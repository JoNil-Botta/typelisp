;; Cross-route contract for conditional branches, including malformed records.
(import stdlib.iterator)
(import compiler_object as cobj)
(import compiler_object_asm as asm)
(import compiler_object_elf as elf)
(import compiler_object_coff as coff)
(import compiler_object_layout as layout)
(import compiler_tlci_native_image as native)
(import compiler_backend_object_target as parts)
(import compiler_owned_view as owned_view)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)

(define (branch-i64! [actual : i64] [expected : i64]) : unit
  (test.assert-i64-eq actual expected "branch encoding and relocation"))

(define (branch-image [cc : i64] [target : String]) : cobj.CompilerObjectImage
  (let
    [body : parts.CompilerBackendObjectTargetParts
      (parts.compiler-backend-object-parts-empty)]
    (for [index (iterator.range 0 2)]
      (let
        [label : String
          (if (= index 0)
            "begin"
            "end")]
        (set!
          body
          (parts.compiler-backend-object-symbol-local-section
            body
            (owned_view.compiler-owned-shared-view label)
            (Text)
            (Function)))
        (set!
          body
          (parts.compiler-backend-object-add-text-relocation
            body
            (owned_view.compiler-owned-shared-view label)
            (Branch)
            (if (= index 0)
              (owned_view.compiler-owned-shared-view target)
              "begin")))
        (set! body (parts.compiler-backend-object-add-text body (Label label)))
        (set!
          body
          (parts.compiler-backend-object-add-text
            body
            (Jcc
              cc
              (if (= index 0)
                (owned_view.compiler-owned-shared-view target)
                "begin"))))
        (if (= index 0)
          (set!
            body
            (parts.compiler-backend-object-add-text
              body
              (Bytes (parts.compiler-backend-object-bytes-from-hex "90"))))
          unit)))
    (cobj.CompilerObjectImage
      (cobj.compiler-object-section-builder-finish
        (cobj.compiler-object-section-builder-push
          (cobj.compiler-object-section-builder-with-capacity 1)
          (Section
            (Text)
            (cobj.compiler-object-data-record-builder-finish body.data)
            (cobj.compiler-object-instr-builder-finish body.text))))
      (cobj.compiler-object-symbol-builder-finish body.symbols)
      (cobj.compiler-object-relocation-builder-finish body.relocations))))

(define (branch-bytes! [bytes : (& bytes str)] [offset : i64] [cc : i64]) : unit
  (branch-i64! (layout.compiler-object-layout-u8-at bytes offset) 0x0f)
  (branch-i64!
    (layout.compiler-object-layout-u8-at bytes (+ offset 1))
    (+ 0x80 cc))
  (branch-i64! (layout.compiler-object-layout-u32-at bytes (+ offset 2)) 0))

