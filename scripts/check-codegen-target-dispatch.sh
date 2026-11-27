#!/usr/bin/env sh
# Codegen target-dispatch boundary guard (#5347).
#
# One shared x86-64 backend serves Linux and Windows. Target choices live in
# named places only:
#   lower   - target-aware lowerer ABI shapes (`compiler_lower*.tl`);
#   leaf    - platform leaf modules (`*_linux.tl`, `*_windows.tl`);
#   policy  - shared-core scopes that construct the target policy or its facts;
#   adapter - shared-core scopes that select a platform leaf or adapter;
#   test    - tests.
# Every other scope of the shared core stays target-neutral: it reads policy,
# ABI, object-format and runtime facts instead of testing Linux or Windows.
#
# Covered modules are discovered by rule, so a new module in the family is
# scanned without being listed: every `src/compiler_<family>*.tl` for the
# families below. A module's role follows from its name: `*_tests.tl` is test,
# `*_linux.tl` / `*_windows.tl` is leaf, `compiler_lower*` is lower, anything
# else is shared core. Every target token found must match exactly one row of
# the per-module inventory directory (`scripts/codegen-target-dispatch.d/<module>.tsv`),
# with that row's count and a boundary its module's role admits. Production
# modules require exact positive integer counts; `role == test` (`*_tests.tl`)
# modules may use `*` (meaning >=1 observed match) as well as exact counts.
# A test module may cover itself with one `*`-scope row; every other row names
# its scope. The optimizer may have no row at all.
#
# Usage: scripts/check-codegen-target-dispatch.sh [--self-test]
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")

if [ "${1:-}" = "--self-test" ]; then
    exec sh "$SELF" --run-self-test
fi

if [ "${1:-}" != "--run-self-test" ]; then
    ROOT=${CODEGEN_TARGET_DISPATCH_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
    cd "$ROOT"
    INVENTORY=${CODEGEN_TARGET_DISPATCH_INVENTORY:-scripts/codegen-target-dispatch.d}
    WORKDIR=${CODEGEN_TARGET_DISPATCH_DIR:-target/codegen-target-dispatch}
fi

FAMILY_RE='^src/compiler_(lower|backend|regalloc|optimize|liveness|parallel_move|abi|x64|target_cfg)[a-z0-9_]*[.]tl$'

TOKEN_RE='CompilerLowerMode[.](Linux|Windows)[[:alnum:]_]*|CompilerLower(Linux|Windows)[[:alnum:]_]*|lower-mode-(linux|windows)-[[:alnum:]_?-]+|CompilerBackendTarget[.](Linux|Windows)|BackendTarget(Linux|Windows)|compiler-backend-target-(linux|windows)[?]|target-(linux|windows)|(linux|windows)-x86_64'

# Print `path<TAB>role` for every covered module.
discover_modules() {
    for path in src/compiler_*.tl; do
        [ -f "$path" ] || continue
        if ! printf '%s\n' "$path" | grep -Eq "$FAMILY_RE"; then
            continue
        fi
        case "$path" in
            *_tests.tl) role=test ;;
            *_linux.tl|*_windows.tl) role=leaf ;;
            src/compiler_lower*) role=lower ;;
            *) role=core ;;
        esac
        printf '%s\t%s\n' "$path" "$role"
    done
}

