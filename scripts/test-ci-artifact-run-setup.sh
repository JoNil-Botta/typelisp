#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/target/exp"
WORKDIR=$(mktemp -d "$ROOT/target/exp/ci-artifact-setup.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
FIXTURE="$WORKDIR/checkout with spaces"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/perf" "$WORKDIR/bin"
cp "$ROOT/scripts/ci-verify.sh" "$FIXTURE/scripts/"
for library in lib-linux-entry lib-ci-timing lib-benchmark-ci-cases lib-ci-compiler-artifact; do
    cp "$ROOT/scripts/$library.sh" "$FIXTURE/scripts/"
done
cp "$ROOT/perf/benchmark-ci-cases.tsv" "$FIXTURE/perf/"
# Execute the real entrypoint through its first child gate. The probe's distinct
# exit stops before any compiler work; no production skip switch is introduced.
cat > "$FIXTURE/scripts/check-cli-gate-coverage.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
[ "${TYPELISP_CI_COMPILER_ARTIFACT_TRACE:-}" = "$EXPECTED_TRACE" ]
case ${TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN:-} in
    setup-test-7-"$EXPECTED_HOST"-*) ;;
    *) exit 1 ;;
esac
[ "$(wc -l < "$EXPECTED_TRACE" | tr -d ' \r')" = 1 ]
head -n 1 "$EXPECTED_TRACE" | grep '^schema' >/dev/null
printf '%s\n' observed > "$PROBE_RESULT"
exit 97
EOF
chmod +x "$FIXTURE/scripts/check-cli-gate-coverage.sh"
cat > "$WORKDIR/bin/uname" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$SETUP_TEST_UNAME"
EOF
chmod +x "$WORKDIR/bin/uname"

run_case() (
    setup_host=$1
    setup_mode=$2
    export EXPECTED_HOST=$setup_host
    case $setup_host in
        linux) SETUP_TEST_UNAME=Linux ;;
        windows) SETUP_TEST_UNAME=MINGW64_NT-10.0 ;;
    esac
    export SETUP_TEST_UNAME
    PATH="$WORKDIR/bin:$PATH"
    export PATH
    unset TYPELISP_CI_COMPILER_ARTIFACT_TRACE TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN
    case $setup_mode in
        unset | empty | inherited-token)
            EXPECTED_TRACE="$FIXTURE/target/ci-compiler-artifacts/trace.tsv" ;;
        relative)
            TYPELISP_CI_COMPILER_ARTIFACT_TRACE='target/custom trace/events.tsv'
            EXPECTED_TRACE="$FIXTURE/$TYPELISP_CI_COMPILER_ARTIFACT_TRACE" ;;
        absolute)
            TYPELISP_CI_COMPILER_ARTIFACT_TRACE="$WORKDIR/external trace/events.tsv"
            EXPECTED_TRACE=$TYPELISP_CI_COMPILER_ARTIFACT_TRACE ;;
    esac
    case $setup_mode in
        empty) TYPELISP_CI_COMPILER_ARTIFACT_TRACE= ;;
        inherited-token) TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN=stale-parent-run ;;
    esac
    export TYPELISP_CI_COMPILER_ARTIFACT_TRACE TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN
    export EXPECTED_TRACE
    PROBE_RESULT="$WORKDIR/$setup_host-$setup_mode.observed"
    export PROBE_RESULT
    mkdir -p "$(dirname -- "$EXPECTED_TRACE")"
    printf '%s\n' stale previous-run rows > "$EXPECTED_TRACE"
    set +e
    GITHUB_RUN_ID=setup-test GITHUB_RUN_ATTEMPT=7 TYPELISP_CI_TIMING=0 \
        TYPELISP_BIN="$FIXTURE/scripts/check-cli-gate-coverage.sh" \
        sh "$FIXTURE/scripts/ci-verify.sh" > "$WORKDIR/case.log" 2>&1
    setup_status=$?
    set -e
    if [ "$setup_status" -ne 97 ] || [ ! -f "$PROBE_RESULT" ]; then
        echo "CI artifact startup failed: $setup_host/$setup_mode (exit $setup_status)" >&2
        cat "$WORKDIR/case.log" >&2
        exit 1
    fi
)

for setup_host in linux windows; do
    for setup_mode in unset empty inherited-token relative absolute; do
        run_case "$setup_host" "$setup_mode"
    done
done
set +e
PROBE_RESULT="$WORKDIR/invalid.observed" EXPECTED_TRACE="$WORKDIR" \
    TYPELISP_CI_COMPILER_ARTIFACT_TRACE="$WORKDIR" TYPELISP_CI_TIMING=0 \
    TYPELISP_BIN="$FIXTURE/scripts/check-cli-gate-coverage.sh" \
    sh "$FIXTURE/scripts/ci-verify.sh" > "$WORKDIR/invalid.log" 2>&1
setup_status=$?
set -e
if [ "$setup_status" -eq 0 ] || [ -e "$WORKDIR/invalid.observed" ] || \
    grep -F '[ci-verify] START' "$WORKDIR/invalid.log" >/dev/null; then
    echo 'invalid trace destination must fail before any gate starts' >&2
    cat "$WORKDIR/invalid.log" >&2
    exit 1
fi
echo 'CI artifact startup passed for default, empty, inherited-token, relative and absolute trace settings on both host branches'
