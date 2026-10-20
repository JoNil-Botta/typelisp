(import linker_coff_import_reader as coff)
(import linker_coff_import_reader_test_dump as dump)
(import linker_coff_import_member_writer as imports)
(import linker_archive_core as archive)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as bytes)
(import stdlib.byte_le as le)
(import stdlib.iterator)
(import stdlib.test)

(include-bin llvm-support "tests/fixtures/coff_import_amd64/example-0.bin")

(include-bin llvm-code "tests/fixtures/coff_import_amd64/example-3.bin")

(include-bin llvm-data "tests/fixtures/coff_import_amd64/example-4.bin")

(include-bin llvm-const "tests/fixtures/coff_import_amd64/example-5.bin")

(include-bin llvm-ordinal "tests/fixtures/coff_import_amd64/example-6.bin")

(include-bin llvm-decorated "tests/fixtures/coff_import_amd64/aliases-5.bin")

(include-bin
  sdk-exclusive
  "tests/fixtures/coff_import_amd64/sdk-acquire-exclusive.bin")

(include-bin
  sdk-shared
  "tests/fixtures/coff_import_amd64/sdk-acquire-shared.bin")

(define (member) : archive.ArchiveMemberId
  (archive.ArchiveMemberId (archive.ArchiveIdentity 17 23) 4 608))

(define (copy-prefix [data : (& d (__tl_dyn-array u8))] [size : i64]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 size)]
    (for [i
      (iterator.range
        0
        (if (< size (array-length data))
          size
          (array-length data)))]
      (set! (array-ref out i) (array-ref data i)))
    out))

(define (short-bytes
  [public : String]
  [dll : String]
  [kind : i64]
  [mode : i64]
  [value : i64]) : (__tl_dyn-array u8)
  (let
    [encoded : String
      (imports.coff-import-short
        dll
        (imports.CoffImportPlan public "" value value kind mode))]
    (byte_buf.to-array (byte_buf.from-string encoded))))

(define (sample) : (__tl_dyn-array u8)
  (short-bytes "Func" "example.dll" 0 1 0))

(define (read [data : (& d (__tl_dyn-array u8))]) : coff.CoffImportReadResult
  (let
    [limits : coff.CoffImportReadLimits (coff.default-limits)]
    (coff.read data (member) (& limits))))

(define (expect-error
  [data : (& d (__tl_dyn-array u8))]
  [limits : (& l coff.CoffImportReadLimits)]
  [kind : String]
  [offset : i64]) : unit
  (match (coff.read data (member) limits)
    [(ReadFailed error)
      (test.assert-string-eq
        (dump.error-name (& error.kind))
        kind
        "failure class")
      (test.assert-i64-eq error.offset offset "failure byte")
      (test.assert-i64-eq error.member.ordinal 4 "physical member")
      (test.assert-true (= error.member.archive.content 23) "content identity")]
    [_ (test.assert-true false "malformed member accepted")]))

(define (check-record
  [data : (& d (__tl_dyn-array u8))]
  [public : String]
  [dll : String]
  [name : String]
  [kind : i64]
  [mode : i64]
  [ordinal : i64]
  [hint : i64]) : unit
  (match (read data)
    [(ShortImport record)
      (test.assert-string-eq record.plan.public-name public "public spelling")
      (test.assert-string-eq record.dll-key dll "DLL identity")
      (test.assert-string-eq record.plan.import-name name "import name")
      (test.assert-string-eq
        record.iat-symbol
        (imports.coff-import-symbol (clone record.plan) 1)
        "literal IAT symbol")
      (test.assert-i64-eq record.plan.kind kind "code/data/const")
      (test.assert-i64-eq record.plan.name-mode mode "name mode")
      (test.assert-i64-eq record.plan.ordinal ordinal "ordinal")
      (test.assert-i64-eq record.plan.hint hint "hint")
      (let
        [encoded : (__tl_dyn-array u8)
          (byte_buf.to-array
            (byte_buf.from-string
              (imports.coff-import-short
                (clone record.dll-spelling)
                (clone record.plan))))]
        (le.set-u32! (&mut encoded) 8 record.timestamp)
        (test.assert-i64-eq
          (array-length encoded)
          (array-length data)
          "round-trip size")
        (for [i (iterator.range 0 (array-length data))]
          (test.assert-i64-eq
            (le.byte-le-at (& encoded) i)
            (le.byte-le-at data i)
            "round-trip byte")))]
    [_ (test.assert-true false "valid import rejected")]))

