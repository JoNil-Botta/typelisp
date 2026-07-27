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
(import "tlci_core.tl")
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as tlci_native_string_i64_map)
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
  256)
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

;; One layout-local index replaces a full instruction/data/symbol scan at
;; every relocation. Large generated transformer programs have tens of
;; thousands of branch relocations, so resolving each target from the start
;; of the text list makes layout quadratic in the generated code size.
(defstruct CompilerTlciNativeSymbolIndex
  (offsets tlci_native_string_i64_map.Map)
  (externs tlci_native_string_i64_map.Map))

(define (compiler-tlci-native-index-data-labels!
  [offsets : (&mut offsets tlci_native_string_i64_map.Map)]
  [records : cobj.CompilerObjectDataRecordList]
  [base : i64]) : unit
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [offset : i64 base]
    (while (< index count)
      (let
        [record : cobj.CompilerObjectDataRecord
          (cobj.compiler-object-data-record-list-ref records index)]
        (begin
          (match record
            [(cobj.CompilerObjectDataRecord.Label name)
              (begin
                (tlci_native_string_i64_map.insert-if-absent-ref!
                  offsets
                  name
                  offset)
                unit)]
            [_ unit])
          (set!
            offset
            (compiler-object-elf-data-record-end-offset record offset))
          (set! index (+ index 1)))))))

(define (compiler-tlci-native-build-symbol-index
  [image : cobj.CompilerObjectImage]
  [bases : CompilerTlciNativeBases]) : CompilerTlciNativeSymbolIndex
  (let
    [instrs : cobj.CompilerObjectX64InstrList
      (compiler-tlci-native-section-instrs
        image
        (cobj.CompilerObjectSectionKind.Text))]
    [instr-count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [offsets : tlci_native_string_i64_map.Map
      (tlci_native_string_i64_map.with-capacity (+ instr-count 16))]
    [instr-index : i64 0]
    [offset : i64 (struct-get bases text)]
    [symbols : cobj.CompilerObjectSymbolList (struct-get image symbols)]
    [symbol-count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [externs : tlci_native_string_i64_map.Map
      (tlci_native_string_i64_map.with-capacity (+ symbol-count 1))]
    [symbol-index : i64 0]
    (begin
      (while (< instr-index instr-count)
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref instrs instr-index)]
          (begin
            (match instr
              [(cobj.CompilerObjectX64Instr.Label name)
                (begin
                  (tlci_native_string_i64_map.insert-if-absent-ref!
                    (&mut offsets)
                    name
                    offset)
                  unit)]
              [_ unit])
            (set! offset (+ offset (compiler-object-elf-instr-size instr)))
            (set! instr-index (+ instr-index 1)))))
      (compiler-tlci-native-index-data-labels!
        (&mut offsets)
        (compiler-tlci-native-section-data
          image
          (cobj.CompilerObjectSectionKind.Rodata))
        (struct-get bases rodata))
      (compiler-tlci-native-index-data-labels!
        (&mut offsets)
        (compiler-tlci-native-section-data
          image
          (cobj.CompilerObjectSectionKind.Data))
        (struct-get bases data))
      (compiler-tlci-native-index-data-labels!
        (&mut offsets)
        (compiler-tlci-native-section-data
          image
          (cobj.CompilerObjectSectionKind.Bss))
        (struct-get bases bss))
      (while (< symbol-index symbol-count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols symbol-index)
            [(cobj.CompilerObjectSymbol.Symbol name binding _ _)
              (match binding
                [(cobj.CompilerObjectSymbolBinding.Extern)
                  (tlci_native_string_i64_map.insert-ref! (&mut externs) name 1)]
                [_ unit])])
          (set! symbol-index (+ symbol-index 1))))
      (CompilerTlciNativeSymbolIndex offsets externs))))

