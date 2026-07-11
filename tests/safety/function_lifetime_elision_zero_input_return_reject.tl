(defstruct ElisionItem
  (value i64))

(define (make-view) : (& ElisionItem)
  (panic "unreachable"))

(define (main) : i64
  42)