(import linker_elf_object_reader as elf)
(import stdlib.byte_le as le)
(import stdlib.iterator)
(import stdlib.test)
(import stdlib.profile as runtime-profile)
(import linker_elf_object_reader_test_dump as dump)
(import stdlib.byte_buf)
(import stdlib.string)

(include-bin
  fixture-gcc-o0-g-common
  "../tests/fixtures/elf-object/gcc-O0-g-common.in")

(include-bin
  fixture-gcc-o0-g-no-common
  "../tests/fixtures/elf-object/gcc-O0-g-no-common.in")

(include-bin
  fixture-gcc-o0-gz-common
  "../tests/fixtures/elf-object/gcc-O0-gz-common.in")

(include-bin
  fixture-gcc-o0-gz-no-common
  "../tests/fixtures/elf-object/gcc-O0-gz-no-common.in")

(include-bin
  fixture-gcc-o0-tlsdesc
  "../tests/fixtures/elf-object/gcc-O0-tlsdesc.in")

(include-bin
  fixture-gcc-o2-g-common
  "../tests/fixtures/elf-object/gcc-O2-g-common.in")

(include-bin
  fixture-gcc-o2-g-no-common
  "../tests/fixtures/elf-object/gcc-O2-g-no-common.in")

(include-bin
  fixture-gcc-o2-gz-common
  "../tests/fixtures/elf-object/gcc-O2-gz-common.in")

(include-bin
  fixture-gcc-o2-gz-no-common
  "../tests/fixtures/elf-object/gcc-O2-gz-no-common.in")

(include-bin
  fixture-gcc-o2-tlsdesc
  "../tests/fixtures/elf-object/gcc-O2-tlsdesc.in")

(include-bin
  fixture-clang-o0-g-common
  "../tests/fixtures/elf-object/clang-O0-g-common.in")

(include-bin
  fixture-clang-o0-g-no-common
  "../tests/fixtures/elf-object/clang-O0-g-no-common.in")

(include-bin
  fixture-clang-o0-gz-common
  "../tests/fixtures/elf-object/clang-O0-gz-common.in")

(include-bin
  fixture-clang-o0-gz-no-common
  "../tests/fixtures/elf-object/clang-O0-gz-no-common.in")

(include-bin
  fixture-clang-o0-tlsdesc
  "../tests/fixtures/elf-object/clang-O0-tlsdesc.in")

(include-bin
  fixture-clang-o2-g-common
  "../tests/fixtures/elf-object/clang-O2-g-common.in")

(include-bin
  fixture-clang-o2-g-no-common
  "../tests/fixtures/elf-object/clang-O2-g-no-common.in")

(include-bin
  fixture-clang-o2-gz-common
  "../tests/fixtures/elf-object/clang-O2-gz-common.in")

(include-bin
  fixture-clang-o2-gz-no-common
  "../tests/fixtures/elf-object/clang-O2-gz-no-common.in")

(include-bin
  fixture-clang-o2-tlsdesc
  "../tests/fixtures/elf-object/clang-O2-tlsdesc.in")

(include-bin
  fixture-gcc-o0-sframe
  "../tests/fixtures/elf-object/gcc-O0-sframe.in")

(include-bin
  fixture-gcc-o2-sframe
  "../tests/fixtures/elf-object/gcc-O2-sframe.in")

(include-bin
  fixture-gnu-as-groups
  "../tests/fixtures/elf-object/gnu-as-groups.in")

(include-bin
  fixture-typelisp-direct
  "../tests/fixtures/elf-object/typelisp-direct.in")

(include-bin
  oracle-clang-o0-g-common
  "../tests/fixtures/elf-object/clang-O0-g-common.expected")

(include-bin
  oracle-clang-o0-g-no-common
  "../tests/fixtures/elf-object/clang-O0-g-no-common.expected")

(include-bin
  oracle-clang-o0-gz-common
  "../tests/fixtures/elf-object/clang-O0-gz-common.expected")

(include-bin
  oracle-clang-o0-gz-no-common
  "../tests/fixtures/elf-object/clang-O0-gz-no-common.expected")

(include-bin
  oracle-clang-o0-tlsdesc
  "../tests/fixtures/elf-object/clang-O0-tlsdesc.expected")

(include-bin
  oracle-clang-o2-g-common
  "../tests/fixtures/elf-object/clang-O2-g-common.expected")

(include-bin
  oracle-clang-o2-g-no-common
  "../tests/fixtures/elf-object/clang-O2-g-no-common.expected")

(include-bin
  oracle-clang-o2-gz-common
  "../tests/fixtures/elf-object/clang-O2-gz-common.expected")

(include-bin
  oracle-clang-o2-gz-no-common
  "../tests/fixtures/elf-object/clang-O2-gz-no-common.expected")

(include-bin
  oracle-clang-o2-tlsdesc
  "../tests/fixtures/elf-object/clang-O2-tlsdesc.expected")

(include-bin
  oracle-gcc-o0-g-common
  "../tests/fixtures/elf-object/gcc-O0-g-common.expected")

(include-bin
  oracle-gcc-o0-g-no-common
  "../tests/fixtures/elf-object/gcc-O0-g-no-common.expected")

(include-bin
  oracle-gcc-o0-gz-common
  "../tests/fixtures/elf-object/gcc-O0-gz-common.expected")

(include-bin
  oracle-gcc-o0-gz-no-common
  "../tests/fixtures/elf-object/gcc-O0-gz-no-common.expected")

(include-bin
  oracle-gcc-o0-sframe
  "../tests/fixtures/elf-object/gcc-O0-sframe.expected")

(include-bin
  oracle-gcc-o0-tlsdesc
  "../tests/fixtures/elf-object/gcc-O0-tlsdesc.expected")

(include-bin
  oracle-gcc-o2-g-common
  "../tests/fixtures/elf-object/gcc-O2-g-common.expected")

(include-bin
  oracle-gcc-o2-g-no-common
  "../tests/fixtures/elf-object/gcc-O2-g-no-common.expected")

(include-bin
  oracle-gcc-o2-gz-common
  "../tests/fixtures/elf-object/gcc-O2-gz-common.expected")

