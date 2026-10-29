;; Establish the whole outer scope before elaborating its first callback.
(define (bad [callback : (-> (& a i64) i64)] [anchor : (& a i64)]) : i64
  (let [local : i64 1]
    (+ (callback (& local)) (deref anchor))))
(define (main) : i64 0)
