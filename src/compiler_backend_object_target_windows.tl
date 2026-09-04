;; compiler_backend_object_target_windows.tl - Windows direct-object policy leaf.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import compiler_backend_object_target as object_target)
(import compiler_object as cobj)
(import compiler_x64_executable_template as x64_template)
(import compiler_x64_executable_template_catalog as x64_catalog)

(defmacro (compiler-backend-object-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(define (compiler-backend-object-registered-bytes
  [id : x64_template.CompilerX64ExecutableTemplateId]
  [hex : String]) : String
  (x64_catalog.compiler-x64-template-render-bytes
    id
    (x64_template.CompilerX64TemplateTarget.WindowsX64)
    (object_target.compiler-backend-object-bytes-from-hex hex)))

(define (compiler-backend-object-chkstk-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectChkstkBytes)
    "51504889c1488d4424104881f9001000007212482d00100000c600004881e900100000ebe54829c8c600005859c3"))

(define (compiler-backend-object-setup-pre-getcmd-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectSetupPreGetcmdBytes)
    "554889e55341544155415641574883ec28"))

(define (compiler-backend-object-setup-after-getcmd-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectSetupAfterGetcmdBytes)
    "4889c34d31e442803c2300740549ffc4ebf4498d4c24014883ec20"))

(define (compiler-backend-object-setup-after-boot1-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectSetupAfterBoot1Bytes)
    "4883c4204989c54831c94c39e17d0d8a040b4188440d0048ffc1ebee43c64425000048c7c1080800004883ec20"))

(define (compiler-backend-object-setup-after-boot2-pre-store-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectSetupAfterBoot2Bytes)
    "4883c4204989c64d31ff4c89eb8a033c0074513c20750548ffc3ebf14981ffff0000007d3f4b891cfe49ffc74531c98a033c00742f3c2275154183f1014889d98a4101880148ffc13c0075f4ebe13c20750d4585c97508c6030048ffc3ebae48ffc3ebcb4bc704fe00000000"))

(define (compiler-backend-object-setup-epilogue-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectSetupEpilogueBytes)
    "4883c428415f415e415d415c5b5dc3"))

(define (compiler-backend-object-add-rdx-rax-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectAddRdxRaxBytes)
    "4801d0"))

(define (compiler-backend-object-ret-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectRetBytes)
    "c3"))

(define (compiler-backend-object-tlci-entry-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectTlciImageBytes)
    "4889c84889d14c89c24883ec28ffd04883c428c3"))

(define (compiler-backend-object-tlci-macro-entry-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectTlciMacroBytes)
    "4889c84889d14c89c24d89c84c8b4c24284c8b5424304c8b5c24384883ec384c895424204c895c2428ffd04883c438c3"))

(define (compiler-backend-object-entry-gs-clear-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectEntryGsClearBytes)
    "6548c704252800000000000000"))

(define (compiler-backend-object-entry-convert-fiber-args-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectConvertFiberArgsBytes)
    "31c9"))

(define (compiler-backend-object-entry-create-fiber-args-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectCreateFiberArgsBytes)
    "b900000100ba0000004041b801000000"))

(define (compiler-backend-object-entry-create-fiber-tail-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectCreateFiberTailBytes)
    "4d89d948c744242000000000"))

(define (compiler-backend-object-entry-stack-guarantee-args-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectStackGuaranteeArgsBytes)
    "c744242000000100488d4c2420"))

(define (compiler-backend-object-entry-stderr-handle-args-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectStderrHandleArgsBytes)
    "b9f4ffffff"))

(define (compiler-backend-object-entry-write-failure-tail-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectWriteFailureTailBytes)
    "41b8360000004d89d948c744242000000000"))

(define (compiler-backend-object-entry-write-overflow-tail-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectWriteOverflowTailBytes)
    "41b8210000004d89d948c744242000000000"))

(define (compiler-backend-object-entry-exit-134-args-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectExit134ArgsBytes)
    "b986000000"))

(define (compiler-backend-object-overflow-filter-test-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectOverflowFilterTestBytes)
    "488b018b0831c081f9fd0000c00f94c0"))

(define (compiler-backend-object-overflow-filter-return-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectOverflowFilterReturnBytes)
    "31c04883c428c3"))

