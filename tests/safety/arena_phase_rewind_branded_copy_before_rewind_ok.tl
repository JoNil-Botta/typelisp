;; #9846 control: ref-wrapped branded arena and erased bare copies remain
;; usable before `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(defstruct RefWrap
  (:lifetimes s r)
  (a (& s (arena.Arena r))))

(define (fill [w : (RefWrap s r)]) : (in r String)
  (in-arena w.a (string.append "a" "b")))

(define (erase [a : (arena.Arena r)]) : arena.Arena
  a)

(define (pass [a : arena.Arena]) : arena.Arena
  a)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [w (RefWrap (& owner))]
    [t1 (fill w)]
    [c2 (pass owner)]
    [t3 (in-arena c2 (string.append "xy" "z"))]
    [c1 (erase owner)]
    [t2 (in-arena c1 (string.append "hello" "world"))]
    [n
      (+
        (string.string-length (& t1))
        (+ (string.string-length (& t2)) (string.string-length (& t3))))]
    (arena.rewind-safe! p)
    (+ 27 n)))