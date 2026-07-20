;; compiler_tlci_native_image.tl - Lay out a normal-backend object image as a
;; tlci-mappable code region (refs #5213 normal-backend pivot).
;;
;; The transformer program is compiled by the ordinary pipeline into a
;; CompilerObjectImage; this module renders its sections with the ELF
;; emitter's encoder (one encoder, no parallel implementation), lays them out
;; in one region (text | rodata | data | got | bss), resolves every internal
;; relocation to final rel32/disp32 values, points extern RipValue sites at
;; loader-bound GOT slots, and records the base-relative fixups (absolute
;; 8-byte slots) plus the named imports the loader must bind before the W^X
;; seal. Extern Call/TailCall sites are rejected: host access goes through
;; extern *values* (GOT loads), never direct extern calls.
(import compiler_object as cobj)
(import "compiler_object_elf.tl")
(import tlci_core as tlci)
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.string)
(cfg test (import stdlib.test))

(defstruct CompilerTlciNativeLayout
  (bytes (Array u8))
  (size i64)
  (bss-size i64)
  (import-names (Array String))
  (import-offsets (Array i64))
  (import-count i64)
  (fixup-offsets (Array i64))
  (fixup-count i64))

(defenum ResultCompilerTlciNativeLayout
  (Ok CompilerTlciNativeLayout)
  (Err String))

(define compiler-tlci-native-import-cap : i64
  64)
(define compiler-tlci-native-fixup-cap : i64
  1024)

(define (compiler-tlci-native-align [offset : i64] [align : i64]) : i64
  (compiler-object-elf-align-offset offset align))

(define (compiler-tlci-native-section-instrs
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : cobj.CompilerObjectX64InstrList
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    kind)
    [(cobj.CompilerObjectSection.Section _ _ instrs) instrs]))

(define (compiler-tlci-native-section-data
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : cobj.CompilerObjectDataRecordList
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    kind)
    [(cobj.CompilerObjectSection.Section _ data _) data]))

;; True iff `name` is bound Extern in the image symbol table.
(define (compiler-tlci-native-extern-symbol?
  [image : cobj.CompilerObjectImage]
  [name : String]) : bool
  (let
    [symbols : cobj.CompilerObjectSymbolList (struct-get image symbols)]
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol sym-name binding _ _)
              (if (and
                (string.eq sym-name name)
                (match binding
                  [(cobj.CompilerObjectSymbolBinding.Extern) true]
                  [_ false]))
                (set! found true)
                unit)])
          (set! index (+ index 1))))
      found)))

;; Section base offsets for one layout run, passed by value.
(defstruct CompilerTlciNativeBases
  (text i64)
  (rodata i64)
  (data i64)
  (got i64)
  (bss i64))

(define (compiler-tlci-native-fail! [error : (Array String)] [message : String]) : i64
  (begin
    (if (= (string.string-length (array-ref error 0)) 0)
      (array-set! error 0 message)
      unit)
    -1))

;; GOT slot offset for extern `name`, allocating on first use.
(define (compiler-tlci-native-got-slot!
  [import-names : (Array String)]
  [import-offsets : (Array i64)]
  [import-count : (Array i64)]
  [error : (Array String)]
  [bases : CompilerTlciNativeBases]
  [name : String]) : i64
  (let
    [count : i64 (array-ref import-count 0)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq (array-ref import-names index) name)
          (set! found index)
          (set! index (+ index 1))))
      (if (>= found 0)
        (array-ref import-offsets found)
        (if (>= count compiler-tlci-native-import-cap)
          (compiler-tlci-native-fail!
            error
            "tlci native image: too many imported symbols")
          (let
            [offset : i64 (+ (struct-get bases got) (* count 8))]
            (begin
              (array-set! import-names count name)
              (array-set! import-offsets count offset)
              (array-set! import-count 0 (+ count 1))
              offset)))))))

