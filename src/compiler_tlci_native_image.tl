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
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_object as cobj)
(import compiler_object_layout as layout)
(import tlci_core)
(import stdlib.byte_buf_core)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as tlci_native_string_i64_map)
(import stdlib.string)

(defstruct CompilerTlciNativeLayout
  (bytes (__tl_dyn-array u8))
  (size i64)
  (bss-size i64)
  (import-names (__tl_dyn-array String))
  (import-offsets (__tl_dyn-array i64))
  (import-count i64)
  (fixup-offsets (__tl_dyn-array i64))
  (fixup-count i64))

(defenum ResultCompilerTlciNativeLayout
  (Ok CompilerTlciNativeLayout)
  (Err String))

(define compiler-tlci-native-import-cap : i64
  256)

(define (compiler-tlci-native-align [offset : i64] [align : i64]) : i64
  (layout.compiler-object-layout-align-offset offset align))

(define (compiler-tlci-native-section-instrs
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : cobj.CompilerObjectX64InstrList
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(Section _ _ instrs) instrs]))

(define (compiler-tlci-native-section-data
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : cobj.CompilerObjectDataRecordList
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(Section _ data _) data]))

;; Every absolute SymbolAddress data record becomes exactly one load-base
;; fixup. Size the output from the object rather than imposing a fixed ceiling:
;; large native declaration generators can legitimately carry more than 1024
;; records. Refs #6551.
(define (compiler-tlci-native-data-fixup-count
  [records : cobj.CompilerObjectDataRecordList]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [fixups : i64 0]
    (while (< index count)
      (match (cobj.compiler-object-data-record-list-ref records index)
        [(SymbolAddress _) (set! fixups (+ fixups 1))]
        [_ unit])
      (set! index (+ index 1)))
    fixups))

;; Section base offsets for one layout run, passed by value.
(defstruct CompilerTlciNativeBases
  (text i64)
  (rodata i64)
  (data i64)
  (got i64)
  (bss i64))

(define (compiler-tlci-native-fail!
  [error : (&mut error (__tl_dyn-array String))]
  [message : String]) : i64
  (if (= (string.string-length (array-ref error 0)) 0)
    (set! (array-ref error 0) message)
    unit)
  -1)

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
        (match (owned_view.compiler-owned-shared-view record)
          [(Label name)
            (tlci_native_string_i64_map.insert-if-absent-ref!
              offsets
              name
              offset)
            unit]
          [_ unit])
        (set!
          offset
          (cobj.compiler-object-data-record-end-offset record offset))
        (set! index (+ index 1))))))

