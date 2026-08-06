;; Test-only proof-reuse exact/walker unit scaffolding moved out of production typechecker.
(import compiler_typecheck_core as tc_core)
(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import compiler_symbols as csym)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.string)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)

(define (compiler-typecheck-proof-reuse-source-missing? [text : String]) : bool
  (match (ci.intern-lookup text)
    [(InternLookupMissing) true]
    [_ false]))

(define (compiler-typecheck-proof-reuse-identity-count [identity : String]) : i64
  (let
    [slot : i64 (tc_core.slot-id (tc_core.lookup-key-id identity))]
    (if (and
      (>= slot 0)
      (< slot tc_core.store-capacity)
      (> (array-ref tc_core.identity-bytes slot) 0))
      (let
        [count : i64 (array-ref tc_core.operand-count slot)]
        (if (and (>= count 0) (<= count tc_core.expected-count))
          count
          -1))
      -1)))

(define (compiler-typecheck-proof-reuse-family-first-identity-id
  [generator : String]
  [item : String]) : i64
  (let
    [slot : i64 (tc_core.slot-index generator item)]
    (if (and
      (>= slot 0)
      (< slot tc_core.additional-capacity)
      (> (array-ref tc_core.storage-identity-vars slot) 0))
      (- (array-ref tc_core.storage-identity-vars slot) 1)
      -1)))

(define (compiler-typecheck-proof-reuse-owned-metadata-ok?
  [generator : String]
  [item : String]
  [identity : String]
  [identity-id : i64]
  [type-key : String]
  [kind : String]) : bool
  (let
    [family-first-id : i64
      (compiler-typecheck-proof-reuse-family-first-identity-id generator item)]
    [identity-slot : i64 (tc_core.slot-id (tc_core.lookup-key-id identity))]
    [identity-count : i64
      (compiler-typecheck-proof-reuse-identity-count identity)]
    (and
      (= family-first-id identity-id)
      (= identity-count 1)
      (string.eq (tc_core.type-key-id identity-slot 0) type-key)
      (string.eq (tc_core.kind-for-check identity-slot 0) kind)
      (compiler-typecheck-proof-reuse-source-missing? generator)
      (compiler-typecheck-proof-reuse-source-missing? item)
      (compiler-typecheck-proof-reuse-source-missing? type-key)
      (compiler-typecheck-proof-reuse-source-missing? kind))))

