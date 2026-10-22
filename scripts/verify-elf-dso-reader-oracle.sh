#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
COMPILER=${TYPELISP_BIN:?set TYPELISP_BIN to a fresh compiler}
WORK=${TYPELISP_DSO_ORACLE_WORK:-"$ROOT/target/exp/elf-dso-oracle"}
mkdir -p "$WORK"
if [ "${1:-}" != --project ]; then
    "$COMPILER" build tools/elf-dso-oracle/main.tl --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" --opt-level 2 -o "$WORK/oracle"
fi
project() {
    awk '
function hx(s) { sub(/^0x/,"",s);sub(/^0+/,"",s);return s=="" ? "0" : tolower(s) }
function hex(s, n,i,d) { sub(/^0x/,"",s);n=0;s=tolower(s);for(i=1;i<=length(s);i++){d=index("0123456789abcdef",substr(s,i,1))-1;n=n*16+d}return n }
function number(s) { return s ~ /^0x/ ? hx(s) : sprintf("%x",s+0) }
function field(line,key, a) { sub("^.*"key" *","",line);split(line,a,/ +/);return a[1] }
function flags(s,one, value) {
 value=0
 if(one) { if(s ~ /(^| )NOW( |$)/)value+=1;if(s ~ /NODELETE/)value+=8 }
 else { if(s ~ /BIND_NOW/)value+=8;if(s ~ /STATIC_TLS/)value+=16;if(s ~ /TEXTREL/)value+=4;if(s ~ /SYMBOLIC/)value+=2;if(s ~ /ORIGIN/)value+=1 }
 return sprintf("%x",value)
}
BEGIN { OFS="\t";mode="" }
/^Dynamic section / { mode="dynamic";next }
/^Symbol table / { mode="symbols";next }
/^Version symbols section / { mode="versym";next }
/^Version definition section / { mode="verdef";next }
/^Version needs section / { mode="verneed";next }
mode=="dynamic" && $1 ~ /^0x/ {
 tag=hx($1);value=$3
 if($2 ~ /^\((NEEDED|SONAME|RPATH|RUNPATH)\)$/) { value=$0;sub(/^.*\[/,"[",value);sub(/\].*$/,"]",value) }
 else if($2=="(FLAGS)")value=flags($0,0)
 else if($2=="(FLAGS_1)")value=flags($0,1)
 else if($2=="(PLTREL)")value=($3=="RELA" ? "7" : "11")
 else value=number($3)
 print "D",tag,value;next
}
mode=="symbols" && $1 ~ /^[0-9]+:$/ {idx=$1;sub(/:$/,"",idx);print "Y",idx+0,hx($2),$3+0,$4,$5,$6,$7,$8;next}
mode=="versym" && $1 ~ /^[0-9a-f]+:$/ {
 start=$1;sub(/:$/,"",start);start=hex(start)
 line=$0;sub(/^[^:]*:/,"",line);gsub(/\([^)]*\)/,"",line);n=split(line,a,/ +/);j=0
 for(i=1;i<=n;i++)if(a[i]!=""){v=a[i];hidden=(v ~ /h$/);sub(/h$/,"",v);print "VS",start+j++,hex(v)+(hidden?32768:0)}
 next
}
mode=="verdef" && /Rev:/ {
 offset=$1;sub(/:$/,"",offset);flag=field($0,"Flags:");fl=(flag=="BASE"?1:(flag=="WEAK"?2:0))
 print "VD",hx(offset),fl,field($0,"Index:")+0,field($0,"Cnt:")+0,field($0,"Name:");next
}
mode=="verdef" && /Parent/ {offset=$1;sub(/:$/,"",offset);n=$3;sub(/:$/,"",n);print "VP",hx(offset),n+0,$4;next}
mode=="verneed" && /File:/ {offset=$1;sub(/:$/,"",offset);print "VN",hx(offset),field($0,"Cnt:")+0,field($0,"File:");next}
mode=="verneed" && /Name:/ {offset=$1;sub(/:$/,"",offset);fl=field($0,"Flags:");print "VA",hx(offset),(fl=="WEAK"?2:0),field($0,"Version:")+0,field($0,"Name:");next}
' "$1"
}
if [ "${1:-}" = --project ]; then project "$2"; exit; fi
count=0
for fixture in "$ROOT"/tests/fixtures/elf-dso/*.in; do
    name=$(basename "$fixture" .in)
    readelf -W -D -s --dynamic --version-info "$fixture" > "$WORK/$name.readelf"
    project "$WORK/$name.readelf" > "$WORK/$name.expected"
    if [ "$name" = no-sections ]; then
        # GNU readelf -V does not expose sectionless version records. -sD still
        # resolves every symbol version. Native tests additionally compare the
        # complete version model with the byte-identical sectionful producer.
        "$WORK/oracle" "$fixture" --no-version-records > "$WORK/$name.actual"
    else
        "$WORK/oracle" "$fixture" > "$WORK/$name.actual"
    fi
    diff -u "$ROOT/tests/fixtures/elf-dso/$name.expected" "$WORK/$name.expected"
    diff -u "$WORK/$name.expected" "$WORK/$name.actual"
    count=$((count + 1))
done
[ "$count" -eq 8 ] || { echo "ELF DSO oracle: expected all 8 producers" >&2; exit 1; }
printf 'ELF DSO oracle: %s producers, every dynamic/symbol/version record verified\n' "$count"
