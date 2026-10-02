;; comptime_host_smoke.tl - Compiler-owned native-comptime host session smoke.
;;
;; Drives the named host callbacks directly, the way a natively compiled
;; transformer does, and checks their marshalling: the value-stack and local
;; operand order, immediates, the data and status channels, macro-call
;; provenance and fold hygiene markers, and the status contract for stale
;; cookies, empty-stack and duplicate commits, fuel exhaustion, and native
;; panic/abort without partial commit. The builders themselves are shared with
;; interpreted CTFE (compiler_ctfe) and tested there. Refs #5212, #5475, #5503,
;; #4870, #6609.
(import compiler_embedded_stdlib_tlci as host)
(import tlci_core as tlci)
(import compiler_tlci_native_producer as producer)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_ast_types as ast)
(import compiler_ctfe as ctfe)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import stdlib.io)
(import stdlib.string)

(define host-smoke-cookie : i64
  0x5151)

(define (host-smoke-name-ptr [name : (& name str)]) : i64
  (cast
    (unsafe
      (ptr->int (string-data name)))
    : i64))

(define (host-smoke-invoke
  [callback : (-> i64 i64 i64 i64 i64)]
  [a : i64]
  [b : i64]) : i64
  (callback host-smoke-cookie a b 0))

(define (host-smoke-ok?
  [callback : (-> i64 i64 i64 i64 i64)]
  [a : i64]
  [b : i64]) : bool
  (= (host-smoke-invoke callback a b) tlci.tlci-host-callback-status-ok))

(define (host-smoke-push? [index : i64]) : bool
  (host-smoke-ok? host.compiler-comptime-host-callback-push-operand index 0))

(define (host-smoke-commit?) : bool
  (host-smoke-ok? host.compiler-comptime-host-callback-commit-result 0 0))

;; A bad request that committed no result.
(define (host-smoke-rejected? [status : i64]) : bool
  (and
    (= status tlci.tlci-host-callback-status-bad-request)
    (not (host.compiler-comptime-host-result-ready?))))

(define (host-smoke-open!
  [pools : ast.AstNodePoolContext]
  [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)]
  [count : i64]
  [fuel : i64]) : unit
  (host.compiler-comptime-host-session-open!
    pools
    operands
    count
    fuel
    host-smoke-cookie
    (ctfe.ctfe-reflect-info-list-empty)))

(define (host-smoke-close [ok : bool]) : bool
  (begin
    (host.compiler-comptime-host-session-close!)
    ok))

(define (host-smoke-var [pools : ast.AstNodePoolContext] [name : String]) : i64
  (ast.ast-node-pool-context-expr-push pools (Var (ci.intern name))))

(define (host-smoke-expr [node : i64]) : ctfe.CompilerCtfeValue
  (Expr node (Expr)))

(define (host-smoke-syntax-name-text [name-id : i64]) : String
  (let
    [source-id : i64
      (cis.intern-structural-session-syntax-source-name-id-or
        (cis.intern-structural-session-handle-from-source-names
          (host.compiler-comptime-host-session-source-names-value))
        name-id
        -1)]
    (if (ci.intern-renderable-id? source-id)
      (ci.intern-str source-id)
      "<structural-name>")))

;; Build `(f ,x)` through named callbacks: callee var, empty list, operand
;; push, append, call, commit.
(define (host-smoke-construct-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand-node : i64 (host-smoke-var pools "x")]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [callee-name : String "__tl_array-length"]
    (begin
      (set! (array-ref operands 0) (host-smoke-expr operand-node))
      (host-smoke-open! pools operands 1 8)
      (and
        (host-smoke-ok? host.compiler-comptime-host-callback-fuel-check 0 0)
        (host-smoke-ok?
          host.compiler-comptime-host-callback-expr-var
          (host-smoke-name-ptr callee-name)
          (string.string-length callee-name))
        (host-smoke-ok?
          host.compiler-comptime-host-callback-expr-list-empty
          0
          0)
        (host-smoke-push? 0)
        (host-smoke-ok?
          host.compiler-comptime-host-callback-expr-list-append
          0
          0)
        (host-smoke-ok? host.compiler-comptime-host-callback-expr-call 0 0)
        (host-smoke-commit?)
        (host.compiler-comptime-host-result-ready?)
        (host-smoke-result-shape-ok? pools operand-node)))))

;; A batch integer, in the encoding the producer writes.
(define (host-smoke-int [value : i64]) : String
  (producer.embedded-native-batch-int value))

;; A batch name entry with this build's row hint for `name`.
(define (host-smoke-name [name : String]) : String
  (str_cat.str-cat
    (host-smoke-int (tlci.tlci-host-callback-row-index (& name)))
    (host-smoke-int (string.string-length name))
    name))

;; A batch name entry whose row hint is wrong, as in an image another build
;; produced: the host must fall back to finding the name.
(define (host-smoke-stale-name [name : String]) : String
  (str_cat.str-cat
    (host-smoke-int (+ (tlci.tlci-host-callback-row-index (& name)) 1))
    (host-smoke-int (string.string-length name))
    name))

;; A record: the op byte for batch name `op`, then three zero immediates.
(define (host-smoke-zero-record [op : i64]) : String
  (str_cat.str-cat
    (producer.embedded-native-batch-char op)
    (host-smoke-int 0)
    (host-smoke-int 0)
    (host-smoke-int 0)))

;; A batch of one name and one record.
(define (host-smoke-one [name : String] [record : String]) : String
  (str_cat.str-cat
    (host-smoke-int 1)
    (host-smoke-name name)
    (host-smoke-int 1)
    record))

;; A batch whose one op is `run-ops` over `inner`, passed as caller bytes: a
;; well-formed inner batch would run if `run-ops` could name itself.
(define (host-smoke-nested-run-ops [inner : String]) : String
  (let
    [length : i64 (string.string-length inner)]
    (host-smoke-one
      "run-ops"
      (str_cat.str-cat
        "0#"
        (host-smoke-int length)
        inner
        (host-smoke-int length)
        (host-smoke-int 0)))))

