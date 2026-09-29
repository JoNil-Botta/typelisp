#!/usr/bin/env sh
set -eu
# Opt-in oracle for the DWARF inventory corpus in tests/fixtures/dwarf.
#
# Regenerates every GCC and Clang fixture with the pinned tools and requires
# the same section bytes as the checked-in copy, then cross-checks the scanner
# (tools/dwarf-inventory) against the tools on every object:
#   - its unit, DIE, attribute and per-class reference counts equal the counts
#     llvm-dwarfdump reports, where each unit header's .debug_abbrev offset is
#     one more section offset;
#   - every .rela.debug_info relocation lands on a recorded reference of the
#     same width;
#   - src/linker_dwarf_scan_core_tests.tl expects exactly the scanner's summary.
# The TypeLisp fixture follows the compiler, so the current compiler's --debug
# output is rebuilt with TYPELISP_BIN and checked the same way, and the script
# only reports whether the checked-in snapshot is still byte-identical.
# Generated translation units of 1000 and 10000 functions are checked the same
# way and must scan within SCALE_LIMIT_MIB, which only a linear scan fits.
# Every compiler and scanner run is memory-capped by run-memory-bounded.sh.
# A missing or differently versioned tool fails the run; nothing is skipped.
#
# usage: TYPELISP_BIN=target/bootstrap-fixpoint/stage3 scripts/analyze-dwarf-corpus.sh
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

COMPILER=${TYPELISP_BIN:-}
FIXTURES="$ROOT/tests/fixtures/dwarf"
TESTS="$ROOT/src/linker_dwarf_scan_core_tests.tl"
WORK="$ROOT/target/dwarf-corpus"
TOOL_LIMIT_MIB=4096
SCALE_LIMIT_MIB=512

fail() {
    echo "dwarf oracle: $*" >&2
    exit 1
}

