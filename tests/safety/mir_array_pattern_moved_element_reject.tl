;; An element a fixed-array pattern moved out is gone: a later pattern that
;; binds the same element again uses a moved value.
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array (string.copy "ab") (string.copy "cde"))]
    [first : i64
      (match items
        [(array text _) (string.string-length text)])]
    (match items
      [(array again _) (+ first (string.string-length again))])))