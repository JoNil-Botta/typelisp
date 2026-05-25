#!/usr/bin/env python3
"""
No-Rust REPL and LSP corpus runner for tests/public-tools/.

Usage:
    TYPELISP_BIN=./target/release/typelisp python3 tests/public-tools/run-corpus.py [repl|lsp]

Exercises transcript/protocol fixtures under tests/public-tools/repl/ and
tests/public-tools/lsp/ and reports pass/fail.
"""

import glob
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

COMPILER = os.environ.get("TYPELISP_BIN", "./target/release/typelisp")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def run(cmd, stdin=b"", cwd=REPO_ROOT):
    result = subprocess.run(
        cmd,
        input=stdin,
        capture_output=True,
        cwd=cwd,
    )
    return result.returncode, result.stdout, result.stderr


def check_contains(haystack, needle):
    return needle in haystack


def check_re(haystack, pattern):
    return re.search(pattern, haystack) is not None


def expand_vars_in_spec(spec, tmp_env):
    """Replace ${{TMP}} and ${{TMP_URI}} placeholders in spec values."""
    def replacer(v):
        if isinstance(v, str):
            return v.replace("${{TMP}}", tmp_env["TMP"]).replace("${{TMP_URI}}", tmp_env["TMP_URI"])
        if isinstance(v, list):
            return [replacer(x) for x in v]
        if isinstance(v, dict):
            return {k: replacer(x) for k, x in v.items()}
        return v
    return replacer(spec)


def run_repl_fixture(path, spec_path=None):
    """Run a REPL fixture (.in + .spec.json) and return (ok, messages)."""
    if spec_path is None:
        base = os.path.splitext(path)[0]
        spec_path = base + ".spec.json"

    with open(path, "rb") as f:
        stdin = f.read()

    code, stdout_b, stderr_b = run([os.path.join(REPO_ROOT, COMPILER), "repl"], stdin)
    stdout = stdout_b.decode("utf-8", errors="replace")
    stderr = stderr_b.decode("utf-8", errors="replace")

    if not os.path.exists(spec_path):
        if code != 0:
            return False, [f"expected exit 0, got {code}"]
        if stderr:
            return False, [f"expected empty stderr, got: {stderr[:200]!r}"]
        return True, []

    with open(spec_path, "r", encoding="utf-8") as f:
        spec = json.load(f)

    errors = []
    want_code = spec.get("exit", 0)
    if code != want_code:
        errors.append(f"expected exit {want_code}, got {code}")

    for pattern in spec.get("stdout_contains", []):
        if not check_contains(stdout, pattern):
            errors.append(f"stdout missing: {pattern!r}")

    for pattern in spec.get("stdout_not_contains", []):
        if check_contains(stdout, pattern):
            errors.append(f"stdout unexpectedly contains: {pattern!r}")

    for pattern in spec.get("stderr_contains", []):
        if not check_contains(stderr, pattern):
            errors.append(f"stderr missing: {pattern!r}")

    for pattern in spec.get("stderr_not_contains", []):
        if check_contains(stderr, pattern):
            errors.append(f"stderr unexpectedly contains: {pattern!r}")

    if "stdout_exact" in spec:
        if stdout != spec["stdout_exact"]:
            errors.append(f"stdout mismatch.\nexpected:\n{spec['stdout_exact']!r}\ngot:\n{stdout!r}")

    if "stderr_exact" in spec:
        if stderr != spec["stderr_exact"]:
            errors.append(f"stderr mismatch.\nexpected:\n{spec['stderr_exact']!r}\ngot:\n{stderr!r}")

    return len(errors) == 0, errors


