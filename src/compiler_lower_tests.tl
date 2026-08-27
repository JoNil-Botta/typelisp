;; compiler_lower_tests.tl - Selfhost lowering fixtures split from production.
(import compiler_lower)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_parse_core)
(import compiler_typecheck_core)
(import compiler_symbols)
(import compiler_typecheck_api)
(import compiler_load)
(import compiler_ctfe)
(import compiler_clone)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as lower_i64_i64_map)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)
(import stdlib.io)
(import stdlib.arena)
(import compiler_owned_view as owned_view)

;; --- fixtures moved from production compiler_lower.tl -------------------------
(define (lower-test-generated-name-id [value : String]) : i64
  (ci.intern-generated-canonical-name value))

(define (lower-test-generated-syntax-id [value : String]) : ci.InternSyntaxId
  (ci.intern-syntax-id-from-raw (lower-test-generated-name-id value)))

(define (lower-test-renderable-name-id [value : String]) : ci.InternId
  (ci.intern-id-from-renderable (ci.intern-generated-canonical-name value)))

(define (lower-test-renderable-name-id-with-state
  [interns : (&mut interns ci.InternCompatState)]
  [value : String]) : ci.InternId
  (ci.intern-id-from-renderable
    (ci.intern-compat-state-generated-canonical-name interns value)))

(define (lower-name-env-resolve-with-id
  [names : compiler_lower.LowerNameEnv]
  [source-name : String]
  [source-id : i64]) : String
  (match (compiler_lower.lower-name-env-lookup-with-id names source-id)
    [(compiler_typecheck_core.TcMaybeString.Some logical) logical]
    [(compiler_typecheck_core.TcMaybeString.No) source-name]))

(define (lower-prune-unreachable-functions-with-clone-roots
  [pools : compiler_ast_types.AstNodePoolContext]
  [entry-path : String]
  [program : compiler_ast_types.AstProgram]
  [paths : compiler_ast_types.AstDeclPathList]
  [names : compiler_lower.LowerNameEnv]
  [clone-roots : compiler_clone.CloneRootEntries]) : compiler_lower.LowerPrunedProgram
  (match (compiler_lower.lower-prune-unreachable-functions-with-clone-roots-and-plan
    (compiler_lower.compiler-lower-state-new)
    pools
    entry-path
    program
    paths
    names
    clone-roots)
    [(compiler_lower.LowerPrunedProgramWithPlan.Program
        pruned-program
        pruned-paths
        _)
      (compiler_lower.LowerPrunedProgram.Program pruned-program pruned-paths)]))

(define (lower-prune-unreachable-functions
  [pools : compiler_ast_types.AstNodePoolContext]
  [entry-path : String]
  [program : compiler_ast_types.AstProgram]
  [paths : compiler_ast_types.AstDeclPathList]
  [names : compiler_lower.LowerNameEnv]) : compiler_lower.LowerPrunedProgram
  (lower-prune-unreachable-functions-with-clone-roots
    pools
    entry-path
    program
    paths
    names
    (compiler_clone.CloneRootEntries.Empty)))

(define (lower-test-prune-unreachable-functions
  [entry-path : String]
  [program : compiler_ast_types.AstProgram]
  [paths : compiler_ast_types.AstDeclPathList]
  [names : compiler_lower.LowerNameEnv]) : compiler_lower.LowerPrunedProgram
  (lower-prune-unreachable-functions
    (compiler_ast_types.ast-node-pool-context-capture-active)
    entry-path
    program
    paths
    names))

(define (lower-capture-list-count [captures : compiler_lower.LowerCaptureList]) : i64
  captures.count)

(define (lower-capture-list-storage-entry?
  [captures : compiler_lower.LowerCaptureList]
  [index : i64]
  [name-id : i64]
  [var-id : i64]
  [offset : i64]) : bool
  (if (or (< index 0) (>= index captures.count))
    false
    (match (array-ref captures.items index)
      [(compiler_lower.LowerCapture.Capture
          capture-name-id
          capture-var-id
          _
          capture-offset)
        (and
          (= capture-name-id name-id)
          (= capture-var-id var-id)
          (= capture-offset offset))])))

(define (lower-cleanup-stack-count
  [cleanups : compiler_lower.LowerCleanupStack]) : i64
  cleanups.count)

(define (lower-cleanup-stack-entry?
  [cleanups : compiler_lower.LowerCleanupStack]
  [index : i64]
  [hidden-name-id : i64]
  [cleanup-name-id : i64]) : bool
  (if (or (< index 0) (>= index cleanups.count))
    false
    (and
      (= (array-ref cleanups.hidden-name-ids index) hidden-name-id)
      (= (array-ref cleanups.cleanup-name-ids index) cleanup-name-id))))

(define (compiler-lower-array-var-set-ok?) : bool
  (let
    [left : compiler_lower.LowerArrayVarSet
      (compiler_lower.lower-array-var-set-add
        (compiler_lower.lower-array-var-set-add
          (compiler_lower.lower-array-var-set-add
            (compiler_lower.lower-array-var-set-empty)
            10
            1)
          20
          2)
        10
        4)]
    [right : compiler_lower.LowerArrayVarSet
      (compiler_lower.lower-array-var-set-add
        (compiler_lower.lower-array-var-set-add
          (compiler_lower.lower-array-var-set-empty)
          30
          3)
        20
        1)]
    [merged : compiler_lower.LowerArrayVarSet
      (compiler_lower.lower-array-var-set-merge left right)]
    [vars : (__tl_dyn-array i64)
      (owned_view.compiler-owned-shared-view merged.vars)]
    [offsets : (__tl_dyn-array i64)
      (owned_view.compiler-owned-shared-view merged.offsets)]
    (and
      (= merged.count 3)
      (= (array-length vars) 3)
      (= (array-length offsets) 3)
      (= (array-ref vars 0) 10)
      (= (array-ref offsets 0) 4)
      (= (array-ref vars 1) 20)
      (= (array-ref offsets 1) 2)
      (= (array-ref vars 2) 30)
      (= (array-ref offsets 2) 3)
      (= (compiler_lower.lower-array-var-set-max-offset merged) 4))))

;; Lower every top-level decl of the expanded program. This used to be
;; a tail-recursive walk (one call per decl), but the inline-aggregate TCO
;; guard declines frame reuse here, so a whole-compiler input stacked
;; one ~56KB frame per decl (7,035 frames = 402MB of the measured 502MB stack
;; peak that forced the 1GB Windows reserves). Iterate instead; the
;; threaded accumulators become loop state.
(define (lower-skip-runtime-until-next-module
  [decls : compiler_ast_types.AstDeclList]) : compiler_ast_types.AstDeclList
  (match (compiler_ast_types.ast-decl-list-step
    (owned_view.compiler-owned-shared-view decls))
    [(compiler_ast_types.AstDeclListStep.Nil)
      (compiler_ast_types.ast-decl-list-new)]
    [(compiler_ast_types.AstDeclListStep.Cons decl rest)
      (let
        [rest : compiler_ast_types.AstDeclList rest]
        (match (owned_view.compiler-owned-shared-view decl)
          [(compiler_ast_types.AstDecl.Module _) decls]
          [_
            (let
              [kept-rest : compiler_ast_types.AstDeclList
                (lower-skip-runtime-until-next-module rest)]
              (if (compiler_lower.lower-type-decl?
                (owned_view.compiler-owned-shared-view decl))
                (compiler_ast_types.ast-decl-list-prepend-builder
                  decl
                  kept-rest)
                kept-rest))]))]))

(define (lower-compiler-program-with-decl-paths
  [entry-path : String]
  [program : compiler_ast_types.AstProgram]
  [paths : compiler_ast_types.AstDeclPathList]) : compiler_lower.ResultCompilerLower
  (compiler_lower.lower-compiler-program-with-decl-paths-mode
    entry-path
    program
    paths
    (compiler_lower.CompilerLowerMode.Scalar)))

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
(define (pair-y [pair : (& pair Pair)]) : i64 pair.y)
(define (main) : i64
  (let
    [items : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    (pair-y (& (array-ref items 1)))))")

(define (compiler-lower-fixed-array-return-source) : String
  "(define (main) : (Array i64 3)
  (array 1 2 3))")

(define (compiler-lower-box-source) : String
  "(define (main) : i64 (deref (box 7)))")

(define (compiler-lower-box-get-source) : String
  "(define (main [b : (Box i64)]) : i64 (deref b))")

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
  (set! inner.value 8))
(define (main) : i64
  (let [w : World (World (Inner 7))]
    (begin
      (set-inner (&mut w.inner))
      w.inner.value)))")

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
  (& p.left))
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
  inner.line)
(define (main [outer : Outer]) : i64
  (take-inner (& outer.inner)))")

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
  (if item.is-owned
    (__tl_string_length item.owned)
    (__tl_string_length item.borrowed)))
(define (main [text : String] [owned : String]) : i64
  (let
    [borrowed : (RefBox text) (ref-box-borrowed (& text) (clone owned))]
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
    (__tl_string_length item.old-text)
    (+
      (__tl_string_length item.replacement-text)
      (if item.is-owned
        (__tl_string_length item.owned)
        (__tl_string_length item.borrowed)))))
(define (main [text : String] [old : String] [replacement : String] [owned : String]) : i64
  (let
    [borrowed : (ReplaceResult text old replacement)
      (replace-borrowed (& text) (& old) (& replacement) (clone owned))]
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
    [a : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref a 0) n)
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
           p.x
           (+
             (array-ref a 1)
             (match s
               [(Rect w h) (* w h)]
               [(None) 0]))))))))")

(define (compiler-lower-capturing-lambda-structural-return-source) : String
  "(define (main) : i64
  (let
    [base : i64 10]
     (tuple-ref
      ((lambda ([value : i64]) : (Tuple i64 i64)
         (tuple base value))
       32)
       1)))")

(define (compiler-lower-capturing-lambda-structural-sret-source) : String
  "(define (main) : i64
  (let
    [base : i64 10]
    (tuple-ref
      ((lambda ([value : i64]) : (Tuple i64 i64 i64)
         (tuple base value 0))
       32)
      1)))")

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

(define (compiler-lower-comptime-error-ordinary-source) : String
  "(import stdlib.comptime)
(define (main) : i64
  (begin
    (comptime.error \"ordinary runtime forbidden\")
    0))")

(define (compiler-lower-comptime-error-tail-source) : String
  "(import stdlib.comptime)
(define (main) : i64
  (comptime.error \"tail runtime forbidden\"))")

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

(define (compiler-lower-defdispatch-structural-source) : String
  "(define (dot-scalar [x : (Tuple i64 i64)]) : (Tuple i64 i64) x)
(define (dot-avx2 [x : (Tuple i64 i64)]) : (Tuple i64 i64) x)
(define (dot-avx512 [x : (Tuple i64 i64)]) : (Tuple i64 i64) x)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main) : i64 (tuple-ref (dot (tuple 1 2)) 1))")

(define (compiler-lower-defdispatch-shared-helper-source) : String
  "(define (dispatch-helper [x : i64]) : i64 (+ x 1))
(define (dot-scalar [x : i64]) : i64 (dispatch-helper x))
(define (dot-avx2 [x : i64]) : i64 (+ (dispatch-helper x) 2))
(define (dot-avx512 [x : i64]) : i64 (+ (dispatch-helper x) 5))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-lower-error-ok? [src : String] [want : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Err diag)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-message (__tl-box-place diag))
        want)]
    [(compiler_lower.ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-comptime-error-runtime-diagnostics-ok?) : bool
  (and
    (compiler-lower-error-ok?
      (compiler-lower-comptime-error-ordinary-source)
      "lower: comptime-error is compile-time only")
    (compiler-lower-error-ok?
      (compiler-lower-comptime-error-tail-source)
      "lower: comptime-error is compile-time only")))

(test
  compiler-lower-comptime-error-runtime-diagnostics
  (test.assert-true
    (compiler-lower-comptime-error-runtime-diagnostics-ok?)
    "ordinary and tail-position comptime-error calls are rejected"))

(define (compiler-lower-resetting-entry-live-session-guard-ok?) : bool
  (let
    [previous-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-active-session-state-shared-view)]
    [live-state : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-session-state-new)]
    [generation-before : i64 (ci.intern-generation)]
    [_select-live : unit
      (compiler_load.compiler-load-session-state-use! live-state)]
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source "(define (main) : i64 0)")]
    [generation-after : i64 (ci.intern-generation)]
    [_restore : unit
      (compiler_load.compiler-load-session-state-use!
        (compiler_load.compiler-load-session-state-shared-view
          (& previous-state)))]
    (and
      (compiler_load.compiler-load-session-state-standalone-reset-safe?
        previous-state)
      (= generation-before generation-after)
      (match result
        [(compiler_lower.ResultCompilerLower.Err diag)
          (string.eq
            (compiler_diagnostic.compiler-diagnostic-message
              (__tl-box-place diag))
            "lower-compiler-source-with-path-mode: standalone resetting compiler entry cannot run inside an active compiler load session")]
        [(compiler_lower.ResultCompilerLower.Ok _ _) false]))))

(test
  compiler-lower-resetting-entry-live-session-guard
  (test.assert-true
    (compiler-lower-resetting-entry-live-session-guard-ok?)
    "lower standalone entry rejects a live compiler session before reset"))

(define (compiler-lower-pool-copy-arena-restoration-ok?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [owner : arena.Arena (arena.make)]
    [ok : bool
      (let
        [pools : compiler_ast_types.AstNodePoolContext
          (compiler_ast_types.ast-node-pool-context-new-with-capacities-in-arena
            8
            8
            (arena.raw-handle owner))]
        [copied : String
          (compiler_lower.lower-copy-string-into-pools "pool-owned" pools)]
        (and (arena.eq? (arena.current) home) (string.eq copied "pool-owned")))]
    (begin
      (arena.destroy-safe! owner)
      ok)))

(test
  compiler-lower-pool-copy-arena-restoration
  (test.assert-true
    (compiler-lower-pool-copy-arena-restoration-ok?)
    "lower pool-copy helper restores caller arena"))

(define (compiler-lower-maybe-span-start-ok?
  [found-span : compiler_ir_types.CompilerMaybeSourceSpan]
  [line : i64]
  [col : i64]) : bool
  (match found-span
    [(compiler_ir_types.CompilerMaybeSourceSpan.Some found)
      (and
        (= (compiler_ast_types.ast-source-span-start-line found) line)
        (= (compiler_ast_types.ast-source-span-start-col found) col))]
    [(compiler_ir_types.CompilerMaybeSourceSpan.No) false]))

(define (compiler-lower-nested-expression-diagnostic-span-ok?) : bool
  (let
    [span : compiler_ast_types.AstSourceSpan
      (compiler_ast_types.ast-source-span 11 3 11 9)]
    [value-id : i64 (ci.intern-generated-name "value")]
    [inner : i64
      (compiler_ast_types.ast-node-push
        (compiler_ast_types.AstExpr.Var value-id))]
    [spanned-inner : i64 (compiler_ast_types.ast-expr-spanned inner span)]
    [wrapped : i64
      (compiler_ast_types.ast-expr-cast
        spanned-inner
        (compiler_ast_types.AstType.I64))]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_lower.lower-diagnostic-at-expr-with-pools
        pools
        (compiler_ast_types.ast-node-get wrapped)
        "lower: nested expression diagnostic")]
    [found-span : compiler_ir_types.CompilerMaybeSourceSpan
      (compiler_lower.lower-ast-expr-span
        pools
        (compiler_ast_types.ast-node-get
          (compiler_ast_types.ast-expr-return spanned-inner)))]
    [diag-ok : bool
      (and
        (string.eq
          (compiler_diagnostic.compiler-diagnostic-message diag)
          "lower: nested expression diagnostic")
        (= (compiler_diagnostic.compiler-diagnostic-line diag) 11)
        (= (compiler_diagnostic.compiler-diagnostic-col diag) 3))]
    [span-ok : bool (compiler-lower-maybe-span-start-ok? found-span 11 3)]
    (and diag-ok span-ok)))

(define (compiler-lower-compound-expression-diagnostic-span-ok?) : bool
  (let
    [span : compiler_ast_types.AstSourceSpan
      (compiler_ast_types.ast-source-span 17 5 17 12)]
    [compound-value-id : i64 (ci.intern-generated-name "compound-value")]
    [a-id : i64 (ci.intern-generated-name "a")]
    [b-id : i64 (ci.intern-generated-name "b")]
    [i-id : i64 (ci.intern-generated-name "i")]
    [prefix-id : i64 (ci.intern-generated-name "prefix")]
    [plain : i64
      (compiler_ast_types.ast-node-push
        (compiler_ast_types.AstExpr.Literal compiler_ast_types.AstLiteral.Unit))]
    [inner : i64
      (compiler_ast_types.ast-node-push
        (compiler_ast_types.AstExpr.Var compound-value-id))]
    [spanned-inner : i64 (compiler_ast_types.ast-expr-spanned inner span)]
    [items : compiler_ast_types.AstExprList
      (compiler_ast_types.ast-expr-cons
        plain
        (compiler_ast_types.ast-expr-cons
          spanned-inner
          (compiler_ast_types.ast-expr-list-new)))]
    [bindings : compiler_ast_types.AstLetBindingList
      (compiler_ast_types.ast-let-binding-cons
        (compiler_ast_types.ast-let-binding-id
          a-id
          (compiler_ast_types.AstMaybeType.No)
          plain)
        (compiler_ast_types.ast-let-binding-cons
          (compiler_ast_types.ast-let-binding-id
            b-id
            (compiler_ast_types.AstMaybeType.No)
            spanned-inner)
          (compiler_ast_types.ast-let-binding-list-new)))]
    [arms : compiler_ast_types.AstMatchArmList
      (compiler_ast_types.ast-match-arm-cons
        (compiler_ast_types.ast-match-arm
          (compiler_ast_types.AstPattern.Wildcard)
          plain)
        (compiler_ast_types.ast-match-arm-cons
          (compiler_ast_types.ast-match-arm
            (compiler_ast_types.AstPattern.Wildcard)
            spanned-inner)
          (compiler_ast_types.ast-match-arm-list-new)))]
    [resources : compiler_ast_types.AstResourceBindingList
      (compiler_ast_types.ast-resource-binding-cons
        (compiler_ast_types.ast-resource-binding-id a-id plain plain)
        (compiler_ast_types.ast-resource-binding-cons
          (compiler_ast_types.ast-resource-binding-id b-id spanned-inner plain)
          (compiler_ast_types.ast-resource-binding-list-new)))]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [ok : bool true]
    (begin
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.Binary
              (compiler_ast_types.AstBinOp.Add)
              plain
              spanned-inner))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.Call
              plain
              (owned_view.compiler-owned-shared-view items)))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.If plain plain spanned-inner))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.Let
              (box (compiler_ast_types.AstLet.Let bindings plain))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.Match
              (box (compiler_ast_types.AstMatch.Match plain arms))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.WithResource
              (box
                (compiler_ast_types.AstWithResource.WithResource
                  resources
                  (owned_view.compiler-owned-shared-view items)))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.SpmdScan
              (box
                (compiler_ast_types.AstSpmdScan.Scan
                  (compiler_ast_types.AstReduceOp.Sum)
                  i-id
                  (compiler_ast_types.AstType.I64)
                  plain
                  plain
                  prefix-id
                  (compiler_ast_types.AstType.I64)
                  plain
                  plain
                  spanned-inner))))
          17
          5)
        (set! ok false))
      (unless
        (compiler-lower-maybe-span-start-ok?
          (compiler_lower.lower-ast-expr-span
            pools
            (compiler_ast_types.AstExpr.Syscall items))
          17
          5)
        (set! ok false))
      ok)))

(define (compiler-lower-mode-error-ok?
  [src : String]
  [mode : compiler_lower.CompilerLowerMode]
  [want : String]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode src mode)
    [(compiler_lower.ResultCompilerLower.Err diag)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-message (__tl-box-place diag))
        want)]
    [(compiler_lower.ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-mode-diagnostic-ok?
  [src : String]
  [mode : compiler_lower.CompilerLowerMode]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode src mode)
    [(compiler_lower.ResultCompilerLower.Err diag-box)
      (let
        [diag : compiler_diagnostic.CompilerDiagnostic
          (compiler_diagnostic.compiler-diagnostic-box-shared-view diag-box)]
        (and
          (string.eq
            (compiler_diagnostic.compiler-diagnostic-message diag)
            want)
          (= (compiler_diagnostic.compiler-diagnostic-line diag) line)
          (= (compiler_diagnostic.compiler-diagnostic-col diag) col)))]
    [(compiler_lower.ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-inline-error-ok? [src : String] [want : String]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Err diag)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-message (__tl-box-place diag))
        want)]
    [(compiler_lower.ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-windows-error-ok? [src : String] [want : String]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Err diag)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-message (__tl-box-place diag))
        want)]
    [(compiler_lower.ResultCompilerLower.Ok _ _) false]))

(define (compiler-lower-entry-moduled-main-ok?) : bool
  (let
    [lower-state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
    [prev-active : bool
      (compiler_lower.lower-entry-main-module-active-current lower-state)]
    [prev-module : String
      (compiler_lower.lower-entry-main-module-current lower-state)]
    [prev-module-id : i64
      (compiler_lower.lower-entry-main-module-id-current lower-state)]
    [active-ok : bool false]
    (begin
      (compiler_lower.lower-entry-main-selection-install!
        lower-state
        (compiler_lower.LowerMaybeEntryMainModule.Some "app.main" 123))
      (set!
        active-ok
        (and
          (compiler_lower.lower-decl-entry-main?
            lower-state
            "src/app.tl"
            "src/app.tl"
            "app.main"
            "main")
          (compiler_lower.lower-decl-entry-main?
            lower-state
            "src\\app.tl"
            "src/app.tl"
            "app.main"
            "main")
          (not
            (compiler_lower.lower-decl-entry-main?
              lower-state
              "src/app.tl"
              "src/lib.tl"
              "app.main"
              "main"))
          (not
            (compiler_lower.lower-decl-entry-main?
              lower-state
              "src/app.tl"
              "src/app.tl"
              "app.main"
              "helper"))))
      (compiler_lower.lower-entry-main-selection-restore!
        lower-state
        prev-active
        prev-module
        prev-module-id)
      (and
        active-ok
        (not
          (compiler_lower.lower-decl-entry-main?
            lower-state
            "src/app.tl"
            "src/app.tl"
            "app.main"
            "main"))))))

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

;; Private dynamic-array length lowering smoke: `array-length` and `length`
;; lower to a fat-value length load rather than a runtime call.
(define (compiler-lower-array-length-source) : String
  "(define (dyn-len [a : (__tl_dyn-array i64)]) : i64 (array-length a))
(define (dyn-len-alias [a : (__tl_dyn-array i64)]) : i64 (length a))
(define (main) : i64 0)")

;; Fixed-array length evaluates each owned/reference receiver but yields the
;; compile-time element count directly, without a fat-value load or call.
(define (compiler-lower-fixed-array-length-source) : String
  "(define (owned-len [a : (Array i64 3)]) : i64 (length a))
(define (shared-len [a : (& a (Array i64 3))]) : i64 (array-length a))
(define (mut-len [a : (&mut a (Array i64 3))]) : i64 (length a))
(define (main) : i64
  (let
    [a : (Array i64 3) (array 1 2 3)]
    (+ (shared-len (& a)) (+ (mut-len (&mut a)) (owned-len a)))))")

(define (compiler-lower-fixed-array-length-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-fixed-array-length-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-load-count
                (owned_view.compiler-owned-shared-view functions)
                "owned-len")
              0)
            (=
              (lower-test-function-load-count
                (owned_view.compiler-owned-shared-view functions)
                "shared-len")
              0)
            (=
              (lower-test-function-load-count
                (owned_view.compiler-owned-shared-view functions)
                "mut-len")
              0)
            (=
              (lower-test-function-return-count
                (owned_view.compiler-owned-shared-view functions)
                "owned-len")
              1)
            (=
              (lower-test-function-return-count
                (owned_view.compiler-owned-shared-view functions)
                "shared-len")
              1)
            (= (lower-test-function-return-count functions "mut-len") 1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; `array-ref`/`array-set!` lower to a bounds-checked typed element load/store.
;; Taking the array as a parameter avoids needing `make-array` here.
(define (compiler-lower-array-access-source) : String
  "(define (get [a : (__tl_dyn-array i64)] [i : i64]) : i64 (array-ref a i))
(define (put [a : (__tl_dyn-array i64)] [i : i64] [v : i64]) : unit (set! (array-ref a i) v))
(define (main) : i64 0)")

;; Private `__tl_array-take!` moves an element only when its companion liveness
;; slot is still true. The primitive returns a false availability flag for
;; exhausted, invalid, or already-taken positions instead of forming an
;; out-of-bounds address; its payload is then intentionally unspecified.
(define (compiler-lower-array-take-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-item [items : (__tl_dyn-array i64)] [live : (__tl_dyn-array bool)] [i : i64]) : (Tuple bool i64)
  (__tl_array-take! items live i))
(define (take-handle [items : (__tl_dyn-array FileHandle)] [live : (__tl_dyn-array bool)] [i : i64]) : (Tuple bool FileHandle)
  (__tl_array-take! items live i))
(define (main [items : (__tl_dyn-array i64)] [live : (__tl_dyn-array bool)] [handles : (__tl_dyn-array FileHandle)] [handle-live : (__tl_dyn-array bool)] [i : i64]) : i64
  (begin
    (take-item items live i)
    (if (tuple-ref (take-handle handles handle-live i) 0) 1 0)))")

;; Fixed-array access lowers against inline array storage rather than the
;; dynamic-array fat `{ptr, len}` layout.
(define (compiler-lower-fixed-array-access-source) : String
  "(define (get [a : (Array i64 3)] [i : i64]) : i64 (array-ref a i))
(define (put [a : (Array i64 3)] [i : i64] [v : i64]) : unit (set! (array-ref a i) v))
(define (main) : i64 0)")

;; A direct fixed-array borrow must be packed into the two-word Slice ABI at a
;; typed call boundary.  The forwarding call receives an already-Slice value,
;; so it must remain a direct pass-through with no second Pack.
(define (compiler-lower-slice-whole-array-pack-source) : String
  "(define (slice-id [s : (& s (Slice i64))]) : (& s (Slice i64))
  s)
(define (slice-forward [s : (& s (Slice i64))]) : i64
  (length (slice-id s)))
(define (slice-from-array-ref [a : (& a (Array i64 3))]) : i64
  (length (slice-id a)))
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    (+
      (slice-forward (slice-id (& items)))
      (+ (slice-from-array-ref (& items)) 39))))")

(define (compiler-lower-slice-whole-array-pack-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-slice-whole-array-pack-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (let
        [pools : compiler_ast_types.AstNodePoolContext
          (compiler_ast_types.ast-node-pool-context-capture-active)]
        (match program
          [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
            (and
              (=
                (lower-test-function-pack-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
              (=
                (lower-test-function-pack-shape-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  (owned_view.compiler-owned-shared-view pools))
                1)
              (=
                (lower-test-function-pack-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "slice-from-array-ref")
                1)
              (=
                (lower-test-function-pack-shape-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "slice-from-array-ref"
                  pools)
                1)
              (=
                (lower-test-function-pack-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "slice-forward")
                0))]))]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-slice-split-at-source) : String
  "(define (split [view : (&mut source (Slice i64))] [mid : i64]) : (Tuple (&mut source (Slice i64)) (&mut source (Slice i64)))
  (slice-split-at-mut view mid))
(define (main) : i64 0)")

(define (compiler-lower-slice-split-at-mode-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-slice-split-at-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "split"
                "tl_oob_abort")
              1)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "split"
                compiler_ir_types.CompilerIrBinOp.Le)
              1)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "split"
                compiler_ir_types.CompilerIrBinOp.Sub)
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "split"
                "tl_alloc")
              0)
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "split")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-slice-split-at-shape-ok?) : bool
  (and
    (compiler-lower-slice-split-at-mode-shape-ok?
      (compiler_lower.CompilerLowerMode.LinuxScalar))
    (compiler-lower-slice-split-at-mode-shape-ok?
      (compiler_lower.CompilerLowerMode.WindowsScalar))))

(define (compiler-lower-mut-ref-array-access-source) : String
  "(define (len [a : (& a (__tl_dyn-array i64))]) : i64 (array-length a))
(define (get [a : (& a (__tl_dyn-array i64))] [i : i64]) : i64 (array-ref a i))
(define (put [a : (&mut a (__tl_dyn-array i64))] [i : i64] [v : i64]) : unit
  (set! (array-ref a i) v))
(define (grow [a : (&mut a (__tl_dyn-array i64))] [v : i64]) : unit
  (__tl_array-push! a v))
(define (main) : i64 0)")

(define (compiler-lower-mut-ref-by-value-writeback-source) : String
  "(defstruct Pair (x i64) (y i64))
(define (set-pair-x! [p : (&mut p Pair)] [value : i64]) : unit
  (set! p.x value))
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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-mut-ref-by-value-writeback-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>=
              (lower-test-function-alloc-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2)
            (>=
              (lower-test-function-addr-of-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2)
            (>=
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-mut-ref-array-field-access-source) : String
  "(defstruct ArrayBag (items (__tl_dyn-array i64)))
(defstruct ArrayBagHandle
  (:lifetimes bag)
  (items (&mut bag (__tl_dyn-array i64)))
  (index i64))
(define (array-bag-handle [bag : (&mut bag ArrayBag)] [index : i64]) : (ArrayBagHandle bag)
  (ArrayBagHandle (&mut bag.items) index))
(define (len [handle : (ArrayBagHandle bag)]) : i64
  (array-length handle.items))
(define (get [handle : (ArrayBagHandle bag)]) : i64
  (array-ref handle.items handle.index))
(define (put [handle : (ArrayBagHandle bag)] [v : i64]) : unit
  (set! (array-ref handle.items handle.index) v))
(define (main) : i64 0)")

;; `array-push!` lowers to checked arena reallocation, a runtime-length copy,
;; a tail store, and in-place fat `{ptr, len}` updates.
(define (compiler-lower-array-push-source) : String
  "(define (grow [a : (__tl_dyn-array i64)] [v : i64]) : unit (__tl_array-push! a v))
(define (main) : i64 0)")

;; Fixed arrays have no runtime capacity field and remain unsupported for push.
(define (compiler-lower-fixed-array-push-source) : String
  "(define (grow [a : (Array i64 3)] [v : i64]) : unit (__tl_array-push! a v))
(define (main) : i64 0)")

;; `make-array` lowers to checked byte-count math, a `tl_alloc` element buffer,
;; initialized elements, and a dynamic-array fat value. The fixture also
;; immediately uses `array-set!`, `array-ref`, and `array-length` so the
;; generated IR exercises the full dynamic-array primitive set.
(define (compiler-lower-make-array-source) : String
  "(define (main [n : u32]) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (set! (array-ref a 0) 40)
      (set! (array-ref a 1) 2)
      (+ (array-length a) (+ (array-ref a 0) (array-ref a 1))))))")

(define (compiler-lower-make-array-init-source) : String
  "(define (main [n : i64]) : i64
  (let
    [items : (__tl_dyn-array String) (__tl_make-array String n)]
    (array-length items)))")

(define (compiler-lower-dyn-array-literal-source) : String
  "(define dyn-array-literal-trace : i64 0)
(define (side [value : i64]) : i64
  (begin
    (set! dyn-array-literal-trace (+ (* dyn-array-literal-trace 10) value))
    value))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array (side 1) (side 2) (side 3))]
    (+ (array-length items)
       (+ (array-ref items 0)
          (+ (array-ref items 1)
             (+ (array-ref items 2) dyn-array-literal-trace))))))")

(define (compiler-lower-make-array-register-resident-fill8-source) : String
  "(defstruct OneWord (value i64))
(define (main [n : i64]) : i64
  (let
    [items : (__tl_dyn-array OneWord) (__tl_make-array OneWord n)]
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

(define (compiler-lower-public-literal-float-to-bits-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "stdlib/math.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "stdlib/math.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        "stdlib/math.tl"
        (compiler_ast_types.ast-decl-root-path-cons
          "stdlib/math.tl"
          (compiler_ast_types.ast-decl-root-path-cons
            "stdlib/math.tl"
            (compiler_ast_types.ast-decl-root-path-cons
              "stdlib/math.tl"
              (compiler_ast_types.ast-decl-path-list-new))))))))

(define (compiler-lower-stdlib-string-wrapper-prune-source) : String
  "(module stdlib.string)
(define (string.string-length [text : (& text str)]) : i64 0)
(module stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(define (io-len [text : String]) : i64 (string.string-length text))
(define (main) : i64 (io-len \"abc\"))")

(define (compiler-lower-stdlib-string-wrapper-prune-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "stdlib/string.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "stdlib/string.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        "stdlib/string.tl"
        (compiler_ast_types.ast-decl-root-path-cons
          "stdlib/tl"
          (compiler_ast_types.ast-decl-root-path-cons
            "stdlib/tl"
            (compiler_ast_types.ast-decl-root-path-cons
              "stdlib/tl"
              (compiler_ast_types.ast-decl-root-path-cons
                "stdlib/tl"
                (compiler_ast_types.ast-decl-path-list-new)))))))))

(define (compiler-lower-stdlib-string-wrapper-prune-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-stdlib-string-wrapper-prune-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "stdlib/tl"
        program
        (compiler-lower-stdlib-string-wrapper-prune-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl::stdlib.io/io-len")
                (not
                  (lower-test-function-defined?
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "stdlib/string.tl::stdlib.string/string.string-length"))
                (not
                  (lower-test-function-defined?
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "string.tl::stdlib.string/string.string-length"))
                (not
                  (lower-test-function-defined?
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "stdlib/string.tl::stdlib.string/string-length"))
                (not
                  (lower-test-function-defined?
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "string.tl::stdlib.string/string-length")))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-string-runtime-source) : String
  "(define (io.emit-string [text : (& text str)]) : unit
  unit)
(define (io.emit-str [text : (& text str)]) : unit
  (io.emit-string text))
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
      (io.emit-string (& joined))
      (io.emit-str (& extended))
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

(define (compiler-lower-emit-string-stdlib-source) : String
  "(define (io.emit-string [text : (& text str)]) : unit
  unit)
(define (io.emit-str [text : (& text str)]) : unit
  (io.emit-string text))
(define (main [text : String]) : i64
  (begin
    (io.emit-string (& text))
    (io.emit-str (& text))
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

(define (compiler-lower-stdlib-hash-string-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "stdlib/hash.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "app.tl"
      (compiler_ast_types.ast-decl-path-list-new))))

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
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    (unsafe (string-from-bytes (ptr-cast (__tl_array-data buf) : (Ptr u8)) count))))
(define (read-stdin-line) : String
  (let
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (__tl_array-data buf) : (Ptr u8)) 0))))
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
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    (unsafe (string-from-bytes (ptr-cast (__tl_array-data buf) : (Ptr u8)) count))))
(define (read-stdin-line) : String
  (let
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (__tl_array-data buf) : (Ptr u8)) 0))))
(define (stdin-eof?) : bool stdin-eof-state)
(define (flush-stdout) : unit unit)
(define (main [count : i64]) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (__tl_string_length (read-stdin-line))
        (__tl_string_length (io.read-stdin-bytes count)))))")

