(define (id-prog [q : (& program i64)]) : (& program i64)
  q)

(define (use-cb [cb : (-> (& outer i64) (& program i64))]) : (& program i64)
  (let
    [x : i64 7]
    (cb (& x))))

(define (main) : i64
  (deref (use-cb id-prog)))