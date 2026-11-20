;; jump threading: the constant flag def and the store through &f share a block,
;; so the last-def walk sees the Mov and not the aliasing store.
;; Expected exit 41 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [f : bool true]
    [pf : (MutPtr bool)
      (unsafe
        (ptr-addr-of f))]
    [x : i64 0]
    (if f
      (begin
        (unsafe
          (ptr-write! pf false))
        (set! x 1))
      (set! x 2))
    (+
      x
      (if f
        10
        40))))