;; #9288: borrowing an arena-backed handle (`(in r String)` -> `(& r str)`,
;; `(in r (__tl_dyn-array i64))`) or `(deref b)` of an arena-tagged `Box`
;; points into arena storage rather than the binder's stack slot and stays
;; valid after the callee returns.
(import stdlib.arena)
(import stdlib.string)

(define (mk-str [a : (arena.Arena r)]) : (& r str)
  (in-arena
    a
    (let
      [s (string.copy "hello-arena")]
      (& s))))

(define (mk-str-outside [a : (arena.Arena r)]) : (& r str)
  (let
    [s (in-arena a (string.copy "world"))]
    (& s)))

(define (mk-box-deref [a : (arena.Arena r)]) : (& r i64)
  (let
    [b (in-arena a (box (ann 24 : i64)))]
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
    [o3 (arena.make)]
    [o4 (arena.make)]
    [s1 (mk-str o1)]
    [s2 (mk-str-outside o2)]
    [n (mk-box-deref o3)]
    [xs (mk-arr o4)]
    (+
      (string.string-length s1)
      (+ (string.string-length s2) (+ (deref n) (array-length xs))))))