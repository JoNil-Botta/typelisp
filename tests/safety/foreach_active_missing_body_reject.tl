;: foreach-active needs at least one body form.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 4]) (foreach-active [lane : i64]))
    0))