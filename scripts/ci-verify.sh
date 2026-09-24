#!/usr/bin/env sh
set -eu

# ci-verify.sh - the repository's CI verification gate.
#
# Runs the gates of scripts/ci-gates.tsv in table order. Fetches the published
# stage0 artifact when TYPELISP_BIN is unset. The seed performs the single
# compiler build of the flow: the stage1->stage2->stage3 bootstrap fixpoint over
# src/main.tl, with a stage4 fallback when needed. Every remaining gate then
# runs on the converged compiler (the branch-built full CLI).
#
# --gates runs a dependency-closed subset of the same table: the named gates
# plus every gate their needs reach, in table order. A subset is a partial
# result, never a verification success.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
GATES_FILE="$ROOT/scripts/ci-gates.tsv"

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-verify.sh [--gates ID[,ID...]]
       scripts/ci-verify.sh --list-gates linux|windows [--gates ID[,ID...]]

Runs the repository's CI verification gate: every gate of scripts/ci-gates.tsv
that applies to this host, in table order.
If TYPELISP_BIN is unset, downloads stage0-latest with scripts/fetch-stage0.sh.
TYPELISP_BIN is the seed compiler and performs the single compiler build of
the flow: the bootstrap stage1->stage2->stage3 fixpoint over src/main.tl, with
a stage4 fallback when needed. Every remaining gate runs on the converged
bootstrapped compiler.

--gates runs only the named host gates plus the closure of their needs, in
table order. Unless that closure is the whole host inventory the result is
partial: no verification-complete timing row and no success message.

--list-gates prints the host inventory, or with --gates the dependency-closed
selection, without running CI.
EOF
}

# Agent/contributor note: do not make CI pass by skipping gates when a PR needs
# a new compiler/runtime capability. Split that work instead: first land the
# compiler/runtime support, then land a follow-up PR that uses the new feature.
# A short green run caused by skipped gates is a CI bug, not a successful check.
#
# NO-RETRY POLICY (#1204): the verify-* gates run each `typelisp` invocation
# exactly once. A crash (segfault / Windows access violation / illegal
# instruction) is a real compiler/runtime bug, NOT transient infra flake — fix
# the bug. Do NOT re-introduce a retry loop or a `VERIFY_*_ATTEMPTS`-style knob
# to retry crashing invocations: that only hides the bug behind a green run, as
# the old #1204 retry masking did for months. (The release-republish retry in
# fetch-stage0.sh is unrelated — it rides out a genuinely transient mutable-asset
# race, not a compiler crash.)

# ci_gates_plan HOST [ID,...]
#   Validate the whole table, then print the HOST rows (id, hosts, label,
#   needs projected onto HOST, compiler, command), or only the requested gates
#   plus the closure of their needs, in table order.
ci_gates_plan() {
    awk -F '\t' -v host="$1" -v request="${2:-}" '
        function fail(message) {
            print "ci-gates.tsv: " message > "/dev/stderr"
            invalid = 1
            exit 1
        }
        { sub(/\r$/, "") }
        /^#/ { next }
        !header {
            if ($0 != "id\thosts\tlabel\tneeds\tcompiler\tcommand")
                fail("line " NR ": expected the id/hosts/label/needs/compiler/command header")
            header = 1
            next
        }
        {
            if (NF != 6 || $1 !~ /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/)
                fail("line " NR ": expected six fields and a lowercase kebab-case ID")
            if ($2 != "all" && $2 != "linux" && $2 != "windows") fail("line " NR ": invalid hosts: " $2)
            if ($3 == "") fail("line " NR ": empty label")
            if ($5 != "-" && $5 != "stage2" && $5 != "profile") fail("line " NR ": invalid compiler: " $5)
            if ($6 == "") fail("line " NR ": empty command")
            if ($1 in gate_hosts) fail("line " NR ": duplicate gate ID: " $1)
            gate_hosts[$1] = $2
            # A need names an earlier gate that runs wherever this one does,
            # optionally on one host only, so table order is a topological order.
            projected = ""
            if ($4 != "-") {
                count = split($4, list, ",")
                for (n = 1; n <= count; n++) {
                    need = list[n]
                    need_host = ""
                    at = index(need, "@")
                    if (at > 0) {
                        need_host = substr(need, at + 1)
                        need = substr(need, 1, at - 1)
                        if (need_host != "linux" && need_host != "windows") fail("line " NR ": invalid need host: " list[n])
                    }
                    if (!(need in gate_hosts) || need == $1) fail("line " NR ": " $1 " needs an unknown or later gate: " need)
                    covered = (need_host != "" ? need_host : $2)
                    if (gate_hosts[need] != "all" && gate_hosts[need] != covered)
                        fail("line " NR ": " $1 " needs a gate that does not run on its hosts: " need)
                    if (need_host == "" || need_host == host) projected = (projected == "" ? need : projected "," need)
                }
            }
            if ($2 != "all" && $2 != host) next
            rows++
            row[rows] = $1 "\t" $2 "\t" $3 "\t" (projected == "" ? "-" : projected) "\t" $5 "\t" $6
            needs[rows] = projected
            position[$1] = rows
        }
        END {
            if (invalid) exit 1
            if (!rows) fail("no gates for " host)
            if (request == "") {
                for (k = 1; k <= rows; k++) print row[k]
                exit 0
            }
            count = split(request, requested, ",")
            for (r = 1; r <= count; r++) {
                id = requested[r]
                if (id == "") fail("empty gate ID in selection: " request)
                if (seen[id]++) fail("duplicate gate in selection: " id)
                if (!(id in position)) {
                    if (id in gate_hosts) fail("gate does not run on " host " (" gate_hosts[id] "): " id)
                    fail("unknown gate in selection: " id)
                }
                selected[position[id]] = 1
            }
            # Needs name earlier gates only, so one reverse pass is a closure.
            for (k = rows; k >= 1; k--) {
                if (!selected[k] || needs[k] == "") continue
                count = split(needs[k], list, ",")
                for (n = 1; n <= count; n++) selected[position[list[n]]] = 1
            }
            for (k = 1; k <= rows; k++) if (selected[k]) print row[k]
        }
    ' "$GATES_FILE"
}

