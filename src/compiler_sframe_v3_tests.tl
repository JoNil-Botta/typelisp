;; Independent golden and mutation coverage for compiler_sframe_v3.tl.
(import compiler_owned_view as owned_view)
(import compiler_sframe_v3 as sframe)
(import stdlib.string)

;; Extracted from GNU as/objcopy 2.47, tag binutils-2_47 peeled commit
;; 6ce87bbc521cf46eaee9a1f7ef61cee2cdfb3e32.  The source and reproduction
;; recipe live in tests/fixtures/sframe-v3/.
(define (sframe-v3-test-binutils-basic) : (__tl_dyn-array u8)
  (__tl_make-array
    0xe2
    0xde
    0x03
    0x04
    0x03
    0x00
    0xf8
    0x00
    0x02
    0x00
    0x00
    0x00
    0x05
    0x00
    0x00
    0x00
    0x1c
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x20
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x02
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x00
    0x07
    0x00
    0x00
    0x00
    0x08
    0x00
    0x00
    0x00
    0x01
    0x00
    0x00
    0x00
    0x00
    0x00
    0x03
    0x08
    0x04
    0x00
    0x00
    0x00
    0x00
    0x00
    0x03
    0x08
    0x01
    0x05
    0x10
    0xf0
    0x04
    0x04
    0x10
    0xf0
    0x06
    0x05
    0x08
    0xf0))