;; The construction above as one `run-ops` batch: the same callbacks with the
;; same immediates commit the same call shape. Refs #8274.
(define (host-smoke-run-ops-construct-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand-node : i64 (host-smoke-var pools "x")]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [batch : String
      (str_cat.str-cat
        (host-smoke-int 5)
        (host-smoke-name "expr-var")
        (host-smoke-name "expr-list-empty")
        (host-smoke-stale-name "push-operand")
        (host-smoke-name "expr-list-append")
        (host-smoke-name "expr-call")
        (host-smoke-int 5)
        (str_cat.str-cat
          "0#"
          (host-smoke-int 17)
          "__tl_array-length"
          (host-smoke-int 17)
          (host-smoke-int 0))
        (host-smoke-zero-record 1)
        (host-smoke-zero-record 2)
        (host-smoke-zero-record 3)
        (host-smoke-zero-record 4))]
    (begin
      (set! (array-ref operands 0) (host-smoke-expr operand-node))
      (host-smoke-open! pools operands 1 8)
      (and
        (host-smoke-ok?
          host.compiler-comptime-host-callback-run-ops
          (host-smoke-name-ptr batch)
          (string.string-length batch))
        (host-smoke-commit?)
        (host.compiler-comptime-host-result-ready?)
        (host-smoke-result-shape-ok? pools operand-node)))))

;; Run `batch` in a fresh one-operand session; the status and the value-stack
;; depth it left, as `status * 1000 + depth`.
(define (host-smoke-run-ops-outcome [batch : String]) : i64
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (host-smoke-expr (host-smoke-var pools "x")))
      (host-smoke-open! pools operands 1 8)
      (let
        [status : i64
          (host-smoke-invoke
            host.compiler-comptime-host-callback-run-ops
            (host-smoke-name-ptr batch)
            (string.string-length batch))]
        [depth : i64 host.compiler-comptime-host-stack-len]
        (begin
          (host.compiler-comptime-host-session-close!)
          (+ (* status 1000) depth))))))

;; A malformed batch is a bad request at the malformed token: the header
;; tokens resolve before any op runs, an earlier op in the same batch has
;; already run (which a failed expansion never commits), and a batch stops at
;; its first failing op.
(define (host-smoke-run-ops-rejects-ok?) : bool
  (let
    [rejected : i64 (* tlci.tlci-host-callback-status-bad-request 1000)]
    (and
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one "expr-list-empty" (host-smoke-zero-record 0)))
        1)
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 1)
            (host-smoke-stale-name "expr-list-empty")
            (host-smoke-int 1)
            (host-smoke-zero-record 0)))
        1)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one "no-such-op" (host-smoke-zero-record 0)))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one "run-ops" (host-smoke-zero-record 0)))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-nested-run-ops
            (host-smoke-one "expr-list-empty" (host-smoke-zero-record 0))))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one "expr-list-empty" (host-smoke-zero-record 1)))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one "expr-list-empty" (str_cat.str-cat "/" "@@@")))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one
            "expr-var"
            (str_cat.str-cat "0#" (host-smoke-int 1) "x" (host-smoke-int 2) "@")))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one
            "expr-var"
            (str_cat.str-cat
              "0#"
              (host-smoke-int 1)
              "x#"
              (host-smoke-int 1)
              "y"
              (host-smoke-int 1))))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one
            "expr-var"
            (str_cat.str-cat "0@@#" (host-smoke-int 1) "x")))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (host-smoke-one
            "expr-var"
            (str_cat.str-cat "0#" (host-smoke-int 9) "x")))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 1)
            (host-smoke-name "expr-list-empty")
            (host-smoke-int 2)
            (host-smoke-zero-record 0)))
        (+ rejected 1))
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-one "expr-list-empty" (host-smoke-zero-record 0))
            "@"))
        (+ rejected 1))
      (=
        (host-smoke-run-ops-outcome (host-smoke-one "expr-list-empty" "0@@"))
        rejected)
      (=
        (host-smoke-run-ops-outcome (host-smoke-one "expr-list-empty" "0@Z@"))
        rejected)
      (=
        (host-smoke-run-ops-outcome (host-smoke-one "expr-list-empty" "0@`@"))
        rejected)
      (=
        (host-smoke-run-ops-outcome (host-smoke-one "expr-list-empty" "0@A~@"))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 0)
            (host-smoke-int 1)
            (host-smoke-zero-record 0)))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 1)
            (host-smoke-name "expr-list-empty")
            (host-smoke-int 0)))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 2)
            (host-smoke-name "expr-list-append")
            (host-smoke-name "expr-list-empty")
            (host-smoke-int 2)
            (host-smoke-zero-record 0)
            (host-smoke-zero-record 1)))
        rejected)
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 1)
            (host-smoke-name "expr-list-empty")
            (host-smoke-int 2)
            (host-smoke-zero-record 0)
            "0@Z@"))
        (+ rejected 1))
      (=
        (host-smoke-run-ops-outcome
          (str_cat.str-cat
            (host-smoke-int 1)
            (host-smoke-name "expr-list-empty")
            (host-smoke-int 3)
            (host-smoke-zero-record 0)
            (host-smoke-zero-record 0)
            (host-smoke-zero-record 0)))
        3))))

(define (host-smoke-result-shape-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [operand-node : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node _)
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(Call callee-id args)
          (and
            (match (ast.ast-node-pool-context-expr-get pools callee-id)
              [(Var name-id)
                (=
                  name-id
                  (host.compiler-comptime-host-template-source-id
                    (ci.intern "__tl_array-length")))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (= (ast.ast-expr-list-get (& args) 0 -1) operand-node))]
        [_ false])]
    [_ false]))

(define (host-smoke-result-is-hygiene-free?) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node _) (= node (ctfe.ctfe-result-hygiene-free-node-id))]
    [_ false]))

;; Reflection probes return 1/0 as data rather than callback statuses. A true
;; result must not poison the following construction operation, and the
;; malformed-request sentinel is likewise caller-owned until a native entry
;; translates it to the public bad-request status.
(define (host-smoke-type-kind-data-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [i64-kind : String "i64"]
    [string-kind : String "string"]
    (begin
      (set! (array-ref operands 0) (ctfe.CompilerCtfeValue.Type (I64)))
      (host-smoke-open! pools operands 1 8)
      (host-smoke-close
        (and
          (=
            (host.compiler-comptime-host-callback-operand-type-kind-eq
              host-smoke-cookie
              0
              (host-smoke-name-ptr i64-kind)
              (string.string-length i64-kind))
            1)
          (=
            (host.compiler-comptime-host-callback-operand-type-kind-eq
              host-smoke-cookie
              0
              (host-smoke-name-ptr string-kind)
              (string.string-length string-kind))
            0)
          (<
            (host.compiler-comptime-host-callback-operand-type-kind-eq
              host-smoke-cookie
              1
              (host-smoke-name-ptr i64-kind)
              (string.string-length i64-kind))
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-bool-literal
            1
            0))))))

