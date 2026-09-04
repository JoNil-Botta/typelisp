;; UNR-1. `compiler-backend-asm-copy-part!` cut down to one piece: the whole of
;; a borrowed string is copied into a byte buffer through a WORD loop over
;; `n / 8` followed by a BYTE tail over what is left.
;;
;; Three of the packet's claims meet in `copy-part!` and nowhere else:
;;   * `n` is a STRING LENGTH, so the non-negativity lattice can sign it and
;;     the signed `/ 8` lowers to one `shrq $3` instead of the five-instruction
;;     rounding sequence;
;;   * the word loop's bound is that `n / 8`, non-negative for the same reason,
;;     so its unroll guard needs no `bound - K <= bound` wrap compare;
;;   * the byte tail's seed is `8 * (n / 8)` against the bound `n`, so it runs
;;     `n mod 8` times -- at most seven -- and must not be unrolled at all.
;;
;; The piece lengths run 1..17, so both loops are exercised: pieces below eight
;; bytes never enter the word loop and pieces above it leave a tail of one to
;; seven bytes.
;;
;; `bump` moves the fold's last read one past the copied region: at 0 every
;; read is in range and the printed fold pins every copied byte in order, so a
;; copy that dropped, duplicated or reordered a byte changes the output; at 1
;; the final read is out of bounds and the run must abort with the same located
;; message the base compiler produced, from a check inside the copied region.
(import stdlib.io)
(import stdlib.string)

(define copy-alphabet : String
  "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
(define copy-hash-basis : i64
  1469598103934665603)
(define copy-hash-prime : i64
  1099511628211)

(define (copy-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) copy-hash-prime))

;; 1..16 bytes, so the word loop runs 0, 1 or 2 times and the tail 0..7. The
;; length and start are MASKED rather than taken modulo: the only division this
;; fixture may contain is the copy helper's own `/ 8`, which is what the
;; asm-shape gate reads.
(define (copy-piece-len [i : i64]) : i64
  (+ 1 (bit-and (* i 5) 15)))

(define (copy-piece-start [i : i64]) : i64
  (bit-and (* i 3) 15))

(define (copy-total [count : i64] [i : i64] [acc : i64]) : i64
  (if (>= i count)
    acc
    (copy-total count (+ i 1) (+ acc (copy-piece-len i)))))

;; compiler-backend-asm-copy-part!: copy the whole of `src` into `dst` at byte
;; offset `off`, INLINE. Returns the byte count copied so the caller can walk
;; the offsets without recomputing the length.
(define (copy-part! [dst : (MutPtr u8)] [off : i64] [src : (& s str)]) : i64
  (let
    [n : i64 (string.string-length src)]
    [words : i64 (/ n 8)]
    [source : (Ptr u8)
      (unsafe
        (string-data src))]
    [src64 : (Ptr i64)
      (unsafe
        (ptr-cast source : (Ptr i64)))]
    [dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset dst off) : (MutPtr i64)))]
    [w : i64 0]
    [b : i64 (* words 8)]
    (begin
      (while (< w words)
        (begin
          (unsafe
            (ptr-write! (ptr-offset dst64 w) (ptr-read (ptr-offset src64 w))))
          (set! w (+ w 1))))
      (while (< b n)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst (+ off b))
              (ptr-read (ptr-offset source b))))
          (set! b (+ b 1))))
      n)))

;; The destination lives in a module global for the same reason the backend's
;; own buffer does: the copy takes its raw data pointer and the fold reads the
;; same storage back through a CHECKED element read.
(define copy-buffer : (__tl_dyn-array u8)
  (__tl_make-array u8 1))

(define (copy-fill! [count : i64] [i : i64] [off : i64]) : i64
  (if (>= i count)
    off
    (copy-fill!
      count
      (+ i 1)
      (+
        off
        (copy-part!
          (unsafe
            (ptr-cast (__tl_array-data copy-buffer) : (MutPtr u8)))
          off
          (string.substring-view
            (& copy-alphabet)
            (copy-piece-start i)
            (copy-piece-len i)))))))

;; DELIBERATELY UNGUARDED against `bump`: this read is the abort twin's bounds
;; check, and it sits on the bytes `copy-part!` just wrote.
(define (copy-fold [limit : i64] [j : i64] [acc : i64]) : i64
  (if (>= j limit)
    acc
    (copy-fold
      limit
      (+ j 1)
      (copy-mix acc (cast (array-ref copy-buffer j) : i64)))))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [total : i64 (copy-total count 0 0)]
    (begin
      (set! copy-buffer (__tl_make-array u8 total))
      (let
        [written : i64 (copy-fill! count 0 0)]
        [fold : i64 (copy-fold (+ total bump) 0 copy-hash-basis)]
        (begin
          (io.print-format "{} {}\n" fold written)
          42)))))