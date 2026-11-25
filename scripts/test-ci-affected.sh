#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-manifest.sh"
. "$ROOT/scripts/lib-ci-gates.sh"
. "$ROOT/scripts/lib-ci-local.sh"
mkdir -p "$ROOT/target/exp/ci-affected-test"
work=$(mktemp -d "$ROOT/target/exp/ci-affected-test/run.XXXXXX")
selector="$ROOT/scripts/ci-affected.sh"
TAB=$(printf '\t')
fail() { echo "ci-affected self-test: $* (evidence: $work)" >&2; exit 1; }
has_gate() { grep -Fx "$2" "$1" >/dev/null || fail "missing $2 in $1${3:+ for $3}"; }
case "$work" in
    "$ROOT/target/exp/ci-affected-test/run."??????) ;;
    *) fail "unexpected self-test scratch directory" ;;
esac

# Exercise Git's actual Windows checkout filter, including the provenance
# tables and byte-compared historical paths. Their LF attributes must win.
for path in scripts/ci-gates.d/*.tsv scripts/ci-affected-paths.d/*.tsv tests/fixtures/ci-affected/*.paths tests/fixtures/ci-affected/history.tsv tests/integration/manifest.d/*.manifest src/compile_manifest.d/*.manifest tests/safety/manifest.d/*.manifest scripts/codegen-target-dispatch.d/*.tsv tools/embedded-stdlib-tlci/identity-fixtures.d/*.tsv tests/codegen/asm-shape.d/*.cases tests/spmd/simd.d/*.cases; do
    git cat-file blob ":$path" > "$work/checkout.expected"
    git -c core.autocrlf=true cat-file --filters --path="$path" ":$path" > "$work/checkout.actual"
    cmp "$work/checkout.actual" "$work/checkout.expected" || fail "Windows checkout changed line endings: $path"
done

ci_gates_load "$ROOT/scripts/ci-gates.d" > "$work/gates-full.tsv" || fail 'gate table load failed'
ci_affected_paths_load "$ROOT/scripts/ci-affected-paths.d" > "$work/affected-paths.tsv" || fail 'affected-paths load failed'

# Audit tracked literal inputs inside owning scripts, independently of the
# reviewed map. Synthetic self-test modes do not consume the real corpus.
git ls-files > "$work/tracked-inputs"
awk '{path=$0; while (sub(/\/[^/]*$/, "", path)) print path}' "$work/tracked-inputs" | sort -u > "$work/tracked-directories"
awk -F '\t' '
    {sub(/\r$/, "")}
    {
        command = $9
        while (match(command, /scripts\/[A-Za-z0-9_.-]+\.sh/)) {
            script = substr(command, RSTART, RLENGTH)
            command = substr(command, RSTART + RLENGTH)
            if (script == "scripts/verify-integration.sh" && $1 != "stage2-native-integration-corpus") continue
            if (script == "scripts/verify-cross-mode-differential.sh" && $1 != "stage2-cross-mode-semantic-abi-differential") continue
            print $1 "\t" script
        }
    }
' "$work/gates-full.tsv" > "$work/owning-scripts.tsv"
awk -F '\t' '
    {sub(/\r$/, "")}
    FILENAME == ARGV[1] { if ($9 ~ /^gate_[a-z0-9_]+$/) gate[$9] = $1; next }
    /^gate_[a-z0-9_]+\(\)/ { name = $1; sub(/\(\).*/, "", name) }
    /^}/ { name = "" }
    name in gate {
        line = $0
        while (match(line, /scripts\/[A-Za-z0-9_.-]+\.sh/)) {
            print gate[name] "\t" substr(line, RSTART, RLENGTH)
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$work/gates-full.tsv" "$ROOT/scripts/ci-verify.sh" >> "$work/owning-scripts.tsv"
# Traverse literal shell invocations, retaining the original gate owner across
# nested guards. A seen set bounds cycles; reading a missing script is an error.
awk -F '\t' '
    {gate[++count]=$1; script[count]=$2}
    END {
        for(i=1;i<=count;i++) {
            key=gate[i] SUBSEP script[i]
            if(seen[key]++) continue
            status=0
            while((status=getline line < script[i]) > 0) {
                if(line ~ /^[[:space:]]*#/) continue
                rest=line
                while(match(rest, /scripts\/[A-Za-z0-9_.-]+\.sh/)) {
                    child=substr(rest,RSTART,RLENGTH)
                    prefix=substr(rest,1,RSTART-1)
                    sub(/["]?\$\{?ROOT\}?\/$/, "", prefix)
                    # --self-test inspects inventories and planner metadata;
                    # its planner/probes do not execute primary fixtures.
                    if(child == "scripts/ci-affected.sh" && substr(rest,RSTART+RLENGTH) ~ /^["]?[[:space:]]+--self-test([[:space:];]|$)/) {
                        rest=substr(rest,RSTART+RLENGTH)
                        continue
                    }
                    # Direct command, sh/bash/exec, or assignment-prefixed call.
                    if(prefix ~ /(^|[;&|()][[:space:]]*)[[:space:]]*(sh|bash|exec)[[:space:]]+$/ || prefix ~ /^[[:space:]]*(([^[:space:]]+=[^[:space:]]+)[[:space:]]+)*["$A-Za-z_{}\/]*$/) {
                        gate[++count]=gate[i]; script[count]=child
                    }
                    rest=substr(rest,RSTART+RLENGTH)
                }
            }
            if(status < 0) {print "cannot read owning script: " script[i] > "/dev/stderr"; exit 1}
            close(script[i])
            print gate[i] "\t" script[i]
        }
    }
' "$work/owning-scripts.tsv" > "$work/recursive-scripts.tsv" || fail 'owning script traversal failed'
awk -F '\t' '
    {
        status=0; contents=""
        while ((status=getline line < $2) > 0) {
            if (line ~ /^[[:space:]]*#/) continue
            contents=contents line "\n"
            rest=line
            # Search roots are supporting inputs, not primary fixture lists.
            gsub(/--stdlib-root[[:space:]]+("[^"]*"|\047[^\047]*\047|[^[:space:]]+)/,"",rest)
            while (match(rest, /(src|tests|stdlib|docs)\/[A-Za-z0-9_.\/-]+/)) {
                print substr(rest, RSTART, RLENGTH) "\t" $1
                rest = substr(rest, RSTART + RLENGTH)
            }
            # Content sweeps also use bare directory roots rather than paths.
            if(line ~ /(^|[;&|()][[:space:]]*)[[:space:]]*find[[:space:]]/ || line ~ /git[[:space:]]+ls-files/) {
                n=split(line, words, /[[:space:]]+/)
                for(j=1;j<=n;j++) {
                    root=words[j]; gsub(/["\047]/,"",root)
                    sub(/\/\*\.tl$/,"",root)
                    sub(/\/$/,"",root)
                    if(root ~ /^(src|tests|stdlib|docs|examples)$/) print root "\t" $1
                }
            }
        }
        if(status < 0) {print "cannot read owning inputs: " $2 > "/dev/stderr"; exit 1}
        close($2)
        # The doctest discovery loop passes each literal root to find "$root".
        if(contents ~ /find[[:space:]]+"?\$root/ && match(contents,/for root in [^;]+;/)) {
            roots=substr(contents,RSTART,RLENGTH); sub(/^for root in /,"",roots); sub(/;$/,"",roots)
            n=split(roots,words," ")
            for(j=1;j<=n;j++) if(words[j] ~ /^(src|tests|stdlib|docs|examples)$/) print words[j] "\t" $1
        }
    }
' "$work/recursive-scripts.tsv" > "$work/script-inputs.raw" || fail 'owning input extraction failed'
sort -u "$work/script-inputs.raw" > "$work/script-inputs.tsv"
# Isolate both audit mechanisms from later fallback and inventory checks.
for script in verify-package-artifact-freshness.sh verify-lsp-transcript-batch.sh; do
    grep -Fx "stage2-public-tool-corpora$TAB""scripts/$script" "$work/recursive-scripts.tsv" >/dev/null || fail "nested guard not discovered: $script"
done
grep -Fx "stage2-stdlib-modules-and-fixtures$TAB"'scripts/check-stdlib-concat-lint.sh' "$work/recursive-scripts.tsv" >/dev/null || fail 'nested stdlib lint not discovered'
for gate in stage2-stdlib-documentation stage2-stdlib-modules-and-fixtures stage2-repository-doctests; do
    grep -Fx "stdlib$TAB$gate" "$work/script-inputs.tsv" >/dev/null || fail "whole-directory input not discovered: $gate"
done
manifest_concat_dir "$ROOT/src/compile_manifest.d" > "$work/compile-manifest.combined" || fail 'compile manifest load failed'
awk -F '|' '$1 == "case" {print $3 "\tstage2-selfhost-compile-manifest"}' "$work/compile-manifest.combined" >> "$work/script-inputs.tsv"

# Primary declarations add exact fixture owners. Imported/staged dependency
# lists and generic compiler-comparison suites remain advisory source classes.
awk -F '\t' '$1 ~ /\.cases$/ {print}' "$work/script-inputs.tsv" > "$work/inventory-owners.tsv"
awk -F '\t' '{sub(/\r$/, "")} {n=split($9, words, " "); for(i=1;i<=n;i++) if(words[i] ~ /^tests\/.*\.cases$/) print words[i] "\t" $1}' "$work/gates-full.tsv" >> "$work/inventory-owners.tsv"
{
    awk -F '\t' '$1 ~ /^tests\/.*\.d$/ {print $1 "\t" $2}' "$work/script-inputs.tsv"
    awk -F '\t' '{sub(/\r$/, "")} {n=split($9, words, " "); for(i=1;i<=n;i++) if(words[i] ~ /^tests\/.*\.d$/) print words[i] "\t" $1}' "$work/gates-full.tsv"
} | sort -u | while IFS=$TAB read -r case_dir case_gate; do
    [ -d "$ROOT/$case_dir" ] || continue
    for case_file in "$ROOT/$case_dir"/*.cases; do
        [ -f "$case_file" ] || continue
        printf '%s\t%s\n' "${case_file#"$ROOT"/}" "$case_gate"
    done
done >> "$work/inventory-owners.tsv"
# The public-tool family runs these transcripts and corpora together, and each
# map row that owns one of their inputs names the whole family, so every file
# requires every part.
for affected_inventory in tests/cli/public-*.cases; do
    for public_tool_gate in stage2-public-tool-affected-map stage2-public-tool-cli-transcripts-1 stage2-public-tool-cli-transcripts-2 stage2-public-tool-cli-transcripts-3 stage2-public-tool-corpora; do
        printf '%s\t%s\n' "$affected_inventory" "$public_tool_gate"
    done
done >> "$work/inventory-owners.tsv"
for affected_inventory in tests/apps/*.cases; do printf '%s\tstage2-app-workflow-corpus\n' "$affected_inventory"; done >> "$work/inventory-owners.tsv"
inventory_inputs() {
    # Reuse the canonical DSL translator for defaults and {{each}} expansion.
    # --list builds no compiler and writes only under our fresh scratch root.
    mkdir -p "$2" || return
    cut -f 1 "$work/inventory-owners.tsv" > "$2/inventories.raw" || return
    sort -u "$2/inventories.raw" > "$2/inventories" || return
    while IFS= read -r affected_inventory; do
        case "$affected_inventory" in
            *.fixtures.cases)
                "$ROOT/scripts/verify-codegen-cases.sh" --list-fixtures "$1/$affected_inventory" > "$2/fixtures.tsv" || return
                awk -F '\t' -v inventory="$affected_inventory" '
                    FILENAME == ARGV[1] {if($1 == inventory) owners[$2]=1; next}
                    {for(gate in owners) print $2 "\t" gate}
                ' "$work/inventory-owners.tsv" "$2/fixtures.tsv" || return
                continue ;;
        esac
        CODEGEN_CASES_WORKDIR="$2" "$ROOT/scripts/verify-codegen-cases.sh" --list "$1/$affected_inventory" >/dev/null || return
        affected_name=$(basename "$affected_inventory" .cases)
        awk -F '\t' -v inventory="$affected_inventory" -v tracked_file="$work/tracked-inputs" -v directory_file="$work/tracked-directories" '
            BEGIN {
                while ((getline path < tracked_file) > 0) tracked[path]=1
                while ((getline path < directory_file) > 0) tracked[path]=1
            }
            function each_value(text, value, at) {
                while ((at=index(text, "{{each}}"))) text=substr(text,1,at-1) value substr(text,at+8)
                return text
            }
            function paths(text, bare, artifact, fixtures_only, token, gate, absolute) {
                # Search roots and outputs are supporting paths, not primaries.
                gsub(/--stdlib-root[[:space:]]+("[^"]*"|\047[^\047]*\047|[^[:space:]]+)/,"",text)
                gsub(/(^|[[:space:]])(-o|--output|--out-dir)[[:space:]]+("[^"]*"|\047[^\047]*\047|[^[:space:]]+)/,"",text)
                gsub(/\{\{(root|native-root)\}\}\//, " @ROOT/", text)
                while (match(text, /(^|[[:space:]"\047])(@ROOT\/)?(src|tests|stdlib|tools|benchmarks|examples|docs)\/[A-Za-z0-9_.\/-]+/)) {
                    token=substr(text,RSTART,RLENGTH)
                    text=substr(text,RSTART+RLENGTH)
                    if (token ~ /\/$/ && text ~ /^\{\{/) continue
                    sub(/^[[:space:]"\047]+/, "", token)
                    absolute=(token ~ /^@ROOT\//)
                    if (absolute) sub(/^@ROOT\//, "", token)
                    sub(/\/$/, "", token)
                    if (!absolute && (!bare || !(token in tracked))) continue
                    if (artifact && token == "src/main.tl") continue
                    if (fixtures_only && token !~ /^(tests|src\/tests|stdlib\/tests)\//) continue
                    for (gate in owners) print token "\t" gate
                }
            }
            FILENAME == ARGV[1] {if($1 == inventory) owners[$2]=1; next}
            FILENAME == ARGV[2] {
                sub(/\r$/, ""); original[FNR]=$0
                # Fixed root-qualified fixture references include copied and batch inputs.
                if ($0 !~ /^[[:space:]]*#/) paths($0,0,0,1)
                next
            }
            /^cc_file / {embedded=1; next}
            /^CC_EOF_FILE_[0-9]+$/ {embedded=0; next}
            embedded {next}
            /^cc_case_[0-9]+\(\)/ {function_name=$1; next}
            /^cc_(run|cwd) / {
                split($0, words, " "); events[function_name,++count[function_name]]=words[2]
                next
            }
            /^}; then cc_fail / {
                split($0, words, " "); events[function_name,++count[function_name]]=words[4]
                next
            }
            /^cc_case / {split($0, quoted, /\047/); source=quoted[6]; next}
            /^cc_variant / {
                split($0, quoted, /\047/); value=quoted[8]
                paths(each_value(source,value),1,0,0)
                bare=1
                for(i=1;i<=count[function_name];i++) {
                    line=each_value(original[events[function_name,i]],value)
                    sub(/^[[:space:]]+/, "", line)
                    if(line ~ /^cwd /) {
                        directory=substr(line,5); gsub(/["\047]/,"",directory)
                        bare=(directory == "-" || directory == "{{root}}")
                    } else if(line ~ /^(run|exec|sh) /) {
                        artifact=(line ~ /^run (compile|build)[[:space:]]/ || (line ~ /^exec / && line ~ /\{\{compiler\}\}["\047]?[[:space:]]+(compile|build)[[:space:]]/))
                        fixtures_only=(line !~ /^run / && line !~ /\{\{compiler\}\}/)
                        paths(line,bare,artifact,fixtures_only)
                    }
                }
            }
        ' "$work/inventory-owners.tsv" "$1/$affected_inventory" "$2/$affected_name/plan.sh" || return
    done < "$2/inventories"
    manifest_concat_dir "$1/tests/integration/manifest.d" > "$2/integration-manifest.combined" || return
    awk -F '|' '{sub(/\r$/, "")} !/^#/ && NF >= 4 {
        print $4 "\tstage2-native-integration-corpus"
        for(i=10;i<=NF;i++) if($i ~ /^suite-members:/) {
            members=substr($i,15); n=split(members,names," ")
            for(j=1;j<=n;j++) if(names[j] != "") print "src/tests/" names[j] "\tstage2-native-integration-corpus"
        }
    }' "$2/integration-manifest.combined" || return
    manifest_concat_dir "$1/tests/safety/manifest.d" > "$2/safety-manifest.combined" || return
    awk -F '|' '{sub(/\r$/, "")} !/^#/ && NF >= 3 {print $3 "\tstage2-safety-corpus"}' "$2/safety-manifest.combined" || return
    manifest_concat_dir "$1/src/compile_manifest.d" > "$2/compile-manifest.combined" || return
    awk -F '|' '{sub(/\r$/, "")} $1 == "case" {print $3 "\tstage2-selfhost-compile-manifest"}' "$2/compile-manifest.combined" || return
}
inventory_inputs "$ROOT" "$work/inventory-plans" > "$work/primary.raw" || fail 'primary input extraction failed'
sort -u "$work/primary.raw" > "$work/primary-inputs.tsv"
# Pin the checked consumption boundary without running an owning harness.
. "$ROOT/scripts/lib-fixture-inventory.sh"
fixture_inventory=$(awk -F '\t' '$1 ~ /\.fixtures\.cases$/ {print $1; exit}' "$work/inventory-owners.tsv")
[ -n "$fixture_inventory" ] || fail 'no canonical fixture inventory discovered'
fixture_inventory_load "$fixture_inventory" "$work/fixture-interface.tsv" || fail 'fixture inventory load failed'
IFS=$TAB read -r fixture_label fixture_source < "$work/fixture-interface.tsv"
fixture_inventory_require "$work/fixture-interface.tsv" "$fixture_source" || fail 'declared runtime primary rejected'
if fixture_inventory_require "$work/fixture-interface.tsv" tests/undeclared-runtime-primary.tl 2> "$work/undeclared.err"; then
    fail 'undeclared runtime primary accepted'
fi
grep -Fx 'undeclared runtime primary: tests/undeclared-runtime-primary.tl' "$work/undeclared.err" >/dev/null || fail 'runtime rejection lost its diagnostic'
for malformed in empty missing-source unsupported; do
    : > "$work/$malformed.fixtures.cases"
    case "$malformed" in
        missing-source) printf 'do none\ncase missing\n' > "$work/$malformed.fixtures.cases" ;;
        unsupported) printf 'do none\ncase unsupported\nsource %s\neach extra\n' "$fixture_source" > "$work/$malformed.fixtures.cases" ;;
    esac
    if "$ROOT/scripts/verify-codegen-cases.sh" --list-fixtures "$work/$malformed.fixtures.cases" > "$work/$malformed.out" 2> "$work/$malformed.err"; then
        fail "$malformed fixture inventory accepted"
    fi
done
# Functions invoked as conditions cannot rely on errexit. Check early and late
# translator failures with every other input present, so a later manifest error
# cannot mask missing in-loop failure propagation. Omit rather than delete files.
IFS= read -r first_inventory < "$work/inventory-plans/inventories"
second_inventory=$(sed -n '2p' "$work/inventory-plans/inventories")
[ -n "$second_inventory" ] || fail 'failure regression needs two inventories'
manifest_list_dir "$ROOT/tests/integration/manifest.d" | sed "s#^$ROOT/##" > "$work/manifest-fragment-files" || fail 'integration manifest list failed'
manifest_list_dir "$ROOT/src/compile_manifest.d" | sed "s#^$ROOT/##" >> "$work/manifest-fragment-files" || fail 'compile manifest list failed'
manifest_list_dir "$ROOT/tests/safety/manifest.d" | sed "s#^$ROOT/##" >> "$work/manifest-fragment-files" || fail 'safety manifest list failed'
cat "$work/inventory-plans/inventories" "$work/manifest-fragment-files" > "$work/failure-inputs"
for failure_kind in missing partial; do
    omitted_inventory=$first_inventory
    [ "$failure_kind" != partial ] || omitted_inventory=$second_inventory
    while IFS= read -r affected_inventory; do
        [ "$affected_inventory" != "$omitted_inventory" ] || continue
        mkdir -p "$work/$failure_kind-root/$(dirname "$affected_inventory")"
        cp "$ROOT/$affected_inventory" "$work/$failure_kind-root/$affected_inventory"
    done < "$work/failure-inputs"
    if inventory_inputs "$work/$failure_kind-root" "$work/$failure_kind-plans" > "$work/$failure_kind.raw" 2> "$work/$failure_kind.err"; then
        fail "$failure_kind inventory extraction hid a translator failure"
    fi
    grep -F "missing case file: $work/$failure_kind-root/$omitted_inventory" "$work/$failure_kind.err" >/dev/null || fail 'failure regression missed its intended case file'
done
[ -s "$work/partial.raw" ] || fail 'late extraction failure probe emitted no initial ownership'
# Exercise the same inventory reader against Git actual Windows checkout bytes.
mkdir -p "$work/crlf-inputs"
{ cut -f 1 "$work/inventory-owners.tsv"; cat "$work/manifest-fragment-files"; } | sort -u > "$work/inventory-files"
while IFS= read -r affected_inventory; do
    mkdir -p "$work/crlf-inputs/$(dirname "$affected_inventory")"
    git -c core.autocrlf=true cat-file --filters --path="$affected_inventory" ":$affected_inventory" > "$work/crlf-inputs/$affected_inventory"
done < "$work/inventory-files"
inventory_inputs "$work/crlf-inputs" "$work/crlf-plans" > "$work/primary-crlf.raw" || fail 'Windows primary input extraction failed'
sort -u "$work/primary-crlf.raw" > "$work/primary-crlf.tsv"
cmp "$work/primary-inputs.tsv" "$work/primary-crlf.tsv" || fail 'Windows checkout changed primary input ownership'
# Check every declared edge without thousands of recursive planner calls.
# Allowed map globs contain only literal characters, dots and stars, so this
# matches the selector case patterns. The witnesses below also replay plans.
awk -F '\t' '
    FILENAME == ARGV[1] {
        if (/^#/ || $1 == "path" || $2 == "-") next
        pattern=$1; gsub(/\./, "\\.", pattern); gsub(/\*/, ".*", pattern)
        patterns[++rows]="^" pattern "$"; gates[rows]="," $2 ","
        next
    }
    FILENAME == ARGV[2] {directories[$0]=1; next}
    {
        path=($1 in directories ? $1 "/__ci_affected_directory_probe__.tl" : $1)
        known=0; covered=0
        for(i=1;i<=rows;i++) if(path ~ patterns[i] || patterns[i] == "^@always$") {
            if(patterns[i] != "^@always$") known=1
            if(gates[i] == ",*," || index(gates[i], "," $2 ",")) covered=1
        }
        if(known && !covered) {
            print "missing required primary owner: " $1 " -> " $2 > "/dev/stderr"
            failed=1
        }
    }
    END {exit failed}
' "$work/affected-paths.tsv" "$work/tracked-directories" "$work/primary-inputs.tsv" || fail 'primary inventory ownership is incomplete'

for host in linux windows; do
    "$ROOT/scripts/ci-verify.sh" --list-gates "$host" > "$work/$host.table"
    sed '1d' "$work/$host.table" | cut -f 1 > "$work/$host.full"
    # The literal-input, literal-reader and constructed-input replays below
    # batch their single-path queries per host, so the selector loads the
    # inventory, the reviewed map and each distinct dependency closure once
    # instead of once per query.
    batched=0
    : > "$work/$host-replay.batch"
    : > "$work/$host-replay.rows"
    while IFS=$TAB read -r pr run base head gate; do
        case "$pr" in \#* | pr) continue ;; esac
        "$selector" --host "$host" --paths "$ROOT/tests/fixtures/ci-affected/$pr.paths" > "$work/$host-$pr.ids" 2> "$work/$host-$pr.log"
        has_gate "$work/$host-$pr.ids" "$gate"
        # Check the captured original diff when history is available. Shallow
        # checkouts still run the regression offline from the committed fixture.
        if git cat-file -e "$base^{commit}" 2>/dev/null && git cat-file -e "$head^{commit}" 2>/dev/null; then
            git diff --name-only --no-renames "$base...$head" > "$work/$pr.actual"
            cmp "$work/$pr.actual" "$ROOT/tests/fixtures/ci-affected/$pr.paths" || fail "historical paths differ for #$pr run $run"
        fi
    done < "$ROOT/tests/fixtures/ci-affected/history.tsv"

    # Isolate the original triggering paths, so unrelated unmapped files in a
    # historical change cannot mask a missing compiler/stdlib map row.
    for path in src/compiler_backend_tests.tl src/compiler_backend.tl src/compiler_target_cfg.tl stdlib/json.tl tests/safety/division_by_zero_trap.tl; do
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/trigger.ids"
        has_gate "$work/trigger.ids" stage2-codegen-target-parity
        has_gate "$work/trigger.ids" stage2-safety-corpus
        has_gate "$work/trigger.ids" tlci-mutation-bootstrap-fixpoint
        case "$path" in
            src/*)
                has_gate "$work/trigger.ids" x64-executable-template-registry-coverage
                has_gate "$work/trigger.ids" compiler-state-schema-boundary ;;
            tests/*)
                has_gate "$work/trigger.ids" cross-mode-differential-oracle-self-tests
                has_gate "$work/trigger.ids" integration-manifest-validator-self-tests ;;
        esac
        has_gate "$work/trigger.ids" zero-cons-fixture-and-embedded-source-invariant
        awk -F '\t' '$6 != "-" {print $1}' "$work/gates-full.tsv" |
        while IFS= read -r gate; do
            if grep -Fx "$gate" "$work/$host.full" >/dev/null; then has_gate "$work/trigger.ids" "$gate"; fi
        done
        [ "$(wc -l < "$work/trigger.ids")" -lt "$(wc -l < "$work/$host.full")" ] || fail "source class selected the full table: $path"
        if grep -Fx linux-resident-memory-limit-helper-self-tests "$work/trigger.ids" >/dev/null; then
            fail 'source class includes unrelated memory-helper fixtures'
        fi
        "$selector" --host "$host" --paths "$work/paths" > "$work/required.ids"
        has_gate "$work/required.ids" stage2-codegen-target-parity
        case "$path" in stdlib/* | tests/safety/*) has_gate "$work/required.ids" stage2-safety-corpus ;; esac
        LC_ALL=C sort "$work/required.ids" > "$work/required.sorted"
        LC_ALL=C sort "$work/trigger.ids" > "$work/advisory.sorted"
        LC_ALL=C comm -23 "$work/required.sorted" "$work/advisory.sorted" > "$work/missing-advisory.ids"
        [ ! -s "$work/missing-advisory.ids" ] || fail 'required tier is not included in advisory'
    done
    # Every literal corpus input in a canonical gate command has an owning
    # required trigger, independently of the advisory input classifications.
    awk -F '\t' '{n = split($9, words, " "); for (i = 1; i <= n; i++) if (words[i] ~ /^tests\/[A-Za-z0-9._\/-]+$/) print words[i] "\t" $1}' "$work/gates-full.tsv" > "$work/literal-inputs.tsv"
    while IFS=$TAB read -r path gate; do
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        if grep -Fx "$path" "$work/tracked-directories" >/dev/null; then
            path="$path/__ci_affected_directory_probe__.cases"
        fi
        batched=$((batched + 1))
        printf '@@\t%s\trequired\t%s\n%s\n' "$host" "$work/$host-replay.$batched.ids" "$path" >> "$work/$host-replay.batch"
        printf '%s\t%s\t%s\n' "$batched" "$path" "$gate" >> "$work/$host-replay.rows"
    done < "$work/literal-inputs.tsv"
    while IFS=$TAB read -r path gate; do
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        path=${path%/}
        case "$path:$gate" in
            src/main.tl:*) continue ;; # Produced CLI workload: bootstrap plus advisory compiler consumers.
            src/sym_i64_env.tl:stage2-opt1-opt2-build-invariance) continue ;; # Staged supporting module, not a primary comparison fixture.
            src/compiler_embedded_stdlib_payload.tl:embedded-stdlib-tlci-bounded-resource-report | src/compiler_embedded_stdlib_payload.tl:embedded-stdlib-tlci-resource-verifier-self-tests | src/compiler_embedded_stdlib_payload.tl:embedded-stdlib-tlci-image | src/compiler_embedded_stdlib_payload.tl:stage2-compile-profile-verifier | src/compiler_embedded_stdlib_payload.tl:stage2-stdlib-modules-and-fixtures | src/compiler_embedded_stdlib_payload.tl:tlci-mutation-bootstrap-fixpoint) continue ;; # Nested image builder reads staged compiler support; payload's standalone guard remains required.
            stdlib/cpu.tl:stage2-spmd-runtime-dispatch | stdlib/cpu.tl:stage2-sde-fallback-*) continue ;; # Imported ISA-detector support; timestamp invalidates its artifact, no direct fixture contract.
            src/tests/compiler_codegen_smoke_suite.tl:stage2-opt1-opt2-build-invariance) continue ;; # Nested pool self-test uses this name as synthetic job data, not as compiled source.
        esac
        if ! grep -Fx "$path" "$work/tracked-inputs" >/dev/null; then
            if ! grep -Fx "$path" "$work/tracked-directories" >/dev/null; then continue; fi
            case "$path:$gate" in
                src:cli-tools-benchmark-repetition-self-test | src:zero-cons-structural-classifier-self-tests | stdlib:zero-cons-structural-classifier-self-tests | tests:zero-cons-structural-classifier-self-tests | examples:zero-cons-structural-classifier-self-tests | stdlib:docs-site-search-manifest-validator-self-tests) continue ;; # Self-test modes consume synthetic trees instead of repository content.
                src:stage2-inline-typelisp-tests | stdlib:stage2-inline-typelisp-tests | examples:stage2-inline-typelisp-tests) continue ;; # Broad inline discovery remains advisory; named units retain explicit owners.
                src:stage2-native-integration-corpus | stdlib:stage2-native-integration-corpus) continue ;; # Native manifest validator catalogs compiler/import dependencies by name only.
                stdlib:stage2-arena-sanitizer-selfhost) continue ;; # Generic instrumented compiler comparison, not a declared primary fixture contract.
                stdlib/tests:stage0-size-ratchet | stdlib/tests:stage2-arena-sanitizer-selfhost | stdlib/tests:stage2-stdlib-documentation) continue ;; # Excluded fixture trees.
                tests/integration:stage2-inline-typelisp-tests) continue ;; # Broad source-suite discovery is advisory; focused tests remain owner-selected.
                tests/safety:stage2-native-integration-corpus) continue ;; # Existence-only catalog for manifest dependency validation, not a content consumer.
            esac
            path="$path/__ci_affected_directory_probe__.tl"
        fi
        batched=$((batched + 1))
        printf '@@\t%s\trequired\t%s\n%s\n' "$host" "$work/$host-replay.$batched.ids" "$path" >> "$work/$host-replay.batch"
        printf '%s\t%s\t%s\n' "$batched" "$path" "$gate" >> "$work/$host-replay.rows"
    done < "$work/script-inputs.tsv"
    # Constructed script inputs and the reported independent source guards.
    for row in 'tests/spmd/package_callable/src/lib.tl package-native-tlci-dependency-macros' 'tests/spmd/package_consumer/src/main.tl package-native-tlci-dependency-macros' 'stdlib/tests/json_sequence_api.tl stage2-stdlib-selfhost-verifier' 'tests/integration/tail_call_stack_forward.tl stage2-regalloc-backend-asm-shape-gates' 'src/tests/compiler_typed_occurrence_smoke.tl stage2-native-integration-corpus' 'tests/safety/global_mut_borrow_deref_location_reject.tl stage2-public-tool-cli-transcripts-3' 'tests/safety/global_mut_borrow_field_overlap_reject.tl stage2-public-tool-cli-transcripts-3' 'tests/safety/global_mut_borrow_initializer_location_reject.tl stage2-public-tool-cli-transcripts-3' 'tests/safety/global_mut_borrow_noncall_location_reject.tl stage2-public-tool-cli-transcripts-3' 'tests/safety/global_mut_borrow_store_location_reject.tl stage2-public-tool-cli-transcripts-3' 'tests/safety/mut_borrow_forwarded_diagnostic_location_reject.tl stage2-public-tool-cli-transcripts-3' 'stdlib/json.tl stage2-docs-pages-build-path' 'stdlib/json.tl stage2-stdlib-documentation' 'stdlib/json.tl stage2-stdlib-modules-and-fixtures' 'stdlib/json.tl stage2-repository-doctests' 'src/build_cli_core.tl stage2-public-tool-corpora' 'src/compiler_driver_core.tl stage2-public-tool-corpora' 'src/compiler_lower.tl stage2-public-tool-corpora' 'src/lsp_frame_core.tl stage2-public-tool-corpora' 'src/main.tl cli-help-surface' 'src/compile_cli_core.tl cli-help-surface'; do
        path=${row% *}
        gate=${row##* }
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        batched=$((batched + 1))
        printf '@@\t%s\trequired\t%s\n%s\n' "$host" "$work/$host-replay.$batched.ids" "$path" >> "$work/$host-replay.batch"
        printf '%s\t%s\t%s\n' "$batched" "$path" "$gate" >> "$work/$host-replay.rows"
    done
    "$selector" --batch "$work/$host-replay.batch"
    while IFS=$TAB read -r batched path gate; do
        has_gate "$work/$host-replay.$batched.ids" "$gate" "$path"
    done < "$work/$host-replay.rows"
    # A batched record must match its single-query replay, in both tiers.
    IFS=$TAB read -r batched path gate < "$work/$host-replay.rows"
    printf '%s\n' "$path" > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" > "$work/single.ids"
    cmp "$work/single.ids" "$work/$host-replay.$batched.ids" || fail "batched record differs from its replay: $path"
    printf '@@\t%s\tadvisory\t%s\n%s\n' "$host" "$work/batch-advisory.ids" docs/testing-guide.md > "$work/batch-advisory.batch"
    "$selector" --batch "$work/batch-advisory.batch"
    printf '%s\n' docs/testing-guide.md > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/single-advisory.ids"
    cmp "$work/batch-advisory.ids" "$work/single-advisory.ids" || fail 'batched advisory record differs from its replay'
    for row in 'scripts/codegen-target-dispatch.d/compiler_backend.tsv stage2-codegen-target-parity' 'tools/embedded-stdlib-tlci/identity-fixtures.d/stdlib.clone.tsv embedded-stdlib-tlci-image,stage2-compile-profile-verifier'; do
        path=${row% *}
        gate=${row##* }
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/subset.ids"
        "$ROOT/scripts/ci-verify.sh" --list-gates "$host" --gates "bootstrap-compiler,bootstrap-fixpoint,shared-view-count-ratchet,typelisp-source-formatting,typelisp-source-lint,stage2-repository-doctests,$gate" > "$work/subset.table"
        sed '1d' "$work/subset.table" | cut -f 1 > "$work/subset.expected"
        cmp "$work/subset.ids" "$work/subset.expected" || fail "wrong dependency closure: $path"
    done
    printf '%s\n' tests/safety/manifest.d/arena-brands-phases.manifest scripts/codegen-target-dispatch.d/compiler_backend.tsv tests/safety/manifest.d/arena-brands-phases.manifest > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" > "$work/union.ids"
    has_gate "$work/union.ids" stage2-safety-corpus
    has_gate "$work/union.ids" stage2-codegen-target-parity
    [ "$(sort "$work/union.ids" | uniq -d | wc -l)" -eq 0 ] || fail 'duplicate gate IDs'
    printf '%s\n' 'unmapped/new file.tl' > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" > "$work/unknown.ids" 2> "$work/unknown.log"
    cmp "$work/unknown.ids" "$work/$host.full" || fail 'unmapped path did not select full table'
    for path in tests/unmapped-corpus-data.bin tests/unmapped-corpus-source.tl; do
        printf '%s\n' "$path" > "$work/paths"
        for tier in required advisory; do
            "$selector" --host "$host" --paths "$work/paths" --tier "$tier" > "$work/advisory-only.ids" 2> "$work/advisory-only.log"
            cmp "$work/advisory-only.ids" "$work/$host.full" || fail 'advisory-only match omitted an unknown required consumer'
        done
    done
    for path in scripts/ci-verify.sh scripts/lib-ci-gates.sh scripts/lib-ci-local.sh scripts/ci-gates.d/bootstrap-compiler.tsv .github/workflows/ci.yml tests/public-tools/example.sh tests/fixtures/ci-affected/history.tsv; do
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/harness.ids"
        cmp "$work/harness.ids" "$work/$host.full" || fail "harness path did not select full table: $path"
    done
    printf '%s\n' docs/testing-guide.md > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/docs.ids"
    has_gate "$work/docs.ids" stage2-docs-pages-build-path
    has_gate "$work/docs.ids" stage2-repository-doctests
    if grep -Fx stage2-opt1-opt2-build-invariance "$work/docs.ids" >/dev/null; then fail 'prose selected build invariance'; fi
    printf '%s\n' src/compiler_backend.tl > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/one-source.ids"
    awk 'BEGIN {for (i = 1; i <= 128; i++) print "src/compiler_large_" i ".tl"}' > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/many-source.ids"
    cmp "$work/one-source.ids" "$work/many-source.ids" || fail 'large source changes expanded duplicate requests'
done

# Exercise real Git diff discovery and the execution boundary in an isolated
# repository. Only its ci-verify entry point is a recording stub; its listing
# delegates to the real planner above. There is no production command override.
repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/tests/safety/manifest.d"
printf '/target/\n' > "$repo/.gitignore"
cp "$selector" "$ROOT/scripts/lib-ci-gates.sh" "$ROOT/scripts/lib-ci-local.sh" "$ROOT/scripts/lib-stage0.sh" \
    "$ROOT/scripts/lib-linux-entry.sh" "$ROOT/scripts/lib-gate.sh" "$repo/scripts/"
cp -R "$ROOT/scripts/ci-gates.d" "$ROOT/scripts/ci-affected-paths.d" "$repo/scripts/"
cat > "$repo/scripts/ci-verify.sh" <<'STUB'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --list-gates ]; then exec "$CI_AFFECTED_TEST_VERIFY" "$@"; fi
printf '%s\n' "${TYPELISP_INLINE_TEST_WORKERS-unset}" "${TYPELISP_BUILD_INVARIANCE_WORKERS-unset}" \
    "${TYPELISP_INTEGRATION_WORKERS-unset}" "${TYPELISP_COMPILE_MANIFEST_WORKERS-unset}" \
    "cache=${TYPELISP_CI_LOCAL_CACHE-unset}" "scope=${TYPELISP_CI_LOCAL_SCOPE_PATHS-unset}" \
    "bin=${TYPELISP_BIN-unset}" "integration_changed=${TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES-unset}" \
    "$@" > "$CI_AFFECTED_TEST_CALL"
printf 'run\n' >> "$CI_AFFECTED_TEST_EXECUTIONS"
exit "${CI_AFFECTED_TEST_EXIT:-0}"
STUB
chmod +x "$repo/scripts/ci-verify.sh"
export CI_AFFECTED_TEST_VERIFY="$ROOT/scripts/ci-verify.sh"
export CI_AFFECTED_TEST_CALL="$work/run.call"
export CI_AFFECTED_TEST_EXECUTIONS="$work/run.executions"
: > "$CI_AFFECTED_TEST_EXECUTIONS"
printf 'initial\n' > "$repo/tests/safety/manifest.d/sample.manifest"
git -C "$repo" init -q
git -C "$repo" add .
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
base=$(git -C "$repo" rev-parse HEAD)
fixture_selector="$repo/scripts/ci-affected.sh"
: > "$work/empty.paths"
"$fixture_selector" --paths "$work/empty.paths" > "$work/empty.ids"
has_gate "$work/empty.ids" shared-view-count-ratchet
has_gate "$work/empty.ids" typelisp-source-formatting
has_gate "$work/empty.ids" typelisp-source-lint
printf 'unstaged\n' >> "$repo/tests/safety/manifest.d/sample.manifest"
"$fixture_selector" --base "$base" > "$work/unstaged.ids" 2> "$work/unstaged.log"
has_gate "$work/unstaged.ids" stage2-safety-corpus
git -C "$repo" add tests/safety/manifest.d/sample.manifest
"$fixture_selector" --base "$base" > "$work/staged.ids" 2> "$work/staged.log"
cmp "$work/staged.ids" "$work/unstaged.ids" || fail 'staged edit missed'
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm edit
"$fixture_selector" --base "$base" > "$work/committed.ids" 2> "$work/committed.log"
cmp "$work/staged.ids" "$work/committed.ids" || fail 'committed edit missed'

case "$(uname -s)" in Linux*) native_host=linux ;; *) native_host=windows ;; esac
# The stub records the four pool worker counts, the local cache root, the scope
# inventory, the seed and the integration changed-files filter (lines 1-8), then
# ci-verify's arguments. Local runs drop the hosted and seed environment so
# their expectations hold anywhere.
local_run() {
    env -u GITHUB_ACTIONS -u TYPELISP_BIN -u TYPELISP_STAGE0_DIR -u TYPELISP_INLINE_TEST_WORKERS \
        -u TYPELISP_BUILD_INVARIANCE_WORKERS -u TYPELISP_INTEGRATION_WORKERS -u TYPELISP_COMPILE_MANIFEST_WORKERS \
        -u TYPELISP_CI_LOCAL_CACHE -u TYPELISP_CI_LOCAL_SCOPE_PATHS -u TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES "$@"
}
cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
# expect_workers JOBS: unset worker counts keep script defaults with at least
# three CPUs per gate, otherwise share the CPUs between the parallel gates.
expect_workers() {
    per_gate=$((cpus / $1))
    [ "$per_gate" -ge 1 ] || per_gate=1
    [ "$per_gate" -lt 3 ] || per_gate=unset
    printf '%s\n' "$per_gate" "$per_gate" "$per_gate" "$per_gate" > "$work/workers.expected"
    sed -n '1,4p' "$work/run.call" > "$work/workers.actual"
    cmp "$work/workers.actual" "$work/workers.expected" || fail "worker counts for --jobs $1 differ from the CPU share"
}
expect_call_line() {
    sed -n "$1p" "$work/run.call" | grep -Fx -- "$2" >/dev/null || fail "ci-verify call line $1 is not $2 ($3)"
}
local_run "$fixture_selector" --base "$base" --run --jobs 1 > "$work/run.ids" 2> "$work/run.log"
expect_workers 1
expect_call_line 5 "cache=$repo/target/ci-affected-cache" 'local cache root'
scope_file=$(sed -n '6s/^scope=//p' "$work/run.call")
git -C "$repo" -c core.quotePath=true diff --no-relative --name-only --no-renames "$base" -- > "$work/scope.expected"
cmp "$scope_file" "$work/scope.expected" || fail 'scope inventory differs from the changed paths'
expect_call_line 7 bin=unset 'no seed without a cache hit'
expect_call_line 8 'integration_changed=tests/safety/manifest.d/sample.manifest' 'local integration changed files'
expect_call_line 9 --gates 'subset flag'
tr '\n' ',' < "$work/committed.ids" | sed 's/,$//' > "$work/run.expected-csv"
sed -n '10p' "$work/run.call" | tr -d '\n' > "$work/run.actual-csv"
cmp "$work/run.actual-csv" "$work/run.expected-csv" || fail 'executed selection differs from printed selection'
[ "$(wc -l < "$work/run.call")" -eq 10 ] || fail '--jobs 1 passed a parallel flag'
cmp "$work/run.ids" "$work/committed.ids" || fail '--run changed the printed selection'

# Parallel runs pass --jobs and the memory budget; explicit workers are kept.
local_run env TYPELISP_INTEGRATION_WORKERS=3 "$fixture_selector" --base "$base" --run --jobs 2 --memory-mib 16384 \
    > "$work/parallel.ids" 2> "$work/parallel.log"
cmp "$work/parallel.ids" "$work/committed.ids" || fail '--jobs changed the printed selection'
expect_call_line 3 3 'explicit integration workers'
expect_call_line 11 --jobs 'parallel flag'
expect_call_line 12 2 'parallel job count'
expect_call_line 13 --memory-mib 'memory flag'
expect_call_line 14 16384 'memory budget'
local_run "$fixture_selector" --base "$base" --run --jobs 2 --memory-mib 16384 > /dev/null 2>&1
expect_workers 2
local_run "$fixture_selector" --base "$base" --run --jobs 1 --no-cache --no-scope > /dev/null 2>&1
expect_call_line 5 cache=unset '--no-cache'
expect_call_line 6 scope=unset '--no-scope'
expect_call_line 8 integration_changed=unset '--no-scope clears integration changed files'
local_run env GITHUB_ACTIONS=true "$fixture_selector" --base "$base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 5 cache=unset 'hosted runs have no local cache'
expect_call_line 6 scope=unset 'hosted runs have no local scope'
expect_call_line 8 integration_changed=unset 'hosted runs have no integration changed files'

# Integration changed-file scoping: exported on tests/integration/*.tl-only
# local --run, and unset on --no-scope, src/ edits, manifest.d/ edits, and
# GITHUB_ACTIONS=true (even when pre-set in the caller environment).
int_base=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/tests/integration/manifest.d" "$repo/src"
printf '(define (main) : i64 0)\n' > "$repo/tests/integration/scoped_one.tl"
local_run "$fixture_selector" --base "$int_base" --run --jobs 1 > "$work/int-one.ids" 2> "$work/int-one.log"
has_gate "$work/int-one.ids" stage2-native-integration-corpus
expect_call_line 8 'integration_changed=tests/integration/scoped_one.tl' 'tests/integration/*.tl-only exports integration changed files'
printf '(define (main) : i64 1)\n' > "$repo/tests/integration/scoped_two.tl"
local_run "$fixture_selector" --base "$int_base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 8 'integration_changed=tests/integration/scoped_one.tl tests/integration/scoped_two.tl' 'multiple tests/integration/*.tl files join with spaces'
local_run env TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES=stale.tl "$fixture_selector" --base "$int_base" --run --jobs 1 --no-scope > /dev/null 2>&1
expect_call_line 8 integration_changed=unset '--no-scope unsets integration changed files on tests/integration/*.tl'
local_run env GITHUB_ACTIONS=true TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES=stale.tl "$fixture_selector" --base "$int_base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 8 integration_changed=unset 'GITHUB_ACTIONS=true unsets integration changed files on tests/integration/*.tl'
printf 'case|all|-|tests/integration/scoped_one.tl|0|-|-|-|-\n' > "$repo/tests/integration/manifest.d/scoped.manifest"
local_run env TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES=stale.tl "$fixture_selector" --base "$int_base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 8 integration_changed=unset 'manifest.d edit unsets integration changed files'
rm -f "$repo/tests/integration/manifest.d/scoped.manifest"
printf '(define (compiler) : i64 0)\n' > "$repo/src/scoped_edit.tl"
local_run env TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES=stale.tl "$fixture_selector" --base "$int_base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 8 integration_changed=unset 'src/ edit unsets integration changed files'
rm -rf "$repo/tests/integration" "$repo/src"

# A valid entry for the local seed skips the stage0 fetch; any input change,
# a different seed or a damaged entry is a miss.
cache_fixture() {
    mkdir -p "$1/src" "$1/stdlib" "$1/tools/build-stdlib-sysroot" "$1/target/stage0" "$1/target/build-stage0" \
        "$1/target/embedded-stdlib-tlci/tools" "$1/target/bootstrap-fixpoint/lib/triple"
    printf '(define (main) : i64 0)\n' > "$1/src/main.tl"
    printf '(define (helper) : i64 1)\n' > "$1/stdlib/core.tl"
    printf '(define (main) : i64 0)\n' > "$1/tools/build-stdlib-sysroot/main.tl"
    printf '#!/bin/sh\n' > "$1/target/stage0/typelisp"
    chmod +x "$1/target/stage0/typelisp"
    for stage in stage1 stage2 stage3; do printf '#!/bin/sh\necho %s\n' "$stage" > "$1/target/bootstrap-fixpoint/$stage"; done
    chmod +x "$1/target/bootstrap-fixpoint/"stage[123]
    printf 'fixpoint\n' > "$1/target/bootstrap-fixpoint/stage3.s"
    printf 'object\n' > "$1/target/bootstrap-fixpoint/stage3.o"
    printf 'sysroot\n' > "$1/target/bootstrap-fixpoint/lib/triple/stdlib.tli"
    printf 'commit' > "$1/target/build-stage0/git-hash.txt"
    printf 'tree' > "$1/target/build-stage0/tree-hash.txt"
    printf 'image\n' > "$1/target/embedded-stdlib-tlci/stdlib.tlci"
    printf 'tool\n' > "$1/target/embedded-stdlib-tlci/tools/tool"
}
cache_fixture "$repo"
cache_key=$(ci_local_cache_key "$repo" "$repo/target/stage0/typelisp")
cache_entry="$repo/target/ci-affected-cache/$cache_key"
ci_local_cache_valid "$cache_entry" && fail 'an absent cache entry was valid'
ci_local_cache_store "$cache_entry" "$repo" "$repo/target/bootstrap-fixpoint" "$repo/target/bootstrap-fixpoint/stage3" > /dev/null
ci_local_cache_valid "$cache_entry" || fail 'a stored cache entry was invalid'
[ ! -e "$cache_entry/bootstrap-fixpoint/stage3.o" ] || fail 'the cache stored an object file'
[ ! -e "$cache_entry/embedded-stdlib-tlci/tools" ] || fail 'the cache stored the image tool cache'
[ "$(ci_local_cache_key "$repo" "$repo/target/stage0/typelisp")" = "$cache_key" ] || fail 'the cache key is unstable'
local_run "$fixture_selector" --base "$base" --run --jobs 1 > /dev/null 2> "$work/hit.log"
expect_call_line 7 "bin=$repo/target/stage0/typelisp" 'a cache hit reuses the local seed'
grep -F 'skipping the stage0 fetch' "$work/hit.log" > /dev/null || fail 'a cache hit did not report the skipped fetch'
local_run "$fixture_selector" --base "$base" --run --jobs 1 --no-cache > /dev/null 2>&1
expect_call_line 7 bin=unset '--no-cache fetches stage0'
local_run env GITHUB_ACTIONS=true "$fixture_selector" --base "$base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 7 bin=unset 'hosted runs fetch stage0'
# Restore puts the outputs and both compiler handoffs back.
rm -rf "$repo/target/bootstrap-fixpoint" "$repo/target/build-stage0" "$repo/target/embedded-stdlib-tlci"
ci_local_cache_restore "$cache_entry" "$repo" "$repo/target/bootstrap-fixpoint" "$work/stage1.path" "$work/stage2.path" > /dev/null ||
    fail 'a valid cache entry did not restore'
[ "$(cat "$work/stage1.path")" = "$repo/target/bootstrap-fixpoint/stage1" ] || fail 'restore wrote the wrong stage1 handoff'
[ "$(cat "$work/stage2.path")" = "$repo/target/bootstrap-fixpoint/stage3" ] || fail 'restore wrote the wrong converged handoff'
[ -x "$repo/target/bootstrap-fixpoint/stage3" ] || fail 'restore lost the converged compiler'
cmp "$repo/target/bootstrap-fixpoint/lib/triple/stdlib.tli" "$cache_entry/bootstrap-fixpoint/lib/triple/stdlib.tli" || fail 'restore lost the sysroot'
[ "$(cat "$repo/target/build-stage0/git-hash.txt")" = commit ] || fail 'restore lost the build identity'
[ -f "$repo/target/embedded-stdlib-tlci/stdlib.tlci" ] || fail 'restore lost the embedded image'
for change in src/main.tl stdlib/core.tl target/stage0/typelisp scripts/lib-ci-local.sh \
    scripts/lib-linux-entry.sh scripts/lib-gate.sh tools/build-stdlib-sysroot/main.tl; do
    cp "$repo/$change" "$work/held-change"
    printf '\n' >> "$repo/$change"
    [ "$(ci_local_cache_key "$repo" "$repo/target/stage0/typelisp")" != "$cache_key" ] || fail "changing $change kept the cache key"
    cp "$work/held-change" "$repo/$change"
done
# Provenance-checking gates bypass the stage0-fetch skip when cached
# HEAD/HEAD^{tree} disagrees, while keeping it when provenance matches.
local_run "$fixture_selector" --base "$base" --tier advisory --run --jobs 1 > /dev/null 2>&1
expect_call_line 7 bin=unset 'stale provenance with a provenance gate did not bypass stage0-fetch skip'
git -C "$repo" rev-parse HEAD | tr -d '\r\n' > "$repo/target/build-stage0/git-hash.txt"
git -C "$repo" rev-parse 'HEAD^{tree}' | tr -d '\r\n' > "$repo/target/build-stage0/tree-hash.txt"
ci_local_cache_store "$cache_entry" "$repo" "$repo/target/bootstrap-fixpoint" "$repo/target/bootstrap-fixpoint/stage3" > /dev/null
local_run "$fixture_selector" --base "$base" --tier advisory --run --jobs 1 > /dev/null 2>&1
expect_call_line 7 "bin=$repo/target/stage0/typelisp" 'matching provenance with a provenance gate missed stage0-fetch skip'
printf 'damaged\n' >> "$cache_entry/bootstrap-fixpoint/stage3"
ci_local_cache_valid "$cache_entry" && fail 'a damaged cache entry was valid'
local_run "$fixture_selector" --base "$base" --run --jobs 1 > /dev/null 2>&1
expect_call_line 7 bin=unset 'a damaged entry is a miss'
ci_local_cache_restore "$cache_entry" "$repo" "$work/restore" "$work/stage1.path" "$work/stage2.path" > /dev/null 2>&1 &&
    fail 'a damaged cache entry restored'
rm -rf "$repo/src" "$repo/stdlib" "$repo/tools" "$repo/target"

# Provenance-checking gates in ci-verify.sh bypass the local cache whenever
# cached build-stage0/{git-hash.txt,tree-hash.txt} disagrees with current
# HEAD/HEAD^{tree}, while ordinary doc/test runs still hit across commits.
vrepo="$work/verify-cache-repo"
mkdir -p "$vrepo/scripts/ci-gates.d" "$vrepo/docs"
printf '/target/\n' > "$vrepo/.gitignore"
cp "$ROOT/scripts/ci-verify.sh" "$ROOT/scripts/lib-ci-gates.sh" "$ROOT/scripts/lib-ci-local.sh" \
    "$ROOT/scripts/lib-linux-entry.sh" "$ROOT/scripts/lib-ci-timing.sh" "$ROOT/scripts/lib-benchmark.sh" \
    "$ROOT/scripts/lib-bounded-pool.sh" "$ROOT/scripts/lib-gate.sh" "$vrepo/scripts/"
printf 'tool\thosts\tgates\tcheck\tinstall\n' > "$vrepo/scripts/ci-host-tools.tsv"
cat > "$vrepo/scripts/check-bootstrap-fixpoint.sh" <<'VBOOT'
#!/usr/bin/env sh
printf 'rebuilt\n' > "$VERIFY_CACHE_TEST_MARKER"
exit 77
VBOOT
cat > "$vrepo/scripts/stub-gate.sh" <<'VGATE'
#!/usr/bin/env sh
exit 0
VGATE
chmod +x "$vrepo/scripts/check-bootstrap-fixpoint.sh" "$vrepo/scripts/stub-gate.sh"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\nbootstrap-compiler\t100\tall\tbootstrap compiler\t-\t-\t256\t-\tgate_bootstrap_compiler\tlinux-1\twindows-1\tcompiler,stdlib,corpus\tfixture\n' > "$vrepo/scripts/ci-gates.d/bootstrap-compiler.tsv"
for vgate in ordinary-gate linux-self-compile-measurement embedded-stdlib-tlci-bounded-resource-report tlci-native-route-sustained-stress; do
    printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\n%s\t50\tall\t%s\tbootstrap-compiler\tstage2\t256\t-\tscripts/stub-gate.sh\tlinux-1\twindows-1\tcompiler,stdlib,corpus\tfixture\n' "$vgate" "$vgate" > "$vrepo/scripts/ci-gates.d/$vgate.tsv"
done
cache_fixture "$vrepo"
# Make stub stage3 exit non-zero on the safety probe after cache restore so
# cache hits terminate immediately after logging the restore without needing as/ld.
printf '#!/bin/sh\nexit 1\n' > "$vrepo/target/bootstrap-fixpoint/stage3"
chmod +x "$vrepo/target/bootstrap-fixpoint/stage3"
printf 'v1\n' > "$vrepo/docs/note.md"
git -C "$vrepo" init -q
git -C "$vrepo" add .
git -C "$vrepo" -c user.name=Test -c user.email=test@example.invalid commit -qm v1
v_head1=$(git -C "$vrepo" rev-parse HEAD)
v_tree1=$(git -C "$vrepo" rev-parse 'HEAD^{tree}')
v_key=$(ci_local_cache_key "$vrepo" "$vrepo/target/stage0/typelisp")
v_entry="$vrepo/target/ci-affected-cache/$v_key"
printf '%s' "$v_head1" > "$vrepo/target/build-stage0/git-hash.txt"
printf '%s' "$v_tree1" > "$vrepo/target/build-stage0/tree-hash.txt"
ci_local_cache_store "$v_entry" "$vrepo" "$vrepo/target/bootstrap-fixpoint" "$vrepo/target/bootstrap-fixpoint/stage3" > /dev/null
run_verify_cache() {
    rm -f "$work/v.marker"
    v_status=0
    env -u GITHUB_ACTIONS -u TYPELISP_CI_COMPILER_ENVELOPES -u TYPELISP_CI_COMPILER_ENVELOPE_DIR \
        -u TYPELISP_BOOTSTRAP_WORKDIR -u TYPELISP_CI_TIMING -u TYPELISP_CI_TIMING_FILE \
        -u TYPELISP_CI_TIMING_GATE -u TYPELISP_CI_LOCAL_SCOPE_PATHS -u TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES \
        TYPELISP_CI_LOCAL_CACHE="$vrepo/target/ci-affected-cache" \
        TYPELISP_BIN="$vrepo/target/stage0/typelisp" VERIFY_CACHE_TEST_MARKER="$work/v.marker" \
        "$vrepo/scripts/ci-verify.sh" --gates "$1" > "$work/v.out" 2>&1 || v_status=$?
}
# Same commit + tree: even a provenance gate hits the local cache.
run_verify_cache linux-self-compile-measurement
grep -F '[ci-verify] local bootstrap cache hit:' "$work/v.out" > /dev/null || fail 'same-commit provenance gate missed local cache'
grep -F '[ci-verify] local cache hit: reused the proven bootstrap' "$work/v.out" > /dev/null || fail 'same-commit provenance gate did not restore local cache'
[ ! -e "$work/v.marker" ] || fail 'same-commit provenance gate invoked bootstrap rebuild'
# Advance commit and tree with a doc-only change (bootstrap cache key unchanged).
printf 'v2\n' > "$vrepo/docs/note.md"
git -C "$vrepo" add docs/note.md
git -C "$vrepo" -c user.name=Test -c user.email=test@example.invalid commit -qm v2
v_head2=$(git -C "$vrepo" rev-parse HEAD)
v_tree2=$(git -C "$vrepo" rev-parse 'HEAD^{tree}')
[ "$v_head1" != "$v_head2" ] && [ "$v_tree1" != "$v_tree2" ] || fail 'doc commit did not advance HEAD and tree'
[ "$(ci_local_cache_key "$vrepo" "$vrepo/target/stage0/typelisp")" = "$v_key" ] || fail 'doc commit unexpectedly changed bootstrap cache key'
# Ordinary non-provenance gate still gets a cross-commit cache hit.
run_verify_cache ordinary-gate
grep -F '[ci-verify] local bootstrap cache hit:' "$work/v.out" > /dev/null || fail 'ordinary cross-commit gate lost its local cache hit'
grep -F '[ci-verify] local cache hit: reused the proven bootstrap' "$work/v.out" > /dev/null || fail 'ordinary cross-commit gate did not restore local cache'
[ ! -e "$work/v.marker" ] || fail 'ordinary cross-commit gate invoked bootstrap rebuild'
# Every provenance-checking gate bypasses the stale cache and rebuilds.
for prov_gate in linux-self-compile-measurement embedded-stdlib-tlci-bounded-resource-report tlci-native-route-sustained-stress; do
    run_verify_cache "$prov_gate"
    [ "$v_status" = 77 ] || fail "provenance gate $prov_gate did not run bootstrap rebuild (exit $v_status)"
    grep -F '[ci-verify] local bootstrap cache bypassed:' "$work/v.out" > /dev/null || fail "provenance gate $prov_gate did not report cache bypass"
    ! grep -F '[ci-verify] local cache hit: reused the proven bootstrap' "$work/v.out" > /dev/null || fail "provenance gate $prov_gate restored a stale cache entry"
    [ -f "$work/v.marker" ] || fail "provenance gate $prov_gate did not invoke check-bootstrap-fixpoint.sh"
done
# HEAD-only mismatch (empty commit, identical HEAD^{tree}) also bypasses.
git -C "$vrepo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm v3-same-tree
v_head3=$(git -C "$vrepo" rev-parse HEAD)
[ "$(git -C "$vrepo" rev-parse 'HEAD^{tree}')" = "$v_tree2" ] || fail 'empty commit changed HEAD^{tree}'
printf '%s' "$v_head2" > "$vrepo/target/build-stage0/git-hash.txt"
printf '%s' "$v_tree2" > "$vrepo/target/build-stage0/tree-hash.txt"
ci_local_cache_store "$v_entry" "$vrepo" "$vrepo/target/bootstrap-fixpoint" "$vrepo/target/bootstrap-fixpoint/stage3" > /dev/null
run_verify_cache linux-self-compile-measurement
[ "$v_status" = 77 ] && [ -f "$work/v.marker" ] || fail 'HEAD-only mismatch did not bypass local cache'
# HEAD^{tree}-only mismatch (matching HEAD, stale tree) also bypasses.
printf '%s' "$v_head3" > "$vrepo/target/build-stage0/git-hash.txt"
printf '%s' "$v_tree1" > "$vrepo/target/build-stage0/tree-hash.txt"
ci_local_cache_store "$v_entry" "$vrepo" "$vrepo/target/bootstrap-fixpoint" "$vrepo/target/bootstrap-fixpoint/stage3" > /dev/null
run_verify_cache embedded-stdlib-tlci-bounded-resource-report
[ "$v_status" = 77 ] && [ -f "$work/v.marker" ] || fail 'tree-only mismatch did not bypass local cache'

# Changed-file scoping: only a change outside src/, stdlib/ and scripts/ is
# scoped, to the changed candidates and the files that name a changed module.
mkdir -p "$work/scope/tests"
printf '(import tests.helper)\n' > "$work/scope/tests/user.tl"
printf '(define (helper) : i64 1)\n' > "$work/scope/tests/helper.tl"
printf '(define (other) : i64 2)\n' > "$work/scope/tests/other.tl"
printf 'tests/helper.tl\ntests/other.tl\ntests/user.tl\n' > "$work/scope/candidates"
printf 'tests/helper.tl\ndocs/guide.md\n' > "$work/scope/changed"
(
    cd "$work/scope"
    TYPELISP_CI_LOCAL_SCOPE_PATHS="$work/scope/changed"
    unset GITHUB_ACTIONS TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES
    ci_local_scope_active || fail 'a corpus-only change was not scoped'
    [ "$(ci_local_scope_paths)" = 'tests/helper.tl docs/guide.md' ] || fail 'ci_local_scope_paths formatted unexpected paths'
    ci_local_scope_filter candidates selected
    printf 'tests/helper.tl\ntests/user.tl\n' > expected
    cmp selected expected || fail 'scope filter missed a changed file or its importer'
    for unscoped in src/compiler.tl stdlib/core.tl scripts/check-tl-lint.sh '"quoted\npath"'; do
        printf 'docs/guide.md\n%s\n' "$unscoped" > changed
        ! ci_local_scope_active || fail "a change to $unscoped was scoped"
        ! ci_local_scope_paths >/dev/null || fail "ci_local_scope_paths accepted $unscoped"
    done
    for unsafe_int in tests/integration/manifest.d/a.manifest tests/integration/gen.awk 'tests/integration/with space.tl' 'tests/integration/with,comma.tl'; do
        printf '%s\n' "$unsafe_int" > changed
        ! ci_local_scope_paths >/dev/null || fail "ci_local_scope_paths accepted $unsafe_int"
    done
    : > changed
    ! ci_local_scope_active || fail 'an empty inventory was scoped'
    ! ci_local_scope_paths >/dev/null || fail 'ci_local_scope_paths accepted an empty inventory'
    TYPELISP_CI_LOCAL_SCOPE_PATHS="$work/scope/missing"
    ! ci_local_scope_active || fail 'an unreadable inventory was scoped'
    TYPELISP_CI_LOCAL_SCOPE_PATHS=
    ! ci_local_scope_active || fail 'a run without an inventory was scoped'
)
printf 'docs/guide.md\n' > "$work/scope/docs-only"
env -u GITHUB_ACTIONS TYPELISP_CI_LOCAL_SCOPE_PATHS="$work/scope/docs-only" "$ROOT/scripts/check-shared-view-count.sh" > "$work/shared-view.out" 2>&1 ||
    fail 'the scoped shared-view check failed'
grep -F 'touches no src/ or stdlib/ source' "$work/shared-view.out" > /dev/null || fail 'the shared-view check ignored the local scope'
# A scoped lint run over a non-src .tl file must succeed even when zero src/ files match.
lint_repo="$work/lint-scope-repo"
mkdir -p "$lint_repo/scripts" "$lint_repo/tests/integration"
cp "$ROOT/scripts/check-tl-lint.sh" "$ROOT/scripts/lib-ci-local.sh" "$ROOT/scripts/lib-ci-timing.sh" \
    "$ROOT/scripts/lib-gate.sh" "$ROOT/scripts/lib-bounded-pool.sh" "$lint_repo/scripts/"
printf '(define (main) : i64 0)\n' > "$lint_repo/tests/integration/unique_scoped_lint.tl"
git -C "$lint_repo" init -q
git -C "$lint_repo" add .
git -C "$lint_repo" -c user.name=Test -c user.email=test@example.invalid commit -qm lint-fixture
cat > "$work/scope/fake-typelisp" <<'FAKE'
#!/usr/bin/env sh
printf 'lint: 0 finding(s)\n'
exit 0
FAKE
chmod +x "$work/scope/fake-typelisp"
printf 'tests/integration/unique_scoped_lint.tl\n' > "$work/scope/unique-tl"
env -u GITHUB_ACTIONS TYPELISP_BIN="$work/scope/fake-typelisp" TYPELISP_CI_LOCAL_SCOPE_PATHS="$work/scope/unique-tl" \
    "$lint_repo/scripts/check-tl-lint.sh" > "$work/lint-scoped.out" 2>&1 ||
    fail 'the scoped tl-lint check failed on a non-src .tl file'
grep -F '[tl-lint] local changed-file scope: 1 of 1 file(s)' "$work/lint-scoped.out" > /dev/null ||
    fail 'the scoped tl-lint check did not report its local scope'
# Hosted CI fails closed on any local-only variable, before any gate starts.
for hosted in "$ROOT/scripts/ci-verify.sh --gates shared-view-count-ratchet" "$ROOT/scripts/check-shared-view-count.sh"; do
    for variable in TYPELISP_CI_LOCAL_CACHE TYPELISP_CI_LOCAL_SCOPE_PATHS TYPELISP_INTEGRATION_LOCAL_CHANGED_FILES; do
        status=0
        # shellcheck disable=SC2086
        env GITHUB_ACTIONS=true "$variable=$work/scope/docs-only" $hosted > "$work/hosted.out" 2> "$work/hosted.err" || status=$?
        [ "$status" = 2 ] || fail "hosted $hosted accepted $variable (exit $status)"
        grep -F 'local-only' "$work/hosted.err" > /dev/null || fail "hosted $hosted rejection lost its diagnostic"
    done
done

expect_rejected() {
    label=$1
    shift
    cp "$CI_AFFECTED_TEST_EXECUTIONS" "$work/rejected.before"
    status=0
    "$@" > "$work/$label.out" 2> "$work/$label.err" || status=$?
    [ "$status" -ne 0 ] || fail "$label was accepted"
    [ ! -s "$work/$label.out" ] || fail "$label emitted a successful plan before failing"
    cmp "$CI_AFFECTED_TEST_EXECUTIONS" "$work/rejected.before" || fail "$label executed a gate"
}
for name in TYPELISP_INLINE_TEST_WORKERS TYPELISP_BUILD_INVARIANCE_WORKERS TYPELISP_INTEGRATION_WORKERS TYPELISP_COMPILE_MANIFEST_WORKERS; do
    expect_rejected "empty-$name" env "$name=" "$fixture_selector" --base "$base" --run
    expect_rejected "zero-$name" env "$name=0" "$fixture_selector" --base "$base" --run
    expect_rejected "four-$name" env "$name=4" "$fixture_selector" --base "$base" --run
done
expect_rejected zero-jobs "$fixture_selector" --base "$base" --run --jobs 0
expect_rejected many-jobs "$fixture_selector" --base "$base" --run --jobs 17
expect_rejected word-jobs "$fixture_selector" --base "$base" --run --jobs two
expect_rejected zero-memory "$fixture_selector" --base "$base" --run --jobs 2 --memory-mib 0
expect_rejected small-memory "$fixture_selector" --base "$base" --run --jobs 2 --memory-mib 1
expect_rejected duplicate-jobs "$fixture_selector" --base "$base" --run --jobs 2 --jobs 2
for flag in '--jobs 2' '--memory-mib 16384' --no-cache --no-scope; do
    # shellcheck disable=SC2086
    expect_rejected "plan-only-${flag%% *}" "$fixture_selector" --base "$base" $flag
done
expect_rejected invalid-base "$fixture_selector" --base no-such-ref --run
expect_rejected invalid-tier "$fixture_selector" --base "$base" --tier invalid --run
expect_rejected paths-cannot-run "$fixture_selector" --paths "$work/empty.paths" --run
other_host=windows
[ "$native_host" != windows ] || other_host=linux
expect_rejected foreign-host "$fixture_selector" --base "$base" --host "$other_host" --run
status=0
CI_AFFECTED_TEST_EXIT=19 "$fixture_selector" --base "$base" --run --jobs 1 > "$work/exit.out" 2> "$work/exit.err" || status=$?
[ "$status" = 19 ] || fail "ci-verify failure not propagated: $status"

# Deletion must keep its old mapped path; renames must include both paths.
git -C "$repo" mv tests/safety/manifest.d/sample.manifest unknown.txt
"$fixture_selector" --base "$base" > "$work/renamed.ids" 2> "$work/renamed.log"
cmp "$work/renamed.ids" "$work/$native_host.full" || fail 'rename destination did not fail safe'
git -C "$repo" reset -q --hard "$base"
git -C "$repo" update-index --force-remove tests/safety/manifest.d/sample.manifest
mv "$repo/tests/safety/manifest.d/sample.manifest" "$work/deleted-manifest.txt"
"$fixture_selector" --base "$base" > "$work/deleted.ids" 2> "$work/deleted.log"
has_gate "$work/deleted.ids" stage2-safety-corpus
printf 'unknown\n' > "$repo/untracked file.txt"
"$fixture_selector" --base "$base" --run --jobs 1 > "$work/untracked.ids" 2> "$work/untracked.log"
cmp "$work/untracked.ids" "$work/$native_host.full" || fail 'untracked path did not select full table'
[ "$(wc -l < "$work/run.call")" -eq 8 ] || fail 'full run added a subset flag'
"$fixture_selector" --base "$base" --run --jobs 2 --memory-mib 16384 > /dev/null 2>&1
sed '1,8d' "$work/run.call" > "$work/full-parallel.args"
printf '%s\n' --jobs 2 --memory-mib 16384 > "$work/full-parallel.expected"
cmp "$work/full-parallel.args" "$work/full-parallel.expected" || fail 'a parallel full run added a subset flag'
mv "$repo/untracked file.txt" "$work/untracked-file.txt"
printf 'unknown\n' > "$repo/line
break.txt"
"$fixture_selector" --base "$base" > "$work/unusual.ids" 2> "$work/unusual.log"
cmp "$work/unusual.ids" "$work/$native_host.full" || fail 'unusual path did not fail safe'

# Base-only drift is excluded by merge-base; a ref/HEAD direct diff would
# incorrectly include the other branch edit and select the full table.
git -C "$repo" checkout -q -b other-base "$base"
printf 'base drift\n' > "$repo/base-only.txt"
git -C "$repo" add base-only.txt
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm drift
drift=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q --detach "$base"
# Use a clean tracked-only fixture for this assertion; earlier untracked
# artifacts remain in this repo, so move them to its task-owned evidence root.
mv "$repo/line
break.txt" "$work/newline-file.txt"
"$fixture_selector" --base "$drift" > "$work/drift.ids" 2> "$work/drift.log"
cmp "$work/drift.ids" "$work/empty.ids" || fail 'base-only drift entered selection'
printf 'unknown/path\tnot-a-real-gate\t-\tinvalid test row\n' >> "$repo/scripts/ci-affected-paths.d/tests-other.tsv"
expect_rejected invalid-map "$fixture_selector" --base "$base" --run
cp "$ROOT/scripts/ci-affected-paths.d/tests-other.tsv" "$repo/scripts/ci-affected-paths.d/tests-other.tsv"
printf 'path\trequired\tadvisory\treason\ntests/*\tstage2-safety-corpus\t-\tduplicate test row\n' > "$repo/scripts/ci-affected-paths.d/zz-dup.tsv"
expect_rejected duplicate-map "$fixture_selector" --base "$base"
rm -f "$repo/scripts/ci-affected-paths.d/zz-dup.tsv"
awk -F '\t' -v OFS='\t' '$1 == "tests/*" {$2 = ""} {print}' "$ROOT/scripts/ci-affected-paths.d/tests-other.tsv" > "$repo/scripts/ci-affected-paths.d/tests-other.tsv"
cp "$work/run.call" "$work/empty-map-before.call"
expect_rejected empty-gates "$fixture_selector" --base "$base" --run
cmp "$work/run.call" "$work/empty-map-before.call" || fail 'invalid map executed a gate'
cp "$ROOT/scripts/ci-affected-paths.d/tests-other.tsv" "$repo/scripts/ci-affected-paths.d/tests-other.tsv"
mv "$repo/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" "$work/held-gate.tsv"
printf '%s\n' src/compiler_backend.tl > "$work/paths"
"$fixture_selector" --paths "$work/paths" > "$work/unreviewed-gate.ids" 2> "$work/unreviewed-gate.log"
cmp "$work/unreviewed-gate.ids" "$work/$native_host.full" || fail 'unreviewed gate inventory did not fail to full'
mv "$work/held-gate.tsv" "$repo/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv"
awk -F '\t' -v OFS='\t' 'NR == 2 {$12 = "invalid-class"} {print}' "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" > "$repo/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv"
expect_rejected invalid-input-class "$fixture_selector" --base "$base"
cp "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" "$repo/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv"
printf 'tests/unmapped.dat\t-,-\t@corpus\tinvalid empty minimum\n' >> "$repo/scripts/ci-affected-paths.d/tests-other.tsv"
expect_rejected invalid-empty-minimum "$fixture_selector" --base "$base"
cp "$ROOT/scripts/ci-affected-paths.d/tests-other.tsv" "$repo/scripts/ci-affected-paths.d/tests-other.tsv"
printf '@@\tlinux\trequired\n' > "$work/malformed.batch"
expect_rejected malformed-batch "$fixture_selector" --batch "$work/malformed.batch"

# Fail-closed fragment-directory checks for ci-gates.d/ and ci-affected-paths.d/:
# filename stem != id, duplicate gate row/ID, dependency cycle, stray non-.tsv,
# symlink, nested entry, and deterministic Kahn (priority desc, id asc) order.
cp "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" "$repo/scripts/ci-gates.d/wrong-stem.tsv"
expect_rejected gates-stem-mismatch ci_gates_load "$repo/scripts/ci-gates.d"
rm -f "$repo/scripts/ci-gates.d/wrong-stem.tsv"
tail -n 1 "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" >> "$repo/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv"
expect_rejected gates-duplicate-row ci_gates_load "$repo/scripts/ci-gates.d"
cp "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" "$repo/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv"
printf 'stray\n' > "$repo/scripts/ci-gates.d/stray.txt"
expect_rejected gates-stray-file ci_gates_load "$repo/scripts/ci-gates.d"
rm -f "$repo/scripts/ci-gates.d/stray.txt"
printf 'stray\n' > "$repo/scripts/ci-affected-paths.d/stray.txt"
expect_rejected paths-stray-file ci_affected_paths_load "$repo/scripts/ci-affected-paths.d"
rm -f "$repo/scripts/ci-affected-paths.d/stray.txt"
mkdir -p "$repo/scripts/ci-gates.d/nested"
cp "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" "$repo/scripts/ci-gates.d/nested/bootstrap-adaptive-control-flow.tsv"
expect_rejected gates-nested-entry ci_gates_load "$repo/scripts/ci-gates.d"
rm -rf "$repo/scripts/ci-gates.d/nested"
if [ "$native_host" = linux ]; then
    ln -s "$ROOT/scripts/ci-gates.d/bootstrap-adaptive-control-flow.tsv" "$repo/scripts/ci-gates.d/link-gate.tsv"
    expect_rejected gates-symlink-entry ci_gates_load "$repo/scripts/ci-gates.d"
    rm -f "$repo/scripts/ci-gates.d/link-gate.tsv"
fi
mkdir -p "$work/cycle-gates"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ncyc-a\t100\tall\tcycle a\tcyc-b\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tcycle fixture\n' > "$work/cycle-gates/cyc-a.tsv"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ncyc-b\t90\tall\tcycle b\tcyc-a\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tcycle fixture\n' > "$work/cycle-gates/cyc-b.tsv"
expect_rejected gates-dependency-cycle ci_gates_load "$work/cycle-gates"
grep -F 'dependency cycle' "$work/gates-dependency-cycle.err" >/dev/null || fail 'cycle rejection lost its diagnostic'
mkdir -p "$work/dup-need-gates"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ng-a\t100\tall\tgate a\t-\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tdup need fixture\n' > "$work/dup-need-gates/g-a.tsv"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ng-b\t90\tall\tgate b\tg-a,g-a@linux\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tdup need fixture\n' > "$work/dup-need-gates/g-b.tsv"
expect_rejected gates-duplicate-effective-need ci_gates_load "$work/dup-need-gates"
grep -F 'duplicate linux need' "$work/gates-duplicate-effective-need.err" >/dev/null || fail 'duplicate effective-host need rejection lost its diagnostic'
mkdir -p "$work/kahn-gates"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ngate-b\t100\tall\tgate b\t-\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tkahn fixture\n' > "$work/kahn-gates/gate-b.tsv"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ngate-a\t100\tall\tgate a\t-\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tkahn fixture\n' > "$work/kahn-gates/gate-a.tsv"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ngate-high\t500\tall\tgate high\tgate-b\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tkahn fixture\n' > "$work/kahn-gates/gate-high.tsv"
printf 'id\tpriority\thosts\tlabel\tneeds\tcompiler\tmemory\tlocks\tcommand\tlinux_lane\twindows_lane\tinput_classes\tinput_reason\ngate-low\t50\tall\tgate low\t-\t-\t256\t-\ttrue\tlinux-1\twindows-1\t-\tkahn fixture\n' > "$work/kahn-gates/gate-low.tsv"
ci_gates_load "$work/kahn-gates" | cut -f 1 > "$work/kahn.actual" || fail 'kahn fixture load failed'
printf 'gate-a\ngate-b\ngate-high\ngate-low\n' > "$work/kahn.expected"
cmp "$work/kahn.actual" "$work/kahn.expected" || fail 'Kahn topological (priority desc, id asc) order mismatch'

# The fixture repository's .git must not block clean --experiments after
# success. Every failure exits above and retains its evidence.
rm -rf -- "${work:?}"
echo "ci-affected self-tests passed (Linux/Windows plans and checkout filters, three historical failed-run diffs, Git discovery, worker and job guards, local cache and scope, and execution)"
