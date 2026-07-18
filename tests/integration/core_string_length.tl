;; Bare `length` is a core builtin for both owned and borrowed strings. Each
;; call must lower to the fat string handle's length field, without requiring
;; an external `_tl_length` symbol.
;; lint-allow: unused-import
(import stdlib.string)

(define (borrowed-length [text : (& text str)]) : i64
  (length text))

(define (main) : i64
  (let
    [text : String "hello"]
    (if (and
      (= (length "abc") 3)
      (= (length text) 5)
      (= (borrowed-length (& text)) 5))
      42
      1)))