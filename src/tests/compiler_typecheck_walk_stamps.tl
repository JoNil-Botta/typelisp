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
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
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

;; A one-element tuple around `id`: its element visit is the root, so every
;; fan-out visit inside `id` counts toward that one root's budget.
(define (walk-wrap [id : i64]) : i64
  (let
    [items : ast.AstTypeList (ast.ast-type-list-with-capacity 1)]
    (ast.ast-type-list-push (&mut items) id)
    (walk-tuple items)))

;; The bound table's last issued serial (0 with no table).
(define (walk-table-serial) : i64
  (let
    [address : i64 (tc.tc-type-walk-table)]
    (if (= address 0)
      0
      (unsafe
        (deref (int->ptr (cast address : u64) : (Ptr tc.TcTypeWalkTable))).serial))))

;; Serials one full walk of `id` issues in `family` (2 loan-free, 0 region tag).
(define (walk-serials-issued [family : i64] [id : i64]) : i64
  (let
    [before : i64 (walk-table-serial)]
    (if (= family 2)
      (walk-expect "wrapped loan-free" (walk-loan-free? id))
      (walk-expect "wrapped no region tag" (not (walk-region-tag? id))))
    (- (walk-table-serial) before)))

;; Fan-out 62..66 below one root: the root visit plus `count` leaves. The first
;; B = 64 visits are plain, so a serial opens exactly when count >= 64; every
;; answer matches the plain walk. Unwrapped flat tuples are separate roots
;; (each leaf is its own root) and must never open a serial. `mode` 1 expects
;; that boundary exactly, 0 expects no serial issued (limit 1 or unbound), -1
;; leaves the counts unchecked (limit 4 wraps and restarts them).
(define (walk-boundary-test [mode : i64]) : unit
  (let
    [r : i64 (ci.intern "walk-r")]
    [plain : i64 (walk-push ast.AstType.I64)]
    [region : i64 (walk-push (ast.AstType.Region r plain))]
    [reference : i64 (walk-push (ast.AstType.Ref r plain))]
    (for [count (iterator.range 62 67)]
      (let
        [want : i64
          (if (>= count 64)
            1
            0)]
        [loan-free : i64
          (walk-serials-issued 2 (walk-wrap (walk-flat count plain)))]
        [region-tag : i64
          (walk-serials-issued 0 (walk-wrap (walk-flat count plain)))]
        [unwrapped : i64 (walk-serials-issued 2 (walk-flat count plain))]
        (when
          (= mode 1)
          (walk-expect "loan-free serial at the boundary" (= loan-free want))
          (walk-expect "region-tag serial at the boundary" (= region-tag want))
          (walk-expect "unwrapped leaves are separate roots" (= unwrapped 0)))
        ;; Stamping off: no serial is issued (a refused open may wrap the
        ;; counter back, so the difference can be negative).
        (when
          (= mode 0)
          (walk-expect
            "serial issued with stamping off"
            (and (<= loan-free 0) (<= region-tag 0) (<= unwrapped 0))))
        (walk-expect
          "wrapped region tag"
          (walk-region-tag? (walk-wrap (walk-flat count region))))
        (walk-expect
          "wrapped loan"
          (not (walk-loan-free? (walk-wrap (walk-flat count reference)))))
        (walk-expect
          "wrapped collect"
          (tc.tc-name-id-list-contains
            (tc.tc-type-collect-regions
              (ast.ty-node-get (walk-wrap (walk-flat count reference))))
            r)))
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

;; Source text of a binary tuple DAG of `depth` levels over leaf `kind`
;; (0 i64, 1 a small S-bearing tuple).
(define (walk-source-leaf [kind : i64]) : String
  (if (= kind 0)
    "i64"
    "(Tuple S (Tuple (Tuple i64 i64) (Tuple i64 i64)))"))

(define (walk-source-dag [depth : i64] [kind : i64]) : String
  (if (= depth 0)
    (walk-source-leaf kind)
    (str_cat.str-cat
      "(Tuple "
      (walk-source-dag (- depth 1) kind)
      " "
      (walk-source-dag (- depth 1) kind)
      ")")))

;; Struct S holds a 128-leaf i64 DAG `f` (or, with `small`, a lone i64) and,
;; when move-only, a Box. `twice` copies one root, `(Tuple (Tuple D E))`: the
;; root first walks D (the same 128-leaf DAG, 255 fan-out visits, so the
;; root's serial is open) and only then reaches S inside E. S's first
;; (uncached) move-kind frame walks `f` as its own root, which opens a second
;; serial while the outer one is open and overwrites the outer stamps of the
;; shared DAG IDs (restored from the undo log on close). `small` keeps the
;; same outer walk with nothing to stamp inside the frame.
(define (walk-context-source [copyable : bool] [small : bool]) : String
  (str_cat.str-cat
    "(defstruct S (f "
    (if small
      "i64"
      (walk-source-dag 7 0))
    ") (n i64)"
    (if copyable
      ")"
      " (b (Box i64)))")
    "\n(define (twice [x : (Tuple (Tuple "
    (walk-source-dag 7 0)
    " "
    (walk-source-dag 4 1)
    "))]) : i64 (let [p x] [q x] 0))\n(define (main) : i64 0)\n"))

;; One check of `source` with the serial job bound around it (so its table
;; survives the check): the verdict must be `want`; returns the serials the
;; check issued.
(define (walk-check-run [source : String] [want : bool]) : i64
  (let
    [serial : tc.TcJobState (tc.tc-serial-job-state)]
    [outer : tc.TcTypeWalkBinding (tc.tc-type-walk-bind! serial)]
    [ok : bool
      (match (check_core.compiler-check-source "tests/walk_context.tl" source)
        [(Ok _ _) true]
        [(Err _ _) false])]
    [issued : i64 (walk-table-serial)]
    (tc.tc-type-walk-restore! outer)
    (tc.tc-type-walk-table-release! serial)
    (walk-expect "walk check verdict" (= ok want))
    (walk-expect "walk check left walk words open" (walk-words-idle?))
    issued))

(define (walk-context-run [copyable : bool] [small : bool]) : i64
  (walk-check-run (walk-context-source copyable small) copyable))

;; A depth-8 DAG of `T` values (each holds an `S` holding a reference to a
;; local), clear, under an arena owner (gated), or escaping its scope: struct
;; frames for holds-reference and move-kind, arena tagging and erasure, and
;; loan checks all walk 256 shared leaves under one root.
(define (walk-lifetime-chain [depth : i64]) : String
  (if (= depth 0)
    "[local : i64 0] [x0 (T (S (& local)))]"
    (str_cat.str-cat
      (walk-lifetime-chain (- depth 1))
      " [x"
      (string.int->string depth)
      " (tuple x"
      (string.int->string (- depth 1))
      " x"
      (string.int->string (- depth 1))
      ")]")))

(define (walk-lifetime-source [kind : i64]) : String
  (str_cat.str-cat
    "(import stdlib.arena)\n(defstruct S (:lifetimes r) (value (& r i64)))\n(defstruct T (:lifetimes r) (value (S r)))\n(define (probe) : i64 (let "
    (if (= kind 0)
      (walk-lifetime-chain 8)
      (if (= kind 1)
        (str_cat.str-cat "[owner (arena.make)] " (walk-lifetime-chain 8))
        (str_cat.str-cat
          "[owner (arena.make)] [keep (let "
          (walk-lifetime-chain 8)
          " x8)]")))
    " 0))\n(define (main) : i64 0)\n"))

;; Clear and gated pass, escape fails (E0205 on main), stamping on and off.
(define (walk-lifetime-test) : unit
  (walk-expect
    "clear stamps"
    (>= (walk-check-run (walk-lifetime-source 0) true) 1))
  (walk-expect
    "gated stamps"
    (>= (walk-check-run (walk-lifetime-source 1) true) 1))
  (walk-expect
    "escape stamps"
    (>= (walk-check-run (walk-lifetime-source 2) false) 1))
  (tc.tc-walk-serial-limit-set! 1)
  (walk-expect
    "clear plain"
    (= (walk-check-run (walk-lifetime-source 0) true) 0))
  (walk-expect
    "gated plain"
    (= (walk-check-run (walk-lifetime-source 1) true) 0))
  (walk-expect
    "escape plain"
    (= (walk-check-run (walk-lifetime-source 2) false) 0))
  (tc.tc-walk-serial-limit-set! 1152921504606846976))

;; Copyable / move-only / copyable in turn. With stamping on, the big field
;; issues more serials than the small one in the same outer walk: the extra
;; ones open inside S's frame while the outer serial is open. With stamping
;; off (limit 1) none are issued. Verdicts match either way and never carry
;; across checks (each check releases its table).
(define (walk-context-test) : unit
  (let
    [a-big : i64 (walk-context-run true false)]
    [a-small : i64 (walk-context-run true true)]
    [b-big : i64 (walk-context-run false false)]
    [b-small : i64 (walk-context-run false true)]
    [a-again : i64 (walk-context-run true false)]
    (walk-expect "A stamps" (>= a-small 1))
    (walk-expect "A frame opens a nested serial" (> a-big a-small))
    (walk-expect "B frame opens a nested serial" (> b-big b-small))
    (walk-expect "A again issues the same serials" (= a-again a-big)))
  (tc.tc-walk-serial-limit-set! 1)
  (walk-expect "A plain" (= (walk-context-run true false) 0))
  (walk-expect "B plain" (= (walk-context-run false false) 0))
  (walk-expect "A plain again" (= (walk-context-run true false) 0))
  (tc.tc-walk-serial-limit-set! 1152921504606846976))

;; Arena erasure: `take` brands `r` through its owner parameter, and its
;; parameter type is one root, `(Tuple (Tuple D L))`, whose last leaf L is
;; `(in r i64)` (tagged) or `i64` (plain) after the 255-visit DAG D. Calls
;; erase the signature's arena regions: the tagged root walks the tag and
;; rebuilds the type (stamped erasure), the plain one returns unchanged.
(define (walk-arena-source [tagged : bool]) : String
  (str_cat.str-cat
    "(import stdlib.arena)\n(define (take [_owner : (& a (arena.Arena r))] [_x : "
    (walk-arena-source-root tagged)
    "]) : i64 2)\n(define (pass [owner : (& a (arena.Arena r))] [x : "
    (walk-arena-source-root tagged)
    "]) : i64 (take owner x))\n(define (main) : i64 0)\n"))

(define (walk-arena-source-root [tagged : bool]) : String
  (str_cat.str-cat
    "(Tuple (Tuple "
    (walk-source-dag 7 0)
    (if tagged
      " (in r i64)))"
      " i64))")))

(define (walk-arena-test) : unit
  (let
    [tagged : i64 (walk-check-run (walk-arena-source true) true)]
    [plain : i64 (walk-check-run (walk-arena-source false) true)]
    (walk-expect "arena erasure stamps" (> tagged plain)))
  (tc.tc-walk-serial-limit-set! 1)
  (walk-expect
    "arena tagged plain"
    (= (walk-check-run (walk-arena-source true) true) 0))
  (walk-expect
    "arena untagged plain"
    (= (walk-check-run (walk-arena-source false) true) 0))
  (tc.tc-walk-serial-limit-set! 1152921504606846976))

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
      (walk-boundary-test 1)
      (walk-dag-test 40)
      (walk-expect "words idle after walks" (walk-words-idle?))
      ;; Forced serial wrap and exhaustion: limit 4 wraps whenever no serial
      ;; is open and nested walks past it run unstamped; limit 1 never
      ;; stamps. Both stay exact (small DAGs: unstamped walks unfold).
      (tc.tc-walk-serial-limit-set! 4)
      (walk-boundary-test -1)
      (walk-dag-test 12)
      (tc.tc-walk-serial-limit-set! 1)
      (walk-boundary-test 0)
      (walk-dag-test 12)
      (tc.tc-walk-serial-limit-set! 1152921504606846976)
      (walk-expect "words idle after wrap" (walk-words-idle?))
      ;; REPL requests and a failing check, under the test job's binding.
      (ast.ast-node-pool-context-install! installed)
      (walk-repl-test job)
      (walk-failing-check-test job)
      (walk-context-test)
      (walk-lifetime-test)
      (walk-arena-test)
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
      (walk-boundary-test 0)
      (walk-expect "words idle at the end" (walk-words-idle?))
      (ast.ast-node-pool-context-install! installed))))

(test walk-stamps-controls (walk-stamps-self-test))

(define (main) : i64
  (cfg test (walk-stamps-self-test))
  42)