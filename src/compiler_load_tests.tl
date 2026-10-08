;; compiler_load_tests.tl - White-box tests for the source and import loader:
;; module and import resolution, includes, the embedded stdlib, package
;; manifests, session caches and state isolation, and the lazy-import observer.
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import sym_i64_env)
(import stdlib.fs)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as load_i64_i64_map)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_ctfe as ctfe)
(import compiler_embedded_stdlib as ces)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import tlci_core as tlci)
(import tlci_loader as tlci_loader_support)
(import compiler_owned_view as owned_view)
(import compiler_load as load)

(define (compiler-load-write-file-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (compiler-load-try-write-file-text
  [path : (& source str)]
  [contents : (& content str)]) : io.ResultIoUnit
  (io.try-write-file path (byte_buf.str-as-bytes contents)))

;; Exact structural demand is reusable by generated-module materializers. The
;; set maps interned member names to a sentinel value and is deduplicated while
;; the importer AST is walked.
(defenum CompilerLoadStructuralMemberDemand
  (CompilerLoadStructuralNoDemand)
  (CompilerLoadStructuralExactMembers sym_i64_env.SymI64Env)
  (CompilerLoadStructuralFullDemand))

(define (compiler-load-surface-signature-must-use?
  [signature : load.CompilerLoadSurfaceSignature]) : bool
  (match signature
    [(CompilerLoadSurfaceStructSignature _ _ _ markers _)
      (not (= (bit-and markers 1) 0))]
    [(CompilerLoadSurfaceEnumSignature _ _ markers _)
      (not (= (bit-and markers 1) 0))]
    [_ false]))

(define (compiler-load-lazy-qualified-observer-stack-count
  [stack : (& stack load.CompilerLoadLazyQualifiedObserverStack)]) : i64
  stack.len)

(define (compiler-load-lazy-qualified-observer-stack-push
  [stack : load.CompilerLoadLazyQualifiedObserverStack]
  [frame : load.CompilerLoadLazyQualifiedObserverFrame]) : load.CompilerLoadLazyQualifiedObserverStack
  (let
    [len : i64 stack.len]
    [slots : (__tl_dyn-array load.CompilerLoadLazyQualifiedObserverFrame)
      stack.slots]
    (if (< len (array-length slots))
      unit
      (let
        [capacity : i64
          (if (= (array-length slots) 0)
            1
            (* (array-length slots) 2))]
        [bigger : (__tl_dyn-array load.CompilerLoadLazyQualifiedObserverFrame)
          (__tl_make-array load.CompilerLoadLazyQualifiedObserverFrame capacity)]
        [index : i64 0]
        (while (< index len)
          (set! (array-ref bigger index) (array-ref slots index))
          (set! index (+ index 1)))
        (set! slots bigger)))
    (set! (array-ref slots len) frame)
    (load.CompilerLoadLazyQualifiedObserverStack slots (+ len 1))))

(define (compiler-load-program-cache-hit-count-value) : i64
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-active-session-state-shared-view)]
    (load.compiler-load-session-state-program-cache-hit-count-value state)))

(define (compiler-load-program-cache-store-count-value) : i64
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-active-session-state-shared-view)]
    (load.compiler-load-session-state-program-cache-store-count-value state)))

(define (compiler-load-embedded-provenance-noted?) : bool
  (load.compiler-load-session-state-embedded-provenance-noted?
    (load.compiler-load-active-session-state-shared-view)))

(define (compiler-load-embedded-provenance-observer-ok?) : bool
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-active-session-state-shared-view)]
    [previous : bool
      (load.compiler-load-session-state-embedded-provenance-noted?
        (owned_view.compiler-owned-shared-view state))]
    [false-ok : bool
      (begin
        (set! (array-ref state.embedded-stdlib-provenance.noted 0) false)
        (not (compiler-load-embedded-provenance-noted?)))]
    [true-ok : bool
      (begin
        (set! (array-ref state.embedded-stdlib-provenance.noted 0) true)
        (compiler-load-embedded-provenance-noted?))]
    (set! (array-ref state.embedded-stdlib-provenance.noted 0) previous)
    (and false-ok true-ok)))

(define (compiler-load-string-vec-one [root : String]) : svec.Vec
  (load.compiler-load-string-vec-push-copy (svec.new) root))

(define (compiler-load-string-vec-two [left : String] [right : String]) : svec.Vec
  (load.compiler-load-string-vec-push-copy
    (compiler-load-string-vec-one left)
    right))

(define (compiler-load-dotted-path-cache-lookup [module-id : i64]) : load.CompilerLoadMaybeString
  (let
    [bound-4 (load.compiler-load-active-session-state-shared-view)]
    (load.compiler-load-session-state-dotted-path-cache-lookup
      bound-4
      module-id)))

(define (compiler-load-decl-list-has-extern-symbol?
  [decls : ast.AstDeclList]
  [want : String]) : bool
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    (while (< index count)
      (let
        [decl : ast.AstDecl
          (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
        (match decl
          [(Extern _ _ _ metadata _)
            (when
              (string.eq
                (ast.ast-extern-metadata-symbol (& (deref metadata)))
                (string.copy want))
              (return true))]
          [_ unit])
        (set! index (+ index 1))))
    false))

(define (compiler-load-surface-summary-requires-eager?
  [summary : (& summary load.CompilerLoadSurfaceSummary)]) : bool
  (or
    summary.has-tests
    summary.has-export-metadata
    summary.has-generated-decls
    summary.has-decl-emitting-macro
    (load.compiler-load-surface-summary-decls-require-eager? summary.decls)))

;; A catalog selector can ask one existing structural demand walk to retain the
;; first member below an alias root for every qualified use it sees. This keeps
;; the ordinary three-bit result intact while avoiding one whole-program walk
;; per candidate member of a generated Module catalog. The observer is strictly
;; dynamic and single-threaded. Nested demand queries save only an active outer
;; observer; a top-level query clears the stack without copying inactive state
;; that may belong to a reclaimed batch-entry arena.
;; The primary root drives the ordinary demand result; a second root is observed
;; opportunistically during that same walk so generated-catalog selection does
;; not traverse the importer program a second time for its canonical module.
(defstruct CompilerLoadLazyQualifiedObserverResult
  (primary-members sym_i64_env.SymI64Env)
  (secondary-members sym_i64_env.SymI64Env)
  (secondary-qualified bool)
  (secondary-direct bool))

(define (compiler-load-session-state-lazy-qualified-observer-begin-pair!
  [state : (& state load.CompilerLoadSessionState)]
  [root-id : i64]
  [secondary-root-id : i64]) : unit
  (let
    [observer : (& state load.CompilerLoadLazyQualifiedObserverState)
      (load.compiler-load-session-state-lazy-qualified-observer state)]
    ;; A top-level query may follow a completed batch entry whose inactive
    ;; observer frame belonged to the reclaimed entry arena. Clear it before
    ;; preserving the ordinary push/pop semantics used by the demand walker.
    (if (load.compiler-load-session-state-lazy-qualified-observer-active? state)
      unit
      (load.compiler-load-session-state-lazy-qualified-observer-reset! state))
    (set!
      (array-ref observer.stack 0)
      (compiler-load-lazy-qualified-observer-stack-push
        (load.compiler-load-global-array-element-shared-view observer.stack 0)
        (load.CompilerLoadLazyQualifiedObserverFrame
          (load.compiler-load-lazy-qualified-observer-flag observer 0)
          (load.compiler-load-lazy-qualified-observer-flag observer 1)
          (load.compiler-load-lazy-qualified-observer-root-id observer 0)
          (load.compiler-load-lazy-qualified-observer-members observer 0)
          (load.compiler-load-lazy-qualified-observer-root-id observer 1)
          (load.compiler-load-lazy-qualified-observer-members observer 1)
          (load.compiler-load-lazy-qualified-observer-flag observer 2)
          (load.compiler-load-lazy-qualified-observer-flag observer 3))))
    (load.compiler-load-lazy-qualified-observer-flag-set! observer 1 true)
    (load.compiler-load-lazy-qualified-observer-flag-set! observer 0 true)
    (load.compiler-load-lazy-qualified-observer-root-id-set! observer 0 root-id)
    (load.compiler-load-lazy-qualified-observer-members-set!
      observer
      0
      (sym_i64_env.sym-i64-empty))
    (load.compiler-load-lazy-qualified-observer-root-id-set!
      observer
      1
      secondary-root-id)
    (load.compiler-load-lazy-qualified-observer-members-set!
      observer
      1
      (sym_i64_env.sym-i64-empty))
    (load.compiler-load-lazy-qualified-observer-flag-set! observer 2 false)
    (load.compiler-load-lazy-qualified-observer-flag-set! observer 3 false)))

(define (compiler-load-session-state-lazy-qualified-observer-end-pair!
  [state : (& state load.CompilerLoadSessionState)]) : CompilerLoadLazyQualifiedObserverResult
  (let
    [observer : (& state load.CompilerLoadLazyQualifiedObserverState)
      (load.compiler-load-session-state-lazy-qualified-observer state)]
    [out : CompilerLoadLazyQualifiedObserverResult
      (CompilerLoadLazyQualifiedObserverResult
        (load.compiler-load-lazy-qualified-observer-members observer 0)
        (load.compiler-load-lazy-qualified-observer-members observer 1)
        (load.compiler-load-lazy-qualified-observer-flag observer 2)
        (load.compiler-load-lazy-qualified-observer-flag observer 3))]
    [stack : load.CompilerLoadLazyQualifiedObserverStack
      (load.compiler-load-global-array-element-shared-view observer.stack 0)]
    [len : i64 (compiler-load-lazy-qualified-observer-stack-count stack)]
    (if (= len 0)
      ;; Preserve the historical empty-pop behavior: return the current
      ;; observation above, then leave the observer fully inactive.
      (load.compiler-load-session-state-lazy-qualified-observer-reset! state)
      (let
        [frame : load.CompilerLoadLazyQualifiedObserverFrame
          (clone (array-ref stack.slots (- len 1)))]
        (set!
          (array-ref observer.stack 0)
          (load.CompilerLoadLazyQualifiedObserverStack stack.slots (- len 1)))
        (load.compiler-load-lazy-qualified-observer-flag-set!
          observer
          0
          frame.active)
        (load.compiler-load-lazy-qualified-observer-flag-set!
          observer
          1
          frame.exhaustive)
        (load.compiler-load-lazy-qualified-observer-root-id-set!
          observer
          0
          frame.root-id)
        (load.compiler-load-lazy-qualified-observer-members-set!
          observer
          0
          frame.members)
        (load.compiler-load-lazy-qualified-observer-root-id-set!
          observer
          1
          frame.secondary-root-id)
        (load.compiler-load-lazy-qualified-observer-members-set!
          observer
          1
          frame.secondary-members)
        (load.compiler-load-lazy-qualified-observer-flag-set!
          observer
          2
          frame.secondary-qualified)
        (load.compiler-load-lazy-qualified-observer-flag-set!
          observer
          3
          frame.secondary-direct)))
    out))

(define (compiler-load-structural-member-demand-from-lazy
  [demand : load.CompilerLoadLazyAliasDemand]) : CompilerLoadStructuralMemberDemand
  (if (or demand.direct demand.unknown)
    (CompilerLoadStructuralFullDemand)
    (if demand.qualified
      (CompilerLoadStructuralExactMembers demand.members)
      (CompilerLoadStructuralNoDemand))))

(define (compiler-load-session-state-structural-member-demand-with-pools
  [state : load.CompilerLoadSessionState]
  [decls : ast.AstDeclList]
  [alias : i64]
  [pools : ast.AstNodePoolContext]) : CompilerLoadStructuralMemberDemand
  (let
    [_install-pools : unit (ast.ast-node-pool-context-install! pools)]
    (compiler-load-structural-member-demand-from-lazy
      (let
        [bound-5 (load.compiler-load-lazy-empty-surface-summary)]
        (load.compiler-load-session-state-lazy-decl-list-demand
          state
          decls
          alias
          bound-5
          (sym_i64_env.sym-i64-empty))))))

;; Serial/test compatibility adapter. Production load jobs pass their owned
;; session state to the stateful entry point above.
(define (compiler-load-structural-member-demand-with-pools
  [decls : ast.AstDeclList]
  [alias : i64]
  [pools : ast.AstNodePoolContext]) : CompilerLoadStructuralMemberDemand
  (compiler-load-session-state-structural-member-demand-with-pools
    (load.compiler-load-active-session-state-shared-view)
    decls
    alias
    pools))

(define (compiler-load-structural-member-demand
  [decls : ast.AstDeclList]
  [alias : i64]) : CompilerLoadStructuralMemberDemand
  (compiler-load-structural-member-demand-with-pools
    decls
    alias
    (ast.ast-node-pool-context-capture-active)))

(define (compiler-load-structural-member-demand-contains?
  [demand : CompilerLoadStructuralMemberDemand]
  [member : i64]) : bool
  (match demand
    [(CompilerLoadStructuralExactMembers members)
      (sym_i64_env.sym-i64-contains-id members member)]
    [_ false]))

(define (compiler-load-structural-member-set-count
  [members : sym_i64_env.SymI64Env]) : i64
  (match (sym_i64_env.sym-i64-view members)
    [(SymI64ViewNil) 0]
    [(SymI64ViewBind _ _ rest)
      (+ 1 (compiler-load-structural-member-set-count rest))]))

(define (compiler-load-structural-member-demand-count
  [demand : CompilerLoadStructuralMemberDemand]) : i64
  (match demand
    [(CompilerLoadStructuralExactMembers members)
      (compiler-load-structural-member-set-count members)]
    [_ 0]))

(define (compiler-load-decls-with-module-and-roots-cfg-root
  [decls : ast.AstDeclList]
  [importer-path : String]
  [importer-path-id : i64]
  [importer-decl-owner-id : i64]
  [importer-module : String]
  [importer-module-id : i64]
  [importer-source-module : String]
  [importer-source-module-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]) : load.ResultCompilerLoadWithPaths
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : load.ResultCompilerLoadWithPaths
      (load.compiler-load-decls-with-module-and-roots-cfg-root-with-pools
        (load.CompilerLoadTraversalContext
          (load.compiler-load-active-session-state-shared-view)
          importer-path-id
          importer-decl-owner-id)
        decls
        importer-path
        importer-module
        importer-module-id
        importer-source-module
        importer-source-module-id
        seen
        stdlib-roots
        import-root
        cfgs
        pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (compiler-load-package-entry-main?
  [entry-path : String]
  [decl-path : String]
  [_module : String]
  [source-name : String]) : bool
  (let
    [entry-path : String (load.compiler-load-normalize-path entry-path)]
    [decl-path : String (load.compiler-load-normalize-path decl-path)]
    (load.compiler-load-package-entry-main-normalized?
      entry-path
      decl-path
      source-name)))

(define (compiler-load-package-file-with-paths-and-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : load.CompilerPkgDeps]) : load.ResultCompilerLoadWithPaths
  (load.compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    No
    manifest-dir
    deps
    (parser.compiler-cfg-empty)))

(define (compiler-load-decl-list-count [decls : (& decls ast.AstDeclList)]) : i64
  (ast.ast-decl-list-len decls))

(define (compiler-load-decl-list-value-name-count
  [decls : ast.AstDeclList]
  [want : String]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) 0]
    [(Cons decl rest)
      (+
        (match decl
          [(Def _ name _ _)
            (if (string.eq (ci.intern-str name) want)
              1
              0)]
          [_ 0])
        (compiler-load-decl-list-value-name-count rest want))]))

(define (compiler-load-first-string-def?
  [decls : ast.AstDeclList]
  [name : String]
  [want : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Cons (Def _ got (Some (String)) value-box) _)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        (match value
          [(Literal (String string-id))
            (and
              (string.eq (ci.intern-str got) name)
              (string.eq (ci.intern-str string-id) want))]
          [_ false]))]
    [_ false]))

(define (compiler-load-first-string-macro?
  [decls : ast.AstDeclList]
  [name : String]
  [want : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Cons (DefMacro _ got params (String) body-box) _)
      (match (ast.ast-node-get body-box)
        [(Call callee-box args)
          (and
            (string.eq (ci.intern-str got) name)
            (= (ast.ast-macro-param-list-len (& params)) 0)
            (match (ast.ast-node-get callee-box)
              [(Var callee) (string.eq (ci.intern-str callee) "expr-string")]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (match (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0))
              [(Literal (String text)) (string.eq (ci.intern-str text) want)]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-load-first-lzss-def?
  [decls : ast.AstDeclList]
  [name : String]
  [want-source : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Cons (Def _ got (Some (DynArray elem-id)) value-box) _)
      (match (ast.ast-node-get value-box)
        [(BinaryData bytes)
          (and
            (string.eq (ci.intern-str got) name)
            (match (ast.ty-node-get elem-id)
              [(U8) true]
              [_ false])
            (string.eq
              bytes
              (ctfe.ctfe-embedded-stdlib-binary-data-bytes want-source)))]
        [_ false])]
    [_ false]))

(define (compiler-load-binary-payload-ok? [text : String]) : bool
  (and
    (= (string.string-length text) 6)
    (= (load.compiler-load-char-code-at text 0) 0)
    (= (load.compiler-load-char-code-at text 1) 65)
    (= (load.compiler-load-char-code-at text 2) 127)
    (= (load.compiler-load-char-code-at text 3) 128)
    (= (load.compiler-load-char-code-at text 4) 255)
    (= (load.compiler-load-char-code-at text 5) 10)))

(define (compiler-load-first-bin-def? [decls : ast.AstDeclList] [name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Cons (Def _ got (Some (DynArray elem-id)) value-box) _)
      (let
        [value : ast.AstExpr (ast.ast-node-get value-box)]
        [elem : ast.AstType (ast.ty-node-get elem-id)]
        (match value
          [(BinaryData text)
            (and
              (string.eq (ci.intern-str got) name)
              (match elem
                [(U8) true]
                [_ false])
              (compiler-load-binary-payload-ok? text))]
          [_ false]))]
    [_ false]))

(define (compiler-load-binary-fixture) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 6)]
    (set! (array-ref bytes 0) (cast 0 : u8))
    (set! (array-ref bytes 1) (cast 65 : u8))
    (set! (array-ref bytes 2) (cast 127 : u8))
    (set! (array-ref bytes 3) (cast 128 : u8))
    (set! (array-ref bytes 4) (cast 255 : u8))
    (set! (array-ref bytes 5) (cast 10 : u8))
    (unsafe
      (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) 6))))

(define (compiler-load-decl-list-has-import-alias?
  [decls : ast.AstDeclList]
  [target-module : String]
  [target-alias : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(Import decl-meta (Spec _ _ (Some module-name) (Some alias) _))
            (if (and
              (string.eq (ci.intern-str module-name) target-module)
              (string.eq (ci.intern-str alias) target-alias))
              true
              (compiler-load-decl-list-has-import-alias?
                rest
                target-module
                target-alias))]
          [_
            (compiler-load-decl-list-has-import-alias?
              rest
              target-module
              target-alias)]))]))

