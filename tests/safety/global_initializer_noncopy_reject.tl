;; A global initialized from a non-Copy global would move out of it (#7804). The
;; initializer is rejected like every other by-value use of a non-Copy global,
;; before lowering could copy the value or the global's address.
(define greeting : String
  "hello")
(define copy : String
  greeting)

(define (main) : i64
  0)