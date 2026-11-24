#!/usr/bin/env python3
"""Unit tests for chat.py using a local mock HTTP server."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

# Repo root on sys.path for `import chat`
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import chat  # noqa: E402


class MockState:
    last_request: dict | None = None
    response_status: int = 200
    response_body: dict | None = None
    fail_next: bool = False


def default_success_body() -> dict:
    return {
        "choices": [{"message": {"role": "assistant", "content": "Hello from Trussed!"}}]
    }


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        MockState.last_request = {
            "path": self.path,
            "headers": dict(self.headers),
            "body": json.loads(raw.decode("utf-8")),
        }
        status = MockState.response_status
        body = MockState.response_body or default_success_body()
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)


def start_mock_server() -> tuple[HTTPServer, str]:
    server = HTTPServer(("127.0.0.1", 0), MockHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{port}/v1/chat/completions"


class ChatTests(unittest.TestCase):
    def setUp(self) -> None:
        MockState.last_request = None
        MockState.response_status = 200
        MockState.response_body = None
        self.server, self.endpoint = start_mock_server()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def test_request_headers_and_payload(self) -> None:
        messages = [{"role": "user", "content": "Hi"}]
        chat.chat_completion(
            self.endpoint, "test-secret-key", "demo-model", messages
        )
        self.assertIsNotNone(MockState.last_request)
        req = MockState.last_request
        auth = req["headers"].get("Authorization") or req["headers"].get("authorization")
        self.assertEqual(auth, "Bearer test-secret-key")
        ctype = req["headers"].get("Content-Type") or req["headers"].get("content-type")
        self.assertIn("application/json", ctype)
        self.assertEqual(req["body"]["model"], "demo-model")
        self.assertEqual(req["body"]["messages"], messages)

    def test_multi_turn_history(self) -> None:
        history = [
            {"role": "user", "content": "First"},
            {"role": "assistant", "content": "Reply one"},
            {"role": "user", "content": "Second"},
        ]
        chat.chat_completion(self.endpoint, "key", "m", history)
        self.assertEqual(MockState.last_request["body"]["messages"], history)

    def test_http_401_error_message(self) -> None:
        MockState.response_status = 401
        MockState.response_body = {"error": "unauthorized"}
        with self.assertRaises(chat.ChatAPIError) as ctx:
            chat.chat_completion(
                self.endpoint, "bad", "m", [{"role": "user", "content": "x"}]
            )
        msg = str(ctx.exception)
        self.assertIn("HTTP 401", msg)
        self.assertIn("TRUSSED_API_KEY", msg)
        self.assertIn(chat.PORTAL_URL, msg)

    def test_http_403_error_message(self) -> None:
        MockState.response_status = 403
        MockState.response_body = {"error": "forbidden"}
        with self.assertRaises(chat.ChatAPIError) as ctx:
            chat.chat_completion(
                self.endpoint, "k", "wrong-model", [{"role": "user", "content": "x"}]
            )
        msg = str(ctx.exception)
        self.assertIn("HTTP 403", msg)
        self.assertIn("TRUSSED_MODEL", msg)

    def test_invalid_json_response(self) -> None:
        class BrokenHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_POST(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"not json")

        server = HTTPServer(("127.0.0.1", 0), BrokenHandler)
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{port}/"
        try:
            with self.assertRaises(chat.ChatAPIError) as ctx:
                chat.chat_completion(url, "k", "m", [{"role": "user", "content": "x"}])
            self.assertIn("Invalid JSON", str(ctx.exception))
        finally:
            server.shutdown()
            server.server_close()

    def test_once_mode_prints_reply(self) -> None:
        buf = io.StringIO()
        with patch.dict(
            os.environ,
            {"TRUSSED_API_KEY": "k", "TRUSSED_MODEL": "m"},
            clear=False,
        ):
            with patch("sys.stdout", buf):
                with patch.object(
                    chat,
                    "parse_args",
                    return_value=argparse_ns(
                        endpoint=self.endpoint, model="m", once="Say hello"
                    ),
                ):
                    chat.main([])
        self.assertIn("Hello from Trussed!", buf.getvalue())
        self.assertEqual(
            MockState.last_request["body"]["messages"],
            [{"role": "user", "content": "Say hello"}],
        )

    def test_missing_api_key_exits(self) -> None:
        env = {k: v for k, v in os.environ.items() if k != "TRUSSED_API_KEY"}
        with patch.dict(os.environ, env, clear=True):
            buf = io.StringIO()
            with patch("sys.stderr", buf):
                with self.assertRaises(SystemExit) as cm:
                    chat.require_api_key()
                self.assertEqual(cm.exception.code, 1)
            self.assertIn(chat.PORTAL_URL, buf.getvalue())

    def test_missing_model_exits(self) -> None:
        buf = io.StringIO()
        with patch("sys.stderr", buf):
            with self.assertRaises(SystemExit) as cm:
                chat.require_model(None)
            self.assertEqual(cm.exception.code, 1)
        self.assertIn("TRUSSED_MODEL", buf.getvalue())

    def test_load_dotenv_sets_unset_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            env_file.write_text(
                "TRUSSED_API_KEY=from-file\nTRUSSED_MODEL=file-model\n",
                encoding="utf-8",
            )
            with patch.dict(os.environ, {}, clear=True):
                chat.load_dotenv(env_file)
                self.assertEqual(os.environ.get("TRUSSED_API_KEY"), "from-file")
                self.assertEqual(os.environ.get("TRUSSED_MODEL"), "file-model")

    def test_load_dotenv_does_not_override_existing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            env_file.write_text("TRUSSED_API_KEY=from-file\n", encoding="utf-8")
            with patch.dict(
                os.environ, {"TRUSSED_API_KEY": "already-set"}, clear=True
            ):
                chat.load_dotenv(env_file)
                self.assertEqual(os.environ["TRUSSED_API_KEY"], "already-set")

    def test_build_payload(self) -> None:
        raw = chat.build_payload("m", [{"role": "user", "content": "a"}])
        parsed = json.loads(raw)
        self.assertEqual(parsed, {"model": "m", "messages": [{"role": "user", "content": "a"}]})


def argparse_ns(**kwargs):
  class NS:
      pass
  ns = NS()
  for k, v in kwargs.items():
      setattr(ns, k, v)
  return ns


if __name__ == "__main__":
    unittest.main()