(include-bin
  oracle-gcc-o2-gz-no-common
  "../tests/fixtures/elf-object/gcc-O2-gz-no-common.expected")

(include-bin
  oracle-gcc-o2-sframe
  "../tests/fixtures/elf-object/gcc-O2-sframe.expected")

(include-bin
  oracle-gcc-o2-tlsdesc
  "../tests/fixtures/elf-object/gcc-O2-tlsdesc.expected")

(include-bin
  oracle-gnu-as-groups
  "../tests/fixtures/elf-object/gnu-as-groups.expected")

(include-bin
  oracle-typelisp-direct
  "../tests/fixtures/elf-object/typelisp-direct.expected")

(define (request) : elf.ElfReadRequest
  (elf.ElfReadRequest
    (elf.ElfIdentity (cast 41 : u64) (cast 7 : u64))
    (elf.default-limits)))

(define (header [sections : i64]) : (__tl_dyn-array u8)
  (let
    [data : (__tl_dyn-array u8) (__tl_make-array u8 (+ 64 (* sections 64)))]
    (set! (array-ref data 0) (cast 127 : u8))
    (set! (array-ref data 1) (cast 69 : u8))
    (set! (array-ref data 2) (cast 76 : u8))
    (set! (array-ref data 3) (cast 70 : u8))
    (set! (array-ref data 4) (cast 2 : u8))
    (set! (array-ref data 5) (cast 1 : u8))
    (set! (array-ref data 6) (cast 1 : u8))
    (le.set-u16! (&mut data) 16 1)
    (le.set-u16! (&mut data) 18 62)
    (le.set-u32! (&mut data) 20 1)
    (le.set-u64!
      (&mut data)
      40
      (if (= sections 0)
        0
        64))
    (le.set-u16! (&mut data) 52 64)
    (le.set-u16! (&mut data) 58 64)
    (le.set-u16! (&mut data) 60 sections)
    data))

(define (assert-header-error
  [data : (& b (__tl_dyn-array u8))]
  [req : (& r elf.ElfReadRequest)]
  [offset : i64]) : unit
  (let
    [check : elf.ElfCheck (elf.new-check req)]
    (match (elf.read-header data (&mut check))
      [(HeaderReady _) (test.assert-true false "malformed ELF header accepted")]
      [(HeaderFailed error)
        (test.assert-i64-eq error.offset offset "first bad header byte")
        (test.assert-true
          (= error.input.input (cast 41 : u64))
          "input provenance")
        (test.assert-true
          (= error.input.content (cast 7 : u64))
          "content provenance")
        (test.assert-i64-eq error.section -1 "header is outside a section")]))
  unit)

(define (header-positive-tests) : unit
  (for [sections (iterator.range 0 3)]
    (let
      [data : (__tl_dyn-array u8) (header sections)]
      [req : elf.ElfReadRequest (request)]
      [check : elf.ElfCheck (elf.new-check (& req))]
      (match (elf.read-header (& data) (&mut check))
        [(HeaderFailed _)
          (test.assert-true false "valid minimal ELF header rejected")]
        [(HeaderReady parsed)
          (test.assert-i64-eq parsed.section-count sections "section count")
          (test.assert-i64-eq
            parsed.section-offset
            (if (= sections 0)
              0
              64)
            "table offset")])))
  (let
    [data : (__tl_dyn-array u8) (header 2)]
    [req : elf.ElfReadRequest (request)]
    (le.set-u16! (&mut data) 60 0)
    (le.set-u64! (&mut data) 96 2)
    (le.set-u16! (&mut data) 62 65535)
    (le.set-u32! (&mut data) 104 1)
    (set! (array-ref data 7) (cast 3 : u8))
    (let
      [check : elf.ElfCheck (elf.new-check (& req))]
      (match (elf.read-header (& data) (&mut check))
        [(HeaderFailed _)
          (test.assert-true false "extended GNU header rejected")]
        [(HeaderReady parsed)
          (test.assert-i64-eq parsed.section-count 2 "extended section count")
          (test.assert-i64-eq parsed.name-table 1 "extended name index")
          (test.assert-i64-eq parsed.osabi 3 "GNU OSABI retained")]))))

(define (header-negative-tests) : unit
  (let
    [positions : (Array i64 13) (array 0 4 5 6 7 16 18 20 32 52 56 58 60)]
    [values : (Array i64 13) (array 0 1 2 0 9 2 3 0 1 63 1 63 255)]
    [req : elf.ElfReadRequest (request)]
    (for [i (iterator.range 0 13)]
      (let
        [data : (__tl_dyn-array u8) (header 1)]
        [at : i64 (array-ref positions i)]
        (set! (array-ref data at) (cast (array-ref values i) : u8))
        (assert-header-error
          (& data)
          (& req)
          (if (= at 60)
            40
            at)))))
  (for [length (iterator.range 0 64)]
    (let
      [data : (__tl_dyn-array u8) (__tl_make-array u8 length)]
      [req : elf.ElfReadRequest (request)]
      (assert-header-error (& data) (& req) length)))
  (let
    [data : (__tl_dyn-array u8) (header 1)]
    [req : elf.ElfReadRequest (request)]
    (le.set-u64! (&mut data) 40 -1)
    (assert-header-error (& data) (& req) 40)
    (le.set-u64! (&mut data) 40 64)
    (le.set-u16! (&mut data) 60 0)
    (le.set-u64! (&mut data) 96 -1)
    (assert-header-error (& data) (& req) 96)))

(define (header-limit-tests) : unit
  (let
    [data : (__tl_dyn-array u8) (header 1)]
    [req : elf.ElfReadRequest (request)]
    (set! req.limits.max-input-bytes 127)
    (assert-header-error (& data) (& req) 0)
    (set! req.limits.max-input-bytes 128)
    (set! req.limits.max-sections 0)
    (assert-header-error (& data) (& req) 60)
    (set! req.limits.max-sections 1)
    (set! req.limits.max-diagnostics 0)
    (assert-header-error (& data) (& req) 0)
    (set! req.limits.max-diagnostics 1)
    (set! req.limits.max-work 127)
    (assert-header-error (& data) (& req) 64)
    (set! req.limits.max-work 128)
    (let
      [check : elf.ElfCheck (elf.new-check (& req))]
      (test.assert-true
        (match (elf.read-header (& data) (&mut check))
          [(HeaderReady _) true]
          [_ false])
        "exact byte/section/diagnostic/work limits pass")
      (test.assert-i64-eq check.left 0 "header work charged exactly"))))

