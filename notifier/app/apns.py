"""Apple Push Notification service client (token-based auth over HTTP/2)."""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from typing import Protocol

import httpx
import jwt

log = logging.getLogger("notifier.apns")

HOSTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
TOKEN_TTL = 50 * 60  # APNs accepts tokens up to 60 min old; refresh at most every 20 min


@dataclass
class ApnsResult:
    ok: bool
    status: int = 0
    reason: str | None = None
    #: APNs' id for an accepted push (`apns-id` response header), for tracing delivery.
    apns_id: str | None = None

    @property
    def device_gone(self) -> bool:
        """True when APNs says this token will never work again for this topic."""
        return self.status == 410 or (
            self.status == 400 and self.reason in ("BadDeviceToken", "DeviceTokenNotForTopic")
        )


class Sender(Protocol):
    async def send(self, device: dict, payload: dict, collapse_id: str) -> ApnsResult: ...


def collapse_id(value: str) -> str:
    return value.encode("utf-8")[:64].decode("utf-8", "ignore")


class ProviderToken:
    def __init__(self, key_pem: str, key_id: str, team_id: str):
        self._key_pem, self._key_id, self._team_id = key_pem, key_id, team_id
        self._token: str | None = None
        self._issued = 0.0
        self.get()  # fail fast on an unusable key

    def get(self, force: bool = False) -> str:
        now = time.time()
        # Never refresh more often than every 20 minutes, even when forced.
        if self._token is None or now - self._issued > TOKEN_TTL or (force and now - self._issued > 20 * 60):
            self._issued = now
            self._token = jwt.encode(
                {"iss": self._team_id, "iat": int(now)},
                self._key_pem,
                algorithm="ES256",
                headers={"kid": self._key_id},
            )
        return self._token


class ApnsClient:
    def __init__(self, key_pem: str, key_id: str, team_id: str, default_topic: str):
        self._jwt = ProviderToken(key_pem, key_id, team_id)
        self._default_topic = default_topic
        self._http = httpx.AsyncClient(http2=True, timeout=httpx.Timeout(15.0))

    async def close(self) -> None:
        await self._http.aclose()

    async def send(self, device: dict, payload: dict, collapse_id_: str) -> ApnsResult:
        result = await self._post(device, payload, collapse_id_, force_token=False)
        if result.status == 403 and result.reason == "ExpiredProviderToken":
            result = await self._post(device, payload, collapse_id_, force_token=True)
        return result

    async def _post(self, device: dict, payload: dict, cid: str, force_token: bool) -> ApnsResult:
        url = f"{HOSTS[device['environment']]}/3/device/{device['token']}"
        headers = {
            "authorization": f"bearer {self._jwt.get(force=force_token)}",
            "apns-topic": device.get("bundle_id") or self._default_topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": str(int(time.time()) + 3600),
            "apns-collapse-id": collapse_id(cid),
        }
        try:
            resp = await self._http.post(url, content=json.dumps(payload).encode(), headers=headers)
        except httpx.HTTPError as exc:
            return ApnsResult(False, 0, f"NetworkError: {exc.__class__.__name__}")
        if resp.status_code == 200:
            return ApnsResult(True, 200, apns_id=resp.headers.get("apns-id"))
        try:
            reason = resp.json().get("reason")
        except ValueError:
            reason = None
        return ApnsResult(False, resp.status_code, reason or f"HTTP {resp.status_code}")
