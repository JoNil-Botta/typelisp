;; Macros that name another module's functions qualified, and macros that
;; write bare helper spellings where stdlib.string is imported.
(import stdlib.string)
(import macro_qualified_helper_defs as defs)
(import macro_qualified_helper_int_defs as idefs)

(defmacro (q-length [a : Expr]) : Expr
  `(defs.string-length ,a))

(defmacro (q-ref [a : Expr]) : Expr
  `(defs.string-ref ,a 0))

(defmacro (q-char-at [a : Expr]) : Expr
  `(defs.char-at ,a 0))

(defmacro (q-eq [a : Expr] [b : Expr]) : Expr
  `(defs.eq ,a ,b))

(defmacro (q-string-eq [a : Expr] [b : Expr]) : Expr
  `(defs.string-eq ,a ,b))

(defmacro (q-string-eq? [a : Expr] [b : Expr]) : Expr
  `(defs.string=? ,a ,b))

(defmacro (q-append [a : Expr] [b : Expr]) : Expr
  `(defs.string-append ,a ,b))

(defmacro (q-concat [a : Expr] [b : Expr]) : Expr
  `(defs.string-concat ,a ,b))

(defmacro (q-clone [a : Expr]) : Expr
  `(defs.clone ,a))

(defmacro (q-int-eq [a : Expr] [b : Expr]) : Expr
  `(idefs.eq ,a ,b))

(defmacro (q-int-length [a : Expr]) : Expr
  `(idefs.string-length ,a))

(defmacro (q-array-length [a : Expr]) : Expr
  `(idefs.array-length ,a))

;; Bare spellings resolve where the macro is defined: the helpers.
(defmacro (b-length [a : Expr]) : Expr
  `(string-length ,a))

(defmacro (b-ref [a : Expr]) : Expr
  `(string-ref ,a 1))

(defmacro (s-length [a : Expr]) : Expr
  `(string.string-length ,a))

(defmacro (s-eq [a : Expr] [b : Expr]) : Expr
  `(string.eq ,a ,b))