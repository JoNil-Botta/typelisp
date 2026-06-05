;; compiler_driver_core.tl - Import-aware selfhost compiler driver helpers.
(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(cfg compile-profile (import "../stdlib/profile.tl"))

(import "compiler_backend.tl")

(import "compiler_diagnostic.tl")

(import "compiler_load.tl")

(import "compiler_optimize.tl")

(import "../stdlib/text_buf.tl")

(defenum ResultCompilerDriver
  (OkCompilerDriver String)
  (ErrCompilerDriver CompilerDiagnostic))

(defenum ResultCompilerDriverBuffer
  (OkCompilerDriverBuffer TextBuf)
  (ErrCompilerDriverBuffer CompilerDiagnostic))

(defenum ResultCompilerDriverLowered
  (OkCompilerDriverLowered CompilerIrProgram CompilerSourceSpans)
  (ErrCompilerDriverLowered CompilerDiagnostic))

(cfg
  compile-profile
  (define compiler-driver-profile-total-start-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-driver-profile-total-start-total : i64
    0))

(cfg
  compile-profile
  (define compiler-driver-profile-total-start-live : i64
    0))

(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-total : i64
    0))

(cfg
  compile-profile
  (define compiler-driver-profile-phase-start-live : i64
    0))

(cfg
  compile-profile
  (define compiler-driver-profile-best-peak : i64
    0))

(cfg
  compile-profile
  (define (compiler-driver-profile-max [left : i64] [right : i64]) : i64
    (if (> left right)
      left
      right)))

(cfg
  compile-profile
  (define (compiler-driver-profile-nonnegative [value : i64]) : i64
    (if (< value 0)
      0
      value)))

(cfg
  compile-profile
  (define (compiler-driver-profile-field [value : i64]) : String
    (string-append "|" (int->string value))))

(cfg
  compile-profile
  (define (compiler-driver-profile-line
    [phase : String]
    [elapsed-ms : i64]
    [alloc-delta : i64]
    [live-delta : i64]
    [peak-delta : i64]) : String
    (string-append
      "compile-profile|"
      (string-append
        phase
        (string-append
          (compiler-driver-profile-field elapsed-ms)
          (string-append
            (compiler-driver-profile-field alloc-delta)
            (string-append
              (compiler-driver-profile-field live-delta)
              (string-append (compiler-driver-profile-field peak-delta) "\n"))))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-phase) : unit
    (begin
      (set! compiler-driver-profile-phase-start-ms (profile-now-ms))
      (set! compiler-driver-profile-phase-start-total (profile-alloc-total))
      (set! compiler-driver-profile-phase-start-live (profile-alloc-live))
      (profile-alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-phase [phase : String]) : unit
    (let
      [end-ms : i64 (profile-now-ms)]
      [end-total : i64 (profile-alloc-total)]
      [end-live : i64 (profile-alloc-live)]
      [peak-delta : i64
        (compiler-driver-profile-nonnegative
          (- (profile-alloc-peak) compiler-driver-profile-phase-start-live))]
      (begin
        (set!
          compiler-driver-profile-best-peak
          (compiler-driver-profile-max
            compiler-driver-profile-best-peak
            peak-delta))
        (print-error
          (compiler-driver-profile-line
            phase
            (- end-ms compiler-driver-profile-phase-start-ms)
            (- end-total compiler-driver-profile-phase-start-total)
            (- end-live compiler-driver-profile-phase-start-live)
            peak-delta))))))

(cfg
  compile-profile
  (define (compiler-driver-profile-start-total) : unit
    (begin
      (set! compiler-driver-profile-total-start-ms (profile-now-ms))
      (set! compiler-driver-profile-total-start-total (profile-alloc-total))
      (set! compiler-driver-profile-total-start-live (profile-alloc-live))
      (set! compiler-driver-profile-best-peak 0)
      (print-error
        "compile-profile|phase|elapsed_ms|alloc_delta_bytes|live_delta_bytes|peak_live_delta_bytes\n")
      (compiler-driver-profile-start-phase))))

(cfg
  compile-profile
  (define (compiler-driver-profile-finish-total) : unit
    (print-error
      (compiler-driver-profile-line
        "total"
        (- (profile-now-ms) compiler-driver-profile-total-start-ms)
        (- (profile-alloc-total) compiler-driver-profile-total-start-total)
        (- (profile-alloc-live) compiler-driver-profile-total-start-live)
        compiler-driver-profile-best-peak))))

(define (compiler-driver-lower-mode-for-target
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]) : CompilerLowerMode
  (match mode
    [(BackendModeAvx2)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx2)]
        [(BackendTargetWindows) (CompilerLowerAvx2)])]
    [(BackendModeAvx512)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx512)]
        [(BackendTargetWindows) (CompilerLowerAvx512)])]
    [_
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxScalar)]
        [(BackendTargetWindows) (CompilerLowerScalar)])]))

(define (compiler-driver-enable-linux-cfgs [cfgs : SymI64Env]) : SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable (compiler-cfg-enable cfgs "linux") "unix")
      "target-linux")
    "os-linux"))