(define (compiler-tlci-native-build-symbol-index
  [image : cobj.CompilerObjectImage]
  [bases : CompilerTlciNativeBases]) : CompilerTlciNativeSymbolIndex
  (let
    [instrs : cobj.CompilerObjectX64InstrList
      (compiler-tlci-native-section-instrs
        (owned_view.compiler-owned-shared-view image)
        (Text))]
    [instr-count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [offsets : tlci_native_string_i64_map.Map
      (tlci_native_string_i64_map.with-capacity (+ instr-count 16))]
    [instr-index : i64 0]
    [offset : i64 bases.text]
    [symbols : cobj.CompilerObjectSymbolList
      (owned_view.compiler-owned-shared-view image.symbols)]
    [symbol-count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [externs : tlci_native_string_i64_map.Map
      (tlci_native_string_i64_map.with-capacity (+ symbol-count 1))]
    [symbol-index : i64 0]
    (while (< instr-index instr-count)
      (let
        [instr : cobj.CompilerObjectX64Instr
          (cobj.compiler-object-instr-list-ref instrs instr-index)]
        (match (owned_view.compiler-owned-shared-view instr)
          [(Label name)
            (tlci_native_string_i64_map.insert-if-absent-ref!
              (&mut offsets)
              name
              offset)
            unit]
          [_ unit])
        (set!
          offset
          (+ offset (layout.compiler-object-layout-instr-size instr)))
        (set! instr-index (+ instr-index 1))))
    (compiler-tlci-native-index-data-labels!
      (&mut offsets)
      (compiler-tlci-native-section-data
        (owned_view.compiler-owned-shared-view image)
        (Rodata))
      bases.rodata)
    (compiler-tlci-native-index-data-labels!
      (&mut offsets)
      (compiler-tlci-native-section-data
        (owned_view.compiler-owned-shared-view image)
        (Data))
      bases.data)
    (compiler-tlci-native-index-data-labels!
      (&mut offsets)
      (compiler-tlci-native-section-data image (Bss))
      bases.bss)
    (while (< symbol-index symbol-count)
      (match (cobj.compiler-object-symbol-list-ref symbols symbol-index)
        [(Symbol name binding _ _)
          (match binding
            [(Extern)
              (tlci_native_string_i64_map.insert-ref! (&mut externs) name 1)]
            [_ unit])])
      (set! symbol-index (+ symbol-index 1)))
    (CompilerTlciNativeSymbolIndex offsets externs)))

;; GOT slot offset for extern `name`, allocating on first use. This also keeps
;; the borrow-in-loop then consume-after-loop ownership pattern exercised by a
;; whole-compiler function body.
(define (compiler-tlci-native-got-slot!
  [import-names : (&mut import-names (__tl_dyn-array String))]
  [import-offsets : (&mut import-offsets (__tl_dyn-array i64))]
  [import-count : (&mut import-count (__tl_dyn-array i64))]
  [error : (&mut error (__tl_dyn-array String))]
  [bases : CompilerTlciNativeBases]
  [name : String]) : i64
  (let
    [count : i64 (array-ref import-count 0)]
    [index : i64 0]
    [found : i64 -1]
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
          [offset : i64 (+ bases.got (* count 8))]
          (set! (array-ref import-names count) name)
          (set! (array-ref import-offsets count) offset)
          (set! (array-ref import-count 0) (+ count 1))
          offset)))))

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
      (str_cat.str-cat
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
  (match (tlci_native_string_i64_map.get-borrowed (& symbols.offsets) name)
    [(LookupFound offset) offset]
    [(LookupMissing) -1]))

(define (compiler-tlci-native-index-extern?
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [name : (& name str)]) : bool
  (tlci_native_string_i64_map.contains-borrowed? (& symbols.externs) name))

(define (compiler-tlci-native-symbol-offset!
  [import-names : (&mut import-names (__tl_dyn-array String))]
  [import-offsets : (&mut import-offsets (__tl_dyn-array i64))]
  [import-count : (&mut import-count (__tl_dyn-array i64))]
  [error : (&mut error (__tl_dyn-array String))]
  [bases : CompilerTlciNativeBases]
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [name : String]) : i64
  (let
    [offset : i64 (compiler-tlci-native-index-offset symbols (& name))]
    (if (>= offset 0)
      offset
      (let
        [extern-name : String
          (compiler-tlci-native-extern-alias
            (owned_view.compiler-owned-shared-view name))]
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
            (str_cat.str-cat "tlci native image: unresolved symbol " name)))))))

