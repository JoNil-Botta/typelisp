;; #8805: a scratch-body allocation passed to a callee that stores it through
;; a `&mut` parameter into outer storage.
(define (fresh-box [n : i64]) : (Box i64)
  (box n))

(define (store-box [slot : (&mut s (Box i64))] [b : (Box i64)]) : unit
  (set! (deref slot) b))

(define (main) : i64
  (let
    [slot : (Box i64) (fresh-box 0)]
    (with-scratch (store-box (&mut slot) (fresh-box 41)))
    (deref slot)))