;; Annotations and named borrows inside a shadowing scope name the local.
(define (read-param [a : i64] [p : (& a i64)]) : i64
  (let
    [r : (& a i64) (& a)]
    (+ (deref r) (deref p))))

(define (read-local [p : (& a i64)]) : i64
  (let
    [a : i64 1]
    (let
      [r : (& a i64) (& a a)]
      (+ (deref r) (deref p)))))

(define (main) : i64
  0)