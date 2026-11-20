;# Zero Is Initialization representation (SPEC 5.12.1, "Zero value of each
;# type"). For every storage shape the ZII classifier (`tc-type-zii-class`)
;# admits, `__tl_make-array` hands back storage whose every byte is zero, and
;# ordinary safe reads see that type's zero value: every scalar width, null raw
;# pointers, a null nullable C function pointer, nested tuple / fixed-array /
;# struct storage, an enum whose first variant is fieldless and one whose first
;# variant carries a ZII payload. Fixed `make-array` yields the same values.
;#
;# The arena is dirtied and rewound first, so a fill that wrongly left old bytes
;# behind is caught rather than hidden by fresh zero pages. The manifest runs
;# the fixture at opt levels 0, 1 and 2.
(import stdlib.arena)

(defstruct Span
  (start i32)
  (end i32))

(defstruct Scalars
  (a i8)
  (b i16)
  (c i32)
  (d i64)
  (e u8)
  (f u16)
  (g u32)
  (h u64)
  (fa f32)
  (fb f64)
  (flag bool)
  (ch char)
  (none unit))

(defstruct Pointers
  (p (Ptr i64))
  (q (MutPtr u8))
  (callback (CFunc nullable (-> i64 i64))))

(defstruct Nested
  (pair (Tuple i64 (Tuple bool char)))
  (spans (Array Span 3))
  (tail u16))

(defenum Slot
  (Empty)
  (Filled i64))

(defenum Cell
  (At i64 Span)
  (Gone))

(define element-count : i64
  64)

;; Every byte of `count` bytes at `data` is zero.
(define (zero-bytes? [data : (Ptr u8)] [count : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (while (< i count)
      (unless
        (=
          (unsafe
            (ptr-read (ptr-offset data i)))
          0)
        (set! ok false))
      (set! i (+ i 1)))
    ok))

(define (scalars-zero? [s : Scalars]) : bool
  (and
    (= s.a 0)
    (= s.b 0)
    (= s.c 0)
    (= s.d 0)
    (= s.e 0)
    (= s.f 0)
    (= s.g 0)
    (= s.h 0)
    (= s.fa 0.0)
    (= s.fb 0.0)
    (not s.flag)
    (= s.ch '\0')))

(define (pointers-zero? [p : Pointers]) : bool
  (and (ptr-null? p.p) (ptr-null? p.q) (ptr-null? p.callback)))

(define (span-zero? [s : Span]) : bool
  (and (= s.start 0) (= s.end 0)))

(define (nested-zero? [n : Nested]) : bool
  (and
    (= (tuple-ref n.pair 0) 0)
    (not (tuple-ref (tuple-ref n.pair 1) 0))
    (= (tuple-ref (tuple-ref n.pair 1) 1) '\0')
    (span-zero? (array-ref n.spans 0))
    (span-zero? (array-ref n.spans 2))
    (= n.tail 0)))

(define (slot-zero? [s : Slot]) : bool
  (match s
    [(Empty) true]
    [(Filled _) false]))

(define (cell-zero? [c : Cell]) : bool
  (match c
    [(At at span) (and (= at 0) (span-zero? span))]
    [(Gone) false]))

(define (scalars-ok?) : bool
  (let
    [items : (__tl_dyn-array Scalars) (__tl_make-array Scalars element-count)]
    [fixed : (Array Scalars 2) (make-array Scalars 2)]
    [i : i64 0]
    [ok : bool
      (and
        (scalars-zero? (array-ref fixed 0))
        (scalars-zero? (array-ref fixed 1)))]
    (while (< i element-count)
      (unless (scalars-zero? (array-ref items i)) (set! ok false))
      (set! i (+ i 1)))
    (and
      ok
      (zero-bytes?
        (unsafe
          (ptr-cast (__tl_array-data items) : (Ptr u8)))
        (* element-count (comptime (size-of (type Scalars))))))))

(define (pointers-ok?) : bool
  (let
    [items : (__tl_dyn-array Pointers) (__tl_make-array Pointers element-count)]
    [fixed : (Array Pointers 2) (make-array Pointers 2)]
    [i : i64 0]
    [ok : bool
      (and
        (pointers-zero? (array-ref fixed 0))
        (pointers-zero? (array-ref fixed 1)))]
    (while (< i element-count)
      (unless (pointers-zero? (array-ref items i)) (set! ok false))
      (set! i (+ i 1)))
    (and
      ok
      (zero-bytes?
        (unsafe
          (ptr-cast (__tl_array-data items) : (Ptr u8)))
        (* element-count (comptime (size-of (type Pointers))))))))

(define (nested-ok?) : bool
  (let
    [items : (__tl_dyn-array Nested) (__tl_make-array Nested element-count)]
    [fixed : (Array Nested 2) (make-array Nested 2)]
    [i : i64 0]
    [ok : bool
      (and
        (nested-zero? (array-ref fixed 0))
        (nested-zero? (array-ref fixed 1)))]
    (while (< i element-count)
      (unless (nested-zero? (array-ref items i)) (set! ok false))
      (set! i (+ i 1)))
    (and
      ok
      (zero-bytes?
        (unsafe
          (ptr-cast (__tl_array-data items) : (Ptr u8)))
        (* element-count (comptime (size-of (type Nested))))))))

(define (slots-ok?) : bool
  (let
    [items : (__tl_dyn-array Slot) (__tl_make-array Slot element-count)]
    [fixed : (Array Slot 2) (make-array Slot 2)]
    [i : i64 0]
    [ok : bool
      (and (slot-zero? (array-ref fixed 0)) (slot-zero? (array-ref fixed 1)))]
    (while (< i element-count)
      (unless (slot-zero? (array-ref items i)) (set! ok false))
      (set! i (+ i 1)))
    (and
      ok
      (zero-bytes?
        (unsafe
          (ptr-cast (__tl_array-data items) : (Ptr u8)))
        (* element-count (comptime (size-of (type Slot))))))))

(define (cells-ok?) : bool
  (let
    [items : (__tl_dyn-array Cell) (__tl_make-array Cell element-count)]
    [fixed : (Array Cell 2) (make-array Cell 2)]
    [i : i64 0]
    [ok : bool
      (and (cell-zero? (array-ref fixed 0)) (cell-zero? (array-ref fixed 1)))]
    (while (< i element-count)
      (unless (cell-zero? (array-ref items i)) (set! ok false))
      (set! i (+ i 1)))
    (and
      ok
      (zero-bytes?
        (unsafe
          (ptr-cast (__tl_array-data items) : (Ptr u8)))
        (* element-count (comptime (size-of (type Cell))))))))

(define (dirty! [items : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (set! (array-ref items i) -1)
      (set! i (+ i 1)))))

(define (main) : i64
  (let
    ;; Force the program arena into existence before taking the mark.
    [warm : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [mark : arena.ArenaMark (arena.mark)]
    (dirty! warm 8)
    (dirty! (__tl_make-array i64 16384) 16384)
    (unsafe
      (arena.rewind mark))
    (if (and (scalars-ok?) (pointers-ok?) (nested-ok?) (slots-ok?) (cells-ok?))
      42
      1)))