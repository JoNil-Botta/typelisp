;; A function whose body uses `try` still receives its caller's sret slot. Since
;; #8563 the try error exit builds the Err straight into that slot, so a
;; tail call from `forward` into `checked` forwards the caller's slot (a tail
;; jump at every level) instead of calling into a temporary and copying the
;; 32-byte result. `checked` stays out of line through a never-taken
;; self-recursion. Both the Ok and the propagated Err path are checked.
(import stdlib.io)

(defstruct Span
  (start i64)
  (end i64)
  (line i64))

(defenum SpanResult
  (Ok Span)
  (Err i64))

(defenum Check
  (Ok)
  (Err i64))

(define (check [x : i64]) : Check
  (if (> x 0)
    Ok
    (Err (- 0 x))))

(define (checked [x : i64]) : SpanResult
  (if (< x -999999)
    (checked (+ x 1))
    (let
      [_ (try (check x))]
      (Ok (Span x (* 2 x) 14)))))

(define (forward [x : i64]) : SpanResult
  (checked (+ x 1)))

(define (score [r : SpanResult]) : i64
  (match r
    [(Ok s) (+ s.start s.end s.line)]
    [(Err e) (- 0 e)]))

(define (main) : i64
  (let
    [base : i64 (- (io.arg-count) 1)]
    (+ (score (forward (+ base 11))) (score (forward (- base 9))))))