(test elf-header-provenance-and-extended-numbering (header-positive-tests))

(test elf-header-truncation-and-hostile-offsets (header-negative-tests))

(test elf-header-resource-boundaries (header-limit-tests))

(define (assert-producer-object
  [data : (& b (__tl_dyn-array u8))]
  [expected : (& e (__tl_dyn-array u8))]
  [label : String]) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    (match (elf.read-object data (& req))
      [(ReadFailed error)
        (test.assert-true false label)
        (test.assert-i64-eq error.offset -1 "unexpected ELF failure offset")]
      [(ReadObject object)
        (test.assert-owned-string-eq
          (dump.dump (& object) false)
          (byte_buf.to-string
            (byte_buf.ByteBuf
              (copy-bytes expected (array-length expected))
              (array-length expected)))
          "independent LLVM structure")
        (test.assert-i64-eq
          (array-length object.sections)
          object.header.section-count
          "physical section count")
        (test.assert-true
          (> (array-length object.symbols) 0)
          "producer has symbols")
        (test.assert-true
          (> (array-length object.relocations) 0)
          "producer has relocations")
        (test.assert-true (> object.work 0) "work accounted")
        (test.assert-i64-eq
          (array-length object.bytes)
          (array-length data)
          "input borrowed intact")])))

(define (producer-tests) : unit
  (assert-producer-object
    (& fixture-gcc-o0-g-common)
    (& oracle-gcc-o0-g-common)
    "gcc-O0-g-common")
  (assert-producer-object
    (& fixture-gcc-o0-g-no-common)
    (& oracle-gcc-o0-g-no-common)
    "gcc-O0-g-no-common")
  (assert-producer-object
    (& fixture-gcc-o0-gz-common)
    (& oracle-gcc-o0-gz-common)
    "gcc-O0-gz-common")
  (assert-producer-object
    (& fixture-gcc-o0-gz-no-common)
    (& oracle-gcc-o0-gz-no-common)
    "gcc-O0-gz-no-common")
  (assert-producer-object
    (& fixture-gcc-o0-tlsdesc)
    (& oracle-gcc-o0-tlsdesc)
    "gcc-O0-tlsdesc")
  (assert-producer-object
    (& fixture-gcc-o2-g-common)
    (& oracle-gcc-o2-g-common)
    "gcc-O2-g-common")
  (assert-producer-object
    (& fixture-gcc-o2-g-no-common)
    (& oracle-gcc-o2-g-no-common)
    "gcc-O2-g-no-common")
  (assert-producer-object
    (& fixture-gcc-o2-gz-common)
    (& oracle-gcc-o2-gz-common)
    "gcc-O2-gz-common")
  (assert-producer-object
    (& fixture-gcc-o2-gz-no-common)
    (& oracle-gcc-o2-gz-no-common)
    "gcc-O2-gz-no-common")
  (assert-producer-object
    (& fixture-gcc-o2-tlsdesc)
    (& oracle-gcc-o2-tlsdesc)
    "gcc-O2-tlsdesc")
  (assert-producer-object
    (& fixture-clang-o0-g-common)
    (& oracle-clang-o0-g-common)
    "clang-O0-g-common")
  (assert-producer-object
    (& fixture-clang-o0-g-no-common)
    (& oracle-clang-o0-g-no-common)
    "clang-O0-g-no-common")
  (assert-producer-object
    (& fixture-clang-o0-gz-common)
    (& oracle-clang-o0-gz-common)
    "clang-O0-gz-common")
  (assert-producer-object
    (& fixture-clang-o0-gz-no-common)
    (& oracle-clang-o0-gz-no-common)
    "clang-O0-gz-no-common")
  (assert-producer-object
    (& fixture-clang-o0-tlsdesc)
    (& oracle-clang-o0-tlsdesc)
    "clang-O0-tlsdesc")
  (assert-producer-object
    (& fixture-clang-o2-g-common)
    (& oracle-clang-o2-g-common)
    "clang-O2-g-common")
  (assert-producer-object
    (& fixture-clang-o2-g-no-common)
    (& oracle-clang-o2-g-no-common)
    "clang-O2-g-no-common")
  (assert-producer-object
    (& fixture-clang-o2-gz-common)
    (& oracle-clang-o2-gz-common)
    "clang-O2-gz-common")
  (assert-producer-object
    (& fixture-clang-o2-gz-no-common)
    (& oracle-clang-o2-gz-no-common)
    "clang-O2-gz-no-common")
  (assert-producer-object
    (& fixture-clang-o2-tlsdesc)
    (& oracle-clang-o2-tlsdesc)
    "clang-O2-tlsdesc")
  (assert-producer-object
    (& fixture-gcc-o0-sframe)
    (& oracle-gcc-o0-sframe)
    "gcc-O0-sframe")
  (assert-producer-object
    (& fixture-gcc-o2-sframe)
    (& oracle-gcc-o2-sframe)
    "gcc-O2-sframe")
  (assert-producer-object
    (& fixture-gnu-as-groups)
    (& oracle-gnu-as-groups)
    "gnu-as-groups")
  (assert-producer-object
    (& fixture-typelisp-direct)
    (& oracle-typelisp-direct)
    "typelisp-direct"))

(test elf-real-producer-objects (producer-tests))

(define (retained-refusal-allocation [data : (& b (__tl_dyn-array u8))]) : i64
  (let
    [req : elf.ElfReadRequest (request)]
    (set! req.limits.max-retained-bytes 0)
    (let
      [check : elf.ElfCheck (elf.new-check (& req))]
      [before : i64 (runtime-profile.alloc-total)]
      (match (elf.read-header data (&mut check))
        [(HeaderReady parsed)
          (elf.preflight data (& parsed) (&mut check))
          unit]
        [(HeaderFailed _) unit])
      (let
        [allocated : i64 (- (runtime-profile.alloc-total) before)]
        (test.assert-true
          (not check.ok)
          "zero retained budget refuses metadata")
        (test.assert-true
          (match check.error.kind
            [(RetainedLimit) true]
            [_ false])
          "typed retained limit")
        allocated))))

