;; #9770: as arena_closure_field_escape_reject, through a Box deref.
(defstruct S
  (f (-> i64)))

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (deref
      (box
        (S
          (lambda () : i64
            x)))).f))

(define (main) : i64
  ((mk 42)))