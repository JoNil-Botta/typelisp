#!/usr/bin/env sh
set -eu

# check-build-invariance.sh - opt1-built vs opt2-built compiler output gate.
#
# A correct compiler's emitted assembly depends on the source, target, backend
# mode, and requested optimization level. It must not depend on whether the
# compiler binary itself was built at opt1 or opt2. CI supplies a converged
# opt2-built stage4; this gate builds one opt1 compiler from current source and
# compares their emitted assembly over a fixed Linux corpus.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-build-invariance.sh

Requires TYPELISP_BIN to point at CI's converged Linux opt2-built stage4
compiler. Builds one opt1 compiler from src/main.tl, then compares emitted
assembly for a fixed corpus.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "build-invariance check is Linux-only" >&2
        exit 1
        ;;
esac

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "check-build-invariance requires TYPELISP_BIN" >&2
    exit 2
fi

COMPILER=$TYPELISP_BIN
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
if [ "$NL_HOST_OS" != linux ]; then
    echo "build-invariance check is Linux-only" >&2
    exit 1
fi
configure_toolchain

WORKDIR="$ROOT/target/build-invariance"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

HANDOFF_PATH_FILE=""
if [ "${TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE+x}" = x ]; then
    HANDOFF_PATH_FILE=$TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE
    if [ -z "$HANDOFF_PATH_FILE" ]; then
        echo "build-invariance opt1 reference path file is empty" >&2
        exit 2
    fi
    case "$HANDOFF_PATH_FILE" in
        /*) ;;
        *) HANDOFF_PATH_FILE="$ROOT/$HANDOFF_PATH_FILE" ;;
    esac
    rm -f "$HANDOFF_PATH_FILE"
fi

print_log_pair() {
    label=$1
    stdout=$2
    stderr=$3
    echo "[$label] stdout:" >&2
    sed 's/^/  /' "$stdout" >&2 || true
    echo "[$label] stderr:" >&2
    sed 's/^/  /' "$stderr" >&2 || true
}

print_asm_fingerprint() {
    label=$1
    file=$2
    bytes=$(wc -c < "$file" | tr -d ' ')
    lines=$(wc -l < "$file" | tr -d ' ')
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum "$file" | sed 's/[[:space:]].*//')
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(shasum -a 256 "$file" | sed 's/[[:space:]].*//')
    else
        hash=unavailable
    fi
    echo "[build-invariance]   $label sha256=$hash bytes=$bytes lines=$lines path=$file" >&2
}

compile_stage() {
    opt_level=$1
    stage_label=$2
    compiler=$3
    asm=$4
    stdout=$5
    stderr=$6

    echo "[build-invariance] opt$opt_level $stage_label: compile src/main.tl"
    if ! ci_timing_run "compiler-opt$opt_level" compile \
        run_with_heartbeat_capture \
        "build-invariance opt$opt_level $stage_label" \
        "$stdout" \
        "$stderr" \
        "$compiler" compile src/main.tl \
        -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$opt_level" \
        --stdlib-root stdlib \
        --stdlib-root src; then
        print_log_pair "build-invariance opt$opt_level $stage_label compile failed" "$stdout" "$stderr"
        exit 1
    fi
    if [ ! -s "$asm" ]; then
        print_log_pair "build-invariance opt$opt_level $stage_label compile output" "$stdout" "$stderr"
        echo "[build-invariance] empty assembly: $asm" >&2
        exit 1
    fi
}

build_opt1_compiler() {
    outdir="$WORKDIR/opt1"
    mkdir -p "$outdir"

    opt1_asm="$outdir/opt1.s"
    opt1_obj="$outdir/opt1.$NL_OBJ_EXT"
    opt1_bin="$outdir/opt1$NL_BIN_EXT"

    compile_stage 1 "stage4-to-opt1" "$COMPILER" "$opt1_asm" "$outdir/opt1.stdout" "$outdir/opt1.stderr"
    ci_timing_run compiler-opt1 assemble-link \
        assemble_and_link "build-invariance opt1 compiler" "$opt1_asm" "$opt1_obj" "$opt1_bin"

    if [ ! -x "$opt1_bin" ]; then
        chmod +x "$opt1_bin" 2>/dev/null || true
    fi
    if [ ! -x "$opt1_bin" ]; then
        echo "[build-invariance] opt1 compiler is not executable: $opt1_bin" >&2
        exit 1
    fi
}

write_corpus() {
    corpus_file=$1
    {
        printf '%s\n' "selfhost_main_opt1|src/main.tl|1"
        printf '%s\n' "selfhost_main_opt2|src/main.tl|2"
        awk -F'|' '
            /^[[:space:]]*#/ { next }
            NF < 2 { next }
            $1 == "" || $2 == "" { next }
            {
                print "integration_" $1 "|" $2 "|2"
            }
        ' tests/integration/native-linux.manifest
    } > "$corpus_file"
}

