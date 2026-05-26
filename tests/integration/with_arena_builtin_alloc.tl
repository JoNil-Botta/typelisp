(define (main) : i64
  (with-arena
    r
    (let
      [s : String (int->string 41)]
      (string-length s))))