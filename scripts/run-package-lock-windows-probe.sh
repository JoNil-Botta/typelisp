#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
WORK=target/exp/w2-8831-probe
mkdir -p "$WORK"
gh api repos/JoNil-Botta/typelisp/releases/assets/642464209 \
    -H 'Accept: application/octet-stream' > "$WORK/seed.exe"
printf '%s\n' '151177667ac7edddab52a035ee73def6673fe859187ed17c3c8ea703418449c9  target/exp/w2-8831-probe/seed.exe' | sha256sum -c -
scripts/run-memory-bounded.sh --limit-mib 512 --report "$WORK/version.memory" -- \
    "$ROOT/$WORK/seed.exe" --version > "$WORK/seed-version.txt"
grep -F 'bab7c0980606d8b10c656b567f1fc478a728df85' "$WORK/seed-version.txt"
scripts/run-memory-bounded.sh --limit-mib 2048 --report "$WORK/build.memory" -- \
    "$ROOT/$WORK/seed.exe" build "$WORK/atomic_replace_probe.tl" \
    --target windows-x86_64 --stdlib-root stdlib -o "$WORK/probe.exe" \
    > "$WORK/build.stdout" 2> "$WORK/build.stderr"
[ -s "$WORK/probe.exe" ]
status=0
scripts/run-memory-bounded.sh --limit-mib 512 --report "$WORK/run.memory" -- \
    "$ROOT/$WORK/probe.exe" > "$WORK/run.stdout" 2> "$WORK/run.stderr" || status=$?
cat "$WORK/run.stdout"
cat "$WORK/run.stderr" >&2
printf '%s\n' "$status" > "$WORK/run.exit"
[ "$status" -eq 42 ]
for witness in legacy-no-reader legacy-reader-share3 legacy-reader-share7 legacy-readonly-destination posix-no-reader posix-reader-share3 posix-reader-share7 posix-readonly-destination after-reader-close=success reader-retains-old=success; do
    grep -Fx "$witness" "$WORK/run.stdout"
done
