#!/usr/bin/env sh
set -eu

# verify-compile-profile.sh - smoke compile-profile detail output.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler

WORKDIR="$ROOT/target/compile-profile-verify/$NL_HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

PROFILE_ASM="$WORKDIR/typelisp-profile.s"
PROFILE_OBJ="$WORKDIR/typelisp-profile.$NL_OBJ_EXT"
PROFILE_BIN="$WORKDIR/typelisp-profile$NL_BIN_EXT"
SURFACE_HYDRATED_ASM="$WORKDIR/surface-hydrated.s"
SURFACE_HYDRATED_STDOUT="$WORKDIR/surface-hydrated.stdout"
SURFACE_HYDRATED_STDERR="$WORKDIR/surface-hydrated.stderr"
SURFACE_SOURCE_ASM="$WORKDIR/surface-source.s"
SURFACE_SOURCE_STDOUT="$WORKDIR/surface-source.stdout"
SURFACE_SOURCE_STDERR="$WORKDIR/surface-source.stderr"
SUMMARY_ASM="$WORKDIR/typelisp-summary.s"
SUMMARY_OBJ="$WORKDIR/typelisp-summary.$NL_OBJ_EXT"
SUMMARY_BIN="$WORKDIR/typelisp-summary$NL_BIN_EXT"
SUMMARY_BUILD_STDOUT="$WORKDIR/summary-build.stdout"
SUMMARY_BUILD_STDERR="$WORKDIR/summary-build.stderr"
SUMMARY_CHECK_STDOUT="$WORKDIR/summary-check.stdout"
SUMMARY_CHECK_STDERR="$WORKDIR/summary-check.stderr"
SUMMARY_OUTPUT_ASM="$WORKDIR/summary-output.s"
NORMAL_CHECK_STDOUT="$WORKDIR/normal-check.stdout"
NORMAL_CHECK_STDERR="$WORKDIR/normal-check.stderr"
NORMAL_OUTPUT_ASM="$WORKDIR/normal-output.s"
DETACH_NOCHANGE_ASM="$WORKDIR/macro-detach-nochange.s"
DETACH_NOCHANGE_STDOUT="$WORKDIR/macro-detach-nochange.stdout"
DETACH_NOCHANGE_STDERR="$WORKDIR/macro-detach-nochange.stderr"
DETACH_CHANGED_ASM="$WORKDIR/macro-detach-changed.s"
DETACH_CHANGED_STDOUT="$WORKDIR/macro-detach-changed.stdout"
DETACH_CHANGED_STDERR="$WORKDIR/macro-detach-changed.stderr"
PEAK_RESET_STDOUT="$WORKDIR/profile-peak-reset.stdout"
PEAK_RESET_STDERR="$WORKDIR/profile-peak-reset.stderr"
BUILD_STDOUT="$WORKDIR/profile-build.stdout"
BUILD_STDERR="$WORKDIR/profile-build.stderr"
CHECK_STDOUT="$WORKDIR/profile-check.stdout"
CHECK_STDERR="$WORKDIR/profile-check.stderr"
COMPTIME_HOST_SMOKE_STDOUT="$WORKDIR/comptime-host-smoke.stdout"
COMPTIME_HOST_SMOKE_STDERR="$WORKDIR/comptime-host-smoke.stderr"
COMPTIME_HOST_SMOKE_ASM="$WORKDIR/comptime-host-smoke.s"
COMPTIME_HOST_SMOKE_OBJ="$WORKDIR/comptime-host-smoke.$NL_OBJ_EXT"
COMPTIME_HOST_SMOKE_BIN="$WORKDIR/comptime-host-smoke$NL_BIN_EXT"
BUILD_CLI_TEST_STDOUT="$WORKDIR/profile-build-cli-test.stdout"
BUILD_CLI_TEST_STDERR="$WORKDIR/profile-build-cli-test.stderr"
STDLIB_TLCI_DIR="$WORKDIR/stdlib-tlci-dispatch"
STDLIB_TLCI_EMBEDDED_ASM="$STDLIB_TLCI_DIR/embedded.s"
STDLIB_TLCI_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/embedded.stdout"
STDLIB_TLCI_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/embedded.stderr"
STDLIB_TLCI_SOURCE_ASM="$STDLIB_TLCI_DIR/source.s"
STDLIB_TLCI_SOURCE_STDOUT="$STDLIB_TLCI_DIR/source.stdout"
STDLIB_TLCI_SOURCE_STDERR="$STDLIB_TLCI_DIR/source.stderr"
VECTOR_CORE_STDOUT="$WORKDIR/profile-vector-core.stdout"
VECTOR_CORE_STDERR="$WORKDIR/profile-vector-core.stderr"
VECTOR_FULL_STDOUT="$WORKDIR/profile-vector-full.stdout"
VECTOR_FULL_STDERR="$WORKDIR/profile-vector-full.stderr"
VECTOR_ONE_ASM="$WORKDIR/profile-vector-one.s"
VECTOR_ONE_STDOUT="$WORKDIR/profile-vector-one.stdout"
VECTOR_ONE_STDERR="$WORKDIR/profile-vector-one.stderr"
VECTOR_FIVE_ASM="$WORKDIR/profile-vector-five.s"
VECTOR_FIVE_STDOUT="$WORKDIR/profile-vector-five.stdout"
VECTOR_FIVE_STDERR="$WORKDIR/profile-vector-five.stderr"
GEN_IMPORT_STDOUT="$WORKDIR/profile-generated-import.stdout"
GEN_IMPORT_STDERR="$WORKDIR/profile-generated-import.stderr"
CTFE_SPLICE_STDOUT="$WORKDIR/profile-ctfe-splice.stdout"
CTFE_SPLICE_STDERR="$WORKDIR/profile-ctfe-splice.stderr"
RESULT_IMPORT_STDOUT="$WORKDIR/profile-result-import.stdout"
RESULT_IMPORT_STDERR="$WORKDIR/profile-result-import.stderr"
CROSS_SINGLE_STDOUT="$WORKDIR/profile-cross-single.stdout"
CROSS_SINGLE_STDERR="$WORKDIR/profile-cross-single.stderr"
GEN_IMPORT_INERT_STDOUT="$WORKDIR/profile-generated-import-inert.stdout"
GEN_IMPORT_INERT_STDERR="$WORKDIR/profile-generated-import-inert.stderr"
REPLAY_STDOUT="$WORKDIR/profile-generated-replay.stdout"
REPLAY_STDERR="$WORKDIR/profile-generated-replay.stderr"
LAYOUT_STDOUT="$WORKDIR/profile-layout.stdout"
LAYOUT_STDERR="$WORKDIR/profile-layout.stderr"
CONCAT_ASM="$WORKDIR/profile-string-concat.s"
CONCAT_STDOUT="$WORKDIR/profile-string-concat.stdout"
CONCAT_STDERR="$WORKDIR/profile-string-concat.stderr"
SPECIALIZATION_ASM="$WORKDIR/profile-specialization.s"
SPECIALIZATION_STDOUT="$WORKDIR/profile-specialization.stdout"
SPECIALIZATION_STDERR="$WORKDIR/profile-specialization.stderr"
OPT_ASM="$WORKDIR/profile-opt.s"
OPT_STDOUT="$WORKDIR/profile-opt.stdout"
OPT_STDERR="$WORKDIR/profile-opt.stderr"
SELFHOST_ASM="$WORKDIR/profile-selfhost.s"
SELFHOST_STDOUT="$WORKDIR/profile-selfhost.stdout"
SELFHOST_STDERR="$WORKDIR/profile-selfhost.stderr"
BATCH_LIST="$WORKDIR/profile-batch.txt"
BATCH_STDOUT="$WORKDIR/profile-batch.stdout"
BATCH_STDERR="$WORKDIR/profile-batch.stderr"
BATCH_ARITH="$WORKDIR/profile-batch-arithmetic.s"
BATCH_FUNCTIONS="$WORKDIR/profile-batch-functions.s"
BATCH_SINGLE_ARITH="$WORKDIR/profile-single-arithmetic.s"
BATCH_SINGLE_FUNCTIONS="$WORKDIR/profile-single-functions.s"
BATCH_SINGLE_STDOUT="$WORKDIR/profile-single.stdout"
BATCH_SINGLE_STDERR="$WORKDIR/profile-single.stderr"
NORMAL_BATCH_LIST="$WORKDIR/normal-batch.txt"
NORMAL_BATCH_STDOUT="$WORKDIR/normal-batch.stdout"
NORMAL_BATCH_STDERR="$WORKDIR/normal-batch.stderr"
NORMAL_BATCH_ARITH="$WORKDIR/normal-batch-arithmetic.s"
NORMAL_BATCH_FUNCTIONS="$WORKDIR/normal-batch-functions.s"
WINDOWS_MEMORY_DIR="$WORKDIR/windows-memory"
FAILED_BATCH_LIST="$WORKDIR/failed-batch.txt"
FAILED_BATCH_STDOUT="$WORKDIR/failed-batch.stdout"
FAILED_BATCH_STDERR="$WORKDIR/failed-batch.stderr"
FAILED_BATCH_FIRST="$WORKDIR/failed-batch-first.s"
FAILED_BATCH_SECOND="$WORKDIR/missing/failed-batch-second.s"

