;# Public dynamic/fixed array helper macros.
;#
;# This module owns the user-facing array helper spellings during the migration
;# away from compiler-public special forms and builtins. The branch compiler
;# enables these helpers by default and expands them to private compiler
;# intrinsics.
;#
;# Usage: `(import "stdlib/array.tl")`
(import stdlib.comptime)

;: Allocate a dynamic array with `count` live elements initialized under ZII.
;; lint-allow: unused-variable
(defmacro (make-array [T : type] [count : comptime.Expr]) : comptime.Expr
  `(__tl_make-array ,T ,count))

;: Return the current length of a dynamic array.
(defmacro (length [items : comptime.Expr]) : comptime.Expr
  `(__tl_array-length ,items))

;: Read a bounds-checked dynamic or fixed array element.
(defmacro (ref [items : comptime.Expr] [index : comptime.Expr]) : comptime.Expr
  `(__tl_array-ref ,items ,index))

;: Write a bounds-checked dynamic or fixed array element.
;:
;: The compiler fast path recognizes the short base for future qualified use,
;: but exporting a macro named `set!` makes the bootstrap compiler resolve the
;: language `set!` form as an imported array macro in larger import graphs.
;: Append a value to a dynamic array, growing storage when needed.
(defmacro (push! [items : comptime.Expr] [value : comptime.Expr]) : comptime.Expr
  `(__tl_array-push! ,items ,value))