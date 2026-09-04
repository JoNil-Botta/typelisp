;; compiler_backend_object_target.tl - Shared direct-object target adapter data.
;;
;; This module deliberately depends only on the structured object model. The
;; compiler backend builds these parts, then a platform leaf adds its entry
;; fragments and finishes the image.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import compiler_object as cobj)
(import compiler_x64_executable_template as x64_template)
(import compiler_x64_executable_template_catalog as x64_catalog)

(defstruct CompilerBackendObjectTargetParts
  (text cobj.CompilerObjectX64InstrBuilder)
  (data cobj.CompilerObjectDataRecordBuilder)
  (rodata cobj.CompilerObjectDataRecordBuilder)
  (bss cobj.CompilerObjectDataRecordBuilder)
  (pdata cobj.CompilerObjectDataRecordBuilder)
  (xdata cobj.CompilerObjectDataRecordBuilder)
  (symbols cobj.CompilerObjectSymbolBuilder)
  (relocations cobj.CompilerObjectRelocationBuilder))

(define (compiler-backend-object-parts-empty) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    (cobj.compiler-object-instr-builder-new)
    (cobj.compiler-object-data-record-builder-new)
    (cobj.compiler-object-data-record-builder-new)
    (cobj.compiler-object-data-record-builder-new)
    (cobj.compiler-object-data-record-builder-new)
    (cobj.compiler-object-data-record-builder-new)
    (cobj.compiler-object-symbol-builder-new)
    (cobj.compiler-object-relocation-builder-new)))

(define (compiler-backend-object-add-text
  [parts : CompilerBackendObjectTargetParts]
  [instr : cobj.CompilerObjectX64Instr]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    (cobj.compiler-object-instr-builder-push parts.text instr)
    parts.data
    parts.rodata
    parts.bss
    parts.pdata
    parts.xdata
    parts.symbols
    parts.relocations))

(define (compiler-backend-object-add-data
  [parts : CompilerBackendObjectTargetParts]
  [record : cobj.CompilerObjectDataRecord]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    (cobj.compiler-object-data-record-builder-push parts.data record)
    parts.rodata
    parts.bss
    parts.pdata
    parts.xdata
    parts.symbols
    parts.relocations))

(define (compiler-backend-object-add-rodata
  [parts : CompilerBackendObjectTargetParts]
  [record : cobj.CompilerObjectDataRecord]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    parts.data
    (cobj.compiler-object-data-record-builder-push parts.rodata record)
    parts.bss
    parts.pdata
    parts.xdata
    parts.symbols
    parts.relocations))

(define (compiler-backend-object-add-bss
  [parts : CompilerBackendObjectTargetParts]
  [record : cobj.CompilerObjectDataRecord]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    parts.data
    parts.rodata
    (cobj.compiler-object-data-record-builder-push parts.bss record)
    parts.pdata
    parts.xdata
    parts.symbols
    parts.relocations))

(define (compiler-backend-object-add-pdata
  [parts : CompilerBackendObjectTargetParts]
  [record : cobj.CompilerObjectDataRecord]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    parts.data
    parts.rodata
    parts.bss
    (cobj.compiler-object-data-record-builder-push parts.pdata record)
    parts.xdata
    parts.symbols
    parts.relocations))

(define (compiler-backend-object-add-xdata
  [parts : CompilerBackendObjectTargetParts]
  [record : cobj.CompilerObjectDataRecord]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    parts.data
    parts.rodata
    parts.bss
    parts.pdata
    (cobj.compiler-object-data-record-builder-push parts.xdata record)
    parts.symbols
    parts.relocations))

(define (compiler-backend-object-add-symbol
  [parts : CompilerBackendObjectTargetParts]
  [name : String]
  [binding : cobj.CompilerObjectSymbolBinding]
  [kind : cobj.CompilerObjectSymbolKind]
  [section : cobj.CompilerObjectMaybeSection]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    parts.data
    parts.rodata
    parts.bss
    parts.pdata
    parts.xdata
    (cobj.compiler-object-symbol-builder-push
      parts.symbols
      (cobj.CompilerObjectSymbol.Symbol name binding kind section))
    parts.relocations))

