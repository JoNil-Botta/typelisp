(import stdlib.test)

(import stdlib.vector_slice)

(define (main) : unit
  (let
    [src : (Array i64) (make-array i64 3)]
    (begin
      (array-set! src 0 5)
      (array-set! src 1 6)
      (array-set! src 2 7)
      (let
        [fv : I64Vec (i64-vec-from-array src 3)]
        [full : (vector_slice.I64Slice fv) (vector_slice.i64-slice-all-vec fv (& fv))]
        [middle : (vector_slice.I64Slice fv) (vector_slice.i64-slice-from-vec fv (& fv) 1 2)]
        (begin
          (test.assert-i64-eq (vector_slice.i64-slice-len full) 3 "full slice len")
          (test.assert-i64-eq (vector_slice.i64-slice-len middle) 2 "middle slice len")
          (test.assert-false (vector_slice.i64-slice-is-empty? middle) "middle slice not empty")
          (test.assert-i64-eq (vector_slice.i64-slice-get middle 0 -1) 6 "middle slice first")
          (test.assert-i64-eq (vector_slice.i64-slice-get middle 1 -1) 7 "middle slice second")
          (test.assert-i64-eq
            (vector_slice.i64-slice-get middle 2 -1)
            -1
            "middle slice high fallback")
          (test.assert-i64-eq
            (vector_slice.i64-slice-get middle -1 -1)
            -1
            "middle slice negative fallback")
          (let
            [bad-start : (vector_slice.I64Slice fv) (vector_slice.i64-slice-from-vec fv (& fv) -1 1)]
            [bad-range : (vector_slice.I64Slice fv) (vector_slice.i64-slice-from-vec fv (& fv) 2 2)]
            (begin
              (test.assert-true
                (vector_slice.i64-slice-is-empty? bad-start)
                "slice negative start -> empty")
              (test.assert-true
                (vector_slice.i64-slice-is-empty? bad-range)
                "slice overrun -> empty")))
          (let
            [tail : (vector_slice.I64Slice fv) (vector_slice.i64-slice-sub-slice middle 1 1)]
            [bad-tail : (vector_slice.I64Slice fv) (vector_slice.i64-slice-sub-slice middle 1 2)]
            (begin
              (test.assert-i64-eq (vector_slice.i64-slice-get tail 0 -1) 7 "sub-slice value")
              (test.assert-true
                (vector_slice.i64-slice-is-empty? bad-tail)
                "sub-slice overrun -> empty")))
          (let
            [from-array : (vector_slice.I64Slice src)
              (vector_slice.i64-slice-from-array src (& src) 3 0 2)]
            [bad-count : (vector_slice.I64Slice src)
              (vector_slice.i64-slice-from-array src (& src) 4 0 1)]
            [bad-array-range : (vector_slice.I64Slice src)
              (vector_slice.i64-slice-from-array src (& src) 3 1 3)]
            (begin
              (test.assert-i64-eq
                (vector_slice.i64-slice-get from-array 1 -1)
                6
                "slice from array reads live prefix")
              (test.assert-true
                (vector_slice.i64-slice-is-empty? bad-count)
                "slice live count past array length -> empty")
              (test.assert-true
                (vector_slice.i64-slice-is-empty? bad-array-range)
                "slice array range past live count -> empty")))
          (let
            [slice-copy : (Array i64) (vector_slice.i64-slice-to-array middle)]
            [slice-vec : I64Vec (vector_slice.i64-slice-to-vec middle)]
            (begin
              (test.assert-i64-eq
                (array-length slice-copy)
                2
                "slice copy array length")
              (test.assert-i64-eq
                (array-ref slice-copy 0)
                6
                "slice copy array first")
              (array-set! slice-copy 0 0)
              (test.assert-i64-eq
                (vector_slice.i64-slice-get middle 0 -1)
                6
                "slice copy independent")
              (test.assert-i64-eq (i64-vec-len slice-vec) 2 "slice to vec len")
              (test.assert-i64-eq
                (i64-vec-get slice-vec 1 -1)
                7
                "slice to vec second"))))))))