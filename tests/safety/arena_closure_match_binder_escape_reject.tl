;; #9770: a match binder of a closure payload keeps the arena's region.
(defenum E
  (A (-> i64))
  (B))

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (match (E.A
      (lambda () : i64
        x))
      [(E.A f) f]
      [(E.B)
        (lambda () : i64
          0)])))

(define (main) : i64
  ((mk 42)))