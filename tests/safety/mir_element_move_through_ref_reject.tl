;: Moving a non-Copy element out of a dynamic array behind a shared reference
;: would duplicate its owner (Rust E0507); only `replace!` may take it.
(import stdlib.string)

(defstruct Item
  (name String)
  (n i64))

(define (take-ref [xs : (& xs (__tl_dyn-array Item))] [i : i64]) : Item
  (array-ref xs i))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array Item) (__tl_make-array Item 1)]
    (begin
      (set! (array-ref xs 0) (Item (string.copy "a") 1))
      (let
        [a : Item (take-ref (& xs) 0)]
        [b : Item (take-ref (& xs) 0)]
        (+ a.n b.n)))))