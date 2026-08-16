#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

exec python3 - "$@" <<'PY'
"""Verify or emit the checked-in stdlib power vectors with MPFR.

The input pairs and expected bit patterns live in
`tests/integration/stdlib_math_pow.tl`. MPFR is the result oracle; host libm is
never consulted.

    scripts/generate-math-pow-vectors.sh
    scripts/generate-math-pow-vectors.sh --emit
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import pathlib
import re
import struct
import sys


ROOT = pathlib.Path.cwd()
VECTORS = ROOT / "tests" / "integration" / "stdlib_math_pow.tl"
PRECISION = 800
MPFR_RNDN = 0
EXPECTED_COUNTS = {64: 254, 32: 186}


class Mpfr(ctypes.Structure):
    _fields_ = [
        ("precision", ctypes.c_long),
        ("sign", ctypes.c_int),
        ("exponent", ctypes.c_long),
        ("limbs", ctypes.POINTER(ctypes.c_ulong)),
    ]


def load_mpfr() -> ctypes.CDLL:
    name = ctypes.util.find_library("mpfr")
    if not name:
        raise RuntimeError("libmpfr was not found")
    lib = ctypes.CDLL(name)
    ptr = ctypes.POINTER(Mpfr)
    lib.mpfr_init2.argtypes = [ptr, ctypes.c_long]
    lib.mpfr_clear.argtypes = [ptr]
    lib.mpfr_set_d.argtypes = [ptr, ctypes.c_double, ctypes.c_int]
    lib.mpfr_set_d.restype = ctypes.c_int
    lib.mpfr_pow.argtypes = [ptr, ptr, ptr, ctypes.c_int]
    lib.mpfr_pow.restype = ctypes.c_int
    lib.mpfr_get_d.argtypes = [ptr, ctypes.c_int]
    lib.mpfr_get_d.restype = ctypes.c_double
    lib.mpfr_get_flt.argtypes = [ptr, ctypes.c_int]
    lib.mpfr_get_flt.restype = ctypes.c_float
    return lib


def float_from_bits(bits: int, width: int) -> float:
    if width == 64:
        return struct.unpack(">d", struct.pack(">Q", bits))[0]
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def bits_from_float(value: float, width: int) -> int:
    if width == 64:
        return struct.unpack(">Q", struct.pack(">d", value))[0]
    return struct.unpack(">I", struct.pack(">f", value))[0]


def reference_bits(lib: ctypes.CDLL, base: int, exponent: int, width: int) -> int:
    x = Mpfr()
    y = Mpfr()
    result = Mpfr()
    for value in (x, y, result):
        lib.mpfr_init2(ctypes.byref(value), PRECISION)
    try:
        lib.mpfr_set_d(
            ctypes.byref(x), float_from_bits(base, width), MPFR_RNDN
        )
        lib.mpfr_set_d(
            ctypes.byref(y), float_from_bits(exponent, width), MPFR_RNDN
        )
        lib.mpfr_pow(
            ctypes.byref(result), ctypes.byref(x), ctypes.byref(y), MPFR_RNDN
        )
        if width == 64:
            rounded = lib.mpfr_get_d(ctypes.byref(result), MPFR_RNDN)
        else:
            rounded = lib.mpfr_get_flt(ctypes.byref(result), MPFR_RNDN)
        return bits_from_float(rounded, width)
    finally:
        for value in (result, y, x):
            lib.mpfr_clear(ctypes.byref(value))


def parse_array(source: str, name: str) -> list[int]:
    match = re.search(
        rf"\(define\s+{re.escape(name)}\s*:[^)]*\)\s*"
        rf"\(array(?P<body>.*?)\)\)",
        source,
        re.DOTALL,
    )
    if not match:
        raise RuntimeError(f"could not find array {name}")
    return [int(value, 16) for value in re.findall(r"0x[0-9a-fA-F]+", match["body"])]


def parse_vectors(source: str, width: int) -> list[tuple[int, int, int]]:
    bases = parse_array(source, f"pow-f{width}-bases")
    exponents = parse_array(source, f"pow-f{width}-exponents")
    results = parse_array(source, f"pow-f{width}-bits")
    expected = EXPECTED_COUNTS[width]
    lengths = (len(bases), len(exponents), len(results))
    if lengths != (expected, expected, expected):
        raise RuntimeError(
            f"expected {expected} f{width} base/exponent/result entries, "
            f"found {lengths}"
        )
    return list(zip(bases, exponents, results))


def emit_array(name: str, width: int, values: list[int]) -> None:
    digits = width // 4
    scalar = f"u{width}"
    print(f"(define {name} : (Array {scalar} {len(values)})")
    print("  (array")
    for index, value in enumerate(values):
        suffix = "))" if index + 1 == len(values) else ""
        print(f"    0x{value:0{digits}x}{suffix}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--emit",
        action="store_true",
        help="emit base, exponent, and regenerated MPFR result arrays",
    )
    args = parser.parse_args()

    source = VECTORS.read_text(encoding="utf-8")
    lib = load_mpfr()
    mismatches = 0
    for width in (64, 32):
        vectors = parse_vectors(source, width)
        actual = [
            reference_bits(lib, base, exponent, width)
            for base, exponent, _ in vectors
        ]
        if args.emit:
            emit_array(f"pow-f{width}-bases", width, [v[0] for v in vectors])
            emit_array(f"pow-f{width}-exponents", width, [v[1] for v in vectors])
            emit_array(f"pow-f{width}-bits", width, actual)
            print()
            continue
        for index, ((base, exponent, checked_in), wanted) in enumerate(
            zip(vectors, actual)
        ):
            if wanted != checked_in:
                digits = width // 4
                print(
                    f"pow-f{width}[{index}] base=0x{base:0{digits}x} "
                    f"exponent=0x{exponent:0{digits}x}: "
                    f"MPFR 0x{wanted:0{digits}x}, "
                    f"checked in 0x{checked_in:0{digits}x}",
                    file=sys.stderr,
                )
                mismatches += 1
    if args.emit:
        return 0
    if mismatches:
        print(f"math pow vectors: {mismatches} mismatch(es)", file=sys.stderr)
        return 1
    total = sum(EXPECTED_COUNTS.values())
    print(f"math pow vectors: MPFR-{PRECISION} verification passed ({total} exact-bit cases)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"math pow vector generator: {error}", file=sys.stderr)
        raise SystemExit(2)
PY
