(import stdlib.io)

(define (initialize) : i64
  (io.eprintln "USER-INIT")
  42)

(define initialized : i64
  (initialize))

(define (main) : i64
  initialized)