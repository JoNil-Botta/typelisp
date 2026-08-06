;: SPMD body checking cannot bypass the global move restriction.
(define global-text : String
  "spmd-owned")

(define (main [n : i64]) : i64
  (begin
    (foreach
      ([i : i64 0 n])
      (let
        [_moved : String global-text]
        unit))
    42))
