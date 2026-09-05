#!/usr/bin/env sh
set -eu

# verify-compile-batch-windows-coff.sh - One-lowering Windows COFF-or-assembly
# batch contract, deterministic plan, and native object link/run smoke.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "Windows COFF batch verifier requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

fail() {
    echo "$*" >&2
    exit 1
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -qF "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

assert_empty() {
    file=$1
    [ ! -s "$file" ] || {
        echo "expected empty file: $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    }
}

HOST_OS=linux
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    Linux*) HOST_OS=linux ;;
    *) fail "unsupported host: $(uname -s)" ;;
esac

WORKDIR="target/verify-compile-batch-windows-coff"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

DIRECT_SOURCE="tests/integration/hello.tl"
FALLBACK_SOURCE="tests/integration/aggregate_globals.tl"
DIRECT_OBJECT="$WORKDIR/direct.obj"
DIRECT_ASSEMBLY="$WORKDIR/direct.s"
FALLBACK_OBJECT="$WORKDIR/fallback.obj"
FALLBACK_ASSEMBLY="$WORKDIR/fallback.s"
FORCED_OBJECT="$WORKDIR/forced.obj"
FORCED_ASSEMBLY="$WORKDIR/forced.s"
RESULT_PLAN="$WORKDIR/results.plan"
BATCH_LIST="$WORKDIR/artifacts.list"

printf '%s|%s|%s\n' \
    "$DIRECT_SOURCE" "$DIRECT_OBJECT" "$DIRECT_ASSEMBLY" > "$BATCH_LIST"
printf '%s|%s|%s|force-assembly\n' \
    "$FALLBACK_SOURCE" "$FORCED_OBJECT" "$FORCED_ASSEMBLY" >> "$BATCH_LIST"
printf '%s|%s|%s\n' \
    "$FALLBACK_SOURCE" "$FALLBACK_OBJECT" "$FALLBACK_ASSEMBLY" >> "$BATCH_LIST"

echo "[compile-batch-windows-coff] object, fallback, and forced assembly"
if ! TYPELISP_WINDOWS_CLANG=__typelisp_unexpected_batch_assembler__.exe \
    "$COMPILER" compile --batch "$BATCH_LIST" \
    --windows-coff-plan "$RESULT_PLAN" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/batch.stdout" 2> "$WORKDIR/batch.stderr"; then
    sed 's/^/  /' "$WORKDIR/batch.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/batch.stderr" >&2 || true
    fail "Windows COFF batch compile failed"
fi
assert_empty "$WORKDIR/batch.stderr"

EXPECTED_PLAN="$WORKDIR/expected.plan"
printf '%s|coff-object|%s|none\n' \
    "$DIRECT_SOURCE" "$DIRECT_OBJECT" > "$EXPECTED_PLAN"
printf '%s|assembly|%s|forced-assembly\n' \
    "$FALLBACK_SOURCE" "$FORCED_ASSEMBLY" >> "$EXPECTED_PLAN"
printf '%s|assembly|%s|unsupported-object-semantics\n' \
    "$FALLBACK_SOURCE" "$FALLBACK_ASSEMBLY" >> "$EXPECTED_PLAN"
cmp "$EXPECTED_PLAN" "$RESULT_PLAN" ||
    fail "Windows COFF batch result plan was not deterministic"

[ -s "$DIRECT_OBJECT" ] || fail "direct row did not write a COFF object"
[ ! -e "$DIRECT_ASSEMBLY" ] || fail "direct row unexpectedly wrote assembly"
[ ! -e "$FALLBACK_OBJECT" ] || fail "fallback row unexpectedly wrote an object"
[ -s "$FALLBACK_ASSEMBLY" ] || fail "fallback row did not write assembly"
[ ! -e "$FORCED_OBJECT" ] || fail "forced row unexpectedly wrote an object"
[ -s "$FORCED_ASSEMBLY" ] || fail "forced row did not write assembly"

LEGACY_ASSEMBLY="$WORKDIR/legacy.s"
LEGACY_LIST="$WORKDIR/legacy.list"
printf '%s|%s\n' "$FALLBACK_SOURCE" "$LEGACY_ASSEMBLY" > "$LEGACY_LIST"
if ! "$COMPILER" compile --batch "$LEGACY_LIST" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/legacy.stdout" 2> "$WORKDIR/legacy.stderr"; then
    sed 's/^/  /' "$WORKDIR/legacy.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/legacy.stderr" >&2 || true
    fail "legacy Windows assembly batch compile failed"
