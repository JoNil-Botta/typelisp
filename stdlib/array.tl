;# Public dynamic/fixed array helper macros (#3421).
;#
;# This module owns the user-facing array helper spellings during the migration
;# away from compiler-public special forms and builtins. The branch compiler
;# enables these helpers by default and expands them to private compiler
;# intrinsics.
;#
;# Usage: `(import "stdlib/array.tl")`
(module stdlib.array)

(import stdlib.comptime)

;: Allocate a dynamic array with `count` live elements initialized under ZII.
;; lint-allow: unused-variable
(defmacro (make-array [T : type] [count : comptime.Expr]) : comptime.Expr
  `(__tl_make-array ,T ,count))

;: Return the current length of a dynamic array.
(defmacro (array-length [items : comptime.Expr]) : comptime.Expr
  `(__tl_array-length ,items))

;: Read a bounds-checked dynamic or fixed array element.
(defmacro (array-ref [items : comptime.Expr] [index : comptime.Expr]) : comptime.Expr
  `(__tl_array-ref ,items ,index))

;: Write a bounds-checked dynamic or fixed array element.
(defmacro (array-set!
  [items : comptime.Expr]
  [index : comptime.Expr]
  [value : comptime.Expr]) : comptime.Expr
  `(__tl_array-set! ,items ,index ,value))

;: Append a value to a dynamic array, growing storage when needed.
(defmacro (array-push! [items : comptime.Expr] [value : comptime.Expr]) : comptime.Expr
  `(__tl_array-push! ,items ,value))