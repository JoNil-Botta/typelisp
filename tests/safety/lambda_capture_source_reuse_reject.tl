(import stdlib.string)

(define (main) : i64
  (let
    [owned : String "captured"]
    [read : (-> i64)
      (lambda () : i64
        (string.string-length owned))]
    [moved : String owned]
    (begin
      (read)
      (string.string-length moved))))