(define (compiler-backend-object-add-rax-branch
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [true-target : String]
  [false-target : String]) : object_target.CompilerBackendObjectTargetParts
  (object_target.compiler-backend-object-add-text
    (object_target.compiler-backend-object-add-text-relocation
      (object_target.compiler-backend-object-add-text-relocation
        parts
        (owned_view.compiler-owned-shared-view site)
        (cobj.CompilerObjectRelocationKind.Branch)
        (owned_view.compiler-owned-shared-view true-target))
      site
      (cobj.CompilerObjectRelocationKind.Branch)
      (owned_view.compiler-owned-shared-view false-target))
    (cobj.CompilerObjectX64Instr.Branch true-target false-target)))

(define (compiler-backend-object-entry-xdata-bytes) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (begin
      ;; UNWIND_INFO: version 1, 4-byte prolog, one UWOP_ALLOC_SMALL(40).
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x01 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x04 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x01 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x00 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x04 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x42 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x00 : u8))
      (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x00 : u8))
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(define compiler-backend-object-manifest-label : String
  ".L_tl_manifest")

(define (compiler-backend-object-manifest-label-shared-view) : String
  (compiler-backend-object-global-shared-view
    compiler-backend-object-manifest-label))

(define compiler-backend-object-rsrc-data-label : String
  ".L_tl_rsrc_data")
(define compiler-backend-object-utf8-manifest : String
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\r\n  <application xmlns=\"urn:schemas-microsoft-com:asm.v3\">\r\n    <windowsSettings>\r\n      <activeCodePage xmlns=\"http://schemas.microsoft.com/SMI/2019/WindowsSettings\">UTF-8</activeCodePage>\r\n    </windowsSettings>\r\n  </application>\r\n</assembly>\r\n")

(define (compiler-backend-object-manifest-resource-records) : cobj.CompilerObjectDataRecordList
  (let
    [records0 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-with-capacity 9)]
    [records1 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records0
        (cobj.CompilerObjectDataRecord.Label ".L_tl_rsrc_base"))]
    [records2 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records1
        (cobj.CompilerObjectDataRecord.Bytes
          (object_target.compiler-backend-object-bytes-from-hex
            "000000000000000000000000000001001800000018000080000000000000000000000000000001000100000030000080000000000000000000000000000001000904000048000000")))]
    [records3 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records2
        (cobj.CompilerObjectDataRecord.Label
          (compiler-backend-object-global-shared-view
            compiler-backend-object-rsrc-data-label)))]
    [records4 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records3
        (cobj.CompilerObjectDataRecord.SymbolRva32
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)))]
    [records5 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records4
        ;; Manifest size is 376 bytes (0x178), followed by codepage/reserved zeros.
        (cobj.CompilerObjectDataRecord.Bytes
          (object_target.compiler-backend-object-bytes-from-hex
            "780100000000000000000000")))]
    [records6 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records5
        (cobj.CompilerObjectDataRecord.Align 4))]
    [records7 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records6
        (cobj.CompilerObjectDataRecord.Label
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)))]
    [records8 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records7
        (cobj.CompilerObjectDataRecord.Bytes
          (compiler-backend-object-global-shared-view
            compiler-backend-object-utf8-manifest)))]
    [records9 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records8
        (cobj.CompilerObjectDataRecord.Label ".L_tl_manifest_end"))]
    (cobj.compiler-object-data-record-builder-finish records9)))

