;# make-array must hand back default-valued elements without any explicit init.
;#
;# The compiler drops explicit "fill the array I just allocated with its own
;# default" loops (packet Z1) because `lower-make-array-zero-fill-supported?`
;# lowers those allocations to `tl_array_zero`, so the slots are already the
;# all-zero default. This fixture pins that contract for the element shapes the
;# dropped loops relied on -- i64, bool, a fieldless-tag-0 enum -- and for an
;# enum whose tag-0 variant carries zero-default fields (an i64 and a struct of
;# i32s), which zero-fills too (#8520). Enums whose tag-0 field is a String or a
;# Box keep the per-element init loop (a Box default is a live allocation, so a
;# wrongly zeroed slot would read through a null box); their defaults must read
;# back as well. It pins
;# the contract in BOTH arena states: a virgin arena (where tl_array_zero is
;# allowed to skip its fill) and a rewound one (where it must not).
;#
;# Sizes are past one 4 KiB page so a wrongly skipped fill cannot hide inside
;# memory that happened to be zero anyway.
(import stdlib.arena)

(defenum Slot
  (Empty)
  (Filled i64))

(defstruct Span
  (start i32)
  (end i32))

(defenum Cell
  (At i64 Span)
  (Gone))

(defenum Named
  (Label String)
  (Anon))

(defenum Holder
  (Has (Box i64))
  (Empty))

(define (dirty-i64! [items : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref items i) (+ i 7))
        (set! i (+ i 1))))))

(define (count-nonzero-i64 [items : (__tl_dyn-array i64)] [n : i64]) : i64
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

(define (count-true-bool [items : (__tl_dyn-array bool)] [n : i64]) : i64
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

(define (count-non-empty-slot [items : (__tl_dyn-array Slot)] [n : i64]) : i64
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

(define (count-non-default-cell [items : (__tl_dyn-array Cell)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (array-ref items i)
            [(Cell.At at span)
              (if (and (= at 0) (= span.start 0) (= span.end 0))
                unit
                (set! bad (+ bad 1)))]
            [(Cell.Gone) (set! bad (+ bad 1))])
          (set! i (+ i 1))))
      bad)))

(define (count-non-default-named [items : (__tl_dyn-array Named)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (array-ref items i)
            [(Named.Label text)
              (if (= (string-length text) 0)
                unit
                (set! bad (+ bad 1)))]
            [(Named.Anon) (set! bad (+ bad 1))])
          (set! i (+ i 1))))
      bad)))

(define (count-non-default-holder [items : (__tl_dyn-array Holder)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (array-ref items i)
            [(Holder.Has value)
              (if (= (deref value) 0)
                unit
                (set! bad (+ bad 1)))]
            [(Holder.Empty) (set! bad (+ bad 1))])
          (set! i (+ i 1))))
      bad)))

(define (defaults-bad [n : i64]) : i64
  (+
    (count-nonzero-i64 (__tl_make-array i64 n) n)
    (+
      (count-true-bool (__tl_make-array bool n) n)
      (+
        (count-non-empty-slot (__tl_make-array Slot n) n)
        (+
          (count-non-default-cell (__tl_make-array Cell n) n)
          (+
            (count-non-default-named (__tl_make-array Named n) n)
            (count-non-default-holder (__tl_make-array Holder n) n)))))))

(define (main) : i64
  (let
    ;; Force the program arena into existence before taking the mark.
    [_warm : (__tl_dyn-array i64) (__tl_make-array i64 8)]
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
      (dirty-i64! (__tl_make-array i64 65536) 65536)
      (unsafe
        (arena.rewind mark))
      (let
        [reused-bad : i64 (defaults-bad 4096)]
        (if (and (= virgin-bad 0) (= reused-bad 0))
          42
          1)))))