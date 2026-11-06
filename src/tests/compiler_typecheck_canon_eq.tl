;; #9581: canonical type-ID equality on the job's type-walk table.
(import compiler_ast_types as ast)
(import compiler_typecheck_core as tc)
(import compiler_check_core as check_core)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import stdlib.vector)
(import (vector.vector String) as canon_svec)
(import stdlib.iterator)
(import stdlib.io)
(cfg test (import stdlib.test))

(define (canon-eq-expect [label : String] [want : bool] [a : i64] [b : i64]) : unit
  (unless
    (= (tc.tc-type-eq (ast.ty-node-get a) (ast.ty-node-get b)) want)
    (io.panic label)))

;; A binary tuple DAG of `depth` levels over `leaf`, appended with raw pushes so
;; neither side is deduplicated against the other (or against itself).
(define (canon-eq-raw-dag [depth : i64] [leaf : ast.AstType]) : i64
  (let
    [node : i64 (ast.ty-node-push-raw (& leaf))]
    (for [_level (iterator.range 0 depth)]
      (let
        [children : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
        (ast.ast-type-list-push (&mut children) node)
        (ast.ast-type-list-push (&mut children) node)
        (set! node (ast.ty-node-push-raw (& (ast.ast-ty-tuple children))))))
    node))

(define (canon-eq-pair [a : i64] [b : i64]) : i64
  (let
    [children : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
    (ast.ast-type-list-push (&mut children) a)
    (ast.ast-type-list-push (&mut children) b)
    (ast.ty-node-push (& (ast.ast-ty-tuple children)))))

(define (canon-eq-fresh-pool) : unit
  (ast.ast-node-pool-context-install!
    (ast.ast-node-pool-context-new-with-capacities 8 8)))

;; Raw-appended (dedup-bypassing) equal DAGs: distinct IDs at every level,
;; equal by canonical ID, so depth 40 stays linear.
(define (canon-eq-raw-test) : unit
  (let
    [left : i64 (canon-eq-raw-dag 40 ast.AstType.I64)]
    [right : i64 (canon-eq-raw-dag 40 ast.AstType.I64)]
    [other : i64 (canon-eq-raw-dag 40 ast.AstType.I32)]
    (when (= left right) (io.panic "raw DAGs share an id"))
    (canon-eq-expect "raw equal DAGs" true left right)
    (canon-eq-expect "raw different leaves" false left other)))

;; Region transparency at the root and below a wrapper; reference lifetimes
;; are never canonicalised away.
(define (canon-eq-push-raw [ty : ast.AstType]) : i64
  (let
    [node : ast.AstType ty]
    (ast.ty-node-push-raw (& node))))

(define (canon-eq-push [ty : ast.AstType]) : i64
  (let
    [node : ast.AstType ty]
    (ast.ty-node-push (& node))))

(define (canon-eq-region-test) : unit
  (let
    [r : i64 (ci.intern "canon-r")]
    [s : i64 (ci.intern "canon-s")]
    [plain : i64 (canon-eq-push ast.AstType.I64)]
    [region : i64 (canon-eq-push (ast.AstType.Region r plain))]
    [box-plain : i64 (canon-eq-push (ast.AstType.Box plain))]
    [box-region : i64 (canon-eq-push (ast.AstType.Box region))]
    [ref-r : i64 (canon-eq-push (ast.AstType.Ref r plain))]
    [ref-s : i64 (canon-eq-push (ast.AstType.Ref s plain))]
    (canon-eq-expect "region root" true region plain)
    (canon-eq-expect "region below box" true box-region box-plain)
    (canon-eq-expect
      "region in a pair"
      true
      (canon-eq-pair box-region plain)
      (canon-eq-pair box-plain region))
    (canon-eq-expect "ref lifetimes differ" false ref-r ref-s)
    (canon-eq-expect "ref lifetimes equal" true ref-r ref-r)))

;; Poison is compatible with anything; a canonical mismatch is never a false
;; answer on its own.
(define (canon-eq-poison-test) : unit
  (let
    [poison : i64 (canon-eq-push (ast.AstType.Var tc.tc-poison-type-name-id))]
    [i64-id : i64 (canon-eq-push ast.AstType.I64)]
    [bool-id : i64 (canon-eq-push ast.AstType.Bool)]
    (canon-eq-expect
      "poison left"
      true
      (canon-eq-pair poison i64-id)
      (canon-eq-pair bool-id i64-id))
    (canon-eq-expect
      "poison right"
      true
      (canon-eq-pair i64-id i64-id)
      (canon-eq-pair i64-id poison))))

;; Truncate and reuse: the generation changes, the table is cleared, and the
;; reused IDs answer for their new contents.
(define (canon-eq-truncate-test) : unit
  (let
    [mark : i64 (ast.ty-node-pool-len)]
    [a : i64 (canon-eq-raw-dag 3 ast.AstType.I64)]
    [b : i64 (canon-eq-raw-dag 3 ast.AstType.I64)]
    (canon-eq-expect "before truncation" true a b)
    (ast.ty-node-pool-truncate! mark)
    (let
      [a2 : i64 (canon-eq-raw-dag 3 ast.AstType.I64)]
      [b2 : i64 (canon-eq-raw-dag 3 ast.AstType.U8)]
      (when (!= a2 a) (io.panic "truncation did not reuse ids"))
      (canon-eq-expect "after truncation reuse" false a2 b2))))

;; Distinct pools with equal numeric IDs: the table follows the installed pool.
(define (canon-eq-pools-test) : unit
  (canon-eq-fresh-pool)
  (let
    [x : i64 (canon-eq-raw-dag 2 ast.AstType.I64)]
    [y : i64 (canon-eq-raw-dag 2 ast.AstType.I64)]
    (canon-eq-expect "first pool" true x y)
    (canon-eq-fresh-pool)
    (let
      [x2 : i64 (canon-eq-raw-dag 2 ast.AstType.I64)]
      [y2 : i64 (canon-eq-raw-dag 2 ast.AstType.F64)]
      (when (!= x2 x) (io.panic "fresh pool did not reuse ids"))
      (when (!= y2 y) (io.panic "fresh pool did not reuse ids"))
      (canon-eq-expect "second pool, equal ids, other contents" false x2 y2))))

;; Context reset (truncation through the installed context, which does not
;; bump the global generation): warmed canonical IDs must not survive into
;; reused IDs. The cell's live revision moves, so the table clears.
(define (canon-eq-context-reset-test) : unit
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [expr-mark : i64 (ast.ast-node-pool-len)]
    [type-mark : i64 (ast.ty-node-pool-len)]
    [x : i64 (canon-eq-push-raw ast.AstType.I64)]
    [y : i64 (canon-eq-push-raw ast.AstType.I64)]
    (canon-eq-expect
      "warm boxes"
      true
      (canon-eq-push (ast.AstType.Box x))
      (canon-eq-push (ast.AstType.Box y)))
    (ast.ast-node-pool-context-reset-to! pools expr-mark type-mark)
    (let
      [x2 : i64 (canon-eq-push-raw ast.AstType.I64)]
      [y2 : i64 (canon-eq-push-raw ast.AstType.Bool)]
      (when (!= x2 x) (io.panic "reset did not reuse ids"))
      (when (!= y2 y) (io.panic "reset did not reuse ids"))
      (canon-eq-expect
        "boxes over reused ids after a context reset"
        false
        (canon-eq-push (ast.AstType.Box x2))
        (canon-eq-push (ast.AstType.Box y2))))))

;; A nested binding of the same job before the first allocation: the table
;; allocated inside is the job's table afterwards too (no second table).
(define (canon-eq-same-job-nesting-test) : unit
  (let
    [job : tc.TcJobState (tc.tc-job-state-new)]
    [outer : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! job)]
    [inner : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! job)]
    [first : i64 (tc.tc-type-walk-table)]
    (tc.tc-type-walk-restore! inner)
    (when
      (!= (tc.tc-type-walk-table) first)
      (io.panic "same job allocated twice"))
    (tc.tc-type-walk-restore! outer)
    (tc.tc-type-walk-table-release! job)
    (when
      (!= (canon-eq-job-table job) 0)
      (io.panic "nesting job kept its table"))))