(define (compiler-driver-enable-windows-cfgs [cfgs : SymI64Env]) : SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable (compiler-cfg-enable cfgs "windows") "target-windows")
    "os-windows"))

(define (compiler-driver-target-cfgs
  [target : CompilerBackendTarget]
  [cfgs : SymI64Env]) : SymI64Env
  (match target
    [(BackendTargetLinux) (compiler-driver-enable-linux-cfgs cfgs)]
    [(BackendTargetWindows) (compiler-driver-enable-windows-cfgs cfgs)]))

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
  (begin
    (cfg compile-profile (compiler-driver-profile-start-phase))
    (match (optimize-program-with-spans-and-level program spans opt-level)
      [(CompilerOptimizedProgram optimized optimized-spans)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase "optimize"))
          (cfg compile-profile (compiler-driver-profile-start-phase))
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
            [(OkCompilerBackend asm)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "backend"))
                (OkCompilerDriver asm))]
            [(ErrCompilerBackend diag)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "backend"))
                (ErrCompilerDriver
                  (compiler-diagnostic-with-path diag input-path)))]))])))

(define (compiler-driver-emit-lowered-buffer-with-level-mode-and-entry
  [input-path : String]
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [mode : CompilerBackendMode]
  [opt-level : i64]
  [emit-entry : bool]) : ResultCompilerDriverBuffer
  (begin
    (cfg compile-profile (compiler-driver-profile-start-phase))
    (match (optimize-program-with-spans-and-level program spans opt-level)
      [(CompilerOptimizedProgram optimized optimized-spans)
        (begin
          (cfg
            compile-profile
            (compiler-driver-profile-finish-phase "optimize"))
          (cfg compile-profile (compiler-driver-profile-start-phase))
          (match (if has-target
            (compiler-backend-emit-program-target-with-mode-buffer
              optimized
              target
              mode
              optimized-spans
              emit-entry)
            (compiler-backend-emit-program-target-with-mode-buffer
              optimized
              (BackendTargetLinux)
              mode
              optimized-spans
              emit-entry))
            [(OkCompilerBackendBuffer buf)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "backend"))
                (OkCompilerDriverBuffer buf))]
            [(ErrCompilerBackendBuffer diag)
              (begin
                (cfg
                  compile-profile
                  (compiler-driver-profile-finish-phase "backend"))
                (ErrCompilerDriverBuffer
                  (compiler-diagnostic-with-path diag input-path)))]))])))

