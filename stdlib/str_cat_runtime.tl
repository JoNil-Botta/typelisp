;# Test-bootstrap-safe String concatenation macro.
;#
;# Published stage0 compilers have a hardcoded fast path for `stdlib.str_cat`
;# while compiling `(test ...)` harnesses. This module intentionally uses a
;# different module name so internal selfhost tests run the checked-in macro
;# body below.
(import stdlib.comptime)
(import stdlib.string)

;: Compiler-private owner for the one backing allocation used by long calls.
(defstruct StrCatPack
  (parts (__tl_dyn-array String)))

;: Allocate the one backing buffer used to pack a long concatenation.
(define (str-cat-pack-new [count : i64]) : StrCatPack
  (StrCatPack (__tl_make-array String count)))

;: Store one String in a compiler-private pack.
(define (str-cat-pack-part!
  [pack : (&mut pack StrCatPack)]
  [index : i64]
  [value : String]) : unit
  (set! (array-ref pack.parts index) value))

;: Internal pack step used by `str-cat` expansion for six or more operands.
;:
;: `carrier` wraps all operands in a marker call so each step reads the next
;: operand by index (`expr-list-nth`) instead of copying a shrinking tail.
;: Emit a flat `begin` of in-place stores rather than a left-nested call chain;
;: this keeps typechecking and lowering stack-bounded for very long calls.
(defmacro (str-cat-pack
  [carrier : comptime.Expr]
  [pack : StrCatPack]
  [idx : comptime.Expr]) : comptime.Expr
  (match idx
    [(comptime.Expr.Int i)
      (match carrier
        [(comptime.Expr.Call _ elems)
          (let
            [index : i64 (comptime.expr-list-length elems)]
            [stores : comptime.ExprList (comptime.expr-list-empty)]
            (begin
              (while (> index i)
                (begin
                  (set! index (- index 1))
                  (set!
                    stores
                    (comptime.expr-list-cons
                      `(stdlib.str_cat_runtime.str-cat-pack-part!
                        (&mut __tl_str_cat_pack)
                        ,(comptime.expr-int index)
                        ,(comptime.expr-list-nth elems index))
                      stores))))
              `(let
                [__tl_str_cat_pack ,pack]
                (begin
                  ,@stores
                  __tl_str_cat_pack))))]
        [_ pack])]
    [_ pack]))

;: Bridge a completed domain pack into the public borrowed-Slice concat API.
;:
;: Keeping the Slice-view setup outside each macro expansion avoids multiplying
;: it across every long `str-cat` call site.
(define (str-cat-concat-packed [pack : StrCatPack]) : String
  (let
    [parts : (__tl_dyn-array String) pack.parts]
    (stdlib.string.concat-all (slice-view (& parts) 0 (array-length parts)))))

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
      `(stdlib.str_cat_runtime.str-cat-concat-packed
        (str-cat-pack
          (__str-cat-args ,@args)
          (stdlib.str_cat_runtime.str-cat-pack-new ,(comptime.expr-int n))
          0))]))

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
        (begin
          (if arg0-borrowable
            unit
            (set! all-borrowable false))
          (if arg1-borrowable
            unit
            (set! all-borrowable false))
          (if all-borrowable
            `(stdlib.string.concat3-borrowed ,arg0 ,arg1 "")
            `(stdlib.string.concat3 ,arg0 ,arg1 ""))))]
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
        (begin
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
            `(stdlib.string.concat3 ,arg0 ,arg1 ,arg2))))]
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
        (begin
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
            `(stdlib.string.concat4 ,arg0 ,arg1 ,arg2 ,arg3))))]
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
        (begin
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
            `(stdlib.string.concat5 ,arg0 ,arg1 ,arg2 ,arg3 ,arg4))))]
    [n
      `(stdlib.str_cat_runtime.str-cat-concat-packed
        (str-cat-pack
          (__str-cat-args ,@args)
          (stdlib.str_cat_runtime.str-cat-pack-new ,(comptime.expr-int n))
          0))]))