(define (compiler-typecheck-proof-reuse-state-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (tc_core.tc-macro-abstract-proof-reset!)
      (tc_core.scratch-reset-functions)
      (if (and
        (= tc_core.first-slot -1)
        (= tc_core.next-slots -1)
        (= tc_core.local-ordinal 0)
        (not tc_core.local-shadow-updated?)
        (not tc_core.portable-pair)
        (not tc_core.local-use)
        (not tc_core.fixed-call)
        (not tc_core.allow-cleanup)
        (not tc_core.checked-context))
        unit
        (set! ok false))
      (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
        (tc_core.lookup-key-id "tc-self-missing-identity")
        (tc_core.lookup-key-id "tc-self-missing-identity"))
        (set! ok false)
        unit)
      (if (and
        tc_core.active-invalid
        (= tc_core.first-slot -1)
        (= tc_core.next-slots -1))
        unit
        (set! ok false))
      (tc_core.scratch-reset-functions)
      ;; Complete-generator proofs are textual program facts, not intern-table
      ;; facts.  They must survive a compatibility-table install, while the
      ;; normal reset still removes the proof and restores the home table for
      ;; later unit cases.
      (let
        [home-state : ci.InternCompatState
          (ci.intern-compat-state-capture-active)]
        [fresh-state : ci.InternCompatState (ci.intern-compat-state-new)]
        [cross-table-proof : String "tc-self-cross-table-proof"]
        (begin
          (tc_core.reset-result)
          (tc_core.record-count cross-table-proof)
          (if (tc_core.complete-key cross-table-proof)
            unit
            (set! ok false))
          (if (=
            (ci.intern-compat-state-table-id home-state)
            (ci.intern-compat-state-table-id fresh-state))
            (set! ok false)
            unit)
          (ci.intern-compat-state-install! fresh-state)
          (if (tc_core.complete-key cross-table-proof)
            unit
            (set! ok false))
          (match (ci.intern-lookup cross-table-proof)
            [(InternLookupMissing) unit]
            [(InternLookupFound _) (set! ok false)])
          (ci.intern-compat-state-install! home-state)
          (tc_core.reset-result)
          (if (tc_core.complete-key cross-table-proof)
            (set! ok false)
            unit)))
      (tc_core.record-count "tc-self-complete")
      (if (tc_core.complete-key "tc-self-complete")
        unit
        (set! ok false))
      (if (tc_core.complete-key "tc-self-missing")
        (set! ok false)
        unit)
      (tc_core.record-count "tc-self-complete")
      (if (= tc_core.required-count 1)
        unit
        (set! ok false))
      (tc_core.reset-result)
      (if (tc_core.complete-key "tc-self-complete")
        (set! ok false)
        unit)
      (tc_core.scratch-reset)
      (let
        [index : i64 0]
        (while (< index 20)
          (begin
            (tc_core.record-slot
              "tc-self-generator"
              (str_cat.str-cat "tc-self-item-" (string.int->string index))
              (str_cat.str-cat "tc-self-identity-" (string.int->string index))
              (ast.ast-decl-fallback))
            (set! index (+ index 1))))
        unit)
      (tc_core.record-slot
        "tc-self-generator"
        "tc-self-item-0"
        "tc-self-identity-replacement"
        (ast.ast-decl-fallback))
      (if (let
        [family-slot : i64
          (tc_core.slot-index "tc-self-generator" "tc-self-item-0")]
        (and
          (>= family-slot 0)
          (< family-slot tc_core.additional-capacity)
          (> (array-ref tc_core.storage-identity-vars family-slot) 0)))
        unit
        (set! ok false))
      (match (ci.intern-generated-canonical-lookup "tc-self-identity-0")
        [(InternLookupFound original-id)
          (if (let
            [family-slot : i64
              (tc_core.slot-index "tc-self-generator" "tc-self-item-0")]
            (and
              (>= family-slot 0)
              (< family-slot tc_core.additional-capacity)
              (> (array-ref tc_core.storage-identity-vars family-slot) 0)
              (=
                (- (array-ref tc_core.storage-identity-vars family-slot) 1)
                original-id)))
            unit
            (set! ok false))]
        [(InternLookupMissing) (set! ok false)])
      (tc_core.record-slot
        "tc-self-first-wins-generator"
        "tc-self-first-wins-item"
        "tc-self-first-wins-identity"
        (ast.AstDecl.Module (ci.intern "tc-self-first-wins-module")))
      (tc_core.record-slot
        "tc-self-first-wins-generator"
        "tc-self-first-wins-item"
        "tc-self-first-wins-replacement"
        (ast.AstDecl.Module (ci.intern "tc-self-first-wins-replacement-module")))
      (if (let
        [family-slot : i64
          (tc_core.slot-index
            "tc-self-first-wins-generator"
            "tc-self-first-wins-item")]
        (and
          (>= family-slot 0)
          (< family-slot tc_core.additional-capacity)
          (> (array-ref tc_core.storage-identity-vars family-slot) 0)
          (=
            (- (array-ref tc_core.storage-identity-vars family-slot) 1)
            (tc_core.tc-generated-module-name-id "tc-self-first-wins-identity"))))
        unit
        (set! ok false))
      (let
        [family-slot : i64
          (tc_core.slot-index
            "tc-self-first-wins-generator"
            "tc-self-first-wins-item")]
        (if (and (>= family-slot 0) (< family-slot tc_core.additional-capacity))
          (match (array-ref (tc_core.augmented-decls-shared-view) family-slot)
            [(ast.AstDecl.Module module-id)
              (if (= module-id (ci.intern "tc-self-first-wins-module"))
                unit
                (set! ok false))]
            [_ (set! ok false)])
          (set! ok false)))
      (let
        [index : i64 0]
        (while (< index 20)
          (if (let
            [family-slot : i64
              (tc_core.slot-index
                "tc-self-generator"
                (str_cat.str-cat "tc-self-item-" (string.int->string index)))]
            (not
              (and
                (>= family-slot 0)
                (< family-slot tc_core.additional-capacity)
                (> (array-ref tc_core.storage-identity-vars family-slot) 0))))
            (set! ok false)
            unit)
          (set! index (+ index 1)))
        unit)
      (tc_core.record-count "tc-self-complete-identities")
      (tc_core.scratch-reset-context)
      (tc_core.scratch-plan-result "type-a" "i64")
      (tc_core.scratch-plan-result "type-b" "slice")
      (tc_core.identity-remap "tc-self-identity-a")
      (tc_core.scratch-reset-context)
      (tc_core.scratch-plan-result "type-c" "struct")
      (tc_core.identity-remap "tc-self-identity-b")
      (if (=
        (compiler-typecheck-proof-reuse-identity-count "tc-self-identity-a")
        2)
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-identity-count "tc-self-identity-b")
        1)
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.kind-for-check
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-identity-b"))
          0)
        "struct")
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.kind-for-check
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-identity-a"))
          1)
        "slice")
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.type-key-id
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-identity-a"))
          0)
        "type-a")
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-identity-count "tc-self-identity-a")
        2)
        unit
        (set! ok false))
      (if (not
        (=
          (string.string-length
            (tc_core.kind-for-check
              (tc_core.slot-id (tc_core.lookup-key-id "tc-self-identity-a"))
              2))
          0))
        (set! ok false)
        unit)
      (tc_core.scratch-reset-context)
      (let
        [index : i64 0]
        (while (< index 17)
          (begin
            (tc_core.scratch-plan-result
              (str_cat.str-cat "overflow-type-" (string.int->string index))
              "i64")
            (set! index (+ index 1))))
        unit)
      (tc_core.identity-remap "tc-self-identity-overflow")
      (if (=
        (compiler-typecheck-proof-reuse-identity-count
          "tc-self-identity-overflow")
        -1)
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-identity-count "tc-self-absent")
        -1)
        unit
        (set! ok false))
      (tc_core.tc-macro-abstract-proof-reset!)
      (if (=
        (compiler-typecheck-proof-reuse-identity-count "tc-self-identity-a")
        -1)
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-family-first-identity-id
          "tc-self-generator"
          "tc-self-item-0")
        -1)
        unit
        (set! ok false))
      (tc_core.tc-macro-abstract-proof-reset!)
      ;; Proof-only family and operand text must stay in the owned key arena:
      ;; recording/querying these novel strings cannot grow or populate the
      ;; source interner.  Canonicalize only the generated identity before the
      ;; source-pool mark; its id lives in the generated lane.
      (let
        [owned-generator : String "tc-self-owned-family-generator-novel"]
        [owned-item : String "tc-self-owned-family-item-novel"]
        [owned-identity : String "tc-self-owned-identity-novel"]
        [owned-type-key : String "tc-self-owned-type-key-novel"]
        [owned-kind : String "tc-self-owned-kind-novel"]
        [owned-identity-id : i64
          (tc_core.tc-generated-module-name-id owned-identity)]
        [source-mark : i64 (ci.intern-pool-len)]
        (begin
          (tc_core.record-slot
            owned-generator
            owned-item
            owned-identity
            (ast.ast-decl-fallback))
          (tc_core.scratch-reset-context)
          (tc_core.scratch-plan-result owned-type-key owned-kind)
          (tc_core.identity-remap owned-identity)
          (if (= source-mark (ci.intern-pool-len))
            unit
            (set! ok false))
          (if (compiler-typecheck-proof-reuse-owned-metadata-ok?
            owned-generator
            owned-item
            owned-identity
            owned-identity-id
            owned-type-key
            owned-kind)
            unit
            (set! ok false))
          (tc_core.macro-expand-scratch-clear-owned-caches!)
          (if (= source-mark (ci.intern-pool-len))
            unit
            (set! ok false))
          (if (compiler-typecheck-proof-reuse-owned-metadata-ok?
            owned-generator
            owned-item
            owned-identity
            owned-identity-id
            owned-type-key
            owned-kind)
            unit
            (set! ok false))
          (tc_core.compiler-typecheck-clear-macro-expanded-source-caches!)
          (if (= source-mark (ci.intern-pool-len))
            unit
            (set! ok false))
          (if (compiler-typecheck-proof-reuse-owned-metadata-ok?
            owned-generator
            owned-item
            owned-identity
            owned-identity-id
            owned-type-key
            owned-kind)
            unit
            (set! ok false))))
      ;; Intra-program cache/arena cleanup must not discard proof-reuse state
      ;; captured during expansion.  Seed every bounded table, clear each
      ;; cleanup boundary, and query the exact values after both calls.
      (tc_core.record-count "tc-self-lifecycle-complete")
      (tc_core.tc-macro-abstract-proof-note!
        "tc-self-lifecycle-proof"
        "tc-self-lifecycle-param"
        37)
      (tc_core.scratch-reset-context)
      (tc_core.scratch-plan-result
        "tc-self-lifecycle-type"
        "tc-self-lifecycle-kind")
      (tc_core.identity-remap "tc-self-lifecycle-identity")
      (tc_core.scratch-reset-context)
      (tc_core.record-slot
        "tc-self-lifecycle-generator"
        "tc-self-lifecycle-item"
        "tc-self-lifecycle-identity"
        (ast.AstDecl.Module (ci.intern "tc-self-lifecycle-module")))
      (tc_core.macro-expand-scratch-clear-owned-caches!)
      (if (tc_core.complete-key "tc-self-lifecycle-complete")
        unit
        (set! ok false))
      (if (=
        (tc_core.tc-macro-abstract-proof-lookup
          "tc-self-lifecycle-proof"
          "tc-self-lifecycle-param")
        37)
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-identity-count
          "tc-self-lifecycle-identity")
        1)
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.type-key-id
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-lifecycle-identity"))
          0)
        "tc-self-lifecycle-type")
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.kind-for-check
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-lifecycle-identity"))
          0)
        "tc-self-lifecycle-kind")
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-family-first-identity-id
          "tc-self-lifecycle-generator"
          "tc-self-lifecycle-item")
        (tc_core.tc-generated-module-name-id "tc-self-lifecycle-identity"))
        unit
        (set! ok false))
      (let
        [family-slot : i64
          (tc_core.slot-index
            "tc-self-lifecycle-generator"
            "tc-self-lifecycle-item")]
        (if (and (>= family-slot 0) (< family-slot tc_core.additional-capacity))
          (match (array-ref (tc_core.augmented-decls-shared-view) family-slot)
            [(ast.AstDecl.Module module-id)
              (if (= module-id (ci.intern "tc-self-lifecycle-module"))
                unit
                (set! ok false))]
            [_ (set! ok false)])
          (set! ok false)))
      (tc_core.compiler-typecheck-clear-macro-expanded-source-caches!)
      (if (tc_core.complete-key "tc-self-lifecycle-complete")
        unit
        (set! ok false))
      (if (=
        (tc_core.tc-macro-abstract-proof-lookup
          "tc-self-lifecycle-proof"
          "tc-self-lifecycle-param")
        37)
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-identity-count
          "tc-self-lifecycle-identity")
        1)
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.type-key-id
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-lifecycle-identity"))
          0)
        "tc-self-lifecycle-type")
        unit
        (set! ok false))
      (if (string.eq
        (tc_core.kind-for-check
          (tc_core.slot-id (tc_core.lookup-key-id "tc-self-lifecycle-identity"))
          0)
        "tc-self-lifecycle-kind")
        unit
        (set! ok false))
      (if (=
        (compiler-typecheck-proof-reuse-family-first-identity-id
          "tc-self-lifecycle-generator"
          "tc-self-lifecycle-item")
        (tc_core.tc-generated-module-name-id "tc-self-lifecycle-identity"))
        unit
        (set! ok false))
      (let
        [family-slot : i64
          (tc_core.slot-index
            "tc-self-lifecycle-generator"
            "tc-self-lifecycle-item")]
        (if (and (>= family-slot 0) (< family-slot tc_core.additional-capacity))
          (match (array-ref (tc_core.augmented-decls-shared-view) family-slot)
            [(ast.AstDecl.Module module-id)
              (if (= module-id (ci.intern "tc-self-lifecycle-module"))
                unit
                (set! ok false))]
            [_ (set! ok false)])
          (set! ok false)))
      (tc_core.tc-macro-abstract-proof-reset!)
      ok)))