(define (retained-budget-tests) : unit
  (let
    [small : (__tl_dyn-array u8) (header 1)]
    [large : (__tl_dyn-array u8) (header 1024)]
    [small-allocation : i64 (retained-refusal-allocation (& small))]
    [large-allocation : i64 (retained-refusal-allocation (& large))]
    (test.assert-i64-eq
      large-allocation
      small-allocation
      "retained refusal allocation independent of declared section count")
    (test.assert-true (<= small-allocation 512) "bounded diagnostic state only")))

(test elf-retained-budget-before-section-allocation (retained-budget-tests))

(cfg
  compile-profile
  (test
    elf-profile-counter-fixture-active
    (let
      [before : i64 (runtime-profile.alloc-total)]
      [data : (__tl_dyn-array u8) (__tl_make-array u8 4096)]
      [sum : i64 0]
      (for [i (iterator.range 0 4096)]
        (set! (array-ref data i) (cast (% i 251) : u8)))
      (for [i (iterator.range 0 4096)]
        (set! sum (+ sum (cast (array-ref data i) : i64))))
      (test.assert-true (> sum 0) "allocation fixture is consumed")
      (test.assert-true
        (>= (- (runtime-profile.alloc-total) before) 4096)
        "compile-profile allocation counters are active"))))

(define (copy-bytes [data : (& d (__tl_dyn-array u8))] [size : i64]) : (__tl_dyn-array
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

(define (section-field
  [data : (& d (__tl_dyn-array u8))]
  [index : i64]
  [field : i64]) : i64
  (+ (le.read-u64 data 40) (* index 64) field))

(define (error-code [kind : (& k elf.ElfErrorKind)]) : i64
  (match (deref kind)
    [(BadHeader) 1]
    [(BadNumbering) 2]
    [(BadRange) 3]
    [(OverlappingRanges) 4]
    [(BadSection) 5]
    [(BadString) 6]
    [(BadSymbol) 7]
    [(BadExtendedIndex) 8]
    [(BadRelocation) 9]
    [(BadGroup) 10]
    [(BadNote) 11]
    [(BadCompression) 12]
    [(UnsupportedCompressedMetadata) 13]
    [(UnsupportedRelFormat) 14]
    [(InvalidLimits) 20]
    [(InputLimit) 21]
    [(SectionLimit) 22]
    [(SymbolLimit) 23]
    [(RelocationLimit) 24]
    [(GroupLimit) 25]
    [(NoteLimit) 26]
    [(StringLimit) 27]
    [(RetainedLimit) 28]
    [(DiagnosticLimit) 29]
    [(WorkLimit) 30]
    [(UnsupportedClass) 31]
    [(UnsupportedEncoding) 32]
    [(UnsupportedVersion) 33]
    [(UnsupportedOsAbi) 34]
    [(UnsupportedObjectType) 35]
    [(UnsupportedMachine) 36]
    [(UnexpectedProgramHeaders) 37]))

(define (assert-object-error
  [data : (& d (__tl_dyn-array u8))]
  [req : (& r elf.ElfReadRequest)]
  [kind : i64]
  [offset : i64]) : unit
  (match (elf.read-object data req)
    [(ReadObject _) (test.assert-true false "malformed object accepted")]
    [(ReadFailed error)
      (test.assert-i64-eq
        (error-code (& error.kind))
        kind
        "typed ELF rejection")
      (test.assert-i64-eq error.offset offset "exact rejected field offset")
      (test.assert-true
        (= error.input.input req.identity.input)
        "error input identity")
      (test.assert-true
        (= error.input.content req.identity.content)
        "error content identity")]))

(defstruct Mutation
  (at i64)
  (width i64)
  (value i64)
  (kind i64)
  (offset i64))

(define (mutate!
  [data : (&mut d (__tl_dyn-array u8))]
  [at : i64]
  [width : i64]
  [value : i64]) : unit
  (match width
    [1 (set! (array-ref data at) (cast value : u8))]
    [2 (le.set-u16! data at value)]
    [4 (le.set-u32! data at value)]
    [_ (le.set-u64! data at value)])
  unit)

(define (table-negative-tests) : unit
  ;; This checked GNU-as fixture has independent readelf/LLVM provenance.
  (let
    [req : elf.ElfReadRequest (request)]
    [mutations : (Array Mutation 58)
      (array
        (Mutation 4 1 1 31 4)
        (Mutation 5 1 2 32 5)
        (Mutation 6 1 0 33 6)
        (Mutation 7 1 9 34 7)
        (Mutation 16 1 2 35 16)
        (Mutation 18 1 3 36 18)
        (Mutation 20 1 0 33 20)
        (Mutation 32 1 1 37 32)
        (Mutation 56 1 1 37 56)
        (Mutation 728 8 1 5 720)
        (Mutation 936 8 -1 3 936)
        (Mutation 944 8 -1 3 936)
        (Mutation 960 8 3 5 960)
        (Mutation 936 8 0 4 936)
        (Mutation 1128 8 80 4 1128)
        (Mutation 1172 4 9 14 1172)
        (Mutation 1208 4 22 5 1208)
        (Mutation 1208 4 20 5 1208)
        (Mutation 1212 4 0 9 1212)
        (Mutation 1212 4 22 5 1212)
        (Mutation 1224 8 16 5 1224)
        (Mutation 1200 8 23 5 1200)
        (Mutation 1272 4 22 5 1272)
        (Mutation 1416 8 0 5 1416)
        (Mutation 1456 8 7 5 1456)
        (Mutation 1976 4 19 5 1976)
        (Mutation 1980 4 0 7 1980)
        (Mutation 1980 4 7 7 1980)
        (Mutation 1992 8 8 5 1992)
        (Mutation 1968 8 143 5 1968)
        (Mutation 352 1 1 6 352)
        (Mutation 411 1 1 6 352)
        (Mutation 1040 4 -1 6 1040)
        (Mutation 208 4 1 7 208)
        (Mutation 232 4 -1 6 232)
        (Mutation 236 1 2 7 236)
        (Mutation 238 2 22 7 238)
        (Mutation 312 8 3 7 312)
        (Mutation 424 8 -1 9 424)
        (Mutation 416 8 -1 9 416)
        (Mutation 416 8 1 9 416)
        (Mutation 792 8 2 10 784)
        (Mutation 816 8 0 10 784)
        (Mutation 828 4 6 10 828)
        (Mutation 68 4 0 10 68)
        (Mutation 68 4 22 10 68)
        (Mutation 72 4 5 10 72)
        (Mutation 1048 8 6 10 68)
        (Mutation 1240 8 642 10 1240)
        (Mutation 1792 8 16 11 1792)
        (Mutation 1776 8 11 11 136)
        (Mutation 136 4 -1 11 136)
        (Mutation 140 4 -1 11 140)
        (Mutation 152 1 1 11 148)
        (Mutation 1776 8 23 11 159)
        (Mutation 984 8 2048 12 1008)
        (Mutation 920 8 2048 12 944)
        (Mutation 1944 8 2048 13 1944))]
    (for [i (iterator.range 0 58)]
      (let
        [data : (__tl_dyn-array u8)
          (copy-bytes
            (& fixture-gnu-as-groups)
            (array-length fixture-gnu-as-groups))]
        [mutation : Mutation (array-ref mutations i)]
        (mutate! (&mut data) mutation.at mutation.width mutation.value)
        (assert-object-error (& data) (& req) mutation.kind mutation.offset)))))

(test
  elf-malformed-sections-symbols-relocations-groups-notes
  (table-negative-tests))

(define (set-limit!
  [_limits : (&mut l elf.ElfLimits)]
  [index : i64]
  [value : i64]) : unit
  (match index
    [0 (set! _limits.max-input-bytes value)]
    [1 (set! _limits.max-sections value)]
    [2 (set! _limits.max-symbols value)]
    [3 (set! _limits.max-relocations value)]
    [4 (set! _limits.max-groups value)]
    [5 (set! _limits.max-notes value)]
    [6 (set! _limits.max-string-bytes value)]
    [7 (set! _limits.max-retained-bytes value)]
    [8 (set! _limits.max-diagnostics value)]
    [_ (set! _limits.max-work value)])
  unit)

(define (fixture-retained-budget) : i64
  (let
    [req : elf.ElfReadRequest (request)]
    [check : elf.ElfCheck (elf.new-check (& req))]
    (match (elf.read-header (& fixture-gnu-as-groups) (&mut check))
      [(HeaderFailed _) 0]
      [(HeaderReady header)
        (let
          [counts : elf.ElfCounts
            (elf.preflight (& fixture-gnu-as-groups) (& header) (&mut check))]
          (test.assert-true check.ok "fixture preflight")
          counts.retained)])))

(define (all-limit-tests) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    [work : i64
      (match (elf.read-object (& fixture-gnu-as-groups) (& req))
        [(ReadFailed _) 0]
        [(ReadObject object) object.work])]
    [values : (Array i64 10)
      (array
        (array-length fixture-gnu-as-groups)
        22
        6
        3
        1
        2
        288
        (fixture-retained-budget)
        1
        work)]
    (test.assert-true (> work 0) "fixture work")
    (for [i (iterator.range 0 10)]
      (let
        [exact : elf.ElfReadRequest (request)]
        [bound : i64 (array-ref values i)]
        (set-limit! (&mut exact.limits) i bound)
        (test.assert-true
          (match (elf.read-object (& fixture-gnu-as-groups) (& exact))
            [(ReadObject _) true]
            [_ false])
          "every exact caller limit passes")
        (set-limit! (&mut exact.limits) i (- bound 1))
        (match (elf.read-object (& fixture-gnu-as-groups) (& exact))
          [(ReadObject _) (test.assert-true false "one-below limit must fail")]
          [(ReadFailed error)
            (test.assert-i64-eq
              (error-code (& error.kind))
              (+ 21 i)
              "specific exhausted limit")])
        (set-limit! (&mut exact.limits) i -1)
        (assert-object-error (& fixture-gnu-as-groups) (& exact) 20 0)))))

(test elf-every-resource-limit-exact-and-one-below (all-limit-tests))

;; Small synthetic directory places the section table first, so truncations
;; reach payload validation instead of all stopping at a missing EOF table.
(define (small-object [extended : bool]) : (__tl_dyn-array u8)
  (let
    [base : (__tl_dyn-array u8) (header 6)]
    [data : (__tl_dyn-array u8) (copy-bytes (& base) 576)]
    ;; section1: one empty string; section2: 32 bytes of writable payload.
    (le.set-u32! (&mut data) 132 3)
    (le.set-u64! (&mut data) 152 448)
    (le.set-u64! (&mut data) 160 1)
    (le.set-u32! (&mut data) 196 1)
    (le.set-u64! (&mut data) 216 456)
    (le.set-u64! (&mut data) 224 32)
    ;; section3: null symbol then one global function in section2.
    (le.set-u32! (&mut data) 260 2)
    (le.set-u64! (&mut data) 280 488)
    (le.set-u64! (&mut data) 288 48)
    (le.set-u32! (&mut data) 296 1)
    (le.set-u32! (&mut data) 300 1)
    (le.set-u64! (&mut data) 312 24)
    (set! (array-ref data 516) (cast 18 : u8))
    (le.set-u16!
      (&mut data)
      518
      (if extended
        65535
        2))
    ;; section4: one R_X86_64_64 with signed addend -7.
    (le.set-u32! (&mut data) 324 4)
    (le.set-u64! (&mut data) 344 536)
    (le.set-u64! (&mut data) 352 24)
    (le.set-u32! (&mut data) 360 3)
    (le.set-u32! (&mut data) 364 2)
    (le.set-u64! (&mut data) 376 24)
    (le.set-u64! (&mut data) 536 24)
    (le.set-u64! (&mut data) 544 4294967297)
    (le.set-u64! (&mut data) 552 -7)
    ;; section5: parallel XINDEX words. Zero for every non-XINDEX symbol.
    (le.set-u32! (&mut data) 388 18)
    (le.set-u64! (&mut data) 408 560)
    (le.set-u64! (&mut data) 416 8)
    (le.set-u32! (&mut data) 424 3)
    (le.set-u64! (&mut data) 440 4)
    (le.set-u32!
      (&mut data)
      564
      (if extended
        2
        0))
    data))

(define (extended-and-truncation-tests) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    (for [mode (iterator.range 0 2)]
      (let
        [data : (__tl_dyn-array u8) (small-object (= mode 1))]
        (match (elf.read-object (& data) (& req))
          [(ReadFailed _)
            (test.assert-true false "parallel extended index accepted")]
          [(ReadObject object)
            (test.assert-i64-eq
              (array-ref object.symbols 1).section-index-offset
              (if (= mode 1)
                564
                518)
              "source of resolved section index")
            (test.assert-true
              (match (array-ref object.symbols 1).section
                [(DefinedSection id) (= id.index 2)]
                [_ false])
              "XINDEX resolves syntax identity")
            (test.assert-i64-eq
              (array-ref object.relocations 0).addend
              -7
              "signed addend")]))))
  (let
    [full : (__tl_dyn-array u8) (small-object true)]
    [req : elf.ElfReadRequest (request)]
    (for [length (iterator.range 0 568)]
      (let
        [data : (__tl_dyn-array u8) (copy-bytes (& full) length)]
        (test.assert-true
          (match (elf.read-object (& data) (& req))
            [(ReadFailed _) true]
            [_ false])
          "every header/table/payload prefix rejects without out-of-bounds access")))
    (for [i (iterator.range 0 5)]
      (let
        [data : (__tl_dyn-array u8) (copy-bytes (& full) 576)]
        [at : i64
          (match i
            [0 560]
            [1 564]
            [2 416]
            [3 388]
            [_ 428])]
        [value : i64
          (match i
            [0 2]
            [1 6]
            [2 4]
            [3 1]
            [_ 1])]
        [offset : i64
          (match i
            [0 560]
            [1 564]
            [2 416]
            [3 518]
            [_ 416])]
        [kind : i64 8]
        (le.set-u32! (&mut data) at value)
        (assert-object-error (& data) (& req) kind offset)))))

