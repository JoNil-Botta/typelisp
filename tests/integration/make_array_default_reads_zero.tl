;# make-array must hand back default-valued elements without any explicit init.
;#
;# The compiler drops explicit "fill the array I just allocated with its own
;# default" loops (packet Z1) because `lower-make-array-zero-fill-supported?`
;# lowers those allocations to `tl_array_zero`, so the slots are already the
;# all-zero default. This fixture pins that contract for the three element
;# shapes the dropped loops relied on -- i64, bool, and a fieldless-tag-0 enum
;# -- and pins it in BOTH arena states: a virgin arena (where tl_array_zero is
;# allowed to skip its fill) and a rewound one (where it must not).
;#
;# Sizes are past one 4 KiB page so a wrongly skipped fill cannot hide inside
;# memory that happened to be zero anyway.
(import stdlib.array)
(import stdlib.arena)

(defenum Slot
  (Empty)
  (Filled i64))

(define (dirty-i64! [items : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! items i (+ i 7))
        (set! i (+ i 1))))))

(define (count-nonzero-i64 [items : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (= (array-ref items i) 0)
            unit
            (set! bad (+ bad 1)))
          (set! i (+ i 1))))
      bad)))

(define (count-true-bool [items : (Array bool)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (array-ref items i)
            (set! bad (+ bad 1))
            unit)
          (set! i (+ i 1))))
      bad)))

(define (count-non-empty-slot [items : (Array Slot)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (array-ref items i)
            [(Slot.Empty) unit]
            [(Slot.Filled _) (set! bad (+ bad 1))])
          (set! i (+ i 1))))
      bad)))

(define (defaults-bad [n : i64]) : i64
  (+
    (count-nonzero-i64 (array.make-array i64 n) n)
    (+
      (count-true-bool (array.make-array bool n) n)
      (count-non-empty-slot (array.make-array Slot n) n))))

(define (main) : i64
  (let
    ;; Force the program arena into existence before taking the mark.
    [_warm : (Array i64) (array.make-array i64 8)]
    [mark : arena.ArenaMark (arena.mark)]
    ;; Virgin arena: tl_array_zero is allowed to skip, the pages must still
    ;; read as the default.
    [virgin-bad : i64 (defaults-bad 4096)]
    (begin
      ;; Rewind, then dirty a range strictly larger than everything the checked
      ;; allocations will occupy, with NONZERO bytes, then rewind again. The
      ;; second round therefore lands entirely on dirtied memory and the fill
      ;; has to run -- without this the checked arrays would be reusing the
      ;; first round's own (already zero) storage and the test would pass even
      ;; with the fill wrongly skipped.
      (unsafe
        (arena.rewind mark))
      (dirty-i64! (array.make-array i64 65536) 65536)
      (unsafe
        (arena.rewind mark))
      (let
        [reused-bad : i64 (defaults-bad 4096)]
        (if (and (= virgin-bad 0) (= reused-bad 0))
          42
          1)))))