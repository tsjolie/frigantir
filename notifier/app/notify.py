"""Decides which devices to notify for a Frigate review message, and delivers."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Callable

from .apns import ApnsResult, Sender
from .formatting import review_payload
from .store import Store, short_token

log = logging.getLogger("notifier.notify")

VERIFIED_PERSON = "person-verified"


def recognized_only(review: dict) -> bool:
    """Every object in the review is a person Frigate's face recognition knows."""
    objects = (review.get("data") or {}).get("objects") or []
    return bool(objects) and all(o == VERIFIED_PERSON for o in objects)


def may_still_be_recognized(review: dict) -> bool:
    """Only people, at least one not recognized yet. Face recognition often
    finishes a few seconds after a review starts."""
    objects = (review.get("data") or {}).get("objects") or []
    return "person" in objects and all(o in ("person", VERIFIED_PERSON) for o in objects)


class Notifier:
    def __init__(self, store: Store, sender: Sender, cameras: list[str] | None = None,
                 cooldown_seconds: int = 0, clock: Callable[[], float] = time.time,
                 thumbnail_url: Callable[[str, float], str] | None = None,
                 verify_wait_seconds: float = 10):
        self.store = store
        self.sender = sender
        self.cameras = set(cameras or [])
        self.cooldown = cooldown_seconds
        self.clock = clock
        self.thumbnail_url = thumbnail_url  # (review_id, now) -> signed URL, when enabled
        self._last_sent: dict[tuple[str, str], float] = {}  # (token, camera) -> ts
        # Devices with "ignore recognized people" hold person-only alerts this
        # long for face recognition to finish, then decide on the latest data.
        self.verify_wait = verify_wait_seconds
        self._latest: dict[str, dict] = {}  # review id -> newest "after", while a hold is pending
        self._held: dict[tuple[str, str], asyncio.Task] = {}  # (review id, token) -> hold

    #: An alert first seen in an `update` or `end` message still notifies if it
    #: started this recently. Frigate doesn't always send `new`: audio reviews
    #: (e.g. "speech" on a baby camera) were observed arriving as an `update`
    #: that is already an alert, then `end`, with no `new` at all. The age limit
    #: stops a restart from replaying old reviews; the dedupe record stops repeats.
    LATE_ALERT_WINDOW = 15 * 60

    def target_severity(self, message: dict, now: float) -> str | None:
        """Severity whose subscribers should hear about this message, or None."""
        kind = message.get("type")
        after = message.get("after") or {}
        before = message.get("before") or {}
        if kind == "new":
            return after.get("severity")
        if kind in ("update", "end") and after.get("severity") == "alert":
            upgraded = before.get("severity") == "detection"
            started = float(after.get("start_time") or 0)
            if upgraded or now - started <= self.LATE_ALERT_WINDOW:
                return "alert"
        return None

    async def handle(self, message: dict) -> list[str]:
        """Process one review message. Returns the device tokens that were sent a push."""
        severity = self.target_severity(message, self.clock())
        review = message.get("after") or {}
        review_id, camera = review.get("id"), review.get("camera")
        if self.thumbnail_url and review_id and review.get("thumb_path"):
            self.store.remember_review(review_id, review["thumb_path"], self.clock())
        if severity not in ("alert", "detection") or not review_id or not camera:
            return []
        if self.cameras and camera not in self.cameras:
            log.debug("Ignoring review %s: camera %s not in CAMERAS", review_id, camera)
            return []

        now = self.clock()
        self.store.prune(now)
        if any(key[0] == review_id for key in self._held):
            self._latest[review_id] = review
        targets = []
        for device in self.store.list_devices():
            token = device["token"]
            if severity not in device["severities"]:
                continue
            if device["cameras"] and camera not in device["cameras"]:
                continue
            if self.store.was_notified(review_id, token):
                continue
            if device.get("ignore_verified"):
                # Not claimed, so a later message (say, an unrecognized person
                # joining) can still notify.
                if recognized_only(review):
                    log.debug("Skipping %s for %s: recognized person", review_id, short_token(token))
                    continue
                if may_still_be_recognized(review) and self.verify_wait > 0:
                    self._hold(review_id, token, review, severity)
                    continue
            if not self._claim(review_id, token, camera, now):
                continue
            targets.append(device)

        if not targets:
            return []
        log.info("Review %s (%s, %s, %s): notifying %d device(s)", review_id, camera, severity,
                 message.get("type"), len(targets))
        return await self._send(review, targets, now)

    def _claim(self, review_id: str, token: str, camera: str, now: float) -> bool:
        if self.cooldown and now - self._last_sent.get((token, camera), 0) < self.cooldown:
            # Record the review as handled: otherwise its later `update`/`end`
            # messages would notify once the cooldown ran out, minutes late.
            self.store.claim(review_id, token, now)
            log.info("Review %s: %s within cooldown on %s, not notifying", review_id, short_token(token), camera)
            return False
        if not self.store.claim(review_id, token, now):
            return False
        self._last_sent[(token, camera)] = now
        return True

    async def _send(self, review: dict, targets: list[dict], now: float) -> list[str]:
        review_id = review["id"]
        thumb = self.thumbnail_url(review_id, now) if self.thumbnail_url and review.get("thumb_path") else None
        payload = review_payload(review, thumb)
        results = await asyncio.gather(*(self.deliver(d, payload, review_id) for d in targets))
        return [d["token"] for d, r in zip(targets, results) if r.ok]

    def _hold(self, review_id: str, token: str, review: dict, severity: str) -> None:
        key = (review_id, token)
        if key in self._held:
            return
        self._latest[review_id] = review
        log.info("Review %s: holding %ss for face recognition (%s)", review_id, self.verify_wait,
                 short_token(token))
        self._held[key] = asyncio.create_task(self._release(review_id, token, severity))

    async def _release(self, review_id: str, token: str, severity: str) -> None:
        """After the hold: notify unless the review now shows only recognized people."""
        try:
            await asyncio.sleep(self.verify_wait)
            review = self._latest.get(review_id) or {}
            device = self.store.get_device(token)
            if not device or not review or self.store.was_notified(review_id, token):
                return
            if severity not in device["severities"]:
                return
            if device.get("ignore_verified") and recognized_only(review):
                log.info("Review %s: recognized person, not notifying %s", review_id, short_token(token))
                return
            now = self.clock()
            if not self._claim(review_id, token, review.get("camera", ""), now):
                return
            log.info("Review %s (%s, %s, held): notifying 1 device(s)", review_id, review.get("camera"),
                     severity)
            await self._send(review, [device], now)
        finally:
            self._held.pop((review_id, token), None)
            if not any(key[0] == review_id for key in self._held):
                self._latest.pop(review_id, None)

    async def drain(self) -> None:
        """Wait for pending holds (tests, shutdown)."""
        while self._held:
            await asyncio.gather(*list(self._held.values()), return_exceptions=True)

    async def deliver(self, device: dict, payload: dict, collapse_id: str) -> ApnsResult:
        token = device["token"]
        try:
            result = await self.sender.send(device, payload, collapse_id)
        except Exception as exc:  # never let one device break the loop
            log.exception("APNs send to %s failed", short_token(token))
            return ApnsResult(False, 0, f"Error: {exc.__class__.__name__}")
        if result.ok:
            # Accepted by Apple. If the device doesn't show it, the cause is on the
            # device (Focus, notification settings, grouping), not here.
            log.info("Push accepted by APNs for %s (%s, %s) apns-id=%s", short_token(token),
                     device.get("device_name") or "device", device.get("environment"), result.apns_id)
        elif result.device_gone:
            self.store.delete_device(token)
            log.warning("APNs rejected %s (%s %s) - device removed", short_token(token),
                        result.status, result.reason)
        else:
            log.error("APNs push to %s failed: %s %s", short_token(token), result.status, result.reason)
        return result
