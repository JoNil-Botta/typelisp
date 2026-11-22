(defenum Same
  (Same i64))

(define (values) : (__tl_dyn-array Same)
  (with-scratch (__tl_make-array (Same 42))))

(define (main) : i64
  (match (array-ref (values) 0)
    [(Same value) value]))