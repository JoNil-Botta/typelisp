#!/usr/bin/env bash
# Temporary #7767 diagnostic, never a replacement for required CI.
set -euo pipefail

payload() {
    local out=$1
    shift
    [[ $1 == -- ]] || exit 2
    shift
    [[ -d $out && ! -e $out/cpu.tsv ]] || exit 2
    local time_tool=${PROBE_TIME_BIN:-/usr/bin/time}
    [[ -x $time_tool ]] || { echo "GNU Time unavailable: $time_tool" >&2; exit 2; }
    local status=0
    # GNU Time is inside the bounded service, directly parenting the exec shim
    # and compiler/perf subtree. An outer systemd-run client's wait4 is not
    # compiler CPU evidence. The same tiny shim is used in every trial.
    "$time_tool" -f $'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S' -o "$out/cpu.tsv" \
        bash --noprofile --norc -c '
            out=$1; shift
            printf "%s\n" "$BASHPID" > "$out/native.pid"
            cat "/proc/$BASHPID/cgroup" > "$out/native.cgroup"
            exec "$@" > "$out/compiler.stdout" 2> "$out/compiler.stderr"
        ' probe-payload "$out" "$@" || status=$?
    printf '%s\n' "$status" > "$out/native.exit"
    exit "$status"
}

