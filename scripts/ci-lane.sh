#!/usr/bin/env sh
set -eu

# ci-lane.sh - the CI lanes of scripts/ci-lanes.tsv (#7767 slice 2, D-C42).
#
#   scripts/ci-lane.sh check
#   scripts/ci-lane.sh setup LANE
#   scripts/ci-lane.sh aggregate HOST LANES_RESULT DOWNLOADS JOBS ARTIFACTS DIGESTS OUT
#
# check validates the assignment against scripts/ci-verify.sh --list-gates of
# both hosts: every gate has exactly one owning lane, every closure duplicate
# is declared, there are at most two lanes per host, and the self_compile
# ledger names the job that runs linux-self-compile-measurement.
#
# setup prints a lane job's configuration as KEY=VALUE lines: the gates it
# owns (for scripts/ci-verify.sh --gates), whether it needs the Linux
# instruction-count tools or runs the self_compile check, and its
# build-invariance worker count: three only when no other gate can run beside
# build-invariance in that lane, otherwise the script default.
#
# aggregate is a host's required check. LANES_RESULT is the lane jobs' needs
# result, DOWNLOADS holds the downloaded lane envelopes, JOBS and ARTIFACTS are
# the run's all-attempt job and artifact listings, and DIGESTS has one
# `LANE<TAB>DIGEST` line per lane job output. For each lane of HOST it binds
# the attempt that executed the lane job, reads that attempt's envelope back
# against the trusted context (scripts/ci-compiler-artifact.sh verify), and
# requires its receipt to plan and pass exactly the lane's assigned gates and
# their closure. It then requires one converged-compiler identity across the
# lanes (and one compile-profile compiler where two lanes build it), records
# each lane's seed, and writes OUT/HOST.tsv, the merged ci-timing artifact with
# the complete-verification row, and OUT/coverage.json. Anything else fails.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
LANES_FILE=$ROOT/scripts/ci-lanes.tsv
LANES_PER_HOST=2
BUILD_INVARIANCE=stage2-opt1-opt2-build-invariance
SELF_COMPILE=linux-self-compile-measurement
TAB=$(printf '\t')

lane_fail() {
    echo "[ci-lane] $*" >&2
    exit 1
}

usage() {
    sed -n '/^#   scripts/s/^# *//p' "$0" >&2
    exit 2
}

# Scratch beside the other CI tooling scratch, never removed by this script.
mkdir -p "$ROOT/target/exp"
LANE_WORK=$(mktemp -d "$ROOT/target/exp/ci-lane.XXXXXX")

# lane_inventory HOST: id, label and needs of the validated host table.
lane_inventory() {
    "$ROOT/scripts/ci-verify.sh" --list-gates "$1" > "$LANE_WORK/list-$1.tsv" || exit 1
    sed 1d "$LANE_WORK/list-$1.tsv" | cut -f 1,3,4
}

# lane_closure HOST ID,...: the planned gate IDs, in table order.
lane_closure() {
    "$ROOT/scripts/ci-verify.sh" --list-gates "$1" --gates "$2" > "$LANE_WORK/closure.tsv" || exit 1
    sed 1d "$LANE_WORK/closure.tsv" | cut -f 1
}

