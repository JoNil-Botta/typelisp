(defstruct FnBox
  (f (-> i64 i64)))

(define (clone-fn-box [x : (& r FnBox)]) : FnBox
  (FnBox x.f))

(define (main) : i64
  (let
    [b : (Box FnBox)
      (with-scratch
        (let
          [x : i64 42]
          (box
            (FnBox
              (lambda ([y : i64]) : i64
                (+ x y))))))]
    ((. (deref b) f) 1)))