(define (compiler-lower-env-builtin-source) : String
  "(define (var-exists? [name : (& name str)]) : bool true)
(define (var-value [name : (& name str)]) : String \"value\")
(define (path-separator) : String \":\")
(define (main [name : String]) : i64
  (let
    [separator : String (path-separator)]
    [value : String (var-value (& name))]
    (if (var-exists? (& name))
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
    [tiny-field : (MutPtr i32) (unsafe (ptr-addr-of tiny.b))]
    [pair-field : (MutPtr i64) (unsafe (ptr-addr-of pair.y))]
    [nested-field : (MutPtr i32)
      (unsafe (ptr-addr-of wrap.tiny.b))]
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
  p.y)
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
    [items : (__tl_dyn-array i64) (init)]
    [tupled : (Tuple i64 bool) (init)]
    [fixed : (Array i64 2) (array (init) 2)]
    [point : Point (init)]
    [constructed : Point (Point (init) (init))]
    [maybe : Maybe (init)]
    [boxed : (Box i64) (init)]
    [called : i64 (take (init))]
    (begin
      (set! (array-ref fixed 0) (init))
      (+ n (+ called (+ point.x (+ constructed.x (+ (tuple-ref tupled 0) (+ (array-ref fixed 0) (deref boxed))))))))))")

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
  (items (__tl_dyn-array String))
  (pair (Tuple String String)))
(defenum StringTree
  (Leaf String)
  (Branch (Box StringTree) (Box StringTree)))
(define (clone-tuple [items : (__tl_dyn-array String)]) : i64
  (let [pair : (Tuple String (__tl_dyn-array String)) (clone (tuple \"tuple\" items))]
    (__tl_string_length (tuple-ref pair 0))))
(define (clone-fixed) : i64
  (let [fixed : (Array String 2) (clone (array \"left\" \"right\"))]
    (__tl_string_length (array-ref fixed 0))))
(define (clone-dyn [items : (__tl_dyn-array String)]) : i64
  (let [copied : (__tl_dyn-array String) (clone items)]
    (array-length copied)))
(define (clone-holder [items : (__tl_dyn-array String)]) : Holder
  (clone (Holder \"holder\" (array \"x\" \"y\") items (tuple \"p\" \"q\"))))
(define (clone-tree [tree : StringTree]) : StringTree
  (clone tree))
(define (main [n : i64] [tree : StringTree]) : i64
  (let
    [items1 : (__tl_dyn-array String) (__tl_make-array String n)]
    [items2 : (__tl_dyn-array String) (__tl_make-array String n)]
    [items3 : (__tl_dyn-array String) (__tl_make-array String n)]
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
(define (copy-i64-items [items : (__tl_dyn-array i64)]) : (__tl_dyn-array i64)
  (clone items))
(define (copy-word-items [items : (__tl_dyn-array OneWord)]) : (__tl_dyn-array OneWord)
  (clone items))
(define (copy-string-items [items : (__tl_dyn-array String)]) : (__tl_dyn-array String)
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
    (__tl_string_length item.used.name)))")

;; Eighteen independent aggregate roots force stdlib.clone's helper handoff
;; across the fixed 16-root chunk boundary.  Source-order field discovery
;; prepends roots, so logical positions 0, 15, 16, and 17 are CloneChunk17,
;; CloneChunk2, CloneChunk1, and CloneChunk0 respectively.
(define (compiler-lower-clone-chunk-boundary-source) : String
  "(defstruct CloneChunk0 (value String))
(defstruct CloneChunk1 (value String))
(defstruct CloneChunk2 (value String))
(defstruct CloneChunk3 (value String))
(defstruct CloneChunk4 (value String))
(defstruct CloneChunk5 (value String))
(defstruct CloneChunk6 (value String))
(defstruct CloneChunk7 (value String))
(defstruct CloneChunk8 (value String))
(defstruct CloneChunk9 (value String))
(defstruct CloneChunk10 (value String))
(defstruct CloneChunk11 (value String))
(defstruct CloneChunk12 (value String))
(defstruct CloneChunk13 (value String))
(defstruct CloneChunk14 (value String))
(defstruct CloneChunk15 (value String))
(defstruct CloneChunk16 (value String))
(defstruct CloneChunk17 (value String))
(define (main [s : String]) : i64
  (begin
    (clone
      (tuple
        (CloneChunk0 (clone s))
        (CloneChunk1 (clone s))
        (CloneChunk2 (clone s))
        (CloneChunk3 (clone s))
        (CloneChunk4 (clone s))
        (CloneChunk5 (clone s))
        (CloneChunk6 (clone s))
        (CloneChunk7 (clone s))
        (CloneChunk8 (clone s))
        (CloneChunk9 (clone s))
        (CloneChunk10 (clone s))
        (CloneChunk11 (clone s))
        (CloneChunk12 (clone s))
        (CloneChunk13 (clone s))
        (CloneChunk14 (clone s))
        (CloneChunk15 (clone s))
        (CloneChunk16 (clone s))
        (CloneChunk17 s)))
    0))")

(define (compiler-lower-clone-chunk-boundary-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-chunk-boundary-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              ".::clone$CloneChunk17")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              ".::clone$CloneChunk2")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              ".::clone$CloneChunk1")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              ".::clone$CloneChunk0"))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; Nominal clone helpers are declaration macros now, so clone-producing lowering
;; fixtures must load the same implicit prelude as the compiler driver.
(define (compiler-lower-clone-source-with-prelude [src : String]) : compiler_lower.ResultCompilerLower
  (begin
    (ci.intern-reset!)
    (compiler_lower.lower-reset-intern-owned-state!)
    (cbi.compiler-builtin-reset!)
    (match (compiler_typecheck_api.typecheck-compiler-source-load src)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (lower-compiler-program-with-decl-paths
          ""
          (compiler_ast_types.ast-program decls)
          paths)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (compiler_lower.ResultCompilerLower.Err diag)])))

;; `main` must lower with both element stores (bool + i64 each written into the
;; aggregate) and a load for the `tuple-ref`.
(define (compiler-lower-tuple-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source (compiler-lower-tuple-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2)
            (>=
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-clone-shape-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-tuple"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-tuple"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-fixed"
                  "tl_substring")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-dyn"
                  "tl_alloc")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-branch-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-dyn")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-holder"
                  ".::clone$Holder")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone-tree"
                  ".::clone$StringTree")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone$Holder"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone$Holder"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::clone$StringTree"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-clone-dynarray-bulk-copy-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-dynarray-bulk-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-i64-items"
                  "tl_memcpy")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-branch-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-i64-items")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-word-items"
                  "tl_memcpy")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-branch-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-word-items")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-string-items"
                  "tl_memcpy")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-string-items"
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-branch-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".::copy-string-items")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-clone-reachable-helpers-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-clone-reachable-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              ".::clone$NestedClone")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              ".::clone$UsedClone")
            (not
              (lower-test-function-defined?
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::clone$UnusedClone"))
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::clone$NestedClone"
                ".::clone$UsedClone")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-struct-source) : String
  "(defstruct Packet (tag i64) (small u8) (count i64))
(define (main) : i64
  (let
    [p : Packet (Packet 7 (cast 2 : u8) 40)]
    (+
      p.tag
      (+
        (cast p.small : i64)
        p.count))))")

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
        (+ (match (deref left) [(Leaf value) value] [_ 0])
           (match (deref right) [(Leaf value) value] [_ 0]))])))")

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
  (let [pair : Pair (id-pair (Pair 20 22))] pair.b))")

(define (compiler-lower-inline-mixed16-copy-source) : String
  "(defstruct Mixed16 (tag u32) (value f32) (tail i64))
(define (id-mixed [p : Mixed16]) : Mixed16 p)
(define (main) : i64
  (let
    [mixed : Mixed16 (id-mixed (Mixed16 (cast 1 : u32) 2.0 40))]
    mixed.tail))")

(define (compiler-lower-inline-sret-return-copy-source) : String
  "(defstruct Return216
  (f00 i64) (f01 i64) (f02 i64) (f03 i64) (f04 i64) (f05 i64)
  (f06 i64) (f07 i64) (f08 i64) (f09 i64) (f10 i64) (f11 i64)
  (f12 i64) (f13 i64) (f14 i64) (f15 i64) (f16 i64) (f17 i64)
  (f18 i64) (f19 i64) (f20 i64) (f21 i64) (f22 i64) (f23 i64)
  (f24 i64) (f25 i64) (f26 i64))
(define (return216-id [value : Return216]) : Return216 value)
(define (main) : i64
  (let
    [value : Return216
      (return216-id
        (Return216
          0 1 2 3 4 5 6 7 8 9 10 11 12 13
          14 15 16 17 18 19 20 21 22 23 24 25 42))]
    value.f26))")

(define (compiler-lower-inline-sret-struct-constructor-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(define (make-wide [x : i64]) : Wide
  (Wide x (+ x 1) (+ x 2)))
(define (main) : i64
  (let [wide : Wide (make-wide 40)] wide.c))")

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
  (let [wide : Wide (from-choice (Make 40))] wide.c))")

(define (compiler-lower-inline-sret-enum-match-generic-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(defenum Choice (Make i64) (Wrap Wide))
(define (from-choice [choice : Choice]) : Wide
  (match choice
    [(Make n) (Wide n (+ n 1) (+ n 2))]
    [(Wrap w) w]))
(define (main) : i64
  (let [wide : Wide (from-choice (Make 40))] wide.c))")

;; Internal structural ABI smoke: tuple register groups and fixed-array memory
;; aggregates must cross ordinary (non-extern) calls using the classifier's
;; physical transport while the source expressions remain pointer-shaped.
(define (compiler-lower-internal-structural-call-source) : String
  "(define (tuple-roundtrip [value : (Tuple i64 f64)]) : (Tuple i64 f64)
  value)
(define (array-roundtrip [items : (Array i64 3)]) : (Array i64 3)
  items)
(define (main) : i64
  (let
    [pair : (Tuple i64 f64) (tuple 40 2.5)]
    [items : (Array i64 3) (array 1 2 3)]
    (+
      (tuple-ref (tuple-roundtrip pair) 0)
      (array-ref (array-roundtrip items) 2))))")

(define (compiler-lower-internal-windows-byref-sret-source) : String
  "(define (array-roundtrip [items : (Array i64 3)]) : (Array i64 3)
  items)
(define (scalar-roundtrip [items : (Array i64 1)]) : (Array i64 1)
  items)
(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    [scalar : (Array i64 1) (array 7)]
    (+
      (array-ref (array-roundtrip items) 2)
      (array-ref (scalar-roundtrip scalar) 0))))")

(define (compiler-lower-internal-windows-u8-three-source) : String
  "(define (roundtrip [value : (Array u8 3)]) : (Array u8 3)
  value)
(define (main) : i64
  (let [value : (Array u8 3) (array (cast 1 : u8) (cast 2 : u8) (cast 3 : u8))]
    (cast (array-ref (roundtrip value) 2) : i64)))")

(define (compiler-lower-internal-early-return-source) : String
  "(define (tuple-early [value : i64]) : (Tuple i64 i64)
  (begin
    (if (> value 0)
      (return (tuple value 2))
      unit)
    (tuple value 3)))
(define (array-early [value : i64]) : (Array i64 3)
  (begin
    (if (> value 0)
      (return (array value 2 3))
      unit)
    (array value 4 5)))
(define (main) : i64
  (+
    (tuple-ref (tuple-early 1) 1)
    (array-ref (array-early 1) 2)))")

(define (compiler-lower-internal-indirect-structural-source) : String
  "(define (tuple-roundtrip [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  value)
(define (main) : i64
  (let
    [f : (-> (Tuple i64 i64) (Tuple i64 i64)) tuple-roundtrip]
    (tuple-ref (f (tuple 1 2)) 1)))")

(define (compiler-lower-internal-tail-structural-source) : String
  "(define (loop [n : i64] [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  (if (= n 0)
    value
    (loop (- n 1) value)))
(define (main) : i64 (tuple-ref (loop 3 (tuple 1 2)) 1))")

(define (compiler-lower-internal-zero-array-param-source) : String
  "(define (bad [items : (Array u8 0)]) : i64
  42)")

(define (compiler-lower-internal-empty-tuple-return-source) : String
  "(define (bad) : (Tuple)
  (tuple))")

(define (compiler-lower-internal-zero-array-indirect-call-source) : String
  "(define (main [f : (-> (Array u8 0) i64)]) : i64
  (f (array)))")

(define (compiler-lower-internal-zero-array-direct-call-source) : String
  "(define (caller) : i64
  (bad (array)))
(define (bad [items : (Array u8 0)]) : i64
  42)
(define (main) : i64 (caller))")

(define (compiler-lower-internal-direct-tail-structural-param-source) : String
  "(define (finish [items : (Array i64 2)]) : i64
  (array-ref items 1))
(define (step [value : i64]) : i64
  (finish (array value 2)))
(define (main) : i64 (step 40))")

(define (compiler-lower-internal-indirect-tail-structural-param-source) : String
  "(define (finish [items : (Array i64 2)]) : i64
  (array-ref items 1))
(define (step [f : (-> (Array i64 2) i64)] [value : i64]) : i64
  (f (array value 2)))
(define (main) : i64 (step finish 40))")

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
            (set! sum (+ sum p.y))
            (set! i (+ i 1)))))
      sum)))")

(define (compiler-lower-inline-direct-store-source) : String
  "(defstruct Wide (a i64) (b i64) (c i64))
(defstruct Holder (wide Wide) (tail i64))
(define (direct-field [h : Holder]) : i64
  (begin
    (set! h.wide (Wide 1 2 3))
    0))
(define (direct-init [h : Holder]) : i64
  (begin
    (set! h.wide (init : Wide))
    0))
(define (direct-dyn-array [items : (__tl_dyn-array Wide)] [i : i64]) : unit
  (set! (array-ref items i) (Wide 4 5 6)))
(define (direct-fixed-array [items : (Array Wide 2)] [i : i64]) : unit
  (set! (array-ref items i) (Wide 7 8 9)))
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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-inline-struct-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-alloc-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                3)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-addr-of-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                3)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  16)
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-enum-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-inline-enum-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-alloc-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                3)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-addr-of-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                3)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  16)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-branch-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-boxed-recursive-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-inline-boxed-recursive-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "tl_alloc")
                2)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-alloc-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                6)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-addr-of-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                2)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                4)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-imported-enum-payload-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-inline-imported-enum-payload-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-functions-call-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "stdlib.maybe_string/maybe-string-single")
            0)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; `id-pair` is the identity on a 16-byte all-integer struct, which is
;; register-resident -- it is carried in a register pair end-to-end, so the
;; passthrough needs NO memory traffic at all: zero byte-copies and zero stores
;; (before register-residency this copied the 16 bytes through a slot). The
;; A mixed int/float 16-byte aggregate stays memory-backed, so its identity
;; return exercises the lower-copy-bytes 16-byte CopyBytes threshold.
(define (compiler-lower-inline-aggregate-copy-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-inline-aggregate-copy-source)
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Ok pair-program _)
      (match pair-program
        [(compiler_ir_types.CompilerIrProgram.Program _ pair-functions _)
          (let
            [pair-copy-count : i64
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view
                  pair-functions)
                "id-pair")]
            [pair-store-count : i64
              (lower-test-function-store-ptr-count pair-functions "id-pair")]
            (match (compiler_lower.lower-compiler-source-with-mode
              (compiler-lower-inline-mixed16-copy-source)
              (compiler_lower.CompilerLowerMode.InlineAggregates))
              [(compiler_lower.ResultCompilerLower.Ok mixed-program _)
                (match mixed-program
                  [(compiler_ir_types.CompilerIrProgram.Program
                      _
                      mixed-functions
                      _)
                    (and
                      (= pair-copy-count 0)
                      (= pair-store-count 0)
                      (=
                        (lower-test-function-copy-bytes-count
                          mixed-functions
                          "id-mixed")
                        1))])]
              [(compiler_lower.ResultCompilerLower.Err _) false]))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-sret-return-copy-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-inline-sret-return-copy-source)
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "return216-id")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "return216-id"
                "tl_memcpy")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-sret-constructor-copy-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-inline-sret-struct-constructor-source)
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Ok struct-program _)
      (match struct-program
        [(compiler_ir_types.CompilerIrProgram.Program _ struct-functions _)
          (let
            [struct-copy-count : i64
              (lower-test-function-copy-bytes-count
                struct-functions
                "make-wide")]
            (match (compiler_lower.lower-compiler-source-with-mode
              (compiler-lower-inline-sret-enum-constructor-source)
              (compiler_lower.CompilerLowerMode.InlineAggregates))
              [(compiler_lower.ResultCompilerLower.Ok enum-program _)
                (match enum-program
                  [(compiler_ir_types.CompilerIrProgram.Program
                      _
                      enum-functions
                      _)
                    (and
                      (= struct-copy-count 0)
                      (=
                        (lower-test-function-copy-bytes-count
                          enum-functions
                          "make-wide-choice")
                        0))])]
              [(compiler_lower.ResultCompilerLower.Err _) false]))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-sret-enum-match-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-inline-sret-enum-match-constructor-source)
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Ok constructor-program _)
      (match constructor-program
        [(compiler_ir_types.CompilerIrProgram.Program _ constructor-functions _)
          (let
            [constructor-copy-count : i64
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view
                  constructor-functions)
                "from-choice")]
            [constructor-phi-count : i64
              (lower-test-function-phi-count
                constructor-functions
                "from-choice")]
            (match (compiler_lower.lower-compiler-source-with-mode
              (compiler-lower-inline-sret-enum-match-generic-source)
              (compiler_lower.CompilerLowerMode.InlineAggregates))
              [(compiler_lower.ResultCompilerLower.Ok generic-program _)
                (match generic-program
                  [(compiler_ir_types.CompilerIrProgram.Program
                      _
                      generic-functions
                      _)
                    (and
                      (= constructor-copy-count 0)
                      (= constructor-phi-count 0)
                      (>
                        (lower-test-function-copy-bytes-count
                          (compiler_ir_types.compiler-ir-global-shared-view
                            generic-functions)
                          "from-choice")
                        0)
                      (=
                        (lower-test-function-phi-count
                          generic-functions
                          "from-choice")
                        0))])]
              [(compiler_lower.ResultCompilerLower.Err _) false]))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-hot-loop-struct-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-inline-hot-loop-struct-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-inline-direct-store-copy-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-inline-direct-store-source)
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "direct-field")
              0)
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "direct-init")
              0)
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "direct-dyn-array")
              0)
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "direct-fixed-array")
              0)
            (>
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "direct-fixed-literal")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
    (compiler-lower-inline-sret-return-copy-shape-ok?)
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
  p.y)
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
      (cast outer.inner.b : i64)
      (cast outer.tail : i64))))")

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
(defstruct Bag (slots (__tl_dyn-array Slot)))
(defenum SlotLookup (:lifetimes bag) (Missing) (Found (& bag i64)))
(define (take [v : (& bag i64)]) : i64 41)
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) SlotLookup.Missing)
(define (slot-found [value : (& bag i64)]) : (SlotLookup bag) (SlotLookup.Found value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (let [same : (& bag i64) v] (slot-found same))]
    [Empty (slot-missing bag)]))
(define (score [bag : (& bag Bag)]) : i64
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (take v)]
    [Empty 0]))
(define (main) : i64
  (let
    [slots : (__tl_dyn-array Slot) (__tl_make-array Slot 1)]
    (begin
      (set! (array-ref slots 0) (Occupied 9))
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
    (result_i64_string.Ok (try (use-fd use-ok h.fd)))))")

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
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok _ _) true]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  [spans : compiler_ir_types.CompilerSourceSpans]
  [name : String]
  [want-line : i64]) : bool
  (match (compiler_ir_types.compiler-source-spans-lookup
    spans
    (compiler_ir_types.compiler-ir-symbol-typed-id (ci.intern name)))
    [(compiler_ir_types.CompilerMaybeSourceSpan.Some span)
      (= (compiler_ast_types.ast-source-span-start-line span) want-line)]
    [(compiler_ir_types.CompilerMaybeSourceSpan.No) false]))

(define (compiler-lower-spans-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok _ spans)
      (and
        (=
          (compiler_ir_types.compiler-source-spans-count
            (owned_view.compiler-owned-shared-view spans))
          2)
        (compiler-lower-span-start-line-ok?
          (owned_view.compiler-owned-shared-view spans)
          "inc"
          3)
        (compiler-lower-span-start-line-ok? spans "main" 5))]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (let
        [summary : compiler_ir_types.CompilerIrSummary
          (compiler_ir_types.compiler-ir-program-summary program)]
        [ok : bool true]
        (begin
          ;; The tail-position `if` returns directly from both arms, so the
          ;; lowered program has no merge block, merge phi, or phi result var.
          (if (= (compiler_ir_types.compiler-ir-summary-globals summary) 1)
            unit
            (set! ok false))
          (if (= (compiler_ir_types.compiler-ir-summary-functions summary) 2)
            unit
            (set! ok false))
          (if (= (compiler_ir_types.compiler-ir-summary-externs summary) 1)
            unit
            (set! ok false))
          (if (= (compiler_ir_types.compiler-ir-summary-blocks summary) 7)
            unit
            (set! ok false))
          (if (=
            (compiler_ir_types.compiler-ir-summary-instructions summary)
            20)
            unit
            (set! ok false))
          (if (= (compiler_ir_types.compiler-ir-summary-vars summary) 13)
            unit
            (set! ok false))
          (if (= (compiler_ir_types.compiler-ir-summary-empty-blocks summary) 0)
            unit
            (set! ok false))
          (if (=
            (compiler_ir_types.compiler-ir-summary-max-instructions-function
              summary)
            17)
            unit
            (set! ok false))
          (if (=
            (compiler_ir_types.compiler-ir-summary-max-instructions-block
              summary)
            6)
            unit
            (set! ok false))
          (if (=
            (compiler_ir_types.compiler-ir-summary-call-arg-entries summary)
            1)
            unit
            (set! ok false))
          (if (=
            (compiler_ir_types.compiler-ir-summary-phi-input-entries summary)
            0)
            unit
            (set! ok false))
          ok))]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; Count `CompilerIrInstr.Phi` nodes, to assert the merge-phi shape of lowered scalar
;; matches: value-returning matches emit a merge phi, unit matches none.
(define (lower-test-instr-phi-count [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Phi _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-load-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Load _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-splat-shape-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Splat _ _ actual-lanes actual-ty)
      (if (and
        (= actual-lanes lanes)
        (compiler_typecheck_core.tc-type-eq actual-ty elem-ty))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-branch-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Branch _ _ _) 1]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-total-enum-branch-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bounds-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.BoundsCheck _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-return-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Return _) 1]
    [_ 0]))

(define (lower-test-shared-slice-ref-type?
  [pools : compiler_ast_types.AstNodePoolContext]
  [ty : compiler_ast_types.AstType]) : bool
  (match ty
    [(compiler_ast_types.AstType.Ref _ referent-id)
      (match (compiler_ast_types.ast-node-pool-context-type-get
        pools
        referent-id)
        [(compiler_ast_types.AstType.Slice elem-id)
          (match (compiler_ast_types.ast-node-pool-context-type-get
            pools
            elem-id)
            [(compiler_ast_types.AstType.I64) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (lower-test-pack-values-shape?
  [values : compiler_ir_types.CompilerIrValueSeq]) : bool
  (if (=
    (compiler_ir_types.compiler-ir-value-seq-count
      (owned_view.compiler-owned-shared-view values))
    2)
    (match (compiler_ir_types.compiler-ir-value-seq-ref
      (owned_view.compiler-owned-shared-view values)
      1)
      [(compiler_ir_types.CompilerIrValue.I64 length) (= length 3)]
      [_ false])
    false))

(define (lower-test-instr-pack-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Pack _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-pack-shape-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [pools : compiler_ast_types.AstNodePoolContext]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Pack _ values ty)
      (if (and
        (lower-test-pack-values-shape? values)
        (lower-test-shared-slice-ref-type? pools ty))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-call-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Call _ call-name _ _)
      (if (string.eq (compiler_ir_types.compiler-ir-symbol-text call-name) name)
        1
        0)]
    [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult payload-box)
      (let
        [call-name
          (__tl-project-field
            (compiler_ir_types.compiler-ir-box-shared-view payload-box)
            name)]
        (if (string.eq
          (compiler_ir_types.compiler-ir-symbol-text call-name)
          name)
          1
          0))]
    [_ 0]))

(define (lower-test-instr-cpuid-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.CpuId _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-xgetbv-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Xgetbv _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-call-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.CallIndirect _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-tail-call-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.TailCallIndirect _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-c-call-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.CallIndirectC _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-unit-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.CallIndirect _ _ _ ty)
      (match ty
        [(compiler_ast_types.AstType.Unit) 1]
        [_ 0])]
    [(compiler_ir_types.CompilerIrInstr.TailCallIndirect _ _ ty)
      (match ty
        [(compiler_ast_types.AstType.Unit) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-value-function-count
  [value : compiler_ir_types.CompilerIrValue]
  [name : String]) : i64
  (match value
    [(compiler_ir_types.CompilerIrValue.Function found)
      (if (string.eq (compiler_ir_types.compiler-ir-symbol-text found) name)
        1
        0)]
    [_ 0]))

(define (lower-test-call-args-function-count
  [args : compiler_ir_types.CompilerIrCallArgs]
  [name : String]) : i64
  (match args
    [(compiler_ir_types.CompilerIrCallArgs.Nil) 0]
    [(compiler_ir_types.CompilerIrCallArgs.One value)
      (lower-test-value-function-count value name)]
    [(compiler_ir_types.CompilerIrCallArgs.Two a b)
      (+
        (lower-test-value-function-count
          a
          (owned_view.compiler-owned-shared-view name))
        (lower-test-value-function-count b name))]
    [(compiler_ir_types.CompilerIrCallArgs.Array values)
      (lower-test-call-args-array-function-count values name 0)]))

(define (lower-test-call-args-array-function-count
  [values : (__tl_dyn-array compiler_ir_types.CompilerIrValue)]
  [name : String]
  [index : i64]) : i64
  (if (>= index (array-length values))
    0
    (+
      (lower-test-value-function-count
        (compiler_ir_types.compiler-ir-array-shared-view values index)
        (owned_view.compiler-owned-shared-view name))
      (lower-test-call-args-array-function-count values name (+ index 1)))))

(define (lower-test-instr-return-function-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [function-name : String]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Return maybe-value)
      (match maybe-value
        [(compiler_ir_types.CompilerIrMaybeValue.Some value)
          (lower-test-value-function-count value function-name)]
        [(compiler_ir_types.CompilerIrMaybeValue.No) 0])]
    [_ 0]))

(define (lower-test-instr-indirect-callee-function-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [function-name : String]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.CallIndirect _ func _ _)
      (lower-test-value-function-count func function-name)]
    [(compiler_ir_types.CompilerIrInstr.TailCallIndirect func _ _)
      (lower-test-value-function-count func function-name)]
    [_ 0]))

(define (lower-test-instr-call-arg-function-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [call-name : String]
  [function-name : String]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Call _ found args _)
      (if (string.eq
        (compiler_ir_types.compiler-ir-symbol-text found)
        call-name)
        (lower-test-call-args-function-count args function-name)
        0)]
    [_ 0]))

(define (lower-test-instr-tail-call-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.TailCall call-name _ _)
      (if (string.eq (compiler_ir_types.compiler-ir-symbol-text call-name) name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-store-ptr-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.StorePtr _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-copy-bytes-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.CopyBytes _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-alloc-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Alloc _ _) 1]
    [_ 0]))

(define (lower-test-instr-addr-of-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.AddrOf _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-load-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.VectorLoad _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.VectorBinOp _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-op-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [want : compiler_ir_types.CompilerIrBinOp]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.VectorBinOp payload-box)
      (let
        [op
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box op)]
        (if (lower-test-binop-same?
          (owned_view.compiler-owned-shared-view op)
          want)
          1
          0))]
    [_ 0]))

(define (lower-test-instr-vector-reduce-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.VectorReduce _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-store-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.VectorStore _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-load-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.PredicatedLoad _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-store-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.PredicatedStore _) 1]
    [_ 0]))

(define (lower-test-instr-select-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Select _) 1]
    [_ 0]))

(define (lower-test-instr-tail-mask-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.TailMask _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-spmd-call-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.SpmdCall _) 1]
    [_ 0]))

(define (lower-test-instr-seq-spmd-call-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-spmd-call-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-spmd-call-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-spmd-call-count instrs)
            (lower-test-blocks-spmd-call-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-block-seq-spmd-call-count seq)]))

(define (lower-test-block-seq-spmd-call-count
  [blocks : compiler_ir_types.CompilerIrBlockSeq]) : i64
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrBlock) blocks.slots]
    [count : i64 blocks.len]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (compiler_ir_types.compiler-ir-array-shared-view slots index)
            [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
              (set! acc (+ acc (lower-test-instr-seq-spmd-call-count instrs)))])
          (set! index (+ index 1))))
      acc)))

(define (lower-test-function-spmd-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (lower-test-function-seq-spmd-call-count funcs name))

(define (lower-test-function-seq-spmd-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrFunction) funcs.slots]
    [count : i64 funcs.len]
    [index : i64 0]
    [result : i64 (- 0 1)]
    (begin
      (while (and (< index count) (< result 0))
        (begin
          (match (compiler_ir_types.compiler-ir-array-shared-view slots index)
            [(compiler_ir_types.CompilerIrFunction.Function fname _ _ _ blocks)
              (if (string.eq
                (compiler_ir_types.compiler-ir-symbol-text fname)
                name)
                (set! result (lower-test-blocks-spmd-call-count blocks))
                unit)])
          (set! index (+ index 1))))
      result)))

(define (lower-test-vector-shape?
  [actual-lanes : i64]
  [actual-ty : compiler_ast_types.AstType]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : bool
  (and
    (= actual-lanes lanes)
    (compiler_typecheck_core.tc-type-eq actual-ty elem-ty)))

(define (lower-test-instr-vector-shape-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.VectorLoad _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape?
        actual-lanes
        (owned_view.compiler-owned-shared-view actual-ty)
        lanes
        (owned_view.compiler-owned-shared-view elem-ty))
        1
        0)]
    [(compiler_ir_types.CompilerIrInstr.VectorBinOp payload-box)
      (let
        [actual-lanes
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            lanes)]
        [actual-ty
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape?
          actual-lanes
          (owned_view.compiler-owned-shared-view actual-ty)
          lanes
          (owned_view.compiler-owned-shared-view elem-ty))
          1
          0))]
    [(compiler_ir_types.CompilerIrInstr.VectorReduce
        _
        _
        _
        actual-lanes
        actual-ty)
      (if (lower-test-vector-shape?
        actual-lanes
        (owned_view.compiler-owned-shared-view actual-ty)
        lanes
        (owned_view.compiler-owned-shared-view elem-ty))
        1
        0)]
    [(compiler_ir_types.CompilerIrInstr.VectorStore payload-box)
      (let
        [actual-lanes
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            lanes)]
        [actual-ty
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape?
          actual-lanes
          (owned_view.compiler-owned-shared-view actual-ty)
          lanes
          (owned_view.compiler-owned-shared-view elem-ty))
          1
          0))]
    [(compiler_ir_types.CompilerIrInstr.PredicatedLoad payload-box)
      (let
        [actual-lanes
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            lanes)]
        [actual-ty
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape?
          actual-lanes
          (owned_view.compiler-owned-shared-view actual-ty)
          lanes
          (owned_view.compiler-owned-shared-view elem-ty))
          1
          0))]
    [(compiler_ir_types.CompilerIrInstr.GatherLoad payload-box)
      (let
        [actual-lanes
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            lanes)]
        [actual-ty
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape?
          actual-lanes
          (owned_view.compiler-owned-shared-view actual-ty)
          lanes
          (owned_view.compiler-owned-shared-view elem-ty))
          1
          0))]
    [(compiler_ir_types.CompilerIrInstr.PredicatedStore payload-box)
      (let
        [actual-lanes
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            lanes)]
        [actual-ty
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape?
          actual-lanes
          (owned_view.compiler-owned-shared-view actual-ty)
          lanes
          (owned_view.compiler-owned-shared-view elem-ty))
          1
          0))]
    [(compiler_ir_types.CompilerIrInstr.Select payload-box)
      (let
        [actual-lanes
          (compiler_ir_types.compiler-ir-box-field-shared-view
            payload-box
            lanes)]
        [actual-ty
          (compiler_ir_types.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape?
          actual-lanes
          (owned_view.compiler-owned-shared-view actual-ty)
          lanes
          (owned_view.compiler-owned-shared-view elem-ty))
          1
          0))]
    [(compiler_ir_types.CompilerIrInstr.Splat _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-u64-mov-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Mov _ _ ty)
      (match ty
        [(compiler_ast_types.AstType.U64) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-binop-same?
  [actual : compiler_ir_types.CompilerIrBinOp]
  [want : compiler_ir_types.CompilerIrBinOp]) : bool
  (match actual
    [(compiler_ir_types.CompilerIrBinOp.Add)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Add) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Sub)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Sub) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Mul)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Mul) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Div)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Div) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Mod)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Mod) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.SafeDiv)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.SafeDiv) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.SafeMod)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.SafeMod) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Eq)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Eq) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Ne)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Ne) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Lt)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Lt) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Le)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Le) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Gt)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Gt) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Ge)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Ge) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.BitTestEq)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.BitTestEq) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.BitTestNe)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.BitTestNe) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.And)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.And) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Or)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Or) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.BitAnd)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.BitAnd) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.BitOr)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.BitOr) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.BitXor)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.BitXor) true]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Shl actual-count-ty)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Shl want-count-ty)
          (compiler_typecheck_core.tc-type-eq actual-count-ty want-count-ty)]
        [_ false])]
    [(compiler_ir_types.CompilerIrBinOp.Shr actual-count-ty)
      (match want
        [(compiler_ir_types.CompilerIrBinOp.Shr want-count-ty)
          (compiler_typecheck_core.tc-type-eq actual-count-ty want-count-ty)]
        [_ false])]))

(define (lower-test-instr-binop-op-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.BinOp _ actual _ _ _)
      (if (lower-test-binop-same? actual op)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-i64-binop-op-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.BinOp _ actual _ _ ty)
      (if (and
        (lower-test-binop-same? actual op)
        (match ty
          [(compiler_ast_types.AstType.I64) true]
          [_ false]))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-cast-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Cast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bitcast-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Bitcast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-store-global-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Store store-name _ _)
      (if (string.eq
        (compiler_ir_types.compiler-ir-symbol-text store-name)
        name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-call-name?
  [instr : compiler_ir_types.CompilerIrInstr]
  [name : String]) : bool
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Call _ call-name _ _)
      (string.eq (compiler_ir_types.compiler-ir-symbol-text call-name) name)]
    [(compiler_ir_types.CompilerIrInstr.TailCall call-name _ _)
      (string.eq (compiler_ir_types.compiler-ir-symbol-text call-name) name)]
    [_ false]))

(define (lower-test-instr-seq-phi-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-phi-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-splat-shape-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-splat-shape-count
                (owned_view.compiler-owned-array-element-shared-view
                  slots
                  index)
                lanes
                (owned_view.compiler-owned-shared-view elem-ty))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-load-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-load-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-branch-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-branch-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-total-enum-branch-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-total-enum-branch-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-bounds-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-bounds-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-return-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-return-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-pack-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-pack-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-pack-shape-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [pools : compiler_ast_types.AstNodePoolContext]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-pack-shape-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (owned_view.compiler-owned-shared-view pools))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-call-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (compiler_ir_types.compiler-ir-global-shared-view name))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-before?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [first : String]
  [second : String]) : bool
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [seen-first : bool false]
    [done : bool false]
    [result : bool false]
    (begin
      (while (and (< index count) (not done))
        (let
          [instr : compiler_ir_types.CompilerIrInstr
            (compiler_ir_types.compiler-ir-array-shared-view slots index)]
          (begin
            (if (lower-test-instr-call-name?
              (compiler_ir_types.compiler-ir-global-shared-view instr)
              (compiler_ir_types.compiler-ir-global-shared-view second))
              (begin
                (set! result seen-first)
                (set! done true))
              (if (lower-test-instr-call-name?
                (compiler_ir_types.compiler-ir-global-shared-view instr)
                (compiler_ir_types.compiler-ir-global-shared-view first))
                (set! seen-first true)
                unit))
            (set! index (+ index 1)))))
      result)))

(define (lower-test-instr-seq-cpuid-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-cpuid-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-xgetbv-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-xgetbv-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-call-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-call-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-tail-call-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
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
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-c-call-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-c-call-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-unit-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-unit-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-return-function-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [function-name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
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
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (owned_view.compiler-owned-shared-view function-name))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-callee-function-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [function-name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
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
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (owned_view.compiler-owned-shared-view function-name))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-arg-function-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [call-name : String]
  [function-name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
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
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (owned_view.compiler-owned-shared-view call-name)
                (owned_view.compiler-owned-shared-view function-name))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-tail-call-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-tail-call-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (compiler_ir_types.compiler-ir-global-shared-view name))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-store-ptr-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-store-ptr-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-copy-bytes-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-copy-bytes-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-alloc-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-alloc-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-addr-of-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-addr-of-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-load-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-load-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-binop-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-binop-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-binop-op-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [want : compiler_ir_types.CompilerIrBinOp]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
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
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (owned_view.compiler-owned-shared-view want))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-reduce-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-reduce-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-store-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-store-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-predicated-load-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-predicated-load-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-predicated-store-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-predicated-store-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-select-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-select-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-tail-mask-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-tail-mask-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-shape-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
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
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                lanes
                (compiler_ast_types.ast-global-shared-view elem-ty))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-u64-mov-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-u64-mov-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-binop-op-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-binop-op-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (compiler_ir_types.compiler-ir-global-shared-view op))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-i64-binop-op-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-i64-binop-op-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (compiler_ir_types.compiler-ir-global-shared-view op))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-cast-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-cast-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-bitcast-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-bitcast-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-store-global-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-store-global-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                (compiler_ir_types.compiler-ir-global-shared-view name))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-phi-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-phi-count instrs)
            (lower-test-blocks-phi-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-phi-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-load-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-load-count instrs)
            (lower-test-blocks-load-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-load-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-splat-shape-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-splat-shape-count
              instrs
              lanes
              (owned_view.compiler-owned-shared-view elem-ty))
            (lower-test-blocks-splat-shape-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              lanes
              elem-ty))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-splat-shape-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        lanes
        elem-ty)]))

(define (lower-test-blocks-label-load-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [want-label : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) (- 0 1)]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block label instrs)
          (if (string.eq
            (compiler_ir_types.compiler-ir-label-text label)
            want-label)
            (lower-test-instr-seq-load-count instrs)
            (lower-test-blocks-label-load-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              want-label))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-label-load-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        want-label)]))

(define (lower-test-blocks-branch-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-branch-count instrs)
            (lower-test-blocks-branch-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-branch-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-total-enum-branch-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-total-enum-branch-count instrs)
            (lower-test-blocks-total-enum-branch-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-total-enum-branch-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-bounds-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-bounds-count instrs)
            (lower-test-blocks-bounds-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-bounds-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-return-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-return-count instrs)
            (lower-test-blocks-return-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-return-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-pack-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-pack-count instrs)
            (lower-test-blocks-pack-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-pack-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-pack-shape-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [pools : compiler_ast_types.AstNodePoolContext]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-pack-shape-count
              instrs
              (compiler_ast_types.ast-global-shared-view pools))
            (lower-test-blocks-pack-shape-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              pools))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-pack-shape-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        pools)]))

(define (lower-test-blocks-call-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-call-count
              instrs
              (compiler_ir_types.compiler-ir-global-shared-view name))
            (lower-test-blocks-call-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              name))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-call-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        name)]))

(define (lower-test-blocks-call-before?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [first : String]
  [second : String]) : bool
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) false]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (if (lower-test-instr-seq-call-before?
            instrs
            (compiler_ir_types.compiler-ir-global-shared-view first)
            (compiler_ir_types.compiler-ir-global-shared-view second))
            true
            (lower-test-blocks-call-before?
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              first
              second))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-call-before?
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        first
        second)]))

