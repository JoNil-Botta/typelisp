(define (main) : i64
  (with-region
    r
    (let
      [s : String (int->string 41)]
      (string-length s))))