;; Exact decimal to binary64 parsing: the Clinger fast-path boundaries, ties
;; to even, subnormal and overflow edges, and the rarely taken branches of the
;; bignum long division behind the exact path (a first quotient-digit estimate
;; of 2^32 or more, a second estimate correction, and the add-back step).
(import stdlib.io)

(define (parse-bits-eq? [text : String] [want : u64]) : bool
  (match (io.float-parse-f64 text)
    [(io.IoFloatSomeF64 value) (= (io.float-f64-bits value) want)]
    [(io.IoFloatNoF64) false]))

(define (parse-overflows? [text : String]) : bool
  (match (io.float-parse-f64 text)
    [(io.IoFloatSomeF64 _) false]
    [(io.IoFloatNoF64) true]))

(define (parse-table-ok?) : bool
  (and
    (parse-bits-eq? "9007199254740991" 0x433fffffffffffff)
    (parse-bits-eq? "9007199254740992" 0x4340000000000000)
    (parse-bits-eq? "9007199254740993" 0x4340000000000000)
    (parse-bits-eq? "9007199254740995" 0x4340000000000002)
    (parse-bits-eq?
      "9007199254740993.0000000000000000000001"
      0x4340000000000001)
    (parse-bits-eq? "4503599627370497.5" 0x4330000000000002)
    (parse-bits-eq? "1e22" 0x4480f0cf064dd592)
    (parse-bits-eq? "1e23" 0x44b52d02c7e14af6)
    (parse-bits-eq? "1e-22" 0x3b5e392010175ee6)
    (parse-bits-eq? "0.1" 0x3fb999999999999a)
    (parse-bits-eq? "0.30000000000000004" 0x3fd3333333333334)
    (parse-bits-eq? "3.141592653589793238462643383279" 0x400921fb54442d18)
    (parse-bits-eq? "123456789012345678901234567890e-10" 0x43e56a95319d63e1)
    (parse-bits-eq? "1.7976931348623157e308" 0x7fefffffffffffff)
    (parse-bits-eq? "1.7976931348623158e308" 0x7fefffffffffffff)
    (parse-overflows? "1.7976931348623159e308")
    (parse-bits-eq? "2.2250738585072014e-308" 0x0010000000000000)
    (parse-bits-eq? "2.2250738585072011e-308" 0x000fffffffffffff)
    (parse-bits-eq? "4.9406564584124654e-324" 0x0000000000000001)
    (parse-bits-eq? "2.4703282292062327e-324" 0x0000000000000000)
    (parse-bits-eq? "2.4703282292062328e-324" 0x0000000000000001)
    (parse-bits-eq? "-2.5e-320" 0x80000000000013c4)
    (parse-bits-eq? "1e-400" 0x0000000000000000)))

;: The BigNum hi * 2^128 + mid * 2^64 + lo.
(define (bn-of [hi : u64] [mid : u64] [lo : u64]) : io.BigNum
  (let
    [top : io.BigNum (io.bn-from-u64 hi)]
    [top-shifted : io.BigNum (io.bn-shl-bits (& top) 64)]
    [middle : io.BigNum (io.bn-from-u64 mid)]
    [upper : io.BigNum (io.bn-add (& top-shifted) (& middle))]
    [upper-shifted : io.BigNum (io.bn-shl-bits (& upper) 64)]
    [low : io.BigNum (io.bn-from-u64 lo)]
    (io.bn-add (& upper-shifted) (& low))))

(define (div-round-eq? [num : io.BigNum] [den : io.BigNum] [want : u64]) : bool
  (= (io.float-round-div-u64 (& num) (& den)) want))

(define (division-table-ok?) : bool
  (and
    ;; First quotient-digit estimate 2^32 + 0, corrected down.
    (div-round-eq?
      (bn-of
        (cast 0 : u64)
        (cast 0x80000000 : u64)
        (cast 0x7fffffff00000000 : u64))
      (bn-of (cast 0 : u64) (cast 0 : u64) (cast 0x80000000ffffffff : u64))
      (cast 0xffffffff : u64))
    ;; Two estimate corrections.
    (div-round-eq?
      (bn-of
        (cast 0 : u64)
        (cast 0xcecc222f : u64)
        (cast 0x925c2162d937820c : u64))
      (bn-of (cast 0 : u64) (cast 0 : u64) (cast 0x80007fffffff : u64))
      (cast 0x19d96a6c87df3 : u64))
    (div-round-eq?
      (bn-of
        (cast 0 : u64)
        (cast 0x2c2c17c0268a7f1 : u64)
        (cast 0xfd66c893ffffffff : u64))
      (bn-of (cast 0 : u64) (cast 1 : u64) (cast 0x0000000180000000 : u64))
      (cast 0x2c2c17bfe4485b8 : u64))
    ;; The multiply-subtract borrows and the divisor is added back.
    (div-round-eq?
      (bn-of
        (cast 0x31a94e77303036 : u64)
        (cast 0x4f2bb6f2ac1ef67e : u64)
        (cast 0x521ff6d188ccf423 : u64))
      (bn-of
        (cast 0 : u64)
        (cast 0xfffffffff1446bea : u64)
        (cast 0xcb91ce37ffffffff : u64))
      (cast 0x31a94e77330bdc : u64))
    (div-round-eq?
      (bn-of
        (cast 0x80000001 : u64)
        (cast 0x7fffffff00000000 : u64)
        (cast 0x8000000000000000 : u64))
      (bn-of
        (cast 0x80000001 : u64)
        (cast 0x7fffffff00000000 : u64)
        (cast 0x8000000000000001 : u64))
      (cast 1 : u64))
    ;; Exact halves round to the even neighbour.
    (div-round-eq?
      (bn-of (cast 0 : u64) (cast 0 : u64) (cast 0x60730000012159 : u64))
      (bn-of (cast 0 : u64) (cast 0 : u64) (cast 0x20000000006 : u64))
      (cast 0x303a : u64))
    (div-round-eq?
      (bn-of (cast 0 : u64) (cast 0 : u64) (cast 0x6075000001215f : u64))
      (bn-of (cast 0 : u64) (cast 0 : u64) (cast 0x20000000006 : u64))
      (cast 0x303a : u64))))

(define (main) : i64
  (if (and (parse-table-ok?) (division-table-ok?))
    42
    1))