(define (compiler-load-unmoduled-import-restored-decls?
  [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Cons (Module imported-module) rest1)
      (let
        [rest1 : ast.AstDeclList rest1]
        (match (ast.ast-decl-list-step rest1)
          [(Cons (Def decl-meta imported-name _ _) rest2)
            (let
              [rest2 : ast.AstDeclList rest2]
              (match (ast.ast-decl-list-step rest2)
                [(Cons (Module restored-module) rest3)
                  (let
                    [rest3 : ast.AstDeclList rest3]
                    (match (ast.ast-decl-list-step rest3)
                      [(Cons
                          (Import
                            _
                            (Spec _ _ (Some alias-module) (Some alias-name) _))
                          rest4)
                        (let
                          [rest4 : ast.AstDeclList rest4]
                          (match (ast.ast-decl-list-step rest4)
                            [(Cons (DefFn _ main-name _ _ _ _) done-box)
                              (let
                                [done : ast.AstDeclList done-box]
                                (and
                                  (ast_tests.ast-decl-list-empty? (& done))
                                  (string.eq
                                    (ci.intern-str imported-module)
                                    "cl_restore_dep")
                                  (string.eq
                                    (ci.intern-str imported-name)
                                    "dep-value")
                                  (string.eq (ci.intern-str restored-module) "")
                                  (string.eq
                                    (ci.intern-str alias-module)
                                    "cl_restore_dep")
                                  (string.eq (ci.intern-str alias-name) "dep")
                                  (string.eq (ci.intern-str main-name) "main")))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-two-modules?
  [modules : ast.AstDeclModuleList]
  [want : String]) : bool
  (and
    (= (ast.ast-decl-module-list-len (& modules)) 2)
    (string.eq (ast_tests.ast-decl-module-list-get (& modules) 0 "") want)
    (string.eq (ast_tests.ast-decl-module-list-get (& modules) 1 "") want)))

(define (compiler-load-entry-cycle-module-name? [name : String]) : bool
  (or
    (string.eq name "compiler_load_entry")
    (string.eq name "compiler_load_dep")))

(define (compiler-load-entry-cycle-modules-loop
  [modules : ast.AstDeclModuleList]
  [count : i64]) : bool
  (if (>= count (ast.ast-decl-module-list-len (& modules)))
    (= count 10)
    (and
      (compiler-load-entry-cycle-module-name?
        (ast_tests.ast-decl-module-list-get (& modules) count ""))
      (compiler-load-entry-cycle-modules-loop modules (+ count 1)))))

(define (compiler-load-entry-cycle-modules? [modules : ast.AstDeclModuleList]) : bool
  (compiler-load-entry-cycle-modules-loop modules 0))

(define (compiler-load-surface-maybe-string-eq?
  [maybe : (& maybe load.CompilerLoadSurfaceMaybeString)]
  [want : (& want str)]) : bool
  (match maybe
    [(CompilerLoadSurfaceSomeString got) (string.eq got want)]
    [(CompilerLoadSurfaceNoString) (string.eq want "")]))

(define (compiler-load-surface-import-kind-code
  [kind : load.CompilerLoadSurfaceImportKind]) : i64
  (match kind
    [(CompilerLoadSurfaceImportModule) 1]
    [(CompilerLoadSurfaceImportMacro) 2]
    [(CompilerLoadSurfaceImportMacroDecls) 3]))

(define (compiler-load-surface-decl-kind-code
  [kind : load.CompilerLoadSurfaceDeclKind]) : i64
  (match kind
    [(CompilerLoadSurfaceValue) 1]
    [(CompilerLoadSurfaceFunction) 2]
    [(CompilerLoadSurfaceExtern) 3]
    [(CompilerLoadSurfaceStruct) 4]
    [(CompilerLoadSurfaceEnum) 5]
    [(CompilerLoadSurfaceMacro) 6]
    [(CompilerLoadSurfaceDispatch) 7]
    [(CompilerLoadSurfaceTest) 8]
    [(CompilerLoadSurfaceIncludeStr) 9]
    [(CompilerLoadSurfaceIncludeBin) 10]
    [(CompilerLoadSurfaceIncludeStrComptime) 11]))

(define (compiler-load-surface-macro-result-kind-code
  [kind : load.CompilerLoadSurfaceMacroResultKind]) : i64
  (match kind
    [(CompilerLoadSurfaceMacroExpr) 1]
    [(CompilerLoadSurfaceMacroModule) 2]
    [(CompilerLoadSurfaceMacroDecls) 3]
    [(CompilerLoadSurfaceMacroOther) 4]))

(define (compiler-load-surface-import-kind-count
  [imports : (& imports load.CompilerLoadSurfaceImportList)]
  [kind-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index (load.compiler-load-surface-import-list-count imports))
      (if (=
        (compiler-load-surface-import-kind-code
          (__tl-project-field
            (load.compiler-load-surface-import-list-at imports index)
            kind))
        kind-code)
        (set! count (+ count 1))
        unit)
      (set! index (+ index 1)))
    count))

(define (compiler-load-surface-import-has?
  [imports : (& imports load.CompilerLoadSurfaceImportList)]
  [kind-code : i64]
  [import-path : String]
  [alias : String]
  [default-alias : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-import-list-count imports))
      (let
        [import-edge : load.CompilerLoadSurfaceImport
          (load.compiler-load-surface-import-list-at imports index)]
        (if (and
          (=
            (compiler-load-surface-import-kind-code import-edge.kind)
            kind-code)
          (string.eq import-edge.import-path import-path)
          (compiler-load-surface-maybe-string-eq? import-edge.alias alias)
          (compiler-load-surface-maybe-string-eq?
            import-edge.default-alias
            default-alias))
          (return true)
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-decl-kind-count
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [kind-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (if (=
        (compiler-load-surface-decl-kind-code
          (__tl-project-field
            (load.compiler-load-surface-decl-list-at decls index)
            kind))
        kind-code)
        (set! count (+ count 1))
        unit)
      (set! index (+ index 1)))
    count))

(define (compiler-load-surface-decl-has?
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [kind-code : i64]
  [name : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (and
          (= (compiler-load-surface-decl-kind-code decl.kind) kind-code)
          (string.eq (ci.intern-str decl.name) name))
          (return true)
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-decl-in-module?
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [name : String]
  [module : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (and
          (string.eq (ci.intern-str decl.name) name)
          (string.eq (ci.intern-str decl.module) module))
          (return true)
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-decl-generated?
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (and
          (string.eq (ci.intern-str decl.name) name)
          decl.has-generated-meta)
          (return true)
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-decl-unsafe?
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (and (string.eq (ci.intern-str decl.name) name) decl.was-unsafe)
          (return true)
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-decl-cleanup?
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (and (string.eq (ci.intern-str decl.name) name) decl.has-cleanup)
          (return true)
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-decl-must-use?
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [name : String]) : bool
  (let
    [index : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (string.eq (ci.intern-str decl.name) name)
          (return (compiler-load-surface-signature-must-use? decl.signature))
          (set! index (+ index 1)))))
    false))

(define (compiler-load-surface-macro-result-count
  [decls : (& decls load.CompilerLoadSurfaceDeclList)]
  [result-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (while (< index (load.compiler-load-surface-decl-list-count decls))
      (let
        [decl : load.CompilerLoadSurfaceDecl
          (load.compiler-load-surface-decl-list-at decls index)]
        (if (and
          (= (compiler-load-surface-decl-kind-code decl.kind) 6)
          (=
            (compiler-load-surface-macro-result-kind-code decl.macro-result)
            result-code))
          (set! count (+ count 1))
          unit)
        (set! index (+ index 1))))
    count))

(define (compiler-load-surface-summary-shape-ok?
  [summary : load.CompilerLoadSurfaceSummary]) : bool
  (let
    [imports : load.CompilerLoadSurfaceImportList summary.imports]
    [decls : load.CompilerLoadSurfaceDeclList summary.decls]
    (and
      (string.eq (ci.intern-str summary.module-id) "summary.mod")
      (string.eq summary.source-path "src/summary.tl")
      (string.eq summary.root-id "src")
      (= (load.compiler-load-surface-import-list-count imports) 5)
      (=
        (array-length imports.slots)
        (load.compiler-load-surface-import-list-count imports))
      (string.eq
        (__tl-project-field
          (load.compiler-load-surface-import-list-at imports 0)
          import-path)
        "dep.mod")
      (string.eq
        (ci.intern-str
          (__tl-project-field
            (load.compiler-load-surface-import-list-at imports 0)
            module))
        "summary.mod")
      (string.eq
        (__tl-project-field
          (load.compiler-load-surface-import-list-at imports 1)
          import-path)
        "stdlib.vector")
      (= (compiler-load-surface-import-kind-count imports 1) 3)
      (= (compiler-load-surface-import-kind-count imports 2) 1)
      (= (compiler-load-surface-import-kind-count imports 3) 1)
      (compiler-load-surface-import-has?
        imports
        1
        "stdlib.vector"
        "vec"
        "vector")
      (compiler-load-surface-import-has? imports 1 "feature.mod" "feat" "mod")
      (= (load.compiler-load-surface-decl-list-count decls) 14)
      (=
        (array-length decls.slots)
        (load.compiler-load-surface-decl-list-count decls))
      (string.eq
        (ci.intern-str
          (__tl-project-field
            (load.compiler-load-surface-decl-list-at decls 0)
            name))
        "value")
      (string.eq
        (ci.intern-str
          (__tl-project-field
            (load.compiler-load-surface-decl-list-at
              decls
              (- (load.compiler-load-surface-decl-list-count decls) 1))
            name))
        "blob")
      (= (compiler-load-surface-decl-kind-count decls 6) 3)
      (compiler-load-surface-decl-has? decls 1 "value")
      (compiler-load-surface-decl-has? decls 2 "pub")
      (compiler-load-surface-decl-has? decls 3 "foreign")
      (compiler-load-surface-decl-in-module?
        decls
        "nested-value"
        "nested.summary")
      (compiler-load-surface-decl-unsafe? decls "danger")
      (compiler-load-surface-decl-cleanup? decls "Resource")
      (compiler-load-surface-decl-cleanup? decls "Maybe")
      (compiler-load-surface-decl-must-use? decls "Resource")
      (compiler-load-surface-decl-must-use? decls "Maybe")
      (not (compiler-load-surface-decl-must-use? decls "value"))
      (compiler-load-surface-decl-generated? decls "generated-value")
      (= (compiler-load-surface-macro-result-count decls 1) 1)
      (= (compiler-load-surface-macro-result-count decls 2) 1)
      (= (compiler-load-surface-macro-result-count decls 3) 1)
      summary.has-tests
      summary.has-export-metadata
      summary.has-generated-decls
      summary.has-decl-emitting-macro
      (compiler-load-surface-summary-requires-eager? summary))))

(define (compiler-load-surface-mark-generated-value! [program : ast.AstProgram]) : bool
  (match program
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [index : i64 0]
        [found : bool false]
        (while (and (< index (ast.ast-decl-list-len (& decls))) (not found))
          (let
            [decl : ast.AstDecl
              (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
            (match (ast.ast-place-shared-view decl)
              [(Def _ name _ _)
                (if (string.eq (ci.intern-str name) "generated-value")
                  (let
                    [args : ast.AstExprList (ast.ast-expr-list-new)]
                    (ast.ast-expr-list-push
                      (&mut args)
                      (ast.ast-node-push
                        (Literal (ast.ast-lit-generated-string "i64"))))
                    (set!
                      (array-ref decls.slots (+ decls.offset index))
                      (ast.ast-decl-comptime-decl-with-meta
                        (Some "gen-family" "generated-value" args "")
                        decl))
                    (set! found true))
                  unit)]
              [_ unit])
            (set! index (+ index 1))))
        found)]))

(define (compiler-load-surface-summary-smoke-ok?) : bool
  (let
    [cfgs : sym_i64_env.SymI64Env
      (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature")]
    [path : String "src\\summary.tl"]
    [parse-identity : load.CompilerLoadParseIdentity
      (load.compiler-load-parse-identity (string.copy path) "src.summary" No)]
    [source-path-id : i64 parse-identity.source-path-id]
    [fallback-id : i64 parse-identity.module-fallback-id]
    (match (load.compiler-load-parse-source-diagnostic-escaping
      (string.copy path)
      (str_cat.str-cat
        "(module summary.mod)
(import dep.mod as dep)
(import stdlib.vector as vec)
(import (vec.vector i64) as vi64)
(cfg feature (import feature.mod as feat))
(emit-generated VecI64)
(define value : i64 1)
(define (pub [x : i64]) (:export-symbol \"pub\") : i64 x)
(extern (foreign [x : i64]) : i64)
(unsafe (extern (danger [x : i64]) : i64))
(defstruct Resource (:cleanup close-resource) (:must-use) (fd i64 (:cleanup close-fd)))
(defenum Maybe (:cleanup close-maybe) (:must-use) (None) (Some i64 (:cleanup close-i64)))
(defmacro (expr-m [x : Expr]) : Expr x)
(defmacro (module-m [T : type]) : Module (expr-unit))
(defmacro (decls-m [T : type]) : Decls (expr-unit))
(define generated-value : i64 3)
(module nested.summary
  (define nested-value : i64 4))
("
        "test loader-summary value)
(include-str text \"data.txt\")
(include-bin blob \"data.bin\")")
      cfgs)
      [(Ok program)
        (if (not
          (compiler-load-surface-mark-generated-value!
            (ast.ast-place-shared-view program)))
          false
          (match (load.compiler-load-surface-summary-build
            path
            source-path-id
            "src\\..\\src"
            program
            fallback-id
            false)
            [(Ok summary) (compiler-load-surface-summary-shape-ok? summary)]
            [(Err _) false]))]
      [(Err _) false])))

(define (compiler-load-normalize-ok?) : bool
  (and
    (string.eq
      (load.compiler-load-normalize-path "selfhost/./x/../compiler_load.tl")
      "selfhost/compiler_load.tl")
    (string.eq
      (load.compiler-load-normalize-path "target\\loader\\..\\dep.tl")
      "target/dep.tl")
    (load.compiler-load-prelude-importer? "stdlib/runtime.tl")
    (load.compiler-load-prelude-importer? "stdlib\\runtime.tl")
    (load.compiler-load-prelude-importer? "stdlib/./core_macros.tl")
    (not (load.compiler-load-prelude-importer? "stdlib/clone.tl"))))

(define (compiler-load-canonical-module-id-ok?) : bool
  (and
    (string.eq
      (load.compiler-load-canonical-module-id-from-path "stdlib/vector.tl")
      "stdlib.vector")
    (string.eq
      (load.compiler-load-canonical-module-id-from-path
        "src\\compiler_intern.tl")
      "src.compiler_intern")
    (string.eq
      (load.compiler-load-canonical-module-id-from-import
        (Module)
        "stdlib.some_name"
        "target/ignored/some_name.tl")
      "stdlib.some_name")))

(define (compiler-load-test-seen-contains?
  [seen : (& seen sym_i64_env.SymI64Env)]
  [name : (& name str)]) : bool
  (sym_i64_env.sym-i64-contains-id
    seen
    (load.compiler-load-parse-context-name-id name)))

(define (compiler-load-source-provenance-ok?) : bool
  (match (load.compiler-load-source-with-paths
    "src/./main.tl"
    "(module app.main)
(define answer : i64 42)"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ modules seen)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-two-modules? modules "app.main")
        (compiler-load-test-seen-contains? seen "app.main"))]
    [(Err _) false]))

(define (compiler-load-entry-moduled-main-ok?) : bool
  (and
    (compiler-load-package-entry-main?
      "src/app.tl"
      "src/app.tl"
      "app.main"
      "main")
    (compiler-load-package-entry-main?
      "src\\app.tl"
      "src/app.tl"
      "app.main"
      "main")
    (not
      (compiler-load-package-entry-main?
        "src/app.tl"
        "src/lib.tl"
        "app.main"
        "main"))
    (not
      (compiler-load-package-entry-main?
        "src/app.tl"
        "src/app.tl"
        "app.main"
        "helper"))))

(define (compiler-load-expected-module-conflict-ok?) : bool
  (match (load.compiler-load-source-with-paths-and-roots-expect
    "src/lib.tl"
    "(module lib.actual)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty)
    (svec.new)
    (Some (ci.intern-generated-name "lib.want")))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: import expected module lib.want but loaded lib.actual")]
    [(Ok _ _ _ _) false]))

(define (compiler-load-duplicate-module-ok?) : bool
  (match (load.compiler-load-source
    "src/dup.tl"
    "(module dup.one)
(module dup.two)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: duplicate module declaration")]
    [(Ok _ _) false]))

(define (compiler-load-nested-module-body-ok?) : bool
  (match (load.compiler-load-source
    "src/nested_module.tl"
    "(module local.helper (define value : i64 1))
(define root-value : i64 2)"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _)
      (match (ast.ast-decl-list-step decls)
        [(Cons (Module nested-module) rest1)
          (let
            [rest1 : ast.AstDeclList rest1]
            (match (ast.ast-decl-list-step rest1)
              [(Cons (Def decl-meta value-name _ _) rest2)
                (let
                  [rest2 : ast.AstDeclList rest2]
                  (match (ast.ast-decl-list-step rest2)
                    [(Cons (Module restored-module) rest3)
                      (let
                        [rest3 : ast.AstDeclList rest3]
                        (match (ast.ast-decl-list-step rest3)
                          [(Cons (Def _ root-name _ _) done-box)
                            (let
                              [done : ast.AstDeclList done-box]
                              (and
                                (ast_tests.ast-decl-list-empty? (& done))
                                (string.eq
                                  (ci.intern-str nested-module)
                                  "local.helper")
                                (string.eq (ci.intern-str value-name) "value")
                                (string.eq (ci.intern-str restored-module) "")
                                (string.eq
                                  (ci.intern-str root-name)
                                  "root-value")))]
                          [_ false]))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [(Err _) false]))

(define (compiler-load-nested-module-duplicate-ok?) : bool
  (match (load.compiler-load-source
    "src/nested_dup.tl"
    "(module local.helper (define a : i64 1))
(module local.helper (define b : i64 2))"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: duplicate module declaration")]
    [(Ok _ _) false]))

(define (compiler-load-seen-module-ok?) : bool
  (match (load.compiler-load-source
    "src/other.tl"
    "(module seen.module)
(define value : i64 1)"
    (sym_i64_env.sym-i64-bind-id
      (sym_i64_env.sym-i64-empty)
      (load.compiler-load-parse-context-name-id "seen.module")
      1))
    [(Ok decls _) (load.compiler-load-decl-list-has-module? decls)]
    [(Err _) false]))

(define (compiler-load-cfg-import-ok?) : bool
  (let
    [source : String
      "(module cfg.entry)
(cfg missing (import definitely_missing))
(define value : i64 1)"]
    [enabled-source : String
      "(module cfg.entry.active)
(cfg feature (import definitely_missing))
(define value : i64 1)"]
    [feature-cfg : sym_i64_env.SymI64Env
      (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature")]
    (and
      (match (load.compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        source
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        (parser.compiler-cfg-empty))
        [(Ok decls _ _ _) (= (compiler-load-decl-list-count decls) 2)]
        [(Err _) false])
      (match (load.compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        enabled-source
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        feature-cfg)
        [(Err _) true]
        [(Ok _ _ _ _) false]))))

(define (compiler-load-file-import-dedup-cycle-ok?) : bool
  (compiler-load-write-file-text
    "target/compiler_load_dep.tl"
    "(module compiler_load_dep)
(import compiler_load_entry as entry)
(define dep : i64 1)")
  (compiler-load-write-file-text
    "target/compiler_load_entry.tl"
    "(module compiler_load_entry)
(import compiler_load_dep as dep)
(import compiler_load_dep)
(define (main) : i64 (+ dep.dep compiler_load_dep.dep))")
  (match (compiler-load-file-with-paths
    "target/compiler_load_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ modules seen)
      (and
        (= (compiler-load-decl-list-count decls) 10)
        (compiler-load-entry-cycle-modules? modules)
        (compiler-load-test-seen-contains? seen "compiler_load_entry")
        (compiler-load-test-seen-contains? seen "compiler_load_dep"))]
    [(Err _) false]))

(define (compiler-load-import-module-restore-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_restore_dep.tl"
    "(module cl_restore_dep)
(define dep-value : i64 1)")
  (compiler-load-write-file-text
    "target/cl_restore_entry.tl"
    "(import cl_restore_dep as dep)
(define (main) : i64 dep.dep-value)")
  (match (compiler-load-file-with-paths
    "target/cl_restore_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _) (compiler-load-unmoduled-import-restored-decls? decls)]
    [(Err _) false]))

(define (compiler-load-import-alias-preserved-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_alias_dep.tl"
    "(module cl_alias_dep)
(define (get) : i64 7)")
  (compiler-load-write-file-text
    "target/cl_alias_entry.tl"
    "(import cl_alias_dep as dep)
(module alias.entry)
(define (main) : i64 (dep.get))")
  (match (compiler-load-file-with-paths
    "target/cl_alias_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _)
      (compiler-load-decl-list-has-import-alias? decls "cl_alias_dep" "dep")]
    [(Err _) false]))

(define (compiler-load-dotted-import-duplicate-alias-ok?) : bool
  (match (load.compiler-load-source
    "src/dup_alias.tl"
    "(module alias.entry)
(import pkg.one)
(import other.one)
(define (main) : i64 0)"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: ambiguous import alias 'one' between 'pkg.one' and 'other.one'; use distinct aliases or qualified access")]
    [(Ok _ _) false]))

;; Re-importing the same module under the same alias is idempotent, not a
;; duplicate: only a different module under a repeated alias is ambiguous.
(define (compiler-load-dotted-import-same-alias-same-module-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_same_alias_dep.tl"
    "(module cl_same_alias_dep)
(define (get) : i64 7)")
  (compiler-load-write-file-text
    "target/cl_same_alias_entry.tl"
    "(import cl_same_alias_dep)
(import cl_same_alias_dep)
(import cl_same_alias_dep as dep)
(import cl_same_alias_dep as dep)
(define (main) : i64 (+ cl_same_alias_dep.get dep.get))")
  (match (compiler-load-file-with-paths
    "target/cl_same_alias_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Err _) false]
    [(Ok _ _ _ _) true]))

(define (compiler-load-dotted-import-resolution-ok?) : bool
  (and
    (string.eq
      (load.compiler-load-dotted-module-path "stdlib.core_macros")
      "stdlib/core_macros.tl")
    (match (load.compiler-load-resolve-module-import-with-roots
      "src/main.tl"
      "src/"
      "app.lib"
      (svec.new))
      [(Ok path) (string.eq path "src/app/lib.tl")]
      [(Err _) false])
    (match (load.compiler-load-resolve-module-import-with-roots
      "src/main.tl"
      "src/"
      "stdlib.core_macros"
      (svec.new))
      [(Ok path) (string.eq path "stdlib/core_macros.tl")]
      [(Err _) false])))

(define (compiler-load-decl-list-has-wildcard-import?
  [decls : ast.AstDeclList]
  [target-module : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(Import _ (Spec (ModuleAll) _ (Some module-name) (Some alias) span))
            (if (and
              (string.eq (ci.intern-str module-name) target-module)
              (= alias cbi.compiler-builtin-id-fix-empty)
              (> (ast.ast-source-span-start-line (deref span)) 0))
              true
              (compiler-load-decl-list-has-wildcard-import? rest target-module))]
          [_ (compiler-load-decl-list-has-wildcard-import? rest target-module)]))]))

(define (compiler-load-decl-list-has-selected-import?
  [decls : ast.AstDeclList]
  [target-module : String]
  [item : String]
  [alias-name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(Import
              _
              (Spec (ModuleItem item-id) _ (Some module-name) (Some alias) span))
            (if (and
              (string.eq (ci.intern-str module-name) target-module)
              (string.eq (ci.intern-str item-id) item)
              (string.eq (ci.intern-str alias) alias-name)
              (> (ast.ast-source-span-start-line (deref span)) 0))
              true
              (compiler-load-decl-list-has-selected-import?
                rest
                target-module
                item
                alias-name))]
          [_
            (compiler-load-decl-list-has-selected-import?
              rest
              target-module
              item
              alias-name)]))]))

(define (compiler-load-decl-path-lists-eq?
  [left : ast.AstDeclPathList]
  [right : ast.AstDeclPathList]) : bool
  (let
    [left-count : i64 (ast.ast-decl-path-list-len (& left))]
    [right-count : i64 (ast.ast-decl-path-list-len (& right))]
    [index : i64 0]
    [same : bool (= left-count right-count)]
    (while (and same (< index left-count))
      (unless
        (string.eq
          (ast.ast-decl-path-list-get (& left) index "")
          (ast.ast-decl-path-list-get (& right) index ""))
        (set! same false))
      (set! index (+ index 1)))
    same))

(define (compiler-load-decl-module-lists-eq?
  [left : ast.AstDeclModuleList]
  [right : ast.AstDeclModuleList]) : bool
  (let
    [left-count : i64 (ast.ast-decl-module-list-len (& left))]
    [right-count : i64 (ast.ast-decl-module-list-len (& right))]
    [index : i64 0]
    [same : bool (= left-count right-count)]
    (while (and same (< index left-count))
      (unless
        (string.eq
          (ast_tests.ast-decl-module-list-get (& left) index "")
          (ast_tests.ast-decl-module-list-get (& right) index ""))
        (set! same false))
      (set! index (+ index 1)))
    same))

(define (compiler-load-diagnostics-eq?
  [left : cdiag.CompilerDiagnostic]
  [right : cdiag.CompilerDiagnostic]) : bool
  (and
    (string.eq
      (cdiag.compiler-diagnostic-path (& left))
      (cdiag.compiler-diagnostic-path (& right)))
    (=
      (cdiag.compiler-diagnostic-line (& left))
      (cdiag.compiler-diagnostic-line (& right)))
    (string.eq
      (cdiag.compiler-diagnostic-message (& left))
      (cdiag.compiler-diagnostic-message (& right)))))

(define (compiler-load-import-suffix-decls-ok? [decls : ast.AstDeclList]) : bool
  (and
    (compiler-load-decl-list-has-wildcard-import?
      (ast.ast-place-shared-view decls)
      "pkg.shared")
    (compiler-load-decl-list-has-selected-import?
      (ast.ast-place-shared-view decls)
      "pkg.shared"
      "value"
      "chosen")
    (compiler-load-decl-list-has-selected-import?
      decls
      "pkg.shared"
      "Some"
      "chosen-some")))

;; Start line of the diagnostic's only secondary label, or 0 without one.
(define (compiler-load-diagnostic-label-line [diag : cdiag.CompilerDiagnostic]) : i64
  (let
    [labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans (& diag))]
    (if (= (cdiag.compiler-diagnostic-label-list-count (& labels)) 1)
      (let
        [label : cdiag.CompilerDiagnosticLabel
          (cdiag.compiler-diagnostic-label-list-get (& labels) 0)]
        (cdiag.compiler-diagnostic-span-start-line (& label.span)))
      0)))

;; Both walkers reject ENTRY with the same diagnostic: MESSAGE at PATH:LINE,
;; labelling the colliding local declaration at LABEL-LINE.
(define (compiler-load-import-local-collision-rejected?
  [entry : String]
  [roots : svec.Vec]
  [root : String]
  [message : String]
  [path : String]
  [line : i64]
  [label-line : i64]) : bool
  (match (load.compiler-load-file-with-paths-and-roots
    (string.copy (& entry))
    (sym_i64_env.sym-i64-empty)
    (ast.ast-place-shared-view roots))
    [(Err ordinary-diag)
      (let
        [ordinary : cdiag.CompilerDiagnostic (deref ordinary-diag)]
        (match (compiler-load-package-file-with-paths-and-roots
          entry
          (sym_i64_env.sym-i64-empty)
          (ast.ast-place-shared-view roots)
          root
          (load.compiler-pkg-deps-empty))
          [(Err package-diag)
            (let
              [package : cdiag.CompilerDiagnostic (deref package-diag)]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-message (& ordinary))
                  message)
                (string.eq (cdiag.compiler-diagnostic-path (& ordinary)) path)
                (= (cdiag.compiler-diagnostic-line (& ordinary)) line)
                (=
                  (compiler-load-diagnostic-label-line
                    (owned_view.compiler-owned-shared-view ordinary))
                  label-line)
                (=
                  (compiler-load-diagnostic-label-line
                    (owned_view.compiler-owned-shared-view package))
                  label-line)
                (compiler-load-diagnostics-eq? ordinary package)))]
          [(Ok _ _ _ _) false]))]
    [(Ok _ _ _ _) false]))

(define (compiler-load-import-local-collision-message
  [name : String]
  [module : String]) : String
  (str_cat.str-cat
    "compiler-load: unqualified import '"
    (str_cat.str-cat
      (string.copy (& name))
      (str_cat.str-cat
        "' from module 'pkg.local' collides with the declaration of '"
        (str_cat.str-cat name (str_cat.str-cat "' in " module))))))

;; An unqualified import (selected, aliased or wildcard) that binds a name its
;; module declares itself is rejected at the import, whatever the order and
;; whether the binding is used, for values, functions, types, constructors and
;; macros, in entry and non-entry modules. Aliases and qualified access avoid
;; the collision.
(define (compiler-load-import-local-collision-ok?) : bool
  (let
    [root : String "target/cl_import_local_root"]
    [roots : svec.Vec
      (compiler-load-string-vec-one
        (owned_view.compiler-owned-shared-view root))]
    (load.compiler-load-test-mkdir (owned_view.compiler-owned-shared-view root))
    (load.compiler-load-test-mkdir "target/cl_import_local_root/pkg")
    (compiler-load-write-file-text
      "target/cl_import_local_root/pkg/local.tl"
      "(module pkg.local)
(define answer : i64 42)
(define (helper [x : i64]) : i64 (* x 100))
(defstruct Pair (left i64))
(defenum Shape (Circle i64) (Square i64))
(defmacro (twice [value : Expr]) : Expr value)")
    (compiler-load-write-file-text
      "target/cl_import_local_root/pkg/dep.tl"
      "(module pkg.dep)
(import pkg.local.*)
(define (helper [x : i64]) : i64 (+ x 1))
(define (step0 [x : i64]) : i64 (helper x))")
    (compiler-load-write-file-text
      "target/cl_import_local_value.tl"
      "(module collide.value)
(import pkg.local.answer as value)
(define value : i64 1)
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_local_function.tl"
      "(module collide.function)
(import pkg.local.helper)
(define (helper [x : i64]) : i64 x)
(define (main) : i64 (helper 1))")
    (compiler-load-write-file-text
      "target/cl_import_local_type.tl"
      "(module collide.type)
(import pkg.local.*)
(defstruct Pair (right i64))
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_local_constructor.tl"
      "(module collide.constructor)
(import pkg.local.*)
(defenum Local (Circle) (Other))
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_local_macro.tl"
      "(module collide.macro)
(import pkg.local.twice)
(defmacro (twice [value : Expr]) : Expr value)
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_local_before.tl"
      "(module collide.before)
(define answer : i64 1)
(import pkg.local.answer)
(define (main) : i64 answer)")
    (compiler-load-write-file-text
      "target/cl_import_local_entry.tl"
      "(import pkg.local.answer)
(define answer : i64 1)
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_local_dep.tl"
      "(module collide.dep)
(import pkg.dep as dep)
(define (main) : i64 (dep.step0 10))")
    (compiler-load-write-file-text
      "target/cl_import_local_none.tl"
      "(module collide.none)
(import pkg.local.answer as imported)
(import pkg.local as local)
(define answer : i64 1)
(define (main) : i64 (+ answer (+ imported local.answer)))")
    (and
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_value.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "value"
          "module 'collide.value'")
        "target/cl_import_local_value.tl"
        2
        3)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_function.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "helper"
          "module 'collide.function'")
        "target/cl_import_local_function.tl"
        2
        3)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_type.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "Pair"
          "module 'collide.type'")
        "target/cl_import_local_type.tl"
        2
        3)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_constructor.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "Circle"
          "module 'collide.constructor'")
        "target/cl_import_local_constructor.tl"
        2
        3)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_macro.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "twice"
          "module 'collide.macro'")
        "target/cl_import_local_macro.tl"
        2
        3)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_before.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "answer"
          "module 'collide.before'")
        "target/cl_import_local_before.tl"
        3
        2)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_entry.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "answer"
          "the entry module")
        "target/cl_import_local_entry.tl"
        1
        2)
      (compiler-load-import-local-collision-rejected?
        "target/cl_import_local_dep.tl"
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (compiler-load-import-local-collision-message
          "helper"
          "module 'pkg.dep'")
        "target/cl_import_local_root/pkg/dep.tl"
        2
        3)
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_local_none.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Ok _ _ _ _) true]
        [(Err _) false])
      (match (compiler-load-package-file-with-paths-and-roots
        "target/cl_import_local_none.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (load.compiler-pkg-deps-empty))
        [(Ok _ _ _ _) true]
        [(Err _) false]))))

(define (compiler-load-import-suffix-resolution-ok?) : bool
  (let
    [root : String "target/cl_import_suffix_root"]
    [pkg-root : String "target/cl_import_suffix_root/pkg"]
    [roots : svec.Vec
      (compiler-load-string-vec-one
        (owned_view.compiler-owned-shared-view root))]
    (load.compiler-load-test-mkdir (owned_view.compiler-owned-shared-view root))
    (load.compiler-load-test-mkdir pkg-root)
    (compiler-load-write-file-text
      "target/cl_import_suffix_root/pkg/shared.tl"
      "(module pkg.shared)
(define value : i64 41)
(define (function [value : i64]) : i64 (+ value 1))
(defstruct SharedPair (value i64))
(defenum Choice (None) (Some i64))
(defmacro (macro [value : Expr]) : Expr value)")
    (compiler-load-write-file-text
      "target/cl_import_suffix_entry.tl"
      "(module suffix.entry)
(import pkg.shared.*)
(import pkg.shared.value as chosen)
(import pkg.shared.Some as chosen-some)
(define (main) : i64 chosen)")
    (compiler-load-write-file-text
      "target/cl_import_suffix_missing.tl"
      "(module suffix.missing)
(import pkg.shared.absent)
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_suffix_invalid.tl"
      "(module suffix.invalid)
(import pkg.shared.absent.extra)
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_suffix_root/pkg/macro-a.tl"
      "(module pkg.macro-a)
(defmacro (same-macro) : Expr '(+ 1 1))")
    (compiler-load-write-file-text
      "target/cl_import_suffix_root/pkg/macro-b.tl"
      "(module pkg.macro-b)
(defmacro (same-macro) : Expr '(+ 2 2))")
    (compiler-load-write-file-text
      "target/cl_import_suffix_collision.tl"
      "(module suffix.collision)
(import pkg.macro-a.*)
(import pkg.macro-b.*)
(define (main) : i64 0)")
    (compiler-load-write-file-text
      "target/cl_import_suffix_repeat.tl"
      "(module suffix.repeat)
(import pkg.shared.*)
(import pkg.shared.*)
(define (main) : i64 value)")
    ;; A module-scope generator leaves the parsed exports incomplete, so both
    ;; walkers defer a selection from it (present or not) to the completed
    ;; expansion instead of rejecting at load time.
    (compiler-load-write-file-text
      "target/cl_import_suffix_root/pkg/generated.tl"
      "(module pkg.generated)
(defmacro (emit-made) : Decls `(define made : i64 41))
(emit-made)")
    (compiler-load-write-file-text
      "target/cl_import_suffix_generated.tl"
      "(module suffix.generated)
(import pkg.generated.made as chosen)
(import pkg.generated.pending as unknown-yet)
(define (main) : i64 chosen)")
    (and
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_suffix_generated.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Ok _ _ _ _) true]
        [(Err _) false])
      (match (compiler-load-package-file-with-paths-and-roots
        "target/cl_import_suffix_generated.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots)
        (owned_view.compiler-owned-shared-view root)
        (load.compiler-pkg-deps-empty))
        [(Ok _ _ _ _) true]
        [(Err _) false])
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_suffix_entry.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Ok ordinary-decls ordinary-paths ordinary-modules _)
          (match (compiler-load-package-file-with-paths-and-roots
            "target/cl_import_suffix_entry.tl"
            (sym_i64_env.sym-i64-empty)
            (ast.ast-place-shared-view roots)
            (owned_view.compiler-owned-shared-view root)
            (load.compiler-pkg-deps-empty))
            [(Ok package-decls package-paths package-modules _)
              (and
                (=
                  (compiler-load-decl-list-count ordinary-decls)
                  (compiler-load-decl-list-count package-decls))
                (compiler-load-import-suffix-decls-ok? ordinary-decls)
                (compiler-load-import-suffix-decls-ok? package-decls)
                (compiler-load-decl-path-lists-eq? ordinary-paths package-paths)
                (compiler-load-decl-module-lists-eq?
                  ordinary-modules
                  package-modules))]
            [(Err _) false])]
        [(Err _) false])
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_suffix_missing.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Err ordinary-diag)
          (let
            [ordinary-value : cdiag.CompilerDiagnostic (deref ordinary-diag)]
            (match (compiler-load-package-file-with-paths-and-roots
              "target/cl_import_suffix_missing.tl"
              (sym_i64_env.sym-i64-empty)
              (ast.ast-place-shared-view roots)
              (owned_view.compiler-owned-shared-view root)
              (load.compiler-pkg-deps-empty))
              [(Err package-diag)
                (let
                  [package-value : cdiag.CompilerDiagnostic
                    (deref package-diag)]
                  (and
                    (string.eq
                      (cdiag.compiler-diagnostic-message ordinary-value)
                      "compiler-load: module 'pkg.shared' has no selected item 'absent'")
                    (> (cdiag.compiler-diagnostic-line ordinary-value) 0)
                    (compiler-load-diagnostics-eq? ordinary-value package-value)))]
              [(Ok _ _ _ _) false]))]
        [(Ok _ _ _ _) false])
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_suffix_invalid.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Err ordinary-diag)
          (let
            [ordinary-value : cdiag.CompilerDiagnostic (deref ordinary-diag)]
            (match (compiler-load-package-file-with-paths-and-roots
              "target/cl_import_suffix_invalid.tl"
              (sym_i64_env.sym-i64-empty)
              (ast.ast-place-shared-view roots)
              (owned_view.compiler-owned-shared-view root)
              (load.compiler-pkg-deps-empty))
              [(Err package-diag)
                (let
                  [package-value : cdiag.CompilerDiagnostic
                    (deref package-diag)]
                  (and
                    (string.eq
                      (cdiag.compiler-diagnostic-message ordinary-value)
                      "compiler-load: import 'pkg.shared.absent.extra' leaves more than one segment after loadable module 'pkg.shared'; only one selected item is supported")
                    (> (cdiag.compiler-diagnostic-line ordinary-value) 0)
                    (compiler-load-diagnostics-eq? ordinary-value package-value)))]
              [(Ok _ _ _ _) false]))]
        [(Ok _ _ _ _) false])
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_suffix_collision.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Err ordinary-diag)
          (let
            [ordinary-value : cdiag.CompilerDiagnostic (deref ordinary-diag)]
            (match (compiler-load-package-file-with-paths-and-roots
              "target/cl_import_suffix_collision.tl"
              (sym_i64_env.sym-i64-empty)
              (ast.ast-place-shared-view roots)
              (owned_view.compiler-owned-shared-view root)
              (load.compiler-pkg-deps-empty))
              [(Err package-diag)
                (let
                  [package-value : cdiag.CompilerDiagnostic
                    (deref package-diag)]
                  (and
                    (string.eq
                      (cdiag.compiler-diagnostic-path ordinary-value)
                      "target/cl_import_suffix_collision.tl")
                    (= (cdiag.compiler-diagnostic-line ordinary-value) 3)
                    (string.eq
                      (cdiag.compiler-diagnostic-message ordinary-value)
                      "compiler-load: ambiguous unqualified import 'same-macro' between modules 'pkg.macro-a' and 'pkg.macro-b'; use explicit selected aliases or qualified access")
                    (compiler-load-diagnostics-eq? ordinary-value package-value)))]
              [(Ok _ _ _ _) false]))]
        [(Ok _ _ _ _) false])
      (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_import_suffix_repeat.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Ok _ _ _ _)
          (match (compiler-load-package-file-with-paths-and-roots
            "target/cl_import_suffix_repeat.tl"
            (sym_i64_env.sym-i64-empty)
            roots
            root
            (load.compiler-pkg-deps-empty))
            [(Ok _ _ _ _) true]
            [(Err _) false])]
        [(Err _) false]))))

(define (compiler-load-session-cache-common-dep-ok?) : bool
  (let
    [root : String "target/cl_cache_common_root"]
    [dep-suffix : String "cache_dep.tl"]
    [dep-file : String
      (load.compiler-load-join-root-path (string.copy root) dep-suffix)]
    [roots : svec.Vec (compiler-load-string-vec-one (string.copy root))]
    (load.compiler-load-test-mkdir root)
    (compiler-load-write-file-text
      dep-file
      "(module stdlib.cache_dep)
(define dep-value : i64 1)")
    (compiler-load-write-file-text
      "target/cl_cache_entry_a.tl"
      "(module cache.entry.a)
(import stdlib.cache_dep as dep)
(define entry-a : i64 1)")
    (compiler-load-write-file-text
      "target/cl_cache_entry_b.tl"
      "(module cache.entry.b)
(import stdlib.cache_dep as dep)
(define entry-b : i64 2)")
    (load.compiler-load-session-cache-enable!)
    (load.compiler-load-program-cache-clear!)
    (let
      [ok : bool false]
      (if (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_cache_entry_a.tl"
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots))
        [(Ok _ _ _ _) true]
        [(Err _) false])
        (begin
          (load.compiler-load-session-reset-pools!)
          (load.compiler-load-session-reset-interns!)
          (match (load.compiler-load-file-with-paths-and-roots
            "target/cl_cache_entry_b.tl"
            (sym_i64_env.sym-i64-empty)
            roots)
            [(Ok _ _ _ _)
              (set!
                ok
                (and
                  (> (compiler-load-program-cache-hit-count-value) 0)
                  (>= (compiler-load-program-cache-store-count-value) 1)))]
            [(Err _) (set! ok false)]))
        (set! ok false))
      (load.compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-load-session-cache-root-isolation-ok?) : bool
  (let
    [root-a : String "target/cl_cache_root_a"]
    [root-b : String "target/cl_cache_root_b"]
    [dep-suffix : String "cache_root_dep.tl"]
    [root-a-file : String
      (load.compiler-load-join-root-path
        (string.copy root-a)
        (string.copy dep-suffix))]
    [root-b-file : String
      (load.compiler-load-join-root-path
        (string.copy root-b)
        (string.copy dep-suffix))]
    [roots-a : svec.Vec (compiler-load-string-vec-one (string.copy root-a))]
    [roots-b : svec.Vec (compiler-load-string-vec-one (string.copy root-b))]
    (load.compiler-load-test-mkdir root-a)
    (load.compiler-load-test-mkdir root-b)
    (compiler-load-write-file-text
      root-a-file
      "(module stdlib.cache_root_dep)
(define root-value : i64 1)")
    (compiler-load-write-file-text
      root-b-file
      "(module stdlib.cache_root_dep)
(define root-value : i64 2)")
    (compiler-load-write-file-text
      "target/cl_cache_root_entry_a.tl"
      "(module cache.root.entry.a)
(import stdlib.cache_root_dep as dep)
(define entry-a : i64 1)")
    (compiler-load-write-file-text
      "target/cl_cache_root_entry_b.tl"
      "(module cache.root.entry.b)
(import stdlib.cache_root_dep as dep)
(define entry-b : i64 2)")
    (load.compiler-load-session-cache-enable!)
    (load.compiler-load-program-cache-clear!)
    (let
      [ok : bool false]
      (if (match (load.compiler-load-file-with-paths-and-roots
        "target/cl_cache_root_entry_a.tl"
        (sym_i64_env.sym-i64-empty)
        roots-a)
        [(Ok _ _ _ _) true]
        [(Err _) false])
        (begin
          (load.compiler-load-session-reset-pools!)
          (load.compiler-load-session-reset-interns!)
          (match (load.compiler-load-file-with-paths-and-roots
            "target/cl_cache_root_entry_b.tl"
            (sym_i64_env.sym-i64-empty)
            roots-b)
            [(Ok _ _ _ _) (set! ok true)]
            [(Err _) (set! ok false)]))
        (set! ok false))
      (load.compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-load-session-cache-entry-cold-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_cache_cold_entry.tl"
    "(module cache.cold.entry)
(define entry-value : i64 1)")
  (load.compiler-load-session-cache-enable!)
  (load.compiler-load-program-cache-clear!)
  (let
    [ok : bool false]
    (if (match (load.compiler-load-entry-file-with-paths-and-roots-cfg
      "target/cl_cache_cold_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      (parser.compiler-cfg-empty))
      [(Ok _ _ _ _) true]
      [(Err _) false])
      (begin
        (load.compiler-load-session-reset-pools!)
        (load.compiler-load-session-reset-interns!)
        (match (load.compiler-load-entry-file-with-paths-and-roots-cfg
          "target/cl_cache_cold_entry.tl"
          (sym_i64_env.sym-i64-empty)
          (svec.new)
          (parser.compiler-cfg-empty))
          [(Ok _ _ _ _)
            (set!
              ok
              (and
                (= (compiler-load-program-cache-hit-count-value) 0)
                (= (compiler-load-program-cache-store-count-value) 0)))]
          [(Err _) (set! ok false)]))
      (set! ok false))
    (load.compiler-load-session-cache-disable-for-test!)
    ok))

(define (compiler-load-session-persistent-floor-interns-ok?) : bool
  (load.compiler-load-session-cache-enable!)
  (load.compiler-load-session-program-cache-disable!)
  (let
    [id : i64
      (with-scratch
        (let
          [name : String (str_cat.str-cat "cache.floor." "transient")]
          [interned : i64 (ci.intern name)]
          (load.compiler-load-session-note-persistent!)
          interned))]
    (load.compiler-load-session-reset-interns!)
    (let
      [again : i64 (ci.intern "cache.floor.transient")]
      [ok : bool (= id again)]
      (load.compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-load-session-cache-local-common-dep-ok?) : bool
  (let
    [dir : String "target/cl_cache_local"]
    [dep : String
      (load.compiler-load-join-root-path (string.copy dir) "dep.tl")]
    [entry-a : String
      (load.compiler-load-join-root-path (string.copy dir) "entry_a.tl")]
    [entry-b : String
      (load.compiler-load-join-root-path (string.copy dir) "entry_b.tl")]
    [entry-c : String
      (load.compiler-load-join-root-path (string.copy dir) "entry_c.tl")]
    (load.compiler-load-test-mkdir (string.copy dir))
    (compiler-load-write-file-text
      (string.copy dep)
      "(module dep)
(define dep-value : i64 1)")
    (compiler-load-write-file-text
      (string.copy entry-a)
      "(module cache.local.entry.a)
(import dep)
(define entry-a : i64 1)")
    (compiler-load-write-file-text
      (string.copy entry-b)
      "(module cache.local.entry.b)
(import dep)
(define entry-b : i64 2)")
    (compiler-load-write-file-text
      (string.copy entry-c)
      "(module cache.local.entry.c)
(import dep)
(define entry-c : i64 3)")
    (load.compiler-load-session-cache-enable!)
    (load.compiler-load-program-cache-clear!)
    (let
      [ok : bool false]
      (if (match (load.compiler-load-entry-file-with-paths-and-roots-cfg
        entry-a
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        (parser.compiler-cfg-empty))
        [(Ok _ _ _ _) true]
        [(Err _) false])
        (begin
          (load.compiler-load-session-reset-pools!)
          (load.compiler-load-session-reset-interns!)
          (match (load.compiler-load-entry-file-with-paths-and-roots-cfg
            entry-b
            (sym_i64_env.sym-i64-empty)
            (svec.new)
            (parser.compiler-cfg-empty))
            [(Ok _ _ _ _)
              (load.compiler-load-session-reset-pools!)
              (load.compiler-load-session-reset-interns!)
              (match (load.compiler-load-entry-file-with-paths-and-roots-cfg
                entry-c
                (sym_i64_env.sym-i64-empty)
                (svec.new)
                (parser.compiler-cfg-empty))
                [(Ok _ _ _ _)
                  (set!
                    ok
                    (and
                      (> (compiler-load-program-cache-hit-count-value) 0)
                      (>= (compiler-load-program-cache-store-count-value) 1)))]
                [(Err _) (set! ok false)])]
            [(Err _) (set! ok false)]))
        (set! ok false))
      (load.compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-load-session-cache-package-common-dep-ok?) : bool
  (let
    [root : String "target/cl_cache_pkg"]
    [src : String (load.compiler-load-join-root-path (string.copy root) "src")]
    [dep : String
      (load.compiler-load-join-root-path (string.copy src) "common.tl")]
    [entry-a : String
      (load.compiler-load-join-root-path (string.copy src) "entry_a.tl")]
    [entry-b : String
      (load.compiler-load-join-root-path (string.copy src) "entry_b.tl")]
    [entry-c : String
      (load.compiler-load-join-root-path (string.copy src) "entry_c.tl")]
    [deps : load.CompilerPkgDeps (load.compiler-pkg-deps-empty)]
    (load.compiler-load-test-mkdir (string.copy root))
    (load.compiler-load-test-mkdir (string.copy src))
    (compiler-load-write-file-text
      (string.copy dep)
      "(module common)
(define common-value : i64 1)")
    (compiler-load-write-file-text
      (string.copy entry-a)
      "(module cache.pkg.entry.a)
(import common)
(define entry-a : i64 1)")
    (compiler-load-write-file-text
      (string.copy entry-b)
      "(module cache.pkg.entry.b)
(import common)
(define entry-b : i64 2)")
    (compiler-load-write-file-text
      (string.copy entry-c)
      "(module cache.pkg.entry.c)
(import common)
(define entry-c : i64 3)")
    (load.compiler-load-session-cache-enable!)
    (load.compiler-load-program-cache-clear!)
    (let
      [ok : bool false]
      (if (match (load.compiler-load-package-entry-file-with-paths-and-roots-cfg
        entry-a
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        (string.copy root)
        (ast.ast-place-shared-view deps)
        (parser.compiler-cfg-empty))
        [(Ok _ _ _ _) true]
        [(Err _) false])
        (begin
          (load.compiler-load-session-reset-pools!)
          (load.compiler-load-session-reset-interns!)
          (match (load.compiler-load-package-entry-file-with-paths-and-roots-cfg
            entry-b
            (sym_i64_env.sym-i64-empty)
            (svec.new)
            (string.copy root)
            (ast.ast-place-shared-view deps)
            (parser.compiler-cfg-empty))
            [(Ok _ _ _ _)
              (load.compiler-load-session-reset-pools!)
              (load.compiler-load-session-reset-interns!)
              (match (load.compiler-load-package-entry-file-with-paths-and-roots-cfg
                entry-c
                (sym_i64_env.sym-i64-empty)
                (svec.new)
                root
                deps
                (parser.compiler-cfg-empty))
                [(Ok _ _ _ _)
                  (set!
                    ok
                    (and
                      (> (compiler-load-program-cache-hit-count-value) 0)
                      (>= (compiler-load-program-cache-store-count-value) 1)))]
                [(Err _) (set! ok false)])]
            [(Err _) (set! ok false)]))
        (set! ok false))
      (load.compiler-load-session-cache-disable-for-test!)
      ok)))

(define (compiler-load-dotted-source-root-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_dotted_src")
  (load.compiler-load-test-mkdir "target/cl_dotted_src/nested")
  (compiler-load-write-file-text
    "target/cl_dotted_src/root_leaf.tl"
    "(module root_leaf)
(define leaf-val : i64 1)")
  (compiler-load-write-file-text
    "target/cl_dotted_src/nested/dep.tl"
    "(module nested.dep)
(import root_leaf as leaf)
(define dep-val : i64 leaf-val)")
  (compiler-load-write-file-text
    "target/cl_dotted_src/entry.tl"
    "(module dotted.entry)
(import nested.dep)
(define (main) : i64 dep-val)")
  (match (compiler-load-file-with-paths
    "target/cl_dotted_src/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok _ _ _ seen)
      (and
        (compiler-load-test-seen-contains? seen "dotted.entry")
        (compiler-load-test-seen-contains? seen "nested.dep")
        (compiler-load-test-seen-contains? seen "root_leaf"))]
    [(Err _) false]))

(define (compiler-load-moduleless-dotted-source-root-ok?) : bool
  (load.compiler-load-test-mkdir "target/cl_moduleless_dotted_src")
  (load.compiler-load-test-mkdir "target/cl_moduleless_dotted_src/nested")
  (compiler-load-write-file-text
    "target/cl_moduleless_dotted_src/root_leaf.tl"
    "(define leaf-val : i64 1)")
  (compiler-load-write-file-text
    "target/cl_moduleless_dotted_src/nested/dep.tl"
    "(import root_leaf as leaf)
(define dep-val : i64 leaf.leaf-val)")
  (compiler-load-write-file-text
    "target/cl_moduleless_dotted_src/entry.tl"
    "(module moduleless.dotted.entry)
(import nested.dep)
(define (main) : i64 dep.dep-val)")
  (match (compiler-load-file-with-paths
    "target/cl_moduleless_dotted_src/entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ seen)
      (and
        (load.compiler-load-decl-list-has-module-id?
          (ast.ast-place-shared-view decls)
          (load.compiler-load-parse-context-name-id "root_leaf"))
        (load.compiler-load-decl-list-has-module-id?
          (ast.ast-place-shared-view decls)
          (load.compiler-load-parse-context-name-id "nested.dep"))
        (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
        (compiler-load-test-seen-contains? seen "root_leaf")
        (compiler-load-test-seen-contains? seen "nested.dep"))]
    [(Err _) false]))

(define (compiler-load-stdlib-source-module-import-ok?) : bool
  (and
    (load.compiler-load-stdlib-source-module-import? "stdlib/vector.tl")
    (load.compiler-load-stdlib-source-module-import? "stdlib\\vector.tl")
    (not
      (load.compiler-load-stdlib-source-module-import?
        "stdlib/tests/thread_api.tl"))
    (not
      (load.compiler-load-stdlib-source-module-import?
        "stdlib\\tests\\thread_api.tl"))))

(define (compiler-load-dotted-source-root-fallback-ok?) : bool
  (let
    [root : String "target/cl_dotted_src_fallback/src"]
    [tests : String
      (load.compiler-load-join-root-path (string.copy root) "tests")]
    [leaf : String
      (load.compiler-load-join-root-path (string.copy root) "leaf.tl")]
    [mid : String
      (load.compiler-load-join-root-path (string.copy root) "mid.tl")]
    [entry : String
      (load.compiler-load-join-root-path (string.copy tests) "entry.tl")]
    [roots : svec.Vec (compiler-load-string-vec-one (string.copy root))]
    (load.compiler-load-test-mkdir "target/cl_dotted_src_fallback")
    (load.compiler-load-test-mkdir root)
    (load.compiler-load-test-mkdir tests)
    (compiler-load-write-file-text
      leaf
      "(module leaf)
(define leaf-val : i64 1)")
    (compiler-load-write-file-text
      mid
      "(module mid)
(import leaf)
(define mid-val : i64 leaf.leaf-val)")
    (compiler-load-write-file-text
      (string.copy entry)
      "(module fallback.entry)
(import mid)
(define (main) : i64 mid.mid-val)")
    (match (load.compiler-load-file-with-paths-and-roots
      (string.copy entry)
      (sym_i64_env.sym-i64-empty)
      roots)
      [(Ok _ _ _ seen)
        (and
          (compiler-load-test-seen-contains? seen "fallback.entry")
          (compiler-load-test-seen-contains? seen "mid")
          (compiler-load-test-seen-contains? seen "leaf"))]
      [(Err _) false])))

(define (compiler-load-dotted-transitive-import-ok?) : bool
  (let
    [root : String "target/cl_dotted_after_path/src"]
    [helper : String
      (load.compiler-load-join-root-path (string.copy root) "helper.tl")]
    [provider : String
      (load.compiler-load-join-root-path (string.copy root) "provider.tl")]
    [entry : String
      (load.compiler-load-join-root-path (string.copy root) "entry.tl")]
    (load.compiler-load-test-mkdir "target/cl_dotted_after_path")
    (load.compiler-load-test-mkdir root)
    (compiler-load-write-file-text
      helper
      "(module helper)
(define answer : i64 42)")
    (compiler-load-write-file-text
      provider
      "(module provider)
(import helper as helper)
(define value : i64 helper.answer)")
    (compiler-load-write-file-text
      (string.copy entry)
      "(import provider)
(define (main) : i64 provider.value)")
    (match (compiler-load-file-with-paths entry (sym_i64_env.sym-i64-empty))
      [(Ok _ _ _ seen)
        (and
          (compiler-load-test-seen-contains? seen "provider")
          (compiler-load-test-seen-contains? seen "helper"))]
      [(Err _) false])))

(define (compiler-load-canonical-source-explicit-mismatch-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_canonical_source_explicit.tl"
    "(module canonical.actual)
(define value : i64 42)")
  (compiler-load-write-file-text
    "target/cl_canonical_source_explicit_entry.tl"
    "(import cl_canonical_source_explicit as wrong)
(define (main) : i64 wrong.value)")
  (match (compiler-load-file-with-paths
    "target/cl_canonical_source_explicit_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: import expected module cl_canonical_source_explicit but loaded canonical.actual")]
    [(Ok _ _ _ _) false]))

(define (compiler-load-package-dotted-import-resolution-ok?) : bool
  (let
    [deps : load.CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (and
      (match (load.compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (Module)
        "app.lib"
        No
        (svec.new)
        "proj"
        (ast.ast-place-shared-view deps))
        [(Ok path) (string.eq path "proj/app/lib.tl")]
        [(Err _) false])
      (match (load.compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (Module)
        "math.src.add"
        No
        (svec.new)
        "proj"
        (ast.ast-place-shared-view deps))
        [(Ok path) (string.eq path "math/src/add.tl")]
        [(Err _) false])
      (load.compiler-load-package-import-externs?
        (Module)
        "math.src.add"
        No
        (ast.ast-place-shared-view deps))
      (not
        (load.compiler-load-package-import-externs?
          (Module)
          "stdlib.core_macros"
          No
          deps)))))

(define (compiler-load-package-dotted-sibling-source-ok?) : bool
  (let
    [root : String "target/cl_pkg_dotted_src"]
    [src : String (load.compiler-load-join-root-path (string.copy root) "src")]
    [entry : String
      (load.compiler-load-join-root-path (string.copy src) "main.tl")]
    [dep : String
      (load.compiler-load-join-root-path (string.copy src) "dep.tl")]
    [deps : load.CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (load.compiler-load-test-mkdir (string.copy root))
    (load.compiler-load-test-mkdir (string.copy src))
    (compiler-load-write-file-text
      (string.copy dep)
      "(module dep)
(define dep-val : i64 1)")
    (match (load.compiler-load-resolve-package-import-spec
      entry
      (Module)
      "dep"
      No
      (svec.new)
      root
      deps)
      [(Ok path) (string.eq path (load.compiler-load-normalize-path dep))]
      [(Err _) false])))

(define (compiler-load-package-second-root-source-ok?) : bool
  (let
    [base : String "target/cl_pkg_second_root"]
    [first-root : String
      (load.compiler-load-join-root-path (string.copy base) "first")]
    [second-root : String
      (load.compiler-load-join-root-path (string.copy base) "second")]
    [tests-root : String
      (load.compiler-load-join-root-path (string.copy base) "tests")]
    [entry : String
      (load.compiler-load-join-root-path (string.copy tests-root) "entry.tl")]
    [dep : String
      (load.compiler-load-join-root-path
        (string.copy second-root)
        "root_helper.tl")]
    [first-order : String
      (load.compiler-load-join-root-path
        (string.copy first-root)
        "root_order.tl")]
    [second-order : String
      (load.compiler-load-join-root-path
        (string.copy second-root)
        "root_order.tl")]
    [roots : svec.Vec (svec.new)]
    (load.compiler-load-test-mkdir (string.copy base))
    (load.compiler-load-test-mkdir (string.copy first-root))
    (load.compiler-load-test-mkdir (string.copy second-root))
    (load.compiler-load-test-mkdir (string.copy tests-root))
    (compiler-load-write-file-text
      (string.copy dep)
      "(module root_helper)
(define answer : i64 42)")
    (compiler-load-write-file-text
      (string.copy entry)
      "(import root_helper)
(define (main) : i64 root_helper.answer)")
    (compiler-load-write-file-text
      (string.copy first-order)
      "(module root_order)
(define answer : i64 1)")
    (compiler-load-write-file-text
      (string.copy second-order)
      "(module root_order)
(define answer : i64 2)")
    (svec.push-ref! (&mut roots) first-root)
    (svec.push-ref! (&mut roots) second-root)
    (let
      [order-ok : bool
        (match (load.compiler-load-resolve-package-import-spec
          (string.copy entry)
          (Module)
          "root_order"
          No
          (ast.ast-place-shared-view roots)
          (string.copy base)
          (load.compiler-pkg-deps-empty))
          [(Ok path)
            (string.eq path (load.compiler-load-normalize-path first-order))]
          [(Err _) false])]
      (and
        order-ok
        (match (compiler-load-package-file-with-paths-and-roots
          entry
          (sym_i64_env.sym-i64-empty)
          roots
          base
          (load.compiler-pkg-deps-empty))
          [(Ok _ _ _ _) true]
          [(Err _) false])))))

(define (compiler-load-package-moduleless-pkg-import-id-ok?) : bool
  (let
    [base : String "target/cl_pkg_moduleless_id"]
    [app-root : String
      (load.compiler-load-join-root-path (string.copy base) "app")]
    [app-src : String
      (load.compiler-load-join-root-path (string.copy app-root) "src")]
    [math-root : String
      (load.compiler-load-join-root-path (string.copy base) "math")]
    [math-src : String
      (load.compiler-load-join-root-path (string.copy math-root) "src")]
    [entry : String
      (load.compiler-load-join-root-path (string.copy app-src) "main.tl")]
    [dep : String
      (load.compiler-load-join-root-path (string.copy math-src) "add.tl")]
    [deps : load.CompilerPkgDeps
      (load.compiler-pkg-deps-cons
        "math"
        "../math"
        (load.compiler-pkg-deps-empty))]
    (load.compiler-load-test-mkdir (string.copy base))
    (load.compiler-load-test-mkdir (string.copy app-root))
    (load.compiler-load-test-mkdir (string.copy app-src))
    (load.compiler-load-test-mkdir (string.copy math-root))
    (load.compiler-load-test-mkdir (string.copy math-src))
    (compiler-load-write-file-text
      (load.compiler-load-join-root-path (string.copy math-root) "typelisp.pkg")
      "(package (name \"math\") (version \"1\") (kind staticlib) (entry \"src/add.tl\"))")
    (compiler-load-write-file-text
      (string.copy dep)
      "(define (add [x : i64]) : i64 (+ x 1))")
    (compiler-load-write-file-text
      (string.copy entry)
      "(module pkg.moduleless.entry)
(import math.src.add)
(define (main) : i64 0)")
    (match (compiler-load-package-file-with-paths-and-roots
      entry
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      app-root
      deps)
      [(Ok decls _ _ seen)
        (and
          (compiler-load-decl-list-has-extern-symbol?
            decls
            "_tl_math_src_add_add")
          (compiler-load-test-seen-contains? seen "math.src.add")
          (not (compiler-load-test-seen-contains? seen dep)))]
      [(Err _) false])))

(define (compiler-load-package-dotted-explicit-module-id-ok?) : bool
  (let
    [base : String "target/cl_pkg_dotted_explicit_id"]
    [app-root : String
      (load.compiler-load-join-root-path (string.copy base) "app")]
    [app-src : String
      (load.compiler-load-join-root-path (string.copy app-root) "src")]
    [math-root : String
      (load.compiler-load-join-root-path (string.copy base) "math")]
    [math-src : String
      (load.compiler-load-join-root-path (string.copy math-root) "src")]
    [entry : String
      (load.compiler-load-join-root-path (string.copy app-src) "main.tl")]
    [dep : String
      (load.compiler-load-join-root-path (string.copy math-src) "add.tl")]
    [deps : load.CompilerPkgDeps
      (load.compiler-pkg-deps-cons
        "math"
        "../math"
        (load.compiler-pkg-deps-empty))]
    (load.compiler-load-test-mkdir (string.copy base))
    (load.compiler-load-test-mkdir (string.copy app-root))
    (load.compiler-load-test-mkdir (string.copy app-src))
    (load.compiler-load-test-mkdir (string.copy math-root))
    (load.compiler-load-test-mkdir (string.copy math-src))
    (compiler-load-write-file-text
      (load.compiler-load-join-root-path (string.copy math-root) "typelisp.pkg")
      "(package (name \"math\") (version \"1\") (kind staticlib) (entry \"src/add.tl\"))")
    (compiler-load-write-file-text
      (string.copy dep)
      "(module arithmetic.public)
(define (add [x : i64]) : i64 (+ x 1))")
    (compiler-load-write-file-text
      (string.copy entry)
      "(module pkg.dotted.explicit.entry)
(import math.src.add as math_add)
(define (main) : i64 (math_add.add 1))")
    (match (compiler-load-package-file-with-paths-and-roots
      entry
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      app-root
      deps)
      [(Ok decls _ _ seen)
        (and
          (compiler-load-decl-list-has-import-alias?
            decls
            "arithmetic.public"
            "math_add")
          (compiler-load-test-seen-contains? seen "arithmetic.public"))]
      [(Err _) false])))

(define (compiler-load-generated-meta-preserved-ok?) : bool
  (let
    [meta : ast.AstGeneratedDeclMeta
      (Some "gen" "generated-fn" (ast.ast-expr-list-new) "")]
    [inner : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (load.compiler-load-parse-context-name-id "generated-fn")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))]
    [decl : ast.AstDecl (ast.ast-decl-comptime-decl-with-meta meta inner)]
    (match (load.compiler-load-package-transform-decl
      "demo"
      ""
      (svec.new)
      "src/main.tl"
      "main"
      Unavailable
      decl)
      [(CompilerLoadSomeDecl transformed)
        (and
          (match (ast.ast-decl-generated-meta transformed)
            [(Some generator item arg-keys _)
              (and
                (string.eq generator "gen")
                (string.eq item "generated-fn")
                (= (ast.ast-expr-list-len (& arg-keys)) 0))]
            [_ false])
          (match transformed
            [(Extern decl-meta name _ _ _)
              (string.eq (ci.intern-str name) "generated-fn")]
            [_ false]))]
      [(CompilerLoadNoDecl) false])))

;; Diamond import dedup: entry imports A and B, both of which
;; import C; C must load exactly once. Writes fixture modules under target/ and
;; loads through the file loader, mirroring the existing dedup/cycle self-test.
(define (compiler-load-diamond-import-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_diamond_c.tl"
    "(module cl_diamond_c)
(define c-val : i64 1)")
  (compiler-load-write-file-text
    "target/cl_diamond_a.tl"
    "(module cl_diamond_a)
(import cl_diamond_c as c)
(define a-val : i64 c.c-val)")
  (compiler-load-write-file-text
    "target/cl_diamond_b.tl"
    "(module cl_diamond_b)
(import cl_diamond_c as c)
(define b-val : i64 c.c-val)")
  (compiler-load-write-file-text
    "target/cl_diamond_entry.tl"
    "(module cl_diamond_entry)
(import cl_diamond_a as a)
(import cl_diamond_b as b)
(define (main) : i64 (+ a.a-val b.b-val))")
  (match (compiler-load-file-with-paths
    "target/cl_diamond_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ seen)
      (and
        (= (compiler-load-decl-list-count decls) 17)
        (compiler-load-test-seen-contains? seen "cl_diamond_c")
        (compiler-load-test-seen-contains? seen "cl_diamond_a")
        (compiler-load-test-seen-contains? seen "cl_diamond_b")
        (compiler-load-test-seen-contains? seen "cl_diamond_entry"))]
    [(Err _) false]))

;; Transitive import dedup: entry imports A, A imports B, B
;; imports C; the whole chain loads with the deterministic loaded decl count and
;; every module recorded in the seen set.
(define (compiler-load-transitive-import-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_tr_c.tl"
    "(module cl_tr_c)
(define c-val : i64 1)")
  (compiler-load-write-file-text
    "target/cl_tr_b.tl"
    "(module cl_tr_b)
(import cl_tr_c as c)
(define b-val : i64 c.c-val)")
  (compiler-load-write-file-text
    "target/cl_tr_a.tl"
    "(module cl_tr_a)
(import cl_tr_b as b)
(define a-val : i64 b.b-val)")
  (compiler-load-write-file-text
    "target/cl_tr_entry.tl"
    "(module cl_tr_entry)
(import cl_tr_a as a)
(define (main) : i64 a.a-val)")
  (match (compiler-load-file-with-paths
    "target/cl_tr_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ seen)
      (and
        (= (compiler-load-decl-list-count decls) 14)
        (compiler-load-test-seen-contains? seen "cl_tr_c")
        (compiler-load-test-seen-contains? seen "cl_tr_b")
        (compiler-load-test-seen-contains? seen "cl_tr_a")
        (compiler-load-test-seen-contains? seen "cl_tr_entry"))]
    [(Err _) false]))

;; An import whose module does not resolve to a readable file reports a
;; `cannot read import <path>` diagnostic.
(define (compiler-load-missing-import-ok?) : bool
  (match (load.compiler-load-source
    "src/app.tl"
    "(import no_such_module_xyz)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read import src/no_such_module_xyz.tl")]
    [(Ok _ _) false]))

(define (compiler-load-include-str-relative-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_include_payload.txt"
    "hello from include")
  (compiler-load-write-file-text
    "target/cl_include_entry.tl"
    "(include-str payload \"cl_include_payload.txt\")
(define (main) : i64 0)")
  (match (compiler-load-file-with-paths
    "target/cl_include_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-first-string-def? decls "payload" "hello from include"))]
    [(Err _) false]))

(define (compiler-load-include-str-stdlib-root-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_include_root_payload.txt"
    "hello from root")
  (match (load.compiler-load-source-with-paths-and-roots
    "src/include_entry.tl"
    "(include-str embedded \"stdlib/cl_include_root_payload.txt\")
(define (main) : i64 0)"
    (sym_i64_env.sym-i64-empty)
    (compiler-load-string-vec-one "target"))
    [(Ok decls _ _ _)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-first-string-def? decls "embedded" "hello from root"))]
    [(Err _) false]))

(define (compiler-load-include-str-comptime-relative-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_include_comptime_payload.txt"
    "only at comptime")
  (compiler-load-write-file-text
    "target/cl_include_comptime_entry.tl"
    "(include-str-comptime payload \"cl_include_comptime_payload.txt\")
(define (main) : i64 0)")
  (match (compiler-load-file-with-paths
    "target/cl_include_comptime_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-first-string-macro? decls "payload" "only at comptime"))]
    [(Err _) false]))

(define (compiler-load-include-str-lzss-relative-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_include_lzss_payload.txt"
    "compress me")
  (compiler-load-write-file-text
    "target/cl_include_lzss_entry.tl"
    "(include-str-lzss payload \"cl_include_lzss_payload.txt\")
(define (main) : i64 0)")
  (match (compiler-load-file-with-paths
    "target/cl_include_lzss_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-first-lzss-def? decls "payload" "compress me"))]
    [(Err _) false]))

;; `include-str-lzss` of a `.tl` source blanks its top-level inline tests to
;; their line breaks; any other path is compressed exactly (#8713).
(define (compiler-load-include-str-lzss-source-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_include_lzss_source.tl"
    "(define a : i64 1)\n(test t\n  (keep a))\n(cfg test (define helper : i64 2))\n(define b : i64 3)\n")
  (compiler-load-write-file-text
    "target/cl_include_lzss_text.txt"
    "(test t (keep a))\n")
  (compiler-load-write-file-text
    "target/cl_include_lzss_source_entry.tl"
    "(include-str-lzss source \"cl_include_lzss_source.tl\")
(define (main) : i64 0)")
  (compiler-load-write-file-text
    "target/cl_include_lzss_text_entry.tl"
    "(include-str-lzss text \"cl_include_lzss_text.txt\")
(define (main) : i64 0)")
  (and
    (match (compiler-load-file-with-paths
      "target/cl_include_lzss_source_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(Ok decls _ _ _)
        (compiler-load-first-lzss-def?
          decls
          "source"
          "(define a : i64 1)\n\n\n\n(define b : i64 3)\n")]
      [(Err _) false])
    (match (compiler-load-file-with-paths
      "target/cl_include_lzss_text_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(Ok decls _ _ _)
        (compiler-load-first-lzss-def? decls "text" "(test t (keep a))\n")]
      [(Err _) false])))

(define (compiler-load-strip-tests-case-ok? [source : String] [want : String]) : bool
  (string.eq (ces.compiler-embedded-stdlib-payload-source source) want))

;; The inline-test blanking rule: top-level `(test ...)` and one-body
;; `(cfg test ...)` forms only, line breaks kept, lexer-exact strings,
;; character literals and comments, and malformed input left unchanged.
(define (compiler-load-strip-inline-tests-ok?) : bool
  (and
    (compiler-load-strip-tests-case-ok?
      "(define a 1)\n(test t\n  (check a))\n(define b 2)\n"
      "(define a 1)\n\n\n(define b 2)\n")
    (compiler-load-strip-tests-case-ok?
      "(cfg\r\n  test\r\n  (define h 1))\r\n(define b 2)"
      "\r\n\r\n\r\n(define b 2)")
    ;; A second body is the non-test branch, so the form is kept.
    (compiler-load-strip-tests-case-ok?
      "(cfg test (define a 1) (define a 2))"
      "(cfg test (define a 1) (define a 2))")
    (compiler-load-strip-tests-case-ok?
      "(cfg (not test) (define a 1))"
      "(cfg (not test) (define a 1))")
    ;; Look-alike heads and nested forms stay.
    (compiler-load-strip-tests-case-ok?
      "(testing 1)(test-foo 2)(define (f) (test 3))"
      "(testing 1)(test-foo 2)(define (f) (test 3))")
    ;; Parens inside strings, character literals and comments do not count.
    ;; The comment is prose, so only its `;` stays.
    (compiler-load-strip-tests-case-ok?
      "(define s \"(test x) \\\" )\")\n(define c '(')\n; (test y\n(test z)\n"
      "(define s \"(test x) \\\" )\")\n(define c '(')\n;\n\n")
    ;; Unbalanced or unlexable sources are returned unchanged.
    (compiler-load-strip-tests-case-ok? "(test x" "(test x")
    (compiler-load-strip-tests-case-ok? "(test x))" "(test x))")
    (compiler-load-strip-tests-case-ok? "(test \"x)" "(test \"x)")))

;; The prose-comment rule (#8659): a comment outside the blanked tests keeps
;; only its first `;`, so every line still reads as it did (comment, doc or
;; code) and every token keeps its line and column. Doc comments, `name:`
;; directives and the bytes of strings and character literals are kept.
(define (compiler-load-trim-prose-comments-ok?) : bool
  (and
    (compiler-load-strip-tests-case-ok?
      ";; Why this exists.\n(define a 1) ; trailing note\n"
      ";\n(define a 1) ;\n")
    (compiler-load-strip-tests-case-ok?
      ";# Module doc.\n;: Item doc.\n(define a 1) ;: not a doc line, still kept\n"
      ";# Module doc.\n;: Item doc.\n(define a 1) ;: not a doc line, still kept\n")
    (compiler-load-strip-tests-case-ok?
      ";; lint-allow: unused-import\n;; doctest-exit: 42\n; ok-1: kept\n"
      ";; lint-allow: unused-import\n;; doctest-exit: 42\n; ok-1: kept\n")
    ;; A capital, a dot or a leading digit is prose, not a directive name.
    (compiler-load-strip-tests-case-ok?
      ";; Note: prose\n;; e.g.: prose\n;; 1x: prose\n"
      ";\n;\n;\n")
    (compiler-load-strip-tests-case-ok?
      ";; prose\r\n(define a 1)"
      ";\r\n(define a 1)")
    (compiler-load-strip-tests-case-ok?
      "(define a\n  ;; inside a kept form\n  1)"
      "(define a\n  ;\n  1)")
    ;; A kept two-body `(cfg test ...)` keeps its comments whole.
    (compiler-load-strip-tests-case-ok?
      "(cfg test (define a 1) ; note\n  (define a 2))"
      "(cfg test (define a 1) ; note\n  (define a 2))")
    (compiler-load-strip-tests-case-ok?
      ";; before\n(test t ; inside\n  (check))\n;; after\n"
      ";\n\n\n;\n")
    (compiler-load-strip-tests-case-ok?
      "(define s \"; not a comment\")\n(define c ';')\n"
      "(define s \"; not a comment\")\n(define c ';')\n")
    (compiler-load-strip-tests-case-ok?
      "(define a 1) ;; no newline"
      "(define a 1) ;")
    (compiler-load-strip-tests-case-ok? ";\n;;\n" ";\n;\n")))

(define (compiler-load-missing-include-str-ok?) : bool
  (match (load.compiler-load-source
    "src/app.tl"
    "(include-str missing \"no_such_resource_xyz.txt\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read include-str no_such_resource_xyz.txt from src/app.tl (resolved src/no_such_resource_xyz.txt)")]
    [(Ok _ _) false]))

(define (compiler-load-include-str-raw-text-ok?) : bool
  (let
    [payload : String "(import definitely_missing)
(define injected : i64 7)"]
    (compiler-load-write-file-text
      "target/cl_include_raw_payload.txt"
      (string.copy payload))
    (compiler-load-write-file-text
      "target/cl_include_raw_entry.tl"
      "(include-str payload \"cl_include_raw_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_raw_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "payload" payload))]
      [(Err _) false])))

(define (compiler-load-include-bin-relative-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_include_bin_payload.bin"
    (compiler-load-binary-fixture))
  (compiler-load-write-file-text
    "target/cl_include_bin_entry.tl"
    "(include-bin payload \"cl_include_bin_payload.bin\")
(define (main) : i64 0)")
  (match (compiler-load-file-with-paths
    "target/cl_include_bin_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-first-bin-def? decls "payload"))]
    [(Err _) false]))

(define (compiler-load-missing-include-bin-ok?) : bool
  (match (load.compiler-load-source
    "src/app.tl"
    "(include-bin missing \"no_such_resource_xyz.bin\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read include-bin no_such_resource_xyz.bin from src/app.tl (resolved src/no_such_resource_xyz.bin)")]
    [(Ok _ _) false]))

(define (compiler-load-embedded-stdlib-lookup-ok?) : bool
  (match (load.compiler-load-embedded-stdlib-source "string.tl")
    [(CompilerEmbeddedStdlibSomeSource source)
      (match (load.compiler-load-source-with-paths-and-roots
        "stdlib/string.tl"
        source
        (sym_i64_env.sym-i64-empty)
        (svec.new))
        [(Ok decls _ _ _) (> (compiler-load-decl-list-count decls) 0)]
        [(Err _) false])]
    [(CompilerEmbeddedStdlibNoSource) false]))

(define (compiler-load-embedded-stdlib-missing-ok?) : bool
  (match (load.compiler-load-embedded-stdlib-source "definitely_missing_xyz.tl")
    [(CompilerEmbeddedStdlibNoSource) true]
    [(CompilerEmbeddedStdlibSomeSource _) false]))

(define (compiler-load-embedded-stdlib-escape-rejected-ok?) : bool
  (match (load.compiler-load-embedded-stdlib-source "../string.tl")
    [(CompilerEmbeddedStdlibNoSource) true]
    [(CompilerEmbeddedStdlibSomeSource _) false]))

;; A parse error inside an imported file surfaces a diagnostic whose path is the
;; imported file (not the importer), preserving imported-file provenance.
(define (compiler-load-imported-parse-error-path-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_ipe_dep.tl"
    "(module cl_ipe_dep)
(define broken : i64 )")
  (compiler-load-write-file-text
    "target/cl_ipe_entry.tl"
    "(module cl_ipe_entry)
(import cl_ipe_dep as dep)
(define (main) : i64 0)")
  (match (compiler-load-file-with-paths
    "target/cl_ipe_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (and
        (string.eq
          (cdiag.compiler-diagnostic-path (__tl-box-place diag))
          "target/cl_ipe_dep.tl")
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          "parse: malformed value definition"))]
    [(Ok _ _ _ _) false]))

;; A duplicate `(module ...)` declaration inside an imported file surfaces a
;; diagnostic whose path is the imported file, not the importer.
(define (compiler-load-imported-duplicate-module-path-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_idm_dep.tl"
    "(module idm.depa)
(module idm.depb)
(define v : i64 1)")
  (compiler-load-write-file-text
    "target/cl_idm_entry.tl"
    "(module idm.entry)
(import cl_idm_dep as dep)
(define (main) : i64 0)")
  (match (compiler-load-file-with-paths
    "target/cl_idm_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Err diag)
      (and
        (string.eq
          (cdiag.compiler-diagnostic-path (__tl-box-place diag))
          "target/cl_idm_dep.tl")
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          "compiler-load: duplicate module declaration"))]
    [(Ok _ _ _ _) false]))

;; A `stdlib/<x>` import whose importer-relative path is absent resolves through
;; a configured `--stdlib-root` (root fallback).
(define (compiler-load-stdlib-root-fallback-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_srf_mod.tl"
    "(module stdlib.cl_srf_mod)
(define v : i64 1)")
  (compiler-load-write-file-text
    "target/cl_srf_entry.tl"
    "(module srf.entry)
(import stdlib.cl_srf_mod as m)
(define (main) : i64 m.v)")
  (match (load.compiler-load-file-with-paths-and-roots
    "target/cl_srf_entry.tl"
    (sym_i64_env.sym-i64-empty)
    (compiler-load-string-vec-one "target"))
    [(Ok _ _ _ seen)
      (compiler-load-test-seen-contains? seen "stdlib.cl_srf_mod")]
    [(Err _) false]))

;; A physically rooted prelude keeps its canonical logical path/module while
;; consuming the root's bytes. Rootless canonical paths prefer embedded source,
;; whereas a root that owns the suffix explicitly requests disk source.
(define (compiler-load-prelude-source-precedence-ok?) : bool
  (let
    [root-dir : String "target/cl_prelude_root"]
    [root-path : String "target/cl_prelude_root/runtime.tl"]
    [roots : svec.Vec (compiler-load-string-vec-one (string.copy root-dir))]
    (fs.mkdir-status-owned (string.copy root-dir))
    (compiler-load-write-file-text
      root-path
      "(define prelude-root-marker : i64 1)")
    (compiler-load-write-file-text
      "target/cl_prelude_root/core_macros.tl"
      "(define core-prelude-root-marker : i64 1)")
    (and
      (match (load.compiler-load-stdlib-prelude-file-with-roots-cfg
        (string.copy (load.compiler-load-runtime-prelude-path-shared-view))
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots)
        (parser.compiler-cfg-empty))
        [(Ok decls paths modules _)
          (and
            (=
              (compiler-load-decl-list-value-name-count
                decls
                "prelude-root-marker")
              1)
            (string.eq
              (compiler-load-test-path-at paths 0)
              (load.compiler-load-runtime-prelude-path-shared-view))
            (string.eq
              (ast_tests.ast-decl-module-list-get (& modules) 0 "")
              "stdlib.runtime"))]
        [(Err _) false])
      (match (load.compiler-load-core-macro-prelude-with-roots-cfg
        (sym_i64_env.sym-i64-empty)
        (ast.ast-place-shared-view roots)
        (parser.compiler-cfg-empty))
        [(Ok decls paths modules _)
          (and
            (=
              (compiler-load-decl-list-value-name-count
                decls
                "core-prelude-root-marker")
              1)
            (string.eq
              (compiler-load-test-path-at paths 0)
              (load.compiler-load-core-macro-prelude-path-shared-view))
            (string.eq
              (ast_tests.ast-decl-module-list-get (& modules) 0 "")
              "stdlib.core_macros")
            (string.eq
              (ast_tests.ast-decl-module-list-get
                (& modules)
                (- (ast.ast-decl-module-list-len (& modules)) 1)
                "missing")
              ""))]
        [(Err _) false])
      (match (load.compiler-load-package-stdlib-prelude-file-with-roots-cfg
        (string.copy (load.compiler-load-runtime-prelude-path-shared-view))
        (sym_i64_env.sym-i64-empty)
        roots
        ""
        (load.compiler-pkg-deps-empty)
        (parser.compiler-cfg-empty))
        [(Ok decls paths modules _)
          (and
            (=
              (compiler-load-decl-list-value-name-count
                decls
                "prelude-root-marker")
              1)
            (string.eq
              (compiler-load-test-path-at paths 0)
              (load.compiler-load-runtime-prelude-path-shared-view))
            (string.eq
              (ast_tests.ast-decl-module-list-get (& modules) 0 "")
              "stdlib.runtime"))]
        [(Err _) false]))))

;; `--stdlib-root` resolution searches roots in order; the first existing
;; candidate wins, so a missing leading root is skipped.
(define (compiler-load-stdlib-searched-root-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_ssr_mod.tl"
    "(module stdlib.cl_ssr_mod)
(define v : i64 1)")
  (compiler-load-write-file-text
    "target/cl_ssr_entry.tl"
    "(module ssr.entry)
(import stdlib.cl_ssr_mod as m)
(define (main) : i64 m.v)")
  (match (load.compiler-load-file-with-paths-and-roots
    "target/cl_ssr_entry.tl"
    (sym_i64_env.sym-i64-empty)
    (compiler-load-string-vec-two "target/cl_ssr_absent_root" "target"))
    [(Ok _ _ _ seen)
      (compiler-load-test-seen-contains? seen "stdlib.cl_ssr_mod")]
    [(Err _) false]))

;; A `stdlib/<x>` import found in no configured root reports a cannot-read
;; diagnostic naming the importer-relative candidate path.
(define (compiler-load-stdlib-unresolved-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_sur_entry.tl"
    "(module sur.entry)
(import stdlib.cl_sur_missing as m)
(define (main) : i64 0)")
  (match (load.compiler-load-file-with-paths-and-roots
    "target/cl_sur_entry.tl"
    (sym_i64_env.sym-i64-empty)
    (compiler-load-string-vec-one "target"))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        "compiler-load: cannot read import stdlib/cl_sur_missing.tl")]
    [(Ok _ _ _ _) false]))

;: Parse a manifest source string into a structured manifest. This compatibility
;: wrapper keeps existing in-memory parser callers and message-only tests stable.
(define (compiler-load-parse-manifest [source : String]) : load.ResultCompilerPkgManifest
  (match (load.compiler-load-parse-manifest-diagnostic "" source)
    [(Ok manifest) (Ok manifest)]
    [(Err diag) (Err (cdiag.compiler-diagnostic-message (__tl-box-place diag)))]))

;: Self-test: a full manifest parses with the expected fields + dependency
;: count.
(define (compiler-load-manifest-valid-full-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"demo\") (version \"0.1.0\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math \"../math\") (util \"../util\")))")
    [(Ok m)
      (and
        (string.eq m.name "demo")
        (string.eq m.version "0.1.0")
        (match m.kind
          [(CompilerPkgKindBin)
            (and
              (string.eq m.entry "src/main.tl")
              (= (load.compiler-pkg-deps-count m.deps) 2))]
          [(CompilerPkgKindLib) false]))]
    [(Err _) false]))

;: Self-test: a manifest without a `dependencies` field parses with no deps.
(define (compiler-load-manifest-valid-nodeps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"x\") (version \"1\") (kind staticlib))")
    [(Ok m)
      (match m.kind
        [(CompilerPkgKindLib)
          (and
            (string.eq m.entry "src/lib.tl")
            (= (load.compiler-pkg-deps-count m.deps) 0))]
        [(CompilerPkgKindBin) false])]
    [(Err _) false]))

(define (compiler-load-manifest-default-bin-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"default_bin\") (version \"1\"))")
    [(Ok m)
      (match m.kind
        [(CompilerPkgKindBin) (string.eq m.entry "src/main.tl")]
        [(CompilerPkgKindLib) false])]
    [(Err _) false]))

(define (compiler-load-manifest-entry-override-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"override\") (version \"1\") (kind \"staticlib\") (entry \"custom/lib.tl\"))")
    [(Ok m)
      (match m.kind
        [(CompilerPkgKindLib) (string.eq m.entry "custom/lib.tl")]
        [(CompilerPkgKindBin) false])]
    [(Err _) false]))

(define (compiler-load-manifest-dep-path-is?
  [deps : load.CompilerPkgDeps]
  [alias : String]
  [expected : String]) : bool
  (match (load.compiler-load-pkg-dep-lookup deps alias)
    [(CompilerLoadSomePath path) (string.eq path expected)]
    [(CompilerLoadNoPath) false]))

(define (compiler-load-pkg-deps-three-alias-order?
  [deps : load.CompilerPkgDeps]
  [first-alias : String]
  [second-alias : String]
  [third-alias : String]) : bool
  (let
    [ordered : load.CompilerPkgDepList (load.compiler-pkg-deps-list deps)]
    (and
      (= (load.compiler-pkg-dep-list-count ordered) 3)
      (string.eq
        (__tl-project-field (load.compiler-pkg-dep-list-at ordered 0) alias)
        first-alias)
      (string.eq
        (__tl-project-field (load.compiler-pkg-dep-list-at ordered 1) alias)
        second-alias)
      (string.eq
        (__tl-project-field (load.compiler-pkg-dep-list-at ordered 2) alias)
        third-alias))))

(define (compiler-load-manifest-github-deps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"github_demo\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math (github \"JoNil-Botta/math\" (rev \"abc123\"))) (util (github \"github.com/JoNil-Botta/util.repo\" (tag \"v1.0.0\"))) (core \"../core\")))")
    [(Ok m)
      (let
        [deps : load.CompilerPkgDeps m.deps]
        (and
          (= (load.compiler-pkg-deps-count deps) 3)
          (compiler-load-pkg-deps-three-alias-order?
            (ast.ast-place-shared-view deps)
            "math"
            "util"
            "core")
          (compiler-load-manifest-dep-path-is?
            (ast.ast-place-shared-view deps)
            "math"
            "https://github.com/JoNil-Botta/math.git#rev=abc123")
          (compiler-load-manifest-dep-path-is?
            (ast.ast-place-shared-view deps)
            "util"
            "https://github.com/JoNil-Botta/util.repo.git#tag=v1.0.0")
          (compiler-load-manifest-dep-path-is? deps "core" "../core")))]
    [(Err _) false]))

;: True when parsing `source` fails with exactly the `expected` diagnostic.
(define (compiler-load-manifest-rejects? [source : String] [expected : String]) : bool
  (match (compiler-load-parse-manifest source)
    [(Err m) (string.eq m expected)]
    [(Ok _) false]))

(define (compiler-load-manifest-diagnostic-span-forward?
  [diag : (& diag cdiag.CompilerDiagnostic)]) : bool
  (or
    (>
      (cdiag.compiler-diagnostic-end-line diag)
      (cdiag.compiler-diagnostic-line diag))
    (and
      (=
        (cdiag.compiler-diagnostic-end-line diag)
        (cdiag.compiler-diagnostic-line diag))
      (>=
        (cdiag.compiler-diagnostic-end-col diag)
        (cdiag.compiler-diagnostic-col diag)))))

(define (compiler-load-manifest-diagnostic-rejects?
  [path : String]
  [source : String]
  [expected : String]
  [line : i64]
  [col : i64]) : bool
  (match (load.compiler-load-parse-manifest-diagnostic
    (string.copy path)
    source)
    [(Err diag)
      (let
        [diagnostic : cdiag.CompilerDiagnostic (deref diag)]
        (and
          (string.eq (cdiag.compiler-diagnostic-path diagnostic) path)
          (= (cdiag.compiler-diagnostic-line diagnostic) line)
          (= (cdiag.compiler-diagnostic-col diagnostic) col)
          (compiler-load-manifest-diagnostic-span-forward? diagnostic)
          (string.eq (cdiag.compiler-diagnostic-message diagnostic) expected)))]
    [(Ok _) false]))

(define (compiler-load-pkg-manifest-diagnostic-ok?) : bool
  (and
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "("
      "manifest: reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "(module foo)"
      "expected `package` form, got `module`"
      1
      1)
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "(package\n  (name \"wrapped\")\n  (version \"1\")\n  (kind \"staticlib\")\n  (dependencies\n    (runtime \"../runtime\")))"
      "library package `wrapped` cannot declare normal dependency `runtime`; declare `runtime` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries"
      6
      6)))

(define (compiler-load-manifest-test-mkdir [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (compiler-load-manifest-test-write [path : String] [contents : String]) : bool
  (match (compiler-load-try-write-file-text (& path) (& contents))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (compiler-load-manifest-test-root [name : String]) : String
  (load.compiler-load-join-root-path "target" name))

(define (compiler-load-manifest-test-src [root : (& root str)]) : String
  (load.compiler-load-join-root-path (string.copy root) "src"))

(define (compiler-load-manifest-test-path [root : String] [relative : String]) : String
  (load.compiler-load-join-root-path root relative))

(define (compiler-load-manifest-write-convention-fixture
  [root : String]
  [manifest : String]
  [has-main : bool]
  [has-lib : bool]) : bool
  (let
    [src : String (compiler-load-manifest-test-src root)]
    [ok-target : bool (compiler-load-manifest-test-mkdir "target")]
    [ok-root : bool (compiler-load-manifest-test-mkdir (string.copy root))]
    [ok-src : bool (compiler-load-manifest-test-mkdir src)]
    [ok-manifest : bool
      (compiler-load-manifest-test-write
        (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")
        manifest)]
    [ok-main : bool
      (if has-main
        (compiler-load-manifest-test-write
          (compiler-load-manifest-test-path (string.copy root) "src/main.tl")
          "(define (main) : i64 42)")
        true)]
    [ok-lib : bool
      (if has-lib
        (compiler-load-manifest-test-write
          (compiler-load-manifest-test-path root "src/lib.tl")
          "(define lib-value : i64 42)")
        true)]
    (and ok-target ok-root ok-src ok-manifest ok-main ok-lib)))

(define (compiler-load-manifest-path-kind-entry-is?
  [path : String]
  [expected-kind : load.CompilerPkgKind]
  [expected-entry : String]) : bool
  (match (load.compiler-load-parse-manifest-diagnostic-infer-kind
    (string.copy path)
    (load.compiler-load-read-file-text path))
    [(Ok manifest)
      (and
        (string.eq manifest.entry expected-entry)
        (match manifest.kind
          [(CompilerPkgKindBin)
            (match expected-kind
              [(CompilerPkgKindBin) true]
              [(CompilerPkgKindLib) false])]
          [(CompilerPkgKindLib)
            (match expected-kind
              [(CompilerPkgKindLib) true]
              [(CompilerPkgKindBin) false])]))]
    [(Err _) false]))

(define (compiler-load-manifest-path-rejects?
  [path : String]
  [expected : String]) : bool
  (match (load.compiler-load-parse-manifest-diagnostic-infer-kind
    (string.copy path)
    (load.compiler-load-read-file-text path))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-message (__tl-box-place diag))
        expected)]
    [(Ok _) false]))

(define (compiler-load-manifest-infer-bin-only-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_bin_only")]
    [manifest-path : String
      (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"bin_only\") (version \"1\"))"
        true
        false)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindBin)
        "src/main.tl"))))

(define (compiler-load-manifest-infer-lib-only-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_lib_only")]
    [manifest-path : String
      (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"lib_only\") (version \"1\"))"
        false
        true)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindLib)
        "src/lib.tl"))))

(define (compiler-load-manifest-infer-lib-dependency-rejects?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_lib_dependency")]
    [manifest-path : String
      (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"inferred_lib\") (version \"1\") (dependencies (runtime \"../runtime\")))"
        false
        true)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "library package `inferred_lib` cannot declare normal dependency `runtime`; declare `runtime` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries"))))

(define (compiler-load-manifest-infer-ambiguous-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_ambiguous")]
    [manifest-path : String
      (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"ambiguous\") (version \"1\"))"
        true
        true)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`"))))

(define (compiler-load-manifest-infer-missing-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_missing")]
    [manifest-path : String
      (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"missing\") (version \"1\"))"
        false
        false)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "manifest omits `kind` and `entry`, but neither `src/main.tl` nor `src/lib.tl` exists; add `kind` and `entry` or create a conventional entry file"))))

(define (compiler-load-manifest-infer-explicit-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_explicit")]
    [manifest-path : String
      (compiler-load-manifest-test-path (string.copy root) "typelisp.pkg")]
    [explicit-entry-root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_explicit_entry")]
    [explicit-entry-path : String
      (compiler-load-manifest-test-path
        (string.copy explicit-entry-root)
        "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"explicit\") (version \"1\") (kind staticlib))"
        true
        true)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindLib)
        "src/lib.tl")
      (compiler-load-manifest-write-convention-fixture
        explicit-entry-root
        "(package (name \"explicit_entry\") (version \"1\") (entry \"custom.tl\"))"
        false
        true)
      (compiler-load-manifest-path-kind-entry-is?
        explicit-entry-path
        (CompilerPkgKindBin)
        "custom.tl"))))

(define (compiler-load-manifest-infer-package-entry-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_entry_lib_only")]
    [source-path : String
      (compiler-load-manifest-test-path (string.copy root) "src/lib.tl")]
    [expected-entry : String (load.compiler-load-normalize-path source-path)]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"entry_dep\") (version \"1\"))"
        false
        true)
      (match (load.compiler-load-package-entry-for-source source-path)
        [(Ok entry)
          (and
            (string.eq entry.owner "entry_dep")
            (string.eq entry.entry-path expected-entry))]
        [(Err _) false]))))

(define (compiler-load-manifest-path-inference-ok?) : bool
  (and
    (compiler-load-manifest-infer-bin-only-ok?)
    (compiler-load-manifest-infer-lib-only-ok?)
    (compiler-load-manifest-infer-lib-dependency-rejects?)
    (compiler-load-manifest-infer-ambiguous-ok?)
    (compiler-load-manifest-infer-missing-ok?)
    (compiler-load-manifest-infer-explicit-ok?)
    (compiler-load-manifest-infer-package-entry-ok?)))

(define (compiler-load-pkg-manifest-github-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\"))))"
      "manifest dependency `math` github source requires exactly one rev, tag, or branch pin")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo/extra\" (rev \"abc\")))))"
      "manifest dependency `math` github address must be `owner/repo` or `github.com/owner/repo`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (sha \"abc\")))))"
      "manifest dependency `math` github pin must be rev, tag, or branch")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (rev \"\")))))"
      "manifest dependency `math` github pin must not be empty")))

(define (compiler-load-pkg-manifest-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"demo\") (name \"again\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "duplicate manifest field `name`")
    (compiler-load-manifest-rejects?
      "(package (name \"\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `name` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"bad.name\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `version` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bad\") (entry \"e.tl\"))"
      "manifest field `kind` must be `bin`, `staticlib`, or `lib`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (kind \"lib\") (entry \"e.tl\"))"
      "duplicate manifest field `kind`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"\"))"
      "manifest field `entry` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"../main.tl\"))"
      "manifest field `entry` must be a normal relative path below the manifest directory")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\")) (dependencies (util \"b\")))"
      "duplicate manifest field `dependencies`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\") (math \"b\")))"
      "duplicate dependency alias `math`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (bad.alias \"a\")))"
      "dependency alias may only contain ASCII letters, digits, '-' and '_'")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"\")))"
      "manifest dependency `math` path must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"layer\") (version \"1\") (kind \"staticlib\") (dependencies (runtime \"../runtime\")))"
      "library package `layer` cannot declare normal dependency `runtime`; declare `runtime` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries")
    (compiler-load-manifest-rejects?
      "(package (name \"remote_layer\") (version \"1\") (kind \"staticlib\") (dependencies (runtime (github \"owner/runtime\" (rev \"abc\")))))"
      "library package `remote_layer` cannot declare normal dependency `runtime`; declare `runtime` directly in the consuming application, remove or combine the library dependency, or use `link` for native libraries")))

;: True when a package link string vector is empty.
(define (compiler-load-link-vec-empty? [vec : (& vec fs.FsStringVector)]) : bool
  (= (fs.string-vector-len vec) 0))

;: True when a package link string vector holds exactly one value equal to `a`.
(define (compiler-load-link-vec-single?
  [vec : (& vec fs.FsStringVector)]
  [a : String]) : bool
  (and
    (= (fs.string-vector-len vec) 1)
    (string.eq (fs.string-vector-get vec 0 "") a)))

;: True when a package link string vector holds exactly `a` then `b`, in order.
(define (compiler-load-link-vec-pair?
  [vec : (& vec fs.FsStringVector)]
  [a : String]
  [b : String]) : bool
  (and
    (= (fs.string-vector-len vec) 2)
    (string.eq (fs.string-vector-get vec 0 "") a)
    (string.eq (fs.string-vector-get vec 1 "") b)))

;: Self-test: a `(link ...)` section parses into all-target and per-target sets
;: with manifest order preserved.
(define (compiler-load-manifest-link-valid-ok?) : bool
  (and
    (match (compiler-load-parse-manifest
      "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (link (libraries \"raylib\") (search-paths \"vendor/lib\") (linux-libraries \"GL\" \"m\") (linux-args \"-Wl,--as-needed\") (windows-libraries \"opengl32\")))")
      [(Ok m)
        (let
          [link : load.CompilerPkgLink m.link]
          [all : load.CompilerPkgLinkSet link.all]
          [lin : load.CompilerPkgLinkSet link.linux]
          [win : load.CompilerPkgLinkSet link.windows]
          (and
            (compiler-load-link-vec-single? (& all.libraries) "raylib")
            (compiler-load-link-vec-single? (& all.search-paths) "vendor/lib")
            (compiler-load-link-vec-empty? (& all.args))
            (compiler-load-link-vec-pair? (& lin.libraries) "GL" "m")
            (compiler-load-link-vec-single? (& lin.args) "-Wl,--as-needed")
            (compiler-load-link-vec-single? (& win.libraries) "opengl32")))]
      [(Err _) false])
    (match (compiler-load-parse-manifest
      "(package (name \"wrapper\") (version \"1\") (kind \"staticlib\") (link (libraries \"sqlite3\") (search-paths \"vendor/sqlite\")))")
      [(Ok m)
        (and
          (= (load.compiler-pkg-deps-count (& m.deps)) 0)
          (compiler-load-link-vec-single? (& m.link.all.libraries) "sqlite3")
          (compiler-load-link-vec-single?
            (& m.link.all.search-paths)
            "vendor/sqlite"))]
      [(Err _) false])))

;: Self-test: a manifest with no `link` section parses with empty link sets.
(define (compiler-load-manifest-link-default-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\"))")
    [(Ok m)
      (let
        [link : load.CompilerPkgLink m.link]
        (and
          (compiler-load-link-vec-empty? (& link.all.libraries))
          (compiler-load-link-vec-empty? (& link.linux.libraries))
          (compiler-load-link-vec-empty? (& link.windows.libraries))))]
    [(Err _) false]))

;: Self-test: invalid `(link ...)` sections produce the expected diagnostics.
(define (compiler-load-manifest-link-rejections-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"a\")) (link (args \"b\")))"
      "duplicate manifest field `link`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"a\") (libraries \"b\")))"
      "duplicate `link` field `libraries`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (frobs \"a\")))"
      "unknown `link` field `frobs`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"\")))"
      "`link` field `libraries` values must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries)))"
      "`link` field `libraries` requires at least one value")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries 5)))"
      "`link` field `libraries` values must be strings")))

;: Aggregate link-section self-test.
(define (compiler-load-manifest-link-ok?) : bool
  (and
    (compiler-load-manifest-link-valid-ok?)
    (compiler-load-manifest-link-default-ok?)
    (compiler-load-manifest-link-rejections-ok?)))

;: Aggregate manifest-parser self-test.
(define (compiler-load-pkg-manifest-ok?) : bool
  (and
    (compiler-load-manifest-valid-full-ok?)
    (compiler-load-manifest-link-ok?)
    (compiler-load-manifest-valid-nodeps-ok?)
    (compiler-load-manifest-default-bin-ok?)
    (compiler-load-manifest-entry-override-ok?)
    (compiler-load-manifest-rejects?
      "(package (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest missing required field `name`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest missing required field `version`")
    (compiler-load-manifest-rejects?
      "(module foo)"
      "expected `package` form, got `module`")
    (compiler-load-pkg-manifest-validation-ok?)
    (compiler-load-manifest-github-deps-ok?)
    (compiler-load-pkg-manifest-github-validation-ok?)
    (compiler-load-pkg-manifest-diagnostic-ok?)))

;: Self-test fixture: local deps plus one GitHub dep that needs fetch support.
(define (compiler-load-pkg-resolve-deps) : load.CompilerPkgDeps
  (load.compiler-pkg-deps-cons
    "math"
    "../math"
    (load.compiler-pkg-deps-cons
      "util"
      "vendor/util"
      (load.compiler-pkg-deps-cons
        "remote"
        "https://github.com/owner/repo.git#rev=abc"
        (load.compiler-pkg-deps-empty)))))

;: True when resolving `import-path` yields exactly `expected`.
(define (compiler-load-pkg-resolves? [import-path : String] [expected : String]) : bool
  (match (load.compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(Ok p) (string.eq p expected)]
    [(Err _) false]))

;: True when resolving `import-path` fails with exactly `expected`.
(define (compiler-load-pkg-resolve-rejects?
  [import-path : String]
  [expected : String]) : bool
  (match (load.compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(Err m) (string.eq m expected)]
    [(Ok _) false]))

;: Aggregate pkg-import resolution self-test.
(define (compiler-load-pkg-resolve-ok?) : bool
  (and
    (compiler-load-pkg-resolves? "pkg:math/src/add.tl" "math/src/add.tl")
    (compiler-load-pkg-resolves? "pkg:util/lib.tl" "proj/vendor/util/lib.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:nope/x.tl"
      "compiler-load: unknown package alias 'nope': pkg:nope/x.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:math"
      "compiler-load: pkg import missing '/' after alias: pkg:math")
    (compiler-load-pkg-resolve-rejects?
      "pkg:math/../../etc.tl"
      "compiler-load: pkg import escapes package root: pkg:math/../../etc.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:remote/src/lib.tl"
      "compiler-load: GitHub dependency 'remote' requires fetch support: pkg:remote/src/lib.tl")))

;: True when `parent-dir dir` yields exactly `expected`.
(define (compiler-load-pkg-parent-dir-is? [dir : String] [expected : String]) : bool
  (match (load.compiler-load-parent-dir dir)
    [(CompilerLoadSomePath p) (string.eq p expected)]
    [(CompilerLoadNoPath) false]))

;: True when `parent-dir dir` reports no parent (top of the climb).
(define (compiler-load-pkg-parent-dir-none? [dir : String]) : bool
  (match (load.compiler-load-parent-dir dir)
    [(CompilerLoadNoPath) true]
    [(CompilerLoadSomePath _) false]))

;: The manifest-discovery walk-up steps one directory at a time, descending to
;: the cwd (``) before stopping.
(define (compiler-load-pkg-parent-dir-ok?) : bool
  (and
    (compiler-load-pkg-parent-dir-is? "a/b/" "a/")
    (compiler-load-pkg-parent-dir-is? "a/b/c/" "a/b/")
    (compiler-load-pkg-parent-dir-is? "a/" "")
    (compiler-load-pkg-parent-dir-none? "")))

(define (compiler-load-string-vec-roots-ok?) : bool
  (compiler-load-write-file-text
    "target/cl_vec_root_payload.tl"
    "(define v : i64 1)")
  (let
    [roots : svec.Vec
      (compiler-load-string-vec-two "target/cl_vec_missing_root" "target")]
    (and
      (= (svec.len (& roots)) 2)
      (string.eq (svec.get (& roots) 0 "") "target/cl_vec_missing_root")
      (string.eq (svec.get (& roots) 1 "") "target")
      (match (load.compiler-load-resolve-stdlib-root-raw
        "cl_vec_root_payload.tl"
        roots)
        [(CompilerLoadSomePath path)
          (string.eq path "target/cl_vec_root_payload.tl")]
        [(CompilerLoadNoPath) false]))))

(define (compiler-load-pkg-dep-list-ok?) : bool
  (let
    [deps : load.CompilerPkgDeps
      (load.compiler-pkg-deps-cons
        "alpha"
        "dep-alpha"
        (load.compiler-pkg-deps-cons
          "beta"
          "dep-beta"
          (load.compiler-pkg-deps-empty)))]
    (and
      (= (load.compiler-pkg-deps-count deps) 2)
      (load.compiler-pkg-deps-alias-seen?
        (ast.ast-place-shared-view deps)
        "beta")
      (compiler-load-manifest-dep-path-is? deps "beta" "dep-beta"))))

;; relative-resolution variants: importer-relative join, parent-directory
;; (`..`) resolution end-to-end (join then normalize), and absolute-path
;; preservation (Unix-rooted and Windows-drive imports ignore the importer dir).
;; Pure path-string logic; complements `compiler-load-normalize-ok?` which covers
;; bare `.`/`..`/separator normalization without the importer-relative join.
(define (compiler-load-relative-resolution-ok?) : bool
  (and
    ;; importer-relative: import resolves against the importer's directory
    (string.eq
      (load.compiler-load-join-import-path "src/app/main.tl" "util.tl")
      "src/app/util.tl")
    ;; parent-directory (`..`) resolution end-to-end (join then normalize)
    (string.eq
      (load.compiler-load-normalize-path
        (load.compiler-load-join-import-path
          "src/app/main.tl"
          "../lib/helper.tl"))
      "src/lib/helper.tl")
    ;; absolute Unix-rooted import is preserved as-is (importer dir ignored)
    (string.eq
      (load.compiler-load-join-import-path "src/app/main.tl" "/opt/dep.tl")
      "/opt/dep.tl")
    ;; absolute Windows-drive import is preserved as-is
    (string.eq
      (load.compiler-load-join-import-path "src/app/main.tl" "C:/dep.tl")
      "C:/dep.tl")))

(define (compiler-load-dotted-module-path-cache-ok?) : bool
  (load.compiler-load-dotted-path-cache-reset!)
  (let
    [home : arena.Arena (arena.current)]
    [stdlib-name : String "stdlib.core_macros"]
    [pkg-name : String "pkg.local.mod"]
    [stdlib-id : i64 (ci.intern stdlib-name)]
    [pkg-id : i64 (ci.intern pkg-name)]
    [first : String
      (load.compiler-load-dotted-module-path-id stdlib-id "stdlib.core_macros")]
    [second : String
      (load.compiler-load-dotted-module-path-id stdlib-id "stdlib.core_macros")]
    [third : String
      (load.compiler-load-dotted-module-path-id pkg-id "pkg.local.mod")]
    (and
      (arena.eq? (arena.current) home)
      (string.eq first "stdlib/core_macros.tl")
      (string.eq second "stdlib/core_macros.tl")
      (string.eq third "pkg/local/mod.tl")
      (match (compiler-load-dotted-path-cache-lookup stdlib-id)
        [(CompilerLoadSomeString cached)
          (string.eq cached "stdlib/core_macros.tl")]
        [(CompilerLoadNoString) false])
      (match (compiler-load-dotted-path-cache-lookup pkg-id)
        [(CompilerLoadSomeString cached) (string.eq cached "pkg/local/mod.tl")]
        [(CompilerLoadNoString) false]))))

(define (compiler-load-test-path-at [paths : ast.AstDeclPathList] [index : i64]) : String
  (match (ast.ast-decl-path-list-step paths)
    [(Nil) ""]
    [(Cons path rest)
      (if (= index 0)
        path
        (let
          [rest : ast.AstDeclPathList rest]
          (compiler-load-test-path-at rest (- index 1))))]))

(define (compiler-load-package-owner-paths-ok?) : bool
  (let
    [roots : svec.Vec (compiler-load-string-vec-one "C:/repo/stdlib")]
    [mixed-roots : svec.Vec
      (compiler-load-string-vec-two "C:/repo/stdlib" "C:/repo/selfhost")]
    [runtime-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (load.compiler-load-parse-context-name-id "runtime-helper")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 1))))]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (load.compiler-load-parse-context-name-id "helper")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 2))))]
    [main-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        (load.compiler-load-parse-context-name-id "main")
        (ast.ast-param-list-new)
        (I64)
        (ast.ast-node-push (Literal (ast.ast-lit-int 0))))]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        (& runtime-decl)
        (&
          (ast.ast-decl-cons
            (& helper-decl)
            (& (ast.ast-decl-cons (& main-decl) (& (ast.ast-decl-list-new)))))))]
    [runtime-path-id : i64
      (load.compiler-load-source-path-id "C:/repo/stdlib/runtime.tl")]
    [main-path-id : i64
      (load.compiler-load-source-path-id "C:/pkg/src/main.tl")]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "C:/repo/stdlib/runtime.tl"
        runtime-path-id
        (ast.ast-decl-path-cons-with-owner-id
          "C:/pkg/src/main.tl"
          main-path-id
          (ast.ast-decl-path-cons-with-owner-id
            "C:/pkg/src/main.tl"
            main-path-id
            (ast.ast-decl-path-list-new))))]
    [owned : ast.AstDeclPathList
      (load.compiler-load-package-owned-paths-for-decls
        "app"
        "C:/pkg/"
        (ast.ast-place-shared-view roots)
        "C:/pkg/src/main.tl"
        decls
        paths)]
    [runtime-owned-ok : bool
      (string.eq
        (compiler-load-test-path-at (ast.ast-place-shared-view owned) 0)
        "stdlib/runtime.tl")]
    [helper-owned-ok : bool
      (string.eq
        (compiler-load-test-path-at (ast.ast-place-shared-view owned) 1)
        "app/src/main.tl")]
    [entry-main-ok : bool (string.eq (compiler-load-test-path-at owned 2) "")]
    [stdlib-normalized-ok : bool
      (string.eq
        (load.compiler-load-package-owned-path
          "app"
          "C:/pkg/"
          (ast.ast-place-shared-view roots)
          "stdlib/../stdlib/runtime.tl")
        "stdlib/runtime.tl")]
    [empty-root-owned-ok : bool
      (string.eq
        (load.compiler-load-package-owned-path "app" "" roots "src/main.tl")
        "app/src/main.tl")]
    [selfhost-root-owned-ok : bool
      (string.eq
        (load.compiler-load-package-owned-path
          "app"
          "C:/repo/"
          mixed-roots
          "C:/repo/selfhost/compiler_driver_core.tl")
        "app/selfhost/compiler_driver_core.tl")]
    (and
      runtime-owned-ok
      helper-owned-ok
      entry-main-ok
      stdlib-normalized-ok
      empty-root-owned-ok
      selfhost-root-owned-ok)))

(define (compiler-load-package-owner-extern-symbol-ok?) : bool
  (let
    [decl : ast.AstDecl
      (load.compiler-load-package-def-fn-extern
        "dep"
        "C:/dep/"
        (svec.new)
        "C:/dep/src/lib.tl"
        ""
        (ci.intern "helper")
        (ast.ast-param-list-new)
        (I64)
        Unavailable)]
    (match decl
      [(Extern decl-meta _ _ metadata _)
        (string.eq
          (ast.ast-extern-metadata-symbol (& (deref metadata)))
          "_tl_dep_src_lib_helper")]
      [_ false])))

;; A dependency function reaches its consumer as an extern with the TypeLisp
;; ABI (#8485), so a TypeLisp-internal convention can tell it from a C extern.
(define (compiler-load-package-extern-typelisp-abi-ok?) : bool
  (match (load.compiler-load-package-def-fn-extern
    "dep"
    "C:/dep/"
    (svec.new)
    "C:/dep/src/lib.tl"
    ""
    (ci.intern "helper")
    (ast.ast-param-list-new)
    (I64)
    Unavailable)
    [(Extern _ _ _ metadata _)
      (match (ast.ast-extern-metadata-abi (deref metadata))
        [(TypeLisp) true]
        [_ false])]
    [_ false]))

(define (compiler-load-package-source-macro-preserved-ok?) : bool
  (let
    [name : i64 (ci.intern-generated-name "package-source-macro")]
    [body : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 42)))]
    [decl : ast.AstDecl
      (ast.ast-decl-def-macro-id name (ast.ast-macro-param-list-new) (I64) body)]
    (match (load.compiler-load-package-transform-decl
      "dep"
      "C:/dep/"
      (svec.new)
      "C:/dep/src/lib.tl"
      "dep.module"
      Unavailable
      decl)
      [(CompilerLoadSomeDecl transformed)
        (match transformed
          [(DefMacro _ got-name params (I64) got-body)
            (and
              (= got-name name)
              (= (ast.ast-macro-param-list-len (& params)) 0)
              (= got-body body))]
          [_ false])]
      [(CompilerLoadNoDecl) false])))

(define (compiler-load-package-imported-spmd-metadata-ok?) : bool
  (let
    [specialization : tlci.TlciSpmdSpecialization
      (tlci.tlci-make-spmd-specialization
        "spmd-call-v1"
        "avx512"
        8
        "vu"
        "v"
        0
        "_tl___tl_spmd_fixture_helper")]
    [callable : tlci.TlciSpmdCallable
      (tlci.tlci-make-spmd-callable
        "spmd_fixture/helper"
        "(-> i64 i64 i64)"
        (tlci.tlci-spmd-specializations-push
          (tlci.tlci-spmd-specializations-empty)
          specialization))]
    [metadata : ast.AstImportedSpmdMetadata
      (load.compiler-load-imported-spmd-metadata
        "spmd_fixture"
        "spmd_fixture"
        (ci.intern "helper")
        (Available
          "1.0.0"
          (tlci.tlci-spmd-callables-push
            (tlci.tlci-spmd-callables-empty)
            callable)))]
    (match metadata
      [(No) false]
      [(Package owner version canonical-name callables-box)
        (let
          [callables : ast.AstImportedSpmdCallableList (deref callables-box)]
          [copied-callable : ast.AstImportedSpmdCallable
            (ast.ast-imported-spmd-callable-list-get
              (& callables)
              0
              (ast.ast-imported-spmd-callable-fallback))]
          [specializations : ast.AstImportedSpmdSpecializationList
            copied-callable.specializations]
          [copied-specialization : ast.AstImportedSpmdSpecialization
            (ast.ast-imported-spmd-specialization-list-get
              (& specializations)
              0
              (ast.ast-imported-spmd-specialization-fallback))]
          (and
            (string.eq owner "spmd_fixture")
            (string.eq version "1.0.0")
            (string.eq (ci.intern-id-str canonical-name) "spmd_fixture/helper")
            (= (ast.ast-imported-spmd-callable-list-len (& callables)) 1)
            (string.eq
              (ci.intern-id-str copied-callable.signature)
              "(-> i64 i64 i64)")
            (=
              (ast.ast-imported-spmd-specialization-list-len
                (& specializations))
              1)
            (string.eq
              (ci.intern-id-str copied-specialization.symbol)
              "_tl___tl_spmd_fixture_helper")))])))

(define (compiler-load-module-list-slots-address
  [items : (& items ast.AstDeclModuleList)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data items.slots) : (Ptr u8))) : i64)))

