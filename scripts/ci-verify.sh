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
#
# --jobs N runs up to N gates at once: a gate starts once every gate it needs
# passed and while the memory and CPU reservations of the running gates fit
# --memory-mib and --cpu-slots. One job, the default, runs the table in order.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
GATES_FILE="$ROOT/scripts/ci-gates.tsv"
HOST_TOOLS_FILE="$ROOT/scripts/ci-host-tools.tsv"
TAB=$(printf '\t')

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-verify.sh [--gates ID[,ID...]] [--jobs N --memory-mib MIB] [--cpu-slots N]
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

--jobs N (1-16, default 1) runs up to N gates at once. A gate starts once every
gate it needs passed and while the memory column of the running gates, plus
its own, fits --memory-mib, which --jobs above 1 requires. Each gate's output is
printed whole when it finishes. Every gate still runs, and the first failure
stops further starts.

--cpu-slots N (1-16384, default: the host's online CPU count) also budgets each
gate's CPU column. The column counts its default concurrent compiler workers,
so nested pools reserve more than one slot. This is admission, not a CPU quota;
custom nested worker counts still need an appropriate budget. A gate needing
more slots than the budget runs alone.

Before the first gate starts, every host tool that scripts/ci-host-tools.tsv
lists for a selected gate must be usable; a missing one fails the run at once
with its install hint.

--list-gates prints the host inventory, or with --gates the dependency-closed
selection, without running CI.
EOF
}

# Agent/contributor note: do not make CI pass by skipping gates when a PR needs
# a new compiler/runtime capability. Split that work instead: first land the
# compiler/runtime support, then land a follow-up PR that uses the new feature.
# A short green run caused by skipped gates is a CI bug, not a successful check.
#
# NO-RETRY POLICY: the verify-* gates run each `typelisp` invocation
# exactly once. A crash (segfault / Windows access violation / illegal
# instruction) is a real compiler/runtime bug, NOT transient infra flake — fix
# the bug. Do NOT re-introduce a retry loop or a `VERIFY_*_ATTEMPTS`-style knob
# to retry crashing invocations: that only hides the bug behind a green run.
# (The release-republish retry in fetch-stage0.sh is unrelated — it rides out a
# genuinely transient mutable-asset race, not a compiler crash.)