;; Resolve symbol `name` to its region offset: text labels, rodata/data
;; labels, then bss labels. Externs resolve to their GOT slot. -1 = unknown.
(define (compiler-tlci-native-symbol-offset!
  [import-names : (Array String)]
  [import-offsets : (Array i64)]
  [import-count : (Array i64)]
  [error : (Array String)]
  [bases : CompilerTlciNativeBases]
  [image : cobj.CompilerObjectImage]
  [name : String]) : i64
  (let
    [text : i64
      (compiler-object-elf-instr-label-offset-from
        (compiler-tlci-native-section-instrs
          image
          (cobj.CompilerObjectSectionKind.Text))
        name
        (struct-get bases text))]
    (if (>= text 0)
      text
      (let
        [rodata : i64
          (compiler-object-elf-data-label-offset-from
            (compiler-tlci-native-section-data
              image
              (cobj.CompilerObjectSectionKind.Rodata))
            name
            (struct-get bases rodata))]
        (if (>= rodata 0)
          rodata
          (let
            [data : i64
              (compiler-object-elf-data-label-offset-from
                (compiler-tlci-native-section-data
                  image
                  (cobj.CompilerObjectSectionKind.Data))
                name
                (struct-get bases data))]
            (if (>= data 0)
              data
              (let
                [bss : i64
                  (compiler-object-elf-data-label-offset-from
                    (compiler-tlci-native-section-data
                      image
                      (cobj.CompilerObjectSectionKind.Bss))
                    name
                    (struct-get bases bss))]
                (if (>= bss 0)
                  bss
                  (if (compiler-tlci-native-extern-symbol? image name)
                    (compiler-tlci-native-got-slot!
                      import-names
                      import-offsets
                      import-count
                      error
                      bases
                      name)
                    (compiler-tlci-native-fail!
                      error
                      (string.append
                        "tlci native image: unresolved symbol "
                        name))))))))))))

;; Write a little-endian i32 at `offset`.
(define (compiler-tlci-native-patch-i32!
  [bytes : (Array u8)]
  [offset : i64]
  [value : i64]) : unit
  (begin
    (array-set! bytes offset (cast (bit-and value 0xff) : u8))
    (array-set! bytes (+ offset 1) (cast (bit-and (shr value 8) 0xff) : u8))
    (array-set! bytes (+ offset 2) (cast (bit-and (shr value 16) 0xff) : u8))
    (array-set! bytes (+ offset 3) (cast (bit-and (shr value 24) 0xff) : u8))))

;; Patch one rel32 site at region offset `site` to reach symbol `target`:
;; value = target-offset - (site + 4). Returns false on resolution failure.
(define (compiler-tlci-native-patch-rel32!
  [import-names : (Array String)]
  [import-offsets : (Array i64)]
  [import-count : (Array i64)]
  [error : (Array String)]
  [bases : CompilerTlciNativeBases]
  [image : cobj.CompilerObjectImage]
  [bytes : (Array u8)]
  [site : i64]
  [target : String]) : bool
  (let
    [target-offset : i64
      (compiler-tlci-native-symbol-offset!
        import-names
        import-offsets
        import-count
        error
        bases
        image
        target)]
    (if (< target-offset 0)
      false
      (begin
        (compiler-tlci-native-patch-i32!
          bytes
          site
          (- target-offset (+ site 4)))
        true))))

