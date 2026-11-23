;; Implicit-cleanup arena escape: early `return` out of `with` inside
;; `with-arena` runs the cleanup while the arena is still active.
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (work) : i64
  (with-arena r (with ([x 1 leak]) (return 0)) 1))

(define (main) : i64
  (let
    [_ : i64 (work)]
    (if (string.eq (& g) "helloworld")
      42
      7)))