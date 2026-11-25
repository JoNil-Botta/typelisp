# lib-ci-local.sh — local-only acceleration for scripts/ci-affected.sh --run.
#
# ci-affected.sh --run sets two internal variables, and only outside hosted CI:
#   TYPELISP_CI_LOCAL_CACHE        root of the content-addressed bootstrap cache
#   TYPELISP_CI_LOCAL_SCOPE_PATHS  the run's changed-path inventory
# Hosted CI (GITHUB_ACTIONS=true) and a direct scripts/ci-verify.sh never set
# them, so there every gate bootstraps from scratch and checks its full corpus.
# A script that sees either one under GITHUB_ACTIONS=true fails closed.
#
# Source it (not exec). POSIX sh only — no `local`, arrays, or bashisms.

ci_local_require_not_hosted() {
    if [ "${GITHUB_ACTIONS:-}" = true ] &&
        { [ -n "${TYPELISP_CI_LOCAL_CACHE:-}" ] || [ -n "${TYPELISP_CI_LOCAL_SCOPE_PATHS:-}" ]; }; then
        echo "[ci-local] TYPELISP_CI_LOCAL_CACHE/TYPELISP_CI_LOCAL_SCOPE_PATHS are local-only; hosted CI runs every gate from scratch over its full corpus" >&2
        exit 2
    fi
}

# --- Changed-file scoping -------------------------------------------------

# ci_local_scope_active
#   True when the changed-path inventory is readable and nonempty and no path
#   touches src/, stdlib/ or scripts/: those change what every formatter, lint,
#   doc and corpus check computes, so only the full corpus covers them. A quoted
#   (unusual) path also keeps the full corpus.
ci_local_scope_active() {
    ci_local_require_not_hosted
    _cls_paths=${TYPELISP_CI_LOCAL_SCOPE_PATHS:-}
    [ -n "$_cls_paths" ] && [ -f "$_cls_paths" ] && [ -r "$_cls_paths" ] && [ -s "$_cls_paths" ] || return 1
    ! grep -E '^("|src/|stdlib/|scripts/)' "$_cls_paths" > /dev/null
}

# ci_local_scope_filter CANDIDATES OUT
#   Write to OUT the CANDIDATES lines (repository-relative paths, one per line,
#   order kept) that the change touches: a changed path itself, or a file that
#   names a changed .tl file's module (its basename) and so may import it.
ci_local_scope_filter() {
    _clsf_names="$2.names"
    _clsf_touched="$2.touched"
    sed -n 's#^\(.*/\)\{0,1\}\([^/]*\)\.tl$#\2#p' "$TYPELISP_CI_LOCAL_SCOPE_PATHS" | LC_ALL=C sort -u > "$_clsf_names"
    {
        cat "$TYPELISP_CI_LOCAL_SCOPE_PATHS"
        if [ -s "$_clsf_names" ]; then
            tr '\n' '\0' < "$1" | xargs -0 grep -l -s -F -w -f "$_clsf_names" -- || :
        fi
    } > "$_clsf_touched"
    awk 'NR == FNR { touched[$0] = 1; next } ($0 in touched)' "$_clsf_touched" "$1" > "$2"
    rm -f "$_clsf_names" "$_clsf_touched"
}

# ci_local_scope_report LABEL SCOPED FULL
#   Announce a scoped run so its log never reads as a full-corpus check.
ci_local_scope_report() {
    echo "[$1] local changed-file scope: $(wc -l < "$2" | tr -d ' ') of $(wc -l < "$3" | tr -d ' ') file(s); hosted CI checks the full corpus"
}

# --- Content-addressed bootstrap cache ------------------------------------
#
# An entry holds what the bootstrap-compiler gate leaves for later gates: the
# stage compilers, the fixpoint assembly, the stdlib sysroot, the build
# identity stamps and the embedded stdlib image. Its key hashes every input of
# that build, so a hit is the same build the gate would make again. compiler.ok
# marks a passed bootstrap-compiler gate (the stage fixpoint, the CLI smoke
# checks and the sysroot), fixpoint.ok a passed embedded-provenance parity.

# The scripts the bootstrap runs; the source trees are hashed whole.
CI_LOCAL_CACHE_SCRIPTS="scripts/ci-verify.sh scripts/check-bootstrap-fixpoint.sh
scripts/build-stdlib-sysroot.sh scripts/build-embedded-stdlib-tlci.sh
scripts/lib-native-link.sh scripts/lib-bootstrap-fixpoint-control.sh
scripts/lib-build-provenance.sh scripts/lib-ci-compiler-artifact.sh
scripts/lib-bounded-pool.sh scripts/lib-ci-timing.sh scripts/lib-ci-local.sh"
CI_LOCAL_CACHE_TREES="src stdlib tests/fixtures tools/embedded-stdlib-tlci"
CI_LOCAL_CACHE_KEEP=3