;; Reflection result callbacks and their computed expression/pattern consumers
;; are the shared host surface used by the eight eq/hash fold bodies in #5626.
;; Keep a compact nominal metadata table here so this test exercises the
;; callback contract independently of the embedded-stdlib coverage census.
(define (host-smoke-reflections [pools : ast.AstNodePoolContext]) : ctfe.CtfeReflectInfoList
  (let
    [pair-id : i64 (ci.intern "HostSmokePair")]
    [choice-id : i64 (ci.intern "HostSmokeChoice")]
    [fields : ctfe.CtfeReflectFieldList
      (ctfe.ctfe-reflect-field-list-with-capacity 2)]
    [payloads : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
    [variants : ctfe.CtfeReflectVariantList
      (ctfe.ctfe-reflect-variant-list-with-capacity 2)]
    [infos : ctfe.CtfeReflectInfoList
      (ctfe.ctfe-reflect-info-list-with-capacity 2)]
    (begin
      (set!
        fields
        (ctfe.ctfe-reflect-field-list-push
          fields
          (Field (ci.intern "alpha") (I64))))
      (set!
        fields
        (ctfe.ctfe-reflect-field-list-push
          fields
          (Field (ci.intern "beta") (Bool))))
      (ast.ast-type-list-push
        (&mut payloads)
        (ast.ast-node-pool-context-type-push pools (I64)))
      (ast.ast-type-list-push
        (&mut payloads)
        (ast.ast-node-pool-context-type-push pools (Bool)))
      (set!
        variants
        (ctfe.ctfe-reflect-variant-list-push
          variants
          (Variant (ci.intern "Some") payloads)))
      (set!
        variants
        (ctfe.ctfe-reflect-variant-list-push
          variants
          (Variant (ci.intern "None") (ast.ast-type-list-new))))
      (set!
        infos
        (ctfe.ctfe-reflect-info-list-push-id
          infos
          (Struct "HostSmokePair" "" "HostSmokePair" pair-id (No) fields 0)
          pair-id))
      (ctfe.ctfe-reflect-info-list-push-id
        infos
        (Enum "HostSmokeChoice" "" "HostSmokeChoice" choice-id (No) variants 0)
        choice-id))))

;; The reflection builder test below batches several independent logical
;; invocations under one expensive metadata setup. Consume its synthetic result
;; between probes; real macro entries never receive this reset capability.
(define (host-smoke-consume-test-result!) : bool
  (begin
    (host.compiler-comptime-host-result-consume-for-test!)
    true))

(define (host-smoke-result-name? [expected : String]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Name text _) (string.eq text expected)]
    [(String text _) (string.eq text expected)]
    [_ false]))

(define (host-smoke-result-type? [expected-bool : bool]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Type ty)
      (if expected-bool
        (match ty
          [(Bool) true]
          [_ false])
        (match ty
          [(I64) true]
          [_ false]))]
    [_ false]))

(define (host-smoke-result-slice-i64?
  [pools : (& pools ast.AstNodePoolContext)]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Type (Slice elem))
      (match (ast.ast-node-pool-context-type-get pools elem)
        [(I64) true]
        [_ false])]
    [_ false]))

;; The native type-slice wrapper shares the value stack ABI of the other
;; composite type callbacks: a scalar then the wrapper commit one Slice.
(define (host-smoke-type-slice-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 0)]
    (begin
      (host-smoke-open! pools operands 0 8)
      (host-smoke-close
        (and
          (host-smoke-ok? host.compiler-comptime-host-callback-type-scalar 0 0)
          (host-smoke-ok? host.compiler-comptime-host-callback-type-slice 0 0)
          (host-smoke-commit?)
          (host-smoke-result-slice-i64? pools))))))

(define (host-smoke-result-tuple-bool-t?
  [pools : (& pools ast.AstNodePoolContext)]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Type (Tuple elems-box))
      (let
        [elems : ast.AstTypeList (deref elems-box)]
        (and
          (= (ast.ast-type-list-len (& elems)) 2)
          (match (ast.ast-node-pool-context-type-get
            pools
            (ast.ast-type-list-get (& elems) 0 (ast.ast-type-id-fallback)))
            [(Bool) true]
            [_ false])
          (match (ast.ast-node-pool-context-type-get
            pools
            (ast.ast-type-list-get (& elems) 1 (ast.ast-type-id-fallback)))
            [(Var name-id)
              (string.eq (host-smoke-syntax-name-text name-id) "T")]
            [_ false])))]
    [_ false]))

;; Tuple type templates preserve source order and reject a non-Type stack
;; suffix without committing a result.
(define (host-smoke-type-tuple-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 0)]
    [type-name : String "T"]
    (begin
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 0 16)
      (and
        (host-smoke-close
          (and
            (host-smoke-ok?
              host.compiler-comptime-host-callback-type-scalar
              10
              0)
            (host-smoke-ok?
              host.compiler-comptime-host-callback-type-var
              (host-smoke-name-ptr type-name)
              (string.string-length type-name))
            (host-smoke-ok? host.compiler-comptime-host-callback-type-tuple 2 0)
            (host-smoke-commit?)
            (host-smoke-result-tuple-bool-t? pools)))
        (begin
          (host-smoke-open! pools operands 0 8)
          (host-smoke-close
            (and
              (host-smoke-ok?
                host.compiler-comptime-host-callback-expr-bool-literal
                1
                0)
              (host-smoke-rejected?
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-type-tuple
                  1
                  0)))))))))

