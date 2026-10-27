;; compiler_tlci_native_producer_tests.tl - the producer's `run-ops` batching:
;; which op lines become batch tokens and how the status chain renders a run
;; of them. The host side of the batch format is covered by
;; src/tests/comptime_host_smoke.tl, and the gates that compile every stdlib
;; macro through both routes cover the end-to-end expansions. Refs #8274.
(import stdlib.iterator)
(import compiler_tlci_native_producer as producer)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.test)
(import tlci_core)
(import lex)

(define (producer-source-failure-sentinel!) : unit
  (let
    [context : producer.TlciNativeSourceContext
      (producer.tlci-native-source-context-new
        (ast.ast-node-pool-context-new-with-capacities 1 1)
        (ci.intern-compat-state-new))]
    [patterns : ast.AstPatternList (ast.ast-pattern-list-new)]
    (ast.ast-pattern-list-push (&mut patterns) (Wildcard))
    (ast.ast-pattern-list-push
      (&mut patterns)
      (Tuple (box (ast.ast-pattern-list-new))))
    (let
      [failure : String
        (producer.embedded-native-value-match-bind (& context) (& patterns) 1 0)]
      (test.assert-true
        (> (string.string-length failure) 0)
        "failure is not empty success")
      (test.assert-true
        (not (lex.is-symbol-char (string.string-ref failure 0)))
        "failure sentinel cannot be a source symbol")
      (test.assert-owned-string-eq
        (producer.embedded-native-value-match-bind (& context) (& patterns) 0 0)
        failure
        "unsupported tail propagates the sentinel")
      (test.assert-owned-string-eq
        (producer.embedded-native-value-match-bind (& context) (& patterns) 2 0)
        ""
        "completed binding chain is empty success"))))

(test
  native-source-unspellable-failure-sentinel
  (producer-source-failure-sentinel!))

;; Parse real macro input and exercise the complete source producer, including
;; native-entry accounting and its registration-shell fallback. Refs #9341.
(define (producer-pattern-source! [pattern : String] [expected-native : i64]) : unit
  (let
    [source : String
      (str_cat.str-cat
        "(defmacro (probe [value : Expr]) : Expr (match value ["
        pattern
        " `(+ 1 2)] [_ `(+ 3 4)]))")]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [parse-state : parser.CompilerParseState
      (parser.compiler-parse-state-new-with-intern-state
        (ci.intern-compat-state-capture-active))]
    (match (parser.parse-ast-source-with-cfg-and-pools
      (& source)
      (parser.compiler-parse-state-cfgs
        (& parse-state)
        (parser.compiler-cfg-empty))
      pools)
      [(Err message) (io.panic message)]
      [(Ok (Program declarations))
        (match (ast.ast-decl-list-step (deref declarations))
          [(Cons (DefMacro _ _ params _ body) _)
            (let
              [context : producer.TlciNativeSourceContext
                (producer.tlci-native-source-context-new
                  (ast.ast-node-pool-context-capture-active)
                  (parser.compiler-parse-state-owner
                    (parser.compiler-parse-state-control-addr (& parse-state))))]
              [names : (__tl_dyn-array String) (__tl_make-array "probe/probe")]
              [captures : producer.TlciNativeMacroCaptures
                (producer.tlci-native-macro-captures-new)]
              [_capture : unit
                (producer.tlci-native-macro-captures-push!
                  (&mut captures)
                  (producer.TlciNativeMacroCapture "probe/probe" params 0 body))]
              [generated : String
                (producer.embedded-native-source
                  (& context)
                  (& names)
                  (& captures))]
              (test.assert-i64-eq
                (array-ref producer.embedded-stdlib-tlci-native-report-count 0)
                expected-native
                "unsupported patterns must not count as native entries")
              (test.assert-i64-eq
                (occurrences (& generated) "$tlci-unsupported")
                0
                "the failure sentinel must not reach generated source")
              (test.assert-i64-eq
                (occurrences
                  (&
                    (array-ref
                      producer.embedded-stdlib-tlci-native-report-reasons
                      0))
                  "probe/probe\t")
                (- 1 expected-native)
                "only unsupported patterns report a registration shell")
              (test.assert-i64-eq
                (array-ref producer.embedded-native-local-len 0)
                0
                "failed and successful arm binding scopes are restored"))]
          [_ (io.panic "pattern fixture must contain a macro")])]
      [_ (io.panic "pattern fixture must contain a program")])))

