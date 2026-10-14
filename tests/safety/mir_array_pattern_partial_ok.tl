;; A by-value fixed-array pattern moves each element it binds out of its own
;; literal-index place: elements under `_` stay owned by the array and a later
;; pattern may take them.
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 3)
      (array (string.copy "ab") (string.copy "cde") (string.copy "f"))]
    [first : i64
      (match items
        [(array text _ _) (string.string-length text)])]
    [rest : i64
      (match items
        [(array _ middle last)
          (+ (string.string-length middle) (string.string-length last))])]
    (+ 36 (+ first rest))))