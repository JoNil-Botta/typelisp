;; #9581 (A''): walk-scoped stamps behind the fan-out visit budget. Every
;; answer must equal the plain walk's: below B = 64 fan-out visits the walk
;; is main's own, above it completed results of the same root walk are
;; reused. The equalities below are checked by construction.
(import compiler_ast_types as ast)
(import compiler_typecheck_core as tc)
(import compiler_intern as ci)
(import compiler_check_core as check_core)
(import compiler_load)
(import compiler_parse_core as parser)
(import compiler_typecheck_api)
(import sym_i64_env)
(import stdlib.iterator)
(import stdlib.io)
(cfg test (import stdlib.test))

(define (walk-push [ty : ast.AstType]) : i64
  (let
    [node : ast.AstType ty]
    (ast.ty-node-push-raw (& node))))

(define (walk-tuple [items : ast.AstTypeList]) : i64
  (let
    [node : ast.AstType (ast.ast-ty-tuple items)]
    (ast.ty-node-push-raw (& node))))

;; A flat tuple of `count` leaves (fan-out visits = count); the last leaf is
;; `last`, every other one is i64.
(define (walk-flat [count : i64] [last : i64]) : i64
  (let
    [plain : i64 (walk-push ast.AstType.I64)]
    [items : ast.AstTypeList (ast.ast-type-list-with-capacity count)]
    (for [at (iterator.range 0 count)]
      (ast.ast-type-list-push
        (&mut items)
        (if (= at (- count 1))
          last
          plain)))
    (walk-tuple items)))