(defenum NameCase
  (Name String i64 String))

(define (valid-tests) : unit
  (check-record (& llvm-code) "Func" "example.dll" "Func" 0 1 0 0)
  (check-record (& llvm-data) "Data" "example.dll" "Data" 1 1 0 0)
  (check-record (& llvm-const) "Const" "example.dll" "Const" 2 1 0 0)
  (check-record (& llvm-ordinal) "Ord" "example.dll" "" 0 0 7 0)
  (check-record
    (& llvm-decorated)
    "_Decorated@8"
    "example.dll"
    "_Decorated@8"
    0
    1
    0
    0)
  (check-record
    (& sdk-exclusive)
    "AcquireSRWLockExclusive"
    "kernel32.dll"
    "AcquireSRWLockExclusive"
    0
    1
    0
    0)
  (check-record
    (& sdk-shared)
    "AcquireSRWLockShared"
    "kernel32.dll"
    "AcquireSRWLockShared"
    0
    1
    0
    1)
  (test.assert-string-eq
    (dump.dump (& (read (& llvm-support))) true)
    "COFF\n"
    "ordinary COFF")
  (let
    [cases : (Array NameCase 15)
      (array
        (Name "Func" 1 "Func")
        (Name "_Foo@8" 1 "_Foo@8")
        (Name "?Foo@@YAXXZ" 1 "?Foo@@YAXXZ")
        (Name "__imp_Foo" 1 "__imp_Foo")
        (Name "Func" 2 "Func")
        (Name "?Foo" 2 "Foo")
        (Name "@Foo@8" 2 "Foo@8")
        (Name "_Foo@8" 2 "Foo@8")
        (Name "??Foo" 2 "?Foo")
        (Name "__imp_Foo" 2 "_imp_Foo")
        (Name "__imp_Foo" 3 "_imp_Foo")
        (Name "Func@8" 3 "Func")
        (Name "?Foo@@YAXXZ" 3 "Foo")
        (Name "@Foo@8" 3 "Foo")
        (Name "_Foo@8" 3 "Foo"))]
    (for [kind (iterator.range 0 3)]
      (for [case (clone cases)]
        (match case
          [(Name public mode name)
            (let
              [data (short-bytes (clone public) "EXample.DLL" kind mode 65535)]
              (check-record
                (& data)
                public
                "example.dll"
                name
                kind
                mode
                0
                65535))]))
      (for [ordinal (array (cast 1 : i64) 65535)]
        (let
          [data (short-bytes "ByOrdinal" "example.dll" kind 0 ordinal)]
          (check-record (& data) "ByOrdinal" "example.dll" "" kind 0 ordinal 0))))))

(defenum Mutation
  (Word i64 i64 String i64)
  (Dword i64 i64 String i64))

(define (truncation-tests [base : (& b (__tl_dyn-array u8))]) : unit
  (let
    [limits (coff.default-limits)]
    [n (array-length base)]
    (for [size (iterator.range 0 n)]
      (let
        [data (copy-prefix base size)]
        (test.assert-true
          (match (read (& data))
            [(ReadFailed _) true]
            [_ false])
          "truncated member")
        (when
          (>= size 20)
          (le.set-u32! (&mut data) 12 (- size 20))
          (expect-error (& data) (& limits) "unterminated-string" size))))))

