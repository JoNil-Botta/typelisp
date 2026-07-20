#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

exec python3 - "$@" <<'PY'
"""Generate or verify stdlib exponential golden vectors with MPFR.

The checked-in binary64 hard cases include inputs selected from the CORE-MATH
`exp.wc` corpus. MPFR is the result oracle; host libm is never consulted.

    scripts/generate-math-exp-vectors.sh
    scripts/generate-math-exp-vectors.sh --emit
    scripts/generate-math-exp-vectors.sh --sample 4096
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
VECTORS = ROOT / "tests" / "integration" / "stdlib_math_exp.tl"
PRECISION = 256
MPFR_RNDN = 0
CORE_MATH_REVISION = "66832f6d97d2245f8f10ea534ed93858e9b058dd"


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
    lib.mpfr_exp.argtypes = [ptr, ptr, ctypes.c_int]
    lib.mpfr_exp.restype = ctypes.c_int
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
        lib.mpfr_exp(ctypes.byref(result), ctypes.byref(argument), MPFR_RNDN)
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


def finite(bits: int, width: int) -> bool:
    mask = 0x7FF0000000000000 if width == 64 else 0x7F800000
    return bits & mask != mask


def sample_inputs(width: int, count: int, seed: int) -> list[int]:
    generator = random.Random(seed ^ width)
    pack = ">Q" if width == 64 else ">I"
    float_pack = ">d" if width == 64 else ">f"
    bounded_lo, bounded_hi = ((-750.0, 710.0) if width == 64 else (-105.0, 90.0))
    values: list[int] = []
    while len(values) < count:
        if len(values) % 2 == 0:
            bits = generator.getrandbits(width)
            if finite(bits, width):
                values.append(bits)
        else:
            value = generator.uniform(bounded_lo, bounded_hi)
            try:
                packed = struct.pack(float_pack, value)
            except OverflowError:
                continue
            values.append(struct.unpack(pack, packed)[0])
    return values


def fixture_inputs(width: int, count: int, seed: int) -> list[int]:
    if width == 64:
        curated = [
            0x0000000000000000,
            0x8000000000000000,
            0x0000000000000001,
            0x8000000000000001,
            0x3FF0000000000000,
            0xBFF0000000000000,
            0x3FE62E42FEFA39EF,
            0xBFE62E42FEFA39EF,
            0x4080000000000000,
            0xC080000000000000,
            0x7FEFFFFFFFFFFFFF,
            0xFFEFFFFFFFFFFFFF,
            # CORE-MATH exp.wc overflow/underflow boundaries and hard cases.
            0x40862E42FEFA39EF,
            0x40862E42FEFA39F0,
            0xC0874910D52D3052,
            0xC0874910D52D3051,
            0xC0874385446D71C3,
            0xC0874385446D71C4,
            0x3CF0000000000000,
            0xBCE0000000000000,
            0x3CE0000000000000,
            0x3CD0000000000000,
            0xBCD0000000000000,
            0x3CC0000000000000,
            0xBCC0000000000000,
            0x3CB0000000000000,
            0xBCB0000000000000,
            0x3CA0000000000000,
            0xBCA0000000000000,
            0xBCE0000000000001,
            0x3CE0000000000001,
            0xBCD0000000000001,
            0x3CD0000000000001,
            0xBCC0000000000001,
            0x3CC0000000000001,
        ]
    else:
        curated = [
            0x00000000,
            0x80000000,
            0x00000001,
            0x80000001,
            0x3F800000,
            0xBF800000,
            0x3F317218,
            0xBF317218,
            0x42B00000,
            0xC2B00000,
            0x42B17216,
            0x42B17217,
            0x42B17218,
            0xC2CFF1B3,
            0xC2CFF1B4,
            0xC2CFF1B5,
            0x7F7FFFFF,
            0xFF7FFFFF,
            0x33800000,
            0xB3800000,
        ]
    sampled = sample_inputs(width, count, seed)
    return (curated + sampled)[:count]


def emit_sample_program(
    lib: ctypes.CDLL, count: int, seed: int, curated: bool = False
) -> None:
    print("(import stdlib.math)")
    print()
    if curated:
        print(
            f";; MPFR-{PRECISION} vectors: curated thresholds/CORE-MATH cases"
        )
        print(f";; plus deterministic samples; count={count}, seed={seed}.")
        print(f";; CORE-MATH revision: {CORE_MATH_REVISION}.")
    else:
        print(f";; Generated MPFR-{PRECISION} sample: count={count}, seed={seed}.")
    for width in (64, 32):
        inputs = (
            fixture_inputs(width, count, seed)
            if curated
            else sample_inputs(width, count, seed)
        )
        emit_array(f"exp-f{width}-inputs", width, inputs)
        emit_array(
            f"exp-f{width}-bits",
            width,
            [reference_bits(lib, bits, width) for bits in inputs],
        )
        print()
    print(
        r"""
