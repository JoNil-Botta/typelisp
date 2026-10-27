;; An immediately invoked lambda stores a borrow of its capture into an outer
;; array through a captured `&mut` (#9297).
(define (scrub [r : (& i64)] [seed : i64]) : i64
  (let
    [a : (Array i64 32)
      (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    [i : i64 0]
    (while (< i 32)
      (set! (array-ref a i) (+ seed i))
      (set! i (+ i 1)))
    (+ (deref r) (- (array-ref a (% seed 32)) (array-ref a (% seed 32))))))

(define (main) : i64
  (let
    [x : i64 42]
    [slots : (Array (& x i64) 1) (array (& x))]
    [out : (&mut slots (Array (& x i64) 1)) (&mut slots)]
    ; Must fail: the stored `(& x)` borrows the lambda's copy of `x`.
    ((lambda () : unit
        (set! (array-ref out 0) (& x))))
    (scrub (array-ref slots 0) 100)))