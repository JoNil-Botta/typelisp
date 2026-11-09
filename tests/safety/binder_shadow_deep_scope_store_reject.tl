;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). The binder is below more than 32 local
;; binds, past the environment cache windows.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      [v0 : i64 0]
      [v1 : i64 1]
      [v2 : i64 2]
      [v3 : i64 3]
      [v4 : i64 4]
      [v5 : i64 5]
      [v6 : i64 6]
      [v7 : i64 7]
      [v8 : i64 8]
      [v9 : i64 9]
      [v10 : i64 10]
      [v11 : i64 11]
      [v12 : i64 12]
      [v13 : i64 13]
      [v14 : i64 14]
      [v15 : i64 15]
      [v16 : i64 16]
      [v17 : i64 17]
      [v18 : i64 18]
      [v19 : i64 19]
      [v20 : i64 20]
      [v21 : i64 21]
      [v22 : i64 22]
      [v23 : i64 23]
      [v24 : i64 24]
      [v25 : i64 25]
      [v26 : i64 26]
      [v27 : i64 27]
      [v28 : i64 28]
      [v29 : i64 29]
      [v30 : i64 30]
      [v31 : i64 31]
      [v32 : i64 32]
      [v33 : i64 33]
      [v34 : i64 34]
      [v35 : i64 35]
      [v36 : i64 36]
      [v37 : i64 37]
      [v38 : i64 38]
      [v39 : i64 39]
      (set! b.value local))))

(define (main) : i64
  0)