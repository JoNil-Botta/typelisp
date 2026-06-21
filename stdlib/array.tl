;# Public dynamic/fixed array helper macros (#3421).
;#
;# This module owns the user-facing array helper spellings during the migration
;# away from compiler-public special forms and builtins. Macro exports are gated
;# so older stage0 compilers skip the public surface while building the branch
;# compiler; the branch compiler enables the gate by default and expands these
;# helpers to private compiler intrinsics.
;#
;# Usage: `(import "stdlib/array.tl")`
(module stdlib.array)

;: Allocate a dynamic array with `count` live elements initialized under ZII.
;; lint-allow: unused-variable
(defmacro (make-array [T : type] [count : Expr]) : Expr
  `(__tl_make-array ,T ,count))

;: Return the current length of a dynamic array.
(defmacro (array-length [items : Expr]) : Expr
  `(__tl_array-length ,items))

;: Read a bounds-checked dynamic or fixed array element.
(defmacro (array-ref [items : Expr] [index : Expr]) : Expr
  `(__tl_array-ref ,items ,index))

;: Write a bounds-checked dynamic or fixed array element.
(defmacro (array-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(__tl_array-set! ,items ,index ,value))

;: Append a value to a dynamic array, growing storage when needed.
(defmacro (array-push! [items : Expr] [value : Expr]) : Expr
  `(__tl_array-push! ,items ,value))

(cfg array-helper-intrinsics (export (macro make-array)))

(cfg array-helper-intrinsics (export (macro array-length)))

(cfg array-helper-intrinsics (export (macro array-ref)))

(cfg array-helper-intrinsics (export (macro array-set!)))

(cfg array-helper-intrinsics (export (macro array-push!)))