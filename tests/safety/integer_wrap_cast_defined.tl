;: SPEC safe-code contract: integer overflow wraps and supported casts are
;: defined, not undefined behavior.
(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(define (add8 [a : i8] [b : i8]) : i8
  (+ a b))

(define (sub8 [a : i8] [b : i8]) : i8
  (- a b))

(define (mul8 [a : i8] [b : i8]) : i8
  (* a b))

(define (neg8 [a : i8]) : i8
  (neg a))

(define (addu8 [a : u8] [b : u8]) : u8
  (+ a b))

(define (main) : i64
  (core/cond
    (!= (cast (add8 (cast 127 : i8) (cast 1 : i8)) : i64) -128)
    1
    (!= (cast (sub8 (cast -128 : i8) (cast 1 : i8)) : i64) 127)
    2
    (!= (cast (mul8 (cast 16 : i8) (cast 16 : i8)) : i64) 0)
    3
    (!= (cast (neg8 (cast -128 : i8)) : i64) -128)
    4
    (!= (cast (addu8 (cast 255 : u8) (cast 1 : u8)) : i64) 0)
    5
    (!= (cast (cast -1 : i8) : i64) -1)
    6
    (!= (cast (cast 255 : u8) : i64) 255)
    7
    (!= (cast (cast (cast 257 : u16) : u8) : i64) 1)
    8
    (!= (cast (cast (cast 300 : u16) : char) : i64) 44)
    9
    42))