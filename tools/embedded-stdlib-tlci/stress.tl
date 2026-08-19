;; Sustained-dispatch stress harness for the mapped embedded image (refs #5528,
;; #5460).
;;
;; #5460 saw machine-dependent corruption after roughly 13.5k catalog calls: a
;; registration shell returned its impossible status-1 sentinel, which can only
;; happen if the `count` argument arriving at the mapped entry was clobbered.
;; Existing coverage is three dispatches (`verify.tl`), four orders of magnitude
;; below that, so nothing proves the raw bridge survives the scale at which the
;; failure appears.
;;
;; The three tiers separate production entry shapes so a failure names one:
;;
;; - tier 1 dispatches the final macro moved off a shell, text_buf/append!,
;;   through its two fixed operands and dynamic set!-place callback chain.
;; - tier 2 dispatches array/length over one set of operands built before the
;;   loop, auditing the session arguments the callbacks read after every
;;   dispatch.
;; - tier 3 runs the same native entry but captures pools and pushes a fresh
;;   operand every iteration. A failure here with tier 2 clean is the
;;   per-iteration session/pool cycling.
;;
;; Progress is written as a fixed-size record before and after each checkpoint
;; so a crash leaves actionable evidence: stderr/stdout are buffered and were
;; lost in the original investigation.
;;
;; usage: stress <tier> <iterations> <progress-file>   (tier: 1, 2, or 3)
(import compiler_embedded_stdlib_tlci)
(import tlci_core)
(import tlci_loader)
(import compiler_ast_types)
(import compiler_ctfe)
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(defmacro (stress-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(define stress-cookie : i64
  0x5528)

;: Entry dispatched by tier 1. This is intentionally the final macro moved off
;: its registration shell: the stress gate now proves its dynamic unquoted
;: set!-place path remains native under sustained dispatch. Refs #6550.
(define stress-tier1-identity : String
  "stdlib.text_buf/append!")

;: Canary words written around the dispatch state and re-checked every
;: iteration. A wild write from the bridge lands here rather than going
;: unnoticed.
(define stress-canary-a : i64
  0x5A5A5A5A5A5A5A5A)
(define stress-canary-b : i64
  0x3C3C3C3C3C3C3C3C)

;: Distinct exit statuses; the issue requires that failures not collapse to a
;: single boolean.
(define stress-status-ok : i64
  42)
(define stress-status-load-failed : i64
  10)
(define stress-status-tier1-session : i64
  11)
(define stress-status-dispatch-error : i64
  12)
(define stress-status-bad-status : i64
  13)
(define stress-status-missing-result : i64
  14)
(define stress-status-canary-clobbered : i64
  15)
(define stress-status-release-failed : i64
  16)
(define stress-status-tier3-status : i64
  17)
(define stress-status-tier3-no-result : i64
  18)
(define stress-status-tier3-shape : i64
  19)
(define stress-status-tier2-status : i64
  20)
(define stress-status-tier2-no-result : i64
  21)
(define stress-status-tier2-shape : i64
  22)
(define stress-status-tier2-operand-clobbered : i64
  23)
(define stress-status-tier2-count-clobbered : i64
  24)
(define stress-status-tier2-cookie-clobbered : i64
  25)
(define stress-status-tier2-stack-not-drained : i64
  26)

;: Fixed-size progress record. Every field is padded so the file length never
;: changes: a torn or truncated file is itself a signal, and the last complete
;: record survives a crash.
(define (stress-pad [text : String] [width : i64]) : String
  (let
    [len : i64 (string.string-length text)]
    (if (>= len width)
      text
      (stress-pad (str_cat.str-cat "0" text) width))))

(define (stress-progress-write!
  [path : String]
  [tier : i64]
  [iteration : i64]
  [status : i64]
  [canary-a : i64]
  [canary-b : i64]) : unit
  (let
    [contents : String
      (str_cat.str-cat
        "tier="
        (stress-pad (string.int->string tier) 4)
        " iter="
        (stress-pad (string.int->string iteration) 12)
        " status="
        (stress-pad (string.int->string status) 6)
        " canary-a-ok="
        (stress-pad
          (string.int->string
            (if (= canary-a stress-canary-a)
              1
              0))
          2)
        " canary-b-ok="
        (stress-pad
          (string.int->string
            (if (= canary-b stress-canary-b)
              1
              0))
          2)
        "\n")]
    (io.write-file path (byte_buf.str-as-bytes (& contents)))))

;: Both canaries intact. Extracted so each tier's guard chain stays a flat
;: `cond` rather than a nested if-ladder.
(define (stress-canaries-ok? [canaries : (__tl_dyn-array i64)]) : bool
  (and
    (= (array-ref canaries 0) stress-canary-a)
    (= (array-ref canaries 1) stress-canary-b)))

;: Build the two parsed-call operands for text_buf/append! once. The first is
;: the Expr place selected by the dynamic set! callback and the second is the
;: runtime String expression spliced into the expansion. Their pools and
;: storage remain fixed while each dispatch gets the required fresh session.
(define (stress-tier1-operands [pools : compiler_ast_types.AstNodePoolContext]) : (__tl_dyn-array
    compiler_ctfe.CompilerCtfeValue)
  (let
    [place-node : i64
      (compiler_ast_types.ast-expr-spanned-with-pools
        pools
        (compiler_ast_types.ast-node-pool-context-expr-push
          pools
          (compiler_ast_types.AstExpr.Var (ci.intern "buf")))
        (compiler_ast_types.ast-source-span 900 7 900 10))]
    [chunk-node : i64
      (compiler_ast_types.ast-expr-spanned-with-pools
        pools
        (compiler_ast_types.ast-node-pool-context-expr-push
          pools
          (compiler_ast_types.AstExpr.Literal
            (compiler_ast_types.AstLiteral.String (ci.intern "x"))))
        (compiler_ast_types.ast-source-span 900 12 900 15))]
    (__tl_make-array
      (compiler_ctfe.CompilerCtfeValue.Expr
        place-node
        (compiler_ast_types.AstType.Expr))
      (compiler_ctfe.CompilerCtfeValue.Expr
        chunk-node
        (compiler_ast_types.AstType.String)))))

;: Tier 1: sustained dispatch of the newly native dynamic set!-place entry.
;: Returns `stress-status-ok` or the first distinguishing failure status;
;: `failed-at` records the iteration.
(define (stress-tier1
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [iterations : i64]
  [progress-path : String]
  [failed-at : (__tl_dyn-array i64)]) : i64
  (let
    [canaries : (__tl_dyn-array i64) (array.make-array i64 2)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (stress-tier1-operands pools)]
    [i : i64 0]
    [outcome : i64 stress-status-ok]
    (begin
      (set! (array-ref canaries 0) stress-canary-a)
      (set! (array-ref canaries 1) stress-canary-b)
      (while (and (= outcome stress-status-ok) (< i iterations))
        (begin
          ;; Checkpoint before the crossing, so a crash inside the bridge is
          ;; attributable to this exact iteration.
          (when
            (= (% i 1000) 0)
            (stress-progress-write!
              progress-path
              1
              i
              0
              (array-ref canaries 0)
              (array-ref canaries 1)))
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            2
            64
            stress-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            (stress-global-shared-view stress-tier1-identity)
            stress-cookie
            (array.make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _)
              (set! outcome stress-status-dispatch-error)]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (let
                [status : i64 dispatch.status]
                (cond
                  [(not (= status tlci_core.tlci-host-callback-status-ok))
                    (begin
                      (stress-progress-write!
                        progress-path
                        1
                        i
                        status
                        (array-ref canaries 0)
                        (array-ref canaries 1))
                      (set! outcome stress-status-bad-status))]
                  [(not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))
                    (set! outcome stress-status-missing-result)]
                  [(or
                      (not
                        (=
                          compiler_embedded_stdlib_tlci.compiler-comptime-host-operand-count
                          2))
                      (not
                        (=
                          compiler_embedded_stdlib_tlci.compiler-comptime-host-session-cookie
                          stress-cookie))
                      (not
                        (=
                          compiler_embedded_stdlib_tlci.compiler-comptime-host-stack-len
                          0)))
                    (set! outcome stress-status-tier1-session)]
                  [(not (stress-canaries-ok? canaries))
                    (set! outcome stress-status-canary-clobbered)]
                  [else unit]))])
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (when
            (not (= outcome stress-status-ok))
            (set! (array-ref failed-at 0) i))
          (set! i (+ i 1))))
      (stress-progress-write!
        progress-path
        1
        i
        outcome
        (array-ref canaries 0)
        (array-ref canaries 1))
      outcome)))

