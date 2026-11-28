(define (counted-zero [calls : (&mut calls i64)]) : i64
  (set! (deref calls) (+ (deref calls) 1))
  0)

(define (main) : i64
  (let
    [calls : i64 0]
    [literal : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [computed : (__tl_dyn-array i64)
      (__tl_make-array i64 (counted-zero (&mut calls)))]
    [explicit : (__tl_dyn-array i64) (__tl_make-array)]
    [empty-ok : bool
      (and
        (= (length literal) 0)
        (= (length computed) 0)
        (= (length explicit) 0)
        (unsafe
          (and
            (= (ptr->int (__tl_array-data literal)) (cast 0 : u64))
            (= (ptr->int (__tl_array-data explicit)) (cast 0 : u64)))))]
    (__tl_array-push! computed 42)
    (if (and
      empty-ok
      (= calls 1)
      (= (length computed) 1)
      (= (array-ref computed 0) 42))
      0
      1)))