;; Write a little-endian i32 at `offset`.
(define (compiler-tlci-native-patch-i32!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (set! (array-ref bytes offset) (cast (bit-and value 0xff) : u8))
  (set! (array-ref bytes (+ offset 1)) (cast (bit-and (shr value 8) 0xff) : u8))
  (set!
    (array-ref bytes (+ offset 2))
    (cast (bit-and (shr value 16) 0xff) : u8))
  (set!
    (array-ref bytes (+ offset 3))
    (cast (bit-and (shr value 24) 0xff) : u8)))

;; Patch one rel32 site at region offset `site` to reach symbol `target`:
;; value = target-offset - (site + 4). Returns false on resolution failure.
(define (compiler-tlci-native-patch-rel32!
  [import-names : (&mut import-names (__tl_dyn-array String))]
  [import-offsets : (&mut import-offsets (__tl_dyn-array i64))]
  [import-count : (&mut import-count (__tl_dyn-array i64))]
  [error : (&mut error (__tl_dyn-array String))]
  [bases : CompilerTlciNativeBases]
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [bytes : (&mut bytes (__tl_dyn-array u8))]
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
  [import-names : (&mut import-names (__tl_dyn-array String))]
  [import-offsets : (&mut import-offsets (__tl_dyn-array i64))]
  [import-count : (&mut import-count (__tl_dyn-array i64))]
  [error : (&mut error (__tl_dyn-array String))]
  [bases : CompilerTlciNativeBases]
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [image : cobj.CompilerObjectImage]
  [bytes : (__tl_dyn-array u8)]) : bool
  (let
    [instrs : cobj.CompilerObjectX64InstrList
      (compiler-tlci-native-section-instrs image (Text))]
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [offset : i64 bases.text]
    [ok : bool true]
    (while (and ok (< index count))
      (let
        [instr : cobj.CompilerObjectX64Instr
          (cobj.compiler-object-instr-list-ref instrs index)]
        (match (owned_view.compiler-owned-shared-view instr)
          [(Call target)
            (if (compiler-tlci-native-index-extern? symbols (& target))
              (begin
                (compiler-tlci-native-fail!
                  error
                  (str_cat.str-cat
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
                  (&mut bytes)
                  (+ offset 1)
                  target)))]
          [(TailCall target)
            (if (compiler-tlci-native-index-extern? symbols (& target))
              (begin
                (compiler-tlci-native-fail!
                  error
                  (str_cat.str-cat
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
                  (&mut bytes)
                  (+ offset 1)
                  target)))]
          [(Jump target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 1)
                target))]
          [(Ja target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 2)
                target))]
          [(Jcc cc target)
            (if (cobj.compiler-object-condition-code-valid? cc)
              (set!
                ok
                (compiler-tlci-native-patch-rel32!
                  import-names
                  import-offsets
                  import-count
                  error
                  bases
                  symbols
                  (&mut bytes)
                  (+ offset 2)
                  target))
              (begin
                (compiler-tlci-native-fail!
                  error
                  "tlci native image: condition code must be between 0 and 15")
                (set! ok false)))]
          [(Branch true-target false-target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
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
                  (&mut bytes)
                  (+ offset 10)
                  false-target))
              unit)]
          [(LoadRip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(LoadRipAddress target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(LoadRipAddressR11 target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(StoreRip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(MovRcxRip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(MovRdxRip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(LoadRipAddressRdx target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(StoreR14Rip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(StoreR15Rip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(AddRcxRip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 3)
                target))]
          [(XorpdRip target)
            (set!
              ok
              (compiler-tlci-native-patch-rel32!
                import-names
                import-offsets
                import-count
                error
                bases
                symbols
                (&mut bytes)
                (+ offset 4)
                target))]
          [_ unit])
        (set!
          offset
          (+ offset (layout.compiler-object-layout-instr-size instr)))
        (set! index (+ index 1))))
    ok))

;; Patch SymbolAddress slots in a rendered data region and record each slot
;; as a base-relative fixup. `region-base` is the region offset where these
;; records begin.
(define (compiler-tlci-native-patch-data!
  [import-names : (&mut import-names (__tl_dyn-array String))]
  [import-offsets : (&mut import-offsets (__tl_dyn-array i64))]
  [import-count : (&mut import-count (__tl_dyn-array i64))]
  [error : (&mut error (__tl_dyn-array String))]
  [bases : CompilerTlciNativeBases]
  [symbols : (& symbols CompilerTlciNativeSymbolIndex)]
  [image : cobj.CompilerObjectImage]
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [kind : cobj.CompilerObjectSectionKind]
  [region-base : i64]
  [fixup-offsets : (&mut fixup-offsets (__tl_dyn-array i64))]
  [fixup-count : (__tl_dyn-array i64)]) : bool
  (let
    [records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data image kind)]
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [offset : i64 region-base]
    [ok : bool true]
    (while (and ok (< index count))
      (let
        [record : cobj.CompilerObjectDataRecord
          (cobj.compiler-object-data-record-list-ref records index)]
        (match (owned_view.compiler-owned-shared-view record)
          [(SymbolAddress target)
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
                  (if (>= slot (array-length fixup-offsets))
                    (begin
                      (compiler-tlci-native-fail!
                        error
                        "tlci native image: too many base fixups")
                      (set! ok false))
                    (begin
                      (compiler-tlci-native-patch-i32! bytes offset value)
                      (compiler-tlci-native-patch-i32! bytes (+ offset 4) 0)
                      (set! (array-ref fixup-offsets slot) offset)
                      (set! (array-ref fixup-count 0) (+ slot 1)))))))]
          [(SymbolRva32 _)
            (compiler-tlci-native-fail!
              error
              "tlci native image: SymbolRva32 is not supported")
            (set! ok false)]
          [_ unit])
        (set!
          offset
          (cobj.compiler-object-data-record-end-offset record offset))
        (set! index (+ index 1))))
    ok))

