"""Settings loaded from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(Exception):
    pass


def _bool(value: str | None, default: bool) -> bool:
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


def _list(value: str | None) -> list[str]:
    return [v.strip() for v in (value or "").split(",") if v.strip()]


@dataclass
class Settings:
    api_token: str
    apns_key_id: str
    apns_team_id: str
    apns_key: str  # PEM contents of the .p8 key
    apns_bundle_id: str = "net.sjolie.frigateapp"
    source: str = "mqtt"
    mqtt_host: str = ""
    mqtt_port: int = 1883
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    mqtt_topic_prefix: str = "frigate"
    mqtt_tls: bool = False
    frigate_url: str = ""
    frigate_username: str | None = None
    frigate_password: str | None = None
    frigate_verify_tls: bool = True
    public_url: str = ""
    cameras: list[str] = field(default_factory=list)
    cooldown_seconds: int = 0
    data_dir: str = "/data"
    port: int = 8080
    log_level: str = "INFO"

    @property
    def thumbnails_enabled(self) -> bool:
        return bool(self.public_url and self.frigate_url)

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        env = dict(os.environ if env is None else env)
        get = lambda k, d=None: (env.get(k) or "").strip() or d  # noqa: E731
        errors: list[str] = []

        source = (get("SOURCE", "mqtt")).lower()
        if source not in ("mqtt", "websocket"):
            errors.append("SOURCE must be 'mqtt' or 'websocket'")

        for key in ("API_TOKEN", "APNS_KEY_ID", "APNS_TEAM_ID"):
            if not get(key):
                errors.append(f"{key} is required")

        key_pem = get("APNS_KEY")
        key_file = get("APNS_KEY_FILE")
        if key_pem:
            key_pem = key_pem.replace("\\n", "\n")
        elif key_file:
            try:
                key_pem = Path(key_file).read_text()
            except OSError as exc:
                errors.append(f"APNS_KEY_FILE could not be read: {exc}")
        else:
            errors.append("APNS_KEY_FILE (path to .p8) or APNS_KEY (PEM contents) is required")

        if source == "mqtt" and not get("MQTT_HOST"):
            errors.append("MQTT_HOST is required when SOURCE=mqtt")
        if source == "websocket" and not get("FRIGATE_URL"):
            errors.append("FRIGATE_URL is required when SOURCE=websocket")

        def as_int(key: str, default: int) -> int:
            try:
                return int(get(key, str(default)))
            except ValueError:
                errors.append(f"{key} must be an integer")
                return default

        settings = cls(
            api_token=get("API_TOKEN", ""),
            apns_key_id=get("APNS_KEY_ID", ""),
            apns_team_id=get("APNS_TEAM_ID", ""),
            apns_key=key_pem or "",
            apns_bundle_id=get("APNS_BUNDLE_ID", "net.sjolie.frigateapp"),
            source=source,
            mqtt_host=get("MQTT_HOST", ""),
            mqtt_port=as_int("MQTT_PORT", 1883),
            mqtt_username=get("MQTT_USERNAME"),
            mqtt_password=get("MQTT_PASSWORD"),
            mqtt_topic_prefix=get("MQTT_TOPIC_PREFIX", "frigate").rstrip("/"),
            mqtt_tls=_bool(env.get("MQTT_TLS"), False),
            frigate_url=get("FRIGATE_URL", "").rstrip("/"),
            frigate_username=get("FRIGATE_USERNAME"),
            frigate_password=get("FRIGATE_PASSWORD"),
            frigate_verify_tls=_bool(env.get("FRIGATE_VERIFY_TLS"), True),
            public_url=get("PUBLIC_URL", "").rstrip("/"),
            cameras=_list(env.get("CAMERAS")),
            cooldown_seconds=as_int("COOLDOWN_SECONDS", 0),
            data_dir=get("DATA_DIR", "/data"),
            port=as_int("PORT", 8080),
            log_level=get("LOG_LEVEL", "INFO").upper(),
        )
        for key in ("FRIGATE_URL", "PUBLIC_URL"):
            if get(key) and not get(key).startswith(("http://", "https://")):
                errors.append(f"{key} must start with http:// or https://")
        if errors:
            raise ConfigError("Invalid configuration:\n  - " + "\n  - ".join(errors))
        return settings