(define (compiler-typecheck-generated-exact-primitives-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      ;; Seed one ordered identity pair through the packet-1 scratch/note API.
      ;; The note calls are the only writes to the bounded metadata table.
      (tc_core.tc-macro-abstract-proof-reset!)
      (tc_core.scratch-reset-context)
      (tc_core.scratch-plan-result "i64" "i64")
      (tc_core.identity-remap "tc-exact-first")
      (tc_core.scratch-reset-context)
      (tc_core.scratch-plan-result "u8" "u8")
      (tc_core.identity-remap "tc-exact-next")
      (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
        (tc_core.lookup-key-id "tc-exact-first")
        (tc_core.lookup-key-id "tc-exact-next"))
        unit
        (set! ok false))
      (let
        [first-id : i64 (tc_core.lookup-key-id "tc-exact-first")]
        [next-id : i64 (tc_core.lookup-key-id "tc-exact-next")]
        [same-name-id : i64 (ci.intern "tc-exact-same-name")]
        [different-name-a-id : i64 (ci.intern "tc-exact-name-a")]
        [different-name-b-id : i64 (ci.intern "tc-exact-name-b")]
        [base-id : i64 (ci.intern "tc-exact-common-base")]
        [wrong-base-id : i64 (ci.intern "tc-exact-wrong-base")]
        [third-module-id : i64
          (ci.intern-generated-canonical-name "tc-exact-third-module")]
        [first-qualified-id : i64
          (ci.intern-generated-canonical-qualified-name
            "tc-exact-first/tc-exact-common-base"
            first-id
            base-id)]
        [next-qualified-id : i64
          (ci.intern-generated-canonical-qualified-name
            "tc-exact-next/tc-exact-common-base"
            next-id
            base-id)]
        [wrong-base-qualified-id : i64
          (ci.intern-generated-canonical-qualified-name
            "tc-exact-next/tc-exact-wrong-base"
            next-id
            wrong-base-id)]
        [third-qualified-id : i64
          (ci.intern-generated-canonical-qualified-name
            "tc-exact-third-module/tc-exact-common-base"
            third-module-id
            base-id)]
        (begin
          ;; Referenced names are stricter than declaration names.  Equal
          ;; references pass without recording a substitution; bare or
          ;; qualified first/next identity names fail closed.
          (tc_core.scratch-reset-functions)
          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
            (tc_core.lookup-key-id "tc-exact-first")
            (tc_core.lookup-key-id "tc-exact-next"))
            unit
            (set! ok false))
          (if (tc_core.qualified-name same-name-id same-name-id)
            unit
            (set! ok false))
          (if (tc_core.qualified-name first-id next-id)
            (set! ok false)
            unit)
          (if (tc_core.qualified-name first-qualified-id next-qualified-id)
            (set! ok false)
            unit)
          (if tc_core.portable-pair
            (set! ok false)
            unit)
          ;; Equal source names pass; arbitrary source renames do not.
          (if (tc_core.exact-name same-name-id same-name-id)
            unit
            (set! ok false))
          (if (tc_core.exact-name different-name-a-id different-name-b-id)
            (set! ok false)
            unit)
          ;; Only the exact generated module substitution is allowed.  The
          ;; qualified spelling additionally requires one shared base id.
          (if (tc_core.exact-name first-id next-id)
            unit
            (set! ok false))
          (if (tc_core.exact-name first-qualified-id next-qualified-id)
            unit
            (set! ok false))
          (if (tc_core.exact-name first-qualified-id wrong-base-qualified-id)
            (set! ok false)
            unit)
          (if (tc_core.exact-name first-qualified-id third-qualified-id)
            (set! ok false)
            unit)
          ;; Reuse the parser/symbol/registry context harness used by the
          ;; generated-declaration scan tests for pooled child-node reads.
          (match (parser.parse-ast-source "(define (main) : i64 0)")
            [(parser.ResultAstProgram.Ok program)
              (match (csym.build-compiler-symbols program)
                [(csym.ResultCompilerSymbols.Ok symbols)
                  (match (csym.build-compiler-registries program)
                    [(csym.ResultCompilerRegistries.Ok registries)
                      (let
                        [ctx : tc_core.TcContext
                          (tc_core.tc-context-new
                            program
                            symbols
                            registries
                            ""
                            cbi.compiler-builtin-id-fix-empty
                            (ast.ast-node-pool-context-capture-active))]
                        [pools : ast.AstNodePoolContext
                          (tc_core.tc-context-pools ctx)]
                        [dyn-i64 : ast.AstType
                          (ast.ast-ty-dyn-array-with-pools
                            pools
                            (ast.AstType.I64))]
                        [dyn-u8 : ast.AstType
                          (ast.ast-ty-dyn-array-with-pools
                            pools
                            (ast.AstType.U8))]
                        [helper-base-id : i64 (ci.intern "tc-exact-helper")]
                        [first-helper-id : i64
                          (ci.intern-generated-canonical-qualified-name
                            "tc-exact-first/tc-exact-helper"
                            first-id
                            helper-base-id)]
                        [next-helper-id : i64
                          (ci.intern-generated-canonical-qualified-name
                            "tc-exact-next/tc-exact-helper"
                            next-id
                            helper-base-id)]
                        [first-body-id : i64
                          (ast.ast-node-pool-context-expr-push
                            pools
                            (ast.AstExpr.Var first-helper-id))]
                        [next-body-id : i64
                          (ast.ast-node-pool-context-expr-push
                            pools
                            (ast.AstExpr.Var next-helper-id))]
                        [first-reference-decl : ast.AstDecl
                          (ast.ast-decl-def-id
                            first-qualified-id
                            ast.AstMaybeType.No
                            first-body-id)]
                        [next-reference-decl : ast.AstDecl
                          (ast.ast-decl-def-id
                            next-qualified-id
                            ast.AstMaybeType.No
                            next-body-id)]
                        (begin
                          ;; The declaration names themselves may carry the
                          ;; generated identity substitution, but a body
                          ;; reference to first/helper -> next/helper is
                          ;; outside this declaration's proof boundary.
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-exact-first")
                            (tc_core.lookup-key-id "tc-exact-next"))
                            (if (tc_core.tc-proof-reuse-session-ast-decl-exact?
                              ctx
                              first-reference-decl
                              next-reference-decl)
                              (set! ok false)
                              unit)
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (if (= (bit-and tc_core.active-mask 1) 1)
                            unit
                            (set! ok false))
                          (if tc_core.portable-pair
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            dyn-i64
                            dyn-u8)
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.Bool))
                            (set! ok false)
                            unit)
                          ;; A canonical-key-equal pair is exact and does not
                          ;; consume an operand bit.
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-exact-first")
                            (tc_core.lookup-key-id "tc-exact-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.I64))
                            unit
                            (set! ok false))
                          (if (= tc_core.active-mask 0)
                            unit
                            (set! ok false))
                          ;; A conflicting second note poisons the row;
                          ;; preflight and both exact primitives fail closed.
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "bool" "bool")
                          (tc_core.identity-remap "tc-exact-first")
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-exact-first")
                            (tc_core.lookup-key-id "tc-exact-next"))
                            (set! ok false)
                            unit)
                          (if (tc_core.exact-name first-id first-id)
                            (set! ok false)
                            unit)
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.I64))
                            (set! ok false)
                            unit)
                          ;; Packet-2A2 rule-4 facts and guards use a fresh metadata pair so
                          ;; the conflicting-row assertion above remains independent.
                          (tc_core.scratch-reset-functions)
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "i64" "i64")
                          (tc_core.identity-remap "tc-rule4-first")
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "u8" "u8")
                          (tc_core.identity-remap "tc-rule4-next")
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          ;; Exact 255 fits the changed u8 target; a 300 fact fails closed.
                          (if (tc_core.tc-proof-reuse-session-ast-literal-exact?
                            (ast.AstLiteral.Int 255 "255")
                            (ast.AstLiteral.Int 255 "255"))
                            unit
                            (set! ok false))
                          (if (tc_core.invalid-keeps-first)
                            unit
                            (set! ok false))
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-literal-exact?
                            (ast.AstLiteral.Int 300 "300")
                            (ast.AstLiteral.Int 300 "300"))
                            unit
                            (set! ok false))
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          ;; Distinct integer spelling with the same parsed value is not an
                          ;; exact literal pair.
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-literal-exact?
                            (ast.AstLiteral.Int 255 "255")
                            (ast.AstLiteral.Int 255 "0xff"))
                            (set! ok false)
                            unit)
                          ;; Integer facts cannot be silently retargeted to a non-integer
                          ;; operand kind.
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "i64" "i64")
                          (tc_core.identity-remap "tc-rule4-int-first")
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "bool" "bool")
                          (tc_core.identity-remap "tc-rule4-int-next")
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-int-first")
                            (tc_core.lookup-key-id "tc-rule4-int-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.Bool))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-literal-exact?
                            (ast.AstLiteral.Int 1 "")
                            (ast.AstLiteral.Int 1 ""))
                            unit
                            (set! ok false))
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          ;; Each semantic note independently rejects the same changed pair.
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-expr-exact?
                            ctx
                            (ast.AstExpr.Binary (ast.AstBinOp.Add) -1 -1)
                            (ast.AstExpr.Binary (ast.AstBinOp.Add) -1 -1))
                            unit
                            unit)
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-expr-exact?
                            ctx
                            (ast.AstExpr.Binary (ast.AstBinOp.Shl) -1 -1)
                            (ast.AstExpr.Binary (ast.AstBinOp.Shl) -1 -1))
                            unit
                            unit)
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-expr-exact?
                            ctx
                            (ast.AstExpr.Binary (ast.AstBinOp.Eq) -1 -1)
                            (ast.AstExpr.Binary (ast.AstBinOp.Eq) -1 -1))
                            unit
                            unit)
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (tc_core.recorded-maybe-ty)
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          ;; Floats and owning composites are rejected independently of notes.
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "f64" "f64")
                          (tc_core.identity-remap "tc-rule4-float-first")
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "f32" "f32")
                          (tc_core.identity-remap "tc-rule4-float-next")
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-float-first")
                            (tc_core.lookup-key-id "tc-rule4-float-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.F64)
                            (ast.AstType.F32))
                            unit
                            (set! ok false))
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "String" "string")
                          (tc_core.identity-remap "tc-rule4-string-first")
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "bool" "bool")
                          (tc_core.identity-remap "tc-rule4-string-next")
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-string-first")
                            (tc_core.lookup-key-id "tc-rule4-string-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.String)
                            (ast.AstType.Bool))
                            unit
                            (set! ok false))
                          (if (tc_core.invalid-keeps-first)
                            (set! ok false)
                            unit)
                          ;; A distinct identity pair with an unchanged key has no used bit;
                          ;; semantic notes alone do not reject that row.
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "i64" "i64")
                          (tc_core.identity-remap "tc-rule4-same-first")
                          (tc_core.scratch-reset-context)
                          (tc_core.scratch-plan-result "i64" "i64")
                          (tc_core.identity-remap "tc-rule4-same-next")
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-same-first")
                            (tc_core.lookup-key-id "tc-rule4-same-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.I64))
                            unit
                            (set! ok false))
                          (if (= tc_core.active-mask 0)
                            unit
                            (set! ok false))
                          (tc_core.recorded-maybe-ty)
                          (if (tc_core.invalid-keeps-first)
                            unit
                            (set! ok false))
                          ;; Capacity+1 identical facts poison the session and fail closed.
                          (tc_core.scratch-reset-functions)
                          (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                            (tc_core.lookup-key-id "tc-rule4-first")
                            (tc_core.lookup-key-id "tc-rule4-next"))
                            unit
                            (set! ok false))
                          (if (tc_core.tc-proof-reuse-session-ast-type-exact?
                            ctx
                            (ast.AstType.I64)
                            (ast.AstType.U8))
                            unit
                            (set! ok false))
                          (let
                            [overflow-index : i64 0]
                            (begin
                              (while (< overflow-index 129)
                                (begin
                                  (tc_core.tc-proof-reuse-session-ast-literal-exact?
                                    (ast.AstLiteral.Int 1 "")
                                    (ast.AstLiteral.Int 1 ""))
                                  (set! overflow-index (+ overflow-index 1))))
                              (if (tc_core.invalid-keeps-first)
                                (set! ok false)
                                unit)))
                          unit))]
                    [(csym.ResultCompilerRegistries.Err _) (set! ok false)])]
                [(csym.ResultCompilerSymbols.Err _) (set! ok false)])]
            [(parser.ResultAstProgram.Err _) (set! ok false)])
          unit))
      (tc_core.scratch-reset-functions)
      (tc_core.scratch-reset-result)
      (tc_core.tc-macro-abstract-proof-reset!)
      ok)))

