#!/usr/bin/env sh
set -eu
# Opt-in focused guard-removal proof for the existing observability self-test.
# The ordinary matrices remain the coverage authority; each variant below runs
# their actual worker/reader assertions on one fault with isolated outputs.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-ci-timing.sh"
proof_shell=${TYPELISP_FIXTURE_PROOF_SHELL:-sh}
command -v "$proof_shell" >/dev/null 2>&1 || exit 2
proof_parent=${1:?proof scratch parent required}
case $proof_parent in "${ROOT:?}/target/"*) ;; *) exit 2 ;; esac
mkdir -p "$proof_parent"
proof_root=$(mktemp -d "$proof_parent/run.XXXXXX")
# Export raw evidence through the existing retained job log, including failures.
# The archive has explicit framing and a SHA-256 receipt for loss detection.
proof_export() {
    proof_exit=$1
    trap - EXIT
    ci_timing_set_now_ms
    proof_export_started=$CI_TIMING_NOW_MS
    proof_archive="$proof_root.evidence.tar.gz"
    if ! tar -czf "$proof_archive" \
        --exclude='./launch-profile/base.tar' --exclude='./launch-profile/head.tar' \
        --exclude='./launch-profile/base/scripts' --exclude='./launch-profile/head/scripts' \
        --exclude='./launch-profile/base/tests' --exclude='./launch-profile/head/tests' \
        -C "$proof_root" .; then exit 1; fi
    proof_hash=$(sha256sum "$proof_archive")
    proof_hash=${proof_hash%% *}
    base64 "$proof_archive" > "$proof_archive.base64" || exit 1
    printf '[fixture-proof-archive] BEGIN schema=1 sha256=%s\n' "$proof_hash"
    sed 's/^/[fixture-proof-archive] /' "$proof_archive.base64" || exit 1
    printf '[fixture-proof-archive] END sha256=%s\n' "$proof_hash"
    ci_timing_set_now_ms
    ci_timing_record_elapsed fixture-proof archive-export \
        "$((CI_TIMING_NOW_MS - proof_export_started))" "$proof_exit" || exit 1
    exit "$proof_exit"
}
trap 'proof_export "$?"' EXIT
PROOF_ROOT=$ROOT
PROOF_SCRATCH=$proof_root
PROOF_REPORT_HOSTS='linux windows'
PROOF_PHYSICAL_HOST=linux
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) PROOF_REPORT_HOSTS=windows; PROOF_PHYSICAL_HOST=windows ;; esac
export PROOF_ROOT PROOF_SCRATCH PROOF_REPORT_HOSTS PROOF_PHYSICAL_HOST
printf 'route\tguard\tfault\texit\texpect\n' > "$proof_root/results.tsv"

