;; The nested reference binding cannot export its Box view as owned (p19).
(defstruct Holder
  (b (Box i64)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42))]
    [b : (Box i64)
      (let
        [r : (& holder Holder) (& holder)]
        r.b)]
    (deref b)))