# lane_check: validate the assignment and write $LANE_WORK/cells.tsv
# (host, id, owner, declared duplicate lanes or -, label; table order) and
# $LANE_WORK/lanes.tsv (host, lane, owned IDs, planned IDs; comma lists).
lane_check() {
    lane_inventory linux > "$LANE_WORK/linux.inv"
    lane_inventory windows > "$LANE_WORK/windows.inv"
    awk -F '\t' -v max="$LANES_PER_HOST" '
        function fail(message) {
            print "ci-lanes.tsv: " message > "/dev/stderr"
            bad = 1
            exit 1
        }
        { sub(/\r$/, "") }
        FILENAME == ARGV[1] || FILENAME == ARGV[2] {
            host = (FILENAME == ARGV[1] ? "linux" : "windows")
            on[host, $1] = 1
            order[host, ++rows[host]] = $1
            label[host, $1] = $2
            if (labels[host, $2]++) fail("duplicate " host " gate label: " $2)
            next
        }
        /^#/ { next }
        !header {
            if ($0 != "id\tlinux\twindows") fail("line " FNR ": expected the id/linux/windows header")
            header = 1
            next
        }
        {
            if (NF != 3) fail("line " FNR ": expected three fields")
            if (seen[$1]++) fail("line " FNR ": gate assigned twice: " $1)
            if (!on["linux", $1] && !on["windows", $1]) fail("line " FNR ": unknown gate: " $1)
            for (c = 2; c <= 3; c++) {
                host = (c == 2 ? "linux" : "windows")
                if ($c == "-") {
                    if (on[host, $1]) fail("line " FNR ": " $1 " runs on " host " but no lane owns it")
                    continue
                }
                if (!on[host, $1]) fail("line " FNR ": " $1 " does not run on " host ": " $c)
                n = split($c, part, "+")
                dups = "-"
                for (k = 1; k <= n; k++) {
                    if (part[k] !~ ("^" host "-[1-9]$")) fail("line " FNR ": invalid " host " lane: " part[k])
                    if (used[$1, host, part[k]]++) fail("line " FNR ": " $1 " names lane " part[k] " twice")
                    if (k > 1) dups = (dups == "-" ? part[k] : dups "," part[k])
                    else owns[host, part[k]] = 1
                    if (!((host, part[k]) in lane)) { lane[host, part[k]] = 1; lanes[host]++ }
                }
                owner[host, $1] = part[1]
                dup[host, $1] = dups
            }
        }
        END {
            if (bad) exit 1
            if (!header) fail("missing the id/linux/windows header")
            for (h = 1; h <= 2; h++) {
                host = (h == 1 ? "linux" : "windows")
                if (lanes[host] > max) fail("more than " max " " host " lanes")
                for (key in lane) {
                    split(key, part, SUBSEP)
                    if (part[1] == host && !owns[host, part[2]]) fail("lane " part[2] " owns no gate")
                }
                for (k = 1; k <= rows[host]; k++) {
                    id = order[host, k]
                    if (!seen[id]) fail("unassigned gate: " id)
                    print host "\t" id "\t" owner[host, id] "\t" dup[host, id] "\t" label[host, id]
                }
            }
        }' "$LANE_WORK/linux.inv" "$LANE_WORK/windows.inv" "$LANES_FILE" > "$LANE_WORK/cells.tsv" || exit 1
    : > "$LANE_WORK/lanes.tsv"
    for _lc_host in linux windows; do
        for _lc_lane in $(awk -F '\t' -v h="$_lc_host" '$1 == h { print $3 }' "$LANE_WORK/cells.tsv" | sort -u); do
            _lc_owned=$(awk -F '\t' -v h="$_lc_host" -v l="$_lc_lane" '$1 == h && $3 == l { print $2 }' "$LANE_WORK/cells.tsv" | paste -sd, -)
            lane_closure "$_lc_host" "$_lc_owned" > "$LANE_WORK/planned"
            awk -F '\t' -v h="$_lc_host" -v l="$_lc_lane" '$1 == h && $3 != l && index("," $4 ",", "," l ",") { print $2 }' \
                "$LANE_WORK/cells.tsv" | LC_ALL=C sort > "$LANE_WORK/declared"
            printf '%s\n' "$_lc_owned" | tr ',' '\n' | LC_ALL=C sort > "$LANE_WORK/owned-sorted"
            LC_ALL=C sort "$LANE_WORK/planned" | LC_ALL=C comm -23 - "$LANE_WORK/owned-sorted" > "$LANE_WORK/needed"
            if ! cmp -s "$LANE_WORK/declared" "$LANE_WORK/needed"; then
                echo "ci-lanes.tsv: lane $_lc_lane runs exactly these unowned needs; declare them as +$_lc_lane:" >&2
                sed 's/^/  /' "$LANE_WORK/needed" >&2
                echo "ci-lanes.tsv: lane $_lc_lane declares:" >&2
                sed 's/^/  /' "$LANE_WORK/declared" >&2
                exit 1
            fi
            printf '%s\t%s\t%s\t%s\n' "$_lc_host" "$_lc_lane" "$_lc_owned" "$(paste -sd, - < "$LANE_WORK/planned")" >> "$LANE_WORK/lanes.tsv"
        done
    done
    # The self_compile ledger attributes a merge to the job that ran the
    # measurement and uploaded its artifact (scripts/lib-self-compile.sh).
    _lc_sc_lane=$(awk -F '\t' -v id="$SELF_COMPILE" '$1 == "linux" && $2 == id { print $3 }' "$LANE_WORK/cells.tsv")
    if [ -n "$_lc_sc_lane" ]; then
        _lc_sc_job=$(. "$ROOT/scripts/lib-self-compile.sh" && printf '%s\n' "$SC_CI_JOB_NAME")
        [ "$_lc_sc_job" = "CI lane $_lc_sc_lane" ] ||
            lane_fail "$SELF_COMPILE runs in CI lane $_lc_sc_lane, but SC_CI_JOB_NAME names '$_lc_sc_job'"
    fi
}

