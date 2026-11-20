;; #9770: as arena_closure_field_escape_reject, through an array element.
(defstruct S
  (f (-> i64)))

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (array-ref
      (array
        (S
          (lambda () : i64
            x)))
      0).f))

(define (main) : i64
  ((mk 42)))