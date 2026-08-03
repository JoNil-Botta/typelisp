;; compiler_driver_state_smoke.tl - Driver/load session state isolation smoke.
;;
;; A load session wired to a non-installed intern state must do its intern
;; floor bookkeeping through that state's own cells: the globally installed
;; table's arena floor and pool counters stay untouched. The same session
;; wired to the installed state reads the live compatibility count, matching
;; the legacy global path exactly. The typecheck body-state case interleaves
;; independent fact/early-exit jobs and reuses one after a controlled failure
;; (refs #4705, #4884).
(import compiler_driver_smoke_tests)
(import compiler_load as load)
(import compiler_ast_types as ast)
(import compiler_typecheck_core as tc_core)
(import compiler_intern as ci)
(import compiler_specialize as spec)
(import compiler_parse_core as parser)
(import compiler_diagnostic as cdiag)
(import stdlib.io)
(import stdlib.string)

(define (driver-state-smoke-global-floor-mark) : i64
  ci.intern-persistent-arena-floor-mark)

(define (driver-state-smoke-non-installed-ok?
  [a : ci.InternCompatState]
  [b : ci.InternCompatState]) : bool
  (let
    [session-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    (begin
      (ci.intern "driver-state-a/name.one")
      (ci.intern-persistent-arena-floor-refresh!)
      (let
        [mark-a : i64 (driver-state-smoke-global-floor-mark)]
        (begin
          ;; Grow the installed table without refreshing: a global-path floor
          ;; refresh for session B would move the global mark past mark-a.
          (ci.intern "driver-state-a/name.one.five")
          (load.compiler-load-session-state-use-with-intern-state! session-b b)
          ;; B's table ends at 3 entries, the installed one at 2, so a
          ;; global-path floor for session B would read 2, not 3.
          (ci.intern-compat-state-intern b "driver-state-b/name.two")
          (ci.intern-compat-state-intern b "driver-state-b/name.two.five")
          (ci.intern-compat-state-intern b "driver-state-b/name.two.nine")
          (load.compiler-load-session-state-note-persistent-interns! session-b)
          (and
            (= (driver-state-smoke-global-floor-mark) mark-a)
            (= (ci.intern-compat-state-table-id a) (ci.intern-active-table-id))
            (= (ci.intern-compat-state-pool-len b) 9)
            (=
              (load.compiler-load-session-state-intern-floor-value session-b)
              (ci.intern-compat-state-pool-len b))
            (> (ci.intern-compat-state-persistent-arena-floor-mark b) 0)))))))

(define (driver-state-smoke-installed-ok? [a : ci.InternCompatState]) : bool
  (let
    [session-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    (begin
      (load.compiler-load-session-state-use-with-intern-state! session-a a)
      (ci.intern "driver-state-a/name.three")
      (load.compiler-load-session-state-note-persistent-interns! session-a)
      (=
        (load.compiler-load-session-state-intern-floor-value session-a)
        (ci.intern-pool-len)))))

(define (driver-state-smoke-expr-token-ok?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [installed-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 1)]
    [wanted-id : i64 (ci.intern "driver-state/wanted")]
    [other-id : i64 (ci.intern "driver-state/other")]
    [source-leaf : i64
      (ast.ast-node-pool-context-expr-push
        source-pools
        (ast.AstExpr.Var wanted-id))]
    [source-root : ast.AstExpr
      (ast.AstExpr.Unary (ast.AstUnOp.Not) source-leaf)]
    [_installed-leaf : i64
      (ast.ast-node-pool-context-expr-push
        installed-pools
        (ast.AstExpr.Var other-id))]
    (begin
      (ast.ast-node-pool-context-install! installed-pools)
      (let
        [installed-bases : i64
          (ast.ast-node-pool-context-expr-segment-bases installed-pools)]
        [found : bool
          (tc_core.tc-expr-uses-free-name?
            (ast.ast-node-pool-context-expr-segment-bases source-pools)
            source-root
            "driver-state/wanted"
            tc_core.TcStringList.Nil)]
        [installed-unchanged : bool
          (= (ast.ast-node-pool-active-expr-segment-bases) installed-bases)]
        (begin
          (ast.ast-node-pool-context-install! active-before)
          (and found installed-unchanged))))))

(define (driver-state-smoke-type-elision-token-ok?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 4)]
    [installed-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 1 4)]
    [source-leaf-id : i64
      (ast.ast-node-pool-context-type-push source-pools (ast.AstType.I64))]
    [installed-leaf-id : i64
      (ast.ast-node-pool-context-type-push installed-pools (ast.AstType.Bytes))]
    [nested-lifetime : i64 (ci.intern "driver-state/source-lifetime")]
    [source-nested-id : i64
      (ast.ast-node-pool-context-type-push
        source-pools
        (ast.AstType.Ref nested-lifetime source-leaf-id))]
    [installed-nested-id : i64
      (ast.ast-node-pool-context-type-push installed-pools (ast.AstType.Bool))]
    (begin
      (ast.ast-node-pool-context-install! installed-pools)
      (let
        [installed-bases : i64
          (ast.ast-node-pool-context-type-segment-bases installed-pools)]
        ;; The nested walk must see source-pools' Ref at id 1, not the
        ;; installed pool's Bool at the same numeric id.
        [source-elision-answer : bool
          (match (tc_core.tc-signature-input-lifetimes-into
            (ast.ast-node-pool-context-type-segment-bases source-pools)
            (ast.AstType.Array source-nested-id 1)
            tc_core.TcNameIdList.Nil)
            [(tc_core.TcNameIdList.Cons lifetime rest)
              (and
                (= lifetime nested-lifetime)
                (match (box-get rest)
                  [(tc_core.TcNameIdList.Nil) true]
                  [_ false]))]
            [_ false])]
        [installed-unchanged : bool
          (=
            (ast.ast-node-pool-context-type-segment-bases
              (ast.ast-node-pool-context-capture-active))
            installed-bases)]
        (begin
          (ast.ast-node-pool-context-install! active-before)
          (and
            (= source-leaf-id installed-leaf-id)
            (= source-nested-id installed-nested-id)
            source-elision-answer
            installed-unchanged))))))

