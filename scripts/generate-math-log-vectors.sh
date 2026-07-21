#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

exec python3 - "$@" <<'PY'
"""Generate or verify stdlib logarithm golden vectors with MPFR.

The binary64 fixture includes hard-to-round inputs from CORE-MATH `log.wc` at
revision 66832f6d97d2245f8f10ea534ed93858e9b058dd. MPFR-256 is the result
oracle; host libm is never consulted.

    scripts/generate-math-log-vectors.sh
    scripts/generate-math-log-vectors.sh --emit
    scripts/generate-math-log-vectors.sh --sample 4096
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import pathlib
import random
import re
import struct
import sys


ROOT = pathlib.Path.cwd()
VECTORS = ROOT / "tests" / "integration" / "stdlib_math_log.tl"
PRECISION = 256
MPFR_RNDN = 0


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
    lib.mpfr_log.argtypes = [ptr, ptr, ctypes.c_int]
    lib.mpfr_get_d.argtypes = [ptr, ctypes.c_int]
    lib.mpfr_get_d.restype = ctypes.c_double
    lib.mpfr_get_flt.argtypes = [ptr, ctypes.c_int]
    lib.mpfr_get_flt.restype = ctypes.c_float
    return lib


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


def float_from_bits(bits: int, width: int) -> float:
    if width == 64:
        return struct.unpack(">d", struct.pack(">Q", bits))[0]
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def bits_from_float(value: float, width: int) -> int:
    if width == 64:
        return struct.unpack(">Q", struct.pack(">d", value))[0]
    return struct.unpack(">I", struct.pack(">f", value))[0]


def reference_bits(lib: ctypes.CDLL, bits: int, width: int) -> int:
    argument = Mpfr()
    result = Mpfr()
    lib.mpfr_init2(ctypes.byref(argument), PRECISION)
    lib.mpfr_init2(ctypes.byref(result), PRECISION)
    try:
        lib.mpfr_set_d(ctypes.byref(argument), float_from_bits(bits, width), MPFR_RNDN)
        lib.mpfr_log(ctypes.byref(result), ctypes.byref(argument), MPFR_RNDN)
        if width == 64:
            rounded = lib.mpfr_get_d(ctypes.byref(result), MPFR_RNDN)
        else:
            rounded = lib.mpfr_get_flt(ctypes.byref(result), MPFR_RNDN)
        return bits_from_float(rounded, width)
    finally:
        lib.mpfr_clear(ctypes.byref(result))
        lib.mpfr_clear(ctypes.byref(argument))


def emit_array(name: str, width: int, values: list[int]) -> None:
    digits = width // 4
    scalar = "u64" if width == 64 else "u32"
    print(f"(define {name} : (Array {scalar} {len(values)})")
    print("  (array")
    for index, value in enumerate(values):
        suffix = "))" if index + 1 == len(values) else ""
        print(f"    0x{value:0{digits}x}{suffix}")


def sample_inputs(width: int, count: int, seed: int) -> list[int]:
    generator = random.Random(seed ^ width)
    exponent_mask = 0x7FF0000000000000 if width == 64 else 0x7F800000
    values: list[int] = []
    while len(values) < count:
        bits = generator.getrandbits(width - 1)
        if bits != 0 and bits & exponent_mask != exponent_mask:
            values.append(bits)
    return values


def emit_sample_program(lib: ctypes.CDLL, count: int, seed: int) -> None:
    print("(import stdlib.math)")
    print()
    print(f";; Generated MPFR-{PRECISION} positive-finite sample: count={count}, seed={seed}.")
    for width in (64, 32):
        inputs = sample_inputs(width, count, seed)
        emit_array(f"log-f{width}-inputs", width, inputs)
        emit_array(
            f"log-f{width}-bits",
            width,
            [reference_bits(lib, bits, width) for bits in inputs],
        )
        print()
    print(
        r"""
(define (log-u64-within-one-ulp? [actual : u64] [expected : u64]) : bool
  (if (> actual expected)
    (<= (- actual expected) (cast 1 : u64))
    (<= (- expected actual) (cast 1 : u64))))

(define (log-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (if (> actual expected)
    (<= (- actual expected) (cast 1 : u32))
    (<= (- expected actual) (cast 1 : u32))))

(define (log-check-f64 [index : i64]) : bool
  (log-u64-within-one-ulp?
    (math.f64-to-bits
      (math.f64-log (math.f64-from-bits (array-ref log-f64-inputs index))))
    (array-ref log-f64-bits index)))

(define (log-check-f32 [index : i64]) : bool
  (log-u32-within-one-ulp?
    (math.f32-to-bits
      (math.f32-log (math.f32-from-bits (array-ref log-f32-inputs index))))
    (array-ref log-f32-bits index)))
"""
    )
    print("(define (main) : i64")
    print("  (let")
    print("    [i : i64 0]")
    print("    (begin")
    print(f"      (while (< i {count})")
    print("        (begin")
    print("          (unless (log-check-f64 i) (return (+ 10 i)))")
    print("          (set! i (+ i 1))))")
    print("      (set! i 0)")
    print(f"      (while (< i {count})")
    print("        (begin")
    print("          (unless (log-check-f32 i) (return (+ 100010 i)))")
    print("          (set! i (+ i 1))))")
    print("      0)))")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit", action="store_true")
    parser.add_argument("--sample", type=int, metavar="COUNT")
    parser.add_argument("--seed", type=int, default=5228)
    args = parser.parse_args()
    if args.sample is not None and args.sample <= 0:
        parser.error("--sample must be positive")
    if args.emit and args.sample is not None:
        parser.error("--emit and --sample are mutually exclusive")

    lib = load_mpfr()
    if args.sample is not None:
        emit_sample_program(lib, args.sample, args.seed)
        return 0

    source = VECTORS.read_text(encoding="utf-8")
    mismatches = 0
    for width in (64, 32):
        inputs = parse_array(source, f"log-f{width}-inputs")
        expected = parse_array(source, f"log-f{width}-bits")
        actual = [reference_bits(lib, bits, width) for bits in inputs]
        if args.emit:
            emit_array(f"log-f{width}-bits", width, actual)
            continue
        if len(expected) != len(actual):
            print(
                f"log-f{width}-bits: expected {len(actual)} entries, "
                f"found {len(expected)}",
                file=sys.stderr,
            )
            mismatches += 1
            continue
        for index, (wanted, found) in enumerate(zip(actual, expected)):
            if wanted != found:
                digits = width // 4
                print(
                    f"log-f{width}-bits[{index}]: MPFR 0x{wanted:0{digits}x}, "
                    f"checked in 0x{found:0{digits}x}",
                    file=sys.stderr,
                )
                mismatches += 1
    if args.emit:
        return 0
    if mismatches:
        print(f"math log vectors: {mismatches} mismatch(es)", file=sys.stderr)
        return 1
    print("math log vectors: MPFR-256 verification passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"math log vector generator: {error}", file=sys.stderr)
        raise SystemExit(2)
PY