batch_path() {
    if [ "$NL_HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

show_failure_logs() {
    _stdout=$1
    _stderr=$2
    echo "stdout:" >&2
    sed 's/^/  /' "$_stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$_stderr" >&2 || true
}

# run_logged STDOUT STDERR MESSAGE COMMAND...: run COMMAND with its streams in
# STDOUT and STDERR; a failure shows both and fails with MESSAGE.
run_logged() {
    _rl_out=$1
    _rl_err=$2
    _rl_msg=$3
    shift 3
    if ! "$@" > "$_rl_out" 2> "$_rl_err"; then
        show_failure_logs "$_rl_out" "$_rl_err"
        fail "$_rl_msg"
    fi
}

# profile_rows STDOUT STDERR [FILE] < ROWS: check FILE (default STDERR), a
# profile-enabled compiler's stderr, against one expectation per row; rows
# starting with `#` are comments. On failure show STDOUT and STDERR.
#   has TEXT | lacks TEXT          some line contains TEXT | no line does
#   lines N TEXT | lines<= N TEXT  exactly | at most N lines contain TEXT
#   c NAME OP N | l NAME OP N      the value (c) or live-delta (l) field of the
#                                  `compile-profile|NAME|...` rows: `=` and
#                                  `>=` hold for some row, `<=` for the first
#                                  row, `all=` for every row (at least one)
#   sum NAME = TERM + TERM...      the first NAME row's value equals the sum
#                                  of TERMs: counter names (their first row's
#                                  value) or integers; a missing counter fails
profile_rows() {
    cat > "$WORKDIR/profile-rows.txt"
    if ! awk -F'|' -v rows="$WORKDIR/profile-rows.txt" '
        BEGIN {
            while ((getline line < rows) > 0) {
                if (line ~ /^[[:space:]]*(#|$)/) continue
                nw = split(line, w, " ")
                spec[++n] = line
                kind[n] = w[1]
                if (w[1] == "has" || w[1] == "lacks") {
                    text[n] = substr(line, length(w[1]) + 2)
                } else if (w[1] == "lines" || w[1] == "lines<=") {
                    want[n] = w[2] + 0
                    text[n] = substr(line, length(w[1]) + length(w[2]) + 3)
                } else if (w[1] == "c" || w[1] == "l") {
                    name[n] = w[2]
                    op[n] = w[3]
                    want[n] = w[4] + 0
                } else if (w[1] == "sum" && w[3] == "=") {
                    terms[n] = w[2]
                    for (j = 4; j <= nw; j += 2) terms[n] = terms[n] " " w[j]
                    for (j = 2; j <= nw; j += 2) if (w[j] !~ /^-?[0-9]+$/) named[w[j]] = 1
                } else {
                    print "malformed profile row: " line > "/dev/stderr"
                    failed = 1
                }
            }
        }
        $1 == "compile-profile" && ($2 in named) && !($2 in value) { value[$2] = $3 + 0 }
        {
            for (i = 1; i <= n; i++) {
                if (kind[i] == "sum") continue
                if (kind[i] == "c" || kind[i] == "l") {
                    if ($1 != "compile-profile" || $2 != name[i]) continue
                    v = (kind[i] == "c" ? $3 : $5) + 0
                    if (!seen[i]++) first[i] = v
                    if (v == want[i]) eq[i] = 1
                    if (v >= want[i]) ge[i] = 1
                    if (v != want[i]) ne[i] = 1
                } else if (index($0, text[i])) {
                    hits[i]++
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                if (kind[i] == "has") ok = hits[i] > 0
                else if (kind[i] == "lacks") ok = hits[i] == 0
                else if (kind[i] == "lines") ok = hits[i] + 0 == want[i]
                else if (kind[i] == "lines<=") ok = hits[i] + 0 <= want[i]
                else if (kind[i] == "sum") {
                    nt = split(terms[i], t, " ")
                    ok = 1
                    total = 0
                    for (j = 1; j <= nt; j++) {
                        if (t[j] ~ /^-?[0-9]+$/) v = t[j] + 0
                        else if (t[j] in value) v = value[t[j]]
                        else { ok = 0; v = 0 }
                        if (j == 1) lhs = v; else total += v
                    }
                    ok = ok && lhs == total
                } else if (op[i] == "=") ok = eq[i]
                else if (op[i] == ">=") ok = ge[i]
                else if (op[i] == "<=") ok = seen[i] && first[i] <= want[i]
                else if (op[i] == "all=") ok = seen[i] && !ne[i]
                else ok = 0
                if (!ok) {
                    print "profile row failed: " spec[i] > "/dev/stderr"
                    failed = 1
                }
            }
            exit failed ? 1 : 0
        }
    ' "${3:-$2}"; then
        show_failure_logs "$1" "$2"
        fail "compile-profile expectations failed for ${3:-$2}"
    fi
}

profile_counter_value_in() {
    _file=$1
    _phase=$2
    awk -F'|' -v phase="$_phase" '
        $1 == "compile-profile" && $2 == phase {
            print $3 + 0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$_file"
}

profile_live_counter_value_in() {
    _file=$1
    _phase=$2
    awk -F'|' -v phase="$_phase" '
        $1 == "compile-profile" && $2 == phase {
            print $5 + 0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$_file"
}

assert_intern_storage_schema_in() {
    _iss_file=$1
    _iss_stdout=$2
    _iss_stderr=$3
    if ! awk -F'|' '
        BEGIN {
            count = split("intern.records.source_live intern.records.source_capacity intern.records.generated_live intern.records.generated_capacity intern.records.source_resizes intern.records.generated_resizes intern.records.reserved_bytes intern.source_map.live intern.source_map.capacity intern.source_map.probes_total intern.source_map.probe_max intern.source_map.resizes intern.source_map.reserved_bytes intern.canonical_map.live intern.canonical_map.capacity intern.canonical_map.probes_total intern.canonical_map.probe_max intern.canonical_map.resizes intern.canonical_map.reserved_bytes", expected, " ")
        }
        $1 == "compile-profile" &&
            ($2 ~ /^intern\.records\./ ||
             $2 ~ /^intern\.source_map\./ ||
             $2 ~ /^intern\.canonical_map\./) {
            seen++
            if (seen > count || $2 != expected[seen] || NF != 6 ||
                $3 !~ /^[0-9]+$/ || $4 != 0 || $5 != 0 || $6 != 0) {
                bad = 1
            }
            value[$2] = $3 + 0
        }
        END {
            if (seen != count || bad) exit 1
            source_live = value["intern.records.source_live"]
            generated_live = value["intern.records.generated_live"]
            source_map_live = value["intern.source_map.live"]
            canonical_map_live = value["intern.canonical_map.live"]
            if (source_live <= 0 || generated_live < canonical_map_live || source_live != source_map_live) exit 1
            if (value["intern.records.source_capacity"] != 262144 || value["intern.records.generated_capacity"] != 262144 || value["intern.source_map.capacity"] != 262144 || value["intern.canonical_map.capacity"] != 262144) exit 1
            if (value["intern.records.source_resizes"] != 0 || value["intern.records.generated_resizes"] != 0 || value["intern.source_map.resizes"] != 0 || value["intern.canonical_map.resizes"] != 0) exit 1
            if (value["intern.records.reserved_bytes"] <= 0 || value["intern.source_map.reserved_bytes"] <= 0 || value["intern.canonical_map.reserved_bytes"] <= 0) exit 1
            if (value["intern.source_map.probes_total"] < value["intern.source_map.probe_max"] || value["intern.canonical_map.probes_total"] < value["intern.canonical_map.probe_max"]) exit 1
        }
    ' "$_iss_file"; then
        show_failure_logs "$_iss_stdout" "$_iss_stderr"
        fail "intern storage profile schema/order/accounting mismatch"
    fi
}

# The lifetime ledger is deliberately machine-readable and deterministic: one
# schema row, a fixed owner order at each boundary, and exact reconciliation of
# exclusive owners plus the explicit remainder. Input bytes are payload detail
# inside frontend-read-parse, so they never participate in the exclusive sum.
assert_lifetime_ledger_in() {
    _lll_file=$1
    _lll_stdout=$2
    _lll_stderr=$3
    if ! awk -F'|' '
        BEGIN {
            expected_text = "load.complete|total|boundary-total load.complete|input-bytes|payload-detail load.complete|frontend-read-parse|transfer load.complete|token-storage|scan-scratch load.complete|reader-sexpr-storage|scan-scratch load.complete|reader-origin-storage|transfer load.complete|parsed-source-base|transfer load.complete|parsed-expr-pool|transfer load.complete|parsed-type-pool|transfer load.complete|loader-session-surface|session load.complete|intern-storage|session load.complete|remainder|unattributed load.handoff|total|boundary-total load.handoff|input-bytes|payload-detail load.handoff|frontend-read-parse|transfer load.handoff|token-storage|scan-scratch load.handoff|reader-sexpr-storage|scan-scratch load.handoff|reader-origin-storage|transfer load.handoff|parsed-source-base|transfer load.handoff|parsed-expr-pool|transfer load.handoff|parsed-type-pool|transfer load.handoff|loader-session-surface|session load.handoff|intern-storage|session load.handoff|remainder|unattributed macro.pre-detach|total|boundary-total macro.pre-detach|macro-enclosing|session macro.pre-detach|macro-job-registry-cache|session macro.pre-detach|scoped-env-index|cache macro.pre-detach|output-pool-base|lower-handoff macro.pre-detach|output-expr-pool|lower-handoff macro.pre-detach|output-type-pool|lower-handoff macro.pre-detach|live-symbols-registry|macro-live macro.pre-detach|retired-symbols-registry|retired macro.pre-detach|expansion-pool|scratch macro.pre-detach|active-generation-pools|scratch macro.pre-detach|retired-generation-pools|retired macro.pre-detach|remainder|unattributed macro.lower-handoff|total|boundary-total macro.lower-handoff|macro-enclosing|session macro.lower-handoff|macro-job-registry-cache|session macro.lower-handoff|scoped-env-index|cache macro.lower-handoff|output-pool-base|lower-handoff macro.lower-handoff|output-expr-pool|lower-handoff macro.lower-handoff|output-type-pool|lower-handoff macro.lower-handoff|live-symbols-registry|macro-live macro.lower-handoff|retired-symbols-registry|retired macro.lower-handoff|expansion-pool|scratch macro.lower-handoff|active-generation-pools|scratch macro.lower-handoff|retired-generation-pools|retired macro.lower-handoff|remainder|unattributed"
            expected_count = split(expected_text, expected, " ")
        }
        $1 == "compile-profile-lifetime" && $2 == "boundary" {
            header++
            if ($0 != "compile-profile-lifetime|boundary|owner|lifetime|cumulative_alloc_bytes|retained_live_bytes|peak_delta_bytes") bad = 1
            next
        }
        $1 == "compile-profile-lifetime" {
            row++
            key = $2 "|" $3 "|" $4
            if (row > expected_count || key != expected[row] || NF != 7) bad = 1
            if ($5 !~ /^[0-9]+$/ || $6 !~ /^-?[0-9]+$/ || $7 !~ /^[0-9]+$/) bad = 1
            boundary = $2
            if (!(boundary in cumulative)) {
                cumulative[boundary] = $5
                peak[boundary] = $7
            } else if ($5 != cumulative[boundary] || $7 != peak[boundary]) {
                bad = 1
            }
            if ($3 == "total") total[boundary] = $6 + 0
            else if ($3 == "remainder") remainder[boundary] = $6 + 0
            else if ($4 != "payload-detail") owners[boundary] += $6
            value[boundary "|" $3] = $6 + 0
        }
        END {
            if (header != 1 || row != expected_count || bad) exit 1
            count = split("load.complete load.handoff macro.pre-detach macro.lower-handoff", boundaries, " ")
            for (i = 1; i <= count; i++) {
                boundary = boundaries[i]
                if (total[boundary] <= 0 || owners[boundary] + remainder[boundary] != total[boundary]) exit 1
                if (owners[boundary] * 100 < total[boundary] * 90) exit 1
            }
            if (value["load.handoff|token-storage"] != 0 || value["load.handoff|reader-sexpr-storage"] != 0) exit 1
            if (value["macro.pre-detach|retired-symbols-registry"] != 0) exit 1
            if (value["macro.lower-handoff|live-symbols-registry"] != 0 || value["macro.lower-handoff|retired-symbols-registry"] != 0 || value["macro.lower-handoff|expansion-pool"] != 0 || value["macro.lower-handoff|active-generation-pools"] != 0 || value["macro.lower-handoff|retired-generation-pools"] != 0) exit 1
        }
    ' "$_lll_file"; then
        show_failure_logs "$_lll_stdout" "$_lll_stderr"
        fail "compile lifetime ledger schema/order/accounting mismatch"
    fi
}

# Every intermediate segmented-program flatten must name one of the two
# documented conservative reasons. Successful expansion then publishes the
# ordinary flat program exactly once at the walk boundary.
assert_segmented_program_view_in() {
    profile_rows "$2" "$3" "$1" <<'ROWS'
sum typecheck.macro.walk_segment_fallback_flattens = typecheck.macro.walk_segment_fallback_alias_flattens + typecheck.macro.walk_segment_fallback_file_flattens
sum typecheck.macro.walk_segment_final_flattens = 1
ROWS
}

# Fired self time excludes the union of nested hygiene and produced-node rewalk
# intervals. Exercise that arithmetic on the small cross-platform fixture as
# well as the Windows-only allocation census below. Windows intentionally has
# no fine-grained elapsed clock, so all three timer rows remain zero there.
assert_fired_decl_timing_in() {
    _fdt_file=$1
    _fdt_stdout=$2
    _fdt_stderr=$3

    _fdt_fire_us=$(profile_counter_value_in "$_fdt_file" "typecheck.macro.walk_decl_fire_us") &&
        _fdt_fire_count=$(profile_counter_value_in "$_fdt_file" "typecheck.macro.walk_decl_fire_count") &&
        _fdt_self_us=$(profile_counter_value_in "$_fdt_file" "typecheck.macro.walk_decl_fire_self_us") &&
        _fdt_nested_us=$(profile_counter_value_in "$_fdt_file" "typecheck.macro.walk_decl_fire_nested_us") &&
        _fdt_attributed_calls=$(profile_counter_value_in "$_fdt_file" "typecheck.macro.walk_decl_fire_attributed_calls") || {
        show_failure_logs "$_fdt_stdout" "$_fdt_stderr"
        fail "missing fired-declaration timing counter"
    }

    [ "$_fdt_attributed_calls" -eq "$_fdt_fire_count" ] || {
        show_failure_logs "$_fdt_stdout" "$_fdt_stderr"
        fail "fired-declaration attribution lost calls: fire=$_fdt_fire_count attributed=$_fdt_attributed_calls"
    }
    _fdt_timed=$((_fdt_self_us + _fdt_nested_us))
    _fdt_delta=$((_fdt_fire_us - _fdt_timed))
    if [ "$_fdt_delta" -lt 0 ]; then
        _fdt_delta=$((-_fdt_delta))
    fi
    [ "$_fdt_delta" -le 2 ] || {
        show_failure_logs "$_fdt_stdout" "$_fdt_stderr"
        fail "fired-declaration exclusive time double-counted nested lanes: total=$_fdt_fire_us self=$_fdt_self_us nested=$_fdt_nested_us"
    }
    if [ "$NL_HOST_OS" = windows ]; then
        [ "$_fdt_fire_us" -eq 0 ] &&
            [ "$_fdt_self_us" -eq 0 ] &&
            [ "$_fdt_nested_us" -eq 0 ] || {
            show_failure_logs "$_fdt_stdout" "$_fdt_stderr"
            fail "Windows fired-declaration timers must remain intentionally zero"
        }
    fi
}

# Fired-declaration ownership is measured at three independent boundaries: the
# exhaustive returned-graph copy, the reclaimable declaration generation, and
# the remainder committed during expansion / after copy-out. Keep the arithmetic
# exact while bounding the final allocator-granularity remainder.
assert_fired_decl_attribution_in() {
    _fda_file=$1
    _fda_stdout=$2
    _fda_stderr=$3

    assert_fired_decl_timing_in "$_fda_file" "$_fda_stdout" "$_fda_stderr"
    _fda_walk_decl_fire_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_live_bytes") &&
        _fda_walk_decl_fire_survivor_alloc_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_survivor_alloc_bytes") &&
        _fda_walk_decl_fire_survivor_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_survivor_live_bytes") &&
        _fda_walk_decl_fire_survivor_pool_node_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_survivor_pool_node_bytes") &&
        _fda_walk_decl_fire_survivor_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_survivor_bytes") &&
        _fda_walk_decl_fire_superseded_alloc_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_superseded_alloc_bytes") &&
        _fda_walk_decl_fire_superseded_released_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_superseded_released_bytes") &&
        _fda_walk_decl_fire_nonoutput_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_nonoutput_live_bytes") &&
        _fda_walk_decl_fire_residual_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_residual_live_bytes") &&
        _fda_walk_decl_fire_residual_committed_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_residual_committed_live_bytes") &&
        _fda_walk_decl_fire_residual_post_boundary_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_residual_post_boundary_live_bytes") &&
        _fda_walk_decl_fire_residual_unattributed_live_bytes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_residual_unattributed_live_bytes") &&
        _fda_walk_decl_fire_source_shared_expr_refs=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_source_shared_expr_refs") &&
        _fda_walk_decl_fire_source_shared_type_refs=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_source_shared_type_refs") &&
        _fda_walk_decl_fire_survivor_expr_nodes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_survivor_expr_nodes") &&
        _fda_walk_decl_fire_survivor_type_nodes=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_fire_survivor_type_nodes") &&
        _fda_walk_decl_generation_rotations=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_generation_rotations") || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "missing fired-declaration attribution counter"
    }

    [ "$_fda_walk_decl_fire_survivor_alloc_bytes" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_survivor_live_bytes" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_survivor_pool_node_bytes" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_survivor_bytes" -gt "$_fda_walk_decl_fire_survivor_alloc_bytes" ] &&
        [ "$_fda_walk_decl_fire_superseded_alloc_bytes" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_superseded_released_bytes" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_source_shared_expr_refs" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_source_shared_type_refs" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_survivor_expr_nodes" -gt 0 ] &&
        [ "$_fda_walk_decl_fire_survivor_type_nodes" -gt 0 ] &&
        [ "$_fda_walk_decl_generation_rotations" -gt 0 ] || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "fired-declaration survivor/non-output counters did not exercise the selfhost graph"
    }

    _fda_reconciled=$((
        _fda_walk_decl_fire_survivor_live_bytes +
        _fda_walk_decl_fire_nonoutput_live_bytes +
        _fda_walk_decl_fire_residual_live_bytes
    ))
    [ "$_fda_reconciled" -eq "$_fda_walk_decl_fire_live_bytes" ] || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "fired-declaration live attribution does not reconcile: live=$_fda_walk_decl_fire_live_bytes attributed=$_fda_reconciled"
    }
    _fda_residual_parts=$((
        _fda_walk_decl_fire_residual_committed_live_bytes +
        _fda_walk_decl_fire_residual_post_boundary_live_bytes +
        _fda_walk_decl_fire_residual_unattributed_live_bytes
    ))
    [ "$_fda_residual_parts" -eq "$_fda_walk_decl_fire_residual_live_bytes" ] || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "fired-declaration residual attribution does not reconcile: residual=$_fda_walk_decl_fire_residual_live_bytes parts=$_fda_residual_parts"
    }
    _fda_unattributed=$_fda_walk_decl_fire_residual_unattributed_live_bytes
    if [ "$_fda_unattributed" -lt 0 ]; then
        _fda_unattributed=$((-_fda_unattributed))
    fi
    # The unattributed remainder tracks the size of the compiler's own source
    # (the selfhost compile is the probe).
    [ "$_fda_unattributed" -le 12582912 ] || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "fired-declaration unattributed residual exceeds 12 MiB: $_fda_unattributed"
    }

    # A proportional ceiling on non-output retention. The generation counter
    # includes copy-out boundaries outside the declaration arena, hence a 2..3
    # cadence band instead of an equality against two.
    _fda_nonoutput_limit=$((_fda_walk_decl_fire_superseded_alloc_bytes / 4))
    [ "$_fda_walk_decl_fire_nonoutput_live_bytes" -le "$_fda_nonoutput_limit" ] || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "fired-declaration non-output retention exceeds 25% of superseded allocation: live=$_fda_walk_decl_fire_nonoutput_live_bytes allocated=$_fda_walk_decl_fire_superseded_alloc_bytes"
    }
    _fda_walk_decl_generations=$(profile_counter_value_in "$1" "typecheck.macro.walk_decl_generations") || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "missing fired-declaration generation count"
    }
    _fda_rotation_lower=$((_fda_walk_decl_generation_rotations * 2))
    _fda_rotation_upper=$((_fda_walk_decl_generation_rotations * 3))
    [ "$_fda_rotation_lower" -le "$_fda_walk_decl_generations" ] &&
        [ "$_fda_rotation_upper" -ge "$_fda_walk_decl_generations" ] || {
        show_failure_logs "$_fda_stdout" "$_fda_stderr"
        fail "declaration-generation rotation cadence left the batch-2 band: generations=$_fda_walk_decl_generations rotations=$_fda_walk_decl_generation_rotations"
    }

}

assert_lower_name_cache_storage_in() {
    _storage_file=$1
    _storage_stdout=$2
    _storage_stderr=$3
    profile_rows "$_storage_stdout" "$_storage_stderr" "$_storage_file" <<'ROWS'
l lower.name_cache.id_growth_views = 0
l lower.name_cache.logical_growth_views = 0
ROWS
    _storage_builds=$(profile_live_counter_value_in \
        "$_storage_file" lower.name_cache.builds) ||
        fail "missing name-cache build count"
    _storage_resets=$(profile_live_counter_value_in \
        "$_storage_file" lower.alias_overlay.resets) ||
        fail "missing alias-overlay reset count"
    _storage_capacity=$(profile_live_counter_value_in \
        "$_storage_file" lower.alias_overlay.capacity_slots) ||
        fail "missing alias-overlay capacity"
    _storage_growth=$(profile_live_counter_value_in \
        "$_storage_file" lower.alias_overlay.growth_slots) ||
        fail "missing alias-overlay allocation count"
    [ "$_storage_builds" -ge 2 ] && [ "$_storage_resets" -ge 2 ] &&
        [ "$_storage_capacity" -ge 16 ] &&
        [ "$_storage_growth" -le "$((2 * _storage_capacity))" ] || {
        show_failure_logs "$_storage_stdout" "$_storage_stderr"
        fail "name-cache tables grew or alias-overlay allocations scaled with views: builds=$_storage_builds resets=$_storage_resets capacity=$_storage_capacity growth_slots=$_storage_growth"
    }
}

assert_profile_total_peak_covers_live_in() {
    _file=$1
    _stdout=$2
    _stderr=$3
    if ! awk -F'|' '
        $1 == "compile-profile" && $2 == "total" {
            found = 1
            if (($6 + 0) < ($5 + 0)) bad = 1
        }
        END { exit found && !bad ? 0 : 1 }
    ' "$_file"; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "compile-wide peak must cover the final live allocation delta"
    fi
}


case "${TYPELISP_COMPILE_PROFILE_EMBEDDED_TLCI_REUSE:-0}" in
    0)
        echo "[compile-profile] build embedded stdlib tlci input"
        scripts/build-embedded-stdlib-tlci.sh \
            "$COMPILER" target/embedded-stdlib-tlci/stdlib.tlci "$NL_HOST_OS"
        ;;
    1)
        echo "[compile-profile] reuse validated embedded stdlib tlci input"
        for reuse_file in \
            target/embedded-stdlib-tlci/stdlib.tlci \
            target/embedded-stdlib-tlci/stdlib.tlci.tlch \
            target/embedded-stdlib-tlci/modules.txt \
            "target/embedded-stdlib-tlci/prelude-surface-$NL_HOST_OS.rodata" \
            target/embedded-stdlib-tlci/source-hash.txt; do
            [ -s "$reuse_file" ] || \
                fail "validated embedded tlci handoff is missing: $reuse_file"
        done
        ;;
    *)
        fail "TYPELISP_COMPILE_PROFILE_EMBEDDED_TLCI_REUSE must be 0 or 1"
        ;;
