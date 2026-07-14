#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CHECKER=scripts/check-cli-gate-coverage.sh
WORKDIR=target/cli-gate-coverage-self-test
HEADER='schema	case_id	gate	source	kind	host	compiler	argv	fixture	stdin	cwd	process	environment	expected_status	stdout	stderr	effects	canonical_owner	duplicate_reason'

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

write_inventory() {
    _file=$1
    printf '# cli-gate-coverage-schema\t1\n%b\n' "$HEADER" > "$_file"
}

append_row() {
    _file=$1
    shift
    if [ "$#" -ne 19 ]; then
        echo "cli-gate coverage self-test row has $# fields; expected 19" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$_file"
}

run_pass() {
    _label=$1
    _inventory=$2
    _source=$3
    _stdout="$WORKDIR/$_label.stdout"
    _stderr="$WORKDIR/$_label.stderr"
    if ! CLI_GATE_COVERAGE_DIR="$WORKDIR/check-$_label" \
        "$CHECKER" --inventory "$_inventory" --source "$_source" > "$_stdout" 2> "$_stderr"; then
        echo "CLI gate coverage self-test unexpectedly failed: $_label" >&2
        cat "$_stderr" >&2
        exit 1
    fi
}

run_fail() {
    _label=$1
    _expected=$2
    _inventory=$3
    _source=$4
    _stdout="$WORKDIR/$_label.stdout"
    _stderr="$WORKDIR/$_label.stderr"
    if CLI_GATE_COVERAGE_DIR="$WORKDIR/check-$_label" \
        "$CHECKER" --inventory "$_inventory" --source "$_source" > "$_stdout" 2> "$_stderr"; then
        echo "CLI gate coverage self-test unexpectedly passed: $_label" >&2
        exit 1
    fi
    if ! grep -F "$_expected" "$_stderr" >/dev/null; then
        echo "CLI gate coverage self-test produced the wrong diagnostic: $_label" >&2
        cat "$_stderr" >&2
        exit 1
    fi
}

VALID_SOURCE="$WORKDIR/valid-source.sh"
VALID_INVENTORY="$WORKDIR/valid.tsv"
cat > "$VALID_SOURCE" <<'EOF'
# cli-gate-case stderr-empty wrapper run_cmd
run_cmd stderr-empty
# cli-gate-case stderr-diagnostic wrapper run_cmd
run_cmd stderr-diagnostic
# cli-gate-case cwd-root wrapper run_cmd
run_cmd cwd-root
# cli-gate-case cwd-fixture wrapper run_cmd
run_cmd cwd-fixture
# cli-gate-case stdin-none wrapper run_cmd
run_cmd stdin-none
# cli-gate-case stdin-program wrapper run_cmd
run_cmd stdin-program
# cli-gate-case heartbeat-none wrapper run_cmd
run_cmd heartbeat-none
# cli-gate-case heartbeat-fd3 wrapper run_cmd
run_cmd heartbeat-fd3
# cli-gate-case platform-linux wrapper run_cmd
run_cmd platform-linux
# cli-gate-case platform-windows wrapper run_cmd
run_cmd platform-windows
# cli-gate-case expected-failure wrapper run_cmd
run_cmd expected-failure
# cli-gate-case delegated-corpus delegated run_corpus
run_corpus delegated-corpus
# cli-gate-case direct-compiler direct "$COMPILER"
"$COMPILER" --version
# cli-gate-expand matrix-{host}-{mode} wrapper run_cmd host=linux,windows mode=scalar,avx2
run_cmd matrix-family
# cli-gate-case allowed-owner wrapper run_cmd
run_cmd allowed-owner
# cli-gate-case allowed-repeat wrapper run_cmd
run_cmd allowed-repeat
EOF

