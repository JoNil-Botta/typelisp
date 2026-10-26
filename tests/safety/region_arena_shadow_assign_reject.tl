;; A nested `with-arena` spelled like the outer one shadows it: a borrow of
;; the inner arena's data assigned to a binding of the outer region outlives
;; the inner arena. The ownership graph erases arena regions, so typing's
;; assignment check decides it by the region's name (#8890).
(import stdlib.string)

(define (main) : i64
  (with-arena
    outer
    (let
      [keep : String (string.append "a" "b")]
      [r : (& outer str) (& keep)]
      (with-arena
        outer
        (let
          [inner : String (string.append "c" "d")]
          ; Must fail: the inner arena resets before `r` is read.
          (set! r (& inner))))
      (string.string-length r))))