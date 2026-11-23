;; Implicit-cleanup arena escape: `with` cleanup inside `with-escape` stores
;; a scratch allocation into a global.
(import stdlib.arena)
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (main) : i64
  (let
    [s (arena.make)]
    [_v : i64 (with-escape s (with ([x 1 leak]) 1))]
    (arena.destroy-safe! s)
    (if (string.eq (& g) "helloworld")
      42
      7)))