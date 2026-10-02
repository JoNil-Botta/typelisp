;; compiler_tlci_native_image_tests.tl - layout, emitter and rejection tests
;; for the native TLCI image builder, kept out of the production module.
(import compiler_object as cobj)
(import compiler_object_elf)
(import tlci_core)
(import stdlib.byte_le)
(import stdlib.string)
(import stdlib.test)
(import compiler_tlci_native_image as native_image)

(define (compiler-tlci-native-test-image
  [import-name : String]
  [direct-extern-call : bool]
  [rva32 : bool]) : cobj.CompilerObjectImage
  (let
    [empty-data : cobj.CompilerObjectDataRecordList
      (cobj.compiler-object-data-record-builder-finish
        (cobj.compiler-object-data-record-builder-with-capacity 1))]
    [empty-instrs : cobj.CompilerObjectX64InstrList
      (cobj.compiler-object-instr-builder-finish
        (cobj.compiler-object-instr-builder-with-capacity 1))]
    [text0 : cobj.CompilerObjectX64InstrBuilder
      (cobj.compiler-object-instr-builder-with-capacity 5)]
    [text1 : cobj.CompilerObjectX64InstrBuilder
      (cobj.compiler-object-instr-builder-push text0 (Label "_entry"))]
    [text2 : cobj.CompilerObjectX64InstrBuilder
      (cobj.compiler-object-instr-builder-push
        text1
        (if direct-extern-call
          (Call (string.copy import-name))
          (Call "_helper")))]
    [text3 : cobj.CompilerObjectX64InstrBuilder
      (cobj.compiler-object-instr-builder-push
        text2
        (LoadRip (string.copy import-name)))]
    [text4 : cobj.CompilerObjectX64InstrBuilder
      (cobj.compiler-object-instr-builder-push text3 (Label "_helper"))]
    [text5 : cobj.CompilerObjectX64InstrBuilder
      (cobj.compiler-object-instr-builder-push
        text4
        (Raw (compiler_object_elf.compiler-object-elf-ret-bytes)))]
    [rodata0 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-with-capacity 2)]
    [rodata1 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        rodata0
        (Label "_constant"))]
    [rodata2 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push rodata1 (String "x"))]
    [data0 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-with-capacity 2)]
    [data1 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push data0 (Label "_pointer"))]
    [data2 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push
        data1
        (if rva32
          (SymbolRva32 "_constant")
          (SymbolAddress "_constant")))]
    [bss0 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-with-capacity 2)]
    [bss1 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push bss0 (Label "_zero"))]
    [bss2 : cobj.CompilerObjectDataRecordBuilder
      (cobj.compiler-object-data-record-builder-push bss1 (Zero 16))]
    [sections0 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-with-capacity 4)]
    [sections1 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections0
        (Section
          (Text)
          empty-data
          (cobj.compiler-object-instr-builder-finish text5)))]
    [sections2 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections1
        (Section
          (Rodata)
          (cobj.compiler-object-data-record-builder-finish rodata2)
          (clone empty-instrs)))]
    [sections3 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections2
        (Section
          (Data)
          (cobj.compiler-object-data-record-builder-finish data2)
          (clone empty-instrs)))]
    [sections4 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections3
        (Section
          (Bss)
          (cobj.compiler-object-data-record-builder-finish bss2)
          (clone empty-instrs)))]
    [symbols0 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-with-capacity 6)]
    [symbols1 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols0
        (Symbol "_entry" (Export) (Function) (Some (Text))))]
    [symbols2 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols1
        (Symbol "_helper" (Local) (Function) (Some (Text))))]
    [symbols3 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols2
        (Symbol "_constant" (Local) (Data) (Some (Rodata))))]
    [symbols4 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols3
        (Symbol "_pointer" (Local) (Data) (Some (Data))))]
    [symbols5 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols4
        (Symbol "_zero" (Local) (Data) (Some (Bss))))]
    [symbols6 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols5
        (Symbol import-name (Extern) (Function) No))]
    [relocations : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-with-capacity 1))]
    (cobj.CompilerObjectImage
      (cobj.compiler-object-section-builder-finish sections4)
      (cobj.compiler-object-symbol-builder-finish symbols6)
      relocations)))

(define (compiler-tlci-native-test-host-import-names-ok?) : bool
  (let
    [question : String "_tl_comptime_host_operand_expr_call_question"]
    [arrow : String "_tl_comptime_host_int__gtstring"]
    (and
      (string.eq
        (native_image.compiler-tlci-native-host-import-name (& question))
        "operand-expr-call?")
      (string.eq
        (native_image.compiler-tlci-native-host-import-name (& arrow))
        "int->string"))))

