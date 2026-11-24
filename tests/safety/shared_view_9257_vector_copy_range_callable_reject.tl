;; #9257: `vector.copy-range!` is an unsafe callable and cannot be laundered as
;; a plain function value, even inside an `unsafe` block.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(define (main) : i64
  (let
    [fn : (-> (&mut dst (__tl_dyn-array i64)) (MutPtr i64) i64 i64 unit)
      (unsafe
        ivec.copy-range!)]
    [dst : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (fn (&mut dst) (ptr-null : (MutPtr i64)) 0 0)
    0))