(define (lower-test-blocks-cpuid-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-cpuid-count instrs)
            (lower-test-blocks-cpuid-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-cpuid-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-xgetbv-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-xgetbv-count instrs)
            (lower-test-blocks-xgetbv-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-xgetbv-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-call-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-call-count instrs)
            (lower-test-blocks-indirect-call-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-call-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-tail-call-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-tail-call-count instrs)
            (lower-test-blocks-indirect-tail-call-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-tail-call-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-c-call-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-c-call-count instrs)
            (lower-test-blocks-indirect-c-call-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-c-call-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-indirect-unit-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-unit-count instrs)
            (lower-test-blocks-indirect-unit-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-unit-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-return-function-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-return-function-count
              instrs
              (compiler_ir_types.compiler-ir-global-shared-view function-name))
            (lower-test-blocks-return-function-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              function-name))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-return-function-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        function-name)]))

(define (lower-test-blocks-indirect-callee-function-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-callee-function-count
              instrs
              (owned_view.compiler-owned-shared-view function-name))
            (lower-test-blocks-indirect-callee-function-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              function-name))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-indirect-callee-function-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        function-name)]))

(define (lower-test-blocks-call-arg-function-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [call-name : String]
  [function-name : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-call-arg-function-count
              instrs
              (owned_view.compiler-owned-shared-view call-name)
              (owned_view.compiler-owned-shared-view function-name))
            (lower-test-blocks-call-arg-function-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              call-name
              function-name))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-call-arg-function-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        call-name
        function-name)]))

(define (lower-test-blocks-tail-call-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-tail-call-count
              instrs
              (compiler_ir_types.compiler-ir-global-shared-view name))
            (lower-test-blocks-tail-call-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              name))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-tail-call-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        name)]))

(define (lower-test-blocks-store-ptr-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-store-ptr-count instrs)
            (lower-test-blocks-store-ptr-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-store-ptr-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-copy-bytes-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-copy-bytes-count instrs)
            (lower-test-blocks-copy-bytes-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-copy-bytes-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-alloc-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-alloc-count instrs)
            (lower-test-blocks-alloc-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-alloc-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-addr-of-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-addr-of-count instrs)
            (lower-test-blocks-addr-of-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-addr-of-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-load-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-load-count instrs)
            (lower-test-blocks-vector-load-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-load-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-binop-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-binop-count instrs)
            (lower-test-blocks-vector-binop-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-binop-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-binop-op-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [want : compiler_ir_types.CompilerIrBinOp]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-binop-op-count
              instrs
              (owned_view.compiler-owned-shared-view want))
            (lower-test-blocks-vector-binop-op-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              want))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-binop-op-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        want)]))

(define (lower-test-blocks-vector-reduce-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-reduce-count instrs)
            (lower-test-blocks-vector-reduce-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-reduce-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-store-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-store-count instrs)
            (lower-test-blocks-vector-store-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-store-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-predicated-load-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-predicated-load-count instrs)
            (lower-test-blocks-predicated-load-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-predicated-load-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-predicated-store-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-predicated-store-count instrs)
            (lower-test-blocks-predicated-store-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-predicated-store-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-select-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-select-count instrs)
            (lower-test-blocks-select-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-select-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-tail-mask-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-tail-mask-count instrs)
            (lower-test-blocks-tail-mask-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-tail-mask-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-vector-shape-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-vector-shape-count
              instrs
              lanes
              (compiler_ast_types.ast-global-shared-view elem-ty))
            (lower-test-blocks-vector-shape-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              lanes
              elem-ty))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-vector-shape-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        lanes
        elem-ty)]))

(define (lower-test-blocks-u64-mov-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-u64-mov-count instrs)
            (lower-test-blocks-u64-mov-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-u64-mov-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-binop-op-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-binop-op-count
              instrs
              (compiler_ir_types.compiler-ir-global-shared-view op))
            (lower-test-blocks-binop-op-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              op))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-binop-op-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        op)]))

(define (lower-test-blocks-i64-binop-op-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-i64-binop-op-count
              instrs
              (compiler_ir_types.compiler-ir-global-shared-view op))
            (lower-test-blocks-i64-binop-op-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              op))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-i64-binop-op-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        op)]))

(define (lower-test-blocks-cast-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-cast-count instrs)
            (lower-test-blocks-cast-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-cast-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-bitcast-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-bitcast-count instrs)
            (lower-test-blocks-bitcast-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-bitcast-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-store-global-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-store-global-count
              instrs
              (compiler_ir_types.compiler-ir-global-shared-view name))
            (lower-test-blocks-store-global-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              name))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-store-global-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        name)]))

;; Phi count of the function named `name`, or -1 when no such function exists
;; (so a missing function fails both the `> 0` and `= 0` assertions below).
(defenum LowerTestMaybeFunction
  (No)
  (Some compiler_ir_types.CompilerIrFunction))

(define (lower-test-function-seq-find-from
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [index : i64]) : LowerTestMaybeFunction
  (if (>= index funcs.len)
    (LowerTestMaybeFunction.No)
    (let
      [func : compiler_ir_types.CompilerIrFunction
        (compiler_ir_types.compiler-ir-function-seq-ref
          (compiler_ir_types.compiler-ir-global-shared-view funcs)
          index)]
      (match (compiler_ir_types.compiler-ir-global-shared-view func)
        [(compiler_ir_types.CompilerIrFunction.Function fname _ _ _ _)
          (if (string.eq (compiler_ir_types.compiler-ir-symbol-text fname) name)
            (LowerTestMaybeFunction.Some func)
            (lower-test-function-seq-find-from funcs name (+ index 1)))]))))

(define (lower-test-function-seq-find
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : LowerTestMaybeFunction
  (lower-test-function-seq-find-from funcs name 0))

(define (lower-test-function-defined?
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : bool
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) false]
    [(LowerTestMaybeFunction.Some _) true]))

(define (lower-test-function-param-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ params _ _ _)
          (compiler_ir_types.compiler-ir-param-list-count params)])]))

(define (lower-test-param-name-at
  [params : compiler_ir_types.CompilerIrParamList]
  [index : i64]) : String
  (match (compiler_ir_types.compiler-ir-param-list-force-cons params)
    [(compiler_ir_types.CompilerIrParamList.Nil) ""]
    [(compiler_ir_types.CompilerIrParamList.Array seq)
      (lower-test-param-name-at
        (compiler_ir_types.compiler-ir-param-seq-to-list seq)
        index)]
    [(compiler_ir_types.CompilerIrParamList.Cons param rest)
      (if (= index 0)
        (match param
          [(compiler_ir_types.CompilerIrParam.Param name _ _) name])
        (lower-test-param-name-at
          (compiler_ir_types.compiler-ir-box-shared-view rest)
          (- index 1)))]))

(define (lower-test-function-param-name
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [index : i64]) : String
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) ""]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ params _ _ _)
          (lower-test-param-name-at params index)])]))

(define (lower-test-function-phi-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-phi-count blocks)])]))

(define (lower-test-function-load-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-load-count blocks)])]))

(define (lower-test-function-splat-shape-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-splat-shape-count blocks lanes elem-ty)])]))

(define (lower-test-function-label-load-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [want-label : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-label-load-count blocks want-label)])]))

(define (lower-test-function-branch-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-branch-count blocks)])]))

(define (lower-test-function-total-enum-branch-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-total-enum-branch-count blocks)])]))

(define (lower-test-function-bounds-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-bounds-count blocks)])]))

(define (lower-test-function-return-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-return-count blocks)])]))

(define (lower-test-function-pack-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-pack-count blocks)])]))

(define (lower-test-function-pack-shape-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [pools : compiler_ast_types.AstNodePoolContext]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-pack-shape-count blocks pools)])]))

(define (lower-test-functions-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set!
                count
                (+
                  count
                  (lower-test-blocks-call-count
                    blocks
                    (compiler_ir_types.compiler-ir-global-shared-view name))))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-functions-branch-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set! count (+ count (lower-test-blocks-branch-count blocks)))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-functions-return-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set! count (+ count (lower-test-blocks-return-count blocks)))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-functions-tail-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set!
                count
                (+
                  count
                  (lower-test-blocks-tail-call-count
                    blocks
                    (compiler_ir_types.compiler-ir-global-shared-view name))))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-functions-direct-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (+
    (lower-test-functions-call-count
      (owned_view.compiler-owned-shared-view funcs)
      (owned_view.compiler-owned-shared-view name))
    (lower-test-functions-tail-call-count funcs name)))

(define (lower-test-functions-cpuid-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set! count (+ count (lower-test-blocks-cpuid-count blocks)))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-functions-xgetbv-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set! count (+ count (lower-test-blocks-xgetbv-count blocks)))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-function-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [call-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-call-count blocks call-name)])]))

(define (lower-test-function-call-before?
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [first : String]
  [second : String]) : bool
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) false]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-call-before? blocks first second)])]))

(define (lower-test-function-indirect-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-indirect-call-count blocks)])]))

(define (lower-test-function-indirect-tail-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-indirect-tail-call-count blocks)])]))

(define (lower-test-function-indirect-c-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-indirect-c-call-count blocks)])]))

(define (lower-test-function-indirect-unit-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-indirect-unit-count blocks)])]))

(define (lower-test-function-return-function-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [function-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-return-function-count blocks function-name)])]))

(define (lower-test-function-indirect-callee-function-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [function-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-indirect-callee-function-count
            blocks
            function-name)])]))

(define (lower-test-function-call-arg-function-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [call-name : String]
  [function-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-call-arg-function-count
            blocks
            call-name
            function-name)])]))

(define (lower-test-function-tail-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [call-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-tail-call-count blocks call-name)])]))

(define (lower-test-function-direct-call-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [call-name : String]) : i64
  (+
    (lower-test-function-call-count
      (owned_view.compiler-owned-shared-view funcs)
      (owned_view.compiler-owned-shared-view name)
      (owned_view.compiler-owned-shared-view call-name))
    (lower-test-function-tail-call-count funcs name call-name)))

(define (lower-test-function-store-ptr-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-store-ptr-count blocks)])]))

(define (lower-test-function-copy-bytes-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-copy-bytes-count blocks)])]))

(define (lower-test-function-alloc-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-alloc-count blocks)])]))

(define (lower-test-function-addr-of-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-addr-of-count blocks)])]))

(define (lower-test-function-vector-load-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-vector-load-count blocks)])]))

(define (lower-test-function-vector-binop-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-vector-binop-count blocks)])]))

(define (lower-test-function-vector-binop-op-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [want : compiler_ir_types.CompilerIrBinOp]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-vector-binop-op-count blocks want)])]))

(define (lower-test-function-vector-reduce-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-vector-reduce-count blocks)])]))

(define (lower-test-function-vector-store-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-vector-store-count blocks)])]))

(define (lower-test-function-predicated-load-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-predicated-load-count blocks)])]))

(define (lower-test-function-predicated-store-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-predicated-store-count blocks)])]))

(define (lower-test-function-select-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-select-count blocks)])]))

(define (lower-test-function-tail-mask-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-tail-mask-count blocks)])]))

(define (lower-test-function-vector-shape-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-vector-shape-count blocks lanes elem-ty)])]))

(define (lower-test-function-u64-mov-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-u64-mov-count blocks)])]))

(define (lower-test-function-binop-op-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-binop-op-count blocks op)])]))

(define (lower-test-function-i64-binop-op-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [op : compiler_ir_types.CompilerIrBinOp]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-i64-binop-op-count blocks op)])]))

(define (lower-test-function-cast-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-cast-count blocks)])]))

(define (lower-test-function-bitcast-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-bitcast-count blocks)])]))

(define (lower-test-functions-bitcast-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index funcs.len)
        (begin
          (match (compiler_ir_types.compiler-ir-function-seq-ref
            (compiler_ir_types.compiler-ir-global-shared-view funcs)
            index)
            [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
              (set! count (+ count (lower-test-blocks-bitcast-count blocks)))])
          (set! index (+ index 1))))
      count)))

(define (lower-test-function-store-global-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [global-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-store-global-count blocks global-name)])]))

(define (lower-test-global-seq-has-name-at?
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [name : String]
  [index : i64]) : bool
  (if (>= index globals.len)
    false
    (match (compiler_ir_types.compiler-ir-global-seq-ref
      (owned_view.compiler-owned-shared-view globals)
      index)
      [(compiler_ir_types.CompilerIrGlobal.Global global-name _ _)
        (if (string.eq
          (compiler_ir_types.compiler-ir-symbol-text global-name)
          (owned_view.compiler-owned-shared-view name))
          true
          (lower-test-global-seq-has-name-at? globals name (+ index 1)))])))

(define (lower-test-global-list-has-name?
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [name : String]) : bool
  (lower-test-global-seq-has-name-at? globals name 0))

(define (compiler-lower-defdispatch-thunk-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-defdispatch-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program globals functions _)
          (let
            [cache-name : String "__tl_dispatch_cache_dot"]
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            [ok : bool true]
            (begin
              (if (lower-test-global-list-has-name?
                globals
                (owned_view.compiler-owned-shared-view cache-name))
                unit
                (set! ok false))
              (if (lower-test-function-defined?
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "dot")
                unit
                (set! ok false))
              (if (lower-test-function-defined?
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                (owned_view.compiler-owned-shared-view scalar-name))
                unit
                (set! ok false))
              (if (lower-test-function-defined?
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                (owned_view.compiler-owned-shared-view avx2-name))
                unit
                (set! ok false))
              (if (lower-test-function-defined?
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                (owned_view.compiler-owned-shared-view avx512-name))
                unit
                (set! ok false))
              (when
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot-scalar")
                (set! ok false))
              (when
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot-avx2")
                (set! ok false))
              (when
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot-avx512")
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "dot")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-indirect-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot")
                4)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-store-global-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot"
                  cache-name)
                3)
                unit
                (set! ok false))
              (if (>=
                (lower-test-functions-cpuid-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                6)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-xgetbv-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot"
                  scalar-name)
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot"
                  avx2-name)
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot"
                  avx512-name)
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-defdispatch-structural-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-defdispatch-structural-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "dot")
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "dot")
              1)
            (>=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "dot")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-defdispatch-shared-helper-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-defdispatch-shared-helper-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            [ok : bool true]
            (begin
              (if (lower-test-function-defined?
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "dispatch-helper")
                unit
                (set! ok false))
              (when
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot-scalar")
                (set! ok false))
              (when
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot-avx2")
                (set! ok false))
              (when
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "dot-avx512")
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  scalar-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  avx2-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  avx512-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-generated-path-source) : String
  "(defstruct Point (x i64))
(defstruct Point (x i64))
(define (after [x : i64]) : i64 (+ x 1))
(define (main) : i64 (after 41))")

(define (compiler-lower-generated-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "gen.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "gen.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        "lib.tl"
        (compiler_ast_types.ast-decl-root-path-cons
          "app.tl"
          (compiler_ast_types.ast-decl-path-list-new))))))

(define (compiler-lower-generated-paths-preserved-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-generated-path-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            [args : compiler_ast_types.AstExprList
              (compiler_ast_types.ast-expr-list-new)]
            (begin
              (compiler_ast_types.ast-expr-list-push
                (&mut args)
                (compiler_ast_types.ast-node-push
                  (compiler_ast_types.AstExpr.Literal
                    (compiler_ast_types.ast-lit-generated-string "same"))))
              (set!
                (array-ref decls.slots decls.offset)
                (compiler_ast_types.ast-decl-comptime-decl-with-meta
                  (compiler_ast_types.AstGeneratedDeclMeta.Some
                    "point-family"
                    "Point"
                    (owned_view.compiler-owned-shared-view args)
                    "")
                  (compiler_ast_types.ast-decl-list-get
                    (& decls)
                    0
                    (compiler_ast_types.ast-decl-fallback))))
              (set!
                (array-ref decls.slots (+ decls.offset 1))
                (compiler_ast_types.ast-decl-comptime-decl-with-meta
                  (compiler_ast_types.AstGeneratedDeclMeta.Some
                    "point-family"
                    "Point"
                    args
                    "")
                  (compiler_ast_types.ast-decl-list-get
                    (& decls)
                    1
                    (compiler_ast_types.ast-decl-fallback))))
              (match (lower-compiler-program-with-decl-paths
                "app.tl"
                program
                (compiler-lower-generated-paths))
                [(compiler_lower.ResultCompilerLower.Ok lowered _)
                  (match lowered
                    [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
                      (and
                        (lower-test-function-defined?
                          (compiler_ir_types.compiler-ir-global-shared-view
                            functions)
                          "lib.tl::after")
                        (lower-test-function-defined?
                          (compiler_ir_types.compiler-ir-global-shared-view
                            functions)
                          "main")
                        (=
                          (lower-test-function-direct-call-count
                            (compiler_ir_types.compiler-ir-global-shared-view
                              functions)
                            "main"
                            "lib.tl::after")
                          1))])]
                [(compiler_lower.ResultCompilerLower.Err _) false])))])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-module-symbol-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x answer))
(define (main) : i64 (inc answer))")

(define (compiler-lower-module-symbol-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "lib.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "lib.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        "app.tl"
        (compiler_ast_types.ast-decl-path-list-new)))))

(define (compiler-lower-module-symbols-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-module-symbol-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-symbol-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program globals functions _)
              (and
                (lower-test-global-list-has-name? globals "lib.tl::answer")
                (>
                  (lower-test-functions-direct-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "lib.tl::inc")
                  0)
                (>
                  (lower-test-function-binop-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "lib.tl::inc")
                  0)
                (>=
                  (lower-test-function-binop-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-package-owned-symbol-source) : String
  "(define (runtime-helper) : i64 1)
(define (app-helper) : i64 41)
(define (main) : i64 (+ (runtime-helper) (app-helper)))")

(define (compiler-lower-package-owned-symbol-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "app/src/main.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        ""
        (compiler_ast_types.ast-decl-path-list-new)))))

(define (compiler-lower-package-owned-symbols-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-package-owned-symbol-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        ""
        program
        (compiler-lower-package-owned-symbol-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "stdlib/runtime.tl::runtime-helper")
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                (=
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "app/src/main.tl::app-helper")
                  1))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-module-qualified-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program globals functions _)
          (and
            (lower-test-global-list-has-name?
              (owned_view.compiler-owned-shared-view globals)
              "left/same")
            (lower-test-global-list-has-name? globals "right/same")
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "left/get")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "right/get")
              0)
            (>
              (lower-test-function-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-import-alias-source) : String
  "(module data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import data as d)
(define (main) : i64
  (+
    (d.get)
    (+
      (let [p : d.Point (d.Point 7)]
        p.x)
      (match (d.Maybe.Some 3)
        [(d.Maybe.Some v) v]
        [d.Maybe.None 0]))))")

(define (compiler-lower-import-alias-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-import-alias-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "data/get")
              0)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "d/get")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-package-alias-collision-source) : String
  "(module left.src.lib)
(define (same [value : i64]) : i64 (+ value 11))
(module right.src.lib)
(define (same [value : i64]) : i64 (+ value 21))
(module consumer.src.main)
(import left.src.lib as left)
(import right.src.lib as right)
(define (main) : i64 (+ (left.same 1) (right.same 1)))")

(define (compiler-lower-package-alias-collision-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "surface_left/src/lib.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "surface_left/src/lib.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        "surface_right/src/lib.tl"
        (compiler_ast_types.ast-decl-root-path-cons
          "surface_right/src/lib.tl"
          (compiler_ast_types.ast-decl-root-path-cons
            "consumer/src/main.tl"
            (compiler_ast_types.ast-decl-root-path-cons
              "consumer/src/main.tl"
              (compiler_ast_types.ast-decl-root-path-cons
                "consumer/src/main.tl"
                (compiler_ast_types.ast-decl-root-path-cons
                  "consumer/src/main.tl"
                  (compiler_ast_types.ast-decl-path-list-new))))))))))

(define (compiler-lower-package-alias-collision-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-package-alias-collision-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "consumer/src/main.tl"
        program
        (compiler-lower-package-alias-collision-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (=
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "surface_left/src/lib.tl::left.src.lib/same")
                  1)
                (=
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "surface_right/src/lib.tl::right.src.lib/same")
                  1))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-package-extern-alias-symbols-ok?) : bool
  (let
    [name : i64 (ci.intern "same")]
    [left-module : i64 (ci.intern "left.src.lib")]
    [right-module : i64 (ci.intern "right.src.lib")]
    [left : compiler_ast_types.AstDecl
      (compiler_load.compiler-load-package-def-fn-extern
        "surface_left"
        "C:/surface_left/"
        (svec.new)
        "C:/surface_left/src/lib.tl"
        "left.src.lib"
        name
        (compiler_ast_types.ast-param-list-new)
        (compiler_ast_types.AstType.I64)
        compiler_load.CompilerLoadPackageSpmdInterface.Unavailable)]
    [right : compiler_ast_types.AstDecl
      (compiler_load.compiler-load-package-def-fn-extern
        "surface_right"
        "C:/surface_right/"
        (svec.new)
        "C:/surface_right/src/lib.tl"
        "right.src.lib"
        name
        (compiler_ast_types.ast-param-list-new)
        (compiler_ast_types.AstType.I64)
        compiler_load.CompilerLoadPackageSpmdInterface.Unavailable)]
    [lower-state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-capture-active))]
    (match left
      [(compiler_ast_types.AstDecl.Extern _ _ _ left-meta _)
        (match right
          [(compiler_ast_types.AstDecl.Extern _ _ _ right-meta _)
            (let
              [left-symbol : i64
                (compiler_lower.lower-extern-logical-symbol-id
                  lower-state
                  (compiler_symbols.compiler-symbol-module-key-id-by-id
                    left-module
                    name)
                  "same"
                  name
                  (compiler_ast_types.ast-extern-metadata-box-shared-view
                    left-meta))]
              [right-symbol : i64
                (compiler_lower.lower-extern-logical-symbol-id
                  lower-state
                  (compiler_symbols.compiler-symbol-module-key-id-by-id
                    right-module
                    name)
                  "same"
                  name
                  (compiler_ast_types.ast-extern-metadata-box-shared-view
                    right-meta))]
              (and
                (not (= left-symbol right-symbol))
                (string.eq
                  (compiler_ir_types.compiler-ir-symbol-text left-symbol)
                  "left.src.lib/same")
                (string.eq
                  (compiler_ir_types.compiler-ir-symbol-text right-symbol)
                  "right.src.lib/same")))]
          [_ false])]
      [_ false])))

(define (compiler-lower-selected-import-alias-name-env-ok?) : bool
  (let
    [target-module : i64 (ci.intern "selected.source")]
    [importer-module : i64 (ci.intern "selected.importer")]
    [item : i64 (ci.intern "source-value")]
    [alias : i64 (ci.intern "chosen")]
    [target-key : i64
      (compiler_symbols.compiler-symbol-module-key-id-by-id target-module item)]
    [alias-key : i64
      (compiler_symbols.compiler-symbol-module-key-id-by-id
        importer-module
        alias)]
    [symbol-id : i64 4242]
    [base : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        target-key
        target-key
        symbol-id
        (compiler_lower.LowerNameEnv.Nil))]
    [aliased : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-add-selected-item-alias
        (compiler_lower.compiler-lower-state-new)
        base
        importer-module
        target-module
        item
        alias)]
    (and
      (=
        (compiler_lower.lower-name-env-lookup-logical-id
          (compiler_lower.lower-global-shared-view aliased)
          alias-key
          -1)
        target-key)
      (=
        (compiler_lower.lower-name-env-lookup-symbol-id
          (compiler_lower.lower-global-shared-view aliased)
          alias-key
          -1)
        symbol-id)
      (=
        (compiler_lower.lower-name-env-lookup-symbol-id
          (compiler_lower.lower-global-shared-view aliased)
          target-key
          -1)
        symbol-id))))

(define (compiler-lower-dotted-import-default-alias-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(module main)
(import pkg.data)
(define (main) : i64 (+ (data.get) 1))")

(define (compiler-lower-dotted-import-default-alias-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-dotted-import-default-alias-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "pkg.data/get")
              0)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "data/get")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-dotted-import-string-call-source) : String
  "(module pkg.string)
(define (eq [left : (& left str)] [right : (& right str)]) : bool (= (__tl_string_length left) (__tl_string_length right)))
(module pkg.args)
(import pkg.string)
(defstruct ArgsOptionSpec (long String))
(define (args-option-spec-long [spec : ArgsOptionSpec]) : String
  spec.long)
(define (args-option-spec-matches-long? [spec : ArgsOptionSpec] [name : (& name str)]) : bool
  (let
    [long : String (args-option-spec-long spec)]
    (if (not (string.eq long \"\"))
      (string.eq long name)
      false)))")

(define (compiler-lower-dotted-import-string-call-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-dotted-import-string-call-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-functions-call-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "pkg.string/eq")
            0)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-function-returning-struct-source) : String
  "(module data)
(defstruct Candidate (number i64))
(define (cand-nth [cands : (__tl_dyn-array Candidate)]) : Candidate
  (array-ref cands 0))
(module main)
(import data)
(define (main) : i64
  (let [c : data.Candidate
    (data.cand-nth
      (__tl_make-array (data.Candidate 7)))]
    c.number))")

(define (compiler-lower-module-function-returning-struct-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-module-function-returning-struct-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-functions-call-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "data/cand-nth")
            0)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-module-function-returning-enum-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-functions-call-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "main/get")
            0)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-imported-enum-aggregate-payload-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-function-copy-bytes-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "main/make")
            0)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-macro-codegen-source) : String
  "(defmacro (int-box) : Module
  `(begin
    (module generated.intbox)
    (defstruct Box1 (value i64))
    (define (make [value : i64]) : Box1
      (Box1 value))
    (define (double [b : Box1]) : i64
      (* b.value 2))
    (define (bumped [b : Box1]) : i64
      (+ (double b) 1))))
(import (int-box) as ib)
(define (main) : i64 (ib.bumped (ib.make 20)))")

(define (compiler-lower-module-macro-codegen-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-module-macro-codegen-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "generated.intbox/make")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "generated.intbox/double")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "generated.intbox/bumped")
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "generated.intbox/make")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "generated.intbox/bumped")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "generated.intbox/bumped"
                "generated.intbox/double")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-module-macro-global-init-source) : String
  "(defmacro (global-module) : Module
  `(begin
    (module generated.global_init_user)
    (define answer : i64 (+ 40 2))
    (define (read-answer) : i64 answer)))
(import (global-module) as generated)
(define (main) : i64 (+ generated.answer (generated.read-answer)))")

(define (compiler-lower-module-macro-global-init-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-module-macro-global-init-source))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program globals functions _)
          (and
            (lower-test-global-list-has-name?
              globals
              "generated.global_init_user/answer")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "__global_init_generated.global_init_user/answer")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "generated.global_init_user/read-answer"))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
          (vec.push-ref! (&mut items) first)
          (if (= (vec.len (& items)) 1)
            (begin
              (vec.get (& items) 0 fallback)
              42)
            0))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 7) (user.make 0)))")

(define (compiler-lower-module-macro-stdlib-vector-import-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-module-macro-stdlib-vector-import-source))
    [(compiler_lower.ResultCompilerLower.Ok _ _) true]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-function-decl-count-wrapped-ok?) : bool
  (let
    [fn : compiler_ast_types.AstDecl
      (compiler_ast_types.ast-decl-def-fn-id
        (lower-test-generated-name-id "generated")
        (compiler_ast_types.ast-param-list-new)
        (compiler_ast_types.AstType.I64)
        (compiler_ast_types.ast-node-push
          (compiler_ast_types.AstExpr.Literal
            (compiler_ast_types.ast-lit-int 1))))]
    (and
      (=
        (compiler_lower.lower-function-decl-count
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-comptime-decl
              (compiler_ast_types.ast-decl-unsafe
                (owned_view.compiler-owned-shared-view fn)))
            (compiler_ast_types.ast-decl-list-new)))
        1)
      (=
        (compiler_lower.lower-function-decl-count
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-unsafe
              (compiler_ast_types.ast-decl-comptime-decl fn))
            (compiler_ast_types.ast-decl-list-new)))
        1))))

(define (compiler-lower-module-specialize-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64)
  (__tl_make-array T n))
(define (main) : (__tl_dyn-array i64)
  (alloc (type i64) 4))")

(define (compiler-lower-module-specialize-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "app.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "app.tl"
      (compiler_ast_types.ast-decl-path-list-new))))

(define (compiler-lower-module-specialize-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-module-specialize-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-specialize-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (>
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "__tl_specialized_alloc_type_i64_none")
                0)])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-c-abi-unsupported-aggregate-source)
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "big-use")
              1)
            ;; `Big` is a 16-byte all-integer struct, register-resident,
            ;; so building `(Big 1 2)` does not heap-allocate -- the value is
            ;; constructed in a register pair. The Win64 C ABI still requires the
            ;; >8 B aggregate to be passed BY REFERENCE, so exactly one tl_alloc
            ;; remains: the byref buffer the register pair is spilled into before
            ;; the call (down from two when construction also allocated).
            (>=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-windows-nested-small-aggregate-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-c-abi-windows-nested-small-aggregate-source)
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (=
            (lower-test-function-call-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "main"
              "outer-float-box-use")
            1)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-c-abi-windows-small-float-aggregate-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-c-abi-windows-small-float-aggregate-source)
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "float-pair-make")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "float-pair-use")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>=
              (lower-test-function-bitcast-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-extern-link-inputs-ok?
  [inputs : compiler_ast_types.AstExternLinkInputList]) : bool
  (and
    (= (compiler_ast_types.ast-extern-link-input-list-len (& inputs)) 3)
    (match (compiler_ast_types.ast-extern-link-input-list-get
      (& inputs)
      0
      (compiler_ast_types.ast-extern-link-input-fallback))
      [(compiler_ast_types.AstExternLinkInput.Lib lib) (string.eq lib "ffi")]
      [_ false])
    (match (compiler_ast_types.ast-extern-link-input-list-get
      (& inputs)
      1
      (compiler_ast_types.ast-extern-link-input-fallback))
      [(compiler_ast_types.AstExternLinkInput.Search dir)
        (string.eq dir "native")]
      [_ false])
    (match (compiler_ast_types.ast-extern-link-input-list-get
      (& inputs)
      2
      (compiler_ast_types.ast-extern-link-input-fallback))
      [(compiler_ast_types.AstExternLinkInput.Arg arg-value)
        (string.eq arg-value "-Wl,--as-needed")]
      [_ false])))

(define (compiler-lower-extern-link-metadata-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-extern-link-metadata-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ _ externs)
          (and
            (= externs.len 1)
            (match (compiler_ir_types.compiler-ir-extern-seq-ref externs 0)
              [(compiler_ir_types.CompilerIrExtern.Extern
                  name-id
                  name-id
                  name
                  _
                  abi
                  symbol-id
                  link-inputs
                  _)
                (and
                  (string.eq (ci.intern-str name-id) "ffi-add")
                  (string.eq name "ffi-add")
                  (string.eq (ci.intern-str symbol-id) "ffi_add")
                  (compiler_ast_types.ast-extern-abi-c? abi)
                  (compiler-lower-extern-link-inputs-ok? link-inputs))]))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-extern-value-fnptr-source) : String
  "(extern raw-value (:symbol \"tl_test_raw_value\") : i64)
(extern raw-fn (:symbol \"tl_test_raw_fn\") : (-> i64 i64))
(extern (direct-fn [x : i64]) : i64 (:symbol \"tl_test_direct_fn\"))
(define (main) : i64
  (let
    [copied : (-> i64 i64) raw-fn]
    (+ raw-value (+ (raw-fn 41) (+ (copied 40) (direct-fn 1))))))")

(define (compiler-lower-extern-value-fnptr-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-extern-value-fnptr-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "raw-fn")
              0)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "direct-fn")
              1)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0)
            (=
              (lower-test-function-indirect-c-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-c-abi-linux-tag-only-enum-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "status-next")
              2)
            (=
              (lower-test-function-indirect-c-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-c-abi-payload-enum-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "small-score")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "box-score")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "box-make")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "wide-make")
              1)
            (=
              (lower-test-function-indirect-c-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-c-abi-windows-enum-aggregate-source)
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "status-pick")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "small-score")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "wide-score")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "return-choice-make")
              1)
            (=
              (lower-test-function-indirect-c-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              4)
            (>=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              3))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source (compiler-lower-global-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program globals functions externs)
          (let
            [ok : bool true]
            (begin
              (if (= globals.len 3)
                unit
                (set! ok false))
              (if (= externs.len 1)
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name?
                (owned_view.compiler-owned-shared-view globals)
                "answer")
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name?
                (owned_view.compiler-owned-shared-view globals)
                "flag")
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name? globals "widened")
                unit
                (set! ok false))
              (if (= (compiler_ir_types.compiler-ir-extern-seq-count externs) 1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-global-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "answer")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source (compiler-lower-numeric-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "bits"
                  compiler_ir_types.CompilerIrBinOp.BitAnd)
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "bits"
                  compiler_ir_types.CompilerIrBinOp.BitOr)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "bits"
                  compiler_ir_types.CompilerIrBinOp.BitXor)
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "bits"
                  (compiler_ir_types.CompilerIrBinOp.Shl
                    (compiler_ast_types.AstType.I32)))
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "bits"
                  (compiler_ir_types.CompilerIrBinOp.Shr
                    (compiler_ast_types.AstType.I32)))
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "floaty"
                  compiler_ir_types.CompilerIrBinOp.Add)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "floaty"
                  compiler_ir_types.CompilerIrBinOp.Lt)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-cast-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "casts")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
    value.c))")

(define (compiler-lower-tail-aggregate-param-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big] [n : i64]) : i64
  (+ x.a n))
(define (step [x : Big] [n : i64]) : i64
  (if (= n 0)
    (finish x n)
    (step x (- n 1))))
(define (main) : i64
  (step (Big 39 1 2) 3))")

(define (compiler-lower-tail-aggregate-local-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big] [n : i64]) : i64
  (+ x.a n))
(define (step [n : i64]) : i64
  (finish (Big n (+ n 1) (+ n 2)) n))
(define (main) : i64 (step 39))")

(define (compiler-lower-tail-aggregate-reassigned-param-source) : String
  "(defstruct Big (a i64) (b i64) (c i64))
(define (finish [x : Big] [n : i64]) : i64
  (+ x.a n))
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
  x.b)
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
    value.c))")

(define (compiler-lower-tail-cleanup-source) : String
  "(define (finish [x : i64]) : i64 x)
(define (step [x : i64]) : i64
  (with-arena scratch
    (finish x)))
(define (main) : i64 (step 42))")

(define (compiler-lower-tail-simple-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-simple-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-context-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-context-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-operand-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-operand-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              0)
            (>
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-direct-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-direct-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-direct-stack-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-direct-stack-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step5"
                "finish5")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step5"
                "finish5")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-return-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-aggregate-return-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "step")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "step")
              0)
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-param-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-aggregate-param-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "step")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "step")
              0)
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-local-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-aggregate-local-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0)
            (>
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-aggregate-reassigned-param-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-aggregate-reassigned-param-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0)
            (>
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-indirect-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-indirect-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              1)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-indirect-aggregate-param-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-indirect-aggregate-param-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              1)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-indirect-aggregate-return-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-indirect-aggregate-return-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              1)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-tail-cleanup-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tail-cleanup-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0)
            (>
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
(define (lower-test-instr-i64-mov-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [want : i64]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Mov _ value _)
      (match value
        [(compiler_ir_types.CompilerIrValue.I64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-f64-mov-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [want : u64]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Mov _ value _)
      (match value
        [(compiler_ir_types.CompilerIrValue.F64 bits)
          (if (= bits want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-binop-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.BinOp _ _ _ _ _) 1]
    [(compiler_ir_types.CompilerIrInstr.UnOp _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-gep-offset-count
  [instr : compiler_ir_types.CompilerIrInstr]
  [want : i64]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Gep _ _ offset _)
      (match offset
        [(compiler_ir_types.CompilerIrValue.I64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-seq-i64-mov-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [want : i64]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-i64-mov-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-f64-mov-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [want : u64]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-f64-mov-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-binop-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-binop-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-gep-offset-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [want : i64]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-gep-offset-count
                (compiler_ir_types.compiler-ir-array-shared-view slots index)
                want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-i64-mov-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-i64-mov-count instrs want)
            (lower-test-blocks-i64-mov-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              want))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-i64-mov-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        want)]))

(define (lower-test-blocks-f64-mov-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [want : u64]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-f64-mov-count instrs want)
            (lower-test-blocks-f64-mov-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              want))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-f64-mov-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        want)]))

(define (lower-test-blocks-binop-count
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-binop-count instrs)
            (lower-test-blocks-binop-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-binop-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq))]))

(define (lower-test-blocks-gep-offset-count
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(compiler_ir_types.CompilerIrBlockList.Nil) 0]
    [(compiler_ir_types.CompilerIrBlockList.Cons block rest)
      (match block
        [(compiler_ir_types.CompilerIrBlock.Block _ instrs)
          (+
            (lower-test-instr-seq-gep-offset-count instrs want)
            (lower-test-blocks-gep-offset-count
              (compiler_ir_types.compiler-ir-box-shared-view rest)
              want))])]
    [(compiler_ir_types.CompilerIrBlockList.Array seq)
      (lower-test-blocks-gep-offset-count
        (compiler_ir_types.compiler-ir-block-seq-to-list seq)
        want)]))

(define (lower-test-function-i64-mov-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [want : i64]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) 0]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-i64-mov-count blocks want)])]))

(define (lower-test-function-f64-mov-count-bits
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [want : u64]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) 0]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-f64-mov-count blocks want)])]))

(define (lower-test-function-binop-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-binop-count blocks)])]))

