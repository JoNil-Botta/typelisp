;; Test-only driver for the public standalone backend source helpers.
(import compiler_backend as backend)
(import compiler_diagnostic as diagnostic)
(import compiler_object_elf as elf)
(import compiler_object_coff as coff)
(import compiler_backend_source_tests as source_tests)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.string)

(define (main) : i64
  (unless
    (= (io.arg-count) 5)
    (io.panic
      "usage: backend-source-import-oracle linux|windows asm|object SOURCE OUTPUT"))
  (let
    [target : backend.CompilerBackendTarget
      (if (string.eq (io.arg 1) "linux")
        (backend.CompilerBackendTarget.Linux)
        (if (string.eq (io.arg 1) "windows")
          (backend.CompilerBackendTarget.Windows)
          (io.panic "expected linux or windows")))]
    [source : String (byte_buf.to-string (io.read-file (io.arg 3)))]
    (when
      (string.eq (io.arg 2) "admission")
      (let
        [status : String (source_tests.source-object-status source target)]
        (io.println "{}" status)
        (return
          (if (string.eq status "eligible")
            0
            2))))
    (let
      [result : backend.ResultCompilerBackend
        (if (string.eq (io.arg 2) "asm")
          (backend.compiler-backend-emit-source-for-target source target)
          (if (string.eq (io.arg 2) "object")
            (match (backend.compiler-backend-emit-source-object-image-for-target
              source
              target)
              [(Err error) (backend.ResultCompilerBackend.Err error)]
              [(Ok image)
                (match target
                  [(Linux)
                    (match (elf.compiler-object-elf-render (& image))
                      [(Ok bytes) (backend.ResultCompilerBackend.Ok bytes)]
                      [(Err error) (io.panic error)])]
                  [(Windows)
                    (match (coff.compiler-object-coff-render (& image))
                      [(Ok bytes) (backend.ResultCompilerBackend.Ok bytes)]
                      [(Err error) (io.panic error)])])])
            (io.panic "expected asm or object")))]
      (match result
        [(Ok bytes)
          (io.write-file (io.arg 4) (byte_buf.str-as-bytes (& bytes)))
          0]
        [(Err error)
          (io.eprintln
            "{}"
            (diagnostic.compiler-diagnostic-render (& (__tl-box-place error))))
          1]))))