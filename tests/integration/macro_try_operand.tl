;; Try must expand the whole operand before typechecking its result carrier.
;; lint-allow: unused-import
(import stdlib.comptime)

(defenum NumberResult
  (Ok i64)
  (Err i64))

(defstruct Counter
  (ticks i64))

(defmacro (next-result [place : Expr] [fail : Expr]) : Expr
  `(let
    [value : i64
      (begin
        (set! ,place (+ ,place 1))
        ,place)]
    (if ,fail
      (NumberResult.Err value)
      (NumberResult.Ok value))))

(defmacro (nested-result [place : Expr] [fail : Expr]) : Expr
  `(next-result ,place ,fail))

(defmacro (generated-try [place : Expr]) : Expr
  `(try (nested-result ,place false)))

(define (identity-result [result : NumberResult]) : NumberResult
  result)

(define (run [counter : (&mut counter Counter)] [fail : bool]) : NumberResult
  (let
    [value : i64 (try (identity-result (nested-result counter.ticks fail)))]
    (begin
      (set! counter.ticks (+ counter.ticks 10))
      (NumberResult.Ok (+ value 41)))))

(define (run-generated [counter : (&mut counter Counter)]) : NumberResult
  (let
    [value : i64 (generated-try counter.ticks)]
    (NumberResult.Ok (+ value 41))))

(define (main) : i64
  (let
    [value : i64 99]
    [success : Counter (Counter 0)]
    [failure : Counter (Counter 0)]
    [generated : Counter (Counter 0)]
    [success-result : NumberResult (run (&mut success) false)]
    [failure-result : NumberResult (run (&mut failure) true)]
    [generated-result : NumberResult (run-generated (&mut generated))]
    (if (and
      (= value 99)
      (= success.ticks 11)
      (= failure.ticks 1)
      (= generated.ticks 1)
      (match success-result
        [(NumberResult.Ok n) (= n 42)]
        [_ false])
      (match failure-result
        [(NumberResult.Err n) (= n 1)]
        [_ false])
      (match generated-result
        [(NumberResult.Ok n) (= n 42)]
        [_ false]))
      42
      1)))