compile_source_for_case() {
    name=$1
    source=$2
    input_root=$3

    case "$name" in
        integration_sym_i64_env)
            input_dir="$input_root/sym_i64_env"
            rm -rf "$input_dir"
            mkdir -p "$input_dir"
            cp "$source" "$input_dir/sym_i64_env.tl"
            cp src/sym_i64_env.tl "$input_dir/sym_i64_env_core.tl"
            printf '%s\n' "$input_dir/sym_i64_env.tl"
            ;;
        *)
            printf '%s\n' "$source"
            ;;
    esac
}

compile_case() {
    compiler_label=$1
    compiler=$2
    name=$3
    source=$4
    opt_level=$5
    out=$6

    stdout="$out.stdout"
    stderr="$out.stderr"
    compile_source=$(compile_source_for_case "$name" "$source" "$WORKDIR/inputs/$name")
    echo "[build-invariance] $compiler_label compile $name opt$opt_level"
    if ! ci_timing_run "$compiler_label:$name" compile \
        run_with_heartbeat_capture \
        "build-invariance $compiler_label $name opt$opt_level" \
        "$stdout" \
        "$stderr" \
        "$compiler" compile "$compile_source" \
        -o "$out" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$opt_level" \
        --stdlib-root stdlib \
        --stdlib-root src; then
        print_log_pair "build-invariance $compiler_label $name opt$opt_level compile failed" "$stdout" "$stderr"
        exit 1
    fi
    if [ ! -s "$out" ]; then
        print_log_pair "build-invariance $compiler_label $name opt$opt_level compile output" "$stdout" "$stderr"
        echo "[build-invariance] empty assembly for $name: $out" >&2
        exit 1
    fi
}

compare_case() {
    name=$1
    left=$2
    right=$3

    if [ "$name" = selfhost_main_opt2 ]; then
        left_rbp=$(grep -cF "(,%rbp,1)" "$left" || true)
        right_rbp=$(grep -cF "(,%rbp,1)" "$right" || true)
        echo "[build-invariance] selfhost opt2 '(,%rbp,1)' count: opt1-built=$left_rbp opt2-built=$right_rbp"
    fi

    if ! ci_timing_run "$name" compare cmp -s "$left" "$right"; then
        echo "[build-invariance] BUILD-INVARIANCE MISMATCH: $name" >&2
        print_asm_fingerprint "opt1-built compiler output" "$left"
        print_asm_fingerprint "opt2-built compiler output" "$right"
        if [ "$name" = selfhost_main_opt2 ]; then
            echo "[build-invariance] '(,%rbp,1)' counts: opt1-built=$left_rbp opt2-built=$right_rbp" >&2
        fi
        if command -v diff >/dev/null 2>&1; then
            diff -u "$left" "$right" | sed -n '1,160p' >&2 || true
        else
            cmp -l "$left" "$right" | sed -n '1,80p' >&2 || true
        fi
        exit 1
    fi
}

echo "[build-invariance] incoming opt2-built stage4 compiler: $COMPILER"
construction_start=$(date +%s)
build_opt1_compiler
OPT1_COMPILER="$WORKDIR/opt1/opt1$NL_BIN_EXT"
OPT2_STAGE4="$COMPILER"
construction_end=$(date +%s)
construction_seconds=$((construction_end - construction_start))
echo "[build-invariance] compiler construction: ${construction_seconds}s"

CORPUS="$WORKDIR/corpus.txt"
LEFT_DIR="$WORKDIR/compare/opt1-built"
RIGHT_DIR="$WORKDIR/compare/opt2-built"
write_corpus "$CORPUS"
rm -rf "$LEFT_DIR" "$RIGHT_DIR"
mkdir -p "$LEFT_DIR" "$RIGHT_DIR"

corpus_start=$(date +%s)
case_count=0
while IFS='|' read -r name source opt_level; do
    [ -n "$name" ] || continue
    if [ ! -f "$source" ]; then
        echo "[build-invariance] corpus source not found for $name: $source" >&2
        exit 1
    fi
    left="$LEFT_DIR/$name.s"
    right="$RIGHT_DIR/$name.s"
    compile_case "opt1-built" "$OPT1_COMPILER" "$name" "$source" "$opt_level" "$left"
    compile_case "opt2-built" "$OPT2_STAGE4" "$name" "$source" "$opt_level" "$right"
    compare_case "$name" "$left" "$right"
    case_count=$((case_count + 1))
done < "$CORPUS"
corpus_end=$(date +%s)
corpus_seconds=$((corpus_end - corpus_start))

echo "[build-invariance] corpus comparison: ${corpus_seconds}s"
echo "build-invariance check passed for $case_count case(s)"

if [ -n "$HANDOFF_PATH_FILE" ]; then
    handoff_reference="$RIGHT_DIR/selfhost_main_opt1.s"
    if [ ! -s "$handoff_reference" ]; then
        echo "build-invariance validated opt1 reference is missing or empty: $handoff_reference" >&2
        exit 1
    fi
    handoff_dir=$(dirname "$HANDOFF_PATH_FILE")
    mkdir -p "$handoff_dir"
    handoff_tmp="$HANDOFF_PATH_FILE.tmp.$$"
    printf '%s\n' "$handoff_reference" > "$handoff_tmp"
    mv "$handoff_tmp" "$HANDOFF_PATH_FILE"
    echo "[build-invariance] published validated opt1 reference: $handoff_reference"
fi