[ -n "$COMPILER" ] || fail "set TYPELISP_BIN to a TypeLisp compiler"
case "$COMPILER" in
/*) ;;
*) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || fail "compiler is not executable: $COMPILER"

# require_version TOOL VERSION: TOOL --version names exactly VERSION.
require_version() {
    command -v "$1" >/dev/null 2>&1 || fail "missing pinned tool: $1"
    "$1" --version 2>/dev/null | head -n 3 | tr ' ' '\n' | grep -Fx "$2" >/dev/null ||
        fail "$1 is not version $2: $("$1" --version 2>/dev/null | head -n 3 | tr '\n' ' ')"
}
require_version gcc "16.2.1"
require_version clang "22.1.8"
require_version as "2.47"
require_version objcopy "2.47"
require_version readelf "2.47"
require_version llvm-dwarfdump "22.1.8"
for tool in awk comm head sha256sum sort tail; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

rm -rf "${WORK:?}"
mkdir -p "$WORK"

# bounded LIMIT_MIB COMMAND...: run COMMAND in the current directory under a
# memory cap; its stdout passes through, and the peak lands in
# $WORK/bounded.report. With BOUNDED_ACCEPT_FAILURE=yes a nonzero exit is
# accepted, but a timeout or the cap still fails the run.
BOUNDED_ACCEPT_FAILURE=no
bounded() {
    limit=$1
    shift
    status=0
    sh "$ROOT/scripts/run-memory-bounded.sh" --limit-mib "$limit" --timeout-seconds 600 \
        --working-directory "$PWD" --report "$WORK/bounded.report" -- "$@" \
        2>"$WORK/bounded.log" || status=$?
    [ "$status" -eq 0 ] && return 0
    if [ "$BOUNDED_ACCEPT_FAILURE" = yes ] &&
        grep -Fx 'reason=command-failure' "$WORK/bounded.report" >/dev/null; then
        return 0
    fi
    cat "$WORK/bounded.log" >&2
    fail "failed or exceeded $limit MiB: $*"
}

INVENTORY="$WORK/dwarf-inventory"
bounded "$TOOL_LIMIT_MIB" "$COMPILER" build tools/dwarf-inventory/main.tl -o "$INVENTORY" \
    --opt-level 2 --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" >/dev/null

# readelf -S -W rows as: index name type offset size info, with hex offset and
# size; the flags column may be empty, so info is counted from the end.
section_rows() {
    readelf -S -W "$1" | sed -n 's/^ *\[ *\([0-9][0-9]*\)\] /\1 /p' |
        awk '{ print $1, $2, $3, $5, $6, $(NF - 1) }'
}

# extract OBJECT DIR RELOCATABLE: one file per .debug_* section, named by its
# index, and DIR/sections.tsv (index, name, size, relocatable, file, sha256).
extract() {
    mkdir -p "$2"
    : > "$2/sections.tsv"
    section_rows "$1" | while read -r index name type offset size info; do
        case "$name" in .debug_*) ;; *) continue ;; esac
        [ "$type" != NOBITS ] || continue
        file=$(printf '%02d%s.bin' "$index" "$name")
        tail -c +$((0x$offset + 1)) "$1" | head -c $((0x$size)) > "$2/$file"
        sum=$(sha256sum "$2/$file" | cut -d ' ' -f 1)
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$name" "$((0x$size))" "$3" "$file" "$sum" \
            >> "$2/sections.tsv"
    done
}

# scan DIR...: the scanner's summary line for DIR, within SCALE_LIMIT_MIB.
scan() {
    bounded "$SCALE_LIMIT_MIB" "$INVENTORY" "$@" > "$WORK/inventory.txt"
    head -n 1 "$WORK/inventory.txt"
}

# oracle_counts OBJECT: the scanner's summary line, counted by llvm-dwarfdump.
# llvm-dwarfdump exits 1 on a split DWARF 4 unit whose ranges need the
# skeleton's DW_AT_GNU_ranges_base, after dumping every DIE.
oracle_counts() {
    BOUNDED_ACCEPT_FAILURE=yes
    bounded "$TOOL_LIMIT_MIB" llvm-dwarfdump --debug-info --debug-types -v "$1" \
        > "$WORK/llvm-dwarfdump.txt"
    BOUNDED_ACCEPT_FAILURE=no
    awk '
        function count(pattern, text) { return gsub(pattern, "", text) }
        /Unit: length = / {
            units++
            match($0, /version = 0x000[0-9]/)
            version = substr($0, RSTART + 15, 1) + 0
            secoff++
        }
        /^0x[0-9a-f]+: +DW_TAG_/ { dies++ }
        match($0, /DW_AT_[A-Za-z0-9_]+ \[DW_FORM_[A-Za-z0-9_]+\]/) {
            attrs++
            split(substr($0, RSTART, RLENGTH), parts, " ")
            attr = parts[1]
            form = substr(parts[2], 2, length(parts[2]) - 2)
            if (form ~ /^DW_FORM_ref(1|2|4|8|_udata)$/) unit++
            else if (form == "DW_FORM_ref_addr") info++
            else if (form == "DW_FORM_ref_sig8") sig++
            else if (form == "DW_FORM_strp") str++
            else if (form == "DW_FORM_line_strp") lstr++
            else if (form ~ /^DW_FORM_strx/ || form == "DW_FORM_GNU_str_index") strx++
            else if (form == "DW_FORM_addr") addr++
            else if (form ~ /^DW_FORM_addrx/ || form == "DW_FORM_GNU_addr_index") addrx++
            else if (form == "DW_FORM_sec_offset") secoff++
            else if (form == "DW_FORM_rnglistx") rngx++
            else if (form == "DW_FORM_loclistx") locx++
            else if (version == 3 && (form == "DW_FORM_data4" || form == "DW_FORM_data8") &&
                     attr ~ /^DW_AT_(stmt_list|ranges|location|frame_base|macro_info)$/) secoff++
            if (form == "DW_FORM_exprloc" || form ~ /^DW_FORM_block/) {
                ops = $0 " "
                addr += count("DW_OP_addr[^x_a-z]", ops)
                addrx += count("DW_OP_(addrx|constx|GNU_addr_index|GNU_const_index)[^_a-z]", ops)
                unit += count("DW_OP_(call2|call4|GNU_parameter_ref)[^_a-z]", ops)
                info += count("DW_OP_(call_ref|implicit_pointer|GNU_implicit_pointer|GNU_variable_value)[^_a-z]", ops)
            }
        }
        END {
            printf "units=%d dies=%d attrs=%d unit=%d info=%d sig=%d str=%d lstr=%d strx=%d addr=%d addrx=%d secoff=%d rngx=%d locx=%d\n",
                units, dies, attrs, unit, info, sig, str, lstr, strx, addr, addrx, secoff, rngx, locx
        }' "$WORK/llvm-dwarfdump.txt"
}

# check_relocations OBJECT DIR: prints how many .rela.debug_info entries there
# are and fails unless each one is a recorded reference of the same width.
check_relocations() {
    bounded "$SCALE_LIMIT_MIB" "$INVENTORY" --references "$2" > "$WORK/references.out"
    sed -n 's/^ref input=1 section=\([0-9]*\) offset=\([0-9]*\) width=\([0-9]*\) .*/\1 \2 \3/p' \
        "$WORK/references.out" | sort -u > "$WORK/references.txt"
    section_rows "$1" | awk '$2 == ".rela.debug_info" { print $4, $6 }' > "$WORK/rela-sections.txt"
    readelf -r -W "$1" | awk -v sections="$WORK/rela-sections.txt" '
        function hex(text, value, i) {
            value = 0
            text = tolower(text)
            sub(/^0x/, "", text)
            for (i = 1; i <= length(text); i++)
                value = value * 16 + index("0123456789abcdef", substr(text, i, 1)) - 1
            return value
        }
        BEGIN {
            while ((getline row < sections) > 0) {
                split(row, field, " ")
                target[hex(field[1])] = field[2]
            }
        }
        /^Relocation section / {
            match($0, /at offset 0x[0-9a-f]+/)
            at = hex(substr($0, RSTART + 10, RLENGTH - 10))
            current = (at in target) ? target[at] : ""
            next
        }
        current != "" && $3 ~ /^R_X86_64_/ {
            print current, hex($1), ($3 ~ /64$/) ? 8 : 4
        }' | sort -u > "$WORK/relocations.txt"
    missing=$(comm -23 "$WORK/relocations.txt" "$WORK/references.txt" | wc -l)
    [ "$missing" -eq 0 ] ||
        fail "$(basename "$2"): $missing .debug_info relocations are not recorded references"
    wc -l < "$WORK/relocations.txt" | tr -d ' '
}

