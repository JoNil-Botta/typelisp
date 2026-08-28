#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RECENT=${CI_TIMING_TREND_RECENT:-3}
BASELINE=${CI_TIMING_TREND_BASELINE:-20}
FACTOR=${CI_TIMING_TREND_FACTOR:-1.5}
MIN_MS=${CI_TIMING_TREND_MIN_MS:-250}
MIN_DELTA_MS=${CI_TIMING_TREND_MIN_DELTA_MS:-250}
BASELINE_PERCENTILE=${CI_TIMING_TREND_BASELINE_PERCENTILE:-95}
RUN_LIMIT=${CI_TIMING_TREND_RUN_LIMIT:-100}
POLICY=${CI_TIMING_TREND_POLICY:-scripts/ci-timing-trend-policy.tsv}
# Gates whose cost is already governed by an explicit cap in
# scripts/check-ci-timing-budgets.sh. This analyzer has no notion of an accepted
# cost -- it compares medians -- so a gate we have investigated and accepted
# would be re-flagged on every report, and the next reader would repeat the
# bisect. A cap says the same thing in a form that can also fail, so the two
# mechanisms are exclusive: a gate belongs to exactly one of them, and adding a
# name here means adding a cap there (#5660, #5778).
DEFAULT_DENYLIST='stage2 opt1/opt2 build-invariance
stage2 CLI host-action smoke'
DENYLIST=${CI_TIMING_TREND_DENYLIST:-$DEFAULT_DENYLIST}
ISSUE_TITLE="CI timing sustained regression alert"
MARKER="<!-- typelisp-ci-timing-trends-v1 -->"
HEADER='head_sha	run_id	run_url	created_at	gate	case_or_chunk	phase	elapsed_ms	exit	host'

usage() {
    cat >&2 <<'EOF'
usage: scripts/analyze-ci-timing-trends.sh --offline HISTORY.tsv REPORT.md
       scripts/analyze-ci-timing-trends.sh --collect OWNER/REPO WORKDIR
       scripts/analyze-ci-timing-trends.sh --print-default-denylist
       scripts/analyze-ci-timing-trends.sh --self-test

History schema:
  head_sha run_id run_url created_at gate case_or_chunk phase elapsed_ms exit host

Configuration: CI_TIMING_TREND_RECENT (3), CI_TIMING_TREND_BASELINE (20),
CI_TIMING_TREND_FACTOR (1.5), CI_TIMING_TREND_MIN_MS (250),
CI_TIMING_TREND_MIN_DELTA_MS (250),
CI_TIMING_TREND_BASELINE_PERCENTILE (95, nearest-rank),
CI_TIMING_TREND_RUN_LIMIT (100),
CI_TIMING_TREND_POLICY (scripts/ci-timing-trend-policy.tsv),
and CI_TIMING_TREND_DENYLIST (newline-separated gate names).
EOF
}

validate_config() {
    case "$RECENT:$BASELINE:$RUN_LIMIT" in
        *[!0-9:]* | 0:* | *:0:* | *:0)
            echo "[ci-timing-trend] windows and run limit must be positive integers" >&2
            return 2
            ;;
    esac
    awk -v factor="$FACTOR" 'BEGIN {
        if (factor !~ /^[0-9]+([.][0-9]+)?$/ || factor <= 1) exit 1
    }' || {
        echo "[ci-timing-trend] factor must be numeric and greater than 1" >&2
        return 2
    }
    case "$MIN_MS" in
        *[!0-9]* | '')
            echo "[ci-timing-trend] minimum duration must be a non-negative integer" >&2
            return 2
            ;;
    esac
    case "$MIN_DELTA_MS" in
        *[!0-9]* | '')
            echo "[ci-timing-trend] minimum delta must be a non-negative integer" >&2
            return 2
            ;;
    esac
    case "$BASELINE_PERCENTILE" in
        *[!0-9]* | '')
            echo "[ci-timing-trend] baseline percentile must be an integer from 50 to 100" >&2
            return 2
            ;;
    esac
    if [ "$BASELINE_PERCENTILE" -lt 50 ] || [ "$BASELINE_PERCENTILE" -gt 100 ]; then
        echo "[ci-timing-trend] baseline percentile must be an integer from 50 to 100" >&2
        return 2
    fi
    required=$((RECENT + BASELINE))
    if [ "$RUN_LIMIT" -lt "$required" ]; then
        echo "[ci-timing-trend] run limit $RUN_LIMIT is smaller than required history $required" >&2
        return 2
    fi
}

