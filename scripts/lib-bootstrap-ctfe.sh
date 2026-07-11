#!/usr/bin/env sh

# lib-bootstrap-ctfe.sh - seed compatibility selection for CTFE loop bootstrap.
#
# A published seed that predates CTFE `while` can still build the first compiler
# through bootstrap/stdlib/core_macros.tl. Newer seeds must use the normal
# iterative macros, so probe the actual capability instead of permanently
# pinning every bootstrap to the legacy expansion path.

bootstrap_seed_ctfe_while_legacy_stdlib() {
    root=$1
    compiler=$2
    workdir=$3
    stdout="$workdir/seed-ctfe-while-probe.stdout"
    stderr="$workdir/seed-ctfe-while-probe.stderr"
    legacy_stdlib="$root/bootstrap/stdlib"
    probe_cwd="$workdir/seed-ctfe-while-probe-cwd"
    mkdir -p "$probe_cwd"

    # The compiler gives a local ./stdlib precedence over --stdlib-root. Run
    # from a scratch directory so the legacy prelude actually wins.
    if (
        cd "$probe_cwd"
        "$compiler" check "$root/tests/bootstrap_ctfe_while_probe.tl" \
            --stdlib-root "$legacy_stdlib" \
            --stdlib-root "$root/stdlib" \
            --stdlib-root "$root/src"
    ) > "$stdout" 2> "$stderr"; then
        return 0
    fi

    if grep -qF "'while' is not supported in compile-time evaluation" \
        "$stdout" "$stderr"; then
        printf '%s\n' "$legacy_stdlib"
        return 0
    fi

    echo "[bootstrap] seed CTFE while capability probe failed unexpectedly" >&2
    echo "[bootstrap] stdout:" >&2
    sed 's/^/  /' "$stdout" >&2 || true
    echo "[bootstrap] stderr:" >&2
    sed 's/^/  /' "$stderr" >&2 || true
    return 1
}
