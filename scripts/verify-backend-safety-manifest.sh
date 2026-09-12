#!/usr/bin/env sh
set -eu

# Source-derived, self-hosted backend safety inventory and mutation gate.
# Refs #7271. This audits contracts; it is not a proof of generated code.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-stage0.sh"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-backend-safety-manifest.sh" >&2
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
    echo "backend safety manifest compiler is not executable: $COMPILER" >&2
    exit 1
fi

mkdir -p "$ROOT/target"
WORKDIR=$(mktemp -d "$ROOT/target/backend-safety-manifest.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

TOOL_BIN=$WORKDIR/backend-safety-manifest$(stage0_host_exe_suffix)
"$COMPILER" build tools/backend-safety-manifest/main.tl --stdlib-root stdlib -o "$TOOL_BIN"

REGISTRIES=tools/backend-safety-manifest/registries.tsv
CATALOG=tools/backend-safety-manifest/catalog.tsv
CONTRACTS=tools/backend-safety-manifest/contracts.tsv
CHECKED=docs/backend-safety-contract-manifest.tsv

fail() {
    echo "backend safety manifest: $*" >&2
    exit 1
}

generate() {
    "$TOOL_BIN" "$1" "$2" "$3" "$4" "$5"
}

generate "$ROOT" "$REGISTRIES" "$CATALOG" "$CONTRACTS" "$WORKDIR/current.tsv"
if ! cmp -s "$CHECKED" "$WORKDIR/current.tsv"; then
    diff -u "$CHECKED" "$WORKDIR/current.tsv" >&2 || true
    fail "checked manifest is stale; regenerate with the self-hosted generator"
fi

awk -F '\t' '
    NR == 1 {
        if (NF != 14 || $1 != "domain" || $2 != "identity" || $14 != "source_site") exit 1
        next
    }
    NF != 14 { exit 1 }
    {
        for (i = 1; i <= NF; i++) if ($i == "") exit 1
        key = $1 "\t" $2
        if (++seen[key] != 1) exit 1
        count++
        if ($1 == "ir_instr") ir++
        if ($1 == "object_instr") object++
    }
    END { if (count < 200 || ir < 50 || object < 20) exit 1 }
' "$WORKDIR/current.tsv" || fail "malformed, missing, or duplicated output rows"

while IFS="$(printf '\t')" read -r domain identity contract witness disposition; do
    [ "$domain" = domain ] && continue
    case "$witness" in
        scripts/* | src/tests/* | src/*_tests.tl | src/compiler_object_elf.tl | tests/*) ;;
        *) fail "$domain.$identity: witness must be a checked repository test/gate" ;;
    esac
    [ -f "$witness" ] || fail "$domain.$identity: witness not found: $witness"
    case "$disposition" in
        checked | fail-closed | elf-only | subset:\#* | blocked:\#*) ;;
        *) fail "$domain.$identity: unknown disposition: $disposition" ;;
    esac
done < "$CATALOG"

mkdir -p "$WORKDIR/source/src"
for name in compiler_ir_types compiler_lower compiler_abi compiler_regalloc \
    compiler_backend compiler_object compiler_object_asm compiler_object_elf compiler_object_coff; do
    cp "src/$name.tl" "$WORKDIR/source/src/$name.tl"
done

expect_failure() {
    label=$1
    expected=$2
    registry=$3
    catalog=$4
    contracts=$5
    if generate "$WORKDIR/source" "$registry" "$catalog" "$contracts" \
        "$WORKDIR/$label.tsv" >"$WORKDIR/$label.stdout" 2>"$WORKDIR/$label.stderr"; then
        fail "$label mutation was accepted"
    fi
    if ! grep -F "$expected" "$WORKDIR/$label.stderr" >/dev/null; then
        sed 's/^/  /' "$WORKDIR/$label.stderr" >&2 || true
        fail "$label diagnostic did not name $expected"
    fi
}

# A newly added production identity and a deleted catalog identity both fail.
sed '/^(defenum CompilerIrInstr$/a\  (AuditMutation)' \
    src/compiler_ir_types.tl > "$WORKDIR/source/src/compiler_ir_types.tl"
expect_failure new-instruction "ir_instr.AuditMutation: missing contract row" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_ir_types.tl "$WORKDIR/source/src/compiler_ir_types.tl"

sed '/^ir_instr[[:space:]]Mov[[:space:]]/d' "$CATALOG" > "$WORKDIR/missing-catalog.tsv"
expect_failure missing-row "ir_instr.Mov: missing contract row" \
    "$REGISTRIES" "$WORKDIR/missing-catalog.tsv" "$CONTRACTS"

# Optimizer effects cannot silently drop a memory side effect.
sed 's/CompilerIrEffect.MemoryRead/CompilerIrEffect.Pure/g' \
    src/compiler_ir_types.tl > "$WORKDIR/source/src/compiler_ir_types.tl"
expect_failure dropped-side-effect "optimizer effect differs" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_ir_types.tl "$WORKDIR/source/src/compiler_ir_types.tl"

# Guard placement, aggregate class, stack reservation, lane mask, and target
# serializer routing are independent anchors. Existing execution fixtures in
# catalog.tsv remain the authority for dynamic correctness.
sed 's/"    cmpq "/"    nop "/g' src/compiler_backend.tl \
    > "$WORKDIR/source/src/compiler_backend.tl"
expect_failure missing-trap "bounds-variable-dominance" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_backend.tl "$WORKDIR/source/src/compiler_backend.tl"

sed 's/lower-c-abi-sysv-pack-f32-sse?/lower-c-abi-sysv-pack-f32-sse-removed?/g' \
    src/compiler_lower.tl > "$WORKDIR/source/src/compiler_lower.tl"
expect_failure aggregate-class "sysv-sse-aggregate-class" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_lower.tl "$WORKDIR/source/src/compiler_lower.tl"

sed 's/Windows) 32/Windows) 16/g' src/compiler_abi.tl \
    > "$WORKDIR/source/src/compiler_abi.tl"
expect_failure shadow-space "win64-shadow-space" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_abi.tl "$WORKDIR/source/src/compiler_abi.tl"

sed 's/compiler-reg-scratch-pick-register-with-siblings/compiler-reg-scratch-pick-register-without-siblings/g' \
    src/compiler_regalloc.tl > "$WORKDIR/source/src/compiler_regalloc.tl"
expect_failure scratch-clobber "scratch-live-home" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_regalloc.tl "$WORKDIR/source/src/compiler_regalloc.tl"

sed 's/"}{z}/"}/g' src/compiler_backend.tl \
    > "$WORKDIR/source/src/compiler_backend.tl"
expect_failure unmasked-read "avx512-masked-read" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_backend.tl "$WORKDIR/source/src/compiler_backend.tl"

sed 's/CompilerObjectX64Instr.MovRcxRax/CompilerObjectX64Instr.MovRcxRaxRemoved/g' \
    src/compiler_object_asm.tl > "$WORKDIR/source/src/compiler_object_asm.tl"
expect_failure asm-object-route "missing assembly/ELF/COFF instruction route" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"
cp src/compiler_object_asm.tl "$WORKDIR/source/src/compiler_object_asm.tl"

sed 's/\[(cobj.CompilerObjectX64Instr.Raw _) (set! ok false)\]/[(cobj.CompilerObjectX64Instr.Raw _) (set! ok true)]/g' \
    src/compiler_object_coff.tl > "$WORKDIR/source/src/compiler_object_coff.tl"
expect_failure raw-coff-admission "raw-coff-reject" \
    "$REGISTRIES" "$CATALOG" "$CONTRACTS"

echo "backend safety manifest: production identities, source guards, and drift mutations passed"