(define (compiler-driver-load-and-lower-escaping
  [input-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverLowered
  (let
    [enclosing : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (begin
      (unsafe
        (arena-set! scratch))
      (match (compiler-load-file-with-paths-and-roots-cfg
        input-path
        (sym-i64-empty)
        stdlib-roots
        cfgs)
        [(OkCompilerLoadWithPaths decls paths _ _)
          (begin
            (cfg compile-profile (compiler-driver-profile-finish-phase "load"))
            (cfg compile-profile (compiler-driver-profile-start-phase))
            (match (lower-compiler-program-with-decl-paths-mode
              input-path
              (ast-program decls)
              paths
              (compiler-driver-lower-mode-for-target target mode))
              [(OkCompilerLower program spans)
                (let
                  [scratch-head : i64 (arena-current)]
                  (begin
                    (unsafe
                      (arena-set! enclosing))
                    (let
                      [escaped-program : CompilerIrProgram
                        (compiler-ir-clone-program program)]
                      [escaped-spans : CompilerSourceSpans (clone spans)]
                      (begin
                        (unsafe
                          (arena-destroy scratch-head))
                        (cfg
                          compile-profile
                          (compiler-driver-profile-finish-phase "lower"))
                        (OkCompilerDriverLowered escaped-program escaped-spans)))))]
              [(ErrCompilerLower diag)
                (let
                  [scratch-head : i64 (arena-current)]
                  (begin
                    (unsafe
                      (arena-set! enclosing))
                    (let
                      [escaped-diag : CompilerDiagnostic (clone diag)]
                      (begin
                        (unsafe
                          (arena-destroy scratch-head))
                        (cfg
                          compile-profile
                          (compiler-driver-profile-finish-phase "lower"))
                        (ErrCompilerDriverLowered escaped-diag)))))]))]
        [(ErrCompilerLoadWithPaths diag)
          (let
            [scratch-head : i64 (arena-current)]
            (begin
              (unsafe
                (arena-set! enclosing))
              (let
                [escaped-diag : CompilerDiagnostic (clone diag)]
                (begin
                  (unsafe
                    (arena-destroy scratch-head))
                  (cfg
                    compile-profile
                    (compiler-driver-profile-finish-phase "load"))
                  (ErrCompilerDriverLowered escaped-diag)))))]))))

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
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (match (compiler-driver-load-and-lower-escaping
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-target-cfgs target cfgs))
      [(OkCompilerDriverLowered program spans)
        ;; The lowering provenance side table (#605/#761) is remapped after
        ;; optimization so backend diagnostics report surviving instruction
        ;; locations when a rewrite can preserve them.
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
      [(ErrCompilerDriverLowered diag) (ErrCompilerDriver diag)])))

(define (compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : ResultCompilerDriverBuffer
  (begin
    (cfg compile-profile (compiler-driver-profile-start-total))
    (match (compiler-driver-load-and-lower-escaping
      input-path
      target
      stdlib-roots
      mode
      (compiler-driver-target-cfgs target cfgs))
      [(OkCompilerDriverLowered program spans)
        (compiler-driver-emit-lowered-buffer-with-level-mode-and-entry
          input-path
          program
          spans
          target
          has-target
          mode
          opt-level
          true)]
      [(ErrCompilerDriverLowered diag) (ErrCompilerDriverBuffer diag)])))

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
  (compiler-driver-emit-package-file-with-target-roots-level-mode-and-crt
    input-path
    target
    has-target
    stdlib-roots
    opt-level
    (BackendModeScalar)
    manifest-dir
    deps
    emit-entry
    crt-entry))

(define (compiler-driver-emit-package-file-with-target-roots-level-mode-and-crt
  [input-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [manifest-dir : String]
  [deps : CompilerPkgDepList]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerDriver
  (match (compiler-load-package-file-with-paths-and-roots-cfg
    input-path
    (sym-i64-empty)
    stdlib-roots
    manifest-dir
    deps
    (compiler-driver-target-cfgs target (compiler-cfg-empty)))
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths-mode
        input-path
        (ast-program decls)
        paths
        (compiler-driver-lower-mode-for-target target mode))
        [(OkCompilerLower program spans)
          (compiler-driver-emit-lowered-with-level-mode-entry-and-crt
            input-path
            program
            spans
            target
            has-target
            mode
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
    (compiler-driver-target-cfgs (BackendTargetLinux) cfgs))
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (lower-compiler-program-with-decl-paths
        input-path
        (ast-program decls)
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

(define (compiler-driver-append-output-chunk
  [output-path : String]
  [chunk : String]) : i64
  (let
    [status : i64 (append-file-status output-path chunk)]
    (if (= status 0)
      0
      (begin
        (print-error
          (string-append
            "compiler: append output failed with status "
            (string-append (int->string status) "\n")))
        1))))

(define (compiler-driver-write-text-buf-chunks
  [output-path : String]
  [chunks : TextBufChunkList]) : i64
  (match chunks
    [(TextBufChunkNil) 0]
    [(TextBufChunkCons chunk rest)
      (let
        [tail-status : i64
          (compiler-driver-write-text-buf-chunks output-path (box-get rest))]
        (if (= tail-status 0)
          (compiler-driver-append-output-chunk output-path chunk)
          tail-status))]))

(define (compiler-driver-write-text-buf [output-path : String] [buf : TextBuf]) : i64
  (match buf
    [(TextBuf chunks _)
      (begin
        (write-file output-path "")
        (compiler-driver-write-text-buf-chunks output-path chunks))]))

(define (compiler-driver-write-result
  [result : ResultCompilerDriver]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriver asm)
      (begin
        (cfg compile-profile (compiler-driver-profile-start-phase))
        (write-file output-path asm)
        (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-string
          (string-append "Generated: " (string-append output-path "\n")))
        0)]
    [(ErrCompilerDriver diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-write-buffer-result
  [result : ResultCompilerDriverBuffer]
  [output-path : String]) : i64
  (match result
    [(OkCompilerDriverBuffer buf)
      (let
        [status : i64
          (begin
            (cfg compile-profile (compiler-driver-profile-start-phase))
            (compiler-driver-write-text-buf output-path buf))]
        (begin
          (cfg compile-profile (compiler-driver-profile-finish-phase "write"))
          (cfg compile-profile (compiler-driver-profile-finish-total))
          (if (= status 0)
            (begin
              (print-string
                (string-append "Generated: " (string-append output-path "\n")))
              0)
            status)))]
    [(ErrCompilerDriverBuffer diag)
      (begin
        (cfg compile-profile (compiler-driver-profile-finish-total))
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (compiler-driver-compile-file-with-target-roots-level-mode-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-write-buffer-result
    (compiler-driver-emit-file-buffer-with-target-roots-level-mode-and-cfg
      input-path
      target
      has-target
      stdlib-roots
      opt-level
      mode
      cfgs)
    output-path))

(define (compiler-driver-compile-file
  [input-path : String]
  [output-path : String]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    CompilerLoadRootNil
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-with-roots-level-mode-and-cfg
  [input-path : String]
  [output-path : String]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    (BackendTargetLinux)
    false
    stdlib-roots
    opt-level
    mode
    cfgs))

(define (compiler-driver-compile-file-for-target
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    CompilerLoadRootNil
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-and-level
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    (BackendModeScalar)
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-level-and-mode
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    mode
    (compiler-cfg-empty)))

(define (compiler-driver-compile-file-for-target-with-roots-level-mode-and-cfg
  [input-path : String]
  [output-path : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [cfgs : SymI64Env]) : i64
  (compiler-driver-compile-file-with-target-roots-level-mode-cfg
    input-path
    output-path
    target
    true
    stdlib-roots
    opt-level
    mode
    cfgs))