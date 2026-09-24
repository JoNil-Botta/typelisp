;; Shifts whose count is a `bit_and` with a literal below the width cannot
;; abort, so the backend drops their count guard. The results must be the same
;; as the guarded shift's for every raw count: negative, past the width, and in
;; range. A count masked wider than the width, and a count var with a second,
;; unmasked definition, keep their guard.
(import stdlib.io)

(define (bit-at [word : i64] [n : i64]) : i64
  (bit-and (shr word (bit-and n 63)) 1))

(define (field [word : i64] [n : i64]) : i64
  (bit-and (shr word (bit-and (- n 16) 63)) 65535))

(define (mask-bit [n : i64]) : i64
  (shl 1 (bit-and n 63)))

(define (low-mask [n : i64]) : i64
  (shl 1 (bit-and n 31)))

(define (wide [word : i64] [n : i64]) : i64
  (shr word (bit-and n 127)))

(define (either [word : i64] [n : i64] [masked? : bool]) : i64
  (let
    [count : i64
      (if masked?
        (bit-and n 63)
        n)]
    (shl word count)))

(define (main) : i64
  (let
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [word : i64 -6148914691236517206]
    [i : i64 0]
    [total : i64 0]
    (begin
      (set! (array-ref counts 0) 0)
      (set! (array-ref counts 1) 17)
      (set! (array-ref counts 2) 63)
      (set! (array-ref counts 3) 64)
      (set! (array-ref counts 4) 1000)
      (set! (array-ref counts 5) -3)
      (while (< i 6)
        (let
          [n : i64 (array-ref counts i)]
          (begin
            (io.println
              "{} {} {} {} {}"
              (bit-at word n)
              (field word n)
              (mask-bit n)
              (low-mask n)
              (either 3 n true))
            (set! total (+ total (bit-at word n)))
            (set! i (+ i 1)))))
      (io.println "{} {}" (wide word 5) (either 3 5 false))
      (+ 40 total))))