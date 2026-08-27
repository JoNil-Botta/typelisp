;# `tl_mem_copy_fwd` must BE the forward byte-copy loop, always.
;#
;# The optimizer's `copy_call` pass turns a counted `dst[i] = src[i]` loop over
;# byte elements into one call to this helper, so the helper's whole contract is
;# that it is indistinguishable from that loop for EVERY argument triple:
;#   1. it copies [dst, dst + count) from [src, src + count) and touches
;#      nothing on either side;
;#   2. it agrees with the loop under OVERLAP in both directions. This is the
;#      rail that rules out `tl_memcpy`: that helper is memmove, so for
;#      `src < dst < src + n` it copies backward and reproduces the source
;#      bytes, where the loop re-reads bytes it has just written and instead
;#      PROPAGATES them. A word-at-a-time forward copy is wrong there too;
;#   3. a zero or negative count copies nothing -- `rep movsb` reads %rcx as
;#      UNSIGNED, so a negative count without the emitter's guard would run
;#      ~2^64 copies.
;#
;# The twin below is the real correctness argument for the pass. `copy-fast` is
;# exactly the shape `copy_call` rewrites; `copy-ref` is the same copy written
;# with a SECOND store in the body, which the pass refuses (its body scan admits
;# one store), so it stays a byte-at-a-time loop and is the oracle. Both run
;# over the same buffer at every source offset, destination offset and length in
;# 0..33, which covers non-overlap, exact aliasing, and both overlap directions
;# at every alignment, and the two buffers are compared byte for byte.
(import stdlib.runtime)

(define buf-size : i64
  96)

(define (pattern [i : i64]) : u8
  (cast (bit-and (+ (* i 37) 11) 255) : u8))

(define (fill-pattern! [items : (__tl_dyn-array u8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref items i) (pattern i))
        (set! i (+ i 1))))))

;; The admitted shape: one byte load, one byte store, counter step 1.
(define (copy-fast
  [items : (__tl_dyn-array u8)]
  [dst : i64]
  [src : i64]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref items (+ dst i)) (array-ref items (+ src i)))
        (set! i (+ i 1))))))

;; The oracle: the same copy, but the second store keeps `copy_call` off it, so
;; this stays a genuine byte-at-a-time forward loop at every optimization level.
(define (copy-ref
  [items : (__tl_dyn-array u8)]
  [witness : (__tl_dyn-array u8)]
  [dst : i64]
  [src : i64]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref items (+ dst i)) (array-ref items (+ src i)))
        (set! (array-ref witness i) (cast (bit-and i 255) : u8))
        (set! i (+ i 1))))))

(define (buffers-eq?
  [a : (__tl_dyn-array u8)]
  [b : (__tl_dyn-array u8)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (= (array-ref a i) (array-ref b i))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

;; Every (dst, src, len) triple in the window. Returns the number of triples
;; whose rewritten copy disagreed with the oracle.
(define (twin-mismatches) : i64
  (let
    [n : i64 buf-size]
    [fast : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [ref : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [witness : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [bad : i64 0]
    [dst : i64 0]
    (begin
      (while (< dst 34)
        (let
          [src : i64 0]
          (while (< src 34)
            (let
              [len : i64 0]
              (begin
                (while (< len 34)
                  (begin
                    (fill-pattern! fast n)
                    (fill-pattern! ref n)
                    (copy-fast fast dst src len)
                    (copy-ref ref witness dst src len)
                    (if (buffers-eq? fast ref n)
                      unit
                      (set! bad (+ bad 1)))
                    (set! len (+ len 1))))
                (set! src (+ src 1)))))
          (set! dst (+ dst 1))))
      bad)))

;; Direct helper contract: exactness at both edges, and a non-positive count.
(define (helper-checks) : i64
  (let
    [n : i64 buf-size]
    [items : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [bad : i64 0]
    (begin
      ;; (1) copies exactly [1, n-1) and leaves the two edge bytes alone.
      (fill-pattern! items n)
      (unsafe
        (runtime.mem-copy-fwd
          (ptr-offset (__tl_array-data items) 1)
          (ptr-cast (ptr-offset (__tl_array-data items) 0) : (Ptr u8))
          (- n 2)))
      (if (= (array-ref items 0) (pattern 0))
        unit
        (set! bad (bit-or bad 1)))
      (if (= (array-ref items (- n 1)) (pattern (- n 1)))
        unit
        (set! bad (bit-or bad 2)))
      ;; That call is the propagating overlap (dst = src + 1): every byte in
      ;; the window must be the FIRST source byte, not a shifted pattern.
      (if (= (count-eq items 1 (- n 1) (pattern 0)) (- n 2))
        unit
        (set! bad (bit-or bad 4)))
      ;; (2) a zero or negative count copies nothing.
      (fill-pattern! items n)
      (unsafe
        (runtime.mem-copy-fwd
          (ptr-offset (__tl_array-data items) 0)
          (ptr-cast (ptr-offset (__tl_array-data items) 8) : (Ptr u8))
          0))
      (unsafe
        (runtime.mem-copy-fwd
          (ptr-offset (__tl_array-data items) 0)
          (ptr-cast (ptr-offset (__tl_array-data items) 8) : (Ptr u8))
          (- 0 5)))
      (if (= (count-pattern items 0 n) n)
        unit
        (set! bad (bit-or bad 8)))
      bad)))

(define (count-eq
  [items : (__tl_dyn-array u8)]
  [lo : i64]
  [hi : i64]
  [want : u8]) : i64
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

(define (count-pattern [items : (__tl_dyn-array u8)] [lo : i64] [hi : i64]) : i64
  (let
    [i : i64 lo]
    [seen : i64 0]
    (begin
      (while (< i hi)
        (begin
          (if (= (array-ref items i) (pattern i))
            (set! seen (+ seen 1))
            unit)
          (set! i (+ i 1))))
      seen)))

(define (main) : i64
  (if (and (= (twin-mismatches) 0) (= (helper-checks) 0))
    42
    1))