# Every command must name something that exists: the scripts/ files it runs
# and the gate_* functions defined in this file.
ci_gates_check_commands() {
    _ci_missing=0
    for _ci_word in $(awk -F '\t' '!/^#/ && NF == 6 && $1 != "id" { print $6 }' "$GATES_FILE" |
        tr -d '\r"' | tr ' ' '\n' |
        grep -E '^(gate_[a-z0-9_]+|scripts/[A-Za-z0-9._/-]+)$' | sort -u); do
        case "$_ci_word" in
            gate_*) command -v "$_ci_word" >/dev/null 2>&1 ;;
            *) [ -f "$ROOT/$_ci_word" ] ;;
        esac || {
            echo "ci-gates.tsv: command names a missing script or gate function: $_ci_word" >&2
            _ci_missing=1
        }
    done
    return "$_ci_missing"
}

ci_verify_error() {
    echo "[ci-verify] ERROR: $*" >&2
}

required_gate_unavailable() {
    gate=$1
    shift
    echo >&2
    ci_verify_error "CI must run every required gate; skipped gates hide compiler regressions."
    ci_verify_error "unable to run required gate: $gate"
    for detail in "$@"; do
        echo "[ci-verify]   $detail" >&2
    done
    exit 1
}

ensure_executable() {
    label=$1
    compiler=$2
    if [ ! -f "$compiler" ]; then
        echo "$label compiler does not exist: $compiler" >&2
        exit 1
    fi
    if [ ! -x "$compiler" ]; then
        chmod +x "$compiler" 2>/dev/null || true
    fi
    if [ ! -x "$compiler" ]; then
        echo "$label compiler is not executable: $compiler" >&2
        exit 1
    fi
}

# Read the one path a producer gate wrote to PATH_FILE into CI_VERIFY_HANDOFF.
read_handoff() {
    if [ ! -s "$2" ]; then
        ci_verify_error "$1 did not write its handoff path: $2"
        return 1
    fi
    CI_VERIFY_HANDOFF=$(sed -n '1p' "$2")
}

# Gates whose setup or handoff does not fit one command line. A gate runs with
# errexit off, so each step checks its own status.

