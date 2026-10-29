;; A callback result supplies the enclosing signature's incoming a.
(define (from-callback [callback : (-> (& a i64))]) : (& a i64)
  (callback))
(define (main) : i64 0)