;; GOT slot offset for extern `name`, allocating on first use. This also keeps
;; the borrow-in-loop then consume-after-loop ownership pattern exercised by a
;; whole-compiler function body.
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
;; Module-qualified spellings of host externs resolve to the canonical ABI
;; symbol (generated entry modules qualify the extern user id).
(define (compiler-tlci-native-prefix?
  [text : (& text str)]
  [prefix : (& prefix str)]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (and
      (>= text-len prefix-len)
      (string.eq (string.substring text 0 prefix-len) prefix))))

(define (compiler-tlci-native-extern-alias [name : String]) : String
  (let
    [qualified-prefix : String "_tl_tlci_entries_comptime_host_"]
    (if (compiler-tlci-native-prefix? name qualified-prefix)
      (string.append
        "_tl_comptime_host_"
        (string.substring
          name
          (string.string-length qualified-prefix)
          (-
            (string.string-length name)
            (string.string-length qualified-prefix))))
      name)))

(define (compiler-tlci-native-index-offset
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [name : (& name str)]) : i64
  (match (tlci_native_string_i64_map.get-borrowed
    (& (struct-get symbols offsets))
    name)
    [(tlci_native_string_i64_map.LookupFound offset) offset]
    [(tlci_native_string_i64_map.LookupMissing) -1]))

(define (compiler-tlci-native-index-extern?
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [name : (& name str)]) : bool
  (tlci_native_string_i64_map.contains-borrowed?
    (& (struct-get symbols externs))
    name))

(define (compiler-tlci-native-symbol-offset!
  [import-names : (Array String)]
  [import-offsets : (Array i64)]
  [import-count : (Array i64)]
  [error : (Array String)]
  [bases : CompilerTlciNativeBases]
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [name : String]) : i64
  (let
    [offset : i64 (compiler-tlci-native-index-offset symbols (& name))]
    (if (>= offset 0)
      offset
      (let
        [extern-name : String (compiler-tlci-native-extern-alias name)]
        (if (compiler-tlci-native-index-extern? symbols (& extern-name))
          (compiler-tlci-native-got-slot!
            import-names
            import-offsets
            import-count
            error
            bases
            extern-name)
          (compiler-tlci-native-fail!
            error
            (string.append "tlci native image: unresolved symbol " name)))))))

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
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
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
        symbols
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
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
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
                (if (compiler-tlci-native-index-extern? symbols (& target))
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
                      symbols
                      bytes
                      (+ offset 1)
                      target)))]
              [(cobj.CompilerObjectX64Instr.TailCall target)
                (if (compiler-tlci-native-index-extern? symbols (& target))
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
                      symbols
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
                    symbols
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
                    symbols
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
                      symbols
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
                        symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
                    symbols
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
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
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
                      symbols
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
    [symbols-index : CompilerTlciNativeSymbolIndex
      (compiler-tlci-native-build-symbol-index image bases)]
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
            (& symbols-index)
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
              (& symbols-index)
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
              (& symbols-index)
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
      (compiler-tlci-native-sort-offsets! out)
      out)))

;; Function bodies are emitted in definition order, so ascending text offsets
;; are definition order regardless of symbol-table ordering.
(define (compiler-tlci-native-sort-offsets! [out : (Array i64)]) : unit
  (let
    [count : i64 (array-length out)]
    [index : i64 1]
    (while (< index count)
      (let
        [value : i64 (array-ref out index)]
        [scan : i64 index]
        (begin
          (while (and (> scan 0) (> (array-ref out (- scan 1)) value))
            (begin
              (array-set! out scan (array-ref out (- scan 1)))
              (set! scan (- scan 1))))
          (array-set! out scan value)
          (set! index (+ index 1)))))))

;; Primitives-only packaging boundary: callers (the producer, tools) pass
;; metadata as canonical text and plain arrays, and every tlci_core nominal
;; stays inside this module's single import instance.
(defenum ResultCompilerTlciNativeBytes
  (Ok (Array u8))
  (Err String))