(define (compiler-backend-object-add-relocation
  [parts : CompilerBackendObjectTargetParts]
  [section : cobj.CompilerObjectSectionKind]
  [site : String]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectTargetParts
  (CompilerBackendObjectTargetParts
    parts.text
    parts.data
    parts.rodata
    parts.bss
    parts.pdata
    parts.xdata
    parts.symbols
    (cobj.compiler-object-relocation-builder-push
      parts.relocations
      (cobj.CompilerObjectRelocation.Relocation section site kind target))))

(define (compiler-backend-object-symbol-local-section
  [parts : CompilerBackendObjectTargetParts]
  [name : String]
  [section : cobj.CompilerObjectSectionKind]
  [kind : cobj.CompilerObjectSymbolKind]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-symbol
    parts
    name
    (cobj.CompilerObjectSymbolBinding.Local)
    kind
    (cobj.CompilerObjectMaybeSection.Some section)))

(define (compiler-backend-object-symbol-export-section
  [parts : CompilerBackendObjectTargetParts]
  [name : String]
  [section : cobj.CompilerObjectSectionKind]
  [kind : cobj.CompilerObjectSymbolKind]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-symbol
    parts
    name
    (cobj.CompilerObjectSymbolBinding.Export)
    kind
    (cobj.CompilerObjectMaybeSection.Some section)))

(define (compiler-backend-object-symbol-extern
  [parts : CompilerBackendObjectTargetParts]
  [name : String]
  [kind : cobj.CompilerObjectSymbolKind]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-symbol
    parts
    name
    (cobj.CompilerObjectSymbolBinding.Extern)
    kind
    (cobj.CompilerObjectMaybeSection.No)))

(define (compiler-backend-object-symbol-extern-once
  [parts : CompilerBackendObjectTargetParts]
  [name : String]
  [kind : cobj.CompilerObjectSymbolKind]) : CompilerBackendObjectTargetParts
  (if (cobj.compiler-object-symbol-builder-contains?
    parts.symbols
    (owned_view.compiler-owned-shared-view name)
    (cobj.CompilerObjectSymbolBinding.Extern)
    kind)
    parts
    (compiler-backend-object-symbol-extern
      (owned_view.compiler-owned-shared-view parts)
      name
      kind)))

(define (compiler-backend-object-add-text-relocation
  [parts : CompilerBackendObjectTargetParts]
  [site : String]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-relocation
    parts
    (cobj.CompilerObjectSectionKind.Text)
    site
    kind
    target))

(define (compiler-backend-object-add-data-relocation
  [parts : CompilerBackendObjectTargetParts]
  [site : String]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-relocation
    parts
    (cobj.CompilerObjectSectionKind.Data)
    site
    kind
    target))

(define (compiler-backend-object-add-rodata-relocation
  [parts : CompilerBackendObjectTargetParts]
  [site : String]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-relocation
    parts
    (cobj.CompilerObjectSectionKind.Rodata)
    site
    kind
    target))

(define (compiler-backend-object-add-pdata-relocation
  [parts : CompilerBackendObjectTargetParts]
  [site : String]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-relocation
    parts
    (cobj.CompilerObjectSectionKind.Pdata)
    site
    kind
    target))

(define (compiler-backend-object-hex-value [c : char]) : i64
  (cond
    [(and (>= c '0') (<= c '9')) (- (cast c : i64) (cast '0' : i64))]
    [(and (>= c 'a') (<= c 'f')) (+ 10 (- (cast c : i64) (cast 'a' : i64)))]
    [(and (>= c 'A') (<= c 'F')) (+ 10 (- (cast c : i64) (cast 'A' : i64)))]
    [else 0]))

(define (compiler-backend-object-bytes-from-hex [hex : String]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [i : i64 0]
    [n : i64 (string.string-length hex)]
    (begin
      (while (< (+ i 1) n)
        (let
          [hi : i64
            (compiler-backend-object-hex-value (string.string-ref hex i))]
          [lo : i64
            (compiler-backend-object-hex-value (string.string-ref hex (+ i 1)))]
          (begin
            (byte_buf_core.byte-buf-builder-push
              (&mut out)
              (cast (+ (* hi 16) lo) : u8))
            (set! i (+ i 2)))))
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(define (compiler-backend-object-add-text-bytes
  [parts : CompilerBackendObjectTargetParts]
  [bytes : String]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-text
    parts
    (cobj.CompilerObjectX64Instr.Bytes bytes)))

(define (compiler-backend-object-add-call-instr
  [parts : CompilerBackendObjectTargetParts]
  [site : String]
  [target : String]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-text
    (compiler-backend-object-add-text-relocation
      parts
      site
      (cobj.CompilerObjectRelocationKind.Call)
      (owned_view.compiler-owned-shared-view target))
    (cobj.CompilerObjectX64Instr.Call target)))

(define (compiler-backend-object-add-rip-instr
  [parts : CompilerBackendObjectTargetParts]
  [site : String]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]
  [instr : cobj.CompilerObjectX64Instr]) : CompilerBackendObjectTargetParts
  (compiler-backend-object-add-text
    (compiler-backend-object-add-text-relocation parts site kind target)
    instr))

(define (compiler-backend-object-add-tlci-entry-runtime-text
  [parts : CompilerBackendObjectTargetParts]
  [entry-bytes : String]
  [macro-entry-bytes : String]
  [macro-entry : bool]
  [target : x64_template.CompilerX64TemplateTarget]
  [entry-template : x64_template.CompilerX64ExecutableTemplateId]
  [macro-template : x64_template.CompilerX64ExecutableTemplateId]) : CompilerBackendObjectTargetParts
  (begin
    (x64_catalog.compiler-x64-template-assert-structured! entry-template target)
    (when
      macro-entry
      (x64_catalog.compiler-x64-template-assert-structured!
        macro-template
        target))
    (let
      [with-image-entry : CompilerBackendObjectTargetParts
        (compiler-backend-object-add-text-bytes
          (compiler-backend-object-add-text
            parts
            (cobj.CompilerObjectX64Instr.Label "tl_tlci_call_image_entry"))
          entry-bytes)]
      (if macro-entry
        (compiler-backend-object-add-text-bytes
          (compiler-backend-object-add-text
            with-image-entry
            (cobj.CompilerObjectX64Instr.Label "tl_tlci_call_macro_entry"))
          macro-entry-bytes)
        with-image-entry))))

(define (compiler-backend-object-empty-data-records) : cobj.CompilerObjectDataRecordList
  (cobj.compiler-object-data-record-builder-finish
    (cobj.compiler-object-data-record-builder-with-capacity 1)))

(define (compiler-backend-object-empty-instrs) : cobj.CompilerObjectX64InstrList
  (cobj.compiler-object-instr-builder-finish
    (cobj.compiler-object-instr-builder-with-capacity 1)))

(define (compiler-backend-object-base-sections
  [parts : CompilerBackendObjectTargetParts]
  [capacity : i64]) : cobj.CompilerObjectSectionBuilder
  (let
    [empty-data : cobj.CompilerObjectDataRecordList
      (compiler-backend-object-empty-data-records)]
    [empty-instrs : cobj.CompilerObjectX64InstrList
      (compiler-backend-object-empty-instrs)]
    [sections0 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-with-capacity capacity)]
    [sections1 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections0
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Text)
          empty-data
          (cobj.compiler-object-instr-builder-finish parts.text)))]
    [sections2 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections1
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Data)
          (cobj.compiler-object-data-record-builder-finish parts.data)
          (owned_view.compiler-owned-shared-view empty-instrs)))]
    [sections3 : cobj.CompilerObjectSectionBuilder
      (cobj.compiler-object-section-builder-push
        sections2
        (cobj.CompilerObjectSection.Section
          (cobj.CompilerObjectSectionKind.Rodata)
          (cobj.compiler-object-data-record-builder-finish parts.rodata)
          (owned_view.compiler-owned-shared-view empty-instrs)))]
    (cobj.compiler-object-section-builder-push
      sections3
      (cobj.CompilerObjectSection.Section
        (cobj.CompilerObjectSectionKind.Bss)
        (cobj.compiler-object-data-record-builder-finish parts.bss)
        empty-instrs))))

(define (compiler-backend-object-base-symbols
  [parts : CompilerBackendObjectTargetParts]) : cobj.CompilerObjectSymbolList
  (cobj.compiler-object-symbol-builder-finish parts.symbols))

(define (compiler-backend-object-base-relocations
  [parts : CompilerBackendObjectTargetParts]) : cobj.CompilerObjectRelocationList
  (cobj.compiler-object-relocation-builder-finish parts.relocations))