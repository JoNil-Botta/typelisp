#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-compiler-artifact.sh"

TRACE_VALIDATION_FILE=
TRACE_VALIDATION_HOST=
case "$#:${1:-}" in
    0:) ;;
    3:--trace)
        TRACE_VALIDATION_FILE=$2
        TRACE_VALIDATION_HOST=$3
        case "$TRACE_VALIDATION_HOST" in
            linux | windows) ;;
            *)
                echo "trace host must be linux or windows" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "usage: scripts/verify-ci-compiler-artifacts.sh [--trace TRACE HOST]" >&2
        exit 2
        ;;
esac

INVENTORY="$ROOT/scripts/ci-compiler-artifacts.tsv"

WORKDIR="$ROOT/target/ci-compiler-artifact-self-test"
FIXTURE="$WORKDIR/fixture"
SOURCE="$FIXTURE/src"
STDLIB="$FIXTURE/stdlib"
PRODUCER="$FIXTURE/producer"
OUTPUT="$FIXTURE/output.bin"
PATH_FILE="$FIXTURE/handoff.path"
METADATA="$FIXTURE/handoff.meta"
TRACE="$FIXTURE/trace.tsv"
STDOUT="$FIXTURE/case.stdout"
STDERR="$FIXTURE/case.stderr"
rm -rf "$WORKDIR"
mkdir -p "$SOURCE" "$STDLIB"

cat > "$PRODUCER" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
    --producer-identity) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
    --version) printf '%s\n' 'typelisp 0123456789abcdef0123456789abcdef01234567 self-test' ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$PRODUCER"
printf '%s\n' '(define source-value : i64 1)' > "$SOURCE/input.tl"
printf '%s\n' '(define stdlib-value : i64 2)' > "$STDLIB/input.tl"
printf '%s\n' artifact-payload > "$OUTPUT"

HOST=$(ci_compiler_artifact_host)
TARGET="${HOST}-x86_64"
LABEL=self-test-compiler
CONSUMER=self-test-consumer
CFG=cfg-a,cfg-b
OPT=2
PROFILE=release
SOURCE_ROOTS=fixture/src,fixture/stdlib
STDLIB_ROOTS=fixture/stdlib,fixture/src
ENVIRONMENT=CODEGEN_MODE=self-test
KIND=compiler-binary
ARGV='compile fixture/src/main.tl -o {output} --target {target} --cfg cfg-a --cfg cfg-b --opt-level 2'
TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN=self-test-run-1
TYPELISP_CI_COMPILER_ARTIFACT_TRACE=$TRACE
export TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN
export TYPELISP_CI_COMPILER_ARTIFACT_TRACE

publish_fixture() {
    rm -f "$PATH_FILE" "$METADATA"
    printf '%s\n' artifact-payload > "$OUTPUT"
    ci_compiler_artifact_publish \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$PRODUCER" \
        "$TARGET" "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" "$OUTPUT" "$ARGV"
}

require_fixture() {
    ci_compiler_artifact_require \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$CONSUMER" \
        "$PRODUCER" \
        "$TARGET" "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" - "$ARGV"
}

expect_failure() {
    label=$1
    needle=$2
    shift 2
    set +e
    "$@" > "$STDOUT" 2> "$STDERR"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "ci compiler artifact self-test unexpectedly passed: $label" >&2
        exit 1
    fi
    if ! grep -F "$needle" "$STDERR" >/dev/null; then
        echo "ci compiler artifact self-test had wrong failure: $label" >&2
        echo "expected: $needle" >&2
        sed 's/^/  /' "$STDERR" >&2 || true
        exit 1
    fi
}

