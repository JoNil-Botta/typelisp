;; compiler_str_cat.tl - `str-cat` for compiler sources.
;;
;; stdlib's `str-cat` moves each operand into the concatenation. Compiler code
;; mostly concatenates names it keeps using (register names, labels, operand
;; text), so here a name operand is read in place: the concatenation copies its
;; bytes before it returns and never keeps the operand, so the owner is not
;; moved. A name of type `(& r str)` reads the String it borrows. Every other
;; operand is passed on unchanged.
(import stdlib.comptime)
(import stdlib.string)
(import stdlib.str_cat_runtime)

(defmacro (str-cat [args : comptime.Expr ...]) : String
  (let
    [parts : comptime.ExprList (comptime.expr-list-empty)]
    [index : i64 (comptime.expr-list-length args)]
    (while (> index 0)
      (set! index (- index 1))
      (let
        [arg : comptime.Expr (comptime.expr-list-nth args index)]
        (set!
          parts
          (comptime.expr-list-cons
            (match arg
              [(comptime.Expr.Var _) `(compiler_str_cat.str-cat-name ,arg)]
              [_ arg])
            parts))))
    `(stdlib.str_cat_runtime.str-cat ,@parts)))

;; The String a name operand holds or borrows, read in place.
(defmacro (str-cat-name [name : Expr]) : String
  (if (string.eq (type-kind (comptime.expr-type name)) "ref")
    `(unsafe
      (ptr-read (ptr-cast (__tl_array-data (array ,name)) : (Ptr String))))
    `(unsafe
      (ptr-read (ptr-addr-of ,name)))))