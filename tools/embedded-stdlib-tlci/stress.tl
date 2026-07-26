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
;; The three tiers separate the layers so a failure names one of them:
;;
;; - tier 1 dispatches a *shell* entry, which crosses
;;   `tl_tlci_call_macro_entry` and the inbound trampoline but invokes no host
;;   callback and commits no AST. A failure here is a pure
;;   call-bridge/argument-marshalling defect.
;; - tier 2 dispatches a native entry over one session and one set of operands
;;   built before the loop, auditing the session arguments the callbacks read
;;   after every dispatch. A failure here with tier 1 clean is callback
;;   marshalling.
;; - tier 3 runs the same native entry but captures pools and pushes a fresh
;;   operand every iteration. A failure here with tier 2 clean is the
;;   per-iteration session/pool cycling.
;;
;; Progress is written as a fixed-size record before and after each checkpoint
;; so a crash leaves actionable evidence: stderr/stdout are buffered and were
;; lost in the original investigation.
;;
;; usage: stress <tier> <iterations> <progress-file>   (tier: 1, 2, or 3)
(import "../../src/compiler_embedded_stdlib_tlci.tl")
(import "../../src/tlci_core.tl")
(import "../../src/tlci_loader.tl")
(import "../../src/compiler_ast_types.tl")
(import "../../src/compiler_ctfe.tl")
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define stress-cookie : i64
  0x5528)

;: Entry dispatched by tier 1. It must be a registration shell so the crossing
;: performs no host callback; `stress-tier1-shell-ok?` asserts that before the
;: loop rather than assuming it, so the harness fails loudly if the macro later
;: becomes native instead of silently testing the wrong path.
(define stress-shell-identity : String
  "stdlib.clone/synthesize-helpers")

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
(define stress-status-not-a-shell : i64
  11)
(define stress-status-dispatch-error : i64
  12)
(define stress-status-bad-status : i64
  13)
(define stress-status-unexpected-result : i64
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
  (io.write-file
    path
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
      "\n")))

;: Both canaries intact. Extracted so each tier's guard chain stays a flat
;: `cond` rather than a nested if-ladder.
(define (stress-canaries-ok? [canaries : (Array i64)]) : bool
  (and
    (= (array-ref canaries 0) stress-canary-a)
    (= (array-ref canaries 1) stress-canary-b)))

;: Confirm the chosen identity really is a registration shell before the loop:
;: a shell commits no result and reports ok for an ordinary dispatch.
(define (stress-tier1-shell-ok? [loaded : (& loaded TlciLoadedImage)]) : bool
  (match (tlci-loader-dispatch-macro
    loaded
    stress-shell-identity
    stress-cookie
    (array.make-array i64 0)
    0)
    [(ResultTlciMacroDispatch.Err _) false]
    [(ResultTlciMacroDispatch.Ok dispatch)
      (and
        (= (struct-get dispatch status) tlci-host-callback-status-ok)
        (not (compiler-comptime-host-result-ready?)))]))

;: Tier 1: sustained raw-entry dispatch. Returns `stress-status-ok` or the
;: first distinguishing failure status; `failed-at` records the iteration.
(define (stress-tier1
  [loaded : (& loaded TlciLoadedImage)]
  [iterations : i64]
  [progress-path : String]
  [failed-at : (Array i64)]) : i64
  (let
    [canaries : (Array i64) (array.make-array i64 2)]
    [i : i64 0]
    [outcome : i64 stress-status-ok]
    (begin
      (array-set! canaries 0 stress-canary-a)
      (array-set! canaries 1 stress-canary-b)
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
          (match (tlci-loader-dispatch-macro
            loaded
            stress-shell-identity
            stress-cookie
            (array.make-array i64 0)
            0)
            [(ResultTlciMacroDispatch.Err _)
              (set! outcome stress-status-dispatch-error)]
            [(ResultTlciMacroDispatch.Ok dispatch)
              (let
                [status : i64 (struct-get dispatch status)]
                (cond
                  ;; This is #5460's signature: a shell reporting anything but
                  ;; ok means its `count` argument did not survive the bridge.
                  [(not (= status tlci-host-callback-status-ok))
                    (begin
                      (stress-progress-write!
                        progress-path
                        1
                        i
                        status
                        (array-ref canaries 0)
                        (array-ref canaries 1))
                      (set! outcome stress-status-bad-status))]
                  [(compiler-comptime-host-result-ready?)
                    (set! outcome stress-status-unexpected-result)]
                  [(not (stress-canaries-ok? canaries))
                    (set! outcome stress-status-canary-clobbered)]
                  [else unit]))])
          (when (not (= outcome stress-status-ok)) (array-set! failed-at 0 i))
          (set! i (+ i 1))))
      (stress-progress-write!
        progress-path
        1
        i
        outcome
        (array-ref canaries 0)
        (array-ref canaries 1))
      outcome)))