validate_policy() {
    [ -s "$POLICY" ] || {
        echo "[ci-timing-trend] policy is missing or empty: $POLICY" >&2
        return 1
    }
    awk -F '\t' -v denylist="$DENYLIST" '
        function fail(message) {
            print "[ci-timing-trend] policy row " FNR ": " message > "/dev/stderr"
            bad = 1
        }
        function pattern_valid(value) {
            return value == "*" || value ~ /^[^*]+[*]?$/
        }
        function pattern_overlap(left, right, lprefix, rprefix) {
            if (left == "*" || right == "*") return 1
            lprefix = substr(left, length(left), 1) == "*"
            rprefix = substr(right, length(right), 1) == "*"
            if (!lprefix && !rprefix) return left == right
            if (lprefix) left = substr(left, 1, length(left) - 1)
            if (rprefix) right = substr(right, 1, length(right) - 1)
            if (lprefix && rprefix) {
                return index(left, right) == 1 || index(right, left) == 1
            }
            if (lprefix) return index(right, left) == 1
            return index(left, right) == 1
        }
        BEGIN {
            count = split(denylist, denied_name, "\n")
            for (i = 1; i <= count; i++) denied[denied_name[i]] = 1
        }
        FNR == 1 {
            sub(/\r$/, "")
            if ($0 != "# ci-timing-trend-policy-schema\t1") {
                fail("invalid schema marker")
            }
            next
        }
        FNR == 2 {
            sub(/\r$/, "")
            if ($0 != "kind\tgate\tcase_or_chunk\tphase\tfactor\tmin_delta_ms\tmin_baseline_ms\tchange_ref\tevidence_url") {
                fail("invalid header")
            }
            next
        }
        {
            sub(/\r$/, "", $9)
            if (NF != 9) { fail("expected 9 tab-separated fields"); next }
            if ($1 != "trend") fail("unknown policy kind " $1)
            if ($2 == "" || $2 ~ /[*]/) fail("gate must be an exact nonempty name")
            if (!pattern_valid($3) || !pattern_valid($4)) {
                fail("case and phase must be exact or a trailing-prefix wildcard")
            }
            if ($5 !~ /^[0-9]+([.][0-9]+)?$/ || $5 <= 1 || $5 > 1.5) {
                fail("factor must be greater than 1 and at most 1.5")
            }
            if ($6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/ || $7 == 0) {
                fail("minimums must be non-negative integers with a positive baseline")
            }
            if ($8 !~ /^#[0-9]+$/) fail("change_ref must name an issue or PR")
            if ($9 !~ /^https:\/\/github.com\/JoNil-Botta\/typelisp\/(actions\/runs|issues|pull)\//) {
                fail("evidence_url must link measured project evidence")
            }
            if ($2 in denied) fail("denylisted gate also has trend policy: " $2)
            for (i = 1; i <= rows; i++) {
                if ($2 == gate[i] && pattern_overlap($3, case_pattern[i]) &&
                        pattern_overlap($4, phase_pattern[i])) {
                    if ($3 == case_pattern[i] && $4 == phase_pattern[i]) {
                        fail("duplicate selector")
                    } else {
                        fail("overlapping selector with policy row " (i + 2))
                    }
                }
            }
            rows++
            gate[rows] = $2
            case_pattern[rows] = $3
            phase_pattern[rows] = $4
        }
        END {
            if (FNR < 3 || rows == 0) {
                print "[ci-timing-trend] policy contains no trend rows" > "/dev/stderr"
                bad = 1
            }
            exit bad ? 1 : 0
        }
    ' "$POLICY"
}

validate_history() {
    file=$1
    [ -s "$file" ] || {
        echo "[ci-timing-trend] history is missing or empty: $file" >&2
        return 1
    }
    awk -F '\t' -v header="$HEADER" '
        NR == 1 { sub(/\r$/, ""); if ($0 != header) exit 2; next }
        {
            sub(/\r$/, "", $10)
            if (NF != 10 || $1 == "" || $2 !~ /^[0-9]+$/ ||
                    $3 !~ /^https:\/\// || $4 == "" || $5 == "" ||
                    $8 !~ /^[0-9]+$/ || $9 !~ /^-?[0-9]+$/ ||
                    ($10 != "linux" && $10 != "windows" &&
                    $10 != "all-hosts")) exit 3
        }
        END { if (NR < 2) exit 4 }
    ' "$file" || {
        echo "[ci-timing-trend] malformed history: $file" >&2
        return 1
    }
}

