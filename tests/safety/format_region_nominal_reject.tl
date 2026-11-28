(import stdlib.io)

(defstruct NoFormatter
  (n i64))

(define (read-tagged [p : (& p NoFormatter)]) : (in p NoFormatter)
  (deref p))

(define (show [p : (& p NoFormatter)]) : unit
  (io.print-format "{}\n" (read-tagged p)))