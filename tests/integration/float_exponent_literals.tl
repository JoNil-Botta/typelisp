;; Runtime coverage for decimal exponent literals in f64 and contextual f32
;; positions.  Bit comparisons keep the parser/conversion result exact.
(import stdlib.math)

(define (main) : i64
  (let
    [f64-small : f64 1.5e-9]
    [f64-ten : f64 1e10]
    [f64-upper : f64 2.5E+3]
    [f64-tiny : f64 1.0e-300]
    [f64-large : f64 3.4e38]
    [f64-negative : f64 -1.5e-9]
    [f32-small : f32 1.5e-9]
    [f32-large : f32 3.4e38]
    (if (and
      (= (math.f64-to-bits f64-small) 0x3e19c511dc3a41df)
      (= (math.f64-to-bits f64-ten) 0x4202a05f20000000)
      (= (math.f64-to-bits f64-upper) 0x40a3880000000000)
      (= (math.f64-to-bits f64-tiny) 0x01a56e1fc2f8f359)
      (= (math.f64-to-bits f64-large) 0x47eff933c78cdfad)
      (= (math.f64-to-bits f64-negative) 0xbe19c511dc3a41df)
      (= (math.f32-to-bits f32-small) 0x30ce288f)
      (= (math.f32-to-bits f32-large) 0x7f7fc99e))
      42
      1)))