write_inventory "$VALID_INVENTORY"
printf '# source\t%s\n' "$VALID_SOURCE" >> "$VALID_INVENTORY"
append_row "$VALID_INVENTORY" 1 stderr-empty fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check same.tl' same none repository one-process none 0 ignore empty none stderr-empty -
append_row "$VALID_INVENTORY" 1 stderr-diagnostic fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check same.tl' same none repository one-process none 0 ignore contains:error none stderr-diagnostic -
append_row "$VALID_INVENTORY" 1 cwd-root fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check cwd.tl' same none repository one-process none 0 ignore empty none cwd-root -
append_row "$VALID_INVENTORY" 1 cwd-fixture fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check cwd.tl' same none fixture-root one-process none 0 ignore empty none cwd-fixture -
append_row "$VALID_INVENTORY" 1 stdin-none fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp repl' same none repository one-process none 0 ignore empty none stdin-none -
append_row "$VALID_INVENTORY" 1 stdin-program fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp repl' same bytes:program repository one-process none 0 ignore empty none stdin-program -
append_row "$VALID_INVENTORY" 1 heartbeat-none fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check heartbeat.tl' same none repository one-process none 0 ignore empty none heartbeat-none -
append_row "$VALID_INVENTORY" 1 heartbeat-fd3 fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check heartbeat.tl' same none repository one-process TYPELISP_STAGE1_HEARTBEAT_FD=3 0 ignore empty none heartbeat-fd3 -
append_row "$VALID_INVENTORY" 1 platform-linux fixture-gate "$VALID_SOURCE" wrapper linux stage3 'typelisp check platform.tl' same none repository one-process none 0 ignore empty none platform-linux -
append_row "$VALID_INVENTORY" 1 platform-windows fixture-gate "$VALID_SOURCE" wrapper windows stage3 'typelisp check platform.tl' same none repository one-process none 0 ignore empty none platform-windows -
append_row "$VALID_INVENTORY" 1 expected-failure fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp check bad.tl' bad none repository one-process none nonzero empty contains:diagnostic none expected-failure -
append_row "$VALID_INVENTORY" 1 delegated-corpus fixture-gate "$VALID_SOURCE" delegated all stage3 'run-corpus tests/public-tools' public-tools none repository child-per-case none 0 corpus-summary empty scratch-tree delegated-corpus -
append_row "$VALID_INVENTORY" 1 direct-compiler fixture-gate "$VALID_SOURCE" direct all stage3 'typelisp --version' none none repository one-process none 0 version empty none direct-compiler -
append_row "$VALID_INVENTORY" 1 matrix-linux-scalar fixture-gate "$VALID_SOURCE" wrapper linux stage3 'typelisp compile matrix.tl --backend-mode scalar' matrix none repository one-process none 0 ignore empty asm matrix-linux-scalar -
append_row "$VALID_INVENTORY" 1 matrix-linux-avx2 fixture-gate "$VALID_SOURCE" wrapper linux stage3 'typelisp compile matrix.tl --backend-mode avx2' matrix none repository one-process none 0 ignore empty asm matrix-linux-avx2 -
append_row "$VALID_INVENTORY" 1 matrix-windows-scalar fixture-gate "$VALID_SOURCE" wrapper windows stage3 'typelisp compile matrix.tl --backend-mode scalar' matrix none repository one-process none 0 ignore empty asm matrix-windows-scalar -
append_row "$VALID_INVENTORY" 1 matrix-windows-avx2 fixture-gate "$VALID_SOURCE" wrapper windows stage3 'typelisp compile matrix.tl --backend-mode avx2' matrix none repository one-process none 0 ignore empty asm matrix-windows-avx2 -
append_row "$VALID_INVENTORY" 1 allowed-owner fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp --version' none none repository one-process none 0 version empty none allowed-owner intentional-control
append_row "$VALID_INVENTORY" 1 allowed-repeat fixture-gate "$VALID_SOURCE" wrapper all stage3 'typelisp --version' none none repository one-process none 0 version empty none allowed-owner intentional-repeat

run_pass valid "$VALID_INVENTORY" "$VALID_SOURCE"
grep -F 'count	gate	fixture-gate	19' "$WORKDIR/valid.stdout" >/dev/null
grep -F 'count	expanded-case	matrix-linux-avx2' "$WORKDIR/valid.stdout" >/dev/null
grep -F 'duplicate	allowed-owner	allowed-owner' "$WORKDIR/valid.stdout" >/dev/null
grep -F 'duplicate	allowed-owner	allowed-repeat' "$WORKDIR/valid.stdout" >/dev/null

DUP_SOURCE="$WORKDIR/duplicate-source.sh"
DUP_INVENTORY="$WORKDIR/duplicate.tsv"
cat > "$DUP_SOURCE" <<'EOF'
# cli-gate-case duplicate-a wrapper run_cmd
run_cmd duplicate-a
# cli-gate-case duplicate-b wrapper run_cmd
run_cmd duplicate-b
EOF
write_inventory "$DUP_INVENTORY"
append_row "$DUP_INVENTORY" 1 duplicate-a fixture-gate "$DUP_SOURCE" wrapper all stage3 'typelisp --help' none none repository one-process none 0 usage empty none duplicate-a -
append_row "$DUP_INVENTORY" 1 duplicate-b fixture-gate "$DUP_SOURCE" wrapper all stage3 'typelisp --help' none none repository one-process none 0 usage empty none duplicate-b -
run_fail exact-duplicate 'exact duplicate CLI gate behavior lacks one in-group canonical owner' "$DUP_INVENTORY" "$DUP_SOURCE"

