;; A macro-bearing imported body must resolve the provider's unqualified
;; declaration, even when the compile root has a same-spelled declaration.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define (macro-module-local-shadow-value [value : String]) : String
  value)

(define (macro-module-local-shadow-direct) : String
  (str_cat.str-cat (macro-module-local-shadow-value "20") ""))

(define (macro-module-local-shadow-later) : String
  (let
    [value : String (macro-module-local-shadow-value "22")]
    (str_cat.str-cat value "")))

(define (macro-module-local-shadow-answer) : i64
  (if (and
    (string.eq (macro-module-local-shadow-direct) "20")
    (string.eq (macro-module-local-shadow-later) "22"))
    42
    1))

(define (main) : i64
  (macro-module-local-shadow-answer))