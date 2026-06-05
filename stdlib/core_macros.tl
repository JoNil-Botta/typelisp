;# Core expression macros for explicit stdlib import.
;#
;# This module is not an automatic prelude. Import it explicitly and call the
;# exported macros through the import alias while the built-in unqualified guard
;# forms remain in place.
;#
;# Usage: `(import "stdlib/core_macros.tl" module stdlib.core-macros as core)`
;#
;# ```typelisp
;# (import "stdlib/core_macros.tl" module stdlib.core-macros as core)
;#
;# (define (main) : i64
;#   (let
;#     [value : i64 0]
;#     (begin
;#       (core/when true (set! value 21))
;#       (core/unless false (set! value (+ value 21)))
;#       value)))
;# ```
(module stdlib.core-macros)

;: Evaluate `body` only when `condition` is true.
;:
;: `body` must be a unit-valued expression. Use an explicit `begin` when more
;: than one expression should run in the guarded branch.
(defmacro
  (when [condition : bool] [body : unit])
  :
  unit
  `(if ,condition
    ,body
    unit))

;: Evaluate `body` only when `condition` is false.
;:
;: `body` must be a unit-valued expression. Use an explicit `begin` when more
;: than one expression should run in the guarded branch.
(defmacro
  (unless [condition : bool] [body : unit])
  :
  unit
  `(if ,condition
    unit
    ,body))

(export (macro when))

(export (macro unless))