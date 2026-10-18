;; compiler_backend_object_target_linux.tl - Linux direct-object policy leaf.
(import compiler_backend_object_target as object_target)
(import compiler_object as cobj)
(import compiler_x64_executable_template as x64_template)
(import compiler_x64_executable_template_catalog as x64_catalog)

(define (compiler-backend-object-tlci-entry-bytes) : String
  (x64_catalog.compiler-x64-template-render-bytes
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciImageBytes)
    (LinuxX64)
    (object_target.compiler-backend-object-bytes-from-hex
      "4889f84889f74889d64883ec08ffd04883c408c3")))

(define (compiler-backend-object-tlci-macro-entry-bytes) : String
  (x64_catalog.compiler-x64-template-render-bytes
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciMacroBytes)
    (LinuxX64)
    (object_target.compiler-backend-object-bytes-from-hex
      "4889f84889f74889d64889ca4c89c14d89c84c8b4c24084883ec08ffd04883c408c3")))

(define (compiler-backend-object-exit-bytes) : String
  (x64_catalog.compiler-x64-template-render-bytes
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectExitBytes)
    (LinuxX64)
    (object_target.compiler-backend-object-bytes-from-hex
      "4889c748c7c03c0000000f05")))

(define (compiler-backend-object-add-entry
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (x64_catalog.compiler-x64-template-assert-structured!
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectStartContribution)
    (LinuxX64))
  (let
    [with-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-export-section
        parts
        "_tl_start"
        (Text)
        (Function))]
    [with-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-symbol
        (cobj.CompilerObjectX64Instr.Label "_tl_start"))]
    [with-main-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-label
        "_tl_start"
        "main")]
    (object_target.compiler-backend-object-add-text-bytes
      with-main-call
      (compiler-backend-object-exit-bytes))))

(define (compiler-backend-object-target-linux-image
  [parts : object_target.CompilerBackendObjectTargetParts]
  [macro-entry : bool]
  [emit-entry : bool]
  [crt-entry : bool]) : cobj.CompilerObjectImage
  (let
    [with-tlci : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-tlci-entry-runtime-text
        parts
        (compiler-backend-object-tlci-entry-bytes)
        (compiler-backend-object-tlci-macro-entry-bytes)
        macro-entry
        (LinuxX64)
        (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciImageContribution)
        (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciMacroContribution))]
    [with-entry : object_target.CompilerBackendObjectTargetParts
      (if (and emit-entry (not crt-entry))
        (compiler-backend-object-add-entry with-tlci)
        with-tlci)]
    [final-parts : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss with-entry (Zero 0))]
    (cobj.CompilerObjectImage
      (cobj.compiler-object-section-builder-finish
        (object_target.compiler-backend-object-base-sections
          final-parts.text
          final-parts.data
          final-parts.rodata
          final-parts.bss
          4))
      (cobj.compiler-object-symbol-builder-finish final-parts.symbols)
      (cobj.compiler-object-relocation-builder-finish final-parts.relocations))))