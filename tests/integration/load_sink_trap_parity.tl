;; TRAP PARITY for the `load_sink` scheduling pass.
;;
;; `(bit-or (array-ref a i) (bit-and (array-ref b i) (bit-xor (array-ref c i)
;; -1)))` lowers all three element reads before any of its ALU ops, so
;; `load_sink` moves `a`'s `gep; load` pair down past `b`'s and `c`'s bounds
;; checks to reach the `bit-or` it feeds. That motion crosses an ABORT point.
;;
;; `b` is short, so the versioning guard fails, the checked clone runs, and
;; iteration 4 aborts inside `b`'s check -- after `a[4]`'s load in the
;; unscheduled program and before it in the scheduled one. A load has no
;; observable effect and its value is dead on the aborting path, so both
;; programs must print the same bytes on stdout, abort at the same site with
;; the same message, and exit with the same status. This fixture pins that:
;; the line printed before the loop must survive, and the abort must name b's
;; index and length, not a's.
(import stdlib.io)

(define (fold-row
  [a : (Array i64)]
  [b : (Array i64)]
  [c : (Array i64)]
  [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (bit-or
              (array-ref a i)
              (bit-and (array-ref b i) (bit-xor (array-ref c i) -1))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 8)]
    [b : (Array i64) (make-array i64 4)]
    [c : (Array i64) (make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref a i) 1)
          (set! (array-ref c i) 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 4)
        (begin
          (set! (array-ref b i) -1)
          (set! i (+ i 1))))
      (io.println "rows")
      (io.println "{}" (fold-row a b c 8))
      42)))