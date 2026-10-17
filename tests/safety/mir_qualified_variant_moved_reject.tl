;: A variant constructor named through an import alias moves its payload.
(import stdlib.string)
(import stdlib.option)
(import (option.option String) as option_string)

(define (run [name : String]) : i64
  (let
    [wrapped : option_string.Option (option_string.Some name)]
    (string.string-length name)))

(define (main) : i64
  0)