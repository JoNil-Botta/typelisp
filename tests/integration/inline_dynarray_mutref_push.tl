;; Regression test for inline 16B DynArray `__tl_array-push!` through `&mut`
;; places: a struct field holding `(&mut r (__tl_dyn-array i64))` with an
;; adjacent sentinel field (catches overwriting the reference slot + next word),
;; tuple element of `&mut`, `Box (&mut ...)`, and nested
;; `(&mut a (&mut b (__tl_dyn-array i64)))`.
(defstruct MutHolder
  (:lifetimes r)
  (r (&mut r (__tl_dyn-array i64)))
  (guard i64))

(define (push-via-holder! [h : (&mut h (MutHolder r))] [v : i64]) : unit
  (__tl_array-push! h.r v))

(define (push-via-tuple!
  [t : (&mut t (Tuple (&mut r (__tl_dyn-array i64)) i64))]
  [v : i64]) : unit
  (__tl_array-push! (tuple-ref (deref t) 0) v))

(define (push-via-array!
  [a : (&mut a (Array (&mut r (__tl_dyn-array i64)) 1))]
  [v : i64]) : unit
  (__tl_array-push! (array-ref (deref a) 0) v))

(define (push-via-nested-param!
  [rr : (&mut a (&mut b (__tl_dyn-array i64)))]
  [v : i64]) : unit
  (__tl_array-push! rr v))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [ok1 : bool
      (let
        [h (MutHolder (&mut xs) 777)]
        (__tl_array-push! h.r 10)
        (push-via-holder! (&mut h) 20)
        (= h.guard 777))]
    [ok2 : bool
      (let
        [guard : i64 888]
        [t (tuple (&mut xs) guard)]
        (push-via-tuple! (&mut t) 5)
        (= (tuple-ref t 1) 888))]
    [_ok3 : unit
      (let
        [arr : (Array (&mut xs (__tl_dyn-array i64)) 1) (array (&mut xs))]
        (__tl_array-push! (array-ref arr 0) 3))]
    [_ok4 : unit
      (let
        [b (box (&mut xs))]
        (__tl_array-push! (deref b) 4))]
    (if (and
      ok1
      ok2
      (= (array-length xs) 5)
      (= (array-ref xs 0) 10)
      (= (array-ref xs 1) 20)
      (= (array-ref xs 2) 5)
      (= (array-ref xs 3) 3)
      (= (array-ref xs 4) 4))
      (+
        (array-ref xs 0)
        (+
          (array-ref xs 1)
          (+ (array-ref xs 2) (+ (array-ref xs 3) (array-ref xs 4)))))
      1)))