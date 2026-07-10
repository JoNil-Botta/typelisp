#!/usr/bin/env sh
set -eu

# measure-lsp-check-latency.sh - exercise interactive LSP tl/check latency.
#
# This intentionally uses a single persistent `typelisp lsp` process.  Each
# document begins invalid, receives an unchanged tl/check, is edited to valid
# source, then receives another tl/check.  The request timers therefore cover
# the normal LSP queue after didOpen/didChange, while the unchanged request
# demonstrates the document-result cache.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

# MSYS can execute a Windows .exe even when its POSIX executable bit is not
# represented in the checkout.  Keep the ordinary executable check for other
# paths while accepting a regular file for that host case.
if [ ! -x "$COMPILER" ] && [ ! -f "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

if [ -n "${TYPELISP_PYTHON:-}" ]; then
    PYTHON=$TYPELISP_PYTHON
elif command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1; then
    PYTHON=python
else
    echo "measure-lsp-check-latency.sh requires Python 3 for interactive JSON-RPC framing" >&2
    exit 1
fi

WORKDIR=${TYPELISP_LSP_CHECK_WORKDIR:-target/lsp-check-latency}
SMALL_LINES=${TYPELISP_LSP_CHECK_SMALL_LINES:-500}
LARGE_LINES=${TYPELISP_LSP_CHECK_LARGE_LINES:-6000}

case "$SMALL_LINES" in
    ''|*[!0-9]*)
        echo "LSP benchmark line counts must be positive integers" >&2
        exit 1
        ;;
esac
case "$LARGE_LINES" in
    ''|*[!0-9]*)
        echo "LSP benchmark line counts must be positive integers" >&2
        exit 1
        ;;
esac
if [ "$SMALL_LINES" -le 2 ] || [ "$LARGE_LINES" -le 2 ]; then
    echo "LSP benchmark line counts must be greater than 2" >&2
    exit 1
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

exec "$PYTHON" - "$COMPILER" "$ROOT" "$WORKDIR" "$SMALL_LINES" "$LARGE_LINES" <<'PY'
import json
import re
import subprocess
import sys
import time
from pathlib import Path


compiler, root, workdir_text, small_lines_text, large_lines_text = sys.argv[1:]
root_path = Path(root)
workdir = Path(workdir_text)
small_lines = int(small_lines_text)
large_lines = int(large_lines_text)


def make_source(label, line_count):
    lines = ["(import stdlib.string)", ""]
    for index in range(1, line_count - 1):
        lines.append(f"(define benchmark_{label}_{index} : i64 {index})")
    return "\n".join(lines) + "\n"


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


