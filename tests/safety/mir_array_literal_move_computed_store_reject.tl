;; A computed-index store into a partially moved array assigns to part of a
;; moved value: only a literal-index store names the element it reinitializes.
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array (string.copy "abc") (string.copy "de"))]
    [index : i64 0]
    [taken : String (array-ref items 0)]
    (begin
      (set! (array-ref items index) (string.copy "x"))
      (string.string-length taken))))