fi
assert_empty "$WORKDIR/legacy.stderr"
cmp "$LEGACY_ASSEMBLY" "$FORCED_ASSEMBLY" ||
    fail "forced assembly differs from the legacy batch output"
cmp "$LEGACY_ASSEMBLY" "$FALLBACK_ASSEMBLY" ||
    fail "automatic fallback assembly differs from the legacy batch output"

# Permanent object/forced-assembly differential sentinels. Together these
# cover an ordinary runtime/entry path, string/data relocations, an explicitly
# allowed Windows external symbol, wide immediates, control flow, register
# groups, tail calls, pointer copies, bounds checks, runtime traps/helpers, and
# the string/cast cases that previously crashed or returned the wrong result as
# partial direct objects. The u64 cast's forced half also preserves the assembly
# text assertions used by the integration manifest.
DIFFERENTIAL_LIST="$WORKDIR/differential.list"
DIFFERENTIAL_PLAN="$WORKDIR/differential.plan"
ALLOWED_EXTERN_SOURCE="$WORKDIR/allowed_external.tl"
cat > "$ALLOWED_EXTERN_SOURCE" <<'EOF'
(extern (win-get-std-handle [kind : i64]) : u64 (:symbol "GetStdHandle"))

(define (main) : i64
  (begin
    (win-get-std-handle -11)
    42))
EOF
TIME_EXTERNAL_SOURCE="$WORKDIR/time_externals.tl"
cat > "$TIME_EXTERNAL_SOURCE" <<'EOF'
(extern (win-get-system-time-as-file-time [out : i64]) : unit
  (:symbol "GetSystemTimeAsFileTime"))
(extern (win-query-performance-counter [out : i64]) : i32
  (:symbol "QueryPerformanceCounter"))
(extern (win-query-performance-frequency [out : i64]) : i32
  (:symbol "QueryPerformanceFrequency"))
(extern (win-sleep [milliseconds : i64]) : unit (:symbol "Sleep"))

(define (main) : i64
  (begin
    (win-get-system-time-as-file-time 0)
    (win-query-performance-counter 0)
    (win-query-performance-frequency 0)
    (win-sleep 0)
    42))
EOF
TIME_NEIGHBOR_SOURCE="$WORKDIR/time_neighbor_externals.tl"
cat > "$TIME_NEIGHBOR_SOURCE" <<'EOF'
(extern (win-get-system-time-precise-as-file-time [out : i64]) : unit
  (:symbol "GetSystemTimePreciseAsFileTime"))
(extern (win-query-thread-cycle-time [thread : i64] [out : i64]) : i32
  (:symbol "QueryThreadCycleTime"))
(extern (win-sleep-ex [milliseconds : i64] [alertable : i64]) : i64
  (:symbol "SleepEx"))

(define (main) : i64
  (begin
    (win-get-system-time-precise-as-file-time 0)
    (win-query-thread-cycle-time 0 0)
    (win-sleep-ex 0 0)
    42))
EOF
NT_CREATE_FILE_SOURCE="$WORKDIR/nt_create_file.tl"
cat > "$NT_CREATE_FILE_SOURCE" <<'EOF'
(extern (win-nt-create-file
  [file-handle : i64]
  [desired-access : i64]
  [object-attributes : i64]
  [io-status-block : i64]
  [allocation-size : i64]
  [file-attributes : i64]
  [share-access : i64]
  [create-disposition : i64]
  [create-options : i64]
  [ea-buffer : i64]
  [ea-length : i64]) : i32 (:symbol "NtCreateFile"))

(define (main) : i64
  (begin
    (win-nt-create-file 0 0 0 0 0 0 0 0 0 0 0)
    42))
EOF
NT_OPEN_FILE_SOURCE="$WORKDIR/nt_open_file.tl"
cat > "$NT_OPEN_FILE_SOURCE" <<'EOF'
(extern (win-nt-open-file
  [file-handle : i64]
  [desired-access : i64]
  [object-attributes : i64]
  [io-status-block : i64]
  [share-access : i64]
  [open-options : i64]) : i32 (:symbol "NtOpenFile"))

(define (main) : i64
  (begin
    (win-nt-open-file 0 0 0 0 0 0)
    42))
EOF

write_differential_rows() {
    _name=$1
    _source=$2
    printf '%s|%s/%s.direct.obj|%s/%s.direct.s\n' \
        "$_source" "$WORKDIR" "$_name" "$WORKDIR" "$_name" >> "$DIFFERENTIAL_LIST"
    printf '%s|%s/%s.forced-unused.obj|%s/%s.forced.s|force-assembly\n' \
        "$_source" "$WORKDIR" "$_name" "$WORKDIR" "$_name" >> "$DIFFERENTIAL_LIST"
}