;; Patch every symbolic text instruction site in `bytes`, mirroring the ELF
;; emitter's site-offset walk exactly. Extern direct calls are rejected: host
;; access goes through extern-value GOT loads only.
(define (compiler-tlci-native-patch-text!
  [import-names : (Array String)]
  [import-offsets : (Array i64)]
  [import-count : (Array i64)]
  [error : (Array String)]
  [bases : CompilerTlciNativeBases]
  [image : cobj.CompilerObjectImage]
  [bytes : (Array u8)]) : bool
  (let
    [instrs : cobj.CompilerObjectX64InstrList
      (compiler-tlci-native-section-instrs
        image
        (cobj.CompilerObjectSectionKind.Text))]
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [offset : i64 (struct-get bases text)]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref instrs index)]
          (begin
            (match instr
              [(cobj.CompilerObjectX64Instr.Call target)
                (if (compiler-tlci-native-extern-symbol? image target)
                  (begin
                    (compiler-tlci-native-fail!
                      error
                      (string.append
                        "tlci native image: direct extern call "
                        target))
                    (set! ok false))
                  (set!
                    ok
                    (compiler-tlci-native-patch-rel32!
                      import-names
                      import-offsets
                      import-count
                      error
                      bases
                      image
                      bytes
                      (+ offset 1)
                      target)))]
              [(cobj.CompilerObjectX64Instr.TailCall target)
                (if (compiler-tlci-native-extern-symbol? image target)
                  (begin
                    (compiler-tlci-native-fail!
                      error
                      (string.append
                        "tlci native image: direct extern call "
                        target))
                    (set! ok false))
                  (set!
                    ok
                    (compiler-tlci-native-patch-rel32!
                      import-names
                      import-offsets
                      import-count
                      error
                      bases
                      image
                      bytes
                      (+ offset 1)
                      target)))]
              [(cobj.CompilerObjectX64Instr.Jump target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 1)
                    target))]
              [(cobj.CompilerObjectX64Instr.Ja target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 2)
                    target))]
              [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
                (begin
                  (set!
                    ok
                    (compiler-tlci-native-patch-rel32!
                      import-names
                      import-offsets
                      import-count
                      error
                      bases
                      image
                      bytes
                      (+ offset 5)
                      true-target))
                  (if ok
                    (set!
                      ok
                      (compiler-tlci-native-patch-rel32!
                        import-names
                        import-offsets
                        import-count
                        error
                        bases
                        image
                        bytes
                        (+ offset 10)
                        false-target))
                    unit))]
              [(cobj.CompilerObjectX64Instr.LoadRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.StoreRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.MovRcxRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.MovRdxRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.AddRcxRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.XorpdRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    import-names
                    import-offsets
                    import-count
                    error
                    bases
                    image
                    bytes
                    (+ offset 4)
                    target))]
              [_ unit])
            (set! offset (+ offset (compiler-object-elf-instr-size instr)))
            (set! index (+ index 1)))))
      ok)))

;; Patch SymbolAddress slots in a rendered data region and record each slot
;; as a base-relative fixup. `region-base` is the region offset where these
;; records begin.
(define (compiler-tlci-native-patch-data!
  [import-names : (Array String)]
  [import-offsets : (Array i64)]
  [import-count : (Array i64)]
  [error : (Array String)]
  [bases : CompilerTlciNativeBases]
  [image : cobj.CompilerObjectImage]
  [bytes : (Array u8)]
  [kind : cobj.CompilerObjectSectionKind]
  [region-base : i64]
  [fixup-offsets : (Array i64)]
  [fixup-count : (Array i64)]) : bool
  (let
    [records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data image kind)]
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [offset : i64 region-base]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [record : cobj.CompilerObjectDataRecord
            (cobj.compiler-object-data-record-list-ref records index)]
          (begin
            (match record
              [(cobj.CompilerObjectDataRecord.SymbolAddress target)
                (let
                  [value : i64
                    (compiler-tlci-native-symbol-offset!
                      import-names
                      import-offsets
                      import-count
                      error
                      bases
                      image
                      target)]
                  (if (< value 0)
                    (set! ok false)
                    (let
                      [slot : i64 (array-ref fixup-count 0)]
                      (if (>= slot compiler-tlci-native-fixup-cap)
                        (begin
                          (compiler-tlci-native-fail!
                            error
                            "tlci native image: too many base fixups")
                          (set! ok false))
                        (begin
                          (compiler-tlci-native-patch-i32! bytes offset value)
                          (compiler-tlci-native-patch-i32! bytes (+ offset 4) 0)
                          (array-set! fixup-offsets slot offset)
                          (array-set! fixup-count 0 (+ slot 1)))))))]
              [(cobj.CompilerObjectDataRecord.SymbolRva32 _)
                (begin
                  (compiler-tlci-native-fail!
                    error
                    "tlci native image: SymbolRva32 is not supported")
                  (set! ok false))]
              [_ unit])
            (set!
              offset
              (compiler-object-elf-data-record-end-offset record offset))
            (set! index (+ index 1)))))
      ok)))

