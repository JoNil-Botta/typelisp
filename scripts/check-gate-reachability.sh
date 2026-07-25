#!/usr/bin/env sh
set -eu

# check-gate-reachability.sh - fail closed on unreferenced check-*/verify-*
# gates.
#
# README.md promises that the CI verification entry point runs "the same gate as
# CI" and that "every remaining gate runs on the freshly bootstrapped compiler".
# Nothing enforced that promise: the perfbench-gathers and point-transform ISPC
# correctness gates sat in scripts/ with zero references for months (#5690).
# Their corpora, case.tsv metadata contracts, and C oracles were never executed,
# and no gate noticed, because a script that nobody calls fails nothing.
#
# This gate is a reachability sweep. The workflow files are the roots; every
# `scripts/<name>.(sh|ps1|awk)` reference is followed transitively; and every
# top-level check-* and verify-* script must be reached. A gate that is
# deliberately not wired is listed with a reason in the optional-gate allowlist
# beside this script, which is itself checked for stale and malformed entries.
#
# Deliberately, this file spells no gate path in prose: a reachable script's
# comments are indistinguishable from its commands to a textual sweep, so a
# mention here would make the mentioned gate look wired.
#
# The sweep is intentionally textual and cheap: it runs before the bootstrap and
# never invokes a compiler.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

ALLOWLIST=scripts/optional-gate-allowlist.tsv
WORKDIR=target/gate-reachability
TAB=$(printf '\t')

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-gate-reachability.sh [--self-test]

Requires every scripts/check-*.sh and scripts/verify-*.sh to be reachable from
a .github/workflows entry point, or listed with a reason in
scripts/optional-gate-allowlist.tsv.
EOF
}

SELF_TEST=0
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "${1:-}" = "--self-test" ]; then
    SELF_TEST=1
    shift