# The single compiler build of the flow: the seed bootstraps src/main.tl through
# successive stages at opt2 until the compiler's own code converges (normally
# stage2 == stage3, with a stage3 == stage4 fallback). Every later gate runs on
# the resulting converged compiler - the branch-built full CLI, handed over via
# the compatibility-named stage2 path file - so the artifact under test is the
# one the bootstrap just produced. Do not add per-gate compiler rebuilds.
gate_bootstrap_fixpoint() {
    _ci_stage1_path_file="$ROOT/target/ci-verify-stage1.path"
    _ci_stage2_path_file="$ROOT/target/ci-verify-stage2.path"
    rm -f "$_ci_stage1_path_file" "$_ci_stage2_path_file"
    TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$_ci_stage1_path_file \
        TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE=$_ci_stage2_path_file \
        scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN" || return $?
    # The cross-mode differential also runs the previous-stage compiler.
    read_handoff "bootstrap previous-stage compiler capture" "$_ci_stage1_path_file" || return 1
    STAGE1_BIN=$CI_VERIFY_HANDOFF
    ensure_executable "previous-stage" "$STAGE1_BIN"
    read_handoff "bootstrap fixpoint compiler capture" "$_ci_stage2_path_file" || return 1
    STAGE2_BIN=$CI_VERIFY_HANDOFF
    ensure_executable "bootstrapped compiler" "$STAGE2_BIN"
    echo "[ci-verify] every gate runs the converged bootstrapped compiler: $STAGE2_BIN"

    # Fail-closed run-capability probe: stage2 must compile -> assemble -> link ->
    # RUN a native program before the run-assert tiers may execute. A failed
    # probe is a CI failure, never a reason to omit gates.
    if [ "$HOST_OS" = linux ]; then
        if ! stage2_safety_corpus_supported "$STAGE2_BIN"; then
            required_gate_unavailable "Linux stage2 compile->as->ld->run probe" \
                "safety, integration, examples, SPMD, and stdlib run-assert tiers depend on this probe"
        fi
        echo "[ci-verify] stage2 compile->as->ld->run capability confirmed"
    else
        if ! stage2_can_compile_native_windows "$STAGE2_BIN"; then
            required_gate_unavailable "Windows stage2 compile->clang->lld-link->run probe" \
                "safety, integration, and examples run-assert tiers depend on this probe"
        fi
        echo "[ci-verify] stage2 compile->clang->lld-link->run capability confirmed"
    fi
}

stage2_safety_corpus_supported() {
    compiler=$1
    probe_dir="$ROOT/target/ci-verify-safety-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    asm="$probe_dir/division_by_zero_trap.s"
    obj="$probe_dir/division_by_zero_trap.o"
    bin="$probe_dir/division_by_zero_trap"

    if ! "$compiler" compile "$ROOT/tests/safety/division_by_zero_trap.tl" \
        --target linux-x86_64 \
        --stdlib-root "$ROOT/stdlib" \
        -o "$asm" \
        > "$probe_dir/compile.stdout" 2> "$probe_dir/compile.stderr"; then
        echo "[ci-verify] stage2 safety probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/compile.stderr" >&2 || true
        return 1
    fi
    if ! as "$asm" -o "$obj" > "$probe_dir/assemble.stdout" 2> "$probe_dir/assemble.stderr"; then
        echo "[ci-verify] stage2 safety probe assemble failed"
        sed 's/^/  /' "$probe_dir/assemble.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/assemble.stderr" >&2 || true
        return 1
    fi
    if ! ld "$obj" -o "$bin" -static -e "$(linux_entry_symbol_for_asm "$asm")" \
        > "$probe_dir/link.stdout" 2> "$probe_dir/link.stderr"; then
        echo "[ci-verify] stage2 safety probe link failed"
        sed 's/^/  /' "$probe_dir/link.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/link.stderr" >&2 || true
        return 1
    fi

    "$bin" > "$probe_dir/run.stdout" 2> "$probe_dir/run.stderr"
    probe_status=$?
    if [ "$probe_status" -ne 135 ]; then
        echo "[ci-verify] stage2 safety probe expected guarded div-zero exit 135, got $probe_status"
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    if ! grep -F \
        "integer division or remainder error: dividend=1 divisor=0" \
        "$probe_dir/run.stderr" >/dev/null; then
        echo "[ci-verify] stage2 safety probe missing guarded div-zero stderr" >&2
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    return 0
}

