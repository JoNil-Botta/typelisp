;; refs #2295: `f32` is a legal field type in a `(:repr c)` struct. The struct
;; type-checks, compiles, and projects its single-precision fields back to the
;; constructed values through C-layout (size 4 / align 4) field offsets.
;; Comparisons are between f32 *values* (fields and their arithmetic results)
;; rather than against bare float literals, so the test isolates repr-c f32
;; field layout/storage/projection. `main` returns 42 only when the f32 fields
;; read back correctly.
(defstruct Rect
  (:repr c)
  (w f32)
  (h f32))

(define (main) : i64
  (let
    [r : Rect (Rect 3.0 4.0)]
    [w : f32 (struct-get r w)]
    [h : f32 (struct-get r h)]
    [sum : f32 (+ w h)]
    [prod : f32 (* w h)]
    ;; w (3) < h (4) -> 20
    [a : i64
      (if (< w h)
        20
        0)]
    ;; sum (7) < prod (12) -> 22
    [b : i64
      (if (< sum prod)
        22
        0)]
    (+ a b)))