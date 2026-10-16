;; Values allocated inside a with-arena scope are used inside it; the form's
;; value is a scalar that outlives the reset.
(import stdlib.string)

(define (main) : i64
  (let
    [base : i64 40]
    (with-arena
      scratch
      (let
        [text : String (string.copy "ab")]
        (+ base (string.string-length text))))))