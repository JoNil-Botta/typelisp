;; compiler_driver_state_smoke.tl - Driver/load session state isolation smoke.
;;
;; A load session wired to a non-installed intern state must do its intern
;; floor bookkeeping through that state's own cells: the globally installed
;; table's arena floor and pool counters stay untouched. The same session
;; wired to the installed state reads the live compatibility count, matching
;; the legacy global path exactly. The typecheck body-state case interleaves
;; independent fact/early-exit jobs and reuses one after a controlled failure
;; (refs #4705, #4884).
(import "../compiler_driver_smoke_tests.tl")
(import "../compiler_typecheck.tl")
(import "../compiler_intern.tl" as ci)
(import stdlib.io)

(define (driver-state-smoke-global-floor-mark) : i64
  intern-persistent-arena-floor-mark)

(define (driver-state-smoke-non-installed-ok?
  [a : ci.InternCompatState]
  [b : ci.InternCompatState]) : bool
  (let
    [session-b : CompilerLoadSessionState (compiler-load-session-state-new)]
    (begin
      (ci.intern "driver-state-a/name.one")
      (intern-persistent-arena-floor-refresh!)
      (let
        [mark-a : i64 (driver-state-smoke-global-floor-mark)]
        (begin
          ;; Grow the installed table without refreshing: a global-path floor
          ;; refresh for session B would move the global mark past mark-a.
          (ci.intern "driver-state-a/name.one.five")
          (compiler-load-session-state-use-with-intern-state! session-b b)
          ;; B's table ends at 3 entries, the installed one at 2, so a
          ;; global-path floor for session B would read 2, not 3.
          (ci.intern-compat-state-intern b "driver-state-b/name.two")
          (ci.intern-compat-state-intern b "driver-state-b/name.two.five")
          (ci.intern-compat-state-intern b "driver-state-b/name.two.nine")
          (compiler-load-session-state-note-persistent-interns! session-b)
          (and
            (= (driver-state-smoke-global-floor-mark) mark-a)
            (= (ci.intern-compat-state-table-id a) (intern-active-table-id))
            (= (ci.intern-compat-state-pool-len b) 9)
            (=
              (compiler-load-session-state-intern-floor-value session-b)
              (ci.intern-compat-state-pool-len b))
            (> (ci.intern-compat-state-persistent-arena-floor-mark b) 0)))))))

(define (driver-state-smoke-installed-ok? [a : ci.InternCompatState]) : bool
  (let
    [session-a : CompilerLoadSessionState (compiler-load-session-state-new)]
    (begin
      (compiler-load-session-state-use-with-intern-state! session-a a)
      (ci.intern "driver-state-a/name.three")
      (compiler-load-session-state-note-persistent-interns! session-a)
      (=
        (compiler-load-session-state-intern-floor-value session-a)
        (intern-pool-len)))))

(define (driver-state-smoke-expr-token-ok?) : bool
  (let
    [active-before : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [source-pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities 4 1)]
    [installed-pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities 4 1)]
    [wanted-id : i64 (ci.intern "driver-state/wanted")]
    [other-id : i64 (ci.intern "driver-state/other")]
    [source-leaf : i64
      (ast-node-pool-context-expr-push source-pools (AstExpr.Var wanted-id))]
    [source-root : AstExpr (AstExpr.Unary (AstUnOp.Not) source-leaf)]
    [_installed-leaf : i64
      (ast-node-pool-context-expr-push installed-pools (AstExpr.Var other-id))]
    (begin
      (ast-node-pool-context-install! installed-pools)
      (let
        [installed-bases : i64
          (ast-node-pool-context-expr-segment-bases installed-pools)]
        [found : bool
          (tc-expr-uses-free-name?
            (ast-node-pool-context-expr-segment-bases source-pools)
            source-root
            "driver-state/wanted"
            TcStringList.Nil)]
        [installed-unchanged : bool
          (= (ast-node-pool-active-expr-segment-bases) installed-bases)]
        (begin
          (ast-node-pool-context-install! active-before)
          (and found installed-unchanged))))))

(define (main) : i64
  (if (not (= (compiler-driver-reader-context-smoke-main) 42))
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
          (tc-body-state-isolation-self-test))
          0
          (begin
            (io.print-string "driver state isolation smoke failed\n")
            1))))))