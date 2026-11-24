;; Implicit-cleanup arena escape: `with` cleanup inside `with-scratch` stores
;; a scratch allocation into a global.
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (main) : i64
  (let
    [_v : i64 (with-scratch (with ([x 1 leak]) 1))]
    (if (string.eq (& g) "helloworld")
      42
      7)))