;; Postfix field projection composes with every non-dotted public place form.
(defstruct Inner
  (value i64))

(defstruct Outer
  (inner Inner))

(defstruct OwnedInner
  (cell (Box i64)))

(defstruct OwnedOuter
  (inner OwnedInner))

(define (main) : i64
  (let
    [items : (Array Outer 1) (array (Outer (Inner 0)))]
    [pair : (Tuple Outer i64) (tuple (Outer (Inner 0)) 0)]
    [boxed : (Box Outer) (box (Outer (Inner 0)))]
    [owned-pair : (Tuple OwnedOuter i64)
      (tuple (OwnedOuter (OwnedInner (box 19))) 0)]
    (begin
      (set! (array-ref items 0).inner.value 10)
      (set! (tuple-ref pair 0).inner.value 14)
      (set! (deref boxed).inner.value 18)
      (let
        [array-value : (& items i64) (& (array-ref items 0).inner.value)]
        [tuple-value : (&mut pair i64) (&mut (tuple-ref pair 0).inner.value)]
        [boxed-value : (& boxed i64) (& (deref boxed).inner.value)]
        [moved-cell : (Box i64) (tuple-ref owned-pair 0).inner.cell]
        (begin
          (set! (deref tuple-value) 15)
          (set! (tuple-ref owned-pair 0).inner.cell (box 20))
          (if (=
            (+
              (deref array-value)
              (+
                (deref tuple-value)
                (+
                  (deref boxed-value)
                  (+
                    (deref moved-cell)
                    (deref (tuple-ref owned-pair 0).inner.cell)))))
            82)
            42
            1))))))