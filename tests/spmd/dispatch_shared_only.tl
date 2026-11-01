(import dispatch_variant_support as support)

(define (fill! [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (program-count))))

(defdispatch fill-auto! (scalar fill!) (avx2 fill!) (avx512 fill!))

(define (main) : i64
  (let
    [out : (Array i64 19) (make-array i64 19)]
    [ok : bool true]
    (fill-auto! (slice-mut-view out 0 19) 19)
    (set!
      ok
      (support.all-equal? (slice-view out 0 19) (support.selected-width)))
    (fill-auto! (slice-mut-view out 0 19) 19)
    (if (and
      ok
      (support.all-equal? (slice-view out 0 19) (support.selected-width)))
      42
      1)))