#!/usr/bin/env sh
set -eu

# verify-stdlib-docs.sh - generate and test docs for canonical stdlib modules.
#
# The public `typelisp doc` command currently runs the selfhost Markdown
# generator through a native compile/run path, which is Linux-only until the doc
# command grows target selection. The doctest subcommand still routes through the
# Rust path; keep this script separate so it can switch to the selfhost doctest
# path when #865 lands.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "stdlib doc verification is Linux-only until typelisp doc supports non-default targets" >&2
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/stdlib-docs"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

MODULES="$WORKDIR/modules.txt"
find stdlib -maxdepth 1 -type f -name '*.tl' | sort > "$MODULES"

if [ ! -s "$MODULES" ]; then
    echo "no stdlib modules found" >&2
    exit 1
fi

check_source_docs() {
    module=$1
    if ! grep -q '^;;;;' "$module"; then
        echo "stdlib doc verification failed: $module has no module docs" >&2
        exit 1
    fi
    if ! grep -q '^;;;[^;]' "$module"; then
        echo "stdlib doc verification failed: $module has no item docs" >&2
        exit 1
    fi
    if ! awk '
        BEGIN {
            pending_doc = 0
            missing = 0
        }
        /^[[:space:]]*;;;;/ {
            pending_doc = 0
            next
        }
        /^[[:space:]]*;;;($|[^;])/ {
            pending_doc = 1
            next
        }
        /^[[:space:]]*$/ {
            next
        }
        /^\((define|defenum|defstruct|extern)([[:space:]]|\()/ {
            if (!pending_doc) {
                printf "%s:%d: missing item docs before %s\n", FILENAME, NR, $0
                missing = 1
            }
            pending_doc = 0
            next
        }
        {
            pending_doc = 0
        }
        END {
            exit missing
        }
    ' "$module"; then
        echo "stdlib doc verification failed: $module has undocumented top-level declarations" >&2
        exit 1
    fi
}

check_markdown() {
    module=$1
    markdown=$2
    if [ ! -s "$markdown" ]; then
        echo "stdlib doc verification failed: $module generated empty Markdown" >&2
        exit 1
    fi
    if grep -q '_No documented declarations._' "$markdown"; then
        echo "stdlib doc verification failed: $module generated no documented declarations" >&2
        exit 1
    fi
    if ! grep -q '^# TypeLisp Documentation' "$markdown"; then
        echo "stdlib doc verification failed: $module Markdown has no title" >&2
        exit 1
    fi
}

module_count=0
while IFS= read -r module; do
    [ -n "$module" ] || continue
    module_count=$((module_count + 1))
    name=$(basename "$module" .tl)
    markdown="$WORKDIR/$name.md"
    doc_stdout="$WORKDIR/$name.doc.stdout"
    doc_stderr="$WORKDIR/$name.doc.stderr"
    test_stdout="$WORKDIR/$name.doctest.stdout"
    test_stderr="$WORKDIR/$name.doctest.stderr"

    check_source_docs "$module"

    echo "[stdlib-docs] generate $module"
    if ! "$COMPILER" doc "$module" -o "$markdown" --stdlib-root "$ROOT/stdlib" \
        > "$doc_stdout" 2> "$doc_stderr"; then
        echo "doc stdout:" >&2
        sed 's/^/  /' "$doc_stdout" >&2
        echo "doc stderr:" >&2
        sed 's/^/  /' "$doc_stderr" >&2
        exit 1
    fi
    check_markdown "$module" "$markdown"

    echo "[stdlib-docs] doctest $module"
    if ! "$COMPILER" doc --test "$module" --stdlib-root "$ROOT/stdlib" \
        > "$test_stdout" 2> "$test_stderr"; then
        echo "doctest stdout:" >&2
        sed 's/^/  /' "$test_stdout" >&2
        echo "doctest stderr:" >&2
        sed 's/^/  /' "$test_stderr" >&2
        exit 1
    fi
    if ! grep -q '^Doc tests passed:' "$test_stdout"; then
        echo "stdlib doc verification failed: $module doctest output did not report success" >&2
        sed 's/^/  /' "$test_stdout" >&2
        exit 1
    fi
done < "$MODULES"

INDEX_SRC="$WORKDIR/stdlib_index.tl"
INDEX_MD="$WORKDIR/stdlib_index.md"
{
    printf ';;;; Stdlib module index.\n\n'
    while IFS= read -r module; do
        [ -n "$module" ] || continue
        printf '(import "stdlib/%s")\n' "$(basename "$module")"
    done < "$MODULES"
} > "$INDEX_SRC"

echo "[stdlib-docs] generate stdlib module graph"
if ! "$COMPILER" doc "$INDEX_SRC" -o "$INDEX_MD" --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/index.doc.stdout" 2> "$WORKDIR/index.doc.stderr"; then
    echo "index doc stdout:" >&2
    sed 's/^/  /' "$WORKDIR/index.doc.stdout" >&2
    echo "index doc stderr:" >&2
    sed 's/^/  /' "$WORKDIR/index.doc.stderr" >&2
    exit 1
fi

while IFS= read -r module; do
    [ -n "$module" ] || continue
    if ! grep -q "stdlib/$(basename "$module")" "$INDEX_MD"; then
        echo "stdlib doc verification failed: index is missing $module" >&2
        exit 1
    fi
done < "$MODULES"

echo "stdlib doc verification passed for $module_count module(s)"
