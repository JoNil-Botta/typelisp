;; Headerless imported module used to verify that compiler-private intrinsics
;; resolve at their definition site after declarations are aggregated.
(define (private-sqrt [value : f64]) : f64
  (__tl_float_sqrt value))

(define (private-float-to-bits [value : f64]) : u64
  (__tl_float_to_bits value))

(define (private-float-from-bits [bits : u64]) : f64
  (__tl_float_from_bits bits))

(define (private-string-length [text : String]) : i64
  (__tl_string_length text))

(define (private-string-ref [text : String] [index : i64]) : char
  (__tl_string_ref text index))

(define (private-string-eq [left : String] [right : String]) : bool
  (__tl_string_eq left right))

(define (private-string-to-int [text : String]) : i64
  (__tl_string_to_int text))