: > "$DIFFERENTIAL_LIST"
write_differential_rows ordinary tests/integration/hello.tl
write_differential_rows string_data tests/integration/string_length.tl
write_differential_rows string_record_extent tests/integration/string_record_extent.tl
write_differential_rows allowed_external "$ALLOWED_EXTERN_SOURCE"
write_differential_rows time_external "$TIME_EXTERNAL_SOURCE"
write_differential_rows time_neighbor "$TIME_NEIGHBOR_SOURCE"
write_differential_rows nt_create_file "$NT_CREATE_FILE_SOURCE"
write_differential_rows nt_open_file "$NT_OPEN_FILE_SOURCE"
write_differential_rows runtime_trap tests/integration/div_zero_trap.tl
write_differential_rows wide_immediate tests/integration/integer_literal_boundary_matrix.tl
write_differential_rows branch_phi_switch tests/integration/enum_match.tl
write_differential_rows tail_call tests/integration/tail_call_stack_args.tl
write_differential_rows register_group tests/integration/register_group_try.tl
write_differential_rows pointer_copy tests/integration/ptr_aggregate_copy.tl
write_differential_rows bounds_check tests/integration/fixed_array_take.tl
write_differential_rows string_match tests/integration/string_match.tl
write_differential_rows u64_float_casts tests/integration/u64_float_casts.tl

if ! TYPELISP_WINDOWS_CLANG=__typelisp_unexpected_batch_assembler__.exe \
    "$COMPILER" compile --batch "$DIFFERENTIAL_LIST" \
    --windows-coff-plan "$DIFFERENTIAL_PLAN" \
    --target windows-x86_64 \
    --cfg windows \
    --stdlib-root stdlib \
    --stdlib-root src \
    > "$WORKDIR/differential.stdout" 2> "$WORKDIR/differential.stderr"; then
    sed 's/^/  /' "$WORKDIR/differential.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/differential.stderr" >&2 || true
    fail "Windows COFF differential batch compile failed"
fi
assert_empty "$WORKDIR/differential.stderr"

DIFFERENTIAL_EXPECTED="$WORKDIR/differential.expected.plan"
: > "$DIFFERENTIAL_EXPECTED"
write_differential_expected() {
    _name=$1
    _source=$2
    printf '%s|coff-object|%s/%s.direct.obj|none\n' \
        "$_source" "$WORKDIR" "$_name" >> "$DIFFERENTIAL_EXPECTED"
    printf '%s|assembly|%s/%s.forced.s|forced-assembly\n' \
        "$_source" "$WORKDIR" "$_name" >> "$DIFFERENTIAL_EXPECTED"
}
write_differential_expected ordinary tests/integration/hello.tl
write_differential_expected string_data tests/integration/string_length.tl
write_differential_expected string_record_extent tests/integration/string_record_extent.tl
write_differential_expected allowed_external "$ALLOWED_EXTERN_SOURCE"
write_differential_expected time_external "$TIME_EXTERNAL_SOURCE"
printf '%s|assembly|%s/%s.direct.s|unsupported-external-relocation\n' \
    "$TIME_NEIGHBOR_SOURCE" "$WORKDIR" time_neighbor >> "$DIFFERENTIAL_EXPECTED"
printf '%s|assembly|%s/%s.forced.s|forced-assembly\n' \
    "$TIME_NEIGHBOR_SOURCE" "$WORKDIR" time_neighbor >> "$DIFFERENTIAL_EXPECTED"
write_differential_expected nt_create_file "$NT_CREATE_FILE_SOURCE"
write_fallback_differential_expected() {
    _name=$1
    _source=$2
    printf '%s|assembly|%s/%s.direct.s|unsupported-object-semantics\n' \
        "$_source" "$WORKDIR" "$_name" >> "$DIFFERENTIAL_EXPECTED"
    printf '%s|assembly|%s/%s.forced.s|forced-assembly\n' \
        "$_source" "$WORKDIR" "$_name" >> "$DIFFERENTIAL_EXPECTED"
}
printf '%s|assembly|%s/%s.direct.s|unsupported-external-relocation\n' \
    "$NT_OPEN_FILE_SOURCE" "$WORKDIR" nt_open_file >> "$DIFFERENTIAL_EXPECTED"
