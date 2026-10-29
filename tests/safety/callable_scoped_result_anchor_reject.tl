;; The outer result also mentions a, fixing the callback's a.
(define (bad [callback : (-> (& a i64) (& a i64))]) : (& a i64)
  (let [local : i64 1]
    (callback (& local))))
(define (main) : i64 0)