;; Lay out the object image as one mappable region: text | rodata | data |
;; got | bss. Renders sections with the ELF encoder, resolves every internal
;; relocation in place, assigns GOT slots for extern value loads, and
;; returns the bytes plus the loader's import and base-fixup records.
(define (compiler-tlci-native-layout-image [image : cobj.CompilerObjectImage]) : ResultCompilerTlciNativeLayout
  (let
    [text-instrs : cobj.CompilerObjectX64InstrList
      (compiler-tlci-native-section-instrs
        (owned_view.compiler-owned-shared-view image)
        (Text))]
    [text-size : i64
      (layout.compiler-object-layout-instrs-size
        (owned_view.compiler-owned-shared-view text-instrs))]
    [rodata-records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data
        (owned_view.compiler-owned-shared-view image)
        (Rodata))]
    [rodata-base : i64 (compiler-tlci-native-align text-size 16)]
    [rodata-size : i64
      (layout.compiler-object-layout-data-records-size-from
        (owned_view.compiler-owned-shared-view rodata-records)
        rodata-base)]
    [data-records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data
        (owned_view.compiler-owned-shared-view image)
        (Data))]
    [data-base : i64 (compiler-tlci-native-align rodata-size 16)]
    [data-size : i64
      (layout.compiler-object-layout-data-records-size-from
        (owned_view.compiler-owned-shared-view data-records)
        data-base)]
    [got-base : i64 (compiler-tlci-native-align data-size 8)]
    [got-size : i64 (* compiler-tlci-native-import-cap 8)]
    [bss-records : cobj.CompilerObjectDataRecordList
      (compiler-tlci-native-section-data
        (owned_view.compiler-owned-shared-view image)
        (Bss))]
    [bss-base : i64 (compiler-tlci-native-align (+ got-base got-size) 16)]
    [bss-size : i64
      (-
        (layout.compiler-object-layout-data-records-size-from
          bss-records
          bss-base)
        bss-base)]
    [bases : CompilerTlciNativeBases
      (CompilerTlciNativeBases 0 rodata-base data-base got-base bss-base)]
    [symbols-index : CompilerTlciNativeSymbolIndex
      (compiler-tlci-native-build-symbol-index
        (owned_view.compiler-owned-shared-view image)
        bases)]
    [import-names : (__tl_dyn-array String)
      (__tl_make-array String compiler-tlci-native-import-cap)]
    [import-offsets : (__tl_dyn-array i64)
      (__tl_make-array i64 compiler-tlci-native-import-cap)]
    [import-count : (__tl_dyn-array i64) (__tl_make-array 0)]
    [error : (__tl_dyn-array String) (__tl_make-array "")]
    [fixup-cap : i64
      (+
        (compiler-tlci-native-data-fixup-count
          (owned_view.compiler-owned-shared-view rodata-records))
        (compiler-tlci-native-data-fixup-count
          (owned_view.compiler-owned-shared-view data-records)))]
    [fixup-offsets : (__tl_dyn-array i64) (__tl_make-array i64 fixup-cap)]
    [fixup-count : (__tl_dyn-array i64) (__tl_make-array 0)]
    [builder : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity bss-base)]
    (layout.compiler-object-layout-render-instrs! (&mut builder) text-instrs)
    (layout.compiler-object-layout-render-padding-to!
      (&mut builder)
      rodata-base)
    (layout.compiler-object-layout-render-data-records!
      (&mut builder)
      rodata-records
      rodata-base)
    (layout.compiler-object-layout-render-padding-to! (&mut builder) data-base)
    (layout.compiler-object-layout-render-data-records!
      (&mut builder)
      data-records
      data-base)
    (layout.compiler-object-layout-render-padding-to! (&mut builder) bss-base)
    (let
      [bytes : (__tl_dyn-array u8)
        (byte_buf_core.byte-buf-builder-to-array (& builder))]
      [text-ok : bool
        (compiler-tlci-native-patch-text!
          (&mut import-names)
          (&mut import-offsets)
          (&mut import-count)
          (&mut error)
          bases
          (& symbols-index)
          (owned_view.compiler-owned-shared-view image)
          (owned_view.compiler-owned-shared-view bytes))]
      [rodata-ok : bool
        (if text-ok
          (compiler-tlci-native-patch-data!
            (&mut import-names)
            (&mut import-offsets)
            (&mut import-count)
            (&mut error)
            bases
            (& symbols-index)
            (owned_view.compiler-owned-shared-view image)
            (&mut bytes)
            (Rodata)
            rodata-base
            (&mut fixup-offsets)
            (owned_view.compiler-owned-shared-view fixup-count))
          false)]
      [data-ok : bool
        (if rodata-ok
          (compiler-tlci-native-patch-data!
            (&mut import-names)
            (&mut import-offsets)
            (&mut import-count)
            (&mut error)
            bases
            (& symbols-index)
            (owned_view.compiler-owned-shared-view image)
            (&mut bytes)
            (Data)
            data-base
            (&mut fixup-offsets)
            (owned_view.compiler-owned-shared-view fixup-count))
          false)]
      (if (not data-ok)
        (Err
          (let
            [message : String
              (owned_view.compiler-owned-array-element-shared-view error 0)]
            (if (= (string.string-length message) 0)
              "tlci native image: layout failed"
              message)))
        (Ok
          (CompilerTlciNativeLayout
            bytes
            bss-base
            bss-size
            import-names
            import-offsets
            (array-ref import-count 0)
            fixup-offsets
            (array-ref fixup-count 0)))))))