(define (malformed-tests) : unit
  (let
    [base (sample)]
    [limits (coff.default-limits)]
    [n (array-length base)]
    [cases : (Array Mutation 13)
      (array
        (Word 0 0x14c "unsupported-machine" 0)
        (Word 2 0 "malformed-header" 2)
        (Word 4 1 "unsupported-version" 4)
        (Word 4 65535 "unsupported-version" 4)
        (Word 6 0x14c "unsupported-machine" 6)
        (Word 18 7 "unsupported-kind" 18)
        (Word 18 36 "reserved-bits" 18)
        (Word 18 20 "unsupported-name-mode" 18)
        (Word 18 28 "unsupported-name-mode" 18)
        (Word
          18
          16
          "unsupported IMPORT_NAME_EXPORTAS (supported NameType: 0..3)"
          18)
        (Dword 12 0 "size-mismatch" 12)
        (Dword 12 0xffffffff "size-mismatch" 12)
        (Word 18 0 "zero-ordinal" 16))]
    (truncation-tests (& llvm-code))
    (truncation-tests (& llvm-data))
    (truncation-tests (& llvm-const))
    (truncation-tests (& llvm-ordinal))
    (truncation-tests (& llvm-decorated))
    (truncation-tests (& sdk-exclusive))
    (truncation-tests (& sdk-shared))
    (for [case cases]
      (let
        [data (copy-prefix (& base) n)]
        (match case
          [(Word offset value kind at)
            (le.set-u16! (&mut data) offset value)
            (expect-error (& data) (& limits) kind at)]
          [(Dword offset value kind at)
            (le.set-u32! (&mut data) offset value)
            (expect-error (& data) (& limits) kind at)])))
    (let
      [data (copy-prefix (& base) (+ n 1))]
      (le.set-u32! (&mut data) 12 (- (+ n 1) 20))
      (expect-error (& data) (& limits) "trailing-data" n))
    (for [mode (array (cast 2 : i64) 3)]
      (for [name (array "?" "@" "_")]
        (let
          [data (short-bytes name "example.dll" 0 mode 0)]
          (expect-error (& data) (& limits) "invalid-name" 20))))
    (for [name
      (array "" "." ".." "foo." ".foo" "a/b.dll" "C:foo" "a\\b.dll" "a?b.dll")]
      (let
        [data (short-bytes "Func" name 0 1 0)]
        (expect-error (& data) (& limits) "invalid-name" 25)))
    (for [value (array (cast 1 : i64) 32 47 92 127 192 255)]
      (let
        [data (copy-prefix (& base) n)]
        (set! (array-ref data 20) (cast value : u8))
        (expect-error (& data) (& limits) "invalid-name" 20)))))

(define (bigobj) : (__tl_dyn-array u8)
  (let
    [data : (__tl_dyn-array u8) (__tl_make-array u8 56)]
    [magic : (Array u8 16)
      (array
        0xc7
        0xa1
        0xba
        0xd1
        0xee
        0xba
        0xa9
        0x4b
        0xaf
        0x20
        0xfa
        0xf6
        0x6a
        0xa4
        0xdc
        0xb8)]
    (le.set-u16! (&mut data) 2 65535)
    (le.set-u16! (&mut data) 4 2)
    (le.set-u16! (&mut data) 6 0x8664)
    (for [i (iterator.range 0 16)]
      (set! (array-ref data (+ 12 i)) (array-ref magic i)))
    data))

(define (classification-tests) : unit
  (let
    [base (bigobj)]
    [limits (coff.default-limits)]
    (test.assert-string-eq
      (dump.dump (& (read (& base))) true)
      "BIGOBJ\n"
      "complete bigobj header")
    (for [size (iterator.range 0 56)]
      (let
        [data (copy-prefix (& base) size)]
        (test.assert-true
          (match (read (& data))
            [(ReadFailed _) true]
            [_ false])
          "short bigobj prefix rejected")))
    (for [i (iterator.range 12 28)]
      (let
        [data (copy-prefix (& base) 56)]
        (set! (array-ref data i) (bit-xor (array-ref data i) (cast 1 : u8)))
        (expect-error (& data) (& limits) "malformed-header" i)))
    (for [offset (array (cast 28 : i64) 32 36 40)]
      (let
        [data (copy-prefix (& base) 56)]
        (le.set-u32! (&mut data) offset 0xffffffff)
        (test.assert-string-eq
          (dump.dump (& (read (& data))) true)
          "BIGOBJ\n"
          "unused bigobj words are not import fields")))
    (for [offset (array (cast 44 : i64) 48 52)]
      (let
        [data (copy-prefix (& base) 56)]
        (le.set-u32! (&mut data) offset 0xffffffff)
        (expect-error (& data) (& limits) "malformed-header" 44)))))

