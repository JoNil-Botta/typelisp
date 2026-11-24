(defstruct FnBox
  (f (-> i64 i64)))

(define (clone-fn-box [x : (& r FnBox)]) : FnBox
  (FnBox x.f))

(define (main) : i64
  (let
    [arr : (Array FnBox 1)
      (with-scratch
        (let
          [x : i64 42]
          (array
            (FnBox
              (lambda ([y : i64]) : i64
                (+ x y))))))]
    ((. (array-ref arr 0) f) 1)))