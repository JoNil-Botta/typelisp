;; Golden, round-trip and rejection coverage for compiler_eh_frame.tl.  The
;; external fixture bytes, their sources and the reproduction recipe live in
;; tests/fixtures/eh-frame/.
(import compiler_eh_frame as eh)
(import stdlib.io)
(import stdlib.string)
(cfg test (import stdlib.test))

(define (eh-frame-test-hex-digit [c : i64]) : i64
  (if (<= c 57)
    (- c 48)
    (+ (- c 97) 10)))

(define (eh-frame-test-bytes [hex : (& hex str)]) : (__tl_dyn-array u8)
  (let
    [count : i64 (/ (string.string-length hex) 2)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref out index)
            (cast
              (+
                (*
                  (eh-frame-test-hex-digit
                    (cast (string.char-at hex (* index 2)) : i64))
                  16)
                (eh-frame-test-hex-digit
                  (cast (string.char-at hex (+ (* index 2) 1)) : i64)))
              : u8))
          (set! index (+ index 1))))
      out)))

;; GNU as 2.47: two functions, a leaf and one with a remembered state.
(define (eh-frame-test-gas-basic) : (__tl_dyn-array u8)
  (eh-frame-test-bytes
    "1400000000000000017a5200017810011b0c070890010000100000001c0000000000000004000000000000002800000030000000000000001b00000000410e108602430d06418303490a450c0708410b45c3410c07080000"))

;; The same object linked by GNU ld 2.47 --eh-frame-hdr: .text at 0x401000,
;; .eh_frame_hdr at 0x402000, .eh_frame at 0x402020.
(define (eh-frame-test-gas-linked) : (__tl_dyn-array u8)
  (eh-frame-test-bytes
    "1400000000000000017a5200017810011b0c070890010000100000001c000000c0efffff04000000000000002800000030000000b0efffff1b00000000410e108602430d06418303490a450c0708410b45c3410c07080000"))

(define (eh-frame-test-gas-linked-header) : (__tl_dyn-array u8)
  (eh-frame-test-bytes
    "011b033b1c0000000200000000f0ffff3800000004f0ffff4c000000"))

;; GCC 16.2.1 -O2 and Clang 22.1.8 -O2 objects of probe.c.in.
(define (eh-frame-test-gcc) : (__tl_dyn-array u8)
  (eh-frame-test-bytes
    "1400000000000000017a5200017810011b0c070890010000100000001c0000000000000006000000000000002c00000030000000000000007700000000440e30488604498305478c03488d026ac345cc45cd490e08470e304e0e08002800000060000000000000009000000000410e108602470d06498d038c048305026d0a0c0708420b00000000"))

(define (eh-frame-test-clang) : (__tl_dyn-array u8)
  (eh-frame-test-bytes
    "1400000000000000017a5200017810011b0c070890010000100000001c0000000000000008000000000000003400000030000000000000004700000000420e10420e18420e20410e28410e3083058c048e038f02770e28410e20420e18420e10420e08002800000068000000000000008a00000000410e108602430d064683058e048f0302760c0708450c0610000000"))

(define (eh-frame-test-image
  [bytes : (& bytes (__tl_dyn-array u8))]
  [input : i64]) : eh.CompilerEhFrameImage
  (let
    [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
    (match (eh.compiler-eh-frame-decode bytes input (& limits))
      [(eh.ResultCompilerEhFrameImage.Ok image) image]
      [(eh.ResultCompilerEhFrameImage.Err error) (io.panic error.message)])))

;; The decode error code at `offset`, after setting `bytes[at]` to `value`.
(define (eh-frame-test-mutant-error
  [hex : (& hex str)]
  [at : i64]
  [value : i64]
  [limits : (& limits eh.CompilerEhFrameLimits)]) : eh.CompilerEhFrameError
  (let
    [bytes : (__tl_dyn-array u8) (eh-frame-test-bytes hex)]
    (begin
      (when (>= at 0) (set! (array-ref bytes at) (cast value : u8)))
      (match (eh.compiler-eh-frame-decode (& bytes) 7 limits)
        [(eh.ResultCompilerEhFrameImage.Ok _)
          (eh.CompilerEhFrameError 0 -1 -1 -1 "decoded")]
        [(eh.ResultCompilerEhFrameImage.Err error) error]))))

(define (eh-frame-test-range-eq?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]
  [hex : (& hex str)]) : bool
  (let
    [expected : (__tl_dyn-array u8) (eh-frame-test-bytes hex)]
    [same? : bool (= length (array-length expected))]
    [index : i64 0]
    (begin
      (while (and same? (< index length))
        (begin
          (when
            (!= (array-ref bytes (+ start index)) (array-ref expected index))
            (set! same? false))
          (set! index (+ index 1))))
      same?)))

