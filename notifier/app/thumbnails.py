"""Signed, expiring thumbnail links, and proxying the image from Frigate."""

from __future__ import annotations

import hashlib
import hmac
import logging
import time
from urllib.parse import quote

import httpx

from .config import Settings
from .sources import frigate_login
from .store import Store

log = logging.getLogger("notifier.thumbnails")

LINK_TTL = 3600  # matches apns-expiration
MEDIA_PREFIX = "/media/frigate/"


class NotFound(Exception):
    pass


class UpstreamError(Exception):
    pass


class Signer:
    def __init__(self, api_token: str):
        self._key = hashlib.sha256(b"thumbnails:" + api_token.encode()).digest()

    def sign(self, review_id: str, expires: int) -> str:
        return hmac.new(self._key, f"{review_id}:{expires}".encode(), hashlib.sha256).hexdigest()

    def verify(self, review_id: str, expires: str | None, sig: str | None, now: float | None = None) -> bool:
        if not expires or not sig or not expires.isdigit():
            return False
        if int(expires) < (now if now is not None else time.time()):
            return False
        return hmac.compare_digest(self.sign(review_id, int(expires)), sig.lower())


def thumbnail_url(public_url: str, signer: Signer, review_id: str, now: float) -> str:
    expires = int(now) + LINK_TTL
    return (f"{public_url}/api/v1/thumbnails/{quote(review_id, safe='')}"
            f"?expires={expires}&sig={signer.sign(review_id, expires)}")


def media_url(frigate_url: str, thumb_path: str) -> str:
    """/media/frigate/clips/review/x.webp -> <FRIGATE_URL>/clips/review/x.webp (as the app does)."""
    path = thumb_path[len(MEDIA_PREFIX):] if thumb_path.startswith(MEDIA_PREFIX) else thumb_path.lstrip("/")
    return f"{frigate_url}/{quote(path)}"


class FrigateMedia:
    """Fetches review thumbnails from Frigate, logging in when credentials are configured."""

    def __init__(self, settings: Settings, store: Store, http: httpx.AsyncClient | None = None):
        self.settings = settings
        self.store = store
        self.http = http or httpx.AsyncClient(verify=settings.frigate_verify_tls, timeout=10.0)
        self._cookie: str | None = None

    async def close(self) -> None:
        await self.http.aclose()

    @property
    def _has_login(self) -> bool:
        return bool(self.settings.frigate_username and self.settings.frigate_password)

    async def _get(self, url: str) -> httpx.Response:
        try:
            if self._has_login and self._cookie is None:
                self._cookie = await frigate_login(self.settings, self.http)
            resp = await self._request(url)
            if resp.status_code == 401 and self._has_login:
                self._cookie = await frigate_login(self.settings, self.http)
                resp = await self._request(url)
        except httpx.HTTPError as exc:
            raise UpstreamError(f"{exc.__class__.__name__}: {exc}") from exc
        except RuntimeError as exc:  # login without a cookie
            raise UpstreamError(str(exc)) from exc
        return resp

    async def _request(self, url: str) -> httpx.Response:
        headers = {"Cookie": f"frigate_token={self._cookie}"} if self._cookie else {}
        return await self.http.get(url, headers=headers)

    async def _lookup_thumb_path(self, review_id: str) -> str:
        thumb = self.store.thumb_path(review_id)
        if thumb:
            return thumb
        resp = await self._get(f"{self.settings.frigate_url}/api/review/{quote(review_id, safe='')}")
        if resp.status_code == 404:
            raise NotFound("review not found")
        if resp.status_code != 200:
            raise UpstreamError(f"Frigate /api/review returned {resp.status_code}")
        try:
            thumb = resp.json().get("thumb_path")
        except (ValueError, AttributeError):
            thumb = None
        if not thumb:
            raise NotFound("review has no thumbnail")
        return thumb

    async def fetch(self, review_id: str) -> tuple[bytes, str]:
        """Return (image bytes, content type) or raise NotFound / UpstreamError."""
        thumb = await self._lookup_thumb_path(review_id)
        resp = await self._get(media_url(self.settings.frigate_url, thumb))
        if resp.status_code == 404:
            raise NotFound("thumbnail not found")
        if resp.status_code != 200:
            raise UpstreamError(f"Frigate returned {resp.status_code} for thumbnail")
        return resp.content, resp.headers.get("content-type", "application/octet-stream")
