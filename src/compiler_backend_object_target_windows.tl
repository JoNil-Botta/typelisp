;; compiler_backend_object_target_windows.tl - Windows direct-object policy leaf.
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_backend_object_target as object_target)
(import compiler_object as cobj)
(import compiler_x64_executable_template as x64_template)
(import compiler_x64_executable_template_catalog as x64_catalog)

(defmacro (compiler-backend-object-global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (compiler-backend-object-registered-bytes
  [id : x64_template.CompilerX64ExecutableTemplateId]
  [hex : (& str)]) : String
  (x64_catalog.compiler-x64-template-render-bytes
    id
    (WindowsX64)
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
    "4883c4204989c54831c94c39e17d0d8a040b4188440d0048ffc1ebee43c64425000048c7c1000004004883ec20"))

(define (compiler-backend-object-setup-after-boot2-pre-store-bytes) : String
  (compiler-backend-object-registered-bytes
    (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectSetupAfterBoot2Bytes)
    "4883c4204989c64d31ff4c89eb8a0384c00f84b40000003c2074043c09750548ffc3ebe94f892cfe49ffc74531c98a0384c00f848e0000003c2074043c0975124585c9750d48ffc341c645000049ffc5ebbb4983ff01744f3c5c75374d31e449ffc448ffc3803b5c74f54d89e2803b22750349d1ea4d85d2740d41c645005c49ffc549ffcaebee8a033c2275a141f6c40175243c2275204585c9740f807b0122750948ffc3eb103c22750c4183f10148ffc3e977ffffff4188450049ffc548ffc3e968ffffff41c64500004bc704fe00000000"))

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
    "56574883ec284889c84889d14c89c24d89c84c8b4c2460488b742468488b7c2470ffd04883c4285f5ec3"))

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
  ;; Both relocations and the branch each own a copy of the labels.
  (object_target.compiler-backend-object-add-text
    (object_target.compiler-backend-object-add-text-relocation
      (object_target.compiler-backend-object-add-text-relocation
        parts
        (string.copy (& site))
        (Branch)
        (string.copy (& true-target)))
      site
      (Branch)
      (string.copy (& false-target)))
    (cobj.CompilerObjectX64Instr.Branch true-target false-target)))

(define (compiler-backend-object-entry-xdata-bytes) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    ;; UNWIND_INFO: version 1, 4-byte prolog, one UWOP_ALLOC_SMALL(40).
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x01 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x04 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x01 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x00 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x04 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x42 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x00 : u8))
    (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0x00 : u8))
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

(define (compiler-backend-object-unwind-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast (bit-and value 255) : u8)))

