#!/usr/bin/env sh
set -eu

# Compact cross-cutting semantic/ABI differential (#7064).
#
# The expensive producer gates remain authoritative and exhaustive. This gate
# consumes their checked artifacts through one manifest and one observation
# oracle. Only the previous/successor compiler row emits new code, and it
# reuses the two compiler binaries produced by the same bootstrap run.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MANIFEST="$ROOT/tests/cross-mode/corpus.tsv"
WORKDIR="$ROOT/target/cross-mode-differential"
SELF_TEST=0
CASE_FILTER=

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-cross-mode-differential.sh [--case NAME]
       scripts/verify-cross-mode-differential.sh --self-test

Consumes artifacts left by the required integration, bootstrap, TLCI, SPMD,
and Windows COFF gates and compares their canonical observations. The normal
CI invocation supplies TYPELISP_BIN (successor) and
TYPELISP_CROSS_MODE_PREVIOUS_COMPILER (previous stage).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            [ "$#" -ge 2 ] || {
                usage
                exit 2
            }
            CASE_FILTER=$2
            shift
            ;;
        --self-test)
            SELF_TEST=1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
    shift
done

if [ "$SELF_TEST" -eq 1 ] && [ -n "$CASE_FILTER" ]; then
    usage
    exit 2
fi

fail() {
    echo "[cross-mode] FAIL: $*" >&2
    exit 1
}

[ -f "$MANIFEST" ] || fail "manifest is missing: $MANIFEST"

validate_manifest() {
    awk -F '\t' '
        function fail(message) {
            print "[cross-mode] manifest: " message > "/dev/stderr"
            invalid = 1
        }
        function valid_descriptor(value) {
            return value ~ /^(integration|stage|tlci|tlci-diagnostic|spmd|coff|expected):[A-Za-z0-9_.:\/-]+$/
        }
        function valid_metadata(value, count, item, i) {
            count = split(value, item, ",")
            if (count == 0) return 0
            for (i = 1; i <= count; i += 1) {
                if (item[i] !~ /^[a-z][a-z0-9-]*=[A-Za-z0-9_.-]+$/) return 0
            }
            return 1
        }
        NR == 1 {
            expected = "case\taxis\thosts\tapplicability\treference\tcandidate\tobservations\treference_metadata\tcandidate_metadata\tproducer\tnotes"
            if ($0 != expected) fail("invalid header")
            next
        }
        {
            sub(/\r$/, "", $0)
            if (NF != 11) {
                fail("line " NR " has " NF " fields; expected 11")
                next
            }
            if ($1 !~ /^[a-z0-9][a-z0-9-]*$/) fail("invalid case at line " NR ": " $1)
            if (seen[$1]++) fail("duplicate case: " $1)
            if ($2 !~ /^(opt-level|call-route|compiler-stage|comptime-route|backend-mode|emission|target)$/)
                fail("invalid axis for " $1 ": " $2)
            axes[$2] = 1
            if ($3 !~ /^(all|linux|windows)$/) fail("invalid hosts for " $1 ": " $3)
            if ($4 !~ /^(required|isa-avx2|isa-avx512)$/)
                fail("invalid applicability for " $1 ": " $4)
            if (!valid_descriptor($5)) fail("invalid reference descriptor for " $1 ": " $5)
            if (!valid_descriptor($6)) fail("invalid candidate descriptor for " $1 ": " $6)
            count = split($7, observations, ",")
            delete observation_seen
            for (i = 1; i <= count; i += 1) {
                observation = observations[i]
                if (observation !~ /^(exit|stdout|stderr|artifact|diagnostic)$/)
                    fail("invalid observation for " $1 ": " observation)
                if (observation_seen[observation]++)
                    fail("duplicate observation for " $1 ": " observation)
            }
            if (!valid_metadata($8)) fail("invalid reference metadata for " $1 ": " $8)
            if (!valid_metadata($9)) fail("invalid candidate metadata for " $1 ": " $9)
            if ($10 !~ /^scripts\/[A-Za-z0-9_.-]+\.sh$/)
                fail("invalid producer for " $1 ": " $10)
            if ($11 == "") fail("empty notes for " $1)
            rows += 1
        }
        END {
            required_axes[1] = "opt-level"
            required_axes[2] = "call-route"
            required_axes[3] = "compiler-stage"
            required_axes[4] = "comptime-route"
            required_axes[5] = "backend-mode"
            required_axes[6] = "emission"
            required_axes[7] = "target"
            for (i = 1; i <= 7; i += 1) {
                if (!(required_axes[i] in axes)) fail("missing axis: " required_axes[i])
            }
            if (rows == 0) fail("manifest has no cases")
            if (invalid) exit 1
        }
    ' "$MANIFEST"
}