;; Exercise the explicit specialization owner while a deliberately conflicting
;; pool/interner is installed as the ambient compatibility context.  The source
;; program and all ids belong to state A; state B reuses the same first id for a
;; different spelling and owns a separate reader pool.  Both the successful
;; generated-declaration path and the incompatible-generated-declaration
;; diagnostic path must match the serial compatibility baseline, while B's
;; nodes, lengths, active reader bases, and interner counters remain untouched.
(define (driver-state-specialize-parse-program [incompatible? : bool]) : parser.ResultAstProgram
  (if incompatible?
    (spec.compiler-generated-decl-incompatible-program)
    (spec.compiler-generated-decl-reuse-program)))

(define (driver-state-specialize-result-ok?
  [result : spec.ResultSpecProgramWithPaths]) : bool
  (match result
    [(spec.ResultSpecProgramWithPaths.Ok _ _) true]
    [(spec.ResultSpecProgramWithPaths.Err _) false]))

(define (driver-state-specialize-result-decl-count
  [result : spec.ResultSpecProgramWithPaths]) : i64
  (match result
    [(spec.ResultSpecProgramWithPaths.Ok program _)
      (match program
        [(ast.AstProgram.Program decls-box)
          (ast.ast-decl-list-len (& (box-get decls-box)))])]
    [(spec.ResultSpecProgramWithPaths.Err _) -1]))

(define (driver-state-specialize-result-diagnostic
  [result : spec.ResultSpecProgramWithPaths]) : String
  (match result
    [(spec.ResultSpecProgramWithPaths.Ok _ _) ""]
    [(spec.ResultSpecProgramWithPaths.Err diag)
      (cdiag.compiler-diagnostic-message (box-get diag))]))