(define (compiler-backend-object-entry-range-unwind-bytes
  [frame : i64]
  [prologue-size : i64]
  [save-rsi-rdi? : bool]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [slots : i64
      (if (<= frame 128)
        1
        (if (<= frame 524280)
          2
          3))]
    [count : i64
      (+
        slots
        (if save-rsi-rdi?
          2
          0))]
    (compiler-backend-object-unwind-push-u8! (&mut out) 1)
    (compiler-backend-object-unwind-push-u8! (&mut out) prologue-size)
    (compiler-backend-object-unwind-push-u8! (&mut out) count)
    (compiler-backend-object-unwind-push-u8! (&mut out) 0)
    (compiler-backend-object-unwind-push-u8! (&mut out) prologue-size)
    (cond
      [(= slots 1)
        (compiler-backend-object-unwind-push-u8!
          (&mut out)
          (+ 2 (* 16 (- (/ frame 8) 1))))]
      [(= slots 2)
        (compiler-backend-object-unwind-push-u8! (&mut out) 1)
        (byte_le.push-u16! (&mut out) (/ frame 8))]
      [else
        (compiler-backend-object-unwind-push-u8! (&mut out) 0x11)
        (byte_le.push-u32! (&mut out) frame)])
    ;; Codes are in reverse prologue order: allocation, RDI, RSI.
    (when
      save-rsi-rdi?
      (compiler-backend-object-unwind-push-u8! (&mut out) 2)
      (compiler-backend-object-unwind-push-u8! (&mut out) 0x70)
      (compiler-backend-object-unwind-push-u8! (&mut out) 1)
      (compiler-backend-object-unwind-push-u8! (&mut out) 0x60))
    (when (= (% count 2) 1) (byte_le.push-u16! (&mut out) 0))
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

;; Every range supplies its own unwind bytes; related RVAs are emitted together
;; so no generated entry can accidentally inherit another entry's frame plan.
(define (compiler-backend-object-add-unwind
  [parts : object_target.CompilerBackendObjectTargetParts]
  [entry : String]
  [end : String]
  [bytes : String]) : object_target.CompilerBackendObjectTargetParts
  (let
    [with-entry : object_target.CompilerBackendObjectTargetParts
      (if (or
        (cobj.compiler-object-symbol-builder-contains?
          (& parts.symbols)
          entry
          (Local)
          (Function))
        (cobj.compiler-object-symbol-builder-contains?
          (& parts.symbols)
          entry
          (Export)
          (Function)))
        parts
        (object_target.compiler-backend-object-symbol-local-section
          parts
          (string.copy (& entry))
          (Text)
          (Function)))]
    [with-end : object_target.CompilerBackendObjectTargetParts
      (if (cobj.compiler-object-symbol-builder-contains?
        (& with-entry.symbols)
        end
        (Local)
        (Function))
        with-entry
        (object_target.compiler-backend-object-symbol-local-section
          with-entry
          (string.copy (& end))
          (Text)
          (Function)))]
    [unwind : String (str_cat.str-cat (string.copy (& entry)) "$unwind")]
    [out : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-xdata
        (object_target.compiler-backend-object-add-xdata
          (object_target.compiler-backend-object-add-xdata
            (object_target.compiler-backend-object-symbol-local-section
              with-end
              (string.copy (& unwind))
              (Xdata)
              (Data))
            (Align 4))
          (Label (string.copy (& unwind))))
        (Bytes bytes))]
    [targets : (Array String 3) (array (string.copy (& entry)) end unwind)]
    (for [i (iterator.range 0 3)]
      (let
        [site : String
          (str_cat.str-cat
            (string.copy (& entry))
            "$pdata"
            (string.int->string i))]
        [target : String (string.copy (& (array-ref targets i)))]
        (set!
          out
          (object_target.compiler-backend-object-add-pdata
            (object_target.compiler-backend-object-add-pdata-relocation
              (object_target.compiler-backend-object-add-pdata
                out
                (Label (string.copy (& site))))
              site
              (Addr32Nb)
              (string.copy (& target)))
            (SymbolRva32 target)))))
    out))

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
        (Label ".L_tl_rsrc_base"))]
    [records2 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records1
        (Bytes
          (object_target.compiler-backend-object-bytes-from-hex
            "000000000000000000000000000001001800000018000080000000000000000000000000000001000100000030000080000000000000000000000000000001000904000048000000")))]
    [records3 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records2
        (Label
          (compiler-backend-object-global-shared-view
            compiler-backend-object-rsrc-data-label)))]
    [records4 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records3
        (SymbolRva32
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)))]
    [records5 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records4
        ;; Manifest size is 376 bytes (0x178), followed by codepage/reserved zeros.
        (Bytes
          (object_target.compiler-backend-object-bytes-from-hex
            "780100000000000000000000")))]
    [records6 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push records5 (Align 4))]
    [records7 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records6
        (Label
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)))]
    [records8 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records7
        (Bytes
          (compiler-backend-object-global-shared-view
            compiler-backend-object-utf8-manifest)))]
    [records9 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records8
        (Label ".L_tl_manifest_end"))]
    (cobj.compiler-object-data-record-builder-finish records9)))

