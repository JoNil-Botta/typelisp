#!/usr/bin/env sh
set -eu
# Functional oracle over checked bytes. Normal/native tests use the recorded
# LLVM projections without spawning tools. This gate rechecks GNU readelf and,
# when installed, current LLVM's full numeric JSON projection independently.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
COMPILER=${TYPELISP_BIN:?set TYPELISP_BIN to a fresh compiler}
case "$COMPILER" in /*) ;; *) COMPILER="$ROOT/$COMPILER" ;; esac
WORK=${TYPELISP_ELF_ORACLE_WORK:-"$ROOT/target/exp/elf-object-oracle"}
mkdir -p "$WORK"
for tool in readelf awk sort diff; do command -v "$tool" >/dev/null; done
"$COMPILER" build tools/elf-object-oracle/main.tl --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src" --opt-level 2 -o "$WORK/oracle"
readelf_projection() {
    awk '
# Canonical projection of GNU readelf -W -S -s -r -g -n output.
# Keep every section/symbol/rela/group/member/note, with stable entry indexes.
function hx(s) { sub(/^0x/, "", s); sub(/^0+/, "", s); return s == "" ? "0" : tolower(s) }
function flags(s, out,i,c) { out=""; for(i=1;i<=length(alphabet);i++){c=substr(alphabet,i,1);if(index(s,c))out=out c} return out }
BEGIN { OFS="\t"; alphabet="ACDEGILMORSTWX"; section=0; rela=-1; symbols=0; group=-1; note=-1 }
/^Section Headers:/ {section=1;next}
section && /^Key to Flags:/ {section=0;next}
section && /^ *\[ *[0-9]+\]/ {
 line=$0;sub(/^ *\[/,"",line);split(line,a,"]");idx=a[1]+0;line=a[2];n=split(line,f,/ +/);if(f[1]==""){for(i=1;i<n;i++)f[i]=f[i+1];n--}
 # The name of section zero is empty; all other checked fixture names are tokens.
 base=(idx==0 ? 0 : 1);name=(idx==0 ? "" : f[1]);fl=(n==base+9 ? f[base+6] : "")
 print "S",idx,hx(f[base+2]),hx(f[base+3]),hx(f[base+4]),hx(f[base+5]),f[n-2]+0,f[n-1]+0,f[n]+0,flags(fl),name
 byname[name]=idx;byoffset[hx(f[base+3])]=idx;next
}
/^COMDAT group section/ {line=$0;sub(/^.*\[/,"",line);sub(/\].*$/,"",line);signature=line;line=$0;sub(/^.*\[/,"",line) # signature was the last bracket
 line=$0;sub(/^COMDAT group section \[ */,"",line);sub(/\].*$/,"",line);group=line+0;member=0;print "G",group,1,signature;next}
group>=0 && /^ *\[ *[0-9]+\]/ {line=$0;sub(/^ *\[ */,"",line);sub(/\].*$/,"",line);print "M",group,member++,line+0;next}
/^Relocation section / {group=-1;line=$0;sub(/^.* at offset 0x/,"",line);sub(/ .*/,"",line);rela=byoffset[hx(line)];entry=0;symbols=0;note=-1;next}
/^Symbol table / {rela=-1;group=-1;symbols=1;note=-1;next}
rela>=0 && $1 ~ /^[0-9a-fA-F]+$/ && length($1)==16 && $2 ~ /^[0-9a-fA-F]+$/ {print "R",rela,entry++,hx($1),hx($2),$(NF-1),hx($NF);next}
symbols && $1 ~ /^[0-9]+:$/ {idx=$1;sub(/:$/,"",idx);print "Y",idx+0,hx($2),$3+0,$4,$5,$6,$7,($4=="SECTION" ? "" : $8);next}
/^Displaying notes found in:/ {symbols=0;rela=-1;group=-1;note=byname[$NF];entry=0;next}
note>=0 && $2 ~ /^0x[0-9a-fA-F]+$/ {
 # The checked notes are GNU property notes and the explicit vendor type7.
 if($3=="NT_GNU_PROPERTY_TYPE_0")type=5;else if($0 ~ /Unknown note type: \(0x00000007\)/)type=7;else {print "unrecognized GNU note" > "/dev/stderr";exit 1}
 print "N",note,entry++,type,hx($2),$1;next
}
' "$1"
}
count=0
for fixture in "$ROOT"/tests/fixtures/elf-object/*.in; do
    case "$fixture" in *.c.in | *.s.in | *.tl.in) continue ;; esac
    name=$(basename "$fixture" .in)
    "$WORK/oracle" "$fixture" > "$WORK/$name.actual"
    diff -u "$ROOT/tests/fixtures/elf-object/$name.expected" "$WORK/$name.actual"
    readelf -W -S -s -r -g -n "$fixture" > "$WORK/$name.readelf"
    readelf_projection "$WORK/$name.readelf" > "$WORK/$name.gnu.unsorted"
    LC_ALL=C sort "$WORK/$name.gnu.unsorted" > "$WORK/$name.gnu.expected"
    "$WORK/oracle" --readelf "$fixture" > "$WORK/$name.gnu.actual.unsorted"
    LC_ALL=C sort "$WORK/$name.gnu.actual.unsorted" > "$WORK/$name.gnu.actual"
    diff -u "$WORK/$name.gnu.expected" "$WORK/$name.gnu.actual"
    if command -v llvm-readobj >/dev/null 2>&1; then
        llvm-readobj --elf-output-style=JSON --file-headers --sections --symbols \
            --relocations --section-groups --notes "$fixture" > "$WORK/$name.llvm.json"
        "$WORK/oracle" --normalize "$WORK/$name.llvm.json" > "$WORK/$name.llvm.expected"
        diff -u "$WORK/$name.llvm.expected" "$WORK/$name.actual"
    fi
    count=$((count + 1))
done
[ "$count" -eq 24 ] || { echo "ELF oracle: expected all 24 producers" >&2; exit 1; }
printf 'ELF object oracle: %s checked producers, GNU readelf verified\n' "$count"
if command -v llvm-readobj >/dev/null 2>&1; then
    echo 'ELF object oracle: LLVM full numeric projection verified'
else
    echo 'ELF object oracle: LLVM unavailable; recorded LLVM projections and live GNU projection verified'
fi
