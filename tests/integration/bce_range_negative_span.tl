;; IT-1 runtime coverage, the refusing side: the same two-loop span kernel with
;; the spans READ FROM DATA, so neither `start` nor `len` is provably
;; non-negative and the versioning guard has to decide them at run time. The
;; accepted spans must compute the same answers the checked clone does; the
;; last span's start is NEGATIVE, which every form of the guard rejects, so that
;; call runs the SLOW clone and aborts on its first bounds check -- at the same
;; index, with the same message, as an unoptimized build.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(import (vector.vector u8) as u8vec)

(define (byte-at [v : (& v u8vec.Vec)] [index : i64]) : i64
  (cast (array-ref (u8vec.slots v) index) : i64))

;; The same descending eight-byte word loop `intern-hash-words` uses, out of
;; line.
(define (load-word [v : (& v u8vec.Vec)] [at : i64]) : i64
  (let
    [word : i64 0]
    [b : i64 7]
    (begin
      (while (>= b 0)
        (begin
          (set! word (+ word (byte-at v (+ at b))))
          (set! b (- b 1))))
      word)))

(define (span-sum [v : (& v u8vec.Vec)] [start : i64] [len : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    [words : i64 (- len 7)]
    (begin
      (while (< i words)
        (begin
          (set! acc (+ acc (load-word v (+ start i))))
          (set! i (+ i 8))))
      (while (< i len)
        (begin
          (set! acc (+ acc (byte-at v (+ start i))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [v : u8vec.Vec (u8vec.Vec (__tl_make-array u8 n) n)]
    [starts : i64vec.Vec (i64vec.Vec (__tl_make-array i64 4) 4)]
    [lengths : i64vec.Vec (i64vec.Vec (__tl_make-array i64 4) 4)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref (u8vec.slots-mut (&mut v)) i) 1)
          (set! i (+ i 1))))
      ;; Three spans the guard accepts, then one whose start went negative.
      (set! (array-ref (i64vec.slots-mut (&mut starts)) 0) 0)
      (set! (array-ref (i64vec.slots-mut (&mut lengths)) 0) n)
      (set! (array-ref (i64vec.slots-mut (&mut starts)) 1) (- n 3))
      (set! (array-ref (i64vec.slots-mut (&mut lengths)) 1) 3)
      (set! (array-ref (i64vec.slots-mut (&mut starts)) 2) n)
      (set! (array-ref (i64vec.slots-mut (&mut lengths)) 2) 0)
      (set! (array-ref (i64vec.slots-mut (&mut starts)) 3) (- 0 n))
      (set! (array-ref (i64vec.slots-mut (&mut lengths)) 3) n)
      (set! i 0)
      (while (< i 3)
        (begin
          (set!
            acc
            (+
              acc
              (span-sum
                (& v)
                (array-ref (i64vec.slots (& starts)) i)
                (array-ref (i64vec.slots (& lengths)) i))))
          (set! i (+ i 1))))
      ;; Every accepted span summed 1 per byte: n + 3 + 0.
      (if (not (= acc (+ n 3)))
        (begin
          (io.print-format "accepted spans disagree: {}\n" acc)
          7)
        ;; The refused span: `start = -n` is rejected by whichever form the
        ;; guard took (`start >= 0` signed, `start <=u v.len` unsigned), so the
        ;; slow clone runs and its first checked read aborts.
        (+
          (span-sum
            (& v)
            (array-ref (i64vec.slots (& starts)) 3)
            (array-ref (i64vec.slots (& lengths)) 3))
          42)))))