;; Focused packet-2B harness.  Each source contains two module bodies so both
;; declarations and all pooled child nodes come from one parser pool.  The
;; explicit bounds checks are intentional: a malformed index must not reach
;; the AstDecl fallback and accidentally look like an exact pair.
(define (compiler-typecheck-generated-walker-seed!
  [first-key : String]
  [first-kind : String]
  [next-key : String]
  [next-kind : String]) : unit
  (begin
    (tc_core.tc-macro-abstract-proof-reset!)
    (tc_core.scratch-reset-context)
    (tc_core.scratch-plan-result first-key first-kind)
    (tc_core.identity-remap "tc-walker-first")
    (tc_core.scratch-reset-context)
    (tc_core.scratch-plan-result next-key next-kind)
    (tc_core.identity-remap "tc-walker-next")))

(define (compiler-typecheck-generated-walker-pair?
  [src : String]
  [first-module-index : i64]
  [next-module-index : i64]
  [first-body-index : i64]
  [next-body-index : i64]
  [first-key : String]
  [first-kind : String]
  [next-key : String]
  [next-kind : String]
  [want-exact : bool]
  [want-safe : bool]) : bool
  (begin
    (compiler-typecheck-generated-walker-seed!
      first-key
      first-kind
      next-key
      next-kind)
    (let
      [answer : bool
        (match (parser.parse-ast-source src)
          [(parser.ResultAstProgram.Ok program)
            (match (csym.build-compiler-symbols program)
              [(csym.ResultCompilerSymbols.Ok symbols)
                (match (csym.build-compiler-registries program)
                  [(csym.ResultCompilerRegistries.Ok registries)
                    (match program
                      [(ast.AstProgram.Program decls-box)
                        (let
                          [decls : ast.AstDeclList (box-get decls-box)]
                          [decl-count : i64 (ast.ast-decl-list-len (& decls))]
                          (if (or
                            (< first-module-index 0)
                            (< next-module-index 0)
                            (>= first-module-index decl-count)
                            (>= next-module-index decl-count))
                            false
                            (match (ast.ast-decl-list-get
                              (& decls)
                              first-module-index
                              (ast.ast-decl-fallback))
                              [(ast.AstDecl.ModuleBody _ first-body-box)
                                (match (ast.ast-decl-list-get
                                  (& decls)
                                  next-module-index
                                  (ast.ast-decl-fallback))
                                  [(ast.AstDecl.ModuleBody _ next-body-box)
                                    (let
                                      [first-body : ast.AstDeclList
                                        (box-get first-body-box)]
                                      [next-body : ast.AstDeclList
                                        (box-get next-body-box)]
                                      [first-count : i64
                                        (ast.ast-decl-list-len (& first-body))]
                                      [next-count : i64
                                        (ast.ast-decl-list-len (& next-body))]
                                      (if (or
                                        (< first-body-index 0)
                                        (< next-body-index 0)
                                        (>= first-body-index first-count)
                                        (>= next-body-index next-count))
                                        false
                                        (let
                                          [first-decl : ast.AstDecl
                                            (ast.ast-decl-list-get
                                              (& first-body)
                                              first-body-index
                                              (ast.ast-decl-fallback))]
                                          [next-decl : ast.AstDecl
                                            (ast.ast-decl-list-get
                                              (& next-body)
                                              next-body-index
                                              (ast.ast-decl-fallback))]
                                          [ctx : tc_core.TcContext
                                            (tc_core.tc-context-new
                                              program
                                              symbols
                                              registries
                                              ""
                                              cbi.compiler-builtin-id-fix-empty
                                              (ast.ast-node-pool-context-capture-active))]
                                          [exact-ok : bool
                                            (begin
                                              (tc_core.scratch-reset-functions)
                                              (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                                                (tc_core.lookup-key-id
                                                  "tc-walker-first")
                                                (tc_core.lookup-key-id
                                                  "tc-walker-next"))
                                                (tc_core.tc-proof-reuse-session-ast-decl-exact?
                                                  ctx
                                                  first-decl
                                                  next-decl)
                                                false))]
                                          [safe-ok : bool
                                            (tc_core.tc-proof-reuse-decl-safe-substitution-ids?
                                              ctx
                                              (tc_core.lookup-key-id
                                                "tc-walker-first")
                                              (tc_core.lookup-key-id
                                                "tc-walker-next")
                                              first-decl
                                              next-decl)]
                                          (begin
                                            (tc_core.scratch-reset-functions)
                                            (and
                                              (if want-exact
                                                exact-ok
                                                (not exact-ok))
                                              (if want-safe
                                                safe-ok
                                                (not safe-ok)))))))]
                                  [_ false])]
                              [_ false])))]
                      [_ false])]
                  [(csym.ResultCompilerRegistries.Err _) false])]
              [(csym.ResultCompilerSymbols.Err _) false])]
          [(parser.ResultAstProgram.Err _) false])]
      (begin
        (stdlib.io.print-bool answer)
        (tc_core.scratch-reset-functions)
        (tc_core.scratch-reset-result)
        (tc_core.tc-macro-abstract-proof-reset!)
        answer))))

