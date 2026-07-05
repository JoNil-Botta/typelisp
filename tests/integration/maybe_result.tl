; maybe_result.tl - Monomorphic Maybe/Result convention witness for #228.
(import stdlib.string)
(import stdlib.result)
(import (result i64 String) as result_i64_string)
(import stdlib.option)
(import (option i64) as option_i64)

(define (find-answer [name : String]) : option_i64.Option
  (if (string.eq name "answer")
    (option_i64.Some 42)
    option_i64.None))

(define (read-small [text : String]) : result_i64_string.Result
  (if (string.eq text "7")
    (result_i64_string.ok 7)
    (result_i64_string.err (string.append "bad:" text))))

(define (maybe-score [m : option_i64.Option] [fallback : i64]) : i64
  (match m
    [(option_i64.Some value) value]
    [(option_i64.None) fallback]))

(define (result-score [r : result_i64_string.Result]) : i64
  (match r
    [(result_i64_string.Ok value) value]
    [(result_i64_string.Err message) (string-length message)]))

(define (main) : i64
  (let
    [hit : i64 (maybe-score (find-answer "answer") 0)]
    [miss : i64 (maybe-score (find-answer "missing") 10)]
    [ok : i64 (result-score (read-small "7"))]
    [err : i64 (result-score (read-small "no"))]
    (+ (+ hit miss) (+ ok err))))