proof_variant() {
    PROOF_ROUTE=$1 PROOF_GUARD=$2 PROOF_CASE=$3
    export PROOF_ROUTE PROOF_GUARD PROOF_CASE
    proof_script="$proof_root/$PROOF_ROUTE-$PROOF_GUARD-$PROOF_CASE.sh"
    awk -v route="$PROOF_ROUTE" -v guard="$PROOF_GUARD" '
        function output(line) {
            if (line ~ /^ROOT=/) line = "ROOT=${PROOF_ROOT:?}"
            if (line ~ /^source_location_self_test /) return
            if (line == "        WORK_SUFFIX=-self-test-batch-observability")
                line = "        WORK_SUFFIX=-self-test-completion-mutant-$PROOF_GUARD-$PROOF_CASE"
            if (line ~ /^awk -v host=.*expand-integration-manifest.awk/) { skip_manifest = 1; return }
            if (skip_manifest) { skip_manifest = 0; return }
            # A narrowed missing-report-only selection schedules no ordinary
            # diagnostic needles. There is no log assertion to run in that
            # selection; status, admission and output assertions still run.
            if (line ~ /bounded_completion_fixture_check "\$_completion_checks"/)
                sub(/bounded_completion_fixture_check/, "[ ! -s \"$_completion_checks\" ] || bounded_completion_fixture_check", line)
            # Tag normal assertion failures, not shell/tool errors, using fd 2.
            if (region && match(line, / \|\| exit 1( ;;)?$/)) {
                tail = (line ~ / ;;$/) ? " ;;" : ""
                line = substr(line, 1, RSTART - 1) " || { printf \"completion-mutant assertion: %s/%s line " NR "\\n\" \"$PROOF_ROUTE\" \"$PROOF_GUARD\" >&2; exit 1; }" tail
            }
            print line
            if (line == guard "() {") {
                if (guard == "integration_batch_require_success") print "    return 0"
                else if (guard == "integration_diagnostic_only") print "    return 1"
                else print "    bounded_pool_read_report() { BOUNDED_POOL_REPORT_PEAK=1048576; BOUNDED_POOL_REPORT_REASON=success; BOUNDED_POOL_REPORT_EXIT_CODE=0; BOUNDED_POOL_REPORT_FAILURE=fixture-bypass; return 0; }"
                mutated++
            }
            if (line ~ /bounded_completion_fixture_matrix "\$HOST_OS"/) {
                print "    BOUNDED_COMPLETION_HOSTS=$PROOF_REPORT_HOSTS"
                print "    BOUNDED_COMPLETION_CASES=$PROOF_CASE"
            }
        }
        $0 == "run_bounded_completion_self_test() (" { region = 1 }
        $0 == "run_batch_observability_self_test() {" { region = 0 }
        route == "integration" && /^if \[ "\$SELF_TEST_BATCH_OBSERVABILITY" -eq 1 \]; then$/ {
            print "run_bounded_completion_self_test\nexit 0"; stopped = 1; exit
        }
        route == "inline-tests" && $0 == "inline_test_self_test_chunks" {
            stopped = 1; exit
        }
        route == "selfhost-compile-manifest" && $0 == "( expectation_self_test )" {
            stopped = 1; exit
        }
        route == "inline-tests" && /^    # Plausible passing stdout/ { matrix = 1 }
        route == "selfhost-compile-manifest" && /^    # Reader checks run with valid-looking assembly/ { matrix = 1 }
        matrix && matrix_done && $0 == "    ci_timing_set_now_ms" { matrix = 0 }
        matrix {
            matrix_body = matrix_body $0 "\n"
            if ($0 ~ /bounded_completion_fixture_check "\$_completion_checks"/) matrix_done = 1
        }
        { output($0) }
        END {
            if (!stopped || (guard != "control" && mutated != 1)) exit 2
            if (route != "integration") {
                if (!matrix_done) exit 2
                print ". \"$ROOT/scripts/lib-bounded-completion-fixtures.sh\""
                print "INLINE_TEST_SELF_TEST_ROOT=\"$PROOF_SCRATCH/inline-$PROOF_GUARD-$PROOF_CASE\""
                print "MANIFEST_POOL_SELF_TEST_ROOT=\"$PROOF_SCRATCH/manifest-$PROOF_GUARD-$PROOF_CASE\""
                print "EXPECTATION_MODE=stage1"
                print "mkdir -p \"$INLINE_TEST_SELF_TEST_ROOT\" \"$MANIFEST_POOL_SELF_TEST_ROOT\""
                # Replay the same matrix source with only its case selection narrowed.
                n = split(matrix_body, lines, "\n")
                region = 1
                for (i = 1; i < n; i++) output(lines[i])
                print "exit 0"
            }
        }
    ' "$ROOT/scripts/verify-$PROOF_ROUTE.sh" > "$proof_script"
    "$proof_shell" -n "$proof_script"
    proof_rc=0
    proof_flag=--self-test-batch-observability
    case $PROOF_ROUTE in inline-tests) proof_flag=--self-test-chunks ;; selfhost-compile-manifest) proof_flag=--self-test-pool ;; esac
    TYPELISP_CI_TIMING=0 "$proof_shell" "$proof_script" "$proof_flag" > "$proof_script.log" 2>&1 || proof_rc=$?
    if [ "$PROOF_ROUTE" = integration ]; then
        cp -a "$ROOT/target/integration-verify/$PROOF_PHYSICAL_HOST-self-test-completion-mutant-$PROOF_GUARD-$PROOF_CASE" \
            "$proof_script.artifacts"
    fi
    proof_want=1
    [ "$PROOF_GUARD" != control ] || proof_want=0
    printf '%s\t%s\t%s\t%s\t%s\n' "$PROOF_ROUTE" "$PROOF_GUARD" "$PROOF_CASE" "$proof_rc" "$proof_want" >> "$proof_root/results.tsv"
    if [ "$proof_rc" -ne "$proof_want" ]; then
        cat "$proof_script.log" >&2
        echo "FAIL: completion mutant $PROOF_ROUTE/$PROOF_GUARD/$PROOF_CASE: exit $proof_rc, expected $proof_want" >&2
        exit 1
    fi
    if [ "$proof_want" -eq 1 ] && ! grep -Eq 'completion-mutant assertion:|worker fixture failed:|worker admission|compile manifest pool self-test: (linux|windows)/missing-report accepted|FAIL: integration (accepted/replayed|parent accepted) (linux|windows)/missing-report' "$proof_script.log"; then
        cat "$proof_script.log" >&2
        echo "FAIL: completion mutant $PROOF_ROUTE/$PROOF_GUARD failed outside its assertion" >&2
        exit 1
    fi
    echo "[completion-mutant] route=$PROOF_ROUTE guard=$PROOF_GUARD fault=$PROOF_CASE report_hosts=$PROOF_REPORT_HOSTS exit=$proof_rc expected=$proof_want"
}