;; Lay out the object image as one mappable region: text | rodata | data |
;; got | bss. Renders sections with the ELF encoder, resolves every internal
;; relocation in place, assigns GOT slots for extern value loads, and
;; returns the bytes plus the loader's import and base-fixup records.
(define (compiler-tlci-native-layout-image [image : cobj.CompilerObjectImage]) : ResultCompilerTlciNativeLayout
  (let
    [text-instrs : cobj.CompilerObjectX64InstrList
      (compiler-tlci-native-section-instrs
        image
        (cobj.CompilerObjectSectionKind.Text))]
    [text-size : i64 (compiler-object-elf-instrs-size text-instrs)]
    [rodata-records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data
        image
        (cobj.CompilerObjectSectionKind.Rodata))]
    [rodata-base : i64 (compiler-tlci-native-align text-size 16)]
    [rodata-size : i64
      (compiler-object-elf-data-records-size-from rodata-records rodata-base)]
    [data-records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data
        image
        (cobj.CompilerObjectSectionKind.Data))]
    [data-base : i64 (compiler-tlci-native-align rodata-size 16)]
    [data-size : i64
      (compiler-object-elf-data-records-size-from data-records data-base)]
    [got-base : i64 (compiler-tlci-native-align data-size 8)]
    [got-size : i64 (* compiler-tlci-native-import-cap 8)]
    [bss-records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data
        image
        (cobj.CompilerObjectSectionKind.Bss))]
    [bss-base : i64 (compiler-tlci-native-align (+ got-base got-size) 16)]
    [bss-size : i64
      (-
        (compiler-object-elf-data-records-size-from bss-records bss-base)
        bss-base)]
    [bases : CompilerTlciNativeBases
      (CompilerTlciNativeBases 0 rodata-base data-base got-base bss-base)]
    [import-names : (Array String)
      (array.make-array String compiler-tlci-native-import-cap)]
    [import-offsets : (Array i64)
      (array.make-array i64 compiler-tlci-native-import-cap)]
    [import-count : (Array i64) (make-array 0)]
    [error : (Array String) (make-array "")]
    [fixup-offsets : (Array i64)
      (array.make-array i64 compiler-tlci-native-fixup-cap)]
    [fixup-count : (Array i64) (make-array 0)]
    [builder : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity bss-base)]
    (begin
      (compiler-object-elf-render-instrs! (&mut builder) text-instrs)
      (compiler-object-elf-render-padding-to! (&mut builder) rodata-base)
      (compiler-object-elf-render-data-records!
        (&mut builder)
        rodata-records
        rodata-base)
      (compiler-object-elf-render-padding-to! (&mut builder) data-base)
      (compiler-object-elf-render-data-records!
        (&mut builder)
        data-records
        data-base)
      (compiler-object-elf-render-padding-to! (&mut builder) bss-base)
      (let
        [bytes : (Array u8)
          (byte_buf_core.byte-buf-builder-to-array (& builder))]
        [text-ok : bool
          (compiler-tlci-native-patch-text!
            import-names
            import-offsets
            import-count
            error
            bases
            image
            bytes)]
        [rodata-ok : bool
          (if text-ok
            (compiler-tlci-native-patch-data!
              import-names
              import-offsets
              import-count
              error
              bases
              image
              bytes
              (cobj.CompilerObjectSectionKind.Rodata)
              rodata-base
              fixup-offsets
              fixup-count)
            false)]
        [data-ok : bool
          (if rodata-ok
            (compiler-tlci-native-patch-data!
              import-names
              import-offsets
              import-count
              error
              bases
              image
              bytes
              (cobj.CompilerObjectSectionKind.Data)
              data-base
              fixup-offsets
              fixup-count)
            false)]
        (if (not data-ok)
          (ResultCompilerTlciNativeLayout.Err
            (let
              [message : String (array-ref error 0)]
              (if (= (string.string-length message) 0)
                "tlci native image: layout failed"
                message)))
          (ResultCompilerTlciNativeLayout.Ok
            (CompilerTlciNativeLayout
              bytes
              bss-base
              bss-size
              import-names
              import-offsets
              (array-ref import-count 0)
              fixup-offsets
              (array-ref fixup-count 0))))))))