(define (compiler-tlci-native-test-emitters-ok?) : bool
  (and
    (compiler-tlci-native-test-host-import-names-ok?)
    (match (native_image.compiler-tlci-native-layout-image
      (compiler-tlci-native-test-image
        "_tl_comptime_host_fuel-check"
        false
        false))
      [(Err _) false]
      [(Ok layout)
        (let
          [fixups : (__tl_dyn-array u8)
            (native_image.compiler-tlci-native-emit-fixups (& layout))]
          (and
            (= (array-length fixups) tlci_core.tlci-section-fixup-record-size)
            (= (tlci_core.tlci-read-u64 fixups 0) 32)
            (match (native_image.compiler-tlci-native-emit-imports (& layout))
              [(Err _) false]
              [(Ok imports)
                (and
                  (=
                    (array-length imports)
                    (+
                      tlci_core.tlci-section-import-header-size
                      (+ tlci_core.tlci-section-import-record-size 10)))
                  (= (tlci_core.tlci-read-u64 imports 0) 1)
                  (=
                    (tlci_core.tlci-read-u64
                      imports
                      tlci_core.tlci-section-import-header-size)
                    40)
                  (string.eq
                    (tlci_core.tlci-bytes->string
                      imports
                      (tlci_core.tlci-read-u64
                        imports
                        (+ tlci_core.tlci-section-import-header-size 8))
                      (tlci_core.tlci-read-u64
                        imports
                        (+ tlci_core.tlci-section-import-header-size 16)))
                    "fuel-check"))])
            (match (native_image.compiler-tlci-native-layout-image
              (compiler-tlci-native-test-image "host-a" false false))
              [(Err _) false]
              [(Ok other)
                (match (native_image.compiler-tlci-native-emit-imports
                  (& other))
                  [(Err message)
                    (string.eq
                      message
                      "tlci native image: unknown host import host-a")]
                  [(Ok _) false])])))])))

(define (compiler-tlci-native-test-layout-ok?) : bool
  (match (native_image.compiler-tlci-native-layout-image
    (compiler-tlci-native-test-image "host-a" false false))
    [(Ok layout)
      (let
        [bytes : (__tl_dyn-array u8) layout.bytes]
        (and
          (= layout.size 2096)
          (= (array-length bytes) 2096)
          (= layout.bss-size 16)
          (= layout.import-count 1)
          (string.eq (array-ref layout.import-names 0) "host-a")
          (= (array-ref layout.import-offsets 0) 40)
          (= layout.fixup-count 1)
          (= (array-ref layout.fixup-offsets 0) 32)
          (= (byte_le.read-u32 (& bytes) 1) 7)
          (= (byte_le.read-u32 (& bytes) 8) 28)
          (= (byte_le.read-u32 (& bytes) 32) 16)
          (= (byte_le.read-u32 (& bytes) 36) 0)
          (=
            (native_image.compiler-tlci-native-entry-offset
              (compiler-tlci-native-test-image "host-a" false false)
              "_entry")
            0)))]
    [(Err _) false]))

(define (compiler-tlci-native-test-results-independent?) : bool
  (match (native_image.compiler-tlci-native-layout-image
    (compiler-tlci-native-test-image "host-a" false false))
    [(Ok first)
      (match (native_image.compiler-tlci-native-layout-image
        (compiler-tlci-native-test-image "host-b" false false))
        [(Ok second)
          (and
            (string.eq (array-ref first.import-names 0) "host-a")
            (string.eq (array-ref second.import-names 0) "host-b"))]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-tlci-native-test-error?
  [direct-extern-call : bool]
  [rva32 : bool]
  [expected : String]) : bool
  (match (native_image.compiler-tlci-native-layout-image
    (compiler-tlci-native-test-image "host-call" direct-extern-call rva32))
    [(Err message) (string.eq message expected)]
    [(Ok _) false]))

(test
  compiler-tlci-native-layout
  (begin
    (test.assert-true
      (compiler-tlci-native-test-layout-ok?)
      "internal call, GOT import, base fixup, and BSS alignment")
    (test.assert-true
      (compiler-tlci-native-test-emitters-ok?)
      "fixup and import section emitters, with unknown-import rejection")
    (test.assert-true
      (compiler-tlci-native-test-results-independent?)
      "layout results own their import metadata")
    (test.assert-true
      (compiler-tlci-native-test-error?
        true
        false
        "tlci native image: direct extern call host-call")
      "direct extern calls are rejected")
    (test.assert-true
      (compiler-tlci-native-test-error?
        false
        true
        "tlci native image: SymbolRva32 is not supported")
      "SymbolRva32 is rejected")))