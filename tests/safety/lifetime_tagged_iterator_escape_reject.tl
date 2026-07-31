;: Lifetime-tagged iterator state cannot outlive its borrowed source storage.
(import stdlib.array)

(defstruct Iter
  (:lifetimes source)
  (slots (& source (__tl_dyn-array i64)))
  (len i64)
  (index i64))

(define (main [items : (__tl_dyn-array i64)]) : (Iter items)
  (let
    [local : (__tl_dyn-array i64) (array.make-array i64 1)]
    (Iter (& local) 1 0)))