;; A struct without lifetime parameters names its reference field's lifetime
;; nominally: a constructor argument must carry exactly that lifetime, so a
;; local's reference cannot be stored and returned (#8449 M5).
(defstruct RefBox
  (value (& n i64)))

(define (escape) : RefBox
  (let
    [x : i64 1]
    (RefBox (& x))))

(define (main) : i64
  0)