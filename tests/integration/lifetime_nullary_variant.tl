;; A bare nullary constructor from a lifetime-parameterized enum must lower like
;; the explicit call form, not escape to the linker as a value symbol.
(defstruct Bag
  (value i64))

(defenum Lookup
  (:lifetimes bag)
  (Missing)
  (Found (& bag i64)))

(define (missing [_bag : (& bag Bag)]) : (Lookup bag)
  Missing)

(define (main) : i64
  (let
    [bag : Bag (Bag 1)]
    (match (missing (& bag))
      [Missing 42]
      [(Found value) 0])))