(define (limit-tests) : unit
  (let
    [data (sample)]
    [limits (coff.default-limits)]
    [n (array-length data)]
    (set! limits.max-input-bytes n)
    (set! limits.max-name-bytes 11)
    (set! limits.max-output-bytes 40)
    (set! limits.max-work (+ 64 (* 16 n)))
    (test.assert-true
      (match (coff.read (& data) (member) (& limits))
        [(ShortImport _) true]
        [_ false])
      "exact bounds")
    (set! limits.max-input-bytes (- n 1))
    (expect-error (& data) (& limits) "input-limit" 0)
    (set! limits.max-input-bytes n)
    (set! limits.max-name-bytes 10)
    (expect-error (& data) (& limits) "name-limit" 25)
    (set! limits.max-name-bytes 9)
    (expect-error (& data) (& limits) "name-limit" 20)
    (set! limits.max-name-bytes 11)
    (set! limits.max-output-bytes 39)
    (expect-error (& data) (& limits) "output-limit" 20)
    (set! limits.max-output-bytes 40)
    (set! limits.max-work (- (+ 64 (* 16 n)) 1))
    (expect-error (& data) (& limits) "work-limit" 0)
    (set! limits.max-work (+ 64 (* 16 n)))
    (set! limits.max-name-bytes -1)
    (expect-error (& data) (& limits) "invalid-limits" 0)))

(define (long-name [size : i64] [value : i64]) : String
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-with-capacity size)]
    (for [_ (iterator.range 0 size)]
      (bytes.byte-buf-builder-push (&mut out) (cast value : u8)))
    (bytes.byte-buf-builder-to-string (& out))))

(define (extra-boundary-tests) : unit
  (let
    [base (sample)]
    [limits (coff.default-limits)]
    [n (array-length base)]
    (for [bit (iterator.range 5 16)]
      (let
        [data (copy-prefix (& base) n)]
        (le.set-u16! (&mut data) 18 (bit-or 4 (shl 1 bit)))
        (expect-error (& data) (& limits) "reserved-bits" 18)))
    (let
      [data (copy-prefix (& base) n)]
      (le.set-u16! (&mut data) 18 24)
      (expect-error (& data) (& limits) "unsupported-name-mode" 18)
      (le.set-u16! (&mut data) 18 4)
      (le.set-u16! (&mut data) 4 2)
      (expect-error (& data) (& limits) "malformed-header" n))
    (let
      [data (short-bytes "" "example.dll" 0 1 0)]
      (expect-error (& data) (& limits) "invalid-name" 20))
    (for [name (array "@@Func" "_@Func" "?@Func")]
      (let
        [data (short-bytes name "example.dll" 0 3 0)]
        (expect-error (& data) (& limits) "invalid-name" 20)))
    (let
      [data (copy-prefix (& base) n)]
      (set! (array-ref data 22) 0)
      (expect-error (& data) (& limits) "trailing-data" 25))
    (let
      [data (copy-prefix (& base) n)]
      (set! (array-ref data 25) 195)
      (set! (array-ref data 26) 169)
      (expect-error (& data) (& limits) "invalid-name" 25))
    (for [field (iterator.range 0 4)]
      (for [value
        (array
          (cast -1 : i64)
          (array-ref (array (cast 16777217 : i64) 4097 1048577 268435521) field))]
        (let
          [bad : coff.CoffImportReadLimits
            (coff.CoffImportReadLimits
              (if (= field 0)
                value
                16777216)
              (if (= field 1)
                value
                4096)
              (if (= field 2)
                value
                32768)
              (if (= field 3)
                value
                268435520))]
          (expect-error (& base) (& bad) "invalid-limits" 0))))
    (for [field (iterator.range 0 4)]
      (let
        [zero : coff.CoffImportReadLimits
          (coff.CoffImportReadLimits
            (if (= field 0)
              0
              16777216)
            (if (= field 1)
              0
              4096)
            (if (= field 2)
              0
              32768)
            (if (= field 3)
              0
              268435520))]
        (expect-error
          (& base)
          (& zero)
          (clone
            (array-ref
              (array "input-limit" "name-limit" "output-limit" "work-limit")
              field))
          (if (or (= field 0) (= field 3))
            0
            20))))
    (let
      [data (short-bytes (long-name 4090 65) "x" 0 1 65535)]
      (check-record
        (& data)
        (long-name 4090 65)
        "x"
        (long-name 4090 65)
        0
        1
        0
        65535))
    (let
      [data (short-bytes (long-name 4091 65) "x" 0 1 0)]
      (expect-error (& data) (& limits) "name-limit" 20))
    (let
      [data (short-bytes "F" (long-name 4096 65) 0 1 0)]
      (check-record (& data) "F" (long-name 4096 97) "F" 0 1 0 0))
    (let
      [data (short-bytes "F" (long-name 4097 65) 0 1 0)]
      (expect-error (& data) (& limits) "name-limit" 22))
    (for [id
      (array
        (archive.ArchiveMemberId (archive.ArchiveIdentity 17 23) -1 608)
        (archive.ArchiveMemberId (archive.ArchiveIdentity 17 23) 4 -1))]
      (match (coff.read (& base) id (& limits))
        [(ReadFailed error)
          (test.assert-string-eq
            (dump.error-name (& error.kind))
            "invalid-member"
            "member identity boundary")]
        [_ (test.assert-true false "invalid member identity accepted")]))
    (let
      [ordinary : (__tl_dyn-array u8) (__tl_make-array u8 24)]
      (le.set-u16! (&mut ordinary) 0 0x8664)
      (le.set-u32! (&mut ordinary) 8 20)
      (le.set-u32! (&mut ordinary) 20 4)
      (test.assert-string-eq
        (dump.dump (& (read (& ordinary))) true)
        "COFF\n"
        "empty ordinary object with strings")
      (le.set-u32! (&mut ordinary) 12 0xffffffff)
      (expect-error (& ordinary) (& limits) "malformed-header" 2))))