ci_timing_set_now_ms
proof_started=$CI_TIMING_NOW_MS
# Controls use the identical extraction and narrowed selections as the mutants.
proof_variant integration control missing-report
proof_variant integration control command-2
proof_variant inline-tests control missing-report
proof_variant selfhost-compile-manifest control missing-report
proof_variant integration bounded_pool_run_job missing-report
proof_variant integration integration_batch_settle_chunk missing-report
proof_variant integration integration_standalone_compile missing-report
proof_variant integration integration_batch_require_success command-2
proof_variant integration integration_diagnostic_only command-2
proof_variant inline-tests bounded_pool_run_job missing-report
proof_variant inline-tests inline_test_settle_chunk missing-report
proof_variant selfhost-compile-manifest bounded_pool_run_job missing-report
proof_variant selfhost-compile-manifest manifest_settle_chunk missing-report
ci_timing_set_now_ms
proof_elapsed=$((CI_TIMING_NOW_MS - proof_started))
ci_timing_record_elapsed completion-mutants guard-removal-proof "$proof_elapsed" 0
printf '[completion-mutant] passed: 9 guard removals, 4 controls; elapsed_ms=%s; evidence=%s\n' "$proof_elapsed" "$proof_root"

[ "${TYPELISP_FIXTURE_MUTANTS:-completion}" = all ] || exit 0
ci_timing_set_now_ms
forwarding_started=$CI_TIMING_NOW_MS

