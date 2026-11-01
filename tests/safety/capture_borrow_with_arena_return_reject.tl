;; A capture borrowed inside a lambda called within `with-arena`, returned out of
;; the form; main pointed at the rewound arena (#9297).
(define (main) : i64
  (let
    [x : i64 42]
    [r : (& x i64)
      (with-arena
        tmp
        ; Must fail: `(& x)` borrows the lambda's copy of `x`.
        (let
          [f
            (lambda () : (& x i64)
              (& x))]
          (f)))]
    [junk : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    (set! (array-ref junk 0) 7)
    (deref r)))