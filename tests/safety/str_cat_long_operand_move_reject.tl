;: A long `str-cat` (six or more operands) stores each operand by value in its
;: temporary parts array, so a plain String variable operand moves and cannot
;: be used again.
(import stdlib.string)
(import stdlib.str_cat)

(define (main) : i64
  (let
    [name : String (string.concat "a" "b")]
    [joined : String (str_cat.str-cat name "-" "c" "d" "e" "f")]
    (+ (string.string-length joined) (string.string-length name))))