telemetry() {
    local phase=$1 parent=$2 t line pid child cg svc value total key file
    declare -A groups=()
    printf 'uptime_seconds\tkind\tscope\tvalue\n' > "$phase/telemetry.tsv"
    while [[ ! -e $phase/telemetry.stop ]]; do
        read -r t _ < /proc/uptime
        total=0
        {
            for file in "$phase"/jobs/*/native.cgroup; do
                [[ -f $file ]] || continue
                read -r line < "$file" || continue
                cg="/sys/fs/cgroup${line#0::}"
                while [[ $cg != /sys/fs/cgroup && $cg != / && $cg != *.service ]]; do cg=${cg%/*}; done
                if [[ $cg == */run-*.service ]]; then groups["$cg"]=1; fi
            done
            for cg in "${!groups[@]}"; do
                [[ -r $cg/memory.current ]] || continue
                read -r value < "$cg/memory.current" || continue
                total=$((total + value))
                printf '%s\tmemory.current\t%s\t%s\n' "$t" "$cg" "$value"
            done
            printf '%s\tactive_bounded_services_sum\tobserved_not_enforced\t%s\n' "$t" "$total"
            for file in "$phase"/jobs/*/native.pid; do
                [[ -f $file ]] || continue
                read -r pid < "$file" || continue
                [[ $pid =~ ^[0-9]+$ ]] || continue
                for key in stat schedstat; do
                    if [[ -r /proc/$pid/$key ]]; then
                        read -r value < "/proc/$pid/$key" || continue
                        printf '%s\tprocess.%s\t%s\t%s\n' "$t" "$key" "$pid" "$value"
                    fi
                done
                if [[ -r /proc/$pid/task/$pid/children ]]; then
                    read -r line < "/proc/$pid/task/$pid/children" || line=
                    for child in $line; do
                        if [[ -r /proc/$child/stat ]]; then
                            read -r value < "/proc/$child/stat" || continue
                            printf '%s\tprocess.stat.child\t%s\t%s\n' "$t" "$child" "$value"
                        fi
                    done
                fi
            done
            if [[ -r /proc/$parent/status ]]; then
                while read -r key value; do
                    case $key in VmRSS:|Cpus_allowed_list:) printf '%s\tcoordinator.%s\t%s\t%s\n' "$t" "$key" "$parent" "$value";; esac
                done < "/proc/$parent/status"
            fi
            read -r value < /proc/loadavg
            printf '%s\tloadavg\tvm\t%s\n' "$t" "$value"
            read -r value < /proc/stat
            printf '%s\tcpu.stat\tvm\t%s\n' "$t" "$value"
            while read -r key value; do
                case $key in MemAvailable:|SwapFree:) printf '%s\t%s\tvm\t%s\n' "$t" "$key" "$value";; esac
            done < /proc/meminfo
            for key in cpu memory io; do
                if [[ -r /proc/pressure/$key ]]; then
                    while IFS= read -r value; do printf '%s\tpressure.%s\tvm\t%s\n' "$t" "$key" "$value"; done < "/proc/pressure/$key"
                fi
            done
            # These ancestor scopes include the VM's other user processes and
            # released page-cache charges, not only the active compiler jobs.
            for cg in "${!groups[@]}"; do
                svc=${cg%/*}
                if [[ -r $svc/memory.current ]]; then
                    read -r value < "$svc/memory.current" || continue
                    printf '%s\tancestor.memory.current\t%s\t%s\n' "$t" "$svc" "$value"
                fi
                break
            done
        } >> "$phase/telemetry.tsv"
        sleep 0.2
    done
}

case ${1:-} in
    --payload) shift; payload "$@";;
    --telemetry) shift; telemetry "$@"; exit;;
esac

MODE=${1:-}
case $MODE in --run|--coordinator|--validate|--self-test|--self-test-failure) ;; *) echo 'expected --run, --validate or --self-test' >&2; exit 2;; esac
SCRIPT=$(readlink -f -- "$0")
ROOT=$(CDPATH= cd -- "${2:-$(dirname -- "$SCRIPT")/..}" && pwd -P)
cd "$ROOT"
FIXTURES=${3:-$ROOT/perf/issue7767-overlap}
MOCK=0
MOCK_FAIL=
[[ $MODE != --self-test && $MODE != --self-test-failure ]] || MOCK=1
[[ $MODE != --self-test-failure ]] || MOCK_FAIL=selfhost
. "$ROOT/scripts/lib-build-invariance-batch.sh"
BOUNDED_POOL_LABEL=overlap-diagnostic
. "$ROOT/scripts/lib-bounded-pool.sh"
. "$ROOT/scripts/lib-ci-timing.sh"

die() { echo "[overlap-diagnostic] $*" >&2; exit 1; }
now() { ci_timing_set_now_ms; NOW=$CI_TIMING_NOW_MS; }
FIXED_C=51c278506af12fd51fba495079e73f69208f7b91
source_digest() {
    git ls-files -z --cached --others --exclude-standard -- src stdlib tests |
        LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
}

validate_fixtures() {
    (cd "$FIXTURES" && sha256sum -c checksums.sha256)
    local n f name source input opt
    for n in 0017 0018 0019; do
        f="$FIXTURES/chunk$n.cases"
        awk -F'|' 'NF!=4 || $1 !~ /^[A-Za-z0-9_-]+$/ || seen[$1]++ ||
            $2!=$3 || $3 !~ /^tests\/(integration|safety)\/[A-Za-z0-9_./-]+\.tl$/ ||
            $3 ~ /(^|\/)\.\.(\/|$)/ || $4!=2 { exit 1 }
            END { if(NR!=64) exit 1 }' "$f" || die "invalid fixture $n"
        while IFS='|' read -r name source input opt; do [[ -f $source && -f $input ]] || die "missing input $input"; done < "$f"
    done
}

prepare_job() {
    local job=$1 producer=$2 chunk=$3 cap=$4 expected=$5 jd="$PHASE/jobs/$1"
    mkdir -p "$jd/asm"
    if [[ $job == selfhost ]]; then
        printf 'selfhost_main_opt2|src/main.tl|src/main.tl|%s/selfhost_main_opt2.s|2\n' "$jd/asm" > "$jd/cases.txt"
    else
        awk -F'|' -v out="$jd/asm" '{print $1 "|" $2 "|" $3 "|" out "/" $1 ".s|" $4}' \
            "$FIXTURES/chunk$chunk.cases" > "$jd/cases.txt"
    fi
    build_invariance_plan_chunk "$jd/cases.txt" "$jd/entries.txt" "$jd/aliases.txt" 2 "$jd/asm"
    [[ $(wc -l < "$jd/entries.txt") -eq $expected ]] || die "entry count $job"
    printf '%s|%s|%s|%s\n' "$producer" "$chunk" "$cap" "$expected" > "$jd/identity.txt"
}

prepare_phase() {
    local phase=$1 job prod chunk expected previous=
    PHASE="$WORK/trials/$phase"
    mkdir -p "$PHASE/jobs"
    printf 'not_started\n' > "$PHASE/status.txt"
    printf 'not_started\n' > "$PHASE/stage.txt"
    prepare_job selfhost opt1-built selfhost 8192 1
    prepare_job anchor opt2-built 0017 4096 44
    printf 'selfhost|8192\n' > "$PHASE/queue.txt"
    for chunk in 0017 0018 0019; do
        expected=44
        [[ $chunk != 0019 ]] || expected=49
        for prod in opt1-built opt2-built; do
            job="$prod.opt2.$chunk"
            prepare_job "$job" "$prod" "$chunk" 4096 "$expected"
            printf '%s|4096%s\n' "$job" "${previous:+|$previous}" >> "$PHASE/queue.txt"
            previous=$job
        done
    done
    [[ $(wc -l < "$PHASE/queue.txt") -eq 7 ]] || die 'queue count'
    bounded_pool_require_queue 12288 "$PHASE/queue.txt"
    : > "$PHASE/expected-outputs.txt"
    for job in selfhost anchor opt1-built.opt2.0017 opt2-built.opt2.0017 opt1-built.opt2.0018 opt2-built.opt2.0018 opt1-built.opt2.0019 opt2-built.opt2.0019; do
        awk -F'|' -v job="$job" '{print job "/asm/" $1 ".s"}' "$PHASE/jobs/$job/cases.txt" >> "$PHASE/expected-outputs.txt"
    done
    [[ $(wc -l < "$PHASE/expected-outputs.txt") -eq 449 ]] || die 'logical output count'
}

check_memory() {
    awk -F= -v limit="$(($2*1048576))" '
        $1=="backend" {b=$2} $1=="reason"{r=$2} $1=="exit_code"{e=$2;have=1}
        $1=="limit_bytes"{l=$2} $1=="peak_memory_bytes"{p=$2}
        END{exit !(b=="systemd-user-cgroup" && r=="success" && have && e==0 && l==limit && p>0 && p<l)}
    ' "$1" || die "invalid enforced report $1"
}

verify_batch_receipts() {
    local entries=$1 stdout=$2 stderr=$3
    [[ -f $stdout && -f $stderr && ! -s $stderr ]] || return 1
    LC_ALL=C awk -F'|' '
        FILENAME==ARGV[1] {
            if (NF!=2 || $2=="" || expected["Wrote " $2]++) invalid=1
            entries++; next
        }
        {
            if (!($0 in expected) || received[$0]++) invalid=1
            receipts++
        }
        END { exit invalid || !entries || entries!=receipts }
    ' "$entries" "$stdout"
}

bounded_pool_run_job() {
    local job=$1 planned_cap=$2 jd="$PHASE/jobs/$1" producer chunk cap expected compiler status=0 start end
    local name source input out opt
    IFS='|' read -r producer chunk cap expected < "$jd/identity.txt"
    [[ $planned_cap == $cap ]] || die 'queue cap differs from identity'
    compiler=$OPT1
    [[ $producer != opt2-built ]] || compiler=$OPT2
    build_invariance_require_plan "$jd/cases.txt" "$jd/entries.txt" "$jd/aliases.txt" 2 "$jd/asm"
    while IFS='|' read -r name source input out opt; do [[ ! -e $out && ! -L $out ]] || die "stale output $out"; done < "$jd/cases.txt"
    local timeout_seconds=600
    if [[ $MOCK == 1 ]]; then cap=32; timeout_seconds=5; fi
    local -a command=("$compiler" compile --batch "$jd/entries.txt" --target linux-x86_64
        --cfg linux --cfg unix --cfg target-linux --cfg os-linux --backend-mode scalar
        --opt-level 2 --stdlib-root stdlib --stdlib-root src)
    if [[ $PERF_AVAILABLE == 1 ]]; then
        command=(perf stat -x $'\t' --no-big-num -o "$jd/perf.tsv" -e cycles:u,instructions:u -- "${command[@]}")
    fi
    now; start=$NOW
    printf '%s\n' "$start" > "$jd/start_ms"
    env -u BASH_ENV "$ROOT/scripts/run-memory-bounded.sh" --limit-mib "$cap" \
        --timeout-seconds "$timeout_seconds" --report "$jd/memory.txt" -- \
        env -u BASH_ENV PROBE_JOB_ID="$job" PROBE_MOCK_FAIL_JOB="$MOCK_FAIL" \
        bash "$SCRIPT" --payload "$jd" -- "${command[@]}" \
        > "$jd/wrapper.stdout" 2> "$jd/wrapper.stderr" || status=$?
    now; end=$NOW
    printf '%s\n' "$end" > "$jd/end_ms"
    printf '%s\n' "$status" > "$jd/exit.txt"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$job" "$cap" "$start" "$end" "$((end-start))" "$status" > "$jd/job.tsv"
    [[ $status == 0 ]] || return "$status"
    check_memory "$jd/memory.txt" "$cap"
    verify_batch_receipts "$jd/entries.txt" "$jd/compiler.stdout" "$jd/compiler.stderr" || die "compiler output stream $job"
    awk -F= '$1~/^(wall_seconds|user_seconds|system_seconds)$/ && $2~/^[0-9]+([.][0-9]+)?$/{n++} END{exit n!=3}' "$jd/cpu.tsv" || die 'missing native child CPU receipt'
    build_invariance_copy_aliases "$jd/aliases.txt"
    while IFS='|' read -r name source input out opt; do [[ -f $out && -s $out && ! -L $out ]] || die "missing output $out"; done < "$jd/cases.txt"
}

stop_owned_services() {
    local file line cg unit
    [[ -n ${PHASE:-} ]] || return 0
    for file in "$PHASE"/jobs/*/native.cgroup; do
        [[ -f $file ]] || continue
        read -r line < "$file" || continue
        cg="${line#0::}"
        while [[ $cg != / && $cg != *.service ]]; do cg=${cg%/*}; done
        unit=${cg##*/}
        if [[ $unit == run-*.service ]]; then systemctl --user stop "$unit" >> "$WORK/stop-services.log" 2>&1 || true; fi
    done
}

