;; Unsafe code may view one buffer both by word index and by byte index: the
;; address is base + index * scale, so `(ptr-offset d i)` at two element sizes
;; names two different words even with one base and one index. Load
;; forwarding once keyed both by base and index alone and served the wrong
;; word at opt2 (main too).
(define words : (__tl_dyn-array i64)
  (__tl_make-array i64 3))
(define stored : (__tl_dyn-array i64)
  (__tl_make-array i64 4))
(define bytes : (__tl_dyn-array u8)
  (__tl_make-array u8 32))

;; 1 when word `i` and the word at byte offset `i` read alike.
(define (same-word? [i : i64]) : i64
  (unsafe
    (let
      [d : (Ptr i64) (ptr-cast (__tl_array-data words) : (Ptr i64))]
      [a : i64 (ptr-read (ptr-offset d i))]
      [b : i64
        (ptr-read (ptr-cast (ptr-offset (ptr-cast d : (Ptr u8)) i) : (Ptr i64)))]
      (if (= a b)
        1
        0))))

;; Store 7 into word `i`, then read the word at byte offset `i`: 7 at i = 0,
;; then the stored byte shifted up (7 << 56, 7 << 48) at i = 1 and 2.
(define (store-then-read [i : i64]) : i64
  (unsafe
    (let
      [d : (Ptr i64) (ptr-cast (__tl_array-data stored) : (Ptr i64))]
      (ptr-write! (ptr-cast (ptr-offset d i) : (MutPtr i64)) 7)
      (ptr-read (ptr-cast (ptr-offset (ptr-cast d : (Ptr u8)) i) : (Ptr i64))))))

;; 1 when the u64 word `i` of a byte buffer and the word at byte `i` agree.
(define (same-bytes? [i : i64]) : i64
  (unsafe
    (let
      [d : (MutPtr u8) (__tl_array-data bytes)]
      [w : u64 (ptr-read (ptr-offset (ptr-cast d : (MutPtr u64)) i))]
      [x : u64 (ptr-read (ptr-cast (ptr-offset d i) : (MutPtr u64)))]
      (if (= w x)
        1
        0))))

(define (main) : i64
  (set! (array-ref words 0) 72623859790382856)
  (set! (array-ref words 1) 1229782938247303441)
  (let
    [k : i64 0]
    (while (< k 32)
      (set! (array-ref bytes k) (cast k : u8))
      (set! k (+ k 1))))
  (let
    [i : i64 0]
    [same : i64 0]
    [sum : i64 0]
    [byte-same : i64 0]
    (while (< i 2)
      (set! same (+ same (same-word? i)))
      (set! byte-same (+ byte-same (same-bytes? i)))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i 3)
      (set! sum (+ sum (store-then-read i)))
      (set! i (+ i 1)))
    (cond
      [(!= same 1) 1]
      [(!= sum 506373483102470151) 2]
      [(!= byte-same 1) 3]
      [else 42])))