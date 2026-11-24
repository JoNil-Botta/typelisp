(import clone_imported_nominal_noncloneable_dep as dep)
(import stdlib.clone)

(defstruct LocalRawWrapper
  (item dep.RawItem))

(clone.gen-clone LocalRawWrapper)

(define (main) : i64
  (unsafe
    (let
      [value : LocalRawWrapper
        (LocalRawWrapper (dep.RawItem (int->ptr (cast 0 : u64) : (Ptr i64))))]
      [copied : LocalRawWrapper (clone.deep value)]
      0)))