# check_summary LABEL DIR OBJECT: the scanner agrees with llvm-dwarfdump.
check_summary() {
    summary=$(scan "$2")
    expected=$(oracle_counts "$3")
    [ "$summary" = "$expected" ] ||
        fail "$1: scanner '$summary' differs from llvm-dwarfdump '$expected'"
}

# compile_c DIR CC FLAGS...: build DIR/probe.c into DIR/probe.dec.o (and
# DIR/probe.dec.dwo for split DWARF) with the compile directory mapped.
compile_c() {
    dir=$1
    cc=$2
    shift 2
    (cd "$dir" && bounded "$TOOL_LIMIT_MIB" "$cc" "$@" -fdebug-prefix-map="$dir=/typelisp" \
        -c probe.c -o probe.o)
    objcopy --decompress-debug-sections "$dir/probe.o" "$dir/probe.dec.o"
    extract "$dir/probe.dec.o" "$dir/sections" yes
    if [ -f "$dir/probe.dwo" ]; then
        objcopy --decompress-debug-sections "$dir/probe.dwo" "$dir/probe.dec.dwo"
        extract "$dir/probe.dec.dwo" "$dir/sections-dwo" no
    fi
}

# generate NAME CC FLAGS...: rebuild probe.c.in and check the fixture NAME
# (and NAME-dwo for split DWARF).
generate() {
    name=$1
    shift
    dir="$WORK/$name"
    mkdir -p "$dir"
    cp "$FIXTURES/probe.c.in" "$dir/probe.c"
    compile_c "$dir" "$@"
    for part in "" "-dwo"; do
        [ -d "$dir/sections$part" ] || continue
        fixture="$FIXTURES/$name$part"
        cmp -s "$dir/sections$part/sections.tsv" "$fixture/sections.tsv" ||
            fail "$name$part: regenerated sections differ from the checked-in sections.tsv"
        cut -f 5,6 "$fixture/sections.tsv" | while read -r file sum; do
            [ "$(sha256sum "$fixture/$file" | cut -d ' ' -f 1)" = "$sum" ] ||
                fail "$name$part/$file: checked-in bytes do not match their SHA-256"
        done
        if [ -z "$part" ]; then
            check_summary "$name" "$fixture" "$dir/probe.dec.o"
        else
            check_summary "$name$part" "$fixture" "$dir/probe.dec.dwo"
        fi
        grep -F "\"$summary\"" "$TESTS" >/dev/null ||
            fail "$name$part: $TESTS does not expect '$summary'"
    done
    relocations=$(check_relocations "$dir/probe.dec.o" "$FIXTURES/$name")
    echo "dwarf oracle: $name matches ($relocations .debug_info relocations on references)"
}

