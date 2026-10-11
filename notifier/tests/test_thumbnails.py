import asyncio
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from starlette.testclient import TestClient

from app.api import create_app
from app.config import Settings
from app.formatting import review_payload, test_payload
from app.sources import SourceState
from app.thumbnails import FrigateMedia, Signer, media_url, thumbnail_url

from .conftest import TOKEN_A, add_device, message, review

API_TOKEN = "s3cret"
PUBLIC = "https://notify.example.com"
FRIGATE = "http://frigate:5000"
RID = "1791293688.0-abc123"
THUMB = "/media/frigate/clips/review/thumb-front_door-1791293688.0-abc123.webp"


# --- signing -------------------------------------------------------------------
def test_sign_and_verify():
    s = Signer(API_TOKEN)
    sig = s.sign(RID, 2000)
    assert len(sig) == 64
    assert s.verify(RID, "2000", sig, now=1000)
    assert s.verify(RID, "2000", sig.upper(), now=1000)


@pytest.mark.parametrize("rid,expires,sig", [
    ("other-review", "2000", None),       # tampered review id
    (RID, "2001", None),                  # tampered expiry
    (RID, "2000", "0" * 64),              # wrong signature
    (RID, None, None), (RID, "2000", ""), (RID, "", None), (RID, "abc", None),  # missing / malformed
])
def test_verify_rejects(rid, expires, sig):
    s = Signer(API_TOKEN)
    good = s.sign(RID, 2000)
    assert not s.verify(rid, expires, good if sig is None and expires not in (None, "") else sig, now=1000)


def test_verify_rejects_expired_and_other_key():
    s = Signer(API_TOKEN)
    sig = s.sign(RID, 2000)
    assert not s.verify(RID, "2000", sig, now=2001)
    assert not Signer("different").verify(RID, "2000", sig, now=1000)


def test_thumbnail_url_format():
    url = thumbnail_url(PUBLIC, Signer(API_TOKEN), "a b/c", now=1000.7)
    parts = urlsplit(url)
    assert parts.path == "/api/v1/thumbnails/a%20b%2Fc"
    q = parse_qs(parts.query)
    assert q["expires"] == ["4600"]
    assert Signer(API_TOKEN).verify("a b/c", q["expires"][0], q["sig"][0], now=1000)


def test_media_url_mapping():
    assert media_url(FRIGATE, THUMB) == f"{FRIGATE}/clips/review/thumb-front_door-1791293688.0-abc123.webp"
    assert media_url(FRIGATE, "clips/x.webp") == f"{FRIGATE}/clips/x.webp"


# --- payload -------------------------------------------------------------------
def test_payload_thumbnail_only_when_given():
    assert "thumbnail_url" not in review_payload(review())["frigate"]
    assert review_payload(review(), "https://x/t")["frigate"]["thumbnail_url"] == "https://x/t"
    assert "thumbnail_url" not in test_payload()["frigate"]


def test_notifier_adds_thumbnail_url_when_enabled(store, sender, make_notifier, clock):
    add_device(store, TOKEN_A, ["alert"])
    signer = Signer(API_TOKEN)
    n = make_notifier(thumbnail_url=lambda rid, now: thumbnail_url(PUBLIC, signer, rid, now))
    asyncio.run(n.handle(message("new")))
    url = sender.sent[0][1]["frigate"]["thumbnail_url"]
    assert url.startswith(f"{PUBLIC}/api/v1/thumbnails/{RID}?expires={int(clock.t) + 3600}&sig=")
    assert store.thumb_path(RID) == THUMB


