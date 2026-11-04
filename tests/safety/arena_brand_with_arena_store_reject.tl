;; #9604: a callee-local `with-arena` region ends before the caller's brand.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: `s` ends inside the call; `r` is the caller's arena.
(define (f [ar : (arena.Arena r)] [out : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [cell (box (ann 5 : i64))]
      (set! out.value (& (deref cell))))))

(define (main) : i64
  0)