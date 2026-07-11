(defstruct ElisionItem
  (value i64))

(define (choose [left : (& ElisionItem)] [right : (& ElisionItem)]) : (&
    ElisionItem)
  left)

(define (main) : i64
  42)