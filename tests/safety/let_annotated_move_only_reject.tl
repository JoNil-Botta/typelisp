;; The move and borrow checks read an annotated let binding's type from body
;; typing. A move-only value bound through an annotation still moves.
(import stdlib.string)

; Must fail: `s` moved into `t` and is read afterwards.
(define (main) : i64
  (let
    [s : String (string.copy "a")]
    [t : String s]
    (+ (string.string-length (& s)) (string.string-length (& t)))))