# Validate inventory directory and print `DIR/*.tsv` in LC_ALL=C sorted order.
list_inventory_files() {
    _dir=$1
    case "$_dir" in
        /) ;;
        */) _dir=${_dir%/} ;;
    esac
    if [ ! -d "$_dir" ]; then
        echo "missing codegen target dispatch inventory directory: $_dir" >&2
        return 1
    fi
    _entries=$(find "$_dir" -print | LC_ALL=C sort) || return 1
    _count=0
    while IFS= read -r _entry; do
        [ -n "$_entry" ] || continue
        [ "$_entry" != "$_dir" ] || continue
        _rel=${_entry#"$_dir"/}
        case "$_rel" in
            */*)
                echo "target dispatch inventory directory $_dir contains nested entry: $_rel" >&2
                return 1
                ;;
            .tsv)
                echo "target dispatch inventory directory $_dir contains invalid filename: $_rel" >&2
                return 1
                ;;
            *.tsv) ;;
            *)
                echo "target dispatch inventory directory $_dir contains unexpected non-.tsv entry: $_rel" >&2
                return 1
                ;;
        esac
        if [ ! -f "$_entry" ] || [ -L "$_entry" ]; then
            echo "target dispatch inventory directory $_dir contains non-regular entry: $_rel" >&2
            return 1
        fi
        _count=$((_count + 1))
    done <<EOF
$_entries
EOF
    if [ "$_count" -eq 0 ]; then
        echo "target dispatch inventory directory is empty (no *.tsv files): $_dir" >&2
        return 1
    fi
    while IFS= read -r _entry; do
        [ -n "$_entry" ] || continue
        [ "$_entry" != "$_dir" ] || continue
        printf '%s\n' "$_entry"
    done <<EOF
$_entries
EOF
}

# Print `file<TAB>scope<TAB>token<TAB>line` for every target token.
scan_tokens() {
    awk -v token_re="$TOKEN_RE" '
function scope_name(text) {
    sub(/[[:space:]].*/, "", text)
    sub(/\).*/, "", text)
    sub(/\[.*/, "", text)
    return text
}
FNR == 1 {
    scope = "<toplevel>"
}
{
    line = $0
    if (line ~ /^\(define[[:space:]]+\(/) {
        text = line
        sub(/^\(define[[:space:]]+\(/, "", text)
        scope = scope_name(text)
    } else if (line ~ /^\(define[[:space:]]+/) {
        text = line
        sub(/^\(define[[:space:]]+/, "", text)
        scope = scope_name(text)
    } else if (line ~ /^\(defenum[[:space:]]+/) {
        text = line
        sub(/^\(defenum[[:space:]]+/, "", text)
        scope = "enum:" scope_name(text)
    } else if (line ~ /^\(defstruct[[:space:]]+/) {
        text = line
        sub(/^\(defstruct[[:space:]]+/, "", text)
        scope = "type:" scope_name(text)
    } else if (line ~ /^\(deftype[[:space:]]+/) {
        text = line
        sub(/^\(deftype[[:space:]]+/, "", text)
        scope = "type:" scope_name(text)
    }

    if (line ~ /^[[:space:]]*;;/) {
        next
    }

    if (scope == "enum:CompilerBackendTarget") {
        if (line ~ /^[[:space:]]*\(Linux\)/) {
            printf "%s\t%s\tCompilerBackendTarget.Linux\t%d\n", FILENAME, scope, FNR
        } else if (line ~ /^[[:space:]]*\(Windows\)/) {
            printf "%s\t%s\tCompilerBackendTarget.Windows\t%d\n", FILENAME, scope, FNR
        }
    }

    if (scope == "enum:CompilerLowerMode") {
        if (line ~ /^[[:space:]]*\((Linux|Windows)(Scalar|Sse2|Avx2|Avx512)\)/) {
            token = line
            sub(/^[[:space:]]*\(/, "", token)
            sub(/\).*/, "", token)
            printf "%s\t%s\tCompilerLowerMode.%s\t%d\n", FILENAME, scope, token, FNR
        }
    }

    rest = line
    while (match(rest, token_re)) {
        token = substr(rest, RSTART, RLENGTH)
        printf "%s\t%s\t%s\t%d\n", FILENAME, scope, token, FNR
        rest = substr(rest, RSTART + RLENGTH)
    }
}
' "$@"
}

run_check() {
    mkdir -p "$WORKDIR"
    inv_files="$WORKDIR/inventory-files.txt"
    list_inventory_files "$INVENTORY" > "$inv_files" || return 1
    modules="$WORKDIR/modules.tsv"
    observed="$WORKDIR/observed.tsv"
    discover_modules > "$modules"
    if [ ! -s "$modules" ]; then
        echo "codegen target dispatch: no covered modules found" >&2
        return 1
    fi
    # shellcheck disable=SC2046
    scan_tokens $(cut -f1 "$modules") | sort > "$observed"

    awk -F '\t' -v inv_list="$inv_files" -v modules="$modules" -v observed="$observed" '
BEGIN {
    valid_category["abi"] = 1
    valid_category["backend-mode"] = 1
    valid_category["entry"] = 1
    valid_category["object-format"] = 1
    valid_category["runtime"] = 1
    valid_category["target-cfg"] = 1
    valid_category["test-only"] = 1
    admits["core", "policy"] = 1
    admits["core", "adapter"] = 1
    admits["core", "test"] = 1
    admits["leaf", "leaf"] = 1
    admits["lower", "lower"] = 1
    admits["test", "test"] = 1
}
FILENAME == modules {
    role[$1] = $2
    next
}
FILENAME == inv_list {
    inv_path = $0
    sub(/\r$/, "", inv_path)
    if (inv_path == "") {
        next
    }
    mod_name = inv_path
    sub(/^.*\//, "", mod_name)
    sub(/\.tsv$/, "", mod_name)
    expected_src = "src/" mod_name ".tl"
    lno = 0
    file_rows = 0
    while ((st = (getline raw < inv_path)) > 0) {
        lno += 1
        sub(/\r$/, "", raw)
        if (raw == "" || raw ~ /^#/) {
            continue
        }
        file_rows += 1
        nf = split(raw, f, "\t")
        if (nf != 7) {
            printf "malformed target dispatch inventory %s:%d: expected 7 tab-separated fields\n", inv_path, lno > "/dev/stderr"
            failed = 1
            continue
        }
        if (f[1] != expected_src) {
            printf "target dispatch inventory %s:%d names `%s`, expected `%s` for module file\n", inv_path, lno, f[1], expected_src > "/dev/stderr"
            failed = 1
        }
        if (!(f[1] in role)) {
            printf "target dispatch inventory %s:%d names `%s`, which is not a covered module\n", inv_path, lno, f[1] > "/dev/stderr"
            failed = 1
        }
        if (!((f[3] == "policy") || (f[3] == "adapter") || (f[3] == "lower") || (f[3] == "leaf") || (f[3] == "test"))) {
            printf "target dispatch inventory %s:%d: unknown boundary `%s`\n", inv_path, lno, f[3] > "/dev/stderr"
            failed = 1
        } else if ((f[1] in role) && !((role[f[1]], f[3]) in admits)) {
            printf "target dispatch inventory %s:%d: boundary `%s` is not allowed in %s module %s\n", inv_path, lno, f[3], role[f[1]], f[1] > "/dev/stderr"
            failed = 1
        }
        if (!(f[4] in valid_category)) {
            printf "target dispatch inventory %s:%d: unknown category `%s`\n", inv_path, lno, f[4] > "/dev/stderr"
            failed = 1
        }
        if ((f[3] == "test") != (f[4] == "test-only")) {
            printf "target dispatch inventory %s:%d: boundary test and category test-only go together\n", inv_path, lno > "/dev/stderr"
            failed = 1
        }
        if (f[1] ~ /^src\/compiler_optimize/) {
            printf "target dispatch inventory %s:%d: the optimizer must stay target-free\n", inv_path, lno > "/dev/stderr"
            failed = 1
        }
        if (f[6] == "*") {
            if (!(f[1] in role) || role[f[1]] != "test" || f[3] != "test") {
                printf "target dispatch inventory %s:%d: wildcard count `*` is only allowed for test modules (*_tests.tl)\n", inv_path, lno > "/dev/stderr"
                failed = 1
            }
        } else if (f[6] !~ /^[1-9][0-9]*$/) {
            printf "target dispatch inventory %s:%d: count must be a positive integer\n", inv_path, lno > "/dev/stderr"
            failed = 1
        }
        if ((f[2] == "*") && (f[3] != "test")) {
            printf "target dispatch inventory %s:%d: only a test row may cover a whole module (scope *)\n", inv_path, lno > "/dev/stderr"
            failed = 1
        }
        if (f[7] ~ /^[[:space:]]*$/) {
            printf "target dispatch inventory %s:%d: rationale is empty\n", inv_path, lno > "/dev/stderr"
            failed = 1
        }
        key = f[1] SUBSEP f[2] SUBSEP f[5]
        if (key in seen_row) {
            printf "duplicate target dispatch inventory %s:%d for %s\t%s\t%s\n", inv_path, lno, f[1], f[2], f[5] > "/dev/stderr"
            failed = 1
        }
        seen_row[key] = 1
        rows += 1
        row_file[rows] = f[1]
        row_scope[rows] = f[2]
        row_boundary[rows] = f[3]
        row_regex[rows] = f[5]
        row_expected[rows] = (f[6] == "*" ? "*" : (f[6] + 0))
    }
    if (st < 0) {
        printf "failed to read target dispatch inventory file: %s\n", inv_path > "/dev/stderr"
        failed = 1
    }
    close(inv_path)
    if (file_rows == 0) {
        printf "target dispatch inventory file is empty: %s\n", inv_path > "/dev/stderr"
        failed = 1
    }
    next
}
FILENAME == observed {
    total += 1
    matched = 0
    matched_row = 0
    for (idx = 1; idx <= rows; idx += 1) {
        if ($1 == row_file[idx] && (row_scope[idx] == "*" || $2 == row_scope[idx]) && $3 ~ ("^(" row_regex[idx] ")$")) {
            matched += 1
            matched_row = idx
        }
    }
    if (matched == 1) {
        actual[matched_row] += 1
    } else if (matched == 0) {
        printf "unclassified target dispatch in %s module: %s:%s scope=%s token=%s\n", role[$1], $1, $4, $2, $3 > "/dev/stderr"
        failed = 1
    } else {
        printf "ambiguous target dispatch: %s:%s scope=%s token=%s matched %d rows\n", $1, $4, $2, $3, matched > "/dev/stderr"
        failed = 1
    }
    next
}
END {
    if (rows == 0) {
        print "target dispatch inventory is empty" > "/dev/stderr"
        failed = 1
    }
    for (idx = 1; idx <= rows; idx += 1) {
        count = actual[idx] + 0
        if (row_expected[idx] == "*") {
            if (count < 1) {
                printf "target dispatch count mismatch: %s scope=%s regex=%s expected=>=1 observed=%d\n", row_file[idx], row_scope[idx], row_regex[idx], count > "/dev/stderr"
                failed = 1
            }
        } else if (count != row_expected[idx]) {
            printf "target dispatch count mismatch: %s scope=%s regex=%s expected=%d observed=%d\n", row_file[idx], row_scope[idx], row_regex[idx], row_expected[idx], count > "/dev/stderr"
            failed = 1
        }
        per_boundary[row_boundary[idx]] += count
    }
    if (failed) {
        print "codegen target dispatch check failed" > "/dev/stderr"
        exit 1
    }
    printf "codegen target dispatch inventory covers %d occurrences across %d rows (policy %d, adapter %d, lower %d, leaf %d, test %d)\n", total, rows, per_boundary["policy"], per_boundary["adapter"], per_boundary["lower"], per_boundary["leaf"], per_boundary["test"]
}
' "$modules" "$inv_files" "$observed"
}

# Each case builds a small tree, runs the real check against it, and expects
# success or one specific failure.
run_self_test() {
    selftest_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    mkdir -p "$selftest_root/target/codegen-target-dispatch"
    base=$(mktemp -d "$selftest_root/target/codegen-target-dispatch/self-test.XXXXXX")
    trap 'rm -rf "$base"' EXIT
    failures=0
    cases=0

    write_tree() {
        tree=$1
        mkdir -p "$tree/src" "$tree/scripts/inventory.d"
        cat > "$tree/src/compiler_backend.tl" <<'EOF'
(define (compiler-backend-target-policy-new [target : CompilerBackendTarget]) : i64
  (match target
    [(CompilerBackendTarget.Linux) 1]
    [(CompilerBackendTarget.Windows) 2]))

(define (compiler-backend-emit-call [policy : i64]) : i64
  policy)
EOF
        cat > "$tree/src/compiler_backend_runtime_linux.tl" <<'EOF'
(define (compiler-backend-runtime-name) : String
  "linux-x86_64")
EOF
        printf '%s\n' \
            '# file	scope	boundary	category	token-regex	count	rationale' \
            'src/compiler_backend.tl	compiler-backend-target-policy-new	policy	abi	CompilerBackendTarget[.](Linux|Windows)	2	Builds the target policy.' \
            > "$tree/scripts/inventory.d/compiler_backend.tsv"
        printf '%s\n' \
            '# file	scope	boundary	category	token-regex	count	rationale' \
            'src/compiler_backend_runtime_linux.tl	compiler-backend-runtime-name	leaf	runtime	linux-x86_64	1	The Linux runtime names its target.' \
            > "$tree/scripts/inventory.d/compiler_backend_runtime_linux.tsv"
    }

    # expect NAME pass|fail [MESSAGE] -- with the tree already edited
    expect() {
        name=$1
        want=$2
        message=${3:-}
        tree="$base/$name"
        cases=$((cases + 1))
        set +e
        out=$(CODEGEN_TARGET_DISPATCH_ROOT="$tree" \
            CODEGEN_TARGET_DISPATCH_INVENTORY=scripts/inventory.d \
            CODEGEN_TARGET_DISPATCH_DIR="$tree/work" \
            sh "$SELF" 2>&1)
        status=$?
        set -e
        if [ "$want" = pass ]; then
            if [ "$status" -ne 0 ]; then
                echo "self-test $name: expected a pass, got:" >&2
                printf '%s\n' "$out" >&2
                failures=$((failures + 1))
            fi
        elif [ "$status" -eq 0 ]; then
            echo "self-test $name: expected a failure, but the check passed" >&2
            failures=$((failures + 1))
        elif ! printf '%s\n' "$out" | grep -qF -- "$message"; then
            echo "self-test $name: expected \`$message\`, got:" >&2
            printf '%s\n' "$out" >&2
            failures=$((failures + 1))
        fi
    }

    # An allowed policy-construction site and a classified leaf pass.
    write_tree "$base/allowed-policy"
    expect allowed-policy pass

    # A shared-core scope that tests the target itself is unclassified.
    write_tree "$base/core-unclassified"
    cat >> "$base/core-unclassified/src/compiler_backend.tl" <<'EOF'

(define (compiler-backend-emit-frame [target : CompilerBackendTarget]) : i64
  (if (compiler-backend-target-windows? target) 32 0))
EOF
    expect core-unclassified fail "unclassified target dispatch in core module"

    # A leaf token without a row.
    write_tree "$base/leaf-unclassified"
    cat >> "$base/leaf-unclassified/src/compiler_backend_runtime_linux.tl" <<'EOF'

(define (compiler-backend-runtime-other) : String
  "linux-x86_64")
EOF
    expect leaf-unclassified fail "unclassified target dispatch in leaf module"

    # Two rows match one token.
    write_tree "$base/ambiguous"
    printf '%s\n' 'src/compiler_backend.tl	compiler-backend-target-policy-new	policy	abi	CompilerBackendTarget[.]Linux	1	Overlaps the row above.' \
        >> "$base/ambiguous/scripts/inventory.d/compiler_backend.tsv"
    expect ambiguous fail "ambiguous target dispatch"

    # Duplicate (file, scope, regex) row is rejected.
    write_tree "$base/duplicate-row"
    printf '%s\n' 'src/compiler_backend.tl	compiler-backend-target-policy-new	policy	abi	CompilerBackendTarget[.](Linux|Windows)	2	Duplicate row.' \
        >> "$base/duplicate-row/scripts/inventory.d/compiler_backend.tsv"
    expect duplicate-row fail "duplicate target dispatch inventory"

    # A count that no longer matches the source.
    write_tree "$base/stale-count"
    sed 's/Linux|Windows)	2	/Linux|Windows)	3	/' "$base/stale-count/scripts/inventory.d/compiler_backend.tsv" > "$base/stale-count/scripts/inventory.d/compiler_backend.new"
    mv "$base/stale-count/scripts/inventory.d/compiler_backend.new" "$base/stale-count/scripts/inventory.d/compiler_backend.tsv"
    expect stale-count fail "count mismatch"

    # An unknown category, and the retired `transitional` one.
    write_tree "$base/illegal-category"
    sed 's/	policy	abi	/	policy	transitional	/' "$base/illegal-category/scripts/inventory.d/compiler_backend.tsv" > "$base/illegal-category/scripts/inventory.d/compiler_backend.new"
    mv "$base/illegal-category/scripts/inventory.d/compiler_backend.new" "$base/illegal-category/scripts/inventory.d/compiler_backend.tsv"
    expect illegal-category fail "unknown category \`transitional\`"

    # An unknown boundary, and a boundary the module's role does not admit.
    write_tree "$base/illegal-boundary"
    sed 's/	policy	abi	/	shared	abi	/' "$base/illegal-boundary/scripts/inventory.d/compiler_backend.tsv" > "$base/illegal-boundary/scripts/inventory.d/compiler_backend.new"
    mv "$base/illegal-boundary/scripts/inventory.d/compiler_backend.new" "$base/illegal-boundary/scripts/inventory.d/compiler_backend.tsv"
    expect illegal-boundary fail "unknown boundary \`shared\`"
    write_tree "$base/wrong-boundary"
    sed 's/	policy	abi	/	leaf	abi	/' "$base/wrong-boundary/scripts/inventory.d/compiler_backend.tsv" > "$base/wrong-boundary/scripts/inventory.d/compiler_backend.new"
    mv "$base/wrong-boundary/scripts/inventory.d/compiler_backend.new" "$base/wrong-boundary/scripts/inventory.d/compiler_backend.tsv"
    expect wrong-boundary fail "boundary \`leaf\` is not allowed in core module"

    # A new module in the covered family is scanned without being listed.
    write_tree "$base/new-module"
    cat > "$base/new-module/src/compiler_backend_unwind.tl" <<'EOF'
(define (compiler-backend-unwind-text [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Windows) ".seh_proc"]
    [_ ""]))
EOF
    expect new-module fail "src/compiler_backend_unwind.tl"

    # Shared target-cfg presets retain the guard after dispatch moves there.
    write_tree "$base/target-cfg-unclassified"
    cat > "$base/target-cfg-unclassified/src/compiler_target_cfg_core.tl" <<'EOF'
(define (compiler-target-enable-linux-cfgs) : String "target-linux")
EOF
    expect target-cfg-unclassified fail "unclassified target dispatch in core module"
    write_tree "$base/target-cfg-classified"
    cp "$base/target-cfg-unclassified/src/compiler_target_cfg_core.tl" \
        "$base/target-cfg-classified/src/compiler_target_cfg_core.tl"
    printf '%s\n' \
        '# file	scope	boundary	category	token-regex	count	rationale' \
        'src/compiler_target_cfg_core.tl	compiler-target-enable-linux-cfgs	policy	target-cfg	target-linux	1	Shared Linux cfg preset.' \
        > "$base/target-cfg-classified/scripts/inventory.d/compiler_target_cfg_core.tsv"
    expect target-cfg-classified pass

    # The optimizer may not be classified at all.
    write_tree "$base/optimizer-row"
    cat > "$base/optimizer-row/src/compiler_optimize.tl" <<'EOF'
(define (opt-target-name) : String
  "linux-x86_64")
EOF
    printf '%s\n' \
        '# file	scope	boundary	category	token-regex	count	rationale' \
        'src/compiler_optimize.tl	opt-target-name	policy	abi	linux-x86_64	1	Not allowed.' \
        > "$base/optimizer-row/scripts/inventory.d/compiler_optimize.tsv"
    expect optimizer-row fail "the optimizer must stay target-free"

    # A row for a file outside the covered family.
    write_tree "$base/uncovered-row"
    printf '%s\n' \
        '# file	scope	boundary	category	token-regex	count	rationale' \
        'src/compile_cli_core.tl	main	policy	abi	linux-x86_64	1	Not covered.' \
        > "$base/uncovered-row/scripts/inventory.d/compile_cli_core.tsv"
    expect uncovered-row fail "is not a covered module"

    # A row placed in the wrong module file is rejected.
    write_tree "$base/wrong-module-file"
    printf '%s\n' 'src/compiler_backend.tl	compiler-backend-emit-call	policy	abi	linux-x86_64	1	Wrong module file.' \
        >> "$base/wrong-module-file/scripts/inventory.d/compiler_backend_runtime_linux.tsv"
    expect wrong-module-file fail "expected \`src/compiler_backend_runtime_linux.tl\` for module file"

    # Stray non-.tsv file in inventory directory is rejected.
    write_tree "$base/stray-file"
    printf 'stray\n' > "$base/stray-file/scripts/inventory.d/notes.txt"
    expect stray-file fail "unexpected non-.tsv entry: notes.txt"

    # Nested subdirectory in inventory directory is rejected.
    write_tree "$base/nested-dir"
    mkdir -p "$base/nested-dir/scripts/inventory.d/sub"
    expect nested-dir fail "unexpected non-.tsv entry: sub"

    # Empty .tsv fragment file is rejected.
    write_tree "$base/empty-fragment"
    printf '# empty\n' > "$base/empty-fragment/scripts/inventory.d/compiler_backend_empty.tsv"
    expect empty-fragment fail "target dispatch inventory file is empty"

    # Empty inventory directory is rejected.
    write_tree "$base/empty-dir"
    rm -f "$base/empty-dir/scripts/inventory.d/"*.tsv
    expect empty-dir fail "inventory directory is empty"

    # Wildcard count `*` is allowed on test modules (*_tests.tl) with >=1 match.
    write_tree "$base/test-wildcard-pass"
    cat > "$base/test-wildcard-pass/src/compiler_backend_tests.tl" <<'EOF'
(define (test-targets) : i64
  (match (CompilerBackendTarget.Linux)
    [(CompilerBackendTarget.Linux) 1]
    [(CompilerBackendTarget.Windows) 2]))
EOF
    printf '%s\n' \
        '# file	scope	boundary	category	token-regex	count	rationale' \
        'src/compiler_backend_tests.tl	*	test	test-only	CompilerBackendTarget[.](Linux|Windows)	*	Backend tests name the targets they exercise.' \
        > "$base/test-wildcard-pass/scripts/inventory.d/compiler_backend_tests.tsv"
    expect test-wildcard-pass pass

    # Wildcard count `*` on test modules still requires >=1 observed match.
    write_tree "$base/test-wildcard-zero"
    cat > "$base/test-wildcard-zero/src/compiler_backend_tests.tl" <<'EOF'
(define (test-no-targets) : i64 42)
EOF
    printf '%s\n' \
        '# file	scope	boundary	category	token-regex	count	rationale' \
        'src/compiler_backend_tests.tl	*	test	test-only	CompilerBackendTarget[.](Linux|Windows)	*	Unused wildcard row.' \
        > "$base/test-wildcard-zero/scripts/inventory.d/compiler_backend_tests.tsv"
    expect test-wildcard-zero fail "expected=>=1 observed=0"

    # Wildcard count `*` is rejected on non-test production modules (policy/adapter/lower/leaf).
    write_tree "$base/prod-wildcard-reject"
    sed 's/Linux|Windows)	2	/Linux|Windows)	*	/' "$base/prod-wildcard-reject/scripts/inventory.d/compiler_backend.tsv" > "$base/prod-wildcard-reject/scripts/inventory.d/compiler_backend.new"
    mv "$base/prod-wildcard-reject/scripts/inventory.d/compiler_backend.new" "$base/prod-wildcard-reject/scripts/inventory.d/compiler_backend.tsv"
    expect prod-wildcard-reject fail "wildcard count \`*\` is only allowed for test modules"

    # Wildcard count `*` is also rejected on inline test rows inside a core module.
    write_tree "$base/core-inline-test-wildcard-reject"
    cat >> "$base/core-inline-test-wildcard-reject/src/compiler_backend.tl" <<'EOF'

(define (compiler-backend-inline-test) : String
  "windows-x86_64")
EOF
    printf '%s\n' 'src/compiler_backend.tl	compiler-backend-inline-test	test	test-only	windows-x86_64	*	Inline test in core module.' \
        >> "$base/core-inline-test-wildcard-reject/scripts/inventory.d/compiler_backend.tsv"
    expect core-inline-test-wildcard-reject fail "wildcard count \`*\` is only allowed for test modules"

    if [ "$failures" -ne 0 ]; then
        echo "codegen target dispatch self-test: $failures of $cases cases failed" >&2
        return 1
    fi
    echo "codegen target dispatch self-test: $cases cases passed"
}

if [ "${1:-}" = "--run-self-test" ]; then
    run_self_test
else
    run_check
fi
