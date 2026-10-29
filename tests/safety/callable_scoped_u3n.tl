(define (keep [q : (& a i64)] [_r : (& a i64)]) : (& a i64) q)
(define (use-cb3 [anchor : (& a i64)] [cb : (-> (& outer i64) (& a i64))]) : (& a i64)
  (let [x : i64 7] (cb (& x))))
(define (main) : i64 (let [v : i64 1] (deref (use-cb3 (& v) (lambda ([q : (& v i64)]) : (& v i64) q)))))
