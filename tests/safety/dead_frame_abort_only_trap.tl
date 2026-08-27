;: SPEC safe-code contract: an out-of-bounds index still traps from a function
;: whose frame carries NO stack adjustment. The W1-frame packet drops the
;: prologue's 8-byte alignment pad when the only `call` in the body is the
;: never-taken `tl_oob_abort` edge, so the abort here is reached with
;: `%rsp % 16 == 0` rather than the ABI's 8. `tl_oob_abort` is a compiler-
;: emitted `never` handler that renders through raw syscalls and exits, so the
;: alignment it inherits is immaterial -- this fixture is what proves it.
;: The five loop-carried values force an EVEN callee-saved push run (the shape
;: that used to pay the pad); `probe` is out of range for a length-4 array.
(import stdlib.io)

(define (probe [xs : (__tl_dyn-array i64)] [n : i64] [k : i64]) : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [d : i64 4]
    [e : i64 5]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (* a i)))
          (set! acc (+ acc (* b i)))
          (set! acc (+ acc (* c i)))
          (set! acc (+ acc (* d i)))
          (set! acc (+ acc (* e i)))
          (set! a (+ a 1))
          (set! b (+ b 2))
          (set! c (+ c 3))
          (set! d (+ d 4))
          (set! e (+ e 5))
          (set! i (+ i 1))))
      (+ acc (+ (array-ref xs k) (+ a (+ b (+ c (+ d e)))))))))

(define (main) : i64
  (let
    [v : i64 (io.arg-count)]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (probe xs (+ v 4) (+ v 6))))