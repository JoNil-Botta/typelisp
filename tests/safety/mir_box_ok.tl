;: Box contents: Copy reads keep the box, a write replaces the contents, and
;: a move-only contents move consumes the box.
(define (main) : i64
  (let
    [n : (Box i64) (box 20)]
    [items : (Box (__tl_dyn-array i64)) (box (__tl_make-array i64 2))]
    (begin
      (set! (deref n) (+ (deref n) 1))
      (let
        [taken : (__tl_dyn-array i64) (deref items)]
        (+ (deref n) (deref n) (array-length taken) -2)))))