;; #9834: two `&mut` borrows of the same arena's locals agree on the referent
;; and on the arena region, so the join stays legal.
(extern (tl_arena_poison_enable) : unit)

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (with-arena
      r
      (let
        [a : (__tl_dyn-array i64) (__tl_make-array 1 2)]
        (let
          [b : (__tl_dyn-array i64) (__tl_make-array 3 4)]
          (let
            [rf
              (if (> (array-ref a 0) 0)
                (&mut a)
                (&mut b))]
            (begin
              (__tl_array-push! (deref rf) 5)
              (if (and
                (= (array-length (deref rf)) 3)
                (= (array-ref (deref rf) 2) 5))
                42
                7))))))))