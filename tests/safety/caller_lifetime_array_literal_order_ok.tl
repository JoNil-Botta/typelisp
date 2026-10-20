;; An array literal's element type does not depend on its elements' order: a
;; caller reference and a borrow of a shorter-lived local spelled like the
;; caller's lifetime mix in either order, as main took them for one lifetime.
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

(define (main) : i64
  0)