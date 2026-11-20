;; #8692: a callee's allocation stored through a `&mut` parameter into
;; storage that outlives the caller's with-arena.
(import stdlib.string)

(defstruct Holder
  (s String))

(define (put [dst : (&mut d Holder)]) : unit
  (set! dst.s (string.append "a" "b")))

(define (main) : i64
  (let
    [h : Holder (Holder "")]
    (with-arena phase (put (&mut h)))
    (string.string-length h.s)))