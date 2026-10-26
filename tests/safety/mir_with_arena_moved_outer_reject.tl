;; A with-arena body may move an outer owner; the owner is moved after the
;; form like after any block.
(import stdlib.string)

(define (consume [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (let
    [owned : String (string.copy "abc")]
    (begin
      (with-arena scratch (consume owned))
      (string.string-length owned))))