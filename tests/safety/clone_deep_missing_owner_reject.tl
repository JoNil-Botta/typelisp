(import clone_deep_missing_owner as owner)
(import stdlib.clone)

(define (copy [source : owner.Leaf]) : owner.Leaf
  (clone.deep source))