#!/usr/bin/env python3
"""Generate or verify stdlib trig golden vectors with MPFR.

The checked-in hard cases also include inputs selected from the CORE-MATH
binary32/binary64 sin/cos/tan `.wc` corpora. MPFR is the result oracle; host
libm is never consulted.

The script uses the MPFR shared library directly, so it needs libmpfr at
runtime but no Python package:

    python3 scripts/generate-math-trig-vectors.py
    python3 scripts/generate-math-trig-vectors.py --emit
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


ROOT = pathlib.Path(__file__).resolve().parents[1]
VECTORS = ROOT / "tests" / "integration" / "stdlib_math_trig.tl"
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
    lib.mpfr_set_d.restype = ctypes.c_int
    for operation in ("sin", "cos", "tan"):
        function = getattr(lib, f"mpfr_{operation}")
        function.argtypes = [ptr, ptr, ctypes.c_int]
        function.restype = ctypes.c_int
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


def reference_bits(lib: ctypes.CDLL, bits: int, width: int, operation: str) -> int:
    argument = Mpfr()
    result = Mpfr()
    lib.mpfr_init2(ctypes.byref(argument), PRECISION)
    lib.mpfr_init2(ctypes.byref(result), PRECISION)
    try:
        lib.mpfr_set_d(
            ctypes.byref(argument),
            float_from_bits(bits, width),
            MPFR_RNDN,
        )
        getattr(lib, f"mpfr_{operation}")(
            ctypes.byref(result),
            ctypes.byref(argument),
            MPFR_RNDN,
        )
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


def sampled_finite_inputs(width: int, count: int, seed: int) -> list[int]:
    generator = random.Random(seed ^ width)
    exponent_mask = 0x7FF0000000000000 if width == 64 else 0x7F800000
    values: list[int] = []
    while len(values) < count:
        bits = generator.getrandbits(width)
        if bits & exponent_mask != exponent_mask:
            values.append(bits)
    return values


def emit_sample_program(lib: ctypes.CDLL, count: int, seed: int) -> None:
    print("(import stdlib.math)")
    print()
    print(f";; Generated MPFR-{PRECISION} sample: count={count}, seed={seed}.")
    for width in (64, 32):
        prefix = f"trig-f{width}"
        inputs = sampled_finite_inputs(width, count, seed)
        emit_array(f"{prefix}-inputs", width, inputs)
        for operation in ("sin", "cos", "tan"):
            emit_array(
                f"{prefix}-{operation}-bits",
                width,
                [
                    reference_bits(lib, input_bits, width, operation)
                    for input_bits in inputs
                ],
            )
        print()
    print(
        r"""
(define (trig-ordered-u64 [bits : u64]) : u64
  (if (!= (bit-and bits (cast 0x8000000000000000 : u64)) (cast 0 : u64))
    (bit-xor bits (cast 0xffffffffffffffff : u64))
    (bit-or bits (cast 0x8000000000000000 : u64))))

(define (trig-ordered-u32 [bits : u32]) : u32
  (if (!= (bit-and bits (cast 0x80000000 : u32)) (cast 0 : u32))
    (bit-xor bits (cast 0xffffffff : u32))
    (bit-or bits (cast 0x80000000 : u32))))

(define (trig-u64-within-one-ulp? [actual : u64] [expected : u64]) : bool
  (let
    [a : u64 (trig-ordered-u64 actual)]
    [b : u64 (trig-ordered-u64 expected)]
    (if (> a b)
      (<= (- a b) (cast 1 : u64))
      (<= (- b a) (cast 1 : u64)))))

(define (trig-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (let
    [a : u32 (trig-ordered-u32 actual)]
    [b : u32 (trig-ordered-u32 expected)]
    (if (> a b)
      (<= (- a b) (cast 1 : u32))
      (<= (- b a) (cast 1 : u32)))))

(define (trig-check-f64 [index : i64]) : bool
  (let
    [value : f64 (math.f64-from-bits (array-ref trig-f64-inputs index))]
    (and
      (trig-u64-within-one-ulp?
        (math.f64-to-bits (math.f64-sin value))
        (array-ref trig-f64-sin-bits index))
      (trig-u64-within-one-ulp?
        (math.f64-to-bits (math.f64-cos value))
        (array-ref trig-f64-cos-bits index))
      (trig-u64-within-one-ulp?
        (math.f64-to-bits (math.f64-tan value))
        (array-ref trig-f64-tan-bits index)))))

(define (trig-check-f32 [index : i64]) : bool
  (let
    [value : f32 (math.f32-from-bits (array-ref trig-f32-inputs index))]
    (and
      (trig-u32-within-one-ulp?
        (math.f32-to-bits (math.f32-sin value))
        (array-ref trig-f32-sin-bits index))
      (trig-u32-within-one-ulp?
        (math.f32-to-bits (math.f32-cos value))
        (array-ref trig-f32-cos-bits index))
      (trig-u32-within-one-ulp?
        (math.f32-to-bits (math.f32-tan value))
        (array-ref trig-f32-tan-bits index)))))
"""
    )
    print("(define (main) : i64")
    print("  (let")
    print("    [i : i64 0]")
    print("    (begin")
    print(f"      (while (< i {count})")
    print("        (begin")
    print("          (if (trig-check-f64 i) unit (return (+ 10 i)))")
    print("          (set! i (+ i 1))))")
    print("      (set! i 0)")
    print(f"      (while (< i {count})")
    print("        (begin")
    print("          (if (trig-check-f32 i) unit (return (+ 10010 i)))")
    print("          (set! i (+ i 1))))")
    print("      0)))")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--emit",
        action="store_true",
        help="print regenerated result arrays instead of only checking them",
    )
    parser.add_argument(
        "--sample",
        type=int,
        metavar="COUNT",
        help="emit a runnable broad sampled verifier with COUNT inputs per precision",
    )
    parser.add_argument("--seed", type=int, default=5229)
    args = parser.parse_args()

    lib = load_mpfr()
    if args.sample is not None:
        if args.sample <= 0:
            parser.error("--sample must be positive")
        if args.emit:
            parser.error("--emit and --sample are mutually exclusive")
        emit_sample_program(lib, args.sample, args.seed)
        return 0

    source = VECTORS.read_text(encoding="utf-8")
    mismatches = 0
    for width in (64, 32):
        prefix = f"trig-f{width}"
        inputs = parse_array(source, f"{prefix}-inputs")
        for operation in ("sin", "cos", "tan"):
            name = f"{prefix}-{operation}-bits"
            expected = parse_array(source, name)
            actual = [
                reference_bits(lib, input_bits, width, operation)
                for input_bits in inputs
            ]
            if args.emit:
                emit_array(name, width, actual)
                continue
            if len(expected) != len(actual):
                print(
                    f"{name}: expected {len(actual)} entries, found {len(expected)}",
                    file=sys.stderr,
                )
                mismatches += 1
                continue
            for index, (wanted, found) in enumerate(zip(actual, expected)):
                if wanted != found:
                    digits = width // 4
                    print(
                        f"{name}[{index}]: MPFR 0x{wanted:0{digits}x}, "
                        f"checked in 0x{found:0{digits}x}",
                        file=sys.stderr,
                    )
                    mismatches += 1
    if args.emit:
        return 0
    if mismatches:
        print(f"math trig vectors: {mismatches} mismatch(es)", file=sys.stderr)
        return 1
    print("math trig vectors: MPFR-256 verification passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"math trig vector generator: {error}", file=sys.stderr)
        raise SystemExit(2)