(define (compiler-backend-object-add-entry-data
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [with-argc-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        parts
        ".L_tl_argc"
        (cobj.CompilerObjectSectionKind.Data)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-argc : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-data
        (object_target.compiler-backend-object-add-data
          with-argc-symbol
          (cobj.CompilerObjectDataRecord.Label ".L_tl_argc"))
        (cobj.CompilerObjectDataRecord.I64 0))]
    [with-argv-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-argc
        ".L_tl_argv"
        (cobj.CompilerObjectSectionKind.Data)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-argv : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-data
        (object_target.compiler-backend-object-add-data
          with-argv-symbol
          (cobj.CompilerObjectDataRecord.Label ".L_tl_argv"))
        (cobj.CompilerObjectDataRecord.I64 0))]
    [with-boot-off-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-argv
        "tl_boot_off"
        (cobj.CompilerObjectSectionKind.Bss)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-boot-off : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        (object_target.compiler-backend-object-add-bss
          (object_target.compiler-backend-object-add-bss
            with-boot-off-symbol
            (cobj.CompilerObjectDataRecord.Align 8))
          (cobj.CompilerObjectDataRecord.Label "tl_boot_off"))
        (cobj.CompilerObjectDataRecord.Zero 8))]
    [with-boot-pool-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-boot-off
        "tl_boot_pool"
        (cobj.CompilerObjectSectionKind.Bss)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-boot-pool : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        (object_target.compiler-backend-object-add-bss
          with-boot-pool-symbol
          (cobj.CompilerObjectDataRecord.Label "tl_boot_pool"))
        (cobj.CompilerObjectDataRecord.Zero 524288))]
    [with-stack-written-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-boot-pool
        ".L_tl_main_stack_written"
        (cobj.CompilerObjectSectionKind.Bss)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-stack-written : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        (object_target.compiler-backend-object-add-bss
          (object_target.compiler-backend-object-add-bss
            with-stack-written-symbol
            (cobj.CompilerObjectDataRecord.Align 8))
          (cobj.CompilerObjectDataRecord.Label ".L_tl_main_stack_written"))
        (cobj.CompilerObjectDataRecord.Zero 8))]
    [with-stack-message-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-stack-written
        ".L_tl_main_stack_reservation_msg"
        (cobj.CompilerObjectSectionKind.Rodata)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-stack-message : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rodata
        (object_target.compiler-backend-object-add-rodata
          with-stack-message-symbol
          (cobj.CompilerObjectDataRecord.Label
            ".L_tl_main_stack_reservation_msg"))
        (cobj.CompilerObjectDataRecord.Bytes
          "typelisp runtime: 1 GiB main-stack reservation failed\n"))]
    [with-overflow-message-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-stack-message
        ".L_tl_stack_overflow_msg"
        (cobj.CompilerObjectSectionKind.Rodata)
        (cobj.CompilerObjectSymbolKind.Data))]
    (object_target.compiler-backend-object-add-rodata
      (object_target.compiler-backend-object-add-rodata
        with-overflow-message-symbol
        (cobj.CompilerObjectDataRecord.Label ".L_tl_stack_overflow_msg"))
      (cobj.CompilerObjectDataRecord.Bytes "typelisp runtime: stack overflow\n"))))

(define (compiler-backend-object-add-runtime-text
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [_registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectRuntimeSupportContribution)
        (x64_template.CompilerX64TemplateTarget.WindowsX64))]
    [with-symbols : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        (object_target.compiler-backend-object-symbol-local-section
          (object_target.compiler-backend-object-symbol-local-section
            (object_target.compiler-backend-object-symbol-local-section
              parts
              "__chkstk"
              (cobj.CompilerObjectSectionKind.Text)
              (cobj.CompilerObjectSymbolKind.Runtime))
            "tl_setup_argv"
            (cobj.CompilerObjectSectionKind.Text)
            (cobj.CompilerObjectSymbolKind.Runtime))
          ".L_tl_boot_alloc"
          (cobj.CompilerObjectSectionKind.Text)
          (cobj.CompilerObjectSymbolKind.Runtime))
        "GetCommandLineA"
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-chkstk-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-symbols
        (cobj.CompilerObjectX64Instr.Label "__chkstk"))]
    [with-chkstk : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-chkstk-label
        (compiler-backend-object-chkstk-bytes))]
    [with-setup-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-chkstk
        (cobj.CompilerObjectX64Instr.Label "tl_setup_argv"))]
    [with-setup-pre : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-setup-label
        (compiler-backend-object-setup-pre-getcmd-bytes))]
    [with-getcmd-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-setup-pre
        "tl_setup_argv"
        "GetCommandLineA")]
    [with-after-getcmd : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-getcmd-call
        (compiler-backend-object-setup-after-getcmd-bytes))]
    [with-boot1-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-after-getcmd
        "tl_setup_argv"
        ".L_tl_boot_alloc")]
    [with-after-boot1 : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-boot1-call
        (compiler-backend-object-setup-after-boot1-bytes))]
    [with-boot2-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-after-boot1
        "tl_setup_argv"
        ".L_tl_boot_alloc")]
    [with-after-boot2 : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-boot2-call
        (compiler-backend-object-setup-after-boot2-pre-store-bytes))]
    [with-argc-store : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-after-boot2
        "tl_setup_argv"
        (cobj.CompilerObjectRelocationKind.RipAddress)
        ".L_tl_argc"
        (cobj.CompilerObjectX64Instr.StoreR15Rip ".L_tl_argc"))]
    [with-argv-store : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-argc-store
        "tl_setup_argv"
        (cobj.CompilerObjectRelocationKind.RipAddress)
        ".L_tl_argv"
        (cobj.CompilerObjectX64Instr.StoreR14Rip ".L_tl_argv"))]
    [with-setup-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-argv-store
        (compiler-backend-object-setup-epilogue-bytes))]
    [with-boot-public-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-setup-end
        (cobj.CompilerObjectX64Instr.Label "tl_alloc"))]
    [with-boot-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-boot-public-label
        (cobj.CompilerObjectX64Instr.Label ".L_tl_boot_alloc"))]
    [with-boot-off-load : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-boot-label
        ".L_tl_boot_alloc"
        (cobj.CompilerObjectRelocationKind.RipValue)
        "tl_boot_off"
        (cobj.CompilerObjectX64Instr.LoadRip "tl_boot_off"))]
    [with-boot-pool-lea : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-boot-off-load
        ".L_tl_boot_alloc"
        (cobj.CompilerObjectRelocationKind.RipAddress)
        "tl_boot_pool"
        (cobj.CompilerObjectX64Instr.LoadRipAddressRdx "tl_boot_pool"))]
    [with-add-base : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-boot-pool-lea
        (compiler-backend-object-add-rdx-rax-bytes))]
    [with-boot-off-add : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-add-base
        ".L_tl_boot_alloc"
        (cobj.CompilerObjectRelocationKind.RipAddress)
        "tl_boot_off"
        (cobj.CompilerObjectX64Instr.AddRcxRip "tl_boot_off"))]
    (object_target.compiler-backend-object-add-text-bytes
      with-boot-off-add
      (compiler-backend-object-ret-bytes))))

