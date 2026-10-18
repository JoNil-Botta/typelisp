;; An array literal's element type does not depend on its elements' order: a
;; caller reference and a borrow of a shorter-lived local, spelled like the
;; caller's lifetime or not, mix in either order.
(define (caller-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rs (array (& (array-ref xs 0)) (& a))]
    (deref (array-ref rs 1))))

(define (local-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rs (array (& a) (& (array-ref xs 0)))]
    (deref (array-ref rs 1))))

(define (other-name-caller-first [xs : (& a (Array i64 2))]) : i64
  (let
    [z : i64 0]
    [rs (array (& (array-ref xs 0)) (& z))]
    (deref (array-ref rs 1))))

(define (other-name-local-first [xs : (& a (Array i64 2))]) : i64
  (let
    [z : i64 0]
    [rs (array (& z) (& (array-ref xs 0)))]
    (deref (array-ref rs 1))))

(define (main) : i64
  0)