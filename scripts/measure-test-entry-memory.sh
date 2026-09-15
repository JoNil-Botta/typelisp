#!/usr/bin/env sh
set -eu

# Refs #7817. Compile the same measurement harness against candidate or base
# sources, then run every heavy/mixed 4/16/32 case under a hard host cap.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { echo "[test-entry-memory] $*" >&2; exit 1; }
if [ "$#" != 2 ] && [ "$#" != 4 ]; then
    fail "usage: $0 COMPILER OUTPUT_DIR [--baseline-root SOURCE_ROOT]"
fi
CALLER=$(pwd)
. "$ROOT/scripts/lib-native-link.sh"
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"
native_link_detect_host
configure_toolchain
COMPILER=$(ci_compiler_artifact_absolute_path "$CALLER" "$1")
[ -x "$COMPILER" ] || fail "compiler is not executable: $COMPILER"
mkdir -p "$2"
WORKDIR=$(CDPATH= cd -- "$2" && pwd)
SOURCE_ROOT=$ROOT
BASELINE=0
if [ "$#" = 4 ]; then
    [ "$3" = --baseline-root ] || fail "unknown option: $3"
    SOURCE_ROOT=$(CDPATH= cd -- "$4" && pwd)
    BASELINE=1
fi
[ ! -e "$WORKDIR/provenance.tsv" ] || fail "output already contains a run: $WORKDIR"
CAP_MIB=4096
EXPECTED_BACKEND=job-object
if [ "$HOST_OS" = linux ]; then
    CAP_MIB=6144
    EXPECTED_BACKEND=systemd-user-cgroup
    TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup
    export TYPELISP_LINUX_MEMORY_LIMIT_BACKEND
fi
CAP_BYTES=$((CAP_MIB * 1024 * 1024))
BOUNDED="$ROOT/scripts/run-memory-bounded.sh"
mkdir -p "$WORKDIR/harness"
cp "$ROOT/tools/test-entry-memory/measure.tl" "$WORKDIR/harness/measure.tl"
cp "$ROOT/src/tests/test_cli_entry_memory_smoke.tl" "$WORKDIR/harness/test_cli_entry_memory_smoke.tl"
SOURCES='src,stdlib,tests/inline/windows_param_preassign_backend.tl,tests/inline/test_batch_retention_leaf.tl'
SOURCE_DIGEST=$(ci_compiler_artifact_source_set_digest "$SOURCE_ROOT" "$SOURCES")
HARNESS_DIGEST=$(ci_compiler_artifact_source_set_digest "$WORKDIR" harness)
{
    printf 'source_commit\t%s\n' "$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
    printf 'source_dirty\t%s\n' "$(if [ -n "$(git -C "$SOURCE_ROOT" status --porcelain -- src stdlib tests/inline/windows_param_preassign_backend.tl tests/inline/test_batch_retention_leaf.tl)" ]; then echo 1; else echo 0; fi)"
    printf 'source_digest\t%s\n' "$SOURCE_DIGEST"
    printf 'harness_digest\t%s\n' "$HARNESS_DIGEST"
    printf 'seed_identity\t%s\n' "$(ci_compiler_artifact_producer_identity "$COMPILER")"
    printf 'seed_sha256\t%s\n' "$(ci_compiler_artifact_sha256_file "$COMPILER")"
    printf 'host\t%s\ncap_bytes\t%s\nbaseline\t%s\n' "$HOST_OS" "$CAP_BYTES" "$BASELINE"
} > "$WORKDIR/provenance.tsv"

check_report() {
    awk -F= -v cap="$CAP_BYTES" -v host="$HOST_OS" -v backend="$EXPECTED_BACKEND" '
        BEGIN { n=split("schema_version host backend reason exit_code limit_bytes peak_memory_bytes wall_ms",keys," "); for(i=1;i<=n;i++) allowed[keys[i]]=1 }
        NF!=2 || !($1 in allowed) || seen[$1]++ { bad=1 }
        { value[$1]=$2; sub(/\r$/, "", value[$1]) }
        END {
            if(NR!=8 || bad) exit 1
            for(i=1;i<=n;i++) if(!(keys[i] in value)) exit 1
            if(value["schema_version"]!="1" || value["host"]!=host || value["backend"]!=backend || value["reason"]!="success" || value["exit_code"]!="0") exit 1
            if(value["limit_bytes"]!~/^[0-9]+$/ || value["limit_bytes"]+0!=cap) exit 1
            if(value["peak_memory_bytes"]!~/^[0-9]+$/ || value["peak_memory_bytes"]+0<=0 || value["peak_memory_bytes"]+0>=cap) exit 1
            if(value["wall_ms"]!~/^[0-9]+$/) exit 1
        }' "$1" || fail "invalid bounded report: $1"
}