(define (eh-frame-test-bytes-eq?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [hex : (& hex str)]) : bool
  (eh-frame-test-range-eq? bytes 0 (array-length bytes) hex))

(define (eh-frame-test-same-bytes?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [same? : bool (= (array-length left) (array-length right))]
    [index : i64 0]
    (begin
      (while (and same? (< index (array-length left)))
        (begin
          (when
            (!= (array-ref left index) (array-ref right index))
            (set! same? false))
          (set! index (+ index 1))))
      same?)))

(cfg
  test
  (test
    eh-frame-decodes-gas-records
    (let
      [bytes : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      [image : eh.CompilerEhFrameImage (eh-frame-test-image (& bytes) 3)]
      [cie : eh.CompilerEhFrameCie (array-ref image.cies 0)]
      [first : eh.CompilerEhFrameFde (array-ref image.fdes 0)]
      [second : eh.CompilerEhFrameFde (array-ref image.fdes 1)]
      (begin
        (test.assert-i64-eq (array-length image.cies) 1 "one CIE")
        (test.assert-i64-eq (array-length image.fdes) 2 "two FDEs")
        (test.assert-false image.terminated? "gas ends at clean EOF")
        (test.assert-i64-eq cie.input 3 "CIE input identity")
        (test.assert-i64-eq cie.offset 0 "CIE offset")
        (test.assert-i64-eq cie.code-alignment 1 "code alignment")
        (test.assert-i64-eq cie.data-alignment -8 "data alignment")
        (test.assert-i64-eq cie.return-register 16 "return register")
        (test.assert-i64-eq cie.pointer-encoding 0x1b "pcrel|sdata4")
        (test.assert-true
          (eh-frame-test-range-eq?
            (& image.programs)
            cie.program-start
            cie.program-length
            "0c07089001")
          "CIE program without its nop padding")
        (test.assert-i64-eq first.offset 0x18 "first FDE offset")
        (test.assert-i64-eq first.cie 0 "first FDE CIE")
        (test.assert-i64-eq first.location-offset 0x20 "first location field")
        (test.assert-i64-eq first.location-width 4 "location width")
        (test.assert-i64-eq first.location-raw 0 "relocatable location addend")
        (test.assert-i64-eq first.range 4 "first range")
        (test.assert-i64-eq first.program-length 0 "all-nop program")
        (test.assert-i64-eq second.offset 0x2c "second FDE offset")
        (test.assert-i64-eq second.location-offset 0x34 "second location field")
        (test.assert-i64-eq second.range 0x1b "second range")
        (test.assert-true
          (eh-frame-test-range-eq?
            (& image.programs)
            second.program-start
            second.program-length
            "410e108602430d06418303490a450c0708410b45c3410c0708")
          "second program")))))

(cfg
  test
  (test
    eh-frame-decodes-compiler-objects-at-relocation-offsets
    (let
      [gcc-bytes : (__tl_dyn-array u8) (eh-frame-test-gcc)]
      [clang-bytes : (__tl_dyn-array u8) (eh-frame-test-clang)]
      [gcc : eh.CompilerEhFrameImage (eh-frame-test-image (& gcc-bytes) 1)]
      [clang : eh.CompilerEhFrameImage (eh-frame-test-image (& clang-bytes) 2)]
      (begin
        (test.assert-i64-eq (array-length gcc.fdes) 3 "gcc FDEs")
        (test.assert-i64-eq (array-length clang.fdes) 3 "clang FDEs")
        ;; R_X86_64_PC32 .rela.eh_frame offsets reported by readelf.
        (test.assert-i64-eq
          (array-ref gcc.fdes 0).location-offset
          0x20
          "gcc reloc 1")
        (test.assert-i64-eq
          (array-ref gcc.fdes 1).location-offset
          0x34
          "gcc reloc 2")
        (test.assert-i64-eq
          (array-ref gcc.fdes 2).location-offset
          0x64
          "gcc reloc 3")
        (test.assert-i64-eq
          (array-ref clang.fdes 2).location-offset
          0x6c
          "clang reloc 3")
        (test.assert-i64-eq (array-ref gcc.fdes 1).range 0x77 "gcc walk range")
        (test.assert-i64-eq
          (array-ref gcc.fdes 2).range
          0x90
          "gcc framed range")
        (test.assert-i64-eq
          (array-ref clang.fdes 1).range
          0x47
          "clang walk range")
        (test.assert-i64-eq
          (array-ref clang.fdes 2).range
          0x8a
          "clang framed range")))))

(cfg
  test
  (test
    eh-frame-decodes-linked-section-and-header
    (let
      [bytes : (__tl_dyn-array u8) (eh-frame-test-gas-linked)]
      [header : (__tl_dyn-array u8) (eh-frame-test-gas-linked-header)]
      [image : eh.CompilerEhFrameImage (eh-frame-test-image (& bytes) 0)]
      [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
      (begin
        (test.assert-i64-eq
          (eh.compiler-eh-frame-fde-initial-location
            (& (array-ref image.fdes 0))
            0x402020)
          0x401000
          "first linked location")
        (test.assert-i64-eq
          (eh.compiler-eh-frame-fde-initial-location
            (& (array-ref image.fdes 1))
            0x402020)
          0x401004
          "second linked location")
        (match (eh.compiler-eh-frame-decode-header
          (& header)
          0x402000
          (& limits))
          [(eh.ResultCompilerEhFrameHeader.Err error) (io.panic error.message)]
          [(eh.ResultCompilerEhFrameHeader.Ok decoded)
            (begin
              (test.assert-i64-eq
                decoded.eh-frame-address
                0x402020
                "field-relative pointer")
              (test.assert-i64-eq (array-length decoded.rows) 2 "two rows")
              (test.assert-i64-eq
                (array-ref decoded.rows 0).initial-location
                0x401000
                "row 0 pc")
              (test.assert-i64-eq
                (array-ref decoded.rows 0).fde-address
                0x402038
                "row 0 FDE")
              (test.assert-i64-eq
                (array-ref decoded.rows 1).initial-location
                0x401004
                "row 1 pc")
              (test.assert-i64-eq
                (array-ref decoded.rows 1).fde-address
                0x40204c
                "row 1 FDE"))])))))

;; Encode the two gas FDEs for code at 0x401000 into a section at 0x402020.
(define (eh-frame-test-encode-basic
  [images : (& images (__tl_dyn-array eh.CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array eh.CompilerEhFrameSelection))]
  [section-address : i64]) : eh.CompilerEhFrameOutput
  (let
    [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
    (match (eh.compiler-eh-frame-encode
      images
      selections
      section-address
      (& limits))
      [(eh.ResultCompilerEhFrameOutput.Ok output) output]
      [(eh.ResultCompilerEhFrameOutput.Err error) (io.panic error.message)])))

(cfg
  test
  (test
    eh-frame-canonical-encoding-round-trips
    (let
      [bytes : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      [images : (__tl_dyn-array eh.CompilerEhFrameImage)
        (__tl_make-array eh.CompilerEhFrameImage 1)]
      [selections : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 2)]
      [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
      (begin
        (set! (array-ref images 0) (eh-frame-test-image (& bytes) 5))
        ;; Selected in reverse; the encoder orders by final location.
        (set!
          (array-ref selections 0)
          (eh.CompilerEhFrameSelection 0 1 0x401004))
        (set!
          (array-ref selections 1)
          (eh.CompilerEhFrameSelection 0 0 0x401000))
        (let
          [output : eh.CompilerEhFrameOutput
            (eh-frame-test-encode-basic (& images) (& selections) 0x402020)]
          [decoded : eh.CompilerEhFrameImage
            (eh-frame-test-image (& output.bytes) 9)]
          (begin
            (test.assert-true
              (eh-frame-test-bytes-eq?
                (& output.bytes)
                "1400000000000000017a5200017810011b0c070890010000140000001c000000c0efffff0400000000000000000000002c00000034000000acefffff1b00000000410e108602430d06418303490a450c0708410b45c3410c070800000000000000000000")
              "canonical bytes: 8-byte records, recomputed pointers, terminator")
            (test.assert-true
              decoded.terminated?
              "canonical output is terminated")
            (test.assert-i64-eq (array-length decoded.fdes) 2 "two FDEs")
            (test.assert-i64-eq
              (eh.compiler-eh-frame-fde-initial-location
                (& (array-ref decoded.fdes 0))
                0x402020)
              0x401000
              "first relocated location")
            (test.assert-i64-eq
              (eh.compiler-eh-frame-fde-initial-location
                (& (array-ref decoded.fdes 1))
                0x402020)
              0x401004
              "second relocated location")
            (test.assert-i64-eq
              (array-ref output.rows 0).fde-address
              0x402038
              "row 0 FDE")
            (test.assert-i64-eq
              (array-ref output.rows 1).fde-address
              0x402050
              "row 1 FDE")
            ;; A header 0x2000 below and code 0x1000 below the section keeps
            ;; the field-relative and header-relative bases apart.
            (match (eh.compiler-eh-frame-encode-header
              (& output.rows)
              0x400000
              0x402020
              (& limits))
              [(eh.ResultCompilerEhFrameHeaderBytes.Ok header)
                (match (eh.compiler-eh-frame-decode-header
                  (& header)
                  0x400000
                  (& limits))
                  [(eh.ResultCompilerEhFrameHeader.Ok table)
                    (begin
                      (test.assert-i64-eq
                        table.eh-frame-address
                        0x402020
                        "header pointer")
                      (test.assert-i64-eq
                        (array-ref table.rows 1).initial-location
                        0x401004
                        "header row pc")
                      (test.assert-i64-eq
                        (array-ref table.rows 1).fde-address
                        0x402050
                        "header row FDE"))]
                  [(eh.ResultCompilerEhFrameHeader.Err error)
                    (io.panic error.message)])]
              [_ (io.panic "expected a header")])))))))

(cfg
  test
  (test
    eh-frame-deduplicates-cies-independent-of-input-order
    (let
      [gas-bytes : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      [gcc-bytes : (__tl_dyn-array u8) (eh-frame-test-gcc)]
      [clang-bytes : (__tl_dyn-array u8) (eh-frame-test-clang)]
      [forward : (__tl_dyn-array eh.CompilerEhFrameImage)
        (__tl_make-array eh.CompilerEhFrameImage 3)]
      [backward : (__tl_dyn-array eh.CompilerEhFrameImage)
        (__tl_make-array eh.CompilerEhFrameImage 3)]
      [forward-selections : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 8)]
      [backward-selections : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 8)]
      [index : i64 0]
      (begin
        (set! (array-ref forward 0) (eh-frame-test-image (& gas-bytes) 1))
        (set! (array-ref forward 1) (eh-frame-test-image (& gcc-bytes) 2))
        (set! (array-ref forward 2) (eh-frame-test-image (& clang-bytes) 3))
        (set! (array-ref backward 0) (eh-frame-test-image (& clang-bytes) 3))
        (set! (array-ref backward 1) (eh-frame-test-image (& gcc-bytes) 2))
        (set! (array-ref backward 2) (eh-frame-test-image (& gas-bytes) 1))
        ;; gas code at 0x1000, gcc at 0x2000, clang at 0x3000.
        (while (< index 8)
          (let
            [image : i64 (cond [(< index 2) 0] [(< index 5) 1] [else 2])]
            [fde : i64
              (cond
                [(< index 2) index]
                [(< index 5) (- index 2)]
                [else (- index 5)])]
            [location : i64 (+ (* (+ image 1) 0x1000) (* fde 0x200))]
            (begin
              (set!
                (array-ref forward-selections index)
                (eh.CompilerEhFrameSelection image fde location))
              (set!
                (array-ref backward-selections (- 7 index))
                (eh.CompilerEhFrameSelection (- 2 image) fde location))
              (set! index (+ index 1)))))
        (let
          [a : eh.CompilerEhFrameOutput
            (eh-frame-test-encode-basic
              (& forward)
              (& forward-selections)
              0x9000)]
          [b : eh.CompilerEhFrameOutput
            (eh-frame-test-encode-basic
              (& backward)
              (& backward-selections)
              0x9000)]
          [decoded : eh.CompilerEhFrameImage
            (eh-frame-test-image (& a.bytes) 4)]
          (begin
            (test.assert-true
              (eh-frame-test-same-bytes? (& a.bytes) (& b.bytes))
              "input order does not change the canonical bytes")
            (test.assert-i64-eq
              (array-length decoded.cies)
              1
              "one retained CIE")
            (test.assert-i64-eq
              (array-length decoded.fdes)
              8
              "every FDE retained")))))))

;; Encoding one gas FDE with a CIE contract changed in `image` never merges it
;; with the unchanged CIE.
(cfg
  test
  (test
    eh-frame-keeps-distinct-cie-contracts
    (let
      [plain : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      [changed : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      [images : (__tl_dyn-array eh.CompilerEhFrameImage)
        (__tl_make-array eh.CompilerEhFrameImage 2)]
      [selections : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 2)]
      (begin
        ;; Data alignment -8 (0x78) becomes -4 (0x7c).
        (set! (array-ref changed 13) (cast 0x7c : u8))
        (set! (array-ref images 0) (eh-frame-test-image (& plain) 1))
        (set! (array-ref images 1) (eh-frame-test-image (& changed) 2))
        (set! (array-ref selections 0) (eh.CompilerEhFrameSelection 0 0 0x1000))
        (set! (array-ref selections 1) (eh.CompilerEhFrameSelection 1 0 0x2000))
        (let
          [output : eh.CompilerEhFrameOutput
            (eh-frame-test-encode-basic (& images) (& selections) 0x8000)]
          [decoded : eh.CompilerEhFrameImage
            (eh-frame-test-image (& output.bytes) 3)]
          (test.assert-i64-eq
            (array-length decoded.cies)
            2
            "distinct contracts stay apart"))))))

(cfg
  test
  (test
    eh-frame-accepts-terminator-and-clean-eof
    (let
      [terminated : (__tl_dyn-array u8)
        (eh-frame-test-bytes
          "1400000000000000017a5200017810011b0c070890010000100000001c000000000000000400000000000000000000000")]
      [image : eh.CompilerEhFrameImage (eh-frame-test-image (& terminated) 1)]
      (begin
        (test.assert-true image.terminated? "explicit terminator")
        (test.assert-i64-eq (array-length image.fdes) 1 "one FDE before it")))))

(define (eh-frame-test-rejects?
  [hex : (& hex str)]
  [at : i64]
  [value : i64]
  [code : i64]
  [offset : i64]) : bool
  (let
    [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
    [error : eh.CompilerEhFrameError
      (eh-frame-test-mutant-error hex at value (& limits))]
    (and (= error.code code) (= error.offset offset))))

(cfg
  test
  (test
    eh-frame-rejects-unadmitted-forms
    (let
      [gas : String
        "1400000000000000017a5200017810011b0c070890010000100000001c0000000000000004000000000000002800000030000000000000001b00000000410e108602430d06418303490a450c0708410b45c3410c07080000"]
      (begin
        (test.assert-true
          (eh-frame-test-rejects? (& gas) -1 0 0 -1)
          "the unmutated fixture decodes")
        (test.assert-true
          (eh-frame-test-rejects?
            "ffffffff"
            -1
            0
            eh.compiler-eh-frame-error-dwarf64
            0)
          "DWARF64 length")
        (test.assert-true
          (eh-frame-test-rejects?
            "140000"
            -1
            0
            eh.compiler-eh-frame-error-truncated
            0)
          "truncated length")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            0
            0x80
            eh.compiler-eh-frame-error-truncated
            0)
          "record past the section")
        (test.assert-true
          (eh-frame-test-rejects? (& gas) 8 3 eh.compiler-eh-frame-error-cie 8)
          "CIE version 3")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            10
            80
            eh.compiler-eh-frame-error-cie
            9)
          "augmentation zP")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            16
            0x03
            eh.compiler-eh-frame-error-cie
            16)
          "udata4 FDE pointer encoding")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            15
            2
            eh.compiler-eh-frame-error-cie
            15)
          "two augmentation data bytes")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            14
            131
            eh.compiler-eh-frame-error-cie
            14)
          "return register outside the register set")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            12
            0
            eh.compiler-eh-frame-error-cie
            12)
          "zero code alignment")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            28
            0x1d
            eh.compiler-eh-frame-error-cie-reference
            28)
          "CIE pointer to no CIE")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            36
            0
            eh.compiler-eh-frame-error-fde
            36)
          "zero FDE range")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            39
            0x80
            eh.compiler-eh-frame-error-fde
            36)
          "negative FDE range")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            40
            1
            eh.compiler-eh-frame-error-fde
            40)
          "FDE augmentation data")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            41
            0x01
            eh.compiler-eh-frame-error-cfa
            41)
          "DW_CFA_set_loc")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            41
            0x0f
            eh.compiler-eh-frame-error-cfa
            41)
          "DW_CFA_def_cfa_expression")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            41
            0x3f
            eh.compiler-eh-frame-error-cfa
            41)
          "unknown opcode")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            41
            0x0b
            eh.compiler-eh-frame-error-cfa
            41)
          "restore_state without a remembered state")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            41
            0x7f
            eh.compiler-eh-frame-error-cfa
            41)
          "advance past the FDE range")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            22
            0x44
            eh.compiler-eh-frame-error-cfa
            22)
          "location advance in a CIE program")
        (test.assert-true
          (eh-frame-test-rejects?
            (& gas)
            23
            0x90
            eh.compiler-eh-frame-error-cfa
            23)
          "truncated operand at the end of a CIE program")
        (test.assert-true
          (eh-frame-test-rejects?
            "1400000000000000017a5200017810011b0c070890010000000000000000"
            -1
            0
            eh.compiler-eh-frame-error-record
            28)
          "bytes after the terminator")))))

