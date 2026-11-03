#!/usr/bin/env sh
# check-with-region-binder-audit.sh - audit the with-arena rename's binder
# coverage (#9593) against the AST schema.
#
# `tc-with-region-rename-binders` renames a colliding with-arena region inside
# the arena body and must stop exactly where a local binder spelled like the
# region shadows it. This gate derives every AstExpr constructor from
# src/compiler_ast_types.tl, and every field `ast-expr-map-children` (and the
# list map macros it calls) passes through unchanged, then checks both sets
# against scripts/with-region-binder-audit.tsv in both directions:
#   - every constructor is classified exactly once: binder, barrier or
#     nonbinder;
#   - every binder has a named arm in tc-with-region-rename-binders and a
#     shadow fixture listed in tests/safety/manifest.txt;
#   - every barrier has its arm in tc-with-region-rename-expr!;
#   - every constructor cites FILE#FUNCTION, a checker function whose patterns
#     name it, so line drift elsewhere does not break the citation;
#   - every derived passthrough field, including those of the list map macros
#     an arm calls (as macro:field), is listed with its kind.
# --self-test checks that an omitted constructor, an omitted binder arm, an
# unlisted passthrough field, a list map macro gaining or dropping a name and a
# wrong citation each fail the audit, and that line drift does not.
# --markdown prints the table.
# usage: scripts/check-with-region-binder-audit.sh [--self-test|--markdown]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TABLE=${AUDIT_TABLE:-scripts/with-region-binder-audit.tsv}
AST=${AUDIT_AST:-src/compiler_ast_types.tl}
CORE=${AUDIT_CORE:-src/compiler_typecheck_core.tl}
MANIFEST=${AUDIT_MANIFEST:-tests/safety/manifest.txt}

