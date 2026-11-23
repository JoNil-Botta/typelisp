(import stdlib.clone)

(defstruct Resource
  (:cleanup close-resource)
  (value i64))

(define (duplicate [source : Resource]) : Resource
  (clone.deep source))