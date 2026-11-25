(import c36_spmd_non_entry_clamp_lib as clamp_lib)

(define (main) : i64
  (let
    [n : i64 13]
    [xs : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (while (< i n)
      (set! (array-ref xs i) (cast (- i 6) : f64))
      (set! i (+ i 1)))
    (clamp_lib.clamp-range! (& xs) (&mut out) n)
    (set! i 0)
    (while (< i n)
      (let
        [x : f64 (array-ref xs i)]
        [expected : f64
          (if (< x -3.0)
            -3.0
            (if (> x 3.0)
              3.0
              x))]
        (set! ok (and ok (= (array-ref out i) expected)))
        (set! i (+ i 1))))
    (if ok
      42
      1)))