;; `writeln!` takes its template from a variadic operand list since #6985; a
;; nonliteral template must still be rejected exactly as before.
(import stdlib.byte_buf)
(import stdlib.format)

(define (main) : i64
  (let
    [bytes : byte_buf.ByteBuf (byte_buf.new)]
    [template : String "value={}"]
    (match (format.writeln! bytes template 7)
      [(format.FormatOk) 42]
      [(format.FormatErr _) 1])))