EMPTY_SOURCE="$WORKDIR/empty-source.sh"
EMPTY_INVENTORY="$WORKDIR/empty-field.tsv"
cat > "$EMPTY_SOURCE" <<'EOF'
# cli-gate-case empty-field wrapper run_cmd
run_cmd empty-field
EOF
write_inventory "$EMPTY_INVENTORY"
append_row "$EMPTY_INVENTORY" 1 empty-field fixture-gate "$EMPTY_SOURCE" wrapper '' stage3 'typelisp --help' none none repository one-process none 0 usage empty none empty-field -
run_fail empty-field 'field `host` is empty' "$EMPTY_INVENTORY" "$EMPTY_SOURCE"

DUP_ID_INVENTORY="$WORKDIR/duplicate-id.tsv"
write_inventory "$DUP_ID_INVENTORY"
append_row "$DUP_ID_INVENTORY" 1 duplicate-id fixture-gate "$EMPTY_SOURCE" wrapper all stage3 'typelisp --help' none none repository one-process none 0 usage empty none duplicate-id -
append_row "$DUP_ID_INVENTORY" 1 duplicate-id fixture-gate "$EMPTY_SOURCE" wrapper linux stage3 'typelisp --help' none none repository one-process none 0 usage empty none duplicate-id -
run_fail duplicate-id 'duplicate CLI gate coverage case ID `duplicate-id`' "$DUP_ID_INVENTORY" "$EMPTY_SOURCE"

DUP_ANNOTATION_SOURCE="$WORKDIR/duplicate-annotation-source.sh"
DUP_ANNOTATION_INVENTORY="$WORKDIR/duplicate-annotation.tsv"
cat > "$DUP_ANNOTATION_SOURCE" <<'EOF'
# cli-gate-case repeated wrapper run_cmd
run_cmd first
# cli-gate-case repeated wrapper run_cmd
run_cmd second
EOF
write_inventory "$DUP_ANNOTATION_INVENTORY"
append_row "$DUP_ANNOTATION_INVENTORY" 1 repeated fixture-gate "$DUP_ANNOTATION_SOURCE" wrapper all stage3 'typelisp --help' none none repository one-process none 0 usage empty none repeated -
run_fail duplicate-annotation 'duplicate executing annotation for case ID `repeated`' "$DUP_ANNOTATION_INVENTORY" "$DUP_ANNOTATION_SOURCE"

MALFORMED_SOURCE="$WORKDIR/malformed-expansion-source.sh"
EMPTY_VALID_INVENTORY="$WORKDIR/empty-valid.tsv"
cat > "$MALFORMED_SOURCE" <<'EOF'
# cli-gate-expand malformed-{mode} wrapper run_cmd mode=scalar,
run_cmd malformed
EOF
write_inventory "$EMPTY_VALID_INVENTORY"
run_fail malformed-expansion 'expansion axis `mode` has an empty value' "$EMPTY_VALID_INVENTORY" "$MALFORMED_SOURCE"

UNKNOWN_SOURCE="$WORKDIR/unknown-owner-source.sh"
UNKNOWN_INVENTORY="$WORKDIR/unknown-owner.tsv"
cat > "$UNKNOWN_SOURCE" <<'EOF'
# cli-gate-case unknown-owner wrapper run_cmd
run_cmd unknown-owner
EOF
write_inventory "$UNKNOWN_INVENTORY"
append_row "$UNKNOWN_INVENTORY" 1 unknown-owner fixture-gate "$UNKNOWN_SOURCE" wrapper all stage3 'typelisp --help' none none repository one-process none 0 usage empty none absent-owner -
run_fail unknown-owner 'names unknown canonical owner `absent-owner`' "$UNKNOWN_INVENTORY" "$UNKNOWN_SOURCE"

STALE_SOURCE="$WORKDIR/stale-source.sh"
STALE_INVENTORY="$WORKDIR/stale.tsv"
printf '%s\n' '# no CLI gate annotation remains here' > "$STALE_SOURCE"
write_inventory "$STALE_INVENTORY"
append_row "$STALE_INVENTORY" 1 stale-row fixture-gate "$STALE_SOURCE" wrapper all stage3 'typelisp --help' none none repository one-process none 0 usage empty none stale-row -
run_fail stale-row 'inventory row `stale-row` has no executing annotation' "$STALE_INVENTORY" "$STALE_SOURCE"

MISSING_SOURCE="$WORKDIR/missing-row-source.sh"
cat > "$MISSING_SOURCE" <<'EOF'
# cli-gate-case missing-row wrapper run_cmd
run_cmd missing-row
EOF
run_fail missing-row 'executing CLI gate annotation `missing-row` has no inventory row' "$EMPTY_VALID_INVENTORY" "$MISSING_SOURCE"

echo "CLI gate coverage checker self-tests passed"