esac
if PRODUCER_IDENTITY=$($COMPILER --producer-identity 2>/dev/null); then
    :
else
    # The published transition seed predates the dedicated command but reports
    # the same exact revision as the second field of its version line.
    PRODUCER_IDENTITY=$($COMPILER --version 2>/dev/null |
        awk 'NR == 1 && $1 == "typelisp" { print $2 }')
fi
if ! printf '%s\n' "$PRODUCER_IDENTITY" | grep -Eq '^[0-9a-f]{40}$'; then
    fail "compiler reported malformed producer identity: $PRODUCER_IDENTITY"
fi
mkdir -p target/build-stage0
printf '%s' "$PRODUCER_IDENTITY" > target/build-stage0/git-hash.txt

echo "[compile-profile] compile profile-enabled CLI"
run_logged "$BUILD_STDOUT" "$BUILD_STDERR" "profile-enabled CLI compile failed" \
    "$COMPILER" compile src/main.tl -o "$PROFILE_ASM" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src \
    --cfg compiler-build-identity --cfg compile-profile --cfg embedded-stdlib-tlci \
    --cfg tlci-native-route-stress --cfg dependency-tlci-verification

echo "[compile-profile] link profile-enabled CLI"
if ! assemble_and_link compile-profile-cli "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "profile-enabled CLI link failed"
fi

# ci-verify reuses this one profile compiler for the sustained production-route
# gate instead of paying for a second full self-compile. The handoff is written
# only after a successful link and consumed only after this verifier passes.
if [ -n "${TYPELISP_COMPILE_PROFILE_CLI_PATH_FILE:-}" ]; then
    mkdir -p "$(dirname -- "$TYPELISP_COMPILE_PROFILE_CLI_PATH_FILE")"
    printf '%s\n' "$PROFILE_BIN" > "$TYPELISP_COMPILE_PROFILE_CLI_PATH_FILE"
fi

echo "[compile-profile] verify exhaustive stdlib tlci identity differential"
sh scripts/verify-stdlib-tlci-identity-differential.sh "$PROFILE_BIN"

# This also compiles the extracted poison-name helpers of the dotted-constructor
# cache.
echo "[compile-profile] verify dense macro profile storage and helper layout"
run_logged "$BUILD_STDOUT" "$BUILD_STDERR" "dense macro profile storage smoke failed" \
    "$PROFILE_BIN" run src/tests/compiler_typecheck_smoke.tl \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib \
    --stdlib-root src --cfg compile-profile --cfg test

echo "[compile-profile] verify native comptime host metadata parity"
run_logged "$COMPTIME_HOST_SMOKE_STDOUT" "$COMPTIME_HOST_SMOKE_STDERR" "native comptime host metadata smoke compile failed" \
    "$PROFILE_BIN" compile src/tests/comptime_host_smoke.tl \
    -o "$COMPTIME_HOST_SMOKE_ASM" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src
if ! assemble_and_link \
    comptime-host-smoke \
    "$COMPTIME_HOST_SMOKE_ASM" \
    "$COMPTIME_HOST_SMOKE_OBJ" \
    "$COMPTIME_HOST_SMOKE_BIN" \
    >> "$COMPTIME_HOST_SMOKE_STDOUT" 2>> "$COMPTIME_HOST_SMOKE_STDERR"; then
    show_failure_logs "$COMPTIME_HOST_SMOKE_STDOUT" "$COMPTIME_HOST_SMOKE_STDERR"
    fail "native comptime host metadata smoke link failed"
fi
set +e
"$COMPTIME_HOST_SMOKE_BIN" \
    >> "$COMPTIME_HOST_SMOKE_STDOUT" 2>> "$COMPTIME_HOST_SMOKE_STDERR"
COMPTIME_HOST_SMOKE_STATUS=$?
set -e
if [ "$COMPTIME_HOST_SMOKE_STATUS" -ne 42 ]; then
    show_failure_logs "$COMPTIME_HOST_SMOKE_STDOUT" "$COMPTIME_HOST_SMOKE_STDERR"
    fail "native comptime host metadata smoke expected exit 42, got $COMPTIME_HOST_SMOKE_STATUS"
fi

echo "[compile-profile] verify package-test native structural equality"
run_logged "$BUILD_CLI_TEST_STDOUT" "$BUILD_CLI_TEST_STDERR" "profile package-test native structural equality failed" \
    "$PROFILE_BIN" test --check src/build_cli_core.tl --target "$NL_BOOTSTRAP_TARGET" \
    --stdlib-root stdlib

echo "[compile-profile] verify hydrated prelude bypass and source parity"
run_logged "$SURFACE_HYDRATED_STDOUT" "$SURFACE_HYDRATED_STDERR" "hydrated prelude profile fixture failed" \
    "$PROFILE_BIN" compile tests/integration/arithmetic.tl -o "$SURFACE_HYDRATED_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args)
profile_rows "$SURFACE_HYDRATED_STDOUT" "$SURFACE_HYDRATED_STDERR" <<'ROWS'
has compile-profile-detail|prelude.source_pipeline_entries|0
has compile-profile-detail|prelude.hydrations|1
has compile-profile-detail|prelude.macro_walk_decl_visits|0
has compile-profile-detail|prelude.typecheck_decl_checks|0
ROWS
run_logged "$SURFACE_SOURCE_STDOUT" "$SURFACE_SOURCE_STDERR" "source prelude parity fixture failed" \
    "$PROFILE_BIN" compile tests/integration/arithmetic.tl -o "$SURFACE_SOURCE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib
profile_rows "$SURFACE_SOURCE_STDOUT" "$SURFACE_SOURCE_STDERR" <<'ROWS'
has compile-profile-detail|prelude.source_pipeline_entries|1
has compile-profile-detail|prelude.hydrations|0
ROWS
assert_intern_storage_schema_in \
    "$SURFACE_SOURCE_STDERR" \
    "$SURFACE_SOURCE_STDOUT" \
    "$SURFACE_SOURCE_STDERR"
cmp "$SURFACE_HYDRATED_ASM" "$SURFACE_SOURCE_ASM" >/dev/null ||
    fail "hydrated prelude assembly differs from source prelude output"

# surface_fallback LABEL FILE VALUE: build the profile CLI while FILE, an input
# of the embedded surface binding, holds VALUE (restored afterwards); its
# compile of the arithmetic fixture must fall back to the source prelude and
# match the explicit source route's assembly.
surface_fallback() {
    _sf=$WORKDIR/surface-$1
    _sf_saved=$(cat "$2")
    printf '%s' "$3" > "$2"
    set +e
    "$COMPILER" compile src/main.tl -o "$_sf-profile.s" --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src \
        --cfg compiler-build-identity --cfg compile-profile --cfg embedded-stdlib-tlci \
        > "$BUILD_STDOUT" 2> "$BUILD_STDERR"
    _sf_status=$?
    set -e
    printf '%s' "$_sf_saved" > "$2"
    [ "$_sf_status" -eq 0 ] || {
        show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
        fail "$1 profile CLI compile failed"
    }
    if ! assemble_and_link "surface-$1-profile-cli" "$_sf-profile.s" "$_sf-profile.$NL_OBJ_EXT" \
        "$_sf-profile$NL_BIN_EXT" >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
        show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
        fail "$1 profile CLI link failed"
    fi
    run_logged "$_sf.stdout" "$_sf.stderr" "$1 surface fallback fixture failed" \
        "$_sf-profile$NL_BIN_EXT" compile tests/integration/arithmetic.tl -o "$_sf.s" \
        --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args)
    profile_rows "$_sf.stdout" "$_sf.stderr" <<'ROWS'
has compile-profile-detail|prelude.source_pipeline_entries|1
has compile-profile-detail|prelude.hydrations|0
ROWS
    cmp "$SURFACE_SOURCE_ASM" "$_sf.s" >/dev/null ||
        fail "$1 fallback differs from explicit source output"
}

echo "[compile-profile] verify source-mismatched surface fallback"
surface_fallback source-mismatch target/embedded-stdlib-tlci/source-hash.txt \
    "$(cat target/embedded-stdlib-tlci/source-hash.txt)-mismatch"

echo "[compile-profile] verify producer-compiler-mismatched surface fallback"
MISMATCH_PRODUCER_IDENTITY=0000000000000000000000000000000000000000
if [ "$MISMATCH_PRODUCER_IDENTITY" = "$PRODUCER_IDENTITY" ]; then
    MISMATCH_PRODUCER_IDENTITY=1111111111111111111111111111111111111111
fi
surface_fallback producer-mismatch target/build-stage0/git-hash.txt "$MISMATCH_PRODUCER_IDENTITY"

echo "[compile-profile] compile compact-summary CLI"
run_logged "$SUMMARY_BUILD_STDOUT" "$SUMMARY_BUILD_STDERR" "compact-summary CLI compile failed" \
    "$COMPILER" compile src/main.tl -o "$SUMMARY_ASM" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src \
    --cfg compile-profile --cfg compile-profile-summary
if ! assemble_and_link compile-profile-summary-cli \
    "$SUMMARY_ASM" "$SUMMARY_OBJ" "$SUMMARY_BIN" \
    >> "$SUMMARY_BUILD_STDOUT" 2>> "$SUMMARY_BUILD_STDERR"; then
    show_failure_logs "$SUMMARY_BUILD_STDOUT" "$SUMMARY_BUILD_STDERR"
    fail "compact-summary CLI link failed"
fi

echo "[compile-profile] verify compact summary schema and bound"
run_logged "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR" "compact-summary fixture compile failed" \
    "$SUMMARY_BIN" compile tests/integration/arithmetic.tl -o "$SUMMARY_OUTPUT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib
profile_rows "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR" <<'ROWS'
has compile-profile-summary|scope|kind|rank|name|elapsed_ms|calls
has compile-profile-summary|optimizer|pass|
has compile-profile-summary|optimizer|pass|0|<remainder>|
has compile-profile-summary|optimizer|function|
has compile-profile-summary|optimizer|function|0|<remainder>|
has compile-profile-summary|optimizer|module|
has compile-profile-summary|optimizer|module|0|<remainder>|
has compile-profile-summary|backend|function|
has compile-profile-summary|backend|function|0|<remainder>|
has compile-profile-summary|backend|module|
has compile-profile-summary|backend|module|0|<remainder>|
has compile-profile|total|
lacks compile-profile-detail|
ROWS
summary_lines=$(grep -c '^compile-profile-summary|' "$SUMMARY_CHECK_STDERR")
if [ "$summary_lines" -gt 46 ]; then
    show_failure_logs "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
    fail "compact summary exceeded 46 rows: $summary_lines"
fi
if ! awk -F'|' '
    $1 == "compile-profile-summary" && $2 != "scope" {
        key = $2 "|" $3
        if ($4 != 0 && $4 != previous[key] + 1) bad = 1
        if ($4 != 0) previous[key] = $4
    }
    END { exit bad ? 1 : 0 }
