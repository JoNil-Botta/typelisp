;; Cross-route contract for conditional branches, including malformed records.
(import compiler_object as cobj)
(import compiler_object_asm as asm)
(import compiler_object_elf as elf)
(import compiler_object_coff as coff)
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
    [index : i64 0]
    (begin
      (while (< index 2)
        (let
          [label : String
            (if (= index 0)
              "begin"
              "end")]
          (begin
            (set!
              body
              (parts.compiler-backend-object-symbol-local-section
                body
                (owned_view.compiler-owned-shared-view label)
                (cobj.CompilerObjectSectionKind.Text)
                (cobj.CompilerObjectSymbolKind.Function)))
            (set!
              body
              (parts.compiler-backend-object-add-text-relocation
                body
                (owned_view.compiler-owned-shared-view label)
                (cobj.CompilerObjectRelocationKind.Branch)
                (if (= index 0)
                  (owned_view.compiler-owned-shared-view target)
                  "begin")))
            (set!
              body
              (parts.compiler-backend-object-add-text
                body
                (cobj.CompilerObjectX64Instr.Label label)))
            (set!
              body
              (parts.compiler-backend-object-add-text
                body
                (cobj.CompilerObjectX64Instr.Jcc
                  cc
                  (if (= index 0)
                    (owned_view.compiler-owned-shared-view target)
                    "begin"))))
            (if (= index 0)
              (set!
                body
                (parts.compiler-backend-object-add-text
                  body
                  (cobj.CompilerObjectX64Instr.Bytes
                    (parts.compiler-backend-object-bytes-from-hex "90"))))
              unit)
            (set! index (+ index 1)))))
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish
          (cobj.compiler-object-section-builder-push
            (cobj.compiler-object-section-builder-with-capacity 1)
            (cobj.CompilerObjectSection.Section
              (cobj.CompilerObjectSectionKind.Text)
              (cobj.compiler-object-data-record-builder-finish body.data)
              (cobj.compiler-object-instr-builder-finish body.text))))
        (cobj.compiler-object-symbol-builder-finish body.symbols)
        (cobj.compiler-object-relocation-builder-finish body.relocations)))))

