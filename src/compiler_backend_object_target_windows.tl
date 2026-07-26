;; compiler_backend_object_target_windows.tl - Windows direct-object policy leaf.
(import stdlib.byte_buf_core)
(import compiler_backend_object_target as object_target)
(import compiler_object as cobj)

(define (compiler-backend-object-chkstk-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "51504889c1488d4424104881f9001000007212482d00100000c600004881e900100000ebe54829c8c600005859c3"))

(define (compiler-backend-object-setup-pre-getcmd-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "554889e55341544155415641574883ec28"))

(define (compiler-backend-object-setup-after-getcmd-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "4889c34d31e442803c2300740549ffc4ebf4498d4c24014883ec20"))

(define (compiler-backend-object-setup-after-boot1-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "4883c4204989c54831c94c39e17d0d8a040b4188440d0048ffc1ebee43c64425000048c7c1080800004883ec20"))

(define (compiler-backend-object-setup-after-boot2-pre-store-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "4883c4204989c64d31ff4c89eb8a033c0074513c20750548ffc3ebf14981ffff0000007d3f4b891cfe49ffc74531c98a033c00742f3c2275154183f1014889d98a4101880148ffc13c0075f4ebe13c20750d4585c97508c6030048ffc3ebae48ffc3ebcb4bc704fe00000000"))

(define (compiler-backend-object-setup-epilogue-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "4883c428415f415e415d415c5b5dc3"))

(define (compiler-backend-object-add-rdx-rax-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "4801d0"))

(define (compiler-backend-object-ret-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "c3"))

(define (compiler-backend-object-tlci-entry-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "4889c84889d14c89c24883ec28ffd04883c428c3"))

(define (compiler-backend-object-tlci-macro-entry-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "4889c84889d14c89c24d89c84c8b4c24284c8b5424304c8b5c24384883ec384c895424204c895c2428ffd04883c438c3"))

(define (compiler-backend-object-entry-gs-clear-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex
    "6548c704252800000000000000"))

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
          compiler-backend-object-rsrc-data-label))]
    [records4 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records3
        (cobj.CompilerObjectDataRecord.SymbolRva32
          compiler-backend-object-manifest-label))]
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
          compiler-backend-object-manifest-label))]
    [records8 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        records7
        (cobj.CompilerObjectDataRecord.Bytes
          compiler-backend-object-utf8-manifest))]
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
    (object_target.compiler-backend-object-add-bss
      (object_target.compiler-backend-object-add-bss
        with-boot-pool-symbol
        (cobj.CompilerObjectDataRecord.Label "tl_boot_pool"))
      (cobj.CompilerObjectDataRecord.Zero 524288))))

(define (compiler-backend-object-add-runtime-text
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
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
    [entry : String "_tl_start"]
    [entry-end : String ".L_tl_start_end"]
    [with-symbols : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-extern-once
        (object_target.compiler-backend-object-symbol-local-section
          (object_target.compiler-backend-object-symbol-export-section
            parts
            entry
            (cobj.CompilerObjectSectionKind.Text)
            (cobj.CompilerObjectSymbolKind.Function))
          entry-end
          (cobj.CompilerObjectSectionKind.Text)
          (cobj.CompilerObjectSymbolKind.Function))
        "ExitProcess"
        (cobj.CompilerObjectSymbolKind.Function))]
    [with-label : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-symbols
        (cobj.CompilerObjectX64Instr.Label entry))]
    [with-sub : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-label
        (cobj.CompilerObjectX64Instr.SubRspImm8 40))]
    [with-setup-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-sub
        entry
        "tl_setup_argv")]
    [with-gs-clear : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text-bytes
        with-setup-call
        (compiler-backend-object-entry-gs-clear-bytes))]
    [with-argc : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-gs-clear
        entry
        (cobj.CompilerObjectRelocationKind.RipValue)
        ".L_tl_argc"
        (cobj.CompilerObjectX64Instr.MovRcxRip ".L_tl_argc"))]
    [with-argv : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-rip-instr
        with-argc
        entry
        (cobj.CompilerObjectRelocationKind.RipValue)
        ".L_tl_argv"
        (cobj.CompilerObjectX64Instr.MovRdxRip ".L_tl_argv"))]
    [with-main-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-argv
        entry
        "main")]
    [with-move-exit-code : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        with-main-call
        (cobj.CompilerObjectX64Instr.MovRcxRax))]
    [with-exit-call : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-call-instr
        with-move-exit-code
        entry
        "ExitProcess")]
    (object_target.compiler-backend-object-add-text
      with-exit-call
      (cobj.CompilerObjectX64Instr.Label entry-end))))

