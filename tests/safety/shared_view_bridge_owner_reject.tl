;; A generated call cannot manufacture a second cleanup-owning handle.
(defstruct Owned
  (:cleanup cleanup-owned)
  (value (Box i64) (:cleanup cleanup-box)))

(define (cleanup-box [_value : (Box i64)]) : unit
  unit)

(defmacro (copy-child [value : Expr]) : Expr
  `(__tl-compiler-owned-shared-view-dyn-ref-as ,value Owned))

(define (main) : i64
  (with
    ([child (Owned (box 0)) cleanup-owned])
    (let
      [copied : Owned (copy-child (& child))]
      42)))
