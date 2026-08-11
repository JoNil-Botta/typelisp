;; lint-allow: unused-import
(import stdlib.string)

(define (main [cell : (Box String)]) : i64
  (let
    [value : String (deref cell)]
    (+ (string-length value) (string-length (__tl-box-place cell)))))