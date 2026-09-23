;; The #7921 reproducer: Wide is written out without macros with fields
;; f0..f1002 plus `tail`, and Next follows it with four bool fields. f1001 is an
;; i64, so using it as an `if` condition is the ordinary type error.
(import wide_struct_literal_decls.*)

(define (main) : i64
  (let
    [w : Wide (make)]
    (if w.f1001
      42
      1)))