(define (host-smoke-result-var-args?
  [expected-name : String]
  [expected-first : String]
  [expected-second : String]
  [expected-count : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Type (VarArgs name lifetimes-box))
      (let
        [lifetimes : ast.AstLifetimeList (deref lifetimes-box)]
        (and
          (= name (ci.intern expected-name))
          (= (ast.ast-lifetime-list-len (& lifetimes)) expected-count)
          (=
            (ast.ast-lifetime-list-get
              (& lifetimes)
              0
              (ast.ast-lifetime-fallback))
            (ci.intern expected-first))
          (or
            (= expected-count 1)
            (=
              (ast.ast-lifetime-list-get
                (& lifetimes)
                1
                (ast.ast-lifetime-fallback))
              (ci.intern expected-second)))))]
    [_ false]))

(define (host-smoke-type-var-args [count : i64] [spec : String]) : i64
  (host.compiler-comptime-host-callback-type-var-args
    host-smoke-cookie
    count
    (host-smoke-name-ptr spec)
    (string.string-length spec)))

;; Lifetime-parameterized unresolved nominal templates preserve exact name ids
;; and lifetime order. Malformed counts and empty fields fail without
;; publishing a result, even when another value is already on the stack.
(define (host-smoke-type-var-args-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 0)]
    (begin
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 0 8)
      (and
        (host-smoke-close
          (and
            (=
              (host-smoke-type-var-args 1 "Borrowed\ntext")
              tlci.tlci-host-callback-status-ok)
            (host-smoke-commit?)
            (host-smoke-result-var-args? "Borrowed" "text" "" 1)))
        (begin
          (host-smoke-open! pools (ast.ast-place-shared-view operands) 0 8)
          (host-smoke-close
            (and
              (=
                (host-smoke-type-var-args 2 "LifetimePair\nleft\nright")
                tlci.tlci-host-callback-status-ok)
              (host-smoke-commit?)
              (host-smoke-result-var-args? "LifetimePair" "left" "right" 2))))
        (begin
          (host-smoke-open! pools operands 0 8)
          (host-smoke-close
            (and
              (host-smoke-ok?
                host.compiler-comptime-host-callback-type-scalar
                0
                0)
              (host-smoke-rejected? (host-smoke-type-var-args 2 "Broken\nonly")))))))))

(define (host-smoke-result-array-take?
  [pools : (& pools ast.AstNodePoolContext)]
  [target : i64]
  [live : i64]
  [index : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node _)
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(ArrayTake actual-target actual-live actual-index)
          (and
            (= actual-target target)
            (= actual-live live)
            (= actual-index index))]
        [_ false])]
    [_ false]))

;; The dedicated array-take node consumes exactly three Expr values; an
;; underflow is a deterministic bad request.
(define (host-smoke-array-take-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [target : i64 (host-smoke-var pools "slots")]
    [live : i64 (host-smoke-var pools "live")]
    [index : i64 (host-smoke-var pools "index")]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 3)]
    (begin
      (set! (array-ref operands 0) (host-smoke-expr target))
      (set! (array-ref operands 1) (host-smoke-expr live))
      (set! (array-ref operands 2) (host-smoke-expr index))
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 3 16)
      (and
        (host-smoke-close
          (and
            (host-smoke-push? 0)
            (host-smoke-push? 1)
            (host-smoke-push? 2)
            (host-smoke-ok?
              host.compiler-comptime-host-callback-expr-array-take
              0
              0)
            (host-smoke-commit?)
            (host-smoke-result-array-take? pools target live index)))
        (begin
          (host-smoke-open! pools operands 3 8)
          (host-smoke-close
            (and
              (host-smoke-push? 0)
              (host-smoke-rejected?
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-expr-array-take
                  0
                  0)))))))))

(define (host-smoke-result-expr-typed-binding? [expected-init : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(LetBinding (Binding name maybe-ty init))
      (and
        (string.eq (host-smoke-syntax-name-text name) "out")
        (= init expected-init)
        (match maybe-ty
          [(Some (Var type-name))
            (string.eq (host-smoke-syntax-name-text type-name) "Vec")]
          [_ false]))]
    [_ false]))

;; Typed template bindings accept an Expr containing type syntax, not only a
;; direct Type value. This is the path used by vector's computed `vec-name`.
;; A non-type Expr reports the same diagnostic as interpreted type unquote.
(define (host-smoke-expr-typed-binding-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [init-node : i64 (host-smoke-var pools "with-capacity")]
    [type-node : i64 (host-smoke-var pools "Vec")]
    [bad-type-node : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (Unit)))]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 3)]
    [binding-name : String "out"]
    (begin
      (set! (array-ref operands 0) (host-smoke-expr init-node))
      (set! (array-ref operands 1) (host-smoke-expr type-node))
      (set! (array-ref operands 2) (host-smoke-expr bad-type-node))
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 3 16)
      (and
        (host-smoke-close
          (and
            (host-smoke-push? 0)
            (host-smoke-push? 1)
            (host-smoke-ok?
              host.compiler-comptime-host-callback-let-binding-typed
              (host-smoke-name-ptr binding-name)
              (string.string-length binding-name))
            (host-smoke-commit?)
            (host-smoke-result-expr-typed-binding? init-node)))
        (begin
          (host-smoke-open! pools operands 3 16)
          (host-smoke-close
            (and
              (host-smoke-push? 0)
              (host-smoke-push? 2)
              (=
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-let-binding-typed
                  (host-smoke-name-ptr binding-name)
                  (string.string-length binding-name))
                tlci.tlci-host-callback-status-diagnostic)
              (string.eq
                (host.compiler-comptime-host-diagnostic-text)
                "type unquote expects a type expression")
              (not (host.compiler-comptime-host-result-ready?)))))))))

(define (host-smoke-result-bool? [expected : bool]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Bool value)
      (if expected
        value
        (not value))]
    [_ false]))

(define (host-smoke-result-captured-begin-items? [expected-node : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(CapturedExprList items _)
      (and
        (= (ctfe.ctfe-expr-list-length items) 1)
        (= (ctfe.ctfe-expr-list-nth items 0) expected-node))]
    [_ false]))

