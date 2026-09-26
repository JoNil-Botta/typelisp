#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/public-tools/lib-result-checks.sh"
mkdir -p "$ROOT/target/exp"
case_dir=$(mktemp -d "$ROOT/target/exp/corpus-result-checks.XXXXXX")
trap 'rm -rf "$case_dir"' EXIT HUP INT TERM

check() {
    check_corpus_result "$case_dir/spec" "$case_dir/out" "$case_dir/err" "$1" \
        "$case_dir/messages" '/tmp/a bc' 'file:///tmp/a%20bc' "$2" > "$case_dir/got"
    if ! cmp -s "$case_dir/want" "$case_dir/got"; then
        echo "corpus result self-test failed: $3" >&2
        diff -u "$case_dir/want" "$case_dir/got" >&2 || true
        exit 1
    fi
}

# Repeated keys, metacharacters, decoded newlines and both path substitutions.
cat > "$case_dir/spec" <<'SPEC'
{
  "exit": 7,
  "stdout_contains": ["alpha\nbeta", "a.*b", ""],
  "stdout_not_contains": ["alpha beta", "missing"],
  "stderr_contains": ["diagnostic"],
  "stderr_not_contains": ["absent"],
  "stdout_exact": "alpha\nbeta a.*b\n",
  "stderr_exact": "diagnostic\n",
  "message_count": 2,
  "message_checks": [
    {"jsonpath_id": 1, "raw_contains": "alpha\nbeta", "raw_contains": "${{TMP}}", "json_contains": "${{TMP_URI}}", "raw_not_contains": "missing", "raw_not_contains": "absent"},
    {"jsonpath_id": 2, "jsonpath_result": null}
  ]
}
SPEC
printf 'alpha\nbeta a.*b\n' > "$case_dir/out"
printf 'diagnostic\n' > "$case_dir/err"
printf '%s\n' '{"id":1,"result":"alpha beta /tmp/a bc file:///tmp/a%20bc"}' '{"id":2,"result":null}' > "$case_dir/messages"
: > "$case_dir/want"
check 7 linux 'all checks pass'

# Every independent failure must survive, in the original diagnostic order.
cat > "$case_dir/spec" <<'SPEC'
{
  "exit": 7,
  "stdout_contains": ["absent\nmissing"],
  "stdout_not_contains": ["alpha"],
  "stderr_contains": ["missing"],
  "stderr_not_contains": ["diagnostic"],
  "stdout_exact": "expected\n",
  "stderr_exact": "expected\n",
  "message_count": 3,
  "message_checks": [
    {"jsonpath_id": 9},
    {"jsonpath_id": 1, "jsonpath_result": null},
    {"jsonpath_id": 1, "raw_contains": "alpha", "raw_contains": "missing"},
    {"jsonpath_id": 1, "json_contains": "missing"},
    {"jsonpath_id": 1, "raw_not_contains": "missing", "raw_not_contains": "alpha"},
    {"jsonpath_id": 1, "raw_contains": "${{TMP}}/missing"},
    {"jsonpath_id": 1, "json_contains": "${{TMP_URI}}/missing"}
  ]
}
SPEC
cat > "$case_dir/want" <<'EXPECTED'
expected exit 7, got 0
stdout missing: absent
stdout missing: missing
stdout unexpectedly contains: alpha
stderr missing: missing
stderr unexpectedly contains: diagnostic
stdout mismatch
expected:
  expected
got:
  alpha
  beta a.*b
stderr mismatch
expected:
  expected
got:
  diagnostic
expected 3 messages, got 2
no message matched:     {"jsonpath_id": 9},
no message matched:     {"jsonpath_id": 1, "jsonpath_result": null},
no message matched:     {"jsonpath_id": 1, "raw_contains": "alpha", "raw_contains": "missing"},
no message matched:     {"jsonpath_id": 1, "json_contains": "missing"},
no message matched:     {"jsonpath_id": 1, "raw_not_contains": "missing", "raw_not_contains": "alpha"},
no message matched:     {"jsonpath_id": 1, "raw_contains": "${{TMP}}/missing"},
no message matched:     {"jsonpath_id": 1, "json_contains": "${{TMP_URI}}/missing"}
EXPECTED
check 0 linux 'all check kinds fail'

# Exact comparison retains bytes, empty files, and the final newline. Only the
# Windows exact comparison strips CR; pattern and message checks do not.
printf '{"stdout_exact": "00"}\n' > "$case_dir/spec"
printf '0' > "$case_dir/out"
printf 'stdout mismatch\nexpected:\n  00got:\n  0' > "$case_dir/want"
check 0 linux 'numeric-looking strings compare bytewise'
printf '{"stdout_exact": "a\\nb\\n"}\n' > "$case_dir/spec"
printf 'a\r\nb\r\n' > "$case_dir/out"
: > "$case_dir/want"
check 0 windows 'Windows CR normalization'
printf 'stdout mismatch\nexpected:\n  a\n  b\ngot:\n  a\r\n  b\r\n' > "$case_dir/want"
check 0 linux 'Linux retains CR'
printf '{"stdout_exact": "a\\n"}\n' > "$case_dir/spec"
printf a > "$case_dir/out"
printf 'stdout mismatch\nexpected:\n  a\ngot:\n  a' > "$case_dir/want"
check 0 linux 'final newline mismatch'
printf '{"stdout_exact": ""}\n' > "$case_dir/spec"
: > "$case_dir/out"
: > "$case_dir/want"
check 0 linux 'empty exact stream'

# wc -l counts terminators; an unterminated final message still participates.
cat > "$case_dir/spec" <<'SPEC'
{
  "message_count": 0,
  "message_checks": [
    {"jsonpath_id": 2, "jsonpath_result": null}
  ]
}
SPEC
printf '%s' '{"id":2,"result":null}' > "$case_dir/messages"
check 0 linux 'unterminated message'
: > "$case_dir/messages"
printf '%s\n' 'no message matched:     {"jsonpath_id": 2, "jsonpath_result": null}' > "$case_dir/want"
check 0 linux 'empty message stream'
# A check cannot combine needles from different messages, and JSON escapes
# retain the same byte decoding in exact streams and message needles.
cat > "$case_dir/spec" <<'SPEC'
{
  "stdout_exact": "quote\" slash\\ tab\t",
  "message_checks": [
    {"raw_contains": "alpha", "raw_contains": "beta"}
  ]
}
SPEC
printf 'quote" slash\\ tab\t' > "$case_dir/out"
printf '%s\n' '{"id":1,"result":"alpha"}' '{"id":2,"result":"beta"}' > "$case_dir/messages"
printf '%s\n' 'no message matched:     {"raw_contains": "alpha", "raw_contains": "beta"}' > "$case_dir/want"
check 0 linux 'escapes and same-message conjunction'
if check_corpus_result "$case_dir/missing" "$case_dir/out" "$case_dir/err" 0 '' '' '' linux > "$case_dir/got" 2>&1; then
    echo 'missing spec unexpectedly accepted' >&2
    exit 1
fi
printf '%s\n' 'public-tool corpus result self-tests passed'
