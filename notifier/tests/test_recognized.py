"""'Skip alerts for recognized people' (device setting ignore_verified)."""
import asyncio
import sqlite3

from app.notify import may_still_be_recognized, recognized_only
from app.store import Store

from .conftest import TOKEN_A, TOKEN_B, message, review

VERIFIED = {"objects": ["person-verified"]}
UNKNOWN = {"objects": ["person"]}


def add(store, token, ignore_verified):
    store.upsert_device(token, "sandbox", "net.sjolie.frigateapp", "Phone", ["alert"], [],
                        ignore_verified=ignore_verified)


def test_classification():
    assert recognized_only(review(data=VERIFIED))
    assert not recognized_only(review(data=UNKNOWN))
    assert not recognized_only(review(data={"objects": ["person-verified", "person"]}))
    assert not recognized_only(review(data={"objects": ["person-verified", "car"]}))
    assert not recognized_only(review(data={"objects": [], "audio": ["speech"]}))
    assert may_still_be_recognized(review(data=UNKNOWN))
    assert may_still_be_recognized(review(data={"objects": ["person-verified", "person"]}))
    assert not may_still_be_recognized(review(data={"objects": ["person", "car"]}))
    assert not may_still_be_recognized(review(data=VERIFIED))


def test_recognized_person_skips_only_devices_that_opted_in(store, sender, make_notifier):
    add(store, TOKEN_A, ignore_verified=True)
    add(store, TOKEN_B, ignore_verified=False)
    sent = asyncio.run(make_notifier().handle(message("new", data=VERIFIED)))
    assert sent == [TOKEN_B]


def test_unrecognized_person_is_sent_after_the_hold(store, sender, make_notifier):
    add(store, TOKEN_A, ignore_verified=True)

    async def scenario():
        n = make_notifier(verify_wait_seconds=0.01)
        assert await n.handle(message("new", data=UNKNOWN)) == []  # held
        await n.drain()

    asyncio.run(scenario())
    assert [token for token, _, _ in sender.sent] == [TOKEN_A]


def test_recognition_during_the_hold_cancels_the_push(store, sender, make_notifier):
    add(store, TOKEN_A, ignore_verified=True)

    async def scenario():
        n = make_notifier(verify_wait_seconds=0.05)
        await n.handle(message("new", data=UNKNOWN))
        await n.handle(message("update", data=VERIFIED))  # face recognized
        await n.drain()

    asyncio.run(scenario())
    assert sender.sent == []


def test_stranger_joining_during_the_hold_notifies_once(store, sender, make_notifier):
    add(store, TOKEN_A, ignore_verified=True)

    async def scenario():
        n = make_notifier(verify_wait_seconds=0.05)
        await n.handle(message("new", data=UNKNOWN))
        sent = await n.handle(message("update", data={"objects": ["person", "car"]}))
        await n.drain()
        return sent

    assert asyncio.run(scenario()) == [TOKEN_A]
    assert len(sender.sent) == 1


def test_other_alerts_are_not_held(store, sender, make_notifier):
    add(store, TOKEN_A, ignore_verified=True)
    audio = {"objects": [], "audio": ["speech"]}
    assert asyncio.run(make_notifier().handle(message("new", data=audio))) == [TOKEN_A]


def test_wait_of_zero_sends_unrecognized_people_immediately(store, sender, make_notifier):
    add(store, TOKEN_A, ignore_verified=True)
    n = make_notifier(verify_wait_seconds=0)
    assert asyncio.run(n.handle(message("new", data=UNKNOWN))) == [TOKEN_A]


def test_migrates_databases_without_the_column(tmp_path):
    path = tmp_path / "old.db"
    db = sqlite3.connect(path)
    db.execute("""CREATE TABLE devices (token TEXT PRIMARY KEY, environment TEXT NOT NULL,
                  bundle_id TEXT NOT NULL, device_name TEXT NOT NULL DEFAULT '', severities TEXT NOT NULL,
                  cameras TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)""")
    db.execute("""INSERT INTO devices VALUES (?, 'sandbox', 'net.sjolie.frigateapp', 'Old', '["alert"]',
                  '[]', 0, 0)""", (TOKEN_A,))
    db.commit()
    db.close()
    store = Store(str(path))
    assert store.get_device(TOKEN_A)["ignore_verified"] is False
    store.upsert_device(TOKEN_A, "sandbox", "net.sjolie.frigateapp", "Old", ["alert"], [], ignore_verified=True)
    assert store.get_device(TOKEN_A)["ignore_verified"] is True
