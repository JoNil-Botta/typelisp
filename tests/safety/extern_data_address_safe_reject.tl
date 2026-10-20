(extern foreign-data (:symbol "foreign_exact") : i64)

(define (main) : (MutPtr i64)
  (ptr-addr-of foreign-data))