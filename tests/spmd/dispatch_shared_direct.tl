(import dispatch_variant_support as support)

(define (fill! [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (program-count))))

(defdispatch fill-auto! (scalar fill!) (avx2 fill!) (avx512 fill!))

(define (apply-fill!
  [f : (-> (&mut (Slice i64)) i64 unit)]
  [out : (&mut (Slice i64))]
  [n : i64]) : unit
  (f out n))

(define (main) : i64
  (let
    [out : (Array i64 19) (make-array i64 19)]
    [ok : bool true]
    (fill-auto! (slice-mut-view out 0 19) 19)
    (set!
      ok
      (support.all-equal? (slice-view out 0 19) (support.selected-width)))
    (fill! (slice-mut-view out 0 19) 19)
    (let
      [width : i64 (array-ref out 0)]
      (set! ok (and ok (support.all-equal? (slice-view out 0 19) width)))
      (apply-fill! fill! (slice-mut-view out 0 19) 19)
      (set! ok (and ok (support.all-equal? (slice-view out 0 19) width)))
      (fill-auto! (slice-mut-view out 0 19) 19)
      (set!
        ok
        (and
          ok
          (support.all-equal? (slice-view out 0 19) (support.selected-width))))
      (if ok
        (+ 42 width)
        1))))