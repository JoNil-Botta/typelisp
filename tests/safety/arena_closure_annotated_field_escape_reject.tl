;; #9770: as arena_closure_field_escape_reject, through a plain annotation.
(defstruct S
  (f (-> i64)))

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (let
      [s : S
        (S
          (lambda () : i64
            x))]
      s.f)))

(define (main) : i64
  ((mk 42)))