;; An immediately called lambda may capture a mutable reference: the closure
;; is a temporary the call takes, so the capture cannot escape and the owner
;; is readable again after the call.
(define (main) : i64
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    (begin
      ((lambda () : unit
          (set! (array-ref exclusive 0) (+ (array-ref exclusive 0) 2))))
      (array-ref values 0))))