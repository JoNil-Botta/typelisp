;; Inside `f`, the local `g : (-> (& b i64) (& a i64))` keeps `f`'s binder `a`
;; free, so it is not alpha-equivalent to `f` itself. Joining them must not
;; type `f` as `g` through `cond`: calling the join with a local would return a dead reference.
(define (spin) : never
  (spin))

(define (f [x : (& a i64)]) : (& a i64)
  (if (<= (deref x) 0)
    x
    (let
      [local : i64 0]
      [g : (-> (& b i64) (& a i64))
        (lambda ([y : (& b i64)]) : (& a i64)
          (spin))]
      [h (cond [(> (deref x) 100) f] [else g])]
      (h (& local)))))

(define (main) : i64
  0)