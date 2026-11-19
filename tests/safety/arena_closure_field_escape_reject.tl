;; #9770: a function type is region-taggable, so a closure made in an arena and
;; read out of a struct field keeps the arena's region.
(defstruct S
  (f (-> i64)))

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (let
      [s
        (S
          (lambda () : i64
            x))]
      s.f)))

(define (main) : i64
  ((mk 42)))