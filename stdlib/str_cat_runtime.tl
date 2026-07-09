;# Test-bootstrap-safe String concatenation macro.
;#
;# Published stage0 compilers have a hardcoded fast path for `stdlib.str_cat`
;# while compiling `(test ...)` harnesses. This module intentionally uses a
;# different module name so internal selfhost tests run the checked-in macro
;# body below.
(import stdlib.comptime)
(import stdlib.array)
(import stdlib.string)

;: Internal pack step used by `str-cat` expansion for six or more operands.
;:
;: `carrier` wraps all operands in a marker call so each step reads the next
;: operand by index (`expr-list-nth`) instead of copying a shrinking tail;
;: `parts` threads the filled dynamic array and `idx` is the next literal slot.
;: When every slot is filled it returns `parts`.
(defmacro (str-cat-pack
  [carrier : comptime.Expr]
  [parts : (Array String)]
  [idx : comptime.Expr]) : (Array String)
  (match idx
    [(comptime.ExprInt i)
      (match carrier
        [(comptime.ExprCall _ elems)
          (if (>= i (comptime.expr-list-length elems))
            parts
            `(str-cat-pack
              ,carrier
              (stdlib.string.concat-all-pack-part
                ,parts
                ,(comptime.expr-int i)
                ,(comptime.expr-list-nth elems i))
              ,(comptime.expr-int (+ i 1))))]
        [_ parts])]
    [_ parts]))

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: Dispatches on the operand count and indexes operands directly with
;: `expr-list-nth`. With no operands it expands to `""`; with one operand it
;: expands to that operand unchanged. Two to five operands use direct
;: one-allocation helpers; six or more are packed into one dynamic parts array
;: and copied by `stdlib.string.concat-all`.
(defmacro (str-cat [args : String ...]) : String
  (match (comptime.expr-list-length args)
    [0 `""]
    [1 (comptime.expr-list-nth args 0)]
    [2
      `(stdlib.string.concat3
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        "")]
    [3
      `(stdlib.string.concat3
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        ,(comptime.expr-list-nth args 2))]
    [4
      `(stdlib.string.concat4
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        ,(comptime.expr-list-nth args 2)
        ,(comptime.expr-list-nth args 3))]
    [5
      `(stdlib.string.concat5
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        ,(comptime.expr-list-nth args 2)
        ,(comptime.expr-list-nth args 3)
        ,(comptime.expr-list-nth args 4))]
    [n
      `(stdlib.string.concat-all
        (str-cat-pack
          (__str-cat-args ,@args)
          (stdlib.array.make-array
            ,(comptime.expr-var "String")
            ,(comptime.expr-int n))
          0))]))