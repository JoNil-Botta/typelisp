;; A box pattern binding a Copy content copies it out: the box stays usable.
(define (main) : i64
  (let
    [cell : (Box i64) (box 40)]
    [n : i64
      (match cell
        [(box value) value])]
    (+ n (- (deref cell) 38))))