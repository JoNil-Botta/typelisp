; maybe_result.tl - Monomorphic Maybe/Result convention witness for #228.
(import "stdlib/string.tl")

(defenum MaybeI64
  (NoneI64)
  (SomeI64 i64))

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (find-answer [name : String]) : MaybeI64
  (if (string-eq name "answer")
    (SomeI64 42)
    NoneI64))

(define (read-small [text : String]) : ResultI64
  (if (string-eq text "7")
    (OkI64 7)
    (ErrI64 (string-append "bad:" text))))

(define (maybe-score [m : MaybeI64] [fallback : i64]) : i64
  (match m
    [(SomeI64 value) value]
    [(NoneI64) fallback]))

(define (result-score [r : ResultI64]) : i64
  (match r
    [(OkI64 value) value]
    [(ErrI64 message) (string-length message)]))

(define (main) : i64
  (let
    [hit : i64 (maybe-score (find-answer "answer") 0)]
    [miss : i64 (maybe-score (find-answer "missing") 10)]
    [ok : i64 (result-score (read-small "7"))]
    [err : i64 (result-score (read-small "no"))]
    (+ (+ hit miss) (+ ok err))))