# ci_local_cache_key ROOT SEED
#   Echo the sha256 key of the bootstrap inputs under ROOT built from SEED.
ci_local_cache_key() {
    [ -f "$2" ] && [ -r "$2" ] || return 1
    _clck_seed=$(sha256sum < "$2" | cut -c 1-64) || return 1
    (
        cd "$1" || exit 1
        {
            printf 'ci-local-cache v1\n%s\nseed %s\n' "$(uname -sm)" "$_clck_seed"
            for _clck_tree in $CI_LOCAL_CACHE_TREES; do
                [ ! -d "$_clck_tree" ] || find "$_clck_tree" -type f -print0
            done | LC_ALL=C sort -z | xargs -0 -r sha256sum
            for _clck_script in $CI_LOCAL_CACHE_SCRIPTS; do
                [ ! -f "$_clck_script" ] || sha256sum "$_clck_script"
            done
        } | sha256sum | cut -c 1-64
    )
}

# ci_local_cache_valid ENTRY
#   True when ENTRY holds a passed bootstrap-compiler gate whose files still
#   match the checksums recorded when it was stored.
ci_local_cache_valid() {
    [ -n "$1" ] && [ -f "$1/compiler.ok" ] && [ -s "$1/SHA256SUMS" ] && [ -s "$1/converged" ] || return 1
    (cd "$1" && sha256sum -c --quiet --strict SHA256SUMS) > /dev/null 2>&1
}

# ci_local_cache_store ENTRY ROOT WORKDIR CONVERGED_BIN
#   Record the bootstrap-compiler gate's outputs under ENTRY, atomically, and
#   keep only the newest CI_LOCAL_CACHE_KEEP entries.
ci_local_cache_store() {
    _clcs_tmp="$1.tmp.$$"
    rm -rf "$_clcs_tmp"
    mkdir -p "$_clcs_tmp/bootstrap-fixpoint" "$_clcs_tmp/build-stage0" "$_clcs_tmp/embedded-stdlib-tlci" || return 1
    for _clcs_file in "$3"/stage1 "$3"/stage2 "$3"/stage3 "$3"/stage4 \
        "$3"/stage1.exe "$3"/stage2.exe "$3"/stage3.exe "$3"/stage4.exe "$3"/stage3.s "$3"/stage4.s; do
        [ ! -f "$_clcs_file" ] || cp -p "$_clcs_file" "$_clcs_tmp/bootstrap-fixpoint/" || return 1
    done
    cp -R "$3/lib" "$_clcs_tmp/bootstrap-fixpoint/lib" || return 1
    cp "$2/target/build-stage0/git-hash.txt" "$2/target/build-stage0/tree-hash.txt" \
        "$_clcs_tmp/build-stage0/" || return 1
    find "$2/target/embedded-stdlib-tlci" -maxdepth 1 -type f \
        -exec cp {} "$_clcs_tmp/embedded-stdlib-tlci/" \; || return 1
    basename -- "$4" > "$_clcs_tmp/converged"
    (cd "$_clcs_tmp" && find bootstrap-fixpoint build-stage0 embedded-stdlib-tlci converged -type f -print0 |
        LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS) || return 1
    basename -- "$1" > "$_clcs_tmp/compiler.ok"
    rm -rf "$1"
    mv "$_clcs_tmp" "$1" || return 1
    _clcs_root=$(dirname -- "$1")
    ls -1t "$_clcs_root" | grep -E '^[0-9a-f]{64}$' | sed "1,${CI_LOCAL_CACHE_KEEP}d" |
        while IFS= read -r _clcs_old; do rm -rf "${_clcs_root:?}/$_clcs_old"; done
    echo "[ci-local] stored bootstrap cache entry $1"
}

# ci_local_cache_restore ENTRY ROOT WORKDIR STAGE1_PATH_FILE STAGE2_PATH_FILE
#   Put a valid entry's outputs back where the bootstrap-compiler gate leaves
#   them and write its two compiler handoff path files.
ci_local_cache_restore() {
    ci_local_cache_valid "$1" || return 1
    rm -rf "$3"
    mkdir -p "$3" "$2/target/build-stage0" "$2/target/embedded-stdlib-tlci" || return 1
    cp -Rp "$1/bootstrap-fixpoint/." "$3/" || return 1
    cp "$1/build-stage0/"* "$2/target/build-stage0/" || return 1
    cp "$1/embedded-stdlib-tlci/"* "$2/target/embedded-stdlib-tlci/" || return 1
    _clcr_suffix=
    [ ! -f "$3/stage1.exe" ] || _clcr_suffix=.exe
    printf '%s\n' "$3/stage1$_clcr_suffix" > "$4"
    printf '%s\n' "$3/$(cat "$1/converged")" > "$5"
    touch "$1"
    echo "[ci-local] restored bootstrap cache entry $1 (built at commit $(cat "$1/build-stage0/git-hash.txt"))"
}