validate_checked_in_inventory() {
    rows="$FIXTURE/inventory-rows.tsv"
    gates="$FIXTURE/inventory-gates.txt"
    : > "$rows"
    : > "$gates"
    awk -F '\t' -v rows="$rows" -v gates="$gates" '
    function fail(message) {
        print "CI compiler artifact inventory: " message > "/dev/stderr"
        failed = 1
    }
    BEGIN {
        header = "schema\trecord_id\tgate\thost\trole\tproducer\ttarget\tcfg\topt_level\tprofile\tsource_set\toutput_kind\treuse_group\ttrace\tdecision\towner\tnotes"
    }
    {
        sub(/\r$/, "", $0)
        if ($0 == "") next
        if ($1 == "# ci-compiler-artifacts-schema") {
            if (NF != 2 || $2 != 1) fail("schema marker must be version 1")
            schema++
            next
        }
        if ($0 ~ /^#/) next
        if (!header_seen) {
            if ($0 != header) fail("header does not match schema 1")
            header_seen = 1
            next
        }
        if (NF != 17) {
            fail("row " FNR " has " NF " fields; expected 17")
            next
        }
        for (i = 1; i <= 17; i++) {
            if ($i == "") fail("row " FNR " has an empty field " i)
        }
        if ($1 != 1) fail("row " FNR " has a non-v1 schema")
        if ($2 !~ /^[a-z0-9][a-z0-9.-]*$/) fail("invalid record id " $2)
        if ($2 in ids) fail("duplicate record id " $2)
        ids[$2] = 1
        if ($4 != "all" && $4 != "linux" && $4 != "windows")
            fail("invalid host for " $2)
        if ($5 != "produce" && $5 != "consume") fail("invalid role for " $2)
        if ($14 != "required" && $14 != "ledger-only")
            fail("invalid trace policy for " $2)
        if ($13 == "none") {
            if ($5 != "produce") fail("ungrouped consumer " $2)
        } else {
            group = $13
            group_rows[group]++
            group_role[group, $5]++
            provenance = $6 FS $7 FS $8 FS $9 FS $10 FS $11 FS $12 FS $14
            if (!(group in group_provenance)) group_provenance[group] = provenance
            else if (group_provenance[group] != provenance)
                fail("reuse group " group " has mismatched provenance fields")
        }
        print $0 > rows
        print $3 > gates
        count++
    }
    END {
        if (schema != 1) fail("expected exactly one schema marker")
        if (!header_seen) fail("missing header")
        if (count < 45) fail("inventory unexpectedly shrank below 45 rows")
        for (group in group_rows) {
            if (group_role[group, "produce"] != 1)
                fail("reuse group " group " must have exactly one producer")
            if (group_role[group, "consume"] < 1)
                fail("reuse group " group " has no consumer")
        }
        if (failed) exit 1
    }
    ' "$INVENTORY"

    LC_ALL=C sort -u "$gates" -o "$gates"
    while IFS= read -r gate; do
        grep -F "\"$gate\"" "$ROOT/scripts/ci-verify.sh" >/dev/null || {
            echo "inventory gate is not wired through ci-verify.sh: $gate" >&2
            exit 1
        }
    done < "$gates"

    for group in \
        bootstrap-converged \
        manifest-assembly-set \
        embedded-stdlib-tlci-canonical \
        build-invariance-opt1 \
        compile-profile-cli; do
        grep -F "$group" "$ROOT/scripts/ci-verify.sh" >/dev/null || {
            echo "required reuse group is absent from ci-verify.sh: $group" >&2
            exit 1
        }
    done
    grep -F 'TYPELISP_COMPILE_PROFILE_EMBEDDED_TLCI_REUSE=1' \
        "$ROOT/scripts/ci-verify.sh" >/dev/null
    grep -F 'TYPELISP_COMPILE_PROFILE_EMBEDDED_TLCI_REUSE:-0' \
        "$ROOT/scripts/verify-compile-profile.sh" >/dev/null
    native_builds=$(grep -c \
        'compile_selfhost_binary compiler-driver src/main.tl' \
        "$ROOT/scripts/verify-native-link-linux.sh")
    [ "$native_builds" -eq 1 ] || {
        echo "native-link gate must build exactly one shared selfhost CLI" >&2
        exit 1
    }
    grep -F 'native-link-selfhost-cli' \
        "$ROOT/scripts/verify-native-link-linux.sh" >/dev/null
    grep -F 'verify_linux_direct_object_link "$NATIVE_LINK_DRIVER"' \
        "$ROOT/scripts/verify-native-link-linux.sh" >/dev/null
}

validate_ci_artifact_call_arities() {
    awk '
    function fail(message) {
        print "CI compiler artifact call arity: " message > "/dev/stderr"
        failed = 1
    }
    function word_count(text,    i, c, state, in_word, count) {
        state = ""
        in_word = 0
        count = 0
        for (i = 1; i <= length(text); i++) {
            c = substr(text, i, 1)
            if (state == "single") {
                if (c == single_quote) state = ""
                continue
            }
            if (state == "double") {
                if (c == "\"") state = ""
                continue
            }
            if (c == single_quote) {
                if (!in_word) { count++; in_word = 1 }
                state = "single"
            } else if (c == "\"") {
                if (!in_word) { count++; in_word = 1 }
                state = "double"
            } else if (c ~ /[[:space:]]/) {
                in_word = 0
            } else if (!in_word) {
                count++
                in_word = 1
            }
        }
        if (state != "") fail(FILENAME ":" start_line " has an unterminated quote")
        return count
    }
    function finish_call(    actual, expected) {
        actual = word_count(call) - 1
        expected = (kind == "publish" ? 15 : 16)
        if (actual != expected)
            fail(FILENAME ":" start_line " " kind " expects " expected \
                " arguments, got " actual)
        collecting = 0
        call = ""
        kind = ""
    }
    BEGIN { single_quote = sprintf("%c", 39) }
    {
        line = $0
        if (!collecting) {
            if (line ~ /^[[:space:]]*ci_compiler_artifact_publish[[:space:]]*\\[[:space:]]*$/)
                kind = "publish"
            else if (line ~ /^[[:space:]]*ci_compiler_artifact_require[[:space:]]*\\[[:space:]]*$/)
                kind = "require"
            else
                next
            collecting = 1
            start_line = FNR
        }
        continued = sub(/\\[[:space:]]*$/, "", line)
        call = call " " line
        if (!continued) finish_call()
    }
    END {
        if (collecting) fail(FILENAME ":" start_line " has an incomplete call")
        if (failed) exit 1
    }
    ' "$@"
}

validate_hosted_trace() {
    _trace_file=$1
    _trace_host=$2
    [ -s "$_trace_file" ] || {
        echo "CI compiler artifact trace is missing or empty: $_trace_file" >&2
        return 1
    }
    awk -F '\t' \
        -v inventory="$INVENTORY" \
        -v trace="$_trace_file" \
        -v selected_host="$_trace_host" '
    function fail(message) {
        print "CI compiler artifact trace: " message > "/dev/stderr"
        failed = 1
    }
    FILENAME == inventory {
        sub(/\r$/, "", $0)
        if ($0 == "" || $0 ~ /^#/) next
        if ($1 == "schema") next
        if ($14 == "required" && ($4 == "all" || $4 == selected_host)) {
            required_role[$2] = $5
            required_group[$2] = $13
            required_count++
        }
        next
    }
    FILENAME == trace {
        sub(/\r$/, "", $0)
        if (FNR == 1) {
            expected = "schema\trole\trecord_id\tprovenance_key\tproducer_identity\tproducer_sha256\thost\ttarget\tcwd\tsource_roots\tstdlib_roots\tcfg\topt_level\tprofile\tenvironment\targv\tsource_set_sha256\toutput_kind\toutput_path\toutput_sha256"
            if ($0 != expected) fail("header does not match schema 2")
            header_count++
            next
        }
        if (NF != 20) {
            fail("row " FNR " has " NF " fields; expected 20")
            next
        }
        for (i = 1; i <= 20; i++) {
            if ($i == "") fail("row " FNR " has an empty field " i)
        }
        if ($1 != 2) fail("row " FNR " has a non-v2 schema")
        if ($2 != "produce" && $2 != "consume")
            fail("row " FNR " has invalid role " $2)
        id = $3
        if (!(id in required_role)) {
            fail("unexpected or ledger-only record " id)
            next
        }
        if ($2 != required_role[id])
            fail("role mismatch for " id ": expected " required_role[id] ", got " $2)
        if ($7 != selected_host)
            fail("host mismatch for " id ": expected " selected_host ", got " $7)
        if (length($4) != 64 || $4 ~ /[^0-9a-f]/)
            fail("malformed provenance key for " id)
        if (length($20) != 64 || $20 ~ /[^0-9a-f]/)
            fail("malformed output digest for " id)
        seen[id]++
        if (seen[id] > 1) fail("duplicate trace record " id)
        record_key[id] = $4
        record_digest[id] = $20
        trace_count++
        next
    }
    END {
        if (header_count != 1) fail("expected exactly one schema-2 header")
        for (id in required_role) {
            if (seen[id] != 1)
                fail("required " required_role[id] " record is missing: " id)
            group = required_group[id]
            if (!(group in group_key)) {
                group_key[group] = record_key[id]
                group_digest[group] = record_digest[id]
            } else {
                if (record_key[id] != group_key[group])
                    fail("reuse group " group " has mismatched provenance keys")
                if (record_digest[id] != group_digest[group])
                    fail("reuse group " group " has mismatched output digests")
            }
        }
        if (trace_count != required_count)
            fail("expected " required_count " records, got " trace_count)
        if (failed) exit 1
    }
    ' "$INVENTORY" "$_trace_file"
}

validate_checked_in_inventory
validate_ci_artifact_call_arities \
    "$ROOT/scripts/ci-verify.sh" \
    "$ROOT/scripts/verify-native-link-linux.sh" \
    "$ROOT/scripts/verify-ci-compiler-artifacts.sh" \
    "$ROOT/scripts/lib-ci-compiler-artifact.sh"

ARITY_GOOD="$FIXTURE/arity-good.sh"
ARITY_BAD="$FIXTURE/arity-bad.sh"
ARITY_BAD_TEMPLATE="$FIXTURE/arity-bad.template"
cat > "$ARITY_GOOD" <<'EOF'
ci_compiler_artifact_publish \
    a b c d e f g h i j k l m n o
ci_compiler_artifact_require \
    a b c d e f g h i j k l m n o p
EOF
validate_ci_artifact_call_arities "$ARITY_GOOD"
cat > "$ARITY_BAD_TEMPLATE" <<'EOF'
@ci_compiler_artifact_publish \
    a b c d e f g h i j k l m n o p
EOF
sed 's/^@//' "$ARITY_BAD_TEMPLATE" > "$ARITY_BAD"
expect_failure call-site-arity 'publish expects 15 arguments, got 16' \
    validate_ci_artifact_call_arities "$ARITY_BAD"

if [ -n "$TRACE_VALIDATION_FILE" ]; then
    validate_hosted_trace "$TRACE_VALIDATION_FILE" "$TRACE_VALIDATION_HOST"
    echo "CI compiler artifact hosted trace passed ($TRACE_VALIDATION_HOST)"
    exit 0
fi

rm -f "$TRACE"
publish_fixture
require_fixture
[ "$CI_COMPILER_ARTIFACT_PATH" = "$OUTPUT" ] || {
    echo "validated handoff returned the wrong path" >&2
    exit 1
}
awk -F '\t' '
    NR == 1 {
        if (NF != 20 || $1 != "schema" || $2 != "role" ||
            $3 != "record_id" || $20 != "output_sha256") exit 1
    }
    NR == 2 {
        if (NF != 20 || $1 != 2 || $2 != "produce" ||
            $3 != "self-test-compiler") exit 1
    }
    NR == 3 {
        if (NF != 20 || $1 != 2 || $2 != "consume" ||
            $3 != "self-test-consumer") exit 1
    }
    END { if (NR != 3) exit 1 }
' "$TRACE" || {
    echo "artifact trace schema is malformed" >&2
    exit 1
}

ASSEMBLY_TREE="$FIXTURE/assembly-tree"
ASSEMBLY_MANIFEST="$FIXTURE/assembly-tree.sha256"
mkdir -p "$ASSEMBLY_TREE/a" "$ASSEMBLY_TREE/b"
printf '%s\n' assembly-a > "$ASSEMBLY_TREE/a/a.s"
printf '%s\n' assembly-b > "$ASSEMBLY_TREE/b/b.s"
ci_compiler_artifact_write_sha256_manifest \
    "$WORKDIR" "$ASSEMBLY_TREE" "$ASSEMBLY_MANIFEST"
ci_compiler_artifact_verify_sha256_manifest "$WORKDIR" "$ASSEMBLY_MANIFEST"
printf '%s\n' corrupt >> "$ASSEMBLY_TREE/b/b.s"
expect_failure manifest-corruption 'manifest artifact digest mismatch' \
    ci_compiler_artifact_verify_sha256_manifest "$WORKDIR" "$ASSEMBLY_MANIFEST"

FILES_MANIFEST="$FIXTURE/files.sha256"
ci_compiler_artifact_write_files_manifest \
    "$WORKDIR" "$FILES_MANIFEST" \
    "$ASSEMBLY_TREE/a/a.s" "$SOURCE/input.tl"
ci_compiler_artifact_verify_sha256_manifest "$WORKDIR" "$FILES_MANIFEST"

# The output location and label are not provenance inputs.  Identical bytes
# produced by the same normalized invocation must therefore group together.
FIRST_KEY=$(ci_compiler_artifact_read_field "$METADATA" provenance_key)
SECOND_OUTPUT="$FIXTURE/second-output.bin"
SECOND_PATH="$FIXTURE/second.path"
SECOND_METADATA="$FIXTURE/second.meta"
cp "$OUTPUT" "$SECOND_OUTPUT"
ci_compiler_artifact_publish \
    "$WORKDIR" "$SECOND_METADATA" "$SECOND_PATH" second-label "$PRODUCER" \
    "$TARGET" "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" "$STDLIB_ROOTS" \
    "$ENVIRONMENT" "$KIND" "$SECOND_OUTPUT" "$ARGV"
SECOND_KEY=$(ci_compiler_artifact_read_field "$SECOND_METADATA" provenance_key)
[ "$FIRST_KEY" = "$SECOND_KEY" ] || {
    echo "equivalent invocations received different provenance keys" >&2
    exit 1
}

publish_fixture
printf '%s\n' corrupt >> "$OUTPUT"
TRACE_LINES_BEFORE_FAILED_REQUIRE=$(wc -l < "$TRACE" | tr -d ' ')
expect_failure corrupt-artifact 'output_sha256 mismatch' require_fixture
TRACE_LINES_AFTER_FAILED_REQUIRE=$(wc -l < "$TRACE" | tr -d ' ')
[ "$TRACE_LINES_BEFORE_FAILED_REQUIRE" -eq \
    "$TRACE_LINES_AFTER_FAILED_REQUIRE" ] || {
    echo "failed consumer validation appended a trace row" >&2
    exit 1
}

publish_fixture
: > "$OUTPUT"
expect_failure empty-artifact 'handoff artifact is missing or empty' require_fixture

publish_fixture
TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN=self-test-run-2
export TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN
expect_failure stale-artifact 'run_token mismatch' require_fixture
TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN=self-test-run-1
export TYPELISP_CI_COMPILER_ARTIFACT_RUN_TOKEN

publish_fixture
cp "$METADATA" "$METADATA.base"
sed 's/^host=.*/host=other-host/' "$METADATA.base" > "$METADATA"
expect_failure cross-host 'host mismatch' require_fixture

publish_fixture
expect_failure wrong-target 'target mismatch' \
    ci_compiler_artifact_require \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$CONSUMER" \
        "$PRODUCER" \
        wrong-target "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" - "$ARGV"

publish_fixture
expect_failure wrong-cfg 'cfg mismatch' \
    ci_compiler_artifact_require \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$CONSUMER" \
        "$PRODUCER" \
        "$TARGET" wrong-cfg "$OPT" "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" - "$ARGV"

publish_fixture
expect_failure wrong-opt-level 'opt_level mismatch' \
    ci_compiler_artifact_require \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$CONSUMER" \
        "$PRODUCER" \
        "$TARGET" "$CFG" 1 "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" - "$ARGV"

publish_fixture
expect_failure wrong-profile 'profile mismatch' \
    ci_compiler_artifact_require \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$CONSUMER" \
        "$PRODUCER" \
        "$TARGET" "$CFG" "$OPT" debug "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" - "$ARGV"

publish_fixture
expect_failure wrong-kind 'output_kind mismatch' \
    ci_compiler_artifact_require \
        "$WORKDIR" "$METADATA" "$PATH_FILE" "$LABEL" "$CONSUMER" \
        "$PRODUCER" \
        "$TARGET" "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" compiler-assembly - "$ARGV"

publish_fixture
cp "$METADATA" "$METADATA.base"
sed 's/^provenance_key=.*/provenance_key=bad/' "$METADATA.base" > "$METADATA"
expect_failure key-mismatch 'provenance_key mismatch' require_fixture

publish_fixture
printf '%s\n' '# producer-byte-change' >> "$PRODUCER"
expect_failure producer-digest 'producer_sha256 mismatch' require_fixture
sed -i '$d' "$PRODUCER"

publish_fixture
printf '%s\n' "$FIXTURE/missing-output" > "$PATH_FILE"
expect_failure missing-path-target 'handoff artifact is missing or empty' require_fixture

rm -f "$FIXTURE/failed.path" "$FIXTURE/failed.meta"
expect_failure producer-failure 'producer output is missing or empty' \
    ci_compiler_artifact_publish \
        "$WORKDIR" "$FIXTURE/failed.meta" "$FIXTURE/failed.path" failed \
        "$PRODUCER" "$TARGET" "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" \
        "$STDLIB_ROOTS" "$ENVIRONMENT" "$KIND" "$FIXTURE/missing" "$ARGV"
[ ! -e "$FIXTURE/failed.path" ] && [ ! -e "$FIXTURE/failed.meta" ] || {
    echo "failed producer published a handoff" >&2
    exit 1
}

# Standalone scripts do not request a handoff; a half-configured CI request is
# rejected instead of silently using the fallback.
if ci_compiler_artifact_handoff_requested '' ''; then
    echo "empty handoff configuration was treated as requested" >&2
    exit 1
fi
expect_failure half-configured-handoff 'must be supplied together' \
    ci_compiler_artifact_handoff_requested "$PATH_FILE" ''

# A tracked source change must alter the key even when every flag and output
# byte is unchanged.
publish_fixture
SOURCE_KEY_BEFORE=$(ci_compiler_artifact_read_field "$METADATA" provenance_key)
printf '%s\n' '(define source-value : i64 3)' > "$SOURCE/input.tl"
ci_compiler_artifact_publish \
    "$WORKDIR" "$SECOND_METADATA" "$SECOND_PATH" second-label "$PRODUCER" \
    "$TARGET" "$CFG" "$OPT" "$PROFILE" "$SOURCE_ROOTS" "$STDLIB_ROOTS" \
    "$ENVIRONMENT" "$KIND" "$OUTPUT" "$ARGV"
SOURCE_KEY_AFTER=$(ci_compiler_artifact_read_field \
    "$SECOND_METADATA" provenance_key)
[ "$SOURCE_KEY_BEFORE" != "$SOURCE_KEY_AFTER" ] || {
    echo "source mutation did not alter the provenance key" >&2
    exit 1
}

# Build a complete host trace from one real handoff row so the final CI
# completeness validator is covered without running the full serial flow.
HOSTED_TRACE="$FIXTURE/hosted-trace.tsv"
HOSTED_TRACE_MISSING="$FIXTURE/hosted-trace-missing.tsv"
HOSTED_TRACE_MISMATCH="$FIXTURE/hosted-trace-mismatch.tsv"
HOSTED_TRACE_DUPLICATE="$FIXTURE/hosted-trace-duplicate.tsv"
HOSTED_TRACE_WRONG_ROLE="$FIXTURE/hosted-trace-wrong-role.tsv"
HOSTED_TRACE_WRONG_HOST="$FIXTURE/hosted-trace-wrong-host.tsv"
HOSTED_TRACE_UNOWNED="$FIXTURE/hosted-trace-unowned.tsv"
expect_failure hosted-trace-empty 'trace is missing or empty' \
    validate_hosted_trace "$FIXTURE/no-hosted-trace.tsv" "$HOST"
sed -n '1p' "$TRACE" > "$HOSTED_TRACE"
HOSTED_TRACE_TEMPLATE=$(sed -n '2p' "$TRACE")
awk -F '\t' -v OFS='\t' -v host="$HOST" \
    -v template="$HOSTED_TRACE_TEMPLATE" '
    BEGIN { count = split(template, field, FS) }
    $0 !~ /^#/ && $1 != "schema" && $14 == "required" &&
        ($4 == "all" || $4 == host) {
        field[2] = $5
        field[3] = $2
        for (i = 1; i <= count; i++)
            printf "%s%s", (i == 1 ? "" : OFS), field[i]
        printf "\n"
    }
    ' "$INVENTORY" >> "$HOSTED_TRACE"
validate_hosted_trace "$HOSTED_TRACE" "$HOST"

sed '$d' "$HOSTED_TRACE" > "$HOSTED_TRACE_MISSING"
expect_failure hosted-trace-missing 'required consume record is missing' \
    validate_hosted_trace "$HOSTED_TRACE_MISSING" "$HOST"

awk -F '\t' -v OFS='\t' '
    NR > 1 && !changed && $2 == "consume" {
        $4 = "0000000000000000000000000000000000000000000000000000000000000000"
        changed = 1
    }
    { print }
    ' "$HOSTED_TRACE" > "$HOSTED_TRACE_MISMATCH"
expect_failure hosted-trace-mismatch 'has mismatched provenance keys' \
    validate_hosted_trace "$HOSTED_TRACE_MISMATCH" "$HOST"

awk 'NR == 2 { print } { print }' \
    "$HOSTED_TRACE" > "$HOSTED_TRACE_DUPLICATE"
expect_failure hosted-trace-duplicate 'duplicate trace record' \
    validate_hosted_trace "$HOSTED_TRACE_DUPLICATE" "$HOST"

awk -F '\t' -v OFS='\t' '
    NR == 2 { $2 = ($2 == "produce" ? "consume" : "produce") }
    { print }
    ' "$HOSTED_TRACE" > "$HOSTED_TRACE_WRONG_ROLE"
expect_failure hosted-trace-wrong-role 'role mismatch' \
    validate_hosted_trace "$HOSTED_TRACE_WRONG_ROLE" "$HOST"

awk -F '\t' -v OFS='\t' -v host="$HOST" '
    NR == 2 { $7 = (host == "linux" ? "windows" : "linux") }
    { print }
    ' "$HOSTED_TRACE" > "$HOSTED_TRACE_WRONG_HOST"
expect_failure hosted-trace-wrong-host 'host mismatch' \
    validate_hosted_trace "$HOSTED_TRACE_WRONG_HOST" "$HOST"

awk -F '\t' -v OFS='\t' '
    NR == 2 { $3 = "unowned-record" }
    { print }
    ' "$HOSTED_TRACE" > "$HOSTED_TRACE_UNOWNED"
expect_failure hosted-trace-unowned 'unexpected or ledger-only record' \
    validate_hosted_trace "$HOSTED_TRACE_UNOWNED" "$HOST"

echo "CI compiler artifact handoff self-tests passed"
