;: replace! requires writable storage and cannot write through a shared Slice.
(define (replace-shared [items : (& items (Slice i64))]) : i64
  (replace! (array-ref items 0) 1))

(define (main) : i64
  42)