(define (use-cb [cb : (-> (& outer i64) i64)]) : i64
  0)

(define (go [p : (& a i64)]) : i64
  (use-cb
    (lambda ([q : (& a i64)]) : i64
      (deref q))))

(define (main) : i64
  0)