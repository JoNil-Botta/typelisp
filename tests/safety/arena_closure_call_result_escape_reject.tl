;; #9770: a call inside an arena may return a closure allocated there, so a
;; function-typed call result carries the active region.
(define (mkc [x : i64]) : (-> i64)
  (lambda () : i64
    x))

(define (mk [x : i64]) : (-> i64)
  (with-arena r (mkc x)))

(define (main) : i64
  ((mk 42)))