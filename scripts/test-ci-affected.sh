#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/target/exp/ci-affected-test"
work=$(mktemp -d "$ROOT/target/exp/ci-affected-test/run.XXXXXX")
selector="$ROOT/scripts/ci-affected.sh"
TAB=$(printf '\t')
fail() { echo "ci-affected self-test: $* (evidence: $work)" >&2; exit 1; }
has_gate() { grep -Fx "$2" "$1" >/dev/null || fail "missing $2 in $1"; }
case "$work" in
    "$ROOT/target/exp/ci-affected-test/run."??????) ;;
    *) fail "unexpected self-test scratch directory" ;;
esac

# Exercise Git's actual Windows checkout filter, including the provenance
# table and byte-compared historical paths. Their LF attributes must win.
for path in scripts/ci-affected-paths.tsv scripts/ci-affected-inputs.tsv tests/fixtures/ci-affected/*.paths tests/fixtures/ci-affected/history.tsv; do
    git cat-file blob ":$path" > "$work/checkout.expected"
    git -c core.autocrlf=true cat-file --filters --path="$path" ":$path" > "$work/checkout.actual"
    cmp "$work/checkout.actual" "$work/checkout.expected" || fail "Windows checkout changed line endings: $path"
done

# Audit tracked literal inputs inside owning scripts, independently of the
# reviewed map. Synthetic self-test modes do not consume the real corpus.
git ls-files > "$work/tracked-inputs"
awk '{path=$0; while (sub(/\/[^/]*$/, "", path)) print path}' "$work/tracked-inputs" | sort -u > "$work/tracked-directories"
awk -F '\t' '
    {sub(/\r$/, "")}
    !/^#/ && $1 != "id" {
        command = $8
        while (match(command, /scripts\/[A-Za-z0-9_.-]+\.sh/)) {
            script = substr(command, RSTART, RLENGTH)
            command = substr(command, RSTART + RLENGTH)
            if (script == "scripts/verify-integration.sh" && $1 != "stage2-native-integration-corpus") continue
            if (script == "scripts/verify-cross-mode-differential.sh" && $1 != "stage2-cross-mode-semantic-abi-differential") continue
            print $1 "\t" script
        }
    }
' "$ROOT/scripts/ci-gates.tsv" > "$work/owning-scripts.tsv"
awk -F '\t' '
    {sub(/\r$/, "")}
    FILENAME == ARGV[1] { if ($8 ~ /^gate_[a-z0-9_]+$/) gate[$8] = $1; next }
    /^gate_[a-z0-9_]+\(\)/ { name = $1; sub(/\(\).*/, "", name) }
    /^}/ { name = "" }
    name in gate {
        line = $0
        while (match(line, /scripts\/[A-Za-z0-9_.-]+\.sh/)) {
            print gate[name] "\t" substr(line, RSTART, RLENGTH)
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" >> "$work/owning-scripts.tsv"
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
    grep -Fx "stage2-public-tool-surface$TAB""scripts/$script" "$work/recursive-scripts.tsv" >/dev/null || fail "nested guard not discovered: $script"
done
grep -Fx "stage2-stdlib-modules-and-fixtures$TAB"'scripts/check-stdlib-concat-lint.sh' "$work/recursive-scripts.tsv" >/dev/null || fail 'nested stdlib lint not discovered'
for gate in stage2-stdlib-documentation stage2-stdlib-modules-and-fixtures stage2-repository-doctests; do
    grep -Fx "stdlib$TAB$gate" "$work/script-inputs.tsv" >/dev/null || fail "whole-directory input not discovered: $gate"
done
awk -F '|' '$1 == "case" {print $3 "\tstage2-selfhost-compile-manifest"}' "$ROOT/src/compile_manifest.txt" >> "$work/script-inputs.tsv"

# Primary declarations add exact fixture owners. Imported/staged dependency
# lists and generic compiler-comparison suites remain advisory source classes.
awk -F '\t' '$1 ~ /\.cases$/ {print}' "$work/script-inputs.tsv" > "$work/inventory-owners.tsv"
awk -F '\t' '{sub(/\r$/, "")} !/^#/ && $1 != "id" {n=split($8, words, " "); for(i=1;i<=n;i++) if(words[i] ~ /^tests\/.*\.cases$/) print words[i] "\t" $1}' "$ROOT/scripts/ci-gates.tsv" >> "$work/inventory-owners.tsv"
for affected_inventory in tests/cli/public-*.cases; do printf '%s\tstage2-public-tool-surface\n' "$affected_inventory"; done >> "$work/inventory-owners.tsv"
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
    awk -F '|' '{sub(/\r$/, "")} !/^#/ && NF >= 4 {
        print $4 "\tstage2-native-integration-corpus"
        for(i=10;i<=NF;i++) if($i ~ /^suite-members:/) {
            members=substr($i,15); n=split(members,names," ")
            for(j=1;j<=n;j++) if(names[j] != "") print "src/tests/" names[j] "\tstage2-native-integration-corpus"
        }
    }' "$1/tests/integration/native.manifest" || return
    awk -F '|' '{sub(/\r$/, "")} !/^#/ && NF >= 3 {print $3 "\tstage2-safety-corpus"}' "$1/tests/safety/manifest.txt" || return
    awk -F '|' '{sub(/\r$/, "")} $1 == "case" {print $3 "\tstage2-selfhost-compile-manifest"}' "$1/src/compile_manifest.txt" || return
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
cat "$work/inventory-plans/inventories" > "$work/failure-inputs"
printf '%s\n' tests/integration/native.manifest tests/safety/manifest.txt src/compile_manifest.txt >> "$work/failure-inputs"
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
{ cut -f 1 "$work/inventory-owners.tsv"; printf '%s\n' tests/integration/native.manifest tests/safety/manifest.txt src/compile_manifest.txt; } | sort -u > "$work/inventory-files"
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
' "$ROOT/scripts/ci-affected-paths.tsv" "$work/tracked-directories" "$work/primary-inputs.tsv" || fail 'primary inventory ownership is incomplete'

for host in linux windows; do
    "$ROOT/scripts/ci-verify.sh" --list-gates "$host" > "$work/$host.table"
    sed '1d' "$work/$host.table" | cut -f 1 > "$work/$host.full"
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
        awk -F '\t' '!/^#/ && $1 != "id" && $5 != "-" {print $1}' "$ROOT/scripts/ci-gates.tsv" |
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
        sort "$work/required.ids" > "$work/required.sorted"
        sort "$work/trigger.ids" > "$work/advisory.sorted"
        comm -23 "$work/required.sorted" "$work/advisory.sorted" > "$work/missing-advisory.ids"
        [ ! -s "$work/missing-advisory.ids" ] || fail 'required tier is not included in advisory'
    done
    # Every literal corpus input in a canonical gate command has an owning
    # required trigger, independently of the advisory input classifications.
    awk -F '\t' '!/^#/ && $1 != "id" {n = split($8, words, " "); for (i = 1; i <= n; i++) if (words[i] ~ /^tests\/[A-Za-z0-9._\/-]+$/) print words[i] "\t" $1}' "$ROOT/scripts/ci-gates.tsv" > "$work/literal-inputs.tsv"
    while IFS=$TAB read -r path gate; do
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/literal.ids"
        has_gate "$work/literal.ids" "$gate"
    done < "$work/literal-inputs.tsv"
    while IFS=$TAB read -r path gate; do
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        path=${path%/}
        case "$path:$gate" in
            src/main.tl:*) continue ;; # Produced CLI workload: bootstrap plus advisory compiler consumers.
            src/sym_i64_env.tl:stage2-opt1-opt2-build-invariance) continue ;; # Staged supporting module, not a primary comparison fixture.
            src/compiler_embedded_stdlib_payload.tl:embedded-stdlib-tlci-bounded-resource-report | src/compiler_embedded_stdlib_payload.tl:embedded-stdlib-tlci-resource-verifier-self-tests | src/compiler_embedded_stdlib_payload.tl:embedded-stdlib-tlci-image | src/compiler_embedded_stdlib_payload.tl:stage2-compile-profile-verifier | src/compiler_embedded_stdlib_payload.tl:stage2-stdlib-modules-and-fixtures | src/compiler_embedded_stdlib_payload.tl:tlci-mutation-bootstrap-fixpoint) continue ;; # Nested image builder reads staged compiler support; payload's standalone guard remains required.
            stdlib/cpu.tl:stage2-spmd-runtime-dispatch | stdlib/cpu.tl:stage2-sde-fallback) continue ;; # Imported ISA-detector support; timestamp invalidates its artifact, no direct fixture contract.
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
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/direct-reader.ids"
        has_gate "$work/direct-reader.ids" "$gate"
    done < "$work/script-inputs.tsv"
    # Constructed script inputs and the reported independent source guards.
    for row in 'tests/spmd/package_callable/src/lib.tl package-native-tlci-dependency-macros' 'tests/spmd/package_consumer/src/main.tl package-native-tlci-dependency-macros' 'stdlib/tests/json_sequence_api.tl stage2-stdlib-selfhost-verifier' 'tests/integration/tail_call_stack_forward.tl stage2-regalloc-backend-asm-shape-gates' 'src/tests/compiler_typed_occurrence_smoke.tl stage2-native-integration-corpus' 'tests/safety/global_mut_borrow_deref_location_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_field_overlap_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_initializer_location_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_noncall_location_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_store_location_reject.tl stage2-public-tool-surface' 'tests/safety/mut_borrow_forwarded_diagnostic_location_reject.tl stage2-public-tool-surface' 'stdlib/json.tl stage2-docs-pages-build-path' 'stdlib/json.tl stage2-stdlib-documentation' 'stdlib/json.tl stage2-stdlib-modules-and-fixtures' 'stdlib/json.tl stage2-repository-doctests' 'src/build_cli_core.tl stage2-public-tool-surface' 'src/compiler_driver_core.tl stage2-public-tool-surface' 'src/compiler_lower.tl stage2-public-tool-surface' 'src/lsp_frame_core.tl stage2-public-tool-surface' 'src/main.tl cli-help-surface' 'src/compile_cli_core.tl cli-help-surface'; do
        path=${row% *}
        gate=${row##* }
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/direct-reader.ids"
        has_gate "$work/direct-reader.ids" "$gate"
    done
    for row in 'scripts/codegen-target-dispatch-inventory.tsv stage2-codegen-target-parity'; do
        path=${row% *}
        gate=${row##* }
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/subset.ids"
        "$ROOT/scripts/ci-verify.sh" --list-gates "$host" --gates "shared-view-count-ratchet,typelisp-source-formatting,typelisp-source-lint,stage2-repository-doctests,$gate" > "$work/subset.table"
        sed '1d' "$work/subset.table" | cut -f 1 > "$work/subset.expected"
        cmp "$work/subset.ids" "$work/subset.expected" || fail "wrong dependency closure: $path"
    done
    printf '%s\n' tests/safety/manifest.txt scripts/codegen-target-dispatch-inventory.tsv tests/safety/manifest.txt > "$work/paths"
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
    for path in scripts/ci-verify.sh .github/workflows/ci.yml tests/public-tools/example.sh tests/fixtures/ci-affected/history.tsv; do
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
mkdir -p "$repo/scripts" "$repo/tests/safety"
printf '/target/\n' > "$repo/.gitignore"
cp "$selector" "$ROOT/scripts/ci-affected-paths.tsv" "$ROOT/scripts/ci-affected-inputs.tsv" "$ROOT/scripts/ci-gates.tsv" "$repo/scripts/"
cat > "$repo/scripts/ci-verify.sh" <<'STUB'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --list-gates ]; then exec "$CI_AFFECTED_TEST_VERIFY" "$@"; fi
printf '%s\n' "$TYPELISP_INLINE_TEST_WORKERS" "$TYPELISP_BUILD_INVARIANCE_WORKERS" "$TYPELISP_INTEGRATION_WORKERS" "$TYPELISP_COMPILE_MANIFEST_WORKERS" "$@" > "$CI_AFFECTED_TEST_CALL"
printf 'run\n' >> "$CI_AFFECTED_TEST_EXECUTIONS"
exit "${CI_AFFECTED_TEST_EXIT:-0}"
STUB
chmod +x "$repo/scripts/ci-verify.sh"
export CI_AFFECTED_TEST_VERIFY="$ROOT/scripts/ci-verify.sh"
export CI_AFFECTED_TEST_CALL="$work/run.call"
export CI_AFFECTED_TEST_EXECUTIONS="$work/run.executions"
: > "$CI_AFFECTED_TEST_EXECUTIONS"
printf 'initial\n' > "$repo/tests/safety/manifest.txt"
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
printf 'unstaged\n' >> "$repo/tests/safety/manifest.txt"
"$fixture_selector" --base "$base" > "$work/unstaged.ids" 2> "$work/unstaged.log"
has_gate "$work/unstaged.ids" stage2-safety-corpus
git -C "$repo" add tests/safety/manifest.txt
"$fixture_selector" --base "$base" > "$work/staged.ids" 2> "$work/staged.log"
cmp "$work/staged.ids" "$work/unstaged.ids" || fail 'staged edit missed'
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm edit
"$fixture_selector" --base "$base" > "$work/committed.ids" 2> "$work/committed.log"
cmp "$work/staged.ids" "$work/committed.ids" || fail 'committed edit missed'

case "$(uname -s)" in Linux*) native_host=linux ;; *) native_host=windows ;; esac
env -u TYPELISP_INLINE_TEST_WORKERS -u TYPELISP_BUILD_INVARIANCE_WORKERS -u TYPELISP_INTEGRATION_WORKERS -u TYPELISP_COMPILE_MANIFEST_WORKERS "$fixture_selector" --base "$base" --run > "$work/run.ids" 2> "$work/run.log"
sed -n '1,4p' "$work/run.call" > "$work/workers.actual"
printf '1\n1\n1\n1\n' > "$work/workers.expected"
cmp "$work/workers.actual" "$work/workers.expected" || fail 'worker defaults were not exported as 1'
sed -n '5p' "$work/run.call" | grep -Fx -- --gates >/dev/null || fail 'subset was not passed to ci-verify'
tr '\n' ',' < "$work/committed.ids" | sed 's/,$//' > "$work/run.expected-csv"
sed -n '6p' "$work/run.call" | tr -d '\n' > "$work/run.actual-csv"
cmp "$work/run.actual-csv" "$work/run.expected-csv" || fail 'executed selection differs from printed selection'

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
expect_rejected inline-workers env TYPELISP_INLINE_TEST_WORKERS=2 "$fixture_selector" --base "$base" --run
expect_rejected invariance-workers env TYPELISP_BUILD_INVARIANCE_WORKERS=2 "$fixture_selector" --base "$base" --run
expect_rejected integration-workers env TYPELISP_INTEGRATION_WORKERS=2 "$fixture_selector" --base "$base" --run
expect_rejected manifest-workers env TYPELISP_COMPILE_MANIFEST_WORKERS=2 "$fixture_selector" --base "$base" --run
for name in TYPELISP_INLINE_TEST_WORKERS TYPELISP_BUILD_INVARIANCE_WORKERS TYPELISP_INTEGRATION_WORKERS TYPELISP_COMPILE_MANIFEST_WORKERS; do
    expect_rejected "empty-$name" env "$name=" "$fixture_selector" --base "$base" --run
    expect_rejected "three-$name" env "$name=3" "$fixture_selector" --base "$base" --run