# ci_gates_plan HOST [ID,...]
#   Validate the whole table, then print the HOST rows (id, hosts, label,
#   needs projected onto HOST, compiler, memory, cpu, locks, command), or only the
#   requested gates plus the closure of their needs, in table order.
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
            if ($0 != "id\thosts\tlabel\tneeds\tcompiler\tmemory\tcpu\tlocks\tcommand")
                fail("line " NR ": expected the id/hosts/label/needs/compiler/memory/cpu/locks/command header")
            header = 1
            next
        }
        {
            if (NF != 9 || $1 !~ /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/)
                fail("line " NR ": expected nine fields and a lowercase kebab-case ID")
            if ($2 != "all" && $2 != "linux" && $2 != "windows") fail("line " NR ": invalid hosts: " $2)
            if ($3 == "") fail("line " NR ": empty label")
            if ($5 != "-" && $5 != "stage2" && $5 != "profile") fail("line " NR ": invalid compiler: " $5)
            if ($6 !~ /^[1-9][0-9]*$/) fail("line " NR ": memory must be a positive MiB count: " $6)
            if ($7 !~ /^([1-9]|1[0-6])$/) fail("line " NR ": CPU slots must be an integer from 1 to 16: " $7)
            if ($8 != "-" && $8 !~ /^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$/) fail("line " NR ": invalid locks: " $8)
            if ($9 == "") fail("line " NR ": empty command")
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
                    if (need_host == "") direct[need] = 1
                }
            }
            # A gate receives a produced compiler only from a gate it needs.
            if ($5 == "stage2" && !direct["bootstrap-fixpoint"])
                fail("line " NR ": " $1 " runs the stage2 compiler without needing bootstrap-fixpoint")
            if ($5 == "profile" && !direct["stage2-compile-profile-verifier"])
                fail("line " NR ": " $1 " runs the profile compiler without needing stage2-compile-profile-verifier")
            delete direct
            if ($2 != "all" && $2 != host) next
            rows++
            row[rows] = $1 "\t" $2 "\t" $3 "\t" (projected == "" ? "-" : projected) "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
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
    for _ci_word in $(awk -F '\t' '!/^#/ && NF == 9 && $1 != "id" { print $9 }' "$GATES_FILE" |
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

# ci_host_tools_plan HOST [ID,...]
#   Validate the whole host-tool table against the gate table, then print the
#   HOST rows of the selected gates: tool, the selected gates that run it, check
#   and install.
ci_host_tools_plan() {
    awk -F '\t' -v host="$1" -v selection=",${2:-}," '
        function fail(message) {
            print "ci-host-tools.tsv: " message > "/dev/stderr"
            invalid = 1
            exit 1
        }
        { sub(/\r$/, "") }
        # ci_gates_plan has validated the gate table; only its hosts are read.
        FNR == NR {
            if (/^#/) next
            if (gates_header++) gate_hosts[$1] = $2
            next
        }
        /^#/ { next }
        !header {
            if ($0 != "tool\thosts\tgates\tcheck\tinstall")
                fail("line " FNR ": expected the tool/hosts/gates/check/install header")
            header = 1
            next
        }
        {
            if (NF != 5 || $1 == "" || $3 == "" || $4 == "" || $5 == "")
                fail("line " FNR ": expected five nonempty fields")
            if ($2 != "all" && $2 != "linux" && $2 != "windows") fail("line " FNR ": invalid hosts: " $2)
            count = split($3, list, ",")
            selected = ""
            for (n = 1; n <= count; n++) {
                id = list[n]
                if (id == "") fail("line " FNR ": empty gate ID in: " $3)
                if (!(id in gate_hosts)) fail("line " FNR ": unknown gate: " id)
                if (row_gates[id]++) fail("line " FNR ": duplicate gate: " id)
                if (gate_hosts[id] != "all" && gate_hosts[id] != $2)
                    fail("line " FNR ": " id " does not run on every host of the row (" gate_hosts[id] ")")
                if (($2 == "all" || $2 == host) && index(selection, "," id ","))
                    selected = (selected == "" ? id : selected ", " id)
            }
            delete row_gates
            if (selected != "") print $1 "\t" selected "\t" $4 "\t" $5
        }
        END {
            if (invalid) exit 1
            if (!header) fail("missing the tool/hosts/gates/check/install header")
        }
    ' "$GATES_FILE" "$HOST_TOOLS_FILE"
}

# ci_host_gnu_time BIN
#   BIN is GNU time: it reports a resident-set peak through -f %M, which the
#   TLCI native-route RSS guard reads, and through -v, which the docs-site one
#   reads.
ci_host_gnu_time() {
    [ -x "$1" ] || return 1
    _ci_peak_kb=$("$1" -f '%M' true 2>&1 >/dev/null) || return 1
    case "$_ci_peak_kb" in
        "" | *[!0-9]*) return 1 ;;
    esac
    "$1" -v -o /dev/null true >/dev/null 2>&1
}

# ci_host_tools_require HOST ID,...
#   Before any gate starts, fail when this host lacks a tool that a selected
#   gate runs, listing every missing tool with its gates and install hint.
ci_host_tools_require() {
    _ci_tools=$(ci_host_tools_plan "$1" "$2") || exit 1
    _ci_tools_missing=0
    while IFS=$TAB read -r _ci_tool _ci_tool_gates _ci_tool_check _ci_tool_install; do
        [ -n "$_ci_tool" ] || continue
        if (eval "$_ci_tool_check") >/dev/null 2>&1; then
            continue
        fi
        if [ "$_ci_tools_missing" -eq 0 ]; then
            echo >&2
            ci_verify_error "this host lacks tools that selected gates run; install them rather than skipping those gates:"
        fi
        _ci_tools_missing=1
        echo "[ci-verify]   $_ci_tool, for $_ci_tool_gates" >&2
        echo "[ci-verify]     $_ci_tool_install" >&2
    done <<EOF
$_ci_tools
EOF
    if [ "$_ci_tools_missing" -ne 0 ]; then
        ci_verify_error "no gate started; CONTRIBUTING.md lists the host prerequisites"
        exit 1
    fi
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
    read -r CI_VERIFY_HANDOFF < "$2" || true
}

# Producer gates hand their artifacts to later gates through these path files,
# because gates may run in different pool workers.
CI_VERIFY_STAGE1_PATH_FILE="$ROOT/target/ci-verify-stage1.path"
CI_VERIFY_STAGE2_PATH_FILE="$ROOT/target/ci-verify-stage2.path"
CI_VERIFY_OPT2_REFERENCE_PATH_FILE="$ROOT/target/ci-verify-opt2-reference.path"
CI_VERIFY_PROFILE_PATH_FILE="$ROOT/target/ci-verify-compile-profile-cli.path"

# ci_verify_load_handoffs NEEDS
#   Set the produced compilers and artifact paths a gate may use. A gate
#   receives an artifact only from a producer among its needs, which passed in
#   this run before the gate started; every other one names a path that cannot
#   exist, so a gate that uses an artifact without needing its producer fails
#   whatever order the gates ran in.
ci_verify_load_handoffs() {
    STAGE1_BIN="$CI_VERIFY_UNPRODUCED/previous-stage-compiler"
    STAGE2_BIN="$CI_VERIFY_UNPRODUCED/converged-compiler"
    COMPILE_PROFILE_BIN="$CI_VERIFY_UNPRODUCED/compile-profile-compiler"
    OPT2_REFERENCE_ASM="$CI_VERIFY_UNPRODUCED/build-invariance-opt1-reference.s"
    case ",$1," in
        *,bootstrap-fixpoint,*)
            read_handoff "bootstrap previous-stage compiler capture" "$CI_VERIFY_STAGE1_PATH_FILE" || return 1
            STAGE1_BIN=$CI_VERIFY_HANDOFF
            ensure_executable "previous-stage" "$STAGE1_BIN"
            read_handoff "bootstrap fixpoint compiler capture" "$CI_VERIFY_STAGE2_PATH_FILE" || return 1
            STAGE2_BIN=$CI_VERIFY_HANDOFF
            ensure_executable "bootstrapped compiler" "$STAGE2_BIN"
            ;;
    esac
    case ",$1," in
        *,stage2-opt1-opt2-build-invariance,*)
            read_handoff "build-invariance opt1 reference handoff" "$CI_VERIFY_OPT2_REFERENCE_PATH_FILE" || return 1
            OPT2_REFERENCE_ASM=$CI_VERIFY_HANDOFF
            if [ ! -s "$OPT2_REFERENCE_ASM" ]; then
                ci_verify_error "build-invariance published a missing or empty assembly: $OPT2_REFERENCE_ASM"
                return 1
            fi
            ;;
    esac
    case ",$1," in
        *,stage2-compile-profile-verifier,*)
            read_handoff "compile-profile verifier" "$CI_VERIFY_PROFILE_PATH_FILE" || return 1
            COMPILE_PROFILE_BIN=$CI_VERIFY_HANDOFF
            ensure_executable "compile-profile" "$COMPILE_PROFILE_BIN"
            ;;
    esac
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
    TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$CI_VERIFY_STAGE1_PATH_FILE \
        TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE=$CI_VERIFY_STAGE2_PATH_FILE \
        scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN" || return $?
    # The cross-mode differential also runs the previous-stage compiler.
    ci_verify_load_handoffs bootstrap-fixpoint || return 1
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
    TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE=$CI_VERIFY_OPT2_REFERENCE_PATH_FILE \
        scripts/check-build-invariance.sh || return $?
    ci_verify_load_handoffs stage2-opt1-opt2-build-invariance
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
    TYPELISP_COMPILE_PROFILE_CLI_PATH_FILE=$CI_VERIFY_PROFILE_PATH_FILE \
        TYPELISP_COMPILE_PROFILE_EMBEDDED_TLCI_REUSE=1 \
        scripts/verify-compile-profile.sh || return $?
    ci_verify_load_handoffs stage2-compile-profile-verifier
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
# must not, so ci-host-tools.tsv makes valgrind a host tool of both
# instruction-count gates, required before any gate starts.
gate_instruction_counts() {
    TYPELISP_IR_CHECK_COMPILER=$STAGE2_BIN scripts/check-instruction-counts.sh
}

