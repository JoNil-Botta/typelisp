;; #9834: a store through the joined reference would put arena storage into
;; `items`, outside the arena.
(extern (tl_arena_poison_enable) : unit)

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [items : (__tl_dyn-array i64) (__tl_make-array 1 2)]
      (begin
        (with-arena
          r
          (let
            [local : (__tl_dyn-array i64) (__tl_make-array 5 6)]
            [rf
              (if (> (array-ref items 0) 0)
                (&mut items)
                (&mut local))]
            (begin
              (set! (deref rf) (__tl_make-array 1 2 3))
              0)))
        (with-arena
          r2
          (begin
            (__tl_make-array 9 9 9 9 9 9 9 9)
            0))
        (if (= (array-ref items 2) 3)
          42
          7)))))