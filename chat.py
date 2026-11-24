#!/usr/bin/env python3
"""Minimal interactive chat client for FAU CoECS Trussed AI completions."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_ENDPOINT = "https://trussed.eng.fau.edu/provider/generic/chat/completions"
PORTAL_URL = "https://trussedportal.hpc.fau.edu/"
SUPPORT_EMAIL = "help@eng.fau.edu"
PROVIDERS = ("chatgpt", "gemini", "faullm")


def load_dotenv(path: Path | None = None) -> None:
    """Load KEY=VALUE pairs from a .env file into os.environ (only if unset)."""
    env_path = path or Path.cwd() / ".env"
    if not env_path.is_file():
        return
    with env_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Hello World chat with FAU CoECS Trussed AI (OpenAI-compatible API)."
    )
    parser.add_argument(
        "--provider",
        choices=PROVIDERS,
        default=os.environ.get("TRUSSED_PROVIDER", "").strip().lower() or None,
        help="LLM profile from .env: chatgpt, gemini, or faullm (default: env TRUSSED_PROVIDER)",
    )
    parser.add_argument(
        "--endpoint",
        default=None,
        help=f"Chat completions URL override (default: profile URL or {DEFAULT_ENDPOINT})",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Model name override (default: profile model or env TRUSSED_MODEL)",
    )
    parser.add_argument(
        "--list-models",
        action="store_true",
        help="Query the /models endpoint for the selected provider and exit.",
    )
    parser.add_argument(
        "--once",
        metavar="PROMPT",
        help="Single-turn mode: send one prompt and print the reply, then exit.",
    )
    return parser.parse_args(argv)


def resolve_config(args: argparse.Namespace) -> tuple[str | None, str, str, str | None]:
    """Resolve (provider, endpoint, api_key, model) from CLI args and env vars."""
    raw_provider = getattr(args, "provider", None)
    provider = raw_provider.lower() if raw_provider else None
    prefix = provider.upper() if provider else None

    endpoint = (
        args.endpoint
        or (os.environ.get(f"{prefix}_API_URL", "").strip() if prefix else "")
        or os.environ.get("TRUSSED_API_URL", "").strip()
        or DEFAULT_ENDPOINT
    )
    api_key = (
        (os.environ.get(f"{prefix}_API_KEY", "").strip() if prefix else "")
        or os.environ.get("TRUSSED_API_KEY", "").strip()
    )
    model = (
        args.model
        or (os.environ.get(f"{prefix}_MODEL", "").strip() if prefix else "")
        or os.environ.get("TRUSSED_MODEL", "").strip()
        or None
    )
    return provider, endpoint, api_key, model


def require_api_key(api_key: str | None = None, provider: str | None = None) -> str:
    key = (api_key if api_key is not None else os.environ.get("TRUSSED_API_KEY", "")).strip()
    if not key:
        var_name = f"{provider.upper()}_API_KEY" if provider else "TRUSSED_API_KEY"
        print(
            f"Error: {var_name} is not set.\n\n"
            f"Create an API key at {PORTAL_URL}\n"
            "(FAU SSO login → select your course/project → Create API Key).\n"
            "Store the key in an environment variable or a local .env file "
            "(never commit it to Git).\n"
            f"Questions? {SUPPORT_EMAIL}",
            file=sys.stderr,
        )
        sys.exit(1)
    return key


def require_model(model: str | None, provider: str | None = None) -> str:
    if not model or not model.strip():
        var_name = f"{provider.upper()}_MODEL" if provider else "TRUSSED_MODEL"
        print(
            "Error: No model specified.\n\n"
            f"Set {var_name} to the model name assigned to your project, "
            "or pass --model <name>.\n"
            "Tip: run with --list-models to see what your key can access.\n"
            f"See your project in the portal: {PORTAL_URL}\n"
            f"Questions? {SUPPORT_EMAIL}",
            file=sys.stderr,
        )
        sys.exit(1)
    return model.strip()


def build_payload(model: str, messages: list[dict[str, str]]) -> bytes:
    body = {"model": model, "messages": messages}
    return json.dumps(body).encode("utf-8")


def models_url_from_endpoint(endpoint: str) -> str:
    if endpoint.endswith("/chat/completions"):
        return endpoint[: -len("/chat/completions")] + "/models"
    return endpoint.rstrip("/") + "/models"


def list_models(
    endpoint: str,
    api_key: str,
    *,
    opener: urllib.request.OpenerDirector | None = None,
) -> list[str]:
    """Query the /models endpoint and return available model IDs."""
    url = models_url_from_endpoint(endpoint)
    req = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
        },
    )
    open_fn = opener.open if opener else urllib.request.urlopen
    try:
        with open_fn(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise ChatAPIError(format_http_error(e.code, body, url)) from e
    except urllib.error.URLError as e:
        raise ChatAPIError(f"Network error: {e.reason}") from e

    parsed = json.loads(raw)
    return [item["id"] for item in parsed.get("data", []) if "id" in item]


def chat_completion(
    endpoint: str,
    api_key: str,
    model: str,
    messages: list[dict[str, str]],
    *,
    opener: urllib.request.OpenerDirector | None = None,
) -> str:
    """POST chat completion and return assistant message content."""
    data = build_payload(model, messages)
    req = urllib.request.Request(
        endpoint,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    open_fn = opener.open if opener else urllib.request.urlopen
    try:
        with open_fn(req, timeout=120) as resp:
            raw = resp.read().decode("utf-8")
            status = getattr(resp, "status", 200)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        diag = format_http_error(e.code, body, endpoint)
        raise ChatAPIError(diag) from e
    except urllib.error.URLError as e:
        raise ChatAPIError(f"Network error: {e.reason}") from e

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ChatAPIError(f"Invalid JSON in response (HTTP {status}): {raw[:500]}") from e

    try:
        return parsed["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as e:
        raise ChatAPIError(
            f"Unexpected response shape (HTTP {status}): {json.dumps(parsed)[:500]}"
        ) from e


class ChatAPIError(Exception):
    """Raised when the API call fails."""


def format_http_error(code: int, body: str, endpoint: str) -> str:
    lines = [
        f"HTTP {code} from {endpoint}",
        f"Response body: {body[:2000] if body else '(empty)'}",
    ]
    if code in (401, 403, 404):
        lines.append(
            "Tip: Verify TRUSSED_API_KEY (or provider key) and TRUSSED_MODEL (or provider model) match your project "
            f"at {PORTAL_URL}. A new key disables the previous one."
        )
    return "\n".join(lines)


def run_once(
    endpoint: str,
    api_key: str,
    model: str,
    prompt: str,
    *,
    opener: urllib.request.OpenerDirector | None = None,
) -> None:
    messages = [{"role": "user", "content": prompt}]
    reply = chat_completion(endpoint, api_key, model, messages, opener=opener)
    print(reply)


def run_interactive(
    endpoint: str,
    api_key: str,
    model: str,
    *,
    provider: str | None = None,
    opener: urllib.request.OpenerDirector | None = None,
) -> None:
    messages: list[dict[str, str]] = []
    print("Trussed AI chat (stdlib demo). Commands: /clear, /exit")
    if provider:
        print(f"Provider: {provider}")
    print(f"Model: {model}")
    print()

    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye.")
            break

        if not user_input:
            continue
        if user_input == "/exit":
            print("Goodbye.")
            break
        if user_input == "/clear":
            messages.clear()
            print("(conversation cleared)")
            continue

        messages.append({"role": "user", "content": user_input})
        try:
            reply = chat_completion(
                endpoint, api_key, model, messages, opener=opener
            )
        except ChatAPIError as e:
            print(f"\nAssistant: (error)\n{e}", file=sys.stderr)
            messages.pop()
            continue

        messages.append({"role": "assistant", "content": reply})
        print(f"\nAssistant: {reply}\n")


def main(argv: list[str] | None = None) -> None:
    load_dotenv()
    args = parse_args(argv)
    provider, endpoint, raw_key, raw_model = resolve_config(args)
    api_key = require_api_key(raw_key, provider=provider)

    if getattr(args, "list_models", False):
        try:
            models = list_models(endpoint, api_key)
        except ChatAPIError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        for m in models:
            print(m)
        return

    model = require_model(raw_model, provider=provider)

    if args.once is not None:
        run_once(endpoint, api_key, model, args.once)
    else:
        run_interactive(endpoint, api_key, model, provider=provider)


if __name__ == "__main__":
    main()
