(import stdlib.string)

(define (main) : i64
  (with-arena
    r
    (let
      [s : String (string.int->string 41)]
      (string-length s))))
