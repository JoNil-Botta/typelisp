;# Arena rewind must re-arm the make-array zero fill.
;#
;# make-array skips its zero fill while the active arena only ever handed out
;# fresh OS pages, and tl_region_reset marks the arena as reused. A dynamic
;# array allocated after a rewind to an earlier mark reuses memory dirtied
;# before the rewind, so the zero fill must run again: if it were wrongly
;# skipped, `fresh` would alias the nonzero contents dirtied below and main
;# would return 1 instead of the expected 42.
(import stdlib.array)
(import stdlib.arena)

(define (dirty-range! [items : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! items i (+ i 1))
        (set! i (+ i 1))))))

(define (sum-range [items : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref items i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    ;; Force the program arena into existence before taking the mark.
    [warm : (__tl_dyn-array i64) (array.make-array i64 8)]
    [mark : arena.ArenaMark (arena.mark)]
    (begin
      (dirty-range! warm 8)
      (dirty-range! (array.make-array i64 1024) 1024)
      (unsafe
        (arena.rewind mark))
      (let
        [fresh : (__tl_dyn-array i64) (array.make-array i64 1024)]
        (if (= (sum-range fresh 1024) 0)
          42
          1)))))