' "$SUMMARY_CHECK_STDERR"; then
    fail "compact summary ranks are not stable ascending rows"
fi

echo "[compile-profile] verify normal compiler has no profile output"
run_logged "$NORMAL_CHECK_STDOUT" "$NORMAL_CHECK_STDERR" "normal fixture compile failed" \
    "$COMPILER" compile tests/integration/arithmetic.tl -o "$NORMAL_OUTPUT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib
profile_rows "$NORMAL_CHECK_STDOUT" "$NORMAL_CHECK_STDERR" <<'ROWS'
lacks compile-profile
ROWS

echo "[compile-profile] verify macro detach structural-change decision"
run_logged "$DETACH_NOCHANGE_STDOUT" "$DETACH_NOCHANGE_STDERR" "macro detach no-change fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/compile_profile_macro_detach_unchanged.tl \
    -o "$DETACH_NOCHANGE_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root stdlib
profile_rows "$DETACH_NOCHANGE_STDOUT" "$DETACH_NOCHANGE_STDERR" <<'ROWS'
l lower.macro_detach.fast_path_hits = 1
l lower.macro_detach.fast_path_misses = 0
l lower.macro_detach.change_reasons = 0
ROWS

run_logged "$DETACH_CHANGED_STDOUT" "$DETACH_CHANGED_STDERR" "macro detach changed fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/compile_profile_macro_detail.tl \
    -o "$DETACH_CHANGED_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root stdlib
profile_rows "$DETACH_CHANGED_STDOUT" "$DETACH_CHANGED_STDERR" <<'ROWS'
l lower.macro_detach.fast_path_hits = 0
l lower.macro_detach.fast_path_misses = 1
has compile-profile|lower.macro_handoff|
has compile-profile|lower.macro_expand|
has compile-profile|lower.macro_finalize|
l lower.macro_detach.change_reasons >= 1
has compile-profile|typecheck.macro.retention_retired_symbol_rotations|
has compile-profile|typecheck.macro.retention_expansion_scratch_creations|
has compile-profile|typecheck.macro.retention_active_generation_rotations|
has compile-profile|typecheck.macro.retention_retired_generation_rotations|
has compile-profile|typecheck.macro.retention_live_symbols_max_bytes|
has compile-profile|typecheck.macro.retention_retired_symbols_max_bytes|
has compile-profile|typecheck.macro.retention_expansion_scratch_max_bytes|
has compile-profile|typecheck.macro.retention_active_generations_max_bytes|
has compile-profile|typecheck.macro.retention_retired_generations_max_bytes|
ROWS
assert_lifetime_ledger_in \
    "$DETACH_CHANGED_STDERR" \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"

echo "[compile-profile] verify compile-wide peak survives nested reset"
run_logged "$PEAK_RESET_STDOUT" "$PEAK_RESET_STDERR" "compile-wide nested peak reset fixture failed" \
    "$PROFILE_BIN" run tests/integration/compile_profile_nested_peak_reset.tl \
    --cfg compile-profile --stdlib-root . --stdlib-root stdlib

echo "[compile-profile] verify per-entry batch memory boundaries"
printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" "$(batch_path "$BATCH_ARITH")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" "$(batch_path "$BATCH_FUNCTIONS")" > "$BATCH_LIST"
run_logged "$BATCH_STDOUT" "$BATCH_STDERR" "profile batch fixture failed" \
    "$PROFILE_BIN" compile --batch "$BATCH_LIST" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib
profile_rows "$BATCH_STDOUT" "$BATCH_STDERR" <<'ROWS'
lines 1 compile-batch-profile|entry_ordinal|marker|
lines 1 compile-batch-profile|0|entry-start|
lines 1 compile-batch-profile|0|emit-complete|
lines 1 compile-batch-profile|0|owned-pool-release|
lines 1 compile-batch-profile|0|intern-session-cleanup|
lines 1 compile-batch-profile|0|lower-cleanup|
lines 1 compile-batch-profile|0|scratch-destroy-steady|
lines 1 compile-batch-profile|1|entry-start|
lines 1 compile-batch-profile|1|emit-complete|
lines 1 compile-batch-profile|1|owned-pool-release|
lines 1 compile-batch-profile|1|intern-session-cleanup|
lines 1 compile-batch-profile|1|lower-cleanup|
lines 1 compile-batch-profile|1|scratch-destroy-steady|
lines 2 compile-profile|intern.records.source_live|
lines 2 compile-profile|intern.records.source_capacity|
lines 2 compile-profile|intern.records.generated_live|
lines 2 compile-profile|intern.records.generated_capacity|
lines 2 compile-profile|intern.records.source_resizes|
lines 2 compile-profile|intern.records.generated_resizes|
lines 2 compile-profile|intern.records.reserved_bytes|
lines 2 compile-profile|intern.source_map.live|
lines 2 compile-profile|intern.source_map.capacity|
lines 2 compile-profile|intern.source_map.probes_total|
lines 2 compile-profile|intern.source_map.probe_max|
lines 2 compile-profile|intern.source_map.resizes|
lines 2 compile-profile|intern.source_map.reserved_bytes|
lines 2 compile-profile|intern.canonical_map.live|
lines 2 compile-profile|intern.canonical_map.capacity|
lines 2 compile-profile|intern.canonical_map.probes_total|
lines 2 compile-profile|intern.canonical_map.probe_max|
lines 2 compile-profile|intern.canonical_map.resizes|
lines 2 compile-profile|intern.canonical_map.reserved_bytes|
ROWS
if ! awk -F'|' '
    $1 == "compile-batch-profile" && $2 != "entry_ordinal" {
        if (NF != 9 || $2 !~ /^[0-9]+$/ || $4 !~ /^-?[0-9]+$/ ||
            $5 !~ /^-?[0-9]+$/ || $6 !~ /^-?[0-9]+$/ ||
            $7 !~ /^-?[0-9]+$/ || $8 !~ /^-?[0-9]+$/ ||
            $9 !~ /^-?[0-9]+$/) bad = 1
        rows++
    }
    END { exit rows == 12 && !bad ? 0 : 1 }
' "$BATCH_STDERR"; then
    show_failure_logs "$BATCH_STDOUT" "$BATCH_STDERR"
    fail "batch profile rows do not match the stable nine-field schema"
fi
if ! awk -F'|' '
    $1 == "compile-batch-profile" && $3 == "owned-pool-release" {
        rows++
        if (($7 + 0) > 1048576) bad = 1
    }
    END { exit rows == 2 && !bad ? 0 : 1 }
' "$BATCH_STDERR"; then
    show_failure_logs "$BATCH_STDOUT" "$BATCH_STDERR"
    fail "post-emission pool release rematerialized more than 1 MiB"
fi
if ! awk -F'|' '
    $1 == "compile-batch-profile" && $2 == 0 && $3 == "entry-start" {
        starts++
        if (($8 + 0) <= 0 || ($9 + 0) != 0) bad = 1
    }
    $1 == "compile-batch-profile" && $3 == "scratch-destroy-steady" {
        steady++
        drift = $9 + 0
        if (drift < 0) drift = -drift
        if (drift > 4194304) bad = 1
    }
    END { exit starts == 1 && steady == 2 && !bad ? 0 : 1 }
' "$BATCH_STDERR"; then
    show_failure_logs "$BATCH_STDOUT" "$BATCH_STDERR"
    fail "batch absolute live baseline drift exceeded 4 MiB"
fi
if ! "$PROFILE_BIN" compile tests/integration/arithmetic.tl \
    -o "$BATCH_SINGLE_ARITH" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib \
    > "$BATCH_SINGLE_STDOUT" 2> "$BATCH_SINGLE_STDERR" ||
   ! "$PROFILE_BIN" compile tests/integration/functions.tl \
    -o "$BATCH_SINGLE_FUNCTIONS" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib \
    >> "$BATCH_SINGLE_STDOUT" 2>> "$BATCH_SINGLE_STDERR"; then
    show_failure_logs "$BATCH_SINGLE_STDOUT" "$BATCH_SINGLE_STDERR"
    fail "profile single-entry parity fixture failed"
fi
cmp "$BATCH_ARITH" "$BATCH_SINGLE_ARITH" >/dev/null ||
    fail "profile batch arithmetic assembly differs from one-entry output"
cmp "$BATCH_FUNCTIONS" "$BATCH_SINGLE_FUNCTIONS" >/dev/null ||
    fail "profile batch functions assembly differs from one-entry output"

echo "[compile-profile] verify failed-entry marker and diagnostic attribution"
printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" "$(batch_path "$FAILED_BATCH_FIRST")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" "$(batch_path "$FAILED_BATCH_SECOND")" > "$FAILED_BATCH_LIST"
if "$PROFILE_BIN" compile --batch "$FAILED_BATCH_LIST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$FAILED_BATCH_STDOUT" 2> "$FAILED_BATCH_STDERR"; then
    show_failure_logs "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
    fail "profile batch with invalid second entry unexpectedly passed"
fi
profile_rows "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR" <<'ROWS'
has compile: batch source failed:
has functions.tl
lines 1 compile-batch-profile|1|emit-complete|
ROWS
if ! grep '^compile-batch-profile|1|emit-complete|' "$FAILED_BATCH_STDERR" >/dev/null; then
    show_failure_logs "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
    fail "failed-entry emit marker was not independently parseable"
fi
cmp "$FAILED_BATCH_FIRST" "$BATCH_ARITH" >/dev/null ||
    fail "successful output before failed batch entry changed"

printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" "$(batch_path "$NORMAL_BATCH_ARITH")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" "$(batch_path "$NORMAL_BATCH_FUNCTIONS")" > "$NORMAL_BATCH_LIST"
run_logged "$NORMAL_BATCH_STDOUT" "$NORMAL_BATCH_STDERR" "normal batch fixture failed" \
    "$COMPILER" compile --batch "$NORMAL_BATCH_LIST" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib
profile_rows "$NORMAL_BATCH_STDOUT" "$NORMAL_BATCH_STDERR" <<'ROWS'
lacks compile-batch-profile
ROWS
cmp "$BATCH_ARITH" "$NORMAL_BATCH_ARITH" >/dev/null ||
    fail "profile-enabled batch changed normal arithmetic assembly"
cmp "$BATCH_FUNCTIONS" "$NORMAL_BATCH_FUNCTIONS" >/dev/null ||
    fail "profile-enabled batch changed normal functions assembly"

if [ "$NL_HOST_OS" = windows ]; then
    command -v pwsh >/dev/null 2>&1 || fail "pwsh is required for Windows batch memory telemetry"
    if ! pwsh -NoProfile -File scripts/measure-compile-batch-memory.ps1 \
        -Compiler "$PROFILE_BIN" \
        -Batch "$BATCH_LIST" \
        -OutputDir "$WINDOWS_MEMORY_DIR" \
        -Target "$NL_BOOTSTRAP_TARGET" \
        -StdlibRoot stdlib \
        > "$WORKDIR/windows-memory.stdout" \
        2> "$WORKDIR/windows-memory.stderr"; then
        show_failure_logs "$WORKDIR/windows-memory.stdout" "$WORKDIR/windows-memory.stderr"
        fail "Windows batch memory sampler failed"
    fi
    windows_memory_rows=$(awk 'NR > 1 { rows++ } END { print rows + 0 }' \
        "$WINDOWS_MEMORY_DIR/memory.tsv")
    [ "$windows_memory_rows" -eq 12 ] ||
        fail "Windows batch memory sampler expected 12 rows, got $windows_memory_rows"
fi

expected_heavy_sources='compiler_typecheck_smoke|src/tests/compiler_typecheck_smoke.tl
compiler_lower_smoke|src/tests/compiler_lower_smoke.tl
compiler_backend_smoke|src/tests/compiler_backend_smoke.tl
doc_test_smoke|src/tests/doc_test_smoke.tl
compiler_driver_pic_smoke|src/tests/compiler_driver_pic_smoke.tl'
actual_heavy_sources=$(scripts/measure-heavy-closure-profile.sh --list)
if [ "$actual_heavy_sources" != "$expected_heavy_sources" ]; then
    fail "heavy-closure harness source list changed"
fi

# A source selfhost compile exercises the compiler's embedded canonical stdlib
# payloads and the retention/attribution invariants on the largest input. The
# probe is Windows-only.
if [ "$NL_HOST_OS" = windows ]; then
    echo "[compile-profile] selfhost embedded-stdlib allocation probe"
    run_logged "$SELFHOST_STDOUT" "$SELFHOST_STDERR" "profile-enabled selfhost compile failed" \
        "$PROFILE_BIN" compile src/main.tl -o "$SELFHOST_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root stdlib \
        --stdlib-root src --cfg compile-profile
    assert_profile_total_peak_covers_live_in \
        "$SELFHOST_STDERR" \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_segmented_program_view_in \
        "$SELFHOST_STDERR" \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_fired_decl_attribution_in \
        "$SELFHOST_STDERR" \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_lifetime_ledger_in \
        "$SELFHOST_STDERR" \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    profile_rows "$SELFHOST_STDOUT" "$SELFHOST_STDERR" <<'ROWS'
c typecheck.macro.retention_retired_symbol_rotations >= 1
c typecheck.macro.retention_expansion_scratch_creations >= 1
c typecheck.macro.retention_active_generation_rotations >= 1
c typecheck.macro.retention_retired_generation_rotations >= 1
c typecheck.macro.retention_live_symbols_max_bytes >= 1
c typecheck.macro.retention_retired_symbols_max_bytes >= 1
c typecheck.macro.retention_expansion_scratch_max_bytes >= 1
c typecheck.macro.retention_active_generations_max_bytes >= 1
c typecheck.macro.retention_retired_generations_max_bytes >= 1
ROWS
    SELFHOST_SEGMENT_FILE_FLATTENS=$(profile_counter_value_in \
        "$SELFHOST_STDERR" \
        "typecheck.macro.walk_segment_fallback_file_flattens")
    SELFHOST_MATERIALIZED_SPLICES=$(profile_counter_value_in \
        "$SELFHOST_STDERR" \
        "typecheck.macro.walk_decl_sp_mat_count")
    SELFHOST_SEGMENT_ALIAS_FLATTENS=$(profile_counter_value_in \
        "$SELFHOST_STDERR" \
        "typecheck.macro.walk_segment_fallback_alias_flattens")
    SELFHOST_REGISTRY_INVALIDATIONS=$(profile_counter_value_in \
        "$SELFHOST_STDERR" \
        "typecheck.macro.walk_splice_registry_invalidated")
    if [ "$SELFHOST_SEGMENT_FILE_FLATTENS" -ne "$SELFHOST_MATERIALIZED_SPLICES" ] ||
        [ "$SELFHOST_SEGMENT_ALIAS_FLATTENS" -ne "$SELFHOST_REGISTRY_INVALIDATIONS" ]; then
        show_failure_logs "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
        fail "segmented-program fallbacks do not match their conservative paths: file=$SELFHOST_SEGMENT_FILE_FLATTENS materialized=$SELFHOST_MATERIALIZED_SPLICES alias=$SELFHOST_SEGMENT_ALIAS_FLATTENS invalidated=$SELFHOST_REGISTRY_INVALIDATIONS"
    fi
    # The compiler source currently exercises ordinary Decls, generated
    # Modules, and generated-file nominal deltas. All are additive: the CTFE
    # metadata cache builds once, grows when needed, and never rescans the
    # whole source graph for a splice.
    profile_rows "$SELFHOST_STDOUT" "$SELFHOST_STDERR" <<'ROWS'
