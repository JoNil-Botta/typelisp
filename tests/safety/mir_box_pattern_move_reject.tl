;; A box pattern binding a move-only content moves it out of the box, which
;; consumes the box: a later read of the box is a use of a moved value.
(import stdlib.string)

(define (main) : i64
  (let
    [cell : (Box String) (box (string.copy "abc"))]
    [n : i64
      (match cell
        [(box text) (string.string-length text)])]
    (+ n (string.string-length (deref cell)))))