analyze() {
    history=$1
    report=$2
    validate_config || return
    validate_policy || return
    validate_history "$history" || return
    workdir=$(dirname -- "$report")
    mkdir -p "$workdir"
    tab=$(printf '\t')
    sorted="$report.sorted"
    tail -n +2 "$history" |
        sort -t "$tab" -k4,4r -k2,2nr -k10,10 -k5,5 -k6,6 -k7,7 > "$sorted"

    awk -F '\t' -v recent="$RECENT" -v baseline="$BASELINE" \
        -v factor="$FACTOR" -v min_ms="$MIN_MS" \
        -v min_delta_ms="$MIN_DELTA_MS" -v policy_file="$POLICY" \
        -v baseline_percentile="$BASELINE_PERCENTILE" \
        -v denylist="$DENYLIST" -v marker="$MARKER" '
        function denied(gate, n, i, rows) {
            n = split(denylist, rows, "\n")
            for (i = 1; i <= n; i++) if (gate == rows[i]) return 1
            return 0
        }
        function key_sort(n, i, j, tmp) {
            for (i = 2; i <= n; i++) {
                tmp = keys[i]; j = i - 1
                while (j > 0 && keys[j] > tmp) {
                    keys[j + 1] = keys[j]; j--
                }
                keys[j + 1] = tmp
            }
        }
        function pattern_match(pattern, value) {
            if (pattern == "*") return 1
            if (substr(pattern, length(pattern), 1) == "*") {
                return index(value, substr(pattern, 1, length(pattern) - 1)) == 1
            }
            return pattern == value
        }
        function find_policy(gate, case_name, phase, i) {
            for (i = 1; i <= policy_count; i++) {
                if (policy_gate[i] == gate &&
                        pattern_match(policy_case[i], case_name) &&
                        pattern_match(policy_phase[i], phase)) return i
            }
            return 0
        }
        function median(key, start, count, i, j, tmp) {
            delete work
            for (i = 1; i <= count; i++) work[i] = value[key, start + i - 1]
            for (i = 2; i <= count; i++) {
                tmp = work[i]; j = i - 1
                while (j > 0 && work[j] > tmp) {
                    work[j + 1] = work[j]; j--
                }
                work[j + 1] = tmp
            }
            if (count % 2) return work[int(count / 2) + 1]
            return (work[count / 2] + work[count / 2 + 1]) / 2
        }
        function percentile(key, start, count, percent, i, j, rank, tmp) {
            delete work
            for (i = 1; i <= count; i++) work[i] = value[key, start + i - 1]
            for (i = 2; i <= count; i++) {
                tmp = work[i]; j = i - 1
                while (j > 0 && work[j] > tmp) {
                    work[j + 1] = work[j]; j--
                }
                work[j + 1] = tmp
            }
            rank = int((percent * count + 99) / 100)
            return work[rank]
        }
        FILENAME == policy_file {
            if (FNR <= 2) next
            policy_count++
            policy_gate[policy_count] = $2
            policy_case[policy_count] = $3
            policy_phase[policy_count] = $4
            policy_factor[policy_count] = $5 + 0
            policy_delta[policy_count] = $6 + 0
            policy_minimum[policy_count] = $7 + 0
            next
        }
        {
            if (!seen_head[$1]++) {
                heads++
                head_rank[$1] = heads
            }
            rank = head_rank[$1]
            selected_policy = find_policy($5, $6, $7)
            top_level = $6 == "all" && $7 == "gate"
            if (rank > recent + baseline || (!top_level && !selected_policy) ||
                    $9 != "0" || denied($5)) next
            key = $10 SUBSEP $5 SUBSEP $6 SUBSEP $7
            if (!known[key]++) keys[++key_count] = key
            if (selected_policy) {
                series_factor[key] = policy_factor[selected_policy]
                series_delta[key] = policy_delta[selected_policy]
                series_minimum[key] = policy_minimum[selected_policy]
                series_policy[key] = "policy"
            } else {
                series_factor[key] = factor
                series_delta[key] = min_delta_ms
                series_minimum[key] = min_ms
                series_policy[key] = "default"
            }
            if (!seen_value[key, rank]++) {
                value[key, rank] = $8 + 0
                url[key, rank] = $3
                run[key, rank] = $2
                count[key]++
            }
        }
        END {
            key_sort(key_count)
            print marker
            print "# CI timing trend report"
            print ""
            print "Recent window: **" recent "**; preceding baseline: **" baseline \
                "**; default alert factor: **" factor "x**; default minimum " \
                "delta/duration: **" min_delta_ms " ms / " min_ms \
                " ms**; baseline dispersion guard: **nearest-rank P" \
                baseline_percentile "**. Exact policy rows override the defaults."
            print ""
            for (i = 1; i <= key_count; i++) {
                key = keys[i]
                if (count[key] != recent + baseline) {
                    insufficient[++insufficient_count] = key
                    continue
                }
                base = median(key, recent + 1, baseline)
                now = median(key, 1, recent)
                guard = percentile(key, recent + 1, baseline, baseline_percentile)
                base_median[key] = base
                recent_median[key] = now
                baseline_guard[key] = guard
                if (base == 0) {
                    if (now > 0) zero_filtered[++zero_filtered_count] = key
                    continue
                }
                ratio = now / base
                ratios[key] = ratio
                if (ratio <= series_factor[key]) continue
                if (base < series_minimum[key] || now < series_minimum[key]) {
                    duration_filtered[++duration_filtered_count] = key
                    continue
                }
                delta = now - base
                deltas[key] = delta
                if (delta <= series_delta[key]) {
                    delta_filtered[++delta_filtered_count] = key
                    continue
                }
                if (now <= guard) {
                    dispersion_filtered[++dispersion_filtered_count] = key
                    continue
                }
                alerts[++alert_count] = key
            }
            if (alert_count == 0) {
                print "## Status: no sustained regressions"
                print ""
                print "No complete selected series exceeds its factor, absolute-delta floor, duration floor, and baseline dispersion guard."
            } else {
                print "## Sustained regressions"
                print ""
                print "| Host | Gate | Case | Phase | Baseline median | Baseline P" \
                    baseline_percentile " | Recent median | Ratio | Policy |"
                print "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |"
                for (i = 1; i <= alert_count; i++) {
                    key = alerts[i]; split(key, parts, SUBSEP)
                    printf "| %s | %s | %s | %s | %.0f ms | %.0f ms | %.0f ms | %.3fx | %s %.2fx/+%dms |\n", \
                        parts[1], parts[2], parts[3], parts[4], base_median[key], \
                        baseline_guard[key], recent_median[key], ratios[key], \
                        series_policy[key], series_factor[key], series_delta[key]
                }
                print ""
                print "### Newest-first series used"
                print ""
                for (i = 1; i <= alert_count; i++) {
                    key = alerts[i]; split(key, parts, SUBSEP)
                    print "- **" parts[1] " / " parts[2] " / " parts[3] \
                        " / " parts[4] "**"
                    for (j = 1; j <= recent + baseline; j++)
                        print "  - [" run[key, j] "](" url[key, j] "): " \
                            value[key, j] " ms"
                }
            }
            if (zero_filtered_count) {
                print ""
                print "## Zero-baseline changes"
                print ""
                print "These changes are informational only. A zero baseline never forms a ratio or alert."
                print ""
                print "| Host | Gate | Case | Phase | Baseline median | Recent median |"
                print "| --- | --- | --- | --- | ---: | ---: |"
                for (i = 1; i <= zero_filtered_count; i++) {
                    key = zero_filtered[i]; split(key, parts, SUBSEP)
                    printf "| %s | %s | %s | %s | %.0f ms | %.0f ms |\n", \
                        parts[1], parts[2], parts[3], parts[4], \
                        base_median[key], recent_median[key]
                }
            }
            if (duration_filtered_count) {
                print ""
                print "## Signals below the duration floor"
                print ""
                print "These ratio-shaped changes are informational only because a median is below " \
                    "the series-specific duration floor."
                print ""
                print "| Host | Gate | Case | Phase | Baseline median | Recent median | Ratio |"
                print "| --- | --- | --- | --- | ---: | ---: | ---: |"
                for (i = 1; i <= duration_filtered_count; i++) {
                    key = duration_filtered[i]; split(key, parts, SUBSEP)
                    printf "| %s | %s | %s | %s | %.0f ms | %.0f ms | %.3fx |\n", \
                        parts[1], parts[2], parts[3], parts[4], base_median[key], \
                        recent_median[key], ratios[key]
                }
            }
            if (delta_filtered_count) {
                print ""
                print "## Signals below the absolute-delta floor"
                print ""
                print "These ratio-shaped changes are informational only because their absolute increase is too small."
                print ""
                print "| Host | Gate | Case | Phase | Baseline median | Recent median | Delta | Ratio |"
                print "| --- | --- | --- | --- | ---: | ---: | ---: | ---: |"
                for (i = 1; i <= delta_filtered_count; i++) {
                    key = delta_filtered[i]; split(key, parts, SUBSEP)
                    printf "| %s | %s | %s | %s | %.0f ms | %.0f ms | %.0f ms | %.3fx |\n", \
                        parts[1], parts[2], parts[3], parts[4], base_median[key], \
                        recent_median[key], deltas[key], ratios[key]
                }
            }
            if (dispersion_filtered_count) {
                print ""
                print "## Signals within baseline dispersion"
                print ""
                print "These ratio-shaped changes do not exceed the nearest-rank baseline P" \
                    baseline_percentile " observation."
                print ""
                print "| Host | Gate | Case | Phase | Baseline median | Baseline P" \
                    baseline_percentile " | Recent median | Ratio |"
                print "| --- | --- | --- | --- | ---: | ---: | ---: | ---: |"
                for (i = 1; i <= dispersion_filtered_count; i++) {
                    key = dispersion_filtered[i]; split(key, parts, SUBSEP)
                    printf "| %s | %s | %s | %s | %.0f ms | %.0f ms | %.0f ms | %.3fx |\n", \
                        parts[1], parts[2], parts[3], parts[4], base_median[key], \
                        baseline_guard[key], recent_median[key], ratios[key]
                }
            }
            if (insufficient_count) {
                print ""
                print "## Insufficient history"
                print ""
                print "| Host | Gate | Case | Phase | Samples | Required |"
                print "| --- | --- | --- | --- | ---: | ---: |"
                for (i = 1; i <= insufficient_count; i++) {
                    key = insufficient[i]; split(key, parts, SUBSEP)
                    print "| " parts[1] " | " parts[2] " | " parts[3] \
                        " | " parts[4] " | " count[key] \
                        " | " recent + baseline " |"
                }
            }
            print ""
            print "_Generated from successful pull-request CI artifacts; alerts are report-only._"
            print alert_count + 0 > (report ".alert-count")
        }
    ' report="$report" "$POLICY" "$sorted" > "$report"
    rm -f "$sorted"
}

