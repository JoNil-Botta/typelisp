; f32 negation must lower to the IEEE sign-bit XOR at runtime and agree with
; the comptime result. The operand is argv-fed so CTFE and the optimizer
; cannot fold the backend lowering away. refs #6914
(import stdlib.io)
(import stdlib.string)

(define (negf [x : f32]) : f32
  (neg x))

(define (main) : i64
  (let
    [x : f32 (cast (string.>int (io.arg 1)) : f32)]
    (if (and
      (= (negf x) (cast -6 : f32))
      (= (neg (negf x)) x)
      (< (negf x) (cast 0 : f32)))
      42
      1)))
