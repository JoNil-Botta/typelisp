#!/usr/bin/env sh
set -eu

# Measure one cold open/check/full-token response and repeated full-token reads
# over the retained document semantic snapshot. The benchmark source defaults
# to the compiler's largest typechecking module and is never modified.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

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
    echo "measure-lsp-semantic-tokens-latency.sh requires Python 3" >&2
    exit 1
fi

REQUESTS=${TYPELISP_LSP_SEMANTIC_TOKEN_REQUESTS:-100}
SOURCE=${TYPELISP_LSP_SEMANTIC_TOKEN_SOURCE:-src/compiler_typecheck_core.tl}

case "$REQUESTS" in
    ''|*[!0-9]*)
        echo "semantic-token request count must be a positive integer" >&2
        exit 1
        ;;
esac
if [ "$REQUESTS" -lt 100 ]; then
    echo "semantic-token benchmark requires at least 100 repeated requests" >&2
    exit 1
fi
if [ ! -f "$SOURCE" ]; then
    echo "semantic-token benchmark source does not exist: $SOURCE" >&2
    exit 1
fi

exec "$PYTHON" - "$COMPILER" "$ROOT" "$SOURCE" "$REQUESTS" <<'PY'
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path


compiler, root_text, source_text, requests_text = sys.argv[1:]
root = Path(root_text)
source_path = Path(source_text).resolve()
source = source_path.read_text(encoding="utf-8")
request_count = int(requests_text)


def frame(message):
    body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


def rss_bytes(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    except (FileNotFoundError, PermissionError, ValueError):
        pass
    return None


class Client:
    def __init__(self):
        self.process = subprocess.Popen(
            [
                compiler,
                "lsp",
                "--stdlib-root",
                str(root / "stdlib"),
                "--stdlib-root",
                str(root / "src"),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.next_id = 1
        self.observed = []

    def send(self, message):
        self.process.stdin.write(frame(message))
        self.process.stdin.flush()

    def read(self):
        headers = {}
        while True:
            line = self.process.stdout.readline()
            if not line:
                error = self.process.stderr.read().decode("utf-8", "replace")
                raise RuntimeError("LSP ended before response: " + error)
            line = line.rstrip(b"\r\n")
            if not line:
                break
            name, separator, value = line.partition(b":")
            if not separator:
                raise RuntimeError(f"malformed LSP header: {line!r}")
            headers[name.lower()] = value.strip()
        length = int(headers[b"content-length"])
        body = self.process.stdout.read(length)
        if len(body) != length:
            raise RuntimeError("truncated LSP body")
        return json.loads(body.decode("utf-8"))

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        started = time.perf_counter_ns()
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            message = self.read()
            self.observed.append(message)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError(f"{method} failed: {message['error']}")
            return (time.perf_counter_ns() - started) / 1_000_000, message.get("result")

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        self.request("shutdown", None)
        self.notify("exit", None)
        self.process.stdin.close()
        stderr = self.process.stderr.read().decode("utf-8", "replace")
        code = self.process.wait(timeout=30)
        if code != 0 or stderr:
            raise RuntimeError(f"LSP exited with {code}: {stderr}")


uri = source_path.as_uri()
params = {"textDocument": {"uri": uri}}
client = Client()
try:
    client.request(
        "initialize",
        {"rootUri": root.resolve().as_uri(), "capabilities": {}},
    )
    rss_before_open = rss_bytes(client.process.pid)
    opened = time.perf_counter_ns()
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": uri,
                "languageId": "typelisp",
                "version": 1,
                "text": source,
            }
        },
    )
    cold_request_ms, cold_result = client.request(
        "textDocument/semanticTokens/full", params
    )
    cold_open_and_request_ms = (time.perf_counter_ns() - opened) / 1_000_000
    if not isinstance(cold_result, dict) or not isinstance(cold_result.get("data"), list):
        raise RuntimeError(
            f"unexpected semantic-token result: {cold_result!r}; "
            f"recent messages: {client.observed[-4:]!r}"
        )
    baseline_data = cold_result["data"]
    if len(baseline_data) % 5:
        raise RuntimeError("semantic-token data length is not divisible by five")
    encoded_bytes = len(json.dumps(cold_result, separators=(",", ":")).encode("utf-8"))
    rss_after_cold = rss_bytes(client.process.pid)

    timings = []
    rss_before_hot = rss_bytes(client.process.pid)
    for _ in range(request_count):
        elapsed_ms, result = client.request("textDocument/semanticTokens/full", params)
        if not isinstance(result, dict) or result.get("data") != baseline_data:
            raise RuntimeError("warm semantic-token response changed")
        timings.append(elapsed_ms)
    rss_after_hot = rss_bytes(client.process.pid)
    client.close()
except Exception:
    if client.process.poll() is None:
        client.process.kill()
    raise


ordered = sorted(timings)
p95_index = min(len(ordered) - 1, int(len(ordered) * 0.95))


def delta(before, after):
    if before is None or after is None:
        return "unavailable"
    return str(after - before)


print(
    "lsp-semantic-tokens "
    f"source={source_path.relative_to(root)} "
    f"source_bytes={len(source.encode('utf-8'))} "
    f"tokens={len(baseline_data) // 5} "
    f"encoded_integers={len(baseline_data)} "
    f"result_bytes={encoded_bytes} "
    f"cold_request_ms={cold_request_ms:.3f} "
    f"cold_open_and_request_ms={cold_open_and_request_ms:.3f} "
    f"cold_retained_rss_delta_bytes={delta(rss_before_open, rss_after_cold)} "
    f"warm_requests={request_count} "
    f"warm_min_ms={min(timings):.3f} "
    f"warm_median_ms={statistics.median(timings):.3f} "
    f"warm_p95_ms={ordered[p95_index]:.3f} "
    f"warm_max_ms={max(timings):.3f} "
    f"warm_retained_rss_delta_bytes={delta(rss_before_hot, rss_after_hot)}"
)
PY