c typecheck.macro.walk_splice_ctfe_builds = 1
c typecheck.macro.walk_splice_ctfe_cleared = 0
c typecheck.macro.walk_splice_ctfe_cache_unavailable = 0
c typecheck.macro.walk_splice_ctfe_extensions >= 1
# Every marker batch flushes a delta cache plus its unresolved-signature
# index; no tail build or conservative fallback may hide equivalent work.
c typecheck.macro.walk_sp_envbuild_calls = 0
c typecheck.macro.walk_sp_envbuild_alloc_kb = 0
c typecheck.macro.walk_splice_env_fallbacks = 0
c typecheck.macro.walk_sp_reresolve_calls >= 1
c typecheck.macro.walk_splice_env_reresolve_updates >= 1
# The cache-local candidate scan revisits only unresolved signatures.
c typecheck.macro.walk_splice_env_reresolve_candidates >= 1
# A ceiling on re-resolution allocation; it grows with the compiler source.
c typecheck.macro.walk_sp_reresolve_alloc_kb <= 31400
ROWS
    # Each ownership boundary exposes used nodes, logical capacity and physical
    # segmentation for both AST pools.
    profile_rows "$SELFHOST_STDOUT" "$SELFHOST_STDERR" <<'ROWS'
has compile-profile|lower.ast_expr_pool.source_load.len|
has compile-profile|lower.ast_expr_pool.source_load.capacity|
has compile-profile|lower.ast_expr_pool.source_load.segments|
has compile-profile|lower.ast_expr_pool.source_load.segment_bytes|
has compile-profile|lower.ast_type_pool.source_load.len|
has compile-profile|lower.ast_type_pool.source_load.capacity|
has compile-profile|lower.ast_type_pool.source_load.segments|
has compile-profile|lower.ast_type_pool.source_load.segment_bytes|
has compile-profile|lower.ast_expr_pool.checked_pool.len|
has compile-profile|lower.ast_expr_pool.checked_pool.capacity|
has compile-profile|lower.ast_expr_pool.checked_pool.segments|
has compile-profile|lower.ast_expr_pool.checked_pool.segment_bytes|
has compile-profile|lower.ast_type_pool.checked_pool.len|
has compile-profile|lower.ast_type_pool.checked_pool.capacity|
has compile-profile|lower.ast_type_pool.checked_pool.segments|
has compile-profile|lower.ast_type_pool.checked_pool.segment_bytes|
has compile-profile|lower.ast_expr_pool.macro_detach.len|
has compile-profile|lower.ast_expr_pool.macro_detach.capacity|
has compile-profile|lower.ast_expr_pool.macro_detach.segments|
has compile-profile|lower.ast_expr_pool.macro_detach.segment_bytes|
has compile-profile|lower.ast_type_pool.macro_detach.len|
has compile-profile|lower.ast_type_pool.macro_detach.capacity|
has compile-profile|lower.ast_type_pool.macro_detach.segments|
has compile-profile|lower.ast_type_pool.macro_detach.segment_bytes|
has compile-profile|lower.ast_expr_pool.retained_reader.len|
has compile-profile|lower.ast_expr_pool.retained_reader.capacity|
has compile-profile|lower.ast_expr_pool.retained_reader.segments|
has compile-profile|lower.ast_expr_pool.retained_reader.segment_bytes|
has compile-profile|lower.ast_type_pool.retained_reader.len|
has compile-profile|lower.ast_type_pool.retained_reader.capacity|
has compile-profile|lower.ast_type_pool.retained_reader.segments|
has compile-profile|lower.ast_type_pool.retained_reader.segment_bytes|
# Arena destruction is a negative live delta; accumulated macro scratch stays
# below 500 MB.
l typecheck.macro_scratch_release >= -500000000
ROWS
    # Last-use pruning only needs lexical bindings.
    BORROW_LIFETIME_SCAN_MAX=$(profile_counter_value_in \
        "$SELFHOST_STDERR" \
        "typecheck.env.borrow_lifetime_scan_max")
    [ "$BORROW_LIFETIME_SCAN_MAX" -le 256 ] ||
        fail "borrow lifetime scan crossed lexical boundary: $BORROW_LIFETIME_SCAN_MAX bindings"
    # Dotted imports revisit module markers thousands of times, so module-local
    # macro and lowering views are reused by module, not rebuilt per marker.
    profile_rows "$SELFHOST_STDOUT" "$SELFHOST_STDERR" <<'ROWS'
c typecheck.env.macro_cache_entries <= 2000000
l lower.name_cache.entries <= 1500000
ROWS
    assert_lower_name_cache_storage_in \
        "$SELFHOST_STDERR" "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
    for cache in module_name_cache module_local_view; do
        cache_lookups=$(profile_live_counter_value_in \
            "$SELFHOST_STDERR" "lower.$cache.lookups") ||
            fail "missing lower.$cache.lookups profile counter"
        cache_hits=$(profile_live_counter_value_in \
            "$SELFHOST_STDERR" "lower.$cache.hits") ||
            fail "missing lower.$cache.hits profile counter"
        cache_entries=$(profile_live_counter_value_in \
            "$SELFHOST_STDERR" "lower.$cache.entries") ||
            fail "missing lower.$cache.entries profile counter"
        [ "$cache_entries" -gt 0 ] ||
            fail "lower.$cache retained no module entries"
        [ "$cache_hits" -gt 0 ] ||
            fail "lower.$cache recorded no repeated-module hits"
        [ "$cache_lookups" -eq "$((cache_hits + cache_entries))" ] ||
            fail "lower.$cache lookup accounting mismatch: lookups=$cache_lookups hits=$cache_hits entries=$cache_entries"
        [ "$cache_entries" -le 1024 ] ||
            fail "lower.$cache retained too many phase entries: $cache_entries"
    done
else
    echo "[compile-profile] selfhost allocation probe SKIPPED (windows-gated)"
fi

echo "[compile-profile] alias module name-cache storage"
ALIAS_VIEW_ASM="$WORKDIR/profile-alias-view.s"
ALIAS_VIEW_STDOUT="$WORKDIR/profile-alias-view.stdout"
ALIAS_VIEW_STDERR="$WORKDIR/profile-alias-view.stderr"
run_logged "$ALIAS_VIEW_STDOUT" "$ALIAS_VIEW_STDERR" "profiled alias-module fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/generated_import_alias_scopes.tl \
    -o "$ALIAS_VIEW_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root tests/integration --stdlib-root stdlib --opt-level 1
assert_lower_name_cache_storage_in \
    "$ALIAS_VIEW_STDERR" "$ALIAS_VIEW_STDOUT" "$ALIAS_VIEW_STDERR"

echo "[compile-profile] compile deep string concat fixture"
run_logged "$CONCAT_STDOUT" "$CONCAT_STDERR" "profiled deep string concat fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/string_concat_deep.tl -o "$CONCAT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) --stdlib-root . \
    --stdlib-root stdlib --opt-level 0

# Two 16-leaf trees flatten once each. The first group holds five leaves and
# each carry group adds four, yielding three concat5 calls plus one concat4
# call per tree. These counters make both the traversal and fan-in invariant
# observable without depending on assembly formatting.
profile_rows "$CONCAT_STDOUT" "$CONCAT_STDERR" <<'ROWS'
l lower.string_concat.trees = 2
l lower.string_concat.leaves = 32
l lower.string_concat.runtime_calls = 8
# A program without specialization never creates a pruning name environment.
l lower.name_env.prune_arena_releases = 0
has compile-profile|intern.render_calls|
has compile-profile-detail|intern.phase.render|
has compile-profile-detail|intern.lower_phase.render|
has compile-profile|lower.specialization.structural_keys.created|
has compile-profile|lower.specialization.structural_keys.reused|
has compile-profile|lower.specialization.generated_text.materialized|
has compile-profile|lower.specialization.render.calls|
has compile-profile|lower.specialization.render.cache_hits|
has compile-profile|lower.specialization.render.cache_misses|
ROWS

echo "[compile-profile] compile specialization counter fixture"
run_logged "$SPECIALIZATION_STDOUT" "$SPECIALIZATION_STDERR" "profiled specialization fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/comptime_type_specialization.tl \
    -o "$SPECIALIZATION_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root . --stdlib-root stdlib
profile_rows "$SPECIALIZATION_STDOUT" "$SPECIALIZATION_STDERR" <<'ROWS'
l lower.specialization.structural_keys.created >= 1
# The name environment over the specialized declarations serves pruning only:
# its arena is retired as soon as the reachability walk returns.
l lower.name_env.prune_arena_releases = 1
l lower.specialization.generated_text.materialized = 0
l lower.specialization.render.calls = 1
l lower.specialization.render.cache_hits = 0
l lower.specialization.render.cache_misses = 1
ROWS

# A successful compile must not pay for "did you mean" suggestions. Macro
# operand capture type-probes each operand and drops a failed probe; the stdlib
# format macros below probe operands that only typecheck inside their own
# templates, so this program discards unbound-name errors while compiling
# cleanly. The finalizer runs for each (the fixture reaches the path); none may
# scan the visible names.
DISCARDED_PROBE_SRC="$WORKDIR/discarded-probe.tl"
DISCARDED_PROBE_STDOUT="$WORKDIR/discarded-probe.stdout"
DISCARDED_PROBE_STDERR="$WORKDIR/discarded-probe.stderr"
cat > "$DISCARDED_PROBE_SRC" <<'FIXTURE'
(import stdlib.io)

(define (main) : i64
  (let
    [count : i64 42]
    (begin
      (io.print-format "{}" count)
      (io.println "")
      0)))
FIXTURE
echo "[compile-profile] check discarded operand probes build no unbound-name suggestion"
run_logged "$DISCARDED_PROBE_STDOUT" "$DISCARDED_PROBE_STDERR" "discarded operand probe fixture check failed" \
    "$PROFILE_BIN" check "$DISCARDED_PROBE_SRC" --stdlib-root . --stdlib-root stdlib
profile_rows "$DISCARDED_PROBE_STDOUT" "$DISCARDED_PROBE_STDERR" <<'ROWS'
c typecheck.env.unbound_finalizers >= 1
c typecheck.env.unbound_scans all= 0
ROWS

echo "[compile-profile] check macro detail fixture"
run_logged "$CHECK_STDOUT" "$CHECK_STDERR" "profiled fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_macro_detail.tl \
    --stdlib-root . --stdlib-root stdlib

assert_fired_decl_timing_in "$CHECK_STDERR" "$CHECK_STDOUT" "$CHECK_STDERR"

str_cat_arity_2_line=$(grep -nF \
    "stdlib.str_cat/str-cat arity=2 calls=2" \
    "$CHECK_STDERR" | sed -n '1s/:.*//p')
str_cat_arity_6_line=$(grep -nF \
    "stdlib.str_cat/str-cat arity=6 calls=1" \
    "$CHECK_STDERR" | sed -n '1s/:.*//p')