(define (sframe-v3-test-copy [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
    [index : i64 0]
    (begin
      (while (< index (array-length bytes))
        (begin
          (set! (array-ref out index) (array-ref bytes index))
          (set! index (+ index 1))))
      out)))

(define (sframe-v3-test-bytes-eq?
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

(define (sframe-v3-test-write-i64!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (let
    [bits : u64 (cast value : u64)]
    [index : i64 0]
    (while (< index 8)
      (begin
        (set!
          (array-ref bytes (+ offset index))
          (cast (bit-and (shr bits (* index 8)) (cast 255 : u64)) : u8))
        (set! index (+ index 1))))))

;; This intentionally shares no production reader or constants.  It catches a
;; producer/consumer bug that could otherwise agree on the same wrong layout.
(define (sframe-v3-test-independent-binutils-oracle?
  [bytes : (& bytes (__tl_dyn-array u8))]) : bool
  (and
    (= (array-length bytes) 88)
    (=
      (+
        (cast (array-ref bytes 0) : i64)
        (shl (cast (array-ref bytes 1) : i64) 8))
      0xdee2)
    (= (array-ref bytes 2) (cast 3 : u8))
    (= (array-ref bytes 3) (cast 4 : u8))
    (= (array-ref bytes 4) (cast 3 : u8))
    (= (array-ref bytes 6) (cast 0xf8 : u8))
    (= (array-ref bytes 8) (cast 2 : u8))
    (= (array-ref bytes 12) (cast 5 : u8))
    (= (array-ref bytes 16) (cast 28 : u8))
    (= (array-ref bytes 24) (cast 32 : u8))
    (= (array-ref bytes 36) (cast 2 : u8))
    (= (array-ref bytes 52) (cast 7 : u8))
    (= (array-ref bytes 56) (cast 8 : u8))
    (= (array-ref bytes 60) (cast 1 : u8))
    (= (array-ref bytes 66) (cast 3 : u8))
    (= (array-ref bytes 68) (cast 4 : u8))
    (= (array-ref bytes 74) (cast 3 : u8))
    (= (array-ref bytes 87) (cast 0xf0 : u8))))

(define (sframe-v3-test-rejects-code?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [limits : (& limits sframe.CompilerSframeV3Limits)]
  [code : i64]) : bool
  (match (sframe.compiler-sframe-v3-decode bytes 0 limits)
    [(sframe.ResultCompilerSframeV3Image.Err error) (= error.code code)]
    [(sframe.ResultCompilerSframeV3Image.Ok _) false]))

(define (sframe-v3-test-rule-fixed?
  [rule : (& rule sframe.CompilerSframeV3Rule)]
  [expected : i64]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(sframe.CompilerSframeV3Rule.Fixed value) (= value expected)]
    [_ false]))

(define (sframe-v3-test-rule-unavailable?
  [rule : (& rule sframe.CompilerSframeV3Rule)]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(sframe.CompilerSframeV3Rule.Unavailable) true]
    [_ false]))

(define (sframe-v3-test-rule-implicit?
  [rule : (& rule sframe.CompilerSframeV3Rule)]
  [deref? : bool]
  [expected : i64]) : bool
  (match (owned_view.compiler-owned-reference-shared-view rule)
    [(sframe.CompilerSframeV3Rule.Implicit actual-deref? value)
      (and (= actual-deref? deref?) (= value expected))]
    [_ false]))

(define (sframe-v3-test-golden-round-trip?) : bool
  (let
    [golden : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (and
      (sframe-v3-test-independent-binutils-oracle? (& golden))
      (match (sframe.compiler-sframe-v3-decode (& golden) 0 (& limits))
        [(sframe.ResultCompilerSframeV3Image.Err _) false]
        [(sframe.ResultCompilerSframeV3Image.Ok image)
          (let
            [first : sframe.CompilerSframeV3Function
              (owned_view.compiler-owned-array-element-shared-view
                image.functions
                0)]
            [second : sframe.CompilerSframeV3Function
              (owned_view.compiler-owned-array-element-shared-view
                image.functions
                1)]
            [first-row : sframe.CompilerSframeV3Row
              (owned_view.compiler-owned-array-element-shared-view
                image.rows
                first.row-start)]
            [second-row : sframe.CompilerSframeV3Row
              (owned_view.compiler-owned-array-element-shared-view
                image.rows
                (+ second.row-start 1))]
            (and
              (= image.fixed-fp-offset 0)
              (= image.fixed-ra-offset -8)
              (not image.sorted?)
              image.decoded-field-pcrel?
              (= (array-length image.functions) 2)
              (= first.index-byte-offset 28)
              (= first.raw-start-addend 0)
              (= first.start-address 28)
              (= second.index-byte-offset 44)
              (= second.start-address 44)
              (= second.row-count 4)
              (= first-row.cfa-register sframe.compiler-sframe-v3-dwarf-rsp)
              (= first-row.cfa-offset 8)
              (sframe-v3-test-rule-fixed? (& first-row.ra-rule) -8)
              (sframe-v3-test-rule-unavailable? (& first-row.fp-rule))
              (= second-row.start-offset 1)
              (= second-row.cfa-offset 16)
              (sframe-v3-test-rule-implicit? (& second-row.fp-rule) true -16)
              (match (sframe.compiler-sframe-v3-encode (& image) 0 (& limits))
                [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
                [(sframe.ResultCompilerSframeV3Bytes.Ok encoded)
                  (sframe-v3-test-bytes-eq? (& golden) (& encoded))])))]))))

(define (sframe-v3-test-linked-golden-round-trip?) : bool
  (let
    [golden : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    [linked : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (begin
      ;; GNU ld 2.47 places .sframe at 0x402000 and these functions at
      ;; 0x401000/0x401002, then writes field-PC-relative signed addends.
      (set! (array-ref linked 3) (cast 5 : u8))
      (sframe-v3-test-write-i64! (&mut linked) 28 -4124)
      (sframe-v3-test-write-i64! (&mut linked) 44 -4138)
      (match (sframe.compiler-sframe-v3-decode (& linked) 0x402000 (& limits))
        [(sframe.ResultCompilerSframeV3Image.Err _) false]
        [(sframe.ResultCompilerSframeV3Image.Ok image)
          (let
            [first : sframe.CompilerSframeV3Function
              (owned_view.compiler-owned-array-element-shared-view
                image.functions
                0)]
            [second : sframe.CompilerSframeV3Function
              (owned_view.compiler-owned-array-element-shared-view
                image.functions
                1)]
            (and
              image.sorted?
              (= first.start-address 0x401000)
              (= first.index-byte-offset 28)
              (= first.raw-start-addend -4124)
              (= second.start-address 0x401002)
              (= second.index-byte-offset 44)
              (= second.raw-start-addend -4138)
              (match (sframe.compiler-sframe-v3-encode
                (& image)
                0x402000
                (& limits))
                [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
                [(sframe.ResultCompilerSframeV3Bytes.Ok encoded)
                  (sframe-v3-test-bytes-eq? (& linked) (& encoded))])))]))))

(define (sframe-v3-test-section-relative-normalization?) : bool
  (let
    [bytes : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (begin
      (set! (array-ref bytes 3) (cast 0 : u8))
      (sframe-v3-test-write-i64! (&mut bytes) 28 72)
      (sframe-v3-test-write-i64! (&mut bytes) 44 172)
      (match (sframe.compiler-sframe-v3-decode (& bytes) 1000 (& limits))
        [(sframe.ResultCompilerSframeV3Image.Err _) false]
        [(sframe.ResultCompilerSframeV3Image.Ok image)
          (let
            [first : sframe.CompilerSframeV3Function
              (owned_view.compiler-owned-array-element-shared-view
                image.functions
                0)]
            [second : sframe.CompilerSframeV3Function
              (owned_view.compiler-owned-array-element-shared-view
                image.functions
                1)]
            (and
              (not image.decoded-field-pcrel?)
              (= first.start-address 1100)
              (= second.start-address 1200)
              (match (sframe.compiler-sframe-v3-encode
                (& image)
                1000
                (& limits))
                [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
                [(sframe.ResultCompilerSframeV3Bytes.Ok canonical)
                  (and
                    (= (array-ref canonical 3) (cast 4 : u8))
                    (match (sframe.compiler-sframe-v3-decode
                      (& canonical)
                      1000
                      (& limits))
                      [(sframe.ResultCompilerSframeV3Image.Err _) false]
                      [(sframe.ResultCompilerSframeV3Image.Ok normalized)
                        (let
                          [normalized-second : sframe.CompilerSframeV3Function
                            (owned_view.compiler-owned-array-element-shared-view
                              normalized.functions
                              1)]
                          (and
                            normalized.decoded-field-pcrel?
                            (= normalized-second.start-address 1200)
                            (= normalized-second.raw-start-addend 156)))]))])))]))))

(define (sframe-v3-test-mask-image) : sframe.CompilerSframeV3Image
  (let
    [rows : (__tl_dyn-array sframe.CompilerSframeV3Row)
      (__tl_make-array
        (sframe.CompilerSframeV3Row
          0
          false
          sframe.compiler-sframe-v3-dwarf-rsp
          false
          8
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Unavailable))
        (sframe.CompilerSframeV3Row
          2
          false
          sframe.compiler-sframe-v3-dwarf-rsp
          false
          16
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Unavailable))
        (sframe.CompilerSframeV3Row
          5
          false
          sframe.compiler-sframe-v3-dwarf-rbp
          false
          16
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Implicit true -16)))]
    [functions : (__tl_dyn-array sframe.CompilerSframeV3Function)
      (__tl_make-array
        (sframe.CompilerSframeV3Function 101 18 true 6 false false 0 0 0 3))]
    (sframe.CompilerSframeV3Image 0 -8 false false functions rows)))

(define (sframe-v3-test-mask-lookup?) : bool
  (let
    [image : sframe.CompilerSframeV3Image (sframe-v3-test-mask-image)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    [function : sframe.CompilerSframeV3Function
      (owned_view.compiler-owned-array-element-shared-view image.functions 0)]
    (and
      (match (sframe.compiler-sframe-v3-row-index-for-pc
        (& function)
        (& image.rows)
        109)
        [(sframe.ResultCompilerSframeV3RowIndex.Ok index) (= index 1)]
        [(sframe.ResultCompilerSframeV3RowIndex.Err _) false])
      (match (sframe.compiler-sframe-v3-row-index-for-pc
        (& function)
        (& image.rows)
        112)
        [(sframe.ResultCompilerSframeV3RowIndex.Ok index) (= index 2)]
        [(sframe.ResultCompilerSframeV3RowIndex.Err _) false])
      (match (sframe.compiler-sframe-v3-encode (& image) 40 (& limits))
        [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
        [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
          (match (sframe.compiler-sframe-v3-decode (& bytes) 40 (& limits))
            [(sframe.ResultCompilerSframeV3Image.Err _) false]
            [(sframe.ResultCompilerSframeV3Image.Ok decoded)
              (let
                [decoded-function : sframe.CompilerSframeV3Function
                  (owned_view.compiler-owned-array-element-shared-view
                    decoded.functions
                    0)]
                (and
                  decoded-function.mask-pc?
                  (= decoded-function.repetition-size 6)
                  (match (sframe.compiler-sframe-v3-row-index-for-pc
                    (& decoded-function)
                    (& decoded.rows)
                    109)
                    [(sframe.ResultCompilerSframeV3RowIndex.Ok index)
                      (= index 1)]
                    [(sframe.ResultCompilerSframeV3RowIndex.Err _) false])))])]))))

(define (sframe-v3-test-flex-image) : sframe.CompilerSframeV3Image
  (let
    [rows : (__tl_dyn-array sframe.CompilerSframeV3Row)
      (__tl_make-array
        (sframe.CompilerSframeV3Row
          0
          false
          12
          false
          300
          (sframe.CompilerSframeV3Rule.Register 16 false 0)
          (sframe.CompilerSframeV3Rule.Implicit true -40000))
        (sframe.CompilerSframeV3Row
          65000
          false
          7
          false
          8
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Implicit true -16)))]
    [functions : (__tl_dyn-array sframe.CompilerSframeV3Function)
      (__tl_make-array
        (sframe.CompilerSframeV3Function 900000 70000 false 0 true true 0 0 0 2))]
    (sframe.CompilerSframeV3Image 0 -8 true false functions rows)))

(define (sframe-v3-test-flex-widths-and-round-trip?) : bool
  (let
    [image : sframe.CompilerSframeV3Image (sframe-v3-test-flex-image)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-plan (& image) (& limits))
      [(sframe.ResultCompilerSframeV3Plan.Err _) false]
      [(sframe.ResultCompilerSframeV3Plan.Ok plan)
        (match (sframe.compiler-sframe-v3-encode (& image) 500000 (& limits))
          [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
          [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
            ;; 28-byte header + 16-byte index; attr info selects 4-byte starts
            ;; and signal, first row info selects six 4-byte data words.
            (if (and
              (= (array-length bytes) plan.total-bytes)
              (= (array-ref bytes 46) (cast 0x82 : u8))
              (= (array-ref bytes 47) (cast 1 : u8))
              (= (array-ref bytes 53) (cast 76 : u8)))
              (match (sframe.compiler-sframe-v3-decode
                (& bytes)
                500000
                (& limits))
                [(sframe.ResultCompilerSframeV3Image.Err _) false]
                [(sframe.ResultCompilerSframeV3Image.Ok decoded)
                  (let
                    [function : sframe.CompilerSframeV3Function
                      (owned_view.compiler-owned-array-element-shared-view
                        decoded.functions
                        0)]
                    [first : sframe.CompilerSframeV3Row
                      (owned_view.compiler-owned-array-element-shared-view
                        decoded.rows
                        function.row-start)]
                    (if (and
                      function.flex?
                      function.signal-frame?
                      (= first.cfa-register 12))
                      (match (owned_view.compiler-owned-reference-shared-view
                        (& first.ra-rule))
                        [(sframe.CompilerSframeV3Rule.Register
                            register
                            deref?
                            offset)
                          (and (= register 16) (not deref?) (= offset 0))]
                        [_ false])
                      false))])
              false)])])))

(define (sframe-v3-test-outermost-marker?) : bool
  (let
    [rows : (__tl_dyn-array sframe.CompilerSframeV3Row)
      (__tl_make-array
        (sframe.CompilerSframeV3Row
          0
          false
          sframe.compiler-sframe-v3-dwarf-rsp
          false
          8
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Unavailable))
        (sframe.CompilerSframeV3Row
          5
          true
          0
          false
          0
          (sframe.CompilerSframeV3Rule.Unavailable)
          (sframe.CompilerSframeV3Rule.Unavailable)))]
    [functions : (__tl_dyn-array sframe.CompilerSframeV3Function)
      (__tl_make-array
        (sframe.CompilerSframeV3Function 100 10 false 0 false false 0 0 0 2))]
    [image : sframe.CompilerSframeV3Image
      (sframe.CompilerSframeV3Image 0 -8 false false functions rows)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-encode (& image) 0 (& limits))
      [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
      [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
        (match (sframe.compiler-sframe-v3-decode (& bytes) 0 (& limits))
          [(sframe.ResultCompilerSframeV3Image.Err _) false]
          [(sframe.ResultCompilerSframeV3Image.Ok decoded)
            (let
              [function : sframe.CompilerSframeV3Function
                (owned_view.compiler-owned-array-element-shared-view
                  decoded.functions
                  0)]
              [row : sframe.CompilerSframeV3Row
                (owned_view.compiler-owned-array-element-shared-view
                  decoded.rows
                  (+ function.row-start 1))]
              row.outermost?)])])))

(define (sframe-v3-test-zero-fre-outermost?) : bool
  (let
    [rows : (__tl_dyn-array sframe.CompilerSframeV3Row)
      (__tl_make-array sframe.CompilerSframeV3Row 0)]
    [functions : (__tl_dyn-array sframe.CompilerSframeV3Function)
      (__tl_make-array
        (sframe.CompilerSframeV3Function 400 10 false 0 false false 0 0 0 0))]
    [image : sframe.CompilerSframeV3Image
      (sframe.CompilerSframeV3Image 0 -8 false false functions rows)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-encode (& image) 100 (& limits))
      [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
      [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
        (match (sframe.compiler-sframe-v3-decode (& bytes) 100 (& limits))
          [(sframe.ResultCompilerSframeV3Image.Err _) false]
          [(sframe.ResultCompilerSframeV3Image.Ok decoded)
            (let
              [function : sframe.CompilerSframeV3Function
                (owned_view.compiler-owned-array-element-shared-view
                  decoded.functions
                  0)]
              (and
                (= (array-length bytes) 49)
                (= function.row-count 0)
                (= (array-length decoded.rows) 0)
                (= function.start-address 400)))])])))

(define (sframe-v3-test-two-byte-widths?) : bool
  (let
    [rows : (__tl_dyn-array sframe.CompilerSframeV3Row)
      (__tl_make-array
        (sframe.CompilerSframeV3Row
          0
          false
          sframe.compiler-sframe-v3-dwarf-rsp
          false
          8
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Unavailable))
        (sframe.CompilerSframeV3Row
          256
          false
          sframe.compiler-sframe-v3-dwarf-rsp
          false
          200
          (sframe.CompilerSframeV3Rule.Fixed -8)
          (sframe.CompilerSframeV3Rule.Unavailable)))]
    [functions : (__tl_dyn-array sframe.CompilerSframeV3Function)
      (__tl_make-array
        (sframe.CompilerSframeV3Function 1000 300 false 0 false false 0 0 0 2))]
    [image : sframe.CompilerSframeV3Image
      (sframe.CompilerSframeV3Image 0 -8 false false functions rows)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-encode (& image) 0 (& limits))
      [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
      [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
        ;; FRE type one selects 2-byte row starts.  The second row independently
        ;; selects 2-byte signed data while the first stays at one byte.
        (and
          (= (array-ref bytes 46) (cast 1 : u8))
          (= (array-ref bytes 53) (cast 0 : u8))
          (= (array-ref bytes 54) (cast 1 : u8))
          (= (array-ref bytes 55) (cast 35 : u8))
          (match (sframe.compiler-sframe-v3-decode (& bytes) 0 (& limits))
            [(sframe.ResultCompilerSframeV3Image.Err _) false]
            [(sframe.ResultCompilerSframeV3Image.Ok decoded)
              (let
                [function : sframe.CompilerSframeV3Function
                  (owned_view.compiler-owned-array-element-shared-view
                    decoded.functions
                    0)]
                [row : sframe.CompilerSframeV3Row
                  (owned_view.compiler-owned-array-element-shared-view
                    decoded.rows
                    (+ function.row-start 1))]
                (and (= row.start-offset 256) (= row.cfa-offset 200)))]))])))

(define (sframe-v3-test-mutations-and-limits?) : bool
  (let
    [golden : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    [flags : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [aux : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [attr : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [row : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [row-order : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [tiling : (__tl_dyn-array u8) (sframe-v3-test-copy (& golden))]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (begin
      (set! (array-ref flags 3) (cast 6 : u8))
      (set! (array-ref aux 7) (cast 1 : u8))
      (set! (array-ref attr 62) (cast 3 : u8))
      (set! (array-ref row 66) (cast 0x83 : u8))
      (set! (array-ref row-order 76) (cast 0 : u8))
      (set! (array-ref tiling 56) (cast 7 : u8))
      (and
        (sframe-v3-test-rejects-code?
          (& flags)
          (& limits)
          sframe.compiler-sframe-v3-error-preamble)
        (sframe-v3-test-rejects-code?
          (& aux)
          (& limits)
          sframe.compiler-sframe-v3-error-preamble)
        (sframe-v3-test-rejects-code?
          (& attr)
          (& limits)
          sframe.compiler-sframe-v3-error-attribute)
        (sframe-v3-test-rejects-code?
          (& row)
          (& limits)
          sframe.compiler-sframe-v3-error-row)
        (sframe-v3-test-rejects-code?
          (& tiling)
          (& limits)
          sframe.compiler-sframe-v3-error-layout)
        (sframe-v3-test-rejects-code?
          (& row-order)
          (& limits)
          sframe.compiler-sframe-v3-error-row)
        (let
          [input-limit : sframe.CompilerSframeV3Limits
            (sframe.CompilerSframeV3Limits 87 1000 10 10 10000 1000)]
          [function-limit : sframe.CompilerSframeV3Limits
            (sframe.CompilerSframeV3Limits 1000 1000 1 10 10000 1000)]
          [row-limit : sframe.CompilerSframeV3Limits
            (sframe.CompilerSframeV3Limits 1000 1000 10 4 10000 1000)]
          [allocation-limit : sframe.CompilerSframeV3Limits
            (sframe.CompilerSframeV3Limits 1000 1000 10 10 1 1000)]
          [work-limit : sframe.CompilerSframeV3Limits
            (sframe.CompilerSframeV3Limits 1000 1000 10 10 10000 1)]
          (and
            (sframe-v3-test-rejects-code?
              (& golden)
              (& input-limit)
              sframe.compiler-sframe-v3-error-input-limit)
            (sframe-v3-test-rejects-code?
              (& golden)
              (& function-limit)
              sframe.compiler-sframe-v3-error-function-limit)
            (sframe-v3-test-rejects-code?
              (& golden)
              (& row-limit)
              sframe.compiler-sframe-v3-error-row-limit)
            (sframe-v3-test-rejects-code?
              (& golden)
              (& allocation-limit)
              sframe.compiler-sframe-v3-error-allocation-limit)
            (sframe-v3-test-rejects-code?
              (& golden)
              (& work-limit)
              sframe.compiler-sframe-v3-error-work-limit)))))))

(define (sframe-v3-test-reserved-flex-control?) : bool
  (let
    [image : sframe.CompilerSframeV3Image (sframe-v3-test-flex-image)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-encode (& image) 500000 (& limits))
      [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
      [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
        (begin
          ;; First FLEX control begins at 54; set reserved bit two.
          (set!
            (array-ref bytes 54)
            (cast (bit-or (cast (array-ref bytes 54) : i64) 4) : u8))
          (sframe-v3-test-rejects-code?
            (& bytes)
            (& limits)
            sframe.compiler-sframe-v3-error-row))])))

(define (sframe-v3-test-zero-flex-control?) : bool
  (let
    [image : sframe.CompilerSframeV3Image (sframe-v3-test-flex-image)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-encode (& image) 500000 (& limits))
      [(sframe.ResultCompilerSframeV3Bytes.Err _) false]
      [(sframe.ResultCompilerSframeV3Bytes.Ok bytes)
        (begin
          ;; A zero control is an omitted/padding word, never a CFA rule.
          (set! (array-ref bytes 54) (cast 0 : u8))
          (sframe-v3-test-rejects-code?
            (& bytes)
            (& limits)
            sframe.compiler-sframe-v3-error-row))])))

(define (sframe-v3-test-explicit-policy?) : bool
  (let
    [golden : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    [image : sframe.CompilerSframeV3Image (sframe-v3-test-mask-image)]
    [supported : sframe.CompilerSframeV3Policy
      (sframe.compiler-sframe-v3-policy)]
    [unsupported : sframe.CompilerSframeV3Policy
      (sframe.CompilerSframeV3Policy 2)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (and
      (match (sframe.compiler-sframe-v3-decode-with-policy
        (& golden)
        0
        (& supported)
        (& limits))
        [(sframe.ResultCompilerSframeV3Image.Ok _) true]
        [(sframe.ResultCompilerSframeV3Image.Err _) false])
      (match (sframe.compiler-sframe-v3-decode-with-policy
        (& golden)
        0
        (& unsupported)
        (& limits))
        [(sframe.ResultCompilerSframeV3Image.Err error)
          (= error.code sframe.compiler-sframe-v3-error-dialect)]
        [(sframe.ResultCompilerSframeV3Image.Ok _) false])
      (match (sframe.compiler-sframe-v3-plan-with-policy
        (& image)
        (& supported)
        (& limits))
        [(sframe.ResultCompilerSframeV3Plan.Ok _) true]
        [(sframe.ResultCompilerSframeV3Plan.Err _) false])
      (match (sframe.compiler-sframe-v3-encode-with-policy
        (& image)
        40
        (& supported)
        (& limits))
        [(sframe.ResultCompilerSframeV3Bytes.Ok _) true]
        [(sframe.ResultCompilerSframeV3Bytes.Err _) false]))))

(test
  compiler-sframe-v3-dialect-pin
  (if (string.eq
    (sframe.compiler-sframe-v3-dialect)
    "gnu-sframe-v3-binutils-2.47-amd64-le-v1")
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-independent-binutils-oracle
  (let
    [golden : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    (if (sframe-v3-test-independent-binutils-oracle? (& golden))
      unit
      (string.tl_oob_abort))))

(test
  compiler-sframe-v3-accept-binutils-golden
  (let
    [golden : (__tl_dyn-array u8) (sframe-v3-test-binutils-basic)]
    [limits : sframe.CompilerSframeV3Limits
      (sframe.compiler-sframe-v3-default-limits)]
    (match (sframe.compiler-sframe-v3-decode (& golden) 0 (& limits))
      [(sframe.ResultCompilerSframeV3Image.Ok _) unit]
      [(sframe.ResultCompilerSframeV3Image.Err _) (string.tl_oob_abort)])))

(test
  compiler-sframe-v3-binutils-golden-round-trip
  (if (sframe-v3-test-golden-round-trip?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-binutils-linked-golden-round-trip
  (if (sframe-v3-test-linked-golden-round-trip?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-section-relative-normalization
  (if (sframe-v3-test-section-relative-normalization?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-mask-relocated-non-power-of-two
  (if (sframe-v3-test-mask-lookup?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-flex-widths-round-trip
  (if (sframe-v3-test-flex-widths-and-round-trip?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-default-outermost-marker
  (if (sframe-v3-test-outermost-marker?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-default-zero-fre-outermost
  (if (sframe-v3-test-zero-fre-outermost?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-minimal-two-byte-widths
  (if (sframe-v3-test-two-byte-widths?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-mutations-and-limits
  (if (sframe-v3-test-mutations-and-limits?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-reject-reserved-flex-control
  (if (sframe-v3-test-reserved-flex-control?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-reject-zero-flex-control
  (if (sframe-v3-test-zero-flex-control?)
    unit
    (string.tl_oob_abort)))

(test
  compiler-sframe-v3-explicit-dialect-policy
  (if (sframe-v3-test-explicit-policy?)
    unit
    (string.tl_oob_abort)))