(define (compiler-backend-object-add-entry-text
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [_start-registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectStartContribution)
        (x64_template.CompilerX64TemplateTarget.WindowsX64))]
    [_fiber-registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectMainFiberContribution)
        (x64_template.CompilerX64TemplateTarget.WindowsX64))]
    [_filter-registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectOverflowFilterContribution)
        (x64_template.CompilerX64TemplateTarget.WindowsX64))]
    [entry : String "_tl_start"]
    [entry-end : String ".L_tl_start_end"]
    [fiber : String ".L_tl_main_fiber"]
    [fiber-end : String ".L_tl_main_fiber_end"]
    [converted : String ".L_tl_start_converted_to_fiber"]
    [created : String ".L_tl_start_main_fiber_created"]
    [failed : String ".L_tl_main_stack_reservation_failed"]
    [overflow-filter : String ".L_tl_stack_overflow_filter"]
    [overflow-filter-end : String ".L_tl_stack_overflow_filter_end"]
    [overflow-write : String ".L_tl_stack_overflow_write"]
    [overflow-continue : String ".L_tl_stack_overflow_continue_search"]
    [with-symbols : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        (object_target.compiler-backend-object-symbol-extern-once
          (object_target.compiler-backend-object-symbol-extern-once
            (object_target.compiler-backend-object-symbol-extern-once
              (object_target.compiler-backend-object-symbol-extern-once
                (object_target.compiler-backend-object-symbol-extern-once
                  (object_target.compiler-backend-object-symbol-local-section
                    (object_target.compiler-backend-object-symbol-local-section
                      (object_target.compiler-backend-object-symbol-local-section
                        (object_target.compiler-backend-object-symbol-local-section
                          (object_target.compiler-backend-object-symbol-local-section
                            (object_target.compiler-backend-object-symbol-local-section
                              (object_target.compiler-backend-object-symbol-export-section
                                parts
                                (owned_view.compiler-owned-shared-view entry)
                                (cobj.CompilerObjectSectionKind.Text)
                                (cobj.CompilerObjectSymbolKind.Function))
                              (owned_view.compiler-owned-shared-view entry-end)
                              (cobj.CompilerObjectSectionKind.Text)
                              (cobj.CompilerObjectSymbolKind.Function))
                            (owned_view.compiler-owned-shared-view fiber)
                            (cobj.CompilerObjectSectionKind.Text)
                            (cobj.CompilerObjectSymbolKind.Function))
                          (owned_view.compiler-owned-shared-view fiber-end)
                          (cobj.CompilerObjectSectionKind.Text)
                          (cobj.CompilerObjectSymbolKind.Function))
                        (owned_view.compiler-owned-shared-view converted)
                        (cobj.CompilerObjectSectionKind.Text)
                        (cobj.CompilerObjectSymbolKind.Function))
                      (owned_view.compiler-owned-shared-view created)
                      (cobj.CompilerObjectSectionKind.Text)
                      (cobj.CompilerObjectSymbolKind.Function))
                    (owned_view.compiler-owned-shared-view failed)
                    (cobj.CompilerObjectSectionKind.Text)
                    (cobj.CompilerObjectSymbolKind.Function))
                  "ExitProcess"
                  (cobj.CompilerObjectSymbolKind.Function))
                "ConvertThreadToFiber"
                (cobj.CompilerObjectSymbolKind.Function))
              "CreateFiberEx"
              (cobj.CompilerObjectSymbolKind.Function))
            "SwitchToFiber"
            (cobj.CompilerObjectSymbolKind.Function))
          "GetStdHandle"
          (cobj.CompilerObjectSymbolKind.Function))
        "WriteFile"
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-overflow-filter-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-symbols
        (owned_view.compiler-owned-shared-view overflow-filter)
        (cobj.CompilerObjectSectionKind.Text)
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-overflow-filter-end-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-overflow-filter-symbol
        (owned_view.compiler-owned-shared-view overflow-filter-end)
        (cobj.CompilerObjectSectionKind.Text)
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-overflow-write-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-overflow-filter-end-symbol
        (owned_view.compiler-owned-shared-view overflow-write)
        (cobj.CompilerObjectSectionKind.Text)
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-overflow-continue-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-overflow-write-symbol
        (owned_view.compiler-owned-shared-view overflow-continue)
        (cobj.CompilerObjectSectionKind.Text)
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-stack-guarantee-extern : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        with-overflow-continue-symbol
        "SetThreadStackGuarantee"
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-exception-filter-extern : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        with-stack-guarantee-extern
        "SetUnhandledExceptionFilter"
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-exception-filter-extern
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view entry)))]
    [with-sub : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-label
        (cobj.CompilerObjectX64Instr.SubRspImm8 40))]
    [with-setup-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-sub
        (owned_view.compiler-owned-shared-view entry)
        "tl_setup_argv")]
    [with-gs-clear : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-setup-call
        (compiler-backend-object-entry-gs-clear-bytes))]
    [with-filter-address : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-gs-clear
        (owned_view.compiler-owned-shared-view entry)
        (cobj.CompilerObjectRelocationKind.RipAddress)
        (owned_view.compiler-owned-shared-view overflow-filter)
        (cobj.CompilerObjectX64Instr.LoadRipAddress
          (owned_view.compiler-owned-shared-view overflow-filter)))]
    [with-filter-argument : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-filter-address
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-filter-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-filter-argument
        (owned_view.compiler-owned-shared-view entry)
        "SetUnhandledExceptionFilter")]
    [with-convert-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-filter-call
        (compiler-backend-object-entry-convert-fiber-args-bytes))]
    [with-convert-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-convert-args
        (owned_view.compiler-owned-shared-view entry)
        "ConvertThreadToFiber")]
    [with-convert-branch : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-rax-branch
        with-convert-call
        (owned_view.compiler-owned-shared-view entry)
        (owned_view.compiler-owned-shared-view converted)
        (owned_view.compiler-owned-shared-view failed))]
    [with-converted-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-convert-branch
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view converted)))]
    [with-create-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-converted-label
        (compiler-backend-object-entry-create-fiber-args-bytes))]
    [with-fiber-address : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-create-args
        (owned_view.compiler-owned-shared-view entry)
        (cobj.CompilerObjectRelocationKind.RipAddress)
        (owned_view.compiler-owned-shared-view fiber)
        (cobj.CompilerObjectX64Instr.LoadRipAddressR11
          (owned_view.compiler-owned-shared-view fiber)))]
    [with-create-tail : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-fiber-address
        (compiler-backend-object-entry-create-fiber-tail-bytes))]
    [with-create-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-create-tail
        (owned_view.compiler-owned-shared-view entry)
        "CreateFiberEx")]
    [with-create-branch : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-rax-branch
        with-create-call
        (owned_view.compiler-owned-shared-view entry)
        (owned_view.compiler-owned-shared-view created)
        (owned_view.compiler-owned-shared-view failed))]
    [with-created-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-create-branch
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view created)))]
    [with-fiber-argument : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-created-label
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-switch-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-fiber-argument
        (owned_view.compiler-owned-shared-view entry)
        "SwitchToFiber")]
    [with-switch-failed : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        (object_target.compiler-backend-object-add-text-relocation
          with-switch-call
          (owned_view.compiler-owned-shared-view entry)
          (cobj.CompilerObjectRelocationKind.Branch)
          (owned_view.compiler-owned-shared-view failed))
        (cobj.CompilerObjectX64Instr.Jump
          (owned_view.compiler-owned-shared-view failed)))]
    [with-failed-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-switch-failed
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view failed)))]
    [with-stderr-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-failed-label
        (compiler-backend-object-entry-stderr-handle-args-bytes))]
    [with-stderr-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-stderr-args
        (owned_view.compiler-owned-shared-view entry)
        "GetStdHandle")]
    [with-stderr-handle : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-stderr-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-message : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-stderr-handle
        (owned_view.compiler-owned-shared-view entry)
        (cobj.CompilerObjectRelocationKind.RipAddress)
        ".L_tl_main_stack_reservation_msg"
        (cobj.CompilerObjectX64Instr.LoadRipAddressRdx
          ".L_tl_main_stack_reservation_msg"))]
    [with-written : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-message
        (owned_view.compiler-owned-shared-view entry)
        (cobj.CompilerObjectRelocationKind.RipAddress)
        ".L_tl_main_stack_written"
        (cobj.CompilerObjectX64Instr.LoadRipAddressR11
          ".L_tl_main_stack_written"))]
    [with-write-tail : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-written
        (compiler-backend-object-entry-write-failure-tail-bytes))]
    [with-write-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-write-tail
        (owned_view.compiler-owned-shared-view entry)
        "WriteFile")]
    [with-exit-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-write-call
        (compiler-backend-object-entry-exit-134-args-bytes))]
    [with-failure-exit : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-exit-args
        (owned_view.compiler-owned-shared-view entry)
        "ExitProcess")]
    [with-entry-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-failure-exit
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view entry-end)))]
    [with-fiber-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-entry-end
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view fiber)))]
    [with-fiber-sub : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-fiber-label
        (cobj.CompilerObjectX64Instr.SubRspImm8 40))]
    [with-stack-guarantee-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-fiber-sub
        (compiler-backend-object-entry-stack-guarantee-args-bytes))]
    [with-stack-guarantee-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-stack-guarantee-args
        (owned_view.compiler-owned-shared-view fiber)
        "SetThreadStackGuarantee")]
    [with-argc : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-stack-guarantee-call
        (owned_view.compiler-owned-shared-view fiber)
        (cobj.CompilerObjectRelocationKind.RipValue)
        ".L_tl_argc"
        (cobj.CompilerObjectX64Instr.MovRcxRip ".L_tl_argc"))]
    [with-argv : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-argc
        (owned_view.compiler-owned-shared-view fiber)
        (cobj.CompilerObjectRelocationKind.RipValue)
        ".L_tl_argv"
        (cobj.CompilerObjectX64Instr.MovRdxRip ".L_tl_argv"))]
    [with-main-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-argv
        (owned_view.compiler-owned-shared-view fiber)
        "main")]
    [with-move-exit-code : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-main-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-exit-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-move-exit-code
        (owned_view.compiler-owned-shared-view fiber)
        "ExitProcess")]
    [with-fiber-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-exit-call
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view fiber-end)))]
    [with-overflow-filter-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-fiber-end
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view overflow-filter)))]
    [with-overflow-filter-sub : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-filter-label
        (cobj.CompilerObjectX64Instr.SubRspImm8 40))]
    [with-overflow-filter-test : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-filter-sub
        (compiler-backend-object-overflow-filter-test-bytes))]
    [with-overflow-filter-branch : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-rax-branch
        with-overflow-filter-test
        (owned_view.compiler-owned-shared-view overflow-filter)
        (owned_view.compiler-owned-shared-view overflow-write)
        (owned_view.compiler-owned-shared-view overflow-continue))]
    [with-overflow-write-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-filter-branch
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view overflow-write)))]
    [with-overflow-stderr-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-write-label
        (compiler-backend-object-entry-stderr-handle-args-bytes))]
    [with-overflow-stderr-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-overflow-stderr-args
        (owned_view.compiler-owned-shared-view overflow-filter)
        "GetStdHandle")]
    [with-overflow-stderr-handle : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-stderr-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-overflow-message : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-overflow-stderr-handle
        (owned_view.compiler-owned-shared-view overflow-filter)
        (cobj.CompilerObjectRelocationKind.RipAddress)
        ".L_tl_stack_overflow_msg"
        (cobj.CompilerObjectX64Instr.LoadRipAddressRdx
          ".L_tl_stack_overflow_msg"))]
    [with-overflow-written : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-overflow-message
        (owned_view.compiler-owned-shared-view overflow-filter)
        (cobj.CompilerObjectRelocationKind.RipAddress)
        ".L_tl_main_stack_written"
        (cobj.CompilerObjectX64Instr.LoadRipAddressR11
          ".L_tl_main_stack_written"))]
    [with-overflow-write-tail : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-written
        (compiler-backend-object-entry-write-overflow-tail-bytes))]
    [with-overflow-write-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-overflow-write-tail
        (owned_view.compiler-owned-shared-view overflow-filter)
        "WriteFile")]
    [with-overflow-exit-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-write-call
        (compiler-backend-object-entry-exit-134-args-bytes))]
    [with-overflow-exit : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-overflow-exit-args
        (owned_view.compiler-owned-shared-view overflow-filter)
        "ExitProcess")]
    [with-overflow-continue-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-exit
        (cobj.CompilerObjectX64Instr.Label
          (owned_view.compiler-owned-shared-view overflow-continue)))]
    [with-overflow-return : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-continue-label
        (compiler-backend-object-overflow-filter-return-bytes))]
    (object_target.compiler-backend-object-add-text
      with-overflow-return
      (cobj.CompilerObjectX64Instr.Label
        (owned_view.compiler-owned-shared-view overflow-filter-end)))))