;; Local Expr destructuring retains Name, Int, and captured-list values, while
;; the bool data/value pair round-trips both immediate states. Wrong local
;; shapes and invalid immediates are rejected through their documented ABI
;; channel.
(define (host-smoke-local-values-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [var-node : i64 (host-smoke-var pools "core")]
    [item-node : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (Unit)))]
    [int-node : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (ast.ast-lit-int 73)))]
    [items : ast.AstExprList (ast.ast-expr-list-with-capacity 1)]
    [begin-node : i64 0]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 4)]
    (begin
      (ast.ast-expr-list-push (&mut items) item-node)
      (set!
        begin-node
        (ast.ast-node-pool-context-expr-push pools (Begin items)))
      (set! (array-ref operands 0) (host-smoke-expr var-node))
      (set!
        (array-ref operands 1)
        (ctfe.CompilerCtfeValue.CapturedExpr begin-node (Expr) pools))
      (set! (array-ref operands 2) (ctfe.CompilerCtfeValue.Bool true))
      (set! (array-ref operands 3) (host-smoke-expr int-node))
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 4 32)
      (and
        (host-smoke-close
          (and
            (host-smoke-push? 0)
            (host-smoke-ok? host.compiler-comptime-host-callback-local-set 0 0)
            (host-smoke-push? 1)
            (host-smoke-ok? host.compiler-comptime-host-callback-local-set 1 0)
            (host-smoke-push? 2)
            (host-smoke-ok? host.compiler-comptime-host-callback-local-set 2 0)
            (host-smoke-push? 3)
            (host-smoke-ok? host.compiler-comptime-host-callback-local-set 3 0)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-expr-var?
                0
                0)
              1)
            (host-smoke-ok?
              host.compiler-comptime-host-callback-local-expr-var-name
              0
              0)
            (host-smoke-commit?)
            (host-smoke-result-name? "core")
            (host-smoke-consume-test-result!)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-expr-begin?
                1
                0)
              1)
            (host-smoke-ok?
              host.compiler-comptime-host-callback-local-expr-begin-items
              1
              0)
            (host-smoke-commit?)
            (host-smoke-result-captured-begin-items? item-node)
            (host-smoke-consume-test-result!)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-expr-int?
                3
                0)
              1)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-expr-int-value
                3
                0)
              73)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-expr-int?
                0
                0)
              0)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-bool-value
                2
                0)
              1)
            (host-smoke-ok? host.compiler-comptime-host-callback-value-bool 0 0)
            (host-smoke-commit?)
            (host-smoke-result-bool? false)
            (host-smoke-consume-test-result!)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-bool-value
                0
                0)
              -3)
            (=
              (host-smoke-invoke
                host.compiler-comptime-host-callback-local-expr-begin?
                0
                0)
              0)))
        (begin
          (host-smoke-open! pools (ast.ast-place-shared-view operands) 4 8)
          (host-smoke-close
            (host-smoke-rejected?
              (host-smoke-invoke
                host.compiler-comptime-host-callback-value-bool
                2
                0))))
        (begin
          (host-smoke-open! pools (ast.ast-place-shared-view operands) 4 8)
          (host-smoke-close
            (and
              (host-smoke-push? 2)
              (host-smoke-ok?
                host.compiler-comptime-host-callback-local-set
                0
                0)
              (=
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-local-expr-var-name
                  0
                  0)
                tlci.tlci-host-callback-status-bad-request))))
        (begin
          (host-smoke-open! pools operands 4 8)
          (host-smoke-close
            (and
              (host-smoke-push? 0)
              (host-smoke-ok?
                host.compiler-comptime-host-callback-local-set
                0
                0)
              (=
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-local-expr-begin-items
                  0
                  0)
                tlci.tlci-host-callback-status-bad-request))))))))

;; Large module generators address locals by immediate slot. Pin the high end
;; of vector's 64-slot producer/host budget and reject the first slot beyond it.
(define (host-smoke-local-capacity-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (ctfe.CompilerCtfeValue.Bool true))
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 1 8)
      (and
        (host-smoke-close
          (and
            (host-smoke-push? 0)
            (host-smoke-ok? host.compiler-comptime-host-callback-local-set 63 0)
            (host-smoke-ok? host.compiler-comptime-host-callback-local-get 63 0)
            (host-smoke-commit?)
            (host-smoke-result-bool? true)))
        (begin
          (host-smoke-open! pools operands 1 8)
          (host-smoke-close
            (and
              (host-smoke-push? 0)
              (=
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-local-set
                  64
                  0)
                tlci.tlci-host-callback-status-bad-request))))))))

;; The native callback value stack is fuel-bounded rather than carrying a
;; second, lower fixed ceiling. Formatting a long variadic argument list is one
;; real workload whose generated transformer can exceed the initial 64 slots.
(define (host-smoke-stack-growth-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (set! (array-ref operands 0) (ctfe.CompilerCtfeValue.Bool true))
      (host-smoke-open! pools operands 1 128)
      (while (and ok (< index 65))
        (begin
          (set! ok (host-smoke-push? 0))
          (set! index (+ index 1))))
      (host-smoke-close
        (and
          ok
          (= host.compiler-comptime-host-stack-len 65)
          (>= (array-length host.compiler-comptime-host-stack) 128))))))