(test
  elf-extended-indices-and-every-structured-prefix
  (extended-and-truncation-tests))

(define (large-extended-test) : unit
  (let
    [small : (__tl_dyn-array u8) (small-object true)]
    [count : i64 65537]
    [end : i64 (+ 64 (* count 64))]
    [data : (__tl_dyn-array u8) (__tl_make-array u8 (+ end 128))]
    [req : elf.ElfReadRequest (request)]
    (for [i (iterator.range 0 448)]
      (set! (array-ref data i) (array-ref small i)))
    (le.set-u16! (&mut data) 60 0)
    (le.set-u64! (&mut data) 96 count)
    (for [index (iterator.range 1 6)]
      (let
        [field : i64 (+ 64 (* index 64) 24)]
        [offset : i64 (le.read-u64 (& small) field)]
        (le.set-u64! (&mut data) field (+ end (- offset 448)))))
    (for [i (iterator.range 0 128)]
      (set! (array-ref data (+ end i)) (array-ref small (+ 448 i))))
    (le.set-u32! (&mut data) (+ end 116) 65536)
    (le.set-u32! (&mut data) (+ 64 (* 65536 64) 4) 8)
    (le.set-u64! (&mut data) (+ 64 (* 65536 64) 24) -1)
    (le.set-u64! (&mut data) (+ 64 (* 65536 64) 32) -1)
    (match (elf.read-object (& data) (& req))
      [(ReadFailed _)
        (test.assert-true false "real high XINDEX object accepted")]
      [(ReadObject object)
        (test.assert-i64-eq
          (array-length object.sections)
          count
          "extended count above reserved boundary")
        (test.assert-true
          (match (array-ref object.symbols 1).section
            [(DefinedSection id) (= id.index 65536)]
            [_ false])
          "32-bit section index is not truncated to ELF16")
        (test.assert-i64-eq
          (array-ref object.sections 65536).payload.size
          0
          "NOBITS has no file range")
        (test.assert-true
          (= (array-ref object.sections 65536).size (cast -1 : u64))
          "NOBITS preserves unsigned size")])
    (let
      [names : (__tl_dyn-array u8) (copy-bytes (& data) (+ end 129))]
      (le.set-u16! (&mut names) 62 65535)
      (le.set-u32! (&mut names) 104 65536)
      (le.set-u32! (&mut names) (+ 64 (* 65536 64) 4) 3)
      (le.set-u64! (&mut names) (+ 64 (* 65536 64) 24) (+ end 128))
      (le.set-u64! (&mut names) (+ 64 (* 65536 64) 32) 1)
      (test.assert-true
        (match (elf.read-object (& names) (& req))
          [(ReadObject object) (= object.header.name-table 65536)]
          [_ false])
        "real high extended name-table index"))
    (set! req.limits.max-sections 65536)
    (assert-object-error (& data) (& req) 22 96)))

