;; GS-1 runtime coverage: the `gvn-table-invalidate-var` shape. A module-global
;; free-list is walked by `while (node >= 0 && !found)`, and the descriptor of
;; the `next` array is loop-invariant, so LICM lifts it into the function's entry
;; block -- where it runs on every call including the ones whose list is empty.
;; The uniform-phi substitution retires the flag phi `flag_exit` leaves behind,
;; the rotation gives the loop a depth-0 landing block, and `guard_sink` moves
;; the descriptor derivations into it, below the `node >= 0` test.
;;
;; Both paths are exercised: the empty list (head = -1, the guard's bypass) and
;; the populated list, with a hit and a miss. The printed numbers must not depend
;; on any of that.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(define gs-next : i64vec.Vec
  (zero-vec 1))
(define gs-key : i64vec.Vec
  (zero-vec 1))
(define gs-head : i64
  -1)
(define gs-hits : i64
  0)
(define gs-steps : i64
  0)

(define (gs-mentions? [node : i64] [var : i64]) : bool
  (= (vec-ref (& gs-key) node) var))

(define (gs-invalidate [var : i64]) : unit
  (let
    [node : i64 gs-head]
    [found : bool false]
    (begin
      (while
        (and (>= node 0) (not found))
        (begin
          (set! gs-steps (+ gs-steps 1))
          (if (gs-mentions? node var)
            (set! found true)
            (set! node (vec-ref (& gs-next) node)))))
      (when
        found
        (set! gs-hits (+ gs-hits 1))))))

(define (gs-build! [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (set! gs-next (zero-vec count))
      (set! gs-key (zero-vec count))
      (while
        (< i count)
        (begin
          (vec-set! (&mut gs-next) i (- i 1))
          (vec-set! (&mut gs-key) i (* i 10))
          (set! i (+ i 1))))
      (set! gs-head (- count 1)))))

(define (main) : i64
  (let
    [empty-calls : i64 0]
    (begin
      ;; Empty list: every call takes the guard's bypass.
      (while
        (< empty-calls 4)
        (begin
          (gs-invalidate (* empty-calls 10))
          (set! empty-calls (+ empty-calls 1))))
      (io.print-format "{}\n" gs-hits)
      (io.print-format "{}\n" gs-steps)
      (gs-build! 6)
      ;; A hit near the head, a hit near the tail, and a miss that walks the
      ;; whole list.
      (gs-invalidate 50)
      (gs-invalidate 0)
      (gs-invalidate 7)
      (io.print-format "{}\n" gs-hits)
      (io.print-format "{}\n" gs-steps)
      42)))
