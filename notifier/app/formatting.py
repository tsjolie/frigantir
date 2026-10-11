"""Builds APNs payloads from Frigate review items."""

from __future__ import annotations

from typing import Any

CATEGORY = "FRIGATE_REVIEW"


def title_case(name: str) -> str:
    """'front_door' -> 'Front Door'."""
    return " ".join(w[:1].upper() + w[1:] for w in str(name).replace("_", " ").split())


def _strings(values: Any) -> list[str]:
    """Unique, non-empty strings, order preserved. Tolerates [name, score] pairs."""
    out: list[str] = []
    for v in values or []:
        if isinstance(v, (list, tuple)):
            v = v[0] if v else ""
        v = str(v).strip()
        if v and v not in out:
            out.append(v)
    return out


def _labels(data: dict) -> list[str]:
    return list(dict.fromkeys(_strings(data.get("objects")) + _strings(data.get("audio"))))


def review_body(review: dict) -> str:
    data = review.get("data") or {}
    severity = review.get("severity", "alert")
    labels = _labels(data)
    sub_labels = _strings(data.get("sub_labels"))
    zones = _strings(data.get("zones"))

    if labels:
        text = ", ".join(title_case(label) for label in labels)
    else:
        text = "Detection" if severity == "detection" else "Alert"
    if sub_labels:
        text += f" ({', '.join(sub_labels)})"
    if zones:
        text += " · " + ", ".join(title_case(z) for z in zones)
    if severity == "detection" and labels:
        text = "Detection: " + text
    return text


def review_payload(review: dict, thumbnail_url: str | None = None) -> dict:
    data = review.get("data") or {}
    camera = review.get("camera", "")
    payload = {
        "aps": {
            "alert": {"title": title_case(camera), "body": review_body(review)},
            "sound": "default",
            "thread-id": camera,
            "category": CATEGORY,
            "mutable-content": 1,
        },
        "frigate": {
            "review_id": review.get("id"),
            "camera": camera,
            "severity": review.get("severity"),
            "start_time": review.get("start_time"),
            "thumb_path": review.get("thumb_path"),
            "labels": _labels(data),
            "sub_labels": _strings(data.get("sub_labels")),
            "zones": _strings(data.get("zones")),
        },
    }
    if thumbnail_url:
        payload["frigate"]["thumbnail_url"] = thumbnail_url
    return payload


def test_payload() -> dict:
    return {
        "aps": {
            "alert": {
                "title": "Frigantir",
                "body": "Test notification — notifications are working.",
            },
            "sound": "default",
        },
        "frigate": {"test": True},
    }


# keep pytest from collecting test_payload as a test when imported into test modules
test_payload.__test__ = False  # type: ignore[attr-defined]
