(defstruct NotIterable
  (value i64))

(define (main) : i64
  (begin
    (for [item (NotIterable 1)]
      (set! item.value 2))
    42))
