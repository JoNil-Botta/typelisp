;; Only the template became optional in #6985: `writeln!` still requires its
;; writer operand.
(import stdlib.format)

(define (main) : i64
  (match (format.writeln!)
    [(format.FormatOk) 42]
    [(format.FormatErr _) 1]))