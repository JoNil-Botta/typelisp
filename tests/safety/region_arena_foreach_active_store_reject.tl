;; A `foreach-active` lane spelled like the arena does not let arena data
;; reach caller storage from its body (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      (foreach
        ([i : i64 0 1])
        (foreach-active [r : i64] (set! b.value (& (deref x))))))))

(define (main) : i64
  0)