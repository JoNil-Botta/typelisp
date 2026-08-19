;# tl_mem_fill8 must fill EXACTLY the slots it was asked for, always.
;#
;# The optimizer's `fill_call` pass turns a counted constant-fill loop into one
;# call to this helper, so three properties of the helper are load-bearing:
;#   1. it writes [buf, buf + count) and nothing on either side;
;#   2. it NEVER skips its fill. `tl_array_zero` may skip when the arena's top
;#      chunk has never been rewound (the storage the bump allocator just handed
;#      out is already zero), which is why this helper is a separate symbol
;#      rather than a call into array-zero. Both arena states are exercised.
;#   3. a zero or negative count writes nothing -- `rep stosq` reads %rcx as
;#      UNSIGNED, so a negative count without the emitter's guard would run
;#      ~2^64 stores.
;#
;# The buffer is dirtied with a value that VARIES per slot, so the dirtying loop
;# cannot itself be rewritten into a fill call and the "outside the window"
;# checks compare against distinguishable values. Sizes are past one 4 KiB page
;# so a wrongly skipped fill cannot hide in memory that happened to be zero.
(import stdlib.array)
(import stdlib.arena)
(import stdlib.runtime)

(define fill-slots : i64
  4096)

(define (dirty! [items : (&mut items (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref items i) (+ 1000 i))
        (set! i (+ i 1))))))

(define (count-eq
  [items : (& items (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]
  [want : i64]) : i64
  (let
    [i : i64 lo]
    [seen : i64 0]
    (begin
      (while (< i hi)
        (begin
          (if (= (array-ref items i) want)
            (set! seen (+ seen 1))
            unit)
          (set! i (+ i 1))))
      seen)))

(define (count-dirty
  [items : (& items (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]) : i64
  (let
    [i : i64 lo]
    [seen : i64 0]
    (begin
      (while (< i hi)
        (begin
          (if (= (array-ref items i) (+ 1000 i))
            (set! seen (+ seen 1))
            unit)
          (set! i (+ i 1))))
      seen)))

;; Fill `count` slots starting at element `start` of `items`.
(define (fill-window
  [slots : (MutPtr u64)]
  [start : i64]
  [count : i64]
  [value : i64]) : unit
  (unsafe
    (runtime.mem-fill8
      (ptr-cast (ptr-offset slots start) : (MutPtr u8))
      count
      (cast value : u64))))

;; Returns a bitmask of failures; 0 is a pass.
(define (fill-checks) : i64
  (let
    [n : i64 fill-slots]
    [items : (__tl_dyn-array i64) (array.make-array i64 n)]
    [slots : (MutPtr u64)
      (unsafe
        (ptr-cast (__tl_array-data items) : (MutPtr u64)))]
    [bad : i64 0]
    (begin
      ;; (1) exactness: fill [1, n-1), leave the two edge slots alone.
      (dirty! (&mut items) n)
      (fill-window slots 1 (- n 2) 0)
      (if (= (array-ref items 0) 1000)
        unit
        (set! bad (bit-or bad 1)))
      (if (= (array-ref items (- n 1)) (+ 1000 (- n 1)))
        unit
        (set! bad (bit-or bad 2)))
      (if (= (count-eq (& items) 1 (- n 1) 0) (- n 2))
        unit
        (set! bad (bit-or bad 4)))
      ;; (2) no early-out, and the value is written verbatim.
      (dirty! (&mut items) n)
      (fill-window slots 0 n 305419896)
      (if (= (count-eq (& items) 0 n 305419896) n)
        unit
        (set! bad (bit-or bad 8)))
      ;; (3) a zero or negative count stores nothing.
      (dirty! (&mut items) n)
      (fill-window slots 0 0 5)
      (fill-window slots 0 (- 0 5) 5)
      (if (= (count-dirty (& items) 0 n) n)
        unit
        (set! bad (bit-or bad 16)))
      bad)))

(define (main) : i64
  (let
    ;; Force the program arena into existence before taking the mark.
    [_warm : (__tl_dyn-array i64) (array.make-array i64 8)]
    [mark : arena.ArenaMark (arena.mark)]
    ;; Virgin arena: this is the state in which tl_array_zero is allowed to
    ;; skip. tl_mem_fill8 must fill anyway.
    [virgin-bad : i64 (fill-checks)]
    (begin
      ;; Rewind, dirty a range strictly larger than everything the checked
      ;; allocation occupies, then rewind again so the second round lands
      ;; entirely on already-written memory.
      (unsafe
        (arena.rewind mark))
      (let
        [dirty-items : (__tl_dyn-array i64) (array.make-array i64 65536)]
        (dirty! (&mut dirty-items) 65536))
      (unsafe
        (arena.rewind mark))
      (let
        [reused-bad : i64 (fill-checks)]
        (if (and (= virgin-bad 0) (= reused-bad 0))
          42
          1)))))