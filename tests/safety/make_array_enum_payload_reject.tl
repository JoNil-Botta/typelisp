(defenum Item
  (Present (Box i64))
  (Absent))

(define (main) : i64
  (let
    [items (make-array Item 1)]
    (length items)))