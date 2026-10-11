"""Event sources: Frigate's MQTT `<prefix>/reviews` topic or its `/ws` WebSocket."""

from __future__ import annotations

import asyncio
import json
import logging
import ssl
from typing import Any, Awaitable, Callable

import httpx

from .config import Settings

log = logging.getLogger("notifier.source")

Handler = Callable[[dict], Awaitable[Any]]
MAX_BACKOFF = 30.0


class SourceState:
    def __init__(self, name: str):
        self.name = name
        self.connected = False

    def set(self, connected: bool, detail: str = "") -> None:
        if connected != self.connected:
            self.connected = connected
            log.info("%s source %s%s", self.name, "connected" if connected else "disconnected",
                     f" ({detail})" if detail else "")


def decode_review(raw: Any) -> dict | None:
    """Payload may be bytes, a JSON-encoded string, or an already-decoded object."""
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return None
    return raw if isinstance(raw, dict) else None


def decode_ws_message(text: str | bytes) -> dict | None:
    """Return the review dict from a Frigate WS frame, or None if it's another topic."""
    try:
        frame = json.loads(text)
    except ValueError:
        return None
    if not isinstance(frame, dict) or frame.get("topic") != "reviews":
        return None
    return decode_review(frame.get("payload"))


async def _dispatch(handler: Handler, review: dict | None) -> None:
    if review is None:
        log.warning("Ignoring undecodable review message")
        return
    try:
        await handler(review)
    except Exception:
        log.exception("Error handling review message")


async def run_forever(state: SourceState, connect_once: Callable[[], Awaitable[None]]) -> None:
    """Run `connect_once` forever, reconnecting with exponential backoff."""
    backoff = 1.0
    while True:
        try:
            await connect_once()
            backoff = 1.0
            state.set(False, "connection closed")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            detail = f"{exc.__class__.__name__}: {exc}"
            if state.connected:
                backoff = 1.0
                state.set(False, detail)
            else:
                log.warning("%s source could not connect: %s", state.name, detail)
            log.debug("Source error", exc_info=True)
        log.info("Reconnecting %s source in %.0fs", state.name, backoff)
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, MAX_BACKOFF)


# --- MQTT --------------------------------------------------------------------
async def run_mqtt(settings: Settings, state: SourceState, handler: Handler) -> None:
    import aiomqtt

    topic = f"{settings.mqtt_topic_prefix}/reviews"

    async def connect_once() -> None:
        async with aiomqtt.Client(
            settings.mqtt_host, settings.mqtt_port,
            username=settings.mqtt_username, password=settings.mqtt_password,
            identifier=None, tls_context=ssl.create_default_context() if settings.mqtt_tls else None,
        ) as client:
            await client.subscribe(topic)
            state.set(True, f"{settings.mqtt_host}:{settings.mqtt_port} topic {topic}")
            async for message in client.messages:
                await _dispatch(handler, decode_review(message.payload))

    await run_forever(state, connect_once)


# --- WebSocket ---------------------------------------------------------------
def ws_url(frigate_url: str) -> str:
    if frigate_url.startswith("https://"):
        return "wss://" + frigate_url[len("https://"):] + "/ws"
    if frigate_url.startswith("http://"):
        return "ws://" + frigate_url[len("http://"):] + "/ws"
    return frigate_url + "/ws"


async def frigate_login(settings: Settings, http: httpx.AsyncClient | None = None) -> str:
    """POST /api/login and return the frigate_token cookie value."""
    if http is None:
        async with httpx.AsyncClient(verify=settings.frigate_verify_tls, timeout=15) as own:
            return await frigate_login(settings, own)
    resp = await http.post(f"{settings.frigate_url}/api/login",
                           json={"user": settings.frigate_username, "password": settings.frigate_password})
    resp.raise_for_status()
    token = resp.cookies.get("frigate_token")
    if not token:
        raise RuntimeError("Frigate login succeeded but returned no frigate_token cookie")
    return token


async def run_websocket(settings: Settings, state: SourceState, handler: Handler) -> None:
    from websockets.asyncio.client import connect

    url = ws_url(settings.frigate_url)
    ssl_ctx = None
    if url.startswith("wss://"):
        ssl_ctx = ssl.create_default_context()
        if not settings.frigate_verify_tls:
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE

    async def connect_once() -> None:
        headers = {}
        if settings.frigate_username and settings.frigate_password:
            # Log in on every (re)connect so expired sessions / 401s recover automatically.
            headers["Cookie"] = f"frigate_token={await frigate_login(settings)}"
        kwargs = {"ssl": ssl_ctx} if ssl_ctx else {}
        async with connect(url, additional_headers=headers, max_size=8 * 1024 * 1024, **kwargs) as ws:
            state.set(True, url)
            async for text in ws:
                review = decode_ws_message(text)
                if review is not None:
                    await _dispatch(handler, review)

    await run_forever(state, connect_once)


async def run_source(settings: Settings, state: SourceState, handler: Handler) -> None:
    if settings.source == "websocket":
        await run_websocket(settings, state, handler)
    else:
        await run_mqtt(settings, state, handler)
