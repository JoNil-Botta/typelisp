(defstruct FnBox
  (f (-> i64 i64)))

(define (main) : i64
  (let
    [cb : FnBox
      (with-scratch
        (let
          [x : i64 42]
          (FnBox
            (lambda ([y : i64]) : i64
              (+ x y)))))]
    ((. cb f) 1)))