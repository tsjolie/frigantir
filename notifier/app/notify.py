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


class Notifier:
    def __init__(self, store: Store, sender: Sender, cameras: list[str] | None = None,
                 cooldown_seconds: int = 0, clock: Callable[[], float] = time.time,
                 thumbnail_url: Callable[[str, float], str] | None = None):
        self.store = store
        self.sender = sender
        self.cameras = set(cameras or [])
        self.cooldown = cooldown_seconds
        self.clock = clock
        self.thumbnail_url = thumbnail_url  # (review_id, now) -> signed URL, when enabled
        self._last_sent: dict[tuple[str, str], float] = {}  # (token, camera) -> ts

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
        targets = []
        for device in self.store.list_devices():
            token = device["token"]
            if severity not in device["severities"]:
                continue
            if device["cameras"] and camera not in device["cameras"]:
                continue
            if self.store.was_notified(review_id, token):
                continue
            if self.cooldown and now - self._last_sent.get((token, camera), 0) < self.cooldown:
                log.debug("Cooldown active for %s on %s", short_token(token), camera)
                continue
            if not self.store.claim(review_id, token, now):
                continue
            self._last_sent[(token, camera)] = now
            targets.append(device)

        if not targets:
            return []
        thumb = self.thumbnail_url(review_id, now) if self.thumbnail_url and review.get("thumb_path") else None
        payload = review_payload(review, thumb)
        log.info("Review %s (%s, %s, %s): notifying %d device(s)", review_id, camera, severity,
                 message.get("type"), len(targets))
        results = await asyncio.gather(*(self.deliver(d, payload, review_id) for d in targets))
        return [d["token"] for d, r in zip(targets, results) if r.ok]

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
