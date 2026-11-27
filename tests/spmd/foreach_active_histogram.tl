;; Collision histogram at N = 2^20 for instruction-count and wall-time
;; comparisons. A read-only slice holds the key sequence. Each bucket must
;; receive exactly 4096 entries.
(define (histogram [keys : (& (Slice i64))] [counts : (&mut (Slice i64))]) : unit
  (foreach
    ([i : i64 0 (length keys)])
    (foreach-active
      [lane : i64]
      (let
        [key : i64 (lane-value (array-ref keys i))]
        (set! (array-ref counts key) (+ 1 (array-ref counts key)))))))

(define (main) : i64
  (let
    [keys : (__tl_dyn-array i64) (__tl_make-array i64 1048576)]
    [counts : (Array i64 256) (make-array i64 256)]
    [i : i64 0]
    (while (< i (length keys))
      (set! (array-ref keys i) (bit-and (* i 37) 255))
      (set! i (+ i 1)))
    (histogram (slice-view keys 0 (length keys)) (&mut counts))
    (set! i 0)
    (while (< i 256)
      (when (!= (array-ref counts i) 4096) (return 1))
      (set! i (+ i 1)))
    42))