(define (producer-pattern-fallback!) : unit
  (producer-pattern-source! "(comptime.Expr.Call (comptime.Expr.Var f) args)" 0)
  (producer-pattern-source! "(comptime.Expr.Call f (comptime.Expr.Int n))" 0)
  (producer-pattern-source! "(comptime.Expr.Call f args)" 1)
  (producer-pattern-source! "(comptime.Expr.Call _ args)" 1)
  (producer-pattern-source! "(comptime.Expr.Call f _)" 1)
  (producer-pattern-source! "(comptime.Expr.Call _ _)" 1))

(test native-source-call-pattern-fallback (producer-pattern-fallback!))

;; Run by the TLCI image gate's separately built, short-timeout driver: the
;; unfixed diagnostic revisits a computed splice forever. Refs #9356.
(define (producer-splice-source!
  [template : String]
  [expected-native : i64]
  [expected-later-blocker : i64]) : unit
  (let
    [source : String
      (str_cat.str-cat
        "(defmacro (probe [values : Expr ...]) : Expr `"
        template
        ")")]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [parse-state : parser.CompilerParseState
      (parser.compiler-parse-state-new-with-intern-state
        (ci.intern-compat-state-capture-active))]
    (match (parser.parse-ast-source-with-cfg-and-pools
      (& source)
      (parser.compiler-parse-state-cfgs
        (& parse-state)
        (parser.compiler-cfg-empty))
      pools)
      [(Err message) (io.panic message)]
      [(Ok (Program declarations))
        (match (ast.ast-decl-list-step (deref declarations))
          [(Cons (DefMacro _ _ params _ body) _)
            (let
              [context : producer.TlciNativeSourceContext
                (producer.tlci-native-source-context-new
                  (ast.ast-node-pool-context-capture-active)
                  (parser.compiler-parse-state-owner
                    (parser.compiler-parse-state-control-addr (& parse-state))))]
              [names : (__tl_dyn-array String) (__tl_make-array "probe/probe")]
              [captures : producer.TlciNativeMacroCaptures
                (producer.tlci-native-macro-captures-new)]
              [_capture : unit
                (producer.tlci-native-macro-captures-push!
                  (&mut captures)
                  (producer.TlciNativeMacroCapture "probe/probe" params 0 body))]
              [_normal-mode : unit
                (producer.embedded-native-full-blocker-report-set! false)]
              [normal : String
                (producer.embedded-native-source
                  (& context)
                  (& names)
                  (& captures))]
              [normal-reasons : String (producer-owner-reasons)]
              [normal-native : i64
                (array-ref producer.embedded-stdlib-tlci-native-report-count 0)]
              [_full-mode : unit
                (producer.embedded-native-full-blocker-report-set! true)]
              [full : String
                (producer.embedded-native-source
                  (& context)
                  (& names)
                  (& captures))]
              [full-reasons : String
                (string.copy
                  (&
                    (array-ref
                      producer.embedded-stdlib-tlci-native-report-full-reasons
                      0)))]
              (test.assert-owned-string-eq
                full
                normal
                "diagnostics preserve emitted source")
              (test.assert-owned-string-eq
                (producer-owner-reasons)
                (string.copy (& normal-reasons))
                "diagnostics preserve first reason")
              (test.assert-i64-eq
                normal-native
                expected-native
                "ordinary native accounting")
              (test.assert-i64-eq
                (array-ref producer.embedded-stdlib-tlci-native-report-count 0)
                normal-native
                "diagnostic native accounting")
              (test.assert-i64-eq
                (array-ref
                  producer.embedded-stdlib-tlci-native-report-partial-count
                  0)
                0
                "no partial native entry")
              (test.assert-i64-eq
                (array-ref
                  producer.embedded-stdlib-tlci-native-report-interpreted-arms
                  0)
                0
                "no interpreted native arms")
              (test.assert-i64-eq
                (occurrences
                  (& normal-reasons)
                  "probe/probe\ttemplate-splice:non-variable\n")
                (- 1 expected-native)
                "computed splice keeps its registration shell")
              (test.assert-i64-eq
                (occurrences
                  (& full-reasons)
                  "probe/probe\tblocked\ttemplate-splice:non-variable\n")
                (- 1 expected-native)
                "computed splice blocker is deduplicated")
              (test.assert-i64-eq
                (occurrences
                  (& full-reasons)
                  "probe/probe\tblocked\ttemplate-node:try\n")
                expected-later-blocker
                "walk continues to a later unsupported sibling")
              (test.assert-true
                (not producer.embedded-native-full-blocker-diagnostic-active)
                "diagnostic mode is cleared"))]
          [_ (io.panic "splice fixture must contain a macro")])]
      [_ (io.panic "splice fixture must contain a program")])))