;; The expansion carries the template's `Spanned` wrappers, the way the
;; interpreted quote leaves them, so the shape probe reads through them.
(define (stress-expr-get
  [pools : compiler_ast_types.AstNodePoolContext]
  [node : i64]) : compiler_ast_types.AstExpr
  (let
    [expr : compiler_ast_types.AstExpr
      (compiler_ast_types.ast-node-pool-context-expr-get pools node)]
    (match (clone expr)
      [(compiler_ast_types.AstExpr.Spanned inner _)
        (stress-expr-get pools inner)]
      [_ expr])))

;; The operand is the node a parsed call site would hand over, so it carries
;; its own span: substitution into the template's unquote position keeps that
;; origin and the argument stays the very node passed in.
(define (stress-operand-node [pools : compiler_ast_types.AstNodePoolContext]) : i64
  (compiler_ast_types.ast-expr-spanned-with-pools
    (compiler_ast_types.ast-node-pool-context-shared-view (& pools))
    (compiler_ast_types.ast-node-pool-context-expr-push
      (compiler_ast_types.ast-node-pool-context-shared-view (& pools))
      (compiler_ast_types.AstExpr.Var (ci.intern "xs")))
    (compiler_ast_types.ast-source-span 900 7 900 9)))

;: The committed expansion `stdlib.array/length` must produce, checked every
;: iteration so a silently wrong commit cannot pass as a clean run.
(define (stress-tier3-result-ok?
  [pools : compiler_ast_types.AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (stress-expr-get
        (compiler_ast_types.ast-node-pool-context-shared-view (& pools))
        node)
        [(compiler_ast_types.AstExpr.Call callee-id args)
          (and
            (match (stress-expr-get
              (compiler_ast_types.ast-node-pool-context-shared-view (& pools))
              callee-id)
              [(compiler_ast_types.AstExpr.Var name-id)
                (=
                  name-id
                  (ci.intern-template-source-id (ci.intern "__tl_array-length")))]
              [_ false])
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1)
            (=
              (compiler_ast_types.ast-expr-list-get (& args) 0 -1)
              operand-node))]
        [_ false])]
    [_ false]))