lane_host() {
    case "$1" in
        linux-[1-9]) printf 'linux\n' ;;
        windows-[1-9]) printf 'windows\n' ;;
        *) lane_fail "invalid lane: $1" ;;
    esac
}

lane_field() {
    awk -F '\t' -v l="$1" -v f="$2" '$2 == l { print $f; found = 1 } END { exit found ? 0 : 1 }' "$LANE_WORK/lanes.tsv" ||
        lane_fail "scripts/ci-lanes.tsv assigns no gate to lane $1"
}

lane_setup() {
    _ls_host=$(lane_host "$1")
    lane_check
    _ls_owned=$(lane_field "$1" 3)
    _ls_planned=$(lane_field "$1" 4)
    _ls_tools=0
    for _ls_gate in $(awk -F '\t' -v h="$_ls_host" '!/^#/ && $1 == "valgrind" && ($2 == "all" || $2 == h) { print $3 }' \
        "$ROOT/scripts/ci-host-tools.tsv" | tr ',' ' '); do
        case ",$_ls_planned," in *",$_ls_gate,"*) _ls_tools=1 ;; esac
    done
    _ls_self_compile=0
    case ",$_ls_planned," in *",$SELF_COMPILE,"*) _ls_self_compile=1 ;; esac
    # Isolated: every other planned gate is a need of build-invariance or
    # needs it, so none can run beside its pool.
    _ls_workers=
    case ",$_ls_planned," in
        *",$BUILD_INVARIANCE,"*)
            _ls_workers=3
            _ls_ancestors=,$(lane_closure "$_ls_host" "$BUILD_INVARIANCE" | paste -sd, -),
            for _ls_gate in $(printf '%s\n' "$_ls_planned" | tr ',' ' '); do
                case "$_ls_ancestors" in *",$_ls_gate,"*) continue ;; esac
                lane_closure "$_ls_host" "$_ls_gate" | grep -qxF "$BUILD_INVARIANCE" || _ls_workers=
            done
            ;;
    esac
    printf 'lane=%s\ngates=%s\ninstruction_tools=%s\nself_compile=%s\nbuild_invariance_workers=%s\n' \
        "$1" "$_ls_owned" "$_ls_tools" "$_ls_self_compile" "$_ls_workers"
}

# The latest executed instance of a job: a "Re-run failed jobs" copy keeps
# the original start, completion and runner (scripts/lib-self-compile.sh).
LANE_JQ_EXECUTED='def executed(j):
    if (j|length) > 1 and j[-1].started_at != null and j[-1].started_at == j[-2].started_at and
       j[-1].completed_at == j[-2].completed_at and j[-1].runner_name == j[-2].runner_name
    then executed(j[:-1]) else j[-1] end;'