(test elf-real-high-section-number-and-huge-nobits (large-extended-test))

(define (relocation-boundary-tests) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    ;; The expected width table is the x86-64 ABI's field-size column.
    [widths : (Array i64 52)
      (array
        0
        8
        4
        4
        4
        0
        8
        8
        8
        4
        4
        4
        2
        2
        1
        1
        8
        8
        8
        4
        4
        4
        4
        4
        8
        8
        4
        8
        8
        8
        8
        8
        4
        8
        4
        0
        16
        8
        8
        -1
        -1
        4
        4
        4
        4
        4
        4
        4
        4
        4
        4
        4)]
    (for [number (iterator.range 0 53)]
      (let
        [data : (__tl_dyn-array u8) (small-object false)]
        [raw : i64
          (if (= number 52)
            4294967295
            number)]
        [width : i64
          (if (= number 52)
            -1
            (array-ref widths number))]
        [offset : i64
          (if (> width 0)
            (- 32 width)
            32)]
        (le.set-u64! (&mut data) 536 offset)
        (le.set-u64! (&mut data) 544 (+ 4294967296 raw))
        (le.set-u64! (&mut data) 552 -9223372036854775808)
        (match (elf.read-object (& data) (& req))
          [(ReadFailed _)
            (test.assert-true false "exact relocation field boundary accepted")]
          [(ReadObject object)
            (let
              [reloc : elf.ElfRelocation (array-ref object.relocations 0)]
              (test.assert-i64-eq reloc.width width "ABI field width")
              (test.assert-i64-eq
                reloc.number
                raw
                "full unsigned relocation number")
              (test.assert-i64-eq
                reloc.addend
                -9223372036854775808
                "full signed addend")
              (test.assert-true
                (match reloc.kind
                  [(UnknownRelocation code) (= code raw)]
                  [_ (>= width 0)])
                "unknown relocation remains explicitly typed"))])
        (let
          [bad : (__tl_dyn-array u8) (copy-bytes (& data) 576)]
          (le.set-u64! (&mut bad) 536 (+ offset 1))
          (assert-object-error (& bad) (& req) 9 536))))))

