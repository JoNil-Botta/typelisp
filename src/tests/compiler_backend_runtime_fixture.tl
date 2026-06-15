;; compiler_backend_runtime_fixture.tl - emit runtime-helper backend fixture assembly.
(import stdlib.io as io_mod)

(import "../compiler_backend.tl")

(define (compiler-backend-runtime-fixture-emit [target-name : String]) : ResultCompilerBackend
  (if (string-eq target-name "linux-x86_64")
    (compiler-backend-emit-program (compiler-backend-runtime-helper-program))
    (if (string-eq target-name "windows-x86_64")
      (compiler-backend-emit-program-for-target
        (compiler-backend-runtime-helper-program)
        (BackendTargetWindows))
      (if (string-eq target-name "windows-driver-primitives")
        (compiler-backend-emit-source-for-target
          (compiler-backend-windows-driver-runtime-source)
          (BackendTargetWindows))
        (ErrCompilerBackend
          (compiler-diagnostic-at-start
            ""
            "compiler-backend-runtime-fixture: unknown target"))))))

(define (main) : i64
  (if (< (io_mod.arg-count) 2)
    (begin
      (io_mod.print-error "compiler-backend-runtime-fixture: expected output path")
      1)
    (let
      [target-name : String
        (if (< (io_mod.arg-count) 3)
          "linux-x86_64"
          (io_mod.arg 2))]
      ;; Keep the driver source emit direct in main; this is the compile-heavy
      ;; fixture path and avoids an extra helper wrapper in the native smoke.
      (if (string-eq target-name "windows-driver-primitives")
        (match (compiler-backend-emit-source-for-target
          (compiler-backend-windows-driver-runtime-source)
          (BackendTargetWindows))
          [(OkCompilerBackend asm)
            (begin
              (io_mod.write-file (io_mod.arg 1) asm)
              0)]
          [(ErrCompilerBackend diag)
            (begin
              (io_mod.print-error (compiler-diagnostic-render diag))
              1)])
        (match (compiler-backend-runtime-fixture-emit target-name)
          [(OkCompilerBackend asm)
            (begin
              (io_mod.write-file (io_mod.arg 1) asm)
              0)]
          [(ErrCompilerBackend diag)
            (begin
              (io_mod.print-error (compiler-diagnostic-render diag))
              1)])))))