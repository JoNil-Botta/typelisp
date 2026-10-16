;; compiler_clone_tests.tl - White-box tests for the clone name sets and
;; root-entry tables and late stdlib helper syntax.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_intern as ci)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as clone_id_map)
(import stdlib.string)
(import compiler_clone as clone_support)
(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import compiler_ctfe as ctfe)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.test)
(cfg test (import compiler_optimize as opt))
(cfg test (import stdlib.arena))

(define (clone-root-entries-empty) : clone_support.CloneRootEntries
  Empty)

(define (clone-root-entries-capacity [roots : clone_support.CloneRootEntries]) : i64
  (match roots
    [(Empty) 0]
    [(Dense address _ _)
      (let
        [store : clone_support.CloneRootEntryStore
          (clone_support.clone-root-entries-store-read address)]
        (array-length store.entries))]))

(define (clone-root-entries-physical-len
  [roots : clone_support.CloneRootEntries]) : i64
  (match roots
    [(Empty) 0]
    [(Dense address _ _)
      (let
        [store : clone_support.CloneRootEntryStore
          (clone_support.clone-root-entries-store-read address)]
        store.len)]))

(define (clone-name-set-smoke-insert-count
  [names : clone_support.CloneNameSet]
  [count : i64]) : clone_support.CloneNameSet
  (if (<= count 0)
    names
    (clone-name-set-smoke-insert-count
      (clone_support.clone-name-set-insert-id names (+ count 10))
      (- count 1))))

(define (clone-name-set-smoke-ok?) : bool
  (let
    [empty : clone_support.CloneNameSet (clone_support.clone-name-set-empty)]
    [one : clone_support.CloneNameSet
      (clone_support.clone-name-set-insert-id empty 1)]
    [dupe : clone_support.CloneNameSet
      (clone_support.clone-name-set-insert-id (clone one) 1)]
    [seed-capacity : i64 (clone_support.clone-name-set-capacity dupe)]
    [grown : clone_support.CloneNameSet
      (clone-name-set-smoke-insert-count (clone dupe) 10)]
    [base-id : i64 (ci.intern "CloneSmokeKey")]
    [first-key : i64
      (clone_support.clone-name-pair-key-id
        (ci.intern "clone.smoke.first")
        base-id)]
    [second-key : i64
      (clone_support.clone-name-pair-key-id
        (ci.intern "clone.smoke.second")
        base-id)]
    [unique : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id
        (clone-root-entries-empty)
        first-key)]
    [ambiguous : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id unique second-key)]
    (and
      (not (clone_support.clone-name-set-contains-id? one 2))
      (clone_support.clone-name-set-contains-id? one 1)
      (= (clone_support.clone-name-set-len dupe) 1)
      (= (clone_support.clone-name-set-len grown) 11)
      (=
        (clone_support.clone-root-entries-unique-key-for-base-id-or
          unique
          base-id
          -1)
        first-key)
      (=
        (clone_support.clone-root-entries-unique-key-for-base-id-or
          ambiguous
          base-id
          -1)
        -1)
      (clone_support.clone-module-alias-import-kind? Module)
      (clone_support.clone-module-alias-import-kind? (Macro 0 No))
      (clone_support.clone-module-alias-import-kind? (MacroDecls 0 No))
      (not (clone_support.clone-module-alias-import-kind? ModuleAll))
      (not (clone_support.clone-module-alias-import-kind? (ModuleItem 0)))
      (> (clone_support.clone-name-set-capacity grown) seed-capacity))))

(define (clone-root-entries-smoke-key-id [index : i64]) : i64
  (ci.intern (str_cat.str-cat "CloneDenseSmokeRoot" (string.int->string index))))

(define (clone-root-entries-smoke-add-sequential
  [roots : clone_support.CloneRootEntries]
  [start : i64]
  [end : i64]) : clone_support.CloneRootEntries
  (let
    [out : clone_support.CloneRootEntries roots]
    [index : i64 start]
    (while (< index end)
      (set!
        out
        (clone_support.clone-root-entries-add-id
          out
          (clone-root-entries-smoke-key-id index)))
      (set! index (+ index 1)))
    out))

