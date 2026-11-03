(import compiler_ast_types as ast)
(import compiler_typecheck_core as tc)
(import compiler_symbols as csym)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define (variance-context
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]) : tc.TcContext
  (let
    [symbols : csym.CompilerSymbols
      (match (csym.build-compiler-symbols (& program))
        [(Ok value) value]
        [(Err message) (io.panic message)])]
    [registries : csym.CompilerRegistries
      (match (csym.build-compiler-registries-with-symbols
        (& program)
        (& symbols))
        [(Ok value) value]
        [(Err message) (io.panic message)])]
    (tc.tc-context-new-with-source-names-and-job-state
      program
      symbols
      registries
      ""
      cbi.compiler-builtin-id-fix-empty
      pools
      (ci.intern-source-name-session-capture-active-handle)
      (tc.tc-job-state-new))))

;; Raw type IDs keep each level compact: two edges share the same child.
;; shape 1 shares across non-sibling paths; shape 2 reuses it at both polarities.
(define (variance-dag-context [depth : i64] [shape : i64]) : tc.TcContext
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [_install : unit (ast.ast-node-pool-context-install! pools)]
    [lifetime : i64 (ci.intern "r")]
    [node : i64
      (ast.ty-node-push (& (ast.ast-ty-ref lifetime (& (ast.AstType.I64)))))]
    [root : ast.AstType (ast.ty-node-get node)]
    [lifetimes : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
    [fields : ast.AstFieldDefList (ast.ast-field-def-list-new)]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    (for [_level (iterator.range 0 depth)]
      (let
        [children : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
        (ast.ast-type-list-push (&mut children) node)
        (ast.ast-type-list-push (&mut children) node)
        (set! root (ast.ast-ty-tuple children))
        (set! node (ast.ty-node-push (& root)))))
    (when
      (= shape 1)
      (let
        [children : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
        (ast.ast-type-list-push (&mut children) node)
        (ast.ast-type-list-push
          (&mut children)
          (ast.ty-node-push (& (ast.AstType.Box node))))
        (set! root (ast.ast-ty-tuple children))))
    (when
      (= shape 2)
      (let
        [params : ast.AstTypeList (ast.ast-type-list-with-capacity 1)]
        (ast.ast-type-list-push (&mut params) node)
        (set! root (ast.AstType.Func (box params) node))))
    (ast.ast-lifetime-list-push (&mut lifetimes) lifetime)
    (ast.ast-field-def-list-push
      (&mut fields)
      (ast.ast-field-def-id
        (ci.intern-syntax-id-from-raw (ci.intern "value"))
        root
        ast.AstFieldCleanup.No))
    (ast.ast-decl-list-push
      (&mut decls)
      (ast.ast-decl-def-struct-lifetimes-id
        (ci.intern "Dag")
        lifetimes
        ast.AstStructRepr.Default
        ast.AstStructCleanup.No
        fields))
    (variance-context (ast.ast-program decls) pools)))

(define (variance-answer [ctx : tc.TcContext] [name : (& str)] [index : i64]) : i64
  (tc.tc-variance-code
    (tc.tc-nominal-lifetime-variance-at
      ctx
      (ci.intern (string.copy name))
      index
      tc.TcNameIdList.Nil)))

(cfg
  test
  (define (variance-dag-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      (for [depth (iterator.range 0 13)]
        (for [shape (iterator.range 0 3)]
          (let
            [ctx : tc.TcContext (variance-dag-context depth shape)]
            (for [mode (iterator.range 0 3)]
              (tc.tc-variance-test-reset! mode)
              (when
                (!=
                  (variance-answer ctx "Dag" 0)
                  (if (= shape 2)
                    3
                    1))
                (io.panic
                  "variance memo/worklist disagrees with no-memo round-robin oracle"))))))
      (for [depth (iterator.range 32 41)]
        (let
          [ctx : tc.TcContext (variance-dag-context depth 0)]
          (tc.tc-variance-test-reset! 0)
          (when
            (or
              (!= (variance-answer ctx "Dag" 0) 1)
              (> tc.tc-variance-test-bodies (+ depth 3)))
            (io.panic "compact DAG variance body bound"))
          (let
            [before : i64 tc.tc-variance-test-bodies]
            (when
              (or
                (!= (variance-answer ctx "Dag" 0) 1)
                (!= before tc.tc-variance-test-bodies))
              (io.panic "completed variance answer was re-solved")))
          (io.print
            "DAG depth={} bodies={} walks={} lookup={} dependency={} polls={} allocated={}\n"
            depth
            tc.tc-variance-test-bodies
            tc.tc-variance-test-walks
            tc.tc-variance-test-lookups
            tc.tc-variance-test-dependencies
            tc.tc-variance-test-polls
            tc.tc-variance-test-allocated)))
      (tc.tc-variance-test-reset! 0)
      (ast.ast-node-pool-context-install! installed))))

(test
  variance-shared-dag-memo-worklist-oracle
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    (variance-dag-self-test)
    (ast.ast-node-pool-context-install! installed)))

(define (variance-source-context [source : (& str)]) : tc.TcContext
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [_install : unit (ast.ast-node-pool-context-install! pools)]
    [program : ast.AstProgram
      (match (parser.parse-ast-source-with-cfg-and-pools
        source
        (parser.compiler-cfg-empty)
        pools)
        [(Ok value) value]
        [(Err _) (io.panic "variance source fixture parse")])]
    (variance-context program pools)))

