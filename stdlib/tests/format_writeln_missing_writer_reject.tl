;; Only the template became optional in #6985: `writeln!` still requires its
;; writer operand.
(import stdlib.format)

(define (main) : i64
  (match (format.writeln!)
    [(FormatOk) 42]
    [(FormatErr _) 1]))