;; A binary tuple DAG of `depth` levels over `leaf` (2^depth unfolded leaves).
(define (walk-dag [depth : i64] [leaf : i64]) : i64
  (let
    [node : i64 leaf]
    (for [_level (iterator.range 0 depth)]
      (let
        [items : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
        (ast.ast-type-list-push (&mut items) node)
        (ast.ast-type-list-push (&mut items) node)
        (set! node (walk-tuple items))))
    node))

(define (walk-expect [label : String] [ok : bool]) : unit
  (unless ok (io.panic label)))

(define (walk-region-tag? [id : i64]) : bool
  (tc.tc-type-contains-region-tag? (ast.ty-node-get id)))

(define (walk-loan-free? [id : i64]) : bool
  (tc.tc-selected-type-loan-free? (ast.ty-node-get id)))

;; Fan-out 63 / 64 / 65 at one root: the plain prefix, the boundary visit and
;; the first stamped visit all answer as the plain walk does.
(define (walk-boundary-test) : unit
  (let
    [r : i64 (ci.intern "walk-r")]
    [plain : i64 (walk-push ast.AstType.I64)]
    [region : i64 (walk-push (ast.AstType.Region r plain))]
    [reference : i64 (walk-push (ast.AstType.Ref r plain))]
    (for [count (iterator.range 62 67)]
      (walk-expect
        "flat region tag"
        (walk-region-tag? (walk-flat count region)))
      (walk-expect
        "flat no region tag"
        (not (walk-region-tag? (walk-flat count plain))))
      (walk-expect
        "flat loan"
        (not (walk-loan-free? (walk-flat count reference))))
      (walk-expect "flat loan-free" (walk-loan-free? (walk-flat count plain)))
      (walk-expect
        "flat collect"
        (tc.tc-name-id-list-contains
          (tc.tc-type-collect-regions
            (ast.ty-node-get (walk-flat count reference)))
          r)))))

;; Shared DAGs: exact for every ctx-free family (and polynomial at depth 40
;; while stamping is available), and
;; without-regions (whose walk calls contains-region-tag at every level)
;; nests a second family's serials inside its own, so overwritten entries of
;; the enclosing walk go through the undo log.
(define (walk-dag-test [depth : i64]) : unit
  (let
    [r : i64 (ci.intern "walk-dag-r")]
    [plain : i64 (walk-push ast.AstType.I64)]
    [region : i64 (walk-push (ast.AstType.Region r plain))]
    [reference : i64 (walk-push (ast.AstType.Ref r plain))]
    [with-region : i64 (walk-dag depth region)]
    [without : i64 (walk-dag depth plain)]
    [with-reference : i64 (walk-dag depth reference)]
    (walk-expect "dag region tag" (walk-region-tag? with-region))
    (walk-expect "dag no region tag" (not (walk-region-tag? without)))
    (walk-expect "dag loan" (not (walk-loan-free? with-reference)))
    (walk-expect "dag loan-free" (walk-loan-free? without))
    (walk-expect
      "dag view"
      (tc.tc-selected-type-contains-view? (ast.ty-node-get with-region)))
    (walk-expect
      "dag no view"
      (not (tc.tc-selected-type-contains-view? (ast.ty-node-get without))))
    (let
      [regions : tc.TcNameIdList
        (tc.tc-type-collect-regions (ast.ty-node-get with-reference))]
      (walk-expect "dag collect one" (= (tc.tc-name-id-list-len regions) 1))
      (walk-expect "dag collect r" (tc.tc-name-id-list-contains regions r)))
    (walk-expect
      "dag without-regions"
      (tc.tc-type-eq
        (tc.tc-type-without-regions (ast.ty-node-get with-region))
        (ast.ty-node-get without)))
    (walk-expect
      "dag without-regions keeps plain"
      (not
        (walk-region-tag?
          (walk-push (tc.tc-type-without-regions (ast.ty-node-get with-region))))))))

;; Every family's visit and serial word (families 0..10).
(define (walk-words-idle?) : bool
  (=
    0
    (bit-or
      tc.tc-walk-visits-0
      (bit-or
        tc.tc-walk-serial-0
        (bit-or
          tc.tc-walk-visits-1
          (bit-or
            tc.tc-walk-serial-1
            (bit-or
              tc.tc-walk-visits-2
              (bit-or
                tc.tc-walk-serial-2
                (bit-or
                  tc.tc-walk-visits-3
                  (bit-or
                    tc.tc-walk-serial-3
                    (bit-or
                      tc.tc-walk-visits-4
                      (bit-or
                        tc.tc-walk-serial-4
                        (bit-or
                          tc.tc-walk-visits-5
                          (bit-or
                            tc.tc-walk-serial-5
                            (bit-or
                              tc.tc-walk-visits-6
                              (bit-or
                                tc.tc-walk-serial-6
                                (bit-or
                                  tc.tc-walk-visits-7
                                  (bit-or
                                    tc.tc-walk-serial-7
                                    (bit-or
                                      tc.tc-walk-visits-8
                                      (bit-or
                                        tc.tc-walk-serial-8
                                        (bit-or
                                          tc.tc-walk-visits-9
                                          (bit-or
                                            tc.tc-walk-serial-9
                                            (bit-or
                                              tc.tc-walk-visits-10
                                              tc.tc-walk-serial-10)))))))))))))))))))))))

(define (walk-job-table [job : tc.TcJobState]) : i64
  (tc.tc-macro-state-slot-address
    (tc.tc-job-state-macro-state job)
    tc.tc-macro-state-slot-type-walk))

;; One REPL request against a fixed session: `want` is whether it checks.
(define (walk-repl-request [source : String] [want : bool]) : unit
  (match (compiler_load.compiler-load-source
    (& "tests/walk_repl_session.tl")
    (&
      "(define (pair [x : i64]) : (Tuple i64 i64) (tuple x x))
(define (quad [x : i64]) : (Tuple (Tuple i64 i64) (Tuple i64 i64))
  (tuple (pair x) (pair x)))")
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _)
      (match (parser.parse-ast-repl-source (& source))
        [(Ok item)
          (match item
            [(AstReplExpr expr)
              (match (compiler_typecheck_api.typecheck-compiler-repl-expr
                decls
                (ast.ast-node-get expr))
                [(Ok _) (walk-expect "REPL request failed" want)]
                [(Err _) (walk-expect "REPL request checked" (not want))])]
            [(AstReplDecl _) (io.panic "REPL request parsed as a declaration")])]
        [(Err _) (io.panic "REPL request did not parse")])]
    [(Err _) (io.panic "REPL session did not load")]))

;; Repeated and failing REPL requests: each binds the serial job, releases its
;; table when that binding was the outermost, restores the caller's binding,
;; and leaves every walk word idle.
(define (walk-repl-test [job : tc.TcJobState]) : unit
  (let
    [serial : tc.TcJobState (tc.tc-serial-job-state)]
    (for [_round (iterator.range 0 3)]
      (walk-repl-request "(quad 1)" true)
      (walk-repl-request "(+ 1 \"x\")" false)
      (walk-repl-request "(tuple (quad 1) (quad 2))" true)
      (walk-repl-request "(quad \"x\")" false)
      (walk-expect
        "REPL binding not restored"
        (= tc.tc-type-walk-job job.address))
      (walk-expect "REPL kept the serial table" (= (walk-job-table serial) 0))
      (walk-expect "REPL left walk words open" (walk-words-idle?)))
    ;; Inside a binding of the serial job itself the request is nested: the
    ;; table stays for the enclosing binding, which releases it.
    (let
      [outer : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! serial)]
      [table : i64 (tc.tc-type-walk-table)]
      (walk-repl-request "(quad 1)" true)
      (walk-repl-request "(quad \"x\")" false)
      (walk-expect
        "nested REPL lost the binding"
        (= tc.tc-type-walk-job serial.address))
      (walk-expect
        "nested REPL released the table"
        (= (walk-job-table serial) table))
      (tc.tc-type-walk-restore! outer)
      (tc.tc-type-walk-table-release! serial)
      (walk-expect "serial table not released" (= (walk-job-table serial) 0)))))