gate_heavy_instruction_counts() {
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
CI_VERIFY_JOBS=1
CI_VERIFY_MEMORY_MIB=
CI_VERIFY_CPU_SLOTS=
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
        ci_host_tools_plan "$2" > /dev/null
        printf 'id\thosts\tlabel\tneeds\tmemory\tcpu\tlocks\n'
        printf '%s\n' "$CI_VERIFY_PLAN" | cut -f 1-4,6-8
        exit 0
        ;;
esac
while [ "$#" -gt 0 ]; do
    case "$1" in
        --gates | --jobs | --memory-mib | --cpu-slots)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                usage
                exit 2
            fi
            case "$1" in
                --gates) CI_VERIFY_GATES=$2 ;;
                --jobs) CI_VERIFY_JOBS=$2 ;;
                --memory-mib) CI_VERIFY_MEMORY_MIB=$2 ;;
                --cpu-slots) CI_VERIFY_CPU_SLOTS=$2 ;;
            esac
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done
case "$CI_VERIFY_JOBS" in
    [1-9] | 1[0-6]) ;;
    *)
        echo "--jobs must be an integer from 1 to 16: $CI_VERIFY_JOBS" >&2
        exit 2
        ;;
esac
case "$CI_VERIFY_MEMORY_MIB" in
    "") ;;
    *[!0-9]* | 0*)
        echo "--memory-mib must be a positive MiB count: $CI_VERIFY_MEMORY_MIB" >&2
        exit 2
        ;;
