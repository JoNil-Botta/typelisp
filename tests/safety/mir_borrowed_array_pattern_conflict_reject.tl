;; A borrowed fixed-array pattern binds a non-Copy element by reference into the
;; array: writing an element while that reference is still used conflicts with
;; its loan.
(defstruct Cell
  (n i64)
  (tag (Box i64)))

(define (main) : i64
  (let
    [items : (Array Cell 2) (array (Cell 40 (box 0)) (Cell 2 (box 0)))]
    [first : (& items Cell)
      (match (& items)
        [(array value _) value])]
    (begin
      (set! (array-ref items 1) (Cell 0 (box 0)))
      (+ (deref first).n 2))))