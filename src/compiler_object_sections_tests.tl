;; Independent physical-header witnesses for extensible sections.
(import compiler_object as obj)
(import compiler_object_layout as layout)
(import compiler_object_elf as elf)
(import compiler_object_coff as coff)
(import compiler_object_asm as asm)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.test)
(import stdlib.io)

(define (image-with [sections : obj.CompilerObjectSectionBuilder]) : obj.CompilerObjectImage
  (obj.CompilerObjectImage
    (obj.compiler-object-section-builder-finish sections)
    (obj.compiler-object-symbol-builder-finish
      (obj.compiler-object-symbol-builder-with-capacity 1))
    (obj.compiler-object-relocation-builder-finish
      (obj.compiler-object-relocation-builder-with-capacity 1))))

(define (section
  [id : i64]
  [name : String]
  [format : obj.CompilerObjectSectionFormat]
  [align : i64]
  [storage : obj.CompilerObjectSectionStorage]
  [data : obj.CompilerObjectDataRecordList]) : obj.CompilerObjectSection
  (Section
    (obj.CompilerObjectSectionSpec
      (obj.CompilerObjectSectionId id)
      42
      name
      align
      storage
      format)
    data
    (obj.compiler-object-instr-list-empty)))

(define (records [r : obj.CompilerObjectDataRecord]) : obj.CompilerObjectDataRecordList
  (obj.compiler-object-data-record-builder-finish
    (obj.compiler-object-data-record-builder-push
      (obj.compiler-object-data-record-builder-with-capacity 1)
      r)))

(define (metadata [coff? : bool] [zero? : bool]) : obj.CompilerObjectSection
  (let
    [s : obj.CompilerObjectSection
      (if zero?
        (section
          101
          ".reserve"
          (if coff?
            (Coff 0xc0000080)
            (Elf 8 3))
          32
          (ZeroFill 128)
          (obj.compiler-object-data-record-list-empty))
        (section
          38
          ".extra.metadata"
          (if coff?
            (Coff 0x42000040)
            (Elf 1 0))
          64
          (Initialized)
          (records (Bytes "meta!"))))]
    (match (layout.compiler-object-checked-section s coff?)
      [(Ok checked) checked]
      [(Err msg) (io.panic msg)])))

(define (fixture [coff? : bool] [reverse? : bool]) : obj.CompilerObjectImage
  (image-with
    (obj.compiler-object-section-builder-push
      (obj.compiler-object-section-builder-push
        (obj.compiler-object-section-builder-with-capacity 1)
        (metadata coff? reverse?))
      (metadata coff? (not reverse?)))))

(define (elf-bytes [image : (& obj.CompilerObjectImage)]) : String
  (match (elf.compiler-object-elf-render image)
    [(Ok bytes) bytes]
    [(Err e) (io.panic e)]))

(define (coff-bytes [image : (& obj.CompilerObjectImage)]) : String
  (match (coff.compiler-object-coff-render image)
    [(Ok bytes) bytes]
    [(Err e) (io.panic e)]))

(test
  extra-elf-section
  (let
    [image (fixture false true)]
    [bytes (elf-bytes (& image))]
    [again (elf-bytes (& (fixture false false)))]
    [headers (layout.compiler-object-layout-u32-at (& bytes) 40)]
    [first (+ headers 64)]
    [second (+ first 64)]
    [strings
      (layout.compiler-object-layout-u32-at
        (& bytes)
        (+ headers (+ (* 7 64) 24)))]
    [raw (layout.compiler-object-layout-u32-at (& bytes) (+ first 24))]
    (test.assert-true
      (string.eq (& bytes) (& again))
      "ELF stable under reversed insertion")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& bytes) 60)
      9
      "ELF physical section count")
    (test.assert-true
      (layout.compiler-object-layout-prefix-at?
        (& bytes)
        ".extra.metadata"
        (+ strings (layout.compiler-object-layout-u32-at (& bytes) first)))
      "ELF sh_name")
    (test.assert-true
      (layout.compiler-object-layout-prefix-at? (& bytes) "meta!" raw)
      "ELF metadata bytes")
    (test.assert-i64-eq (% raw 64) 0 "ELF file alignment")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& bytes) (+ first 48))
      64
      "ELF sh_addralign")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& bytes) (+ second 4))
      8
      "ELF NOBITS")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& bytes) (+ second 32))
      128
      "ELF zero-fill extent")
    (match (elf.compiler-object-elf-render-archive (& image))
      [(Ok object)
        (test.assert-true
          (layout.compiler-object-layout-contains? (& object) ".extra.metadata")
          "archive retains metadata")]
      [(Err e) (io.panic e)])
    (match (asm.compiler-object-asm-render image)
      [(Ok text)
        (test.assert-true
          (string.contains
            (& text)
            ".section .extra.metadata,\"\",@progbits\n    .balign 64")
          "ELF assembler attributes")
        (test.assert-true
          (string.contains (& text) ".zero 128")
          "assembler reserves full extent")]
      [(Err e) (io.panic e)])))

