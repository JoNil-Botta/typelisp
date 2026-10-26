;; A slice element store through `&mut` whose value exits never stores: the
;; slice's reborrow for the store is never taken, and the call returns 42.
(define (store-or-leave [a : (&mut a (Slice i64))] [leave : bool]) : i64
  (set!
    (array-ref a 0)
    (if leave
      (return 42)
      7))
  (array-ref a 0))

(define (leave [a : (&mut a (Slice i64))]) : i64
  (set! (array-ref a 0) (return 42))
  1)

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (if (= (store-or-leave (&mut items) false) 7)
      (leave (&mut items))
      1)))