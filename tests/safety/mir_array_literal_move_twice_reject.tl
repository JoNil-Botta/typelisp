;; An element moved out at a literal index is gone until a literal-index store
;; reinitializes it.
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array (string.copy "abc") (string.copy "de"))]
    [taken : String (array-ref items 0)]
    [again : String (array-ref items 0)]
    (string.string-length again)))