(test elf-all-relocation-widths-and-unknown-types (relocation-boundary-tests))

(define (compression-object) : (__tl_dyn-array u8)
  (let
    [data : (__tl_dyn-array u8) (small-object false)]
    (le.set-u64! (&mut data) 200 2048)
    (le.set-u32! (&mut data) 456 1)
    (le.set-u64! (&mut data) 464 64)
    (le.set-u64! (&mut data) 472 16)
    (le.set-u64! (&mut data) 536 56)
    data))

(define (compression-tests) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    (for [kind (iterator.range 1 4)]
      (let
        [data : (__tl_dyn-array u8) (compression-object)]
        (le.set-u32! (&mut data) 456 kind)
        (match (elf.read-object (& data) (& req))
          [(ReadFailed _)
            (test.assert-true false "compressed opaque target accepted")]
          [(ReadObject object)
            (test.assert-true
              (match (array-ref object.sections 2).body
                [(Compressed body)
                  (and
                    (= body.size (cast 64 : u64))
                    (= body.alignment (cast 16 : u64))
                    (= body.payload.offset 480)
                    (= body.payload.size 8)
                    (match body.kind
                      [(Zlib) (= kind 1)]
                      [(Zstd) (= kind 2)]
                      [(UnknownCompression value) (= value kind)]))]
                [_ false])
              "Chdr is retained without decompression")
            (test.assert-true
              (= (array-ref object.relocations 0).offset (cast 56 : u64))
              "relocation uses uncompressed bounds")]))))
  (let
    [req : elf.ElfReadRequest (request)]
    [mutations : (Array Mutation 6)
      (array
        (Mutation 460 4 1 12 460)
        (Mutation 472 8 3 12 472)
        (Mutation 224 8 23 12 224)
        (Mutation 196 4 8 12 224)
        (Mutation 196 4 2 13 200)
        (Mutation 536 8 57 9 536))]
    (for [i (iterator.range 0 6)]
      (let
        [data : (__tl_dyn-array u8) (compression-object)]
        [m : Mutation (array-ref mutations i)]
        (mutate! (&mut data) m.at m.width m.value)
        (assert-object-error (& data) (& req) m.kind m.offset))))
  ;; Two parallel SHNDX tables for one symtab cannot compete for ownership.
  (let
    [data : (__tl_dyn-array u8) (small-object true)]
    [req : elf.ElfReadRequest (request)]
    (le.set-u32! (&mut data) 196 18)
    (le.set-u64! (&mut data) 224 8)
    (le.set-u32! (&mut data) 232 3)
    (le.set-u64! (&mut data) 248 4)
    (assert-object-error (& data) (& req) 8 424)))

(test elf-compression-and-duplicate-parallel-index-tables (compression-tests))

(define (opaque-and-identity-tests) : unit
  (let
    [data : (__tl_dyn-array u8)
      (copy-bytes
        (& fixture-gnu-as-groups)
        (array-length fixture-gnu-as-groups))]
    [req : elf.ElfReadRequest (request)]
    ;; Names are bytes. This mutation must not be UTF-8-decoded or normalized.
    (set! (array-ref data 353) (cast 255 : u8))
    (match (elf.read-object (& data) (& req))
      [(ReadFailed _) (test.assert-true false "non-UTF8 symbol name")]
      [(ReadObject object)
        (test.assert-true
          (match (array-ref object.sections 14).class
            [(UnknownNonAllocSection) true]
            [_ false])
          "opaque nonalloc class")
        (test.assert-true
          (match (array-ref object.sections 15).class
            [(UnknownAllocSection) true]
            [_ false])
          "unknown alloc admission marker")
        (test.assert-true
          (array-ref object.sections 17).gnu-stack
          "GNU stack marker")
        (test.assert-true
          (match (array-ref object.symbols 2).binding
            [(GnuUnique) true]
            [_ false])
          "GNU unique binding")
        (test.assert-true
          (match (array-ref object.symbols 5).symbol-type
            [(GnuIfunc) true]
            [_ false])
          "GNU IFUNC type")
        (test.assert-i64-eq
          (le.byte-le-at object.bytes (array-ref object.symbols 1).name.offset)
          255
          "raw name byte retained")
        (let
          [first : String (dump.dump (& object) true)]
          ;; An unrelated parse between two reads cannot perturb IDs or order.
          [other-req : elf.ElfReadRequest (request)]
          (set! other-req.identity.input (cast 99 : u64))
          (match (elf.read-object (& fixture-gcc-o0-g-common) (& other-req))
            [(ReadFailed _) (test.assert-true false "interleaved object")]
            [(ReadObject other)
              (test.assert-true
                (= (array-ref other.sections 1).id.input.input (cast 99 : u64))
                "identity reaches records")])
          (match (elf.read-object (& data) (& req))
            [(ReadFailed _) (test.assert-true false "repeat object")]
            [(ReadObject repeated)
              (test.assert-owned-string-eq
                (dump.dump (& repeated) true)
                first
                "stable full structural dump across interleaving")]))]))
  (let
    [req : elf.ElfReadRequest (request)]
    (match (elf.read-object (& fixture-gcc-o0-g-common) (& req))
      [(ReadFailed _) (test.assert-true false "constructor fixture")]
      [(ReadObject object)
        (test.assert-true
          (match (array-ref object.sections 15).priority
            [(Priority value) (= value (cast 101 : u64))]
            [_ false])
          "constructor numeric priority")
        (test.assert-true
          (match (array-ref object.sections 19).priority
            [(Priority value) (= value (cast 201 : u64))]
            [_ false])
          "destructor numeric priority")
        (test.assert-i64-eq
          (array-ref object.sections 23).section-type
          16
          "preinit array retained")])))

