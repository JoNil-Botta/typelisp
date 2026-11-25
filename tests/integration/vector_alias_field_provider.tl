;; A struct whose field names a generic alias that only this module imports.
;; vector_alias_field.tl puts it in a vector it instantiates itself.
(import stdlib.option)
(import (option.option i64) as opt)

(defstruct Tagged
  (tag opt.Option)
  (n i64))

(define (tagged [tag : i64] [n : i64]) : Tagged
  (Tagged (opt.some tag) n))

(define (untagged [n : i64]) : Tagged
  (Tagged (opt.none) n))

;: Owner equality: the generated Option family has no hook, so compare by hand.
(define (eq-tagged [left : (& left Tagged)] [right : (& right Tagged)]) : bool
  (and
    (= left.n right.n)
    (match left.tag
      [(opt.Option.Some l)
        (match right.tag
          [(opt.Option.Some r) (= l r)]
          [opt.Option.None false])]
      [opt.Option.None (opt.is-none? (& right.tag))])))