# Windows analog of stage2_safety_corpus_supported: can the bootstrapped Windows
# stage1 compile -> clang -> lld-link -> RUN a native program? Uses a normal
# exit-42 fixture (not a trap: bare hardware traps surface as Windows structured
# exceptions whose shell exit code is unstable under MSYS/Git Bash).
stage2_can_compile_native_windows() {
    compiler=$1
    probe_dir="$ROOT/target/ci-verify-win-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    asm="$probe_dir/probe.s"
    obj="$probe_dir/probe.obj"
    bin="$probe_dir/probe.exe"
    if ! "$compiler" compile "$ROOT/tests/safety/integer_wrap_cast_defined.tl" \
        --target windows-x86_64 --stdlib-root "$ROOT/stdlib" -o "$asm" \
        > "$probe_dir/compile.out" 2>&1; then
        echo "[ci-verify] windows stage2 compile-native probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.out" >&2 || true
        return 1
    fi
    if ! clang --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" \
        > "$probe_dir/asm.out" 2>&1; then
        echo "[ci-verify] windows stage2 compile-native probe assemble failed"
        sed 's/^/  /' "$probe_dir/asm.out" >&2 || true
        return 1
    fi
    if ! lld-link -NOLOGO "$(cygpath -aw "$obj")" "-OUT:$(cygpath -aw "$bin")" \
        -SUBSYSTEM:CONSOLE -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib ntdll.lib \
        > "$probe_dir/link.out" 2>&1; then
        echo "[ci-verify] windows stage2 compile-native probe link failed"
        sed 's/^/  /' "$probe_dir/link.out" >&2 || true
        return 1
    fi
    "$bin" < /dev/null > "$probe_dir/run.out" 2>&1
    probe_status=$?
    if [ "$probe_status" -ne 42 ]; then
        echo "[ci-verify] windows stage2 compile-native probe expected exit 42, got $probe_status"
        return 1
    fi
    return 0
}

# Linux build-invariance publishes its validated stage4 src/main @ opt1
# assembly; the opt2 gate reuses it as its reference instead of compiling it
# again. Windows has no build-invariance gate, so the opt2 gate retains its
# standalone reference compile there.
gate_build_invariance() {
    _ci_reference_path_file="$ROOT/target/ci-verify-opt2-reference.path"
    rm -f "$_ci_reference_path_file"
    TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE=$_ci_reference_path_file \
        scripts/check-build-invariance.sh || return $?
    read_handoff "build-invariance opt1 reference handoff" "$_ci_reference_path_file" || return 1
    OPT2_REFERENCE_ASM=$CI_VERIFY_HANDOFF
    if [ ! -s "$OPT2_REFERENCE_ASM" ]; then
        ci_verify_error "build-invariance published a missing or empty assembly: $OPT2_REFERENCE_ASM"
        return 1
    fi
}

gate_opt2_cli_regression() {
    if [ "$HOST_OS" = windows ]; then
        scripts/check-opt2-cli-regression.sh
        return $?
    fi
    echo "[ci-verify] opt2 gate reuses build-invariance reference: $OPT2_REFERENCE_ASM"
    TYPELISP_OPT2_CLI_REFERENCE_ASM=$OPT2_REFERENCE_ASM scripts/check-opt2-cli-regression.sh
}

# The compile-profile verifier reuses the embedded stdlib image the image gate
# built and publishes its profile-enabled CLI, which the TLCI stress and
# package gates run instead of paying for another full self-compile.
gate_compile_profile() {
    _ci_profile_path_file="$ROOT/target/ci-verify-compile-profile-cli.path"
    rm -f "$_ci_profile_path_file"
    TYPELISP_COMPILE_PROFILE_CLI_PATH_FILE=$_ci_profile_path_file \
        TYPELISP_COMPILE_PROFILE_EMBEDDED_TLCI_REUSE=1 \
        scripts/verify-compile-profile.sh || return $?
    read_handoff "compile-profile verifier" "$_ci_profile_path_file" || return 1
    COMPILE_PROFILE_BIN=$CI_VERIFY_HANDOFF
    ensure_executable "compile-profile" "$COMPILE_PROFILE_BIN"
}

# On Linux the benchmark suites run the cases perf/benchmark-ci-cases.tsv
# assigns them; Windows runs every case.
gate_benchmark_correctness() {
    if [ "$HOST_OS" = windows ]; then
        scripts/bench.sh --correctness
        return $?
    fi
    _ci_cases=$(benchmark_ci_case_csv "$ROOT" benchmark) || return $?
    scripts/bench.sh --correctness --cases "$_ci_cases"
}

gate_optimization_opt2_correctness() {
    if [ "$HOST_OS" = windows ]; then
        scripts/run-optimization-benchmarks.sh --correctness --tl-opt-level 2
        return $?
    fi
    _ci_cases=$(benchmark_ci_case_csv "$ROOT" optimization-opt2) || return $?
    scripts/run-optimization-benchmarks.sh --correctness --tl-opt-level 2 \
        --cases "$_ci_cases"
}