def parse_lsp_messages(data):
    """Parse Content-Length framed JSON-RPC messages from bytes."""
    messages = []
    offset = 0
    while offset < len(data):
        header_end = data.find(b"\r\n\r\n", offset)
        if header_end == -1:
            break
        header = data[offset:header_end].decode("utf-8", errors="replace")
        body_start = header_end + 4
        content_length = None
        for line in header.splitlines():
            if line.startswith("Content-Length:"):
                try:
                    content_length = int(line[15:].strip())
                except ValueError:
                    pass
                break
        if content_length is None:
            break
        body_end = body_start + content_length
        if body_end > len(data):
            break
        try:
            msg = json.loads(data[body_start:body_end].decode("utf-8", errors="replace"))
            messages.append((msg, data[body_start:body_end].decode("utf-8", errors="replace")))
        except json.JSONDecodeError:
            messages.append((None, data[body_start:body_end].decode("utf-8", errors="replace")))
        offset = body_end
    return messages


def frame_payload(payload):
    body = payload.encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8") + body


def run_lsp_fixture(path):
    """Run an LSP fixture (.in.json + .spec.json) and return (ok, messages)."""
    base = path.removesuffix(".in.json")
    spec_path = base + ".spec.json"
    prep_path = base + ".prep.py"

    with open(path, "r", encoding="utf-8") as f:
        requests_raw = f.read()

    with open(spec_path, "r", encoding="utf-8") as f:
        spec = json.load(f)

    # Set up a temporary directory for this fixture. realpath() canonicalizes it
    # (resolving Windows 8.3 short names like RUNNER~1 to the long form), matching
    # the compiler's std::fs::canonicalize of imported module paths.
    tmpdir = os.path.realpath(tempfile.mkdtemp(prefix="typelisp-lsp-fixture-"))
    # Build a proper file URI: file:///tmp/... on POSIX and file:///C:/... on
    # Windows (three slashes for the drive-letter form), matching the compiler's
    # path_to_file_uri. A bare "file://" + path yields "file://C:/..." on
    # Windows, which never matches the emitted diagnostic URIs.
    tmp_uri = pathlib.Path(tmpdir).as_uri()
    tmp_env = {"TMP": tmpdir, "TMP_URI": tmp_uri}
    spec = expand_vars_in_spec(spec, tmp_env)

    # Run optional prep script to create side files
    if os.path.exists(prep_path):
        env = os.environ.copy()
        env["FIXTURE_TMP"] = tmpdir
        env["FIXTURE_TMP_URI"] = tmp_uri
        prep_result = subprocess.run([sys.executable, prep_path], capture_output=True, text=True, env=env, cwd=REPO_ROOT)
        if prep_result.returncode != 0:
            os.rmdir(tmpdir)
            return False, [f"prep.py failed: {prep_result.stderr}"]

    # Substitute ${{TMP}} and ${{TMP_URI}} in request JSON too
    requests_raw = requests_raw.replace("${{TMP}}", tmpdir.replace("\\", "/"))
    requests_raw = requests_raw.replace("${{TMP_URI}}", tmp_uri)
    requests = json.loads(requests_raw)

    stdin = b""
    for req in requests:
        stdin += frame_payload(json.dumps(req))

    code, stdout_b, stderr_b = run([os.path.join(REPO_ROOT, COMPILER), "lsp"], stdin)
    stdout = stdout_b.decode("utf-8", errors="replace")
    stderr = stderr_b.decode("utf-8", errors="replace")

    parsed_messages = parse_lsp_messages(stdout_b)

    errors = []
    want_code = spec.get("exit", 0)
    if code != want_code:
        errors.append(f"expected exit {want_code}, got {code}")

    for pattern in spec.get("stderr_contains", []):
        if not check_contains(stderr, pattern):
            errors.append(f"stderr missing: {pattern!r}")

    for pattern in spec.get("stderr_not_contains", []):
        if check_contains(stderr, pattern):
            errors.append(f"stderr unexpectedly contains: {pattern!r}")

    for pattern in spec.get("stdout_contains", []):
        if not check_contains(stdout, pattern):
            errors.append(f"stdout missing: {pattern!r}")

    if "message_count" in spec:
        if len(parsed_messages) != spec["message_count"]:
            errors.append(f"expected {spec['message_count']} messages, got {len(parsed_messages)}")

    for check in spec.get("message_checks", []):
        found = False
        for msg_obj, msg_raw in parsed_messages:
            match = True
            for key, value in check.items():
                if key == "raw_contains":
                    if not check_contains(msg_raw, value):
                        match = False
                        break
                elif key == "jsonpath":
                    node = msg_obj
                    for part in value.split("."):
                        if node is None:
                            match = False
                            break
                        if isinstance(node, dict):
                            node = node.get(part)
                        elif isinstance(node, list) and part.isdigit():
                            idx = int(part)
                            if idx < len(node):
                                node = node[idx]
                            else:
                                node = None
                        else:
                            node = None
                    if node is None:
                        match = False
                        break
                elif key.startswith("jsonpath_"):
                    path = key[len("jsonpath_"):]
                    node = msg_obj
                    for part in path.split("."):
                        if node is None:
                            match = False
                            break
                        if isinstance(node, dict):
                            node = node.get(part)
                        else:
                            node = None
                    if node != value:
                        match = False
                        break
                elif key == "json_contains":
                    msg_json = json.dumps(msg_obj, separators=(',', ':'), ensure_ascii=False) if msg_obj else ""
                    if not check_contains(msg_json, value):
                        match = False
                        break
                elif key == "raw_not_contains":
                    if check_contains(msg_raw, value):
                        match = False
                        break
            if match:
                found = True
                break
        if not found:
            errors.append(f"no message matched: {check!r}")

    import shutil
    shutil.rmtree(tmpdir, ignore_errors=True)

    return len(errors) == 0, errors


