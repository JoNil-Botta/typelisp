; IAG-1: a three-field (24-byte) aggregate global. The inline cell reserves the
; whole aggregate and the startup copy unrolls past the first 16 bytes.
(import stdlib.io)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(define triple : Triple
  (Triple 1 2 3))

(define (install! [a : i64] [b : i64] [c : i64]) : unit
  (set! triple (Triple a b c)))

(define (weigh [t : (& Triple)]) : i64
  (+ t.a (+ (* t.b 10) (* t.c 100))))

(define (report) : i64
  (+ (weigh (& triple)) (+ triple.a (+ triple.b triple.c))))

(define (main) : i64
  (begin
    (io.print-format "{}\n" (report))
    (install! 4 5 6)
    (io.print-format "{}\n" (report))
    42))