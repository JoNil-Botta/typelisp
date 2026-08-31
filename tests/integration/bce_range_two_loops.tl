;; IT-1 runtime coverage: the `intern-hash-words` shape -- TWO sequential loops
;; over ONE slice of one container, an eight-offset word loader followed by a
;; single-byte tail, with the word loader out of line. The tail loop is a
;; variable-base family against a container length, so its guard is the
;; two-unsigned-compare normal form `start <=u v.len && count <=u v.len -
;; start` that `opt-bce-version-range-normal-guard` emits.
;;
;; What must hold is that whatever clone the guard selects computes the same
;; answer as the checked one, at every optimization level, for every span the
;; caller can present: an empty span, a one-byte span, a span shorter than one
;; word, a span ending exactly at the container's end, a span starting at the
;; container's end, and the whole container. The spans are derived from argv so
;; nothing folds at compile time.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector u8) as u8vec)

(define (byte-at [v : (& v u8vec.Vec)] [index : i64]) : i64
  (cast (array-ref (u8vec.slots v) index) : i64))

;; One 64-bit word of the slice, read the way `intern-hash-words` reads it: a
;; descending byte loop over eight consecutive offsets, out of line.
(define (load-word [v : (& v u8vec.Vec)] [at : i64]) : i64
  (let
    [word : i64 0]
    [b : i64 7]
    (begin
      (while (>= b 0)
        (begin
          (set! word (+ (* word 2) (byte-at v (+ at b))))
          (set! b (- b 1))))
      word)))

;; The two-loop kernel: `words` is `len - 7`, so the word loop and the byte
;; tail between them walk exactly `[start, start + len)`.
(define (span-hash [v : (& v u8vec.Vec)] [start : i64] [len : i64]) : i64
  (let
    [h : i64 (+ 5381 len)]
    [i : i64 0]
    [words : i64 (- len 7)]
    [tail : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! h (+ (* h 31) (load-word v (+ start i))))
          (set! i (+ i 8))))
      (while (< i len)
        (begin
          (set! tail (+ (* tail 256) (byte-at v (+ start i))))
          (set! i (+ i 1))))
      (+ (* h 31) tail))))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [v : u8vec.Vec (u8vec.Vec (__tl_make-array u8 n) n)]
    [i : i64 0]
    [acc : i64 0]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref (u8vec.slots-mut (&mut v)) i) (cast (+ i 1) : u8))
          (set! i (+ i 1))))
      ;; Every span shape the guard has a corner for: empty, one byte, shorter
      ;; than a word, exactly one word, ending at the container's end, and the
      ;; whole container.
      (set! start 0)
      (while (<= start n)
        (begin
          (set! acc (+ (* acc 7) (span-hash (& v) start 0)))
          (set! acc (+ (* acc 7) (span-hash (& v) start (- n start))))
          (set! start (+ start 1))))
      (set! acc (+ (* acc 7) (span-hash (& v) 0 1)))
      (set! acc (+ (* acc 7) (span-hash (& v) 1 7)))
      (set! acc (+ (* acc 7) (span-hash (& v) 1 8)))
      (set! acc (+ (* acc 7) (span-hash (& v) (- n 8) 8)))
      (set! acc (+ (* acc 7) (span-hash (& v) 0 n)))
      (io.print-format "{}\n" acc)
      42)))