def build_selfhost_binary(name):
    """Build a selfhost binary if not already present. Returns path or None."""
    bin_path = f"/tmp/typelisp-corpus-{name}"
    if os.path.exists(bin_path):
        return bin_path
    src = os.path.join(REPO_ROOT, "selfhost", f"{name}.tl")
    stdlib = os.path.join(REPO_ROOT, "stdlib")
    result = subprocess.run(
        [os.path.join(REPO_ROOT, COMPILER), "build", src, "--stdlib-root", stdlib, "-o", bin_path],
        capture_output=True,
        cwd=REPO_ROOT,
    )
    if result.returncode != 0:
        print(f"  SKIP selfhost {name}: build failed", file=sys.stderr)
        return None
    return bin_path


def run_selfhost_repl_fixture(path, spec_path, binary):
    with open(path, "rb") as f:
        stdin = f.read()
    code, stdout_b, stderr_b = run([binary], stdin)
    stdout = stdout_b.decode("utf-8", errors="replace")
    stderr = stderr_b.decode("utf-8", errors="replace")

    with open(spec_path, "r", encoding="utf-8") as f:
        spec = json.load(f)

    errors = []
    want_code = spec.get("exit", 0)
    if code != want_code:
        errors.append(f"expected exit {want_code}, got {code}")

    for pattern in spec.get("stdout_contains", []):
        if not check_contains(stdout, pattern):
            errors.append(f"stdout missing: {pattern!r}")

    for pattern in spec.get("stdout_not_contains", []):
        if check_contains(stdout, pattern):
            errors.append(f"stdout unexpectedly contains: {pattern!r}")

    for pattern in spec.get("stderr_contains", []):
        if not check_contains(stderr, pattern):
            errors.append(f"stderr missing: {pattern!r}")

    for pattern in spec.get("stderr_not_contains", []):
        if check_contains(stderr, pattern):
            errors.append(f"stderr unexpectedly contains: {pattern!r}")

    if "stdout_exact" in spec:
        if stdout != spec["stdout_exact"]:
            errors.append(f"stdout mismatch.\nexpected:\n{spec['stdout_exact']!r}\ngot:\n{stdout!r}")

    if "stderr_exact" in spec:
        if stderr != spec["stderr_exact"]:
            errors.append(f"stderr mismatch.\nexpected:\n{spec['stderr_exact']!r}\ngot:\n{stderr!r}")

    return len(errors) == 0, errors


