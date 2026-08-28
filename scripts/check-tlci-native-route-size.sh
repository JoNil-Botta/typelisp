#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

POLICY=${TLCI_NATIVE_ROUTE_SIZE_POLICY:-scripts/tlci-native-route-size-policy.tsv}
HEADER='kind	host	scope	row	metric	dispatches	baseline_bytes	max_bytes	change_ref	evidence_url'

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-tlci-native-route-size.sh EVIDENCE.tsv
       scripts/check-tlci-native-route-size.sh --check-policy
       scripts/check-tlci-native-route-size.sh --self-test

Checks the sustained TLCI fixture's host-specific heavy-row assembly size.
EOF
}

check_policy() {
    [ -s "$POLICY" ] || {
        echo "[tlci-size-ratchet] policy is missing or empty: $POLICY" >&2
        return 1
    }
    awk -F '\t' -v header="$HEADER" '
        function fail(message) {
            print "[tlci-size-ratchet] policy row " FNR ": " message > "/dev/stderr"
            bad = 1
        }
        FNR == 1 {
            sub(/\r$/, "")
            if ($0 != "# tlci-native-route-size-policy-schema\t1") {
                fail("invalid schema marker")
            }
            next
        }
        FNR == 2 {
            sub(/\r$/, "")
            if ($0 != header) fail("invalid header")
            next
        }
        {
            sub(/\r$/, "", $10)
            if (NF != 10) { fail("expected 10 tab-separated fields"); next }
            if ($1 != "ratchet") fail("unknown policy kind " $1)
            if ($2 != "linux" && $2 != "windows") fail("unknown host " $2)
            if ($3 != "row" || $4 != "0" || $5 != "native_assembly_bytes") {
                fail("unknown heavy-row selector")
            }
            for (i = 6; i <= 8; i++) {
                if ($i !~ /^[0-9]+$/ || $i == 0) fail("invalid numeric budget")
            }
            if (($8 + 0) < ($7 + 0)) fail("max_bytes is below baseline_bytes")
            if (($8 + 0) * 100 > ($7 + 0) * 115) {
                fail("headroom exceeds the 15% broad-relaxation limit")
            }
            if ($9 !~ /^#[0-9]+$/) fail("change_ref must name an issue or PR")
            if ($10 !~ /^https:\/\/github.com\/JoNil-Botta\/typelisp\/(actions\/runs|issues|pull)\//) {
                fail("evidence_url must link measured project evidence")
            }
            key = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
            if (seen[key]++) fail("duplicate or overlapping selector")
            hosts[$2]++
            rows++
        }
        END {
            if (FNR < 3 || rows != 2) {
                print "[tlci-size-ratchet] policy must contain exactly two host rows" > "/dev/stderr"
                bad = 1
            }
            if (hosts["linux"] != 1 || hosts["windows"] != 1) {
                print "[tlci-size-ratchet] policy must cover linux and windows exactly once" > "/dev/stderr"
                bad = 1
            }
            exit bad ? 1 : 0
        }
    ' "$POLICY"
}

check_evidence() {
    evidence=$1
    check_policy || return 1
    [ -s "$evidence" ] || {
        echo "[tlci-size-ratchet] evidence is missing or empty: $evidence" >&2
        return 1
    }
    awk -F '\t' -v policy="$POLICY" '
        function fail(message) {
            print "[tlci-size-ratchet] ERROR: " message > "/dev/stderr"
            bad = 1
        }
        BEGIN {
            while ((getline line < policy) > 0) {
                sub(/\r$/, "", line)
                if (line ~ /^#/ || line ~ /^kind\t/) continue
                count = split(line, field, "\t")
                if (count != 10) continue
                host = field[2]
                dispatches[host] = field[6] + 0
                baseline[host] = field[7] + 0
                maximum[host] = field[8] + 0
            }
            close(policy)
        }
        NR == 1 {
            sub(/\r$/, "")
            if ($0 != "scope\trow\tmetric\tvalue\tunit\thost") {
                fail("invalid evidence header")
            }
            next
        }
        {
            sub(/\r$/, "", $6)
            if (NF != 6 || $4 !~ /^[0-9]+$/) {
                fail("malformed evidence row " NR)
                next
            }
            if ($6 != "linux" && $6 != "windows") {
                fail("unknown evidence host " $6)
                next
            }
            observed_host[$6]++
            if ($1 == "row" && $2 == "0" &&
                    $3 == "native_assembly_bytes") {
                matched[$6]++
                value[$6] = $4 + 0
                if ($5 != "bytes") fail("heavy row has unit " $5 ", expected bytes")
            }
        }
        END {
            hosts = 0
            for (host in observed_host) hosts++
            if (hosts != 1) fail("evidence must contain exactly one host")
            for (host in observed_host) {
                if (matched[host] != 1) {
                    fail("heavy-row metric occurs " (matched[host] + 0) " times for " host)
                    continue
                }
                printf "[tlci-size-ratchet] host=%s raw=%d baseline=%d max=%d bytes_per_dispatch=%.3f\n", \
                    host, value[host], baseline[host], maximum[host], \
                    value[host] / dispatches[host]
                if (value[host] > maximum[host]) {
                    fail(host " heavy-row assembly is " value[host] \
                        " bytes (" sprintf("%.3f", value[host] / dispatches[host]) \
                        " bytes/dispatch), baseline " baseline[host] \
                        ", max " maximum[host])
                }
            }
            if (bad) {
                print "[tlci-size-ratchet] Reproduce: scripts/verify-tlci-native-route-stress.sh <stress-enabled-profile-compiler>" > "/dev/stderr"
                exit 1
            }
        }
    ' "$evidence"
}

write_evidence_fixture() {
    file=$1
    host=$2
    bytes=$3
    {
        printf 'scope\trow\tmetric\tvalue\tunit\thost\n'
        printf 'row\t0\tnative_assembly_bytes\t%s\tbytes\t%s\n' "$bytes" "$host"
    } > "$file"
}

self_test() {
    work="$ROOT/target/tlci-native-route-size-self-test"
    rm -rf "$work"
    mkdir -p "$work"

    check_policy
    write_evidence_fixture "$work/pass.tsv" linux 64908
    check_evidence "$work/pass.tsv" > "$work/pass.out"
    grep -F 'bytes_per_dispatch=4.057' "$work/pass.out" >/dev/null

    write_evidence_fixture "$work/breach.tsv" windows 85926
    if check_evidence "$work/breach.tsv" > "$work/breach.out" 2>&1; then
        echo "[tlci-size-ratchet] breach fixture unexpectedly passed" >&2
        return 1
    fi
    grep -F 'raw=85926 baseline=78114 max=85925' "$work/breach.out" >/dev/null
    grep -F 'Reproduce: scripts/verify-tlci-native-route-stress.sh' \
        "$work/breach.out" >/dev/null

    write_evidence_fixture "$work/missing.tsv" linux 100
    sed '/native_assembly_bytes/d' "$work/missing.tsv" > "$work/missing-row.tsv"
    if check_evidence "$work/missing-row.tsv" >/dev/null 2>&1; then
        echo "[tlci-size-ratchet] missing metric unexpectedly passed" >&2
        return 1
    fi
    printf 'row\t0\tnative_assembly_bytes\t100\tbytes\tlinux\n' \
        >> "$work/missing.tsv"
    if check_evidence "$work/missing.tsv" >/dev/null 2>&1; then
        echo "[tlci-size-ratchet] duplicate metric unexpectedly passed" >&2
        return 1
    fi

    cp "$POLICY" "$work/policy.tsv"
    printf 'ratchet\tlinux\trow\t0\tnative_assembly_bytes\t16000\t59007\t64908\t#6906\thttps://github.com/JoNil-Botta/typelisp/actions/runs/33183348057\n' \
        >> "$work/policy.tsv"
    if TLCI_NATIVE_ROUTE_SIZE_POLICY="$work/policy.tsv" \
            "$0" --check-policy >/dev/null 2>&1; then
        echo "[tlci-size-ratchet] duplicate policy unexpectedly passed" >&2
        return 1
    fi
    sed 's/^ratchet\tlinux/unknown\tlinux/' "$POLICY" > "$work/unknown.tsv"
    if TLCI_NATIVE_ROUTE_SIZE_POLICY="$work/unknown.tsv" \
            "$0" --check-policy >/dev/null 2>&1; then
        echo "[tlci-size-ratchet] unknown policy kind unexpectedly passed" >&2
        return 1
    fi
    sed 's/59007\t64908/59007\t70000/' "$POLICY" > "$work/broad.tsv"
    if TLCI_NATIVE_ROUTE_SIZE_POLICY="$work/broad.tsv" \
            "$0" --check-policy >/dev/null 2>&1; then
        echo "[tlci-size-ratchet] broad relaxation unexpectedly passed" >&2
        return 1
    fi
    sed 's/\t#6906\t/\tno-reference\t/' "$POLICY" > "$work/unexplained.tsv"
    if TLCI_NATIVE_ROUTE_SIZE_POLICY="$work/unexplained.tsv" \
            "$0" --check-policy >/dev/null 2>&1; then
        echo "[tlci-size-ratchet] unexplained baseline unexpectedly passed" >&2
        return 1
    fi

    echo "TLCI native route size ratchet self-tests passed"
}

case "${1:-}" in
    --check-policy) [ "$#" -eq 1 ] || { usage; exit 2; }; check_policy ;;
    --self-test) [ "$#" -eq 1 ] || { usage; exit 2; }; self_test ;;
    -h|--help) usage ;;
    '') usage; exit 2 ;;
    *) [ "$#" -eq 1 ] || { usage; exit 2; }; check_evidence "$1" ;;
esac
