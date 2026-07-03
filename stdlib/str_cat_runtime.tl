;# Test-bootstrap-safe String concatenation macro.
;#
;# Published stage0 compilers have a hardcoded fast path for `stdlib.str_cat`
;# that still emits the legacy `stdlib.string/string-concat*` helper names while
;# compiling `(test ...)` harnesses. This module intentionally uses a different
;# module name so internal selfhost tests run the checked-in macro body below.
(module stdlib.str_cat_runtime)

(import stdlib.comptime)
(import stdlib.array)
(import stdlib.string)

;: Internal recursive pack step used by `str-cat` expansion.
(defmacro (pack [parts : (Array String)] [index : i64] [args : String ...]) : (Array
    String)
  (if (comptime.expr-list-empty? args)
    parts
    `(pack
      (stdlib.string.concat-all-pack-part
        ,parts
        ,index
        ,(comptime.expr-list-head args))
      (+ ,index 1)
      ,@(comptime.expr-list-tail args))))

;: Concatenate any number of `String` operands into a fresh active-arena String.
(defmacro (str-cat [args : String ...]) : String
  (if (comptime.expr-list-empty? args)
    `""
    (let
      [a : comptime.Expr (comptime.expr-list-head args)]
      [rest1 : comptime.ExprList (comptime.expr-list-tail args)]
      (if (comptime.expr-list-empty? rest1)
        a
        (let
          [b : comptime.Expr (comptime.expr-list-head rest1)]
          [rest2 : comptime.ExprList (comptime.expr-list-tail rest1)]
          (if (comptime.expr-list-empty? rest2)
            `(stdlib.string.concat3 ,a ,b "")
            (let
              [c : comptime.Expr (comptime.expr-list-head rest2)]
              [rest3 : comptime.ExprList (comptime.expr-list-tail rest2)]
              (if (comptime.expr-list-empty? rest3)
                `(stdlib.string.concat3 ,a ,b ,c)
                (let
                  [d : comptime.Expr (comptime.expr-list-head rest3)]
                  [rest4 : comptime.ExprList (comptime.expr-list-tail rest3)]
                  (if (comptime.expr-list-empty? rest4)
                    `(stdlib.string.concat4 ,a ,b ,c ,d)
                    (let
                      [e : comptime.Expr (comptime.expr-list-head rest4)]
                      [rest5 : comptime.ExprList
                        (comptime.expr-list-tail rest4)]
                      (if (comptime.expr-list-empty? rest5)
                        `(stdlib.string.concat5 ,a ,b ,c ,d ,e)
                        (let
                          [string-type : comptime.Expr
                            (comptime.expr-var "String")]
                          [count : comptime.Expr
                            (comptime.expr-int (comptime.expr-list-length args))]
                          `(stdlib.string.concat-all
                            (pack
                              (stdlib.array.make-array ,string-type ,count)
                              0
                              ,@args)))))))))))))))