finish() {
    local status=$? phase
    trap - EXIT
    if [[ $status != 0 ]]; then
        [[ -z ${PHASE:-} ]] || printf 'failed_exit_%s\n' "$status" > "$PHASE/status.txt"
        if [[ ${POOL_ACTIVE:-0} == 1 ]]; then : > "$POOL/abort"; fi
        stop_owned_services
        if [[ ${POOL_ACTIVE:-0} == 1 ]]; then bounded_pool_stop "$POOL"; fi
        if [[ -n ${PHASE:-} && -f $PHASE/combined_start_ms ]]; then
            local partial_start
            read -r partial_start < "$PHASE/combined_start_ms"
            now
            printf '%s\t%s\t%s\t%s\n' "$partial_start" "$NOW" "$((NOW-partial_start))" "$status" > "$PHASE/partial-combined.tsv"
        fi
    fi
    if [[ -n ${TELEMETRY_PID:-} ]]; then
        : > "$PHASE/telemetry.stop"
        wait "$TELEMETRY_PID" || true
    fi
    printf '%s\n' "$status" > "$WORK/exit.txt"
    {
        printf 'phase\tstatus\n'
        for phase in A1-serial B1-overlap B2-overlap A2-serial; do
            printf '%s\t%s\n' "$phase" "$(cat "$WORK/trials/$phase/status.txt" 2>/dev/null || echo not_prepared)"
        done
    } > "$WORK/all-trial-status.tsv"
    exit "$status"
}