(define (compiler-tlci-native-package
  [metadata-text : String]
  [build-hash : String]
  [rodata : (Array u8)]
  [code : (Array u8)]
  [imports : (Array u8)]
  [fixup-offsets : (Array i64)]
  [fixup-count : i64]
  [identities : (Array String)]
  [entry-offsets : (Array i64)]
  [macro-count : i64]) : ResultCompilerTlciNativeBytes
  (match (tlci-metadata-parse metadata-text)
    [(ResultTlciMetadata.Err message)
      (ResultCompilerTlciNativeBytes.Err
        (string.append "package metadata rejected: " message))]
    [(ResultTlciMetadata.Ok metadata)
      (match (tlci-emit-native-package-image
        metadata
        build-hash
        (TlciNativePackageInput
          rodata
          code
          imports
          fixup-offsets
          fixup-count
          identities
          entry-offsets
          macro-count))
        [(ResultTlciBytes.Err message)
          (ResultCompilerTlciNativeBytes.Err message)]
        [(ResultTlciBytes.Ok bytes) (ResultCompilerTlciNativeBytes.Ok bytes)])]))

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
      (array.make-array u8 (* count tlci-section-fixup-record-size))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (tlci-set-u64!
            out
            (* index tlci-section-fixup-record-size)
            (array-ref (struct-get layout fixup-offsets) index))
          (set! index (+ index 1))))
      out)))

;; Reverse the compiler's assembly-safe spelling for the callback-name
;; alphabet. Callback names contain lowercase ASCII, hyphens, `?`, and `->`;
;; they never contain source underscores, so this transform is unambiguous.
(define (compiler-tlci-native-host-import-unmangle [encoded : (& encoded str)]) : String
  (let
    [index : i64 0]
    [len : i64 (string.string-length encoded)]
    [out : String ""]
    (begin
      (while (< index len)
        (cond
          [(and
              (<= (+ index 9) len)
              (string.eq (string.substring encoded index 9) "_question"))
            (begin
              (set! out (string.append out "?"))
              (set! index (+ index 9)))]
          [(and
              (<= (+ index 3) len)
              (string.eq (string.substring encoded index 3) "_gt"))
            (begin
              (set! out (string.append out ">"))
              (set! index (+ index 3)))]
          [(= (string.string-ref encoded index) '_')
            (begin
              (set! out (string.append out "-"))
              (set! index (+ index 1)))]
          [else
            (begin
              (set! out (string.append out (string.substring encoded index 1)))
              (set! index (+ index 1)))]))
      out)))

;; Map a canonical extern symbol to the source-level name resolved by the
;; built-in linker. Unknown externs stay closed at package time.
(define (compiler-tlci-native-host-import-name [symbol : (& symbol str)]) : String
  (let
    [prefix : String "_tl_comptime_host_"]
    (if (and
      (compiler-tlci-native-prefix? symbol prefix)
      (> (string.string-length symbol) (string.string-length prefix)))
      (let
        [suffix : String
          (string.substring
            symbol
            (string.string-length prefix)
            (- (string.string-length symbol) (string.string-length prefix)))]
        (compiler-tlci-native-host-import-unmangle (& suffix)))
      "")))

;; Emit count + fixed records + packed names. Records contain a GOT slot and
;; section-relative name slice; the loader resolves the name before W^X.
(defenum ResultCompilerTlciNativeImports
  (Ok (Array u8))
  (Err String))

