(import stdlib.format)

;; The control differs only in import order; JSON has no direct source use.
;; lint-allow: unused-import
(import stdlib.json)
(import stdlib.string)

(define (main) : i64
  (let
    [n : i64 7]
    (if (string.eq (format.format "{:#x}" n) "0x7")
      42
      1)))