esac
if [ -z "$CI_VERIFY_CPU_SLOTS" ]; then
    CI_VERIFY_CPU_SLOTS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null) ||
        CI_VERIFY_CPU_SLOTS=
    case "$CI_VERIFY_CPU_SLOTS" in
        "" | *[!0-9]* | 0*)
            echo "cannot count this host's online CPUs; pass --cpu-slots N" >&2
            exit 2
            ;;
    esac
    [ "$CI_VERIFY_CPU_SLOTS" -le 16384 ] || CI_VERIFY_CPU_SLOTS=16384
fi
if ! awk -v slots="$CI_VERIFY_CPU_SLOTS" 'BEGIN { exit !(slots ~ /^[1-9][0-9]*$/ && slots <= 16384) }'; then
    echo "--cpu-slots must be an integer from 1 to 16384: $CI_VERIFY_CPU_SLOTS" >&2
    exit 2
fi
if [ "$CI_VERIFY_JOBS" -gt 1 ] && [ -z "$CI_VERIFY_MEMORY_MIB" ]; then
    echo "--jobs $CI_VERIFY_JOBS needs --memory-mib: the memory the running gates may reserve at once" >&2
    exit 2
fi

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-benchmark.sh"
BOUNDED_POOL_LABEL=ci-verify
. "$ROOT/scripts/lib-bounded-pool.sh"

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
CI_VERIFY_PLAN_IDS=$(printf '%s\n' "$CI_VERIFY_PLAN" | cut -f 1 | tr '\n' ',')
ci_host_tools_require "$HOST_OS" "$CI_VERIFY_PLAN_IDS"

if [ "${TYPELISP_CI_TIMING:-0}" = 1 ]; then
    ci_timing_init "$ROOT/target/ci-timing/$HOST_OS.tsv" "$HOST_OS"
    ci_timing_set_now_ms
    CI_VERIFY_STARTED_MS=$CI_TIMING_NOW_MS
    trap 'ci_timing_summary "$TYPELISP_CI_TIMING_FILE" 10' EXIT
fi

# Only the bootstrap consumes the seed; a selection without it needs none.
SEED_TYPELISP_BIN=
case ",$CI_VERIFY_PLAN_IDS" in
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
# them. Until that gate passes they name a path that cannot exist, so a missing
# need fails its consumer instead of falling back to some other compiler. A gate
# whose compiler column is `-` sees such a path as TYPELISP_BIN, so a gate that
# uses a compiler without naming one fails instead of falling back to the seed.
CI_VERIFY_UNPRODUCED="$ROOT/target/ci-verify-unproduced"
rm -rf "$CI_VERIFY_UNPRODUCED"
CI_VERIFY_NO_COMPILER="$CI_VERIFY_UNPRODUCED/gate-names-no-compiler"
mkdir -p "$ROOT/target"
rm -f "$CI_VERIFY_STAGE1_PATH_FILE" "$CI_VERIFY_STAGE2_PATH_FILE" \
    "$CI_VERIFY_OPT2_REFERENCE_PATH_FILE" "$CI_VERIFY_PROFILE_PATH_FILE"

# run_gate LABEL NEEDS COMPILER COMMAND
#   Run one gate in a subshell, so nothing it sets or exits reaches the next
#   gate of its worker, and set GATE_STATUS and GATE_ELAPSED (seconds).
run_gate() {
    TYPELISP_CI_TIMING_GATE=$1
    export TYPELISP_CI_TIMING_GATE
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        start=$CI_TIMING_NOW_MS
    else
        start=$(date +%s)
    fi
    set +e
    (
        ci_verify_load_handoffs "$2" || exit 1
        case "$3" in
            stage2) gate_bin=$STAGE2_BIN ;;
            profile) gate_bin=$COMPILE_PROFILE_BIN ;;
            *) gate_bin=$CI_VERIFY_NO_COMPILER ;;
        esac
        if [ "$3" != - ] && [ ! -x "$gate_bin" ]; then
            ci_verify_error "$1 compiler was not produced by this run: $gate_bin"
            exit 126
        fi
        TYPELISP_BIN=$gate_bin
        export TYPELISP_BIN
        eval "$4"
    )
    GATE_STATUS=$?
    set -e
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        end=$CI_TIMING_NOW_MS
        elapsed_ms=$((end - start))
        GATE_ELAPSED=$((elapsed_ms / 1000))
        ci_timing_record_elapsed all gate "$elapsed_ms" "$GATE_STATUS"
    else
        end=$(date +%s)
        GATE_ELAPSED=$((end - start))
    fi
}