(define (compiler-typecheck-generated-context-walker-pair?
  [src : String]
  [first-module-index : i64]
  [next-module-index : i64]
  [first-body-index : i64]
  [next-body-index : i64]
  [first-key : String]
  [first-kind : String]
  [next-key : String]
  [next-kind : String]
  [want-exact : bool]
  [want-safe : bool]
  [want-context : bool]) : bool
  (begin
    ;; This focused helper intentionally stops after the exact walk so tests
    ;; can observe the context-sensitive scalar before Rule 4 is evaluated.
    (compiler-typecheck-generated-walker-seed!
      first-key
      first-kind
      next-key
      next-kind)
    (let
      [answer : bool
        (match (parser.parse-ast-source src)
          [(parser.ResultAstProgram.Ok program)
            (match (csym.build-compiler-symbols program)
              [(csym.ResultCompilerSymbols.Ok symbols)
                (match (csym.build-compiler-registries program)
                  [(csym.ResultCompilerRegistries.Ok registries)
                    (match program
                      [(ast.AstProgram.Program decls-box)
                        (let
                          [decls : ast.AstDeclList (box-get decls-box)]
                          [decl-count : i64 (ast.ast-decl-list-len (& decls))]
                          (if (or
                            (< first-module-index 0)
                            (< next-module-index 0)
                            (>= first-module-index decl-count)
                            (>= next-module-index decl-count))
                            false
                            (match (ast.ast-decl-list-get
                              (& decls)
                              first-module-index
                              (ast.ast-decl-fallback))
                              [(ast.AstDecl.ModuleBody _ first-body-box)
                                (match (ast.ast-decl-list-get
                                  (& decls)
                                  next-module-index
                                  (ast.ast-decl-fallback))
                                  [(ast.AstDecl.ModuleBody _ next-body-box)
                                    (let
                                      [first-body : ast.AstDeclList
                                        (box-get first-body-box)]
                                      [next-body : ast.AstDeclList
                                        (box-get next-body-box)]
                                      [first-count : i64
                                        (ast.ast-decl-list-len (& first-body))]
                                      [next-count : i64
                                        (ast.ast-decl-list-len (& next-body))]
                                      (if (or
                                        (< first-body-index 0)
                                        (< next-body-index 0)
                                        (>= first-body-index first-count)
                                        (>= next-body-index next-count))
                                        false
                                        (let
                                          [first-decl : ast.AstDecl
                                            (ast.ast-decl-list-get
                                              (& first-body)
                                              first-body-index
                                              (ast.ast-decl-fallback))]
                                          [next-decl : ast.AstDecl
                                            (ast.ast-decl-list-get
                                              (& next-body)
                                              next-body-index
                                              (ast.ast-decl-fallback))]
                                          [ctx : tc_core.TcContext
                                            (tc_core.tc-context-new
                                              program
                                              symbols
                                              registries
                                              ""
                                              cbi.compiler-builtin-id-fix-empty
                                              (ast.ast-node-pool-context-capture-active))]
                                          [exact-ok : bool
                                            (begin
                                              (tc_core.scratch-reset-functions)
                                              (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                                                (tc_core.lookup-key-id
                                                  "tc-walker-first")
                                                (tc_core.lookup-key-id
                                                  "tc-walker-next"))
                                                (tc_core.tc-proof-reuse-session-ast-decl-exact?
                                                  ctx
                                                  first-decl
                                                  next-decl)
                                                false))]
                                          [context-ok : bool
                                            (=
                                              tc_core.checked-context
                                              want-context)]
                                          [safe-ok : bool
                                            (tc_core.invalid-keeps-first)]
                                          (begin
                                            (stdlib.io.print-bool exact-ok)
                                            (stdlib.io.print-bool safe-ok)
                                            (stdlib.io.print-bool context-ok)
                                            (and
                                              (= exact-ok want-exact)
                                              (= safe-ok want-safe)
                                              context-ok)))))]
                                  [_ false])]
                              [_ false])))]
                      [_ false])]
                  [(csym.ResultCompilerRegistries.Err _) false])]
              [(csym.ResultCompilerSymbols.Err _) false])]
          [(parser.ResultAstProgram.Err _) false])]
      (begin
        (stdlib.io.print-bool answer)
        (tc_core.scratch-reset-functions)
        (tc_core.scratch-reset-result)
        (tc_core.tc-macro-abstract-proof-reset!)
        answer))))

