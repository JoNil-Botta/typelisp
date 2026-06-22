(import "stdlib/test.tl")

(defstruct Wide
  (a i64)
  (b i64)
  (c i64))

(defenum WideStatus
  (WideOk Wide i64)
  (WideErr i64))

(defenum BuildMode
  (Build i64)
  (Fallback))

(define (wide-sum [w : Wide]) : i64
  (+ (struct-get w a) (+ (struct-get w b) (struct-get w c))))

(define (make-wide-stack-sret
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : Wide
  (Wide (+ a b) (+ c d) (+ e f)))

(define (make-status-stack-sret
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : WideStatus
  (WideOk (make-wide-stack-sret a b c d e f) 9))

(define (match-direct-status [mode : BuildMode]) : WideStatus
  (match mode
    [(Build base) (WideOk (Wide base (+ base 1) (+ base 2)) 8)]
    [Fallback (WideErr 99)]))

(define (status-score [status : WideStatus]) : i64
  (match status
    [(WideOk w marker) (+ marker (wide-sum w))]
    [(WideErr code) code]))

(define (adjacent-aggregate-local-score [seed : i64]) : i64
  (let
    [before : i64 5]
    [status : WideStatus (WideOk (Wide seed (+ seed 1) (+ seed 2)) 4)]
    [after : i64 6]
    (match status
      [(WideOk w marker) (+ before (+ after (+ marker (wide-sum w))))]
      [(WideErr code) code])))

(test
  aggregate-sret-stack-args
  (assert-i64-eq
    (wide-sum (make-wide-stack-sret 1 2 3 4 5 6))
    21
    "hidden sret pointer should survive spilled stack arguments"))

(test
  aggregate-enum-sret-stack-args
  (assert-i64-eq
    (status-score (make-status-stack-sret 1 2 3 4 5 6))
    30
    "aggregate enum sret should preserve nested struct payload"))

(test
  aggregate-enum-match-direct-return
  (begin
    (assert-i64-eq
      (status-score (match-direct-status (Build 10)))
      41
      "direct aggregate enum return from match arm should be safe")
    (assert-i64-eq
      (status-score (match-direct-status Fallback))
      99
      "fallback aggregate enum match arm should be safe")))

(test
  aggregate-local-adjacent-scalars
  (assert-i64-eq
    (adjacent-aggregate-local-score 10)
    48
    "aggregate enum local should not overwrite adjacent scalar locals"))