;: The committed expansion `stdlib.array/length` must produce, checked every
;: iteration so a silently wrong commit cannot pass as a clean run.
(define (stress-tier3-result-ok?
  [pools : AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee-id args)
          (and
            (match (ast-node-pool-context-expr-get pools callee-id)
              [(AstExpr.Var name-id)
                (=
                  name-id
                  (ci.intern-template-source-id (ci.intern "__tl_array-length")))]
              [_ false])
            (= (ast-expr-list-len (& args)) 1)
            (= (ast-expr-list-get (& args) 0 -1) operand-node))]
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
  [outcome : (Array i64)]) : bool
  (cond
    [(not (= compiler-comptime-host-operand-count 1))
      (begin
        (array-set! outcome 0 stress-status-tier2-count-clobbered)
        false)]
    [(not
        (match (array-ref compiler-comptime-host-operands 0)
          [(CompilerCtfeValue.Expr node _) (= node expected-operand-node)]
          [_ false]))
      (begin
        (array-set! outcome 0 stress-status-tier2-operand-clobbered)
        false)]
    [(not (= compiler-comptime-host-session-cookie stress-cookie))
      (begin
        (array-set! outcome 0 stress-status-tier2-cookie-clobbered)
        false)]
    [(not (= compiler-comptime-host-stack-len 0))
      (begin
        (array-set! outcome 0 stress-status-tier2-stack-not-drained)
        false)]
    [else true]))

