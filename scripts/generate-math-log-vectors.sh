#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

exec python3 - "$@" <<'PY'
"""Generate or verify stdlib logarithm golden vectors with MPFR.

The binary64 hard cases are pinned from CORE-MATH's `log.wc` corpus. MPFR is
the result oracle; host libm is never consulted.

    scripts/generate-math-log-vectors.sh
    scripts/generate-math-log-vectors.sh --emit
    scripts/generate-math-log-vectors.sh --sample 4096
    scripts/generate-math-log-vectors.sh --fixture 128
"""

from __future__ import annotations

import argparse
import contextlib
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
CORE_MATH_REVISION = "66832f6d97d2245f8f10ea534ed93858e9b058dd"
CORE_MATH_LOG_HARD_CASES = (
    "0x1.a6ae5142326b5p+0",
    "0x1.a6ba95b1520f9p+0",
    "0x1.a702b2ce91b3p+0",
    "0x1.a775c6c1d8d3ep+0",
    "0x1.b072ab04ee9bfp+0",
    "0x1.c877cba59d0acp+0",
    "0x1.bbfff9457d5c3p+0",
    "0x1.bdfbc244c2cfep+0",
    "0x1.befeb75414206p+0",
    "0x1.c19bdd1656c31p+0",
    "0x1.c9f6ad292698fp+0",
    "0x1.b188600086feep+0",
    "0x1.ca3665f2edf3dp+0",
    "0x1.d2e75daa7d786p+0",
    "0x1.c47c00242ae49p+0",
    "0x1.1e852e6951306p+1",
    "0x1.1f1f3da2014bbp+1",
    "0x1.21e133699fd0fp+1",
    "0x1.dafdb40362537p+0",
    "0x1.dd17c2931712fp+0",
    "0x1.dd40c880d5893p+0",
    "0x1.e18514963c8ecp+0",
)


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
    lib.mpfr_log.argtypes = [ptr, ptr, ctypes.c_int]
    lib.mpfr_log.restype = ctypes.c_int
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
    sign_mask = 1 << (width - 1)
    values: list[int] = []
    while len(values) < count:
        bits = generator.getrandbits(width) & ~sign_mask
        if bits != 0 and bits & exponent_mask != exponent_mask:
            values.append(bits)
    return values


def table_boundary_inputs(width: int) -> list[int]:
    if width == 64:
        off, step, buckets = 0x3FE6000000000000, 1 << 45, 128
    else:
        off, step, buckets = 0x3F330000, 1 << 19, 16
    values: list[int] = []
    for boundary in range(buckets + 1):
        bits = off + boundary * step
        values.append(bits)
        if boundary % 8 == 0:
            values.extend((bits - 1, bits + 1))
    return values


def fixture_inputs(width: int, count: int, seed: int) -> list[int]:
    if width == 64:
        curated = [
            0x0000000000000001,
            0x000FFFFFFFFFFFFF,
            0x0010000000000000,
            0x0010000000000001,
            0x3CA0000000000000,
            0x3FD0000000000000,
            0x3FE0000000000000,
            0x3FEFFFFFFFFFFFFF,
            0x3FF0000000000000,
            0x3FF0000000000001,
            0x3FF0000000000002,
            0x4000000000000000,
            0x4010000000000000,
            0x7FD0000000000000,
            0x7FEFFFFFFFFFFFFF,
        ]
        curated.extend(
            bits_from_float(float.fromhex(value), 64)
            for value in CORE_MATH_LOG_HARD_CASES
        )
    else:
        curated = [
            0x00000001,
            0x007FFFFF,
            0x00800000,
            0x00800001,
            0x33800000,
            0x3E800000,
            0x3F000000,
            0x3F7FFFFF,
            0x3F800000,
            0x3F800001,
            0x3F800002,
            0x40000000,
            0x40800000,
            0x7E800000,
            0x7F7FFFFF,
        ]
    curated.extend(table_boundary_inputs(width))
    seen: set[int] = set()
    unique = [value for value in curated if not (value in seen or seen.add(value))]
    unique.extend(sample_inputs(width, max(0, count - len(unique)), seed))
    return unique[:count]


def emit_program(lib: ctypes.CDLL, count: int, seed: int, curated: bool) -> None:
    print("(import stdlib.math)")
    print()
    if curated:
        print(f";; MPFR-{PRECISION} vectors: special boundaries, table boundaries,")
        print(";; CORE-MATH binary64 hard cases, and deterministic positive samples.")
        print(f";; count={count}, seed={seed}.")
        print(f";; CORE-MATH revision: {CORE_MATH_REVISION}.")
    else:
        print(f";; Generated MPFR-{PRECISION} positive sample: count={count}, seed={seed}.")
    for width in (64, 32):
        inputs = fixture_inputs(width, count, seed) if curated else sample_inputs(width, count, seed)
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
  (if (= (bit-and expected 0x7fffffffffffffff) (cast 0 : u64))
    (= actual expected)
    (if (!=
      (bit-and actual 0x8000000000000000)
      (bit-and expected 0x8000000000000000))
      false
      (if (> actual expected)
        (<= (- actual expected) (cast 1 : u64))
        (<= (- expected actual) (cast 1 : u64))))))

