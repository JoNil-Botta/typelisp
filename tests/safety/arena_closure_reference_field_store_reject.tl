;; #9770: a function value read through a reference takes the referent's arena
;; tags, and the reference's lifetime when that is an arena region: `(& s)` of
;; an arena value borrows at the arena's lifetime, so `p.f` keeps `r`.
(defstruct S
  (f (-> i64)))

(define (run [x : i64] [o : (-> i64)]) : i64
  (let
    [k : (-> i64) o]
    (begin
      (with-arena
        r
        (let
          [s
            (S
              (lambda () : i64
                x))]
          [p (& s)]
          (set! k p.f)))
      (k))))

(define (main) : i64
  (run
    42
    (lambda () : i64
      0)))