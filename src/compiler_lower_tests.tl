;; compiler_lower_tests.tl - Selfhost lowering fixtures split from production.
(import compiler_lower as lower)
(import compiler_optimize as optimize)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(cfg test (import compiler_profile_state as profile_state))
(import compiler_parse_core as parser)
(import compiler_typecheck_core as tc_core)
(import compiler_symbols as csym)
(import compiler_typecheck_api as tc_api)
(import compiler_load as load)
(import compiler_ctfe as ctfe)
(import compiler_clone as clone_support)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as lower_i64_i64_map)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)
(import stdlib.io)
(import stdlib.arena)
(import compiler_owned_view as owned_view)

;; The functions of a successful lowering. Checks match on it and fail on No.
(defenum LowerTestFunctions
  (No)
  (Some ir.CompilerIrFunctionSeq))

(define (lower-test-functions [result : lower.ResultCompilerLower]) : LowerTestFunctions
  (match result
    [(Ok program _)
      (match program
        [(Program _ functions _) (Some functions)])]
    [(Err _) (No)]))

;; --- fixtures moved from production compiler_lower.tl -------------------------
(define (lower-test-generated-name-id [value : String]) : i64
  (ci.intern-generated-canonical-name value))

(define (lower-test-generated-syntax-id [value : String]) : ci.InternSyntaxId
  (ci.intern-syntax-id-from-raw (lower-test-generated-name-id value)))

(define (lower-test-renderable-name-id-with-state
  [interns : (&mut interns ci.InternCompatState)]
  [value : String]) : ci.InternId
  (ci.intern-id-from-renderable
    (ci.intern-compat-state-generated-canonical-name interns value)))

(define (lower-name-env-resolve-with-id
  [names : lower.LowerNameEnv]
  [source-name : String]
  [source-id : i64]) : String
  (match (lower.lower-name-env-lookup-with-id names source-id)
    [(Some logical) logical]
    [(No) source-name]))

(define (lower-prune-unreachable-functions-with-clone-roots
  [pools : ast.AstNodePoolContext]
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [names : lower.LowerNameEnv]
  [clone-roots : clone_support.CloneRootEntries]) : LowerPrunedProgram
  (match (lower.lower-prune-unreachable-functions-with-clone-roots-and-plan
    (lower.compiler-lower-state-new)
    pools
    entry-path
    program
    paths
    names
    clone-roots)
    [(Program pruned-program pruned-paths _)
      (Program pruned-program pruned-paths)]))

(define (lower-prune-unreachable-functions
  [pools : ast.AstNodePoolContext]
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [names : lower.LowerNameEnv]) : LowerPrunedProgram
  (lower-prune-unreachable-functions-with-clone-roots
    pools
    entry-path
    program
    paths
    names
    (Empty)))

(define (lower-test-prune-unreachable-functions
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [names : lower.LowerNameEnv]) : LowerPrunedProgram
  (lower-prune-unreachable-functions
    (ast.ast-node-pool-context-capture-active)
    entry-path
    program
    paths
    names))

(define (lower-capture-list-count
  [captures : (& captures lower.LowerCaptureList)]) : i64
  captures.count)

(define (lower-capture-list-storage-entry?
  [captures : (& captures lower.LowerCaptureList)]
  [index : i64]
  [name-id : i64]
  [var-id : i64]
  [offset : i64]) : bool
  (if (or (< index 0) (>= index captures.count))
    false
    (match (array-ref captures.items index)
      [(Capture capture-name-id capture-var-id _ capture-offset)
        (and
          (= capture-name-id name-id)
          (= capture-var-id var-id)
          (= capture-offset offset))])))

(define (lower-cleanup-stack-count
  [cleanups : (& cleanups lower.LowerCleanupStack)]) : i64
  cleanups.count)

(define (lower-cleanup-stack-entry?
  [cleanups : (& cleanups lower.LowerCleanupStack)]
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
    [left : lower.LowerArrayVarSet
      (lower.lower-array-var-set-add
        (lower.lower-array-var-set-add
          (lower.lower-array-var-set-add (lower.lower-array-var-set-empty) 10 1)
          20
          2)
        10
        4)]
    [right : lower.LowerArrayVarSet
      (lower.lower-array-var-set-add
        (lower.lower-array-var-set-add (lower.lower-array-var-set-empty) 30 3)
        20
        1)]
    [merged : lower.LowerArrayVarSet
      (lower.lower-array-var-set-merge left right)]
    [vars : (__tl_dyn-array i64) merged.vars]
    [offsets : (__tl_dyn-array i64) merged.offsets]
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
      (= (lower.lower-array-var-set-max-offset merged) 4))))

(define (lower-skip-runtime-until-next-module [decls : ast.AstDeclList]) : ast.AstDeclList
  (match (ast.ast-decl-list-step decls)
    [(Nil) (ast.ast-decl-list-new)]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (owned_view.compiler-owned-shared-view decl)
          [(Module _) decls]
          [_
            (let
              [kept-rest : ast.AstDeclList
                (lower-skip-runtime-until-next-module rest)]
              (if (lower.lower-type-decl?
                (owned_view.compiler-owned-shared-view decl))
                (ast.ast-decl-list-prepend-builder decl kept-rest)
                kept-rest))]))]))

(define (lower-compiler-program-with-decl-paths
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]) : lower.ResultCompilerLower
  (lower-compiler-program-with-decl-paths-mode
    entry-path
    program
    paths
    (lower.CompilerLowerMode.Scalar)))

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
(define (main) : i64 (need [true]))")

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

;; #8012: a multiply by a wide power-of-two constant global must be optimized
;; exactly like a multiply by any other wide constant: dead products removed,
;; loop-invariant products hoisted, product-conditioned loops rotated. Only the
;; instruction itself differs (the late pass selects a shift). The same program
;; is optimized at level 2 with `big` = 2^34 and with the non-power 2^34 + 1,
;; and each function must keep the same block count and the block its product
;; sits in, with no more instructions than the control.
(define (compiler-optimize-wide-power-product-source [big : String]) : String
  (str_cat.str-cat
    "(define big : i64 "
    big
    ")
(define (dead [x : i64]) : i64
  (let
    [t : i64 (* x big)]
    (+ x 1)))
(define (hoisted [n : i64] [count : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! acc (+ acc (* n big)))
          (set! i (+ i 1))))
      acc)))
(define (rotated [lim : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< (* i big) lim)
        (set! i (+ i 1)))
      i)))
(define keep-dead : (-> i64 i64) dead)
(define keep-hoisted : (-> i64 i64 i64) hoisted)
(define keep-rotated : (-> i64 i64) rotated)
(define (main) : i64
  0)"))

;; Block count, instruction count and the index of the block holding the first
;; 64-bit multiply or shift (-1 when there is none) of function NAME.
(defstruct LowerTestProductShape
  (blocks i64)
  (instrs i64)
  (product-block i64))

(define (lower-test-product-instr? [instr : ir.CompilerIrInstr]) : bool
  (match instr
    [(BinOp _ (Mul) _ _ (I64)) true]
    [(BinOp _ (Shl _) _ _ (I64)) true]
    [_ false]))

(define (lower-test-product-shape-blocks
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [block-index : i64]
  [shape : LowerTestProductShape]) : LowerTestProductShape
  (match blocks
    [(slice) shape]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (let
            [count : i64 (ir.compiler-ir-instr-seq-count instrs)]
            [index : i64 0]
            [product-block : i64 shape.product-block]
            (while (< index count)
              (if (and
                (< product-block 0)
                (lower-test-product-instr?
                  (ir.compiler-ir-instr-seq-ref instrs index)))
                (set! product-block block-index)
                unit)
              (set! index (+ index 1)))
            (lower-test-product-shape-blocks
              rest
              (+ block-index 1)
              (LowerTestProductShape
                (+ shape.blocks 1)
                (+ shape.instrs count)
                product-block)))])]))

(define (lower-test-optimized-product-shape [source : String] [name : String]) : LowerTestProductShape
  (match (lower.lower-compiler-source source)
    [(Ok program spans)
      (match (match (optimize.optimize-program-with-spans-and-level
        program
        spans
        2)
        [(Program optimized _) optimized])
        [(Program _ functions _)
          (match (lower-test-function-seq-find functions name)
            [(Some func)
              (match func
                [(Function _ _ _ _ blocks _)
                  (lower-test-product-shape-blocks
                    (ir.compiler-ir-block-list-view blocks)
                    0
                    (LowerTestProductShape 0 0 -1))])]
            [(No) (LowerTestProductShape -1 -1 -2)])])]
    [(Err _) (LowerTestProductShape -1 -1 -3)]))

(define (lower-test-product-shapes-match? [name : String]) : bool
  (let
    [power : LowerTestProductShape
      (lower-test-optimized-product-shape
        (compiler-optimize-wide-power-product-source "17179869184")
        (owned_view.compiler-owned-shared-view name))]
    [control : LowerTestProductShape
      (lower-test-optimized-product-shape
        (compiler-optimize-wide-power-product-source "17179869185")
        name)]
    (and
      (>= power.blocks 1)
      (= power.blocks control.blocks)
      ;; the control reads its non-substituted global through one more
      ;; instruction; the power product never needs more than it
      (<= power.instrs control.instrs)
      (= power.product-block control.product-block))))

(define (compiler-optimize-wide-power-product-shape-ok?) : bool
  (and
    (lower-test-product-shapes-match? "dead")
    (lower-test-product-shapes-match? "hoisted")
    (lower-test-product-shapes-match? "rotated")
    ;; the dead product is really gone, and the live ones really exist
    (<
      (lower-test-product-shape-block
        (lower-test-optimized-product-shape
          (compiler-optimize-wide-power-product-source "17179869184")
          "dead"))
      0)
    (>=
      (lower-test-product-shape-block
        (lower-test-optimized-product-shape
          (compiler-optimize-wide-power-product-source "17179869184")
          "hoisted"))
      0)))

(define (lower-test-product-shape-block [shape : LowerTestProductShape]) : i64
  shape.product-block)

;; Globals initialized from other globals (#7804): a variable's value is read by
;; a runtime initializer, while a function name keeps its closure-descriptor
;; initializer.
(define (compiler-lower-global-reference-initializer-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(defenum Color (Red) (Green))
(define base : i64 14)
(define copy : i64 base)
(define widened : i64 (cast base : i64))
(define color : Color Green)
(define callback : (-> i64 i64) inc)
(define callback-copy : (-> i64 i64) callback)
(define (main) : i64
  (+ copy (callback-copy widened)))")

(define (compiler-lower-static-array-global-source) : String
  "(define wide : (Array u16 3) (array 1 256 65535))
(define halves : (Array f32 2) (array 1.5 -0.0))
(define flags : (Array bool 2) (array true false))
(define letters : (Array char 1) (array 'A'))
(define negatives : (Array i8 2) (array -1 -128))
(define empty : (Array i64 0) (array))
(define (seed) : i64 3)
(define computed : (Array i64 2) (array (seed) 4))
(define converted : (Array f64 1) (array (cast 1 : f64)))
(define nested : (Array (Array i64 2) 1) (array (array 5 6)))
(define (main) : i64
  (+
    (cast (array-ref wide 1) : i64)
    (cast (array-ref halves 0) : i64)
    (if (array-ref flags 0) 1 0)
    (cast (array-ref letters 0) : i64)
    (cast (array-ref negatives 0) : i64)
    (array-ref computed 0)
    (cast (array-ref converted 0) : i64)
    (array-ref (array-ref nested 0) 1)))")

(define (compiler-lower-mutable-global-function-value-source) : String
  "(define (initial [x : i64]) : i64 x)
(define (replacement [x : i64]) : i64 (- x 1))
(define callback : (-> i64 i64) initial)
(define (install! [next : (-> i64 i64)]) : unit
  (set! callback next))
(define (invoke [x : i64]) : i64
  (+ (callback x) 0))
(define (main) : i64
  (begin
    (install! replacement)
    (+ (invoke 43) 0)))")

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
  (match (lower.lower-compiler-source src)
    [(Err diag)
      (string.eq (cdiag.compiler-diagnostic-message (__tl-box-place diag)) want)]
    [(Ok _ _) false]))

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

(test
  compiler-lower-resetting-entry-live-session-guard
  (test.assert-true
    (let
      [previous-state : load.CompilerLoadSessionState
        (load.compiler-load-active-session-state-shared-view)]
      [live-state : load.CompilerLoadSessionState
        (load.compiler-load-session-state-new)]
      [generation-before : i64 (ci.intern-generation)]
      [_select-live : unit (load.compiler-load-session-state-use! live-state)]
      [result : lower.ResultCompilerLower
        (lower.lower-compiler-source "(define (main) : i64 0)")]
      [generation-after : i64 (ci.intern-generation)]
      [_restore : unit
        (let
          [state
            (load.compiler-load-session-state-shared-view (& previous-state))]
          (load.compiler-load-session-state-use! state))]
      (and
        (load.compiler-load-session-state-standalone-reset-safe? previous-state)
        (= generation-before generation-after)
        (match result
          [(Err diag)
            (string.eq
              (cdiag.compiler-diagnostic-message (__tl-box-place diag))
              "lower-compiler-source-with-path-mode: standalone resetting compiler entry cannot run inside an active compiler load session")]
          [(Ok _ _) false])))
    "lower standalone entry rejects a live compiler session before reset"))

(test
  compiler-lower-pool-copy-arena-restoration
  (test.assert-true
    (let
      [home : arena.Arena (arena.current)]
      [owner : arena.Arena (arena.make)]
      [ok : bool
        (let
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-new-with-capacities-in-arena
              8
              8
              (arena.raw-handle owner))]
          [copied : String
            (lower.lower-copy-string-into-pools "pool-owned" pools)]
          (and (arena.eq? (arena.current) home) (string.eq copied "pool-owned")))]
      (arena.destroy-safe! owner)
      ok)
    "lower pool-copy helper restores caller arena"))

(define (compiler-lower-maybe-span-start-ok?
  [found-span : ir.CompilerMaybeSourceSpan]
  [line : i64]
  [col : i64]) : bool
  (match found-span
    [(Some found)
      (and
        (= (ast.ast-source-span-start-line found) line)
        (= (ast.ast-source-span-start-col found) col))]
    [(No) false]))

(define (compiler-lower-nested-expression-diagnostic-span-ok?) : bool
  (let
    [span : ast.AstSourceSpan (ast.ast-source-span 11 3 11 9)]
    [value-id : i64 (ci.intern-generated-name "value")]
    [inner : i64 (ast.ast-node-push (Var value-id))]
    [spanned-inner : i64 (ast.ast-expr-spanned inner span)]
    [wrapped : i64 (ast.ast-expr-cast spanned-inner (I64))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [diag : cdiag.CompilerDiagnostic
      (lower.lower-diagnostic-at-expr-with-pools
        pools
        (ast.ast-node-get wrapped)
        "lower: nested expression diagnostic")]
    [found-span : ir.CompilerMaybeSourceSpan
      (lower.lower-ast-expr-span
        pools
        (ast.ast-node-get (ast.ast-expr-return spanned-inner)))]
    [diag-ok : bool
      (and
        (string.eq
          (cdiag.compiler-diagnostic-message diag)
          "lower: nested expression diagnostic")
        (= (cdiag.compiler-diagnostic-line diag) 11)
        (= (cdiag.compiler-diagnostic-col diag) 3))]
    [span-ok : bool (compiler-lower-maybe-span-start-ok? found-span 11 3)]
    (and diag-ok span-ok)))

(define (compiler-lower-compound-expression-diagnostic-span-ok?) : bool
  (let
    [span : ast.AstSourceSpan (ast.ast-source-span 17 5 17 12)]
    [compound-value-id : i64 (ci.intern-generated-name "compound-value")]
    [a-id : i64 (ci.intern-generated-name "a")]
    [b-id : i64 (ci.intern-generated-name "b")]
    [i-id : i64 (ci.intern-generated-name "i")]
    [prefix-id : i64 (ci.intern-generated-name "prefix")]
    [plain : i64 (ast.ast-node-push (Literal Unit))]
    [inner : i64 (ast.ast-node-push (Var compound-value-id))]
    [spanned-inner : i64 (ast.ast-expr-spanned inner span)]
    [items : ast.AstExprList
      (ast.ast-expr-cons
        plain
        (ast.ast-expr-cons spanned-inner (ast.ast-expr-list-new)))]
    [bindings : ast.AstLetBindingList
      (ast.ast-let-binding-cons
        (ast.ast-let-binding-id a-id (No) plain)
        (ast.ast-let-binding-cons
          (ast.ast-let-binding-id b-id (No) spanned-inner)
          (ast.ast-let-binding-list-new)))]
    [arms : ast.AstMatchArmList
      (ast.ast-match-arm-cons
        (ast.ast-match-arm (Wildcard) plain)
        (ast.ast-match-arm-cons
          (ast.ast-match-arm (Wildcard) spanned-inner)
          (ast.ast-match-arm-list-new)))]
    [resources : ast.AstResourceBindingList
      (ast.ast-resource-binding-cons
        (ast.ast-resource-binding-id a-id plain plain)
        (ast.ast-resource-binding-cons
          (ast.ast-resource-binding-id b-id spanned-inner plain)
          (ast.ast-resource-binding-list-new)))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    (and
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span pools (Binary (Add) plain spanned-inner))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span
          pools
          (SpmdCompact
            (box
              (ast.AstSpmdCompact.Compact
                i-id
                (I64)
                plain
                plain
                prefix-id
                (I64)
                plain
                plain
                spanned-inner))))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span
          pools
          (Call plain (owned_view.compiler-owned-shared-view items)))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span pools (If plain plain spanned-inner))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span
          pools
          (Let (box (ast.AstLet.Let bindings plain))))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span
          pools
          (Match (box (ast.AstMatch.Match plain arms))))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span
          pools
          (WithResource
            (box
              (ast.AstWithResource.WithResource
                resources
                (owned_view.compiler-owned-shared-view items)))))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span
          pools
          (SpmdScan
            (box
              (ast.AstSpmdScan.Scan
                (Sum)
                i-id
                (I64)
                plain
                plain
                prefix-id
                (I64)
                plain
                plain
                spanned-inner))))
        17
        5)
      (compiler-lower-maybe-span-start-ok?
        (lower.lower-ast-expr-span pools (Syscall items))
        17
        5))))

(define (compiler-lower-mode-error-ok?
  [src : String]
  [mode : lower.CompilerLowerMode]
  [want : String]) : bool
  (match (lower.lower-compiler-source-with-mode src mode)
    [(Err diag)
      (string.eq (cdiag.compiler-diagnostic-message (__tl-box-place diag)) want)]
    [(Ok _ _) false]))

(define (compiler-lower-mode-diagnostic-ok?
  [src : String]
  [mode : lower.CompilerLowerMode]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (lower.lower-compiler-source-with-mode src mode)
    [(Err diag-box)
      (let
        [diag : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-box-shared-view diag-box)]
        (and
          (string.eq (cdiag.compiler-diagnostic-message diag) want)
          (= (cdiag.compiler-diagnostic-line diag) line)
          (= (cdiag.compiler-diagnostic-col diag) col)))]
    [(Ok _ _) false]))

(define (compiler-lower-inline-error-ok? [src : String] [want : String]) : bool
  (match (lower.lower-compiler-source src)
    [(Err diag)
      (string.eq (cdiag.compiler-diagnostic-message (__tl-box-place diag)) want)]
    [(Ok _ _) false]))

(define (compiler-lower-windows-error-ok? [src : String] [want : String]) : bool
  (match (lower.lower-compiler-source-with-mode
    src
    (lower.CompilerLowerMode.WindowsScalar))
    [(Err diag)
      (string.eq (cdiag.compiler-diagnostic-message (__tl-box-place diag)) want)]
    [(Ok _ _) false]))

(define (compiler-lower-entry-moduled-main-ok?) : bool
  (let
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [prev-active : bool
      (lower.lower-entry-main-module-active-current lower-state)]
    [prev-module : String (lower.lower-entry-main-module-current lower-state)]
    [prev-module-id : i64
      (lower.lower-entry-main-module-id-current lower-state)]
    [active-ok : bool false]
    (lower.lower-entry-main-selection-install!
      lower-state
      (Some "app.main" 123))
    (set!
      active-ok
      (and
        (lower.lower-decl-entry-main?
          lower-state
          "src/app.tl"
          "src/app.tl"
          "app.main"
          "main")
        (lower.lower-decl-entry-main?
          lower-state
          "src\\app.tl"
          "src/app.tl"
          "app.main"
          "main")
        (not
          (lower.lower-decl-entry-main?
            lower-state
            "src/app.tl"
            "src/lib.tl"
            "app.main"
            "main"))
        (not
          (lower.lower-decl-entry-main?
            lower-state
            "src/app.tl"
            "src/app.tl"
            "app.main"
            "helper"))))
    (lower.lower-entry-main-selection-restore!
      lower-state
      prev-active
      prev-module
      prev-module-id)
    (and
      active-ok
      (not
        (lower.lower-decl-entry-main?
          lower-state
          "src/app.tl"
          "src/app.tl"
          "app.main"
          "main")))))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-fixed-array-length-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "owned-len" (Load)) 0)
        (= (lower-test-count functions "shared-len" (Load)) 0)
        (= (lower-test-count functions "mut-len" (Load)) 0)
        (= (lower-test-count functions "owned-len" (Return)) 1)
        (= (lower-test-count functions "shared-len" (Return)) 1)
        (= (lower-test-count functions "mut-len" (Return)) 1))]
    [_ false]))

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
  (match (lower.lower-compiler-source
    (compiler-lower-slice-whole-array-pack-source))
    [(Ok program _)
      (let
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        (match program
          [(Program _ functions _)
            (and
              (= (lower-test-count functions "main" (Pack)) 1)
              (=
                (lower-test-function-pack-shape-count functions "main" pools)
                1)
              (= (lower-test-count functions "slice-from-array-ref" (Pack)) 1)
              (=
                (lower-test-function-pack-shape-count
                  functions
                  "slice-from-array-ref"
                  pools)
                1)
              (= (lower-test-count functions "slice-forward" (Pack)) 0))]))]
    [(Err _) false]))

(define (compiler-lower-slice-split-at-source) : String
  "(define (split [view : (&mut source (Slice i64))] [mid : i64]) : (Tuple (&mut source (Slice i64)) (&mut source (Slice i64)))
  (slice-split-at-mut view mid))
(define (main) : i64 0)")

(define (compiler-lower-slice-split-at-mode-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-slice-split-at-source)
      mode))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "split" "tl_oob_abort") 1)
        (= (lower-test-function-binop-op-count functions "split" Le) 1)
        (= (lower-test-function-binop-op-count functions "split" Sub) 1)
        (= (lower-test-function-call-count functions "split" "tl_alloc") 0)
        (>= (lower-test-count functions "split" (Pack)) 2))]
    [_ false]))

(define (compiler-lower-slice-split-at-shape-ok?) : bool
  (and
    (compiler-lower-slice-split-at-mode-shape-ok?
      (lower.CompilerLowerMode.LinuxScalar))
    (compiler-lower-slice-split-at-mode-shape-ok?
      (lower.CompilerLowerMode.WindowsScalar))))

;; Tuple values are inline (#7070): building one, returning one through the
;; register or sret path, and the CPUID result tuple never call `tl_alloc`.
(define (compiler-lower-tuple-inline-storage-source) : String
  "(define (wide [x : i64]) : (Tuple i64 i64 i64 i64)
  (tuple x x x x))
(define (pair [x : i64]) : (Tuple i64 i64)
  (tuple x x))
(define (local [x : i64]) : i64
  (let
    [t : (Tuple i64 i64 i64 i64) (tuple x x x x)]
    (tuple-ref t 3)))
(define (leaf) : i64
  (let
    [r : (Tuple i32 i32 i32 i32) (cpuid 0 0)]
    (cast (tuple-ref r 0) : i64)))
(define (main) : i64 (+ (local 1) (leaf)))")

(define (compiler-lower-tuple-inline-storage-no-heap?
  [functions : (& functions ir.CompilerIrFunctionSeq)]
  [name : String]) : bool
  (= (lower-test-function-call-count functions name "tl_alloc") 0))

(define (compiler-lower-tuple-inline-storage-frame?
  [functions : (& functions ir.CompilerIrFunctionSeq)]
  [name : String]) : bool
  (> (lower-test-count functions name (Alloc)) 0))

(define (compiler-lower-tuple-inline-storage-mode-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-tuple-inline-storage-source)
      mode))
    [(Some functions)
      (and
        (compiler-lower-tuple-inline-storage-no-heap? functions "wide")
        (compiler-lower-tuple-inline-storage-frame? functions "wide")
        (compiler-lower-tuple-inline-storage-no-heap? functions "pair")
        (compiler-lower-tuple-inline-storage-frame? functions "pair")
        (compiler-lower-tuple-inline-storage-no-heap? functions "local")
        (compiler-lower-tuple-inline-storage-frame? functions "local")
        (compiler-lower-tuple-inline-storage-no-heap? functions "leaf")
        (compiler-lower-tuple-inline-storage-frame? functions "leaf"))]
    [_ false]))

(define (compiler-lower-tuple-inline-storage-ok?) : bool
  (and
    (compiler-lower-tuple-inline-storage-mode-ok?
      (lower.CompilerLowerMode.LinuxScalar))
    (compiler-lower-tuple-inline-storage-mode-ok?
      (lower.CompilerLowerMode.WindowsScalar))))

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
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-mut-ref-by-value-writeback-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (Alloc)) 2)
        (>= (lower-test-count functions "main" (AddrOf)) 2)
        (>= (lower-test-count functions "main" (Load)) 2))]
    [_ false]))

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

(define (compiler-lower-public-literal-float-to-bits-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/math.tl"
    (ast.ast-decl-root-path-cons
      "stdlib/math.tl"
      (ast.ast-decl-root-path-cons
        "stdlib/math.tl"
        (ast.ast-decl-root-path-cons
          "stdlib/math.tl"
          (ast.ast-decl-root-path-cons
            "stdlib/math.tl"
            (ast.ast-decl-root-path-cons
              "stdlib/math.tl"
              (ast.ast-decl-path-list-new))))))))

(define (compiler-lower-stdlib-string-wrapper-prune-source) : String
  "(module stdlib.string)
(define (string.string-length [text : (& text str)]) : i64 0)
(module stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(define (io-len [text : String]) : i64 (string.string-length text))
(define (main) : i64 (io-len \"abc\"))")

(define (compiler-lower-stdlib-string-wrapper-prune-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/string.tl"
    (ast.ast-decl-root-path-cons
      "stdlib/string.tl"
      (ast.ast-decl-root-path-cons
        "stdlib/string.tl"
        (ast.ast-decl-root-path-cons
          "stdlib/tl"
          (ast.ast-decl-root-path-cons
            "stdlib/tl"
            (ast.ast-decl-root-path-cons
              "stdlib/tl"
              (ast.ast-decl-root-path-cons
                "stdlib/tl"
                (ast.ast-decl-path-list-new)))))))))

(define (compiler-lower-stdlib-string-wrapper-prune-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-stdlib-string-wrapper-prune-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "stdlib/tl"
          program
          (compiler-lower-stdlib-string-wrapper-prune-paths)))
        [(Some functions)
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
                "string.tl::stdlib.string/string-length")))]
        [_ false])]
    [(Err _) false]))

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

(define (compiler-lower-stdlib-hash-string-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/hash.tl"
    (ast.ast-decl-root-path-cons "app.tl" (ast.ast-decl-path-list-new))))

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
  (match (lower-test-functions
    (compiler-lower-clone-source-with-prelude
      (compiler-lower-clone-chunk-boundary-source)))
    [(Some functions)
      (and
        (lower-test-function-defined? functions ".::clone$CloneChunk17")
        (lower-test-function-defined? functions ".::clone$CloneChunk2")
        (lower-test-function-defined? functions ".::clone$CloneChunk1")
        (lower-test-function-defined? functions ".::clone$CloneChunk0"))]
    [_ false]))

;; Nominal clone helpers are declaration macros now, so clone-producing lowering
;; fixtures must load the same implicit prelude as the compiler driver.
(define (compiler-lower-clone-source-with-prelude [src : String]) : lower.ResultCompilerLower
  (ci.intern-reset!)
  (lower.lower-reset-intern-owned-state!)
  (cbi.compiler-builtin-reset!)
  (match (tc_api.typecheck-compiler-source-load src)
    [(Ok decls paths _ _)
      (lower-compiler-program-with-decl-paths "" (ast.ast-program decls) paths)]
    [(Err diag) (Err diag)]))

;; `main` must lower with both element stores (bool + i64 each written into the
;; aggregate) and a load for the `tuple-ref`.
(define (compiler-lower-tuple-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tuple-source)))
    [(Some functions)
      (and
        (>= (lower-test-count functions "main" (StorePtr)) 2)
        (>= (lower-test-count functions "main" (Load)) 1))]
    [_ false]))

(define (compiler-lower-clone-shape-ok?) : bool
  (match (lower-test-functions
    (compiler-lower-clone-source-with-prelude (compiler-lower-clone-source)))
    [(Some functions)
      (and
        (>
          (lower-test-function-call-count
            functions
            ".::clone-tuple"
            "tl_substring")
          0)
        (>
          (lower-test-function-call-count functions ".::clone-tuple" "tl_alloc")
          0)
        (>
          (lower-test-function-call-count
            functions
            ".::clone-fixed"
            "tl_substring")
          1)
        (>
          (lower-test-function-call-count functions ".::clone-dyn" "tl_alloc")
          1)
        (> (lower-test-count functions ".::clone-dyn" (Branch)) 0)
        (=
          (lower-test-function-call-count
            functions
            ".::clone-holder"
            ".::clone$Holder")
          1)
        (=
          (lower-test-function-call-count
            functions
            ".::clone-tree"
            ".::clone$StringTree")
          1)
        (>
          (lower-test-function-call-count
            functions
            ".::clone$Holder"
            "tl_substring")
          0)
        (>
          (lower-test-function-call-count
            functions
            ".::clone$Holder"
            "tl_alloc")
          0)
        (>
          (lower-test-function-call-count
            functions
            ".::clone$StringTree"
            "tl_substring")
          0))]
    [_ false]))

(define (compiler-lower-clone-dynarray-bulk-copy-ok?) : bool
  (match (lower-test-functions
    (compiler-lower-clone-source-with-prelude
      (compiler-lower-clone-dynarray-bulk-source)))
    [(Some functions)
      (and
        (=
          (lower-test-function-call-count
            functions
            ".::copy-i64-items"
            "tl_memcpy")
          1)
        (= (lower-test-count functions ".::copy-i64-items" (Branch)) 0)
        (=
          (lower-test-function-call-count
            functions
            ".::copy-word-items"
            "tl_memcpy")
          1)
        (= (lower-test-count functions ".::copy-word-items" (Branch)) 0)
        (=
          (lower-test-function-call-count
            functions
            ".::copy-string-items"
            "tl_memcpy")
          0)
        (>
          (lower-test-function-call-count
            functions
            ".::copy-string-items"
            "tl_substring")
          0)
        (> (lower-test-count functions ".::copy-string-items" (Branch)) 0))]
    [_ false]))

(define (compiler-lower-clone-reachable-helpers-ok?) : bool
  (match (lower-test-functions
    (compiler-lower-clone-source-with-prelude
      (compiler-lower-clone-reachable-source)))
    [(Some functions)
      (and
        (lower-test-function-defined? functions ".::clone$NestedClone")
        (lower-test-function-defined? functions ".::clone$UsedClone")
        (not (lower-test-function-defined? functions ".::clone$UnusedClone"))
        (=
          (lower-test-function-call-count
            functions
            ".::clone$NestedClone"
            ".::clone$UsedClone")
          1))]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-inline-struct-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (Alloc)) 3)
        (= (lower-test-count functions "main" (AddrOf)) 1)
        (>= (lower-test-count functions "main" (StorePtr)) 3)
        (> (lower-test-count functions "main" (GepOffset 16)) 0))]
    [_ false]))

(define (compiler-lower-inline-enum-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-inline-enum-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (Alloc)) 3)
        (= (lower-test-count functions "main" (AddrOf)) 1)
        (>= (lower-test-count functions "main" (StorePtr)) 3)
        (> (lower-test-count functions "main" (GepOffset 16)) 0)
        (> (lower-test-count functions "main" (Branch)) 0))]
    [_ false]))

(define (compiler-lower-inline-boxed-recursive-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-inline-boxed-recursive-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 2)
        (>= (lower-test-count functions "main" (Alloc)) 6)
        (>= (lower-test-count functions "main" (AddrOf)) 2)
        (>= (lower-test-count functions "main" (StorePtr)) 4))]
    [_ false]))

(define (compiler-lower-inline-imported-enum-payload-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-inline-imported-enum-payload-source)))
    [(Some functions)
      (>
        (lower-test-functions-call-count
          functions
          "stdlib.maybe_string/maybe-string-single")
        0)]
    [_ false]))

;; `id-pair` is the identity on a 16-byte all-integer struct, which is
;; register-resident -- it is carried in a register pair end-to-end, so the
;; passthrough needs NO memory traffic at all: zero byte-copies and zero stores
;; (before register-residency this copied the 16 bytes through a slot). The
;; A mixed int/float 16-byte aggregate stays memory-backed, so its identity
;; return exercises the lower-copy-bytes 16-byte CopyBytes threshold.
(define (compiler-lower-inline-aggregate-copy-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-inline-aggregate-copy-source)))
    [(Some pair-functions)
      (let
        [pair-copy-count : i64
          (lower-test-count pair-functions "id-pair" (CopyBytes))]
        [pair-store-count : i64
          (lower-test-count pair-functions "id-pair" (StorePtr))]
        (match (lower-test-functions
          (lower.lower-compiler-source
            (compiler-lower-inline-mixed16-copy-source)))
          [(Some mixed-functions)
            (and
              (= pair-copy-count 0)
              (= pair-store-count 0)
              (= (lower-test-count mixed-functions "id-mixed" (CopyBytes)) 1))]
          [_ false]))]
    [_ false]))

(define (compiler-lower-inline-sret-return-copy-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-inline-sret-return-copy-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "return216-id" (CopyBytes)) 1)
        (=
          (lower-test-function-call-count functions "return216-id" "tl_memcpy")
          0))]
    [_ false]))

(define (compiler-lower-inline-sret-constructor-copy-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-inline-sret-struct-constructor-source)))
    [(Some struct-functions)
      (let
        [struct-copy-count : i64
          (lower-test-count struct-functions "make-wide" (CopyBytes))]
        (match (lower-test-functions
          (lower.lower-compiler-source
            (compiler-lower-inline-sret-enum-constructor-source)))
          [(Some enum-functions)
            (and
              (= struct-copy-count 0)
              (=
                (lower-test-count enum-functions "make-wide-choice" (CopyBytes))
                0))]
          [_ false]))]
    [_ false]))

(define (compiler-lower-inline-sret-enum-match-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-inline-sret-enum-match-constructor-source)))
    [(Some constructor-functions)
      (let
        [constructor-copy-count : i64
          (lower-test-count constructor-functions "from-choice" (CopyBytes))]
        [constructor-phi-count : i64
          (lower-test-function-phi-count constructor-functions "from-choice")]
        (match (lower-test-functions
          (lower.lower-compiler-source
            (compiler-lower-inline-sret-enum-match-generic-source)))
          [(Some generic-functions)
            (and
              (= constructor-copy-count 0)
              (= constructor-phi-count 0)
              (>
                (lower-test-count generic-functions "from-choice" (CopyBytes))
                0)
              (=
                (lower-test-function-phi-count generic-functions "from-choice")
                0))]
          [_ false]))]
    [_ false]))

(define (compiler-lower-inline-hot-loop-struct-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-inline-hot-loop-struct-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (> (lower-test-count functions "main" (Branch)) 0))]
    [_ false]))

(define (compiler-lower-inline-direct-store-copy-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-inline-direct-store-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "direct-field" (CopyBytes)) 0)
        (= (lower-test-count functions "direct-init" (CopyBytes)) 0)
        (= (lower-test-count functions "direct-dyn-array" (CopyBytes)) 0)
        (= (lower-test-count functions "direct-fixed-array" (CopyBytes)) 0)
        (> (lower-test-count functions "direct-fixed-literal" (CopyBytes)) 0))]
    [_ false]))

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
  "(defenum Slot (Empty) (Occupied String))
(defstruct Bag (slots (__tl_dyn-array Slot)))
(defenum SlotLookup (:lifetimes bag) (Missing) (Found (& bag str)))
(define (take [v : (& bag str)]) : i64 41)
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) SlotLookup.Missing)
(define (slot-found [value : (& bag str)]) : (SlotLookup bag) (SlotLookup.Found value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (let [same : (& bag str) v] (slot-found same))]
    [Empty (slot-missing bag)]))
(define (score [bag : (& bag Bag)]) : i64
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (take v)]
    [Empty 0]))
(define (main) : i64
  (let
    [slots : (__tl_dyn-array Slot) (__tl_make-array Slot 1)]
    (begin
      (set! (array-ref slots 0) (Occupied \"nine\"))
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
  (match (lower.lower-compiler-source src)
    [(Ok _ _) true]
    [(Err _) false]))

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
  [spans : ir.CompilerSourceSpans]
  [name : String]
  [want-line : i64]) : bool
  (match (ir.compiler-source-spans-lookup
    spans
    (ir.compiler-ir-symbol-typed-id (ci.intern name)))
    [(Some span) (= (ast.ast-source-span-start-line span) want-line)]
    [(No) false]))

(define (compiler-lower-spans-ok? [src : String]) : bool
  (match (lower.lower-compiler-source src)
    [(Ok _ spans)
      (and
        (=
          (ir.compiler-source-spans-count
            (owned_view.compiler-owned-shared-view spans))
          2)
        (compiler-lower-span-start-line-ok?
          (owned_view.compiler-owned-shared-view spans)
          "inc"
          3)
        (compiler-lower-span-start-line-ok? spans "main" 5))]
    [(Err _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower.lower-compiler-source src)
    [(Ok program _)
      (let
        [summary : ir.CompilerIrSummary
          (ir.compiler-ir-program-summary program)]
        (and
          (= (ir.compiler-ir-summary-globals summary) 1)
          (= (ir.compiler-ir-summary-functions summary) 2)
          (= (ir.compiler-ir-summary-externs summary) 1)
          (= (ir.compiler-ir-summary-blocks summary) 7)
          (= (ir.compiler-ir-summary-instructions summary) 20)
          (= (ir.compiler-ir-summary-vars summary) 13)
          (= (ir.compiler-ir-summary-empty-blocks summary) 0)
          (= (ir.compiler-ir-summary-max-instructions-function summary) 17)
          (= (ir.compiler-ir-summary-max-instructions-block summary) 6)
          (= (ir.compiler-ir-summary-call-arg-entries summary) 1)
          (= (ir.compiler-ir-summary-phi-input-entries summary) 0)))]
    [(Err _) false]))

;; Count `CompilerIrInstr.Phi` nodes, to assert the merge-phi shape of lowered scalar
;; matches: value-returning matches emit a merge phi, unit matches none.
(define (lower-test-instr-phi-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Phi _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-load-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Load _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-splat-shape-count
  [instr : ir.CompilerIrInstr]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (match instr
    [(Splat _ _ actual-lanes actual-ty)
      (if (and (= actual-lanes lanes) (tc_core.tc-type-eq actual-ty elem-ty))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-branch-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Branch _ _ _) 1]
    [(TotalEnumBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-total-enum-branch-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(TotalEnumBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bounds-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(BoundsCheck _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-return-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Return _) 1]
    [_ 0]))

(define (lower-test-shared-slice-ref-type?
  [pools : (& pools ast.AstNodePoolContext)]
  [ty : ast.AstType]) : bool
  (match ty
    [(Ref _ referent-id)
      (match (ast.ast-node-pool-context-type-get pools referent-id)
        [(Slice elem-id)
          (match (ast.ast-node-pool-context-type-get pools elem-id)
            [(I64) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (lower-test-pack-values-shape? [values : ir.CompilerIrValueSeq]) : bool
  (if (= (ir.compiler-ir-value-seq-count values) 2)
    (match (ir.compiler-ir-value-seq-ref values 1)
      [(I64 length) (= length 3)]
      [_ false])
    false))

(define (lower-test-instr-pack-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Pack _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-pack-shape-count
  [instr : ir.CompilerIrInstr]
  [pools : (& pools ast.AstNodePoolContext)]) : i64
  (match instr
    [(Pack _ values ty)
      (if (and
        (lower-test-pack-values-shape? values)
        (lower-test-shared-slice-ref-type? pools ty))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-call-count
  [instr : ir.CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(Call _ call-name _ _)
      (if (string.eq (ir.compiler-ir-symbol-text call-name) name)
        1
        0)]
    [(CallCAbiStoreResult payload-box)
      (let
        [call-name (__tl-project-field (deref payload-box) name)]
        (if (string.eq (ir.compiler-ir-symbol-text call-name) name)
          1
          0))]
    [_ 0]))

(define (lower-test-instr-cpuid-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(CpuId _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-xgetbv-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Xgetbv _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-call-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(CallIndirect _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-tail-call-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(TailCallIndirect _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-c-call-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(CallIndirectC _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-unit-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(CallIndirect _ _ _ ty)
      (match ty
        [(Unit) 1]
        [_ 0])]
    [(TailCallIndirect _ _ ty)
      (match ty
        [(Unit) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-value-function-count
  [value : ir.CompilerIrValue]
  [name : (& name str)]) : i64
  (match value
    [(Function found)
      (if (string.eq (ir.compiler-ir-symbol-text found) name)
        1
        0)]
    [_ 0]))

(define (lower-test-call-args-function-count
  [args : ir.CompilerIrCallArgs]
  [name : (& name str)]) : i64
  (match args
    [(Nil) 0]
    [(One value) (lower-test-value-function-count value name)]
    [(Two a b)
      (+
        (lower-test-value-function-count a name)
        (lower-test-value-function-count b name))]
    [(Array values) (lower-test-call-args-array-function-count values name 0)]
    [(Sret values _) (lower-test-call-args-array-function-count values name 0)]))

(define (lower-test-call-args-array-function-count
  [values : (__tl_dyn-array ir.CompilerIrValue)]
  [name : (& name str)]
  [index : i64]) : i64
  (if (>= index (array-length values))
    0
    (+
      (lower-test-value-function-count
        (ir.compiler-ir-array-shared-view values index)
        name)
      (lower-test-call-args-array-function-count values name (+ index 1)))))

(define (lower-test-instr-return-function-count
  [instr : ir.CompilerIrInstr]
  [function-name : (& function-name str)]) : i64
  (match instr
    [(Return maybe-value)
      (match maybe-value
        [(Some value) (lower-test-value-function-count value function-name)]
        [(No) 0])]
    [_ 0]))

(define (lower-test-instr-indirect-callee-function-count
  [instr : ir.CompilerIrInstr]
  [function-name : (& function-name str)]) : i64
  (match instr
    [(CallIndirect _ func _ _)
      (lower-test-value-function-count func function-name)]
    [(TailCallIndirect func _ _)
      (lower-test-value-function-count func function-name)]
    [_ 0]))

(define (lower-test-instr-call-arg-function-count
  [instr : ir.CompilerIrInstr]
  [call-name : (& call-name str)]
  [function-name : (& function-name str)]) : i64
  (match instr
    [(Call _ found args _)
      (if (string.eq (ir.compiler-ir-symbol-text found) call-name)
        (lower-test-call-args-function-count args function-name)
        0)]
    [_ 0]))

(define (lower-test-instr-tail-call-count
  [instr : ir.CompilerIrInstr]
  [name : (& name str)]) : i64
  (match instr
    [(TailCall call-name _ _)
      (if (string.eq (ir.compiler-ir-symbol-text call-name) name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-store-ptr-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(StorePtr _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-copy-bytes-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(CopyBytes _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-alloc-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Alloc _ _) 1]
    [_ 0]))

(define (lower-test-instr-addr-of-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(AddrOf _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-load-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(VectorLoad _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(VectorBinOp _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-op-count
  [instr : ir.CompilerIrInstr]
  [want : ir.CompilerIrBinOp]) : i64
  (match instr
    [(VectorBinOp payload-box)
      (let
        [op (ir.compiler-ir-box-field-shared-view payload-box op)]
        (if (lower-test-binop-same? op want)
          1
          0))]
    [_ 0]))

(define (lower-test-instr-vector-reduce-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(VectorReduce _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-store-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(VectorStore _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-load-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(PredicatedLoad _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-store-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(PredicatedStore _) 1]
    [_ 0]))

(define (lower-test-instr-select-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Select _) 1]
    [_ 0]))

(define (lower-test-instr-tail-mask-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(TailMask _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-spmd-call-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(SpmdCall _) 1]
    [_ 0]))

(define (lower-test-instr-seq-spmd-call-count [instrs : ir.CompilerIrInstrSeq]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-spmd-call-count
            (ir.compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-blocks-spmd-call-count [blocks : ir.CompilerIrBlockList]) : i64
  (match blocks
    [(Array seq) (lower-test-block-seq-spmd-call-count seq)]))

(define (lower-test-block-seq-spmd-call-count [blocks : ir.CompilerIrBlockSeq]) : i64
  (let
    [slots : (__tl_dyn-array ir.CompilerIrBlock) blocks.slots]
    [count : i64 blocks.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (match (ir.compiler-ir-array-shared-view slots index)
        [(Block _ instrs)
          (set! acc (+ acc (lower-test-instr-seq-spmd-call-count instrs)))])
      (set! index (+ index 1)))
    acc))

(define (lower-test-function-spmd-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : i64
  (lower-test-function-seq-spmd-call-count funcs name))

(define (lower-test-function-seq-spmd-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : i64
  (let
    [slots : (__tl_dyn-array ir.CompilerIrFunction) funcs.slots]
    [count : i64 funcs.len]
    [index : i64 0]
    [result : i64 (- 0 1)]
    (while (and (< index count) (< result 0))
      (match (ir.compiler-ir-array-shared-view slots index)
        [(Function fname _ _ _ blocks _)
          (if (string.eq (ir.compiler-ir-symbol-text fname) name)
            (set! result (lower-test-blocks-spmd-call-count blocks))
            unit)])
      (set! index (+ index 1)))
    result))

(define (lower-test-vector-shape?
  [actual-lanes : i64]
  [actual-ty : ast.AstType]
  [lanes : i64]
  [elem-ty : ast.AstType]) : bool
  (and (= actual-lanes lanes) (tc_core.tc-type-eq actual-ty elem-ty)))

(define (lower-test-instr-vector-shape-count
  [instr : ir.CompilerIrInstr]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (match instr
    [(VectorLoad _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(VectorBinOp payload-box)
      (let
        [actual-lanes (ir.compiler-ir-box-field-shared-view payload-box lanes)]
        [actual-ty (ir.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(VectorReduce _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(VectorStore payload-box)
      (let
        [actual-lanes (ir.compiler-ir-box-field-shared-view payload-box lanes)]
        [actual-ty (ir.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(PredicatedLoad payload-box)
      (let
        [actual-lanes (ir.compiler-ir-box-field-shared-view payload-box lanes)]
        [actual-ty (ir.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(GatherLoad payload-box)
      (let
        [actual-lanes (ir.compiler-ir-box-field-shared-view payload-box lanes)]
        [actual-ty (ir.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(PredicatedStore payload-box)
      (let
        [actual-lanes (ir.compiler-ir-box-field-shared-view payload-box lanes)]
        [actual-ty (ir.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(Select payload-box)
      (let
        [actual-lanes (ir.compiler-ir-box-field-shared-view payload-box lanes)]
        [actual-ty (ir.compiler-ir-box-field-shared-view payload-box ty)]
        (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
          1
          0))]
    [(Splat _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-u64-mov-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Mov _ _ ty)
      (match ty
        [(U64) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-binop-same?
  [actual : ir.CompilerIrBinOp]
  [want : ir.CompilerIrBinOp]) : bool
  (match actual
    [(Add)
      (match want
        [(Add) true]
        [_ false])]
    [(Sub)
      (match want
        [(Sub) true]
        [_ false])]
    [(Mul)
      (match want
        [(Mul) true]
        [_ false])]
    [(Div)
      (match want
        [(Div) true]
        [_ false])]
    [(Mod)
      (match want
        [(Mod) true]
        [_ false])]
    [(SafeDiv)
      (match want
        [(SafeDiv) true]
        [_ false])]
    [(SafeMod)
      (match want
        [(SafeMod) true]
        [_ false])]
    [(Eq)
      (match want
        [(Eq) true]
        [_ false])]
    [(Ne)
      (match want
        [(Ne) true]
        [_ false])]
    [(Lt)
      (match want
        [(Lt) true]
        [_ false])]
    [(Le)
      (match want
        [(Le) true]
        [_ false])]
    [(Gt)
      (match want
        [(Gt) true]
        [_ false])]
    [(Ge)
      (match want
        [(Ge) true]
        [_ false])]
    [(BitTestEq)
      (match want
        [(BitTestEq) true]
        [_ false])]
    [(BitTestNe)
      (match want
        [(BitTestNe) true]
        [_ false])]
    [(And)
      (match want
        [(And) true]
        [_ false])]
    [(Or)
      (match want
        [(Or) true]
        [_ false])]
    [(BitAnd)
      (match want
        [(BitAnd) true]
        [_ false])]
    [(BitOr)
      (match want
        [(BitOr) true]
        [_ false])]
    [(BitXor)
      (match want
        [(BitXor) true]
        [_ false])]
    [(Shl actual-count-ty)
      (match want
        [(Shl want-count-ty) (tc_core.tc-type-eq actual-count-ty want-count-ty)]
        [_ false])]
    [(Shr actual-count-ty)
      (match want
        [(Shr want-count-ty) (tc_core.tc-type-eq actual-count-ty want-count-ty)]
        [_ false])]))

(define (lower-test-instr-binop-op-count
  [instr : ir.CompilerIrInstr]
  [op : ir.CompilerIrBinOp]) : i64
  (match instr
    [(BinOp _ actual _ _ _)
      (if (lower-test-binop-same? actual op)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-i64-binop-op-count
  [instr : ir.CompilerIrInstr]
  [op : ir.CompilerIrBinOp]) : i64
  (match instr
    [(BinOp _ actual _ _ ty)
      (if (and
        (lower-test-binop-same? actual op)
        (match ty
          [(I64) true]
          [_ false]))
        1
        0)]
    [_ 0]))

(define (lower-test-instr-cast-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Cast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bitcast-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(Bitcast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-store-global-count
  [instr : ir.CompilerIrInstr]
  [name : (& name str)]) : i64
  (match instr
    [(Store store-name _ _)
      (if (string.eq (ir.compiler-ir-symbol-text store-name) name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-call-name?
  [instr : ir.CompilerIrInstr]
  [name : (& name str)]) : bool
  (match instr
    [(Call _ call-name _ _)
      (string.eq (ir.compiler-ir-symbol-text call-name) name)]
    [(TailCall call-name _ _)
      (string.eq (ir.compiler-ir-symbol-text call-name) name)]
    [_ false]))

(define (lower-test-instr-seq-phi-count [instrs : ir.CompilerIrInstrSeq]) : i64
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-phi-count
            (ir.compiler-ir-array-shared-view slots index))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-splat-shape-count
  [instrs : ir.CompilerIrInstrSeq]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-splat-shape-count
            (owned_view.compiler-owned-array-element-shared-view slots index)
            lanes
            (owned_view.compiler-owned-shared-view elem-ty))))
      (set! index (+ index 1)))
    acc))

;; The instruction kinds the count checks look for; each counts through its
;; own lower-test-instr-K-count predicate.
(defenum LowerTestInstr
  (AddrOf)
  (Alloc)
  (Binop)
  (Bitcast)
  (Bounds)
  (Branch)
  (Cast)
  (CopyBytes)
  (Cpuid)
  (F64Mov u64)
  (GepOffset i64)
  (I64Mov i64)
  (IndirectCCall)
  (IndirectCall)
  (IndirectTailCall)
  (IndirectUnit)
  (Load)
  (Pack)
  (PredicatedLoad)
  (PredicatedStore)
  (Return)
  (Select)
  (StorePtr)
  (TailMask)
  (TotalEnumBranch)
  (U64Mov)
  (VectorBinop)
  (VectorLoad)
  (VectorReduce)
  (VectorStore)
  (Xgetbv))

(define (lower-test-instr-count
  [instr : ir.CompilerIrInstr]
  [kind : LowerTestInstr]) : i64
  (match kind
    [(AddrOf) (lower-test-instr-addr-of-count instr)]
    [(Alloc) (lower-test-instr-alloc-count instr)]
    [(Binop) (lower-test-instr-binop-count instr)]
    [(Bitcast) (lower-test-instr-bitcast-count instr)]
    [(Bounds) (lower-test-instr-bounds-count instr)]
    [(Branch) (lower-test-instr-branch-count instr)]
    [(Cast) (lower-test-instr-cast-count instr)]
    [(CopyBytes) (lower-test-instr-copy-bytes-count instr)]
    [(Cpuid) (lower-test-instr-cpuid-count instr)]
    [(F64Mov want) (lower-test-instr-f64-mov-count instr want)]
    [(GepOffset want) (lower-test-instr-gep-offset-count instr want)]
    [(I64Mov want) (lower-test-instr-i64-mov-count instr want)]
    [(IndirectCCall) (lower-test-instr-indirect-c-call-count instr)]
    [(IndirectCall) (lower-test-instr-indirect-call-count instr)]
    [(IndirectTailCall) (lower-test-instr-indirect-tail-call-count instr)]
    [(IndirectUnit) (lower-test-instr-indirect-unit-count instr)]
    [(Load) (lower-test-instr-load-count instr)]
    [(Pack) (lower-test-instr-pack-count instr)]
    [(PredicatedLoad) (lower-test-instr-predicated-load-count instr)]
    [(PredicatedStore) (lower-test-instr-predicated-store-count instr)]
    [(Return) (lower-test-instr-return-count instr)]
    [(Select) (lower-test-instr-select-count instr)]
    [(StorePtr) (lower-test-instr-store-ptr-count instr)]
    [(TailMask) (lower-test-instr-tail-mask-count instr)]
    [(TotalEnumBranch) (lower-test-instr-total-enum-branch-count instr)]
    [(U64Mov) (lower-test-instr-u64-mov-count instr)]
    [(VectorBinop) (lower-test-instr-vector-binop-count instr)]
    [(VectorLoad) (lower-test-instr-vector-load-count instr)]
    [(VectorReduce) (lower-test-instr-vector-reduce-count instr)]
    [(VectorStore) (lower-test-instr-vector-store-count instr)]
    [(Xgetbv) (lower-test-instr-xgetbv-count instr)]))

(define (lower-test-instr-seq-count
  [instrs : ir.CompilerIrInstrSeq]
  [kind : LowerTestInstr]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-count
            (ir.compiler-ir-array-shared-view slots index)
            kind)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-blocks-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [kind : LowerTestInstr]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-count instrs kind)
            (lower-test-blocks-count rest kind))])]))

;; How many KIND instructions the function NAME holds; -1 when it is missing.
(define (lower-test-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [kind : LowerTestInstr]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-count (ir.compiler-ir-block-list-view blocks) kind)])]))

(define (lower-test-instr-seq-pack-shape-count
  [instrs : ir.CompilerIrInstrSeq]
  [pools : (& pools ast.AstNodePoolContext)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-pack-shape-count
            (ir.compiler-ir-array-shared-view slots index)
            pools)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-call-count
  [instrs : ir.CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-call-count
            (ir.compiler-ir-array-shared-view slots index)
            (ir.compiler-ir-global-shared-view name))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-call-before?
  [instrs : ir.CompilerIrInstrSeq]
  [first : (& first str)]
  [second : (& second str)]) : bool
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [seen-first : bool false]
    [done : bool false]
    [result : bool false]
    (while (and (< index count) (not done))
      (let
        [instr : ir.CompilerIrInstr
          (ir.compiler-ir-array-shared-view slots index)]
        (if (lower-test-instr-call-name?
          (ir.compiler-ir-global-shared-view instr)
          second)
          (begin
            (set! result seen-first)
            (set! done true))
          (if (lower-test-instr-call-name? instr first)
            (set! seen-first true)
            unit))
        (set! index (+ index 1))))
    result))

(define (lower-test-instr-seq-return-function-count
  [instrs : ir.CompilerIrInstrSeq]
  [function-name : (& function-name str)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-return-function-count
            (ir.compiler-ir-array-shared-view slots index)
            function-name)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-indirect-callee-function-count
  [instrs : ir.CompilerIrInstrSeq]
  [function-name : (& function-name str)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-indirect-callee-function-count
            (ir.compiler-ir-array-shared-view slots index)
            function-name)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-call-arg-function-count
  [instrs : ir.CompilerIrInstrSeq]
  [call-name : (& call-name str)]
  [function-name : (& function-name str)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-call-arg-function-count
            (ir.compiler-ir-array-shared-view slots index)
            call-name
            function-name)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-tail-call-count
  [instrs : ir.CompilerIrInstrSeq]
  [name : (& name str)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-tail-call-count
            (ir.compiler-ir-array-shared-view slots index)
            name)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-vector-binop-op-count
  [instrs : ir.CompilerIrInstrSeq]
  [want : ir.CompilerIrBinOp]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-vector-binop-op-count
            (ir.compiler-ir-array-shared-view slots index)
            (owned_view.compiler-owned-shared-view want))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-vector-shape-count
  [instrs : ir.CompilerIrInstrSeq]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-vector-shape-count
            (ir.compiler-ir-array-shared-view slots index)
            lanes
            (ast.ast-global-shared-view elem-ty))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-binop-op-count
  [instrs : ir.CompilerIrInstrSeq]
  [op : ir.CompilerIrBinOp]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-binop-op-count
            (ir.compiler-ir-array-shared-view slots index)
            (ir.compiler-ir-global-shared-view op))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-i64-binop-op-count
  [instrs : ir.CompilerIrInstrSeq]
  [op : ir.CompilerIrBinOp]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-i64-binop-op-count
            (ir.compiler-ir-array-shared-view slots index)
            (ir.compiler-ir-global-shared-view op))))
      (set! index (+ index 1)))
    acc))

(define (lower-test-instr-seq-store-global-count
  [instrs : ir.CompilerIrInstrSeq]
  [name : (& name str)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (set!
        acc
        (+
          acc
          (lower-test-instr-store-global-count
            (ir.compiler-ir-array-shared-view slots index)
            name)))
      (set! index (+ index 1)))
    acc))

(define (lower-test-blocks-phi-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-phi-count instrs)
            (lower-test-blocks-phi-count rest))])]))

(define (lower-test-blocks-splat-shape-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-splat-shape-count
              instrs
              lanes
              (owned_view.compiler-owned-shared-view elem-ty))
            (lower-test-blocks-splat-shape-count rest lanes elem-ty))])]))

(define (lower-test-blocks-label-load-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [want-label : String]) : i64
  (match blocks
    [(slice) (- 0 1)]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block label instrs)
          (if (string.eq (ir.compiler-ir-label-text label) want-label)
            (lower-test-instr-seq-count instrs (Load))
            (lower-test-blocks-label-load-count rest want-label))])]))

(define (lower-test-blocks-pack-shape-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [pools : (& pools ast.AstNodePoolContext)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-pack-shape-count instrs pools)
            (lower-test-blocks-pack-shape-count rest pools))])]))

(define (lower-test-blocks-call-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [name : String]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-call-count
              instrs
              (ir.compiler-ir-global-shared-view name))
            (lower-test-blocks-call-count rest name))])]))

(define (lower-test-blocks-call-before?
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [first : (& first str)]
  [second : (& second str)]) : bool
  (match blocks
    [(slice) false]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (if (lower-test-instr-seq-call-before? instrs first second)
            true
            (lower-test-blocks-call-before? rest first second))])]))

(define (lower-test-blocks-return-function-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [function-name : (& function-name str)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-return-function-count instrs function-name)
            (lower-test-blocks-return-function-count rest function-name))])]))

(define (lower-test-blocks-indirect-callee-function-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [function-name : (& function-name str)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-indirect-callee-function-count
              instrs
              function-name)
            (lower-test-blocks-indirect-callee-function-count
              rest
              function-name))])]))

(define (lower-test-blocks-call-arg-function-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [call-name : (& call-name str)]
  [function-name : (& function-name str)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-call-arg-function-count
              instrs
              call-name
              function-name)
            (lower-test-blocks-call-arg-function-count
              rest
              call-name
              function-name))])]))

(define (lower-test-blocks-tail-call-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [name : (& name str)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-tail-call-count instrs name)
            (lower-test-blocks-tail-call-count rest name))])]))

(define (lower-test-blocks-vector-binop-op-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [want : ir.CompilerIrBinOp]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-vector-binop-op-count
              instrs
              (owned_view.compiler-owned-shared-view want))
            (lower-test-blocks-vector-binop-op-count rest want))])]))

(define (lower-test-blocks-vector-shape-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-vector-shape-count
              instrs
              lanes
              (ast.ast-global-shared-view elem-ty))
            (lower-test-blocks-vector-shape-count rest lanes elem-ty))])]))

(define (lower-test-blocks-binop-op-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [op : ir.CompilerIrBinOp]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-binop-op-count
              instrs
              (ir.compiler-ir-global-shared-view op))
            (lower-test-blocks-binop-op-count rest op))])]))

(define (lower-test-blocks-i64-binop-op-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [op : ir.CompilerIrBinOp]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-i64-binop-op-count
              instrs
              (ir.compiler-ir-global-shared-view op))
            (lower-test-blocks-i64-binop-op-count rest op))])]))

(define (lower-test-blocks-store-global-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [name : (& name str)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-store-global-count instrs name)
            (lower-test-blocks-store-global-count rest name))])]))

;; Phi count of the function named `name`, or -1 when no such function exists
;; (so a missing function fails both the `> 0` and `= 0` assertions below).
(defenum LowerTestMaybeFunction
  (No)
  (Some ir.CompilerIrFunction))

(define (lower-test-function-seq-find-from
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [index : i64]) : LowerTestMaybeFunction
  (if (>= index funcs.len)
    (No)
    (let
      [func : ir.CompilerIrFunction
        (ir.compiler-ir-array-shared-view funcs.slots index)]
      (match (ir.compiler-ir-global-shared-view func)
        [(Function fname _ _ _ _ _)
          (if (string.eq (ir.compiler-ir-symbol-text fname) name)
            (Some func)
            (lower-test-function-seq-find-from funcs name (+ index 1)))]))))

(define (lower-test-function-seq-find
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : LowerTestMaybeFunction
  (lower-test-function-seq-find-from funcs name 0))

(define (lower-test-function-defined?
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : bool
  (match (lower-test-function-seq-find funcs name)
    [(No) false]
    [(Some _) true]))

(define (lower-test-function-param-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ params _ _ _ _) (ir.compiler-ir-param-seq-count params)])]))

(define (lower-test-param-name-at
  [params : ir.CompilerIrParamSeq]
  [index : i64]) : String
  (if (or (< index 0) (>= index params.len))
    ""
    (match (ir.compiler-ir-param-seq-ref params index)
      [(Param name _ _) name])))

(define (lower-test-function-param-name
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [index : i64]) : String
  (match (lower-test-function-seq-find funcs name)
    [(No) ""]
    [(Some func)
      (match func
        [(Function _ params _ _ _ _) (lower-test-param-name-at params index)])]))

(define (lower-test-function-phi-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-phi-count (ir.compiler-ir-block-list-view blocks))])]))

(define (lower-test-function-splat-shape-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-splat-shape-count
            (ir.compiler-ir-block-list-view blocks)
            lanes
            elem-ty)])]))

(define (lower-test-function-label-load-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [want-label : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-label-load-count
            (ir.compiler-ir-block-list-view blocks)
            want-label)])]))

(define (lower-test-function-pack-shape-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [pools : (& pools ast.AstNodePoolContext)]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-pack-shape-count
            (ir.compiler-ir-block-list-view blocks)
            pools)])]))

(define (lower-test-functions-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-call-count
                (ir.compiler-ir-block-list-view blocks)
                (ir.compiler-ir-global-shared-view name))))])
      (set! index (+ index 1)))
    count))

(define (lower-test-functions-branch-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-count
                (ir.compiler-ir-block-list-view blocks)
                (Branch))))])
      (set! index (+ index 1)))
    count))

(define (lower-test-functions-return-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-count
                (ir.compiler-ir-block-list-view blocks)
                (Return))))])
      (set! index (+ index 1)))
    count))

(define (lower-test-functions-tail-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : (& name str)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-tail-call-count
                (ir.compiler-ir-block-list-view blocks)
                name)))])
      (set! index (+ index 1)))
    count))

(define (lower-test-functions-direct-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]) : i64
  (+
    (lower-test-functions-call-count
      funcs
      (owned_view.compiler-owned-shared-view name))
    (lower-test-functions-tail-call-count funcs name)))

(define (lower-test-functions-cpuid-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-count
                (ir.compiler-ir-block-list-view blocks)
                (Cpuid))))])
      (set! index (+ index 1)))
    count))

(define (lower-test-functions-xgetbv-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-count
                (ir.compiler-ir-block-list-view blocks)
                (Xgetbv))))])
      (set! index (+ index 1)))
    count))

(define (lower-test-function-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [call-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-call-count
            (ir.compiler-ir-block-list-view blocks)
            call-name)])]))

(define (lower-test-function-call-before?
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [first : String]
  [second : String]) : bool
  (match (lower-test-function-seq-find funcs name)
    [(No) false]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-call-before?
            (ir.compiler-ir-block-list-view blocks)
            first
            second)])]))

(define (lower-test-function-return-function-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [function-name : (& function-name str)]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-return-function-count
            (ir.compiler-ir-block-list-view blocks)
            function-name)])]))

(define (lower-test-function-indirect-callee-function-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [function-name : (& function-name str)]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-indirect-callee-function-count
            (ir.compiler-ir-block-list-view blocks)
            function-name)])]))

(define (lower-test-function-call-arg-function-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [call-name : String]
  [function-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-call-arg-function-count
            (ir.compiler-ir-block-list-view blocks)
            call-name
            function-name)])]))

(define (lower-test-function-tail-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [call-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-tail-call-count
            (ir.compiler-ir-block-list-view blocks)
            call-name)])]))

(define (lower-test-function-direct-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [call-name : String]) : i64
  (+
    (lower-test-function-call-count
      funcs
      (owned_view.compiler-owned-shared-view name)
      (owned_view.compiler-owned-shared-view call-name))
    (lower-test-function-tail-call-count funcs name call-name)))

(define (lower-test-values-distinct-vars
  [a : ir.CompilerIrValue]
  [b : ir.CompilerIrValue]) : i64
  (match a
    [(Var a-id)
      (match b
        [(Var b-id)
          (if (= a-id b-id)
            0
            1)]
        [_ 0])]
    [_ 0]))

(define (lower-test-call-args-array-distinct-vars
  [values : (__tl_dyn-array ir.CompilerIrValue)]) : i64
  (if (< (array-length values) 2)
    0
    (lower-test-values-distinct-vars
      (ir.compiler-ir-array-shared-view values 0)
      (ir.compiler-ir-array-shared-view values 1))))

;; 1 when the call's first two arguments are two different variables.
(define (lower-test-call-args-distinct-vars [args : ir.CompilerIrCallArgs]) : i64
  (match args
    [(Two a b) (lower-test-values-distinct-vars a b)]
    [(Array values) (lower-test-call-args-array-distinct-vars values)]
    [(Sret values _) (lower-test-call-args-array-distinct-vars values)]
    [_ 0]))

(define (lower-test-instr-seq-distinct-arg-call-count
  [instrs : ir.CompilerIrInstrSeq]
  [call-name : (& call-name str)]) : i64
  (let
    [count : i64 instrs.len]
    [slots : (__tl_dyn-array ir.CompilerIrInstr) instrs.slots]
    [index : i64 0]
    [acc : i64 0]
    (while (< index count)
      (match (ir.compiler-ir-array-shared-view slots index)
        [(Call _ found args _)
          (when
            (string.eq (ir.compiler-ir-symbol-text found) call-name)
            (set! acc (+ acc (lower-test-call-args-distinct-vars args))))]
        [_ unit])
      (set! index (+ index 1)))
    acc))

(define (lower-test-blocks-distinct-arg-call-count
  [blocks : (& blocks (Slice ir.CompilerIrBlock))]
  [call-name : (& call-name str)]) : i64
  (match blocks
    [(slice) 0]
    [(slice block & rest)
      (match (owned_view.compiler-owned-reference-shared-view block)
        [(Block _ instrs)
          (+
            (lower-test-instr-seq-distinct-arg-call-count instrs call-name)
            (lower-test-blocks-distinct-arg-call-count rest call-name))])]))

;; How many `call-name` calls in `name` pass two different variables as their
;; first two arguments.
(define (lower-test-function-distinct-arg-call-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [call-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-distinct-arg-call-count
            (ir.compiler-ir-block-list-view blocks)
            call-name)])]))

(define (lower-test-function-vector-binop-op-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [want : ir.CompilerIrBinOp]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-vector-binop-op-count
            (ir.compiler-ir-block-list-view blocks)
            want)])]))

(define (lower-test-function-vector-shape-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [lanes : i64]
  [elem-ty : ast.AstType]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-vector-shape-count
            (ir.compiler-ir-block-list-view blocks)
            lanes
            elem-ty)])]))

(define (lower-test-function-binop-op-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [op : ir.CompilerIrBinOp]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-binop-op-count
            (ir.compiler-ir-block-list-view blocks)
            op)])]))

(define (lower-test-function-i64-binop-op-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [op : ir.CompilerIrBinOp]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-i64-binop-op-count
            (ir.compiler-ir-block-list-view blocks)
            op)])]))

(define (lower-test-functions-bitcast-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index funcs.len)
      (match (ir.compiler-ir-array-shared-view funcs.slots index)
        [(Function _ _ _ _ blocks _)
          (set!
            count
            (+
              count
              (lower-test-blocks-count
                (ir.compiler-ir-block-list-view blocks)
                (Bitcast))))])
      (set! index (+ index 1)))
    count))

(define (lower-test-function-store-global-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [global-name : String]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) (- 0 1)]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-store-global-count
            (ir.compiler-ir-block-list-view blocks)
            global-name)])]))

(define (lower-test-global-seq-has-name-at?
  [globals : ir.CompilerIrGlobalSeq]
  [name : String]
  [index : i64]) : bool
  (if (>= index globals.len)
    false
    (match (ir.compiler-ir-global-seq-ref globals index)
      [(Global global-name _ _)
        (if (string.eq (ir.compiler-ir-symbol-text global-name) name)
          true
          (lower-test-global-seq-has-name-at? globals name (+ index 1)))])))

(define (lower-test-global-list-has-name?
  [globals : (& globals ir.CompilerIrGlobalSeq)]
  [name : String]) : bool
  (let
    [globals : ir.CompilerIrGlobalSeq
      (owned_view.compiler-owned-reference-shared-view globals)]
    (lower-test-global-seq-has-name-at? globals name 0)))

(define (lower-test-global-function-initializer-at?
  [globals : ir.CompilerIrGlobalSeq]
  [global-name : String]
  [function-name : String]
  [index : i64]) : bool
  (if (>= index globals.len)
    false
    (match (ir.compiler-ir-global-seq-ref globals index)
      [(Global name _ initial)
        (if (string.eq (ir.compiler-ir-symbol-text name) global-name)
          (match initial
            [(Function found)
              (string.eq (ir.compiler-ir-symbol-text found) function-name)]
            [_ false])
          (lower-test-global-function-initializer-at?
            globals
            global-name
            function-name
            (+ index 1)))])))

(define (lower-test-global-function-initializer?
  [globals : ir.CompilerIrGlobalSeq]
  [global-name : String]
  [function-name : String]) : bool
  (lower-test-global-function-initializer-at?
    globals
    global-name
    function-name
    0))

(define (lower-test-dispatch-cache-word-at?
  [globals : ir.CompilerIrGlobalSeq]
  [name : (& name str)]
  [index : i64]) : bool
  (if (>= index globals.len)
    false
    (match (ir.compiler-ir-global-seq-ref globals index)
      [(Global global-name ty initial)
        (if (string.eq (ir.compiler-ir-symbol-text global-name) name)
          (match ty
            [(I64)
              (match initial
                [(Unit) true]
                [_ false])]
            [_ false])
          (lower-test-dispatch-cache-word-at? globals name (+ index 1)))])))

(define (lower-test-dispatch-cache-word?
  [globals : ir.CompilerIrGlobalSeq]
  [name : (& name str)]) : bool
  (lower-test-dispatch-cache-word-at? globals name 0))

(define (compiler-lower-defdispatch-thunk-shape-ok?) : bool
  (match (lower.lower-compiler-source (compiler-lower-defdispatch-source))
    [(Ok program _)
      (match program
        [(Program globals functions _)
          (let
            [cache-name : String "__tl_dispatch_cache_dot"]
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            (and
              (lower-test-dispatch-cache-word? globals cache-name)
              (lower-test-function-defined? functions "dot")
              (lower-test-function-defined?
                functions
                (owned_view.compiler-owned-shared-view scalar-name))
              (lower-test-function-defined?
                functions
                (owned_view.compiler-owned-shared-view avx2-name))
              (lower-test-function-defined?
                functions
                (owned_view.compiler-owned-shared-view avx512-name))
              (not (lower-test-function-defined? functions "dot-scalar"))
              (not (lower-test-function-defined? functions "dot-avx2"))
              (not (lower-test-function-defined? functions "dot-avx512"))
              (= (lower-test-function-call-count functions "main" "dot") 1)
              (>= (lower-test-count functions "dot" (IndirectCall)) 4)
              (=
                (lower-test-function-store-global-count
                  functions
                  "dot"
                  cache-name)
                0)
              (=
                (lower-test-function-call-count
                  functions
                  "dot"
                  "tl_atomic_i64_load_ptr")
                1)
              (=
                (lower-test-function-call-count
                  functions
                  "dot"
                  "tl_atomic_i64_cas_ptr")
                3)
              (= (lower-test-count functions "dot" (Select)) 3)
              (= (lower-test-count functions "dot" (Cast)) 4)
              (>= (lower-test-functions-cpuid-count functions) 6)
              (= (lower-test-functions-xgetbv-count functions) 2)
              (=
                (lower-test-function-call-arg-function-count
                  functions
                  "dot"
                  "tl_atomic_i64_cas_ptr"
                  scalar-name)
                1)
              (=
                (lower-test-function-call-arg-function-count
                  functions
                  "dot"
                  "tl_atomic_i64_cas_ptr"
                  avx2-name)
                1)
              (=
                (lower-test-function-call-arg-function-count
                  functions
                  "dot"
                  "tl_atomic_i64_cas_ptr"
                  avx512-name)
                1)))])]
    [(Err _) false]))

(define (compiler-lower-defdispatch-structural-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-defdispatch-structural-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (lower-test-function-defined? functions "dot")
        (= (lower-test-function-call-count functions "main" "dot") 1)
        (>= (lower-test-count functions "dot" (IndirectCall)) 1))]
    [_ false]))

(define (compiler-lower-defdispatch-shared-helper-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-defdispatch-shared-helper-source)))
    [(Some functions)
      (let
        [scalar-name : String "__tl_dispatch_variant_scalar_dot__dot-scalar"]
        [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
        [avx512-name : String "__tl_dispatch_variant_avx512_dot__dot-avx512"]
        (and
          (lower-test-function-defined? functions "dispatch-helper")
          (not (lower-test-function-defined? functions "dot-scalar"))
          (not (lower-test-function-defined? functions "dot-avx2"))
          (not (lower-test-function-defined? functions "dot-avx512"))
          (=
            (lower-test-function-direct-call-count
              functions
              scalar-name
              "dispatch-helper")
            1)
          (=
            (lower-test-function-direct-call-count
              functions
              avx2-name
              "dispatch-helper")
            1)
          (=
            (lower-test-function-direct-call-count
              functions
              avx512-name
              "dispatch-helper")
            1)))]
    [_ false]))

(define (compiler-lower-generated-path-source) : String
  "(defstruct Point (x i64))
(defstruct Point (x i64))
(define (after [x : i64]) : i64 (+ x 1))
(define (main) : i64 (after 41))")

(define (compiler-lower-generated-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "gen.tl"
    (ast.ast-decl-root-path-cons
      "gen.tl"
      (ast.ast-decl-root-path-cons
        "lib.tl"
        (ast.ast-decl-root-path-cons "app.tl" (ast.ast-decl-path-list-new))))))

(define (compiler-lower-generated-paths-preserved-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-generated-path-source))
    [(Ok program)
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            [args : ast.AstExprList (ast.ast-expr-list-new)]
            (ast.ast-expr-list-push
              (&mut args)
              (ast.ast-node-push
                (Literal (ast.ast-lit-generated-string "same"))))
            (set!
              (array-ref decls.slots decls.offset)
              (ast.ast-decl-comptime-decl-with-meta
                (Some
                  "point-family"
                  "Point"
                  (owned_view.compiler-owned-shared-view args)
                  "")
                (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))))
            (set!
              (array-ref decls.slots (+ decls.offset 1))
              (ast.ast-decl-comptime-decl-with-meta
                (Some "point-family" "Point" args "")
                (ast.ast-decl-list-get (& decls) 1 (ast.ast-decl-fallback))))
            (match (lower-test-functions
              (lower-compiler-program-with-decl-paths
                "app.tl"
                program
                (compiler-lower-generated-paths)))
              [(Some functions)
                (and
                  (lower-test-function-defined? functions "lib.tl::after")
                  (lower-test-function-defined? functions "main")
                  (=
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      "lib.tl::after")
                    1))]
              [_ false]))])]
    [(Err _) false]))

(define (compiler-lower-module-symbol-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x answer))
(define (main) : i64 (inc answer))")

(define (compiler-lower-module-symbol-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "lib.tl"
    (ast.ast-decl-root-path-cons
      "lib.tl"
      (ast.ast-decl-root-path-cons "app.tl" (ast.ast-decl-path-list-new)))))

(define (compiler-lower-module-symbols-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-module-symbol-source))
    [(Ok program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-symbol-paths))
        [(Ok lowered _)
          (match lowered
            [(Program globals functions _)
              (and
                (lower-test-global-list-has-name? globals "lib.tl::answer")
                (>
                  (lower-test-functions-direct-call-count
                    functions
                    "lib.tl::inc")
                  0)
                (> (lower-test-count functions "lib.tl::inc" (Binop)) 0)
                (>= (lower-test-count functions "main" (Binop)) 0))])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-lower-package-owned-symbol-source) : String
  "(define (runtime-helper) : i64 1)
(define (app-helper) : i64 41)
(define (main) : i64 (+ (runtime-helper) (app-helper)))")

(define (compiler-lower-package-owned-symbol-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (ast.ast-decl-root-path-cons
      "app/src/main.tl"
      (ast.ast-decl-root-path-cons "" (ast.ast-decl-path-list-new)))))

(define (compiler-lower-package-owned-symbols-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-package-owned-symbol-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          ""
          program
          (compiler-lower-package-owned-symbol-paths)))
        [(Some functions)
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
              1))]
        [_ false])]
    [(Err _) false]))

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
  (match (lower.lower-compiler-source (compiler-lower-module-qualified-source))
    [(Ok lowered _)
      (match lowered
        [(Program globals functions _)
          (and
            (lower-test-global-list-has-name? globals "left/same")
            (lower-test-global-list-has-name? globals "right/same")
            (> (lower-test-functions-call-count functions "left/get") 0)
            (> (lower-test-functions-call-count functions "right/get") 0)
            (> (lower-test-count functions "main" (Binop)) 0))])]
    [(Err _) false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-import-alias-source)))
    [(Some functions)
      (and
        (> (lower-test-functions-call-count functions "data/get") 0)
        (= (lower-test-functions-call-count functions "d/get") 0))]
    [_ false]))

(define (compiler-lower-package-alias-collision-source) : String
  "(module left.src.lib)
(define (same [value : i64]) : i64 (+ value 11))
(module right.src.lib)
(define (same [value : i64]) : i64 (+ value 21))
(module consumer.src.main)
(import left.src.lib as left)
(import right.src.lib as right)
(define (main) : i64 (+ (left.same 1) (right.same 1)))")

(define (compiler-lower-package-alias-collision-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "surface_left/src/lib.tl"
    (ast.ast-decl-root-path-cons
      "surface_left/src/lib.tl"
      (ast.ast-decl-root-path-cons
        "surface_right/src/lib.tl"
        (ast.ast-decl-root-path-cons
          "surface_right/src/lib.tl"
          (ast.ast-decl-root-path-cons
            "consumer/src/main.tl"
            (ast.ast-decl-root-path-cons
              "consumer/src/main.tl"
              (ast.ast-decl-root-path-cons
                "consumer/src/main.tl"
                (ast.ast-decl-root-path-cons
                  "consumer/src/main.tl"
                  (ast.ast-decl-path-list-new))))))))))

(define (compiler-lower-dotted-import-default-alias-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(module main)
(import pkg.data)
(define (main) : i64 (+ (data.get) 1))")

(define (compiler-lower-dotted-import-default-alias-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-dotted-import-default-alias-source)))
    [(Some functions)
      (and
        (> (lower-test-functions-call-count functions "pkg.data/get") 0)
        (= (lower-test-functions-call-count functions "data/get") 0))]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-dotted-import-string-call-source)))
    [(Some functions)
      (> (lower-test-functions-call-count functions "pkg.string/eq") 0)]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-module-function-returning-struct-source)))
    [(Some functions)
      (> (lower-test-functions-call-count functions "data/cand-nth") 0)]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-module-function-returning-enum-source)))
    [(Some functions)
      (> (lower-test-functions-call-count functions "main/get") 0)]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-imported-enum-aggregate-payload-source)))
    [(Some functions)
      (> (lower-test-count functions "main/make" (CopyBytes)) 0)]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-module-macro-codegen-source)))
    [(Some functions)
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
          1))]
    [_ false]))

(define (compiler-lower-module-macro-global-init-source) : String
  "(defmacro (global-module) : Module
  `(begin
    (module generated.global_init_user)
    (define answer : i64 (+ 40 2))
    (define (read-answer) : i64 answer)))
(import (global-module) as generated)
(define (main) : i64 (+ generated.answer (generated.read-answer)))")

(define (compiler-lower-module-macro-global-init-ok?) : bool
  (match (lower.lower-compiler-source
    (compiler-lower-module-macro-global-init-source))
    [(Ok lowered _)
      (match lowered
        [(Program globals functions _)
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
    [(Err _) false]))

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
  (match (lower.lower-compiler-source
    (compiler-lower-module-macro-stdlib-vector-import-source))
    [(Ok _ _) true]
    [(Err _) false]))

(define (compiler-lower-function-decl-count-wrapped-ok?) : bool
  (let
    [fn : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (lower-test-generated-name-id "generated")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))]
    (and
      (=
        (lower.lower-function-decl-count
          (ast.ast-decl-cons
            (ast.ast-decl-comptime-decl
              (ast.ast-decl-unsafe (owned_view.compiler-owned-shared-view fn)))
            (ast.ast-decl-list-new)))
        1)
      (=
        (lower.lower-function-decl-count
          (ast.ast-decl-cons
            (ast.ast-decl-unsafe (ast.ast-decl-comptime-decl fn))
            (ast.ast-decl-list-new)))
        1))))

(define (compiler-lower-module-specialize-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64)
  (__tl_make-array T n))
(define (main) : (__tl_dyn-array i64)
  (alloc (type i64) 4))")

(define (compiler-lower-module-specialize-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "app.tl"
    (ast.ast-decl-root-path-cons "app.tl" (ast.ast-decl-path-list-new))))

(define (compiler-lower-module-specialize-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-module-specialize-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "app.tl"
          program
          (compiler-lower-module-specialize-paths)))
        [(Some functions)
          (>
            (lower-test-functions-direct-call-count
              functions
              "__tl_specialized_alloc_type_i64_none")
            0)]
        [_ false])]
    [(Err _) false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-unsupported-aggregate-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "big-use") 1)
        ;; `Big` is a 16-byte all-integer struct, register-resident,
        ;; so building `(Big 1 2)` does not heap-allocate -- the value is
        ;; constructed in a register pair. The Win64 C ABI still requires the
        ;; >8 B aggregate to be passed BY REFERENCE: the register pair is
        ;; spilled into a frame temporary (two 8-byte slots and their
        ;; address), not an arena buffer, so nothing calls tl_alloc (#7885).
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (Alloc)) 2)
        (>= (lower-test-count functions "main" (AddrOf)) 1))]
    [_ false]))

(define (compiler-lower-c-abi-windows-byref-aggregate-temps-source) : String
  "(defstruct Big (lo i64) (hi i64))
(defstruct Wide (a i64) (b i64) (c i64))
(extern (big-pair-use [arg0 : Big] [arg1 : Big]) : i64 (:symbol \"tl_cabi_big_pair_use\"))
(extern (wide-pair-use [arg0 : Wide] [arg1 : Wide]) : i64 (:symbol \"tl_cabi_wide_pair_use\"))
(extern (made-pair-use [arg0 : Big] [arg1 : Big]) : i64 (:symbol \"tl_cabi_made_pair_use\"))
(extern (big-make [seed : i64]) : Big (:symbol \"tl_cabi_big_make\"))
(define (main) : i64
  (let
    [big : Big (Big 1 2)]
    [wide : Wide (Wide 3 4 5)]
    (+
      (big-pair-use big big)
      (+ (wide-pair-use wide wide) (made-pair-use (big-make 7) (big-make 8))))))")

;; Every Win64 by-reference argument gets its own frame temporary: the callee
;; may write through either pointer, so two arguments built from the same value,
;; register-resident or memory-class, and call results passed straight on,
;; never share one copy. None of the six copies allocates (#7885), and neither
;; do the hidden-sret result buffers of `big-make` (#7990).
(define (compiler-lower-c-abi-windows-byref-aggregate-temps-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-windows-byref-aggregate-temps-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (=
          (lower-test-function-distinct-arg-call-count
            functions
            "main"
            "big-pair-use")
          1)
        (=
          (lower-test-function-distinct-arg-call-count
            functions
            "main"
            "wide-pair-use")
          1)
        (=
          (lower-test-function-distinct-arg-call-count
            functions
            "main"
            "made-pair-use")
          1))]
    [_ false]))

(define (compiler-lower-c-abi-result-frame-storage-source) : String
  "(defstruct Triple (:repr c) (a i64) (b i64) (c i64))
(defstruct Pair (:repr c) (a i64) (b i64))
(defstruct IntFloat (:repr c) (a i32) (b f32))
(extern (triple-make [seed : i64]) : Triple (:symbol \"tl_cabi_triple_make\"))
(extern triple-maker (:symbol \"tl_cabi_triple_make_ptr\") : (CFunc non-null (-> i64 Triple)))
(extern (pair-make [seed : i64]) : Pair (:symbol \"tl_cabi_pair_make\"))
(extern (int-float-make [seed : i32]) : IntFloat (:symbol \"tl_cabi_int_float_make\"))
(define (main) : i64
  (let
    [t : Triple (triple-make 7)]
    [u : Triple (triple-maker 8)]
    [p : Pair (pair-make 9)]
    [f : IntFloat (int-float-make (cast 10 : i32))]
    (+ t.c (+ u.c (+ p.b (cast f.a : i64))))))")

;; A C aggregate result lands in caller frame storage whether it comes back
;; through a hidden result pointer (`Triple`, directly and through a `CFunc`;
;; `Pair` on Win64), in two registers (`Pair` on SysV), or in one register
;; holding a value TypeLisp keeps in memory (`IntFloat`). Nothing calls
;; tl_alloc (#7990). The four results need 3 + 3 + 2 + 1 frame slots, each
;; result's own, and one address per result.
(define (compiler-lower-c-abi-result-frame-storage-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-result-frame-storage-source)
      mode))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (= (lower-test-function-call-count functions "main" "triple-make") 1)
        (= (lower-test-count functions "main" (IndirectCCall)) 1)
        (>= (lower-test-count functions "main" (Alloc)) 9)
        (>= (lower-test-count functions "main" (AddrOf)) 4))]
    [_ false]))

(define (compiler-lower-c-abi-windows-nested-small-aggregate-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-windows-nested-small-aggregate-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (=
        (lower-test-function-call-count functions "main" "outer-float-box-use")
        1)]
    [_ false]))

(define (compiler-lower-c-abi-windows-small-float-aggregate-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-windows-small-float-aggregate-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (and
        (=
          (lower-test-function-call-count functions "main" "float-pair-make")
          1)
        (= (lower-test-function-call-count functions "main" "float-pair-use") 1)
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (Bitcast)) 2))]
    [_ false]))

(define (compiler-lower-extern-link-inputs-ok?
  [inputs : ast.AstExternLinkInputList]) : bool
  (and
    (= (ast.ast-extern-link-input-list-len (& inputs)) 3)
    (match (ast.ast-extern-link-input-list-get
      (& inputs)
      0
      (ast.ast-extern-link-input-fallback))
      [(Lib lib) (string.eq lib "ffi")]
      [_ false])
    (match (ast.ast-extern-link-input-list-get
      (& inputs)
      1
      (ast.ast-extern-link-input-fallback))
      [(Search dir) (string.eq dir "native")]
      [_ false])
    (match (ast.ast-extern-link-input-list-get
      (& inputs)
      2
      (ast.ast-extern-link-input-fallback))
      [(Arg arg-value) (string.eq arg-value "-Wl,--as-needed")]
      [_ false])))

(define (compiler-lower-extern-link-metadata-ok?) : bool
  (match (lower.lower-compiler-source
    (compiler-lower-extern-link-metadata-source))
    [(Ok program _)
      (match program
        [(Program _ _ externs)
          (and
            (= externs.len 1)
            (match (ir.compiler-ir-extern-seq-ref externs 0)
              [(Extern name-id name-id name _ abi symbol-id link-inputs _)
                (and
                  (string.eq (ci.intern-str name-id) "ffi-add")
                  (string.eq name "ffi-add")
                  (string.eq (ci.intern-str symbol-id) "ffi_add")
                  (ast.ast-extern-abi-c? abi)
                  (compiler-lower-extern-link-inputs-ok? link-inputs))]))])]
    [(Err _) false]))

(define (compiler-lower-extern-value-fnptr-source) : String
  "(extern raw-value (:symbol \"tl_test_raw_value\") : i64)
(extern raw-fn (:symbol \"tl_test_raw_fn\") : (CFunc non-null (-> i64 i64)))
(extern (direct-fn [x : i64]) : i64 (:symbol \"tl_test_direct_fn\"))
(extern (resolve [name : (Ptr u8)]) : (CFunc non-null (-> i64 i64)) (:symbol \"tl_test_resolve\"))
(define (main) : i64
  (let
    [copied : (CFunc non-null (-> i64 i64)) raw-fn]
    [resolved : (CFunc non-null (-> i64 i64)) (resolve (ptr-null : (Ptr u8)))]
    (+ raw-value (+ (raw-fn 41) (+ (copied 40) (+ (resolved 39) (direct-fn 1)))))))")

(define (compiler-lower-extern-value-fnptr-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-extern-value-fnptr-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "raw-fn") 0)
        (= (lower-test-function-call-count functions "main" "direct-fn") 1)
        (= (lower-test-function-call-count functions "main" "resolve") 1)
        (= (lower-test-count functions "main" (IndirectCall)) 0)
        (= (lower-test-count functions "main" (IndirectCCall)) 3))]
    [_ false]))

(test
  compiler-lower-extern-value-fnptr-shape
  (test.assert-true
    (compiler-lower-extern-value-fnptr-shape-ok?)
    "bare and dynamically returned raw C function pointers use indirect C ABI calls"))

(define (compiler-lower-extern-returned-fnptr-to-tl-param-source) : String
  "(extern (resolve [name : (Ptr u8)]) : (-> i64 i64) (:symbol \"tl_test_resolve\"))
(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64 (f x))
(define (main) : i64
  (apply1 (resolve (ptr-null : (Ptr u8))) 41))")

(test
  compiler-lower-extern-returned-fnptr-flow-reject
  (test.assert-true
    (compiler-lower-error-ok?
      (compiler-lower-extern-returned-fnptr-to-tl-param-source)
      "typecheck: raw C function pointer requires an explicit CFunc type")
    "dynamically returned raw C function pointers cannot flow into TypeLisp callback positions"))

(define (compiler-lower-c-abi-linux-tag-only-enum-source) : String
  "(defenum Status (Ready) (Done) (Failed))
(extern (status-next [arg0 : Status]) : Status (:symbol \"tl_cabi_status_next\"))
(extern status-score-ptr (:symbol \"tl_cabi_status_score_ptr\") : (CFunc non-null (->
  Status
  i64
  i64)))
(define (status-rank [s : Status]) : i64
  (match s
    [Ready 1]
    [Done 2]
    [Failed 3]))
(define (main) : i64
  (let
    [score-copy : (CFunc non-null (-> Status i64 i64)) status-score-ptr]
    [ready : Status (Ready)]
    [done : Status (status-next ready)]
    [failed : Status (status-next done)]
    [score : i64 (score-copy failed 7)]
    (+ score (status-rank done))))")

(define (compiler-lower-c-abi-linux-tag-only-enum-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-linux-tag-only-enum-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "status-next") 2)
        (= (lower-test-count functions "main" (IndirectCCall)) 1)
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0))]
    [_ false]))

(define (compiler-lower-c-abi-payload-enum-source) : String
  "(defenum SmallChoice (None) (Some i64))
(defstruct SmallBox (choice SmallChoice))
(defenum WideChoice (None) (Some u64 u64))
(extern (small-score [arg : SmallChoice]) : i64 (:symbol \"tl_cabi_small_score\"))
(extern small-score-ptr (:symbol \"tl_cabi_small_score_ptr\") : (CFunc non-null (-> SmallChoice i64)))
(extern (box-score [arg : SmallBox]) : i64 (:symbol \"tl_cabi_box_score\"))
(extern (box-make [seed : i64]) : SmallBox (:symbol \"tl_cabi_box_make\"))
(extern (wide-make [seed : u64]) : WideChoice (:symbol \"tl_cabi_wide_make\"))
(define (wide-score [w : WideChoice]) : i64
  (match w
    [WideChoice.None 0]
    [(WideChoice.Some lo hi) (+ (cast lo : i64) (cast hi : i64))]))
(define (main) : i64
  (let
    [copy : (CFunc non-null (-> SmallChoice i64)) small-score-ptr]
    [boxed : SmallBox (box-make 5)]
    [made : WideChoice (wide-make (cast 10 : u64))]
    (+ (small-score (SmallChoice.Some 11)) (+ (copy SmallChoice.None) (+ (box-score boxed) (wide-score made))))))")

(define (compiler-lower-c-abi-linux-payload-enum-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-payload-enum-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "small-score") 1)
        (= (lower-test-function-call-count functions "main" "box-score") 1)
        (= (lower-test-function-call-count functions "main" "box-make") 1)
        (= (lower-test-function-call-count functions "main" "wide-make") 1)
        (= (lower-test-count functions "main" (IndirectCCall)) 1))]
    [_ false]))

(define (compiler-lower-c-abi-windows-enum-aggregate-source) : String
  "(defenum Status (Ready) (Done) (Failed))
(defenum SmallChoice (None) (Some i64))
(defenum WideChoice (None) (Some u64 f64))
(defenum ReturnChoice (None) (Pair u64 u64))
(extern (status-pick [arg0 : Status] [arg1 : Status] [choose-second : i64]) : Status (:symbol \"tl_win64_status_pick\"))
(extern status-pick-ptr (:symbol \"tl_win64_status_pick_ptr\") : (CFunc non-null (->
  Status
  Status
  i64
  Status)))
(extern (small-score [arg : SmallChoice] [bias : i64]) : i64 (:symbol \"tl_win64_small_score\"))
(extern small-scorer (:symbol \"tl_win64_small_score_ptr\") : (CFunc non-null (->
  SmallChoice
  i64
  i64)))
(extern (wide-score [arg : WideChoice] [tag : u64]) : i64 (:symbol \"tl_win64_wide_score\"))
(extern wide-scorer (:symbol \"tl_win64_wide_score_ptr\") : (CFunc non-null (->
  WideChoice
  u64
  i64)))
(extern (return-choice-make [a : u32] [b : u32] [tag : u64]) : ReturnChoice (:symbol \"tl_win64_return_choice_make\"))
(extern return-choice-maker (:symbol \"tl_win64_return_choice_make_ptr\") : (CFunc non-null (->
  u32
  u32
  u64
  ReturnChoice)))
(define (return-score [r : ReturnChoice]) : i64
  (match r
    [ReturnChoice.None 0]
    [(ReturnChoice.Pair lo hi) (+ (cast lo : i64) (cast hi : i64))]))
(define (main) : i64
  (let
    [status-copy : (CFunc non-null (-> Status Status i64 Status)) status-pick-ptr]
    [small-copy : (CFunc non-null (-> SmallChoice i64 i64)) small-scorer]
    [wide-copy : (CFunc non-null (-> WideChoice u64 i64)) wide-scorer]
    [return-copy : (CFunc non-null (-> u32 u32 u64 ReturnChoice)) return-choice-maker]
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
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-c-abi-windows-enum-aggregate-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "status-pick") 1)
        (= (lower-test-function-call-count functions "main" "small-score") 1)
        (= (lower-test-function-call-count functions "main" "wide-score") 1)
        (=
          (lower-test-function-call-count functions "main" "return-choice-make")
          1)
        (= (lower-test-count functions "main" (IndirectCCall)) 4)
        ;; The two by-reference `WideChoice` arguments are copied into
        ;; frame temporaries (#7885), and the hidden-sret result buffers
        ;; of the `ReturnChoice` calls are frame storage too (#7990).
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0))]
    [_ false]))

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
  (match (lower.lower-compiler-source (compiler-lower-global-source))
    [(Ok program _)
      (match program
        [(Program globals functions externs)
          (and
            (= globals.len 3)
            (= externs.len 1)
            (lower-test-global-list-has-name? globals "answer")
            (lower-test-global-list-has-name? globals "flag")
            (lower-test-global-list-has-name? globals "widened")
            (= (ir.compiler-ir-extern-seq-count externs) 1)
            (>
              (lower-test-function-store-global-count functions "main" "answer")
              0))])]
    [(Err _) false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-numeric-source)))
    [(Some functions)
      (and
        (> (lower-test-function-binop-op-count functions "bits" BitAnd) 1)
        (> (lower-test-function-binop-op-count functions "bits" BitOr) 0)
        (> (lower-test-function-binop-op-count functions "bits" BitXor) 1)
        (> (lower-test-function-binop-op-count functions "bits" (Shl (I32))) 0)
        (> (lower-test-function-binop-op-count functions "bits" (Shr (I32))) 0)
        (> (lower-test-function-binop-op-count functions "floaty" Add) 0)
        (> (lower-test-function-binop-op-count functions "floaty" Lt) 0)
        (> (lower-test-count functions "casts" (Cast)) 0))]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-simple-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "loop" "loop") 1)
        (= (lower-test-function-call-count functions "loop" "loop") 0))]
    [_ false]))

(define (compiler-lower-tail-context-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-context-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "loop" "loop") 1)
        (= (lower-test-function-call-count functions "loop" "loop") 0))]
    [_ false]))

(define (compiler-lower-tail-operand-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-operand-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "loop" "loop") 0)
        (> (lower-test-function-call-count functions "loop" "loop") 0))]
    [_ false]))

(define (compiler-lower-tail-direct-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-direct-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "finish") 1)
        (= (lower-test-function-call-count functions "step" "finish") 0))]
    [_ false]))

(define (compiler-lower-tail-direct-stack-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-direct-stack-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step5" "finish5") 1)
        (= (lower-test-function-call-count functions "step5" "finish5") 0))]
    [_ false]))

(define (compiler-lower-tail-aggregate-return-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-aggregate-return-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "step") 1)
        (= (lower-test-function-call-count functions "step" "step") 0)
        (= (lower-test-function-tail-call-count functions "step" "finish") 1)
        (= (lower-test-function-call-count functions "step" "finish") 0))]
    [_ false]))

(define (compiler-lower-tail-aggregate-param-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-aggregate-param-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "step") 1)
        (= (lower-test-function-call-count functions "step" "step") 0)
        (= (lower-test-function-tail-call-count functions "step" "finish") 1)
        (= (lower-test-function-call-count functions "step" "finish") 0))]
    [_ false]))

(define (compiler-lower-tail-aggregate-local-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-aggregate-local-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "finish") 0)
        (> (lower-test-function-call-count functions "step" "finish") 0))]
    [_ false]))

(define (compiler-lower-tail-aggregate-reassigned-param-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-tail-aggregate-reassigned-param-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "finish") 0)
        (> (lower-test-function-call-count functions "step" "finish") 0))]
    [_ false]))

(define (compiler-lower-tail-indirect-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-indirect-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "step" (IndirectTailCall)) 1)
        (= (lower-test-count functions "step" (IndirectCall)) 0))]
    [_ false]))

(define (compiler-lower-tail-indirect-aggregate-param-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-tail-indirect-aggregate-param-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "step" (IndirectTailCall)) 1)
        (= (lower-test-count functions "step" (IndirectCall)) 0))]
    [_ false]))

(define (compiler-lower-tail-indirect-aggregate-return-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-tail-indirect-aggregate-return-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "step" (IndirectTailCall)) 1)
        (= (lower-test-count functions "step" (IndirectCall)) 0))]
    [_ false]))

(define (compiler-lower-tail-cleanup-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tail-cleanup-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "finish") 0)
        (> (lower-test-function-call-count functions "step" "finish") 0))]
    [_ false]))

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
  [instr : ir.CompilerIrInstr]
  [want : i64]) : i64
  (match instr
    [(Mov _ value _)
      (match value
        [(I64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-f64-mov-count
  [instr : ir.CompilerIrInstr]
  [want : u64]) : i64
  (match instr
    [(Mov _ value _)
      (match value
        [(F64 bits)
          (if (= bits want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-binop-count [instr : ir.CompilerIrInstr]) : i64
  (match instr
    [(BinOp _ _ _ _ _) 1]
    [(UnOp _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-gep-offset-count
  [instr : ir.CompilerIrInstr]
  [want : i64]) : i64
  (match instr
    [(Gep _ _ offset _)
      (match offset
        [(I64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-function-i64-mov-count
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [want : i64]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) 0]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-count
            (ir.compiler-ir-block-list-view blocks)
            (I64Mov want))])]))

(define (lower-test-function-f64-mov-count-bits
  [funcs : (& funcs ir.CompilerIrFunctionSeq)]
  [name : String]
  [want : u64]) : i64
  (match (lower-test-function-seq-find funcs name)
    [(No) 0]
    [(Some func)
      (match func
        [(Function _ _ _ _ blocks _)
          (lower-test-blocks-count
            (ir.compiler-ir-block-list-view blocks)
            (F64Mov want))])]))

(define (compiler-lower-comptime-fold-ok? [src : String] [want : i64]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-function-i64-mov-count functions "main" want) 0)
        (= (lower-test-count functions "main" (Binop)) 0))]
    [_ false]))

(define (compiler-lower-comptime-float-fold-ok?
  [src : String]
  [want : String]
  [ty : ast.AstType]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (>
          (lower-test-function-f64-mov-count-bits
            functions
            "main"
            (lower.lower-float-literal-bits want ty))
          0)
        (= (lower-test-count functions "main" (Binop)) 0))]
    [_ false]))

(define (compiler-lower-comptime-f64-fold-ok? [src : String] [want : String]) : bool
  (compiler-lower-comptime-float-fold-ok? src want (F64)))

(define (compiler-lower-comptime-f32-fold-ok? [src : String] [want : String]) : bool
  (compiler-lower-comptime-float-fold-ok? src want (F32)))

;; Tail-position scalar matches (`classify`/`flag-score`/`sign`) return directly
;; from every arm; the unit-typed match (`announce`) likewise needs no phi.
(define (compiler-lower-match-tail-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (= (lower-test-function-phi-count functions "classify") 0)
        (= (lower-test-function-phi-count functions "flag-score") 0)
        (= (lower-test-function-phi-count functions "sign") 0)
        (= (lower-test-function-phi-count functions "announce") 0))]
    [_ false]))

;; Tail-position enum matches also return directly from their arms. Payload
;; matches still need the loads that extract values from the enum storage.
(define (compiler-lower-enum-match-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (= (lower-test-function-phi-count functions "score") 0)
        (= (lower-test-function-phi-count functions "zero-call") 0)
        (= (lower-test-function-phi-count functions "or-zero") 0)
        (= (lower-test-function-phi-count functions "touch") 0)
        (> (lower-test-count functions "score" (Load)) 1)
        (> (lower-test-count functions "or-zero" (Load)) 1))]
    [_ false]))

(define (compiler-lower-two-variant-fallthrough-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-two-variant-fallthrough-source)))
    [(Some functions)
      (and
        (= (lower-test-function-binop-op-count functions "score" Eq) 1)
        (= (lower-test-function-call-count functions "score" "tl_oob_abort") 0))]
    [_ false]))

(define (compiler-lower-total-enum-provenance-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-total-enum-provenance-source)))
    [(Some functions)
      (and
        (>= (lower-test-count functions "large" (TotalEnumBranch)) 4)
        (= (lower-test-count functions "small" (TotalEnumBranch)) 0)
        ;; The outer two-arm match remains ordinary while its nested
        ;; six-variant match independently carries the total proof.
        (= (lower-test-count functions "nested" (TotalEnumBranch)) 4)
        (= (lower-test-count functions "nested" (Branch)) 6)
        ;; A catch-all makes the match exhaustive as source syntax, but it
        ;; does not prove that the compared tags cover the enum domain.
        (= (lower-test-count functions "partial" (TotalEnumBranch)) 0))]
    [_ false]))

(define (compiler-lower-enum-string-literal-payload-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-enum-string-literal-payload-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions "tl_string_eq") 0)
        (= (lower-test-functions-call-count functions "string-eq") 0)
        (> (lower-test-count functions "classify" (Branch)) 2)
        (> (lower-test-count functions "classify" (Load)) 2))]
    [_ false]))

(define (compiler-lower-borrowed-enum-match-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-borrowed-enum-match-source)))
    [(Some functions)
      (and
        (> (lower-test-function-phi-count functions "score") 0)
        (> (lower-test-function-call-count functions "score" "take") 0)
        (> (lower-test-count functions "score" (GepOffset 8)) 0)
        (> (lower-test-count functions "slot-score" (Branch)) 0))]
    [_ false]))

(define (compiler-lower-result-try-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-count functions ".::sum" (Branch)) 1)
        (> (lower-test-count functions ".::sum" (Return)) 2)
        (> (lower-test-count functions ".::chain" (Return)) 1)
        (> (lower-test-count functions ".::sum" (Load)) 3))]
    [_ false]))

(define (compiler-lower-option-try-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-option-try-source)))
    [(Some functions)
      (and
        (> (lower-test-count functions "main" (Branch)) 1)
        (> (lower-test-count functions "main" (Return)) 2))]
    [_ false]))

(define (compiler-lower-return-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-return-source)))
    [(Some functions) (> (lower-test-count functions "main" (Return)) 1)]
    [_ false]))

(define (compiler-lower-return-with-arena-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-return-with-arena-source)))
    [(Some functions)
      (and
        (> (lower-test-count functions "main" (Return)) 1)
        (> (lower-test-functions-call-count functions "tl_region_reset") 1))]
    [_ false]))

(define (compiler-lower-resource-with-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-resource-with-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions ".::close-a") 3)
        (= (lower-test-functions-call-count functions ".::close-b") 2)
        (> (lower-test-count functions "main" (Return)) 2)
        (> (lower-test-count functions "main" (Branch)) 2))]
    [_ false]))

(define (compiler-lower-resource-with-nested-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-resource-with-nested-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions ".::close-a") 1)
        (= (lower-test-functions-call-count functions ".::close-b") 1))]
    [_ false]))

(define (compiler-lower-cleanup-struct-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-cleanup-struct-source)))
    [(Some functions)
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
        (> (lower-test-count functions "main" (Return)) 1))]
    [_ false]))

(define (compiler-lower-cleanup-struct-nested-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-cleanup-struct-nested-source)))
    [(Some functions)
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
          "cleanup-file-handle"))]
    [_ false]))

(define (compiler-lower-array-access-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-count functions "get" (Bounds)) 0)
        (> (lower-test-count functions "put" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-array-take-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-array-take-source)))
    [(Some functions)
      (and
        (>= (lower-test-count functions "take-item" (Bounds)) 2)
        (>= (lower-test-count functions "take-item" (Branch)) 2)
        (>= (lower-test-count functions "take-item" (StorePtr)) 3)
        (>= (lower-test-count functions "take-item" (Load)) 3))]
    [_ false]))

(define (compiler-lower-mut-ref-array-field-access-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-mut-ref-array-field-access-source)))
    [(Some functions)
      (and
        (> (lower-test-count functions "array-bag-handle" (Load)) 0)
        (> (lower-test-count functions "len" (Load)) 0)
        (> (lower-test-count functions "get" (Bounds)) 0)
        (> (lower-test-count functions "put" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-fixed-array-access-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-count functions "get" (Bounds)) 0)
        (> (lower-test-count functions "get" (Load)) 0)
        (> (lower-test-count functions "put" (Bounds)) 0)
        (= (lower-test-count functions "get" (GepOffset 1)) 0)
        (= (lower-test-count functions "put" (GepOffset 1)) 0)
        (> (lower-test-count functions "put" (StorePtr)) 0))]
    [_ false]))

(define (compiler-lower-fixed-array-literal-stack-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-array-literal-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (Alloc)) 3)
        (= (lower-test-count functions "main" (AddrOf)) 1))]
    [_ false]))

(define (compiler-lower-fixed-array-aggregate-layout-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-fixed-array-aggregate-literal-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (> (lower-test-count functions "main" (GepOffset 16)) 0)
        (= (lower-test-count functions "main" (CopyBytes)) 0))]
    [_ false]))

(define (compiler-lower-array-push-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-functions-call-count functions "tl_alloc") 0)
        (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
        (> (lower-test-count functions "grow" (Binop)) 0)
        (> (lower-test-count functions "grow" (StorePtr)) 0))]
    [_ false]))

(define (compiler-lower-make-array-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-functions-call-count functions "tl_alloc") 1)
        (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
        (>= (lower-test-function-i64-binop-op-count functions "main" (Le)) 2)
        (=
          (lower-test-function-binop-op-count functions "main" (Le))
          (lower-test-function-i64-binop-op-count functions "main" (Le)))
        (= (lower-test-function-call-count functions "main" "tl_array_zero") 1))]
    [_ false]))

(define (compiler-lower-make-array-init-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_array_fill8") 1)
        (>= (lower-test-count functions "main" (StorePtr)) 2)
        (> (lower-test-functions-call-count functions "tl_alloc") 0))]
    [_ false]))

(define (compiler-lower-dyn-array-literal-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-dyn-array-literal-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 2)
        (= (lower-test-function-call-count functions "main" "tl_array_zero") 0)
        (>= (lower-test-count functions "main" (StorePtr)) 3))]
    [_ false]))

(define (compiler-lower-make-array-register-resident-zero-fill-shape-ok?) : bool
  ;; A one-word register-resident struct with an all-zero default takes the
  ;; tl_array_zero path (the aggregate zero-fill supersedes fill8 for
  ;; all-zero defaults; fill8 remains for non-zero defaults).
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-make-array-register-resident-fill8-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_array_zero") 1)
        (= (lower-test-function-call-count functions "main" "tl_array_fill8") 0))]
    [_ false]))

(define (compiler-lower-string-runtime-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions "tl_substring") 0)
        (= (lower-test-functions-call-count functions "tl_string_concat") 0)
        (= (lower-test-functions-call-count functions "tl_oob_abort") 0)
        (>
          (lower-test-functions-direct-call-count functions "string.substring")
          0)
        (> (lower-test-functions-direct-call-count functions "string.append") 0)
        (> (lower-test-functions-direct-call-count functions "string.concat") 0)
        (=
          (lower-test-functions-direct-call-count functions "io.emit-string")
          2)
        (= (lower-test-functions-direct-call-count functions "io.emit-str") 1))]
    [_ false]))

(define (compiler-lower-string-concat-fusion-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-string-concat-fusion-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions "tl_string_concat") 0)
        (= (lower-test-functions-call-count functions "tl_string_concat3") 0)
        (= (lower-test-functions-call-count functions "tl_string_concat4") 0)
        (= (lower-test-functions-call-count functions "tl_string_concat5") 0)
        (> (lower-test-functions-direct-call-count functions "string.append") 0))]
    [_ false]))

(define (compiler-lower-emit-string-stdlib-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-emit-string-stdlib-source)))
    [(Some functions)
      (and
        (=
          (lower-test-functions-direct-call-count functions "io.emit-string")
          2)
        (= (lower-test-functions-direct-call-count functions "io.emit-str") 1))]
    [_ false]))

(define (compiler-lower-borrowed-str-param-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-borrowed-str-param-source)))
    [(Some functions)
      (and
        (>
          (lower-test-function-direct-call-count
            functions
            "main"
            "borrowed-score")
          0)
        (> (lower-test-count functions "borrowed-score" (GepOffset 1)) 0)
        (= (lower-test-functions-call-count functions "string-length") 0))]
    [_ false]))

(define (compiler-lower-stdlib-hash-string-shape-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-stdlib-hash-string-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "app.tl"
          program
          (compiler-lower-stdlib-hash-string-paths)))
        [(Some functions)
          (let
            [name : String "stdlib/hash.tl::hash-string"]
            (and
              (=
                (lower-test-function-call-count
                  functions
                  (owned_view.compiler-owned-shared-view name)
                  "tl_hash_string")
                0)
              (>
                (lower-test-count
                  functions
                  (owned_view.compiler-owned-shared-view name)
                  (Bounds))
                0)
              (=
                (lower-test-function-direct-call-count functions "main" name)
                1)))]
        [_ false])]
    [(Err _) false]))

(define (compiler-lower-reference-values-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-reference-return-source)))
    [(Some functions)
      (and
        (> (lower-test-function-call-count functions "ref-return" "tl_alloc") 0)
        (= (lower-test-function-call-count functions "ref-id" "tl_alloc") 0)
        (> (lower-test-count functions "main" (StorePtr)) 1)
        (= (lower-test-count functions "ref-return" (Return)) 1)
        (= (lower-test-count functions "ref-id" (Return)) 1))]
    [_ false]))

(define (compiler-lower-reference-place-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-reference-place-source)))
    [(Some functions)
      (and
        (> (lower-test-count functions "borrow-pair" (GepOffset 0)) 0)
        (> (lower-test-count functions "borrow-tuple" (GepOffset 0)) 0)
        (> (lower-test-count functions "borrow-array" (Bounds)) 0)
        (compiler-lower-reference-inline-struct-field-shape-ok?))]
    [_ false]))

(define (compiler-lower-reference-inline-struct-field-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-reference-inline-struct-field-source)))
    [(Some functions)
      (and
        (=
          (lower-test-function-direct-call-count functions "main" "take-inner")
          1)
        (= (lower-test-count functions "main" (Load)) 0))]
    [_ false]))

(define (compiler-lower-reference-nominal-aggregate-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-reference-struct-result-source))
    (compiler-lower-ok? (compiler-lower-reference-struct-multi-result-source))
    (compiler-lower-ok? (compiler-lower-reference-enum-result-source))))

(define (compiler-lower-string-shadow-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-functions-call-count functions "string.string-length") 0)
        (> (lower-test-functions-call-count functions "string.append") 0)
        (> (lower-test-functions-call-count functions "string.string-ref") 0)
        (> (lower-test-functions-call-count functions "string.char-at") 0)
        (= (lower-test-functions-call-count functions "tl_string_concat") 0)
        (= (lower-test-functions-call-count functions "tl_oob_abort") 0))]
    [_ false]))

(define (compiler-lower-function-value-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-function-value-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "apply1" (IndirectTailCall)) 1)
        (= (lower-test-count functions "apply1" (IndirectCall)) 0)
        (= (lower-test-function-call-count functions "apply1" "f") 0)
        (= (lower-test-count functions "shadow-inc" (IndirectTailCall)) 1)
        (= (lower-test-function-call-count functions "shadow-inc" "inc") 0)
        (=
          (lower-test-function-call-arg-function-count
            functions
            "main"
            "apply1"
            "inc")
          1))]
    [_ false]))

(define (compiler-lower-function-value-contextual-init-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-function-value-contextual-init-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "main" (IndirectTailCall)) 1)
        (= (lower-test-count functions "main" (IndirectCall)) 0))]
    [_ false]))

(define (compiler-lower-mutable-global-function-value-mode-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower.lower-compiler-source-with-mode
    (compiler-lower-mutable-global-function-value-source)
    mode)
    [(Ok program _)
      (match program
        [(Program globals functions _)
          (and
            (lower-test-global-function-initializer?
              globals
              "callback"
              "initial")
            (= (lower-test-count functions "invoke" (IndirectCall)) 1)
            (= (lower-test-function-call-count functions "invoke" "callback") 0)
            (=
              (lower-test-function-store-global-count
                functions
                "install!"
                "callback")
              1)
            (= (lower-test-function-call-count functions "main" "invoke") 1))])]
    [(Err _) false]))

(define (compiler-lower-mutable-global-function-value-shape-ok?) : bool
  (and
    (compiler-lower-mutable-global-function-value-mode-shape-ok?
      (lower.CompilerLowerMode.LinuxScalar))
    (compiler-lower-mutable-global-function-value-mode-shape-ok?
      (lower.CompilerLowerMode.WindowsScalar))))

;; The initializer of global `global-name`, classified as "i64", "runtime",
;; "static:<b0>,<b1>,..." (the static array's bytes), "function:<symbol>",
;; "global:<symbol>", "other" or "missing".
(define (lower-test-global-initializer-kind-at
  [globals : ir.CompilerIrGlobalSeq]
  [global-name : String]
  [index : i64]) : String
  (if (>= index globals.len)
    "missing"
    (match (ir.compiler-ir-global-seq-ref globals index)
      [(Global name _ initial)
        (if (string.eq (ir.compiler-ir-symbol-text name) global-name)
          (match initial
            [(I64 _) "i64"]
            [(StaticArray bytes)
              (str_cat.str-cat "static:" (lower-test-byte-list bytes 0))]
            [(RuntimeGlobal _) "runtime"]
            [(Function found)
              (str_cat.str-cat "function:" (ir.compiler-ir-symbol-text found))]
            [(Global found)
              (str_cat.str-cat "global:" (ir.compiler-ir-symbol-text found))]
            [_ "other"])
          (lower-test-global-initializer-kind-at
            globals
            global-name
            (+ index 1)))])))

(define (lower-test-global-initializer-kind
  [globals : (& globals ir.CompilerIrGlobalSeq)]
  [global-name : String]) : String
  (let
    [globals : ir.CompilerIrGlobalSeq
      (owned_view.compiler-owned-reference-shared-view globals)]
    (lower-test-global-initializer-kind-at globals global-name 0)))

(define (compiler-lower-global-reference-initializer-mode-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower.lower-compiler-source-with-mode
    (compiler-lower-global-reference-initializer-source)
    mode)
    [(Ok program _)
      (match program
        [(Program globals _ _)
          (and
            (string.eq
              (lower-test-global-initializer-kind globals "base")
              "i64")
            (string.eq
              (lower-test-global-initializer-kind globals "copy")
              "runtime")
            (string.eq
              (lower-test-global-initializer-kind globals "widened")
              "runtime")
            (string.eq
              (lower-test-global-initializer-kind globals "color")
              "runtime")
            (string.eq
              (lower-test-global-initializer-kind globals "callback")
              "function:inc")
            (string.eq
              (lower-test-global-initializer-kind globals "callback-copy")
              "runtime"))])]
    [(Err _) false]))

(define (lower-test-byte-list [bytes : String] [index : i64]) : String
  (if (>= index (string.string-length (& bytes)))
    ""
    (str_cat.str-cat
      (if (= index 0)
        ""
        ",")
      (string.int->string (cast (string.string-ref (& bytes) index) : i64))
      (lower-test-byte-list bytes (+ index 1)))))

;; Constant scalar arrays lower to their exact element bytes (#8369); an element
;; that is not a constant of the element's kind, or a non-scalar element type,
;; keeps the runtime initializer.
(define (compiler-lower-static-array-global-mode-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower.lower-compiler-source-with-mode
    (compiler-lower-static-array-global-source)
    mode)
    [(Ok program _)
      (match program
        [(Program globals _ _)
          (and
            (string.eq
              (lower-test-global-initializer-kind globals "wide")
              "static:1,0,0,1,255,255")
            (string.eq
              (lower-test-global-initializer-kind globals "halves")
              "static:0,0,192,63,0,0,0,128")
            (string.eq
              (lower-test-global-initializer-kind globals "flags")
              "static:1,0")
            (string.eq
              (lower-test-global-initializer-kind globals "letters")
              "static:65")
            (string.eq
              (lower-test-global-initializer-kind globals "negatives")
              "static:255,128")
            (string.eq
              (lower-test-global-initializer-kind globals "empty")
              "static:")
            (string.eq
              (lower-test-global-initializer-kind globals "computed")
              "runtime")
            (string.eq
              (lower-test-global-initializer-kind globals "converted")
              "runtime")
            (string.eq
              (lower-test-global-initializer-kind globals "nested")
              "runtime"))])]
    [(Err _) false]))

(define (compiler-lower-static-array-global-shape-ok?) : bool
  (and
    (compiler-lower-static-array-global-mode-shape-ok?
      (lower.CompilerLowerMode.LinuxScalar))
    (compiler-lower-static-array-global-mode-shape-ok?
      (lower.CompilerLowerMode.WindowsScalar))))

(define (compiler-lower-global-reference-initializer-shape-ok?) : bool
  (and
    (compiler-lower-global-reference-initializer-mode-shape-ok?
      (lower.CompilerLowerMode.LinuxScalar))
    (compiler-lower-global-reference-initializer-mode-shape-ok?
      (lower.CompilerLowerMode.WindowsScalar))))

(define (compiler-lower-noncapturing-lambda-value-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-noncapturing-lambda-value-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_get-fn_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (=
            (lower-test-function-return-function-count
              functions
              "get-fn"
              lambda-name)
            1)
          (> (lower-test-count functions lambda-name (Binop)) 0)))]
    [_ false]))

(define (compiler-lower-immediate-lambda-call-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-immediate-lambda-call-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectTailCall)) 1)
          (=
            (lower-test-function-indirect-callee-function-count
              functions
              "main"
              lambda-name)
            1)
          (= (lower-test-function-call-count functions "main" lambda-name) 0)))]
    [_ false]))

(define (compiler-lower-unit-lambda-call-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-unit-lambda-call-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectUnit)) 1)
          (=
            (lower-test-function-indirect-callee-function-count
              functions
              "main"
              lambda-name)
            1)))]
    [_ false]))

(define (compiler-lower-noncapturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-noncapturing-lambda-value-ok?)
    (compiler-lower-immediate-lambda-call-ok?)
    (compiler-lower-unit-lambda-call-ok?)))

(define (compiler-lower-capturing-lambda-scalar-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-scalar-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectTailCall)) 1)
          (>= (lower-test-count functions "main" (StorePtr)) 3)
          (>= (lower-test-functions-call-count functions "tl_alloc") 2)
          (>= (lower-test-count functions lambda-name (Load)) 1)))]
    [_ false]))

(define (compiler-lower-capturing-lambda-function-value-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-function-value-source)))
    [(Some functions)
      (let
        [capturing-name : String "__tl_lambda_main_1"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 3)
          (= (lower-test-count functions "main" (IndirectTailCall)) 1)
          (>=
            (lower-test-count
              functions
              (owned_view.compiler-owned-shared-view capturing-name)
              (IndirectTailCall))
            1)
          (>= (lower-test-count functions capturing-name (Load)) 2)))]
    [_ false]))

(define (compiler-lower-capturing-lambda-fat-handle-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-fat-handle-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectTailCall)) 1)
          (>= (lower-test-functions-call-count functions "tl_alloc") 3)
          (>= (lower-test-count functions lambda-name (Load)) 2)))]
    [_ false]))

(define (compiler-lower-capturing-lambda-aggregate-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-aggregate-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectTailCall)) 1)
          (>= (lower-test-functions-call-count functions "tl_alloc") 5)
          (>= (lower-test-count functions "main" (StorePtr)) 8)
          (>= (lower-test-count functions lambda-name (Load)) 4)))]
    [_ false]))

(define (compiler-lower-capturing-lambda-structural-return-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-structural-return-source)))
    [(Some functions)
      (and
        (= (ir.compiler-ir-function-seq-count functions) 2)
        (= (lower-test-count functions "main" (IndirectCall)) 1)
        (>= (lower-test-count functions "__tl_lambda_main_0" (Pack)) 1))]
    [_ false]))

(define (compiler-lower-capturing-lambda-structural-sret-params-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-structural-sret-source)))
    [(Some functions)
      (and
        (= (ir.compiler-ir-function-seq-count functions) 2)
        (string.eq
          (lower-test-function-param-name functions "__tl_lambda_main_0" 0)
          "__tl_env")
        (string.eq
          (lower-test-function-param-name functions "__tl_lambda_main_0" 1)
          (ir.compiler-ir-hidden-sret-param-name)))]
    [_ false]))

(define (compiler-lower-capturing-lambda-shadow-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-shadow-source)))
    [(Some functions)
      (and
        (= (ir.compiler-ir-function-seq-count functions) 2)
        (= (ir.compiler-ir-function-seq-count functions) 2)
        (= (lower-test-count functions "main" (IndirectTailCall)) 1))]
    [_ false]))

(define (compiler-lower-capturing-lambda-reference-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-reference-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectCall)) 1)
          (>= (lower-test-count functions lambda-name (Load)) 1)))]
    [_ false]))

(define (compiler-lower-capturing-lambda-reference-immediate-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-capturing-lambda-reference-immediate-source)))
    [(Some functions)
      (let
        [lambda-name : String "__tl_lambda_main_0"]
        (and
          (= (ir.compiler-ir-function-seq-count functions) 2)
          (= (lower-test-count functions "main" (IndirectCall)) 1)
          (>= (lower-test-count functions lambda-name (Load)) 1)))]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-fs-status-source)))
    [(Some functions)
      (and
        (=
          (lower-test-functions-call-count functions ".L_tl_fs_mkdir_status")
          0)
        (=
          (lower-test-functions-call-count
            functions
            ".L_tl_fs_remove_file_status")
          0)
        (=
          (lower-test-functions-call-count
            functions
            ".L_tl_fs_remove_dir_status")
          0)
        (=
          (lower-test-functions-call-count functions ".L_tl_fs_rename_status")
          0)
        (=
          (lower-test-functions-call-count functions ".L_tl_fs_read_dir_status")
          0)
        (= (lower-test-functions-call-count functions ".L_tl_fs_read_dir") 0)
        (=
          (lower-test-functions-call-count
            functions
            ".L_tl_fs_file_kind_status")
          0)
        (=
          (lower-test-functions-call-count
            functions
            ".L_tl_fs_file_size_status")
          0)
        (= (lower-test-functions-call-count functions ".L_tl_fs_file_size") 0)
        (= (lower-test-functions-call-count functions ".L_tl_fs_process_id") 0)
        (=
          (lower-test-functions-call-count functions "tl_fs_current_dir_status")
          0)
        (= (lower-test-functions-call-count functions "tl_fs_current_dir") 0)
        (= (lower-test-functions-call-count functions "mkdir-status") 1)
        (= (lower-test-functions-call-count functions "remove-file-status") 1)
        (= (lower-test-functions-call-count functions "remove-dir-status") 1)
        (= (lower-test-functions-call-count functions "rename-status") 1)
        (= (lower-test-functions-call-count functions "read-dir-status") 1)
        (= (lower-test-functions-call-count functions "read-dir") 1)
        (= (lower-test-functions-call-count functions "file-kind-status") 1)
        (= (lower-test-functions-call-count functions "file-size-status") 1)
        (= (lower-test-functions-call-count functions "file-size") 1)
        (= (lower-test-functions-call-count functions "process-id") 1)
        (= (lower-test-functions-call-count functions "current-dir-status") 1)
        (= (lower-test-functions-call-count functions "current-dir") 1))]
    [_ false]))

(define (compiler-lower-region-source) : String
  "(define (string.int->string [value : i64]) : String
  \"41\")
(define (main) : i64
  (with-arena r
    (let
      [s : String (string.int->string 41)]
      (__tl_string_length s))))")

(define (compiler-lower-region-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-region-source)))
    [(Some functions)
      (and
        (> (lower-test-functions-call-count functions "tl_region_mark") 0)
        (> (lower-test-functions-call-count functions "tl_region_reset") 0))]
    [_ false]))

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
  [functions : (& functions ir.CompilerIrFunctionSeq)]) : bool
  (and
    (>= (lower-test-functions-call-count functions "tl_arena_current") 3)
    (>= (lower-test-functions-call-count functions "tl_arena_set") 4)
    (> (lower-test-functions-call-count functions "tl_region_mark") 0)
    (> (lower-test-functions-call-count functions "tl_region_reset") 0)))

(define (compiler-lower-with-escape-arena-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (compiler-lower-with-escape-arena-functions-shape-ok? functions)]
    [_ false]))

(define (compiler-lower-with-escape-array-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-with-escape-array-source)))
    [(Some functions)
      (and
        (compiler-lower-with-escape-arena-shape-ok?
          (compiler-lower-with-escape-array-source))
        (> (lower-test-functions-call-count functions "tl_alloc") 1)
        (> (lower-test-functions-branch-count functions) 0))]
    [_ false]))

(define (compiler-lower-with-escape-box-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-with-escape-box-source)))
    [(Some functions)
      (and
        (compiler-lower-with-escape-arena-shape-ok?
          (compiler-lower-with-escape-box-source))
        (> (lower-test-functions-call-count functions "tl_alloc") 0)
        (> (lower-test-functions-call-count functions "tl_substring") 0))]
    [_ false]))

(define (compiler-lower-with-escape-owning-shape-ok?) : bool
  (match (lower-test-functions
    (compiler-lower-clone-source-with-prelude
      (compiler-lower-with-escape-owning-source)))
    [(Some functions)
      (and
        (compiler-lower-with-escape-arena-functions-shape-ok? functions)
        (> (lower-test-functions-call-count functions "tl_alloc") 0))]
    [_ false]))

(define (compiler-lower-with-escape-shape-ok?) : bool
  (and
    (compiler-lower-with-escape-arena-shape-ok?
      (compiler-lower-with-escape-scalar-source))
    (match (lower-test-functions
      (lower.lower-compiler-source (compiler-lower-with-escape-string-source)))
      [(Some functions)
        (and
          (compiler-lower-with-escape-arena-shape-ok?
            (compiler-lower-with-escape-string-source))
          (> (lower-test-functions-call-count functions "tl_substring") 0))]
      [_ false])
    (compiler-lower-with-escape-array-shape-ok?)
    (compiler-lower-with-escape-box-shape-ok?)
    (compiler-lower-with-escape-owning-shape-ok?)))

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

(define (compiler-lower-runtime-substring-scratch-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons "stdlib/runtime.tl" (ast.ast-decl-path-list-new)))

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
  "(unsafe
  (define (atomic-i64-fetch-add-ptr!
    [ptr : (MutPtr i64)]
    [delta : i64]) : i64
    (unsafe (atomic-fetch-add! ptr delta))))
(unsafe
  (define (atomic-i64-load-ptr [ptr : (Ptr i64)]) : i64
    (unsafe (atomic-load ptr))))
(extern (atomic-i64-fetch-add!
  [items : (__tl_dyn-array i64)]
  [index : i64]
  [delta : i64]) : i64 (:symbol \"tl_atomic_i64_fetch_add\"))
(define (main [items : (__tl_dyn-array i64)]) : i64
  (atomic-i64-fetch-add! items 0 1))")

(define (compiler-lower-runtime-atomic-reachable-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/runtime.tl"
    (ast.ast-decl-root-path-cons
      "stdlib/runtime.tl"
      (ast.ast-decl-root-path-cons
        "stdlib/atomic.tl"
        (ast.ast-decl-root-path-cons "app.tl" (ast.ast-decl-path-list-new))))))

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
  [functions : (& functions ir.CompilerIrFunctionSeq)]) : bool
  (and
    (>= (lower-test-functions-call-count functions "tl_arena_current") 3)
    (>= (lower-test-functions-call-count functions "tl_arena_set") 3)
    (>= (lower-test-functions-call-count functions "tl_arena_make") 1)
    (>= (lower-test-functions-call-count functions "tl_arena_destroy") 1)
    (= (lower-test-functions-call-count functions "tl_region_mark") 0)
    (= (lower-test-functions-call-count functions "tl_region_reset") 0)))

(define (compiler-lower-with-scratch-arena-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (compiler-lower-with-scratch-arena-functions-shape-ok? functions)]
    [_ false]))

(define (compiler-lower-with-scratch-owning-shape-ok?) : bool
  (match (lower-test-functions
    (compiler-lower-clone-source-with-prelude
      (compiler-lower-with-scratch-owning-source)))
    [(Some functions)
      (and
        (compiler-lower-with-scratch-arena-functions-shape-ok? functions)
        (> (lower-test-functions-call-count functions "tl_alloc") 0))]
    [_ false]))

(define (compiler-lower-with-scratch-shape-ok?) : bool
  (and
    (compiler-lower-with-scratch-arena-shape-ok?
      (compiler-lower-with-scratch-scalar-source))
    (match (lower-test-functions
      (lower.lower-compiler-source (compiler-lower-with-scratch-string-source)))
      [(Some functions)
        (and
          (compiler-lower-with-scratch-arena-shape-ok?
            (compiler-lower-with-scratch-string-source))
          (> (lower-test-functions-call-count functions "tl_substring") 0))]
      [_ false])
    (compiler-lower-with-scratch-owning-shape-ok?)))

(define (compiler-lower-runtime-substring-scratch-reachable-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-runtime-substring-scratch-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "app.tl"
          program
          (compiler-lower-runtime-substring-scratch-paths)))
        [(Some functions)
          (and
            (lower-test-function-defined?
              functions
              "stdlib/runtime.tl::substring")
            (>
              (lower-test-function-call-count functions "main" "tl_substring")
              0))]
        [_ false])]
    [(Err _) false]))

(define (compiler-lower-runtime-substring-call-reachable-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-runtime-substring-call-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "app.tl"
          program
          (compiler-lower-runtime-substring-scratch-paths)))
        [(Some functions)
          (and
            (lower-test-function-defined?
              functions
              "stdlib/runtime.tl::substring")
            (>
              (lower-test-function-call-count functions "main" "tl_substring")
              0))]
        [_ false])]
    [(Err _) false]))

(define (compiler-lower-runtime-substring-capturing-lambda-reachable-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-runtime-substring-capturing-lambda-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "app.tl"
          program
          (compiler-lower-runtime-substring-scratch-paths)))
        [(Some functions)
          (and
            (lower-test-function-defined?
              functions
              "stdlib/runtime.tl::substring")
            (>
              (lower-test-function-call-count functions "main" "tl_substring")
              0))]
        [_ false])]
    [(Err _) false]))

(define (compiler-lower-runtime-atomic-reachable-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-runtime-atomic-reachable-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "app.tl"
          program
          (compiler-lower-runtime-atomic-reachable-paths)))
        [(Some functions)
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
              0))]
        [_ false])]
    [(Err _) false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-tls-current-arena-source)))
    [(Some functions)
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
          1))]
    [_ false]))

(define (compiler-lower-in-arena-shape-ok?) : bool
  (and
    (match (lower-test-functions
      (lower.lower-compiler-source (compiler-lower-in-arena-source)))
      [(Some functions)
        (and
          (>= (lower-test-functions-call-count functions "tl_arena_current") 1)
          (>= (lower-test-functions-call-count functions "tl_arena_set") 2))]
      [_ false])
    (match (lower-test-functions
      (lower.lower-compiler-source (compiler-lower-in-arena-return-source)))
      [(Some functions)
        (and
          (>= (lower-test-functions-call-count functions "tl_arena_current") 1)
          (>= (lower-test-functions-call-count functions "tl_arena_set") 3)
          (> (lower-test-functions-return-count functions) 1))]
      [_ false])))

(define (compiler-lower-repr-c-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-repr-c-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (> (lower-test-count functions "main" (GepOffset 4)) 0)
        (> (lower-test-count functions "main" (GepOffset 12)) 0))]
    [_ false]))

;; `foreach` scalar lowering: a foreach `main` lowers to a loop, so its
;; body holds at least the guard branch (`i < end`) and two binops (the `<`
;; guard and the `+ 1` increment).
(define (compiler-lower-foreach-shape-ok? [src : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-count functions "main" (Branch)) 0)
        (> (lower-test-count functions "main" (Binop)) 1))]
    [_ false]))

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

(define (compiler-lower-spmd-numeric-i64-division-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (/ (array-ref a i) 2))))")

(define (compiler-lower-spmd-numeric-f32-division-source) : String
  "(define (fill [a : (__tl_dyn-array f32)] [out : (__tl_dyn-array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (/ (array-ref a i) (cast 2 : f32)))))")

(define (compiler-lower-spmd-numeric-conversion-source) : String
  "(define (fill [a : (__tl_dyn-array i32)] [out : (__tl_dyn-array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (cast (array-ref a i) : f32))))")

(define (compiler-lower-spmd-numeric-masked-division-source) : String
  "(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref a i) 0)
      (set! (array-ref out i) (/ (array-ref a i) 2))
      unit)))")

(define (compiler-lower-spmd-numeric-inline-helper-source) : String
  "(define (half [x : i64]) : i64 (/ x 2))
(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (half (array-ref a i)))))")

(define (compiler-lower-spmd-numeric-private-helper-source) : String
  "(define (heavy-half [x : i64]) : i64
  (/ (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7) 2))
(define (fill [a : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (heavy-half (array-ref a i)))))")

(define (compiler-lower-spmd-numeric-fused-reduction-source) : String
  "(define (f [a : (__tl_dyn-array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (/ (array-ref a i) 2)))")

(define (compiler-lower-spmd-numeric-error-at-source?
  [src : String]
  [mode : lower.CompilerLowerMode]
  [want : String]) : bool
  (match (lower.lower-compiler-source-with-mode src mode)
    [(Err diag-box)
      (let
        [diag : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-box-shared-view diag-box)]
        (unless
          (string.eq (cdiag.compiler-diagnostic-message diag) want)
          (io.panic
            (str_cat.str-cat
              "SPMD numeric diagnostic mismatch: got `"
              (cdiag.compiler-diagnostic-message diag)
              "`, expected `"
              want
              "`")))
        (unless
          (> (cdiag.compiler-diagnostic-line diag) 0)
          (io.panic "SPMD numeric diagnostic has no source line"))
        (unless
          (> (cdiag.compiler-diagnostic-col diag) 0)
          (io.panic "SPMD numeric diagnostic has no source column"))
        true)]
    [(Ok _ _) (io.panic "SPMD numeric source unexpectedly lowered")]))

(test
  compiler-lower-spmd-numeric-diagnostics
  (test.assert-true
    (and
      (compiler-lower-ok? (compiler-lower-spmd-numeric-i64-division-source))
      (compiler-lower-ok? (compiler-lower-spmd-numeric-f32-division-source))
      (compiler-lower-ok? (compiler-lower-spmd-numeric-conversion-source))
      (compiler-lower-ok? (compiler-lower-spmd-numeric-masked-division-source))
      (compiler-lower-ok? (compiler-lower-spmd-numeric-inline-helper-source))
      (compiler-lower-ok? (compiler-lower-spmd-numeric-private-helper-source))
      (compiler-lower-ok? (compiler-lower-spmd-numeric-fused-reduction-source))
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-i64-division-source)
        (lower.CompilerLowerMode.Avx2)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in direct map context for AVX2 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-i64-division-source)
        (lower.CompilerLowerMode.Avx512)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in direct map context for AVX-512 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-f32-division-source)
        (lower.CompilerLowerMode.Avx2)
        "lower: SPMD numeric operation '/' from f32 to f32 is unsupported in direct map context for AVX2 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-conversion-source)
        (lower.CompilerLowerMode.Avx2)
        "lower: SPMD numeric conversion from i32 to f32 is unsupported in direct map context for AVX2 backend; SIMD cross-lane conversion has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-masked-division-source)
        (lower.CompilerLowerMode.Avx2)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in masked control context for AVX2 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-masked-division-source)
        (lower.CompilerLowerMode.Avx512)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in masked control context for AVX-512 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-inline-helper-source)
        (lower.CompilerLowerMode.Avx2)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in inline helper context for AVX2 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-private-helper-source)
        (lower.CompilerLowerMode.Avx512)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in private helper context for AVX-512 backend; SIMD division has no implemented strategy; use scalar backend")
      (compiler-lower-spmd-numeric-error-at-source?
        (compiler-lower-spmd-numeric-fused-reduction-source)
        (lower.CompilerLowerMode.Avx2)
        "lower: SPMD numeric operation '/' from i64 to i64 is unsupported in map-fused reduction context for AVX2 backend; SIMD division has no implemented strategy; use scalar backend"))
    "SPMD numeric failures report their matrix row at the operator or cast"))

;; A masked store of `value` from a `source` array into a `destination` array,
;; guarded by a casted-literal comparison. The stored value starts on line 6,
;; column 9.
(define (compiler-lower-masked-cast-source
  [source : String]
  [destination : String]
  [value : String]) : String
  (str_cat.str-cat
    "(define (fill [src : (__tl_dyn-array "
    (clone source)
    ")] [out : (__tl_dyn-array "
    destination
    ")] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref src i) (cast 0 : "
    source
    "))
      (set! (array-ref out i)
        "
    value
    ")
      unit)))"))

(define (compiler-lower-masked-cast-value-source
  [source : String]
  [destination : String]) : String
  (compiler-lower-masked-cast-source
    source
    (clone destination)
    (str_cat.str-cat "(cast (array-ref src i) : " destination ")")))

;; The masked-control conversion row for `source -> destination` must reject
;; in `mode`, at the cast.
(define (compiler-lower-masked-cast-rejected?
  [source : String]
  [destination : String]
  [mode : lower.CompilerLowerMode]
  [backend : String]) : bool
  (let
    [want : String
      (str_cat.str-cat
        "lower: SPMD numeric conversion from "
        (clone source)
        " to "
        (clone destination)
        " is unsupported in masked control context for "
        backend
        " backend; SIMD cross-lane conversion has no implemented strategy; use scalar backend")]
    (match (lower.lower-compiler-source-with-mode
      (compiler-lower-masked-cast-value-source
        (clone source)
        (clone destination))
      mode)
      [(Err diag-box)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-box-shared-view diag-box)]
          (if (and
            (string.eq (cdiag.compiler-diagnostic-message diag) want)
            (= (cdiag.compiler-diagnostic-line diag) 6)
            (= (cdiag.compiler-diagnostic-col diag) 9))
            true
            (io.panic
              (str_cat.str-cat
                "masked cast diagnostic mismatch: got `"
                (cdiag.compiler-diagnostic-message diag)
                "` at "
                (string.int->string (cdiag.compiler-diagnostic-line diag))
                ":"
                (string.int->string (cdiag.compiler-diagnostic-col diag))
                ", expected `"
                want
                "` at 6:9"))))]
      [(Ok _ _)
        (io.panic
          (str_cat.str-cat
            "masked cast from "
            source
            " to "
            destination
            " unexpectedly lowered"))])))

;; `src` lowers in `mode` through the masked emitter: its store is predicated.
(define (compiler-lower-masked-cast-vectorized?
  [src : String]
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower-test-functions (lower.lower-compiler-source-with-mode src mode))
    [(Some functions)
      (> (lower-test-count functions "fill" (PredicatedStore)) 0)]
    [(No) false]))

(define (compiler-lower-masked-cast-rows-ok?
  [mode : lower.CompilerLowerMode]
  [backend : String]) : bool
  (and
    ;; Both directions of every representation-changing 32-bit row, and a
    ;; same-width signedness change, which has no checked classification.
    (compiler-lower-masked-cast-rejected? "i32" "f32" mode (clone backend))
    (compiler-lower-masked-cast-rejected? "f32" "i32" mode (clone backend))
    (compiler-lower-masked-cast-rejected? "u32" "f32" mode (clone backend))
    (compiler-lower-masked-cast-rejected? "f32" "u32" mode (clone backend))
    (compiler-lower-masked-cast-rejected? "i32" "u32" mode backend)
    ;; An identity cast and a casted literal still lower as masked vectors.
    (compiler-lower-masked-cast-vectorized?
      (compiler-lower-masked-cast-value-source "i32" "i32")
      mode)
    (compiler-lower-masked-cast-vectorized?
      (compiler-lower-masked-cast-source "f32" "f32" "(cast 1 : f32)")
      mode)))

(test
  compiler-lower-spmd-masked-cast-fail-closed
  (test.assert-true
    (and
      (compiler-lower-ok? (compiler-lower-masked-cast-value-source "i32" "f32"))
      (compiler-lower-ok? (compiler-lower-masked-cast-value-source "f32" "u32"))
      (compiler-lower-masked-cast-rows-ok?
        (lower.CompilerLowerMode.Avx2)
        "AVX2")
      (compiler-lower-masked-cast-rows-ok?
        (lower.CompilerLowerMode.Avx512)
        "AVX-512")
      ;; With the census forced to admit every cast, the masked emitter itself
      ;; must reject the same rows at the cast.
      (begin
        (lower.lower-masked-census-admit-every-cast! true)
        (let
          [ok : bool
            (and
              (compiler-lower-masked-cast-rows-ok?
                (lower.CompilerLowerMode.Avx2)
                "AVX2")
              (compiler-lower-masked-cast-rows-ok?
                (lower.CompilerLowerMode.Avx512)
                "AVX-512"))]
          (lower.lower-masked-census-admit-every-cast! false)
          ok)))
    "masked SPMD casts that change lane representation reject at the cast, in the census and in the emitter"))

(define (compiler-lower-avx2-foreach-map-source-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx2)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count
            functions
            "fill"
            lanes
            elem-ty)]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 2)
          (= binop-count 2)
          (= store-count 1)
          (= pred-load-count 2)
          (= pred-store-count 1)
          (= tail-mask-count 1)
          (= shape-count 8)
          (> tail-store-count 0)))]
    [_ false]))

(define (compiler-lower-avx2-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (I64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-foreach-borrowed-array-map-source)
      (I64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i32-source)
      (I32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u64-source)
      (U64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u32-source)
      (U32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i16-source)
      (I16)
      16)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u16-source)
      (U16)
      16)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f64-source)
      (F64)
      4)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f32-source)
      (F32)
      8)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i8-source)
      (I8)
      32)
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u8-source)
      (U8)
      32)))

(define (compiler-lower-avx2-foreach-uniform-source-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]
  [want-loads : i64]
  [want-binops : i64]
  [want-shapes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx2)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count
            functions
            "fill"
            lanes
            elem-ty)]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count want-loads)
          (= binop-count (* want-binops 2))
          (= store-count 1)
          (= pred-load-count want-loads)
          (= pred-store-count 1)
          (= tail-mask-count 1)
          (= shape-count (* want-shapes 2))
          (> tail-store-count 0)))]
    [_ false]))

(define (compiler-lower-avx2-foreach-uniform-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-source)
      (I64)
      4
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i32-source)
      (I32)
      8
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u64-source)
      (U64)
      4
      2
      3
      8)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u32-source)
      (U32)
      8
      2
      3
      8)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i16-source)
      (I16)
      16
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u16-source)
      (U16)
      16
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f64-source)
      (F64)
      4
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f32-source)
      (F32)
      8
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i8-source)
      (I8)
      32
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u8-source)
      (U8)
      32
      2
      2
      6)
    (compiler-lower-avx2-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-zip-uniform-source)
      (I64)
      4
      3
      3
      8)))

(define (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx2)))
    [(Some functions)
      (and
        (= (lower-test-count functions "fill" (VectorLoad)) 0)
        (= (lower-test-count functions "fill" (VectorStore)) 1)
        (=
          (lower-test-function-vector-shape-count
            functions
            "fill"
            lanes
            elem-ty)
          2)
        (> (lower-test-count functions "fill" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-broadcast-avx2-shape-ok?) : bool
  (and
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-source)
      (I64)
      4)
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-u64-source)
      (U64)
      4)
    (compiler-lower-spmd-broadcast-avx2-source-shape-ok?
      (compiler-lower-spmd-broadcast-u32-source)
      (U32)
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
  [elem-ty : ast.AstType]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count
            functions
            "fill"
            lanes
            elem-ty)]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 2)
          (= binop-count 2)
          (= store-count 1)
          (= pred-load-count 2)
          (= pred-store-count 1)
          (= tail-mask-count 1)
          (= shape-count 8)
          (> tail-store-count 0)))]
    [_ false]))

(define (compiler-lower-avx512-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (I64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-foreach-borrowed-array-map-source)
      (I64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i32-source)
      (I32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u64-source)
      (U64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u32-source)
      (U32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i16-source)
      (I16)
      32)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u16-source)
      (U16)
      32)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f64-source)
      (F64)
      8)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-f32-source)
      (F32)
      16)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-i8-source)
      (I8)
      64)
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-u8-source)
      (U8)
      64)))

(define (compiler-lower-avx512-foreach-uniform-source-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]
  [want-loads : i64]
  [want-pred-loads : i64]
  [want-binops : i64]
  [want-shapes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count
            functions
            "fill"
            lanes
            elem-ty)]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count want-loads)
          (= binop-count want-binops)
          (= store-count 1)
          (= pred-load-count want-pred-loads)
          (= pred-store-count 1)
          (= tail-mask-count 1)
          (= shape-count want-shapes)
          (> tail-store-count 0)))]
    [_ false]))

(define (compiler-lower-avx512-foreach-uniform-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-source)
      (I64)
      8
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i32-source)
      (I32)
      16
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u64-source)
      (U64)
      8
      2
      2
      6
      16)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u32-source)
      (U32)
      16
      2
      2
      6
      16)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i16-source)
      (I16)
      32
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u16-source)
      (U16)
      32
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f64-source)
      (F64)
      8
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-f32-source)
      (F32)
      16
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-i8-source)
      (I8)
      64
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-map-uniform-u8-source)
      (U8)
      64
      2
      2
      4
      12)
    (compiler-lower-avx512-foreach-uniform-source-shape-ok?
      (compiler-lower-avx2-foreach-zip-uniform-source)
      (I64)
      8
      3
      3
      6
      16)))

(define (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (and
        (= (lower-test-count functions "fill" (VectorLoad)) 0)
        (= (lower-test-count functions "fill" (VectorStore)) 1)
        (= (lower-test-count functions "fill" (PredicatedStore)) 1)
        (= (lower-test-count functions "fill" (TailMask)) 1)
        (=
          (lower-test-function-vector-shape-count
            functions
            "fill"
            lanes
            elem-ty)
          4)
        (> (lower-test-count functions "fill" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-broadcast-avx512-shape-ok?) : bool
  (and
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-source)
      (I64)
      8)
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-u64-source)
      (U64)
      8)
    (compiler-lower-spmd-broadcast-avx512-source-shape-ok?
      (compiler-lower-spmd-broadcast-u32-source)
      (U32)
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
  [mode : lower.CompilerLowerMode]
  [vector-loads : i64]
  [predicated-loads : i64]) : bool
  (match (lower-test-functions (lower.lower-compiler-source-with-mode src mode))
    [(Some functions)
      (let
        [actual-vector-loads : i64
          (lower-test-count functions "fill" (VectorLoad))]
        [actual-predicated-loads : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        (and
          (= actual-vector-loads vector-loads)
          (= actual-predicated-loads predicated-loads)))]
    [_ false]))

(define (compiler-lower-masked-preheader-cache-counts-ok?
  [mode : lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-masked-load-cache-let-source)
      mode))
    [(Some functions)
      (and
        ;; The condition's repeated literal and both arms' shared bias are
        ;; each materialized once for the full body and vector tail.
        (=
          (lower-test-function-splat-shape-count functions "fill" lanes (I64))
          2)
        ;; Dynamic-array slot-0 loads live in entry, never in either vector
        ;; body. The scalar tail deliberately retains its checked reloads.
        (= (lower-test-function-label-load-count functions "fill" "entry") 4)
        (=
          (lower-test-function-label-load-count
            functions
            "fill"
            "foreach_avx512_mask_body.1")
          0)
        (=
          (lower-test-function-label-load-count
            functions
            "fill"
            "foreach_tail_mask.4")
          0))]
    [_ false]))

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
    (match (lower-test-functions
      (lower.lower-compiler-source-with-mode
        (compiler-lower-masked-preheader-windows-avx2-cap-source)
        (lower.CompilerLowerMode.Avx2)))
      [(Some functions)
        (= (lower-test-function-splat-shape-count functions "fill" 8 (I32)) 5)]
      [_ false])
    (match (lower-test-functions
      (lower.lower-compiler-source-with-mode
        (compiler-lower-masked-preheader-windows-avx2-cap-source)
        (lower.CompilerLowerMode.LinuxAvx2)))
      [(Some functions)
        (= (lower-test-function-splat-shape-count functions "fill" 8 (I32)) 5)]
      [_ false])
    (match (lower-test-functions
      (lower.lower-compiler-source-with-mode
        (compiler-lower-masked-preheader-windows-avx2-cap-source)
        (lower.CompilerLowerMode.WindowsAvx2)))
      [(Some functions)
        (= (lower-test-function-splat-shape-count functions "fill" 8 (I32)) 5)]
      [_ false])))

(define (compiler-lower-masked-preheader-unsafe-rejected?
  [mode : lower.CompilerLowerMode]) : bool
  (and
    (compiler-lower-mode-error-ok?
      (compiler-lower-masked-preheader-reassign-source)
      mode
      "typecheck: foreach cannot set binding declared outside foreach")
    (compiler-lower-mode-error-ok?
      (compiler-lower-masked-preheader-grow-source)
      mode
      "typecheck: SPMD masked if does not support side effects other than contiguous array writes inside masked branches")))

(define (compiler-lower-masked-load-cache-tests-ok?) : bool
  (and
    ;; Repeated spelling and an explicit lane-local binding each issue one
    ;; load in the full body and one parent-mask load in the tail body.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-if-bitand-value-source)
      (lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-let-source)
      (lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-if-bitand-value-source)
      (lower.CompilerLowerMode.Avx512)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-let-source)
      (lower.CompilerLowerMode.Avx512)
      1
      1)
    ;; A load first evaluated under one arm cannot feed its sibling: each of
    ;; the full and tail bodies needs one load for each arm.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-sibling-source)
      (lower.CompilerLowerMode.Avx2)
      0
      4)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-sibling-source)
      (lower.CompilerLowerMode.Avx512)
      0
      4)
    ;; A store retires the parent value. The post-store read and the sibling
    ;; read must both reload in each body.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-mutation-source)
      (lower.CompilerLowerMode.Avx2)
      1
      5)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-mutation-source)
      (lower.CompilerLowerMode.Avx512)
      1
      5)
    ;; Dominance is transitive through nested if and scalar-lane match masks.
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-nested-if-source)
      (lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-nested-if-source)
      (lower.CompilerLowerMode.Avx512)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-match-source)
      (lower.CompilerLowerMode.Avx2)
      1
      1)
    (compiler-lower-masked-load-cache-counts-ok?
      (compiler-lower-masked-load-cache-match-source)
      (lower.CompilerLowerMode.Avx512)
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
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 1)
          (= store-count 0)
          (>= binop-count 2)
          (>= pred-load-count 3)
          (>= pred-store-count 4)
          (= tail-mask-count 1)
          (> tail-store-count 0)
          true))]
    [_ false]))

(define (compiler-lower-avx512-masked-if-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-source)))

(define (compiler-lower-avx512-masked-if-offset-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-offset-source)))

(define (compiler-lower-avx512-masked-if-index-value-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-avx512-masked-if-index-value-source)
      (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count functions "fill" 8 (I64))]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 0)
          (= store-count 0)
          (>= binop-count 3)
          (= pred-load-count 0)
          (>= pred-store-count 4)
          (= tail-mask-count 1)
          (>= shape-count 5)
          (> tail-store-count 0)))]
    [_ false]))

(define (compiler-lower-avx512-masked-if-index-mod-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-avx512-masked-if-index-mod-source)
      (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count functions "fill" 8 (I64))]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 0)
          (= store-count 0)
          (>= binop-count 6)
          (= pred-load-count 0)
          (>= pred-store-count 4)
          (= tail-mask-count 1)
          (>= shape-count 9)
          (> tail-store-count 0)))]
    [_ false]))

(define (compiler-lower-avx512-masked-if-value-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-avx512-masked-if-value-source)
      (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [select-count : i64 (lower-test-count functions "fill" (Select))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count functions "fill" 8 (I64))]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 1)
          (= store-count 1)
          (>= binop-count 2)
          (= pred-load-count 1)
          (= pred-store-count 1)
          (= select-count 2)
          (= tail-mask-count 1)
          (and (>= shape-count 7) (> tail-store-count 0))))]
    [_ false]))

(define (compiler-lower-masked-if-bitand-value-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-masked-if-bitand-value-source)
      mode))
    [(Some functions)
      (let
        [lanes : i64 (lower.lower-simd-lanes-for-elem mode (I64))]
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [select-count : i64 (lower-test-count functions "fill" (Select))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count functions "fill" lanes (I64))]
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
          (>= shape-count 14)))]
    [_ false]))

(define (compiler-lower-masked-if-bitwise-value-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-masked-if-bitwise-value-source)
      mode))
    [(Some functions)
      (let
        [lanes : i64 (lower.lower-simd-lanes-for-elem mode (I64))]
        [binop-count : i64 (lower-test-count functions "fill" (VectorBinop))]
        [bit-or-count : i64
          (lower-test-function-vector-binop-op-count functions "fill" (BitOr))]
        [bit-xor-count : i64
          (lower-test-function-vector-binop-op-count functions "fill" (BitXor))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [select-count : i64 (lower-test-count functions "fill" (Select))]
        [shape-count : i64
          (lower-test-function-vector-shape-count functions "fill" lanes (I64))]
        (and
          (>= binop-count 8)
          (>= bit-or-count 4)
          (>= bit-xor-count 4)
          (>= pred-load-count 1)
          (= pred-store-count 1)
          (>= select-count 4)
          (>= shape-count 16)))]
    [_ false]))

(define (compiler-lower-masked-if-shift-value-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower.lower-compiler-source-with-mode
    (compiler-lower-masked-if-shift-value-source)
    mode)
    [(Ok program _)
      (match program
        [(Program _ functions _)
          (let
            [lanes : i64 (lower.lower-simd-lanes-for-elem mode (I64))]
            [shl-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (Shl (I64)))]
            [shr-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (Shr (I64)))]
            [abort-count : i64
              (lower-test-functions-call-count functions "tl_shift_abort")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                (I64))]
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
            true)])]
    [(Err diag)
      (io.panic (cdiag.compiler-diagnostic-message (__tl-box-place diag)))]))

(define (compiler-lower-masked-if-narrow-shift-shape-ok?
  [mode : lower.CompilerLowerMode]) : bool
  (match (lower.lower-compiler-source-with-mode
    (compiler-lower-masked-if-narrow-shift-source)
    mode)
    [(Ok program _)
      (match program
        [(Program _ functions _)
          (let
            [lanes : i64 (lower.lower-simd-lanes-for-elem mode (I16))]
            [shl-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (Shl (I16)))]
            [shr-count : i64
              (lower-test-function-vector-binop-op-count
                functions
                "fill"
                (Shr (I16)))]
            [abort-count : i64
              (lower-test-functions-call-count functions "tl_shift_abort")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                (I16))]
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
            true)])]
    [(Err diag)
      (io.panic (cdiag.compiler-diagnostic-message (__tl-box-place diag)))]))

(define (compiler-lower-masked-shift-tests-ok?) : bool
  (unless
    (compiler-lower-masked-if-shift-value-shape-ok?
      (lower.CompilerLowerMode.Avx2))
    (io.panic "lower: AVX2 masked shift shape mismatch"))
  (unless
    (compiler-lower-masked-if-shift-value-shape-ok?
      (lower.CompilerLowerMode.Avx512))
    (io.panic "lower: AVX-512 masked shift shape mismatch"))
  (unless
    (compiler-lower-masked-if-narrow-shift-shape-ok?
      (lower.CompilerLowerMode.Avx2))
    (io.panic "lower: AVX2 narrow masked shift shape mismatch"))
  (unless
    (compiler-lower-masked-if-narrow-shift-shape-ok?
      (lower.CompilerLowerMode.Avx512))
    (io.panic "lower: AVX-512 narrow masked shift shape mismatch"))
  true)

(define (compiler-lower-avx512-masked-if-nested-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-avx512-masked-if-nested-source)
      (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        [shape-count : i64
          (lower-test-function-vector-shape-count functions "fill" 8 (I64))]
        [tail-store-count : i64 (lower-test-count functions "fill" (StorePtr))]
        (compiler-lower-and8
          (= load-count 1)
          (= store-count 0)
          (> pred-load-count 0)
          (> pred-store-count 0)
          (= tail-mask-count 1)
          (> shape-count 0)
          (> tail-store-count 0)
          true))]
    [_ false]))

(define (compiler-lower-avx2-masked-if-source-shape-ok? [src : String]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx2)))
    [(Some functions)
      (let
        [load-count : i64 (lower-test-count functions "fill" (VectorLoad))]
        [store-count : i64 (lower-test-count functions "fill" (VectorStore))]
        [pred-load-count : i64
          (lower-test-count functions "fill" (PredicatedLoad))]
        [pred-store-count : i64
          (lower-test-count functions "fill" (PredicatedStore))]
        [select-count : i64 (lower-test-count functions "fill" (Select))]
        [tail-mask-count : i64 (lower-test-count functions "fill" (TailMask))]
        (and
          (>
            (+
              (+ (+ load-count store-count) pred-load-count)
              (+ pred-store-count select-count))
            0)
          (= tail-mask-count 1)))]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-avx2-foreach-map-source)))
    [(Some functions) (= (lower-test-count functions "fill" (VectorLoad)) 0)]
    [_ false]))

(define (compiler-lower-spmd-lane-array-source) : String
  "(define (fill [zeros : (__tl_dyn-array f32)] [out : (__tl_dyn-array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (array-ref zeros (program-index)))))")

(define (compiler-lower-spmd-lane-array-shape-ok?
  [mode : lower.CompilerLowerMode]
  [predicated? : bool]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-spmd-lane-array-source)
      mode))
    [(Some functions)
      (and
        (> (lower-test-count functions "fill" (VectorLoad)) 0)
        (> (lower-test-count functions "fill" (VectorStore)) 0)
        (> (lower-test-count functions "fill" (Bounds)) 0)
        (if predicated?
          (and
            (> (lower-test-count functions "fill" (PredicatedLoad)) 0)
            (> (lower-test-count functions "fill" (PredicatedStore)) 0))
          true))]
    [_ false]))

(define (compiler-lower-simd-foreach-fallback-diagnostic-ok?) : bool
  (and
    (compiler-lower-mode-error-ok?
      (compiler-lower-avx2-foreach-scalar-fallback-source)
      (lower.CompilerLowerMode.Avx2)
      (lower.lower-simd-foreach-fallback-diagnostic))
    (compiler-lower-mode-error-ok?
      (compiler-lower-avx2-foreach-scalar-fallback-source)
      (lower.CompilerLowerMode.Avx512)
      (lower.lower-simd-foreach-fallback-diagnostic))))

(define (compiler-lower-spmd-shuffle-lowering-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-spmd-shuffle-source))
    (compiler-lower-mode-error-ok?
      (compiler-lower-spmd-shuffle-source)
      (lower.CompilerLowerMode.Avx2)
      (lower.lower-spmd-shuffle-diagnostic))
    (compiler-lower-mode-error-ok?
      (compiler-lower-spmd-shuffle-source)
      (lower.CompilerLowerMode.Avx512)
      (lower.lower-spmd-shuffle-diagnostic))))

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
  [mode : lower.CompilerLowerMode]) : i64
  (match (lower.lower-compiler-source-with-mode src mode)
    [(Ok program _)
      (match program
        [(Program _ functions _)
          (lower-test-function-spmd-call-count functions "fill")])]
    [(Err _) (- 0 1)]))

(define (compiler-lower-spmd-source-function-count
  [src : String]
  [mode : lower.CompilerLowerMode]) : i64
  (match (lower.lower-compiler-source-with-mode src mode)
    [(Ok program _)
      (match program
        [(Program _ functions _) (ir.compiler-ir-function-seq-count functions)])]
    [(Err _) (- 0 1)]))

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
  [result : lower.ResultLowerImportedSpmdSpecialization]
  [fragment : (& fragment str)]) : bool
  (match result
    [(Ok _) false]
    [(Err diag)
      (let
        [message : String
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))]
        (string.contains (& message) fragment))]))

;; Selection, generated linker-name canonicalization, source metadata, and
;; diagnostic spans all belong to the caller's compile job. A same-shaped
;; installed decoy must not redirect any of those reads or receive mutations.
(define (compiler-lower-imported-spmd-owner-isolation-ok?) : bool
  (let
    [active-intern-before : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [active-pools-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
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
    [lower-a : lower.CompilerLowerState
      (lower.compiler-lower-state-new-with-intern-state
        (owned_view.compiler-owned-shared-view intern-a))]
    [structural-a : cis.InternStructuralKey
      (cis.intern-structural-session-composite-pair-key
        (lower.compiler-lower-state-structural-session lower-a)
        name-a
        link-a)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [inner-a : i64
      (ast.ast-node-pool-context-expr-push
        pools-a
        (Literal (ast.ast-lit-int 1)))]
    [_inner-b : i64
      (ast.ast-node-pool-context-expr-push
        pools-b
        (Spanned 0 (ast.ast-source-span 99 1 99 2)))]
    [origin-a : ast.AstExpr (Spanned inner-a (ast.ast-source-span 9 4 9 12))]
    [item-a : ast.AstImportedSpmdSpecialization
      (ast.AstImportedSpmdSpecialization
        (ci.intern-id-from-renderable link-a)
        (ci.intern-id-from-renderable link-a)
        1
        (ci.intern-id-from-renderable link-a)
        (ci.intern-id-from-renderable link-a)
        0
        (ci.intern-id-from-renderable link-a))]
    [empty-callables : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [decoy-source-before : i64
      (ci.intern-compat-state-pool-len (& intern-decoy))]
    [decoy-generated-before : i64
      (ci.intern-compat-state-generated-count (& intern-decoy))]
    [decoy-exprs-before : i64 (ast.ast-node-pool-context-expr-len pools-b)]
    [ok : bool false]
    (ci.intern-compat-state-install! intern-decoy)
    (ast.ast-node-pool-context-install! pools-b)
    (let
      [stripped-a : i64
        (lower.lower-imported-spmd-ir-symbol (&mut intern-a) item-a)]
      [diagnostic-line : i64
        (match (lower.lower-imported-spmd-select
          (& intern-a)
          pools-a
          (ci.intern-id-from-renderable name-a)
          (& empty-callables)
          "(-> i64 i64)"
          (Scalar)
          1
          "v"
          0
          (I64)
          origin-a)
          [(Ok _) -1]
          [(Err diag) (cdiag.compiler-diagnostic-line (__tl-box-place diag))])]
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
            (lower.compiler-lower-state-name-text lower-a name-a)
            "owner-a/item.field")
          (string.eq
            (lower.compiler-lower-state-name-text
              lower-a
              (cis.intern-structural-key-raw structural-a))
            "owner-a/item.field/_tl_owner_a")
          (= diagnostic-line 9)
          (=
            (ci.intern-compat-state-pool-len (& intern-decoy))
            decoy-source-before)
          (=
            (ci.intern-compat-state-generated-count (& intern-decoy))
            decoy-generated-before)
          (= (ast.ast-node-pool-context-expr-len pools-b) decoy-exprs-before))))
    (ci.intern-compat-state-install! active-intern-before)
    (ast.ast-node-pool-context-install! active-pools-before)
    (ast.ast-node-pool-context-destroy-storage! pools-a)
    (ast.ast-node-pool-context-destroy-storage! pools-b)
    (unsafe
      (arena.tl_arena_destroy
        (ci.intern-compat-state-persistent-arena (& intern-a)))
      (arena.tl_arena_destroy
        (ci.intern-compat-state-persistent-arena (& intern-b)))
      (arena.tl_arena_destroy
        (ci.intern-compat-state-persistent-arena (& intern-decoy))))
    ok))

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
    [specializations : ast.AstImportedSpmdSpecializationList
      (ast.ast-imported-spmd-specialization-list-new)]
    [callables : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [empty-callables : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [duplicate-callables : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [unsupported-specializations : ast.AstImportedSpmdSpecializationList
      (ast.ast-imported-spmd-specialization-list-new)]
    [unsupported-callables : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    [missing-message-fragment : String "has no TLCI callable metadata"]
    [signature-message-fragment : String "ordinary signature mismatch"]
    [specialization-message-fragment : String "has no requested specialization"]
    [abi-message-fragment : String
      "uses unsupported private ABI `spmd-call-v2`"]
    [duplicate-message-fragment : String "has duplicate TLCI specializations"]
    [avx2-message-fragment : String "is not supported in AVX2 backend mode"]
    [origin : ast.AstExpr (Literal (ast.ast-lit-int 0))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    (ast.ast-imported-spmd-specialization-list-push
      (&mut specializations)
      (ast.AstImportedSpmdSpecialization
        (lower-test-renderable-name-id-with-state (&mut interns) "spmd-call-v1")
        (lower-test-renderable-name-id-with-state (&mut interns) "scalar")
        1
        (lower-test-renderable-name-id-with-state (&mut interns) "v")
        (lower-test-renderable-name-id-with-state (&mut interns) "v")
        0
        (lower-test-renderable-name-id-with-state
          (&mut interns)
          "_tl___fixture_helper_scalar")))
    (ast.ast-imported-spmd-callable-list-push
      (&mut callables)
      (ast.AstImportedSpmdCallable
        (lower-test-renderable-name-id-with-state
          (&mut interns)
          (owned_view.compiler-owned-shared-view signature))
        (owned_view.compiler-owned-shared-view specializations)))
    (ast.ast-imported-spmd-callable-list-push
      (&mut duplicate-callables)
      (ast.AstImportedSpmdCallable
        (lower-test-renderable-name-id-with-state
          (&mut interns)
          (owned_view.compiler-owned-shared-view signature))
        (owned_view.compiler-owned-shared-view specializations)))
    (ast.ast-imported-spmd-callable-list-push
      (&mut duplicate-callables)
      (ast.AstImportedSpmdCallable
        (lower-test-renderable-name-id-with-state
          (&mut interns)
          (owned_view.compiler-owned-shared-view signature))
        specializations))
    (ast.ast-imported-spmd-specialization-list-push
      (&mut unsupported-specializations)
      (ast.AstImportedSpmdSpecialization
        (lower-test-renderable-name-id-with-state (&mut interns) "spmd-call-v2")
        (lower-test-renderable-name-id-with-state (&mut interns) "scalar")
        1
        (lower-test-renderable-name-id-with-state (&mut interns) "v")
        (lower-test-renderable-name-id-with-state (&mut interns) "v")
        0
        (lower-test-renderable-name-id-with-state
          (&mut interns)
          "__fixture_helper_v2")))
    (ast.ast-imported-spmd-callable-list-push
      (&mut unsupported-callables)
      (ast.AstImportedSpmdCallable
        (lower-test-renderable-name-id-with-state
          (&mut interns)
          (owned_view.compiler-owned-shared-view signature))
        unsupported-specializations))
    (and
      (match (lower.lower-imported-spmd-select
        (& interns)
        pools
        canonical-name
        (& callables)
        (owned_view.compiler-owned-shared-view signature)
        (Scalar)
        1
        "v"
        0
        (I64)
        origin)
        [(Ok selected)
          (and
            (string.eq
              (ci.intern-compat-state-id-str interns selected.symbol)
              "_tl___fixture_helper_scalar")
            (string.eq
              (ci.intern-compat-state-str
                interns
                (lower.lower-imported-spmd-ir-symbol (&mut interns) selected))
              "__fixture_helper_scalar"))]
        [(Err _) false])
      (match (lower.lower-imported-spmd-select
        (& interns)
        pools
        canonical-name
        (& empty-callables)
        (owned_view.compiler-owned-shared-view signature)
        (Scalar)
        1
        "v"
        0
        (I64)
        origin)
        [(Ok _) false]
        [(Err diag)
          (let
            [message : String
              (cdiag.compiler-diagnostic-message (__tl-box-place diag))]
            (string.contains (& message) (& missing-message-fragment)))])
      (compiler-lower-imported-spmd-selection-error-contains?
        (lower.lower-imported-spmd-select
          (& interns)
          pools
          canonical-name
          (& callables)
          "(-> i64 u64)"
          (Scalar)
          1
          "v"
          0
          (I64)
          origin)
        signature-message-fragment)
      (compiler-lower-imported-spmd-selection-error-contains?
        (lower.lower-imported-spmd-select
          (& interns)
          pools
          canonical-name
          (& callables)
          (owned_view.compiler-owned-shared-view signature)
          (Avx512)
          8
          "v"
          0
          (I64)
          origin)
        specialization-message-fragment)
      (compiler-lower-imported-spmd-selection-error-contains?
        (lower.lower-imported-spmd-select
          (& interns)
          pools
          canonical-name
          (& callables)
          (owned_view.compiler-owned-shared-view signature)
          (Scalar)
          1
          "v"
          -1
          (I64)
          origin)
        specialization-message-fragment)
      (compiler-lower-imported-spmd-selection-error-contains?
        (lower.lower-imported-spmd-select
          (& interns)
          pools
          canonical-name
          (& unsupported-callables)
          (owned_view.compiler-owned-shared-view signature)
          (Scalar)
          1
          "v"
          0
          (I64)
          origin)
        abi-message-fragment)
      (compiler-lower-imported-spmd-selection-error-contains?
        (lower.lower-imported-spmd-select
          (& interns)
          pools
          canonical-name
          (& duplicate-callables)
          (owned_view.compiler-owned-shared-view signature)
          (Scalar)
          1
          "v"
          0
          (I64)
          origin)
        duplicate-message-fragment)
      (compiler-lower-imported-spmd-selection-error-contains?
        (lower.lower-imported-spmd-select
          (& interns)
          pools
          canonical-name
          (& callables)
          signature
          (Avx2)
          4
          "v"
          0
          (I64)
          origin)
        avx2-message-fragment)
      (compiler-lower-imported-spmd-owner-isolation-ok?))))

(define (compiler-lower-spmd-scalar-call-shape-ok?) : bool
  (and
    (compiler-lower-imported-spmd-selection-smoke-ok?)
    (compiler-lower-spmd-scalar-private-abi-descriptors-ok?)
    (match (lower-test-functions
      (lower.lower-compiler-source-with-mode
        (compiler-lower-spmd-scalar-call-shape-source)
        (lower.CompilerLowerMode.Scalar)))
      [(Some functions)
        (and
          (> (lower-test-function-spmd-call-count functions "fill-value") 0)
          (> (lower-test-function-spmd-call-count functions "fill-unit") 0)
          (> (ir.compiler-ir-function-seq-count functions) 4))]
      [_ false])))

(define (compiler-lower-spmd-varying-local-call-shape-ok?) : bool
  (>
    (compiler-lower-spmd-source-call-count
      (compiler-lower-spmd-varying-local-call-source)
      (lower.CompilerLowerMode.Avx512))
    0))

(define (compiler-lower-spmd-uniform-arg-call-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-spmd-uniform-arg-call-source)
      (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (and
        (= (lower-test-function-spmd-call-count functions "fill") 0)
        (= (lower-test-function-binop-op-count functions "fill" (Add)) 5))]
    [_ false]))

;; --- private SPMD ABI descriptors (#7405) ------------------------------------
(define (lower-test-function-abi-ordinary?
  [functions : (& functions ir.CompilerIrFunctionSeq)]
  [name : String]) : bool
  (let
    [found : bool false]
    [ordinary : bool false]
    [index : i64 0]
    (while (< index functions.len)
      (match (ir.compiler-ir-array-shared-view functions.slots index)
        [(Function fname _ _ _ _ function-abi)
          (if (string.eq (ir.compiler-ir-symbol-text fname) name)
            (begin
              (set! found true)
              (set!
                ordinary
                (ir.compiler-ir-function-abi-ordinary? function-abi)))
            unit)])
      (set! index (+ index 1)))
    (and found ordinary)))

;; Lower `src` in `mode`; the whole program must pass private ABI admission,
;; `caller` must keep the ordinary ABI, and the private helpers must have
;; exactly the `expected` shapes.
(define (compiler-lower-spmd-private-abi-case-ok?
  [src : String]
  [mode : lower.CompilerLowerMode]
  [caller : String]
  [expected : String]) : bool
  (match (lower-test-functions (lower.lower-compiler-source-with-mode src mode))
    [(Some functions)
      (and
        (string.eq (ir.compiler-ir-spmd-private-abi-program-error functions) "")
        (lower-test-function-abi-ordinary? functions caller)
        (string.eq
          (ir.compiler-ir-test-spmd-private-abi-shapes functions)
          expected))]
    [_ false]))

;; Optimization must keep every helper's descriptor and every call's copy of it:
;; admission still passes and the helper shapes are unchanged.
(define (compiler-lower-spmd-private-abi-optimized-ok?
  [src : String]
  [mode : lower.CompilerLowerMode]
  [level : i64]) : bool
  (match (lower.lower-compiler-source-with-mode src mode)
    [(Ok program spans)
      (let
        [before : String
          (match (ir.compiler-ir-global-shared-view program)
            [(Program _ functions _)
              (ir.compiler-ir-test-spmd-private-abi-shapes functions)])]
        [optimized : ir.CompilerIrProgram
          (match (optimize.optimize-program-with-spans-and-level
            program
            spans
            level)
            [(Program optimized _) optimized])]
        (match optimized
          [(Program _ functions _)
            (and
              (> (string.string-length before) 0)
              (string.eq
                (ir.compiler-ir-spmd-private-abi-program-error functions)
                "")
              (string.eq
                (ir.compiler-ir-test-spmd-private-abi-shapes functions)
                before))]))]
    [(Err _) false]))

(define (lower-test-twice [shape : String]) : String
  (str_cat.str-cat (clone shape) " | " shape))

;; Uniform `&mut` reference, varying i64, and two mask (varying bool) sources.
(define (compiler-lower-spmd-private-abi-mask-arg-source) : String
  "(define (heavy-store [out : (&mut out (__tl_dyn-array i64))] [i : i64] [take0 : bool] [take1 : bool]) : unit
  (if take0
    (if take1
      (set! (array-ref out i) (+ (+ (+ (+ (+ (+ (+ i 1) 2) 3) 4) 5) 6) 7))
      (set! (array-ref out i) (- (- (- (- (- (- (- i 1) 2) 3) 4) 5) 6) 7)))
    (set! (array-ref out i) 0)))
(define (fill [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (heavy-store out i (< i 7) (= (% i 3) 0))))")

;; A varying bool result is a mask.
(define (compiler-lower-spmd-private-abi-bool-result-source) : String
  "(define (large-enough? [x : i64]) : bool
  (> (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7) 30))
(define (fill [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (if (large-enough? i) (set! (array-ref out i) 1) (set! (array-ref out i) 0))))")

;; The result depends only on the uniform argument.
(define (compiler-lower-spmd-private-abi-uniform-result-source) : String
  "(define (heavy [x : i64] [k : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ k 1) 2) 3) 4) 5) 6) 7))
(define (fill [out : (__tl_dyn-array i64)] [n : i64] [k : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (heavy i k))))")

;; f64 sources and result, and a varying argument that is not the index.
(define (compiler-lower-spmd-private-abi-f64-source) : String
  "(define (heavy [x : f64] [s : f64]) : f64
  (+ (+ (+ (+ (+ (+ (+ (* x s) 1.0) 2.0) 3.0) 4.0) 5.0) 6.0) 7.0))
(define (fill [out : (__tl_dyn-array f64)] [xs : (__tl_dyn-array f64)] [n : i64] [s : f64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (heavy (array-ref xs i) s))))")

;; Every generated same-program helper carries the private ABI and every call
;; to it an equal copy (admission passes); the caller stays ordinary. Each
;; case pins the full descriptor: roles, physical ordinals and types, source
;; classes and types, index mapping, and result class. SIMD modes emit one
;; helper for the full gang and one for the tail.
(define (compiler-lower-spmd-private-abi-descriptors-ok?) : bool
  (let
    [mask : String "[0 active-mask : bool, "]
    [varying-i64 : String "source 0 varying i64 : i64"]
    [mask-arg-sources : String
      (str_cat.str-cat
        "1 source 0 uniform (&mut out (__tl_dyn-array i64)) : (&mut out (__tl_dyn-array i64)), "
        "2 source 1 varying i64 : i64, 3 source 2 mask bool : bool, "
        "4 source 3 mask bool : bool")]
    (and
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-out-of-line-value-source)
        (lower.CompilerLowerMode.Avx512)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx512 lanes 8 "
            (clone mask)
            "1 "
            (clone varying-i64)
            ", 2 index-base : i64] index appended 2 result varying i64")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-out-of-line-value-source)
        (lower.CompilerLowerMode.Avx2)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx2 lanes 4 "
            (clone mask)
            "1 "
            (clone varying-i64)
            ", 2 index-base : i64] index appended 2 result varying i64")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-out-of-line-unit-source)
        (lower.CompilerLowerMode.Avx512)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx512 lanes 8 "
            (clone mask)
            "1 "
            (clone varying-i64)
            ", 2 index-base : i64] index appended 2 result unit")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-varying-local-call-source)
        (lower.CompilerLowerMode.Avx2)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx2 lanes 4 "
            (clone mask)
            "1 "
            (clone varying-i64)
            "] index none result varying i64")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-private-abi-mask-arg-source)
        (lower.CompilerLowerMode.Avx512)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx512 lanes 8 "
            (clone mask)
            (clone mask-arg-sources)
            ", 5 index-base : i64] index appended 5 result unit")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-private-abi-bool-result-source)
        (lower.CompilerLowerMode.Avx2)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx2 lanes 4 "
            (clone mask)
            "1 "
            (clone varying-i64)
            ", 2 index-base : i64] index appended 2 result mask bool")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-private-abi-uniform-result-source)
        (lower.CompilerLowerMode.Avx512)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx512 lanes 8 "
            (clone mask)
            "1 "
            (clone varying-i64)
            ", 2 source 1 uniform i64 : i64, 3 index-base : i64]"
            " index appended 3 result uniform i64")))
      (compiler-lower-spmd-private-abi-case-ok?
        (compiler-lower-spmd-private-abi-f64-source)
        (lower.CompilerLowerMode.Avx512)
        "fill"
        (lower-test-twice
          (str_cat.str-cat
            "avx512 lanes 8 "
            (clone mask)
            "1 source 0 varying f64 : f64, 2 source 1 uniform f64 : f64]"
            " index none result varying f64")))
      (compiler-lower-spmd-private-abi-optimized-ok?
        (compiler-lower-spmd-private-abi-mask-arg-source)
        (lower.CompilerLowerMode.Avx512)
        1)
      (compiler-lower-spmd-private-abi-optimized-ok?
        (compiler-lower-spmd-private-abi-uniform-result-source)
        (lower.CompilerLowerMode.Avx2)
        2)
      (compiler-lower-spmd-private-abi-optimized-ok?
        (compiler-lower-spmd-private-abi-bool-result-source)
        (lower.CompilerLowerMode.Avx512)
        2))))

;; The scalar backend runs one lane, prepends the active bool, and never maps a
;; logical index.
(define (compiler-lower-spmd-scalar-private-abi-descriptors-ok?) : bool
  (and
    (compiler-lower-spmd-private-abi-case-ok?
      (compiler-lower-spmd-out-of-line-value-source)
      (lower.CompilerLowerMode.Scalar)
      "fill"
      "scalar lanes 1 [0 active-mask : bool, 1 source 0 varying i64 : i64] index none result varying i64")
    (compiler-lower-spmd-private-abi-case-ok?
      (compiler-lower-spmd-out-of-line-unit-source)
      (lower.CompilerLowerMode.Scalar)
      "fill"
      "scalar lanes 1 [0 active-mask : bool, 1 source 0 varying i64 : i64] index none result unit")
    (compiler-lower-spmd-private-abi-case-ok?
      (compiler-lower-spmd-private-abi-mask-arg-source)
      (lower.CompilerLowerMode.Scalar)
      "fill"
      (str_cat.str-cat
        "scalar lanes 1 [0 active-mask : bool, "
        "1 source 0 uniform (&mut out (__tl_dyn-array i64)) : (&mut out (__tl_dyn-array i64)), "
        "2 source 1 varying i64 : i64, 3 source 2 mask bool : bool, "
        "4 source 3 mask bool : bool] index none result unit"))
    (compiler-lower-spmd-private-abi-case-ok?
      (compiler-lower-spmd-private-abi-bool-result-source)
      (lower.CompilerLowerMode.Scalar)
      "fill"
      "scalar lanes 1 [0 active-mask : bool, 1 source 0 varying i64 : i64] index none result mask bool")
    (compiler-lower-spmd-private-abi-case-ok?
      (compiler-lower-spmd-private-abi-uniform-result-source)
      (lower.CompilerLowerMode.Scalar)
      "fill"
      "scalar lanes 1 [0 active-mask : bool, 1 source 0 varying i64 : i64, 2 source 1 uniform i64 : i64] index none result uniform i64")
    (compiler-lower-spmd-private-abi-optimized-ok?
      (compiler-lower-spmd-private-abi-mask-arg-source)
      (lower.CompilerLowerMode.Scalar)
      1)))

(define (compiler-lower-spmd-out-of-line-call-shape-ok?) : bool
  (and
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-value-source)
        (lower.CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (lower.CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-masked-source)
        (lower.CompilerLowerMode.Avx512))
      0)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-value-source)
        (lower.CompilerLowerMode.Avx512))
      2)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (lower.CompilerLowerMode.Avx512))
      2)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-value-source)
        (lower.CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (lower.CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-call-count
        (compiler-lower-spmd-out-of-line-masked-source)
        (lower.CompilerLowerMode.Avx2))
      0)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-value-source)
        (lower.CompilerLowerMode.Avx2))
      2)
    (>
      (compiler-lower-spmd-source-function-count
        (compiler-lower-spmd-out-of-line-unit-source)
        (lower.CompilerLowerMode.Avx2))
      2)
    (compiler-lower-spmd-varying-local-call-shape-ok?)
    (compiler-lower-spmd-uniform-arg-call-shape-ok?)
    (compiler-lower-spmd-private-abi-descriptors-ok?)))

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
      (lower.CompilerLowerMode.Avx2)
      false)
    (compiler-lower-spmd-lane-array-shape-ok?
      (lower.CompilerLowerMode.Avx512)
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
      (lower.CompilerLowerMode.Avx2))
    (compiler-lower-masked-if-bitand-value-shape-ok?
      (lower.CompilerLowerMode.Avx512))
    (compiler-lower-masked-if-bitwise-value-shape-ok?
      (lower.CompilerLowerMode.Avx2))
    (compiler-lower-masked-if-bitwise-value-shape-ok?
      (lower.CompilerLowerMode.Avx512))
    (compiler-lower-masked-shift-tests-ok?)
    (compiler-lower-avx512-masked-if-nested-shape-ok?)
    (compiler-lower-avx2-masked-if-shape-ok?)))

(define (compiler-lower-avx2-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]
  [vector-shapes : i64]
  [vector-binops : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx2)))
    [(Some functions)
      (and
        (= (lower-test-count functions "f" (VectorLoad)) 1)
        (= (lower-test-count functions "f" (VectorReduce)) 1)
        (= (lower-test-count functions "f" (VectorBinop)) vector-binops)
        (=
          (lower-test-function-vector-shape-count functions "f" lanes elem-ty)
          vector-shapes)
        (> (lower-test-count functions "f" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-bool-reduce-shape-ok?
  [src : String]
  [mode : lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-test-functions (lower.lower-compiler-source-with-mode src mode))
    [(Some functions)
      (and
        (= (lower-test-count functions "f" (VectorLoad)) 0)
        (= (lower-test-count functions "f" (VectorReduce)) 0)
        (= (lower-test-count functions "f" (PredicatedLoad)) 1)
        (= (lower-test-count functions "f" (TailMask)) 1)
        (=
          (lower-test-function-vector-shape-count functions "f" lanes (Bool))
          1)
        (> (lower-test-count functions "f" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-reduce-map-fused-shape-ok?
  [mode : lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [r : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0
    (+ (+ (array-ref xs i) r) (bit-and (program-index) 0))))"
      mode))
    [(Some functions)
      (and
        (= (lower-test-count functions "f" (VectorLoad)) 1)
        (= (lower-test-count functions "f" (VectorReduce)) 1)
        (= (lower-test-count functions "f" (VectorBinop)) 4)
        (= (lower-test-function-vector-shape-count functions "f" lanes (I64)) 9)
        (> (lower-test-count functions "f" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-avx512-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : ast.AstType]
  [lanes : i64]
  [vector-shapes : i64]
  [vector-binops : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode src (lower.CompilerLowerMode.Avx512)))
    [(Some functions)
      (and
        (= (lower-test-count functions "f" (VectorLoad)) 1)
        (= (lower-test-count functions "f" (VectorReduce)) 1)
        (= (lower-test-count functions "f" (VectorBinop)) vector-binops)
        (=
          (lower-test-function-vector-shape-count functions "f" lanes elem-ty)
          vector-shapes)
        (> (lower-test-count functions "f" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-reduce-lane-identity-source) : String
  "(define (f [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (program-count) (program-index))))")

(define (compiler-lower-spmd-reduce-lane-identity-shape-ok?
  [mode : lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-spmd-reduce-lane-identity-source)
      mode))
    [(Some functions)
      (and
        (= (lower-test-count functions "f" (VectorLoad)) 0)
        (= (lower-test-count functions "f" (VectorReduce)) 1)
        (= (lower-test-count functions "f" (VectorBinop)) 2)
        (= (lower-test-function-vector-shape-count functions "f" lanes (I64)) 5)
        (= (lower-test-count functions "f" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-reduce-gather-source-shape-ok?
  [source : String]
  [mode : lower.CompilerLowerMode]
  [lanes : i64]) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode source mode))
    [(Some functions)
      (and
        (= (lower-test-count functions "f" (VectorLoad)) 0)
        (= (lower-test-count functions "f" (VectorReduce)) 1)
        (= (lower-test-function-vector-shape-count functions "f" lanes (F32)) 2)
        (> (lower-test-count functions "f" (Bounds)) 0))]
    [_ false]))

(define (compiler-lower-spmd-reduce-gather-shape-ok?
  [mode : lower.CompilerLowerMode]
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
        (I64)
        4
        4
        1)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
        (I32)
        8
        4
        1)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (I32)
        8
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (I32)
        8
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (F64)
        4
        2
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (I64)
        4
        4
        0)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (I64)
        4
        4
        0)
      (compiler-lower-spmd-reduce-lane-identity-shape-ok?
        (lower.CompilerLowerMode.Avx2)
        4))
    (compiler-lower-avx2-spmd-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
      (F32)
      8
      2
      0)
    (compiler-lower-spmd-reduce-map-fused-shape-ok?
      (lower.CompilerLowerMode.Avx2)
      4)
    (compiler-lower-spmd-reduce-gather-shape-ok?
      (lower.CompilerLowerMode.Avx2)
      8)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))"
      (lower.CompilerLowerMode.Avx2)
      32)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))"
      (lower.CompilerLowerMode.Avx2)
      32)))

(define (compiler-lower-avx512-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
        (I64)
        8
        4
        1)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (I64)
        8
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (I64)
        8
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (F64)
        8
        2
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (I32)
        16
        4
        0)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (I32)
        16
        4
        0)
      (compiler-lower-spmd-reduce-lane-identity-shape-ok?
        (lower.CompilerLowerMode.Avx512)
        8)
      (compiler-lower-avx512-spmd-reduce-shape-ok?
        "(define (f [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
        (F32)
        16
        2
        0))
    (compiler-lower-spmd-reduce-map-fused-shape-ok?
      (lower.CompilerLowerMode.Avx512)
      8)
    (compiler-lower-spmd-reduce-gather-shape-ok?
      (lower.CompilerLowerMode.Avx512)
      16)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))"
      (lower.CompilerLowerMode.Avx512)
      64)
    (compiler-lower-spmd-bool-reduce-shape-ok?
      "(define (f [xs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))"
      (lower.CompilerLowerMode.Avx512)
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
  (match (lower-test-functions (lower.lower-compiler-source src))
    [(Some functions)
      (and
        (> (lower-test-count functions "f" (Branch)) 0)
        (= (lower-test-count functions "f" (Binop)) 0))]
    [_ false]))

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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-raw-pointer-ops-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (= (lower-test-count functions "main" (AddrOf)) 1)
        (>= (lower-test-count functions "main" (StorePtr)) 2))]
    [_ false]))

(define (compiler-lower-register-addr-of-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-register-addr-of-source)))
    [(Some functions)
      (and
        (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
        (>= (lower-test-count functions "main" (AddrOf)) 3)
        (>= (lower-test-count functions "main" (GepOffset 4)) 1)
        (>= (lower-test-count functions "main" (GepOffset 8)) 1)
        (>= (lower-test-count functions "main" (StorePtr)) 2))]
    [_ false]))

(define (compiler-lower-raw-pointer-call-value-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-raw-pointer-call-value-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions "raw-make") 1)
        (= (lower-test-functions-call-count functions "raw-value") 1)
        (= (lower-test-count functions "main" (StorePtr)) 1)
        (> (lower-test-count functions "main" (U64Mov)) 0))]
    [_ false]))

(define (compiler-lower-raw-pointer-aggregate-copy-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-raw-pointer-aggregate-copy-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "copy-slot" (CopyBytes)) 1)
        (= (lower-test-count functions "copy-slot" (StorePtr)) 0)
        (= (lower-test-count functions "copy-pair" (CopyBytes)) 0)
        (= (lower-test-count functions "copy-pair" (StorePtr)) 2))]
    [_ false]))

(define (compiler-lower-string-length-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-string-length-source))
    [(Ok program)
      (match (lower-test-functions (lower-compiler-program program))
        [(Some functions)
          (and
            (> (lower-test-count functions "core-str-len" (GepOffset 1)) 0)
            (>
              (lower-test-count functions "core-str-len-borrow" (GepOffset 1))
              0)
            (= (lower-test-functions-direct-call-count functions "length") 0))]
        [_ false])]
    [(Err _) false]))

(define (compiler-lower-float-bitcast-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-float-bitcast-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "f64-bits" (Bitcast)) 1)
        (= (lower-test-count functions "f32-bits" (Bitcast)) 1)
        (= (lower-test-count functions "f64-from" (Bitcast)) 1)
        (= (lower-test-count functions "f32-from" (Bitcast)) 1)
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
          0))]
    [_ false]))

(define (compiler-lower-literal-float-to-bits-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-literal-float-to-bits-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-bitcast-count functions) 0)
        (=
          (lower-test-functions-direct-call-count
            functions
            "__tl_float_to_bits")
          0))]
    [_ false]))

(define (compiler-lower-public-literal-float-to-bits-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-lower-public-literal-float-to-bits-source))
    [(Ok program)
      (match (lower-test-functions
        (lower-compiler-program-with-decl-paths
          "stdlib/math.tl"
          program
          (compiler-lower-public-literal-float-to-bits-paths)))
        [(Some functions) (= (lower-test-functions-bitcast-count functions) 0)]
        [_ false])]
    [(Err _) false]))

(define (compiler-lower-string-runtime-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-string-runtime-source))
    [(Ok program)
      (match (lower-compiler-program program)
        [(Ok _ _) true]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-lower-stdio-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-stdio-source))
    [(Ok program)
      (match (lower-compiler-program program)
        [(Ok _ _) true]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-lower-stdio-builtin-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-stdio-builtin-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions ".L_tl_flush_stdout") 0)
        (= (lower-test-functions-call-count functions ".L_tl_stdin_eof") 0)
        (=
          (lower-test-functions-call-count functions ".L_tl_read_stdin_line")
          0)
        (=
          (lower-test-functions-call-count functions ".L_tl_read_stdin_bytes")
          0)
        (= (lower-test-functions-call-count functions "flush-stdout") 1)
        (= (lower-test-functions-call-count functions "stdin-eof?") 1)
        (= (lower-test-functions-call-count functions "read-stdin-line") 1)
        (= (lower-test-functions-call-count functions "io.read-stdin-bytes") 1))]
    [_ false]))

(define (compiler-lower-env-builtin-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-env-builtin-source)))
    [(Some functions)
      (and
        (= (lower-test-functions-call-count functions "tl_env_var_exists") 0)
        (= (lower-test-functions-call-count functions "tl_env_var_value") 0)
        (= (lower-test-functions-direct-call-count functions "var-exists?") 1)
        (= (lower-test-functions-direct-call-count functions "var-value") 1)
        (=
          (lower-test-functions-direct-call-count functions "path-separator")
          1))]
    [_ false]))

(define (compiler-lower-stdlib-helper-defaults-disabled-ok?) : bool
  (and
    (not
      (lower.lower-bootstrap-runtime-builtin-id?
        cbi.compiler-builtin-id-env-path-separator))
    (not
      (not
        (lower.lower-bootstrap-runtime-builtin-id?
          cbi.compiler-builtin-id-tl-private-string-eq)))
    (not
      (not
        (lower.lower-bootstrap-runtime-builtin-id?
          cbi.compiler-builtin-id-tl-private-string-to-int)))
    (not (lower.lower-string-runtime-builtin? "substring"))
    (not (lower.lower-string-runtime-builtin? "string-slice"))
    (not (lower.lower-string-runtime-builtin? "string-append"))
    (not (lower.lower-string-runtime-builtin? "string-concat"))))

(define (compiler-lower-cpu-builtin-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-cpu-builtin-source)))
    [(Some functions)
      (and
        (>= (lower-test-functions-cpuid-count functions) 4)
        (= (lower-test-functions-xgetbv-count functions) 1)
        (= (lower-test-functions-call-count functions "cpuid") 0)
        (= (lower-test-functions-call-count functions "xgetbv") 0)
        (= (lower-test-functions-call-count functions "tl_cpuid") 0)
        (= (lower-test-functions-call-count functions "tl_xgetbv") 0))]
    [_ false]))

(define (compiler-lower-runtime-helper-tests-ok?) : bool
  (and
    (compiler-lower-string-length-ok?)
    (compiler-lower-float-bitcast-ok?)
    (compiler-lower-literal-float-to-bits-ok?)
    (compiler-lower-public-literal-float-to-bits-ok?)
    (compiler-lower-stdlib-string-wrapper-prune-ok?)
    (compiler-lower-string-runtime-ok?)
    (compiler-lower-string-runtime-shape-ok?
      (compiler-lower-string-runtime-source))
    (compiler-lower-string-concat-fusion-shape-ok?)
    (compiler-lower-emit-string-stdlib-shape-ok?)
    (compiler-lower-borrowed-str-param-shape-ok?)
    (compiler-lower-stdlib-hash-string-shape-ok?)
    (compiler-lower-string-shadow-shape-ok?
      (compiler-lower-string-shadow-source))
    (compiler-lower-stdio-ok?)
    (compiler-lower-stdio-builtin-shape-ok?)
    (compiler-lower-stdlib-helper-defaults-disabled-ok?)
    (compiler-lower-env-builtin-shape-ok?)
    (compiler-lower-cpu-builtin-shape-ok?)
    (compiler-lower-fs-status-shape-ok?)))

(define (lower-test-decl-list-count [decls : (& decls ast.AstDeclList)]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) 0]
    [(Cons _ rest)
      (let
        [rest : ast.AstDeclList rest]
        (+ 1 (lower-test-decl-list-count rest)))]))

(define (lower-test-decl-list-defines?
  [decls : (& decls ast.AstDeclList)]
  [name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(DefFn decl-meta found _ _ _ _)
            (if (string.eq (tc_core.tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(DefEnum decl-meta found _ _)
            (if (string.eq (tc_core.tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(DefEnumLifetimes decl-meta found _ _ _)
            (if (string.eq (tc_core.tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(DefStruct decl-meta found _ _ _)
            (if (string.eq (tc_core.tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(DefStructLifetimes decl-meta found _ _ _ _)
            (if (string.eq (tc_core.tc-env-key-name-text found) name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(Unsafe inner-box)
            (let
              [inner : ast.AstDecl (ast.ast-decl-box-shared-view inner-box)]
              (if (let
                [arg (ast.ast-decl-cons inner (ast.ast-decl-list-new))]
                (lower-test-decl-list-defines?
                  arg
                  (owned_view.compiler-owned-shared-view name)))
                true
                (lower-test-decl-list-defines? rest name)))]
          [_ (lower-test-decl-list-defines? rest name)]))]))

(define (compiler-lower-ast-dce-program) : ast.AstProgram
  (let
    [callback-id : i64 (lower-test-generated-name-id "callback")]
    [callback-target-id : i64 cbi.compiler-builtin-id-fix-callback_target]
    [main-id : i64 cbi.compiler-builtin-id-fix-main]
    [helper-id : i64 cbi.compiler-builtin-id-fix-helper]
    [dead-id : i64 (lower-test-generated-name-id "dead")]
    (ast.ast-program
      (ast.ast-decl-cons
        (ast.ast-decl-def-id
          callback-id
          No
          (ast.ast-node-push (Var callback-target-id)))
        (ast.ast-decl-cons
          (ast.ast-decl-def-fn-id
            main-id
            (ast.ast-param-list-new)
            (I64)
            (ast.ast-expr-call
              (ast.ast-node-push (Var helper-id))
              (ast.ast-expr-list-new)))
          (ast.ast-decl-cons
            (ast.ast-decl-def-fn-id
              helper-id
              (ast.ast-param-list-new)
              (I64)
              (ast.ast-node-push (Literal (ast.ast-lit-int 7))))
            (ast.ast-decl-cons
              (ast.ast-decl-def-fn-id
                callback-target-id
                (ast.ast-param-list-new)
                (I64)
                (ast.ast-node-push (Literal (ast.ast-lit-int 11))))
              (ast.ast-decl-cons
                (ast.ast-decl-def-fn-id
                  dead-id
                  (ast.ast-param-list-new)
                  (I64)
                  (ast.ast-node-push (Literal (ast.ast-lit-int 9))))
                (ast.ast-decl-list-new)))))))))

(define (compiler-lower-dce-test-symbols-ready?) : bool
  (match (parser.parse-ast-source
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
    [(Ok _) true]
    [(Err _) false]))

(define (compiler-lower-ast-dce-no-main-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-def-fn-id
        (lower-test-generated-name-id "helper")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 7))))
      (ast.ast-decl-cons
        (ast.ast-decl-def-fn-id
          (lower-test-generated-name-id "dead")
          (ast.ast-param-list-new)
          (I64)
          (ast.ast-node-push (Literal (ast.ast-lit-int 9))))
        (ast.ast-decl-list-new)))))

(define (compiler-lower-macro-body-dce-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-def-fn-id
        (lower-test-generated-name-id "main")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
      (ast.ast-decl-cons
        (ast.ast-decl-def-fn-id
          (lower-test-generated-name-id "macro-only-helper")
          (ast.ast-param-list-new)
          (I64)
          (ast.ast-node-push (Literal (ast.ast-lit-int 7))))
        (ast.ast-decl-cons
          (ast.ast-decl-def-macro-id
            (lower-test-generated-name-id "macro-uses-helper")
            (ast.ast-macro-param-list-new)
            (Expr)
            (ast.ast-expr-call
              (ast.ast-node-push
                (Var cbi.compiler-builtin-id-fix-macro_only_helper))
              (ast.ast-expr-list-new)))
          (ast.ast-decl-list-new))))))

(define (compiler-lower-stdlib-comptime-runtime-dce-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-module-id (lower-test-generated-name-id "stdlib.comptime"))
      (ast.ast-decl-cons
        (ast.ast-decl-def-fn-id
          (lower-test-generated-name-id "ctfe-runtime-helper")
          (ast.ast-param-list-new)
          (I64)
          (ast.ast-node-push (Literal (ast.ast-lit-int 7))))
        (ast.ast-decl-cons
          (ast.ast-decl-module-id (lower-test-generated-name-id "main"))
          (ast.ast-decl-cons
            (ast.ast-decl-def-fn-id
              (lower-test-generated-name-id "main")
              (ast.ast-param-list-new)
              (I64)
              (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
            (ast.ast-decl-list-new)))))))

(define (compiler-lower-stdlib-comptime-runtime-skip-keeps-types-ok?) : bool
  (let
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        (ast.ast-decl-def-fn-id
          (lower-test-generated-name-id "ctfe-runtime-helper")
          (ast.ast-param-list-new)
          (I64)
          (ast.ast-node-push (Literal (ast.ast-lit-int 7))))
        (ast.ast-decl-cons
          (ast.ast-decl-comptime-decl
            (ast.ast-decl-def-struct-id
              (lower-test-generated-name-id "ExprClauseList")
              Default
              No
              (ast.ast-field-def-list-new)))
          (ast.ast-decl-cons
            (ast.ast-decl-module-id (lower-test-generated-name-id "main"))
            (ast.ast-decl-cons
              (ast.ast-decl-def-fn-id
                (lower-test-generated-name-id "main")
                (ast.ast-param-list-new)
                (I64)
                (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
              (ast.ast-decl-list-new)))))]
    [kept : ast.AstDeclList (lower-skip-runtime-until-next-module decls)]
    (and
      (= (lower-test-decl-list-count kept) 3)
      (lower-test-decl-list-defines? kept "ExprClauseList")
      (lower-test-decl-list-defines? kept "main")
      (not (lower-test-decl-list-defines? kept "ctfe-runtime-helper")))))

(define (compiler-lower-stdlib-comptime-type-prune-keeps-types-ok?) : bool
  (let
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (ast.ast-decl-module-id
            (lower-test-generated-name-id "stdlib.comptime"))
          (ast.ast-decl-cons
            (ast.ast-decl-def-fn-id
              (lower-test-generated-name-id "ctfe-runtime-helper")
              (ast.ast-param-list-new)
              (I64)
              (ast.ast-node-push (Literal (ast.ast-lit-int 7))))
            (ast.ast-decl-cons
              (ast.ast-decl-comptime-decl
                (ast.ast-decl-def-struct-id
                  (lower-test-generated-name-id "ExprClauseList")
                  Default
                  No
                  (ast.ast-field-def-list-new)))
              (ast.ast-decl-cons
                (ast.ast-decl-module-id (lower-test-generated-name-id "main"))
                (ast.ast-decl-cons
                  (ast.ast-decl-def-fn-id
                    (lower-test-generated-name-id "main")
                    (ast.ast-param-list-new)
                    (I64)
                    (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
                  (ast.ast-decl-list-new)))))))]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (ast.ast-decl-path-list-new)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (ast.ast-decl-path-list-new)
        names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (lower-test-decl-list-defines? kept "ExprClauseList")
                (lower-test-decl-list-defines? kept "main")
                (not (lower-test-decl-list-defines? kept "ctfe-runtime-helper"))))])])))

(define (compiler-lower-stdlib-comptime-nullary-enum-runtime-skip-ok?) : bool
  (match (lower.lower-compiler-source
    "(import stdlib.comptime)
(define (main) : i64 0)")
    [(Ok program _)
      (match program
        [(Program globals _ _)
          (not
            (lower-test-global-list-has-name?
              globals
              "__enum_obj_stdlib.comptime/Pattern_Wildcard"))])]
    [(Err _) false]))

(define (compiler-lower-unsafe-ast-dce-source) : String
  "(define (main) : i64 (unsafe (unsafe-entry)))
(define (unsafe-helper) : i64 41)
(unsafe (define (unsafe-entry) : i64 (unsafe-helper)))
(define (dead-helper) : i64 0)
(unsafe (define (dead-unsafe) : i64 (dead-helper)))")

(define (compiler-lower-type-decl-dce-program) : ast.AstProgram
  (let
    [used-enum-id : i64 cbi.compiler-builtin-id-fix-UsedEnum]
    [used-box-id : i64 cbi.compiler-builtin-id-fix-UsedBox]
    (ast.ast-program
      (ast.ast-decl-cons
        (ast.ast-decl-def-enum-id
          used-enum-id
          No
          (ast.ast-variant-def-cons
            (ast.ast-variant-def-id
              (lower-test-generated-name-id "UsedA")
              (ast.ast-type-list-new)
              (ast.ast-variant-payload-cleanup-list-new))
            (ast.ast-variant-def-list-new)))
        (ast.ast-decl-cons
          (ast.ast-decl-def-enum-id
            (lower-test-generated-name-id "DeadEnum")
            No
            (ast.ast-variant-def-cons
              (ast.ast-variant-def-id
                (lower-test-generated-name-id "DeadA")
                (ast.ast-type-list-new)
                (ast.ast-variant-payload-cleanup-list-new))
              (ast.ast-variant-def-list-new)))
          (ast.ast-decl-cons
            (ast.ast-decl-def-struct-id
              used-box-id
              Default
              No
              (ast.ast-field-def-cons
                (ast.ast-field-def-id
                  (lower-test-generated-syntax-id "value")
                  (Enum used-enum-id)
                  No)
                (ast.ast-field-def-list-new)))
            (ast.ast-decl-cons
              (ast.ast-decl-def-struct-id
                (lower-test-generated-name-id "DeadBox")
                Default
                No
                (ast.ast-field-def-cons
                  (ast.ast-field-def-id
                    (lower-test-generated-syntax-id "value")
                    (I64)
                    No)
                  (ast.ast-field-def-list-new)))
              (ast.ast-decl-cons
                (ast.ast-decl-def-fn-id
                  cbi.compiler-builtin-id-fix-main
                  (ast.ast-param-list-new)
                  (Struct used-box-id)
                  (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
                (ast.ast-decl-list-new)))))))))

(define (compiler-lower-type-decl-dce-paths) : ast.AstDeclPathList
  (let
    [types-id : i64 (load.compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (load.compiler-load-source-path-id "entry.tl")]
    (ast.ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (ast.ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (ast.ast-decl-path-cons-with-owner-id
          "types.tl"
          types-id
          (ast.ast-decl-path-cons-with-owner-id
            "types.tl"
            types-id
            (ast.ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (ast.ast-decl-path-list-new))))))))

(define (compiler-lower-type-decl-dce-qualified-base-program) : ast.AstProgram
  (let
    [result-id : i64
      (load.compiler-load-parse-context-name-id "io.ResultIoString")]
    [dead-result-id : i64
      (load.compiler-load-parse-context-name-id "io.DeadResult")]
    (ast.ast-program
      (ast.ast-decl-cons
        (ast.ast-decl-def-enum-id
          result-id
          No
          (ast.ast-variant-def-cons
            (ast.ast-variant-def-id
              (lower-test-generated-name-id "OkIoString")
              (ast.ast-type-list-new)
              (ast.ast-variant-payload-cleanup-list-new))
            (ast.ast-variant-def-list-new)))
        (ast.ast-decl-cons
          (ast.ast-decl-def-enum-id
            dead-result-id
            No
            (ast.ast-variant-def-cons
              (ast.ast-variant-def-id
                (lower-test-generated-name-id "DeadResultA")
                (ast.ast-type-list-new)
                (ast.ast-variant-payload-cleanup-list-new))
              (ast.ast-variant-def-list-new)))
          (ast.ast-decl-cons
            (ast.ast-decl-def-fn-id
              cbi.compiler-builtin-id-fix-main
              (ast.ast-param-list-new)
              (Enum result-id)
              (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
            (ast.ast-decl-list-new)))))))

(define (compiler-lower-type-decl-dce-qualified-base-paths) : ast.AstDeclPathList
  (let
    [types-id : i64 (load.compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (load.compiler-load-source-path-id "entry.tl")]
    (ast.ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (ast.ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (ast.ast-decl-path-cons-with-owner-id
          "entry.tl"
          entry-id
          (ast.ast-decl-path-list-new))))))

(define (compiler-lower-type-decl-dce-arena-support-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-module-id
        (load.compiler-load-parse-context-name-id "stdlib.arena"))
      (ast.ast-decl-cons
        (ast.ast-decl-def-struct-id
          (ci.intern-dotted-tail-id cbi.compiler-builtin-id-fix-arena_dot_Arena)
          Default
          No
          (ast.ast-field-def-cons
            (ast.ast-field-def-id
              (lower-test-generated-syntax-id "handle")
              (I64)
              No)
            (ast.ast-field-def-list-new)))
        (ast.ast-decl-cons
          (ast.ast-decl-def-struct-id
            cbi.compiler-builtin-id-fix-ArenaMark
            Default
            No
            (ast.ast-field-def-cons
              (ast.ast-field-def-id
                (lower-test-generated-syntax-id "handle")
                (I64)
                No)
              (ast.ast-field-def-list-new)))
          (ast.ast-decl-cons
            (ast.ast-decl-def-struct-id
              (lower-test-generated-name-id "DeadArenaPeer")
              Default
              No
              (ast.ast-field-def-cons
                (ast.ast-field-def-id
                  (lower-test-generated-syntax-id "handle")
                  (I64)
                  No)
                (ast.ast-field-def-list-new)))
            (ast.ast-decl-cons
              (ast.ast-decl-module-id cbi.compiler-builtin-id-fix-main)
              (ast.ast-decl-cons
                (ast.ast-decl-def-struct-id
                  cbi.compiler-builtin-id-fix-ThreadBox
                  Default
                  No
                  (ast.ast-field-def-cons
                    (ast.ast-field-def-id
                      (lower-test-generated-syntax-id "owner")
                      (Struct cbi.compiler-builtin-id-fix-arena_dot_Arena)
                      No)
                    (ast.ast-field-def-list-new)))
                (ast.ast-decl-cons
                  (ast.ast-decl-def-fn-id
                    cbi.compiler-builtin-id-fix-main
                    (ast.ast-param-list-new)
                    (Struct cbi.compiler-builtin-id-fix-ThreadBox)
                    (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
                  (ast.ast-decl-list-new))))))))))

(define (compiler-lower-type-decl-dce-arena-support-paths) : ast.AstDeclPathList
  (let
    [arena-id : i64 (load.compiler-load-source-path-id "arena.tl")]
    [entry-id : i64 (load.compiler-load-source-path-id "entry.tl")]
    [thread-id : i64 (load.compiler-load-source-path-id "thread.tl")]
    (ast.ast-decl-path-cons-with-owner-id
      "arena.tl"
      arena-id
      (ast.ast-decl-path-cons-with-owner-id
        "arena.tl"
        arena-id
        (ast.ast-decl-path-cons-with-owner-id
          "arena.tl"
          arena-id
          (ast.ast-decl-path-cons-with-owner-id
            "arena.tl"
            arena-id
            (ast.ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (ast.ast-decl-path-cons-with-owner-id
                "thread.tl"
                thread-id
                (ast.ast-decl-path-cons-with-owner-id
                  "entry.tl"
                  entry-id
                  (ast.ast-decl-path-list-new))))))))))

(define (compiler-lower-type-decl-dce-test-body-program) : ast.AstProgram
  (let
    [unit-expr : i64 (ast.ast-node-push (Literal (Unit)))]
    [test-body : i64
      (ast.ast-expr-let
        (ast.ast-let-binding-cons
          (ast.ast-let-binding-id
            (lower-test-generated-name-id "mark")
            (Some (Struct cbi.compiler-builtin-id-fix-ImportedMark))
            unit-expr)
          (ast.ast-let-binding-list-new))
        unit-expr)]
    (ast.ast-program
      (ast.ast-decl-cons
        (ast.ast-decl-def-struct-id
          cbi.compiler-builtin-id-fix-ImportedMark
          Default
          No
          (ast.ast-field-def-list-new))
        (ast.ast-decl-cons
          (ast.ast-decl-def-struct-id
            (lower-test-generated-name-id "DeadMark")
            Default
            No
            (ast.ast-field-def-list-new))
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              (lower-test-generated-name-id "uses-imported-mark-annotation")
              test-body
              (ast.ast-source-span 1 1 1 1))
            (ast.ast-decl-cons
              (ast.ast-decl-def-fn-id
                cbi.compiler-builtin-id-fix-main
                (ast.ast-param-list-new)
                (I64)
                (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
              (ast.ast-decl-list-new))))))))

(define (compiler-lower-type-decl-dce-test-body-paths) : ast.AstDeclPathList
  (let
    [types-id : i64 (load.compiler-load-source-path-id "types.tl")]
    [entry-id : i64 (load.compiler-load-source-path-id "entry.tl")]
    (ast.ast-decl-path-cons-with-owner-id
      "types.tl"
      types-id
      (ast.ast-decl-path-cons-with-owner-id
        "types.tl"
        types-id
        (ast.ast-decl-path-cons-with-owner-id
          "entry.tl"
          entry-id
          (ast.ast-decl-path-cons-with-owner-id
            "entry.tl"
            entry-id
            (ast.ast-decl-path-list-new)))))))

(define (compiler-lower-type-decl-dce-body-pattern-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-module-id
        (load.compiler-load-parse-context-name-id "struct.match.geom"))
      (ast.ast-decl-cons
        (ast.ast-decl-def-struct-id
          (load.compiler-load-parse-context-name-id "QPoint")
          Default
          No
          (ast.ast-field-def-cons
            (ast.ast-field-def-id (lower-test-generated-syntax-id "x") (I64) No)
            (ast.ast-field-def-cons
              (ast.ast-field-def-id
                (lower-test-generated-syntax-id "y")
                (I64)
                No)
              (ast.ast-field-def-list-new))))
        (ast.ast-decl-cons
          (ast.ast-decl-def-struct-id
            (lower-test-generated-name-id "DeadGeom")
            Default
            No
            (ast.ast-field-def-cons
              (ast.ast-field-def-id
                (lower-test-generated-syntax-id "value")
                (I64)
                No)
              (ast.ast-field-def-list-new)))
          (ast.ast-decl-cons
            (ast.ast-decl-module-id cbi.compiler-builtin-id-fix-main)
            (ast.ast-decl-cons
              (ast.ast-decl-def-fn-id
                cbi.compiler-builtin-id-fix-main
                (ast.ast-param-list-new)
                (I64)
                (ast.ast-expr-match
                  (ast.ast-node-push (Literal (ast.ast-lit-int 0)))
                  (ast.ast-match-arm-cons
                    (ast.ast-match-arm
                      (ast.ast-pat-variant-id
                        (load.compiler-load-parse-context-name-id "geom.QPoint")
                        (ast.ast-pattern-cons
                          (ast.ast-pat-binding-id
                            (lower-test-generated-name-id "x"))
                          (ast.ast-pattern-cons
                            (ast.ast-pat-binding-id
                              (lower-test-generated-name-id "y"))
                            (ast.ast-pattern-list-new))))
                      (ast.ast-node-push (Literal (ast.ast-lit-int 0))))
                    (ast.ast-match-arm-list-new))))
              (ast.ast-decl-list-new))))))))

(define (compiler-lower-type-decl-dce-body-pattern-paths) : ast.AstDeclPathList
  (let
    [geom-id : i64 (load.compiler-load-source-path-id "geom.tl")]
    [entry-id : i64 (load.compiler-load-source-path-id "entry.tl")]
    (ast.ast-decl-path-cons-with-owner-id
      "geom.tl"
      geom-id
      (ast.ast-decl-path-cons-with-owner-id
        "geom.tl"
        geom-id
        (ast.ast-decl-path-cons-with-owner-id
          "geom.tl"
          geom-id
          (ast.ast-decl-path-cons-with-owner-id
            "entry.tl"
            entry-id
            (ast.ast-decl-path-cons-with-owner-id
              "entry.tl"
              entry-id
              (ast.ast-decl-path-list-new))))))))

(define (compiler-lower-ast-dce-ok?) : bool
  (let
    [program : ast.AstProgram (compiler-lower-ast-dce-program)]
    [no-main-program : ast.AstProgram (compiler-lower-ast-dce-no-main-program)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (ast.ast-decl-path-list-new)
              "entry.tl"
              Nil))])]
    [no-main-names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view no-main-program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (ast.ast-decl-path-list-new)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (ast.ast-decl-path-list-new)
        names)]
    [no-main-pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        no-main-program
        (ast.ast-decl-path-list-new)
        no-main-names)]
    (match pruned
      [(Program kept-program _)
        (match no-main-pruned
          [(Program kept-no-main _)
            (match kept-program
              [(Program kept-box)
                (let
                  [kept : ast.AstDeclList
                    (ast.ast-decl-list-box-shared-view kept-box)]
                  (match kept-no-main
                    [(Program no-main-kept-box)
                      (let
                        [no-main-kept : ast.AstDeclList
                          (ast.ast-decl-list-box-shared-view no-main-kept-box)]
                        (and
                          (= (lower-test-decl-list-count kept) 4)
                          (lower-test-decl-list-defines? kept "main")
                          (lower-test-decl-list-defines? kept "helper")
                          (lower-test-decl-list-defines? kept "callback-target")
                          (not (lower-test-decl-list-defines? kept "dead"))
                          (= (lower-test-decl-list-count no-main-kept) 2)))]))])])])))

(define (compiler-lower-type-decl-dce-ok?) : bool
  (let
    [program : ast.AstProgram (compiler-lower-type-decl-dce-program)]
    [paths : ast.AstDeclPathList (compiler-lower-type-decl-dce-paths)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 3)
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "UsedBox")
                (lower-test-decl-list-defines? kept "UsedEnum")
                (not (lower-test-decl-list-defines? kept "DeadBox"))
                (not (lower-test-decl-list-defines? kept "DeadEnum"))))])])))

(define (compiler-lower-type-decl-dce-qualified-base-ok?) : bool
  (let
    [program : ast.AstProgram
      (compiler-lower-type-decl-dce-qualified-base-program)]
    [paths : ast.AstDeclPathList
      (compiler-lower-type-decl-dce-qualified-base-paths)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 2)
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "io.ResultIoString")
                (not (lower-test-decl-list-defines? kept "io.DeadResult"))))])])))

(define (compiler-lower-type-decl-dce-arena-support-ok?) : bool
  (let
    [program : ast.AstProgram
      (compiler-lower-type-decl-dce-arena-support-program)]
    [paths : ast.AstDeclPathList
      (compiler-lower-type-decl-dce-arena-support-paths)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "ThreadBox")
                (lower-test-decl-list-defines? kept "Arena")
                (lower-test-decl-list-defines? kept "ArenaMark")
                (not (lower-test-decl-list-defines? kept "DeadArenaPeer"))))])])))

(define (compiler-lower-type-decl-dce-test-body-ok?) : bool
  (let
    [program : ast.AstProgram (compiler-lower-type-decl-dce-test-body-program)]
    [paths : ast.AstDeclPathList (compiler-lower-type-decl-dce-test-body-paths)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 3)
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "ImportedMark")
                (not (lower-test-decl-list-defines? kept "DeadMark"))))])])))

(define (compiler-lower-type-decl-dce-body-pattern-ok?) : bool
  (let
    [program : ast.AstProgram
      (compiler-lower-type-decl-dce-body-pattern-program)]
    [paths : ast.AstDeclPathList
      (compiler-lower-type-decl-dce-body-pattern-paths)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (owned_view.compiler-owned-shared-view paths)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions "entry.tl" program paths names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (lower-test-decl-list-defines? kept "main")
                (lower-test-decl-list-defines? kept "QPoint")
                (not (lower-test-decl-list-defines? kept "DeadGeom"))))])])))

(define (compiler-lower-macro-body-dce-ok?) : bool
  (let
    [program : ast.AstProgram (compiler-lower-macro-body-dce-program)]
    [names : lower.LowerNameEnv
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (lower-name-env-from-decls
              decls
              (ast.ast-decl-path-list-new)
              "entry.tl"
              Nil))])]
    [pruned : LowerPrunedProgram
      (lower-test-prune-unreachable-functions
        "entry.tl"
        program
        (ast.ast-decl-path-list-new)
        names)]
    (match pruned
      [(Program kept-program _)
        (match kept-program
          [(Program kept-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view kept-box)]
              (and
                (= (lower-test-decl-list-count kept) 2)
                (lower-test-decl-list-defines? kept "main")
                (not (lower-test-decl-list-defines? kept "macro-only-helper"))))])])))

(define (compiler-lower-stdlib-comptime-runtime-dce-ok?) : bool
  (match (lower-compiler-program-with-decl-paths
    "entry.tl"
    (compiler-lower-stdlib-comptime-runtime-dce-program)
    (ast.ast-decl-path-list-new))
    [(Ok lowered _)
      (match lowered
        [(Program _ functions externs)
          (and
            (= (ir.compiler-ir-function-seq-count functions) 1)
            (= (ir.compiler-ir-extern-seq-count externs) 0)
            (lower-test-function-defined? functions "main"))])]
    [(Err _) false]))

(define (compiler-lower-unsafe-ast-dce-kept-ok? [kept : ast.AstDeclList]) : bool
  (and
    (= (lower-test-decl-list-count kept) 3)
    (lower-test-decl-list-defines? kept "main")
    (lower-test-decl-list-defines? kept "unsafe-helper")
    (lower-test-decl-list-defines? kept "unsafe-entry")
    (not (lower-test-decl-list-defines? kept "dead-helper"))
    (not (lower-test-decl-list-defines? kept "dead-unsafe"))))

(define (compiler-lower-unsafe-ast-dce-ok?) : bool
  (match (parser.parse-ast-source (compiler-lower-unsafe-ast-dce-source))
    [(Ok program)
      (match (owned_view.compiler-owned-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            [names : lower.LowerNameEnv
              (lower-name-env-from-decls
                decls
                (ast.ast-decl-path-list-new)
                "entry.tl"
                Nil)]
            [pruned : LowerPrunedProgram
              (lower-test-prune-unreachable-functions
                "entry.tl"
                program
                (ast.ast-decl-path-list-new)
                names)]
            (match pruned
              [(Program kept-program _)
                (match kept-program
                  [(Program kept-box)
                    (compiler-lower-unsafe-ast-dce-kept-ok?
                      (ast.ast-decl-list-box-shared-view kept-box))])]))])]
    [(Err _) false]))

(define (compiler-lower-name-env-dense-snapshots-ok?) : bool
  (let
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
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
    [base : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        source-id
        base-logical-id
        base-symbol-id
        Nil)]
    [child : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        source-id
        child-logical-id
        child-symbol-id
        (lower.lower-global-shared-view base))]
    [sibling : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        sibling-id
        sibling-id
        sibling-symbol-id
        (lower.lower-global-shared-view base))]
    [grown : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        source-id
        child-logical-id
        grown-symbol-id
        (lower.lower-global-shared-view child))]
    [grow-index : i64 1]
    [_grow : unit
      (while (< grow-index 16)
        (set!
          grown
          (lower.lower-name-env-bind-logical-symbol-id
            source-id
            child-logical-id
            grown-symbol-id
            grown))
        (set! grow-index (+ grow-index 1)))]
    [copied : lower.LowerNameEnv
      (lower.lower-name-env-copy-active (lower.lower-global-shared-view child))]
    [copy-branch : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        source-id
        source-id
        copy-branch-symbol-id
        (lower.lower-global-shared-view copied))]
    [right : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        alias-id
        alias-id
        right-symbol-id
        Nil)]
    [left : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        alias-id
        alias-id
        left-new-symbol-id
        (lower.lower-name-env-bind-logical-symbol-id
          alias-id
          alias-id
          left-old-symbol-id
          Nil))]
    [appended : lower.LowerNameEnv
      (lower.lower-name-env-append left (lower.lower-global-shared-view right))]
    [previous-global : lower.LowerNameCache
      (lower.lower-active-global-name-cache-current lower-state)]
    [_set-global : unit
      (lower.lower-active-global-name-cache-set!
        lower-state
        (lower.lower-name-cache-from-env
          lower-state
          (lower.lower-global-shared-view base)))]
    [overlay : lower.LowerNameCache
      (lower.lower-name-cache-overlay
        lower-state
        (lower.lower-name-env-bind-logical-symbol-id
          overlay-id
          overlay-id
          overlay-symbol-id
          Nil)
        (ci.intern-generated-canonical-name "dense-overlay-module"))]
    [ok : bool
      (and
        (= (lower.lower-name-env-count base) 1)
        (= (lower.lower-name-env-count child) 2)
        (= (lower.lower-name-env-count sibling) 2)
        (= (lower.lower-name-env-count grown) 18)
        (= (lower.lower-name-env-count copied) 2)
        (= (lower.lower-name-env-count copy-branch) 3)
        (= (lower.lower-name-env-count appended) 3)
        (=
          (lower.lower-name-env-lookup-symbol-id base source-id -1)
          base-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id
            (lower.lower-global-shared-view child)
            source-id
            -1)
          child-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id
            (lower.lower-global-shared-view sibling)
            source-id
            -1)
          base-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id grown source-id -1)
          grown-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id sibling sibling-id -1)
          sibling-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id
            (lower.lower-global-shared-view copied)
            source-id
            -1)
          child-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id copy-branch source-id -1)
          copy-branch-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id appended alias-id -1)
          left-new-symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id right alias-id -1)
          right-symbol-id)
        (string.eq
          (tc_core.tc-env-key-name-text
            (lower.lower-name-env-lookup-symbol-id copied source-id -1))
          (tc_core.tc-env-key-name-text child-symbol-id))
        (=
          (lower.lower-name-cache-lookup-symbol-id (& overlay) overlay-id -1)
          overlay-symbol-id)
        (=
          (lower.lower-name-cache-lookup-symbol-id (& overlay) source-id -1)
          base-symbol-id)
        (match (lower.lower-name-env-view child)
          [(Bind head-source _ head-symbol rest)
            (and
              (= head-source source-id)
              (= head-symbol child-symbol-id)
              (match (lower.lower-name-env-view rest)
                [(Bind tail-source _ tail-symbol tail)
                  (and
                    (= tail-source source-id)
                    (= tail-symbol base-symbol-id)
                    (match tail
                      [(Nil) true]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    (lower.lower-active-global-name-cache-set! lower-state previous-global)
    ok))

(test
  compiler-lower-name-env-dense-snapshots
  (test.assert-true
    (compiler-lower-name-env-dense-snapshots-ok?)
    "dense lower-name snapshots preserve overlays, append order, and names"))

(define (compiler-lower-alias-overlay-map-reuse-ok?) : bool
  (let
    [state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [scratch : arena.Arena (arena.make)]
    [index : i64 0]
    ;; Grow while entry scratch is active, then retire it. The state and
    ;; reused table must still be valid for the next batch entry.
    (in-arena
      scratch
      (while (< index 128)
        (lower.lower-alias-overlay-record! state index (+ index 1000))
        (set! index (+ index 1))))
    (unsafe
      (arena.tl_arena_destroy (arena.raw-handle scratch)))
    (let
      [before : lower_i64_i64_map.Map
        (lower.compiler-lower-state-read
          state
          lower_i64_i64_map.Map
          lower.alias-overlay-ids)]
      [capacity : i64 (lower_i64_i64_map.capacity (& before))]
      [storage : i64
        (cast
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data before.slots) : (Ptr i64))))
          : i64)]
      (lower.lower-alias-overlay-reset! state)
      (lower.lower-alias-overlay-seed-from-env! state Nil)
      (let
        [after : lower_i64_i64_map.Map
          (lower.compiler-lower-state-read
            state
            lower_i64_i64_map.Map
            lower.alias-overlay-ids)]
        [empty : bool
          (and
            (= (lower_i64_i64_map.capacity (& after)) capacity)
            (=
              (cast
                (unsafe
                  (ptr->int
                    (ptr-cast (__tl_array-data after.slots) : (Ptr i64))))
                : i64)
              storage)
            (= (lower_i64_i64_map.len (& after)) 0)
            (= (lower.lower-alias-overlay-logical-id-or state 31 -1) -1))]
        (lower.lower-alias-overlay-record! state 31 2031)
        (and
          empty
          (= (lower.lower-alias-overlay-logical-id-or state 31 -1) 2031))))))

(test
  compiler-lower-alias-overlay-map-reuse
  (test.assert-true
    (compiler-lower-alias-overlay-map-reuse-ok?)
    "alias overlay reset and seed reuse storage, clear old entries, and accept new ones"))

(define (compiler-lower-alias-overlay-negative-id-scan-ok?) : bool
  (let
    [state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [source-id : i64
      (ci.intern-generated-canonical-name "alias-overlay-positive-source")]
    [symbol-id : i64
      (ci.intern-generated-canonical-name "alias-overlay-positive-symbol")]
    [names : lower.LowerNameEnv
      (lower.lower-name-env-bind-logical-symbol-id
        source-id
        source-id
        symbol-id
        (lower.lower-name-env-bind-logical-symbol-id -1 -1 symbol-id Nil))]
    (lower.lower-alias-overlay-seed-from-env!
      state
      (lower.lower-global-shared-view names))
    (let
      [degraded : bool
        (not
          (lower.compiler-lower-state-read state bool lower.alias-overlay-valid))]
      [positive : lower.LowerNameEnv
        (lower.lower-name-env-add-import-alias-binding-symbol-id
          state
          (lower.lower-global-shared-view names)
          ""
          ""
          source-id
          ""
          source-id
          symbol-id)]
      [negative : lower.LowerNameEnv
        (lower.lower-name-env-add-import-alias-binding-symbol-id
          state
          names
          ""
          ""
          -1
          ""
          -1
          symbol-id)]
      (and
        degraded
        (= (lower.lower-name-env-count positive) 2)
        (= (lower.lower-name-env-count negative) 3)
        (=
          (lower.lower-alias-overlay-logical-id-or state source-id -1)
          source-id)))))

(test
  compiler-lower-alias-overlay-negative-id-scan
  (test.assert-true
    (compiler-lower-alias-overlay-negative-id-scan-ok?)
    "negative source id degrades to exact scan while interned duplicate still resolves"))

(define (compiler-lower-name-cache-capacity-ok?) : bool
  (let
    [count : i64 0]
    (while (<= count 256)
      (let
        [ids : lower_i64_i64_map.Map
          (lower_i64_i64_map.with-capacity
            (lower.lower-name-cache-capacity count))]
        [initial-capacity : i64 (lower_i64_i64_map.capacity (& ids))]
        [key : i64 0]
        (while (< key count)
          (lower_i64_i64_map.insert-ref! (&mut ids) key key)
          (set! key (+ key 1)))
        (when
          (not (= (lower_i64_i64_map.capacity (& ids)) initial-capacity))
          (return false))
        (set! count (+ count 1))))
    true))

(test
  compiler-lower-name-cache-capacity
  (test.assert-true
    (compiler-lower-name-cache-capacity-ok?)
    "name cache capacity admits every counted entry without a grow"))

;; The id-keyed compat prescan walker must agree with the two string-keyed
;; walks it replaces on every env-key family the prescan can meet: pool ids,
;; hygiene-local ids (post-splice trees), structural-local ids, and
;; composite keys, including bound-name shadowing.
(define (compiler-lower-compat-prescan-id-parity?
  [session : cis.InternStructuralSessionHandle]
  [expr-bases : i64]
  [tree : ast.AstExpr]
  [when-id : i64]
  [unless-id : i64]) : bool
  (=
    (tc_core.tc-expr-uses-free-source-id?
      session
      expr-bases
      (ast.ast-global-shared-view tree)
      when-id
      unless-id
      Nil)
    (or
      (tc_core.tc-expr-uses-free-name?
        expr-bases
        (ast.ast-global-shared-view tree)
        "when"
        Nil)
      (tc_core.tc-expr-uses-free-name? expr-bases tree "unless" Nil))))

(define (compiler-lower-compat-prescan-test-let
  [binder-id : i64]
  [init-id : i64]
  [body-id : i64]) : ast.AstExpr
  (let
    [bindings : ast.AstLetBindingList
      (ast.ast-let-binding-list-with-capacity 1)]
    (set!
      (array-ref bindings.slots 0)
      (ast.AstLetBinding.Binding binder-id (No) init-id))
    (set! bindings.len 1)
    (Let (box (ast.AstLet.Let bindings body-id)))))

(test
  compiler-lower-compat-prescan-id-parity
  (test.assert-true
    (let
      [pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 4 1)]
      [expr-bases : i64 (ast.ast-node-pool-context-expr-segment-bases pools)]
      [when-id : i64 (ci.intern "when")]
      [unless-id : i64 (ci.intern "unless")]
      [x-id : i64 (ci.intern "x")]
      [intern-state : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      ;; Local ids never read the expanding context's symbols, so the hygiene
      ;; context carries no shared block.
      [hygiene-ctx : tc_core.MacroHygieneContext
        (tc_core.MacroHygieneContext
          (ci.intern "test-macro")
          (ci.intern "test-module")
          1360
          0)]
      [hyg-when-id : i64
        (tc_core.macro-hygiene-local-id session hygiene-ctx 1 when-id)]
      [hyg-x-id : i64
        (tc_core.macro-hygiene-local-id session hygiene-ctx 1 x-id)]
      [struct-when-id : i64
        (cis.intern-fresh-local-identity-raw
          (cis.intern-structural-session-fresh-local-identity session 1 when-id))]
      [composite-id : i64
        (tc_core.tc-module-name-id-by-id (ci.intern "stdlib.io") when-id)]
      [when-var : i64 (ast.ast-node-pool-context-expr-push pools (Var when-id))]
      [hyg-when-var : i64
        (ast.ast-node-pool-context-expr-push pools (Var hyg-when-id))]
      [x-var : i64 (ast.ast-node-pool-context-expr-push pools (Var x-id))]
      (and
        (compiler-lower-compat-prescan-id-parity?
          session
          expr-bases
          (Var when-id)
          when-id
          unless-id)
        (compiler-lower-compat-prescan-id-parity?
          session
          expr-bases
          (Var x-id)
          when-id
          unless-id)
        (tc_core.tc-expr-uses-free-source-id?
          session
          expr-bases
          (Var hyg-when-id)
          when-id
          unless-id
          Nil)
        (not
          (tc_core.tc-expr-uses-free-source-id?
            session
            expr-bases
            (Var hyg-x-id)
            when-id
            unless-id
            Nil))
        (compiler-lower-compat-prescan-id-parity?
          session
          expr-bases
          (Var struct-when-id)
          when-id
          unless-id)
        (compiler-lower-compat-prescan-id-parity?
          session
          expr-bases
          (Var composite-id)
          when-id
          unless-id)
        (compiler-lower-compat-prescan-id-parity?
          session
          expr-bases
          (Var unless-id)
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
          (tc_core.tc-expr-uses-free-source-id?
            session
            expr-bases
            (compiler-lower-compat-prescan-test-let when-id x-var hyg-when-var)
            when-id
            unless-id
            Nil))
        ;; A hygiene binder whose source name is `when` shadows the hygiene
        ;; use (the string walker cannot see this shape: intern-str traps on
        ;; out-of-pool ids, so check the id walker directly).
        (not
          (tc_core.tc-expr-uses-free-source-id?
            session
            expr-bases
            (compiler-lower-compat-prescan-test-let
              hyg-when-id
              x-var
              hyg-when-var)
            when-id
            unless-id
            Nil))))
    "id-keyed compat prescan matches the string-keyed walks incl. hygiene ids"))

(test
  compiler-lower-macro-structural-growth
  (test.assert-true
    (let
      [intern-state : ci.InternCompatState (ci.intern-compat-state-new)]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-state))]
      [definition : cis.InternMacroDefinitionIdentity
        (cis.intern-structural-session-macro-definition-identity session 1 2)]
      [index : i64 0]
      [last : i64 -1]
      (while (< index 600)
        (set!
          last
          (cis.intern-macro-local-identity-raw
            (cis.intern-structural-session-macro-local-identity
              session
              definition
              index
              3)))
        (set! index (+ index 1)))
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
        (= (ci.intern-compat-state-structural-count intern-state) 601)))
    "macro structural records grow beyond the first record slab"))

(define (compiler-lower-private-record-missing?
  [record : cis.InternMaybeLowerPrivateRecord]) : bool
  (match record
    [(No) true]
    [_ false]))

(define (compiler-lower-private-identity-raw
  [session : cis.InternStructuralSessionHandle]
  [record : cis.InternLowerPrivateRecord]) : i64
  (cis.intern-lower-private-identity-raw
    (cis.intern-structural-session-lower-private-identity session record)))

(test
  compiler-lower-private-structural-identities
  (test.assert-true
    (let
      [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [session-a : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-a))]
      [session-b : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names
          (ci.intern-source-name-session-handle-from-state intern-b))]
      [identities : (__tl_dyn-array i64) (__tl_make-array i64 20)]
      [ok : bool true]
      (set!
        (array-ref identities 0)
        (compiler-lower-private-identity-raw session-a SretParameter))
      (set!
        (array-ref identities 1)
        (compiler-lower-private-identity-raw session-a CleanupStack))
      (set!
        (array-ref identities 2)
        (compiler-lower-private-identity-raw session-a RegionReset))
      (set!
        (array-ref identities 3)
        (compiler-lower-private-identity-raw session-a (CleanupHidden 1)))
      (set!
        (array-ref identities 4)
        (compiler-lower-private-identity-raw session-a (CleanupLiveness 1)))
      (set!
        (array-ref identities 5)
        (compiler-lower-private-identity-raw session-a (RegionHidden 1)))
      (set!
        (array-ref identities 6)
        (compiler-lower-private-identity-raw session-a (ArenaRestoreHidden 1)))
      (set!
        (array-ref identities 7)
        (compiler-lower-private-identity-raw session-a SpmdReduceAccumulator))
      (set!
        (array-ref identities 8)
        (compiler-lower-private-identity-raw session-a SpmdReduceEnd))
      (set!
        (array-ref identities 9)
        (compiler-lower-private-identity-raw session-a SpmdReduceValue))
      (set!
        (array-ref identities 10)
        (compiler-lower-private-identity-raw session-a SpmdReduceCurrent))
      (set!
        (array-ref identities 11)
        (compiler-lower-private-identity-raw session-a SpmdReduceStart))
      (set!
        (array-ref identities 12)
        (compiler-lower-private-identity-raw session-a SpmdReduceUniform))
      (set!
        (array-ref identities 13)
        (compiler-lower-private-identity-raw session-a SpmdScanAccumulator))
      (set!
        (array-ref identities 14)
        (compiler-lower-private-identity-raw session-a SpmdScanEnd))
      (set!
        (array-ref identities 15)
        (compiler-lower-private-identity-raw session-a SpmdScanValue))
      (set!
        (array-ref identities 16)
        (compiler-lower-private-identity-raw session-a (WhileExit 1)))
      (set!
        (array-ref identities 17)
        (compiler-lower-private-identity-raw session-a (WhileHeader 1)))
      (set!
        (array-ref identities 18)
        (compiler-lower-private-identity-raw session-a (SpmdDomainBound 1)))
      (set!
        (array-ref identities 19)
        (compiler-lower-private-identity-raw session-a (SpmdDomainBound 3)))
      (let
        [left : i64 0]
        (while (< left 20)
          (let
            [right : i64 (+ left 1)]
            (while (< right 20)
              (when
                (= (array-ref identities left) (array-ref identities right))
                (set! ok false))
              (set! right (+ right 1)))
            (set! left (+ left 1)))))
      (let
        [high-owner : i64 (+ (ci.intern-capacity) 100)]
        [high-owner-a : i64
          (compiler-lower-private-identity-raw
            session-a
            (CleanupHidden high-owner))]
        [high-owner-a-again : i64
          (compiler-lower-private-identity-raw
            session-a
            (CleanupHidden high-owner))]
        [high-owner-b : i64
          (compiler-lower-private-identity-raw
            session-a
            (CleanupHidden (+ high-owner 1)))]
        [collision-a : i64
          (compiler-lower-private-identity-raw session-a (CleanupHidden 2048))]
        [collision-b : i64
          (compiler-lower-private-identity-raw session-a (CleanupHidden 2560))]
        [other-session-uniform : i64
          (compiler-lower-private-identity-raw session-b SpmdReduceUniform)]
        [former-collision-key : cis.InternStructuralKey
          (cis.intern-structural-session-key
            session-a
            (ci.intern-structural-kind-lower-private)
            0
            1
            0)]
        [former-collision-raw : i64
          (cis.intern-structural-key-raw former-collision-key)]
        [unknown-kind-key : cis.InternStructuralKey
          (cis.intern-structural-session-key session-a 255 0 0 0)]
        [unknown-kind-raw : i64
          (cis.intern-structural-key-raw unknown-kind-key)]
        [index : i64 0]
        (unless (= high-owner-a high-owner-a-again) (set! ok false))
        (when (= high-owner-a high-owner-b) (set! ok false))
        (when (= collision-a collision-b) (set! ok false))
        (when
          (= other-session-uniform (array-ref identities 12))
          (set! ok false))
        ;; This is the structural counterpart of the old kind-16/value-0
        ;; versus kind-0/value-1 collision. The malformed marker recipe is a
        ;; separate record and fails typed decoding.
        (when
          (= former-collision-raw (array-ref identities 12))
          (set! ok false))
        (unless
          (compiler-lower-private-record-missing?
            (cis.intern-structural-session-lower-private-record-for-raw
              session-a
              former-collision-raw))
          (set! ok false))
        (unless
          (compiler-lower-private-record-missing?
            (cis.intern-structural-session-lower-private-record-for-raw
              session-a
              unknown-kind-raw))
          (set! ok false))
        (unless
          (compiler-lower-private-record-missing?
            (cis.intern-structural-session-lower-private-record-for-raw
              session-b
              (array-ref identities 12)))
          (set! ok false))
        (match (cis.intern-structural-session-lower-private-record-for-raw
          session-a
          (array-ref identities 12))
          [(Some (SpmdReduceUniform)) unit]
          [_ (set! ok false)])
        (match (cis.intern-structural-session-lower-private-record-for-raw
          session-a
          high-owner-a)
          [(Some (CleanupHidden owner-id))
            (unless (= owner-id high-owner) (set! ok false))]
          [_ (set! ok false)])
        (match (cis.intern-structural-session-lower-private-record-for-raw
          session-a
          (array-ref identities 16))
          [(Some (WhileExit ordinal)) (unless (= ordinal 1) (set! ok false))]
          [_ (set! ok false)])
        (match (cis.intern-structural-session-lower-private-record-for-raw
          session-a
          (array-ref identities 19))
          [(Some (SpmdDomainBound ordinal))
            (unless (= ordinal 3) (set! ok false))]
          [_ (set! ok false)])
        (while (< index 700)
          (begin
            (compiler-lower-private-identity-raw
              session-a
              (CleanupHidden (+ 100000 index)))
            unit)
          (set! index (+ index 1)))
        (unless
          (=
            (compiler-lower-private-identity-raw
              session-a
              (CleanupHidden 100000))
            (compiler-lower-private-identity-raw
              session-a
              (CleanupHidden 100000)))
          (set! ok false))
        (unless
          (=
            (cis.intern-structural-session-kind-count
              session-a
              (ci.intern-structural-kind-lower-private))
            725)
          (set! ok false))
        (unless
          (= (ci.intern-compat-state-structural-count intern-a) 726)
          (set! ok false))
        (unless (= (ci.intern-structural-record-slot-bytes) 37) (set! ok false)))
      (let
        [reset-to-state : ci.InternCompatState (ci.intern-compat-state-new)]
        [reset-to-session : cis.InternStructuralSessionHandle
          (cis.intern-structural-session-handle-from-source-names
            (ci.intern-source-name-session-handle-from-state reset-to-state))]
        [reset-to-identity : i64
          (compiler-lower-private-identity-raw reset-to-session CleanupStack)]
        [mark : i64 (ci.intern-compat-state-pool-len reset-to-state)]
        (ci.intern-compat-state-reset-to! (&mut reset-to-state) mark)
        (unless
          (compiler-lower-private-record-missing?
            (cis.intern-structural-session-lower-private-record-for-raw
              reset-to-session
              reset-to-identity))
          (set! ok false)))
      (let
        [reset-state : ci.InternCompatState (ci.intern-compat-state-new)]
        [reset-session : cis.InternStructuralSessionHandle
          (cis.intern-structural-session-handle-from-source-names
            (ci.intern-source-name-session-handle-from-state reset-state))]
        [reset-identity : i64
          (compiler-lower-private-identity-raw reset-session RegionReset)]
        (ci.intern-compat-state-reset! (&mut reset-state))
        (unless
          (compiler-lower-private-record-missing?
            (cis.intern-structural-session-lower-private-record-for-raw
              reset-session
              reset-identity))
          (set! ok false)))
      (and
        ok
        (=
          (cis.intern-lower-private-identity-size)
          (comptime (size-of (type i64))))))
    "lower-private records are typed, canonical, session-owned, and collision-free"))

(test
  compiler-lower-private-structural-select-temporary
  (test.assert-true
    (compiler-lower-ok?
      "(define (f [xs : (__tl_dyn-array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))")
    "lower-private select temporaries stay outside renderable-name metadata"))

(test
  compiler-lower-standalone-cleanup-owner-refresh
  (test.assert-true
    (begin
      (cbi.compiler-builtin-initialize-for-parse!)
      (if (compiler-lower-cleanup-struct-shape-ok?)
        (begin
          (cbi.compiler-builtin-refresh!)
          true)
        false))
    "standalone cleanup lowering preserves post-reset intern/builtin ownership"))

(test
  compiler-lower-cleanup-owner-interleaving
  (test.assert-true
    (let
      [active-intern-before : ci.InternCompatState
        (ci.intern-compat-state-capture-active)]
      [active-pools-before : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [module-a : i64 (ci.intern-compat-state-intern (&mut intern-a) "owner-a")]
      [cleanup-a : i64
        (ci.intern-compat-state-intern (&mut intern-a) "cleanup-a")]
      [_module-b : i64
        (ci.intern-compat-state-intern (&mut intern-b) "decoy-b")]
      [_cleanup-b : i64
        (ci.intern-compat-state-intern (&mut intern-b) "cleanup-b")]
      [pools-a : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 8 1)]
      [pools-b : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 8 1)]
      [lower-a : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state
          (owned_view.compiler-owned-shared-view intern-a))]
      [generated-b-before : i64
        (ci.intern-compat-state-generated-count intern-b)]
      [expr-b-before : i64 (ast.ast-node-pool-context-expr-len pools-b)]
      [ok : bool false]
      (ci.intern-compat-state-install! intern-b)
      (ast.ast-node-pool-context-install! pools-b)
      (let
        [_active-generated-b : i64
          (ci.intern-compat-state-generated-name
            (&mut intern-b)
            "decoy-generated-b")]
        [generated-b-after : i64
          (ci.intern-compat-state-generated-count intern-b)]
        [param-a : i64 (lower.lower-struct-cleanup-param-id lower-a)]
        [param-again-a : i64 (lower.lower-struct-cleanup-param-id lower-a)]
        [payload-a : i64 (lower.lower-enum-cleanup-payload-id lower-a 0)]
        [payload-again-a : i64 (lower.lower-enum-cleanup-payload-id lower-a 0)]
        [qualified-a : i64
          (ci.intern-compat-state-generated-canonical-qualified-name
            (&mut intern-a)
            "owner-a/cleanup-a"
            module-a
            cleanup-a)]
        [_enum-call-a : i64
          (lower.lower-enum-cleanup-call-expr pools-a cleanup-a payload-a)]
        [_struct-call-a : i64
          (lower.lower-struct-cleanup-call-expr
            pools-a
            cleanup-a
            param-a
            cleanup-a)]
        [lower-a-interns : ci.InternCompatState
          (lower.compiler-lower-state-interns lower-a)]
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
            (= (ast.ast-node-pool-context-expr-len pools-a) 7)
            (= (ast.ast-node-pool-context-expr-len pools-b) expr-b-before))))
      (ci.intern-compat-state-install! active-intern-before)
      (ast.ast-node-pool-context-install! active-pools-before)
      (ast.ast-node-pool-context-destroy-storage! pools-a)
      (ast.ast-node-pool-context-destroy-storage! pools-b)
      (unsafe
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-a))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-b)))
      ok)
    "cleanup synthesis mutates only its explicit intern and AST-pool owners"))

(define (compiler-lower-comptime-error-test-builtins
  [intern-state : (& intern-state ci.InternCompatState)]
  [comptime-id : i64]
  [comptime-error-id : i64]
  [bare-id : i64]
  [stdlib-comptime-id : i64]
  [stdlib-error-id : i64]) : cbi.CompilerBuiltinIdsState
  (let
    [state : cbi.CompilerBuiltinIdsState (cbi.state-new)]
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
    state))

(test
  compiler-lower-comptime-error-cache-owner-isolation
  (test.assert-true
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
        (ci.intern-compat-state-intern
          (&mut intern-a)
          "comptime.comptime-error")]
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
        (ci.intern-compat-state-intern
          (&mut intern-b)
          "comptime.comptime-error")]
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
          intern-a
          a-comptime
          a-error
          a-bare
          a-stdlib-comptime
          a-stdlib-error)]
      [builtins-b : cbi.CompilerBuiltinIdsState
        (compiler-lower-comptime-error-test-builtins
          intern-b
          b-comptime
          b-error
          b-bare
          b-stdlib-comptime
          b-stdlib-error)]
      [builtins-decoy : cbi.CompilerBuiltinIdsState
        (compiler-lower-comptime-error-test-builtins
          intern-decoy
          decoy-id
          decoy-id
          decoy-id
          decoy-id
          decoy-id)]
      [lower-a : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state
          (owned_view.compiler-owned-shared-view intern-a))]
      [lower-b : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state
          (owned_view.compiler-owned-shared-view intern-b))]
      [initial-a : lower.CompilerLowerStateObservation
        (lower.compiler-lower-state-observe lower-a)]
      [ok : bool false]
      (ci.intern-compat-state-install! intern-decoy)
      (cbi.state-install! builtins-decoy)
      (lower.lower-comptime-error-ids-ensure! lower-a builtins-a)
      (lower.lower-comptime-error-ids-ensure! lower-b builtins-b)
      (let
        [b-before-reuse : lower.CompilerLowerStateObservation
          (lower.compiler-lower-state-observe lower-b)]
        [old-generation : i64 (ci.intern-compat-state-generation intern-a)]
        (lower.compiler-lower-state-reset! lower-a)
        (let
          [reset-ok? : bool (compiler-lower-state-reset? lower-a)]
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
              (ci.intern-compat-state-intern (&mut intern-a) "comptime-error")]
            [a-new-comptime : i64
              (ci.intern-compat-state-intern
                (&mut intern-a)
                "comptime.comptime-error")]
            [a-new-error : i64
              (ci.intern-compat-state-intern (&mut intern-a) "comptime.error")]
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
                intern-a
                a-new-comptime
                a-new-error
                a-new-bare
                a-new-stdlib-comptime
                a-new-stdlib-error)]
            (lower.lower-comptime-error-ids-ensure! lower-a builtins-a-reused)
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
                  (lower.compiler-lower-state-observation-eq?
                    initial-a
                    (lower.compiler-lower-state-observe lower-a)))
                (lower.lower-comptime-error-call-id? lower-a a-new-bare)
                (not (lower.lower-comptime-error-call-id? lower-a a-bare))
                (lower.lower-comptime-error-call-id? lower-b b-bare)
                (not (lower.lower-comptime-error-call-id? lower-b b-decoy))
                reset-ok?
                (not
                  (=
                    old-generation
                    (ci.intern-compat-state-generation intern-a)))
                (lower.compiler-lower-state-observation-eq?
                  b-before-reuse
                  (lower.compiler-lower-state-observe lower-b))
                (=
                  (ci.intern-active-table-id)
                  (ci.intern-compat-state-table-id intern-decoy))
                (=
                  (ci.intern-generation)
                  (ci.intern-compat-state-generation intern-decoy))
                (= (ci.intern-pool-len) 1)
                (cbi.compiler-builtin-table-current?)
                (= cbi.compiler-builtin-id-fix-comptime_error decoy-id))))))
      (ci.intern-compat-state-install! active-intern-before)
      (cbi.state-install! active-builtins-before)
      (unsafe
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-a))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-b))
        (arena.tl_arena_destroy
          (ci.intern-compat-state-persistent-arena intern-decoy)))
      ok)
    "comptime-error caches use explicit intern/builtin owners and reset stamps"))

(define (compiler-lower-boxed-helper-lists-ok?) : bool
  (let
    [source-a-id : i64 (ci.intern-generated-canonical-name "source-a")]
    [source-b-id : i64 (ci.intern-generated-canonical-name "source-b")]
    [names : lower.LowerNameEnv
      (lower-name-env-bind-logical-id
        source-a-id
        "logical-a"
        source-a-id
        (lower-name-env-bind-logical-id source-b-id "logical-b" source-b-id Nil))]
    [captures : lower.LowerCaptureList
      (lower.lower-capture-list-add-front
        (lower.lower-capture-list-add-front
          (lower.lower-capture-list-empty)
          (Capture 102 2 (Bool) 8))
        (Capture 101 1 (I64) 0))]
    [cleanups : lower.LowerCleanupStack
      (lower.lower-cleanup-stack-push
        (lower.lower-cleanup-stack-push
          (lower.lower-cleanup-stack-empty)
          201
          301)
        202
        302)]
    [slots : lower.LowerCAbiSlotList
      (lower.lower-c-abi-slot-list-pair (Slot (I64) 0) (Slot (F64) 8))]
    (and
      (= (lower.lower-name-env-count names) 2)
      (string.eq
        (lower-name-env-resolve-with-id names "source-b" source-b-id)
        "logical-b")
      (= (lower-capture-list-count captures) 2)
      (lower.lower-capture-list-contains-name? captures 102)
      (lower-capture-list-storage-entry? captures 0 102 2 8)
      (lower-capture-list-storage-entry? captures 1 101 1 0)
      (= (lower-cleanup-stack-count cleanups) 2)
      (lower-cleanup-stack-entry? cleanups 0 201 301)
      (lower-cleanup-stack-entry? cleanups 1 202 302)
      (= (lower.lower-c-abi-slot-list-count slots) 2)
      (match (lower.lower-c-abi-slot-list-ref slots 0)
        [(Slot ty offset) (and (= offset 0) (tc_core.tc-type-eq ty (I64)))])
      (match (lower.lower-c-abi-slot-list-ref slots 1)
        [(Slot ty offset) (and (= offset 8) (tc_core.tc-type-eq ty (F64)))]))))

(define (compiler-lower-name-cache-intern-id-dotted-ok?) : bool
  (let
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [alias-id : i64 cbi.compiler-builtin-id-fix-alias]
    [value-id : i64 cbi.compiler-builtin-id-fix-value]
    [source-id : i64
      (csym.compiler-symbol-module-key-id-by-id alias-id value-id)]
    [logical : String "logical-value"]
    [split-source : String
      (csym.compiler-symbol-module-key
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
      (csym.compiler-symbol-module-key-id-by-id split-alias-id split-value-id)]
    [split-logical : String "split-logical-value"]
    [names : lower.LowerNameEnv
      (lower-name-env-bind-logical-id
        split-source-id
        (owned_view.compiler-owned-shared-view split-logical)
        split-source-id
        (lower-name-env-bind-logical-id
          source-id
          (owned_view.compiler-owned-shared-view logical)
          source-id
          Nil))]
    [cache : lower.LowerNameCache
      (lower.lower-name-cache-from-env lower-state names)]
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
      (match (lower.lower-name-cache-resolve-id-display
        (owned_view.compiler-owned-shared-view cache)
        source-id)
        [(Some resolved) (string.eq resolved logical)]
        [(No) false])
      (match (lower.lower-name-cache-resolve-id-display cache split-source-id)
        [(Some resolved) (string.eq resolved split-logical)]
        [(No) false]))))

(define (compiler-lower-function-memo-test-write!
  [function-state : lower.CompilerLowerFunctionState]
  [slot : i64]
  [key : i64]
  [ty : ast.AstType]
  [outcome : lower.LowerVariantArmResolution]) : unit
  (let
    [storage : lower.CompilerLowerFunctionMemoStorage
      (lower.compiler-lower-function-memo-storage
        (lower.compiler-lower-function-state-owner function-state))]
    (set!
      (array-ref storage.rtf-generations slot)
      (lower.compiler-lower-function-state-rtf-generation function-state))
    (set! (array-ref storage.rtf-ids slot) key)
    (set! (array-ref storage.rtf-types slot) ty)
    (set!
      (array-ref storage.variant-stamps slot)
      (lower.compiler-lower-function-state-variant-generation function-state))
    (set! (array-ref storage.variant-keys slot) key)
    (set! (array-ref storage.variant-scrutinee-types slot) ty)
    (set! (array-ref storage.variant-outcomes slot) outcome)))

(define (compiler-lower-function-memo-test-hit?
  [function-state : lower.CompilerLowerFunctionState]
  [slot : i64]
  [key : i64]
  [ty : ast.AstType]
  [outcome-name : String]) : bool
  (let
    [storage : lower.CompilerLowerFunctionMemoStorage
      (lower.compiler-lower-function-memo-storage
        (lower.compiler-lower-function-state-owner function-state))]
    (and
      (=
        (array-ref storage.rtf-generations slot)
        (lower.compiler-lower-function-state-rtf-generation function-state))
      (= (array-ref storage.rtf-ids slot) key)
      (ast.ast-type-eq?
        (owned_view.compiler-owned-array-element-shared-view
          storage.rtf-types
          slot)
        (owned_view.compiler-owned-shared-view ty))
      (=
        (array-ref storage.variant-stamps slot)
        (lower.compiler-lower-function-state-variant-generation function-state))
      (= (array-ref storage.variant-keys slot) key)
      (ast.ast-type-eq?
        (owned_view.compiler-owned-array-element-shared-view
          storage.variant-scrutinee-types
          slot)
        ty)
      (match (owned_view.compiler-owned-array-element-shared-view
        storage.variant-outcomes
        slot)
        [(Missing name) (string.eq name outcome-name)]
        [_ false]))))

;; A and B deliberately reuse the same numeric memo slot/key/generation and
;; fresh-local source ID. The backing arrays are owner-private, while sibling
;; functions in A share backing but use distinct generations so interleaving is
;; an eviction/miss rather than a stale read.
(define (compiler-lower-spmd-function-state-isolation-ok?) : bool
  (let
    [owner-a : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [owner-b : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [idle-a : i64 (compiler-lower-state-function-memo-retained-bytes owner-a)]
    [idle-b : i64 (compiler-lower-state-function-memo-retained-bytes owner-b)]
    (lower.compiler-lower-state-set-spmd-package! owner-a "package-a")
    (lower.compiler-lower-state-set-spmd-package! owner-b "package-b")
    (let
      [function-a : lower.CompilerLowerFunctionState
        (lower.compiler-lower-function-state-new owner-a)]
      [retained-a : i64
        (compiler-lower-state-function-memo-retained-bytes owner-a)]
      [still-idle-b : i64
        (compiler-lower-state-function-memo-retained-bytes owner-b)]
      [function-a-nested : lower.CompilerLowerFunctionState
        (lower.compiler-lower-function-state-new owner-a)]
      [function-b : lower.CompilerLowerFunctionState
        (lower.compiler-lower-function-state-new owner-b)]
      [retained-b : i64
        (compiler-lower-state-function-memo-retained-bytes owner-b)]
      [source-id : i64
        (ci.intern-generated-name "lower-function-state-isolation-temp")]
      [symbol : i64 81173]
      [interns-a : ci.InternCompatState
        (lower.compiler-lower-state-interns owner-a)]
      [interns-b : ci.InternCompatState
        (lower.compiler-lower-state-interns owner-b)]
      [identity-a : i64
        (ci.intern-compat-state-intern (&mut interns-a) "identity-a")]
      [identity-b : i64
        (ci.intern-compat-state-intern (&mut interns-b) "identity-b")]
      [registered-a : lower.LowerSpmdPackageSymbolRegistration
        (lower.lower-spmd-package-symbol-register
          owner-a
          symbol
          symbol
          identity-a)]
      [registered-b : lower.LowerSpmdPackageSymbolRegistration
        (lower.lower-spmd-package-symbol-register
          owner-b
          symbol
          symbol
          identity-b)]
      [repeated-b : lower.LowerSpmdPackageSymbolRegistration
        (lower.lower-spmd-package-symbol-register
          owner-b
          symbol
          symbol
          identity-b)]
      (lower.compiler-lower-function-state-inline-helper-stack-set!
        function-a
        (lower.lower-id-set-insert (lower.lower-id-set-empty) 4242))
      (lower.compiler-lower-function-state-recursion-detected-set!
        function-a
        true)
      (lower.compiler-lower-function-state-scalar-call-context-set!
        function-a
        (Some "lane-a"))
      (let
        [temp-a-0 : i64
          (lower.compiler-lower-function-state-fresh-local-id!
            function-a
            source-id)]
        [temp-a-1 : i64
          (lower.compiler-lower-function-state-fresh-local-id!
            function-a
            source-id)]
        [temp-a-nested-0 : i64
          (lower.compiler-lower-function-state-fresh-local-id!
            function-a-nested
            source-id)]
        [temp-b-0 : i64
          (lower.compiler-lower-function-state-fresh-local-id!
            function-b
            source-id)]
        [slot : i64 17]
        [key : i64 17017]
        (compiler-lower-function-memo-test-write!
          function-a
          slot
          key
          (I64)
          (Missing "memo-a"))
        (compiler-lower-function-memo-test-write!
          function-b
          slot
          key
          (Bool)
          (Missing "memo-b"))
        (let
          [owners-hit : bool
            (and
              (compiler-lower-function-memo-test-hit?
                function-a
                slot
                key
                (I64)
                "memo-a")
              (compiler-lower-function-memo-test-hit?
                function-b
                slot
                key
                (Bool)
                "memo-b"))]
          (compiler-lower-function-memo-test-write!
            function-a-nested
            slot
            key
            (Bool)
            (Missing "memo-a-nested"))
          (let
            [nested-hit : bool
              (compiler-lower-function-memo-test-hit?
                function-a-nested
                slot
                key
                (Bool)
                "memo-a-nested")]
            [outer-evicted : bool
              (not
                (compiler-lower-function-memo-test-hit?
                  function-a
                  slot
                  key
                  (I64)
                  "memo-a"))]
            [b-still-hit : bool
              (compiler-lower-function-memo-test-hit?
                function-b
                slot
                key
                (Bool)
                "memo-b")]
            (lower.compiler-lower-state-reset! owner-a)
            (let
              [stack-a : lower.LowerIdSet
                (lower.compiler-lower-function-state-inline-helper-stack
                  function-a)]
              [stack-b : lower.LowerIdSet
                (lower.compiler-lower-function-state-inline-helper-stack
                  function-b)]
              [stack-a-nested : lower.LowerIdSet
                (lower.compiler-lower-function-state-inline-helper-stack
                  function-a-nested)]
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
                  (lower.compiler-lower-function-state-rtf-generation
                    function-a)
                  (lower.compiler-lower-function-state-rtf-generation
                    function-b))
                (not
                  (=
                    (lower.compiler-lower-function-state-rtf-generation
                      function-a)
                    (lower.compiler-lower-function-state-rtf-generation
                      function-a-nested)))
                (lower.lower-id-set-contains? stack-a 4242)
                (not (lower.lower-id-set-contains? stack-a-nested 4242))
                (not (lower.lower-id-set-contains? stack-b 4242))
                (lower.compiler-lower-function-state-recursion-detected?
                  function-a)
                (not
                  (lower.compiler-lower-function-state-recursion-detected?
                    function-a-nested))
                (not
                  (lower.compiler-lower-function-state-recursion-detected?
                    function-b))
                (match (lower.compiler-lower-function-state-scalar-call-context
                  function-a)
                  [(Some lane) (string.eq lane "lane-a")]
                  [_ false])
                (match (lower.compiler-lower-function-state-scalar-call-context
                  function-b)
                  [(No) true]
                  [_ false])
                (= temp-a-0 temp-a-nested-0)
                (= temp-a-0 temp-b-0)
                (not (= temp-a-0 temp-a-1))
                owners-hit
                nested-hit
                outer-evicted
                b-still-hit
                (match registered-a
                  [(New) true]
                  [_ false])
                (match registered-b
                  [(New) true]
                  [_ false])
                (match repeated-b
                  [(Existing) true]
                  [_ false])
                (string.eq
                  (lower.compiler-lower-state-spmd-package-name owner-a)
                  "")
                (string.eq
                  (lower.compiler-lower-state-spmd-package-name owner-b)
                  "package-b")
                (match (lower.lower-spmd-package-symbol-register
                  owner-b
                  symbol
                  symbol
                  identity-b)
                  [(Existing) true]
                  [_ false])
                (compiler-lower-state-reset? owner-a)))))))))

(define (compiler-lower-type-cache-i64-keys-ok?) : bool
  (let
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [module : String "type_cache_mod_3939"]
    [name : String "TypeCacheThing3939"]
    [module-id : i64
      (ci.intern-generated-name (owned_view.compiler-owned-shared-view module))]
    [name-id : i64
      (ci.intern-generated-name (owned_view.compiler-owned-shared-view name))]
    [qualified-name : String
      (csym.compiler-symbol-module-key
        (owned_view.compiler-owned-shared-view module)
        name)]
    [qualified-id : i64
      (csym.compiler-symbol-module-key-id-by-id module-id name-id)]
    [fallback-name : String "TypeCacheFallback3939"]
    [fallback-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view fallback-name))]
    [fallback-primary : String
      (csym.compiler-symbol-module-key
        module
        (owned_view.compiler-owned-shared-view fallback-name))]
    [fallback-primary-missing-before : bool
      (match (ci.intern-lookup
        (owned_view.compiler-owned-shared-view fallback-primary))
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    [env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-id (tc_core.tc-empty-env) qualified-id (I64))
        fallback-id
        (Bool))]
    [cache : lower.LowerTypeCache
      (lower.lower-type-cache-from-env lower-state env)]
    [missing : String "TypeCacheMissing3939"]
    [missing-id : i64 (+ (ci.intern-capacity) 3939)]
    [missing-before : bool
      (match (ci.intern-lookup (owned_view.compiler-owned-shared-view missing))
        [(InternLookupFound _) false]
        [(InternLookupMissing) true])]
    (and
      (string.eq
        (tc_core.tc-env-key-display
          (lower.compiler-lower-state-structural-session lower-state)
          qualified-id)
        qualified-name)
      fallback-primary-missing-before
      missing-before
      (match (lower.lower-type-cache-lookup-id
        (owned_view.compiler-owned-shared-view cache)
        qualified-id
        qualified-name)
        [(Ok ty) (tc_core.tc-type-eq ty (I64))]
        [(Err _) false])
      (match (lower.lower-type-cache-lookup-id
        (owned_view.compiler-owned-shared-view cache)
        fallback-id
        fallback-name)
        [(Ok ty) (tc_core.tc-type-eq ty (Bool))]
        [(Err _) false])
      (match (lower.lower-type-cache-lookup-id
        cache
        missing-id
        (owned_view.compiler-owned-shared-view missing))
        [(Ok _) false]
        [(Err _) true])
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
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-scalar-shift-count-source)))
    [(Some functions)
      (and
        (=
          (lower-test-function-binop-op-count functions "shift-u8" (Shl (U8)))
          1)
        (=
          (lower-test-function-binop-op-count functions "shift-u64" (Shr (U64)))
          1)
        (=
          (lower-test-function-binop-op-count functions "shift-u8" (Shl (U64)))
          0)
        (=
          (lower-test-function-binop-op-count functions "shift-u64" (Shr (U8)))
          0))]
    [_ false]))

(test
  compiler-lower-scalar-shift-count-types
  (test.assert-true
    (compiler-lower-scalar-shift-count-types-ok?)
    "scalar lowering preserves independent u8/u64 shift count payloads"))

;; Structural borrowed-slice references use two integer words end-to-end while
;; ordinary references, including references to raw-pointer values, retain
;; their one-word pointer representation. A borrowed Slice of shared references
;; is supported like a borrowed fixed array of them. A dynamic array of
;; supported references lowers by value like a fixed array; borrowing one stays
;; unsupported. Build the types directly in a private pool so this test does
;; not depend on public Slice syntax.
(define (compiler-lower-slice-reference-layout-ok?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 16)]
    [elem-id : i64 (ast.ast-node-pool-context-type-push pools (I64))]
    [slice-id : i64 (ast.ast-node-pool-context-type-push pools (Slice elem-id))]
    [region-slice-id : i64
      (ast.ast-node-pool-context-type-push pools (Region 7 slice-id))]
    [nested-ref-element-id : i64
      (ast.ast-node-pool-context-type-push pools (Ref 1 elem-id))]
    [nested-slice-id : i64
      (ast.ast-node-pool-context-type-push pools (Slice nested-ref-element-id))]
    [ordinary-id : i64 (ast.ast-node-pool-context-type-push pools (I64))]
    [pointer-id : i64 (ast.ast-node-pool-context-type-push pools (Ptr elem-id))]
    [mutable-pointer-id : i64
      (ast.ast-node-pool-context-type-push pools (MutPtr elem-id))]
    [ref : ast.AstType (Ref 1 slice-id)]
    [mut-ref : ast.AstType (MutRef 1 region-slice-id)]
    [ordinary-ref : ast.AstType (Ref 1 ordinary-id)]
    [pointer-ref : ast.AstType (Ref 1 pointer-id)]
    [mutable-pointer-ref : ast.AstType (Ref 1 mutable-pointer-id)]
    [nested-ref : ast.AstType (Ref 1 nested-slice-id)]
    [nested-ref-id : i64
      (ast.ast-node-pool-context-type-push pools (Ref 1 nested-slice-id))]
    [ref-dyn-array-id : i64
      (ast.ast-node-pool-context-type-push
        pools
        (DynArray nested-ref-element-id))]
    [ref-dyn-array : ast.AstType (DynArray nested-ref-element-id)]
    [nested-ref-dyn-array : ast.AstType (DynArray nested-ref-id)]
    [borrowed-ref-dyn-array : ast.AstType (Ref 1 ref-dyn-array-id)]
    [bare-slice : ast.AstType (Slice elem-id)]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        0
        pools)]
    [layouts : ctfe.CtfeLayoutInfoList (ctfe.ctfe-layout-info-list-empty)]
    [ok : bool false]
    (ast.ast-node-pool-context-install! pools)
    (set!
      ok
      (and
        (= (lower.lower-type-size ctx ref) 16)
        (= (lower.lower-type-align ctx ref) 8)
        (lower.lower-type-register-resident?
          ctx
          (owned_view.compiler-owned-shared-view ref))
        (=
          (lower.lower-type-register-words
            ctx
            (owned_view.compiler-owned-shared-view ref))
          2)
        (tc_core.tc-type-eq (lower.lower-register-word-type ctx ref 0) (U64))
        (tc_core.tc-type-eq (lower.lower-register-word-type ctx ref 1) (I64))
        (= (lower.lower-type-size ctx mut-ref) 16)
        (= (lower.lower-type-align ctx mut-ref) 8)
        (lower.lower-type-register-resident?
          ctx
          (owned_view.compiler-owned-shared-view mut-ref))
        (=
          (lower.lower-type-register-words
            ctx
            (owned_view.compiler-owned-shared-view mut-ref))
          2)
        (= (lower.lower-type-size ctx ordinary-ref) 8)
        (not
          (lower.lower-type-register-resident?
            ctx
            (owned_view.compiler-owned-shared-view ordinary-ref)))
        (=
          (lower.lower-type-register-words
            ctx
            (owned_view.compiler-owned-shared-view ordinary-ref))
          0)
        (= (lower.lower-type-size ctx pointer-ref) 8)
        (not
          (lower.lower-type-register-resident?
            ctx
            (owned_view.compiler-owned-shared-view pointer-ref)))
        (lower.lower-supported-reference-type? ctx pointer-ref)
        (lower.lower-supported-reference-type? ctx mutable-pointer-ref)
        (= (lower.lower-type-size ctx bare-slice) 0)
        (not
          (lower.lower-type-register-resident?
            ctx
            (owned_view.compiler-owned-shared-view bare-slice)))
        (lower.lower-supported-reference-type?
          ctx
          (owned_view.compiler-owned-shared-view ref))
        (lower.lower-supported-reference-type?
          ctx
          (owned_view.compiler-owned-shared-view mut-ref))
        (not
          (lower.lower-supported-reference-type?
            ctx
            (owned_view.compiler-owned-shared-view bare-slice)))
        ;; A borrowed Slice of shared references views an array's inline
        ;; one-word pointer elements (#8111).
        (lower.lower-supported-reference-type? ctx nested-ref)
        (lower.lower-supported-reference-type? ctx ref-dyn-array)
        ;; Its elements are two-word shared Slice views, like `(& str)`.
        (lower.lower-supported-reference-type? ctx nested-ref-dyn-array)
        (not (lower.lower-supported-reference-type? ctx borrowed-ref-dyn-array))
        (=
          (ctfe.ctfe-type-size-with-pools
            pools
            (owned_view.compiler-owned-shared-view layouts)
            (owned_view.compiler-owned-shared-view ref))
          16)
        (=
          (ctfe.ctfe-type-align-with-pools
            pools
            (owned_view.compiler-owned-shared-view layouts)
            mut-ref)
          8)
        (=
          (ctfe.ctfe-type-size-with-pools
            pools
            (owned_view.compiler-owned-shared-view layouts)
            ordinary-ref)
          8)
        (= (ctfe.ctfe-type-size-with-pools pools layouts bare-slice) -1)
        (match (tc_core.tc-inline-aggregate-type-layout ctx ref)
          [(Ok info)
            (and
              (= (tc_core.tc-layout-info-size info) 16)
              (= (tc_core.tc-layout-info-align info) 8))]
          [(Err _) false])))
    (ast.ast-node-pool-context-install! active-before)
    ok))

;; A BoundsCheck lowers to one unsigned `cmpq length, index`, so an operand that
;; is already a width-64 integer is handed to the check directly instead of
;; through a materialised `Cast ... : u64`. `get` therefore keeps exactly ONE
;; cast (the i64 gep-offset conversion); the length is loaded as i64 and used
;; as-is.
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
  [functions : (& functions ir.CompilerIrFunctionSeq)]) : bool
  (and
    (= (lower-test-count functions "get" (Bounds)) 1)
    (= (lower-test-count functions "get" (Cast)) 1)
    (= (lower-test-count functions "get-narrow" (Bounds)) 1)
    (= (lower-test-count functions "get-narrow" (Cast)) 2)
    (= (lower-test-count functions "plain-cast" (Bounds)) 0)
    (= (lower-test-count functions "plain-cast" (Cast)) 1)))

(define (compiler-lower-bounds-operand-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source (compiler-lower-bounds-operand-source)))
    [(Some functions) (compiler-lower-bounds-operand-counts-ok? functions)]
    [_ false]))

;; The pass-through is a fixed point: u64 is itself width-64, so re-applying the
;; operand rule to what the old cast used to produce emits nothing further, and
;; lowering the same source again reaches the identical shape.
(define (compiler-lower-bounds-operand-idempotent-ok?) : bool
  (and
    (lower.lower-bounds-operand-width-64? (U64))
    (compiler-lower-bounds-operand-shape-ok?)))

(define (compiler-lower-bounds-operand-width-predicate-ok?) : bool
  (let
    [ok : bool true]
    (if (lower.lower-bounds-operand-width-64? (I64))
      unit
      (set! ok false))
    (if (lower.lower-bounds-operand-width-64? (U64))
      unit
      (set! ok false))
    (if (lower.lower-bounds-operand-width-64? (I32))
      (set! ok false)
      unit)
    (if (lower.lower-bounds-operand-width-64? (U32))
      (set! ok false)
      unit)
    (if (lower.lower-bounds-operand-width-64? (U8))
      (set! ok false)
      unit)
    (if (lower.lower-bounds-operand-width-64? (F64))
      (set! ok false)
      unit)
    (if (lower.lower-bounds-operand-width-64? (Bool))
      (set! ok false)
      unit)
    ok))

;; Anonymous tuples use the same aligned, recursive layout walk as nominal
;; aggregates.  Exercise the layout and the packet-1 internal ABI classifier
;; directly with private pool types so extern C selection can be checked in the
;; same fixture.
(define (compiler-lower-internal-tuple-array-layout-ok?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 64)]
    [u8-id : i64 (ast.ast-node-pool-context-type-push pools (U8))]
    [u64-id : i64 (ast.ast-node-pool-context-type-push pools (U64))]
    [f32-id : i64 (ast.ast-node-pool-context-type-push pools (F32))]
    [f64-id : i64 (ast.ast-node-pool-context-type-push pools (F64))]
    [string-id : i64 (ast.ast-node-pool-context-type-push pools (String))]
    [slice-id : i64 (ast.ast-node-pool-context-type-push pools (Slice u8-id))]
    [empty-elements : ast.AstTypeList (ast.ast-type-list-new)]
    [u8-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id u8-id (ast.ast-type-list-new))]
    [u8-u64-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id
        u8-id
        (ast.ast-type-list-cons-id u64-id (ast.ast-type-list-new)))]
    [f32-f32-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id
        f32-id
        (ast.ast-type-list-cons-id f32-id (ast.ast-type-list-new)))]
    [u8-f64-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id
        u8-id
        (ast.ast-type-list-cons-id f64-id (ast.ast-type-list-new)))]
    [string-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id string-id (ast.ast-type-list-new))]
    [slice-ref-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id
        (ast.ast-node-pool-context-type-push pools (Ref 1 slice-id))
        (ast.ast-type-list-new))]
    [nested-id : i64
      (ast.ast-node-pool-context-type-push pools (Tuple (box u8-u64-elements)))]
    [array-u8-id : i64
      (ast.ast-node-pool-context-type-push pools (Array u8-id 3))]
    [nested-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id
        nested-id
        (ast.ast-type-list-cons-id u8-id (ast.ast-type-list-new)))]
    [tuple-array-elements : ast.AstTypeList
      (ast.ast-type-list-cons-id
        array-u8-id
        (ast.ast-type-list-cons-id u64-id (ast.ast-type-list-new)))]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        0
        pools)]
    [empty : ast.AstType (Tuple (box empty-elements))]
    [u8-tuple : ast.AstType (Tuple (box u8-elements))]
    [u8-u64 : ast.AstType (Tuple (box u8-u64-elements))]
    [f32-f32 : ast.AstType (Tuple (box f32-f32-elements))]
    [u8-f64 : ast.AstType (Tuple (box u8-f64-elements))]
    [nested : ast.AstType (Tuple (box nested-elements))]
    [tuple-array : ast.AstType (Tuple (box tuple-array-elements))]
    [tuple-string : ast.AstType (Tuple (box string-elements))]
    [array-string : ast.AstType (Array string-id 2)]
    [slice-ref-tuple : ast.AstType (Tuple (box slice-ref-elements))]
    [array-u8 : ast.AstType (Array u8-id 3)]
    [array-nested : ast.AstType (Array nested-id 2)]
    [ok : bool false]
    (ast.ast-node-pool-context-install! pools)
    (set!
      ok
      (and
        (= (lower.lower-type-size ctx empty) 0)
        (= (lower.lower-type-align ctx empty) 1)
        (= (lower.lower-type-size ctx u8-tuple) 1)
        (= (lower.lower-type-align ctx u8-tuple) 1)
        (= (lower.lower-type-size ctx u8-u64) 16)
        (= (lower.lower-type-align ctx u8-u64) 8)
        (= (lower.lower-type-size ctx f32-f32) 8)
        (= (lower.lower-type-align ctx f32-f32) 4)
        (= (lower.lower-type-size ctx nested) 24)
        (= (lower.lower-type-align ctx nested) 8)
        (= (lower.lower-type-size ctx array-u8) 3)
        (= (lower.lower-type-align ctx array-u8) 1)
        (= (lower.lower-type-size ctx array-nested) 32)
        (= (lower.lower-type-align ctx array-nested) 8)
        (= (lower.lower-type-size ctx tuple-array) 16)
        (= (lower.lower-type-align ctx tuple-array) 8)
        (= (lower.lower-type-size ctx tuple-string) 8)
        (= (lower.lower-type-size ctx array-string) 16)
        (= (lower.lower-type-size ctx slice-ref-tuple) 16)
        (lower.lower-type-inline-storage? ctx u8-u64)
        (not
          (lower.lower-type-register-resident?
            ctx
            (ast.ast-global-shared-view u8-u64)))
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          u8-tuple)
          [(Register slots size)
            (and
              (= size 1)
              (= (lower.lower-c-abi-slot-list-count slots) 1)
              (match (lower.lower-c-abi-slot-list-ref slots 0)
                [(Slot ty _) (tc_core.tc-type-eq ty (U8))]))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          f32-f32)
          [(Register slots size)
            (and
              (= size 8)
              (match (lower.lower-c-abi-slot-list-ref slots 0)
                [(Slot ty offset)
                  (and (= offset 0) (tc_core.tc-type-eq ty (F64)))]))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          u8-f64)
          [(Register slots size)
            (and
              (= size 16)
              (= (lower.lower-c-abi-slot-list-count slots) 2)
              (match (lower.lower-c-abi-slot-list-ref slots 0)
                [(Slot ty _) (tc_core.tc-type-eq ty (U64))])
              (match (lower.lower-c-abi-slot-list-ref slots 1)
                [(Slot ty _) (tc_core.tc-type-eq ty (F64))]))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          (ast.ast-global-shared-view tuple-string))
          [(Register slots size)
            (and
              (= size 8)
              (= (lower.lower-c-abi-slot-list-count slots) 1)
              (match (lower.lower-c-abi-slot-list-ref slots 0)
                [(Slot ty _) (tc_core.tc-type-eq ty (U64))]))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          array-string)
          [(Register slots size)
            (and
              (= size 16)
              (= (lower.lower-c-abi-slot-list-count slots) 2)
              (match (lower.lower-c-abi-slot-list-ref slots 0)
                [(Slot ty _) (tc_core.tc-type-eq ty (U64))])
              (match (lower.lower-c-abi-slot-list-ref slots 1)
                [(Slot ty _) (tc_core.tc-type-eq ty (U64))]))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          (ast.ast-global-shared-view array-nested))
          [(Memory size) (= size 32)]
          [_ false])
        (match (lower.lower-internal-return-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          array-nested)
          [(Sret size) (= size 32)]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.WindowsScalar)
          (ast.ast-global-shared-view array-u8))
          [(ByRef size) (= size 3)]
          [_ false])
        (match (lower.lower-internal-return-aggregate-class
          ctx
          (lower.CompilerLowerMode.WindowsScalar)
          (ast.ast-global-shared-view array-u8))
          [(Sret size) (= size 3)]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.WindowsScalar)
          tuple-string)
          [(Integer ty size) (and (= size 8) (tc_core.tc-type-eq ty (U64)))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          slice-ref-tuple)
          [(Register slots size)
            (and
              (= size 16)
              (= (lower.lower-c-abi-slot-list-count slots) 2)
              (match (lower.lower-c-abi-slot-list-ref slots 0)
                [(Slot ty _) (tc_core.tc-type-eq ty (U64))])
              (match (lower.lower-c-abi-slot-list-ref slots 1)
                [(Slot ty _) (tc_core.tc-type-eq ty (U64))]))]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.WindowsScalar)
          (ast.ast-global-shared-view u8-u64))
          [(ByRef size) (= size 16)]
          [_ false])
        (match (lower.lower-internal-return-aggregate-class
          ctx
          (lower.CompilerLowerMode.WindowsScalar)
          (ast.ast-global-shared-view u8-u64))
          [(Sret size) (= size 16)]
          [_ false])
        (match (lower.lower-internal-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          empty)
          [(Unsupported _) true]
          [_ false])
        ;; Extern C aggregate selection remains nominal-only.
        (match (lower.lower-c-abi-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          u8-u64)
          [(No) true]
          [_ false])
        (match (lower.lower-c-abi-return-aggregate-class
          ctx
          (lower.CompilerLowerMode.LinuxScalar)
          array-u8)
          [(No) true]
          [_ false])))
    (ast.ast-node-pool-context-install! active-before)
    ok))

(test
  compiler-lower-internal-tuple-array-layout
  (test.assert-true
    (compiler-lower-internal-tuple-array-layout-ok?)
    "recursive tuple/array layout and internal ABI classifier"))

(define (compiler-lower-internal-structural-call-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-internal-structural-call-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (lower-test-function-defined? functions "tuple-roundtrip")
        (lower-test-function-defined? functions "array-roundtrip")
        (= (lower-test-function-param-count functions "tuple-roundtrip") 1)
        (= (lower-test-function-param-count functions "array-roundtrip") 2)
        (=
          (lower-test-function-call-count functions "main" "tuple-roundtrip")
          1)
        (=
          (lower-test-function-call-count functions "main" "array-roundtrip")
          1)
        (>= (lower-test-count functions "tuple-roundtrip" (StorePtr)) 2)
        (>= (lower-test-count functions "array-roundtrip" (CopyBytes)) 1)
        ;; Tuple register-group transport is packed at the call boundary;
        ;; the array return takes the leading hidden sret path.
        (>= (lower-test-count functions "main" (Pack)) 1))]
    [_ false]))

(test
  compiler-lower-internal-structural-call-shape
  (test.assert-true
    (compiler-lower-internal-structural-call-shape-ok?)
    "tuple/array internal call and return transport"))

(define (compiler-lower-internal-windows-byref-sret-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-internal-windows-byref-sret-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (and
        (lower-test-function-defined? functions "array-roundtrip")
        (lower-test-function-defined? functions "scalar-roundtrip")
        (= (lower-test-function-param-count functions "array-roundtrip") 2)
        (= (lower-test-function-param-count functions "scalar-roundtrip") 1)
        (=
          (lower-test-function-call-count functions "main" "array-roundtrip")
          1)
        (=
          (lower-test-function-call-count functions "main" "scalar-roundtrip")
          1)
        (>= (lower-test-count functions "array-roundtrip" (CopyBytes)) 1)
        ;; Win64 ByRef parameters are copied into a private caller buffer;
        ;; the >8-byte result uses a leading sret pointer.
        (>= (lower-test-count functions "main" (CopyBytes)) 1))]
    [_ false]))

(define (compiler-lower-internal-windows-u8-three-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-internal-windows-u8-three-source)
      (lower.CompilerLowerMode.WindowsScalar)))
    [(Some functions)
      (and
        (lower-test-function-defined? functions "roundtrip")
        ;; Leading caller-owned sret plus one ByRef source parameter.
        (= (lower-test-function-param-count functions "roundtrip") 2)
        (= (lower-test-function-call-count functions "main" "roundtrip") 1)
        ;; Three-byte copies lower to two scalar load/store chunks rather
        ;; than a bulk CopyBytes instruction. The callee copies into sret;
        ;; main has three literal stores plus the two ByRef-copy stores.
        (>= (lower-test-count functions "roundtrip" (StorePtr)) 2)
        (>= (lower-test-count functions "main" (StorePtr)) 5))]
    [_ false]))

(define (compiler-lower-internal-early-return-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-internal-early-return-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (>= (lower-test-count functions "tuple-early" (Pack)) 1)
        (>= (lower-test-count functions "array-early" (CopyBytes)) 1))]
    [_ false]))

(define (compiler-lower-internal-indirect-structural-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-internal-indirect-structural-source)))
    [(Some functions)
      (and
        (= (lower-test-count functions "main" (IndirectCall)) 1)
        (>= (lower-test-count functions "main" (Pack)) 1))]
    [_ false]))

(define (compiler-lower-internal-tail-structural-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source
      (compiler-lower-internal-tail-structural-source)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "loop" "loop") 0)
        (> (lower-test-function-call-count functions "loop" "loop") 0))]
    [_ false]))

(define (compiler-lower-internal-unsupported-diagnostics-ok?) : bool
  (and
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-param-source)
      (lower.CompilerLowerMode.LinuxScalar)
      "lower: unsupported linux-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-param-source)
      (lower.CompilerLowerMode.WindowsScalar)
      "lower: unsupported windows-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-empty-tuple-return-source)
      (lower.CompilerLowerMode.LinuxScalar)
      "lower: unsupported linux-x86_64 internal aggregate ABI for (Tuple ); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-empty-tuple-return-source)
      (lower.CompilerLowerMode.WindowsScalar)
      "lower: unsupported windows-x86_64 internal aggregate ABI for (Tuple ); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      3)
    ;; Direct and indirect call conversion must stamp classifier errors at the
    ;; call expression, including when no concrete indirect callee exists.
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-direct-call-source)
      (lower.CompilerLowerMode.LinuxScalar)
      "lower: unsupported linux-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      4)
    (compiler-lower-mode-diagnostic-ok?
      (compiler-lower-internal-zero-array-indirect-call-source)
      (lower.CompilerLowerMode.WindowsScalar)
      "lower: unsupported windows-x86_64 internal aggregate ABI for (Array u8 0); tuple/fixed-array parameters and returns require a non-zero finite inline layout"
      2
      4)))

(define (compiler-lower-internal-direct-tail-structural-param-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-internal-direct-tail-structural-param-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (= (lower-test-function-tail-call-count functions "step" "finish") 0)
        (= (lower-test-function-call-count functions "step" "finish") 1)
        (>= (lower-test-count functions "step" (Pack)) 1))]
    [_ false]))

(define (compiler-lower-internal-indirect-tail-structural-param-shape-ok?) : bool
  (match (lower-test-functions
    (lower.lower-compiler-source-with-mode
      (compiler-lower-internal-indirect-tail-structural-param-source)
      (lower.CompilerLowerMode.LinuxScalar)))
    [(Some functions)
      (and
        (= (lower-test-count functions "step" (IndirectTailCall)) 0)
        (= (lower-test-count functions "step" (IndirectCall)) 1)
        (>= (lower-test-count functions "step" (Pack)) 1))]
    [_ false]))

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
    (let
      [target-module : i64 (ci.intern "selected.source")]
      [importer-module : i64 (ci.intern "selected.importer")]
      [item : i64 (ci.intern "source-value")]
      [alias : i64 (ci.intern "chosen")]
      [target-key : i64
        (csym.compiler-symbol-module-key-id-by-id target-module item)]
      [alias-key : i64
        (csym.compiler-symbol-module-key-id-by-id importer-module alias)]
      [symbol-id : i64 4242]
      [base : lower.LowerNameEnv
        (lower.lower-name-env-bind-logical-symbol-id
          target-key
          target-key
          symbol-id
          (Nil))]
      [aliased : lower.LowerNameEnv
        (lower.lower-name-env-add-selected-item-alias
          (lower.compiler-lower-state-new)
          base
          importer-module
          target-module
          item
          alias)]
      (and
        (=
          (lower.lower-name-env-lookup-logical-id
            (lower.lower-global-shared-view aliased)
            alias-key
            -1)
          target-key)
        (=
          (lower.lower-name-env-lookup-symbol-id
            (lower.lower-global-shared-view aliased)
            alias-key
            -1)
          symbol-id)
        (=
          (lower.lower-name-env-lookup-symbol-id aliased target-key -1)
          symbol-id)))
    "selected import aliases preserve source logical and linker identities"))

(test
  compiler-lower-package-alias-collision
  (test.assert-true
    (match (parser.parse-ast-source
      (compiler-lower-package-alias-collision-source))
      [(Ok program)
        (match (lower-test-functions
          (lower-compiler-program-with-decl-paths
            "consumer/src/main.tl"
            program
            (compiler-lower-package-alias-collision-paths)))
          [(Some functions)
            (and
              (=
                (lower-test-function-call-count
                  functions
                  "main"
                  "surface_left/src/lib.tl::left.src.lib/same")
                1)
              (=
                (lower-test-function-call-count
                  functions
                  "main"
                  "surface_right/src/lib.tl::right.src.lib/same")
                1))]
          [_ false])]
      [(Err _) false])
    "package aliases preserve same-named value targets"))

(test
  compiler-lower-package-extern-alias-symbols
  (test.assert-true
    (let
      [name : i64 (ci.intern "same")]
      [left-module : i64 (ci.intern "left.src.lib")]
      [right-module : i64 (ci.intern "right.src.lib")]
      [left : ast.AstDecl
        (load.compiler-load-package-def-fn-extern
          "surface_left"
          "C:/surface_left/"
          (svec.new)
          "C:/surface_left/src/lib.tl"
          "left.src.lib"
          name
          (ast.ast-param-list-new)
          (I64)
          Unavailable)]
      [right : ast.AstDecl
        (load.compiler-load-package-def-fn-extern
          "surface_right"
          "C:/surface_right/"
          (svec.new)
          "C:/surface_right/src/lib.tl"
          "right.src.lib"
          name
          (ast.ast-param-list-new)
          (I64)
          Unavailable)]
      [lower-state : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state
          (ci.intern-compat-state-capture-active))]
      (match left
        [(Extern _ _ _ left-meta _)
          (match right
            [(Extern _ _ _ right-meta _)
              (let
                [left-symbol : i64
                  (lower.lower-extern-logical-symbol-id
                    lower-state
                    (csym.compiler-symbol-module-key-id-by-id left-module name)
                    "same"
                    name
                    (ast.ast-extern-metadata-box-shared-view left-meta))]
                [right-symbol : i64
                  (lower.lower-extern-logical-symbol-id
                    lower-state
                    (csym.compiler-symbol-module-key-id-by-id right-module name)
                    "same"
                    name
                    (ast.ast-extern-metadata-box-shared-view right-meta))]
                (and
                  (not (= left-symbol right-symbol))
                  (string.eq
                    (ir.compiler-ir-symbol-text left-symbol)
                    "left.src.lib/same")
                  (string.eq
                    (ir.compiler-ir-symbol-text right-symbol)
                    "right.src.lib/same")))]
            [_ false])]
        [_ false]))
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
    (and
      (compiler-lower-masked-preheader-cache-counts-ok?
        (lower.CompilerLowerMode.Avx2)
        4)
      (compiler-lower-masked-preheader-cache-counts-ok?
        (lower.CompilerLowerMode.Avx512)
        8)
      (compiler-lower-masked-preheader-unsafe-rejected?
        (lower.CompilerLowerMode.Avx2))
      (compiler-lower-masked-preheader-unsafe-rejected?
        (lower.CompilerLowerMode.Avx512))
      (compiler-lower-masked-preheader-windows-avx2-cap-ok?))
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
  (and
    (compiler-lower-bounds-operand-shape-ok?)
    (compiler-lower-bounds-operand-width-predicate-ok?)
    (compiler-lower-bounds-operand-idempotent-ok?)
    (compiler-lower-name-env-dense-snapshots-ok?)
    (compiler-lower-alias-overlay-map-reuse-ok?)
    (compiler-lower-alias-overlay-negative-id-scan-ok?)
    (compiler-lower-name-cache-capacity-ok?)
    (compiler-lower-slice-reference-layout-ok?)
    (compiler-lower-internal-tuple-array-layout-ok?)
    (compiler-lower-internal-structural-call-shape-ok?)
    (compiler-lower-internal-windows-byref-sret-shape-ok?)
    (compiler-lower-internal-windows-u8-three-shape-ok?)
    (compiler-lower-internal-early-return-shape-ok?)
    (compiler-lower-internal-indirect-structural-shape-ok?)
    (compiler-lower-internal-tail-structural-shape-ok?)
    (compiler-lower-internal-unsupported-diagnostics-ok?)
    (compiler-lower-internal-direct-tail-structural-param-shape-ok?)
    (compiler-lower-internal-indirect-tail-structural-param-shape-ok?)
    (compiler-lower-capturing-lambda-structural-return-shape-ok?)
    (compiler-lower-capturing-lambda-structural-sret-params-ok?)
    (compiler-lower-defdispatch-structural-shape-ok?)
    (compiler-lower-slice-whole-array-pack-shape-ok?)
    (compiler-lower-slice-split-at-shape-ok?)
    (compiler-lower-tuple-inline-storage-ok?)
    (compiler-lower-boxed-helper-lists-ok?)
    (compiler-lower-name-cache-intern-id-dotted-ok?)
    (compiler-lower-module-phase-cache-storage-ok?)
    (compiler-lower-checked-pools-state-isolation-ok?)
    (compiler-lower-spmd-function-state-isolation-ok?)
    (compiler-lower-checked-pools-abort-lifecycle-ok?)
    (compiler-lower-type-cache-i64-keys-ok?)
    (compiler-lower-module-specialize-ok?)
    (compiler-lower-region-shape-ok?)
    (compiler-lower-with-escape-shape-ok?)
    (compiler-lower-with-scratch-shape-ok?)
    (compiler-lower-runtime-substring-scratch-reachable-ok?)
    (compiler-lower-runtime-substring-call-reachable-ok?)
    (compiler-lower-runtime-substring-capturing-lambda-reachable-ok?)
    (compiler-lower-runtime-atomic-reachable-ok?)
    (compiler-lower-in-arena-shape-ok?)
    (compiler-lower-tls-current-arena-shape-ok?)
    (compiler-lower-repr-c-shape-ok?)
    (compiler-lower-error-ok?
      (compiler-lower-branch-mismatch-source)
      "typecheck: if branches must match")
    (compiler-lower-scalar-shift-count-types-ok?)
    (compiler-lower-ok? (compiler-lower-array-literal-source))
    (compiler-lower-ok? (compiler-lower-fixed-array-return-source))
    (compiler-lower-ok? (compiler-lower-box-source))
    (compiler-lower-ok? (compiler-lower-box-get-source))
    (compiler-lower-ok? (compiler-lower-reference-source))
    (compiler-lower-ok? (compiler-lower-reference-auto-borrow-source))
    (compiler-lower-ok? (compiler-lower-reference-mut-dotted-field-source))
    (compiler-lower-reference-values-shape-ok?)
    (compiler-lower-reference-place-shape-ok?)
    (compiler-lower-reference-nominal-aggregate-ok?)
    (compiler-lower-comptime-fold-ok? (compiler-lower-comptime-arith-source) 3)
    (compiler-lower-comptime-fold-ok? (compiler-lower-comptime-if-source) 42)
    (compiler-lower-comptime-fold-ok? (compiler-lower-comptime-let-source) 42)
    (compiler-lower-error-ok?
      (compiler-lower-comptime-runtime-var-source)
      "compile-time evaluation cannot reference runtime variable 'x'")
    (compiler-lower-comptime-f64-fold-ok?
      (compiler-lower-comptime-f64-source)
      "1.5")
    (compiler-lower-comptime-f32-fold-ok?
      (compiler-lower-comptime-f32-source)
      "1")
    (compiler-lower-comptime-op-fold-tests-ok?)
    (compiler-lower-layout-query-fold-tests-ok?)
    (compiler-lower-error-ok?
      (compiler-lower-duplicate-function-source)
      "symbols: duplicate value declaration dup")
    (compiler-lower-numeric-shape-ok?)
    (compiler-lower-tail-call-shape-ok?)
    (compiler-lower-foreach-tests-ok?)
    (compiler-lower-array-var-set-ok?)
    (compiler-lower-spmd-reduce-tests-ok?)
    (compiler-lower-dce-test-symbols-ready?)
    (compiler-lower-ast-dce-ok?)
    (compiler-lower-type-decl-dce-ok?)
    (compiler-lower-type-decl-dce-qualified-base-ok?)
    (compiler-lower-type-decl-dce-arena-support-ok?)
    (compiler-lower-type-decl-dce-test-body-ok?)
    (compiler-lower-type-decl-dce-body-pattern-ok?)
    (compiler-lower-macro-body-dce-ok?)
    (compiler-lower-stdlib-comptime-runtime-dce-ok?)
    (compiler-lower-stdlib-comptime-runtime-skip-keeps-types-ok?)
    (compiler-lower-stdlib-comptime-type-prune-keeps-types-ok?)
    (compiler-lower-stdlib-comptime-nullary-enum-runtime-skip-ok?)
    (compiler-lower-unsafe-ast-dce-ok?)))

(test
  compiler-lower-profile-job-isolation
  (test.assert-true
    (compiler-lower-profile-job-isolation-tests-ok?)
    "lower profile reset and observations stay isolated per job"))

(test
  compiler-lower-name-profile-job-isolation
  (test.assert-true
    (compiler-lower-name-profile-job-isolation-tests-ok?)
    "lower name metrics stay isolated across equal-ID jobs and owner reset"))

(test
  compiler-lower-spmd-structural-profile
  (test.assert-true
    (let
      [state : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state
          (ci.intern-compat-state-new))]
      [_package : unit
        (lower.compiler-lower-state-set-spmd-package! state "profile-pkg")]
      [intern-state : ci.InternCompatState
        (lower.compiler-lower-state-interns state)]
      [canonical : i64
        (ci.intern-compat-state-intern (&mut intern-state) "profile-pkg/helper")]
      [classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
      [_class : unit
        (ast.ast-spmd-param-class-list-push (&mut classes) Varying)]
      [first : i64
        (lower.lower-spmd-package-structural-symbol
          state
          "profile-pkg"
          "profile-pkg/helper"
          canonical
          "(-> i64 i64)"
          (I64)
          (Avx512)
          8
          classes
          (Varying)
          0)]
      [repeat : i64
        (lower.lower-spmd-package-structural-symbol
          state
          "profile-pkg"
          "profile-pkg/helper"
          canonical
          "(-> i64 i64)"
          (I64)
          (Avx512)
          8
          classes
          (Varying)
          0)]
      [expected : String
        (lower.lower-spmd-package-symbol
          "profile-pkg"
          "profile-pkg/helper"
          "(-> i64 i64)"
          (I64)
          (Avx512)
          8
          "v"
          "v"
          0)]
      [lazy-before : bool
        (and
          (=
            (string.string-length
              (ci.intern-compat-state-str
                intern-state
                (lower.lower-spmd-package-structural-identity
                  (owned_view.compiler-owned-shared-view intern-state)
                  first)))
            0)
          (=
            (string.string-length
              (ci.intern-compat-state-str
                intern-state
                (lower.lower-spmd-package-structural-linker-symbol
                  intern-state
                  first)))
            0))]
      (lower.lower-materialize-generated-role-symbols! state)
      (and
        lazy-before
        (=
          (lower.lower-spmd-package-structural-identity
            (owned_view.compiler-owned-shared-view intern-state)
            first)
          (lower.lower-spmd-package-structural-identity
            (owned_view.compiler-owned-shared-view intern-state)
            repeat))
        (=
          (lower.lower-spmd-package-structural-linker-symbol intern-state first)
          (lower.lower-spmd-package-structural-linker-symbol
            intern-state
            repeat))
        (=
          (lower.lower-spmd-package-structural-registration-key
            intern-state
            first)
          (lower.lower-spmd-package-structural-registration-key
            intern-state
            repeat))
        (string.eq
          (ci.intern-compat-state-str
            intern-state
            (lower.lower-spmd-package-structural-linker-symbol
              intern-state
              first))
          expected)
        (= (compiler-lower-profile-spmd-identity-serializations-value state) 1)
        (= (compiler-lower-profile-spmd-stable-hash-computations-value state) 1)
        (= (compiler-lower-profile-spmd-render-cache-misses-value state) 1)
        (>= (compiler-lower-profile-spmd-render-cache-hits-value state) 2)))
    "SPMD identity serialization and stable hashing are cached per structural recipe"))

(define (compiler-lower-state-advisory-sink [state : lower.CompilerLowerState]) : cdiag.CompilerAdvisorySink
  (lower.compiler-lower-state-read
    state
    cdiag.CompilerAdvisorySink
    lower.advisory-sink-owner))

(defenum LowerPrunedProgram
  (Program ast.AstProgram ast.AstDeclPathList))

(define (compiler-lower-checked-pools-state-inert?
  [lower-state : lower.CompilerLowerState]) : bool
  (let
    [handoff : lower.CompilerLowerCheckedPoolsState
      (lower.compiler-lower-state-checked-pools lower-state)]
    (and
      (not handoff.active)
      (not handoff.committed)
      (match handoff.context
        [(NoContext) true]
        [(Context _) false])
      (= handoff.source-release-arena 0)
      (= handoff.source-release-expr-storage-arena 0)
      (= handoff.source-release-type-storage-arena 0)
      (= handoff.frontend-release-arena 0)
      (not handoff.frontend-released)
      (not handoff.rolled-over)
      (not handoff.deferred)
      (= handoff.deferred-expr-capacity 0)
      (= handoff.deferred-type-capacity 0))))

;; Exercise the complete transition record without owning/destroying the active
;; test pool. A receives every handoff field, B must remain byte-for-byte stable,
;; and clear must remove the context and deferred-capacity payload rather than
;; leaving an inactive pointer into another job's pool generation.
(define (compiler-lower-checked-pools-state-isolation-ok?) : bool
  (let
    [state-a : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [state-b : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [initial-a : lower.CompilerLowerStateObservation
      (lower.compiler-lower-state-observe state-a)]
    [initial-b : lower.CompilerLowerStateObservation
      (lower.compiler-lower-state-observe state-b)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    (lower.compiler-lower-checked-dest-pools-use! state-a pools 101 102 103 104)
    (let
      [armed : lower.CompilerLowerCheckedPoolsState
        (lower.compiler-lower-state-checked-pools state-a)]
      [_defer-second-destination : unit
        (begin
          (set! armed.frontend-released true)
          (set! armed.rolled-over true)
          (set! armed.deferred true)
          (set! armed.deferred-expr-capacity 105)
          (set! armed.deferred-type-capacity 106)
          (lower.compiler-lower-state-checked-pools-set! state-a armed))]
      [armed-a : lower.CompilerLowerStateObservation
        (lower.compiler-lower-state-observe state-a)]
      [untouched-b : lower.CompilerLowerStateObservation
        (lower.compiler-lower-state-observe state-b)]
      [armed-ok? : bool
        (and
          armed.active
          (not armed.committed)
          (match armed.context
            [(Context observed)
              (=
                (ast.ast-node-pool-context-base-arena observed)
                (ast.ast-node-pool-context-base-arena pools))]
            [(NoContext) false])
          (= armed.source-release-arena 101)
          (= armed.source-release-expr-storage-arena 102)
          (= armed.source-release-type-storage-arena 103)
          (= armed.frontend-release-arena 104)
          armed.frontend-released
          armed.rolled-over
          armed.deferred
          (= armed.deferred-expr-capacity 105)
          (= armed.deferred-type-capacity 106))]
      (lower.compiler-lower-checked-dest-pools-clear! state-a)
      (and
        armed-ok?
        (not (lower.compiler-lower-state-observation-eq? initial-a armed-a))
        (lower.compiler-lower-state-observation-eq? initial-b untouched-b)
        (lower.compiler-lower-state-observation-eq?
          initial-a
          (lower.compiler-lower-state-observe state-a))
        (compiler-lower-checked-pools-state-inert? state-a)
        (compiler-lower-checked-pools-state-inert? state-b)))))

(define (compiler-lower-checked-pools-test-arm-committed!
  [state : lower.CompilerLowerState]
  [pools : ast.AstNodePoolContext]) : unit
  (lower.compiler-lower-checked-dest-pools-use! state pools 0 0 0 0)
  (let
    [handoff : lower.CompilerLowerCheckedPoolsState
      (lower.compiler-lower-state-checked-pools state)]
    (set! handoff.committed true)
    (lower.compiler-lower-state-checked-pools-set! state handoff)))

(define (compiler-lower-checked-pools-test-context-destroy!
  [pools : ast.AstNodePoolContext]
  [return-arena : i64]) : unit
  (let
    [base-arena : i64 (ast.ast-node-pool-context-base-arena pools)]
    (unsafe
      (arena.tl_arena_set return-arena))
    (ast.ast-node-pool-context-destroy-storage! pools)
    (unsafe
      (arena.tl_arena_set return-arena)
      (arena.tl_arena_destroy base-arena)
      (arena.tl_arena_set return-arena))))

;; Abort both sides of deferred materialization with real owned arenas. The
;; driver-owned first destination is deliberately released by the test after
;; abort, while abort itself owns the macro frontend and (when present) second
;; destination. Completing both routes without stale state or double-destroy
;; validates that ownership split, including the no-materialization failure edge.
(define (compiler-lower-checked-pools-abort-lifecycle-ok?) : bool
  (let
    [return-arena : i64 (arena.tl_arena_current)]
    [active-pools-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [deferred-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [deferred-base : i64 (arena.tl_arena_make)]
    [deferred-source : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena 8 2 deferred-base)]
    [materialized-state : lower.CompilerLowerState
      (lower.compiler-lower-state-new)]
    [materialized-base : i64 (arena.tl_arena_make)]
    [materialized-source : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        8
        2
        materialized-base)]
    [retained-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [retained-base : i64 (arena.tl_arena_make)]
    [retained-source : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena 8 2 retained-base)]
    [ok : bool true]
    (compiler-lower-checked-pools-test-arm-committed!
      deferred-state
      deferred-source)
    (lower.lower-checked-dest-pools-rollover-for-macro! deferred-state)
    (let
      [deferred : lower.CompilerLowerCheckedPoolsState
        (lower.compiler-lower-state-checked-pools deferred-state)]
      (unless
        (and
          deferred.active
          (not deferred.committed)
          deferred.rolled-over
          deferred.deferred
          (> deferred.frontend-release-arena 0)
          (=
            deferred.deferred-expr-capacity
            (ast.ast-node-pool-context-expr-capacity deferred-source))
          (=
            deferred.deferred-type-capacity
            (ast.ast-node-pool-context-type-capacity deferred-source)))
        (set! ok false)))
    (lower.compiler-lower-checked-dest-pools-abort-uncommitted! deferred-state)
    (unless
      (and
        (compiler-lower-checked-pools-state-inert? deferred-state)
        (= (arena.tl_arena_current) deferred-base))
      (set! ok false))
    (compiler-lower-checked-pools-test-context-destroy!
      deferred-source
      return-arena)
    (compiler-lower-checked-pools-test-arm-committed!
      materialized-state
      materialized-source)
    (lower.lower-checked-dest-pools-rollover-for-macro! materialized-state)
    (let
      [second-destination : ast.AstNodePoolContext
        (lower.compiler-lower-checked-dest-pools-current materialized-state)]
      [materialized : lower.CompilerLowerCheckedPoolsState
        (lower.compiler-lower-state-checked-pools materialized-state)]
      (unless
        (and
          materialized.active
          (not materialized.committed)
          materialized.rolled-over
          (not materialized.deferred)
          (> materialized.frontend-release-arena 0)
          (not
            (=
              (ast.ast-node-pool-context-base-arena second-destination)
              materialized-base)))
        (set! ok false)))
    (lower.compiler-lower-checked-dest-pools-abort-uncommitted!
      materialized-state)
    (unless
      (and
        (compiler-lower-checked-pools-state-inert? materialized-state)
        (= (arena.tl_arena_current) materialized-base))
      (set! ok false))
    (compiler-lower-checked-pools-test-context-destroy!
      materialized-source
      return-arena)
    (compiler-lower-checked-pools-test-arm-committed!
      retained-state
      retained-source)
    (lower.lower-checked-dest-pools-rollover-for-macro! retained-state)
    (lower.lower-checked-dest-pools-retain-macro-source!
      retained-state
      retained-source)
    (let
      [retained : lower.CompilerLowerCheckedPoolsState
        (lower.compiler-lower-state-checked-pools retained-state)]
      (unless
        (and
          (not retained.active)
          retained.committed
          retained.frontend-released
          (not retained.rolled-over)
          (not retained.deferred)
          (= retained.frontend-release-arena 0)
          (= retained.deferred-expr-capacity 0)
          (= retained.deferred-type-capacity 0)
          (=
            (ast.ast-node-pool-context-base-arena
              (lower.compiler-lower-checked-pools-context retained))
            retained-base))
        (set! ok false)))
    (lower.compiler-lower-checked-dest-pools-clear! retained-state)
    (unless
      (compiler-lower-checked-pools-state-inert? retained-state)
      (set! ok false))
    (ast.ast-node-pool-context-install! active-pools-before)
    (compiler-lower-checked-pools-test-context-destroy!
      retained-source
      return-arena)
    ok))

(define (compiler-lower-profile-spmd-identity-serializations-value
  [_state : lower.CompilerLowerState]) : i64
  (cfg
    (any compile-profile test)
    (lower.compiler-lower-profile-value
      _state
      lower.compiler-lower-profile-spmd-identity-serializations-metric)
    0))

(define (compiler-lower-profile-spmd-stable-hash-computations-value
  [_state : lower.CompilerLowerState]) : i64
  (cfg
    (any compile-profile test)
    (lower.compiler-lower-profile-value
      _state
      lower.compiler-lower-profile-spmd-stable-hash-computations-metric)
    0))

(define (compiler-lower-profile-spmd-render-cache-hits-value
  [_state : lower.CompilerLowerState]) : i64
  (cfg
    (any compile-profile test)
    (lower.compiler-lower-profile-value
      _state
      lower.compiler-lower-profile-spmd-render-cache-hits-metric)
    0))

(define (compiler-lower-profile-spmd-render-cache-misses-value
  [_state : lower.CompilerLowerState]) : i64
  (cfg
    (any compile-profile test)
    (lower.compiler-lower-profile-value
      _state
      lower.compiler-lower-profile-spmd-render-cache-misses-metric)
    0))

(cfg
  test
  (define (compiler-lower-profile-job-isolation-tests-ok?) : bool
    (let
      [left-profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right-profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state-and-profile-state
          (ci.intern-compat-state-new)
          left-profile)]
      [right : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state-and-profile-state
          (ci.intern-compat-state-new)
          right-profile)]
      (lower.compiler-lower-profile-reset! left)
      (lower.compiler-lower-profile-reset! right)
      (lower.compiler-lower-profile-set!
        left
        lower.compiler-lower-profile-start-ms-metric
        11)
      (lower.compiler-lower-profile-set!
        right
        lower.compiler-lower-profile-start-ms-metric
        29)
      (lower.compiler-lower-profile-string-concat-note-tree! left 7)
      (lower.compiler-lower-profile-string-concat-note-runtime-call! right)
      (lower.compiler-lower-profile-string-concat-note-runtime-call! left)
      (lower.compiler-lower-profile-reset! right)
      (and
        (=
          (lower.compiler-lower-profile-value
            left
            lower.compiler-lower-profile-start-ms-metric)
          11)
        (=
          (lower.compiler-lower-profile-value
            left
            lower.compiler-lower-profile-string-concat-trees-metric)
          1)
        (=
          (lower.compiler-lower-profile-value
            left
            lower.compiler-lower-profile-string-concat-leaves-metric)
          7)
        (=
          (lower.compiler-lower-profile-value
            left
            lower.compiler-lower-profile-string-concat-runtime-calls-metric)
          1)
        (=
          (lower.compiler-lower-profile-value
            right
            lower.compiler-lower-profile-start-ms-metric)
          0)
        (=
          (lower.compiler-lower-profile-value
            right
            lower.compiler-lower-profile-string-concat-trees-metric)
          0)
        (=
          (lower.compiler-lower-profile-value
            right
            lower.compiler-lower-profile-string-concat-runtime-calls-metric)
          0)))))

(cfg
  test
  (define (compiler-lower-name-profile-job-isolation-tests-ok?) : bool
    (let
      [left-profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right-profile : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state-and-profile-state
          (ci.intern-compat-state-new)
          left-profile)]
      [right : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state-and-profile-state
          (ci.intern-compat-state-new)
          right-profile)]
      [left-names : lower.LowerNameEnv Nil]
      [bind-id : i64 0]
      (lower.compiler-lower-profile-name-reset left)
      (lower.compiler-lower-profile-name-reset right)
      ;; Equal IDs deliberately flow through two owners. A reset is allowed to
      ;; affect only the exact profile state passed to it.
      (while (< bind-id 17)
        (set!
          left-names
          (lower.lower-name-env-bind-ids-profile
            left
            bind-id
            bind-id
            bind-id
            left-names))
        (set! bind-id (+ bind-id 1)))
      (let
        [_left-env-hit : i64
          (lower.lower-name-env-lookup-symbol-id-profile
            left
            (lower.lower-global-shared-view left-names)
            0
            -1)]
        [_copy : lower.LowerNameEnv
          (lower.lower-name-env-materialize-two-profile
            left
            (lower.lower-global-shared-view left-names)
            Nil)]
        [left-cache : lower.LowerNameCache
          (lower.lower-name-cache-from-env left left-names)]
        [_left-name-hit : i64
          (lower.lower-name-cache-lookup-symbol-id (& left-cache) 0 -1)]
        [_left-module-miss : lower.LowerMaybeModuleNameCache
          (lower.lower-active-module-name-cache-lookup left 7)]
        [_left-module-insert : unit
          (lower.lower-active-module-name-cache-insert!
            left
            7
            (lower.lower-global-shared-view left-cache))]
        [_left-module-hit : lower.LowerMaybeModuleNameCache
          (lower.lower-active-module-name-cache-lookup left 7)]
        [left-view : lower.LowerModuleLocalView
          (lower.LowerModuleLocalView (tc_core.tc-empty-env) left-cache (No))]
        [_left-view-miss : lower.LowerMaybeModuleLocalView
          (lower.lower-active-module-local-view-lookup left 7)]
        [_left-view-insert : unit
          (lower.lower-active-module-local-view-insert! left 7 left-view)]
        [_left-view-hit : lower.LowerMaybeModuleLocalView
          (lower.lower-active-module-local-view-lookup left 7)]
        [right-names : lower.LowerNameEnv
          (lower.lower-name-env-bind-ids-profile right 0 0 0 Nil)]
        [_right-env-hit : i64
          (lower.lower-name-env-lookup-symbol-id-profile
            right
            (lower.lower-global-shared-view right-names)
            0
            -1)]
        [right-cache : lower.LowerNameCache
          (lower.lower-name-cache-from-env right right-names)]
        [_right-name-miss : i64
          (lower.lower-name-cache-lookup-symbol-id (& right-cache) 1 -1)]
        [_right-module-insert : unit
          (lower.lower-active-module-name-cache-insert!
            right
            7
            (lower.lower-global-shared-view right-cache))]
        [right-view : lower.LowerModuleLocalView
          (lower.LowerModuleLocalView (tc_core.tc-empty-env) right-cache (No))]
        [_right-view-insert : unit
          (lower.lower-active-module-local-view-insert! right 7 right-view)]
        [right-recorded : bool
          (and
            (=
              (lower.compiler-lower-profile-value
                right
                lower.compiler-lower-profile-name-env-binds-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                right
                lower.compiler-lower-profile-module-name-cache-entries-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                right
                lower.compiler-lower-profile-module-local-view-entries-metric)
              1))]
        (lower.compiler-lower-profile-name-reset right)
        (let
          [metric : i64 lower.compiler-lower-profile-name-env-binds-metric]
          [right-reset : bool true]
          (while (< metric lower.compiler-lower-name-cache-profile-end)
            (when
              (not (= (lower.compiler-lower-profile-value right metric) 0))
              (set! right-reset false))
            (set! metric (+ metric 1)))
          (and
            right-recorded
            right-reset
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-binds-metric)
              17)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-lookups-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-lookup-steps-metric)
              17)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-stores-metric)
              2)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-store-grows-metric)
              2)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-materializations-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-env-materialized-entries-metric)
              17)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-cache-builds-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-cache-entries-metric)
              17)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-cache-lookups-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-cache-local-hits-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-name-cache-local-misses-metric)
              0)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-module-name-cache-lookups-metric)
              2)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-module-name-cache-hits-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-module-name-cache-entries-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-module-local-view-lookups-metric)
              2)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-module-local-view-hits-metric)
              1)
            (=
              (lower.compiler-lower-profile-value
                left
                lower.compiler-lower-profile-module-local-view-entries-metric)
              1)))))))

(define (lower-name-env-bind-logical-id
  [source-id : i64]
  [logical-name : String]
  [logical-id : i64]
  [rest : lower.LowerNameEnv]) : lower.LowerNameEnv
  (lower.lower-name-env-bind-ids
    source-id
    logical-id
    (lower.lower-derived-symbol-id logical-name)
    rest))

(define (lower-name-env-from-decls
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [entry-path : String]
  [names : lower.LowerNameEnv]) : lower.LowerNameEnv
  (lower.lower-name-env-from-decls-with-state
    (lower.compiler-lower-state-new)
    decls
    paths
    entry-path
    names))

(define (lower-active-module-name-cache-count
  [lower-state : lower.CompilerLowerState]) : i64
  (let
    [store : lower.LowerModuleNameCacheStore
      (lower.compiler-lower-state-read
        lower-state
        lower.LowerModuleNameCacheStore
        lower.active-module-name-caches)]
    store.len))

(define (lower-active-module-local-view-count
  [lower-state : lower.CompilerLowerState]) : i64
  (let
    [store : lower.LowerModuleLocalViewStore
      (lower.compiler-lower-state-read
        lower-state
        lower.LowerModuleLocalViewStore
        lower.active-module-local-views)]
    store.len))

;; Structural regression for the phase-local module caches. The high sparse ID
;; proves storage is dense rather than sized by the global interner range;
;; repeated inserts must retain one slot, reset must retire both value families,
;; and a second job-owned state must never observe the first state's entries.
(define (compiler-lower-module-phase-cache-storage-ok?) : bool
  (let
    [state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [independent : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [base-cache : lower.LowerNameCache
      (lower.lower-empty-global-name-cache state.address)]
    [empty-env : tc_core.TcTypeEnv (tc_core.tc-empty-env)]
    [index : i64 0]
    [sparse-id : i64 9000001]
    (while (< index 12)
      (let
        [module-id : i64 (+ 1000 index)]
        [cache : lower.LowerNameCache
          (lower.lower-name-cache-with-module-id
            (lower.lower-global-shared-view base-cache)
            module-id)]
        [view : lower.LowerModuleLocalView
          (lower.LowerModuleLocalView
            empty-env
            (lower.lower-global-shared-view cache)
            (No))]
        (lower.lower-active-module-name-cache-insert! state module-id cache)
        (lower.lower-active-module-local-view-insert! state module-id view))
      (set! index (+ index 1)))
    (let
      [sparse-cache : lower.LowerNameCache
        (lower.lower-name-cache-with-module-id base-cache sparse-id)]
      [sparse-view : lower.LowerModuleLocalView
        (lower.LowerModuleLocalView
          empty-env
          (lower.lower-global-shared-view sparse-cache)
          (No))]
      (lower.lower-active-module-name-cache-insert!
        state
        sparse-id
        (lower.lower-global-shared-view sparse-cache))
      (lower.lower-active-module-local-view-insert!
        state
        sparse-id
        (lower.lower-global-shared-view sparse-view))
      ;; A duplicate publication updates the existing dense slot instead
      ;; of growing either store.
      (lower.lower-active-module-name-cache-insert!
        state
        sparse-id
        sparse-cache)
      (lower.lower-active-module-local-view-insert! state sparse-id sparse-view))
    (let
      [before-reset : bool
        (and
          (= (lower-active-module-name-cache-count state) 13)
          (= (lower-active-module-local-view-count state) 13)
          (= (lower-active-module-name-cache-count independent) 0)
          (= (lower-active-module-local-view-count independent) 0)
          (match (lower.lower-active-module-name-cache-lookup state sparse-id)
            [(Some cache) (= cache.module-id sparse-id)]
            [(No) false])
          (match (lower.lower-active-module-local-view-lookup state sparse-id)
            [(Some view) (= view.name-cache.module-id sparse-id)]
            [(No) false])
          (match (lower.lower-active-module-name-cache-lookup state 7777777)
            [(No) true]
            [_ false])
          (match (lower.lower-active-module-local-view-lookup state 7777777)
            [(No) true]
            [_ false]))]
      (lower.lower-module-phase-caches-reset! state)
      (and
        before-reset
        (= (lower-active-module-name-cache-count state) 0)
        (= (lower-active-module-local-view-count state) 0)
        (match (lower.lower-active-module-name-cache-lookup state sparse-id)
          [(No) true]
          [_ false])
        (match (lower.lower-active-module-local-view-lookup state sparse-id)
          [(No) true]
          [_ false])))))

(define (compiler-lower-state-function-memo-retained-bytes
  [state : lower.CompilerLowerState]) : i64
  (let
    [storage : lower.CompilerLowerFunctionMemoStorage
      (lower.compiler-lower-function-memo-storage state)]
    (+
      (*
        8
        (+
          (array-length storage.rtf-generations)
          (array-length storage.rtf-ids)))
      (+
        (* (ast.ast-type-node-bytes) (array-length storage.rtf-types))
        (+
          (*
            8
            (+
              (array-length storage.variant-stamps)
              (array-length storage.variant-keys)))
          (+
            (*
              (ast.ast-type-node-bytes)
              (array-length storage.variant-scrutinee-types))
            (*
              (lower.lower-variant-arm-resolution-size)
              (array-length storage.variant-outcomes))))))))

(define (compiler-lower-state-reset? [lower-state : lower.CompilerLowerState]) : bool
  (let
    [global-names : lower.LowerNameCache
      (lower.compiler-lower-state-read
        lower-state
        lower.LowerNameCache
        lower.active-global-name-cache)]
    [alias-memo : (__tl_dyn-array i64)
      (lower.compiler-lower-state-read
        lower-state
        (__tl_dyn-array i64)
        lower.alias-symbol-memo)]
    [rvo : lower_i64_i64_map.Map
      (lower.compiler-lower-state-read
        lower-state
        lower_i64_i64_map.Map
        lower.rvo-early-return-functions)]
    [runtime-paths : lower_i64_i64_map.Map
      (lower.compiler-lower-state-read
        lower-state
        lower_i64_i64_map.Map
        lower.reach-active-runtime-paths)]
    [used-types : lower_i64_i64_map.Map
      (lower.compiler-lower-state-read
        lower-state
        lower_i64_i64_map.Map
        lower.reach-active-body-used-types)]
    [module-name-caches : lower.LowerModuleNameCacheStore
      (lower.compiler-lower-state-read
        lower-state
        lower.LowerModuleNameCacheStore
        lower.active-module-name-caches)]
    [module-local-views : lower.LowerModuleLocalViewStore
      (lower.compiler-lower-state-read
        lower-state
        lower.LowerModuleLocalViewStore
        lower.active-module-local-views)]
    [alias-ids : lower_i64_i64_map.Map
      (lower.compiler-lower-state-read
        lower-state
        lower_i64_i64_map.Map
        lower.alias-overlay-ids)]
    [index-modules : lower_i64_i64_map.Map
      (lower.compiler-lower-state-read
        lower-state
        lower_i64_i64_map.Map
        lower.module-decl-index-modules)]
    [index-starts : (__tl_dyn-array i64)
      (lower.compiler-lower-state-read
        lower-state
        (__tl_dyn-array i64)
        lower.module-decl-index-starts)]
    [index-ends : (__tl_dyn-array i64)
      (lower.compiler-lower-state-read
        lower-state
        (__tl_dyn-array i64)
        lower.module-decl-index-ends)]
    [index-positions : (__tl_dyn-array i64)
      (lower.compiler-lower-state-read
        lower-state
        (__tl_dyn-array i64)
        lower.module-decl-index-positions)]
    [active-symbols-state : csym.CompilerSymbols
      (lower.compiler-lower-state-read
        lower-state
        csym.CompilerSymbols
        lower.active-symbols)]
    [package : lower.CompilerLowerSpmdPackageState
      (lower.compiler-lower-state-spmd-package lower-state)]
    (and
      (= (lower_i64_i64_map.len (& global-names.ids)) 0)
      (= (array-length global-names.logical-ids) 0)
      (match (lower.compiler-lower-state-read
        lower-state
        lower.LowerTypeCache
        lower.decls-global-type-cache)
        [(No) true]
        [_ false])
      (= (lower_i64_i64_map.len (& rvo)) 0)
      (= (lower_i64_i64_map.len (& runtime-paths)) 0)
      (= (lower_i64_i64_map.len (& used-types)) 0)
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.current-source-path-id)
        0)
      (not
        (lower.compiler-lower-state-read
          lower-state
          bool
          lower.current-decl-generated))
      (= (csym.compiler-symbols-decl-count (& active-symbols-state)) 0)
      (not
        (lower.compiler-lower-state-read
          lower-state
          bool
          lower.active-symbols-ready))
      (= module-name-caches.len 0)
      (= (lower_i64_i64_map.len (& module-name-caches.modules)) 0)
      (= module-local-views.len 0)
      (= (lower_i64_i64_map.len (& module-local-views.modules)) 0)
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.active-loop-function)
        -1)
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.active-loop-entry-var-limit)
        -1)
      (= (lower_i64_i64_map.len (& alias-ids)) 0)
      (lower.compiler-lower-state-read
        lower-state
        bool
        lower.alias-overlay-valid)
      (= (array-length alias-memo) 0)
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.canonical-path-count)
        0)
      (string.eq (lower.lower-canonical-path-recent-current lower-state) "")
      (string.eq (lower.lower-canonical-path-prior-current lower-state) "")
      (not
        (lower.compiler-lower-state-read
          lower-state
          bool
          lower.entry-main-module-active))
      (string.eq (lower.lower-entry-main-module-current lower-state) "")
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.entry-main-module-id)
        cbi.compiler-builtin-id-fix-empty)
      (not
        (lower.compiler-lower-state-read
          lower-state
          bool
          lower.module-decl-index-ready))
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.module-decl-index-decl-count)
        -1)
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.module-decl-index-decl-offset)
        -1)
      (= (lower_i64_i64_map.len (& index-modules)) 0)
      (= (array-length index-starts) 0)
      (= (array-length index-ends) 0)
      (= (array-length index-positions) 0)
      (=
        (lower.compiler-lower-state-read
          lower-state
          i64
          lower.module-decl-index-arena)
        0)
      (string.eq package.name "")
      (= (lower_i64_i64_map.len (& package.symbol-identities)) 0)
      (= (lower_i64_i64_map.len (& package.identity-stable-hashes)) 0)
      (lower-comptime-error-ids-reset? lower-state)
      (compiler-lower-checked-pools-state-inert? lower-state))))

(define (lower-comptime-error-ids-reset?
  [lower-state : lower.CompilerLowerState]) : bool
  (let
    [cache : (__tl_dyn-array i64)
      (lower.compiler-lower-state-read
        lower-state
        (__tl_dyn-array i64)
        lower.comptime-error-cache)]
    (and
      (= (array-ref cache lower.lower-comptime-cache-generation-index) -1)
      (= (array-ref cache lower.lower-comptime-cache-table-id-index) -1)
      (= (array-ref cache lower.lower-comptime-cache-id-index) 0)
      (= (array-ref cache lower.lower-comptime-cache-comptime-dot-id-index) 0)
      (= (array-ref cache lower.lower-comptime-cache-comptime-slash-id-index) 0)
      (=
        (array-ref cache lower.lower-comptime-cache-comptime-error-dot-id-index)
        0)
      (=
        (array-ref
          cache
          lower.lower-comptime-cache-comptime-error-slash-id-index)
        0)
      (= (array-ref cache lower.lower-comptime-cache-stdlib-dot-dot-id-index) 0)
      (=
        (array-ref cache lower.lower-comptime-cache-stdlib-dot-slash-id-index)
        0)
      (=
        (array-ref cache lower.lower-comptime-cache-stdlib-slash-dot-id-index)
        0)
      (=
        (array-ref cache lower.lower-comptime-cache-stdlib-slash-slash-id-index)
        0)
      (=
        (array-ref
          cache
          lower.lower-comptime-cache-stdlib-error-dot-dot-id-index)
        0)
      (=
        (array-ref
          cache
          lower.lower-comptime-cache-stdlib-error-dot-slash-id-index)
        0)
      (=
        (array-ref
          cache
          lower.lower-comptime-cache-stdlib-error-slash-dot-id-index)
        0)
      (=
        (array-ref
          cache
          lower.lower-comptime-cache-stdlib-error-slash-slash-id-index)
        0))))

(define (lower-compiler-program-with-decl-paths-mode
  [entry-path : String]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [mode : lower.CompilerLowerMode]) : lower.ResultCompilerLower
  (let
    [state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    (lower.lower-compiler-program-with-decl-paths-mode-cache-and-state
      state
      entry-path
      program
      paths
      mode
      (svec.new)
      (lower.lower-source-language-cfgs)
      (tc_core.tc-prefix-default-cache-scope))))

(define (lower-compiler-program-with-path
  [path : String]
  [program : ast.AstProgram]) : lower.ResultCompilerLower
  (lower.lower-compiler-program-with-path-mode
    path
    program
    (lower.CompilerLowerMode.Scalar)))

(define (lower-compiler-program [program : ast.AstProgram]) : lower.ResultCompilerLower
  (lower-compiler-program-with-path "<source>" program))

;; Lower SRC with debug info and type-graph verification on: the rendered
;; debug type graph (#8237), or the lowering error.
(define (compiler-lower-debug-type-graph-text [src : String]) : String
  (let
    [state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [result : lower.ResultCompilerLower
      (begin
        (ir.compiler-debug-info-set-enabled! true)
        (ir.compiler-debug-type-graph-verify-set! true)
        (lower.lower-compiler-source-with-path-mode-and-state
          state
          "<source>"
          src
          (lower.CompilerLowerMode.Scalar)))]
    (ir.compiler-debug-info-set-enabled! false)
    (ir.compiler-debug-type-graph-verify-set! false)
    (match result
      [(lower.ResultCompilerLower.Ok _ _)
        (let
          [graph : ir.CompilerDebugTypeGraph
            (lower.compiler-lower-state-debug-type-graph state)]
          (ir.compiler-debug-type-graph-render (& graph)))]
      [(lower.ResultCompilerLower.Err diag)
        (str_cat.str-cat
          "error: "
          (cdiag.compiler-diagnostic-render (deref diag)))])))

;; Every scalar width, nested and register-pair structs, a tuple, an enum with
;; unit, scalar and aggregate payloads, a fixed array of structs, a recursive
;; enum through Box (a forward node), Ref, Slice and str views, String, a
;; dynamic array, and one generated module at two instantiations.
(define (compiler-lower-debug-type-graph-source) : String
  "(import stdlib.option)\n(import (option.option i64) as oi)\n(import (option.option bool) as ob)\n(defstruct Point (x i64) (y i64))\n(defstruct Line (a Point) (b Point) (tag u8))\n(defenum Shape (Circle f64) (Rect Point Point) (Empty))\n(defenum Tree (Leaf i64) (Branch (Box Tree) (Box Tree)))\n(define (scalars [a : i8] [b : i16] [c : i32] [d : i64] [e : u8] [f : u16] [g : u32] [h : u64] [i : f32] [j : f64] [k : bool] [l : char]) : unit unit)\n(define (views [p : (& Point)] [s : (& str)] [xs : (& (Slice i64))] [name : String] [ys : (__tl_dyn-array i64)]) : i64 0)\n(define (main) : i64\n  (let\n    [line : Line (Line (Point 1 2) (Point 3 4) 5)]\n    [pair : (Tuple u8 i64 bool) (tuple 1 2 true)]\n    [shape : Shape (Shape.Empty)]\n    [grid : (Array Point 3) (array (Point 0 0) (Point 1 1) (Point 2 2))]\n    [tree : Tree (Tree.Leaf 1)]\n    [boxed : (Box i64) (box 7)]\n    [none : oi.Option (oi.Option.None)]\n    [flag : ob.Option (ob.Option.Some true)]\n    [name : String \"n\"]\n    [origin : Point (Point 1 2)]\n    [cells : (Array i64 2) (array 4 5)]\n    [ys : (__tl_dyn-array i64) (__tl_make-array i64 2)]\n    (begin\n      (scalars (cast 1 : i8) (cast 2 : i16) (cast 3 : i32) 4 (cast 5 : u8) (cast 6 : u16) (cast 7 : u32) (cast 8 : u64) (cast 1.5 : f32) 2.5 true 'c')\n      (views (& origin) \"s\" (slice-view (& cells) 0 2) name ys))))")

(test
  compiler-lower-debug-type-graph-golden
  (test.assert-owned-string-eq
    (compiler-lower-debug-type-graph-text
      (compiler-lower-debug-type-graph-source))
    "debug-types v1 nodes=30\nt0 scalar i8 size=1 align=1\nt1 scalar i16 size=2 align=2\nt2 scalar i32 size=4 align=4\nt3 scalar i64 size=8 align=8\nt4 scalar u8 size=1 align=1\nt5 scalar u16 size=2 align=2\nt6 scalar u32 size=4 align=4\nt7 scalar u64 size=8 align=8\nt8 scalar f32 size=4 align=4\nt9 scalar f64 size=8 align=8\nt10 scalar bool size=1 align=1\nt11 scalar char size=1 align=1\nt12 scalar unit size=0 align=1\nt13 pointer (& Point) size=8 align=8 target=t14\nt14 struct Point size=16 align=8 regs=2\n  .x t3 @0\n  .y t3 @8\nt15 handle (& str) size=8 align=8 target=t4\nt16 view (& (Slice i64)) size=16 align=8 target=t3\nt17 handle String size=8 align=8 target=t4\nt18 handle (__tl_dyn-array i64) size=8 align=8 target=t3\nt19 struct Line size=40 align=8\n  .a t14 @0\n  .b t14 @16\n  .tag t4 @32\nt20 tuple (Tuple u8 i64 bool) size=24 align=8\n  .0 t4 @0\n  .1 t3 @8\n  .2 t10 @16\nt21 enum Shape size=40 align=8 target=t3 count=3\n  variant Circle =0\n    .0 t9 @8\n  variant Rect =1\n    .0 t14 @8\n    .1 t14 @24\n  variant Empty =2\nt22 array (Array Point 3) size=48 align=8 target=t14 count=3\nt23 enum Tree size=24 align=8 target=t3 count=2\n  variant Leaf =0\n    .0 t3 @8\n  variant Branch =1\n    .0 t24 @8\n    .1 t24 @16\nt24 pointer (Box Tree) size=8 align=8 target=t25\nt25 forward Tree size=24 align=8 target=t23\nt26 pointer (Box i64) size=8 align=8 target=t3\nt27 enum stdlib.option.generated.i64/Option size=16 align=8 target=t3 count=2 regs=2\n  variant None =0\n  variant Some =1\n    .0 t3 @8\nt28 enum stdlib.option.generated.bool/Option size=16 align=8 target=t3 count=2 regs=2\n  variant None =0\n  variant Some =1\n    .0 t10 @8\nt29 array (Array i64 2) size=16 align=8 target=t3 count=2\n"
    "the debug type graph has every layout the typechecker computes"))

(test
  compiler-lower-debug-type-graph-stable
  (test.assert-owned-string-eq
    (compiler-lower-debug-type-graph-text
      (compiler-lower-debug-type-graph-source))
    (compiler-lower-debug-type-graph-text
      (compiler-lower-debug-type-graph-source))
    "two lowerings of one program give identical graphs"))

(test
  compiler-lower-debug-type-graph-off-without-debug-info
  (test.assert-true
    (let
      [state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
      (match (lower.lower-compiler-source-with-path-mode-and-state
        state
        "<source>"
        (compiler-lower-debug-type-graph-source)
        (lower.CompilerLowerMode.Scalar))
        [(lower.ResultCompilerLower.Ok _ _)
          (=
            (__tl-project-field
              (lower.compiler-lower-state-debug-type-graph state)
              node-count)
            0)]
        [(lower.ResultCompilerLower.Err _) false]))
    "without debug info lowering builds no graph"))

(test
  compiler-lower-debug-type-graph-mismatch-fails
  (test.assert-true
    (let
      [types : lower.LowerDebugTypes (lower.lower-debug-types-empty)]
      [name : String "Point"]
      (lower.lower-debug-check! (&mut types) (& name) "size" 16 16)
      (let
        [agreed : bool (= (string.string-length (& types.error)) 0)]
        (ir.compiler-debug-type-graph-verify-set! true)
        (lower.lower-debug-check! (&mut types) (& name) "size" 8 16)
        (lower.lower-debug-check! (&mut types) (& name) "align" 4 8)
        (ir.compiler-debug-type-graph-verify-set! false)
        (and
          agreed
          (string.eq
            (& types.error)
            "debug type graph: Point size is 8, the typechecker says 16"))))
    "a layout disagreement is kept, first one only, and only under --verify-ir"))