(define (lower-test-function-gep-offset-count
  [funcs : compiler_ir_types.CompilerIrFunctionSeq]
  [name : String]
  [want : i64]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(LowerTestMaybeFunction.No) (- 0 1)]
    [(LowerTestMaybeFunction.Some func)
      (match func
        [(compiler_ir_types.CompilerIrFunction.Function _ _ _ _ blocks)
          (lower-test-blocks-gep-offset-count blocks want)])]))

(define (compiler-lower-comptime-fold-ok? [src : String] [want : i64]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-i64-mov-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                want)
              0)
            (=
              (lower-test-function-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-comptime-float-fold-ok?
  [src : String]
  [want : String]
  [ty : compiler_ast_types.AstType]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-f64-mov-count-bits
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                (compiler_lower.lower-float-literal-bits want ty))
              0)
            (=
              (lower-test-function-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-comptime-f64-fold-ok? [src : String] [want : String]) : bool
  (compiler-lower-comptime-float-fold-ok?
    src
    want
    (compiler_ast_types.AstType.F64)))

(define (compiler-lower-comptime-f32-fold-ok? [src : String] [want : String]) : bool
  (compiler-lower-comptime-float-fold-ok?
    src
    want
    (compiler_ast_types.AstType.F32)))

;; Tail-position scalar matches (`classify`/`flag-score`/`sign`) return directly
;; from every arm; the unit-typed match (`announce`) likewise needs no phi.
(define (compiler-lower-match-tail-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "classify")
              0)
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "flag-score")
              0)
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "sign")
              0)
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "announce")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; Tail-position enum matches also return directly from their arms. Payload
;; matches still need the loads that extract values from the enum storage.
(define (compiler-lower-enum-match-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score")
              0)
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "zero-call")
              0)
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "or-zero")
              0)
            (=
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "touch")
              0)
            (>
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score")
              1)
            (>
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "or-zero")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-two-variant-fallthrough-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-two-variant-fallthrough-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score"
                compiler_ir_types.CompilerIrBinOp.Eq)
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score"
                "tl_oob_abort")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-total-enum-provenance-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-total-enum-provenance-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>=
              (lower-test-function-total-enum-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "large")
              4)
            (=
              (lower-test-function-total-enum-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "small")
              0)
            ;; The outer two-arm match remains ordinary while its nested
            ;; six-variant match independently carries the total proof.
            (=
              (lower-test-function-total-enum-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "nested")
              4)
            (=
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "nested")
              6)
            ;; A catch-all makes the match exhaustive as source syntax, but it
            ;; does not prove that the compared tags cover the enum domain.
            (=
              (lower-test-function-total-enum-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "partial")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-enum-string-literal-payload-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-enum-string-literal-payload-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_string_eq")
              0)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "string-eq")
              0)
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "classify")
              2)
            (>
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "classify")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-borrowed-enum-match-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-borrowed-enum-match-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-phi-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score")
              0)
            (>
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score"
                "take")
              0)
            (>
              (lower-test-function-gep-offset-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "score"
                8)
              0)
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "slot-score")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-result-try-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::sum")
              1)
            (>
              (lower-test-function-return-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::sum")
              2)
            (>
              (lower-test-function-return-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::chain")
              1)
            (>
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::sum")
              3))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-option-try-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-option-try-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (>
              (lower-test-function-return-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-return-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source (compiler-lower-return-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (>
            (lower-test-function-return-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "main")
            1)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-return-with-arena-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-return-with-arena-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-return-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_region_reset")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-resource-with-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-resource-with-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::close-a")
              3)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::close-b")
              2)
            (>
              (lower-test-function-return-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2)
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-resource-with-nested-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-resource-with-nested-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::close-a")
              1)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::close-b")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-cleanup-struct-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-cleanup-struct-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                ".::cleanup-file-handle"
                ".::close-fd")
              1)
            (>
              (lower-test-function-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                ".::cleanup-file-handle")
              1)
            (>
              (lower-test-function-return-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-cleanup-struct-nested-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-cleanup-struct-nested-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "cleanup-file-handle"
                "close-fd")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "cleanup-buffered-file"
                "close-buffer")
              1)
            (=
              (lower-test-function-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "cleanup-buffered-file"
                "cleanup-file-handle")
              1)
            (lower-test-function-call-before?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "cleanup-buffered-file"
              "close-buffer"
              "cleanup-file-handle"))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-array-access-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "get")
              0)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "put")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-array-take-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-array-take-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>=
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "take-item")
              2)
            (>=
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "take-item")
              2)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "take-item")
              3)
            (>=
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "take-item")
              3))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-mut-ref-array-field-access-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-mut-ref-array-field-access-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "array-bag-handle")
              0)
            (>
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "len")
              0)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "get")
              0)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "put")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-fixed-array-access-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-bounds-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "get")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "get")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-bounds-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "put")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "get"
                  1)
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "put"
                  1)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "put")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-fixed-array-literal-stack-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-array-literal-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>=
              (lower-test-function-alloc-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              3)
            (=
              (lower-test-function-addr-of-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-fixed-array-aggregate-layout-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-fixed-array-aggregate-literal-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>
              (lower-test-function-gep-offset-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                16)
              0)
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-array-push-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_oob_abort")
              0)
            (>
              (lower-test-function-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "grow")
              0)
            (>
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "grow")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-make-array-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              1)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_oob_abort")
              0)
            (>=
              (lower-test-function-i64-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                (compiler_ir_types.CompilerIrBinOp.Le))
              2)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                (compiler_ir_types.CompilerIrBinOp.Le))
              (lower-test-function-i64-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                (compiler_ir_types.CompilerIrBinOp.Le)))
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_array_zero")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-make-array-init-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_array_fill8")
              1)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-dyn-array-literal-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-dyn-array-literal-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              2)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_array_zero")
              0)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              3))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-make-array-register-resident-zero-fill-shape-ok?) : bool
  ;; A one-word register-resident struct with an all-zero default takes the
  ;; tl_array_zero path (the aggregate zero-fill supersedes fill8 for
  ;; all-zero defaults; fill8 remains for non-zero defaults).
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-make-array-register-resident-fill8-source)
    (compiler_lower.CompilerLowerMode.InlineAggregates))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_array_zero")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_array_fill8")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-string-runtime-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_substring")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_string_concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_oob_abort")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "string.substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "string.append")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "string.concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "io.emit-string")
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "io.emit-str")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-string-concat-fusion-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-string-concat-fusion-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_string_concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_string_concat3")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_string_concat4")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_string_concat5")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "string.append")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-emit-string-stdlib-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-emit-string-stdlib-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-functions-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "io.emit-string")
              2)
            (=
              (lower-test-functions-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "io.emit-str")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-borrowed-str-param-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-borrowed-str-param-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "borrowed-score")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "borrowed-score"
                  1)
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "string-length")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-stdlib-hash-string-shape-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-stdlib-hash-string-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-stdlib-hash-string-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (let
                [name : String "stdlib/hash.tl::hash-string"]
                [ok : bool true]
                (begin
                  (if (=
                    (lower-test-function-call-count
                      (compiler_ir_types.compiler-ir-global-shared-view
                        functions)
                      (owned_view.compiler-owned-shared-view name)
                      "tl_hash_string")
                    0)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-bounds-count
                      (compiler_ir_types.compiler-ir-global-shared-view
                        functions)
                      (owned_view.compiler-owned-shared-view name))
                    0)
                    unit
                    (set! ok false))
                  (if (=
                    (lower-test-function-direct-call-count
                      (compiler_ir_types.compiler-ir-global-shared-view
                        functions)
                      "main"
                      name)
                    1)
                    unit
                    (set! ok false))
                  ok))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-reference-values-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-reference-return-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "ref-return"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "ref-id"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-return-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "ref-return")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-return-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "ref-id")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-reference-place-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-reference-place-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "borrow-pair"
                  0)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "borrow-tuple"
                  0)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-bounds-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "borrow-array")
                0)
                unit
                (set! ok false))
              (if (compiler-lower-reference-inline-struct-field-shape-ok?)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-reference-inline-struct-field-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-reference-inline-struct-field-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "take-inner")
              1)
            (=
              (lower-test-function-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-reference-nominal-aggregate-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-reference-struct-result-source))
    (compiler-lower-ok? (compiler-lower-reference-struct-multi-result-source))
    (compiler-lower-ok? (compiler-lower-reference-enum-result-source))))

(define (compiler-lower-string-shadow-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "string.string-length")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "string.append")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "string.string-ref")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "string.char-at")
              0)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_string_concat")
              0)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_oob_abort")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-function-value-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-function-value-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "apply1")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "apply1")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "apply1"
                  "f")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "shadow-inc")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "shadow-inc"
                  "inc")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-arg-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  "apply1"
                  "inc")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-function-value-contextual-init-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-function-value-contextual-init-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-noncapturing-lambda-value-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-noncapturing-lambda-value-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_get-fn_0"]
            (and
              (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
              (=
                (lower-test-function-return-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "get-fn"
                  (owned_view.compiler-owned-shared-view lambda-name))
                1)
              (>
                (lower-test-function-binop-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  lambda-name)
                0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-immediate-lambda-call-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-immediate-lambda-call-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            (and
              (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
              (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
              (=
                (lower-test-function-indirect-callee-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  (owned_view.compiler-owned-shared-view lambda-name))
                1)
              (=
                (lower-test-function-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  lambda-name)
                0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-unit-lambda-call-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-unit-lambda-call-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            (and
              (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
              (=
                (lower-test-function-indirect-unit-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
              (=
                (lower-test-function-indirect-callee-function-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main"
                  lambda-name)
                1)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-noncapturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-noncapturing-lambda-value-ok?)
    (compiler-lower-immediate-lambda-call-ok?)
    (compiler-lower-unit-lambda-call-ok?)))

(define (compiler-lower-capturing-lambda-scalar-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-scalar-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                3)
                unit
                (set! ok false))
              (if (>=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_alloc")
                2)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  lambda-name)
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-function-value-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-function-value-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [capturing-name : String "__tl_lambda_main_1"]
            [ok : bool true]
            (begin
              (if (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                3)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  (owned_view.compiler-owned-shared-view capturing-name))
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  capturing-name)
                2)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-fat-handle-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-fat-handle-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_alloc")
                3)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  lambda-name)
                2)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-aggregate-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-aggregate-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-tail-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_alloc")
                5)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-store-ptr-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                8)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  lambda-name)
                4)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-structural-return-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-structural-return-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (compiler_ir_types.compiler-ir-function-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              2)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "__tl_lambda_main_0")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-structural-sret-params-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-structural-sret-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (compiler_ir_types.compiler-ir-function-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              2)
            (string.eq
              (lower-test-function-param-name
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "__tl_lambda_main_0"
                0)
              "__tl_env")
            (string.eq
              (lower-test-function-param-name
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "__tl_lambda_main_0"
                1)
              "__sret"))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-shadow-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-shadow-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (compiler_ir_types.compiler-ir-function-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              2)
            (=
              (compiler_ir_types.compiler-ir-function-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              2)
            (=
              (lower-test-function-indirect-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-reference-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-reference-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  lambda-name)
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-reference-immediate-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-capturing-lambda-reference-immediate-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (=
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  lambda-name)
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-capturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-capturing-lambda-scalar-shape-ok?)
    (compiler-lower-capturing-lambda-function-value-shape-ok?)
    (compiler-lower-capturing-lambda-fat-handle-shape-ok?)
    (compiler-lower-capturing-lambda-aggregate-shape-ok?)
    (compiler-lower-capturing-lambda-structural-return-shape-ok?)
    (compiler-lower-capturing-lambda-structural-sret-params-ok?)
    (compiler-lower-capturing-lambda-shadow-shape-ok?)
    (compiler-lower-capturing-lambda-reference-shape-ok?)
    (compiler-lower-capturing-lambda-reference-immediate-shape-ok?)))

(define (compiler-lower-fs-status-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-fs-status-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_mkdir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_remove_file_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_remove_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_rename_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_read_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_read_dir")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_file_kind_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_file_size_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_file_size")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_fs_process_id")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_fs_current_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_fs_current_dir")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "mkdir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "remove-file-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "remove-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "rename-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "read-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "read-dir")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "file-kind-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "file-size-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "file-size")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "process-id")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "current-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "current-dir")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-region-source) : String
  "(define (string.int->string [value : i64]) : String
  \"41\")
(define (main) : i64
  (with-arena r
    (let
      [s : String (string.int->string 41)]
      (__tl_string_length s))))")

(define (compiler-lower-region-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source (compiler-lower-region-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_region_mark")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_region_reset")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-arena-source [src : String]) : String
  (str_cat.str-cat
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
(define (arena-raw-handle [arena : Arena]) : i64 arena.handle)
(define (arena-mark-raw-handle [mark : ArenaMark]) : i64 mark.handle)
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
    "(define (main) : (__tl_dyn-array String)
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch
      (let
        [items : (__tl_dyn-array String) (__tl_make-array String 2)]
        (begin
          (set! (array-ref items 0) (string.int->string 1))
          (set! (array-ref items 1) (string.int->string 2))
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
  (items (__tl_dyn-array String))
  (cell (Box String)))
(defenum EscapeResult
  (Ok EscapePayload)
  (None))
(define (main) : EscapeResult
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch
      (let
        [items : (__tl_dyn-array String) (__tl_make-array String 2)]
        (begin
          (set! (array-ref items 0) (string.int->string 1))
          (set! (array-ref items 1) (string.int->string 2))
          (EscapeResult.Ok
            (EscapePayload
              (string.int->string 3)
              items
              (box (string.int->string 4)))))))))"))

(define (compiler-lower-with-escape-arena-functions-shape-ok?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : bool
  (and
    (>=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_arena_current")
      3)
    (>=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_arena_set")
      4)
    (>
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_region_mark")
      0)
    (>
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_region_reset")
      0)))

(define (compiler-lower-with-escape-arena-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (compiler-lower-with-escape-arena-functions-shape-ok? functions)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-array-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-with-escape-array-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-escape-arena-shape-ok?
              (compiler-lower-with-escape-array-source))
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              1)
            (>
              (lower-test-functions-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-box-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-with-escape-box-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-escape-arena-shape-ok?
              (compiler-lower-with-escape-box-source))
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              0)
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_substring")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-owning-shape-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-with-escape-owning-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-escape-arena-functions-shape-ok?
              (compiler_ir_types.compiler-ir-global-shared-view functions))
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-escape-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-with-escape-arena-shape-ok?
        (compiler-lower-with-escape-scalar-source))
        unit
        (set! ok false))
      (if (match (compiler_lower.lower-compiler-source
        (compiler-lower-with-escape-string-source))
        [(compiler_lower.ResultCompilerLower.Ok program _)
          (match program
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (compiler-lower-with-escape-arena-shape-ok?
                  (compiler-lower-with-escape-string-source))
                (>
                  (lower-test-functions-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "tl_substring")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])
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
  (str_cat.str-cat
    "(define (substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
  (unsafe (string-from-bytes (ptr-offset src start) len)))
"
    (compiler-lower-with-scratch-string-source)))

(define (compiler-lower-runtime-substring-scratch-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (compiler_ast_types.ast-decl-path-list-new)))

(define (compiler-lower-runtime-substring-call-source) : String
  (str_cat.str-cat
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
  (str_cat.str-cat
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
  [items : (__tl_dyn-array i64)]
  [index : i64]
  [delta : i64]) : i64 (:symbol \"tl_atomic_i64_fetch_add\"))
(define (main [items : (__tl_dyn-array i64)]) : i64
  (atomic-i64-fetch-add! items 0 1))")

(define (compiler-lower-runtime-atomic-reachable-paths) : compiler_ast_types.AstDeclPathList
  (compiler_ast_types.ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (compiler_ast_types.ast-decl-root-path-cons
      "stdlib/runtime.tl"
      (compiler_ast_types.ast-decl-root-path-cons
        "stdlib/atomic.tl"
        (compiler_ast_types.ast-decl-root-path-cons
          "app.tl"
          (compiler_ast_types.ast-decl-path-list-new))))))

(define (compiler-lower-with-scratch-owning-source) : String
  (compiler-lower-with-arena-source
    "(defstruct ScratchPayload
  (name String)
  (items (__tl_dyn-array String))
  (cell (Box String)))
(defenum ScratchResult
  (Ok ScratchPayload)
  (None))
(define (main) : ScratchResult
  (with-scratch
    (let
      [items : (__tl_dyn-array String) (__tl_make-array String 2)]
        (begin
          (set! (array-ref items 0) (string.int->string 1))
          (set! (array-ref items 1) (string.int->string 2))
        (ScratchResult.Ok
          (ScratchPayload
            (string.int->string 3)
            items
            (box (string.int->string 4))))))))"))

(define (compiler-lower-with-scratch-arena-functions-shape-ok?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : bool
  (and
    (>=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_arena_current")
      3)
    (>=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_arena_set")
      3)
    (>=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_arena_make")
      1)
    (>=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_arena_destroy")
      1)
    (=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_region_mark")
      0)
    (=
      (lower-test-functions-call-count
        (compiler_ir_types.compiler-ir-global-shared-view functions)
        "tl_region_reset")
      0)))

(define (compiler-lower-with-scratch-arena-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (compiler-lower-with-scratch-arena-functions-shape-ok? functions)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-scratch-owning-shape-ok?) : bool
  (match (compiler-lower-clone-source-with-prelude
    (compiler-lower-with-scratch-owning-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (compiler-lower-with-scratch-arena-functions-shape-ok?
              (compiler_ir_types.compiler-ir-global-shared-view functions))
            (>
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-with-scratch-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-with-scratch-arena-shape-ok?
        (compiler-lower-with-scratch-scalar-source))
        unit
        (set! ok false))
      (if (match (compiler_lower.lower-compiler-source
        (compiler-lower-with-scratch-string-source))
        [(compiler_lower.ResultCompilerLower.Ok program _)
          (match program
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (compiler-lower-with-scratch-arena-shape-ok?
                  (compiler-lower-with-scratch-string-source))
                (>
                  (lower-test-functions-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "tl_substring")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      (if (compiler-lower-with-scratch-owning-shape-ok?)
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-runtime-substring-scratch-reachable-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-runtime-substring-scratch-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-substring-scratch-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "stdlib/runtime.tl::substring")
                (>
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "tl_substring")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-runtime-substring-call-reachable-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-runtime-substring-call-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-substring-scratch-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "stdlib/runtime.tl::substring")
                (>
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "tl_substring")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-runtime-substring-capturing-lambda-reachable-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-runtime-substring-capturing-lambda-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-substring-scratch-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "stdlib/runtime.tl::substring")
                (>
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "tl_substring")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-runtime-atomic-reachable-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-runtime-atomic-reachable-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-runtime-atomic-reachable-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (lower-test-function-defined?
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "stdlib/runtime.tl::atomic-i64-fetch-add-ptr!")
                (not
                  (lower-test-function-defined?
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "stdlib/runtime.tl::atomic-i64-load-ptr"))
                (>
                  (lower-test-function-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "main"
                    "tl_atomic_i64_fetch_add_ptr")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-tls-current-arena-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_tls_current_arena_load")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_tls_current_arena_store")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-in-arena-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (match (compiler_lower.lower-compiler-source
        (compiler-lower-in-arena-source))
        [(compiler_lower.ResultCompilerLower.Ok program _)
          (match program
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (>=
                  (lower-test-functions-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "tl_arena_current")
                  1)
                (>=
                  (lower-test-functions-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "tl_arena_set")
                  2))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      (if (match (compiler_lower.lower-compiler-source
        (compiler-lower-in-arena-return-source))
        [(compiler_lower.ResultCompilerLower.Ok program _)
          (match program
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (>=
                  (lower-test-functions-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "tl_arena_current")
                  1)
                (>=
                  (lower-test-functions-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "tl_arena_set")
                  3)
                (>
                  (lower-test-functions-return-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions))
                  1))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-repr-c-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source (compiler-lower-repr-c-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>
              (lower-test-function-gep-offset-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                4)
              0)
            (>
              (lower-test-function-gep-offset-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                12)
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; `foreach` scalar lowering: a foreach `main` lowers to a loop, so its
;; body holds at least the guard branch (`i < end`) and two binops (the `<`
;; guard and the `+ 1` increment).
(define (compiler-lower-foreach-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0)
            (>
              (lower-test-function-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-foreach-map-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [b : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-foreach-borrowed-array-map-source) : String
  "(define (fill [a : (& a (__tl_dyn-array i64))] [b : (& b (__tl_dyn-array i64))] [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i32-source) : String
  "(define (fill [a : (__tl_dyn-array i32)] [b : (__tl_dyn-array i32)] [out : (__tl_dyn-array i32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u64-source) : String
  "(define (fill [a : (__tl_dyn-array u64)] [b : (__tl_dyn-array u64)] [out : (__tl_dyn-array u64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u32-source) : String
  "(define (fill [a : (__tl_dyn-array u32)] [b : (__tl_dyn-array u32)] [out : (__tl_dyn-array u32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i16-source) : String
  "(define (fill [a : (__tl_dyn-array i16)] [b : (__tl_dyn-array i16)] [out : (__tl_dyn-array i16)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u16-source) : String
  "(define (fill [a : (__tl_dyn-array u16)] [b : (__tl_dyn-array u16)] [out : (__tl_dyn-array u16)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-f64-source) : String
  "(define (fill [a : (__tl_dyn-array f64)] [b : (__tl_dyn-array f64)] [out : (__tl_dyn-array f64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-f32-source) : String
  "(define (fill [a : (__tl_dyn-array f32)] [b : (__tl_dyn-array f32)] [out : (__tl_dyn-array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i8-source) : String
  "(define (fill [a : (__tl_dyn-array i8)] [b : (__tl_dyn-array i8)] [out : (__tl_dyn-array i8)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-u8-source) : String
  "(define (fill [a : (__tl_dyn-array u8)] [b : (__tl_dyn-array u8)] [out : (__tl_dyn-array u8)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-uniform-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [b : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64] [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-i32-source) : String
  "(define (fill [a : (__tl_dyn-array i32)] [b : (__tl_dyn-array i32)] [out : (__tl_dyn-array i32)] [n : i64] [r : i32]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-u64-source) : String
  "(define (fill [a : (__tl_dyn-array u64)] [b : (__tl_dyn-array u64)] [out : (__tl_dyn-array u64)] [n : i64] [r : u64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (* (array-ref b i) r)) (cast 7 : u64)))))")

(define (compiler-lower-avx2-foreach-map-uniform-u32-source) : String
  "(define (fill [a : (__tl_dyn-array u32)] [b : (__tl_dyn-array u32)] [out : (__tl_dyn-array u32)] [n : i64] [r : u32]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (* (array-ref b i) r)) (cast 7 : u32)))))")

(define (compiler-lower-avx2-foreach-map-uniform-i16-source) : String
  "(define (fill [a : (__tl_dyn-array i16)] [b : (__tl_dyn-array i16)] [out : (__tl_dyn-array i16)] [n : i64] [r : i16]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-u16-source) : String
  "(define (fill [a : (__tl_dyn-array u16)] [b : (__tl_dyn-array u16)] [out : (__tl_dyn-array u16)] [n : i64] [r : u16]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-f64-source) : String
  "(define (fill [a : (__tl_dyn-array f64)] [b : (__tl_dyn-array f64)] [out : (__tl_dyn-array f64)] [n : i64] [r : f64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-f32-source) : String
  "(define (fill [a : (__tl_dyn-array f32)] [b : (__tl_dyn-array f32)] [out : (__tl_dyn-array f32)] [n : i64] [r : f32]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-i8-source) : String
  "(define (fill [a : (__tl_dyn-array i8)] [b : (__tl_dyn-array i8)] [out : (__tl_dyn-array i8)] [n : i64] [r : i8]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-map-uniform-u8-source) : String
  "(define (fill [a : (__tl_dyn-array u8)] [b : (__tl_dyn-array u8)] [out : (__tl_dyn-array u8)] [n : i64] [r : u8]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (array-ref a i) (array-ref b i)) r))))")

(define (compiler-lower-avx2-foreach-zip-uniform-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [b : (__tl_dyn-array i64)] [c : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64] [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (+ (* (array-ref a i) (array-ref b i)) (array-ref c i)) r))))")

(define (compiler-lower-spmd-broadcast-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64] [lane : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-broadcast (array-ref a i) lane))))")

(define (compiler-lower-spmd-broadcast-u64-source) : String
  "(define (fill [a : (__tl_dyn-array u64)] [out : (__tl_dyn-array u64)] [n : i64] [lane : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-broadcast (array-ref a i) lane))))")

(define (compiler-lower-spmd-broadcast-u32-source) : String
  "(define (fill [a : (__tl_dyn-array u32)] [out : (__tl_dyn-array u32)] [n : i64] [lane : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-broadcast (array-ref a i) lane))))")

(define (compiler-lower-spmd-shuffle-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-shuffle (array-ref a i) i))))")

(define (compiler-lower-avx2-foreach-scalar-fallback-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a (+ i 1)) 1))))")

(define (compiler-lower-avx2-foreach-map-source-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx2))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 2)
              (= binop-count 2)
              (= store-count 1)
              (= pred-load-count 2)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count 8)
              (> tail-store-count 0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (compiler_ast_types.AstType.I64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-foreach-borrowed-array-map-source)
      (compiler_ast_types.AstType.I64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i32-source)
      (compiler_ast_types.AstType.I32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u64-source)
      (compiler_ast_types.AstType.U64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u32-source)
      (compiler_ast_types.AstType.U32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i16-source)
      (compiler_ast_types.AstType.I16)
      16)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u16-source)
      (compiler_ast_types.AstType.U16)
      16)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f64-source)
      (compiler_ast_types.AstType.F64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f32-source)
      (compiler_ast_types.AstType.F32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i8-source)
      (compiler_ast_types.AstType.I8)
      32)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u8-source)
      (compiler_ast_types.AstType.U8)
      32)))

(define (compiler-lower-avx2-foreach-uniform-source-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]
  [want-loads : i64]
  [want-binops : i64]
  [want-shapes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx2))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count want-loads)
              (= binop-count (* want-binops 2))
              (= store-count 1)
              (= pred-load-count want-loads)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count (* want-shapes 2))
              (> tail-store-count 0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-foreach-uniform-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-source)
      (compiler_ast_types.AstType.I64)
      4
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i32-source)
      (compiler_ast_types.AstType.I32)
      8
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u64-source)
      (compiler_ast_types.AstType.U64)
      4
      2
      3
      8)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u32-source)
      (compiler_ast_types.AstType.U32)
      8
      2
      3
      8)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i16-source)
      (compiler_ast_types.AstType.I16)
      16
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u16-source)
      (compiler_ast_types.AstType.U16)
      16
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f64-source)
      (compiler_ast_types.AstType.F64)
      4
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f32-source)
      (compiler_ast_types.AstType.F32)
      8
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i8-source)
      (compiler_ast_types.AstType.I8)
      32
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u8-source)
      (compiler_ast_types.AstType.U8)
      32
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-zip-uniform-source)
      (compiler_ast_types.AstType.I64)
      4
      3
      3
      8)))

(define (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx2))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0)
            (=
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              1)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                elem-ty)
              2)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-broadcast-avx2-shape-ok?) : bool
  (and
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-source)
      (compiler_ast_types.AstType.I64)
      4)
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-u64-source)
      (compiler_ast_types.AstType.U64)
      4)
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-u32-source)
      (compiler_ast_types.AstType.U32)
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
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 2)
              (= binop-count 2)
              (= store-count 1)
              (= pred-load-count 2)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count 8)
              (> tail-store-count 0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (compiler_ast_types.AstType.I64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-foreach-borrowed-array-map-source)
      (compiler_ast_types.AstType.I64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i32-source)
      (compiler_ast_types.AstType.I32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u64-source)
      (compiler_ast_types.AstType.U64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u32-source)
      (compiler_ast_types.AstType.U32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i16-source)
      (compiler_ast_types.AstType.I16)
      32)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u16-source)
      (compiler_ast_types.AstType.U16)
      32)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f64-source)
      (compiler_ast_types.AstType.F64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f32-source)
      (compiler_ast_types.AstType.F32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i8-source)
      (compiler_ast_types.AstType.I8)
      64)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u8-source)
      (compiler_ast_types.AstType.U8)
      64)))

(define (compiler-lower-avx512-foreach-uniform-source-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]
  [want-loads : i64]
  [want-pred-loads : i64]
  [want-binops : i64]
  [want-shapes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count want-loads)
              (= binop-count want-binops)
              (= store-count 1)
              (= pred-load-count want-pred-loads)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count want-shapes)
              (> tail-store-count 0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-foreach-uniform-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-source)
      (compiler_ast_types.AstType.I64)
      8
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i32-source)
      (compiler_ast_types.AstType.I32)
      16
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u64-source)
      (compiler_ast_types.AstType.U64)
      8
      2
      2
      6
      16)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u32-source)
      (compiler_ast_types.AstType.U32)
      16
      2
      2
      6
      16)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i16-source)
      (compiler_ast_types.AstType.I16)
      32
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u16-source)
      (compiler_ast_types.AstType.U16)
      32
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f64-source)
      (compiler_ast_types.AstType.F64)
      8
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f32-source)
      (compiler_ast_types.AstType.F32)
      16
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i8-source)
      (compiler_ast_types.AstType.I8)
      64
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u8-source)
      (compiler_ast_types.AstType.U8)
      64
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-zip-uniform-source)
      (compiler_ast_types.AstType.I64)
      8
      3
      3
      6
      16)))

(define (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0)
            (=
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              1)
            (=
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              1)
            (=
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              1)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                elem-ty)
              4)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-broadcast-avx512-shape-ok?) : bool
  (and
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-source)
      (compiler_ast_types.AstType.I64)
      8)
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-u64-source)
      (compiler_ast_types.AstType.U64)
      8)
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-u32-source)
      (compiler_ast_types.AstType.U32)
      16)))

(define (compiler-lower-avx512-masked-if-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (set! (array-ref out i) 0)
      (set! (array-ref out i) (+ (array-ref xs i) 1)))))")

(define (compiler-lower-avx512-masked-if-offset-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs (+ i 1)) 0)
      (set! (array-ref out (+ i 1)) 0)
      (set! (array-ref out (+ i 1)) (+ (array-ref xs (+ i 1)) 1)))))")

(define (compiler-lower-avx512-masked-if-index-value-source) : String
  "(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 6)
      (set! (array-ref out i) i)
      (set! (array-ref out i) (+ i 1)))))")

(define (compiler-lower-avx512-masked-if-index-mod-source) : String
  "(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (= (% i 2) 0)
      (set! (array-ref out i) (+ i 10))
      (set! (array-ref out i) (+ i 100)))))")

(define (compiler-lower-avx512-masked-if-value-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (if (< (array-ref xs i) 0)
        0
        (+ (array-ref xs i) 1)))))")

(define (compiler-lower-masked-if-bitand-value-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64] [bias : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (if (= (bit-and (array-ref xs i) 1) 1)
        (+ (array-ref xs i) bias)
        (- (array-ref xs i) bias)))))")

(define (compiler-lower-masked-load-cache-let-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64] [bias : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (set! (array-ref out i) (if (= (bit-and x 1) 1)
          (+ x bias)
          (- x bias))))))")

(define (compiler-lower-masked-load-cache-sibling-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (if (< i 4)
        (+ (array-ref xs i) 1)
        (- (array-ref xs i) 1)))))")

(define (compiler-lower-masked-load-cache-mutation-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (if (= (bit-and (array-ref xs i) 1) 1)
        (begin
          (set! (array-ref xs i) (+ (array-ref xs i) 7))
          (array-ref xs i))
        (array-ref xs i)))))")

(define (compiler-lower-masked-load-cache-nested-if-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (if (< (array-ref xs i) 0)
        (- (array-ref xs i) 1)
        (if (= (array-ref xs i) 0)
          0
          (+ (array-ref xs i) 1))))))")

(define (compiler-lower-masked-load-cache-match-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i)
      (match (bit-and (array-ref xs i) 1)
        [0 (+ (array-ref xs i) 1)]
        [_ (- (array-ref xs i) 1)]))))")

(define (compiler-lower-masked-load-cache-counts-ok?
  [src : String]
  [mode : compiler_lower.CompilerLowerMode]
  [vector-loads : i64]
  [predicated-loads : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode src mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [actual-vector-loads : i64
              (lower-test-function-vector-load-count
                (owned_view.compiler-owned-shared-view functions)
                "fill")]
            [actual-predicated-loads : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (and
              (= actual-vector-loads vector-loads)
              (= actual-predicated-loads predicated-loads)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-preheader-cache-counts-ok?
  [mode : compiler_lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-masked-load-cache-let-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            ;; The condition's repeated literal and both arms' shared bias are
            ;; each materialized once for the full body and vector tail.
            (=
              (lower-test-function-splat-shape-count
                (owned_view.compiler-owned-shared-view functions)
                "fill"
                lanes
                (compiler_ast_types.AstType.I64))
              2)
            ;; Dynamic-array slot-0 loads live in entry, never in either vector
            ;; body. The scalar tail deliberately retains its checked reloads.
            (=
              (lower-test-function-label-load-count
                (owned_view.compiler-owned-shared-view functions)
                "fill"
                "entry")
              4)
            (=
              (lower-test-function-label-load-count
                (owned_view.compiler-owned-shared-view functions)
                "fill"
                "foreach_avx512_mask_body.1")
              0)
            (=
              (lower-test-function-label-load-count
                functions
                "fill"
                "foreach_tail_mask.4")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-preheader-reassign-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (set! xs out)
      (set! (array-ref out i) (array-ref xs i)))))")

(define (compiler-lower-masked-preheader-grow-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 4)
      (__tl_array-push! xs i)
      (set! (array-ref out i) (array-ref xs i)))))")

(define (compiler-lower-masked-preheader-windows-avx2-cap-source) : String
  "(define (fill
    [xs : (__tl_dyn-array i32)]
    [out : (__tl_dyn-array i32)]
    [n : i64]
    [a : i32]
    [b : i32]
    [c : i32]
    [d : i32]
    [e : i32]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (if (< (array-ref xs i) a)
      (+ (+ (+ (+ (array-ref xs i) b) c) d) e)
      (- (array-ref xs i) a)))))")

(define (compiler-lower-masked-preheader-windows-avx2-cap-ok?) : bool
  (and
    (match (compiler_lower.lower-compiler-source-with-mode
      (compiler-lower-masked-preheader-windows-avx2-cap-source)
      (compiler_lower.CompilerLowerMode.Avx2))
      [(compiler_lower.ResultCompilerLower.Ok program _)
        (match program
          [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
            (=
              (lower-test-function-splat-shape-count
                functions
                "fill"
                8
                (compiler_ast_types.AstType.I32))
              5)])]
      [(compiler_lower.ResultCompilerLower.Err _) false])
    (match (compiler_lower.lower-compiler-source-with-mode
      (compiler-lower-masked-preheader-windows-avx2-cap-source)
      (compiler_lower.CompilerLowerMode.LinuxAvx2))
      [(compiler_lower.ResultCompilerLower.Ok program _)
        (match program
          [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
            ;; All five unique source splats are shared by the full and tail
            ;; vector bodies now that the allocator handles their live ranges.
            (=
              (lower-test-function-splat-shape-count
                functions
                "fill"
                8
                (compiler_ast_types.AstType.I32))
              5)])]
      [(compiler_lower.ResultCompilerLower.Err _) false])
    (match (compiler_lower.lower-compiler-source-with-mode
      (compiler-lower-masked-preheader-windows-avx2-cap-source)
      (compiler_lower.CompilerLowerMode.WindowsAvx2))
      [(compiler_lower.ResultCompilerLower.Ok program _)
        (match program
          [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
            ;; Windows shares the same five unique source splats now that
            ;; full-width call volatility and spill scratch are modeled.
            (=
              (lower-test-function-splat-shape-count
                functions
                "fill"
                8
                (compiler_ast_types.AstType.I32))
              5)])]
      [(compiler_lower.ResultCompilerLower.Err _) false])))

(define (compiler-lower-masked-preheader-unsafe-rejected?
  [mode : compiler_lower.CompilerLowerMode]) : bool
  (and
    (compiler-lower-mode-error-ok?
      (compiler-lower-masked-preheader-reassign-source)
      mode
      "typecheck: foreach cannot set binding declared outside foreach")
    (compiler-lower-mode-error-ok?
      (compiler-lower-masked-preheader-grow-source)
      mode
      "typecheck: SPMD masked if does not support side effects other than contiguous array writes inside masked branches")))

(define (compiler-lower-masked-preheader-cache-tests-ok?) : bool
  (and
    (compiler-lower-masked-preheader-cache-counts-ok?
      (compiler_lower.CompilerLowerMode.Avx2)
      4)
    (compiler-lower-masked-preheader-cache-counts-ok?
      (compiler_lower.CompilerLowerMode.Avx512)
      8)
    (compiler-lower-masked-preheader-unsafe-rejected?
      (compiler_lower.CompilerLowerMode.Avx2))
    (compiler-lower-masked-preheader-unsafe-rejected?
      (compiler_lower.CompilerLowerMode.Avx512))
    (compiler-lower-masked-preheader-windows-avx2-cap-ok?)))

(define (compiler-lower-masked-load-cache-tests-ok?) : bool
  (and
    ;; Repeated spelling and an explicit lane-local binding each issue one
    ;; load in the full body and one parent-mask load in the tail body.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-if-bitand-value-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-let-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-if-bitand-value-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-let-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      1
      1)
    ;; A load first evaluated under one arm cannot feed its sibling: each of
    ;; the full and tail bodies needs one load for each arm.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-sibling-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      0
      4)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-sibling-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      0
      4)
    ;; A store retires the parent value. The post-store read and the sibling
    ;; read must both reload in each body.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-mutation-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      1
      5)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-mutation-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      1
      5)
    ;; Dominance is transitive through nested if and scalar-lane match masks.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-nested-if-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-nested-if-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-match-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-match-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      1
      1)))

