;; Implicit-cleanup arena escape: local function binding used as `with`
;; cleanup inside `with-arena` is mapped through the indirect call bucket.
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (main) : i64
  (let
    [f leak]
    (with-arena r (with ([x 1 f]) 0))
    (if (string.eq (& g) "helloworld")
      42
      7)))