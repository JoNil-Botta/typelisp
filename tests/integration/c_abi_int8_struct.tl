;; #2386: an 8-byte all-integer struct is register-resident -- it lives in a GP
;; register, not a memory slot. The C ABI (System V and Win64 alike) also passes
;; and returns such a struct in a single register, so the lowering must hand the
;; register word straight across the call boundary rather than treating it as a
;; pointer to spill/reload. This exercises both directions (by-value arg + by-value
;; return) plus a struct-get on the register-resident return value.
(defstruct W8
  (a i64))

(extern (w8-make [arg0 : i64]) : W8 (:symbol "tl_cabi_w8_make"))

(extern (w8-use [arg0 : W8]) : i64 (:symbol "tl_cabi_w8_use"))

(define (main) : i64
  (let
    [w : W8 (w8-make 20)]
    [used : i64 (w8-use w)]
    [field : i64 (struct-get w a)]
    (if (= used 140)
      (if (= field 40)
        42
        2)
      1)))