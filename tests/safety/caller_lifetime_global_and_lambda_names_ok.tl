;; A top-level name spelled like a caller lifetime does not shadow it in
;; annotations, and a lambda's parameter types name the enclosing lifetime,
;; also for a closure that captures the caller's `&mut` place.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (t) : i64
  1)

(define (read-global [p : (& t i64)]) : i64
  (let
    [q : (& t i64) p]
    (+ (deref q) (t))))

(define (read-lambda [p : (& a i64)]) : i64
  (let
    [g
      (lambda ([q : (& a i64)]) : i64
        (let
          [r : (& a i64) q]
          (deref r)))]
    (let
      [a : i64 1]
      (+ a (g p)))))

(define (store [p : (& a i64)] [b : (&mut a (RefBox a))]) : unit
  (let
    [put
      (lambda ([q : (& a i64)]) : unit
        (set! b.value q))]
    (let
      [a : i64 5]
      (put p))))

(define (main) : i64
  0)