;# Public dynamic/fixed array helper macros (#3421).
;#
;# This module owns the user-facing array helper spellings during the migration
;# away from compiler-public special forms and builtins. The macro declarations
;# are gated so older stage0 compilers skip them while building the branch
;# compiler; the branch compiler enables the gate by default and expands these
;# helpers to private compiler intrinsics.
;#
;# Usage: `(import "stdlib/array.tl")`
(module stdlib.array)

(cfg
  array-helper-intrinsics
  (defmacro (make-array [T : type] [count : Expr]) : Expr
    `(__tl_make-array ,T ,count)))

(cfg
  array-helper-intrinsics
  (defmacro (array-length [items : Expr]) : Expr
    `(__tl_array-length ,items)))

(cfg
  array-helper-intrinsics
  (defmacro (array-ref [items : Expr] [index : Expr]) : Expr
    `(__tl_array-ref ,items ,index)))

(cfg
  array-helper-intrinsics
  (defmacro (array-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
    `(__tl_array-set! ,items ,index ,value)))

(cfg
  array-helper-intrinsics
  (defmacro (array-push! [items : Expr] [value : Expr]) : Expr
    `(__tl_array-push! ,items ,value)))

(cfg array-helper-intrinsics (export (macro make-array)))

(cfg array-helper-intrinsics (export (macro array-length)))

(cfg array-helper-intrinsics (export (macro array-ref)))

(cfg array-helper-intrinsics (export (macro array-set!)))

(cfg array-helper-intrinsics (export (macro array-push!)))