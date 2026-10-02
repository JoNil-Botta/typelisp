;; An arm counts toward length coverage only when its element patterns are
;; irrefutable; a literal element leaves the other values of that length open.
(define (zero-count [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice 0 & rest) (+ 1 (zero-count rest))]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 0 1)]
    (zero-count (& items))))