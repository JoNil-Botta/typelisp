;; Both the destination and replacement of replace! carry hygienic bindings.
;; Caller names must not capture the template's index or replacement value.
;; lint-allow: unused-import
(import stdlib.comptime)

(defmacro (replace-first [items : Expr]) : Expr
  `(let
    [index : i64 0]
    [replacement : i64 22]
    (replace! (array-ref ,items index) replacement)))

(defmacro (replace-first-box [items : Expr]) : Expr
  `(let
    [index : i64 0]
    [replacement : (Box i64) (box 2)]
    (replace! (array-ref ,items index) replacement)))

(defmacro (nested-replace [items : Expr]) : Expr
  `(replace-first ,items))

(define (main) : i64
  (let
    [index : i64 1]
    [replacement : i64 99]
    [items : (__tl_dyn-array i64) (__tl_make-array 20 7)]
    [fixed : (Array i64 2) (array 20 8)]
    [owned : (Array (Box i64) 1) (array (box 40))]
    [old : i64 (replace-first items)]
    [nested-old : i64 (nested-replace fixed)]
    [old-box : (Box i64) (replace-first-box owned)]
    (if (and
      (= (+ old (array-ref items 0)) 42)
      (= (array-ref items 1) 7)
      (= (+ nested-old (array-ref fixed 0)) 42)
      (= (array-ref fixed 1) 8)
      (= (+ (deref old-box) (deref (array-ref owned 0))) 42)
      (= index 1)
      (= replacement 99))
      42
      1)))