append_artifact() {
    sha=$1 id=$2 url=$3 created=$4 host=$5 file=$6 out=$7
    awk -F '\t' -v sha="$sha" -v id="$id" -v url="$url" \
        -v created="$created" -v expected_host="$host" '
        NR == 1 {
            sub(/\r$/, "")
            if ($0 != "gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost") exit 2
            next
        }
        {
            sub(/\r$/, "", $6)
            if (NF != 6 || $4 !~ /^[0-9]+$/ || $5 !~ /^-?[0-9]+$/ ||
                    $6 != expected_host) exit 3
            print sha, id, url, created, $1, $2, $3, $4, $5, $6
        }
        END { if (NR < 2) exit 4 }
    ' OFS='\t' "$file" >> "$out" || {
        echo "[ci-timing-trend] corrupt $host artifact for run $id" >&2
        return 1
    }
}

complete_verification_value() {
    file=$1
    expected_host=$2
    awk -F '\t' -v expected_host="$expected_host" '
        NR == 1 { next }
        $1 == "CI verification" && $2 == "all" &&
                $3 == "complete-verification" {
            count++
            if (NF != 6 || $4 !~ /^[0-9]+$/ || $5 != "0" ||
                    $6 != expected_host) bad = 1
            value = $4
        }
        END {
            if (count > 1 || bad) exit 1
            if (count == 1) print value
        }
    ' "$file"
}

append_verification_aggregates() {
    sha=$1 id=$2 url=$3 created=$4 linux_file=$5 windows_file=$6 out=$7
    linux_value=$(complete_verification_value "$linux_file" linux) || {
        echo "[ci-timing-trend] malformed Linux complete-verification series for run $id" >&2
        return 1
    }
    windows_value=$(complete_verification_value "$windows_file" windows) || {
        echo "[ci-timing-trend] malformed Windows complete-verification series for run $id" >&2
        return 1
    }
    if [ -z "$linux_value" ] && [ -z "$windows_value" ]; then
        # Artifacts before #6882 do not contain the synthetic flow total. They
        # remain valid baseline input for older top-level series.
        return 0
    fi
    if [ -z "$linux_value" ] || [ -z "$windows_value" ]; then
        echo "[ci-timing-trend] run $id has a complete-verification row on only one host" >&2
        return 1
    fi
    if [ "$linux_value" -gt "$windows_value" ]; then
        critical=$linux_value
    else
        critical=$windows_value
    fi
    summed=$((linux_value + windows_value))
    printf '%s\t%s\t%s\t%s\tCI verification\tall\tcritical-path\t%s\t0\tall-hosts\n' \
        "$sha" "$id" "$url" "$created" "$critical" >> "$out"
    printf '%s\t%s\t%s\t%s\tCI verification\tall\tsummed-runner-time\t%s\t0\tall-hosts\n' \
        "$sha" "$id" "$url" "$created" "$summed" >> "$out"
}

