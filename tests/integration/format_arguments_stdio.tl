(import format_arguments_owner as owner)
(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [value (owner.make 7)]
    [arguments (format.args "value={}" value)]
    [materialized : String (format.format arguments)]
    (begin
      (io.println arguments)
      (io.eprintln arguments)
      (if (and (string.eq materialized "value=direct") (= value.value 7))
        42
        1))))