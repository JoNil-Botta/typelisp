(extern (get-add) : (CFunc non-null (-> i64 i64 i64)) (:symbol "tl_certified_cfunc_add"))
(extern (get-sub) : (CFunc non-null (-> i64 i64 i64)) (:symbol "tl_certified_cfunc_sub"))
(extern (get-mix) : (CFunc non-null (-> i64 f32 i64 f32 f32)) (:symbol "tl_certified_cfunc_mix"))
(extern (get-sum9) : (CFunc
  non-null
  (-> i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)) (:symbol "tl_certified_cfunc_sum9"))

(define (relay [f : (CFunc non-null (-> i64 i64 i64))]) : (CFunc
    non-null
    (-> i64 i64 i64))
  f)

(define (factory [resolver : (-> (CFunc non-null (-> i64 i64 i64)))]) : (CFunc
    non-null
    (-> i64 i64 i64))
  (resolver))

(define (invoke
  [f : (CFunc non-null (-> i64 i64 i64))]
  [g : (CFunc non-null (-> i64 i64 i64))]
  [value : i64]) : i64
  (f
    value
    (begin
      (set! f g)
      (set! value 99)
      0)))

(define (looping [f : (CFunc non-null (-> i64 i64 i64))]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (while (< index 6)
      (set! total (f total 7))
      (set! index (+ index 1)))
    total))

(define (mixed [f : (CFunc non-null (-> i64 f32 i64 f32 f32))]) : f32
  (f 10 0.5 20 0.25))

(define (stacked
  [f : (CFunc non-null (-> i64 i64 i64 i64 i64 i64 i64 i64 i64 i64))]) : i64
  (f 1 2 3 4 5 6 7 8 9))

(define (main) : i64
  (let
    [add : (CFunc non-null (-> i64 i64 i64)) (factory get-add)]
    [sub : (CFunc non-null (-> i64 i64 i64)) (relay (get-sub))]
    (if (and
      (= (invoke add sub 42) 42)
      (= (looping add) 42)
      (=
        ((if true
            add
            sub)
          20
          22)
        42)
      (= ((relay add) 20 22) 42)
      (= (mixed (get-mix)) 30.75)
      (= (stacked (get-sum9)) 45))
      42
      1)))