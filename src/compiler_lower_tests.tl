;; compiler_lower_tests.tl - Selfhost lowering fixtures split from production.
(import "compiler_lower.tl")
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_builtin_ids as cbi)
(import "compiler_diagnostic.tl")
(import "compiler_ir_types.tl")
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as lower_i64_i64_map)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)

;; --- self-test ---------------------------------------------------------------
(define (compiler-lower-smoke-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if flag x 0))))")

(define (compiler-lower-export-source) : String
  "(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-lower-macro-expand-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64 (if (and2 true true) 1 0))")

(define (compiler-lower-macro-expr-clause-source) : String
  "(defmacro (pick [arm : ExprClause]) : i64
  `(if ,(expr-clause-first arm) ,(expr-clause-second arm) 0))
(define (main) : i64 (pick [true 7]))")

(define (compiler-lower-macro-expr-clause-variadic-source) : String
  "(defmacro (pick-first [arms : ExprClause ...]) : i64
  `(pick-first-from 0 ,@(expr-clause-list->expr-list arms)))
(defmacro (pick-first-from [idx : Expr] [arms : ExprClause ...]) : i64
  (match idx
    [(Expr.Int i)
      (if (>= i (expr-clause-list-length arms))
        (expr-int 0)
        (let
          [arm : ExprClause (expr-clause-list-nth arms i)]
          `(if ,(expr-clause-first arm)
             ,(expr-clause-second arm)
             (pick-first-from
               ,(expr-int (+ i 1))
               ,@(expr-clause-list->expr-list arms)))))]
    [_ (expr-int 0)]))
(define (main) : i64 (pick-first [false 1] [true 9] [true 3]))")

(define (compiler-lower-macro-expr-clause-to-expr-error-source) : String
  "(defmacro (id [x : Expr]) : i64 x)
(define (main) : i64 (id [true 1]))")

(define (compiler-lower-macro-expr-to-clause-error-source) : String
  "(defmacro (need [arm : ExprClause]) : i64
  (expr-clause-second arm))
(define (main) : i64 (need 1))")

(define (compiler-lower-macro-expr-clause-shape-error-source) : String
  "(defmacro (need [arm : ExprClause]) : i64
  (expr-clause-second arm))
(define (main) : i64 (need [true 1 2]))")

(define (compiler-lower-bracket-ordinary-call-error-source) : String
  "(define (take [x : i64]) : i64 x)
(define (main) : i64 (take [true 1]))")

(define (compiler-lower-macro-arity-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64 (if (and2 true) 1 0))")

(define (compiler-lower-macro-hygiene-definition-source) : String
  "(define (macro-helper [x : bool]) : bool (not x))
(defmacro (unless2 [condition : bool] [body : unit]) : unit
  `(if (macro-helper ,condition)
     ,body
     unit))
(define (main) : unit
  (let [macro-helper : bool true]
    (unless2 false unit)))")

;; A fixed-array literal `(array ...)`: it type-checks to `(Array i64 N)` and now
;; lowers to inline storage with each element stored at its offset, returning the
;; storage pointer (the same representation `array-ref`/`array-set!` index off).
(define (compiler-lower-array-literal-source) : String
  "(define (main) : i64
  (let [a : (Array i64 3) (array 1 2 3)]
    (array-ref a 2)))")

(define (compiler-lower-fixed-array-aggregate-literal-source) : String
  "(defstruct Pair (x i64) (y i64))
(define (main) : i64
  (let
    [items : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    (struct-get (array-ref items 1) y)))")

(define (compiler-lower-fixed-array-return-source) : String
  "(define (main) : (Array i64 3)
  (array 1 2 3))")

(define (compiler-lower-box-source) : String
  "(define (main) : i64 (box-get (box 7)))")

(define (compiler-lower-box-get-source) : String
  "(define (main [b : (Box i64)]) : i64 (box-get b))")

(define (compiler-lower-reference-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& n)))")

(define (compiler-lower-reference-auto-borrow-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take n))")

(define (compiler-lower-reference-mut-dotted-field-source) : String
  "(defstruct Inner (value i64))
(defstruct World (inner Inner))
(define (set-inner [inner : (&mut inner Inner)]) : unit
  (set! (struct-get inner value) 8))
(define (main) : i64
  (let [w : World (World (Inner 7))]
    (begin
      (set-inner (&mut w.inner))
      (struct-get (struct-get w inner) value))))")

(define (compiler-lower-reference-return-source) : String
  "(define (ref-return [n : i64]) : (& n i64) (& n))
(define (ref-id [r : (& n i64)]) : (& n i64) r)
(define (make-ref-tuple [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 7))
(define (make-ref-array [n : i64]) : (Array (& n i64) 1)
  (array (& n)))
(define (main [n : i64]) : i64
  (let
    [pair : (Tuple (& n i64) i64) (tuple (& n) 7)]
    [items : (Array (& n i64) 1) (array (& n))]
    (begin
      (ref-id (ref-return n))
      (make-ref-tuple n)
      (make-ref-array n)
      (tuple-ref pair 1)
      (array-ref items 0)
      42)))")

(define (compiler-lower-reference-place-source) : String
  "(defstruct Pair (left i64) (right i64))
(define (borrow-pair [p : Pair]) : (& p i64)
  (& (struct-get p left)))
(define (borrow-tuple [t : (Tuple i64 bool)]) : (& t i64)
  (& (tuple-ref t 0)))
(define (borrow-array [items : (Array i64 2)]) : (& items i64)
  (& (array-ref items 0)))
(define (main) : i64
  (let
    [p : Pair (Pair 40 2)]
    [t : (Tuple i64 bool) (tuple 41 true)]
    [items : (Array i64 2) (array 42 7)]
    (begin
      (borrow-pair p)
      (borrow-tuple t)
      (borrow-array items)
      42)))")

(define (compiler-lower-reference-inline-struct-field-source) : String
  "(defstruct Inner (name String) (line i64))
(defstruct Outer (prefix i64) (inner Inner))
(define (take-inner [inner : (& inner Inner)]) : i64
  (struct-get inner line))
(define (main [outer : Outer]) : i64
  (take-inner (& (struct-get outer inner))))")

(define (compiler-lower-reference-struct-result-source) : String
  "(defstruct RefBox
  (:lifetimes text)
  (borrowed (& text str))
  (owned String)
  (is-owned bool))
(define (ref-box-borrowed [text : (& text str)] [owned : String]) : (RefBox text)
  (RefBox text owned false))
(define (ref-box-owned [text : (& text str)] [owned : String]) : (RefBox text)
  (RefBox text owned true))
(define (ref-box-length [item : (RefBox text)]) : i64
  (if (struct-get item is-owned)
    (__tl_string_length (struct-get item owned))
    (__tl_string_length (struct-get item borrowed))))
(define (main [text : String] [owned : String]) : i64
  (let
    [borrowed : (RefBox text) (ref-box-borrowed (& text) owned)]
    [owned-box : (RefBox text) (ref-box-owned (& text) owned)]
    (+ (ref-box-length borrowed) (ref-box-length owned-box))))")

(define (compiler-lower-reference-struct-multi-result-source) : String
  "(defstruct ReplaceResult
  (:lifetimes text old replacement)
  (borrowed (& text str))
  (old-text (& old str))
  (replacement-text (& replacement str))
  (owned String)
  (is-owned bool))
(define (replace-borrowed
  [text : (& text str)]
  [old : (& old str)]
  [replacement : (& replacement str)]
  [owned : String]) : (ReplaceResult text old replacement)
  (ReplaceResult text old replacement owned false))
(define (replace-owned
  [text : (& text str)]
  [old : (& old str)]
  [replacement : (& replacement str)]
  [owned : String]) : (ReplaceResult text old replacement)
  (ReplaceResult text old replacement owned true))
(define (replace-score [item : (ReplaceResult text old replacement)]) : i64
  (+
    (__tl_string_length (struct-get item old-text))
    (+
      (__tl_string_length (struct-get item replacement-text))
      (if (struct-get item is-owned)
        (__tl_string_length (struct-get item owned))
        (__tl_string_length (struct-get item borrowed))))))
(define (main [text : String] [old : String] [replacement : String] [owned : String]) : i64
  (let
    [borrowed : (ReplaceResult text old replacement)
      (replace-borrowed (& text) (& old) (& replacement) owned)]
    [owned-result : (ReplaceResult text old replacement)
      (replace-owned (& text) (& old) (& replacement) owned)]
    (+ (replace-score borrowed) (replace-score owned-result))))")

(define (compiler-lower-reference-enum-result-source) : String
  "(defenum RefChoice
  (:lifetimes text)
  (RefChoiceBorrowed (& text str))
  (RefChoiceOwned String))
(define (borrowed-choice [text : (& text str)]) : (RefChoice text)
  (RefChoiceBorrowed text))
(define (owned-choice [text : (& text str)] [owned : String]) : (RefChoice text)
  (RefChoiceOwned owned))
(define (choice-length [choice : (RefChoice text)]) : i64
  (match choice
    [(RefChoiceBorrowed value) (__tl_string_length value)]
    [(RefChoiceOwned value) (__tl_string_length value)]))
(define (choice-loop [choice : (RefChoice text)] [count : i64]) : i64
  (match choice
    [(RefChoiceBorrowed value)
      (if (> count 0)
        (choice-loop (RefChoiceBorrowed value) (- count 1))
        (__tl_string_length value))]
    [(RefChoiceOwned value) (__tl_string_length value)]))
(define (main [text : String] [owned : String]) : i64
  (+
    (choice-length (borrowed-choice (& text)))
    (choice-loop (owned-choice (& text) owned) 1)))")

(define (compiler-lower-function-value-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
  (f x))
(define (shadow-inc [inc : (-> i64 i64)] [x : i64]) : i64
  (inc x))
(define (main) : i64
  (+ (apply1 inc 41) (shadow-inc inc 1)))")

(define (compiler-lower-function-value-contextual-init-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64
  (let
    [f : (-> i64 i64) inc]
    (f (init))))")

(define (compiler-lower-noncapturing-lambda-value-source) : String
  "(define (get-fn) : (-> i64 i64)
  (lambda ([x : i64]) : i64 (+ x 1)))")

(define (compiler-lower-immediate-lambda-call-source) : String
  "(define (main) : i64
  ((lambda ([x : i64]) : i64 (+ x 1)) 41))")

(define (compiler-lower-unit-lambda-call-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
(define (main) : unit
  ((lambda () : unit (print-i64 1))))")

(define (compiler-lower-capturing-lambda-scalar-source) : String
  "(define (main) : i64
  (let
    [n : i64 10]
    ((lambda ([x : i64]) : i64 (+ x n)) 32)))")

(define (compiler-lower-capturing-lambda-function-value-source) : String
  "(define (main) : i64
  (let
    [inc : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))]
    [n : i64 9]
    ((lambda ([x : i64]) : i64 (inc (+ x n))) 32)))")

(define (compiler-lower-capturing-lambda-fat-handle-source) : String
  "(define (main [n : i64]) : i64
  (let
    [s : String \"hello\"]
    [a : (Array i64) (make-array i64 2)]
    (begin
      (array-set! a 0 n)
      ((lambda () : i64 (+ (__tl_string_length s) (array-ref a 0)))))))")

(define (compiler-lower-capturing-lambda-aggregate-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Rect i64 i64) (None))
(define (main) : i64
  (let
    [t : (Tuple i64 i64) (tuple 5 99)]
    [p : Point (Point 7 1)]
    [a : (Array i64 2) (array 3 10)]
    [s : Shape (Rect 4 5)]
    ((lambda () : i64
       (+
         (tuple-ref t 0)
         (+
           (struct-get p x)
           (+
             (array-ref a 1)
             (match s
               [(Rect w h) (* w h)]
               [(None) 0]))))))))")

(define (compiler-lower-capturing-lambda-shadow-source) : String
  "(define (main) : i64
  (let
    [n : i64 10]
    ((lambda ([x : i64]) : i64
       (+
         n
         (let
           [n : i64 100]
           (+ x n))))
     32)))")

(define (compiler-lower-capturing-lambda-reference-source) : String
  "(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (let [copy : (& n i64) r] 42))]
      (f))))")

(define (compiler-lower-capturing-lambda-reference-immediate-source) : String
  "(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64 (let [copy : (& n i64) r] 42)))))")

;; `(comptime expr)` folds to a literal via the scalar CTFE evaluator.
;; These fixtures exercise arithmetic, f64, `if`, and `let` folds, plus the
;; runtime-variable rejection path.
(define (compiler-lower-comptime-arith-source) : String
  "(define (main) : i64 (comptime (+ 1 2)))")

(define (compiler-lower-comptime-if-source) : String
  "(define (main) : i64 (comptime (if (< 1 2) (* 6 7) 0)))")

(define (compiler-lower-comptime-let-source) : String
  "(define (main) : i64 (comptime (let [x 40] (+ x 2))))")

(define (compiler-lower-comptime-runtime-var-source) : String
  "(define (main [x : i64]) : i64 (comptime x))")

(define (compiler-lower-comptime-f64-source) : String
  "(define (main) : f64 (comptime 1.5))")

(define (compiler-lower-comptime-f32-source) : String
  "(define (main) : f32 (comptime (cast 1.00000001 : f32)))")

(define (compiler-lower-duplicate-function-source) : String
  "(define (dup) : i64 1)
(define (dup) : i64 2)
(define (main) : i64 (dup))")

(define (compiler-lower-defdispatch-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 (+ x 2))
(define (dot-avx512 [x : i64]) : i64 (+ x 5))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-lower-defdispatch-shared-helper-source) : String
  "(define (dispatch-helper [x : i64]) : i64 (+ x 1))
(define (dot-scalar [x : i64]) : i64 (dispatch-helper x))
(define (dot-avx2 [x : i64]) : i64 (+ (dispatch-helper x) 2))
(define (dot-avx512 [x : i64]) : i64 (+ (dispatch-helper x) 5))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-lower-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]
    [(ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-maybe-span-start-ok?
  [found-span : CompilerMaybeSourceSpan]
  [line : i64]
  [col : i64]) : bool
  (match found-span
    [(CompilerMaybeSourceSpan.Some found)
      (and
        (= (ast-source-span-start-line found) line)
        (= (ast-source-span-start-col found) col))]
    [(CompilerMaybeSourceSpan.No) false]))

(define (compiler-lower-nested-expression-diagnostic-span-ok?) : bool
  (let
    [span : AstSourceSpan (ast-source-span 11 3 11 9)]
    [value-id : i64 (ci.intern-generated-name "value")]
    [inner : i64 (ast-node-push (AstExpr.Var value-id))]
    [spanned-inner : i64 (ast-expr-spanned inner span)]
    [wrapped : i64 (ast-expr-cast spanned-inner (AstType.I64))]
    [diag : CompilerDiagnostic
      (lower-diagnostic-at-expr
        (ast-node-get wrapped)
        "lower: nested expression diagnostic")]
    [found-span : CompilerMaybeSourceSpan
      (lower-ast-expr-span (ast-node-get (ast-expr-return spanned-inner)))]
    [diag-ok : bool
      (and
        (string.eq
          (compiler-diagnostic-message diag)
          "lower: nested expression diagnostic")
        (= (compiler-diagnostic-line diag) 11)
        (= (compiler-diagnostic-col diag) 3))]
    [span-ok : bool (compiler-lower-maybe-span-start-ok? found-span 11 3)]
    (and diag-ok span-ok)))

(define (compiler-lower-compound-expression-diagnostic-span-ok?) : bool
  (let
    [span : AstSourceSpan (ast-source-span 17 5 17 12)]
    [compound-value-id : i64 (ci.intern-generated-name "compound-value")]
    [a-id : i64 (ci.intern-generated-name "a")]
    [b-id : i64 (ci.intern-generated-name "b")]
    [i-id : i64 (ci.intern-generated-name "i")]
    [prefix-id : i64 (ci.intern-generated-name "prefix")]
    [plain : i64 (ast-node-push (AstExpr.Literal AstLiteral.Unit))]
    [inner : i64 (ast-node-push (AstExpr.Var compound-value-id))]
    [spanned-inner : i64 (ast-expr-spanned inner span)]
    [items : AstExprList
      (ast-expr-cons plain (ast-expr-cons spanned-inner (ast-expr-list-new)))]
    [bindings : AstLetBindingList
      (ast-let-binding-cons
        (ast-let-binding-id a-id (AstMaybeType.No) plain)
        (ast-let-binding-cons
          (ast-let-binding-id b-id (AstMaybeType.No) spanned-inner)
          (ast-let-binding-list-new)))]
    [arms : AstMatchArmList
      (ast-match-arm-cons
        (ast-match-arm (AstPattern.Wildcard) plain)
        (ast-match-arm-cons
          (ast-match-arm (AstPattern.Wildcard) spanned-inner)
          (ast-match-arm-list-new)))]
    [resources : AstResourceBindingList
      (ast-resource-binding-cons
        (ast-resource-binding-id a-id plain plain)
        (ast-resource-binding-cons
          (ast-resource-binding-id b-id spanned-inner plain)
          (ast-resource-binding-list-new)))]
    [ok : bool true]
    (begin
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span
            (AstExpr.Binary (AstBinOp.Add) plain spanned-inner))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span (AstExpr.Call plain items))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span (AstExpr.If plain plain spanned-inner))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span (AstExpr.Let (box (AstLet.Let bindings plain))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span
            (AstExpr.Match (box (AstMatch.Match plain arms))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span
            (AstExpr.WithResource
              (box (AstWithResource.WithResource resources items))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span
            (AstExpr.SpmdScan
              (box
                (AstSpmdScan.Scan
                  (AstReduceOp.Sum)
                  i-id
                  (AstType.I64)
                  plain
                  plain
                  prefix-id
                  (AstType.I64)
                  plain
                  plain
                  spanned-inner))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (lower-ast-expr-span (AstExpr.Syscall items))
          17
          5)
        (set! ok false))
      ok)))

(define (compiler-lower-mode-error-ok?
  [src : String]
  [mode : CompilerLowerMode]
  [want : String]) : bool
  (match (lower-compiler-source-with-mode src mode)
    [(ResultCompilerLower.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]
    [(ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-inline-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source-with-mode
    src
    (CompilerLowerMode.InlineAggregates))
    [(ResultCompilerLower.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]
    [(ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-windows-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.WindowsScalar))
    [(ResultCompilerLower.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]
    [(ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-entry-moduled-main-ok?) : bool
  (let
    [prev-active : bool lower-entry-main-module-active]
    [prev-module : String lower-entry-main-module]
    [prev-module-id : i64 lower-entry-main-module-id]
    [active-ok : bool false]
    (begin
      (lower-entry-main-selection-install!
        (LowerMaybeEntryMainModule.Some "app.main" 123))
      (set!
        active-ok
        (and
          (lower-decl-entry-main? "src/app.tl" "src/app.tl" "app.main" "main")
          (lower-decl-entry-main? "src\\app.tl" "src/app.tl" "app.main" "main")
          (not
            (lower-decl-entry-main? "src/app.tl" "src/lib.tl" "app.main" "main"))
          (not
            (lower-decl-entry-main?
              "src/app.tl"
              "src/app.tl"
              "app.main"
              "helper"))))
      (lower-entry-main-selection-restore!
        prev-active
        prev-module
        prev-module-id)
      (and
        active-ok
        (not
          (lower-decl-entry-main? "src/app.tl" "src/app.tl" "app.main" "main"))))))

;; Scalar match lowering smoke: an i64 literal match with a binding
;; catch-all (value-returning), an exhaustive bool match, and a unit-typed match.
(define (compiler-lower-match-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
(define (classify [n : i64]) : i64
  (match n
    [0 100]
    [1 200]
    [other (+ other 1)]))
(define (flag-score [b : bool]) : i64
  (match b
    [true 1]
    [false 0]))
(define (sign [n : i64]) : i64
  (match n
    [0 0]
    [_ 1]))
(define (announce [n : i64]) : unit
  (match n
    [0 (print-i64 0)]
    [other (print-i64 other)]))
(define (main) : i64
  (begin
    (announce (classify 1))
    (+ (sign 7) (+ (classify 1) (flag-score true)))))")

;; Dynamic-array length lowering smoke: `array-length` and `length` on a
;; dynamic array lower to a fat-value length load rather than a runtime call.
(define (compiler-lower-array-length-source) : String
  "(define (dyn-len [a : (Array i64)]) : i64 (array-length a))
(define (dyn-len-alias [a : (Array i64)]) : i64 (length a))
(define (main) : i64 0)")

;; `array-ref`/`array-set!` lower to a bounds-checked typed element load/store.
;; Taking the array as a parameter avoids needing `make-array` here.
(define (compiler-lower-array-access-source) : String
  "(define (get [a : (Array i64)] [i : i64]) : i64 (array-ref a i))
(define (put [a : (Array i64)] [i : i64] [v : i64]) : unit (array-set! a i v))
(define (main) : i64 0)")

;; `array-take!` moves an element only when its companion liveness slot is
;; still true. The primitive returns a false availability flag for exhausted,
;; invalid, or already-taken positions instead of forming an out-of-bounds
;; address; its payload is then intentionally unspecified.
(define (compiler-lower-array-take-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-item [items : (Array i64)] [live : (Array bool)] [i : i64]) : (Tuple bool i64)
  (array-take! items live i))
(define (take-handle [items : (Array FileHandle)] [live : (Array bool)] [i : i64]) : (Tuple bool FileHandle)
  (array-take! items live i))
(define (main [items : (Array i64)] [live : (Array bool)] [handles : (Array FileHandle)] [handle-live : (Array bool)] [i : i64]) : i64
  (begin
    (take-item items live i)
    (if (tuple-ref (take-handle handles handle-live i) 0) 1 0)))")

;; Fixed-array access lowers against inline array storage rather than the
;; dynamic-array fat `{ptr, len}` layout.
(define (compiler-lower-fixed-array-access-source) : String
  "(define (get [a : (Array i64 3)] [i : i64]) : i64 (array-ref a i))
(define (put [a : (Array i64 3) (:consume)] [i : i64] [v : i64]) : unit (array-set! a i v))
(define (main) : i64 0)")

(define (compiler-lower-mut-ref-array-access-source) : String
  "(define (len [a : (& a (Array i64))]) : i64 (array-length a))
(define (get [a : (& a (Array i64))] [i : i64]) : i64 (array-ref a i))
(define (put [a : (&mut a (Array i64))] [i : i64] [v : i64]) : unit
  (array-set! a i v))
(define (grow [a : (&mut a (Array i64))] [v : i64]) : unit
  (array-push! a v))
(define (main) : i64 0)")

(define (compiler-lower-mut-ref-by-value-writeback-source) : String
  "(defstruct Pair (x i64) (y i64))
(define (set-pair-x! [p : (&mut p Pair)] [value : i64]) : unit
  (set! (struct-get p x) value))
(define (touch-scalar! [n : (&mut n i64)]) : unit unit)
(define (main) : i64
  (let
    [p : Pair (Pair 7 35)]
    [n : i64 41]
    (begin
      (set-pair-x! (&mut p) 40)
      (touch-scalar! (&mut n))
      42)))")

(define (compiler-lower-mut-ref-by-value-writeback-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-mut-ref-by-value-writeback-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (>= (lower-test-function-alloc-count functions "main") 2)
            (>= (lower-test-function-addr-of-count functions "main") 2)
            (>= (lower-test-function-load-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-mut-ref-array-field-access-source) : String
  "(defstruct ArrayBag (items (Array i64)))
(defstruct ArrayBagHandle
  (:lifetimes bag)
  (items (&mut bag (Array i64)))
  (index i64))
(define (array-bag-handle [bag : (&mut bag ArrayBag)] [index : i64]) : (ArrayBagHandle bag)
  (ArrayBagHandle (&mut (struct-get bag items)) index))
(define (len [handle : (ArrayBagHandle bag)]) : i64
  (array-length (struct-get handle items)))
(define (get [handle : (ArrayBagHandle bag)]) : i64
  (array-ref (struct-get handle items) (struct-get handle index)))
(define (put [handle : (ArrayBagHandle bag)] [v : i64]) : unit
  (array-set! (struct-get handle items) (struct-get handle index) v))
(define (main) : i64 0)")

;; `array-push!` lowers to checked arena reallocation, a runtime-length copy,
;; a tail store, and in-place fat `{ptr, len}` updates.
(define (compiler-lower-array-push-source) : String
  "(define (grow [a : (Array i64)] [v : i64]) : unit (array-push! a v))
(define (main) : i64 0)")

;; Fixed arrays have no runtime capacity field and remain unsupported for push.
(define (compiler-lower-fixed-array-push-source) : String
  "(define (grow [a : (Array i64 3)] [v : i64]) : unit (array-push! a v))
(define (main) : i64 0)")

;; `make-array` lowers to checked byte-count math, a `tl_alloc` element buffer,
;; initialized elements, and a dynamic-array fat value. The fixture also
;; immediately uses `array-set!`, `array-ref`, and `array-length` so the
;; generated IR exercises the full dynamic-array primitive set.
(define (compiler-lower-make-array-source) : String
  "(define (main [n : u32]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-length a) (+ (array-ref a 0) (array-ref a 1))))))")

(define (compiler-lower-make-array-init-source) : String
  "(define (main [n : i64]) : i64
  (let
    [items : (Array String) (make-array String n)]
    (array-length items)))")

(define (compiler-lower-dyn-array-literal-source) : String
  "(define dyn-array-literal-trace : i64 0)
(define (side [value : i64]) : i64
  (begin
    (set! dyn-array-literal-trace (+ (* dyn-array-literal-trace 10) value))
    value))
(define (main) : i64
  (let
    [items : (Array i64) (make-array (side 1) (side 2) (side 3))]
    (+ (array-length items)
       (+ (array-ref items 0)
          (+ (array-ref items 1)
             (+ (array-ref items 2) dyn-array-literal-trace))))))")

(define (compiler-lower-make-array-register-resident-fill8-source) : String
  "(defstruct OneWord (value i64))
(define (main [n : i64]) : i64
  (let
    [items : (Array OneWord) (make-array OneWord n)]
    (array-length items)))")

;; Core and private string length lower to the same fat `{ptr, len}` length load
;; as `array-length`: both lay out the i64 length at offset 8.
(define (compiler-lower-string-length-source) : String
  "(define (str-len [s : String]) : i64 (__tl_string_length s))
(define (str-len-alias [s : String]) : i64 (__tl_string_length s))
(define (str-len-borrow [s : String]) : i64 (__tl_string_length (& s)))
(define (str-len-alias-borrow [s : String]) : i64 (__tl_string_length (& s)))
(define (core-str-len [s : String]) : i64 (length s))
(define (core-str-len-borrow [s : (& s str)]) : i64 (length s))
(define (main) : i64 0)")

(define (compiler-lower-float-bitcast-source) : String
  "(define (f64-bits [value : f64]) : u64 (__tl_float_to_bits value))
(define (f32-bits [value : f32]) : u32 (__tl_float_to_bits value))
(define (f64-from [bits : u64]) : f64 (__tl_float_from_bits bits))
(define (f32-from [bits : u32]) : f32 (__tl_float_from_bits bits))
(define (main) : i64 0)")

(define (compiler-lower-literal-float-to-bits-source) : String
  "(define (f64-pos-zero) : u64 (__tl_float_to_bits 0.0))
(define (f64-neg-zero) : u64 (__tl_float_to_bits -0.0))
(define (f64-pos-normal) : u64 (__tl_float_to_bits 0.1))
(define (f64-neg-normal) : u64 (__tl_float_to_bits -0.1))
(define (f64-pos-subnormal) : u64
  (__tl_float_to_bits 0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005))
(define (f64-neg-subnormal) : u64
  (__tl_float_to_bits -0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005))
(define (f32-pos-zero) : u32 (__tl_float_to_bits (ann 0.0 : f32)))
(define (f32-neg-zero) : u32 (__tl_float_to_bits (ann -0.0 : f32)))
(define (f32-pos-normal) : u32 (__tl_float_to_bits (ann 0.1 : f32)))
(define (f32-neg-normal) : u32 (__tl_float_to_bits (ann -0.1 : f32)))
(define (f32-pos-subnormal) : u32
  (__tl_float_to_bits
    (ann 0.000000000000000000000000000000000000000000001 : f32)))
(define (f32-neg-subnormal) : u32
  (__tl_float_to_bits
    (ann -0.000000000000000000000000000000000000000000001 : f32)))
(define (main) : i64 0)")

(define (compiler-lower-public-literal-float-to-bits-source) : String
  "(module stdlib.math)
(define (f64-to-bits [value : f64]) : u64 (__tl_float_to_bits value))
(define (f32-to-bits [value : f32]) : u32 (__tl_float_to_bits value))
(define (f64-literal) : u64 (stdlib.math.f64-to-bits 0.1))
(define (f32-literal) : u32 (stdlib.math.f32-to-bits -0.0))
(define (main) : i64
  (+ (cast (f64-literal) : i64) (cast (f32-literal) : i64)))")

(define (compiler-lower-public-literal-float-to-bits-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "stdlib/math.tl"
    (ast-decl-root-path-cons
      "stdlib/math.tl"
      (ast-decl-root-path-cons
        "stdlib/math.tl"
        (ast-decl-root-path-cons
          "stdlib/math.tl"
          (ast-decl-root-path-cons
            "stdlib/math.tl"
            (ast-decl-root-path-cons "stdlib/math.tl" (ast-decl-path-list-new))))))))

(define (compiler-lower-stdlib-string-wrapper-prune-source) : String
  "(module stdlib.string)
(define (string.string-length [text : (& text str)]) : i64 0)
(module stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(define (io-len [text : String]) : i64 (string.string-length text))
(define (main) : i64 (io-len \"abc\"))")

(define (compiler-lower-stdlib-string-wrapper-prune-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "stdlib/string.tl"
    (ast-decl-root-path-cons
      "stdlib/string.tl"
      (ast-decl-root-path-cons
        "stdlib/string.tl"
        (ast-decl-root-path-cons
          "stdlib/tl"
          (ast-decl-root-path-cons
            "stdlib/tl"
            (ast-decl-root-path-cons
              "stdlib/tl"
              (ast-decl-root-path-cons "stdlib/tl" (ast-decl-path-list-new)))))))))

(define (compiler-lower-stdlib-string-wrapper-prune-ok?) : bool
  (match (parse-ast-source (compiler-lower-stdlib-string-wrapper-prune-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "stdlib/tl"
        program
        (compiler-lower-stdlib-string-wrapper-prune-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined? functions "tl::stdlib.io/io-len")
                (not
                  (lower-test-function-defined?
                    functions
                    "stdlib/string.tl::stdlib.string/string.string-length"))
                (not
                  (lower-test-function-defined?
                    functions
                    "string.tl::stdlib.string/string.string-length"))
                (not
                  (lower-test-function-defined?
                    functions
                    "stdlib/string.tl::stdlib.string/string-length"))
                (not
                  (lower-test-function-defined?
                    functions
                    "string.tl::stdlib.string/string-length")))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-string-runtime-source) : String
  "(define (io.print-string [text : String]) : unit
  unit)
(define (io.print-str [text : String]) : unit
  (io.print-string text))
(define (string.append [left : (& left str)] [right : (& right str)]) : String
  \"joined\")
(define (string.substring [text : (& text str)] [start : i64] [len : i64]) : String
  (let
    [probe : char (__tl_string_ref text start)]
    \"slice\"))
(define (string.concat [left : (& left str)] [right : (& right str)]) : String
  (string.append left right))
(define (main) : i64
  (let
    [left : String \"foo\"]
    [right : String \"bar\"]
    [joined : String (string.append (& left) (& right))]
    [mid : String (string.substring (& joined) 2 3)]
    [bang : String \"!\"]
    [extended : String (string.concat (& mid) (& bang))]
    [spaced : String \" x\"]
    [digits : String \"7\"]
    (begin
      (io.print-string joined)
      (io.print-str extended)
      (+ (__tl_string_length (& joined))
        (+ (__tl_string_length (& extended))
          (+ (__tl_string_to_int (& digits))
            (+ (if (__tl_string_eq (& joined) (& extended)) 1 0)
              (cast (__tl_string_ref (& spaced) 0) : i64))))))))")

(define (compiler-lower-string-concat-fusion-source) : String
  "(define (string.append [left : String] [right : String]) : String
  left)
(define (shadowed-tail) : String
  (string.append \"x\" \"y\"))
(define (main) : i64
  (let
    [three : String (string.append \"a\" (string.append \"b\" \"c\"))]
    [four : String
      (string.append \"a\" (string.append \"b\" (string.append \"c\" \"d\")))]
    [five : String
      (string.append
        \"a\"
        (string.append \"b\" (string.append \"c\" (string.append \"d\" \"e\"))))]
    (+ (__tl_string_length three)
      (+ (__tl_string_length four) (__tl_string_length five)))))")

(define (compiler-lower-print-string-stdlib-source) : String
  "(define (io.print-string [text : String]) : unit
  unit)
(define (io.print-str [text : String]) : unit
  (io.print-string text))
(define (main [text : String]) : i64
  (begin
    (io.print-string text)
    (io.print-str text)
    0))")

(define (compiler-lower-borrowed-str-param-source) : String
  "(define (borrowed-score [path : (& path str)]) : i64
  (__tl_string_length path))
(define (main [path : String]) : i64
  (borrowed-score (& path)))")

(define (compiler-lower-stdlib-hash-string-source) : String
  "(define (hash-string [key : (& key str)]) : i64
  (let
    [n : i64 (__tl_string_length key)]
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (< i n)
        (let
          [next : i64
            (+ (+ (* hash 131) (cast (__tl_string_ref key i) : i64)) 1)]
          [reduced : i64
            (+ (bit-and next 0x7fffffff) (shr next 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (+ i 1)))))
      hash)))
(define (main [key : String]) : i64
  (+ (hash-string (& key)) 0))")

(define (compiler-lower-stdlib-hash-string-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "stdlib/hash.tl"
    (ast-decl-root-path-cons "app.tl" (ast-decl-path-list-new))))

(define (compiler-lower-string-shadow-source) : String
  "(define (string.string-length [s : String]) : i64 40)
(define (string.append [a : i64] [b : i64]) : i64 (+ a b))
(define (string.string-ref [a : i64] [b : i64]) : i64 (+ a b))
(define (string.char-at [a : i64] [b : i64]) : i64 (* a b))
(define (main) : i64
  (+ (string.string-length \"abc\")
    (+ (string.append 1 1)
      (+ (string.string-ref 10 7) (string.char-at 3 4)))))")

(define (compiler-lower-stdio-source) : String
  "(define stdin-eof-state : bool false)
(define (io.read-stdin-bytes [count : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 count)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) count))))
(define (read-stdin-line) : String
  (let
    [buf : (Array u8) (make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) 0))))
(define (stdin-eof?) : bool stdin-eof-state)
(define (flush-stdout) : unit unit)
(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (__tl_string_length (read-stdin-line))
        (__tl_string_length (io.read-stdin-bytes 3)))))")

(define (compiler-lower-stdio-builtin-source) : String
  "(define stdin-eof-state : bool false)
(define (io.read-stdin-bytes [count : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 count)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) count))))
(define (read-stdin-line) : String
  (let
    [buf : (Array u8) (make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) 0))))
(define (stdin-eof?) : bool stdin-eof-state)
(define (flush-stdout) : unit unit)
(define (main [count : i64]) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (__tl_string_length (read-stdin-line))
        (__tl_string_length (io.read-stdin-bytes count)))))")

(define (compiler-lower-env-builtin-source) : String
  "(define (var-exists? [name : String]) : bool true)
(define (var-value [name : String]) : String name)
(define (path-separator) : String \":\")
(define (main [name : String]) : i64
  (let
    [separator : String (path-separator)]
    [value : String (var-value name)]
    (if (var-exists? name)
      (+ (__tl_string_length value) (__tl_string_length separator))
      (__tl_string_length separator))))")

(define (compiler-lower-cpu-builtin-source) : String
  "(define (main) : i64
  (let
    [r : (Tuple i32 i32 i32 i32) (cpuid 0 0)]
    (+ (cast (tuple-ref r 0) : i64) (xgetbv 0))))")

(define (compiler-lower-fs-status-source) : String
  "(define (current-dir-status) : i64 0)
(define (current-dir) : String \".\")
(define (process-id) : i64 1)
(define (mkdir-status [path : String]) : i64 0)
(define (remove-file-status [path : String]) : i64 0)
(define (remove-dir-status [path : String]) : i64 0)
(define (rename-status [source : String] [destination : String]) : i64 0)
(define (read-dir-status [path : String]) : i64 0)
(define (read-dir [path : String]) : String path)
(define (file-kind-status [path : String]) : i64 0)
(define (file-size-status [path : String]) : i64 0)
(define (file-size [path : String]) : i64 (__tl_string_length path))
(define (main) : i64
  (+ (current-dir-status)
    (+ (__tl_string_length (current-dir))
      (+ (process-id)
        (+ (mkdir-status \"target/typelisp-fs\")
          (+ (remove-file-status \"target/typelisp-fs/artifact.o\")
            (+ (remove-dir-status \"target/typelisp-fs\")
              (+ (rename-status
                  \"target/typelisp-fs/from name\"
                  \"target/typelisp-fs/to name\")
                (+ (read-dir-status \"target/typelisp-fs\")
                  (+ (__tl_string_length (read-dir \"target/typelisp-fs\"))
                    (+ (file-kind-status \"target/typelisp-fs\")
                      (+ (file-size-status \"target/typelisp-fs\")
                        (file-size \"target/typelisp-fs\")))))))))))))")

(define (compiler-lower-raw-pointer-ops-source) : String
  "(extern (raw-make) : (MutPtr i64))
(define (main [n : u64]) : u64
  (let
    [cell : i64 0]
    [local : (MutPtr i64) (unsafe (ptr-addr-of cell))]
    [p : (MutPtr i64) (raw-make)]
    (unsafe
      (ptr-write! local 42)
      (ptr-read local)
      (ptr-write! p 41)
      (ptr-read p)
      (ptr->int (ptr-offset (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr i64)) 2)))))")

(define (compiler-lower-register-addr-of-source) : String
  "(defstruct Tiny (a i32) (b i32))
(defstruct Pair (x i64) (y i64))
(defstruct Wrap (tiny Tiny))
(define (main) : i64
  (let
    [tiny : Tiny (Tiny (cast 1 : i32) (cast 2 : i32))]
    [pair : Pair (Pair 3 4)]
    [wrap : Wrap (Wrap (Tiny (cast 7 : i32) (cast 8 : i32)))]
    [whole : (MutPtr Pair) (unsafe (ptr-addr-of pair))]
    [tiny-field : (MutPtr i32) (unsafe (ptr-addr-of (struct-get tiny b)))]
    [pair-field : (MutPtr i64) (unsafe (ptr-addr-of (struct-get pair y)))]
    [nested-field : (MutPtr i32)
      (unsafe (ptr-addr-of (struct-get (struct-get wrap tiny) b)))]
    (unsafe
      (ptr-write! tiny-field (cast 5 : i32))
      (ptr-write! pair-field 6)
      (ptr-write! nested-field (cast 9 : i32))
      (+ (cast (ptr->int whole) : i64)
        (+ (cast (ptr-read tiny-field) : i64)
          (+ (ptr-read pair-field)
            (cast (ptr-read nested-field) : i64)))))))")

(define (compiler-lower-raw-pointer-direct-call-source) : String
  "(extern (raw-make) : (MutPtr i64))
(define (main) : unit
  (unsafe
    (ptr-write! (raw-make) 41)))")

(define (compiler-lower-raw-pointer-call-value-source) : String
  "(extern (raw-make) : (MutPtr i64))
(extern (raw-value) : i64)
(define (main) : unit
  (unsafe
    (ptr-write! (raw-make) (raw-value))))")

(define (compiler-lower-raw-pointer-aggregate-copy-source) : String
  "(defenum Slot
  (Empty)
  (Tombstone)
  (Occupied i64 i64 i64))
(defstruct Pair
  (left i64)
  (right i64))
(define (copy-slot [dst : (MutPtr Slot)] [src : (Ptr Slot)]) : unit
  (unsafe
    (ptr-write! dst (ptr-read src))))
(define (copy-pair [dst : (MutPtr Pair)] [src : (Ptr Pair)]) : unit
  (unsafe
    (ptr-write! dst (ptr-read src))))
(define (main) : i64 0)")

(define (compiler-lower-aggregate-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Nothing) (Circle i64) (Pair Point))
(define (make-point [x : i64] [y : i64]) : Point
  (Point x y))
(define (get-y [p : Point]) : i64
  (struct-get p y))
(define (make-none) : Shape
  Nothing)
(define (make-none-call) : Shape
  (Nothing))
(define (make-circle [r : i64]) : Shape
  (Circle r))
(define (make-pair [x : i64]) : Shape
  (Pair (Point x (+ x 1))))
(define (main) : i64
  (get-y (make-point 20 22)))")

(define (compiler-lower-init-source) : String
  "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some i64))
(define (take [n : i64]) : i64 n)
(define (main) : i64
  (let
    [n : i64 (init : i64)]
    [flag : bool (init)]
    [ch : char (init)]
    [text : String (init)]
    [ptr : (Ptr i64) (init)]
    [items : (Array i64) (init)]
    [tupled : (Tuple i64 bool) (init)]
    [fixed : (Array i64 2) (array (init) 2)]
    [point : Point (init)]
    [constructed : Point (Point (init) (init))]
    [maybe : Maybe (init)]
    [boxed : (Box i64) (init)]
    [called : i64 (take (init))]
    (begin
      (array-set! fixed 0 (init))
      (+ n (+ called (+ (struct-get point x) (+ (struct-get constructed x) (+ (tuple-ref tupled 0) (+ (array-ref fixed 0) (box-get boxed))))))))))")

;; Tuple construction + ref lowering: `(tuple true 42)` reserves
;; struct-shaped aggregate storage and stores each element at its field offset;
;; `(tuple-ref t 1)` gep+loads the indexed element. The whole computation lives
;; in `main` so it is not pruned as unreachable.
(define (compiler-lower-tuple-source) : String
  "(define (main) : i64
  (let
    [t : (Tuple bool i64) (tuple true 42)]
    (tuple-ref t 1)))")

(define (compiler-lower-tuple-return-source) : String
  "(define (make-pair [a : i64] [b : bool]) : (Tuple i64 bool)
  (tuple a b))")

(define (compiler-lower-clone-source) : String
  "(defstruct Holder
  (name String)
  (fixed (Array String 2))
  (items (Array String))
  (pair (Tuple String String)))
(defenum StringTree
  (Leaf String)
  (Branch (Box StringTree) (Box StringTree)))
(define (clone-tuple [items : (Array String)]) : i64
  (let [pair : (Tuple String (Array String)) (clone (tuple \"tuple\" items))]
    (__tl_string_length (tuple-ref pair 0))))
(define (clone-fixed) : i64
  (let [fixed : (Array String 2) (clone (array \"left\" \"right\"))]
    (__tl_string_length (array-ref fixed 0))))
(define (clone-dyn [items : (Array String)]) : i64
  (let [copied : (Array String) (clone items)]
    (array-length copied)))
(define (clone-holder [items : (Array String)]) : Holder
  (clone (Holder \"holder\" (array \"x\" \"y\") items (tuple \"p\" \"q\"))))
(define (clone-tree [tree : StringTree]) : StringTree
  (clone tree))
(define (main [n : i64] [tree : StringTree]) : i64
  (let
    [items1 : (Array String) (make-array String n)]
    [items2 : (Array String) (make-array String n)]
    [items3 : (Array String) (make-array String n)]
    (begin
      (clone-tuple items1)
      (clone-dyn items2)
      (clone-holder items3)
      (clone-fixed)
      (clone-tree tree)
      0)))")

(define (compiler-lower-clone-dynarray-bulk-source) : String
  "(defstruct OneWord
  (value i64))
(define (copy-i64-items [items : (Array i64)]) : (Array i64)
  (clone items))
(define (copy-word-items [items : (Array OneWord)]) : (Array OneWord)
  (clone items))
(define (copy-string-items [items : (Array String)]) : (Array String)
  (clone items))")

(define (compiler-lower-clone-unsupported-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : (-> i64 i64)
  (clone inc))")

(define (compiler-lower-clone-reachable-source) : String
  "(defstruct UsedClone
  (name String))
(defstruct NestedClone
  (used UsedClone))
(defstruct UnusedClone
  (name String))
(define (make-nested [s : String]) : NestedClone
  (clone (NestedClone (UsedClone s))))
(define (main [s : String]) : i64
  (let
    [item : NestedClone (make-nested s)]
    (__tl_string_length (struct-get (struct-get item used) name))))")

;; Nominal clone helpers are declaration macros now, so clone-producing lowering
;; fixtures must load the same implicit prelude as the compiler driver.
(define (compiler-lower-clone-source-with-prelude [src : String]) : ResultCompilerLower
  (begin
    (intern-reset!)
    (lower-reset-intern-owned-state!)
    (cbi.compiler-builtin-reset!)
    (match (typecheck-compiler-source-load src)
      [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (lower-compiler-program-with-decl-paths "" (ast-program decls) paths)]
      [(ResultCompilerLoadWithPaths.Err diag) (ResultCompilerLower.Err diag)])))

;; `main` must lower with both element stores (bool + i64 each written into the
;; aggregate) and a load for the `tuple-ref`.
(define (compiler-lower-tuple-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tuple-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (>= (lower-test-function-store-ptr-count functions "main") 2)
            (>= (lower-test-function-load-count functions "main") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-clone-shape-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone-tuple"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone-tuple"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone-fixed"
                  "tl_substring")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone-dyn"
                  "tl_alloc")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-branch-count functions ".::clone-dyn")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  functions
                  ".::clone-holder"
                  ".::clone$Holder")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  functions
                  ".::clone-tree"
                  ".::clone$StringTree")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone$Holder"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone$Holder"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::clone$StringTree"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-clone-dynarray-bulk-copy-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-dynarray-bulk-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count
                  functions
                  ".::copy-i64-items"
                  "tl_memcpy")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-branch-count functions ".::copy-i64-items")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  functions
                  ".::copy-word-items"
                  "tl_memcpy")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-branch-count
                  functions
                  ".::copy-word-items")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  functions
                  ".::copy-string-items"
                  "tl_memcpy")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  functions
                  ".::copy-string-items"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-branch-count
                  functions
                  ".::copy-string-items")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-clone-reachable-helpers-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-reachable-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined? functions ".::clone$NestedClone")
            (lower-test-function-defined? functions ".::clone$UsedClone")
            (not
              (lower-test-function-defined? functions ".::clone$UnusedClone"))
            (=
              (lower-test-function-call-count
                functions
                ".::clone$NestedClone"
                ".::clone$UsedClone")
              1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-struct-source) : String
  "(defstruct Packet (tag i64) (small u8) (count i64))
(define (main) : i64
  (let
    [p : Packet (Packet 7 (cast 2 : u8) 40)]
    (+
      (struct-get p tag)
      (+
        (cast (struct-get p small) : i64)
        (struct-get p count)))))")

(define (compiler-lower-inline-enum-source) : String
  "(defenum Choice (Empty) (Wide u8 i64))
(define (main) : i64
  (let
    [c : Choice (Wide (cast 1 : u8) 41)]
    (match c
      [Empty 0]
      [(Wide b n) (+ (cast b : i64) n)])))")

(define (compiler-lower-inline-boxed-recursive-source) : String
  "(defenum Tree (Leaf i64) (Branch (Box Tree) (Box Tree)))
(define (main) : i64
  (let
    [tree : Tree (Branch (box (Leaf 20)) (box (Leaf 21)))]
    (match tree
      [(Leaf value) value]
      [(Branch left right)
        (+ (match (box-get left) [(Leaf value) value] [_ 0])
           (match (box-get right) [(Leaf value) value] [_ 0]))])))")

(define (compiler-lower-inline-imported-enum-payload-source) : String
  "(module stdlib.maybe_string)
(defenum MaybeString (No) (Some String))
(define (maybe-string-single [value : String]) : MaybeString
  (MaybeString.Some value))
(module main)
(import stdlib.maybe_string)
(define (main) : i64
  (__tl_string_length
    (match (maybe_string.maybe-string-single \"a\")
      [(maybe_string.MaybeString.No) \"\"]
      [(maybe_string.MaybeString.Some head) head])))")

(define (compiler-lower-inline-recursive-error-source) : String
  "(defenum BadTree (Leaf i64) (Branch BadTree BadTree))
(define (main) : i64
  (let
    [x : BadTree (BadTree.Leaf 1)]
    0))")

(define (compiler-lower-inline-aggregate-copy-source) : String
  "(defstruct Pair (a i64) (b i64))
(define (id-pair [p : Pair]) : Pair p)
(define (main) : i64
  (struct-get (id-pair (Pair 20 22)) b))")

(define (compiler-lower-inline-mixed16-copy-source) : String
  "(defstruct Mixed16 (tag u32) (value f32) (tail i64))
(define (id-mixed [p : Mixed16]) : Mixed16 p)
(define (main) : i64
  (struct-get (id-mixed (Mixed16 (cast 1 : u32) 2.0 40)) tail))")

(define (compiler-lower-inline-sret-struct-constructor-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(define (make-wide [x : i64]) : Wide
  (Wide x (+ x 1) (+ x 2)))
(define (main) : i64
  (struct-get (make-wide 40) c))")

(define (compiler-lower-inline-sret-enum-constructor-source) : String
  "(defenum WideChoice (Some i64 i64 i64) (None))
(define (make-wide-choice [x : i64]) : WideChoice
  (WideChoice.Some x (+ x 1) (+ x 2)))
(define (main) : i64
  (match (make-wide-choice 40)
    [(WideChoice.Some _ _ c) c]
    [WideChoice.None 0]))")

(define (compiler-lower-inline-sret-enum-match-constructor-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(defenum Choice (Make i64) (Zero))
(define (from-choice [choice : Choice]) : Wide
  (match choice
    [(Make n) (Wide n (+ n 1) (+ n 2))]
    [Zero (Wide 0 1 2)]))
(define (main) : i64
  (struct-get (from-choice (Make 40)) c))")

(define (compiler-lower-inline-sret-enum-match-generic-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(defenum Choice (Make i64) (Wrap Wide))
(define (from-choice [choice : Choice]) : Wide
  (match choice
    [(Make n) (Wide n (+ n 1) (+ n 2))]
    [(Wrap w) w]))
(define (main) : i64
  (struct-get (from-choice (Make 40)) c))")

(define (compiler-lower-inline-hot-loop-struct-source) : String
  "(defstruct Pair (x i64) (y i64))
(define (main [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (let
          [p : Pair (Pair i (+ i 1))]
          (begin
            (set! sum (+ sum (struct-get p y)))
            (set! i (+ i 1)))))
      sum)))")

(define (compiler-lower-inline-direct-store-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(defstruct Holder (wide Wide) (tail i64))
(define (direct-field [h : Holder (:consume)]) : i64
  (begin
    (set! (struct-get h wide) (Wide 1 2 3))
    0))
(define (direct-init [h : Holder (:consume)]) : i64
  (begin
    (set! (struct-get h wide) (init : Wide))
    0))
(define (direct-dyn-array [items : (Array Wide)] [i : i64]) : unit
  (array-set! items i (Wide 4 5 6)))
(define (direct-fixed-array [items : (Array Wide 2) (:consume)] [i : i64]) : unit
  (array-set! items i (Wide 7 8 9)))
(define (direct-fixed-literal) : (Array Wide 2)
  (array (Wide 10 11 12) (Wide 13 14 15)))")

;; Payload offset lookup must not depend on earlier enum families or on
;; helper/constructor ordering when String and i64 payload result enums coexist.
(define (compiler-lower-inline-enum-layout-cache-order-source-a) : String
  "(defenum FirstResult
  (Err String)
  (Ok i64))
(defenum SecondResult
  (Ok i64)
  (Err String))
(define (first-helper [flag : bool]) : FirstResult
  (if flag
    (FirstResult.Ok 1)
    (FirstResult.Err \"first failed\")))
(define (second-helper [value : i64]) : SecondResult
  (SecondResult.Ok value))
(define (second-value-or [result : SecondResult] [fallback : i64]) : i64
  (match result
    [(SecondResult.Err _) fallback]
    [(SecondResult.Ok value) value]))
(define (main) : i64
  (+
    (match (first-helper false)
      [(FirstResult.Err message) (__tl_string_length message)]
      [(FirstResult.Ok value) value])
    (second-value-or (second-helper 40) 0)))")

(define (compiler-lower-inline-enum-layout-cache-order-source-b) : String
  "(defenum SecondResult
  (Err String)
  (Ok i64))
(defenum FirstResult
  (Ok i64)
  (Err String))
(define (second-value-or [result : SecondResult] [fallback : i64]) : i64
  (match result
    [(SecondResult.Ok value) value]
    [(SecondResult.Err _) fallback]))
(define (first-helper [flag : bool]) : FirstResult
  (if flag
    (FirstResult.Ok 2)
    (FirstResult.Err \"first failed\")))
(define (second-helper [value : i64]) : SecondResult
  (SecondResult.Ok value))
(define (main) : i64
  (+
    (second-value-or (second-helper 40) 0)
    (match (first-helper false)
      [(FirstResult.Ok value) value]
      [(FirstResult.Err message) (__tl_string_length message)])))")

(define (compiler-lower-inline-struct-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-inline-struct-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count functions "main" "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>= (lower-test-function-alloc-count functions "main") 3)
                unit
                (set! ok false))
              (if (= (lower-test-function-addr-of-count functions "main") 1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 3)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count functions "main" 16)
                0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-enum-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-inline-enum-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count functions "main" "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>= (lower-test-function-alloc-count functions "main") 3)
                unit
                (set! ok false))
              (if (= (lower-test-function-addr-of-count functions "main") 1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 3)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count functions "main" 16)
                0)
                unit
                (set! ok false))
              (if (> (lower-test-function-branch-count functions "main") 0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-boxed-recursive-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-inline-boxed-recursive-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count functions "main" "tl_alloc")
                2)
                unit
                (set! ok false))
              (if (>= (lower-test-function-alloc-count functions "main") 6)
                unit
                (set! ok false))
              (if (>= (lower-test-function-addr-of-count functions "main") 2)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 4)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-imported-enum-payload-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-inline-imported-enum-payload-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-functions-call-count
              functions
              "stdlib.maybe_string/maybe-string-single")
            0)])]
    [(ResultCompilerLower.Err _) false]))

;; `id-pair` is the identity on a 16-byte all-integer struct, which is
;; register-resident -- it is carried in a register pair end-to-end, so the
;; passthrough needs NO memory traffic at all: zero byte-copies and zero stores
;; (before register-residency this copied the 16 bytes through a slot). The
;; A mixed int/float 16-byte aggregate stays memory-backed, so its identity
;; return exercises the lower-copy-bytes 16-byte CopyBytes threshold.
(define (compiler-lower-inline-aggregate-copy-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-aggregate-copy-source)
    (CompilerLowerMode.InlineAggregates))
    [(ResultCompilerLower.Ok pair-program _)
      (match pair-program
        [(CompilerIrProgram.Program _ pair-functions _)
          (let
            [pair-copy-count : i64
              (lower-test-function-copy-bytes-count pair-functions "id-pair")]
            [pair-store-count : i64
              (lower-test-function-store-ptr-count pair-functions "id-pair")]
            (match (lower-compiler-source-with-mode
              (compiler-lower-inline-mixed16-copy-source)
              (CompilerLowerMode.InlineAggregates))
              [(ResultCompilerLower.Ok mixed-program _)
                (match mixed-program
                  [(CompilerIrProgram.Program _ mixed-functions _)
                    (and
                      (= pair-copy-count 0)
                      (= pair-store-count 0)
                      (=
                        (lower-test-function-copy-bytes-count
                          mixed-functions
                          "id-mixed")
                        1))])]
              [(ResultCompilerLower.Err _) false]))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-sret-constructor-copy-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-sret-struct-constructor-source)
    (CompilerLowerMode.InlineAggregates))
    [(ResultCompilerLower.Ok struct-program _)
      (match struct-program
        [(CompilerIrProgram.Program _ struct-functions _)
          (let
            [struct-copy-count : i64
              (lower-test-function-copy-bytes-count
                struct-functions
                "make-wide")]
            (match (lower-compiler-source-with-mode
              (compiler-lower-inline-sret-enum-constructor-source)
              (CompilerLowerMode.InlineAggregates))
              [(ResultCompilerLower.Ok enum-program _)
                (match enum-program
                  [(CompilerIrProgram.Program _ enum-functions _)
                    (and
                      (= struct-copy-count 0)
                      (=
                        (lower-test-function-copy-bytes-count
                          enum-functions
                          "make-wide-choice")
                        0))])]
              [(ResultCompilerLower.Err _) false]))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-sret-enum-match-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-sret-enum-match-constructor-source)
    (CompilerLowerMode.InlineAggregates))
    [(ResultCompilerLower.Ok constructor-program _)
      (match constructor-program
        [(CompilerIrProgram.Program _ constructor-functions _)
          (let
            [constructor-copy-count : i64
              (lower-test-function-copy-bytes-count
                constructor-functions
                "from-choice")]
            [constructor-phi-count : i64
              (lower-test-function-phi-count
                constructor-functions
                "from-choice")]
            (match (lower-compiler-source-with-mode
              (compiler-lower-inline-sret-enum-match-generic-source)
              (CompilerLowerMode.InlineAggregates))
              [(ResultCompilerLower.Ok generic-program _)
                (match generic-program
                  [(CompilerIrProgram.Program _ generic-functions _)
                    (and
                      (= constructor-copy-count 0)
                      (= constructor-phi-count 0)
                      (>
                        (lower-test-function-copy-bytes-count
                          generic-functions
                          "from-choice")
                        0)
                      (=
                        (lower-test-function-phi-count
                          generic-functions
                          "from-choice")
                        0))])]
              [(ResultCompilerLower.Err _) false]))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-hot-loop-struct-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-inline-hot-loop-struct-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (> (lower-test-function-branch-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-direct-store-copy-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-direct-store-source)
    (CompilerLowerMode.InlineAggregates))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-copy-bytes-count functions "direct-field")
              0)
            (= (lower-test-function-copy-bytes-count functions "direct-init") 0)
            (=
              (lower-test-function-copy-bytes-count
                functions
                "direct-dyn-array")
              0)
            (=
              (lower-test-function-copy-bytes-count
                functions
                "direct-fixed-array")
              0)
            (>
              (lower-test-function-copy-bytes-count
                functions
                "direct-fixed-literal")
              0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-enum-layout-cache-order-ok?) : bool
  (and
    (compiler-lower-ok?
      (compiler-lower-inline-enum-layout-cache-order-source-a))
    (compiler-lower-ok?
      (compiler-lower-inline-enum-layout-cache-order-source-b))))

(define (compiler-lower-inline-aggregate-tests-ok?) : bool
  (and
    (compiler-lower-inline-struct-shape-ok?)
    (compiler-lower-inline-enum-shape-ok?)
    (compiler-lower-inline-boxed-recursive-shape-ok?)
    (compiler-lower-inline-imported-enum-payload-ok?)
    (compiler-lower-inline-aggregate-copy-shape-ok?)
    (compiler-lower-inline-sret-constructor-copy-shape-ok?)
    (compiler-lower-inline-sret-enum-match-shape-ok?)
    (compiler-lower-inline-hot-loop-struct-shape-ok?)
    (compiler-lower-inline-direct-store-copy-shape-ok?)
    (compiler-lower-inline-enum-layout-cache-order-ok?)
    (compiler-lower-inline-error-ok?
      (compiler-lower-inline-recursive-error-source)
      "typecheck: inline aggregate layout cycle BadTree -> BadTree; insert (Box BadTree) at the recursive edge")))

(define (compiler-lower-generated-decl-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Nothing) (Circle i64) (Pair Point))
(define (make-point [x : i64] [y : i64]) : Point
  (Point x y))
(define (get-y [p : Point]) : i64
  (struct-get p y))
(define (make-pair [x : i64]) : Shape
  (Pair (Point x (+ x 1))))
(define (main) : i64
  (get-y (make-point 20 22)))")

(define (compiler-lower-repr-c-source) : String
  "(defstruct Inner
  (:repr c)
  (a u8)
  (b i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail u16))
(define (main) : i64
  (let
    [inner : Inner (Inner (cast 1 : u8) (cast 41 : i32))]
    [outer : Outer (Outer (cast 2 : u8) inner (cast 3 : u16))]
    (+
      (cast (struct-get (struct-get outer inner) b) : i64)
      (cast (struct-get outer tail) : i64))))")

(define (compiler-lower-enum-match-source) : String
  "(defenum Maybe (None) (Some i64) (Pair i64 i64))
(define (score [m : Maybe]) : i64
  (match m
    [Maybe.None 0]
    [(Maybe.Some v) (+ v 1)]
    [(Maybe.Pair left _) left]))
(define (zero-call [m : Maybe]) : i64
  (match m
    [(Maybe.None) 0]
    [_ 1]))
(define (or-zero [m : Maybe]) : i64
  (match m
    [(Maybe.Some v) v]
    [_ 0]))
(define (touch [m : Maybe]) : unit
  (match m
    [Maybe.None unit]
    [(Maybe.Some _) unit]
    [(Maybe.Pair _ _) unit]))
(define (main) : i64
  (+ (score (Maybe.Some 4))
     (+ (zero-call Maybe.None) (or-zero (Maybe.Pair 3 4)))))")

;; Pins the classic exhaustive lowering policy: only the first of two explicit
;; variants is compared; the final variant is direct fallthrough, with no
;; abort/trap materialized by lowering.
(define (compiler-lower-two-variant-fallthrough-source) : String
  "(defenum Two (First) (Second))
(define (score [value : Two]) : i64
  (match value
    [Two.First 10]
    [Two.Second 20]))
(define (main) : i64 0)")

(define (compiler-lower-total-enum-provenance-source) : String
  "(defenum Six (A) (B) (C) (D) (E) (F))
(define (large [value : Six]) : i64
  (match value
    [Six.A 0]
    [Six.B 1]
    [Six.C 2]
    [Six.D 3]
    [Six.E 4]
    [Six.F 5]))
(defenum Small (Left) (Right))
(define (small [value : Small]) : i64
  (match value
    [Small.Left 10]
    [Small.Right 20]))
(defenum Outer (Wrap Six) (Empty))
(define (nested [value : Outer]) : i64
  (match value
    [(Outer.Wrap inner)
      (match inner
        [Six.A 20]
        [Six.B 21]
        [Six.C 22]
        [Six.D 23]
        [Six.E 24]
        [Six.F 25])]
    [Outer.Empty 30]))
(defenum Seven (P0) (P1) (P2) (P3) (P4) (P5) (P6))
(define (partial [value : Seven]) : i64
  (match value
    [Seven.P0 40]
    [Seven.P1 41]
    [Seven.P2 42]
    [Seven.P3 43]
    [Seven.P4 44]
    [_ 45]))
(define (main) : i64 0)")

;; A refutable literal payload subpattern: `(Some 0)` tests the payload
;; and, on mismatch, falls through to the `(Some n)` binding arm. The trailing
;; `(Some n)` keeps the match exhaustive.
(define (compiler-lower-enum-literal-payload-source) : String
  "(defenum Maybe (None) (Some i64))
(define (classify [m : Maybe]) : i64
  (match m
    [(Some 0) 100]
    [(Some n) n]
    [None 5]))
(define (main) : i64 0)")

;; A refutable nested-variant payload subpattern: `(Wrap (A n))` tests
;; the inner enum's tag and, on mismatch, falls through to `(Wrap inner)` (the
;; irrefutable Wrap arm keeps the match exhaustive).
(define (compiler-lower-enum-nested-payload-source) : String
  "(defenum Inner (A i64) (B i64))
(defenum Outer (Wrap Inner) (Empty))
(define (classify [o : Outer]) : i64
  (match o
    [(Wrap (A n)) n]
    [(Wrap inner) 50]
    [Empty 0]))
(define (main) : i64 0)")

(define (compiler-lower-enum-string-literal-payload-source) : String
  "(defenum Token (TIdent String) (TEnd))
(define (classify [t : Token]) : i64
  (match t
    [(TIdent \"if\") 10]
    [(TIdent _) 1]
    [TEnd 0]))
(define (main) : i64 0)")

(define (compiler-lower-borrowed-enum-match-source) : String
  "(defenum Maybe (None) (Some i64))
(define (take [v : (& m i64)]) : i64 41)
(define (score [m : Maybe]) : i64
  (match (& m)
    [(Some v) (take v)]
    [None 0]))
(define (slot-score [items : (Array Maybe 2)]) : i64
  (match (& (array-ref items 0))
    [(Some v) (take v)]
    [None 0]))
(define (main) : i64
  (let [items : (Array Maybe 2) (array (Some 9) None)]
    (+ (score (Some 7)) (slot-score items))))")

(define (compiler-lower-borrowed-enum-match-ref-struct-array-source) : String
  "(defenum Slot (Empty) (Occupied i64))
(defstruct Bag (slots (Array Slot)))
(defenum SlotLookup (:lifetimes bag) (Missing) (Found (& bag i64)))
(define (take [v : (& bag i64)]) : i64 41)
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) SlotLookup.Missing)
(define (slot-found [value : (& bag i64)]) : (SlotLookup bag) (SlotLookup.Found value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref (struct-get bag slots) 0))
    [(Occupied v) (let [same : (& bag i64) v] (slot-found same))]
    [Empty (slot-missing bag)]))
(define (score [bag : (& bag Bag)]) : i64
  (match (& (array-ref (struct-get bag slots) 0))
    [(Occupied v) (take v)]
    [Empty 0]))
(define (main) : i64
  (let
    [slots : (Array Slot) (make-array Slot 1)]
    (begin
      (array-set! slots 0 (Occupied 9))
      (let [bag : Bag (Bag slots)]
        (+ (score (& bag))
          (match (lookup (& bag))
            [(SlotLookup.Found v) (take v)]
            [SlotLookup.Missing 0]))))))")

(define (compiler-lower-borrowed-enum-match-str-source) : String
  "(defenum Item (Named String) (Empty))
(define (score-item [item : Item]) : i64
  (match (& item)
    [(Named s) (__tl_string_length s)]
    [Empty 0]))
(define (main [text : String]) : i64 (score-item (Named text)))")

(define (compiler-lower-borrowed-enum-match-nested-source) : String
  "(defenum Inner (A i64) (B i64))
(defenum Outer (Wrap Inner) (Empty))
(define (take [v : (& o i64)]) : i64 7)
(define (score [o : Outer]) : i64
  (match (& o)
    [(Wrap (A 0)) 10]
    [(Wrap (A n)) (take n)]
    [(Wrap _) 1]
    [Empty 0]))
(define (main) : i64 (score (Wrap (A 2))))")

(define (compiler-lower-result-try-source) : String
  "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (read [flag : bool] [n : i64]) : result_i64_string.Result
  (if flag (result_i64_string.Ok n) (result_i64_string.Err \"read failed\")))
(define (sum [a : bool] [b : bool]) : result_i64_string.Result
  (let [x : i64 (try (read a 40))]
    [y : i64 0]
    (begin
      (set! y (try (read b 2)))
      (result_i64_string.Ok (+ x y)))))
(define (chain [flag : bool]) : result_i64_string.Result
  (result_i64_string.Ok (try (sum flag true))))
(define (main [flag : bool]) : result_i64_string.Result
  (chain flag))")

(define (compiler-lower-option-try-source) : String
  "(import stdlib.option)
(import (option.option i64) as option_i64)
(define (read [flag : bool] [n : i64]) : option_i64.Option
  (if flag (option_i64.Some n) option_i64.None))
(define (main [a : bool] [b : bool]) : option_i64.Option
  (let [x : i64 (try (read a 40))]
    (option_i64.Some (+ x (try (read b 2))))))")

(define (compiler-lower-return-source) : String
  "(define (main [flag : bool]) : i64
  (begin
    (if flag (return 7) unit)
    42))")

(define (compiler-lower-return-with-arena-source) : String
  "(define (main [flag : bool]) : i64
  (with-arena r
    (begin
      (if flag (return 7) unit)
      42)))")

(define (compiler-lower-resource-with-source) : String
  "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (open-a [ok : bool]) : result_i64_string.Result
  (if ok (result_i64_string.Ok 10) (result_i64_string.Err \"open a\")))
(define (open-b [ok : bool]) : result_i64_string.Result
  (if ok (result_i64_string.Ok 32) (result_i64_string.Err \"open b\")))
(define (use-a [ok : bool] [h : i64]) : result_i64_string.Result
  (if ok (result_i64_string.Ok h) (result_i64_string.Err \"use a\")))
(define (close-a [h : i64]) : unit unit)
(define (close-b [h : i64]) : unit unit)
(define (main [a-ok : bool] [b-ok : bool] [use-ok : bool]) : result_i64_string.Result
  (with ([a (try (open-a a-ok)) close-a]
         [b (try (open-b b-ok)) close-b])
    (result_i64_string.Ok (+ (try (use-a use-ok a)) b))))")

(define (compiler-lower-resource-with-nested-source) : String
  "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (close-a [h : i64]) : unit unit)
(define (close-b [h : i64]) : unit unit)
(define (main) : result_i64_string.Result
  (with ([a 10 close-a])
    (with ([b 32 close-b])
      (result_i64_string.Ok (+ a b)))))")

(define (compiler-lower-cleanup-struct-source) : String
  "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (close-fd [fd : i64]) : unit unit)
(define (use-fd [ok : bool] [fd : i64]) : result_i64_string.Result
  (if ok (result_i64_string.Ok fd) (result_i64_string.Err \"use fd\")))
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main [use-ok : bool]) : result_i64_string.Result
  (with ([h (FileHandle 10) cleanup-file-handle])
    (result_i64_string.Ok (try (use-fd use-ok (struct-get h fd))))))")

(define (compiler-lower-cleanup-struct-nested-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(define (close-buffer [buffer : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct BufferedFile
  (:cleanup cleanup-buffered-file)
  (handle FileHandle (:owned))
  (buffer i64 (:cleanup close-buffer)))
(define (main) : i64
  (with ([b (BufferedFile (FileHandle 10) 20) cleanup-buffered-file])
    42))")

(define (compiler-lower-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok _ _) true]
    [(ResultCompilerLower.Err _) false]))

;; Provenance side-table smoke: the smoke source defines two functions
;;
;; (`inc` on line 3 and `main` on line 4 with its body on line 5). After lowering
;;
;; the function spans table must hold exactly those two entries, keyed by name,
;;
;; recording each function body's source start line. The instruction/value span
;;
;; side table should also receive entries from expression-backed emits.
(define (compiler-lower-span-start-line-ok?
  [spans : CompilerSourceSpans]
  [name : String]
  [want-line : i64]) : bool
  (match (compiler-source-spans-lookup
    spans
    (compiler-ir-symbol-typed-id (ci.intern name)))
    [(CompilerMaybeSourceSpan.Some span)
      (= (ast-source-span-start-line span) want-line)]
    [(CompilerMaybeSourceSpan.No) false]))

(define (compiler-lower-spans-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok _ spans)
      (and
        (= (compiler-source-spans-count spans) 2)
        (compiler-lower-span-start-line-ok? spans "inc" 3)
        (compiler-lower-span-start-line-ok? spans "main" 5))]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (let
        [summary : CompilerIrSummary (compiler-ir-program-summary program)]
        [ok : bool true]
        (begin
          ;; The tail-position `if` returns directly from both arms, so the
          ;; lowered program has no merge block, merge phi, or phi result var.
          (if (= (compiler-ir-summary-globals summary) 1)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-functions summary) 2)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-externs summary) 1)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-blocks summary) 7)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-instructions summary) 20)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-vars summary) 13)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-empty-blocks summary) 0)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-max-instructions-function summary) 17)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-max-instructions-block summary) 6)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-call-arg-entries summary) 1)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-phi-input-entries summary) 0)
            unit
            (set! ok false))
          ok))]
    [(ResultCompilerLower.Err _) false]))

;; Count `CompilerIrInstr.Phi` nodes, to assert the merge-phi shape of lowered scalar
;; matches: value-returning matches emit a merge phi, unit matches none.
(define (lower-test-instr-phi-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Phi _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-load-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Load _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-branch-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Branch _ _ _) 1]
    [(CompilerIrInstr.TotalEnumBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-total-enum-branch-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.TotalEnumBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bounds-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.BoundsCheck _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-return-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Return _) 1]
    [_ 0]))

(define (lower-test-instr-call-count [instr : CompilerIrInstr] [name : String]) : i64
  (match instr
    [(CompilerIrInstr.Call _ call-name _ _)
      (if (string.eq (compiler-ir-symbol-text call-name) name)
        1
        0)]
    [(CompilerIrInstr.CallCAbiStoreResult payload-box)
      (let
        [call-name (struct-get (box-get payload-box) name)]
        (if (string.eq (compiler-ir-symbol-text call-name) name)
          1
          0))]
    [_ 0]))

(define (lower-test-instr-cpuid-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.CpuId _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-xgetbv-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Xgetbv _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-call-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.CallIndirect _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-tail-call-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.TailCallIndirect _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-c-call-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.CallIndirectC _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-unit-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.CallIndirect _ _ _ ty)
      (match ty
        [(AstType.Unit) 1]
        [_ 0])]
    [(CompilerIrInstr.TailCallIndirect _ _ ty)
      (match ty
        [(AstType.Unit) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-value-function-count
  [value : CompilerIrValue]
  [name : String]) : i64
  (match value
    [(CompilerIrValue.Function found)
      (if (string.eq (compiler-ir-symbol-text found) name)
        1
        0)]
    [_ 0]))

(define (lower-test-call-args-function-count
  [args : CompilerIrCallArgs]
  [name : String]) : i64
  (match args
    [(CompilerIrCallArgs.Nil) 0]
    [(CompilerIrCallArgs.One value)
      (lower-test-value-function-count value name)]
    [(CompilerIrCallArgs.Two a b)
      (+
        (lower-test-value-function-count a name)
        (lower-test-value-function-count b name))]
    [(CompilerIrCallArgs.Array values)
      (lower-test-call-args-array-function-count values name 0)]))

(define (lower-test-call-args-array-function-count
  [values : (Array CompilerIrValue)]
  [name : String]
  [index : i64]) : i64
  (if (>= index (array-length values))
    0
    (+
      (lower-test-value-function-count (array-ref values index) name)
      (lower-test-call-args-array-function-count values name (+ index 1)))))

(define (lower-test-instr-return-function-count
  [instr : CompilerIrInstr]
  [function-name : String]) : i64
  (match instr
    [(CompilerIrInstr.Return maybe-value)
      (match maybe-value
        [(CompilerIrMaybeValue.Some value)
          (lower-test-value-function-count value function-name)]
        [(CompilerIrMaybeValue.No) 0])]
    [_ 0]))

(define (lower-test-instr-indirect-callee-function-count
  [instr : CompilerIrInstr]
  [function-name : String]) : i64
  (match instr
    [(CompilerIrInstr.CallIndirect _ func _ _)
      (lower-test-value-function-count func function-name)]
    [(CompilerIrInstr.TailCallIndirect func _ _)
      (lower-test-value-function-count func function-name)]
    [_ 0]))

(define (lower-test-instr-call-arg-function-count
  [instr : CompilerIrInstr]
  [call-name : String]
  [function-name : String]) : i64
  (match instr
    [(CompilerIrInstr.Call _ found args _)
      (if (string.eq (compiler-ir-symbol-text found) call-name)
        (lower-test-call-args-function-count args function-name)
        0)]
    [_ 0]))

(define (lower-test-instr-tail-call-count
  [instr : CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(CompilerIrInstr.TailCall call-name _ _)
      (if (string.eq (compiler-ir-symbol-text call-name) name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-store-ptr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.StorePtr _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-copy-bytes-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.CopyBytes _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-alloc-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Alloc _ _) 1]
    [_ 0]))

(define (lower-test-instr-addr-of-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.AddrOf _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-load-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.VectorLoad _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.VectorBinOp _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-op-count
  [instr : CompilerIrInstr]
  [want : CompilerIrBinOp]) : i64
  (match instr
    [(CompilerIrInstr.VectorBinOp payload-box)
      (let
        [op (struct-get (box-get payload-box) op)]
        (if (lower-test-binop-same? op want)
          1
          0))]
    [_ 0]))

(define (lower-test-instr-vector-reduce-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.VectorReduce _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-store-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.VectorStore _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-load-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.PredicatedLoad _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-store-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.PredicatedStore _) 1]
    [_ 0]))

(define (lower-test-instr-select-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Select _) 1]
    [_ 0]))

(define (lower-test-instr-tail-mask-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.TailMask _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-spmd-call-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.SpmdCall _) 1]
    [_ 0]))

(define (lower-test-instr-seq-spmd-call-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-spmd-call-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-spmd-call-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-spmd-call-count instrs)
            (lower-test-blocks-spmd-call-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq) (lower-test-block-seq-spmd-call-count seq)]))

(define (lower-test-block-seq-spmd-call-count [blocks : CompilerIrBlockSeq]) : i64
  (let
    [slots : (Array CompilerIrBlock) (struct-get blocks slots)]
    [count : i64 (struct-get blocks len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (array-ref slots index)
            [(CompilerIrBlock.Block _ instrs)
              (set! acc (+ acc (lower-test-instr-seq-spmd-call-count instrs)))])
          (set! index (+ index 1))))
      acc)))

(define (lower-test-function-spmd-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-spmd-call-count blocks)
            (lower-test-function-spmd-call-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-seq-spmd-call-count seq name)]))

(define (lower-test-function-seq-spmd-call-count
  [funcs : CompilerIrFunctionSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrFunction) (struct-get funcs slots)]
    [count : i64 (struct-get funcs len)]
    [index : i64 0]
    [result : i64 (- 0 1)]
    (begin
      (while (and (< index count) (< result 0))
        (begin
          (match (array-ref slots index)
            [(CompilerIrFunction.Function fname _ _ _ blocks)
              (if (string.eq (compiler-ir-symbol-text fname) name)
                (set! result (lower-test-blocks-spmd-call-count blocks))
                unit)])
          (set! index (+ index 1))))
      result)))

(define (lower-test-vector-shape?
  [actual-lanes : i64]
  [actual-ty : AstType]
  [lanes : i64]
  [elem-ty : AstType]) : bool
  (and (= actual-lanes lanes) (tc-type-eq actual-ty elem-ty)))

(define (lower-test-instr-vector-shape-count
  [instr : CompilerIrInstr]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match instr
    [(CompilerIrInstr.VectorLoad _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(CompilerIrInstr.VectorBinOp payload-box)
      (let
        [actual-lanes (struct-get (box-get payload-box) lanes)]
        [actual-ty (struct-get (box-get payload-box) ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(CompilerIrInstr.VectorReduce _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(CompilerIrInstr.VectorStore payload-box)
      (let
        [actual-lanes (struct-get (box-get payload-box) lanes)]
        [actual-ty (struct-get (box-get payload-box) ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(CompilerIrInstr.PredicatedLoad payload-box)
      (let
        [actual-lanes (struct-get (box-get payload-box) lanes)]
        [actual-ty (struct-get (box-get payload-box) ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(CompilerIrInstr.GatherLoad payload-box)
      (let
        [actual-lanes (struct-get (box-get payload-box) lanes)]
        [actual-ty (struct-get (box-get payload-box) ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(CompilerIrInstr.PredicatedStore payload-box)
      (let
        [actual-lanes (struct-get (box-get payload-box) lanes)]
        [actual-ty (struct-get (box-get payload-box) ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(CompilerIrInstr.Select payload-box)
      (let
        [actual-lanes (struct-get (box-get payload-box) lanes)]
        [actual-ty (struct-get (box-get payload-box) ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(CompilerIrInstr.Splat _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-u64-mov-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Mov _ _ ty)
      (match ty
        [(AstType.U64) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-binop-same?
  [actual : CompilerIrBinOp]
  [want : CompilerIrBinOp]) : bool
  (match actual
    [(CompilerIrBinOp.Add)
      (match want
        [(CompilerIrBinOp.Add) true]
        [_ false])]
    [(CompilerIrBinOp.Sub)
      (match want
        [(CompilerIrBinOp.Sub) true]
        [_ false])]
    [(CompilerIrBinOp.Mul)
      (match want
        [(CompilerIrBinOp.Mul) true]
        [_ false])]
    [(CompilerIrBinOp.Div)
      (match want
        [(CompilerIrBinOp.Div) true]
        [_ false])]
    [(CompilerIrBinOp.Mod)
      (match want
        [(CompilerIrBinOp.Mod) true]
        [_ false])]
    [(CompilerIrBinOp.SafeDiv)
      (match want
        [(CompilerIrBinOp.SafeDiv) true]
        [_ false])]
    [(CompilerIrBinOp.SafeMod)
      (match want
        [(CompilerIrBinOp.SafeMod) true]
        [_ false])]
    [(CompilerIrBinOp.Eq)
      (match want
        [(CompilerIrBinOp.Eq) true]
        [_ false])]
    [(CompilerIrBinOp.Ne)
      (match want
        [(CompilerIrBinOp.Ne) true]
        [_ false])]
    [(CompilerIrBinOp.Lt)
      (match want
        [(CompilerIrBinOp.Lt) true]
        [_ false])]
    [(CompilerIrBinOp.Le)
      (match want
        [(CompilerIrBinOp.Le) true]
        [_ false])]
    [(CompilerIrBinOp.Gt)
      (match want
        [(CompilerIrBinOp.Gt) true]
        [_ false])]
    [(CompilerIrBinOp.Ge)
      (match want
        [(CompilerIrBinOp.Ge) true]
        [_ false])]
    [(CompilerIrBinOp.BitTestEq)
      (match want
        [(CompilerIrBinOp.BitTestEq) true]
        [_ false])]
    [(CompilerIrBinOp.BitTestNe)
      (match want
        [(CompilerIrBinOp.BitTestNe) true]
        [_ false])]
    [(CompilerIrBinOp.And)
      (match want
        [(CompilerIrBinOp.And) true]
        [_ false])]
    [(CompilerIrBinOp.Or)
      (match want
        [(CompilerIrBinOp.Or) true]
        [_ false])]
    [(CompilerIrBinOp.BitAnd)
      (match want
        [(CompilerIrBinOp.BitAnd) true]
        [_ false])]
    [(CompilerIrBinOp.BitOr)
      (match want
        [(CompilerIrBinOp.BitOr) true]
        [_ false])]
    [(CompilerIrBinOp.BitXor)
      (match want
        [(CompilerIrBinOp.BitXor) true]
        [_ false])]
    [(CompilerIrBinOp.Shl)
      (match want
        [(CompilerIrBinOp.Shl) true]
        [_ false])]
    [(CompilerIrBinOp.Shr)
      (match want
        [(CompilerIrBinOp.Shr) true]
        [_ false])]))

(define (lower-test-instr-binop-op-count
  [instr : CompilerIrInstr]
  [op : CompilerIrBinOp]) : i64
  (match instr
    [(CompilerIrInstr.BinOp _ actual _ _ _)
      (if (lower-test-binop-same? actual op)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-i64-binop-op-count
  [instr : CompilerIrInstr]
  [op : CompilerIrBinOp]) : i64
  (match instr
    [(CompilerIrInstr.BinOp _ actual _ _ ty)
      (if (and
        (lower-test-binop-same? actual op)
        (match ty
          [(AstType.I64) true]
          [_ false]))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-cast-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Cast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bitcast-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.Bitcast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-store-global-count
  [instr : CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(CompilerIrInstr.Store store-name _ _)
      (if (string.eq (compiler-ir-symbol-text store-name) name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-call-name? [instr : CompilerIrInstr] [name : String]) : bool
  (match instr
    [(CompilerIrInstr.Call _ call-name _ _)
      (string.eq (compiler-ir-symbol-text call-name) name)]
    [(CompilerIrInstr.TailCall call-name _ _)
      (string.eq (compiler-ir-symbol-text call-name) name)]
    [_ false]))

(define (lower-test-instr-seq-phi-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-phi-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-load-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-load-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-branch-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-branch-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-total-enum-branch-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-total-enum-branch-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-bounds-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-bounds-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-return-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-return-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-count
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-call-count (array-ref slots index) name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-before?
  [instrs : CompilerIrInstrSeq]
  [first : String]
  [second : String]) : bool
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [seen-first : bool false]
    [done : bool false]
    [result : bool false]
    (begin
      (while (and (< index count) (not done))
        (let
          [instr : CompilerIrInstr (array-ref slots index)]
          (begin
            (if (lower-test-instr-call-name? instr second)
              (begin
                (set! result seen-first)
                (set! done true))
              (if (lower-test-instr-call-name? instr first)
                (set! seen-first true)
                unit))
            (set! index (+ index 1)))))
      result)))

(define (lower-test-instr-seq-cpuid-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-cpuid-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-xgetbv-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-xgetbv-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-call-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-call-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-tail-call-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-tail-call-count
                (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-c-call-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-c-call-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-unit-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-unit-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-return-function-count
  [instrs : CompilerIrInstrSeq]
  [function-name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-return-function-count
                (array-ref slots index)
                function-name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-callee-function-count
  [instrs : CompilerIrInstrSeq]
  [function-name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-callee-function-count
                (array-ref slots index)
                function-name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-arg-function-count
  [instrs : CompilerIrInstrSeq]
  [call-name : String]
  [function-name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-call-arg-function-count
                (array-ref slots index)
                call-name
                function-name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-tail-call-count
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-tail-call-count (array-ref slots index) name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-store-ptr-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-store-ptr-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-copy-bytes-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-copy-bytes-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-alloc-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-alloc-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-addr-of-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-addr-of-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-load-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-vector-load-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-binop-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-binop-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-binop-op-count
  [instrs : CompilerIrInstrSeq]
  [want : CompilerIrBinOp]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-binop-op-count
                (array-ref slots index)
                want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-reduce-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-reduce-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-store-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-store-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-predicated-load-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-predicated-load-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-predicated-store-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-predicated-store-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-select-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-select-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-tail-mask-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-tail-mask-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-shape-count
  [instrs : CompilerIrInstrSeq]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-shape-count
                (array-ref slots index)
                lanes
                elem-ty)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-u64-mov-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-u64-mov-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-binop-op-count
  [instrs : CompilerIrInstrSeq]
  [op : CompilerIrBinOp]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-binop-op-count (array-ref slots index) op)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-i64-binop-op-count
  [instrs : CompilerIrInstrSeq]
  [op : CompilerIrBinOp]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-i64-binop-op-count (array-ref slots index) op)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-cast-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-cast-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-bitcast-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-bitcast-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-store-global-count
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-store-global-count (array-ref slots index) name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-phi-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-phi-count instrs)
            (lower-test-blocks-phi-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-phi-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-load-count instrs)
            (lower-test-blocks-load-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-load-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-branch-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-branch-count instrs)
            (lower-test-blocks-branch-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-branch-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-total-enum-branch-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-total-enum-branch-count instrs)
            (lower-test-blocks-total-enum-branch-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-total-enum-branch-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-bounds-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-bounds-count instrs)
            (lower-test-blocks-bounds-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-bounds-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-return-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-return-count instrs)
            (lower-test-blocks-return-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-return-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-call-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-call-count instrs name)
            (lower-test-blocks-call-count (box-get rest) name))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-call-count (compiler-ir-block-seq-to-list seq) name)]))

(define (lower-test-blocks-call-before?
  [blocks : CompilerIrBlockList]
  [first : String]
  [second : String]) : bool
  (match blocks
    [(CompilerIrBlockList.Nil) false]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (if (lower-test-instr-seq-call-before? instrs first second)
            true
            (lower-test-blocks-call-before? (box-get rest) first second))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-call-before?
        (compiler-ir-block-seq-to-list seq)
        first
        second)]))

(define (lower-test-blocks-cpuid-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-cpuid-count instrs)
            (lower-test-blocks-cpuid-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-cpuid-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-xgetbv-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-xgetbv-count instrs)
            (lower-test-blocks-xgetbv-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-xgetbv-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-call-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-call-count instrs)
            (lower-test-blocks-indirect-call-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-call-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-tail-call-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-tail-call-count instrs)
            (lower-test-blocks-indirect-tail-call-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-tail-call-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-c-call-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-c-call-count instrs)
            (lower-test-blocks-indirect-c-call-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-c-call-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-unit-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-unit-count instrs)
            (lower-test-blocks-indirect-unit-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-unit-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-return-function-count
  [blocks : CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-return-function-count instrs function-name)
            (lower-test-blocks-return-function-count
              (box-get rest)
              function-name))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-return-function-count
        (compiler-ir-block-seq-to-list seq)
        function-name)]))

(define (lower-test-blocks-indirect-callee-function-count
  [blocks : CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-callee-function-count
              instrs
              function-name)
            (lower-test-blocks-indirect-callee-function-count
              (box-get rest)
              function-name))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-callee-function-count
        (compiler-ir-block-seq-to-list seq)
        function-name)]))

(define (lower-test-blocks-call-arg-function-count
  [blocks : CompilerIrBlockList]
  [call-name : String]
  [function-name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-call-arg-function-count
              instrs
              call-name
              function-name)
            (lower-test-blocks-call-arg-function-count
              (box-get rest)
              call-name
              function-name))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-call-arg-function-count
        (compiler-ir-block-seq-to-list seq)
        call-name
        function-name)]))

(define (lower-test-blocks-tail-call-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-tail-call-count instrs name)
            (lower-test-blocks-tail-call-count (box-get rest) name))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-tail-call-count
        (compiler-ir-block-seq-to-list seq)
        name)]))

(define (lower-test-blocks-store-ptr-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-store-ptr-count instrs)
            (lower-test-blocks-store-ptr-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-store-ptr-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-copy-bytes-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-copy-bytes-count instrs)
            (lower-test-blocks-copy-bytes-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-copy-bytes-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-alloc-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-alloc-count instrs)
            (lower-test-blocks-alloc-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-alloc-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-addr-of-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-addr-of-count instrs)
            (lower-test-blocks-addr-of-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-addr-of-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-load-count instrs)
            (lower-test-blocks-vector-load-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-load-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-binop-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-binop-count instrs)
            (lower-test-blocks-vector-binop-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-binop-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-binop-op-count
  [blocks : CompilerIrBlockList]
  [want : CompilerIrBinOp]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-binop-op-count instrs want)
            (lower-test-blocks-vector-binop-op-count (box-get rest) want))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-binop-op-count
        (compiler-ir-block-seq-to-list seq)
        want)]))

(define (lower-test-blocks-vector-reduce-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-reduce-count instrs)
            (lower-test-blocks-vector-reduce-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-reduce-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-store-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-store-count instrs)
            (lower-test-blocks-vector-store-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-store-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-predicated-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-predicated-load-count instrs)
            (lower-test-blocks-predicated-load-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-predicated-load-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-predicated-store-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-predicated-store-count instrs)
            (lower-test-blocks-predicated-store-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-predicated-store-count
        (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-select-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-select-count instrs)
            (lower-test-blocks-select-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-select-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-tail-mask-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-tail-mask-count instrs)
            (lower-test-blocks-tail-mask-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-tail-mask-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-shape-count
  [blocks : CompilerIrBlockList]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-shape-count instrs lanes elem-ty)
            (lower-test-blocks-vector-shape-count (box-get rest) lanes elem-ty))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-shape-count
        (compiler-ir-block-seq-to-list seq)
        lanes
        elem-ty)]))

(define (lower-test-blocks-u64-mov-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-u64-mov-count instrs)
            (lower-test-blocks-u64-mov-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-u64-mov-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-binop-op-count
  [blocks : CompilerIrBlockList]
  [op : CompilerIrBinOp]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-binop-op-count instrs op)
            (lower-test-blocks-binop-op-count (box-get rest) op))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-binop-op-count (compiler-ir-block-seq-to-list seq) op)]))

(define (lower-test-blocks-i64-binop-op-count
  [blocks : CompilerIrBlockList]
  [op : CompilerIrBinOp]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-i64-binop-op-count instrs op)
            (lower-test-blocks-i64-binop-op-count (box-get rest) op))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-i64-binop-op-count
        (compiler-ir-block-seq-to-list seq)
        op)]))

(define (lower-test-blocks-cast-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-cast-count instrs)
            (lower-test-blocks-cast-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-cast-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-bitcast-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-bitcast-count instrs)
            (lower-test-blocks-bitcast-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-bitcast-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-store-global-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-store-global-count instrs name)
            (lower-test-blocks-store-global-count (box-get rest) name))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-store-global-count
        (compiler-ir-block-seq-to-list seq)
        name)]))

;; Phi count of the function named `name`, or -1 when no such function exists
;; (so a missing function fails both the `> 0` and `= 0` assertions below).
(define (lower-test-function-defined?
  [funcs : CompilerIrFunctionList]
  [name : String]) : bool
  (match funcs
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ _)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            true
            (lower-test-function-defined? (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-defined? (compiler-ir-function-seq-to-list seq) name)]))

(define (lower-test-function-phi-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-phi-count blocks)
            (lower-test-function-phi-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-phi-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-load-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-load-count blocks)
            (lower-test-function-load-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-load-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-branch-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-branch-count blocks)
            (lower-test-function-branch-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-branch-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-total-enum-branch-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-total-enum-branch-count blocks)
            (lower-test-function-total-enum-branch-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-total-enum-branch-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-bounds-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-bounds-count blocks)
            (lower-test-function-bounds-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-bounds-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-return-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-return-count blocks)
            (lower-test-function-return-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-return-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-functions-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-call-count blocks name)
            (lower-test-functions-call-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-call-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-functions-branch-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-branch-count blocks)
            (lower-test-functions-branch-count (box-get rest)))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-branch-count (compiler-ir-function-seq-to-list seq))]))

(define (lower-test-functions-return-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-return-count blocks)
            (lower-test-functions-return-count (box-get rest)))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-return-count (compiler-ir-function-seq-to-list seq))]))

(define (lower-test-functions-tail-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-tail-call-count blocks name)
            (lower-test-functions-tail-call-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-tail-call-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-functions-direct-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (+
    (lower-test-functions-call-count funcs name)
    (lower-test-functions-tail-call-count funcs name)))

(define (lower-test-functions-cpuid-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-cpuid-count blocks)
            (lower-test-functions-cpuid-count (box-get rest)))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-cpuid-count (compiler-ir-function-seq-to-list seq))]))

(define (lower-test-functions-xgetbv-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-xgetbv-count blocks)
            (lower-test-functions-xgetbv-count (box-get rest)))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-xgetbv-count (compiler-ir-function-seq-to-list seq))]))

(define (lower-test-function-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-call-count blocks call-name)
            (lower-test-function-call-count (box-get rest) name call-name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-call-count
        (compiler-ir-function-seq-to-list seq)
        name
        call-name)]))

(define (lower-test-function-call-before?
  [funcs : CompilerIrFunctionList]
  [name : String]
  [first : String]
  [second : String]) : bool
  (match funcs
    [(CompilerIrFunctionList.Nil) false]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-call-before? blocks first second)
            (lower-test-function-call-before? (box-get rest) name first second))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-call-before?
        (compiler-ir-function-seq-to-list seq)
        name
        first
        second)]))

(define (lower-test-function-indirect-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-indirect-call-count blocks)
            (lower-test-function-indirect-call-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-indirect-call-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-indirect-tail-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-indirect-tail-call-count blocks)
            (lower-test-function-indirect-tail-call-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-indirect-tail-call-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-indirect-c-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-indirect-c-call-count blocks)
            (lower-test-function-indirect-c-call-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-indirect-c-call-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-indirect-unit-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-indirect-unit-count blocks)
            (lower-test-function-indirect-unit-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-indirect-unit-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-return-function-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [function-name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-return-function-count blocks function-name)
            (lower-test-function-return-function-count
              (box-get rest)
              name
              function-name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-return-function-count
        (compiler-ir-function-seq-to-list seq)
        name
        function-name)]))

(define (lower-test-function-indirect-callee-function-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [function-name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-indirect-callee-function-count
              blocks
              function-name)
            (lower-test-function-indirect-callee-function-count
              (box-get rest)
              name
              function-name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-indirect-callee-function-count
        (compiler-ir-function-seq-to-list seq)
        name
        function-name)]))

(define (lower-test-function-call-arg-function-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]
  [function-name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-call-arg-function-count
              blocks
              call-name
              function-name)
            (lower-test-function-call-arg-function-count
              (box-get rest)
              name
              call-name
              function-name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-call-arg-function-count
        (compiler-ir-function-seq-to-list seq)
        name
        call-name
        function-name)]))

(define (lower-test-function-tail-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-tail-call-count blocks call-name)
            (lower-test-function-tail-call-count (box-get rest) name call-name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-tail-call-count
        (compiler-ir-function-seq-to-list seq)
        name
        call-name)]))

(define (lower-test-function-direct-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]) : i64
  (+
    (lower-test-function-call-count funcs name call-name)
    (lower-test-function-tail-call-count funcs name call-name)))

(define (lower-test-function-store-ptr-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-store-ptr-count blocks)
            (lower-test-function-store-ptr-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-store-ptr-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-copy-bytes-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-copy-bytes-count blocks)
            (lower-test-function-copy-bytes-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-copy-bytes-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-alloc-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-alloc-count blocks)
            (lower-test-function-alloc-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-alloc-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-addr-of-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-addr-of-count blocks)
            (lower-test-function-addr-of-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-addr-of-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-vector-load-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-vector-load-count blocks)
            (lower-test-function-vector-load-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-vector-load-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-vector-binop-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-vector-binop-count blocks)
            (lower-test-function-vector-binop-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-vector-binop-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-vector-binop-op-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [want : CompilerIrBinOp]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-vector-binop-op-count blocks want)
            (lower-test-function-vector-binop-op-count (box-get rest) name want))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-vector-binop-op-count
        (compiler-ir-function-seq-to-list seq)
        name
        want)]))

(define (lower-test-function-vector-reduce-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-vector-reduce-count blocks)
            (lower-test-function-vector-reduce-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-vector-reduce-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-vector-store-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-vector-store-count blocks)
            (lower-test-function-vector-store-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-vector-store-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-predicated-load-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-predicated-load-count blocks)
            (lower-test-function-predicated-load-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-predicated-load-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-predicated-store-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-predicated-store-count blocks)
            (lower-test-function-predicated-store-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-predicated-store-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-select-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-select-count blocks)
            (lower-test-function-select-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-select-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-tail-mask-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-tail-mask-count blocks)
            (lower-test-function-tail-mask-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-tail-mask-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-vector-shape-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-vector-shape-count blocks lanes elem-ty)
            (lower-test-function-vector-shape-count
              (box-get rest)
              name
              lanes
              elem-ty))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-vector-shape-count
        (compiler-ir-function-seq-to-list seq)
        name
        lanes
        elem-ty)]))

(define (lower-test-function-u64-mov-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-u64-mov-count blocks)
            (lower-test-function-u64-mov-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-u64-mov-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-binop-op-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [op : CompilerIrBinOp]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-binop-op-count blocks op)
            (lower-test-function-binop-op-count (box-get rest) name op))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-binop-op-count
        (compiler-ir-function-seq-to-list seq)
        name
        op)]))

(define (lower-test-function-i64-binop-op-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [op : CompilerIrBinOp]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-i64-binop-op-count blocks op)
            (lower-test-function-i64-binop-op-count (box-get rest) name op))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-i64-binop-op-count
        (compiler-ir-function-seq-to-list seq)
        name
        op)]))

(define (lower-test-function-cast-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-cast-count blocks)
            (lower-test-function-cast-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-cast-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-bitcast-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-bitcast-count blocks)
            (lower-test-function-bitcast-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-bitcast-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-functions-bitcast-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function _ _ _ _ blocks)
          (+
            (lower-test-blocks-bitcast-count blocks)
            (lower-test-functions-bitcast-count (box-get rest)))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-functions-bitcast-count
        (compiler-ir-function-seq-to-list seq))]))

(define (lower-test-function-store-global-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [global-name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-store-global-count blocks global-name)
            (lower-test-function-store-global-count
              (box-get rest)
              name
              global-name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-store-global-count
        (compiler-ir-function-seq-to-list seq)
        name
        global-name)]))

(define (lower-test-global-list-has-name?
  [globals : CompilerIrGlobalList]
  [name : String]) : bool
  (match globals
    [(CompilerIrGlobalList.Nil) false]
    [(CompilerIrGlobalList.Cons global rest)
      (match global
        [(CompilerIrGlobal.Global global-name _ _)
          (if (string.eq (compiler-ir-symbol-text global-name) name)
            true
            (lower-test-global-list-has-name? (box-get rest) name))])]
    [(CompilerIrGlobalList.Array seq)
      (lower-test-global-list-has-name?
        (compiler-ir-global-seq-to-list seq)
        name)]))

(define (compiler-lower-defdispatch-thunk-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-defdispatch-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program globals functions _)
          (let
            [cache-name : String "__tl_dispatch_cache_dot"]
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            [ok : bool true]
            (begin
              (if (lower-test-global-list-has-name? globals cache-name)
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions "dot")
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions scalar-name)
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions avx2-name)
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions avx512-name)
                unit
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-scalar")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx2")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx512")
                (set! ok false))
              (if (= (lower-test-function-call-count functions "main" "dot") 1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-indirect-call-count functions "dot")
                4)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-store-global-count
                  functions
                  "dot"
                  cache-name)
                3)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-cpuid-count functions) 6)
                unit
                (set! ok false))
              (if (= (lower-test-functions-xgetbv-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "dot"
                  scalar-name)
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "dot"
                  avx2-name)
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "dot"
                  avx512-name)
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-defdispatch-shared-helper-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-defdispatch-shared-helper-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            [ok : bool true]
            (begin
              (if (lower-test-function-defined? functions "dispatch-helper")
                unit
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-scalar")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx2")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx512")
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  functions
                  scalar-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  functions
                  avx2-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  functions
                  avx512-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-generated-path-source) : String
  "(defstruct Point (x i64))
(defstruct Point (x i64))
(define (after [x : i64]) : i64 (+ x 1))
(define (main) : i64 (after 41))")

(define (compiler-lower-generated-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "gen.tl"
    (ast-decl-root-path-cons
      "gen.tl"
      (ast-decl-root-path-cons
        "lib.tl"
        (ast-decl-root-path-cons "app.tl" (ast-decl-path-list-new))))))

(define (compiler-lower-generated-paths-preserved-ok?) : bool
  (match (parse-ast-source (compiler-lower-generated-path-source))
    [(ResultAstProgram.Ok program)
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [args : AstExprList (ast-expr-list-new)]
            (begin
              (ast-expr-list-push
                (&mut args)
                (ast-node-push
                  (AstExpr.Literal (ast-lit-generated-string "same"))))
              (array-set!
                (struct-get decls slots)
                (struct-get decls offset)
                (ast-decl-comptime-decl-with-meta
                  (AstGeneratedDeclMeta.Some "point-family" "Point" args "")
                  (ast-decl-list-get (& decls) 0 (ast-decl-fallback))))
              (array-set!
                (struct-get decls slots)
                (+ (struct-get decls offset) 1)
                (ast-decl-comptime-decl-with-meta
                  (AstGeneratedDeclMeta.Some "point-family" "Point" args "")
                  (ast-decl-list-get (& decls) 1 (ast-decl-fallback))))
              (match (lower-compiler-program-with-decl-paths
                "app.tl"
                program
                (compiler-lower-generated-paths))
                [(ResultCompilerLower.Ok lowered _)
                  (match lowered
                    [(CompilerIrProgram.Program _ functions _)
                      (and
                        (lower-test-function-defined? functions "lib.tl::after")
                        (lower-test-function-defined? functions "main")
                        (=
                          (lower-test-function-direct-call-count
                            functions
                            "main"
                            "lib.tl::after")
                          1))])]
                [(ResultCompilerLower.Err _) false])))])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-module-symbol-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x answer))
(define (main) : i64 (inc answer))")

(define (compiler-lower-module-symbol-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "lib.tl"
    (ast-decl-root-path-cons
      "lib.tl"
      (ast-decl-root-path-cons "app.tl" (ast-decl-path-list-new)))))

(define (compiler-lower-module-symbols-ok?) : bool
  (match (parse-ast-source (compiler-lower-module-symbol-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-symbol-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program globals functions _)
              (and
                (lower-test-global-list-has-name? globals "lib.tl::answer")
                (>
                  (lower-test-functions-direct-call-count
                    functions
                    "lib.tl::inc")
                  0)
                (> (lower-test-function-binop-count functions "lib.tl::inc") 0)
                (>= (lower-test-function-binop-count functions "main") 0))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-package-owned-symbol-source) : String
  "(define (runtime-helper) : i64 1)
(define (app-helper) : i64 41)
(define (main) : i64 (+ (runtime-helper) (app-helper)))")

(define (compiler-lower-package-owned-symbol-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (ast-decl-root-path-cons
      "app/src/main.tl"
      (ast-decl-root-path-cons "" (ast-decl-path-list-new)))))

(define (compiler-lower-package-owned-symbols-ok?) : bool
  (match (parse-ast-source (compiler-lower-package-owned-symbol-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        ""
        program
        (compiler-lower-package-owned-symbol-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "stdlib/runtime.tl::runtime-helper")
                (lower-test-function-defined? functions "main")
                (=
                  (lower-test-function-call-count
                    functions
                    "main"
                    "app/src/main.tl::app-helper")
                  1))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-module-entry-main-source) : String
  "(module stdlib.arena)
(define (helper) : i64 41)
(define (main) : i64 (helper))")

(define (compiler-lower-module-qualified-source) : String
  "(module left)
(define same : i64 20)
(define (get) : i64 same)
(module right)
(define same : i64 22)
(define (get) : i64 same)
(module main)
(import left)
(import right)
(define (main) : i64 (+ (left.get) (right.get)))")

(define (compiler-lower-module-qualified-ok?) : bool
  (match (lower-compiler-source (compiler-lower-module-qualified-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program globals functions _)
          (and
            (lower-test-global-list-has-name? globals "left/same")
            (lower-test-global-list-has-name? globals "right/same")
            (> (lower-test-functions-call-count functions "left/get") 0)
            (> (lower-test-functions-call-count functions "right/get") 0)
            (> (lower-test-function-binop-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-import-alias-source) : String
  "(module data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (+
    (d.get)
    (+
      (let [p : d.Point (d.Point 7)]
        (struct-get p x))
      (match (d.Maybe.Some 3)
        [(d.Maybe.Some v) v]
        [d.Maybe.None 0]))))")

(define (compiler-lower-import-alias-ok?) : bool
  (match (lower-compiler-source (compiler-lower-import-alias-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-functions-call-count functions "data/get") 0)
            (= (lower-test-functions-call-count functions "d/get") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-dotted-import-default-alias-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(module main)
(import pkg.data)
(define (main) : i64 (+ (data.get) 1))")

(define (compiler-lower-dotted-import-default-alias-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-dotted-import-default-alias-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-functions-call-count functions "pkg.data/get") 0)
            (= (lower-test-functions-call-count functions "data/get") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-dotted-import-string-call-source) : String
  "(module pkg.string)
(define (eq [left : String] [right : String]) : bool (= (__tl_string_length left) (__tl_string_length right)))
(module pkg.args)
(import pkg.string)
(defstruct ArgsOptionSpec (long String))
(define (args-option-spec-long [spec : ArgsOptionSpec]) : String
  (struct-get spec long))
(define (args-option-spec-matches-long? [spec : ArgsOptionSpec] [name : String]) : bool
  (if (not (string.eq (args-option-spec-long spec) \"\"))
    (string.eq (args-option-spec-long spec) name)
    false))")

(define (compiler-lower-dotted-import-string-call-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-dotted-import-string-call-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (> (lower-test-functions-call-count functions "pkg.string/eq") 0)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-function-returning-struct-source) : String
  "(module data)
(defstruct Candidate (number i64))
(define (cand-nth [cands : (Array Candidate)]) : Candidate
  (array-ref cands 0))
(module main)
(import data)
(define (main) : i64
  (let [c : data.Candidate
    (data.cand-nth
      (make-array (data.Candidate 7)))]
    (struct-get c number)))")

(define (compiler-lower-module-function-returning-struct-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-module-function-returning-struct-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (> (lower-test-functions-call-count functions "data/cand-nth") 0)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-function-returning-enum-source) : String
  "(module data)
(defenum Maybe (get))
(module main)
(import data)
(define (get) : data.Maybe
  (data.get))
(define (main) : i64
  (match (get)
    [data.get 1]))")

(define (compiler-lower-module-function-returning-enum-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-module-function-returning-enum-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (> (lower-test-functions-call-count functions "main/get") 0)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-imported-enum-aggregate-payload-source) : String
  "(module data)
(defstruct Payload (code i64) (left i64) (right i64))
(defenum Choice (Wrap Payload))
(module main)
(import data)
(define (make) : data.Choice
  (data.Wrap (data.Payload 17 20 5)))
(define (main) : i64
  (match (make)
    [(data.Wrap payload) 1]))")

(define (compiler-lower-imported-enum-aggregate-payload-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-imported-enum-aggregate-payload-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (> (lower-test-function-copy-bytes-count functions "main/make") 0)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-macro-codegen-source) : String
  "(defmacro (int-box) : Module
  `(begin
    (module generated.intbox)
    (defstruct Box1 (value i64))
    (define (make [value : i64]) : Box1
      (Box1 value))
    (define (double [b : Box1]) : i64
      (* (struct-get b value) 2))
    (define (bumped [b : Box1]) : i64
      (+ (double b) 1))))
(import (int-box) as ib)
(define (main) : i64 (ib.bumped (ib.make 20)))")

(define (compiler-lower-module-macro-codegen-ok?) : bool
  (match (lower-compiler-source (compiler-lower-module-macro-codegen-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined? functions "generated.intbox/make")
            (lower-test-function-defined? functions "generated.intbox/double")
            (lower-test-function-defined? functions "generated.intbox/bumped")
            (=
              (lower-test-function-call-count
                functions
                "main"
                "generated.intbox/make")
              1)
            (=
              (lower-test-function-call-count
                functions
                "main"
                "generated.intbox/bumped")
              1)
            (=
              (lower-test-function-call-count
                functions
                "generated.intbox/bumped"
                "generated.intbox/double")
              1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-macro-global-init-source) : String
  "(defmacro (global-module) : Module
  `(begin
    (module generated.global_init_user)
    (define answer : i64 (+ 40 2))
    (define (read-answer) : i64 answer)))
(import (global-module) as generated)
(define (main) : i64 (+ generated.answer (generated.read-answer)))")

(define (compiler-lower-module-macro-global-init-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-module-macro-global-init-source))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program globals functions _)
          (and
            (lower-test-global-list-has-name?
              globals
              "generated.global_init_user/answer")
            (lower-test-function-defined?
              functions
              "__global_init_generated.global_init_user/answer")
            (lower-test-function-defined?
              functions
              "generated.global_init_user/read-answer"))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-macro-stdlib-vector-import-source) : String
  "(import stdlib.vector)
(import (vector.vector String) as svec)
(defmacro (vector-user) : Module
  `(begin
    (module generated.lower_vector_user)
    (defstruct T
      (value i64))
    (import (vector.vector T) as vec)
    (define (make [value : i64]) : T
      (T value))
    (define (score [first : T] [fallback : T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) first)
          (if (= (vec.len (& items)) 1)
            (begin
              (vec.get (& items) 0 fallback)
              42)
            0))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 7) (user.make 0)))")

(define (compiler-lower-module-macro-stdlib-vector-import-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-module-macro-stdlib-vector-import-source))
    [(ResultCompilerLower.Ok _ _) true]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-function-decl-count-wrapped-ok?) : bool
  (let
    [fn : AstDecl
      (ast-decl-def-fn-id
        (lower-test-generated-name-id "generated")
        (ast-param-list-new)
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 1))))]
    (and
      (=
        (lower-function-decl-count
          (ast-decl-cons
            (ast-decl-comptime-decl (ast-decl-unsafe fn))
            (ast-decl-list-new)))
        1)
      (=
        (lower-function-decl-count
          (ast-decl-cons
            (ast-decl-unsafe (ast-decl-comptime-decl fn))
            (ast-decl-list-new)))
        1))))

(define (compiler-lower-module-specialize-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
  (make-array T n))
(define (main) : (Array i64)
  (alloc (type i64) 4))")

(define (compiler-lower-module-specialize-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "app.tl"
    (ast-decl-root-path-cons "app.tl" (ast-decl-path-list-new))))

(define (compiler-lower-module-specialize-ok?) : bool
  (match (parse-ast-source (compiler-lower-module-specialize-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-specialize-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (>
                (lower-test-functions-direct-call-count
                  functions
                  "__tl_specialized_alloc_type_i64_none")
                0)])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-extern-link-metadata-source) : String
  "(extern (ffi-add [arg0 : i64]) : i64 (:abi c) (:symbol \"ffi_add\") (:link-lib \"ffi\") (:link-search \"native\") (:link-arg \"-Wl,--as-needed\"))
(define (main) : i64 (ffi-add 35))")

(define (compiler-lower-c-abi-unsupported-aggregate-source) : String
  "(defstruct Big (lo i64) (hi i64))
(extern (big-use [arg0 : Big]) : i64 (:symbol \"tl_cabi_big_use\"))
(define (main) : i64
  (big-use (Big 1 2)))")

(define (compiler-lower-c-abi-windows-nested-small-aggregate-source) : String
  "(defstruct InnerFloatBox (value f64))
(defstruct OuterFloatBox (inner InnerFloatBox))
(extern (outer-float-box-use [arg0 : OuterFloatBox]) : i64 (:symbol \"tl_cabi_outer_float_box_use\"))
(define (main) : i64
  (outer-float-box-use (OuterFloatBox (InnerFloatBox 1.5))))")

(define (compiler-lower-c-abi-windows-unsupported-aggregate-source) : String
  "(defstruct InnerText (value String))
(defstruct OuterText (inner InnerText))
(extern (outer-text-use [arg0 : OuterText]) : i64 (:symbol \"tl_cabi_outer_text_use\"))
(define (main) : i64
  (outer-text-use (OuterText (InnerText \"not-c-scalar\"))))")

(define (compiler-lower-c-abi-windows-small-float-aggregate-source) : String
  "(defstruct FloatPair
  (:repr c)
  (x f32)
  (y f32))
(extern (float-pair-use [arg0 : FloatPair]) : i64 (:symbol \"tl_cabi_float_pair_use\"))
(extern (float-pair-make [tag : u64]) : FloatPair (:symbol \"tl_cabi_float_pair_make\"))
(define (main) : i64
  (float-pair-use (float-pair-make (cast 5 : u64))))")

(define (compiler-lower-c-abi-windows-byref-aggregate-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-c-abi-unsupported-aggregate-source)
    (CompilerLowerMode.WindowsScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "big-use") 1)
            ;; `Big` is a 16-byte all-integer struct, register-resident,
            ;; so building `(Big 1 2)` does not heap-allocate -- the value is
            ;; constructed in a register pair. The Win64 C ABI still requires the
            ;; >8 B aggregate to be passed BY REFERENCE, so exactly one tl_alloc
            ;; remains: the byref buffer the register pair is spilled into before
            ;; the call (down from two when construction also allocated).
            (>= (lower-test-function-call-count functions "main" "tl_alloc") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-windows-nested-small-aggregate-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-c-abi-windows-nested-small-aggregate-source)
    (CompilerLowerMode.WindowsScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (=
            (lower-test-function-call-count
              functions
              "main"
              "outer-float-box-use")
            1)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-windows-small-float-aggregate-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-c-abi-windows-small-float-aggregate-source)
    (CompilerLowerMode.WindowsScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                functions
                "main"
                "float-pair-make")
              1)
            (=
              (lower-test-function-call-count functions "main" "float-pair-use")
              1)
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (>= (lower-test-function-bitcast-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-extern-link-inputs-ok?
  [inputs : AstExternLinkInputList]) : bool
  (and
    (= (ast-extern-link-input-list-len (& inputs)) 3)
    (match (ast-extern-link-input-list-get
      (& inputs)
      0
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Lib lib) (string.eq lib "ffi")]
      [_ false])
    (match (ast-extern-link-input-list-get
      (& inputs)
      1
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Search dir) (string.eq dir "native")]
      [_ false])
    (match (ast-extern-link-input-list-get
      (& inputs)
      2
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Arg arg-value)
        (string.eq arg-value "-Wl,--as-needed")]
      [_ false])))

(define (compiler-lower-extern-link-metadata-ok?) : bool
  (match (lower-compiler-source (compiler-lower-extern-link-metadata-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ _ externs)
          (match (match externs
            [(CompilerIrExternList.Array seq)
              (compiler-ir-extern-seq-to-list seq)]
            [_ externs])
            [(CompilerIrExternList.Cons
                (CompilerIrExtern.Extern
                  name-id
                  name-id
                  name
                  _
                  abi
                  symbol-id
                  link-inputs
                  _)
                CompilerIrExternList.Nil)
              (and
                (string.eq (intern-str name-id) "ffi-add")
                (string.eq name "ffi-add")
                (string.eq (intern-str symbol-id) "ffi_add")
                (ast-extern-abi-c? abi)
                (compiler-lower-extern-link-inputs-ok? link-inputs))]
            [_ false])])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-extern-value-fnptr-source) : String
  "(extern raw-value (:symbol \"tl_test_raw_value\") : i64)
(extern raw-fn (:symbol \"tl_test_raw_fn\") : (-> i64 i64))
(extern (direct-fn [x : i64]) : i64 (:symbol \"tl_test_direct_fn\"))
(define (main) : i64
  (let
    [copied : (-> i64 i64) raw-fn]
    (+ raw-value (+ (raw-fn 41) (+ (copied 40) (direct-fn 1))))))")

(define (compiler-lower-extern-value-fnptr-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-extern-value-fnptr-source)
    (CompilerLowerMode.LinuxScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "raw-fn") 0)
            (= (lower-test-function-call-count functions "main" "direct-fn") 1)
            (= (lower-test-function-indirect-call-count functions "main") 0)
            (= (lower-test-function-indirect-c-call-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-linux-tag-only-enum-source) : String
  "(defenum Status (Ready) (Done) (Failed))
(extern (status-next [arg0 : Status]) : Status (:symbol \"tl_cabi_status_next\"))
(extern status-score-ptr (:symbol \"tl_cabi_status_score_ptr\") : (->
  Status
  i64
  i64))
(define (status-rank [s : Status]) : i64
  (match s
    [Ready 1]
    [Done 2]
    [Failed 3]))
(define (main) : i64
  (let
    [score-copy : (-> Status i64 i64) status-score-ptr]
    [ready : Status (Ready)]
    [done : Status (status-next ready)]
    [failed : Status (status-next done)]
    [score : i64 (score-copy failed 7)]
    (+ score (status-rank done))))")

(define (compiler-lower-c-abi-linux-tag-only-enum-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-c-abi-linux-tag-only-enum-source)
    (CompilerLowerMode.LinuxScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count functions "main" "status-next")
              2)
            (= (lower-test-function-indirect-c-call-count functions "main") 1)
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-payload-enum-source) : String
  "(defenum SmallChoice (None) (Some i64))
(defstruct SmallBox (choice SmallChoice))
(defenum WideChoice (None) (Some u64 u64))
(extern (small-score [arg : SmallChoice]) : i64 (:symbol \"tl_cabi_small_score\"))
(extern small-score-ptr (:symbol \"tl_cabi_small_score_ptr\") : (-> SmallChoice i64))
(extern (box-score [arg : SmallBox]) : i64 (:symbol \"tl_cabi_box_score\"))
(extern (box-make [seed : i64]) : SmallBox (:symbol \"tl_cabi_box_make\"))
(extern (wide-make [seed : u64]) : WideChoice (:symbol \"tl_cabi_wide_make\"))
(define (wide-score [w : WideChoice]) : i64
  (match w
    [WideChoice.None 0]
    [(WideChoice.Some lo hi) (+ (cast lo : i64) (cast hi : i64))]))
(define (main) : i64
  (let
    [copy : (-> SmallChoice i64) small-score-ptr]
    [boxed : SmallBox (box-make 5)]
    [made : WideChoice (wide-make (cast 10 : u64))]
    (+ (small-score (SmallChoice.Some 11)) (+ (copy SmallChoice.None) (+ (box-score boxed) (wide-score made))))))")

(define (compiler-lower-c-abi-linux-payload-enum-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-c-abi-payload-enum-source)
    (CompilerLowerMode.LinuxScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count functions "main" "small-score")
              1)
            (= (lower-test-function-call-count functions "main" "box-score") 1)
            (= (lower-test-function-call-count functions "main" "box-make") 1)
            (= (lower-test-function-call-count functions "main" "wide-make") 1)
            (= (lower-test-function-indirect-c-call-count functions "main") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-windows-enum-aggregate-source) : String
  "(defenum Status (Ready) (Done) (Failed))
(defenum SmallChoice (None) (Some i64))
(defenum WideChoice (None) (Some u64 f64))
(defenum ReturnChoice (None) (Pair u64 u64))
(extern (status-pick [arg0 : Status] [arg1 : Status] [choose-second : i64]) : Status (:symbol \"tl_win64_status_pick\"))
(extern status-pick-ptr (:symbol \"tl_win64_status_pick_ptr\") : (->
  Status
  Status
  i64
  Status))
(extern (small-score [arg : SmallChoice] [bias : i64]) : i64 (:symbol \"tl_win64_small_score\"))
(extern small-scorer (:symbol \"tl_win64_small_score_ptr\") : (->
  SmallChoice
  i64
  i64))
(extern (wide-score [arg : WideChoice] [tag : u64]) : i64 (:symbol \"tl_win64_wide_score\"))
(extern wide-scorer (:symbol \"tl_win64_wide_score_ptr\") : (->
  WideChoice
  u64
  i64))
(extern (return-choice-make [a : u32] [b : u32] [tag : u64]) : ReturnChoice (:symbol \"tl_win64_return_choice_make\"))
(extern return-choice-maker (:symbol \"tl_win64_return_choice_make_ptr\") : (->
  u32
  u32
  u64
  ReturnChoice))
(define (return-score [r : ReturnChoice]) : i64
  (match r
    [ReturnChoice.None 0]
    [(ReturnChoice.Pair lo hi) (+ (cast lo : i64) (cast hi : i64))]))
(define (main) : i64
  (let
    [status-copy : (-> Status Status i64 Status) status-pick-ptr]
    [small-copy : (-> SmallChoice i64 i64) small-scorer]
    [wide-copy : (-> WideChoice u64 i64) wide-scorer]
    [return-copy : (-> u32 u32 u64 ReturnChoice) return-choice-maker]
    [picked : Status (status-pick (Ready) (Done) 1)]
    [picked-via-ptr : Status (status-copy (Ready) (Failed) 1)]
    [small-direct : i64 (small-score (SmallChoice.Some 11) 5)]
    [small-via-ptr : i64 (small-copy SmallChoice.None 7)]
    [wide-direct : i64 (wide-score (WideChoice.Some (cast 20 : u64) 2.5) (cast 3 : u64))]
    [wide-via-ptr : i64 (wide-copy WideChoice.None (cast 4 : u64))]
    [made : ReturnChoice
      (return-choice-make (cast 3 : u32) (cast 4 : u32) (cast 10 : u64))]
    [made-via-ptr : ReturnChoice
      (return-copy (cast 5 : u32) (cast 6 : u32) (cast 2 : u64))]
    (+ small-direct
      (+ small-via-ptr
        (+ wide-direct
          (+ wide-via-ptr
            (+ (return-score made) (return-score made-via-ptr))))))))")

(define (compiler-lower-c-abi-windows-enum-aggregate-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-c-abi-windows-enum-aggregate-source)
    (CompilerLowerMode.WindowsScalar))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count functions "main" "status-pick")
              1)
            (=
              (lower-test-function-call-count functions "main" "small-score")
              1)
            (= (lower-test-function-call-count functions "main" "wide-score") 1)
            (=
              (lower-test-function-call-count
                functions
                "main"
                "return-choice-make")
              1)
            (= (lower-test-function-indirect-c-call-count functions "main") 4)
            (>= (lower-test-function-call-count functions "main" "tl_alloc") 3))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-global-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
(define answer : i64 40)
(define flag : bool true)
(define widened : i64 (cast 7 : i64))
(define (main) : i64
  (begin
    (set! answer 41)
    (if flag (+ answer widened) 0)))")

(define (compiler-lower-global-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-global-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program globals functions externs)
          (let
            [ok : bool true]
            (begin
              (if (match globals
                [(CompilerIrGlobalList.Array _) true]
                [_ false])
                unit
                (set! ok false))
              (if (match externs
                [(CompilerIrExternList.Array _) true]
                [_ false])
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name? globals "answer")
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name? globals "flag")
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name? globals "widened")
                unit
                (set! ok false))
              (if (= (compiler-ir-extern-list-count externs) 1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-global-count
                  functions
                  "main"
                  "answer")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-numeric-source) : String
  "(define (bits [a : i32] [b : i32] [s : i32]) : i32
  (bit-xor (bit-or (bit-and a b s) (shl a s)) (shr b s) a))
(define (floaty [a : f64] [b : f64]) : bool
  (< (+ a b) 10.0))
(define (casts [c : char] [x : i64]) : u8
  (cast (+ x (cast c : i64)) : u8))
(define (main) : i64
  (if (floaty 1.0 2.0)
    (+ (cast (bits (cast 7 : i32) (cast 3 : i32) (cast 1 : i32)) : i64) (cast (casts 'A' 1) : i64))
    0))")

(define (compiler-lower-numeric-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-numeric-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  CompilerIrBinOp.BitAnd)
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  CompilerIrBinOp.BitOr)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  CompilerIrBinOp.BitXor)
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  CompilerIrBinOp.Shl)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  CompilerIrBinOp.Shr)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "floaty"
                  CompilerIrBinOp.Add)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "floaty"
                  CompilerIrBinOp.Lt)
                0)
                unit
                (set! ok false))
              (if (> (lower-test-function-cast-count functions "casts") 0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-simple-source) : String
  "(define (loop [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (loop (- n 1) (+ acc 1))))
(define (main) : i64 (loop 3 0))")

(define (compiler-lower-tail-context-source) : String
  "(define (loop [n : i64] [acc : i64]) : i64
  (let
    [next : i64 (- n 1)]
    (begin
      unit
      (ann
        (match n
          [0 acc]
          [_ (cast (loop next (+ acc 1)) : i64)])
        : i64))))
(define (main) : i64 (loop 3 0))")

(define (compiler-lower-tail-operand-source) : String
  "(define (loop [n : i64]) : i64
  (+ 1 (loop (- n 1))))
(define (main) : i64 (loop 3))")

(define (compiler-lower-tail-direct-source) : String
  "(define (finish [x : i64] [y : i64]) : i64 (+ x y))
(define (step [x : i64]) : i64 (finish x 1))
(define (main) : i64 (step 41))")

(define (compiler-lower-tail-direct-stack-source) : String
  "(define (finish5
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]) : i64
  (+ a (+ b (+ c (+ d e)))))
(define (step5 [x : i64]) : i64 (finish5 x 1 2 3 4))
(define (main) : i64 (step5 32))")

(define (compiler-lower-tail-aggregate-return-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : i64]) : Big
  (Big x (+ x 1) (+ x 2)))
(define (step [n : i64] [acc : i64]) : Big
  (if (= n 0)
    (finish acc)
    (step (- n 1) (+ acc 1))))
(define (main) : i64
  (let [value : Big (step 3 39)]
    (struct-get value c)))")

(define (compiler-lower-tail-aggregate-param-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big] [n : i64]) : i64
  (+ (struct-get x a) n))
(define (step [x : Big] [n : i64]) : i64
  (if (= n 0)
    (finish x n)
    (step x (- n 1))))
(define (main) : i64
  (step (Big 39 1 2) 3))")

(define (compiler-lower-tail-aggregate-local-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big] [n : i64]) : i64
  (+ (struct-get x a) n))
(define (step [n : i64]) : i64
  (finish (Big n (+ n 1) (+ n 2)) n))
(define (main) : i64 (step 39))")

(define (compiler-lower-tail-aggregate-reassigned-param-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big] [n : i64]) : i64
  (+ (struct-get x a) n))
(define (step [x : Big] [n : i64]) : i64
  (begin
    (set! x (Big n (+ n 1) (+ n 2)))
    (finish x n)))
(define (main) : i64
  (step (Big 1 2 3) 39))")

(define (compiler-lower-tail-indirect-source) : String
  "(define (finish [x : i64]) : i64 x)
(define (step [f : (-> i64 i64)] [x : i64]) : i64
  (f x))
(define (main) : i64 (step finish 42))")

(define (compiler-lower-tail-indirect-aggregate-param-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big]) : i64
  (struct-get x b))
(define (step [f : (-> Big i64)] [x : Big]) : i64
  (f x))
(define (main) : i64
  (step finish (Big 1 42 3)))")

(define (compiler-lower-tail-indirect-aggregate-return-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : i64]) : Big
  (Big x (+ x 1) (+ x 2)))
(define (step [f : (-> i64 Big)] [x : i64]) : Big
  (f x))
(define (main) : i64
  (let [value : Big (step finish 39)]
    (struct-get value c)))")

(define (compiler-lower-tail-cleanup-source) : String
  "(define (finish [x : i64]) : i64 x)
(define (step [x : i64]) : i64
  (with-arena scratch
    (finish x)))
(define (main) : i64 (step 42))")

(define (compiler-lower-tail-simple-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-simple-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "loop" "loop") 1)
            (= (lower-test-function-call-count functions "loop" "loop") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-context-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-context-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "loop" "loop") 1)
            (= (lower-test-function-call-count functions "loop" "loop") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-operand-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-operand-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "loop" "loop") 0)
            (> (lower-test-function-call-count functions "loop" "loop") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-direct-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-direct-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              1)
            (= (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-direct-stack-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-direct-stack-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step5" "finish5")
              1)
            (= (lower-test-function-call-count functions "step5" "finish5") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-return-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-aggregate-return-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "step" "step") 1)
            (= (lower-test-function-call-count functions "step" "step") 0)
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              1)
            (= (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-param-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-aggregate-param-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "step" "step") 1)
            (= (lower-test-function-call-count functions "step" "step") 0)
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              1)
            (= (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-local-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-aggregate-local-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              0)
            (> (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-reassigned-param-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-tail-aggregate-reassigned-param-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              0)
            (> (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-indirect-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-indirect-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count functions "step")
              1)
            (= (lower-test-function-indirect-call-count functions "step") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-indirect-aggregate-param-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-tail-indirect-aggregate-param-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count functions "step")
              1)
            (= (lower-test-function-indirect-call-count functions "step") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-indirect-aggregate-return-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-tail-indirect-aggregate-return-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count functions "step")
              1)
            (= (lower-test-function-indirect-call-count functions "step") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-cleanup-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-cleanup-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              0)
            (> (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-call-shape-ok?) : bool
  (and
    (compiler-lower-tail-simple-shape-ok?)
    (compiler-lower-tail-context-shape-ok?)
    (compiler-lower-tail-operand-shape-ok?)
    (compiler-lower-tail-direct-shape-ok?)
    (compiler-lower-tail-direct-stack-shape-ok?)
    (compiler-lower-tail-aggregate-return-shape-ok?)
    (compiler-lower-tail-aggregate-param-shape-ok?)
    (compiler-lower-tail-aggregate-local-shape-ok?)
    (compiler-lower-tail-aggregate-reassigned-param-shape-ok?)
    (compiler-lower-tail-indirect-shape-ok?)
    (compiler-lower-tail-indirect-aggregate-param-shape-ok?)
    (compiler-lower-tail-indirect-aggregate-return-shape-ok?)
    (compiler-lower-tail-cleanup-shape-ok?)))

;; CTFE fold verification: a folded `(comptime ...)` lowers to a literal,
;; so the function body must contain a `Mov` of the expected literal and no
;; `BinOp`/`UnOp` instructions (the arithmetic was evaluated at compile time).
(define (lower-test-instr-i64-mov-count [instr : CompilerIrInstr] [want : i64]) : i64
  (match instr
    [(CompilerIrInstr.Mov _ value _)
      (match value
        [(CompilerIrValue.I64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-f64-mov-count [instr : CompilerIrInstr] [want : u64]) : i64
  (match instr
    [(CompilerIrInstr.Mov _ value _)
      (match value
        [(CompilerIrValue.F64 bits)
          (if (= bits want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-binop-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(CompilerIrInstr.BinOp _ _ _ _ _) 1]
    [(CompilerIrInstr.UnOp _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-gep-offset-count
  [instr : CompilerIrInstr]
  [want : i64]) : i64
  (match instr
    [(CompilerIrInstr.Gep _ _ offset _)
      (match offset
        [(CompilerIrValue.I64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-seq-i64-mov-count
  [instrs : CompilerIrInstrSeq]
  [want : i64]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-i64-mov-count (array-ref slots index) want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-f64-mov-count
  [instrs : CompilerIrInstrSeq]
  [want : u64]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-f64-mov-count (array-ref slots index) want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-binop-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-binop-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-gep-offset-count
  [instrs : CompilerIrInstrSeq]
  [want : i64]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-gep-offset-count (array-ref slots index) want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-i64-mov-count
  [blocks : CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-i64-mov-count instrs want)
            (lower-test-blocks-i64-mov-count (box-get rest) want))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-i64-mov-count (compiler-ir-block-seq-to-list seq) want)]))

(define (lower-test-blocks-f64-mov-count
  [blocks : CompilerIrBlockList]
  [want : u64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-f64-mov-count instrs want)
            (lower-test-blocks-f64-mov-count (box-get rest) want))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-f64-mov-count (compiler-ir-block-seq-to-list seq) want)]))

(define (lower-test-blocks-binop-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-binop-count instrs)
            (lower-test-blocks-binop-count (box-get rest)))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-binop-count (compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-gep-offset-count
  [blocks : CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(CompilerIrBlockList.Nil) 0]
    [(CompilerIrBlockList.Cons block rest)
      (match block
        [(CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-gep-offset-count instrs want)
            (lower-test-blocks-gep-offset-count (box-get rest) want))])]
    [(CompilerIrBlockList.Array seq)
      (lower-test-blocks-gep-offset-count
        (compiler-ir-block-seq-to-list seq)
        want)]))

(define (lower-test-function-i64-mov-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [want : i64]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-i64-mov-count blocks want)
            (lower-test-function-i64-mov-count (box-get rest) name want))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-i64-mov-count
        (compiler-ir-function-seq-to-list seq)
        name
        want)]))

(define (lower-test-function-f64-mov-count-bits
  [funcs : CompilerIrFunctionList]
  [name : String]
  [want : u64]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-f64-mov-count blocks want)
            (lower-test-function-f64-mov-count-bits (box-get rest) name want))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-f64-mov-count-bits
        (compiler-ir-function-seq-to-list seq)
        name
        want)]))

(define (lower-test-function-binop-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-binop-count blocks)
            (lower-test-function-binop-count (box-get rest) name))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-binop-count
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (lower-test-function-gep-offset-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [want : i64]) : i64
  (match funcs
    [(CompilerIrFunctionList.Nil) (- 0 1)]
    [(CompilerIrFunctionList.Cons func rest)
      (match func
        [(CompilerIrFunction.Function fname _ _ _ blocks)
          (if (string.eq (compiler-ir-symbol-text fname) name)
            (lower-test-blocks-gep-offset-count blocks want)
            (lower-test-function-gep-offset-count (box-get rest) name want))])]
    [(CompilerIrFunctionList.Array seq)
      (lower-test-function-gep-offset-count
        (compiler-ir-function-seq-to-list seq)
        name
        want)]))

(define (compiler-lower-comptime-fold-ok? [src : String] [want : i64]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-i64-mov-count functions "main" want) 0)
            (= (lower-test-function-binop-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-comptime-float-fold-ok?
  [src : String]
  [want : String]
  [ty : AstType]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-f64-mov-count-bits
                functions
                "main"
                (lower-float-literal-bits want ty))
              0)
            (= (lower-test-function-binop-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-comptime-f64-fold-ok? [src : String] [want : String]) : bool
  (compiler-lower-comptime-float-fold-ok? src want (AstType.F64)))

(define (compiler-lower-comptime-f32-fold-ok? [src : String] [want : String]) : bool
  (compiler-lower-comptime-float-fold-ok? src want (AstType.F32)))

;; Tail-position scalar matches (`classify`/`flag-score`/`sign`) return directly
;; from every arm; the unit-typed match (`announce`) likewise needs no phi.
(define (compiler-lower-match-tail-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-phi-count functions "classify") 0)
            (= (lower-test-function-phi-count functions "flag-score") 0)
            (= (lower-test-function-phi-count functions "sign") 0)
            (= (lower-test-function-phi-count functions "announce") 0))])]
    [(ResultCompilerLower.Err _) false]))

;; Tail-position enum matches also return directly from their arms. Payload
;; matches still need the loads that extract values from the enum storage.
(define (compiler-lower-enum-match-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-phi-count functions "score") 0)
            (= (lower-test-function-phi-count functions "zero-call") 0)
            (= (lower-test-function-phi-count functions "or-zero") 0)
            (= (lower-test-function-phi-count functions "touch") 0)
            (> (lower-test-function-load-count functions "score") 1)
            (> (lower-test-function-load-count functions "or-zero") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-two-variant-fallthrough-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-two-variant-fallthrough-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-binop-op-count
                functions
                "score"
                CompilerIrBinOp.Eq)
              1)
            (=
              (lower-test-function-call-count functions "score" "tl_oob_abort")
              0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-total-enum-provenance-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-total-enum-provenance-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (>=
              (lower-test-function-total-enum-branch-count functions "large")
              4)
            (=
              (lower-test-function-total-enum-branch-count functions "small")
              0)
            ;; The outer two-arm match remains ordinary while its nested
            ;; six-variant match independently carries the total proof.
            (=
              (lower-test-function-total-enum-branch-count functions "nested")
              4)
            (= (lower-test-function-branch-count functions "nested") 6)
            ;; A catch-all makes the match exhaustive as source syntax, but it
            ;; does not prove that the compared tags cover the enum domain.
            (=
              (lower-test-function-total-enum-branch-count functions "partial")
              0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-enum-string-literal-payload-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-enum-string-literal-payload-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-functions-call-count functions "tl_string_eq") 0)
            (= (lower-test-functions-call-count functions "string-eq") 0)
            (> (lower-test-function-branch-count functions "classify") 2)
            (> (lower-test-function-load-count functions "classify") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-borrowed-enum-match-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-borrowed-enum-match-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-phi-count functions "score") 0)
            (> (lower-test-function-call-count functions "score" "take") 0)
            (> (lower-test-function-gep-offset-count functions "score" 8) 0)
            (> (lower-test-function-branch-count functions "slot-score") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-result-try-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-branch-count functions ".::sum") 1)
            (> (lower-test-function-return-count functions ".::sum") 2)
            (> (lower-test-function-return-count functions ".::chain") 1)
            (> (lower-test-function-load-count functions ".::sum") 3))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-option-try-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-option-try-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-branch-count functions "main") 1)
            (> (lower-test-function-return-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-return-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-return-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (> (lower-test-function-return-count functions "main") 1)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-return-with-arena-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-return-with-arena-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-return-count functions "main") 1)
            (> (lower-test-functions-call-count functions "tl_region_reset") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-resource-with-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-resource-with-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-functions-call-count functions ".::close-a") 3)
            (= (lower-test-functions-call-count functions ".::close-b") 2)
            (> (lower-test-function-return-count functions "main") 2)
            (> (lower-test-function-branch-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-resource-with-nested-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-resource-with-nested-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-functions-call-count functions ".::close-a") 1)
            (= (lower-test-functions-call-count functions ".::close-b") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-cleanup-struct-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-cleanup-struct-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                functions
                ".::cleanup-file-handle"
                ".::close-fd")
              1)
            (>
              (lower-test-function-direct-call-count
                functions
                "main"
                ".::cleanup-file-handle")
              1)
            (> (lower-test-function-return-count functions "main") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-cleanup-struct-nested-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-cleanup-struct-nested-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                functions
                "cleanup-file-handle"
                "close-fd")
              1)
            (=
              (lower-test-function-call-count
                functions
                "cleanup-buffered-file"
                "close-buffer")
              1)
            (=
              (lower-test-function-direct-call-count
                functions
                "cleanup-buffered-file"
                "cleanup-file-handle")
              1)
            (lower-test-function-call-before?
              functions
              "cleanup-buffered-file"
              "close-buffer"
              "cleanup-file-handle"))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-array-access-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-bounds-count functions "get") 0)
            (> (lower-test-function-bounds-count functions "put") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-array-take-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-array-take-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (>= (lower-test-function-bounds-count functions "take-item") 2)
            (>= (lower-test-function-branch-count functions "take-item") 2)
            (>= (lower-test-function-store-ptr-count functions "take-item") 3)
            (>= (lower-test-function-load-count functions "take-item") 3))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-mut-ref-array-field-access-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-mut-ref-array-field-access-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-load-count functions "array-bag-handle") 0)
            (> (lower-test-function-load-count functions "len") 0)
            (> (lower-test-function-bounds-count functions "get") 0)
            (> (lower-test-function-bounds-count functions "put") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-fixed-array-access-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (> (lower-test-function-bounds-count functions "get") 0)
                unit
                (set! ok false))
              (if (> (lower-test-function-load-count functions "get") 0)
                unit
                (set! ok false))
              (if (> (lower-test-function-bounds-count functions "put") 0)
                unit
                (set! ok false))
              (if (= (lower-test-function-gep-offset-count functions "get" 1) 0)
                unit
                (set! ok false))
              (if (= (lower-test-function-gep-offset-count functions "put" 1) 0)
                unit
                (set! ok false))
              (if (> (lower-test-function-store-ptr-count functions "put") 0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-fixed-array-literal-stack-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-array-literal-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (>= (lower-test-function-alloc-count functions "main") 3)
            (= (lower-test-function-addr-of-count functions "main") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-fixed-array-aggregate-layout-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-fixed-array-aggregate-literal-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (> (lower-test-function-gep-offset-count functions "main" 16) 0)
            (= (lower-test-function-copy-bytes-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-array-push-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_alloc") 0)
            (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
            (> (lower-test-function-binop-count functions "grow") 0)
            (> (lower-test-function-store-ptr-count functions "grow") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-make-array-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_alloc") 1)
            (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
            (>=
              (lower-test-function-i64-binop-op-count
                functions
                "main"
                (CompilerIrBinOp.Le))
              2)
            (=
              (lower-test-function-binop-op-count
                functions
                "main"
                (CompilerIrBinOp.Le))
              (lower-test-function-i64-binop-op-count
                functions
                "main"
                (CompilerIrBinOp.Le)))
            (=
              (lower-test-function-call-count functions "main" "tl_array_zero")
              1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-make-array-init-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count functions "main" "tl_array_fill8")
              1)
            (>= (lower-test-function-store-ptr-count functions "main") 2)
            (> (lower-test-functions-call-count functions "tl_alloc") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-dyn-array-literal-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-dyn-array-literal-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 2)
            (=
              (lower-test-function-call-count functions "main" "tl_array_zero")
              0)
            (>= (lower-test-function-store-ptr-count functions "main") 3))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-make-array-register-resident-zero-fill-shape-ok?) : bool
  ;; A one-word register-resident struct with an all-zero default takes the
  ;; tl_array_zero path (the aggregate zero-fill supersedes fill8 for
  ;; all-zero defaults; fill8 remains for non-zero defaults).
  (match (lower-compiler-source-with-mode
    (compiler-lower-make-array-register-resident-fill8-source)
    (CompilerLowerMode.InlineAggregates))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count functions "main" "tl_array_zero")
              1)
            (=
              (lower-test-function-call-count functions "main" "tl_array_fill8")
              0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-string-runtime-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions "tl_substring")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_oob_abort")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string.substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string.append")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string.concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_print_str")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "__tl_rt_print_string")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "io.print-string")
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "io.print-str")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-string-concat-fusion-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-string-concat-fusion-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat3")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat4")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat5")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string.append")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-print-string-stdlib-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-print-string-stdlib-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-functions-call-count functions "tl_print_str") 0)
            (=
              (lower-test-functions-direct-call-count
                functions
                "io.print-string")
              2)
            (=
              (lower-test-functions-direct-call-count functions "io.print-str")
              1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-borrowed-str-param-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-borrowed-str-param-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-direct-call-count
                  functions
                  "main"
                  "borrowed-score")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  functions
                  "borrowed-score"
                  1)
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "string-length")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-stdlib-hash-string-shape-ok?) : bool
  (match (parse-ast-source (compiler-lower-stdlib-hash-string-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-stdlib-hash-string-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (let
                [name : String "stdlib/hash.tl::hash-string"]
                [ok : bool true]
                (begin
                  (if (=
                    (lower-test-function-call-count
                      functions
                      name
                      "tl_hash_string")
                    0)
                    unit
                    (set! ok false))
                  (if (> (lower-test-function-bounds-count functions name) 0)
                    unit
                    (set! ok false))
                  (if (=
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      name)
                    1)
                    unit
                    (set! ok false))
                  ok))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-reference-values-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-reference-return-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-call-count
                  functions
                  "ref-return"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count functions "ref-id" "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (> (lower-test-function-store-ptr-count functions "main") 1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-return-count functions "ref-return")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-function-return-count functions "ref-id") 1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-reference-place-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-reference-place-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-gep-offset-count functions "borrow-pair" 0)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  functions
                  "borrow-tuple"
                  0)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-bounds-count functions "borrow-array")
                0)
                unit
                (set! ok false))
              (if (compiler-lower-reference-inline-struct-field-shape-ok?)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-reference-inline-struct-field-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-reference-inline-struct-field-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                functions
                "main"
                "take-inner")
              1)
            (= (lower-test-function-load-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-reference-nominal-aggregate-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-reference-struct-result-source))
    (compiler-lower-ok? (compiler-lower-reference-struct-multi-result-source))
    (compiler-lower-ok? (compiler-lower-reference-enum-result-source))))

(define (compiler-lower-string-shadow-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count functions "string.string-length")
              0)
            (> (lower-test-functions-call-count functions "string.append") 0)
            (>
              (lower-test-functions-call-count functions "string.string-ref")
              0)
            (> (lower-test-functions-call-count functions "string.char-at") 0)
            (= (lower-test-functions-call-count functions "tl_string_concat") 0)
            (= (lower-test-functions-call-count functions "tl_oob_abort") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-function-value-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-function-value-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-indirect-tail-call-count
                  functions
                  "apply1")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "apply1")
                0)
                unit
                (set! ok false))
              (if (= (lower-test-function-call-count functions "apply1" "f") 0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count
                  functions
                  "shadow-inc")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count functions "shadow-inc" "inc")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-arg-function-count
                  functions
                  "main"
                  "apply1"
                  "inc")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-function-value-contextual-init-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-function-value-contextual-init-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count functions "main")
              1)
            (= (lower-test-function-indirect-call-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-noncapturing-lambda-value-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-noncapturing-lambda-value-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_get-fn_0"]
            (and
              (= (compiler-ir-function-list-count functions) 2)
              (=
                (lower-test-function-return-function-count
                  functions
                  "get-fn"
                  lambda-name)
                1)
              (> (lower-test-function-binop-count functions lambda-name) 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-immediate-lambda-call-ok?) : bool
  (match (lower-compiler-source (compiler-lower-immediate-lambda-call-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            (and
              (= (compiler-ir-function-list-count functions) 2)
              (=
                (lower-test-function-indirect-tail-call-count functions "main")
                1)
              (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "main"
                  lambda-name)
                1)
              (=
                (lower-test-function-call-count functions "main" lambda-name)
                0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-unit-lambda-call-ok?) : bool
  (match (lower-compiler-source (compiler-lower-unit-lambda-call-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            (and
              (= (compiler-ir-function-list-count functions) 2)
              (= (lower-test-function-indirect-unit-count functions "main") 1)
              (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "main"
                  lambda-name)
                1)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-noncapturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-noncapturing-lambda-value-ok?)
    (compiler-lower-immediate-lambda-call-ok?)
    (compiler-lower-unit-lambda-call-ok?)))

(define (compiler-lower-capturing-lambda-scalar-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-capturing-lambda-scalar-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 3)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-call-count functions "tl_alloc") 2)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-function-value-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-function-value-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [capturing-name : String "__tl_lambda_main_1"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 3)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-indirect-tail-call-count
                  functions
                  capturing-name)
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count functions capturing-name)
                2)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-fat-handle-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-fat-handle-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-call-count functions "tl_alloc") 3)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 2)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-aggregate-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-aggregate-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-call-count functions "tl_alloc") 5)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 8)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 4)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-shadow-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-capturing-lambda-shadow-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (compiler-ir-function-list-count functions) 2)
            (=
              (lower-test-function-indirect-tail-call-count functions "main")
              1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-reference-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-reference-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-reference-immediate-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-reference-immediate-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-capturing-lambda-scalar-shape-ok?)
    (compiler-lower-capturing-lambda-function-value-shape-ok?)
    (compiler-lower-capturing-lambda-fat-handle-shape-ok?)
    (compiler-lower-capturing-lambda-aggregate-shape-ok?)
    (compiler-lower-capturing-lambda-shadow-shape-ok?)
    (compiler-lower-capturing-lambda-reference-shape-ok?)
    (compiler-lower-capturing-lambda-reference-immediate-shape-ok?)))

(define (compiler-lower-fs-status-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-fs-status-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_mkdir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_remove_file_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_remove_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_rename_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_read_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions ".L_tl_fs_read_dir")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_file_kind_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_file_size_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions ".L_tl_fs_file_size")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_process_id")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "tl_fs_current_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_fs_current_dir")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "mkdir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "remove-file-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "remove-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "rename-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "read-dir-status")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "read-dir") 1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "file-kind-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "file-size-status")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "file-size") 1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "process-id") 1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "current-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "current-dir")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-region-source) : String
  "(define (string.int->string [value : i64]) : String
  \"41\")
(define (main) : i64
  (with-arena r
    (let
      [s : String (string.int->string 41)]
      (__tl_string_length s))))")

(define (compiler-lower-region-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-region-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_region_mark") 0)
            (> (lower-test-functions-call-count functions "tl_region_reset") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-arena-source [src : String]) : String
  (string.append
    "(module stdlib.arena)
(extern (tl_arena_make) : i64)
(extern (tl_arena_current) : i64)
(extern (tl_region_mark) : i64)
(unsafe (extern (tl_arena_set [arg0 : i64]) : unit))
(unsafe (extern (tl_region_reset [arg0 : i64]) : unit))
(defstruct Arena (handle i64))
(defstruct ArenaMark (handle i64))
(define (arena-make) : Arena (Arena (tl_arena_make)))
(define (arena-current) : Arena (Arena (tl_arena_current)))
(define (arena-mark) : ArenaMark (ArenaMark (tl_region_mark)))
(define (arena-raw-handle [arena : Arena]) : i64 (struct-get arena handle))
(define (arena-mark-raw-handle [mark : ArenaMark]) : i64 (struct-get mark handle))
(unsafe (define (arena-set! [arena : Arena]) : unit (unsafe (tl_arena_set (arena-raw-handle arena)))))
(unsafe (define (arena-rewind [mark : ArenaMark]) : unit (unsafe (tl_region_reset (arena-mark-raw-handle mark)))))
(define (string.int->string [value : i64]) : String \"42\")
"
    src))

(define (compiler-lower-with-escape-scalar-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : i64
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch 40 42)))"))

(define (compiler-lower-with-escape-string-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : String
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch (string.int->string 42))))"))

(define (compiler-lower-with-escape-array-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : (Array String)
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch
      (let
        [items : (Array String) (make-array String 2)]
        (begin
          (array-set! items 0 (string.int->string 1))
          (array-set! items 1 (string.int->string 2))
          items)))))"))

(define (compiler-lower-with-escape-box-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : (Box String)
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch (box (string.int->string 42)))))"))

(define (compiler-lower-with-escape-owning-source) : String
  (compiler-lower-with-arena-source
    "(defstruct EscapePayload
  (name String)
  (items (Array String))
  (cell (Box String)))
(defenum EscapeResult
  (Ok EscapePayload)
  (None))
(define (main) : EscapeResult
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch
      (let
        [items : (Array String) (make-array String 2)]
        (begin
          (array-set! items 0 (string.int->string 1))
          (array-set! items 1 (string.int->string 2))
          (EscapeResult.Ok
            (EscapePayload
              (string.int->string 3)
              items
              (box (string.int->string 4)))))))))"))

(define (compiler-lower-with-escape-arena-functions-shape-ok?
  [functions : CompilerIrFunctionList]) : bool
  (and
    (>= (lower-test-functions-call-count functions "tl_arena_current") 3)
    (>= (lower-test-functions-call-count functions "tl_arena_set") 4)
    (> (lower-test-functions-call-count functions "tl_region_mark") 0)
    (> (lower-test-functions-call-count functions "tl_region_reset") 0)))

(define (compiler-lower-with-escape-arena-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (compiler-lower-with-escape-arena-functions-shape-ok? functions)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-array-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-with-escape-array-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-escape-arena-shape-ok?
              (compiler-lower-with-escape-array-source))
            (> (lower-test-functions-call-count functions "tl_alloc") 1)
            (> (lower-test-functions-branch-count functions) 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-box-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-with-escape-box-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-escape-arena-shape-ok?
              (compiler-lower-with-escape-box-source))
            (> (lower-test-functions-call-count functions "tl_alloc") 0)
            (> (lower-test-functions-call-count functions "tl_substring") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-owning-shape-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-with-escape-owning-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-escape-arena-functions-shape-ok? functions)
            (> (lower-test-functions-call-count functions "tl_alloc") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-with-escape-arena-shape-ok?
        (compiler-lower-with-escape-scalar-source))
        unit
        (set! ok false))
      (if (match (lower-compiler-source
        (compiler-lower-with-escape-string-source))
        [(ResultCompilerLower.Ok program _)
          (match program
            [(CompilerIrProgram.Program _ functions _)
              (and
                (compiler-lower-with-escape-arena-shape-ok?
                  (compiler-lower-with-escape-string-source))
                (> (lower-test-functions-call-count functions "tl_substring") 0))])]
        [(ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-array-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-box-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-owning-shape-ok?)
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-with-scratch-scalar-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : i64
  (with-scratch 40 42))"))

(define (compiler-lower-with-scratch-string-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : String
  (with-scratch (string.int->string 42)))"))

(define (compiler-lower-runtime-substring-scratch-source) : String
  (string.append
    "(define (substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
  (unsafe (string-from-bytes (ptr-offset src start) len)))
"
    (compiler-lower-with-scratch-string-source)))

(define (compiler-lower-runtime-substring-scratch-paths) : AstDeclPathList
  (ast-decl-root-path-cons "stdlib/runtime.tl" (ast-decl-path-list-new)))

(define (compiler-lower-runtime-substring-call-source) : String
  (string.append
    "(define (substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
  (unsafe (string-from-bytes (ptr-offset src start) len)))
(unsafe
  (extern (tl_substring [src : (Ptr u8)] [start : i64] [len : i64]) : String))
"
    "(define (main) : String
  (let
    [s : String \"hello\"]
    (unsafe (tl_substring (string-data s) 1 2))))"))

(define (compiler-lower-runtime-substring-capturing-lambda-source) : String
  (string.append
    "(define (substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
  (unsafe (string-from-bytes (ptr-offset src start) len)))
"
    "(define (main) : String
  (let
    [s : String \"hello\"]
    ((lambda () : String s))))"))

(define (compiler-lower-runtime-atomic-reachable-source) : String
  "(define (atomic-i64-fetch-add-ptr!
  [ptr : (MutPtr i64)]
  [delta : i64]) : i64
  (unsafe (atomic-fetch-add! ptr delta)))
(define (atomic-i64-load-ptr [ptr : (Ptr i64)]) : i64
  (unsafe (atomic-load ptr)))
(extern (atomic-i64-fetch-add!
  [items : (Array i64)]
  [index : i64]
  [delta : i64]) : i64 (:symbol \"tl_atomic_i64_fetch_add\"))
(define (main [items : (Array i64)]) : i64
  (atomic-i64-fetch-add! items 0 1))")

(define (compiler-lower-runtime-atomic-reachable-paths) : AstDeclPathList
  (ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (ast-decl-root-path-cons
      "stdlib/runtime.tl"
      (ast-decl-root-path-cons
        "stdlib/atomic.tl"
        (ast-decl-root-path-cons "app.tl" (ast-decl-path-list-new))))))

(define (compiler-lower-with-scratch-owning-source) : String
  (compiler-lower-with-arena-source
    "(defstruct ScratchPayload
  (name String)
  (items (Array String))
  (cell (Box String)))
(defenum ScratchResult
  (Ok ScratchPayload)
  (None))
(define (main) : ScratchResult
  (with-scratch
    (let
      [items : (Array String) (make-array String 2)]
        (begin
          (array-set! items 0 (string.int->string 1))
          (array-set! items 1 (string.int->string 2))
        (ScratchResult.Ok
          (ScratchPayload
            (string.int->string 3)
            items
            (box (string.int->string 4))))))))"))

(define (compiler-lower-with-scratch-arena-functions-shape-ok?
  [functions : CompilerIrFunctionList]) : bool
  (and
    (>= (lower-test-functions-call-count functions "tl_arena_current") 3)
    (>= (lower-test-functions-call-count functions "tl_arena_set") 3)
    (>= (lower-test-functions-call-count functions "tl_arena_make") 1)
    (>= (lower-test-functions-call-count functions "tl_arena_destroy") 1)
    (= (lower-test-functions-call-count functions "tl_region_mark") 0)
    (= (lower-test-functions-call-count functions "tl_region_reset") 0)))

(define (compiler-lower-with-scratch-arena-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (compiler-lower-with-scratch-arena-functions-shape-ok? functions)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-scratch-owning-shape-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-with-scratch-owning-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-scratch-arena-functions-shape-ok? functions)
            (> (lower-test-functions-call-count functions "tl_alloc") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-scratch-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-with-scratch-arena-shape-ok?
        (compiler-lower-with-scratch-scalar-source))
        unit
        (set! ok false))
      (if (match (lower-compiler-source
        (compiler-lower-with-scratch-string-source))
        [(ResultCompilerLower.Ok program _)
          (match program
            [(CompilerIrProgram.Program _ functions _)
              (and
                (compiler-lower-with-scratch-arena-shape-ok?
                  (compiler-lower-with-scratch-string-source))
                (> (lower-test-functions-call-count functions "tl_substring") 0))])]
        [(ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      (if (compiler-lower-with-scratch-owning-shape-ok?)
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-runtime-substring-scratch-reachable-ok?) : bool
  (match (parse-ast-source (compiler-lower-runtime-substring-scratch-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-substring-scratch-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "stdlib/runtime.tl::substring")
                (>
                  (lower-test-function-call-count
                    functions
                    "main"
                    "tl_substring")
                  0))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-runtime-substring-call-reachable-ok?) : bool
  (match (parse-ast-source (compiler-lower-runtime-substring-call-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-substring-scratch-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "stdlib/runtime.tl::substring")
                (>
                  (lower-test-function-call-count
                    functions
                    "main"
                    "tl_substring")
                  0))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-runtime-substring-capturing-lambda-reachable-ok?) : bool
  (match (parse-ast-source
    (compiler-lower-runtime-substring-capturing-lambda-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-substring-scratch-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "stdlib/runtime.tl::substring")
                (>
                  (lower-test-function-call-count
                    functions
                    "main"
                    "tl_substring")
                  0))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-runtime-atomic-reachable-ok?) : bool
  (match (parse-ast-source (compiler-lower-runtime-atomic-reachable-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-atomic-reachable-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "stdlib/runtime.tl::atomic-i64-fetch-add-ptr!")
                (not
                  (lower-test-function-defined?
                    functions
                    "stdlib/runtime.tl::atomic-i64-load-ptr"))
                (>
                  (lower-test-function-call-count
                    functions
                    "main"
                    "tl_atomic_i64_fetch_add_ptr")
                  0))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-in-arena-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : i64
  (let
    [scratch : Arena (arena-make)]
    (in-arena scratch
      (let [text : String (string.int->string 42)] 42))))"))

(define (compiler-lower-in-arena-return-source) : String
  (compiler-lower-with-arena-source
    "(define (main [flag : bool]) : i64
  (let
    [scratch : Arena (arena-make)]
    (in-arena scratch
      (begin
        (if flag (return 7) unit)
        42))))"))

(define (compiler-lower-tls-current-arena-source) : String
  "(define (main) : i64
  (let
    [arena : i64 (tls-current-arena)]
    (begin
      (unsafe (tls-current-arena-set! arena))
      arena)))")

(define (compiler-lower-tls-current-arena-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tls-current-arena-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                functions
                "main"
                "tl_tls_current_arena_load")
              1)
            (=
              (lower-test-function-call-count
                functions
                "main"
                "tl_tls_current_arena_store")
              1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-in-arena-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (match (lower-compiler-source (compiler-lower-in-arena-source))
        [(ResultCompilerLower.Ok program _)
          (match program
            [(CompilerIrProgram.Program _ functions _)
              (and
                (>=
                  (lower-test-functions-call-count functions "tl_arena_current")
                  1)
                (>=
                  (lower-test-functions-call-count functions "tl_arena_set")
                  2))])]
        [(ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      (if (match (lower-compiler-source (compiler-lower-in-arena-return-source))
        [(ResultCompilerLower.Ok program _)
          (match program
            [(CompilerIrProgram.Program _ functions _)
              (and
                (>=
                  (lower-test-functions-call-count functions "tl_arena_current")
                  1)
                (>=
                  (lower-test-functions-call-count functions "tl_arena_set")
                  3)
                (> (lower-test-functions-return-count functions) 1))])]
        [(ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-repr-c-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-repr-c-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (> (lower-test-function-gep-offset-count functions "main" 4) 0)
            (> (lower-test-function-gep-offset-count functions "main" 12) 0))])]
    [(ResultCompilerLower.Err _) false]))

;; `foreach` scalar lowering: a foreach `main` lowers to a loop, so its
;; body holds at least the guard branch (`i < end`) and two binops (the `<`
;; guard and the `+ 1` increment).
(define (compiler-lower-foreach-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-branch-count functions "main") 0)
            (> (lower-test-function-binop-count functions "main") 1))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-foreach-map-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-foreach-borrowed-array-map-source) : String
  "(define (fill [a : (& a (Array i64))] [b : (& b (Array i64))] [out : (&mut out (Array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i32-source) : String
  "(define (fill [a : (Array i32)] [b : (Array i32)] [out : (Array i32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u64-source) : String
  "(define (fill [a : (Array u64)] [b : (Array u64)] [out : (Array u64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u32-source) : String
  "(define (fill [a : (Array u32)] [b : (Array u32)] [out : (Array u32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i16-source) : String
  "(define (fill [a : (Array i16)] [b : (Array i16)] [out : (Array i16)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u16-source) : String
  "(define (fill [a : (Array u16)] [b : (Array u16)] [out : (Array u16)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-f64-source) : String
  "(define (fill [a : (Array f64)] [b : (Array f64)] [out : (Array f64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-f32-source) : String
  "(define (fill [a : (Array f32)] [b : (Array f32)] [out : (Array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i8-source) : String
  "(define (fill [a : (Array i8)] [b : (Array i8)] [out : (Array i8)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u8-source) : String
  "(define (fill [a : (Array u8)] [b : (Array u8)] [out : (Array u8)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-uniform-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i64)] [out : (Array i64)] [n : i64] [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-i32-source) : String
  "(define (fill [a : (Array i32)] [b : (Array i32)] [out : (Array i32)] [n : i64] [r : i32]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-u64-source) : String
  "(define (fill [a : (Array u64)] [b : (Array u64)] [out : (Array u64)] [n : i64] [r : u64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (* (array-ref b i) r)) (cast 7 : u64)))))")

(define (compiler-lower-avx2-foreach-map-uniform-u32-source) : String
  "(define (fill [a : (Array u32)] [b : (Array u32)] [out : (Array u32)] [n : i64] [r : u32]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (* (array-ref b i) r)) (cast 7 : u32)))))")

(define (compiler-lower-avx2-foreach-map-uniform-i16-source) : String
  "(define (fill [a : (Array i16)] [b : (Array i16)] [out : (Array i16)] [n : i64] [r : i16]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-u16-source) : String
  "(define (fill [a : (Array u16)] [b : (Array u16)] [out : (Array u16)] [n : i64] [r : u16]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-f64-source) : String
  "(define (fill [a : (Array f64)] [b : (Array f64)] [out : (Array f64)] [n : i64] [r : f64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-f32-source) : String
  "(define (fill [a : (Array f32)] [b : (Array f32)] [out : (Array f32)] [n : i64] [r : f32]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-i8-source) : String
  "(define (fill [a : (Array i8)] [b : (Array i8)] [out : (Array i8)] [n : i64] [r : i8]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-u8-source) : String
  "(define (fill [a : (Array u8)] [b : (Array u8)] [out : (Array u8)] [n : i64] [r : u8]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-zip-uniform-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i64)] [c : (Array i64)] [out : (Array i64)] [n : i64] [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (* (array-ref a i) (array-ref b i)) (array-ref c i)) r))))")

(define (compiler-lower-spmd-broadcast-source) : String
  "(define (fill [a : (Array i64)] [out : (Array i64)] [n : i64] [lane : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref a i) lane))))")

(define (compiler-lower-spmd-broadcast-u64-source) : String
  "(define (fill [a : (Array u64)] [out : (Array u64)] [n : i64] [lane : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref a i) lane))))")

(define (compiler-lower-spmd-broadcast-u32-source) : String
  "(define (fill [a : (Array u32)] [out : (Array u32)] [n : i64] [lane : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref a i) lane))))")

(define (compiler-lower-spmd-shuffle-source) : String
  "(define (fill [a : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-shuffle (array-ref a i) i))))")

(define (compiler-lower-avx2-foreach-scalar-fallback-source) : String
  "(define (fill [a : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a (+ i 1)) 1))))")

(define (compiler-lower-avx2-foreach-map-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx2))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (and
              (= load-count 2)
              (= binop-count 1)
              (= store-count 1)
              (= shape-count 4)
              (> tail-store-count 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (AstType.I64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-foreach-borrowed-array-map-source)
      (AstType.I64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i32-source)
      (AstType.I32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u64-source)
      (AstType.U64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u32-source)
      (AstType.U32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i16-source)
      (AstType.I16)
      16)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u16-source)
      (AstType.U16)
      16)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f64-source)
      (AstType.F64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f32-source)
      (AstType.F32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i8-source)
      (AstType.I8)
      32)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u8-source)
      (AstType.U8)
      32)))

(define (compiler-lower-avx2-foreach-uniform-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]
  [want-loads : i64]
  [want-binops : i64]
  [want-shapes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx2))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (and
              (= load-count want-loads)
              (= binop-count want-binops)
              (= store-count 1)
              (= shape-count want-shapes)
              (> tail-store-count 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-foreach-uniform-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-source)
      (AstType.I64)
      4
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i32-source)
      (AstType.I32)
      8
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u64-source)
      (AstType.U64)
      4
      2
      3
      8)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u32-source)
      (AstType.U32)
      8
      2
      3
      8)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i16-source)
      (AstType.I16)
      16
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u16-source)
      (AstType.U16)
      16
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f64-source)
      (AstType.F64)
      4
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f32-source)
      (AstType.F32)
      8
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i8-source)
      (AstType.I8)
      32
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u8-source)
      (AstType.U8)
      32
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-zip-uniform-source)
      (AstType.I64)
      4
      3
      3
      8)))

(define (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx2))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "fill") 0)
            (= (lower-test-function-vector-store-count functions "fill") 1)
            (=
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)
              2)
            (> (lower-test-function-bounds-count functions "fill") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-broadcast-avx2-shape-ok?) : bool
  (and
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-source)
      (AstType.I64)
      4)
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-u64-source)
      (AstType.U64)
      4)
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-u32-source)
      (AstType.U32)
      8)))

(define (compiler-lower-and8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (and a b c d e f g h))

(define (compiler-lower-avx512-foreach-map-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 2)
              (= binop-count 2)
              (= store-count 1)
              (= pred-load-count 2)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count 8)
              (> tail-store-count 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (AstType.I64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-foreach-borrowed-array-map-source)
      (AstType.I64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i32-source)
      (AstType.I32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u64-source)
      (AstType.U64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u32-source)
      (AstType.U32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i16-source)
      (AstType.I16)
      32)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u16-source)
      (AstType.U16)
      32)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f64-source)
      (AstType.F64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f32-source)
      (AstType.F32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i8-source)
      (AstType.I8)
      64)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u8-source)
      (AstType.U8)
      64)))

(define (compiler-lower-avx512-foreach-uniform-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]
  [want-loads : i64]
  [want-pred-loads : i64]
  [want-binops : i64]
  [want-shapes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count want-loads)
              (= binop-count want-binops)
              (= store-count 1)
              (= pred-load-count want-pred-loads)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count want-shapes)
              (> tail-store-count 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-foreach-uniform-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-source)
      (AstType.I64)
      8
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i32-source)
      (AstType.I32)
      16
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u64-source)
      (AstType.U64)
      8
      2
      2
      6
      16)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u32-source)
      (AstType.U32)
      16
      2
      2
      6
      16)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i16-source)
      (AstType.I16)
      32
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u16-source)
      (AstType.U16)
      32
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f64-source)
      (AstType.F64)
      8
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f32-source)
      (AstType.F32)
      16
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i8-source)
      (AstType.I8)
      64
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u8-source)
      (AstType.U8)
      64
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-zip-uniform-source)
      (AstType.I64)
      8
      3
      3
      6
      16)))

(define (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "fill") 0)
            (= (lower-test-function-vector-store-count functions "fill") 1)
            (= (lower-test-function-predicated-store-count functions "fill") 1)
            (= (lower-test-function-tail-mask-count functions "fill") 1)
            (=
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)
              4)
            (> (lower-test-function-bounds-count functions "fill") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-broadcast-avx512-shape-ok?) : bool
  (and
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-source)
      (AstType.I64)
      8)
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-u64-source)
      (AstType.U64)
      8)
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-u32-source)
      (AstType.U32)
      16)))

(define (compiler-lower-avx512-masked-if-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (array-set! out i 0)
      (array-set! out i (+ (array-ref xs i) 1)))))")

(define (compiler-lower-avx512-masked-if-offset-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs (+ i 1)) 0)
      (array-set! out (+ i 1) 0)
      (array-set! out (+ i 1) (+ (array-ref xs (+ i 1)) 1)))))")

(define (compiler-lower-avx512-masked-if-index-value-source) : String
  "(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 6)
      (array-set! out i i)
      (array-set! out i (+ i 1)))))")

(define (compiler-lower-avx512-masked-if-index-mod-source) : String
  "(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (= (% i 2) 0)
      (array-set! out i (+ i 10))
      (array-set! out i (+ i 100)))))")

(define (compiler-lower-avx512-masked-if-value-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i
      (if (< (array-ref xs i) 0)
        0
        (+ (array-ref xs i) 1)))))")

(define (compiler-lower-masked-if-bitand-value-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64] [bias : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i
      (if (= (bit-and (array-ref xs i) 1) 1)
        (+ (array-ref xs i) bias)
        (- (array-ref xs i) bias)))))")

(define (compiler-lower-masked-if-bitwise-value-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (array-set! out i
        (if (< x 8)
          (bit-or 1 x)
          (match (bit-and x 3)
            [0 (bit-xor x 3)]
            [_ (bit-or (bit-xor x 5) 2)]))))))")

(define (compiler-lower-masked-if-shift-value-source) : String
  "(define (fill
  [xs : (Array i64)]
  [counts : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      [count : i64 (array-ref counts i)]
      (array-set! out i
        (if (< x 0)
          (shr x count)
          (shl x count))))))")

(define (compiler-lower-masked-if-narrow-shift-source) : String
  "(define (fill
  [xs : (Array i16)]
  [out : (Array i16)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i16 (array-ref xs i)]
      (array-set! out i
        (if (< x 0)
          (shr x 1)
          (shl x 1))))))")

(define (compiler-lower-avx512-masked-if-nested-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (if (< x 0)
        (array-set! out i -10)
        (if (= x 0)
          (array-set! out i 0)
          (if (< x 6)
            (array-set! out i 6)
            (array-set! out i 12)))))))")

(define (compiler-lower-avx512-masked-if-source-shape-ok? [src : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 0)
              (>= binop-count 2)
              (>= pred-load-count 3)
              (>= pred-store-count 4)
              (= tail-mask-count 1)
              (> tail-store-count 0)
              true))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-masked-if-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-source)))

(define (compiler-lower-avx512-masked-if-offset-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-offset-source)))

(define (compiler-lower-avx512-masked-if-index-value-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-index-value-source)
    (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                8
                (AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 0)
              (= store-count 0)
              (>= binop-count 3)
              (= pred-load-count 0)
              (>= pred-store-count 4)
              (= tail-mask-count 1)
              (>= shape-count 5)
              (> tail-store-count 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-masked-if-index-mod-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-index-mod-source)
    (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                8
                (AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 0)
              (= store-count 0)
              (>= binop-count 6)
              (= pred-load-count 0)
              (>= pred-store-count 4)
              (= tail-mask-count 1)
              (>= shape-count 9)
              (> tail-store-count 0)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-masked-if-value-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-value-source)
    (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [select-count : i64
              (lower-test-function-select-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                8
                (AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 1)
              (>= binop-count 2)
              (>= pred-load-count 3)
              (= pred-store-count 1)
              (= select-count 2)
              (= tail-mask-count 1)
              (and (>= shape-count 7) (> tail-store-count 0))))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-if-bitand-value-shape-ok?
  [mode : CompilerLowerMode]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-masked-if-bitand-value-source)
    mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64 (lower-simd-lanes-for-elem mode (AstType.I64))]
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [select-count : i64
              (lower-test-function-select-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                (AstType.I64))]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 1)
              (>= binop-count 6)
              (>= pred-load-count 5)
              (= pred-store-count 1)
              (= select-count 2)
              (= tail-mask-count 1)
              (>= shape-count 15)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-if-bitwise-value-shape-ok?
  [mode : CompilerLowerMode]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-masked-if-bitwise-value-source)
    mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64 (lower-simd-lanes-for-elem mode (AstType.I64))]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [bit-or-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (CompilerIrBinOp.BitOr))]
            [bit-xor-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (CompilerIrBinOp.BitXor))]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [select-count : i64
              (lower-test-function-select-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                (AstType.I64))]
            (and
              (>= binop-count 8)
              (>= bit-or-count 4)
              (>= bit-xor-count 4)
              (>= pred-load-count 1)
              (= pred-store-count 1)
              (>= select-count 4)
              (>= shape-count 16)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-if-shift-value-shape-ok?
  [mode : CompilerLowerMode]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-masked-if-shift-value-source)
    mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64 (lower-simd-lanes-for-elem mode (AstType.I64))]
            [shl-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (CompilerIrBinOp.Shl))]
            [shr-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (CompilerIrBinOp.Shr))]
            [abort-count : i64
              (lower-test-functions-call-count functions "tl_shift_abort")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                (AstType.I64))]
            (begin
              (unless
                (= shl-count 2)
                (panic "lower: masked shift shl IR count mismatch"))
              (unless
                (= shr-count 2)
                (panic "lower: masked shift shr IR count mismatch"))
              (unless
                (= abort-count 4)
                (panic "lower: masked shift abort call count mismatch"))
              (unless
                (>= shape-count 20)
                (panic "lower: masked shift vector shape count mismatch"))
              true))])]
    [(ResultCompilerLower.Err diag)
      (panic (compiler-diagnostic-message (box-get diag)))]))

(define (compiler-lower-masked-if-narrow-shift-diagnostic-ok?
  [mode : CompilerLowerMode]
  [mode-name : String]) : bool
  (compiler-lower-mode-error-ok?
    (compiler-lower-masked-if-narrow-shift-source)
    mode
    (str_cat.str-cat
      "lower: SPMD masked if does not support masked shift 'shr' for lane type i16 in "
      mode-name
      " backend mode; supported lane types are i32, u32, i64, and u64")))

(define (compiler-lower-masked-shift-tests-ok?) : bool
  (begin
    (unless
      (compiler-lower-masked-if-shift-value-shape-ok? (CompilerLowerMode.Avx2))
      (panic "lower: AVX2 masked shift shape mismatch"))
    (unless
      (compiler-lower-masked-if-shift-value-shape-ok?
        (CompilerLowerMode.Avx512))
      (panic "lower: AVX-512 masked shift shape mismatch"))
    (unless
      (compiler-lower-masked-if-narrow-shift-diagnostic-ok?
        (CompilerLowerMode.Avx2)
        "AVX2")
      (panic "lower: AVX2 narrow masked shift diagnostic mismatch"))
    (unless
      (compiler-lower-masked-if-narrow-shift-diagnostic-ok?
        (CompilerLowerMode.Avx512)
        "AVX-512")
      (panic "lower: AVX-512 narrow masked shift diagnostic mismatch"))
    true))

(define (compiler-lower-avx512-masked-if-nested-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-nested-source)
    (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                8
                (AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 0)
              (> pred-load-count 0)
              (> pred-store-count 0)
              (= tail-mask-count 1)
              (> shape-count 0)
              (> tail-store-count 0)
              true))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-masked-if-source-shape-ok? [src : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx2))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [select-count : i64
              (lower-test-function-select-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            (and
              (>
                (+
                  (+ (+ load-count store-count) pred-load-count)
                  (+ pred-store-count select-count))
                0)
              (= tail-mask-count 1)))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-masked-if-shape-ok?) : bool
  (and
    (compiler-lower-avx2-masked-if-source-shape-ok?
      (compiler-lower-avx512-masked-if-source))
    (compiler-lower-avx2-masked-if-source-shape-ok?
      (compiler-lower-avx512-masked-if-offset-source))
    (compiler-lower-avx2-masked-if-source-shape-ok?
      (compiler-lower-avx512-masked-if-index-value-source))
    (compiler-lower-avx2-masked-if-source-shape-ok?
      (compiler-lower-avx512-masked-if-index-mod-source))
    (compiler-lower-avx2-masked-if-source-shape-ok?
      (compiler-lower-avx512-masked-if-value-source))
    (compiler-lower-avx2-masked-if-source-shape-ok?
      (compiler-lower-avx512-masked-if-nested-source))))

(define (compiler-lower-scalar-foreach-stays-scalar-ok?) : bool
  (match (lower-compiler-source (compiler-lower-avx2-foreach-map-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (= (lower-test-function-vector-load-count functions "fill") 0)])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-lane-array-source) : String
  "(define (fill [zeros : (Array f32)] [out : (Array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (array-ref zeros (program-index)))))")

(define (compiler-lower-spmd-lane-array-shape-ok?
  [mode : CompilerLowerMode]
  [predicated? : bool]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-spmd-lane-array-source)
    mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-vector-load-count functions "fill") 0)
            (> (lower-test-function-vector-store-count functions "fill") 0)
            (> (lower-test-function-bounds-count functions "fill") 0)
            (if predicated?
              (and
                (>
                  (lower-test-function-predicated-load-count functions "fill")
                  0)
                (>
                  (lower-test-function-predicated-store-count functions "fill")
                  0))
              true))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-simd-foreach-fallback-diagnostic-ok?) : bool
  (and
    (compiler-lower-mode-error-ok?
      (compiler-lower-avx2-foreach-scalar-fallback-source)
      (CompilerLowerMode.Avx2)
      (lower-simd-foreach-fallback-diagnostic))
    (compiler-lower-mode-error-ok?
      (compiler-lower-avx2-foreach-scalar-fallback-source)
      (CompilerLowerMode.Avx512)
      (lower-simd-foreach-fallback-diagnostic))))

(define (compiler-lower-spmd-shuffle-lowering-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-spmd-shuffle-source))
    (compiler-lower-mode-error-ok?
      (compiler-lower-spmd-shuffle-source)
      (CompilerLowerMode.Avx2)
      (lower-spmd-shuffle-diagnostic))
    (compiler-lower-mode-error-ok?
      (compiler-lower-spmd-shuffle-source)
      (CompilerLowerMode.Avx512)
      (lower-spmd-shuffle-diagnostic))))

(define (compiler-lower-spmd-out-of-line-value-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (heavy i))))")

(define (compiler-lower-spmd-out-of-line-unit-source) : String
  "(define (touch-heavy [x : i64]) : unit
  (begin
    (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7)
    unit))
(define (fill [n : i64]) : unit
  (foreach ([i : i64 0 n]) (touch-heavy i)))")

(define (compiler-lower-spmd-out-of-line-masked-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 4)
      (array-set! out i (heavy i))
      (array-set! out i 0))))")

(define (compiler-lower-spmd-source-call-count
  [src : String]
  [mode : CompilerLowerMode]) : i64
  (match (lower-compiler-source-with-mode src mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (lower-test-function-spmd-call-count functions "fill")])]
    [(ResultCompilerLower.Err _) (- 0 1)]))

(define (compiler-lower-spmd-source-function-count
  [src : String]
  [mode : CompilerLowerMode]) : i64
  (match (lower-compiler-source-with-mode src mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (compiler-ir-function-list-count functions)])]
    [(ResultCompilerLower.Err _) (- 0 1)]))

(define (compiler-lower-spmd-scalar-call-shape-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (touch-heavy [x : i64]) : unit
  (begin
    (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7)
    unit))
(define (fill-value [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (heavy i))))
(define (fill-unit [n : i64]) : unit
  (foreach ([i : i64 0 n]) (touch-heavy i)))")

(define (compiler-lower-spmd-varying-local-call-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (+ i 1)]
      (array-set! out i (heavy x)))))")

(define (compiler-lower-spmd-uniform-arg-call-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (Array i64)] [n : i64] [offset : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (heavy (+ offset 1)))))")

(define (compiler-lower-imported-spmd-selection-error-contains?
  [result : ResultLowerImportedSpmdSpecialization]
  [fragment : String]) : bool
  (match result
    [(ResultLowerImportedSpmdSpecialization.Ok _) false]
    [(ResultLowerImportedSpmdSpecialization.Err diag)
      (let
        [message : String (compiler-diagnostic-message (box-get diag))]
        (string.contains (& message) (& fragment)))]))

(define (compiler-lower-imported-spmd-selection-smoke-ok?) : bool
  (let
    [canonical-name : i64 (ci.intern-generated-canonical-name "fixture/helper")]
    [signature : String "(-> i64 i64)"]
    [specializations : AstImportedSpmdSpecializationList
      (ast-imported-spmd-specialization-list-new)]
    [callables : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-new)]
    [empty-callables : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-new)]
    [duplicate-callables : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-new)]
    [unsupported-specializations : AstImportedSpmdSpecializationList
      (ast-imported-spmd-specialization-list-new)]
    [unsupported-callables : AstImportedSpmdCallableList
      (ast-imported-spmd-callable-list-new)]
    [missing-message-fragment : String "has no TLCI callable metadata"]
    [signature-message-fragment : String "ordinary signature mismatch"]
    [specialization-message-fragment : String "has no requested specialization"]
    [abi-message-fragment : String
      "uses unsupported private ABI `spmd-call-v2`"]
    [duplicate-message-fragment : String "has duplicate TLCI specializations"]
    [avx2-message-fragment : String "is not supported in AVX2 backend mode"]
    [origin : AstExpr (AstExpr.Literal (ast-lit-int 0))]
    (begin
      (ast-imported-spmd-specialization-list-push
        (&mut specializations)
        (AstImportedSpmdSpecialization
          (ci.intern-generated-canonical-name "spmd-call-v1")
          (ci.intern-generated-canonical-name "scalar")
          1
          (ci.intern-generated-canonical-name "v")
          (ci.intern-generated-canonical-name "v")
          0
          (ci.intern-generated-canonical-name "_tl___fixture_helper_scalar")))
      (ast-imported-spmd-callable-list-push
        (&mut callables)
        (AstImportedSpmdCallable
          (ci.intern-generated-canonical-name signature)
          specializations))
      (ast-imported-spmd-callable-list-push
        (&mut duplicate-callables)
        (AstImportedSpmdCallable
          (ci.intern-generated-canonical-name signature)
          specializations))
      (ast-imported-spmd-callable-list-push
        (&mut duplicate-callables)
        (AstImportedSpmdCallable
          (ci.intern-generated-canonical-name signature)
          specializations))
      (ast-imported-spmd-specialization-list-push
        (&mut unsupported-specializations)
        (AstImportedSpmdSpecialization
          (ci.intern-generated-canonical-name "spmd-call-v2")
          (ci.intern-generated-canonical-name "scalar")
          1
          (ci.intern-generated-canonical-name "v")
          (ci.intern-generated-canonical-name "v")
          0
          (ci.intern-generated-canonical-name "__fixture_helper_v2")))
      (ast-imported-spmd-callable-list-push
        (&mut unsupported-callables)
        (AstImportedSpmdCallable
          (ci.intern-generated-canonical-name signature)
          unsupported-specializations))
      (and
        (match (lower-imported-spmd-select
          canonical-name
          (& callables)
          signature
          (CompilerIrSpmdBackend.Scalar)
          1
          "v"
          0
          (AstType.I64)
          origin)
          [(ResultLowerImportedSpmdSpecialization.Ok selected)
            (and
              (string.eq
                (intern-str (struct-get selected symbol))
                "_tl___fixture_helper_scalar")
              (string.eq
                (intern-str (lower-imported-spmd-ir-symbol selected))
                "__fixture_helper_scalar"))]
          [(ResultLowerImportedSpmdSpecialization.Err _) false])
        (match (lower-imported-spmd-select
          canonical-name
          (& empty-callables)
          signature
          (CompilerIrSpmdBackend.Scalar)
          1
          "v"
          0
          (AstType.I64)
          origin)
          [(ResultLowerImportedSpmdSpecialization.Ok _) false]
          [(ResultLowerImportedSpmdSpecialization.Err diag)
            (let
              [message : String (compiler-diagnostic-message (box-get diag))]
              (string.contains (& message) (& missing-message-fragment)))])
        (compiler-lower-imported-spmd-selection-error-contains?
          (lower-imported-spmd-select
            canonical-name
            (& callables)
            "(-> i64 u64)"
            (CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (AstType.I64)
            origin)
          signature-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (lower-imported-spmd-select
            canonical-name
            (& callables)
            signature
            (CompilerIrSpmdBackend.Avx512)
            8
            "v"
            0
            (AstType.I64)
            origin)
          specialization-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (lower-imported-spmd-select
            canonical-name
            (& callables)
            signature
            (CompilerIrSpmdBackend.Scalar)
            1
            "v"
            -1
            (AstType.I64)
            origin)
          specialization-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (lower-imported-spmd-select
            canonical-name
            (& unsupported-callables)
            signature
            (CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (AstType.I64)
            origin)
          abi-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (lower-imported-spmd-select
            canonical-name
            (& duplicate-callables)
            signature
            (CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (AstType.I64)
            origin)
          duplicate-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (lower-imported-spmd-select
            canonical-name
            (& callables)
            signature
            (CompilerIrSpmdBackend.Avx2)
            4
            "v"
            0
            (AstType.I64)
            origin)
          avx2-message-fragment)))))

(define (compiler-lower-spmd-scalar-call-shape-ok?) : bool
  (and
    (compiler-lower-imported-spmd-selection-smoke-ok?)
    (match (lower-compiler-source-with-mode
      (compiler-lower-spmd-scalar-call-shape-source)
      (CompilerLowerMode.Scalar))
      [(ResultCompilerLower.Ok program _)
        (match program
          [(CompilerIrProgram.Program _ functions _)
            (and
              (> (lower-test-function-spmd-call-count functions "fill-value") 0)
              (> (lower-test-function-spmd-call-count functions "fill-unit") 0)
              (> (compiler-ir-function-list-count functions) 4)
              (match lower-spmd-scalar-call-context
                [(LowerSpmdScalarCallContext.No) true]
                [(LowerSpmdScalarCallContext.Some _) false]))])]
      [(ResultCompilerLower.Err _) false])))

(define (compiler-lower-spmd-varying-local-call-shape-ok?) : bool
  (>
    (compiler-lower-spmd-source-call-count
      (compiler-lower-spmd-varying-local-call-source)
      (CompilerLowerMode.Avx512))
    0))

(define (compiler-lower-spmd-uniform-arg-call-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-spmd-uniform-arg-call-source)
    (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-spmd-call-count functions "fill") 0)
            (=
              (lower-test-function-binop-op-count
                functions
                "fill"
                (CompilerIrBinOp.Add))
              5))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-out-of-line-call-shape-ok?) : bool
  (and
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-value-source)
        (CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-masked-source)
        (CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-value-source)
        (CompilerLowerMode.Avx512))
      2)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (CompilerLowerMode.Avx512))
      2)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-value-source)
        (CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-masked-source)
        (CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-value-source)
        (CompilerLowerMode.Avx2))
      2)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (CompilerLowerMode.Avx2))
      2)
    (compiler-lower-spmd-varying-local-call-shape-ok?)
    (compiler-lower-spmd-uniform-arg-call-shape-ok?)))

(define (compiler-lower-foreach-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
      (compiler-lower-ok?
        "(define (f [a : (Array i64)] [n : i64]) : unit (foreach ([i : i64 0 n]) (array-set! a i i)))")
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 0]) unit) 0))")
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) (foreach ([j : i64 0 2]) unit)) 0))")
      (compiler-lower-foreach-shape-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
      (compiler-lower-avx2-foreach-map-shape-ok?)
      (compiler-lower-avx512-foreach-map-shape-ok?)
      (compiler-lower-avx2-foreach-uniform-shape-ok?))
    (compiler-lower-avx512-foreach-uniform-shape-ok?)
    (compiler-lower-spmd-lane-array-shape-ok? (CompilerLowerMode.Avx2) false)
    (compiler-lower-spmd-lane-array-shape-ok? (CompilerLowerMode.Avx512) true)
    (compiler-lower-spmd-broadcast-avx2-shape-ok?)
    (compiler-lower-spmd-broadcast-avx512-shape-ok?)
    (compiler-lower-scalar-foreach-stays-scalar-ok?)
    (compiler-lower-simd-foreach-fallback-diagnostic-ok?)
    (compiler-lower-spmd-shuffle-lowering-ok?)
    (compiler-lower-avx512-masked-if-shape-ok?)
    (compiler-lower-avx512-masked-if-offset-shape-ok?)
    (compiler-lower-avx512-masked-if-index-value-shape-ok?)
    (compiler-lower-avx512-masked-if-index-mod-shape-ok?)
    (compiler-lower-avx512-masked-if-value-shape-ok?)
    (compiler-lower-masked-if-bitand-value-shape-ok? (CompilerLowerMode.Avx2))
    (compiler-lower-masked-if-bitand-value-shape-ok? (CompilerLowerMode.Avx512))
    (compiler-lower-masked-if-bitwise-value-shape-ok? (CompilerLowerMode.Avx2))
    (compiler-lower-masked-if-bitwise-value-shape-ok?
      (CompilerLowerMode.Avx512))
    (compiler-lower-masked-shift-tests-ok?)
    (compiler-lower-avx512-masked-if-nested-shape-ok?)
    (compiler-lower-avx2-masked-if-shape-ok?)))

(define (compiler-lower-avx2-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]
  [vector-shapes : i64]
  [vector-binops : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx2))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 1)
            (= (lower-test-function-vector-reduce-count functions "f") 1)
            (=
              (lower-test-function-vector-binop-count functions "f")
              vector-binops)
            (=
              (lower-test-function-vector-shape-count
                functions
                "f"
                lanes
                elem-ty)
              vector-shapes)
            (> (lower-test-function-bounds-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-bool-reduce-shape-ok?
  [src : String]
  [mode : CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 0)
            (= (lower-test-function-vector-reduce-count functions "f") 0)
            (= (lower-test-function-predicated-load-count functions "f") 1)
            (= (lower-test-function-tail-mask-count functions "f") 1)
            (=
              (lower-test-function-vector-shape-count
                functions
                "f"
                lanes
                (AstType.Bool))
              1)
            (> (lower-test-function-bounds-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-map-fused-shape-ok?
  [mode : CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode
    "(define (f [xs : (Array i64)] [n : i64] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0
    (+ (+ (array-ref xs i) r) (bit-and (program-index) 0))))"
    mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 1)
            (= (lower-test-function-vector-reduce-count functions "f") 1)
            (= (lower-test-function-vector-binop-count functions "f") 4)
            (=
              (lower-test-function-vector-shape-count
                functions
                "f"
                lanes
                (AstType.I64))
              9)
            (> (lower-test-function-bounds-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]
  [vector-shapes : i64]
  [vector-binops : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerMode.Avx512))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 1)
            (= (lower-test-function-vector-reduce-count functions "f") 1)
            (=
              (lower-test-function-vector-binop-count functions "f")
              vector-binops)
            (=
              (lower-test-function-vector-shape-count
                functions
                "f"
                lanes
                elem-ty)
              vector-shapes)
            (> (lower-test-function-bounds-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-lane-identity-source) : String
  "(define (f [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (program-count) (program-index))))")

(define (compiler-lower-spmd-reduce-lane-identity-shape-ok?
  [mode : CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-spmd-reduce-lane-identity-source)
    mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 0)
            (= (lower-test-function-vector-reduce-count functions "f") 1)
            (= (lower-test-function-vector-binop-count functions "f") 2)
            (=
              (lower-test-function-vector-shape-count
                functions
                "f"
                lanes
                (AstType.I64))
              5)
            (= (lower-test-function-bounds-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-gather-source-shape-ok?
  [source : String]
  [mode : CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode source mode)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 0)
            (= (lower-test-function-vector-reduce-count functions "f") 1)
            (=
              (lower-test-function-vector-shape-count
                functions
                "f"
                lanes
                (AstType.F32))
              2)
            (> (lower-test-function-bounds-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-gather-shape-ok?
  [mode : CompilerLowerMode]
  [lanes : i64]) : bool
  (and
    (compiler-lower-spmd-reduce-gather-source-shape-ok?
      "(define (f [xs : (Array f32)] [ix : (Array i64)] [n : i64]) : f32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs (array-ref ix i))))"
      mode
      lanes)
    (compiler-lower-spmd-reduce-gather-source-shape-ok?
      "(define (f [xs : (Array f32)] [offsets : (Array i64)] [n : i64]) : f32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs (+ i (array-ref offsets (program-index))))))"
      mode
      lanes)))

(define (compiler-lower-avx2-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
        (AstType.I64)
        4
        4
        1)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
        (AstType.I32)
        8
        4
        1)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I32)
        8
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I32)
        8
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (AstType.F64)
        4
        2
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I64)
        4
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I64)
        4
        4
        0)
      (compiler-lower-spmd-reduce-lane-identity-shape-ok?
        (CompilerLowerMode.Avx2)
        4))
    (compiler-lower-avx2-spmd-reduce-shape-ok?
      "(define (f [xs : (Array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
      (AstType.F32)
      8
      2
      0)
    (compiler-lower-spmd-reduce-map-fused-shape-ok? (CompilerLowerMode.Avx2) 4)
    (compiler-lower-spmd-reduce-gather-shape-ok? (CompilerLowerMode.Avx2) 8)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))"
      (CompilerLowerMode.Avx2)
      32)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))"
      (CompilerLowerMode.Avx2)
      32)))

(define (compiler-lower-avx512-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
        (AstType.I64)
        8
        4
        1)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I64)
        8
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I64)
        8
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (AstType.F64)
        8
        2
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I32)
        16
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstType.I32)
        16
        4
        0)
      (compiler-lower-spmd-reduce-lane-identity-shape-ok?
        (CompilerLowerMode.Avx512)
        8)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (Array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
        (AstType.F32)
        16
        2
        0))
    (compiler-lower-spmd-reduce-map-fused-shape-ok?
      (CompilerLowerMode.Avx512)
      8)
    (compiler-lower-spmd-reduce-gather-shape-ok? (CompilerLowerMode.Avx512) 16)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))"
      (CompilerLowerMode.Avx512)
      64)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))"
      (CompilerLowerMode.Avx512)
      64)))

;; `spmd-reduce` lowering: integer, f32, and f64 sum reductions lower (to
;; an accumulator loop, so `main` holds the guard branch + fold/increment
;; binops), and the min/max/all/any reduction ops lower as well.
(define (compiler-lower-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-ok?
      "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (Array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))")
    (compiler-lower-foreach-shape-ok?
      "(define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 i))")
    (compiler-lower-ok?
      "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))")
    (compiler-lower-avx2-spmd-reduce-tests-ok?)
    (compiler-lower-avx512-spmd-reduce-tests-ok?)))

;; Comptime folding of the remaining scalar operators: each `(comptime ...)`
;; must collapse to a single constant `mov` with no residual runtime binop,
;; complementing the `+`/`<`/`*`/`let` cases already in the self-test.
(define (compiler-lower-comptime-op-fold-tests-ok?) : bool
  (and
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (- 50 8)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (/ 84 2)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (% 142 100)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (bit-and 63 42)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (bit-or 40 2)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (bit-xor 63 21)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (shl 21 1)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (shr 84 1)))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (if (= 5 5) 42 0)))"
      42)))

;; `size-of`/`align-of` comptime layout queries: a scalar type
;; folds to its byte size / alignment (equal for primitives) inside `(comptime ...)`.
(define (compiler-lower-layout-query-fold-tests-ok?) : bool
  (and
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (size-of (type i64))))"
      8)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (align-of (type i64))))"
      8)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (size-of (type i32))))"
      4)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (size-of (type bool))))"
      1)
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (size-of (type char))))"
      1)
    (compiler-lower-comptime-fold-ok?
      "(defstruct Inner
  (:repr c)
  (x i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail i64))
(define (main) : i64
  (comptime (+ (size-of (type Outer))
    (+ (align-of (type Outer))
      (+ (offset-of (type Outer) inner)
        (+ (offset-of (type Outer) tail) 6))))))"
      42)
    (compiler-lower-comptime-fold-ok?
      "(defstruct Pair (x i64) (y i64))
(define (main) : i64
  (comptime
    (+ (size-of (type (Array u8 3)))
      (+ (align-of (type (Array u8 3)))
        (+ (size-of (type (Array i64 3)))
          (+ (align-of (type (Array i64 3)))
            (+ (size-of (type (Array Pair 2)))
              (align-of (type (Array Pair 2))))))))))"
      76)
    ;; An enum is inline storage — an 8-byte tag plus max-aligned payload — so
    ;; `size-of` on the enum type must agree with what `offset-of` reports for a
    ;; struct field of that type. The enum arms used to answer with the tag
    ;; width alone, so `Wide` measured 8 against the 48 bytes it actually
    ;; occupies, and a fixed array of enums scaled that error by its length.
    (compiler-lower-comptime-fold-ok?
      "(defenum Narrow (N i64))
(defenum Wide (W i64 i64 i64 i64 i64))
(defstruct HoldsWide
  (w Wide)
  (tail i64))
(define (main) : i64
  (comptime
    (+ (size-of (type Wide))
      (+ (size-of (type Narrow))
        (+ (align-of (type Wide))
          (+ (offset-of (type HoldsWide) tail)
            (size-of (type (Array Narrow 2)))))))))"
      152)
    ;; The lifetime-parameterized spelling reaches the `EnumArgs` arm. It
    ;; already answered from the recorded layout, so this pins the two arms
    ;; agreeing rather than a change: tag plus one reference-sized payload.
    (compiler-lower-comptime-fold-ok?
      "(defenum SharedNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))
(define (main) : i64
  (comptime
    (+ (size-of (type (SharedNext holder)))
      (align-of (type (SharedNext holder))))))"
      24)
    (compiler-lower-error-ok?
      "(define (main) : i64 (size-of (type i64)))"
      "typecheck: size-of is compile-time only; wrap it in (comptime ...)")))

;; `and`/`or` short-circuit lowering: `(and a b)` and `(or a b)`
;; desugar to a conditional branch, so a function whose body is a bare `and`/`or`
;; of two boolean params must emit at least one branch and NO eager binop (the
;; old `CompilerIrBinOp.And`/`CompilerIrBinOp.Or` path would have produced one binop and no branch).
(define (compiler-lower-and-short-circuit-source) : String
  "(defmacro (and [args : bool ...]) : bool
  `(and-from (__and-args ,@args) 0))
(defmacro (and-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool true)
            `(if ,(expr-list-nth elems i)
               (and-from ,carrier ,(expr-int (+ i 1)))
               false))]
        [_ (expr-bool true)])]
    [_ (expr-bool true)]))
(define (f [a : bool] [b : bool]) : bool (and a b))")

(define (compiler-lower-or-short-circuit-source) : String
  "(defmacro (or [args : bool ...]) : bool
  `(or-from (__or-args ,@args) 0))
(defmacro (or-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool false)
            `(if ,(expr-list-nth elems i)
               true
               (or-from ,carrier ,(expr-int (+ i 1)))))]
        [_ (expr-bool false)])]
    [_ (expr-bool false)]))
(define (f [a : bool] [b : bool]) : bool (or a b))")

(define (compiler-lower-short-circuit-branch? [src : String]) : bool
  (match (lower-compiler-source src)
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (> (lower-test-function-branch-count functions "f") 0)
            (= (lower-test-function-binop-count functions "f") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-and-or-short-circuit-shape-ok?) : bool
  (and
    (compiler-lower-short-circuit-branch?
      (compiler-lower-and-short-circuit-source))
    (compiler-lower-short-circuit-branch?
      (compiler-lower-or-short-circuit-source))))

(define (compiler-lower-raw-pointer-ops-ok?) : bool
  (and
    (compiler-lower-raw-pointer-addr-of-shape-ok?)
    (compiler-lower-register-addr-of-shape-ok?)
    (compiler-lower-raw-pointer-aggregate-copy-shape-ok?)
    (compiler-lower-ok? (compiler-lower-raw-pointer-direct-call-source))
    (compiler-lower-ok? (compiler-lower-raw-pointer-call-value-source))))

(define (compiler-lower-raw-pointer-addr-of-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-raw-pointer-ops-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (= (lower-test-function-addr-of-count functions "main") 1)
            (>= (lower-test-function-store-ptr-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-register-addr-of-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-register-addr-of-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (>= (lower-test-function-addr-of-count functions "main") 3)
            (>= (lower-test-function-gep-offset-count functions "main" 4) 1)
            (>= (lower-test-function-gep-offset-count functions "main" 8) 1)
            (>= (lower-test-function-store-ptr-count functions "main") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-raw-pointer-call-value-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-raw-pointer-call-value-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-functions-call-count functions "raw-make") 1)
            (= (lower-test-functions-call-count functions "raw-value") 1)
            (= (lower-test-function-store-ptr-count functions "main") 1)
            (> (lower-test-function-u64-mov-count functions "main") 0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-raw-pointer-aggregate-copy-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-raw-pointer-aggregate-copy-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-copy-bytes-count functions "copy-slot") 1)
            (= (lower-test-function-store-ptr-count functions "copy-slot") 0)
            (= (lower-test-function-copy-bytes-count functions "copy-pair") 0)
            (= (lower-test-function-store-ptr-count functions "copy-pair") 2))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-string-length-ok?) : bool
  (match (parse-ast-source (compiler-lower-string-length-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program program)
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (and
                (>
                  (lower-test-function-gep-offset-count
                    functions
                    "core-str-len"
                    1)
                  0)
                (>
                  (lower-test-function-gep-offset-count
                    functions
                    "core-str-len-borrow"
                    1)
                  0)
                (=
                  (lower-test-functions-direct-call-count functions "length")
                  0))])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-float-bitcast-ok?) : bool
  (match (lower-compiler-source (compiler-lower-float-bitcast-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-function-bitcast-count functions "f64-bits") 1)
            (= (lower-test-function-bitcast-count functions "f32-bits") 1)
            (= (lower-test-function-bitcast-count functions "f64-from") 1)
            (= (lower-test-function-bitcast-count functions "f32-from") 1)
            (= (lower-test-functions-call-count functions "tl_alloc") 0)
            (=
              (lower-test-functions-direct-call-count
                functions
                "__tl_float_to_bits")
              0)
            (=
              (lower-test-functions-direct-call-count
                functions
                "__tl_float_from_bits")
              0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-literal-float-to-bits-ok?) : bool
  (match (lower-compiler-source (compiler-lower-literal-float-to-bits-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (and
            (= (lower-test-functions-bitcast-count functions) 0)
            (=
              (lower-test-functions-direct-call-count
                functions
                "__tl_float_to_bits")
              0))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-public-literal-float-to-bits-ok?) : bool
  (match (parse-ast-source (compiler-lower-public-literal-float-to-bits-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "stdlib/math.tl"
        program
        (compiler-lower-public-literal-float-to-bits-paths))
        [(ResultCompilerLower.Ok lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (= (lower-test-functions-bitcast-count functions) 0)])]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-string-runtime-ok?) : bool
  (match (parse-ast-source (compiler-lower-string-runtime-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program program)
        [(ResultCompilerLower.Ok _ _) true]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-stdio-ok?) : bool
  (match (parse-ast-source (compiler-lower-stdio-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program program)
        [(ResultCompilerLower.Ok _ _) true]
        [(ResultCompilerLower.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-stdio-builtin-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-stdio-builtin-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions ".L_tl_flush_stdout")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions ".L_tl_stdin_eof")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_read_stdin_line")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_read_stdin_bytes")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "flush-stdout")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "stdin-eof?") 1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "read-stdin-line")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "io.read-stdin-bytes")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-env-builtin-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-env-builtin-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions "tl_env_var_exists")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_env_var_value")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count functions "var-exists?")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count functions "var-value")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "path-separator")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-stdlib-helper-defaults-disabled-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (when
        (lower-bootstrap-runtime-builtin-id?
          cbi.compiler-builtin-id-env-path-separator)
        (set! ok false))
      (when
        (not
          (lower-bootstrap-runtime-builtin-id?
            cbi.compiler-builtin-id-tl-private-string-eq))
        (set! ok false))
      (when
        (not
          (lower-bootstrap-runtime-builtin-id?
            cbi.compiler-builtin-id-tl-private-string-to-int))
        (set! ok false))
      (when (lower-string-runtime-builtin? "substring") (set! ok false))
      (when (lower-string-runtime-builtin? "string-slice") (set! ok false))
      (when (lower-string-runtime-builtin? "string-append") (set! ok false))
      (when (lower-string-runtime-builtin? "string-concat") (set! ok false))
      ok)))

(define (compiler-lower-cpu-builtin-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-cpu-builtin-source))
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>= (lower-test-functions-cpuid-count functions) 4)
                unit
                (set! ok false))
              (if (= (lower-test-functions-xgetbv-count functions) 1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "cpuid") 0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "xgetbv") 0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "tl_cpuid") 0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "tl_xgetbv") 0)
                unit
                (set! ok false))
              ok))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-runtime-helper-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-string-length-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-float-bitcast-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-literal-float-to-bits-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-public-literal-float-to-bits-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-string-wrapper-prune-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-runtime-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-runtime-shape-ok?
        (compiler-lower-string-runtime-source))
        unit
        (set! ok false))
      (if (compiler-lower-string-concat-fusion-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-print-string-stdlib-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-borrowed-str-param-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-hash-string-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-shadow-shape-ok?
        (compiler-lower-string-shadow-source))
        unit
        (set! ok false))
      (if (compiler-lower-stdio-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdio-builtin-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-helper-defaults-disabled-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-env-builtin-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-cpu-builtin-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-fs-status-shape-ok?)
        unit
        (set! ok false))
      ok)))

(define (lower-test-decl-list-count [decls : AstDeclList]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons _ rest)
      (let
        [rest : AstDeclList rest]
        (+ 1 (lower-test-decl-list-count rest)))]))

(define (lower-test-decl-list-defines? [decls : AstDeclList] [name : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.DefFn decl-meta found _ _ _ _)
            (if (string.eq (tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(AstDecl.DefEnum decl-meta found _ _)
            (if (string.eq (tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(AstDecl.DefEnumLifetimes decl-meta found _ _ _)
            (if (string.eq (tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(AstDecl.DefStruct decl-meta found _ _ _)
            (if (string.eq (tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(AstDecl.DefStructLifetimes decl-meta found _ _ _ _)
            (if (string.eq (tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(AstDecl.Unsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (if (lower-test-decl-list-defines?
                (ast-decl-cons inner (ast-decl-list-new))
                name)
                true
                (lower-test-decl-list-defines? rest name)))]
          [_ (lower-test-decl-list-defines? rest name)]))]))

(define (compiler-lower-ast-dce-program) : AstProgram
  (let
    [callback-id : i64 (lower-test-generated-name-id "callback")]
    [callback-target-id : i64 cbi.compiler-builtin-id-fix-callback_target]
    [main-id : i64 cbi.compiler-builtin-id-fix-main]
    [helper-id : i64 cbi.compiler-builtin-id-fix-helper]
    [dead-id : i64 (lower-test-generated-name-id "dead")]
    (ast-program
      (ast-decl-cons
        (ast-decl-def-id
          callback-id
          AstMaybeType.No
          (ast-node-push (AstExpr.Var callback-target-id)))
        (ast-decl-cons
          (ast-decl-def-fn-id
            main-id
            (ast-param-list-new)
            (AstType.I64)
            (ast-expr-call
              (ast-node-push (AstExpr.Var helper-id))
              (ast-expr-list-new)))
          (ast-decl-cons
            (ast-decl-def-fn-id
              helper-id
              (ast-param-list-new)
              (AstType.I64)
              (ast-node-push (AstExpr.Literal (ast-lit-int 7))))
            (ast-decl-cons
              (ast-decl-def-fn-id
                callback-target-id
                (ast-param-list-new)
                (AstType.I64)
                (ast-node-push (AstExpr.Literal (ast-lit-int 11))))
              (ast-decl-cons
                (ast-decl-def-fn-id
                  dead-id
                  (ast-param-list-new)
                  (AstType.I64)
                  (ast-node-push (AstExpr.Literal (ast-lit-int 9))))
                (ast-decl-list-new)))))))))

(define (compiler-lower-dce-test-symbols-ready?) : bool
  (match (parse-ast-source
    "(define callback : i64 0)
(define main : i64 0)
(define helper : i64 0)
(define callback-target : i64 0)
(define dead : i64 0)
(define macro-only-helper : i64 0)
(define macro-uses-helper : i64 0)
(define stdlib.comptime : i64 0)
(define ctfe-runtime-helper : i64 0)
(define ExprClauseList : i64 0)
(define UsedEnum : i64 0)
(define UsedA : i64 0)
(define DeadEnum : i64 0)
(define DeadA : i64 0)
(define UsedBox : i64 0)
(define value : i64 0)
(define DeadBox : i64 0)
(define io.ResultIoString : i64 0)
(define OkIoString : i64 0)
(define io.DeadResult : i64 0)
(define DeadResultA : i64 0)
(define stdlib.arena : i64 0)
(define Arena : i64 0)
(define handle : i64 0)
(define ArenaMark : i64 0)
(define DeadArenaPeer : i64 0)
(define ThreadBox : i64 0)
(define owner : i64 0)
(define ImportedMark : i64 0)
(define mark : i64 0)
(define DeadMark : i64 0)
(define uses-imported-mark-annotation : i64 0)
(define struct.match.geom : i64 0)
(define QPoint : i64 0)
(define x : i64 0)
(define y : i64 0)
(define DeadGeom : i64 0)
(define geom.QPoint : i64 0)
(define entry.tl : i64 0)
(define types.tl : i64 0)")
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-ast-dce-no-main-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def-fn-id
        (lower-test-generated-name-id "helper")
        (ast-param-list-new)
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 7))))
      (ast-decl-cons
        (ast-decl-def-fn-id
          (lower-test-generated-name-id "dead")
          (ast-param-list-new)
          (AstType.I64)
          (ast-node-push (AstExpr.Literal (ast-lit-int 9))))
        (ast-decl-list-new)))))

(define (compiler-lower-macro-body-dce-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def-fn-id
        (lower-test-generated-name-id "main")
        (ast-param-list-new)
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
      (ast-decl-cons
        (ast-decl-def-fn-id
          (lower-test-generated-name-id "macro-only-helper")
          (ast-param-list-new)
          (AstType.I64)
          (ast-node-push (AstExpr.Literal (ast-lit-int 7))))
        (ast-decl-cons
          (ast-decl-def-macro-id
            (lower-test-generated-name-id "macro-uses-helper")
            (ast-macro-param-list-new)
            (AstType.Expr)
            (ast-expr-call
              (ast-node-push
                (AstExpr.Var cbi.compiler-builtin-id-fix-macro_only_helper))
              (ast-expr-list-new)))
          (ast-decl-list-new))))))

(define (compiler-lower-stdlib-comptime-runtime-dce-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-module-id (lower-test-generated-name-id "stdlib.comptime"))
      (ast-decl-cons
        (ast-decl-def-fn-id
          (lower-test-generated-name-id "ctfe-runtime-helper")
          (ast-param-list-new)
          (AstType.I64)
          (ast-node-push (AstExpr.Literal (ast-lit-int 7))))
        (ast-decl-cons
          (ast-decl-module-id (lower-test-generated-name-id "main"))
          (ast-decl-cons
            (ast-decl-def-fn-id
              (lower-test-generated-name-id "main")
              (ast-param-list-new)
              (AstType.I64)
              (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
            (ast-decl-list-new)))))))

(define (compiler-lower-stdlib-comptime-runtime-skip-keeps-types-ok?) : bool
  (let
    [decls : AstDeclList
      (ast-decl-cons
        (ast-decl-def-fn-id
          (lower-test-generated-name-id "ctfe-runtime-helper")
          (ast-param-list-new)
          (AstType.I64)
          (ast-node-push (AstExpr.Literal (ast-lit-int 7))))
        (ast-decl-cons
          (ast-decl-comptime-decl
            (ast-decl-def-struct-id
              (lower-test-generated-name-id "ExprClauseList")
              AstStructRepr.Default
              AstStructCleanup.No
              (ast-field-def-list-new)))
          (ast-decl-cons
            (ast-decl-module-id (lower-test-generated-name-id "main"))
            (ast-decl-cons
              (ast-decl-def-fn-id
                (lower-test-generated-name-id "main")
                (ast-param-list-new)
                (AstType.I64)
                (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
              (ast-decl-list-new)))))]
    [kept : AstDeclList (lower-skip-runtime-until-next-module decls)]
    (and
      (= (lower-test-decl-list-count kept) 3)
      (lower-test-decl-list-defines? kept "ExprClauseList")
      (lower-test-decl-list-defines? kept "main")
      (not (lower-test-decl-list-defines? kept "ctfe-runtime-helper")))))

(define (compiler-lower-stdlib-comptime-type-prune-keeps-types-ok?) : bool
  (let
    [program : AstProgram
      (ast-program
        (ast-decl-cons
          (ast-decl-module-id (lower-test-generated-name-id "stdlib.comptime"))
          (ast-decl-cons
            (ast-decl-def-fn-id
              (lower-test-generated-name-id "ctfe-runtime-helper")
              (ast-param-list-new)
              (AstType.I64)
              (ast-node-push (AstExpr.Literal (ast-lit-int 7))))
            (ast-decl-cons
              (ast-decl-comptime-decl
                (ast-decl-def-struct-id
                  (lower-test-generated-name-id "ExprClauseList")
                  AstStructRepr.Default
                  AstStructCleanup.No
                  (ast-field-def-list-new)))
              (ast-decl-cons
                (ast-decl-module-id (lower-test-generated-name-id "main"))
                (ast-decl-cons
                  (ast-decl-def-fn-id
                    (lower-test-generated-name-id "main")
                    (ast-param-list-new)
                    (AstType.I64)
                    (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
                  (ast-decl-list-new)))))))]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls
              decls
              (ast-decl-path-list-new)
              "entry.tl"
              LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (ast-decl-path-list-new)
        names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (lower-test-decl-list-defines? kept "ExprClauseList")
                (lower-test-decl-list-defines? kept "main")
                (not (lower-test-decl-list-defines? kept "ctfe-runtime-helper"))))])])))

(define (compiler-lower-stdlib-comptime-nullary-enum-runtime-skip-ok?) : bool
  (match (lower-compiler-source
    "(import stdlib.comptime)
(define (main) : i64 0)")
    [(ResultCompilerLower.Ok program _)
      (match program
        [(CompilerIrProgram.Program globals _ _)
          (not
            (lower-test-global-list-has-name?
              globals
              "__enum_obj_stdlib.comptime/Pattern_Wildcard"))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-unsafe-ast-dce-source) : String
  "(define (main) : i64 (unsafe (unsafe-entry)))
(define (unsafe-helper) : i64 41)
(unsafe (define (unsafe-entry) : i64 (unsafe-helper)))
(define (dead-helper) : i64 0)
(unsafe (define (dead-unsafe) : i64 (dead-helper)))")

(define (compiler-lower-type-decl-dce-program) : AstProgram
  (let
    [used-enum-id : i64 cbi.compiler-builtin-id-fix-UsedEnum]
    [used-box-id : i64 cbi.compiler-builtin-id-fix-UsedBox]
    (ast-program
      (ast-decl-cons
        (ast-decl-def-enum-id
          used-enum-id
          AstEnumCleanup.No
          (ast-variant-def-cons
            (ast-variant-def-id
              (lower-test-generated-name-id "UsedA")
              (ast-type-list-new)
              (ast-variant-payload-cleanup-list-new))
            (ast-variant-def-list-new)))
        (ast-decl-cons
          (ast-decl-def-enum-id
            (lower-test-generated-name-id "DeadEnum")
            AstEnumCleanup.No
            (ast-variant-def-cons
              (ast-variant-def-id
                (lower-test-generated-name-id "DeadA")
                (ast-type-list-new)
                (ast-variant-payload-cleanup-list-new))
              (ast-variant-def-list-new)))
          (ast-decl-cons
            (ast-decl-def-struct-id
              used-box-id
              AstStructRepr.Default
              AstStructCleanup.No
              (ast-field-def-cons
                (ast-field-def-id
                  (lower-test-generated-name-id "value")
                  (AstType.Enum used-enum-id)
                  AstFieldCleanup.No)
                (ast-field-def-list-new)))
            (ast-decl-cons
              (ast-decl-def-struct-id
                (lower-test-generated-name-id "DeadBox")
                AstStructRepr.Default
                AstStructCleanup.No
                (ast-field-def-cons
                  (ast-field-def-id
                    (lower-test-generated-name-id "value")
                    (AstType.I64)
                    AstFieldCleanup.No)
                  (ast-field-def-list-new)))
              (ast-decl-cons
                (ast-decl-def-fn-id
                  cbi.compiler-builtin-id-fix-main
                  (ast-param-list-new)
                  (AstType.Struct used-box-id)
                  (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
                (ast-decl-list-new)))))))))

(define (compiler-lower-type-decl-dce-paths) : AstDeclPathList
  (let
    [types-id : i64 (compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (compiler-load-source-path-id "entry.tl")]
    (ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (ast-decl-path-cons-with-owner-id
          "types.tl"
          types-id
          (ast-decl-path-cons-with-owner-id
            "types.tl"
            types-id
            (ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (ast-decl-path-list-new))))))))

(define (compiler-lower-type-decl-dce-qualified-base-program) : AstProgram
  (let
    [result-id : i64 (compiler-load-parse-context-name-id "io.ResultIoString")]
    [dead-result-id : i64 (compiler-load-parse-context-name-id "io.DeadResult")]
    (ast-program
      (ast-decl-cons
        (ast-decl-def-enum-id
          result-id
          AstEnumCleanup.No
          (ast-variant-def-cons
            (ast-variant-def-id
              (lower-test-generated-name-id "OkIoString")
              (ast-type-list-new)
              (ast-variant-payload-cleanup-list-new))
            (ast-variant-def-list-new)))
        (ast-decl-cons
          (ast-decl-def-enum-id
            dead-result-id
            AstEnumCleanup.No
            (ast-variant-def-cons
              (ast-variant-def-id
                (lower-test-generated-name-id "DeadResultA")
                (ast-type-list-new)
                (ast-variant-payload-cleanup-list-new))
              (ast-variant-def-list-new)))
          (ast-decl-cons
            (ast-decl-def-fn-id
              cbi.compiler-builtin-id-fix-main
              (ast-param-list-new)
              (AstType.Enum result-id)
              (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
            (ast-decl-list-new)))))))

(define (compiler-lower-type-decl-dce-qualified-base-paths) : AstDeclPathList
  (let
    [types-id : i64 (compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (compiler-load-source-path-id "entry.tl")]
    (ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (ast-decl-path-cons-with-owner-id
          "entry.tl"
          entry-id
          (ast-decl-path-list-new))))))

(define (compiler-lower-type-decl-dce-arena-support-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-module-id (compiler-load-parse-context-name-id "stdlib.arena"))
      (ast-decl-cons
        (ast-decl-def-struct-id
          (intern-dotted-tail-id cbi.compiler-builtin-id-fix-arena_dot_Arena)
          AstStructRepr.Default
          AstStructCleanup.No
          (ast-field-def-cons
            (ast-field-def-id
              (lower-test-generated-name-id "handle")
              (AstType.I64)
              AstFieldCleanup.No)
            (ast-field-def-list-new)))
        (ast-decl-cons
          (ast-decl-def-struct-id
            cbi.compiler-builtin-id-fix-ArenaMark
            AstStructRepr.Default
            AstStructCleanup.No
            (ast-field-def-cons
              (ast-field-def-id
                (lower-test-generated-name-id "handle")
                (AstType.I64)
                AstFieldCleanup.No)
              (ast-field-def-list-new)))
          (ast-decl-cons
            (ast-decl-def-struct-id
              (lower-test-generated-name-id "DeadArenaPeer")
              AstStructRepr.Default
              AstStructCleanup.No
              (ast-field-def-cons
                (ast-field-def-id
                  (lower-test-generated-name-id "handle")
                  (AstType.I64)
                  AstFieldCleanup.No)
                (ast-field-def-list-new)))
            (ast-decl-cons
              (ast-decl-module-id cbi.compiler-builtin-id-fix-main)
              (ast-decl-cons
                (ast-decl-def-struct-id
                  cbi.compiler-builtin-id-fix-ThreadBox
                  AstStructRepr.Default
                  AstStructCleanup.No
                  (ast-field-def-cons
                    (ast-field-def-id
                      (lower-test-generated-name-id "owner")
                      (AstType.Struct
                        cbi.compiler-builtin-id-fix-arena_dot_Arena)
                      AstFieldCleanup.No)
                    (ast-field-def-list-new)))
                (ast-decl-cons
                  (ast-decl-def-fn-id
                    cbi.compiler-builtin-id-fix-main
                    (ast-param-list-new)
                    (AstType.Struct cbi.compiler-builtin-id-fix-ThreadBox)
                    (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
                  (ast-decl-list-new))))))))))

(define (compiler-lower-type-decl-dce-arena-support-paths) : AstDeclPathList
  (let
    [arena-id : i64 (compiler-load-source-path-id "arena.tl")]
    [entry-id : i64 (compiler-load-source-path-id "entry.tl")]
    [thread-id : i64 (compiler-load-source-path-id "thread.tl")]
    (ast-decl-path-cons-with-owner-id
      "arena.tl"
      arena-id
      (ast-decl-path-cons-with-owner-id
        "arena.tl"
        arena-id
        (ast-decl-path-cons-with-owner-id
          "arena.tl"
          arena-id
          (ast-decl-path-cons-with-owner-id
            "arena.tl"
            arena-id
            (ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (ast-decl-path-cons-with-owner-id
                "thread.tl"
                thread-id
                (ast-decl-path-cons-with-owner-id
                  "entry.tl"
                  entry-id
                  (ast-decl-path-list-new))))))))))

(define (compiler-lower-type-decl-dce-test-body-program) : AstProgram
  (let
    [unit-expr : i64 (ast-node-push (AstExpr.Literal (AstLiteral.Unit)))]
    [test-body : i64
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding-id
            (lower-test-generated-name-id "mark")
            (AstMaybeType.Some
              (AstType.Struct cbi.compiler-builtin-id-fix-ImportedMark))
            unit-expr)
          (ast-let-binding-list-new))
        unit-expr)]
    (ast-program
      (ast-decl-cons
        (ast-decl-def-struct-id
          cbi.compiler-builtin-id-fix-ImportedMark
          AstStructRepr.Default
          AstStructCleanup.No
          (ast-field-def-list-new))
        (ast-decl-cons
          (ast-decl-def-struct-id
            (lower-test-generated-name-id "DeadMark")
            AstStructRepr.Default
            AstStructCleanup.No
            (ast-field-def-list-new))
          (ast-decl-cons
            (ast-decl-test-id
              (lower-test-generated-name-id "uses-imported-mark-annotation")
              test-body
              (ast-source-span 1 1 1 1))
            (ast-decl-cons
              (ast-decl-def-fn-id
                cbi.compiler-builtin-id-fix-main
                (ast-param-list-new)
                (AstType.I64)
                (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
              (ast-decl-list-new))))))))

(define (compiler-lower-type-decl-dce-test-body-paths) : AstDeclPathList
  (let
    [types-id : i64 (compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (compiler-load-source-path-id "entry.tl")]
    (ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (ast-decl-path-cons-with-owner-id
          "entry.tl"
          entry-id
          (ast-decl-path-cons-with-owner-id
            "entry.tl"
            entry-id
            (ast-decl-path-list-new)))))))

(define (compiler-lower-type-decl-dce-body-pattern-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-module-id
        (compiler-load-parse-context-name-id "struct.match.geom"))
      (ast-decl-cons
        (ast-decl-def-struct-id
          (compiler-load-parse-context-name-id "QPoint")
          AstStructRepr.Default
          AstStructCleanup.No
          (ast-field-def-cons
            (ast-field-def-id
              (lower-test-generated-name-id "x")
              (AstType.I64)
              AstFieldCleanup.No)
            (ast-field-def-cons
              (ast-field-def-id
                (lower-test-generated-name-id "y")
                (AstType.I64)
                AstFieldCleanup.No)
              (ast-field-def-list-new))))
        (ast-decl-cons
          (ast-decl-def-struct-id
            (lower-test-generated-name-id "DeadGeom")
            AstStructRepr.Default
            AstStructCleanup.No
            (ast-field-def-cons
              (ast-field-def-id
                (lower-test-generated-name-id "value")
                (AstType.I64)
                AstFieldCleanup.No)
              (ast-field-def-list-new)))
          (ast-decl-cons
            (ast-decl-module-id cbi.compiler-builtin-id-fix-main)
            (ast-decl-cons
              (ast-decl-def-fn-id
                cbi.compiler-builtin-id-fix-main
                (ast-param-list-new)
                (AstType.I64)
                (ast-expr-match
                  (ast-node-push (AstExpr.Literal (ast-lit-int 0)))
                  (ast-match-arm-cons
                    (ast-match-arm
                      (ast-pat-variant-id
                        (compiler-load-parse-context-name-id "geom.QPoint")
                        (ast-pattern-cons
                          (ast-pat-binding-id
                            (lower-test-generated-name-id "x"))
                          (ast-pattern-cons
                            (ast-pat-binding-id
                              (lower-test-generated-name-id "y"))
                            (ast-pattern-list-new))))
                      (ast-node-push (AstExpr.Literal (ast-lit-int 0))))
                    (ast-match-arm-list-new))))
              (ast-decl-list-new))))))))

(define (compiler-lower-type-decl-dce-body-pattern-paths) : AstDeclPathList
  (let
    [geom-id : i64 (compiler-load-source-path-id "geom.tl")]
    [entry-id : i64 (compiler-load-source-path-id "entry.tl")]
    (ast-decl-path-cons-with-owner-id
      "geom.tl"
      geom-id
      (ast-decl-path-cons-with-owner-id
        "geom.tl"
        geom-id
        (ast-decl-path-cons-with-owner-id
          "geom.tl"
          geom-id
          (ast-decl-path-cons-with-owner-id
            "entry.tl"
            entry-id
            (ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (ast-decl-path-list-new))))))))

(define (compiler-lower-ast-dce-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-ast-dce-program)]
    [no-main-program : AstProgram (compiler-lower-ast-dce-no-main-program)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls
              decls
              (ast-decl-path-list-new)
              "entry.tl"
              LowerNameEnv.Nil))])]
    [no-main-names : LowerNameEnv
      (match no-main-program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls
              decls
              (ast-decl-path-list-new)
              "entry.tl"
              LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (ast-decl-path-list-new)
        names)]
    [no-main-pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        no-main-program
        (ast-decl-path-list-new)
        no-main-names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match no-main-pruned
          [(LowerPrunedProgram.Program kept-no-main _)
            (match kept-program
              [(AstProgram.Program kept-box)
                (let
                  [kept : AstDeclList (box-get kept-box)]
                  (match kept-no-main
                    [(AstProgram.Program no-main-kept-box)
                      (let
                        [no-main-kept : AstDeclList (box-get no-main-kept-box)]
                        (and
                          (= (lower-test-decl-list-count kept) 4)
                          (lower-test-decl-list-defines? kept "main")
                          (lower-test-decl-list-defines? kept "helper")
                          (lower-test-decl-list-defines? kept "callback-target")
                          (not (lower-test-decl-list-defines? kept "dead"))
                          (= (lower-test-decl-list-count no-main-kept) 2)))]))])])])))

(define (compiler-lower-type-decl-dce-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-type-decl-dce-program)]
    [paths : AstDeclPathList (compiler-lower-type-decl-dce-paths)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls decls paths "entry.tl" LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 3)
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "UsedBox")
                (lower-test-decl-list-defines? kept "UsedEnum")
                (not (lower-test-decl-list-defines? kept "DeadBox"))
                (not (lower-test-decl-list-defines? kept "DeadEnum"))))])])))

(define (compiler-lower-type-decl-dce-qualified-base-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-type-decl-dce-qualified-base-program)]
    [paths : AstDeclPathList
      (compiler-lower-type-decl-dce-qualified-base-paths)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls decls paths "entry.tl" LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 2)
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "io.ResultIoString")
                (not (lower-test-decl-list-defines? kept "io.DeadResult"))))])])))

(define (compiler-lower-type-decl-dce-arena-support-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-type-decl-dce-arena-support-program)]
    [paths : AstDeclPathList (compiler-lower-type-decl-dce-arena-support-paths)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls decls paths "entry.tl" LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "ThreadBox")
                (lower-test-decl-list-defines? kept "Arena")
                (lower-test-decl-list-defines? kept "ArenaMark")
                (not (lower-test-decl-list-defines? kept "DeadArenaPeer"))))])])))

(define (compiler-lower-type-decl-dce-test-body-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-type-decl-dce-test-body-program)]
    [paths : AstDeclPathList (compiler-lower-type-decl-dce-test-body-paths)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls decls paths "entry.tl" LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 3)
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "ImportedMark")
                (not (lower-test-decl-list-defines? kept "DeadMark"))))])])))

(define (compiler-lower-type-decl-dce-body-pattern-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-type-decl-dce-body-pattern-program)]
    [paths : AstDeclPathList (compiler-lower-type-decl-dce-body-pattern-paths)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls decls paths "entry.tl" LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "QPoint")
                (not (lower-test-decl-list-defines? kept "DeadGeom"))))])])))

(define (compiler-lower-macro-body-dce-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-macro-body-dce-program)]
    [names : LowerNameEnv
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls
              decls
              (ast-decl-path-list-new)
              "entry.tl"
              LowerNameEnv.Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (ast-decl-path-list-new)
        names)]
    (match pruned
      [(LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(AstProgram.Program kept-box)
            (let
              [kept : AstDeclList (box-get kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 2)
                (lower-test-decl-list-defines? kept "main")
                (not (lower-test-decl-list-defines? kept "macro-only-helper"))))])])))

(define (compiler-lower-stdlib-comptime-runtime-dce-ok?) : bool
  (match (lower-compiler-program-with-decl-paths
    "entry.tl"
    (compiler-lower-stdlib-comptime-runtime-dce-program)
    (ast-decl-path-list-new))
    [(ResultCompilerLower.Ok lowered _)
      (match lowered
        [(CompilerIrProgram.Program _ functions externs)
          (and
            (= (compiler-ir-function-list-count functions) 1)
            (= (compiler-ir-extern-list-count externs) 0)
            (lower-test-function-defined? functions "main"))])]
    [(ResultCompilerLower.Err _) false]))

(define (compiler-lower-unsafe-ast-dce-kept-ok? [kept : AstDeclList]) : bool
  (and
    (= (lower-test-decl-list-count kept) 3)
    (lower-test-decl-list-defines? kept "main")
    (lower-test-decl-list-defines? kept "unsafe-helper")
    (lower-test-decl-list-defines? kept "unsafe-entry")
    (not (lower-test-decl-list-defines? kept "dead-helper"))
    (not (lower-test-decl-list-defines? kept "dead-unsafe"))))

(define (compiler-lower-unsafe-ast-dce-ok?) : bool
  (match (parse-ast-source (compiler-lower-unsafe-ast-dce-source))
    [(ResultAstProgram.Ok program)
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [names : LowerNameEnv
              (lower-name-env-from-decls
                decls
                (ast-decl-path-list-new)
                "entry.tl"
                LowerNameEnv.Nil)]
            [pruned : LowerPrunedProgram
              (lower-test-prune-unreachable-functions
                "entry.tl"
                program
                (ast-decl-path-list-new)
                names)]
            (match pruned
              [(LowerPrunedProgram.Program kept-program _)
                (match kept-program
                  [(AstProgram.Program kept-box)
                    (compiler-lower-unsafe-ast-dce-kept-ok? (box-get kept-box))])]))])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-lower-name-env-dense-snapshots-ok?) : bool
  (let
    [source-id : i64 (ci.intern-generated-canonical-name "dense-source")]
    [sibling-id : i64 (ci.intern-generated-canonical-name "dense-sibling")]
    [overlay-id : i64 (ci.intern-generated-canonical-name "dense-overlay")]
    [alias-id : i64 (ci.intern-generated-canonical-name "dense-alias")]
    [base-logical-id : i64
      (ci.intern-generated-canonical-name "dense-base-logical")]
    [base-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-base-symbol")]
    [child-logical-id : i64
      (ci.intern-generated-canonical-name "dense-child-logical")]
    [child-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-child-symbol")]
    [sibling-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-sibling-symbol")]
    [overlay-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-overlay-symbol")]
    [right-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-right-symbol")]
    [left-old-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-left-old-symbol")]
    [left-new-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-left-new-symbol")]
    [copy-branch-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-copy-branch-symbol")]
    [grown-symbol-id : i64
      (ci.intern-generated-canonical-name "dense-grown-symbol")]
    [base : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        source-id
        base-logical-id
        base-symbol-id
        LowerNameEnv.Nil)]
    [child : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        source-id
        child-logical-id
        child-symbol-id
        base)]
    [sibling : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        sibling-id
        sibling-id
        sibling-symbol-id
        base)]
    [grown : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        source-id
        child-logical-id
        grown-symbol-id
        child)]
    [grow-index : i64 1]
    [_grow : unit
      (while (< grow-index 16)
        (begin
          (set!
            grown
            (lower-name-env-bind-logical-symbol-id
              source-id
              child-logical-id
              grown-symbol-id
              grown))
          (set! grow-index (+ grow-index 1))))]
    [copied : LowerNameEnv (lower-name-env-copy-active child)]
    [copy-branch : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        source-id
        source-id
        copy-branch-symbol-id
        copied)]
    [right : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        alias-id
        alias-id
        right-symbol-id
        LowerNameEnv.Nil)]
    [left : LowerNameEnv
      (lower-name-env-bind-logical-symbol-id
        alias-id
        alias-id
        left-new-symbol-id
        (lower-name-env-bind-logical-symbol-id
          alias-id
          alias-id
          left-old-symbol-id
          LowerNameEnv.Nil))]
    [appended : LowerNameEnv (lower-name-env-append left right)]
    [previous-global : LowerNameCache lower-active-global-name-cache]
    [_set-global : unit
      (set! lower-active-global-name-cache (lower-name-cache-from-env base))]
    [overlay : LowerNameCache
      (lower-name-cache-overlay
        (lower-name-env-bind-logical-symbol-id
          overlay-id
          overlay-id
          overlay-symbol-id
          LowerNameEnv.Nil)
        (ci.intern-generated-canonical-name "dense-overlay-module"))]
    [ok : bool
      (and
        (= (lower-name-env-count base) 1)
        (= (lower-name-env-count child) 2)
        (= (lower-name-env-count sibling) 2)
        (= (lower-name-env-count grown) 18)
        (= (lower-name-env-count copied) 2)
        (= (lower-name-env-count copy-branch) 3)
        (= (lower-name-env-count appended) 3)
        (= (lower-name-env-lookup-symbol-id base source-id -1) base-symbol-id)
        (= (lower-name-env-lookup-symbol-id child source-id -1) child-symbol-id)
        (=
          (lower-name-env-lookup-symbol-id sibling source-id -1)
          base-symbol-id)
        (= (lower-name-env-lookup-symbol-id grown source-id -1) grown-symbol-id)
        (=
          (lower-name-env-lookup-symbol-id sibling sibling-id -1)
          sibling-symbol-id)
        (=
          (lower-name-env-lookup-symbol-id copied source-id -1)
          child-symbol-id)
        (=
          (lower-name-env-lookup-symbol-id copy-branch source-id -1)
          copy-branch-symbol-id)
        (=
          (lower-name-env-lookup-symbol-id appended alias-id -1)
          left-new-symbol-id)
        (= (lower-name-env-lookup-symbol-id right alias-id -1) right-symbol-id)
        (string.eq
          (tc-env-key-name-text
            (lower-name-env-lookup-symbol-id copied source-id -1))
          (tc-env-key-name-text child-symbol-id))
        (=
          (lower-name-cache-lookup-symbol-id (& overlay) overlay-id -1)
          overlay-symbol-id)
        (=
          (lower-name-cache-lookup-symbol-id (& overlay) source-id -1)
          base-symbol-id)
        (match (lower-name-env-view child)
          [(LowerNameEnvView.Bind head-source _ head-symbol rest)
            (and
              (= head-source source-id)
              (= head-symbol child-symbol-id)
              (match (lower-name-env-view rest)
                [(LowerNameEnvView.Bind tail-source _ tail-symbol tail)
                  (and
                    (= tail-source source-id)
                    (= tail-symbol base-symbol-id)
                    (match tail
                      [(LowerNameEnv.Nil) true]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    (begin
      (set! lower-active-global-name-cache previous-global)
      ok)))

(test
  compiler-lower-name-env-dense-snapshots
  (test.assert-true
    (compiler-lower-name-env-dense-snapshots-ok?)
    "dense lower-name snapshots preserve overlays, append order, and names"))

;; The id-keyed compat prescan walker must agree with the two string-keyed
;; walks it replaces on every env-key family the prescan can meet: pool ids,
;; hygiene-local ids (post-splice trees), structural-local ids, and
;; composite keys, including bound-name shadowing.
(define (compiler-lower-compat-prescan-id-parity?
  [expr-bases : i64]
  [tree : AstExpr]
  [when-id : i64]
  [unless-id : i64]) : bool
  (=
    (tc-expr-uses-free-source-id?
      expr-bases
      tree
      when-id
      unless-id
      TcNameIdList.Nil)
    (or
      (tc-expr-uses-free-name? expr-bases tree "when" TcStringList.Nil)
      (tc-expr-uses-free-name? expr-bases tree "unless" TcStringList.Nil))))

(define (compiler-lower-compat-prescan-test-let
  [binder-id : i64]
  [init-id : i64]
  [body-id : i64]) : AstExpr
  (let
    [bindings : AstLetBindingList (ast-let-binding-list-with-capacity 1)]
    (begin
      (array-set!
        (struct-get bindings slots)
        0
        (AstLetBinding.Binding binder-id (AstMaybeType.No) init-id))
      (set! (struct-get bindings len) 1)
      (AstExpr.Let (box (AstLet.Let bindings body-id))))))

(define (compiler-lower-compat-prescan-id-parity-ok?) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-new-with-capacities 4 1)]
    [expr-bases : i64 (ast-node-pool-context-expr-segment-bases pools)]
    [when-id : i64 (ci.intern "when")]
    [unless-id : i64 (ci.intern "unless")]
    [x-id : i64 (ci.intern "x")]
    [hygiene-ctx : MacroHygieneContext
      (MacroHygieneContext
        (ci.intern "test-macro")
        (ci.intern "test-module")
        1360
        (compiler-symbols-empty))]
    [hyg-when-id : i64 (macro-hygiene-local-id hygiene-ctx 1 when-id)]
    [hyg-x-id : i64 (macro-hygiene-local-id hygiene-ctx 1 x-id)]
    [struct-when-id : i64 (ci.intern-structural-local-id 1 when-id)]
    [composite-id : i64
      (tc-module-name-id-by-id (ci.intern "stdlib.io") when-id)]
    [push-var
      (lambda ([name-id : i64]) : i64
        (ast-node-pool-context-expr-push pools (AstExpr.Var name-id)))]
    [when-var : i64 (push-var when-id)]
    [hyg-when-var : i64 (push-var hyg-when-id)]
    [x-var : i64 (push-var x-id)]
    (and
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var when-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var x-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var hyg-when-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var hyg-x-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var struct-when-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var composite-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (AstExpr.Var unless-id)
        when-id
        unless-id)
      ;; A pool binder named `when` shadows a pool use of `when`.
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (compiler-lower-compat-prescan-test-let when-id x-var when-var)
        when-id
        unless-id)
      ;; A differently-named binder does not shadow the use.
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (compiler-lower-compat-prescan-test-let x-id x-var when-var)
        when-id
        unless-id)
      ;; A pool binder named `when` also shadows a hygiene-id use whose
      ;; source name is `when` (the post-splice re-run shape).
      (compiler-lower-compat-prescan-id-parity?
        expr-bases
        (compiler-lower-compat-prescan-test-let when-id x-var hyg-when-var)
        when-id
        unless-id)
      ;; A hygiene binder whose source name is `when` shadows the hygiene
      ;; use (the string walker cannot see this shape: intern-str traps on
      ;; out-of-pool ids, so check the id walker directly).
      (not
        (tc-expr-uses-free-source-id?
          expr-bases
          (compiler-lower-compat-prescan-test-let
            hyg-when-id
            x-var
            hyg-when-var)
          when-id
          unless-id
          TcNameIdList.Nil)))))

(test
  compiler-lower-compat-prescan-id-parity
  (test.assert-true
    (compiler-lower-compat-prescan-id-parity-ok?)
    "id-keyed compat prescan matches the string-keyed walks incl. hygiene ids"))

(define (compiler-lower-boxed-helper-lists-ok?) : bool
  (let
    [source-a-id : i64 (ci.intern-generated-canonical-name "source-a")]
    [source-b-id : i64 (ci.intern-generated-canonical-name "source-b")]
    [names : LowerNameEnv
      (lower-name-env-bind-logical-id
        source-a-id
        "logical-a"
        source-a-id
        (lower-name-env-bind-logical-id
          source-b-id
          "logical-b"
          source-b-id
          LowerNameEnv.Nil))]
    [captures : LowerCaptureList
      (lower-capture-list-add-front
        (lower-capture-list-add-front
          (lower-capture-list-empty)
          (LowerCapture.Capture 102 2 (AstType.Bool) 8))
        (LowerCapture.Capture 101 1 (AstType.I64) 0))]
    [cleanups : LowerCleanupStack
      (lower-cleanup-stack-push
        (lower-cleanup-stack-push (lower-cleanup-stack-empty) 201 301)
        202
        302)]
    [slots : LowerCAbiSlotList
      (lower-c-abi-slot-list-pair
        (LowerCAbiSlot.Slot (AstType.I64) 0)
        (LowerCAbiSlot.Slot (AstType.F64) 8))]
    (and
      (= (lower-name-env-count names) 2)
      (string.eq
        (lower-name-env-resolve-with-id names "source-b" source-b-id)
        "logical-b")
      (= (lower-capture-list-count captures) 2)
      (lower-capture-list-contains-name? captures 102)
      (lower-capture-list-storage-entry? captures 0 102 2 8)
      (lower-capture-list-storage-entry? captures 1 101 1 0)
      (= (lower-cleanup-stack-count cleanups) 2)
      (lower-cleanup-stack-entry? cleanups 0 201 301)
      (lower-cleanup-stack-entry? cleanups 1 202 302)
      (= (lower-c-abi-slot-list-count slots) 2)
      (match (lower-c-abi-slot-list-ref slots 0)
        [(LowerCAbiSlot.Slot ty offset)
          (and (= offset 0) (tc-type-eq ty (AstType.I64)))])
      (match (lower-c-abi-slot-list-ref slots 1)
        [(LowerCAbiSlot.Slot ty offset)
          (and (= offset 8) (tc-type-eq ty (AstType.F64)))]))))

(define (compiler-lower-name-cache-intern-id-dotted-ok?) : bool
  (let
    [alias-id : i64 cbi.compiler-builtin-id-fix-alias]
    [value-id : i64 cbi.compiler-builtin-id-fix-value]
    [source-id : i64 (compiler-symbol-module-key-id-by-id alias-id value-id)]
    [logical : String "logical-value"]
    [split-source : String
      (compiler-symbol-module-key
        "name_cache_split_alias_3940"
        "name_cache_split_value_3940")]
    [split-source-missing-before : bool
      (match (intern-lookup split-source)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    [split-alias-id : i64
      cbi.compiler-builtin-id-fix-name_cache_split_alias_3940]
    [split-value-id : i64
      cbi.compiler-builtin-id-fix-name_cache_split_value_3940]
    [split-source-id : i64
      (compiler-symbol-module-key-id-by-id split-alias-id split-value-id)]
    [split-logical : String "split-logical-value"]
    [names : LowerNameEnv
      (lower-name-env-bind-logical-id
        split-source-id
        split-logical
        split-source-id
        (lower-name-env-bind-logical-id
          source-id
          logical
          source-id
          LowerNameEnv.Nil))]
    [cache : LowerNameCache (lower-name-cache-from-env names)]
    (and
      (>= source-id 0)
      (>= alias-id 0)
      (>= value-id 0)
      split-source-missing-before
      (>= split-alias-id 0)
      (>= split-value-id 0)
      (match (intern-lookup split-source)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])
      (match (lower-name-cache-resolve-id-display cache source-id)
        [(TcMaybeString.Some resolved) (string.eq resolved logical)]
        [(TcMaybeString.No) false])
      (match (lower-name-cache-resolve-id-display cache split-source-id)
        [(TcMaybeString.Some resolved) (string.eq resolved split-logical)]
        [(TcMaybeString.No) false]))))

(define (compiler-lower-type-cache-i64-keys-ok?) : bool
  (let
    [module : String "type_cache_mod_3939"]
    [name : String "TypeCacheThing3939"]
    [module-id : i64 (ci.intern-generated-name module)]
    [name-id : i64 (ci.intern-generated-name name)]
    [qualified-name : String (compiler-symbol-module-key module name)]
    [qualified-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [fallback-name : String "TypeCacheFallback3939"]
    [fallback-id : i64 (ci.intern-generated-name fallback-name)]
    [fallback-primary : String
      (compiler-symbol-module-key module fallback-name)]
    [fallback-primary-missing-before : bool
      (match (intern-lookup fallback-primary)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    [env : TcTypeEnv
      (tc-bind-id
        (tc-bind-id (tc-empty-env) qualified-id (AstType.I64))
        fallback-id
        (AstType.Bool))]
    [cache : LowerTypeCache (lower-type-cache-from-env env)]
    [missing : String "TypeCacheMissing3939"]
    [missing-id : i64 (+ (intern-capacity) 3939)]
    [missing-before : bool
      (match (intern-lookup missing)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    (and
      (string.eq (tc-env-key-display qualified-id) qualified-name)
      fallback-primary-missing-before
      missing-before
      (match (lower-type-cache-lookup-id cache qualified-id qualified-name)
        [(ResultTcType.Ok ty) (tc-type-eq ty (AstType.I64))]
        [(ResultTcType.Err _) false])
      (match (lower-type-cache-lookup-id cache fallback-id fallback-name)
        [(ResultTcType.Ok ty) (tc-type-eq ty (AstType.Bool))]
        [(ResultTcType.Err _) false])
      (match (lower-type-cache-lookup-id cache missing-id missing)
        [(ResultTcType.Ok _) false]
        [(ResultTcType.Err _) true])
      (match (intern-lookup fallback-primary)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])
      (match (intern-lookup missing)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true]))))

(define (compiler-lower-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-lower-back-half-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-name-env-dense-snapshots-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-boxed-helper-lists-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-name-cache-intern-id-dotted-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-type-cache-i64-keys-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-module-specialize-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-region-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-scratch-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-runtime-substring-scratch-reachable-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-runtime-substring-call-reachable-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-runtime-substring-capturing-lambda-reachable-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-runtime-atomic-reachable-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-in-arena-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-tls-current-arena-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-repr-c-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-branch-mismatch-source)
        "typecheck: if branches must match")
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-array-literal-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-fixed-array-return-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-box-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-box-get-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-reference-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-reference-auto-borrow-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok?
        (compiler-lower-reference-mut-dotted-field-source))
        unit
        (set! ok false))
      (if (compiler-lower-reference-values-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-reference-place-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-reference-nominal-aggregate-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-comptime-fold-ok?
        (compiler-lower-comptime-arith-source)
        3)
        unit
        (set! ok false))
      (if (compiler-lower-comptime-fold-ok?
        (compiler-lower-comptime-if-source)
        42)
        unit
        (set! ok false))
      (if (compiler-lower-comptime-fold-ok?
        (compiler-lower-comptime-let-source)
        42)
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-comptime-runtime-var-source)
        "compile-time evaluation cannot reference runtime variable 'x'")
        unit
        (set! ok false))
      (if (compiler-lower-comptime-f64-fold-ok?
        (compiler-lower-comptime-f64-source)
        "1.5")
        unit
        (set! ok false))
      (if (compiler-lower-comptime-f32-fold-ok?
        (compiler-lower-comptime-f32-source)
        "1")
        unit
        (set! ok false))
      (if (compiler-lower-comptime-op-fold-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-layout-query-fold-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-duplicate-function-source)
        "symbols: duplicate value declaration dup")
        unit
        (set! ok false))
      (if (compiler-lower-numeric-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-tail-call-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-foreach-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-array-var-set-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-spmd-reduce-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-dce-test-symbols-ready?)
        unit
        (set! ok false))
      (if (compiler-lower-ast-dce-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-type-decl-dce-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-type-decl-dce-qualified-base-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-type-decl-dce-arena-support-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-type-decl-dce-test-body-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-type-decl-dce-body-pattern-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-macro-body-dce-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-comptime-runtime-dce-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-comptime-runtime-skip-keeps-types-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-comptime-type-prune-keeps-types-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-comptime-nullary-enum-runtime-skip-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-unsafe-ast-dce-ok?)
        unit
        (set! ok false))
      ok)))