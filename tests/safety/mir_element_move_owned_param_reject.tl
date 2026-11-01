;: A computed-index element of an owned dynamic array cannot move out: the
;: checker cannot name the moved slot (SPEC: array element ownership).
(import stdlib.string)

(defstruct Item
  (name String)
  (n i64))

(define (take [xs : (__tl_dyn-array Item)] [i : i64]) : Item
  (array-ref xs i))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array Item) (__tl_make-array Item 1)]
    (begin
      (set! (array-ref xs 0) (Item (string.copy "a") 1))
      (take xs 0).n)))