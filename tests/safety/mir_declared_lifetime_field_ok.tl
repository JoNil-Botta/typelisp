;; A struct and an enum declaring the lifetime of the reference they hold:
;; the ownership graph tracks its loan (#8449 M5).
(defstruct RefBox
  (:lifetimes n)
  (value (& n i64)))

(defenum RefOption
  (:lifetimes n)
  (SomeRef (& n i64))
  (NoRef))

(define (read-box [n : i64]) : i64
  (let
    [box : (RefBox n) (RefBox (& n))]
    (deref box.value)))

(define (read-option [n : i64]) : i64
  (match (SomeRef (& n))
    [(SomeRef value) (deref value)]
    [(NoRef) 0]))

(define (main) : i64
  (+ (read-box 40) (read-option 2)))