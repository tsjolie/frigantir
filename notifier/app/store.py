"""SQLite storage for registered devices and the notification dedupe record."""

from __future__ import annotations

import json
import sqlite3
import threading
import time

DEDUPE_TTL = 24 * 3600

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    token       TEXT PRIMARY KEY,
    environment TEXT NOT NULL,
    bundle_id   TEXT NOT NULL,
    device_name TEXT NOT NULL DEFAULT '',
    severities  TEXT NOT NULL,
    cameras     TEXT NOT NULL,
    ignore_verified INTEGER NOT NULL DEFAULT 0,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS notified (
    review_id TEXT NOT NULL,
    token     TEXT NOT NULL,
    ts        REAL NOT NULL,
    PRIMARY KEY (review_id, token)
);
CREATE INDEX IF NOT EXISTS notified_ts ON notified(ts);
CREATE TABLE IF NOT EXISTS reviews (
    review_id  TEXT PRIMARY KEY,
    thumb_path TEXT NOT NULL,
    ts         REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS reviews_ts ON reviews(ts);
"""


def short_token(token: str) -> str:
    """Truncated device token, safe for logs."""
    return token[:8] + "…" if len(token) > 8 else token


class Store:
    def __init__(self, path: str = ":memory:"):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(SCHEMA)
            # Databases created before the column existed.
            columns = {row["name"] for row in self._db.execute("PRAGMA table_info(devices)")}
            if "ignore_verified" not in columns:
                self._db.execute("ALTER TABLE devices ADD COLUMN ignore_verified INTEGER NOT NULL DEFAULT 0")

    # --- devices -----------------------------------------------------------
    @staticmethod
    def _row(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["severities"] = json.loads(d["severities"])
        d["cameras"] = json.loads(d["cameras"])
        d["ignore_verified"] = bool(d["ignore_verified"])
        return d

    def upsert_device(self, token: str, environment: str, bundle_id: str, device_name: str,
                      severities: list[str], cameras: list[str], ignore_verified: bool = False) -> dict:
        now = time.time()
        with self._lock:
            self._db.execute(
                """INSERT INTO devices (token, environment, bundle_id, device_name, severities, cameras,
                                        ignore_verified, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(token) DO UPDATE SET environment=excluded.environment,
                       bundle_id=excluded.bundle_id, device_name=excluded.device_name,
                       severities=excluded.severities, cameras=excluded.cameras,
                       ignore_verified=excluded.ignore_verified, updated_at=excluded.updated_at""",
                (token, environment, bundle_id, device_name, json.dumps(severities),
                 json.dumps(cameras), int(ignore_verified), now, now),
            )
        return self.get_device(token)  # type: ignore[return-value]

    def get_device(self, token: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM devices WHERE token = ?", (token,)).fetchone()
        return self._row(row) if row else None

    def list_devices(self) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM devices ORDER BY created_at").fetchall()
        return [self._row(r) for r in rows]

    def count_devices(self) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM devices").fetchone()[0]

    def delete_device(self, token: str) -> bool:
        with self._lock:
            cur = self._db.execute("DELETE FROM devices WHERE token = ?", (token,))
            self._db.execute("DELETE FROM notified WHERE token = ?", (token,))
        return cur.rowcount > 0

    # --- dedupe ------------------------------------------------------------
    def was_notified(self, review_id: str, token: str) -> bool:
        with self._lock:
            row = self._db.execute(
                "SELECT 1 FROM notified WHERE review_id = ? AND token = ?", (review_id, token)
            ).fetchone()
        return row is not None

    def claim(self, review_id: str, token: str, now: float | None = None) -> bool:
        """Atomically record a notification; returns False if it was already recorded."""
        with self._lock:
            cur = self._db.execute(
                "INSERT OR IGNORE INTO notified (review_id, token, ts) VALUES (?, ?, ?)",
                (review_id, token, now or time.time()),
            )
        return cur.rowcount == 1

    def prune(self, now: float | None = None) -> None:
        cutoff = (now or time.time()) - DEDUPE_TTL
        with self._lock:
            self._db.execute("DELETE FROM notified WHERE ts < ?", (cutoff,))
            self._db.execute("DELETE FROM reviews WHERE ts < ?", (cutoff,))

    # --- review thumbnails ---------------------------------------------------
    def remember_review(self, review_id: str, thumb_path: str, now: float | None = None) -> None:
        with self._lock:
            self._db.execute(
                """INSERT INTO reviews (review_id, thumb_path, ts) VALUES (?, ?, ?)
                   ON CONFLICT(review_id) DO UPDATE SET thumb_path=excluded.thumb_path, ts=excluded.ts""",
                (review_id, thumb_path, now or time.time()),
            )

    def thumb_path(self, review_id: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT thumb_path FROM reviews WHERE review_id = ?",
                                   (review_id,)).fetchone()
        return row[0] if row else None
