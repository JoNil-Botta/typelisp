(import stdlib.io)

;; Argument marshalling for a call that OVERFLOWS the ABI's argument registers
;; while its arguments stay REGISTER-HOMED.
;;
;; Nine GP arguments spill three onto the outgoing stack area on System V (six
;; argument registers) and five on Windows (four), so both ABIs run the overflow
;; path here. `rev9-caller` hands its own parameters over fully reversed, which
;; makes every stack-passed argument read out of a register that is also some
;; other argument's DESTINATION register: the naive ascending marshalling writes
;; the destination first and the stack store then reads a clobbered source. The
;; sound order stores the overflow before it writes any argument register.
;;
;; `mix9-caller` is the other half of the shape: values computed in the caller
;; and live across the call take callee-saved homes, and the same value appears
;; both in an argument register and on the stack, so a stack store whose source
;; register is not an argument register has to be marshalled correctly too.
;;
;; Values come from (io.arg-count) so the optimizer cannot fold the calls away,
;; and the callee is self-recursive on a branch that never runs so it is not
;; inlined into either caller: the real call and its marshalling must be emitted.
(define (nine-callee
  [a0 : i64]
  [a1 : i64]
  [a2 : i64]
  [a3 : i64]
  [a4 : i64]
  [a5 : i64]
  [a6 : i64]
  [a7 : i64]
  [a8 : i64]) : i64
  (if (< a0 0)
    (nine-callee (- 0 a0) a1 a2 a3 a4 a5 a6 a7 a8)
    (+
      (* a0 100000000)
      (+
        (* a1 10000000)
        (+
          (* a2 1000000)
          (+
            (* a3 100000)
            (+ (* a4 10000) (+ (* a5 1000) (+ (* a6 100) (+ (* a7 10) a8))))))))))

(define (rev9-caller
  [a0 : i64]
  [a1 : i64]
  [a2 : i64]
  [a3 : i64]
  [a4 : i64]
  [a5 : i64]
  [a6 : i64]
  [a7 : i64]
  [a8 : i64]) : i64
  (nine-callee a8 a7 a6 a5 a4 a3 a2 a1 a0))

(define (mix9-caller [p : i64] [q : i64]) : i64
  (let
    [u : i64 (+ (* p 3) q)]
    [v : i64 (+ (* q 5) p)]
    [w : i64 (+ u v)]
    [r : i64 (nine-callee q p u v w p q u v)]
    (+ r (+ u (+ v w)))))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [rev : i64
      (rev9-caller
        (* n 1)
        (* n 2)
        (* n 3)
        (* n 4)
        (* n 5)
        (* n 6)
        (* n 7)
        (* n 8)
        (* n 9))]
    [mix : i64 (mix9-caller (* n 2) (* n 1))]
    (if (and (= rev 987654321) (= mix 127842205))
      42
      1)))