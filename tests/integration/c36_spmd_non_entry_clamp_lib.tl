(module c36_spmd_non_entry_clamp_lib)

(import stdlib.math)

(define (clamp-range!
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (math.f64-clamp (array-ref xs i) -3.0 3.0))))