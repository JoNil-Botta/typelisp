;; Specialization traverses resource children and keeps sequential scopes.
(define cleanup-total : i64
  0)

(define (drop-i64 [value : i64]) : unit
  (set! cleanup-total (+ cleanup-total value)))

(define (drop-fn [_value : (-> i64 i64)]) : unit
  unit)

(define (pick [comptime n : i64]) : i64
  n)

(define (substitute [comptime value-type : type] [comptime n : i64]) : i64
  (with
    ([value
        (let
          [typed : value-type n]
          typed)
        drop-i64])
    (+ value n)))

(define (value-shadow [comptime n : i64]) : i64
  (with ([n (+ n 1) drop-i64] [later (+ n 2) drop-i64]) (+ n later)))

(define (type-shadow [comptime value-type : type]) : i64
  (with
    ([value-type
        (let
          [typed : value-type 9]
          typed)
        drop-i64])
    (+ value-type 0)))

(define (template-shadow) : i64
  (let
    [inner : i64
      (with
        ([pick
            (begin
              (pick 0)
              (lambda ([x : i64]) : i64
                (+ x 100)))
            drop-fn]
          [later (pick 6) drop-i64])
        (+ later (pick 7)))]
    ;; The resource scope must not leak into a sibling expression.
    (+ inner (pick 11))))

(define (results-ok?
  [discovered : i64]
  [substituted : i64]
  [shadowed : i64]
  [type-shadowed : i64]
  [template-shadowed : i64]) : bool
  (and
    (= discovered 8)
    (= substituted 10)
    (= shadowed 10)
    (= type-shadowed 9)
    (= template-shadowed 224)
    (= cleanup-total 133)))

(define (main) : i64
  (let
    [discovered : i64 (with ([a (pick 3) drop-i64]) (+ a (pick 5)))]
    [substituted : i64 (substitute (type i64) 5)]
    [shadowed : i64 (value-shadow 3)]
    [type-shadowed : i64 (type-shadow (type i64))]
    [template-shadowed : i64 (template-shadow)]
    (if (results-ok?
      discovered
      substituted
      shadowed
      type-shadowed
      template-shadowed)
      42
      1)))