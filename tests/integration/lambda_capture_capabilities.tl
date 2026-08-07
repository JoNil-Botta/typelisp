(import stdlib.string)

(defmacro (generated-bump-twice [body : unit]) : unit
  `(let
    [generated-bump : (-> unit)
      (lambda () : unit
        ,body)]
    (begin
      (generated-bump)
      (generated-bump))))

(define (mutable-capture-repeats-and-releases) : bool
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump : (-> unit)
      (lambda () : unit
        (array-set! exclusive 0 (+ (array-ref exclusive 0) 1)))]
    (begin
      (bump)
      (bump)
      (= (array-ref values 0) 42))))

(define (consuming-capture-calls-once) : bool
  (let
    [owned : String "captured"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [result : String (take)]
    (= (string.string-length result) 8)))

(define (read-only-owner-capture-repeats) : bool
  (let
    [owned : String "read"]
    [read : (-> i64)
      (lambda () : i64
        (string.string-length owned))]
    (and (= (read) 4) (= (read) 4))))

(define (consuming-capture-exclusive-branch [take-left : bool]) : bool
  (let
    [owned : String "branch"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [result : String
      (if take-left
        (take)
        (take))]
    (= (string.string-length result) 6)))

(define (immediate-mutable-capture) : bool
  (let
    [values : (Array i64 1) (array 41)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    (begin
      ((lambda () : unit
          (array-set! exclusive 0 (+ (array-ref exclusive 0) 1))))
      (= (array-ref values 0) 42))))

(define (immediate-consuming-capture) : bool
  (let
    [owned : String "immediate"]
    [result : String
      ((lambda () : String
          owned))]
    (= (string.string-length result) 9)))

(define (nested-mutable-capture) : bool
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump-twice : (-> unit)
      (lambda () : unit
        (let
          [bump : (-> unit)
            (lambda () : unit
              (array-set! exclusive 0 (+ (array-ref exclusive 0) 1)))]
          (begin
            (bump)
            (bump))))]
    (begin
      (bump-twice)
      (= (array-ref values 0) 42))))

(define (macro-generated-mutable-capture) : bool
  (let
    [values : (Array i64 1) (array 40)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    (begin
      (generated-bump-twice
        (array-set! exclusive 0 (+ (array-ref exclusive 0) 1)))
      (= (array-ref values 0) 42))))

(define (main) : i64
  (begin
    (unless (mutable-capture-repeats-and-releases) (return 1))
    (unless (consuming-capture-calls-once) (return 2))
    (unless (read-only-owner-capture-repeats) (return 3))
    (unless (immediate-mutable-capture) (return 4))
    (unless (immediate-consuming-capture) (return 5))
    (unless (nested-mutable-capture) (return 6))
    (unless (macro-generated-mutable-capture) (return 7))
    (unless (consuming-capture-exclusive-branch true) (return 8))
    (unless (consuming-capture-exclusive-branch false) (return 9))
    42))