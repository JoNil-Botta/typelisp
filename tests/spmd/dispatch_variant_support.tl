(import stdlib.cpu)
(import stdlib.iterator)

(define (selected-width) : i64
  (if (cpu.runs-avx512?)
    8
    (if (cpu.runs-avx2?)
      4
      1)))

(define (all-equal? [out : (& (Slice i64))] [expected : i64]) : bool
  (let
    [ok : bool true]
    (for [i (iterator.range 0 (array-length out))]
      (set! ok (and ok (= (array-ref out i) expected))))
    ok))