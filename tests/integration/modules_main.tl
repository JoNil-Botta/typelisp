; Entry module: imports a helper and calls functions defined there.
; (triple 8) = 24, (add 24 6) = 30 -> process exit code 30.
(import "modules_helper.tl")

(define (main) : i64
  (add (triple 8) 6))