class LspClient:
    def __init__(self):
        self.process = subprocess.Popen(
            [
                compiler,
                "lsp",
                "--stdlib-root",
                str(root_path / "stdlib"),
                "--prefix-cache-stats",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.next_id = 1

    def send(self, message):
        assert self.process.stdin is not None
        self.process.stdin.write(frame(message))
        self.process.stdin.flush()

    def read_message(self):
        assert self.process.stdout is not None
        headers = {}
        while True:
            line = self.process.stdout.readline()
            if not line:
                stderr = self.process.stderr.read().decode("utf-8", "replace")
                raise RuntimeError(f"LSP ended before a response: {stderr.strip()}")
            line = line.rstrip(b"\r\n")
            if not line:
                break
            name, separator, value = line.partition(b":")
            if not separator:
                raise RuntimeError(f"malformed LSP header: {line!r}")
            headers[name.lower()] = value.strip()
        try:
            length = int(headers[b"content-length"])
        except (KeyError, ValueError) as error:
            raise RuntimeError(f"missing or invalid Content-Length: {headers!r}") from error
        chunks = []
        remaining = length
        while remaining:
            chunk = self.process.stdout.read(remaining)
            if not chunk:
                raise RuntimeError("LSP payload ended early")
            chunks.append(chunk)
            remaining -= len(chunk)
        return json.loads(b"".join(chunks).decode("utf-8"))

    def request(self, method, params, expected_success=None):
        request_id = self.next_id
        self.next_id += 1
        started = time.perf_counter_ns()
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            message = self.read_message()
            if message.get("id") != request_id:
                continue
            elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
            if "error" in message:
                raise RuntimeError(f"{method} returned JSON-RPC error: {message['error']}")
            if expected_success is not None:
                result = message.get("result")
                if not isinstance(result, dict) or result.get("success") is not expected_success:
                    raise RuntimeError(
                        f"{method} expected success={expected_success}, got {message!r}"
                    )
            return elapsed_ms

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        self.request("shutdown", None)
        self.notify("exit", None)
        assert self.process.stdin is not None
        self.process.stdin.close()
        assert self.process.stderr is not None
        stderr = self.process.stderr.read().decode("utf-8", "replace")
        code = self.process.wait(timeout=30)
        if code != 0:
            raise RuntimeError(f"LSP exited with status {code}: {stderr.strip()}")
        return stderr


def did_open(uri, text):
    return {
        "textDocument": {
            "uri": uri,
            "languageId": "typelisp",
            "version": 1,
            "text": text,
        }
    }


def did_change(uri, text):
    return {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": text}],
    }


def check_params(uri):
    return {"textDocument": {"uri": uri}}


def run_case(client, label, line_count):
    path = workdir / f"{label}.tl"
    uri = path.resolve().as_uri()
    valid_source = make_source(label, line_count)
    invalid_source = valid_source + "(\n"
    path.write_text(valid_source, encoding="utf-8")

    client.notify("textDocument/didOpen", did_open(uri, invalid_source))
    invalid_ms = client.request("tl/check", check_params(uri), expected_success=False)
    unchanged_ms = client.request("tl/check", check_params(uri), expected_success=False)
    client.notify("textDocument/didChange", did_change(uri, valid_source))
    edited_ms = client.request("tl/check", check_params(uri), expected_success=True)
    return (line_count, invalid_ms, unchanged_ms, edited_ms)


client = LspClient()
try:
    client.request("initialize", {"capabilities": {}})

    # Seed the shared import path so subsequent edited documents can expose
    # the compiler's existing prefix-cache counters at shutdown.
    warmup_path = workdir / "warmup.tl"
    warmup_source = "(import stdlib.string)\n(define warmup : i64 1)\n"
    warmup_path.write_text(warmup_source, encoding="utf-8")
    warmup_uri = warmup_path.resolve().as_uri()
    client.notify("textDocument/didOpen", did_open(warmup_uri, warmup_source))
    client.request("tl/check", check_params(warmup_uri), expected_success=True)

    results = [
        run_case(client, "generated-500-lines", small_lines),
        run_case(client, "generated-6000-lines", large_lines),
    ]
    stderr = client.close()
except Exception:
    try:
        if client.process.poll() is None:
            client.process.kill()
    finally:
        raise

stderr_path = workdir / "lsp.stderr"
stderr_path.write_text(stderr, encoding="utf-8")
stats = re.search(r"^typecheck-prefix-cache\|lsp\|.*$", stderr, re.MULTILINE)
if not stats:
    raise SystemExit("LSP did not emit the requested prefix-cache stats; see " + str(stderr_path))

print("[lsp-check] persistent_server=1 scenarios=2")
for line_count, invalid_ms, unchanged_ms, edited_ms in results:
    target = 500 if line_count <= 500 else 3000
    comparison = "within" if edited_ms < target else "over"
    print(
        "[lsp-check] "
        f"lines={line_count} invalid_check_ms={invalid_ms:.3f} "
        f"unchanged_check_ms={unchanged_ms:.3f} edited_check_ms={edited_ms:.3f} "
        f"edited_target_ms={target} comparison={comparison}"
    )
print(f"[lsp-check] {stats.group(0)}")
print("[lsp-check] unchanged_check is served from the per-document result cache")
print("[lsp-check] targets are informational local baselines, not pass/fail gates")
PY
