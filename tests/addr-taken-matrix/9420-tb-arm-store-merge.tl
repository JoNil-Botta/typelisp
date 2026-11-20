;; jump threading: each arm defines the tested flag with a constant, and the
;; taken arm stores false through the flag's own address before the merge.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(import stdlib.io)

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
        (unsafe
          (ptr-write! pg false))
        (set! x 0))
      (begin
        (set! g false)
        (set! x 50)))
    (+
      x
      (if g
        10
        40))))