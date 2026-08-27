;; bce_descending_counted_loop.tl - runtime parity for the multi-block bounds
;; check versioner's DESCENDING counter admission.
;;
;; `walk` is a do-while counted loop that steps its counter DOWN (`pos - 1`)
;; under a `>= 0` latch, with a second array read at `pos + 1`. The versioner
;; mirrors that range into the ascending [first, limit) pair its derivations
;; read (opt-bce-mb-counter-range) and emits the guard `0 <= n` / `n + 1 <=
;; len`, so the two calls below take opposite sides of it:
;;
;;   n = len - 1   guard holds, the check-free fast clone runs
;;   n = len       guard fails, the original loop runs with its checks
;;
;; Both must produce the same value the loop always produced -- `seed + n`,
;; since every `items` entry is positive and every `other` entry is zero -- and
;; neither may trap: the guard-failing call never reaches `other[pos + 1]`,
;; because that arm is unreachable for positive `items` entries. `len` is taken
;; from the process argument count so no size folds and the guard is a real run
;; time decision.
(import stdlib.io)

(define (walk
  [items : (& items (__tl_dyn-array i64))]
  [other : (& other (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [pos : i64 (- n 1)]
    (begin
      (while (>= pos 0)
        (begin
          (if (> (array-ref items pos) 0)
            (set! acc (+ acc (array-ref other pos)))
            (set! acc (bit-xor acc (array-ref other (+ pos 1)))))
          (if (< acc 0)
            (set! acc (- 0 acc))
            (set! acc (+ acc 1)))
          (set! pos (- pos 1))))
      acc)))

(define (fill-ones [items : (&mut items (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref items i) 1)
          (set! i (+ i 1))))
      unit)))

(define (main) : i64
  (let
    [len : i64 (+ 8 (io.arg-count))]
    [items (__tl_make-array i64 len)]
    [other (__tl_make-array i64 len)]
    (begin
      (fill-ones (&mut items) len)
      (if (and
        (= (walk (& items) (& other) (- len 1) 3) (+ 3 (- len 1)))
        (= (walk (& items) (& other) len 3) (+ 3 len)))
        42
        1))))