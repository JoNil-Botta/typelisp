;; A struct or enum holding a reference must declare its lifetimes: an
;; unparameterized one names none, so a value could outlive its referent once
;; it leaves the function (#8449 M5; legacy typing accepted the declaration).
(defstruct RefBox
  (value (& n i64)))

(define (read-box [n : i64]) : i64
  (let
    [box : RefBox (RefBox (& n))]
    (deref box.value)))

(define (main) : i64
  (read-box 42))