(define (host-smoke-result-shared-let-scope?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding-name : i64]
  [init-node : i64]
  [body-node : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr result-node _)
      (match (ast.ast-node-pool-context-expr-get pools result-node)
        [(Let let-box)
          (match (deref let-box)
            [(Let bindings actual-body)
              (and
                (= actual-body body-node)
                (= (ast.ast-let-binding-list-len (& bindings)) 1)
                (match (ast.ast-let-binding-list-get
                  (& bindings)
                  0
                  (ast.ast-let-binding-fallback))
                  [(Binding actual-name (No) borrow-node)
                    (and
                      (= actual-name binding-name)
                      (match (ast.ast-node-pool-context-expr-get
                        pools
                        borrow-node)
                        [(Borrow mutable? lifetime-id actual-init)
                          (and
                            (not mutable?)
                            (match (ast.ast-borrow-lifetime-from-id lifetime-id)
                              [(Inferred) true]
                              [_ false])
                            (= actual-init init-node))]
                        [_ false]))]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; The ownership-preserving format path uses this callback directly in native
;; macro images. Pin the direct-place form and the stable stack-base restoration
;; after the preceding growth test independently of format expansion.
(define (host-smoke-shared-let-scope-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [binding-name : i64 (ci.intern "shared")]
    [init-node : i64 (host-smoke-var pools "owner")]
    [body-node : i64
      (ast.ast-node-pool-context-expr-push pools (Var binding-name))]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 3)]
    (begin
      (set!
        (array-ref operands 0)
        (ctfe.CompilerCtfeValue.Name "shared" binding-name))
      (set! (array-ref operands 1) (host-smoke-expr init-node))
      (set! (array-ref operands 2) (host-smoke-expr body-node))
      (host-smoke-open! pools operands 3 16)
      (host-smoke-close
        (and
          (= (array-length host.compiler-comptime-host-stack) 64)
          (host-smoke-push? 0)
          (host-smoke-push? 1)
          (host-smoke-push? 2)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-shared-let-scope
            0
            0)
          (host-smoke-commit?)
          (host-smoke-result-shared-let-scope?
            pools
            binding-name
            init-node
            body-node))))))

(define (host-smoke-result-struct-get?
  [pools : (& pools ast.AstNodePoolContext)]
  [target : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node _)
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(StructGet actual field)
          (and
            (= actual target)
            (string.eq (host-smoke-syntax-name-text field) "alpha"))]
        [_ false])]
    [_ false]))

(define (host-smoke-result-struct-set?
  [pools : (& pools ast.AstNodePoolContext)]
  [target : i64]
  [field-id : i64]
  [value : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node (Unit))
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(StructSet actual-target actual-field actual-value)
          (and
            (= actual-target target)
            (= actual-field field-id)
            (= actual-value value))]
        [_ false])]
    [_ false]))

;; Computed struct assignment pops the value after the field name and target,
;; and rejects a field that is neither a String nor a Name without producing a
;; result. Refs #5999.
(define (host-smoke-struct-set-from-value-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [target-node : i64 (host-smoke-var pools "target")]
    [value-node : i64 (host-smoke-var pools "value")]
    [name-id : i64 (ci.intern "name-field")]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 4)]
    (begin
      (set! (array-ref operands 0) (host-smoke-expr target-node))
      (set!
        (array-ref operands 1)
        (ctfe.CompilerCtfeValue.Name "name-field" name-id))
      (set! (array-ref operands 2) (host-smoke-expr value-node))
      (set! (array-ref operands 3) (ctfe.CompilerCtfeValue.Bool false))
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 4 16)
      (and
        (host-smoke-close
          (and
            (host-smoke-push? 0)
            (host-smoke-push? 1)
            (host-smoke-push? 2)
            (host-smoke-ok?
              host.compiler-comptime-host-callback-expr-struct-set-from-value
              0
              0)
            (host-smoke-commit?)
            (host-smoke-result-struct-set? pools target-node name-id value-node)))
        (begin
          (host-smoke-open! pools operands 4 16)
          (host-smoke-close
            (and
              (host-smoke-push? 0)
              (host-smoke-push? 3)
              (host-smoke-push? 2)
              (host-smoke-rejected?
                (host-smoke-invoke
                  host.compiler-comptime-host-callback-expr-struct-set-from-value
                  0
                  0)))))))))

(define (host-smoke-result-tuple-ref?
  [pools : (& pools ast.AstNodePoolContext)]
  [target : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node _)
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(TupleRef actual index) (and (= actual target) (= index 1))]
        [_ false])]
    [_ false]))

(define (host-smoke-result-reflected-match?
  [pools : (& pools ast.AstNodePoolContext)]
  [scrutinee : i64]
  [body : i64]) : bool
  (match (host.compiler-comptime-host-result-value)
    [(Expr node _)
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(Match match-box)
          (match (deref match-box)
            [(Match actual arms)
              (and
                (= actual scrutinee)
                (= arms.len 1)
                (match (array-ref arms.slots 0)
                  [(Arm pattern actual-body)
                    (and
                      (= actual-body body)
                      (match pattern
                        [(Variant name args-box)
                          (let
                            [args : ast.AstPatternList (deref args-box)]
                            (and
                              (string.eq
                                (host-smoke-syntax-name-text name)
                                "Some")
                              (= args.len 2)
                              (match (array-ref args.slots 0)
                                [(Binding first)
                                  (string.eq
                                    (host-smoke-syntax-name-text first)
                                    "p0")]
                                [_ false])
                              (match (array-ref args.slots 1)
                                [(Binding second)
                                  (string.eq
                                    (host-smoke-syntax-name-text second)
                                    "p1")]
                                [_ false])))]
                        [_ false]))]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [_ false]))

;; Reflection callbacks take their type from the stack and indexes as
;; immediates: counts answer as data and consume the type, names and types
;; replace it. Their results then feed the computed projection and variant
;; match builders.
(define (host-smoke-reflection-builders-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [pair-id : i64 (ci.intern "HostSmokePair")]
    [choice-id : i64 (ci.intern "HostSmokeChoice")]
    [tuple-items : ast.AstTypeList (ast.ast-type-list-with-capacity 2)]
    [value-node : i64 (host-smoke-var pools "value")]
    [body-node : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (Bool true)))]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 5)]
    [dot : String "."]
    [prefix : String "p"]
    (begin
      (ast.ast-type-list-push
        (&mut tuple-items)
        (ast.ast-node-pool-context-type-push pools (I64)))
      (ast.ast-type-list-push
        (&mut tuple-items)
        (ast.ast-node-pool-context-type-push pools (Bool)))
      (set!
        (array-ref operands 0)
        (ctfe.CompilerCtfeValue.Type (Struct pair-id)))
      (set!
        (array-ref operands 1)
        (ctfe.CompilerCtfeValue.Type (Enum choice-id)))
      (set!
        (array-ref operands 2)
        (ctfe.CompilerCtfeValue.Type (Tuple (box tuple-items))))
      (set! (array-ref operands 3) (host-smoke-expr value-node))
      (set!
        (array-ref operands 4)
        (ctfe.CompilerCtfeValue.Expr body-node (Bool)))
      (host.compiler-comptime-host-session-open!
        pools
        operands
        5
        64
        host-smoke-cookie
        (host-smoke-reflections pools))
      (host-smoke-close
        (and
          (host-smoke-push? 0)
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-struct-field-count
              0
              0)
            2)
          (host-smoke-push? 2)
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-tuple-element-count
              0
              0)
            2)
          (host-smoke-push? 1)
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-enum-variant-count
              0
              0)
            2)
          (host-smoke-push? 1)
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-enum-variant-payload-count
              0
              0)
            2)
          (host-smoke-push? 0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-struct-field-name
            1
            0)
          (host-smoke-commit?)
          (host-smoke-result-name? "beta")
          (host-smoke-consume-test-result!)
          ;; A computed String and a reflected Name append in stack order;
          ;; struct hashing builds this `"." + field-name` key.
          (host-smoke-ok?
            host.compiler-comptime-host-callback-string-value
            (host-smoke-name-ptr dot)
            1)
          (host-smoke-push? 0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-struct-field-name
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-string-append
            0
            0)
          (host-smoke-commit?)
          (host-smoke-result-name? ".alpha")
          (host-smoke-consume-test-result!)
          (host-smoke-push? 0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-struct-field-type
            0
            0)
          (host-smoke-commit?)
          (host-smoke-result-type? false)
          (host-smoke-consume-test-result!)
          (host-smoke-push? 2)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-tuple-element-type
            1
            0)
          (host-smoke-commit?)
          (host-smoke-result-type? true)
          (host-smoke-consume-test-result!)
          (host-smoke-push? 1)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-enum-variant-name
            0
            0)
          (host-smoke-commit?)
          (host-smoke-result-name? "Some")
          (host-smoke-consume-test-result!)
          (host-smoke-push? 1)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-enum-variant-payload-type
            0
            1)
          (host-smoke-commit?)
          (host-smoke-result-type? true)
          (host-smoke-consume-test-result!)
          ;; Dynamic projections consume reflected names/indexes.
          (host-smoke-push? 3)
          (host-smoke-push? 0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-struct-field-name
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-struct-get-from-value
            0
            0)
          (host-smoke-commit?)
          (host-smoke-result-struct-get? pools value-node)
          (host-smoke-consume-test-result!)
          (host-smoke-push? 3)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-tuple-ref
            1
            0)
          (host-smoke-commit?)
          (host-smoke-result-tuple-ref? pools value-node)
          (host-smoke-consume-test-result!)
          ;; Assemble a variant match from a reflected name and dense
          ;; generated payload bindings.
          (host-smoke-push? 3)
          (host-smoke-push? 1)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-enum-variant-name
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-string-value
            (host-smoke-name-ptr prefix)
            (string.string-length prefix))
          (host-smoke-ok?
            host.compiler-comptime-host-callback-pattern-list-bindings
            2
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-pattern-variant-from-value
            0
            0)
          (host-smoke-push? 4)
          (host-smoke-ok? host.compiler-comptime-host-callback-match-arm 0 0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-match-arm-list-empty
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-match-arm-list-cons-from-values
            0
            0)
          (host-smoke-ok? host.compiler-comptime-host-callback-expr-match 0 0)
          (host-smoke-commit?)
          (host-smoke-result-reflected-match? pools value-node body-node))))))