profile_rows "$CHECK_STDOUT" "$CHECK_STDERR" <<'ROWS'
has compile-profile-detail|typecheck.macro_expand|
has compile-profile|typecheck.macro_materialize|
has stdlib.str_cat/str-cat arity=2 calls=2
has stdlib.str_cat/str-cat arity=6 calls=1
# str-cat's six-plus-operand path delegates packing to the runtime module.
has stdlib.str_cat_runtime/str-cat-pack arity=3
has stdlib.core_macros/and arity=3
has stdlib.core_macros/or arity=2
has stdlib.core_macros/cond arity=4
has compile-profile|typecheck.macro.walk_rewalk_zero_fire_calls|
has compile-profile|typecheck.macro.walk_rewalk_provenance_skips|
has compile-profile|typecheck.macro.walk_hygiene_nodes_reused|
has compile-profile|typecheck.macro.walk_hygiene_nodes_copied|
has compile-profile|typecheck.macro.walk_decl_fire_self_us|
has compile-profile|typecheck.macro.walk_decl_fire_survivor_bytes|
has compile-profile|typecheck.macro.walk_decl_fire_nonoutput_live_bytes|
has compile-profile|typecheck.macro.walk_decl_fire_residual_live_bytes|
has compile-profile|typecheck.macro.walk_decl_fire_source_shared_expr_refs|
has compile-profile|typecheck.macro.walk_decl_generation_rotations|
c typecheck.macro.walk_hygiene_nodes_reused >= 1
c typecheck.macro.walk_rewalk_provenance_skips >= 1
has compile-profile|typecheck.env.binds|
has compile-profile|typecheck.env.lookups|
has compile-profile|typecheck.env.cache_builds|
has compile-profile|typecheck.env.cache_entries|
has compile-profile|typecheck.env.macro_cache_entries|
has compile-profile|typecheck.env.marker_scans|
has compile-profile|typecheck.env.module_local_hits|
has compile-profile|typecheck.env.module_local_misses|
has compile-profile|typecheck.env.scoped_binds|
has compile-profile|typecheck.env.scoped_cache_hits|
has compile-profile|typecheck.env.scoped_cache_misses|
has compile-profile|typecheck.env.scoped_tail_fallbacks|
has compile-profile|typecheck.env.scoped_materializations|
has compile-profile|typecheck.env.scoped_materialized_slots|
has compile-profile|typecheck.env.borrow_lifetime_scans|
has compile-profile|typecheck.env.borrow_lifetime_scan_bindings|
has compile-profile|typecheck.env.borrow_lifetime_scan_max|
has compile-profile|typecheck.env.unbound_finalizers|
has compile-profile|typecheck.env.unbound_scans|
has compile-profile|typecheck.env.unbound_candidate_slots|
has compile-profile|typecheck.env.unbound_visible_candidates|
has compile-profile|typecheck.env.unbound_length_survivors|
has compile-profile|typecheck.env.unbound_edit_evaluations|
has compile-profile|typecheck.resolve.typecheck.ordinary_calls|
has compile-profile|typecheck.resolve.typecheck.concrete_leaf_calls|
has compile-profile|typecheck.resolve.typecheck.concrete_composite_calls|
has compile-profile|typecheck.resolve.typecheck.unresolved_var_calls|
has compile-profile|typecheck.resolve.typecheck.unresolved_varargs_calls|
has compile-profile|typecheck.resolve.typecheck.unresolved_composite_calls|
has compile-profile|typecheck.resolve.typecheck.name_lookup_calls|
has compile-profile|typecheck.resolve.typecheck.name_cache_hits|
has compile-profile|typecheck.resolve.typecheck.name_cache_misses|
has compile-profile|typecheck.resolve.typecheck.type_symbol_probes|
has compile-profile|typecheck.resolve.typecheck.type_handle_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_cache_hits|
has compile-profile|typecheck.resolve.typecheck.type_handle_cache_misses|
has compile-profile|typecheck.resolve.typecheck.type_handle_symbol_probes|
has compile-profile|typecheck.resolve.typecheck.type_handle_resolver_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_nominal_lifetime_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_constructor_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_aggregate_layout_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_move_kind_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_qualified_owner_lookups|
has compile-profile|typecheck.resolve.typecheck.type_handle_lazy_unique_lookups|
# Ordinary calls are classified; name lookups and type handles are hits or
# misses, each miss one symbol probe; every type-handle lookup has a caller.
sum typecheck.resolve.typecheck.ordinary_calls = typecheck.resolve.typecheck.concrete_leaf_calls + typecheck.resolve.typecheck.concrete_composite_calls + typecheck.resolve.typecheck.unresolved_var_calls + typecheck.resolve.typecheck.unresolved_varargs_calls + typecheck.resolve.typecheck.unresolved_composite_calls
sum typecheck.resolve.typecheck.name_lookup_calls = typecheck.resolve.typecheck.name_cache_hits + typecheck.resolve.typecheck.name_cache_misses
sum typecheck.resolve.typecheck.name_cache_misses = typecheck.resolve.typecheck.type_symbol_probes
sum typecheck.resolve.typecheck.type_handle_lookups = typecheck.resolve.typecheck.type_handle_cache_hits + typecheck.resolve.typecheck.type_handle_cache_misses
sum typecheck.resolve.typecheck.type_handle_cache_misses = typecheck.resolve.typecheck.type_handle_symbol_probes
sum typecheck.resolve.typecheck.type_handle_lookups = typecheck.resolve.typecheck.type_handle_resolver_lookups + typecheck.resolve.typecheck.type_handle_nominal_lifetime_lookups + typecheck.resolve.typecheck.type_handle_constructor_lookups + typecheck.resolve.typecheck.type_handle_aggregate_layout_lookups + typecheck.resolve.typecheck.type_handle_move_kind_lookups + typecheck.resolve.typecheck.type_handle_qualified_owner_lookups + typecheck.resolve.typecheck.type_handle_lazy_unique_lookups
c typecheck.resolve.typecheck.type_handle_resolver_lookups >= 1
c typecheck.resolve.typecheck.type_handle_nominal_lifetime_lookups >= 1
c typecheck.resolve.typecheck.type_handle_constructor_lookups >= 1
c typecheck.resolve.typecheck.type_handle_cache_hits >= 1
c typecheck.resolve.typecheck.concrete_composite_calls >= 1
c typecheck.resolve.typecheck.unresolved_var_calls >= 1
has compile-profile|typecheck.macro.generated_module_materializations|
has compile-profile|typecheck.macro.generated_decl_checks|
has compile-profile|typecheck.macro.generated_module_memo_hits|
has compile-profile|typecheck.macro.generated_module_catalog_builds|
has compile-profile|typecheck.macro.generated_module_catalog_hits|
has compile-profile|typecheck.macro.generated_module_catalog_validations|
has compile-profile|typecheck.macro.live_rebuilds|
has compile-profile|typecheck.macro.live_reuses|
has compile-profile|typecheck.macro.live_registry_rebuilds|
has compile-profile|typecheck.macro.live_registry_reuses|
has compile-profile|typecheck.macro.stdlib_tlci_catalog_hits|
has compile-profile|typecheck.macro.stdlib_tlci_catalog_misses|
has compile-profile|typecheck.macro.stdlib_tlci_load_failures|
has compile-profile|typecheck.macro.stdlib_tlci_interpreted_fallbacks|
has compile-profile|typecheck.macro.stdlib_source_interpreted|
has compile-profile|typecheck.macro.stdlib_tlci_native_expr_results|
has compile-profile|typecheck.macro.stdlib_tlci_direct_expr_results|
has compile-profile|typecheck.macro.stdlib_tlci_direct_shell_env_folds|
has compile-profile|typecheck.macro.stdlib_tlci_native_module_results|
has compile-profile|typecheck.macro.stdlib_tlci_native_decls_results|
has compile-profile|typecheck.macro.stdlib_tlci_entry_resolution_us|
has compile-profile|typecheck.macro.stdlib_tlci_entry_resolution_calls|
has compile-profile|typecheck.macro.stdlib_tlci_entry_invoke_us|
has compile-profile|typecheck.macro.stdlib_tlci_entry_invoke_calls|
has compile-profile|typecheck.macro.stdlib_tlci_shell_learns|
has compile-profile|typecheck.macro.stdlib_tlci_shell_cache_hits|
has compile-profile|typecheck.macro.walk_direct_marshal_us|
has compile-profile|typecheck.macro.walk_direct_marshal_calls|
has compile-profile|typecheck.macro.walk_direct_marshal_alloc_kb|
has compile-profile|typecheck.macro.walk_direct_marshal_live_kb|
# The repo's stdlib is content-identical to the embedded payload, so the
# catalog dispatches natively on both hosts.
c typecheck.macro.stdlib_tlci_catalog_hits >= 1
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
c typecheck.macro.stdlib_tlci_direct_expr_results >= 1
c typecheck.macro.walk_direct_marshal_calls >= 1
c typecheck.macro.stdlib_tlci_catalog_misses = 0
c typecheck.macro.stdlib_source_interpreted = 0
# Macro expansion is a single demand-driven pass (no fixed-point loop).
lacks typecheck.macro.fixed_point_
has compile-profile|typecheck.reinfer.move.call_func|
has compile-profile|typecheck.reinfer.borrow.call_arg.calls|
has compile-profile|typecheck.body_fact.move.call_func.hits|
has compile-profile|typecheck.body_fact.move.call_func.misses|
has compile-profile|typecheck.body_fact.borrow.call_func.hits|
has compile-profile|typecheck.body_fact.borrow.call_func.misses|
ROWS
[ "$str_cat_arity_2_line" -lt "$str_cat_arity_6_line" ] ||
    fail "macro profile detail rows lost deterministic first-seen order"
# Direct capture owns one declared-parameter-sized operand array per call: at
# most 1.25 KiB per call.
DIRECT_MARSHAL_CALLS=$(profile_counter_value_in \
    "$CHECK_STDERR" \
    "typecheck.macro.walk_direct_marshal_calls")
DIRECT_MARSHAL_ALLOC_KB=$(profile_counter_value_in \
    "$CHECK_STDERR" \
    "typecheck.macro.walk_direct_marshal_alloc_kb")
if [ $((DIRECT_MARSHAL_ALLOC_KB * 4)) -gt $((DIRECT_MARSHAL_CALLS * 5)) ]; then
    show_failure_logs "$CHECK_STDOUT" "$CHECK_STDERR"
    fail "direct marshal storage exceeded 1.25 KiB per call: ${DIRECT_MARSHAL_ALLOC_KB} KiB / ${DIRECT_MARSHAL_CALLS} calls"
fi

echo "[compile-profile] verify embedded stdlib tlci routing and differential output"
mkdir -p "$STDLIB_TLCI_DIR"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$STDLIB_TLCI_EMBEDDED_STDOUT" 2> "$STDLIB_TLCI_EMBEDDED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_EMBEDDED_STDOUT" "$STDLIB_TLCI_EMBEDDED_STDERR"
    fail "embedded stdlib tlci routing fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_SOURCE_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root "$ROOT/stdlib"
) > "$STDLIB_TLCI_SOURCE_STDOUT" 2> "$STDLIB_TLCI_SOURCE_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_SOURCE_STDOUT" "$STDLIB_TLCI_SOURCE_STDERR"
    fail "source stdlib routing fixture compile failed"
