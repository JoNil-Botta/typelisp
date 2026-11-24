(import clone_imported_nominal_dep as dep)
(import stdlib.clone)
(import stdlib.string)

(define (main) : i64
  (let
    [value : dep.Item (dep.Item "clone-direct")]
    [copied : dep.Item (clone.deep value)]
    (if (string.eq copied.text "clone-direct")
      41
      1)))