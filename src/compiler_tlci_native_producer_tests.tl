;; compiler_tlci_native_producer_tests.tl - the producer's `run-ops` batching:
;; which op lines become batch tokens and how the status chain renders a run
;; of them. The host side of the batch format is covered by
;; src/tests/comptime_host_smoke.tl, and the gates that compile every stdlib
;; macro through both routes cover the end-to-end expansions. Refs #8274.
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
          [(and in-string (= c '\\')) (set! index (+ index 1))]
          [(= c '"') (set! in-string (not in-string))]
          [(and (not in-string) (= c '(')) (set! depth (+ depth 1))]
          [(and (not in-string) (= c ')')) (set! depth (- depth 1))]
          [else unit])
        (set! index (+ index 1))))
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
          (set! count (+ count 1))
          (set! index (+ index length)))
        (set! index (+ index 1))))
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
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref ops index)
        (op-line (str_cat.str-cat "op-" (string.int->string index)) "0 0 0"))
      (set! index (+ index 1)))
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