#!/usr/bin/env sh
set -eu

# Regenerate the address-free TLCI native admission/callback audit manifest,
# compare it with the checked-in artifact, and prove that representative drift
# in every source boundary fails closed with an actionable identity. Refs #7272.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-stage0.sh"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-tlci-boundary-manifest.sh" >&2
    exit 2
fi

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "TLCI boundary manifest compiler is not executable: $COMPILER" >&2
    exit 1
fi

mkdir -p "$ROOT/target"
WORKDIR=$(mktemp -d "$ROOT/target/tlci-boundary-manifest.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

TOOL=tools/tlci-boundary-manifest/main.tl
CORE=src/tlci_core.tl
HOST=src/compiler_embedded_stdlib_tlci.tl
PRODUCER=src/compiler_tlci_native_producer.tl
STAGES=tools/tlci-boundary-manifest/admission-stages.tsv
CHECKED=docs/tlci-native-boundary-manifest.tsv
ACTUAL=$WORKDIR/manifest.tsv
TOOL_BIN=$WORKDIR/tlci-boundary-manifest$(stage0_host_exe_suffix)

"$COMPILER" build "$TOOL" --stdlib-root stdlib -o "$TOOL_BIN"

generate() {
    core=$1
    host=$2
    producer=$3
    stages=$4
    output=$5
    "$TOOL_BIN" "$core" "$host" "$producer" "$stages" "$output"
}

fail() {
    echo "TLCI boundary manifest: $*" >&2
    exit 1
}

generate "$CORE" "$HOST" "$PRODUCER" "$STAGES" "$ACTUAL"

if ! cmp -s "$CHECKED" "$ACTUAL"; then
    echo "TLCI boundary manifest is stale; regenerate with the self-hosted generator" >&2
    diff -u "$CHECKED" "$ACTUAL" >&2 || true
    exit 1
fi

awk -F '\t' '
    NR == 1 {
        if (NF != 14 || $1 != "kind" || $2 != "identity") exit 1
        next
    }
    NF != 14 { exit 1 }
    {
        for (i = 1; i <= NF; i++) if ($i == "") exit 1
        key = $1 "\t" $2
        if (++seen[key] != 1) exit 1
        kinds[$1]++
    }
    END {
        if (kinds["stage"] < 20 || kinds["callback"] < 1) exit 1
    }
' "$ACTUAL" || fail "generated rows are incomplete, malformed, or duplicated"

if grep -E '0x[0-9A-Fa-f]+|(^|[[:space:]])/[[:alnum:]_.-]+/' "$ACTUAL" >/dev/null; then
    fail "generated output contains a raw address or absolute host path"
fi

expect_failure() {
    label=$1
    expected=$2
    core=$3
    host=$4
    producer=$5
    stages=$6
    stdout=$WORKDIR/$label.stdout
    stderr=$WORKDIR/$label.stderr
    output=$WORKDIR/$label.tsv

    if generate "$core" "$host" "$producer" "$stages" "$output" \
        >"$stdout" 2>"$stderr"; then
        fail "$label mutation was accepted"
    fi
    if ! grep -F "$expected" "$stderr" >/dev/null; then
        sed 's/^/  /' "$stderr" >&2 || true
        fail "$label diagnostic did not contain: $expected"
    fi
}

# Version skew must fail before a manifest can claim the wrong stable ABI.
awk '
    /\(define tlci-callback-abi-version : i64/ { in_version = 1 }
    in_version && !changed && $0 == "  2)" { $0 = "  3)"; changed = 1; in_version = 0 }
    { print }
' "$CORE" >"$WORKDIR/version-core.tl"
expect_failure version-skew "ABI-version: host/callback version skew" \
    "$WORKDIR/version-core.tl" "$HOST" "$PRODUCER" "$STAGES"

# A repeated stable name is ambiguous even if its spelling is unchanged.
cp "$CORE" "$WORKDIR/duplicate-core.tl"
printf '\n(define tlci-host-callback-name-fuel-check : String\n  "fuel-check")\n' \
    >>"$WORKDIR/duplicate-core.tl"
expect_failure duplicate-name "fuel-check: duplicate ABI name declaration" \
    "$WORKDIR/duplicate-core.tl" "$HOST" "$PRODUCER" "$STAGES"

# Removing a production registration leaves the ABI catalog incomplete.
awk '
    /\(define \(compiler-comptime-host-table\)/ { in_table = 1 }
    in_table && !removed && /\(compiler-comptime-host-registry-add!/ {
        removing = 1
        removed = 1
        next
    }
    removing {
        if (/compiler-comptime-host-callback-fuel-check\)/) removing = 0
        next
    }
    { print }
' "$HOST" >"$WORKDIR/missing-registration-host.tl"
expect_failure missing-registration "ABI/host row count skew" \
    "$CORE" "$WORKDIR/missing-registration-host.tl" "$PRODUCER" "$STAGES"

# A name may not be rebound to another callback implementation.
awk '
    /\(define \(compiler-comptime-host-table\)/ { in_table = 1 }
    in_table && !changed && /compiler-comptime-host-callback-fuel-check\)/ {
        sub(/compiler-comptime-host-callback-fuel-check/, "compiler-comptime-host-callback-diagnostic")
        changed = 1
    }
    { print }
' "$HOST" >"$WORKDIR/binding-skew-host.tl"
expect_failure binding-skew "fuel-check: implementation binding skew" \
    "$CORE" "$WORKDIR/binding-skew-host.tl" "$PRODUCER" "$STAGES"

# Every callback body (or its one-hop typed adapter) must retain the session,
# first-failure, and malformed-request guards before it can mutate host state.
awk '
    /\(define \(compiler-comptime-host-callback-fuel-check/ { in_callback = 1 }
    in_callback && /compiler-comptime-host-session-cookie/ {
        gsub(/compiler-comptime-host-session-cookie/, "compiler-comptime-host-cookie-unchecked")
    }
    in_callback && /^\(define / && !/callback-fuel-check/ { in_callback = 0 }
    { print }
' "$HOST" >"$WORKDIR/missing-guard-host.tl"
expect_failure missing-guard "fuel-check: implementation has no direct or one-hop session/bounds failure guard" \
    "$CORE" "$WORKDIR/missing-guard-host.tl" "$PRODUCER" "$STAGES"

# New callback spellings remain rejected until assigned to an audited
# capability class; synchronized renaming cannot bypass the audit contract.
sed 's/fuel-check/new-unaudited-callback/g' "$CORE" >"$WORKDIR/capability-core.tl"
sed 's/fuel-check/new-unaudited-callback/g' "$HOST" >"$WORKDIR/capability-host.tl"
expect_failure missing-capability "new-unaudited-callback: callback is not assigned to an audited capability class" \
    "$WORKDIR/capability-core.tl" "$WORKDIR/capability-host.tl" "$PRODUCER" "$STAGES"

# Producer-side callback imports must not name identities absent from the
# shared ABI/host catalog.
awk '
    !changed && /tlci_core\.tlci-host-callback-name-push-operand/ {
        sub(/tlci_core\.tlci-host-callback-name-push-operand/, "tlci_core.tlci-host-callback-name-not-cataloged")
        changed = 1
    }
    { print }
' "$PRODUCER" >"$WORKDIR/producer-alone.tl"
expect_failure producer-alone "not-cataloged: native producer references a callback with no ABI catalog row" \
    "$CORE" "$HOST" "$WORKDIR/producer-alone.tl" "$STAGES"

# Admission rows are executable audit links, not prose: stale stable source
# identities fail with the stage name and path/token pair.
sed 's/src\/tlci_core.tl:tlci-parse-image/src\/tlci_core.tl:tlci-parse-image-missing/' \
    "$STAGES" >"$WORKDIR/missing-stage.tsv"
expect_failure missing-stage "image-container-parse: missing source site" \
    "$CORE" "$HOST" "$PRODUCER" "$WORKDIR/missing-stage.tsv"

stage_count=$(awk -F '\t' '$1 == "stage" { count++ } END { print count + 0 }' "$ACTUAL")
callback_count=$(awk -F '\t' '$1 == "callback" { count++ } END { print count + 0 }' "$ACTUAL")
echo "TLCI boundary manifest verified: $stage_count admission stages, $callback_count derived callbacks"
