; (with-arena ...) takes a mark at entry and resets it at scope exit (#550),
; so a loop that allocates inside the region each iteration reuses the arena
; rather than growing it without bound. Every region body here returns a
; region-free scalar (a length), so the reset is safe.
; Tail-recursive loop: each iteration allocates a fresh String inside the region
; and resets it, accumulating only the (region-free) length.
(define (sum-lengths [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (sum-lengths
      (- n 1)
      (+
        acc
        (with-arena
          r
          (let
            [s : String (string-append "ab" "cd")]
            (string-length s)))))))

; Nested regions: the inner region resets before the outer one. Both bodies
; yield scalars.
(define (nested) : i64
  (with-arena
    outer
    (let
      [a : String (string-append "x" "y")]
      (+
        (string-length a)
        (with-arena
          inner
          (let
            [b : String (string-append "p" "q")]
            (string-length b)))))))

(define (main) : i64
  (if (= (sum-lengths 1000 0) 4000)
    (if (= (nested) 4)
      42
      1)
    2))