(define (clone-root-entries-smoke-order-ok?
  [roots : clone_support.CloneRootEntries]) : bool
  (let
    [index : i64 0]
    [count : i64 (clone_support.clone-root-entries-len roots)]
    [ok : bool true]
    (while (and (< index count) ok)
      (if (not
        (=
          (clone_support.clone-root-entries-key-id-at-or roots index -1)
          (clone-root-entries-smoke-key-id (- count (+ index 1)))))
        (set! ok false)
        unit)
      (set! index (+ index 1)))
    ok))

(define (clone-root-entries-smoke-copy-equal?
  [left : clone_support.CloneRootEntries]
  [right : clone_support.CloneRootEntries]) : bool
  (let
    [index : i64 0]
    [count : i64 (clone_support.clone-root-entries-len left)]
    [ok : bool (= count (clone_support.clone-root-entries-len right))]
    (while (and (< index count) ok)
      (if (and
        (=
          (clone_support.clone-root-entries-key-id-at-or left index -1)
          (clone_support.clone-root-entries-key-id-at-or right index -1))
        (=
          (clone_support.clone-root-entries-helper-id-at-or left index -1)
          (clone_support.clone-root-entries-helper-id-at-or right index -1)))
        unit
        (set! ok false))
      (set! index (+ index 1)))
    ok))

(define (clone-root-entries-smoke-ok?) : bool
  (let
    [empty : clone_support.CloneRootEntries (clone-root-entries-empty)]
    [first-key : i64 (clone-root-entries-smoke-key-id 0)]
    [grown-key : i64 (ci.intern "CloneDenseSmokeGrown")]
    [branch-key : i64 (ci.intern "CloneDenseSmokeBranch")]
    [first : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id empty first-key)]
    [duplicate : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id first first-key)]
    [roots : clone_support.CloneRootEntries
      (clone-root-entries-smoke-add-sequential first 1 24)]
    [prefix : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-take roots 3)]
    [first-helper : i64
      (clone_support.clone-root-entries-helper-id-or first first-key -1)]
    [prefix-helper : i64
      (clone_support.clone-root-entries-helper-id-at-or prefix 0 -1)]
    [grown : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id roots grown-key)]
    [branch : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id prefix branch-key)]
    [copy : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-copy branch)]
    [base-id : i64 (ci.intern "CloneDenseSmokeKey")]
    [first-qualified : i64
      (clone_support.clone-name-pair-key-id
        (ci.intern "clone.dense.first")
        base-id)]
    [second-qualified : i64
      (clone_support.clone-name-pair-key-id
        (ci.intern "clone.dense.second")
        base-id)]
    [unique-base : i64 (ci.intern "CloneDenseUniqueKey")]
    [unique-qualified : i64
      (clone_support.clone-name-pair-key-id
        (ci.intern "clone.dense.unique")
        unique-base)]
    [qualified : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id
        (clone_support.clone-root-entries-add-id empty first-qualified)
        second-qualified)]
    [_materialize-qualified : unit
      (clone_support.clone-root-entries-materialize-helper-names! qualified)]
    [unique-root : clone_support.CloneRootEntries
      (clone_support.clone-root-entries-add-id empty unique-qualified)]
    (and
      ;; Empty is allocation-free and duplicate insertion is idempotent.
      (clone_support.clone-root-entries-empty? empty)
      (= (clone-root-entries-physical-len empty) 0)
      (= (clone-root-entries-capacity empty) 0)
      (= (clone_support.clone-root-entries-len duplicate) 1)
      (=
        (clone_support.clone-root-entries-helper-id-or duplicate first-key -1)
        first-helper)
      ;; 24 entries cross three geometric growth boundaries and remain ordered.
      (= (clone_support.clone-root-entries-len roots) 24)
      (clone-root-entries-smoke-order-ok? roots)
      ;; The one-entry snapshot remains unchanged after 4->8->16->32 growth,
      ;; while its shared physical store and map observe later entries.
      (= (clone_support.clone-root-entries-len first) 1)
      (= (clone_support.clone-root-entries-key-id-at-or first 0 -1) first-key)
      (=
        (clone_support.clone-root-entries-helper-id-or first first-key -1)
        first-helper)
      (not (clone_support.clone-root-entries-contains-id? first grown-key))
      (= (clone_support.clone-root-entries-helper-id-or first grown-key -1) -1)
      (= (clone-root-entries-physical-len first) 25)
      (>= (clone-root-entries-capacity first) 25)
      (= (clone_support.clone-root-entries-len roots) 24)
      (= (clone-root-entries-physical-len roots) 25)
      (>= (clone-root-entries-capacity roots) 25)
      (< (clone-root-entries-capacity roots) 50)
      ;; A recent slice remains separate from the divergent COW branch.
      (= (clone_support.clone-root-entries-len prefix) 3)
      (=
        (clone_support.clone-root-entries-helper-id-at-or prefix 0 -1)
        prefix-helper)
      (=
        (clone_support.clone-root-entries-key-id-at-or prefix 0 -1)
        (clone-root-entries-smoke-key-id 23))
      (not (clone_support.clone-root-entries-contains-id? prefix grown-key))
      (= (clone_support.clone-root-entries-helper-id-or prefix grown-key -1) -1)
      (= (clone_support.clone-root-entries-key-id-at-or grown 0 -1) grown-key)
      (= (clone_support.clone-root-entries-len grown) 25)
      ;; Divergent append materializes the stale prefix, leaving the original
      ;; descendant untouched.
      (= (clone_support.clone-root-entries-len branch) 4)
      (= (clone-root-entries-physical-len branch) 4)
      (>= (clone-root-entries-capacity branch) 4)
      (< (clone-root-entries-capacity branch) 8)
      (= (clone_support.clone-root-entries-key-id-at-or branch 0 -1) branch-key)
      (=
        (clone_support.clone-root-entries-key-id-at-or roots 0 -1)
        (clone-root-entries-smoke-key-id 23))
      (= (clone_support.clone-root-entries-len copy) 4)
      (= (clone-root-entries-physical-len copy) 4)
      (>= (clone-root-entries-capacity copy) 4)
      (< (clone-root-entries-capacity copy) 8)
      (clone-root-entries-smoke-copy-equal? branch copy)
      (=
        (clone_support.clone-root-entries-len
          (clone_support.clone-root-entries-take roots 5))
        5)
      (=
        (clone_support.clone-root-entries-len
          (clone_support.clone-root-entries-drop roots 5))
        19)
      (=
        (clone_support.clone-root-entries-key-id-at-or
          (clone_support.clone-root-entries-drop roots 5)
          0
          -1)
        (clone-root-entries-smoke-key-id 18))
      ;; Qualified keys with one base stay ambiguous; a unique base resolves.
      (=
        (clone_support.clone-root-entries-unique-key-for-base-id-or
          qualified
          base-id
          -1)
        -1)
      (=
        (clone_support.clone-root-entries-unique-key-for-base-id-or
          unique-root
          unique-base
          -1)
        unique-qualified))))