;; Region offset of exported text symbol `name`, for macro entry records.
;; Text offsets of exported functions in symbol-table order. Generated
;; transformer programs define one entry function per catalog identity and
;; nothing else, so export order is the identity order; compact function
;; naming makes label names unstable, so offsets are the contract.
(define (compiler-tlci-native-function-export-count
  [image : cobj.CompilerObjectImage]) : i64
  (let
    [symbols : cobj.CompilerObjectSymbolList (struct-get image symbols)]
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol _ binding kind _)
              (if (and
                (match binding
                  [(cobj.CompilerObjectSymbolBinding.Export) true]
                  [_ false])
                (match kind
                  [(cobj.CompilerObjectSymbolKind.Function) true]
                  [_ false]))
                (set! total (+ total 1))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-tlci-native-function-export-offsets
  [image : cobj.CompilerObjectImage]) : (Array i64)
  (let
    [symbols : cobj.CompilerObjectSymbolList (struct-get image symbols)]
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [total : i64 (compiler-tlci-native-function-export-count image)]
    [out : (Array i64) (array.make-array i64 total)]
    [index : i64 0]
    [slot : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol name binding kind _)
              (if (and
                (match binding
                  [(cobj.CompilerObjectSymbolBinding.Export) true]
                  [_ false])
                (match kind
                  [(cobj.CompilerObjectSymbolKind.Function) true]
                  [_ false]))
                (begin
                  (array-set!
                    out
                    slot
                    (compiler-tlci-native-entry-offset image name))
                  (set! slot (+ slot 1)))
                unit)])
          (set! index (+ index 1))))
      out)))

(define (compiler-tlci-native-entry-offset
  [image : cobj.CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-elf-instr-label-offset-from
    (compiler-tlci-native-section-instrs
      image
      (cobj.CompilerObjectSectionKind.Text))
    name
    0))

;; Emit the layout's base fixups as a tlci fixups section: one u64 slot offset
;; per absolute pointer slot, which the loader rebases by the map base.
(define (compiler-tlci-native-emit-fixups
  [layout : (& layout CompilerTlciNativeLayout)]) : (Array u8)
  (let
    [count : i64 (struct-get layout fixup-count)]
    [out : (Array u8)
      (array.make-array u8 (* count tlci.tlci-section-fixup-record-size))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (tlci.tlci-set-u64!
            out
            (* index tlci.tlci-section-fixup-record-size)
            (array-ref (struct-get layout fixup-offsets) index))
          (set! index (+ index 1))))
      out)))

;; Map an extern value name to its stable host-import ABI id, or -1 when the
;; name is not a known host entry point (the closed host ABI).
(define (compiler-tlci-native-host-import-id [name : (& name str)]) : i64
  (if (string.eq name "_tl_comptime_host_invoke")
    tlci.tlci-host-import-invoke
    -1))

;; Emit the layout's imports as a tlci imports section: one 16-byte record
;; (got-slot-offset u64, host-import-id u64) per import. Unknown host entry
;; names abort with an empty result and a message, keeping the ABI closed.
(defenum ResultCompilerTlciNativeImports
  (Ok (Array u8))
  (Err String))

