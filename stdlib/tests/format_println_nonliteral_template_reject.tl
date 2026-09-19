;; `println` takes its template from a variadic operand list since #6985; a
;; nonliteral template must still be rejected exactly as before.
(import stdlib.io)

(define (main) : i64
  (let
    [template : String "value={}"]
    (begin
      (io.println template 7)
      42)))