;; Dense binding construction charges one unit per generated payload binding
;; and rejects the request before allocating when the shared session budget is
;; too small.
(define (host-smoke-pattern-binding-fuel-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [prefix : String "p"]
    (begin
      (host-smoke-open! pools operands 0 1)
      (host-smoke-close
        (and
          (host-smoke-ok?
            host.compiler-comptime-host-callback-string-value
            (host-smoke-name-ptr prefix)
            (string.string-length prefix))
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-pattern-list-bindings
              2
              0)
            tlci.tlci-host-callback-status-fuel-exhausted))))))

;; Native sequence folds must publish the same exact-root hygiene exemption as
;; their interpreted CTFE counterparts. Otherwise a later handoff clones and
;; reattributes captured caller syntax through the macro definition context.
(define (host-smoke-expr-list-fold-hygiene-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [condition-node : i64 (host-smoke-var pools "flag")]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (ctfe.CompilerCtfeValue.ExprList
          (ast.ast-expr-cons condition-node (ast.ast-expr-list-new))))
      (ctfe.ctfe-result-hygiene-free-reset!)
      (host-smoke-open! pools operands 1 8)
      (host-smoke-close
        (and
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-bool-literal
            1
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-bool-literal
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-list-fold-if
            0
            1)
          (host-smoke-commit?)
          (host-smoke-result-is-hygiene-free?))))))

(define (host-smoke-clause-list-fold-hygiene-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [condition-node : i64 (host-smoke-var pools "flag")]
    [result-node : i64
      (ast.ast-node-pool-context-expr-push pools (Literal (Bool true)))]
    [else-node : i64 (host-smoke-var pools "else")]
    [clauses : ast.AstExprClauseList (ast.ast-expr-clause-list-new)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    (begin
      (ast.ast-expr-clause-list-push
        (&mut clauses)
        (ast.ast-expr-clause condition-node result-node))
      (ast.ast-expr-clause-list-push
        (&mut clauses)
        (ast.ast-expr-clause else-node result-node))
      (set!
        (array-ref operands 0)
        (ctfe.CompilerCtfeValue.ExprClauseList clauses))
      (ctfe.ctfe-result-hygiene-free-reset!)
      (host-smoke-open! pools operands 1 8)
      (host-smoke-close
        (and
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-bool-literal
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-bool-literal
            0
            0)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-clause-list-fold-if
            0
            0)
          (host-smoke-commit?)
          (host-smoke-result-is-hygiene-free?))))))

(define (host-smoke-call-provenance-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [macro-name : String "nested-macro"]
    (begin
      (ctfe.ctfe-visible-macro-names-reset!)
      (ctfe.ctfe-visible-macro-name-add!
        (ci.intern (ast.ast-place-shared-view macro-name)))
      (ctfe.ctfe-result-macro-provenance-reset!)
      (host-smoke-open! pools operands 0 8)
      (host-smoke-close
        (and
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-var
            (host-smoke-name-ptr macro-name)
            (string.string-length macro-name))
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-list-empty
            0
            0)
          (host-smoke-ok? host.compiler-comptime-host-callback-expr-call 0 0)
          (ctfe.ctfe-result-may-contain-macro?))))))

