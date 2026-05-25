(import "stdlib/string.tl")

; Must fail: the String returned by string-trim is owned by the inner active
; arena and cannot escape to the outer scope.
(define (main) : String
  (with-region outer (with-region inner (string-trim "  scoped  "))))