"""Entry point: python -m app"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import sys

import uvicorn

from .apns import ApnsClient
from .api import create_app
from .config import ConfigError, Settings
from .notify import Notifier
from .sources import SourceState, run_source
from .store import Store
from .thumbnails import FrigateMedia, Signer, thumbnail_url

log = logging.getLogger("notifier")


def main() -> None:
    try:
        settings = Settings.from_env()
    except ConfigError as exc:
        print(f"notifier: {exc}", file=sys.stderr)
        sys.exit(2)

    logging.basicConfig(level=settings.log_level,
                        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s")
    for noisy in ("httpx", "httpcore", "hpack", "websockets", "uvicorn.access"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    try:
        apns = ApnsClient(settings.apns_key, settings.apns_key_id, settings.apns_team_id,
                          settings.apns_bundle_id)
    except Exception as exc:
        print(f"notifier: could not load APNs key: {exc}", file=sys.stderr)
        sys.exit(2)

    os.makedirs(settings.data_dir, exist_ok=True)
    store = Store(os.path.join(settings.data_dir, "notifier.sqlite3"))
    media = None
    thumb_url = None
    if settings.thumbnails_enabled:
        media = FrigateMedia(settings, store)
        signer = Signer(settings.api_token)
        thumb_url = lambda review_id, now: thumbnail_url(settings.public_url, signer, review_id, now)  # noqa: E731
    notifier = Notifier(store, apns, settings.cameras, settings.cooldown_seconds, thumbnail_url=thumb_url)
    state = SourceState(settings.source)

    @contextlib.asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(run_source(settings, state, notifier.handle))
        log.info("Started: source=%s, %d registered device(s), cameras=%s, cooldown=%ss",
                 settings.source, store.count_devices(), settings.cameras or "all",
                 settings.cooldown_seconds)
        if media:
            log.info("Thumbnails enabled: links via %s, images from %s", settings.public_url, settings.frigate_url)
        else:
            log.info("Thumbnails disabled (set both PUBLIC_URL and FRIGATE_URL to enable)")
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            await apns.close()
            if media:
                await media.close()

    app = create_app(notifier, state, settings.api_token, settings.apns_bundle_id, lifespan=lifespan,
                     media=media)
    uvicorn.run(app, host="0.0.0.0", port=settings.port, log_level=settings.log_level.lower(),
                proxy_headers=True, server_header=False, access_log=False, log_config=None)


if __name__ == "__main__":
    main()
