;# Test-bootstrap-safe String concatenation macro.
;#
;# Published stage0 compilers have a hardcoded fast path for `stdlib.str_cat`
;# while compiling `(test ...)` harnesses. This module intentionally uses a
;# different module name so internal selfhost tests run the checked-in macro
;# body below.
(import stdlib.comptime)
(import stdlib.string)

;: Internal long-call step used by the `str-cat` expansion for six or more
;: operands.
;:
;: `carrier` wraps all operands in a marker call so each step reads the next
;: operand by index (`expr-list-nth`) instead of copying a shrinking tail.
;: `count` is the operand count and `index` is the first index to keep. The
;: body copies the operand references into a fresh list and emits one
;: `stdlib.string.concat-all` call over one borrowed fixed array of the
;: operands, so each part is one stack store instead of a heap pack store.
(defmacro (str-cat-pack
  [carrier : comptime.Expr]
  [count : comptime.Expr]
  [index : comptime.Expr]) : comptime.Expr
  (match index
    [(comptime.Expr.Int stop)
      (match count
        [(comptime.Expr.Int n)
          (match carrier
            [(comptime.Expr.Call _ elems)
              (let
                [cursor : i64 n]
                [parts : comptime.ExprList (comptime.expr-list-empty)]
                (while (> cursor stop)
                  (set! cursor (- cursor 1))
                  (set!
                    parts
                    (comptime.expr-list-cons
                      (comptime.expr-list-nth elems cursor)
                      parts)))
                `(stdlib.string.concat-all (& (array ,@parts))))]
            [_ carrier])]
        [_ carrier])]
    [_ carrier]))

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: Dispatches on the operand count and indexes operands directly with
;: `expr-list-nth`. With no operands it expands to `""`; with one operand it
;: expands to that operand unchanged. Two to five operands use direct
;: one-allocation helpers; six or more become one borrowed fixed array of the
;: operands and are copied by `stdlib.string.concat-all`.
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
    [n `(str-cat-pack (__str-cat-args ,@args) ,(comptime.expr-int n) 0)]))

;: Concatenate operands while accepting fixed-arity scoped-region variables.
;:
;: Fixed arities capture raw expressions so syntax inspection retains literal
;: provenance. Calls made only from literals and variables use borrowed helpers,
;: allowing current-region variables. Any other operand keeps the legacy
;: owned-helper expansion so rvalue and conditional callers retain their
;: existing temporary-lifetime behavior.
(defmacro (str-cat-scoped [args : comptime.Expr ...]) : String
  (match (comptime.expr-list-length args)
    [0 `""]
    [1 (comptime.expr-list-nth args 0)]
    [2
      (let
        [arg0 : comptime.Expr (comptime.expr-list-nth args 0)]
        [arg1 : comptime.Expr (comptime.expr-list-nth args 1)]
        [arg0-borrowable : bool
          (if (comptime.expr-string? arg0)
            true
            (match arg0
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg1-borrowable : bool
          (if (comptime.expr-string? arg1)
            true
            (match arg1
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [all-borrowable : bool true]
        (if arg0-borrowable
          unit
          (set! all-borrowable false))
        (if arg1-borrowable
          unit
          (set! all-borrowable false))
        (if all-borrowable
          `(stdlib.string.concat3-borrowed ,arg0 ,arg1 "")
          `(stdlib.string.concat3 ,arg0 ,arg1 "")))]
    [3
      (let
        [arg0 : comptime.Expr (comptime.expr-list-nth args 0)]
        [arg1 : comptime.Expr (comptime.expr-list-nth args 1)]
        [arg2 : comptime.Expr (comptime.expr-list-nth args 2)]
        [arg0-borrowable : bool
          (if (comptime.expr-string? arg0)
            true
            (match arg0
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg1-borrowable : bool
          (if (comptime.expr-string? arg1)
            true
            (match arg1
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg2-borrowable : bool
          (if (comptime.expr-string? arg2)
            true
            (match arg2
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [all-borrowable : bool true]
        (if arg0-borrowable
          unit
          (set! all-borrowable false))
        (if arg1-borrowable
          unit
          (set! all-borrowable false))
        (if arg2-borrowable
          unit
          (set! all-borrowable false))
        (if all-borrowable
          `(stdlib.string.concat3-borrowed ,arg0 ,arg1 ,arg2)
          `(stdlib.string.concat3 ,arg0 ,arg1 ,arg2)))]
    [4
      (let
        [arg0 : comptime.Expr (comptime.expr-list-nth args 0)]
        [arg1 : comptime.Expr (comptime.expr-list-nth args 1)]
        [arg2 : comptime.Expr (comptime.expr-list-nth args 2)]
        [arg3 : comptime.Expr (comptime.expr-list-nth args 3)]
        [arg0-borrowable : bool
          (if (comptime.expr-string? arg0)
            true
            (match arg0
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg1-borrowable : bool
          (if (comptime.expr-string? arg1)
            true
            (match arg1
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg2-borrowable : bool
          (if (comptime.expr-string? arg2)
            true
            (match arg2
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg3-borrowable : bool
          (if (comptime.expr-string? arg3)
            true
            (match arg3
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [all-borrowable : bool true]
        (if arg0-borrowable
          unit
          (set! all-borrowable false))
        (if arg1-borrowable
          unit
          (set! all-borrowable false))
        (if arg2-borrowable
          unit
          (set! all-borrowable false))
        (if arg3-borrowable
          unit
          (set! all-borrowable false))
        (if all-borrowable
          `(stdlib.string.concat4-borrowed ,arg0 ,arg1 ,arg2 ,arg3)
          `(stdlib.string.concat4 ,arg0 ,arg1 ,arg2 ,arg3)))]
    [5
      (let
        [arg0 : comptime.Expr (comptime.expr-list-nth args 0)]
        [arg1 : comptime.Expr (comptime.expr-list-nth args 1)]
        [arg2 : comptime.Expr (comptime.expr-list-nth args 2)]
        [arg3 : comptime.Expr (comptime.expr-list-nth args 3)]
        [arg4 : comptime.Expr (comptime.expr-list-nth args 4)]
        [arg0-borrowable : bool
          (if (comptime.expr-string? arg0)
            true
            (match arg0
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg1-borrowable : bool
          (if (comptime.expr-string? arg1)
            true
            (match arg1
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg2-borrowable : bool
          (if (comptime.expr-string? arg2)
            true
            (match arg2
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg3-borrowable : bool
          (if (comptime.expr-string? arg3)
            true
            (match arg3
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [arg4-borrowable : bool
          (if (comptime.expr-string? arg4)
            true
            (match arg4
              [(comptime.Expr.Var _) true]
              [_ false]))]
        [all-borrowable : bool true]
        (if arg0-borrowable
          unit
          (set! all-borrowable false))
        (if arg1-borrowable
          unit
          (set! all-borrowable false))
        (if arg2-borrowable
          unit
          (set! all-borrowable false))
        (if arg3-borrowable
          unit
          (set! all-borrowable false))
        (if arg4-borrowable
          unit
          (set! all-borrowable false))
        (if all-borrowable
          `(stdlib.string.concat5-borrowed ,arg0 ,arg1 ,arg2 ,arg3 ,arg4)
          `(stdlib.string.concat5 ,arg0 ,arg1 ,arg2 ,arg3 ,arg4)))]
    [n `(str-cat-pack (__str-cat-args ,@args) ,(comptime.expr-int n) 0)]))