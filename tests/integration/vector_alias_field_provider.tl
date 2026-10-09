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