(define (log-u32-within-one-ulp? [actual : u32] [expected : u32]) : bool
  (if (= (bit-and expected (cast 0x7fffffff : u32)) (cast 0 : u32))
    (= actual expected)
    (if (!=
      (bit-and actual (cast 0x80000000 : u32))
      (bit-and expected (cast 0x80000000 : u32)))
      false
      (if (> actual expected)
        (<= (- actual expected) (cast 1 : u32))
        (<= (- expected actual) (cast 1 : u32))))))

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
    if curated:
        print("      (unless")
        print("        (= (math.f64-to-bits (math.f64-log 0.0))")
        print("          (cast 0xfff0000000000000 : u64))")
        print("        (return 200001))")
        print("      (unless")
        print("        (= (math.f64-to-bits")
        print("          (math.f64-log (math.f64-from-bits 0x8000000000000000)))")
        print("          (cast 0xfff0000000000000 : u64))")
        print("        (return 200002))")
        print("      (unless (math.f64-nan? (math.f64-log -1.0)) (return 200003))")
        print("      (unless")
        print("        (math.f64-nan? (math.f64-log (math.f64-negative-infinity)))")
        print("        (return 200004))")
        print("      (unless")
        print("        (= (math.f64-to-bits (math.f64-log (math.f64-positive-infinity)))")
        print("          (cast 0x7ff0000000000000 : u64))")
        print("        (return 200005))")
        print("      (unless (math.f64-nan? (math.f64-log (math.f64-quiet-nan)))")
        print("        (return 200006))")
        print("      (unless")
        print("        (= (math.f32-to-bits (math.f32-log (cast 0.0 : f32)))")
        print("          (cast 0xff800000 : u32))")
        print("        (return 200007))")
        print("      (unless")
        print("        (= (math.f32-to-bits")
        print("          (math.f32-log (math.f32-from-bits (cast 0x80000000 : u32))))")
        print("          (cast 0xff800000 : u32))")
        print("        (return 200008))")
        print("      (unless (math.f32-nan? (math.f32-log (cast -1.0 : f32)))")
        print("        (return 200009))")
        print("      (unless")
        print("        (math.f32-nan? (math.f32-log (math.f32-negative-infinity)))")
        print("        (return 200010))")
        print("      (unless")
        print("        (= (math.f32-to-bits (math.f32-log (math.f32-positive-infinity)))")
        print("          (cast 0x7f800000 : u32))")
        print("        (return 200011))")
        print("      (unless (math.f32-nan? (math.f32-log (math.f32-quiet-nan)))")
        print("        (return 200012))")
    print("      0)))")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit", action="store_true")
    parser.add_argument("--sample", type=int, metavar="COUNT")
    parser.add_argument("--fixture", type=int, metavar="COUNT")
    parser.add_argument("--output", type=pathlib.Path, metavar="PATH")
    parser.add_argument("--seed", type=int, default=5228)
    args = parser.parse_args()
    if args.sample is not None and args.sample <= 0:
        parser.error("--sample must be positive")
    if args.fixture is not None and args.fixture <= 0:
        parser.error("--fixture must be positive")
    if sum(int(value) for value in (args.emit, args.sample is not None, args.fixture is not None)) > 1:
        parser.error("--emit, --sample, and --fixture are mutually exclusive")
    if args.output is not None and args.sample is None and args.fixture is None:
        parser.error("--output requires --sample or --fixture")

    lib = load_mpfr()
    if args.sample is not None:
        if args.output is None:
            emit_program(lib, args.sample, args.seed, False)
        else:
            with args.output.open("w", encoding="utf-8", newline="\n") as stream:
                with contextlib.redirect_stdout(stream):
                    emit_program(lib, args.sample, args.seed, False)
        return 0
    if args.fixture is not None:
        if args.output is None:
            emit_program(lib, args.fixture, args.seed, True)
        else:
            with args.output.open("w", encoding="utf-8", newline="\n") as stream:
                with contextlib.redirect_stdout(stream):
                    emit_program(lib, args.fixture, args.seed, True)
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
                f"log-f{width}-bits: expected {len(actual)} entries, found {len(expected)}",
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
