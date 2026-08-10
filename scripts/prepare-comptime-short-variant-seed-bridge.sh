#!/usr/bin/env sh
set -eu

# Prepare a temporary source mirror that the previously published stage0 can
# compile. The mirror can restore old well-known enum spellings/shapes and also
# rewrites the rebuilt compiler's private StructGet parser name in
# stdlib.comptime. This is a bootstrap boundary, not a public compatibility
# surface.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 output-directory" >&2
    exit 2
fi

OUT=$1
case "$OUT" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) OUT="$ROOT/$OUT" ;;
esac
case "$OUT" in
    "$ROOT"/target/*) ;;
    *)
        echo "comptime short-variant seed bridge must stay below $ROOT/target" >&2
        exit 2
        ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$ROOT/src" "$OUT/src"
cp -R "$ROOT/stdlib" "$OUT/stdlib"
cp -R "$ROOT/bootstrap" "$OUT/bootstrap"
mkdir -p "$OUT/tests"
cp "$ROOT/tests/bootstrap_ctfe_while_probe.tl" \
    "$OUT/tests/bootstrap_ctfe_while_probe.tl"

# Seeds carrying structured macro provenance wrap every captured Expr in a
# caller-origin node. That predates the private place bridge and can make a
# composite operand such as `(array-ref map.slots i)` alias its dotted child.
# The temporary mirror can use the seed's legacy public source spellings, so
# rewrite only these reserved bridge calls before compiling the one-generation
# compatibility compiler.
PYTHON=
if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1; then
    PYTHON=python
else
    echo "comptime seed bridge requires python3 or python" >&2
    exit 1
fi
"$PYTHON" "$ROOT/scripts/rewrite-private-place-seed-bridge.py" \
    "$OUT/src" "$OUT/stdlib" "$OUT/bootstrap" "$OUT/tests"

# GNU sed is present on both supported bootstrap hosts (Linux and Git Bash).
# Word boundaries keep compiler-internal names such as AstExpr.Var and
# AstPattern.Variant unchanged. A seed that already accepts the short
# qualified spelling may set this mode to 0; that keeps its name ABI while
# still applying the old-shape TypeInfo enum bridge below.
LEGACY_SHORT_VARIANTS=${COMPTIME_SHORT_VARIANT_SEED_BRIDGE_LEGACY:-1}
REMOVE_TYPEINFO_SLICE=${COMPTIME_SEED_BRIDGE_REMOVE_SLICE:-1}
case "$LEGACY_SHORT_VARIANTS" in
    0 | 1) ;;
    *)
        echo "comptime short-variant seed bridge mode must be 0 or 1" >&2
        exit 2
        ;;
esac
case "$REMOVE_TYPEINFO_SLICE" in
    0 | 1) ;;
    *)
        echo "comptime TypeInfo Slice seed bridge mode must be 0 or 1" >&2
        exit 2
        ;;
esac
if [ "$LEGACY_SHORT_VARIANTS" = 1 ]; then
  find "$OUT/src" "$OUT/stdlib" "$OUT/bootstrap" "$OUT/tests" \
    -type f -name '*.tl' -exec sed -i \
    -e 's/\<Expr\.Bool\>/ExprBool/g' \
    -e 's/\<Expr\.Int\>/ExprInt/g' \
    -e 's/\<Expr\.Var\>/ExprVar/g' \
    -e 's/\<Expr\.Splice\>/ExprSplice/g' \
    -e 's/\<Expr\.If\>/ExprIf/g' \
    -e 's/\<Expr\.Call\>/ExprCall/g' \
    -e 's/\<Expr\.Begin\>/ExprBegin/g' \
    -e 's/\<Expr\.Quote\>/ExprQuote/g' \
    -e 's/\<Expr\.Quasiquote\>/ExprQuasiquote/g' \
    -e 's/\<Expr\.Unquote\>/ExprUnquote/g' \
    -e 's/\<Expr\.UnquoteSplicing\>/ExprUnquoteSplicing/g' \
    -e 's/\<Pattern\.Wildcard\>/PatternWildcard/g' \
    -e 's/\<Pattern\.Binding\>/PatternBinding/g' \
    -e 's/\<Pattern\.Variant\>/PatternVariant/g' \
    -e 's/\<TypeInfo\.Builtin\>/TypeInfoBuiltin/g' \
    -e 's/\<TypeInfo\.Array\>/TypeInfoArray/g' \
    -e 's/\<TypeInfo\.DynArray\>/TypeInfoDynArray/g' \
    -e 's/\<TypeInfo\.Function\>/TypeInfoFunction/g' \
    -e 's/\<TypeInfo\.Tuple\>/TypeInfoTuple/g' \
    -e 's/\<TypeInfo\.Struct\>/TypeInfoStruct/g' \
    -e 's/\<TypeInfo\.Enum\>/TypeInfoEnum/g' \
    -e 's/\<TypeInfo\.Opaque\>/TypeInfoOpaque/g' \
    -e 's/\<TypeInfo\.Slice\>/TypeInfoSlice/g' \
    {} +
fi

COMPTIME="$OUT/stdlib/comptime.tl"
sed -i -e 's/(__tl_struct-get /(struct-get /g' "$COMPTIME"

if [ "$REMOVE_TYPEINFO_SLICE" = 1 ] && [ "$LEGACY_SHORT_VARIANTS" = 1 ]; then
  sed -i \
      -e 's/^  (Bool bool)$/  (ExprBool bool)/' \
      -e 's/^  (Int i64)$/  (ExprInt i64)/' \
      -e 's/^  (Var String)$/  (ExprVar String)/' \
      -e 's/^  (Splice (Box Expr))$/  (ExprSplice (Box Expr))/' \
      -e 's/^  (If (Box Expr) (Box Expr) (Box Expr))$/  (ExprIf (Box Expr) (Box Expr) (Box Expr))/' \
      -e 's/^  (Call (Box Expr) ExprList)$/  (ExprCall (Box Expr) ExprList)/' \
      -e 's/^  (Begin ExprList)$/  (ExprBegin ExprList)/' \
      -e 's/^  (Quote (Box Expr))$/  (ExprQuote (Box Expr))/' \
      -e 's/^  (Quasiquote (Box Expr))$/  (ExprQuasiquote (Box Expr))/' \
      -e 's/^  (Unquote (Box Expr))$/  (ExprUnquote (Box Expr))/' \
      -e 's/^  (UnquoteSplicing (Box Expr)))$/  (ExprUnquoteSplicing (Box Expr)))/' \
      -e 's/^  (Wildcard)$/  (PatternWildcard)/' \
      -e 's/^  (Binding String)$/  (PatternBinding String)/' \
      -e 's/^  (Variant String PatternList))$/  (PatternVariant String PatternList))/' \
      -e 's/^  (Builtin String)$/  (TypeInfoBuiltin String)/' \
      -e 's/^  (Array (Box TypeInfo) i64)$/  (TypeInfoArray (Box TypeInfo) i64)/' \
      -e 's/^  (DynArray (Box TypeInfo))$/  (TypeInfoDynArray (Box TypeInfo))/' \
      -e 's/^  (Function TypeInfoList (Box TypeInfo))$/  (TypeInfoFunction TypeInfoList (Box TypeInfo))/' \
      -e 's/^  (Tuple TypeInfoList)$/  (TypeInfoTuple TypeInfoList)/' \
      -e 's/^  (Struct String TypeFieldList)$/  (TypeInfoStruct String TypeFieldList)/' \
      -e 's/^  (Enum String TypeVariantList)$/  (TypeInfoEnum String TypeVariantList)/' \
      -e '/^  (Slice (Box TypeInfo)))$/d' \
      -e 's/^  (Opaque String)$/  (TypeInfoOpaque String))/' \
      "$COMPTIME"
elif [ "$REMOVE_TYPEINFO_SLICE" = 1 ]; then
  sed -i \
      -e '/^  (Slice (Box TypeInfo)))$/d' \
      -e 's/^  (Opaque String)$/  (Opaque String))/' \
      "$COMPTIME"
fi

if [ "$REMOVE_TYPEINFO_SLICE" = 1 ] && [ "$LEGACY_SHORT_VARIANTS" = 1 ]; then
  grep -qF '(ExprBool bool)' "$COMPTIME" || {
    echo "seed bridge did not restore the legacy Expr declaration" >&2
    exit 1
  }
  grep -qF '(ExprUnquoteSplicing (Box Expr)))' "$COMPTIME" || {
    echo "seed bridge did not restore the final legacy Expr variant" >&2
    exit 1
  }
  grep -qF '(PatternVariant String PatternList))' "$COMPTIME" || {
    echo "seed bridge did not restore the final legacy Pattern variant" >&2
    exit 1
  }
  grep -qF '(TypeInfoOpaque String))' "$COMPTIME" || {
    echo "seed bridge did not restore the final legacy TypeInfo Opaque variant" >&2
    exit 1
  }
elif [ "$REMOVE_TYPEINFO_SLICE" = 1 ]; then
  grep -qF '(Opaque String))' "$COMPTIME" || {
    echo "seed bridge did not restore the final short TypeInfo Opaque variant" >&2
    exit 1
  }
fi
if [ "$REMOVE_TYPEINFO_SLICE" = 1 ] && \
    { grep -qF '(TypeInfoSlice' "$COMPTIME" || \
      grep -qF '(Slice (Box TypeInfo))' "$COMPTIME"; }; then
    echo "seed bridge retained the new TypeInfo Slice variant" >&2
    exit 1
fi
if grep -qF '(__tl_struct-get ' "$COMPTIME"; then
    echo "seed bridge retained the rebuilt compiler's private StructGet name" >&2
    exit 1
fi
grep -qF '(struct-get items len)' "$COMPTIME" || {
    echo "seed bridge did not restore the seed StructGet spelling" >&2
    exit 1
}
grep -qF '(compiler-builtin-resolve-name insert-missing "Var")' \
    "$OUT/src/compiler_builtin_ids.tl" || {
    echo "seed bridge changed the new short-name compiler ABI" >&2
    exit 1
}
if grep -qF 'AstPatternVariant' "$OUT/src/compiler_typecheck_core.tl"; then
    echo "seed bridge rewrote compiler-internal AstPattern.Variant" >&2
    exit 1
fi

echo "comptime short-variant seed bridge prepared at $OUT"
