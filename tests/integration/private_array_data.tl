;; The compiler-private spelling shares the public compatibility intrinsic's
;; raw mutable-pointer result and lowering. It does not introduce a safe API.
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (unsafe
      (begin
        (ptr-write! (__tl_array-data items) 20)
        (ptr-write! (ptr-offset (__tl_array-data items) 1) 22)
        (+ (array-ref items 0) (array-ref items 1))))))