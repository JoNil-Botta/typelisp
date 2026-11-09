;; Helper for entry_value_scope_p21_prelude_same (#9687).
(import stdlib.string)

(define (n-prel3) : i64
  (let
    [s : String (int-to-string 12345)]
    (string.string-length (& s))))