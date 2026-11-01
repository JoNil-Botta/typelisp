;; Operands a macro splices into its template keep the caller's file, through
;; a nested expansion as well: the error in this file's operand is reported
;; here.
(import macro_nested_frame_dep as dep)

(define (main) : i64
  (let
    [x : i64 42]
    (dep.outer-pass (ptr->int (ptr-addr-of x)))))