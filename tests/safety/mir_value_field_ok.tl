;: A field read off an evaluated value consumes the temporary.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (make) : Holder
  (Holder (__tl_make-array i64 2) 40))

(define (main) : i64
  (+ (make).count (array-length (make).items)))