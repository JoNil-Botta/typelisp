;; Typing lets a value of the earlier arena `a` flow into the brand the call
;; binds to `b`, so `kept` names `b` alone and destroying `a` would not end it
;; (a use of freed memory). The ownership graph sees arena values only through
;; their brands, so it does not represent a call that coerces one arena's value
;; into another arena's brand.
(import stdlib.arena)
(import stdlib.string)

(define (keep [_o : (& x (arena.Arena r))] [t : (in r String)]) : (in r String)
  t)

(define (main) : i64
  (let
    [a (arena.make)]
    [b (arena.make)]
    [text (in-arena a (string.append "a" "b"))]
    [kept (keep (& b) text)]
    (begin
      (arena.destroy-safe! a)
      (string.string-length kept))))