;; Macro expansion runs unbound and restores the caller's binding, on
;; success and on failure.
(define (canon-eq-expansion-binding-test [job : tc.TcJobState]) : unit
  (match (check_core.compiler-check-source
    "tests/canon_eq_macro_ok.tl"
    "(defmacro (twice [x : Expr]) : Expr `(tuple ,x ,x))
(define (main) : i64 (let [p (twice 1)] 0))")
    [(Ok _ _) unit]
    [(Err _ _) (io.panic "macro source rejected")])
  (when
    (!= tc.tc-type-walk-job job.address)
    (io.panic "binding not restored after a macro expansion"))
  (canon-eq-expect-no-table "a macro check")
  (match (check_core.compiler-check-source
    "tests/canon_eq_macro_bad.tl"
    "(defmacro (twice [x : Expr]) : Expr `(tuple ,x ,x))
(define (main) : i64 (let [p (twice (+ 1 \"x\"))] 0))")
    [(Ok _ _) (io.panic "failing macro source checked")]
    [(Err _ _) unit])
  (when
    (!= tc.tc-type-walk-job job.address)
    (io.panic "binding not restored after a failing macro expansion")))

;; A file-state reset releases the job's table; the next use allocates a
;; fresh one and equality stays exact.
(define (canon-eq-release-test [job : tc.TcJobState]) : unit
  (let
    [before : i64 (tc.tc-type-walk-table)]
    (when (= before 0) (io.panic "no table before release"))
    (tc.tc-type-walk-table-release! job)
    (canon-eq-expect
      "after release"
      true
      (canon-eq-raw-dag 8 ast.AstType.I64)
      (canon-eq-raw-dag 8 ast.AstType.I64))
    (when (= (tc.tc-type-walk-table) 0) (io.panic "no table after release"))))

;; Interleaved jobs: B's binding runs inside A's; A's binding and table come
;; back intact.
(define (canon-eq-jobs-test [job : tc.TcJobState]) : unit
  (let
    [address-a : i64 (tc.tc-type-walk-table)]
    [job-b : tc.TcJobState (tc.tc-job-state-new)]
    [inner : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! job-b)]
    [address-b : i64 (tc.tc-type-walk-table)]
    (when (= address-a address-b) (io.panic "jobs share a table"))
    (canon-eq-expect
      "job B"
      true
      (canon-eq-raw-dag 4 ast.AstType.I64)
      (canon-eq-raw-dag 4 ast.AstType.I64))
    (tc.tc-type-walk-restore! inner)
    (tc.tc-type-walk-table-release! job-b)
    (when (!= tc.tc-type-walk-job job.address) (io.panic "job A binding lost"))
    (when (!= (tc.tc-type-walk-table) address-a) (io.panic "job A table lost"))))

;; A check's job keeps no type-walk table once the check returns, even a
;; temporary job that is never reset or retired (the typed-lint fallback).
(define (canon-eq-job-table [job : tc.TcJobState]) : i64
  (tc.tc-macro-state-slot-address
    (tc.tc-job-state-macro-state job)
    tc.tc-macro-state-slot-type-walk))

(define (canon-eq-expect-no-table [label : String]) : unit
  (when (!= (canon-eq-job-table (tc.tc-serial-job-state)) 0) (io.panic label)))

(define (canon-eq-temporary-job-test) : unit
  (let
    [job : tc.TcJobState (tc.tc-job-state-new)]
    [roots : canon_svec.Vec (canon_svec.new)]
    (match (check_core.compiler-check-source-with-roots-and-cfg-and-job-state
      "tests/canon_eq_temporary_job.tl"
      "(define (pair [x : i64]) : (Tuple i64 i64) (tuple x x))
(define (main) : i64 (let [p (pair 1)] [q (ann p : (Tuple i64 i64))] 0))"
      roots
      (parser.compiler-cfg-empty)
      job)
      [(Ok _ _) unit]
      [(Err _ _) (io.panic "temporary-job source rejected")])
    (when
      (!= (canon-eq-job-table job) 0)
      (io.panic "temporary job kept its type-walk table"))))

;; A failing check runs its own job binding and restores the caller's.
(define (canon-eq-failing-check-test [job : tc.TcJobState]) : unit
  (match (check_core.compiler-check-source
    "tests/canon_eq_failing.tl"
    "(define (main) : i64 (+ 1 \"x\"))")
    [(Ok _ _) (io.panic "failing source checked")]
    [(Err _ _) unit])
  (when
    (!= tc.tc-type-walk-job job.address)
    (io.panic "binding not restored after a failing check"))
  (canon-eq-expect-no-table "a failing check"))

(cfg
  test
  (define (canon-eq-self-test) : unit
    (let
      [installed : ast.AstNodePoolContext
        (ast.ast-node-pool-context-capture-active)]
      [job : tc.TcJobState (tc.tc-job-state-new)]
      [outer : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! job)]
      (canon-eq-fresh-pool)
      (canon-eq-raw-test)
      (canon-eq-region-test)
      (canon-eq-poison-test)
      (canon-eq-truncate-test)
      (canon-eq-pools-test)
      (canon-eq-context-reset-test)
      (canon-eq-jobs-test job)
      (canon-eq-same-job-nesting-test)
      (canon-eq-release-test job)
      (ast.ast-node-pool-context-install! installed)
      (canon-eq-failing-check-test job)
      (canon-eq-expansion-binding-test job)
      (canon-eq-temporary-job-test)
      (tc.tc-type-walk-restore! outer)
      (tc.tc-type-walk-table-release! job)
      ;; Unbound: the table bypasses and equality stays exact.
      (canon-eq-fresh-pool)
      (when (!= (tc.tc-type-walk-table) 0) (io.panic "unbound table"))
      (canon-eq-expect
        "unbound raw DAGs"
        true
        (canon-eq-raw-dag 6 ast.AstType.I64)
        (canon-eq-raw-dag 6 ast.AstType.I64))
      (ast.ast-node-pool-context-install! installed))))

(test canonical-type-id-equality-controls (canon-eq-self-test))

(define (main) : i64
  (cfg test (canon-eq-self-test))
  42)