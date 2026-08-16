(import format_owner_beta as second)
(import format_owner_alpha as first)
(import stdlib.format)
(import stdlib.io)

(define (main) : i64
  (begin
    (io.println "{}|{}" (first.Token 1) (second.Token 2))
    0))