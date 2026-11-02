;; Inside `with-arena r`, an annotation or explicit borrow lifetime spelled `r`
;; names the arena, not the caller lifetime it shadows. Passing the borrow
;; through a let and a lifetime-preserving call keeps the arena region (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (identity [p : (& t i64)]) : (& t i64)
  p)

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [y : (& r i64) (identity (& r (deref x)))]
      ; Must fail: `y` borrows the arena, which resets before the caller
      ; reads `b.value`.
      (set! b.value y))))

(define (main) : i64
  0)