# check-instruction-counts.sh reports and skips without valgrind; required CI
# must not, so both instruction-count gates require it here.
require_valgrind() {
    command -v valgrind >/dev/null 2>&1 ||
        required_gate_unavailable "Linux instruction-count baseline" \
            "valgrind is required on Linux; install valgrind rather than skipping this gate"
}

gate_instruction_counts() {
    require_valgrind
    TYPELISP_IR_CHECK_COMPILER=$STAGE2_BIN scripts/check-instruction-counts.sh
}

gate_heavy_instruction_counts() {
    require_valgrind
    _ci_cases=$(benchmark_ci_case_csv "$ROOT" instruction-heavy) || return $?
    TYPELISP_IR_CHECK_COMPILER=$STAGE2_BIN scripts/check-instruction-counts.sh \
        --baseline perf/insn-exec-heavy-baseline.tsv \
        --benchmarks "$_ci_cases" \
        --benchmarks-only \
        --runs 1 \
        --output target/instruction-count-heavy
}

# Arguments and listing are read-only and must be handled before any runtime
# initialization.
CI_VERIFY_GATES=
case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
    --list-gates)
        if { [ "$#" -ne 2 ] && { [ "$#" -ne 4 ] || [ "$3" != --gates ]; }; } ||
            { [ "$2" != linux ] && [ "$2" != windows ]; }; then
            usage
            exit 2
        fi
        # Validate the whole table before printing anything.
        ci_gates_check_commands
        CI_VERIFY_PLAN=$(ci_gates_plan "$2" "${4:-}")
        printf 'id\thosts\tlabel\tneeds\n'
        printf '%s\n' "$CI_VERIFY_PLAN" | cut -f 1-4
        exit 0
        ;;
    --gates)
        if [ "$#" -ne 2 ] || [ -z "$2" ]; then
            usage
            exit 2
        fi
        CI_VERIFY_GATES=$2
        ;;
    *)
        if [ "$#" -ne 0 ]; then
            usage
            exit 2
        fi
        ;;
esac

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-benchmark-ci-cases.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "CI verification is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

ci_gates_check_commands
CI_VERIFY_INVENTORY=$(ci_gates_plan "$HOST_OS")
CI_VERIFY_PLAN=$(ci_gates_plan "$HOST_OS" "$CI_VERIFY_GATES")
CI_VERIFY_HOST_COUNT=$(printf '%s\n' "$CI_VERIFY_INVENTORY" | awk 'END { print NR }')
CI_VERIFY_SELECTED_COUNT=$(printf '%s\n' "$CI_VERIFY_PLAN" | awk 'END { print NR }')
CI_VERIFY_COMPLETE=0
if [ "$CI_VERIFY_SELECTED_COUNT" = "$CI_VERIFY_HOST_COUNT" ]; then
    CI_VERIFY_COMPLETE=1
fi
if [ -n "$CI_VERIFY_GATES" ]; then
    if [ "$CI_VERIFY_COMPLETE" != 1 ]; then
        echo "[ci-verify] partial run: $CI_VERIFY_SELECTED_COUNT of $CI_VERIFY_HOST_COUNT $HOST_OS gates"
        printf '%s\n' "$CI_VERIFY_PLAN" | awk -F '\t' -v request=",$CI_VERIFY_GATES," '
            {print "[ci-verify]   " (index(request, "," $1 ",") ? "requested " : "needed    ") $1}'
    else
        echo "[ci-verify] --gates $CI_VERIFY_GATES closes over the complete $HOST_OS inventory"
    fi
fi

if [ "${TYPELISP_CI_TIMING:-0}" = 1 ]; then
    ci_timing_init "$ROOT/target/ci-timing/$HOST_OS.tsv" "$HOST_OS"
    ci_timing_set_now_ms
    CI_VERIFY_STARTED_MS=$CI_TIMING_NOW_MS
    trap 'ci_timing_summary "$TYPELISP_CI_TIMING_FILE" 10' EXIT
fi

