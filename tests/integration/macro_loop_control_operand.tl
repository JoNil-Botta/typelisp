;; Macro expansion checks a loop body as a loop target, as the typechecker
;; does, so a `when` or `unless` operand may `break` or `continue` the
;; enclosing `while`, also when `for` produced that `while`. Expansion used to
;; check those operands outside any loop and reject them with "break requires
;; enclosing scalar while". `main` returns 42 only when every loop stops where
;; it should.
(import stdlib.iterator)

(define (while-total) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (while (< index 10)
      (set! index (+ index 1))
      (when (= index 3) (continue))
      (unless (< index 5) (break))
      (set! total (+ total index)))
    ;; 1 + 2 + 4
    total))

(define (for-total) : i64
  (let
    [total : i64 0]
    (for [index (iterator.range 0 10)]
      (when (= index 1) (continue))
      (when (= index 4) (break))
      (set! total (+ total index)))
    ;; 0 + 2 + 3
    total))

(define (main) : i64
  (if (and (= (while-total) 7) (= (for-total) 5))
    42
    1))