;; Inspect the producer's real template without adding a boxed-list schema to
;; repository fixtures. Only let bindings are special; children use the schema.
(define (clone-test-tail-template-id
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]) : i64
  (let
    [expr : ast.AstExpr (ast.ast-node-pool-context-expr-get pools id)]
    (match (& expr)
      [(Let payload)
        (match (& (deref payload))
          [(Let bindings _)
            (for [index (iterator.range 0 bindings.len)]
              (match (ast.ast-let-binding-list-get
                bindings
                index
                (ast.ast-let-binding-fallback))
                [(Binding name _ init)
                  (when
                    (string.eq (ci.intern-str name) "next-tail")
                    (return init))]))])]
      [_ unit])
    (let
      [children : ast.AstExprList (ast.ast-expr-child-ids expr)]
      (for [index (iterator.range 0 children.len)]
        (let
          [found : i64
            (clone-test-tail-template-id
              pools
              (ast.ast-expr-list-get (& children) index -1))]
          (when (>= found 0) (return found)))))
    -1))

(define (clone-test-tail-operation?
  [pools : (& pools ast.AstNodePoolContext)]
  [id : i64]
  [boxed-self : bool]) : bool
  (match (ast.ast-node-pool-context-expr-get pools id)
    [(Spanned inner _) (clone-test-tail-operation? pools inner boxed-self)]
    [(or (BoxGet inner) (BoxTake inner))
      (and boxed-self (clone-test-tail-operation? pools inner false))]
    [(Var name) (and (not boxed-self) (string.eq (ci.intern-str name) "tail"))]
    [_ false]))