(define (compiler-backend-object-add-entry-data
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [with-argc-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        parts
        ".L_tl_argc"
        (Data)
        (Data))]
    [with-argc : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-data
        (object_target.compiler-backend-object-add-data
          with-argc-symbol
          (Label ".L_tl_argc"))
        (I64 0))]
    [with-argv-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-argc
        ".L_tl_argv"
        (Data)
        (Data))]
    [with-argv : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-data
        (object_target.compiler-backend-object-add-data
          with-argv-symbol
          (Label ".L_tl_argv"))
        (I64 0))]
    [with-boot-off-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-argv
        "tl_boot_off"
        (Bss)
        (Data))]
    [with-boot-off : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        (object_target.compiler-backend-object-add-bss
          (object_target.compiler-backend-object-add-bss
            with-boot-off-symbol
            (Align 8))
          (Label "tl_boot_off"))
        (Zero 8))]
    [with-boot-pool-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-boot-off
        "tl_boot_pool"
        (Bss)
        (Data))]
    [with-boot-pool : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        (object_target.compiler-backend-object-add-bss
          with-boot-pool-symbol
          (Label "tl_boot_pool"))
        (Zero 524288))]
    [with-stack-written-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-boot-pool
        ".L_tl_main_stack_written"
        (Bss)
        (Data))]
    [with-stack-written : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss
        (object_target.compiler-backend-object-add-bss
          (object_target.compiler-backend-object-add-bss
            with-stack-written-symbol
            (Align 8))
          (Label ".L_tl_main_stack_written"))
        (Zero 8))]
    [with-stack-message-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-stack-written
        ".L_tl_main_stack_reservation_msg"
        (Rodata)
        (Data))]
    [with-stack-message : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rodata
        (object_target.compiler-backend-object-add-rodata
          with-stack-message-symbol
          (Label ".L_tl_main_stack_reservation_msg"))
        (Bytes "typelisp runtime: 1 GiB main-stack reservation failed\n"))]
    [with-overflow-message-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-stack-message
        ".L_tl_stack_overflow_msg"
        (Rodata)
        (Data))]
    (object_target.compiler-backend-object-add-rodata
      (object_target.compiler-backend-object-add-rodata
        with-overflow-message-symbol
        (Label ".L_tl_stack_overflow_msg"))
      (Bytes "typelisp runtime: stack overflow\n"))))