(define (compiler-backend-object-add-entry-unwind
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [xdata-label : String ".L_tl_start_xdata"]
    [pdata-begin : String ".L_tl_start_pdata_begin"]
    [pdata-end : String ".L_tl_start_pdata_end"]
    [pdata-unwind : String ".L_tl_start_pdata_unwind"]
    [fiber-pdata-begin : String ".L_tl_main_fiber_pdata_begin"]
    [fiber-pdata-end : String ".L_tl_main_fiber_pdata_end"]
    [fiber-pdata-unwind : String ".L_tl_main_fiber_pdata_unwind"]
    [filter-pdata-begin : String ".L_tl_stack_overflow_filter_pdata_begin"]
    [filter-pdata-end : String ".L_tl_stack_overflow_filter_pdata_end"]
    [filter-pdata-unwind : String ".L_tl_stack_overflow_filter_pdata_unwind"]
    [with-xdata-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        parts
        (owned_view.compiler-owned-shared-view xdata-label)
        (cobj.CompilerObjectSectionKind.Xdata)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-xdata : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-xdata
        (object_target.compiler-backend-object-add-xdata
          with-xdata-symbol
          (cobj.CompilerObjectDataRecord.Label
            (owned_view.compiler-owned-shared-view xdata-label)))
        (cobj.CompilerObjectDataRecord.Bytes
          (compiler-backend-object-entry-xdata-bytes)))]
    [with-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-xdata
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view pdata-begin)))
          pdata-begin
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          "_tl_start")
        (cobj.CompilerObjectDataRecord.SymbolRva32 "_tl_start"))]
    [with-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-begin
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view pdata-end)))
          pdata-end
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          ".L_tl_start_end")
        (cobj.CompilerObjectDataRecord.SymbolRva32 ".L_tl_start_end"))]
    [with-pdata-unwind : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-end
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view pdata-unwind)))
          pdata-unwind
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          (owned_view.compiler-owned-shared-view xdata-label))
        (cobj.CompilerObjectDataRecord.SymbolRva32
          (owned_view.compiler-owned-shared-view xdata-label)))]
    [with-fiber-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-unwind
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view fiber-pdata-begin)))
          fiber-pdata-begin
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          ".L_tl_main_fiber")
        (cobj.CompilerObjectDataRecord.SymbolRva32 ".L_tl_main_fiber"))]
    [with-fiber-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-fiber-pdata-begin
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view fiber-pdata-end)))
          fiber-pdata-end
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          ".L_tl_main_fiber_end")
        (cobj.CompilerObjectDataRecord.SymbolRva32 ".L_tl_main_fiber_end"))]
    [with-fiber-pdata-unwind : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-fiber-pdata-end
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view fiber-pdata-unwind)))
          fiber-pdata-unwind
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          (owned_view.compiler-owned-shared-view xdata-label))
        (cobj.CompilerObjectDataRecord.SymbolRva32
          (owned_view.compiler-owned-shared-view xdata-label)))]
    [with-filter-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-fiber-pdata-unwind
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view filter-pdata-begin)))
          filter-pdata-begin
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          ".L_tl_stack_overflow_filter")
        (cobj.CompilerObjectDataRecord.SymbolRva32
          ".L_tl_stack_overflow_filter"))]
    [with-filter-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-filter-pdata-begin
            (cobj.CompilerObjectDataRecord.Label
              (owned_view.compiler-owned-shared-view filter-pdata-end)))
          filter-pdata-end
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          ".L_tl_stack_overflow_filter_end")
        (cobj.CompilerObjectDataRecord.SymbolRva32
          ".L_tl_stack_overflow_filter_end"))]
    (object_target.compiler-backend-object-add-pdata
      (object_target.compiler-backend-object-add-pdata-relocation
        (object_target.compiler-backend-object-add-pdata
          with-filter-pdata-end
          (cobj.CompilerObjectDataRecord.Label
            (owned_view.compiler-owned-shared-view filter-pdata-unwind)))
        filter-pdata-unwind
        (cobj.CompilerObjectRelocationKind.Addr32Nb)
        (owned_view.compiler-owned-shared-view xdata-label))
      (cobj.CompilerObjectDataRecord.SymbolRva32 xdata-label))))