collect() {
    repo=$1 workdir=$2
    validate_config || return
    command -v gh >/dev/null 2>&1 || {
        echo "[ci-timing-trend] gh is required for collection" >&2; return 1;
    }
    rm -rf "$workdir"
    mkdir -p "$workdir/downloads"
    runs="$workdir/runs.tsv"
    gh run list --repo "$repo" --workflow ci.yml --event pull_request \
        --status success --limit "$RUN_LIMIT" \
        --json databaseId,headSha,url,createdAt \
        --jq '.[] | [.headSha,.databaseId,.url,.createdAt] | @tsv' > "$runs"
    history="$workdir/history.tsv"
    printf '%s\n' "$HEADER" > "$history"
    seen="$workdir/seen"
    : > "$seen"
    collected=0
    while IFS="$(printf '\t')" read -r sha id url created; do
        grep -Fx "$sha" "$seen" >/dev/null 2>&1 && continue
        names=$(gh api "repos/$repo/actions/runs/$id/artifacts" \
            --jq '.artifacts[] | select(.expired == false) | .name')
        printf '%s\n' "$names" | grep -Fx ci-timing-Linux >/dev/null || continue
        printf '%s\n' "$names" | grep -Fx ci-timing-Windows >/dev/null || continue
        dir="$workdir/downloads/$id"
        mkdir -p "$dir/linux" "$dir/windows"
        gh run download "$id" --repo "$repo" -n ci-timing-Linux -D "$dir/linux"
        gh run download "$id" --repo "$repo" -n ci-timing-Windows -D "$dir/windows"
        linux=$(find "$dir/linux" -type f -name '*.tsv')
        windows=$(find "$dir/windows" -type f -name '*.tsv')
        [ "$(printf '%s\n' "$linux" | grep -c .)" -eq 1 ] &&
            [ "$(printf '%s\n' "$windows" | grep -c .)" -eq 1 ] || {
                echo "[ci-timing-trend] run $id does not contain one TSV per host" >&2
                return 1
            }
        append_artifact "$sha" "$id" "$url" "$created" linux "$linux" "$history"
        append_artifact "$sha" "$id" "$url" "$created" windows "$windows" "$history"
        append_verification_aggregates \
            "$sha" "$id" "$url" "$created" "$linux" "$windows" "$history"
        printf '%s\n' "$sha" >> "$seen"
        collected=$((collected + 1))
        [ "$collected" -ge $((RECENT + BASELINE)) ] && break
    done < "$runs"
    [ "$collected" -ge $((RECENT + BASELINE)) ] || {
        echo "[ci-timing-trend] only $collected complete unique heads found; need $((RECENT + BASELINE)) after scanning $RUN_LIMIT runs" >&2
        return 1
    }
    report="$workdir/report.md"
    analyze "$history" "$report"
    alert_count=$(cat "$report.alert-count")
    issue=$(gh issue list --repo "$repo" --state all --limit 100 \
        --search "$ISSUE_TITLE in:title" --json number,title,state,body \
        --jq ".[] | select(.title == \"$ISSUE_TITLE\" and (.body | contains(\"$MARKER\"))) | [.number,.state] | @tsv" |
        sed -n '1p')
    number=$(printf '%s' "$issue" | cut -f1)
    state=$(printf '%s' "$issue" | cut -f2)
    if [ "$alert_count" -gt 0 ]; then
        if [ -z "$number" ]; then
            gh issue create --repo "$repo" --title "$ISSUE_TITLE" --body-file "$report"
        else
            [ "$state" = OPEN ] || gh issue reopen "$number" --repo "$repo"
            gh issue edit "$number" --repo "$repo" --body-file "$report"
        fi
    elif [ -n "$number" ] && [ "$state" = OPEN ]; then
        gh issue comment "$number" --repo "$repo" \
            --body "Recovered: the latest scheduled analysis found no sustained regressions."
        gh issue close "$number" --repo "$repo" --reason completed
    fi
    cat "$report"
}

