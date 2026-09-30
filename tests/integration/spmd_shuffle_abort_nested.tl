; #7497: a shuffle's selector abort fires while its staging region is live,
; three calls below main. The fatal backtrace must name every caller: the
; region is ordinary frame state, so a frame-pointer walk (Linux) and the
; unwind tables (Windows) both recover the caller chain.
; Selector 99 is invalid for every gang width, scalar included.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (permute-kernel
  [xs : (& xs i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]
  [selector : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (set!
        (array-ref out-slots i)
        (spmd-shuffle (array-ref xs-slots i) selector)))))

(define (middle [xs : (& xs i64v.Vec)] [out : (&mut out i64v.Vec)] [n : i64]) : i64
  (begin
    (permute-kernel xs out n 99)
    n))

(define (outer [n : i64]) : i64
  (let
    [xs : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    (+ (middle (& xs) (&mut out) n) 1)))

(define (main) : i64
  (- (outer 16) 1))