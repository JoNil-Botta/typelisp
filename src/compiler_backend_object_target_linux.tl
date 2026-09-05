;; compiler_backend_object_target_linux.tl - Linux direct-object policy leaf.
(import compiler_owned_view as owned_view)
(import compiler_backend_object_target as object_target)
(import compiler_object as cobj)
(import compiler_x64_executable_template as x64_template)
(import compiler_x64_executable_template_catalog as x64_catalog)

(define (compiler-backend-object-tlci-entry-bytes) : String
  (x64_catalog.compiler-x64-template-render-bytes
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciImageBytes)
    (x64_template.CompilerX64TemplateTarget.LinuxX64)
    (object_target.compiler-backend-object-bytes-from-hex
      "4889f84889f74889d64883ec08ffd04883c408c3")))

(define (compiler-backend-object-tlci-macro-entry-bytes) : String
  (x64_catalog.compiler-x64-template-render-bytes
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciMacroBytes)
    (x64_template.CompilerX64TemplateTarget.LinuxX64)
    (object_target.compiler-backend-object-bytes-from-hex
      "4889f84889f74889d64889ca4c89c14d89c84c8b4c24084883ec08ffd04883c408c3")))

(define (compiler-backend-object-exit-bytes) : String
  (x64_catalog.compiler-x64-template-render-bytes
    (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectExitBytes)
    (x64_template.CompilerX64TemplateTarget.LinuxX64)
    (object_target.compiler-backend-object-bytes-from-hex
      "4889c748c7c03c0000000f05")))

(define (compiler-backend-object-add-entry
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (begin
    (x64_catalog.compiler-x64-template-assert-structured!
      (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectStartContribution)
      (x64_template.CompilerX64TemplateTarget.LinuxX64))
    (let
      [entry : String "_tl_start"]
      [with-symbol : object_target.CompilerBackendObjectTargetParts
        (object_target.compiler-backend-object-symbol-export-section
          parts
          (owned_view.compiler-owned-shared-view entry)
          (cobj.CompilerObjectSectionKind.Text)
          (cobj.CompilerObjectSymbolKind.Function))]
      [with-label : object_target.CompilerBackendObjectTargetParts
        (object_target.compiler-backend-object-add-text
          with-symbol
          (cobj.CompilerObjectX64Instr.Label
            (owned_view.compiler-owned-shared-view entry)))]
      [with-main-call : object_target.CompilerBackendObjectTargetParts
        (object_target.compiler-backend-object-add-call-instr
          with-label
          entry
          "main")]
      (object_target.compiler-backend-object-add-text-bytes
        with-main-call
        (compiler-backend-object-exit-bytes)))))

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
        (x64_template.CompilerX64TemplateTarget.LinuxX64)
        (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciImageContribution)
        (x64_template.CompilerX64ExecutableTemplateId.LinuxObjectTlciMacroContribution))]
    [with-entry : object_target.CompilerBackendObjectTargetParts
      (if (and emit-entry (not crt-entry))
        (compiler-backend-object-add-entry with-tlci)
        with-tlci)]
    [final-parts : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        with-entry
        (cobj.CompilerObjectDataRecord.Zero 0))]
    (cobj.CompilerObjectImage
      (cobj.compiler-object-section-builder-finish
        (object_target.compiler-backend-object-base-sections
          (owned_view.compiler-owned-shared-view final-parts)
          4))
      (object_target.compiler-backend-object-base-symbols
        (owned_view.compiler-owned-shared-view final-parts))
      (object_target.compiler-backend-object-base-relocations final-parts))))