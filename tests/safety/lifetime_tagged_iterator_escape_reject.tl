;: Lifetime-tagged iterator state cannot outlive its borrowed source storage.
(defstruct Iter
  (:lifetimes source)
  (slots (& source (Array i64)))
  (len i64)
  (index i64))

(define (main [items : (Array i64)]) : (Iter items)
  (let
    [local : (Array i64) (make-array i64 1)]
    (Iter (& local) 1 0)))