# The reduced host selection must still detect each guard relevant to that
# plan. A fresh unmutated control proves every narrowed invocation is valid.
proof_forwarding() {
    proof_kind=$1 PROOF_GUARD=$2 PROOF_CASE=$3 proof_needle=$4 proof_source=$5
    PROOF_NL_PLAN=$6
    PROOF_PREP_COUNT=6
    [ "$PROOF_PHYSICAL_HOST" != windows ] || PROOF_PREP_COUNT=4
    export PROOF_GUARD PROOF_CASE PROOF_NL_PLAN PROOF_PREP_COUNT
    for proof_action in control mutant; do
        proof_prefix="$proof_root/$proof_kind-$PROOF_GUARD-$proof_action"
        if [ "$proof_kind" = native ]; then
            PROOF_LIBRARY="$proof_prefix.native.sh"
            PROOF_ENTRY="$proof_prefix.entry.sh"
            export PROOF_LIBRARY PROOF_ENTRY
            for proof_lib in lib-native-link.sh lib-linux-entry.sh; do
                proof_destination=$PROOF_LIBRARY
                [ "$proof_lib" != lib-linux-entry.sh ] || proof_destination=$PROOF_ENTRY
                PROOF_NEEDLE=$proof_needle awk -v mutate="$proof_action" -v source="$proof_source" -v file="$proof_lib" '
                    $0 == ENVIRON["PROOF_NEEDLE"] && source == file {
                        found++
                        if (mutate == "mutant") sub(/ \|\| return .*$/, "")
                    }
                    $0 == ". \"$ROOT/scripts/lib-linux-entry.sh\"" { $0 = ". \"$PROOF_ENTRY\"" }
                    { print }
                    END { if (source == file && found != 1) exit 2 }
                ' "$ROOT/scripts/$proof_lib" > "$proof_destination"
            done
            awk '
                /^ROOT=/ { print "ROOT=${PROOF_ROOT:?}"; next }
                $0 == ". \"$ROOT/scripts/lib-native-link.sh\"" { print ". \"$PROOF_LIBRARY\""; next }
                { sub(/nl_case_count=[0-9]+/, "nl_case_count=2"); print }
                /^    nl_case=/ { print "    [ \"$nl_case\" = \"$PROOF_NL_PLAN-$nl_timing-$PROOF_CASE\" ] || return 0" }
            ' "$ROOT/scripts/verify-native-link-failures.sh" > "$proof_prefix.sh"
            proof_arg="$proof_prefix.artifacts"
        else
            PROOF_NEEDLE=$proof_needle awk -v mutate="$proof_action" '
                /^ROOT=/ { print "ROOT=${PROOF_ROOT:?}"; next }
                /^source_location_self_test / { next }
                /^awk -v host=.*expand-integration-manifest.awk/ { skip = 1; next }
                skip { skip = 0; next }
                $0 == "        WORK_SUFFIX=-self-test-batch-observability" { $0 = "        WORK_SUFFIX=-self-test-preparation-mutant-$PROOF_GUARD-" mutate }
                /^    prep_failures=/ { $0 = "    prep_failures=$PROOF_CASE" }
                { sub(/prep_count=[0-9]+/, "prep_count=$PROOF_PREP_COUNT") }
                $0 == ENVIRON["PROOF_NEEDLE"] {
                    found++
                    if (mutate == "mutant") sub(/ \|\| (return|exit) .*$/, "")
                }
                /^if \[ "\$SELF_TEST_BATCH_OBSERVABILITY" -eq 1 \]; then$/ {
                    print "run_preparation_failure_self_test\nexit 0"; stopped = 1; exit
                }
                { print }
                END { if (found != 1 || !stopped) exit 2 }
            ' "$ROOT/scripts/verify-integration.sh" > "$proof_prefix.sh"
            proof_arg=--self-test-batch-observability
        fi
        "$proof_shell" -n "$proof_prefix.sh"
        proof_rc=0
        TYPELISP_CI_TIMING=0 "$proof_shell" "$proof_prefix.sh" "$proof_arg" > "$proof_prefix.log" 2>&1 || proof_rc=$?
        if [ "$proof_kind" = preparation ]; then
            cp -a "$ROOT/target/integration-verify/$PROOF_PHYSICAL_HOST-self-test-preparation-mutant-$PROOF_GUARD-$proof_action" \
                "$proof_prefix.artifacts"
        fi
        proof_want=0
        [ "$proof_action" != mutant ] || proof_want=1
        if [ "$proof_rc" -ne "$proof_want" ]; then
            cat "$proof_prefix.log" >&2
            echo "FAIL: $proof_kind guard $PROOF_GUARD/$proof_action: exit $proof_rc, expected $proof_want" >&2
            exit 1
        fi
        if [ "$proof_action" = mutant ]; then
            if [ "$proof_kind" = native ]; then
                for proof_timing in 0 1; do
                    grep -Fq "FAIL: native-link fixture $PROOF_NL_PLAN-$proof_timing-$PROOF_CASE:" "$proof_prefix.log" || exit 1
                done
            else
                grep -Eq 'FAIL: preparation|FAIL: batch settlement lost' "$proof_prefix.log" || exit 1
            fi
        fi
        printf '%s\t%s/%s\t%s\t%s\t%s\n' "$proof_kind" "$PROOF_GUARD" "$proof_action" "$PROOF_CASE" "$proof_rc" "$proof_want" >> "$proof_root/results.tsv"
    done
    echo "[forwarding-mutant] kind=$proof_kind guard=$PROOF_GUARD host=$PROOF_PHYSICAL_HOST plan=$PROOF_NL_PLAN case=$PROOF_CASE timing=0,1 detected"
}

while IFS='#' read -r proof_scope proof_name proof_plan proof_case proof_source proof_needle; do
    [ "$proof_scope" != linux ] || [ "$PROOF_PHYSICAL_HOST" = linux ] || continue
    [ "$proof_plan" != native ] || proof_plan=$PROOF_PHYSICAL_HOST
    proof_forwarding native "$proof_name" "$proof_case" "$proof_needle" "$proof_source" "$proof_plan"
