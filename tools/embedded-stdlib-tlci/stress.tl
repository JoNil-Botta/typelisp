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
;; Tier 1 isolates the narrowest layer: repeated dispatch of a *shell* entry,
;; which crosses `tl_tlci_call_macro_entry` and the inbound trampoline but
;; invokes no host callback and commits no AST. A failure here is a pure
;; call-bridge/argument-marshalling defect; a clean run exonerates that layer
;; and moves the search to the callback and pool tiers.
;;
;; Progress is written as a fixed-size record before and after each checkpoint
;; so a crash leaves actionable evidence: stderr/stdout are buffered and were
;; lost in the original investigation.
;;
;; usage: stress <tier> <iterations> <progress-file>   (tier: 1 or 3)
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
                (if (not (= status tlci-host-callback-status-ok))
                  ;; This is #5460's signature: a shell reporting anything but
                  ;; ok means its `count` argument did not survive the bridge.
                  (begin
                    (stress-progress-write!
                      progress-path
                      1
                      i
                      status
                      (array-ref canaries 0)
                      (array-ref canaries 1))
                    (set! outcome stress-status-bad-status))
                  (if (compiler-comptime-host-result-ready?)
                    (set! outcome stress-status-unexpected-result)
                    (if (or
                      (not (= (array-ref canaries 0) stress-canary-a))
                      (not (= (array-ref canaries 1) stress-canary-b)))
                      (set! outcome stress-status-canary-clobbered)
                      unit))))])
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
                (if (not
                  (= (struct-get dispatch status) tlci-host-callback-status-ok))
                  (begin
                    (stress-progress-write!
                      progress-path
                      3
                      i
                      (struct-get dispatch status)
                      (array-ref canaries 0)
                      (array-ref canaries 1))
                    (set! outcome stress-status-tier3-status))
                  (if (not (compiler-comptime-host-result-ready?))
                    (set! outcome stress-status-tier3-no-result)
                    (if (not (stress-tier3-result-ok? pools operand-node))
                      (set! outcome stress-status-tier3-shape)
                      (if (or
                        (not (= (array-ref canaries 0) stress-canary-a))
                        (not (= (array-ref canaries 1) stress-canary-b)))
                        (set! outcome stress-status-canary-clobbered)
                        unit))))])
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
                  (if (= tier 3)
                    ;; Tier 3 owns a session per iteration, so retire the outer
                    ;; one before it starts cycling its own.
                    (begin
                      (compiler-comptime-host-session-close!)
                      (stress-tier3
                        (& loaded)
                        iterations
                        progress-path
                        failed-at))
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
                          tier1))))]
                (begin
                  (io.print-string
                    (str_cat.str-cat
                      "stress tier="
                      (string.int->string tier)
                      " identity="
                      (if (= tier 3)
                        stress-native-identity
                        stress-shell-identity)
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