;: Tier 2: the callback layer, between tier 1's bare crossing and tier 3's pool
;: cycling. It dispatches the same native entry tier 3 uses, so the two tiers
;: differ in exactly one variable -- tier 3 captures pools and pushes a fresh
;: operand every iteration, while tier 2 holds both for the whole run. Both
;: open the fresh per-invocation host session required by SPEC 5.17.1.1. A tier
;: 2 failure with tier 1 clean therefore isolates callback marshalling; a tier
;: 3 failure with tier 2 clean isolates per-iteration pool/operand cycling.
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
  [loaded : (& loaded TlciLoadedImage)]
  [iterations : i64]
  [progress-path : String]
  [failed-at : (Array i64)]) : i64
  (let
    [canaries : (Array i64) (array.make-array i64 2)]
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand-node : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "xs")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    [detail : (Array i64) (make-array stress-status-ok)]
    [i : i64 0]
    [outcome : i64 stress-status-ok]
    (begin
      (array-set! canaries 0 stress-canary-a)
      (array-set! canaries 1 stress-canary-b)
      (array-set!
        operands
        0
        (CompilerCtfeValue.Expr operand-node (AstType.Expr)))
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
          (compiler-comptime-host-session-open!
            pools
            operands
            1
            64
            stress-cookie
            (ctfe-reflect-info-list-empty))
          (match (tlci-loader-dispatch-macro
            loaded
            stress-native-identity
            stress-cookie
            (array.make-array i64 0)
            0)
            [(ResultTlciMacroDispatch.Err _)
              (set! outcome stress-status-dispatch-error)]
            [(ResultTlciMacroDispatch.Ok dispatch)
              (cond
                [(not
                    (=
                      (struct-get dispatch status)
                      tlci-host-callback-status-ok))
                  (begin
                    (stress-progress-write!
                      progress-path
                      2
                      i
                      (struct-get dispatch status)
                      (array-ref canaries 0)
                      (array-ref canaries 1))
                    (set! outcome stress-status-tier2-status))]
                [(not (compiler-comptime-host-result-ready?))
                  (set! outcome stress-status-tier2-no-result)]
                [(not (stress-tier3-result-ok? pools operand-node))
                  (set! outcome stress-status-tier2-shape)]
                [(not (stress-tier2-session-ok? operand-node detail))
                  (set! outcome (array-ref detail 0))]
                [(not (stress-canaries-ok? canaries))
                  (set! outcome stress-status-canary-clobbered)]
                [else unit])])
          (compiler-comptime-host-session-close!)
          (when (not (= outcome stress-status-ok)) (array-set! failed-at 0 i))
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
  [loaded : (& loaded TlciLoadedImage)]
  [iterations : i64]
  [progress-path : String]
  [failed-at : (Array i64)]) : i64
  (let
    [canaries : (Array i64) (array.make-array i64 2)]
    [i : i64 0]
    [outcome : i64 stress-status-ok]
    (begin
      (array-set! canaries 0 stress-canary-a)
      (array-set! canaries 1 stress-canary-b)
      (while (and (= outcome stress-status-ok) (< i iterations))
        (let
          [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
          [operand-node : i64
            (ast-node-pool-context-expr-push
              pools
              (AstExpr.Var (ci.intern "xs")))]
          [operands : (Array CompilerCtfeValue)
            (array.make-array CompilerCtfeValue 1)]
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
            (array-set!
              operands
              0
              (CompilerCtfeValue.Expr operand-node (AstType.Expr)))
            (compiler-comptime-host-session-open!
              pools
              operands
              1
              64
              stress-cookie
              (ctfe-reflect-info-list-empty))
            (match (tlci-loader-dispatch-macro
              loaded
              stress-native-identity
              stress-cookie
              (array.make-array i64 0)
              0)
              [(ResultTlciMacroDispatch.Err _)
                (set! outcome stress-status-dispatch-error)]
              [(ResultTlciMacroDispatch.Ok dispatch)
                (cond
                  [(not
                      (=
                        (struct-get dispatch status)
                        tlci-host-callback-status-ok))
                    (begin
                      (stress-progress-write!
                        progress-path
                        3
                        i
                        (struct-get dispatch status)
                        (array-ref canaries 0)
                        (array-ref canaries 1))
                      (set! outcome stress-status-tier3-status))]
                  [(not (compiler-comptime-host-result-ready?))
                    (set! outcome stress-status-tier3-no-result)]
                  [(not (stress-tier3-result-ok? pools operand-node))
                    (set! outcome stress-status-tier3-shape)]
                  [(not (stress-canaries-ok? canaries))
                    (set! outcome stress-status-canary-clobbered)]
                  [else unit])])
            (compiler-comptime-host-session-close!)
            (when (not (= outcome stress-status-ok)) (array-set! failed-at 0 i))
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
      [failed-at : (Array i64) (make-array -1)]
      (match (tlci-loader-load-from-bytes-with-host
        (compiler-embedded-stdlib-tlci-copy)
        (compiler-comptime-host-table))
        [(ResultTlciLoadedImage.Err _)
          (begin
            (io.print-error "stress: embedded image failed to load\n")
            stress-status-load-failed)]
        [(ResultTlciLoadedImage.Ok loaded)
          (let
            [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
            [operands : (Array CompilerCtfeValue)
              (array.make-array CompilerCtfeValue 0)]
            (begin
              ;; One session and one mapped-image lifetime for the whole run,
              ;; which is the shape #5460 failed in.
              (compiler-comptime-host-session-open!
                pools
                operands
                0
                0x7FFFFFFF
                stress-cookie
                (ctfe-reflect-info-list-empty))
              (let
                [outcome : i64
                  (cond
                    ;; Tier 3 owns a session per iteration, so retire the outer
                    ;; one before it starts cycling its own.
                    [(= tier 3)
                      (begin
                        (compiler-comptime-host-session-close!)
                        (stress-tier3
                          (& loaded)
                          iterations
                          progress-path
                          failed-at))]
                    ;; Tier 2 opens its own single session over its own operands,
                    ;; for the same reason.
                    [(= tier 2)
                      (begin
                        (compiler-comptime-host-session-close!)
                        (stress-tier2
                          (& loaded)
                          iterations
                          progress-path
                          failed-at))]
                    [else
                      (if (not (stress-tier1-shell-ok? (& loaded)))
                        ;; Record the pre-loop failure too: the issue wants a
                        ;; durable marker at every state transition, not only
                        ;; inside the loop.
                        (begin
                          (stress-progress-write!
                            progress-path
                            1
                            -1
                            stress-status-not-a-shell
                            stress-canary-a
                            stress-canary-b)
                          stress-status-not-a-shell)
                        (let
                          [tier1 : i64
                            (stress-tier1
                              (& loaded)
                              iterations
                              progress-path
                              failed-at)]
                          (begin
                            (compiler-comptime-host-session-close!)
                            tier1)))])]
                (begin
                  (io.print-string
                    (str_cat.str-cat
                      "stress tier="
                      (string.int->string tier)
                      " identity="
                      (if (= tier 1)
                        stress-shell-identity
                        stress-native-identity)
                      " iterations="
                      (string.int->string iterations)
                      " outcome="
                      (string.int->string outcome)
                      " failed-at="
                      (string.int->string (array-ref failed-at 0))
                      "\n"))
                  (match (tlci-loader-release loaded)
                    [(ResultTlciLoaderUnit.Ok) outcome]
                    [(ResultTlciLoaderUnit.Err _) stress-status-release-failed])))))]))))