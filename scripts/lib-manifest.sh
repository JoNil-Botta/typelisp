#!/usr/bin/env sh
# lib-manifest.sh - POSIX helpers for fragment-directory manifests (*.manifest).
#
# Sourced by runners and validators. Lists and concatenates regular `*.manifest`
# files directly inside a directory in `LC_ALL=C` sorted order with `\r`
# stripped, rejecting missing/empty directories, subdirectories, symlinks, and
# non-`.manifest` stray entries. File lists stream via stdin so Windows ARG_MAX
# is never reached regardless of fragment count.

# manifest_list_dir DIR
# Validate DIR and print each DIR/*.manifest path in LC_ALL=C sorted order.
# Atomic on error: emits nothing to stdout if any entry is invalid or DIR has
# no fragments.
manifest_list_dir() {
    _ml_dir=${1:-}
    if [ -z "$_ml_dir" ]; then
        echo "manifest_list_dir: directory argument required" >&2
        return 1
    fi
    case "$_ml_dir" in
        /) ;;
        */) _ml_dir=${_ml_dir%/} ;;
    esac
    if [ ! -d "$_ml_dir" ]; then
        echo "manifest directory does not exist: $_ml_dir" >&2
        return 1
    fi
    _ml_entries=$(find "$_ml_dir" -print | LC_ALL=C sort) || return 1
    _ml_count=0
    while IFS= read -r _ml_entry; do
        [ -n "$_ml_entry" ] || continue
        [ "$_ml_entry" != "$_ml_dir" ] || continue
        _ml_rel=${_ml_entry#"$_ml_dir"/}
        case "$_ml_rel" in
            */*)
                echo "manifest directory $_ml_dir contains nested entry: $_ml_rel" >&2
                return 1
                ;;
            .manifest)
                echo "manifest directory $_ml_dir contains invalid manifest filename: $_ml_rel" >&2
                return 1
                ;;
            *.manifest) ;;
            *)
                echo "manifest directory $_ml_dir contains unexpected non-.manifest entry: $_ml_rel" >&2
                return 1
                ;;
        esac
        if [ ! -f "$_ml_entry" ] || [ -L "$_ml_entry" ]; then
            echo "manifest directory $_ml_dir contains non-regular entry: $_ml_rel" >&2
            return 1
        fi
        _ml_count=$((_ml_count + 1))
    done <<EOF
$_ml_entries
EOF
    if [ "$_ml_count" -eq 0 ]; then
        echo "manifest directory is empty (no *.manifest files): $_ml_dir" >&2
        return 1
    fi
    while IFS= read -r _ml_entry; do
        [ -n "$_ml_entry" ] || continue
        [ "$_ml_entry" != "$_ml_dir" ] || continue
        printf '%s\n' "$_ml_entry"
    done <<EOF
$_ml_entries
EOF
}

# manifest_concat_dir DIR
# Validate DIR and stream every DIR/*.manifest concatenated in LC_ALL=C sorted
# order with CR (`\r`) stripped. Safe against Windows ARG_MAX because fragment
# paths pass over stdin into a single awk process.
manifest_concat_dir() {
    _mc_dir=${1:-}
    _mc_files=$(manifest_list_dir "$_mc_dir") || return 1
    awk '
        {
            path = $0
            while ((status = (getline line < path)) > 0) {
                gsub(/\r/, "", line)
                print line
            }
            if (status < 0) {
                print "manifest_concat_dir: failed to read " path > "/dev/stderr"
                failed = 1
                exit 1
            }
            close(path)
        }
        END { if (failed) exit 1 }
    ' <<EOF
$_mc_files
EOF
}
