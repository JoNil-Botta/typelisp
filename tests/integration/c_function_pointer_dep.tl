(define (relay [f : (CFunc non-null (-> i64 i64))]) : (CFunc
    non-null
    (-> i64 i64))
  f)