(define (compiler-backend-object-add-entry-unwind
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [xdata-label : String ".L_tl_start_xdata"]
    [pdata-begin : String ".L_tl_start_pdata_begin"]
    [pdata-end : String ".L_tl_start_pdata_end"]
    [pdata-unwind : String ".L_tl_start_pdata_unwind"]
    [with-xdata-symbol : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-symbol-local-section
        parts
        xdata-label
        (cobj.CompilerObjectSectionKind.Xdata)
        (cobj.CompilerObjectSymbolKind.Data))]
    [with-xdata : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-xdata
        (object_target.compiler-backend-object-add-xdata
          with-xdata-symbol
          (cobj.CompilerObjectDataRecord.Label xdata-label))
        (cobj.CompilerObjectDataRecord.Bytes
          (compiler-backend-object-entry-xdata-bytes)))]
    [with-pdata-begin : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-xdata
            (cobj.CompilerObjectDataRecord.Label pdata-begin))
          pdata-begin
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          "_tl_start")
        (cobj.CompilerObjectDataRecord.SymbolRva32 "_tl_start"))]
    [with-pdata-end : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-pdata
        (object_target.compiler-backend-object-add-pdata-relocation
          (object_target.compiler-backend-object-add-pdata
            with-pdata-begin
            (cobj.CompilerObjectDataRecord.Label pdata-end))
          pdata-end
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          ".L_tl_start_end")
        (cobj.CompilerObjectDataRecord.SymbolRva32 ".L_tl_start_end"))]
    (object_target.compiler-backend-object-add-pdata
      (object_target.compiler-backend-object-add-pdata-relocation
        (object_target.compiler-backend-object-add-pdata
          with-pdata-end
          (cobj.CompilerObjectDataRecord.Label pdata-unwind))
        pdata-unwind
        (cobj.CompilerObjectRelocationKind.Addr32Nb)
        xdata-label)
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
      (object_target.compiler-backend-object-base-sections parts 7)]
    [sections5 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections4
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Pdata)
          (cobj.compiler-object-data-record-builder-finish
            (struct-get parts pdata))
          empty-instrs))]
    [sections6 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections5
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Xdata)
          (cobj.compiler-object-data-record-builder-finish
            (struct-get parts xdata))
          empty-instrs))]
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
        (struct-get parts symbols)
        (cobj.CompilerObjectSymbol.Symbol
          compiler-backend-object-manifest-label
          (cobj.CompilerObjectSymbolBinding.Local)
          (cobj.CompilerObjectSymbolKind.Data)
          (cobj.CompilerObjectMaybeSection.Some
            (cobj.CompilerObjectSectionKind.Rsrc))))
      (struct-get parts symbols))))

(define (compiler-backend-object-image-relocations
  [parts : object_target.CompilerBackendObjectTargetParts]
  [emit-manifest-resource : bool]) : cobj.CompilerObjectRelocationList
  (cobj.compiler-object-relocation-builder-finish
    (if emit-manifest-resource
      (cobj.compiler-object-relocation-builder-push
        (struct-get parts relocations)
        (cobj.CompilerObjectRelocation.Relocation
          (cobj.CompilerObjectSectionKind.Rsrc)
          compiler-backend-object-rsrc-data-label
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          compiler-backend-object-manifest-label))
      (struct-get parts relocations))))

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
        macro-entry)]
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
      (compiler-backend-object-image-sections final-parts emit-native-entry)
      (compiler-backend-object-image-symbols final-parts emit-native-entry)
      (compiler-backend-object-image-relocations final-parts emit-native-entry))))