cd "$SOURCE_ROOT"
# The fresh executable contains this source tree's compiler/test driver. It
# is distinct from the seed that emits it; both identities are recorded.
# shellcheck disable=SC2046
"$BOUNDED" --limit-mib "$CAP_MIB" --report "$WORKDIR/build.metrics" --timeout-seconds 600 -- \
    "$COMPILER" compile "$WORKDIR/harness/measure.tl" -o "$WORKDIR/measure.s" \
    --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) --opt-level 1 \
    --stdlib-root "$WORKDIR/harness" --stdlib-root "$SOURCE_ROOT/stdlib" --stdlib-root "$SOURCE_ROOT/src" \
    > "$WORKDIR/build.stdout" 2> "$WORKDIR/build.stderr"
check_report "$WORKDIR/build.metrics"
EXE="$WORKDIR/measure$BIN_EXT"
"$BOUNDED" --limit-mib "$CAP_MIB" --report "$WORKDIR/link.metrics" --timeout-seconds 600 -- sh -c '
    ROOT=$1
    . "$ROOT/scripts/lib-native-link.sh"
    native_link_detect_host
    configure_toolchain
    assemble_and_link test-entry-memory "$2/measure.s" "$2/measure.$OBJ_EXT" "$2/measure$BIN_EXT"
' sh "$ROOT" "$WORKDIR" > "$WORKDIR/link.stdout" 2> "$WORKDIR/link.stderr"
check_report "$WORKDIR/link.metrics"
printf 'executable_sha256\t%s\n' "$(ci_compiler_artifact_sha256_file "$EXE")" >> "$WORKDIR/provenance.tsv"
printf 'mode\tentries\twarm_bytes\tfinal_bytes\tretained_delta\tpeak_bytes\twall_ms\n' > "$WORKDIR/results.tsv"
for mode in heavy mixed; do
    for count in 4 16 32; do
        label="$mode-$count"
        "$BOUNDED" --limit-mib "$CAP_MIB" --report "$WORKDIR/$label.metrics" --timeout-seconds 900 -- \
            "$EXE" "$mode" "$count" > "$WORKDIR/$label.stdout" 2> "$WORKDIR/$label.stderr"
        check_report "$WORKDIR/$label.metrics"
        awk -F'|' -v mode="$mode" -v count="$count" -v baseline="$BASELINE" '
            $1=="test-entry-memory" {
                sub(/\r$/, "", $6); found++
                if(NF!=6 || $2!=mode || $3!=count || $4!~/^[0-9]+$/ || $5!~/^[0-9]+$/ || $6!~/^-?[0-9]+$/ || $4+0<=0 || $5-$4!=$6+0 || (!baseline && $6+0!=0)) bad=1
            }
            END { exit found==1 && !bad ? 0 : 1 }' "$WORKDIR/$label.stdout" || fail "invalid or growing sample: $label"
        awk -F'|' '$1=="test-entry-memory" { sub(/\r$/, "", $6); printf "%s\t%s\t%s\t%s\t%s\t",$2,$3,$4,$5,$6 }' "$WORKDIR/$label.stdout" >> "$WORKDIR/results.tsv"
        awk -F= '$1=="peak_memory_bytes" { peak=$2 } $1=="wall_ms" { wall=$2 } END { gsub(/\r/,"",peak); gsub(/\r/,"",wall); printf "%s\t%s\n",peak,wall }' "$WORKDIR/$label.metrics" >> "$WORKDIR/results.tsv"
        echo "[test-entry-memory] $label passed ($HOST_OS, $CAP_MIB MiB)"
    done
done
[ "$SOURCE_DIGEST" = "$(ci_compiler_artifact_source_set_digest "$SOURCE_ROOT" "$SOURCES")" ] || fail "source inputs changed during measurement"
[ "$HARNESS_DIGEST" = "$(ci_compiler_artifact_source_set_digest "$WORKDIR" harness)" ] || fail "harness changed during measurement"
echo "[test-entry-memory] six native measurements complete: $WORKDIR/results.tsv"