;: Native entry dispatched by tier 3: it drives real host callbacks and commits
;: an AST result, so this tier crosses the bridge, the callback trampoline, and
;: the pool commit path together. `verify.tl` pins its expansion shape.
(define stress-native-identity : String
  "stdlib.array/length")

;: The session state a callback reads on entry, re-checked after every
;: dispatch. #5460's signature was a `count` argument that did not survive the
;: crossing, so the argument the host callbacks see is exactly the thing to
;: watch: `operand-count` is that count, the operand slot is what an operand
;: query returns, and the cookie is the token every callback validates before
;: acting. A drained stack proves the entry balanced its pushes and pops.
(define (stress-tier2-session-ok?
  [expected-operand-node : i64]
  [outcome : (__tl_dyn-array i64)]) : bool
  (cond
    [(not
        (= compiler_embedded_stdlib_tlci.compiler-comptime-host-operand-count 1))
      (begin
        (set! (array-ref outcome 0) stress-status-tier2-count-clobbered)
        false)]
    [(not
        (match (array-ref
          (stress-global-shared-view
            compiler_embedded_stdlib_tlci.compiler-comptime-host-operands)
          0)
          [(compiler_ctfe.CompilerCtfeValue.Expr node _)
            (= node expected-operand-node)]
          [_ false]))
      (begin
        (set! (array-ref outcome 0) stress-status-tier2-operand-clobbered)
        false)]
    [(not
        (=
          compiler_embedded_stdlib_tlci.compiler-comptime-host-session-cookie
          stress-cookie))
      (begin
        (set! (array-ref outcome 0) stress-status-tier2-cookie-clobbered)
        false)]
    [(not (= compiler_embedded_stdlib_tlci.compiler-comptime-host-stack-len 0))
      (begin
        (set! (array-ref outcome 0) stress-status-tier2-stack-not-drained)
        false)]
    [else true]))

