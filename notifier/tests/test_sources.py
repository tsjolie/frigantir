import json

from app.sources import decode_review, decode_ws_message, ws_url

from .conftest import message


def test_ws_payload_as_json_string():
    msg = message("new")
    frame = json.dumps({"topic": "reviews", "payload": json.dumps(msg)})
    assert decode_ws_message(frame) == msg


def test_ws_payload_as_object():
    msg = message("new")
    frame = json.dumps({"topic": "reviews", "payload": msg})
    assert decode_ws_message(frame) == msg


def test_ws_other_topics_and_garbage_ignored():
    assert decode_ws_message(json.dumps({"topic": "events", "payload": "{}"})) is None
    assert decode_ws_message("not json") is None
    assert decode_ws_message(json.dumps(["reviews"])) is None
    assert decode_ws_message(json.dumps({"topic": "reviews", "payload": "nope"})) is None


def test_mqtt_payload_bytes():
    msg = message("new")
    assert decode_review(json.dumps(msg).encode()) == msg
    assert decode_review(b"\xff") is None


def test_ws_url():
    assert ws_url("http://frigate:5000") == "ws://frigate:5000/ws"
    assert ws_url("https://nvr.example.com") == "wss://nvr.example.com/ws"


def test_websocket_source_end_to_end():
    """Real websocket server on localhost: frames are decoded and dispatched, state tracked."""
    import asyncio

    from websockets.asyncio.server import serve

    from app.config import Settings
    from app.sources import SourceState, run_websocket

    msg = message("new")

    async def scenario():
        async def ws_handler(ws):
            await ws.send(json.dumps({"topic": "events", "payload": "{}"}))
            await ws.send(json.dumps({"topic": "reviews", "payload": json.dumps(msg)}))
            await ws.wait_closed()

        received = asyncio.Queue()

        async def handler(review):
            await received.put(review)

        async with serve(ws_handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            settings = Settings(api_token="t", apns_key_id="k", apns_team_id="t", apns_key="",
                                source="websocket", frigate_url=f"http://127.0.0.1:{port}")
            state = SourceState("websocket")
            task = asyncio.create_task(run_websocket(settings, state, handler))
            try:
                got = await asyncio.wait_for(received.get(), 5)
                assert got == msg and state.connected
            finally:
                task.cancel()

    asyncio.run(scenario())
