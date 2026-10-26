;; A closure capturing a mutable reference is called through an exclusive
;; borrow each time; the owner is readable again after the closure's last use.
(define (main) : i64
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump : (-> unit)
      (lambda () : unit
        (set! (array-ref exclusive 0) (+ (array-ref exclusive 0) 1)))]
    (begin
      (bump)
      (bump)
      (array-ref values 0))))