(define (producer-splice-diagnostics!) : unit
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [saved : bool producer.embedded-native-full-blocker-report-enabled]
    (producer-splice-source! "(call ,@(comptime.expr-list-cons `1 values))" 0 0)
    (producer-splice-source!
      "(call 0 ,@(comptime.expr-list-cons `1 values) ,@(comptime.expr-list-cons `2 values) (try 1))"
      0
      1)
    (producer-splice-source! "(call ,@values)" 1 0)
    (producer.embedded-native-full-blocker-report-set! saved)))

;; The batch tokens of `line`, or "none" when it is not batchable.
(define (batch-tokens [line : String]) : String
  (match (producer.embedded-native-batch-op (& line))
    [(EmbeddedNativeBatchOpSome name tokens) (str_cat.str-cat name tokens)]
    [(EmbeddedNativeBatchOpNone) "none"]))

(defstruct ProducerOwnerFixture
  (context producer.TlciNativeSourceContext)
  (names (__tl_dyn-array String))
  (captures producer.TlciNativeMacroCaptures)
  (serial-source String)
  (serial-reasons String))

(define (producer-owner-input [callee : String] [wrapper : String]) : String
  (str_cat.str-cat
    "(defmacro (entry [value : Expr]) : Expr `("
    callee
    " ,value))\n"
    "(defmacro (typed [T : type]) : Expr `(init : ("
    wrapper
    " ,T)))\n"
    "(defmacro (unsupported [value : Expr]) : Expr (unknown-source-helper value))\n"))

(define (producer-owner-reasons) : String
  (string.copy
    (& (array-ref producer.embedded-stdlib-tlci-native-report-reasons 0))))

;; Setup deliberately follows the serial parse boundary. Only the later pure
;; generation calls run under a different installed owner.
(define (producer-owner-fixture [callee : String] [wrapper : String]) : ProducerOwnerFixture
  (ci.intern-compat-state-install! (& (ci.intern-compat-state-new)))
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [parse-state : parser.CompilerParseState
      (parser.compiler-parse-state-new-with-intern-state
        (ci.intern-compat-state-capture-active))]
    [source : String (producer-owner-input callee wrapper)]
    [_install : unit (ast.ast-node-pool-context-install! pools)]
    (match (parser.parse-ast-source-with-cfg-and-pools
      (& source)
      (parser.compiler-parse-state-cfgs
        (& parse-state)
        (parser.compiler-cfg-empty))
      pools)
      [(Err message) (io.panic message)]
      [(Ok program)
        (match program
          [(Program declarations)
            (let
              [context : producer.TlciNativeSourceContext
                (producer.tlci-native-source-context-new
                  (ast.ast-node-pool-context-capture-active)
                  (parser.compiler-parse-state-owner
                    (parser.compiler-parse-state-control-addr (& parse-state))))]
              [names : (__tl_dyn-array String) (__tl_make-array String 3)]
              [captures : producer.TlciNativeMacroCaptures
                (producer.tlci-native-macro-captures-new)]
              [cursor : ast.AstDeclList (deref declarations)]
              [index : i64 0]
              [done : bool false]
              (while (not done)
                (match (ast.ast-decl-list-step cursor)
                  [(Nil) (set! done true)]
                  [(Cons declaration rest)
                    (match declaration
                      [(DefMacro _ name params ret body)
                        (let
                          [identity : String
                            (producer.embedded-stdlib-tlci-identity
                              (& context)
                              "owner"
                              name)]
                          (set! (array-ref names index) (string.copy identity))
                          (producer.tlci-native-macro-captures-push!
                            (&mut captures)
                            (producer.TlciNativeMacroCapture
                              identity
                              params
                              (producer.embedded-native-macro-result-kind
                                (& context)
                                ret)
                              body))
                          (set! index (+ index 1)))]
                      [_ (io.panic "owner fixture must contain three macros")])
                    (set! cursor rest)]))
              (unless (= index 3) (io.panic "owner fixture macro count"))
              (let
                [generated : String
                  (producer.embedded-native-source
                    (& context)
                    (& names)
                    (& captures))]
                (test.assert-i64-eq
                  (array-ref
                    producer.embedded-stdlib-tlci-native-report-count
                    0)
                  2
                  "the expression and typed-init entries are native")
                (ProducerOwnerFixture
                  context
                  names
                  captures
                  generated
                  (producer-owner-reasons))))])])))