(define (compiler-lower-masked-if-bitwise-value-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (set! (array-ref out i) (if (< x 8)
          (bit-or 1 x)
          (match (bit-and x 3)
            [0 (bit-xor x 3)]
            [_ (bit-or (bit-xor x 5) 2)]))))))")

(define (compiler-lower-masked-if-shift-value-source) : String
  "(define (fill
  [xs : (__tl_dyn-array i64)]
  [counts : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      [count : i64 (array-ref counts i)]
      (set! (array-ref out i) (if (< x 0)
          (shr x count)
          (shl x count))))))")

(define (compiler-lower-masked-if-narrow-shift-source) : String
  "(define (fill
  [xs : (__tl_dyn-array i16)]
  [counts : (__tl_dyn-array i16)]
  [out : (__tl_dyn-array i16)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i16 (array-ref xs i)]
      [count : i16 (array-ref counts i)]
      (set! (array-ref out i) (if (< x 0)
          (shr x count)
          (shl x count))))))")

(define (compiler-lower-avx512-masked-if-nested-source) : String
  "(define (fill [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (if (< x 0)
        (set! (array-ref out i) -10)
        (if (= x 0)
          (set! (array-ref out i) 0)
          (if (< x 6)
            (set! (array-ref out i) 6)
            (set! (array-ref out i) 12)))))))")

(define (compiler-lower-avx512-masked-if-source-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 0)
              (>= binop-count 2)
              (>= pred-load-count 3)
              (>= pred-store-count 4)
              (= tail-mask-count 1)
              (> tail-store-count 0)
              true))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-masked-if-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-source)))

(define (compiler-lower-avx512-masked-if-offset-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-offset-source)))

(define (compiler-lower-avx512-masked-if-index-value-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-index-value-source)
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                8
                (compiler_ast_types.AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 0)
              (= store-count 0)
              (>= binop-count 3)
              (= pred-load-count 0)
              (>= pred-store-count 4)
              (= tail-mask-count 1)
              (>= shape-count 5)
              (> tail-store-count 0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-masked-if-index-mod-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-index-mod-source)
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                8
                (compiler_ast_types.AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 0)
              (= store-count 0)
              (>= binop-count 6)
              (= pred-load-count 0)
              (>= pred-store-count 4)
              (= tail-mask-count 1)
              (>= shape-count 9)
              (> tail-store-count 0)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-masked-if-value-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-value-source)
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [select-count : i64
              (lower-test-function-select-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                8
                (compiler_ast_types.AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 1)
              (>= binop-count 2)
              (= pred-load-count 1)
              (= pred-store-count 1)
              (= select-count 2)
              (= tail-mask-count 1)
              (and (>= shape-count 7) (> tail-store-count 0))))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-if-bitand-value-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-masked-if-bitand-value-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64
              (compiler_lower.lower-simd-lanes-for-elem
                mode
                (compiler_ast_types.AstType.I64))]
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [select-count : i64
              (lower-test-function-select-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                (compiler_ast_types.AstType.I64))]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 1)
              (>= binop-count 6)
              (= pred-load-count 1)
              (= pred-store-count 1)
              (= select-count 2)
              (= tail-mask-count 1)
              ;; One uniform source splat now serves both vector paths from the
              ;; preheader, reducing this shape floor by one.
              (>= shape-count 14)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-if-bitwise-value-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-masked-if-bitwise-value-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64
              (compiler_lower.lower-simd-lanes-for-elem
                mode
                (compiler_ast_types.AstType.I64))]
            [binop-count : i64
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [bit-or-count : i64
              (lower-test-function-vector-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.BitOr))]
            [bit-xor-count : i64
              (lower-test-function-vector-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.BitXor))]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [select-count : i64
              (lower-test-function-select-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                (compiler_ast_types.AstType.I64))]
            (and
              (>= binop-count 8)
              (>= bit-or-count 4)
              (>= bit-xor-count 4)
              (>= pred-load-count 1)
              (= pred-store-count 1)
              (>= select-count 4)
              (>= shape-count 16)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-masked-if-shift-value-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-masked-if-shift-value-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64
              (compiler_lower.lower-simd-lanes-for-elem
                mode
                (compiler_ast_types.AstType.I64))]
            [shl-count : i64
              (lower-test-function-vector-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.Shl
                  (compiler_ast_types.AstType.I64)))]
            [shr-count : i64
              (lower-test-function-vector-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.Shr
                  (compiler_ast_types.AstType.I64)))]
            [abort-count : i64
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_shift_abort")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                (compiler_ast_types.AstType.I64))]
            (begin
              (unless
                (= shl-count 2)
                (io.panic "lower: masked shift shl IR count mismatch"))
              (unless
                (= shr-count 2)
                (io.panic "lower: masked shift shr IR count mismatch"))
              (unless
                (= abort-count 4)
                (io.panic "lower: masked shift abort call count mismatch"))
              (unless
                (>= shape-count 20)
                (io.panic "lower: masked shift vector shape count mismatch"))
              true))])]
    [(compiler_lower.ResultCompilerLower.Err diag)
      (io.panic
        (compiler_diagnostic.compiler-diagnostic-message (__tl-box-place diag)))]))

(define (compiler-lower-masked-if-narrow-shift-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-masked-if-narrow-shift-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [lanes : i64
              (compiler_lower.lower-simd-lanes-for-elem
                mode
                (compiler_ast_types.AstType.I16))]
            [shl-count : i64
              (lower-test-function-vector-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.Shl
                  (compiler_ast_types.AstType.I16)))]
            [shr-count : i64
              (lower-test-function-vector-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.Shr
                  (compiler_ast_types.AstType.I16)))]
            [abort-count : i64
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_shift_abort")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                lanes
                (compiler_ast_types.AstType.I16))]
            (begin
              (unless
                (= shl-count 2)
                (io.panic
                  (str_cat.str-cat
                    "lower: narrow masked shift shl IR count mismatch: "
                    (string.int->string shl-count))))
              (unless
                (= shr-count 2)
                (io.panic
                  (str_cat.str-cat
                    "lower: narrow masked shift shr IR count mismatch: "
                    (string.int->string shr-count))))
              (unless
                (= abort-count 4)
                (io.panic
                  (str_cat.str-cat
                    "lower: narrow masked shift abort call count mismatch: "
                    (string.int->string abort-count))))
              (unless
                (>= shape-count 10)
                (io.panic
                  (str_cat.str-cat
                    "lower: narrow masked shift vector shape count mismatch: "
                    (string.int->string shape-count))))
              true))])]
    [(compiler_lower.ResultCompilerLower.Err diag)
      (io.panic
        (compiler_diagnostic.compiler-diagnostic-message (__tl-box-place diag)))]))

(define (compiler-lower-masked-shift-tests-ok?) : bool
  (begin
    (unless
      (compiler-lower-masked-if-shift-value-shape-ok?
        (compiler_lower.CompilerLowerMode.Avx2))
      (io.panic "lower: AVX2 masked shift shape mismatch"))
    (unless
      (compiler-lower-masked-if-shift-value-shape-ok?
        (compiler_lower.CompilerLowerMode.Avx512))
      (io.panic "lower: AVX-512 masked shift shape mismatch"))
    (unless
      (compiler-lower-masked-if-narrow-shift-shape-ok?
        (compiler_lower.CompilerLowerMode.Avx2))
      (io.panic "lower: AVX2 narrow masked shift shape mismatch"))
    (unless
      (compiler-lower-masked-if-narrow-shift-shape-ok?
        (compiler_lower.CompilerLowerMode.Avx512))
      (io.panic "lower: AVX-512 narrow masked shift shape mismatch"))
    true))

(define (compiler-lower-avx512-masked-if-nested-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-avx512-masked-if-nested-source)
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                8
                (compiler_ast_types.AstType.I64))]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (compiler-lower-and8
              (= load-count 1)
              (= store-count 0)
              (> pred-load-count 0)
              (> pred-store-count 0)
              (= tail-mask-count 1)
              (> shape-count 0)
              (> tail-store-count 0)
              true))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx2-masked-if-source-shape-ok? [src : String]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx2))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [select-count : i64
              (lower-test-function-select-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")]
            (and
              (>
                (+
                  (+ (+ load-count store-count) pred-load-count)
                  (+ pred-store-count select-count))
                0)
              (= tail-mask-count 1)))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-avx2-foreach-map-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (=
            (lower-test-function-vector-load-count
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "fill")
            0)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-lane-array-source) : String
  "(define (fill [zeros : (__tl_dyn-array f32)] [out : (__tl_dyn-array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (array-ref zeros (program-index)))))")

(define (compiler-lower-spmd-lane-array-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]
  [predicated? : bool]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-spmd-lane-array-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0)
            (>
              (lower-test-function-vector-store-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0)
            (if predicated?
              (and
                (>
                  (lower-test-function-predicated-load-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "fill")
                  0)
                (>
                  (lower-test-function-predicated-store-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "fill")
                  0))
              true))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-simd-foreach-fallback-diagnostic-ok?) : bool
  (and
    (compiler-lower-mode-error-ok?
      (compiler-lower-avx2-foreach-scalar-fallback-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      (compiler_lower.lower-simd-foreach-fallback-diagnostic))
    (compiler-lower-mode-error-ok?
      (compiler-lower-avx2-foreach-scalar-fallback-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      (compiler_lower.lower-simd-foreach-fallback-diagnostic))))

(define (compiler-lower-spmd-shuffle-lowering-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-spmd-shuffle-source))
    (compiler-lower-mode-error-ok?
      (compiler-lower-spmd-shuffle-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      (compiler_lower.lower-spmd-shuffle-diagnostic))
    (compiler-lower-mode-error-ok?
      (compiler-lower-spmd-shuffle-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      (compiler_lower.lower-spmd-shuffle-diagnostic))))

(define (compiler-lower-spmd-out-of-line-value-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (heavy i))))")

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
(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 4)
      (set! (array-ref out i) (heavy i))
      (set! (array-ref out i) 0))))")

(define (compiler-lower-spmd-source-call-count
  [src : String]
  [mode : compiler_lower.CompilerLowerMode]) : i64
  (match (compiler_lower.lower-compiler-source-with-mode src mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (lower-test-function-spmd-call-count
            (compiler_ir_types.compiler-ir-global-shared-view functions)
            "fill")])]
    [(compiler_lower.ResultCompilerLower.Err _) (- 0 1)]))

(define (compiler-lower-spmd-source-function-count
  [src : String]
  [mode : compiler_lower.CompilerLowerMode]) : i64
  (match (compiler_lower.lower-compiler-source-with-mode src mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (compiler_ir_types.compiler-ir-function-seq-count
            (compiler_ir_types.compiler-ir-global-shared-view functions))])]
    [(compiler_lower.ResultCompilerLower.Err _) (- 0 1)]))

(define (compiler-lower-spmd-scalar-call-shape-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (touch-heavy [x : i64]) : unit
  (begin
    (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7)
    unit))
(define (fill-value [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (heavy i))))
(define (fill-unit [n : i64]) : unit
  (foreach ([i : i64 0 n]) (touch-heavy i)))")

(define (compiler-lower-spmd-varying-local-call-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (+ i 1)]
      (set! (array-ref out i) (heavy x)))))")

(define (compiler-lower-spmd-uniform-arg-call-source) : String
  "(define (heavy [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (__tl_dyn-array i64)] [n : i64] [offset : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (heavy (+ offset 1)))))")

(define (compiler-lower-imported-spmd-selection-error-contains?
  [result : compiler_lower.ResultLowerImportedSpmdSpecialization]
  [fragment : String]) : bool
  (match result
    [(compiler_lower.ResultLowerImportedSpmdSpecialization.Ok _) false]
    [(compiler_lower.ResultLowerImportedSpmdSpecialization.Err diag)
      (let
        [message : String
          (compiler_diagnostic.compiler-diagnostic-message
            (__tl-box-place diag))]
        (string.contains (& message) (& fragment)))]))

;; Selection, generated linker-name canonicalization, source metadata, and
;; diagnostic spans all belong to the caller's compile job. A same-shaped
;; installed decoy must not redirect any of those reads or receive mutations.
(define (compiler-lower-imported-spmd-owner-isolation-ok?) : bool
  (let
    [active-intern-before : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [active-pools-before : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-decoy : ci.InternCompatState (ci.intern-compat-state-new)]
    [name-a : i64
      (ci.intern-compat-state-intern (&mut intern-a) "owner-a/item.field")]
    [name-b : i64
      (ci.intern-compat-state-intern (&mut intern-b) "owner-b-plain")]
    [_decoy-name : i64
      (ci.intern-compat-state-intern (&mut intern-decoy) "installed-decoy")]
    [link-a : i64
      (ci.intern-compat-state-generated-canonical-name
        (&mut intern-a)
        "_tl_owner_a")]
    [link-b : i64
      (ci.intern-compat-state-generated-canonical-name
        (&mut intern-b)
        "_tl_owner_b")]
    [source-a : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state (& intern-a))]
    [source-b : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state (& intern-b))]
    [lower-a : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (owned_view.compiler-owned-shared-view intern-a))]
    [structural-a : cis.InternStructuralKey
      (cis.intern-structural-session-composite-pair-key
        (compiler_lower.compiler-lower-state-structural-session
          (owned_view.compiler-owned-shared-view lower-a))
        name-a
        link-a)]
    [pools-a : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 4 1)]
    [pools-b : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 4 1)]
    [inner-a : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools-a)
        (compiler_ast_types.AstExpr.Literal (compiler_ast_types.ast-lit-int 1)))]
    [_inner-b : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools-b)
        (compiler_ast_types.AstExpr.Spanned
          0
          (compiler_ast_types.ast-source-span 99 1 99 2)))]
    [origin-a : compiler_ast_types.AstExpr
      (compiler_ast_types.AstExpr.Spanned
        inner-a
        (compiler_ast_types.ast-source-span 9 4 9 12))]
    [item-a : compiler_ast_types.AstImportedSpmdSpecialization
      (compiler_ast_types.AstImportedSpmdSpecialization
        (ci.intern-id-from-renderable link-a)
        (ci.intern-id-from-renderable link-a)
        1
        (ci.intern-id-from-renderable link-a)
        (ci.intern-id-from-renderable link-a)
        0
        (ci.intern-id-from-renderable link-a))]
    [empty-callables : compiler_ast_types.AstImportedSpmdCallableList
      (compiler_ast_types.ast-imported-spmd-callable-list-new)]
    [decoy-source-before : i64
      (ci.intern-compat-state-pool-len (& intern-decoy))]
    [decoy-generated-before : i64
      (ci.intern-compat-state-generated-count (& intern-decoy))]
    [decoy-exprs-before : i64
      (compiler_ast_types.ast-node-pool-context-expr-len
        (owned_view.compiler-owned-shared-view pools-b))]
    [ok : bool false]
    (begin
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view intern-decoy))
      (compiler_ast_types.ast-node-pool-context-install!
        (owned_view.compiler-owned-shared-view pools-b))
      (let
        [stripped-a : i64
          (compiler_lower.lower-imported-spmd-ir-symbol (&mut intern-a) item-a)]
        [diagnostic-line : i64
          (match (compiler_lower.lower-imported-spmd-select
            (& intern-a)
            (owned_view.compiler-owned-shared-view pools-a)
            (ci.intern-id-from-renderable name-a)
            (& empty-callables)
            "(-> i64 i64)"
            (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (compiler_ast_types.AstType.I64)
            origin-a)
            [(compiler_lower.ResultLowerImportedSpmdSpecialization.Ok _) -1]
            [(compiler_lower.ResultLowerImportedSpmdSpecialization.Err diag)
              (compiler_diagnostic.compiler-diagnostic-line
                (__tl-box-place diag))])]
        (set!
          ok
          (and
            (= name-a name-b)
            (= link-a link-b)
            (string.eq
              (ci.intern-source-name-session-handle-str source-a name-a)
              "owner-a/item.field")
            (string.eq
              (ci.intern-source-name-session-handle-str source-b name-b)
              "owner-b-plain")
            (ci.intern-source-name-session-handle-qualified? source-a name-a)
            (ci.intern-source-name-session-handle-dotted? source-a name-a)
            (not
              (ci.intern-source-name-session-handle-qualified? source-b name-b))
            (not (ci.intern-source-name-session-handle-dotted? source-b name-b))
            (string.eq
              (ci.intern-compat-state-str (& intern-a) stripped-a)
              "owner_a")
            (string.eq
              (compiler_lower.compiler-lower-state-name-text
                (owned_view.compiler-owned-shared-view lower-a)
                name-a)
              "owner-a/item.field")
            (string.eq
              (compiler_lower.compiler-lower-state-name-text
                (owned_view.compiler-owned-shared-view lower-a)
                (cis.intern-structural-key-raw structural-a))
              "owner-a/item.field/_tl_owner_a")
            (= diagnostic-line 9)
            (=
              (ci.intern-compat-state-pool-len (& intern-decoy))
              decoy-source-before)
            (=
              (ci.intern-compat-state-generated-count (& intern-decoy))
              decoy-generated-before)
            (=
              (compiler_ast_types.ast-node-pool-context-expr-len
                (owned_view.compiler-owned-shared-view pools-b))
              decoy-exprs-before))))
      (ci.intern-compat-state-install! active-intern-before)
      (compiler_ast_types.ast-node-pool-context-install! active-pools-before)
      (compiler_ast_types.ast-node-pool-context-destroy-storage! pools-a)
      (compiler_ast_types.ast-node-pool-context-destroy-storage! pools-b)
      (unsafe
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena (& intern-a)))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena (& intern-b)))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena (& intern-decoy))))
      ok)))

(test
  compiler-lower-imported-spmd-owner-isolation
  (test.assert-true
    (compiler-lower-imported-spmd-owner-isolation-ok?)
    "imported SPMD selection and diagnostics use only explicit intern/pool owners"))

(define (compiler-lower-imported-spmd-selection-smoke-ok?) : bool
  (let
    [interns : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [canonical-name : ci.InternId
      (lower-test-renderable-name-id-with-state (&mut interns) "fixture/helper")]
    [signature : String "(-> i64 i64)"]
    [specializations : compiler_ast_types.AstImportedSpmdSpecializationList
      (compiler_ast_types.ast-imported-spmd-specialization-list-new)]
    [callables : compiler_ast_types.AstImportedSpmdCallableList
      (compiler_ast_types.ast-imported-spmd-callable-list-new)]
    [empty-callables : compiler_ast_types.AstImportedSpmdCallableList
      (compiler_ast_types.ast-imported-spmd-callable-list-new)]
    [duplicate-callables : compiler_ast_types.AstImportedSpmdCallableList
      (compiler_ast_types.ast-imported-spmd-callable-list-new)]
    [unsupported-specializations : compiler_ast_types.AstImportedSpmdSpecializationList
      (compiler_ast_types.ast-imported-spmd-specialization-list-new)]
    [unsupported-callables : compiler_ast_types.AstImportedSpmdCallableList
      (compiler_ast_types.ast-imported-spmd-callable-list-new)]
    [missing-message-fragment : String "has no TLCI callable metadata"]
    [signature-message-fragment : String "ordinary signature mismatch"]
    [specialization-message-fragment : String "has no requested specialization"]
    [abi-message-fragment : String
      "uses unsupported private ABI `spmd-call-v2`"]
    [duplicate-message-fragment : String "has duplicate TLCI specializations"]
    [avx2-message-fragment : String "is not supported in AVX2 backend mode"]
    [origin : compiler_ast_types.AstExpr
      (compiler_ast_types.AstExpr.Literal (compiler_ast_types.ast-lit-int 0))]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    (begin
      (compiler_ast_types.ast-imported-spmd-specialization-list-push
        (&mut specializations)
        (compiler_ast_types.AstImportedSpmdSpecialization
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            "spmd-call-v1")
          (lower-test-renderable-name-id-with-state (&mut interns) "scalar")
          1
          (lower-test-renderable-name-id-with-state (&mut interns) "v")
          (lower-test-renderable-name-id-with-state (&mut interns) "v")
          0
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            "_tl___fixture_helper_scalar")))
      (compiler_ast_types.ast-imported-spmd-callable-list-push
        (&mut callables)
        (compiler_ast_types.AstImportedSpmdCallable
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            (owned_view.compiler-owned-shared-view signature))
          (owned_view.compiler-owned-shared-view specializations)))
      (compiler_ast_types.ast-imported-spmd-callable-list-push
        (&mut duplicate-callables)
        (compiler_ast_types.AstImportedSpmdCallable
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            (owned_view.compiler-owned-shared-view signature))
          (owned_view.compiler-owned-shared-view specializations)))
      (compiler_ast_types.ast-imported-spmd-callable-list-push
        (&mut duplicate-callables)
        (compiler_ast_types.AstImportedSpmdCallable
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            (owned_view.compiler-owned-shared-view signature))
          (owned_view.compiler-owned-shared-view specializations)))
      (compiler_ast_types.ast-imported-spmd-specialization-list-push
        (&mut unsupported-specializations)
        (compiler_ast_types.AstImportedSpmdSpecialization
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            "spmd-call-v2")
          (lower-test-renderable-name-id-with-state (&mut interns) "scalar")
          1
          (lower-test-renderable-name-id-with-state (&mut interns) "v")
          (lower-test-renderable-name-id-with-state (&mut interns) "v")
          0
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            "__fixture_helper_v2")))
      (compiler_ast_types.ast-imported-spmd-callable-list-push
        (&mut unsupported-callables)
        (compiler_ast_types.AstImportedSpmdCallable
          (lower-test-renderable-name-id-with-state
            (&mut interns)
            (owned_view.compiler-owned-shared-view signature))
          unsupported-specializations))
      (and
        (match (compiler_lower.lower-imported-spmd-select
          (& interns)
          (owned_view.compiler-owned-shared-view pools)
          canonical-name
          (& callables)
          (owned_view.compiler-owned-shared-view signature)
          (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
          1
          "v"
          0
          (compiler_ast_types.AstType.I64)
          (owned_view.compiler-owned-shared-view origin))
          [(compiler_lower.ResultLowerImportedSpmdSpecialization.Ok selected)
            (and
              (string.eq
                (ci.intern-compat-state-id-str interns selected.symbol)
                "_tl___fixture_helper_scalar")
              (string.eq
                (ci.intern-compat-state-str
                  interns
                  (compiler_lower.lower-imported-spmd-ir-symbol
                    (&mut interns)
                    selected))
                "__fixture_helper_scalar"))]
          [(compiler_lower.ResultLowerImportedSpmdSpecialization.Err _) false])
        (match (compiler_lower.lower-imported-spmd-select
          (& interns)
          (owned_view.compiler-owned-shared-view pools)
          canonical-name
          (& empty-callables)
          (owned_view.compiler-owned-shared-view signature)
          (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
          1
          "v"
          0
          (compiler_ast_types.AstType.I64)
          (owned_view.compiler-owned-shared-view origin))
          [(compiler_lower.ResultLowerImportedSpmdSpecialization.Ok _) false]
          [(compiler_lower.ResultLowerImportedSpmdSpecialization.Err diag)
            (let
              [message : String
                (compiler_diagnostic.compiler-diagnostic-message
                  (__tl-box-place diag))]
              (string.contains (& message) (& missing-message-fragment)))])
        (compiler-lower-imported-spmd-selection-error-contains?
          (compiler_lower.lower-imported-spmd-select
            (& interns)
            (owned_view.compiler-owned-shared-view pools)
            canonical-name
            (& callables)
            "(-> i64 u64)"
            (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (compiler_ast_types.AstType.I64)
            (owned_view.compiler-owned-shared-view origin))
          signature-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (compiler_lower.lower-imported-spmd-select
            (& interns)
            (owned_view.compiler-owned-shared-view pools)
            canonical-name
            (& callables)
            (owned_view.compiler-owned-shared-view signature)
            (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
            8
            "v"
            0
            (compiler_ast_types.AstType.I64)
            (owned_view.compiler-owned-shared-view origin))
          (owned_view.compiler-owned-shared-view
            specialization-message-fragment))
        (compiler-lower-imported-spmd-selection-error-contains?
          (compiler_lower.lower-imported-spmd-select
            (& interns)
            (owned_view.compiler-owned-shared-view pools)
            canonical-name
            (& callables)
            (owned_view.compiler-owned-shared-view signature)
            (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
            1
            "v"
            -1
            (compiler_ast_types.AstType.I64)
            (owned_view.compiler-owned-shared-view origin))
          specialization-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (compiler_lower.lower-imported-spmd-select
            (& interns)
            (owned_view.compiler-owned-shared-view pools)
            canonical-name
            (& unsupported-callables)
            (owned_view.compiler-owned-shared-view signature)
            (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (compiler_ast_types.AstType.I64)
            (owned_view.compiler-owned-shared-view origin))
          abi-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (compiler_lower.lower-imported-spmd-select
            (& interns)
            (owned_view.compiler-owned-shared-view pools)
            canonical-name
            (& duplicate-callables)
            (owned_view.compiler-owned-shared-view signature)
            (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
            1
            "v"
            0
            (compiler_ast_types.AstType.I64)
            (owned_view.compiler-owned-shared-view origin))
          duplicate-message-fragment)
        (compiler-lower-imported-spmd-selection-error-contains?
          (compiler_lower.lower-imported-spmd-select
            (& interns)
            (owned_view.compiler-owned-shared-view pools)
            canonical-name
            (& callables)
            (owned_view.compiler-owned-shared-view signature)
            (compiler_ir_types.CompilerIrSpmdBackend.Avx2)
            4
            "v"
            0
            (compiler_ast_types.AstType.I64)
            (owned_view.compiler-owned-shared-view origin))
          avx2-message-fragment)
        (compiler-lower-imported-spmd-owner-isolation-ok?)))))

(define (compiler-lower-spmd-scalar-call-shape-ok?) : bool
  (and
    (compiler-lower-imported-spmd-selection-smoke-ok?)
    (match (compiler_lower.lower-compiler-source-with-mode
      (compiler-lower-spmd-scalar-call-shape-source)
      (compiler_lower.CompilerLowerMode.Scalar))
      [(compiler_lower.ResultCompilerLower.Ok program _)
        (match program
          [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
            (and
              (>
                (lower-test-function-spmd-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "fill-value")
                0)
              (>
                (lower-test-function-spmd-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "fill-unit")
                0)
              (>
                (compiler_ir_types.compiler-ir-function-seq-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                4))])]
      [(compiler_lower.ResultCompilerLower.Err _) false])))

(define (compiler-lower-spmd-varying-local-call-shape-ok?) : bool
  (>
    (compiler-lower-spmd-source-call-count
      (compiler-lower-spmd-varying-local-call-source)
      (compiler_lower.CompilerLowerMode.Avx512))
    0))

(define (compiler-lower-spmd-uniform-arg-call-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-spmd-uniform-arg-call-source)
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-spmd-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill")
              0)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "fill"
                (compiler_ir_types.CompilerIrBinOp.Add))
              5))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-out-of-line-call-shape-ok?) : bool
  (and
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-value-source)
        (compiler_lower.CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (compiler_lower.CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-masked-source)
        (compiler_lower.CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-value-source)
        (compiler_lower.CompilerLowerMode.Avx512))
      2)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (compiler_lower.CompilerLowerMode.Avx512))
      2)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-value-source)
        (compiler_lower.CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (compiler_lower.CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-masked-source)
        (compiler_lower.CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-value-source)
        (compiler_lower.CompilerLowerMode.Avx2))
      2)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (compiler_lower.CompilerLowerMode.Avx2))
      2)
    (compiler-lower-spmd-varying-local-call-shape-ok?)
    (compiler-lower-spmd-uniform-arg-call-shape-ok?)))

(define (compiler-lower-foreach-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
      (compiler-lower-ok?
        "(define (f [a : (__tl_dyn-array i64)] [n : i64]) : unit (foreach ([i : i64 0 n]) (set! (array-ref a i) i)))")
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
    (compiler-lower-spmd-lane-array-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx2)
      false)
    (compiler-lower-spmd-lane-array-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx512)
      true)
    (compiler-lower-spmd-broadcast-avx2-shape-ok?)
    (compiler-lower-spmd-broadcast-avx512-shape-ok?)
    (compiler-lower-scalar-foreach-stays-scalar-ok?)
    (compiler-lower-simd-foreach-fallback-diagnostic-ok?)
    (compiler-lower-spmd-shuffle-lowering-ok?)
    (compiler-lower-masked-load-cache-tests-ok?)
    (compiler-lower-avx512-masked-if-shape-ok?)
    (compiler-lower-avx512-masked-if-offset-shape-ok?)
    (compiler-lower-avx512-masked-if-index-value-shape-ok?)
    (compiler-lower-avx512-masked-if-index-mod-shape-ok?)
    (compiler-lower-avx512-masked-if-value-shape-ok?)
    (compiler-lower-masked-if-bitand-value-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx2))
    (compiler-lower-masked-if-bitand-value-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx512))
    (compiler-lower-masked-if-bitwise-value-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx2))
    (compiler-lower-masked-if-bitwise-value-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx512))
    (compiler-lower-masked-shift-tests-ok?)
    (compiler-lower-avx512-masked-if-nested-shape-ok?)
    (compiler-lower-avx2-masked-if-shape-ok?)))

(define (compiler-lower-avx2-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]
  [vector-shapes : i64]
  [vector-binops : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx2))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-reduce-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              vector-binops)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f"
                lanes
                elem-ty)
              vector-shapes)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-bool-reduce-shape-ok?
  [src : String]
  [mode : compiler_lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode src mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0)
            (=
              (lower-test-function-vector-reduce-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0)
            (=
              (lower-test-function-predicated-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-tail-mask-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f"
                lanes
                (compiler_ast_types.AstType.Bool))
              1)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-map-fused-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0
    (+ (+ (array-ref xs i) r) (bit-and (program-index) 0))))"
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-reduce-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              4)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f"
                lanes
                (compiler_ast_types.AstType.I64))
              9)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-avx512-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]
  [vector-shapes : i64]
  [vector-binops : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    src
    (compiler_lower.CompilerLowerMode.Avx512))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-reduce-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              vector-binops)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f"
                lanes
                elem-ty)
              vector-shapes)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-lane-identity-source) : String
  "(define (f [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (program-count) (program-index))))")

(define (compiler-lower-spmd-reduce-lane-identity-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-spmd-reduce-lane-identity-source)
    mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0)
            (=
              (lower-test-function-vector-reduce-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              2)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f"
                lanes
                (compiler_ast_types.AstType.I64))
              5)
            (=
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-gather-source-shape-ok?
  [source : String]
  [mode : compiler_lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (compiler_lower.lower-compiler-source-with-mode source mode)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-vector-load-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0)
            (=
              (lower-test-function-vector-reduce-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              1)
            (=
              (lower-test-function-vector-shape-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f"
                lanes
                (compiler_ast_types.AstType.F32))
              2)
            (>
              (lower-test-function-bounds-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-spmd-reduce-gather-shape-ok?
  [mode : compiler_lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (and
    (compiler-lower-spmd-reduce-gather-source-shape-ok?
      "(define (f [xs : (__tl_dyn-array f32)] [ix : (__tl_dyn-array i64)] [n : i64]) : f32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs (array-ref ix i))))"
      mode
      lanes)
    (compiler-lower-spmd-reduce-gather-source-shape-ok?
      "(define (f [xs : (__tl_dyn-array f32)] [offsets : (__tl_dyn-array i64)] [n : i64]) : f32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs (+ i (array-ref offsets (program-index))))))"
      mode
      lanes)))

(define (compiler-lower-avx2-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
        (compiler_ast_types.AstType.I64)
        4
        4
        1)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
        (compiler_ast_types.AstType.I32)
        8
        4
        1)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I32)
        8
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I32)
        8
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (compiler_ast_types.AstType.F64)
        4
        2
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I64)
        4
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I64)
        4
        4
        0)
      (compiler-lower-spmd-reduce-lane-identity-shape-ok?
        (compiler_lower.CompilerLowerMode.Avx2)
        4))
    (compiler-lower-avx2-spmd-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
      (compiler_ast_types.AstType.F32)
      8
      2
      0)
    (compiler-lower-spmd-reduce-map-fused-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx2)
      4)
    (compiler-lower-spmd-reduce-gather-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx2)
      8)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))"
      (compiler_lower.CompilerLowerMode.Avx2)
      32)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))"
      (compiler_lower.CompilerLowerMode.Avx2)
      32)))

(define (compiler-lower-avx512-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
        (compiler_ast_types.AstType.I64)
        8
        4
        1)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I64)
        8
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I64)
        8
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (compiler_ast_types.AstType.F64)
        8
        2
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I32)
        16
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (compiler_ast_types.AstType.I32)
        16
        4
        0)
      (compiler-lower-spmd-reduce-lane-identity-shape-ok?
        (compiler_lower.CompilerLowerMode.Avx512)
        8)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
        (compiler_ast_types.AstType.F32)
        16
        2
        0))
    (compiler-lower-spmd-reduce-map-fused-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx512)
      8)
    (compiler-lower-spmd-reduce-gather-shape-ok?
      (compiler_lower.CompilerLowerMode.Avx512)
      16)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))"
      (compiler_lower.CompilerLowerMode.Avx512)
      64)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))"
      (compiler_lower.CompilerLowerMode.Avx512)
      64)))

;; `spmd-reduce` lowering: integer, f32, and f64 sum reductions lower (to
;; an accumulator loop, so `main` holds the guard branch + fold/increment
;; binops), and the min/max/all/any reduction ops lower as well.
(define (compiler-lower-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))")
    (compiler-lower-foreach-shape-ok?
      "(define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 i))")
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))")
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))")
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
  (match (compiler_lower.lower-compiler-source src)
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>
              (lower-test-function-branch-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0)
            (=
              (lower-test-function-binop-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-raw-pointer-ops-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (=
              (lower-test-function-addr-of-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-register-addr-of-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-register-addr-of-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tl_alloc")
              0)
            (>=
              (lower-test-function-addr-of-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              3)
            (>=
              (lower-test-function-gep-offset-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                4)
              1)
            (>=
              (lower-test-function-gep-offset-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                8)
              1)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-raw-pointer-call-value-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-raw-pointer-call-value-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "raw-make")
              1)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "raw-value")
              1)
            (=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (>
              (lower-test-function-u64-mov-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-raw-pointer-aggregate-copy-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-raw-pointer-aggregate-copy-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "copy-slot")
              1)
            (=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "copy-slot")
              0)
            (=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "copy-pair")
              0)
            (=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "copy-pair")
              2))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-string-length-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-string-length-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (compiler_lower.lower-compiler-program program)
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (and
                (>
                  (lower-test-function-gep-offset-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "core-str-len"
                    1)
                  0)
                (>
                  (lower-test-function-gep-offset-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "core-str-len-borrow"
                    1)
                  0)
                (=
                  (lower-test-functions-direct-call-count
                    (compiler_ir_types.compiler-ir-global-shared-view functions)
                    "length")
                  0))])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-float-bitcast-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-float-bitcast-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-bitcast-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f64-bits")
              1)
            (=
              (lower-test-function-bitcast-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f32-bits")
              1)
            (=
              (lower-test-function-bitcast-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f64-from")
              1)
            (=
              (lower-test-function-bitcast-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "f32-from")
              1)
            (=
              (lower-test-functions-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tl_alloc")
              0)
            (=
              (lower-test-functions-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "__tl_float_to_bits")
              0)
            (=
              (lower-test-functions-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "__tl_float_from_bits")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-literal-float-to-bits-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-literal-float-to-bits-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-functions-bitcast-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              0)
            (=
              (lower-test-functions-direct-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "__tl_float_to_bits")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-public-literal-float-to-bits-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-public-literal-float-to-bits-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "stdlib/math.tl"
        program
        (compiler-lower-public-literal-float-to-bits-paths))
        [(compiler_lower.ResultCompilerLower.Ok lowered _)
          (match lowered
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (=
                (lower-test-functions-bitcast-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                0)])]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-string-runtime-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-string-runtime-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (compiler_lower.lower-compiler-program program)
        [(compiler_lower.ResultCompilerLower.Ok _ _) true]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-stdio-ok?) : bool
  (match (compiler_parse_core.parse-ast-source (compiler-lower-stdio-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (compiler_lower.lower-compiler-program program)
        [(compiler_lower.ResultCompilerLower.Ok _ _) true]
        [(compiler_lower.ResultCompilerLower.Err _) false])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-stdio-builtin-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-stdio-builtin-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_flush_stdout")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_stdin_eof")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_read_stdin_line")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  ".L_tl_read_stdin_bytes")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "flush-stdout")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "stdin-eof?")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "read-stdin-line")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "io.read-stdin-bytes")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-env-builtin-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-env-builtin-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_env_var_exists")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_env_var_value")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "var-exists?")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "var-value")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "path-separator")
                1)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-stdlib-helper-defaults-disabled-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (when
        (compiler_lower.lower-bootstrap-runtime-builtin-id?
          cbi.compiler-builtin-id-env-path-separator)
        (set! ok false))
      (when
        (not
          (compiler_lower.lower-bootstrap-runtime-builtin-id?
            cbi.compiler-builtin-id-tl-private-string-eq))
        (set! ok false))
      (when
        (not
          (compiler_lower.lower-bootstrap-runtime-builtin-id?
            cbi.compiler-builtin-id-tl-private-string-to-int))
        (set! ok false))
      (when
        (compiler_lower.lower-string-runtime-builtin? "substring")
        (set! ok false))
      (when
        (compiler_lower.lower-string-runtime-builtin? "string-slice")
        (set! ok false))
      (when
        (compiler_lower.lower-string-runtime-builtin? "string-append")
        (set! ok false))
      (when
        (compiler_lower.lower-string-runtime-builtin? "string-concat")
        (set! ok false))
      ok)))