validate_manifest || exit 1

if [ -n "$CASE_FILTER" ]; then
    awk -F '\t' -v wanted="$CASE_FILTER" 'NR > 1 && $1 == wanted { found = 1 }
        END { exit found ? 0 : 1 }' "$MANIFEST" ||
        fail "unknown manifest case: $CASE_FILTER"
fi

hash_file() {
    _cm_hash_file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_cm_hash_file" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$_cm_hash_file" | awk '{ print $1 }'
    else
        fail "sha256sum or shasum is required"
    fi
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

metadata_add() {
    _cm_metadata_dir=$1
    _cm_metadata_value=$2
    printf '%s\n' "$_cm_metadata_value" >> "$_cm_metadata_dir/metadata"
}

finalize_observation() {
    _cm_finalize_dir=$1
    _cm_canonical="$_cm_finalize_dir/canonical.tsv"
    : > "$_cm_canonical"
    for _cm_field in exit stdout stderr diagnostic artifact; do
        _cm_value_file="$_cm_finalize_dir/$_cm_field"
        [ -f "$_cm_value_file" ] || continue
        if [ "$_cm_field" = exit ]; then
            _cm_value=$(tr -d '\r\n' < "$_cm_value_file")
            case "$_cm_value" in
                "" | *[!0-9-]*) fail "invalid canonical exit value: $_cm_value_file" ;;
            esac
            printf 'exit\t%s\n' "$_cm_value" >> "$_cm_canonical"
        else
            printf '%s-sha256\t%s\n' \
                "$_cm_field" "$(hash_file "$_cm_value_file")" \
                >> "$_cm_canonical"
        fi
    done
    if [ -f "$_cm_finalize_dir/metadata" ]; then
        LC_ALL=C sort -u "$_cm_finalize_dir/metadata" |
            while IFS= read -r _cm_metadata_line; do
                printf 'metadata\t%s\n' "$_cm_metadata_line"
            done >> "$_cm_canonical"
    fi
}

run_program_observation() {
    _cm_run_binary=$1
    _cm_run_dir=$2
    [ -f "$_cm_run_binary" ] || fail "native artifact is missing: $_cm_run_binary"
    if [ ! -x "$_cm_run_binary" ]; then
        chmod +x "$_cm_run_binary" 2>/dev/null || true
    fi
    [ -x "$_cm_run_binary" ] || fail "native artifact is not executable: $_cm_run_binary"
    : > "$_cm_run_dir/stdout"
    : > "$_cm_run_dir/stderr"
    set +e
    "$_cm_run_binary" > "$_cm_run_dir/stdout" 2> "$_cm_run_dir/stderr"
    _cm_run_status=$?
    set -e
    printf '%s\n' "$_cm_run_status" > "$_cm_run_dir/exit"
}

resolve_integration_observation() {
    _cm_integration_name=$1
    _cm_integration_dir=$2
    _cm_integration_base="$ROOT/target/integration-verify/$HOST_OS/$_cm_integration_name/$_cm_integration_name"
    if [ "$HOST_OS" = windows ]; then
        _cm_integration_binary="$_cm_integration_base.exe"
    else
        _cm_integration_binary=$_cm_integration_base
    fi
    run_program_observation "$_cm_integration_binary" "$_cm_integration_dir"
    case "$_cm_integration_name" in
        backend-cmp-mem-fold-parity-opt0)
            metadata_add "$_cm_integration_dir" opt-level=0
            metadata_add "$_cm_integration_dir" emission=assembly
            metadata_add "$_cm_integration_dir" execution=native
            ;;
        backend-cmp-mem-fold-parity-opt2)
            metadata_add "$_cm_integration_dir" opt-level=2
            metadata_add "$_cm_integration_dir" emission=assembly
            metadata_add "$_cm_integration_dir" execution=native
            ;;
        cross_mode_internal_color)
            metadata_add "$_cm_integration_dir" call-route=internal
            metadata_add "$_cm_integration_dir" target=current
            metadata_add "$_cm_integration_dir" "target-host=$HOST_OS"
            ;;
        c_abi_aggregate_color)
            metadata_add "$_cm_integration_dir" call-route=c-abi
            metadata_add "$_cm_integration_dir" "target-host=$HOST_OS"
            ;;
        *)
            fail "unclassified integration artifact: $_cm_integration_name"
            ;;
    esac
}

