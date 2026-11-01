;; A move-only element of a fixed array at a literal index moves its exact
;; path: a disjoint literal element stays usable, and a literal-index store
;; reinitializes the moved element.
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array String 2) (array (string.copy "abc") (string.copy "de"))]
    [taken : String (array-ref items 0)]
    [other : i64 (string.string-length (array-ref items 1))]
    (begin
      (set! (array-ref items 0) (string.copy "fghij"))
      (+
        32
        (+
          (string.string-length taken)
          (+ other (string.string-length (array-ref items 0))))))))