def run_selfhost_lsp_fixture(path, spec_path, binary):
    with open(path, "r", encoding="utf-8") as f:
        requests_raw = f.read()

    with open(spec_path, "r", encoding="utf-8") as f:
        spec = json.load(f)

    # realpath() canonicalizes Windows 8.3 short names to match the compiler's
    # std::fs::canonicalize of imported module paths (see run_lsp_fixture).
    tmpdir = os.path.realpath(tempfile.mkdtemp(prefix="typelisp-selfhost-lsp-fixture-"))
    # Build a proper file URI: file:///tmp/... on POSIX and file:///C:/... on
    # Windows (three slashes for the drive-letter form), matching the compiler's
    # path_to_file_uri. A bare "file://" + path yields "file://C:/..." on
    # Windows, which never matches the emitted diagnostic URIs.
    tmp_uri = pathlib.Path(tmpdir).as_uri()
    tmp_env = {"TMP": tmpdir, "TMP_URI": tmp_uri}
    spec = expand_vars_in_spec(spec, tmp_env)

    requests_raw = requests_raw.replace("${{TMP}}", tmpdir.replace("\\", "/"))
    requests_raw = requests_raw.replace("${{TMP_URI}}", tmp_uri)

    stdin = b""
    if path.endswith(".in.json"):
        requests = json.loads(requests_raw)
        for req in requests:
            stdin += frame_payload(json.dumps(req))
    else:
        stdin = requests_raw.encode("utf-8")

    code, stdout_b, stderr_b = run([binary], stdin)
    stdout = stdout_b.decode("utf-8", errors="replace")
    stderr = stderr_b.decode("utf-8", errors="replace")

    parsed_messages = parse_lsp_messages(stdout_b)

    errors = []
    want_code = spec.get("exit", 0)
    if code != want_code:
        errors.append(f"expected exit {want_code}, got {code}")

    for pattern in spec.get("stderr_contains", []):
        if not check_contains(stderr, pattern):
            errors.append(f"stderr missing: {pattern!r}")

    for pattern in spec.get("stderr_not_contains", []):
        if check_contains(stderr, pattern):
            errors.append(f"stderr unexpectedly contains: {pattern!r}")

    for pattern in spec.get("stdout_contains", []):
        if not check_contains(stdout, pattern):
            errors.append(f"stdout missing: {pattern!r}")

    if "message_count" in spec:
        if len(parsed_messages) != spec["message_count"]:
            errors.append(f"expected {spec['message_count']} messages, got {len(parsed_messages)}")

    for check in spec.get("message_checks", []):
        found = False
        for msg_obj, msg_raw in parsed_messages:
            match = True
            for key, value in check.items():
                if key == "raw_contains":
                    if not check_contains(msg_raw, value):
                        match = False
                        break
                elif key == "raw_not_contains":
                    if check_contains(msg_raw, value):
                        match = False
                        break
                elif key == "jsonpath":
                    node = msg_obj
                    for part in value.split("."):
                        if node is None:
                            match = False
                            break
                        if isinstance(node, dict):
                            node = node.get(part)
                        elif isinstance(node, list) and part.isdigit():
                            idx = int(part)
                            if idx < len(node):
                                node = node[idx]
                            else:
                                node = None
                        else:
                            node = None
                    if node is None:
                        match = False
                        break
                elif key.startswith("jsonpath_"):
                    path = key[len("jsonpath_"):]
                    node = msg_obj
                    for part in path.split("."):
                        if node is None:
                            match = False
                            break
                        if isinstance(node, dict):
                            node = node.get(part)
                        else:
                            node = None
                    if node != value:
                        match = False
                        break
                elif key == "json_contains":
                    msg_json = json.dumps(msg_obj, separators=(',', ':'), ensure_ascii=False) if msg_obj else ""
                    if not check_contains(msg_json, value):
                        match = False
                        break
            if match:
                found = True
                break
        if not found:
            errors.append(f"no message matched: {check!r}")

    import shutil
    shutil.rmtree(tmpdir, ignore_errors=True)

    return len(errors) == 0, errors


