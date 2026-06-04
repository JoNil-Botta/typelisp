;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import "compiler_backend.tl")

(import "compiler_diagnostic.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(defenum ResultCompilerDriver
  (OkCompilerDriver String)
  (ErrCompilerDriver CompilerDiagnostic))

(define (compiler-driver-lower-mode-for-backend [mode : CompilerBackendMode]) : CompilerLowerMode
  (match mode
    [(BackendModeAvx2) (CompilerLowerAvx2)]
    [(BackendModeAvx512) (CompilerLowerAvx512)]
    [_ (CompilerLowerScalar)]))

(define (compiler-driver-emit-lowered
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level
    input-path
    program
    spans
    target
    has-target
    (compiler-optimize-default-level)))

(define (compiler-driver-emit-lowered-with-level
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-and-entry
    input-path
    program
    spans
    target
    has-target
    opt-level
    true))

(define (compiler-driver-emit-lowered-with-level-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-mode-and-entry
    input-path
    program
    spans
    target
    has-target
    (BackendModeScalar)
    opt-level
    emit-entry))

(define (compiler-driver-emit-lowered-with-level-mode-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
    input-path
    program
    spans
    target
    has-target
    mode
    opt-level
    emit-entry
    false))

(define (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (match (optimize-program-with-spans-and-level program spans opt-level)
    [(CompilerOptimizedProgram optimized optimized-spans)
      (match (if has-target
        (compiler-backend-emit-program-target-with-mode-and-crt
          optimized
          target
          mode
          optimized-spans
          emit-entry
          crt-entry)
        (compiler-backend-emit-program-target-with-mode-and-crt
          optimized
          (BackendTargetLinux)
          mode
          optimized-spans
          emit-entry
          crt-entry))
        [(OkCompilerBackend asm) (OkCompilerDriver asm)]
        [(ErrCompilerBackend diag)
          (ErrCompilerDriver (compiler-diagnostic-with-path diag input-path))])]))

(define (compiler-driver-emit-file-with-target
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    has-target
    CompilerLoadRootNil))

(define (compiler-driver-emit-file-with-target-and-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    has-target
    stdlib-roots
    (compiler-optimize-default-level)))

(define (compiler-driver-emit-file-with-target-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-and-mode
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    (BackendModeScalar)))

(define (compiler-driver-emit-file-with-target-roots-level-and-mode
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)
    false))

(define (compiler-driver-emit-file-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    mode
    cfgs
    false))

(define (compiler-driver-emit-file-with-target-roots-level-mode-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [crt-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)
    crt-entry))

(define (compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]
  [crt-entry : bool]) : ResultCompilerDriver
  (match (compiler-load-file-with-paths-and-roots-cfg
    input-path
    (sym-i64-empty)
    stdlib-roots
    cfgs)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths-mode
        input-path
        (AstProgram decls)
        paths
        (compiler-driver-lower-mode-for-backend mode))
        ;; The lowering provenance side table (#605/#761) is remapped after
        ;; optimization so backend diagnostics report surviving instruction
        ;; locations when a rewrite can preserve them.
        [(OkCompilerLower program spans)
          (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
            input-path
            program
            spans
            target
            has-target
            mode
            opt-level
            true
            crt-entry)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-emit-package-file-with-target-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [emit-entry : bool]) : ResultCompilerDriver
  (compiler-driver-emit-package-file-with-target-roots-level-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    manifest-dir
    deps
    emit-entry
    false))