printf '%s|assembly|%s/%s.forced.s|forced-assembly\n' \
    "$NT_OPEN_FILE_SOURCE" "$WORKDIR" nt_open_file >> "$DIFFERENTIAL_EXPECTED"
write_fallback_differential_expected runtime_trap tests/integration/div_zero_trap.tl
write_fallback_differential_expected wide_immediate tests/integration/integer_literal_boundary_matrix.tl
write_fallback_differential_expected branch_phi_switch tests/integration/enum_match.tl
write_fallback_differential_expected tail_call tests/integration/tail_call_stack_args.tl
write_fallback_differential_expected register_group tests/integration/register_group_try.tl
write_fallback_differential_expected pointer_copy tests/integration/ptr_aggregate_copy.tl
write_fallback_differential_expected bounds_check tests/integration/fixed_array_take.tl
write_fallback_differential_expected string_match tests/integration/string_match.tl
write_fallback_differential_expected u64_float_casts tests/integration/u64_float_casts.tl
cmp "$DIFFERENTIAL_EXPECTED" "$DIFFERENTIAL_PLAN" ||
    fail "Windows COFF differential plan changed classification"

for differential_case in ordinary string_data string_record_extent \
    allowed_external time_external nt_create_file; do
    [ -s "$WORKDIR/$differential_case.direct.obj" ] ||
        fail "differential direct object missing: $differential_case"
    [ ! -e "$WORKDIR/$differential_case.direct.s" ] ||
        fail "differential direct row wrote assembly: $differential_case"
    [ -s "$WORKDIR/$differential_case.forced.s" ] ||
        fail "differential forced assembly missing: $differential_case"
    [ ! -e "$WORKDIR/$differential_case.forced-unused.obj" ] ||
        fail "differential forced row wrote an object: $differential_case"
done
for differential_case in time_neighbor nt_open_file runtime_trap wide_immediate branch_phi_switch \
    tail_call register_group pointer_copy bounds_check string_match \
    u64_float_casts; do
    [ -s "$WORKDIR/$differential_case.direct.s" ] ||
        fail "automatic fallback assembly is missing: $differential_case"
    [ ! -e "$WORKDIR/$differential_case.direct.obj" ] ||
        fail "automatic fallback wrote an object: $differential_case"
    [ -s "$WORKDIR/$differential_case.forced.s" ] ||
        fail "forced assembly is missing: $differential_case"
    [ ! -e "$WORKDIR/$differential_case.forced-unused.obj" ] ||
        fail "forced assembly wrote an object: $differential_case"
    cmp "$WORKDIR/$differential_case.direct.s" \
        "$WORKDIR/$differential_case.forced.s" ||
        fail "automatic fallback differs from forced assembly: $differential_case"
done
[ -s "$WORKDIR/u64_float_casts.forced.s" ] ||
    fail "forced assembly text sentinel is missing"
[ ! -e "$WORKDIR/u64_float_casts.forced-unused.obj" ] ||
    fail "forced assembly text sentinel wrote an object"
assert_contains "$WORKDIR/u64_float_casts.forced.s" "cast_u64_float_"
assert_contains "$WORKDIR/u64_float_casts.forced.s" "cast_float_u64_"
assert_contains "$WORKDIR/u64_float_casts.forced.s" "    addsd "
assert_contains "$WORKDIR/u64_float_casts.forced.s" "    addss "
assert_contains "$WORKDIR/u64_float_casts.forced.s" "    ucomisd "
assert_contains "$WORKDIR/u64_float_casts.forced.s" "    ucomiss "
assert_contains "$WORKDIR/u64_float_casts.forced.s" '    btsq $63, '

MALFORMED_LIST="$WORKDIR/malformed.list"
MALFORMED_PLAN="$WORKDIR/malformed.plan"
printf '%s|%s\n' "$DIRECT_SOURCE" "$WORKDIR/malformed.obj" > "$MALFORMED_LIST"
printf 'stale plan must not survive\n' > "$MALFORMED_PLAN"
if "$COMPILER" compile --batch "$MALFORMED_LIST" \
    --windows-coff-plan "$MALFORMED_PLAN" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/malformed.stdout" 2> "$WORKDIR/malformed.stderr"; then
    fail "malformed Windows COFF batch unexpectedly succeeded"
fi
assert_contains "$WORKDIR/malformed.stderr" \
    "compile: malformed --batch line 1: missing assembly path"
[ ! -e "$MALFORMED_PLAN" ] ||
    fail "malformed Windows COFF batch wrote a result plan"

