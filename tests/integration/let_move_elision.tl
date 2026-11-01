;; A `let` that moves a whole move-only binding may take over its storage
;; instead of copying it (#8449, `lower-let-may-adopt-moved-storage?`). Each
;; case checks the value the new binding holds after writes through it, and
;; that a source reassigned after the move keeps the two values apart.
(defstruct Acc
  (items (__tl_dyn-array i64))
  (total i64)
  (count i64))

(define (fresh [n : i64]) : Acc
  (Acc (__tl_make-array i64 2) n 0))

;; The moved parameter's storage becomes the accumulator's.
(define (fold-param [acc : Acc] [k : i64]) : i64
  (let
    [running : Acc acc]
    [i : i64 0]
    (while (< i k)
      (set! running.total (+ running.total i))
      (set! running.count (+ running.count 1))
      (set! i (+ i 1)))
    (+ running.total running.count)))

;; A moved local keeps its storage with the new binding.
(define (fold-local [k : i64]) : i64
  (let
    [start : Acc (fresh 10)]
    [running : Acc start]
    (set! running.total (+ running.total k))
    running.total))

;; The source is reassigned after the move, so the binding must own a copy:
;; writing the source again cannot change it.
(define (reassigned-source [k : i64]) : i64
  (let
    [source : Acc (fresh 5)]
    [kept : Acc source]
    (set! source (fresh 100))
    (set! source.total (+ source.total k))
    (+ kept.total source.total)))

(define (main) : i64
  ;; fold-param: 0+1+2+3 = 6 plus 4 steps on top of 7 -> 17
  ;; fold-local: 10 + 5 = 15
  ;; reassigned-source: 5 + 103 = 108
  (if (and
    (= (fold-param (fresh 7) 4) 17)
    (= (fold-local 5) 15)
    (= (reassigned-source 3) 108))
    42
    1))