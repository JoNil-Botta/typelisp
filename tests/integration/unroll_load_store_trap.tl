(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

;; Trap parity for the load-AND-store body class of the counted-loop unroller.
;;
;; `merge!` is that class's exact shape. The first call is entirely in bounds,
;; so whichever form the pipeline chose -- the rolled loop, the unrolled pair,
;; or a versioned fast clone of either -- actually executes. The second call
;; then walks one element PAST the destination's length, so the abort has to
;; name that element and no other.
;;
;; The argument selects the destination length, which is also the index the
;; abort must report: `4` puts the failing trip at an even index and `5` at an
;; odd one, i.e. on either side of a two-copy group boundary. A rewrite that
;; let the unrolled body run one group too far would abort at the wrong index
;; (or not at all); one that mis-ordered the copies would abort at the right
;; index but after the wrong number of stores, which the completed first call's
;; checksum print pins.
(define (merge!
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref dst i) (bit-or (array-ref dst i) (array-ref src i)))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [len : i64 (string.>int (io.arg 1))]
    [dst : (__tl_dyn-array i64) (array.make-array i64 len)]
    [src : (__tl_dyn-array i64) (array.make-array i64 (+ len 1))]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! (array-ref dst i) (* i 3))
          (set! (array-ref src i) (* i 5))
          (set! i (+ i 1))))
      (set! (array-ref src len) 7)
      ;; In bounds: the merge runs to completion.
      (merge! (&mut dst) (& src) len)
      (set! i 0)
      (while (< i len)
        (begin
          (set! acc (+ (* acc 1000003) (array-ref dst i)))
          (set! i (+ i 1))))
      (io.println "{}" acc)
      ;; One element past the destination: the abort must name index `len`.
      (merge! (&mut dst) (& src) (+ len 1))
      0)))