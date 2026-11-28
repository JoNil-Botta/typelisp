;; compiler_ast_types_tests.tl - White-box tests for the AST node pools, list
;; helpers and span oracles.
(cfg test (import stdlib.str_cat_runtime as str_cat))
(import stdlib.iterator)
(import compiler_intern as ci)
(cfg test (import compiler_intern_tests as intern_tests))
(import compiler_builtin_ids as cbi)
(cfg test (import stdlib.io))
(import stdlib.arena)
(import stdlib.string)
(import compiler_ast_types as ast)
(import compiler_owned_view as owned_view)

;; Layout queries need the struct names unqualified. Lint does not count a use
;; inside `(type ...)`.
;; lint-allow: unused-import
(import compiler_ast_types.AstExprBindingClause)

;; lint-allow: unused-import
(import compiler_ast_types.AstImportedSpmdCallable)

;; lint-allow: unused-import
(import compiler_ast_types.AstImportedSpmdSpecialization)
(cfg test (import stdlib.io))

;; Destructive intern fixtures own a separate table. A captured caller view
;; shares its arrays, so resetting that table and reinstalling its old scalar
;; cells would not restore it. Bodies must finish normally before restoration.
(defmacro (with-test-interns [body : unit ...]) : unit
  `(let
    [caller-interns : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [caller-builtins : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
    [fixture-interns : ci.InternCompatState (ci.intern-compat-state-new)]
    (ci.intern-compat-state-install! fixture-interns)
    (cbi.compiler-builtin-initialize-for-parse!)
    ,@body
    (ci.intern-compat-state-capture-from-globals! (&mut fixture-interns))
    (ci.intern-compat-state-install! caller-interns)
    (cbi.state-install! caller-builtins)
    (ci.intern-compat-state-release-structural-generations!
      (&mut fixture-interns))
    (unsafe
      (arena.destroy
        (arena.from-raw-handle
          (ci.intern-compat-state-persistent-arena fixture-interns))))))

(define (ast-lit-string-text [string-id : i64]) : String
  (ci.intern-str string-id))

(define (ast-spmd-param-class-list-box-shared-view
  [value : (Box ast.AstSpmdParamClassList)]) : ast.AstSpmdParamClassList
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of value) : (Ptr i64))))]
    (unsafe
      (ptr-read
        (int->ptr (cast address : u64) : (Ptr ast.AstSpmdParamClassList))))))

(define (ast-expr-node-pool-state-mark
  [pool : (& pool ast.AstExprNodePoolState)]) : i64
  (ast.ast-expr-node-pool-state-len pool))

(define (ast-expr-node-pool-state-reset-to-mark
  [pool : ast.AstExprNodePoolState]
  [mark : i64]) : ast.AstExprNodePoolState
  (ast.ast-expr-node-pool-state-reset-to pool mark))

(define (ty-node-pool-capacity) : i64
  (ast.ty-node-pool-capacity))

;; The AST smoke fixtures inspect and configure the real canonical index.
(define (ast-type-node-pool-test-cursor
  [pool : (& pool ast.AstTypeNodePoolState)]) : (MutPtr ast.AstTypePoolCursor)
  (unsafe
    (int->ptr pool.revision-cell : (MutPtr ast.AstTypePoolCursor))))

(define (ast-type-node-pool-test-dedup-capacity
  [pool : (& pool ast.AstTypeNodePoolState)]) : i64
  (unsafe
    (deref (ast-type-node-pool-test-cursor pool)).dedup-capacity))

(define (ast-type-node-pool-test-dedup-count
  [pool : (& pool ast.AstTypeNodePoolState)]) : i64
  (unsafe
    (deref (ast-type-node-pool-test-cursor pool)).dedup-count))

(define (ast-type-node-pool-test-dedup-slot
  [pool : (& pool ast.AstTypeNodePoolState)]
  [index : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-offset
        (deref (ast-type-node-pool-test-cursor pool)).dedup-slots
        index))))

(define (ast-type-node-pool-test-set-dedup-capacity!
  [pool : (& pool ast.AstTypeNodePoolState)]
  [capacity : i64]) : unit
  (unsafe
    (let
      [cursor : (MutPtr ast.AstTypePoolCursor)
        (ast-type-node-pool-test-cursor pool)]
      (in-arena
        (arena.from-raw-handle pool.base-arena)
        (set! (deref cursor).dedup-slots (ast.ty-node-dedup-slots-new capacity)))
      (set! (deref cursor).dedup-capacity capacity))))

(define (ast-type-node-pool-state-exhausted?
  [pool : (& pool ast.AstTypeNodePoolState)]) : bool
  pool.exhausted)

(define (ast-type-node-pool-state-mark
  [pool : (& pool ast.AstTypeNodePoolState)]) : i64
  (ast.ast-type-node-pool-state-len pool))

(define (ast-type-node-pool-state-reset-to-mark
  [pool : ast.AstTypeNodePoolState]
  [mark : i64]) : ast.AstTypeNodePoolState
  (ast.ast-type-node-pool-state-reset-to pool mark))

(define (ast-type-node-pool-state-set!
  [pool : ast.AstTypeNodePoolState]
  [id : i64]
  [node : ast.AstType]) : ast.AstTypeNodePoolState
  (let
    [count : i64 (ast.ast-type-node-pool-state-len pool)]
    [base-arena : i64 pool.base-arena]
    [persistent : ast.AstType
      (in-arena
        (unsafe
          (arena.from-raw-handle base-arena))
        (ast.ty-node-persist (& node)))]
    [biased-base : i64
      (unsafe
        (ptr-read
          (ptr-offset (int->ptr pool.segment-bases : (Ptr i64)) (shr id 10))))]
    [dest : (MutPtr i64)
      (unsafe
        (int->ptr
          (+ biased-base (* id (ast.ast-type-node-bytes)))
          : (MutPtr i64)))]
    [source : (Ptr i64)
      (unsafe
        (ptr-cast (ptr-addr-of persistent) : (Ptr i64)))]
    (unsafe
      (ptr-write! dest (ptr-read source))
      (ptr-write! (ptr-offset dest 1) (ptr-read (ptr-offset source 1)))
      (ptr-write! (ptr-offset dest 2) (ptr-read (ptr-offset source 2))))
    ;; Overwriting an existing id can make hash entries stale. Clear the
    ;; shared table and let future pushes repopulate it from new candidates.
    (ast.ast-type-node-pool-state-reset-to pool count)))

(define (ast-node-pool-context-expr-canonical-span
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]) : ast.AstMaybeSourceSpan
  (let
    [bound-1 (ast.ast-expr-pool-cell-read pools.expr-pool)]
    (ast.ast-expr-node-pool-state-canonical-span bound-1 id)))

(define (ast-ty-c-func
  [args : ast.AstTypeList]
  [ret : ast.AstType]
  [mode : ast.AstCFunctionMode]) : ast.AstType
  (CFunc
    (ast.ast-node-pool-reader-type-push (& (ast.ast-ty-func args (& ret))))
    mode))

(define (ast-expr-clause-list-tail [items : ast.AstExprClauseList]) : ast.AstExprClauseList
  (let
    [out : ast.AstExprClauseList
      (ast.ast-expr-clause-list-with-capacity (- items.len 1))]
    (for [index (iterator.range 1 items.len)]
      (ast.ast-expr-clause-list-push
        (&mut out)
        (ast.ast-expr-clause-list-get
          (& items)
          index
          (ast.ast-expr-clause-fallback))))
    out))

(define (ast-expr-binding-clause-list-tail
  [items : ast.AstExprBindingClauseList]) : ast.AstExprBindingClauseList
  (let
    [out : ast.AstExprBindingClauseList
      (ast.ast-expr-binding-clause-list-with-capacity (- items.len 1))]
    (for [index (iterator.range 1 items.len)]
      (ast.ast-expr-binding-clause-list-push
        (&mut out)
        (ast.ast-expr-binding-clause-list-get
          (& items)
          index
          (ast.ast-expr-binding-clause-fallback))))
    out))

;; The AstType-taking constructors intern the type themselves, so call sites
;; can pass a literal type directly.
;; The `-id` twins below are for walks that already hold an AstTypeId and
;; would otherwise round-trip it through `ty-node-get`/`ty-node-push`.
(define (ast-expr-ann [expr : i64] [ty : ast.AstType]) : i64
  (ast.ast-node-push (Ann expr (ast.ty-node-push (& ty)))))

(define (ast-expr-quasiquote [inner : i64]) : i64
  (ast.ast-node-push (Quasiquote inner)))

(define (ast-expr-break) : i64
  (ast.ast-node-push (Break)))

(define (ast-expr-continue) : i64
  (ast.ast-node-push (Continue)))

(define (ast-decl-list-empty? [v : (& v ast.AstDeclList)]) : bool
  (= (ast.ast-decl-list-len v) 0))

(define (ast-decl-list-tail [items : (& items ast.AstDeclList)]) : ast.AstDeclList
  (let
    [items : ast.AstDeclList
      (owned_view.compiler-owned-reference-shared-view items)]
    (if (<= (ast.ast-decl-list-len (& items)) 0)
      (ast.ast-decl-list-new)
      (ast.AstDeclList items.slots (+ items.offset 1) (- items.len 1) false))))

(define (ast-decl-module-list-get
  [v : (& v ast.AstDeclModuleList)]
  [index : i64]
  [fallback : String]) : String
  (if (and (>= index 0) (< index (ast.ast-decl-module-list-len v)))
    (ci.intern-str (array-ref v.slots (+ v.offset index)))
    fallback))

(define (ast-expr-tag [expr : ast.AstExpr]) : i64
  (match expr
    [(Spanned _ _) 1]
    [(Literal _) 2]
    [(Var _) 3]
    [(Binary _ _ _) 4]
    [(Unary _ _) 5]
    [(Call _ _) 6]
    [(If _ _ _) 7]
    [(Let _) 8]
    [(Lambda _) 9]
    [(Tuple _) 10]
    [(TupleRef _ _) 11]
    [(Array _) 12]
    [(DynArray _) 74]
    [(FixedMakeArray _ _) 81]
    [(MakeArray _ _) 13]
    [(ArrayRef _ _) 14]
    [(ArraySet _ _ _) 15]
    [(ArrayTake _ _ _) 75]
    [(ArrayPush _ _) 41]
    [(StringRef _ _) 16]
    [(While _ _) 17]
    [(ForOwnedState _) 77]
    [(ForOwnedStep _) 78]
    [(MacroExpansion _ _ _) 79]
    [(Replace _ _) 80]
    [(Begin _) 18]
    [(Unsafe _) 32]
    [(Set _ _) 19]
    [(Ann _ _) 20]
    [(Cast _ _) 21]
    [(Borrow _ _ _) 40]
    [(Match _) 22]
    [(Foreach _) 23]
    [(StructGet _ _) 24]
    [(or (StructSet _ _ _) (BracketClause _)) 63]
    [(WithRegion _ _) 25]
    [(or (WithEscape _ _) (Return _)) 48]
    [(WithScratch _) 67]
    [(or (InArena _ _) (BoxTake _)) 65]
    [(TypeLiteral _) 26]
    [(Comptime _) 27]
    [(SpmdReduce _) 28]
    [(SpmdScan _) 68]
    [(SpmdCompact _) 82]
    [(or (SpmdBroadcast _ _) (BinaryData _)) 64]
    [(SpmdShuffle _ _) 71]
    [(SpmdProgramIndex) 69]
    [(SpmdProgramCount) 70]
    [(Try _) 29]
    [(Break) 72]
    [(Continue) 73]
    [(PtrNull _) 30]
    [(PtrNullCheck _) 31]
    [(WithResource _) 33]
    [(PtrAddrOf _) 62]
    [(PtrRead _) 34]
    [(PtrWrite _ _) 35]
    [(PtrOffset _ _) 36]
    [(PtrCast _ _) 37]
    [(PtrToInt _) 38]
    [(IntToPtr _ _) 39]
    [(Box _) 42]
    [(BoxGet _) 43]
    [(BoxSet _ _) 66]
    [(Quote _) 44]
    [(Quasiquote _) 45]
    [(Unquote _) 46]
    [(UnquoteSplicing _) 47]
    [(StringData _) 49]
    [(StringFromBytes _ _) 50]
    [(ArrayData _) 51]
    [(ProgramArgc) 52]
    [(ProgramArgv) 53]
    [(ProgramEnvp) 54]
    [(CpuIdEax _ _) 55]
    [(CpuIdEbx _ _) 56]
    [(CpuIdEcx _ _) 57]
    [(CpuIdEdx _ _) 58]
    [(Xgetbv _) 59]
    [(Syscall _) 60]
    [(ForeachActive _ _) 83]
    [(LaneValue _) 84]
    [(CloneOut _ _) 85]))

(define (ast-decl-tag [decl : ast.AstDecl]) : i64
  (match decl
    [(Def decl-meta _ _ _) 1]
    [(DefFn decl-meta _ _ _ _ _) 2]
    [(DefMacro decl-meta _ _ _ _) 10]
    [(Extern decl-meta _ _ _ _) 3]
    [(DefEnum decl-meta _ _ _) 4]
    [(DefStruct decl-meta _ _ _ _) 5]
    [(Import decl-meta _) 6]
    [(Test _ _ _ _) 7]
    [(Module _) 9]
    [(ModuleBody _ _) 18]
    [(IncludeStr _ _) 12]
    [(IncludeStrComptime _ _) 19]
    [(IncludeStrLzss _ _) 20]
    [(Unsafe _) 13]
    [(DefEnumLifetimes decl-meta _ _ _ _) 14]
    [(DefStructLifetimes decl-meta _ _ _ _ _) 15]
    [(DefDispatch decl-meta _ _) 16]
    [(IncludeBin _ _) 17]))

(define (compiler-ast-begin-expr? [expr : ast.AstExpr]) : bool
  (match expr
    [(Begin _) true]
    [_ false]))

(define (compiler-ast-nested-pattern-box-ok? [pattern : ast.AstPattern]) : bool
  (match pattern
    [(Variant name args-box)
      (let
        [args : ast.AstPatternList (deref args-box)]
        (and
          (= name cbi.compiler-builtin-id-fix-Some)
          (= args.len 1)
          (match (ast.ast-pattern-list-get
            (& args)
            0
            (ast.ast-pattern-fallback))
            [(Tuple items-box)
              (let
                [items : ast.AstPatternList (deref items-box)]
                (and
                  (= items.len 2)
                  (match (ast.ast-pattern-list-get
                    (& items)
                    0
                    (ast.ast-pattern-fallback))
                    [(Binding bind-name)
                      (= bind-name cbi.compiler-builtin-id-fix-item)]
                    [_ false])
                  (match (ast.ast-pattern-list-get
                    (& items)
                    1
                    (ast.ast-pattern-fallback))
                    [(Wildcard) true]
                    [_ false])))]
            [_ false])))]
    [_ false]))

(define (compiler-ast-single-arm-box-ok? [arms : ast.AstMatchArmList]) : bool
  (and
    (= (ast.ast-match-arm-list-len (& arms)) 1)
    (match (ast.ast-match-arm-list-get (& arms) 0 (ast.ast-match-arm-fallback))
      [(Arm pattern body-id)
        (let
          [body : ast.AstExpr (ast.ast-node-get body-id)]
          (and
            (compiler-ast-nested-pattern-box-ok? pattern)
            (compiler-ast-begin-expr? body)))]
      [_ false])))

(define (compiler-ast-nested-expr-box-ok? [expr : ast.AstExpr]) : bool
  (match expr
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body-box)
          (let
            [body : ast.AstExpr (ast.ast-node-get body-box)]
            (and
              (= (ast.ast-let-binding-list-len (& bindings)) 1)
              (match (ast.ast-let-binding-list-get
                (& bindings)
                0
                (ast.ast-let-binding-fallback))
                [(Binding name _ init-box)
                  (let
                    [init : ast.AstExpr (ast.ast-node-get init-box)]
                    (and
                      (= name cbi.compiler-builtin-id-fix-x)
                      (compiler-ast-begin-expr? init)))]
                [_ false])
              (match body
                [(If cond-box then-box else-box)
                  (let
                    [cond : ast.AstExpr (ast.ast-node-get cond-box)]
                    [then-expr : ast.AstExpr (ast.ast-node-get then-box)]
                    [else-expr : ast.AstExpr (ast.ast-node-get else-box)]
                    (and
                      (match cond
                        [(Var name) (string.eq (ci.intern-str name) "cond")]
                        [_ false])
                      (match then-expr
                        [(Match match-box)
                          (match (__tl-box-place match-box)
                            [(Match scrut-box arms)
                              (let
                                [scrut : ast.AstExpr
                                  (ast.ast-node-get scrut-box)]
                                (and
                                  (match scrut
                                    [(Var name)
                                      (string.eq (ci.intern-str name) "input")]
                                    [_ false])
                                  (compiler-ast-single-arm-box-ok? arms)))])]
                        [_ false])
                      (compiler-ast-begin-expr? else-expr)))]
                [_ false])))])]
    [_ false]))

(define (compiler-ast-expr-pattern-box-smoke?) : bool
  (let
    [one : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 1)))]
    [two : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 2)))]
    [begin-expr : i64
      (ast.ast-node-push
        (Begin
          (ast.ast-expr-cons
            one
            (& (ast.ast-expr-cons two (& (ast.ast-expr-list-new)))))))]
    [bindings : ast.AstLetBindingList
      (ast.ast-let-binding-cons
        (&
          (ast.ast-let-binding-id cbi.compiler-builtin-id-fix-x (No) begin-expr))
        (& (ast.ast-let-binding-list-new)))]
    [tuple-pattern : ast.AstPattern
      (ast.ast-pat-tuple
        (ast.ast-pattern-cons
          (& (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-item))
          (&
            (ast.ast-pattern-cons (& (Wildcard)) (& (ast.ast-pattern-list-new))))))]
    [variant-pattern : ast.AstPattern
      (ast.ast-pat-variant-id
        cbi.compiler-builtin-id-fix-Some
        (ast.ast-pattern-cons (& tuple-pattern) (& (ast.ast-pattern-list-new))))]
    [arms : ast.AstMatchArmList
      (ast.ast-match-arm-cons
        (& (ast.ast-match-arm variant-pattern begin-expr))
        (& (ast.ast-match-arm-list-new)))]
    [match-expr : i64
      (ast.ast-expr-match
        (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-input))
        arms)]
    [nested : i64
      (ast.ast-expr-let
        bindings
        (ast.ast-expr-if
          (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-cond))
          match-expr
          begin-expr))]
    (compiler-ast-nested-expr-box-ok? (ast.ast-node-get nested))))

(define (compiler-ast-decl-def-lit-ok?
  [decl : ast.AstDecl]
  [want-name-id : i64]
  [want-value : i64]) : bool
  (match decl
    [(Def decl-meta name _ value-box)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (and
          (= name want-name-id)
          (match value
            [(Literal (Int actual _)) (= actual want-value)]
            [_ false])))]
    [_ false]))

(define (compiler-ast-nested-decl-box-ok?
  [decl : ast.AstDecl]
  [generated-name-id : i64]) : bool
  (match decl
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (and
          (ast.ast-decl-comptime-only? inner)
          (compiler-ast-decl-def-lit-ok? inner generated-name-id 7)))]
    [_ false]))

(define (compiler-ast-decl-program-box-smoke?) : bool
  (let
    [generated-name-id : i64 (ci.intern-generated-name "generated")]
    [runtime-name-id : i64 (ci.intern-generated-name "runtime")]
    [generated : ast.AstDecl
      (ast.ast-decl-def-id
        generated-name-id
        (Some (I64))
        (ast.ast-node-push (Literal (ast.ast-lit-int 7))))]
    [runtime : ast.AstDecl
      (ast.ast-decl-def-id
        runtime-name-id
        (Some (I64))
        (ast.ast-node-push (Literal (ast.ast-lit-int 9))))]
    [nested : ast.AstDecl
      (ast.ast-decl-unsafe (ast.ast-decl-comptime-decl generated))]
    [program : ast.AstProgram
      (ast.ast-program
        (ast.ast-decl-cons
          (& nested)
          (& (ast.ast-decl-cons (& runtime) (& (ast.ast-decl-list-new))))))]
    (match program
      [(Program decls-box)
        (let
          [decls : ast.AstDeclList (deref decls-box)]
          (match (ast.ast-decl-list-step decls)
            [(Cons first rest-box)
              (let
                [rest : ast.AstDeclList rest-box]
                (and
                  (compiler-ast-nested-decl-box-ok? first generated-name-id)
                  (match (ast.ast-decl-list-step rest)
                    [(Cons second done-box)
                      (let
                        [done : ast.AstDeclList done-box]
                        (and
                          (compiler-ast-decl-def-lit-ok?
                            second
                            runtime-name-id
                            9)
                          (match (ast.ast-decl-list-step done)
                            [(Nil) true]
                            [_ false])))]
                    [_ false])))]
            [_ false]))])))

;; The ty-node pool grows on demand (see ast-type-pool-cursor-cover!) rather
;; than failing closed, so a push at capacity installs another segment and
;; assigns the next sequential id. Fill every installed slot with distinct
;; nodes (a truncate cannot extend the live length), then verify that growth.
(define (compiler-ast-type-pool-exhaustion-smoke?) : bool
  (let
    [capacity : i64 (ty-node-pool-capacity)]
    (ast.ty-node-pool-reset!)
    (while (< (ast.ty-node-pool-len) capacity)
      (begin
        (ast.ty-node-push (& (ast.AstType.Var (ast.ty-node-pool-len))))
        unit))
    (let
      [id : i64 (ast.ty-node-push (& (ast.AstType.I64)))]
      [len : i64 (ast.ty-node-pool-len)]
      [exhausted : bool (ast.ty-node-pool-exhausted?)]
      [grew : bool (> (ty-node-pool-capacity) capacity)]
      (ast.ty-node-pool-reset!)
      (and (not exhausted) (= id capacity) (= len (+ capacity 1)) grew))))

(define (compiler-ast-type-dedup-smoke?) : bool
  (ast.ty-node-pool-reset!)
  (let
    [first-i64 : i64 (ast.ty-node-push (& (I64)))]
    [first-len : i64 (ast.ty-node-pool-len)]
    [second-i64 : i64 (ast.ty-node-push (& (I64)))]
    [second-len : i64 (ast.ty-node-pool-len)]
    [first-array : i64 (ast.ty-node-push (& (ast.ast-ty-array (& (I64)) 4)))]
    [array-len : i64 (ast.ty-node-pool-len)]
    [second-array : i64 (ast.ty-node-push (& (ast.ast-ty-array (& (I64)) 4)))]
    [final-len : i64 (ast.ty-node-pool-len)]
    [first-bytes : i64 (ast.ty-node-push (& (Bytes)))]
    [bytes-len : i64 (ast.ty-node-pool-len)]
    [second-bytes : i64 (ast.ty-node-push (& (Bytes)))]
    [second-bytes-len : i64 (ast.ty-node-pool-len)]
    [str-ty : i64 (ast.ty-node-push (& (Str)))]
    [str-len : i64 (ast.ty-node-pool-len)]
    [first-slice : i64 (ast.ty-node-push (& (ast.ast-ty-slice (& (I64)))))]
    [slice-len : i64 (ast.ty-node-pool-len)]
    [second-slice : i64 (ast.ty-node-push (& (ast.ast-ty-slice (& (I64)))))]
    [second-slice-len : i64 (ast.ty-node-pool-len)]
    [first-dyn-array : i64
      (ast.ty-node-push (& (ast.ast-ty-dyn-array (& (I64)))))]
    [dyn-array-len : i64 (ast.ty-node-pool-len)]
    [nested-slice : i64
      (ast.ty-node-push (& (ast.ast-ty-slice (& (ast.ast-ty-slice (& (I64)))))))]
    [nested-slice-again : i64
      (ast.ty-node-push (& (ast.ast-ty-slice (& (ast.ast-ty-slice (& (I64)))))))]
    [ok : bool
      (and
        (= first-i64 second-i64)
        (= first-len 1)
        (= second-len 1)
        (= first-array second-array)
        (= array-len 2)
        (= final-len 2)
        (= first-bytes second-bytes)
        (= bytes-len 3)
        (= second-bytes-len 3)
        (not (= first-bytes str-ty))
        (= str-len 4)
        (= first-slice second-slice)
        (= slice-len 5)
        (= second-slice-len 5)
        (not (= first-slice first-dyn-array))
        (= dyn-array-len 6)
        (= nested-slice nested-slice-again)
        (= (ast.ast-type-tag (& (ast.ty-node-get first-slice))) 37)
        (not
          (=
            (ast.ty-node-hash-value (& (ast.ty-node-get first-slice)))
            (ast.ty-node-hash-value (& (ast.ty-node-get first-dyn-array))))))]
    (ast.ty-node-pool-reset!)
    ok))

(define (compiler-ast-spmd-metadata-clone-smoke?) : bool
  (let
    [classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    [specializations : ast.AstSpmdSpecializationList
      (ast.ast-spmd-specialization-list-new)]
    (ast.ast-spmd-param-class-list-push (&mut classes) Varying)
    (ast.ast-spmd-param-class-list-push (&mut classes) Uniform)
    (ast.ast-spmd-specialization-list-push
      (&mut specializations)
      (ast.AstSpmdSpecialization 8 (box classes) Varying 0))
    (let
      [copied : ast.AstFnMetadata
        (ast.ast-fn-metadata-clone (& (SpmdCallable (box specializations))))]
      (match (ast.ast-fn-metadata-spmd-callable (& copied))
        [(Callable copied-items)
          (let
            [fallback : ast.AstSpmdSpecialization
              (ast.AstSpmdSpecialization
                2
                (box (ast.ast-spmd-param-class-list-new))
                Unit
                -1)]
            [item : ast.AstSpmdSpecialization
              (ast.ast-spmd-specialization-list-get (& copied-items) 0 fallback)]
            [copied-classes : ast.AstSpmdParamClassList
              (ast-spmd-param-class-list-box-shared-view item.args)]
            (and
              (= (ast.ast-spmd-specialization-list-len (& copied-items)) 1)
              (= item.lanes 8)
              (= item.index-param 0)
              (match item.result
                [(Varying) true]
                [_ false])
              (match (ast.ast-spmd-param-class-list-get
                (& copied-classes)
                0
                Uniform)
                [(Varying) true]
                [_ false])
              (match (ast.ast-spmd-param-class-list-get
                (& copied-classes)
                1
                Varying)
                [(Uniform) true]
                [_ false])))]
        [_ false]))))

(define (compiler-ast-imported-spmd-metadata-clone-smoke?) : bool
  (let
    [abi : ci.InternId (ci.intern-id-from-renderable 1)]
    [backend : ci.InternId (ci.intern-id-from-renderable 2)]
    [args : ci.InternId (ci.intern-id-from-renderable 3)]
    [result : ci.InternId (ci.intern-id-from-renderable 4)]
    [symbol : ci.InternId (ci.intern-id-from-renderable 5)]
    [signature : ci.InternId (ci.intern-id-from-renderable 6)]
    [name-id : ci.InternId (ci.intern-id-from-renderable 7)]
    [specializations : ast.AstImportedSpmdSpecializationList
      (ast.ast-imported-spmd-specialization-list-new)]
    [callables : ast.AstImportedSpmdCallableList
      (ast.ast-imported-spmd-callable-list-new)]
    (ast.ast-imported-spmd-specialization-list-push
      (&mut specializations)
      (ast.AstImportedSpmdSpecialization abi backend 8 args result 0 symbol))
    (ast.ast-imported-spmd-callable-list-push
      (&mut callables)
      (ast.AstImportedSpmdCallable signature specializations))
    (match (ast.ast-imported-spmd-metadata-clone
      (& (Package "fixture" "1.0.0" name-id (box callables))))
      [(Package owner version name copied-callables)
        (let
          [copied : ast.AstImportedSpmdCallableList (deref copied-callables)]
          [callable : ast.AstImportedSpmdCallable
            (ast.ast-imported-spmd-callable-list-get
              (& copied)
              0
              (ast.ast-imported-spmd-callable-fallback))]
          [copied-specializations : ast.AstImportedSpmdSpecializationList
            callable.specializations]
          [item : ast.AstImportedSpmdSpecialization
            (ast.ast-imported-spmd-specialization-list-get
              (& copied-specializations)
              0
              (ast.ast-imported-spmd-specialization-fallback))]
          (and
            (string.eq owner "fixture")
            (string.eq version "1.0.0")
            (ci.intern-id-eq? name name-id)
            (= (ast.ast-imported-spmd-callable-list-len (& copied)) 1)
            (ci.intern-id-eq? callable.signature signature)
            (=
              (ast.ast-imported-spmd-specialization-list-len
                (& copied-specializations))
              1)
            (= item.lanes 8)
            (ci.intern-id-eq? item.symbol symbol)))]
      [(No) false]
      [(Inline _ _ _) false])))

;; Pin `ast-expr-node-bytes` / `ast-type-node-bytes` to the compiler's REAL
;; inline array stride.
;;
;; `size-of` on an enum reports the handle width, so the two stride constants
;; are stated by hand and consumed by unchecked pointer arithmetic in every
;; pool load and store. If a constant ever disagrees with the layout the
;; compiler actually gives `(__tl_dyn-array AstExpr)` /
;; `(__tl_dyn-array AstType)`, every pool access computes a wrong address and
;; the failure is silent memory corruption, not a type error.
;;
;; The check plays the two representations against each other: `array-set!`
;; addresses a slot with the compiler's own stride, while the reader below
;; addresses it as `base + index * <the constant>`. They agree only when the
;; constant is right. Distinct payloads at both indices mean an off-by-one
;; stride cannot alias into a passing answer.
(define (ast-expr-node-stride-pinned?) : bool
  (let
    [slots : (__tl_dyn-array ast.AstExpr) (__tl_make-array ast.AstExpr 2)]
    [_w0 : unit (set! (array-ref slots 0) (ast.AstExpr.Var 0))]
    [_w1 : unit (set! (array-ref slots 1) (ast.AstExpr.Comptime 987654321))]
    [base : i64
      (cast
        (unsafe
          (ptr->int (ptr-cast (__tl_array-data slots) : (Ptr u8))))
        : i64)]
    (and
      (match (unsafe
        (ptr-read
          (int->ptr
            (+ base (* 0 (ast.ast-expr-node-bytes)))
            : (Ptr ast.AstExpr))))
        [(Var name) (= name 0)]
        [_ false])
      (match (unsafe
        (ptr-read
          (int->ptr
            (+ base (* 1 (ast.ast-expr-node-bytes)))
            : (Ptr ast.AstExpr))))
        [(Comptime inner) (= inner 987654321)]
        [_ false]))))

(define (ast-type-node-stride-pinned?) : bool
  (let
    [slots : (__tl_dyn-array ast.AstType) (__tl_make-array ast.AstType 2)]
    [_w0 : unit (set! (array-ref slots 0) (ast.AstType.I64))]
    [_w1 : unit (set! (array-ref slots 1) (ast.AstType.Array 123456789 42))]
    [base : i64
      (cast
        (unsafe
          (ptr->int (ptr-cast (__tl_array-data slots) : (Ptr u8))))
        : i64)]
    (and
      (match (unsafe
        (ptr-read
          (int->ptr
            (+ base (* 0 (ast.ast-type-node-bytes)))
            : (Ptr ast.AstType))))
        [(I64) true]
        [_ false])
      (match (unsafe
        (ptr-read
          (int->ptr
            (+ base (* 1 (ast.ast-type-node-bytes)))
            : (Ptr ast.AstType))))
        [(Array elem count) (and (= elem 123456789) (= count 42))]
        [_ false]))))

(define (ast-node-stride-pinned?) : bool
  (and (ast-expr-node-stride-pinned?) (ast-type-node-stride-pinned?)))

(define (compiler-ast-smoke) : i64
  (let
    [_builtin-init : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [string-ty : ast.AstType (String)]
    [arg-tys : ast.AstTypeList
      (ast.ast-type-cons
        (& (I64))
        (& (ast.ast-type-cons (& string-ty) (& (ast.ast-type-list-new)))))]
    [ret-ty : ast.AstType
      (ast.ast-ty-ref
        (ci.intern-generated-name "r")
        (& (ast.ast-ty-ptr (& (ast.ast-ty-array (& (I64)) 4)))))]
    [fn-ty : ast.AstType (ast.ast-ty-func arg-tys (& ret-ty))]
    [nested-ty-ok? : bool
      (match (ast.ast-place-shared-view fn-ty)
        [(Func _ ret)
          (match (ast.ty-node-get ret)
            [(Ref region ptr)
              (and
                (string.eq (ci.intern-str region) "r")
                (match (ast.ty-node-get ptr)
                  [(Ptr array)
                    (match (ast.ty-node-get array)
                      [(Array elem count)
                        (and
                          (= count 4)
                          (match (ast.ty-node-get elem)
                            [(I64) true]
                            [_ false]))]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [lit : ast.AstLiteral (ast.ast-lit-int 41)]
    [one : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 1)))]
    [expr : i64
      (ast.ast-expr-binary (Add) (ast.ast-node-push (Literal lit)) one)]
    [nested-expr-pattern-ok? : bool (compiler-ast-expr-pattern-box-smoke?)]
    [decl-program-ok? : bool (compiler-ast-decl-program-box-smoke?)]
    [type-dedup-ok? : bool (compiler-ast-type-dedup-smoke?)]
    [pool-exhaustion-ok? : bool (compiler-ast-type-pool-exhaustion-smoke?)]
    [node-stride-ok? : bool (ast-node-stride-pinned?)]
    [spmd-metadata-clone-ok? : bool (compiler-ast-spmd-metadata-clone-smoke?)]
    [imported-spmd-metadata-clone-ok? : bool
      (compiler-ast-imported-spmd-metadata-clone-smoke?)]
    [param : ast.AstParam
      (ast.ast-param-id cbi.compiler-builtin-id-fix-x (I64) false)]
    [params : ast.AstParamList
      (ast.ast-param-cons (& param) (& (ast.ast-param-list-new)))]
    [decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        cbi.compiler-builtin-id-fix-main
        params
        (I64)
        expr)]
    [program : ast.AstProgram
      (ast.ast-program (ast.ast-decl-cons (& decl) (& (ast.ast-decl-list-new))))]
    (match program
      [(Program _)
        (if (and
          nested-ty-ok?
          nested-expr-pattern-ok?
          decl-program-ok?
          type-dedup-ok?
          pool-exhaustion-ok?
          node-stride-ok?
          spmd-metadata-clone-ok?
          imported-spmd-metadata-clone-ok?)
          (+
            (ast.ast-type-tag (& fn-ty))
            (+ (ast-expr-tag (ast.ast-node-get expr)) (ast-decl-tag decl)))
          0)])))

(cfg
  test
  (test
    compiler-ast-name-layout
    (unless
      (and
        (= (intern_tests.intern-id-size) 4)
        (= (intern_tests.intern-syntax-id-size) 8)
        (= (comptime (size-of (type AstExprBindingClause))) 88)
        (= (comptime (size-of (type AstImportedSpmdSpecialization))) 40)
        (= (comptime (size-of (type AstImportedSpmdCallable))) 32))
      (io.panic
        (str_cat.str-cat
          "compiler AST name layout changed: InternId="
          (string.int->string (intern_tests.intern-id-size))
          " InternSyntaxId="
          (string.int->string (intern_tests.intern-syntax-id-size))
          " binding-clause="
          (string.int->string (comptime (size-of (type AstExprBindingClause))))
          " specialization="
          (string.int->string
            (comptime (size-of (type AstImportedSpmdSpecialization))))
          " callable="
          (string.int->string
            (comptime (size-of (type AstImportedSpmdCallable)))))))))

(cfg
  test
  (test
    compiler-ast-aggregate-marker-wrappers
    (let
      [unmarked : ast.AstDecl
        (ast.ast-decl-def-struct-id
          (ci.intern-generated-name "Marked")
          Default
          No
          (ast.ast-field-def-list-new))]
      [marked : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-place-shared-view unmarked)
          1)]
      [comptime-decl : ast.AstDecl
        (ast.ast-decl-comptime-decl (ast.ast-place-shared-view marked))]
      [generated-decl : ast.AstDecl
        (ast.ast-decl-comptime-decl-with-meta
          No
          (ast.ast-place-shared-view marked))]
      [unsafe-decl : ast.AstDecl
        (ast.ast-decl-unsafe (ast.ast-place-shared-view comptime-decl))]
      [cleared-comptime : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-place-shared-view generated-decl)
          0)]
      [before : arena.ArenaMark (arena.mark)]
      [same-runtime : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers unmarked 0)]
      [same-marked : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-place-shared-view marked)
          1)]
      [same-comptime : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-place-shared-view generated-decl)
          1)]
      [same-unsafe : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-place-shared-view unsafe-decl)
          1)]
      [cleared-runtime : ast.AstDecl
        (ast.ast-decl-with-aggregate-markers
          (ast.ast-place-shared-view marked)
          0)]
      [after : arena.ArenaMark (arena.mark)]
      (unless
        (and
          (arena.mark-eq? before after)
          (not (ast.ast-decl-must-use? same-runtime))
          (ast.ast-decl-must-use? same-marked)
          (ast.ast-decl-must-use? same-comptime)
          (ast.ast-decl-must-use? same-unsafe)
          (not (ast.ast-decl-must-use? cleared-runtime))
          (not (ast.ast-decl-must-use? cleared-comptime))
          (ast.ast-decl-comptime-only? cleared-comptime)
          (ast.ast-decl-must-use? marked)
          (ast.ast-decl-must-use? comptime-decl)
          (ast.ast-decl-must-use? generated-decl)
          (ast.ast-decl-must-use? unsafe-decl)
          (ast.ast-decl-comptime-only? unsafe-decl))
        (io.panic "aggregate marker wrapper semantics or allocation changed")))))

;; In-place writes below the protected floor are undone by the restore (#8757).
;; Two writes to one persistent node restore to its parsed form, a write above
;; the floor is not journaled and survives, and a floor of 0 drops the journal.
(define (compiler-ast-protected-restore-ok?) : bool
  (let
    [base : i64 (ast.ast-node-pool-len)]
    [kept : i64 (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-input))]
    [_floor : unit (ast.ast-node-protected-floor-set! (ast.ast-node-pool-len))]
    [above : i64 (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-cond))]
    (ast.ast-node-set! kept (Literal (ast.ast-lit-int 7)))
    (ast.ast-node-set! kept (Literal (ast.ast-lit-int 8)))
    (ast.ast-node-set! above (Literal (ast.ast-lit-int 9)))
    (let
      [journaled : i64 (ast.ast-node-protected-journal-count)]
      [rewritten : bool
        (match (ast.ast-node-get kept)
          [(Literal _) true]
          [_ false])]
      (ast.ast-node-protected-restore!)
      (let
        [restored : bool
          (match (ast.ast-node-get kept)
            [(Var id) (= id cbi.compiler-builtin-id-fix-input)]
            [_ false])]
        [above-kept : bool
          (match (ast.ast-node-get above)
            [(Literal _) true]
            [_ false])]
        [emptied : bool (= (ast.ast-node-protected-journal-count) 0)]
        (ast.ast-node-set! kept (Literal (ast.ast-lit-int 10)))
        (let
          [noted-again : bool (= (ast.ast-node-protected-journal-count) 1)]
          (ast.ast-node-protected-floor-set! 0)
          (let
            [dropped : bool (= (ast.ast-node-protected-journal-count) 0)]
            (ast.ast-node-pool-reset-to! base)
            (and
              (= journaled 2)
              rewritten
              restored
              above-kept
              emptied
              noted-again
              dropped)))))))

(cfg
  test
  (test
    compiler-ast-protected-node-restore
    (unless
      (compiler-ast-protected-restore-ok?)
      (io.panic "in-place writes below the protected floor were not undone"))))

(define (ast-children-test-walk-ids
  [expr-id : i64]
  [scratch : (&mut scratch ast.AstExprList)]
  [target : i64]
  [replacement : i64]) : i64
  (let
    [start : i64 scratch.len]
    [expr : ast.AstExpr (ast.ast-node-get expr-id)]
    (ast.ast-expr-child-ids-into! expr scratch)
    (let
      [end : i64 scratch.len]
      [changed? : bool false]
      [index : i64 start]
      (while (< index end)
        (let
          [orig : i64 (ast.ast-expr-list-get (& (deref scratch)) index -1)]
          [next : i64
            (if (= orig target)
              replacement
              orig)]
          (when
            (!= next orig)
            (ast.ast-expr-list-set! scratch index next)
            (set! changed? true)))
        (set! index (+ index 1)))
      (if changed?
        (let
          [rebuilt : ast.AstExpr
            (ast.ast-expr-with-child-ids-from
              (ast.ast-node-get expr-id)
              (& (deref scratch))
              start)]
          (ast.ast-expr-list-truncate! scratch start)
          (ast.ast-node-push rebuilt))
        (begin
          (ast.ast-expr-list-truncate! scratch start)
          expr-id)))))

(define (ast-children-test-walk-all
  [expr-id : i64]
  [scratch : (&mut scratch ast.AstExprChildList)]
  [target-expr : i64]
  [repl-expr : i64]
  [target-ty-id : i64]
  [repl-ty-id : i64]
  [rewrite-ty-pat? : bool]) : i64
  (let
    [start : i64 scratch.len]
    [expr : ast.AstExpr (ast.ast-node-get expr-id)]
    (ast.ast-expr-children-into! expr scratch)
    (let
      [end : i64 scratch.len]
      [changed? : bool false]
      [index : i64 start]
      (while (< index end)
        (match (ast.ast-expr-child-list-get
          (& (deref scratch))
          index
          (ast.ast-expr-child-fallback))
          [(ast.AstExprChild.Expr id)
            (when
              (= id target-expr)
              (ast.ast-expr-child-list-set!
                scratch
                index
                (ast.AstExprChild.Expr repl-expr))
              (set! changed? true))]
          [(ast.AstExprChild.TypeId id)
            (when
              (= id target-ty-id)
              (ast.ast-expr-child-list-set!
                scratch
                index
                (ast.AstExprChild.TypeId repl-ty-id))
              (set! changed? true))]
          [(ast.AstExprChild.Type ty)
            (when
              rewrite-ty-pat?
              (match ty
                [(ast.AstType.I64)
                  (ast.ast-expr-child-list-set!
                    scratch
                    index
                    (ast.AstExprChild.Type ast.AstType.Bool))
                  (set! changed? true)]
                [_ unit]))]
          [(ast.AstExprChild.Pattern pat)
            (when
              rewrite-ty-pat?
              (match pat
                [(ast.AstPattern.Wildcard)
                  (ast.ast-expr-child-list-set!
                    scratch
                    index
                    (ast.AstExprChild.Pattern (ast.AstPattern.Binding 99)))
                  (set! changed? true)]
                [_ unit]))])
        (set! index (+ index 1)))
      (if changed?
        (let
          [rebuilt : ast.AstExpr
            (ast.ast-expr-with-children-from!
              (ast.ast-node-get expr-id)
              scratch
              start)]
          (ast.ast-expr-child-list-truncate! scratch start)
          (ast.ast-node-push rebuilt))
        (begin
          (ast.ast-expr-child-list-truncate! scratch start)
          expr-id)))))

(define (compiler-ast-child-ids-into-and-from-ok?) : bool
  (let
    [base-pool : i64 (ast.ast-node-pool-len)]
    [e0 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 1)))]
    [e1 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 2)))]
    [e2 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 3)))]
    [e3 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 4)))]
    [bin-id : i64
      (ast.ast-node-push (ast.AstExpr.Binary ast.AstBinOp.Add e0 e1))]
    [args : ast.AstExprList (ast.ast-expr-list-with-capacity 3)]
    [_p0 : unit (ast.ast-expr-list-push (&mut args) e0)]
    [_p1 : unit (ast.ast-expr-list-push (&mut args) e1)]
    [_p2 : unit (ast.ast-expr-list-push (&mut args) e2)]
    [call-id : i64 (ast.ast-node-push (ast.AstExpr.Call e0 args))]
    [step-slots : ast.AstExprList (ast.ast-expr-list-with-capacity 4)]
    [_s0 : unit (ast.ast-expr-list-push (&mut step-slots) e0)]
    [_s1 : unit (ast.ast-expr-list-push (&mut step-slots) -1)]
    [_s2 : unit (ast.ast-expr-list-push (&mut step-slots) e1)]
    [_s3 : unit (ast.ast-expr-list-push (&mut step-slots) e2)]
    [step-id : i64 (ast.ast-node-push (ast.AstExpr.ForOwnedStep step-slots))]
    ;; Pre-populated scratch buffer with sentinel prefix to test non-zero `start`
    ;; and `ast-expr-list-truncate!` restoration with zero arena/pool growth.
    [scratch : ast.AstExprList (ast.ast-expr-list-with-capacity 16)]
    [_pre0 : unit (ast.ast-expr-list-push (&mut scratch) 777)]
    [_pre1 : unit (ast.ast-expr-list-push (&mut scratch) 888)]
    [pool-before : i64 (ast.ast-node-pool-len)]
    [mark-before : arena.ArenaMark (arena.mark)]
    [same-bin : i64 (ast-children-test-walk-ids bin-id (&mut scratch) -999 e3)]
    [same-call : i64
      (ast-children-test-walk-ids call-id (&mut scratch) -999 e3)]
    [same-step : i64
      (ast-children-test-walk-ids step-id (&mut scratch) -999 e3)]
    [mark-after : arena.ArenaMark (arena.mark)]
    [pool-after : i64 (ast.ast-node-pool-len)]
    [new-bin : i64 (ast-children-test-walk-ids bin-id (&mut scratch) e1 e3)]
    [new-call : i64 (ast-children-test-walk-ids call-id (&mut scratch) e1 e3)]
    [new-step : i64 (ast-children-test-walk-ids step-id (&mut scratch) e1 e3)]
    [ok : bool
      (and
        (= same-bin bin-id)
        (= same-call call-id)
        (= same-step step-id)
        (arena.mark-eq? mark-before mark-after)
        (= pool-before pool-after)
        (= scratch.len 2)
        (= (ast.ast-expr-list-get (& scratch) 0 0) 777)
        (= (ast.ast-expr-list-get (& scratch) 1 0) 888)
        (!= new-bin bin-id)
        (!= new-call call-id)
        (!= new-step step-id)
        (match (ast.ast-node-get new-bin)
          [(ast.AstExpr.Binary _ ra rb) (and (= ra e0) (= rb e3))]
          [_ false])
        (match (ast.ast-node-get new-call)
          [(ast.AstExpr.Call rf rargs)
            (and
              (= rf e0)
              (= (ast.ast-expr-list-len (& rargs)) 3)
              (= (ast.ast-expr-list-get (& rargs) 0 0) e0)
              (= (ast.ast-expr-list-get (& rargs) 1 0) e3)
              (= (ast.ast-expr-list-get (& rargs) 2 0) e2))]
          [_ false])
        (match (ast.ast-node-get new-step)
          [(ast.AstExpr.ForOwnedStep slots)
            (and
              (= (ast.ast-expr-list-get (& slots) 0 0) e0)
              (= (ast.ast-expr-list-get (& slots) 1 0) -1)
              (= (ast.ast-expr-list-get (& slots) 2 0) e3)
              (= (ast.ast-expr-list-get (& slots) 3 0) e2))]
          [_ false]))]
    (ast.ast-node-pool-reset-to! base-pool)
    ok))

(define (compiler-ast-children-into-and-with-children-ok?) : bool
  (let
    [base-pool : i64 (ast.ast-node-pool-len)]
    [base-ty : i64 (ast.ty-node-pool-len)]
    [e0 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 10)))]
    [e1 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 20)))]
    [e2 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 30)))]
    [e3 : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 40)))]
    [t0 : i64 (ast.ty-node-push (& (ast.AstType.I64)))]
    [t1 : i64 (ast.ty-node-push (& (ast.AstType.Bool)))]
    [ann-id : i64 (ast.ast-node-push (ast.AstExpr.Ann e0 t0))]
    [mk-id : i64 (ast.ast-node-push (ast.AstExpr.FixedMakeArray t0 e0))]
    [let-bindings : ast.AstLetBindingList
      (ast.ast-let-binding-list-with-capacity 1)]
    [_lb : unit
      (ast.ast-let-binding-list-push
        (&mut let-bindings)
        (ast.AstLetBinding.Binding 1 (ast.AstMaybeType.Some ast.AstType.I64) e0))]
    [let-id : i64
      (ast.ast-node-push
        (ast.AstExpr.Let (box (ast.AstLet.Let let-bindings e1))))]
    [match-arms : ast.AstMatchArmList (ast.ast-match-arm-list-with-capacity 1)]
    [_ma : unit
      (ast.ast-match-arm-list-push
        (&mut match-arms)
        (ast.AstMatchArm.Arm ast.AstPattern.Wildcard e1))]
    [match-id : i64
      (ast.ast-node-push
        (ast.AstExpr.Match (box (ast.AstMatch.Match e0 match-arms))))]
    [fe-id : i64
      (ast.ast-node-push
        (ast.AstExpr.Foreach
          (box (ast.AstForeach.Foreach 7 ast.AstType.I64 e0 e1 e2))))]
    [fe2-id : i64
      (ast.ast-node-push
        (ast.AstExpr.Foreach
          (box
            (ast.AstForeach.Foreach2
              7
              ast.AstType.I64
              e0
              e1
              8
              ast.AstType.I64
              e1
              e2
              e0))))]
    [scratch : ast.AstExprChildList (ast.ast-expr-child-list-with-capacity 32)]
    [_pre : unit
      (ast.ast-expr-child-list-push (&mut scratch) (ast.AstExprChild.Expr 555))]
    [pool-before : i64 (ast.ast-node-pool-len)]
    [mark-before : arena.ArenaMark (arena.mark)]
    [same-ann : i64
      (ast-children-test-walk-all ann-id (&mut scratch) -999 e3 -999 t1 false)]
    [same-let : i64
      (ast-children-test-walk-all let-id (&mut scratch) -999 e3 -999 t1 false)]
    [same-match : i64
      (ast-children-test-walk-all match-id (&mut scratch) -999 e3 -999 t1 false)]
    [same-fe : i64
      (ast-children-test-walk-all fe-id (&mut scratch) -999 e3 -999 t1 false)]
    [same-fe2 : i64
      (ast-children-test-walk-all fe2-id (&mut scratch) -999 e3 -999 t1 false)]
    [mark-after : arena.ArenaMark (arena.mark)]
    [pool-after : i64 (ast.ast-node-pool-len)]
    ;; Changed rebuilds across TypeId, inline Type, Pattern, Foreach2, and
    ;; a direct `ast-expr-with-children-from!` call.
    [new-ann : i64
      (ast-children-test-walk-all ann-id (&mut scratch) e0 e3 t0 t1 false)]
    [new-mk : i64
      (ast-children-test-walk-all mk-id (&mut scratch) -999 e3 t0 t1 false)]
    [new-let : i64
      (ast-children-test-walk-all let-id (&mut scratch) e1 e3 -999 t1 true)]
    [new-match : i64
      (ast-children-test-walk-all match-id (&mut scratch) -999 e3 -999 t1 true)]
    [new-fe : i64
      (ast-children-test-walk-all fe-id (&mut scratch) e1 e3 -999 t1 true)]
    [new-fe2 : i64
      (ast-children-test-walk-all fe2-id (&mut scratch) e2 e3 -999 t1 true)]
    [direct-children : ast.AstExprChildList
      (ast.ast-expr-children (ast.ast-node-get ann-id))]
    [_set0 : unit
      (ast.ast-expr-child-list-set!
        (&mut direct-children)
        0
        (ast.AstExprChild.Expr e2))]
    [direct-rebuilt : ast.AstExpr
      (ast.ast-expr-with-children-from!
        (ast.ast-node-get ann-id)
        (&mut direct-children)
        0)]
    [ok : bool
      (and
        (= same-ann ann-id)
        (= same-let let-id)
        (= same-match match-id)
        (= same-fe fe-id)
        (= same-fe2 fe2-id)
        (arena.mark-eq? mark-before mark-after)
        (= pool-before pool-after)
        (= scratch.len 1)
        (match (ast.ast-expr-child-list-get
          (& scratch)
          0
          (ast.ast-expr-child-fallback))
          [(ast.AstExprChild.Expr id) (= id 555)]
          [_ false])
        (match (ast.ast-node-get new-ann)
          [(ast.AstExpr.Ann ra rt) (and (= ra e3) (= rt t1))]
          [_ false])
        (match (ast.ast-node-get new-mk)
          [(ast.AstExpr.FixedMakeArray rt ra) (and (= rt t1) (= ra e0))]
          [_ false])
        (match (ast.ast-node-get new-let)
          [(ast.AstExpr.Let payload)
            (match (& (__tl-box-place payload))
              [(ast.AstLet.Let bs body)
                (and
                  (= body e3)
                  (match (ast.ast-let-binding-list-get
                    bs
                    0
                    (ast.ast-let-binding-fallback))
                    [(ast.AstLetBinding.Binding
                        _
                        (ast.AstMaybeType.Some (ast.AstType.Bool))
                        init)
                      (= init e0)]
                    [_ false]))])]
          [_ false])
        (match (ast.ast-node-get new-match)
          [(ast.AstExpr.Match payload)
            (match (& (__tl-box-place payload))
              [(ast.AstMatch.Match scr arms)
                (and
                  (= scr e0)
                  (match (ast.ast-match-arm-list-get
                    arms
                    0
                    (ast.ast-match-arm-fallback))
                    [(ast.AstMatchArm.Arm (ast.AstPattern.Binding 99) body)
                      (= body e1)]
                    [_ false]))])]
          [_ false])
        (match (ast.ast-node-get new-fe)
          [(ast.AstExpr.Foreach payload)
            (match (& (__tl-box-place payload))
              [(ast.AstForeach.Foreach 7 (ast.AstType.Bool) a b d)
                (and (= a e0) (= b e3) (= d e2))]
              [_ false])]
          [_ false])
        (match (ast.ast-node-get new-fe2)
          [(ast.AstExpr.Foreach payload)
            (match (& (__tl-box-place payload))
              [(ast.AstForeach.Foreach2
                  7
                  (ast.AstType.Bool)
                  a0
                  b0
                  8
                  (ast.AstType.Bool)
                  a1
                  b1
                  d)
                (and (= a0 e0) (= b0 e1) (= a1 e1) (= b1 e3) (= d e0))]
              [_ false])]
          [_ false])
        (match direct-rebuilt
          [(ast.AstExpr.Ann ra rt) (and (= ra e2) (= rt t0))]
          [_ false]))]
    (ast.ast-node-pool-reset-to! base-pool)
    (ast.ty-node-pool-reset-to! base-ty)
    ok))

(cfg
  test
  (test
    compiler-ast-child-ids-into-and-from
    (unless
      (compiler-ast-child-ids-into-and-from-ok?)
      (io.panic
        "ast-expr-child-ids-into! / ast-expr-with-child-ids-from failed"))))

(cfg
  test
  (test
    compiler-ast-children-into-and-with-children
    (unless
      (compiler-ast-children-into-and-with-children-ok?)
      (io.panic
        "ast-expr-children-into! or ast-expr-with-children-from! failed"))))