(define (compiler-tlci-native-emit-imports
  [layout : (& layout CompilerTlciNativeLayout)]) : ResultCompilerTlciNativeImports
  (let
    [count : i64 (struct-get layout import-count)]
    [out : (Array u8)
      (array.make-array u8 (* count tlci.tlci-section-import-record-size))]
    [index : i64 0]
    [error : String ""]
    (begin
      (while (and (= (string.string-length error) 0) (< index count))
        (let
          [id : i64
            (compiler-tlci-native-host-import-id
              (array-ref (struct-get layout import-names) index))]
          (if (< id 0)
            (set!
              error
              (string.append
                "tlci native image: unknown host import "
                (array-ref (struct-get layout import-names) index)))
            (let
              [record : i64 (* index tlci.tlci-section-import-record-size)]
              (begin
                (tlci.tlci-set-u64!
                  out
                  record
                  (array-ref (struct-get layout import-offsets) index))
                (tlci.tlci-set-u64! out (+ record 8) id)
                (set! index (+ index 1)))))))
      (if (= (string.string-length error) 0)
        (ResultCompilerTlciNativeImports.Ok out)
        (ResultCompilerTlciNativeImports.Err error)))))

(cfg
  test
  (define (compiler-tlci-native-test-u32 [bytes : (Array u8)] [offset : i64]) : i64
    (bit-or
      (cast (array-ref bytes offset) : i64)
      (bit-or
        (shl (cast (array-ref bytes (+ offset 1)) : i64) 8)
        (bit-or
          (shl (cast (array-ref bytes (+ offset 2)) : i64) 16)
          (shl (cast (array-ref bytes (+ offset 3)) : i64) 24))))))

(cfg
  test
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
        (cobj.compiler-object-instr-builder-push
          text0
          (cobj.CompilerObjectX64Instr.Label "_entry"))]
      [text2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text1
          (if direct-extern-call
            (cobj.CompilerObjectX64Instr.Call import-name)
            (cobj.CompilerObjectX64Instr.Call "_helper")))]
      [text3 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text2
          (cobj.CompilerObjectX64Instr.LoadRip import-name))]
      [text4 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text3
          (cobj.CompilerObjectX64Instr.Label "_helper"))]
      [text5 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text4
          (cobj.CompilerObjectX64Instr.Raw (compiler-object-elf-ret-bytes)))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (cobj.CompilerObjectDataRecord.Label "_constant"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata1
          (cobj.CompilerObjectDataRecord.String "x"))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_pointer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (if rva32
            (cobj.CompilerObjectDataRecord.SymbolRva32 "_constant")
            (cobj.CompilerObjectDataRecord.SymbolAddress "_constant")))]
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss0
          (cobj.CompilerObjectDataRecord.Label "_zero"))]
      [bss2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss1
          (cobj.CompilerObjectDataRecord.Zero 16))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            empty-data
            (cobj.compiler-object-instr-builder-finish text5)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            empty-instrs))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data2)
            empty-instrs))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            (cobj.compiler-object-data-record-builder-finish bss2)
            empty-instrs))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 6)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (cobj.CompilerObjectSymbol.Symbol
            "_entry"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (cobj.CompilerObjectSymbol.Symbol
            "_helper"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            "_constant"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Rodata))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "_pointer"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (cobj.CompilerObjectSymbol.Symbol
            "_zero"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Bss))))]
      [symbols6 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols5
          (cobj.CompilerObjectSymbol.Symbol
            import-name
            (cobj.CompilerObjectSymbolBinding.Extern)
            (cobj.CompilerObjectSymbolKind.Function)
            cobj.CompilerObjectMaybeSection.No))]
      [relocations : cobj.CompilerObjectRelocationList
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-with-capacity 1))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols6)
        relocations))))

