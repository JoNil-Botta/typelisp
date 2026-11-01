;; The address offset `i + 1` can be the same SSA value as the next counter.
;; Bulk-copy recognition must keep the first address, not replace it with the
;; final counter. All arrays have spare initialized storage, so even the old
;; incorrect offset stays inside their allocations and fails by value.
(import stdlib.io)
(import stdlib.string)

(define (copy-shifted-words
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [count : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref dst (+ i 1)) (array-ref src (+ i 1)))
          (set! i (+ i 1))))
      i)))

(define (copy-shifted-bytes
  [dst : (&mut dst (__tl_dyn-array u8))]
  [src : (& src (__tl_dyn-array u8))]
  [count : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref dst (+ i 1)) (array-ref src (+ i 1)))
          (set! i (+ i 1))))
      i)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 24)]
    [dst : (__tl_dyn-array i64) (__tl_make-array i64 24)]
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 24)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 24)]
    [i : i64 0]
    (begin
      (unless (and (>= count 0) (<= count 9)) (return 90))
      (while (< i 24)
        (begin
          (set! (array-ref src i) (+ 100 i))
          (set! (array-ref dst i) -1)
          (set! (array-ref bytes i) (cast (+ 100 i) : u8))
          (set! (array-ref out i) 0)
          (set! i (+ i 1))))
      (unless
        (= (copy-shifted-words (&mut dst) (& src) count) count)
        (return 1))
      (unless
        (= (copy-shifted-bytes (&mut out) (& bytes) count) count)
        (return 2))
      (set! i 0)
      (while (< i 24)
        (let
          [copied? : bool (and (> i 0) (<= i count))]
          (begin
            (unless
              (=
                (array-ref dst i)
                (if copied?
                  (+ 100 i)
                  -1))
              (return 3))
            (unless
              (=
                (cast (array-ref out i) : i64)
                (if copied?
                  (+ 100 i)
                  0))
              (return 4))
            (set! i (+ i 1)))))
      42)))