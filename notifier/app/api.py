"""HTTP API used by the iOS app to register devices."""

from __future__ import annotations

import hmac
import json
import logging
import re

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from .formatting import test_payload
from .notify import Notifier
from .sources import SourceState
from .store import short_token
from .thumbnails import FrigateMedia, NotFound, Signer, UpstreamError

log = logging.getLogger("notifier.api")

HEX_TOKEN = re.compile(r"^[0-9a-f]{16,200}$")
SEVERITIES = ("alert", "detection")
ENVIRONMENTS = ("sandbox", "production")


class Invalid(Exception):
    pass


def validate_device(body: object, default_bundle_id: str) -> dict:
    if not isinstance(body, dict):
        raise Invalid("body must be a JSON object")
    token = body.get("token")
    if not isinstance(token, str) or not HEX_TOKEN.match(token.lower()):
        raise Invalid("token must be a hex string")
    environment = body.get("environment")
    if environment not in ENVIRONMENTS:
        raise Invalid("environment must be 'sandbox' or 'production'")
    bundle_id = body.get("bundle_id") or default_bundle_id
    if not isinstance(bundle_id, str) or len(bundle_id) > 255:
        raise Invalid("bundle_id must be a string")
    device_name = body.get("device_name") or ""
    if not isinstance(device_name, str) or len(device_name) > 255:
        raise Invalid("device_name must be a string")
    severities = body.get("severities", ["alert"])
    if (not isinstance(severities, list) or not severities
            or any(s not in SEVERITIES for s in severities)):
        raise Invalid("severities must be a non-empty subset of ['alert', 'detection']")
    cameras = body.get("cameras") or []
    if not isinstance(cameras, list) or any(not isinstance(c, str) or not c for c in cameras):
        raise Invalid("cameras must be a list of camera names")
    return {
        "token": token.lower(),
        "environment": environment,
        "bundle_id": bundle_id,
        "device_name": device_name,
        "severities": [s for s in SEVERITIES if s in severities],
        "cameras": list(dict.fromkeys(cameras)),
    }


def create_app(notifier: Notifier, state: SourceState, api_token: str, default_bundle_id: str,
               lifespan=None, media: FrigateMedia | None = None) -> Starlette:
    store = notifier.store

    def authorized(request: Request) -> bool:
        header = request.headers.get("authorization", "")
        scheme, _, supplied = header.partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(supplied.strip().encode(), api_token.encode())

    def unauthorized() -> JSONResponse:
        return JSONResponse({"error": "unauthorized"}, status_code=401,
                            headers={"WWW-Authenticate": "Bearer"})

    async def health(request: Request) -> JSONResponse:
        return JSONResponse({"status": "ok", "source": state.name,
                             "source_connected": state.connected, "devices": store.count_devices()})

    async def register(request: Request) -> Response:
        if not authorized(request):
            return unauthorized()
        try:
            body = await request.json()
        except (ValueError, json.JSONDecodeError):
            return JSONResponse({"error": "invalid JSON"}, status_code=400)
        try:
            fields = validate_device(body, default_bundle_id)
        except Invalid as exc:
            return JSONResponse({"error": str(exc)}, status_code=400)
        device = store.upsert_device(**fields)
        log.info("Registered %s (%s, %s, severities=%s, cameras=%s)", short_token(device["token"]),
                 device["device_name"] or "unnamed", device["environment"], device["severities"],
                 device["cameras"] or "all")
        return JSONResponse(device)

    async def unregister(request: Request) -> Response:
        if not authorized(request):
            return unauthorized()
        token = request.path_params["token"].lower()
        if store.delete_device(token):
            log.info("Unregistered %s", short_token(token))
        return Response(status_code=204)

    async def send_test(request: Request) -> Response:
        if not authorized(request):
            return unauthorized()
        device = store.get_device(request.path_params["token"].lower())
        if device is None:
            return JSONResponse({"error": "device not found"}, status_code=404)
        result = await notifier.deliver(device, test_payload(), "test")
        if result.ok:
            log.info("Test push sent to %s", short_token(device["token"]))
            return JSONResponse({"sent": True})
        return JSONResponse({"sent": False, "reason": result.reason}, status_code=502)

    signer = Signer(api_token)

    async def thumbnail(request: Request) -> Response:
        # No bearer auth: the HMAC signature in the query string is the authorization.
        review_id = request.path_params["review_id"]
        if media is None:
            return JSONResponse({"error": "thumbnails are not enabled"}, status_code=404)
        if not signer.verify(review_id, request.query_params.get("expires"), request.query_params.get("sig")):
            return JSONResponse({"error": "invalid or expired link"}, status_code=403)
        try:
            body, content_type = await media.fetch(review_id)
        except NotFound as exc:
            log.info("Thumbnail for review %s not found: %s", review_id, exc)
            return JSONResponse({"error": "thumbnail not found"}, status_code=404)
        except UpstreamError as exc:
            log.warning("Thumbnail for review %s: Frigate error: %s", review_id, exc)
            return JSONResponse({"error": "could not fetch thumbnail from Frigate"}, status_code=502)
        return Response(body, media_type=content_type,
                        headers={"Cache-Control": "private, max-age=3600"})

    return Starlette(
        routes=[
            Route("/api/v1/health", health, methods=["GET"]),
            Route("/api/v1/devices", register, methods=["POST"]),
            Route("/api/v1/devices/{token}", unregister, methods=["DELETE"]),
            Route("/api/v1/devices/{token}/test", send_test, methods=["POST"]),
            Route("/api/v1/thumbnails/{review_id}", thumbnail, methods=["GET"]),
        ],
        lifespan=lifespan,
    )