lane_aggregate() {
    [ "$#" -eq 7 ] || usage
    _la_host=$1 _la_result=$2 _la_downloads=$3 _la_jobs=$4 _la_artifacts=$5 _la_digests=$6 _la_out=$7
    case "$_la_host" in linux | windows) ;; *) lane_fail "invalid host: $_la_host" ;; esac
    [ "$_la_result" = success ] || lane_fail "the lane jobs did not all succeed (needs result: ${_la_result:-none})"
    [ "${GITHUB_ACTIONS:-}" = true ] || lane_fail 'aggregate runs only in GitHub Actions'
    case "${GITHUB_RUN_ID:-}:${GITHUB_RUN_ATTEMPT:-}" in
        *[!0-9:]* | :* | *:) lane_fail 'run id/attempt missing' ;;
    esac
    lane_check
    mkdir -p "$_la_out"
    _la_lanes=$(awk -F '\t' -v h="$_la_host" '$1 == h { print $2 }' "$LANE_WORK/lanes.tsv")
    [ -n "$_la_lanes" ] || lane_fail "no $_la_host lanes"
    : > "$LANE_WORK/proof-lanes.jsonl"
    : > "$LANE_WORK/timing-args"
    for _la_lane in $_la_lanes; do
        _la_job="CI lane $_la_lane"
        _la_state=$(jq -r --arg n "$_la_job" --argjson run "$GITHUB_RUN_ID" "$LANE_JQ_EXECUTED"'
            [.jobs[] | select(.name == $n and .run_id == $run)] | sort_by(.run_attempt)
            | if length == 0 or ([.[].run_attempt] | unique | length) != length then empty
              else executed(.) | [(.run_attempt | tostring), .status, (.conclusion // "")] | @tsv end' "$_la_jobs" | tr -d '\r')
        [ -n "$_la_state" ] || lane_fail "$_la_job has no single instance per attempt in this run"
        _la_attempt=$(printf '%s\n' "$_la_state" | cut -f 1)
        [ "$(printf '%s\n' "$_la_state" | cut -f 2-3)" = "completed${TAB}success" ] ||
            lane_fail "$_la_job did not succeed in attempt $_la_attempt: $(printf '%s' "$_la_state" | cut -f 2-3 | tr '\t' ' ')"
        [ "$_la_attempt" -le "$GITHUB_RUN_ATTEMPT" ] || lane_fail "$_la_job attempt $_la_attempt is later than this run attempt"
        _la_name=ci-stage-envelope-$_la_lane-r$GITHUB_RUN_ID-a$_la_attempt
        _la_bundle=$_la_downloads/$_la_name
        [ -d "$_la_bundle" ] || lane_fail "missing envelope $_la_name for the attempt that executed $_la_job"
        _la_digest=$(awk -F '\t' -v l="$_la_lane" '$1 == l { print $2 }' "$_la_digests")
        "$ROOT/scripts/ci-compiler-artifact.sh" verify "$ROOT" "$_la_bundle" "$_la_host" "$_la_digest" \
            "$_la_jobs" "$_la_artifacts" "$_la_lane" "$_la_attempt" > "$_la_out/readback-$_la_lane.json" ||
            lane_fail "envelope readback failed for $_la_job attempt $_la_attempt"
        # The receipt must be this lane's assignment and its needs closure.
        lane_field "$_la_lane" 3 | tr ',' '\n' | LC_ALL=C sort > "$LANE_WORK/owned-$_la_lane"
        lane_field "$_la_lane" 4 | tr ',' '\n' > "$LANE_WORK/planned-$_la_lane"
        cmp -s "$LANE_WORK/owned-$_la_lane" "$_la_bundle/lane/requested.txt" ||
            lane_fail "$_la_job requested gates other than the ones scripts/ci-lanes.tsv assigns it"
        cmp -s "$LANE_WORK/planned-$_la_lane" "$_la_bundle/lane/plan.txt" ||
            lane_fail "$_la_job planned gates other than its assignment's needs closure"
        printf '%s\t%s\t%s\n' "$_la_lane" "$LANE_WORK/planned-$_la_lane" "$_la_bundle/lane/timing.tsv" >> "$LANE_WORK/timing-args"
        _la_seed='null'
        _la_role=$_la_bundle/roles/bootstrap-converged/manifest.json
        [ ! -f "$_la_role" ] || _la_seed=$(jq -c .proof.seed "$_la_role")
        jq -cn --arg lane "$_la_lane" --arg job "$_la_job" --argjson attempt "$_la_attempt" --arg digest "$_la_digest" \
            --argjson seed "$_la_seed" --rawfile owned "$LANE_WORK/owned-$_la_lane" --rawfile planned "$LANE_WORK/planned-$_la_lane" \
            --rawfile handoffs "$_la_bundle/lane/handoffs.tsv" '
            ($owned | split("\n") | map(select(length > 0))) as $o |
            ($planned | split("\n") | map(select(length > 0))) as $p |
            {lane: $lane, job: $job, attempt: $attempt, bundle_sha256: $digest, seed: $seed,
             owned: ($o | length), planned: ($p | length), duplicates: ($p - $o),
             handoffs: ($handoffs | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: {sha256: .[1], identity_sha256: .[2]}}) | from_entries)}' \
            >> "$LANE_WORK/proof-lanes.jsonl"
    done
    # Every host gate passed in its owning lane: the readback proved each
    # receipt passes exactly its plan, and the plans cover the owners.
    awk -F '\t' -v h="$_la_host" '$1 == h { print $2 "\t" $3 "\t" $5 }' "$LANE_WORK/cells.tsv" > "$LANE_WORK/gates.tsv"
    while IFS=$TAB read -r _la_id _la_owner _la_label; do
        grep -qxF "$_la_id" "$LANE_WORK/planned-$_la_owner" 2>/dev/null ||
            lane_fail "$_la_id is not in the receipt of its owning lane $_la_owner"
    done < "$LANE_WORK/gates.tsv"
    jq -s '.' "$LANE_WORK/proof-lanes.jsonl" > "$LANE_WORK/proof-lanes.json"
    # One converged compiler across lanes, whatever their seeds; a mismatch
    # is a determinism defect, never a reason to retry.
    jq -e '[.[] | select(.handoffs.converged) | .handoffs.converged.identity_sha256] | length >= 1 and (unique | length) == 1' \
        "$LANE_WORK/proof-lanes.json" > /dev/null || {
        jq -r '.[] | "[ci-lane]   \(.lane): converged \(.handoffs.converged.identity_sha256 // "none") seed \(.seed.sha256 // "none")"' \
            "$LANE_WORK/proof-lanes.json" >&2
        lane_fail "stage2 identity differs between $_la_host lanes: a determinism defect (do not re-run it away)"
    }
    jq -e '[.[] | select(.handoffs["compile-profile"]) | .handoffs["compile-profile"].identity_sha256] | (unique | length) <= 1' \
        "$LANE_WORK/proof-lanes.json" > /dev/null ||
        lane_fail "compile-profile compiler identity differs between $_la_host lanes"
    lane_merge_timing "$_la_host" "$LANE_WORK/gates.tsv" "$LANE_WORK/timing-args" > "$_la_out/$_la_host.tsv"
    jq -n --arg host "$_la_host" --arg run "$GITHUB_RUN_ID" --argjson attempt "$GITHUB_RUN_ATTEMPT" \
        --arg commit "$(git rev-parse HEAD)" --arg tree "$(git rev-parse 'HEAD^{tree}')" \
        --arg head "$(jq -r .pull_request.head.sha "$GITHUB_EVENT_PATH")" --argjson gates "$(awk 'END { print NR }' "$LANE_WORK/gates.tsv")" \
        --slurpfile lanes "$LANE_WORK/proof-lanes.json" '
        {schema: "typelisp-ci-lane-coverage/1", host: $host, run_id: $run, attempt: $attempt, commit: $commit, tree: $tree, head: $head,
         gates: $gates, lanes: $lanes[0], stage2_identity_sha256: ($lanes[0] | map(select(.handoffs.converged)) | .[0].handoffs.converged.identity_sha256),
         seeds: ($lanes[0] | map(.seed.sha256 // empty) | unique), status: "pass"}' > "$_la_out/coverage.json"
    echo "[ci-lane] $_la_host: $(awk 'END { print NR }' "$LANE_WORK/gates.tsv") gates passed in their owning lanes ($(printf '%s ' $_la_lanes)); one converged compiler"
}

# lane_merge_timing HOST GATES ARGS: the host's ci-timing rows in table order,
# each gate's rows from its owning lane, the lanes' ungated rows first and one
# complete-verification row (the slowest lane's partial-verification time).
lane_merge_timing() {
    _lm_host=$1 _lm_args=$3
    _lm_lanes=
    set -- "$2"
    while IFS=$TAB read -r _lm_lane _lm_plan _lm_timing; do
        _lm_lanes="$_lm_lanes $_lm_lane"
        set -- "$@" "$_lm_plan" "$_lm_timing"
    done < "$_lm_args"
    awk -F '\t' -v host="$_lm_host" -v lanes="$_lm_lanes" '
        function fail(message) {
            print "[ci-lane] timing: " message > "/dev/stderr"
            bad = 1
            exit 1
        }
        BEGIN { count = split(lanes, lane, " ") }
        { sub(/\r$/, "") }
        FNR == 1 { file++ }
        file == 1 { order[++gates] = $1; owner[$1] = $2; label_of[$1] = $3; next }
        file % 2 == 0 { l = lane[file / 2]; planned_id[l, label_of[$1]] = $1; next }
        {
            l = lane[(file - 1) / 2]
            if (FNR == 1) {
                if ($0 != "gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost") fail(l " header changed")
                next
            }
            if (NF != 6 || $6 != host) fail(l " row is not a " host " timing row: " $0)
            if ($1 == "ungated") { ungated[++u] = $0; next }
            if ($1 == "CI verification") {
                if ($2 != "all" || $3 != "partial-verification" || $4 !~ /^[0-9]+$/ || (l in partial))
                    fail(l " has an unexpected verification row: " $0)
                partial[l] = $4
                next
            }
            if (!((l, $1) in planned_id)) fail(l " has rows of a gate it did not plan: " $1)
            id = planned_id[l, $1]
            if (owner[id] != l) next
            rows[id, ++n[id]] = $0
            if ($2 == "all" && $3 == "gate" && $5 == "0") passed[id] = 1
        }
        END {
            if (bad) exit 1
            for (k = 1; k <= count; k++) if (!(lane[k] in partial)) fail(lane[k] " has no partial-verification row")
            print "gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost"
            for (k = 1; k <= u; k++) print ungated[k]
            for (g = 1; g <= gates; g++) {
                id = order[g]
                if (!passed[id]) fail(id " has no passing gate row in its owning lane " owner[id])
                for (k = 1; k <= n[id]; k++) print rows[id, k]
            }
            longest = 0
            for (k = 1; k <= count; k++) if (partial[lane[k]] + 0 > longest) longest = partial[lane[k]] + 0
            print "CI verification\tall\tcomplete-verification\t" longest "\t0\t" host
        }' "$@"
}

case "${1:-}" in
    check)
        [ "$#" -eq 1 ] || usage
        lane_check
        echo "[ci-lane] scripts/ci-lanes.tsv assigns every gate of both hosts to exactly one lane"
        ;;
    setup)
        [ "$#" -eq 2 ] || usage
        lane_setup "$2"
        ;;
    aggregate)
        shift
        lane_aggregate "$@"
        ;;
    *) usage ;;
esac