fi
if [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

# Every textual reference to a repository script, however it is spelled: a bare
# `scripts/foo.sh` argument, a `"$ROOT/scripts/foo.sh"` source, or a workflow
# `run:` line.
extract_refs() {
    grep -Eo 'scripts/[A-Za-z0-9_.+-]+\.(sh|ps1|awk)' "$1" 2>/dev/null | sort -u
}

# Reachable set: breadth-first from the workflow files, following script
# references transitively. Documentation is never a root -- a script mentioned
# only by README.md is still dead weight in CI.
collect_reachable() {
    _base=$1
    _work=$2
    _reached="$_work/reached.txt"
    _frontier="$_work/frontier.txt"
    _current="$_work/current.txt"

    : > "$_reached"
    : > "$_frontier"

    _roots=0
    for _wf in "$_base"/.github/workflows/*.yml "$_base"/.github/workflows/*.yaml; do
        [ -f "$_wf" ] || continue
        _roots=$((_roots + 1))
        printf '%s\n' "$_wf" >> "$_frontier"
    done
    if [ "$_roots" -eq 0 ]; then
        echo "[gate-reachability] no workflow roots under $_base/.github/workflows" >&2
        return 1
    fi

    while [ -s "$_frontier" ]; do
        mv "$_frontier" "$_current"
        : > "$_frontier"
        while IFS= read -r _file; do
            extract_refs "$_file" | while IFS= read -r _ref; do
                _path="$_base/$_ref"
                [ -f "$_path" ] || continue
                if grep -Fxq "$_ref" "$_reached"; then
                    continue
                fi
                printf '%s\n' "$_ref" >> "$_reached"
                printf '%s\n' "$_path" >> "$_frontier"
            done
        done < "$_current"
    done

    sort -u "$_reached" -o "$_reached"
}

check_tree() {
    _base=$1
    _allowlist=$2
    _work=$3

    rm -rf "$_work"
    mkdir -p "$_work"
    collect_reachable "$_base" "$_work" || return 1

    _reached="$_work/reached.txt"
    _required="$_work/required.txt"
    _allowed="$_work/allowed.txt"
    _errors=0

    : > "$_required"
    for _script in "$_base"/scripts/check-*.sh "$_base"/scripts/verify-*.sh \
        "$_base"/scripts/check-*.ps1 "$_base"/scripts/verify-*.ps1; do
        [ -f "$_script" ] || continue
        printf 'scripts/%s\n' "$(basename "$_script")" >> "$_required"
    done
    sort -u "$_required" -o "$_required"
    if [ ! -s "$_required" ]; then
        echo "[gate-reachability] no check-*/verify-* gates found under $_base/scripts" >&2
        return 1
    fi

    : > "$_allowed"
    if [ ! -f "$_allowlist" ]; then
        echo "[gate-reachability] missing optional-gate allowlist: $_allowlist" >&2
        return 1
    fi
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            '' | '#'*) continue ;;
        esac
        _entry=${_line%%"$TAB"*}
        _reason=${_line#*"$TAB"}
        if [ "$_reason" = "$_line" ] || [ -z "$_reason" ]; then
            echo "[gate-reachability] ERROR: allowlist row lacks a tab-separated reason: $_line" >&2
            _errors=$((_errors + 1))
            continue
        fi
        if ! grep -Fxq "$_entry" "$_required"; then
            echo "[gate-reachability] ERROR: allowlist entry is not a check-*/verify-* gate: $_entry" >&2
            _errors=$((_errors + 1))
            continue
        fi
        if grep -Fxq "$_entry" "$_reached"; then
            echo "[gate-reachability] ERROR: stale allowlist entry is wired after all: $_entry" >&2
            _errors=$((_errors + 1))
            continue
        fi
        if grep -Fxq "$_entry" "$_allowed"; then
            echo "[gate-reachability] ERROR: duplicate allowlist entry: $_entry" >&2
            _errors=$((_errors + 1))
            continue
        fi
        printf '%s\n' "$_entry" >> "$_allowed"
    done < "$_allowlist"
    sort -u "$_allowed" -o "$_allowed"

    _orphans="$_work/orphans.txt"
    comm -23 "$_required" "$_reached" > "$_work/unreached.txt"
    comm -23 "$_work/unreached.txt" "$_allowed" > "$_orphans"
    if [ -s "$_orphans" ]; then
        while IFS= read -r _orphan; do
            echo "[gate-reachability] ERROR: gate is never invoked: $_orphan" >&2
            _errors=$((_errors + 1))
        done < "$_orphans"
        echo "[gate-reachability] wire it into scripts/ci-verify.sh (or a workflow)," >&2
        echo "[gate-reachability] or record it with a reason in $_allowlist." >&2
    fi

    if [ "$_errors" -ne 0 ]; then
        return 1
    fi

    printf '[gate-reachability] %s gates, %s reachable, %s allowlisted\n' \
        "$(wc -l < "$_required" | tr -d ' ')" \
        "$(comm -12 "$_required" "$_reached" | wc -l | tr -d ' ')" \
        "$(wc -l < "$_allowed" | tr -d ' ')"
}

# This script is itself reachable, so the sweep follows its text. A gate named
# anywhere in it -- prose, hint string, fixture heredoc -- would be reported as
# reachable purely because this file mentioned it, which is exactly the failure
# the gate exists to catch. Self-references (usage strings) are fine.
check_no_gate_mentions() {
    _base=$1
    _file=$2
    _self="scripts/$(basename "$_file")"
    _mentions=$(extract_refs "$_file" |
        grep -E '^scripts/(check|verify)-' |
        grep -Fxv "$_self" |
        while IFS= read -r _candidate; do
            # Only a mention that resolves to a real gate can fake reachability;
            # self-test fixture names never exist in the tree.
            if [ -f "$_base/$_candidate" ]; then
                printf '%s\n' "$_candidate"
            fi
        done || true)
    if [ -n "$_mentions" ]; then
        echo "[gate-reachability] ERROR: $_file names other gates:" >&2
        printf '%s\n' "$_mentions" | while IFS= read -r _mention; do
            echo "[gate-reachability]   $_mention" >&2
        done
        echo "[gate-reachability] a reachable script's comments look like commands to" >&2
        echo "[gate-reachability] a textual sweep; describe gates without their paths." >&2
        return 1
    fi
}

# Fixture names are deliberately unlike any real script: the production sweep
# reads this file, so a fixture that shared a name with a repository gate would
# mark that gate reachable from here.
write_fixture_tree() {
    _tree=$1
    rm -rf "$_tree"
    mkdir -p "$_tree/.github/workflows" "$_tree/scripts"
    cat > "$_tree/.github/workflows/ci.yml" <<'EOF'
jobs:
  ci:
    steps:
      - run: scripts/selftest-entry.sh
EOF
    cat > "$_tree/scripts/selftest-entry.sh" <<'EOF'
#!/usr/bin/env sh
scripts/verify-selftest-wired.sh
EOF
    cat > "$_tree/scripts/verify-selftest-wired.sh" <<'EOF'
#!/usr/bin/env sh
. "$ROOT/scripts/check-selftest-transitive.sh"
EOF
    printf '#!/usr/bin/env sh\n' > "$_tree/scripts/check-selftest-transitive.sh"
    printf '#!/usr/bin/env sh\n' > "$_tree/scripts/verify-selftest-orphan.sh"
    printf '# optional-gate-allowlist-schema\t1\n' > "$_tree/allowlist.tsv"
}

expect_tree() {
    _label=$1
    _expectation=$2
    _tree=$3
    _out=$4
    _status=0
    check_tree "$_tree" "$_tree/allowlist.tsv" "$_tree/work" > "$_out" 2>&1 || _status=$?
    case "$_expectation:$_status" in
        pass:0) ;;
        fail:0)
            echo "[gate-reachability] self-test $_label unexpectedly passed" >&2
            cat "$_out" >&2
            return 1
            ;;
        fail:*) ;;
        pass:*)
            echo "[gate-reachability] self-test $_label unexpectedly failed" >&2
            cat "$_out" >&2
            return 1
            ;;
    esac
}