(define (compiler-lower-cpu-builtin-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-cpu-builtin-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>=
                (lower-test-functions-cpuid-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                4)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-xgetbv-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions))
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "cpuid")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "xgetbv")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_cpuid")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  (compiler_ir_types.compiler-ir-global-shared-view functions)
                  "tl_xgetbv")
                0)
                unit
                (set! ok false))
              ok))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

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
      (if (compiler-lower-emit-string-stdlib-shape-ok?)
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

(define (lower-test-decl-list-count [decls : compiler_ast_types.AstDeclList]) : i64
  (match (compiler_ast_types.ast-decl-list-step
    (owned_view.compiler-owned-shared-view decls))
    [(compiler_ast_types.AstDeclListStep.Nil) 0]
    [(compiler_ast_types.AstDeclListStep.Cons _ rest)
      (let
        [rest : compiler_ast_types.AstDeclList rest]
        (+ 1 (lower-test-decl-list-count rest)))]))

(define (lower-test-decl-list-defines?
  [decls : compiler_ast_types.AstDeclList]
  [name : String]) : bool
  (match (compiler_ast_types.ast-decl-list-step decls)
    [(compiler_ast_types.AstDeclListStep.Nil) false]
    [(compiler_ast_types.AstDeclListStep.Cons decl rest)
      (let
        [rest : compiler_ast_types.AstDeclList rest]
        (match decl
          [(compiler_ast_types.AstDecl.DefFn decl-meta found _ _ _ _)
            (if (string.eq
              (compiler_typecheck_core.tc-env-key-name-text found)
              (owned_view.compiler-owned-shared-view name))
              true
              (lower-test-decl-list-defines? rest name))]
          [(compiler_ast_types.AstDecl.DefEnum decl-meta found _ _)
            (if (string.eq
              (compiler_typecheck_core.tc-env-key-name-text found)
              (owned_view.compiler-owned-shared-view name))
              true
              (lower-test-decl-list-defines? rest name))]
          [(compiler_ast_types.AstDecl.DefEnumLifetimes decl-meta found _ _ _)
            (if (string.eq
              (compiler_typecheck_core.tc-env-key-name-text found)
              (owned_view.compiler-owned-shared-view name))
              true
              (lower-test-decl-list-defines? rest name))]
          [(compiler_ast_types.AstDecl.DefStruct decl-meta found _ _ _)
            (if (string.eq
              (compiler_typecheck_core.tc-env-key-name-text found)
              (owned_view.compiler-owned-shared-view name))
              true
              (lower-test-decl-list-defines? rest name))]
          [(compiler_ast_types.AstDecl.DefStructLifetimes
              decl-meta
              found
              _
              _
              _
              _)
            (if (string.eq
              (compiler_typecheck_core.tc-env-key-name-text found)
              (owned_view.compiler-owned-shared-view name))
              true
              (lower-test-decl-list-defines? rest name))]
          [(compiler_ast_types.AstDecl.Unsafe inner-box)
            (let
              [inner : compiler_ast_types.AstDecl
                (compiler_ast_types.ast-decl-box-shared-view inner-box)]
              (if (lower-test-decl-list-defines?
                (compiler_ast_types.ast-decl-cons
                  inner
                  (compiler_ast_types.ast-decl-list-new))
                (owned_view.compiler-owned-shared-view name))
                true
                (lower-test-decl-list-defines? rest name)))]
          [_ (lower-test-decl-list-defines? rest name)]))]))

(define (compiler-lower-ast-dce-program) : compiler_ast_types.AstProgram
  (let
    [callback-id : i64 (lower-test-generated-name-id "callback")]
    [callback-target-id : i64 cbi.compiler-builtin-id-fix-callback_target]
    [main-id : i64 cbi.compiler-builtin-id-fix-main]
    [helper-id : i64 cbi.compiler-builtin-id-fix-helper]
    [dead-id : i64 (lower-test-generated-name-id "dead")]
    (compiler_ast_types.ast-program
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-id
          callback-id
          compiler_ast_types.AstMaybeType.No
          (compiler_ast_types.ast-node-push
            (compiler_ast_types.AstExpr.Var callback-target-id)))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-fn-id
            main-id
            (compiler_ast_types.ast-param-list-new)
            (compiler_ast_types.AstType.I64)
            (compiler_ast_types.ast-expr-call
              (compiler_ast_types.ast-node-push
                (compiler_ast_types.AstExpr.Var helper-id))
              (compiler_ast_types.ast-expr-list-new)))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-def-fn-id
              helper-id
              (compiler_ast_types.ast-param-list-new)
              (compiler_ast_types.AstType.I64)
              (compiler_ast_types.ast-node-push
                (compiler_ast_types.AstExpr.Literal
                  (compiler_ast_types.ast-lit-int 7))))
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-def-fn-id
                callback-target-id
                (compiler_ast_types.ast-param-list-new)
                (compiler_ast_types.AstType.I64)
                (compiler_ast_types.ast-node-push
                  (compiler_ast_types.AstExpr.Literal
                    (compiler_ast_types.ast-lit-int 11))))
              (compiler_ast_types.ast-decl-cons
                (compiler_ast_types.ast-decl-def-fn-id
                  dead-id
                  (compiler_ast_types.ast-param-list-new)
                  (compiler_ast_types.AstType.I64)
                  (compiler_ast_types.ast-node-push
                    (compiler_ast_types.AstExpr.Literal
                      (compiler_ast_types.ast-lit-int 9))))
                (compiler_ast_types.ast-decl-list-new)))))))))

(define (compiler-lower-dce-test-symbols-ready?) : bool
  (match (compiler_parse_core.parse-ast-source
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
    [(compiler_parse_core.ResultAstProgram.Ok _) true]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-ast-dce-no-main-program) : compiler_ast_types.AstProgram
  (compiler_ast_types.ast-program
    (compiler_ast_types.ast-decl-cons
      (compiler_ast_types.ast-decl-def-fn-id
        (lower-test-generated-name-id "helper")
        (compiler_ast_types.ast-param-list-new)
        (compiler_ast_types.AstType.I64)
        (compiler_ast_types.ast-node-push
          (compiler_ast_types.AstExpr.Literal
            (compiler_ast_types.ast-lit-int 7))))
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-fn-id
          (lower-test-generated-name-id "dead")
          (compiler_ast_types.ast-param-list-new)
          (compiler_ast_types.AstType.I64)
          (compiler_ast_types.ast-node-push
            (compiler_ast_types.AstExpr.Literal
              (compiler_ast_types.ast-lit-int 9))))
        (compiler_ast_types.ast-decl-list-new)))))

(define (compiler-lower-macro-body-dce-program) : compiler_ast_types.AstProgram
  (compiler_ast_types.ast-program
    (compiler_ast_types.ast-decl-cons
      (compiler_ast_types.ast-decl-def-fn-id
        (lower-test-generated-name-id "main")
        (compiler_ast_types.ast-param-list-new)
        (compiler_ast_types.AstType.I64)
        (compiler_ast_types.ast-node-push
          (compiler_ast_types.AstExpr.Literal
            (compiler_ast_types.ast-lit-int 0))))
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-fn-id
          (lower-test-generated-name-id "macro-only-helper")
          (compiler_ast_types.ast-param-list-new)
          (compiler_ast_types.AstType.I64)
          (compiler_ast_types.ast-node-push
            (compiler_ast_types.AstExpr.Literal
              (compiler_ast_types.ast-lit-int 7))))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-macro-id
            (lower-test-generated-name-id "macro-uses-helper")
            (compiler_ast_types.ast-macro-param-list-new)
            (compiler_ast_types.AstType.Expr)
            (compiler_ast_types.ast-expr-call
              (compiler_ast_types.ast-node-push
                (compiler_ast_types.AstExpr.Var
                  cbi.compiler-builtin-id-fix-macro_only_helper))
              (compiler_ast_types.ast-expr-list-new)))
          (compiler_ast_types.ast-decl-list-new))))))

(define (compiler-lower-stdlib-comptime-runtime-dce-program) : compiler_ast_types.AstProgram
  (compiler_ast_types.ast-program
    (compiler_ast_types.ast-decl-cons
      (compiler_ast_types.ast-decl-module-id
        (lower-test-generated-name-id "stdlib.comptime"))
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-fn-id
          (lower-test-generated-name-id "ctfe-runtime-helper")
          (compiler_ast_types.ast-param-list-new)
          (compiler_ast_types.AstType.I64)
          (compiler_ast_types.ast-node-push
            (compiler_ast_types.AstExpr.Literal
              (compiler_ast_types.ast-lit-int 7))))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-module-id
            (lower-test-generated-name-id "main"))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-def-fn-id
              (lower-test-generated-name-id "main")
              (compiler_ast_types.ast-param-list-new)
              (compiler_ast_types.AstType.I64)
              (compiler_ast_types.ast-node-push
                (compiler_ast_types.AstExpr.Literal
                  (compiler_ast_types.ast-lit-int 0))))
            (compiler_ast_types.ast-decl-list-new)))))))

(define (compiler-lower-stdlib-comptime-runtime-skip-keeps-types-ok?) : bool
  (let
    [decls : compiler_ast_types.AstDeclList
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-fn-id
          (lower-test-generated-name-id "ctfe-runtime-helper")
          (compiler_ast_types.ast-param-list-new)
          (compiler_ast_types.AstType.I64)
          (compiler_ast_types.ast-node-push
            (compiler_ast_types.AstExpr.Literal
              (compiler_ast_types.ast-lit-int 7))))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-comptime-decl
            (compiler_ast_types.ast-decl-def-struct-id
              (lower-test-generated-name-id "ExprClauseList")
              compiler_ast_types.AstStructRepr.Default
              compiler_ast_types.AstStructCleanup.No
              (compiler_ast_types.ast-field-def-list-new)))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-module-id
              (lower-test-generated-name-id "main"))
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-def-fn-id
                (lower-test-generated-name-id "main")
                (compiler_ast_types.ast-param-list-new)
                (compiler_ast_types.AstType.I64)
                (compiler_ast_types.ast-node-push
                  (compiler_ast_types.AstExpr.Literal
                    (compiler_ast_types.ast-lit-int 0))))
              (compiler_ast_types.ast-decl-list-new)))))]
    [kept : compiler_ast_types.AstDeclList
      (lower-skip-runtime-until-next-module decls)]
    (and
      (=
        (lower-test-decl-list-count
          (owned_view.compiler-owned-shared-view kept))
        3)
      (lower-test-decl-list-defines?
        (owned_view.compiler-owned-shared-view kept)
        "ExprClauseList")
      (lower-test-decl-list-defines?
        (owned_view.compiler-owned-shared-view kept)
        "main")
      (not (lower-test-decl-list-defines? kept "ctfe-runtime-helper")))))

(define (compiler-lower-stdlib-comptime-type-prune-keeps-types-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler_ast_types.ast-program
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-module-id
            (lower-test-generated-name-id "stdlib.comptime"))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-def-fn-id
              (lower-test-generated-name-id "ctfe-runtime-helper")
              (compiler_ast_types.ast-param-list-new)
              (compiler_ast_types.AstType.I64)
              (compiler_ast_types.ast-node-push
                (compiler_ast_types.AstExpr.Literal
                  (compiler_ast_types.ast-lit-int 7))))
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-comptime-decl
                (compiler_ast_types.ast-decl-def-struct-id
                  (lower-test-generated-name-id "ExprClauseList")
                  compiler_ast_types.AstStructRepr.Default
                  compiler_ast_types.AstStructCleanup.No
                  (compiler_ast_types.ast-field-def-list-new)))
              (compiler_ast_types.ast-decl-cons
                (compiler_ast_types.ast-decl-module-id
                  (lower-test-generated-name-id "main"))
                (compiler_ast_types.ast-decl-cons
                  (compiler_ast_types.ast-decl-def-fn-id
                    (lower-test-generated-name-id "main")
                    (compiler_ast_types.ast-param-list-new)
                    (compiler_ast_types.AstType.I64)
                    (compiler_ast_types.ast-node-push
                      (compiler_ast_types.AstExpr.Literal
                        (compiler_ast_types.ast-lit-int 0))))
                  (compiler_ast_types.ast-decl-list-new)))))))]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (compiler_ast_types.ast-decl-path-list-new)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (compiler_ast_types.ast-decl-path-list-new)
        names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "ExprClauseList")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (not (lower-test-decl-list-defines? kept "ctfe-runtime-helper"))))])])))

(define (compiler-lower-stdlib-comptime-nullary-enum-runtime-skip-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    "(import stdlib.comptime)
(define (main) : i64 0)")
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program globals _ _)
          (not
            (lower-test-global-list-has-name?
              globals
              "__enum_obj_stdlib.comptime/Pattern_Wildcard"))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-unsafe-ast-dce-source) : String
  "(define (main) : i64 (unsafe (unsafe-entry)))
(define (unsafe-helper) : i64 41)
(unsafe (define (unsafe-entry) : i64 (unsafe-helper)))
(define (dead-helper) : i64 0)
(unsafe (define (dead-unsafe) : i64 (dead-helper)))")

(define (compiler-lower-type-decl-dce-program) : compiler_ast_types.AstProgram
  (let
    [used-enum-id : i64 cbi.compiler-builtin-id-fix-UsedEnum]
    [used-box-id : i64 cbi.compiler-builtin-id-fix-UsedBox]
    (compiler_ast_types.ast-program
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-enum-id
          used-enum-id
          compiler_ast_types.AstEnumCleanup.No
          (compiler_ast_types.ast-variant-def-cons
            (compiler_ast_types.ast-variant-def-id
              (lower-test-generated-name-id "UsedA")
              (compiler_ast_types.ast-type-list-new)
              (compiler_ast_types.ast-variant-payload-cleanup-list-new))
            (compiler_ast_types.ast-variant-def-list-new)))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-enum-id
            (lower-test-generated-name-id "DeadEnum")
            compiler_ast_types.AstEnumCleanup.No
            (compiler_ast_types.ast-variant-def-cons
              (compiler_ast_types.ast-variant-def-id
                (lower-test-generated-name-id "DeadA")
                (compiler_ast_types.ast-type-list-new)
                (compiler_ast_types.ast-variant-payload-cleanup-list-new))
              (compiler_ast_types.ast-variant-def-list-new)))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-def-struct-id
              used-box-id
              compiler_ast_types.AstStructRepr.Default
              compiler_ast_types.AstStructCleanup.No
              (compiler_ast_types.ast-field-def-cons
                (compiler_ast_types.ast-field-def-id
                  (lower-test-generated-syntax-id "value")
                  (compiler_ast_types.AstType.Enum used-enum-id)
                  compiler_ast_types.AstFieldCleanup.No)
                (compiler_ast_types.ast-field-def-list-new)))
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-def-struct-id
                (lower-test-generated-name-id "DeadBox")
                compiler_ast_types.AstStructRepr.Default
                compiler_ast_types.AstStructCleanup.No
                (compiler_ast_types.ast-field-def-cons
                  (compiler_ast_types.ast-field-def-id
                    (lower-test-generated-syntax-id "value")
                    (compiler_ast_types.AstType.I64)
                    compiler_ast_types.AstFieldCleanup.No)
                  (compiler_ast_types.ast-field-def-list-new)))
              (compiler_ast_types.ast-decl-cons
                (compiler_ast_types.ast-decl-def-fn-id
                  cbi.compiler-builtin-id-fix-main
                  (compiler_ast_types.ast-param-list-new)
                  (compiler_ast_types.AstType.Struct used-box-id)
                  (compiler_ast_types.ast-node-push
                    (compiler_ast_types.AstExpr.Literal
                      (compiler_ast_types.ast-lit-int 0))))
                (compiler_ast_types.ast-decl-list-new)))))))))

(define (compiler-lower-type-decl-dce-paths) : compiler_ast_types.AstDeclPathList
  (let
    [types-id : i64 (compiler_load.compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (compiler_load.compiler-load-source-path-id "entry.tl")]
    (compiler_ast_types.ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (compiler_ast_types.ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (compiler_ast_types.ast-decl-path-cons-with-owner-id
          "types.tl"
          types-id
          (compiler_ast_types.ast-decl-path-cons-with-owner-id
            "types.tl"
            types-id
            (compiler_ast_types.ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (compiler_ast_types.ast-decl-path-list-new))))))))

(define (compiler-lower-type-decl-dce-qualified-base-program) : compiler_ast_types.AstProgram
  (let
    [result-id : i64
      (compiler_load.compiler-load-parse-context-name-id "io.ResultIoString")]
    [dead-result-id : i64
      (compiler_load.compiler-load-parse-context-name-id "io.DeadResult")]
    (compiler_ast_types.ast-program
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-enum-id
          result-id
          compiler_ast_types.AstEnumCleanup.No
          (compiler_ast_types.ast-variant-def-cons
            (compiler_ast_types.ast-variant-def-id
              (lower-test-generated-name-id "OkIoString")
              (compiler_ast_types.ast-type-list-new)
              (compiler_ast_types.ast-variant-payload-cleanup-list-new))
            (compiler_ast_types.ast-variant-def-list-new)))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-enum-id
            dead-result-id
            compiler_ast_types.AstEnumCleanup.No
            (compiler_ast_types.ast-variant-def-cons
              (compiler_ast_types.ast-variant-def-id
                (lower-test-generated-name-id "DeadResultA")
                (compiler_ast_types.ast-type-list-new)
                (compiler_ast_types.ast-variant-payload-cleanup-list-new))
              (compiler_ast_types.ast-variant-def-list-new)))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-def-fn-id
              cbi.compiler-builtin-id-fix-main
              (compiler_ast_types.ast-param-list-new)
              (compiler_ast_types.AstType.Enum result-id)
              (compiler_ast_types.ast-node-push
                (compiler_ast_types.AstExpr.Literal
                  (compiler_ast_types.ast-lit-int 0))))
            (compiler_ast_types.ast-decl-list-new)))))))

(define (compiler-lower-type-decl-dce-qualified-base-paths) : compiler_ast_types.AstDeclPathList
  (let
    [types-id : i64 (compiler_load.compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (compiler_load.compiler-load-source-path-id "entry.tl")]
    (compiler_ast_types.ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (compiler_ast_types.ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (compiler_ast_types.ast-decl-path-cons-with-owner-id
          "entry.tl"
          entry-id
          (compiler_ast_types.ast-decl-path-list-new))))))

(define (compiler-lower-type-decl-dce-arena-support-program) : compiler_ast_types.AstProgram
  (compiler_ast_types.ast-program
    (compiler_ast_types.ast-decl-cons
      (compiler_ast_types.ast-decl-module-id
        (compiler_load.compiler-load-parse-context-name-id "stdlib.arena"))
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-struct-id
          (ci.intern-dotted-tail-id cbi.compiler-builtin-id-fix-arena_dot_Arena)
          compiler_ast_types.AstStructRepr.Default
          compiler_ast_types.AstStructCleanup.No
          (compiler_ast_types.ast-field-def-cons
            (compiler_ast_types.ast-field-def-id
              (lower-test-generated-syntax-id "handle")
              (compiler_ast_types.AstType.I64)
              compiler_ast_types.AstFieldCleanup.No)
            (compiler_ast_types.ast-field-def-list-new)))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-struct-id
            cbi.compiler-builtin-id-fix-ArenaMark
            compiler_ast_types.AstStructRepr.Default
            compiler_ast_types.AstStructCleanup.No
            (compiler_ast_types.ast-field-def-cons
              (compiler_ast_types.ast-field-def-id
                (lower-test-generated-syntax-id "handle")
                (compiler_ast_types.AstType.I64)
                compiler_ast_types.AstFieldCleanup.No)
              (compiler_ast_types.ast-field-def-list-new)))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-def-struct-id
              (lower-test-generated-name-id "DeadArenaPeer")
              compiler_ast_types.AstStructRepr.Default
              compiler_ast_types.AstStructCleanup.No
              (compiler_ast_types.ast-field-def-cons
                (compiler_ast_types.ast-field-def-id
                  (lower-test-generated-syntax-id "handle")
                  (compiler_ast_types.AstType.I64)
                  compiler_ast_types.AstFieldCleanup.No)
                (compiler_ast_types.ast-field-def-list-new)))
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-module-id
                cbi.compiler-builtin-id-fix-main)
              (compiler_ast_types.ast-decl-cons
                (compiler_ast_types.ast-decl-def-struct-id
                  cbi.compiler-builtin-id-fix-ThreadBox
                  compiler_ast_types.AstStructRepr.Default
                  compiler_ast_types.AstStructCleanup.No
                  (compiler_ast_types.ast-field-def-cons
                    (compiler_ast_types.ast-field-def-id
                      (lower-test-generated-syntax-id "owner")
                      (compiler_ast_types.AstType.Struct
                        cbi.compiler-builtin-id-fix-arena_dot_Arena)
                      compiler_ast_types.AstFieldCleanup.No)
                    (compiler_ast_types.ast-field-def-list-new)))
                (compiler_ast_types.ast-decl-cons
                  (compiler_ast_types.ast-decl-def-fn-id
                    cbi.compiler-builtin-id-fix-main
                    (compiler_ast_types.ast-param-list-new)
                    (compiler_ast_types.AstType.Struct
                      cbi.compiler-builtin-id-fix-ThreadBox)
                    (compiler_ast_types.ast-node-push
                      (compiler_ast_types.AstExpr.Literal
                        (compiler_ast_types.ast-lit-int 0))))
                  (compiler_ast_types.ast-decl-list-new))))))))))

(define (compiler-lower-type-decl-dce-arena-support-paths) : compiler_ast_types.AstDeclPathList
  (let
    [arena-id : i64 (compiler_load.compiler-load-source-path-id "arena.tl")]
    [entry-id : i64 (compiler_load.compiler-load-source-path-id "entry.tl")]
    [thread-id : i64 (compiler_load.compiler-load-source-path-id "thread.tl")]
    (compiler_ast_types.ast-decl-path-cons-with-owner-id
      "arena.tl"
      arena-id
      (compiler_ast_types.ast-decl-path-cons-with-owner-id
        "arena.tl"
        arena-id
        (compiler_ast_types.ast-decl-path-cons-with-owner-id
          "arena.tl"
          arena-id
          (compiler_ast_types.ast-decl-path-cons-with-owner-id
            "arena.tl"
            arena-id
            (compiler_ast_types.ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (compiler_ast_types.ast-decl-path-cons-with-owner-id
                "thread.tl"
                thread-id
                (compiler_ast_types.ast-decl-path-cons-with-owner-id
                  "entry.tl"
                  entry-id
                  (compiler_ast_types.ast-decl-path-list-new))))))))))

(define (compiler-lower-type-decl-dce-test-body-program) : compiler_ast_types.AstProgram
  (let
    [unit-expr : i64
      (compiler_ast_types.ast-node-push
        (compiler_ast_types.AstExpr.Literal
          (compiler_ast_types.AstLiteral.Unit)))]
    [test-body : i64
      (compiler_ast_types.ast-expr-let
        (compiler_ast_types.ast-let-binding-cons
          (compiler_ast_types.ast-let-binding-id
            (lower-test-generated-name-id "mark")
            (compiler_ast_types.AstMaybeType.Some
              (compiler_ast_types.AstType.Struct
                cbi.compiler-builtin-id-fix-ImportedMark))
            unit-expr)
          (compiler_ast_types.ast-let-binding-list-new))
        unit-expr)]
    (compiler_ast_types.ast-program
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-struct-id
          cbi.compiler-builtin-id-fix-ImportedMark
          compiler_ast_types.AstStructRepr.Default
          compiler_ast_types.AstStructCleanup.No
          (compiler_ast_types.ast-field-def-list-new))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-struct-id
            (lower-test-generated-name-id "DeadMark")
            compiler_ast_types.AstStructRepr.Default
            compiler_ast_types.AstStructCleanup.No
            (compiler_ast_types.ast-field-def-list-new))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-test-id
              (lower-test-generated-name-id "uses-imported-mark-annotation")
              test-body
              (compiler_ast_types.ast-source-span 1 1 1 1))
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-def-fn-id
                cbi.compiler-builtin-id-fix-main
                (compiler_ast_types.ast-param-list-new)
                (compiler_ast_types.AstType.I64)
                (compiler_ast_types.ast-node-push
                  (compiler_ast_types.AstExpr.Literal
                    (compiler_ast_types.ast-lit-int 0))))
              (compiler_ast_types.ast-decl-list-new))))))))

(define (compiler-lower-type-decl-dce-test-body-paths) : compiler_ast_types.AstDeclPathList
  (let
    [types-id : i64 (compiler_load.compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (compiler_load.compiler-load-source-path-id "entry.tl")]
    (compiler_ast_types.ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (compiler_ast_types.ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (compiler_ast_types.ast-decl-path-cons-with-owner-id
          "entry.tl"
          entry-id
          (compiler_ast_types.ast-decl-path-cons-with-owner-id
            "entry.tl"
            entry-id
            (compiler_ast_types.ast-decl-path-list-new)))))))

(define (compiler-lower-type-decl-dce-body-pattern-program) : compiler_ast_types.AstProgram
  (compiler_ast_types.ast-program
    (compiler_ast_types.ast-decl-cons
      (compiler_ast_types.ast-decl-module-id
        (compiler_load.compiler-load-parse-context-name-id "struct.match.geom"))
      (compiler_ast_types.ast-decl-cons
        (compiler_ast_types.ast-decl-def-struct-id
          (compiler_load.compiler-load-parse-context-name-id "QPoint")
          compiler_ast_types.AstStructRepr.Default
          compiler_ast_types.AstStructCleanup.No
          (compiler_ast_types.ast-field-def-cons
            (compiler_ast_types.ast-field-def-id
              (lower-test-generated-syntax-id "x")
              (compiler_ast_types.AstType.I64)
              compiler_ast_types.AstFieldCleanup.No)
            (compiler_ast_types.ast-field-def-cons
              (compiler_ast_types.ast-field-def-id
                (lower-test-generated-syntax-id "y")
                (compiler_ast_types.AstType.I64)
                compiler_ast_types.AstFieldCleanup.No)
              (compiler_ast_types.ast-field-def-list-new))))
        (compiler_ast_types.ast-decl-cons
          (compiler_ast_types.ast-decl-def-struct-id
            (lower-test-generated-name-id "DeadGeom")
            compiler_ast_types.AstStructRepr.Default
            compiler_ast_types.AstStructCleanup.No
            (compiler_ast_types.ast-field-def-cons
              (compiler_ast_types.ast-field-def-id
                (lower-test-generated-syntax-id "value")
                (compiler_ast_types.AstType.I64)
                compiler_ast_types.AstFieldCleanup.No)
              (compiler_ast_types.ast-field-def-list-new)))
          (compiler_ast_types.ast-decl-cons
            (compiler_ast_types.ast-decl-module-id
              cbi.compiler-builtin-id-fix-main)
            (compiler_ast_types.ast-decl-cons
              (compiler_ast_types.ast-decl-def-fn-id
                cbi.compiler-builtin-id-fix-main
                (compiler_ast_types.ast-param-list-new)
                (compiler_ast_types.AstType.I64)
                (compiler_ast_types.ast-expr-match
                  (compiler_ast_types.ast-node-push
                    (compiler_ast_types.AstExpr.Literal
                      (compiler_ast_types.ast-lit-int 0)))
                  (compiler_ast_types.ast-match-arm-cons
                    (compiler_ast_types.ast-match-arm
                      (compiler_ast_types.ast-pat-variant-id
                        (compiler_load.compiler-load-parse-context-name-id
                          "geom.QPoint")
                        (compiler_ast_types.ast-pattern-cons
                          (compiler_ast_types.ast-pat-binding-id
                            (lower-test-generated-name-id "x"))
                          (compiler_ast_types.ast-pattern-cons
                            (compiler_ast_types.ast-pat-binding-id
                              (lower-test-generated-name-id "y"))
                            (compiler_ast_types.ast-pattern-list-new))))
                      (compiler_ast_types.ast-node-push
                        (compiler_ast_types.AstExpr.Literal
                          (compiler_ast_types.ast-lit-int 0))))
                    (compiler_ast_types.ast-match-arm-list-new))))
              (compiler_ast_types.ast-decl-list-new))))))))

(define (compiler-lower-type-decl-dce-body-pattern-paths) : compiler_ast_types.AstDeclPathList
  (let
    [geom-id : i64 (compiler_load.compiler-load-source-path-id "geom.tl")]
    [entry-id : i64 (compiler_load.compiler-load-source-path-id "entry.tl")]
    (compiler_ast_types.ast-decl-path-cons-with-owner-id
      "geom.tl"
      geom-id
      (compiler_ast_types.ast-decl-path-cons-with-owner-id
        "geom.tl"
        geom-id
        (compiler_ast_types.ast-decl-path-cons-with-owner-id
          "geom.tl"
          geom-id
          (compiler_ast_types.ast-decl-path-cons-with-owner-id
            "entry.tl"
            entry-id
            (compiler_ast_types.ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (compiler_ast_types.ast-decl-path-list-new))))))))

(define (compiler-lower-ast-dce-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram (compiler-lower-ast-dce-program)]
    [no-main-program : compiler_ast_types.AstProgram
      (compiler-lower-ast-dce-no-main-program)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (compiler_ast_types.ast-decl-path-list-new)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [no-main-names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view no-main-program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (compiler_ast_types.ast-decl-path-list-new)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (compiler_ast_types.ast-decl-path-list-new)
        names)]
    [no-main-pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        no-main-program
        (compiler_ast_types.ast-decl-path-list-new)
        no-main-names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match no-main-pruned
          [(compiler_lower.LowerPrunedProgram.Program kept-no-main _)
            (match kept-program
              [(compiler_ast_types.AstProgram.Program kept-box)
                (let
                  [kept : compiler_ast_types.AstDeclList
                    (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
                  (match kept-no-main
                    [(compiler_ast_types.AstProgram.Program no-main-kept-box)
                      (let
                        [no-main-kept : compiler_ast_types.AstDeclList
                          (compiler_ast_types.ast-decl-list-box-shared-view
                            no-main-kept-box)]
                        (and
                          (=
                            (lower-test-decl-list-count
                              (owned_view.compiler-owned-shared-view kept))
                            4)
                          (lower-test-decl-list-defines?
                            (owned_view.compiler-owned-shared-view kept)
                            "main")
                          (lower-test-decl-list-defines?
                            (owned_view.compiler-owned-shared-view kept)
                            "helper")
                          (lower-test-decl-list-defines?
                            (owned_view.compiler-owned-shared-view kept)
                            "callback-target")
                          (not
                            (lower-test-decl-list-defines?
                              (owned_view.compiler-owned-shared-view kept)
                              "dead"))
                          (= (lower-test-decl-list-count no-main-kept) 2)))]))])])])))

(define (compiler-lower-type-decl-dce-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler-lower-type-decl-dce-program)]
    [paths : compiler_ast_types.AstDeclPathList
      (compiler-lower-type-decl-dce-paths)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (=
                  (lower-test-decl-list-count
                    (owned_view.compiler-owned-shared-view kept))
                  3)
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "UsedBox")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "UsedEnum")
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "DeadBox"))
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "DeadEnum"))))])])))

(define (compiler-lower-type-decl-dce-qualified-base-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler-lower-type-decl-dce-qualified-base-program)]
    [paths : compiler_ast_types.AstDeclPathList
      (compiler-lower-type-decl-dce-qualified-base-paths)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (=
                  (lower-test-decl-list-count
                    (owned_view.compiler-owned-shared-view kept))
                  2)
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "io.ResultIoString")
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "io.DeadResult"))))])])))

(define (compiler-lower-type-decl-dce-arena-support-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler-lower-type-decl-dce-arena-support-program)]
    [paths : compiler_ast_types.AstDeclPathList
      (compiler-lower-type-decl-dce-arena-support-paths)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "ThreadBox")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "Arena")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "ArenaMark")
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "DeadArenaPeer"))))])])))

(define (compiler-lower-type-decl-dce-test-body-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler-lower-type-decl-dce-test-body-program)]
    [paths : compiler_ast_types.AstDeclPathList
      (compiler-lower-type-decl-dce-test-body-paths)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (=
                  (lower-test-decl-list-count
                    (owned_view.compiler-owned-shared-view kept))
                  3)
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "ImportedMark")
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "DeadMark"))))])])))

(define (compiler-lower-type-decl-dce-body-pattern-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler-lower-type-decl-dce-body-pattern-program)]
    [paths : compiler_ast_types.AstDeclPathList
      (compiler-lower-type-decl-dce-body-pattern-paths)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "QPoint")
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "DeadGeom"))))])])))

(define (compiler-lower-macro-body-dce-ok?) : bool
  (let
    [program : compiler_ast_types.AstProgram
      (compiler-lower-macro-body-dce-program)]
    [names : compiler_lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            (compiler_lower.lower-name-env-from-decls
              decls
              (compiler_ast_types.ast-decl-path-list-new)
              "entry.tl"
              compiler_lower.LowerNameEnv.Nil))])]
    [pruned : compiler_lower.LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (compiler_ast_types.ast-decl-path-list-new)
        names)]
    (match pruned
      [(compiler_lower.LowerPrunedProgram.Program kept-program _)
        (match kept-program
          [(compiler_ast_types.AstProgram.Program kept-box)
            (let
              [kept : compiler_ast_types.AstDeclList
                (compiler_ast_types.ast-decl-list-box-shared-view kept-box)]
              (and
                (=
                  (lower-test-decl-list-count
                    (owned_view.compiler-owned-shared-view kept))
                  2)
                (lower-test-decl-list-defines?
                  (owned_view.compiler-owned-shared-view kept)
                  "main")
                (not
                  (lower-test-decl-list-defines?
                    (owned_view.compiler-owned-shared-view kept)
                    "macro-only-helper"))))])])))

