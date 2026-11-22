;; jump threading: the const flag def is followed by a call holding &g, then the
;; merge branches on g.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (clear [p : (MutPtr bool)])
  (unsafe
    (ptr-write! p false)))

(define (main) : i64
  (let
    [g : bool true]
    [pg : (MutPtr bool)
      (unsafe
        (ptr-addr-of g))]
    [f : bool (= (io.arg-count) 1)]
    [x : i64 0]
    (if f
      (begin
        (set! g true)
        (clear pg)
        (set! x 0))
      (begin
        (set! g false)
        (set! x 50)))
    (+
      x
      (if g
        10
        40))))