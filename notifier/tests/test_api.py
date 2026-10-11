import pytest
from starlette.testclient import TestClient

from app.api import create_app
from app.apns import ApnsResult
from app.sources import SourceState

from .conftest import TOKEN_A, add_device

API_TOKEN = "s3cret"
AUTH = {"Authorization": f"Bearer {API_TOKEN}"}


@pytest.fixture
def client(make_notifier):
    state = SourceState("mqtt")
    app = create_app(make_notifier(), state, API_TOKEN, "net.sjolie.frigateapp")
    with TestClient(app) as c:
        c.state = state
        yield c


def device_body(**overrides):
    body = {"token": TOKEN_A, "environment": "sandbox", "bundle_id": "net.sjolie.frigateapp",
            "device_name": "Tristan's iPhone", "severities": ["alert"], "cameras": []}
    body.update(overrides)
    return body


def test_health_no_auth(client, store):
    add_device(store)
    r = client.get("/api/v1/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "source": "mqtt", "source_connected": False, "devices": 1}


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": API_TOKEN},
                                     {"Authorization": f"Basic {API_TOKEN}"}])
def test_auth_required(client, headers):
    assert client.post("/api/v1/devices", json=device_body(), headers=headers).status_code == 401
    assert client.delete(f"/api/v1/devices/{TOKEN_A}", headers=headers).status_code == 401
    assert client.post(f"/api/v1/devices/{TOKEN_A}/test", headers=headers).status_code == 401


def test_register_and_upsert(client, store):
    r = client.post("/api/v1/devices", json=device_body(), headers=AUTH)
    assert r.status_code == 200
    d = r.json()
    assert d["token"] == TOKEN_A and d["environment"] == "sandbox"
    assert d["device_name"] == "Tristan's iPhone" and d["severities"] == ["alert"] and d["cameras"] == []

    r = client.post("/api/v1/devices", headers=AUTH, json=device_body(
        token=TOKEN_A.upper(), environment="production", severities=["detection", "alert"],
        cameras=["front_door"]))
    assert r.status_code == 200
    d = r.json()
    assert d["token"] == TOKEN_A and d["environment"] == "production"
    assert d["severities"] == ["alert", "detection"] and d["cameras"] == ["front_door"]
    assert store.count_devices() == 1


@pytest.mark.parametrize("overrides", [
    {"token": "not-hex!"}, {"token": ""}, {"token": 123},
    {"environment": "staging"}, {"environment": None},
    {"severities": []}, {"severities": ["alert", "motion"]}, {"severities": "alert"},
    {"cameras": "front_door"}, {"cameras": [1]},
    {"device_name": 5},
])
def test_register_validation(client, overrides):
    r = client.post("/api/v1/devices", json=device_body(**overrides), headers=AUTH)
    assert r.status_code == 400
    assert "error" in r.json()


def test_register_invalid_json(client):
    r = client.post("/api/v1/devices", content=b"{nope", headers={**AUTH, "content-type": "application/json"})
    assert r.status_code == 400
    assert client.post("/api/v1/devices", json=["x"], headers=AUTH).status_code == 400


def test_register_bundle_id_fallback(client):
    body = device_body()
    del body["bundle_id"]
    assert client.post("/api/v1/devices", json=body, headers=AUTH).json()["bundle_id"] == "net.sjolie.frigateapp"


def test_unregister(client, store):
    add_device(store)
    assert client.delete(f"/api/v1/devices/{TOKEN_A}", headers=AUTH).status_code == 204
    assert store.get_device(TOKEN_A) is None
    assert client.delete(f"/api/v1/devices/{TOKEN_A}", headers=AUTH).status_code == 204


def test_test_push_ok(client, store, sender):
    add_device(store)
    r = client.post(f"/api/v1/devices/{TOKEN_A}/test", headers=AUTH)
    assert r.status_code == 200 and r.json() == {"sent": True}
    token, payload, cid = sender.sent[0]
    assert cid == "test" and payload["frigate"] == {"test": True}


def test_test_push_unknown_device(client):
    assert client.post(f"/api/v1/devices/{TOKEN_A}/test", headers=AUTH).status_code == 404


def test_test_push_apns_failure(client, store, sender):
    add_device(store)
    sender.responses[TOKEN_A] = ApnsResult(False, 400, "BadDeviceToken")
    r = client.post(f"/api/v1/devices/{TOKEN_A}/test", headers=AUTH)
    assert r.status_code == 502
    assert r.json() == {"sent": False, "reason": "BadDeviceToken"}
    assert store.get_device(TOKEN_A) is None  # bad token removed