compiler_for_stage() {
    _cm_stage=$1
    case "$_cm_stage" in
        previous)
            _cm_stage_compiler=${TYPELISP_CROSS_MODE_PREVIOUS_COMPILER:-}
            if [ -z "$_cm_stage_compiler" ] &&
                [ -s "$ROOT/target/ci-verify-stage1.path" ]; then
                _cm_stage_compiler=$(sed -n '1p' "$ROOT/target/ci-verify-stage1.path")
            fi
            ;;
        successor)
            _cm_stage_compiler=${TYPELISP_BIN:-}
            if [ -z "$_cm_stage_compiler" ] &&
                [ -s "$ROOT/target/ci-verify-stage2.path" ]; then
                _cm_stage_compiler=$(sed -n '1p' "$ROOT/target/ci-verify-stage2.path")
            fi
            ;;
        *) fail "unknown compiler stage: $_cm_stage" ;;
    esac
    [ -n "$_cm_stage_compiler" ] ||
        fail "same-run $_cm_stage compiler handoff is missing"
    case "$_cm_stage_compiler" in
        /* | [A-Za-z]:[/\\]*) ;;
        *) _cm_stage_compiler="$ROOT/$_cm_stage_compiler" ;;
    esac
    [ -x "$_cm_stage_compiler" ] ||
        fail "$_cm_stage compiler is not executable: $_cm_stage_compiler"
    printf '%s\n' "$_cm_stage_compiler"
}

resolve_stage_observation() {
    _cm_stage_name=$1
    _cm_stage_dir=$2
    _cm_stage_compiler=$(compiler_for_stage "$_cm_stage_name")
    _cm_stage_asm="$_cm_stage_dir/color.s"
    _cm_stage_obj="$_cm_stage_dir/color.$NL_OBJ_EXT"
    _cm_stage_binary="$_cm_stage_dir/color$NL_BIN_EXT"
    _cm_stage_compile_stdout="$_cm_stage_dir/compile.stdout"
    _cm_stage_compile_stderr="$_cm_stage_dir/compile.stderr"
    _cm_stage_source="$ROOT/tests/integration/cross_mode_internal_color.tl"

    set +e
    if [ "$HOST_OS" = windows ]; then
        "$_cm_stage_compiler" compile "$_cm_stage_source" \
            --target windows-x86_64 \
            --cfg windows \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src" \
            -o "$_cm_stage_asm" \
            > "$_cm_stage_compile_stdout" \
            2> "$_cm_stage_compile_stderr"
    else
        "$_cm_stage_compiler" compile "$_cm_stage_source" \
            --target linux-x86_64 \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src" \
            -o "$_cm_stage_asm" \
            > "$_cm_stage_compile_stdout" \
            2> "$_cm_stage_compile_stderr"
    fi
    _cm_stage_compile_status=$?
    set -e
    if [ "$_cm_stage_compile_status" -ne 0 ] || [ ! -s "$_cm_stage_asm" ]; then
        echo "[cross-mode] $_cm_stage_name compile stdout:" >&2
        sed 's/^/  /' "$_cm_stage_compile_stdout" >&2 || true
        echo "[cross-mode] $_cm_stage_name compile stderr:" >&2
        sed 's/^/  /' "$_cm_stage_compile_stderr" >&2 || true
        fail "$_cm_stage_name compiler could not emit the stage witness"
    fi
    if ! assemble_and_link \
        "cross-mode-$_cm_stage_name" \
        "$_cm_stage_asm" \
        "$_cm_stage_obj" \
        "$_cm_stage_binary" \
        > "$_cm_stage_dir/link.stdout" \
        2> "$_cm_stage_dir/link.stderr"; then
        sed 's/^/  /' "$_cm_stage_dir/link.stdout" >&2 || true
        sed 's/^/  /' "$_cm_stage_dir/link.stderr" >&2 || true
        fail "$_cm_stage_name compiler witness did not link"
    fi
    run_program_observation "$_cm_stage_binary" "$_cm_stage_dir"
    metadata_add "$_cm_stage_dir" "compiler-stage=$_cm_stage_name"
    metadata_add "$_cm_stage_dir" emission=assembly
    metadata_add "$_cm_stage_dir" execution=native
}

resolve_tlci_observation() {
    _cm_tlci_spec=$1
    _cm_tlci_dir=$2
    _cm_tlci_route=${_cm_tlci_spec%%:*}
    _cm_tlci_index=${_cm_tlci_spec#*:}
    case "$_cm_tlci_route" in
        native) _cm_tlci_artifact_route=default ;;
        source) _cm_tlci_artifact_route=source ;;
        *) fail "unknown TLCI route: $_cm_tlci_route" ;;
    esac
    _cm_tlci_root="$ROOT/target/stdlib-tlci-identity-differential/$HOST_OS"
    _cm_tlci_asm="$_cm_tlci_root/$_cm_tlci_artifact_route/$_cm_tlci_index.s"
    _cm_tlci_log="$_cm_tlci_root/$_cm_tlci_artifact_route.stderr"
    [ -s "$_cm_tlci_asm" ] || fail "TLCI artifact is missing: $_cm_tlci_asm"
    [ -s "$_cm_tlci_log" ] || fail "TLCI route evidence is missing: $_cm_tlci_log"
    grep -F "tlci-identity-route|$_cm_tlci_route|" "$_cm_tlci_log" >/dev/null ||
        fail "TLCI artifact lacks $_cm_tlci_route route evidence"
    grep -F 'stdlib.clone/clone-fixed-array' "$_cm_tlci_log" >/dev/null ||
        fail "TLCI artifact lacks the manifest row-zero identity evidence"
    cp "$_cm_tlci_asm" "$_cm_tlci_dir/artifact"
    metadata_add "$_cm_tlci_dir" "comptime-route=$_cm_tlci_route"
}

resolve_tlci_diagnostic_observation() {
    _cm_diag_spec=$1
    _cm_diag_dir=$2
    _cm_diag_route=${_cm_diag_spec%%:*}
    _cm_diag_case=${_cm_diag_spec#*:}
    _cm_diag_root="$ROOT/target/stdlib-tlci-identity-differential/$HOST_OS/failures"
    _cm_diag_file="$_cm_diag_root/$_cm_diag_case.$_cm_diag_route.diag"
    _cm_diag_log="$_cm_diag_root/$_cm_diag_case.$_cm_diag_route.stderr"
    [ -s "$_cm_diag_file" ] || fail "TLCI normalized diagnostic is missing: $_cm_diag_file"
    [ -s "$_cm_diag_log" ] || fail "TLCI diagnostic route evidence is missing: $_cm_diag_log"
    grep -F "tlci-identity-route|$_cm_diag_route|" "$_cm_diag_log" >/dev/null ||
        fail "TLCI diagnostic lacks $_cm_diag_route route evidence"
    cp "$_cm_diag_file" "$_cm_diag_dir/diagnostic"
    metadata_add "$_cm_diag_dir" "comptime-route=$_cm_diag_route"
}

resolve_spmd_observation() {
    _cm_spmd_spec=$1
    _cm_spmd_dir=$2
    _cm_spmd_tag=${_cm_spmd_spec%%:*}
    _cm_spmd_mode=${_cm_spmd_spec#*:}
    _cm_spmd_base="$ROOT/target/spmd-simd-verify/$_cm_spmd_tag.$_cm_spmd_mode"
    [ -f "$_cm_spmd_base.exit" ] ||
        fail "SPMD exit observation is missing: $_cm_spmd_base.exit"
    [ -f "$_cm_spmd_base.err" ] ||
        fail "SPMD stderr observation is missing: $_cm_spmd_base.err"
    tr -d '\r\n' < "$_cm_spmd_base.exit" > "$_cm_spmd_dir/exit"
    printf '\n' >> "$_cm_spmd_dir/exit"
    cp "$_cm_spmd_base.err" "$_cm_spmd_dir/stderr"
    metadata_add "$_cm_spmd_dir" "backend-mode=$_cm_spmd_mode"
}

resolve_coff_observation() {
    _cm_coff_spec=$1
    _cm_coff_dir=$2
    _cm_coff_case=${_cm_coff_spec%%:*}
    _cm_coff_route=${_cm_coff_spec#*:}
    _cm_coff_root="$ROOT/target/verify-compile-batch-windows-coff"
    _cm_coff_base="$_cm_coff_root/$_cm_coff_case.$_cm_coff_route"
    [ -f "$_cm_coff_base.exit" ] || fail "COFF exit observation is missing: $_cm_coff_base.exit"
    [ -f "$_cm_coff_base.stdout" ] || fail "COFF stdout observation is missing: $_cm_coff_base.stdout"
    [ -f "$_cm_coff_base.stderr" ] || fail "COFF stderr observation is missing: $_cm_coff_base.stderr"
    tr -d '\r\n' < "$_cm_coff_base.exit" > "$_cm_coff_dir/exit"
    printf '\n' >> "$_cm_coff_dir/exit"
    cp "$_cm_coff_base.stdout" "$_cm_coff_dir/stdout"
    cp "$_cm_coff_base.stderr" "$_cm_coff_dir/stderr"
    case "$_cm_coff_route" in
        direct)
            [ -s "$_cm_coff_root/$_cm_coff_case.direct.obj" ] ||
                fail "COFF direct object is missing for $_cm_coff_case"
            [ ! -e "$_cm_coff_root/$_cm_coff_case.direct.s" ] ||
                fail "COFF direct route unexpectedly wrote assembly for $_cm_coff_case"
            metadata_add "$_cm_coff_dir" emission=direct-object
            ;;
        forced)
            [ -s "$_cm_coff_root/$_cm_coff_case.forced.s" ] ||
                fail "COFF forced assembly is missing for $_cm_coff_case"
            metadata_add "$_cm_coff_dir" emission=assembly
            ;;
        *) fail "unknown COFF route: $_cm_coff_route" ;;
    esac
    metadata_add "$_cm_coff_dir" execution=native
}

resolve_expected_observation() {
    _cm_expected_name=$1
    _cm_expected_dir=$2
    case "$_cm_expected_name" in
        portable-color)
            printf '42\n' > "$_cm_expected_dir/exit"
            printf 'color=104:36\n' > "$_cm_expected_dir/stdout"
            : > "$_cm_expected_dir/stderr"
            metadata_add "$_cm_expected_dir" target=portable
            ;;
        *) fail "unknown expected observation: $_cm_expected_name" ;;
    esac
}

resolve_observation() {
    _cm_resolve_descriptor=$1
    _cm_resolve_dir=$2
    mkdir -p "$_cm_resolve_dir"
    : > "$_cm_resolve_dir/metadata"
    case "$_cm_resolve_descriptor" in
        integration:*)
            resolve_integration_observation \
                "${_cm_resolve_descriptor#integration:}" "$_cm_resolve_dir"
            ;;
        stage:*)
            resolve_stage_observation \
                "${_cm_resolve_descriptor#stage:}" "$_cm_resolve_dir"
            ;;
        tlci:*)
            resolve_tlci_observation \
                "${_cm_resolve_descriptor#tlci:}" "$_cm_resolve_dir"
            ;;
        tlci-diagnostic:*)
            resolve_tlci_diagnostic_observation \
                "${_cm_resolve_descriptor#tlci-diagnostic:}" "$_cm_resolve_dir"
            ;;
        spmd:*)
            resolve_spmd_observation \
                "${_cm_resolve_descriptor#spmd:}" "$_cm_resolve_dir"
            ;;
        coff:*)
            resolve_coff_observation \
                "${_cm_resolve_descriptor#coff:}" "$_cm_resolve_dir"
            ;;
        expected:*)
            resolve_expected_observation \
                "${_cm_resolve_descriptor#expected:}" "$_cm_resolve_dir"
            ;;
        *) fail "unknown observation descriptor: $_cm_resolve_descriptor" ;;
    esac
    finalize_observation "$_cm_resolve_dir"
}

print_reproducer() {
    _cm_reproducer_case=$1
    _cm_reproducer_previous=${TYPELISP_CROSS_MODE_PREVIOUS_COMPILER:-target/ci-verify-stage1.path}
    _cm_reproducer_successor=${TYPELISP_BIN:-target/ci-verify-stage2.path}
    echo "[cross-mode] reproduce: TYPELISP_BIN=$_cm_reproducer_successor TYPELISP_CROSS_MODE_PREVIOUS_COMPILER=$_cm_reproducer_previous scripts/verify-cross-mode-differential.sh --case $_cm_reproducer_case" >&2
}

assert_metadata() {
    _cm_assert_case=$1
    _cm_assert_axis=$2
    _cm_assert_route=$3
    _cm_assert_dir=$4
    _cm_assert_expected=$5
    _cm_assert_old_ifs=$IFS
    IFS=,
    for _cm_assert_item in $_cm_assert_expected; do
        IFS=$_cm_assert_old_ifs
        if ! grep -F -x "$_cm_assert_item" "$_cm_assert_dir/metadata" >/dev/null 2>&1; then
            echo "[cross-mode] mismatch case=$_cm_assert_case axis=$_cm_assert_axis observation=metadata route=$_cm_assert_route expected=$_cm_assert_item" >&2
            print_reproducer "$_cm_assert_case"
            IFS=$_cm_assert_old_ifs
            return 1
        fi
        IFS=,
    done
    IFS=$_cm_assert_old_ifs
    return 0
}

compare_observations() {
    _cm_compare_case=$1
    _cm_compare_axis=$2
    _cm_compare_fields=$3
    _cm_compare_reference=$4
    _cm_compare_candidate=$5
    _cm_compare_reference_descriptor=$6
    _cm_compare_candidate_descriptor=$7
    _cm_compare_old_ifs=$IFS
    IFS=,
    for _cm_compare_field in $_cm_compare_fields; do
        IFS=$_cm_compare_old_ifs
        _cm_compare_reference_file="$_cm_compare_reference/$_cm_compare_field"
        _cm_compare_candidate_file="$_cm_compare_candidate/$_cm_compare_field"
        if [ ! -f "$_cm_compare_reference_file" ] ||
            [ ! -f "$_cm_compare_candidate_file" ]; then
            echo "[cross-mode] mismatch case=$_cm_compare_case axis=$_cm_compare_axis observation=$_cm_compare_field route=pair reason=missing-observation" >&2
            echo "[cross-mode]   reference=$_cm_compare_reference_descriptor ($_cm_compare_reference_file)" >&2
            echo "[cross-mode]   candidate=$_cm_compare_candidate_descriptor ($_cm_compare_candidate_file)" >&2
            print_reproducer "$_cm_compare_case"
            IFS=$_cm_compare_old_ifs
            return 1
        fi
        if ! cmp -s "$_cm_compare_reference_file" "$_cm_compare_candidate_file"; then
            echo "[cross-mode] mismatch case=$_cm_compare_case axis=$_cm_compare_axis observation=$_cm_compare_field route=candidate" >&2
            echo "[cross-mode]   reference=$_cm_compare_reference_descriptor" >&2
            echo "[cross-mode]   candidate=$_cm_compare_candidate_descriptor" >&2
            if [ "$_cm_compare_field" != artifact ] && command -v diff >/dev/null 2>&1; then
                diff -u \
                    "$_cm_compare_reference_file" \
                    "$_cm_compare_candidate_file" >&2 || true
            else
                echo "[cross-mode]   reference-sha256=$(hash_file "$_cm_compare_reference_file")" >&2
                echo "[cross-mode]   candidate-sha256=$(hash_file "$_cm_compare_candidate_file")" >&2
            fi
            print_reproducer "$_cm_compare_case"
            IFS=$_cm_compare_old_ifs
            return 1
        fi
        IFS=,
    done
    IFS=$_cm_compare_old_ifs
    return 0
}

self_test_oracle() {
    _cm_self_root="$WORKDIR/self-test"
    rm -rf "$_cm_self_root"
    mkdir -p "$_cm_self_root"
    _cm_self_rows=0
    _cm_self_controls=0
    _cm_tab=$(printf '\t')
    while IFS="$_cm_tab" read -r \
        _cm_case _cm_axis _cm_hosts _cm_applicability \
        _cm_reference_descriptor _cm_candidate_descriptor \
        _cm_observations _cm_reference_metadata _cm_candidate_metadata \
        _cm_producer _cm_notes || [ -n "$_cm_case" ]; do
        [ "$_cm_case" != case ] || continue
        _cm_self_rows=$((_cm_self_rows + 1))
        _cm_reference_dir="$_cm_self_root/$_cm_case/reference"
        _cm_candidate_dir="$_cm_self_root/$_cm_case/candidate"
        mkdir -p "$_cm_reference_dir" "$_cm_candidate_dir"
        for _cm_dir in "$_cm_reference_dir" "$_cm_candidate_dir"; do
            printf '42\n' > "$_cm_dir/exit"
            printf 'stable stdout\n' > "$_cm_dir/stdout"
            printf 'stable stderr\n' > "$_cm_dir/stderr"
            printf 'stable artifact\n' > "$_cm_dir/artifact"
            printf 'stable diagnostic\n' > "$_cm_dir/diagnostic"
        done
        printf '%s\n' "$_cm_reference_metadata" | tr ',' '\n' \
            > "$_cm_reference_dir/metadata"
        printf '%s\n' "$_cm_candidate_metadata" | tr ',' '\n' \
            > "$_cm_candidate_dir/metadata"

        assert_metadata \
            "$_cm_case" "$_cm_axis" reference \
            "$_cm_reference_dir" "$_cm_reference_metadata" >/dev/null
        assert_metadata \
            "$_cm_case" "$_cm_axis" candidate \
            "$_cm_candidate_dir" "$_cm_candidate_metadata" >/dev/null
        compare_observations \
            "$_cm_case" "$_cm_axis" "$_cm_observations" \
            "$_cm_reference_dir" "$_cm_candidate_dir" \
            "$_cm_reference_descriptor" "$_cm_candidate_descriptor" >/dev/null

        case "$_cm_axis:$_cm_observations" in
            call-route:*) _cm_perturb_field=stdout ;;
            compiler-stage:*) _cm_perturb_field=stderr ;;
            comptime-route:*artifact*) _cm_perturb_field=artifact ;;
            comptime-route:*diagnostic*) _cm_perturb_field=diagnostic ;;
            backend-mode:* | emission:*) _cm_perturb_field=metadata ;;
            target:*) _cm_perturb_field=stdout ;;
            *) _cm_perturb_field=${_cm_observations%%,*} ;;
        esac

        for _cm_side in reference candidate; do
            if [ "$_cm_side" = reference ]; then
                _cm_side_dir=$_cm_reference_dir
                _cm_side_metadata=$_cm_reference_metadata
            else
                _cm_side_dir=$_cm_candidate_dir
                _cm_side_metadata=$_cm_candidate_metadata
            fi
            _cm_control_log="$_cm_self_root/$_cm_case.$_cm_side.control.log"
            if [ "$_cm_perturb_field" = metadata ]; then
                cp "$_cm_side_dir/metadata" "$_cm_side_dir/metadata.saved"
                sed -n '2,$p' "$_cm_side_dir/metadata.saved" > "$_cm_side_dir/metadata"
                set +e
                assert_metadata \
                    "$_cm_case" "$_cm_axis" "$_cm_side" \
                    "$_cm_side_dir" "$_cm_side_metadata" \
                    > "$_cm_control_log" 2>&1
                _cm_control_status=$?
                set -e
                mv "$_cm_side_dir/metadata.saved" "$_cm_side_dir/metadata"
                _cm_expected_observation=metadata
            else
                cp \
                    "$_cm_side_dir/$_cm_perturb_field" \
                    "$_cm_side_dir/$_cm_perturb_field.saved"
                printf 'controlled perturbation\n' \
                    >> "$_cm_side_dir/$_cm_perturb_field"
                set +e
                compare_observations \
                    "$_cm_case" "$_cm_axis" "$_cm_observations" \
                    "$_cm_reference_dir" "$_cm_candidate_dir" \
                    "$_cm_reference_descriptor" "$_cm_candidate_descriptor" \
                    > "$_cm_control_log" 2>&1
                _cm_control_status=$?
                set -e
                mv \
                    "$_cm_side_dir/$_cm_perturb_field.saved" \
                    "$_cm_side_dir/$_cm_perturb_field"
                _cm_expected_observation=$_cm_perturb_field
            fi
            [ "$_cm_control_status" -ne 0 ] ||
                fail "oracle accepted $_cm_case $_cm_side controlled perturbation"
            grep -F "case=$_cm_case axis=$_cm_axis observation=$_cm_expected_observation" \
                "$_cm_control_log" >/dev/null ||
                fail "oracle omitted first-difference context for $_cm_case $_cm_side"
            grep -F '[cross-mode] reproduce:' "$_cm_control_log" >/dev/null ||
                fail "oracle omitted reproducer for $_cm_case $_cm_side"
            _cm_self_controls=$((_cm_self_controls + 1))
        done
    done < "$MANIFEST"
    [ "$_cm_self_rows" -gt 0 ] || fail "self-test exercised no manifest rows"
    [ "$_cm_self_controls" -eq $((_cm_self_rows * 2)) ] ||
        fail "self-test control count changed: rows=$_cm_self_rows controls=$_cm_self_controls"
    echo "cross-mode differential oracle self-tests passed ($_cm_self_rows rows, $_cm_self_controls route perturbations)"
}

if [ "$SELF_TEST" -eq 1 ]; then
    self_test_oracle
    exit 0
fi

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
HOST_OS=$NL_HOST_OS

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh")
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/observations"
APPLICABILITY="$WORKDIR/applicability.tsv"
printf 'case\taxis\thost\tstate\treason\n' > "$APPLICABILITY"

case_active() {
    _cm_active_hosts=$1
    _cm_active_applicability=$2
    CASE_ACTIVE_REASON=required
    if [ "$_cm_active_hosts" != all ] && [ "$_cm_active_hosts" != "$HOST_OS" ]; then
        CASE_ACTIVE_REASON="host-$HOST_OS-not-selected"
        return 1
    fi
    case "$_cm_active_applicability" in
        required) return 0 ;;
        isa-avx2)
            if printf '%s\n' "$SIMD_ISAS" | grep -F -x avx2 >/dev/null; then
                CASE_ACTIVE_REASON=host-isa-avx2
                return 0
            fi
            CASE_ACTIVE_REASON=host-isa-avx2-unavailable
            return 1
            ;;
        isa-avx512)
            if printf '%s\n' "$SIMD_ISAS" | grep -F -x avx512 >/dev/null; then
                CASE_ACTIVE_REASON=host-isa-avx512
                return 0
            fi
            CASE_ACTIVE_REASON=host-isa-avx512-unavailable
            return 1
            ;;
        *) fail "unknown applicability: $_cm_active_applicability" ;;
    esac
}

ACTIVE_CASES=0
NOT_APPLICABLE_CASES=0
_cm_tab=$(printf '\t')
while IFS="$_cm_tab" read -r \
    _cm_case _cm_axis _cm_hosts _cm_applicability \
    _cm_reference_descriptor _cm_candidate_descriptor \
    _cm_observations _cm_reference_metadata _cm_candidate_metadata \
    _cm_producer _cm_notes || [ -n "$_cm_case" ]; do
    [ "$_cm_case" != case ] || continue
    if [ -n "$CASE_FILTER" ] && [ "$_cm_case" != "$CASE_FILTER" ]; then
        continue
    fi
    if ! case_active "$_cm_hosts" "$_cm_applicability"; then
        printf '%s\t%s\t%s\tnot-applicable\t%s\n' \
            "$_cm_case" "$_cm_axis" "$HOST_OS" "$CASE_ACTIVE_REASON" \
            >> "$APPLICABILITY"
        echo "[cross-mode] NOT-APPLICABLE $_cm_case axis=$_cm_axis reason=$CASE_ACTIVE_REASON"
        NOT_APPLICABLE_CASES=$((NOT_APPLICABLE_CASES + 1))
        continue
    fi
    printf '%s\t%s\t%s\tactive\t%s\n' \
        "$_cm_case" "$_cm_axis" "$HOST_OS" "$CASE_ACTIVE_REASON" \
        >> "$APPLICABILITY"
    _cm_case_dir="$WORKDIR/observations/$_cm_case"
    _cm_reference_dir="$_cm_case_dir/reference-$(safe_name "$_cm_reference_descriptor")"
    _cm_candidate_dir="$_cm_case_dir/candidate-$(safe_name "$_cm_candidate_descriptor")"
    resolve_observation "$_cm_reference_descriptor" "$_cm_reference_dir"
    resolve_observation "$_cm_candidate_descriptor" "$_cm_candidate_dir"
    assert_metadata \
        "$_cm_case" "$_cm_axis" reference \
        "$_cm_reference_dir" "$_cm_reference_metadata" || exit 1
    assert_metadata \
        "$_cm_case" "$_cm_axis" candidate \
        "$_cm_candidate_dir" "$_cm_candidate_metadata" || exit 1
    compare_observations \
        "$_cm_case" "$_cm_axis" "$_cm_observations" \
        "$_cm_reference_dir" "$_cm_candidate_dir" \
        "$_cm_reference_descriptor" "$_cm_candidate_descriptor" || exit 1
    echo "[cross-mode] PASS $_cm_case axis=$_cm_axis observations=$_cm_observations"
    ACTIVE_CASES=$((ACTIVE_CASES + 1))
done < "$MANIFEST"

[ "$ACTIVE_CASES" -gt 0 ] || {
    if [ -n "$CASE_FILTER" ] && [ "$NOT_APPLICABLE_CASES" -eq 1 ]; then
        echo "cross-mode case is explicitly not applicable (host=$HOST_OS case=$CASE_FILTER applicability=$APPLICABILITY)"
        exit 0
    fi
    fail "no active cases for host=$HOST_OS"
}
echo "cross-mode semantic/ABI differential passed (host=$HOST_OS active=$ACTIVE_CASES not-applicable=$NOT_APPLICABLE_CASES applicability=$APPLICABILITY)"
