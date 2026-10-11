import copy

import pytest

from app.apns import ApnsResult
from app.notify import Notifier
from app.store import Store

TOKEN_A = "a" * 64
TOKEN_B = "b" * 64

REVIEW = {
    "id": "1791293688.0-abc123",
    "camera": "front_door",
    "start_time": 1791293688.0,
    "end_time": None,
    "severity": "alert",
    "thumb_path": "/media/frigate/clips/review/thumb-front_door-1791293688.0-abc123.webp",
    "data": {"detections": ["x"], "objects": ["person"], "sub_labels": ["Alice"],
             "zones": ["driveway"], "audio": []},
}


def review(**overrides):
    r = copy.deepcopy(REVIEW)
    data = overrides.pop("data", None)
    r.update(overrides)
    if data is not None:
        r["data"].update(data)
    return r


def message(kind="new", before=None, **after):
    a = review(**after)
    return {"type": kind, "before": before or copy.deepcopy(a), "after": a}


class FakeSender:
    def __init__(self):
        self.sent = []  # (token, payload, collapse_id)
        self.responses = {}  # token -> ApnsResult

    async def send(self, device, payload, collapse_id):
        self.sent.append((device["token"], payload, collapse_id))
        return self.responses.get(device["token"], ApnsResult(True, 200))


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def store():
    return Store(":memory:")


@pytest.fixture
def sender():
    return FakeSender()


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def make_notifier(store, sender, clock):
    def make(**kwargs):
        return Notifier(store, sender, clock=clock, **kwargs)
    return make


def add_device(store, token=TOKEN_A, severities=("alert",), cameras=(), environment="sandbox"):
    return store.upsert_device(token, environment, "net.sjolie.frigateapp", "Test iPhone",
                               list(severities), list(cameras))
