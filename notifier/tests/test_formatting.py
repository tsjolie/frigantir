from app.apns import collapse_id
from app.formatting import review_body, review_payload, test_payload, title_case

from .conftest import review


def test_title_case():
    assert title_case("front_door") == "Front Door"
    assert title_case("garage") == "Garage"
    assert title_case("back_yard_cam2") == "Back Yard Cam2"


def test_alert_body_with_sub_labels_and_zones():
    assert review_body(review()) == "Person (Alice) · Driveway"


def test_objects_and_audio_joined():
    r = review(data={"objects": ["person", "car"], "audio": ["speech"], "sub_labels": [], "zones": []})
    assert review_body(r) == "Person, Car, Speech"


def test_multiple_zones_title_cased():
    r = review(data={"sub_labels": [], "zones": ["front_yard", "porch"]})
    assert review_body(r) == "Person · Front Yard, Porch"


def test_detection_prefix():
    r = review(severity="detection", data={"sub_labels": []})
    assert review_body(r) == "Detection: Person · Driveway"


def test_no_labels():
    empty = {"objects": [], "audio": [], "sub_labels": [], "zones": []}
    assert review_body(review(data=empty)) == "Alert"
    assert review_body(review(severity="detection", data=empty)) == "Detection"


def test_sub_label_pairs_tolerated():
    r = review(data={"sub_labels": [["Alice", 0.9]], "zones": []})
    assert review_body(r) == "Person (Alice)"


def test_review_payload_shape():
    p = review_payload(review())
    assert p == {
        "aps": {"alert": {"title": "Front Door", "body": "Person (Alice) · Driveway"},
                "sound": "default", "thread-id": "front_door", "category": "FRIGATE_REVIEW",
                "mutable-content": 1},
        "frigate": {"review_id": "1791293688.0-abc123", "camera": "front_door", "severity": "alert",
                    "start_time": 1791293688.0,
                    "thumb_path": "/media/frigate/clips/review/thumb-front_door-1791293688.0-abc123.webp",
                    "labels": ["person"], "sub_labels": ["Alice"], "zones": ["driveway"]},
    }


def test_test_payload():
    p = test_payload()
    assert p["aps"]["alert"] == {"title": "Frigantir",
                                 "body": "Test notification — notifications are working."}
    assert p["frigate"] == {"test": True}


def test_collapse_id_truncated_to_64_bytes():
    assert collapse_id("x" * 100) == "x" * 64
    assert len(collapse_id("é" * 40).encode()) <= 64
