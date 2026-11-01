;; The accepted twins of the `storage_dead_*_reject` rows: a borrow of a
;; parameter's referent, or of a part of caller-owned storage, may be stored
;; through a `&mut` parameter or returned (#8890). Rust accepts each.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store-referent [p : (& a i64)] [b : (&mut o (RefBox a))]) : unit
  (set! b.value (& (deref p))))

(define (store-element [xs : (& a (Array i64 2))] [b : (&mut o (RefBox a))]) : unit
  (set! b.value (& (array-ref xs 1))))

(define (return-element [xs : (& a (Array i64 2))]) : (& a i64)
  (& (array-ref xs 0)))

(define (main) : i64
  (let
    [xs : (Array i64 2) (array 40 2)]
    [first : (RefBox xs) (RefBox (& (array-ref xs 1)))]
    [second : (RefBox xs) (RefBox (& (array-ref xs 0)))]
    (store-referent (& (array-ref xs 0)) (&mut first))
    (store-element (& xs) (&mut second))
    (+
      (deref first.value)
      (deref second.value)
      (deref (return-element (& xs)))
      -40)))