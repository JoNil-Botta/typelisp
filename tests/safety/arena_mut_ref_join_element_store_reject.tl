;; #9834: an element store through the joined reference would put an arena
;; array into an element of `items`, outside the arena.
(extern (tl_arena_poison_enable) : unit)

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [items : (__tl_dyn-array (__tl_dyn-array i64))
        (__tl_make-array (__tl_make-array 1 2))]
      (begin
        (with-arena
          r
          (let
            [local : (__tl_dyn-array (__tl_dyn-array i64))
              (__tl_make-array (__tl_make-array 5 6))]
            [rf
              (if (> (array-length items) 0)
                (&mut items)
                (&mut local))]
            (begin
              (set! (array-ref (deref rf) 0) (__tl_make-array 1 2 3))
              0)))
        (with-arena
          r2
          (begin
            (__tl_make-array 9 9 9 9 9 9 9 9)
            0))
        (if (= (array-ref (array-ref items 0) 2) 3)
          42
          7)))))