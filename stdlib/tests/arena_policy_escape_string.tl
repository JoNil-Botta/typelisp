(import stdlib.string)

; Must fail: the String returned by string-trim is owned by the inner active
; arena and cannot escape to the outer scope.
(define (main) : String
  (with-arena
    outer
    (with-arena
      inner
      (let
        [s : String "  scoped  "]
        (string.string-trim (& s))))))