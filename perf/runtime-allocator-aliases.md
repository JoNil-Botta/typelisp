# Inline fixed allocations through runtime aliases

An extern declared with `(:symbol "tl_alloc")` reaches the same runtime allocator
as a direct call. The backend previously required the language-level builtin
name before selecting its existing inline allocation path. A call such as
`(reserve 24)` therefore paid for argument setup, a call and the general size
checks even after constant propagation exposed its fixed size.

The fast path now also accepts a mutable pointer result when the resolved call
symbol is exactly `tl_alloc` and the runtime plan provides the allocator. The
existing one-argument, positive 1–64-byte size gate remains. An unrelated symbol,
integer or floating alias result, a variable/unsupported size, or a program that
does not provide the runtime still uses its ordinary call. This is an emission
change; optimizer memory-effect assumptions are unchanged.

The existing fast path rounds to eight bytes, checks the current arena and
shared flag, and checks capacity before advancing the cursor. Shared arenas and
full segments call the same fixed-size runtime fallback as direct allocations.
The register allocator already reserves both general-register scratch roles
for every direct call with this literal-argument shape, regardless of its name.

## Measurement

On Linux x86-64, Ryzen 9 9950X, a two-million-iteration raw allocation loop
allocating 24 bytes, writing three i64 fields and reading the last field executes
**58,000,824 → 40,000,824** instructions (−31.0%). The output checksum is
`2000057000000` on both compilers. Cachegrind uses `--cache-sim=no
--branch-sim=no --vex-guest-chase=no`. Fifteen rotated runs pinned to CPU 14 give
medians of **4.051 → 3.279 ms** (−19.1%), including startup, on a shared host.
These are focused allocator measurements, not LLVM parity or a whole-program
string-performance claim. All 45 existing benchmark assemblies are unchanged.

The probe imports `stdlib.io` and `stdlib.string`, declares
`(extern (reserve [bytes : i64]) : (MutPtr u8) (:symbol "tl_alloc"))`, reads its
round count from argv, and repeats:

```lisp
(let [p : (MutPtr i64) (unsafe (ptr-cast (reserve 24) : (MutPtr i64)))]
  (begin
    (unsafe (ptr-write! p i))
    (unsafe (ptr-write! (ptr-offset p 1) (+ i 17)))
    (unsafe (ptr-write! (ptr-offset p 2) (+ i 29)))
    (set! sum (+ sum (unsafe (ptr-read (ptr-cast (ptr-offset p 2) : (Ptr i64))))))
    (set! i (+ i 1))))
```

## Coverage

Backend smoke tests run source through constant propagation and register
allocation on Linux and Windows. They check native/C aliases, rounded sizes,
unsupported sizes, other symbols, and non-pointer results. The integration
fixture keeps six register-group values and an earlier allocation live across
native and C aliases. It tests an ordinary arena, forces the next 24-byte
allocation to grow the arena, verifies that growth occurred, and tests an atomic
arena. Both native manifests run the fixture at opt0, opt1 and opt2.
