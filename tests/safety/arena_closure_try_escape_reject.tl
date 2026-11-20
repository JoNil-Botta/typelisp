;; #9770: a closure leaving an arena through `try` keeps its region.
(defenum RE
  (Ok (-> i64))
  (Err i64))

(define (mk [x : i64]) : RE
  (RE.Ok
    (with-arena
      r
      (try
        (RE.Ok
          (lambda () : i64
            x))))))

(define (main) : i64
  (match (mk 42)
    [(RE.Ok f) (f)]
    [(RE.Err e) e]))