(define (branch-bytes! [bytes : String] [offset : i64] [cc : i64]) : unit
  (begin
    (branch-i64!
      (elf.compiler-object-elf-u8-at
        (owned_view.compiler-owned-shared-view bytes)
        offset)
      0x0f)
    (branch-i64!
      (elf.compiler-object-elf-u8-at
        (owned_view.compiler-owned-shared-view bytes)
        (+ offset 1))
      (+ 0x80 cc))
    (branch-i64! (elf.compiler-object-elf-u32-at bytes (+ offset 2)) 0)))

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
    [cc : i64 0]
    (while (< cc 16)
      (let
        [image : cobj.CompilerObjectImage (branch-image cc "end")]
        (begin
          (match (asm.compiler-object-asm-render
            (owned_view.compiler-owned-shared-view image))
            [(asm.ResultCompilerObjectAsm.Err message)
              (test.assert-true false message)]
            [(asm.ResultCompilerObjectAsm.Ok text)
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
          (match (elf.compiler-object-elf-render
            (owned_view.compiler-owned-shared-view image))
            [(elf.ResultCompilerObjectElf.Err message)
              (test.assert-true false message)]
            [(elf.ResultCompilerObjectElf.Ok bytes)
              (let
                [text : i64
                  (elf.compiler-object-elf-text-offset
                    (owned_view.compiler-owned-shared-view image))]
                [relocs : i64
                  (elf.compiler-object-elf-rela-text-offset
                    (owned_view.compiler-owned-shared-view image))]
                [index : i64 0]
                (while (< index 2)
                  (begin
                    (branch-bytes!
                      (owned_view.compiler-owned-shared-view bytes)
                      (+ text (* index 7))
                      cc)
                    (branch-i64!
                      (elf.compiler-object-elf-rela-target-offset-at
                        (owned_view.compiler-owned-shared-view bytes)
                        relocs
                        index)
                      (+ 2 (* index 7)))
                    (branch-i64!
                      (elf.compiler-object-elf-rela-type-at
                        (owned_view.compiler-owned-shared-view bytes)
                        relocs
                        index)
                      2)
                    (branch-i64!
                      (elf.compiler-object-elf-u32-at
                        (owned_view.compiler-owned-shared-view bytes)
                        (+ relocs (+ (* index 24) 12)))
                      (elf.compiler-object-elf-symbol-index
                        (owned_view.compiler-owned-shared-view image)
                        (if (= index 0)
                          "end"
                          "begin")))
                    (test.assert-true
                      (elf.compiler-object-elf-rela-addend-rel32?
                        (owned_view.compiler-owned-shared-view bytes)
                        relocs
                        index)
                      "ELF branch addend is -4")
                    (set! index (+ index 1)))))])
          (match (coff.compiler-object-coff-render
            (owned_view.compiler-owned-shared-view image))
            [(coff.ResultCompilerObjectCoff.Err message)
              (test.assert-true false message)]
            [(coff.ResultCompilerObjectCoff.Ok bytes)
              (let
                [text : i64
                  (coff.compiler-object-coff-section-raw-pointer
                    (owned_view.compiler-owned-shared-view image)
                    (cobj.CompilerObjectSectionKind.Text))]
                [relocs : i64
                  (coff.compiler-object-coff-relocation-pointer
                    (owned_view.compiler-owned-shared-view image)
                    (cobj.CompilerObjectSectionKind.Text))]
                [index : i64 0]
                (while (< index 2)
                  (let
                    [record : i64 (+ relocs (* index 10))]
                    (begin
                      (branch-bytes!
                        (owned_view.compiler-owned-shared-view bytes)
                        (+ text (* index 7))
                        cc)
                      (branch-i64!
                        (coff.compiler-object-coff-u32-at
                          (owned_view.compiler-owned-shared-view bytes)
                          record)
                        (+ 2 (* index 7)))
                      (branch-i64!
                        (coff.compiler-object-coff-u32-at
                          (owned_view.compiler-owned-shared-view bytes)
                          (+ record 4))
                        (coff.compiler-object-coff-symbol-index
                          (owned_view.compiler-owned-shared-view image)
                          (if (= index 0)
                            "end"
                            "begin")))
                      (branch-i64!
                        (coff.compiler-object-coff-u16-at
                          (owned_view.compiler-owned-shared-view bytes)
                          (+ record 8))
                        4)
                      (set! index (+ index 1))))))])
          (match (native.compiler-tlci-native-layout-image image)
            [(native.ResultCompilerTlciNativeLayout.Err message)
              (test.assert-true false message)]
            [(native.ResultCompilerTlciNativeLayout.Ok layout)
              (begin
                (branch-i64! (cast (array-ref layout.bytes 0) : i64) 0x0f)
                (branch-i64!
                  (cast (array-ref layout.bytes 1) : i64)
                  (+ 0x80 cc))
                (branch-i64! (cast (array-ref layout.bytes 2) : i64) 1)
                (branch-i64! (cast (array-ref layout.bytes 7) : i64) 0x0f)
                (branch-i64!
                  (cast (array-ref layout.bytes 8) : i64)
                  (+ 0x80 cc))
                (branch-i64! (cast (array-ref layout.bytes 9) : i64) 0xf3)
                (branch-i64! (cast (array-ref layout.bytes 12) : i64) 0xff))])
          (set! cc (+ cc 1)))))))

(test
  conditional-branch-rejections
  (let
    [codes : (__tl_dyn-array i64)
      (__tl_make-array -1 16 256 9223372036854775807 4)]
    [index : i64 0]
    (while (< index 5)
      (let
        [image : cobj.CompilerObjectImage
          (branch-image
            (array-ref codes index)
            (if (= index 4)
              "missing"
              "end"))]
        (begin
          (if (< index 4)
            (test.assert-true
              (match (asm.compiler-object-asm-render
                (owned_view.compiler-owned-shared-view image))
                [(asm.ResultCompilerObjectAsm.Err _) true]
                [_ false])
              "assembly rejects invalid condition codes")
            unit)
          (test.assert-true
            (match (elf.compiler-object-elf-render
              (owned_view.compiler-owned-shared-view image))
              [(elf.ResultCompilerObjectElf.Err _) true]
              [_ false])
            "ELF rejects invalid codes and missing symbols")
          (test.assert-true
            (match (coff.compiler-object-coff-render
              (owned_view.compiler-owned-shared-view image))
              [(coff.ResultCompilerObjectCoff.Err _) true]
              [_ false])
            "COFF rejects invalid codes and missing symbols")
          (test.assert-true
            (match (native.compiler-tlci-native-layout-image image)
              [(native.ResultCompilerTlciNativeLayout.Err _) true]
              [_ false])
            "TLCI rejects invalid codes and missing symbols")
          (set! index (+ index 1)))))))