run_phase() {
    local name=$1 workers=$2 start end rel n case_name source input opt
    PHASE="$WORK/trials/$name"
    printf 'running\n' > "$PHASE/status.txt"
    if [[ $MOCK == 0 ]]; then
        [[ $(source_digest) == $SOURCE_INITIAL ]] || die 'source changed before trial'
        sha256sum -c "$WORK/compiler-sha256.txt" > "$PHASE/compiler-hash-check.txt"
    fi
    printf 'anchor_running\n' > "$PHASE/stage.txt"
    bash "$SCRIPT" --telemetry "$PHASE" "$BASHPID" &
    TELEMETRY_PID=$!
    bounded_pool_run_job anchor 4096
    [[ $MOCK == 0 ]] || workers=1
    printf '%s\n' "$workers" > "$PHASE/actual_workers.txt"
    POOL="$PHASE/pool"
    [[ $POOL == "$WORK"/trials/*/pool && ! -e $POOL ]] || die 'pool is not fresh/owned'
    bounded_pool_init "$POOL" 12288 "$PHASE/queue.txt"
    now; start=$NOW
    printf '%s\n' "$start" > "$PHASE/combined_start_ms"
    printf 'combined_running\n' > "$PHASE/stage.txt"
    POOL_ACTIVE=1
    bounded_pool_start "$POOL" "$workers"
    bounded_pool_join "$POOL"
    POOL_ACTIVE=0
    now; end=$NOW
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$workers" "$start" "$end" "$((end-start))" > "$PHASE/combined.tsv"
    : > "$PHASE/telemetry.stop"
    wait "$TELEMETRY_PID"
    TELEMETRY_PID=
    for n in 0017 0018 0019; do
        while IFS='|' read -r case_name source input opt; do
            cmp "$PHASE/jobs/opt1-built.opt2.$n/asm/$case_name.s" "$PHASE/jobs/opt2-built.opt2.$n/asm/$case_name.s"
        done < "$FIXTURES/chunk$n.cases"
    done
    if [[ $name != A1-serial ]]; then
        while IFS= read -r rel; do
            cmp "$WORK/trials/A1-serial/jobs/$rel" "$PHASE/jobs/$rel"
        done < "$PHASE/expected-outputs.txt"
    fi
    [[ $(find "$PHASE/jobs" -type f -name '*.s' | wc -l) -eq 449 ]] || die 'unexpected assembly inventory'
    if [[ $MOCK == 0 ]]; then
        [[ $(source_digest) == $SOURCE_INITIAL ]] || die 'source changed during trial'
    fi
    printf 'all_outputs_verified\n' > "$PHASE/stage.txt"
    printf 'passed\n' > "$PHASE/status.txt"
    echo "[overlap-diagnostic] $name completed $((end-start))ms; anchor/individual CPU and telemetry retained"
}

coordinator() {
    POOL_ACTIVE=0
    TELEMETRY_PID=
    PHASE=
    trap finish EXIT
    trap 'exit 124' TERM INT HUP
    validate_fixtures
    for phase in A1-serial B1-overlap B2-overlap A2-serial; do prepare_phase "$phase"; done
    PHASE=
    PERF_AVAILABLE=0
    if [[ $MOCK == 1 ]]; then
        cat > "$WORK/mock-compiler" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${PROBE_JOB_ID:-} != ${PROBE_MOCK_FAIL_JOB:-} ]] || { echo injected-failure >&2; exit 7; }
[[ $1 == compile && $2 == --batch ]]
while IFS='|' read -r input output; do
    printf 'fake assembly for %s\n' "$input" > "$output"
    printf 'Wrote %s\n' "$output"
done < "$3"
EOF
        chmod 700 "$WORK/mock-compiler"
        OPT1="$WORK/mock-compiler"; OPT2=$OPT1
        printf 'MOCK_PROTOCOL_TEST; no performance evidence; all actual worker counts1\n' > "$WORK/scope.txt"
    else
        [[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux ]] || die 'hosted-only parallel diagnostic'
        [[ ${GITHUB_BASE_REF:-} == t3/issue-7767-build-invariance-critical-path ]] || die 'wrong PR base'
        [[ $(git rev-parse HEAD^) == $FIXED_C ]] || die 'diagnostic must be one commit over fixed C'
        [[ $(git rev-parse HEAD) == ${PROBE_EXPECTED_HEAD:-} ]] || die 'checkout is not the pushed diagnostic head'
        git diff --exit-code "$FIXED_C" HEAD -- src stdlib tests scripts/lib-build-invariance-batch.sh \
            scripts/lib-bounded-pool.sh scripts/lib-native-link.sh scripts/run-memory-bounded.sh \
            scripts/lib-linux-memory-limit.sh scripts/ci-verify.sh scripts/ci-gates.tsv scripts/check-bootstrap-fixpoint.sh
        {
            git rev-parse HEAD HEAD^ HEAD^{tree}
            uname -a; lscpu; nproc; free -b
            cat /proc/self/status /proc/self/cgroup
            bash --version; as --version; ld --version
            "${PROBE_TIME_BIN:-/usr/bin/time}" --version
            printf 'SDE=not_exercised; compile-only diagnostic, no required-coverage claim\n'
        } > "$WORK/environment.txt"
        [[ $(nproc) -eq 4 ]] || die 'unexpected CPU allocation'
        awk '/^MemTotal:/{exit $2<14*1024*1024}' /proc/meminfo || die 'unexpected RAM allocation'
        env -u BASH_ENV "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 8192 \
            --timeout-seconds 1200 --report "$WORK/bootstrap.memory" -- \
            env -u BASH_ENV TYPELISP_INLINE_TEST_WORKERS=1 TYPELISP_BUILD_INVARIANCE_WORKERS=1 \
            bash "$ROOT/scripts/ci-verify.sh" --gates bootstrap-fixpoint > "$WORK/bootstrap.log" 2> "$WORK/bootstrap.stderr"
        read -r OPT2 < target/ci-verify-stage2.path
        [[ -x $OPT2 ]] || die 'no bootstrap compiler'
        . "$ROOT/scripts/lib-native-link.sh"
        native_link_detect_host; configure_toolchain
        env -u BASH_ENV "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 600 \
            --report "$WORK/opt1-build.memory" -- env -u BASH_ENV "$OPT2" compile src/main.tl \
            -o "$WORK/opt1.s" --target linux-x86_64 --cfg linux --cfg unix --cfg target-linux --cfg os-linux \
            --backend-mode scalar --opt-level 1 --stdlib-root stdlib --stdlib-root src \
            > "$WORK/opt1-build.stdout" 2> "$WORK/opt1-build.stderr"
        assemble_and_link 'diagnostic opt1' "$WORK/opt1.s" "$WORK/opt1.o" "$WORK/opt1"
        OPT1="$WORK/opt1"
        sha256sum "$OPT1" "$OPT2" > "$WORK/compiler-sha256.txt"
        printf 'C_opt1_sha256=4d2b05cf3bc582477240530f356ae764ef4b60ea657d3eb36fc8862daadce82c\n' > "$WORK/C-compiler-comparison.txt"
        printf 'probe_opt1_sha256=%s\n' "$(sha256sum "$OPT1" | cut -d' ' -f1)" >> "$WORK/C-compiler-comparison.txt"
        # All four trials must use these exact binaries. A different build path
        # or toolchain may change file metadata versus C; report it rather than
        # silently treating a cross-build hash difference as equivalent.
        if command -v perf > "$WORK/perf-path.txt" 2>&1; then
            perf --version > "$WORK/perf-version.txt" 2> "$WORK/perf-version.stderr" || true
            if env -u BASH_ENV "$ROOT/scripts/run-memory-bounded.sh" --limit-mib 256 --timeout-seconds 15 \
                --report "$WORK/perf-check.memory" -- env -u BASH_ENV perf stat -x $'\t' --no-big-num \
                -e cycles:u,instructions:u -o "$WORK/perf-check.tsv" -- true \
                > "$WORK/perf-check.stdout" 2> "$WORK/perf-check.stderr"; then
                if awk -F'\t' '$1~/^[0-9]+([.][0-9]+)?$/ && $1>0 &&
                    ($3=="cycles:u" || $3=="instructions:u") && $5+0>=90 {n++}
                    END{exit n!=2}' "$WORK/perf-check.tsv"; then PERF_AVAILABLE=1; fi
            fi
        fi
        printf 'perf_available=%s\nscope=user-only cycles/instructions if supported; native process subtree\n' "$PERF_AVAILABLE" > "$WORK/counter-scope.txt"
        printf 'DIAGNOSTIC ONLY; single hosted runner; inner1-vs2-worker scheduling; no complete-corpus latency claim\n' > "$WORK/scope.txt"
        SOURCE_INITIAL=$(source_digest)
        printf '%s\n' "$SOURCE_INITIAL" > "$WORK/source-digest-initial.txt"
    fi
    run_phase A1-serial 1
    run_phase B1-overlap 2
    run_phase B2-overlap 2
    run_phase A2-serial 1
    if [[ $MOCK == 0 ]]; then
        sha256sum -c "$WORK/compiler-sha256.txt" > "$WORK/compiler-hash-recheck.txt"
        git diff --exit-code HEAD -- src stdlib tests > "$WORK/source-recheck.txt"
    fi
    validate_fixtures
    printf 'all_four_trials_and_anchors_passed_exact_output_checks\n' > "$WORK/verification.txt"
}

if [[ $MODE == --coordinator ]]; then
    WORK=$4
    coordinator
    exit
fi
mkdir -p "$ROOT/target"
[[ $(CDPATH= cd -- "$ROOT/target" && pwd -P) == "$ROOT/target" ]] || die 'target escapes checkout'
WORK=$(mktemp -d "$ROOT/target/issue7767-overlap.XXXXXX")
echo "[overlap-diagnostic] evidence=$WORK"
[[ -z ${GITHUB_OUTPUT:-} ]] || printf 'evidence=%s\n' "$WORK" >> "$GITHUB_OUTPUT"
if [[ $MODE == --validate ]]; then
    validate_fixtures
    for phase in A1-serial B1-overlap B2-overlap A2-serial; do prepare_phase "$phase"; done
    printf 'metadata_and_queues_validated; no compiler processes\n' > "$WORK/validation.txt"
elif [[ $MOCK == 1 ]]; then
    coordinator
else
    # Foreground mode signals the coordinator, whose EXIT path stops exact
    # owned services and drains workers. No timed-out job is retried.
    timeout --foreground --signal=TERM --kill-after=660s 3900s \
        env -u BASH_ENV bash "$SCRIPT" --coordinator "$ROOT" "$FIXTURES" "$WORK"
fi