(define (exp-u64-within-one-ulp? [actual : u64] [expected : u64]) : bool
  (if (or
    (= expected (cast 0 : u64))
    (= expected (cast 0x7ff0000000000000 : u64)))
    (= actual expected)
    (if (> actual expected)
      (<= (- actual expected) (cast 1 : u64))
      (<= (- expected actual) (cast 1 : u64)))))

(define (exp-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (if (or
    (= expected (cast 0 : u32))
    (= expected (cast 0x7f800000 : u32)))
    (= actual expected)
    (if (> actual expected)
      (<= (- actual expected) (cast 1 : u32))
      (<= (- expected actual) (cast 1 : u32)))))

(define (exp-check-f64 [index : i64]) : bool
  (exp-u64-within-one-ulp?
    (math.f64-to-bits
      (math.f64-exp (math.f64-from-bits (array-ref exp-f64-inputs index))))
    (array-ref exp-f64-bits index)))

(define (exp-check-f32 [index : i64]) : bool
  (exp-u32-within-one-ulp?
    (math.f32-to-bits
      (math.f32-exp (math.f32-from-bits (array-ref exp-f32-inputs index))))
    (array-ref exp-f32-bits index)))
"""
    )
    print("(define (main) : i64")
    print("  (let")
    print("    [i : i64 0]")
    print("    (begin")
    print(f"      (while (< i {count})")
    print("        (begin")
    print("          (unless (exp-check-f64 i) (return (+ 10 i)))")
    print("          (set! i (+ i 1))))")
    print("      (set! i 0)")
    print(f"      (while (< i {count})")
    print("        (begin")
    print("          (unless (exp-check-f32 i) (return (+ 100010 i)))")
    print("          (set! i (+ i 1))))")
    if curated:
        print("      (unless")
        print("        (= (math.f64-to-bits")
        print("          (math.f64-exp (math.f64-negative-infinity)))")
        print("          (cast 0 : u64))")
        print("        (return 200001))")
        print("      (unless")
        print("        (= (math.f64-to-bits")
        print("          (math.f64-exp (math.f64-positive-infinity)))")
        print("          (cast 0x7ff0000000000000 : u64))")
        print("        (return 200002))")
        print("      (unless")
        print("        (math.f64-nan? (math.f64-exp (math.f64-quiet-nan)))")
        print("        (return 200003))")
        print("      (unless")
        print("        (= (math.f32-to-bits")
        print("          (math.f32-exp (math.f32-negative-infinity)))")
        print("          (cast 0 : u32))")
        print("        (return 200004))")
        print("      (unless")
        print("        (= (math.f32-to-bits")
        print("          (math.f32-exp (math.f32-positive-infinity)))")
        print("          (cast 0x7f800000 : u32))")
        print("        (return 200005))")
        print("      (unless")
        print("        (math.f32-nan? (math.f32-exp (math.f32-quiet-nan)))")
        print("        (return 200006))")
    print("      0)))")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit", action="store_true")
    parser.add_argument("--sample", type=int, metavar="COUNT")
    parser.add_argument("--fixture", type=int, metavar="COUNT")
    parser.add_argument("--seed", type=int, default=5227)
    args = parser.parse_args()
    if args.sample is not None and args.sample <= 0:
        parser.error("--sample must be positive")
    if args.fixture is not None and args.fixture <= 0:
        parser.error("--fixture must be positive")
    selected_modes = sum(
        int(value)
        for value in (args.emit, args.sample is not None, args.fixture is not None)
    )
    if selected_modes > 1:
        parser.error("--emit, --sample, and --fixture are mutually exclusive")

    lib = load_mpfr()
    if args.sample is not None:
        emit_sample_program(lib, args.sample, args.seed)
        return 0
    if args.fixture is not None:
        emit_sample_program(lib, args.fixture, args.seed, curated=True)
        return 0

    source = VECTORS.read_text(encoding="utf-8")
    mismatches = 0
    for width in (64, 32):
        inputs = parse_array(source, f"exp-f{width}-inputs")
        expected = parse_array(source, f"exp-f{width}-bits")
        actual = [reference_bits(lib, bits, width) for bits in inputs]
        if args.emit:
            emit_array(f"exp-f{width}-bits", width, actual)
            continue
        if len(expected) != len(actual):
            print(
                f"exp-f{width}-bits: expected {len(actual)} entries, "
                f"found {len(expected)}",
                file=sys.stderr,
            )
            mismatches += 1
            continue
        for index, (wanted, found) in enumerate(zip(actual, expected)):
            if wanted != found:
                digits = width // 4
                print(
                    f"exp-f{width}-bits[{index}]: MPFR 0x{wanted:0{digits}x}, "
                    f"checked in 0x{found:0{digits}x}",
                    file=sys.stderr,
                )
                mismatches += 1
    if args.emit:
        return 0
    if mismatches:
        print(f"math exp vectors: {mismatches} mismatch(es)", file=sys.stderr)
        return 1
    print("math exp vectors: MPFR-256 verification passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"math exp vector generator: {error}", file=sys.stderr)
        raise SystemExit(2)
PY