(define (compiler-typecheck-generated-walker-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      ;; DefStruct: DynArray's element type substitutes while the invariant
      ;; i64 field and all declaration/field names remain exact.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (defstruct Vec (slots (__tl_dyn-array i64)) (invariant i64)))
(module tc-walker-next
  (defstruct Vec (slots (__tl_dyn-array u8)) (invariant i64)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        true)
        unit
        (set! ok false))
      ;; Fixed-size arrays are dependent even when their shapes compare equal;
      ;; the exact type fast path must veto the i64 -> u8 substitution.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (defstruct Vec (slots (Array i64 4)) (invariant i64)))
(module tc-walker-next
  (defstruct Vec (slots (Array u8 4)) (invariant i64)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; DefFn: a nominal type nested in the reference parameter is outside
      ;; the audited type surface, so the declaration fails closed.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (defstruct Vec (slots (& caller (__tl_dyn-array i64))))
  (define (slots [v : (& caller Vec)]) : (& caller (__tl_dyn-array i64))
    (struct-get (& v) slots)))
(module tc-walker-next
  (defstruct Vec (slots (& caller (__tl_dyn-array u8))))
  (define (slots [v : (& caller Vec)]) : (& caller (__tl_dyn-array u8))
    (struct-get (& v) slots)))"
        0
        1
        1
        1
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; Local declaration, parameter and field renames are never an
      ;; established identity substitution.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (defstruct Vec (slot i64)))
