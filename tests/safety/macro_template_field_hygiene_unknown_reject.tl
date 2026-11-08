;; #8749: an unknown field named by a hygiene-renamed macro template symbol is
;; reported under its source spelling, not rendered as a raw structural key.
(import stdlib.byte_buf)

(defstruct Span
  (owner i64)
  (size i64))

(defmacro (span-len [span : Expr]) : i64
  `(__tl-project-field ,span len))

(define (main [span : Span]) : i64
  (span-len span))