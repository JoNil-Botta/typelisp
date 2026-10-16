;; A mutable borrow taken inside a with-arena body conflicts with a write to
;; its owner while the borrow is still used.
(define (main) : i64
  (let
    [values : (Array i64 2) (array 40 2)]
    (with-arena
      scratch
      (let
        [exclusive : (&mut values (Array i64 2)) (&mut values)]
        (begin
          (set! (array-ref values 0) 1)
          (set! (array-ref exclusive 1) 2)
          (+ (array-ref values 0) 41))))))