(test
  extra-coff-section
  (let
    [image (fixture true false)]
    [bytes (coff-bytes (& image))]
    [again (coff-bytes (& (fixture true true)))]
    [raw (layout.compiler-object-layout-u32-at (& bytes) 40)]
    [strings (layout.compiler-object-layout-u32-at (& bytes) 8)]
    (test.assert-true
      (string.eq (& bytes) (& again))
      "COFF stable under reversed insertion")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& bytes) 2)
      2
      "COFF physical section count")
    (test.assert-true
      (layout.compiler-object-layout-prefix-at? (& bytes) "/4" 20)
      "COFF long section name offset")
    (test.assert-true
      (layout.compiler-object-layout-prefix-at?
        (& bytes)
        ".extra.metadata"
        (+ strings 4))
      "COFF section string table")
    (test.assert-true
      (layout.compiler-object-layout-prefix-at? (& bytes) "meta!" raw)
      "COFF metadata bytes")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& bytes) 56)
      0x42700040
      "COFF metadata characteristics")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& bytes) 76)
      128
      "COFF uninitialized size")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& bytes) 80)
      0
      "COFF uninitialized section has no file data")
    (test.assert-i64-eq strings (+ raw 5) "zero-fill takes no file space")
    (match (asm.compiler-object-asm-render image)
      [(Ok text)
        (test.assert-true
          (string.contains (& text) ".section .extra.metadata,\"drD\"")
          "COFF assembler characteristics")]
      [(Err e) (io.panic e)])))

(define (invalid-section [which : i64]) : obj.CompilerObjectSection
  (section
    (if (= which 0)
      1
      2)
    (if (= which 1)
      ".first"
      ".second")
    (match which
      [3 (Elf 8 3)]
      [4 (Coff 0x40000040)]
      [5 (Elf 8 3)]
      [_ (Elf 1 0)])
    (if (= which 2)
      3
      1)
    (if (= which 5)
      (ZeroFill 128)
      (Initialized))
    (records
      (if (= which 6)
        (Zero 9223372036854775807)
        (Bytes "abc")))))

(test
  reject-invalid-sections
  (for [i (iterator.range 0 7)]
    (let
      [image
        (image-with
          (obj.compiler-object-section-builder-push
            (obj.compiler-object-section-builder-push
              (obj.compiler-object-section-builder-with-capacity 2)
              (section
                1
                ".first"
                (Elf 1 0)
                1
                (Initialized)
                (obj.compiler-object-data-record-list-empty)))
            (invalid-section i)))]
      (match (elf.compiler-object-elf-render (& image))
        [(Err e)
          (test.assert-true
            (string.contains (& e) "elf: section .")
            "reject malformed section with context")]
        [(Ok _) (io.panic "ELF accepted malformed section")])
      (match (asm.compiler-object-asm-render image)
        [(Err _) unit]
        [(Ok _) (io.panic "assembly accepted malformed section")]))))

;; Both records use private IDs unrelated to file section numbers. Introducing
;; an earlier section changes both numbers without changing either reference.
(define (fixup-image [coff? : bool]) : obj.CompilerObjectImage
  (let
    [data (obj.compiler-object-data-record-builder-with-capacity 2)]
    [src
      (section
        99
        ".pointers"
        (if coff?
          (Coff 0x40000040)
          (Elf 1 0))
        8
        (Initialized)
        (obj.compiler-object-data-record-builder-finish
          (obj.compiler-object-data-record-builder-push
            (obj.compiler-object-data-record-builder-push data (Label "site"))
            (SymbolAddress "dst"))))]
    [dst
      (section
        54
        ".target"
        (if coff?
          (Coff 0xc0000080)
          (Elf 8 3))
        1
        (ZeroFill 128)
        (records (Label "dst")))]
    [sections (obj.compiler-object-section-builder-with-capacity 3)]
    [symbols (obj.compiler-object-symbol-builder-with-capacity 1)]
    [relocs (obj.compiler-object-relocation-builder-with-capacity 1)]
    (obj.CompilerObjectImage
      (obj.compiler-object-section-builder-finish
        (obj.compiler-object-section-builder-push
          (obj.compiler-object-section-builder-push
            (obj.compiler-object-section-builder-push sections src)
            dst)
          (metadata coff? false)))
      (obj.compiler-object-symbol-builder-finish
        (obj.compiler-object-symbol-builder-push
          symbols
          (Symbol "dst" (Local) (Data) (Some (obj.CompilerObjectSectionId 54)))))
      (obj.compiler-object-relocation-builder-finish
        (obj.compiler-object-relocation-builder-push
          relocs
          (Relocation (obj.CompilerObjectSectionId 99) "site" (Abs64) "dst"))))))

(test
  private-section-relocations
  (let
    [coff (coff-bytes (& (fixup-image true)))]
    [elf (elf-bytes (& (fixup-image false)))]
    [sym (layout.compiler-object-layout-u32-at (& coff) 8)]
    [rel (layout.compiler-object-layout-u32-at (& coff) 124)]
    [sh (layout.compiler-object-layout-u32-at (& elf) 40)]
    [rela (+ sh (* 6 64))]
    [elf-rel (layout.compiler-object-layout-u32-at (& elf) (+ rela 24))]
    [elf-sym
      (layout.compiler-object-layout-u32-at (& elf) (+ (+ sh (* 7 64)) 24))]
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& coff) (+ sym 12))
      2
      "COFF target symbol section")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& coff) 132)
      1
      "COFF relocation in third section")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& coff) (+ rel 8))
      1
      "COFF ADDR64")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& elf) (+ rela 44))
      3
      "ELF relocation sh_info")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& elf) (+ elf-rel 12))
      1
      "ELF relocation symbol index")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& elf) (+ elf-sym 30))
      2
      "ELF target symbol section")))