(define (producer-owner-source [fixture : (& fixture ProducerOwnerFixture)]) : String
  (producer.embedded-native-source
    (& fixture.context)
    (& fixture.names)
    (& fixture.captures)))

(define (producer-owner-annotation [fixture : (& fixture ProducerOwnerFixture)]) : i64
  (match (producer.embedded-stdlib-tlci-unwrap-expr
    (& fixture.context)
    (__tl-project-field (array-ref fixture.captures.slots 1) body))
    [(Quasiquote template)
      (match (producer.embedded-stdlib-tlci-unwrap-expr
        (& fixture.context)
        template)
        [(Init annotation) annotation]
        [_ -1])]
    [_ -1]))

(define (producer-owner-isolation!) : unit
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [home-full-report : bool
      producer.embedded-native-full-blocker-report-enabled]
    [home-interns : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [home-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [home-builtins : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
    [a : ProducerOwnerFixture (producer-owner-fixture "fnalpha" "Ptr")]
    [b : ProducerOwnerFixture (producer-owner-fixture "fnbravo" "Box")]
    [decoy : ProducerOwnerFixture (producer-owner-fixture "fnother" "Slice")]
    [decoy-id : i64 (ci.intern-active-table-id)]
    [decoy-generation : i64 (ci.intern-generation)]
    [decoy-length : i64 (ci.intern-pool-len)]
    [decoy-expressions : i64
      (ast.ast-node-pool-context-expr-len decoy.context.pools)]
    [decoy-types : i64 (ast.ast-node-pool-context-type-len decoy.context.pools)]
    [round : i64 0]
    (test.assert-i64-eq
      (__tl-project-field (array-ref a.captures.slots 0) body)
      (__tl-project-field (array-ref b.captures.slots 0) body)
      "expression IDs collide across A and B")
    (test.assert-i64-eq
      (__tl-project-field (array-ref a.captures.slots 0) body)
      (__tl-project-field (array-ref decoy.captures.slots 0) body)
      "the decoy has the same expression ID")
    (test.assert-true
      (>= (producer-owner-annotation (& a)) 0)
      "typed init has a pooled annotation")
    (test.assert-i64-eq
      (producer-owner-annotation (& a))
      (producer-owner-annotation (& b))
      "type IDs collide across A and B")
    (test.assert-i64-eq
      (producer-owner-annotation (& a))
      (producer-owner-annotation (& decoy))
      "the decoy has the same type ID")
    (test.assert-true
      (and
        (match (ast.ast-node-pool-context-type-get
          (& a.context.pools)
          (producer-owner-annotation (& a)))
          [(Ptr _) true]
          [_ false])
        (match (ast.ast-node-pool-context-type-get
          (& b.context.pools)
          (producer-owner-annotation (& b)))
          [(Box _) true]
          [_ false])
        (match (ast.ast-node-pool-context-type-get
          decoy.context.pools
          (producer-owner-annotation (& decoy)))
          [(Slice _) true]
          [_ false]))
      "the colliding type IDs denote different constructors")
    (test.assert-i64-eq
      (producer.tlci-native-source-name-id (& a.context.intern-state) "fnalpha")
      (producer.tlci-native-source-name-id (& b.context.intern-state) "fnbravo")
      "different source spellings collide numerically across owners")
    (test.assert-i64-eq
      (producer.tlci-native-source-name-id (& a.context.intern-state) "fnalpha")
      (producer.tlci-native-source-name-id
        (& decoy.context.intern-state)
        "fnother")
      "the installed decoy has the same numeric callee ID")
    (test.assert-true
      (> (occurrences (& a.serial-source) "fnalpha") 0)
      "A's serial source contains its own callee")
    (test.assert-true
      (not (string.eq (& a.serial-source) (& b.serial-source)))
      "the fixtures produce distinct source")
    (producer.embedded-native-full-blocker-report-set! true)
    (while (< round 3)
      (test.assert-owned-string-eq
        (producer-owner-source (& a))
        (clone a.serial-source)
        "A ignores installed expression/type pools and intern names")
      (test.assert-owned-string-eq
        (producer-owner-reasons)
        (clone a.serial-reasons)
        "A's unsupported-body diagnostic is stable")
      (test.assert-owned-string-eq
        (producer-owner-source (& b))
        (clone b.serial-source)
        "B ignores installed expression/type pools and intern names")
      (test.assert-owned-string-eq
        (producer-owner-reasons)
        (clone b.serial-reasons)
        "B's unsupported-body diagnostic is stable")
      (test.assert-true
        (>
          (occurrences
            (&
              (array-ref
                producer.embedded-stdlib-tlci-native-report-full-reasons
                0))
            "owner/unsupported\tblocked\t")
          0)
        "full diagnostics retain the borrowed catalog identity")
      (set! round (+ round 1)))
    ;; Reset only the retired input owner. Its peer remains a valid source
    ;; snapshot, and no producer call is allowed to resurrect A's old IDs.
    (ci.intern-compat-state-reset! (&mut a.context.intern-state))
    (ast.ast-node-pool-context-reset-to! a.context.pools 0 0)
    (test.assert-owned-string-eq
      (producer-owner-source (& b))
      (clone b.serial-source)
      "resetting A preserves B's captured source")
    (test.assert-i64-eq
      (ci.intern-active-table-id)
      decoy-id
      "decoy table unchanged")
    (test.assert-i64-eq
      (ci.intern-generation)
      decoy-generation
      "decoy generation unchanged")
    (test.assert-i64-eq
      (ci.intern-pool-len)
      decoy-length
      "decoy intern length unchanged")
    (test.assert-i64-eq
      (ast.ast-node-pool-context-expr-len decoy.context.pools)
      decoy-expressions
      "decoy expression pool unchanged")
    (test.assert-i64-eq
      (ast.ast-node-pool-context-type-len decoy.context.pools)
      decoy-types
      "decoy type pool unchanged")
    (test.assert-owned-string-eq
      (producer-owner-source (& decoy))
      decoy.serial-source
      "the decoy's own source remains intact")
    (producer.embedded-native-full-blocker-report-set! home-full-report)
    (ci.intern-compat-state-install! home-interns)
    (ast.ast-node-pool-context-install! home-pools)
    (cbi.state-install! (& home-builtins))))

(test native-source-explicit-owner-isolation (producer-owner-isolation!))

(define (producer-owner-result-kinds!) : unit
  (let
    [a : ci.InternCompatState (ci.intern-compat-state-new)]
    [b : ci.InternCompatState (ci.intern-compat-state-new)]
    [module-a : i64 (ci.intern-compat-state-intern (&mut a) "Module")]
    [decls-b : i64 (ci.intern-compat-state-intern (&mut b) "Decls")]
    [context-a : producer.TlciNativeSourceContext
      (producer.tlci-native-source-context-new
        (ast.ast-node-pool-context-new-with-capacities 1 1)
        a)]
    [context-b : producer.TlciNativeSourceContext
      (producer.tlci-native-source-context-new
        (ast.ast-node-pool-context-new-with-capacities 1 1)
        b)]
    [empty : producer.TlciNativeSourceContext
      (producer.tlci-native-source-context-new
        (ast.ast-node-pool-context-new-with-capacities 1 1)
        (ci.intern-compat-state-new))]
    (test.assert-i64-eq
      module-a
      decls-b
      "same numeric ID has different result spelling")
    (test.assert-i64-eq
      (producer.embedded-native-macro-result-kind (& context-a) (Var module-a))
      1
      "Module uses A's interner")
    (test.assert-i64-eq
      (producer.embedded-native-macro-result-kind (& context-b) (Var decls-b))
      2
      "Decls uses B's interner")
    (test.assert-i64-eq
      (producer.embedded-native-macro-result-kind (& empty) (Var -1))
      0
      "missing sentinels never match a negative name")))

(test
  native-source-result-kind-owner-and-missing-sentinels
  (producer-owner-result-kinds!))

(define (name-arg [escaped : String]) : String
  (str_cat.str-cat
    "(cast (unsafe (ptr->int (string-data \""
    (str_cat.str-cat escaped "\"))) : i64)")))

(define (op-line [name : String] [args : String]) : String
  (str_cat.str-cat
    "(comptime-host-"
    (str_cat.str-cat
      name
      (str_cat.str-cat " host session " (str_cat.str-cat args ")")))))

(test
  batch-op-constant-immediates
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "3 14 -21474836480"))
    "expr-spanA3A>fD00000"
    "integer immediates become batch integers")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line "expr-var" (str_cat.str-cat (name-arg "value") " 5 0")))
    "expr-var#A5valueA5@"
    "a name argument carries its bytes")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line
        "string-value"
        (str_cat.str-cat (name-arg "a\\\"b\\\\c\\n d") " 8 0")))
    "string-value#A8a\"b\\c\n dA8@"
    "escapes are undone and the byte length counts raw bytes")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line
        "type-ref"
        (str_cat.str-cat "1 " (str_cat.str-cat (name-arg "r") " 1"))))
    "type-refA1#A1rA1"
    "a name argument may sit in the middle position"))