(define (compiler-lower-stdlib-comptime-runtime-dce-ok?) : bool
  (match (lower-compiler-program-with-decl-paths
    "entry.tl"
    (compiler-lower-stdlib-comptime-runtime-dce-program)
    (compiler_ast_types.ast-decl-path-list-new))
    [(compiler_lower.ResultCompilerLower.Ok lowered _)
      (match lowered
        [(compiler_ir_types.CompilerIrProgram.Program _ functions externs)
          (and
            (=
              (compiler_ir_types.compiler-ir-function-seq-count
                (compiler_ir_types.compiler-ir-global-shared-view functions))
              1)
            (= (compiler_ir_types.compiler-ir-extern-seq-count externs) 0)
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "main"))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-unsafe-ast-dce-kept-ok?
  [kept : compiler_ast_types.AstDeclList]) : bool
  (and
    (=
      (lower-test-decl-list-count (owned_view.compiler-owned-shared-view kept))
      3)
    (lower-test-decl-list-defines?
      (owned_view.compiler-owned-shared-view kept)
      "main")
    (lower-test-decl-list-defines?
      (owned_view.compiler-owned-shared-view kept)
      "unsafe-helper")
    (lower-test-decl-list-defines?
      (owned_view.compiler-owned-shared-view kept)
      "unsafe-entry")
    (not
      (lower-test-decl-list-defines?
        (owned_view.compiler-owned-shared-view kept)
        "dead-helper"))
    (not (lower-test-decl-list-defines? kept "dead-unsafe"))))

(define (compiler-lower-unsafe-ast-dce-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    (compiler-lower-unsafe-ast-dce-source))
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match (owned_view.compiler-owned-shared-view program)
        [(compiler_ast_types.AstProgram.Program decls-box)
          (let
            [decls : compiler_ast_types.AstDeclList
              (compiler_ast_types.ast-decl-list-box-shared-view decls-box)]
            [names : compiler_lower.LowerNameEnv
              (compiler_lower.lower-name-env-from-decls
                decls
                (compiler_ast_types.ast-decl-path-list-new)
                "entry.tl"
                compiler_lower.LowerNameEnv.Nil)]
            [pruned : compiler_lower.LowerPrunedProgram
              (lower-test-prune-unreachable-functions
                "entry.tl"
                program
                (compiler_ast_types.ast-decl-path-list-new)
                names)]
            (match pruned
              [(compiler_lower.LowerPrunedProgram.Program kept-program _)
                (match kept-program
                  [(compiler_ast_types.AstProgram.Program kept-box)
                    (compiler-lower-unsafe-ast-dce-kept-ok?
                      (compiler_ast_types.ast-decl-list-box-shared-view
                        kept-box))])]))])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-lower-name-env-dense-snapshots-ok?) : bool
  (let
    [lower-state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
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
    [base : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        source-id
        base-logical-id
        base-symbol-id
        compiler_lower.LowerNameEnv.Nil)]
    [child : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        source-id
        child-logical-id
        child-symbol-id
        (compiler_lower.lower-global-shared-view base))]
    [sibling : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        sibling-id
        sibling-id
        sibling-symbol-id
        (compiler_lower.lower-global-shared-view base))]
    [grown : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        source-id
        child-logical-id
        grown-symbol-id
        (compiler_lower.lower-global-shared-view child))]
    [grow-index : i64 1]
    [_grow : unit
      (while (< grow-index 16)
        (begin
          (set!
            grown
            (compiler_lower.lower-name-env-bind-logical-symbol-id
              source-id
              child-logical-id
              grown-symbol-id
              grown))
          (set! grow-index (+ grow-index 1))))]
    [copied : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-copy-active
        (compiler_lower.lower-global-shared-view child))]
    [copy-branch : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        source-id
        source-id
        copy-branch-symbol-id
        (compiler_lower.lower-global-shared-view copied))]
    [right : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        alias-id
        alias-id
        right-symbol-id
        compiler_lower.LowerNameEnv.Nil)]
    [left : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-symbol-id
        alias-id
        alias-id
        left-new-symbol-id
        (compiler_lower.lower-name-env-bind-logical-symbol-id
          alias-id
          alias-id
          left-old-symbol-id
          compiler_lower.LowerNameEnv.Nil))]
    [appended : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-append
        (compiler_lower.lower-global-shared-view left)
        (compiler_lower.lower-global-shared-view right))]
    [previous-global : compiler_lower.LowerNameCache
      (compiler_lower.lower-active-global-name-cache-current lower-state)]
    [_set-global : unit
      (compiler_lower.lower-active-global-name-cache-set!
        lower-state
        (compiler_lower.lower-name-cache-from-env
          lower-state
          (compiler_lower.lower-global-shared-view base)))]
    [overlay : compiler_lower.LowerNameCache
      (compiler_lower.lower-name-cache-overlay
        lower-state
        (compiler_lower.lower-name-env-bind-logical-symbol-id
          overlay-id
          overlay-id
          overlay-symbol-id
          compiler_lower.LowerNameEnv.Nil)
        (ci.intern-generated-canonical-name "dense-overlay-module"))]
    [ok : bool
      (and
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view base))
          1)
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view child))
          2)
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view sibling))
          2)
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view grown))
          18)
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view copied))
          2)
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view copy-branch))
          3)
        (=
          (compiler_lower.lower-name-env-count
            (compiler_lower.lower-global-shared-view appended))
          3)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view base)
            source-id
            -1)
          base-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view child)
            source-id
            -1)
          child-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view sibling)
            source-id
            -1)
          base-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view grown)
            source-id
            -1)
          grown-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view sibling)
            sibling-id
            -1)
          sibling-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view copied)
            source-id
            -1)
          child-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view copy-branch)
            source-id
            -1)
          copy-branch-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view appended)
            alias-id
            -1)
          left-new-symbol-id)
        (=
          (compiler_lower.lower-name-env-lookup-symbol-id
            (compiler_lower.lower-global-shared-view right)
            alias-id
            -1)
          right-symbol-id)
        (string.eq
          (compiler_typecheck_core.tc-env-key-name-text
            (compiler_lower.lower-name-env-lookup-symbol-id
              (compiler_lower.lower-global-shared-view copied)
              source-id
              -1))
          (compiler_typecheck_core.tc-env-key-name-text child-symbol-id))
        (=
          (compiler_lower.lower-name-cache-lookup-symbol-id
            (& overlay)
            overlay-id
            -1)
          overlay-symbol-id)
        (=
          (compiler_lower.lower-name-cache-lookup-symbol-id
            (& overlay)
            source-id
            -1)
          base-symbol-id)
        (match (compiler_lower.lower-name-env-view
          (compiler_lower.lower-global-shared-view child))
          [(compiler_lower.LowerNameEnvView.Bind head-source _ head-symbol rest)
            (and
              (= head-source source-id)
              (= head-symbol child-symbol-id)
              (match (compiler_lower.lower-name-env-view rest)
                [(compiler_lower.LowerNameEnvView.Bind
                    tail-source
                    _
                    tail-symbol
                    tail)
                  (and
                    (= tail-source source-id)
                    (= tail-symbol base-symbol-id)
                    (match tail
                      [(compiler_lower.LowerNameEnv.Nil) true]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    (begin
      (compiler_lower.lower-active-global-name-cache-set!
        lower-state
        previous-global)
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
  [session : cis.InternStructuralSessionHandle]
  [expr-bases : i64]
  [tree : compiler_ast_types.AstExpr]
  [when-id : i64]
  [unless-id : i64]) : bool
  (=
    (compiler_typecheck_core.tc-expr-uses-free-source-id?
      session
      expr-bases
      (compiler_ast_types.ast-global-shared-view tree)
      when-id
      unless-id
      compiler_typecheck_core.TcNameIdList.Nil)
    (or
      (compiler_typecheck_core.tc-expr-uses-free-name?
        expr-bases
        (compiler_ast_types.ast-global-shared-view tree)
        "when"
        compiler_typecheck_core.TcStringList.Nil)
      (compiler_typecheck_core.tc-expr-uses-free-name?
        expr-bases
        (compiler_ast_types.ast-global-shared-view tree)
        "unless"
        compiler_typecheck_core.TcStringList.Nil))))

(define (compiler-lower-compat-prescan-test-let
  [binder-id : i64]
  [init-id : i64]
  [body-id : i64]) : compiler_ast_types.AstExpr
  (let
    [bindings : compiler_ast_types.AstLetBindingList
      (compiler_ast_types.ast-let-binding-list-with-capacity 1)]
    (begin
      (set!
        (array-ref bindings.slots 0)
        (compiler_ast_types.AstLetBinding.Binding
          binder-id
          (compiler_ast_types.AstMaybeType.No)
          init-id))
      (set! bindings.len 1)
      (compiler_ast_types.AstExpr.Let
        (box (compiler_ast_types.AstLet.Let bindings body-id))))))

(define (compiler-lower-compat-prescan-id-parity-ok?) : bool
  (let
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 4 1)]
    [expr-bases : i64
      (compiler_ast_types.ast-node-pool-context-expr-segment-bases pools)]
    [when-id : i64 (ci.intern "when")]
    [unless-id : i64 (ci.intern "unless")]
    [x-id : i64 (ci.intern "x")]
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-state))]
    [hygiene-ctx : compiler_typecheck_core.MacroHygieneContext
      (compiler_typecheck_core.MacroHygieneContext
        (ci.intern "test-macro")
        (ci.intern "test-module")
        1360
        (compiler_symbols.compiler-symbols-empty))]
    [hyg-when-id : i64
      (compiler_typecheck_core.macro-hygiene-local-id
        session
        (owned_view.compiler-owned-shared-view hygiene-ctx)
        1
        when-id)]
    [hyg-x-id : i64
      (compiler_typecheck_core.macro-hygiene-local-id
        session
        hygiene-ctx
        1
        x-id)]
    [struct-when-id : i64 (ci.intern-structural-local-id 1 when-id)]
    [composite-id : i64
      (compiler_typecheck_core.tc-module-name-id-by-id
        (ci.intern "stdlib.io")
        when-id)]
    [when-var : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstExpr.Var when-id))]
    [hyg-when-var : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstExpr.Var hyg-when-id))]
    [x-var : i64
      (compiler_ast_types.ast-node-pool-context-expr-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstExpr.Var x-id))]
    (and
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler_ast_types.AstExpr.Var when-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler_ast_types.AstExpr.Var x-id)
        when-id
        unless-id)
      (compiler_typecheck_core.tc-expr-uses-free-source-id?
        session
        expr-bases
        (compiler_ast_types.AstExpr.Var hyg-when-id)
        when-id
        unless-id
        compiler_typecheck_core.TcNameIdList.Nil)
      (not
        (compiler_typecheck_core.tc-expr-uses-free-source-id?
          session
          expr-bases
          (compiler_ast_types.AstExpr.Var hyg-x-id)
          when-id
          unless-id
          compiler_typecheck_core.TcNameIdList.Nil))
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler_ast_types.AstExpr.Var struct-when-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler_ast_types.AstExpr.Var composite-id)
        when-id
        unless-id)
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler_ast_types.AstExpr.Var unless-id)
        when-id
        unless-id)
      ;; A pool binder named `when` shadows a pool use of `when`.
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler-lower-compat-prescan-test-let when-id x-var when-var)
        when-id
        unless-id)
      ;; A differently-named binder does not shadow the use.
      (compiler-lower-compat-prescan-id-parity?
        session
        expr-bases
        (compiler-lower-compat-prescan-test-let x-id x-var when-var)
        when-id
        unless-id)
      ;; A pool binder named `when` also shadows a hygiene-id use whose
      ;; source name is `when` (the post-splice re-run shape).
      (not
        (compiler_typecheck_core.tc-expr-uses-free-source-id?
          session
          expr-bases
          (compiler-lower-compat-prescan-test-let when-id x-var hyg-when-var)
          when-id
          unless-id
          compiler_typecheck_core.TcNameIdList.Nil))
      ;; A hygiene binder whose source name is `when` shadows the hygiene
      ;; use (the string walker cannot see this shape: intern-str traps on
      ;; out-of-pool ids, so check the id walker directly).
      (not
        (compiler_typecheck_core.tc-expr-uses-free-source-id?
          session
          expr-bases
          (compiler-lower-compat-prescan-test-let
            hyg-when-id
            x-var
            hyg-when-var)
          when-id
          unless-id
          compiler_typecheck_core.TcNameIdList.Nil)))))

(test
  compiler-lower-compat-prescan-id-parity
  (test.assert-true
    (compiler-lower-compat-prescan-id-parity-ok?)
    "id-keyed compat prescan matches the string-keyed walks incl. hygiene ids"))

(define (compiler-lower-macro-structural-growth-ok?) : bool
  (let
    [intern-state : ci.InternCompatState (ci.intern-compat-state-new)]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-state))]
    [definition : cis.InternMacroDefinitionIdentity
      (cis.intern-structural-session-macro-definition-identity session 1 2)]
    [index : i64 0]
    [last : i64 -1]
    (begin
      (while (< index 600)
        (begin
          (set!
            last
            (cis.intern-macro-local-identity-raw
              (cis.intern-structural-session-macro-local-identity
                session
                definition
                index
                3)))
          (set! index (+ index 1))))
      (set!
        last
        (cis.intern-macro-local-identity-raw
          (cis.intern-structural-session-macro-local-identity
            session
            definition
            7
            3)))
      (and
        (> last 0)
        (= (ci.intern-compat-state-structural-count intern-state) 601)))))

(test
  compiler-lower-macro-structural-growth
  (test.assert-true
    (compiler-lower-macro-structural-growth-ok?)
    "macro structural records grow beyond the first record slab"))

;; The standalone adapter resets the active intern generation after constructing
;; its lower carrier. Cleanup synthesis must use the refreshed post-reset view;
;; publishing a pre-reset snapshot would invalidate the active builtin IDs.
(define (compiler-lower-standalone-cleanup-owner-refresh-ok?) : bool
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (compiler-lower-cleanup-struct-shape-ok?)
      (begin
        (cbi.compiler-builtin-refresh!)
        true)
      false)))

(test
  compiler-lower-standalone-cleanup-owner-refresh
  (test.assert-true
    (compiler-lower-standalone-cleanup-owner-refresh-ok?)
    "standalone cleanup lowering preserves post-reset intern/builtin ownership"))

;; Lowerer-owned synthesis must select its compile job's capabilities even
;; while a different job is installed as the serial compatibility decoy.
(define (compiler-lower-cleanup-owner-interleaving-ok?) : bool
  (let
    [active-intern-before : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [active-pools-before : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [module-a : i64 (ci.intern-compat-state-intern (&mut intern-a) "owner-a")]
    [cleanup-a : i64
      (ci.intern-compat-state-intern (&mut intern-a) "cleanup-a")]
    [_module-b : i64 (ci.intern-compat-state-intern (&mut intern-b) "decoy-b")]
    [_cleanup-b : i64
      (ci.intern-compat-state-intern (&mut intern-b) "cleanup-b")]
    [pools-a : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 8 1)]
    [pools-b : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 8 1)]
    [lower-a : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (owned_view.compiler-owned-shared-view intern-a))]
    [generated-b-before : i64 (ci.intern-compat-state-generated-count intern-b)]
    [expr-b-before : i64
      (compiler_ast_types.ast-node-pool-context-expr-len pools-b)]
    [ok : bool false]
    (begin
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view intern-b))
      (compiler_ast_types.ast-node-pool-context-install!
        (owned_view.compiler-owned-shared-view pools-b))
      (let
        [_active-generated-b : i64
          (ci.intern-compat-state-generated-name
            (&mut intern-b)
            "decoy-generated-b")]
        [generated-b-after : i64
          (ci.intern-compat-state-generated-count intern-b)]
        [param-a : i64
          (compiler_lower.lower-struct-cleanup-param-id
            (owned_view.compiler-owned-shared-view lower-a))]
        [param-again-a : i64
          (compiler_lower.lower-struct-cleanup-param-id
            (owned_view.compiler-owned-shared-view lower-a))]
        [payload-a : i64
          (compiler_lower.lower-enum-cleanup-payload-id
            (owned_view.compiler-owned-shared-view lower-a)
            0)]
        [payload-again-a : i64
          (compiler_lower.lower-enum-cleanup-payload-id
            (owned_view.compiler-owned-shared-view lower-a)
            0)]
        [qualified-a : i64
          (ci.intern-compat-state-generated-canonical-qualified-name
            (&mut intern-a)
            "owner-a/cleanup-a"
            module-a
            cleanup-a)]
        [_enum-call-a : i64
          (compiler_lower.lower-enum-cleanup-call-expr
            (owned_view.compiler-owned-shared-view pools-a)
            cleanup-a
            payload-a)]
        [_struct-call-a : i64
          (compiler_lower.lower-struct-cleanup-call-expr
            (owned_view.compiler-owned-shared-view pools-a)
            cleanup-a
            param-a
            cleanup-a)]
        [lower-a-interns : ci.InternCompatState
          (compiler_lower.compiler-lower-state-interns
            (owned_view.compiler-owned-shared-view lower-a))]
        (set!
          ok
          (and
            (=
              (ci.intern-compat-state-table-id (& lower-a-interns))
              (ci.intern-compat-state-table-id intern-a))
            (= param-a param-again-a)
            (= payload-a payload-again-a)
            (= (ci.intern-compat-state-generated-count intern-a) 3)
            (=
              (ci.intern-compat-state-generated-count intern-b)
              generated-b-after)
            (= generated-b-after (+ generated-b-before 1))
            (= (ci.intern-generated-count) generated-b-after)
            (string.eq
              (ci.intern-compat-state-str intern-a param-a)
              "__tl_cleanup_value")
            (string.eq
              (ci.intern-compat-state-str intern-a payload-a)
              "__tl_cleanup_payload_0")
            (ci.intern-compat-state-qualified? intern-a qualified-a)
            (=
              (ci.intern-compat-state-qualified-module-id intern-a qualified-a)
              module-a)
            (=
              (ci.intern-compat-state-qualified-base-id intern-a qualified-a)
              cleanup-a)
            (= (compiler_ast_types.ast-node-pool-context-expr-len pools-a) 7)
            (=
              (compiler_ast_types.ast-node-pool-context-expr-len pools-b)
              expr-b-before))))
      (ci.intern-compat-state-install! active-intern-before)
      (compiler_ast_types.ast-node-pool-context-install! active-pools-before)
      (compiler_ast_types.ast-node-pool-context-destroy-storage! pools-a)
      (compiler_ast_types.ast-node-pool-context-destroy-storage! pools-b)
      (unsafe
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-a))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-b)))
      ok)))

(test
  compiler-lower-cleanup-owner-interleaving
  (test.assert-true
    (compiler-lower-cleanup-owner-interleaving-ok?)
    "cleanup synthesis mutates only its explicit intern and AST-pool owners"))

(define (compiler-lower-comptime-error-test-builtins
  [intern-state : ci.InternCompatState]
  [comptime-id : i64]
  [comptime-error-id : i64]
  [bare-id : i64]
  [stdlib-comptime-id : i64]
  [stdlib-error-id : i64]) : cbi.CompilerBuiltinIdsState
  (let
    [state : cbi.CompilerBuiltinIdsState (cbi.state-new)]
    (begin
      (cbi.state-set-generation!
        (&mut state)
        (ci.intern-compat-state-generation intern-state))
      (cbi.state-set-metadata!
        (&mut state)
        (ci.intern-compat-state-table-id intern-state)
        (ci.intern-compat-state-pool-len intern-state)
        true)
      (cbi.state-set! (&mut state) 90 comptime-id)
      (cbi.state-set! (&mut state) 91 comptime-error-id)
      (cbi.state-set! (&mut state) 94 bare-id)
      (cbi.state-set! (&mut state) 149 stdlib-comptime-id)
      (cbi.state-set! (&mut state) 150 stdlib-error-id)
      state)))

;; Cache identity is the pair `(table-id, reset generation)`, not a numeric ID
;; alone. A and B deliberately assign the same raw ID to different strings;
;; the installed third state is a compatibility decoy and must remain untouched.
(define (compiler-lower-comptime-error-cache-owner-isolation-ok?) : bool
  (let
    [active-intern-before : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [active-builtins-before : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-decoy : ci.InternCompatState (ci.intern-compat-state-new)]
    [a-bare : i64
      (ci.intern-compat-state-intern (&mut intern-a) "comptime-error")]
    [a-comptime : i64
      (ci.intern-compat-state-intern (&mut intern-a) "comptime.comptime-error")]
    [a-error : i64
      (ci.intern-compat-state-intern (&mut intern-a) "comptime.error")]
    [a-stdlib-comptime : i64
      (ci.intern-compat-state-intern
        (&mut intern-a)
        "stdlib.comptime.comptime-error")]
    [a-stdlib-error : i64
      (ci.intern-compat-state-intern (&mut intern-a) "stdlib.comptime.error")]
    [b-decoy : i64
      (ci.intern-compat-state-intern (&mut intern-b) "owner-b-decoy")]
    [_b-decoy-2 : i64
      (ci.intern-compat-state-intern (&mut intern-b) "owner-b-decoy-2")]
    [_b-decoy-3 : i64
      (ci.intern-compat-state-intern (&mut intern-b) "owner-b-decoy-3")]
    [_b-decoy-4 : i64
      (ci.intern-compat-state-intern (&mut intern-b) "owner-b-decoy-4")]
    [_b-decoy-5 : i64
      (ci.intern-compat-state-intern (&mut intern-b) "owner-b-decoy-5")]
    [b-bare : i64
      (ci.intern-compat-state-intern (&mut intern-b) "comptime-error")]
    [b-comptime : i64
      (ci.intern-compat-state-intern (&mut intern-b) "comptime.comptime-error")]
    [b-error : i64
      (ci.intern-compat-state-intern (&mut intern-b) "comptime.error")]
    [b-stdlib-comptime : i64
      (ci.intern-compat-state-intern
        (&mut intern-b)
        "stdlib.comptime.comptime-error")]
    [b-stdlib-error : i64
      (ci.intern-compat-state-intern (&mut intern-b) "stdlib.comptime.error")]
    [decoy-id : i64
      (ci.intern-compat-state-intern (&mut intern-decoy) "installed-decoy")]
    [builtins-a : cbi.CompilerBuiltinIdsState
      (compiler-lower-comptime-error-test-builtins
        (owned_view.compiler-owned-shared-view intern-a)
        a-comptime
        a-error
        a-bare
        a-stdlib-comptime
        a-stdlib-error)]
    [builtins-b : cbi.CompilerBuiltinIdsState
      (compiler-lower-comptime-error-test-builtins
        (owned_view.compiler-owned-shared-view intern-b)
        b-comptime
        b-error
        b-bare
        b-stdlib-comptime
        b-stdlib-error)]
    [builtins-decoy : cbi.CompilerBuiltinIdsState
      (compiler-lower-comptime-error-test-builtins
        (owned_view.compiler-owned-shared-view intern-decoy)
        decoy-id
        decoy-id
        decoy-id
        decoy-id
        decoy-id)]
    [lower-a : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (owned_view.compiler-owned-shared-view intern-a))]
    [lower-b : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (owned_view.compiler-owned-shared-view intern-b))]
    [initial-a : compiler_lower.CompilerLowerStateObservation
      (compiler_lower.compiler-lower-state-observe
        (owned_view.compiler-owned-shared-view lower-a))]
    [ok : bool false]
    (begin
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view intern-decoy))
      (cbi.state-install! builtins-decoy)
      (compiler_lower.lower-comptime-error-ids-ensure!
        (owned_view.compiler-owned-shared-view lower-a)
        (owned_view.compiler-owned-shared-view builtins-a))
      (compiler_lower.lower-comptime-error-ids-ensure!
        (owned_view.compiler-owned-shared-view lower-b)
        (owned_view.compiler-owned-shared-view builtins-b))
      (let
        [b-before-reuse : compiler_lower.CompilerLowerStateObservation
          (compiler_lower.compiler-lower-state-observe
            (owned_view.compiler-owned-shared-view lower-b))]
        [old-generation : i64 (ci.intern-compat-state-generation intern-a)]
        (begin
          (compiler_lower.compiler-lower-state-reset!
            (owned_view.compiler-owned-shared-view lower-a))
          (let
            [reset-ok? : bool
              (compiler_lower.compiler-lower-state-reset?
                (owned_view.compiler-owned-shared-view lower-a))]
            (begin
              (ci.intern-compat-state-reset! (&mut intern-a))
              (let
                [_a-new-decoy-1 : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "owner-a-new-decoy-1")]
                [_a-new-decoy-2 : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "owner-a-new-decoy-2")]
                [_a-new-decoy-3 : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "owner-a-new-decoy-3")]
                [_a-new-decoy-4 : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "owner-a-new-decoy-4")]
                [_a-new-decoy-5 : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "owner-a-new-decoy-5")]
                [a-new-bare : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "comptime-error")]
                [a-new-comptime : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "comptime.comptime-error")]
                [a-new-error : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "comptime.error")]
                [a-new-stdlib-comptime : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "stdlib.comptime.comptime-error")]
                [a-new-stdlib-error : i64
                  (ci.intern-compat-state-intern
                    (&mut intern-a)
                    "stdlib.comptime.error")]
                [builtins-a-reused : cbi.CompilerBuiltinIdsState
                  (compiler-lower-comptime-error-test-builtins
                    (owned_view.compiler-owned-shared-view intern-a)
                    a-new-comptime
                    a-new-error
                    a-new-bare
                    a-new-stdlib-comptime
                    a-new-stdlib-error)]
                (begin
                  (compiler_lower.lower-comptime-error-ids-ensure!
                    (owned_view.compiler-owned-shared-view lower-a)
                    builtins-a-reused)
                  (set!
                    ok
                    (and
                      (= a-bare b-decoy)
                      (string.eq
                        (ci.intern-compat-state-str intern-a a-new-bare)
                        "comptime-error")
                      (string.eq
                        (ci.intern-compat-state-str intern-b b-decoy)
                        "owner-b-decoy")
                      (not
                        (compiler_lower.compiler-lower-state-observation-eq?
                          initial-a
                          (compiler_lower.compiler-lower-state-observe
                            (owned_view.compiler-owned-shared-view lower-a))))
                      (compiler_lower.lower-comptime-error-call-id?
                        (owned_view.compiler-owned-shared-view lower-a)
                        a-new-bare)
                      (not
                        (compiler_lower.lower-comptime-error-call-id?
                          (owned_view.compiler-owned-shared-view lower-a)
                          a-bare))
                      (compiler_lower.lower-comptime-error-call-id?
                        (owned_view.compiler-owned-shared-view lower-b)
                        b-bare)
                      (not
                        (compiler_lower.lower-comptime-error-call-id?
                          (owned_view.compiler-owned-shared-view lower-b)
                          b-decoy))
                      reset-ok?
                      (not
                        (=
                          old-generation
                          (ci.intern-compat-state-generation intern-a)))
                      (compiler_lower.compiler-lower-state-observation-eq?
                        b-before-reuse
                        (compiler_lower.compiler-lower-state-observe
                          (owned_view.compiler-owned-shared-view lower-b)))
                      (=
                        (ci.intern-active-table-id)
                        (ci.intern-compat-state-table-id intern-decoy))
                      (=
                        (ci.intern-generation)
                        (ci.intern-compat-state-generation intern-decoy))
                      (= (ci.intern-pool-len) 1)
                      (cbi.compiler-builtin-table-current?)
                      (= cbi.compiler-builtin-id-fix-comptime_error decoy-id)))))))))
      (ci.intern-compat-state-install! active-intern-before)
      (cbi.state-install! active-builtins-before)
      (unsafe
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-a))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-b))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-decoy)))
      ok)))

(test
  compiler-lower-comptime-error-cache-owner-isolation
  (test.assert-true
    (compiler-lower-comptime-error-cache-owner-isolation-ok?)
    "comptime-error caches use explicit intern/builtin owners and reset stamps"))

(define (compiler-lower-boxed-helper-lists-ok?) : bool
  (let
    [source-a-id : i64 (ci.intern-generated-canonical-name "source-a")]
    [source-b-id : i64 (ci.intern-generated-canonical-name "source-b")]
    [names : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-id
        source-a-id
        "logical-a"
        source-a-id
        (compiler_lower.lower-name-env-bind-logical-id
          source-b-id
          "logical-b"
          source-b-id
          compiler_lower.LowerNameEnv.Nil))]
    [captures : compiler_lower.LowerCaptureList
      (compiler_lower.lower-capture-list-add-front
        (compiler_lower.lower-capture-list-add-front
          (compiler_lower.lower-capture-list-empty)
          (compiler_lower.LowerCapture.Capture
            102
            2
            (compiler_ast_types.AstType.Bool)
            8))
        (compiler_lower.LowerCapture.Capture
          101
          1
          (compiler_ast_types.AstType.I64)
          0))]
    [cleanups : compiler_lower.LowerCleanupStack
      (compiler_lower.lower-cleanup-stack-push
        (compiler_lower.lower-cleanup-stack-push
          (compiler_lower.lower-cleanup-stack-empty)
          201
          301)
        202
        302)]
    [slots : compiler_lower.LowerCAbiSlotList
      (compiler_lower.lower-c-abi-slot-list-pair
        (compiler_lower.LowerCAbiSlot.Slot (compiler_ast_types.AstType.I64) 0)
        (compiler_lower.LowerCAbiSlot.Slot (compiler_ast_types.AstType.F64) 8))]
    (and
      (=
        (compiler_lower.lower-name-env-count
          (owned_view.compiler-owned-shared-view names))
        2)
      (string.eq
        (lower-name-env-resolve-with-id names "source-b" source-b-id)
        "logical-b")
      (=
        (lower-capture-list-count
          (owned_view.compiler-owned-shared-view captures))
        2)
      (compiler_lower.lower-capture-list-contains-name?
        (owned_view.compiler-owned-shared-view captures)
        102)
      (lower-capture-list-storage-entry?
        (owned_view.compiler-owned-shared-view captures)
        0
        102
        2
        8)
      (lower-capture-list-storage-entry? captures 1 101 1 0)
      (=
        (lower-cleanup-stack-count
          (owned_view.compiler-owned-shared-view cleanups))
        2)
      (lower-cleanup-stack-entry?
        (owned_view.compiler-owned-shared-view cleanups)
        0
        201
        301)
      (lower-cleanup-stack-entry? cleanups 1 202 302)
      (=
        (compiler_lower.lower-c-abi-slot-list-count
          (compiler_lower.lower-global-shared-view slots))
        2)
      (match (compiler_lower.lower-c-abi-slot-list-ref
        (compiler_lower.lower-global-shared-view slots)
        0)
        [(compiler_lower.LowerCAbiSlot.Slot ty offset)
          (and
            (= offset 0)
            (compiler_typecheck_core.tc-type-eq
              ty
              (compiler_ast_types.AstType.I64)))])
      (match (compiler_lower.lower-c-abi-slot-list-ref
        (compiler_lower.lower-global-shared-view slots)
        1)
        [(compiler_lower.LowerCAbiSlot.Slot ty offset)
          (and
            (= offset 8)
            (compiler_typecheck_core.tc-type-eq
              ty
              (compiler_ast_types.AstType.F64)))]))))