gate_verdict() {
    if [ "$2" -eq 0 ]; then
        echo "[ci-verify] PASS $1 (${3}s)"
    else
        echo "[ci-verify] FAIL $1 (${3}s, exit $2)"
    fi
}

echo "[ci-verify] host=$HOST_OS seed=${SEED_TYPELISP_BIN:-<unused by this selection>}"

# Gates are the jobs of one bounded pool (scripts/lib-bounded-pool.sh), queued
# in table order with their needs, their memory column as the reservation and
# their CPU slots and locks. The memory column is a gate's measured process-tree
# peak with headroom; the pool admits a gate while the reservations of the running gates,
# plus its own, fit --memory-mib, but it does not enforce them. Pools inside
# gates still run every chunk under its enforced cap. Gates that share a lock
# write or read the same checkout paths, so they never run at once. One job
# runs the table in order and streams each gate's output. With more, a gate
# writes its output and timing rows to its own files; this shell prints each
# gate's output whole when it finishes, and merges the timing rows in table
# order.
CI_VERIFY_PLAN_FILE="$ROOT/target/ci-verify-plan.tsv"
CI_VERIFY_POOL="$ROOT/target/ci-verify-pool"
printf '%s\n' "$CI_VERIFY_PLAN" > "$CI_VERIFY_PLAN_FILE"
CI_VERIFY_QUEUE="$ROOT/target/ci-verify-queue.txt"
CI_VERIFY_BUDGET_MIB=0
: > "$CI_VERIFY_QUEUE"
while IFS=$TAB read -r gate_id gate_hosts gate_label gate_needs gate_compiler_kind gate_memory gate_cpu gate_locks gate_command; do
    printf '%s|%s|%s|%s|%s\n' "$gate_id" "$gate_memory" "$gate_needs" "$gate_locks" "$gate_cpu" >> "$CI_VERIFY_QUEUE"
    [ "$gate_memory" -le "$CI_VERIFY_BUDGET_MIB" ] || CI_VERIFY_BUDGET_MIB=$gate_memory
done < "$CI_VERIFY_PLAN_FILE"
# One job needs no memory budget: each gate runs alone.
if [ "$CI_VERIFY_JOBS" -gt 1 ]; then
    CI_VERIFY_BUDGET_MIB=$CI_VERIFY_MEMORY_MIB
    echo "[ci-verify] $CI_VERIFY_SELECTED_COUNT gates, up to $CI_VERIFY_JOBS at once within $CI_VERIFY_BUDGET_MIB MiB of reservations"
fi
bounded_pool_init "$CI_VERIFY_POOL" "$CI_VERIFY_BUDGET_MIB" "$CI_VERIFY_QUEUE" "$CI_VERIFY_CPU_SLOTS" || exit 1
echo "[ci-verify] CPU reservation budget: $CI_VERIFY_CPU_SLOTS slots"
mkdir -p "$CI_VERIFY_POOL/logs" "$CI_VERIFY_POOL/timing" "$CI_VERIFY_POOL/elapsed"
CI_VERIFY_TIMING_FILE=${TYPELISP_CI_TIMING_FILE:-}

# The pool's job callback. Workers are background subshells, so gates read
# standard input from /dev/null.
bounded_pool_run_job() {
    while IFS=$TAB read -r job_id job_hosts job_label job_needs job_compiler_kind job_memory job_cpu job_locks job_command; do
        [ "$job_id" != "$1" ] || break
    done < "$CI_VERIFY_PLAN_FILE"
    if [ "$job_id" != "$1" ]; then
        ci_verify_error "pool job names no planned gate: $1"
        return 1
    fi
    if ci_timing_enabled; then
        TYPELISP_CI_TIMING_FILE="$CI_VERIFY_POOL/timing/$1.tsv"
        export TYPELISP_CI_TIMING_FILE
    fi
    if [ "$CI_VERIFY_JOBS" -eq 1 ]; then
        echo
        echo "[ci-verify] START $job_label"
        run_gate "$job_label" "$job_needs" "$job_compiler_kind" "$job_command"
        gate_verdict "$job_label" "$GATE_STATUS" "$GATE_ELAPSED"
    else
        run_gate "$job_label" "$job_needs" "$job_compiler_kind" "$job_command" \
            > "$CI_VERIFY_POOL/logs/$1.log" 2>&1
    fi
    printf '%s\n' "$GATE_ELAPSED" > "$CI_VERIFY_POOL/elapsed/$1"
    return "$GATE_STATUS"
}