(define (compiler-load-append-onto-reuse-ok?) : bool
  (let
    [left-a-id : i64 (ci.intern-generated-name "left-a")]
    [left-b-id : i64 (ci.intern-generated-name "left-b")]
    [right-a-id : i64 (ci.intern-generated-name "right-a")]
    [right-b-id : i64 (ci.intern-generated-name "right-b")]
    [alias-a-id : i64 (ci.intern-generated-name "alias-a")]
    [alias-b-id : i64 (ci.intern-generated-name "alias-b")]
    [tail-a-id : i64 (ci.intern-generated-name "tail-a")]
    [tail-b-id : i64 (ci.intern-generated-name "tail-b")]
    [left : ast.AstDeclModuleList (ast.ast-decl-module-list-with-capacity 2)]
    [_left : unit
      (begin
        (ast.ast-decl-module-list-push-id (&mut left) left-a-id)
        (ast.ast-decl-module-list-push-id (&mut left) left-b-id))]
    [right-base : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
    [right-tail : ast.AstDeclModuleList
      (ast.ast-decl-module-list-prepend-builder-id right-b-id right-base)]
    [right : ast.AstDeclModuleList
      (ast.ast-decl-module-list-prepend-builder-id right-a-id right-tail)]
    [right-address : i64 (compiler-load-module-list-slots-address right)]
    [reused : ast.AstDeclModuleList
      (load.compiler-load-decl-module-list-append-onto left right)]
    [shared : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [_shared : unit
      (begin
        (set! (array-ref shared 1) alias-a-id)
        (set! (array-ref shared 2) alias-b-id)
        (set! (array-ref shared 4) tail-a-id)
        (set! (array-ref shared 5) tail-b-id))]
    [alias-left : ast.AstDeclModuleList
      (ast.AstDeclModuleList (ast.ast-place-shared-view shared) 1 2 true)]
    [alias-right : ast.AstDeclModuleList
      (ast.AstDeclModuleList (ast.ast-place-shared-view shared) 4 2 true)]
    [alias-address : i64 (compiler-load-module-list-slots-address alias-right)]
    [copied : ast.AstDeclModuleList
      (load.compiler-load-decl-module-list-append-onto alias-left alias-right)]
    (and
      (= (compiler-load-module-list-slots-address reused) right-address)
      (= (ast.ast-decl-module-list-len (& reused)) 4)
      (= (ast.ast-decl-module-list-get-id (& reused) 0 -1) left-a-id)
      (= (ast.ast-decl-module-list-get-id (& reused) 1 -1) left-b-id)
      (= (ast.ast-decl-module-list-get-id (& reused) 2 -1) right-a-id)
      (= (ast.ast-decl-module-list-get-id (& reused) 3 -1) right-b-id)
      (not (= (compiler-load-module-list-slots-address copied) alias-address))
      (= (ast.ast-decl-module-list-len (& copied)) 4)
      (= (ast.ast-decl-module-list-get-id (& copied) 0 -1) alias-a-id)
      (= (ast.ast-decl-module-list-get-id (& copied) 1 -1) alias-b-id)
      (= (ast.ast-decl-module-list-get-id (& copied) 2 -1) tail-a-id)
      (= (ast.ast-decl-module-list-get-id (& copied) 3 -1) tail-b-id)
      (= (array-ref shared 1) alias-a-id)
      (= (array-ref shared 2) alias-b-id)
      (= (array-ref shared 4) tail-a-id)
      (= (array-ref shared 5) tail-b-id))))

(define (compiler-load-session-explicit-cache-api-isolation-ok?) : bool
  (let
    [previous-state : load.CompilerLoadSessionState
      (load.compiler-load-global-shared-view
        load.compiler-load-active-session-state)]
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [_select-b : unit (load.compiler-load-session-state-use! state-b)]
    [cfgs : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    [program-key : load.CompilerLoadProgramCacheKey
      (load.CompilerLoadProgramCacheKey CompilerLoadProgramEmbedded 701 cfgs)]
    [program : ast.AstProgram (ast.ast-program (ast.ast-decl-list-new))]
    [_store-program : bool
      (load.compiler-load-session-state-program-cache-store
        (owned_view.compiler-owned-shared-view state-a)
        program-key
        program)]
    [_note-hit : unit
      (load.compiler-load-session-state-program-cache-note-hit!
        (owned_view.compiler-owned-shared-view state-a))]
    [_admit : bool
      (load.compiler-load-session-state-program-admission-record
        state-a
        program-key)]
    [prelude-key : load.CompilerLoadPreludeCacheKey
      (load.CompilerLoadPreludeCacheKey
        (load.CompilerLoadInternIdSeq (__tl_make-array i64 0) 0)
        cfgs)]
    [_store-prelude : unit
      (load.compiler-load-session-state-runtime-prelude-cache-store
        (owned_view.compiler-owned-shared-view state-a)
        (ast.ast-place-shared-view prelude-key)
        (ast.ast-decl-list-new)
        (ast.ast-decl-path-list-new)
        (ast.ast-decl-module-list-new)
        (sym_i64_env.sym-i64-empty))]
    [dotted : String
      (load.compiler-load-session-state-dotted-module-path-id
        (owned_view.compiler-owned-shared-view state-a)
        702
        "pkg.explicit")]
    [ok : bool
      (and
        (match (load.compiler-load-session-state-program-cache-lookup
          (owned_view.compiler-owned-shared-view state-a)
          program-key)
          [(CompilerLoadProgramCacheHit _) true]
          [_ false])
        (=
          (load.compiler-load-session-state-program-cache-hit-count-value
            state-a)
          1)
        (=
          (load.compiler-load-session-state-program-cache-store-count-value
            state-a)
          1)
        (load.compiler-load-session-state-program-admission-contains?
          (owned_view.compiler-owned-shared-view state-a)
          program-key)
        (match (load.compiler-load-session-state-runtime-prelude-cache-lookup
          state-a
          prelude-key)
          [(CompilerLoadPreludeCacheHit _ _ _ _) true]
          [_ false])
        (string.eq dotted "pkg/explicit.tl")
        (not (array-ref state-b.program-cache-ready 0))
        (=
          (load.compiler-load-session-state-program-cache-hit-count-value
            state-b)
          0)
        (=
          (load.compiler-load-session-state-program-cache-store-count-value
            state-b)
          0)
        (not (array-ref state-b.program-admission-ready 0))
        (not (array-ref state-b.runtime-prelude-cache-ready 0))
        (match (load.compiler-load-session-state-dotted-path-cache-lookup
          state-b
          702)
          [(CompilerLoadNoString) true]
          [_ false]))]
    (load.compiler-load-session-state-use! previous-state)
    ok))

(define (compiler-load-session-embedded-provenance-isolation-ok?) : bool
  (let
    [previous-state : load.CompilerLoadSessionState
      (load.compiler-load-global-shared-view
        load.compiler-load-active-session-state)]
    [active-intern-before : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-decoy : ci.InternCompatState (ci.intern-compat-state-new)]
    [module-a : String "stdlib.state_a"]
    [module-b : String "stdlib.state_b"]
    [id-a : i64
      (ci.intern-compat-state-intern (&mut intern-a) (& (string.copy module-a)))]
    [id-b : i64
      (ci.intern-compat-state-intern (&mut intern-b) (& (string.copy module-b)))]
    [id-decoy : i64
      (ci.intern-compat-state-intern (&mut intern-decoy) "stdlib.decoy")]
    [_bind-a : unit
      (load.compiler-load-session-state-use-with-intern-state!
        state-a
        (owned_view.compiler-owned-shared-view intern-a))]
    [_bind-b : unit
      (load.compiler-load-session-state-use-with-intern-state! state-b intern-b)]
    [decoy-pool-before : i64 (ci.intern-compat-state-pool-len (& intern-decoy))]
    [ok : bool false]
    ;; Keep an unrelated same-shaped table installed while every explicit
    ;; operation below targets A or B. Any ambient interning would mutate the
    ;; decoy and make the colliding ids appear to belong to the wrong job.
    (ci.intern-compat-state-install! intern-decoy)
    (load.compiler-load-session-state-note-embedded-module!
      state-a
      "stdlib/state_a.tl")
    (load.compiler-load-session-state-note-embedded-module!
      state-b
      "stdlib/state_b.tl")
    (set! (array-ref state-a.embedded-stdlib-provenance.noted 0) true)
    (set! (array-ref state-b.embedded-stdlib-provenance.noted 0) true)
    (let
      [before : bool
        (and
          (= id-a id-b)
          (= id-b id-decoy)
          (compiler-load-session-state-embedded-stdlib-module-id?
            state-a
            (string.copy module-a))
          (not
            (compiler-load-session-state-embedded-stdlib-module-id?
              state-a
              (string.copy module-b)))
          (compiler-load-session-state-embedded-stdlib-module-id?
            state-b
            (string.copy module-b))
          (not
            (compiler-load-session-state-embedded-stdlib-module-id?
              state-b
              (string.copy module-a)))
          (load.compiler-load-session-state-embedded-provenance-noted?
            (owned_view.compiler-owned-shared-view state-a))
          (load.compiler-load-session-state-embedded-provenance-noted?
            (owned_view.compiler-owned-shared-view state-b))
          (=
            (ci.intern-compat-state-pool-len (& intern-decoy))
            decoy-pool-before))]
      (load.compiler-load-session-state-embedded-provenance-reset!
        (owned_view.compiler-owned-shared-view state-b))
      (let
        [active-after : ci.InternCompatState
          (ci.intern-compat-state-capture-active)]
        (set!
          ok
          (and
            before
            (compiler-load-session-state-embedded-stdlib-module-id?
              state-a
              (string.copy module-a))
            (load.compiler-load-session-state-embedded-provenance-noted?
              (owned_view.compiler-owned-shared-view state-a))
            (not
              (compiler-load-session-state-embedded-stdlib-module-id?
                state-b
                (string.copy module-b)))
            (not
              (load.compiler-load-session-state-embedded-provenance-noted?
                state-b))
            (=
              (ci.intern-compat-state-pool-len (& intern-decoy))
              decoy-pool-before)
            (=
              (ci.intern-compat-state-table-id (& active-after))
              (ci.intern-compat-state-table-id (& intern-decoy))))))
      ;; The inverse transition matters during today's compatibility
      ;; migration: when A is installed, inserting through A must publish
      ;; and then recapture the active scalar count for later explicit use.
      (ci.intern-compat-state-install! intern-a)
      (load.compiler-load-session-state-use-with-intern-state! state-a intern-a)
      (load.compiler-load-session-state-note-embedded-module!
        state-a
        "stdlib/state_active.tl")
      (set!
        ok
        (and
          ok
          (=
            (ci.intern-pool-len)
            (ci.intern-compat-state-pool-len
              (& (array-ref state-a.intern-state 0))))
          (compiler-load-session-state-embedded-stdlib-module-id?
            state-a
            "stdlib.state_active")))
      (load.compiler-load-session-state-restore! previous-state)
      (ci.intern-compat-state-install! active-intern-before)
      ok)))

;; A stdlib suffix names one file per session (#8430): a root file takes the
;; name `stdlib/<suffix>`, a path already spelled that way names itself, and a
;; second file claiming the suffix leaves both on their path-derived names.
(define (compiler-load-canonical-stdlib-path-claims-ok?) : bool
  (let
    [previous-state : load.CompilerLoadSessionState
      (load.compiler-load-global-shared-view
        load.compiler-load-active-session-state)]
    [state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [_use : unit (load.compiler-load-session-state-use! state)]
    [io-id : i64
      (load.compiler-load-session-state-intern
        (owned_view.compiler-owned-shared-view state)
        "io.tl")]
    [string-id : i64
      (load.compiler-load-session-state-intern
        (owned_view.compiler-owned-shared-view state)
        "string.tl")]
    [unmapped-empty : bool
      (string.eq
        (load.compiler-load-canonical-stdlib-path "/roots/a/io.tl")
        "/roots/a/io.tl")]
    [_note-root : unit
      (load.compiler-load-session-state-note-stdlib-path!
        (owned_view.compiler-owned-shared-view state)
        io-id
        "io.tl"
        "/roots/a/./io.tl")]
    [_note-identity : unit
      (load.compiler-load-session-state-note-stdlib-path!
        (owned_view.compiler-owned-shared-view state)
        string-id
        "string.tl"
        "stdlib/string.tl")]
    [claimed : bool
      (and
        (string.eq
          (load.compiler-load-canonical-stdlib-path "/roots/a/io.tl")
          "stdlib/io.tl")
        (string.eq
          (load.compiler-load-canonical-stdlib-path "stdlib/string.tl")
          "stdlib/string.tl")
        (string.eq
          (load.compiler-load-canonical-stdlib-path "/roots/a/main.tl")
          "/roots/a/main.tl"))]
    [_note-second-io : unit
      (load.compiler-load-session-state-note-stdlib-path!
        (owned_view.compiler-owned-shared-view state)
        io-id
        "io.tl"
        "/roots/b/io.tl")]
    [_note-second-string : unit
      (load.compiler-load-session-state-note-stdlib-path!
        (owned_view.compiler-owned-shared-view state)
        string-id
        "string.tl"
        "/roots/a/string.tl")]
    [conflicted : bool
      (and
        (string.eq
          (load.compiler-load-canonical-stdlib-path "/roots/a/io.tl")
          "/roots/a/io.tl")
        (string.eq
          (load.compiler-load-canonical-stdlib-path "/roots/b/io.tl")
          "/roots/b/io.tl")
        (string.eq
          (load.compiler-load-canonical-stdlib-path "stdlib/string.tl")
          "stdlib/string.tl")
        (string.eq
          (load.compiler-load-canonical-stdlib-path "/roots/a/string.tl")
          "/roots/a/string.tl"))]
    [_reset : unit
      (load.compiler-load-session-state-embedded-provenance-reset!
        (owned_view.compiler-owned-shared-view state))]
    [_note-after-reset : unit
      (load.compiler-load-session-state-note-stdlib-path!
        (owned_view.compiler-owned-shared-view state)
        io-id
        "io.tl"
        "/roots/b/io.tl")]
    [reclaimed : bool
      (string.eq
        (load.compiler-load-canonical-stdlib-path "/roots/b/io.tl")
        "stdlib/io.tl")]
    (load.compiler-load-session-state-restore! previous-state)
    (and unmapped-empty claimed conflicted reclaimed)))

(define (compiler-load-session-explicit-parse-isolation-ok?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [previous-state : load.CompilerLoadSessionState
      (load.compiler-load-global-shared-view
        load.compiler-load-active-session-state)]
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [_enable-a : unit (compiler-load-session-state-cache-enable! state-a)]
    [_select-b : unit (load.compiler-load-session-state-use! state-b)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [cfgs : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    [ok-path : String "explicit-state-a.tl"]
    [ok-id : i64 (load.compiler-load-source-path-id (string.copy ok-path))]
    [first : parser.ResultAstProgramDiagnostic
      (load.compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
        (owned_view.compiler-owned-shared-view state-a)
        (string.copy ok-path)
        ok-id
        "(define value : i64 42)"
        cfgs
        pools)]
    [second : parser.ResultAstProgramDiagnostic
      (load.compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
        (owned_view.compiler-owned-shared-view state-a)
        (string.copy ok-path)
        ok-id
        "(define value : i64 42)"
        cfgs
        pools)]
    [bad-path : String "explicit-state-a-bad.tl"]
    [bad : parser.ResultAstProgramDiagnostic
      (load.compiler-load-parse-embedded-source-diagnostic-session-id-with-pools
        (owned_view.compiler-owned-shared-view state-a)
        (string.copy bad-path)
        (load.compiler-load-source-path-id (string.copy bad-path))
        "("
        cfgs
        pools)]
    [ok : bool
      (and
        (arena.eq? (arena.current) home)
        (load.compiler-load-ast-program-result-ok? first)
        (load.compiler-load-ast-program-result-ok? second)
        (match bad
          [(Err diag)
            (and
              (string.eq
                (cdiag.compiler-diagnostic-path (__tl-box-place diag))
                bad-path)
              (>
                (string.string-length
                  (cdiag.compiler-diagnostic-message (__tl-box-place diag)))
                0))]
          [_ false])
        (=
          (load.compiler-load-session-state-program-cache-hit-count-value
            state-a)
          1)
        (=
          (load.compiler-load-session-state-program-cache-miss-count-value
            state-a)
          2)
        (=
          (load.compiler-load-session-state-program-cache-store-count-value
            state-a)
          1)
        (load.compiler-load-session-state-embedded-stdlib-source-used? state-a)
        (=
          (load.compiler-load-session-state-program-cache-hit-count-value
            state-b)
          0)
        (=
          (load.compiler-load-session-state-program-cache-miss-count-value
            state-b)
          0)
        (=
          (load.compiler-load-session-state-program-cache-store-count-value
            state-b)
          0)
        (not
          (load.compiler-load-session-state-embedded-stdlib-source-used?
            state-b)))]
    (load.compiler-load-session-state-use! previous-state)
    ok))

(define (compiler-load-session-owned-traversal-isolation-ok?) : bool
  (let
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [alias-a-member-id : i64 cbi.compiler-builtin-id-fix-arena_dot_Arena]
    [alias-a-id : i64 (ci.intern-leading-dot-id alias-a-member-id)]
    [member-a-id : i64
      (load.compiler-load-session-state-lazy-qualified-member-id
        (owned_view.compiler-owned-shared-view state-a)
        alias-a-member-id
        alias-a-id)]
    [alias-b-member-id : i64 cbi.compiler-builtin-id-fix-stdlib_dot_string]
    [alias-b-id : i64 (ci.intern-leading-dot-id alias-b-member-id)]
    [member-b-id : i64
      (load.compiler-load-session-state-lazy-qualified-member-id
        (owned_view.compiler-owned-shared-view state-b)
        alias-b-member-id
        alias-b-id)]
    [secondary-root-id : i64 cbi.compiler-builtin-id-fix-empty]
    [summary : load.CompilerLoadSurfaceSummary
      (load.CompilerLoadSurfaceSummary
        alias-a-id
        alias-a-id
        false
        false
        alias-b-id
        "state.tl"
        ""
        (load.compiler-load-surface-import-list-empty)
        (load.compiler-load-surface-decl-list-empty)
        false
        false
        false
        false
        (CompilerLoadLazyImportDirect))]
    [_seed-b-caches : unit
      (begin
        (set! (array-ref state-b.program-cache-hit-count 0) 7)
        (set! (array-ref state-b.runtime-prelude-cache-ready 0) true))]
    [_clear-a-caches : unit
      (begin
        (load.compiler-load-session-state-program-cache-clear!
          (owned_view.compiler-owned-shared-view state-a))
        (load.compiler-load-session-state-runtime-prelude-cache-clear!
          (owned_view.compiler-owned-shared-view state-a)))]
    [dotted-id : i64 alias-a-member-id]
    [_seed-b-dotted : unit
      (begin
        (load.compiler-load-session-state-dotted-path-cache-reset!
          (owned_view.compiler-owned-shared-view state-b))
        (load.compiler-load-session-state-dotted-path-cache-store!
          state-b
          dotted-id
          "pkg/member.tl")
        (load.compiler-load-session-state-dotted-path-cache-reset!
          (owned_view.compiler-owned-shared-view state-a)))]
    [_record-a : unit
      (begin
        (load.compiler-load-session-state-surface-summary-load-enter!
          (owned_view.compiler-owned-shared-view state-a))
        (load.compiler-load-session-state-record-surface-summary!
          state-a
          (ast.ast-place-shared-view summary))
        (load.compiler-load-session-state-lazy-import-record-skip!
          (owned_view.compiler-owned-shared-view state-a))
        (load.compiler-load-session-state-lazy-import-record-skip!
          (owned_view.compiler-owned-shared-view state-a))
        (compiler-load-session-state-lazy-qualified-observer-begin-pair!
          state-a
          alias-a-id
          secondary-root-id)
        (load.compiler-load-session-state-lazy-qualified-observer-note!
          state-a
          alias-a-member-id))]
    [_record-b : unit
      (begin
        (load.compiler-load-session-state-surface-summary-load-enter!
          (owned_view.compiler-owned-shared-view state-b))
        (load.compiler-load-session-state-record-surface-summary!
          state-b
          summary)
        (load.compiler-load-session-state-lazy-import-record-skip!
          (owned_view.compiler-owned-shared-view state-b))
        (compiler-load-session-state-lazy-qualified-observer-begin-pair!
          state-b
          alias-b-id
          secondary-root-id)
        (load.compiler-load-session-state-lazy-qualified-observer-note!
          state-b
          alias-b-member-id))]
    [observed-b : CompilerLoadLazyQualifiedObserverResult
      (compiler-load-session-state-lazy-qualified-observer-end-pair! state-b)]
    [a-still-active : bool
      (load.compiler-load-session-state-lazy-qualified-observer-active? state-a)]
    [observed-a : CompilerLoadLazyQualifiedObserverResult
      (compiler-load-session-state-lazy-qualified-observer-end-pair! state-a)]
    [_finish : unit
      (begin
        (load.compiler-load-session-state-surface-summary-load-exit!
          (owned_view.compiler-owned-shared-view state-a))
        (load.compiler-load-session-state-surface-summary-load-exit!
          (owned_view.compiler-owned-shared-view state-b)))]
    [before-reset : bool
      (and
        a-still-active
        (not
          (load.compiler-load-session-state-lazy-qualified-observer-active?
            state-b))
        (= (load.compiler-load-session-state-lazy-import-skip-count state-a) 2)
        (= (load.compiler-load-session-state-lazy-import-skip-count state-b) 1)
        (sym_i64_env.sym-i64-contains-id observed-a.primary-members member-a-id)
        (sym_i64_env.sym-i64-contains-id observed-b.primary-members member-b-id))]
    [_reset-a : unit
      (load.compiler-load-session-state-surface-summaries-reset!
        (owned_view.compiler-owned-shared-view state-a))]
    (cond
      [(not before-reset)
        (io.panic "compiler-load: traversal before-reset mismatch")]
      [(not (= (array-ref state-b.program-cache-hit-count 0) 7))
        (io.panic "compiler-load: traversal program cache mismatch")]
      [(not (array-ref state-b.runtime-prelude-cache-ready 0))
        (io.panic "compiler-load: traversal prelude cache mismatch")]
      [(not
          (match (load.compiler-load-session-state-dotted-path-cache-lookup
            state-b
            dotted-id)
            [(CompilerLoadSomeString path) (string.eq path "pkg/member.tl")]
            [_ false]))
        (io.panic "compiler-load: traversal dotted cache mismatch")]
      [(not
          (=
            (load.compiler-load-session-state-lazy-import-skip-count state-a)
            0))
        (io.panic "compiler-load: traversal reset count mismatch")]
      [(not
          (=
            (load.compiler-load-session-state-lazy-import-skip-count state-b)
            1))
        (io.panic "compiler-load: traversal peer count mismatch")]
      [(not
          (match (load.compiler-load-session-state-surface-summary-find-source
            state-a
            alias-b-id)
            [(CompilerLoadNoSurfaceSummary) true]
            [_ false]))
        (io.panic "compiler-load: traversal reset summary mismatch")]
      [(not
          (match (load.compiler-load-session-state-surface-summary-find-source
            state-b
            alias-b-id)
            [(CompilerLoadSomeSurfaceSummary _) true]
            [_ false]))
        (io.panic "compiler-load: traversal peer summary mismatch")]
      [else true])))

;; The raw IDs deliberately collide between A and B. A third same-capacity
;; table containing only plain names stays installed while the demand helpers
;; interpret each ID through its load-session owner. Resetting B then makes its
;; old IDs fail closed without affecting A or the installed decoy.
(define (compiler-load-session-lazy-intern-isolation-ok?) : bool
  (let
    [previous-load-state : load.CompilerLoadSessionState
      (load.compiler-load-global-shared-view
        load.compiler-load-active-session-state)]
    [previous-interns : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [decoy : ci.InternCompatState (ci.intern-compat-state-new)]
    [alias-a : i64 (ci.intern-compat-state-intern (&mut intern-a) "alpha")]
    [name-a : i64 (ci.intern-compat-state-intern (&mut intern-a) "alpha.left")]
    [alias-b : i64 (ci.intern-compat-state-intern (&mut intern-b) "beta")]
    [name-b : i64 (ci.intern-compat-state-intern (&mut intern-b) "beta.right")]
    [_bind-a : unit
      (load.compiler-load-session-state-use-with-intern-state!
        state-a
        (owned_view.compiler-owned-shared-view intern-a))]
    [_bind-b : unit
      (load.compiler-load-session-state-use-with-intern-state!
        state-b
        (owned_view.compiler-owned-shared-view intern-b))]
    [decoy-index : i64 0]
    [ok : bool false]
    (while (<= (ci.intern-compat-state-pool-len (& decoy)) name-a)
      (begin
        (ci.intern-compat-state-intern
          (&mut decoy)
          (& (str_cat.str-cat "plain" (string.int->string decoy-index))))
        unit)
      (set! decoy-index (+ decoy-index 1)))
    (let
      [decoy-len : i64 (ci.intern-compat-state-pool-len (& decoy))]
      (ci.intern-compat-state-install! decoy)
      (let
        [member-a : i64
          (load.compiler-load-session-state-lazy-qualified-member-id
            (owned_view.compiler-owned-shared-view state-a)
            name-a
            alias-a)]
        [member-b : i64
          (load.compiler-load-session-state-lazy-qualified-member-id
            (owned_view.compiler-owned-shared-view state-b)
            name-b
            alias-b)]
        [before-reset : bool
          (and
            (= alias-a alias-b)
            (= name-a name-b)
            (= member-a member-b)
            (>= member-a 0)
            (string.eq
              (ci.intern-compat-state-str (& intern-a) member-a)
              "left")
            (string.eq
              (ci.intern-compat-state-str (& intern-b) member-b)
              "right")
            (not (ci.intern-compat-state-dotted? (& decoy) name-a))
            (= (ci.intern-compat-state-pool-len (& decoy)) decoy-len))]
        (ci.intern-compat-state-reset! (&mut intern-b))
        (set!
          ok
          (and
            before-reset
            (<
              (load.compiler-load-session-state-lazy-qualified-member-id
                state-b
                name-b
                alias-b)
              0)
            (=
              (load.compiler-load-session-state-lazy-qualified-member-id
                state-a
                name-a
                alias-a)
              member-a)
            (= (ci.intern-compat-state-pool-len (& decoy)) decoy-len)))))
    (ci.intern-compat-state-install! previous-interns)
    (load.compiler-load-session-state-use! previous-load-state)
    ok))

(define (compiler-load-lazy-qualified-observer-test-root
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 1000 level)))

(define (compiler-load-lazy-qualified-observer-test-secondary-root
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 2000 level)))

(define (compiler-load-lazy-qualified-observer-test-member
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 3000 level)))

(define (compiler-load-lazy-qualified-observer-test-secondary-member
  [offset : i64]
  [level : i64]) : i64
  (+ offset (+ 4000 level)))

(define (compiler-load-lazy-qualified-observer-test-exhaustive? [level : i64]) : bool
  (= (% level 2) 0))

(define (compiler-load-lazy-qualified-observer-test-secondary-qualified?
  [level : i64]) : bool
  (= (% level 3) 1))

(define (compiler-load-lazy-qualified-observer-test-secondary-direct?
  [level : i64]) : bool
  (= (% level 4) 2))

(define (compiler-load-lazy-qualified-observer-test-configure!
  [state : (& state load.CompilerLoadSessionState)]
  [offset : i64]
  [level : i64]) : unit
  (let
    [observer : (& state load.CompilerLoadLazyQualifiedObserverState)
      (load.compiler-load-session-state-lazy-qualified-observer state)]
    ;; Production begin-pair makes every active query exhaustive. Vary this
    ;; internal bit here so the frame test proves it is snapshotted rather
    ;; than accidentally derived from active state during a pop.
    (load.compiler-load-lazy-qualified-observer-flag-set!
      observer
      1
      (compiler-load-lazy-qualified-observer-test-exhaustive? level))
    (load.compiler-load-lazy-qualified-observer-members-set!
      observer
      0
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-empty)
        (compiler-load-lazy-qualified-observer-test-member offset level)
        1))
    (load.compiler-load-lazy-qualified-observer-members-set!
      observer
      1
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-empty)
        (compiler-load-lazy-qualified-observer-test-secondary-member
          offset
          level)
        1))
    (load.compiler-load-lazy-qualified-observer-flag-set!
      observer
      2
      (compiler-load-lazy-qualified-observer-test-secondary-qualified? level))
    (load.compiler-load-lazy-qualified-observer-flag-set!
      observer
      3
      (compiler-load-lazy-qualified-observer-test-secondary-direct? level))))

(define (compiler-load-lazy-qualified-observer-test-empty-state?
  [state : (& state load.CompilerLoadSessionState)]
  [offset : i64]) : bool
  (let
    [observer : (& state load.CompilerLoadLazyQualifiedObserverState)
      (load.compiler-load-session-state-lazy-qualified-observer state)]
    [primary-members : sym_i64_env.SymI64Env
      (load.compiler-load-lazy-qualified-observer-members observer 0)]
    [secondary-members : sym_i64_env.SymI64Env
      (load.compiler-load-lazy-qualified-observer-members observer 1)]
    [stack : load.CompilerLoadLazyQualifiedObserverStack
      (load.compiler-load-global-array-element-shared-view observer.stack 0)]
    (and
      (not (load.compiler-load-lazy-qualified-observer-flag observer 0))
      (not (load.compiler-load-lazy-qualified-observer-flag observer 1))
      (= (load.compiler-load-lazy-qualified-observer-root-id observer 0) 0)
      (= (load.compiler-load-lazy-qualified-observer-root-id observer 1) 0)
      (not
        (sym_i64_env.sym-i64-contains-id
          primary-members
          (compiler-load-lazy-qualified-observer-test-member offset 0)))
      (not
        (sym_i64_env.sym-i64-contains-id
          secondary-members
          (compiler-load-lazy-qualified-observer-test-secondary-member offset 0)))
      (not (load.compiler-load-lazy-qualified-observer-flag observer 2))
      (not (load.compiler-load-lazy-qualified-observer-flag observer 3))
      (= (compiler-load-lazy-qualified-observer-stack-count stack) 0))))

(define (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
  [state : (& state load.CompilerLoadSessionState)]) : bool
  (let
    [observer : (& state load.CompilerLoadLazyQualifiedObserverState)
      (load.compiler-load-session-state-lazy-qualified-observer state)]
    [stack : load.CompilerLoadLazyQualifiedObserverStack
      (load.compiler-load-global-array-element-shared-view observer.stack 0)]
    (= (array-length stack.slots) 0)))

(define (compiler-load-lazy-qualified-observer-test-state-at?
  [state : (& state load.CompilerLoadSessionState)]
  [offset : i64]
  [level : i64]) : bool
  (if (< level 0)
    (compiler-load-lazy-qualified-observer-test-empty-state? state offset)
    (let
      [observer : (& state load.CompilerLoadLazyQualifiedObserverState)
        (load.compiler-load-session-state-lazy-qualified-observer state)]
      [primary-members : sym_i64_env.SymI64Env
        (load.compiler-load-lazy-qualified-observer-members observer 0)]
      [secondary-members : sym_i64_env.SymI64Env
        (load.compiler-load-lazy-qualified-observer-members observer 1)]
      (and
        (load.compiler-load-lazy-qualified-observer-flag observer 0)
        (=
          (load.compiler-load-lazy-qualified-observer-flag observer 1)
          (compiler-load-lazy-qualified-observer-test-exhaustive? level))
        (=
          (load.compiler-load-lazy-qualified-observer-root-id observer 0)
          (compiler-load-lazy-qualified-observer-test-root offset level))
        (=
          (load.compiler-load-lazy-qualified-observer-root-id observer 1)
          (compiler-load-lazy-qualified-observer-test-secondary-root
            offset
            level))
        (sym_i64_env.sym-i64-contains-id
          primary-members
          (compiler-load-lazy-qualified-observer-test-member offset level))
        (sym_i64_env.sym-i64-contains-id
          secondary-members
          (compiler-load-lazy-qualified-observer-test-secondary-member
            offset
            level))
        (=
          (load.compiler-load-lazy-qualified-observer-flag observer 2)
          (compiler-load-lazy-qualified-observer-test-secondary-qualified?
            level))
        (=
          (load.compiler-load-lazy-qualified-observer-flag observer 3)
          (compiler-load-lazy-qualified-observer-test-secondary-direct? level))
        (=
          (compiler-load-lazy-qualified-observer-stack-count
            (array-ref observer.stack 0))
          (+ level 1))))))

(define (compiler-load-lazy-qualified-observer-test-result-at?
  [result : CompilerLoadLazyQualifiedObserverResult]
  [offset : i64]
  [level : i64]) : bool
  (and
    (sym_i64_env.sym-i64-contains-id
      result.primary-members
      (compiler-load-lazy-qualified-observer-test-member offset level))
    (sym_i64_env.sym-i64-contains-id
      result.secondary-members
      (compiler-load-lazy-qualified-observer-test-secondary-member offset level))
    (=
      result.secondary-qualified
      (compiler-load-lazy-qualified-observer-test-secondary-qualified? level))
    (=
      result.secondary-direct
      (compiler-load-lazy-qualified-observer-test-secondary-direct? level))))

(define (compiler-load-lazy-qualified-observer-test-empty-result?
  [result : CompilerLoadLazyQualifiedObserverResult]
  [offset : i64]) : bool
  (and
    (not
      (sym_i64_env.sym-i64-contains-id
        result.primary-members
        (compiler-load-lazy-qualified-observer-test-member offset 0)))
    (not
      (sym_i64_env.sym-i64-contains-id
        result.secondary-members
        (compiler-load-lazy-qualified-observer-test-secondary-member offset 0)))
    (not result.secondary-qualified)
    (not result.secondary-direct)))

(define (compiler-load-lazy-qualified-observer-test-push-depth!
  [state : (& state load.CompilerLoadSessionState)]
  [offset : i64]
  [depth : i64]) : unit
  (let
    [level : i64 0]
    (while (< level depth)
      (compiler-load-session-state-lazy-qualified-observer-begin-pair!
        state
        (compiler-load-lazy-qualified-observer-test-root offset level)
        (compiler-load-lazy-qualified-observer-test-secondary-root offset level))
      (compiler-load-lazy-qualified-observer-test-configure! state offset level)
      (set! level (+ level 1)))))

;; Crosses six geometric capacity boundaries, then pops two independently
;; owned states in an interleaved order. Every frame field is varied so a
;; missing snapshot/restore cannot hide behind the ordinary production values.
(define (compiler-load-lazy-qualified-observer-dense-stack-ok?) : bool
  (let
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-reset : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [offset-a : i64 0]
    [offset-b : i64 10000]
    [offset-reset : i64 20000]
    [depth : i64 40]
    [level : i64 0]
    [ok : bool true]
    (while (< level depth)
      (compiler-load-session-state-lazy-qualified-observer-begin-pair!
        state-a
        (compiler-load-lazy-qualified-observer-test-root offset-a level)
        (compiler-load-lazy-qualified-observer-test-secondary-root
          offset-a
          level))
      (compiler-load-lazy-qualified-observer-test-configure!
        state-a
        offset-a
        level)
      (compiler-load-session-state-lazy-qualified-observer-begin-pair!
        state-b
        (compiler-load-lazy-qualified-observer-test-root offset-b level)
        (compiler-load-lazy-qualified-observer-test-secondary-root
          offset-b
          level))
      (compiler-load-lazy-qualified-observer-test-configure!
        state-b
        offset-b
        level)
      (set! level (+ level 1)))
    (set! level (- depth 1))
    (while (and ok (>= level 0))
      (let
        [result-b : CompilerLoadLazyQualifiedObserverResult
          (compiler-load-session-state-lazy-qualified-observer-end-pair!
            state-b)]
        (set!
          ok
          (and
            (compiler-load-lazy-qualified-observer-test-result-at?
              result-b
              offset-b
              level)
            (compiler-load-lazy-qualified-observer-test-state-at?
              state-a
              offset-a
              level)
            (compiler-load-lazy-qualified-observer-test-state-at?
              state-b
              offset-b
              (- level 1))))
        (if ok
          (let
            [result-a : CompilerLoadLazyQualifiedObserverResult
              (compiler-load-session-state-lazy-qualified-observer-end-pair!
                state-a)]
            (set!
              ok
              (and
                (compiler-load-lazy-qualified-observer-test-result-at?
                  result-a
                  offset-a
                  level)
                (compiler-load-lazy-qualified-observer-test-state-at?
                  state-a
                  offset-a
                  (- level 1))
                (compiler-load-lazy-qualified-observer-test-state-at?
                  state-b
                  offset-b
                  (- level 1)))))
          unit)
        (set! level (- level 1))))
    ;; A reset from a deep live stack must discard its backing slots rather
    ;; than leave an arena-owned array reachable through the session state.
    (compiler-load-lazy-qualified-observer-test-push-depth!
      state-reset
      offset-reset
      depth)
    (load.compiler-load-session-state-lazy-qualified-observer-reset!
      state-reset)
    (set!
      ok
      (and
        ok
        (compiler-load-lazy-qualified-observer-test-empty-state?
          state-reset
          offset-reset)
        (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
          state-reset)))
    ;; The state remains reusable after that reset.
    (compiler-load-session-state-lazy-qualified-observer-begin-pair!
      state-reset
      (compiler-load-lazy-qualified-observer-test-root offset-reset 0)
      (compiler-load-lazy-qualified-observer-test-secondary-root offset-reset 0))
    (compiler-load-lazy-qualified-observer-test-configure!
      state-reset
      offset-reset
      0)
    (let
      [reset-result : CompilerLoadLazyQualifiedObserverResult
        (compiler-load-session-state-lazy-qualified-observer-end-pair!
          state-reset)]
      (set!
        ok
        (and
          ok
          (compiler-load-lazy-qualified-observer-test-result-at?
            reset-result
            offset-reset
            0)
          (compiler-load-lazy-qualified-observer-test-empty-state?
            state-reset
            offset-reset))))
    ;; Empty pops preserve the old contract: return an empty observation and
    ;; leave both independent states inactive.
    (let
      [underflow-a : CompilerLoadLazyQualifiedObserverResult
        (compiler-load-session-state-lazy-qualified-observer-end-pair! state-a)]
      [underflow-b : CompilerLoadLazyQualifiedObserverResult
        (compiler-load-session-state-lazy-qualified-observer-end-pair! state-b)]
      (and
        ok
        (compiler-load-lazy-qualified-observer-test-empty-result?
          underflow-a
          offset-a)
        (compiler-load-lazy-qualified-observer-test-empty-result?
          underflow-b
          offset-b)
        (compiler-load-lazy-qualified-observer-test-empty-state?
          state-a
          offset-a)
        (compiler-load-lazy-qualified-observer-test-empty-state?
          state-b
          offset-b)
        (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
          state-a)
        (compiler-load-lazy-qualified-observer-test-stack-capacity-zero?
          state-b)))))

(define (compiler-load-surface-summary-list-test-summary
  [module-id : i64]
  [source-path-id : i64]
  [source-path : String]) : load.CompilerLoadSurfaceSummary
  (load.CompilerLoadSurfaceSummary
    module-id
    module-id
    true
    true
    source-path-id
    source-path
    ""
    (load.compiler-load-surface-import-list-empty)
    (load.compiler-load-surface-decl-list-empty)
    false
    false
    false
    false
    (CompilerLoadLazyImportDirect)))

(define (compiler-load-surface-summary-dense-session-ok?) : bool
  (let
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [module-a : i64 (ci.intern "surface-dense.module-a")]
    [module-b : i64 (ci.intern "surface-dense.module-b")]
    [module-peer : i64 (ci.intern "surface-dense.module-peer")]
    [source-a : i64 (ci.intern "target/surface-dense-a.tl")]
    [source-b : i64 (ci.intern "target/surface-dense-b.tl")]
    [source-peer : i64 (ci.intern "target/surface-dense-peer.tl")]
    [summary-a : load.CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-a
        source-a
        "target/surface-dense-a.tl")]
    [duplicate-source : load.CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-b
        source-a
        "target/surface-dense-a-duplicate.tl")]
    [duplicate-module : load.CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-a
        source-b
        "target/surface-dense-b.tl")]
    [reloaded : load.CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-b
        source-b
        "target/surface-dense-b-reloaded.tl")]
    [peer : load.CompilerLoadSurfaceSummary
      (compiler-load-surface-summary-list-test-summary
        module-peer
        source-peer
        "target/surface-dense-peer.tl")]
    ;; Interleave independent sessions and prove duplicate-source suppression
    ;; does not suppress a distinct source with the same module identity.
    (load.compiler-load-session-state-record-surface-summary!
      (& state-a)
      summary-a)
    (load.compiler-load-session-state-record-surface-summary! (& state-b) peer)
    (load.compiler-load-session-state-record-surface-summary!
      (& state-a)
      duplicate-source)
    (load.compiler-load-session-state-record-surface-summary!
      (& state-a)
      duplicate-module)
    (let
      [before : load.CompilerLoadSurfaceSummaryList
        (load.compiler-load-session-state-surface-summaries state-a)]
      [before-ok : bool
        (and
          (= (load.compiler-load-surface-summary-list-count before) 2)
          (>=
            (array-length before.slots)
            (load.compiler-load-surface-summary-list-count before))
          (=
            (__tl-project-field
              (load.compiler-load-surface-summary-list-at before 0)
              source-path-id)
            source-b)
          (=
            (__tl-project-field
              (load.compiler-load-surface-summary-list-at before 1)
              source-path-id)
            source-a)
          (match (load.compiler-load-session-state-surface-summary-find-source
            state-a
            source-a)
            [(CompilerLoadSomeSurfaceSummary summary)
              (= summary.module-id module-a)]
            [_ false])
          (match (load.compiler-load-session-state-surface-summary-find-module
            state-a
            module-a)
            [(CompilerLoadSomeSurfaceSummary summary)
              (= summary.source-path-id source-b)]
            [_ false]))]
      [_remove : unit
        (load.compiler-load-session-state-surface-summary-remove-source!
          (owned_view.compiler-owned-shared-view state-a)
          source-b)]
      [after-remove-ok : bool
        (and
          (=
            (let
              [summaries
                (load.compiler-load-session-state-surface-summaries state-a)]
              (load.compiler-load-surface-summary-list-count summaries))
            1)
          (match (load.compiler-load-session-state-surface-summary-find-module
            state-a
            module-a)
            [(CompilerLoadSomeSurfaceSummary summary)
              (= summary.source-path-id source-a)]
            [_ false]))]
      [_reload : unit
        (load.compiler-load-session-state-record-surface-summary!
          state-a
          reloaded)]
      [reload-ok : bool
        (and
          (=
            (let
              [summaries
                (load.compiler-load-session-state-surface-summaries state-a)]
              (load.compiler-load-surface-summary-list-count summaries))
            2)
          (match (load.compiler-load-session-state-surface-summary-find-source
            state-a
            source-b)
            [(CompilerLoadSomeSurfaceSummary summary)
              (= summary.module-id module-b)]
            [_ false]))]
      [_reset-a : unit
        (load.compiler-load-session-state-surface-summaries-reset!
          (owned_view.compiler-owned-shared-view state-a))]
      [isolation-ok : bool
        (and
          (=
            (let
              [summaries
                (load.compiler-load-session-state-surface-summaries state-a)]
              (load.compiler-load-surface-summary-list-count summaries))
            0)
          (=
            (let
              [summaries
                (load.compiler-load-session-state-surface-summaries state-b)]
              (load.compiler-load-surface-summary-list-count summaries))
            1)
          (match (load.compiler-load-session-state-surface-summary-find-source
            state-b
            source-peer)
            [(CompilerLoadSomeSurfaceSummary summary)
              (= summary.module-id module-peer)]
            [_ false]))]
      (and before-ok after-remove-ok reload-ok isolation-ok))))

