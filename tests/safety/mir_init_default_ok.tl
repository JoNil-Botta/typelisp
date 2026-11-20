;; `(init : T)` is a fresh default value: its fields are assigned in place.
(defstruct InitPair
  (left i64)
  (right i64))

(define (main) : i64
  (let
    ;; lint-allow: removed-init -- This test is about init's fresh default value.
    [pair : InitPair (init : InitPair)]
    (begin
      (set! pair.left 40)
      (set! pair.right 2)
      (+ pair.left pair.right))))