;; Region offset of exported text symbol `name`, for macro entry records.
;; Text offsets of exported functions in symbol-table order. Generated
;; transformer programs define one entry function per catalog identity and
;; nothing else, so export order is the identity order; compact function
;; naming makes label names unstable, so offsets are the contract.
;; Function bodies are emitted in definition order, so ascending text offsets
;; are definition order regardless of symbol-table ordering.
;; Primitives-only packaging boundary: callers (the producer, tools) pass
;; metadata as canonical text and plain arrays, and every tlci_core nominal
;; stays inside this module's single import instance.
(defenum ResultCompilerTlciNativeBytes
  (Ok (__tl_dyn-array u8))
  (Err String))

(define (compiler-tlci-native-package
  [metadata-text : String]
  [build-hash : String]
  [host-platform : i64]
  [rodata : (__tl_dyn-array u8)]
  [code : (__tl_dyn-array u8)]
  [imports : (__tl_dyn-array u8)]
  [fixup-offsets : (__tl_dyn-array i64)]
  [fixup-count : i64]
  [identities : (__tl_dyn-array String)]
  [entry-offsets : (__tl_dyn-array i64)]
  [macro-count : i64]) : ResultCompilerTlciNativeBytes
  (match (tlci_core.tlci-metadata-parse metadata-text)
    [(Err message)
      (Err (str_cat.str-cat "package metadata rejected: " message))]
    [(Ok metadata)
      (match (tlci_core.tlci-emit-native-package-image
        metadata
        build-hash
        host-platform
        (tlci_core.TlciNativePackageInput
          rodata
          code
          imports
          fixup-offsets
          fixup-count
          identities
          entry-offsets
          macro-count))
        [(Err message) (Err message)]
        [(Ok bytes) (Ok bytes)])]))

(define (compiler-tlci-native-entry-offset
  [image : cobj.CompilerObjectImage]
  [name : String]) : i64
  (layout.compiler-object-layout-instr-label-offset-from
    (compiler-tlci-native-section-instrs image (Text))
    name
    0))

