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
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.string)

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

;; Mutable resolution state for one layout run (single-threaded build step).
(define compiler-tlci-native-import-names : (Array String)
  (array.make-array String 64))
(define compiler-tlci-native-import-offsets : (Array i64)
  (array.make-array i64 64))
(define compiler-tlci-native-import-count : (Array i64)
  (make-array 0))
(define compiler-tlci-native-error : (Array String)
  (array.make-array String 1))

;; Section base offsets for one layout run, passed by value.
(defstruct CompilerTlciNativeBases
  (text i64)
  (rodata i64)
  (data i64)
  (got i64)
  (bss i64))

(define (compiler-tlci-native-reset!) : unit
  (begin
    (array-set! compiler-tlci-native-import-count 0 0)
    (array-set! compiler-tlci-native-error 0 "")))

(define (compiler-tlci-native-fail! [message : String]) : i64
  (begin
    (if (= (string.string-length (array-ref compiler-tlci-native-error 0)) 0)
      (array-set! compiler-tlci-native-error 0 message)
      unit)
    -1))

;; GOT slot offset for extern `name`, allocating on first use.
(define (compiler-tlci-native-got-slot!
  [bases : CompilerTlciNativeBases]
  [name : String]) : i64
  (let
    [count : i64 (array-ref compiler-tlci-native-import-count 0)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq (array-ref compiler-tlci-native-import-names index) name)
          (set! found index)
          (set! index (+ index 1))))
      (if (>= found 0)
        (array-ref compiler-tlci-native-import-offsets found)
        (if (>= count compiler-tlci-native-import-cap)
          (compiler-tlci-native-fail!
            "tlci native image: too many imported symbols")
          (let
            [offset : i64 (+ (struct-get bases got) (* count 8))]
            (begin
              (array-set! compiler-tlci-native-import-names count name)
              (array-set! compiler-tlci-native-import-offsets count offset)
              (array-set! compiler-tlci-native-import-count 0 (+ count 1))
              offset)))))))

;; Resolve symbol `name` to its region offset: text labels, rodata/data
;; labels, then bss labels. Externs resolve to their GOT slot. -1 = unknown.
(define (compiler-tlci-native-symbol-offset!
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
                    (compiler-tlci-native-got-slot! bases name)
                    (compiler-tlci-native-fail!
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
  [bases : CompilerTlciNativeBases]
  [image : cobj.CompilerObjectImage]
  [bytes : (Array u8)]
  [site : i64]
  [target : String]) : bool
  (let
    [target-offset : i64
      (compiler-tlci-native-symbol-offset! bases image target)]
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
                      (string.append
                        "tlci native image: direct extern call "
                        target))
                    (set! ok false))
                  (set!
                    ok
                    (compiler-tlci-native-patch-rel32!
                      bases
                      image
                      bytes
                      (+ offset 1)
                      target)))]
              [(cobj.CompilerObjectX64Instr.TailCall target)
                (if (compiler-tlci-native-extern-symbol? image target)
                  (begin
                    (compiler-tlci-native-fail!
                      (string.append
                        "tlci native image: direct extern call "
                        target))
                    (set! ok false))
                  (set!
                    ok
                    (compiler-tlci-native-patch-rel32!
                      bases
                      image
                      bytes
                      (+ offset 1)
                      target)))]
              [(cobj.CompilerObjectX64Instr.Jump target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 1)
                    target))]
              [(cobj.CompilerObjectX64Instr.Ja target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
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
                      bases
                      image
                      bytes
                      (+ offset 5)
                      true-target))
                  (if ok
                    (set!
                      ok
                      (compiler-tlci-native-patch-rel32!
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
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.StoreRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.MovRcxRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.MovRdxRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.AddRcxRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
                    bases
                    image
                    bytes
                    (+ offset 3)
                    target))]
              [(cobj.CompilerObjectX64Instr.XorpdRip target)
                (set!
                  ok
                  (compiler-tlci-native-patch-rel32!
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
                    (compiler-tlci-native-symbol-offset! bases image target)]
                  (if (< value 0)
                    (set! ok false)
                    (let
                      [slot : i64 (array-ref fixup-count 0)]
                      (if (>= slot compiler-tlci-native-fixup-cap)
                        (begin
                          (compiler-tlci-native-fail!
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
    [fixup-offsets : (Array i64)
      (array.make-array i64 compiler-tlci-native-fixup-cap)]
    [fixup-count : (Array i64) (make-array 0)]
    (begin
      (compiler-tlci-native-reset!)
      (let
        [builder : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-with-capacity (+ got-base got-size))]
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
          (compiler-object-elf-render-padding-to!
            (&mut builder)
            (+ got-base got-size))
          (let
            [bytes : (Array u8)
              (byte_buf_core.byte-buf-builder-to-array (& builder))]
            [text-ok : bool
              (compiler-tlci-native-patch-text! bases image bytes)]
            [rodata-ok : bool
              (if text-ok
                (compiler-tlci-native-patch-data!
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
                  [message : String (array-ref compiler-tlci-native-error 0)]
                  (if (= (string.string-length message) 0)
                    "tlci native image: layout failed"
                    message)))
              (ResultCompilerTlciNativeLayout.Ok
                (CompilerTlciNativeLayout
                  bytes
                  (+ got-base got-size)
                  bss-size
                  compiler-tlci-native-import-names
                  compiler-tlci-native-import-offsets
                  (array-ref compiler-tlci-native-import-count 0)
                  fixup-offsets
                  (array-ref fixup-count 0))))))))))

;; Region offset of exported text symbol `name`, for macro entry records.
(define (compiler-tlci-native-entry-offset
  [image : cobj.CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-elf-instr-label-offset-from
    (compiler-tlci-native-section-instrs
      image
      (cobj.CompilerObjectSectionKind.Text))
    name
    0))