generate gcc-dwarf4-O0 gcc -gdwarf-4 -O0
generate gcc-dwarf5-O0 gcc -gdwarf-5 -O0
generate gcc-dwarf5-O2 gcc -gdwarf-5 -O2
generate gcc-dwarf5-O2-function-sections gcc -gdwarf-5 -O2 -ffunction-sections
generate gcc-dwarf5-O2-split gcc -gdwarf-5 -O2 -gsplit-dwarf
generate gcc-dwarf4-O2-split gcc -gdwarf-4 -O2 -gsplit-dwarf
generate gcc-dwarf4-O0-types gcc -gdwarf-4 -O0 -fdebug-types-section
generate gcc-dwarf5-O0-types gcc -gdwarf-5 -O0 -fdebug-types-section
generate clang-dwarf4-O0 clang -gdwarf-4 -O0
generate clang-dwarf5-O0 clang -gdwarf-5 -O0
generate clang-dwarf5-O2 clang -gdwarf-5 -O2
generate clang-dwarf5-O2-function-sections clang -gdwarf-5 -O2 -ffunction-sections
generate clang-dwarf5-O2-split clang -gdwarf-5 -O2 -gsplit-dwarf
generate clang-dwarf4-O2-split clang -gdwarf-4 -O2 -gsplit-dwarf

# The current compiler's --debug output (DWARF 3 through GNU as).
dir="$WORK/typelisp-debug"
mkdir -p "$dir"
cp "$FIXTURES/probe.tl.in" "$dir/probe.tl"
(cd "$dir" && bounded "$TOOL_LIMIT_MIB" "$COMPILER" compile probe.tl -o probe.s --debug \
    --target linux-x86_64 --cfg linux --cfg unix --cfg target-linux --cfg os-linux \
    --stdlib-root "$ROOT/stdlib" >/dev/null)
(cd "$dir" && as --debug-prefix-map "$ROOT=/typelisp" --debug-prefix-map "$dir=/typelisp" \
    probe.s -o probe.o)
objcopy --decompress-debug-sections "$dir/probe.o" "$dir/probe.dec.o"
extract "$dir/probe.dec.o" "$dir/sections" yes
check_summary "current TypeLisp --debug output" "$dir/sections" "$dir/probe.dec.o"
relocations=$(check_relocations "$dir/probe.dec.o" "$dir/sections")
echo "dwarf oracle: current TypeLisp --debug output matches ($relocations .debug_info relocations on references)"
summary=$(scan "$FIXTURES/typelisp-debug")
grep -F "\"$summary\"" "$TESTS" >/dev/null ||
    fail "typelisp-debug: $TESTS does not expect '$summary'"
if cmp -s "$dir/sections/sections.tsv" "$FIXTURES/typelisp-debug/sections.tsv"; then
    echo "dwarf oracle: tests/fixtures/dwarf/typelisp-debug is current"
else
    echo "dwarf oracle: tests/fixtures/dwarf/typelisp-debug is an older compiler's output;" \
        "$dir/sections holds the current one"
fi

# Scale: N functions, each with its own struct, an inlined helper and a loop.
for functions in 1000 10000; do
    for cc in gcc clang; do
        dir="$WORK/scale-$cc-$functions"
        mkdir -p "$dir"
        awk -v n="$functions" 'BEGIN {
            for (i = 0; i < n; i++) {
                printf "struct s%d { long a; int b[%d]; struct s%d *next; };\n", i, i % 7 + 1, i
                printf "static inline long h%d(long v) { return v * %d; }\n", i, i % 5 + 2
                printf "long f%d(struct s%d *p, int k) { long t = p->a; for (int j = 0; j < k; j++) t += h%d(p->b[j %% %d]); return p->next ? t + f%d(p->next, k - 1) : t; }\n", i, i, i, i % 7 + 1, i
            }
        }' > "$dir/probe.c"
        compile_c "$dir" "$cc" -gdwarf-5 -O2
        summary=$(scan "$dir/sections")
        peak=$(sed -n 's/^peak_memory_bytes=//p' "$WORK/bounded.report")
        wall=$(sed -n 's/^wall_ms=//p' "$WORK/bounded.report")
        expected=$(oracle_counts "$dir/probe.dec.o")
        [ "$summary" = "$expected" ] ||
            fail "scale-$cc-$functions: scanner '$summary' differs from llvm-dwarfdump '$expected'"
        work=$(sed -n 's/^work=//p' "$WORK/inventory.txt")
        bytes=$(sed -n 's/^bytes=//p' "$WORK/inventory.txt")
        [ "$work" -le "$bytes" ] || fail "scale-$cc-$functions: work $work exceeds $bytes input bytes"
        relocations=$(check_relocations "$dir/probe.dec.o" "$dir/sections")
        echo "dwarf oracle: scale-$cc-$functions matches: $bytes bytes, work $work," \
            "peak $((peak / 1048576)) MiB, ${wall} ms ($relocations .debug_info relocations on references)"
    done
done
echo "dwarf oracle: corpus verified with GCC 16.2.1, Clang 22.1.8, GNU binutils 2.47 and llvm-dwarfdump 22.1.8"