# Only the bootstrap consumes the seed; a selection without it needs none.
SEED_TYPELISP_BIN=
case ",$(printf '%s\n' "$CI_VERIFY_PLAN" | cut -f 1 | tr '\n' ',')" in
    *,bootstrap-fixpoint,*)
        if [ -z "${TYPELISP_BIN:-}" ]; then
            scripts/fetch-stage0.sh
            SEED_TYPELISP_BIN="$ROOT/target/stage0/typelisp"
            if [ "$HOST_OS" = windows ]; then
                SEED_TYPELISP_BIN="$SEED_TYPELISP_BIN.exe"
            fi
        else
            SEED_TYPELISP_BIN=$TYPELISP_BIN
        fi
        ensure_executable "seed" "$SEED_TYPELISP_BIN"
        ;;
esac

# Produced compilers and artifact paths are set only by the gate that produces
# them. Until that gate runs they name a path that cannot exist, so a missing
# need fails its consumer instead of falling back to some other compiler. A gate
# whose compiler column is `-` sees such a path as TYPELISP_BIN, so a gate that
# uses a compiler without naming one fails instead of falling back to the seed.
CI_VERIFY_UNPRODUCED="$ROOT/target/ci-verify-unproduced"
rm -rf "$CI_VERIFY_UNPRODUCED"
STAGE1_BIN="$CI_VERIFY_UNPRODUCED/previous-stage-compiler"
STAGE2_BIN="$CI_VERIFY_UNPRODUCED/converged-compiler"
COMPILE_PROFILE_BIN="$CI_VERIFY_UNPRODUCED/compile-profile-compiler"
OPT2_REFERENCE_ASM="$CI_VERIFY_UNPRODUCED/build-invariance-opt1-reference.s"
CI_VERIFY_NO_COMPILER="$CI_VERIFY_UNPRODUCED/gate-names-no-compiler"

# run_gate LABEL COMPILER COMMAND
run_gate() {
    case "$2" in
        stage2) gate_bin=$STAGE2_BIN ;;
        profile) gate_bin=$COMPILE_PROFILE_BIN ;;
        *) gate_bin=$CI_VERIFY_NO_COMPILER ;;
    esac
    TYPELISP_CI_TIMING_GATE=$1
    export TYPELISP_CI_TIMING_GATE
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        start=$CI_TIMING_NOW_MS
    else
        start=$(date +%s)
    fi
    echo
    echo "[ci-verify] START $1"
    set +e
    if [ "$2" != - ] && [ ! -x "$gate_bin" ]; then
        ci_verify_error "$1 compiler was not produced by this run: $gate_bin"
        status=126
    else
        TYPELISP_BIN=$gate_bin
        export TYPELISP_BIN
        eval "$3"
        status=$?
    fi
    set -e
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        end=$CI_TIMING_NOW_MS
        elapsed_ms=$((end - start))
        elapsed=$((elapsed_ms / 1000))
        ci_timing_record_elapsed all gate "$elapsed_ms" "$status"
    else
        end=$(date +%s)
        elapsed=$((end - start))
    fi
    if [ "$status" -eq 0 ]; then
        echo "[ci-verify] PASS $1 (${elapsed}s)"
    else
        echo "[ci-verify] FAIL $1 (${elapsed}s, exit $status)" >&2
    fi
    return "$status"
}

echo "[ci-verify] host=$HOST_OS seed=${SEED_TYPELISP_BIN:-<unused by this selection>}"

# Gates may read standard input, so the plan is read from descriptor 3.
CI_VERIFY_PLAN_FILE="$ROOT/target/ci-verify-plan.tsv"
mkdir -p "$ROOT/target"
printf '%s\n' "$CI_VERIFY_PLAN" > "$CI_VERIFY_PLAN_FILE"
TAB=$(printf '\t')
while IFS=$TAB read -r gate_id gate_hosts gate_label gate_needs gate_compiler_kind gate_command <&3; do
    run_gate "$gate_label" "$gate_compiler_kind" "$gate_command" || exit $?
done 3< "$CI_VERIFY_PLAN_FILE"

# A selection that does not close over the whole inventory proves only its own
# gates: it must not look like a verification to timing or log consumers.
if [ "$CI_VERIFY_COMPLETE" != 1 ]; then
    echo
    echo "CI verification partial: $CI_VERIFY_SELECTED_COUNT of $CI_VERIFY_HOST_COUNT $HOST_OS gates passed; this is not a complete verification"
    exit 0
fi

if ci_timing_enabled; then
    ci_timing_record_verification_complete "$CI_VERIFY_STARTED_MS" 0
fi

echo
echo "CI verification passed"