(test
  batch-op-rejects-non-constant-shapes
  (test.assert-owned-string-eq
    (batch-tokens (op-line "local-get" "k3 0 0"))
    "none"
    "a generated variable is not a constant")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line "expr-var" (str_cat.str-cat (name-arg "value") " 4 0")))
    "none"
    "the length after a name must be its byte length")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line "expr-var" (str_cat.str-cat "0 0 " (name-arg "value"))))
    "none"
    "a name in the last position has no length")
  (test.assert-owned-string-eq
    (batch-tokens
      (op-line
        "expr-var"
        (str_cat.str-cat
          (name-arg "a")
          (str_cat.str-cat " " (str_cat.str-cat (name-arg "b") " 1")))))
    "none"
    "a name cannot follow a name")
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "1  2 3"))
    "none"
    "only the canonical spacing parses")
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "1 2 1234567890123456789"))
    "none"
    "a 19-digit immediate is not batched")
  (test.assert-owned-string-eq
    (batch-tokens (op-line "expr-span" "1 2 3 4"))
    "none"
    "an op takes exactly three immediates")
  (test.assert-owned-string-eq
    (batch-tokens "(other-call host session 0 0 0)")
    "none"
    "only host calls are batched"))

;; The number of `(` minus `)` in `text` outside string literals.
(define (open-parens [text : (& text str)]) : i64
  (let
    [depth : i64 0]
    [index : i64 0]
    [in-string : bool false]
    (while (< index (string.string-length text))
      (let
        [c : char (string.string-ref text index)]
        (cond
          [(and in-string (= c '\\')) (+= index 1)]
          [(= c '"') (set! in-string (not in-string))]
          [(and (not in-string) (= c '(')) (+= depth 1)]
          [(and (not in-string) (= c ')')) (-= depth 1)]
          [else unit])
        (+= index 1)))
    depth))