(define (eh-frame-test-decode-code
  [bytes : (& bytes (__tl_dyn-array u8))]
  [limits : eh.CompilerEhFrameLimits]) : i64
  (match (eh.compiler-eh-frame-decode bytes 1 (& limits))
    [(eh.ResultCompilerEhFrameImage.Err error) error.code]
    [(eh.ResultCompilerEhFrameImage.Ok _) 0]))

(cfg
  test
  (test
    eh-frame-enforces-limits
    (let
      [bytes : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      (begin
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits 88 64 3 64 64 100))
          0
          "the fixture fits its exact limits")
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits 88 64 2 64 64 100))
          eh.compiler-eh-frame-error-record-limit
          "record limit")
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits 87 64 3 64 64 100))
          eh.compiler-eh-frame-error-input-limit
          "input limit")
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits 88 64 3 20 64 100))
          eh.compiler-eh-frame-error-cfa
          "program byte limit")
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits 88 64 3 64 0 100))
          eh.compiler-eh-frame-error-cfa
          "remembered state depth limit")
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits 88 64 3 64 64 4))
          eh.compiler-eh-frame-error-work-limit
          "work limit")
        (test.assert-i64-eq
          (eh-frame-test-decode-code
            (& bytes)
            (eh.CompilerEhFrameLimits -1 64 3 64 64 100))
          eh.compiler-eh-frame-error-invalid-limits
          "invalid limits")))))

