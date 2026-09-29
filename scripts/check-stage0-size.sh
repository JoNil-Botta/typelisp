#!/usr/bin/env sh
set -eu

# check-stage0-size.sh - the stage0 size ratchet (#6260's < 10,000,000-byte
# target, #8277).
#
# The converged bootstrap compiler is the stage0-equivalent binary: it comes
# from the same compile and native-link route as the published stage0. On
# Linux a stripped COPY is measured, as scripts/build-stage0.sh strips the
# published binary; the input itself is never modified. On Windows the linked
# executable is measured as it is.
#
# scripts/stage0-size-policy.tsv is an append-only ledger per host. A host's
# LAST row is its ceiling. An ordinary `ceiling` row may only lower the ceiling,
# a `raise` row is the one way to raise it and must name the change that
# authorizes the raise, and no ceiling may be below the final target.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

POLICY=${TYPELISP_STAGE0_SIZE_POLICY:-scripts/stage0-size-policy.tsv}
SCHEMA='# stage0-size-policy-schema	1'
HEADER='kind	host	ceiling_bytes	target_bytes	change_ref	evidence_url'
TARGET=10000000

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-stage0-size.sh BINARY [linux|windows]
       scripts/check-stage0-size.sh --check-policy
       scripts/check-stage0-size.sh --self-test

Measures the stage0-equivalent compiler against the host's ceiling in
scripts/stage0-size-policy.tsv. The host defaults to the running one.
EOF
}

check_policy() {
    [ -s "$POLICY" ] || {
        echo "[stage0-size] policy is missing or empty: $POLICY" >&2
        return 1
    }
    awk -F '\t' -v schema="$SCHEMA" -v header="$HEADER" -v target="$TARGET" '
        function fail(message) {
            print "[stage0-size] policy row " FNR ": " message > "/dev/stderr"
            bad = 1
        }
        FNR == 1 {
            sub(/\r$/, "")
            if ($0 != schema) fail("invalid schema marker")
            next
        }
        FNR == 2 {
            sub(/\r$/, "")
            if ($0 != header) fail("invalid header")
            next
        }
        {
            sub(/\r$/, "", $6)
            if (NF != 6) { fail("expected 6 tab-separated fields"); next }
            if ($1 != "ceiling" && $1 != "raise") {
                fail("unknown kind " $1)
                next
            }
            if ($2 != "linux" && $2 != "windows") {
                fail("unknown host " $2)
                next
            }
            if ($3 !~ /^[1-9][0-9]*$/ || $4 !~ /^[1-9][0-9]*$/) {
                fail("invalid byte count")
                next
            }
            if ($4 + 0 != target + 0) fail("target must be " target)
            if ($3 + 0 < target + 0) fail("ceiling " $3 " is below the target " target)
            if ($5 !~ /^#[0-9]+$/) fail("change_ref must name an issue or PR")
            if ($6 !~ /^https:\/\/github.com\/JoNil-Botta\/typelisp\/(actions\/runs|issues|pull)\//) {
                fail("evidence_url must link measured project evidence")
            }
            if (!($2 in ceiling)) {
                if ($1 != "ceiling") fail("the first " $2 " row must be a ceiling")
            } else if ($1 == "ceiling" && $3 + 0 > ceiling[$2]) {
                fail($2 " ceiling " $3 " is above the previous " ceiling[$2] \
                    "; only a raise row naming its authorizing change may raise it")
            } else if ($1 == "raise" && $3 + 0 <= ceiling[$2]) {
                fail($2 " raise row " $3 " does not raise the previous " ceiling[$2])
            }
            ceiling[$2] = $3 + 0
        }
        END {
            if (FNR < 3) {
                print "[stage0-size] policy has no rows" > "/dev/stderr"
                bad = 1
            }
            if (!("linux" in ceiling) || !("windows" in ceiling)) {
                print "[stage0-size] policy must cover linux and windows" > "/dev/stderr"
                bad = 1
            }
            exit bad ? 1 : 0
        }
    ' "$POLICY"
}

host_ceiling() {
    awk -F '\t' -v host="$1" '
        FNR > 2 && $2 == host { ceiling = $3 }
        END { print ceiling }
    ' "$POLICY"
}

running_host() {
    case "$(uname -s)" in
        Linux*) echo linux ;;
        MINGW* | MSYS* | CYGWIN*) echo windows ;;
        *) echo other ;;
    esac
}

check_binary() {
    binary=$1
    host=$2
    check_policy || return 1
    case "$host" in
        linux | windows) ;;
        *)
            echo "[stage0-size] unsupported host: $host" >&2
            return 1
            ;;
    esac
    [ -f "$binary" ] || {
        echo "[stage0-size] binary is missing: $binary" >&2
        return 1
    }
    work=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-stage0-size.XXXXXX")
    measured="$work/stage0"
    cp "$binary" "$measured"
    if [ "$host" = linux ]; then
        if ! strip "$measured"; then
            rm -rf "$work"
            echo "[stage0-size] could not strip a copy of $binary" >&2
            return 1
        fi
    fi
    bytes=$(wc -c < "$measured" | tr -d ' ')
    rm -rf "$work"
    ceiling=$(host_ceiling "$host")
    delta=$((bytes - ceiling))
    over_target=$((bytes - TARGET))
    printf '[stage0-size] host=%s bytes=%s ceiling=%s target=%s delta_to_ceiling=%s over_target=%s\n' \
        "$host" "$bytes" "$ceiling" "$TARGET" "$delta" "$over_target"
    if [ "$bytes" -gt "$ceiling" ]; then
        echo "[stage0-size] ERROR: $host stage0 is $bytes bytes, $delta over its ceiling $ceiling (target $TARGET)" >&2
        echo "[stage0-size] Reproduce: scripts/check-stage0-size.sh <converged-bootstrap-compiler> $host" >&2
        return 1
    fi
    headroom=$((bytes / 100))
    suggested=$((bytes + headroom))
    if [ "$suggested" -lt "$TARGET" ]; then
        suggested=$TARGET
    fi
    if [ "$suggested" -lt "$ceiling" ]; then
        echo "[stage0-size] $host ceiling may drop to $suggested (measured + 1%, not below the target): append a ceiling row"
    fi
}

