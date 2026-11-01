(import dispatch_variant_support as support)

(define (fill-scalar! [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (program-count))))

(define (fill-avx2! [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (program-count))))

(define (fill-avx512! [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (program-count))))

(defdispatch
  fill-auto!
  (scalar fill-scalar!)
  (avx2 fill-avx2!)
  (avx512 fill-avx512!))

(define (main) : i64
  (let
    [out : (Array i64 19) (make-array i64 19)]
    [ok : bool true]
    (fill-auto! (slice-mut-view out 0 19) 19)
    (set!
      ok
      (support.all-equal? (slice-view out 0 19) (support.selected-width)))
    (fill-scalar! (slice-mut-view out 0 19) 19)
    (let
      [width : i64 (array-ref out 0)]
      (set! ok (and ok (support.all-equal? (slice-view out 0 19) width)))
      (fill-avx2! (slice-mut-view out 0 19) 19)
      (set! ok (and ok (support.all-equal? (slice-view out 0 19) width)))
      (fill-avx512! (slice-mut-view out 0 19) 19)
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