;; A generated import records its surface summary while the macro walk's
;; reclaimable arena is current, then the lazy-import handoff reads that summary
;; after the macro arena has been destroyed. Pin that exact lifetime boundary:
;; the session record must own the copied string and nested list descriptors.
(define (compiler-load-surface-summary-scratch-handoff-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [module-id : i64 (ci.intern "surface-scratch.module")]
    [source-id : i64 (ci.intern "target/surface-scratch.tl")]
    [decl-id : i64 (ci.intern "surface-scratch-value")]
    [scratch : i64 (arena.tl_arena_make)]
    [_enter : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- moved from the audited compiler_load module.
        (arena.tl_arena_set scratch))]
    [imports : (__tl_dyn-array load.CompilerLoadSurfaceImport)
      (__tl_make-array load.CompilerLoadSurfaceImport 1)]
    [decls : (__tl_dyn-array load.CompilerLoadSurfaceDecl)
      (__tl_make-array load.CompilerLoadSurfaceDecl 1)]
    [_fill-nested : unit
      (begin
        (set!
          (array-ref imports 0)
          (load.CompilerLoadSurfaceImport
            (CompilerLoadSurfaceImportModule)
            module-id
            (string.copy "target/surface-scratch.tl")
            (string.copy "surface.scratch.dep")
            (CompilerLoadSurfaceSomeString (string.copy "surface.scratch.dep"))
            (CompilerLoadSurfaceSomeString (string.copy "scratch-dep"))
            (CompilerLoadSurfaceSomeString (string.copy "scratch-default"))
            (load.compiler-load-surface-zero-span)))
        (set!
          (array-ref decls 0)
          (load.CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceValue)
            decl-id
            module-id
            (CompilerLoadSurfaceNoSignature)
            (CompilerLoadSurfaceMacroOther)
            false
            false
            false
            false
            (load.compiler-load-surface-zero-span))))]
    [_record : unit
      (load.compiler-load-session-state-record-surface-summary!
        (& state)
        (load.CompilerLoadSurfaceSummary
          module-id
          module-id
          true
          true
          source-id
          (string.copy "target/surface-scratch.tl")
          (string.copy "surface-scratch-root")
          (load.CompilerLoadSurfaceImportList imports 1)
          (load.CompilerLoadSurfaceDeclList decls 1)
          false
          false
          false
          false
          (CompilerLoadLazyImportDirect)))]
    [_restore : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- moved from the audited compiler_load module.
        (arena.tl_arena_set home))]
    [_release : unit
      (unsafe
        ;; lint-allow: raw-arena-op -- moved from the audited compiler_load module.
        (arena.tl_arena_destroy scratch))]
    [handoff-ok : bool
      (match (load.compiler-load-session-state-surface-summary-find-source
        state
        source-id)
        [(CompilerLoadSomeSurfaceSummary summary)
          (let
            [import-edge : load.CompilerLoadSurfaceImport
              (load.compiler-load-surface-import-list-at (& summary.imports) 0)]
            [decl : load.CompilerLoadSurfaceDecl
              (load.compiler-load-surface-decl-list-at (& summary.decls) 0)]
            (and
              (= summary.module-id module-id)
              (string.eq summary.source-path "target/surface-scratch.tl")
              (string.eq summary.root-id "surface-scratch-root")
              (=
                (load.compiler-load-surface-import-list-count
                  (& summary.imports))
                1)
              (string.eq import-edge.source-path "target/surface-scratch.tl")
              (string.eq import-edge.import-path "surface.scratch.dep")
              (=
                (load.compiler-load-surface-decl-list-count (& summary.decls))
                1)
              (= decl.name decl-id)
              (= decl.module module-id)))]
        [_ false])]
    (load.compiler-load-session-state-surface-summaries-reset!
      (owned_view.compiler-owned-shared-view state))
    (and
      handoff-ok
      (=
        (load.compiler-load-session-state-surface-summary-owner-arena (& state))
        0)
      (=
        (let
          [summaries (load.compiler-load-session-state-surface-summaries state)]
          (load.compiler-load-surface-summary-list-count summaries))
        0))))

