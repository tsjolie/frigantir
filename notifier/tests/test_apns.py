import asyncio
import json
import time

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.apns import ApnsClient, ApnsResult

from .conftest import TOKEN_A


def make_key():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    return key, pem


def client_with(handler):
    key, pem = make_key()
    c = ApnsClient(pem, "KEYID12345", "TEAMID1234", "net.sjolie.frigateapp")
    c._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return c, key


DEVICE = {"token": TOKEN_A, "environment": "sandbox", "bundle_id": "com.example.app"}


def test_request_shape():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200)

    c, key = client_with(handler)
    result = asyncio.run(c.send(DEVICE, {"aps": {}}, "r" * 80))
    assert result.ok
    req = seen[0]
    assert str(req.url) == f"https://api.sandbox.push.apple.com/3/device/{TOKEN_A}"
    assert req.headers["apns-topic"] == "com.example.app"
    assert req.headers["apns-push-type"] == "alert"
    assert req.headers["apns-priority"] == "10"
    assert req.headers["apns-collapse-id"] == "r" * 64
    assert abs(int(req.headers["apns-expiration"]) - (time.time() + 3600)) < 5
    assert json.loads(req.content) == {"aps": {}}
    token = req.headers["authorization"].removeprefix("bearer ")
    assert jwt.get_unverified_header(token)["kid"] == "KEYID12345"
    claims = jwt.decode(token, key.public_key(), algorithms=["ES256"])
    assert claims["iss"] == "TEAMID1234"


def test_production_host_and_topic_fallback():
    seen = []
    c, _ = client_with(lambda r: seen.append(r) or httpx.Response(200))
    asyncio.run(c.send({"token": TOKEN_A, "environment": "production", "bundle_id": ""}, {}, "x"))
    assert seen[0].url.host == "api.push.apple.com"
    assert seen[0].headers["apns-topic"] == "net.sjolie.frigateapp"


def test_error_reason_parsed():
    c, _ = client_with(lambda r: httpx.Response(400, json={"reason": "BadDeviceToken"}))
    result = asyncio.run(c.send(DEVICE, {}, "x"))
    assert result == ApnsResult(False, 400, "BadDeviceToken")
    assert result.device_gone


def test_410_is_gone_but_429_is_not():
    assert ApnsResult(False, 410, "Unregistered").device_gone
    assert not ApnsResult(False, 429, "TooManyRequests").device_gone
    assert not ApnsResult(False, 400, "BadCollapseId").device_gone


def test_network_error():
    def handler(request):
        raise httpx.ConnectError("down")

    c, _ = client_with(handler)
    result = asyncio.run(c.send(DEVICE, {}, "x"))
    assert not result.ok and result.reason.startswith("NetworkError")


def test_jwt_cached():
    c, _ = client_with(lambda r: httpx.Response(200))
    assert c._jwt.get() == c._jwt.get()