BAD_SOURCE="$WORKDIR/bad.tl"
cat > "$BAD_SOURCE" <<'EOF'
(define (main) : i64
  "not an integer")
EOF
FAILURE_LIST="$WORKDIR/failure.list"
FAILURE_PLAN="$WORKDIR/failure.plan"
SENTINEL_OBJECT="$WORKDIR/sentinel.obj"
SENTINEL_ASSEMBLY="$WORKDIR/sentinel.s"
printf 'stale plan must not survive\n' > "$FAILURE_PLAN"
printf '%s|%s|%s\n' \
    "$BAD_SOURCE" "$WORKDIR/bad.obj" "$WORKDIR/bad.s" > "$FAILURE_LIST"
printf '%s|%s|%s\n' \
    "$DIRECT_SOURCE" "$SENTINEL_OBJECT" "$SENTINEL_ASSEMBLY" >> "$FAILURE_LIST"
if "$COMPILER" compile --batch "$FAILURE_LIST" \
    --windows-coff-plan "$FAILURE_PLAN" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/failure.stdout" 2> "$WORKDIR/failure.stderr"; then
    fail "compile-error Windows COFF batch unexpectedly succeeded"
fi
assert_contains "$WORKDIR/failure.stderr" \
    "typecheck: return type mismatch: expected i64, found String"
assert_contains "$WORKDIR/failure.stderr" \
    "compile: batch source failed: $BAD_SOURCE"
[ ! -e "$FAILURE_PLAN" ] ||
    fail "failed Windows COFF batch wrote a result plan"
[ ! -e "$SENTINEL_OBJECT" ] ||
    fail "failed Windows COFF batch compiled the sentinel object"
[ ! -e "$SENTINEL_ASSEMBLY" ] ||
    fail "failed Windows COFF batch compiled the sentinel assembly"

if "$COMPILER" compile --batch "$BATCH_LIST" \
    --windows-coff-plan "$WORKDIR/linux-target.plan" \
    --target linux-x86_64 \
    > "$WORKDIR/linux-target.stdout" 2> "$WORKDIR/linux-target.stderr"; then
    fail "Windows COFF batch accepted a Linux target"
fi
assert_contains "$WORKDIR/linux-target.stderr" \
    "compile: --windows-coff-plan requires --target windows-x86_64"