(cfg
  test
  (define (compiler-tlci-native-test-emitters-ok?) : bool
    (match (compiler-tlci-native-layout-image
      (compiler-tlci-native-test-image "_tl_comptime_host_invoke" false false))
      [(ResultCompilerTlciNativeLayout.Err _) false]
      [(ResultCompilerTlciNativeLayout.Ok layout)
        (let
          [fixups : (Array u8) (compiler-tlci-native-emit-fixups (& layout))]
          (and
            (= (array-length fixups) tlci.tlci-section-fixup-record-size)
            (= (tlci.tlci-read-u64 fixups 0) 32)
            (match (compiler-tlci-native-emit-imports (& layout))
              [(ResultCompilerTlciNativeImports.Err _) false]
              [(ResultCompilerTlciNativeImports.Ok imports)
                (and
                  (=
                    (array-length imports)
                    tlci.tlci-section-import-record-size)
                  (= (tlci.tlci-read-u64 imports 0) 40)
                  (=
                    (tlci.tlci-read-u64 imports 8)
                    tlci.tlci-host-import-invoke))])
            (match (compiler-tlci-native-layout-image
              (compiler-tlci-native-test-image "host-a" false false))
              [(ResultCompilerTlciNativeLayout.Err _) false]
              [(ResultCompilerTlciNativeLayout.Ok other)
                (match (compiler-tlci-native-emit-imports (& other))
                  [(ResultCompilerTlciNativeImports.Err message)
                    (string.eq
                      message
                      "tlci native image: unknown host import host-a")]
                  [(ResultCompilerTlciNativeImports.Ok _) false])])))])))

(cfg
  test
  (define (compiler-tlci-native-test-layout-ok?) : bool
    (match (compiler-tlci-native-layout-image
      (compiler-tlci-native-test-image "host-a" false false))
      [(ResultCompilerTlciNativeLayout.Ok layout)
        (let
          [bytes : (Array u8) (struct-get layout bytes)]
          (and
            (= (struct-get layout size) 560)
            (= (array-length bytes) 560)
            (= (struct-get layout bss-size) 16)
            (= (struct-get layout import-count) 1)
            (string.eq (array-ref (struct-get layout import-names) 0) "host-a")
            (= (array-ref (struct-get layout import-offsets) 0) 40)
            (= (struct-get layout fixup-count) 1)
            (= (array-ref (struct-get layout fixup-offsets) 0) 32)
            (= (compiler-tlci-native-test-u32 bytes 1) 7)
            (= (compiler-tlci-native-test-u32 bytes 8) 28)
            (= (compiler-tlci-native-test-u32 bytes 32) 16)
            (= (compiler-tlci-native-test-u32 bytes 36) 0)
            (=
              (compiler-tlci-native-entry-offset
                (compiler-tlci-native-test-image "host-a" false false)
                "_entry")
              0)))]
      [(ResultCompilerTlciNativeLayout.Err _) false])))

(cfg
  test
  (define (compiler-tlci-native-test-results-independent?) : bool
    (match (compiler-tlci-native-layout-image
      (compiler-tlci-native-test-image "host-a" false false))
      [(ResultCompilerTlciNativeLayout.Ok first)
        (match (compiler-tlci-native-layout-image
          (compiler-tlci-native-test-image "host-b" false false))
          [(ResultCompilerTlciNativeLayout.Ok second)
            (and
              (string.eq (array-ref (struct-get first import-names) 0) "host-a")
              (string.eq
                (array-ref (struct-get second import-names) 0)
                "host-b"))]
          [(ResultCompilerTlciNativeLayout.Err _) false])]
      [(ResultCompilerTlciNativeLayout.Err _) false])))

(cfg
  test
  (define (compiler-tlci-native-test-error?
    [direct-extern-call : bool]
    [rva32 : bool]
    [expected : String]) : bool
    (match (compiler-tlci-native-layout-image
      (compiler-tlci-native-test-image "host-call" direct-extern-call rva32))
      [(ResultCompilerTlciNativeLayout.Err message)
        (string.eq message expected)]
      [(ResultCompilerTlciNativeLayout.Ok _) false])))

(cfg
  test
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
        "SymbolRva32 is rejected"))))