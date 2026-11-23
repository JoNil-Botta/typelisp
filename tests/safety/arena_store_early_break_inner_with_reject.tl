;; Implicit-cleanup arena escape: early `break` out of `with` inside
;; `with-arena` runs the cleanup while the arena is still active.
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (main) : i64
  (let
    [i : i64 0]
    (while (< i 1)
      (with-arena r (with ([x 1 leak]) (break)))))
  (if (string.eq (& g) "helloworld")
    42
    7))