;; Occurrences of `needle` in `text`.
(define (occurrences [text : (& text str)] [needle : String]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    [length : i64 (string.string-length needle)]
    (while (<= (+ index length) (string.string-length text))
      (if (string.eq (string.substring text index length) (& needle))
        (begin
          (+= count 1)
          (+= index length))
        (+= index 1)))
    count))

;; A batch name entry: this build's row hint, the length and the name.
(define (batch-name [name : String]) : String
  (str_cat.str-cat
    (producer.embedded-native-batch-int
      (tlci_core.tlci-host-callback-row-index (& name)))
    (producer.embedded-native-batch-int (string.string-length name))
    name))

(test
  status-chain-batches-constant-runs
  (let
    [ops : (__tl_dyn-array String) (__tl_make-array String 5)]
    (set! (array-ref ops 0) (op-line "expr-list-empty" "0 0 0"))
    (set!
      (array-ref ops 1)
      (op-line "expr-var" (str_cat.str-cat (name-arg "x") " 1 0")))
    (set! (array-ref ops 2) (op-line "local-get" "k3 0 0"))
    (set! (array-ref ops 3) (op-line "expr-span" "3 4 -5"))
    (set! (array-ref ops 4) (op-line "expr-list-empty" "0 0 0"))
    (let
      [text : String (producer.embedded-native-ops-open-text ops 5)]
      (test.assert-i64-eq
        (open-parens (& text))
        10
        "every op still opens one pair")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-run-ops")
        2
        "two constant runs")
      (test.assert-i64-eq
        (occurrences (& text) "(begin (begin")
        2
        "one empty pair per batched op after the first")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-local-get host session k3 0 0")
        1
        "the non-constant op stays a call")
      (test.assert-i64-eq
        (occurrences
          (& text)
          (producer.embedded-native-escape-string
            (str_cat.str-cat
              (producer.embedded-native-batch-int 2)
              (batch-name "expr-list-empty")
              (batch-name "expr-var")
              (producer.embedded-native-batch-int 2)
              "0@@@1#A1xA1@")))
        1
        "the first run names each op once and indexes its names")
      (test.assert-i64-eq
        (occurrences
          (& text)
          (producer.embedded-native-escape-string
            (str_cat.str-cat
              (producer.embedded-native-batch-int 2)
              (batch-name "expr-span")
              (batch-name "expr-list-empty")
              (producer.embedded-native-batch-int 2)
              "0A3A4a51@@@")))
        1
        "the second run")
      (test.assert-i64-eq
        (occurrences (& text) "[q0 :")
        1
        "the first run keeps its first op's status name")
      (test.assert-i64-eq
        (occurrences (& text) "[q2 :")
        1
        "the unbatched op keeps its own status name")
      (test.assert-i64-eq
        (occurrences (& text) "[q3 :")
        1
        "the second run keeps its first op's status name"))))

