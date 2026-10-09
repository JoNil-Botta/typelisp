;; Specialization scopes the owned `for` binders and the `foreach-active` lane
;; like every other binder (#8704). Each shadows the comptime parameter of the
;; same name in its body, a type parameter as much as a value parameter, and
;; the parameter is visible again after the loop. A missed scope shows up as a
;; substituted literal binder, a type-valued runtime use, or a wrong sum.
;; The owned loop's item binder shadows a value parameter: 1 + 2 + 3, then 5.
(define (owned-value-shadow [comptime n : i64]) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    [total : i64 0]
    (for [n items]
      (set! total (+ total n)))
    (+ total n)))

;; The item binder shadows a type parameter: 1 + 2 + 3, then `(cast 1 : T)`.
(define (owned-type-shadow [comptime T : type]) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    [total : i64 0]
    (for [T items]
      (set! total (+ total T)))
    (+ total (cast 1 : T))))

;; A typed binder shadows the value parameter `n` too: 10 + 20, then 3.
(define (owned-typed-shadow [comptime n : i64]) : i64
  (let
    [items : (Array i64 2) (array 10 20)]
    [total : i64 0]
    (for [n : i64 items]
      (set! total (+ total n)))
    (+ total n)))

;; A lane named like a type parameter: (0 + 0) + (1 + 0) + (2 + 0) + (3 + 0),
;; then `(cast 1 : T)` after the loop.
(define (lane-type-shadow [comptime T : type]) : i64
  (let
    [out : (Array i64 4) (make-array i64 4)]
    (foreach
      ([i : i64 0 4])
      (foreach-active
        ;; lint-allow: local-name-case -- the lane must shadow the type parameter
        [T : i64]
        (let
          [k : i64 (lane-value i)]
          (set! (array-ref out k) (+ k T)))))
    (+ (spmd-reduce sum ([i : i64 0 4]) 0 (array-ref out i)) (cast 1 : T))))

;; The same with a value parameter, which the lane already shadowed: 6, then 9.
(define (lane-value-shadow [comptime m : i64]) : i64
  (let
    [out : (Array i64 4) (make-array i64 4)]
    (foreach
      ([i : i64 0 4])
      (foreach-active
        [m : i64]
        (let
          [k : i64 (lane-value i)]
          (set! (array-ref out k) (+ k m)))))
    (+ (spmd-reduce sum ([i : i64 0 4]) 0 (array-ref out i)) m)))

(define (main) : i64
  (if (and
    (= (owned-value-shadow 5) 11)
    (= (owned-type-shadow (type i64)) 7)
    (= (owned-typed-shadow 3) 33)
    (= (lane-type-shadow (type i64)) 7)
    (= (lane-value-shadow 9) 15))
    42
    1))