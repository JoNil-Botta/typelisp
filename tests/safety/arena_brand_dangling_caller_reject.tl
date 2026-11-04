;; #9604: the caller witness. `f` would keep a borrow of `x` in a box that lives
;; in the caller's arena, and `main` reads it after `x`'s scope has ended.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

; Must fail: storing `ra` lets it outlive `x`.
(define (f
  [a : i64]
  [ra : (& a i64)]
  [ar : (arena.Arena r)]
  [out : (&mut r (RefBox r))]) : unit
  (set! out.value ra))

(define (main) : i64
  (let
    [ar (arena.make)]
    (in-arena
      ar
      (let
        [slot (box (ann 5 : i64))]
        [bx (RefBox (& (deref slot)))]
        (begin
          (let
            [x : i64 7]
            (f x (& x) ar (&mut bx)))
          (deref bx.value))))))