(define (compiler-backend-object-add-runtime-text
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [_registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectRuntimeSupportContribution)
        (WindowsX64))]
    [with-symbols : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        (object_target.compiler-backend-object-symbol-local-section
          (object_target.compiler-backend-object-symbol-local-section
            (object_target.compiler-backend-object-symbol-local-section
              parts
              "__chkstk"
              (Text)
              (Runtime))
            "tl_setup_argv"
            (Text)
            (Runtime))
          ".L_tl_boot_alloc"
          (Text)
          (Runtime))
        "GetCommandLineA"
        (Function))]
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
        (RipAddress)
        ".L_tl_argc"
        (cobj.CompilerObjectX64Instr.StoreR15Rip ".L_tl_argc"))]
    [with-argv-store : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-argc-store
        "tl_setup_argv"
        (RipAddress)
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
        (RipValue)
        "tl_boot_off"
        (cobj.CompilerObjectX64Instr.LoadRip "tl_boot_off"))]
    [with-boot-pool-lea : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-boot-off-load
        ".L_tl_boot_alloc"
        (RipAddress)
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
        (RipAddress)
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
        (WindowsX64))]
    [_fiber-registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectMainFiberContribution)
        (WindowsX64))]
    [_filter-registered : unit
      (x64_catalog.compiler-x64-template-assert-structured!
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectOverflowFilterContribution)
        (WindowsX64))]
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
                                "_tl_start"
                                (Text)
                                (Function))
                              ".L_tl_start_end"
                              (Text)
                              (Function))
                            ".L_tl_main_fiber"
                            (Text)
                            (Function))
                          ".L_tl_main_fiber_end"
                          (Text)
                          (Function))
                        ".L_tl_start_converted_to_fiber"
                        (Text)
                        (Function))
                      ".L_tl_start_main_fiber_created"
                      (Text)
                      (Function))
                    ".L_tl_main_stack_reservation_failed"
                    (Text)
                    (Function))
                  "ExitProcess"
                  (Function))
                "ConvertThreadToFiber"
                (Function))
              "CreateFiberEx"
              (Function))
            "SwitchToFiber"
            (Function))
          "GetStdHandle"
          (Function))
        "WriteFile"
        (Function))]
    [with-overflow-filter-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-symbols
        ".L_tl_stack_overflow_filter"
        (Text)
        (Function))]
    [with-overflow-filter-end-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-overflow-filter-symbol
        ".L_tl_stack_overflow_filter_end"
        (Text)
        (Function))]
    [with-overflow-write-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-overflow-filter-end-symbol
        ".L_tl_stack_overflow_write"
        (Text)
        (Function))]
    [with-overflow-continue-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        with-overflow-write-symbol
        ".L_tl_stack_overflow_continue_search"
        (Text)
        (Function))]
    [with-stack-guarantee-extern : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        with-overflow-continue-symbol
        "SetThreadStackGuarantee"
        (Function))]
    [with-exception-filter-extern : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        with-stack-guarantee-extern
        "SetUnhandledExceptionFilter"
        (Function))]
    [with-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-exception-filter-extern
        (cobj.CompilerObjectX64Instr.Label "_tl_start"))]
    [with-sub : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-label
        (cobj.CompilerObjectX64Instr.SubRspImm8 40))]
    [with-setup-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-sub
        "_tl_start"
        "tl_setup_argv")]
    [with-gs-clear : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-setup-call
        (compiler-backend-object-entry-gs-clear-bytes))]
    [with-filter-address : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-gs-clear
        "_tl_start"
        (RipAddress)
        ".L_tl_stack_overflow_filter"
        (cobj.CompilerObjectX64Instr.LoadRipAddress
          ".L_tl_stack_overflow_filter"))]
    [with-filter-argument : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-filter-address
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-filter-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-filter-argument
        "_tl_start"
        "SetUnhandledExceptionFilter")]
    [with-convert-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-filter-call
        (compiler-backend-object-entry-convert-fiber-args-bytes))]
    [with-convert-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-convert-args
        "_tl_start"
        "ConvertThreadToFiber")]
    [with-convert-branch : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-rax-branch
        with-convert-call
        "_tl_start"
        ".L_tl_start_converted_to_fiber"
        ".L_tl_main_stack_reservation_failed")]
    [with-converted-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-convert-branch
        (cobj.CompilerObjectX64Instr.Label ".L_tl_start_converted_to_fiber"))]
    [with-create-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-converted-label
        (compiler-backend-object-entry-create-fiber-args-bytes))]
    [with-fiber-address : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-create-args
        "_tl_start"
        (RipAddress)
        ".L_tl_main_fiber"
        (cobj.CompilerObjectX64Instr.LoadRipAddressR11 ".L_tl_main_fiber"))]
    [with-create-tail : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-fiber-address
        (compiler-backend-object-entry-create-fiber-tail-bytes))]
    [with-create-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-create-tail
        "_tl_start"
        "CreateFiberEx")]
    [with-create-branch : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-rax-branch
        with-create-call
        "_tl_start"
        ".L_tl_start_main_fiber_created"
        ".L_tl_main_stack_reservation_failed")]
    [with-created-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-create-branch
        (cobj.CompilerObjectX64Instr.Label ".L_tl_start_main_fiber_created"))]
    [with-fiber-argument : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-created-label
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-switch-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-fiber-argument
        "_tl_start"
        "SwitchToFiber")]
    [with-switch-failed : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        (object_target.compiler-backend-object-add-text-relocation
          with-switch-call
          "_tl_start"
          (Branch)
          ".L_tl_main_stack_reservation_failed")
        (cobj.CompilerObjectX64Instr.Jump ".L_tl_main_stack_reservation_failed"))]
    [with-failed-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-switch-failed
        (cobj.CompilerObjectX64Instr.Label
          ".L_tl_main_stack_reservation_failed"))]
    [with-stderr-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-failed-label
        (compiler-backend-object-entry-stderr-handle-args-bytes))]
    [with-stderr-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-stderr-args
        "_tl_start"
        "GetStdHandle")]
    [with-stderr-handle : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-stderr-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-message : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-stderr-handle
        "_tl_start"
        (RipAddress)
        ".L_tl_main_stack_reservation_msg"
        (cobj.CompilerObjectX64Instr.LoadRipAddressRdx
          ".L_tl_main_stack_reservation_msg"))]
    [with-written : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-message
        "_tl_start"
        (RipAddress)
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
        "_tl_start"
        "WriteFile")]
    [with-exit-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-write-call
        (compiler-backend-object-entry-exit-134-args-bytes))]
    [with-failure-exit : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-exit-args
        "_tl_start"
        "ExitProcess")]
    [with-entry-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-failure-exit
        (cobj.CompilerObjectX64Instr.Label ".L_tl_start_end"))]
    [with-fiber-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-entry-end
        (cobj.CompilerObjectX64Instr.Label ".L_tl_main_fiber"))]
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
        ".L_tl_main_fiber"
        "SetThreadStackGuarantee")]
    [with-argc : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-stack-guarantee-call
        ".L_tl_main_fiber"
        (RipValue)
        ".L_tl_argc"
        (cobj.CompilerObjectX64Instr.MovRcxRip ".L_tl_argc"))]
    [with-argv : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-argc
        ".L_tl_main_fiber"
        (RipValue)
        ".L_tl_argv"
        (cobj.CompilerObjectX64Instr.MovRdxRip ".L_tl_argv"))]
    [with-main-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-argv
        ".L_tl_main_fiber"
        "main")]
    [with-move-exit-code : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-main-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-exit-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-move-exit-code
        ".L_tl_main_fiber"
        "ExitProcess")]
    [with-fiber-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-exit-call
        (cobj.CompilerObjectX64Instr.Label ".L_tl_main_fiber_end"))]
    [with-overflow-filter-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-fiber-end
        (cobj.CompilerObjectX64Instr.Label ".L_tl_stack_overflow_filter"))]
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
        ".L_tl_stack_overflow_filter"
        ".L_tl_stack_overflow_write"
        ".L_tl_stack_overflow_continue_search")]
    [with-overflow-write-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-filter-branch
        (cobj.CompilerObjectX64Instr.Label ".L_tl_stack_overflow_write"))]
    [with-overflow-stderr-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-write-label
        (compiler-backend-object-entry-stderr-handle-args-bytes))]
    [with-overflow-stderr-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-overflow-stderr-args
        ".L_tl_stack_overflow_filter"
        "GetStdHandle")]
    [with-overflow-stderr-handle : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-stderr-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-overflow-message : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-overflow-stderr-handle
        ".L_tl_stack_overflow_filter"
        (RipAddress)
        ".L_tl_stack_overflow_msg"
        (cobj.CompilerObjectX64Instr.LoadRipAddressRdx
          ".L_tl_stack_overflow_msg"))]
    [with-overflow-written : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-overflow-message
        ".L_tl_stack_overflow_filter"
        (RipAddress)
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
        ".L_tl_stack_overflow_filter"
        "WriteFile")]
    [with-overflow-exit-args : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-write-call
        (compiler-backend-object-entry-exit-134-args-bytes))]
    [with-overflow-exit : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-overflow-exit-args
        ".L_tl_stack_overflow_filter"
        "ExitProcess")]
    [with-overflow-continue-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-overflow-exit
        (cobj.CompilerObjectX64Instr.Label
          ".L_tl_stack_overflow_continue_search"))]
    [with-overflow-return : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-overflow-continue-label
        (compiler-backend-object-overflow-filter-return-bytes))]
    (object_target.compiler-backend-object-add-text
      with-overflow-return
      (cobj.CompilerObjectX64Instr.Label ".L_tl_stack_overflow_filter_end"))))