done <<'NATIVE'
linux#linux-assembler#linux#assemble-assemble#lib-native-link.sh#        as "$asm" -o "$obj" || return $?
all#windows-assembler#windows#assemble-assemble#lib-native-link.sh#    "$TYPELISP_WINDOWS_CLANG_POSIX" --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" || return $?
linux#linux-entry#linux#assemble-entry#lib-native-link.sh#        _entry=$(linux_entry_symbol_for_asm "$asm") || return $?
all#object-path#windows#assemble-object-path#lib-native-link.sh#        obj_win=$(to_windows_path "$obj") || return $?
all#binary-path#windows#assemble-binary-path#lib-native-link.sh#        bin_win=$(to_windows_path "$bin") || return $?
all#clang-override#windows#toolchain-unix-path#lib-native-link.sh#        TYPELISP_WINDOWS_CLANG_POSIX=$(to_unix_path "$TYPELISP_WINDOWS_CLANG") || return $?
all#linker-override#windows#linker-unix-path#lib-native-link.sh#        TYPELISP_WINDOWS_LINK_POSIX=$(to_unix_path "$TYPELISP_WINDOWS_LINK") || return $?
all#short-path#windows#clang-short-path#lib-native-link.sh#    TYPELISP_WINDOWS_CLANG=$(short_windows_path "$clang_path") || return $?
all#configure-chain#windows#toolchain-unix-path#lib-native-link.sh#        configure_windows_clang_env || return $?
all#clang-discovery#windows#find-discovery#lib-native-link.sh#        command -v clang.exe || return $?
all#linker-discovery#windows#linker-discovery#lib-native-link.sh#        TYPELISP_WINDOWS_LINK_POSIX=$(command -v lld-link) || return $?
linux#linux-assemble-notice#linux#assemble-assemble-notice#lib-native-link.sh#        echo "[native-link] assemble $label with as" || return $?
all#windows-assemble-notice#windows#assemble-assemble-notice#lib-native-link.sh#    echo "[native-link] assemble $label with clang" || return $?
linux#linux-link-notice#linux#assemble-link-notice#lib-native-link.sh#        echo "[native-link] link $label with ld (freestanding: no libc, no loader)" || return $?
all#windows-link-notice#windows#assemble-link-notice#lib-native-link.sh#        echo "[native-link] link $label with Windows COFF linker (freestanding: no CRT)" || return $?
all#linker-notice#windows#linker-linker-notice#lib-native-link.sh#        echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK" || return $?
all#entry-read#native#real-entry-entry-first#lib-linux-entry.sh#            [ "$_tle_status" -eq 1 ] || return "$_tle_status"
all#short-output#windows#short-output-output#lib-native-link.sh#                command printf '%s\n' "$short_path" || return $?
all#normalization#windows#powershell-normalize#lib-native-link.sh#        ) || return $?
NATIVE
while IFS='#' read -r proof_name proof_case proof_needle; do
    proof_forwarding preparation "$proof_name" "$proof_case" "$proof_needle" verify-integration.sh "$PROOF_PHYSICAL_HOST"
done <<'PREPARATION'
prepare-stage-corpus#helper-build#    integration_stage_corpus || return 1
prepare-location#location#    integration_source_location_self_test || exit 1
stage-helper#helper-build#    ci_timing_run manifest stage-helper integration_stage_helper_build || return 1
stage-self-test#self-test#    integration_stage_self_test || return 1
stage-plan#stage-plan#    ci_timing_run manifest stage-plan integration_stage_plan || return 1
batch-queue#batch-queue#    ci_timing_run manifest batch-queue integration_batch_queue || return 1
batch-pool#pool#        integration_batch_run_pool "$_pool_queue" || return 1
windows-result-plan#success#                "$_chunk_list" "$_chunk_plan" "$_chunk_label" || return 1
PREPARATION
ci_timing_set_now_ms
forwarding_elapsed=$((CI_TIMING_NOW_MS - forwarding_started))
ci_timing_record_elapsed host-plan-mutants host-plan-guard-proof "$forwarding_elapsed" 0
printf '[forwarding-mutant] all relevant guards detected; elapsed_ms=%s; evidence=%s\n' "$forwarding_elapsed" "$proof_root"

