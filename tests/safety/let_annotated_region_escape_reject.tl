;; The move and borrow checks read an annotated let binding's type from body
;; typing. A value allocated in an arena keeps its region through an annotated
;; binding, so it still cannot escape the arena.
(import stdlib.string)

; Must fail: `s` is allocated in `phase` and returned out of it.
(define (main) : String
  (with-arena
    phase
    (let
      [s : String (string.int->string 41)]
      s)))