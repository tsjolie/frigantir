import pytest

from app.config import ConfigError, Settings

BASE = {"API_TOKEN": "t", "APNS_KEY_ID": "k", "APNS_TEAM_ID": "team", "APNS_KEY": "pem", "MQTT_HOST": "mqtt"}


def test_defaults():
    s = Settings.from_env(BASE)
    assert s.source == "mqtt" and s.mqtt_port == 1883 and s.mqtt_topic_prefix == "frigate"
    assert s.port == 8080 and s.data_dir == "/data" and s.cooldown_seconds == 0
    assert s.apns_bundle_id == "net.sjolie.frigateapp" and s.frigate_verify_tls is True


def test_missing_required_lists_everything():
    with pytest.raises(ConfigError) as exc:
        Settings.from_env({})
    msg = str(exc.value)
    for key in ("API_TOKEN", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_KEY_FILE", "MQTT_HOST"):
        assert key in msg


def test_websocket_requires_frigate_url():
    env = {**BASE, "SOURCE": "websocket"}
    with pytest.raises(ConfigError, match="FRIGATE_URL"):
        Settings.from_env(env)
    s = Settings.from_env({**env, "FRIGATE_URL": "https://nvr/", "FRIGATE_VERIFY_TLS": "false"})
    assert s.frigate_url == "https://nvr" and s.frigate_verify_tls is False


def test_key_file_and_lists(tmp_path):
    key = tmp_path / "AuthKey.p8"
    key.write_text("PEM")
    env = {**BASE, "APNS_KEY": "", "APNS_KEY_FILE": str(key), "CAMERAS": "front_door, garage,",
           "COOLDOWN_SECONDS": "30"}
    s = Settings.from_env(env)
    assert s.apns_key == "PEM" and s.cameras == ["front_door", "garage"] and s.cooldown_seconds == 30


def test_bad_values():
    with pytest.raises(ConfigError):
        Settings.from_env({**BASE, "SOURCE": "kafka"})
    with pytest.raises(ConfigError):
        Settings.from_env({**BASE, "PORT": "eighty"})
