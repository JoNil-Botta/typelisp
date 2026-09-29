;; A bytes view reads u8 elements only.
(define (main) : i64
  (let
    [words : (Array i64 3) (array 1 2 3)]
    [view : (& words bytes) (__tl_bytes-view words 0 3)]
    0))