(cfg
  test
  (define (variance-four-values-self-test) : unit
    (let
      [ctx : tc.TcContext
        (variance-source-context
          "(defstruct Positive (:lifetimes r) (x (& r i64)))
         (defstruct Negative (:lifetimes r) (x (-> (& r i64) i64)))
         (defstruct Invariant (:lifetimes r) (x (MutPtr (& r i64))))
         (defstruct Mutable (:lifetimes r) (x (&mut program (& r i64))))
         (defstruct Phantom (:lifetimes r) (x i64))
         (defstruct Recursive (:lifetimes a b) (next (Box (Recursive b a))) (x (& a i64)))
         (defstruct MutualA (:lifetimes a b) (next (Box (MutualB b a))) (x (& a i64)))
         (defstruct MutualB (:lifetimes a b) (next (Box (MutualA b a))))")]
      [names
        (array
          "Positive"
          "Negative"
          "Invariant"
          "Mutable"
          "Phantom"
          "Recursive"
          "MutualA"
          "MutualB")]
      [answers : (Array i64 8) (array 1 2 3 3 0 1 1 0)]
      (for [mode (iterator.range 0 3)]
        (tc.tc-variance-test-reset! mode)
        (for [at (iterator.range 0 (array-length names))]
          (when
            (!=
              (variance-answer ctx (& (array-ref names at)) 0)
              (array-ref answers at))
            (io.panic "four-valued or recursive variance mismatch")))
        (when
          (or
            (!= (variance-answer ctx "Recursive" 1) 1)
            (!= (variance-answer ctx "MutualA" 1) 0)
            (!= (variance-answer ctx "MutualB" 1) 1))
          (io.panic "recursive permutation lost parameter identity")))
      (tc.tc-variance-test-reset! 0))))

(test
  variance-four-answers-and-recursive-permutations
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    (variance-four-values-self-test)
    (ast.ast-node-pool-context-install! installed)))

(define (variance-layer-context [depth : i64]) : tc.TcContext
  (let
    [source : String "(defstruct L0 (:lifetimes r) (value (& r i64)))\n"]
    (for [level (iterator.range 1 (+ depth 1))]
      (let
        [name : String (string.int->string level)]
        [previous : String (string.int->string (- level 1))]
        (set!
          source
          (str_cat.str-cat
            source
            "(defstruct L"
            name
            " (:lifetimes r) (value (Tuple (L"
            (string.copy (& previous))
            " r) (L"
            previous
            " r))))\n"))))
    (variance-source-context (& source))))

(cfg
  test
  (define (variance-layers-self-test) : unit
    (for [depth (iterator.range 0 17)]
      (let
        [ctx : tc.TcContext (variance-layer-context depth)]
        [name : String (str_cat.str-cat "L" (string.int->string depth))]
        (for [mode (iterator.range 0 3)]
          (tc.tc-variance-test-reset! mode)
          (when
            (!= (variance-answer ctx name 0) 1)
            (io.panic "nominal layers oracle mismatch")))))
    (for [depth (iterator.range 32 41)]
      (let
        [ctx : tc.TcContext (variance-layer-context depth)]
        [name : String (str_cat.str-cat "L" (string.int->string depth))]
        (tc.tc-variance-test-reset! 0)
        (when
          (or
            (!= (variance-answer ctx name 0) 1)
            (> tc.tc-variance-test-walks (* 2 (+ depth 1))))
          (io.panic "changed-answer worklist layers bound"))
        (io.print
          "LAYERS depth={} bodies={} walks={} lookup={} dependency={} polls={} allocated={}\n"
          depth
          tc.tc-variance-test-bodies
          tc.tc-variance-test-walks
          tc.tc-variance-test-lookups
          tc.tc-variance-test-dependencies
          tc.tc-variance-test-polls
          tc.tc-variance-test-allocated)))))

(test
  variance-nominal-layer-worklist
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    (variance-layers-self-test)
    (ast.ast-node-pool-context-install! installed)))

