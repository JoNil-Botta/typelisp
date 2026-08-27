;: A by-value read cannot create an untracked alias of mutable global storage.

(define global-items : (__tl_dyn-array i64)
  (__tl_make-array i64 2))

(define (main) : i64
  (let
    [_alias : (__tl_dyn-array i64) global-items]
    42))