;; compiler_lower_smoke.tl - Runnable smoke for compiler_lower.tl (#446).
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import "../compiler_driver_core.tl")

(define (compiler-lower-smoke-imported-local-vector-source) : String
  "(module stdlib.vector)
(defstruct StringVec (len i64) (first String))
(define (string-vec-new) : StringVec
  (StringVec 0 \"\"))
(define (string-vec-push [v : StringVec] [value : String]) : StringVec
  (StringVec (+ (struct-get v len) 1) value))
(define (string-vec-get [v : StringVec] [index : i64] [fallback : String]) : String
  (if (< index (struct-get v len))
    (struct-get v first)
    fallback))
(module main)
(import stdlib.vector)
(define (main) : i64
  (__tl_string_length
    (vector.string-vec-get
      (vector.string-vec-push (vector.string-vec-new) \"a\")
      0
      \"\")))")

(define (compiler-lower-smoke-imported-local-vector-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-smoke-imported-local-vector-source))
    [(OkCompilerLower _ _) true]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-smoke-imported-nullary-file-ok?) : bool
  (let
    [root : String "target/lower_nullary_stdlib"]
    [dep : String "target/lower_nullary_stdlib/maybe_string.tl"]
    [entry : String "target/lower_nullary_entry.tl"]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) root)]
    (begin
      (compiler-load-test-mkdir root)
      (io.write-file
        dep
        "(module stdlib.maybe_string)
(defenum MaybeString (NoString) (SomeString String))
(define (maybe-string-single [value : String]) : MaybeString
  (SomeString value))")
      (io.write-file
        entry
        "(import stdlib.maybe_string)
(define (main) : i64
  (__tl_string_length
    (match (maybe_string.maybe-string-single \"a\")
      [(maybe_string.NoString) \"\"]
      [(maybe_string.SomeString head) head])))")
      (match (compiler-load-file-with-paths-and-roots
        entry
        (sym-i64-empty)
        roots)
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (lower-compiler-program-with-decl-paths
            entry
            (ast-program decls)
            paths)
            [(OkCompilerLower _ _) true]
            [(ErrCompilerLower diag)
              (panic (compiler-diagnostic-message (box-get diag)))])]
        [(ResultCompilerLoadWithPaths.Err diag)
          (panic (compiler-diagnostic-message (box-get diag)))]))))

(define (compiler-lower-smoke-stdlib-args-ok?) : bool
  (let
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "stdlib")]
    (match (compiler-driver-load-and-lower-escaping
      "stdlib/args.tl"
      (CompilerBackendTarget.Linux)
      roots
      (CompilerBackendMode.Scalar)
      (compiler-driver-target-cfgs
        (CompilerBackendTarget.Linux)
        (compiler-cfg-empty)))
      [(ResultCompilerDriverLowered.Ok _ _ _) true]
      [(ResultCompilerDriverLowered.Err _) false])))

(define (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-source) : String
  "(defmacro (vector-user) : Module
  `(begin
    (module generated.lower_vector_user_no_main)
    (import stdlib.vector)
    (defstruct T
      (value i64))
    (import (vector T) as vec)
    (define (make [value : i64]) : T
      (T value))
    (define (score [first : T] [fallback : T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) first)
          (if (= (vec.len (& items)) 1)
            (begin
              (vec.get (& items) 0 fallback)
              42)
            0))))))
(import (vector-user) as user)")

(define (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-source))
    [(OkCompilerLower _ _) true]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-smoke-module-macro-vector-no-main-ir-ok?) : bool
  (let
    [path : String "target/lower_module_macro_vector_no_main.tl"]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "stdlib")]
    (begin
      (io.write-file
        path
        (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-source))
      (match (compiler-driver-emit-ir-summary-file-with-target-roots-level-mode-and-cfg
        path
        (CompilerBackendTarget.Linux)
        roots
        0
        (CompilerBackendMode.Scalar)
        (compiler-cfg-empty))
        [(ResultCompilerDriver.Ok _) true]
        [(ResultCompilerDriver.Err diag)
          (panic (compiler-diagnostic-message (box-get diag)))]))))

(define (compiler-lower-smoke-direct-no-main-keeps-source-symbols?) : bool
  (let
    [path : String "target/lower_direct_no_main_symbols.tl"]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "stdlib")]
    (begin
      (io.write-file path "(define (no-main-direct-helper) : i64 7)")
      (lower-no-main-entry-prune-set! true)
      (compiler-driver-reset-file-state!)
      (match (compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
        path
        (CompilerBackendTarget.Linux)
        true
        roots
        0
        (CompilerBackendMode.Scalar)
        (compiler-cfg-empty))
        [(ResultCompilerDriverBuffer.Ok buf)
          (let
            [asm : String (text_buf.text-buf-render buf)]
            [needle : String
              "_tl_lower_direct_no_main_symbols_no_main_direct_helper:"]
            (string.string-contains (& asm) (& needle)))]
        [(ResultCompilerDriverBuffer.Err diag)
          (panic (compiler-diagnostic-message (box-get diag)))]))))

(define (compiler-lower-smoke-issue3494-ok?) : bool
  (begin
    (unless
      (compiler-lower-smoke-imported-local-vector-ok?)
      (panic "lower: issue3494 imported local vector failed"))
    (unless
      (compiler-lower-smoke-imported-nullary-file-ok?)
      (panic "lower: issue3494 imported nullary file failed"))
    (unless
      (compiler-lower-smoke-stdlib-args-ok?)
      (panic "lower: issue3494 stdlib args failed"))
    (unless
      (compiler-lower-smoke-module-macro-vector-no-main-ir-ok?)
      (panic "lower: no-main module macro vector IR failed"))
    (unless
      (compiler-lower-smoke-direct-no-main-keeps-source-symbols?)
      (panic "lower: direct no-main compile pruned source symbol"))
    (unless
      (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-ok?)
      (panic "lower: no-main module macro vector import failed"))
    true))

(define (compiler-lower-smoke-module-entry-main-check) : unit
  (match (parse-ast-source (compiler-lower-module-entry-main-source))
    [(ResultAstProgram.Ok program)
      (match (lower-compiler-program-with-decl-paths
        "stdlib/arena.tl"
        program
        AstDeclPathNil)
        [(OkCompilerLower lowered _)
          (match lowered
            [(CompilerIrProgram.Program _ functions _)
              (begin
                (unless
                  (lower-test-function-defined? functions "main")
                  (panic "lower: module entry main function missing"))
                (unless
                  (lower-test-function-defined?
                    functions
                    "arena.tl::stdlib.arena/helper")
                  (panic "lower: module entry helper function missing"))
                (let
                  [path-count : i64
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      "arena.tl::stdlib.arena/helper")]
                  [module-count : i64
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      "stdlib.arena/helper")]
                  [bare-count : i64
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      "helper")]
                  (unless
                    (= path-count 1)
                    (if (= module-count 1)
                      (panic "lower: module entry main uses module helper")
                      (if (= bare-count 1)
                        (panic "lower: module entry main uses bare helper")
                        (panic "lower: module entry main helper call missing"))))))])]
        [(ErrCompilerLower diag)
          (panic (compiler-diagnostic-message (box-get diag)))])]
    [(ResultAstProgram.Err _) (panic "lower: module entry main parse failed")]))

(define (compiler-lower-smoke-self-test) : unit
  (begin
    (unless
      (compiler-lower-and-or-short-circuit-shape-ok?)
      (panic "lower: and/or short-circuit smoke mismatch"))
    (unless
      (compiler-lower-entry-moduled-main-ok?)
      (panic "lower: entry moduled main smoke mismatch"))
    (unless
      (compiler-lower-ok-summary? (compiler-lower-smoke-source))
      (panic "lower: basic summary smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-macro-expand-source))
      (panic "lower: macro expand smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-macro-expr-clause-source))
      (panic "lower: macro expr clause smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-macro-expr-clause-variadic-source))
      (panic "lower: macro variadic clause smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-macro-hygiene-definition-source))
      (panic "lower: macro hygiene definition smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-macro-arity-source)
        "macro call has too few arguments")
      (panic "lower: macro arity diagnostic smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        "(import stdlib.comptime)
(define (main) : i64
  (comptime.comptime-error \"runtime forbidden\"))"
        "lower: comptime-error is compile-time only")
      (panic "lower: comptime-error runtime diagnostic smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-macro-expr-clause-to-expr-error-source)
        "typecheck: macro operand type mismatch: expected Expr, got bracket clause")
      (panic "lower: macro clause-to-expr diagnostic smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-macro-expr-to-clause-error-source)
        "typecheck: ExprClause macro operand expects bracket syntax")
      (panic "lower: macro expr-to-clause diagnostic smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-macro-expr-clause-shape-error-source)
        "typecheck: ExprClause macro operand expects bracket clause [expr expr]")
      (panic "lower: macro clause shape diagnostic smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-bracket-ordinary-call-error-source)
        "typecheck: bracket clause is only valid as an ExprClause or ExprBindingClause macro operand")
      (panic "lower: bracket ordinary-call diagnostic smoke mismatch"))
    (unless
      (compiler-lower-spans-ok? (compiler-lower-smoke-source))
      (panic "lower: source span smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-match-source))
      (panic "lower: match smoke mismatch"))
    (unless
      (compiler-lower-match-phi-shape-ok? (compiler-lower-match-source))
      (panic "lower: match phi smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-enum-match-source))
      (panic "lower: enum match smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-enum-literal-payload-source))
      (panic "lower: enum literal payload smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-enum-nested-payload-source))
      (panic "lower: enum nested payload smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-enum-string-literal-payload-source))
      (panic "lower: enum string payload smoke mismatch"))
    (unless
      (compiler-lower-enum-string-literal-payload-shape-ok?)
      (panic "lower: enum string payload shape smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-borrowed-enum-match-source))
      (panic "lower: borrowed enum match smoke mismatch"))
    (unless
      (compiler-lower-ok?
        (compiler-lower-borrowed-enum-match-ref-struct-array-source))
      (panic "lower: borrowed enum ref struct array smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-borrowed-enum-match-str-source))
      (panic "lower: borrowed enum str smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-borrowed-enum-match-nested-source))
      (panic "lower: borrowed enum nested smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-export-source))
      (panic "lower: export smoke mismatch"))
    (unless
      (compiler-lower-defdispatch-thunk-shape-ok?)
      (panic "lower: defdispatch thunk smoke mismatch"))
    (unless
      (compiler-lower-defdispatch-shared-helper-ok?)
      (panic "lower: defdispatch shared helper smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-result-try-source))
      (panic "lower: result try smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-option-try-source))
      (panic "lower: option try smoke mismatch"))
    (unless
      (compiler-lower-enum-match-shape-ok? (compiler-lower-enum-match-source))
      (panic "lower: enum match shape smoke mismatch"))
    (unless
      (compiler-lower-borrowed-enum-match-shape-ok?)
      (panic "lower: borrowed enum match shape smoke mismatch"))
    (unless
      (compiler-lower-result-try-shape-ok? (compiler-lower-result-try-source))
      (panic "lower: result try shape smoke mismatch"))
    (unless
      (compiler-lower-option-try-shape-ok?)
      (panic "lower: option try shape smoke mismatch"))
    (unless
      (compiler-lower-return-shape-ok?)
      (panic "lower: return smoke mismatch"))
    (unless
      (compiler-lower-return-with-arena-shape-ok?)
      (panic "lower: return with arena smoke mismatch"))
    (unless
      (compiler-lower-resource-with-shape-ok?)
      (panic "lower: resource-with smoke mismatch"))
    (unless
      (compiler-lower-resource-with-nested-shape-ok?)
      (panic "lower: nested resource-with smoke mismatch"))
    (unless
      (compiler-lower-cleanup-struct-shape-ok?)
      (panic "lower: cleanup struct smoke mismatch"))
    (unless
      (compiler-lower-cleanup-struct-nested-shape-ok?)
      (panic "lower: nested cleanup struct smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-array-length-source))
      (panic "lower: array length smoke mismatch"))
    (unless
      (compiler-lower-array-access-shape-ok?
        (compiler-lower-array-access-source))
      (panic "lower: array access smoke mismatch"))
    (unless
      (compiler-lower-fixed-array-access-shape-ok?
        (compiler-lower-fixed-array-access-source))
      (panic "lower: fixed array access smoke mismatch"))
    (unless
      (compiler-lower-fixed-array-literal-stack-shape-ok?)
      (panic "lower: fixed array stack literal smoke mismatch"))
    (unless
      (compiler-lower-fixed-array-aggregate-layout-shape-ok?)
      (panic "lower: fixed array aggregate layout smoke mismatch"))
    (unless
      (compiler-lower-array-access-shape-ok?
        (compiler-lower-mut-ref-array-access-source))
      (panic "lower: mutable ref array access smoke mismatch"))
    (unless
      (compiler-lower-mut-ref-by-value-writeback-shape-ok?)
      (panic "lower: mutable ref writeback smoke mismatch"))
    (unless
      (compiler-lower-mut-ref-array-field-access-shape-ok?)
      (panic "lower: mutable ref array field smoke mismatch"))
    (unless
      (compiler-lower-array-push-shape-ok? (compiler-lower-array-push-source))
      (panic "lower: array push smoke mismatch"))
    (unless
      (compiler-lower-array-push-shape-ok?
        (compiler-lower-mut-ref-array-access-source))
      (panic "lower: mutable ref array push smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-fixed-array-push-source)
        "typecheck: array-push! requires dynamic array type")
      (panic "lower: fixed array push diagnostic smoke mismatch"))
    (unless
      (compiler-lower-make-array-shape-ok? (compiler-lower-make-array-source))
      (panic "lower: make-array smoke mismatch"))
    (unless
      (compiler-lower-make-array-init-shape-ok?
        (compiler-lower-make-array-init-source))
      (panic "lower: make-array init smoke mismatch"))
    (unless
      (compiler-lower-make-array-register-resident-fill8-shape-ok?)
      (panic "lower: make-array fill8 smoke mismatch"))
    (unless
      (compiler-lower-runtime-helper-tests-ok?)
      (panic "lower: runtime helper smoke mismatch"))
    (unless
      (compiler-lower-function-value-shape-ok?)
      (panic "lower: function value smoke mismatch"))
    (unless
      (compiler-lower-function-value-contextual-init-ok?)
      (panic "lower: contextual function value smoke mismatch"))
    (unless
      (compiler-lower-noncapturing-lambda-tests-ok?)
      (panic "lower: noncapturing lambda smoke mismatch"))
    (unless
      (compiler-lower-capturing-lambda-tests-ok?)
      (panic "lower: capturing lambda smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-aggregate-source))
      (panic "lower: aggregate smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-init-source))
      (panic "lower: init smoke mismatch"))
    (unless
      (compiler-lower-tuple-shape-ok?)
      (panic "lower: tuple smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-tuple-return-source))
      (panic "lower: tuple return smoke mismatch"))
    (unless
      (compiler-lower-clone-shape-ok?)
      (panic "lower: clone smoke mismatch"))
    (unless
      (compiler-lower-clone-dynarray-bulk-copy-ok?)
      (panic "lower: clone dynarray bulk smoke mismatch"))
    (unless
      (compiler-lower-clone-reachable-helpers-ok?)
      (panic "lower: clone reachable helpers smoke mismatch"))
    (unless
      (compiler-lower-error-ok?
        (compiler-lower-clone-unsupported-source)
        "typecheck: clone unsupported type (-> i64 i64)")
      (panic "lower: clone unsupported diagnostic smoke mismatch"))
    (unless
      (compiler-lower-inline-aggregate-tests-ok?)
      (panic "lower: inline aggregate smoke mismatch"))
    (unless
      (compiler-lower-ok? (compiler-lower-comptime-decl-source))
      (panic "lower: comptime decl smoke mismatch"))
    (unless
      (compiler-lower-generated-paths-preserved-ok?)
      (panic "lower: generated paths smoke mismatch"))
    (unless
      (compiler-lower-module-symbols-ok?)
      (panic "lower: module symbols smoke mismatch"))
    (unless
      (compiler-lower-package-owned-symbols-ok?)
      (panic "lower: package-owned symbols smoke mismatch"))
    (compiler-lower-smoke-module-entry-main-check)
    (unless
      (compiler-lower-module-qualified-ok?)
      (panic "lower: module qualified smoke mismatch"))
    (unless
      (compiler-lower-import-alias-ok?)
      (panic "lower: import alias smoke mismatch"))
    (unless
      (compiler-lower-dotted-import-default-alias-ok?)
      (panic "lower: dotted import default alias smoke mismatch"))
    (unless
      (compiler-lower-dotted-import-string-call-ok?)
      (panic "lower: dotted import string call smoke mismatch"))
    (unless
      (compiler-lower-module-function-returning-struct-ok?)
      (panic "lower: module struct return smoke mismatch"))
    (unless
      (compiler-lower-module-function-returning-enum-ok?)
      (panic "lower: module enum return smoke mismatch"))
    (unless
      (compiler-lower-imported-enum-aggregate-payload-ok?)
      (panic "lower: imported enum aggregate payload smoke mismatch"))
    (unless
      (compiler-lower-module-macro-codegen-ok?)
      (panic "lower: module macro codegen smoke mismatch"))
    (unless
      (compiler-lower-module-macro-global-init-ok?)
      (panic "lower: module macro global init smoke mismatch"))
    (unless
      (compiler-lower-module-macro-stdlib-vector-import-ok?)
      (panic "lower: module macro stdlib vector import smoke mismatch"))
    (unless
      (compiler-lower-smoke-module-macro-stdlib-vector-import-no-main-ok?)
      (panic "lower: no-main module macro stdlib vector import smoke mismatch"))
    (unless
      (compiler-lower-function-decl-count-wrapped-ok?)
      (panic "lower: function decl count smoke mismatch"))
    (unless
      (compiler-lower-extern-link-metadata-ok?)
      (panic "lower: extern link metadata smoke mismatch"))
    (unless
      (compiler-lower-extern-value-fnptr-shape-ok?)
      (panic "lower: extern fnptr value smoke mismatch"))
    (unless
      (compiler-lower-c-abi-linux-tag-only-enum-shape-ok?)
      (panic "lower: linux tag-only enum C ABI smoke mismatch"))
    (unless
      (compiler-lower-c-abi-windows-enum-aggregate-shape-ok?)
      (panic "lower: windows enum aggregate C ABI smoke mismatch"))
    (unless
      (compiler-lower-c-abi-linux-payload-enum-shape-ok?)
      (panic "lower: linux payload enum C ABI smoke mismatch"))
    (unless
      (compiler-lower-c-abi-windows-byref-aggregate-shape-ok?)
      (panic "lower: windows byref aggregate C ABI smoke mismatch"))
    (unless
      (compiler-lower-c-abi-windows-small-float-aggregate-shape-ok?)
      (panic "lower: windows small float aggregate C ABI smoke mismatch"))
    (unless
      (compiler-lower-c-abi-windows-nested-small-aggregate-shape-ok?)
      (panic "lower: windows nested small aggregate C ABI smoke mismatch"))
    (unless
      (compiler-lower-windows-error-ok?
        (compiler-lower-c-abi-windows-unsupported-aggregate-source)
        "lower: unsupported windows-x86_64 C aggregate ABI for OuterText; this slice supports scalar structs of size 1, 2, 4, or 8 bytes, including nested scalar struct fields")
      (panic "lower: windows unsupported C ABI diagnostic smoke mismatch"))
    (unless
      (compiler-lower-global-shape-ok?)
      (panic "lower: global shape smoke mismatch"))
    (unless
      (compiler-lower-raw-pointer-ops-ok?)
      (panic "lower: raw pointer ops smoke mismatch"))
    (unless
      (compiler-lower-raw-pointer-call-value-shape-ok?)
      (panic "lower: raw pointer call value smoke mismatch"))
    (unless
      (compiler-lower-back-half-tests-ok?)
      (panic "lower: back-half smoke mismatch"))))

(define (main) : i64
  (begin
    (compiler-lower-smoke-self-test)
    (unless
      (compiler-lower-smoke-issue3494-ok?)
      (panic "lower: issue3494 smoke failed"))
    42))