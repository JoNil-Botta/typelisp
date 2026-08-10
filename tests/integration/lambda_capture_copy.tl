(defstruct Pair
  (left i64)
  (right i64))

(define (named-one) : i64
  1)

(define (copy-scalar-pointer-function-and-aggregate [x : i64]) : bool
  (let
    [pair : Pair (Pair 40 2)]
    [raw : (Ptr i64) (ptr-null : (Ptr i64))]
    [raw-mut : (MutPtr i64) (ptr-null : (MutPtr i64))]
    [fn-value : (-> i64) named-one]
    [f : (-> i64)
      (lambda () : i64
        (if (ptr-null? raw)
          (if (ptr-null? raw-mut)
            (+ x (+ (struct-get pair left) (fn-value)))
            0)
          0))]
    [copy : (-> i64) f]
    (and (= (f) 42) (= (copy) 42))))

(define (read-copy-ref [_r : (& n i64)]) : i64
  1)

(define (copy-immutable-reference [x : i64]) : i64
  (let
    [r : (& x i64) (& x)]
    [f : (-> i64)
      (lambda () : i64
        (read-copy-ref r))]
    [copy : (-> i64) f]
    (+ (f) (copy))))

(define (copy-nested-closure [x : i64]) : bool
  (let
    [inner : (-> i64)
      (lambda () : i64
        (+ x 1))]
    [outer : (-> i64)
      (lambda () : i64
        (inner))]
    [copy : (-> i64) outer]
    (and (= (outer) (+ x 1)) (= (copy) (+ x 1)))))

(define (invoke [f : (-> i64)]) : i64
  (f))

(define (copy-through-ordinary-call [x : i64]) : bool
  (let
    [f : (-> i64)
      (lambda () : i64
        (+ x 1))]
    (and (= (invoke f) 42) (= (f) 42))))

(define (main) : i64
  (begin
    (unless (copy-scalar-pointer-function-and-aggregate 1) (return 1))
    (unless (= (copy-immutable-reference 42) 2) (return 2))
    (unless (copy-nested-closure 41) (return 3))
    (unless (copy-through-ordinary-call 41) (return 4))
    42))