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

# Owning scripts are the inventory for fixtures they construct in shell loops.
# Supported boundary: after sh quote removal, a path word under src, tests,
# stdlib or docs that expands $NAME or ${NAME}. It is relative to the root or
# $ROOT, or under a reviewed prefix: a root alias is audited the same way,
# scratch is skipped and any other prefix fails. A reference resolves only
# inside a "for NAME in WORD..." loop of that name, when every list for the name
# is literal, no other bare word names it, and only pure words run between the
# loop's do and the reference: keywords, nested literal headers and assignments
# without arithmetic or assigning expansions. The closed whitelist also leaves
# the whole script unresolved when it or a sourced script has eval, let, alias,
# a read/getopts/mapfile/readarray/declare/typeset/export/local/readonly/trap
# with an expansion, printf -v, an expanded arithmetic assignment, a computed
# source, an unbalanced loop or a for header meeting a command before its do.
# Each resolved expansion is a primary contract; search roots and outputs stay
# supporting. Anything unresolved is a family: every tracked file it can name
# must select the gate on each host.
constructed_inputs() {
    awk -F '\t' '
        function load(script,    line, status, physical, pending, joined, rest, offset, at, before, word, heads, tails, arith) {
            lines = 0; physical = 0; pending = 0; heads = 0; tails = 0; quote = ""; arith = 0
            while ((status = getline line < script) > 0) {
                sub(/\r$/, "", line)
                physical++
                if (heads < tails) {
                    # Heredoc text is data: it is scanned but holds no commands.
                    word = line
                    if (tabbed[heads + 1]) sub(/^\t+/, "", word)
                    if (word == delimiter[heads + 1]) heads++
                    else { text[++lines] = line; start[lines] = physical; body[lines] = 1; literal_body[lines] = quoted_delimiter[heads + 1] }
                    continue
                }
                if (pending) line = joined line
                else if (quote == "" && line ~ /^[[:space:]]*#/) continue
                else start[lines + 1] = physical
                if (line ~ /\\$/) { sub(/\\$/, "", line); joined = line; pending = 1; continue }
                pending = 0
                text[++lines] = line; body[lines] = 0; quote_at[lines] = quote; view[lines] = mask(line)
                # Heredoc operators are code: quoted or commented << opens nothing,
                # nor does an arithmetic shift, even one spanning lines.
                rest = view[lines]; offset = 0
                while (match(rest, /<<-?[[:space:]]*/)) {
                    at = offset + RSTART
                    offset += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
                    if ((at > 1 && substr(view[lines], at - 1, 1) == "<") || substr(view[lines], at + 2, 1) == "<") continue
                    before = substr(view[lines], 1, at - 1)
                    if (arith + gsub(/\(\(/, "", before) - gsub(/\)\)/, "", before) > 0) continue
                    if (!match(rest, /^[^[:space:];|&<>()]+/)) continue
                    word = normal(substr(line, offset + 1, RLENGTH))
                    offset += RLENGTH; rest = substr(rest, RLENGTH + 1)
                    quoted_delimiter[tails + 1] = (substr(line, offset + 1 - RLENGTH, RLENGTH) ~ /["\047\\]/)
                    tabbed[++tails] = (substr(view[lines], at, 3) == "<<-")
                    delimiter[tails] = word
                }
                before = view[lines]
                arith += gsub(/\(\(/, "", before) - gsub(/\)\)/, "", before)
                if (arith < 0) arith = 0
            }
            if (status < 0) { print "cannot read owning script: " script > "/dev/stderr"; exit 1 }
            close(script)
            if (heads < tails) { print "unterminated heredoc in owning script: " script > "/dev/stderr"; exit 1 }
        }
        function mask(line,    i, n, character, out) {
            # Keep positions; quoted or escaped text and inline comments are not code.
            out = ""; n = length(line)
            for (i = 1; i <= n; i++) {
                character = substr(line, i, 1)
                if (quote == "\047") { if (character == quote) { quote = ""; out = out character } else out = out "x"; continue }
                if (character == "\\" && i < n) { out = out "xx"; i++; continue }
                if (quote == "\"") { if (character == quote) { quote = ""; out = out character } else out = out "x"; continue }
                if (character == "\"" || character == "\047") { quote = character; out = out character; continue }
                if (character == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];&|()]/)) {
                    out = out sprintf("%" (n - i + 1) "s", ""); break
                }
                out = out character
            }
            return out
        }
        function blank(line, pattern,    out) {
            out = ""
            while (match(line, pattern)) {
                out = out substr(line, 1, RSTART - 1) sprintf("%" RLENGTH "s", "")
                line = substr(line, RSTART + RLENGTH)
            }
            return out line
        }
        function normal(value) { gsub(/["\047\\]/, "", value); return value }
        # The end of the simple command whose words start at from, in the code view.
        function extent(view, from,    j, character) {
            for (j = from; j <= length(view); j++) {
                character = substr(view, j, 1)
                if (character ~ /[;|()]/) return j
                if (character == "&" && substr(view, j - 1, 1) !~ /[<>]/) return j
            }
            return j
        }
        # An unquoted glob word in a literal list names every matching file.
        function globs(i, view, from, size,    rest, offset, at, width, path, prefix, t) {
            rest = substr(view, from, size); offset = from - 1
            while (match(rest, /[^[:space:]]+/)) {
                at = offset + RSTART; width = RLENGTH
                offset += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
                if (substr(view, at, width) !~ /[*?[]/) continue
                path = normal(substr(text[i], at, width)); prefix = ""
                sub(/^\.\//, "", path)
                if (match(path, /^\$(ROOT|\{ROOT([:?=+-][^}]*)?\})\//)) path = substr(path, RLENGTH + 1)
                else if (match(path, /^\$(\{[A-Za-z_][A-Za-z0-9_]*[^}]*\}|[A-Za-z_][A-Za-z0-9_]*)\//)) { prefix = substr(path, 1, RLENGTH); path = substr(path, RLENGTH + 1) }
                sub(/[()`;|&<>].*$/, "", path)
                if (path !~ /^(src|tests|stdlib|docs)\// || path ~ /\$/) continue
                t = ++tokens; token_site[t] = start[i]; token_prefix[t] = prefix; token_segments[t] = 0; token_glob[t] = path
            }
        }
        # The closing ] of a bracket expression starting at i, or 0 when unmatched.
        function bracket_end(value, i,    j, n, ending) {
            n = length(value); j = i + 1
            if (substr(value, j, 1) ~ /[!^]/) j++
            if (substr(value, j, 1) == "]") j++
            for (; j <= n; j++) {
                if (substr(value, j, 1) == "[" && substr(value, j + 1, 1) ~ /[:.=]/) {
                    ending = index(substr(value, j + 2), substr(value, j + 1, 1) "]")
                    if (ending) { j += ending + 2; continue }
                }
                if (substr(value, j, 1) == "]") return j
            }
            return 0
        }
        function glob_pattern(path,    out, i, ending, character) {
            out = "^"
            for (i = 1; i <= length(path); i++) {
                character = substr(path, i, 1)
                if (character == "*") out = out "[^/]*"
                else if (character == "?") out = out "[^/]"
                else if (character == "[" && (ending = bracket_end(path, i))) { out = out "[^/]"; i = ending }
                else if (character ~ /[.+(){}|^$\\[]/) out = out "\\" character
                else out = out character
            }
            return out "$"
        }
        function add_event(i, at, what, value) { event[i, ++events[i]] = at; kind[i, events[i]] = what; data[i, events[i]] = value }
        # Shell words of one logical line in order. A word at a command position
        # is classified on its quote-removed text: loop keywords become events,
        # every real command is an impure event, and the closed whitelist marks
        # binding-capable forms that leave the whole script unresolved.
        function commands(i, view, main,    rest, offset, at, width, raw, word, state, args, count, words, j, value, literal, values, name, from, list) {
            rest = view; offset = 0; state = 1
            while (match(rest, /[^[:space:];&|()<>]+|[;&|()<>]+/)) {
                at = offset + RSTART; width = RLENGTH
                offset += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
                raw = substr(view, at, width)
                if (raw ~ /^[;&|()<>]+$/) {
                    # A redirection names a target word, not a command.
                    if (raw !~ /[;|()]/ && raw ~ /[<>]/) {
                        if (match(rest, /^[[:space:]]*[^[:space:];&|()<>]+/)) { offset += RLENGTH; rest = substr(rest, RLENGTH + 1) }
                        continue
                    }
                    state = 1; continue
                }
                if (!state) continue
                word = normal(substr(text[i], at, width))
                if (word ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) {
                    # An assignment keeps the command position and is pure unless
                    # its value has an arithmetic or assigning expansion.
                    if (main) add_event(i, at, "command", (word ~ /\$\(\(|\$\{[^}]*=/) ? 1 : 0)
                    continue
                }
                if (word ~ /^(if|then|else|elif|while|until|!|time|\{)$/) continue
                if (word == "do") { if (main) add_event(i, at, "do", 0); continue }
                if (word ~ /^(done|fi|esac|\})$/) { if (main && word == "done") add_event(i, at, "done", 0); state = 0; continue }
                if (word == "case") { state = 0; continue }
                if (word == "command" || word == "builtin") {
                    # A wrapper runs the next word; command -v and -V only query.
                    if (match(rest, /^[[:space:]]+-p([[:space:]]|$)/)) { offset += RLENGTH - 1; rest = substr(rest, RLENGTH) }
                    if (rest ~ /^[[:space:]]+-[A-Za-z]*[vV]/) { if (main) add_event(i, at, "command", 1); state = 0 }
                    continue
                }
                if (word == "for") {
                    state = 0
                    if (!main) continue
                    if (!match(substr(view, at), /^for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) { unreliable = 1; continue }
                    name = substr(view, at, RLENGTH); sub(/^for[[:space:]]+/, "", name)
                    headers[name]++
                    from = at + RLENGTH; literal = 0; values = ""
                    if (match(substr(view, from), /^[[:space:]]+in([[:space:]]|;|$)/)) {
                        from += RLENGTH; literal = 1
                        list = substr(view, from)
                        list = substr(text[i], from, match(list, /;/) ? RSTART - 1 : length(list))
                        count = split(list, words, /[[:space:]]+/)
                        for (j = 1; j <= count; j++) {
                            value = words[j]
                            if (value ~ /^"[^"]*"$/ || value ~ /^\047[^\047]*\047$/) value = substr(value, 2, length(value) - 2)
                            if (value ~ /^[A-Za-z0-9_.\/+-]+$/) {
                                values = values " " value
                                if (!((name, value) in listed)) { listed[name, value] = 1; union[name] = union[name] " " value }
                            } else if (value != "") literal = 0
                        }
                        globs(i, view, from, length(list))
                        offset = from + length(list) - 1; rest = substr(view, offset + 1)
                    } else { state = 1; offset = from - 1; rest = substr(view, from) } # for NAME do, or for NAME; do
                    add_event(i, at, "for", ++blocks)
                    block_name[blocks] = name; block_literal[blocks] = literal; block_values[blocks] = values
                    if (!literal) open_list[name] = 1
                    continue
                }
                # Every real command, computed command names included, is impure.
                state = 0
                if (main) add_event(i, at, "command", 1)
                args = normal(substr(text[i], at + width, extent(view, at + width) - at - width))
                gsub(/[0-9]*[<>]+&?[[:space:]]*[^[:space:]]*/, " ", args)
                gsub(/\$[?#$!]/, "", args)
                if (word ~ /^(eval|let|alias)$/) unreliable = 1
                else if (word ~ /^(read|getopts|mapfile|readarray|declare|typeset|export|local|readonly|trap)$/ && args ~ /[$`]/) unreliable = 1
                else if (word == "printf" && args ~ /(^|[[:space:]])-v/) unreliable = 1
                else if (word == "." || word == "source") {
                    count = split(args, words, /[[:space:]]+/)
                    value = (words[1] == "" ? words[2] : words[1])
                    sub(/^\$(ROOT|\{ROOT\})\//, "", value)
                    if (value ~ /^(\/|scripts\/)[A-Za-z0-9_.\/-]+\.sh$/) { if (!(value in sourced)) { sourced[value] = 1; queue[++queued] = value } }
                    else unreliable = 1
                }
            }
        }
        # An arithmetic assignment whose target is an expansion may bind any name.
        function arithmetic(    i, all, code, source, at, region, closing) {
            # $(( )) expands inside double quotes too, so search the quote-removed
            # text; an (( )) command is code, so search the view and read the
            # same span of the original line.
            all = ""; code = ""; source = ""
            for (i = 1; i <= lines; i++) {
                all = all normal(text[i]) "\n"
                code = code (body[i] ? sprintf("%" length(text[i]) "s", "") : view[i]) "\n"
                source = source text[i] "\n"
            }
            while ((at = index(all, "$((")) > 0) {
                all = substr(all, at + 3); closing = index(all, "))")
                region = (closing ? substr(all, 1, closing - 1) : all)
                if (assigning(region)) unreliable = 1
            }
            while ((at = index(code, "((")) > 0) {
                code = substr(code, at + 2); source = substr(source, at + 2); closing = index(code, "))")
                region = normal(closing ? substr(source, 1, closing - 1) : source)
                if (assigning(region)) unreliable = 1
            }
        }
        function assigning(region,    shifted) {
            if (region !~ /[$`]/) return 0 # Literal targets are bare words.
            shifted = (region ~ /<<=|>>=/)
            gsub(/[=!<>]=/, "", region)
            return shifted || region ~ /=/ || region ~ /\+\+|--/
        }
        function bare(name,    i, line, from, at, previous, following, total) {
            total = 0
            for (i = 1; i <= lines; i++) {
                line = normal(text[i]); from = 1
                while ((at = index(substr(line, from), name)) > 0) {
                    at += from - 1; from = at + length(name)
                    previous = (at > 1 ? substr(line, at - 1, 1) : "")
                    following = substr(line, from, 2)
                    # Expansions read the name; ${NAME=...} and ${NAME:=...} assign it.
                    if (previous == "$" || (at > 3 && substr(line, at - 3, 3) == "${#")) continue
                    if (at > 2 && substr(line, at - 2, 2) == "${") { if (following ~ /^(=|:=)/) total++; continue }
                    # Inside a longer word or path it is not the name. Every other
                    # occurrence may bind it, whatever the delimiter: read targets,
                    # assignments, arithmetic such as $((1?n=2:0)) or $((n--)).
                    if (previous ~ /[A-Za-z0-9_]/ || following ~ /^[A-Za-z0-9_]/) continue
                    if (previous ~ /[.\/-]/ && substr(line, at - 2, 2) != "--") continue
                    if (following ~ /^[.\/-]/ && following !~ /^(--|-=|\/=)/) continue
                    total++
                }
            }
            return total
        }
        # Replay loop events in order. A command counts once the next one starts,
        # so a use inside a command never sees that command as having run.
        function commit() { effects += staged; staged = 0 }
        function apply(i, k,    what) {
            what = kind[i, k]
            if (what == "for") { if (pending) unreliable = 1; commit(); pending = data[i, k] }
            else if (what == "command") { if (pending) unreliable = 1; commit(); staged = data[i, k] }
            else if (what == "do") { commit(); stack[++depth] = pending; stacked[depth] = effects; pending = 0 }
            else { commit(); if (depth > 0) depth--; else unreliable = 1 }
        }
        function innermost(name,    d) {
            for (d = depth; d > 0; d--) if (stack[d] && block_name[stack[d]] == name) return d
            return 0
        }
        function process(script,    i, k, t, s, q, d, e, plain, quoting, position, tail, before, prefix, character, name, segments, found, pattern, part, template, expanded, count, items, values, n, m, j, resolved) {
            load(script)
            split("", headers); split("", sourced); split("", unbound); split("", union); split("", listed); split("", open_list)
            blocks = 0; queued = 0; unreliable = 0; tokens = 0; depth = 0; pending = 0; effects = 0; staged = 0
            for (i = 1; i <= lines; i++) {
                events[i] = 0
                if (!body[i]) commands(i, view[i], 1)
                k = 1
                if (index(text[i], "$")) {
                    # Constructed paths are found after quote removal, as sh joins
                    # words. A $ that sh keeps literal (single-quoted or escaped)
                    # becomes \001, and text of a quoted heredoc never resolves.
                    plain = ""; n = length(text[i]); quoting = (body[i] ? "" : quote_at[i])
                    for (q = 1; q <= n; q++) {
                        character = substr(text[i], q, 1)
                        if (quoting == "\047") { if (character == "\047") { quoting = ""; continue } if (character == "$") character = "\001" }
                        else if (character == "\\" && q < n) { q++; character = substr(text[i], q, 1); if (character == "$") character = "\001" }
                        else if (!body[i] && character == "\"") { quoting = (quoting == "\"" ? "" : "\""); continue }
                        else if (!body[i] && character == "\047" && quoting == "") { quoting = "\047"; continue }
                        plain = plain character; origin[length(plain)] = q
                    }
                    plain = blank(blank(plain, "--stdlib-root[[:space:]]+[^[:space:]]+"), "(^|[[:space:]])(-o|--output|--out-dir)[[:space:]]+[^[:space:]]+")
                    position = 1
                    while (match(substr(plain, position), /(src|tests|stdlib|docs)\/([A-Za-z0-9_.\/*?:!^-]|\[|\])*\$/)) {
                        position += RSTART - 1
                        while (k <= events[i] && event[i, k] < origin[position]) apply(i, k++)
                        before = substr(plain, 1, position - 1); gsub(/["\047]/, "", before)
                        prefix = ""
                        if (before != "" && before !~ /[[:space:]=(:;,|&<>]$/ && before !~ /\$(ROOT|\{ROOT([:?=+-][^}]*)?\})\/$/ && match(before, /[^[:space:]=(;|&<>]+$/))
                            prefix = substr(before, RSTART, RLENGTH)
                        tail = substr(plain, position)
                        t = ++tokens; token_site[t] = start[i]; token_prefix[t] = prefix; token_glob[t] = ""; token_data[t] = (body[i] && literal_body[i])
                        segments = 0; token_literal[t, 0] = ""; q = 1
                        while (q <= length(tail)) {
                            character = substr(tail, q, 1)
                            if (character ~ /[A-Za-z0-9_.\/-]/) { token_literal[t, segments] = token_literal[t, segments] character; q++; continue }
                            if (character == "*" || character == "?" || character == "[") { # A glob is a wildcard segment.
                                if (character == "[" && bracket_end(tail, q)) q = bracket_end(tail, q)
                                q++; token_reference[t, ++segments] = "*"; token_literal[t, segments] = ""; token_block[t, segments] = 0
                                continue
                            }
                            if (character != "$") break
                            name = ""
                            if (match(substr(tail, q), /^\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) { name = substr(tail, q + 2, RLENGTH - 3); q += RLENGTH }
                            else if (match(substr(tail, q), /^\$[A-Za-z_][A-Za-z0-9_]*/)) { name = substr(tail, q + 1, RLENGTH - 1); q += RLENGTH }
                            else if (substr(tail, q + 1, 1) ~ /[0-9$@*#?!-]/) q += 2
                            else q = length(tail) + 1 # Command substitution or operator expansion.
                            token_reference[t, ++segments] = name; token_literal[t, segments] = ""
                            d = (name == "" ? 0 : innermost(name))
                            # Resolved only when nothing impure ran since that loop began.
                            token_block[t, segments] = (d && stacked[d] == effects ? stack[d] : 0)
                        }
                        token_segments[t] = segments
                        position += q - 1
                    }
                }
                while (k <= events[i]) apply(i, k++)
                commit()
            }
            if (depth || pending) unreliable = 1
            arithmetic()
            for (name in headers) unbound[name] = bare(name)
            # Sourced scripts can bind names too; read them with the same rules.
            for (e = 1; e <= queued; e++) {
                load(queue[e])
                for (i = 1; i <= lines; i++) { events[i] = 0; if (!body[i]) commands(i, view[i], 0) }
                arithmetic()
                for (name in headers) unbound[name] += bare(name)
            }
            for (name in headers) unbound[name] = (unbound[name] != headers[name])
            found = ""
            for (t = 1; t <= tokens; t++) {
                segments = token_segments[t]
                template = token_literal[t, 0]; part = token_literal[t, 0]; gsub(/\./, "\\.", part); pattern = "^" part
                resolved = !unreliable
                if (token_glob[t] != "") { template = token_glob[t]; pattern = glob_pattern(template); sub(/\$$/, "", pattern); resolved = 0 }
                if (token_data[t]) resolved = 0
                for (s = 1; s <= segments; s++) {
                    name = token_reference[t, s]
                    template = template (name == "*" ? "*" : "${" (name == "" ? "?" : name) "}") token_literal[t, s]
                    part = token_literal[t, s]; gsub(/\./, "\\.", part); pattern = pattern ".*" part
                    if (name == "" || !token_block[t, s] || (name in open_list) || unbound[name]) resolved = 0
                }
                prefix = token_prefix[t]
                if (prefix != "") {
                    used[script, prefix] = 1
                    if (reviewed[script, prefix] == "scratch") continue
                    if (reviewed[script, prefix] != "root") { found = found "prefixed\t" prefix "\t" script ":" token_site[t] "\t" template "\n"; continue }
                }
                if (!resolved) { found = found "family\t" pattern "$\t" script ":" token_site[t] "\t" template "\n"; continue }
                expanded = token_literal[t, 0]
                for (s = 1; s <= segments; s++) {
                    count = split(expanded, items, "\n"); n = split(union[token_reference[t, s]], values, " ")
                    expanded = ""
                    for (m = 1; m <= count; m++) for (j = 1; j <= n; j++) expanded = expanded (expanded == "" ? "" : "\n") items[m] values[j] token_literal[t, s]
                }
                count = split(expanded, items, "\n")
                for (m = 1; m <= count; m++) found = found "member\t" items[m] "\t" script ":" token_site[t] "\t" template "\n"
            }
            return found
        }
        FILENAME == ARGV[2] { reviewed[$1, $2] = $3; next }
        { gate[++pairs] = $1; owner[pairs] = $2 }
        END {
            for (p = 1; p <= pairs; p++) {
                if (!(owner[p] in contracts)) contracts[owner[p]] = process(owner[p])
                count = split(contracts[owner[p]], rows, "\n")
                for (r = 1; r <= count; r++) if (rows[r] != "") {
                    split(rows[r], fields, "\t")
                    print fields[1] "\t" fields[2] "\t" gate[p] "\t" fields[3] "\t" fields[4]
                }
            }
            for (key in reviewed) if (!(key in used)) { split(key, fields, SUBSEP); print "unused\t" fields[2] "\t-\t" fields[1] "\t-" }
        }
    ' "$1" "$2"
}
# Prefixed paths need a reviewed class, and every reviewed prefix still occurs.
constructed_prefix_gaps() {
    awk -F '\t' '
        $1 == "prefixed" { print "constructed path under an unreviewed prefix: " $4 " " $2 $5 " -> " $3 > "/dev/stderr"; failed = 1 }
        $1 == "unused" { print "reviewed constructed prefix no longer occurs: " $4 " " $2 > "/dev/stderr"; failed = 1 }
        END { exit failed }
    ' "$1"
}
# Group the tracked files each family can name by the map rows that match them.
# Unmapped files select the full table and a direct owner needs no replay; one
# member per remaining row set is replayed through the real planner per host.
constructed_family_members() {
    awk -F '\t' '
        FILENAME == ARGV[1] {
            if (/^#/ || $1 == "path" || $2 == "-" || $1 == "@always") next
            pattern=$1; gsub(/\./, "\\.", pattern); gsub(/\*/, ".*", pattern)
            patterns[++rows]="^" pattern "$"; gates[rows]="," $2 ","
            next
        }
        FILENAME == ARGV[2] {tracked[++files]=$0; next}
        {
            for (f = 1; f <= files; f++) if (tracked[f] ~ $1) {
                path = tracked[f]
                if (!(path in signature)) {
                    signature[path] = ""; owners[path] = ""
                    for (i = 1; i <= rows; i++) if (path ~ patterns[i]) { signature[path] = signature[path] " " i; owners[path] = owners[path] gates[i] }
                }
                if (signature[path] == "" || index(owners[path], ",*,") || index(owners[path], "," $2 ",")) continue
                if (seen[FNR, signature[path]]++ || replayed[path, $2]++) continue
                print path "\t" $2 "\t" $3 "\t" $4
            }
        }
    ' "$@"
}
# Check every declared edge without thousands of recursive planner calls.
# Allowed map globs contain only literal characters, dots and stars, so this
# matches the selector case patterns. The witnesses below also replay plans.
check_primary_owners() {
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
                print "missing required primary owner: " $1 " -> " $2 ($3 == "" ? "" : " (constructed at " $3 ")") > "/dev/stderr"
                failed=1
            }
        }
        END {exit failed}
    ' "$@"
}
# Pin the boundary on synthetic scripts and a map, independent of today's lists.
mkdir -p "$work/constructed-probe"
cat > "$work/constructed-probe/owner.sh" <<'OWNER'
# for skipped in "tests/integration/$skipped.tl"; do
for fixture in alpha \
    'beta'; do
    compile "$ROOT/tests/integ\
ration/$fixture.tl" --stdlib-root "$ROOT/tests/$fixture" -o "tests/out/$fixture.s" "$WORK/src/$fixture.tl"
done
for fixture in alpha; do for named in gamma; do compile "stdlib/$fixture/$named-source" "$WORK/x-named-y"; done; done
compile "tests/integration/$fixture.tl"
for loose in $LOOSE; do compile "tests/integration/${loose}_case.tl"; done
for quoted in gamma; do printf 'delta\n' | while read -r 'quoted'; do compile "${ROOT}"'/tests/integration/'"$quoted".tl; done; done
for split in gamma; do read -r spl""it; compile "tests/integration/$split.tl"; done
echo ignored # for commented in alpha; do cat <<IGNORED
printf '%s\n' 'Example: for prose in alpha; do'
cat <<'SCRIPT' > "$WORK/generated.sh"
for embedded in alpha; do compile "tests/integration/$embedded.tl"; done
SCRIPT
compile "tests/integration/$commented.tl" "tests/integration/$prose.tl" "tests/integration/$embedded.tl" "stdlib/$$.tl"
for defaulted in alpha; do : "${defaulted:=beta}"; compile "${ROOT:?}/tests/integration/$defaulted.tl"; done
for positional; do compile "$ROOT"/tests/integration/"$positional".tl; done
for globbed in tests/*.tl; do compile "tests/integration/$globbed.tl"; done
for exported in alpha; do export exported; compile "tests/integration/$exported.tl"; done
for fixture in alpha; do compile "$ALIAS/tests/integration/$fixture.tl" "$OTHER/tests/$fixture.tl" "${ROOT_ALIAS}/tests/$fixture.tl"; done
for depth in 1; do : $((depth+=1)); compile "tests/integration/$depth.tl" "$ROOT"/tests/$depth/*.tl; done
for bracketed in tests/[[:alpha:]]*.in; do :; done
for ternary in 1; do : $((1?ternary=2:0)); compile "tests/integration/$ternary.tl"; done
: $((1 << bits)); cat <<E"OF"
for hidden in alpha; do :; done
EOF
for after in omega; do compile "tests/integration/$after.tl"; done
for reused in alpha; do for reused in gamma; do compile "tests/integration/$reused.tl"; done; done
helper() { for helped in $EXTRA; do :; done; }
for helped in alpha; do helper; compile "tests/integration/$helped.tl"; done
for dotted in ./tests/*.in $(ls "$ROOT"/tests/listed/*.in); do :; done
for bracket_name in alpha; do compile "tests/[ab]/$bracket_name.tl"; done
for impure in alpha; do "$TOOL" prepare; compile "tests/integration/$impure.tl"; done
for joined in alpha; do compile te""sts/integration/"$joined".tl 'tests/literal/$joined.tl' tests/[[:alpha:]]*/"$joined".tl; done
OWNER
probe_owner="$work/constructed-probe/owner.sh"
# A sourced script can rebind a name; a # line inside an open quote is string
# text; a for header must reach its do before any other command.
printf 'libbound=delta\n' > "$work/constructed-probe/lib.sh"
printf '. "%s"\nfor libbound in alpha; do compile "tests/integration/$libbound.tl"; done\n' "$work/constructed-probe/lib.sh" > "$work/constructed-probe/sourcing.sh"
printf '%s\n' "printf '%s\\n' 'first line" "# still quoted'; for commenter in alpha; do compile \"tests/integration/\$commenter.tl\"; done" > "$work/constructed-probe/quoted-comment.sh"
printf 'echo Ready ! for stray in alpha\nwhile read -r line; do compile "tests/integration/$stray.tl"; done\n' > "$work/constructed-probe/stray-for.sh"
# Each closed-whitelist class, written outside the loop, leaves the script
# unresolved; the benign forms on the last script do not.
probe_script() { printf 'synthetic-gate\t%s\n' "$1" >> "$work/constructed-probe/scripts.tsv"; }
: > "$work/constructed-probe/scripts.tsv"
for probe_name in owner sourcing quoted-comment stray-for; do probe_script "$work/constructed-probe/$probe_name.sh"; done
probe_class=0
for probe_construct in 'eval "$BINDING"' 'let other=1' 'alias rd=read' 'read -r "$TARGET" < /dev/null' 're""ad -r fixt"$SUFFIX"' 'export "$TARGET=1"' 'trap "$HANDLER" EXIT' 'printf -v"$TARGET" %s value' ': "$(( $TARGET = 32 ))"' '. "$HELPER"' 'command . "$HELPER"' 'case "$MODE" in x) . "$HELPER" ;; esac' 'builtin eval "$BINDING"'; do
    probe_class=$((probe_class + 1))
    printf '%s\n%s\n' "$probe_construct" 'for item in alpha; do compile "tests/integration/$item.tl"; done' > "$work/constructed-probe/whitelist-$probe_class.sh"
    probe_script "$work/constructed-probe/whitelist-$probe_class.sh"
done
printf ': $((\n    $TARGET = 32\n))\nfor item in alpha; do compile "tests/integration/$item.tl"; done\n' > "$work/constructed-probe/whitelist-multiline.sh"
printf '%s\n' 'command -v cc >/dev/null; IFS= read -r line < /dev/null || return $?; printf "%s\n" "$line"; : $((count + 1))' 'for item in alpha; do compile "tests/integration/$item.tl"; done' > "$work/constructed-probe/benign.sh"
probe_script "$work/constructed-probe/whitelist-multiline.sh"
probe_script "$work/constructed-probe/benign.sh"
printf '%s\t%s\t%s\n' "$probe_owner" '$WORK/' scratch "$probe_owner" '$ALIAS/' root "$probe_owner" '$UNUSED/' scratch > "$work/constructed-probe/prefixes.tsv"
constructed_inputs "$work/constructed-probe/scripts.tsv" "$work/constructed-probe/prefixes.tsv" > "$work/constructed-probe/actual.tsv" || fail 'synthetic constructed input discovery failed'
probe_row() { printf '%s\t%s\tsynthetic-gate\t%s:%s\t%s\n' "$1" "$2" "$probe_owner" "$3" "$4"; }
probe_family() { probe_row family '^tests/integration/.*\.tl$' "$1" "tests/integration/\${$2}.tl"; }
{
    probe_row member tests/integration/alpha.tl 4 'tests/integration/${fixture}.tl'
    probe_row member tests/integration/beta.tl 4 'tests/integration/${fixture}.tl'
    probe_row member stdlib/alpha/gamma-source 7 'stdlib/${fixture}/${named}-source'
    probe_row member stdlib/beta/gamma-source 7 'stdlib/${fixture}/${named}-source'
    probe_family 8 fixture
    probe_row family '^tests/integration/.*_case\.tl$' 9 'tests/integration/${loose}_case.tl'
    probe_family 10 quoted
    probe_family 11 split
    probe_family 15 embedded # Quoted heredoc text never resolves.
    probe_family 17 commented
    probe_family 17 prose
    probe_family 17 embedded
    probe_row family '^stdlib/.*\.tl$' 17 'stdlib/${?}.tl'
    probe_family 18 defaulted
    probe_family 19 positional
    probe_row family '^tests/[^/]*\.tl$' 20 'tests/*.tl'
    probe_family 20 globbed
    probe_family 21 exported
    probe_row member tests/integration/alpha.tl 22 'tests/integration/${fixture}.tl'
    probe_row member tests/integration/beta.tl 22 'tests/integration/${fixture}.tl' # Every header of a name joins one union.
    probe_row prefixed '$OTHER/' 22 'tests/${fixture}.tl'
    probe_row prefixed '${ROOT_ALIAS}/' 22 'tests/${fixture}.tl'
    probe_family 23 depth
    probe_row family '^tests/.*/.*\.tl$' 23 'tests/${depth}/*.tl'
    probe_row family '^tests/[^/][^/]*\.in$' 24 'tests/[[:alpha:]]*.in'
    probe_family 25 ternary
    probe_row member tests/integration/omega.tl 29 'tests/integration/${after}.tl'
    probe_row member tests/integration/alpha.tl 30 'tests/integration/${reused}.tl'
    probe_row member tests/integration/gamma.tl 30 'tests/integration/${reused}.tl'
    probe_family 32 helped
    probe_row family '^tests/[^/]*\.in$' 33 'tests/*.in'
    probe_row family '^tests/listed/[^/]*\.in$' 33 'tests/listed/*.in'
    probe_row family '^tests/.*/.*\.tl$' 34 'tests/*/${bracket_name}.tl'
    probe_family 35 impure # A command ran between the loop's do and the use.
    probe_row member tests/integration/alpha.tl 36 'tests/integration/${joined}.tl'
    probe_row family '^tests/.*.*/.*\.tl$' 36 'tests/**/${joined}.tl'
    printf 'family\t%s\tsynthetic-gate\t%s:2\t%s\n' '^tests/integration/.*\.tl$' "$work/constructed-probe/sourcing.sh" 'tests/integration/${libbound}.tl'
    printf 'member\t%s\tsynthetic-gate\t%s:2\t%s\n' tests/integration/alpha.tl "$work/constructed-probe/quoted-comment.sh" 'tests/integration/${commenter}.tl'
    printf 'family\t%s\tsynthetic-gate\t%s:2\t%s\n' '^tests/integration/.*\.tl$' "$work/constructed-probe/stray-for.sh" 'tests/integration/${stray}.tl'
    probe_class=0
    while [ "$probe_class" -lt 13 ]; do
        probe_class=$((probe_class + 1))
        printf 'family\t%s\tsynthetic-gate\t%s:2\t%s\n' '^tests/integration/.*\.tl$' "$work/constructed-probe/whitelist-$probe_class.sh" 'tests/integration/${item}.tl'
    done
    printf 'family\t%s\tsynthetic-gate\t%s:4\t%s\n' '^tests/integration/.*\.tl$' "$work/constructed-probe/whitelist-multiline.sh" 'tests/integration/${item}.tl'
    printf 'member\t%s\tsynthetic-gate\t%s:2\t%s\n' tests/integration/alpha.tl "$work/constructed-probe/benign.sh" 'tests/integration/${item}.tl'
    printf 'unused\t%s\t-\t%s\t-\n' '$UNUSED/' "$probe_owner"
} > "$work/constructed-probe/expected.tsv"
cmp "$work/constructed-probe/actual.tsv" "$work/constructed-probe/expected.tsv" || fail 'constructed input discovery left its supported boundary'
if constructed_prefix_gaps "$work/constructed-probe/actual.tsv" 2> "$work/constructed-probe/prefixes.err"; then
    fail 'unreviewed synthetic prefix passed'
fi
{
    printf 'constructed path under an unreviewed prefix: %s:22 %s -> synthetic-gate\n' "$probe_owner" '$OTHER/tests/${fixture}.tl' "$probe_owner" '${ROOT_ALIAS}/tests/${fixture}.tl'
    printf 'reviewed constructed prefix no longer occurs: %s %s\n' "$probe_owner" '$UNUSED/'
} > "$work/constructed-probe/prefixes.expected"
cmp "$work/constructed-probe/prefixes.err" "$work/constructed-probe/prefixes.expected" || fail 'constructed prefix review lost its diagnostic'
# A heredoc that never closes would hide every later line, so it fails.
printf 'cat <<EOF\nfor fixture in alpha; do compile "tests/integration/$fixture.tl"; done\n' > "$work/constructed-probe/unterminated.sh"
printf 'synthetic-gate\t%s\n' "$work/constructed-probe/unterminated.sh" > "$work/constructed-probe/unterminated.tsv"
if constructed_inputs "$work/constructed-probe/unterminated.tsv" "$work/constructed-probe/prefixes.tsv" > "$work/constructed-probe/unterminated.out" 2> "$work/constructed-probe/unterminated.err"; then
    fail 'unterminated synthetic heredoc passed'
fi
grep -Fx "unterminated heredoc in owning script: $work/constructed-probe/unterminated.sh" "$work/constructed-probe/unterminated.err" >/dev/null || fail 'unterminated heredoc lost its diagnostic'
# A member added to a literal list with neither a map owner nor a witness fails.
printf 'path\trequired\tadvisory\treason\ntests/integration/*\tother-gate\t-\tsynthetic\ntests/integration/beta.tl\tsynthetic-gate\t-\tsynthetic\ntests/integration/b_case.tl\tsynthetic-gate\t-\tsynthetic\nstdlib/*\t-\t@stdlib\tsynthetic\n' > "$work/constructed-probe/map.tsv"
awk -F '\t' '$1 == "member" && $2 ~ /^tests\// && !seen[$2 FS $3]++ {print $2 "\t" $3 "\t" $4}' "$work/constructed-probe/actual.tsv" > "$work/constructed-probe/members.tsv"
: > "$work/constructed-probe/directories"
if check_primary_owners "$work/constructed-probe/map.tsv" "$work/constructed-probe/directories" "$work/constructed-probe/members.tsv" 2> "$work/constructed-probe/owners.err"; then
    fail 'unowned synthetic constructed member passed'
fi
printf 'missing required primary owner: tests/integration/%s -> synthetic-gate (constructed at %s)\n' alpha.tl "$probe_owner:4" omega.tl "$probe_owner:29" gamma.tl "$probe_owner:30" > "$work/constructed-probe/owners.expected"
cmp "$work/constructed-probe/owners.err" "$work/constructed-probe/owners.expected" || fail 'constructed member omission lost its owner diagnostic'
# A family is checked through its tracked members, not an unmapped stand-in:
# a_case needs a replay, d_case shares its rows, b_case has a direct owner and
# stdlib/x.tl is unmapped.
printf '%s\n' tests/integration/a_case.tl tests/integration/b_case.tl tests/integration/d_case.tl stdlib/x.tl > "$work/constructed-probe/tracked"
awk -F '\t' '$1 == "family" && ($5 ~ /loose/ || $2 ~ /stdlib/) && $4 ~ /owner\.sh:/ {print $2 "\t" $3 "\t" $4 "\t" $5}' "$work/constructed-probe/actual.tsv" > "$work/constructed-probe/families.tsv"
constructed_family_members "$work/constructed-probe/map.tsv" "$work/constructed-probe/tracked" "$work/constructed-probe/families.tsv" > "$work/constructed-probe/family-members.tsv" || fail 'synthetic family member grouping failed'
printf 'tests/integration/a_case.tl\tsynthetic-gate\t%s:9\t%s\n' "$probe_owner" 'tests/integration/${loose}_case.tl' > "$work/constructed-probe/family-members.expected"
cmp "$work/constructed-probe/family-members.tsv" "$work/constructed-probe/family-members.expected" || fail 'constructed family lost a mapped member without its owner'

# Reviewed prefixes of constructed paths. A root alias is audited like $ROOT;
# scratch and copied roots are not repository inputs.
{
    printf '%s\t%s\troot\n' scripts/build-embedded-stdlib-tlci.sh '$SOURCE_ROOT/' # Defaults to $ROOT.
    printf '%s\t%s\tscratch\n' scripts/check-compiler-scaling.sh '$WORKDIR/' # Generated scaling sources.
    printf '%s\t%s\tscratch\n' scripts/verify-compile-profile.sh '$STDLIB_TLCI_MODIFIED_DIR/' # Modified stdlib copy.
    printf '%s\t%s\tscratch\n' scripts/verify-embedded-stdlib-tlci-resources.sh '$SOURCE_ROOT/' # Copy under WORKDIR.
    printf '%s\t%s\tscratch\n' scripts/verify-integration.sh '$_t/' # Staging self-test tree.
    printf '%s\t%s\tscratch\n' scripts/verify-integration.sh '$_tp/' # The same tree, relative to ROOT.
    printf '%s\t%s\tscratch\n' scripts/verify-stdlib-tlci-identity-differential.sh '$MODIFIED_ROOT/' # Modified stdlib copy.
    printf '%s\t%s\tscratch\n' scripts/verify-tlci-native-route-stress.sh '$SOURCE_ROOT/' # Copy under WORKDIR.
} > "$work/constructed-prefixes.tsv"
constructed_inputs "$work/recursive-scripts.tsv" "$work/constructed-prefixes.tsv" > "$work/constructed.raw" || fail 'constructed input discovery failed'
constructed_prefix_gaps "$work/constructed.raw" || fail 'constructed path prefixes need review'
awk -F '\t' '$1 == "member" && !seen[$2 FS $3]++ {print $2 "\t" $3 "\t" $4}' "$work/constructed.raw" > "$work/constructed-members.tsv"
awk -F '\t' '$1 == "family" {script = $4; sub(/:[0-9]+$/, "", script); if (!seen[$3 FS script FS $5]++) print $2 "\t" $3 "\t" $4 "\t" $5}' "$work/constructed.raw" > "$work/constructed-families.raw"
# Reviewed unresolved sites. A new site fails until it resolves, is owned or is
# recorded here with the inventory that bounds its members.
while IFS=$TAB read -r pattern gate site template; do
    case "${site%:*} $template" in
        'scripts/verify-embedded-stdlib-payload.sh stdlib/${suffix}') pattern='^stdlib/.*\.tl$' ;; # Its manifest check admits only stdlib .tl module suffixes.
    esac
    case "${site%:*} $template $gate" in
        *' embedded-stdlib-tlci-resource-verifier-self-tests') case "${site%:*}" in scripts/verify-embedded-stdlib-tlci-resources.sh | scripts/build-embedded-stdlib-tlci.sh) continue ;; esac ;; # Its --self-test exits before both sweeps.
        'scripts/verify-embedded-stdlib-payload.sh stdlib/${suffix} embedded-stdlib-build-payload') continue ;; # The same payload checks run in the required stdlib module gate.
        'scripts/build-embedded-stdlib-tlci.sh stdlib/${MODULE_PATH} '*) # Payload source hash.
            case "$gate" in embedded-stdlib-tlci-bounded-resource-report | embedded-stdlib-tlci-image | stage2-compile-profile-verifier | tlci-mutation-bootstrap-fixpoint) continue ;; esac ;;
        'scripts/verify-embedded-stdlib-tlci.sh stdlib/${suffix} embedded-stdlib-tlci-image' | 'scripts/check-bootstrap-fixpoint.sh stdlib/${_btms_module_path} tlci-mutation-bootstrap-fixpoint') continue ;; # Payload copy and source hash.
        'scripts/verify-compile-profile.sh stdlib/*.tl stage2-compile-profile-verifier' | 'scripts/verify-stdlib-tlci-identity-differential.sh stdlib/*.tl stage2-compile-profile-verifier') continue ;; # Whole-stdlib copies into a modified root.
        'scripts/verify-embedded-stdlib-tlci-resources.sh stdlib/*.tl embedded-stdlib-tlci-bounded-resource-report' | 'scripts/verify-tlci-native-route-stress.sh stdlib/*.tl tlci-native-route-sustained-stress') continue ;; # Whole-stdlib copies into a modified root.
    esac # Stdlib stays an advisory class for the other produced-compiler consumers.
    printf '%s\t%s\t%s\t%s\n' "$pattern" "$gate" "$site" "$template"
done < "$work/constructed-families.raw" > "$work/constructed-families.tsv"
constructed_family_members "$ROOT/scripts/ci-affected-paths.tsv" "$work/tracked-inputs" "$work/constructed-families.tsv" > "$work/constructed-family-members.tsv" || fail 'constructed family member grouping failed'
check_primary_owners "$ROOT/scripts/ci-affected-paths.tsv" "$work/tracked-directories" "$work/primary-inputs.tsv" "$work/constructed-members.tsv" || fail 'primary inventory ownership is incomplete'

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
            stdlib/cpu.tl:stage2-spmd-runtime-dispatch) continue ;; # Imported ISA-detector support; timestamp invalidates its artifact, no direct fixture contract.
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
                tests/integration:ir-observability-golden | tests/integration:stage2-compile-profile-verifier | tests/integration:compiler-arena-debug-native-matrix | tests/integration:stage2-safety-corpus) continue ;; # Search roots and constructed-path prefixes; discovered members have exact owners.
                tests/integration:stage2-inline-typelisp-tests) continue ;; # Broad source-suite discovery is advisory; focused tests remain owner-selected.
                tests/safety:stage2-native-integration-corpus) continue ;; # Existence-only catalog for manifest dependency validation, not a content consumer.
            esac
            path="$path/__ci_affected_directory_probe__.tl"
        fi
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/direct-reader.ids"
        has_gate "$work/direct-reader.ids" "$gate"
    done < "$work/script-inputs.tsv"
    # Inputs outside the constructed-loop boundary and reported independent guards.
    for row in 'tests/spmd/package_callable/src/lib.tl package-native-tlci-dependency-macros' 'tests/spmd/package_consumer/src/main.tl package-native-tlci-dependency-macros' 'stdlib/tests/json_sequence_api.tl stage2-stdlib-selfhost-verifier' 'tests/integration/tail_call_stack_forward.tl stage2-regalloc-backend-asm-shape-gates' 'src/tests/compiler_typed_occurrence_smoke.tl stage2-native-integration-corpus' 'tests/safety/global_mut_borrow_deref_location_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_field_overlap_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_initializer_location_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_noncall_location_reject.tl stage2-public-tool-surface' 'tests/safety/global_mut_borrow_store_location_reject.tl stage2-public-tool-surface' 'tests/safety/mut_borrow_forwarded_diagnostic_location_reject.tl stage2-public-tool-surface' 'stdlib/json.tl stage2-docs-pages-build-path' 'stdlib/json.tl stage2-stdlib-documentation' 'stdlib/json.tl stage2-stdlib-modules-and-fixtures' 'stdlib/json.tl stage2-repository-doctests' 'src/build_cli_core.tl stage2-public-tool-surface' 'src/compiler_driver_core.tl stage2-public-tool-surface' 'src/compiler_lower.tl stage2-public-tool-surface' 'src/lsp_frame_core.tl stage2-public-tool-surface' 'src/main.tl cli-help-surface' 'src/compile_cli_core.tl cli-help-surface'; do
        path=${row% *}
        gate=${row##* }
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/direct-reader.ids"
        has_gate "$work/direct-reader.ids" "$gate"
    done
    # Every tracked file an unresolved construction can name selects its gate.
    while IFS=$TAB read -r path gate site template; do
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/constructed-family.ids"
        grep -Fx "$gate" "$work/constructed-family.ids" >/dev/null || fail "unresolved constructed input: $site $template -> $gate ($path does not select it on $host)"
    done < "$work/constructed-family-members.tsv"
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
