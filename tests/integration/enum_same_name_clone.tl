(import stdlib.clone)

(defenum Same
  (Same (__tl_dyn-array i64)))

(clone.gen-clone Same)

(define (main) : i64
  (let
    [source : Same (Same (__tl_make-array 42))]
    [copy : Same (clone-same (& source))]
    (match source
      [(Same items)
        (set! (array-ref items 0) 1)
        (match copy
          [(Same copied-items) (array-ref copied-items 0)])])))