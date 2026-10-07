;; A function may store a reference parameter into a field of a
;; lifetime-parameterized struct it receives through `&mut` when the lifetimes
;; match (#8584): the store is checked against the field's own lifetime `a`,
;; which outlives the `&mut` reference, not against the reference itself.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Outer
  (:lifetimes a)
  (inner (RefBox a)))

(define (store-deref [b : (&mut (RefBox a))] [v : (& a i64)]) : unit
  (set! (deref b).value v))

(define (store-dotted [b : (&mut (RefBox a))] [v : (& a i64)]) : unit
  (set! b.value v))

(define (store-named [b : (&mut m (RefBox a))] [v : (& a i64)]) : unit
  (set! (deref b).value v))

(define (store-whole [b : (&mut (RefBox a))] [v : (& a i64)]) : unit
  (set! (deref b) (RefBox v)))

(define (store-nested [o : (&mut (Outer a))] [v : (& a i64)]) : unit
  (set! (deref o).inner.value v))

(define (main) : i64
  (let
    [xs : (Array i64 6) (array 0 1 2 3 4 32)]
    [rb : (RefBox xs) (RefBox (& (array-ref xs 0)))]
    [ob : (Outer xs) (Outer (RefBox (& (array-ref xs 0))))]
    [total : i64 0]
    (store-deref (&mut rb) (& (array-ref xs 1)))
    (set! total (+ total (deref rb.value)))
    (store-dotted (&mut rb) (& (array-ref xs 2)))
    (set! total (+ total (deref rb.value)))
    (store-named (&mut rb) (& (array-ref xs 3)))
    (set! total (+ total (deref rb.value)))
    (store-whole (&mut rb) (& (array-ref xs 4)))
    (set! total (+ total (deref rb.value)))
    (store-nested (&mut ob) (& (array-ref xs 5)))
    (+ total (deref ob.inner.value))))