#!/usr/bin/env sh
set -eu
# Maintainer-only offline regeneration. CI executes checked-in fixtures.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
check=0
if [ "${1:-}" = --check ]; then check=1; shift; fi
[ "$#" -eq 1 ] || { echo 'usage: regenerate-crypto-aes-kat.sh [--check] <pinned-rsp-directory>' >&2; exit 2; }
case "$1" in /*) inputs=$1 ;; *) inputs="$ROOT/$1" ;; esac
(cd "$inputs" && sha256sum -c "$ROOT/tests/fixtures/crypto-aes/sources.sha256")
work=${AES_KAT_WORKDIR:-target/exp/crypto-aes-kat}
mkdir -p "$work"
compiler=${TYPELISP_BIN:-target/stage0/typelisp}
"$compiler" run tools/crypto-aes-kat/generate.tl --stdlib-root stdlib -- "$inputs" "$work/crypto_aes_kat_inline.tl"
"$compiler" fmt "$work/crypto_aes_kat_inline.tl"
if [ "$check" -eq 1 ]; then
    cmp stdlib/tests/crypto_aes_kat_inline.tl "$work/crypto_aes_kat_inline.tl"
else
    cp "$work/crypto_aes_kat_inline.tl" stdlib/tests/crypto_aes_kat_inline.tl
fi
