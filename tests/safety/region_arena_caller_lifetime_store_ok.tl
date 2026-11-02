;; Inside a `with-arena` region spelled like the caller lifetime, caller data
;; keeps the caller lifetime: storing it into caller storage is not an arena
;; escape (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      (set! b.value p)
      (+ (deref x) (deref b.value)))))

(define (main) : i64
  0)