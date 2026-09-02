;; PRED-1's ASCENDING shape, and its own malformed twin: one source, two rows.
;;
;; `gt-walk` counts UP, so the first index it checks is the smallest one it will
;; ever check and the abort may NOT be moved ahead of the loop: by the time
;; `data[count-1]` would fail, `gt-mix` has been called `len` times and `acc`
;; carries their results. The check is therefore not hoisted. Instead the TRIP
;; RANGE is tightened to `min(count, data.len)`, the body runs unchecked, and
;; the check is re-issued on the way out on the index the next iteration would
;; have used -- so the loop performs exactly the iterations the original
;; performed, and then aborts exactly where the original aborted.
;;
;; The inner `while` and the call to `gt-mix` are both load-bearing. The call is
;; what keeps the loop VERSIONER out (it wants three derived checks per
;; duplicated call site and this loop offers one), and the nested loop is the
;; tightening's own admission: the rewrite costs a `min` per loop ENTRY and pays
;; a check per TRIP, and a loop that runs another loop per trip is the shape
;; that was measured to repay it. `(bit-and v 3)` keeps the inner trip count out
;; of the constant folder's reach.
;;
;; The twin is the SAME program with `bump` = 1: `gt-walk` is handed
;; `count = n + 1` while `gt-data` holds `n`, so the walk runs all `n` elements
;; and then must abort on `data[n]`. The re-issued check is the one that fires,
;; on the same index and the same length the original's next iteration would
;; have used, and it carries the original ok-label under the clone suffix the
;; span table strips -- so the abort site, the index, the length and the exit
;; status must be byte-identical to the base compiler's at every optimization
;; level, and so must `acc`'s effect on everything printed before it.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define gt-data : i64vec.Vec
  (zero-vec 1))

;; Non-tail recursive on purpose: the inliner will not absorb it, so the loop
;; below really does hold a direct call at the round the predication pass sees
;; it. An absorbed helper would leave a call-free body the loop VERSIONER clones
;; instead, and this fixture would stop watching what it is named for.
(define (gt-mix [a : i64] [b : i64] [depth : i64]) : i64
  (if (<= depth 0)
    (+ (* a 1000003) (* b 31))
    (+ 1 (gt-mix (+ a b) b (- depth 1)))))

(define (gt-walk [data-vec : (& data i64vec.Vec)] [count : i64]) : i64
  (let
    [data (i64vec.slots data-vec)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i count)
        (let
          [v : i64 (array-ref data i)]
          [j : i64 0]
          (begin
            (set! acc (gt-mix acc v 2))
            (while (< j (bit-and v 3))
              (begin
                (set! acc (+ acc j))
                (set! j (+ j 1))))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    (begin
      (set! gt-data (zero-vec n))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut gt-data)) i) (* i 7))
          (set! i (+ i 1))))
      (io.print-format "{}\n" (gt-walk (& gt-data) (+ n bump)))
      42)))