(define (driver-state-specialize-ab-case-ok? [incompatible? : bool]) : bool
  (let
    [home-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [home-intern : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [serial-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 64 32)]
    [owned-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 64 32)]
    [decoy-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
    [ok : bool false]
    (begin
      ;; Force the same numeric source id in A and B, but with different text.
      (let
        [a-seed : i64 (ci.intern-compat-state-intern state-a "source/seed")]
        [b-seed : i64 (ci.intern-compat-state-intern state-b "decoy/seed")]
        [b-generated : i64
          (ci.intern-compat-state-generated-name state-b "decoy/generated")]
        [b-structural-left : i64
          (ci.intern-compat-state-intern state-b "decoy/structural-left")]
        [b-structural-right : i64
          (ci.intern-compat-state-intern state-b "decoy/structural-right")]
        [b-structural-id : i64
          (ci.intern-compat-state-composite-pair-id
            state-b
            b-structural-left
            b-structural-right)]
        [b-structural-rendered : String
          (ci.intern-compat-state-composite-rendered-name-record!
            state-b
            b-structural-id
            "decoy/structural-sentinel")]
        (begin
          (ci.intern-compat-state-install! state-a)
          (ast.ast-node-pool-context-install! serial-pools)
          (match (driver-state-specialize-parse-program incompatible?)
            [(parser.ResultAstProgram.Ok serial-program)
              (let
                [serial-result : spec.ResultSpecProgramWithPaths
                  (spec.compiler-specialize-program-with-paths-and-pools
                    serial-program
                    paths
                    "specialize-smoke.tl"
                    serial-pools)]
                (begin
                  (ast.ast-node-pool-context-install! owned-pools)
                  (match (driver-state-specialize-parse-program incompatible?)
                    [(parser.ResultAstProgram.Ok owned-program)
                      (let
                        [decoy-source-id : i64
                          (ci.intern-compat-state-intern state-b "decoy/active")]
                        [decoy-expr-id : i64
                          (ast.ast-node-pool-context-expr-push
                            decoy-pools
                            (ast.AstExpr.Var decoy-source-id))]
                        [decoy-type-id : i64
                          (ast.ast-node-pool-context-type-push
                            decoy-pools
                            (ast.AstType.I64))]
                        (begin
                          (ci.intern-compat-state-install! state-b)
                          (ast.ast-node-pool-context-install! decoy-pools)
                          (let
                            [before-expr-len : i64
                              (ast.ast-node-pool-context-expr-len decoy-pools)]
                            [before-type-len : i64
                              (ast.ast-node-pool-context-type-len decoy-pools)]
                            [before-expr-bases : i64
                              (ast.ast-node-pool-active-expr-segment-bases)]
                            [before-type-bases : i64
                              (ast.ast-node-pool-reader-type-segment-bases)]
                            [before-intern-table : i64
                              (ci.intern-active-table-id)]
                            [before-intern-generation : i64
                              (ci.intern-generation)]
                            [before-intern-len : i64 (ci.intern-pool-len)]
                            [before-generated-count : i64
                              (ci.intern-generated-count)]
                            [before-decoy-len : i64
                              (ci.intern-compat-state-pool-len state-b)]
                            [before-decoy-generated : i64
                              (ci.intern-compat-state-generated-count state-b)]
                            [before-decoy-structural-count : i64
                              (ci.intern-compat-state-structural-count state-b)]
                            [before-decoy-structural-id : i64
                              (ci.intern-compat-state-composite-pair-id
                                state-b
                                b-structural-left
                                b-structural-right)]
                            [before-decoy-structural-rendered : String
                              (ci.intern-compat-state-composite-rendered-name
                                state-b
                                b-structural-id)]
                            [before-decoy-source-text : String
                              (ci.intern-compat-state-str
                                state-b
                                decoy-source-id)]
                            [before-decoy-generated-text : String
                              (ci.intern-compat-state-str state-b b-generated)]
                            [baseline-ok : bool
                              (driver-state-specialize-result-ok? serial-result)]
                            [baseline-count : i64
                              (driver-state-specialize-result-decl-count
                                serial-result)]
                            [baseline-diagnostic : String
                              (driver-state-specialize-result-diagnostic
                                serial-result)]
                            [owned-result : spec.ResultSpecProgramWithPaths
                              (spec.compiler-specialize-program-with-paths-and-pools-and-intern-state
                                owned-program
                                paths
                                "specialize-smoke.tl"
                                owned-pools
                                state-a)]
                            [after-expr-len : i64
                              (ast.ast-node-pool-context-expr-len decoy-pools)]
                            [after-type-len : i64
                              (ast.ast-node-pool-context-type-len decoy-pools)]
                            [after-expr-bases : i64
                              (ast.ast-node-pool-active-expr-segment-bases)]
                            [after-type-bases : i64
                              (ast.ast-node-pool-reader-type-segment-bases)]
                            [after-intern-table : i64
                              (ci.intern-active-table-id)]
                            [after-intern-generation : i64
                              (ci.intern-generation)]
                            [after-intern-len : i64 (ci.intern-pool-len)]
                            [after-generated-count : i64
                              (ci.intern-generated-count)]
                            [after-decoy-len : i64
                              (ci.intern-compat-state-pool-len state-b)]
                            [after-decoy-generated : i64
                              (ci.intern-compat-state-generated-count state-b)]
                            [after-decoy-structural-count : i64
                              (ci.intern-compat-state-structural-count state-b)]
                            [after-decoy-structural-id : i64
                              (ci.intern-compat-state-composite-pair-id
                                state-b
                                b-structural-left
                                b-structural-right)]
                            [after-decoy-structural-rendered : String
                              (ci.intern-compat-state-composite-rendered-name
                                state-b
                                b-structural-id)]
                            [after-decoy-source-text : String
                              (ci.intern-compat-state-str
                                state-b
                                decoy-source-id)]
                            [after-decoy-generated-text : String
                              (ci.intern-compat-state-str state-b b-generated)]
                            [owned-ok : bool
                              (driver-state-specialize-result-ok? owned-result)]
                            [owned-count : i64
                              (driver-state-specialize-result-decl-count
                                owned-result)]
                            [owned-diagnostic : String
                              (driver-state-specialize-result-diagnostic
                                owned-result)]
                            [decoy-node-ok : bool
                              (and
                                (match (ast.ast-node-pool-context-expr-get
                                  decoy-pools
                                  decoy-expr-id)
                                  [(ast.AstExpr.Var id) (= id decoy-source-id)]
                                  [_ false])
                                (match (ast.ast-node-pool-context-type-get
                                  decoy-pools
                                  decoy-type-id)
                                  [(ast.AstType.I64) true]
                                  [_ false]))]
                            (set!
                              ok
                              (and
                                (= a-seed b-seed)
                                (= baseline-ok owned-ok)
                                (= baseline-count owned-count)
                                (string.eq baseline-diagnostic owned-diagnostic)
                                (= before-expr-len after-expr-len)
                                (= before-type-len after-type-len)
                                (= before-expr-bases after-expr-bases)
                                (= before-type-bases after-type-bases)
                                (= before-intern-table after-intern-table)
                                (=
                                  before-intern-generation
                                  after-intern-generation)
                                (= before-intern-len after-intern-len)
                                (= before-generated-count after-generated-count)
                                (= before-decoy-len after-decoy-len)
                                (= before-decoy-generated after-decoy-generated)
                                (=
                                  before-decoy-structural-count
                                  after-decoy-structural-count)
                                (= b-structural-id after-decoy-structural-id)
                                (string.eq
                                  before-decoy-structural-rendered
                                  after-decoy-structural-rendered)
                                (string.eq
                                  b-structural-rendered
                                  after-decoy-structural-rendered)
                                (string.eq
                                  before-decoy-source-text
                                  after-decoy-source-text)
                                (string.eq
                                  before-decoy-generated-text
                                  after-decoy-generated-text)
                                decoy-node-ok)))))]
                    [_ (set! ok false)])))]
            [(parser.ResultAstProgram.Err _) (set! ok false)])))
      ;; Restore both compatibility contexts on every normal exit.
      (ast.ast-node-pool-context-install! home-pools)
      (ci.intern-compat-state-install! home-intern)
      ok)))

(define (main) : i64
  (if (not
    (=
      (compiler_driver_smoke_tests.compiler-driver-reader-context-smoke-main)
      42))
    (begin
      (io.print-string "driver state reader-context isolation smoke failed\n")
      1)
    (let
      [a : ci.InternCompatState (ci.intern-compat-state-new)]
      [b : ci.InternCompatState (ci.intern-compat-state-new)]
      (begin
        (ci.intern-compat-state-install! a)
        (if (and
          (driver-state-smoke-non-installed-ok? a b)
          (driver-state-smoke-installed-ok? a)
          (driver-state-smoke-expr-token-ok?)
          (driver-state-smoke-type-elision-token-ok?)
          (tc_core.tc-body-state-isolation-self-test)
          (driver-state-specialize-ab-case-ok? false)
          (driver-state-specialize-ab-case-ok? true))
          0
          (begin
            (io.print-string "driver state isolation smoke failed\n")
            1))))))