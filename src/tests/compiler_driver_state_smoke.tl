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
(import stdlib.io)

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
          (tc_core.tc-body-state-isolation-self-test))
          0
          (begin
            (io.print-string "driver state isolation smoke failed\n")
            1))))))