(module tc-walker-next
  (defstruct Renamed (slot u8)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (same [x : i64]) : i64 (+ x 1)))
(module tc-walker-next
  (define (same [y : u8]) : u8 (+ y 1)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; A lexical parameter pass-through remains safe under i64 -> u8: the
      ;; equal Var is paired with the active parameter, not treated as fixed.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (identity [x : i64]) : i64 x))
(module tc-walker-next
  (define (identity [x : u8]) : u8 x))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        true)
        unit
        (set! ok false))
      ;; Let bindings are outside the audited expression surface and therefore
      ;; fall through to concrete checking.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (fixed-local-annotation [x : i64]) : i64
    (let [y : i64 x] y)))
(module tc-walker-next
  (define (fixed-local-annotation [x : u8]) : u8
    (let [y : i64 x] y)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; A fixed return boundary beside a substituted parameter is likewise
      ;; concrete-only, even though the body remains a local pass-through.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (fixed-return [x : i64]) : i64 x))
(module tc-walker-next
  (define (fixed-return [x : u8]) : i64 x))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      ;; If expressions are outside the audited expression surface and fail
      ;; closed even when their source shape is otherwise unchanged.
      (if (compiler-typecheck-generated-context-walker-pair?
        "(module tc-walker-first
  (define (condition [x : bool]) : bool (if x x x)))
(module tc-walker-next
  (define (condition [x : u8]) : u8 (if x x x)))"
        0
        1
        0
        0
        "bool"
        "bool"
        "u8"
        "u8"
        false
        true
        false)
        unit
        (set! ok false))
      ;; StructGet's field result is selected by the receiver's hidden nominal
      ;; type, so a fixed field beside a substituted payload needs checking.
      (if (compiler-typecheck-generated-context-walker-pair?
        "(module tc-walker-first
  (defstruct Box (fixed i64) (payload i64))
  (define (field [value : Box]) : i64 (struct-get value fixed)))
(module tc-walker-next
  (defstruct Box (fixed i64) (payload u8))
  (define (field [value : Box]) : u8 (struct-get value fixed)))"
        0
        1
        1
        1
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false
        true)
        unit
        (set! ok false))
      ;; Constructor calls carry fixed field expectations that are not visible
      ;; in the call AST itself.
      (if (compiler-typecheck-generated-context-walker-pair?
        "(module tc-walker-first
  (defstruct Box (fixed i64) (payload i64))
  (define (construct [x : i64]) : Box (Box x x)))
(module tc-walker-next
  (defstruct Box (fixed i64) (payload u8))
  (define (construct [x : u8]) : Box (Box x x)))"
        0
        1
        1
        1
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false
        true)
        unit
        (set! ok false))
      ;; Inferred Let/Begin/Set forms are outside the audited expression
      ;; surface and fail closed.
      (if (compiler-typecheck-generated-context-walker-pair?
        "(module tc-walker-first
  (define (inferred [x : i64]) : i64
    (let [y 0]
      (begin
        (set! y x)
        x))))
(module tc-walker-next
  (define (inferred [x : u8]) : u8
    (let [y 0]
      (begin
        (set! y x)
        x))))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        true
        false)
        unit
        (set! ok false))
      ;; ArrayRef is outside the audited expression surface and fails closed.
      (if (compiler-typecheck-generated-context-walker-pair?
        "(module tc-walker-first
  (define (array-ref-index [xs : (__tl_dyn-array i64)] [index : i64]) : i64
    (array-ref xs index)))
(module tc-walker-next
  (define (array-ref-index [xs : (__tl_dyn-array u8)] [index : u8]) : u8
    (array-ref xs index)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        true
        false)
        unit
        (set! ok false))
      ;; Fixed top-level values and callees are structurally exact but cannot
      ;; be reused when another declaration's type substituted around them.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define fixed-i64 : i64 42)
  (define (fixed-as-t [x : i64]) : i64 fixed-i64))
(module tc-walker-next
  (define fixed-i64 : i64 42)
  (define (fixed-as-t [x : u8]) : u8 fixed-i64))"
        0
        1
        1
        1
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (only-i64 [x : i64]) : i64 x)
  (define (call-only-i64 [x : i64]) : i64 (only-i64 x)))
(module tc-walker-next
  (define (only-i64 [x : i64]) : i64 x)
  (define (call-only-i64 [x : u8]) : u8 (only-i64 x)))"
        0
        1
        1
        1
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (defstruct Vec (slot i64)))
(module tc-walker-next
  (defstruct Vec (other u8)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; Constructor/body changes reject even when the declarations otherwise
      ;; carry the same substitution metadata.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (shape [x : i64]) : i64 (+ x 1)))
(module tc-walker-next
  (define (shape [x : u8]) : u8 x))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; Literal narrowing is structurally exact, but Rule 4 rejects a value
      ;; outside the next u8 range.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (literal [x : i64]) : i64 (+ x 300)))
(module tc-walker-next
  (define (literal [x : u8]) : u8 (+ x 300)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      ;; Binary arithmetic records the operator fact; changed operand kinds
      ;; then fail Rule 4.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (arith [x : i64]) : i64 (+ x x)))
