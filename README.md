# Trussed AI Hello World Chat

A minimal **Python 3** command-line chat demo for the FAU CoECS **Trussed AI** OpenAI-compatible chat completions API. It uses only the standard library (`urllib`, `json`, `argparse`) so you can run it with:

```bash
python3 chat.py
```

No `pip install` required.

## API key and model

1. Sign in at the [LLM Self-Service Portal](https://trussedportal.hpc.fau.edu/) with **FAU SSO**.
2. Select your assigned course/project.
3. Click **Create API Key**. The key is shown **only once** — copy it immediately.

**Security**

- Do **not** hardcode the key in source code, paste it in chat/email, or commit it to Git.
- Store it in `TRUSSED_API_KEY` or a local `.env` file (see below).
- Each key works only with the **endpoint** and **model names** assigned to your project.
- Creating a new key for the same project **disables** the previous key.

Support: [help@eng.fau.edu](mailto:help@eng.fau.edu)

## Setup

Copy the example env file and add your values:

```bash
cp .env.example .env
# Edit .env: set TRUSSED_API_KEY and TRUSSED_MODEL from the portal
```

Or export variables in your shell:

```bash
export TRUSSED_API_KEY='your-key'
export TRUSSED_MODEL='your-assigned-model-name'
```

Optional:

| Variable | Purpose |
|----------|---------|
| `TRUSSED_API_URL` | Override API URL (default: `https://trussed.eng.fau.edu/provider/generic/chat/completions`) |
| `TRUSSED_MODEL` | Model name from your project |
| `TRUSSED_API_KEY` | API key from the portal |

CLI flags override env where noted:

- `--endpoint` — same as `TRUSSED_API_URL`
- `--model` — same as `TRUSSED_MODEL`

## Usage

**Interactive chat**

```bash
python3 chat.py
```

- `/clear` — reset conversation history  
- `/exit` — quit (also **Ctrl+C** or **EOF**)

**Single-turn smoke test**

```bash
python3 chat.py --once "Hello, world!"
```

## How it works

Each turn sends a `POST` with:

- `Authorization: Bearer <TRUSSED_API_KEY>`
- `Content-Type: application/json`
- JSON body: `{ "model": "<name>", "messages": [ ... ] }`

User and assistant messages are kept in `messages` across turns so the API sees full context.

On HTTP errors, the client prints the status code, response body (truncated), and—for **401**, **403**, or **404**—a reminder to check your key and model in the portal.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

Tests spin up a local mock HTTP server to verify headers, payload shape, multi-turn history, error text, `--once` behavior, and `.env` loading—without calling the real Trussed endpoint.

## Files

| File | Description |
|------|-------------|
| `chat.py` | CLI and API client |
| `.env.example` | Template for local secrets |
| `.gitignore` | Ignores `.env` and bytecode |
| `tests/test_chat.py` | Unit tests |

## License

Educational demo for FAU CoECS Trussed AI self-service. Use according to your course/project policies.