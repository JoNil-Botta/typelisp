;: A Copy payload matched through a shared reference binds by value, so it is
;: no longer a reference to dereference.
(defenum E
  (A i64)
  (B))

(define (is-a3 [e : (& E)]) : bool
  (match e
    [(E.A k) (= (deref k) 3)]
    [(E.B) false]))

(define (main) : i64
  (let
    [e (E.A 3)]
    (if (is-a3 (& e))
      0
      1)))