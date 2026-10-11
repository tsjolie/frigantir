import asyncio

from app.apns import ApnsResult

from .conftest import TOKEN_A, TOKEN_B, add_device, message


def run(coro):
    return asyncio.run(coro)


def test_new_alert_notifies_alert_subscribers(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    add_device(store, TOKEN_B, ["detection"])
    sent = run(make_notifier().handle(message("new")))
    assert sent == [TOKEN_A]
    token, payload, cid = sender.sent[0]
    assert cid == "1791293688.0-abc123"
    assert payload["frigate"]["severity"] == "alert"


def test_new_detection_only_for_detection_subscribers(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    add_device(store, TOKEN_B, ["alert", "detection"])
    assert run(make_notifier().handle(message("new", severity="detection"))) == [TOKEN_B]


def test_update_and_end_of_a_notified_alert_send_nothing_more(store, make_notifier):
    add_device(store, TOKEN_A, ["alert", "detection"])
    n = make_notifier()
    assert run(n.handle(message("new"))) == [TOKEN_A]
    assert run(n.handle(message("update"))) == []
    assert run(n.handle(message("end"))) == []


def test_detection_updates_are_ignored(store, make_notifier):
    add_device(store, TOKEN_A, ["alert", "detection"])
    n = make_notifier()
    assert run(n.handle(message("update", severity="detection"))) == []
    assert run(n.handle(message("end", severity="detection"))) == []


def test_alert_without_a_new_message_notifies_once(store, sender, make_notifier, clock):
    # Seen from Frigate 0.18 for an audio ("speech") alert: no `new`, just an
    # `update` that is already alert→alert, then `end`.
    add_device(store, TOKEN_A, ["alert"])
    clock.t = 1791293688.0 + 2
    n = make_notifier()
    audio = {"objects": [], "audio": ["speech"]}
    update = message("update", before={"severity": "alert"}, data=audio)
    assert run(n.handle(update)) == [TOKEN_A]
    end = message("end", before={"severity": "alert"}, end_time=1791293688.0, data=audio)
    assert run(n.handle(end)) == []
    assert len(sender.sent) == 1


def test_alert_first_seen_at_end_notifies(store, make_notifier, clock):
    add_device(store, TOKEN_A, ["alert"])
    clock.t = 1791293688.0 + 5
    end = message("end", before={"severity": "alert"}, end_time=1791293688.4)
    assert run(make_notifier().handle(end)) == [TOKEN_A]


def test_old_alert_seen_late_is_ignored(store, make_notifier, clock):
    # e.g. the notifier restarted while a review it never saw was ending.
    add_device(store, TOKEN_A, ["alert"])
    clock.t = 1791293688.0 + 16 * 60
    assert run(make_notifier().handle(message("end"))) == []


def test_severity_upgrade_notifies_alert_subscribers_once(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    add_device(store, TOKEN_B, ["alert", "detection"])
    n = make_notifier()
    assert run(n.handle(message("new", severity="detection"))) == [TOKEN_B]
    upgrade = message("update", before={"severity": "detection"}, severity="alert")
    # B already heard about this review as a detection; only A gets the alert.
    assert run(n.handle(upgrade)) == [TOKEN_A]
    assert run(n.handle(upgrade)) == []
    assert len(sender.sent) == 2


def test_dedupe_same_review(store, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    n = make_notifier()
    assert run(n.handle(message("new"))) == [TOKEN_A]
    assert run(n.handle(message("new"))) == []


def test_dedupe_expires_after_24h(store, make_notifier, clock):
    add_device(store, TOKEN_A, ["alert"])
    n = make_notifier()
    run(n.handle(message("new")))
    clock.t += 25 * 3600
    assert run(n.handle(message("new"))) == [TOKEN_A]


def test_device_camera_filter(store, make_notifier):
    add_device(store, TOKEN_A, ["alert"], cameras=["garage"])
    add_device(store, TOKEN_B, ["alert"], cameras=[])
    assert run(make_notifier().handle(message("new"))) == [TOKEN_B]
    assert run(make_notifier().handle(message("new", id="r2", camera="garage"))) == [TOKEN_A, TOKEN_B]


def test_global_camera_allowlist(store, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    n = make_notifier(cameras=["garage"])
    assert run(n.handle(message("new"))) == []
    assert run(n.handle(message("new", id="r2", camera="garage"))) == [TOKEN_A]


def test_cooldown_per_device_and_camera(store, make_notifier, clock):
    add_device(store, TOKEN_A, ["alert"])
    n = make_notifier(cooldown_seconds=60)
    assert run(n.handle(message("new", id="r1"))) == [TOKEN_A]
    clock.t += 30
    assert run(n.handle(message("new", id="r2"))) == []
    assert run(n.handle(message("new", id="r3", camera="garage"))) == [TOKEN_A]
    clock.t += 31
    assert run(n.handle(message("new", id="r4"))) == [TOKEN_A]


def test_malformed_messages_ignored(store, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    n = make_notifier()
    assert run(n.handle({})) == []
    assert run(n.handle({"type": "new", "after": {"severity": "alert"}})) == []


def test_unregistered_on_410(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    add_device(store, TOKEN_B, ["alert"])
    sender.responses[TOKEN_A] = ApnsResult(False, 410, "Unregistered")
    assert run(make_notifier().handle(message("new"))) == [TOKEN_B]
    assert store.get_device(TOKEN_A) is None
    assert store.get_device(TOKEN_B) is not None


def test_bad_token_reasons_remove_device(store, sender, make_notifier):
    for i, reason in enumerate(["BadDeviceToken", "DeviceTokenNotForTopic"]):
        add_device(store, TOKEN_A, ["alert"])
        sender.responses[TOKEN_A] = ApnsResult(False, 400, reason)
        run(make_notifier().handle(message("new", id=f"r{i}")))
        assert store.get_device(TOKEN_A) is None


def test_other_failures_keep_device(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    sender.responses[TOKEN_A] = ApnsResult(False, 429, "TooManyRequests")
    assert run(make_notifier().handle(message("new"))) == []
    assert store.get_device(TOKEN_A) is not None
    sender.responses[TOKEN_A] = ApnsResult(False, 400, "PayloadTooLarge")
    run(make_notifier().handle(message("new", id="r2")))
    assert store.get_device(TOKEN_A) is not None


def test_sender_exception_does_not_break_others(store, sender, make_notifier):
    add_device(store, TOKEN_A, ["alert"])
    add_device(store, TOKEN_B, ["alert"])

    original = sender.send

    async def flaky(device, payload, cid):
        if device["token"] == TOKEN_A:
            raise ConnectionError("boom")
        return await original(device, payload, cid)

    sender.send = flaky
    assert run(make_notifier().handle(message("new"))) == [TOKEN_B]
    assert store.get_device(TOKEN_A) is not None