(define (compiler-backend-object-add-entry-unwind
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [with-xdata-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        parts
        ".L_tl_start_xdata"
        (Xdata)
        (Data))]
    [with-xdata : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-xdata
        (object_target.compiler-backend-object-add-xdata
          with-xdata-symbol
          (Label ".L_tl_start_xdata"))
        (Bytes (compiler-backend-object-entry-xdata-bytes)))]
    [with-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-xdata
            (Label ".L_tl_start_pdata_begin"))
          ".L_tl_start_pdata_begin"
          (Addr32Nb)
          "_tl_start")
        (SymbolRva32 "_tl_start"))]
    [with-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-begin
            (Label ".L_tl_start_pdata_end"))
          ".L_tl_start_pdata_end"
          (Addr32Nb)
          ".L_tl_start_end")
        (SymbolRva32 ".L_tl_start_end"))]
    [with-pdata-unwind : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-end
            (Label ".L_tl_start_pdata_unwind"))
          ".L_tl_start_pdata_unwind"
          (Addr32Nb)
          ".L_tl_start_xdata")
        (SymbolRva32 ".L_tl_start_xdata"))]
    [with-fiber-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-unwind
            (Label ".L_tl_main_fiber_pdata_begin"))
          ".L_tl_main_fiber_pdata_begin"
          (Addr32Nb)
          ".L_tl_main_fiber")
        (SymbolRva32 ".L_tl_main_fiber"))]
    [with-fiber-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-fiber-pdata-begin
            (Label ".L_tl_main_fiber_pdata_end"))
          ".L_tl_main_fiber_pdata_end"
          (Addr32Nb)
          ".L_tl_main_fiber_end")
        (SymbolRva32 ".L_tl_main_fiber_end"))]
    [with-fiber-pdata-unwind : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-fiber-pdata-end
            (Label ".L_tl_main_fiber_pdata_unwind"))
          ".L_tl_main_fiber_pdata_unwind"
          (Addr32Nb)
          ".L_tl_start_xdata")
        (SymbolRva32 ".L_tl_start_xdata"))]
    [with-filter-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-fiber-pdata-unwind
            (Label ".L_tl_stack_overflow_filter_pdata_begin"))
          ".L_tl_stack_overflow_filter_pdata_begin"
          (Addr32Nb)
          ".L_tl_stack_overflow_filter")
        (SymbolRva32 ".L_tl_stack_overflow_filter"))]
    [with-filter-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-filter-pdata-begin
            (Label ".L_tl_stack_overflow_filter_pdata_end"))
          ".L_tl_stack_overflow_filter_pdata_end"
          (Addr32Nb)
          ".L_tl_stack_overflow_filter_end")
        (SymbolRva32 ".L_tl_stack_overflow_filter_end"))]
    (object_target.compiler-backend-object-add-pdata
      (object_target.compiler-backend-object-add-pdata-relocation
        (object_target.compiler-backend-object-add-pdata
          with-filter-pdata-end
          (Label ".L_tl_stack_overflow_filter_pdata_unwind"))
        ".L_tl_stack_overflow_filter_pdata_unwind"
        (Addr32Nb)
        ".L_tl_start_xdata")
      (SymbolRva32 ".L_tl_start_xdata"))))

