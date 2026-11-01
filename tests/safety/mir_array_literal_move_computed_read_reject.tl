;; A computed index may name the moved element, so reading a partially moved
;; array through one uses a moved value (legacy accepted this read).
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array (string.copy "abc") (string.copy "de"))]
    [index : i64 0]
    [taken : String (array-ref items 0)]
    (string.string-length (array-ref items index))))