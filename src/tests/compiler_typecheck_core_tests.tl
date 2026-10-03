;; compiler_typecheck_core_tests.tl - White-box tests for the typechecker core:
;; state isolation between jobs, environment and cache smokes, and inline tests.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.hashmap)
(import compiler_symbols as csym)
(import compiler_load as cload)
(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_diagnostic as cdiag)
(import compiler_ctfe as ctfe_support)
(import compiler_specialize as spec)
(import compiler_clone as clone_support)
(import (hashmap.hashmap i64 i64) as tc_i64_i64_map)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import token)
(cfg test (import stdlib.test))
(cfg test (import stdlib.profile))
(import sym_i64_env)
(import compiler_typecheck_core as tc_core)
(import compiler_parse_core as parser)
(import read as reader)
(import lex as lexer)
(import compiler_owned_view as owned_view)

;; Layout queries need the struct names unqualified. Lint does not count a use
;; inside `(type ...)`.
;; lint-allow: unused-import
(import compiler_typecheck_core.TcTypeEnvBinding)

;; lint-allow: unused-import
(import compiler_typecheck_core.TcTypeEnvCache)

;; lint-allow: unused-import
(import compiler_typecheck_core.TcTypeEnvStore)

;; Copies of core's walk-state field macros: a type named in a macro template
;; resolves where the macro expands, so core's own copies work only inside core.
(defmacro (tc-macro-walk-field [state : Expr] [field : Expr]) : Expr
  `(let
    [data : tc_core.TcMacroWalkStateData
      (tc_core.tc-macro-walk-state-data ,state)]
    (tc_core.tc-global-shared-view (__tl-project-field data ,field))))

(defmacro (tc-macro-walk-set! [state : Expr] [field : Expr] [value : Expr]) : Expr
  `(let
    [data : tc_core.TcMacroWalkStateData
      (tc_core.tc-macro-walk-state-data ,state)]
    (__tl-project-set-field data ,field ,value)
    (tc_core.tc-macro-walk-state-data-set! ,state data)))

(defenum TcTypeHandleCacheLookup
  (Miss)
  (Hit i64))

(defenum TcTypeEnvLookupStep
  (Missing)
  (Miss tc_core.TcTypeEnv)
  (Found ast.AstType))

(defenum TcTypeEnvUnsafeLookupStep
  (Missing)
  (Miss tc_core.TcTypeEnv)
  (Found ast.AstType bool))

(defenum TcTypeEnvScopedMarkerLookup
  (Missing)
  (Found i64 ast.AstType i64 i64))

(define (tc-checked-let-binding-fact-count
  [state : tc_core.TcCheckedLetBindingFactState]) : i64
  (__tl-project-field
    (tc_core.tc-checked-let-binding-fact-state-data state)
    len))

(define (tc-checked-let-binding-facts-self-test) : bool
  (let
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-c : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [a : tc_core.TcCheckedLetBindingFactState
      (tc_core.tc-job-state-checked-let-binding-facts job-a)]
    [b : tc_core.TcCheckedLetBindingFactState
      (tc_core.tc-job-state-checked-let-binding-facts job-b)]
    [c : tc_core.TcCheckedLetBindingFactState
      (tc_core.tc-job-state-checked-let-binding-facts job-c)]
    [ordinary : tc_core.TcCheckedLetBindingTransition
      (tc_core.TcCheckedLetBindingTransition 1 -1)]
    [special : tc_core.TcCheckedLetBindingTransition
      (tc_core.TcCheckedLetBindingTransition 2 91)]
    (tc_core.tc-checked-let-binding-facts-begin! a)
    (tc_core.tc-checked-let-binding-facts-begin! b)
    (tc_core.tc-checked-let-binding-facts-begin! c)
    (tc_core.tc-checked-let-binding-facts-set-current-declaration! a 7)
    ;; Reused init ids and same-spelled bindings remain distinct by enclosing
    ;; body and ordinal. Re-recording the same proof does not grow the store.
    (tc_core.tc-checked-let-binding-fact-record!
      (ast.ast-node-pool-reader-type-segment-bases)
      a
      11
      0
      13
      17
      (I64)
      ordinary)
    (tc_core.tc-checked-let-binding-fact-record!
      (ast.ast-node-pool-reader-type-segment-bases)
      a
      12
      0
      13
      17
      (Bool)
      special)
    (tc_core.tc-checked-let-binding-fact-record!
      (ast.ast-node-pool-reader-type-segment-bases)
      a
      11
      0
      13
      17
      (I64)
      ordinary)
    (tc_core.tc-checked-let-binding-facts-set-current-declaration! b 7)
    (tc_core.tc-checked-let-binding-fact-record!
      (ast.ast-node-pool-reader-type-segment-bases)
      b
      11
      0
      13
      17
      (I64)
      ordinary)
    ;; A conflicting contextual proof fails closed without altering job A.
    (tc_core.tc-checked-let-binding-fact-record!
      (ast.ast-node-pool-reader-type-segment-bases)
      b
      11
      0
      13
      17
      (Bool)
      ordinary)
    ;; Grow both retained containers while an unrelated scratch arena is
    ;; active, then destroy that scratch. Every fact and hashmap slot must
    ;; remain owned by the fact generation and storage stays one entry per
    ;; successful binding.
    (tc_core.tc-checked-let-binding-facts-set-current-declaration! c 19)
    (let
      [scratch : i64 (arena.tl_arena_make)]
      (in-arena
        (arena.Arena scratch)
        (let
          [index : i64 0]
          (while (< index 257)
            (tc_core.tc-checked-let-binding-fact-record!
              (ast.ast-node-pool-reader-type-segment-bases)
              c
              (+ 100 index)
              index
              (+ 200 index)
              (+ 300 index)
              (I64)
              ordinary)
            (set! index (+ index 1)))))
      (unsafe
        (arena.tl_arena_destroy scratch)))
    (let
      [initial : bool
        (and
          (= (tc-checked-let-binding-fact-count a) 2)
          (= (tc-checked-let-binding-fact-count b) 1)
          (match (tc_core.tc-checked-let-binding-fact-lookup a 7 11 0 13 17)
            [(Hit (I64) transition)
              (tc_core.tc-checked-let-binding-transition-eq?
                transition
                ordinary)]
            [_ false])
          (match (tc_core.tc-checked-let-binding-fact-lookup a 7 12 0 13 17)
            [(Hit (Bool) transition)
              (tc_core.tc-checked-let-binding-transition-eq? transition special)]
            [_ false])
          (match (tc_core.tc-checked-let-binding-fact-lookup a 8 11 0 13 17)
            [(Missing) true]
            [_ false])
          (match (tc_core.tc-checked-let-binding-fact-lookup b 7 11 0 13 17)
            [(Inconsistent) true]
            [_ false])
          (= (tc-checked-let-binding-fact-count c) 257)
          (match (tc_core.tc-checked-let-binding-fact-lookup
            c
            19
            356
            256
            456
            556)
            [(Hit (I64) transition)
              (tc_core.tc-checked-let-binding-transition-eq?
                transition
                ordinary)]
            [_ false]))]
      (tc_core.tc-checked-let-binding-facts-finish! a)
      (tc_core.tc-checked-let-binding-facts-finish! b)
      (tc_core.tc-checked-let-binding-facts-finish! c)
      (let
        [cleared : bool
          (and
            (= (tc-checked-let-binding-fact-count a) 0)
            (not (tc_core.tc-checked-let-binding-facts-enabled? a))
            (match (tc_core.tc-checked-let-binding-fact-lookup a 7 11 0 13 17)
              [(Missing) true]
              [_ false]))]
        ;; A second generation must not see the first generation's keys.
        (tc_core.tc-checked-let-binding-facts-begin! a)
        (tc_core.tc-checked-let-binding-facts-set-current-declaration! a 8)
        (tc_core.tc-checked-let-binding-fact-record!
          (ast.ast-node-pool-reader-type-segment-bases)
          a
          11
          0
          13
          17
          (Bool)
          ordinary)
        (let
          [reused : bool
            (and
              (match (tc_core.tc-checked-let-binding-fact-lookup a 7 11 0 13 17)
                [(Missing) true]
                [_ false])
              (match (tc_core.tc-checked-let-binding-fact-lookup a 8 11 0 13 17)
                [(Hit (Bool) _) true]
                [_ false]))]
          (tc_core.tc-checked-let-binding-facts-finish! a)
          (and initial cleared reused))))))

(cfg
  test
  (test
    tc-checked-let-binding-facts-identity-reset
    (unless
      (tc-checked-let-binding-facts-self-test)
      (io.panic "typecheck: checked let-binding fact identity/reset failed"))))

(define (tc-job-state-set-topenv-membership-enabled!
  [state : tc_core.TcJobState]
  [enabled : bool]) : unit
  (let
    [membership : tc_core.TcTopEnvMembershipState
      (tc_core.tc-job-state-topenv-membership state)]
    [data : tc_core.TcTopEnvMembershipStateData
      (tc_core.tc-topenv-membership-state-data membership)]
    (set! data.accelerator-enabled enabled)
    (tc_core.tc-topenv-membership-state-data-set! membership data)))

(define (tc-job-state-set-thread-name-kind-enabled!
  [state : tc_core.TcJobState]
  [enabled : bool]) : unit
  (let
    [thread-state : tc_core.TcThreadNameKindState
      (tc_core.tc-job-state-thread-name-kind state)]
    [data : tc_core.TcThreadNameKindStateData
      (tc_core.tc-thread-name-kind-state-data thread-state)]
    (set! data.accelerator-enabled enabled)
    (tc_core.tc-thread-name-kind-state-data-set! thread-state data)))

(define (tc-body-state-new-with-job-state [job-state : tc_core.TcJobState]) : tc_core.TcBodyState
  (tc_core.tc-body-state-new-with-job-state-and-source-names
    job-state
    (ci.intern-source-name-session-capture-active-handle)))

(define (tc-body-state-new) : tc_core.TcBodyState
  (tc-body-state-new-with-job-state (tc_core.tc-serial-job-state)))

(define (tc-body-state-storage-arena-value [state : tc_core.TcBodyState]) : i64
  (__tl-project-field
    (tc_core.tc-body-state-data-value state)
    type-fact-storage-arena))

(define (tc-body-state-type-fact-capacity [state : tc_core.TcBodyState]) : i64
  (array-length
    (__tl-project-field
      (tc_core.tc-body-state-data-value state)
      type-fact-types)))

(define (tc-body-state-early-exit-source-limit [state : tc_core.TcBodyState]) : i64
  (__tl-project-field
    (tc_core.tc-body-state-data-value state)
    early-exit-source-expr-limit))

(define (tc-body-early-exit-suppress-push! [state : tc_core.TcBodyState]) : unit
  (let
    [data : tc_core.TcBodyStateData (tc_core.tc-body-state-data-value state)]
    (when
      data.early-exit-facts-collecting
      (set! data.early-exit-suppress-depth (+ data.early-exit-suppress-depth 1))
      (tc_core.tc-body-state-data-set! state data))))

(define (tc-body-early-exit-suppress-pop! [state : tc_core.TcBodyState]) : unit
  (let
    [data : tc_core.TcBodyStateData (tc_core.tc-body-state-data-value state)]
    (when
      data.early-exit-facts-collecting
      (set! data.early-exit-suppress-depth (- data.early-exit-suppress-depth 1))
      (tc_core.tc-body-state-data-set! state data))))

(define (tc-body-state-type-fact-i64-hit?
  [state : tc_core.TcBodyState]
  [expr-id : i64]) : bool
  (match (tc_core.tc-body-type-fact-lookup state expr-id)
    [(Hit (I64)) true]
    [_ false]))

(define (tc-body-state-type-fact-bool-hit?
  [state : tc_core.TcBodyState]
  [expr-id : i64]) : bool
  (match (tc_core.tc-body-type-fact-lookup state expr-id)
    [(Hit (Bool)) true]
    [_ false]))

(define (tc-body-state-early-exit-known?
  [state : tc_core.TcBodyState]
  [body-id : i64]
  [expected : bool]) : bool
  (match (tc_core.tc-body-early-exit-fact state body-id)
    [(Known actual) (= actual expected)]
    [(Unknown) false]))

;; Exercise the state surface directly so the isolation invariant is covered
;; independently from the serial whole-compiler smoke. A and B deliberately
;; interleave record/consume modes and use disjoint source-id ranges. The reused
;; state takes a controlled error path with nested suppression before starting a
;; fresh body, matching the lifecycle used by the checked entrypoint.
(define (tc-body-state-isolation-self-test) : bool
  (let
    [a : tc_core.TcBodyState (tc-body-state-new)]
    [b : tc_core.TcBodyState (tc-body-state-new)]
    [reused : tc_core.TcBodyState (tc-body-state-new)]
    (tc_core.tc-body-early-exit-facts-start-with-limit! a 128)
    (tc_core.tc-body-early-exit-facts-start-with-limit! b 32)
    (tc_core.tc-body-early-exit-function-start! a)
    (tc_core.tc-body-type-facts-start-recording! a)
    (tc_core.tc-body-type-fact-record! a 70 (I64))
    (tc_core.tc-body-early-exit-function-start! b)
    (tc_core.tc-body-type-facts-start-recording! b)
    (tc_core.tc-body-type-fact-record! b 7 (Bool))
    (tc_core.tc-body-type-facts-start-consuming! a)
    (let
      [a-hit : bool (tc-body-state-type-fact-i64-hit? a 70)]
      [a-cross-miss : bool
        (match (tc_core.tc-body-type-fact-lookup a 7)
          [(Miss) true]
          [_ false])]
      (tc_core.tc-body-type-facts-start-consuming! b)
      (let
        [b-hit : bool (tc-body-state-type-fact-bool-hit? b 7)]
        [b-cross-miss : bool
          (match (tc_core.tc-body-type-fact-lookup b 70)
            [(Miss) true]
            [_ false])]
        (tc_core.tc-body-early-exit-note! a)
        (tc_core.tc-body-early-exit-function-finish! a 70)
        (tc-body-early-exit-suppress-push! b)
        (tc_core.tc-body-early-exit-note! b)
        (tc-body-early-exit-suppress-pop! b)
        (tc_core.tc-body-early-exit-function-finish! b 7)
        (tc_core.tc-body-type-facts-clear! a)
        (tc_core.tc-body-type-facts-clear! b)
        (tc_core.tc-body-early-exit-facts-finish! a)
        (tc_core.tc-body-early-exit-facts-finish! b)
        (tc_core.tc-body-early-exit-facts-start-with-limit! reused 64)
        (tc_core.tc-body-early-exit-function-start! reused)
        (tc_core.tc-body-type-facts-start-recording! reused)
        (tc_core.tc-body-type-fact-record! reused 31 (I64))
        (tc_core.tc-body-type-facts-start-consuming! reused)
        (match (tc_core.ResultTcUnit.Err "controlled body diagnostic")
          [(Ok) unit]
          [(Err _)
            (tc_core.tc-body-type-facts-clear! reused)
            (tc_core.tc-body-early-exit-facts-abort! reused)])
        (tc_core.tc-body-early-exit-facts-start-with-limit! reused 16)
        (tc_core.tc-body-early-exit-function-start! reused)
        (tc_core.tc-body-type-facts-start-recording! reused)
        (tc_core.tc-body-type-fact-record! reused 5 (Bool))
        (tc_core.tc-body-type-facts-start-consuming! reused)
        (let
          [reuse-hit : bool (tc-body-state-type-fact-bool-hit? reused 5)]
          (tc-body-early-exit-suppress-push! reused)
          (tc-body-early-exit-suppress-push! reused)
          (tc_core.tc-body-early-exit-note! reused)
          (tc-body-early-exit-suppress-pop! reused)
          (tc_core.tc-body-early-exit-note! reused)
          (tc-body-early-exit-suppress-pop! reused)
          (tc_core.tc-body-early-exit-note! reused)
          (tc_core.tc-body-early-exit-function-finish! reused 5)
          (tc_core.tc-body-type-facts-clear! reused)
          (tc_core.tc-body-early-exit-facts-finish! reused)
          (and
            a-hit
            a-cross-miss
            b-hit
            b-cross-miss
            reuse-hit
            (tc-body-state-early-exit-known? a 70 true)
            (tc-body-state-early-exit-known? b 7 false)
            (tc-body-state-early-exit-known? reused 5 true)
            (= (tc-body-state-storage-arena-value a) 0)
            (= (tc-body-state-storage-arena-value b) 0)
            (= (tc-body-state-storage-arena-value reused) 0)
            (= (tc-body-state-type-fact-capacity a) 1)
            (= (tc-body-state-type-fact-capacity b) 1)
            (= (tc-body-state-type-fact-capacity reused) 1)
            (= (tc-body-state-early-exit-source-limit a) 128)
            (= (tc-body-state-early-exit-source-limit b) 32)
            (= (tc-body-state-early-exit-source-limit reused) 16)))))))

(define (tc-agg-layout-cache-slot-empty-for-state?
  [state : tc_core.TcAggLayoutCacheState]
  [index : i64]) : bool
  (let
    [data : tc_core.TcAggLayoutCacheStateData
      (tc_core.tc-agg-layout-cache-state-data state)]
    [slots : (__tl_dyn-array tc_core.TcAggLayoutCacheSlot)
      data.agg-layout-cache]
    (if (or (< index 0) (>= index (array-length slots)))
      false
      (match (tc_core.tc-global-array-element-shared-view slots index)
        [(Empty) true]
        [(Full _ _) false]))))

(define (macro-prepare-test-ctx [pools : ast.AstNodePoolContext]) : tc_core.TcContext
  (tc_core.tc-context-new
    (ast.ast-program (ast.ast-decl-list-new))
    (csym.compiler-symbols-empty)
    (csym.compiler-registries-empty)
    ""
    cbi.compiler-builtin-id-fix-empty
    pools))

;; Preparing a transformer compares the owned pools with the installed pool's
;; lengths (#7937). An owned context that argument normalisation extended past
;; the installed one, in either pool, is installed; an owned context that is not
;; longer takes a capture of the installed state; under an explicit
;; compatibility context nothing changes.
(test
  macro-prepare-transformer-pools-length-decision
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [older : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [owned : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [ctx : tc_core.TcContext (macro-prepare-test-ctx owned)]
    [_older-root : i64 (ast.ast-node-pool-context-expr-push older (Var 1))]
    [_owned-root : i64 (ast.ast-node-pool-context-expr-push owned (Var 2))]
    [_owned-next : i64 (ast.ast-node-pool-context-expr-push owned (Var 3))]
    [_install-older : unit (ast.ast-node-pool-context-install! older)]
    [_prepare-longer : unit (tc_core.macro-prepare-transformer-pools! ctx)]
    [longer-installed? : bool (ast.ast-node-pool-context-expr-installed? owned)]
    [_older-grows : i64
      (begin
        (ast.ast-node-pool-context-expr-push older (Var 4))
        (ast.ast-node-pool-context-expr-push older (Var 5)))]
    [_reinstall-older : unit (ast.ast-node-pool-context-install! older)]
    [_prepare-shorter : unit (tc_core.macro-prepare-transformer-pools! ctx)]
    [shorter-captured? : bool
      (and
        (ast.ast-node-pool-context-expr-installed? older)
        (= (ast.ast-node-pool-context-expr-len owned) 3)
        (= (ast.ast-node-pool-len) 3))]
    [type-older : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [type-owned : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [type-ctx : tc_core.TcContext (macro-prepare-test-ctx type-owned)]
    [_type-owned-node : i64
      (ast.ast-node-pool-context-type-push type-owned (Array 0 7937))]
    [_install-type-older : unit (ast.ast-node-pool-context-install! type-older)]
    [_prepare-type : unit (tc_core.macro-prepare-transformer-pools! type-ctx)]
    [type-longer-installed? : bool
      (ast.ast-node-pool-context-expr-installed? type-owned)]
    [_install-compat-older : unit (ast.ast-node-pool-context-install! older)]
    [compat-unchanged? : bool
      (begin
        (ast.ast-node-pool-compat-context-use! type-older)
        (tc_core.macro-prepare-transformer-pools! type-ctx)
        (let
          [unchanged? : bool
            (not (ast.ast-node-pool-context-expr-installed? type-owned))]
          (ast.ast-node-pool-compat-context-clear!)
          unchanged?))]
    (ast.ast-node-pool-context-install! installed)
    (if (and
      longer-installed?
      shorter-captured?
      type-longer-installed?
      compat-unchanged?)
      unit
      (io.panic "typecheck: macro transformer pool preparation failed"))))

(test
  tc-context-expression-pool-isolation
  (let
    [installed-len : i64 (ast.ast-node-pool-len)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [root-a : i64 (ast.ast-node-pool-context-expr-push pools-a (Var 101))]
    [root-b : i64 (ast.ast-node-pool-context-expr-push pools-b (Var 202))]
    [ctx-a : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-a)]
    [ctx-b : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-b)]
    [next-a : i64 (ast.ast-node-pool-context-expr-push pools-a (Var 303))]
    [next-b : i64 (ast.ast-node-pool-context-expr-push pools-b (Var 404))]
    [a-root-ok? : bool
      (match (tc_core.tc-context-expr-get ctx-a root-a)
        [(Var name) (= name 101)]
        [_ false])]
    [b-root-ok? : bool
      (match (tc_core.tc-context-expr-get ctx-b root-b)
        [(Var name) (= name 202)]
        [_ false])]
    [a-next-ok? : bool
      (match (tc_core.tc-context-expr-get ctx-a next-a)
        [(Var name) (= name 303)]
        [_ false])]
    [b-next-ok? : bool
      (match (tc_core.tc-context-expr-get ctx-b next-b)
        [(Var name) (= name 404)]
        [_ false])]
    [compat-ok? : bool
      (begin
        (ast.ast-node-pool-compat-context-use! pools-a)
        (let
          [ok?
            : bool
            ;; A compatibility pool context does not redirect typechecker
            ;; reads, and no typecheck context may be created under one.
            (and
              (match (tc_core.tc-context-expr-get ctx-b root-a)
                [(Var name) (= name 202)]
                [_ false])
              (=
                (tc_core.tc-context-expr-bases ctx-b)
                (ast.ast-node-pool-context-expr-segment-bases (& pools-b)))
              (>
                (string.string-length (tc_core.tc-context-compat-guard-message))
                0))]
          (ast.ast-node-pool-compat-context-clear!)
          (and
            ok?
            (=
              (string.string-length (tc_core.tc-context-compat-guard-message))
              0))))]
    [installed-ok? : bool
      (let
        [saved : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        ;; Neither does an ordinary install of another pool.
        (ast.ast-node-pool-context-install! pools-b)
        (let
          [ok? : bool
            (match (tc_core.tc-context-expr-get ctx-a root-b)
              [(Var name) (= name 101)]
              [_ false])]
          (ast.ast-node-pool-context-install! saved)
          ok?))]
    (if (and
      (= root-a root-b)
      (= next-a next-b)
      a-root-ok?
      b-root-ok?
      a-next-ok?
      b-next-ok?
      compat-ok?
      installed-ok?
      (= (ast.ast-node-pool-context-expr-len pools-a) 2)
      (= (ast.ast-node-pool-context-expr-len pools-b) 2)
      (= (ast.ast-node-pool-len) installed-len))
      unit
      (io.panic "typecheck: context expression pool isolation failed"))))

(cfg
  test
  (test
    compiler-tc-reinfer-body-fact-profile-job-isolation
    (let
      [left-metrics : (__tl_dyn-array i64)
        (__tl_make-array i64 tc_core.compiler-tc-profile-metric-count)]
      [right-metrics : (__tl_dyn-array i64)
        (__tl_make-array i64 tc_core.compiler-tc-profile-metric-count)]
      [left : tc_core.TcJobState
        (tc_core.tc-job-state-new-with-profile-metrics-address
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data left-metrics) : (Ptr i64)))))]
      [right : tc_core.TcJobState
        (tc_core.tc-job-state-new-with-profile-metrics-address
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data right-metrics) : (Ptr i64)))))]
      [left-address : u64 (tc_core.compiler-tc-profile-metrics-address left)]
      [right-address : u64 (tc_core.compiler-tc-profile-metrics-address right)]
      [site : String "move.call_func"]
      [index : i64
        (tc_core.compiler-tc-reinfer-profile-site-index (string.copy site))]
      (tc_core.compiler-tc-reinfer-profile-reset left)
      (tc_core.compiler-tc-reinfer-profile-reset right)
      (tc_core.compiler-tc-body-fact-profile-reset left)
      (tc_core.compiler-tc-body-fact-profile-reset right)
      (tc_core.compiler-tc-reinfer-profile-note left (string.copy site) 7 11 13)
      (tc_core.compiler-tc-body-fact-profile-hit left (string.copy site))
      (tc_core.compiler-tc-reinfer-profile-note
        right
        (string.copy site)
        17
        19
        23)
      (tc_core.compiler-tc-body-fact-profile-miss right (string.copy site))
      (tc_core.compiler-tc-reinfer-profile-reset right)
      (tc_core.compiler-tc-body-fact-profile-reset right)
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          (+ tc_core.compiler-tc-reinfer-profile-calls-start index))
        1
        "left reinference count survives right reset")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          (+ tc_core.compiler-tc-reinfer-profile-ms-start index))
        7
        "left reinference timing uses its owner")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          (+ tc_core.compiler-tc-reinfer-profile-alloc-start index))
        11
        "left reinference allocation delta uses its owner")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          (+ tc_core.compiler-tc-reinfer-profile-live-start index))
        13
        "left reinference live delta uses its owner")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          (+ tc_core.compiler-tc-body-fact-profile-hits-start index))
        1
        "left body-fact hit survives right reset")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          (+ tc_core.compiler-tc-reinfer-profile-calls-start index))
        0
        "right reinference count resets independently")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          (+ tc_core.compiler-tc-body-fact-profile-misses-start index))
        0
        "right body-fact miss resets independently"))))

(cfg
  test
  (test
    compiler-tc-splice-profile-job-isolation
    (let
      [left-metrics : (__tl_dyn-array i64)
        (__tl_make-array i64 tc_core.compiler-tc-profile-metric-count)]
      [right-metrics : (__tl_dyn-array i64)
        (__tl_make-array i64 tc_core.compiler-tc-profile-metric-count)]
      [left : tc_core.TcJobState
        (tc_core.tc-job-state-new-with-profile-metrics-address
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data left-metrics) : (Ptr i64)))))]
      [right : tc_core.TcJobState
        (tc_core.tc-job-state-new-with-profile-metrics-address
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data right-metrics) : (Ptr i64)))))]
      [left-macro : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state left)]
      [right-macro : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state right)]
      [left-address : u64 (tc_core.compiler-tc-profile-metrics-address left)]
      [right-address : u64 (tc_core.compiler-tc-profile-metrics-address right)]
      (tc_core.compiler-tc-splice-profile-reset left)
      (tc_core.compiler-tc-splice-profile-reset right)
      ;; Interleave the two jobs' notes on the same slot names.
      (tc_core.compiler-tc-walk-segment-fallback-flatten-note! left-macro 2)
      (tc_core.compiler-tc-walk-segment-fallback-flatten-note! right-macro 1)
      (tc_core.compiler-tc-walk-segment-fallback-flatten-note! left-macro 2)
      (tc_core.compiler-tc-macro-profile-metric-add!
        left-macro
        tc_core.tc-profile-segment-delta-decls
        5)
      (tc_core.compiler-tc-macro-profile-metric-add!
        right-macro
        tc_core.tc-profile-segment-final-flattens
        1)
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-segment-fallback-file-flattens)
        2
        "left file flattens count only left notes")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-segment-fallback-alias-flattens)
        0
        "right alias flatten is not left's")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          tc_core.tc-profile-segment-fallback-flattens)
        1
        "right counts its own flatten")
      (tc_core.compiler-tc-splice-profile-reset right)
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          tc_core.tc-profile-segment-final-flattens)
        0
        "right reset clears the family's last slot")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-segment-fallback-flattens)
        2
        "right reset leaves left's flattens")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-segment-delta-decls)
        5
        "right reset leaves left's delta declarations")
      ;; The family sits between the reinference/body-fact columns and the
      ;; driver ledger's first slot.
      (test.assert-true
        (and
          (>=
            tc_core.compiler-tc-splice-profile-first
            (+
              tc_core.compiler-tc-body-fact-profile-misses-start
              tc_core.compiler-tc-reinfer-profile-site-count))
          (<= tc_core.compiler-tc-splice-profile-end 108))
        "splice slots do not overlap another family"))))

(cfg
  test
  (test
    compiler-tc-macro-program-profile-job-isolation
    (let
      [left-metrics : (__tl_dyn-array i64)
        (__tl_make-array i64 tc_core.compiler-tc-profile-metric-count)]
      [right-metrics : (__tl_dyn-array i64)
        (__tl_make-array i64 tc_core.compiler-tc-profile-metric-count)]
      [left : tc_core.TcJobState
        (tc_core.tc-job-state-new-with-profile-metrics-address
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data left-metrics) : (Ptr i64)))))]
      [right : tc_core.TcJobState
        (tc_core.tc-job-state-new-with-profile-metrics-address
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data right-metrics) : (Ptr i64)))))]
      [left-macro : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state left)]
      [right-macro : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state right)]
      [left-address : u64 (tc_core.compiler-tc-profile-metrics-address left)]
      [right-address : u64 (tc_core.compiler-tc-profile-metrics-address right)]
      (tc_core.compiler-tc-macro-program-profile-reset left)
      (tc_core.compiler-tc-macro-program-profile-reset right)
      ;; Interleave the two jobs' counts and maxima on the same slot names.
      (tc_core.compiler-tc-macro-profile-metric-add!
        left-macro
        tc_core.tc-profile-generated-decl-checks
        2)
      (tc_core.compiler-tc-macro-profile-metric-max!
        right-macro
        tc_core.tc-profile-live-symbols-max-bytes
        7)
      (tc_core.compiler-tc-macro-profile-metric-max!
        left-macro
        tc_core.tc-profile-live-symbols-max-bytes
        100)
      (tc_core.compiler-tc-macro-profile-metric-max!
        left-macro
        tc_core.tc-profile-live-symbols-max-bytes
        40)
      (tc_core.compiler-tc-macro-profile-metric-add!
        right-macro
        tc_core.tc-profile-stdlib-catalog-hits
        1)
      (tc_core.compiler-tc-macro-profile-metric-add!
        left-macro
        tc_core.tc-profile-splice-generation-rotations
        3)
      (tc_core.compiler-tc-profile-metric-set!
        right-address
        tc_core.tc-profile-stdlib-entry-invoke-start-ns
        9)
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-generated-decl-checks)
        2
        "left counts its own generated declaration checks")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          tc_core.tc-profile-generated-decl-checks)
        0
        "left's checks are not right's")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-live-symbols-max-bytes)
        100
        "a smaller sample does not lower left's maximum")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          tc_core.tc-profile-live-symbols-max-bytes)
        7
        "right keeps its own maximum")
      (tc_core.compiler-tc-macro-program-profile-reset right)
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          tc_core.tc-profile-stdlib-entry-invoke-start-ns)
        0
        "right reset clears the family's last, unreported slot")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          right-address
          tc_core.tc-profile-stdlib-catalog-hits)
        0
        "right reset clears its catalog hits")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-splice-generation-rotations)
        3
        "right reset leaves left's splice rotations")
      (test.assert-i64-eq
        (tc_core.compiler-tc-profile-metric-value
          left-address
          tc_core.tc-profile-live-symbols-max-bytes)
        100
        "right reset leaves left's maximum")
      ;; The family follows the splice counters and ends before the driver
      ;; ledger's first slot.
      (test.assert-true
        (and
          (>=
            tc_core.compiler-tc-macro-program-profile-first
            tc_core.compiler-tc-splice-profile-end)
          (<= tc_core.compiler-tc-macro-program-profile-end 108))
        "macro-program slots do not overlap another family"))))

;; Every span-bearing diagnostic builder below a typecheck error, rendered for
;; one expression root through one expression segment-bases token.
(define (tc-diagnostic-span-isolation-transcript
  [expr-bases : i64]
  [session : cis.InternStructuralSessionHandle]
  [root-id : i64]) : String
  (let
    [root : ast.AstExpr (ast.ast-expr-segment-bases-get expr-bases root-id)]
    [outer : ast.AstSourceSpan (ast.ast-source-span 1 1 1 2)]
    [located : String
      (tc_core.tc-locate-error-at-expr
        expr-bases
        (tc_core.tc-global-shared-view root)
        "typecheck: span isolation")]
    [expr-diag : cdiag.CompilerDiagnostic
      (tc_core.tc-expr-diag
        expr-bases
        (tc_core.tc-global-shared-view root)
        "typecheck: span isolation")]
    [decl-diag : cdiag.CompilerDiagnostic
      (tc_core.tc-decl-diag
        expr-bases
        (ast.ast-decl-def-id (ci.intern "span-isolation/decl") (No) root-id)
        "typecheck: span isolation")]
    [escape : String
      (match (tc_core.tc-spanned-escape-error
        expr-bases
        session
        (tc_core.tc-global-shared-view root)
        outer
        "typecheck: reference value would escape lexical scope")
        [(Some rich) rich]
        [(No) "<no escape diagnostic>"])]
    [escape-at : String
      (tc_core.tc-rich-escape-at-expr
        expr-bases
        (tc_core.tc-global-shared-view root)
        "typecheck: reference value would escape lexical scope"
        "span isolation")]
    [pattern : String
      (tc_core.tc-locate-match-pattern-error
        expr-bases
        root
        "typecheck: span isolation")]
    (str_cat.str-cat
      located
      "\n"
      (cdiag.compiler-diagnostic-render expr-diag)
      "\n"
      (cdiag.compiler-diagnostic-render decl-diag)
      "\n"
      escape
      "\n"
      escape-at
      "\n"
      pattern)))

(define (tc-diagnostic-span-isolation-expect-message
  [ctx : tc_core.TcContext]
  [root : ast.AstExpr]) : String
  (match (tc_core.tc-expect-at-expr
    ctx
    root
    (I64)
    (Bool)
    "typecheck: span isolation")
    [(Err message) message]
    [(Ok) "<no mismatch>"]))

;; Pools A and B hold the same numeric ids with different source spans. With B
;; installed as a decoy, every diagnostic built for an A node must carry A's
;; span, byte-identical to the serial rendering with A installed, and must
;; leave B installed and both pools unchanged.
(test
  tc-diagnostic-span-pool-isolation
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [name-id : i64 (ci.intern "span-isolation/value")]
    [leaf-a : i64 (ast.ast-node-pool-context-expr-push pools-a (Var name-id))]
    [leaf-b : i64 (ast.ast-node-pool-context-expr-push pools-b (Var name-id))]
    [spanned-a : i64
      (ast.ast-node-pool-context-expr-push
        pools-a
        (Spanned leaf-a (ast.ast-source-span 7 5 7 12)))]
    [spanned-b : i64
      (ast.ast-node-pool-context-expr-push
        pools-b
        (Spanned leaf-b (ast.ast-source-span 99 3 99 9)))]
    [root-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Return spanned-a))]
    [root-b : i64
      (ast.ast-node-pool-context-expr-push pools-b (Return spanned-b))]
    [ctx-a : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-a)]
    [session : cis.InternStructuralSessionHandle
      (tc_core.tc-context-structural-session ctx-a)]
    [bases-a : i64 (ast.ast-node-pool-context-expr-segment-bases (& pools-a))]
    [bases-b : i64 (ast.ast-node-pool-context-expr-segment-bases (& pools-b))]
    [root-expr : ast.AstExpr (ast.ast-expr-segment-bases-get bases-a root-a)]
    [_install-owner : unit (ast.ast-node-pool-context-install! pools-a)]
    [serial : String
      (tc-diagnostic-span-isolation-transcript
        (ast.ast-node-pool-active-expr-segment-bases)
        session
        root-a)]
    [serial-expect : String
      (tc-diagnostic-span-isolation-expect-message
        ctx-a
        (tc_core.tc-global-shared-view root-expr))]
    [_install-decoy : unit (ast.ast-node-pool-context-install! pools-b)]
    [isolated : String
      (tc-diagnostic-span-isolation-transcript bases-a session root-a)]
    [isolated-expect : String
      (tc-diagnostic-span-isolation-expect-message ctx-a root-expr)]
    [decoy : String
      (tc-diagnostic-span-isolation-transcript bases-b session root-b)]
    [owner-line? : bool
      (match (tc_core.tc-expr-id-maybe-span bases-a root-a)
        [(Some span) (= (ast.ast-source-span-start-line span) 7)]
        [(No) false])]
    [decoy-line? : bool
      (match (tc_core.tc-expr-id-maybe-span-installed root-b)
        [(Some span) (= (ast.ast-source-span-start-line span) 99)]
        [(No) false])]
    [decoy-still-installed? : bool
      (ast.ast-node-pool-context-expr-installed? pools-b)]
    [ok? : bool
      (and
        (= root-a root-b)
        owner-line?
        decoy-line?
        (string.eq serial isolated)
        (string.eq serial-expect isolated-expect)
        (not (string.eq isolated decoy))
        (not (string.eq isolated-expect "<no mismatch>"))
        decoy-still-installed?
        (= (ast.ast-node-pool-context-expr-len pools-a) 3)
        (= (ast.ast-node-pool-context-expr-len pools-b) 3))]
    (ast.ast-node-pool-context-install! installed)
    (if ok?
      unit
      (io.panic "typecheck: diagnostic span pool isolation failed"))))

;; One decoy-pool fixture for macro expression reads (#8199): `(head name 1)`
;; whose name is a spanned child. Pools A and B push the same shapes, so ids
;; collide, but A builds `(define alpha 1)` and B `(begin beta 1)`.
(define (macro-read-pool-call
  [pools : ast.AstNodePoolContext]
  [head-id : i64]
  [name-id : i64]) : i64
  (let
    [name : i64 (ast.ast-node-pool-context-expr-push pools (Var name-id))]
    [spanned : i64
      (ast.ast-node-pool-context-expr-push
        pools
        (Spanned name (ast.ast-source-span 3 1 3 6)))]
    [value : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (Int 1 "1")))]
    [head : i64 (ast.ast-node-pool-context-expr-push pools (Var head-id))]
    [args : ast.AstExprList (ast.ast-expr-list-new)]
    (ast.ast-expr-list-push (&mut args) spanned)
    (ast.ast-expr-list-push (&mut args) value)
    (ast.ast-node-pool-context-expr-push pools (Call head args))))

;; The name id of the single `define` a macro output parses to, or -1.
(define (macro-read-pool-parsed-name [parsed : tc_core.ResultMacroParsedDecls]) : i64
  (match parsed
    [(Ok decls)
      (match (ast.ast-decl-list-step decls)
        [(Cons decl _)
          (match decl
            [(Def _ name _ _) name]
            [_ -1])]
        [(Nil) -1])]
    [(Err _) -1]))

;; With decoy pool B installed, macro call naming, sexpr conversion and output
;; declaration parsing of A's nodes read A through its segment bases.
(test
  macro-expression-read-pool-isolation
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [alpha-id : i64 (ci.intern "macro-read-isolation/alpha")]
    [beta-id : i64 (ci.intern "macro-read-isolation/beta")]
    [call-a : i64 (macro-read-pool-call pools-a (ci.intern "define") alpha-id)]
    [call-b : i64 (macro-read-pool-call pools-b (ci.intern "begin") beta-id)]
    [ctx-a : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-a)]
    [session : cis.InternStructuralSessionHandle
      (tc_core.tc-context-structural-session ctx-a)]
    [dispatch : sym_i64_env.SymI64Env (parser.compiler-parse-dispatch-env)]
    [bases-a : i64 (ast.ast-node-pool-context-expr-segment-bases (& pools-a))]
    [call-expr : ast.AstExpr (ast.ast-expr-segment-bases-get bases-a call-a)]
    [owner : tc_core.MacroSexprOwner
      (tc_core.macro-sexpr-owner
        (ast.ast-node-pool-reader-type-segment-bases)
        bases-a
        session)]
    ;; The spanned name is the define's first argument, pushed second.
    [spanned-expr : ast.AstExpr
      (ast.ast-expr-segment-bases-get bases-a (- call-a 3))]
    ;; Parsing an output form installs the parser's pools, so the decoy is
    ;; reinstalled before each read under test.
    [_decoy-for-name : unit (ast.ast-node-pool-context-install! pools-b)]
    [callee-name : String
      (match (tc_core.macro-call-callee-name bases-a session spanned-expr)
        [(Some name) name]
        [(No) ""])]
    [_decoy-for-sexpr : unit (ast.ast-node-pool-context-install! pools-b)]
    [sexpr-name : i64
      (match (tc_core.macro-expr-to-spanned-sexpr
        (& owner)
        (tc_core.tc-global-shared-view call-expr)
        (tc_core.tc-global-shared-view call-expr))
        [(Ok form)
          (match (parser.parse-ast-decl-maybe dispatch form)
            [(SomeDecl decl)
              (match decl
                [(Def _ name _ _) name]
                [_ -1])]
            [_ -1])]
        [(Err _) -1])]
    [_decoy-for-parse : unit (ast.ast-node-pool-context-install! pools-b)]
    [parsed-name : i64
      (macro-read-pool-parsed-name
        (tc_core.macro-parse-decls-from-expr
          (& owner)
          dispatch
          (tc_core.tc-global-shared-view call-expr)
          call-expr))]
    [ok? : bool
      (and
        (= call-a call-b)
        (string.eq callee-name "macro-read-isolation/alpha")
        (string.eq
          (tc_core.tc-env-key-display session sexpr-name)
          "macro-read-isolation/alpha")
        (string.eq
          (tc_core.tc-env-key-display session parsed-name)
          "macro-read-isolation/alpha"))]
    (ast.ast-node-pool-context-install! installed)
    (if ok?
      unit
      (io.panic "typecheck: macro expression read pool isolation failed"))))

;; --- #8200: typecheck and CTFE-predicate reads use the owning pool ----------
;;
;; Two fresh pools take the same push sequence, so each probed node has the same
;; id in both. Pool B is installed as the ambient decoy while A's segment bases
;; are passed explicitly; a read that fell back to the installed pool would see
;; B's node and answer differently.
;; Three filler nodes, then LAST; LAST's id. The same calls on two fresh pools
;; return the same ids.
(define (owned-read-pool-node
  [pools : ast.AstNodePoolContext]
  [last : ast.AstExpr]) : i64
  (ast.ast-node-pool-context-expr-push pools (ProgramArgc))
  (ast.ast-node-pool-context-expr-push pools (ProgramArgc))
  (ast.ast-node-pool-context-expr-push pools (ProgramArgc))
  (ast.ast-node-pool-context-expr-push pools last))

(test
  typecheck-expression-reads-use-owning-pool
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [name-id : i64 (ci.intern "owned-read/value")]
    [span : ast.AstSourceSpan (ast.ast-source-span 2 1 2 9)]
    ;; call classification: a call in A, a literal at the same id in B
    [call-a : i64
      (owned-read-pool-node pools-a (Call 0 (ast.ast-expr-list-new)))]
    [call-b : i64 (owned-read-pool-node pools-b (Literal (Int 1 "1")))]
    ;; borrow check: A's value names `name-id`, B's names another binding
    [var-a : i64 (owned-read-pool-node pools-a (Var name-id))]
    [var-b : i64
      (owned-read-pool-node pools-b (Var (ci.intern "owned-read/decoy")))]
    ;; CTFE predicate: a type literal in A, a plain literal in B
    [type-a : i64 (owned-read-pool-node pools-a (TypeLiteral 0))]
    [type-b : i64 (owned-read-pool-node pools-b (Literal (Int 2 "2")))]
    [bases-a : i64 (ast.ast-node-pool-context-expr-segment-bases (& pools-a))]
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state (tc_core.tc-job-state-new))]
    [_decoy : unit (ast.ast-node-pool-context-install! pools-b)]
    [call? : bool (tc_core.tc-call-expr? bases-a (Spanned call-a span))]
    [uses? : bool
      (tc_core.tc-borrow-check-composite-value-uses-name?
        bases-a
        (Spanned var-a span)
        name-id)]
    [typed? : bool
      (tc_core.ctfe-node-has-type-literal? bases-a macro-state type-a)]
    (ast.ast-node-pool-context-install! installed)
    (test.assert-true
      (and (= call-a call-b) (= var-a var-b) (= type-a type-b))
      "the two pools give the probed nodes the same ids")
    (test.assert-true
      call?
      "call classification (tc-call-expr?) reads the call from its owning pool, not the installed decoy")
    (test.assert-true
      uses?
      "the composite-value borrow check reads the value from its owning pool, not the installed decoy")
    (test.assert-true
      typed?
      "the CTFE type-literal predicate reads the node from its owning pool, not the installed decoy")))

;; Equal numeric ids in a decoy pool must not redirect type readers. The
;; captured table remains valid across segment growth; the resolver's memo and
;; reconstructed children must keep the same context owner.
(test
  tc-type-readers-owning-pool
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [from : i64 (ci.intern "type-reader/from")]
    [to : i64 (ci.intern "type-reader/to")]
    [region : i64 (ci.intern "type-reader/region")]
    [scalar-a : i64 (ast.ast-node-pool-context-type-push a (I64))]
    [scalar-b : i64 (ast.ast-node-pool-context-type-push b (Bool))]
    [region-a : i64
      (ast.ast-node-pool-context-type-push a (Region region scalar-a))]
    [region-b : i64 (ast.ast-node-pool-context-type-push b (F64))]
    [var-a : i64
      (ast.ast-node-pool-context-type-push a (Var (ci.intern "Expr")))]
    [var-b : i64 (ast.ast-node-pool-context-type-push b (I64))]
    [root-a : i64 (ast.ast-node-pool-context-type-push a (Array region-a 3))]
    [root-b : i64 (ast.ast-node-pool-context-type-push b (Array region-b 9))]
    [bases : i64 (ast.ast-node-pool-context-type-segment-bases a)]
    [ctx : tc_core.TcContext (macro-prepare-test-ctx a)]
    [env : tc_core.TcTypeEnv
      (tc_core.tc-default-env-with-job-state (tc_core.tc-context-job-state ctx))]
    [params : ast.AstLifetimeList
      (ast.ast-lifetime-cons from (ast.ast-lifetime-list-new))]
    [index : i64 0]
    (while (< index 1030)
      (ast.ast-node-pool-context-type-push a (Array scalar-a (+ index 100)))
      (ast.ast-node-pool-context-type-push b (Array region-b (+ index 100)))
      (set! index (+ index 1)))
    (let
      [b-before : i64 (ast.ast-node-pool-context-type-len b)]
      [_decoy : unit (ast.ast-node-pool-context-install! b)]
      [equal? : bool
        (tc_core.tc-type-eq bases (Array region-a 3) (Array scalar-a 3))]
      [different? : bool
        (not (tc_core.tc-type-eq bases (Array scalar-a 3) (Array scalar-a 4)))]
      [rendered : String (tc_core.tc-type-render bases (Array scalar-a 3))]
      [grown : String
        (tc_core.tc-type-render
          bases
          (ast.ast-type-segment-bases-get bases 1024))]
      [substitution? : bool
        (match (tc_core.tc-infer-lifetime-subst-from-type
          ctx
          env
          params
          Nil
          (Ref from region-a)
          (Ref to region-a)
          TcVarianceCovariant)
          [(Ok subst)
            (match (tc_core.tc-lifetime-subst-lookup subst from)
              [(Some actual) (= actual to)]
              [(No) false])]
          [(Err _) false])]
      [resolved : ast.AstType (tc_core.tc-resolve-type ctx (Array var-a 5))]
      [resolution? : bool
        (match resolved
          [(Array child count)
            (and
              (= count 5)
              (< child (ast.ast-node-pool-context-type-len a))
              (match (ast.ast-type-segment-bases-get bases child)
                [(Expr) true]
                [_ false]))]
          [_ false])]
      [decoy-unchanged? : bool
        (= b-before (ast.ast-node-pool-context-type-len b))]
      [decoy-installed? : bool (ast.ast-node-pool-context-type-installed? b)]
      (ast.ast-node-pool-context-install! installed)
      (test.assert-true
        (and
          (= scalar-a scalar-b)
          (= region-a region-b)
          (= var-a var-b)
          (= root-a root-b))
        "colliding type ids")
      (test.assert-true
        (= bases (ast.ast-node-pool-context-type-segment-bases a))
        "the owning type table survives growth")
      (test.assert-true equal? "type equality reads the owning pool")
      (test.assert-true different? "type equality preserves array lengths")
      (test.assert-true
        (string.eq rendered "(Array i64 3)")
        "rendering reads the owning scalar")
      (test.assert-true
        (string.eq grown "(Array i64 1120)")
        "rendering reads a grown segment")
      (test.assert-true
        substitution?
        "lifetime substitution reads the owning pool")
      (test.assert-true
        resolution?
        "resolution writes children to the owning pool")
      (test.assert-true
        decoy-unchanged?
        "resolution leaves the decoy pool unchanged")
      (test.assert-true
        decoy-installed?
        "type readers leave the decoy installed"))))

;; --- #7918: expression forms in Decls/Module macro output -------------------
;;
;; A Decls or Module macro's output reaches the declaration parser through
;; `macro-expr-to-spanned-sexpr`, which spells each expression node back as the
;; syntax the parser reads. Its match has no fallback, so the typechecker keeps
;; it total over `AstExpr`; this test checks that the spelling is right: every
;; form below converts, re-parses as the same kind of expression, and converts
;; again to the same syntax, with the expected head.
;; Span-insensitive syntax equality.
(define (macro-output-sexpr-eq?
  [a : reader.SpannedSexpr]
  [b : reader.SpannedSexpr]) : bool
  (match (reader.spanned-sexpr-view a)
    [(Int av _ _)
      (match (reader.spanned-sexpr-view b)
        [(Int bv _ _) (= av bv)]
        [_ false])]
    [(Sym as _)
      (match (reader.spanned-sexpr-view b)
        [(Sym bs _)
          (= (ci.intern-syntax-id-value as) (ci.intern-syntax-id-value bs))]
        [_ false])]
    [(Nil _)
      (match (reader.spanned-sexpr-view b)
        [(Nil _) true]
        [_ false])]
    [(Cons ahead atail _)
      (match (reader.spanned-sexpr-view b)
        [(Cons bhead btail _)
          (and
            (macro-output-sexpr-eq? ahead bhead)
            (macro-output-sexpr-eq? atail btail))]
        [_ false])]
    [(Str aid _)
      (match (reader.spanned-sexpr-view b)
        [(Str bid _) (= (ci.intern-id-value aid) (ci.intern-id-value bid))]
        [_ false])]
    [(Char ac _)
      (match (reader.spanned-sexpr-view b)
        [(Char bc _) (= ac bc)]
        [_ false])]
    [(Float at _)
      (match (reader.spanned-sexpr-view b)
        [(Float bt _) (string.eq at bt)]
        [_ false])]
    [(BracketList aitems _)
      (match (reader.spanned-sexpr-view b)
        [(BracketList bitems _) (macro-output-sexpr-eq? aitems bitems)]
        [_ false])]))

(define (macro-output-sexpr-head? [form : reader.SpannedSexpr] [head : String]) : bool
  (match (reader.spanned-sexpr-view form)
    [(Cons first _ _)
      (match (reader.spanned-sexpr-view first)
        [(Sym name _) (= (ci.intern-syntax-id-value name) (ci.intern head))]
        [_ false])]
    [_ false]))

;; The body of `(define (probe) : i64 FORM)`, parsed into the active pools.
(define (macro-output-probe-body [form : String]) : i64
  (match (parser.parse-ast-source
    (str_cat.str-cat "(define (probe) : i64 " form ")"))
    [(Ok (Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(Cons (DefFn _ _ _ _ body-box _) _) body-box]
        [_ -1])]
    [(Err _) -1]))

;; FORM as the reader reads it, or an empty list when it does not read.
(define (macro-output-source-sexpr [form : String]) : reader.SpannedSexpr
  (match (lexer.spanned-result form)
    [(Ok toks)
      (match (reader.spanned-result toks)
        [(Ok sexpr) sexpr]
        [(Err _)
          (reader.spanned-sexpr-list-from-builder
            (reader.spanned-sexpr-builder-new)
            (token.SourceSpan 0 0 0 0))])]
    [(Err _)
      (reader.spanned-sexpr-list-from-builder
        (reader.spanned-sexpr-builder-new)
        (token.SourceSpan 0 0 0 0))]))

;; Probe PROBE's form converts to exactly the syntax it was written as, with
;; the expected head; that re-parses as the same kind of expression and
;; converts again to the same syntax.
(define (macro-output-form-round-trips?
  [session : cis.InternStructuralSessionHandle]
  [probe : i64]) : bool
  (let
    [body-id : i64 (macro-output-probe-body (macro-output-form probe))]
    (if (< body-id 0)
      false
      (let
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [bases : i64 (ast.ast-node-pool-context-expr-segment-bases (& pools))]
        [first-expr : ast.AstExpr
          (ast.ast-expr-segment-bases-get bases body-id)]
        [owner : tc_core.MacroSexprOwner
          (tc_core.macro-sexpr-owner
            (ast.ast-node-pool-reader-type-segment-bases)
            bases
            session)]
        (match (tc_core.macro-expr-to-spanned-sexpr
          (& owner)
          (tc_core.tc-global-shared-view first-expr)
          (tc_core.tc-global-shared-view first-expr))
          [(Err _) false]
          [(Ok first)
            (match (parser.parse-ast-expr-with-pools
              (parser.compiler-parse-dispatch-env)
              pools
              (tc_core.tc-global-shared-view first))
              [(Err _) false]
              [(Ok second-id)
                (let
                  [second-pools : ast.AstNodePoolContext
                    (ast.ast-node-pool-context-capture-active)]
                  [second-bases : i64
                    (ast.ast-node-pool-context-expr-segment-bases
                      (& second-pools))]
                  [second-expr : ast.AstExpr
                    (ast.ast-expr-segment-bases-get second-bases second-id)]
                  [second-owner : tc_core.MacroSexprOwner
                    (tc_core.macro-sexpr-owner
                      (ast.ast-node-pool-reader-type-segment-bases)
                      second-bases
                      session)]
                  (match (tc_core.macro-expr-to-spanned-sexpr
                    (& second-owner)
                    (tc_core.tc-global-shared-view second-expr)
                    (tc_core.tc-global-shared-view second-expr))
                    [(Err _) false]
                    [(Ok second)
                      (and
                        (macro-output-sexpr-head?
                          (tc_core.tc-global-shared-view first)
                          (macro-output-form-head probe))
                        (macro-output-sexpr-eq?
                          (tc_core.tc-global-shared-view first)
                          (macro-output-source-sexpr (macro-output-form probe)))
                        (macro-output-sexpr-eq? first second)
                        (string.eq
                          (ctfe_support.ctfe-describe-expr
                            (ast.ast-expr-unspan-with-segment-bases
                              bases
                              first-expr))
                          (ctfe_support.ctfe-describe-expr
                            (ast.ast-expr-unspan-with-segment-bases
                              second-bases
                              second-expr))))]))])])))))

;; The probed forms, in order; the last wraps a converted form in a `let`.
(define (macro-output-form [i : i64]) : String
  (cond
    [(= i 0) "(in-arena a 41 42)"]
    [(= i 1) "(with-escape s 42)"]
    [(= i 2) "(with-scratch 41 42)"]
    [(= i 3) "(with-arena r 41 42)"]
    [(= i 4) "(with ([h (open-h) close-h] [g (open-g h) close-g]) (use h) 42)"]
    [(= i 5) "(break)"]
    [(= i 6) "(continue)"]
    [(= i 7) "(comptime (+ 40 2))"]
    [(= i 8) "(lambda ([x : i64] [y : i64]) : i64 (+ x y))"]
    [(= i 9) "(lambda ([x : i64]) x)"]
    [(= i 10) "(foreach ([i : i64 0 n]) (touch out i))"]
    [(= i 11) "(foreach-active [lane : i64] (lane-value lane))"]
    [(= i 12) "(spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i))"]
    [(= i 13)
      "(spmd-scan max ([i : i64 0 n] [acc : i64 0]) (array-ref xs i) (touch out i acc))"]
    [(= i 14)
      "(spmd-compact ([i : i64 0 n] [slot : i64 0]) (> (array-ref xs i) 0) (touch out slot i))"]
    [(= i 15) "(spmd-broadcast v 0)"]
    [(= i 16) "(spmd-shuffle v lane)"]
    [(= i 17) "(program-index)"]
    [(= i 18) "(program-count)"]
    [(= i 19) "(lane-value v)"]
    [(= i 20) "(__tl_for-owned-state src idx source body)"]
    [(= i 21) "(__tl_for-owned-step src idx item done body)"]
    [(= i 22) "(__tl_for-owned-step-typed src idx item (type i64) done body)"]
    [else "(let [x : i64 41] (in-arena a (+ x 1)))"]))

;; The head each probed form converts to.
(define (macro-output-form-head [i : i64]) : String
  (cond
    [(= i 0) "in-arena"]
    [(= i 1) "with-escape"]
    [(= i 2) "with-scratch"]
    [(= i 3) "with-arena"]
    [(= i 4) "with"]
    [(= i 5) "break"]
    [(= i 6) "continue"]
    [(= i 7) "comptime"]
    [(= i 8) "lambda"]
    [(= i 9) "lambda"]
    [(= i 10) "foreach"]
    [(= i 11) "foreach-active"]
    [(= i 12) "spmd-reduce"]
    [(= i 13) "spmd-scan"]
    [(= i 14) "spmd-compact"]
    [(= i 15) "spmd-broadcast"]
    [(= i 16) "spmd-shuffle"]
    [(= i 17) "program-index"]
    [(= i 18) "program-count"]
    [(= i 19) "lane-value"]
    [(= i 20) "__tl_for-owned-state"]
    [(= i 21) "__tl_for-owned-step"]
    [(= i 22) "__tl_for-owned-step-typed"]
    [else "let"]))

(define (macro-output-forms-failed
  [session : cis.InternStructuralSessionHandle]) : String
  (let
    [failed : String ""]
    [i : i64 0]
    (while (< i 24)
      (if (macro-output-form-round-trips? session i)
        unit
        (set! failed (str_cat.str-cat failed " " (macro-output-form i))))
      (set! i (+ i 1)))
    failed))

;; A move-aware resource scope has no declaration spelling; converting one must
;; fail instead of re-parsing as a plain `with` that keeps its cleanup armed.
(define (macro-output-move-aware-rejected?
  [session : cis.InternStructuralSessionHandle]) : bool
  (let
    [body-id : i64 (macro-output-probe-body (macro-output-form 4))]
    (if (< body-id 0)
      false
      (let
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [bases : i64 (ast.ast-node-pool-context-expr-segment-bases (& pools))]
        [parsed : ast.AstExpr (ast.ast-expr-segment-bases-get bases body-id)]
        [owner : tc_core.MacroSexprOwner
          (tc_core.macro-sexpr-owner
            (ast.ast-node-pool-reader-type-segment-bases)
            bases
            session)]
        (match (ast.ast-expr-unspan-with-segment-bases bases parsed)
          [(WithResource resource-box)
            (match (__tl-box-place resource-box)
              [(WithResource bindings body)
                (let
                  [moved : ast.AstResourceBindingList
                    (ast.ast-resource-binding-list-new)]
                  [index : i64 0]
                  (while (<
                    index
                    (ast.ast-resource-binding-list-len (& bindings)))
                    (match (ast.ast-resource-binding-list-get
                      (& bindings)
                      index
                      (ast.ast-resource-binding-fallback))
                      [(Binding name init cleanup _)
                        (ast.ast-resource-binding-list-push
                          (&mut moved)
                          (ast.AstResourceBinding.Binding
                            name
                            init
                            cleanup
                            true))])
                    (set! index (+ index 1)))
                  (let
                    [move-aware : ast.AstExpr
                      (WithResource
                        (box (ast.AstWithResource.WithResource moved body)))]
                    (match (tc_core.macro-expr-to-spanned-sexpr
                      (& owner)
                      (tc_core.tc-global-shared-view move-aware)
                      (tc_core.tc-global-shared-view move-aware))
                      [(Err _) true]
                      [(Ok _) false])))])]
          [_ false])))))

(test
  macro-output-expression-forms-round-trip
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-node-pool-context-capture-active))]
    [failed : String
      (macro-output-forms-failed (tc_core.tc-context-structural-session ctx))]
    [move-aware-rejected? : bool
      (macro-output-move-aware-rejected?
        (tc_core.tc-context-structural-session ctx))]
    (ast.ast-node-pool-context-install! installed)
    (test.assert-string-eq
      failed
      ""
      "every expression form the parser accepts in a function body -- the scoped arena, scratch, escape and resource forms, break and continue, comptime, typed and untyped lambdas, foreach and the SPMD forms, and the compiler-private owned-iteration steps in both spellings -- converts from Decls/Module macro output back to syntax that re-parses as the same kind of expression and converts again to the same syntax")
    (test.assert-true
      move-aware-rejected?
      "a move-aware resource scope in Decls/Module macro output is rejected, not spelled as a plain `with` whose cleanup stays armed")))

(define (tc-type-env-lookup-step [env : tc_core.TcTypeEnv] [name-id : i64]) : TcTypeEnvLookupStep
  (match (tc_core.tc-type-env-view env)
    [(Nil) (Missing)]
    [(Cache cache-ptr _ partial _ below)
      (let
        [ids : tc_i64_i64_map.Map
          (tc_core.tc-type-env-cache-field-at cache-ptr 32 tc_i64_i64_map.Map)]
        [values : (__tl_dyn-array ast.AstType)
          (tc_core.tc-type-env-cache-field-at
            cache-ptr
            56
            (__tl_dyn-array ast.AstType))]
        (match (tc_i64_i64_map.get (& ids) name-id)
          [(LookupFound index)
            ;; AstType reads must stay `array-ref` because inline-by-value
            ;; AstType values are multi-word.
            (Found (ast.ast-array-shared-view values index))]
          [(LookupMissing)
            (if partial
              (Miss below)
              (Missing))]))]
    [(Bind key ty rest)
      (if (= key name-id)
        (Found ty)
        (Miss rest))]))

(define (tc-type-env-unsafe-lookup-step
  [env : tc_core.TcTypeEnv]
  [name-id : i64]) : TcTypeEnvUnsafeLookupStep
  (match (tc_core.tc-type-env-view env)
    [(Nil) (Missing)]
    [(Cache cache-ptr _ partial _ below)
      (let
        [ids : tc_i64_i64_map.Map
          (tc_core.tc-type-env-cache-field-at cache-ptr 32 tc_i64_i64_map.Map)]
        [values : (__tl_dyn-array ast.AstType)
          (tc_core.tc-type-env-cache-field-at
            cache-ptr
            56
            (__tl_dyn-array ast.AstType))]
        [unsafe-flags : (__tl_dyn-array i64)
          (tc_core.tc-type-env-cache-field-at cache-ptr 64 (__tl_dyn-array i64))]
        (match (tc_i64_i64_map.get (& ids) name-id)
          [(LookupFound index)
            ;; AstType read must stay `array-ref`; the unsafe flag is a
            ;; scalar i64 and keeps the previous raw read path.
            (Found
              (ast.ast-array-shared-view values index)
              (=
                (unsafe
                  (ptr-read
                    (ptr-offset
                      (ptr-cast (__tl_array-data unsafe-flags) : (Ptr i64))
                      index)))
                1))]
          [(LookupMissing)
            (if partial
              (Miss below)
              (Missing))]))]
    [(Bind key ty rest)
      (if (= key name-id)
        (Found ty (tc_core.tc-binding-unsafe-marker-head-id? rest name-id))
        (Miss rest))]))

(cfg
  test
  (define (tc-topenv-membership-job-owned-capacity-smoke?) : bool
    (let
      [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state-a : tc_core.TcTopEnvMembershipState
        (tc_core.tc-job-state-topenv-membership job-a)]
      [state-b : tc_core.TcTopEnvMembershipState
        (tc_core.tc-job-state-topenv-membership job-b)]
      [env-a : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-a)]
      [env-b : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-b)]
      [renderable : i64 (ci.intern "membership-job-owned")]
      [renderable-overflow : i64
        (+ tc_core.tc-topenv-renderable-table-capacity 1)]
      [alias-id : i64 (ci.intern "membership-ab-alias")]
      [structural-base : i64 (* (ci.intern-capacity) (ci.intern-capacity))]
      [stress-count : i64 65537]
      [index : i64 0]
      (tc_core.tc-topenv-membership-begin! state-a env-a 101 201)
      (tc_core.tc-topenv-membership-begin! state-b env-b 102 202)
      (tc_core.tc-topenv-membership-mark-bound! state-a renderable)
      ;; One more entry than the removed fixed overflow table proves structural
      ;; membership has no hidden 65,536-key ceiling.
      (while (< index stress-count)
        (tc_core.tc-topenv-membership-mark-bound!
          state-a
          (+ structural-base index))
        (set! index (+ index 1)))
      (let
        [isolated? : bool
          (and
            (tc_core.tc-topenv-membership-bound? state-a renderable)
            (not (tc_core.tc-topenv-membership-maybe? state-b renderable))
            (tc_core.tc-topenv-membership-bound? state-a structural-base)
            (tc_core.tc-topenv-membership-bound?
              state-a
              (+ structural-base (- stress-count 1)))
            (not (tc_core.tc-topenv-membership-maybe? state-b structural-base)))]
        [enabled-env : tc_core.TcTypeEnv
          (tc_core.tc-bind-alias-id-if-free
            (tc_core.tc-bind-alias-id-if-free env-a alias-id (I64))
            alias-id
            (Bool))]
        [overflow-safe? : bool
          (begin
            ;; A typed ID above the dense prefix remains exact in the
            ;; renderable overflow map; it never enters the structural path.
            (tc_core.tc-topenv-membership-mark-bound!
              state-a
              renderable-overflow)
            (and
              (tc_core.tc-topenv-membership-maybe? state-a renderable)
              (tc_core.tc-topenv-membership-maybe? state-a renderable-overflow)
              (tc_core.tc-topenv-membership-bound? state-a renderable)
              (tc_core.tc-topenv-membership-bound? state-a renderable-overflow)))]
        (tc-job-state-set-topenv-membership-enabled! job-b false)
        (tc_core.tc-topenv-membership-begin! state-b env-b 102 202)
        (let
          [disabled-env : tc_core.TcTypeEnv
            (tc_core.tc-bind-alias-id-if-free
              (tc_core.tc-bind-alias-id-if-free env-b alias-id (I64))
              alias-id
              (Bool))]
          (tc_core.tc-topenv-membership-end! state-a)
          (tc_core.tc-topenv-membership-end! state-b)
          (and
            isolated?
            overflow-safe?
            (match (tc_core.tc-lookup-id enabled-env alias-id)
              [(Ok (I64)) true]
              [_ false])
            (match (tc_core.tc-lookup-id disabled-env alias-id)
              [(Ok (I64)) true]
              [_ false])))))))

(cfg
  test
  (test
    tc-topenv-membership-job-owned-capacity
    (if (tc-topenv-membership-job-owned-capacity-smoke?)
      unit
      (io.panic "typecheck: job-owned top-env membership/capacity smoke failed"))))

(cfg
  test
  (define (tc-env-cache-explicit-head? [env : tc_core.TcTypeEnv]) : bool
    (match (tc_core.tc-type-env-view env)
      [(Cache _ scan-through _ _ _) (not scan-through)]
      [_ false])))

(define (tc-type-env-scoped-stack-with-capacity
  [slot-capacity : i64]
  [mark-capacity : i64]) : tc_core.TcTypeEnvScopedStack
  (tc_core.tc-type-env-scoped-stack-with-capacity-for-state
    (tc_core.tc-job-state-type-env-scoped-state (tc_core.tc-serial-job-state))
    slot-capacity
    mark-capacity))

(define (tc-type-env-scoped-stack-mark-count
  [stack : (& stack tc_core.TcTypeEnvScopedStack)]) : i64
  stack.mark-count)

(define (tc-type-env-scoped-stack-scope-depth
  [stack : (& stack tc_core.TcTypeEnvScopedStack)]) : i64
  stack.scope-depth)

(define (tc-type-env-scoped-empty-mark) : tc_core.TcTypeEnvScopedMark
  (tc_core.TcTypeEnvScopedMark 0 0 0 0))

(define (tc-type-env-scoped-stack-reserve-marks!
  [stack : (&mut stack tc_core.TcTypeEnvScopedStack)]
  [min-capacity : i64]) : unit
  (while (< (array-length stack.marks) min-capacity)
    (__tl_array-push! stack.marks (tc-type-env-scoped-empty-mark)))
  unit)

(define (tc-type-env-scoped-stack-bind-flags-id!
  [stack : (&mut stack tc_core.TcTypeEnvScopedStack)]
  [name-id : i64]
  [ty : ast.AstType]
  [flags : i64]) : unit
  (tc_core.tc-type-env-scoped-stack-push-slot! stack name-id ty flags None))

(define (tc-type-env-scoped-stack-save!
  [stack : (&mut stack tc_core.TcTypeEnvScopedStack)]) : tc_core.TcTypeEnvScopedMark
  (let
    [index : i64 stack.mark-count]
    [mark : tc_core.TcTypeEnvScopedMark
      (tc_core.TcTypeEnvScopedMark
        stack.slot-count
        index
        stack.scope-depth
        stack.cache-generation)]
    (tc-type-env-scoped-stack-reserve-marks! stack (+ index 1))
    (set! (array-ref stack.marks index) mark)
    (set! stack.mark-count (+ index 1))
    (set! stack.scope-depth (+ stack.scope-depth 1))
    mark))

(define (tc-type-env-scoped-stack-marker-lookup-from
  [stack : tc_core.TcTypeEnvScopedStack]
  [marker-kind : tc_core.TcTypeEnvScopedMarkerKind]
  [index : i64]) : TcTypeEnvScopedMarkerLookup
  (if (< index 0)
    Missing
    (let
      [slot : tc_core.TcTypeEnvScopedSlot
        (tc_core.tc-global-array-element-shared-view stack.slots index)]
      (if (and
        (tc_core.tc-type-env-scoped-flag?
          slot.flags
          tc_core.tc-type-env-scoped-flag-marker)
        (=
          slot.marker-kind-tag
          (tc_core.tc-type-env-scoped-marker-kind-tag marker-kind)))
        (Found slot.name-id slot.ty slot.scope-depth slot.generation)
        (tc-type-env-scoped-stack-marker-lookup-from
          stack
          marker-kind
          (- index 1))))))

(define (tc-type-env-scoped-stack-marker-lookup
  [stack : (& stack tc_core.TcTypeEnvScopedStack)]
  [marker-kind : tc_core.TcTypeEnvScopedMarkerKind]) : TcTypeEnvScopedMarkerLookup
  (let
    [stack : tc_core.TcTypeEnvScopedStack
      (owned_view.compiler-owned-reference-shared-view stack)]
    [index : i64 (- stack.slot-count 1)]
    (tc-type-env-scoped-stack-marker-lookup-from stack marker-kind index)))

(define (tc-type-env-scoped-sidecar-new) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-from-env (tc_core.tc-empty-env)))

(define (tc-type-env-scoped-sidecar-save!
  [sidecar : (&mut sidecar tc_core.TcTypeEnvScopedSidecar)]) : tc_core.TcTypeEnvScopedMark
  (tc-type-env-scoped-stack-save! (&mut sidecar.stack)))

(define (tc-type-env-scoped-sidecar-enter-unsafe
  [sidecar : tc_core.TcTypeEnvScopedSidecar]) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-bind-marker-id
    sidecar
    (tc_core.tc-unsafe-marker-id)
    (Unit)
    UnsafeContext))

(define (tc-type-env-scoped-sidecar-bind-default-boundary
  [sidecar : tc_core.TcTypeEnvScopedSidecar]) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-bind-marker-id
    sidecar
    (tc_core.tc-default-boundary-id)
    (Unit)
    DefaultBoundary))

(define (tc-type-env-scoped-sidecar-push-region
  [sidecar : tc_core.TcTypeEnvScopedSidecar]
  [region : i64]) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-bind-marker-id
    sidecar
    (tc_core.tc-region-marker-id)
    (Var region)
    Region))

(define (tc-type-env-scoped-sidecar-bind-cleanup-owner
  [sidecar : tc_core.TcTypeEnvScopedSidecar]
  [name-id : i64]) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-bind-marker-id
    sidecar
    (tc_core.tc-cleanup-owner-marker-id)
    (Var name-id)
    CleanupOwner))

(define (tc-type-env-scoped-sidecar-bind-ordinary-arena-owner
  [sidecar : tc_core.TcTypeEnvScopedSidecar]
  [name-id : i64]) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-bind-marker-id
    sidecar
    (tc_core.tc-ordinary-arena-owner-marker-id)
    (Var name-id)
    OrdinaryArenaOwner))

(define (tc-type-env-scoped-sidecar-bind-atomic-arena-owner
  [sidecar : tc_core.TcTypeEnvScopedSidecar]
  [name-id : i64]) : tc_core.TcTypeEnvScopedSidecar
  (tc_core.tc-type-env-scoped-sidecar-bind-marker-id
    sidecar
    (tc_core.tc-atomic-arena-owner-marker-id)
    (Var name-id)
    AtomicArenaOwner))

(define (tc-type-env-scoped-sidecar-bind-unsafe-id
  [sidecar : tc_core.TcTypeEnvScopedSidecar]
  [name-id : i64]
  [ty : ast.AstType]) : tc_core.TcTypeEnvScopedSidecar
  (let
    [next : tc_core.TcTypeEnvScopedSidecar sidecar]
    (tc_core.tc-type-env-scoped-stack-bind-marker-id!
      (&mut next.stack)
      (tc_core.tc-unsafe-decl-marker-id name-id)
      (Unit)
      UnsafeDecl)
    (tc-type-env-scoped-stack-bind-flags-id!
      (&mut next.stack)
      name-id
      ty
      tc_core.tc-type-env-scoped-flag-unsafe)
    next))

(define (tc-type-env-scoped-carrier-new) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-from-env (tc_core.tc-empty-env)))

(define (tc-type-env-scoped-carrier-sidecar
  [carrier : tc_core.TcTypeEnvScopedCarrier]) : tc_core.TcTypeEnvScopedSidecar
  carrier.sidecar)

(define (tc-type-env-scoped-carrier-enter-unsafe
  [carrier : tc_core.TcTypeEnvScopedCarrier]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-enter-unsafe carrier.sidecar)))

(define (tc-type-env-scoped-carrier-bind-default-boundary
  [carrier : tc_core.TcTypeEnvScopedCarrier]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-bind-default-boundary carrier.sidecar)))

(define (tc-type-env-scoped-carrier-push-region
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [region : i64]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-push-region carrier.sidecar region)))

(define (tc-type-env-scoped-carrier-bind-cleanup-owner
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-bind-cleanup-owner carrier.sidecar name-id)))

(define (tc-type-env-scoped-carrier-bind-ordinary-arena-owner
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-bind-ordinary-arena-owner
      carrier.sidecar
      name-id)))

(define (tc-type-env-scoped-carrier-bind-atomic-arena-owner
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-bind-atomic-arena-owner carrier.sidecar name-id)))

(define (tc-type-env-scoped-carrier-bind-unsafe-id
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]
  [ty : ast.AstType]) : tc_core.TcTypeEnvScopedCarrier
  (tc_core.tc-type-env-scoped-carrier-with-sidecar
    (tc_core.tc-global-shared-view carrier)
    (tc-type-env-scoped-sidecar-bind-unsafe-id carrier.sidecar name-id ty)))

(define (tc-type-env-scoped-carrier-lookup-id
  [carrier : (& carrier tc_core.TcTypeEnvScopedCarrier)]
  [name-id : i64]) : tc_core.ResultTcType
  (let
    [carrier : tc_core.TcTypeEnvScopedCarrier
      (owned_view.compiler-owned-reference-shared-view carrier)]
    [sidecar : tc_core.TcTypeEnvScopedSidecar carrier.sidecar]
    [stack : tc_core.TcTypeEnvScopedStack
      (tc_core.tc-global-shared-view sidecar.stack)]
    [index : i64 (tc_core.tc-type-env-scoped-stack-lookup-index stack name-id)]
    (if (>= index 0)
      (let
        [slot : tc_core.TcTypeEnvScopedSlot
          (tc_core.tc-global-array-element-shared-view stack.slots index)]
        (Ok slot.ty))
      (tc_core.tc-lookup-persistent-id
        (tc_core.tc-type-env-scoped-sidecar-persistent sidecar)
        name-id))))

(define (tc-type-env-scoped-carrier-name-bound-id?
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : bool
  (let
    [sidecar : tc_core.TcTypeEnvScopedSidecar carrier.sidecar]
    [stack : tc_core.TcTypeEnvScopedStack
      (tc_core.tc-global-shared-view sidecar.stack)]
    (if (>= (tc_core.tc-type-env-scoped-stack-lookup-index stack name-id) 0)
      true
      (tc-name-bound-persistent-id?
        (tc_core.tc-type-env-scoped-sidecar-persistent sidecar)
        name-id))))

(define (tc-type-env-scoped-carrier-bind-alias-id-if-free
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]
  [ty : ast.AstType]) : tc_core.TcTypeEnvScopedCarrier
  (if (tc-type-env-scoped-carrier-name-bound-id?
    (tc_core.tc-global-shared-view carrier)
    name-id)
    carrier
    (tc_core.tc-type-env-scoped-carrier-bind-id carrier name-id ty)))

(define (tc-type-env-scoped-carrier-lookup-unsafe-id
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : tc_core.ResultTcTypeUnsafe
  (let
    [sidecar : tc_core.TcTypeEnvScopedSidecar carrier.sidecar]
    [stack : tc_core.TcTypeEnvScopedStack
      (tc_core.tc-global-shared-view sidecar.stack)]
    [index : i64 (tc_core.tc-type-env-scoped-stack-lookup-index stack name-id)]
    (if (>= index 0)
      (let
        [slot : tc_core.TcTypeEnvScopedSlot
          (tc_core.tc-global-array-element-shared-view stack.slots index)]
        (Ok
          slot.ty
          (tc_core.tc-type-env-scoped-flag?
            slot.flags
            tc_core.tc-type-env-scoped-flag-unsafe)))
      (tc-lookup-unsafe-persistent-id
        (tc_core.tc-type-env-scoped-sidecar-persistent sidecar)
        name-id))))

(define (tc-type-env-scoped-carrier-binding-unsafe-id?
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : bool
  (match (tc-type-env-scoped-carrier-lookup-unsafe-id carrier name-id)
    [(Ok _ unsafe) unsafe]
    [(Err _) false]))

(define (tc-type-env-scoped-carrier-ordinary-arena-owner-active?
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : bool
  (tc_core.tc-type-env-scoped-carrier-arena-owner-active?
    carrier
    name-id
    (tc_core.tc-ordinary-arena-owner-marker-id)))

(define (tc-type-env-scoped-carrier-atomic-arena-owner-active?
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : bool
  (tc_core.tc-type-env-scoped-carrier-arena-owner-active?
    carrier
    name-id
    (tc_core.tc-atomic-arena-owner-marker-id)))

(cfg
  test
  (define (tc-stdlib-comptime-syntax-test-is?
    [name-id : i64]
    [want : ast.AstType]) : bool
    (match (tc_core.tc-stdlib-comptime-syntax-type-id
      (tc_core.tc-stdlib-comptime-type-key-id "" name-id))
      [(Some ty)
        (tc_core.tc-type-eq
          (ast.ast-node-pool-reader-type-segment-bases)
          ty
          want)]
      [(No) false])))

(cfg
  test
  (define (tc-stdlib-comptime-syntax-test-none? [canonical-id : i64]) : bool
    (match (tc_core.tc-stdlib-comptime-syntax-type-id canonical-id)
      [(Some _) false]
      [(No) true])))

;; The decomposition must agree with the key constructor for every syntax type
;; and reject every other shape that carries one of the same ids.
(test
  tc-stdlib-comptime-syntax-type-id-decomposes-key
  (unless
    (and
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        true)
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-Expr
        (Expr))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-ExprList
        (ExprList))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-ExprClause
        (tc_core.tc-macro-expr-clause-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-ExprClauseList
        (tc_core.tc-macro-expr-clause-list-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-ExprBindingClause
        (tc_core.tc-macro-expr-binding-clause-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-ExprBindingClauseList
        (tc_core.tc-macro-expr-binding-clause-list-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-Pattern
        (tc_core.tc-macro-pattern-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-PatternList
        (tc_core.tc-macro-pattern-list-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-MatchArm
        (tc_core.tc-macro-match-arm-type))
      (tc-stdlib-comptime-syntax-test-is?
        cbi.compiler-builtin-id-fix-MatchArmList
        (tc_core.tc-macro-match-arm-list-type))
      ;; A bare base id, the right base under another module, a non-syntax base
      ;; under the right module, a triple key and an invalid id are all misses.
      (tc-stdlib-comptime-syntax-test-none? cbi.compiler-builtin-id-fix-Expr)
      (tc-stdlib-comptime-syntax-test-none?
        (tc_core.tc-qualified-name-key-id
          cbi.compiler-builtin-id-fix-stdlib
          cbi.compiler-builtin-id-fix-Expr))
      (tc-stdlib-comptime-syntax-test-none?
        (tc_core.tc-stdlib-comptime-type-key-id
          ""
          cbi.compiler-builtin-id-fix-string))
      (tc-stdlib-comptime-syntax-test-none?
        (csym.compiler-composite-triple-key-id
          cbi.compiler-builtin-id-fix-stdlib_dot_comptime
          cbi.compiler-builtin-id-fix-Expr
          cbi.compiler-builtin-id-fix-Expr))
      (tc-stdlib-comptime-syntax-test-none? -1))
    (io.panic
      "typecheck: stdlib comptime syntax type key decomposition disagrees")))

(define (tc-name-bound-persistent-id? [env : tc_core.TcTypeEnv] [name-id : i64]) : bool
  (tc_core.tc-name-bound-persistent-key-id?
    env
    (tc_core.tc-env-name-key-id
      (tc_core.tc-type-env-structural-session env)
      name-id)))

(define (tc-lookup-unsafe-persistent-id
  [env : tc_core.TcTypeEnv]
  [name-id : i64]) : tc_core.ResultTcTypeUnsafe
  (tc_core.tc-lookup-unsafe-persistent-key-id
    env
    (tc_core.tc-env-name-key-id
      (tc_core.tc-type-env-structural-session env)
      name-id)
    name-id))

(define (tc-lookup-hygiene-global-id [env : tc_core.TcTypeEnv] [name-id : i64]) : tc_core.ResultTcType
  (tc_core.tc-lookup-hygiene-global-key-scan
    env
    env
    (tc_core.tc-env-name-key-id
      (tc_core.tc-type-env-structural-session env)
      name-id)
    name-id))

(define (tc-lookup-dotted-source-visible
  [ctx : tc_core.TcContext]
  [env : tc_core.TcTypeEnv]
  [name : String]
  [name-id : i64]) : tc_core.ResultTcType
  (tc_core.tc-lookup-dotted-source-visible-mode ctx env name name-id false))

(define (tc-bind-cleanup-owner [env : tc_core.TcTypeEnv] [name-id : i64]) : tc_core.TcTypeEnv
  (tc_core.tc-bind-runtime-marker-id
    env
    (tc_core.tc-cleanup-owner-marker-id)
    (Var name-id)
    CleanupOwner))

(test
  tc-type-render-hides-elaborated-lifetimes
  (let
    [hidden : i64 (tc_core.tc-elided-lifetime-name 0)]
    [named : i64 (ci.intern "named")]
    (if (and
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-node-pool-reader-type-segment-bases)
          (ast.ast-ty-ref hidden (I64)))
        "(& i64)")
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-node-pool-reader-type-segment-bases)
          (ast.ast-ty-mut-ref hidden (I64)))
        "(&mut i64)")
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-node-pool-reader-type-segment-bases)
          (ast.ast-ty-ref named (I64)))
        "(& named i64)"))
      unit
      (io.panic "typecheck: elaborated lifetime leaked through type rendering"))))

;; The storage of the parameter list eliding a `count`-parameter signature, or
;; -1 when elision fails or changes the count.
(define (tc-elided-signature-param-capacity [count : i64]) : i64
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-active-live)]
    [params : ast.AstParamList (ast.ast-param-list-with-capacity 0)]
    [index : i64 0]
    (while (< index count)
      (ast.ast-param-list-push
        (&mut params)
        (ast.ast-param-id (ci.intern "elided") (I64) false))
      (set! index (+ index 1)))
    (match (tc_core.tc-elide-function-signature pools params (I64))
      [(Ok signature)
        (if (= (ast.ast-param-list-len (& signature.params)) count)
          (array-length signature.params.slots)
          -1)]
      [(Err _) -1])))

;; Elision reserves the elided list at its final length, so it leaves no
;; outgrown storage behind (#7943).
(test
  tc-elided-signature-params-reserve-exactly
  (if (and
    (= (tc-elided-signature-param-capacity 0) 0)
    (= (tc-elided-signature-param-capacity 1) 1)
    (= (tc-elided-signature-param-capacity 3) 3)
    (= (tc-elided-signature-param-capacity 9) 9))
    unit
    (io.panic
      "typecheck: an elided parameter list should reserve exactly its length")))

;; Standalone helpers retain their serial compatibility surface. Production
;; typecheck paths use the explicit job/pool or context variants below.
(define (tc-type-needs-resolution-id? [ty-id : i64]) : bool
  (let
    [state : tc_core.TcTypeResolutionCacheState
      (tc_core.tc-job-state-type-resolution-cache (tc_core.tc-serial-job-state))]
    (tc_core.tc-type-resolution-cache-bind-active-for-state! state)
    (tc_core.tc-type-needs-resolution-id-for-state? state ty-id)))

;; Uncached explicit-pool compatibility twin. Production contexts use the
;; job-owned memo below; standalone pool-isolation tests retain this raw worker.
(define (tc-type-list-needs-resolution-with-bases?
  [type-bases : i64]
  [types : ast.AstTypeList]) : bool
  (tc-type-list-needs-resolution-at-with-bases? type-bases (& types) 0))

(define (tc-type-list-needs-resolution-at-with-bases?
  [type-bases : i64]
  [types : (& types ast.AstTypeList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-type-list-len types))
    false
    (if (tc-type-needs-resolution-id-with-bases?
      type-bases
      (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
      true
      (tc-type-list-needs-resolution-at-with-bases?
        type-bases
        types
        (+ index 1)))))

(define (tc-type-needs-resolution-id-with-bases?
  [type-bases : i64]
  [ty-id : i64]) : bool
  (tc-type-needs-resolution-with-bases?
    type-bases
    (ast.ast-type-segment-bases-get type-bases ty-id)))

(define (tc-type-needs-resolution-with-bases?
  [type-bases : i64]
  [ty : ast.AstType]) : bool
  (match ty
    [(Func args ret)
      (if (tc-type-list-needs-resolution-with-bases?
        type-bases
        (ast.ast-type-list-box-shared-view args))
        true
        (tc-type-needs-resolution-id-with-bases? type-bases ret))]
    [(Tuple elems)
      (tc-type-list-needs-resolution-with-bases?
        type-bases
        (ast.ast-type-list-box-shared-view elems))]
    [(Array elem _) (tc-type-needs-resolution-id-with-bases? type-bases elem)]
    [(DynArray elem) (tc-type-needs-resolution-id-with-bases? type-bases elem)]
    [(Slice elem) (tc-type-needs-resolution-id-with-bases? type-bases elem)]
    [(Box elem) (tc-type-needs-resolution-id-with-bases? type-bases elem)]
    [(Ptr elem) (tc-type-needs-resolution-id-with-bases? type-bases elem)]
    [(MutPtr elem) (tc-type-needs-resolution-id-with-bases? type-bases elem)]
    [(Ref _ inner) (tc-type-needs-resolution-id-with-bases? type-bases inner)]
    [(MutRef _ inner)
      (tc-type-needs-resolution-id-with-bases? type-bases inner)]
    [(Region _ inner)
      (tc-type-needs-resolution-id-with-bases? type-bases inner)]
    [(VarArgs _ _) true]
    [(Var _) true]
    [_ false]))

(test
  tc-source-slash-qualified-negative-name
  (test.assert-false
    (tc_core.tc-source-slash-qualified-id?
      (cis.InternStructuralSessionHandle 0)
      "__internal"
      -1)
    "negative internal names stay outside intern metadata"))

(define (tc-source-dotted-alias-key-cache-get [module-id : i64] [name-id : i64]) : i64
  (tc_core.tc-source-dotted-alias-key-cache-get-for-state
    (tc_core.tc-job-state-source-key-cache (tc_core.tc-serial-job-state))
    (ci.intern-active-table-id)
    (ci.intern-generation)
    module-id
    name-id))

(define (tc-source-dotted-full-path-key-cache-get
  [module-id : i64]
  [name-id : i64]) : i64
  (tc_core.tc-source-dotted-full-path-key-cache-get-for-state
    (tc_core.tc-job-state-source-key-cache (tc_core.tc-serial-job-state))
    (ci.intern-active-table-id)
    (ci.intern-generation)
    module-id
    name-id))

(define (tc-source-qualified-variant-key-cache-get
  [registry-id : i64]
  [module-id : i64]
  [name-id : i64]) : i64
  (tc_core.tc-source-qualified-variant-key-cache-get-for-state
    (tc_core.tc-job-state-source-key-cache (tc_core.tc-serial-job-state))
    (ci.intern-active-table-id)
    (ci.intern-generation)
    registry-id
    module-id
    name-id))

(define (tc-source-dotted-alias-key-cache-put!
  [module-id : i64]
  [name-id : i64]
  [value : i64]) : unit
  (tc_core.tc-source-dotted-alias-key-cache-put-for-state!
    (tc_core.tc-job-state-source-key-cache (tc_core.tc-serial-job-state))
    (ci.intern-active-table-id)
    (ci.intern-generation)
    module-id
    name-id
    value))

(define (tc-source-dotted-full-path-key-cache-put!
  [module-id : i64]
  [name-id : i64]
  [value : i64]) : unit
  (tc_core.tc-source-dotted-full-path-key-cache-put-for-state!
    (tc_core.tc-job-state-source-key-cache (tc_core.tc-serial-job-state))
    (ci.intern-active-table-id)
    (ci.intern-generation)
    module-id
    name-id
    value))

(define (tc-source-qualified-variant-key-cache-put!
  [registry-id : i64]
  [module-id : i64]
  [name-id : i64]
  [value : i64]
  [handle : i64]) : unit
  (tc_core.tc-source-qualified-variant-key-cache-put-for-state!
    (tc_core.tc-job-state-source-key-cache (tc_core.tc-serial-job-state))
    (ci.intern-active-table-id)
    (ci.intern-generation)
    registry-id
    module-id
    name-id
    value
    handle))

(define (tc-lazy-import-summary-backed-stub-count-for-state
  [state : tc_core.TcMacroState]) : i64
  (let
    [lazy-state : tc_core.TcLazyImportState
      (tc_core.tc-macro-state-lazy-import state)]
    [_ready : unit
      (tc_core.tc-lazy-import-stubs-ensure-for-state! state lazy-state)]
    (__tl-project-field
      (tc_core.tc-lazy-import-state-data lazy-state)
      summary-backed-count)))

;; Standalone source APIs and focused smokes use the serial compatibility job.
(define (tc-lazy-import-stub-count) : i64
  (tc_core.tc-lazy-import-stub-count-for-state
    (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))))

(define (tc-lazy-import-summary-backed-stub-count) : i64
  (tc-lazy-import-summary-backed-stub-count-for-state
    (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))))

(define (tc-lazy-import-summary-macro-force-count) : i64
  (tc_core.tc-lazy-import-summary-macro-force-count-for-state
    (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))))

(define (tc-type-handle-cache-entry-lookup
  [state : tc_core.TcTypeHandleCacheState]
  [key : i64]) : TcTypeHandleCacheLookup
  (let
    [data : tc_core.TcTypeHandleCacheStateData
      (tc_core.tc-type-handle-cache-state-data state)]
    (if (> data.keys-address 0)
      (let
        [slot : i64 (tc_core.tc-type-handle-cache-slot key)]
        [keys : (Ptr i64)
          (unsafe
            (int->ptr (cast data.keys-address : u64) : (Ptr i64)))]
        [handles : (Ptr i64)
          (unsafe
            (int->ptr (cast data.handles-address : u64) : (Ptr i64)))]
        (if (=
          (unsafe
            (ptr-read (ptr-offset keys slot)))
          key)
          (Hit
            (unsafe
              (ptr-read (ptr-offset handles slot))))
          Miss))
      Miss)))

(cfg
  test
  (test
    tc-type-handle-cache-job-isolation-and-symbol-rebinding
    (let
      [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-growth : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state-a : tc_core.TcNominalCacheState
        (tc_core.tc-job-state-nominal-cache job-a)]
      [state-b : tc_core.TcNominalCacheState
        (tc_core.tc-job-state-nominal-cache job-b)]
      [state-growth : tc_core.TcNominalCacheState
        (tc_core.tc-job-state-nominal-cache job-growth)]
      [name-id : i64 137]
      [cache-key : i64 name-id]
      [map-key : i64 (csym.compiler-symbol-name-id-key name-id)]
      [symbols-a : csym.CompilerSymbols
        (csym.compiler-symbols-add-type-alias-key-id
          (csym.compiler-symbols-empty)
          map-key
          101)]
      [symbols-b : csym.CompilerSymbols
        (csym.compiler-symbols-add-type-alias-key-id
          (csym.compiler-symbols-empty)
          map-key
          202)]
      [symbols-growth : csym.CompilerSymbols (csym.compiler-symbols-empty)]
      [stamp-a : csym.CompilerSymbolsTypeMapStamp
        (csym.compiler-symbols-type-map-stamp (& symbols-a))]
      [stamp-b : csym.CompilerSymbolsTypeMapStamp
        (csym.compiler-symbols-type-map-stamp (& symbols-b))]
      [positive-a : i64
        (tc_core.tc-type-handle-lookup-id
          state-a
          (& symbols-a)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [positive-a-hit : i64
        (tc_core.tc-type-handle-lookup-id
          state-a
          (& symbols-a)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [positive-a-entry? : bool
        (match (tc-type-handle-cache-entry-lookup
          (tc_core.tc-nominal-cache-type-handles state-a)
          cache-key)
          [(Hit handle) (= handle 101)]
          [(Miss) false])]
      [positive-b : i64
        (tc_core.tc-type-handle-lookup-id
          state-b
          (& symbols-b)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [positive-b-hit : i64
        (tc_core.tc-type-handle-lookup-id
          state-b
          (& symbols-b)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [negative : i64
        (tc_core.tc-type-handle-lookup-id
          state-growth
          (& symbols-growth)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [negative-hit : i64
        (tc_core.tc-type-handle-lookup-id
          state-growth
          (& symbols-growth)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [negative-entry? : bool
        (match (tc-type-handle-cache-entry-lookup
          (tc_core.tc-nominal-cache-type-handles state-growth)
          cache-key)
          [(Hit handle) (= handle -1)]
          [(Miss) false])]
      [growth-before : csym.CompilerSymbolsTypeMapStamp
        (csym.compiler-symbols-type-map-stamp (& symbols-growth))]
      [symbols-growth-next : csym.CompilerSymbols
        (csym.compiler-symbols-add-type-alias-key-id symbols-growth map-key 303)]
      [growth-after : csym.CompilerSymbolsTypeMapStamp
        (csym.compiler-symbols-type-map-stamp (& symbols-growth-next))]
      [after-add : i64
        (tc_core.tc-type-handle-lookup-id
          state-growth
          (& symbols-growth-next)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [owner-rebound : i64
        (tc_core.tc-type-handle-lookup-id
          state-a
          (& symbols-b)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [owner-returned : i64
        (tc_core.tc-type-handle-lookup-id
          state-a
          (& symbols-a)
          name-id
          tc_core.tc-type-handle-lookup-caller-resolver)]
      [data-a : tc_core.TcTypeHandleCacheStateData
        (tc_core.tc-type-handle-cache-state-data
          (tc_core.tc-nominal-cache-type-handles state-a))]
      [data-b : tc_core.TcTypeHandleCacheStateData
        (tc_core.tc-type-handle-cache-state-data
          (tc_core.tc-nominal-cache-type-handles state-b))]
      [data-growth : tc_core.TcTypeHandleCacheStateData
        (tc_core.tc-type-handle-cache-state-data
          (tc_core.tc-nominal-cache-type-handles state-growth))]
      (if (and
        (not (= state-a.address state-b.address))
        (not (= stamp-a.owner stamp-b.owner))
        (= positive-a 101)
        (= positive-a-hit 101)
        positive-a-entry?
        (= positive-b 202)
        (= positive-b-hit 202)
        (= negative -1)
        (= negative-hit -1)
        negative-entry?
        (= growth-before.owner growth-after.owner)
        (= growth-after.generation (+ growth-before.generation 1))
        (= after-add 303)
        (= owner-rebound 202)
        (= owner-returned 101)
        (= data-a.symbols-owner stamp-a.owner)
        (= data-a.symbols-generation stamp-a.generation)
        (= data-b.symbols-owner stamp-b.owner)
        (= data-b.symbols-generation stamp-b.generation)
        (= data-growth.symbols-owner growth-after.owner)
        (= data-growth.symbols-generation growth-after.generation))
        unit
        (io.panic
          "typecheck: type-handle cache isolation/rebinding self-test failed")))))

;; The first id after START whose cache slot equals KEY's, so a lookup of it
;; evicts KEY's entry.
(define (tc-type-handle-cache-colliding-id [key : i64] [start : i64]) : i64
  (if (and
    (not (= start key))
    (=
      (tc_core.tc-type-handle-cache-slot start)
      (tc_core.tc-type-handle-cache-slot key)))
    start
    (tc-type-handle-cache-colliding-id key (+ start 1))))

(cfg
  test
  (test
    tc-type-handle-cache-move-kind-lane-follows-key-and-stamp
    (let
      [job : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state : tc_core.TcNominalCacheState
        (tc_core.tc-job-state-nominal-cache job)]
      [name-id : i64 137]
      [map-key : i64 (csym.compiler-symbol-name-id-key name-id)]
      [symbols-a : csym.CompilerSymbols
        (csym.compiler-symbols-add-type-alias-key-id
          (csym.compiler-symbols-empty)
          map-key
          101)]
      [symbols-b : csym.CompilerSymbols
        (csym.compiler-symbols-add-type-alias-key-id
          (csym.compiler-symbols-empty)
          map-key
          202)]
      ;; An unbound cache neither answers nor records a kind.
      [unbound-set : unit
        (tc_core.tc-type-handle-cache-move-kind-set!
          state
          (& symbols-a)
          name-id
          2)]
      [unbound : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-a) name-id)]
      [_bind : i64
        (tc_core.tc-type-handle-lookup-id
          state
          (& symbols-a)
          name-id
          tc_core.tc-type-handle-lookup-caller-move-kind)]
      [fresh : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-a) name-id)]
      [_record : unit
        (tc_core.tc-type-handle-cache-move-kind-set!
          state
          (& symbols-a)
          name-id
          2)]
      [recorded : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-a) name-id)]
      ;; A key that is not the slot's current key is not recorded.
      [other-id : i64 (tc-type-handle-cache-colliding-id name-id 1)]
      [_absent-set : unit
        (tc_core.tc-type-handle-cache-move-kind-set!
          state
          (& symbols-a)
          other-id
          1)]
      [still-recorded : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-a) name-id)]
      ;; Another stamp neither sees the kind nor, once rebound, keeps it.
      [other-stamp : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-b) name-id)]
      [_rebind : i64
        (tc_core.tc-type-handle-lookup-id
          state
          (& symbols-b)
          name-id
          tc_core.tc-type-handle-lookup-caller-move-kind)]
      [rebound : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-b) name-id)]
      [_record-b : unit
        (tc_core.tc-type-handle-cache-move-kind-set!
          state
          (& symbols-b)
          name-id
          1)]
      ;; Evicting the slot resets the kind for both the old and the new key.
      [_evict : i64
        (tc_core.tc-type-handle-lookup-id
          state
          (& symbols-b)
          other-id
          tc_core.tc-type-handle-lookup-caller-move-kind)]
      [evicted : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-b) name-id)]
      [evictor : i64
        (tc_core.tc-type-handle-cache-move-kind state (& symbols-b) other-id)]
      (if (and
        (= unbound 0)
        (= fresh 0)
        (= recorded 2)
        (= still-recorded 2)
        (= other-stamp 0)
        (= rebound 0)
        (= evicted 0)
        (= evictor 0))
        unit
        (io.panic
          "typecheck: type-handle cache move-kind lane self-test failed")))))

(define (tc-spmd-env-pop [env : tc_core.TcSpmdEnv] [count : i64]) : tc_core.TcSpmdEnv
  (if (<= count 0)
    env
    (let
      [next-len : i64 (- (tc_core.tc-spmd-env-len env) count)]
      (tc_core.tc-spmd-env-restore env (tc_core.TcSpmdEnvMark next-len)))))

(define (tc-type-env-cache-raw-fields-match? [env : tc_core.TcTypeEnv]) : bool
  (let
    [cache-ptr : (Ptr tc_core.TcTypeEnvCache)
      (tc_core.tc-type-env-cache-ptr
        env.store
        (tc_core.tc-type-env-cache-index env.head))]
    [cache : tc_core.TcTypeEnvCache (tc_core.tc-type-env-cache-at cache-ptr)]
    [raw-shadow : (__tl_dyn-array i64)
      (tc_core.tc-type-env-cache-field-at cache-ptr 72 (__tl_dyn-array i64))]
    (and
      (unsafe
        (=
          (ptr->int (__tl_array-data raw-shadow))
          (ptr->int (__tl_array-data cache.shadow-flags))))
      (=
        (tc_core.tc-type-env-cache-field-at cache-ptr 80 bool)
        cache.scan-through)
      (= (tc_core.tc-type-env-cache-field-at cache-ptr 81 bool) cache.partial)
      (= (tc_core.tc-type-env-cache-field-at cache-ptr 88 i64) cache.rest)
      (= (tc_core.tc-type-env-cache-field-at cache-ptr 96 i64) cache.below))))

(define (tc-type-env-cache-raw-fields-smoke?) : bool
  (let
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id
          (tc_core.tc-empty-env)
          (ci.intern "raw-cache-base")
          (I64)))]
    [layer : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache-layer-over-explicit
        (tc_core.tc-bind-id base (ci.intern "raw-cache-layer") (Bool)))]
    (and
      (tc-type-env-cache-raw-fields-match? base)
      (tc-type-env-cache-raw-fields-match? layer))))

(define (tc-type-env-raw-layout-smoke?) : bool
  (and
    (tc-type-env-cache-raw-fields-smoke?)
    (= (comptime (offset-of (type TcTypeEnvBinding) name-id)) 0)
    (= (comptime (offset-of (type TcTypeEnvBinding) ty)) 8)
    (= (comptime (offset-of (type TcTypeEnvBinding) parent)) 32)
    (= (comptime (offset-of (type TcTypeEnvStore) bindings)) 0)
    (= (comptime (offset-of (type TcTypeEnvStore) binding-capacity)) 8)
    (= (comptime (offset-of (type TcTypeEnvStore) binding-len)) 16)
    (=
      (comptime
        (offset-of (type TcTypeEnvStore) topenv-membership-state-address))
      56)
    (= (comptime (offset-of (type TcTypeEnvStore) chain-state)) 64)
    (=
      (comptime (offset-of (type TcTypeEnvStore) structural-session-address))
      72)
    (=
      (comptime
        (offset-of (type TcTypeEnvStore) type-resolution-cache-state-address))
      80)
    ;; The structural top-env index reads these four through raw word offsets,
    ;; so they must stay first and stay one word wide.
    (= (comptime (offset-of (type TcTypeEnvCache) chain-depth)) 0)
    (= (comptime (offset-of (type TcTypeEnvCache) chain-seq)) 8)
    (= (comptime (offset-of (type TcTypeEnvCache) chain-jumps-address)) 16)
    (= (comptime (offset-of (type TcTypeEnvCache) chain-prev-address)) 24)))

(define (tc-type-env-owner-arena-smoke?) : bool
  (let
    [base-id : i64 (ci.intern "owner-arena-base")]
    [filler-id : i64 (ci.intern "owner-arena-filler")]
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make_small)]
    [scratch : i64 (arena.tl_arena_make_small)]
    [_owner-current : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-bind-id (tc_core.tc-empty-env) base-id (String))]
    [first-cache : tc_core.TcTypeEnv (tc_core.tc-env-with-cache base)]
    [grown : tc_core.TcTypeEnv
      (tc_core.TcTypeEnv base.store base.head base.abi-pad)]
    [latest-cache : tc_core.TcTypeEnv
      (tc_core.TcTypeEnv first-cache.store first-cache.head first-cache.abi-pad)]
    [index : i64 0]
    [cache-index : i64 0]
    [binding-restored? : bool false]
    [latest-cache-valid? : bool false]
    (unsafe
      (arena.tl_arena_set scratch))
    ;; Extend a store created in `owner` while an unrelated scratch arena is
    ;; current. Segment allocation must use the store owner and restore the
    ;; scratch arena before returning.
    (while (< index (+ (tc_core.tc-type-env-binding-segment-capacity) 8))
      (set! grown (tc_core.tc-bind-id grown filler-id (I64)))
      (set! index (+ index 1)))
    (set! binding-restored? (= (arena.tl_arena_current) scratch))
    ;; Exercise cache-segment rollover through the same owner switch. The
    ;; newer cache payloads intentionally live only until scratch is
    ;; destroyed; `first-cache` was built in owner and must remain valid.
    (while (< cache-index (+ (tc_core.tc-type-env-cache-segment-capacity) 2))
      (set! latest-cache (tc_core.tc-env-with-cache grown))
      (set! cache-index (+ cache-index 1)))
    (set!
      latest-cache-valid?
      (match (tc_core.tc-lookup-id latest-cache base-id)
        [(Ok (String)) true]
        [_ false]))
    (let
      [scratch-restored? : bool (= (arena.tl_arena_current) scratch)]
      (unsafe
        (arena.tl_arena_set home)
        (arena.tl_arena_destroy scratch))
      ;; Destroying scratch must not invalidate either the retained
      ;; first-segment snapshot or the head in the later owner segment.
      (let
        [base-alive? : bool
          (match (tc_core.tc-lookup-id base base-id)
            [(Ok (String)) true]
            [_ false])]
        [grown-alive? : bool
          (match (tc_core.tc-lookup-id grown base-id)
            [(Ok (String)) true]
            [_ false])]
        [first-cache-alive? : bool
          (match (tc_core.tc-lookup-id first-cache base-id)
            [(Ok (String)) true]
            [_ false])]
        (unsafe
          (arena.tl_arena_set home)
          (arena.tl_arena_destroy owner))
        (and
          binding-restored?
          scratch-restored?
          latest-cache-valid?
          base-alive?
          grown-alive?
          first-cache-alive?)))))

;; Entries in STORE-HANDLE's chain index, or -1 without one.
(define (tc-type-env-chain-index-len [store-handle : i64]) : i64
  (let
    [address : i64 (tc_core.tc-chain-state-address store-handle)]
    (if (> address 0)
      (let
        [state : tc_core.TcChainIndex (tc_core.tc-chain-state-read address)]
        (tc_i64_i64_map.len (& state.map)))
      -1)))

;; A function-local store fork (#8375) grows its bindings, cache layers and
;; chain index in the current scratch, sees every parent binding through the
;; inherited head, shares the parent's index until its first layer, and leaves
;; the parent's store, index and lookups unchanged after the scratch is
;; rewound. A parent without an index keeps none.
(define (tc-type-env-function-store-fork-smoke?) : bool
  (let
    [base-id : i64 (ci.intern "fork-parent-base")]
    [kept-id : i64 (ci.intern "fork-parent-kept")]
    [local-id : i64 (ci.intern "fork-local")]
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make_small)]
    [scratch : i64 (arena.tl_arena_make_small)]
    [_owner-current : unit
      (unsafe
        (arena.tl_arena_set owner))]
    [parent : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id
          (tc_core.tc-bind-id (tc_core.tc-empty-env) base-id (String))
          kept-id
          (I64)))]
    [plain : tc_core.TcTypeEnv
      (tc_core.tc-bind-id (tc_core.tc-empty-env) base-id (String))]
    [parent-store : tc_core.TcTypeEnvStore
      (tc_core.tc-type-env-store-read parent.store)]
    [parent-chain : i64 (tc_core.tc-chain-state-address parent.store)]
    [parent-chain-len : i64 (tc-type-env-chain-index-len parent.store)]
    [fork-ok : bool false]
    (unsafe
      (arena.tl_arena_set scratch))
    (let
      [mark : i64 (arena.tl_region_mark)]
      [reader : tc_core.TcTypeEnv
        (tc_core.tc-type-env-fork-function-store parent)]
      [fork : tc_core.TcTypeEnv
        (tc_core.tc-type-env-fork-function-store parent)]
      [plain-fork : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-type-env-fork-function-store plain))]
      [index : i64 0]
      ;; Shadow a parent name, then cross two binding segments and several
      ;; cache segments.
      (set! fork (tc_core.tc-bind-id fork base-id (Bool)))
      (while (< index (+ (tc_core.tc-type-env-binding-segment-capacity) 8))
        (set! fork (tc_core.tc-bind-id fork local-id (I64)))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index (+ (tc_core.tc-type-env-cache-segment-capacity) 2))
        (set! fork (tc_core.tc-env-with-cache fork))
        (set! index (+ index 1)))
      (set!
        fork-ok
        (and
          (match (tc_core.tc-lookup-id fork base-id)
            [(Ok (Bool)) true]
            [_ false])
          (match (tc_core.tc-lookup-id fork kept-id)
            [(Ok (I64)) true]
            [_ false])
          (match (tc_core.tc-lookup-id fork local-id)
            [(Ok (I64)) true]
            [_ false])
          (match (tc_core.tc-lookup-id reader base-id)
            [(Ok (String)) true]
            [_ false])
          (= (tc_core.tc-chain-state-address reader.store) parent-chain)
          (= (tc_core.tc-chain-store-owner fork.store) scratch)
          (> (tc_core.tc-chain-state-address fork.store) 0)
          (not (= (tc_core.tc-chain-state-address fork.store) parent-chain))
          (>= (tc-type-env-chain-index-len fork.store) parent-chain-len)
          (> (tc_core.tc-chain-state-address plain-fork.store) 0)
          (match (tc_core.tc-lookup-id plain-fork base-id)
            [(Ok (String)) true]
            [_ false])))
      (unsafe
        (arena.tl_region_reset mark)))
    (unsafe
      (arena.tl_arena_set home)
      (arena.tl_arena_destroy scratch))
    (let
      [after : tc_core.TcTypeEnvStore
        (tc_core.tc-type-env-store-read parent.store)]
      [after-chain : i64 (tc_core.tc-chain-state-address parent.store)]
      [result : bool
        (and
          fork-ok
          (> parent-chain-len 0)
          (= after.binding-len parent-store.binding-len)
          (= after.cache-len parent-store.cache-len)
          (= after-chain parent-chain)
          (= (tc-type-env-chain-index-len parent.store) parent-chain-len)
          (= (tc_core.tc-chain-state-address plain.store) 0)
          (match (tc_core.tc-lookup-id parent base-id)
            [(Ok (String)) true]
            [_ false])
          (match (tc_core.tc-lookup-id parent kept-id)
            [(Ok (I64)) true]
            [_ false])
          (match (tc_core.tc-lookup-id parent local-id)
            [(Ok _) false]
            [_ true]))]
      (unsafe
        (arena.tl_arena_set home)
        (arena.tl_arena_destroy owner))
      result)))

(test
  tc-type-env-function-store-fork
  (test.assert-true
    (tc-type-env-function-store-fork-smoke?)
    "a function-local store fork never touches its parent's store or index"))

(define (tc-type-env-segmented-snapshot-smoke?) : bool
  (let
    [branch-id : i64 (ci.intern "branch")]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-bind-id (tc_core.tc-empty-env) (ci.intern "base") (String))]
    [left : tc_core.TcTypeEnv (tc_core.tc-bind-id base branch-id (I64))]
    [right : tc_core.TcTypeEnv (tc_core.tc-bind-id base branch-id (Bool))]
    [left-cached : tc_core.TcTypeEnv (tc_core.tc-env-with-cache left)]
    [right-cached : tc_core.TcTypeEnv (tc_core.tc-env-with-cache right)]
    [segment-id : i64 (ci.intern "segment-base")]
    [segment-base : tc_core.TcTypeEnv
      (tc_core.tc-bind-id (tc_core.tc-empty-env) segment-id (String))]
    [segment-grown : tc_core.TcTypeEnv
      (tc_core.TcTypeEnv
        segment-base.store
        segment-base.head
        segment-base.abi-pad)]
    [segment-index : i64 0]
    [cache-segment-id : i64 (ci.intern "cache-segment-base")]
    [cache-segment-base : tc_core.TcTypeEnv
      (tc_core.tc-bind-id (tc_core.tc-empty-env) cache-segment-id (String))]
    [cache-segment-first : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache cache-segment-base)]
    [cache-segment-latest : tc_core.TcTypeEnv
      (tc_core.TcTypeEnv
        cache-segment-first.store
        cache-segment-first.head
        cache-segment-first.abi-pad)]
    [cache-segment-index : i64 0]
    [env : tc_core.TcTypeEnv
      (tc_core.tc-bind-return-type
        (tc_core.tc-bind-id
          (tc_core.tc-bind-id
            (tc_core.tc-push-region-id
              (tc_core.tc-empty-env)
              (ci.intern "arena"))
            (ci.intern "x")
            (I64))
          (ci.intern "x")
          (Bool))
        (I64))]
    [cached : tc_core.TcTypeEnv (tc_core.tc-env-with-cache env)]
    ;; Force more than one binding segment, then branch from the retained
    ;; first-segment snapshot after the store has advanced.
    (while (<
      segment-index
      (+ (tc_core.tc-type-env-binding-segment-capacity) 8))
      (set!
        segment-grown
        (tc_core.tc-bind-id
          segment-grown
          (ci.intern
            (str_cat.str-cat "segment-" (string.int->string segment-index)))
          (I64)))
      (set! segment-index (+ segment-index 1)))
    (while (<
      cache-segment-index
      (+ (tc_core.tc-type-env-cache-segment-capacity) 2))
      (set!
        cache-segment-latest
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            cache-segment-base
            (ci.intern
              (str_cat.str-cat
                "cache-segment-"
                (string.int->string cache-segment-index)))
            (I64))))
      (set! cache-segment-index (+ cache-segment-index 1)))
    (let
      [segment-sibling : tc_core.TcTypeEnv
        (tc_core.tc-bind-id segment-base segment-id (Bool))]
      (and
        (tc-type-env-raw-layout-smoke?)
        (tc-type-env-owner-arena-smoke?)
        (match (tc_core.tc-lookup-id base branch-id)
          [(Err _) true]
          [_ false])
        (match (tc_core.tc-lookup-id left branch-id)
          [(Ok (I64)) true]
          [_ false])
        (match (tc_core.tc-lookup-id right branch-id)
          [(Ok (Bool)) true]
          [_ false])
        (match (tc_core.tc-lookup-id left-cached branch-id)
          [(Ok (I64)) true]
          [_ false])
        (match (tc_core.tc-lookup-id right-cached branch-id)
          [(Ok (Bool)) true]
          [_ false])
        (match (tc_core.tc-lookup-id segment-base segment-id)
          [(Ok (String)) true]
          [_ false])
        (match (tc_core.tc-lookup-id segment-grown segment-id)
          [(Ok (String)) true]
          [_ false])
        (match (tc_core.tc-lookup-id segment-sibling segment-id)
          [(Ok (Bool)) true]
          [_ false])
        (match (tc_core.tc-lookup-id cache-segment-first cache-segment-id)
          [(Ok (String)) true]
          [_ false])
        (match (tc_core.tc-lookup-id cache-segment-latest cache-segment-id)
          [(Ok (String)) true]
          [_ false])
        (= (tc_core.tc-env-cache-count cached) 4)
        (match (tc_core.tc-lookup-id cached (ci.intern "x"))
          [(Ok (Bool)) true]
          [_ false])
        (match (tc_core.tc-current-return-type env)
          [(Ok (I64)) true]
          [_ false])
        (match (tc_core.tc-active-region env)
          [(Some region) (= region (ci.intern "arena"))]
          [_ false])
        (tc_core.tc-lifetime-visible-id? env (ci.intern "arena"))))))

(test
  tc-type-env-segmented-snapshots
  (if (tc-type-env-segmented-snapshot-smoke?)
    unit
    (io.panic "typecheck: segmented environment snapshot smoke failed")))

(define (tc-type-env-cache-head? [env : tc_core.TcTypeEnv]) : bool
  (match (tc_core.tc-type-env-view env)
    [(Cache _ _ _ _ _) true]
    [_ false]))

(define (tc-type-env-cache-partial-head? [env : tc_core.TcTypeEnv]) : bool
  (match (tc_core.tc-type-env-view env)
    [(Cache _ _ partial _ _) partial]
    [_ false]))

(define (tc-type-env-bind-many [env : tc_core.TcTypeEnv] [count : i64]) : tc_core.TcTypeEnv
  (let
    [i : i64 0]
    [out : tc_core.TcTypeEnv env]
    (while (< i count)
      (set!
        out
        (tc_core.tc-bind-id
          out
          (ci.intern (str_cat.str-cat "local" (string.int->string i)))
          (I64)))
      (set! i (+ i 1)))
    out))

(defstruct TcTypeEnvBindManyEndpoints
  (env tc_core.TcTypeEnv)
  (first-id i64)
  (last-id i64))

(define (tc-type-env-bind-many-endpoints
  [env : tc_core.TcTypeEnv]
  [count : i64]) : TcTypeEnvBindManyEndpoints
  (let
    [i : i64 0]
    [out : tc_core.TcTypeEnv env]
    [first-id : i64 -1]
    [last-id : i64 -1]
    (while (< i count)
      (let
        [name-id : i64
          (ci.intern (str_cat.str-cat "local" (string.int->string i)))]
        (if (= i 0)
          (set! first-id name-id)
          unit)
        (set! last-id name-id)
        (set! out (tc_core.tc-bind-id out name-id (I64)))
        (set! i (+ i 1))))
    (TcTypeEnvBindManyEndpoints out first-id last-id)))

(define (tc-type-env-local-cache-behavior-smoke?) : bool
  (let
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id
          (tc_core.tc-empty-env)
          (ci.intern "global")
          (String)))]
    [marked : tc_core.TcTypeEnv
      (tc_core.tc-bind-return-type
        (tc_core.tc-bind-unsafe-id
          (tc_core.tc-push-region-id base (ci.intern "arena"))
          (ci.intern "danger")
          (I64))
        (I64))]
    [shadowed : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-id marked (ci.intern "shadow") (I64))
        (ci.intern "shadow")
        (Bool))]
    [cached : tc_core.TcTypeEnv
      (tc-type-env-bind-many shadowed (- (tc_core.tc-local-cache-threshold) 6))]
    (and
      (tc-type-env-cache-head? cached)
      (match (tc_core.tc-lookup-id cached (ci.intern "shadow"))
        [(Ok (Bool)) true]
        [_ false])
      (match (tc_core.tc-lookup-id cached (ci.intern "global"))
        [(Ok (String)) true]
        [_ false])
      (match (tc_core.tc-lookup-unsafe-id cached (ci.intern "danger"))
        [(Ok (I64) unsafe) unsafe]
        [_ false])
      (match (tc_core.tc-lookup-id cached (ci.intern "missing"))
        [(Err message)
          (string.eq
            message
            (cdiag.compiler-diagnostic-typecheck-tagged
              (UnboundName)
              "typecheck: unbound name missing"))]
        [_ false])
      (match (tc_core.tc-current-return-type cached)
        [(Ok (I64)) true]
        [_ false])
      (match (tc_core.tc-active-region cached)
        [(Some region) (= region (ci.intern "arena"))]
        [_ false])
      (tc_core.tc-lifetime-visible-id? cached (ci.intern "shadow")))))

(define (tc-type-env-local-cache-default-shadow-smoke?) : bool
  (let
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache (tc_core.tc-default-env))]
    [shadowed : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        base
        (ci.intern "__tl_string_length")
        (tc_core.tc-fn1 (I64) (I64)))]
    [cached : tc_core.TcTypeEnv
      (tc-type-env-bind-many shadowed (- (tc_core.tc-local-cache-threshold) 1))]
    (and
      (tc-type-env-cache-head? cached)
      (not
        (tc_core.tc-default-builtin-unshadowed-id?
          cached
          cbi.compiler-builtin-id-tl-private-string-length)))))

(define (tc-type-env-local-cache-partial-layer-smoke?) : bool
  (let
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id
          (tc_core.tc-empty-env)
          (ci.intern "global")
          (String)))]
    [layer1 : tc_core.TcTypeEnv
      (tc-type-env-bind-many base (tc_core.tc-local-cache-threshold))]
    [older-shadow : tc_core.TcTypeEnv
      (tc_core.tc-bind-id layer1 (ci.intern "shadow") (I64))]
    [layer2 : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        older-shadow
        (- (tc_core.tc-local-cache-threshold) 1))]
    [newer-shadow : tc_core.TcTypeEnv
      (tc_core.tc-bind-id layer2 (ci.intern "shadow") (Bool))]
    [layer3 : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        newer-shadow
        (- (tc_core.tc-local-cache-threshold) 1))]
    (and
      (tc-type-env-cache-partial-head? layer1)
      (tc-type-env-cache-partial-head? layer2)
      (tc-type-env-cache-partial-head? layer3)
      (= (tc_core.tc-env-partial-layer-depth layer3) 3)
      (match (tc_core.tc-lookup-id layer3 (ci.intern "global"))
        [(Ok (String)) true]
        [_ false])
      (match (tc_core.tc-lookup-id layer2 (ci.intern "shadow"))
        [(Ok (I64)) true]
        [_ false])
      (match (tc_core.tc-lookup-id layer3 (ci.intern "shadow"))
        [(Ok (Bool)) true]
        [_ false]))))

(define (tc-type-env-local-cache-default-shadow-partial-miss-smoke?) : bool
  (let
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache (tc_core.tc-default-env))]
    [shadowed : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        base
        (ci.intern "__tl_string_length")
        (tc_core.tc-fn1 (I64) (I64)))]
    [shadow-layer : tc_core.TcTypeEnv
      (tc-type-env-bind-many shadowed (- (tc_core.tc-local-cache-threshold) 1))]
    [miss-layer : tc_core.TcTypeEnv
      (tc-type-env-bind-many shadow-layer (tc_core.tc-local-cache-threshold))]
    [clear-layer : tc_core.TcTypeEnv
      (tc-type-env-bind-many base (tc_core.tc-local-cache-threshold))]
    (and
      (tc-type-env-cache-partial-head? shadow-layer)
      (tc-type-env-cache-partial-head? miss-layer)
      (tc-type-env-cache-partial-head? clear-layer)
      (not
        (tc_core.tc-default-builtin-unshadowed-id?
          shadow-layer
          cbi.compiler-builtin-id-tl-private-string-length))
      (not
        (tc_core.tc-default-builtin-unshadowed-id?
          miss-layer
          cbi.compiler-builtin-id-tl-private-string-length))
      (tc_core.tc-default-builtin-unshadowed-id?
        clear-layer
        cbi.compiler-builtin-id-tl-private-string-length))))

(define (tc-type-env-local-cache-depth-cap-smoke?) : bool
  (let
    [global-id : i64 (ci.intern "global")]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id (tc_core.tc-empty-env) global-id (String)))]
    [bound : TcTypeEnvBindManyEndpoints
      (tc-type-env-bind-many-endpoints
        base
        (*
          (tc_core.tc-local-cache-threshold)
          (+ (tc_core.tc-local-cache-partial-layer-cap) 1)))]
    [deep : tc_core.TcTypeEnv bound.env]
    [layered : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache-layer-over-explicit deep)]
    (and
      (tc-type-env-cache-head? deep)
      (tc-type-env-cache-partial-head? deep)
      (= (tc_core.tc-env-partial-layer-depth deep) 1)
      (=
        (tc_core.tc-env-partial-local-covered-count deep)
        (*
          (tc_core.tc-local-cache-threshold)
          (+ (tc_core.tc-local-cache-partial-layer-cap) 1)))
      (match (tc_core.tc-type-env-view (tc_core.tc-env-partial-local-base deep))
        [(Cache _ scan-through _ _ _) (not scan-through)]
        [_ false])
      (match (tc_core.tc-lookup-id deep global-id)
        [(Ok (String)) true]
        [_ false])
      (match (tc_core.tc-lookup-id deep bound.first-id)
        [(Ok (I64)) true]
        [_ false])
      (match (tc_core.tc-lookup-id deep bound.last-id)
        [(Ok (I64)) true]
        [_ false])
      ;; Explicitly layering a module-sized prefix must flatten all partial
      ;; windows without absorbing the global cache below them.
      (match (tc_core.tc-type-env-view layered)
        [(Cache _ scan-through _ _ _) (not scan-through)]
        [_ false])
      (tc-type-env-cache-partial-head? layered)
      (match (tc_core.tc-lookup-id layered global-id)
        [(Ok (String)) true]
        [_ false])
      (match (tc_core.tc-lookup-id layered bound.first-id)
        [(Ok (I64)) true]
        [_ false])
      (match (tc_core.tc-lookup-id layered bound.last-id)
        [(Ok (I64)) true]
        [_ false]))))

;; Markers buried below MORE THAN ONE compaction window. The behavior
;; smoke above only crosses one threshold, so the head cache is unwrapped and
;; the markers are reached by the plain bind walk; with two stacked
;; compaction caches the scans must recurse through scan-through cache nodes
;; or the markers disappear (with-arena escape checking was silently disabled
;; past 32 local binds). Scans must still terminate at the explicit
;; non-scan-through base cache.
(define (tc-arena-phase-nested-structural-record-smoke?) : bool
  (let
    [owner-a : i64 (ci.intern "arena-phase-owner-a")]
    [owner-b : i64 (ci.intern "arena-phase-owner-b")]
    [token-a : i64 (ci.intern "arena-phase-token-a")]
    [token-b : i64 (ci.intern "arena-phase-token-b")]
    [base : tc_core.TcTypeEnv (tc_core.tc-empty-env)]
    [outer-markers : tc_core.TcTypeEnv
      (tc_core.tc-bind-arena-phase-token base token-a owner-a)]
    [outer : tc_core.TcTypeEnv (tc_core.tc-bind-id outer-markers token-a (I64))]
    [outer-region : i64 (tc_core.tc-arena-phase-region-id base owner-a token-a)]
    ;; Shadow the same phase token under a different owner, then nest a second
    ;; token under that owner. Persistent snapshots model the rewind boundary:
    ;; querying `outer` after constructing `inner` must recover outer records.
    [shadow-markers : tc_core.TcTypeEnv
      (tc_core.tc-bind-arena-phase-token outer token-a owner-b)]
    [shadow : tc_core.TcTypeEnv
      (tc_core.tc-bind-id shadow-markers token-a (I64))]
    [shadow-region : i64
      (tc_core.tc-arena-phase-region-id base owner-b token-a)]
    [inner-markers : tc_core.TcTypeEnv
      (tc_core.tc-bind-arena-phase-token shadow token-b owner-b)]
    [inner : tc_core.TcTypeEnv (tc_core.tc-bind-id inner-markers token-b (I64))]
    [inner-region : i64 (tc_core.tc-arena-phase-region-id base owner-b token-b)]
    [deep : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        inner
        (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
    [current-marker : i64
      (tc_core.tc-arena-phase-current-region-marker-id base owner-b)]
    [owner-marker : i64
      (tc_core.tc-arena-phase-token-owner-marker-id base token-b)]
    [region-marker : i64
      (tc_core.tc-arena-phase-token-region-marker-id base token-b)]
    (and
      (not (= inner-region shadow-region))
      (not (= inner-region current-marker))
      (not (= current-marker owner-marker))
      (not (= owner-marker region-marker))
      (tc_core.tc-arena-region-owned-by-id? deep owner-b inner-region)
      (not (tc_core.tc-arena-region-owned-by-id? deep owner-a inner-region))
      (= (tc_core.tc-current-arena-owner-region outer owner-a) outer-region)
      (= (tc_core.tc-current-arena-owner-region shadow owner-b) shadow-region)
      (= (tc_core.tc-current-arena-owner-region deep owner-b) inner-region)
      (match (tc_core.tc-arena-phase-token-owner-active deep token-a)
        [(Some owner) (= owner owner-b)]
        [_ false])
      (match (tc_core.tc-arena-phase-token-region-active deep token-a)
        [(Some region) (= region shadow-region)]
        [_ false])
      (match (tc_core.tc-arena-phase-token-owner-active deep token-b)
        [(Some owner) (= owner owner-b)]
        [_ false])
      (match (tc_core.tc-arena-phase-token-region-active deep token-b)
        [(Some region) (= region inner-region)]
        [_ false]))))

(define (tc-type-env-local-cache-deep-scan-smoke?) : bool
  (let
    [global-id : i64 (ci.intern "global")]
    [arena-id : i64 (ci.intern "arena")]
    [atomic-arena-id : i64 (ci.intern "atomic-arena")]
    [phase-id : i64 (ci.intern "phase")]
    [resource-id : i64 (ci.intern "resource")]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id (tc_core.tc-empty-env) global-id (String)))]
    [phase-region-id : i64
      (tc_core.tc-arena-phase-region-id base arena-id phase-id)]
    [marked : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc-bind-cleanup-owner
          (tc_core.tc-bind-id
            (tc_core.tc-bind-arena-phase-token
              (tc_core.tc-bind-id
                (tc_core.tc-bind-atomic-arena-owner
                  (tc_core.tc-bind-id
                    (tc_core.tc-bind-ordinary-arena-owner
                      (tc_core.tc-bind-return-type
                        (tc_core.tc-enter-unsafe
                          (tc_core.tc-push-region-id base arena-id))
                        (I64))
                      arena-id)
                    arena-id
                    (I64))
                  atomic-arena-id)
                atomic-arena-id
                (I64))
              phase-id
              arena-id)
            phase-id
            (I64))
          resource-id)
        resource-id
        (String))]
    [deep : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        marked
        (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
    [resource-shadow : tc_core.TcTypeEnv
      (tc_core.tc-bind-id deep resource-id (Bool))]
    [shadow-layer : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        resource-shadow
        (- (tc_core.tc-local-cache-threshold) 1))]
    [below-base : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        base
        (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
    (and
      (match (tc_core.tc-active-region deep)
        [(Some region) (= region arena-id)]
        [_ false])
      (match (tc_core.tc-current-return-type deep)
        [(Ok (I64)) true]
        [_ false])
      (tc_core.tc-in-unsafe? deep)
      (tc_core.tc-ordinary-arena-owner-active-id? deep arena-id)
      (tc_core.tc-atomic-arena-owner-active-id? deep atomic-arena-id)
      (match (tc_core.tc-arena-phase-token-region-active deep phase-id)
        [(Some region) (= region phase-region-id)]
        [_ false])
      (match (tc_core.tc-arena-phase-token-owner-active deep phase-id)
        [(Some owner) (= owner arena-id)]
        [_ false])
      (tc_core.tc-string-list-contains
        (tc_core.tc-active-cleanup-owners deep)
        "resource")
      (tc_core.tc-lifetime-visible-id? deep arena-id)
      (tc_core.tc-lifetime-visible-id? deep resource-id)
      (tc_core.tc-lifetime-outlives-binding-id? deep arena-id resource-id)
      (not (tc_core.tc-lifetime-outlives-binding-id? deep resource-id arena-id))
      (tc_core.tc-lifetime-outlives-lifetime-id? deep arena-id resource-id)
      (not
        (tc_core.tc-lifetime-outlives-lifetime-id? deep resource-id arena-id))
      (not (tc_core.tc-cleanup-owner-active-id? shadow-layer resource-id))
      (tc_core.tc-ordinary-arena-owner-active-id? shadow-layer arena-id)
      (tc_core.tc-atomic-arena-owner-active-id? shadow-layer atomic-arena-id)
      (tc_core.tc-region-outlives-or-matches deep arena-id arena-id)
      (match (tc_core.tc-active-region below-base)
        [(No) true]
        [_ false])
      (not (tc_core.tc-lifetime-visible-id? below-base (ci.intern "global"))))))

(define (tc-type-env-c-function-value-shape? [ty : ast.AstType]) : bool
  (match ty
    [(CFunc signature mode)
      (and
        (= (ast.ast-c-function-mode-key mode) 1)
        (tc_core.tc-type-eq
          (ast.ast-node-pool-reader-type-segment-bases)
          (ast.ty-node-get signature)
          (tc_core.tc-fn0 (I64))))]
    [_ false]))

(define (tc-type-env-has-c-function-value?
  [env : tc_core.TcTypeEnv]
  [name-id : i64]) : bool
  (match (tc_core.tc-lookup-unsafe-key-id env name-id)
    [(Ok ty _) (tc-type-env-c-function-value-shape? ty)]
    [_ false]))

(define (tc-type-env-scoped-has-c-function-value?
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [name-id : i64]) : bool
  (let
    [index : i64
      (tc_core.tc-type-env-scoped-carrier-lookup-index carrier name-id)]
    (if (>= index 0)
      (match (tc_core.tc-type-env-scoped-stack-lookup-id-at
        carrier.sidecar.stack
        index)
        [(Found ty _ _ _ _) (tc-type-env-c-function-value-shape? ty)]
        [_ false])
      (match (tc_core.tc-lookup-unsafe-persistent-key-id
        (tc_core.tc-type-env-scoped-sidecar-persistent carrier.sidecar)
        name-id
        name-id)
        [(Ok ty _) (tc-type-env-c-function-value-shape? ty)]
        [_ false]))))

(define (tc-type-env-local-cache-c-function-smoke?) : bool
  (let
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache (tc_core.tc-empty-env))]
    [callback-ty : ast.AstType
      (ast_tests.ast-ty-c-func (ast.ast-type-list-new) (I64) NonNull)]
    [marked : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        base
        (ci.intern "callback")
        (tc_core.tc-global-shared-view callback-ty))]
    [both : tc_core.TcTypeEnv
      (tc_core.tc-bind-unsafe-id
        marked
        (ci.intern "danger-callback")
        callback-ty)]
    [deep : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        both
        (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
    (and
      (tc-type-env-has-c-function-value? deep (ci.intern "callback"))
      (not (tc_core.tc-binding-unsafe-id? deep (ci.intern "callback")))
      (tc-type-env-has-c-function-value? deep (ci.intern "danger-callback"))
      (tc_core.tc-binding-unsafe-id? deep (ci.intern "danger-callback"))
      (match (tc_core.tc-lookup-unsafe-id deep (ci.intern "danger-callback"))
        [(Ok (CFunc _ _) unsafe) unsafe]
        [_ false]))))

(cfg
  test
  (define (tc-source-leading-segment-scoped-result-is?
    [carrier : tc_core.TcTypeEnvScopedCarrier]
    [name-id : i64]
    [prefix-id : i64]
    [expected : bool]) : bool
    (let
      [env : tc_core.TcTypeEnv (tc_core.tc-type-env-scoped-carrier-env carrier)]
      [runtime-save : tc_core.TcTypeEnvScopedRuntimeSave
        (tc_core.tc-type-env-scoped-runtime-enter! carrier)]
      [actual : bool
        (tc_core.tc-source-leading-segment-wins-over-exact-id?
          env
          name-id
          prefix-id)]
      (tc_core.tc-type-env-scoped-runtime-restore! runtime-save)
      (= actual expected))))

(cfg
  test
  (define (tc-source-leading-segment-raw-ordering-smoke?) : bool
    (let
      [module-id : i64 (ci.intern "dotted-order-module")]
      [base-name-id : i64 (ci.intern "dotted-order-a.b")]
      [name-id : i64 (ci.intern "dotted-order-module/dotted-order-a.b")]
      [prefix-id : i64 (ci.intern "dotted-order-module/dotted-order-a")]
      [structural-name-id : i64
        (tc_core.tc-env-name-key-id
          (cis.InternStructuralSessionHandle 0)
          name-id)]
      [structural-prefix-id : i64
        (tc_core.tc-env-name-key-id
          (cis.InternStructuralSessionHandle 0)
          prefix-id)]
      [layer-id : i64 (ci.intern "dotted-order-layer")]
      [exact-below : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id (tc_core.tc-empty-env) name-id (I64)))]
      [prefix-above : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-layer-over-explicit
          (tc_core.tc-bind-id exact-below prefix-id (Bool)))]
      [prefix-below : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id (tc_core.tc-empty-env) prefix-id (Bool)))]
      [exact-above : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-layer-over-explicit
          (tc_core.tc-bind-id prefix-below name-id (I64)))]
      [prefix-wins-tail : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-bind-id (tc_core.tc-empty-env) name-id (I64))
            prefix-id
            (Bool)))]
      [prefix-wins-recursive-layer : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-prefix-layer
          (tc_core.tc-bind-id prefix-wins-tail layer-id (Unit))
          1
          true
          prefix-wins-tail)]
      [exact-wins-tail : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-bind-id (tc_core.tc-empty-env) prefix-id (Bool))
            name-id
            (I64)))]
      [exact-wins-recursive-layer : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-prefix-layer
          (tc_core.tc-bind-id exact-wins-tail layer-id (Unit))
          1
          true
          exact-wins-tail)]
      [structural-exact-only : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-bind-id (tc_core.tc-empty-env) prefix-id (Bool))
            structural-name-id
            (I64)))]
      [scoped-prefix-wins : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-bind-id
          (tc_core.tc-type-env-scoped-carrier-bind-id
            (tc-type-env-scoped-carrier-new)
            name-id
            (I64))
          prefix-id
          (Bool))]
      [scoped-exact-wins : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-bind-id
          (tc_core.tc-type-env-scoped-carrier-bind-id
            (tc-type-env-scoped-carrier-new)
            prefix-id
            (Bool))
          name-id
          (I64))]
      (and
        (ci.intern-qualified? name-id)
        (= (ci.intern-qualified-module-id name-id) module-id)
        (= (ci.intern-qualified-base-id name-id) base-name-id)
        (= (ci.intern-leading-dot-id name-id) prefix-id)
        (not (= structural-name-id name-id))
        (not (= structural-prefix-id prefix-id))
        (=
          structural-name-id
          (tc_core.tc-module-name-id-by-id module-id base-name-id))
        (tc-type-env-cache-partial-head? prefix-above)
        (tc-type-env-cache-partial-head? exact-above)
        (tc-env-cache-explicit-head? prefix-above)
        (tc-env-cache-explicit-head? exact-above)
        (tc_core.tc-source-leading-segment-wins-over-exact-persistent-id?
          prefix-above
          name-id
          prefix-id)
        (not
          (tc_core.tc-source-leading-segment-wins-over-exact-persistent-id?
            exact-above
            name-id
            prefix-id))
        (tc-type-env-cache-partial-head? prefix-wins-recursive-layer)
        (tc-type-env-cache-partial-head? exact-wins-recursive-layer)
        (tc_core.tc-source-leading-segment-wins-over-exact-persistent-id?
          prefix-wins-recursive-layer
          name-id
          prefix-id)
        (not
          (tc_core.tc-source-leading-segment-wins-over-exact-persistent-id?
            exact-wins-recursive-layer
            name-id
            prefix-id))
        ;; This structural top-env key has the same source spelling as the raw
        ;; exact candidate, but it must not participate in local ordering.
        (tc_core.tc-source-leading-segment-wins-over-exact-persistent-id?
          structural-exact-only
          name-id
          prefix-id)
        (tc-source-leading-segment-scoped-result-is?
          scoped-prefix-wins
          name-id
          prefix-id
          true)
        (tc-source-leading-segment-scoped-result-is?
          scoped-exact-wins
          name-id
          prefix-id
          false)
        ;; With no scoped candidates, ordering falls back to the persistent
        ;; tail, including its older partial-cache recursion path.
        (tc-source-leading-segment-scoped-result-is?
          (tc_core.tc-type-env-scoped-carrier-from-env
            prefix-wins-recursive-layer)
          name-id
          prefix-id
          true)
        (tc-source-leading-segment-scoped-result-is?
          (tc_core.tc-type-env-scoped-carrier-from-env
            exact-wins-recursive-layer)
          name-id
          prefix-id
          false)))))

(cfg
  test
  (define (tc-type-env-c-function-selected-key-smoke?) : bool
    (let
      [module-id : i64 (ci.intern "selected-key-module")]
      [name-id : i64 (ci.intern "selected-key-callback")]
      [qualified-id : i64
        (ci.intern "selected-key-module/selected-key-callback")]
      [structural-key : i64 (tc_core.tc-module-name-id-by-id module-id name-id)]
      [normalized-key : i64
        (tc_core.tc-env-name-key-id
          (cis.InternStructuralSessionHandle 0)
          qualified-id)]
      [local-id : i64 (ci.intern "selected-key-local")]
      [layer-id : i64 (ci.intern "selected-key-layer")]
      [callback-ty : ast.AstType
        (ast_tests.ast-ty-c-func (ast.ast-type-list-new) (I64) NonNull)]
      [structural-base : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-empty-env)
            structural-key
            (tc_core.tc-global-shared-view callback-ty)))]
      [structural-layer : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-layer-over-explicit
          (tc_core.tc-bind-id structural-base layer-id (Bool)))]
      [qualified-raw : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-empty-env)
            qualified-id
            (tc_core.tc-global-shared-view callback-ty)))]
      [local-raw : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-empty-env)
            local-id
            (tc_core.tc-global-shared-view callback-ty)))]
      [tail-carrier : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-from-env structural-layer)]
      [scoped-carrier : tc_core.TcTypeEnvScopedCarrier
        (tc-type-env-scoped-carrier-bind-unsafe-id
          (tc_core.tc-type-env-scoped-carrier-from-env (tc_core.tc-empty-env))
          structural-key
          callback-ty)]
      [was-active : bool
        (tc_core.tc-type-env-scoped-runtime-active? structural-layer)]
      [runtime-save : tc_core.TcTypeEnvScopedRuntimeSave
        (tc_core.tc-type-env-scoped-runtime-enter!
          (tc_core.tc-global-shared-view tail-carrier))]
      [runtime-ok : bool
        (and
          (tc-type-env-has-c-function-value? structural-layer structural-key)
          (not
            (tc-type-env-has-c-function-value? structural-layer qualified-id)))]
      (tc_core.tc-type-env-scoped-runtime-restore! runtime-save)
      (and
        (not was-active)
        (ci.intern-qualified? qualified-id)
        (= structural-key normalized-key)
        (not (= structural-key qualified-id))
        (tc-env-cache-explicit-head? structural-layer)
        (tc-type-env-cache-partial-head? structural-layer)
        (tc-type-env-has-c-function-value? structural-layer structural-key)
        (not (tc-type-env-has-c-function-value? structural-layer qualified-id))
        (tc-type-env-has-c-function-value? qualified-raw qualified-id)
        (not (tc-type-env-has-c-function-value? qualified-raw normalized-key))
        (tc-type-env-has-c-function-value? local-raw local-id)
        (tc-type-env-scoped-has-c-function-value?
          (tc_core.tc-global-shared-view tail-carrier)
          structural-key)
        (not
          (tc-type-env-scoped-has-c-function-value? tail-carrier qualified-id))
        (tc-type-env-scoped-has-c-function-value?
          (tc_core.tc-global-shared-view scoped-carrier)
          structural-key)
        (not
          (tc-type-env-scoped-has-c-function-value? scoped-carrier qualified-id))
        runtime-ok))))

(cfg
  test
  (define (tc-type-env-explicit-cache-layering-lookup-smoke?) : bool
    (let
      [base-id : i64 (ci.intern "base")]
      [dup-id : i64 (ci.intern "dup")]
      [missing-id : i64 (ci.intern "missing")]
      [base : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id (tc_core.tc-empty-env) base-id (I64)))]
      [older : tc_core.TcTypeEnv (tc_core.tc-bind-id base dup-id (I64))]
      [newer : tc_core.TcTypeEnv (tc_core.tc-bind-id older dup-id (Bool))]
      [layer : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-layer-over-explicit newer)]
      (and
        (= (tc_core.tc-env-uncached-prefix-to-explicit-cache-count newer) 2)
        (tc-env-cache-explicit-head? layer)
        (tc-type-env-cache-partial-head? layer)
        (match (tc_core.tc-lookup-id layer dup-id)
          [(Ok (Bool)) true]
          [_ false])
        (match (tc_core.tc-lookup-id layer base-id)
          [(Ok (I64)) true]
          [_ false])
        (match (tc_core.tc-lookup-id layer missing-id)
          [(Err message)
            (string.eq
              message
              (cdiag.compiler-diagnostic-typecheck-tagged
                (UnboundName)
                "typecheck: unbound name missing"))]
          [_ false])))))

(cfg
  test
  (define (tc-type-env-explicit-cache-layering-flags-smoke?) : bool
    (let
      [callback-ty : ast.AstType
        (ast_tests.ast-ty-c-func (ast.ast-type-list-new) (I64) NonNull)]
      [base-callback-id : i64 (ci.intern "base-callback")]
      [danger-callback-id : i64 (ci.intern "danger-callback")]
      [base : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-bind-id
            (tc_core.tc-empty-env)
            base-callback-id
            (tc_core.tc-global-shared-view callback-ty)))]
      [layer-source : tc_core.TcTypeEnv
        (tc_core.tc-bind-unsafe-id base danger-callback-id callback-ty)]
      [layer : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-layer-over-explicit layer-source)]
      (and
        (tc-env-cache-explicit-head? layer)
        (tc-type-env-cache-partial-head? layer)
        (tc-type-env-has-c-function-value? layer base-callback-id)
        (not (tc_core.tc-binding-unsafe-id? layer base-callback-id))
        (tc-type-env-has-c-function-value? layer danger-callback-id)
        (tc_core.tc-binding-unsafe-id? layer danger-callback-id)
        (match (tc_core.tc-lookup-unsafe-id layer danger-callback-id)
          [(Ok (CFunc _ _) unsafe) unsafe]
          [_ false])))))

(cfg
  test
  (define (tc-type-env-explicit-cache-layering-marker-smoke?) : bool
    (let
      [base : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache
          (tc_core.tc-push-region (tc_core.tc-default-env) (ci.intern "hidden")))]
      [shadowed : tc_core.TcTypeEnv
        (tc_core.tc-bind-id
          base
          (ci.intern "__tl_string_length")
          (tc_core.tc-fn1 (I64) (I64)))]
      [layer : tc_core.TcTypeEnv
        (tc_core.tc-env-with-cache-layer-over-explicit shadowed)]
      (and
        (tc-env-cache-explicit-head? layer)
        (tc-type-env-cache-partial-head? layer)
        (tc_core.tc-default-builtin-unshadowed-id?
          base
          cbi.compiler-builtin-id-tl-private-string-length)
        (not
          (tc_core.tc-default-builtin-unshadowed-id?
            layer
            cbi.compiler-builtin-id-tl-private-string-length))
        (match (tc_core.tc-active-region layer)
          [(No) true]
          [_ false])
        (not (tc_core.tc-lifetime-visible-id? layer (ci.intern "hidden")))))))

(define (tc-type-env-local-cache-lambda-capture-smoke?) : bool
  (let
    [expr-bases : i64 (ast.ast-node-pool-active-expr-segment-bases)]
    [body : ast.AstExpr (Var (ci.intern "captured"))]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache (tc_core.tc-empty-env))]
    [env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-push-region-id base (ci.intern "outer"))
        (ci.intern "captured")
        (ast.ast-ty-ref (ci.intern "outer") (I64)))]
    [deep : tc_core.TcTypeEnv
      (tc-type-env-bind-many env (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
    [scoped : tc_core.TcTypeEnvScopedCarrier
      (tc_core.tc-type-env-scoped-carrier-from-marker-visible-env deep)]
    (and
      (tc_core.tc-lambda-captures-reference?
        (ast.ast-node-pool-reader-type-segment-bases)
        expr-bases
        deep
        (ast.ast-param-list-new)
        (tc_core.tc-global-shared-view body))
      (tc_core.tc-type-env-scoped-carrier-lambda-captures-reference?
        (ast.ast-node-pool-reader-type-segment-bases)
        expr-bases
        scoped
        (ast.ast-param-list-new)
        (tc_core.tc-global-shared-view body))
      (match (tc_core.tc-check-lambda-region-captures
        (ast.ast-node-pool-reader-type-segment-bases)
        expr-bases
        deep
        (ast.ast-param-list-new)
        (tc_core.tc-global-shared-view body))
        [(Err message)
          (string.eq
            message
            (cdiag.compiler-diagnostic-typecheck-tagged
              (RegionEscape)
              "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope"))]
        [_ false])
      (match (tc_core.tc-check-lambda-region-captures-allow-refs
        (ast.ast-node-pool-reader-type-segment-bases)
        expr-bases
        deep
        (ast.ast-param-list-new)
        body)
        [(Ok) true]
        [_ false]))))

(define (tc-type-env-scoped-stack-grow-smoke?) : bool
  (let
    [stack : tc_core.TcTypeEnvScopedStack
      (tc-type-env-scoped-stack-with-capacity 1 1)]
    [a-id : i64 (ci.intern "scoped-grow-a")]
    [b-id : i64 (ci.intern "scoped-grow-b")]
    [c-id : i64 (ci.intern "scoped-grow-c")]
    (tc_core.tc-type-env-scoped-stack-bind-id! (&mut stack) a-id (I64))
    (let
      [outer : tc_core.TcTypeEnvScopedMark
        (tc-type-env-scoped-stack-save! (&mut stack))]
      (tc_core.tc-type-env-scoped-stack-bind-id! (&mut stack) b-id (Bool))
      (let
        [inner : tc_core.TcTypeEnvScopedMark
          (tc-type-env-scoped-stack-save! (&mut stack))]
        (tc_core.tc-type-env-scoped-stack-bind-id! (&mut stack) c-id (String))
        (tc_core.tc-type-env-scoped-stack-restore! (&mut stack) inner)
        (let
          [after-inner : bool
            (and
              (= (tc_core.tc-type-env-scoped-stack-len stack) 2)
              (= (tc-type-env-scoped-stack-mark-count stack) 1)
              (= (tc-type-env-scoped-stack-scope-depth stack) 1)
              (match (tc_core.tc-type-env-scoped-stack-lookup-id stack c-id)
                [(Missing) true]
                [_ false])
              (match (tc_core.tc-type-env-scoped-stack-lookup-id stack b-id)
                [(Found (Bool) unsafe _ depth _) (and (not unsafe) (= depth 1))]
                [_ false]))]
          (tc_core.tc-type-env-scoped-stack-restore! (&mut stack) outer)
          (and
            after-inner
            (= (tc_core.tc-type-env-scoped-stack-len stack) 1)
            (= (tc-type-env-scoped-stack-mark-count stack) 0)
            (= (tc-type-env-scoped-stack-scope-depth stack) 0)
            (match (tc_core.tc-type-env-scoped-stack-lookup-id stack b-id)
              [(Missing) true]
              [_ false])
            (match (tc_core.tc-type-env-scoped-stack-lookup-id stack a-id)
              [(Found (I64) unsafe marker-kind depth _)
                (and
                  (not unsafe)
                  (tc_core.tc-type-env-scoped-marker-kind-same?
                    marker-kind
                    None)
                  (= depth 0))]
              [_ false])))))))

(define (tc-type-env-scoped-stack-sparse-cache-repair-smoke?) : bool
  (let
    [stack : tc_core.TcTypeEnvScopedStack
      (tc-type-env-scoped-stack-with-capacity 1 1)]
    [name-id : i64 (+ tc_core.tc-type-env-scoped-dense-lookup-capacity 17)]
    (tc_core.tc-type-env-scoped-stack-bind-id! (&mut stack) name-id (I64))
    (let
      [mark : tc_core.TcTypeEnvScopedMark
        (tc-type-env-scoped-stack-save! (&mut stack))]
      (tc_core.tc-type-env-scoped-stack-bind-id! (&mut stack) name-id (Bool))
      (let
        [shadowed : bool
          (match (tc_core.tc-type-env-scoped-stack-lookup-id stack name-id)
            [(Found (Bool) _ _ _ _) true]
            [_ false])]
        (tc_core.tc-type-env-scoped-stack-restore! (&mut stack) mark)
        (let
          [restored : bool
            (match (tc_core.tc-type-env-scoped-stack-lookup-id stack name-id)
              [(Found (I64) _ _ _ _) true]
              [_ false])]
          [repaired-index : i64
            (match (tc_i64_i64_map.get
              (& (__tl-box-place stack.lookup-cache))
              name-id)
              [(LookupFound index) index]
              [(LookupMissing) -1])]
          [restored-again : bool
            (match (tc_core.tc-type-env-scoped-stack-lookup-id stack name-id)
              [(Found (I64) _ _ _ _) true]
              [_ false])]
          (and shadowed restored (= repaired-index 0) restored-again))))))

(define (tc-type-env-scoped-sidecar-smoke?) : bool
  (let
    [sidecar : tc_core.TcTypeEnvScopedSidecar (tc-type-env-scoped-sidecar-new)]
    [value-id : i64 (ci.intern "scoped-value")]
    [fn-id : i64 (ci.intern "scoped-callback")]
    (set!
      sidecar
      (tc_core.tc-type-env-scoped-sidecar-bind-id sidecar value-id (I64)))
    (let
      [stack-mark : tc_core.TcTypeEnvScopedMark
        (tc-type-env-scoped-sidecar-save! (&mut sidecar))]
      [mark : tc_core.TcTypeEnvScopedSidecarMark
        (tc_core.tc-type-env-scoped-sidecar-mark
          (tc_core.tc-global-shared-view sidecar)
          stack-mark)]
      [generation-before : i64
        (tc_core.tc-type-env-scoped-stack-cache-generation sidecar.stack)]
      (set!
        sidecar
        (tc_core.tc-type-env-scoped-sidecar-bind-id sidecar value-id (Bool)))
      (set!
        sidecar
        (tc-type-env-scoped-sidecar-bind-unsafe-id sidecar fn-id (I64)))
      (let
        [before-restore : bool
          (and
            (match (tc_core.tc-type-env-scoped-sidecar-lookup-id
              (tc_core.tc-global-shared-view sidecar)
              value-id)
              [(Found (Bool) unsafe marker-kind depth generation)
                (and
                  (not unsafe)
                  (tc_core.tc-type-env-scoped-marker-kind-same?
                    marker-kind
                    None)
                  (= depth 1)
                  (= generation generation-before))]
              [_ false])
            (match (tc_core.tc-type-env-scoped-sidecar-lookup-id
              (tc_core.tc-global-shared-view sidecar)
              fn-id)
              [(Found (I64) unsafe _ depth generation)
                (and unsafe (= depth 1) (= generation generation-before))]
              [_ false])
            (match (tc-type-env-scoped-stack-marker-lookup
              sidecar.stack
              UnsafeDecl)
              [(Found marker-id (Unit) depth generation)
                (and
                  (= marker-id (tc_core.tc-unsafe-decl-marker-id fn-id))
                  (= depth 1)
                  (= generation generation-before))]
              [_ false])
            (match (tc_core.tc-lookup-id
              (tc_core.tc-type-env-scoped-sidecar-persistent
                (tc_core.tc-global-shared-view sidecar))
              value-id)
              [(Err _) true]
              [_ false])
            (match (tc_core.tc-lookup-unsafe-id
              (tc_core.tc-type-env-scoped-sidecar-materialize
                (tc_core.tc-global-shared-view sidecar))
              fn-id)
              [(Ok (I64) unsafe) unsafe]
              [_ false])
            (match (tc_core.tc-lookup-id
              (tc_core.tc-type-env-scoped-sidecar-materialize
                (tc_core.tc-global-shared-view sidecar))
              value-id)
              [(Ok (Bool)) true]
              [_ false]))]
        (tc_core.tc-type-env-scoped-sidecar-restore! (&mut sidecar) mark)
        (and
          before-restore
          (= (tc_core.tc-type-env-scoped-stack-len sidecar.stack) 1)
          (= (tc-type-env-scoped-stack-mark-count sidecar.stack) 0)
          (=
            (tc_core.tc-type-env-scoped-stack-cache-generation sidecar.stack)
            (+ generation-before 1))
          (match (tc_core.tc-type-env-scoped-sidecar-lookup-id
            (tc_core.tc-global-shared-view sidecar)
            fn-id)
            [(Missing) true]
            [_ false])
          (match (tc_core.tc-type-env-scoped-sidecar-lookup-id
            (tc_core.tc-global-shared-view sidecar)
            value-id)
            [(Found (I64) unsafe marker-kind depth _)
              (and
                (not unsafe)
                (tc_core.tc-type-env-scoped-marker-kind-same? marker-kind None)
                (= depth 0))]
            [_ false])
          (match (tc_core.tc-lookup-id
            (tc_core.tc-type-env-scoped-sidecar-materialize
              (tc_core.tc-global-shared-view sidecar))
            value-id)
            [(Ok (I64)) true]
            [_ false])
          (match (tc_core.tc-lookup-id
            (tc_core.tc-type-env-scoped-sidecar-materialize sidecar)
            fn-id)
            [(Err _) true]
            [_ false]))))))

(define (tc-type-env-scoped-carrier-bind-many
  [carrier : tc_core.TcTypeEnvScopedCarrier]
  [count : i64]) : tc_core.TcTypeEnvScopedCarrier
  (let
    [i : i64 0]
    [out : tc_core.TcTypeEnvScopedCarrier carrier]
    (while (< i count)
      (let
        [name : String (str_cat.str-cat "carrier-local" (string.int->string i))]
        (set!
          out
          (tc_core.tc-type-env-scoped-carrier-bind-id
            out
            (tc_core.tc-generated-name-id name)
            (I64)))
        (set! i (+ i 1))))
    out))

(define (tc-type-env-scoped-carrier-region-matches-env?
  [carrier : tc_core.TcTypeEnvScopedCarrier]) : bool
  (match (tc_core.tc-type-env-scoped-carrier-active-region
    (tc_core.tc-global-shared-view carrier))
    [(Some sidecar-region)
      (match (tc_core.tc-active-region
        (tc_core.tc-type-env-scoped-carrier-env carrier))
        [(Some env-region) (= sidecar-region env-region)]
        [_ false])]
    [(No)
      (match (tc_core.tc-active-region
        (tc_core.tc-type-env-scoped-carrier-env carrier))
        [(No) true]
        [_ false])]))

(define (tc-type-env-scoped-carrier-return-matches-env?
  [carrier : tc_core.TcTypeEnvScopedCarrier]) : bool
  (match (tc_core.tc-type-env-scoped-carrier-current-return-type
    (tc_core.tc-global-shared-view carrier))
    [(Ok carrier-ty)
      (match (tc_core.tc-current-return-type
        (tc_core.tc-type-env-scoped-carrier-env carrier))
        [(Ok env-ty)
          (tc_core.tc-type-eq
            (ast.ast-node-pool-reader-type-segment-bases)
            carrier-ty
            env-ty)]
        [_ false])]
    [(Err _)
      (match (tc_core.tc-current-return-type
        (tc_core.tc-type-env-scoped-carrier-env carrier))
        [(Err _) true]
        [_ false])]))

(define (tc-type-env-scoped-carrier-smoke?) : bool
  (let
    [_outer-id : i64 (ci.intern "outer")]
    [_inner-id : i64 (ci.intern "inner")]
    [_resource-id : i64 (ci.intern "resource")]
    [_arena-id : i64 (ci.intern "arena")]
    [_atomic-id : i64 (ci.intern "atomic")]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-push-region-id
          (tc_core.tc-empty-env)
          (ci.intern "cached-base")))]
    [carrier : tc_core.TcTypeEnvScopedCarrier
      (tc_core.tc-type-env-scoped-carrier-from-env base)]
    [fn-id : i64 (ci.intern "carrier-callback")]
    [callback-ty : ast.AstType (tc_core.tc-fn0 (I64))]
    (set! carrier (tc-type-env-scoped-carrier-bind-default-boundary carrier))
    (set! carrier (tc-type-env-scoped-carrier-push-region carrier _outer-id))
    (set! carrier (tc-type-env-scoped-carrier-enter-unsafe carrier))
    (set!
      carrier
      (tc_core.tc-type-env-scoped-carrier-bind-return-type carrier (I64)))
    (set!
      carrier
      (tc-type-env-scoped-carrier-bind-cleanup-owner carrier _resource-id))
    (set!
      carrier
      (tc_core.tc-type-env-scoped-carrier-bind-id carrier _resource-id (String)))
    (set!
      carrier
      (tc-type-env-scoped-carrier-bind-ordinary-arena-owner carrier _arena-id))
    (set!
      carrier
      (tc_core.tc-type-env-scoped-carrier-bind-id carrier _arena-id (I64)))
    (set!
      carrier
      (tc-type-env-scoped-carrier-bind-atomic-arena-owner carrier _atomic-id))
    (set!
      carrier
      (tc_core.tc-type-env-scoped-carrier-bind-id carrier _atomic-id (I64)))
    (let
      [_outer-snapshot-smoke : i64 0]
      (set! carrier (tc-type-env-scoped-carrier-push-region carrier _inner-id))
      (set!
        carrier
        (tc-type-env-scoped-carrier-bind-unsafe-id carrier fn-id callback-ty))
      (let
        [deep : tc_core.TcTypeEnvScopedCarrier
          (tc-type-env-scoped-carrier-bind-many
            carrier
            (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
        [snapshot : tc_core.TcTypeEnvScopedCarrier
          (tc_core.tc-type-env-scoped-carrier-from-marker-visible-env
            (tc_core.tc-type-env-scoped-carrier-env deep))]
        [deep-sidecar : tc_core.TcTypeEnvScopedSidecar
          (tc-type-env-scoped-carrier-sidecar
            (tc_core.tc-global-shared-view deep))]
        [before-restore : bool
          (and
            (tc-type-env-scoped-carrier-region-matches-env?
              (tc_core.tc-global-shared-view deep))
            (tc-type-env-scoped-carrier-return-matches-env?
              (tc_core.tc-global-shared-view deep))
            (tc_core.tc-type-env-scoped-carrier-in-unsafe?
              (tc_core.tc-global-shared-view deep))
            (tc_core.tc-in-unsafe?
              (tc_core.tc-type-env-scoped-carrier-env deep))
            (match (tc_core.tc-type-env-scoped-carrier-active-region
              (tc_core.tc-global-shared-view deep))
              [(Some region) (= region _inner-id)]
              [_ false])
            (tc_core.tc-cleanup-owner-active-id?
              (tc_core.tc-type-env-scoped-carrier-env deep)
              _resource-id)
            (tc_core.tc-ordinary-arena-owner-active-id?
              (tc_core.tc-type-env-scoped-carrier-env deep)
              _arena-id)
            (tc_core.tc-atomic-arena-owner-active-id?
              (tc_core.tc-type-env-scoped-carrier-env deep)
              _atomic-id)
            (tc_core.tc-type-env-scoped-carrier-in-unsafe?
              (tc_core.tc-global-shared-view snapshot))
            (match (tc_core.tc-type-env-scoped-carrier-active-region
              (tc_core.tc-global-shared-view snapshot))
              [(Some region) (= region _inner-id)]
              [_ false])
            (match (tc_core.tc-type-env-scoped-carrier-current-return-type
              (tc_core.tc-global-shared-view snapshot))
              [(Ok (I64)) true]
              [_ false])
            (tc_core.tc-type-env-scoped-carrier-cleanup-owner-active?
              (tc_core.tc-global-shared-view snapshot)
              _resource-id)
            (tc-type-env-scoped-carrier-ordinary-arena-owner-active?
              (tc_core.tc-global-shared-view snapshot)
              _arena-id)
            (tc-type-env-scoped-carrier-atomic-arena-owner-active?
              (tc_core.tc-global-shared-view snapshot)
              _atomic-id)
            (tc_core.tc-type-env-scoped-carrier-lifetime-visible-id?
              (tc_core.tc-global-shared-view snapshot)
              _arena-id)
            (tc_core.tc-type-env-scoped-carrier-lifetime-visible-id?
              (tc_core.tc-global-shared-view snapshot)
              _resource-id)
            (tc_core.tc-type-env-scoped-carrier-lifetime-outlives-binding-id?
              (tc_core.tc-global-shared-view snapshot)
              _resource-id
              _arena-id)
            (not
              (tc_core.tc-type-env-scoped-carrier-lifetime-outlives-binding-id?
                (tc_core.tc-global-shared-view snapshot)
                _arena-id
                _resource-id))
            (tc_core.tc-type-env-scoped-carrier-lifetime-outlives-lifetime-id?
              (tc_core.tc-global-shared-view snapshot)
              _resource-id
              _arena-id)
            (not
              (tc_core.tc-type-env-scoped-carrier-lifetime-outlives-lifetime-id?
                snapshot
                _arena-id
                _resource-id))
            (tc_core.tc-binding-unsafe-id?
              (tc_core.tc-type-env-scoped-carrier-env deep)
              fn-id)
            (match (tc_core.tc-type-env-scoped-sidecar-lookup-id
              (tc_core.tc-global-shared-view deep-sidecar)
              fn-id)
              [(Found (Func _ _) unsafe _ _ _) (and unsafe)]
              [_ false])
            (match (tc-type-env-scoped-stack-marker-lookup
              deep-sidecar.stack
              DefaultBoundary)
              [(Found marker-id (Unit) _ _)
                (= marker-id (tc_core.tc-default-boundary-id))]
              [_ false])
            (match (tc-type-env-scoped-stack-marker-lookup
              deep-sidecar.stack
              CleanupOwner)
              [(Found marker-id (Var owner) _ _)
                (and
                  (= marker-id (tc_core.tc-cleanup-owner-marker-id))
                  (string.eq (ci.intern-str owner) "resource"))]
              [_ false])
            (match (tc-type-env-scoped-stack-marker-lookup
              deep-sidecar.stack
              OrdinaryArenaOwner)
              [(Found marker-id (Var owner) _ _)
                (and
                  (= marker-id (tc_core.tc-ordinary-arena-owner-marker-id))
                  (string.eq (ci.intern-str owner) "arena"))]
              [_ false])
            (match (tc-type-env-scoped-stack-marker-lookup
              deep-sidecar.stack
              AtomicArenaOwner)
              [(Found marker-id (Var owner) _ _)
                (and
                  (= marker-id (tc_core.tc-atomic-arena-owner-marker-id))
                  (string.eq (ci.intern-str owner) "atomic"))]
              [_ false]))]
        before-restore))))

(cfg
  test
  (define (tc-type-env-scoped-runtime-smoke?) : bool
    (let
      [was-active : bool
        (tc_core.tc-type-env-scoped-runtime-active? (tc_core.tc-default-env))]
      [outer-id : i64 (ci.intern "outer")]
      [inner-id : i64 (ci.intern "inner")]
      [resource-id : i64 (ci.intern "resource")]
      [runtime-tail-id : i64 (ci.intern "runtime-tail")]
      [runtime-unsafe-id : i64 (ci.intern "runtime-unsafe")]
      [runtime-callback-id : i64 (ci.intern "runtime-callback")]
      [base-env : tc_core.TcTypeEnv
        (tc_core.tc-bind-return-type
          (tc_core.tc-push-region-id
            (tc_core.tc-enter-unsafe
              (tc_core.tc-bind-id
                (tc_core.tc-default-env)
                runtime-tail-id
                (String)))
            outer-id)
          (I64))]
      [carrier : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-from-env base-env)]
      [outer-save : tc_core.TcTypeEnvScopedRuntimeSave
        (tc_core.tc-type-env-scoped-runtime-enter! carrier)]
      [runtime-env : tc_core.TcTypeEnv
        (tc_core.tc-bind-id
          (tc-bind-cleanup-owner base-env resource-id)
          resource-id
          (String))]
      [scope-save : tc_core.TcTypeEnvScopedRuntimeSave
        (tc_core.tc-type-env-scoped-runtime-save runtime-env)]
      [unsafe-env : tc_core.TcTypeEnv
        (tc_core.tc-bind-unsafe-id runtime-env runtime-unsafe-id (I64))]
      [c-abi-env : tc_core.TcTypeEnv
        (tc_core.tc-bind-id
          unsafe-env
          runtime-callback-id
          (tc_core.tc-fn0 (I64)))]
      [shadow-env : tc_core.TcTypeEnv
        (tc_core.tc-bind-id
          c-abi-env
          cbi.compiler-builtin-id-tl-private-string-length
          (tc_core.tc-fn1 (I64) (I64)))]
      [inner-env : tc_core.TcTypeEnv
        (tc_core.tc-push-region-id shadow-env inner-id)]
      [inner-ok : bool
        (and
          (match (tc_core.tc-active-region inner-env)
            [(Some region) (= region inner-id)]
            [_ false])
          (match (tc_core.tc-lookup-id inner-env runtime-tail-id)
            [(Ok (String)) true]
            [_ false])
          (match (tc_core.tc-lookup-id inner-env runtime-unsafe-id)
            [(Ok (I64)) true]
            [_ false])
          (tc_core.tc-name-bound-id? inner-env runtime-unsafe-id)
          (match (tc_core.tc-lookup-unsafe-id inner-env runtime-unsafe-id)
            [(Ok (I64) unsafe) unsafe]
            [_ false])
          (not
            (tc_core.tc-default-builtin-unshadowed-id?
              inner-env
              cbi.compiler-builtin-id-tl-private-string-length)))]
      (tc_core.tc-type-env-scoped-runtime-restore! scope-save)
      (let
        [restored-ok : bool
          (and
            (match (tc_core.tc-active-region runtime-env)
              [(Some region) (= region outer-id)]
              [_ false])
            (match (tc_core.tc-current-return-type runtime-env)
              [(Ok (I64)) true]
              [_ false])
            (tc_core.tc-in-unsafe? runtime-env)
            (tc_core.tc-cleanup-owner-active-id? runtime-env resource-id)
            (match (tc_core.tc-lookup-id runtime-env runtime-tail-id)
              [(Ok (String)) true]
              [_ false])
            (match (tc_core.tc-lookup-id runtime-env runtime-unsafe-id)
              [(Err _) true]
              [_ false])
            (not (tc_core.tc-name-bound-id? runtime-env runtime-unsafe-id))
            (tc_core.tc-default-builtin-unshadowed-id?
              runtime-env
              cbi.compiler-builtin-id-tl-private-string-length))]
        (tc_core.tc-type-env-scoped-runtime-restore! outer-save)
        (and
          (not was-active)
          (not (tc_core.tc-type-env-scoped-runtime-active? runtime-env))
          inner-ok
          restored-ok)))))

(cfg
  test
  (define (tc-type-env-scoped-job-isolation-smoke?) : bool
    (let
      [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [lazy-before : bool
        (and
          (= (tc_core.tc-job-state-type-env-scoped-state-address job-a) 0)
          (= (tc_core.tc-job-state-type-env-scoped-state-address job-b) 0))]
      [name-a : i64 (ci.intern "scoped-job-a")]
      [name-b : i64 (ci.intern "scoped-job-b")]
      [lifetime-a : i64 (ci.intern "scoped-job-lifetime-a")]
      [lifetime-a-inner : i64 (ci.intern "scoped-job-lifetime-a-inner")]
      [base-a : tc_core.TcTypeEnv
        (tc_core.tc-push-region-id
          (tc_core.tc-push-region-id
            (tc_core.tc-empty-env-with-job-state job-a)
            lifetime-a)
          lifetime-a-inner)]
      [base-b : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-b)]
      [state-a : tc_core.TcTypeEnvScopedState
        (tc_core.tc-job-state-type-env-scoped-state job-a)]
      [state-b : tc_core.TcTypeEnvScopedState
        (tc_core.tc-job-state-type-env-scoped-state job-b)]
      [save-a : tc_core.TcTypeEnvScopedRuntimeSave
        (tc_core.tc-type-env-scoped-runtime-enter!
          (tc_core.tc-type-env-scoped-carrier-from-env base-a))]
      [env-a : tc_core.TcTypeEnv (tc_core.tc-bind-id base-a name-a (I64))]
      ;; Entering B while A is live must select B's carrier without suspending A.
      [save-b : tc_core.TcTypeEnvScopedRuntimeSave
        (tc_core.tc-type-env-scoped-runtime-enter!
          (tc_core.tc-type-env-scoped-carrier-from-env base-b))]
      [env-b : tc_core.TcTypeEnv (tc_core.tc-bind-id base-b name-b (Bool))]
      [interleaved : bool
        (and
          lazy-before
          (not (= state-a.address state-b.address))
          (tc_core.tc-type-env-scoped-runtime-active? env-a)
          (tc_core.tc-type-env-scoped-runtime-active? env-b)
          (match (tc_core.tc-lookup-id env-a name-a)
            [(Ok (I64)) true]
            [_ false])
          (match (tc_core.tc-lookup-id env-a name-b)
            [(Err _) true]
            [_ false])
          (match (tc_core.tc-lookup-id env-b name-b)
            [(Ok (Bool)) true]
            [_ false])
          (match (tc_core.tc-lookup-id env-b name-a)
            [(Err _) true]
            [_ false])
          ;; These two queries populate equal-shaped visibility memo cells in
          ;; different states; B's miss must not replace A's hit.
          (tc_core.tc-lifetime-visible-id? env-a lifetime-a)
          (not (tc_core.tc-lifetime-visible-id? env-b lifetime-a))
          (tc_core.tc-lifetime-visible-id? env-a lifetime-a)
          ;; Exercise the other two independently stored memo cells with the
          ;; same A-hit/B-miss/A-hit pattern.
          (tc_core.tc-lifetime-outlives-binding-id? env-a lifetime-a name-a)
          (not
            (tc_core.tc-lifetime-outlives-binding-id? env-b lifetime-a name-a))
          (tc_core.tc-lifetime-outlives-binding-id? env-a lifetime-a name-a)
          (tc_core.tc-lifetime-outlives-lifetime-id?
            env-a
            lifetime-a
            lifetime-a-inner)
          (not
            (tc_core.tc-lifetime-outlives-lifetime-id?
              env-b
              lifetime-a
              lifetime-a-inner))
          (tc_core.tc-lifetime-outlives-lifetime-id?
            env-a
            lifetime-a
            lifetime-a-inner))]
      (tc_core.tc-job-state-reset-derived-caches! job-b)
      (let
        [reset-isolated : bool
          (and
            interleaved
            (tc_core.tc-type-env-scoped-runtime-active? env-a)
            (not (tc_core.tc-type-env-scoped-runtime-active? env-b))
            (match (tc_core.tc-lookup-id env-a name-a)
              [(Ok (I64)) true]
              [_ false])
            (tc_core.tc-lifetime-visible-id? env-a lifetime-a))]
        (tc_core.tc-type-env-scoped-runtime-restore! save-b)
        (tc_core.tc-job-state-release-type-env-scoped-state! job-b)
        (let
          [release-isolated : bool
            (and
              reset-isolated
              (= (tc_core.tc-job-state-type-env-scoped-state-address job-b) 0)
              (tc_core.tc-type-env-scoped-runtime-active? env-a))]
          [next-b : tc_core.TcTypeEnv
            (tc_core.tc-empty-env-with-job-state job-b)]
          [state-b-next : tc_core.TcTypeEnvScopedState
            (tc_core.tc-job-state-type-env-scoped-state job-b)]
          (tc_core.tc-type-env-scoped-runtime-restore! save-a)
          (and
            release-isolated
            (> state-b-next.address 0)
            (=
              (tc_core.tc-job-state-type-env-scoped-state-address job-b)
              state-b-next.address)
            (= next-b.abi-pad state-b-next.address)
            (not (tc_core.tc-type-env-scoped-runtime-active? next-b))
            (not (tc_core.tc-type-env-scoped-runtime-active? env-a))))))))

(cfg
  test
  (test
    tc-type-env-scoped-job-isolation
    (if (tc-type-env-scoped-job-isolation-smoke?)
      unit
      (io.panic "typecheck: scoped environment job isolation smoke failed"))))

(define (tc-type-env-scoped-primary-storage-smoke?) : bool
  (let
    [tail-only-id : i64 (tc_core.tc-generated-name-id "tail-only")]
    [shadow-id : i64 (tc_core.tc-generated-name-id "shadow")]
    [alias-id : i64 (tc_core.tc-generated-name-id "alias")]
    [hygiene-id : i64 (tc_core.tc-generated-name-id "hygiene-value")]
    [mirrored-id : i64 (tc_core.tc-generated-name-id "mirrored")]
    [fresh-id : i64 (tc_core.tc-generated-name-id "fresh")]
    [base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id (tc_core.tc-empty-env) tail-only-id (String)))]
    [carrier : tc_core.TcTypeEnvScopedCarrier
      (tc_core.tc-type-env-scoped-carrier-from-env base)]
    [fn-id : i64 (tc_core.tc-generated-name-id "scoped-primary-fn")]
    (set!
      carrier
      (tc_core.tc-type-env-scoped-carrier-bind-id carrier shadow-id (I64)))
    (set!
      carrier
      (tc_core.tc-type-env-scoped-carrier-bind-id carrier shadow-id (Bool)))
    (set!
      carrier
      (tc-type-env-scoped-carrier-bind-alias-id-if-free
        carrier
        shadow-id
        (String)))
    (set!
      carrier
      (tc-type-env-scoped-carrier-bind-alias-id-if-free carrier alias-id (I64)))
    (set!
      carrier
      (tc-type-env-scoped-carrier-bind-unsafe-id
        carrier
        fn-id
        (tc_core.tc-fn0 (I64))))
    (let
      [snapshot : tc_core.TcTypeEnv
        (tc_core.tc-type-env-scoped-carrier-env carrier)]
      [default-carrier : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-bind-id
          (tc_core.tc-type-env-scoped-carrier-from-env
            (tc_core.tc-env-with-cache (tc_core.tc-default-env)))
          cbi.compiler-builtin-id-tl-private-string-length
          (tc_core.tc-fn1 (I64) (I64)))]
      [hygiene-carrier : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-bind-id
          (tc_core.tc-type-env-scoped-carrier-from-env
            (tc_core.tc-hygiene-global-env
              (tc_core.tc-bind-id (tc_core.tc-empty-env) hygiene-id (I64))))
          hygiene-id
          (Bool))]
      [mirrored-carrier : tc_core.TcTypeEnvScopedCarrier
        (tc_core.tc-type-env-scoped-carrier-bind-id
          (tc_core.tc-type-env-scoped-carrier-from-marker-visible-env
            (tc_core.tc-bind-id (tc_core.tc-empty-env) mirrored-id (I64)))
          fresh-id
          (Bool))]
      [mirrored-snapshot : tc_core.TcTypeEnv
        (tc_core.tc-type-env-scoped-carrier-env mirrored-carrier)]
      (and
        (match (tc-type-env-scoped-carrier-lookup-id carrier tail-only-id)
          [(Ok (String)) true]
          [_ false])
        (match (tc-type-env-scoped-carrier-lookup-id carrier shadow-id)
          [(Ok (Bool)) true]
          [_ false])
        (match (tc-type-env-scoped-carrier-lookup-id carrier alias-id)
          [(Ok (I64)) true]
          [_ false])
        (tc-type-env-scoped-carrier-binding-unsafe-id? carrier fn-id)
        (match (tc_core.tc-lookup-id snapshot tail-only-id)
          [(Ok (String)) true]
          [_ false])
        (match (tc_core.tc-lookup-id snapshot shadow-id)
          [(Ok (Bool)) true]
          [_ false])
        (tc_core.tc-binding-unsafe-id? snapshot fn-id)
        (not
          (tc_core.tc-default-builtin-unshadowed-id?
            (tc_core.tc-type-env-scoped-carrier-env default-carrier)
            cbi.compiler-builtin-id-tl-private-string-length))
        (match (tc-lookup-hygiene-global-id
          (tc_core.tc-type-env-scoped-carrier-env hygiene-carrier)
          hygiene-id)
          [(Ok (I64)) true]
          [_ false])
        (=
          (tc_core.tc-ordinary-binding-rank-id-from
            mirrored-snapshot
            fresh-id
            0)
          0)
        (=
          (tc_core.tc-ordinary-binding-rank-id-from
            mirrored-snapshot
            mirrored-id
            0)
          1)))))

(define (tc-type-env-scoped-stack-smoke?) : bool
  (cbi.compiler-builtin-initialize-for-parse!)
  (and
    (tc-type-env-scoped-stack-grow-smoke?)
    (tc-type-env-scoped-stack-sparse-cache-repair-smoke?)
    (tc-type-env-scoped-sidecar-smoke?)
    (tc-type-env-scoped-carrier-smoke?)
    (tc-type-env-scoped-primary-storage-smoke?)
    (cfg test (tc-type-env-scoped-runtime-smoke?) true)))

(test
  tc-type-env-scoped-stack
  (if (tc-type-env-scoped-stack-smoke?)
    unit
    (io.panic "typecheck: scoped type env smoke failed")))

(define (tc-type-env-walker-api-smoke?) : bool
  (let
    [lookup-base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-bind-id
          (tc_core.tc-empty-env)
          (ci.intern "global")
          (String)))]
    [lookup-local : tc_core.TcTypeEnv
      (tc_core.tc-bind-id lookup-base (ci.intern "local") (I64))]
    [lookup-deep : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        lookup-local
        (+ (tc_core.tc-local-cache-threshold) 4))]
    [marker-base : tc_core.TcTypeEnv
      (tc_core.tc-env-with-cache
        (tc_core.tc-push-region-id (tc_core.tc-empty-env) (ci.intern "outer")))]
    [inner-id : i64 (ci.intern "inner")]
    [marker-local : tc_core.TcTypeEnv
      (tc_core.tc-push-region-id marker-base inner-id)]
    [marker-deep : tc_core.TcTypeEnv
      (tc-type-env-bind-many
        marker-local
        (+ (* (tc_core.tc-local-cache-threshold) 2) 8))]
    [marker-scoped : tc_core.TcTypeEnvScopedCarrier
      (tc_core.tc-type-env-scoped-carrier-from-marker-visible-env marker-deep)]
    [unsafe-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-unsafe-id
        (tc_core.tc-empty-env)
        (ci.intern "unsafe-value")
        (I64))]
    [hygiene-top : tc_core.TcTypeEnv
      (tc_core.tc-bind-id (tc_core.tc-empty-env) (ci.intern "visible") (I64))]
    [hygiene-root : tc_core.TcTypeEnv
      (tc_core.tc-hygiene-global-env hygiene-top)]
    [hygiene-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id hygiene-root (ci.intern "visible") (Bool))]
    (and
      (match (tc-type-env-lookup-step lookup-local (ci.intern "local"))
        [(Found (I64)) true]
        [_ false])
      (match (tc-type-env-lookup-step lookup-local (ci.intern "global"))
        [(Miss rest-env)
          (match (tc-type-env-lookup-step rest-env (ci.intern "global"))
            [(Found (String)) true]
            [_ false])]
        [_ false])
      (match (tc_core.tc-type-env-marker-step
        (tc_core.tc-type-env-marker-start marker-local))
        [(Bind key (Var region) _)
          (and (= key (tc_core.tc-region-marker-id)) (= region inner-id))]
        [_ false])
      (match (tc_core.tc-type-env-scoped-marker-step
        (tc_core.tc-type-env-scoped-carrier-marker-cursor marker-scoped))
        [(Bind key (I64) _)
          (=
            key
            (ci.intern
              (str_cat.str-cat
                "local"
                (string.int->string
                  (- (+ (* (tc_core.tc-local-cache-threshold) 2) 8) 1)))))]
        [_ false])
      (match (tc-type-env-unsafe-lookup-step
        unsafe-env
        (ci.intern "unsafe-value"))
        [(Found (I64) unsafe) unsafe]
        [_ false])
      (match (tc_core.tc-ptr-addr-of-local-lookup
        hygiene-env
        (ci.intern "visible"))
        [(Ok (Bool)) true]
        [_ false])
      (match (tc_core.tc-ptr-addr-of-local-lookup
        hygiene-root
        (ci.intern "visible"))
        [(Err _) true]
        [_ false])
      (match (tc_core.tc-lookup-id lookup-deep (ci.intern "global"))
        [(Ok (String)) true]
        [_ false])
      (match (tc_core.tc-lookup-id lookup-deep (ci.intern "local"))
        [(Ok (I64)) true]
        [_ false])
      (match (tc_core.tc-active-region marker-deep)
        [(Some region) (= region (ci.intern "inner"))]
        [_ false])
      (tc_core.tc-lifetime-visible-id? marker-deep (ci.intern "inner"))
      (not (tc_core.tc-lifetime-visible-id? marker-deep (ci.intern "outer")))
      (match (tc_core.tc-lookup-id hygiene-env (ci.intern "visible"))
        [(Ok (Bool)) true]
        [_ false])
      (match (tc-lookup-hygiene-global-id hygiene-env (ci.intern "visible"))
        [(Ok (I64)) true]
        [_ false]))))

(test
  tc-type-env-walker-api
  (if (tc-type-env-walker-api-smoke?)
    unit
    (io.panic "typecheck: env walker api smoke failed")))

(define (tc-type-env-local-cache-smoke?) : bool
  (and
    (tc-type-env-local-cache-behavior-smoke?)
    (tc-type-env-local-cache-default-shadow-smoke?)
    (tc-type-env-local-cache-partial-layer-smoke?)
    (tc-type-env-local-cache-default-shadow-partial-miss-smoke?)
    (tc-type-env-local-cache-depth-cap-smoke?)
    (tc-arena-phase-nested-structural-record-smoke?)
    (tc-type-env-local-cache-deep-scan-smoke?)
    (tc-type-env-local-cache-c-function-smoke?)
    (tc-type-env-local-cache-lambda-capture-smoke?)
    (tc-type-env-scoped-stack-smoke?)
    (tc-type-env-walker-api-smoke?)))

(test
  tc-type-env-local-cache
  (if (tc-type-env-local-cache-smoke?)
    unit
    (io.panic "typecheck: local env cache smoke failed")))

(test
  tc-source-leading-segment-raw-ordering
  (if (tc-source-leading-segment-raw-ordering-smoke?)
    unit
    (io.panic "typecheck: raw dotted-local ordering smoke failed")))

(test
  tc-type-env-explicit-cache-layering
  (if (tc-type-env-explicit-cache-layering-lookup-smoke?)
    unit
    (io.panic "typecheck: explicit env cache lookup layering smoke failed"))
  (if (tc-type-env-explicit-cache-layering-flags-smoke?)
    unit
    (io.panic "typecheck: explicit env cache flag layering smoke failed"))
  (if (tc-type-env-explicit-cache-layering-marker-smoke?)
    unit
    (io.panic "typecheck: explicit env cache marker layering smoke failed"))
  (if (tc-type-env-c-function-selected-key-smoke?)
    unit
    (io.panic "typecheck: selected C ABI fnptr key smoke failed")))

(define (tc-spmd-env-box-smoke?) : bool
  (let
    [lane-id : i64 (ci.intern "lane")]
    [idx-id : i64 (ci.intern "idx")]
    [x-id : i64 (ci.intern "x")]
    [flag-id : i64 (ci.intern "flag")]
    [env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-id (tc_core.tc-empty-env) x-id (I64))
        flag-id
        (Bool))]
    [shadow-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-id (tc_core.tc-empty-env) x-id (I64))
        x-id
        (Bool))]
    [shadow-spmd : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-from-type-env shadow-env)]
    [outer : tc_core.TcSpmdEnv (tc_core.tc-spmd-env-from-type-env env)]
    [local : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-bind-id outer lane-id (I64) Varying Local)]
    [updated : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-set-local-class-id local lane-id Uniform)]
    [indexed : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-bind-role-id
        updated
        idx-id
        (I64)
        Uniform
        Local
        ForeachIndex)]
    [marked-outer : tc_core.TcSpmdEnv (tc_core.tc-spmd-env-mark-outer indexed)]
    [branch-right : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-set-local-class-id indexed lane-id Varying)]
    [merged : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-merge-classes indexed branch-right)]
    [restore-mark : tc_core.TcSpmdEnvMark (tc_core.tc-spmd-env-mark outer)]
    [restored : tc_core.TcSpmdEnv
      (tc_core.tc-spmd-env-restore updated restore-mark)]
    (and
      (match (tc_core.tc-spmd-env-lookup-id updated lane-id)
        [(Found (I64) (Uniform) (Local) (Value)) true]
        [_ false])
      (tc_core.tc-spmd-env-has-local-id? updated lane-id)
      (tc_core.tc-spmd-env-has-outer-id? updated x-id)
      (match (tc_core.tc-spmd-env-lookup-id shadow-spmd x-id)
        [(Found (Bool) (Uniform) (Outer) (Value)) true]
        [_ false])
      (match (tc_core.tc-spmd-env-lookup-id marked-outer idx-id)
        [(Found (I64) (Uniform) (Outer) (ForeachIndex)) true]
        [_ false])
      (not (tc_core.tc-spmd-env-has-local-id? marked-outer lane-id))
      (tc_core.tc-spmd-env-has-outer-id? marked-outer lane-id)
      (match (tc_core.tc-spmd-env-lookup-id merged lane-id)
        [(Found (I64) (Varying) (Local) (Value)) true]
        [_ false])
      (match (tc_core.tc-spmd-env-lookup-id merged idx-id)
        [(Found (I64) (Uniform) (Local) (ForeachIndex)) true]
        [_ false])
      (match (tc_core.tc-spmd-env-lookup-id (tc-spmd-env-pop updated 1) lane-id)
        [(Missing) true]
        [_ false])
      (match (tc_core.tc-spmd-env-lookup-id restored lane-id)
        [(Missing) true]
        [_ false]))))

(cfg
  test
  (define (tc-import-alias-summary-index-test-slot-or
    [index : (& index tc_core.TcImportAliasSummaryIndex)]
    [module-id : i64]
    [fallback : i64]) : i64
    (match (tc_core.tc-import-alias-summary-index-lookup index module-id)
      [(Found slot) slot]
      [(Missing) fallback])))

(cfg
  test
  (define (tc-import-alias-summary-index-test-def-at?
    [decls : ast.AstDeclList]
    [index : i64]
    [expected-name : i64]
    [expected-value : i64]) : bool
    (match (ast.ast-decl-list-ref decls index)
      [(Def _ name _ value)
        (and (= name expected-name) (= value expected-value))]
      [_ false])))

(cfg
  test
  (define (tc-import-alias-summary-index-borrowed-rows-smoke?) : bool
    (let
      [module-a : i64 (ci.intern "summary-index-module-a")]
      [module-b : i64 (ci.intern "summary-index-module-b")]
      [root-name : i64 (ci.intern "summary-index-root")]
      [generated-name : i64 (ci.intern "summary-index-generated")]
      [test-name : i64 (ci.intern "summary-index-test")]
      [bin-name : i64 (ci.intern "summary-index-bin")]
      [str-name : i64 (ci.intern "summary-index-str")]
      [last-a-name : i64 (ci.intern "summary-index-last-a")]
      [b-name : i64 (ci.intern "summary-index-b")]
      [base : ast.AstDeclList (ast.ast-decl-list-with-capacity 1)]
      [_dummy : unit (ast.ast-decl-list-push (&mut base) (Module -101))]
      [_module-a : unit (ast.ast-decl-list-push (&mut base) (Module module-a))]
      [_generated : unit
        (ast.ast-decl-list-push
          (&mut base)
          (ast.ast-decl-comptime-decl-with-meta
            (Some
              "summary-generator"
              "summary-item"
              (ast.ast-expr-list-new)
              "summary-key")
            (ast.ast-decl-def-id generated-name (No) 21)))]
      [_test : unit
        (ast.ast-decl-list-push
          (&mut base)
          (ast.ast-decl-test-id test-name 22 (ast.ast-source-span 1 2 3 4)))]
      [_bin : unit
        (ast.ast-decl-list-push (&mut base) (IncludeBin bin-name "summary.bin"))]
      [_str : unit
        (ast.ast-decl-list-push (&mut base) (IncludeStr str-name "summary.txt"))]
      [_last-a : unit
        (ast.ast-decl-list-push
          (&mut base)
          (ast.ast-decl-def-id last-a-name (No) 25))]
      [_module-b : unit (ast.ast-decl-list-push (&mut base) (Module module-b))]
      [_b : unit
        (ast.ast-decl-list-push
          (&mut base)
          (ast.ast-decl-def-id b-name (No) 31))]
      ;; Tail shares grown source storage but is not prependable. Rebuilding a
      ;; root row in front gives the index a non-zero-offset source and mirrors
      ;; the generated-list prepend/rebuild shapes used by macro expansion.
      [tail : ast.AstDeclList (ast_tests.ast-decl-list-tail base)]
      [all-decls : ast.AstDeclList
        (ast.ast-decl-list-prepend-builder
          (ast.ast-decl-def-id root-name (No) 11)
          tail)]
      [summary : tc_core.TcImportAliasSummaryIndex
        (tc_core.tc-import-alias-summary-index-build-current
          (tc_core.tc-global-shared-view all-decls))]
      [root-slot : i64
        (tc-import-alias-summary-index-test-slot-or
          (& summary)
          cbi.compiler-builtin-id-fix-empty
          -1)]
      [a-slot : i64
        (tc-import-alias-summary-index-test-slot-or (& summary) module-a -1)]
      [b-slot : i64
        (tc-import-alias-summary-index-test-slot-or (& summary) module-b -1)]
      [root-decls : ast.AstDeclList
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data summary.decls) root-slot)))]
      [a-decls : ast.AstDeclList
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data summary.decls) a-slot)))]
      [b-decls : ast.AstDeclList
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data summary.decls) b-slot)))]
      [generated-meta-ok : bool
        (match (let
          [decl (ast.ast-decl-list-ref a-decls 0)]
          (ast.ast-decl-generated-meta decl))
          [(Some _ _ _ key) (string.eq key "summary-key")]
          [(No) false])]
      ;; A later source-slot write must not affect the owned per-module list.
      [_rewrite-source : unit
        (set!
          (array-ref all-decls.slots (+ all-decls.offset 2))
          (ast.ast-decl-def-id generated-name (No) 99))]
      [empty-summary : tc_core.TcImportAliasSummaryIndex
        (tc_core.tc-import-alias-summary-index-build-current
          (ast.ast-decl-list-new))]
      (and
        (> all-decls.offset 0)
        (= summary.count 3)
        (>= root-slot 0)
        (>= a-slot 0)
        (>= b-slot 0)
        (match (tc_core.tc-import-alias-summary-index-lookup (& summary) -202)
          [(Missing) true]
          [_ false])
        (= (ast.ast-decl-list-len (& root-decls)) 1)
        (tc-import-alias-summary-index-test-def-at? root-decls 0 root-name 11)
        (= (ast.ast-decl-list-len (& a-decls)) 5)
        (tc-import-alias-summary-index-test-def-at?
          (tc_core.tc-global-shared-view a-decls)
          0
          generated-name
          21)
        generated-meta-ok
        (match (ast.ast-decl-list-ref a-decls 1)
          [(Test name body _ span)
            (and
              (= name test-name)
              (= body 22)
              (= (ast.ast-source-span-start-line span) 1)
              (= (ast.ast-source-span-end-line span) 3))]
          [_ false])
        (match (ast.ast-decl-list-ref a-decls 2)
          [(IncludeBin name path)
            (and (= name bin-name) (string.eq path "summary.bin"))]
          [_ false])
        (match (ast.ast-decl-list-ref a-decls 3)
          [(IncludeStr name path)
            (and (= name str-name) (string.eq path "summary.txt"))]
          [_ false])
        (tc-import-alias-summary-index-test-def-at? a-decls 4 last-a-name 25)
        (= (ast.ast-decl-list-len (& b-decls)) 1)
        (tc-import-alias-summary-index-test-def-at? b-decls 0 b-name 31)
        (= empty-summary.count 0)
        (match (tc_core.tc-import-alias-summary-index-lookup
          (& empty-summary)
          module-a)
          [(Missing) true]
          [_ false])))))

(cfg
  test
  (test
    import_alias_summary_index_borrowed_rows
    (if (tc-import-alias-summary-index-borrowed-rows-smoke?)
      unit
      (io.panic "typecheck: import alias summary row borrowing failed"))))

(cfg
  test
  (define (tc-literal-pool-test-root
    [pools : ast.AstNodePoolContext]
    [literal : ast.AstLiteral]
    [line : i64]) : i64
    (let
      [leaf : i64 (ast.ast-node-pool-context-expr-push pools (Literal literal))]
      [original : i64
        (ast.ast-expr-source-view-with-pools
          pools
          leaf
          (ast.ast-source-span line 3 line 9))]
      [expanded : i64
        (ast.ast-node-pool-context-expr-push
          pools
          (MacroExpansion original 0 0))]
      (ast.ast-expr-source-view-with-pools
        pools
        expanded
        (ast.ast-source-span (+ line 10) 5 (+ line 10) 11)))))

(cfg
  test
  (define (tc-literal-pool-test-context [pools : ast.AstNodePoolContext]) : tc_core.TcContext
    (tc_core.tc-context-new
      (ast.ast-program (ast.ast-decl-list-new))
      (csym.compiler-symbols-empty)
      (csym.compiler-registries-empty)
      ""
      cbi.compiler-builtin-id-fix-empty
      pools)))

(test
  tc-literal-expression-pool-isolation
  (let
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-c : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [root-a : i64 (tc-literal-pool-test-root pools-a (Int 17 "17") 7)]
    [root-b : i64 (tc-literal-pool-test-root pools-b (Float "3.5") 41)]
    [root-c : i64 (tc-literal-pool-test-root pools-c (Float "1e100") 83)]
    [ctx-a : tc_core.TcContext (tc-literal-pool-test-context pools-a)]
    [ctx-b : tc_core.TcContext (tc-literal-pool-test-context pools-b)]
    [ctx-c : tc_core.TcContext (tc-literal-pool-test-context pools-c)]
    [saved : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [owned-ok? : bool false]
    [compat-ok? : bool false]
    [integer-ok? : bool false]
    ;; All roots have identical integer ids. The installed integer pool must
    ;; not turn the other owners' float syntax into an integer literal.
    (ast.ast-node-pool-context-install! pools-a)
    (set!
      owned-ok?
      (and
        (= root-a root-b)
        (= root-a root-c)
        (tc_core.tc-float-literal-expr?
          ctx-b
          (tc_core.tc-context-expr-get ctx-b root-b))
        (not
          (tc_core.tc-integer-literal-expr?
            ctx-b
            (tc_core.tc-context-expr-get ctx-b root-b)))
        (match (tc_core.tc-float-literal-expr-with-expected
          ctx-b
          (tc_core.tc-context-expr-get ctx-b root-b)
          (F32))
          [(Ok ty)
            (tc_core.tc-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              ty
              (F32))]
          [_ false])
        ;; Literal validation returns raw errors; the diagnostic boundary
        ;; attaches locations. Check rejection and retained provenance
        ;; separately rather than decoding raw text as a located diagnostic.
        (match (tc_core.tc-float-literal-expr-with-expected
          ctx-c
          (tc_core.tc-context-expr-get ctx-c root-c)
          (F32))
          [(Err message)
            (string.eq
              message
              (cdiag.compiler-diagnostic-typecheck-tagged
                (TypeMismatch)
                "typecheck: non-finite f32 literal is not supported"))]
          [_ false])
        (match (ast_tests.ast-node-pool-context-expr-canonical-span
          pools-c
          root-c)
          [(Some span)
            (and
              (= (ast.ast-source-span-start-line span) 83)
              (= (ast.ast-source-span-start-col span) 3))]
          [_ false])
        (match (ast.ast-node-pool-context-expr-view-span pools-c root-c)
          [(Some span)
            (and
              (= (ast.ast-source-span-start-line span) 93)
              (= (ast.ast-source-span-start-col span) 5))]
          [_ false])
        (ast.ast-node-pool-context-expr-span-oracle-ok? pools-c)))
    (ast.ast-node-pool-context-install! pools-b)
    (set!
      integer-ok?
      (and
        (tc_core.tc-integer-literal-expr?
          ctx-a
          (tc_core.tc-context-expr-get ctx-a root-a))
        (not
          (tc_core.tc-float-literal-expr?
            ctx-a
            (tc_core.tc-context-expr-get ctx-a root-a)))
        (match (tc_core.tc-integer-literal-expr-with-expected
          ctx-a
          (tc_core.tc-context-expr-get ctx-a root-a)
          (I64))
          [(Ok ty)
            (tc_core.tc-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              ty
              (I64))]
          [_ false])
        (not (tc_core.tc-integer-literal-expr? ctx-a (Literal (Bool true))))
        (not (tc_core.tc-float-literal-expr? ctx-a (Literal (Bool true))))))
    ;; A compatibility pool context does not redirect typechecker reads: the
    ;; owner-A context still reads its integer literal at the shared id.
    (ast.ast-node-pool-compat-context-use! pools-b)
    (set!
      compat-ok?
      (and
        (tc_core.tc-integer-literal-expr?
          ctx-a
          (tc_core.tc-context-expr-get ctx-a root-b))
        (not
          (tc_core.tc-float-literal-expr?
            ctx-a
            (tc_core.tc-context-expr-get ctx-a root-b)))
        (match (tc_core.tc-integer-literal-expr-with-expected
          ctx-a
          (tc_core.tc-context-expr-get ctx-a root-b)
          (I64))
          [(Ok ty)
            (tc_core.tc-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              ty
              (I64))]
          [_ false])))
    (ast.ast-node-pool-compat-context-clear!)
    (ast.ast-node-pool-context-install! saved)
    (unless
      (and owned-ok? integer-ok? compat-ok?)
      (io.panic
        "typecheck: literal owner, contextual type, or source provenance changed"))))

(cfg
  test
  (test
    tc-unbound-edit-distance-adjacent-transposition
    (let
      [len : i64 5]
      [previous-previous-row : (__tl_dyn-array i64) (__tl_make-array i64 len)]
      [previous-row : (__tl_dyn-array i64) (__tl_make-array i64 len)]
      [current-row : (__tl_dyn-array i64) (__tl_make-array i64 len)]
      (unless
        (and
          (=
            (tc_core.tc-unbound-edit-distance
              "emti"
              "emit"
              (&mut previous-previous-row)
              (&mut previous-row)
              (&mut current-row))
            1)
          (=
            (tc_core.tc-unbound-edit-distance
              "emit"
              "emit"
              (&mut previous-previous-row)
              (&mut previous-row)
              (&mut current-row))
            0))
        (io.panic "typecheck: adjacent-transposition distance failed")))))

(cfg
  test
  (test
    tc-unbound-visible-name-persistent-and-qualified
    (begin
      (ci.intern-reset!)
      (let
        [module-id : i64 (ci.intern "suggest-module")]
        [other-module-id : i64 (ci.intern "suggest-other")]
        [candidate-id : i64 (ci.intern "render-value")]
        [wanted-id : i64 (ci.intern "render-valuf")]
        [qualified-wanted-id : i64 (ci.intern "alias.render-valuf")]
        [plain-id : i64 (ci.intern "plain-value")]
        [plain-wanted-id : i64 (ci.intern "plain-valuf")]
        [qualified-plain-wanted-id : i64 (ci.intern "alias.plain-valuf")]
        [base : tc_core.TcTypeEnv (tc_core.tc-empty-env)]
        [session : cis.InternStructuralSessionHandle
          (tc_core.tc-type-env-structural-session base)]
        [candidate-key : i64
          (tc_core.tc-module-name-id-by-id-for-session
            session
            module-id
            candidate-id)]
        [other-key : i64
          (tc_core.tc-module-name-id-by-id-for-session
            session
            other-module-id
            (ci.intern "render-valve"))]
        ;; Repeated bindings collapse to one cache entry and must produce one
        ;; source candidate, independent of hash-table iteration order.
        [env : tc_core.TcTypeEnv
          (tc_core.tc-env-with-cache
            (tc_core.tc-bind-id
              (tc_core.tc-bind-id
                (tc_core.tc-bind-id
                  (tc_core.tc-bind-id base candidate-key (I64))
                  candidate-key
                  (Bool))
                other-key
                (String))
              plain-id
              (I64)))]
        [visible : tc_core.TcUnboundVisibleNames
          (tc_core.tc-unbound-visible-names true module-id false env)]
        [unqualified : String
          (tc_core.tc-unbound-near-miss
            true
            module-id
            env
            "render-valuf"
            wanted-id)]
        [qualified : String
          (tc_core.tc-unbound-near-miss
            true
            module-id
            env
            "alias.render-valuf"
            qualified-wanted-id)]
        [plain : String
          (tc_core.tc-unbound-near-miss
            true
            module-id
            env
            "plain-valuf"
            plain-wanted-id)]
        [qualified-plain : String
          (tc_core.tc-unbound-near-miss
            true
            module-id
            env
            "alias.plain-valuf"
            qualified-plain-wanted-id)]
        (unless
          (and
            (= visible.len 2)
            (string.eq unqualified "render-value")
            (string.eq qualified "alias.render-value")
            (string.eq plain "plain-value")
            (string.eq qualified-plain ""))
          (io.panic
            "typecheck: persistent/qualified visible-name enumeration failed"))
        (ci.intern-reset!)
        (let
          [hidden-id : i64 (ci.intern "__alpha")]
          [hidden-wanted-id : i64 (ci.intern "alpha")]
          [hidden-env : tc_core.TcTypeEnv
            (tc_core.tc-bind-id (tc_core.tc-empty-env) hidden-id (I64))]
          [hidden-result : String
            (tc_core.tc-unbound-near-miss
              false
              -1
              hidden-env
              "alpha"
              hidden-wanted-id)]
          (unless
            (string.eq hidden-result "")
            (io.panic "typecheck: visible-name reset isolation failed"))
          (ci.intern-reset!))))))

(cfg
  test
  (test
    tc-unbound-visible-name-structural-and-scoped-reset
    (begin
      (ci.intern-reset!)
      (let
        [module-id : i64 (ci.intern "macro-module")]
        [macro-source-id : i64 (ci.intern "macro-value")]
        [structural-source-id : i64 (ci.intern "structural-name")]
        [base : tc_core.TcTypeEnv (tc_core.tc-empty-env)]
        [session : cis.InternStructuralSessionHandle
          (tc_core.tc-type-env-structural-session base)]
        [macro-id : i64
          (tc_core.macro-hygiene-global-id
            session
            module-id
            macro-source-id
            false)]
        [structural-id : i64
          (cis.intern-fresh-local-identity-raw
            (cis.intern-structural-session-fresh-local-identity
              session
              7
              structural-source-id))]
        [persistent : tc_core.TcTypeEnv
          (tc_core.tc-env-with-cache
            (tc_core.tc-bind-id
              (tc_core.tc-bind-id base macro-id (I64))
              structural-id
              (Bool)))]
        [macro-result : String
          (tc_core.tc-unbound-near-miss
            true
            module-id
            persistent
            "m.macro-valuf"
            (ci.intern "m.macro-valuf"))]
        [structural-result : String
          (tc_core.tc-unbound-near-miss
            false
            -1
            persistent
            "structural-namf"
            (ci.intern "structural-namf"))]
        [carrier-before : tc_core.TcTypeEnvScopedCarrier
          (tc_core.tc-type-env-scoped-carrier-from-env persistent)]
        [mark : tc_core.TcTypeEnvScopedCarrierMark
          (tc_core.tc-type-env-scoped-carrier-snapshot-mark
            (tc_core.tc-global-shared-view carrier-before))]
        [scoped-id : i64 (ci.intern "scoped-value")]
        [scoped-wanted-id : i64 (ci.intern "scoped-valuf")]
        [inactive-scoped-result : String
          (tc_core.tc-unbound-near-miss
            false
            -1
            persistent
            "scoped-valuf"
            scoped-wanted-id)]
        [carrier-after : tc_core.TcTypeEnvScopedCarrier
          (tc_core.tc-type-env-scoped-carrier-bind-id
            carrier-before
            scoped-id
            (String))]
        [active-save : tc_core.TcTypeEnvScopedRuntimeSave
          (tc_core.tc-type-env-scoped-runtime-enter!
            (tc_core.tc-global-shared-view carrier-after))]
        [scoped-result : String
          (tc_core.tc-unbound-near-miss
            false
            -1
            persistent
            "scoped-valuf"
            scoped-wanted-id)]
        (tc_core.tc-type-env-scoped-runtime-restore! active-save)
        (let
          [restored : tc_core.TcTypeEnvScopedCarrier
            (tc_core.tc-type-env-scoped-carrier-restore carrier-after mark)]
          [restored-save : tc_core.TcTypeEnvScopedRuntimeSave
            (tc_core.tc-type-env-scoped-runtime-enter! restored)]
          [restored-result : String
            (tc_core.tc-unbound-near-miss
              false
              -1
              persistent
              "scoped-valuf"
              scoped-wanted-id)]
          (tc_core.tc-type-env-scoped-runtime-restore! restored-save)
          (unless
            (and
              (string.eq macro-result "m.macro-value")
              (string.eq structural-result "structural-name")
              (string.eq inactive-scoped-result "")
              (string.eq scoped-result "scoped-value")
              (string.eq restored-result ""))
            (io.panic
              "typecheck: structural/scoped visible-name enumeration failed"))
          (ci.intern-reset!))))))

(cfg
  test
  (test
    tc-unbound-visible-name-two-job-isolation
    (begin
      (ci.intern-reset!)
      (let
        [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
        [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
        [env-a : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-a)]
        [env-b : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-b)]
        [name-a : i64 (ci.intern "job-alpha")]
        [name-b : i64 (ci.intern "job-bravo")]
        [carrier-a : tc_core.TcTypeEnvScopedCarrier
          (tc_core.tc-type-env-scoped-carrier-bind-id
            (tc_core.tc-type-env-scoped-carrier-from-env env-a)
            name-a
            (I64))]
        [carrier-b : tc_core.TcTypeEnvScopedCarrier
          (tc_core.tc-type-env-scoped-carrier-bind-id
            (tc_core.tc-type-env-scoped-carrier-from-env env-b)
            name-b
            (Bool))]
        [save-a : tc_core.TcTypeEnvScopedRuntimeSave
          (tc_core.tc-type-env-scoped-runtime-enter! carrier-a)]
        [save-b : tc_core.TcTypeEnvScopedRuntimeSave
          (tc_core.tc-type-env-scoped-runtime-enter! carrier-b)]
        [result-a : String
          (tc_core.tc-unbound-near-miss
            false
            -1
            env-a
            "job-alphb"
            (ci.intern "job-alphb"))]
        [result-b : String
          (tc_core.tc-unbound-near-miss
            false
            -1
            env-b
            "job-bravp"
            (ci.intern "job-bravp"))]
        (tc_core.tc-type-env-scoped-runtime-restore! save-b)
        (tc_core.tc-type-env-scoped-runtime-restore! save-a)
        (unless
          (and
            (string.eq result-a "job-alpha")
            (string.eq result-b "job-bravo"))
          (io.panic "typecheck: visible-name job isolation failed"))
        (ci.intern-reset!)))))

(cfg
  test
  (test
    tc-unbound-near-miss-stable-and-tie-broken
    (begin
      (ci.intern-reset!)
      (let
        [alpha-id : i64 (ci.intern "alpha")]
        [wanted-id : i64 (ci.intern "alphi")]
        [env : tc_core.TcTypeEnv
          (tc_core.tc-bind-id (tc_core.tc-empty-env) alpha-id (I64))]
        [first : String
          (tc_core.tc-unbound-near-miss false -1 env "alphi" wanted-id)]
        ;; A repeat with the same inputs gives the same suggestion.
        (unless
          (string.eq
            first
            (tc_core.tc-unbound-near-miss false -1 env "alphi" wanted-id))
          (io.panic "typecheck: near-miss scan changed a stable result"))
        (unless
          (string.eq first "alpha")
          (io.panic "typecheck: near-miss scan result wrong"))
        ;; A candidate interned and bound later is found by the next scan:
        ;; at the same distance the alphabetically smaller name wins.
        (let
          [alph-id : i64 (ci.intern "alph")]
          [env2 : tc_core.TcTypeEnv (tc_core.tc-bind-id env alph-id (I64))]
          [after : String
            (tc_core.tc-unbound-near-miss false -1 env2 "alphi" wanted-id)]
          (unless
            (string.eq after "alph")
            (io.panic
              "typecheck: near-miss scan ignored a newly bound candidate"))
          (unless
            (string.eq
              after
              (tc_core.tc-unbound-near-miss false -1 env2 "alphi" wanted-id))
            (io.panic "typecheck: near-miss scan changed the updated result"))
          (ci.intern-reset!))))))

(cfg
  test
  (test
    tc-unbound-suggestion-suppression-scope
    (begin
      (ci.intern-reset!)
      (let
        [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
        [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
        [alpha-id : i64 (ci.intern "alpha")]
        [wanted-id : i64 (ci.intern "alphq")]
        [env-a : tc_core.TcTypeEnv
          (tc_core.tc-bind-id
            (tc_core.tc-empty-env-with-job-state job-a)
            alpha-id
            (I64))]
        [env-b : tc_core.TcTypeEnv
          (tc_core.tc-bind-id
            (tc_core.tc-empty-env-with-job-state job-b)
            alpha-id
            (I64))]
        (unless
          (string.eq
            (tc_core.tc-unbound-near-miss false -1 env-a "alphq" wanted-id)
            "alpha")
          (io.panic "typecheck: near-miss fixture did not suggest alpha"))
        ;; Scopes nest; only the owning job is silenced, and a reported
        ;; diagnostic outside every scope gets its suggestion back.
        (tc_core.tc-unbound-suggestions-suppress-push! env-a)
        (tc_core.tc-unbound-suggestions-suppress-push! env-a)
        (unless
          (and
            (= (tc_core.tc-unbound-suggestion-suppress-depth env-a) 2)
            (= (tc_core.tc-unbound-suggestion-suppress-depth env-b) 0)
            (string.eq
              (tc_core.tc-unbound-near-miss false -1 env-a "alphq" wanted-id)
              "")
            (string.eq
              (tc_core.tc-unbound-near-miss false -1 env-b "alphq" wanted-id)
              "alpha"))
          (io.panic "typecheck: suppression scope leaked or did not suppress"))
        (match (tc_core.tc-unbound-suggestion false -1 env-a "alphq" wanted-id)
          [(No) unit]
          [_ (io.panic "typecheck: suppressed scope still built a suggestion")])
        (tc_core.tc-unbound-suggestions-suppress-pop! env-a)
        (unless
          (string.eq
            (tc_core.tc-unbound-near-miss false -1 env-a "alphq" wanted-id)
            "")
          (io.panic "typecheck: inner pop ended the outer suppression scope"))
        (tc_core.tc-unbound-suggestions-suppress-pop! env-a)
        (unless
          (and
            (= (tc_core.tc-unbound-suggestion-suppress-depth env-a) 0)
            (string.eq
              (tc_core.tc-unbound-near-miss false -1 env-a "alphq" wanted-id)
              "alpha"))
          (io.panic "typecheck: suggestion did not return after the scope"))
        (ci.intern-reset!)))))

(cfg
  test
  (test
    tc-lifetime-substitution-rewrites-region-wrapper
    (match (tc_core.tc-lifetime-subst-type
      (ast.ast-node-pool-reader-type-segment-bases)
      (One 101 202)
      (ast.ast-ty-region 101 (String)))
      [(Region region inner)
        (if (and
          (= region 202)
          (match (ast.ty-node-get inner)
            [(String) true]
            [_ false]))
          unit
          (io.panic "typecheck: region lifetime substitution test failed"))]
      [_ (io.panic "typecheck: region lifetime substitution test failed")])))

(cfg
  test
  ;; Seven nodes with identical ids in every pool built here. `owner?` selects
  ;; which payloads the colliding views and expansion wrappers point at, so the
  ;; same copied argument names a different valid fact key in each pool:
  ;;   id  owner                 decoy
  ;;   0   Bool padding          Int 42
  ;;   1   Int 17                Bool padding
  ;;   2   view of 1             view of 0
  ;;   3   view of 2 (nested)    view of 1
  ;;   4   expansion of 3        expansion of 2
  ;;   5   expansion of 4        expansion of 4
  ;;   6   Unit (not a view)     view of 0
  (define (tc-call-arg-fact-test-pool
    [pools : ast.AstNodePoolContext]
    [owner? : bool]) : i64
    (let
      [first : i64
        (ast.ast-node-pool-context-expr-push
          pools
          (if owner?
            (Literal (Bool true))
            (Literal (Int 42 "42"))))]
      [second : i64
        (ast.ast-node-pool-context-expr-push
          pools
          (if owner?
            (Literal (Int 17 "17"))
            (Literal (Bool true))))]
      [line : i64
        (if owner?
          7
          41)]
      [view : i64
        (ast.ast-expr-source-view-with-pools
          pools
          (if owner?
            second
            first)
          (ast.ast-source-span line 3 line 5))]
      [nested : i64
        (ast.ast-expr-source-view-with-pools
          pools
          (if owner?
            view
            second)
          (ast.ast-source-span (+ line 1) 3 (+ line 1) 5))]
      [expanded : i64
        (ast.ast-node-pool-context-expr-push
          pools
          (MacroExpansion
            (if owner?
              nested
              view)
            0
            0))]
      [chained : i64
        (ast.ast-node-pool-context-expr-push
          pools
          (MacroExpansion expanded 0 0))]
      [tail : i64
        (if owner?
          (ast.ast-node-pool-context-expr-push pools (Literal (Unit)))
          (ast.ast-expr-source-view-with-pools
            pools
            first
            (ast.ast-source-span (+ line 2) 3 (+ line 2) 5)))]
      (if (and
        (= first 0)
        (= second 1)
        (= view 2)
        (= nested 3)
        (= expanded 4)
        (= chained 5)
        (= tail 6))
        tail
        (io.panic "typecheck: call-argument fact fixture ids do not collide")))))

(cfg
  test
  (define (tc-call-arg-fact-test-type-is?
    [ctx : tc_core.TcContext]
    [env : tc_core.TcTypeEnv]
    [arg : ast.AstExpr]
    [want : ast.AstType]) : bool
    (match (tc_core.tc-call-arg-expr-type ctx env arg)
      [(Ok ty) (tc_core.tc-type-eq (tc_core.tc-context-type-bases ctx) ty want)]
      [(Err _) false])))

(cfg
  test
  ;; The owner's expansion arguments select keys 1 and 2; read through the decoy
  ;; they select key 0, whose seeded fact is Bool.
  (define (tc-call-arg-fact-test-owning-facts?
    [ctx : tc_core.TcContext]
    [env : tc_core.TcTypeEnv]) : bool
    (and
      (tc-call-arg-fact-test-type-is? ctx env (MacroExpansion 2 0 0) (I64))
      (tc-call-arg-fact-test-type-is? ctx env (MacroExpansion 3 0 0) (F64))
      (tc-call-arg-fact-test-type-is? ctx env (MacroExpansion 5 0 0) (F64))
      (tc-call-arg-fact-test-type-is?
        ctx
        env
        (Spanned 1 (ast.ast-source-span 7 3 7 5))
        (I64)))))

(test
  tc-call-arg-fact-key-pool-isolation
  (let
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [_tail-a : i64 (tc-call-arg-fact-test-pool pools-a true)]
    [_tail-b : i64 (tc-call-arg-fact-test-pool pools-b false)]
    [ctx-a : tc_core.TcContext (tc-literal-pool-test-context pools-a)]
    [ctx-b : tc_core.TcContext (tc-literal-pool-test-context pools-b)]
    [state : tc_core.TcBodyState (tc_core.tc-context-body-state ctx-a)]
    [env : tc_core.TcTypeEnv (tc_core.tc-type-env-new)]
    [saved : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [keys-ok? : bool false]
    [compat-ok? : bool false]
    [recording-ok? : bool false]
    [consuming-ok? : bool false]
    [cleared-ok? : bool false]
    [restart-ok? : bool false]
    ;; Every argument below is a copied owner-A expression. The unrelated
    ;; installed pool holds other valid views at the same ids.
    (ast.ast-node-pool-context-install! pools-b)
    (set!
      keys-ok?
      (and
        ;; A direct source view is its own immediate payload and reads no pool.
        (=
          (tc_core.tc-call-arg-fact-key
            ctx-a
            (Spanned 1 (ast.ast-source-span 7 3 7 5)))
          1)
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 2 0 0)) 1)
        ;; A nested view keys on its immediate payload, not the deepest leaf.
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 3 0 0)) 2)
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 5 0 0)) 2)
        ;; The decoy holds a view where the owner holds a non-view.
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 6 0 0)) -1)
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 1 0 0)) -1)
        (= (tc_core.tc-call-arg-fact-key ctx-a (Literal (Int 17 "17"))) -1)
        ;; The decoy's own context selects the decoy's keys for the same ids.
        (= (tc_core.tc-call-arg-fact-key ctx-b (MacroExpansion 2 0 0)) 0)
        (= (tc_core.tc-call-arg-fact-key ctx-b (MacroExpansion 5 0 0)) 0)
        (= (tc_core.tc-call-arg-fact-key ctx-b (MacroExpansion 6 0 0)) 0)))
    ;; A compatibility pool context does not redirect typechecker reads: the
    ;; owner-A context keeps its own keys for the same ids.
    (ast.ast-node-pool-compat-context-use! pools-b)
    (set!
      compat-ok?
      (and
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 2 0 0)) 1)
        (= (tc_core.tc-call-arg-fact-key ctx-a (MacroExpansion 3 0 0)) 2)
        (=
          (tc_core.tc-call-arg-fact-key
            ctx-a
            (Spanned 1 (ast.ast-source-span 7 3 7 5)))
          1)))
    (ast.ast-node-pool-compat-context-clear!)
    ;; Seed three valid keys with distinct types that inference cannot
    ;; produce for these literals, so a hit is distinguishable from a re-walk
    ;; and the decoy-selected key 0 from the owning keys 1 and 2.
    (tc_core.tc-body-type-fact-storage-start! state 8)
    (tc_core.tc-body-type-facts-start-recording! state)
    (tc_core.tc-body-type-fact-record! state 0 (Bool))
    (tc_core.tc-body-type-fact-record! state 1 (I64))
    (tc_core.tc-body-type-fact-record! state 2 (F64))
    (set! recording-ok? (tc-call-arg-fact-test-owning-facts? ctx-a env))
    (tc_core.tc-body-type-facts-start-consuming! state)
    ;; Installing the owner, then the decoy again, must not move the facts an
    ;; unchanged context and argument select.
    (ast.ast-node-pool-context-install! pools-a)
    (set! consuming-ok? (tc-call-arg-fact-test-owning-facts? ctx-a env))
    (ast.ast-node-pool-context-install! pools-b)
    (set!
      consuming-ok?
      (and consuming-ok? (tc-call-arg-fact-test-owning-facts? ctx-a env)))
    ;; A cleared table misses: the argument is re-inferred from the owner's
    ;; Int 17 rather than answered by a stale seeded fact, and nothing is
    ;; recorded outside the recording phase.
    (tc_core.tc-body-type-facts-clear! state)
    (set!
      cleared-ok?
      (and
        (tc-call-arg-fact-test-type-is? ctx-a env (MacroExpansion 2 0 0) (I32))
        (< (tc_core.tc-body-type-fact-slot state 0) 0)
        (< (tc_core.tc-body-type-fact-slot state 1) 0)
        (< (tc_core.tc-body-type-fact-slot state 2) 0)))
    ;; A restarted recording stores the re-inferred type under the owning
    ;; key, never under the decoy-selected one, and then serves it as a hit.
    (tc_core.tc-body-type-facts-start-recording! state)
    (set!
      restart-ok?
      (and
        (tc-call-arg-fact-test-type-is? ctx-a env (MacroExpansion 2 0 0) (I32))
        (>= (tc_core.tc-body-type-fact-slot state 1) 0)
        (< (tc_core.tc-body-type-fact-slot state 0) 0)
        (match (tc_core.tc-call-arg-fact-lookup state 1)
          [(Hit ty)
            (tc_core.tc-type-eq
              (ast.ast-node-pool-reader-type-segment-bases)
              ty
              (I32))]
          [(Miss) false])))
    (tc_core.tc-body-type-fact-storage-release! state)
    (ast.ast-node-pool-context-install! saved)
    (unless
      keys-ok?
      (io.panic
        "typecheck: call-argument fact key followed an unrelated expression owner"))
    (unless
      compat-ok?
      (io.panic
        "typecheck: call-argument fact key ignored the explicit compatibility owner"))
    (unless
      (and recording-ok? consuming-ok?)
      (io.panic
        "typecheck: call-argument type came from another owner's body fact"))
    (unless
      (and cleared-ok? restart-ok?)
      (io.panic
        "typecheck: call-argument fact survived a clear or restarted under another key"))))

(cfg
  test
  (define (tc-arena-classifier-identity-ids-ok?) : bool
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [generated-module : i64
        (ci.intern-generated-canonical-name "stdlib.arena")]
      [generated-type : i64
        (ci.intern-generated-canonical-name "stdlib.arena/Arena")]
      [generated-phase : i64 (ci.intern-generated-canonical-name "phase")]
      [canonical-phase : i64
        (tc_core.tc-qualified-name-key-id
          cbi.compiler-builtin-id-arena-module
          cbi.compiler-builtin-id-arena-phase-base)]
      [generated-module-phase : i64
        (tc_core.tc-qualified-name-key-id
          generated-module
          cbi.compiler-builtin-id-arena-phase-base)]
      [generated-base-phase : i64
        (tc_core.tc-qualified-name-key-id
          cbi.compiler-builtin-id-arena-module
          generated-phase)]
      (and
        (tc_core.tc-nominal-name-id-eq?
          cbi.compiler-builtin-id-arena-type
          cbi.compiler-builtin-id-arena-type)
        (not
          (tc_core.tc-nominal-name-id-eq?
            generated-type
            cbi.compiler-builtin-id-arena-type))
        (=
          (tc_core.tc-arena-safe-call-base-kind-id
            cbi.compiler-builtin-id-arena-phase-base)
          (tc_core.tc-arena-safe-call-kind-phase))
        (=
          (tc_core.tc-arena-safe-call-base-kind-id
            cbi.compiler-builtin-id-arena-rewind-safe-base)
          (tc_core.tc-arena-safe-call-kind-rewind))
        (=
          (tc_core.tc-arena-safe-call-base-kind-id
            cbi.compiler-builtin-id-arena-destroy-safe-base)
          (tc_core.tc-arena-safe-call-kind-destroy))
        (=
          (tc_core.tc-arena-safe-call-base-kind-id generated-phase)
          (tc_core.tc-arena-safe-call-kind-none))
        (tc_core.tc-arena-canonical-call-base-id?
          (cis.InternStructuralSessionHandle 0)
          canonical-phase
          cbi.compiler-builtin-id-arena-phase-base)
        (not
          (tc_core.tc-arena-canonical-call-base-id?
            (cis.InternStructuralSessionHandle 0)
            generated-module-phase
            cbi.compiler-builtin-id-arena-phase-base))
        (not
          (tc_core.tc-arena-canonical-call-base-id?
            (cis.InternStructuralSessionHandle 0)
            generated-base-phase
            cbi.compiler-builtin-id-arena-phase-base))))))

(cfg
  test
  (test
    tc-arena-classifier-identity-ids
    (if (tc-arena-classifier-identity-ids-ok?)
      unit
      (io.panic "typecheck: arena classifier identity ID test failed"))))

(cfg
  test
  (define (tc-arena-generated-brand-ids-ok?) : bool
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [ordinary-a : i64
        (tc_core.tc-arena-brand-id (tc_core.tc-arena-owner-kind-ordinary) 101)]
      [ordinary-a-again : i64
        (tc_core.tc-arena-brand-id (tc_core.tc-arena-owner-kind-ordinary) 101)]
      [ordinary-b : i64
        (tc_core.tc-arena-brand-id (tc_core.tc-arena-owner-kind-ordinary) 102)]
      [atomic-a : i64
        (tc_core.tc-arena-brand-id (tc_core.tc-arena-owner-kind-atomic) 101)]
      [ordinary-ty : ast.AstType
        (tc_core.tc-arena-branded-type
          (tc_core.tc-arena-owner-kind-ordinary)
          101)]
      [atomic-ty : ast.AstType
        (tc_core.tc-arena-branded-type (tc_core.tc-arena-owner-kind-atomic) 101)]
      [rendered : String
        (tc_core.tc-type-render
          (ast.ast-node-pool-reader-type-segment-bases)
          (tc_core.tc-global-shared-view ordinary-ty))]
      [ordinary-prefix : String (tc_core.tc-arena-brand-ordinary-prefix)]
      [env : tc_core.TcTypeEnv (tc_core.tc-empty-env)]
      (and
        (= ordinary-a ordinary-a-again)
        (not (= ordinary-a ordinary-b))
        (not (= ordinary-a atomic-a))
        (tc_core.tc-generated-ordinary-arena-brand-id? ordinary-a)
        (tc_core.tc-generated-atomic-arena-brand-id? atomic-a)
        (tc_core.tc-lifetime-visible-id? env ordinary-a)
        (tc_core.tc-ordinary-arena-owner-active-id? env ordinary-a)
        (tc_core.tc-atomic-arena-owner-active-id? env atomic-a)
        (not (tc_core.tc-atomic-arena-owner-active-id? env ordinary-a))
        (not
          (tc_core.tc-type-regions-all-atomic-arena-owners?
            (ast.ast-node-pool-reader-type-segment-bases)
            env
            ordinary-ty))
        (tc_core.tc-type-regions-all-atomic-arena-owners?
          (ast.ast-node-pool-reader-type-segment-bases)
          env
          atomic-ty)
        (string.contains (& rendered) (& ordinary-prefix))))))

(cfg
  test
  (test
    tc-arena-generated-brand-ids
    (if (tc-arena-generated-brand-ids-ok?)
      unit
      (io.panic "typecheck: generated Arena brand ID test failed"))))

(cfg
  test
  (define (tc-thread-name-kind-job-owned-smoke?) : bool
    (let
      [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state-a : tc_core.TcThreadNameKindState
        (tc_core.tc-job-state-thread-name-kind job-a)]
      [state-b : tc_core.TcThreadNameKindState
        (tc_core.tc-job-state-thread-name-kind job-b)]
      [name-id : ci.InternId
        (ci.intern-id-from-renderable (ci.intern "thread-kind-owned"))]
      [a-channel : i64
        (tc_core.tc-thread-name-kind-owned
          state-a
          301
          401
          name-id
          "channel-worker-send")]
      [b-spawn : i64
        (tc_core.tc-thread-name-kind-owned state-b 301 401 name-id "spawn")]
      [a-cached : i64
        (tc_core.tc-thread-name-kind-owned state-a 301 401 name-id "spawn")]
      ;; Reusing a numeric ID under a different owner must invalidate A's entry.
      [a-new-owner : i64
        (tc_core.tc-thread-name-kind-owned state-a 302 402 name-id "ordinary")]
      (tc-job-state-set-thread-name-kind-enabled! job-a false)
      (let
        [uncached : i64
          (tc_core.tc-thread-name-kind-owned state-a 302 402 name-id "spawn")]
        [data : tc_core.TcThreadNameKindStateData
          (tc_core.tc-thread-name-kind-state-data state-a)]
        (and
          (= a-channel 1)
          (= b-spawn 2)
          (= a-cached 1)
          (= a-new-owner 0)
          (= uncached 2)
          (= (tc_i64_i64_map.len (& data.kinds)) 1)
          (< (tc_i64_i64_map.capacity (& data.kinds)) (ci.intern-capacity)))))))

(cfg
  test
  (test
    tc-thread-name-kind-job-owned
    (if (tc-thread-name-kind-job-owned-smoke?)
      unit
      (io.panic "typecheck: job-owned thread-name kind smoke failed"))))

(define (tc-nominal-clone-state-isolation-self-test) : bool
  (let
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [nominal-a : tc_core.TcNominalCacheState
      (tc_core.tc-job-state-nominal-cache job-a)]
    [nominal-b : tc_core.TcNominalCacheState
      (tc_core.tc-job-state-nominal-cache job-b)]
    [clone-a : tc_core.TcCloneState (tc_core.tc-job-state-clone job-a)]
    [clone-b : tc_core.TcCloneState (tc_core.tc-job-state-clone job-b)]
    [owner-handle : i64 73]
    [owner-slot : i64 (tc_core.tc-nominal-owner-cache-slot owner-handle)]
    [program : ast.AstProgram (ast.ast-program (ast.ast-decl-list-new))]
    ;; The same numeric lookup key and symbol handle deliberately carry
    ;; different answers in the two jobs.
    (tc_core.tc-resolve-type-name-cache-store! nominal-a 41 true 101)
    (tc_core.tc-resolve-type-name-cache-store! nominal-b 41 false 0)
    (tc_core.tc-nominal-owner-cache-store-if-safe!
      nominal-a
      owner-handle
      "owner-a")
    (tc_core.tc-nominal-owner-cache-store-if-safe!
      nominal-b
      owner-handle
      "owner-b")
    (let
      [data-a : tc_core.TcCloneStateData (tc_core.tc-clone-state-data clone-a)]
      [data-b : tc_core.TcCloneStateData (tc_core.tc-clone-state-data clone-b)]
      (set!
        data-a.able-cache
        (clone_support.clone-name-set-insert-id data-a.able-cache 111))
      (set! data-a.able-ready true)
      (tc_core.tc-clone-state-data-set! clone-a data-a)
      (set!
        data-b.able-cache
        (clone_support.clone-name-set-insert-id data-b.able-cache 222))
      (set! data-b.able-ready true)
      (tc_core.tc-clone-state-data-set! clone-b data-b))
    ;; Each active traversal owns an independent arena even when both jobs
    ;; were constructed in the same driver lifetime arena.
    (tc_core.tc-clone-root-collection-use!
      job-a
      (tc_core.tc-global-shared-view program))
    (tc_core.tc-clone-root-collection-use! job-b program)
    (let
      [root-a-before : tc_core.TcCloneStateData
        (tc_core.tc-clone-state-data clone-a)]
      [root-b-before : tc_core.TcCloneStateData
        (tc_core.tc-clone-state-data clone-b)]
      [root-b-arena : i64 root-b-before.root-arena]
      (tc_core.tc-nominal-owner-cache-reset-for-job! job-a)
      (tc_core.tc-clone-able-cache-reset-for-job! job-a)
      (let
        [nominal-a-after : tc_core.TcNominalCacheStateData
          (tc_core.tc-nominal-cache-state-data nominal-a)]
        [nominal-b-after : tc_core.TcNominalCacheStateData
          (tc_core.tc-nominal-cache-state-data nominal-b)]
        [clone-a-after : tc_core.TcCloneStateData
          (tc_core.tc-clone-state-data clone-a)]
        [clone-b-after : tc_core.TcCloneStateData
          (tc_core.tc-clone-state-data clone-b)]
        [isolated : bool
          (and
            root-a-before.root-active
            root-b-before.root-active
            (> root-a-before.root-arena 0)
            (> root-b-arena 0)
            (not (= root-a-before.root-arena root-b-arena))
            (match (tc_core.tc-resolve-type-name-cache-lookup nominal-a 41)
              [(Miss) true]
              [_ false])
            (match (tc_core.tc-resolve-type-name-cache-lookup nominal-b 41)
              [(Missing) true]
              [_ false])
            (= (array-ref nominal-a-after.owner-handles owner-slot) -1)
            (string.eq
              (tc_core.tc-global-array-element-shared-view
                nominal-a-after.owner-names
                owner-slot)
              "")
            (=
              (array-ref nominal-b-after.owner-handles owner-slot)
              owner-handle)
            (string.eq
              (tc_core.tc-global-array-element-shared-view
                nominal-b-after.owner-names
                owner-slot)
              "owner-b")
            (not clone-a-after.able-ready)
            clone-b-after.able-ready
            (clone_support.clone-name-set-contains-id?
              (& clone-b-after.able-cache)
              222))]
        (tc_core.tc-clone-root-collection-abort! job-a)
        (let
          [root-a-after : tc_core.TcCloneStateData
            (tc_core.tc-clone-state-data clone-a)]
          [root-b-after : tc_core.TcCloneStateData
            (tc_core.tc-clone-state-data clone-b)]
          [root-isolated : bool
            (and
              (not root-a-after.root-active)
              (= root-a-after.root-arena 0)
              root-b-after.root-active
              (= root-b-after.root-arena root-b-arena)
              root-b-after.able-ready
              (clone_support.clone-name-set-contains-id?
                (& root-b-after.able-cache)
                222))]
          (tc_core.tc-clone-root-collection-abort! job-b)
          (and
            isolated
            root-isolated
            (not (tc_core.tc-clone-root-collection-active-for-job? job-b))))))))

(cfg
  test
  (test
    tc-nominal-clone-job-owned-reset-isolation
    (if (tc-nominal-clone-state-isolation-self-test)
      unit
      (io.panic "typecheck: job-owned nominal/clone state isolation failed"))))

;; --------------------------------------------------------------------------
;; Inferred-type hint collection (used by the LSP for inlay hints).
;;
;; Disabled by default so normal and bootstrap compiles are byte-for-byte
;; unaffected. When enabled, the typechecker records the rendered inferred type
;; and 1-based source position of each un-annotated `let` binding value. A ring
;; buffer keeps the most recent records, so the entry document (whose decls are
;; checked last) is always retained even when imported modules are re-checked.
;; Records are not file-attributed; the LSP filters them against the open
;; document's text before turning them into hints.
;; Each TcJobState owns one collector: fixed arrays are lazy and live in the
;; state creation arena, while copied rendered strings live in a disposable
;; per-generation arena. The stdio LSP is serialized, but independent jobs can
;; interleave without resetting one another's records.
;; --------------------------------------------------------------------------
(define (tc-inlay-hint-state-enabled? [state : tc_core.TcInlayHintState]) : bool
  (__tl-project-field (tc_core.tc-inlay-hint-state-data state) enabled))

;; Serial/test adapters retain the historical no-state surface.
(define (tc-inlay-hints-enable!) : unit
  (tc_core.tc-inlay-hints-enable-for-state!
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))))

(define (tc-inlay-hints-disable!) : unit
  (tc_core.tc-inlay-hints-disable-for-state!
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))))

(define (tc-inlay-hints-size) : i64
  (tc_core.tc-inlay-hints-size-for-state
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))))

(define (tc-inlay-hint-line-at [i : i64]) : i64
  (tc_core.tc-inlay-hint-line-at-for-state
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))
    i))

(define (tc-inlay-hint-col-at [i : i64]) : i64
  (tc_core.tc-inlay-hint-col-at-for-state
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))
    i))

(define (tc-inlay-hint-type-at [i : i64]) : String
  (tc_core.tc-inlay-hint-type-at-for-state
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))
    i))

(define (tc-inlay-hint-record! [line : i64] [col : i64] [ty : String]) : unit
  (tc_core.tc-inlay-hint-record-for-state!
    (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))
    line
    col
    ty))

(define (tc-spmd-traversal-state-isolation-self-test) : bool
  (let
    [caller : arena.Arena (arena.current)]
    [owner-a : arena.Arena (arena.make)]
    [owner-b : arena.Arena (arena.make)]
    [job-a-address : i64
      (in-arena owner-a (__tl-project-field (tc_core.tc-job-state-new) address))]
    [job-b-address : i64
      (in-arena owner-b (__tl-project-field (tc_core.tc-job-state-new) address))]
    [job-a : tc_core.TcJobState (tc_core.TcJobState job-a-address)]
    [job-b : tc_core.TcJobState (tc_core.TcJobState job-b-address)]
    [state-a : tc_core.TcSpmdTraversalState
      (tc_core.tc-job-state-spmd-traversal job-a)]
    [state-b : tc_core.TcSpmdTraversalState
      (tc_core.tc-job-state-spmd-traversal job-b)]
    [scratch : arena.Arena (arena.make)]
    [saved-a : tc_core.TcNameIdList Nil]
    [owned-dense? : bool false]
    [interleaved? : bool false]
    [reset-isolated? : bool false]
    [reuse-isolated? : bool false]
    [survives-other-owner-destroy? : bool false]
    (unsafe
      (arena.set! scratch))
    (tc_core.tc-spmd-inline-helper-stack-push-for-state! state-a 101)
    (tc_core.tc-spmd-inline-helper-stack-push-for-state! state-a 102)
    (set! saved-a (tc_core.tc-spmd-inline-helper-stack-for-state state-a))
    (tc_core.tc-spmd-inline-helper-stack-push-for-state! state-a 103)
    (tc_core.tc-spmd-inline-helper-stack-push-for-state! state-b 201)
    (tc_core.tc-spmd-inline-helper-stack-push-for-state! state-b 202)
    (set!
      owned-dense?
      (match (tc_core.tc-spmd-inline-helper-stack-for-state state-a)
        [(Dense address _ 3)
          (=
            (__tl-project-field
              (tc_core.tc-name-id-list-store-read address)
              owner-arena)
            (arena.raw-handle owner-a))]
        [_ false]))
    (unsafe
      (arena.set! caller))
    (unsafe
      (arena.destroy scratch))
    (set!
      interleaved?
      (and
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-a 101)
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-a 103)
        (not
          (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-a 201))
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 201)
        (not
          (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 101))))
    (tc_core.tc-spmd-inline-helper-stack-restore-for-state! state-a saved-a)
    (tc_core.tc-job-state-reset-file-state! job-a)
    (set!
      reset-isolated?
      (and
        (tc_core.tc-name-id-list-empty?
          (tc_core.tc-spmd-inline-helper-stack-for-state state-a))
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 201)
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 202)))
    (tc_core.tc-spmd-inline-helper-stack-push-for-state! state-a 104)
    (set!
      reuse-isolated?
      (and
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-a 104)
        (not
          (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-a 101))
        (not
          (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 104))))
    (unsafe
      (arena.destroy owner-a))
    (set!
      survives-other-owner-destroy?
      (and
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 201)
        (tc_core.tc-spmd-inline-helper-stack-contains-for-state? state-b 202)))
    (tc_core.tc-spmd-inline-helper-stack-reset-for-job! job-b)
    (let
      [b-reset? : bool
        (tc_core.tc-name-id-list-empty?
          (tc_core.tc-spmd-inline-helper-stack-for-state state-b))]
      (unsafe
        (arena.destroy owner-b))
      (and
        owned-dense?
        interleaved?
        reset-isolated?
        reuse-isolated?
        survives-other-owner-destroy?
        b-reset?))))

(cfg
  test
  (test
    spmd-traversal-state-isolation
    (if (tc-spmd-traversal-state-isolation-self-test)
      unit
      (io.panic "typecheck: job-owned SPMD traversal isolation failed"))))

(test
  tc-cleanup-owner-result-walk-pool-isolation
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [owner-id : i64 (ci.intern "cleanup-owner/pool-a")]
    [decoy-id : i64 (ci.intern "cleanup-owner/pool-b-decoy")]
    [leaf-a : i64 (ast.ast-node-pool-context-expr-push pools-a (Var owner-id))]
    [leaf-b : i64 (ast.ast-node-pool-context-expr-push pools-b (Var decoy-id))]
    [root : ast.AstExpr (Spanned leaf-a (ast.ast-source-span 1 1 1 2))]
    [ctx-a : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-a)]
    [env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc-bind-cleanup-owner (tc_core.tc-empty-env) owner-id)
        owner-id
        (String))]
    [owners : tc_core.TcStringList
      (tc_core.tc-string-list-add Nil (ci.intern-str owner-id))]
    [_install-decoy : unit (ast.ast-node-pool-context-install! pools-b)]
    [owner-found? : bool
      (tc_core.tc-expr-result-uses-active-cleanup-owner?
        ctx-a
        env
        (tc_core.tc-global-shared-view root))]
    [decoy-differs? : bool
      (not
        (tc_core.tc-expr-result-uses-cleanup-owner?
          (ast.ast-node-pool-context-expr-segment-bases (& pools-b))
          root
          owners
          Nil))]
    [decoy-still-installed? : bool
      (ast.ast-node-pool-context-expr-installed? pools-b)]
    [ok? : bool
      (and
        (= leaf-a leaf-b)
        owner-found?
        decoy-differs?
        decoy-still-installed?
        (= (ast.ast-node-pool-context-expr-len pools-a) 1)
        (= (ast.ast-node-pool-context-expr-len pools-b) 1))]
    (ast.ast-node-pool-context-install! installed)
    (if ok?
      unit
      (io.panic "typecheck: cleanup-owner result walk pool isolation failed"))))

;; A struct's fields in the inline aggregate layout default and `(:repr c)`
;; structs share.
(define (tc-inline-layout-fields [layout : tc_core.TcInlineAggregateLayout]) : tc_core.TcInlineFieldLayoutList
  (match layout
    [(Struct _ _ fields) fields]
    [(Enum _ _ _)
      (tc_core.TcInlineFieldLayoutList
        (__tl_make-array tc_core.TcInlineFieldLayout 0))]))

(define (tc-inline-layout-field-offset
  [layout : tc_core.TcInlineAggregateLayout]
  [name : String]) : i64
  (tc-inline-field-list-offset (tc-inline-layout-fields layout) name))

;; The offset of the field named `name`, or -1.
(define (tc-inline-field-list-offset
  [fields : tc_core.TcInlineFieldLayoutList]
  [name : String]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (while (< index (tc_core.tc-inline-field-layout-list-count (& fields)))
      (match (tc_core.tc-inline-field-layout-list-ref (& fields) index)
        [(Field field-name _ offset)
          (when
            (string.eq (tc_core.tc-env-key-name-text field-name) name)
            (set! found offset)
            (set! index (tc_core.tc-inline-field-layout-list-count (& fields))))])
      (set! index (+ index 1)))
    found))

(define (tc-inline-variant-layout-size
  [variant : tc_core.TcInlineVariantLayout]) : i64
  (match variant
    [(Variant _ size _ _) size]))

(define (tc-inline-variant-layout-list-size-exact-id
  [variants : tc_core.TcInlineVariantLayoutList]
  [name-id : i64]) : i64
  (tc-inline-variant-layout-list-size-exact-id-at variants name-id 0))

(define (tc-inline-variant-layout-list-size-exact-id-at
  [variants : tc_core.TcInlineVariantLayoutList]
  [name-id : i64]
  [index : i64]) : i64
  (if (>= index (tc_core.tc-inline-variant-layout-list-count variants))
    -1
    (let
      [variant : tc_core.TcInlineVariantLayout
        (tc_core.tc-inline-variant-layout-list-ref variants index)]
      (if (=
        (tc_core.tc-inline-variant-layout-name-id
          (tc_core.tc-global-shared-view variant))
        name-id)
        (tc-inline-variant-layout-size variant)
        (tc-inline-variant-layout-list-size-exact-id-at
          variants
          name-id
          (+ index 1))))))

(define (tc-inline-variant-layout-list-size-fallback-id
  [variants : tc_core.TcInlineVariantLayoutList]
  [name-id : i64]) : i64
  (tc-inline-variant-layout-list-size-fallback-id-at variants name-id 0))

(define (tc-inline-variant-layout-list-size-fallback-id-at
  [variants : tc_core.TcInlineVariantLayoutList]
  [name-id : i64]
  [index : i64]) : i64
  (if (>= index (tc_core.tc-inline-variant-layout-list-count variants))
    -1
    (let
      [variant : tc_core.TcInlineVariantLayout
        (tc_core.tc-inline-variant-layout-list-ref variants index)]
      (if (tc_core.tc-inline-variant-layout-name-matches-id?
        (tc_core.tc-inline-variant-layout-name-id
          (tc_core.tc-global-shared-view variant))
        name-id)
        (tc-inline-variant-layout-size variant)
        (tc-inline-variant-layout-list-size-fallback-id-at
          variants
          name-id
          (+ index 1))))))

(define (tc-inline-aggregate-layout-variant-size-id
  [layout : (& layout tc_core.TcInlineAggregateLayout)]
  [name-id : i64]) : i64
  (let
    [layout : tc_core.TcInlineAggregateLayout
      (owned_view.compiler-owned-reference-shared-view layout)]
    (match layout
      [(Struct _ _ _) -1]
      [(Enum _ _ variants)
        (let
          [exact : i64
            (tc-inline-variant-layout-list-size-exact-id
              (tc_core.tc-global-shared-view variants)
              name-id)]
          (if (>= exact 0)
            exact
            (tc-inline-variant-layout-list-size-fallback-id variants name-id)))])))

;; Serial/test compatibility adapter. Production batch prewarming supplies the
;; CompilerDriverState-owned job explicitly.
(define (tc-agg-size-cache-storage-ensure!) : unit
  (tc_core.tc-agg-size-cache-storage-ensure-for-job!
    (tc_core.tc-serial-job-state)))

(define (tc-agg-align-cache-storage-ensure!) : unit
  (tc_core.tc-agg-align-cache-storage-ensure-for-job!
    (tc_core.tc-serial-job-state)))

(define (tc-agg-regwords-cache-storage-ensure!) : unit
  (tc_core.tc-agg-regwords-cache-storage-ensure-for-job!
    (tc_core.tc-serial-job-state)))

;; The demand-driven CTFE base env: when metadata is demanded, the first
;; request builds once into the pool context's base arena, caches the env in
;; the macro-walk state, and every later request reuses it instead of walking
;; the program again. When no metadata is demanded the gate hands back an empty
;; env and leaves the cache untouched.
(define (tc-ctfe-env-demand-cache-smoke?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools)]
    [state : tc_core.TcMacroState (tc_core.tc-context-macro-state ctx)]
    [base-arena : i64 (ast.ast-node-pool-context-base-arena pools)]
    ;; Metadata demanded: exactly one build into the base arena, then reuse.
    (tc_core.compiler-typecheck-ctfe-env-cache-clear! state)
    (tc-macro-walk-set! state ctfe-needs-metadata true)
    (let
      [first-env : ctfe_support.CtfeEnv (tc_core.tc-ctfe-env ctx)]
      [built-ready? : bool
        (tc-macro-walk-field state macro-expand-ctfe-env-ready)]
      [built-has-metadata? : bool
        (tc-macro-walk-field state macro-expand-ctfe-env-has-metadata)]
      [built-owner : i64
        (tc-macro-walk-field state macro-expand-ctfe-env-owner-arena)]
      [second-env : ctfe_support.CtfeEnv (tc_core.tc-ctfe-env ctx)]
      [first-layouts : ctfe_support.CtfeLayoutInfoList
        (ctfe_support.ctfe-env-layouts (& first-env))]
      [second-layouts : ctfe_support.CtfeLayoutInfoList
        (ctfe_support.ctfe-env-layouts (& second-env))]
      [first-reflections : ctfe_support.CtfeReflectInfoList
        (ctfe_support.ctfe-env-reflections (& first-env))]
      [second-reflections : ctfe_support.CtfeReflectInfoList
        (ctfe_support.ctfe-env-reflections (& second-env))]
      ;; No metadata demanded: empty env, cache stays unset.
      [_cleared : unit (tc_core.compiler-typecheck-ctfe-env-cache-clear! state)]
      [_gate-off : unit (tc-macro-walk-set! state ctfe-needs-metadata false)]
      [empty-env : ctfe_support.CtfeEnv (tc_core.tc-ctfe-env ctx)]
      [empty-reflections : ctfe_support.CtfeReflectInfoList
        (ctfe_support.ctfe-env-reflections (& empty-env))]
      [empty-layouts : ctfe_support.CtfeLayoutInfoList
        (ctfe_support.ctfe-env-layouts (& empty-env))]
      [empty-ready? : bool
        (tc-macro-walk-field state macro-expand-ctfe-env-ready)]
      [empty-has-metadata? : bool
        (tc-macro-walk-field state macro-expand-ctfe-env-has-metadata)]
      ;; Restore the fresh-state defaults for later tests sharing this walk
      ;; state: cache cleared and the conservative metadata demand back on.
      [_restore : unit
        (begin
          (tc_core.compiler-typecheck-ctfe-env-cache-clear! state)
          (tc-macro-walk-set! state ctfe-needs-metadata true))]
      (and
        built-ready?
        built-has-metadata?
        (= built-owner base-arena)
        (= first-layouts.len second-layouts.len)
        (= first-reflections.len second-reflections.len)
        (= second-layouts.len empty-layouts.len)
        (= second-reflections.len empty-reflections.len)
        (not empty-ready?)
        (not empty-has-metadata?)))))

(test
  tc-ctfe-env-demand-cache
  (if (tc-ctfe-env-demand-cache-smoke?)
    unit
    (io.panic "typecheck: CTFE env demand cache smoke failed")))

(cfg
  test
  (define (tc-comptime-sequence-field-pair-ok?
    [owner : String]
    [elem-ty : ast.AstType]) : bool
    (and
      (match (tc_core.tc-comptime-sequence-field-type
        (tc_core.tc-global-shared-view owner)
        (tc_core.tc-global-shared-view elem-ty)
        cbi.compiler-builtin-id-fix-items)
        [(Ok (DynArray _)) true]
        [_ false])
      (match (tc_core.tc-comptime-sequence-field-type
        owner
        elem-ty
        cbi.compiler-builtin-id-fix-len)
        [(Ok (I64)) true]
        [_ false]))))

(cfg
  test
  (define (tc-comptime-structural-field-ids-ok?) : bool
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [generated-items : i64 (ci.intern-generated-canonical-name "items")]
      (and
        (tc-comptime-sequence-field-pair-ok? "ExprList" (Expr))
        (tc-comptime-sequence-field-pair-ok?
          "ExprClauseList"
          (tc_core.tc-macro-expr-clause-type))
        (tc-comptime-sequence-field-pair-ok?
          "ExprBindingClauseList"
          (tc_core.tc-macro-expr-binding-clause-type))
        (tc-comptime-sequence-field-pair-ok?
          "PatternList"
          (tc_core.tc-macro-pattern-type))
        (tc-comptime-sequence-field-pair-ok?
          "MatchArmList"
          (tc_core.tc-macro-match-arm-type))
        (match (tc_core.tc-comptime-expr-clause-field-type
          cbi.compiler-builtin-id-fix-first)
          [(Ok (Expr)) true]
          [_ false])
        (match (tc_core.tc-comptime-expr-clause-field-type
          cbi.compiler-builtin-id-fix-second)
          [(Ok (Expr)) true]
          [_ false])
        (match (tc_core.tc-comptime-expr-binding-clause-field-type
          cbi.compiler-builtin-id-fix-name)
          [(Ok (String)) true]
          [_ false])
        (match (tc_core.tc-comptime-expr-binding-clause-field-type
          cbi.compiler-builtin-id-fix-has_type)
          [(Ok (Bool)) true]
          [_ false])
        (match (tc_core.tc-comptime-expr-binding-clause-field-type
          cbi.compiler-builtin-id-fix-ty)
          [(Ok (Expr)) true]
          [_ false])
        (match (tc_core.tc-comptime-expr-binding-clause-field-type
          cbi.compiler-builtin-id-fix-init)
          [(Ok (Expr)) true]
          [_ false])
        (match (tc_core.tc-comptime-match-arm-field-type
          cbi.compiler-builtin-id-fix-pattern)
          [(Ok _) true]
          [_ false])
        (match (tc_core.tc-comptime-match-arm-field-type
          cbi.compiler-builtin-id-fix-body)
          [(Ok (Expr)) true]
          [_ false])
        (match (tc_core.tc-comptime-sequence-field-type
          "ExprList"
          (Expr)
          generated-items)
          [(Err message)
            (string.eq
              message
              (cdiag.compiler-diagnostic-typecheck-tagged
                (UnknownStructField)
                "typecheck: unknown struct field ExprList.items"))]
          [_ false])))))

(cfg
  test
  (test
    tc-comptime-structural-field-ids
    (if (tc-comptime-structural-field-ids-ok?)
      unit
      (io.panic "typecheck: comptime structural field ID test failed"))))

(test
  tc-quasiquote-template-explicit-pool-isolation
  (let
    [prev : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [quoted-value-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Var 101))]
    [quote-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Quote quoted-value-a))]
    [unquote-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Unquote quote-a))]
    [return-value-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Var 202))]
    [return-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Return return-value-a))]
    [template-items : ast.AstExprList (ast.ast-expr-list-new)]
    [_item-unquote : unit
      (ast.ast-expr-list-push (&mut template-items) unquote-a)]
    [_item-return : unit
      (ast.ast-expr-list-push (&mut template-items) return-a)]
    [quoted-value-b : i64
      (ast.ast-node-pool-context-expr-push pools-b (Var 901))]
    [quote-b : i64 (ast.ast-node-pool-context-expr-push pools-b (Var 902))]
    [unquote-b : i64
      (ast.ast-node-pool-context-expr-push pools-b (Unquote quote-b))]
    [return-value-b : i64
      (ast.ast-node-pool-context-expr-push pools-b (Var 903))]
    [return-b : i64
      (ast.ast-node-pool-context-expr-push pools-b (Return return-value-b))]
    [job-state : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new-with-source-names-and-job-state
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-a
        (ci.intern-source-name-session-capture-active-handle)
        job-state)]
    [env : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-state)]
    [_install-decoy : unit (ast.ast-node-pool-context-install! pools-b)]
    [result : tc_core.ResultTcUnit
      (tc_core.tc-quasiquote-template-ok ctx env (Begin template-items))]
    [decoy-still-installed? : bool
      (and
        (=
          (ast.ast-node-pool-active-expr-segment-bases)
          (ast.ast-node-pool-context-expr-segment-bases pools-b))
        (match (ast.ast-node-pool-context-expr-get pools-b quote-b)
          [(Var name-id) (= name-id 902)]
          [_ false]))]
    [ok? : bool
      (and
        (= quoted-value-a quoted-value-b)
        (= quote-a quote-b)
        (= unquote-a unquote-b)
        (= return-value-a return-value-b)
        (= return-a return-b)
        (match result
          [(Ok) true]
          [(Err _) false])
        decoy-still-installed?
        (= (ast.ast-node-pool-context-expr-len pools-a) 5)
        (= (ast.ast-node-pool-context-expr-len pools-b) 5))]
    (ast.ast-node-pool-context-install! prev)
    (if ok?
      unit
      (io.panic "typecheck: quasiquote template pool isolation failed"))))

(define (tc-moved-capacity [set : tc_core.TcMovedSet]) : i64
  (let
    [roots : tc_i64_i64_map.Map
      (tc_core.tc-moved-roots (tc_core.tc-global-shared-view set))]
    [partials : tc_i64_i64_map.Map
      (tc_core.tc-moved-partials (tc_core.tc-global-shared-view set))]
    [paths : tc_core.TcMovedPathFacts
      (tc_core.tc-moved-paths (tc_core.tc-global-shared-view set))]
    [hidden : tc_i64_i64_map.Map (tc_core.tc-moved-hidden-atomic-users set)]
    (+
      (+
        (tc_i64_i64_map.capacity (& roots))
        (tc_i64_i64_map.capacity (& partials)))
      (+
        (tc_core.tc-moved-path-facts-len paths)
        (tc_i64_i64_map.capacity (& hidden))))))

(define (tc-move-path-segments-storage-node-count
  [segments : tc_core.TcMovePathSegments]) : i64
  (if (= segments.store-address 0)
    0
    (__tl-project-field
      (tc_core.tc-move-path-segment-store-read segments.store-address)
      len)))

(define (tc-move-path-segments-storage-capacity
  [segments : tc_core.TcMovePathSegments]) : i64
  (if (= segments.store-address 0)
    0
    (array-length
      (__tl-project-field
        (tc_core.tc-move-path-segment-store-read segments.store-address)
        nodes))))

(define (tc-move-path-hash-combine [seed : i64] [component : i64]) : i64
  (bit-xor (* seed 2654435761) (+ component 40503)))

(define (tc-move-path-segments-hash [segments : tc_core.TcMovePathSegments]) : i64
  (let
    [cursor : i64 segments.tail]
    [remaining : i64 segments.len]
    [out : i64 17]
    (while (> remaining 0)
      (let
        [node : tc_core.TcMovePathSegmentNode
          (tc_core.tc-move-path-segments-node segments cursor)]
        [seed : i64
          (cond
            [(= node.kind tc_core.tc-move-path-segment-kind-field) 23]
            [(= node.kind tc_core.tc-move-path-segment-kind-tuple) 29]
            [(= node.kind tc_core.tc-move-path-segment-kind-array) 31]
            [(= node.kind tc_core.tc-move-path-segment-kind-slice-split) 37]
            [else 41])]
        (set!
          out
          (tc-move-path-hash-combine
            (tc-move-path-hash-combine seed node.value)
            out))
        (set! cursor node.parent)
        (set! remaining (- remaining 1))))
    out))

(define (tc-moved-path-fact-path [fact : tc_core.TcMovedPathFact]) : tc_core.TcMovePath
  fact.path)

(define (tc-move-path-dense-storage-smoke?) : bool
  (let
    [root-id : i64 (ci.intern "dense-root")]
    [other-root-id : i64 (ci.intern "dense-other")]
    [alpha-id : i64 (ci.intern "alpha")]
    [beta-id : i64 (ci.intern "beta")]
    [empty : tc_core.TcMovePathSegments (tc_core.tc-move-path-segments-empty)]
    [alpha : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-field empty alpha-id)]
    [tuple : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-tuple alpha 2)]
    [array : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-array tuple 3)]
    [mixed : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-field array beta-id)]
    ;; Append a sibling after retaining `mixed`; both share the immutable
    ;; `alpha.2` prefix, and neither may overwrite the other's tail.
    [sibling : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-array tuple 4)]
    [same : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-field
        (tc_core.tc-move-path-segments-append-array
          (tc_core.tc-move-path-segments-append-tuple
            (tc_core.tc-move-path-segments-append-field
              (tc_core.tc-move-path-segments-empty)
              alpha-id)
            2)
          3)
        beta-id)]
    [field-kind : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-field
        (tc_core.tc-move-path-segments-empty)
        alpha-id)]
    [tuple-kind : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-tuple
        (tc_core.tc-move-path-segments-empty)
        alpha-id)]
    [array-kind : tc_core.TcMovePathSegments
      (tc_core.tc-move-path-segments-append-array
        (tc_core.tc-move-path-segments-empty)
        alpha-id)]
    [root : tc_core.TcMovePath
      (tc_core.TcMovePath root-id (tc_core.tc-move-path-segments-empty))]
    [prefix : tc_core.TcMovePath (tc_core.TcMovePath root-id tuple)]
    [mixed-path : tc_core.TcMovePath (tc_core.TcMovePath root-id mixed)]
    [same-path : tc_core.TcMovePath (tc_core.TcMovePath root-id same)]
    [sibling-path : tc_core.TcMovePath (tc_core.TcMovePath root-id sibling)]
    [other-root : tc_core.TcMovePath (tc_core.TcMovePath other-root-id mixed)]
    [split-left : tc_core.TcMovePath
      (tc_core.tc-move-slice-split-half-path root 17 0)]
    [split-right : tc_core.TcMovePath
      (tc_core.tc-move-slice-split-half-path root 17 1)]
    [split-nested-left : tc_core.TcMovePath
      (tc_core.tc-move-slice-split-half-path split-right 18 0)]
    [expected-hash : i64
      (tc-move-path-hash-combine
        (tc-move-path-hash-combine 23 alpha-id)
        (tc-move-path-hash-combine
          (tc-move-path-hash-combine 29 2)
          (tc-move-path-hash-combine
            (tc-move-path-hash-combine 31 3)
            (tc-move-path-hash-combine
              (tc-move-path-hash-combine 23 beta-id)
              17))))]
    [deep : tc_core.TcMovePathSegments (tc_core.tc-move-path-segments-empty)]
    [deep-render : String ""]
    [index : i64 0]
    (while (< index 128)
      (cond
        [(= (% index 3) 0)
          (set! deep (tc_core.tc-move-path-segments-append-field deep alpha-id))
          (set! deep-render (str_cat.str-cat deep-render ".alpha"))]
        [(= (% index 3) 1)
          (set! deep (tc_core.tc-move-path-segments-append-tuple deep index))
          (set!
            deep-render
            (str_cat.str-cat deep-render "." (string.int->string index)))]
        [else
          (set! deep (tc_core.tc-move-path-segments-append-array deep index))
          (set!
            deep-render
            (str_cat.str-cat deep-render "[" (string.int->string index) "]"))])
      (set! index (+ index 1)))
    (and
      (tc_core.tc-move-path-eq? mixed-path same-path)
      (not (tc_core.tc-move-path-eq? mixed-path sibling-path))
      (not (tc_core.tc-move-path-segments-eq? field-kind tuple-kind))
      (not (tc_core.tc-move-path-segments-eq? field-kind array-kind))
      (tc_core.tc-move-path-conflicts? root mixed-path)
      (tc_core.tc-move-path-conflicts? prefix mixed-path)
      (tc_core.tc-move-path-conflicts? mixed-path same-path)
      (not (tc_core.tc-move-path-conflicts? mixed-path sibling-path))
      (not (tc_core.tc-move-path-conflicts? mixed-path other-root))
      (tc_core.tc-move-path-conflicts? root split-left)
      (not (tc_core.tc-move-path-conflicts? split-left split-right))
      (tc_core.tc-move-path-conflicts? split-right split-nested-left)
      (not (tc_core.tc-move-path-conflicts? split-left split-nested-left))
      (tc_core.tc-move-path-slice-half? split-left 0)
      (tc_core.tc-move-path-slice-half? split-right 1)
      (string.eq
        (tc_core.tc-move-path-render split-left)
        "dense-root.<slice-split>.0")
      (string.eq (tc_core.tc-move-path-render prefix) "dense-root.alpha.2")
      (string.eq
        (tc_core.tc-move-path-render mixed-path)
        "dense-root.alpha.2[3].beta")
      (string.eq
        (tc_core.tc-move-path-render sibling-path)
        "dense-root.alpha.2[4]")
      (= (tc-move-path-segments-hash mixed) expected-hash)
      (= (tc-move-path-segments-storage-node-count mixed) 5)
      (= deep.len 128)
      (= (tc-move-path-segments-storage-node-count deep) 128)
      (= (tc-move-path-segments-storage-capacity deep) 128)
      (string.eq (tc_core.tc-move-path-segments-render deep) deep-render))))

(test
  tc-move-path-dense-storage
  (if (tc-move-path-dense-storage-smoke?)
    unit
    (io.panic "typecheck: dense move-path storage smoke failed")))

;; The fallback walk runs only for bodies without recorded facts, which no
;; source fixture reaches, so its shapes are checked on constructed nodes.
(test
  tc-move-tail-diverges-shapes
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 16 8)]
    [value : i64 (ast.ast-node-pool-context-expr-push pools (Literal (Unit)))]
    [returns : i64 (ast.ast-node-pool-context-expr-push pools (Return value))]
    [breaks : i64 (ast.ast-node-pool-context-expr-push pools Break)]
    [continues : i64 (ast.ast-node-pool-context-expr-push pools Continue)]
    [ends-in-return : ast.AstExprList (ast.ast-expr-list-new)]
    [return-then-value : ast.AstExprList (ast.ast-expr-list-new)]
    [_fill : unit
      (begin
        (ast.ast-expr-list-push (&mut ends-in-return) value)
        (ast.ast-expr-list-push (&mut ends-in-return) returns)
        (ast.ast-expr-list-push (&mut return-then-value) returns)
        (ast.ast-expr-list-push (&mut return-then-value) value))]
    [tail-return : i64
      (ast.ast-node-pool-context-expr-push pools (Begin ends-in-return))]
    [tail-value : i64
      (ast.ast-node-pool-context-expr-push pools (Begin return-then-value))]
    [empty : i64
      (ast.ast-node-pool-context-expr-push
        pools
        (Begin (ast.ast-expr-list-new)))]
    [both-leave : i64
      (ast.ast-node-pool-context-expr-push pools (If value tail-return breaks))]
    [one-leaves : i64
      (ast.ast-node-pool-context-expr-push pools (If value continues value))]
    [spanned : i64
      (ast.ast-expr-source-view-with-pools
        pools
        both-leave
        (ast.ast-source-span 3 1 3 9))]
    [ctx : tc_core.TcContext (tc-literal-pool-test-context pools)]
    [bases : i64 (tc_core.tc-context-expr-bases ctx)]
    (unless
      (and
        (tc_core.tc-move-tail-diverges? ctx bases returns)
        (tc_core.tc-move-tail-diverges? ctx bases breaks)
        (tc_core.tc-move-tail-diverges? ctx bases continues)
        (tc_core.tc-move-tail-diverges? ctx bases tail-return)
        (tc_core.tc-move-tail-diverges? ctx bases both-leave)
        (tc_core.tc-move-tail-diverges? ctx bases spanned)
        (not (tc_core.tc-move-tail-diverges? ctx bases value))
        (not (tc_core.tc-move-tail-diverges? ctx bases tail-value))
        (not (tc_core.tc-move-tail-diverges? ctx bases empty))
        (not (tc_core.tc-move-tail-diverges? ctx bases one-leaves))
        ;; Without recorded facts the arm query is the walk.
        (tc_core.tc-move-arm-diverges? ctx bases both-leave)
        (not (tc_core.tc-move-arm-diverges? ctx bases one-leaves)))
      (io.panic "typecheck: tail divergence shape was misjudged"))))

(define (tc-dependency-tlci-route-counter-value-for-job
  [state : tc_core.TcJobState]
  [counter : i64]) : i64
  (tc_core.tc-dependency-tlci-route-counter-value
    (tc_core.tc-job-state-macro-state state)
    counter))

(cfg
  test
  (test
    compiler-typecheck-dependency-tlci-route-job-isolation
    (let
      [left : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [right : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [left-macro : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state left)]
      [right-macro : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state right)]
      (tc_core.macro-dependency-catalog-slot-cache-store! left-macro 5 11)
      (tc_core.macro-dependency-catalog-slot-cache-store! right-macro 5 22)
      (tc_core.tc-dependency-tlci-route-counter-add!
        left-macro
        tc_core.tc-dependency-tlci-native-dispatches
        2)
      (tc_core.tc-dependency-tlci-route-counter-add!
        right-macro
        tc_core.tc-dependency-tlci-native-dispatches
        7)
      (tc_core.tc-dependency-tlci-route-counter-add!
        left-macro
        tc_core.tc-dependency-tlci-parameter-name-lookups
        3)
      (tc_core.macro-dependency-catalog-slot-cache-reset! right-macro)
      (tc_core.tc-dependency-tlci-route-counters-reset! right-macro)
      (test.assert-i64-eq
        (tc_core.macro-dependency-catalog-slot-cache-value-or left-macro 5 -2)
        11
        "right reset preserves left provenance catalog slot")
      (test.assert-i64-eq
        (tc_core.macro-dependency-catalog-slot-cache-value-or right-macro 5 -2)
        -2
        "provenance catalog slot reset is job-local")
      (test.assert-i64-eq
        (tc-dependency-tlci-route-counter-value-for-job
          left
          tc_core.tc-dependency-tlci-native-dispatches)
        2
        "right reset preserves left dependency dispatches")
      (test.assert-i64-eq
        (tc-dependency-tlci-route-counter-value-for-job
          left
          tc_core.tc-dependency-tlci-parameter-name-lookups)
        3
        "interleaved dependency route fields share no storage")
      (test.assert-i64-eq
        (tc-dependency-tlci-route-counter-value-for-job
          right
          tc_core.tc-dependency-tlci-native-dispatches)
        0
        "right dependency route reset is job-local"))))

(cfg
  test
  (test
    macro-decl-generation-global-batch-two
    (let
      [job : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job)]
      [first : i64 (tc_core.macro-decl-generation-enter! state)]
      [empty-mark : i64 (tc-macro-walk-field state macro-decl-generation-mark)]
      [enclosing : i64 (arena.tl_arena_current)]
      [_batch-one-garbage : unit
        (begin
          (unsafe
            (arena.tl_arena_set first))
          (__tl_make-array i64 512)
          (unsafe
            (arena.tl_arena_set enclosing)))]
      [batch-one-mark : i64 (tc_core.macro-generation-base-mark first)]
      [second : i64 (tc_core.macro-decl-generation-enter! state)]
      [third : i64 (tc_core.macro-decl-generation-enter! state)]
      [third-batch-used : i64
        (tc-macro-walk-field state macro-decl-generation-batch-used)]
      [rewound-mark : i64 (tc_core.macro-generation-base-mark third)]
      (tc_core.macro-decl-generations-release! state)
      (test.assert-i64-eq
        (tc-macro-walk-field state macro-decl-generation-batch-size)
        2
        "declaration generations use the global batch-two cadence")
      (test.assert-i64-eq second first "second declaration stays in batch")
      (test.assert-i64-eq
        third-batch-used
        1
        "third declaration starts a new batch without a source-specific first batch")
      ;; The new batch rewinds the same arena instead of mapping another one,
      ;; reclaiming everything the first batch allocated (#7934).
      (test.assert-i64-eq third first "a new batch reuses the arena")
      (test.assert-true
        (> batch-one-mark empty-mark)
        "the first batch allocated in its generation")
      (test.assert-i64-eq
        rewound-mark
        empty-mark
        "the new batch starts from the empty arena"))))

(cfg
  test
  (define (macro-decl-list-slots-address [items : ast.AstDeclList]) : i64
    (unsafe
      (cast
        (ptr->int (ptr-cast (__tl_array-data items.slots) : (Ptr u8)))
        : i64))))

(cfg
  test
  (define (macro-decl-path-list-slots-address [items : ast.AstDeclPathList]) : i64
    (unsafe
      (cast
        (ptr->int (ptr-cast (__tl_array-data items.slots) : (Ptr u8)))
        : i64))))

(cfg
  test
  (define (macro-decl-module-eq? [decl : ast.AstDecl] [wanted : i64]) : bool
    (match decl
      [(Module name) (= name wanted)]
      [_ false])))

(cfg
  test
  (define (macro-decl-list-append-headroom-smoke?) : bool
    (let
      [left-id : i64 (ci.intern-generated-name "left")]
      [right-a-id : i64 (ci.intern-generated-name "right-a")]
      [right-b-id : i64 (ci.intern-generated-name "right-b")]
      [alias-id : i64 (ci.intern-generated-name "alias")]
      [prefix-a-id : i64 (ci.intern-generated-name "prefix-a")]
      [prefix-b-id : i64 (ci.intern-generated-name "prefix-b")]
      [left : ast.AstDeclList (ast.ast-decl-list-with-capacity 1)]
      [_left : unit (ast.ast-decl-list-push (&mut left) (Module left-id))]
      [right-base : ast.AstDeclList (ast.ast-decl-list-new)]
      [right-tail : ast.AstDeclList
        (ast.ast-decl-list-prepend-builder (Module right-b-id) right-base)]
      [right : ast.AstDeclList
        (ast.ast-decl-list-prepend-builder (Module right-a-id) right-tail)]
      [right-address : i64
        (macro-decl-list-slots-address (tc_core.tc-global-shared-view right))]
      [reused : ast.AstDeclList
        (tc_core.macro-decl-list-append
          left
          (tc_core.tc-global-shared-view right))]
      [alias-left : ast.AstDeclList
        (begin
          (set! (array-ref right.slots 0) (ast.AstDecl.Module alias-id))
          (ast.AstDeclList
            (tc_core.tc-global-shared-view right.slots)
            0
            1
            false))]
      [copied : ast.AstDeclList
        (tc_core.macro-decl-list-append
          alias-left
          (tc_core.tc-global-shared-view right))]
      [reserved : ast.AstDeclList
        (tc_core.macro-decl-list-with-prefix-reserve right 8)]
      [reserved-address : i64
        (macro-decl-list-slots-address (tc_core.tc-global-shared-view reserved))]
      [prefix-base : ast.AstDeclList (ast.ast-decl-list-new)]
      [prefix-tail : ast.AstDeclList
        (ast.ast-decl-list-prepend-builder (Module prefix-a-id) prefix-base)]
      [prefix-rev : ast.AstDeclList
        (ast.ast-decl-list-prepend-builder (Module prefix-b-id) prefix-tail)]
      [prefixed : ast.AstDeclList
        (macro-decl-list-prefix-rev-current-suffix
          prefix-rev
          (tc_core.tc-global-shared-view reserved))]
      (and
        (=
          (macro-decl-list-slots-address (tc_core.tc-global-shared-view reused))
          right-address)
        (= reused.offset 1)
        (= (ast.ast-decl-list-len (& reused)) 3)
        (macro-decl-module-eq? (ast.ast-decl-list-ref reused 0) left-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref reused 1) right-a-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref reused 2) right-b-id)
        (not
          (=
            (macro-decl-list-slots-address
              (tc_core.tc-global-shared-view copied))
            right-address))
        (macro-decl-module-eq? (ast.ast-decl-list-ref copied 0) alias-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref copied 1) right-a-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref copied 2) right-b-id)
        (= reserved.offset 8)
        (=
          (macro-decl-list-slots-address
            (tc_core.tc-global-shared-view prefixed))
          reserved-address)
        (= prefixed.offset 6)
        (macro-decl-module-eq? (ast.ast-decl-list-ref prefixed 0) prefix-a-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref prefixed 1) prefix-b-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref prefixed 2) right-a-id)
        (macro-decl-module-eq? (ast.ast-decl-list-ref prefixed 3) right-b-id)))))

(cfg
  test
  (define (macro-decl-path-list-append-headroom-smoke?) : bool
    (let
      [left-id : i64 (ci.intern-generated-name "left-path")]
      [right-a-id : i64 (ci.intern-generated-name "right-a-path")]
      [right-b-id : i64 (ci.intern-generated-name "right-b-path")]
      [alias-id : i64 (ci.intern-generated-name "alias-path")]
      [prefix-a-id : i64 (ci.intern-generated-name "prefix-a-path")]
      [prefix-b-id : i64 (ci.intern-generated-name "prefix-b-path")]
      [left : ast.AstDeclPathList (ast.ast-decl-path-list-with-capacity 1)]
      [_left : unit
        (ast.ast-decl-path-list-push-with-owner-id (&mut left) "left" left-id)]
      [right-base : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
      [right-tail : ast.AstDeclPathList
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          "right-b"
          right-b-id
          right-base)]
      [right : ast.AstDeclPathList
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          "right-a"
          right-a-id
          right-tail)]
      [right-address : i64
        (macro-decl-path-list-slots-address
          (tc_core.tc-global-shared-view right))]
      [reused : ast.AstDeclPathList
        (tc_core.macro-decl-path-list-append
          left
          (tc_core.tc-global-shared-view right))]
      [alias-left : ast.AstDeclPathList
        (begin
          (set! (array-ref right.slots 0) "alias")
          (set! (array-ref right.owner-ids 0) alias-id)
          (ast.AstDeclPathList
            (tc_core.tc-global-shared-view right.slots)
            (tc_core.tc-global-shared-view right.owner-ids)
            0
            1
            false))]
      [copied : ast.AstDeclPathList
        (tc_core.macro-decl-path-list-append
          alias-left
          (tc_core.tc-global-shared-view right))]
      [reserved : ast.AstDeclPathList
        (tc_core.macro-decl-path-list-with-prefix-reserve right 8)]
      [reserved-address : i64
        (macro-decl-path-list-slots-address
          (tc_core.tc-global-shared-view reserved))]
      [prefix-base : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
      [prefix-tail : ast.AstDeclPathList
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          "prefix-a"
          prefix-a-id
          prefix-base)]
      [prefix-rev : ast.AstDeclPathList
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          "prefix-b"
          prefix-b-id
          prefix-tail)]
      [prefixed : ast.AstDeclPathList
        (macro-decl-path-list-prefix-rev-current-suffix
          prefix-rev
          (tc_core.tc-global-shared-view reserved))]
      (and
        (=
          (macro-decl-path-list-slots-address
            (tc_core.tc-global-shared-view reused))
          right-address)
        (= reused.offset 1)
        (= (ast.ast-decl-path-list-len (& reused)) 3)
        (string.eq (ast.ast-decl-path-list-get (& reused) 0 "") "left")
        (string.eq (ast.ast-decl-path-list-get (& reused) 1 "") "right-a")
        (string.eq (ast.ast-decl-path-list-get (& reused) 2 "") "right-b")
        (= (ast.ast-decl-path-list-owner-id (& reused) 0 -1) left-id)
        (= (ast.ast-decl-path-list-owner-id (& reused) 1 -1) right-a-id)
        (= (ast.ast-decl-path-list-owner-id (& reused) 2 -1) right-b-id)
        (not
          (=
            (macro-decl-path-list-slots-address
              (tc_core.tc-global-shared-view copied))
            right-address))
        (string.eq (ast.ast-decl-path-list-get (& copied) 0 "") "alias")
        (string.eq (ast.ast-decl-path-list-get (& copied) 1 "") "right-a")
        (string.eq (ast.ast-decl-path-list-get (& copied) 2 "") "right-b")
        (= (ast.ast-decl-path-list-owner-id (& copied) 0 -1) alias-id)
        (= (ast.ast-decl-path-list-owner-id (& copied) 1 -1) right-a-id)
        (= (ast.ast-decl-path-list-owner-id (& copied) 2 -1) right-b-id)
        (= reserved.offset 8)
        (=
          (macro-decl-path-list-slots-address
            (tc_core.tc-global-shared-view prefixed))
          reserved-address)
        (= prefixed.offset 6)
        (string.eq (ast.ast-decl-path-list-get (& prefixed) 0 "") "prefix-a")
        (string.eq (ast.ast-decl-path-list-get (& prefixed) 1 "") "prefix-b")
        (string.eq (ast.ast-decl-path-list-get (& prefixed) 2 "") "right-a")
        (string.eq (ast.ast-decl-path-list-get (& prefixed) 3 "") "right-b")
        (= (ast.ast-decl-path-list-owner-id (& prefixed) 0 -1) prefix-a-id)
        (= (ast.ast-decl-path-list-owner-id (& prefixed) 1 -1) prefix-b-id)
        (= (ast.ast-decl-path-list-owner-id (& prefixed) 2 -1) right-a-id)
        (= (ast.ast-decl-path-list-owner-id (& prefixed) 3 -1) right-b-id)))))

(cfg
  test
  (test
    macro-decl-list-append-headroom
    (if (macro-decl-list-append-headroom-smoke?)
      (if (macro-decl-path-list-append-headroom-smoke?)
        unit
        (io.panic
          "typecheck: macro decl-path-list append headroom smoke failed"))
      (io.panic "typecheck: macro decl-list append headroom smoke failed"))))

(define (macro-decl-list-prefix-rev-current-suffix
  [prefix-rev : ast.AstDeclList]
  [suffix : ast.AstDeclList]) : ast.AstDeclList
  (let
    [prefix-count : i64 (ast.ast-decl-list-len (& prefix-rev))]
    [suffix-offset : i64 suffix.offset]
    (if (<= prefix-count suffix-offset)
      (let
        [cursor : ast.AstDeclList prefix-rev]
        [write-index : i64 (- suffix-offset 1)]
        [done : bool false]
        (while (not done)
          (match (ast.ast-decl-list-step cursor)
            [(Nil) (set! done true)]
            [(Cons decl rest)
              (set! (array-ref suffix.slots write-index) decl)
              (set! write-index (- write-index 1))
              (set! cursor rest)]))
        (ast.AstDeclList
          suffix.slots
          (- suffix-offset prefix-count)
          (+ prefix-count suffix.len)
          false))
      (tc_core.macro-decl-list-append
        (tc_core.macro-decl-list-reverse prefix-rev)
        suffix))))

(define (macro-decl-path-list-prefix-rev-current-suffix
  [prefix-rev : ast.AstDeclPathList]
  [suffix : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [prefix-count : i64 (ast.ast-decl-path-list-len (& prefix-rev))]
    [suffix-offset : i64 suffix.offset]
    (if (<= prefix-count suffix-offset)
      (let
        [cursor : ast.AstDeclPathList prefix-rev]
        [write-index : i64 (- suffix-offset 1)]
        [done : bool false]
        (while (not done)
          (let
            [owner-id : i64
              (ast.ast-decl-path-list-owner-id
                (& cursor)
                0
                cbi.compiler-builtin-id-fix-empty)]
            [provenance-id : i64
              (ast.ast-decl-path-list-provenance-id
                (& cursor)
                0
                cbi.compiler-builtin-id-fix-empty)]
            (match (ast.ast-decl-path-list-step cursor)
              [(Nil) (set! done true)]
              [(Cons path rest)
                (set! (array-ref suffix.slots write-index) path)
                (ast.ast-decl-path-list-set-owner-and-provenance-id-at-physical-index!
                  suffix.owner-ids
                  (array-length suffix.slots)
                  write-index
                  owner-id
                  provenance-id)
                (set! write-index (- write-index 1))
                (set! cursor rest)])))
        (ast.AstDeclPathList
          suffix.slots
          suffix.owner-ids
          (- suffix-offset prefix-count)
          (+ prefix-count suffix.len)
          false))
      (tc_core.macro-decl-path-list-append
        (tc_core.macro-decl-path-list-reverse prefix-rev)
        suffix))))

(define (macro-segmented-program-decl-at
  [state : tc_core.TcJobState]
  [logical-index : i64]
  [fallback : ast.AstDecl]) : ast.AstDecl
  (let
    [data : tc_core.MacroSegmentedProgramViewData
      (tc_core.macro-segmented-program-view-data
        (tc_core.tc-job-state-macro-program-view-address state))]
    [prefix : ast.AstDeclList data.prefix-rev]
    [prefix-count : i64 (ast.ast-decl-list-len (& prefix))]
    (if (or
      (< logical-index 0)
      (>= logical-index (+ prefix-count data.queue-len)))
      fallback
      (if (< logical-index prefix-count)
        (ast.ast-decl-list-ref prefix (- (- prefix-count 1) logical-index))
        (let
          [remaining : i64 (- logical-index prefix-count)]
          [node-address : i64 data.head]
          [node-index : i64 data.cursor]
          [found : bool false]
          [out : ast.AstDecl fallback]
          (while (and (not found) (> node-address 0))
            (let
              [node : tc_core.MacroProgramSegmentNodeData
                (tc_core.macro-program-segment-node-data node-address)]
              [decls : ast.AstDeclList node.decls]
              [available : i64 (- (ast.ast-decl-list-len (& decls)) node-index)]
              (if (< remaining available)
                (begin
                  (set!
                    out
                    (ast.ast-decl-list-ref decls (+ node-index remaining)))
                  (set! found true))
                (begin
                  (set! remaining (- remaining available))
                  (set! node-address node.next)
                  (set! node-index 0)))))
          out)))))

(define (macro-segmented-program-path-at
  [state : tc_core.TcJobState]
  [logical-index : i64]
  [fallback : String]) : String
  (let
    [data : tc_core.MacroSegmentedProgramViewData
      (tc_core.macro-segmented-program-view-data
        (tc_core.tc-job-state-macro-program-view-address state))]
    [prefix : ast.AstDeclPathList data.prefix-paths-rev]
    [prefix-count : i64 (ast.ast-decl-list-len (& data.prefix-rev))]
    (if (or
      (< logical-index 0)
      (>= logical-index (+ prefix-count data.queue-len)))
      fallback
      (if (< logical-index prefix-count)
        (ast.ast-decl-path-list-get
          (& prefix)
          (- (- prefix-count 1) logical-index)
          fallback)
        (let
          [remaining : i64 (- logical-index prefix-count)]
          [node-address : i64 data.head]
          [node-index : i64 data.cursor]
          [found : bool false]
          [out : String ""]
          (while (and (not found) (> node-address 0))
            (let
              [node : tc_core.MacroProgramSegmentNodeData
                (tc_core.macro-program-segment-node-data node-address)]
              [decls : ast.AstDeclList node.decls]
              [available : i64 (- (ast.ast-decl-list-len (& decls)) node-index)]
              (if (< remaining available)
                (begin
                  (set!
                    out
                    (ast.ast-decl-path-list-get
                      (& node.paths)
                      (+ node-index remaining)
                      (tc_core.tc-global-shared-view fallback)))
                  (set! found true))
                (begin
                  (set! remaining (- remaining available))
                  (set! node-address node.next)
                  (set! node-index 0)))))
          (if found
            out
            fallback))))))

(define (macro-segmented-program-owner-id-at
  [state : tc_core.TcJobState]
  [logical-index : i64]
  [fallback : i64]) : i64
  (let
    [data : tc_core.MacroSegmentedProgramViewData
      (tc_core.macro-segmented-program-view-data
        (tc_core.tc-job-state-macro-program-view-address state))]
    [prefix : ast.AstDeclPathList data.prefix-paths-rev]
    [prefix-count : i64 (ast.ast-decl-list-len (& data.prefix-rev))]
    (if (or
      (< logical-index 0)
      (>= logical-index (+ prefix-count data.queue-len)))
      fallback
      (if (< logical-index prefix-count)
        (ast.ast-decl-path-list-owner-id
          (& prefix)
          (- (- prefix-count 1) logical-index)
          fallback)
        (let
          [remaining : i64 (- logical-index prefix-count)]
          [node-address : i64 data.head]
          [node-index : i64 data.cursor]
          [found : bool false]
          [out : i64 fallback]
          (while (and (not found) (> node-address 0))
            (let
              [node : tc_core.MacroProgramSegmentNodeData
                (tc_core.macro-program-segment-node-data node-address)]
              [decls : ast.AstDeclList node.decls]
              [available : i64 (- (ast.ast-decl-list-len (& decls)) node-index)]
              (if (< remaining available)
                (begin
                  (set!
                    out
                    (ast.ast-decl-path-list-owner-id
                      (& node.paths)
                      (+ node-index remaining)
                      fallback))
                  (set! found true))
                (begin
                  (set! remaining (- remaining available))
                  (set! node-address node.next)
                  (set! node-index 0)))))
          out)))))

(define (macro-segmented-program-iter-current-path
  [iter : (& iter tc_core.MacroSegmentedProgramIter)]) : String
  (ast.ast-decl-path-list-get (& iter.paths) iter.index ""))

(define (macro-segmented-program-iter-current-owner-id
  [iter : (& iter tc_core.MacroSegmentedProgramIter)]) : i64
  (ast.ast-decl-path-list-owner-id
    (& iter.paths)
    iter.index
    cbi.compiler-builtin-id-fix-empty))

(define (macro-segmented-program-iter-current-provenance-id
  [iter : (& iter tc_core.MacroSegmentedProgramIter)]) : i64
  (ast.ast-decl-path-list-provenance-id
    (& iter.paths)
    iter.index
    cbi.compiler-builtin-id-fix-empty))

(define (macro-segmented-program-module-id-at-or
  [state : tc_core.TcJobState]
  [index : i64]
  [fallback : i64]) : i64
  (match (macro-segmented-program-decl-at state index (Module fallback))
    [(Module name) name]
    [_ fallback]))

(define (macro-segmented-program-empty-head-inject!
  [state : tc_core.TcJobState]) : unit
  (let
    [address : i64 (tc_core.tc-job-state-macro-program-view-address state)]
    [data : tc_core.MacroSegmentedProgramViewData
      (tc_core.macro-segmented-program-view-data address)]
    [empty-head : i64
      (in-arena
        (arena.Arena
          (tc_core.macro-expand-scratch-arena-get
            (tc_core.tc-job-state-macro-state state)))
        (tc_core.macro-program-segment-node-new-current
          (ast.ast-decl-list-new)
          (ast.ast-decl-path-list-new)
          (__tl_make-array i64 0)
          data.head))]
    (set! data.head empty-head)
    (tc_core.macro-segmented-program-view-data-set! address data)))

(define (macro-segmented-program-empty-boundary-smoke?
  [state : tc_core.TcJobState]
  [expected : i64]) : bool
  (let
    [iter : tc_core.MacroSegmentedProgramIter
      (tc_core.macro-segmented-program-iter state)]
    ;; Consume the two reversed-prefix rows. The next advance must skip the
    ;; injected empty head and install the first non-empty segment once.
    (tc_core.macro-segmented-program-iter-advance! (&mut iter))
    (tc_core.macro-segmented-program-iter-advance! (&mut iter))
    (and
      iter.has-current
      (match (tc_core.macro-segmented-program-iter-current-decl (& iter))
        [(Module name) (= name expected)]
        [_ false])
      (string.eq (macro-segmented-program-iter-current-path (& iter)) "a")
      (= (macro-segmented-program-iter-current-owner-id (& iter)) 20)
      (= (macro-segmented-program-iter-current-provenance-id (& iter)) 20))))

(define (macro-segmented-program-boundary-smoke?) : bool
  (let
    [p0 : i64 (ci.intern "seg-prefix-0")]
    [p1 : i64 (ci.intern "seg-prefix-1")]
    [a : i64 (ci.intern "seg-a")]
    [b : i64 (ci.intern "seg-b")]
    [c : i64 (ci.intern "seg-c")]
    [x : i64 (ci.intern "seg-x")]
    [y : i64 (ci.intern "seg-y")]
    [z : i64 (ci.intern "seg-z")]
    [prefix-rev : ast.AstDeclList
      (ast.ast-decl-cons
        (Module p1)
        (ast.ast-decl-cons (Module p0) (ast.ast-decl-list-new)))]
    [prefix-paths-rev : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "p1"
        11
        (ast.ast-decl-path-cons-with-owner-id
          "p0"
          10
          (ast.ast-decl-path-list-new)))]
    [source : ast.AstDeclList
      (ast.ast-decl-cons
        (Module a)
        (ast.ast-decl-cons
          (Module b)
          (ast.ast-decl-cons (Module c) (ast.ast-decl-list-new))))]
    [source-paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "a"
        20
        (ast.ast-decl-path-cons-with-owner-id
          "b"
          21
          (ast.ast-decl-path-cons-with-owner-id
            "c"
            22
            (ast.ast-decl-path-list-new))))]
    [xy : ast.AstDeclList
      (ast.ast-decl-cons
        (Module x)
        (ast.ast-decl-cons (Module y) (ast.ast-decl-list-new)))]
    [xy-paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "x"
        30
        (ast.ast-decl-path-cons-with-owner-id
          "y"
          31
          (ast.ast-decl-path-list-new)))]
    [zs : ast.AstDeclList
      (ast.ast-decl-cons (Module z) (ast.ast-decl-list-new))]
    [z-paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id "z" 40 (ast.ast-decl-path-list-new))]
    [state : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [out-rev : ast.AstDeclList prefix-rev]
    [out-paths-rev : ast.AstDeclPathList prefix-paths-rev]
    (tc_core.macro-expand-scratch-begin!
      (tc_core.tc-job-state-macro-state state))
    (tc_core.macro-segmented-program-begin!
      state
      (tc_core.tc-global-shared-view out-rev)
      (tc_core.tc-global-shared-view out-paths-rev)
      source
      source-paths)
    (macro-segmented-program-empty-head-inject! state)
    (let
      [empty-boundary-ok : bool
        (macro-segmented-program-empty-boundary-smoke? state a)]
      [initial-ok : bool
        (and
          (= (tc_core.macro-segmented-program-decl-count state) 5)
          (= (macro-segmented-program-module-id-at-or state 0 -1) p0)
          (= (macro-segmented-program-module-id-at-or state 1 -1) p1)
          (= (macro-segmented-program-module-id-at-or state 2 -1) a)
          (= (macro-segmented-program-module-id-at-or state 3 -1) b)
          (= (macro-segmented-program-module-id-at-or state 4 -1) c)
          (string.eq (macro-segmented-program-path-at state 0 "") "p0")
          (= (macro-segmented-program-owner-id-at state 4 -1) 22))]
      (tc_core.macro-segmented-program-splice-current! state xy xy-paths)
      ;; Nested compiler work resets derived file state while a splice is
      ;; active; that boundary must not cancel the walk-owned cursor.
      (tc_core.tc-job-state-reset-file-state! state)
      (let
        [first-splice-ok : bool
          (and
            (tc_core.macro-segmented-program-active? state)
            (= (tc_core.macro-segmented-program-decl-count state) 6)
            (= (tc_core.macro-segmented-program-current-owner-id state) 30)
            (string.eq (tc_core.macro-segmented-program-current-path state) "x"))]
        (set!
          out-rev
          (ast.ast-decl-list-prepend-builder
            (tc_core.macro-segmented-program-current-decl state)
            out-rev))
        (set!
          out-paths-rev
          (ast.ast-decl-path-list-prepend-builder-with-owner-id
            (tc_core.macro-segmented-program-current-path state)
            (tc_core.macro-segmented-program-current-owner-id state)
            out-paths-rev))
        (tc_core.macro-segmented-program-advance! state)
        (tc_core.macro-segmented-program-prefix-set!
          state
          out-rev
          out-paths-rev)
        (tc_core.macro-segmented-program-splice-current! state zs z-paths)
        (let
          [flat : tc_core.MacroSegmentedProgramFlatView
            (tc_core.macro-segmented-program-flatten-raw state)]
          [flat-decls : ast.AstDeclList flat.decls]
          [flat-paths : ast.AstDeclPathList flat.paths]
          [iter : tc_core.MacroSegmentedProgramIter
            (tc_core.macro-segmented-program-iter state)]
          [iter-index : i64 0]
          [iter-ok : bool true]
          [nested-ok : bool
            (and
              (= (ast.ast-decl-list-len (& flat-decls)) 6)
              (= (macro-segmented-program-module-id-at-or state 0 -1) p0)
              (= (macro-segmented-program-module-id-at-or state 1 -1) p1)
              (= (macro-segmented-program-module-id-at-or state 2 -1) x)
              (= (macro-segmented-program-module-id-at-or state 3 -1) z)
              (= (macro-segmented-program-module-id-at-or state 4 -1) b)
              (= (macro-segmented-program-module-id-at-or state 5 -1) c)
              (string.eq (ast.ast-decl-path-list-get (& flat-paths) 3 "") "z")
              (= (ast.ast-decl-path-list-owner-id (& flat-paths) 3 -1) 40)
              (string.eq (ast.ast-decl-path-list-get (& flat-paths) 4 "") "b")
              (= (ast.ast-decl-path-list-owner-id (& flat-paths) 5 -1) 22))]
          ;; The derived-index iterator must preserve declaration,
          ;; path, and owner alignment across prefix, split, and
          ;; inserted-segment boundaries.
          (while (and iter-ok iter.has-current)
            (if (>= iter-index 6)
              (set! iter-ok false)
              (let
                [expected-id : i64
                  (match (ast.ast-decl-list-ref flat-decls iter-index)
                    [(Module name) name]
                    [_ -1])]
                [actual-id : i64
                  (match (tc_core.macro-segmented-program-iter-current-decl
                    (& iter))
                    [(Module name) name]
                    [_ -1])]
                (if (and
                  (= actual-id expected-id)
                  (string.eq
                    (macro-segmented-program-iter-current-path (& iter))
                    (ast.ast-decl-path-list-get (& flat-paths) iter-index ""))
                  (=
                    (macro-segmented-program-iter-current-owner-id (& iter))
                    (ast.ast-decl-path-list-owner-id
                      (& flat-paths)
                      iter-index
                      -1)))
                  unit
                  (set! iter-ok false))))
            (tc_core.macro-segmented-program-iter-advance! (&mut iter))
            (set! iter-index (+ iter-index 1)))
          (tc_core.macro-segmented-program-end! state)
          (tc_core.macro-expand-scratch-release!
            (tc_core.tc-job-state-macro-state state))
          (and
            empty-boundary-ok
            initial-ok
            first-splice-ok
            nested-ok
            iter-ok
            (= iter-index 6)
            (not (tc_core.macro-segmented-program-active? state))))))))

(cfg
  test
  (test
    macro-segmented-program-boundaries
    (if (macro-segmented-program-boundary-smoke?)
      unit
      (io.panic "typecheck: segmented macro program boundary smoke failed"))))

;; Rows for the event-index smoke: 0 a module marker, 1 an aliased import of
;; `id` as alias `id + 1`, 2 the same import under `unsafe`, 3 a plain row.
(define (macro-segmented-event-row [kind : i64] [id : i64]) : ast.AstDecl
  (let
    [marker : ast.AstDeclList
      (tc_core.macro-module-import-marker-decls
        "target"
        id
        (Some (+ id 1))
        (ast.ast-source-span 1 1 1 2))]
    [import : ast.AstDecl (ast.ast-decl-list-ref marker 0)]
    (cond
      [(= kind 0) (Module id)]
      [(= kind 1) import]
      [(= kind 2) (Unsafe (box import))]
      [else (IncludeStr id "row")])))

;; `specs` holds (kind, id) pairs.
(define (macro-segmented-event-rows [specs : (& specs (__tl_dyn-array i64))]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity (/ (array-length specs) 2))]
    [index : i64 0]
    (while (< index (array-length specs))
      (ast.ast-decl-list-push
        (&mut out)
        (macro-segmented-event-row
          (array-ref specs index)
          (array-ref specs (+ index 1))))
      (set! index (+ index 2)))
    out))

;; The event index lists exactly the module/import rows of the program, in
;; program order: the prefix's positions, then each unprocessed node's slot
;; positions from the cursor on.
(define (macro-segmented-events-match-flat? [state : tc_core.TcJobState]) : bool
  (let
    [data : tc_core.MacroSegmentedProgramViewData
      (tc_core.macro-segmented-prefix-events-sync! state)]
    [flat : tc_core.MacroSegmentedProgramFlatView
      (tc_core.macro-segmented-program-flatten-raw state)]
    [flat-decls : ast.AstDeclList flat.decls]
    [count : i64 (ast.ast-decl-list-len (& flat-decls))]
    [expected : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [expected-count : i64 0]
    [actual : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [actual-count : i64 0]
    [base : i64 (ast.ast-decl-list-len (& data.prefix-rev))]
    [node-address : i64 data.head]
    [start : i64 data.cursor]
    [index : i64 0]
    [ok : bool (= data.prefix-scanned base)]
    (while (< index count)
      (when
        (tc_core.macro-decl-list-event-at? (& flat-decls) index)
        (set! (array-ref expected expected-count) index)
        (set! expected-count (+ expected-count 1)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index data.prefix-event-count)
      (set!
        (array-ref actual actual-count)
        (array-ref data.prefix-events index))
      (set! actual-count (+ actual-count 1))
      (set! index (+ index 1)))
    (while (and ok (> node-address 0))
      (let
        [node : tc_core.MacroProgramSegmentNodeData
          (tc_core.macro-program-segment-node-data node-address)]
        [first : i64 (+ node.decls.offset start)]
        [end : i64 (+ node.decls.offset (ast.ast-decl-list-len (& node.decls)))]
        [event : i64 0]
        (while (< event (array-length node.events))
          (let
            [slot : i64 (array-ref node.events event)]
            (if (and (>= slot first) (< slot end))
              (if (< actual-count count)
                (begin
                  (set! (array-ref actual actual-count) (+ base (- slot first)))
                  (set! actual-count (+ actual-count 1)))
                (set! ok false))
              unit)
            (set! event (+ event 1))))
        (set! base (+ base (- end first)))
        (set! node-address node.next)
        (set! start 0)))
    (set! ok (and ok (= actual-count expected-count) (= base count)))
    (set! index 0)
    (while (and ok (< index expected-count))
      (set! ok (= (array-ref actual index) (array-ref expected index)))
      (set! index (+ index 1)))
    ok))

;; The alias index built from the events answers every (module, alias) pair of
;; `pairs` exactly as the full flat build does.
(define (macro-segmented-alias-index-matches-flat?
  [state : tc_core.TcJobState]
  [pairs : (& pairs (__tl_dyn-array i64))]) : bool
  (let
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state state)]
    [flat : tc_core.MacroSegmentedProgramFlatView
      (tc_core.macro-segmented-program-flatten-raw state)]
    [flat-decls : ast.AstDeclList flat.decls]
    [count : i64 (array-length pairs)]
    [segmented : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    (tc_core.tc-macro-import-index-control-set! macro-state 3 0)
    (tc_core.macro-alias-cache-ensure! macro-state)
    (tc_core.macro-alias-cache-build-segmented! state)
    (while (< index count)
      (set!
        (array-ref segmented index)
        (tc_core.macro-alias-cache-get
          macro-state
          (array-ref pairs index)
          (array-ref pairs (+ index 1))))
      (set! index (+ index 2)))
    (tc_core.tc-macro-import-index-control-set! macro-state 3 0)
    (tc_core.macro-alias-cache-ensure! macro-state)
    (tc_core.macro-alias-cache-build! macro-state (& flat-decls))
    (set! index 0)
    (while (< index count)
      (if (=
        (array-ref segmented index)
        (tc_core.macro-alias-cache-get
          macro-state
          (array-ref pairs index)
          (array-ref pairs (+ index 1))))
        unit
        (set! ok false))
      (set! index (+ index 2)))
    ok))

;; Moves `count` rows from the cursor into the emitted prefix, as the walk does.
(define (macro-segmented-events-emit!
  [state : tc_core.TcJobState]
  [count : i64]) : unit
  (let
    [data : tc_core.MacroSegmentedProgramViewData
      (tc_core.macro-segmented-program-view-data
        (tc_core.tc-job-state-macro-program-view-address state))]
    [out-rev : ast.AstDeclList data.prefix-rev]
    [out-paths-rev : ast.AstDeclPathList data.prefix-paths-rev]
    [index : i64 0]
    (while (< index count)
      (set!
        out-rev
        (ast.ast-decl-list-prepend-builder
          (tc_core.macro-segmented-program-current-decl state)
          out-rev))
      (set!
        out-paths-rev
        (ast.ast-decl-path-list-prepend-builder-with-owner-id
          (tc_core.macro-segmented-program-current-path state)
          (tc_core.macro-segmented-program-current-owner-id state)
          out-paths-rev))
      (tc_core.macro-segmented-program-advance! state)
      (set! index (+ index 1)))
    (tc_core.macro-segmented-program-prefix-set! state out-rev out-paths-rev)))

(define (macro-segmented-events-smoke?) : bool
  (let
    [state : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state state)]
    [m1 : i64 (ci.intern "seg-event-m1")]
    [m2 : i64 (ci.intern "seg-event-m2")]
    [t1 : i64 (ci.intern "seg-event-t1")]
    [t2 : i64 (ci.intern "seg-event-t2")]
    [t3 : i64 (ci.intern "seg-event-t3")]
    [t4 : i64 (ci.intern "seg-event-t4")]
    ;; Twenty prefix events outgrow the index's first allocation.
    [prefix-specs : (__tl_dyn-array i64) (__tl_make-array i64 44)]
    [_prefix-specs : unit
      (let
        [index : i64 0]
        (while (< index 22)
          (set!
            (array-ref prefix-specs (* index 2))
            (if (= (% index 7) 3)
              3
              1))
          (set! (array-ref prefix-specs (+ (* index 2) 1)) (+ t1 index))
          (set! index (+ index 1))))]
    [prefix : ast.AstDeclList (macro-segmented-event-rows (& prefix-specs))]
    [source-specs : (__tl_dyn-array i64) (__tl_make-array i64 18)]
    [_source-specs : unit
      (begin
        (set! (array-ref source-specs 0) 0)
        (set! (array-ref source-specs 1) m1)
        (set! (array-ref source-specs 2) 3)
        (set! (array-ref source-specs 3) 1)
        (set! (array-ref source-specs 4) 1)
        (set! (array-ref source-specs 5) t2)
        (set! (array-ref source-specs 6) 3)
        (set! (array-ref source-specs 7) 2)
        (set! (array-ref source-specs 8) 3)
        (set! (array-ref source-specs 9) 3)
        (set! (array-ref source-specs 10) 2)
        (set! (array-ref source-specs 11) t3)
        (set! (array-ref source-specs 12) 0)
        (set! (array-ref source-specs 13) m2)
        (set! (array-ref source-specs 14) 3)
        (set! (array-ref source-specs 15) 4)
        (set! (array-ref source-specs 16) 1)
        (set! (array-ref source-specs 17) t2))]
    [source : ast.AstDeclList (macro-segmented-event-rows (& source-specs))]
    [delta-specs : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [_delta-specs : unit
      (begin
        (set! (array-ref delta-specs 0) 3)
        (set! (array-ref delta-specs 1) 5)
        (set! (array-ref delta-specs 2) 1)
        (set! (array-ref delta-specs 3) t4)
        (set! (array-ref delta-specs 4) 3)
        (set! (array-ref delta-specs 5) 6))]
    [delta : ast.AstDeclList (macro-segmented-event-rows (& delta-specs))]
    [plain-specs : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [_plain-specs : unit
      (begin
        (set! (array-ref plain-specs 0) 3)
        (set! (array-ref plain-specs 1) 7))]
    [plain : ast.AstDeclList (macro-segmented-event-rows (& plain-specs))]
    ;; (module, alias) pairs: every alias in every module, the two duplicate
    ;; imports of t2, and a missing pair.
    [pairs : (__tl_dyn-array i64) (__tl_make-array i64 12)]
    [_pairs : unit
      (begin
        (set! (array-ref pairs 0) cbi.compiler-builtin-id-fix-empty)
        (set! (array-ref pairs 1) (+ t1 1))
        (set! (array-ref pairs 2) m1)
        (set! (array-ref pairs 3) (+ t2 1))
        (set! (array-ref pairs 4) m1)
        (set! (array-ref pairs 5) (+ t3 1))
        (set! (array-ref pairs 6) m1)
        (set! (array-ref pairs 7) (+ t4 1))
        (set! (array-ref pairs 8) m2)
        (set! (array-ref pairs 9) (+ t2 1))
        (set! (array-ref pairs 10) m2)
        (set! (array-ref pairs 11) (+ t3 1)))]
    (tc_core.macro-expand-scratch-begin! macro-state)
    (tc_core.macro-segmented-program-begin!
      state
      (tc_core.macro-decl-list-reverse-into
        (tc_core.tc-global-shared-view prefix)
        (ast.ast-decl-list-new))
      (tc_core.macro-decl-path-list-reverse-into
        (tc_core.macro-paths-for-decls macro-state prefix "prefix")
        (ast.ast-decl-path-list-new))
      (tc_core.tc-global-shared-view source)
      (tc_core.macro-paths-for-decls macro-state source "source"))
    (let
      [initial-ok : bool (macro-segmented-events-match-flat? state)]
      ;; Emit the module marker and the plain row, then replace the import at
      ;; the cursor by a delta with its own import (a mid-node split).
      [_emit : unit (macro-segmented-events-emit! state 2)]
      [_split : unit
        (tc_core.macro-segmented-program-splice-current!
          state
          (tc_core.tc-global-shared-view delta)
          (tc_core.macro-paths-for-decls macro-state delta "delta"))]
      [split-ok : bool (macro-segmented-events-match-flat? state)]
      [split-alias-ok : bool
        (macro-segmented-alias-index-matches-flat? state (& pairs))]
      ;; Emit through the delta and replace the first row of the suffix
      ;; slice with an event-free delta (a node-boundary splice).
      [_emit-delta : unit (macro-segmented-events-emit! state 3)]
      [_boundary : unit
        (tc_core.macro-segmented-program-splice-current!
          state
          (tc_core.tc-global-shared-view plain)
          (tc_core.macro-paths-for-decls macro-state plain "plain"))]
      [boundary-ok : bool (macro-segmented-events-match-flat? state)]
      [boundary-alias-ok : bool
        (macro-segmented-alias-index-matches-flat? state (& pairs))]
      ;; Everything emitted: the prefix alone holds every event.
      [_drain : unit
        (macro-segmented-events-emit!
          state
          (__tl-project-field
            (tc_core.macro-segmented-program-view-data
              (tc_core.tc-job-state-macro-program-view-address state))
            queue-len))]
      [drained-ok : bool
        (and
          (tc_core.macro-segmented-program-empty? state)
          (macro-segmented-events-match-flat? state))]
      [drained-alias-ok : bool
        (macro-segmented-alias-index-matches-flat? state (& pairs))]
      (tc_core.macro-segmented-program-end! state)
      (tc_core.macro-expand-scratch-release! macro-state)
      (and
        initial-ok
        split-ok
        split-alias-ok
        boundary-ok
        boundary-alias-ok
        drained-ok
        drained-alias-ok))))

(cfg
  test
  (test
    macro-segmented-program-events
    (if (macro-segmented-events-smoke?)
      unit
      (io.panic "typecheck: segmented macro program event index smoke failed"))))

(define (macro-segmented-program-job-reset-smoke?) : bool
  (let
    [left-id : i64 (ci.intern "seg-job-left")]
    [right-id : i64 (ci.intern "seg-job-right")]
    [left-decls : ast.AstDeclList
      (ast.ast-decl-cons (Module left-id) (ast.ast-decl-list-new))]
    [right-decls : ast.AstDeclList
      (ast.ast-decl-cons (Module right-id) (ast.ast-decl-list-new))]
    [left-paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "left"
        51
        (ast.ast-decl-path-list-new))]
    [right-paths : ast.AstDeclPathList
      (ast.ast-decl-path-cons-with-owner-id
        "right"
        61
        (ast.ast-decl-path-list-new))]
    [left-state : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [right-state : tc_core.TcJobState (tc_core.tc-job-state-new)]
    (tc_core.macro-expand-scratch-begin!
      (tc_core.tc-job-state-macro-state left-state))
    (tc_core.macro-expand-scratch-begin!
      (tc_core.tc-job-state-macro-state right-state))
    (tc_core.macro-segmented-program-begin!
      left-state
      (ast.ast-decl-list-new)
      (ast.ast-decl-path-list-new)
      left-decls
      left-paths)
    (tc_core.macro-segmented-program-begin!
      right-state
      (ast.ast-decl-list-new)
      (ast.ast-decl-path-list-new)
      right-decls
      right-paths)
    (let
      [left-iter : tc_core.MacroSegmentedProgramIter
        (tc_core.macro-segmented-program-iter left-state)]
      [right-iter : tc_core.MacroSegmentedProgramIter
        (tc_core.macro-segmented-program-iter right-state)]
      [initial-ok : bool
        (and
          left-iter.has-current
          right-iter.has-current
          (string.eq
            (macro-segmented-program-iter-current-path (& left-iter))
            "left")
          (string.eq
            (macro-segmented-program-iter-current-path (& right-iter))
            "right"))]
      ;; File-state reset is job-local and does not own either segmented
      ;; cursor. Acquire row views only after the reset and consume them
      ;; before mutating the corresponding iterator.
      (tc_core.tc-job-state-reset-file-state! left-state)
      (tc_core.tc-job-state-reset-file-state! right-state)
      (let
        [reset-ok : bool
          (and
            (tc_core.macro-segmented-program-active? left-state)
            (tc_core.macro-segmented-program-active? right-state)
            (match (tc_core.macro-segmented-program-iter-current-decl
              (& left-iter))
              [(Module name) (= name left-id)]
              [_ false])
            (match (tc_core.macro-segmented-program-iter-current-decl
              (& right-iter))
              [(Module name) (= name right-id)]
              [_ false])
            (= (macro-segmented-program-iter-current-owner-id (& left-iter)) 51)
            (=
              (macro-segmented-program-iter-current-provenance-id
                (& right-iter))
              61))]
        (tc_core.macro-segmented-program-iter-advance! (&mut left-iter))
        (tc_core.macro-segmented-program-iter-advance! (&mut right-iter))
        (tc_core.macro-segmented-program-end! left-state)
        (tc_core.macro-segmented-program-end! right-state)
        (tc_core.macro-expand-scratch-release!
          (tc_core.tc-job-state-macro-state left-state))
        (tc_core.macro-expand-scratch-release!
          (tc_core.tc-job-state-macro-state right-state))
        (and
          initial-ok
          reset-ok
          (not left-iter.has-current)
          (not right-iter.has-current)
          (not (tc_core.macro-segmented-program-active? left-state))
          (not (tc_core.macro-segmented-program-active? right-state)))))))

(cfg
  test
  (test
    macro-segmented-program-job-reset
    (if (macro-segmented-program-job-reset-smoke?)
      unit
      (io.panic "typecheck: segmented macro program job/reset smoke failed"))))

(define (macro-identity-key-internal-symbol-smoke?) : bool
  (let
    [span : token.SourceSpan (token.source-span-new 1 1 1 2)]
    [marker-id : i64
      (ctfe_support.ctfe-internal-resolved-struct-type-marker-id)]
    [owner-id : i64 (ci.intern "identity-owner")]
    [name-id : i64 (ci.intern "identity-name")]
    [composite-id : i64 (csym.compiler-composite-pair-key-id owner-id name-id)]
    (and
      (string.eq
        (tc_core.macro-identity-key-sexpr
          (cis.InternStructuralSessionHandle 0)
          (tc_core.macro-spanned-symbol-id marker-id span))
        (str_cat.str-cat
          "sym:"
          (spec.spec-string-key
            (tc_core.macro-internal-resolved-struct-type-marker))))
      (string.eq
        (tc_core.macro-identity-key-sexpr
          (cis.InternStructuralSessionHandle 0)
          (tc_core.macro-spanned-symbol-id composite-id span))
        (str_cat.str-cat
          "sym:"
          (spec.spec-string-key (ast.ast-nominal-name-id-display composite-id)))))))

(test
  macro-identity-key-preserves-internal-symbols
  (if (macro-identity-key-internal-symbol-smoke?)
    unit
    (io.panic "typecheck: internal macro identity key self-test failed")))

(test
  macro-import-kind-module-alias-classification
  (test.assert-true
    (tc_core.macro-import-kind-module-alias? Module)
    "file module imports bind module aliases")
  (test.assert-true
    (tc_core.macro-import-kind-module-alias? (Macro 0 No))
    "expression module macros bind module aliases")
  (test.assert-true
    (tc_core.macro-import-kind-module-alias? (MacroDecls 0 No))
    "declaration module macros bind module aliases")
  (test.assert-false
    (tc_core.macro-import-kind-module-alias? ModuleAll)
    "wildcard imports do not bind module aliases")
  (test.assert-false
    (tc_core.macro-import-kind-module-alias? (ModuleItem 0))
    "selected imports do not bind module aliases"))

(define (tc-unused-unsafe-storage-lifetime-fill!
  [state : tc_core.TcUnusedUnsafeState]
  [index : i64]) : unit
  (if (>= index 129)
    unit
    (let
      [line : i64 (+ 100 index)]
      [col : i64 (+ 200 index)]
      [span : ast.AstSourceSpan (ast.ast-source-span line col line (+ col 1))]
      [previous : i64 (tc_core.tc-unused-unsafe-enter-block state (Some span))]
      (if (= index 128)
        (tc_core.tc-unused-unsafe-mark-current-used! state)
        unit)
      (tc_core.tc-unused-unsafe-restore-block! state previous)
      (tc-unused-unsafe-storage-lifetime-fill! state (+ index 1)))))

(define (tc-unused-unsafe-storage-lifetime-ok?) : bool
  (let
    [caller : arena.Arena (arena.current)]
    [job : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [state : tc_core.TcUnusedUnsafeState
      (tc_core.tc-job-state-unused-unsafe job)]
    [scratch : arena.Arena (arena.make)]
    [path : String "tc-unused-unsafe-lifetime"]
    ;; First allocation runs while an unrelated disposable arena is current.
    ;; The buffers must still be retained by the state owner's arena.
    (unsafe
      (arena.set! scratch))
    (tc_core.tc-unused-unsafe-tracking-reset!
      state
      (tc_core.tc-global-shared-view path))
    (unsafe
      (arena.set! caller))
    (unsafe
      (arena.destroy scratch))
    (tc_core.tc-unused-unsafe-set-current-path!
      state
      (tc_core.tc-global-shared-view path))
    (tc-unused-unsafe-storage-lifetime-fill! state 0)
    (let
      [first-span : ast.AstSourceSpan
        (tc_core.tc-unused-unsafe-block-span state 0)]
      [last-span : ast.AstSourceSpan
        (tc_core.tc-unused-unsafe-block-span state 128)]
      [data : tc_core.TcUnusedUnsafeStateData
        (tc_core.tc-unused-unsafe-state-data state)]
      [survived? : bool
        (and
          (= (tc_core.tc-unused-unsafe-block-count state) 129)
          (string.eq (tc_core.tc-unused-unsafe-block-path state 0) path)
          (string.eq (tc_core.tc-unused-unsafe-block-path state 128) path)
          (= (ast.ast-source-span-start-line first-span) 100)
          (= (ast.ast-source-span-start-col first-span) 200)
          (= (ast.ast-source-span-end-line first-span) 100)
          (= (ast.ast-source-span-end-col first-span) 201)
          (= (ast.ast-source-span-start-line last-span) 228)
          (= (ast.ast-source-span-start-col last-span) 328)
          (= (ast.ast-source-span-end-line last-span) 228)
          (= (ast.ast-source-span-end-col last-span) 329)
          (not (tc_core.tc-unused-unsafe-block-used? state 0))
          (tc_core.tc-unused-unsafe-block-used? state 128)
          (= data.current-block -1))]
      (tc_core.tc-unused-unsafe-tracking-clear! state)
      (let
        [cleared : tc_core.TcUnusedUnsafeStateData
          (tc_core.tc-unused-unsafe-state-data state)]
        (and
          survived?
          (= (tc_core.tc-unused-unsafe-block-count state) 0)
          (not cleared.enabled)
          (= cleared.current-block -1)
          (string.eq cleared.current-path "")
          (string.eq cleared.target-path ""))))))

(define (tc-unused-unsafe-state-isolation-ok?) : bool
  (let
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [state-a : tc_core.TcUnusedUnsafeState
      (tc_core.tc-job-state-unused-unsafe job-a)]
    [state-b : tc_core.TcUnusedUnsafeState
      (tc_core.tc-job-state-unused-unsafe job-b)]
    [path-a : String "tc-unused-unsafe-a"]
    [path-b : String "tc-unused-unsafe-b"]
    [span-b : ast.AstSourceSpan (ast.ast-source-span 7 8 9 10)]
    (tc_core.tc-unused-unsafe-tracking-reset!
      state-a
      (tc_core.tc-global-shared-view path-a))
    (tc_core.tc-unused-unsafe-set-current-path! state-a path-a)
    (tc-unused-unsafe-storage-lifetime-fill! state-a 0)
    (tc_core.tc-unused-unsafe-tracking-reset!
      state-b
      (tc_core.tc-global-shared-view path-b))
    (tc_core.tc-unused-unsafe-set-current-path!
      state-b
      (tc_core.tc-global-shared-view path-b))
    (let
      [previous-b : i64
        (tc_core.tc-unused-unsafe-enter-block state-b (Some span-b))]
      (tc_core.tc-unused-unsafe-mark-current-used! state-b)
      (tc_core.tc-unused-unsafe-restore-block! state-b previous-b)
      ;; A reset must not alter B's selectors, records, or result bits.
      (tc_core.tc-job-state-reset-file-state! job-a)
      (let
        [data-b : tc_core.TcUnusedUnsafeStateData
          (tc_core.tc-unused-unsafe-state-data state-b)]
        (and
          (= (tc_core.tc-unused-unsafe-block-count state-a) 0)
          (= (tc_core.tc-unused-unsafe-block-count state-b) 1)
          (string.eq (tc_core.tc-unused-unsafe-block-path state-b 0) path-b)
          (tc_core.tc-unused-unsafe-span-eq?
            (tc_core.tc-unused-unsafe-block-span state-b 0)
            span-b)
          (tc_core.tc-unused-unsafe-block-used? state-b 0)
          data-b.enabled
          (= data-b.current-block -1)
          (string.eq data-b.current-path path-b)
          (string.eq data-b.target-path path-b))))))

(define (tc-unused-unsafe-state-isolation-self-test) : bool
  (and
    (tc-unused-unsafe-storage-lifetime-ok?)
    (tc-unused-unsafe-state-isolation-ok?)))

(define (tc-inlay-hint-string-lifetime-record-in-arena!
  [state : tc_core.TcInlayHintState]
  [producer : arena.Arena]) : unit
  (unsafe
    (arena.set! producer))
  (let
    [ty : String (str_cat.str-cat "lifetime-hint-" (string.int->string 42))]
    (tc_core.tc-inlay-hint-record-for-state! state 7 11 ty)))

;; Exercise every retained no-state adapter against the one serial state. The
;; fixed arrays are retained after reset, so this adds no second capacity-sized
;; allocation while still covering read-after-disable and generation cleanup.
(define (tc-inlay-hint-serial-adapters-ok?) : bool
  (let
    [state : tc_core.TcInlayHintState
      (tc_core.tc-job-state-inlay-hints (tc_core.tc-serial-job-state))]
    [readable? : bool false]
    [clean? : bool false]
    (tc_core.tc-inlay-hints-reset-for-state! state)
    (tc-inlay-hints-enable!)
    (tc-inlay-hint-record! 17 23 "serial-adapter")
    (tc-inlay-hints-disable!)
    (set!
      readable?
      (and
        (= (tc-inlay-hints-size) 1)
        (= (tc-inlay-hint-line-at 0) 17)
        (= (tc-inlay-hint-col-at 0) 23)
        (string.eq (tc-inlay-hint-type-at 0) "serial-adapter")))
    (tc_core.tc-inlay-hints-reset-for-state! state)
    (set!
      clean?
      (and
        (not (tc-inlay-hint-state-enabled? state))
        (= (tc-inlay-hints-size) 0)
        (=
          (__tl-project-field (tc_core.tc-inlay-hint-state-data state) count)
          0)
        (=
          (__tl-project-field
            (tc_core.tc-inlay-hint-state-data state)
            string-arena)
          0)))
    (and readable? clean?)))

(define (tc-inlay-hint-state-isolation-ok?) : bool
  (let
    [caller : arena.Arena (arena.current)]
    [producer : arena.Arena (arena.make)]
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [state-a : tc_core.TcInlayHintState
      (tc_core.tc-job-state-inlay-hints job-a)]
    [state-b : tc_core.TcInlayHintState
      (tc_core.tc-job-state-inlay-hints job-b)]
    [initially-lazy? : bool
      (and
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-a)
              lines))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-b)
              lines))
          0)
        (=
          (array-length
            (__tl-project-field (tc_core.tc-inlay-hint-state-data state-a) cols))
          0)
        (=
          (array-length
            (__tl-project-field (tc_core.tc-inlay-hint-state-data state-b) cols))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-a)
              types))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-b)
              types))
          0))]
    [restored-after-enable? : bool false]
    [a-survived? : bool false]
    [b-survived? : bool false]
    [a-reset? : bool false]
    [b-after-a-reset? : bool false]
    [reuse-isolated? : bool false]
    [fixed-capacities? : bool false]
    ;; Fixed storage is owned by the state creation arena even when first
    ;; use occurs under a disposable producer arena.
    (unsafe
      (arena.set! producer))
    (tc_core.tc-inlay-hints-enable-for-state! state-a)
    (set! restored-after-enable? (arena.eq? (arena.current) producer))
    (tc-inlay-hint-string-lifetime-record-in-arena! state-a producer)
    (unsafe
      (arena.set! caller))
    (unsafe
      (arena.destroy producer))
    (tc_core.tc-inlay-hints-disable-for-state! state-a)
    (tc_core.tc-inlay-hints-enable-for-state! state-b)
    (tc_core.tc-inlay-hint-record-for-state! state-b 21 31 "state-b")
    (set!
      fixed-capacities?
      (and
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-a)
              lines))
          tc_core.tc-inlay-hint-capacity)
        (=
          (array-length
            (__tl-project-field (tc_core.tc-inlay-hint-state-data state-a) cols))
          tc_core.tc-inlay-hint-capacity)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-a)
              types))
          tc_core.tc-inlay-hint-capacity)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-b)
              lines))
          tc_core.tc-inlay-hint-capacity)
        (=
          (array-length
            (__tl-project-field (tc_core.tc-inlay-hint-state-data state-b) cols))
          tc_core.tc-inlay-hint-capacity)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-inlay-hint-state-data state-b)
              types))
          tc_core.tc-inlay-hint-capacity)))
    (set!
      a-survived?
      (and
        (= (tc_core.tc-inlay-hints-size-for-state state-a) 1)
        (= (tc_core.tc-inlay-hint-line-at-for-state state-a 0) 7)
        (= (tc_core.tc-inlay-hint-col-at-for-state state-a 0) 11)
        (string.eq
          (tc_core.tc-inlay-hint-type-at-for-state state-a 0)
          "lifetime-hint-42")))
    (set!
      b-survived?
      (and
        (= (tc_core.tc-inlay-hints-size-for-state state-b) 1)
        (= (tc_core.tc-inlay-hint-line-at-for-state state-b 0) 21)
        (= (tc_core.tc-inlay-hint-col-at-for-state state-b 0) 31)
        (string.eq
          (tc_core.tc-inlay-hint-type-at-for-state state-b 0)
          "state-b")))
    (tc_core.tc-job-state-reset-file-state! job-a)
    (set!
      a-reset?
      (and
        (not (tc-inlay-hint-state-enabled? state-a))
        (= (tc_core.tc-inlay-hints-size-for-state state-a) 0)
        (=
          (__tl-project-field
            (tc_core.tc-inlay-hint-state-data state-a)
            string-arena)
          0)))
    (set!
      b-after-a-reset?
      (and
        (tc-inlay-hint-state-enabled? state-b)
        (= (tc_core.tc-inlay-hints-size-for-state state-b) 1)
        (= (tc_core.tc-inlay-hint-line-at-for-state state-b 0) 21)
        (= (tc_core.tc-inlay-hint-col-at-for-state state-b 0) 31)
        (string.eq
          (tc_core.tc-inlay-hint-type-at-for-state state-b 0)
          "state-b")))
    (tc_core.tc-inlay-hints-enable-for-state! state-a)
    (tc_core.tc-inlay-hint-record-for-state! state-a 41 51 "state-a-reused")
    (tc_core.tc-inlay-hints-disable-for-state! state-a)
    (set!
      reuse-isolated?
      (and
        (= (tc_core.tc-inlay-hints-size-for-state state-a) 1)
        (= (tc_core.tc-inlay-hint-line-at-for-state state-a 0) 41)
        (= (tc_core.tc-inlay-hint-col-at-for-state state-a 0) 51)
        (string.eq
          (tc_core.tc-inlay-hint-type-at-for-state state-a 0)
          "state-a-reused")
        (= (tc_core.tc-inlay-hints-size-for-state state-b) 1)
        (string.eq
          (tc_core.tc-inlay-hint-type-at-for-state state-b 0)
          "state-b")))
    (tc_core.tc-inlay-hints-reset-for-state! state-a)
    (tc_core.tc-inlay-hints-reset-for-state! state-b)
    (and
      initially-lazy?
      restored-after-enable?
      a-survived?
      b-survived?
      fixed-capacities?
      a-reset?
      b-after-a-reset?
      reuse-isolated?
      (=
        (__tl-project-field
          (tc_core.tc-inlay-hint-state-data state-a)
          string-arena)
        0)
      (=
        (__tl-project-field
          (tc_core.tc-inlay-hint-state-data state-b)
          string-arena)
        0))))

(define (tc-lazy-table-storage-ok?) : bool
  (let
    [caller : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [job-state : tc_core.TcJobState (tc_core.tc-serial-job-state)]
    [resolution-state : tc_core.TcTypeResolutionCacheState
      (tc_core.tc-job-state-type-resolution-cache job-state)]
    [scalar-state : tc_core.TcAggScalarCacheState
      (tc_core.tc-job-state-agg-scalar-caches job-state)]
    [layout-state : tc_core.TcAggLayoutCacheState
      (tc_core.tc-job-state-agg-layout-cache job-state)]
    [initially-lazy? : bool
      (and
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-type-resolution-cache-state-data resolution-state)
              slots))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-agg-scalar-cache-state-data scalar-state)
              size-cache))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-agg-scalar-cache-state-data scalar-state)
              align-cache))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-agg-scalar-cache-state-data scalar-state)
              regwords-cache))
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-agg-layout-cache-state-data layout-state)
              agg-layout-cache))
          0)
        (=
          (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
            layout-state)
          0))]
    [_set-scratch : unit
      (unsafe
        (arena.set! scratch))]
    [_resolution : unit
      (tc_core.tc-type-needs-resolution-storage-ensure-for-job! job-state)]
    [_size : unit (tc-agg-size-cache-storage-ensure!)]
    [_align : unit (tc-agg-align-cache-storage-ensure!)]
    [_regwords : unit (tc-agg-regwords-cache-storage-ensure!)]
    [scalar-data : tc_core.TcAggScalarCacheStateData
      (tc_core.tc-agg-scalar-cache-state-data scalar-state)]
    [resolution-data : tc_core.TcTypeResolutionCacheStateData
      (tc_core.tc-type-resolution-cache-state-data resolution-state)]
    [_layout : unit
      (tc_core.tc-agg-layout-cache-table-storage-ensure-for-state! layout-state)]
    [restored-caller? : bool (arena.eq? (arena.current) scratch)]
    [exact-capacities? : bool
      (and
        (=
          (array-length resolution-data.slots)
          tc_core.tc-type-resolution-cache-capacity)
        (=
          (array-length scalar-data.size-cache)
          tc_core.tc-agg-scalar-cache-capacity)
        (=
          (array-length scalar-data.align-cache)
          tc_core.tc-agg-scalar-cache-capacity)
        (=
          (array-length scalar-data.regwords-cache)
          tc_core.tc-agg-scalar-cache-capacity)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-agg-layout-cache-state-data layout-state)
              agg-layout-cache))
          tc_core.tc-agg-layout-cache-capacity))]
    (unsafe
      (arena.set! caller))
    (unsafe
      (arena.destroy scratch))
    (set! (array-ref resolution-data.slots 0) 17)
    (set! (array-ref scalar-data.size-cache 0) 29)
    (set! (array-ref scalar-data.align-cache 0) 31)
    (set! (array-ref scalar-data.regwords-cache 0) 37)
    (set!
      (array-ref
        (__tl-project-field
          (tc_core.tc-agg-layout-cache-state-data layout-state)
          agg-layout-cache)
        0)
      (tc_core.TcAggLayoutCacheSlot.Empty))
    (let
      [survived? : bool
        (and
          (= (array-ref resolution-data.slots 0) 17)
          (= (array-ref scalar-data.size-cache 0) 29)
          (= (array-ref scalar-data.align-cache 0) 31)
          (= (array-ref scalar-data.regwords-cache 0) 37)
          (match (tc_core.tc-global-array-element-shared-view
            (__tl-project-field
              (tc_core.tc-agg-layout-cache-state-data layout-state)
              agg-layout-cache)
            0)
            [(Empty) true]
            [_ false]))]
      (set! (array-ref resolution-data.slots 0) 0)
      (set! (array-ref scalar-data.size-cache 0) 0)
      (set! (array-ref scalar-data.align-cache 0) 0)
      (set! (array-ref scalar-data.regwords-cache 0) 0)
      (let
        [unused-unsafe-lifetime? : bool (tc-unused-unsafe-storage-lifetime-ok?)]
        [unused-unsafe-isolation? : bool (tc-unused-unsafe-state-isolation-ok?)]
        (and
          initially-lazy?
          restored-caller?
          exact-capacities?
          survived?
          unused-unsafe-lifetime?
          unused-unsafe-isolation?)))))

(cfg
  test
  (test
    type-resolution-cache-state-isolation
    (let
      [caller : arena.Arena (arena.current)]
      [owner-a : arena.Arena (arena.make)]
      [owner-b : arena.Arena (arena.make)]
      [job-a-address : i64
        (in-arena
          owner-a
          (__tl-project-field (tc_core.tc-job-state-new) address))]
      [job-b-address : i64
        (in-arena
          owner-b
          (__tl-project-field (tc_core.tc-job-state-new) address))]
      [job-a : tc_core.TcJobState (tc_core.TcJobState job-a-address)]
      [job-b : tc_core.TcJobState (tc_core.TcJobState job-b-address)]
      [state-a : tc_core.TcTypeResolutionCacheState
        (tc_core.tc-job-state-type-resolution-cache job-a)]
      [state-b : tc_core.TcTypeResolutionCacheState
        (tc_core.tc-job-state-type-resolution-cache job-b)]
      [pools-a : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 4 4)]
      [pools-b : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 4 4)]
      [child-a : i64 (ast.ast-node-pool-context-type-push pools-a (I64))]
      [parent-a : i64
        (ast.ast-node-pool-context-type-push pools-a (Array child-a 3))]
      [child-b : i64
        (ast.ast-node-pool-context-type-push
          pools-b
          (Var (ci.intern "resolution-owner-b")))]
      [parent-b : i64
        (ast.ast-node-pool-context-type-push pools-b (Array child-b 3))]
      [initially-lazy? : bool
        (and
          (=
            (array-length
              (tc_core.tc-type-resolution-cache-state-data state-a).slots)
            0)
          (=
            (array-length
              (tc_core.tc-type-resolution-cache-state-data state-b).slots)
            0))]
      [scratch : arena.Arena (arena.make)]
      (unsafe
        (arena.set! scratch))
      (let
        [answer-a : bool
          (tc_core.tc-type-needs-resolution-for-job-and-pools?
            job-a
            pools-a
            (ast.ast-node-pool-context-type-segment-bases pools-a)
            (ast.ast-node-pool-context-type-get pools-a parent-a))]
        [answer-b : bool
          (tc_core.tc-type-needs-resolution-for-job-and-pools?
            job-b
            pools-b
            (ast.ast-node-pool-context-type-segment-bases pools-b)
            (ast.ast-node-pool-context-type-get pools-b parent-b))]
        [hit-a : bool
          (tc_core.tc-type-needs-resolution-id-for-state? state-a parent-a)]
        [hit-b : bool
          (tc_core.tc-type-needs-resolution-id-for-state? state-b parent-b)]
        [data-a : tc_core.TcTypeResolutionCacheStateData
          (tc_core.tc-type-resolution-cache-state-data state-a)]
        [data-b : tc_core.TcTypeResolutionCacheStateData
          (tc_core.tc-type-resolution-cache-state-data state-b)]
        [slot-a : i64 (array-ref data-a.slots parent-a)]
        [slot-b : i64 (array-ref data-b.slots parent-b)]
        [restored-scratch? : bool (arena.eq? (arena.current) scratch)]
        (unsafe
          (arena.set! caller))
        (unsafe
          (arena.destroy scratch))
        (tc_core.tc-job-state-reset-derived-caches! job-a)
        (let
          [reset-a : tc_core.TcTypeResolutionCacheStateData
            (tc_core.tc-type-resolution-cache-state-data state-a)]
          [intact-b : tc_core.TcTypeResolutionCacheStateData
            (tc_core.tc-type-resolution-cache-state-data state-b)]
          [b-after-a-reset? : bool
            (tc_core.tc-type-needs-resolution-id-for-state? state-b parent-b)]
          [isolated? : bool
            (and
              initially-lazy?
              (not (= state-a.address state-b.address))
              (= child-a child-b)
              (= parent-a parent-b)
              (not answer-a)
              answer-b
              (not hit-a)
              hit-b
              restored-scratch?
              (=
                (array-length data-a.slots)
                tc_core.tc-type-resolution-cache-capacity)
              (=
                (array-length data-b.slots)
                tc_core.tc-type-resolution-cache-capacity)
              (= (shr slot-a 1) data-a.epoch)
              (= (bit-and slot-a 1) 0)
              (= (shr slot-b 1) data-b.epoch)
              (= (bit-and slot-b 1) 1)
              (= reset-a.type-pool-owner-id 0)
              (= reset-a.type-segment-bases 0)
              (> reset-a.epoch data-a.epoch)
              (= intact-b.type-pool-owner-id data-b.type-pool-owner-id)
              (= intact-b.type-segment-bases data-b.type-segment-bases)
              (= intact-b.epoch data-b.epoch)
              (= (array-ref intact-b.slots parent-b) slot-b)
              b-after-a-reset?)]
          (unsafe
            (arena.destroy owner-a))
          (let
            [b-after-a-destroy? : bool
              (tc_core.tc-type-needs-resolution-id-for-state? state-b parent-b)]
            (unsafe
              (arena.destroy owner-b))
            (if (and isolated? b-after-a-destroy?)
              unit
              (io.panic
                "typecheck: type-resolution cache state isolation failed"))))))))

(cfg
  test
  (test
    type-resolution-concrete-fast-path-pool-isolation
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [concrete-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 4 4)]
      [compatibility-pools : ast.AstNodePoolContext
        (ast.ast-node-pool-context-new-with-capacities 4 4)]
      [job-state : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [concrete-child : i64
        (ast.ast-node-pool-context-type-push concrete-pools (I64))]
      [concrete-root : ast.AstType (Array concrete-child 3)]
      [unresolved-name : i64 (ci.intern "Expr")]
      [unresolved-child : i64
        (ast.ast-node-pool-context-type-push
          compatibility-pools
          (Var unresolved-name))]
      [unresolved-root : ast.AstType (Array unresolved-child 5)]
      [ctx : tc_core.TcContext
        (tc_core.tc-context-new-with-source-names-and-job-state
          (ast.ast-program (ast.ast-decl-list-new))
          (csym.compiler-symbols-empty)
          (csym.compiler-registries-empty)
          ""
          cbi.compiler-builtin-id-fix-empty
          concrete-pools
          (ci.intern-source-name-session-capture-active-handle)
          job-state)]
      [_install-concrete : unit
        (ast.ast-node-pool-context-install! concrete-pools)]
      [concrete-len-before : i64
        (ast.ast-node-pool-context-type-len concrete-pools)]
      [resolved-primitive : ast.AstType (tc_core.tc-resolve-type ctx (I64))]
      [resolved-nominal : ast.AstType
        (tc_core.tc-resolve-type ctx (Struct 700))]
      [resolved-concrete : ast.AstType
        (tc_core.tc-resolve-type ctx concrete-root)]
      [concrete-unchanged? : bool
        (and
          (match resolved-primitive
            [(I64) true]
            [_ false])
          (match resolved-nominal
            [(Struct name) (= name 700)]
            [_ false])
          (match resolved-concrete
            [(Array child len) (and (= child concrete-child) (= len 3))]
            [_ false])
          (=
            (ast.ast-node-pool-context-type-len concrete-pools)
            concrete-len-before))]
      [compatibility-ctx : tc_core.TcContext
        (tc_core.tc-context-new-with-source-names-and-job-state
          (ast.ast-program (ast.ast-decl-list-new))
          (csym.compiler-symbols-empty)
          (csym.compiler-registries-empty)
          ""
          cbi.compiler-builtin-id-fix-empty
          compatibility-pools
          (ci.intern-source-name-session-capture-active-handle)
          job-state)]
      [_install-compatibility : unit
        (ast.ast-node-pool-context-install! compatibility-pools)]
      [compatibility-len-before : i64
        (ast.ast-node-pool-context-type-len compatibility-pools)]
      [resolved-unresolved : ast.AstType
        (tc_core.tc-resolve-type compatibility-ctx unresolved-root)]
      [compatibility-result-ok? : bool
        (match resolved-unresolved
          [(Array child len)
            (and
              (= len 5)
              (match (ast.ast-node-pool-context-type-get
                compatibility-pools
                child)
                [(Expr) true]
                [_ false]))]
          [_ false])]
      [compatibility-len-grew? : bool
        (=
          (ast.ast-node-pool-context-type-len compatibility-pools)
          (+ compatibility-len-before 1))]
      [compatibility-still-installed? : bool
        (ast.ast-node-pool-context-type-installed? (& compatibility-pools))]
      (ast.ast-node-pool-context-install! installed)
      (cond
        [(not concrete-unchanged?)
          (io.panic
            "typecheck: concrete resolution fast path rebuilt a concrete type")]
        [(not compatibility-result-ok?)
          (io.panic
            "typecheck: concrete resolution fast path changed unresolved output")]
        [(not compatibility-len-grew?)
          (io.panic
            "typecheck: concrete resolution fast path skipped unresolved rebuild")]
        [(not compatibility-still-installed?)
          (io.panic
            "typecheck: concrete resolution fast path changed the installed pool")]
        [else unit]))))

(cfg
  test
  (test
    agg-scalar-cache-state-isolation
    (let
      [caller : arena.Arena (arena.current)]
      [owner-a : arena.Arena (arena.make)]
      [owner-b : arena.Arena (arena.make)]
      [job-a-address : i64
        (in-arena
          owner-a
          (__tl-project-field (tc_core.tc-job-state-new) address))]
      [job-b-address : i64
        (in-arena
          owner-b
          (__tl-project-field (tc_core.tc-job-state-new) address))]
      [job-a : tc_core.TcJobState (tc_core.TcJobState job-a-address)]
      [job-b : tc_core.TcJobState (tc_core.TcJobState job-b-address)]
      [state-a : tc_core.TcAggScalarCacheState
        (tc_core.tc-job-state-agg-scalar-caches job-a)]
      [state-b : tc_core.TcAggScalarCacheState
        (tc_core.tc-job-state-agg-scalar-caches job-b)]
      [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [decoy : ci.InternCompatState (ci.intern-compat-state-new)]
      [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
      [table-a : i64 (ci.intern-compat-state-table-id intern-a)]
      [table-b : i64 (ci.intern-compat-state-table-id intern-b)]
      [generation-a : i64 (ci.intern-compat-state-generation intern-a)]
      [generation-b : i64 (ci.intern-compat-state-generation intern-b)]
      [initially-lazy? : bool
        (and
          (=
            (array-length
              (tc_core.tc-agg-scalar-cache-state-data state-a).size-cache)
            0)
          (=
            (array-length
              (tc_core.tc-agg-scalar-cache-state-data state-a).align-cache)
            0)
          (=
            (array-length
              (tc_core.tc-agg-scalar-cache-state-data state-a).regwords-cache)
            0)
          (=
            (array-length
              (tc_core.tc-agg-scalar-cache-state-data state-b).size-cache)
            0)
          (=
            (array-length
              (tc_core.tc-agg-scalar-cache-state-data state-b).align-cache)
            0)
          (=
            (array-length
              (tc_core.tc-agg-scalar-cache-state-data state-b).regwords-cache)
            0))]
      [scratch : arena.Arena (arena.make)]
      (unsafe
        (arena.set! scratch))
      (tc_core.tc-agg-size-cache-storage-ensure-for-job! job-a)
      (tc_core.tc-agg-align-cache-storage-ensure-for-job! job-a)
      (tc_core.tc-agg-regwords-cache-storage-ensure-for-job! job-a)
      (tc_core.tc-agg-size-cache-storage-ensure-for-job! job-b)
      (tc_core.tc-agg-align-cache-storage-ensure-for-job! job-b)
      (tc_core.tc-agg-regwords-cache-storage-ensure-for-job! job-b)
      (let
        [restored-scratch? : bool (arena.eq? (arena.current) scratch)]
        (unsafe
          (arena.set! caller))
        (unsafe
          (arena.destroy scratch))
        (tc_core.tc-agg-size-cache-ensure-for-state!
          state-a
          table-a
          generation-a)
        (tc_core.tc-agg-align-cache-ensure-for-state!
          state-a
          table-a
          generation-a)
        (tc_core.tc-agg-regwords-cache-ensure-for-state!
          state-a
          table-a
          generation-a)
        (tc_core.tc-agg-size-cache-ensure-for-state!
          state-b
          table-b
          generation-b)
        (tc_core.tc-agg-align-cache-ensure-for-state!
          state-b
          table-b
          generation-b)
        (tc_core.tc-agg-regwords-cache-ensure-for-state!
          state-b
          table-b
          generation-b)
        (let
          [data-a : tc_core.TcAggScalarCacheStateData
            (tc_core.tc-agg-scalar-cache-state-data state-a)]
          [data-b : tc_core.TcAggScalarCacheStateData
            (tc_core.tc-agg-scalar-cache-state-data state-b)]
          (set! (array-ref data-a.size-cache 17) 9)
          (set! (array-ref data-a.align-cache 17) 5)
          (set! (array-ref data-a.regwords-cache 17) 3)
          (set! (array-ref data-b.size-cache 17) 33)
          (set! (array-ref data-b.align-cache 17) 17)
          (set! (array-ref data-b.regwords-cache 17) 2)
          (ci.intern-compat-state-install! decoy)
          (tc_core.tc-agg-caches-reset-for-job! job-a)
          (tc_core.tc-agg-size-cache-ensure-for-state!
            state-a
            table-a
            generation-a)
          (tc_core.tc-agg-align-cache-ensure-for-state!
            state-a
            table-a
            generation-a)
          (tc_core.tc-agg-regwords-cache-ensure-for-state!
            state-a
            table-a
            generation-a)
          (let
            [reset-a : tc_core.TcAggScalarCacheStateData
              (tc_core.tc-agg-scalar-cache-state-data state-a)]
            [intact-b : tc_core.TcAggScalarCacheStateData
              (tc_core.tc-agg-scalar-cache-state-data state-b)]
            [isolated? : bool
              (and
                (= (array-ref reset-a.size-cache 17) 0)
                (= (array-ref reset-a.align-cache 17) 0)
                (= (array-ref reset-a.regwords-cache 17) 0)
                (= (array-ref intact-b.size-cache 17) 33)
                (= (array-ref intact-b.align-cache 17) 17)
                (= (array-ref intact-b.regwords-cache 17) 2)
                (= intact-b.size-intern-table-id table-b)
                (= intact-b.size-intern-generation generation-b)
                (= intact-b.align-intern-table-id table-b)
                (= intact-b.align-intern-generation generation-b)
                (= intact-b.regwords-intern-table-id table-b)
                (= intact-b.regwords-intern-generation generation-b))]
            (unsafe
              (arena.destroy owner-a))
            (let
              [after-a-destroy : tc_core.TcAggScalarCacheStateData
                (tc_core.tc-agg-scalar-cache-state-data state-b)]
              [b-survived? : bool
                (and
                  (= (array-ref after-a-destroy.size-cache 17) 33)
                  (= (array-ref after-a-destroy.align-cache 17) 17)
                  (= (array-ref after-a-destroy.regwords-cache 17) 2))]
              (ci.intern-compat-state-install! installed)
              (unsafe
                (arena.destroy owner-b))
              (if (and
                initially-lazy?
                restored-scratch?
                isolated?
                b-survived?
                (not (= table-a table-b)))
                unit
                (io.panic
                  "typecheck: aggregate scalar cache state isolation failed")))))))))

;; Same numeric importer/alias IDs belong to different intern owners here.
;; Allocate both tables while an unrelated scratch arena is active, then prove
;; that A-only reset and generation invalidation leave B's lookup and counters
;; intact after that scratch arena has been destroyed.
(cfg
  test
  (test
    lazy-import-state-isolation
    (let
      [caller : arena.Arena (arena.current)]
      [installed-table-id : i64 (ci.intern-active-table-id)]
      [installed-generation : i64 (ci.intern-generation)]
      [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state-a : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job-a)]
      [state-b : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job-b)]
      [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [importer-a : i64
        (ci.intern-compat-state-intern (&mut intern-a) "importer")]
      [alias-a : i64 (ci.intern-compat-state-intern (&mut intern-a) "alias")]
      [target-a : i64
        (ci.intern-compat-state-intern (&mut intern-a) "target-a")]
      [importer-b : i64
        (ci.intern-compat-state-intern (&mut intern-b) "importer")]
      [alias-b : i64 (ci.intern-compat-state-intern (&mut intern-b) "alias")]
      [_filler-b : i64 (ci.intern-compat-state-intern (&mut intern-b) "filler")]
      [target-b : i64
        (ci.intern-compat-state-intern (&mut intern-b) "target-b")]
      [_bind-a : unit
        (tc_core.tc-macro-state-bind-source-names!
          state-a
          (ci.intern-source-name-session-handle-from-state intern-a))]
      [_bind-b : unit
        (tc_core.tc-macro-state-bind-source-names!
          state-b
          (ci.intern-source-name-session-handle-from-state intern-b))]
      [initially-lazy? : bool
        (and
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-lazy-import)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-lazy-import)
            0))]
      [scratch : arena.Arena (arena.make)]
      (unsafe
        (arena.set! scratch))
      (tc_core.tc-lazy-import-stub-record-for-job!
        job-a
        importer-a
        alias-a
        target-a
        true)
      (tc_core.tc-lazy-import-summary-macro-force-record-for-state! state-a)
      (tc_core.tc-lazy-import-summary-macro-force-record-for-state! state-a)
      (tc_core.tc-lazy-import-stub-record-for-job!
        job-b
        importer-b
        alias-b
        target-b
        false)
      (tc_core.tc-lazy-import-summary-macro-force-record-for-state! state-b)
      (unsafe
        (arena.set! caller))
      (unsafe
        (arena.destroy scratch))
      (let
        [lazy-a : tc_core.TcLazyImportState
          (tc_core.tc-job-state-lazy-import job-a)]
        [lazy-b : tc_core.TcLazyImportState
          (tc_core.tc-job-state-lazy-import job-b)]
        [data-a : tc_core.TcLazyImportStateData
          (tc_core.tc-lazy-import-state-data lazy-a)]
        [data-b : tc_core.TcLazyImportStateData
          (tc_core.tc-lazy-import-state-data lazy-b)]
        [before-reset? : bool
          (and
            initially-lazy?
            (not (= lazy-a.address lazy-b.address))
            (=
              (array-length data-a.index-slots)
              tc_core.tc-lazy-import-stub-capacity)
            (=
              (array-length data-b.index-slots)
              tc_core.tc-lazy-import-stub-capacity)
            (= importer-a importer-b)
            (= alias-a alias-b)
            (not (= target-a target-b))
            (= (tc_core.tc-lazy-import-stub-count-for-state state-a) 1)
            (= (tc_core.tc-lazy-import-stub-count-for-state state-b) 1)
            (= (tc-lazy-import-summary-backed-stub-count-for-state state-a) 1)
            (= (tc-lazy-import-summary-backed-stub-count-for-state state-b) 0)
            (=
              (tc_core.tc-lazy-import-summary-macro-force-count-for-state
                state-a)
              2)
            (=
              (tc_core.tc-lazy-import-summary-macro-force-count-for-state
                state-b)
              1)
            (match (tc_core.tc-lazy-import-stub-target-id-for-state
              state-a
              importer-a
              alias-a)
              [(Some target) (= target target-a)]
              [(No) false])
            (match (tc_core.tc-lazy-import-stub-target-id-for-state
              state-b
              importer-b
              alias-b)
              [(Some target) (= target target-b)]
              [(No) false]))]
        (tc_core.tc-lazy-import-stubs-reset-for-job! job-a)
        (let
          [a-reset-b-intact? : bool
            (and
              (= (tc_core.tc-lazy-import-stub-count-for-state state-a) 0)
              (= (tc-lazy-import-summary-backed-stub-count-for-state state-a) 0)
              (=
                (tc_core.tc-lazy-import-summary-macro-force-count-for-state
                  state-a)
                0)
              (match (tc_core.tc-lazy-import-stub-target-id-for-state
                state-a
                importer-a
                alias-a)
                [(Some _) false]
                [(No) true])
              (= (tc_core.tc-lazy-import-stub-count-for-state state-b) 1)
              (=
                (tc_core.tc-lazy-import-summary-macro-force-count-for-state
                  state-b)
                1)
              (match (tc_core.tc-lazy-import-stub-target-id-for-state
                state-b
                importer-b
                alias-b)
                [(Some target) (= target target-b)]
                [(No) false]))]
          (tc_core.tc-lazy-import-stub-record-for-job!
            job-a
            importer-a
            alias-a
            target-a
            false)
          (ci.intern-compat-state-reset! (&mut intern-a))
          (tc_core.tc-macro-state-bind-source-names!
            state-a
            (ci.intern-source-name-session-handle-from-state intern-a))
          (if (and
            before-reset?
            a-reset-b-intact?
            (= (tc_core.tc-lazy-import-stub-count-for-state state-a) 0)
            (= (tc_core.tc-lazy-import-stub-count-for-state state-b) 1)
            (= (ci.intern-active-table-id) installed-table-id)
            (= (ci.intern-generation) installed-generation))
            unit
            (io.panic "typecheck: lazy import state isolation failed")))))))

;; Deterministic A/B interleaving probe for the job-owned macro and CTFE state.
;; It exercises independent writes, A-only resets, and lazy table allocation
;; without relying on an active-state selector.
(cfg
  test
  (define (tc-macro-state-isolation-ok?) : bool
    (let
      [_installed-ready : unit
        (if (= (ci.intern-generation) 0)
          (ci.intern-reset!)
          unit)]
      [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state-a : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job-a)]
      [state-b : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job-b)]
      [installed-table-id : i64 (ci.intern-active-table-id)]
      [installed-generation : i64 (ci.intern-generation)]
      [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [module-id-a : i64
        (ci.intern-compat-state-intern (&mut intern-a) "same-module")]
      [name-id-a : i64
        (ci.intern-compat-state-intern (&mut intern-a) "same-name")]
      [module-id-b : i64
        (ci.intern-compat-state-intern (&mut intern-b) "same-module")]
      [name-id-b : i64
        (ci.intern-compat-state-intern (&mut intern-b) "same-name")]
      [source-names-a : ci.InternSourceNameSessionHandle
        (ci.intern-source-name-session-handle-from-state intern-a)]
      [source-names-b : ci.InternSourceNameSessionHandle
        (ci.intern-source-name-session-handle-from-state intern-b)]
      [installed-generated-identity-before : i64
        (match (ci.intern-generated-canonical-lookup
          "tc-macro-state-isolation-owner-only")
          [(InternLookupFound id) (+ id 1)]
          [(InternLookupMissing) 0])]
      [initially-lazy? : bool
        (and
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-walk)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-abstract)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-identity)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-generated-decls)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-surface-call)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-a
              tc_core.tc-macro-state-slot-import-index)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-walk)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-abstract)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-identity)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-generated-decls)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-surface-call)
            0)
          (=
            (tc_core.tc-macro-state-slot-address
              state-b
              tc_core.tc-macro-state-slot-import-index)
            0))]
      [ok : bool initially-lazy?]
      (tc_core.tc-macro-state-bind-source-names! state-a source-names-a)
      (tc_core.tc-macro-state-bind-source-names! state-b source-names-b)
      (let
        [journal-mark-a : i64 (tc_core.tc-dotted-macro-journal-start! state-a)]
        [journal-mark-b : i64 (tc_core.tc-dotted-macro-journal-start! state-b)]
        (tc_core.tc-dotted-macro-journal-restore-to! state-a journal-mark-a)
        (set!
          ok
          (and
            ok
            (= journal-mark-a 0)
            (= journal-mark-b 0)
            (= (tc-macro-walk-field state-a dotted-macro-journal-depth) 0)
            (= (tc-macro-walk-field state-b dotted-macro-journal-depth) 1)))
        (tc_core.tc-dotted-macro-journal-restore-to! state-b journal-mark-b))
      (set!
        ok
        (and
          ok
          (= module-id-a module-id-b)
          (= name-id-a name-id-b)
          (not
            (=
              (ci.intern-compat-state-table-id intern-a)
              (ci.intern-compat-state-table-id intern-b)))))
      ;; Interleave live-walk state and dense hygiene environments.
      (tc-macro-walk-set! state-a macro-expand-active-module "isolation-a")
      (tc-macro-walk-set! state-b macro-expand-active-module "isolation-b")
      (tc_core.macro-hygiene-env-root-begin! state-a)
      (tc_core.macro-hygiene-env-root-begin! state-b)
      (let
        [env-a : tc_core.MacroHygieneEnv
          (tc_core.macro-hygiene-env-bind-raw
            (tc_core.macro-hygiene-env-empty
              state-a
              (ast.ast-node-pool-compat-context-current))
            71
            81)]
        [env-b : tc_core.MacroHygieneEnv
          (tc_core.macro-hygiene-env-bind-raw
            (tc_core.macro-hygiene-env-empty
              state-b
              (ast.ast-node-pool-compat-context-current))
            71
            91)]
        (set!
          ok
          (and
            ok
            (match (tc_core.macro-hygiene-env-lookup env-a 71)
              [(Some value) (= value 81)]
              [_ false])
            (match (tc_core.macro-hygiene-env-lookup env-b 71)
              [(Some value) (= value 91)]
              [_ false])))
        (tc_core.macro-hygiene-env-root-finish! state-a)
        (tc_core.macro-hygiene-env-root-finish! state-b))
      ;; Interleave the large lazy import and surface memo tables.
      (tc_core.macro-unqualified-import-cache-ensure! state-a)
      (tc_core.macro-unqualified-import-cache-put!
        state-a
        module-id-a
        name-id-a
        301)
      (tc_core.macro-unqualified-import-cache-ensure! state-b)
      (tc_core.macro-unqualified-import-cache-put!
        state-b
        module-id-b
        name-id-b
        401)
      (tc_core.macro-alias-cache-ensure! state-a)
      (tc_core.macro-alias-cache-put! state-a module-id-a name-id-a 302)
      (tc_core.macro-alias-cache-ensure! state-b)
      (tc_core.macro-alias-cache-put! state-b module-id-b name-id-b 402)
      (tc_core.macro-flat-import-target-cache-ensure! state-a)
      (tc_core.macro-flat-import-target-cache-put!
        state-a
        module-id-a
        (tc_core.macro-flat-import-target-list-add
          (tc_core.macro-flat-import-target-list-empty)
          303))
      (tc_core.macro-flat-import-target-cache-ensure! state-b)
      (tc_core.macro-flat-import-target-cache-put!
        state-b
        module-id-b
        (tc_core.macro-flat-import-target-list-add
          (tc_core.macro-flat-import-target-list-empty)
          403))
      (tc_core.macro-surface-call-decl-cache-ensure! state-a)
      (tc_core.macro-surface-call-decl-cache-put! state-a 501 601 (No))
      (tc_core.macro-surface-call-decl-cache-ensure! state-b)
      (tc_core.macro-surface-call-decl-cache-put! state-b 501 601 (No))
      (set!
        ok
        (and
          ok
          (=
            (tc_core.macro-unqualified-import-cache-get
              state-a
              module-id-a
              name-id-a)
            301)
          (=
            (tc_core.macro-unqualified-import-cache-get
              state-b
              module-id-b
              name-id-b)
            401)
          (= (tc_core.macro-alias-cache-get state-a module-id-a name-id-a) 302)
          (= (tc_core.macro-alias-cache-get state-b module-id-b name-id-b) 402)
          (match (tc_core.macro-flat-import-target-cache-get
            state-a
            module-id-a)
            [(Hit targets)
              (and (= targets.len 1) (= (array-ref targets.slots 0) 303))]
            [_ false])
          (match (tc_core.macro-flat-import-target-cache-get
            state-b
            module-id-b)
            [(Hit targets)
              (and (= targets.len 1) (= (array-ref targets.slots 0) 403))]
            [_ false])
          (match (tc_core.macro-surface-call-decl-cache-get state-a 501 601)
            [(Hit (No)) true]
            [_ false])
          (match (tc_core.macro-surface-call-decl-cache-get state-b 501 601)
            [(Hit (No)) true]
            [_ false])))
      ;; Interleave generated-declaration and generated-module memos.
      (tc_core.macro-generated-decls-memo-put!
        state-a
        "tc-macro-state-isolation"
        (ast.ast-decl-list-new))
      (tc_core.macro-generated-decls-memo-put!
        state-b
        "tc-macro-state-isolation"
        (ast.ast-decl-list-new))
      (tc_core.macro-generated-module-memo-put!
        state-a
        "tc-macro-state-isolation-module"
        901
        (ast.ast-decl-list-new)
        (ast.ast-decl-list-new)
        "isolation-generator-a"
        "isolation-a.tl")
      (tc_core.macro-generated-module-memo-put!
        state-b
        "tc-macro-state-isolation-module"
        902
        (ast.ast-decl-list-new)
        (ast.ast-decl-list-new)
        "isolation-generator-b"
        "isolation-b.tl")
      (tc_core.tc-macro-identity-intern-for-state
        state-a
        "tc-macro-state-isolation-owner-only")
      (set!
        ok
        (and
          ok
          (>=
            (tc_core.tc-macro-identity-lookup-for-state
              state-a
              "tc-macro-state-isolation-owner-only")
            0)
          (<
            (tc_core.tc-macro-identity-lookup-for-state
              state-b
              "tc-macro-state-isolation-owner-only")
            0)
          (=
            (tc_core.tc-macro-identity-lookup-for-state
              state-a
              "tc-macro-state-isolation")
            (tc_core.tc-macro-identity-lookup-for-state
              state-b
              "tc-macro-state-isolation"))))
      (set!
        ok
        (and
          ok
          (match (tc_core.macro-generated-decls-memo-get
            state-a
            "tc-macro-state-isolation")
            [(Some decls) (= (ast.ast-decl-list-len (& decls)) 0)]
            [_ false])
          (match (tc_core.macro-generated-decls-memo-get
            state-b
            "tc-macro-state-isolation")
            [(Some decls) (= (ast.ast-decl-list-len (& decls)) 0)]
            [_ false])
          (match (tc_core.macro-generated-module-memo-get-catalog
            state-a
            "tc-macro-state-isolation-module")
            [(Catalog target _ _ _ _ _) (= target 901)]
            [_ false])
          (match (tc_core.macro-generated-module-memo-get-catalog
            state-b
            "tc-macro-state-isolation-module")
            [(Catalog target _ _ _ _ _) (= target 902)]
            [_ false])))
      ;; Independent live-symbol generations and declaration/splice rings must
      ;; survive another job's reset and destroy cadence.
      (let
        [empty-program : ast.AstProgram
          (ast.ast-program (ast.ast-decl-list-new))]
        [empty-paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
        [symbols-a : csym.ResultCompilerSymbols
          (tc_core.macro-live-symbols-build-fresh
            state-a
            (tc_core.tc-global-shared-view empty-program)
            (tc_core.tc-global-shared-view empty-paths))]
        [symbols-a-rebuild : csym.ResultCompilerSymbols
          (tc_core.macro-live-symbols-build-fresh
            state-a
            (tc_core.tc-global-shared-view empty-program)
            (tc_core.tc-global-shared-view empty-paths))]
        [_reclaim-a-symbols : unit
          (tc_core.macro-live-symbols-reclaim-retired! state-a)]
        [a-rebuild-reclaimed? : bool
          (and
            (tc-macro-walk-field state-a macro-live-symbols-ready)
            (= (tc-macro-walk-field state-a macro-live-symbols-retired-arena) 0))]
        [symbols-b : csym.ResultCompilerSymbols
          (tc_core.macro-live-symbols-build-fresh
            state-b
            (tc_core.tc-global-shared-view empty-program)
            (tc_core.tc-global-shared-view empty-paths))]
        [symbols-b-arena : i64
          (tc-macro-walk-field state-b macro-live-symbols-arena)]
        [symbols-b-reused : csym.ResultCompilerSymbols
          (tc_core.macro-live-symbols-build-or-reuse!
            state-b
            empty-program
            empty-paths)]
        [decl-arena-a : i64 (tc_core.macro-decl-generation-enter! state-a)]
        [decl-arena-a-same : i64 (tc_core.macro-decl-generation-enter! state-a)]
        [decl-arena-a-next : i64 (tc_core.macro-decl-generation-enter! state-a)]
        ;; A rotation rewinds the job's one declaration arena; it maps no
        ;; new one.
        [a-decl-rotation-reclaimed? : bool
          (and
            (= decl-arena-a decl-arena-a-same)
            (= decl-arena-a decl-arena-a-next)
            (=
              (tc-macro-walk-field state-a macro-decl-generation-arena)
              decl-arena-a-next)
            (=
              (tc-macro-walk-field state-a macro-decl-generation-retired-arena)
              0))]
        [decl-arena-b : i64 (tc_core.macro-decl-generation-enter! state-b)]
        [splice-arena-a : i64 (tc_core.macro-splice-generation-enter! state-a)]
        [splice-arena-a-next : i64
          (tc_core.macro-splice-generation-enter! state-a)]
        [splice-arena-a-third : i64
          (tc_core.macro-splice-generation-enter! state-a)]
        ;; The third splice rewinds the generation two behind it.
        [a-splice-ring-ok? : bool
          (and
            (not (= splice-arena-a splice-arena-a-next))
            (not (= splice-arena-a-next splice-arena-a-third))
            (= splice-arena-a splice-arena-a-third)
            (=
              (tc-macro-walk-field state-a macro-splice-generation-arena)
              splice-arena-a-third)
            (=
              (tc-macro-walk-field
                state-a
                macro-splice-generation-retired-arena)
              splice-arena-a-next))]
        [splice-arena-b : i64 (tc_core.macro-splice-generation-enter! state-b)]
        [enclosing : i64 (arena.tl_arena_current)]
        [_switch-b : unit
          (unsafe
            (arena.tl_arena_set decl-arena-b))]
        [job-b-generation-text : String "job-b-generation"]
        [owned-by-b : String (string.copy (& job-b-generation-text))]
        [_restore : unit
          (unsafe
            (arena.tl_arena_set enclosing))]
        (tc_core.macro-live-symbols-clear! state-a)
        (tc_core.macro-decl-generations-release! state-a)
        (set!
          ok
          (and
            ok
            (match symbols-a
              [(Ok _) true]
              [_ false])
            (match symbols-a-rebuild
              [(Ok _) true]
              [_ false])
            (match symbols-b
              [(Ok _) true]
              [_ false])
            (match symbols-b-reused
              [(Ok _) true]
              [_ false])
            a-rebuild-reclaimed?
            a-decl-rotation-reclaimed?
            a-splice-ring-ok?
            (=
              (tc-macro-walk-field state-b macro-live-symbols-arena)
              symbols-b-arena)
            (not (= decl-arena-a-next decl-arena-b))
            (not (= splice-arena-a-next splice-arena-b))
            (not (= splice-arena-a-third splice-arena-b))
            (=
              (tc-macro-walk-field state-b macro-decl-generation-arena)
              decl-arena-b)
            (=
              (tc-macro-walk-field state-b macro-splice-generation-arena)
              splice-arena-b)
            (tc-macro-walk-field state-b macro-live-symbols-ready)
            (string.eq owned-by-b "job-b-generation"))))
      ;; CTFE result markers and export maps share the same job capability.
      (ctfe_support.ctfe-module-macro-export-reset-for-state!
        (tc_core.tc-macro-ctfe-state state-a))
      (ctfe_support.ctfe-module-macro-export-reset-for-state!
        (tc_core.tc-macro-ctfe-state state-b))
      (ctfe_support.ctfe-module-macro-export-add-id-for-state!
        (tc_core.tc-macro-ctfe-state state-a)
        701
        801)
      (ctfe_support.ctfe-module-macro-export-add-id-for-state!
        (tc_core.tc-macro-ctfe-state state-b)
        702
        802)
      (ctfe_support.ctfe-result-hygiene-free-note-for-state!
        (tc_core.tc-macro-ctfe-state state-a)
        17)
      (ctfe_support.ctfe-result-hygiene-free-reset-for-state!
        (tc_core.tc-macro-ctfe-state state-b))
      (let
        [failed-env : ctfe_support.CtfeEnv
          (ctfe_support.ctfe-env-empty-with-pools-and-source-names-and-macro-state
            (ast.ast-node-pool-context-capture-active)
            source-names-a
            (tc_core.tc-macro-ctfe-state state-a))]
        [failed : ctfe_support.ResultCtfe
          (ctfe_support.compiler-ctfe-eval
            (Literal (Float "not-a-float"))
            failed-env
            8)]
        (set!
          ok
          (and
            ok
            (match failed
              [(Err _) true]
              [_ false]))))
      (set!
        ok
        (and
          ok
          (ctfe_support.ctfe-module-macro-export-id-for-state?
            (tc_core.tc-macro-ctfe-state state-a)
            701
            801)
          (not
            (ctfe_support.ctfe-module-macro-export-id-for-state?
              (tc_core.tc-macro-ctfe-state state-b)
              701
              801))
          (=
            (ctfe_support.ctfe-result-hygiene-free-node-id-for-state
              (tc_core.tc-macro-ctfe-state state-a))
            17)
          (=
            (ctfe_support.ctfe-result-hygiene-free-node-id-for-state
              (tc_core.tc-macro-ctfe-state state-b))
            -1)))
      ;; Reset only A. B's import, surface, generated memo, live walk, and
      ;; CTFE export must all remain intact.
      (tc_core.macro-alias-derived-cache-reset-for-state! state-a)
      (tc_core.macro-generated-module-memo-reset! state-a)
      (tc_core.macro-generated-decls-memo-reset! state-a)
      (tc_core.tc-macro-identity-reset-for-state! state-a)
      (ctfe_support.ctfe-module-macro-export-reset-for-state!
        (tc_core.tc-macro-ctfe-state state-a))
      (tc_core.macro-unqualified-import-cache-ensure! state-a)
      (tc_core.macro-alias-cache-ensure! state-a)
      (tc_core.macro-flat-import-target-cache-ensure! state-a)
      (tc_core.macro-surface-call-decl-cache-ensure! state-a)
      (set!
        ok
        (and
          ok
          (=
            (tc_core.macro-unqualified-import-cache-get
              state-a
              module-id-a
              name-id-a)
            -2)
          (=
            (tc_core.macro-unqualified-import-cache-get
              state-b
              module-id-b
              name-id-b)
            401)
          (= (tc_core.macro-alias-cache-get state-a module-id-a name-id-a) -2)
          (= (tc_core.macro-alias-cache-get state-b module-id-b name-id-b) 402)
          (match (tc_core.macro-flat-import-target-cache-get
            state-a
            module-id-a)
            [(Missing) true]
            [_ false])
          (match (tc_core.macro-flat-import-target-cache-get
            state-b
            module-id-b)
            [(Hit targets)
              (and (= targets.len 1) (= (array-ref targets.slots 0) 403))]
            [_ false])
          (match (tc_core.macro-surface-call-decl-cache-get state-a 501 601)
            [(Miss) true]
            [_ false])
          (match (tc_core.macro-surface-call-decl-cache-get state-b 501 601)
            [(Hit (No)) true]
            [_ false])
          (match (tc_core.macro-generated-decls-memo-get
            state-b
            "tc-macro-state-isolation")
            [(Some decls) (= (ast.ast-decl-list-len (& decls)) 0)]
            [_ false])
          (match (tc_core.macro-generated-module-memo-get-catalog
            state-a
            "tc-macro-state-isolation-module")
            [(Empty) true]
            [_ false])
          (match (tc_core.macro-generated-module-memo-get-catalog
            state-b
            "tc-macro-state-isolation-module")
            [(Catalog target _ _ _ _ _) (= target 902)]
            [_ false])
          (string.eq
            (tc-macro-walk-field state-a macro-expand-active-module)
            "isolation-a")
          (string.eq
            (tc-macro-walk-field state-b macro-expand-active-module)
            "isolation-b")
          (ctfe_support.ctfe-module-macro-export-id-for-state?
            (tc_core.tc-macro-ctfe-state state-b)
            702
            802)
          (not
            (ctfe_support.ctfe-module-macro-export-id-for-state?
              (tc_core.tc-macro-ctfe-state state-a)
              701
              801))
          (<
            (tc_core.tc-macro-identity-lookup-for-state
              state-a
              "tc-macro-state-isolation-owner-only")
            0)
          (>=
            (tc_core.tc-macro-identity-lookup-for-state
              state-b
              "tc-macro-state-isolation")
            0)
          (=
            (match (ci.intern-generated-canonical-lookup
              "tc-macro-state-isolation-owner-only")
              [(InternLookupFound id) (+ id 1)]
              [(InternLookupMissing) 0])
            installed-generated-identity-before)
          (= (ci.intern-active-table-id) installed-table-id)
          (= (ci.intern-generation) installed-generation)))
      (tc_core.macro-live-symbols-clear! state-b)
      (tc_core.macro-decl-generations-release! state-b)
      ok)))

(test
  tc-expr-discarding-errors-balances-its-scope
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [missing : i64
      (ast.ast-node-pool-context-expr-push
        pools
        (Var (ci.intern "tc-discarding-scope-missing-name")))]
    [literal : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (Bool true)))]
    [ctx : tc_core.TcContext (tc-literal-pool-test-context pools)]
    [env : tc_core.TcTypeEnv (tc_core.tc-type-env-new)]
    [saved : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [failed? : bool
      (match (tc_core.tc-expr-discarding-errors
        ctx
        env
        (tc_core.tc-context-expr-get ctx missing))
        [(Err _) true]
        [(Ok _) false])]
    [after-error : i64 (tc_core.tc-unbound-suggestion-suppress-depth env)]
    [succeeded? : bool
      (match (tc_core.tc-expr-discarding-errors
        ctx
        env
        (tc_core.tc-context-expr-get ctx literal))
        [(Ok ty)
          (tc_core.tc-type-eq
            (ast.ast-node-pool-reader-type-segment-bases)
            ty
            (Bool))]
        [(Err _) false])]
    [after-success : i64 (tc_core.tc-unbound-suggestion-suppress-depth env)]
    (ast.ast-node-pool-context-install! saved)
    (unless
      (and failed? succeeded? (= after-error 0) (= after-success 0))
      (io.panic
        "typecheck: discarded-error probe left its suggestion scope open"))))

(cfg
  test
  (test
    compiler-typecheck-embedded-provenance-job-isolation
    (let
      [left : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state (tc_core.tc-job-state-new))]
      [right : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state (tc_core.tc-job-state-new))]
      [left-module : String "stdlib.state_a"]
      [right-module : String "stdlib.state_b"]
      [left-ids : sym_i64_env.SymI64Env
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-empty)
          (ci.intern (string.copy left-module))
          1)]
      [right-ids : sym_i64_env.SymI64Env
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-empty)
          (ci.intern (string.copy right-module))
          1)]
      (tc-macro-walk-set! left macro-expand-stdlib-tlci-module-ids left-ids)
      (tc-macro-walk-set! right macro-expand-stdlib-tlci-module-ids right-ids)
      (tc-macro-walk-set!
        right
        macro-expand-stdlib-tlci-module-ids
        (sym_i64_env.sym-i64-empty))
      (test.assert-true
        (tc_core.macro-expand-stdlib-tlci-module-id?
          left
          (string.copy left-module))
        "right provenance reset preserves left snapshot")
      (test.assert-false
        (tc_core.macro-expand-stdlib-tlci-module-id?
          left
          (string.copy right-module))
        "left snapshot does not trust right module")
      (test.assert-false
        (tc_core.macro-expand-stdlib-tlci-module-id?
          right
          (string.copy right-module))
        "right provenance reset is job-local"))))

(test
  tc-noninstalling-expression-walk-pool-isolation
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [literal-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Literal (Int 7 "7")))]
    [macro-a : i64
      (ast.ast-node-pool-context-expr-push pools-a (Literal (Int 8 "8")))]
    [literal-b : i64
      (ast.ast-node-pool-context-expr-push
        pools-b
        (Unsafe (ast.ast-expr-list-new)))]
    [macro-b : i64 (ast.ast-node-pool-context-expr-push pools-b (Quasiquote 0))]
    [ctx-a : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (csym.compiler-symbols-empty)
        (csym.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        pools-a)]
    [_install-decoy : unit (ast.ast-node-pool-context-install! pools-b)]
    [expr-bases-a : i64 (tc_core.tc-context-expr-bases ctx-a)]
    [expr-bases-b : i64
      (ast.ast-node-pool-context-expr-segment-bases (& pools-b))]
    [env : tc_core.TcTypeEnv (tc_core.tc-type-env-new)]
    [decls : ast.AstDeclList (ast.ast-decl-list-new)]
    [literal-a-ok? : bool
      (match (tc_core.tc-integer-literal-expr-with-expected-with-bases
        ctx-a
        expr-bases-a
        (Spanned literal-a (ast.ast-source-span 1 1 1 2))
        (I64))
        [(Ok (I64)) true]
        [_ false])]
    [literal-b-differs? : bool
      (match (tc_core.tc-integer-literal-expr-with-expected-with-bases
        ctx-a
        expr-bases-b
        (Spanned literal-b (ast.ast-source-span 1 1 1 2))
        (I64))
        [(Ok (I32)) true]
        [_ false])]
    [purity-a-ok? : bool
      (match (tc_core.tc-comptime-purity-node-mode
        ctx-a
        expr-bases-a
        env
        Nil
        Nil
        Nil
        false
        literal-a)
        [(Ok) true]
        [_ false])]
    [purity-b-differs? : bool
      (match (tc_core.tc-comptime-purity-node-mode
        ctx-a
        expr-bases-b
        env
        Nil
        Nil
        Nil
        false
        literal-b)
        [(Err _) true]
        [_ false])]
    [macro-a-ok? : bool
      (not
        (tc_core.macro-node-uses-macro?
          ctx-a
          expr-bases-a
          (tc_core.tc-global-shared-view decls)
          macro-a))]
    [macro-b-differs? : bool
      (tc_core.macro-node-uses-macro? ctx-a expr-bases-b decls macro-b)]
    [decoy-still-installed? : bool
      (ast.ast-node-pool-context-expr-installed? pools-b)]
    (ast.ast-node-pool-context-install! installed)
    (if (and
      (= literal-a literal-b)
      (= macro-a macro-b)
      literal-a-ok?
      literal-b-differs?
      purity-a-ok?
      purity-b-differs?
      macro-a-ok?
      macro-b-differs?
      decoy-still-installed?)
      unit
      (io.panic
        "typecheck: noninstalling expression walk pool isolation failed"))))

;; Compatibility entry point for focused callers that construct generated
;; declarations without a distinct physical provenance lane.
(define (macro-materialize-generated-import
  [load-state : (& load-state cload.CompilerLoadSessionState)]
  [decl : ast.AstDecl]
  [decl-path : String]
  [decl-owner-id : i64]
  [module : String]
  [module-id : i64]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultMacroMaterializeImport
  (let
    [load-state : cload.CompilerLoadSessionState
      (owned_view.compiler-owned-reference-shared-view load-state)]
    (tc_core.macro-materialize-generated-import-with-provenance
      load-state
      decl
      decl-path
      decl-owner-id
      decl-owner-id
      module
      module-id
      seen
      stdlib-roots
      cfgs
      pools)))

(define (tc-scratch-arena-state-isolation-self-test) : bool
  (let
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [state-a : tc_core.TcScratchArenaState
      (tc_core.tc-job-state-scratch-arenas job-a)]
    [state-b : tc_core.TcScratchArenaState
      (tc_core.tc-job-state-scratch-arenas job-b)]
    [fn-a : i64 (tc_core.tc-fn-scratch-arena-get state-a)]
    [decl-a : i64 (tc_core.tc-decl-scratch-arena-get state-a)]
    [fn-b : i64 (tc_core.tc-fn-scratch-arena-get state-b)]
    [decl-b : i64 (tc_core.tc-decl-scratch-arena-get state-b)]
    (tc_core.tc-decl-scratch-depth-set! state-a 2)
    (tc_core.tc-decl-scratch-depth-set! state-b 1)
    ;; Exercise both active-arena teardown paths: a direct function release
    ;; and a full reset while A's declaration scratch is current.
    (unsafe
      (arena.tl_arena_set fn-a))
    (tc_core.tc-fn-scratch-arena-release! state-a)
    (unsafe
      (arena.tl_arena_set decl-a))
    (tc_core.tc-job-state-release-scratch-arenas! job-a)
    (tc_core.tc-job-state-reset-file-state! job-a)
    (let
      [after-a-reset : tc_core.TcScratchArenaStateData
        (tc_core.tc-scratch-arena-state-data state-a)]
      [b-live : tc_core.TcScratchArenaStateData
        (tc_core.tc-scratch-arena-state-data state-b)]
      [isolated : bool
        (and
          (not (= fn-a 0))
          (not (= decl-a 0))
          (not (= fn-b 0))
          (not (= decl-b 0))
          (not (= fn-a fn-b))
          (not (= decl-a decl-b))
          (= after-a-reset.fn-arena 0)
          (= after-a-reset.decl-arena 0)
          (= after-a-reset.decl-depth 0)
          (= b-live.fn-arena fn-b)
          (= b-live.decl-arena decl-b)
          (= b-live.decl-depth 1))]
      [fn-a-reused : i64 (tc_core.tc-fn-scratch-arena-get state-a)]
      [decl-a-reused : i64 (tc_core.tc-decl-scratch-arena-get state-a)]
      (tc_core.tc-decl-scratch-depth-set! state-a 3)
      (let
        [b-after-a-reuse : tc_core.TcScratchArenaStateData
          (tc_core.tc-scratch-arena-state-data state-b)]
        [reused : bool
          (and
            (not (= fn-a-reused 0))
            (not (= decl-a-reused 0))
            (= (tc_core.tc-decl-scratch-depth state-a) 3)
            (= b-after-a-reuse.fn-arena fn-b)
            (= b-after-a-reuse.decl-arena decl-b)
            (= b-after-a-reuse.decl-depth 1))]
        (tc_core.tc-job-state-release-scratch-arenas! job-a)
        (tc_core.tc-job-state-reset-file-state! job-a)
        (tc_core.tc-job-state-release-scratch-arenas! job-b)
        (tc_core.tc-job-state-reset-file-state! job-b)
        (let
          [after-a-reuse-reset : tc_core.TcScratchArenaStateData
            (tc_core.tc-scratch-arena-state-data state-a)]
          [after-b-reset : tc_core.TcScratchArenaStateData
            (tc_core.tc-scratch-arena-state-data state-b)]
          (and
            isolated
            reused
            (= after-a-reuse-reset.fn-arena 0)
            (= after-a-reuse-reset.decl-arena 0)
            (= after-a-reuse-reset.decl-depth 0)
            (= after-b-reset.fn-arena 0)
            (= after-b-reset.decl-arena 0)
            (= after-b-reset.decl-depth 0)))))))

(cfg
  test
  (test
    tc-scratch-arena-job-owned-reset-reuse
    (if (tc-scratch-arena-state-isolation-self-test)
      unit
      (io.panic "typecheck: job-owned scratch arena isolation failed"))))

(cfg
  test
  (test
    lazy-import-preserving-reset-handoff
    (let
      [job-state : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [macro-state : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state job-state)]
      [importer-id : i64 (ci.intern "handoff.importer")]
      [alias-id : i64 (ci.intern "handoff-alias")]
      [target-id : i64 (ci.intern "handoff.target")]
      (tc_core.tc-lazy-import-stub-record-for-job!
        job-state
        importer-id
        alias-id
        target-id
        true)
      (tc_core.compiler-typecheck-reset-file-state-preserving-lazy-imports-for-job!
        job-state)
      (let
        [preserved? : bool
          (match (tc_core.tc-lazy-import-stub-target-id-for-state
            macro-state
            importer-id
            alias-id)
            [(Some target) (= target target-id)]
            [(No) false])]
        (tc_core.compiler-typecheck-reset-file-state-for-job! job-state)
        (if (and
          preserved?
          (match (tc_core.tc-lazy-import-stub-target-id-for-state
            macro-state
            importer-id
            alias-id)
            [(Some _) false]
            [(No) true]))
          unit
          (io.panic "typecheck: preserving lazy-import handoff reset failed"))))))

;; --- generated-declarations memo re-arm (#8158) ---------------------------------
(cfg
  test
  (define (memo-test-decls [count : i64]) : ast.AstDeclList
    (let
      [out : ast.AstDeclList (ast.ast-decl-list-new)]
      [index : i64 0]
      (while (< index count)
        (set!
          out
          (ast.ast-decl-cons
            (ast.ast-decl-def-fn-id
              (ci.intern-generated-name "memo-test-decl")
              (ast.ast-param-list-new)
              (Unit)
              (ast.ast-node-push (Literal (Unit))))
            out))
        (set! index (+ index 1)))
      out)))

(cfg
  test
  (define (memo-test-identity [index : i64]) : String
    (str_cat.str-cat "memo-test-identity-" (string.int->string index))))

;; The number of decls memoized for `identity`, or -1 when it misses.
(cfg
  test
  (define (memo-test-lookup [state : tc_core.TcMacroState] [index : i64]) : i64
    (match (tc_core.macro-generated-decls-memo-get
      state
      (memo-test-identity index))
      [(Some decls) (ast.ast-decl-list-len (& decls))]
      [(No) -1])))

;; An identity index past 0 whose bucket is identity 0's, so it probes past it.
(cfg
  test
  (define (memo-test-colliding-index [state : tc_core.TcMacroState]) : i64
    (let
      [home : i64
        (tc_core.macro-generated-decls-memo-bucket
          state
          (tc_core.macro-generated-identity-id state (memo-test-identity 0)))]
      [index : i64 1]
      (while (!=
        (tc_core.macro-generated-decls-memo-bucket
          state
          (tc_core.macro-generated-identity-id state (memo-test-identity index)))
        home)
        (set! index (+ index 1)))
      index)))

(cfg
  test
  (test
    macro-generated-decls-memo-rearm-clears-only-keys
    (let
      [job : tc_core.TcJobState (tc_core.tc-job-state-new)]
      [state : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job)]
      [other : i64 (memo-test-colliding-index state)]
      (tc_core.macro-generated-decls-memo-put!
        state
        (memo-test-identity 0)
        (memo-test-decls 1))
      (tc_core.macro-generated-decls-memo-put!
        state
        (memo-test-identity other)
        (memo-test-decls 2))
      (test.assert-i64-eq (memo-test-lookup state 0) 1 "home slot entry")
      (test.assert-i64-eq
        (memo-test-lookup state other)
        2
        "an entry that probes past the home slot")
      (tc_core.macro-generated-decls-memo-reset! state)
      (let
        [before : i64 (profile.alloc-total)]
        (tc_core.macro-generated-decls-memo-ensure! state)
        (test.assert-i64-eq
          (- (profile.alloc-total) before)
          0
          "re-arming the memo allocates nothing"))
      (test.assert-i64-eq (memo-test-lookup state 0) -1 "no stale home entry")
      (test.assert-i64-eq
        (memo-test-lookup state other)
        -1
        "no stale probed entry")
      ;; After the re-arm `other` takes the empty home slot. Identity 0 then
      ;; probes past it into the zeroed slot that still holds the old list,
      ;; and must miss rather than return that list.
      (tc_core.macro-generated-decls-memo-put!
        state
        (memo-test-identity other)
        (memo-test-decls 3))
      (test.assert-i64-eq
        (memo-test-lookup state other)
        3
        "put/get round-trips after a re-arm")
      (test.assert-i64-eq
        (memo-test-lookup state 0)
        -1
        "a key probing past a zeroed slot misses")
      (tc_core.macro-generated-decls-memo-put!
        state
        (memo-test-identity 0)
        (memo-test-decls 4))
      (test.assert-i64-eq
        (memo-test-lookup state 0)
        4
        "the zeroed slot is reused"))))