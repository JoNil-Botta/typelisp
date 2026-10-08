;; Prelude `any?` and `all?` accept the sources of `for` and stop at the first
;; item that decides the answer. `main` returns 42 only when every answer and
;; every predicate count is right.
(import stdlib.iterator)

(defstruct Seq
  (slots (__tl_dyn-array i64))
  (len i64))

(define predicate-calls : i64
  0)

(define (counted-even? [value : i64]) : bool
  (begin
    (set! predicate-calls (+ predicate-calls 1))
    (= (% value 2) 0)))

(define (calls-after [answer : bool] [expected-answer : bool]) : i64
  (if (= answer expected-answer)
    (let
      [calls : i64 predicate-calls]
      (begin
        (set! predicate-calls 0)
        calls))
    -1))

(define (main) : i64
  (let
    [fixed : (Array i64 4) (array 1 3 4 5)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (begin
      (set! (array-ref slots 0) 2)
      (set! (array-ref slots 1) 4)
      (set! (array-ref slots 2) 7)
      (let
        [seq : Seq (Seq slots 3)]
        [found-even : i64
          (calls-after
            (any? [value (& fixed)]
              (counted-even? (deref value)))
            true)]
        [all-even : i64
          (calls-after
            (all? [value (& seq)]
              (counted-even? (deref value)))
            false)]
        [even-index : i64
          (calls-after
            (any? [index (iterator.range 0 10)]
              (= index 6))
            true)]
        [none : bool
          (any? [index (iterator.range 3 3)]
            true)]
        [vacuous : bool
          (all? [index (iterator.range 3 3)]
            false)]
        (cond
          ;; stops at 4, the third item
          [(not (= found-even 3)) 1]
          ;; stops at 7, the third item
          [(not (= all-even 3)) 2]
          [(not (= even-index 0)) 3]
          [none 4]
          [(not vacuous) 5]
          [else 42])))))