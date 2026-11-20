;; #9834: a joined mutable reference is invariant in its referent, and a
;; `&mut` of arena storage does not join with a `&mut` of outer storage. The
;; push would otherwise grow `items` with arena storage.
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
            (__tl_array-push! (deref rf) 3)))
        (with-arena
          r2
          (begin
            (__tl_make-array 9 9 9 9 9 9 9 9)
            0))
        (if (= (array-ref items 2) 3)
          42
          7)))))