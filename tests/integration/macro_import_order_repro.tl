;; Intentionally first: this ordering exposed the lost definition-site alias in
;; #5648. The import participates through the loader, not a direct source use.
;; lint-allow: unused-import
(import stdlib.json)
(import stdlib.format)
(import stdlib.string)

(define (main) : i64
  (let
    [n : i64 7]
    (if (string.eq (format.format "{}" n) "7")
      42
      1)))
