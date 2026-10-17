;: `try` propagates an error or absence by returning the enclosing family's
;: variant with the same payload, and yields the success payload otherwise.
(defenum ResultI64
  (OkI64 i64)
  (ErrI64 (__tl_dyn-array i64)))

(defenum MaybeI64
  (SomeI64 i64)
  (NoneI64))

(define (read-small [n : i64]) : ResultI64
  (if (< n 10)
    (ResultI64.OkI64 n)
    (ResultI64.ErrI64 (__tl_make-array i64 n))))

(define (plus-one [n : i64]) : ResultI64
  (let
    [value : i64 (try (read-small n))]
    (ResultI64.OkI64 (+ value 1))))

(define (find [n : i64]) : MaybeI64
  (if (> n 0)
    (MaybeI64.SomeI64 n)
    MaybeI64.NoneI64))

(define (double-found [n : i64]) : MaybeI64
  (MaybeI64.SomeI64 (* 2 (try (find n)))))

(define (main) : i64
  (+
    (match (plus-one 4)
      [(ResultI64.OkI64 v) v]
      [(ResultI64.ErrI64 _) 100])
    (match (plus-one 40)
      [(ResultI64.OkI64 v) v]
      [(ResultI64.ErrI64 items) (array-length items)])
    (match (double-found 0)
      [(MaybeI64.SomeI64 v) v]
      [(MaybeI64.NoneI64) -3])))