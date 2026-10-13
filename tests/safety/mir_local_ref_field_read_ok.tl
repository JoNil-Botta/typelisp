;: Reading a Copy field through a local reference, then the owner again.
(defstruct Counter
  (count i64)
  (items (__tl_dyn-array i64)))

(define (main) : i64
  (let
    [c : Counter (Counter 40 (__tl_make-array i64 2))]
    [r : (& c Counter) (& c)]
    [n : i64 r.count]
    (+ n (array-length c.items))))