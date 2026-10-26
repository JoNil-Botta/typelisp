;; A `break` operand is a checked exit: it leaves the scope of the loop body's
;; `let` owner, whose cleanup obligation must be discharged first.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (take2 [a : i64] [b : i64]) : i64
  (+ a b))

(define (spin [limit : i64]) : i64
  (let
    [n : i64 0]
    (begin
      (while (< n limit)
        (let
          [h : Handle (Handle n)]
          (begin
            (take2 (break) 1)
            (cleanup-handle h))))
      n)))

(define (main) : i64
  (spin 3))