(define (compiler-load-dependency-catalog-registry-ok?) : bool
  (let
    [state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [other-state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [owner : i64
      (load.compiler-load-dependency-catalog-owner-arena-ensure!
        (load.compiler-load-global-shared-view state))]
    [checks : (__tl_dyn-array bool) (__tl_make-array false)]
    (load.compiler-load-session-state-set-dependency-tlci-force-source!
      (load.compiler-load-global-shared-view state)
      true)
    (load.compiler-load-session-state-set-dependency-tlci-force-source!
      (load.compiler-load-global-shared-view other-state)
      false)
    (in-arena
      (arena.Arena owner)
      (let
        [outer-root : String
          (load.compiler-load-canonical-path
            (load.compiler-load-join-root-path
              (fs.current-dir)
              "__dependency_catalog_test"))]
        [nested-root : String
          (load.compiler-load-join-root-path
            (load.compiler-load-global-shared-view outer-root)
            "nested")]
        [metadata-root : String
          (load.compiler-load-join-root-path
            (load.compiler-load-global-shared-view outer-root)
            "metadata")]
        [outer-key : load.CompilerLoadDependencyCatalogKey
          (load.CompilerLoadDependencyCatalogKey
            (load.compiler-load-global-shared-view outer-root)
            "outer"
            "1.0.0"
            (load.compiler-load-join-root-path
              (load.compiler-load-global-shared-view outer-root)
              "target/outer.tlci")
            11
            12
            13
            14
            "compiler-a")]
        [nested-key : load.CompilerLoadDependencyCatalogKey
          (load.CompilerLoadDependencyCatalogKey
            (load.compiler-load-global-shared-view nested-root)
            "nested"
            "2.0.0"
            (load.compiler-load-join-root-path
              (load.compiler-load-global-shared-view nested-root)
              "target/nested.tlci")
            21
            22
            23
            24
            "compiler-b")]
        [metadata-key : load.CompilerLoadDependencyCatalogKey
          (load.CompilerLoadDependencyCatalogKey
            (load.compiler-load-global-shared-view metadata-root)
            "metadata"
            "3.0.0"
            (load.compiler-load-join-root-path
              metadata-root
              "target/metadata.tlci")
            31
            32
            (tlci.tlci-build-host-platform)
            tlci.tlci-callback-abi-version
            "compiler-c")]
        [metadata-image : tlci.TlciImage
          (tlci.tlci-make-image
            (tlci.tlci-build-host-platform)
            tlci.tlci-callback-abi-version
            "compiler-c"
            (tlci.tlci-make-metadata-v2
              "metadata"
              "3.0.0"
              (tlci.tlci-spmd-callables-empty))
            (tlci.tlci-empty-bytes)
            (tlci.tlci-empty-bytes)
            (tlci.tlci-empty-bytes)
            (tlci.tlci-empty-bytes)
            (tlci.tlci-empty-bytes)
            (tlci.tlci-empty-bytes))]
        [outer-entry : load.CompilerLoadDependencyCatalogEntry
          (load.CompilerLoadDependencyCatalogEntry
            outer-key
            None
            (tlci.tlci-spmd-callables-empty)
            (Unavailable (Missing "outer missing")))]
        [nested-entry : load.CompilerLoadDependencyCatalogEntry
          (load.CompilerLoadDependencyCatalogEntry
            (load.compiler-load-global-shared-view nested-key)
            None
            (tlci.tlci-spmd-callables-empty)
            (Unavailable (Missing "nested missing")))]
        [metadata-entry : load.CompilerLoadDependencyCatalogEntry
          (load.CompilerLoadDependencyCatalogEntry
            metadata-key
            (Some metadata-image)
            (tlci.tlci-spmd-callables-empty)
            TrustedMetadataOnly)]
        [outer-slot : i64
          (load.compiler-load-dependency-catalog-record-owned!
            (load.compiler-load-global-shared-view state)
            outer-entry)]
        [nested-slot : i64
          (load.compiler-load-dependency-catalog-record-owned!
            (load.compiler-load-global-shared-view state)
            (load.compiler-load-global-shared-view nested-entry))]
        [metadata-slot : i64
          (load.compiler-load-dependency-catalog-record-owned!
            (load.compiler-load-global-shared-view state)
            metadata-entry)]
        [nested-provenance : i64
          (ci.intern
            (load.compiler-load-join-root-path
              (load.compiler-load-global-shared-view nested-root)
              "src/lib.tl"))]
        [outer-provenance : i64
          (ci.intern
            (load.compiler-load-join-root-path outer-root "src/lib.tl"))]
        [sibling-provenance : i64
          (ci.intern
            (load.compiler-load-join-root-path
              (fs.current-dir)
              "__dependency_catalog_test-other/src/lib.tl"))]
        [same-slot : i64
          (load.compiler-load-dependency-catalog-record-owned!
            (load.compiler-load-global-shared-view state)
            nested-entry)]
        [observation : load.CompilerLoadDependencyCatalogObservation
          (load.compiler-load-dependency-catalog-observe state)]
        (set!
          (array-ref checks 0)
          (and
            (load.compiler-load-session-state-dependency-tlci-force-source?
              state)
            (not
              (load.compiler-load-session-state-dependency-tlci-force-source?
                other-state))
            (= outer-slot 0)
            (= nested-slot 1)
            (= metadata-slot 2)
            (= same-slot nested-slot)
            (=
              (load.compiler-load-dependency-catalog-find-key-slot
                (load.compiler-load-global-shared-view state)
                (load.compiler-load-global-shared-view nested-key))
              nested-slot)
            (=
              (load.compiler-load-dependency-catalog-slot-for-provenance-id
                (load.compiler-load-global-shared-view state)
                nested-provenance)
              nested-slot)
            (=
              (load.compiler-load-dependency-catalog-slot-for-provenance-id
                (load.compiler-load-global-shared-view state)
                outer-provenance)
              outer-slot)
            (=
              (load.compiler-load-dependency-catalog-slot-for-provenance-id
                (load.compiler-load-global-shared-view state)
                sibling-provenance)
              -1)
            (=
              (load.compiler-load-dependency-catalog-slot-for-provenance-id
                other-state
                nested-provenance)
              -1)
            (match (load.compiler-load-dependency-catalog-lookup-macro
              (load.compiler-load-global-shared-view state)
              metadata-slot
              "metadata/macro")
              [(MetadataOnly) true]
              [_ false])
            (match (load.compiler-load-dependency-catalog-admitted-image
              state
              metadata-slot)
              [(TrustedMetadataOnly image)
                (and
                  (= (array-length image.code) 0)
                  (= (array-length image.fixups) 0)
                  (= (array-length image.entries) 0)
                  (= (array-length image.imports) 0))]
              [_ false])
            (match (load.compiler-load-dependency-catalog-lookup-macro
              (load.compiler-load-global-shared-view state)
              nested-slot
              "nested/macro")
              [(Unavailable (Missing message))
                (string.eq message "nested missing")]
              [_ false])
            (= observation.entries 3)
            (= observation.generation 3)
            (= observation.unavailable 2)
            (= observation.metadata-only 1)
            (= observation.trusted-code 0)
            (= observation.code-bytes 0)
            (= observation.fixup-bytes 0)
            (= observation.entry-bytes 0)
            (= observation.import-bytes 0)))
        (let
          [capability : load.CompilerLoadDependencyCatalogCapability
            (load.CompilerLoadDependencyCatalogCapability
              (load.compiler-load-session-state-dependency-catalog-handle
                (load.compiler-load-global-shared-view state))
              nested-slot
              (load.compiler-load-global-shared-view nested-key)
              (array-ref state.dependency-catalog.generation 0)
              (ci.intern nested-key.package-name)
              (ci.intern nested-key.package-version)
              (ci.intern nested-key.artifact-path)
              (tlci_loader_support.TlciResolvedMacroEntry 0 0))]
          [replacement-key : load.CompilerLoadDependencyCatalogKey
            (load.CompilerLoadDependencyCatalogKey
              (load.compiler-load-global-shared-view nested-root)
              "nested"
              "2.0.0"
              (load.compiler-load-join-root-path
                nested-root
                "target/nested-next.tlci")
              21
              222
              23
              24
              "compiler-b")]
          [replacement-entry : load.CompilerLoadDependencyCatalogEntry
            (load.CompilerLoadDependencyCatalogEntry
              replacement-key
              None
              (tlci.tlci-spmd-callables-empty)
              (Unavailable (Missing "nested replacement missing")))]
          (set!
            (array-ref checks 0)
            (and
              (array-ref checks 0)
              (load.compiler-load-dependency-catalog-capability-current?
                (load.compiler-load-global-shared-view capability))))
          (load.compiler-load-dependency-catalog-record-owned!
            (load.compiler-load-global-shared-view state)
            replacement-entry)
          (set!
            (array-ref checks 0)
            (and
              (array-ref checks 0)
              (not
                (load.compiler-load-dependency-catalog-capability-current?
                  capability)))))))
    (let
      [release-ok : bool
        (match (load.compiler-load-session-state-dependency-catalog-release!
          (load.compiler-load-global-shared-view state))
          [(Ok) true]
          [(Err _) false])]
      (and
        (array-ref checks 0)
        release-ok
        (= (load.compiler-load-dependency-catalog-owner-arena state) 0)
        (= (array-ref state.dependency-catalog.entries 0).len 0)))))

(define (compiler-load-self-test) : i64
  (unless
    (compiler-load-dependency-catalog-registry-ok?)
    (return (io.panic "compiler-load: dependency catalog registry mismatch")))
  (unless
    (compiler-load-embedded-provenance-observer-ok?)
    (return (io.panic "compiler-load: embedded provenance observer mismatch")))
  (unless
    (compiler-load-session-explicit-cache-api-isolation-ok?)
    (return
      (io.panic "compiler-load: explicit cache API isolation smoke mismatch")))
  (unless
    (compiler-load-session-embedded-provenance-isolation-ok?)
    (return
      (io.panic "compiler-load: embedded provenance isolation smoke mismatch")))
  (unless
    (compiler-load-canonical-stdlib-path-claims-ok?)
    (return (io.panic "compiler-load: canonical stdlib path claims mismatch")))
  (unless
    (compiler-load-session-explicit-parse-isolation-ok?)
    (return (io.panic "compiler-load: explicit parse isolation smoke mismatch")))
  (unless
    (compiler-load-session-owned-traversal-isolation-ok?)
    (return
      (io.panic "compiler-load: owned traversal isolation smoke mismatch")))
  (unless
    (compiler-load-session-lazy-intern-isolation-ok?)
    (return (io.panic "compiler-load: lazy intern isolation smoke mismatch")))
  (unless
    (compiler-load-surface-summary-dense-session-ok?)
    (return (io.panic "compiler-load: dense surface summary session mismatch")))
  (unless
    (compiler-load-surface-summary-scratch-handoff-ok?)
    (return
      (io.panic "compiler-load: surface summary scratch handoff mismatch")))
  (unless
    (compiler-load-lazy-qualified-observer-dense-stack-ok?)
    (return
      (io.panic "compiler-load: lazy qualified observer dense stack mismatch")))
  (unless
    (compiler-load-append-onto-reuse-ok?)
    (return (io.panic "compiler-load: append-onto reuse smoke mismatch")))
  (unless
    (compiler-load-normalize-ok?)
    (return (io.panic "compiler-load: normalize smoke mismatch")))
  (unless
    (compiler-load-canonical-module-id-ok?)
    (return (io.panic "compiler-load: canonical module id smoke mismatch")))
  (unless
    (compiler-load-relative-resolution-ok?)
    (return (io.panic "compiler-load: relative resolution smoke mismatch")))
  (unless
    (compiler-load-dotted-module-path-cache-ok?)
    (return (io.panic "compiler-load: dotted path cache smoke mismatch")))
  (unless
    (compiler-load-package-owner-paths-ok?)
    (return (io.panic "compiler-load: package owner path smoke mismatch")))
  (unless
    (compiler-load-package-owner-extern-symbol-ok?)
    (return
      (io.panic "compiler-load: package owner extern symbol smoke mismatch")))
  (unless
    (compiler-load-package-extern-typelisp-abi-ok?)
    (return
      (io.panic "compiler-load: package extern does not carry the TypeLisp ABI")))
  (unless
    (compiler-load-package-source-macro-preserved-ok?)
    (return (io.panic "compiler-load: package source macro was not preserved")))
  (unless
    (compiler-load-package-imported-spmd-metadata-ok?)
    (return
      (io.panic "compiler-load: package imported SPMD metadata smoke mismatch")))
  (unless
    (compiler-load-source-provenance-ok?)
    (return (io.panic "compiler-load: source provenance smoke mismatch")))
  (unless
    (compiler-load-entry-moduled-main-ok?)
    (return (io.panic "compiler-load: entry moduled main smoke mismatch")))
  (unless
    (compiler-load-expected-module-conflict-ok?)
    (return (io.panic "compiler-load: expected module smoke mismatch")))
  (unless
    (compiler-load-duplicate-module-ok?)
    (return (io.panic "compiler-load: duplicate module smoke mismatch")))
  (unless
    (compiler-load-nested-module-body-ok?)
    (return (io.panic "compiler-load: nested module body smoke mismatch")))
  (unless
    (compiler-load-nested-module-duplicate-ok?)
    (return (io.panic "compiler-load: nested module duplicate smoke mismatch")))
  (unless
    (compiler-load-seen-module-ok?)
    (return (io.panic "compiler-load: seen module smoke mismatch")))
  (unless
    (compiler-load-cfg-import-ok?)
    (return (io.panic "compiler-load: cfg import smoke mismatch")))
  (unless
    (compiler-load-surface-summary-smoke-ok?)
    (return (io.panic "compiler-load: surface summary smoke mismatch")))
  (unless
    (compiler-load-session-cache-common-dep-ok?)
    (return (io.panic "compiler-load: session cache common dep smoke mismatch")))
  (unless
    (compiler-load-session-cache-root-isolation-ok?)
    (return
      (io.panic "compiler-load: session cache root isolation smoke mismatch")))
  (unless
    (compiler-load-session-cache-entry-cold-ok?)
    (return (io.panic "compiler-load: session cache entry cold smoke mismatch")))
  (unless
    (compiler-load-session-persistent-floor-interns-ok?)
    (return
      (io.panic
        "compiler-load: session cache intern floor kept scratch storage")))
  (unless
    (compiler-load-session-cache-local-common-dep-ok?)
    (return
      (io.panic "compiler-load: session cache local common dep smoke mismatch")))
  (unless
    (compiler-load-session-cache-package-common-dep-ok?)
    (return
      (io.panic
        "compiler-load: session cache package common dep smoke mismatch")))
  (unless
    (compiler-load-file-import-dedup-cycle-ok?)
    (return (io.panic "compiler-load: import dedup/cycle smoke mismatch")))
  (unless
    (compiler-load-import-module-restore-ok?)
    (return (io.panic "compiler-load: import module restore smoke mismatch")))
  (unless
    (compiler-load-import-alias-preserved-ok?)
    (return
      (io.panic "compiler-load: import alias preservation smoke mismatch")))
  (unless
    (compiler-load-dotted-import-duplicate-alias-ok?)
    (return
      (io.panic "compiler-load: dotted import duplicate alias smoke mismatch")))
  (unless
    (compiler-load-dotted-import-same-alias-same-module-ok?)
    (return
      (io.panic "compiler-load: dotted import same-module alias smoke mismatch")))
  (unless
    (compiler-load-dotted-import-resolution-ok?)
    (return (io.panic "compiler-load: dotted import resolution smoke mismatch")))
  (unless
    (compiler-load-import-suffix-resolution-ok?)
    (return (io.panic "compiler-load: import suffix resolution smoke mismatch")))
  (unless
    (compiler-load-import-local-collision-ok?)
    (return (io.panic "compiler-load: import/local collision smoke mismatch")))
  (unless
    (compiler-load-dotted-source-root-ok?)
    (return (io.panic "compiler-load: dotted source root smoke mismatch")))
  (unless
    (compiler-load-moduleless-dotted-source-root-ok?)
    (return
      (io.panic "compiler-load: moduleless dotted source root smoke mismatch")))
  (unless
    (compiler-load-stdlib-source-module-import-ok?)
    (return
      (io.panic "compiler-load: stdlib source module import smoke mismatch")))
  (unless
    (compiler-load-dotted-source-root-fallback-ok?)
    (return
      (io.panic "compiler-load: dotted source root fallback smoke mismatch")))
  (unless
    (compiler-load-dotted-transitive-import-ok?)
    (return (io.panic "compiler-load: dotted transitive import smoke mismatch")))
  (unless
    (compiler-load-canonical-source-explicit-mismatch-ok?)
    (return
      (io.panic "compiler-load: canonical source mismatch smoke mismatch")))
  (unless
    (compiler-load-package-dotted-import-resolution-ok?)
    (return
      (io.panic
        "compiler-load: package dotted import resolution smoke mismatch")))
  (unless
    (compiler-load-package-dotted-sibling-source-ok?)
    (return
      (io.panic "compiler-load: package dotted sibling source smoke mismatch")))
  (unless
    (compiler-load-package-second-root-source-ok?)
    (return
      (io.panic "compiler-load: package second root source smoke mismatch")))
  (unless
    (compiler-load-package-moduleless-pkg-import-id-ok?)
    (return
      (io.panic "compiler-load: package moduleless pkg import smoke mismatch")))
  (unless
    (compiler-load-package-dotted-explicit-module-id-ok?)
    (return
      (io.panic "compiler-load: package dotted explicit module smoke mismatch")))
  (unless
    (compiler-load-generated-meta-preserved-ok?)
    (return
      (io.panic "compiler-load: generated metadata preservation smoke mismatch")))
  (unless
    (compiler-load-diamond-import-ok?)
    (return (io.panic "compiler-load: diamond import smoke mismatch")))
  (unless
    (compiler-load-transitive-import-ok?)
    (return (io.panic "compiler-load: transitive import smoke mismatch")))
  (unless
    (compiler-load-missing-import-ok?)
    (return (io.panic "compiler-load: missing import smoke mismatch")))
  (unless
    (compiler-load-include-str-relative-ok?)
    (return (io.panic "compiler-load: include-str relative smoke mismatch")))
  (unless
    (compiler-load-include-str-stdlib-root-ok?)
    (return (io.panic "compiler-load: include-str stdlib root smoke mismatch")))
  (unless
    (compiler-load-include-str-comptime-relative-ok?)
    (return
      (io.panic "compiler-load: include-str-comptime relative smoke mismatch")))
  (unless
    (compiler-load-include-str-lzss-relative-ok?)
    (return
      (io.panic "compiler-load: include-str-lzss relative smoke mismatch")))
  (unless
    (compiler-load-include-str-lzss-source-ok?)
    (return
      (io.panic
        "compiler-load: include-str-lzss source blanking smoke mismatch")))
  (unless
    (compiler-load-strip-inline-tests-ok?)
    (return (io.panic "compiler-load: inline-test blanking smoke mismatch")))
  (unless
    (compiler-load-trim-prose-comments-ok?)
    (return (io.panic "compiler-load: prose-comment trimming smoke mismatch")))
  (unless
    (compiler-load-missing-include-str-ok?)
    (return (io.panic "compiler-load: missing include-str smoke mismatch")))
  (unless
    (compiler-load-include-str-raw-text-ok?)
    (return (io.panic "compiler-load: include-str raw text smoke mismatch")))
  (unless
    (compiler-load-include-bin-relative-ok?)
    (return (io.panic "compiler-load: include-bin relative smoke mismatch")))
  (unless
    (compiler-load-missing-include-bin-ok?)
    (return (io.panic "compiler-load: missing include-bin smoke mismatch")))
  (unless
    (compiler-load-embedded-stdlib-lookup-ok?)
    (return (io.panic "compiler-load: embedded stdlib lookup smoke mismatch")))
  (unless
    (compiler-load-embedded-stdlib-missing-ok?)
    (return (io.panic "compiler-load: embedded stdlib missing smoke mismatch")))
  (unless
    (compiler-load-embedded-stdlib-escape-rejected-ok?)
    (return (io.panic "compiler-load: embedded stdlib escape smoke mismatch")))
  (unless
    (compiler-load-imported-parse-error-path-ok?)
    (return
      (io.panic "compiler-load: imported parse error path smoke mismatch")))
  (unless
    (compiler-load-imported-duplicate-module-path-ok?)
    (return
      (io.panic "compiler-load: imported duplicate module path smoke mismatch")))
  (unless
    (compiler-load-stdlib-root-fallback-ok?)
    (return (io.panic "compiler-load: stdlib root fallback smoke mismatch")))
  (unless
    (compiler-load-prelude-source-precedence-ok?)
    (return
      (io.panic "compiler-load: prelude source precedence smoke mismatch")))
  (unless
    (compiler-load-stdlib-searched-root-ok?)
    (return (io.panic "compiler-load: stdlib searched root smoke mismatch")))
  (unless
    (compiler-load-stdlib-unresolved-ok?)
    (return (io.panic "compiler-load: stdlib unresolved smoke mismatch")))
  (unless
    (compiler-load-pkg-manifest-ok?)
    (return (io.panic "compiler-load: pkg manifest smoke mismatch")))
  (unless
    (compiler-load-manifest-path-inference-ok?)
    (return (io.panic "compiler-load: manifest path inference smoke mismatch")))
  (unless
    (compiler-load-pkg-resolve-ok?)
    (return (io.panic "compiler-load: pkg resolve smoke mismatch")))
  (unless
    (compiler-load-pkg-parent-dir-ok?)
    (return (io.panic "compiler-load: pkg parent-dir smoke mismatch")))
  (unless
    (compiler-load-string-vec-roots-ok?)
    (return (io.panic "compiler-load: string vec roots smoke mismatch")))
  (unless
    (compiler-load-pkg-dep-list-ok?)
    (return (io.panic "compiler-load: pkg-dep-list smoke mismatch")))
  42)

(define (compiler-load-session-state-cache-set-enabled!
  [state : load.CompilerLoadSessionState]
  [enabled : bool]) : unit
  (load.compiler-load-session-state-bool-cell-set! state.cache-enabled enabled))

(define (compiler-load-session-state-cache-enable!
  [state : (& state load.CompilerLoadSessionState)]) : unit
  (let
    [state : load.CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view state)]
    (compiler-load-session-state-cache-set-enabled! state true)))

(define (compiler-load-lazy-import-skip-count) : i64
  (let
    [bound-5 (load.compiler-load-active-session-state-shared-view)]
    (load.compiler-load-session-state-lazy-import-skip-count bound-5)))

(define (compiler-load-file-with-paths
  [path : String]
  [seen : sym_i64_env.SymI64Env]) : load.ResultCompilerLoadWithPaths
  (load.compiler-load-file-with-paths-and-roots path seen (svec.new)))

(define (compiler-load-session-state-embedded-stdlib-module-id?
  [state : (& state load.CompilerLoadSessionState)]
  [module : String]) : bool
  (let
    [state : load.CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view state)]
    [ids : sym_i64_env.SymI64Env
      (load.compiler-load-session-state-embedded-module-ids-shared-view
        (owned_view.compiler-owned-shared-view state))]
    (if (array-ref state.intern-state-ready 0)
      (match (ci.intern-compat-state-lookup
        (& (array-ref state.intern-state 0))
        (& module))
        [(InternLookupFound id) (sym_i64_env.sym-i64-contains-id ids id)]
        [(InternLookupMissing) false])
      (match (ci.intern-lookup-content module)
        [(InternLookupFound id) (sym_i64_env.sym-i64-contains-id ids id)]
        [(InternLookupMissing) false]))))