(test
  conditional-branch-encodings
  (let
    [mnemonics : (__tl_dyn-array String)
      (__tl_make-array
        "jo"
        "jno"
        "jb"
        "jae"
        "je"
        "jne"
        "jbe"
        "ja"
        "js"
        "jns"
        "jp"
        "jnp"
        "jl"
        "jge"
        "jle"
        "jg")]
    (for [cc (iterator.range 0 16)]
      (let
        [image : cobj.CompilerObjectImage (branch-image cc "end")]
        (match (asm.compiler-object-asm-render
          (owned_view.compiler-owned-shared-view image))
          [(Err message) (test.assert-true false message)]
          [(Ok text)
            (test.assert-true
              (string.eq
                text
                (str_cat.str-cat
                  "\n.text\n    .balign 16\nbegin:\n    "
                  (str_cat.str-cat
                    (string.copy (array-ref mnemonics cc))
                    (str_cat.str-cat
                      " end\n    .byte 0x90\nend:\n    "
                      (str_cat.str-cat
                        (string.copy (array-ref mnemonics cc))
                        " begin\n\n")))))
              "all condition mnemonics preserve both targets")])
        (match (elf.compiler-object-elf-render image)
          [(Err message) (test.assert-true false message)]
          [(Ok bytes)
            (let
              [text : i64 (elf.compiler-object-elf-load-offset image 0)]
              [relocs : i64 (elf.compiler-object-elf-rela-offset image 0)]
              (for [index (iterator.range 0 2)]
                (branch-bytes! bytes (+ text (* index 7)) cc)
                (branch-i64!
                  (elf.compiler-object-elf-rela-target-offset-at
                    bytes
                    relocs
                    index)
                  (+ 2 (* index 7)))
                (branch-i64!
                  (elf.compiler-object-elf-rela-type-at bytes relocs index)
                  2)
                (branch-i64!
                  (layout.compiler-object-layout-u32-at
                    bytes
                    (+ relocs (+ (* index 24) 12)))
                  (elf.compiler-object-elf-symbol-index
                    image
                    (if (= index 0)
                      "end"
                      "begin")))
                (test.assert-true
                  (elf.compiler-object-elf-rela-addend-rel32?
                    bytes
                    relocs
                    index)
                  "ELF branch addend is -4")))])
        (match (coff.compiler-object-coff-render image)
          [(Err message) (test.assert-true false message)]
          [(Ok bytes)
            (let
              [text : i64
                (coff.compiler-object-coff-section-raw-pointer image (Text))]
              [relocs : i64
                (coff.compiler-object-coff-relocation-pointer image (Text))]
              (for [index (iterator.range 0 2)]
                (let
                  [record : i64 (+ relocs (* index 10))]
                  (branch-bytes! bytes (+ text (* index 7)) cc)
                  (branch-i64!
                    (layout.compiler-object-layout-u32-at bytes record)
                    (+ 2 (* index 7)))
                  (branch-i64!
                    (layout.compiler-object-layout-u32-at bytes (+ record 4))
                    (coff.compiler-object-coff-symbol-index
                      image
                      (if (= index 0)
                        "end"
                        "begin")))
                  (branch-i64!
                    (layout.compiler-object-layout-u16-at bytes (+ record 8))
                    4))))])
        (match (native.compiler-tlci-native-layout-image image)
          [(Err message) (test.assert-true false message)]
          [(Ok image-layout)
            (branch-i64! (cast (array-ref image-layout.bytes 0) : i64) 0x0f)
            (branch-i64!
              (cast (array-ref image-layout.bytes 1) : i64)
              (+ 0x80 cc))
            (branch-i64! (cast (array-ref image-layout.bytes 2) : i64) 1)
            (branch-i64! (cast (array-ref image-layout.bytes 7) : i64) 0x0f)
            (branch-i64!
              (cast (array-ref image-layout.bytes 8) : i64)
              (+ 0x80 cc))
            (branch-i64! (cast (array-ref image-layout.bytes 9) : i64) 0xf3)
            (branch-i64! (cast (array-ref image-layout.bytes 12) : i64) 0xff)])))))

(test
  conditional-branch-rejections
  (let
    [codes : (__tl_dyn-array i64)
      (__tl_make-array -1 16 256 9223372036854775807 4)]
    (for [index (iterator.range 0 5)]
      (let
        [image : cobj.CompilerObjectImage
          (branch-image
            (array-ref codes index)
            (if (= index 4)
              "missing"
              "end"))]
        (if (< index 4)
          (test.assert-true
            (match (asm.compiler-object-asm-render
              (owned_view.compiler-owned-shared-view image))
              [(Err _) true]
              [_ false])
            "assembly rejects invalid condition codes")
          unit)
        (test.assert-true
          (match (elf.compiler-object-elf-render image)
            [(Err _) true]
            [_ false])
          "ELF rejects invalid codes and missing symbols")
        (test.assert-true
          (match (coff.compiler-object-coff-render image)
            [(Err _) true]
            [_ false])
          "COFF rejects invalid codes and missing symbols")
        (test.assert-true
          (match (native.compiler-tlci-native-layout-image image)
            [(Err _) true]
            [_ false])
          "TLCI rejects invalid codes and missing symbols")))))