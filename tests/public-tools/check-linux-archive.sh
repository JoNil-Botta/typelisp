#!/usr/bin/env sh
set -eu

compiler=$1
case_dir=$(CDPATH= cd -- "$2" && pwd)
manifest="$case_dir/pkg with spaces/typelisp.pkg"
output_dir="$case_dir/pkg with spaces/target/release"
archive="$output_dir/libarchive_probe.a"
stamp="$archive.runtime-inputs"
original_path=$PATH
ar_tool=$(command -v ar)
llvm_tool=$(command -v llvm-ar || true)

# Model an ar configured without a deterministic default. An explicit D is
# passed through; otherwise U exposes timestamp and permission dependencies.
mkdir -p "$case_dir/archivers"
cat > "$case_dir/archivers/wrapper" <<'AR'
#!/bin/sh
set -eu
base=$(dirname "$0")
printf '%s\n' "$1" >> "$base/calls"
[ "$#" -eq 3 ]
real=$(cat "$base/real")
case "$1" in
  *D*) ;;
  *) flags="$1"U; shift; set -- "$flags" "$@" ;;
esac
exec "$real" "$@"
AR

build() {
    mask=$1
    (umask "$mask"; PATH="$tool_dir:$original_path" "$compiler" build \
        --manifest-path "$manifest" --target linux-x86_64 \
        --backend-mode "$mode" --opt-level 0) \
        > "$tool_dir/stdout" 2> "$tool_dir/stderr"
    test ! -s "$tool_dir/stderr"
}

for family in ar llvm-ar; do
    case "$family" in
      ar) real=$ar_tool ;;
      llvm-ar) real=$llvm_tool ;;
    esac
    if test -z "$real"; then
        printf '%s\n' 'llvm-ar unavailable; GNU-compatible ar checks remain required'
        continue
    fi
    for mode in scalar avx2; do
        tool_dir="$case_dir/archivers/$family-$mode"
        mkdir -p "$tool_dir"
        cp "$case_dir/archivers/wrapper" "$tool_dir/ar"
        chmod +x "$tool_dir/ar"
        printf '%s\n' "$real" > "$tool_dir/real"
        build 077
        grep -q '^Built ' "$tool_dir/stdout"
        cp "$archive" "$tool_dir/expected.a"
        sleep 1
        rm -f "$archive" "$stamp" "$output_dir/archive_probe.o" "$output_dir/archive_probe.s"
        build 022
        grep -q '^Built ' "$tool_dir/stdout"
        cmp "$tool_dir/expected.a" "$archive"
        test "$(grep -c '^arg 4:rcsD$' "$stamp")" = 1
        test "$(wc -l < "$tool_dir/calls")" = 2

        # A valid legacy argv field must invalidate the old runtime stamp once.
        sed 's/^arg 4:rcsD$/arg 3:rcs/' "$stamp" > "$tool_dir/legacy-inputs"
        mv "$tool_dir/legacy-inputs" "$stamp"
        build 022
        grep -q '^Built ' "$tool_dir/stdout"
        test "$(wc -l < "$tool_dir/calls")" = 3
        cmp "$tool_dir/expected.a" "$archive"
        build 022
        grep -q '^Fresh ' "$tool_dir/stdout"
        test "$(wc -l < "$tool_dir/calls")" = 3
        printf '%s/%s reproducible and fresh\n' "$family" "$mode"
    done
done

# A D-rejecting tool would accept a retry without D. The build must fail after
# one invocation and leave the previous archive intact.
bad_dir="$case_dir/archivers/reject-D"
mkdir -p "$bad_dir"
cat > "$bad_dir/ar" <<'AR'
#!/bin/sh
set -eu
base=$(dirname "$0")
printf '%s\n' "$1" >> "$base/calls"
case "$1" in
  *D*) echo 'D modifier rejected by test archiver' >&2; exit 64 ;;
esac
real=$(cat "$base/real")
flags="$1"U; shift
exec "$real" "$flags" "$@"
AR
chmod +x "$bad_dir/ar"
printf '%s\n' "$ar_tool" > "$bad_dir/real"
cp "$archive" "$bad_dir/expected.a"
if PATH="$bad_dir:$original_path" "$compiler" build \
    --manifest-path "$manifest" --target linux-x86_64 --opt-level 0 \
    > "$bad_dir/stdout" 2> "$bad_dir/stderr"; then
    echo 'D rejection unexpectedly built an archive' >&2
    exit 1
fi
grep -q 'D modifier rejected by test archiver' "$bad_dir/stderr"
grep -q 'deterministic Linux archives require rcsD support' "$bad_dir/stderr"
grep -qF "$bad_dir/ar" "$bad_dir/stderr"
test "$(wc -l < "$bad_dir/calls")" = 1
grep -qx rcsD "$bad_dir/calls"
cmp "$bad_dir/expected.a" "$archive"
printf '%s\n' 'Linux deterministic archive checks passed'