;; Emit the layout's base fixups as a tlci fixups section: one u64 slot offset
;; per absolute pointer slot, which the loader rebases by the map base.
(define (compiler-tlci-native-emit-fixups
  [layout : (& layout CompilerTlciNativeLayout)]) : (__tl_dyn-array u8)
  (let
    [count : i64 layout.fixup-count]
    [out : (__tl_dyn-array u8)
      (__tl_make-array u8 (* count tlci_core.tlci-section-fixup-record-size))]
    [index : i64 0]
    (while (< index count)
      (tlci_core.tlci-set-u64!
        (&mut out)
        (* index tlci_core.tlci-section-fixup-record-size)
        (array-ref layout.fixup-offsets index))
      (set! index (+ index 1)))
    out))

;; Reverse the compiler's assembly-safe spelling for the callback-name
;; alphabet. Callback names contain lowercase ASCII, hyphens, `?`, and `->`;
;; they never contain source underscores, so this transform is unambiguous.
(define (compiler-tlci-native-host-import-unmangle [encoded : (& encoded str)]) : String
  (let
    [index : i64 0]
    [len : i64 (string.string-length encoded)]
    [out : String ""]
    (while (< index len)
      (cond
        [(and
          (<= (+ index 9) len)
          (string.eq (string.substring encoded index 9) "_question"))
          (set! out (str_cat.str-cat out "?"))
          (set! index (+ index 9))]
        [(and
          (<= (+ index 3) len)
          (string.eq (string.substring encoded index 3) "_gt"))
          (set! out (str_cat.str-cat out ">"))
          (set! index (+ index 3))]
        [(= (string.string-ref encoded index) '_')
          (set! out (str_cat.str-cat out "-"))
          (set! index (+ index 1))]
        [else
          (set! out (str_cat.str-cat out (string.substring encoded index 1)))
          (set! index (+ index 1))]))
    out))

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
  (Ok (__tl_dyn-array u8))
  (Err String))

(define (compiler-tlci-native-emit-imports
  [layout : (& layout CompilerTlciNativeLayout)]) : ResultCompilerTlciNativeImports
  (let
    [count : i64 layout.import-count]
    [names : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    [names-len : i64 0]
    [error : String ""]
    (while (and (= (string.string-length error) 0) (< index count))
      (let
        [import-name : String
          (owned_view.compiler-owned-array-element-shared-view
            layout.import-names
            index)]
        [name : String (compiler-tlci-native-host-import-name import-name)]
        (if (= (string.string-length name) 0)
          (set!
            error
            (str_cat.str-cat-scoped
              "tlci native image: unknown host import "
              import-name))
          (begin
            (set! (array-ref names index) name)
            (set! names-len (+ names-len (string.string-length name)))
            (set! index (+ index 1))))))
    (if (= (string.string-length error) 0)
      (if (= count 0)
        (Ok (__tl_make-array u8 0))
        (let
          [records-end : i64
            (+
              tlci_core.tlci-section-import-header-size
              (* count tlci_core.tlci-section-import-record-size))]
          [out : (__tl_dyn-array u8)
            (__tl_make-array u8 (+ records-end names-len))]
          [name-offset : i64 records-end]
          (tlci_core.tlci-set-u64! (&mut out) 0 count)
          (set! index 0)
          (while (< index count)
            (let
              [record : i64
                (+
                  tlci_core.tlci-section-import-header-size
                  (* index tlci_core.tlci-section-import-record-size))]
              [name : String
                (owned_view.compiler-owned-array-element-shared-view
                  names
                  index)]
              [name-len : i64 (string.string-length name)]
              (tlci_core.tlci-set-u64!
                (&mut out)
                record
                (array-ref layout.import-offsets index))
              (tlci_core.tlci-set-u64! (&mut out) (+ record 8) name-offset)
              (tlci_core.tlci-set-u64! (&mut out) (+ record 16) name-len)
              (tlci_core.tlci-put-string! (&mut out) name-offset name)
              (set! name-offset (+ name-offset name-len))
              (set! index (+ index 1))))
          (Ok out)))
      (Err error))))