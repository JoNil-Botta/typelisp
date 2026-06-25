;: SPEC SPMD contract: varying match scrutinees must stay in supported lane value types.
(define (main [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (match (if (= (% i 2) 0)
        "even"
        "odd")
        ["even" 1]
        [_ 0]))))