def test_notifier_without_thumbnails(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    asyncio.run(make_notifier().handle(message("new")))
    assert "thumbnail_url" not in sender.sent[0][1]["frigate"]
    assert store.thumb_path(RID) is None


def test_stored_thumb_paths_pruned_after_24h(store):
    store.remember_review(RID, THUMB, now=1000)
    store.prune(now=1000 + 23 * 3600)
    assert store.thumb_path(RID) == THUMB
    store.prune(now=1000 + 25 * 3600)
    assert store.thumb_path(RID) is None


# --- endpoint --------------------------------------------------------------------
class FakeFrigate:
    """httpx MockTransport handler emulating the bits of Frigate we use."""

    def __init__(self):
        self.requests = []
        self.reviews = {}            # review id -> thumb_path for /api/review/<id>
        self.images = {}             # path -> (bytes, content type)
        self.require_login = False
        self.valid_cookie = "tok1"
        self.fail = None             # status code to return for everything, or "network"

    def __call__(self, request):
        self.requests.append(request)
        if self.fail == "network":
            raise httpx.ConnectError("unreachable")
        if self.fail:
            return httpx.Response(self.fail)
        path = request.url.path
        if path == "/api/login":
            return httpx.Response(200, headers={"set-cookie": f"frigate_token={self.valid_cookie}; Path=/"})
        if self.require_login and request.headers.get("cookie") != f"frigate_token={self.valid_cookie}":
            return httpx.Response(401)
        if path.startswith("/api/review/"):
            rid = path.removeprefix("/api/review/")
            if rid not in self.reviews:
                return httpx.Response(404, json={"message": "not found"})
            return httpx.Response(200, json={"id": rid, "thumb_path": self.reviews[rid]})
        if path in self.images:
            body, ctype = self.images[path]
            return httpx.Response(200, content=body, headers={"content-type": ctype})
        return httpx.Response(404)


@pytest.fixture
def frigate():
    return FakeFrigate()


def make_client(store, notifier, frigate, **settings_overrides):
    settings = Settings(api_token=API_TOKEN, apns_key_id="k", apns_team_id="t", apns_key="",
                        frigate_url=FRIGATE, public_url=PUBLIC, **settings_overrides)
    media = FrigateMedia(settings, store, httpx.AsyncClient(transport=httpx.MockTransport(frigate)))
    app = create_app(notifier, SourceState("mqtt"), API_TOKEN, "net.sjolie.frigateapp", media=media)
    return TestClient(app)


def signed_path(rid=RID, ttl=3600):
    import time
    expires = int(time.time()) + ttl
    return f"/api/v1/thumbnails/{rid}?expires={expires}&sig={Signer(API_TOKEN).sign(rid, expires)}"


IMG_PATH = "/clips/review/thumb-front_door-1791293688.0-abc123.webp"


def test_endpoint_serves_stored_thumbnail(store, make_notifier, frigate):
    store.remember_review(RID, THUMB)
    frigate.images[IMG_PATH] = (b"WEBPDATA", "image/webp")
    with make_client(store, make_notifier(), frigate) as c:
        r = c.get(signed_path())  # no Authorization header
    assert r.status_code == 200
    assert r.content == b"WEBPDATA"
    assert r.headers["content-type"] == "image/webp"
    assert r.headers["cache-control"] == "private, max-age=3600"
    assert [req.url.path for req in frigate.requests] == [IMG_PATH]


def test_endpoint_falls_back_to_review_api(store, make_notifier, frigate):
    frigate.reviews[RID] = THUMB
    frigate.images[IMG_PATH] = (b"JPEG", "image/jpeg")
    with make_client(store, make_notifier(), frigate) as c:
        r = c.get(signed_path())
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert [req.url.path for req in frigate.requests] == [f"/api/review/{RID}", IMG_PATH]


def test_endpoint_logs_in_and_relogs_on_401(store, make_notifier, frigate):
    store.remember_review(RID, THUMB)
    frigate.images[IMG_PATH] = (b"IMG", "image/webp")
    frigate.require_login = True
    with make_client(store, make_notifier(), frigate, frigate_username="u", frigate_password="p") as c:
        assert c.get(signed_path()).status_code == 200
        frigate.valid_cookie = "tok2"  # session expired on Frigate's side
        assert c.get(signed_path()).status_code == 200
    paths = [req.url.path for req in frigate.requests]
    assert paths == ["/api/login", IMG_PATH, IMG_PATH, "/api/login", IMG_PATH]


@pytest.mark.parametrize("query", [
    "", "?expires=9999999999", "?sig=" + "0" * 64,
    "?expires=9999999999&sig=" + "0" * 64,
])
def test_endpoint_403_bad_signature(store, make_notifier, frigate, query):
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(f"/api/v1/thumbnails/{RID}{query}").status_code == 403
    assert frigate.requests == []


def test_endpoint_403_expired(store, make_notifier, frigate):
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(signed_path(ttl=-10)).status_code == 403


def test_endpoint_403_signature_for_other_review(store, make_notifier, frigate):
    path = signed_path("other").replace("/other?", f"/{RID}?")
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(path).status_code == 403


def test_endpoint_404_unknown_review(store, make_notifier, frigate):
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(signed_path()).status_code == 404


def test_endpoint_404_missing_image(store, make_notifier, frigate):
    store.remember_review(RID, THUMB)
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(signed_path()).status_code == 404


@pytest.mark.parametrize("fail", ["network", 500, 503])
def test_endpoint_502_frigate_errors(store, make_notifier, frigate, fail):
    store.remember_review(RID, THUMB)
    frigate.fail = fail
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(signed_path()).status_code == 502


def test_endpoint_502_on_review_lookup_error(store, make_notifier, frigate):
    frigate.fail = 500
    with make_client(store, make_notifier(), frigate) as c:
        assert c.get(signed_path()).status_code == 502


def test_endpoint_404_when_disabled(store, make_notifier):
    app = create_app(make_notifier(), SourceState("mqtt"), API_TOKEN, "net.sjolie.frigateapp")
    with TestClient(app) as c:
        assert c.get(signed_path()).status_code == 404


def test_thumbnails_enabled_setting():
    base = {"API_TOKEN": "t", "APNS_KEY_ID": "k", "APNS_TEAM_ID": "t", "APNS_KEY": "pem", "MQTT_HOST": "m"}
    assert not Settings.from_env(base).thumbnails_enabled
    assert not Settings.from_env({**base, "PUBLIC_URL": PUBLIC}).thumbnails_enabled
    s = Settings.from_env({**base, "PUBLIC_URL": PUBLIC + "/", "FRIGATE_URL": FRIGATE})
    assert s.thumbnails_enabled and s.public_url == PUBLIC
