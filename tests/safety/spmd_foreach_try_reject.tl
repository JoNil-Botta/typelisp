;: SPEC SPMD contract: foreach bodies do not support try-style early exits.
(defenum ResultI64
  (OkI64 i64)
  (ErrI64 i64))

(define (main [out : (Array i64)] [flag : bool] [n : i64]) : ResultI64
  (begin
    (foreach
      ([i : i64 0 n])
      (array-set!
        out
        i
        (try
          (if flag
            (OkI64 1)
            (ErrI64 i)))))
    (OkI64 0)))