(test
  elf-opaque-flags-byte-names-and-stable-provenance
  (opaque-and-identity-tests))

(define (bounded-mutation-tests) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    [size : i64 (array-length fixture-gnu-as-groups)]
    (set! req.limits.max-work 100000)
    (for [i (iterator.range 0 256)]
      (let
        [data : (__tl_dyn-array u8) (copy-bytes (& fixture-gnu-as-groups) size)]
        (set!
          (array-ref data (% (* i 7919) size))
          (cast (% (+ (* i 131) 255) 256) : u8))
        (match (elf.read-object (& data) (& req))
          [(ReadFailed error)
            (test.assert-true
              (and (>= error.offset 0) (<= error.offset size))
              "bounded mutation diagnostic provenance")]
          [(ReadObject object)
            (test.assert-true
              (<= object.work req.limits.max-work)
              "mutation work limit")
            (for [j (iterator.range 0 (array-length object.sections))]
              (let
                [s : (& object elf.ElfSection)
                  (& (array-ref object.sections j))]
                (test.assert-i64-eq
                  s.id.index
                  j
                  "stable physical order after mutation")
                (test.assert-true
                  (elf.file-range?
                    size
                    (cast s.payload.offset : u64)
                    (cast s.payload.size : u64))
                  "every returned payload bounded")))])))))

(test elf-finite-hostile-mutation-corpus (bounded-mutation-tests))

(define (self-test) : i64
  (header-positive-tests)
  (header-negative-tests)
  (header-limit-tests)
  (producer-tests)
  (retained-budget-tests)
  (table-negative-tests)
  (all-limit-tests)
  (extended-and-truncation-tests)
  (large-extended-test)
  (relocation-boundary-tests)
  (compression-tests)
  (opaque-and-identity-tests)
  (bounded-mutation-tests)
  (priority-tests)
  (payload-allocation-tests)
  42)

(define (array-with-name [kind : i64] [name : String]) : (__tl_dyn-array u8)
  (let
    [base : (__tl_dyn-array u8) (header 3)]
    [size : i64 (string.string-length (& name))]
    [data : (__tl_dyn-array u8) (copy-bytes (& base) (+ 266 size))]
    (le.set-u16! (&mut data) 62 2)
    (le.set-u32! (&mut data) 128 1)
    (le.set-u32! (&mut data) 132 kind)
    (le.set-u64! (&mut data) 152 256)
    (le.set-u64! (&mut data) 160 8)
    (le.set-u32! (&mut data) 196 3)
    (le.set-u64! (&mut data) 216 264)
    (le.set-u64! (&mut data) 224 (+ size 2))
    (for [i (iterator.range 0 size)]
      (set!
        (array-ref data (+ 265 i))
        (cast (string.string-ref (& name) i) : u8)))
    data))

(define (priority-tests) : unit
  (let
    [req : elf.ElfReadRequest (request)]
    [names : (Array String 5)
      (array
        ".init_array.18446744073709551615"
        ".fini_array.00101"
        ".preinit_array.201"
        ".init_array.184467440737095516150x"
        ".init_array.")]
    [types : (Array i64 5) (array 14 15 16 14 14)]
    [values : (Array u64 5)
      (array
        (cast -1 : u64)
        (cast 101 : u64)
        (cast 201 : u64)
        (cast 0 : u64)
        (cast 0 : u64))]
    (for [i (iterator.range 0 5)]
      (let
        [data : (__tl_dyn-array u8)
          (array-with-name (array-ref types i) (clone (array-ref names i)))]
        (match (elf.read-object (& data) (& req))
          [(ReadFailed _) (test.assert-true false "valid pointer array suffix")]
          [(ReadObject object)
            (test.assert-true
              (match (array-ref object.sections 1).priority
                [(Priority value) (and (< i 3) (= value (array-ref values i)))]
                [(NoPriority) (>= i 3)])
              "numeric suffix retained; nonnumeric deferred to layout policy")])))
    (let
      [data : (__tl_dyn-array u8)
        (array-with-name 14 ".init_array.18446744073709551616")]
      (assert-object-error (& data) (& req) 5 296))))

(test elf-pointer-array-priority-boundaries (priority-tests))

(define (payload-allocation [size : i64]) : i64
  (let
    [base : (__tl_dyn-array u8) (header 2)]
    [data : (__tl_dyn-array u8) (copy-bytes (& base) (+ 192 size))]
    [req : elf.ElfReadRequest (request)]
    (le.set-u32! (&mut data) 132 1)
    (le.set-u64! (&mut data) 152 192)
    (le.set-u64! (&mut data) 160 size)
    (let
      [before : i64 (runtime-profile.alloc-total)]
      (match (elf.read-object (& data) (& req))
        [(ReadFailed _) (test.assert-true false "opaque payload fixture")]
        [(ReadObject object)
          (test.assert-i64-eq
            (array-ref object.sections 1).payload.size
            size
            "complete borrowed payload")])
      (- (runtime-profile.alloc-total) before))))

(define (payload-allocation-tests) : unit
  (test.assert-i64-eq
    (payload-allocation 1048576)
    (payload-allocation 1)
    "reader allocation independent of payload bytes"))

(test elf-payload-bytes-are-borrowed-without-copy (payload-allocation-tests))