fi
profile_rows "$STDLIB_TLCI_EMBEDDED_STDOUT" "$STDLIB_TLCI_EMBEDDED_STDERR" <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits >= 1
c typecheck.macro.stdlib_tlci_catalog_misses = 0
c typecheck.macro.stdlib_tlci_load_failures = 0
# With the fold bodies native, every cataloged macro in this fixture now
# commits natively; assert the dispatches instead of a fallback count.
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
ROWS
embedded_native_expr=$(profile_counter_value_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_expr_results")
embedded_direct_expr=$(profile_counter_value_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_direct_expr_results")
if [ "$embedded_direct_expr" -ne "$embedded_native_expr" ]; then
    fail "embedded expression commits bypassed direct capture: native=$embedded_native_expr direct=$embedded_direct_expr"
fi
# A pristine stdlib root is content-identical to the embedded payload, so
# the catalog dispatches for it too; the byte-parity requirement below is
# the contract that matters.
profile_rows "$STDLIB_TLCI_SOURCE_STDOUT" "$STDLIB_TLCI_SOURCE_STDERR" <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits >= 1
ROWS
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_SOURCE_ASM"; then
    diff -u "$STDLIB_TLCI_SOURCE_ASM" "$STDLIB_TLCI_EMBEDDED_ASM" >&2 || true
    fail "embedded and source stdlib routing changed generated assembly"
fi

# A modified stdlib root must keep every one of its modules on source
# interpretation (the catalog may never shadow user stdlib), and a
# comment-only modification must still produce byte-identical output.
echo "[compile-profile] verify modified stdlib root stands the catalog down"
STDLIB_TLCI_MODIFIED_DIR="$STDLIB_TLCI_DIR/modified-root"
STDLIB_TLCI_MODIFIED_ASM="$STDLIB_TLCI_DIR/modified.s"
STDLIB_TLCI_MODIFIED_STDOUT="$STDLIB_TLCI_DIR/modified.stdout"
STDLIB_TLCI_MODIFIED_STDERR="$STDLIB_TLCI_DIR/modified.stderr"
rm -rf "$STDLIB_TLCI_MODIFIED_DIR"
mkdir -p "$STDLIB_TLCI_MODIFIED_DIR/stdlib"
for f in "$ROOT"/stdlib/*.tl; do
    { cat "$f"; echo ";; provenance-control-comment"; } \
        > "$STDLIB_TLCI_MODIFIED_DIR/stdlib/$(basename "$f")"
done
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_MODIFIED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$STDLIB_TLCI_MODIFIED_STDOUT" 2> "$STDLIB_TLCI_MODIFIED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_MODIFIED_STDOUT" "$STDLIB_TLCI_MODIFIED_STDERR"
    fail "modified stdlib routing fixture compile failed"
fi
profile_rows "$STDLIB_TLCI_MODIFIED_STDOUT" "$STDLIB_TLCI_MODIFIED_STDERR" <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
c typecheck.macro.stdlib_source_interpreted >= 1
ROWS
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_MODIFIED_ASM"; then
    diff -u "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_MODIFIED_ASM" >&2 || true
    fail "comment-modified stdlib root changed generated assembly"
fi

# Route differentials: a fixture compiled through the embedded native catalog
# (from $STDLIB_TLCI_DIR) and through source interpretation of the
# comment-modified root must produce the same assembly, with the named macros
# on the native route; the image census alone cannot catch a callback that
# returns the wrong syntax. A route's outputs are
# $STDLIB_TLCI_DIR/LABEL-{embedded,interpreted}.{s,stdout,stderr}.

# route_run NAME DIR COMMAND SOURCE ARGS...: run the profile compiler's
# COMMAND on SOURCE from DIR (compile writes $STDLIB_TLCI_DIR/NAME.s); the
# status is left in route_status.
route_run() {
    _rr_out=$STDLIB_TLCI_DIR/$1
    _rr_dir=$2
    _rr_command=$3
    _rr_source=$4
    shift 4
    if [ "$_rr_command" = compile ]; then
        set -- -o "$_rr_out.s" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) "$@"
    fi
    set +e
    (cd "$_rr_dir" && "$PROFILE_BIN" "$_rr_command" "$_rr_source" "$@") \
        > "$_rr_out.stdout" 2> "$_rr_out.stderr"
    route_status=$?
    set -e
}

# route_pair LABEL SOURCE: both routes compile SOURCE to the same assembly.
route_pair() {
    for _rp_route in embedded interpreted; do
        if [ "$_rp_route" = embedded ]; then
            route_run "$1-embedded" "$STDLIB_TLCI_DIR" compile "$2"
        else
            route_run "$1-interpreted" "$STDLIB_TLCI_MODIFIED_DIR" compile "$2" --stdlib-root stdlib
        fi
        [ "$route_status" -eq 0 ] || {
            show_failure_logs "$STDLIB_TLCI_DIR/$1-$_rp_route.stdout" "$STDLIB_TLCI_DIR/$1-$_rp_route.stderr"
            fail "$_rp_route $1 fixture compile failed"
        }
    done
    if ! cmp -s "$STDLIB_TLCI_DIR/$1-embedded.s" "$STDLIB_TLCI_DIR/$1-interpreted.s"; then
        diff -u "$STDLIB_TLCI_DIR/$1-interpreted.s" "$STDLIB_TLCI_DIR/$1-embedded.s" >&2 || true
        fail "native and interpreted $1 expansions differ"
    fi
}

# route_rows LABEL ROUTE < ROWS: profile_rows over one route's stderr.
route_rows() {
    profile_rows "$STDLIB_TLCI_DIR/$1-$2.stdout" "$STDLIB_TLCI_DIR/$1-$2.stderr"
}

# route_reject LABEL SOURCE: both routes reject SOURCE under `check`; the
# diagnostics without profile rows are LABEL-{embedded,interpreted}.text.
route_reject() {
    route_run "$1-embedded" "$STDLIB_TLCI_DIR" check "$2"
    [ "$route_status" -ne 0 ] || fail "embedded route accepted rejected $1 fixture"
    route_run "$1-interpreted" "$STDLIB_TLCI_MODIFIED_DIR" check "$2" --stdlib-root stdlib
    [ "$route_status" -ne 0 ] || fail "interpreted route accepted rejected $1 fixture"
    for _rj_route in embedded interpreted; do
        grep -v 'compile-profile' "$STDLIB_TLCI_DIR/$1-$_rj_route.stderr" \
            > "$STDLIB_TLCI_DIR/$1-$_rj_route.text" || true
    done
}

# route_same LABEL SUFFIX: LABEL-embedded.SUFFIX and LABEL-interpreted.SUFFIX
# are identical.
route_same() {
    if ! cmp -s "$STDLIB_TLCI_DIR/$1-embedded.$2" "$STDLIB_TLCI_DIR/$1-interpreted.$2"; then
        diff -u "$STDLIB_TLCI_DIR/$1-interpreted.$2" "$STDLIB_TLCI_DIR/$1-embedded.$2" >&2 || true
        fail "native and interpreted $1 $2 differ"
    fi
}

# route_native_exit LABEL: the embedded route's program links and exits 42.
route_native_exit() {
    _rn=$STDLIB_TLCI_DIR/$1-embedded
    if ! assemble_and_link "$1-native" "$_rn.s" "$_rn.$NL_OBJ_EXT" "$_rn$NL_BIN_EXT" \
        >> "$_rn.stdout" 2>> "$_rn.stderr"; then
        show_failure_logs "$_rn.stdout" "$_rn.stderr"
        fail "native $1 fixture link failed"
    fi
    set +e
    "$_rn$NL_BIN_EXT" >> "$_rn.stdout" 2>> "$_rn.stderr"
    _rn_status=$?
    set -e
    [ "$_rn_status" -eq 42 ] || {
        show_failure_logs "$_rn.stdout" "$_rn.stderr"
        fail "native $1 fixture expected exit 42, got $_rn_status"
    }
}

# verify_residual_route LABEL SOURCE IDENTITY...: the route pair, with every
# IDENTITY expanded on the native route and no catalog miss.
verify_residual_route() {
    _vr_label=$1
    route_pair "$1" "$2"
    shift 2
    route_rows "$_vr_label" embedded <<'ROWS'
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
c typecheck.macro.stdlib_tlci_catalog_misses = 0
ROWS
    route_rows "$_vr_label" interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS
    for _vr_identity do
        printf 'has %s arity=\n' "$_vr_identity"
    done | route_rows "$_vr_label" embedded
}

echo "[compile-profile] verify for residual routing differential"
verify_residual_route for-residual "$ROOT/tests/integration/for_macro.tl" \
    stdlib.core_macros/for
# `for` validates the iterator protocol before it builds syntax.
route_reject for-diagnostic "$ROOT/stdlib/tests/core_macros_for_missing_protocol.tl"
profile_rows "$STDLIB_TLCI_DIR/for-diagnostic-embedded.stdout" "$STDLIB_TLCI_DIR/for-diagnostic-embedded.stderr" \
    "$STDLIB_TLCI_DIR/for-diagnostic-embedded.text" <<'ROWS'
has is missing protocol function
ROWS
route_same for-diagnostic text

echo "[compile-profile] verify vector residual routing differential"
verify_residual_route vector-full-residual "$ROOT/tests/integration/compile_profile_vector_full.tl" \
    stdlib.vector/vector
verify_residual_route vector-core-residual "$ROOT/tests/integration/compile_profile_vector_core.tl" \
    stdlib.vector/vector
# The borrowed TextBuf family is the production consumer of unresolved
# lifetime-parameterized nominal type templates.
verify_residual_route text-buf-borrowed-lifetime-residual "$ROOT/tests/integration/stdlib_text_buf.tl" \
    stdlib.text_buf_family/borrowed
# The module generator's malformed-capability diagnostic on both routes. Native
# callback diagnostics are anchored at the invocation; the interpreted route can
# keep a transformer-expression primary span, so the headlines must match and
# both must name the invocation.
route_reject vector-diagnostic "$ROOT/tests/safety/vector_invalid_capability_reject.tl"
for vector_route in embedded interpreted; do
    profile_rows "$STDLIB_TLCI_DIR/vector-diagnostic-$vector_route.stdout" \
        "$STDLIB_TLCI_DIR/vector-diagnostic-$vector_route.stderr" \
        "$STDLIB_TLCI_DIR/vector-diagnostic-$vector_route.text" <<'ROWS'
has vector: optional capability must be bare `core`
has in expansion of macro `stdlib.vector/vector` invoked here
ROWS
    head -n 1 "$STDLIB_TLCI_DIR/vector-diagnostic-$vector_route.text" \
        > "$STDLIB_TLCI_DIR/vector-diagnostic-$vector_route.headline"
done
route_same vector-diagnostic headline

echo "[compile-profile] verify json/serialize residual routing differential"
verify_residual_route serialize-json-residual "$ROOT/tests/integration/stdlib_serialize_json.tl" \
    stdlib.json/decode-int \
    stdlib.serialize/encode-value \
    stdlib.serialize/decode-value \
    stdlib.serialize/decode-field \
    stdlib.serialize/enum-source-import \
    stdlib.serialize/nested-import-for-type \
    stdlib.serialize/encode-tuple-elements \
    stdlib.serialize/decode-tuple-items \
    stdlib.serialize/encode-enum-payload-elements \
    stdlib.serialize/decode-enum-payload-items \
    stdlib.serialize/nested-imports-for-tuple \
    stdlib.serialize/nested-imports-for-enum-payloads

# Every operand-count arm of the public concatenator, with its runtime rows
# and no native-route fallback; the native result must also run.
echo "[compile-profile] verify public str-cat arity routing differential"
route_pair str-cat-arities "$ROOT/tests/integration/str_cat_native_arities.tl"
route_rows str-cat-arities embedded <<'ROWS'
has stdlib.str_cat/str-cat arity=0
has stdlib.str_cat_runtime/str-cat-scoped arity=0
has stdlib.str_cat/str-cat arity=1
has stdlib.str_cat_runtime/str-cat-scoped arity=1
has stdlib.str_cat/str-cat arity=2
has stdlib.str_cat_runtime/str-cat-scoped arity=2
has stdlib.str_cat/str-cat arity=5
has stdlib.str_cat_runtime/str-cat-scoped arity=5
has stdlib.str_cat/str-cat arity=6
has stdlib.str_cat_runtime/str-cat-scoped arity=6
has stdlib.str_cat/str-cat arity=8
has stdlib.str_cat_runtime/str-cat-scoped arity=8
has stdlib.str_cat_runtime/str-cat-pack arity=3
c typecheck.macro.stdlib_tlci_native_dispatches >= 6
c typecheck.macro.stdlib_tlci_catalog_misses = 0
c typecheck.macro.stdlib_tlci_load_failures = 0
c typecheck.macro.stdlib_tlci_interpreted_fallbacks = 0
ROWS
route_rows str-cat-arities interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS
route_native_exit str-cat-arities

# The scoped concatenator's fixed arities, by bytes and by behavior.
echo "[compile-profile] verify scoped str-cat routing differential"
route_pair scoped-cat "$ROOT/tests/integration/str_cat_scoped_region.tl"
route_rows scoped-cat embedded <<'ROWS'
has stdlib.str_cat_runtime/str-cat-scoped arity=2
has stdlib.str_cat_runtime/str-cat-scoped arity=3
has stdlib.str_cat_runtime/str-cat-scoped arity=4
has stdlib.str_cat_runtime/str-cat-scoped arity=5
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
c typecheck.macro.stdlib_tlci_interpreted_fallbacks = 0
ROWS
route_rows scoped-cat interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS
route_native_exit scoped-cat

# The template node kinds the json/serialize/text_buf/math hooks use: `return`,
# `box`/`deref`, dotted `set!` places and float literals inside quasiquotes.
# text_buf_family.owned commits a Decls result through the mapped image.
echo "[compile-profile] verify template node kind routing differential"
route_pair template-nodes "$ROOT/tests/integration/tlci_native_template_nodes.tl"
route_rows template-nodes embedded <<'ROWS'
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
has stdlib.text_buf/append! arity=2
c typecheck.macro.stdlib_tlci_interpreted_fallbacks = 0
c typecheck.macro.stdlib_tlci_native_decls_results >= 1
ROWS
route_rows template-nodes interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS

# The modified root reached by a non-`stdlib` path spelling, from a working
# directory without a `stdlib/` fallback, still typechecks the root's own
# modules against that root's core-macros prelude.
route_run pathroot "$STDLIB_TLCI_DIR" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
    --stdlib-root modified-root/stdlib
[ "$route_status" -eq 0 ] || {
    show_failure_logs "$STDLIB_TLCI_DIR/pathroot.stdout" "$STDLIB_TLCI_DIR/pathroot.stderr"
    fail "path-spelled modified stdlib root failed to typecheck"
}
profile_rows "$STDLIB_TLCI_DIR/pathroot.stdout" "$STDLIB_TLCI_DIR/pathroot.stderr" <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
c typecheck.macro.stdlib_source_interpreted >= 1
ROWS
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_DIR/pathroot.s"; then
    diff -u "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_DIR/pathroot.s" >&2 || true
    fail "path-spelled modified stdlib root changed generated assembly"
fi

# Index folds that stop early, repeat or reverse still compile and run; only a
# route differential catches them. Both folds must fire.
echo "[compile-profile] verify tlci index-fold route differential"
route_pair folds "$ROOT/tests/integration/tlci_native_index_folds.tl"
route_rows folds embedded <<'ROWS'
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
c typecheck.macro.stdlib_tlci_catalog_misses = 0
has stdlib.str_cat_runtime/str-cat-pack arity=3
has stdlib.fs/path-join-fold arity=3
ROWS
route_rows folds interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS

# Computed string-dispatch scrutinees pick an arm inside the native entry, so a
# wrong probe result silently selects another expansion.
echo "[compile-profile] verify computed scrutinee routing differential"
route_pair scrutinee "$ROOT/tests/integration/tlci_native_computed_scrutinee.tl"
route_rows scrutinee embedded <<'ROWS'
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
ROWS
route_rows scrutinee interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS

# Definition-site aliases retained only in a lazy surface summary must survive
# another import loading the shared dependency first (json-first is the
# failure ordering).
echo "[compile-profile] verify lazy macro definition import order"
for import_order in repro format_first; do
    route_run "import-order-$import_order" "$STDLIB_TLCI_DIR" compile \
        "$ROOT/tests/integration/macro_import_order_$import_order.tl"
    [ "$route_status" -eq 0 ] || {
        show_failure_logs "$STDLIB_TLCI_DIR/import-order-$import_order.stdout" \
            "$STDLIB_TLCI_DIR/import-order-$import_order.stderr"
        fail "lazy macro definition import-order fixture $import_order failed"
    }
done
if ! cmp -s "$STDLIB_TLCI_DIR/import-order-repro.s" "$STDLIB_TLCI_DIR/import-order-format_first.s"; then
    diff -u "$STDLIB_TLCI_DIR/import-order-format_first.s" "$STDLIB_TLCI_DIR/import-order-repro.s" >&2 || true
    fail "import order changed lazy macro definition-context assembly"
fi

# `stdlib.hash/hash` generates its module in the wildcard arm of a type-kind
# match; a wrong module name or dropped declaration still compiles and runs.
# It is a real source-lowered Module result.
echo "[compile-profile] verify tlci wildcard-arm route differential"
route_pair wildcard "$ROOT/tests/integration/tlci_native_wildcard_arms.tl"
route_rows wildcard embedded <<'ROWS'
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
c typecheck.macro.stdlib_tlci_native_module_results >= 1
has stdlib.hash/hash arity=1
has stdlib.hash/inline-hash arity=2
has stdlib.eq/inline-eq arity=3
ROWS
route_rows wildcard interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS

# `stdlib.format/format` scans the template at comptime, then `format-expand`
# and `format-expand-call` bind the plan; an off-by-one still compiles and runs.
echo "[compile-profile] verify tlci format-scanner route differential"
route_pair format "$ROOT/tests/integration/tlci_native_format_scanner.tl"
route_rows format embedded <<'ROWS'
c typecheck.macro.stdlib_tlci_native_dispatches >= 1
has stdlib.format/format arity=
has stdlib.format/format-expand arity=
has stdlib.format/format-expand-call arity=
ROWS
route_rows format interpreted <<'ROWS'
c typecheck.macro.stdlib_tlci_catalog_hits = 0
ROWS

# The scanner's rejection paths are reported by the macro itself; compare the
# rendered diagnostics, not just the exit status.
echo "[compile-profile] verify tlci format-scanner diagnostic differential"
FMT_DIAG_DIR="$STDLIB_TLCI_DIR/format-diagnostics"
rm -rf "$FMT_DIAG_DIR"
mkdir -p "$FMT_DIAG_DIR"
cat > "$FMT_DIAG_DIR/unmatched-open.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define (main) : i64
  (begin (io.print-format "{}" (format.format "a{")) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/too-few-arguments.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define one : i64 1)
(define (main) : i64
  (begin (io.print-format "{}" (format.format "{} {}" one)) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/too-many-arguments.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define one : i64 1)
(define two : i64 2)
(define (main) : i64
  (begin (io.print-format "{}" (format.format "{}" one two)) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/unmatched-close.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define (main) : i64
  (begin (io.print-format "{}" (format.format "a}b")) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/non-literal-template.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define template : String "{}")
(define (main) : i64
  (begin (io.print-format "{}" (format.format template 1)) 0))
FIXTURE
for fmt_case in unmatched-open too-few-arguments too-many-arguments \
    unmatched-close non-literal-template; do
    route_reject "format-$fmt_case" "$FMT_DIAG_DIR/$fmt_case.tl"
    grep -q 'format: ' "$STDLIB_TLCI_DIR/format-$fmt_case-embedded.text" || {
        show_failure_logs "$STDLIB_TLCI_DIR/format-$fmt_case-embedded.stdout" \
            "$STDLIB_TLCI_DIR/format-$fmt_case-embedded.text"
        fail "embedded route reported no format diagnostic for $fmt_case"
    }
    route_same "format-$fmt_case" text
done

echo "[compile-profile] compare compact and full canonical vector modules"
run_logged "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR" "profiled compact vector fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_vector_core.tl \
    --stdlib-root . --stdlib-root stdlib
run_logged "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR" "profiled full vector fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_vector_full.tl \
    --stdlib-root . --stdlib-root stdlib

profile_rows "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR" <<'ROWS'
has stdlib.vector/vector arity=2 calls=1
ROWS
profile_rows "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR" <<'ROWS'
has stdlib.vector/vector arity=1 calls=1
ROWS

VECTOR_CORE_MACRO_ALLOC=$(awk -F'|' \
    '$1 == "compile-profile" && $2 == "typecheck.macro_walk" { print $4 }' \
    "$VECTOR_CORE_STDERR")
VECTOR_FULL_MACRO_ALLOC=$(awk -F'|' \
    '$1 == "compile-profile" && $2 == "typecheck.macro_walk" { print $4 }' \
    "$VECTOR_FULL_STDERR")
case "$VECTOR_CORE_MACRO_ALLOC:$VECTOR_FULL_MACRO_ALLOC" in
    *[!0-9:]* | :* | *:)
        show_failure_logs "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR"
        show_failure_logs "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR"
        fail "could not parse vector macro-walk allocation counters"
        ;;
esac
VECTOR_MACRO_ALLOC_SAVINGS=$((VECTOR_FULL_MACRO_ALLOC - VECTOR_CORE_MACRO_ALLOC))
if [ "$VECTOR_MACRO_ALLOC_SAVINGS" -lt 250000 ]; then
    show_failure_logs "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR"
    show_failure_logs "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR"
    fail "compact vector macro-walk savings regressed: core=$VECTOR_CORE_MACRO_ALLOC full=$VECTOR_FULL_MACRO_ALLOC savings=$VECTOR_MACRO_ALLOC_SAVINGS"
fi
echo "[compile-profile] vector macro-walk allocation core=$VECTOR_CORE_MACRO_ALLOC full=$VECTOR_FULL_MACRO_ALLOC savings=$VECTOR_MACRO_ALLOC_SAVINGS"

echo "[compile-profile] compare one and five compact vector identities"
run_logged "$VECTOR_ONE_STDOUT" "$VECTOR_ONE_STDERR" "profiled one-vector fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/compile_profile_vector_one_core.tl \
    -o "$VECTOR_ONE_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root . --stdlib-root stdlib --opt-level 1
run_logged "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR" "profiled five-vector fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/compile_profile_vector_five_core.tl \
    -o "$VECTOR_FIVE_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root . --stdlib-root stdlib --opt-level 1

profile_rows "$VECTOR_ONE_STDOUT" "$VECTOR_ONE_STDERR" <<'ROWS'
c typecheck.macro.generated_module_materializations = 1
c typecheck.macro.generated_module_memo_hits = 0
# Every generated vector identity checks all fifteen generated declarations,
# including the two public place macros.
c typecheck.macro.generated_decl_checks = 15
ROWS
profile_rows "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR" <<'ROWS'
c typecheck.macro.generated_module_materializations = 5
c typecheck.macro.generated_module_memo_hits = 0
c typecheck.macro.generated_decl_checks = 75
# The initial table build is the only whole-program symbol/registry build;
# every generated vector module extends the live tables at their logical end.
c typecheck.macro.live_rebuilds = 1
c typecheck.macro.live_reuses = 5
c typecheck.macro.live_registry_reuses = 5
ROWS
VECTOR_ONE_DECL_CHECKS=$(profile_counter_value_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_decl_checks")
VECTOR_FIVE_DECL_CHECKS=$(profile_counter_value_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_decl_checks")

# Generated vector Modules and their marker imports are append-only. They split
# the active segment and publish declaration deltas, but must never request an
# intermediate whole-program view.
assert_segmented_program_view_in \
    "$VECTOR_ONE_STDERR" \
    "$VECTOR_ONE_STDOUT" \
    "$VECTOR_ONE_STDERR"
assert_segmented_program_view_in \
    "$VECTOR_FIVE_STDERR" \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"
profile_rows "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR" <<'ROWS'
c typecheck.macro.walk_segment_fallback_flattens = 0
c typecheck.macro.walk_segment_splits >= 5
c typecheck.macro.walk_segment_delta_decls >= 5
ROWS

for counter in \
    checked_program.pre_decls.functions \
    checked_program.reachable.decls \
    checked_program.reachable.functions \
    ir.after_decls.functions \
    ir.after_decls.blocks \
    ir.after_decls.instructions; do
    one_value=$(profile_live_counter_value_in \
        "$VECTOR_ONE_STDERR" \
        "lower.$counter")
    five_value=$(profile_live_counter_value_in \
        "$VECTOR_FIVE_STDERR" \
        "lower.$counter")
    if [ "$one_value" -le 0 ] || [ "$five_value" -le "$one_value" ]; then
        show_failure_logs "$VECTOR_ONE_STDOUT" "$VECTOR_ONE_STDERR"
        show_failure_logs "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR"
        fail "profile counter lower.$counter did not grow from one to five identities: one=$one_value five=$five_value"
    fi
done

echo "[compile-profile] compact vector identity counters generated_decl_checks=$VECTOR_ONE_DECL_CHECKS/$VECTOR_FIVE_DECL_CHECKS"

echo "[compile-profile] check generated import fixture"
run_logged "$GEN_IMPORT_STDOUT" "$GEN_IMPORT_STDERR" "profiled generated import fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_generated_import.tl \
    --stdlib-root . --stdlib-root stdlib
assert_segmented_program_view_in \
    "$GEN_IMPORT_STDERR" \
    "$GEN_IMPORT_STDOUT" \
    "$GEN_IMPORT_STDERR"

# The generated module imports stdlib.string; the single demand-driven pass
# loads and forces that file import inline.
profile_rows "$GEN_IMPORT_STDOUT" "$GEN_IMPORT_STDERR" <<'ROWS'
lacks typecheck.macro.fixed_point_
has compile-profile|typecheck.macro_scratch_release|
ROWS

echo "[compile-profile] check additive CTFE splice fixture"
run_logged "$CTFE_SPLICE_STDOUT" "$CTFE_SPLICE_STDERR" "profiled additive CTFE splice fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_ctfe_splice_delta.tl \
    --stdlib-root . --stdlib-root stdlib
assert_segmented_program_view_in \
    "$CTFE_SPLICE_STDERR" \
    "$CTFE_SPLICE_STDOUT" \
    "$CTFE_SPLICE_STDERR"

# Fresh ordinary/module/file nominals remain visible to later reflection. The
# fixture also forces vector growth and one first-wins collision: every clear
# has a measured rebuild, and capacity never makes the cache unavailable.
# Top-env maintenance follows the same additive splice contract.
profile_rows "$CTFE_SPLICE_STDOUT" "$CTFE_SPLICE_STDERR" <<'ROWS'
sum typecheck.macro.walk_splice_ctfe_builds = typecheck.macro.walk_splice_ctfe_rebuilds + 1
sum typecheck.macro.walk_splice_ctfe_rebuilds = typecheck.macro.walk_splice_ctfe_cleared
c typecheck.macro.walk_splice_ctfe_extensions >= 1
c typecheck.macro.walk_splice_ctfe_semantic_rejections >= 1
c typecheck.macro.walk_splice_ctfe_capacity_grows >= 1
c typecheck.macro.walk_splice_ctfe_cache_unavailable = 0
c typecheck.macro.walk_splice_env_reresolve_calls >= 1
c typecheck.macro.walk_splice_env_reresolve_candidates >= 1
c typecheck.macro.walk_splice_env_fallbacks = 0
ROWS

echo "[compile-profile] check generated result import fixture"
run_logged "$RESULT_IMPORT_STDOUT" "$RESULT_IMPORT_STDERR" "profiled generated result import fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_result_import.tl \
    --stdlib-root . --stdlib-root stdlib

profile_rows "$RESULT_IMPORT_STDOUT" "$RESULT_IMPORT_STDERR" <<'ROWS'
has stdlib.result/result arity=2 calls=1
lacks typecheck.macro.fixed_point_
ROWS

echo "[compile-profile] check cross-file single-compilation fixture"
run_logged "$CROSS_SINGLE_STDOUT" "$CROSS_SINGLE_STDERR" "profiled cross-file single-compilation fixture check failed" \
    "$PROFILE_BIN" check \
    tests/integration/compile_profile_cross_file_single_compilation.tl --stdlib-root . \
    --stdlib-root stdlib

# Three modules import the same (vector i64) instantiation: the program-global
# memo materializes it once, so the two later importers are memo hits. Vector
# contains uses the shared generated equality module, so exactly two identities
# are materialized. The vector catalog is materialized in full, so the
# partial-catalog shadow-validation counter stays zero.
profile_rows "$CROSS_SINGLE_STDOUT" "$CROSS_SINGLE_STDERR" <<'ROWS'
c typecheck.macro.generated_module_memo_hits = 2
c typecheck.macro.generated_module_materializations = 2
c typecheck.macro.generated_module_catalog_builds = 2
c typecheck.macro.generated_module_catalog_hits = 2
c typecheck.macro.generated_module_catalog_validations = 0
ROWS
CROSS_SINGLE_DECL_CHECKS=$(profile_counter_value_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_decl_checks")
if [ "$CROSS_SINGLE_DECL_CHECKS" -le 0 ]; then
    show_failure_logs "$CROSS_SINGLE_STDOUT" "$CROSS_SINGLE_STDERR"
    fail "repeated generated identity emitted no generated declaration checks"
fi

echo "[compile-profile] check inert generated import fixture"
run_logged "$GEN_IMPORT_INERT_STDOUT" "$GEN_IMPORT_INERT_STDERR" "profiled inert generated import fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_generated_import_inert.tl \
    --stdlib-root . --stdlib-root stdlib

# The generated module imports a source file by path; the single
# demand-driven pass loads it inline.
profile_rows "$GEN_IMPORT_INERT_STDOUT" "$GEN_IMPORT_INERT_STDERR" <<'ROWS'
lacks typecheck.macro.fixed_point_
ROWS

echo "[compile-profile] check generated module replay lazy fixture"
run_logged "$REPLAY_STDOUT" "$REPLAY_STDERR" "profiled generated replay fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_generated_replay_lazy.tl \
    --stdlib-root . --stdlib-root stdlib

profile_rows "$REPLAY_STDOUT" "$REPLAY_STDERR" <<'ROWS'
has compile-profile-detail|typecheck.macro_expand|
# A memoized module is never re-expanded: the repeated import is a memo hit of
# the single demand-driven walk.
has compile-profile|typecheck.macro.generated_module_memo_hits|
lacks typecheck.macro.fixed_point_
c typecheck.macro.generated_module_memo_hits >= 1
# Local generated-import worklist processing and generated-identity shortcuts can
# reduce these detail rows; keep upper bounds to guard against re-expanding the
# repeated replay import.
lines<= 2 profile-replay-user arity=1 calls=1
lines<= 2 profile-replay-nested arity=2 calls=1
# The repeated profile-replay-user import is structurally identical. It must not
# add another whole-program macro setup/walk pass just to discover no new work.
# Keep this as an upper bound so future local-worklist fixes can reduce it.
lines<= 7 compile-profile|typecheck.macro_setup|
lines<= 7 compile-profile|typecheck.macro_walk|
ROWS

echo "[compile-profile] check layout/spec counter fixture"
run_logged "$LAYOUT_STDOUT" "$LAYOUT_STDERR" "profiled layout/spec fixture check failed" \
    "$PROFILE_BIN" check tests/integration/compile_profile_layout_spec.tl \
    --stdlib-root . --stdlib-root stdlib

profile_rows "$LAYOUT_STDOUT" "$LAYOUT_STDERR" <<'ROWS'
has compile-profile|typecheck.layout.repr_c_field_builds|
has compile-profile|typecheck.layout.repr_c_field_visits|
has compile-profile|typecheck.layout.inline_field_builds|
has compile-profile|typecheck.layout.inline_field_visits|
has compile-profile|typecheck.layout.inline_payload_builds|
has compile-profile|typecheck.layout.inline_payload_visits|
has compile-profile|typecheck.layout.inline_variant_builds|
has compile-profile|typecheck.layout.inline_variant_visits|
has compile-profile|typecheck.layout.stdlib_field_spec_builds|
has compile-profile|typecheck.layout.stdlib_field_spec_visits|
has compile-profile|typecheck.layout.stdlib_variant_spec_builds|
has compile-profile|typecheck.layout.stdlib_variant_spec_visits|
has compile-profile|typecheck.layout.cache_hits|
has compile-profile|typecheck.layout.cache_misses|
has compile-profile|typecheck.layout.cache_bypasses|
ROWS

echo "[compile-profile] compile optimizer escape fixture"
run_logged "$OPT_STDOUT" "$OPT_STDERR" "profiled optimized fixture compile failed" \
    "$PROFILE_BIN" compile tests/integration/compile_profile_optimizer_escape.tl \
    -o "$OPT_ASM" --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root . --stdlib-root stdlib --opt-level 1

profile_rows "$OPT_STDOUT" "$OPT_STDERR" <<'ROWS'
has compile-profile|optimize.functions|
has compile-profile|optimize.load_cse.max_table_size|
has compile-profile|optimize.load_cse.max_kinds_size|
has compile-profile|optimize.load_cse.table_cap_hits|
has compile-profile|optimize.load_cse.kinds_cap_hits|
has compile-profile|optimize.load_cse.field_key_drops|
has compile-profile-detail|optimize.escape.body|
has compile-profile-detail|optimize.escape.dce_escape|
has compile-profile-detail|optimize.escape.restore|
has |1|main
has compile-profile|lower.ast_expr_pool.macro_expand.len|
has compile-profile|lower.ast_expr_pool.macro_expand.capacity|
has compile-profile|lower.ast_type_pool.macro_expand.len|
has compile-profile|lower.ast_type_pool.macro_expand.capacity|
has compile-profile|lower.ast_expr_pool.typecheck.len|
has compile-profile|lower.ast_expr_pool.typecheck.capacity|
has compile-profile|lower.ast_type_pool.typecheck.len|
has compile-profile|lower.ast_type_pool.typecheck.capacity|
has compile-profile|lower.ast_expr_pool.pre_decls.len|
has compile-profile|lower.ast_expr_pool.pre_decls.capacity|
has compile-profile|lower.ast_type_pool.pre_decls.len|
has compile-profile|lower.ast_type_pool.pre_decls.capacity|
has compile-profile|lower.checked_program.pre_decls.decls|
has compile-profile|lower.checked_program.pre_decls.functions|
has compile-profile|lower.checked_program.reachable.decls|
has compile-profile|lower.checked_program.reachable.functions|
has compile-profile|lower.ir.after_decls.functions|
has compile-profile|lower.ir.after_decls.blocks|
has compile-profile|lower.ir.after_decls.instructions|
has compile-profile|lower.ir_arena.after_decls.active|
has compile-profile|lower.name_env.binds|
has compile-profile|lower.name_env.lookups|
has compile-profile|lower.name_env.lookup_steps|
has compile-profile|lower.name_env.stores|
has compile-profile|lower.name_env.store_grows|
has compile-profile|lower.name_env.materializations|
has compile-profile|lower.name_env.materialized_entries|
has compile-profile|lower.name_cache.builds|
has compile-profile|lower.name_cache.entries|
has compile-profile|lower.name_cache.lookups|
has compile-profile|lower.name_cache.local_hits|
has compile-profile|lower.name_cache.local_misses|
has compile-profile|lower.module_name_cache.lookups|
has compile-profile|lower.module_name_cache.hits|
has compile-profile|lower.module_name_cache.entries|
has compile-profile|lower.module_local_view.lookups|
has compile-profile|lower.module_local_view.hits|
has compile-profile|lower.module_local_view.entries|
ROWS

echo "[compile-profile] scan scratch allocation regression"
"$COMPILER" test src/tests/scan_storage_growth.tl \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --cfg compile-profile --opt-level 2 --stdlib-root stdlib --stdlib-root src

echo "[compile-profile] ok"
