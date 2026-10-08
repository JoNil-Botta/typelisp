(define (main [xs : (& xs (Array i64 4))]) : i64
  (let [total : i64 0]
    (begin (for [x xs] (+= total (deref x)))
      (for [i (iterator.range 0 2)] [x xs] (for [y xs] (-= total (deref y))))
      (if (all? [x xs] (> (deref x) 0)) total (if (any? [x xs] (= (deref x) 0)) 0 1)))))