(define (eh-frame-test-header-error
  [rows : (& rows (__tl_dyn-array eh.CompilerEhFrameRow))]
  [header-address : i64]
  [eh-frame-address : i64]) : i64
  (let
    [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
    (match (eh.compiler-eh-frame-encode-header
      rows
      header-address
      eh-frame-address
      (& limits))
      [(eh.ResultCompilerEhFrameHeaderBytes.Err error) error.code]
      [(eh.ResultCompilerEhFrameHeaderBytes.NoHeader) -1]
      [(eh.ResultCompilerEhFrameHeaderBytes.Ok _) 0])))

(cfg
  test
  (test
    eh-frame-header-rejects-ambiguous-and-overflowing-tables
    (let
      [empty : (__tl_dyn-array eh.CompilerEhFrameRow)
        (__tl_make-array eh.CompilerEhFrameRow 0)]
      [rows : (__tl_dyn-array eh.CompilerEhFrameRow)
        (__tl_make-array eh.CompilerEhFrameRow 2)]
      (begin
        (test.assert-i64-eq
          (eh-frame-test-header-error (& empty) 0x1000 0x2000)
          -1
          "no header")
        (set! (array-ref rows 0) (eh.CompilerEhFrameRow 0x5000 0x10 0x9000))
        (set! (array-ref rows 1) (eh.CompilerEhFrameRow 0x5000 0x08 0x9020))
        (test.assert-i64-eq
          (eh-frame-test-header-error (& rows) 0x1000 0x2000)
          eh.compiler-eh-frame-error-header-order
          "duplicate initial location")
        (set! (array-ref rows 1) (eh.CompilerEhFrameRow 0x5008 0x08 0x9020))
        (test.assert-i64-eq
          (eh-frame-test-header-error (& rows) 0x1000 0x2000)
          eh.compiler-eh-frame-error-header-order
          "overlapping ranges")
        (set! (array-ref rows 1) (eh.CompilerEhFrameRow 0x5010 0x08 0x9020))
        (test.assert-i64-eq
          (eh-frame-test-header-error (& rows) 0x1000 0x2000)
          0
          "adjacent ranges")
        (test.assert-i64-eq
          (eh-frame-test-header-error (& rows) 0x100001000 0x2000)
          eh.compiler-eh-frame-error-address
          "eh_frame pointer overflow")
        (set!
          (array-ref rows 1)
          (eh.CompilerEhFrameRow 0x100000000 0x08 0x9020))
        (test.assert-i64-eq
          (eh-frame-test-header-error (& rows) 0x1000 0x2000)
          eh.compiler-eh-frame-error-address
          "table displacement overflow")))))

(cfg
  test
  (test
    eh-frame-header-decode-rejects-malformed-tables
    (let
      [limits : eh.CompilerEhFrameLimits (eh.compiler-eh-frame-default-limits)]
      [unsorted : (__tl_dyn-array u8)
        (eh-frame-test-bytes
          "011b033b1c0000000200000004f0ffff3800000000f0ffff4c000000")]
      [short : (__tl_dyn-array u8)
        (eh-frame-test-bytes
          "011b033b1c0000000300000000f0ffff3800000004f0ffff4c000000")]
      [version : (__tl_dyn-array u8)
        (eh-frame-test-bytes
          "021b033b1c0000000200000000f0ffff3800000004f0ffff4c000000")]
      (begin
        (match (eh.compiler-eh-frame-decode-header
          (& unsorted)
          0x402000
          (& limits))
          [(eh.ResultCompilerEhFrameHeader.Err error)
            (test.assert-i64-eq
              error.code
              eh.compiler-eh-frame-error-header-order
              "unsorted")]
          [_ (io.panic "expected an order error")])
        (match (eh.compiler-eh-frame-decode-header
          (& short)
          0x402000
          (& limits))
          [(eh.ResultCompilerEhFrameHeader.Err error)
            (test.assert-i64-eq
              error.code
              eh.compiler-eh-frame-error-header
              "count mismatch")]
          [_ (io.panic "expected a size error")])
        (match (eh.compiler-eh-frame-decode-header
          (& version)
          0x402000
          (& limits))
          [(eh.ResultCompilerEhFrameHeader.Err error)
            (test.assert-i64-eq
              error.code
              eh.compiler-eh-frame-error-header
              "version")]
          [_ (io.panic "expected a version error")])))))

(define (eh-frame-test-leb [hex : (& hex str)] [signed? : bool]) : eh.CompilerEhFrameLeb
  (let
    [bytes : (__tl_dyn-array u8) (eh-frame-test-bytes hex)]
    (eh.compiler-eh-frame-leb (& bytes) 0 (array-length bytes) signed?)))

(cfg
  test
  (test
    eh-frame-leb-boundaries
    (begin
      (test.assert-i64-eq
        (eh-frame-test-leb "e58e26" false).value
        624485
        "DWARF ULEB example")
      (test.assert-i64-eq
        (eh-frame-test-leb "c0bb78" true).value
        -123456
        "DWARF SLEB example")
      (test.assert-i64-eq (eh-frame-test-leb "7f" true).value -1 "one-byte -1")
      (test.assert-i64-eq
        (eh-frame-test-leb "7f" false).value
        127
        "one-byte 127")
      (test.assert-i64-eq
        (eh-frame-test-leb "8100" false).next
        2
        "overlong but in range")
      (test.assert-i64-eq
        (eh-frame-test-leb "ffffffffffffffff3f" false).value
        4611686018427387903
        "largest admitted unsigned value")
      (test.assert-false
        (eh-frame-test-leb "80808080808080808001" false).ok?
        "ten-byte encoding")
      (test.assert-false
        (eh-frame-test-leb "ffffffffffffffff7f" false).ok?
        "unsigned value past 2^62")
      (test.assert-false (eh-frame-test-leb "8080" false).ok? "truncated")
      (test.assert-false
        (eh-frame-test-leb "8080808080808080c000" true).ok?
        "ten-byte signed encoding")
      (test.assert-i64-eq
        (eh-frame-test-leb "808080808080808040" true).value
        (- 0 4611686018427387904)
        "smallest admitted signed value"))))

(define (eh-frame-test-encode-code
  [images : (& images (__tl_dyn-array eh.CompilerEhFrameImage))]
  [selections : (& selections (__tl_dyn-array eh.CompilerEhFrameSelection))]
  [section-address : i64]
  [limits : eh.CompilerEhFrameLimits]) : i64
  (match (eh.compiler-eh-frame-encode
    images
    selections
    section-address
    (& limits))
    [(eh.ResultCompilerEhFrameOutput.Err error) error.code]
    [(eh.ResultCompilerEhFrameOutput.Ok _) 0]))

(cfg
  test
  (test
    eh-frame-encode-rejects-bad-selections
    (let
      [bytes : (__tl_dyn-array u8) (eh-frame-test-gas-basic)]
      [images : (__tl_dyn-array eh.CompilerEhFrameImage)
        (__tl_make-array eh.CompilerEhFrameImage 1)]
      [one : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 1)]
      [two : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 2)]
      [none : (__tl_dyn-array eh.CompilerEhFrameSelection)
        (__tl_make-array eh.CompilerEhFrameSelection 0)]
      [defaults : eh.CompilerEhFrameLimits
        (eh.compiler-eh-frame-default-limits)]
      (begin
        (set! (array-ref images 0) (eh-frame-test-image (& bytes) 1))
        (set! (array-ref one 0) (eh.CompilerEhFrameSelection 0 2 0x1000))
        (test.assert-i64-eq
          (eh-frame-test-encode-code (& images) (& one) 0x2000 defaults)
          eh.compiler-eh-frame-error-selection
          "no such FDE")
        (set! (array-ref one 0) (eh.CompilerEhFrameSelection 0 0 0x100001000))
        (test.assert-i64-eq
          (eh-frame-test-encode-code (& images) (& one) 0x2000 defaults)
          eh.compiler-eh-frame-error-address
          "initial location displacement overflows sdata4")
        (set! (array-ref one 0) (eh.CompilerEhFrameSelection 0 0 0x1000))
        (test.assert-i64-eq
          (eh-frame-test-encode-code
            (& images)
            (& one)
            0x2000
            (eh.CompilerEhFrameLimits 88 50 3 64 64 100))
          eh.compiler-eh-frame-error-output-limit
          "output limit")
        (set! (array-ref two 0) (eh.CompilerEhFrameSelection 0 1 0x1000))
        (set! (array-ref two 1) (eh.CompilerEhFrameSelection 0 1 0x3000))
        (test.assert-i64-eq
          (eh-frame-test-encode-code (& images) (& two) 0x2000 defaults)
          eh.compiler-eh-frame-error-selection
          "one FDE selected twice")
        (match (eh.compiler-eh-frame-encode
          (& images)
          (& none)
          0x2000
          (& defaults))
          [(eh.ResultCompilerEhFrameOutput.Ok output)
            (begin
              (test.assert-true
                (eh-frame-test-bytes-eq? (& output.bytes) "00000000")
                "an empty selection is only the terminator")
              (test.assert-i64-eq (array-length output.rows) 0 "no rows"))]
          [(eh.ResultCompilerEhFrameOutput.Err error) (io.panic error.message)])))))