;: Tier 2 dispatches the same native entry tier 3 uses, so those two tiers
;: differ in exactly one variable -- tier 3 captures pools and pushes a fresh
;: operand every iteration, while tier 2 holds both for the whole run. Both
;: open the fresh per-invocation host session required by SPEC 5.17.1.1. A tier
;: 3 failure with tier 2 clean therefore isolates per-iteration pool/operand
;: cycling; tier 1 independently stresses append!'s two-operand callback chain.
;;
;; Note on "does not allocate AST nodes" in #5528's tier list: no stdlib entry
;; drives host callbacks without allocating its own expansion, so what tier 2
;; holds fixed is the harness's allocation -- operands and pools are built once,
;; before the loop. The entry's expansion still allocates, as it must.
;;
;; What tier 2 adds beyond running the same entry as tier 3 is the per-iteration
;; audit of the session arguments themselves, which neither other tier performs
;; and which is the integrity #5460's corrupted-argument symptom actually
;; implicates. Refs #5528, #5460.
(define (stress-tier2
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [iterations : i64]
  [progress-path : String]
  [failed-at : (__tl_dyn-array i64)]) : i64
  (let
    [canaries : (__tl_dyn-array i64) (array.make-array i64 2)]
    [pools : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-context-capture-active)]
    [operand-node : i64 (stress-operand-node pools)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (array.make-array compiler_ctfe.CompilerCtfeValue 1)]
    [detail : (__tl_dyn-array i64) (__tl_make-array stress-status-ok)]
    [i : i64 0]
    [outcome : i64 stress-status-ok]
    (begin
      (set! (array-ref canaries 0) stress-canary-a)
      (set! (array-ref canaries 1) stress-canary-b)
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          operand-node
          (compiler_ast_types.AstType.Expr)))
      (while (and (= outcome stress-status-ok) (< i iterations))
        (begin
          (when
            (= (% i 1000) 0)
            (stress-progress-write!
              progress-path
              2
              i
              0
              (array-ref canaries 0)
              (array-ref canaries 1)))
          ;; Keep the mapped image, pools, and operand storage alive across the
          ;; run, but give each entry invocation its transactional result slot.
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            1
            64
            stress-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            (stress-global-shared-view stress-native-identity)
            stress-cookie
            (array.make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _)
              (set! outcome stress-status-dispatch-error)]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (cond
                [(not
                    (= dispatch.status tlci_core.tlci-host-callback-status-ok))
                  (begin
                    (stress-progress-write!
                      progress-path
                      2
                      i
                      dispatch.status
                      (array-ref canaries 0)
                      (array-ref canaries 1))
                    (set! outcome stress-status-tier2-status))]
                [(not
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))
                  (set! outcome stress-status-tier2-no-result)]
                [(not (stress-tier3-result-ok? pools operand-node))
                  (set! outcome stress-status-tier2-shape)]
                [(not (stress-tier2-session-ok? operand-node detail))
                  (set! outcome (array-ref detail 0))]
                [(not (stress-canaries-ok? canaries))
                  (set! outcome stress-status-canary-clobbered)]
                [else unit])])
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (when
            (not (= outcome stress-status-ok))
            (set! (array-ref failed-at 0) i))
          (set! i (+ i 1))))
      (stress-progress-write!
        progress-path
        2
        i
        outcome
        (array-ref canaries 0)
        (array-ref canaries 1))
      outcome)))

