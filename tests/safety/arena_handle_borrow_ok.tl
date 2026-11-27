;; #9288: borrowing an arena-backed handle (`(in r (__tl_dyn-array i64))`) or
;; `(deref b)` of an arena-tagged `Box` points into arena storage rather than
;; the binder's stack slot and stays valid after the callee returns. Inline
;; `(in r String)` retires with its frame until #8090 makes `(& r str)` a 16B
;; value.
(import stdlib.arena)

(define (mk-box-deref [a : (arena.Arena r)]) : (& r i64)
  (let
    [b (in-arena a (box (ann 40 : i64)))]
    (& (deref b))))

(define (mk-arr [a : (arena.Arena r)]) : (& r (__tl_dyn-array i64))
  (in-arena
    a
    (let
      [xs (__tl_make-array i64 2)]
      (& xs))))

(define (main) : i64
  (let
    [o1 (arena.make)]
    [o2 (arena.make)]
    [n (mk-box-deref o1)]
    [xs (mk-arr o2)]
    (+ (deref n) (array-length xs))))