#!/usr/bin/env sh
set -eu

# Measure cold analysis separately from repeated completion over one retained
# document/workspace snapshot.  The hot loop alternates a deep lexical query
# and a large-workspace import query without edits, filesystem reads, or
# compiler reruns between requests.

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
    echo "measure-lsp-completion-latency.sh requires Python 3" >&2
    exit 1
fi

WORKDIR=${TYPELISP_LSP_COMPLETION_WORKDIR:-target/lsp-completion-latency}
REQUESTS=${TYPELISP_LSP_COMPLETION_REQUESTS:-100}
TOP_LEVEL=${TYPELISP_LSP_COMPLETION_TOP_LEVEL:-1000}
DEPTH=${TYPELISP_LSP_COMPLETION_DEPTH:-128}
MODULES=${TYPELISP_LSP_COMPLETION_MODULES:-128}

for value in "$REQUESTS" "$TOP_LEVEL" "$DEPTH" "$MODULES"; do
    case "$value" in
        ''|*[!0-9]*)
            echo "completion benchmark sizes must be positive integers" >&2
            exit 1
            ;;
    esac
    if [ "$value" -le 0 ]; then
        echo "completion benchmark sizes must be positive integers" >&2
        exit 1
    fi
done
if [ "$REQUESTS" -lt 100 ]; then
    echo "completion benchmark requires at least 100 repeated requests" >&2
    exit 1
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

exec "$PYTHON" - "$COMPILER" "$ROOT" "$WORKDIR" "$REQUESTS" "$TOP_LEVEL" "$DEPTH" "$MODULES" <<'PY'
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path


compiler, root_text, workdir_text, requests_text, top_text, depth_text, modules_text = sys.argv[1:]
root = Path(root_text)
workdir = Path(workdir_text)
request_count = int(requests_text)
top_level_count = int(top_text)
depth = int(depth_text)
module_count = int(modules_text)
cachegrind_enabled = os.environ.get("TYPELISP_LSP_COMPLETION_CACHEGRIND") == "1"
cachegrind_path = workdir / "cachegrind.out"


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
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
        command = [compiler, "lsp", "--stdlib-root", str(root / "stdlib")]
        if cachegrind_enabled:
            command = [
                "valgrind",
                "--tool=cachegrind",
                "--quiet",
                f"--cachegrind-out-file={cachegrind_path}",
                "--",
            ] + command
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.next_id = 1

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
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError(f"{method} failed: {message['error']}")
            elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
            return elapsed_ms, message.get("result")

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        self.request("shutdown", None)
        self.notify("exit", None)
        self.process.stdin.close()
        stderr = self.process.stderr.read().decode("utf-8", "replace")
        code = self.process.wait(timeout=30)
        if code != 0:
            raise RuntimeError(f"LSP exited with {code}: {stderr}")


for index in range(module_count):
    path = workdir / "bench" / f"mod{index}.tl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"(module bench.mod{index})\n"
        f"(define module_value_{index} : i64 {index})\n"
        f"(define (module_function_{index} [value : i64]) : i64 value)\n",
        encoding="utf-8",
    )

lines = ["(module bench.main)", "(import bench.mod0 as m0)"]
for index in range(top_level_count):
    lines.append(f"(define benchmark_value_{index} : i64 {index})")

body = f"deep_{depth - 1}"
for index in reversed(range(depth)):
    initial = "root" if index == 0 else f"deep_{index - 1}"
    body = f"(let [deep_{index} : i64 {initial}] {body})"
deep_line = f"(define (deep [root : i64]) : i64 {body})"
deep_line_number = len(lines)
deep_cursor = deep_line.rfind(f"deep_{depth - 1}") + len("deep_")
lines.append(deep_line)
source = "\n".join(lines) + "\n"
main_path = workdir / "main.tl"
main_path.write_text(source, encoding="utf-8")
uri = main_path.resolve().as_uri()
root_uri = workdir.resolve().as_uri()

deep_params = {
    "textDocument": {"uri": uri},
    "position": {"line": deep_line_number, "character": deep_cursor},
}
import_params = {
    "textDocument": {"uri": uri},
    "position": {"line": 1, "character": len("(import bench.m")},
}

client = Client()
try:
    client.request("initialize", {"rootUri": root_uri, "capabilities": {}})
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
    cold_request_ms, cold_result = client.request("textDocument/completion", deep_params)
    cold_total_ms = (time.perf_counter_ns() - opened) / 1_000_000
    if isinstance(cold_result, dict):
        cold_items = cold_result.get("items")
    else:
        cold_items = cold_result
    if not isinstance(cold_items, list):
        raise RuntimeError(f"unexpected completion result: {cold_result!r}")

    rss_before = rss_bytes(client.process.pid)
    timings = []
    candidate_counts = []
    for index in range(request_count):
        params = deep_params if index % 2 == 0 else import_params
        elapsed_ms, result = client.request("textDocument/completion", params)
        items = result.get("items") if isinstance(result, dict) else result
        if not isinstance(items, list):
            raise RuntimeError(f"unexpected completion result: {result!r}")
        timings.append(elapsed_ms)
        candidate_counts.append(len(items))
    rss_after = rss_bytes(client.process.pid)
    client.close()
except Exception:
    if client.process.poll() is None:
        client.process.kill()
    raise

ordered = sorted(timings)
p95_index = min(len(ordered) - 1, int(len(ordered) * 0.95))
retained = "unavailable"
if rss_before is not None and rss_after is not None:
    retained = str(rss_after - rss_before)
instruction_count = "unavailable"
if cachegrind_enabled:
    try:
        for line in cachegrind_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("summary:"):
                instruction_count = line.split()[1]
                break
    except (FileNotFoundError, IndexError, ValueError):
        pass

print(
    "[lsp-completion] "
    f"cold_total_ms={cold_total_ms:.3f} cold_request_ms={cold_request_ms:.3f} "
    f"cold_candidates={len(cold_items)}"
)
print(
    "[lsp-completion] "
    f"requests={request_count} p50_ms={statistics.median(timings):.3f} "
    f"p95_ms={ordered[p95_index]:.3f} max_ms={max(timings):.3f} "
    f"candidate_min={min(candidate_counts)} candidate_max={max(candidate_counts)}"
)
print(
    "[lsp-completion] "
    f"rss_before_bytes={rss_before if rss_before is not None else 'unavailable'} "
    f"rss_after_bytes={rss_after if rss_after is not None else 'unavailable'} "
    f"retained_rss_delta_bytes={retained}"
)
print(
    "[lsp-completion] "
    f"top_level={top_level_count} lexical_depth={depth} workspace_modules={module_count} "
    "compiler_reruns_in_hot_loop=0 filesystem_reads_in_hot_loop=0"
)
print(f"[lsp-completion] dynamic_instructions={instruction_count}")
PY
