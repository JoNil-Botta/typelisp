;; A raw range helper cannot become a function value, even inside `unsafe`
;; (#7700). This check-only fixture must never execute.
(import stdlib.format)

(define (main) : i64
  (let
    [_fill : (-> (MutPtr u8) i64 i64 char unit)
      (unsafe
        format.format-write-fill!)]
    0))