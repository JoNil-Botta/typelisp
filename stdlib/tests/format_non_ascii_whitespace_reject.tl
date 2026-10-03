(import stdlib.format)

(define (main) : i64
  ;; U+00A0 is Rust whitespace, but TypeLisp's current formatter parser sees
  ;; UTF-8 string bytes rather than Unicode scalar values.
  (format.format "{name }")
  42)