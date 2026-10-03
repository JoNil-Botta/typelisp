;; Calls to `[comptime T : type]` functions inside typed macro operands: the
;; prelude `when`/`unless`/`and`/`or`/`cond`, a user macro operand typed i64,
;; nested macros, and a `cond` initializer checked against a `let` annotation.
;; Each operand is checked before specialization rewrites the call (#8578).
;; `main` returns 42 only when every branch ran as written.
(defmacro (ident [x : i64]) : i64
  x)

(define (pick [comptime T : type] [x : T]) : T
  x)

(define (first [comptime T : type] [xs : (& (Slice T))]) : T
  (array-ref xs 0))

(define (second [comptime A : type] [comptime B : type] [_a : A] [b : B]) : B
  b)

(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    [score : i64 0]
    [picked : i64
      (cond [(pick (type bool) false) 0] [else (pick (type i64) 2)])]
    (when
      (= (first (type i64) (slice-view items 0 3)) 1)
      (set! score (+ score 10)))
    (unless (= (pick (type i64) 1) 2) (set! score (+ score 10)))
    (when
      (and
        (pick (type bool) true)
        (or false (second (type i64) (type bool) 7 true)))
      (set! score (+ score 10)))
    (set! score (+ score (ident (ident (pick (type i64) 8)))))
    ;; 10 + 10 + 10 + 8 + 2 + 2
    (+ score (+ picked (ident (second (type bool) (type i64) false 2))))))