if [ "$HOST_OS" = windows ]; then
    LINKER=
    if command -v lld-link >/dev/null 2>&1; then
        LINKER=$(command -v lld-link)
    elif command -v lld-link.exe >/dev/null 2>&1; then
        LINKER=$(command -v lld-link.exe)
    fi
    [ -n "$LINKER" ] || fail "missing Windows COFF linker: lld-link"
    command -v clang >/dev/null 2>&1 ||
        fail "missing Windows COFF assembly differential tool: clang"
    command -v powershell.exe >/dev/null 2>&1 ||
        fail "missing Windows COFF differential runner: powershell.exe"

    DIRECT_EXE="$WORKDIR/direct.exe"
    DIRECT_OBJECT_WIN=$(cygpath -aw "$DIRECT_OBJECT")
    DIRECT_EXE_WIN=$(cygpath -aw "$DIRECT_EXE")
    echo "[compile-batch-windows-coff] link and run direct object without clang"
    MSYS2_ARG_CONV_EXCL='*' "$LINKER" \
        /NOLOGO \
        "$DIRECT_OBJECT_WIN" \
        "/OUT:$DIRECT_EXE_WIN" \
        /SUBSYSTEM:CONSOLE \
        /ENTRY:_tl_start \
        /NODEFAULTLIB \
        /DYNAMICBASE:NO \
        /STACK:268435456 \
        kernel32.lib \
        ntdll.lib

    set +e
    "$DIRECT_EXE" > "$WORKDIR/direct.stdout" 2> "$WORKDIR/direct.stderr"
    direct_status=$?
    set -e
    [ "$direct_status" -eq 42 ] ||
        fail "direct batch object executable expected exit 42, got $direct_status"
    assert_empty "$WORKDIR/direct.stdout"
    assert_empty "$WORKDIR/direct.stderr"

    link_differential_object() {
        _diff_object=$1
        _diff_exe=$2
        _diff_object_win=$(cygpath -aw "$_diff_object")
        _diff_exe_win=$(cygpath -aw "$_diff_exe")
        MSYS2_ARG_CONV_EXCL='*' "$LINKER" \
            /NOLOGO \
            "$_diff_object_win" \
            "/OUT:$_diff_exe_win" \
            /SUBSYSTEM:CONSOLE \
            /ENTRY:_tl_start \
            /NODEFAULTLIB \
            /DYNAMICBASE:NO \
            /STACK:268435456 \
            kernel32.lib \
            ntdll.lib
    }

    run_differential_executable() {
        _diff_label=$1
        _diff_exe=$2
        _diff_stdout="$WORKDIR/$_diff_label.stdout"
        _diff_stderr="$WORKDIR/$_diff_label.stderr"
        _diff_exit="$WORKDIR/$_diff_label.exit"
        powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File "$(cygpath -aw "$ROOT/scripts/windows-integration-legacy-runner.ps1")" \
            "$(cygpath -aw "$_diff_exe")" \
            "$(cygpath -aw "$_diff_stdout")" \
            "$(cygpath -aw "$_diff_stderr")" \
            "$(cygpath -aw "$_diff_exit")" \
            > "$WORKDIR/$_diff_label.runner.stdout" \
            2> "$WORKDIR/$_diff_label.runner.stderr" ||
            fail "Windows COFF differential runner failed: $_diff_label"
        [ -s "$_diff_exit" ] ||
            fail "Windows COFF differential runner omitted exit: $_diff_label"
        DIFFERENTIAL_EXIT=$(tr -d '\r\n' < "$_diff_exit")
    }

    echo "[compile-batch-windows-coff] direct-object/forced-assembly differential"
    for differential_case in ordinary string_data string_record_extent \
        allowed_external nt_create_file nt_open_file runtime_trap \
        wide_immediate branch_phi_switch tail_call register_group pointer_copy \
        bounds_check string_match u64_float_casts; do
        differential_direct_object="$WORKDIR/$differential_case.direct.obj"
        differential_forced_assembly="$WORKDIR/$differential_case.forced.s"
        differential_forced_object="$WORKDIR/$differential_case.forced.obj"
        differential_direct_exe="$WORKDIR/$differential_case.direct.exe"
        differential_forced_exe="$WORKDIR/$differential_case.forced.exe"

        if [ -s "$WORKDIR/$differential_case.direct.s" ]; then
            clang --target=x86_64-pc-windows-msvc \
                -c "$WORKDIR/$differential_case.direct.s" \
                -o "$differential_direct_object"
        fi
        clang --target=x86_64-pc-windows-msvc \
            -c "$differential_forced_assembly" \
            -o "$differential_forced_object"
        link_differential_object "$differential_direct_object" "$differential_direct_exe"
        link_differential_object "$differential_forced_object" "$differential_forced_exe"

        run_differential_executable "$differential_case.direct" "$differential_direct_exe"
        differential_direct_exit=$DIFFERENTIAL_EXIT
        run_differential_executable "$differential_case.forced" "$differential_forced_exe"
        differential_forced_exit=$DIFFERENTIAL_EXIT

        [ "$differential_direct_exit" = "$differential_forced_exit" ] ||
            fail "Windows COFF differential exit mismatch for $differential_case: direct=$differential_direct_exit forced=$differential_forced_exit"
        cmp "$WORKDIR/$differential_case.direct.stdout" \
            "$WORKDIR/$differential_case.forced.stdout" ||
            fail "Windows COFF differential stdout mismatch: $differential_case"
        cmp "$WORKDIR/$differential_case.direct.stderr" \
            "$WORKDIR/$differential_case.forced.stderr" ||
            fail "Windows COFF differential stderr mismatch: $differential_case"

        case "$differential_case" in
            ordinary | string_record_extent | allowed_external | \
                nt_create_file | nt_open_file | \
                wide_immediate | branch_phi_switch | \
                tail_call | register_group | bounds_check | string_match)
                [ "$differential_direct_exit" = 42 ] ||
                    fail "Windows COFF differential expected exit 42 for $differential_case, got $differential_direct_exit"
                ;;
            string_data)
                [ "$differential_direct_exit" = 5 ] ||
                    fail "Windows COFF differential expected exit 5 for string_data, got $differential_direct_exit"
                ;;
            runtime_trap)
                [ "$differential_direct_exit" != 0 ] ||
                    fail "Windows COFF runtime-trap differential unexpectedly succeeded"
                ;;
            pointer_copy | u64_float_casts)
                [ "$differential_direct_exit" = 0 ] ||
                    fail "Windows COFF differential expected exit 0 for $differential_case, got $differential_direct_exit"
                ;;
        esac
    done
fi

echo "Windows COFF batch verifier passed"