(define (compiler-backend-object-add-entry
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-entry-unwind
    (compiler-backend-object-add-entry-text
      (compiler-backend-object-add-runtime-text
        (compiler-backend-object-add-entry-data parts)))))

(define (compiler-backend-object-image-sections
  [parts : object_target.CompilerBackendObjectTargetParts]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectSectionList
  (let
    [empty-instrs : cobj.CompilerObjectX64InstrList
      (object_target.compiler-backend-object-empty-instrs)]
    [sections4 : cobj.CompilerObjectSectionBuilder
      (object_target.compiler-backend-object-base-sections
        (owned_view.compiler-owned-shared-view parts)
        7)]
    [sections5 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections4
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Pdata)
          (cobj.compiler-object-data-record-builder-finish parts.pdata)
          (owned_view.compiler-owned-shared-view empty-instrs)))]
    [sections6 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections5
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Xdata)
          (cobj.compiler-object-data-record-builder-finish parts.xdata)
          (owned_view.compiler-owned-shared-view empty-instrs)))]
    (cobj.compiler-object-section-builder-finish
      (cobj.compiler-object-section-builder-push
        sections6
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Rsrc)
          (if emit-manifest-resource
            (compiler-backend-object-manifest-resource-records)
            (object_target.compiler-backend-object-empty-data-records))
          empty-instrs)))))

