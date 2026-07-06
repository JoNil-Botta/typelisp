# lib-stage0.sh — shared stage0 compiler resolver for verify-*/check-* scripts.
#
# With the Rust compiler removed (#795), scripts that previously fell back to a
# local `cargo build --release` when TYPELISP_BIN was unset now fall back to the
# published self-hosted stage0 compiler instead. CI always sets TYPELISP_BIN
# explicitly (the CI gate fetches stage0 once and threads it through every
# gate), so this fallback only fires for local developer runs that did not set
# TYPELISP_BIN.
#
# Source it (not exec): `. "$ROOT/scripts/lib-stage0.sh"`. POSIX sh only — no
# `local`, arrays, or bashisms.

# stage0_host_exe_suffix
#   Echo the host executable suffix (".exe" on Windows Git Bash/MSYS/Cygwin,
#   empty elsewhere).
stage0_host_exe_suffix() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) printf '%s\n' ".exe" ;;
        *) printf '%s\n' "" ;;
    esac
}

# stage0_compiler_path ROOT
#   Echo the default published stage0 compiler path for this host.
stage0_compiler_path() {
    _ls0_root=$1
    _ls0_dir=${TYPELISP_STAGE0_DIR:-target/stage0}
    case "$_ls0_dir" in
        /*) : ;;
        *) _ls0_dir="$_ls0_root/$_ls0_dir" ;;
    esac
    _ls0_suffix=$(stage0_host_exe_suffix)
    printf '%s\n' "$_ls0_dir/typelisp$_ls0_suffix"
}

# fetch_stage0_compiler ROOT
#   Refresh the published stage0 compiler using the repository fetch script.
fetch_stage0_compiler() {
    _ls0_root=$1
    "$_ls0_root/scripts/fetch-stage0.sh" >&2
}

# resolve_stage0_compiler ROOT
#   Echo the path to a usable stage0 compiler. Always refreshes the
#   published stage0 first so mutable stage0-latest caches do not silently go
#   stale. Honours the same TYPELISP_STAGE0_* environment knobs as
#   scripts/fetch-stage0.sh.
resolve_stage0_compiler() {
    _ls0_root=$1
    fetch_stage0_compiler "$_ls0_root" || return 1
    _ls0_bin=$(stage0_compiler_path "$_ls0_root")
    if [ ! -x "$_ls0_bin" ]; then
        echo "stage0 compiler unavailable after fetch: $_ls0_bin" >&2
        echo "set TYPELISP_BIN to a stage0 binary, or run scripts/fetch-stage0.sh" >&2
        return 1
    fi
    printf '%s\n' "$_ls0_bin"
}

# selfhost_stage2_path OUT_DIR
#   Echo the stage2 compiler path build_selfhost_stage2 produces under OUT_DIR.
#   Pure string construction so callers recover the path without capturing build
#   output (build-stage0.sh's heartbeat runs in the background and can write to
#   the original stdout, so a command-substituted build is not a safe way to
#   read the path back).
selfhost_stage2_path() {
    printf '%s\n' "$1/stage2/typelisp$(stage0_host_exe_suffix)"
}

# build_selfhost_stage2 ROOT SEED OUT_DIR
#   Build the fixpoint opt2 stage2 compiler from SEED under OUT_DIR. Runs
#   scripts/build-stage0.sh twice (SEED -> stage1 -> stage2); that script
#   compiles src/main.tl at --opt-level 2, so the result is the same
#   register-allocated, self-hosted compiler that the published stage0 and the
#   check-instruction-counts.sh CI gate measure. Local self-compile measurement
#   and profiling must run this compiler, not the raw seed: the seed is an older
#   build whose per-function codegen differs, so measuring it does not reflect
#   the metric CI ratchets (self_compile/compile_cli_opt1). All build output goes
#   to stderr; recover the resulting compiler path with selfhost_stage2_path.
build_selfhost_stage2() {
    _bss_root=$1
    _bss_seed=$2
    _bss_dir=$3
    _bss_suffix=$(stage0_host_exe_suffix)
    _bss_stage1="$_bss_dir/stage1/typelisp$_bss_suffix"
    _bss_stage2=$(selfhost_stage2_path "$_bss_dir")
    mkdir -p "$_bss_dir/stage1" "$_bss_dir/stage2" || return 1
    {
        echo "[stage2-build] seed -> stage1: $_bss_stage1"
        "$_bss_root/scripts/build-stage0.sh" "$_bss_seed" "$_bss_stage1" || return 1
        echo "[stage2-build] stage1 -> stage2 (opt2): $_bss_stage2"
        "$_bss_root/scripts/build-stage0.sh" "$_bss_stage1" "$_bss_stage2" || return 1
    } >&2
}