;; One invocation owns one public result slot. A buggy native entry must not
;; overwrite its first committed handle; the second commit is a bad request,
;; leaves the first value intact, and poisons the remainder of the session.
(define (host-smoke-single-commit-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (ctfe.CompilerCtfeValue.Bool true))
      (host-smoke-open! pools operands 1 8)
      (host-smoke-close
        (and
          (host-smoke-push? 0)
          (host-smoke-commit?)
          (host-smoke-ok?
            host.compiler-comptime-host-callback-expr-bool-literal
            0
            0)
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-commit-result
              0
              0)
            tlci.tlci-host-callback-status-bad-request)
          (host-smoke-result-bool? true)
          (=
            (host-smoke-invoke
              host.compiler-comptime-host-callback-expr-unit-literal
              0
              0)
            tlci.tlci-host-callback-status-bad-request))))))

;; Statuses: stale cookie, empty-stack commit, and fuel exhaustion all answer
;; without committing state.
(define (host-smoke-status-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    (begin
      (host-smoke-open! pools (ast.ast-place-shared-view operands) 0 1)
      (and
        (=
          (host.compiler-comptime-host-callback-expr-list-empty 0x9999 0 0 0)
          tlci.tlci-host-callback-status-bad-request)
        (=
          (host-smoke-invoke
            host.compiler-comptime-host-callback-commit-result
            0
            0)
          tlci.tlci-host-callback-status-bad-request)
        (=
          (host-smoke-invoke
            host.compiler-comptime-host-callback-fuel-check
            0
            0)
          tlci.tlci-host-callback-status-bad-request)
        (begin
          (host.compiler-comptime-host-session-close!)
          (host-smoke-open! pools operands 0 1)
          true)
        (host-smoke-ok? host.compiler-comptime-host-callback-fuel-check 0 0)
        (=
          (host-smoke-invoke
            host.compiler-comptime-host-callback-fuel-check
            0
            0)
          tlci.tlci-host-callback-status-fuel-exhausted)
        (=
          (host-smoke-invoke
            host.compiler-comptime-host-callback-expr-list-empty
            0
            0)
          tlci.tlci-host-callback-status-fuel-exhausted)
        (not (host.compiler-comptime-host-result-ready?))))))

;; The fixed abort-table callback latches status 3 after an entry has staged a
;; value but before commit. The attempted commit must return that status and
;; leave the public result slot empty.
(define (host-smoke-abort-no-commit-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue 1)]
    [message : String "native comptime abort control"]
    (begin
      (set! (array-ref operands 0) (ctfe.CompilerCtfeValue.Bool true))
      (host-smoke-open! pools operands 1 8)
      (and
        (host-smoke-push? 0)
        (=
          (host.compiler-comptime-host-callback-abort
            host-smoke-cookie
            7
            (host-smoke-name-ptr message)
            (string.string-length message)
            0)
          tlci.tlci-host-callback-status-ok)
        (=
          (host-smoke-invoke
            host.compiler-comptime-host-callback-commit-result
            0
            0)
          tlci.tlci-host-callback-status-abort)
        (not (host.compiler-comptime-host-result-ready?))))))

(define (host-smoke-closed-session-ok?) : bool
  (begin
    (host.compiler-comptime-host-session-close!)
    (=
      (host-smoke-invoke
        host.compiler-comptime-host-callback-expr-list-empty
        0
        0)
      tlci.tlci-host-callback-status-bad-request)))

(define (host-smoke-table-ok?) : bool
  (match (tlci.tlci-validate-host-callback-table
    (host.compiler-comptime-host-table))
    [(Ok) true]
    [(Err _) false]))

(define (main) : i64
  (cond
    [(not (host-smoke-construct-ok?))
      (io.panic "comptime host smoke: construction")]
    [(not (host-smoke-run-ops-construct-ok?))
      (io.panic "comptime host smoke: run-ops construction")]
    [(not (host-smoke-run-ops-rejects-ok?))
      (io.panic "comptime host smoke: run-ops rejections")]
    [(not (host-smoke-type-kind-data-ok?))
      (io.panic "comptime host smoke: type-kind data status")]
    [(not (host-smoke-type-slice-ok?))
      (io.panic "comptime host smoke: type-slice callback")]
    [(not (host-smoke-type-tuple-ok?))
      (io.panic "comptime host smoke: type-tuple callback")]
    [(not (host-smoke-type-var-args-ok?))
      (io.panic "comptime host smoke: type-var-args callback")]
    [(not (host-smoke-array-take-ok?))
      (io.panic "comptime host smoke: array-take callback")]
    [(not (host-smoke-expr-typed-binding-ok?))
      (io.panic "comptime host smoke: expression-typed binding callback")]
    [(not (host-smoke-local-values-ok?))
      (io.panic "comptime host smoke: local value callbacks")]
    [(not (host-smoke-local-capacity-ok?))
      (io.panic "comptime host smoke: local capacity callbacks")]
    [(not (host-smoke-stack-growth-ok?))
      (io.panic "comptime host smoke: value stack growth")]
    [(not (host-smoke-shared-let-scope-ok?))
      (io.panic "comptime host smoke: shared let scope callback")]
    [(not (host-smoke-reflection-builders-ok?))
      (io.panic "comptime host smoke: reflection builders")]
    [(not (host-smoke-struct-set-from-value-ok?))
      (io.panic "comptime host smoke: computed struct set")]
    [(not (host-smoke-pattern-binding-fuel-ok?))
      (io.panic "comptime host smoke: pattern binding fuel")]
    [(not (host-smoke-expr-list-fold-hygiene-ok?))
      (io.panic "comptime host smoke: expression fold hygiene")]
    [(not (host-smoke-clause-list-fold-hygiene-ok?))
      (io.panic "comptime host smoke: clause fold hygiene")]
    [(not (host-smoke-call-provenance-ok?))
      (io.panic "comptime host smoke: call provenance")]
    [(not (host-smoke-single-commit-ok?))
      (io.panic "comptime host smoke: single result commit")]
    [(not (host-smoke-status-ok?))
      (io.panic "comptime host smoke: status contract")]
    [(not (host-smoke-abort-no-commit-ok?))
      (io.panic "comptime host smoke: abort no-partial-commit contract")]
    [(not (host-smoke-closed-session-ok?))
      (io.panic "comptime host smoke: closed session")]
    [(not (host-smoke-table-ok?)) (io.panic "comptime host smoke: host table")]
    [else 42]))