# Print a START line for each newly claimed gate and the whole output of each
# newly finished one, in table order.
CI_VERIFY_STARTED=,
CI_VERIFY_REPORTED=,
ci_verify_report() {
    while IFS=$TAB read -r report_id report_hosts report_label report_rest; do
        case "$CI_VERIFY_STARTED" in *",$report_id,"*) ;; *)
            [ -d "$CI_VERIFY_POOL/claims/$report_id" ] || continue
            CI_VERIFY_STARTED="$CI_VERIFY_STARTED$report_id,"
            echo "[ci-verify] START $report_label"
            ;;
        esac
        case "$CI_VERIFY_REPORTED" in *",$report_id,"*) continue ;; esac
        [ -f "$CI_VERIFY_POOL/results/$report_id" ] || continue
        CI_VERIFY_REPORTED="$CI_VERIFY_REPORTED$report_id,"
        read -r report_status < "$CI_VERIFY_POOL/results/$report_id"
        report_elapsed=?
        [ ! -f "$CI_VERIFY_POOL/elapsed/$report_id" ] ||
            read -r report_elapsed < "$CI_VERIFY_POOL/elapsed/$report_id"
        echo
        echo "[ci-verify] OUTPUT $report_label"
        cat "$CI_VERIFY_POOL/logs/$report_id.log" 2>/dev/null || true
        gate_verdict "$report_label" "$report_status" "$report_elapsed"
    done < "$CI_VERIFY_PLAN_FILE"
}

bounded_pool_start "$CI_VERIFY_POOL" "$CI_VERIFY_JOBS"
if [ "$CI_VERIFY_JOBS" -gt 1 ]; then
    while :; do
        ci_verify_report
        ci_verify_alive=0
        for ci_verify_pid in $BOUNDED_POOL_PIDS; do
            if kill -0 "$ci_verify_pid" 2>/dev/null; then
                ci_verify_alive=1
            fi
        done
        [ "$ci_verify_alive" -eq 1 ] || break
        sleep 2
    done
    ci_verify_report
fi
ci_verify_status=0
bounded_pool_join "$CI_VERIFY_POOL" || ci_verify_status=1

# Timing rows follow the table order whatever order the gates finished in.
if ci_timing_enabled; then
    TYPELISP_CI_TIMING_FILE=$CI_VERIFY_TIMING_FILE
    export TYPELISP_CI_TIMING_FILE
    while IFS=$TAB read -r merge_id merge_rest; do
        [ ! -s "$CI_VERIFY_POOL/timing/$merge_id.tsv" ] ||
            cat "$CI_VERIFY_POOL/timing/$merge_id.tsv" >> "$TYPELISP_CI_TIMING_FILE"
    done < "$CI_VERIFY_PLAN_FILE"
fi

if [ "$ci_verify_status" -ne 0 ]; then
    echo >&2
    ci_verify_error "CI verification failed; no further gate started after the first failure:"
    ci_verify_first_failure=
    while IFS=$TAB read -r failed_id failed_hosts failed_label failed_rest; do
        if [ -f "$CI_VERIFY_POOL/results/$failed_id" ]; then
            read -r failed_status < "$CI_VERIFY_POOL/results/$failed_id"
            [ "$failed_status" != 0 ] || continue
            echo "[ci-verify]   FAIL $failed_label (exit $failed_status)" >&2
            [ -n "$ci_verify_first_failure" ] || ci_verify_first_failure=$failed_status
        elif [ -d "$CI_VERIFY_POOL/claims/$failed_id" ]; then
            echo "[ci-verify]   UNFINISHED $failed_label" >&2
        else
            echo "[ci-verify]   NOT STARTED $failed_label" >&2
        fi
    done < "$CI_VERIFY_PLAN_FILE"
    exit "${ci_verify_first_failure:-1}"
fi

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
