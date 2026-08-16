(import format_owner_alpha as left)
(import format_owner_beta as right)
(import stdlib.format)
(import stdlib.io)

(define (main) : i64
  (begin
    (io.println "{}|{}" (left.Token 1) (right.Token 2))
    0))