;; Error injection: a failing check whose types fan out runs under its own
;; binding; afterwards the caller's binding is back and every word is idle.
(define (walk-failing-check-test [job : tc.TcJobState]) : unit
  (match (check_core.compiler-check-source
    "tests/walk_failing.tl"
    "(define (main) : i64
  (let [p (tuple 1 1)] [q (tuple p p)] [r (tuple q q)] [s (tuple r r)]
    [t (ann s : (Tuple (Tuple (Tuple (Tuple i64 i64) (Tuple i64 i64)) (Tuple (Tuple i64 i64) (Tuple i64 i64))) (Tuple (Tuple (Tuple i64 i64) (Tuple i64 i64)) (Tuple (Tuple i64 i64) (Tuple i64 bool)))))]
    0))")
    [(Ok _ _) (io.panic "failing walk source checked")]
    [(Err _ _) unit])
  (walk-expect
    "binding not restored after a failing check"
    (= tc.tc-type-walk-job job.address))
  (walk-expect "failing check left walk words open" (walk-words-idle?))
  (walk-expect
    "failing check kept the serial table"
    (= (walk-job-table (tc.tc-serial-job-state)) 0)))

(cfg
  test
  (define (walk-stamps-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [job : tc.TcJobState (tc.tc-job-state-new)]
      [outer : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! job)]
      (ast.ast-node-pool-context-install!
        (ast.ast-node-pool-context-new-with-capacities 8 8))
      (walk-boundary-test)
      (walk-dag-test 40)
      (walk-expect "words idle after walks" (walk-words-idle?))
      ;; Forced serial wrap and exhaustion: limit 4 wraps whenever no serial
      ;; is open and nested walks past it run unstamped; limit 1 never
      ;; stamps. Both stay exact (small DAGs: unstamped walks unfold).
      (tc.tc-walk-serial-limit-set! 4)
      (walk-boundary-test)
      (walk-dag-test 12)
      (tc.tc-walk-serial-limit-set! 1)
      (walk-boundary-test)
      (walk-dag-test 12)
      (tc.tc-walk-serial-limit-set! 1152921504606846976)
      (walk-expect "words idle after wrap" (walk-words-idle?))
      ;; REPL requests and a failing check, under the test job's binding.
      (ast.ast-node-pool-context-install! installed)
      (walk-repl-test job)
      (walk-failing-check-test job)
      (ast.ast-node-pool-context-install!
        (ast.ast-node-pool-context-new-with-capacities 8 8))
      ;; Release in between: the next walk starts a fresh table.
      (tc.tc-type-walk-restore! outer)
      (tc.tc-type-walk-table-release! job)
      (let
        [again : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! job)]
        (walk-dag-test 40)
        (tc.tc-type-walk-restore! again)
        (tc.tc-type-walk-table-release! job))
      ;; Unbound: no table, the plain walks stay exact (small depth only).
      (walk-boundary-test)
      (walk-expect "words idle at the end" (walk-words-idle?))
      (ast.ast-node-pool-context-install! installed))))

(test walk-stamps-controls (walk-stamps-self-test))

(define (main) : i64
  (cfg test (walk-stamps-self-test))
  42)