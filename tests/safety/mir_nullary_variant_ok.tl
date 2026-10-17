;: Nullary variants, called or used as values, through an import alias.
(import stdlib.option)
(import (option.option i64) as option_i64)

(define (pick [flag : bool]) : option_i64.Option
  (if flag
    (option_i64.Some 42)
    option_i64.None))

(define (main) : i64
  (match (pick true)
    [(option_i64.Some value) value]
    [(option_i64.None) 0]))