(define (compiler-tlci-native-emit-imports
  [layout : (& layout CompilerTlciNativeLayout)]) : ResultCompilerTlciNativeImports
  (let
    [count : i64 (struct-get layout import-count)]
    [names : (Array String) (array.make-array String count)]
    [index : i64 0]
    [names-len : i64 0]
    [error : String ""]
    (begin
      (while (and (= (string.string-length error) 0) (< index count))
        (let
          [name : String
            (compiler-tlci-native-host-import-name
              (array-ref (struct-get layout import-names) index))]
          (if (= (string.string-length name) 0)
            (set!
              error
              (string.append
                "tlci native image: unknown host import "
                (array-ref (struct-get layout import-names) index)))
            (begin
              (array-set! names index name)
              (set! names-len (+ names-len (string.string-length name)))
              (set! index (+ index 1))))))
      (if (= (string.string-length error) 0)
        (if (= count 0)
          (ResultCompilerTlciNativeImports.Ok (array.make-array u8 0))
          (let
            [records-end : i64
              (+
                tlci-section-import-header-size
                (* count tlci-section-import-record-size))]
            [out : (Array u8) (array.make-array u8 (+ records-end names-len))]
            [name-offset : i64 records-end]
            (begin
              (tlci-set-u64! out 0 count)
              (set! index 0)
              (while (< index count)
                (let
                  [record : i64
                    (+
                      tlci-section-import-header-size
                      (* index tlci-section-import-record-size))]
                  [name : String (array-ref names index)]
                  [name-len : i64 (string.string-length name)]
                  (begin
                    (tlci-set-u64!
                      out
                      record
                      (array-ref (struct-get layout import-offsets) index))
                    (tlci-set-u64! out (+ record 8) name-offset)
                    (tlci-set-u64! out (+ record 16) name-len)
                    (tlci-put-string! out name-offset name)
                    (set! name-offset (+ name-offset name-len))
                    (set! index (+ index 1)))))
              (ResultCompilerTlciNativeImports.Ok out))))
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
  (define (compiler-tlci-native-test-host-import-names-ok?) : bool
    (let
      [question : String "_tl_comptime_host_operand_expr_call_question"]
      [arrow : String "_tl_comptime_host_int__gtstring"]
      (and
        (string.eq
          (compiler-tlci-native-host-import-name (& question))
          "operand-expr-call?")
        (string.eq
          (compiler-tlci-native-host-import-name (& arrow))
          "int->string")))))

(cfg
  test
  (define (compiler-tlci-native-test-emitters-ok?) : bool
    (and
      (compiler-tlci-native-test-host-import-names-ok?)
      (match (compiler-tlci-native-layout-image
        (compiler-tlci-native-test-image
          "_tl_comptime_host_fuel-check"
          false
          false))
        [(ResultCompilerTlciNativeLayout.Err _) false]
        [(ResultCompilerTlciNativeLayout.Ok layout)
          (let
            [fixups : (Array u8) (compiler-tlci-native-emit-fixups (& layout))]
            (and
              (= (array-length fixups) tlci-section-fixup-record-size)
              (= (tlci-read-u64 fixups 0) 32)
              (match (compiler-tlci-native-emit-imports (& layout))
                [(ResultCompilerTlciNativeImports.Err _) false]
                [(ResultCompilerTlciNativeImports.Ok imports)
                  (and
                    (=
                      (array-length imports)
                      (+
                        tlci-section-import-header-size
                        (+ tlci-section-import-record-size 10)))
                    (= (tlci-read-u64 imports 0) 1)
                    (=
                      (tlci-read-u64 imports tlci-section-import-header-size)
                      40)
                    (string.eq
                      (tlci-bytes->string
                        imports
                        (tlci-read-u64
                          imports
                          (+ tlci-section-import-header-size 8))
                        (tlci-read-u64
                          imports
                          (+ tlci-section-import-header-size 16)))
                      "fuel-check"))])
              (match (compiler-tlci-native-layout-image
                (compiler-tlci-native-test-image "host-a" false false))
                [(ResultCompilerTlciNativeLayout.Err _) false]
                [(ResultCompilerTlciNativeLayout.Ok other)
                  (match (compiler-tlci-native-emit-imports (& other))
                    [(ResultCompilerTlciNativeImports.Err message)
                      (string.eq
                        message
                        "tlci native image: unknown host import host-a")]
                    [(ResultCompilerTlciNativeImports.Ok _) false])])))]))))

(cfg
  test
  (define (compiler-tlci-native-test-layout-ok?) : bool
    (match (compiler-tlci-native-layout-image
      (compiler-tlci-native-test-image "host-a" false false))
      [(ResultCompilerTlciNativeLayout.Ok layout)
        (let
          [bytes : (Array u8) (struct-get layout bytes)]
          (and
            (= (struct-get layout size) 2096)
            (= (array-length bytes) 2096)
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