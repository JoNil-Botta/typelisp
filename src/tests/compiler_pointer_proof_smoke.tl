(import stdlib.iterator)
(import compiler_lower as lower)
(import compiler_pointer_proof_input as proof)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)
(import compiler_diagnostic as diagnostic)
(import compiler_driver_core as driver)
(import compiler_backend as backend)
(import stdlib.string)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_cfg_core as cfg_core)
(import (vector.vector proof.PointerProofRef core) as refs)

(define (proof-smoke-use
  [input : proof.PointerProofInput]
  [reference : proof.PointerProofRef]) : proof.PointerProofUse
  (match (proof.pointer-proof-input-use input reference)
    [(Ok use) use]
    [_ (io.panic "pointer-proof smoke: invalid semantic reference")]))

(define (proof-smoke-reference
  [references : (& references refs.Vec)]
  [index : i64]) : proof.PointerProofRef
  (unsafe
    (ptr-read (ptr-offset (__tl_array-data references.slots) index))))

(define (proof-smoke-request
  [input : proof.PointerProofInput]
  [mode : lower.CompilerLowerMode]) : lower.CompilerLowerRequest
  (lower.CompilerLowerRequest mode (Requested input)))

(define (proof-smoke-lower
  [input : proof.PointerProofInput]
  [source : String]
  [mode : lower.CompilerLowerMode]) : String
  (let
    [request : lower.CompilerLowerRequest (proof-smoke-request input mode)]
    [lowered : lower.ResultCompilerLower
      (lower.lower-compiler-source-with-request "proof-case.tl" source request)]
    (match (lower.lower-compiler-pointer-proof-result request lowered)
      [(Err error)
        (let
          [message : diagnostic.CompilerDiagnostic (deref error)]
          (io.println "{}" (diagnostic.compiler-diagnostic-render (& message)))
          (io.panic "pointer-proof smoke: requested lowering failed"))]
      [(Ok program _ _)
        (let
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-capture-active)]
          (ir.compiler-ir-program-render
            (cis.intern-structural-session-handle-from-source-names
              (ci.intern-source-name-session-capture-active-handle))
            (ast.ast-node-pool-context-type-segment-bases pools)
            program))])))

(define (proof-smoke-has-conversion? [input : proof.PointerProofInput]) : bool
  (let
    [found : bool false]
    (for [index (iterator.range 0 (proof.pointer-proof-input-use-count input))]
      (match (proof.pointer-proof-input-use
        input
        (proof.PointerProofRef input.control index))
        [(Ok use)
          (match use.operation
            [(IntegerToPointer) (set! found true)]
            [_ unit])
          unit]
        [(Err _) (io.panic "pointer-proof smoke: missing occurrence")]))
    found))