(define (compiler-backend-object-image-symbols
  [parts : object_target.CompilerBackendObjectTargetParts]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectSymbolList
  (cobj.compiler-object-symbol-builder-finish
    (if emit-manifest-resource
      (cobj.compiler-object-symbol-builder-push
        parts.symbols
        (cobj.CompilerObjectSymbol.Symbol
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)
          (cobj.CompilerObjectSymbolBinding.Local)
          (cobj.CompilerObjectSymbolKind.Data)
          (cobj.CompilerObjectMaybeSection.Some
            (cobj.CompilerObjectSectionKind.Rsrc))))
      parts.symbols)))

(define (compiler-backend-object-image-relocations
  [parts : object_target.CompilerBackendObjectTargetParts]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectRelocationList
  (cobj.compiler-object-relocation-builder-finish
    (if emit-manifest-resource
      (cobj.compiler-object-relocation-builder-push
        parts.relocations
        (cobj.CompilerObjectRelocation.Relocation
          (cobj.CompilerObjectSectionKind.Rsrc)
          (compiler-backend-object-global-shared-view
            compiler-backend-object-rsrc-data-label)
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)))
      parts.relocations)))

(define (compiler-backend-object-target-windows-image
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
        (x64_template.CompilerX64TemplateTarget.WindowsX64)
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectTlciImageContribution)
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectTlciMacroContribution))]
    [emit-native-entry : bool (and emit-entry (not crt-entry))]
    [with-entry : object_target.CompilerBackendObjectTargetParts
      (if emit-native-entry
        (compiler-backend-object-add-entry with-tlci)
        with-tlci)]
    [final-parts : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        with-entry
        (cobj.CompilerObjectDataRecord.Zero 0))]
    (cobj.CompilerObjectImage
      (compiler-backend-object-image-sections
        (owned_view.compiler-owned-shared-view final-parts)
        emit-native-entry)
      (compiler-backend-object-image-symbols
        (owned_view.compiler-owned-shared-view final-parts)
        emit-native-entry)
      (compiler-backend-object-image-relocations final-parts emit-native-entry))))