self_test() {
    work="$ROOT/target/ci-timing-trend-self-test"
    rm -rf "$work"; mkdir -p "$work"

    printed_default=$("$0" --print-default-denylist)
    if [ "$printed_default" != "$DEFAULT_DENYLIST" ]; then
        echo "[ci-timing-trend] printed default denylist does not match the analyzer default" >&2
        return 1
    fi
    printed_with_override=$(CI_TIMING_TREND_DENYLIST=none \
        "$0" --print-default-denylist)
    if [ "$printed_with_override" != "$DEFAULT_DENYLIST" ]; then
        echo "[ci-timing-trend] denylist override changed the printed default" >&2
        return 1
    fi

    validate_policy
    cp "$POLICY" "$work/policy-duplicate.tsv"
    sed -n '3p' "$POLICY" >> "$work/policy-duplicate.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-duplicate.tsv" \
            "$0" --offline /dev/null "$work/policy-duplicate.md" \
            > "$work/policy-duplicate.out" 2>&1; then
        echo "[ci-timing-trend] duplicate policy unexpectedly passed" >&2
        return 1
    fi
    grep -F 'duplicate selector' "$work/policy-duplicate.out" >/dev/null
    cp "$POLICY" "$work/policy-overlap.tsv"
    printf 'trend\tstage2 native integration corpus\tcompiler_frontend_smoke_suite\tsemantic-partial\t1.15\t500\t250\t#6882\thttps://github.com/JoNil-Botta/typelisp/issues/6881\n' \
        >> "$work/policy-overlap.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-overlap.tsv" \
            "$0" --offline /dev/null "$work/policy-overlap.md" \
            > "$work/policy-overlap.out" 2>&1; then
        echo "[ci-timing-trend] overlapping policy unexpectedly passed" >&2
        return 1
    fi
    grep -F 'overlapping selector' "$work/policy-overlap.out" >/dev/null
    sed '0,/^trend\t/s//unknown\t/' "$POLICY" > "$work/policy-unknown.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-unknown.tsv" \
            "$0" --offline /dev/null "$work/policy-unknown.md" \
            > "$work/policy-unknown.out" 2>&1; then
        echo "[ci-timing-trend] unknown policy kind unexpectedly passed" >&2
        return 1
    fi
    grep -F 'unknown policy kind' "$work/policy-unknown.out" >/dev/null
    sed '2s/min_delta_ms/unknown_column/' "$POLICY" > "$work/policy-malformed.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-malformed.tsv" \
            "$0" --offline /dev/null "$work/policy-malformed.md" \
            > "$work/policy-malformed.out" 2>&1; then
        echo "[ci-timing-trend] malformed policy unexpectedly passed" >&2
        return 1
    fi
    grep -F 'invalid header' "$work/policy-malformed.out" >/dev/null
    sed 's/\t#6882\t/\tno-reference\t/' "$POLICY" > "$work/policy-unexplained.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-unexplained.tsv" \
            "$0" --offline /dev/null "$work/policy-unexplained.md" \
            > "$work/policy-unexplained.out" 2>&1; then
        echo "[ci-timing-trend] unexplained policy change unexpectedly passed" >&2
        return 1
    fi
    grep -F 'change_ref must name an issue or PR' \
        "$work/policy-unexplained.out" >/dev/null
    sed '0,/\t1.15\t/s//\t1.60\t/' "$POLICY" > "$work/policy-broad.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-broad.tsv" \
            "$0" --offline /dev/null "$work/policy-broad.md" \
            > "$work/policy-broad.out" 2>&1; then
        echo "[ci-timing-trend] broad threshold relaxation unexpectedly passed" >&2
        return 1
    fi
    grep -F 'factor must be greater than 1 and at most 1.5' \
        "$work/policy-broad.out" >/dev/null
    cp "$POLICY" "$work/policy-denied.tsv"
    printf 'trend\tstage2 CLI host-action smoke\tall\tgate\t1.15\t1000\t1000\t#6882\thttps://github.com/JoNil-Botta/typelisp/issues/6881\n' \
        >> "$work/policy-denied.tsv"
    if CI_TIMING_TREND_POLICY="$work/policy-denied.tsv" \
            "$0" --offline /dev/null "$work/policy-denied.md" \
            > "$work/policy-denied.out" 2>&1; then
        echo "[ci-timing-trend] denied policy overlap unexpectedly passed" >&2
        return 1
    fi
    grep -F 'denylisted gate also has trend policy' "$work/policy-denied.out" >/dev/null

    fixture="$work/history.tsv"
    printf '%s\n' "$HEADER" > "$fixture"
    i=1
    while [ "$i" -le 23 ]; do
        # Newest three Linux gate-a values breach 1.5x; exact-threshold gate-b does not.
        if [ "$i" -le 3 ]; then
            a=1600
            b=1500
            clean=12500
            sub_floor=400
            zero_baseline=5000
            complete=4248000
            critical=4307000
            summed=8426000
            long_gate=117000
            semantic=11800
            semantic_tiny=1180
        else
            a=1000
            b=1000
            clean=4100
            sub_floor=200
            zero_baseline=0
            complete=3600000
            critical=3650000
            summed=7200000
            long_gate=100000
            semantic=10000
            semantic_tiny=1000
        fi
        # Exact noisy series from #5661: baseline median 1065 ms, P95 6280 ms,
        # recent median 1600 ms. The ratio breaches by only 0.002x while the
        # recent observation remains well inside the baseline dispersion.
        case "$i" in
            1) noisy=6530 ;;
            2) noisy=1600 ;;
            3) noisy=1390 ;;
            4) noisy=740 ;;
            5) noisy=8570 ;;
            6) noisy=990 ;;
            7) noisy=1450 ;;
            8) noisy=580 ;;
            9) noisy=1160 ;;
            10) noisy=1070 ;;
            11) noisy=2500 ;;
            12) noisy=800 ;;
            13) noisy=760 ;;
            14) noisy=810 ;;
            15) noisy=6280 ;;
            16) noisy=800 ;;
            17) noisy=780 ;;
            18) noisy=4500 ;;
            19) noisy=4190 ;;
            20) noisy=720 ;;
            21) noisy=2150 ;;
            22) noisy=1180 ;;
            23) noisy=1060 ;;
        esac
        created=$(printf '2026-07-%02dT00:00:00Z' $((24 - i)))
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tgate-a\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$a" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tgate-b\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$b" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tgate-a\tall\tgate\t1000\t0\twindows\n' \
            "$i" "$i" "$i" "$created" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tclean-step\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$clean" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tgate-sub-floor\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$sub_floor" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tgate-zero-baseline\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$zero_baseline" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tgate-noisy\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$noisy" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tCI verification\tall\tcomplete-verification\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$complete" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tCI verification\tall\tcritical-path\t%d\t0\tall-hosts\n' \
            "$i" "$i" "$i" "$created" "$critical" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tCI verification\tall\tsummed-runner-time\t%d\t0\tall-hosts\n' \
            "$i" "$i" "$i" "$created" "$summed" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 native integration corpus\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$long_gate" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 native integration corpus\tcompiler_frontend_smoke_suite\tsemantic-partial\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$semantic" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 native integration corpus\tcompiler_frontend_smoke_suite\tsemantic-tiny\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$semantic_tiny" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 native integration corpus\tcompiler_frontend_smoke_suite\tsemantic-failed\t999999\t7\tlinux\n' \
            "$i" "$i" "$i" "$created" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 native integration corpus\tcompiler_frontend_smoke_suite\tchild-check\t999999\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" >> "$fixture"
        # Both denylisted gates are given a breaching shape -- newest three at
        # 16x the baseline -- so the assertions below prove suppression rather
        # than merely the absence of a signal. A flat series would pass even if
        # the denylist stopped working.
        if [ "$i" -le 3 ]; then denied=16000; else denied=1000; fi
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 opt1/opt2 build-invariance\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$denied" >> "$fixture"
        printf 'sha%02d\t%d\thttps://example.test/runs/%d\t%s\tstage2 CLI host-action smoke\tall\tgate\t%d\t0\tlinux\n' \
            "$i" "$i" "$i" "$created" "$denied" >> "$fixture"
        i=$((i + 1))
    done
    # Older duplicate rerun and irrelevant/nonzero/detail rows must not affect results.
    printf 'sha01\t999\thttps://example.test/runs/999\t2026-01-01T00:00:00Z\tgate-a\tall\tgate\t9999\t0\tlinux\n' >> "$fixture"
    printf 'sha01\t1\thttps://example.test/runs/1\t2026-07-23T00:00:00Z\tgate-a\tchunk\tcompile\t9999\t0\tlinux\n' >> "$fixture"
    printf 'sha01\t1\thttps://example.test/runs/1\t2026-07-23T00:00:00Z\tfailed\tall\tgate\t9999\t1\tlinux\n' >> "$fixture"
    printf 'sha01\t1\thttps://example.test/runs/1\t2026-07-23T00:00:00Z\tgate-short\tall\tgate\t100\t0\tlinux\n' >> "$fixture"
    analyze "$fixture" "$work/report-a.md"
    analyze "$fixture" "$work/report-b.md"
    cmp "$work/report-a.md" "$work/report-b.md"
    {
        head -n 1 "$fixture"
        tail -n +2 "$fixture" | sort -r
    } > "$work/unordered.tsv"
    analyze "$work/unordered.tsv" "$work/unordered.md"
    cmp "$work/report-a.md" "$work/unordered.md"
    grep -F '| linux | gate-a | all | gate | 1000 ms | 1000 ms | 1600 ms | 1.600x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | clean-step | all | gate | 4100 ms | 4100 ms | 12500 ms | 3.049x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | CI verification | all | complete-verification | 3600000 ms | 3600000 ms | 4248000 ms | 1.180x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| all-hosts | CI verification | all | critical-path | 3650000 ms | 3650000 ms | 4307000 ms | 1.180x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| all-hosts | CI verification | all | summed-runner-time | 7200000 ms | 7200000 ms | 8426000 ms | 1.170x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | stage2 native integration corpus | all | gate | 100000 ms | 100000 ms | 117000 ms | 1.170x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | stage2 native integration corpus | compiler_frontend_smoke_suite | semantic-partial | 10000 ms | 10000 ms | 11800 ms | 1.180x |' \
        "$work/report-a.md" >/dev/null
    ! grep -F '| linux | gate-b |' "$work/report-a.md" >/dev/null
    grep -F '| linux | gate-sub-floor | all | gate | 200 ms | 400 ms | 2.000x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | gate-zero-baseline | all | gate | 0 ms | 5000 ms |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | gate-noisy | all | gate | 1065 ms | 6280 ms | 1600 ms | 1.502x |' \
        "$work/report-a.md" >/dev/null
    grep -F '| linux | stage2 native integration corpus | compiler_frontend_smoke_suite | semantic-tiny | 1000 ms | 1180 ms | 180 ms | 1.180x |' \
        "$work/report-a.md" >/dev/null
    ! grep -F 'semantic-failed' "$work/report-a.md" >/dev/null
    ! grep -F 'child-check' "$work/report-a.md" >/dev/null
    ! grep -F '999999' "$work/report-a.md" >/dev/null
    ! grep -F 'build-invariance' "$work/report-a.md" >/dev/null
    ! grep -F 'host-action smoke' "$work/report-a.md" >/dev/null
    # Same rows, denylist emptied: both must alert, which is what makes the two
    # assertions above evidence that the denylist is doing the suppressing.
    CI_TIMING_TREND_DENYLIST=none "$0" --offline "$fixture" "$work/no-denylist.md"
    grep -F '| linux | stage2 opt1/opt2 build-invariance |' \
        "$work/no-denylist.md" >/dev/null
    grep -F '| linux | stage2 CLI host-action smoke |' \
        "$work/no-denylist.md" >/dev/null
    grep -F '| linux | gate-short | all | gate | 1 | 23 |' \
        "$work/report-a.md" >/dev/null
    grep -F '| windows | gate-a |' "$work/report-a.md" >/dev/null && {
        echo "[ci-timing-trend] host separation self-test unexpectedly alerted" >&2; return 1;
    }
    [ "$(cat "$work/report-a.md.alert-count")" -eq 7 ]
    {
        printf '# ci-timing-trend-policy-schema\t1\n'
        printf '%s\n' 'kind	gate	case_or_chunk	phase	factor	min_delta_ms	min_baseline_ms	change_ref	evidence_url'
        printf 'trend\tnot-present\tall\tgate\t1.15\t1000\t1000\t#6882\thttps://github.com/JoNil-Botta/typelisp/issues/6881\n'
    } > "$work/irrelevant-policy.tsv"
    CI_TIMING_TREND_FACTOR=4 CI_TIMING_TREND_RUN_LIMIT=100 \
        CI_TIMING_TREND_POLICY="$work/irrelevant-policy.tsv" \
        "$0" --offline "$fixture" "$work/recovered.md"
    grep -F '## Status: no sustained regressions' "$work/recovered.md" >/dev/null
    [ "$(cat "$work/recovered.md.alert-count")" -eq 0 ]
    CI_TIMING_TREND_MIN_MS=100 CI_TIMING_TREND_MIN_DELTA_MS=100 \
        "$0" --offline \
        "$fixture" "$work/lower-floor.md"
    grep -F '| linux | gate-sub-floor | all | gate | 200 ms | 200 ms | 400 ms | 2.000x |' \
        "$work/lower-floor.md" >/dev/null
    CI_TIMING_TREND_BASELINE_PERCENTILE=50 "$0" --offline \
        "$fixture" "$work/median-guard.md"
    grep -F '| linux | gate-noisy | all | gate | 1065 ms | 1060 ms | 1600 ms | 1.502x |' \
        "$work/median-guard.md" >/dev/null

    printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\nCI verification\tall\tcomplete-verification\t1000\t0\tlinux\n' \
        > "$work/linux-artifact.tsv"
    printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\nCI verification\tall\tcomplete-verification\t1200\t0\twindows\n' \
        > "$work/windows-artifact.tsv"
    : > "$work/aggregate-history.tsv"
    append_verification_aggregates sha 1 https://example.test/runs/1 \
        2026-07-01T00:00:00Z "$work/linux-artifact.tsv" \
        "$work/windows-artifact.tsv" "$work/aggregate-history.tsv"
    awk -F '\t' '
        $5 == "CI verification" && $6 == "all" &&
            $7 == "critical-path" && $8 == 1200 && $9 == 0 &&
            $10 == "all-hosts" { critical++ }
        $5 == "CI verification" && $6 == "all" &&
            $7 == "summed-runner-time" && $8 == 2200 && $9 == 0 &&
            $10 == "all-hosts" { summed++ }
        END { exit critical == 1 && summed == 1 ? 0 : 1 }
    ' "$work/aggregate-history.tsv"
    head -n 1 "$work/windows-artifact.tsv" > "$work/windows-missing.tsv"
    if append_verification_aggregates sha 2 https://example.test/runs/2 \
            2026-07-02T00:00:00Z "$work/linux-artifact.tsv" \
            "$work/windows-missing.tsv" "$work/missing-aggregate.tsv" \
            >/dev/null 2>&1; then
        echo "[ci-timing-trend] one-host verification total unexpectedly passed" >&2
        return 1
    fi
    sed -n '2p' "$work/linux-artifact.tsv" >> "$work/linux-artifact.tsv"
    if append_verification_aggregates sha 2 https://example.test/runs/2 \
            2026-07-02T00:00:00Z "$work/linux-artifact.tsv" \
            "$work/windows-artifact.tsv" "$work/bad-aggregate.tsv" \
            >/dev/null 2>&1; then
        echo "[ci-timing-trend] duplicate verification total unexpectedly passed" >&2
        return 1
    fi
    median="$work/median.tsv"
    printf '%s\n' "$HEADER" > "$median"
    printf 'm1\t1\thttps://example.test/runs/1\t2026-07-04T00:00:00Z\tmedian\tall\tgate\t2000\t0\tlinux\n' >> "$median"
    printf 'm2\t2\thttps://example.test/runs/2\t2026-07-03T00:00:00Z\tmedian\tall\tgate\t1000\t0\tlinux\n' >> "$median"
    printf 'm3\t3\thttps://example.test/runs/3\t2026-07-02T00:00:00Z\tmedian\tall\tgate\t1000\t0\tlinux\n' >> "$median"
    printf 'm4\t4\thttps://example.test/runs/4\t2026-07-01T00:00:00Z\tmedian\tall\tgate\t1000\t0\tlinux\n' >> "$median"
    CI_TIMING_TREND_RECENT=2 CI_TIMING_TREND_BASELINE=2 \
        CI_TIMING_TREND_FACTOR=1.5 CI_TIMING_TREND_RUN_LIMIT=4 \
        "$0" --offline "$median" "$work/even.md"
    grep -F '## Status: no sustained regressions' "$work/even.md" >/dev/null
    cp "$fixture" "$work/malformed.tsv"
    printf 'broken\n' >> "$work/malformed.tsv"
    if analyze "$work/malformed.tsv" "$work/bad.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] malformed fixture unexpectedly passed" >&2
        return 1
    fi
    if CI_TIMING_TREND_RECENT=0 "$0" --offline \
        "$fixture" "$work/invalid-window.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] zero window unexpectedly passed" >&2
        return 1
    fi
    if CI_TIMING_TREND_FACTOR=1 "$0" --offline \
        "$fixture" "$work/invalid-factor.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] factor 1 unexpectedly passed" >&2
        return 1
    fi
    if CI_TIMING_TREND_MIN_MS=-1 "$0" --offline \
            "$fixture" "$work/invalid-minimum.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] negative minimum duration unexpectedly passed" >&2
        return 1
    fi
    if CI_TIMING_TREND_MIN_DELTA_MS=-1 "$0" --offline \
            "$fixture" "$work/invalid-delta.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] negative minimum delta unexpectedly passed" >&2
        return 1
    fi
    if CI_TIMING_TREND_BASELINE_PERCENTILE=49 "$0" --offline \
        "$fixture" "$work/invalid-percentile.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] baseline percentile below 50 unexpectedly passed" >&2
        return 1
    fi
    if CI_TIMING_TREND_BASELINE_PERCENTILE=101 "$0" --offline \
        "$fixture" "$work/invalid-percentile-high.md" >/dev/null 2>&1; then
        echo "[ci-timing-trend] baseline percentile above 100 unexpectedly passed" >&2
        return 1
    fi
    workflow="$ROOT/.github/workflows/ci-timing-trends.yml"
    grep -F 'schedule:' "$workflow" >/dev/null
    grep -F 'workflow_dispatch:' "$workflow" >/dev/null
    grep -F 'actions: read' "$workflow" >/dev/null
    grep -F 'contents: read' "$workflow" >/dev/null
    grep -F 'issues: write' "$workflow" >/dev/null
    echo "CI timing trend analyzer self-tests passed"
}

case "${1:-}" in
    --offline) [ "$#" -eq 3 ] || { usage; exit 2; }; analyze "$2" "$3" ;;
    --collect) [ "$#" -eq 3 ] || { usage; exit 2; }; collect "$2" "$3" ;;
    --print-default-denylist)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        printf '%s\n' "$DEFAULT_DENYLIST"
        ;;
    --self-test) [ "$#" -eq 1 ] || { usage; exit 2; }; self_test ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