(define (compiler-backend-object-add-entry
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-entry-unwind
    (compiler-backend-object-add-entry-text
      (compiler-backend-object-add-runtime-text
        (compiler-backend-object-add-entry-data parts)))))

(define (compiler-backend-object-image-sections
  [text : cobj.CompilerObjectX64InstrBuilder]
  [data : cobj.CompilerObjectDataRecordBuilder]
  [rodata : cobj.CompilerObjectDataRecordBuilder]
  [bss : cobj.CompilerObjectDataRecordBuilder]
  [pdata : cobj.CompilerObjectDataRecordBuilder]
  [xdata : cobj.CompilerObjectDataRecordBuilder]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectSectionList
  (let
    [sections4 : cobj.CompilerObjectSectionBuilder
      (object_target.compiler-backend-object-base-sections
        text
        data
        rodata
        bss
        7)]
    [sections5 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections4
        (Section
          (Pdata)
          (cobj.compiler-object-data-record-builder-finish pdata)
          (cobj.compiler-object-instr-list-empty)))]
    [sections6 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections5
        (Section
          (Xdata)
          (cobj.compiler-object-data-record-builder-finish xdata)
          (cobj.compiler-object-instr-list-empty)))]
    (cobj.compiler-object-section-builder-finish
      (cobj.compiler-object-section-builder-push
        sections6
        (Section
          (Rsrc)
          (if emit-manifest-resource
            (compiler-backend-object-manifest-resource-records)
            (cobj.compiler-object-data-record-list-empty))
          (cobj.compiler-object-instr-list-empty))))))