(test
  status-chain-leaves-lone-ops-as-calls
  (let
    [ops : (__tl_dyn-array String) (__tl_make-array String 3)]
    (set! (array-ref ops 0) (op-line "expr-list-empty" "0 0 0"))
    (set! (array-ref ops 1) (op-line "local-get" "k1 0 0"))
    (set! (array-ref ops 2) (op-line "expr-list-empty" "0 0 0"))
    (let
      [text : String (producer.embedded-native-ops-open-text ops 3)]
      (test.assert-i64-eq (open-parens (& text)) 6 "three pairs")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-run-ops")
        0
        "a run of one stays a call")
      (test.assert-i64-eq
        (occurrences
          (& text)
          "comptime-host-expr-list-empty host session 0 0 0")
        2
        "both lone ops are calls"))))

;; A run that would bind more distinct names than one batch may is split.
(test
  status-chain-splits-at-the-name-cap
  (let
    [count : i64 (+ tlci_core.tlci-run-ops-names-cap 1)]
    [ops : (__tl_dyn-array String) (__tl_make-array String count)]
    (for [index (iterator.range 0 count)]
      (set!
        (array-ref ops index)
        (op-line (str_cat.str-cat "op-" (string.int->string index)) "0 0 0")))
    (let
      [text : String (producer.embedded-native-ops-open-text ops count)]
      (test.assert-i64-eq
        (open-parens (& text))
        (* 2 count)
        "every op still opens one pair")
      (test.assert-i64-eq
        (occurrences (& text) "comptime-host-run-ops")
        1
        "one full batch")
      (test.assert-i64-eq
        (occurrences
          (& text)
          (str_cat.str-cat
            "comptime-host-op-"
            (string.int->string tlci_core.tlci-run-ops-names-cap)))
        1
        "the op past the cap is left as its own call"))))