;# Read zeroed dynamic-array elements in both virgin and rewound arenas.
;# The arrays span more than one page to expose stale backing bytes. Tag-0
;# enum payloads include scalar fields, inline structs and empty strings.
;# Holder's boxes are constructed explicitly and checked separately.
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
  (Empty)
  (Has (Box i64)))

(defenum Mixed
  (Vals f64 char bool)
  (NoVals))

(defenum Wrapped
  (Wrap Named)
  (Bare))

(define (dirty-i64! [items : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (set! (array-ref items i) (+ i 7))
      (set! i (+ i 1)))))

(define (count-nonzero-i64 [items : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (if (= (array-ref items i) 0)
        unit
        (set! bad (+ bad 1)))
      (set! i (+ i 1)))
    bad))

(define (count-true-bool [items : (__tl_dyn-array bool)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (if (array-ref items i)
        (set! bad (+ bad 1))
        unit)
      (set! i (+ i 1)))
    bad))

(define (count-non-empty-slot [items : (__tl_dyn-array Slot)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (match (array-ref items i)
        [(Empty) unit]
        [(Filled _) (set! bad (+ bad 1))])
      (set! i (+ i 1)))
    bad))

(define (count-non-default-cell [items : (__tl_dyn-array Cell)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (match (array-ref items i)
        [(At at span)
          (if (and (= at 0) (= span.start 0) (= span.end 0))
            unit
            (set! bad (+ bad 1)))]
        [(Gone) (set! bad (+ bad 1))])
      (set! i (+ i 1)))
    bad))

(define (count-non-default-named [items : (__tl_dyn-array Named)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (match (& (array-ref items i))
        [(Label text)
          (if (= (string-length text) 0)
            unit
            (set! bad (+ bad 1)))]
        [(Anon) (set! bad (+ bad 1))])
      (set! i (+ i 1)))
    bad))

(define (construct-holders [n : i64]) : (__tl_dyn-array Holder)
  (let
    [items : (__tl_dyn-array Holder) (__tl_make-array Holder n)]
    [i : i64 0]
    (while (< i n)
      (set! (array-ref items i) (Has (box 0)))
      (set! i (+ i 1)))
    items))

(define (count-non-default-holder [items : (__tl_dyn-array Holder)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (match (& (array-ref items i))
        [(Has value)
          (if (= (deref value) 0)
            unit
            (set! bad (+ bad 1)))]
        [(Empty) (set! bad (+ bad 1))])
      (set! i (+ i 1)))
    bad))

(define (count-non-default-mixed [items : (__tl_dyn-array Mixed)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (match (array-ref items i)
        [(Vals value code flag)
          (if (and (= value 0.0) (= code '\0') (not flag))
            unit
            (set! bad (+ bad 1)))]
        [(NoVals) (set! bad (+ bad 1))])
      (set! i (+ i 1)))
    bad))

(define (count-non-default-wrapped [items : (__tl_dyn-array Wrapped)] [n : i64]) : i64
  (let
    [i : i64 0]
    [bad : i64 0]
    (while (< i n)
      (match (& (array-ref items i))
        [(Wrap (Label text))
          (if (= (string-length text) 0)
            unit
            (set! bad (+ bad 1)))]
        [_ (set! bad (+ bad 1))])
      (set! i (+ i 1)))
    bad))

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
            (+
              (count-non-default-holder (construct-holders n) n)
              (+
                (count-non-default-mixed (__tl_make-array Mixed n) n)
                (count-non-default-wrapped (__tl_make-array Wrapped n) n)))))))))

(define (main) : i64
  (let
    ;; Force the program arena into existence before taking the mark.
    [_warm : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [mark : arena.ArenaMark (arena.mark)]
    ;; Virgin arena: tl_array_zero is allowed to skip, the pages must still
    ;; read as the default.
    [virgin-bad : i64 (defaults-bad 4096)]
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
        1))))