derive_constructors() {
    awk '/^\(defenum AstExpr$/ { f = 1; next }
         f && /^\(/ { f = 0 }
         f && /^  \([A-Z]/ { sub(/^  \(/, ""); split($0, a, /[ )]/); print a[1] }' "$1"
}

# Prints "Constructor<TAB>field" for every pattern variable that an arm of
# ast-expr-map-children copies into its result without a hook, and, for every
# list map macro an arm calls (transitively), "Constructor<TAB>macro:field" for
# each pattern variable that macro copies through unchanged.
derive_passthrough() {
    awk '
    function passthrough(text, emit,   n, i, toks, v, out, rest, cnt, pats, s, m, seen, re) {
        gsub(/[ \t]+/, " ", text)
        pats = ""; s = text
        while (match(s, /\[\([A-Za-z0-9.]+( [a-z0-9?-]+)*\)/)) {
            m = substr(s, RSTART + 2, RLENGTH - 3)
            sub(/^[A-Za-z0-9.]+/, "", m)
            pats = pats " " m
            s = substr(s, RSTART + RLENGTH)
        }
        out = text
        # Hooked children, box reads and nested list maps are not passthrough.
        gsub(/\(,[a-z-]+ ,@[a-z]+ [a-z0-9?-]+\)/, " HOOK ", out)
        gsub(/\(__tl-box-place [a-z-]+\)/, " BOX ", out)
        gsub(/\(ast-[a-z-]+-map [a-z-]+[^)]*\)/, " MAP ", out)
        gsub(/\[\([A-Za-z0-9.]+( [a-z0-9?-]+)*\)/, " PAT ", out)
        n = split(pats, toks, " ")
        for (i = 1; i <= n; i++) {
            v = toks[i]
            if (v == "" || v ~ /^[A-Z]/ || (v in seen)) continue
            seen[v] = 1
            rest = out; re = v
            gsub(/[?]/, "[?]", re)
            cnt = gsub("[ (]" re "[ )]", "", rest)
            if (cnt > 0) emit[++emit[0]] = v
        }
    }
    function helpers_of(text, key,   s) {
        s = text
        while (match(s, /\(ast-[a-z-]+-map /)) {
            uses[key] = uses[key] " " substr(s, RSTART + 1, RLENGTH - 2)
            s = substr(s, RSTART + RLENGTH)
        }
    }
    function flush(   e, i) {
        if (unit == "") return
        e[0] = 0
        passthrough(text, e)
        if (mode == "map") {
            for (i = 1; i <= e[0]; i++) print unit "\t" e[i]
            ctors[unit] = 1
        } else {
            for (i = 1; i <= e[0]; i++) hp[unit] = hp[unit] " " e[i]
        }
        helpers_of(text, unit)
        unit = ""; text = ""
    }
    function short(h) { sub(/^ast-/, "", h); sub(/(-list)?-map$/, "", h); return h }
    function expand(c, h, depth,   n, i, hs, k, vs) {
        if (depth > 8 || ((c SUBSEP h) in done)) return
        done[c SUBSEP h] = 1
        n = split(hp[h], vs, " ")
        for (k = 1; k <= n; k++) if (vs[k] != "") print c "\t" short(h) ":" vs[k]
        n = split(uses[h], hs, " ")
        for (i = 1; i <= n; i++) if (hs[i] != "") expand(c, hs[i], depth + 1)
    }
    /^\(/ { flush(); mode = "" }
    /^\(defmacro \(ast-expr-map-children$/ { mode = "map"; next }
    /^\(defmacro \(ast-[a-z-]+-map$/ {
        mode = "helper"; unit = $0; sub(/^\(defmacro \(/, "", unit); next
    }
    mode == "" { next }
    /^[ \t]*;/ { next }
    mode == "map" && /^      \[\(AstExpr\.[A-Za-z]+/ {
        flush(); mode = "map"
        unit = $0; sub(/^      \[\(AstExpr\./, "", unit); sub(/[ )].*/, "", unit)
    }
    unit != "" { text = text " " $0 }
    END {
        flush()
        for (c in ctors) {
            n = split(uses[c], hs, " ")
            for (i = 1; i <= n; i++) if (hs[i] != "") expand(c, hs[i], 0)
        }
    }' "$1"
}

function_arms() {
    awk -v fn="$2" '
        $0 == "(define (" fn { f = 1; next }
        f && /^\(/ { f = 0 }
        f && /^    \[\(/ { s = $0; sub(/^    \[\(/, "", s); sub(/[ )].*/, "", s); print s }' "$1"
}

audit() {
    work=$1
    status=0
    derive_constructors "$AST" | sort -u > "$work/ctors"
    derive_passthrough "$AST" | sort -u > "$work/passthrough"
    function_arms "$CORE" tc-with-region-rename-binders | sort -u > "$work/binder-arms"
    awk '$0 == "(define (tc-with-region-rename-expr!" { f = 1; next } f && /^\(/ { f = 0 } f' "$CORE" > "$work/barrier-text"
    grep -v '^#' "$TABLE" | awk -F '\t' 'NF' > "$work/table"
    awk -F '\t' '$1 == "ctor" { print $2 }' "$work/table" | sort > "$work/table-ctors-all"
    sort -u "$work/table-ctors-all" > "$work/table-ctors"
    if ! cmp -s "$work/table-ctors-all" "$work/table-ctors"; then
        echo "binder-audit: a constructor is classified more than once" >&2; status=1
    fi
    if ! cmp -s "$work/ctors" "$work/table-ctors"; then
        echo "binder-audit: AstExpr constructors and the table differ (< source, > table):" >&2
        diff "$work/ctors" "$work/table-ctors" | grep '^[<>]' >&2 || true
        status=1
    fi
    awk -F '\t' '$1 == "field" { print $2 "\t" $3 }' "$work/table" | sort -u > "$work/table-fields"
    if ! cmp -s "$work/passthrough" "$work/table-fields"; then
        echo "binder-audit: map-children passthrough fields and the table differ (< source, > table):" >&2
        diff "$work/passthrough" "$work/table-fields" | grep '^[<>]' >&2 || true
        status=1
    fi
    while IFS="$(printf '\t')" read -r kind ctor class handler fixture cite; do
        [ "$kind" = ctor ] || continue
        case "$class" in
            binder)
                if ! grep -qx "$ctor" "$work/binder-arms"; then
                    echo "binder-audit: binder $ctor has no arm in tc-with-region-rename-binders" >&2; status=1
                fi
                if ! grep -q "^$fixture|" "$MANIFEST"; then
                    echo "binder-audit: binder $ctor shadow fixture $fixture is not in $MANIFEST" >&2; status=1
                fi ;;
            barrier)
                if ! grep -q "($ctor[ )]" "$work/barrier-text"; then
                    echo "binder-audit: barrier $ctor has no arm in tc-with-region-rename-expr!" >&2; status=1
                fi ;;
            nonbinder) : ;;
            *) echo "binder-audit: $ctor has unknown class '$class'" >&2; status=1 ;;
        esac
        # A citation is FILE#FUNCTION: the checker function must name the
        # constructor in a pattern, so line drift elsewhere cannot break it.
        file=${cite%%#*}; fn=${cite##*#}
        [ "$file" = src/compiler_typecheck_core.tl ] && file=$CORE
        if [ ! -f "$file" ] || ! awk -v fn="$fn" -v c="$ctor" '
                $0 == "(define (" fn || index($0, "(define (" fn " ") == 1 { f = 1; next }
                f && /^\(/ { f = 0 }
                f && $0 ~ ("\\((ast\\.AstExpr\\.)?" c "[ )]") { found = 1 }
                END { exit found ? 0 : 1 }' "$file"; then
            echo "binder-audit: $ctor citation $cite: the function does not name the constructor" >&2; status=1
        fi
    done < "$work/table"
    while IFS="$(printf '\t')" read -r kind ctor field fkind note; do
        [ "$kind" = field ] || continue
        case "$fkind" in
            binder-name)
                if ! awk -F '\t' -v c="$ctor" '$1 == "ctor" && $2 == c && $3 == "binder"' "$work/table" | grep -q .; then
                    echo "binder-audit: $ctor.$field binds a name but $ctor is not a binder" >&2; status=1
                fi ;;
            region-name)
                if ! awk -F '\t' -v c="$ctor" '$1 == "ctor" && $2 == c && $3 == "barrier"' "$work/table" | grep -q .; then
                    echo "binder-audit: $ctor.$field names a region but $ctor is not a barrier" >&2; status=1
                fi ;;
            use-name | lifetime | data) : ;;
            *) echo "binder-audit: $ctor.$field has unknown kind '$fkind'" >&2; status=1 ;;
        esac
    done < "$work/table"
    return "$status"
}

new_work() {
    base=${TMPDIR:-$ROOT/target}/with-region-binder-audit
    mkdir -p "$base"
    mktemp -d "$base/run.XXXXXX"
}

case "${1:-}" in
    --markdown)
        echo '| AstExpr | class | handler | shadow fixture | checker line |'
        echo '|---|---|---|---|---|'
        grep -v '^#' "$TABLE" | awk -F '\t' '$1 == "ctor" { printf "| %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6 }'
        echo
        echo '| AstExpr | passthrough field | kind | note |'
        echo '|---|---|---|---|'
        grep -v '^#' "$TABLE" | awk -F '\t' '$1 == "field" { printf "| %s | %s | %s | %s |\n", $2, $3, $4, $5 }'
        ;;
    --self-test)
        work=$(new_work)
        cp "$TABLE" "$work/table.tsv"
        cp "$CORE" "$work/core.tl"
        grep -v "$(printf '^ctor\tLaneValue\t')" "$TABLE" > "$work/omit-ctor.tsv"
        if AUDIT_TABLE="$work/omit-ctor.tsv" "$0" > "$work/omit-ctor.out" 2>&1; then
            echo "binder-audit self-test: an omitted constructor passed" >&2; exit 1
        fi
        awk '/^    \[\(ForeachActive lane body\)$/ { skip = 1; next }
             skip { if ($0 ~ /\)\]$/) skip = 0; next } { print }' "$CORE" > "$work/omit-arm.tl"
        if cmp -s "$CORE" "$work/omit-arm.tl"; then
            echo "binder-audit self-test: could not remove the ForeachActive arm" >&2; exit 1
        fi
        if AUDIT_CORE="$work/omit-arm.tl" "$0" > "$work/omit-arm.out" 2>&1; then
            echo "binder-audit self-test: an omitted binder arm passed" >&2; exit 1
        fi
        grep -v "$(printf '^field\tForeachActive\tlane\t')" "$TABLE" > "$work/omit-field.tsv"
        if AUDIT_TABLE="$work/omit-field.tsv" "$0" > "$work/omit-field.out" 2>&1; then
            echo "binder-audit self-test: an unlisted passthrough field passed" >&2; exit 1
        fi
        # A list map macro that gains an unlisted name, or stops passing one
        # through, must fail: helper fields are derived, not asserted.
        sed 's/(AstParam\.Param name ty is-comptime)/(AstParam.Param name ty is-comptime audit-extra)/;
             s/(AstParam\.Param name (,on-type ,@contexts ty) is-comptime)/(AstParam.Param name (,on-type ,@contexts ty) is-comptime audit-extra)/' \
            "$AST" > "$work/helper-extra.tl"
        if cmp -s "$AST" "$work/helper-extra.tl" || AUDIT_AST="$work/helper-extra.tl" "$0" > "$work/helper-extra.out" 2>&1; then
            echo "binder-audit self-test: an unlisted list-macro name passed" >&2; exit 1
        fi
        sed 's/(AstParam\.Param name (,on-type ,@contexts ty) is-comptime)/(AstParam.Param 0 (,on-type ,@contexts ty) is-comptime)/' \
            "$AST" > "$work/helper-drop.tl"
        if cmp -s "$AST" "$work/helper-drop.tl" || AUDIT_AST="$work/helper-drop.tl" "$0" > "$work/helper-drop.out" 2>&1; then
            echo "binder-audit self-test: a list-macro name no longer passed through still passed" >&2; exit 1
        fi
        # A citation must name the constructor in the cited function.
        awk -F '\t' 'BEGIN { OFS = FS } $1 == "ctor" && $2 == "Var" { $6 = "src/compiler_typecheck_core.tl#tc-with-region-binder" } { print }' \
            "$TABLE" > "$work/bad-cite.tsv"
        if AUDIT_TABLE="$work/bad-cite.tsv" "$0" > "$work/bad-cite.out" 2>&1; then
            echo "binder-audit self-test: a citation of a function not naming the constructor passed" >&2; exit 1
        fi
        # Line drift elsewhere in the checker must not break the audit.
        { awk 'BEGIN { for (i = 0; i < 500; i++) print ";; drift" }'; cat "$CORE"; } > "$work/drift.tl"
        if ! AUDIT_CORE="$work/drift.tl" "$0" > "$work/drift.out" 2>&1; then
            echo "binder-audit self-test: 500 lines of drift broke the audit" >&2; exit 1
        fi
        echo "binder-audit self-test: passed"
        ;;
    "")
        work=$(new_work)
        audit "$work"
        echo "binder-audit: $(wc -l < "$work/ctors" | tr -d ' ') AstExpr constructors and $(wc -l < "$work/passthrough" | tr -d ' ') passthrough fields classified"
        ;;
    *) echo "usage: $0 [--self-test|--markdown]" >&2; exit 2 ;;
esac