def main():
    if not os.path.isfile(os.path.join(REPO_ROOT, COMPILER)):
        print(f"Compiler not found: {COMPILER}", file=sys.stderr)
        sys.exit(1)

    failed = 0
    passed = 0

    import platform
    is_linux = platform.system() == "Linux"

    # REPL fixtures
    repl_dir = os.path.join(os.path.dirname(__file__), "repl")
    if os.path.isdir(repl_dir):
        repl_paths = sorted(glob.glob(os.path.join(repl_dir, "*.in")))
        repl_paths = [p for p in repl_paths if not p.endswith(".linux.in")]
        if is_linux:
            repl_paths += sorted(glob.glob(os.path.join(repl_dir, "*.linux.in")))
        for path in repl_paths:
            name = os.path.basename(path)
            if name.endswith(".linux.in"):
                base = path.removesuffix(".linux.in")
                spec_path = base + ".linux.spec.json"
            else:
                spec_path = None
            ok, msgs = run_repl_fixture(path, spec_path)
            if ok:
                print(f"  PASS repl/{name}")
                passed += 1
            else:
                print(f"  FAIL repl/{name}")
                for m in msgs:
                    print(f"    - {m}")
                failed += 1

    # LSP fixtures
    lsp_dir = os.path.join(os.path.dirname(__file__), "lsp")
    if os.path.isdir(lsp_dir):
        for path in sorted(glob.glob(os.path.join(lsp_dir, "*.in.json"))):
            ok, msgs = run_lsp_fixture(path)
            name = os.path.basename(path)
            if ok:
                print(f"  PASS lsp/{name}")
                passed += 1
            else:
                print(f"  FAIL lsp/{name}")
                for m in msgs:
                    print(f"    - {m}")
                failed += 1

    # Selfhost REPL fixtures (Linux only)
    selfhost_repl_dir = os.path.join(os.path.dirname(__file__), "selfhost-repl")
    selfhost_repl_bin = None
    if is_linux and os.path.isdir(selfhost_repl_dir):
        selfhost_repl_bin = build_selfhost_binary("repl")
        if selfhost_repl_bin:
            for path in sorted(glob.glob(os.path.join(selfhost_repl_dir, "*.linux.in"))):
                name = os.path.basename(path)
                base = path.removesuffix(".linux.in")
                spec_path = base + ".linux.spec.json"
                ok, msgs = run_selfhost_repl_fixture(path, spec_path, selfhost_repl_bin)
                if ok:
                    print(f"  PASS selfhost-repl/{name}")
                    passed += 1
                else:
                    print(f"  FAIL selfhost-repl/{name}")
                    for m in msgs:
                        print(f"    - {m}")
                    failed += 1

    # Selfhost LSP fixtures (Linux only)
    selfhost_lsp_dir = os.path.join(os.path.dirname(__file__), "selfhost-lsp")
    selfhost_lsp_bin = None
    if is_linux and os.path.isdir(selfhost_lsp_dir):
        selfhost_lsp_bin = build_selfhost_binary("lsp_frame")
        if selfhost_lsp_bin:
            selfhost_lsp_paths = sorted(glob.glob(os.path.join(selfhost_lsp_dir, "*.linux.in")))
            # Raw .in files also match .linux.in; use .in.json for JSON fixtures
            for path in sorted(glob.glob(os.path.join(selfhost_lsp_dir, "*.linux.in.json"))):
                if path not in selfhost_lsp_paths:
                    selfhost_lsp_paths.append(path)
            for path in selfhost_lsp_paths:
                name = os.path.basename(path)
                if name.endswith(".linux.in.json"):
                    base = path.removesuffix(".linux.in.json")
                elif name.endswith(".linux.in"):
                    base = path.removesuffix(".linux.in")
                else:
                    continue
                spec_path = base + ".linux.spec.json"
                ok, msgs = run_selfhost_lsp_fixture(path, spec_path, selfhost_lsp_bin)
                if ok:
                    print(f"  PASS selfhost-lsp/{name}")
                    passed += 1
                else:
                    print(f"  FAIL selfhost-lsp/{name}")
                    for m in msgs:
                        print(f"    - {m}")
                    failed += 1

    total = passed + failed
    print(f"\n{passed}/{total} passed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
