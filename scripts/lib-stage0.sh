# lib-stage0.sh — shared no-Rust stage0 compiler resolver for verify-*/check-* scripts.
#
# With the Rust compiler removed (#795), scripts that previously fell back to a
# local `cargo build --release` when TYPELISP_BIN was unset now fall back to the
# published self-hosted stage0 compiler instead. CI always sets TYPELISP_BIN
# explicitly (the no-Rust gate fetches stage0 once and threads it through every
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

# resolve_stage0_compiler ROOT
#   Echo the path to a usable no-Rust stage0 compiler. Always refreshes the
#   published stage0 first so mutable stage0-latest caches do not silently go
#   stale. Honours the same TYPELISP_STAGE0_* environment knobs as
#   scripts/fetch-stage0.sh.
resolve_stage0_compiler() {
    _ls0_root=$1
    _ls0_dir=${TYPELISP_STAGE0_DIR:-target/stage0}
    case "$_ls0_dir" in
        /*) : ;;
        *) _ls0_dir="$_ls0_root/$_ls0_dir" ;;
    esac
    _ls0_suffix=$(stage0_host_exe_suffix)
    _ls0_bin="$_ls0_dir/typelisp$_ls0_suffix"
    "$_ls0_root/scripts/fetch-stage0.sh" >&2
    if [ ! -x "$_ls0_bin" ]; then
        echo "no-Rust stage0 compiler unavailable after fetch: $_ls0_bin" >&2
        echo "set TYPELISP_BIN to a stage0 binary, or run scripts/fetch-stage0.sh" >&2
        return 1
    fi
    printf '%s\n' "$_ls0_bin"
}
