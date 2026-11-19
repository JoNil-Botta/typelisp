;; #8173: an allocation through a bare arena parameter handed to a callee that
;; stores it into the caller's struct.
(import stdlib.arena)
(import stdlib.string)

(defstruct Holder
  (s String))

(define (keep [dst : (&mut d Holder)] [s : String]) : unit
  (set! dst.s s))

(define (fill [a : arena.Arena] [dst : (&mut d Holder)]) : unit
  (let
    [s : String (in-arena a (string.append "a" "b"))]
    (keep dst s)))

(define (main) : i64
  (let
    [h : Holder (Holder "")]
    [o : arena.Arena (arena.make)]
    (fill o (&mut h))
    (arena.destroy-safe! o)
    (string.string-length (& h.s))))