;: Lane identity forms are not valid in foreach bounds.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 (program-count)]) unit)
    0))