(define (compiler-lower-name-cache-intern-id-dotted-ok?) : bool
  (let
    [lower-state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
    [alias-id : i64 cbi.compiler-builtin-id-fix-alias]
    [value-id : i64 cbi.compiler-builtin-id-fix-value]
    [source-id : i64
      (compiler_symbols.compiler-symbol-module-key-id-by-id alias-id value-id)]
    [logical : String "logical-value"]
    [split-source : String
      (compiler_symbols.compiler-symbol-module-key
        "name_cache_split_alias_3940"
        "name_cache_split_value_3940")]
    [split-source-missing-before : bool
      (match (ci.intern-lookup
        (owned_view.compiler-owned-shared-view split-source))
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    [split-alias-id : i64
      cbi.compiler-builtin-id-fix-name_cache_split_alias_3940]
    [split-value-id : i64
      cbi.compiler-builtin-id-fix-name_cache_split_value_3940]
    [split-source-id : i64
      (compiler_symbols.compiler-symbol-module-key-id-by-id
        split-alias-id
        split-value-id)]
    [split-logical : String "split-logical-value"]
    [names : compiler_lower.LowerNameEnv
      (compiler_lower.lower-name-env-bind-logical-id
        split-source-id
        (owned_view.compiler-owned-shared-view split-logical)
        split-source-id
        (compiler_lower.lower-name-env-bind-logical-id
          source-id
          (owned_view.compiler-owned-shared-view logical)
          source-id
          compiler_lower.LowerNameEnv.Nil))]
    [cache : compiler_lower.LowerNameCache
      (compiler_lower.lower-name-cache-from-env lower-state names)]
    (and
      (>= source-id 0)
      (>= alias-id 0)
      (>= value-id 0)
      split-source-missing-before
      (>= split-alias-id 0)
      (>= split-value-id 0)
      (match (ci.intern-lookup split-source)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])
      (match (compiler_lower.lower-name-cache-resolve-id-display
        (owned_view.compiler-owned-shared-view cache)
        source-id)
        [(compiler_typecheck_core.TcMaybeString.Some resolved)
          (string.eq resolved logical)]
        [(compiler_typecheck_core.TcMaybeString.No) false])
      (match (compiler_lower.lower-name-cache-resolve-id-display
        cache
        split-source-id)
        [(compiler_typecheck_core.TcMaybeString.Some resolved)
          (string.eq resolved split-logical)]
        [(compiler_typecheck_core.TcMaybeString.No) false]))))

(define (compiler-lower-module-phase-cache-storage-ok?) : bool
  (compiler_lower.compiler-lower-module-phase-cache-storage-ok?))

(define (compiler-lower-checked-pools-state-isolation-ok?) : bool
  (compiler_lower.compiler-lower-checked-pools-state-isolation-ok?))

(define (compiler-lower-function-memo-test-write!
  [function-state : compiler_lower.CompilerLowerFunctionState]
  [slot : i64]
  [key : i64]
  [ty : compiler_ast_types.AstType]
  [outcome : compiler_lower.LowerVariantArmResolution]) : unit
  (let
    [storage : compiler_lower.CompilerLowerFunctionMemoStorage
      (compiler_lower.compiler-lower-function-memo-storage
        (compiler_lower.compiler-lower-function-state-owner function-state))]
    (begin
      (set!
        (array-ref storage.rtf-generations slot)
        (compiler_lower.compiler-lower-function-state-rtf-generation
          function-state))
      (set! (array-ref storage.rtf-ids slot) key)
      (set! (array-ref storage.rtf-types slot) ty)
      (set!
        (array-ref storage.variant-stamps slot)
        (compiler_lower.compiler-lower-function-state-variant-generation
          function-state))
      (set! (array-ref storage.variant-keys slot) key)
      (set! (array-ref storage.variant-scrutinee-types slot) ty)
      (set! (array-ref storage.variant-outcomes slot) outcome))))

(define (compiler-lower-function-memo-test-hit?
  [function-state : compiler_lower.CompilerLowerFunctionState]
  [slot : i64]
  [key : i64]
  [ty : compiler_ast_types.AstType]
  [outcome-name : String]) : bool
  (let
    [storage : compiler_lower.CompilerLowerFunctionMemoStorage
      (compiler_lower.compiler-lower-function-memo-storage
        (compiler_lower.compiler-lower-function-state-owner function-state))]
    (and
      (=
        (array-ref storage.rtf-generations slot)
        (compiler_lower.compiler-lower-function-state-rtf-generation
          function-state))
      (= (array-ref storage.rtf-ids slot) key)
      (compiler_ast_types.ast-type-eq?
        (owned_view.compiler-owned-array-element-shared-view
          storage.rtf-types
          slot)
        (owned_view.compiler-owned-shared-view ty))
      (=
        (array-ref storage.variant-stamps slot)
        (compiler_lower.compiler-lower-function-state-variant-generation
          function-state))
      (= (array-ref storage.variant-keys slot) key)
      (compiler_ast_types.ast-type-eq?
        (owned_view.compiler-owned-array-element-shared-view
          storage.variant-scrutinee-types
          slot)
        (owned_view.compiler-owned-shared-view ty))
      (match (owned_view.compiler-owned-array-element-shared-view
        storage.variant-outcomes
        slot)
        [(compiler_lower.LowerVariantArmResolution.Missing name)
          (string.eq name outcome-name)]
        [_ false]))))

;; A and B deliberately reuse the same numeric memo slot/key/generation and
;; fresh-local source ID. The backing arrays are owner-private, while sibling
;; functions in A share backing but use distinct generations so interleaving is
;; an eviction/miss rather than a stale read.
(define (compiler-lower-spmd-function-state-isolation-ok?) : bool
  (let
    [owner-a : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
    [owner-b : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
    [idle-a : i64
      (compiler_lower.compiler-lower-state-function-memo-retained-bytes owner-a)]
    [idle-b : i64
      (compiler_lower.compiler-lower-state-function-memo-retained-bytes owner-b)]
    (begin
      (compiler_lower.compiler-lower-state-set-spmd-package!
        owner-a
        "package-a")
      (compiler_lower.compiler-lower-state-set-spmd-package!
        owner-b
        "package-b")
      (let
        [function-a : compiler_lower.CompilerLowerFunctionState
          (compiler_lower.compiler-lower-function-state-new owner-a)]
        [retained-a : i64
          (compiler_lower.compiler-lower-state-function-memo-retained-bytes
            owner-a)]
        [still-idle-b : i64
          (compiler_lower.compiler-lower-state-function-memo-retained-bytes
            owner-b)]
        [function-a-nested : compiler_lower.CompilerLowerFunctionState
          (compiler_lower.compiler-lower-function-state-new owner-a)]
        [function-b : compiler_lower.CompilerLowerFunctionState
          (compiler_lower.compiler-lower-function-state-new owner-b)]
        [retained-b : i64
          (compiler_lower.compiler-lower-state-function-memo-retained-bytes
            owner-b)]
        [source-id : i64
          (ci.intern-generated-name "lower-function-state-isolation-temp")]
        [symbol : i64 81173]
        [interns-a : ci.InternCompatState
          (compiler_lower.compiler-lower-state-interns owner-a)]
        [interns-b : ci.InternCompatState
          (compiler_lower.compiler-lower-state-interns owner-b)]
        [identity-a : i64
          (ci.intern-compat-state-intern (&mut interns-a) "identity-a")]
        [identity-b : i64
          (ci.intern-compat-state-intern (&mut interns-b) "identity-b")]
        [registered-a : compiler_lower.LowerSpmdPackageSymbolRegistration
          (compiler_lower.lower-spmd-package-symbol-register
            owner-a
            symbol
            symbol
            identity-a)]
        [registered-b : compiler_lower.LowerSpmdPackageSymbolRegistration
          (compiler_lower.lower-spmd-package-symbol-register
            owner-b
            symbol
            symbol
            identity-b)]
        [repeated-b : compiler_lower.LowerSpmdPackageSymbolRegistration
          (compiler_lower.lower-spmd-package-symbol-register
            owner-b
            symbol
            symbol
            identity-b)]
        (begin
          (compiler_lower.compiler-lower-function-state-inline-helper-stack-set!
            function-a
            (compiler_lower.lower-id-set-insert
              (compiler_lower.lower-id-set-empty)
              4242))
          (compiler_lower.compiler-lower-function-state-recursion-detected-set!
            function-a
            true)
          (compiler_lower.compiler-lower-function-state-scalar-call-context-set!
            function-a
            (compiler_lower.LowerSpmdScalarCallContext.Some "lane-a"))
          (let
            [temp-a-0 : i64
              (compiler_lower.compiler-lower-function-state-fresh-local-id!
                function-a
                source-id)]
            [temp-a-1 : i64
              (compiler_lower.compiler-lower-function-state-fresh-local-id!
                function-a
                source-id)]
            [temp-a-nested-0 : i64
              (compiler_lower.compiler-lower-function-state-fresh-local-id!
                function-a-nested
                source-id)]
            [temp-b-0 : i64
              (compiler_lower.compiler-lower-function-state-fresh-local-id!
                function-b
                source-id)]
            [slot : i64 17]
            [key : i64 17017]
            (begin
              (compiler-lower-function-memo-test-write!
                function-a
                slot
                key
                (compiler_ast_types.AstType.I64)
                (compiler_lower.LowerVariantArmResolution.Missing "memo-a"))
              (compiler-lower-function-memo-test-write!
                function-b
                slot
                key
                (compiler_ast_types.AstType.Bool)
                (compiler_lower.LowerVariantArmResolution.Missing "memo-b"))
              (let
                [owners-hit : bool
                  (and
                    (compiler-lower-function-memo-test-hit?
                      function-a
                      slot
                      key
                      (compiler_ast_types.AstType.I64)
                      "memo-a")
                    (compiler-lower-function-memo-test-hit?
                      function-b
                      slot
                      key
                      (compiler_ast_types.AstType.Bool)
                      "memo-b"))]
                (begin
                  (compiler-lower-function-memo-test-write!
                    function-a-nested
                    slot
                    key
                    (compiler_ast_types.AstType.Bool)
                    (compiler_lower.LowerVariantArmResolution.Missing
                      "memo-a-nested"))
                  (let
                    [nested-hit : bool
                      (compiler-lower-function-memo-test-hit?
                        function-a-nested
                        slot
                        key
                        (compiler_ast_types.AstType.Bool)
                        "memo-a-nested")]
                    [outer-evicted : bool
                      (not
                        (compiler-lower-function-memo-test-hit?
                          function-a
                          slot
                          key
                          (compiler_ast_types.AstType.I64)
                          "memo-a"))]
                    [b-still-hit : bool
                      (compiler-lower-function-memo-test-hit?
                        function-b
                        slot
                        key
                        (compiler_ast_types.AstType.Bool)
                        "memo-b")]
                    (begin
                      (compiler_lower.compiler-lower-state-reset! owner-a)
                      (and
                        (= idle-a 0)
                        (= idle-b 0)
                        (> retained-a 0)
                        (= still-idle-b 0)
                        (> retained-b 0)
                        (not (= owner-a.address owner-b.address))
                        (not (= function-a.address function-a-nested.address))
                        (not (= function-a.address function-b.address))
                        (=
                          (compiler_lower.compiler-lower-function-state-rtf-generation
                            function-a)
                          (compiler_lower.compiler-lower-function-state-rtf-generation
                            function-b))
                        (not
                          (=
                            (compiler_lower.compiler-lower-function-state-rtf-generation
                              function-a)
                            (compiler_lower.compiler-lower-function-state-rtf-generation
                              function-a-nested)))
                        (compiler_lower.lower-id-set-contains?
                          (compiler_lower.compiler-lower-function-state-inline-helper-stack
                            function-a)
                          4242)
                        (not
                          (compiler_lower.lower-id-set-contains?
                            (compiler_lower.compiler-lower-function-state-inline-helper-stack
                              function-a-nested)
                            4242))
                        (not
                          (compiler_lower.lower-id-set-contains?
                            (compiler_lower.compiler-lower-function-state-inline-helper-stack
                              function-b)
                            4242))
                        (compiler_lower.compiler-lower-function-state-recursion-detected?
                          function-a)
                        (not
                          (compiler_lower.compiler-lower-function-state-recursion-detected?
                            function-a-nested))
                        (not
                          (compiler_lower.compiler-lower-function-state-recursion-detected?
                            function-b))
                        (match (compiler_lower.compiler-lower-function-state-scalar-call-context
                          function-a)
                          [(compiler_lower.LowerSpmdScalarCallContext.Some lane)
                            (string.eq lane "lane-a")]
                          [_ false])
                        (match (compiler_lower.compiler-lower-function-state-scalar-call-context
                          function-b)
                          [(compiler_lower.LowerSpmdScalarCallContext.No) true]
                          [_ false])
                        (= temp-a-0 temp-a-nested-0)
                        (= temp-a-0 temp-b-0)
                        (not (= temp-a-0 temp-a-1))
                        owners-hit
                        nested-hit
                        outer-evicted
                        b-still-hit
                        (match registered-a
                          [(compiler_lower.LowerSpmdPackageSymbolRegistration.New)
                            true]
                          [_ false])
                        (match registered-b
                          [(compiler_lower.LowerSpmdPackageSymbolRegistration.New)
                            true]
                          [_ false])
                        (match repeated-b
                          [(compiler_lower.LowerSpmdPackageSymbolRegistration.Existing)
                            true]
                          [_ false])
                        (string.eq
                          (compiler_lower.compiler-lower-state-spmd-package-name
                            owner-a)
                          "")
                        (string.eq
                          (compiler_lower.compiler-lower-state-spmd-package-name
                            owner-b)
                          "package-b")
                        (match (compiler_lower.lower-spmd-package-symbol-register
                          owner-b
                          symbol
                          symbol
                          identity-b)
                          [(compiler_lower.LowerSpmdPackageSymbolRegistration.Existing)
                            true]
                          [_ false])
                        (compiler_lower.compiler-lower-state-reset? owner-a)))))))))))))

(define (compiler-lower-spmd-structural-profile-ok?) : bool
  (let
    [state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [_package : unit
      (compiler_lower.compiler-lower-state-set-spmd-package!
        state
        "profile-pkg")]
    [intern-state : ci.InternCompatState
      (compiler_lower.compiler-lower-state-interns state)]
    [canonical : i64
      (ci.intern-compat-state-intern (&mut intern-state) "profile-pkg/helper")]
    [classes : compiler_ast_types.AstSpmdParamClassList
      (compiler_ast_types.ast-spmd-param-class-list-new)]
    [_class : unit
      (compiler_ast_types.ast-spmd-param-class-list-push
        (&mut classes)
        compiler_ast_types.AstSpmdParamClass.Varying)]
    [first : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state
        "profile-pkg"
        "profile-pkg/helper"
        canonical
        "(-> i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        (owned_view.compiler-owned-shared-view classes)
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [repeat : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state
        "profile-pkg"
        "profile-pkg/helper"
        canonical
        "(-> i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        (owned_view.compiler-owned-shared-view classes)
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [expected : String
      (compiler_lower.lower-spmd-package-symbol
        "profile-pkg"
        "profile-pkg/helper"
        "(-> i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        "v"
        "v"
        0)]
    [lazy-before : bool
      (and
        (=
          (string.string-length
            (ci.intern-compat-state-str
              (owned_view.compiler-owned-shared-view intern-state)
              (compiler_lower.lower-spmd-package-structural-identity
                (owned_view.compiler-owned-shared-view intern-state)
                first)))
          0)
        (=
          (string.string-length
            (ci.intern-compat-state-str
              (owned_view.compiler-owned-shared-view intern-state)
              (compiler_lower.lower-spmd-package-structural-linker-symbol
                (owned_view.compiler-owned-shared-view intern-state)
                first)))
          0))]
    (begin
      (compiler_lower.lower-materialize-generated-role-symbols! state)
      (and
        lazy-before
        (=
          (compiler_lower.lower-spmd-package-structural-identity
            (owned_view.compiler-owned-shared-view intern-state)
            first)
          (compiler_lower.lower-spmd-package-structural-identity
            (owned_view.compiler-owned-shared-view intern-state)
            repeat))
        (=
          (compiler_lower.lower-spmd-package-structural-linker-symbol
            (owned_view.compiler-owned-shared-view intern-state)
            first)
          (compiler_lower.lower-spmd-package-structural-linker-symbol
            (owned_view.compiler-owned-shared-view intern-state)
            repeat))
        (=
          (compiler_lower.lower-spmd-package-structural-registration-key
            (owned_view.compiler-owned-shared-view intern-state)
            first)
          (compiler_lower.lower-spmd-package-structural-registration-key
            (owned_view.compiler-owned-shared-view intern-state)
            repeat))
        (string.eq
          (ci.intern-compat-state-str
            (owned_view.compiler-owned-shared-view intern-state)
            (compiler_lower.lower-spmd-package-structural-linker-symbol
              (owned_view.compiler-owned-shared-view intern-state)
              first))
          expected)
        (=
          (compiler_lower.compiler-lower-profile-spmd-identity-serializations-value
            state)
          1)
        (=
          (compiler_lower.compiler-lower-profile-spmd-stable-hash-computations-value
            state)
          1)
        (=
          (compiler_lower.compiler-lower-profile-spmd-render-cache-misses-value
            state)
          1)
        (>=
          (compiler_lower.compiler-lower-profile-spmd-render-cache-hits-value
            state)
          2)))))

(define (compiler-lower-checked-pools-abort-lifecycle-ok?) : bool
  (compiler_lower.compiler-lower-checked-pools-abort-lifecycle-ok?))

(define (compiler-lower-type-cache-i64-keys-ok?) : bool
  (let
    [lower-state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
    [module : String "type_cache_mod_3939"]
    [name : String "TypeCacheThing3939"]
    [module-id : i64
      (ci.intern-generated-name (owned_view.compiler-owned-shared-view module))]
    [name-id : i64
      (ci.intern-generated-name (owned_view.compiler-owned-shared-view name))]
    [qualified-name : String
      (compiler_symbols.compiler-symbol-module-key
        (owned_view.compiler-owned-shared-view module)
        name)]
    [qualified-id : i64
      (compiler_symbols.compiler-symbol-module-key-id-by-id module-id name-id)]
    [fallback-name : String "TypeCacheFallback3939"]
    [fallback-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view fallback-name))]
    [fallback-primary : String
      (compiler_symbols.compiler-symbol-module-key
        module
        (owned_view.compiler-owned-shared-view fallback-name))]
    [fallback-primary-missing-before : bool
      (match (ci.intern-lookup
        (owned_view.compiler-owned-shared-view fallback-primary))
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    [env : compiler_typecheck_core.TcTypeEnv
      (compiler_typecheck_core.tc-bind-id
        (compiler_typecheck_core.tc-bind-id
          (compiler_typecheck_core.tc-empty-env)
          qualified-id
          (compiler_ast_types.AstType.I64))
        fallback-id
        (compiler_ast_types.AstType.Bool))]
    [cache : compiler_lower.LowerTypeCache
      (compiler_lower.lower-type-cache-from-env lower-state env)]
    [missing : String "TypeCacheMissing3939"]
    [missing-id : i64 (+ (ci.intern-capacity) 3939)]
    [missing-before : bool
      (match (ci.intern-lookup (owned_view.compiler-owned-shared-view missing))
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    (and
      (string.eq
        (compiler_typecheck_core.tc-env-key-display
          (compiler_lower.compiler-lower-state-structural-session lower-state)
          qualified-id)
        qualified-name)
      fallback-primary-missing-before
      missing-before
      (match (compiler_lower.lower-type-cache-lookup-id
        (owned_view.compiler-owned-shared-view cache)
        qualified-id
        qualified-name)
        [(compiler_typecheck_core.ResultTcType.Ok ty)
          (compiler_typecheck_core.tc-type-eq
            ty
            (compiler_ast_types.AstType.I64))]
        [(compiler_typecheck_core.ResultTcType.Err _) false])
      (match (compiler_lower.lower-type-cache-lookup-id
        (owned_view.compiler-owned-shared-view cache)
        fallback-id
        fallback-name)
        [(compiler_typecheck_core.ResultTcType.Ok ty)
          (compiler_typecheck_core.tc-type-eq
            ty
            (compiler_ast_types.AstType.Bool))]
        [(compiler_typecheck_core.ResultTcType.Err _) false])
      (match (compiler_lower.lower-type-cache-lookup-id
        cache
        missing-id
        (owned_view.compiler-owned-shared-view missing))
        [(compiler_typecheck_core.ResultTcType.Ok _) false]
        [(compiler_typecheck_core.ResultTcType.Err _) true])
      (match (ci.intern-lookup fallback-primary)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])
      (match (ci.intern-lookup missing)
        [(InternLookupFound _) false]
        [(InternLookupMissing) true]))))

(define (compiler-lower-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-lower-scalar-shift-count-source) : String
  "(define (shift-u8 [value : u64] [count : u8]) : u64
  (shl value count))
(define (shift-u64 [value : u64] [count : u64]) : u64
  (shr value count))
(define (main) : i64
  (let
    [a : u64 (shift-u8 (cast 1 : u64) (cast 1 : u8))]
    [b : u64 (shift-u64 (cast 1 : u64) (cast 1 : u64))]
    (+ (cast a : i64) (cast b : i64))))")

(define (compiler-lower-scalar-shift-count-types-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-scalar-shift-count-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "shift-u8"
                (compiler_ir_types.CompilerIrBinOp.Shl
                  (compiler_ast_types.AstType.U8)))
              1)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "shift-u64"
                (compiler_ir_types.CompilerIrBinOp.Shr
                  (compiler_ast_types.AstType.U64)))
              1)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "shift-u8"
                (compiler_ir_types.CompilerIrBinOp.Shl
                  (compiler_ast_types.AstType.U64)))
              0)
            (=
              (lower-test-function-binop-op-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "shift-u64"
                (compiler_ir_types.CompilerIrBinOp.Shr
                  (compiler_ast_types.AstType.U8)))
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(test
  compiler-lower-scalar-shift-count-types
  (test.assert-true
    (compiler-lower-scalar-shift-count-types-ok?)
    "scalar lowering preserves independent u8/u64 shift count payloads"))

;; Structural borrowed-slice references use two integer words end-to-end while
;; ordinary references retain their one-word pointer representation.  Build the
;; types directly in a private pool so this test does not depend on public Slice
;; syntax (which is intentionally opened in a later packet).
(define (compiler-lower-slice-reference-layout-ok?) : bool
  (let
    [active-before : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 4 16)]
    [elem-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (compiler_ast_types.AstType.I64))]
    [slice-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (compiler_ast_types.AstType.Slice elem-id))]
    [region-slice-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (compiler_ast_types.AstType.Region 7 slice-id))]
    [nested-ref-element-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (compiler_ast_types.AstType.Ref 1 elem-id))]
    [nested-slice-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (compiler_ast_types.AstType.Slice nested-ref-element-id))]
    [ordinary-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (compiler_ast_types.AstType.I64))]
    [ref : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Ref 1 slice-id)]
    [mut-ref : compiler_ast_types.AstType
      (compiler_ast_types.AstType.MutRef 1 region-slice-id)]
    [ordinary-ref : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Ref 1 ordinary-id)]
    [nested-ref : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Ref 1 nested-slice-id)]
    [bare-slice : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Slice elem-id)]
    [ctx : compiler_typecheck_core.TcContext
      (compiler_typecheck_core.tc-context-new
        (compiler_ast_types.ast-program (compiler_ast_types.ast-decl-list-new))
        (compiler_symbols.compiler-symbols-empty)
        (compiler_symbols.compiler-registries-empty)
        ""
        0
        (owned_view.compiler-owned-shared-view pools))]
    [layouts : compiler_ctfe.CtfeLayoutInfoList
      (compiler_ctfe.ctfe-layout-info-list-empty)]
    [ok : bool false]
    (begin
      (compiler_ast_types.ast-node-pool-context-install!
        (owned_view.compiler-owned-shared-view pools))
      (set!
        ok
        (and
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ref))
            16)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ref))
            8)
          (compiler_lower.lower-type-register-resident?
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (owned_view.compiler-owned-shared-view ref))
          (=
            (compiler_lower.lower-type-register-words
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ref))
            2)
          (compiler_typecheck_core.tc-type-eq
            (compiler_lower.lower-register-word-type
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ref)
              0)
            (compiler_ast_types.AstType.U64))
          (compiler_typecheck_core.tc-type-eq
            (compiler_lower.lower-register-word-type
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ref)
              1)
            (compiler_ast_types.AstType.I64))
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view mut-ref))
            16)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view mut-ref))
            8)
          (compiler_lower.lower-type-register-resident?
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (owned_view.compiler-owned-shared-view mut-ref))
          (=
            (compiler_lower.lower-type-register-words
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view mut-ref))
            2)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ordinary-ref))
            8)
          (not
            (compiler_lower.lower-type-register-resident?
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ordinary-ref)))
          (=
            (compiler_lower.lower-type-register-words
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view ordinary-ref))
            0)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view bare-slice))
            0)
          (not
            (compiler_lower.lower-type-register-resident?
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view bare-slice)))
          (compiler_lower.lower-supported-reference-type?
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (owned_view.compiler-owned-shared-view ref))
          (compiler_lower.lower-supported-reference-type?
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (owned_view.compiler-owned-shared-view mut-ref))
          (not
            (compiler_lower.lower-supported-reference-type?
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view bare-slice)))
          (not
            (compiler_lower.lower-supported-reference-type?
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (owned_view.compiler-owned-shared-view nested-ref)))
          (=
            (compiler_ctfe.ctfe-type-size-with-pools
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view layouts)
              (owned_view.compiler-owned-shared-view ref))
            16)
          (=
            (compiler_ctfe.ctfe-type-align-with-pools
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view layouts)
              mut-ref)
            8)
          (=
            (compiler_ctfe.ctfe-type-size-with-pools
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view layouts)
              ordinary-ref)
            8)
          (=
            (compiler_ctfe.ctfe-type-size-with-pools pools layouts bare-slice)
            -1)
          (match (compiler_typecheck_core.tc-inline-aggregate-type-layout
            (compiler_typecheck_core.tc-global-shared-view ctx)
            ref)
            [(compiler_typecheck_core.ResultTcLayoutInfo.Ok info)
              (and
                (= (compiler_typecheck_core.tc-layout-info-size info) 16)
                (= (compiler_typecheck_core.tc-layout-info-align info) 8))]
            [(compiler_typecheck_core.ResultTcLayoutInfo.Err _) false])))
      (compiler_ast_types.ast-node-pool-context-install! active-before)
      ok)))

;; A BoundsCheck lowers to one unsigned `cmpq length, index`, so an operand that
;; is already a width-64 integer is handed to the check directly instead of
;; through a materialised `Cast ... : u64`. `get` therefore keeps exactly ONE
;; cast (the i64 gep-offset conversion) where it used to carry three; the length
;; is loaded as i64 and used as-is.
;;
;; `get-narrow` is the width negative: an i32 index really must be extended, so
;; its u64 cast survives (two casts: the u64 check operand and the i64 gep
;; offset). `plain-cast` is the consumer negative: a width-64 cast that feeds no
;; bounds check is untouched.
(define (compiler-lower-bounds-operand-source) : String
  "(define (get [a : (__tl_dyn-array i64)] [i : i64]) : i64 (array-ref a i))
(define (get-narrow [a : (__tl_dyn-array i64)] [i : i32]) : i64 (array-ref a i))
(define (plain-cast [x : i64]) : u64 (cast x : u64))
(define (main) : i64 0)")

(define (compiler-lower-bounds-operand-counts-ok?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : bool
  (let
    [ok : bool true]
    (begin
      ;; width-64 index and length: the check is still emitted, and the only
      ;; surviving cast is the gep-offset one.
      (if (=
        (lower-test-function-bounds-count
          (compiler_ir_types.compiler-ir-global-shared-view functions)
          "get")
        1)
        unit
        (set! ok false))
      (if (=
        (lower-test-function-cast-count
          (compiler_ir_types.compiler-ir-global-shared-view functions)
          "get")
        1)
        unit
        (set! ok false))
      ;; narrow index: the extension cast is still required.
      (if (=
        (lower-test-function-bounds-count
          (compiler_ir_types.compiler-ir-global-shared-view functions)
          "get-narrow")
        1)
        unit
        (set! ok false))
      (if (=
        (lower-test-function-cast-count
          (compiler_ir_types.compiler-ir-global-shared-view functions)
          "get-narrow")
        2)
        unit
        (set! ok false))
      ;; a width-64 cast with no bounds-check consumer is left alone.
      (if (=
        (lower-test-function-bounds-count
          (compiler_ir_types.compiler-ir-global-shared-view functions)
          "plain-cast")
        0)
        unit
        (set! ok false))
      (if (=
        (lower-test-function-cast-count
          (compiler_ir_types.compiler-ir-global-shared-view functions)
          "plain-cast")
        1)
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-bounds-operand-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-bounds-operand-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (compiler-lower-bounds-operand-counts-ok? functions)])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

;; The pass-through is a fixed point: u64 is itself width-64, so re-applying the
;; operand rule to what the old cast used to produce emits nothing further, and
;; lowering the same source again reaches the identical shape.
(define (compiler-lower-bounds-operand-idempotent-ok?) : bool
  (and
    (compiler_lower.lower-bounds-operand-width-64?
      (compiler_ast_types.AstType.U64))
    (compiler-lower-bounds-operand-shape-ok?)))

(define (compiler-lower-bounds-operand-width-predicate-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.I64))
        unit
        (set! ok false))
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.U64))
        unit
        (set! ok false))
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.I32))
        (set! ok false)
        unit)
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.U32))
        (set! ok false)
        unit)
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.U8))
        (set! ok false)
        unit)
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.F64))
        (set! ok false)
        unit)
      (if (compiler_lower.lower-bounds-operand-width-64?
        (compiler_ast_types.AstType.Bool))
        (set! ok false)
        unit)
      ok)))

;; Anonymous tuples use the same aligned, recursive layout walk as nominal
;; aggregates.  Exercise the layout and the packet-1 internal ABI classifier
;; directly with private pool types so extern C selection can be checked in the
;; same fixture.
(define (compiler-lower-internal-tuple-array-layout-ok?) : bool
  (let
    [active-before : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-new-with-capacities 4 64)]
    [u8-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.U8))]
    [u64-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.U64))]
    [f32-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.F32))]
    [f64-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.F64))]
    [string-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.String))]
    [slice-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.Slice u8-id))]
    [empty-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-new)]
    [u8-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        u8-id
        (compiler_ast_types.ast-type-list-new))]
    [u8-u64-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        u8-id
        (compiler_ast_types.ast-type-list-cons-id
          u64-id
          (compiler_ast_types.ast-type-list-new)))]
    [f32-f32-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        f32-id
        (compiler_ast_types.ast-type-list-cons-id
          f32-id
          (compiler_ast_types.ast-type-list-new)))]
    [u8-f64-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        u8-id
        (compiler_ast_types.ast-type-list-cons-id
          f64-id
          (compiler_ast_types.ast-type-list-new)))]
    [string-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        string-id
        (compiler_ast_types.ast-type-list-new))]
    [slice-ref-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        (compiler_ast_types.ast-node-pool-context-type-push
          (compiler_ast_types.ast-global-shared-view pools)
          (compiler_ast_types.AstType.Ref 1 slice-id))
        (compiler_ast_types.ast-type-list-new))]
    [nested-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.Tuple (box u8-u64-elements)))]
    [array-u8-id : i64
      (compiler_ast_types.ast-node-pool-context-type-push
        (compiler_ast_types.ast-global-shared-view pools)
        (compiler_ast_types.AstType.Array u8-id 3))]
    [nested-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        nested-id
        (compiler_ast_types.ast-type-list-cons-id
          u8-id
          (compiler_ast_types.ast-type-list-new)))]
    [tuple-array-elements : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-cons-id
        array-u8-id
        (compiler_ast_types.ast-type-list-cons-id
          u64-id
          (compiler_ast_types.ast-type-list-new)))]
    [ctx : compiler_typecheck_core.TcContext
      (compiler_typecheck_core.tc-context-new
        (compiler_ast_types.ast-program (compiler_ast_types.ast-decl-list-new))
        (compiler_symbols.compiler-symbols-empty)
        (compiler_symbols.compiler-registries-empty)
        ""
        0
        (compiler_ast_types.ast-global-shared-view pools))]
    [empty : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box empty-elements))]
    [u8-tuple : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box u8-elements))]
    [u8-u64 : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box u8-u64-elements))]
    [f32-f32 : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box f32-f32-elements))]
    [u8-f64 : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box u8-f64-elements))]
    [nested : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box nested-elements))]
    [tuple-array : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box tuple-array-elements))]
    [tuple-string : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box string-elements))]
    [array-string : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Array string-id 2)]
    [slice-ref-tuple : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Tuple (box slice-ref-elements))]
    [array-u8 : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Array u8-id 3)]
    [array-nested : compiler_ast_types.AstType
      (compiler_ast_types.AstType.Array nested-id 2)]
    [ok : bool false]
    (begin
      (compiler_ast_types.ast-node-pool-context-install!
        (compiler_ast_types.ast-global-shared-view pools))
      (set!
        ok
        (and
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view empty))
            0)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view empty))
            1)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view u8-tuple))
            1)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view u8-tuple))
            1)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view u8-u64))
            16)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view u8-u64))
            8)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view f32-f32))
            8)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view f32-f32))
            4)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view nested))
            24)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view nested))
            8)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view array-u8))
            3)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view array-u8))
            1)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view array-nested))
            32)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view array-nested))
            8)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view tuple-array))
            16)
          (=
            (compiler_lower.lower-type-align
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view tuple-array))
            8)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view tuple-string))
            8)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view array-string))
            16)
          (=
            (compiler_lower.lower-type-size
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view slice-ref-tuple))
            16)
          (compiler_lower.lower-type-inline-storage?
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_ast_types.ast-global-shared-view u8-u64))
          (not
            (compiler_lower.lower-type-register-resident?
              (compiler_typecheck_core.tc-global-shared-view ctx)
              (compiler_ast_types.ast-global-shared-view u8-u64)))
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view u8-tuple))
            [(compiler_lower.LowerCAbiAggregate.Register slots size)
              (and
                (= size 1)
                (=
                  (compiler_lower.lower-c-abi-slot-list-count
                    (compiler_lower.lower-global-shared-view slots))
                  1)
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  0)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U8))]))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view f32-f32))
            [(compiler_lower.LowerCAbiAggregate.Register slots size)
              (and
                (= size 8)
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  0)
                  [(compiler_lower.LowerCAbiSlot.Slot ty offset)
                    (and
                      (= offset 0)
                      (compiler_typecheck_core.tc-type-eq
                        ty
                        (compiler_ast_types.AstType.F64)))]))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view u8-f64))
            [(compiler_lower.LowerCAbiAggregate.Register slots size)
              (and
                (= size 16)
                (=
                  (compiler_lower.lower-c-abi-slot-list-count
                    (compiler_lower.lower-global-shared-view slots))
                  2)
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  0)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U64))])
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  1)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.F64))]))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view tuple-string))
            [(compiler_lower.LowerCAbiAggregate.Register slots size)
              (and
                (= size 8)
                (=
                  (compiler_lower.lower-c-abi-slot-list-count
                    (compiler_lower.lower-global-shared-view slots))
                  1)
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  0)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U64))]))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view array-string))
            [(compiler_lower.LowerCAbiAggregate.Register slots size)
              (and
                (= size 16)
                (=
                  (compiler_lower.lower-c-abi-slot-list-count
                    (compiler_lower.lower-global-shared-view slots))
                  2)
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  0)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U64))])
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  1)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U64))]))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view array-nested))
            [(compiler_lower.LowerCAbiAggregate.Memory size) (= size 32)]
            [_ false])
          (match (compiler_lower.lower-internal-return-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view array-nested))
            [(compiler_lower.LowerCAbiAggregate.Sret size) (= size 32)]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.WindowsScalar)
            (compiler_ast_types.ast-global-shared-view array-u8))
            [(compiler_lower.LowerCAbiAggregate.ByRef size) (= size 3)]
            [_ false])
          (match (compiler_lower.lower-internal-return-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.WindowsScalar)
            (compiler_ast_types.ast-global-shared-view array-u8))
            [(compiler_lower.LowerCAbiAggregate.Sret size) (= size 3)]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.WindowsScalar)
            (compiler_ast_types.ast-global-shared-view tuple-string))
            [(compiler_lower.LowerCAbiAggregate.Integer ty size)
              (and
                (= size 8)
                (compiler_typecheck_core.tc-type-eq
                  ty
                  (compiler_ast_types.AstType.U64)))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view slice-ref-tuple))
            [(compiler_lower.LowerCAbiAggregate.Register slots size)
              (and
                (= size 16)
                (=
                  (compiler_lower.lower-c-abi-slot-list-count
                    (compiler_lower.lower-global-shared-view slots))
                  2)
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  0)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U64))])
                (match (compiler_lower.lower-c-abi-slot-list-ref
                  (compiler_lower.lower-global-shared-view slots)
                  1)
                  [(compiler_lower.LowerCAbiSlot.Slot ty _)
                    (compiler_typecheck_core.tc-type-eq
                      ty
                      (compiler_ast_types.AstType.U64))]))]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.WindowsScalar)
            (compiler_ast_types.ast-global-shared-view u8-u64))
            [(compiler_lower.LowerCAbiAggregate.ByRef size) (= size 16)]
            [_ false])
          (match (compiler_lower.lower-internal-return-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.WindowsScalar)
            (compiler_ast_types.ast-global-shared-view u8-u64))
            [(compiler_lower.LowerCAbiAggregate.Sret size) (= size 16)]
            [_ false])
          (match (compiler_lower.lower-internal-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view empty))
            [(compiler_lower.LowerCAbiAggregate.Unsupported _) true]
            [_ false])
          ;; Extern C aggregate selection remains nominal-only.
          (match (compiler_lower.lower-c-abi-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view u8-u64))
            [(compiler_lower.LowerCAbiAggregate.No) true]
            [_ false])
          (match (compiler_lower.lower-c-abi-return-aggregate-class
            (compiler_typecheck_core.tc-global-shared-view ctx)
            (compiler_lower.CompilerLowerMode.LinuxScalar)
            (compiler_ast_types.ast-global-shared-view array-u8))
            [(compiler_lower.LowerCAbiAggregate.No) true]
            [_ false])))
      (compiler_ast_types.ast-node-pool-context-install! active-before)
      ok)))

(test
  compiler-lower-internal-tuple-array-layout
  (test.assert-true
    (compiler-lower-internal-tuple-array-layout-ok?)
    "recursive tuple/array layout and internal ABI classifier"))

(define (compiler-lower-internal-structural-call-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-internal-structural-call-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "tuple-roundtrip")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "array-roundtrip")
            (=
              (lower-test-function-param-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tuple-roundtrip")
              1)
            (=
              (lower-test-function-param-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "array-roundtrip")
              2)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "tuple-roundtrip")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "array-roundtrip")
              1)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tuple-roundtrip")
              2)
            (>=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "array-roundtrip")
              1)
            ;; Tuple register-group transport is packed at the call boundary;
            ;; the array return takes the leading hidden sret path.
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(test
  compiler-lower-internal-structural-call-shape
  (test.assert-true
    (compiler-lower-internal-structural-call-shape-ok?)
    "tuple/array internal call and return transport"))

(define (compiler-lower-internal-windows-byref-sret-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-internal-windows-byref-sret-source)
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "array-roundtrip")
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "scalar-roundtrip")
            (=
              (lower-test-function-param-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "array-roundtrip")
              2)
            (=
              (lower-test-function-param-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "scalar-roundtrip")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "array-roundtrip")
              1)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "scalar-roundtrip")
              1)
            (>=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "array-roundtrip")
              1)
            ;; Win64 ByRef parameters are copied into a private caller buffer;
            ;; the >8-byte result uses a leading sret pointer.
            (>=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-internal-windows-u8-three-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-internal-windows-u8-three-source)
    (compiler_lower.CompilerLowerMode.WindowsScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (lower-test-function-defined?
              (compiler_ir_types.compiler-ir-global-shared-view functions)
              "roundtrip")
            ;; Leading caller-owned sret plus one ByRef source parameter.
            (=
              (lower-test-function-param-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "roundtrip")
              2)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main"
                "roundtrip")
              1)
            ;; Three-byte copies lower to two scalar load/store chunks rather
            ;; than a bulk CopyBytes instruction. The callee copies into sret;
            ;; main has three literal stores plus the two ByRef-copy stores.
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "roundtrip")
              2)
            (>=
              (lower-test-function-store-ptr-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              5))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-internal-early-return-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-internal-early-return-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "tuple-early")
              1)
            (>=
              (lower-test-function-copy-bytes-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "array-early")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-internal-indirect-structural-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-internal-indirect-structural-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1)
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "main")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-internal-tail-structural-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source
    (compiler-lower-internal-tail-structural-source))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              0)
            (>
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "loop"
                "loop")
              0))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-internal-unsupported-diagnostics-ok?) : bool
  (and
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-param-source)
      (compiler_lower.CompilerLowerMode.LinuxScalar)
      "lower: unsupported linux-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-param-source)
      (compiler_lower.CompilerLowerMode.WindowsScalar)
      "lower: unsupported windows-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-empty-tuple-return-source)
      (compiler_lower.CompilerLowerMode.LinuxScalar)
      "lower: unsupported linux-x86_64 internal aggregate ABI for (Tuple ); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-empty-tuple-return-source)
      (compiler_lower.CompilerLowerMode.WindowsScalar)
      "lower: unsupported windows-x86_64 internal aggregate ABI for (Tuple ); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    ;; Direct and indirect call conversion must stamp classifier errors at the
    ;; call expression, including when no concrete indirect callee exists.
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-direct-call-source)
      (compiler_lower.CompilerLowerMode.LinuxScalar)
      "lower: unsupported linux-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      4)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-indirect-call-source)
      (compiler_lower.CompilerLowerMode.WindowsScalar)
      "lower: unsupported windows-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      4)))

(define (compiler-lower-internal-direct-tail-structural-param-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-internal-direct-tail-structural-param-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              0)
            (=
              (lower-test-function-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step"
                "finish")
              1)
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(define (compiler-lower-internal-indirect-tail-structural-param-shape-ok?) : bool
  (match (compiler_lower.lower-compiler-source-with-mode
    (compiler-lower-internal-indirect-tail-structural-param-source)
    (compiler_lower.CompilerLowerMode.LinuxScalar))
    [(compiler_lower.ResultCompilerLower.Ok program _)
      (match program
        [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
          (and
            (=
              (lower-test-function-indirect-tail-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              0)
            (=
              (lower-test-function-indirect-call-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              1)
            (>=
              (lower-test-function-pack-count
                (compiler_ir_types.compiler-ir-global-shared-view functions)
                "step")
              1))])]
    [(compiler_lower.ResultCompilerLower.Err _) false]))

(test
  compiler-lower-internal-windows-byref-sret-shape
  (test.assert-true
    (compiler-lower-internal-windows-byref-sret-shape-ok?)
    "Windows ByRef aggregate and leading sret transport"))

(test
  compiler-lower-internal-windows-u8-three-shape
  (test.assert-true
    (compiler-lower-internal-windows-u8-three-shape-ok?)
    "Windows three-byte ByRef parameter and leading sret transport"))

(test
  compiler-lower-internal-early-return-shape
  (test.assert-true
    (compiler-lower-internal-early-return-shape-ok?)
    "structural register and sret explicit returns"))

(test
  compiler-lower-internal-indirect-structural-shape
  (test.assert-true
    (compiler-lower-internal-indirect-structural-shape-ok?)
    "noncapturing indirect structural call transport"))

(test
  compiler-lower-internal-tail-structural-shape
  (test.assert-true
    (compiler-lower-internal-tail-structural-shape-ok?)
    "structural tail/RVO suppression"))

(test
  compiler-lower-internal-unsupported-diagnostics
  (test.assert-true
    (compiler-lower-internal-unsupported-diagnostics-ok?)
    "internal tuple/array ABI diagnostics are mode-specific and source-located"))

(test
  compiler-lower-internal-direct-tail-structural-param-shape
  (test.assert-true
    (compiler-lower-internal-direct-tail-structural-param-shape-ok?)
    "direct structural-parameter tail call uses ordinary ABI conversion"))

(test
  compiler-lower-internal-indirect-tail-structural-param-shape
  (test.assert-true
    (compiler-lower-internal-indirect-tail-structural-param-shape-ok?)
    "indirect structural-parameter tail call uses ordinary ABI conversion"))

(test
  compiler-lower-capturing-lambda-structural-return-shape
  (test.assert-true
    (compiler-lower-capturing-lambda-structural-return-shape-ok?)
    "capturing lambda structural return transport"))

(test
  compiler-lower-capturing-lambda-structural-sret-params
  (test.assert-true
    (compiler-lower-capturing-lambda-structural-sret-params-ok?)
    "capturing lambda keeps env before structural sret"))

(test
  compiler-lower-selected-import-alias-name-env
  (test.assert-true
    (compiler-lower-selected-import-alias-name-env-ok?)
    "selected import aliases preserve source logical and linker identities"))

(test
  compiler-lower-package-alias-collision
  (test.assert-true
    (compiler-lower-package-alias-collision-ok?)
    "package aliases preserve same-named value targets"))

(test
  compiler-lower-package-extern-alias-symbols
  (test.assert-true
    (compiler-lower-package-extern-alias-symbols-ok?)
    "package extern aliases preserve canonical call symbols"))

(test
  compiler-lower-defdispatch-structural-shape
  (test.assert-true
    (compiler-lower-defdispatch-structural-shape-ok?)
    "defdispatch structural thunk transport"))

(test
  compiler-lower-masked-load-cache
  (test.assert-true
    (compiler-lower-masked-load-cache-tests-ok?)
    "masked loads reuse only through dominating masks and memory epochs"))

(test
  compiler-lower-masked-preheader-cache
  (test.assert-true
    (compiler-lower-masked-preheader-cache-tests-ok?)
    "masked loops hoist typed splats and dynamic-array data pointers"))

(test
  compiler-lower-module-phase-cache-storage
  (test.assert-true
    (compiler-lower-module-phase-cache-storage-ok?)
    "module phase caches use sparse indexes, unique dense slots, and job-local reset"))

(test
  compiler-lower-checked-pools-state-isolation
  (test.assert-true
    (compiler-lower-checked-pools-state-isolation-ok?)
    "checked-pool retirement handoff is job-owned and clears to context-free state"))

(test
  compiler-lower-spmd-function-state-isolation
  (test.assert-true
    (compiler-lower-spmd-function-state-isolation-ok?)
    "SPMD package, traversal, and function memo state stays owner-local under interleaving"))

(test
  compiler-lower-checked-pools-abort-lifecycle
  (test.assert-true
    (compiler-lower-checked-pools-abort-lifecycle-ok?)
    "rollover abort releases deferred/materialized arenas exactly once"))

(define (compiler-lower-back-half-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-bounds-operand-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-bounds-operand-width-predicate-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-bounds-operand-idempotent-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-name-env-dense-snapshots-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-slice-reference-layout-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-tuple-array-layout-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-structural-call-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-windows-byref-sret-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-windows-u8-three-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-early-return-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-indirect-structural-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-tail-structural-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-unsupported-diagnostics-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-direct-tail-structural-param-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-internal-indirect-tail-structural-param-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-capturing-lambda-structural-return-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-capturing-lambda-structural-sret-params-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-defdispatch-structural-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-slice-whole-array-pack-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-slice-split-at-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-boxed-helper-lists-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-name-cache-intern-id-dotted-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-module-phase-cache-storage-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-checked-pools-state-isolation-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-spmd-function-state-isolation-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-checked-pools-abort-lifecycle-ok?)
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
      (if (compiler-lower-scalar-shift-count-types-ok?)
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

(test
  compiler-lower-profile-job-isolation
  (test.assert-true
    (compiler_lower.compiler-lower-profile-job-isolation-tests-ok?)
    "lower profile reset and observations stay isolated per job"))

(test
  compiler-lower-name-profile-job-isolation
  (test.assert-true
    (compiler_lower.compiler-lower-name-profile-job-isolation-tests-ok?)
    "lower name metrics stay isolated across equal-ID jobs and owner reset"))

(test
  compiler-lower-spmd-structural-profile
  (test.assert-true
    (compiler-lower-spmd-structural-profile-ok?)
    "SPMD identity serialization and stable hashing are cached per structural recipe"))