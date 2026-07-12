;; Full generated catalogs validate unused helpers at the generator import.
(defmacro (catalog [T : type]) : Module
  `(begin
    (module generated.catalog_invalid)
    (defstruct Item
      (value ,T))
    (define (answer) : i64
      42)
    (define (invalid-unused-helper) : i64
      true)))

(import (catalog i64) as catalog_i64)

(define (main) : i64
  (catalog_i64.answer))