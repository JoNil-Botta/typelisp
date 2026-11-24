;; #9944: Unshadowed `program-argc` rejects unexpected arguments.
(define (main) : i64
  (program-argc 1))