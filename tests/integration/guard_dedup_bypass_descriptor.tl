;; IT-2 runtime coverage: the `intern-hash-words` shape, with the slice
;; DESCRIPTOR bound once at the top of the kernel -- two sequential loops over
;; one span, an out-of-line eight-offset word loader that opt2 inlines, and a
;; single-byte tail. The tail loop's versioning guard is reached both through
;; the word loop and on a bypass edge from the entry block, and on that edge the
;; descriptor words the word loop's own guard loaded never executed, so the tail
;; guard re-derives them. IT-2 moves the pair onto the bypass edge and retires
;; the re-derivation, so both guards read ONE pair of loaded words.
;;
;; What must hold is that whichever clone each guard selects computes exactly
;; what the checked one computes, at every optimization level, for every span
;; the caller can present: an empty span, a one-byte span, a span shorter than
;; one word, a span ending exactly at the container's end, a span starting at
;; the container's end, and the whole container. Every span is derived from
;; argv, so nothing folds at compile time.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector u8) as u8vec)

;; The word loader is out of line so that opt2's inliner is what puts its
;; descriptor read inside the first loop -- the placement that leaves the tail
;; guard re-deriving the words on the bypass edge.
(define (gd-load-word [v : (& v u8vec.Vec)] [at : i64]) : i64
  (let
    [slots (u8vec.slots v)]
    [word : i64 0]
    [b : i64 7]
    (begin
      (while (>= b 0)
        (begin
          (set! word (+ (* word 2) (cast (array-ref slots (+ at b)) : i64)))
          (set! b (- b 1))))
      word)))

(define (gd-hash [v : (& v u8vec.Vec)] [start : i64] [len : i64]) : i64
  (let
    [slots (u8vec.slots v)]
    [h : i64 (+ 5381 len)]
    [i : i64 0]
    [words : i64 (- len 7)]
    [tail : i64 0]
    (begin
      (while (< i words)
        (begin
          (set! h (+ (* h 31) (gd-load-word v (+ start i))))
          (set! i (+ i 8))))
      (while (< i len)
        (begin
          (set!
            tail
            (+ (* tail 256) (cast (array-ref slots (+ start i)) : i64)))
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
      (while (<= start n)
        (begin
          (set! acc (+ (* acc 7) (gd-hash (& v) start 0)))
          (set! acc (+ (* acc 7) (gd-hash (& v) start (- n start))))
          (set! start (+ start 1))))
      (set! acc (+ (* acc 7) (gd-hash (& v) 0 1)))
      (set! acc (+ (* acc 7) (gd-hash (& v) 1 7)))
      (set! acc (+ (* acc 7) (gd-hash (& v) 1 8)))
      (set! acc (+ (* acc 7) (gd-hash (& v) (- n 8) 8)))
      (set! acc (+ (* acc 7) (gd-hash (& v) 0 n)))
      (io.print-format "{}\n" acc)
      42)))