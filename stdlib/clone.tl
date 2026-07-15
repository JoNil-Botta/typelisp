;# Declaration-macro support for compiler-checked `(clone value)` roots.
;#
;# The compiler owns cloneability, reachable-root discovery, arena semantics,
;# and diagnostics. This module owns the staged declaration producer used by
;# the typed handoff. The first handoff deliberately covers one-field named
;# structs; broader aggregate shapes remain on the compatibility producer.
(import stdlib.comptime)

;: Emit the `clone$Type` helper for a reachable one-field named struct.
(defmacro (synthesize-one-field-struct [T : type] [helper-name : Expr]) : Decls
  (match (type-kind T)
    ["struct"
      (if (!= (struct-field-count T) 1)
        (comptime.comptime-error
          (comptime.string-append
            "clone: stdlib handoff expected a one-field struct, got "
            (type-key T)))
        (let
          [type-name : String (type-nominal-name T)]
          [type-ctor : comptime.Expr (comptime.expr-var type-name)]
          [field-access : comptime.Expr
            (comptime.expr-struct-get
              (comptime.expr-var "value")
              (struct-field-name T 0))]
          `(begin
            (define (,helper-name [value : ,T]) : ,T
              (,type-ctor (clone ,field-access))))))]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "clone: stdlib handoff expected a struct, got "
          (type-key T)))]))