(define (compiler-driver-emit-package-file-with-target-roots-level-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (match (compiler-load-package-file-with-paths-and-roots
    input-path
    (sym-i64-empty)
    stdlib-roots
    manifest-dir
    deps)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths
        input-path
        (AstProgram decls)
        paths)
        [(OkCompilerLower program spans)
          (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
            input-path
            program
            spans
            target
            has-target
            (BackendModeScalar)
            opt-level
            emit-entry
            crt-entry)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-ir-summary-line [name : String] [value : i64]) : String
  (string-append
    name
    (string-append " " (string-append (int->string value) "\n"))))

(define (compiler-driver-ir-summary-render [summary : CompilerIrSummary]) : String
  (let
    [out : String "typelisp-ir-summary v1\n"]
    (begin
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "globals"
            (compiler-ir-summary-globals summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "functions"
            (compiler-ir-summary-functions summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "externs"
            (compiler-ir-summary-externs summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "blocks"
            (compiler-ir-summary-blocks summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "instructions"
            (compiler-ir-summary-instructions summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "vars"
            (compiler-ir-summary-vars summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "empty-blocks"
            (compiler-ir-summary-empty-blocks summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "max-instructions-function"
            (compiler-ir-summary-max-instructions-function summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "max-instructions-block"
            (compiler-ir-summary-max-instructions-block summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "call-arg-entries"
            (compiler-ir-summary-call-arg-entries summary))))
      (set!
        out
        (string-append
          out
          (compiler-driver-ir-summary-line
            "phi-input-entries"
            (compiler-ir-summary-phi-input-entries summary))))
      (string-append
        out
        (compiler-driver-ir-summary-line
          "score"
          (compiler-ir-summary-score summary))))))

(define (compiler-driver-emit-ir-summary-lowered-with-level
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [opt-level : i64]) : ResultCompilerDriver
  (match (optimize-program-with-spans-and-level program spans opt-level)
    [(CompilerOptimizedProgram optimized _)
      (OkCompilerDriver
        (compiler-driver-ir-summary-render
          (compiler-ir-program-summary optimized)))]))

(define (compiler-driver-emit-ir-summary-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
    input-path
    stdlib-roots
    opt-level
    (compiler-cfg-empty)))

(define (compiler-driver-emit-ir-summary-file-with-roots-level-and-cfg
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [cfgs : SymI64Env]) : ResultCompilerDriver
  (match (compiler-load-file-with-paths-and-roots-cfg
    input-path
    (sym-i64-empty)
    stdlib-roots
    cfgs)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths
        input-path
        (AstProgram decls)
        paths)
        [(OkCompilerLower program spans)
          (compiler-driver-emit-ir-summary-lowered-with-level
            program
            spans
            opt-level)]
        [(ErrCompilerLower diag) (ErrCompilerDriver diag)])]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerDriver diag)]))

(define (compiler-driver-emit-file [input-path : String]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path (BackendTargetLinux) false))

(define (compiler-driver-emit-file-with-roots
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    (BackendTargetLinux)
    false
    stdlib-roots))

(define (compiler-driver-emit-file-with-roots-and-level
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level))

(define (compiler-driver-emit-file-for-target
  [input-path : String]
  [target : CompilerBackendTarget]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target input-path target true))

(define (compiler-driver-emit-file-for-target-with-roots
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-and-roots
    input-path
    target
    true
    stdlib-roots))

(define (compiler-driver-emit-file-for-target-with-roots-and-level
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultCompilerDriver
  (compiler-driver-emit-file-with-target-roots-and-level
    input-path
    target
    true
    stdlib-roots
    opt-level))

(define (compiler-driver-write-result
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriver asm)
      (begin
        (write-file output-path asm)
        (print-string
          (string-append "Generated: " (string-append output-path "\n")))
        0)]
    [(ErrCompilerDriver diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file input-path)
    output-path))

(define (compiler-driver-compile-file-with-roots
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-roots input-path stdlib-roots)
    output-path))

(define (compiler-driver-compile-file-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-roots-and-level
      input-path
      stdlib-roots
      opt-level)
    output-path))

(define (compiler-driver-compile-file-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-target-roots-level-and-mode
      input-path
      (BackendTargetLinux)
      false
      stdlib-roots
      opt-level
      mode)
    output-path))

(define (compiler-driver-compile-file-with-roots-level-mode-and-cfg
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-target-roots-level-mode-and-cfg
      input-path
      (BackendTargetLinux)
      false
      stdlib-roots
      opt-level
      mode
      cfgs)
    output-path))

(define (compiler-driver-compile-file-for-target
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target input-path target)
    output-path))

(define (compiler-driver-compile-file-for-target-with-roots
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target-with-roots
      input-path
      target
      stdlib-roots)
    output-path))

(define (compiler-driver-compile-file-for-target-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-for-target-with-roots-and-level
      input-path
      target
      stdlib-roots
      opt-level)
    output-path))

(define (compiler-driver-compile-file-for-target-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-target-roots-level-and-mode
      input-path
      target
      true
      stdlib-roots
      opt-level
      mode)
    output-path))

(define (compiler-driver-compile-file-for-target-with-roots-level-mode-and-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-write-result
    (compiler-driver-emit-file-with-target-roots-level-mode-and-cfg
      input-path
      target
      true
      stdlib-roots
      opt-level
      mode
      cfgs)
    output-path))