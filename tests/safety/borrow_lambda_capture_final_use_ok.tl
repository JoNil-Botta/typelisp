;: A directly invoked lambda and a macro-generated nested closure both count as
;: real uses of a lending binding. Their mutable borrow ends before the owner
;: read that follows the call.
(defmacro (call-captured [body : unit]) : unit
  `(let
    [captured-call : (-> unit)
      (lambda () : unit
        ,body)]
    (captured-call)))

(define (direct-capture) : i64
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    (begin
      ((lambda () : unit
          (array-set! exclusive 0 (+ (array-ref exclusive 0) 1))))
      (array-ref values 0))))

(define (generated-capture) : i64
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    (begin
      (call-captured (array-set! exclusive 0 (+ (array-ref exclusive 0) 1)))
      (array-ref values 0))))

(define (main) : i64
  0)