(cfg
  test
  (define (variance-context-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [ctx : tc.TcContext (variance-dag-context 0 0)]
      [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
      [job : tc.TcJobState (tc.tc-context-job-state ctx)]
      [other-view : tc.TcContext
        (tc.tc-context-with-program
          ctx
          (ast.ast-program (ast.ast-decl-list-new)))]
      [other-module : tc.TcContext
        (tc.tc-context-with-module-id ctx "caller" (ci.intern "caller"))]
      (tc.tc-variance-test-reset! 0)
      (when
        (!= (variance-answer ctx "Dag" 0) 1)
        (io.panic "initial variance answer"))
      (let
        [before : i64 tc.tc-variance-test-bodies]
        (when
          (or
            (!= (variance-answer other-module "Dag" 0) 1)
            (!= tc.tc-variance-test-bodies before))
          (io.panic "nominal owner failed to erase caller module")))
      (let
        [before : i64 tc.tc-variance-test-bodies]
        (when
          (or
            (!= (variance-answer other-view "Dag" 0) 1)
            (<= tc.tc-variance-test-bodies before))
          (io.panic "same owner with different program view reused a solution")))
      (tc.tc-lazy-import-stub-record-for-job!
        job
        (ci.intern "caller")
        (ci.intern "alias")
        (ci.intern "target")
        false)
      (let
        [before : i64 tc.tc-variance-test-bodies]
        (when
          (or
            (!= (variance-answer other-view "Dag" 0) 1)
            (<= tc.tc-variance-test-bodies before))
          (io.panic "lazy alias publication did not invalidate variance")))
      (tc.macro-segmented-program-begin!
        job
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new))
      (let
        [before : i64 tc.tc-variance-test-bodies]
        (when
          (or
            (!= (variance-answer ctx "Dag" 0) 1)
            (!= (variance-answer ctx "Dag" 0) 1)
            (<= (- tc.tc-variance-test-bodies before) 2))
          (io.panic "segmented program view failed to bypass completed cache")))
      (tc.macro-segmented-program-end! job)
      ;; Reindex the same declaration in place, preserving symbol-table size.
      (let
        [source : tc.TcContext
          (variance-source-context
            "(defstruct Dag (:lifetimes r) (value (-> (& r i64) i64)))")]
        [replacement : ast.AstDecl
          (match (csym.compiler-symbols-decl-at-index
            (tc.tc-context-symbols source)
            0)
            [(Ok value) value]
            [(Err message) (io.panic message)])]
        [_install : unit (ast.ast-node-pool-context-install! pools)]
        ;; Build the replacement in this pool so its child IDs have this owner.
        [parsed : ast.AstProgram
          (match (parser.parse-ast-source-with-cfg-and-pools
            "(defstruct Dag (:lifetimes r) (value (-> (& r i64) i64)))"
            (parser.compiler-cfg-empty)
            pools)
            [(Ok value) value]
            [(Err _) (io.panic "replacement parse")])]
        [decl : ast.AstDecl
          (match parsed
            [(Program ds) (ast.ast-decl-list-get (& (deref ds)) 0 replacement)])]
        [_changed : csym.CompilerSymbols
          (csym.compiler-symbols-index-decl
            (tc.tc-context-symbols-view ctx)
            (& decl)
            0
            (csym.compiler-symbol-root-module-id)
            0)]
        (when
          (!= (variance-answer ctx "Dag" 0) 2)
          (io.panic "same-size symbol replacement reused variance")))
      (ast.ast-node-pool-context-install! installed))))

(test
  variance-completed-cache-context-and-publication
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    (variance-context-self-test)
    (ast.ast-node-pool-context-install! installed)))

