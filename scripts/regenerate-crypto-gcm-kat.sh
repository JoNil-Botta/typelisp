#!/usr/bin/env sh
set -eu
# Offline maintainer regeneration from the official hash-pinned NIST archive.
# No network or external crypto provider is used by the test/gate.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
check=0
if [ "${1:-}" = --check ]; then check=1; shift; fi
[ "$#" -eq 1 ] || { echo 'usage: regenerate-crypto-gcm-kat.sh [--check] <pinned-rsp-directory>' >&2; exit 2; }
case "$1" in /*) inputs=$1 ;; *) inputs="$ROOT/$1" ;; esac
(cd "$inputs" && sha256sum -c "$ROOT/tests/fixtures/crypto-gcm/sources.sha256")
work=${GCM_KAT_WORKDIR:-target/exp/crypto-gcm-kat}
mkdir -p "$work"
output="$work/crypto_aes128_gcm_kat_inline.tl"
compiler=${TYPELISP_BIN:-target/stage0/typelisp}
"$compiler" run tools/crypto-gcm-kat/generate.tl --stdlib-root stdlib -- "$inputs" "$output"
"$compiler" fmt "$output"
if [ "$check" -eq 1 ]; then
    cmp stdlib/tests/crypto_aes128_gcm_kat_inline.tl "$output"
else
    cp "$output" stdlib/tests/crypto_aes128_gcm_kat_inline.tl
fi