done
expect_rejected invalid-base "$fixture_selector" --base no-such-ref --run
expect_rejected invalid-tier "$fixture_selector" --base "$base" --tier invalid --run
expect_rejected paths-cannot-run "$fixture_selector" --paths "$work/empty.paths" --run
other_host=windows
[ "$native_host" != windows ] || other_host=linux
expect_rejected foreign-host "$fixture_selector" --base "$base" --host "$other_host" --run
status=0
CI_AFFECTED_TEST_EXIT=19 "$fixture_selector" --base "$base" --run > "$work/exit.out" 2> "$work/exit.err" || status=$?
[ "$status" = 19 ] || fail "ci-verify failure not propagated: $status"

# Deletion must keep its old mapped path; renames must include both paths.
git -C "$repo" mv tests/safety/manifest.txt unknown.txt
"$fixture_selector" --base "$base" > "$work/renamed.ids" 2> "$work/renamed.log"
cmp "$work/renamed.ids" "$work/$native_host.full" || fail 'rename destination did not fail safe'
git -C "$repo" reset -q --hard "$base"
git -C "$repo" update-index --force-remove tests/safety/manifest.txt
mv "$repo/tests/safety/manifest.txt" "$work/deleted-manifest.txt"
"$fixture_selector" --base "$base" > "$work/deleted.ids" 2> "$work/deleted.log"
has_gate "$work/deleted.ids" stage2-safety-corpus
printf 'unknown\n' > "$repo/untracked file.txt"
"$fixture_selector" --base "$base" --run > "$work/untracked.ids" 2> "$work/untracked.log"
cmp "$work/untracked.ids" "$work/$native_host.full" || fail 'untracked path did not select full table'
[ "$(wc -l < "$work/run.call")" -eq 4 ] || fail 'full run added a subset flag'
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
printf 'unknown/path\tnot-a-real-gate\t-\tinvalid test row\n' >> "$repo/scripts/ci-affected-paths.tsv"
expect_rejected invalid-map "$fixture_selector" --base "$base" --run
cp "$ROOT/scripts/ci-affected-paths.tsv" "$repo/scripts/ci-affected-paths.tsv"
printf 'tests/*\tstage2-safety-corpus\t-\tduplicate test row\n' >> "$repo/scripts/ci-affected-paths.tsv"
expect_rejected duplicate-map "$fixture_selector" --base "$base"
awk -F '\t' -v OFS='\t' '$1 == "tests/*" {$2 = ""} {print}' "$ROOT/scripts/ci-affected-paths.tsv" > "$repo/scripts/ci-affected-paths.tsv"
cp "$work/run.call" "$work/empty-map-before.call"
expect_rejected empty-gates "$fixture_selector" --base "$base" --run
cmp "$work/run.call" "$work/empty-map-before.call" || fail 'invalid map executed a gate'
cp "$ROOT/scripts/ci-affected-paths.tsv" "$repo/scripts/ci-affected-paths.tsv"
sed '$d' "$ROOT/scripts/ci-affected-inputs.tsv" > "$repo/scripts/ci-affected-inputs.tsv"
printf '%s\n' src/compiler_backend.tl > "$work/paths"
"$fixture_selector" --paths "$work/paths" > "$work/unreviewed-gate.ids" 2> "$work/unreviewed-gate.log"
cmp "$work/unreviewed-gate.ids" "$work/$native_host.full" || fail 'unreviewed gate inventory did not fail to full'
cp "$ROOT/scripts/ci-affected-inputs.tsv" "$repo/scripts/ci-affected-inputs.tsv"
printf 'bad-gate\tinvalid-class\tinvalid fixture\n' >> "$repo/scripts/ci-affected-inputs.tsv"
expect_rejected invalid-input-class "$fixture_selector" --base "$base"
cp "$ROOT/scripts/ci-affected-inputs.tsv" "$repo/scripts/ci-affected-inputs.tsv"
printf 'tests/unmapped.dat\t-,-\t@corpus\tinvalid empty minimum\n' >> "$repo/scripts/ci-affected-paths.tsv"
expect_rejected invalid-empty-minimum "$fixture_selector" --base "$base"

# The fixture repository's .git must not block clean --experiments after
# success. Every failure exits above and retains its evidence.
rm -rf -- "${work:?}"
echo "ci-affected self-tests passed (Linux/Windows plans and checkout filters, three historical failed-run diffs, Git discovery, worker guards and execution)"
