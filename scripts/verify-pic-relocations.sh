#!/usr/bin/env sh
set -eu

# verify-pic-relocations.sh - object-level gate for --pic assembly/fixups.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "PIC relocation verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/pic-relocation-verify/$HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

FIXTURE="$WORKDIR/pic_probe.tl"
cat > "$FIXTURE" <<'EOF'
(import "stdlib/string.tl")

(define greeting : String "hi")
(define answer : i64 42)
(define (len-fn) : i64
  (string-length greeting))
(define fn-value : (-> i64) len-fn)
(define (main) : i64
  (+ answer (len-fn)))
EOF

compile_pic() {
    _target=$1
    _asm=$2
    if ! "$COMPILER" compile "$FIXTURE" \
        --pic \
        --target "$_target" \
        -o "$_asm" \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        > "$WORKDIR/compile.$_target.stdout" \
        2> "$WORKDIR/compile.$_target.stderr"; then
        echo "PIC compile failed for $_target" >&2
        sed 's/^/  /' "$WORKDIR/compile.$_target.stdout" >&2 || true
        sed 's/^/  /' "$WORKDIR/compile.$_target.stderr" >&2 || true
        return 1
    fi
}

validate_fixups() {
    _asm=$1
    _fixups=$2
    _rows="$WORKDIR/fixup.rows"

    if ! [ -s "$_fixups" ]; then
        echo "missing PIC fixup table: $_fixups" >&2
        return 1
    fi
    if grep -F " - .L_tl_pic_image_base" "$_asm" >/dev/null; then
        echo "PIC assembly still contains cross-section image-base expressions" >&2
        return 1
    fi
    if ! grep -F "    .quad 0" "$_asm" >/dev/null; then
        echo "PIC assembly did not emit neutral pointer placeholders" >&2
        return 1
    fi

    if ! awk '
        NR == 1 {
            if ($0 != "typelisp-pic-fixups v1") {
                print "invalid fixup header: " $0 > "/dev/stderr"
                bad = 1
            }
            next
        }
        {
            if (NF != 4) {
                print "malformed fixup row: " $0 > "/dev/stderr"
                bad = 1
            }
            if ($1 != "data" && $1 != "rodata") {
                print "unexpected fixup section: " $1 > "/dev/stderr"
                bad = 1
            }
            if ($2 !~ /^[0-9]+$/) {
                print "non-numeric fixup offset: " $2 > "/dev/stderr"
                bad = 1
            } else if (($2 % 8) != 0) {
                print "unaligned fixup offset: " $2 > "/dev/stderr"
                bad = 1
            }
            count += 1
        }
        END {
            if (NR == 0) {
                print "empty fixup file" > "/dev/stderr"
                bad = 1
            }
            if (count < 2) {
                print "expected multiple data/rodata fixups, got " count > "/dev/stderr"
                bad = 1
            }
            exit bad ? 1 : 0
        }
    ' "$_fixups"; then
        return 1
    fi

    tail -n +2 "$_fixups" > "$_rows"
    while IFS=' ' read -r _section _offset _site _target _extra; do
        [ -n "$_site" ] || continue
        if [ -n "${_extra:-}" ]; then
            echo "malformed fixup row has extra fields: $_section $_offset $_site $_target $_extra" >&2
            return 1
        fi
        if ! grep -Fx "$_site:" "$_asm" >/dev/null; then
            echo "fixup site label is not present in assembly: $_site" >&2
            return 1
        fi
        if ! grep -Fx "$_target:" "$_asm" >/dev/null; then
            echo "fixup target label is not present in assembly: $_target" >&2
            return 1
        fi
    done < "$_rows"
}

verify_linux_pic() {
    command -v as >/dev/null 2>&1 || {
        echo "missing assembler: as" >&2
        return 1
    }
    command -v readelf >/dev/null 2>&1 || {
        echo "missing relocation dumper: readelf" >&2
        return 1
    }

    _asm="$WORKDIR/pic_probe_linux.s"
    _obj="$WORKDIR/pic_probe_linux.o"
    _relocs="$WORKDIR/pic_probe_linux.relocs"

    compile_pic linux-x86_64 "$_asm"
    validate_fixups "$_asm" "$_asm.fixups"
    if ! as "$_asm" -o "$_obj" > "$WORKDIR/as.stdout" 2> "$WORKDIR/as.stderr"; then
        echo "PIC assembly did not assemble with GNU as" >&2
        sed 's/^/  /' "$WORKDIR/as.stdout" >&2 || true
        sed 's/^/  /' "$WORKDIR/as.stderr" >&2 || true
        return 1
    fi
    readelf -r "$_obj" > "$_relocs"
    if grep -E "R_X86_64_(64|32|32S)([^A-Za-z0-9_]|$)" "$_relocs" >/dev/null; then
        echo "PIC object contains disallowed absolute ELF relocations" >&2
        sed 's/^/  /' "$_relocs" >&2 || true
        return 1
    fi
    if grep -E "Relocation section '.rela\\.(data|rodata)'" "$_relocs" >/dev/null; then
        echo "PIC object contains data/rodata relocations outside the fixup table" >&2
        sed 's/^/  /' "$_relocs" >&2 || true
        return 1
    fi
}

verify_windows_pic() {
    command -v clang >/dev/null 2>&1 || {
        echo "missing assembler: clang" >&2
        return 1
    }
    command -v llvm-readobj >/dev/null 2>&1 || {
        echo "missing relocation dumper: llvm-readobj" >&2
        return 1
    }

    _asm="$WORKDIR/pic_probe_windows.s"
    _obj="$WORKDIR/pic_probe_windows.obj"
    _relocs="$WORKDIR/pic_probe_windows.relocs"

    compile_pic windows-x86_64 "$_asm"
    validate_fixups "$_asm" "$_asm.fixups"
    if ! clang --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" \
        > "$WORKDIR/clang.stdout" 2> "$WORKDIR/clang.stderr"; then
        echo "PIC assembly did not assemble with clang for COFF" >&2
        sed 's/^/  /' "$WORKDIR/clang.stdout" >&2 || true
        sed 's/^/  /' "$WORKDIR/clang.stderr" >&2 || true
        return 1
    fi
    llvm-readobj --relocations "$_obj" > "$_relocs"
    if grep -F "IMAGE_REL_AMD64_ADDR64" "$_relocs" >/dev/null; then
        echo "PIC object contains disallowed absolute COFF relocations" >&2
        sed 's/^/  /' "$_relocs" >&2 || true
        return 1
    fi
}

if [ "$HOST_OS" = linux ]; then
    verify_linux_pic
else
    verify_windows_pic
fi

echo "PIC relocation verification passed for $HOST_OS"
