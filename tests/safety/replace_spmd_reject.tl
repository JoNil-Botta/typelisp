;: replace! has no scalarized or vector replacement semantics in foreach.
(define (main [n : i64]) : i64
  (let
    [value : i64 0]
    (begin
      (foreach
        ([i : i64 0 n])
        (begin
          (replace! value i)
          unit))
      value)))