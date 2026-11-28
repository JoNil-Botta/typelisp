;; #9288: borrowing `(deref b)` of an arena-tagged `Box` points into arena
;; storage rather than the binder's stack slot and stays valid after the callee
;; returns. Inline `(in r String)` and `(in r (__tl_dyn-array T))` descriptors
;; retire with their frame.
(import stdlib.arena)

(define (mk-box-deref [a : (arena.Arena r)]) : (& r i64)
  (let
    [b (in-arena a (box (ann 42 : i64)))]
    (& (deref b))))

(define (main) : i64
  (let
    [o1 (arena.make)]
    [n (mk-box-deref o1)]
    (deref n)))