(module tc-walker-next
  (define (arith [x : bool]) : bool (+ x x)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "bool"
        "bool"
        true
        false)
        unit
        (set! ok false))
      ;; Eq/Ne and clone are structurally exact but conservative equality/clone
      ;; facts make a changed operand concrete.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (equals [x : i64]) : bool (= x x)))
(module tc-walker-next
  (define (equals [x : u8]) : bool (= x x)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (not-equals [x : i64]) : bool (!= x x)))
(module tc-walker-next
  (define (not-equals [x : u8]) : bool (!= x x)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (clone-value [x : i64]) : i64 (clone x)))
(module tc-walker-next
  (define (clone-value [x : u8]) : u8 (clone x)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        true
        false)
        unit
        (set! ok false))
      ;; Reflection and casts are concrete-only forms.  TypeLiteral is
      ;; unsupported by the compact walk and records no reflection fact.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (reflect [x : i64]) : i64 (type i64)))
(module tc-walker-next
  (define (reflect [x : u8]) : u8 (type u8)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (casted [x : i64]) : i64 (cast x : i64)))
(module tc-walker-next
  (define (casted [x : u8]) : u8 (cast x : u8)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; Unsupported declaration and expression forms fail closed.
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first (import dep))
(module tc-walker-next (import dep))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-walker-pair?
        "(module tc-walker-first
  (define (unsupported [x : i64]) : i64 (while x x)))
(module tc-walker-next
  (define (unsupported [x : u8]) : u8 (while x x)))"
        0
        1
        0
        0
        "i64"
        "i64"
        "u8"
        "u8"
        false
        false)
        unit
        (set! ok false))
      ;; The focused body walk treats TypeLiteral as unsupported and records no
      ;; reflection fact.
      (tc_core.tc-macro-abstract-proof-reset!)
      (match (parser.parse-ast-source
        "(module tc-walker-first
  (define (reflect [x : i64]) : i64 (type i64)))
(module tc-walker-next
  (define (reflect [x : u8]) : u8 (type u8)))")
        [(parser.ResultAstProgram.Ok program)
          (match (csym.build-compiler-symbols program)
            [(csym.ResultCompilerSymbols.Ok symbols)
              (match (csym.build-compiler-registries program)
                [(csym.ResultCompilerRegistries.Ok registries)
                  (match program
                    [(ast.AstProgram.Program decls-box)
                      (let
                        [decls : ast.AstDeclList (box-get decls-box)]
                        [first-module : ast.AstDecl
                          (ast.ast-decl-list-get
                            (& decls)
                            0
                            (ast.ast-decl-fallback))]
                        [next-module : ast.AstDecl
                          (ast.ast-decl-list-get
                            (& decls)
                            1
                            (ast.ast-decl-fallback))]
                        (match first-module
                          [(ast.AstDecl.ModuleBody _ first-box)
                            (match next-module
                              [(ast.AstDecl.ModuleBody _ next-box)
                                (let
                                  [first-body : ast.AstDeclList
                                    (box-get first-box)]
                                  [next-body : ast.AstDeclList
                                    (box-get next-box)]
                                  [first-decl : ast.AstDecl
                                    (ast.ast-decl-list-get
                                      (& first-body)
                                      0
                                      (ast.ast-decl-fallback))]
                                  [next-decl : ast.AstDecl
                                    (ast.ast-decl-list-get
                                      (& next-body)
                                      0
                                      (ast.ast-decl-fallback))]
                                  [ctx : tc_core.TcContext
                                    (tc_core.tc-context-new
                                      program
                                      symbols
                                      registries
                                      ""
                                      cbi.compiler-builtin-id-fix-empty
                                      (ast.ast-node-pool-context-capture-active))]
                                  (begin
                                    (compiler-typecheck-generated-walker-seed!
                                      "i64"
                                      "i64"
                                      "u8"
                                      "u8")
                                    (tc_core.scratch-reset-functions)
                                    (if (tc_core.tc-proof-reuse-session-identity-preflight-ids?
                                      (tc_core.lookup-key-id "tc-walker-first")
                                      (tc_core.lookup-key-id "tc-walker-next"))
                                      unit
                                      (set! ok false))
                                    (if (tc_core.tc-proof-reuse-session-ast-decl-exact?
                                      ctx
                                      first-decl
                                      next-decl)
                                      (set! ok false)
                                      unit)
                                    (if tc_core.reflection-env
                                      (set! ok false)
                                      unit)
                                    ;; Missing metadata is a hard preflight
                                    ;; failure, even when the declarations are
                                    ;; otherwise well-shaped.
                                    (tc_core.tc-macro-abstract-proof-reset!)
                                    (if (tc_core.tc-proof-reuse-decl-safe-substitution-ids?
                                      ctx
                                      (tc_core.lookup-key-id
                                        "tc-walker-missing")
                                      (tc_core.lookup-key-id "tc-walker-next")
                                      first-decl
                                      next-decl)
                                      (set! ok false)
                                      unit)
                                    ;; A conflicting second note poisons the
                                    ;; bounded identity row; the combined
                                    ;; entry must remain concrete.
                                    (compiler-typecheck-generated-walker-seed!
                                      "i64"
                                      "i64"
                                      "u8"
                                      "u8")
                                    (tc_core.scratch-reset-context)
                                    (tc_core.scratch-plan-result "bool" "bool")
                                    (tc_core.identity-remap "tc-walker-first")
                                    (if (tc_core.tc-proof-reuse-decl-safe-substitution-ids?
                                      ctx
                                      (tc_core.lookup-key-id "tc-walker-first")
                                      (tc_core.lookup-key-id "tc-walker-next")
                                      first-decl
                                      next-decl)
                                      (set! ok false)
                                      unit)))]
                              [_ (set! ok false)])]
                          [_ (set! ok false)]))]
                    [_ (set! ok false)])]
                [(csym.ResultCompilerRegistries.Err _) (set! ok false)])]
            [(csym.ResultCompilerSymbols.Err _) (set! ok false)])]
        [(parser.ResultAstProgram.Err _) (set! ok false)])
      (tc_core.scratch-reset-functions)
      (if (and
        (= tc_core.local-ordinal 0)
        (not tc_core.local-shadow-updated?)
        (not tc_core.portable-pair)
        (not tc_core.local-use)
        (not tc_core.fixed-call)
        (not tc_core.allow-cleanup)
        (not tc_core.checked-context))
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-proof-reuse-unit-tests-ok?) : bool
  (and
    (compiler-typecheck-proof-reuse-state-tests-ok?)
    (compiler-typecheck-generated-exact-primitives-tests-ok?)
    (compiler-typecheck-generated-walker-tests-ok?)))