(cfg
  test
  (define (variance-pool-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [left : tc.TcContext (variance-dag-context 0 0)]
      [left-pools : ast.AstNodePoolContext (tc.tc-context-pools left)]
      [right-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 8 8)]
      [r : i64 (ci.intern "r")]
      (tc.tc-variance-test-reset! 0)
      (when
        (!= (variance-answer left "Dag" 0) 1)
        (io.panic "pool initial answer"))
      (ast.ast-node-pool-context-install! right-pools)
      ;; Left's field is Ref(r, 0). The same id now names a mutable referent
      ;; containing r, so this installed reader changes its full answer to Inv.
      (ast.ty-node-push (& (ast.AstType.MutRef (ci.intern "program") 1)))
      (ast.ty-node-push (& (ast.AstType.Ref r 2)))
      (ast.ty-node-push (& (ast.AstType.I64)))
      (when
        (!= (variance-answer left "Dag" 0) 3)
        (io.panic "equal type ids from another reader reused variance"))
      (ast.ast-node-pool-context-install! left-pools)
      (when
        (!= (variance-answer left "Dag" 0) 1)
        (io.panic "interleaved reader did not restore variance"))
      (ast.ty-node-pool-reset-to! 0)
      (ast.ty-node-push (& (ast.AstType.MutRef (ci.intern "program") 1)))
      (ast.ty-node-push (& (ast.AstType.Ref r 2)))
      (ast.ty-node-push (& (ast.AstType.I64)))
      (when
        (!= (variance-answer left "Dag" 0) 3)
        (io.panic "truncated/reused type ids reused variance"))
      (ast.ast-node-pool-context-install! installed))))

(test
  variance-reader-pool-identity-and-truncate-reuse
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    (variance-pool-self-test)
    (ast.ast-node-pool-context-install! installed)))

(cfg
  test
  (define (variance-alias-answer-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [ctx : tc.TcContext
        (variance-source-context
          "(module positive)
         (defstruct Target (:lifetimes r) (x (& r i64)))
         (module negative)
         (defstruct Target (:lifetimes r) (x (-> (& r i64) i64)))
         (module owner)
         (defstruct Holder (:lifetimes r) (x (selected.Target r)))")]
      [job : tc.TcJobState (tc.tc-context-job-state ctx)]
      [owner : i64 (ci.intern "owner")]
      [alias : i64 (ci.intern "selected")]
      [name : i64
        (csym.compiler-symbol-module-key-id-by-id owner (ci.intern "Holder"))]
      (tc.tc-variance-test-reset! 0)
      (tc.tc-lazy-import-stub-record-for-job!
        job
        owner
        alias
        (ci.intern "positive")
        false)
      (when
        (!=
          (tc.tc-variance-code
            (tc.tc-nominal-lifetime-variance-at ctx name 0 tc.TcNameIdList.Nil))
          1)
        (io.panic "initial alias variance"))
      (tc.tc-lazy-import-stub-record-for-job!
        job
        owner
        alias
        (ci.intern "negative")
        false)
      (when
        (!=
          (tc.tc-variance-code
            (tc.tc-nominal-lifetime-variance-at ctx name 0 tc.TcNameIdList.Nil))
          2)
        (io.panic "published alias reused old completed variance"))
      (tc.macro-segmented-program-begin!
        job
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new))
      (tc.tc-lazy-import-stub-record-for-job!
        job
        owner
        alias
        (ci.intern "positive")
        false)
      (when
        (!=
          (tc.tc-variance-code
            (tc.tc-nominal-lifetime-variance-at ctx name 0 tc.TcNameIdList.Nil))
          1)
        (io.panic "segmented alias publication reused completed variance"))
      (tc.macro-segmented-program-end! job)
      (when
        (!=
          (tc.tc-variance-code
            (tc.tc-nominal-lifetime-variance-at ctx name 0 tc.TcNameIdList.Nil))
          1)
        (io.panic "post-segment alias variance"))
      (ast.ast-node-pool-context-install! installed))))

(test
  variance-alias-publication-changes-equation-answer
  (variance-alias-answer-self-test))

(define (main) : i64
  (cfg
    test
    (begin
      (variance-dag-self-test)
      (variance-four-values-self-test)
      (variance-layers-self-test)
      (variance-context-self-test)
      (variance-pool-self-test)
      (variance-alias-answer-self-test)))
  42)