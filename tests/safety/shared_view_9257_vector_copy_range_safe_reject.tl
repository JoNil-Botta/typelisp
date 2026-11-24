;; #9257: `vector.copy-range!` requires `unsafe` because it reads through a raw
;; `(MutPtr T)` argument.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(define (main) : i64
  (let
    [dst : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [src : (MutPtr i64) (ptr-null : (MutPtr i64))]
    (ivec.copy-range! (&mut dst) src 0 1)
    0))