(define (proof-smoke-distinction [mode : lower.CompilerLowerMode]) : unit
  (let
    [direct : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [converted : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [direct-ir : String
      (proof-smoke-lower
        direct
        "(define (main [p : (Ptr i64)]) : (Ptr i64) p)"
        mode)]
    [converted-ir : String
      (proof-smoke-lower
        converted
        "(define (main [p : (Ptr i64)]) : (Ptr i64) (unsafe (int->ptr (ptr->int p) : (Ptr i64))))"
        mode)]
    (unless
      (string.eq (& direct-ir) (& converted-ir))
      (io.panic "pointer-proof smoke: conversion changed ordinary machine IR"))
    (when
      (proof-smoke-has-conversion? direct)
      (io.panic
        "pointer-proof smoke: later job contaminated direct pointer evidence"))
    (unless
      (proof-smoke-has-conversion? converted)
      (io.panic "pointer-proof smoke: missing no-instruction conversion"))
    (proof.pointer-proof-input-release! direct)
    (proof.pointer-proof-input-release! converted)))

(define (proof-smoke-mixed-uses [mode : lower.CompilerLowerMode]) : unit
  (let
    [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [_ir : String
      (proof-smoke-lower
        input
        "(define (main [p : (Ptr i64)] [b : bool]) : (Ptr i64) (if b p (unsafe (int->ptr (ptr->int p) : (Ptr i64)))))"
        mode)]
    [reads : i64 0]
    [joined : bool false]
    [conversion-span : bool false]
    (for [index (iterator.range 0 (proof.pointer-proof-input-use-count input))]
      (match (proof.pointer-proof-input-use
        input
        (proof.PointerProofRef input.control index))
        [(Err _) (io.panic "pointer-proof smoke: missing mixed use")]
        [(Ok use)
          (match use.operation
            [(Read binding) (when (= binding 0) (+= reads 1))]
            [(Join) (set! joined true)]
            [(IntegerToPointer)
              (match use.span
                [(Some span)
                  (set! conversion-span (> (cast span.start-col : i64) 70))]
                [_ unit])]
            [_ unit])
          unit]))
    (unless
      (and (= reads 2) joined conversion-span)
      (io.panic
        "pointer-proof smoke: same-var alternatives or conversion source lost"))
    (proof.pointer-proof-input-release! input)))

(define (proof-smoke-missing-input [mode : lower.CompilerLowerMode]) : unit
  (let
    [request : lower.CompilerLowerRequest
      (lower.CompilerLowerRequest mode Disabled)]
    [plain : lower.ResultCompilerLower
      (lower.lower-compiler-source-with-mode
        "(define (main [p : (Ptr i64)]) : (Ptr i64) p)"
        mode)]
    (match (lower.lower-compiler-pointer-proof-result request plain)
      [(Err _) unit]
      [_
        (io.panic
          "pointer-proof smoke: ordinary lowering admitted missing input")])))

(define (proof-smoke-emit
  [input : proof.PointerProofInput]
  [source : String]
  [mode : lower.CompilerLowerMode]
  [target : backend.CompilerBackendTarget]
  [level : i64]
  [requested? : bool]) : String
  (let
    [request : lower.CompilerLowerRequest (proof-smoke-request input mode)]
    [lowered : lower.ResultCompilerLower
      (if requested?
        (lower.lower-compiler-source-with-request
          "proof-parity.tl"
          source
          (owned_view.compiler-owned-shared-view request))
        (lower.lower-compiler-source-with-path-mode
          "proof-parity.tl"
          source
          mode))]
    (match lowered
      [(Err _) (io.panic "pointer-proof smoke: parity source did not lower")]
      [(Ok program spans)
        (when
          requested?
          (match (lower.lower-compiler-pointer-proof-result
            request
            (Ok
              (owned_view.compiler-owned-shared-view program)
              (owned_view.compiler-owned-shared-view spans)))
            [(Ok _ _ _) unit]
            [_ (io.panic "pointer-proof smoke: parity proof is incomplete")]))
        (let
          [emitted : driver.ResultCompilerDriver
            (driver.compiler-driver-emit-lowered-with-level-and-mode
              "proof-parity.tl"
              program
              spans
              target
              true
              Scalar
              level)]
          (ast.ast-node-pool-reader-clear!)
          (match emitted
            [(Ok assembly _) assembly]
            [_ (io.panic "pointer-proof smoke: parity emission failed")]))])))

(define (proof-smoke-parity
  [source : String]
  [mode : lower.CompilerLowerMode]
  [target : backend.CompilerBackendTarget]) : unit
  (for [level (iterator.range 0 3)]
    (let
      [plain-input : proof.PointerProofInput (proof.pointer-proof-input-new)]
      [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
      [plain : String
        (proof-smoke-emit
          plain-input
          (owned_view.compiler-owned-shared-view source)
          mode
          target
          level
          false)]
      [requested : String
        (proof-smoke-emit
          input
          (owned_view.compiler-owned-shared-view source)
          mode
          target
          level
          true)]
      (unless
        (and
          (string.eq (& plain) (& requested))
          (= (proof.pointer-proof-input-use-count plain-input) 0))
        (io.panic
          "pointer-proof smoke: requested/ordinary opt0/1/2 assembly differs"))
      (proof.pointer-proof-input-release! plain-input)
      (proof.pointer-proof-input-release! input))))

(define (proof-smoke-interactions
  [mode : lower.CompilerLowerMode]
  [target : backend.CompilerBackendTarget]) : unit
  (let
    [sources : (Array String 6)
      (array
        "(define (main [p : (Ptr i64)]) : (Ptr i64) (unsafe (ptr-cast (ptr-cast p : (MutPtr u8)) : (Ptr i64))))"
        "(define (main [p : (MutPtr i64)]) : (MutPtr i64) (unsafe (ptr-offset (ptr-cast (ptr-cast p : (Ptr u8)) : (MutPtr i64)) 1)))"
        "(define (main [p : (Ptr i64)] [b : bool]) : (Ptr i64) (let [q : (Ptr i64) p] (begin (when b (set! q (unsafe (int->ptr (ptr->int p) : (Ptr i64))))) q)))"
        "(define (pass [p : (Ptr i64)]) : (Ptr i64) p) (define (main [p : (Ptr i64)] [b : bool]) : (Ptr i64) (if b (pass p) (pass (unsafe (int->ptr (ptr->int p) : (Ptr i64))))))"
        "(define (step [p : (Ptr i64)] [n : i64]) : (Ptr i64) (if (= n 0) (return p) (step p (- n 1)))) (define (main [p : (Ptr i64)]) : (Ptr i64) (if (ptr-null? p) (ptr-null : (Ptr i64)) (step p 2)))"
        "(define (pass [comptime T : type] [p : (Ptr T)]) : (Ptr T) p) (define (main [p : (Ptr i64)]) : (Ptr i64) (pass (type i64) p))")]
    (for [index (iterator.range 0 6)]
      (proof-smoke-parity
        (owned_view.compiler-owned-array-element-shared-view sources index)
        mode
        target))))

(define (proof-smoke-unsupported-producer-source) : String
  "(define (main [p : (Ptr i64)] [b : bool]) : (Ptr i64) (match b [true p] [false (ptr-null : (Ptr i64))]))")

;; The pattern binder `g` shadows the global `g`. The capture does not model
;; pattern bindings, so a read of `g` must not resolve to the global: the
;; arm assigns the round-tripped scrutinee to `r`, not the global's value.
(define (proof-smoke-unmodelled-binder-source) : String
  "(define g : (Ptr i64) (ptr-null : (Ptr i64)))
(defenum Holder (H (Ptr i64)))
(define (main [p : (Ptr i64)]) : (Ptr i64)
  (let
    [r : (Ptr i64) p]
    (begin
      (match (Holder.H (unsafe (int->ptr (ptr->int p) : (Ptr i64))))
        [(Holder.H g) (set! r g)])
      r)))")

(define (proof-smoke-unsupported
  [mode : lower.CompilerLowerMode]
  [source : String]) : unit
  (let
    [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [request : lower.CompilerLowerRequest (proof-smoke-request input mode)]
    [lowered : lower.ResultCompilerLower
      (lower.lower-compiler-source-with-request
        "unsupported-proof.tl"
        source
        (owned_view.compiler-owned-shared-view request))]
    (match (lower.lower-compiler-pointer-proof-result request lowered)
      [(Err error)
        (let
          [message : diagnostic.CompilerDiagnostic (deref error)]
          (unless
            (and
              (string.eq
                (diagnostic.compiler-diagnostic-path (& message))
                "unsupported-proof.tl")
              (string.eq
                (diagnostic.compiler-diagnostic-message (& message))
                "pointer proof: unsupported semantic pointer operation"))
            (begin
              (io.println
                "{}"
                (diagnostic.compiler-diagnostic-render (& message)))
              (io.panic
                "pointer-proof smoke: unsupported producer lacks source rejection"))))]
      [_
        (io.panic
          "pointer-proof smoke: unclassified pointer producer was admitted")])
    (proof.pointer-proof-input-release! input)))

(define (proof-smoke-bindings [mode : lower.CompilerLowerMode]) : unit
  (let
    [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [_ir : String
      (proof-smoke-lower
        input
        "(define (pass [comptime T : type] [p : (Ptr T)]) : (Ptr T) p) (define (step [p : (Ptr i64)] [n : i64]) : (Ptr i64) (if (= n 0) (return p) (step p (- n 1)))) (define (main [p : (Ptr i64)] [b : bool]) : (Ptr i64) (let [q : (Ptr i64) p] (begin (set! q (unsafe (int->ptr (ptr->int p) : (Ptr i64)))) (if b (pass (type i64) q) (step p 2)))))"
        mode)]
    [calls : i64 0]
    [recursive : bool false]
    [assignment : bool false]
    [returned : bool false]
    (for [index (iterator.range 0 3)]
      (match (proof.pointer-proof-input-function input index)
        [(Err _) (io.panic "pointer-proof smoke: missing specialized function")]
        [(Ok function)
          (for [parameter (iterator.range 0 (refs.len (& function.parameters)))]
            (let
              [use : proof.PointerProofUse
                (proof-smoke-use
                  input
                  (proof-smoke-reference (& function.parameters) parameter))]
              (unless
                (=
                  (ir.compiler-ir-symbol-id-value use.function)
                  (ir.compiler-ir-symbol-id-value function.symbol))
                (io.panic
                  "pointer-proof smoke: parameter belongs to another function"))
              (match use.operation
                [(Parameter ordinal)
                  (unless
                    (= ordinal parameter)
                    (io.panic "pointer-proof smoke: parameter ordinal changed"))]
                [_
                  (io.panic
                    "pointer-proof smoke: parameter is not a parameter occurrence")])
              (when
                (= parameter 0)
                (match use.source-type
                  [(Pointer) unit]
                  [_
                    (io.panic
                      "pointer-proof smoke: original pointer parameter type lost")]))))
          (let
            [result : proof.PointerProofUse
              (proof-smoke-use input function.result)]
            (unless
              (=
                (ir.compiler-ir-symbol-id-value result.function)
                (ir.compiler-ir-symbol-id-value function.symbol))
              (io.panic
                "pointer-proof smoke: result belongs to another function")))]))
    (for [index (iterator.range 0 (proof.pointer-proof-input-use-count input))]
      (let
        [use : proof.PointerProofUse
          (proof-smoke-use input (proof.PointerProofRef input.control index))]
        (match use.operation
          [(DirectCall symbol)
            (let
              [found : bool false]
              (for [callee-index (iterator.range 0 3)]
                (match (proof.pointer-proof-input-function input callee-index)
                  [(Ok callee)
                    (when
                      (=
                        (ir.compiler-ir-symbol-id-value symbol)
                        (ir.compiler-ir-symbol-id-value callee.symbol))
                      (set! found true)
                      (unless
                        (=
                          (refs.len (& use.operands))
                          (refs.len (& callee.parameters)))
                        (io.panic
                          "pointer-proof smoke: specialized call argument ordinals changed")))]
                  [_
                    (io.panic "pointer-proof smoke: missing direct-call callee")]))
              (unless
                found
                (io.panic
                  "pointer-proof smoke: call symbol is not an emitted callee"))
              (when
                (=
                  (ir.compiler-ir-symbol-id-value symbol)
                  (ir.compiler-ir-symbol-id-value use.function))
                (set! recursive true))
              (+= calls 1))]
          [(Assignment binding)
            (let
              [bound : proof.PointerProofUse
                (proof-smoke-use
                  input
                  (proof.PointerProofRef input.control binding))]
              (match bound.operation
                [(Binding) (set! assignment true)]
                [_
                  (io.panic
                    "pointer-proof smoke: assignment lost its lexical binding")]))]
          [(Return) (set! returned true)]
          [_ unit])))
    (unless
      (and (= calls 3) recursive assignment returned)
      (io.panic
        "pointer-proof smoke: tail/recursive call or assignment evidence lost"))
    (proof.pointer-proof-input-release! input)))

(define (proof-smoke-missing-location) : unit
  (let
    [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
    (proof.pointer-proof-input-push!
      input
      (ir.compiler-ir-symbol-typed-id 1)
      IntegerToPointer
      Pointer
      (proof.pointer-proof-input-operands input)
      "missing-location.tl"
      No)
    (let
      [message : diagnostic.CompilerDiagnostic
        (proof.pointer-proof-input-diagnostic
          input
          "pointer proof: missing conversion source location")]
      [error : String (proof.pointer-proof-input-begin-error input)]
      (unless
        (and
          (> (string.string-length (& error)) 0)
          (string.eq
            (diagnostic.compiler-diagnostic-path (& message))
            "missing-location.tl"))
        (io.panic
          "pointer-proof smoke: missing conversion metadata did not fail closed")))
    (proof.pointer-proof-input-release! input)))

(define (proof-smoke-job-guards [mode : lower.CompilerLowerMode]) : unit
  (let
    [first : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [second : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [missing : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [request : lower.CompilerLowerRequest (proof-smoke-request first mode)]
    [source : String "(define (main [p : (Ptr i64)]) : (Ptr i64) p)"]
    [first-result : lower.ResultCompilerLower
      (lower.lower-compiler-source-with-request
        "first.tl"
        (owned_view.compiler-owned-shared-view source)
        (owned_view.compiler-owned-shared-view request))]
    [second-result : lower.ResultCompilerLower
      (lower.lower-compiler-source-with-request
        "second.tl"
        (owned_view.compiler-owned-shared-view source)
        (proof-smoke-request second mode))]
    [reference : proof.PointerProofRef
      (match (proof.pointer-proof-input-function first 0)
        [(Ok function) function.result]
        [_ (io.panic "pointer-proof smoke: missing function/result binding")])]
    (match (proof.pointer-proof-input-use first reference)
      [(Ok _) unit]
      [_
        (io.panic
          "pointer-proof smoke: later source/interner job invalidated earlier facts")])
    (match (proof.pointer-proof-input-use second reference)
      [(Err _) unit]
      [_
        (io.panic
          "pointer-proof smoke: a foreign semantic reference was admitted")])
    (match (lower.lower-compiler-pointer-proof-result
      (owned_view.compiler-owned-shared-view request)
      (owned_view.compiler-owned-shared-view second-result))
      [(Err _) unit]
      [_
        (io.panic
          "pointer-proof smoke: another program reused the first job's evidence")])
    (match (owned_view.compiler-owned-shared-view first-result)
      [(Ok program _)
        (match (owned_view.compiler-owned-shared-view second-result)
          [(Ok _ spans)
            (match (lower.lower-compiler-pointer-proof-result
              (owned_view.compiler-owned-shared-view request)
              (Ok program spans))
              [(Err _) unit]
              [_
                (io.panic
                  "pointer-proof smoke: foreign source provenance was admitted")])]
          [_ (io.panic "pointer-proof smoke: second guard source failed")])]
      [_ (io.panic "pointer-proof smoke: first guard source failed")])
    (match (lower.lower-compiler-pointer-proof-result
      (proof-smoke-request missing mode)
      (owned_view.compiler-owned-shared-view first-result))
      [(Err _) unit]
      [_
        (io.panic
          "pointer-proof smoke: incomplete requested owner was admitted")])
    (match (lower.lower-compiler-source-with-request
      "reuse.tl"
      (owned_view.compiler-owned-shared-view source)
      (owned_view.compiler-owned-shared-view request))
      [(Err _) unit]
      [_ (io.panic "pointer-proof smoke: a bound owner was reused")])
    (proof.pointer-proof-input-release! first)
    (match (proof.pointer-proof-input-use first reference)
      [(Err _) unit]
      [_ (io.panic "pointer-proof smoke: retired owner was read")])
    (match (lower.lower-compiler-source-with-request
      "retired.tl"
      source
      request)
      [(Err _) unit]
      [_
        (io.panic
          "pointer-proof smoke: retired owner entered another lowering job")])
    (proof.pointer-proof-input-release! second)
    (proof.pointer-proof-input-release! missing)))

(define (proof-smoke-failed-source-job [mode : lower.CompilerLowerMode]) : unit
  (let
    [sources : (Array String 2) (array "(" "(define (main) : i64 true)")]
    (for [index (iterator.range 0 2)]
      (let
        [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
        [request : lower.CompilerLowerRequest (proof-smoke-request input mode)]
        [failed : lower.ResultCompilerLower
          (lower.lower-compiler-source-with-request
            "failed-source.tl"
            (owned_view.compiler-owned-array-element-shared-view sources index)
            (owned_view.compiler-owned-shared-view request))]
        (match failed
          [(Err _) unit]
          [_ (io.panic "pointer-proof smoke: invalid source was accepted")])
        (let
          [error : String (proof.pointer-proof-input-begin-error input)]
          (unless
            (> (string.string-length (& error)) 0)
            (io.panic
              "pointer-proof smoke: failed source did not consume its owner")))
        (match (lower.lower-compiler-source-with-request
          "failed-reuse.tl"
          "(define (main [p : (Ptr i64)]) : (Ptr i64) p)"
          request)
          [(Err _) unit]
          [_
            (io.panic
              "pointer-proof smoke: failed owner entered a later source job")])
        (proof.pointer-proof-input-release! input)))))

(define (proof-smoke-driver-handoff
  [mode : lower.CompilerLowerMode]
  [target : backend.CompilerBackendTarget]) : unit
  (let
    [input : proof.PointerProofInput (proof.pointer-proof-input-new)]
    [request : lower.CompilerLowerRequest (proof-smoke-request input mode)]
    [state : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [path : String "target/exp/compiler-pointer-proof/driver-input.tl"]
    [source : String
      "(define (main [p : (Ptr i64)]) : (Ptr i64) (unsafe (int->ptr (ptr->int p) : (Ptr i64))))"]
    [roots : svec.Vec (svec.new)]
    [interns : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state)]
    (when
      (= (driver.compiler-driver-state-intern-generation state) 0)
      (ci.intern-compat-state-reset! (&mut interns)))
    (driver.compiler-driver-state-install-pools! state)
    (driver.compiler-driver-state-install-interns! state)
    (driver.compiler-driver-state-reset-file-state!
      (owned_view.compiler-owned-shared-view state))
    (fs.try-mkdir-if-missing "target")
    (fs.try-mkdir-if-missing "target/exp")
    (fs.try-mkdir-if-missing "target/exp/compiler-pointer-proof")
    (io.write-file
      (owned_view.compiler-owned-shared-view path)
      (byte_buf.str-as-bytes (& source)))
    (svec.push-ref! (&mut roots) "stdlib")
    (lower.compiler-lower-state-use-request!
      (driver.compiler-driver-state-owned-lower-state state)
      (owned_view.compiler-owned-shared-view request))
    (match (driver.compiler-driver-load-and-lower-escaping-with-state-and-retirement
      (owned_view.compiler-owned-shared-view state)
      (owned_view.compiler-owned-shared-view path)
      target
      roots
      Scalar
      (cfg_core.compiler-cfg-empty)
      true)
      [(Err error _)
        (let
          [message : diagnostic.CompilerDiagnostic (deref error)]
          (io.println "{}" (diagnostic.compiler-diagnostic-render (& message)))
          (io.panic "pointer-proof smoke: driver lowering failed"))]
      [(Ok program spans _ _ _ _)
        (match (lower.lower-compiler-pointer-proof-result
          request
          (Ok program spans))
          [(Err error)
            (let
              [message : diagnostic.CompilerDiagnostic (deref error)]
              (io.println
                "{}"
                (diagnostic.compiler-diagnostic-render (& message)))
              (io.panic "pointer-proof smoke: driver handoff lost evidence"))]
          [_ unit])])
    (driver.compiler-driver-retire-frontend-arena!)
    (driver.compiler-driver-retire-lowered-source-arena!)
    (unless
      (proof-smoke-has-conversion? input)
      (io.panic
        "pointer-proof smoke: retired source pools invalidated semantic facts"))
    (driver.compiler-driver-state-release-lower-arenas!
      (owned_view.compiler-owned-shared-view state))
    (driver.compiler-driver-state-release-file-state! state)
    (ast.ast-node-pool-reader-clear!)
    (unless
      (proof-smoke-has-conversion? input)
      (io.panic
        "pointer-proof smoke: interner retirement invalidated semantic facts"))
    (proof.pointer-proof-input-release! input)
    (fs.try-remove-file-if-exists (& path))
    unit))

(define (main) : i64
  (proof-smoke-distinction LinuxScalar)
  (proof-smoke-distinction WindowsScalar)
  (proof-smoke-mixed-uses LinuxScalar)
  (proof-smoke-mixed-uses WindowsScalar)
  (proof-smoke-missing-input LinuxScalar)
  (proof-smoke-missing-input WindowsScalar)
  (proof-smoke-interactions LinuxScalar Linux)
  (proof-smoke-interactions WindowsScalar Windows)
  (proof-smoke-unsupported
    LinuxScalar
    (proof-smoke-unsupported-producer-source))
  (proof-smoke-unsupported
    WindowsScalar
    (proof-smoke-unsupported-producer-source))
  (proof-smoke-unsupported LinuxScalar (proof-smoke-unmodelled-binder-source))
  (proof-smoke-unsupported WindowsScalar (proof-smoke-unmodelled-binder-source))
  (proof-smoke-bindings LinuxScalar)
  (proof-smoke-bindings WindowsScalar)
  (proof-smoke-missing-location)
  (proof-smoke-job-guards LinuxScalar)
  (proof-smoke-job-guards WindowsScalar)
  (proof-smoke-failed-source-job LinuxScalar)
  (proof-smoke-failed-source-job WindowsScalar)
  (proof-smoke-driver-handoff LinuxScalar Linux)
  (proof-smoke-driver-handoff WindowsScalar Windows)
  42)