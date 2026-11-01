;: A shared slice view borrows its array until the view's last use.
(define (sum [view : (& v (Slice i64))]) : i64
  (let
    [total : i64 0]
    [i : i64 0]
    (begin
      (while (< i (array-length view))
        (begin
          (set! total (+ total (array-ref view i)))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 11 12 13)]
    [view : (& items (Slice i64)) (slice-view items 1 2)]
    [first : i64 (sum view)]
    (begin
      (set! (array-ref items 0) 19)
      (+ first (array-ref items 0)))))