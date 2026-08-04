(import std)
(import ffi)

(extern (print-string [arg0 : String]) : unit (:abi c) (:symbol "tl_print_string"))
(extern (print-int [arg0 : i64]) : unit)

(define KEY_A : i64
  1)
(define KEY_B : i64
  2)
(define F64_LOW : f64
  1.5e-9)
(define F64_UPPER : f64
  2.5E+3)
(define F64_ONLY : f64
  1e10)
(define F32_NEG : f32
  -1e-5)
(define F32_PLUS : f32
  1e+5)