;: Tier 3: sustained dispatch of a native entry through repeated host-session
;: open/close cycles against real pools, which is the shape a macro pass runs
;: in. This is the tier that exercises the allocator and pool-commit paths
;: #5460's follow-on crashes pointed at. Refs #5528.
(define (stress-tier3
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [iterations : i64]
  [progress-path : String]
  [failed-at : (__tl_dyn-array i64)]) : i64
  (let
    [canaries : (__tl_dyn-array i64) (array.make-array i64 2)]
    [i : i64 0]
    [outcome : i64 stress-status-ok]
    (begin
      (set! (array-ref canaries 0) stress-canary-a)
      (set! (array-ref canaries 1) stress-canary-b)
      (while (and (= outcome stress-status-ok) (< i iterations))
        (let
          [pools : compiler_ast_types.AstNodePoolContext
            (compiler_ast_types.ast-node-pool-context-capture-active)]
          [operand-node : i64 (stress-operand-node pools)]
          [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
            (array.make-array compiler_ctfe.CompilerCtfeValue 1)]
          (begin
            (when
              (= (% i 1000) 0)
              (stress-progress-write!
                progress-path
                3
                i
                0
                (array-ref canaries 0)
                (array-ref canaries 1)))
            (set!
              (array-ref operands 0)
              (compiler_ctfe.CompilerCtfeValue.Expr
                operand-node
                (compiler_ast_types.AstType.Expr)))
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
              pools
              operands
              1
              64
              stress-cookie
              (compiler_ctfe.ctfe-reflect-info-list-empty))
            (match (tlci_loader.tlci-loader-dispatch-macro
              loaded
              (stress-global-shared-view stress-native-identity)
              stress-cookie
              (array.make-array i64 0)
              0)
              [(tlci_loader.ResultTlciMacroDispatch.Err _)
                (set! outcome stress-status-dispatch-error)]
              [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                (cond
                  [(not
                      (= dispatch.status tlci_core.tlci-host-callback-status-ok))
                    (begin
                      (stress-progress-write!
                        progress-path
                        3
                        i
                        dispatch.status
                        (array-ref canaries 0)
                        (array-ref canaries 1))
                      (set! outcome stress-status-tier3-status))]
                  [(not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))
                    (set! outcome stress-status-tier3-no-result)]
                  [(not (stress-tier3-result-ok? pools operand-node))
                    (set! outcome stress-status-tier3-shape)]
                  [(not (stress-canaries-ok? canaries))
                    (set! outcome stress-status-canary-clobbered)]
                  [else unit])])
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
            (when
              (not (= outcome stress-status-ok))
              (set! (array-ref failed-at 0) i))
            (set! i (+ i 1)))))
      (stress-progress-write!
        progress-path
        3
        i
        outcome
        (array-ref canaries 0)
        (array-ref canaries 1))
      outcome)))

(define (main) : i64
  (if (not (= (io.arg-count) 4))
    (begin
      (io.print-error "usage: stress <iterations> <progress-file>\n")
      2)
    (let
      [tier : i64 (string.>int (io.arg 1))]
      [iterations : i64 (string.>int (io.arg 2))]
      [progress-path : String (io.arg 3)]
      [failed-at : (__tl_dyn-array i64) (__tl_make-array -1)]
      (match (tlci_loader.tlci-loader-load-from-bytes-with-host
        (arena.tl_arena_current)
        (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-copy)
        (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
        [(tlci_loader.ResultTlciLoadedImage.Err _)
          (begin
            (io.print-error "stress: embedded image failed to load\n")
            stress-status-load-failed)]
        [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
          (let
            [outcome : i64
              (cond
                [(= tier 3)
                  (stress-tier3 (& loaded) iterations progress-path failed-at)]
                [(= tier 2)
                  (stress-tier2 (& loaded) iterations progress-path failed-at)]
                [else
                  (stress-tier1 (& loaded) iterations progress-path failed-at)])]
            (begin
              (io.print-format
                "{}"
                (str_cat.str-cat
                  "stress tier="
                  (string.int->string tier)
                  " identity="
                  (if (= tier 1)
                    (stress-global-shared-view stress-tier1-identity)
                    (stress-global-shared-view stress-native-identity))
                  " iterations="
                  (string.int->string iterations)
                  " outcome="
                  (string.int->string outcome)
                  " failed-at="
                  (string.int->string (array-ref failed-at 0))
                  "\n"))
              (match (tlci_loader.tlci-loader-release loaded)
                [(tlci_loader.ResultTlciLoaderUnit.Ok) outcome]
                [(tlci_loader.ResultTlciLoaderUnit.Err _)
                  stress-status-release-failed])))]))))