self_test() {
    _root="$WORKDIR-self-test"
    rm -rf "$_root"
    mkdir -p "$_root"

    # An unreferenced verify-* gate is the #5690 shape and must fail closed.
    write_fixture_tree "$_root/orphan"
    expect_tree orphan fail "$_root/orphan" "$_root/orphan.out"
    grep -F 'gate is never invoked: scripts/verify-selftest-orphan.sh' \
        "$_root/orphan.out" >/dev/null
    grep -F 'or record it with a reason in' "$_root/orphan.out" >/dev/null

    # Transitive reachability counts: check-selftest-transitive.sh is only ever
    # named by verify-selftest-wired.sh, which the workflow reaches through the
    # fixture entry point.
    if grep -F 'check-selftest-transitive.sh' "$_root/orphan.out" >/dev/null; then
        echo "[gate-reachability] self-test transitive reachability regressed" >&2
        return 1
    fi

    # Wiring the orphan clears the failure.
    write_fixture_tree "$_root/wired"
    printf 'scripts/verify-selftest-orphan.sh\n' \
        >> "$_root/wired/scripts/selftest-entry.sh"
    expect_tree wired pass "$_root/wired" "$_root/wired.out"
    grep -F '3 gates, 3 reachable, 0 allowlisted' "$_root/wired.out" >/dev/null

    # An explicit allowlist entry with a reason also clears it.
    write_fixture_tree "$_root/allowed"
    printf 'scripts/verify-selftest-orphan.sh\tlocal-only comparison\n' \
        >> "$_root/allowed/allowlist.tsv"
    expect_tree allowed pass "$_root/allowed" "$_root/allowed.out"
    grep -F '3 gates, 2 reachable, 1 allowlisted' "$_root/allowed.out" >/dev/null

    # A reason is mandatory; a bare script name is not an allowlist entry.
    write_fixture_tree "$_root/no-reason"
    printf 'scripts/verify-selftest-orphan.sh\n' >> "$_root/no-reason/allowlist.tsv"
    expect_tree no-reason fail "$_root/no-reason" "$_root/no-reason.out"
    grep -F 'allowlist row lacks a tab-separated reason' "$_root/no-reason.out" >/dev/null

    # Allowlisting a wired gate is stale state and must be reported.
    write_fixture_tree "$_root/stale"
    printf 'scripts/verify-selftest-wired.sh\tstale entry\n' \
        >> "$_root/stale/allowlist.tsv"
    expect_tree stale fail "$_root/stale" "$_root/stale.out"
    grep -F 'stale allowlist entry is wired after all: scripts/verify-selftest-wired.sh' \
        "$_root/stale.out" >/dev/null

    # The allowlist cannot smuggle in a script that is not a gate at all.
    write_fixture_tree "$_root/unknown"
    printf 'scripts/measure-selftest-thing.sh\toptional local tool\n' \
        >> "$_root/unknown/allowlist.tsv"
    expect_tree unknown fail "$_root/unknown" "$_root/unknown.out"
    grep -F 'allowlist entry is not a check-*/verify-* gate' "$_root/unknown.out" >/dev/null

    # Duplicate rows hide a second, unreviewed reason behind the first.
    write_fixture_tree "$_root/duplicate"
    printf 'scripts/verify-selftest-orphan.sh\tfirst reason\n' \
        >> "$_root/duplicate/allowlist.tsv"
    printf 'scripts/verify-selftest-orphan.sh\tsecond reason\n' \
        >> "$_root/duplicate/allowlist.tsv"
    expect_tree duplicate fail "$_root/duplicate" "$_root/duplicate.out"
    grep -F 'duplicate allowlist entry: scripts/verify-selftest-orphan.sh' \
        "$_root/duplicate.out" >/dev/null

    # A missing allowlist file fails closed rather than silently allowing all.
    write_fixture_tree "$_root/missing"
    rm -f "$_root/missing/allowlist.tsv"
    expect_tree missing fail "$_root/missing" "$_root/missing.out"
    grep -F 'missing optional-gate allowlist' "$_root/missing.out" >/dev/null

    # Self-mention detection: a usage string is fine, an existing gate's path is
    # not, and a name that resolves to nothing is not a false reachability edge.
    write_fixture_tree "$_root/mentions"
    _probe="$_root/mentions/scripts/check-selftest-mentions.sh"
    printf 'usage: scripts/check-selftest-mentions.sh\n' > "$_probe"
    printf '# see scripts/verify-selftest-absent.sh\n' >> "$_probe"
    if ! check_no_gate_mentions "$_root/mentions" "$_probe" \
        2> "$_root/mentions-self.out"; then
        echo "[gate-reachability] self-test rejected a harmless mention" >&2
        cat "$_root/mentions-self.out" >&2
        return 1
    fi
    printf '# see scripts/verify-selftest-orphan.sh\n' >> "$_probe"
    if check_no_gate_mentions "$_root/mentions" "$_probe" \
        2> "$_root/mentions-other.out"; then
        echo "[gate-reachability] self-test accepted a foreign gate mention" >&2
        return 1
    fi
    grep -F 'scripts/verify-selftest-orphan.sh' "$_root/mentions-other.out" >/dev/null

    echo "gate reachability self-tests passed"
}

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
fi

check_no_gate_mentions "$ROOT" "$ROOT/scripts/$(basename "$0")"
check_tree "$ROOT" "$ROOT/$ALLOWLIST" "$ROOT/$WORKDIR"