if [ "$PROOF_PHYSICAL_HOST" = windows ]; then
    ci_timing_set_now_ms
    launch_profile_started=$CI_TIMING_NOW_MS
    profile_root="$proof_root/launch-profile"
    mkdir -p "$profile_root/base" "$profile_root/head"
    profile_base=632185e7f0f320dbaf1ba66fed4266d2ef5d6e22
    git -C "$ROOT" cat-file -e "$profile_base^{commit}" 2>/dev/null ||
        git -C "$ROOT" fetch --no-tags origin "$profile_base"
    git -C "$ROOT" archive "$profile_base" scripts tests/integration/native.manifest > "$profile_root/base.tar"
    git -C "$ROOT" archive HEAD scripts tests/integration/native.manifest > "$profile_root/head.tar"
    tar -xf "$profile_root/base.tar" -C "$profile_root/base"
    tar -xf "$profile_root/head.tar" -C "$profile_root/head"
    printf 'base=%s\nhead=%s\n' "$profile_base" "$(git -C "$ROOT" rev-parse HEAD)" > "$profile_root/provenance.txt"
    profile_shell=$(cygpath -aw "$(command -v bash)")
    profile_observer=$(cygpath -aw "$ROOT/scripts/measure-fixture-launches.ps1")
    # One external sh command creates a Bash fork and a sh executable on MSYS.
    # Pin that complete known tree, including both protected sentinel branches.
    profile_tiny="$profile_root/known-tree.sh"
    printf '%s\n' '#!/usr/bin/env sh' 'set -eu' \
        'MSYS2_ARG_CONV_EXCL="*" cmd.exe /d /c exit 0' \
        'sh -c :' \
        'MSYS2_ARG_CONV_EXCL="*" cmd.exe /d /c exit 0' > "$profile_tiny"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$profile_observer" \
        -Shell "$profile_shell" -Script "$(cygpath -am "$profile_tiny")" \
        -WorkingDirectory "$(cygpath -aw "$ROOT")" \
        -OutputPrefix "$(cygpath -aw "$profile_root/known-tree")" -ExpectedFixtureLaunches 2
    for profile_version in base head; do
        for profile_route in integration inline-tests selfhost-compile-manifest; do
            profile_flag=--self-test-batch-observability
            case $profile_route in inline-tests) profile_flag=--self-test-chunks ;; selfhost-compile-manifest) profile_flag=--self-test-pool ;; esac
            profile_driver="$profile_root/$profile_version-$profile_route.sh"
            {
                printf '#!/usr/bin/env sh\nset -eu\ncd "%s"\n' "$profile_root/$profile_version"
                printf '%s\n' 'export TYPELISP_INLINE_TEST_WORKERS=1 TYPELISP_BUILD_INVARIANCE_WORKERS=1 TYPELISP_INTEGRATION_WORKERS=1 TYPELISP_COMPILE_MANIFEST_WORKERS=1'
                printf '%s\n' 'export TYPELISP_FIXTURE_MUTANTS=0 TYPELISP_CI_TIMING=1 TYPELISP_CI_TIMING_HOST=windows'
                printf 'export TYPELISP_CI_TIMING_GATE=launch-profile-%s\n' "$profile_version"
                printf 'export TYPELISP_CI_TIMING_FILE="%s/%s-%s.timing.tsv"\n' "$profile_root" "$profile_version" "$profile_route"
                printf '%s\n' 'MSYS2_ARG_CONV_EXCL="*" cmd.exe /d /c exit 0'
                printf 'sh scripts/verify-%s.sh %s\n' "$profile_route" "$profile_flag"
                printf '%s\n' 'MSYS2_ARG_CONV_EXCL="*" cmd.exe /d /c exit 0'
            } > "$profile_driver"
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$profile_observer" \
                -Shell "$profile_shell" -Script "$(cygpath -am "$profile_driver")" \
                -WorkingDirectory "$(cygpath -aw "$ROOT")" \
                -OutputPrefix "$(cygpath -aw "$profile_root/$profile_version-$profile_route")"
        done
    done
    ci_timing_set_now_ms
    ci_timing_record_elapsed fixture-launch-profile hosted-launch-profile \
        "$((CI_TIMING_NOW_MS - launch_profile_started))" 0
fi