(define (compiler-backend-object-image-symbols
  [symbols : cobj.CompilerObjectSymbolBuilder]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectSymbolList
  (cobj.compiler-object-symbol-builder-finish
    (if emit-manifest-resource
      (cobj.compiler-object-symbol-builder-push
        symbols
        (Symbol
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)
          (Local)
          (Data)
          (Some (Rsrc))))
      symbols)))

(define (compiler-backend-object-image-relocations
  [relocations : cobj.CompilerObjectRelocationBuilder]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectRelocationList
  (cobj.compiler-object-relocation-builder-finish
    (if emit-manifest-resource
      (cobj.compiler-object-relocation-builder-push
        relocations
        (Relocation
          (Rsrc)
          (compiler-backend-object-global-shared-view
            compiler-backend-object-rsrc-data-label)
          (Addr32Nb)
          (compiler-backend-object-global-shared-view
            compiler-backend-object-manifest-label)))
      relocations)))

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
        (WindowsX64)
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectTlciImageContribution)
        (x64_template.CompilerX64ExecutableTemplateId.WindowsObjectTlciMacroContribution))]
    [with-image-unwind : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-unwind
        with-tlci
        "tl_tlci_call_image_entry"
        "tl_tlci_call_image_entry$end"
        (compiler-backend-object-entry-range-unwind-bytes 40 13 false))]
    [with-macro-unwind : object_target.CompilerBackendObjectTargetParts
      (if macro-entry
        (compiler-backend-object-add-unwind
          with-image-unwind
          "tl_tlci_call_macro_entry"
          "tl_tlci_call_macro_entry$end"
          (compiler-backend-object-entry-range-unwind-bytes 40 6 true))
        with-image-unwind)]
    [emit-native-entry : bool (and emit-entry (not crt-entry))]
    [with-entry : object_target.CompilerBackendObjectTargetParts
      (if emit-native-entry
        (compiler-backend-object-add-entry with-macro-unwind)
        with-macro-unwind)]
    [final-parts : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-bss with-entry (Zero 0))]
    (cobj.CompilerObjectImage
      (compiler-backend-object-image-sections
        final-parts.text
        final-parts.data
        final-parts.rodata
        final-parts.bss
        final-parts.pdata
        final-parts.xdata
        emit-native-entry)
      (compiler-backend-object-image-symbols
        final-parts.symbols
        emit-native-entry)
      (compiler-backend-object-image-relocations
        final-parts.relocations
        emit-native-entry))))