(define (clone-test-evaluate-tail?
  [pools : ast.AstNodePoolContext]
  [id : i64]
  [boxed-self : bool]) : bool
  (let
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        (ctfe.ctfe-env-empty-with-pools pools)
        (ci.intern "boxed-self")
        (& (ctfe.CompilerCtfeValue.Bool boxed-self)))]
    [expr : ast.AstExpr (ast.ast-node-pool-context-expr-get (& pools) id)]
    (match (ctfe.compiler-ctfe-eval (& expr) env (ctfe.ctfe-fuel-limit))
      [(Ok value _)
        (match value
          [(Expr node _) (clone-test-tail-operation? (& pools) node boxed-self)]
          [(CapturedExpr node _ produced)
            (clone-test-tail-operation? (& produced) node boxed-self)]
          [_ false])]
      [(Err _) false])))

(define (compiler-clone-late-tail-template-ok?) : bool
  (let
    [source : String (byte_buf.to-string (io.read-file "stdlib/clone.tl"))]
    (match (parser.parse-ast-source (& source))
      [(Ok program)
        (let
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-capture-active)]
          (match program
            [(Program declarations)
              (let
                [decls : ast.AstDeclList (deref declarations)]
                (for [index (iterator.range 0 decls.len)]
                  (match (ast.ast-decl-list-get
                    (& decls)
                    index
                    (ast.ast-decl-fallback))
                    [(DefMacro _ name _ _ body)
                      (when
                        (string.eq (ci.intern-str name) "synthesize-helpers")
                        (let
                          [tail : i64
                            (clone-test-tail-template-id (& pools) body)]
                          (return
                            (and
                              (>= tail 0)
                              (clone-test-evaluate-tail? pools tail true)
                              (clone-test-evaluate-tail? pools tail false)))))]
                    [_ unit]))
                false)]))]
      [(Err _) false])))

(test
  compiler-clone-late-tail-template
  (test.assert-true
    (compiler-clone-late-tail-template-ok?)
    "late boxed and direct clone tails contain ordinary syntax"))

(cfg
  test
  (define (clone-test-production-tail-valid?
    [value : (& value opt.OptNonnegPhis)]
    [count : i64]) : bool
    (match value
      [(Nil) (= count 0)]
      [(Cons head tail)
        (and
          (= head (- count 1))
          (clone-test-production-tail-valid? tail (- count 1)))])))

;; Reuse the optimizer's existing boxed-tail type rather than introducing a
;; list schema into the fixture corpus. The clone crosses a real arena boundary.
(test
  compiler-clone-boxed-production-tail
  (let
    [home : arena.Arena (arena.current)]
    (for [case-index (iterator.range 0 3)]
      (let
        [count : i64
          (cond [(= case-index 0) 0] [(= case-index 1) 1] [else 30000])]
        [scratch : arena.Arena (arena.make)]
        (unsafe
          (arena.set! scratch))
        (let
          [source : opt.OptNonnegPhis (opt.OptNonnegPhis.Nil)]
          (for [index (iterator.range 0 count)]
            (set! source (opt.OptNonnegPhis.Cons index (box source))))
          (unsafe
            (arena.set! home))
          (let
            [copied : opt.OptNonnegPhis (clone source)]
            (test.assert-true
              (clone-test-production-tail-valid? (& source) count)
              "cloning preserves every source element")
            (unsafe
              (arena.destroy scratch))
            (test.assert-true
              (clone-test-production-tail-valid? (& copied) count)
              "the clone retains every element after source retirement")))))
    (let
      [source : opt.OptNonnegPhis
        (opt.OptNonnegPhis.Cons
          7
          (box (opt.OptNonnegPhis.Cons 8 (box (opt.OptNonnegPhis.Nil)))))]
      [copied : opt.OptNonnegPhis (clone source)]
      (match copied
        [(Cons head tail)
          (test.assert-i64-eq head 7 "clone keeps the head")
          (set! (deref tail) (opt.OptNonnegPhis.Nil))
          (test.assert-true
            (opt.opt-nonneg-phis-member? (& source) 8)
            "mutating the clone leaves the source tail intact")]
        [_ (test.assert-true false "clone keeps the nonempty variant")]))))