(define (determinism-tests) : unit
  (let
    [data (sample)]
    [first (read (& data))]
    [limits (coff.default-limits)]
    [key : String "K\texample.dll\t0\tFunc\t__imp_Func\tFunc\t0\n"]
    (test.assert-string-eq
      (dump.dump (& first) true)
      "P\t17\t23\t4\t608\t0\t1\t0\t20\t25\nK\texample.dll\t0\tFunc\t__imp_Func\tFunc\t0\n"
      "fixed projection")
    (for [i (iterator.range 0 8)]
      (test.assert-string-eq
        (dump.dump (& (read (& data))) true)
        (dump.dump (& first) true)
        "repeat read"))
    (le.set-u32! (&mut data) 8 0xffffffff)
    (le.set-u16! (&mut data) 16 65535)
    (le.set-u16! (&mut data) 18 8)
    (test.assert-string-eq
      (dump.dump (& (read (& data))) false)
      key
      "timestamp/hint do not affect identity")
    (test.assert-string-eq
      (dump.dump (& first) false)
      key
      "owned normalized snapshot")
    (set! (array-ref data 20) 88)
    (test.assert-string-eq
      (dump.dump (& first) false)
      key
      "input mutation cannot change returned strings")
    (set! (array-ref data 20) 70)
    (test.assert-string-eq
      (dump.dump
        (&
          (coff.read
            (& data)
            (archive.ArchiveMemberId (archive.ArchiveIdentity 17 24) 5 700)
            (& limits)))
        false)
      key
      "member provenance is separate")
    (let
      [collision (short-bytes "__imp_Func" "example.dll" 0 1 0)]
      (check-record
        (& collision)
        "__imp_Func"
        "example.dll"
        "__imp_Func"
        0
        1
        0
        0)
      (test.assert-string-eq
        (dump.dump (& (read (& collision))) false)
        "K\texample.dll\t0\t__imp_Func\t__imp___imp_Func\t__imp_Func\t0\n"
        "literal prefix/collision is preserved"))
    (le.set-u32! (&mut data) 12 0)
    (test.assert-string-eq
      (dump.dump (& (read (& data))) true)
      "E\t17\t23\t4\t608\tSizeOfData\t12\tsize-mismatch\n"
      "stable diagnostic")))

(define (self-test) : unit
  (valid-tests)
  (malformed-tests)
  (classification-tests)
  (limit-tests)
  (extra-boundary-tests)
  (determinism-tests))

(test coff-import-producer-fixtures-and-name-modes (valid-tests))

(test
  coff-import-malformed-and-classification
  (malformed-tests)
  (classification-tests))

(test coff-import-resource-limits (limit-tests) (extra-boundary-tests))

(test coff-import-deterministic-normalization (determinism-tests))