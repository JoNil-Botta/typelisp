; Entry module: imports a helper and calls functions defined there.
; (triple 8) = 24, (add 24 6) = 30 -> process exit code 30.
(import modules_helper as helper)

(define (main) : i64
  (helper.add (helper.triple 8) 6))
