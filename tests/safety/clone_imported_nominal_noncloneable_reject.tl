(import clone_imported_nominal_noncloneable_dep as dep)

(defstruct LocalRawWrapper
  (item dep.RawItem))

(define (main) : i64
  (unsafe
    (let
      [value : LocalRawWrapper
        (LocalRawWrapper (dep.RawItem (int->ptr (cast 0 : u64) : (Ptr i64))))]
      [copied : LocalRawWrapper (clone value)]
      0)))