write_policy_fixture() {
    file=$1
    shift
    {
        printf '%s\n%s\n' "$SCHEMA" "$HEADER"
        for row in "$@"; do
            printf '%s\n' "$row"
        done
    } > "$file"
}

expect_policy_failure() {
    label=$1
    file=$2
    if TYPELISP_STAGE0_SIZE_POLICY="$file" "$0" --check-policy \
            > "$work/$label.out" 2>&1; then
        echo "[stage0-size] $label policy unexpectedly passed" >&2
        return 1
    fi
}

self_test() {
    work="$ROOT/target/stage0-size-self-test"
    rm -rf "$work"
    mkdir -p "$work"
    evidence='https://github.com/JoNil-Botta/typelisp/issues/8277'
    linux_row="ceiling	linux	11000000	10000000	#8277	$evidence"
    windows_row="ceiling	windows	12000000	10000000	#8277	$evidence"

    check_policy

    write_policy_fixture "$work/good.tsv" "$linux_row" "$windows_row" \
        "ceiling	windows	11500000	10000000	#8276	$evidence" \
        "raise	windows	11600000	10000000	#8301	$evidence"
    TYPELISP_STAGE0_SIZE_POLICY="$work/good.tsv" "$0" --check-policy

    if TYPELISP_STAGE0_SIZE_POLICY="$work/absent.tsv" "$0" --check-policy \
            > "$work/absent.out" 2>&1; then
        echo "[stage0-size] missing policy unexpectedly passed" >&2
        return 1
    fi
    write_policy_fixture "$work/fields.tsv" "$linux_row" \
        "ceiling	windows	12000000	10000000	#8277"
    expect_policy_failure fields "$work/fields.tsv"
    write_policy_fixture "$work/number.tsv" "$linux_row" \
        "ceiling	windows	12e6	10000000	#8277	$evidence"
    expect_policy_failure number "$work/number.tsv"
    write_policy_fixture "$work/below.tsv" "$linux_row" \
        "ceiling	windows	9999999	10000000	#8277	$evidence"
    expect_policy_failure below "$work/below.tsv"
    grep -F 'below the target' "$work/below.out" >/dev/null
    write_policy_fixture "$work/raised.tsv" "$linux_row" "$windows_row" \
        "ceiling	windows	12000001	10000000	#8277	$evidence"
    expect_policy_failure raised "$work/raised.tsv"
    grep -F 'only a raise row' "$work/raised.out" >/dev/null
    write_policy_fixture "$work/unnamed.tsv" "$linux_row" "$windows_row" \
        "raise	windows	12500000	10000000	unnamed	$evidence"
    expect_policy_failure unnamed "$work/unnamed.tsv"
    write_policy_fixture "$work/host.tsv" "$linux_row"
    expect_policy_failure host "$work/host.tsv"

    # The comparison, on windows so the fixture bytes are measured unstripped.
    head -c 11500000 /dev/zero > "$work/under.exe"
    TYPELISP_STAGE0_SIZE_POLICY="$work/good.tsv" "$0" "$work/under.exe" windows \
        > "$work/under.out"
    grep -F 'bytes=11500000 ceiling=11600000' "$work/under.out" >/dev/null
    head -c 11600001 /dev/zero > "$work/over.exe"
    if TYPELISP_STAGE0_SIZE_POLICY="$work/good.tsv" "$0" "$work/over.exe" windows \
            > "$work/over.out" 2>&1; then
        echo "[stage0-size] over-ceiling binary unexpectedly passed" >&2
        return 1
    fi
    grep -F 'stage0 is 11600001 bytes, 1 over its ceiling 11600000 (target 10000000)' \
        "$work/over.out" >/dev/null
    grep -F 'Reproduce: scripts/check-stage0-size.sh' "$work/over.out" >/dev/null
    head -c 10200000 /dev/zero > "$work/shrunk.exe"
    TYPELISP_STAGE0_SIZE_POLICY="$work/good.tsv" "$0" "$work/shrunk.exe" windows \
        > "$work/shrunk.out"
    grep -F 'ceiling may drop to 10302000' "$work/shrunk.out" >/dev/null
    if TYPELISP_STAGE0_SIZE_POLICY="$work/good.tsv" "$0" "$work/missing.exe" windows \
            > "$work/missing.out" 2>&1; then
        echo "[stage0-size] missing binary unexpectedly passed" >&2
        return 1
    fi

    rm -rf "$work"
    echo "stage0 size ratchet self-tests passed"
}

case "${1:-}" in
    --check-policy) [ "$#" -eq 1 ] || { usage; exit 2; }; check_policy ;;
    --self-test) [ "$#" -eq 1 ] || { usage; exit 2; }; self_test ;;
    -h | --help) usage ;;
    '') usage; exit 2 ;;
    *)
        [ "$#" -le 2 ] || { usage; exit 2; }
        check_binary "$1" "${2:-$(running_host)}"
        ;;
esac
