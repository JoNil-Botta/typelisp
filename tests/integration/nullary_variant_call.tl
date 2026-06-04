;; refs #41, GAP (D): the zero-arg call form `(Ctor)` constructs a NULLARY enum
;; variant, equivalent to bare `Ctor` and consistent with payload construction
;; `(RGB v)`. This program exercises all three construction forms at runtime and
;; proves the disambiguation rule: a genuine zero-arg `define`d function `(bias)`
;; still CALLS the function (it is bound as a function type, not an enum type),
;; while `(Red)` / `(Green)` construct their nullary variants.
(import "stdlib/io.tl")

(defenum Color
  (Red)
  (Green)
  (RGB i64))

;; Classify a Color to an i64. The arms match nullary variants `(Red)`/`(Green)`
;; and the payload variant `(RGB v)`.
(define (code [c : Color]) : i64
  (match c
    [(Red) 1]
    [(Green) 2]
    [(RGB v) v]))

;; A real zero-arg function — NOT an enum variant. `(bias)` must dispatch to this
;; function (returns 30), proving the nullary-variant call form does not shadow
;; ordinary zero-arg function calls.
(define (bias) : i64
  30)

(define (main)
  :
  i64
  ;; (Red)   -> nullary variant via call form           -> code = 1
  ;; (Green) -> nullary variant via call form           -> code = 2
  ;; (RGB 9) -> payload variant                          -> code = 9
  ;; (bias)  -> zero-arg FUNCTION call                   -> 30
  ;; total = 1 + 2 + 9 + 30 = 42
  (+ (+ (code (Red)) (code (Green))) (+ (code (RGB 9)) (bias))))