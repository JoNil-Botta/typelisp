(import linker_elf_dso_reader as dso)
(import linker_elf_dso_reader_test_dump as dump)
(import linker_elf_object_reader as elf)
(import linker_elf_dynamic as dynamic)
(import stdlib.byte_le as le)
(import stdlib.byte_buf)
(import stdlib.test)
(import stdlib.string)
(import stdlib.profile)

(include-bin gcc-both "../tests/fixtures/elf-dso/gcc-both.in")

(include-bin gcc-gnu "../tests/fixtures/elf-dso/gcc-gnu.in")

(include-bin gcc-sysv "../tests/fixtures/elf-dso/gcc-sysv.in")

(include-bin clang-both "../tests/fixtures/elf-dso/clang-both.in")

(include-bin clang-gnu "../tests/fixtures/elf-dso/clang-gnu.in")

(include-bin clang-sysv "../tests/fixtures/elf-dso/clang-sysv.in")

(include-bin musl "../tests/fixtures/elf-dso/musl-1.2.5.in")

(include-bin no-sections "../tests/fixtures/elf-dso/no-sections.in")

(include-bin gcc-both-oracle "../tests/fixtures/elf-dso/gcc-both.expected")

(include-bin gcc-gnu-oracle "../tests/fixtures/elf-dso/gcc-gnu.expected")

(include-bin gcc-sysv-oracle "../tests/fixtures/elf-dso/gcc-sysv.expected")

(include-bin clang-both-oracle "../tests/fixtures/elf-dso/clang-both.expected")

(include-bin clang-gnu-oracle "../tests/fixtures/elf-dso/clang-gnu.expected")

(include-bin clang-sysv-oracle "../tests/fixtures/elf-dso/clang-sysv.expected")

(include-bin musl-oracle "../tests/fixtures/elf-dso/musl-1.2.5.expected")

(include-bin
  no-sections-oracle
  "../tests/fixtures/elf-dso/no-sections.expected")

(include-bin empty-gnu "../tests/fixtures/elf-dso/gcc-empty-gnu.in")

(include-bin empty-both "../tests/fixtures/elf-dso/gcc-empty-both.in")

(include-bin
  empty-gnu-oracle
  "../tests/fixtures/elf-dso/gcc-empty-gnu.expected")

(include-bin
  empty-both-oracle
  "../tests/fixtures/elf-dso/gcc-empty-both.expected")

(define (request) : dso.DsoReadRequest
  (dso.DsoReadRequest
    (elf.ElfIdentity (cast 41 : u64) (cast 7 : u64))
    (dso.default-limits)))

(define (copy-span [data : (& b (__tl_dyn-array u8))] [at : i64] [size : i64]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 size)]
    [i : i64 0]
    (while (< i size)
      (when
        (< (+ at i) (array-length data))
        (set! (array-ref out i) (array-ref data (+ at i))))
      (set! i (+ i 1)))
    out))

(define (assert-fixture
  [data : (& b (__tl_dyn-array u8))]
  [expected : (& e (__tl_dyn-array u8))]
  [complete : bool]) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso data (& req))
      [(ReadFailed error)
        (test.assert-owned-string-eq
          error.field
          "accepted fixture"
          "producer rejected")]
      [(ReadDso object)
        (test.assert-owned-string-eq
          (dump.dump (& object) complete)
          (byte_buf.to-string
            (byte_buf.ByteBuf
              (copy-span expected 0 (array-length expected))
              (array-length expected)))
          "every independent readelf record")
        (test.assert-i64-eq
          (array-length object.bytes)
          (array-length data)
          "borrowed complete input")
        (test.assert-true
          (= object.identity.content (cast 7 : u64))
          "content provenance")]))
  unit)

(define (producer-tests) : unit
  (assert-fixture (& gcc-both) (& gcc-both-oracle) true)
  (assert-fixture (& gcc-gnu) (& gcc-gnu-oracle) true)
  (assert-fixture (& gcc-sysv) (& gcc-sysv-oracle) true)
  (assert-fixture (& clang-both) (& clang-both-oracle) true)
  (assert-fixture (& clang-gnu) (& clang-gnu-oracle) true)
  (assert-fixture (& clang-sysv) (& clang-sysv-oracle) true)
  (assert-fixture (& musl) (& musl-oracle) true)
  (assert-fixture (& no-sections) (& no-sections-oracle) false)
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso (& no-sections) (& req))
      [(ReadFailed _) (test.assert-true false "sectionless producer")]
      [(ReadDso object)
        (test.assert-i64-eq object.header.section-count 0 "no section fallback")
        (test.assert-owned-string-eq
          (dump.dump (& object) true)
          (byte_buf.to-string
            (byte_buf.ByteBuf
              (clone gcc-both-oracle)
              (array-length gcc-both-oracle)))
          "complete version model matches sectionful oracle")]))
  (test.assert-i64-eq
    (array-length gcc-both)
    (array-length no-sections)
    "same physical bytes")
  (let
    [i : i64 0]
    (while (< i (array-length gcc-both))
      (unless
        (or (and (>= i 40) (< i 48)) (and (>= i 58) (< i 64)))
        (test.assert-true
          (= (array-ref gcc-both i) (array-ref no-sections i))
          "only section header locator removed"))
      (set! i (+ i 1)))))

;; A separate linear scan reads binding/visibility/version bits from the wire.
;; Its only shared input with lookup is the already oracle-checked symbol model.
(define (linear-index
  [object : (& o (dso.DsoObject input))]
  [name : (& n (__tl_dyn-array u8))]
  [version : i64]) : i64
  (let
    [i : i64 1]
    (while (< i (array-length object.symbols))
      (let
        [s : (& o elf.ElfSymbol) (& (array-ref object.symbols i))]
        [binding : i64 (shr (le.byte-le-at object.bytes (+ s.id.offset 4)) 4)]
        [visibility : i64
          (bit-and (le.byte-le-at object.bytes (+ s.id.offset 5)) 3)]
        [raw : i64
          (match object.versions
            [(Unversioned) 1]
            [(Versioned _)
              (le.read-u16
                object.bytes
                (+ (array-ref object.version-spans 0).offset (* i 2)))])]
        [same : bool (= s.name.size (array-length name))]
        [j : i64 0]
        (while (and same (< j s.name.size))
          (set!
            same
            (= (array-ref object.bytes (+ s.name.offset j)) (array-ref name j)))
          (set! j (+ j 1)))
        (when
          (and
            same
            (> s.raw-section 0)
            (or (= binding 1) (= binding 2) (= binding 10))
            (or (= visibility 0) (= visibility 3))
            (if (< version 0)
              (and (> (bit-and raw 32767) 0) (= (bit-and raw 32768) 0))
              (= (bit-and raw 32767) version)))
          (return i)))
      (set! i (+ i 1)))
    -1))

(define (assert-lookup
  [object : (& o (dso.DsoObject input))]
  [name : (& n (__tl_dyn-array u8))]
  [version : (& v (__tl_dyn-array u8))]
  [expected : i64]
  [kind : (& k dso.DsoHashKind)]) : unit
  (let
    [query : (dso.DsoLookupRequest n v)
      (dso.DsoLookupRequest name version (clone (deref kind)) 1048576)]
    (match (dso.lookup object (& query))
      [(LookupFailed _) (test.assert-true false "bounded hash lookup")]
      [(Absent)
        (test.assert-i64-eq expected -1 "linear scan agrees with absence")]
      [(Found symbol)
        (test.assert-i64-eq
          symbol.id.index
          expected
          "own hash agrees with independent linear scan")
        (test.assert-true
          (= symbol.id.section.input.input object.identity.input)
          "lookup retains input provenance")]))
  unit)

(define (lookup-fixture [data : (& b (__tl_dyn-array u8))]) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso data (& req))
      [(ReadFailed _) (test.assert-true false "lookup producer")]
      [(ReadDso object)
        (let
          [i : i64 1]
          [missing : (__tl_dyn-array u8)
            (byte_buf.to-array (byte_buf.from-string "not_a_real_export_8300"))]
          [empty : (__tl_dyn-array u8) (__tl_make-array u8 0)]
          (while (< i (array-length object.symbols))
            (with-arena
              scratch
              (let
                [s : (& object elf.ElfSymbol) (& (array-ref object.symbols i))]
                [name : (__tl_dyn-array u8)
                  (copy-span data s.name.offset s.name.size)]
                [check : dso.DsoCheck (dso.new-check (& req))]
                [version-span : elf.ElfSpan
                  (dso.version-name! (& object) i (&mut check))]
                [version-name : (__tl_dyn-array u8)
                  (copy-span data version-span.offset version-span.size)]
                [raw : i64
                  (match object.versions
                    [(Unversioned) 1]
                    [(Versioned _)
                      (le.read-u16
                        data
                        (+ (array-ref object.version-spans 0).offset (* i 2)))])]
                [expected : i64
                  (linear-index
                    (& object)
                    (& name)
                    (if (> version-span.size 0)
                      (bit-and raw 32767)
                      -1))]
                (when
                  (> object.sysv.span.size 0)
                  (assert-lookup
                    (& object)
                    (& name)
                    (& version-name)
                    expected
                    (& (dso.SysvHash))))
                (when
                  (> object.gnu.span.size 0)
                  (assert-lookup
                    (& object)
                    (& name)
                    (& version-name)
                    expected
                    (& (dso.GnuHash))))
                (assert-lookup
                  (& object)
                  (& name)
                  (& empty)
                  (linear-index (& object) (& name) -1)
                  (& (dso.PreferGnu)))))
            (set! i (+ i 1)))
          (assert-lookup
            (& object)
            (& missing)
            (& empty)
            -1
            (& (dso.PreferGnu)))
          (when
            (> object.sysv.span.size 0)
            (assert-lookup
              (& object)
              (& missing)
              (& empty)
              -1
              (& (dso.SysvHash))))
          (let
            [query : (dso.DsoLookupRequest missing empty)
              (dso.DsoLookupRequest (& missing) (& empty) (dso.PreferGnu) 0)]
            (test.assert-true
              (match (dso.lookup (& object) (& query))
                [(LookupFailed _) true]
                [_ false])
              "lookup work limit")))]))
  unit)

(define (lookup-tests) : unit
  (lookup-fixture (& gcc-both))
  (lookup-fixture (& gcc-gnu))
  (lookup-fixture (& gcc-sysv))
  (lookup-fixture (& clang-both))
  (lookup-fixture (& clang-gnu))
  (lookup-fixture (& clang-sysv))
  (lookup-fixture (& no-sections))
  (lookup-fixture (& musl)))

(define (set-limit!
  [_limits : (&mut l dso.DsoLimits)]
  [which : i64]
  [value : i64]) : unit
  (match which
    [0 (set! _limits.max-input-bytes value)]
    [1 (set! _limits.max-segments value)]
    [2 (set! _limits.max-sections value)]
    [3 (set! _limits.max-dynamic-entries value)]
    [4 (set! _limits.max-symbols value)]
    [5 (set! _limits.max-versions value)]
    [6 (set! _limits.max-string-bytes value)]
    [7 (set! _limits.max-retained-bytes value)]
    [_ (set! _limits.max-work value)])
  unit)

(define (limit-pass? [which : i64] [value : i64]) : bool
  (with-arena
    scratch
    (let
      [req : dso.DsoReadRequest (request)]
      (set-limit! (&mut req.limits) which value)
      (match (dso.read-dso (& gcc-both) (& req))
        [(ReadDso _) true]
        [(ReadFailed _) false]))))

(define (limit-tests) : unit
  (let
    [which : i64 0]
    (while (< which 9)
      (test.assert-true (not (limit-pass? which -1)) "negative caller limit")
      (let
        [low : i64 0]
        [high : i64 536870912]
        (while (< low high)
          (let
            [middle : i64 (+ low (/ (- high low) 2))]
            (if (limit-pass? which middle)
              (set! high middle)
              (set! low (+ middle 1)))))
        (test.assert-true (> low 0) "fixture exercises every caller resource")
        (test.assert-true (limit-pass? which low) "exact resource boundary")
        (test.assert-true
          (not (limit-pass? which (- low 1)))
          "one below resource boundary"))
      (set! which (+ which 1)))))

(define (minimal [size : i64]) : (__tl_dyn-array u8)
  (let
    [data : (__tl_dyn-array u8) (__tl_make-array u8 size)]
    (le.set-u32! (&mut data) 0 1179403647)
    (set! (array-ref data 4) (cast 2 : u8))
    (set! (array-ref data 5) (cast 1 : u8))
    (set! (array-ref data 6) (cast 1 : u8))
    (le.set-u16! (&mut data) 16 3)
    (le.set-u16! (&mut data) 18 62)
    (le.set-u32! (&mut data) 20 1)
    (le.set-u64! (&mut data) 32 64)
    (le.set-u16! (&mut data) 52 64)
    (le.set-u16! (&mut data) 54 56)
    (le.set-u16! (&mut data) 56 2)
    (le.set-u32! (&mut data) 64 1)
    (le.set-u64! (&mut data) 80 4194304)
    (le.set-u64! (&mut data) 96 313)
    (le.set-u64! (&mut data) 104 313)
    (le.set-u64! (&mut data) 112 4096)
    (le.set-u32! (&mut data) 120 2)
    (le.set-u64! (&mut data) 128 176)
    (le.set-u64! (&mut data) 136 4194480)
    (le.set-u64! (&mut data) 152 96)
    (le.set-u64! (&mut data) 160 96)
    (let
      [tags : (Array i64 5) (array 4 5 10 6 11)]
      [values : (Array i64 5) (array 4194576 4194616 1 4194592 24)]
      [i : i64 0]
      (while (< i 5)
        (le.set-u64! (&mut data) (+ 176 (* i 16)) (array-ref tags i))
        (le.set-u64! (&mut data) (+ 184 (* i 16)) (array-ref values i))
        (set! i (+ i 1))))
    (le.set-u32! (&mut data) 272 1)
    (le.set-u32! (&mut data) 276 1)
    data))

(define (truncation-tests) : unit
  (let
    [full : (__tl_dyn-array u8) (minimal 313)]
    [req : dso.DsoReadRequest (request)]
    [size : i64 0]
    (test.assert-true
      (match (dso.read-dso (& full) (& req))
        [(ReadDso _) true]
        [_ false])
      "nonzero virtual base")
    (while (< size 313)
      (with-arena
        scratch
        (let
          [data : (__tl_dyn-array u8) (copy-span (& full) 0 size)]
          (test.assert-true
            (match (dso.read-dso (& data) (& req))
              [(ReadFailed _) true]
              [_ false])
            "every incomplete prefix rejected")))
      (set! size (+ size 1)))
    (let
      [text : (__tl_dyn-array u8)
        (byte_buf.to-array (byte_buf.from-string "GROUP ( libc.so.6 )"))]
      (test.assert-true
        (match (dso.read-dso (& text) (& req))
          [(ReadFailed error)
            (match error.kind
              [(NotElf) true]
              [_ false])]
          [_ false])
        "not-ELF script dispatch"))))

(define (payload-allocation [size : i64]) : i64
  (let
    [data : (__tl_dyn-array u8) (minimal size)]
    [req : dso.DsoReadRequest (request)]
    [before : i64 (profile.alloc-total)]
    (match (dso.read-dso (& data) (& req))
      [(ReadFailed _) (test.assert-true false "borrowed payload")]
      [(ReadDso object)
        (test.assert-i64-eq
          (array-length object.bytes)
          size
          "complete input remains borrowed")
        (test.assert-i64-eq
          object.symbol-span.offset
          288
          "VA mapped to physical symbol bytes")])
    (- (profile.alloc-total) before)))

(define (payload-tests) : unit
  (test.assert-i64-eq
    (payload-allocation 313)
    (payload-allocation 1048576)
    "opaque file payload does not allocate")
  (cfg
    compile-profile
    (test.assert-true
      (> (payload-allocation 313) 0)
      "profile allocation counters are active")))

(defstruct Mutation
  (at i64)
  (width i64)
  (value i64)
  (field String)
  (offset i64))

(define (mutate!
  [data : (&mut b (__tl_dyn-array u8))]
  [at : i64]
  [width : i64]
  [value : i64]) : unit
  (match width
    [1 (set! (array-ref data at) (cast value : u8))]
    [2 (le.set-u16! data at value)]
    [4 (le.set-u32! data at value)]
    [_ (le.set-u64! data at value)])
  unit)

(define (assert-error
  [data : (& b (__tl_dyn-array u8))]
  [field : (& f str)]
  [offset : i64]) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso data (& req))
      [(ReadDso _) (test.assert-true false "malformed DSO accepted")]
      [(ReadFailed error)
        (test.assert-owned-string-eq
          error.field
          (string.copy field)
          "exact hostile field")
        (test.assert-i64-eq error.offset offset "exact hostile field offset")
        (test.assert-true
          (= error.identity.input (cast 41 : u64))
          "error input identity")
        (test.assert-true
          (= error.identity.content (cast 7 : u64))
          "error content revision")]))
  unit)

(define (malformed-tests) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso (& gcc-both) (& req))
      [(ReadFailed _) (test.assert-true false "mutation control")]
      [(ReadDso object)
        (let
          [first : i64 -1]
          [second : i64 -1]
          [dyn : i64 -1]
          [i : i64 0]
          [sym-section : i64 0]
          (while (< i (array-length object.segments))
            (when
              (= (array-ref object.segments i).kind 1)
              (if (< first 0)
                (set! first i)
                (when (< second 0) (set! second i))))
            (when (= (array-ref object.segments i).kind 2) (set! dyn i))
            (set! i (+ i 1)))
          (set! i 0)
          (while (< i object.header.section-count)
            (let
              [section : elf.ElfSection
                (elf.section-at
                  (& gcc-both)
                  (& object.header)
                  (& object.identity)
                  i)]
              (when (= section.section-type 11) (set! sym-section i)))
            (set! i (+ i 1)))
          (let
            [load-at : i64 (array-ref object.segments first).offset]
            [second-at : i64 (array-ref object.segments second).offset]
            [dyn-at : i64 (array-ref object.segments dyn).offset]
            [str-at : i64 (dso.tag-offset (& object.entries) dynamic.dt-strtab)]
            [strsz-at : i64
              (dso.tag-offset (& object.entries) dynamic.dt-strsz)]
            [versym-at : i64 (array-ref object.version-spans 0).offset]
            [verdef-at : i64 (array-ref object.version-spans 1).offset]
            [verneed-at : i64 (array-ref object.version-spans 2).offset]
            [sysv-chain : i64
              (+
                object.sysv.chain-offset
                (* (le.read-u32 (& gcc-both) object.sysv.bucket-offset) 4))]
            [cases : (Array Mutation 30)
              (array
                (Mutation 0 1 0 "ELF.magic" 0)
                (Mutation 4 1 1 "EI_CLASS" 4)
                (Mutation 5 1 2 "EI_DATA" 5)
                (Mutation 18 2 3 "e_machine" 18)
                (Mutation 16 2 2 "e_type" 16)
                (Mutation 32 8 -1 "program-table" 32)
                (Mutation 40 8 -1 "e_shoff" 40)
                (Mutation (+ load-at 32) 8 -1 "p_filesz" (+ load-at 32))
                (Mutation (+ load-at 16) 8 -1 "p_memsz-overflow" (+ load-at 40))
                (Mutation
                  (+ second-at 16)
                  8
                  (cast (array-ref object.segments first).address : i64)
                  "PT_LOAD-overlap"
                  (+ second-at 16))
                (Mutation
                  (+ second-at 8)
                  8
                  0
                  "PT_LOAD-file-overlap"
                  (+ second-at 8))
                (Mutation str-at 8 -1 "DT_STRTAB" str-at)
                (Mutation strsz-at 8 32768 "DT_STRSZ" strsz-at)
                (Mutation strsz-at 8 0 "DT_STRSZ-empty" strsz-at)
                (Mutation
                  (- (+ object.strings.offset object.strings.size) 1)
                  1
                  1
                  "dynstr-boundaries"
                  object.strings.offset)
                (Mutation
                  (+ dyn-at 32)
                  8
                  (* (- (array-length object.entries) 1) 16)
                  "DT_NULL"
                  (+
                    object.dynamic-span.offset
                    (* (- (array-length object.entries) 1) 16)))
                (Mutation
                  object.sysv.span.offset
                  4
                  0
                  "DT_HASH"
                  object.sysv.span.offset)
                (Mutation
                  (+ object.sysv.span.offset 4)
                  4
                  -1
                  "symbol-limit"
                  (+ object.sysv.span.offset 4))
                (Mutation
                  sysv-chain
                  4
                  (le.read-u32 (& gcc-both) object.sysv.bucket-offset)
                  "hash-cycle-or-overlap"
                  sysv-chain)
                (Mutation
                  (+ object.gnu.span.offset 8)
                  4
                  0
                  "GNU-hash-header"
                  (+ object.gnu.span.offset 4))
                (Mutation
                  object.gnu.chain-offset
                  4
                  (bit-xor (le.read-u32 (& gcc-both) object.gnu.chain-offset) 2)
                  "GNU-hash-value"
                  object.gnu.chain-offset)
                (Mutation
                  (+ object.gnu.span.offset 16)
                  8
                  0
                  "GNU-hash-bloom"
                  (+ object.gnu.span.offset 16))
                (Mutation (+ versym-at 2) 2 32767 "versym" (+ versym-at 2))
                (Mutation (+ verdef-at 16) 4 0 "vd_next" (+ verdef-at 16))
                (Mutation (+ verdef-at 16) 4 -1 "vd_next" (+ verdef-at 16))
                (Mutation
                  (dso.tag-offset (& object.entries) dynamic.dt-verneednum)
                  8
                  2
                  "vn_next"
                  (+ verneed-at 12))
                (Mutation
                  (+ object.header.section-offset (* sym-section 64) 24)
                  8
                  (+ object.symbol-span.offset 1)
                  "section-dynamic-disagreement"
                  (+ object.header.section-offset (* sym-section 64) 24))
                (Mutation
                  (+ object.symbol-span.offset 24)
                  4
                  object.strings.size
                  "dynstr-index"
                  (+ object.symbol-span.offset 24))
                (Mutation
                  (dso.tag-offset (& object.entries) dynamic.dt-syment)
                  8
                  23
                  "dynamic-required-tags"
                  object.dynamic-span.offset)
                (Mutation
                  (+ object.sysv.span.offset 4)
                  4
                  (- object.sysv.symbol-count 1)
                  "hash-symbol-count"
                  object.dynamic-span.offset))]
            (set! i 0)
            (while (< i 30)
              (with-arena
                scratch
                (let
                  [mutation : (& cases Mutation) (& (array-ref cases i))]
                  [data : (__tl_dyn-array u8) (clone gcc-both)]
                  (mutate!
                    (&mut data)
                    mutation.at
                    mutation.width
                    mutation.value)
                  (assert-error (& data) mutation.field mutation.offset)))
              (set! i (+ i 1)))
            (let
              [data : (__tl_dyn-array u8) (clone gcc-both)]
              [at : i64 (- (dso.tag-offset (& object.entries) 20) 8)]
              (le.set-u64! (&mut data) at dynamic.dt-syment)
              (assert-error (& data) "duplicate-DT-tag" at))))]))
  unit)

(define (lookup-boundary-tests) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    [api : (__tl_dyn-array u8) (byte_buf.to-array (byte_buf.from-string "api"))]
    [wrong : (__tl_dyn-array u8)
      (byte_buf.to-array (byte_buf.from-string "NO_VERSION"))]
    [empty : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    [embedded : (__tl_dyn-array u8)
      (byte_buf.to-array (byte_buf.from-string "api\0tail"))]
    (match (dso.read-dso (& gcc-both) (& req))
      [(ReadFailed _) (test.assert-true false "version boundary control")]
      [(ReadDso object)
        (assert-lookup (& object) (& api) (& wrong) -1 (& (dso.PreferGnu)))
        (assert-lookup (& object) (& embedded) (& empty) -1 (& (dso.PreferGnu)))
        (test.assert-true (= object.flags (cast 8 : u64)) "DT_FLAGS retained")
        (test.assert-true
          (= object.flags-1 (cast 9 : u64))
          "DT_FLAGS_1 retained")
        (test.assert-owned-string-eq
          (dump.name object.bytes (& object.soname))
          "libfixture.so"
          "soname retained")])
    (match (dso.read-dso (& gcc-gnu) (& req))
      [(ReadFailed _) (test.assert-true false "GNU-only control")]
      [(ReadDso object)
        (let
          [query : (dso.DsoLookupRequest api empty)
            (dso.DsoLookupRequest (& api) (& empty) (dso.SysvHash) 1048576)]
          (test.assert-true
            (match (dso.lookup (& object) (& query))
              [(LookupFailed _) true]
              [_ false])
            "missing requested hash is explicit"))])))

(define (chain-and-pointer-tests) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso (& gcc-both) (& req))
      [(ReadFailed _) (test.assert-true false "chain mutation control")]
      [(ReadDso object)
        (let
          [i : i64 0]
          (while (< i (array-length object.entries))
            (let
              [entry : (& object dso.DsoDynamic)
                (& (array-ref object.entries i))]
              (when
                (dynamic.pointer-tag? entry.tag)
                (with-arena
                  scratch
                  (let
                    [data : (__tl_dyn-array u8) (clone gcc-both)]
                    [field : String (dynamic.pointer-field entry.tag)]
                    (le.set-u64! (&mut data) (+ entry.offset 8) -1)
                    (assert-error (& data) field (+ entry.offset 8))))))
            (set! i (+ i 1))))
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          [check : dso.DsoCheck (dso.new-check (& req))]
          [tail : elf.ElfSpan
            (dso.mapped-tail!
              (& object.segments)
              (dso.tag-value (& object.entries) dynamic.dt-gnu-hash)
              (&mut check)
              "probe"
              0)]
          [end : i64 (+ tail.offset tail.size)]
          [at : i64 object.gnu.chain-offset]
          (while (<= (+ at 4) end)
            (le.set-u32! (&mut data) at 0)
            (set! at (+ at 4)))
          (assert-error (& data) "GNU-hash-chain" at))
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          (le.set-u32! (&mut data) object.gnu.bucket-offset -1)
          (assert-error (& data) "symbol-limit" object.gnu.bucket-offset))
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          (le.set-u32!
            (&mut data)
            (+ object.sysv.chain-offset 4)
            object.sysv.symbol-count)
          (assert-error
            (& data)
            "SysV-hash-chain"
            (+ object.sysv.chain-offset 4)))
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          (le.set-u32!
            (&mut data)
            (+ (array-ref object.version-spans 1).offset 12)
            -1)
          (assert-error
            (& data)
            "vd_aux"
            (+ (array-ref object.version-spans 1).offset 12)))]))
  unit)

(define (mutation-corpus-tests) : unit
  (let
    [positions : (Array i64 24)
      (array
        4
        5
        7
        16
        18
        32
        40
        54
        56
        58
        60
        64
        72
        80
        96
        104
        112
        120
        128
        136
        152
        176
        184
        276)]
    [values : (Array i64 8) (array -1 -2147483648 0 1 2 3 65535 2147483647)]
    [req : dso.DsoReadRequest (request)]
    [i : i64 0]
    (while (< i 24)
      (let
        [j : i64 0]
        (while (< j 8)
          (with-arena
            scratch
            (let
              [data : (__tl_dyn-array u8) (minimal 313)]
              (le.set-u32!
                (&mut data)
                (array-ref positions i)
                (array-ref values j))
              (match (dso.read-dso (& data) (& req))
                [(ReadFailed _) unit]
                [(ReadDso object)
                  (test.assert-true
                    (elf.file-range?
                      (array-length data)
                      (cast object.strings.offset : u64)
                      (cast object.strings.size : u64))
                    "accepted string span bounded")
                  (test.assert-true
                    (elf.file-range?
                      (array-length data)
                      (cast object.symbol-span.offset : u64)
                      (cast object.symbol-span.size : u64))
                    "accepted symbol span bounded")
                  (test.assert-true
                    (elf.file-range?
                      (array-length data)
                      (cast object.dynamic-span.offset : u64)
                      (cast object.dynamic-span.size : u64))
                    "accepted dynamic span bounded")])))
          (set! j (+ j 1))))
      (set! i (+ i 1)))))

(define (numbering-and-empty-tests) : unit
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso (& gcc-both) (& req))
      [(ReadFailed _) (test.assert-true false "numbering control")]
      [(ReadDso object)
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          (le.set-u16! (&mut data) 56 65535)
          (le.set-u16! (&mut data) 60 0)
          (le.set-u16! (&mut data) 62 65535)
          (le.set-u64!
            (&mut data)
            (+ object.header.section-offset 32)
            object.header.section-count)
          (le.set-u32!
            (&mut data)
            (+ object.header.section-offset 40)
            object.header.name-table)
          (le.set-u32!
            (&mut data)
            (+ object.header.section-offset 44)
            (array-length object.segments))
          (assert-fixture (& data) (& gcc-both-oracle) true))
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          [i : i64 0]
          [found : bool false]
          (while (< i (array-length object.segments))
            (let
              [segment : (& object dso.DsoSegment)
                (& (array-ref object.segments i))]
              (when
                (and
                  (= segment.kind 1685382481)
                  (= segment.file-size (cast 0 : u64))
                  (= segment.memory-size (cast 0 : u64)))
                (set! found true)
                (le.set-u32! (&mut data) segment.offset 1)))
            (set! i (+ i 1)))
          (test.assert-true found "empty GNU_STACK producer control")
          (assert-fixture (& data) (& gcc-both-oracle) true))
        (let
          [data : (__tl_dyn-array u8) (clone gcc-both)]
          (le.set-u64! (&mut data) (+ object.header.section-offset 32) 1)
          (assert-error
            (& data)
            "section-zero-size"
            (+ object.header.section-offset 32)))])))

(define (empty-gnu-tests) : unit
  (assert-fixture (& empty-gnu) (& empty-gnu-oracle) true)
  (assert-fixture (& empty-both) (& empty-both-oracle) true)
  (lookup-fixture (& empty-gnu))
  (lookup-fixture (& empty-both))
  (let
    [req : dso.DsoReadRequest (request)]
    (match (dso.read-dso (& empty-gnu) (& req))
      [(ReadFailed _)
        (test.assert-true false "empty GNU table with section count")]
      [(ReadDso object)
        (test.assert-i64-eq
          object.gnu.chain-count
          0
          "empty GNU hash contains no chains")
        (test.assert-true
          (> object.gnu.symbol-count object.gnu.symbol-offset)
          "undefined prefix exceeds GNU symoffset")
        (test.assert-i64-eq
          object.gnu.symbol-count
          (array-length object.symbols)
          "complete symbol count")
        (let
          [data : (__tl_dyn-array u8) (clone empty-gnu)]
          (le.set-u64! (&mut data) 40 0)
          (le.set-u16! (&mut data) 58 0)
          (le.set-u16! (&mut data) 60 0)
          (le.set-u16! (&mut data) 62 0)
          (assert-error
            (& data)
            "GNU-empty-symbol-count"
            (+ object.gnu.span.offset 4))
          (test.assert-true
            (match (dso.read-dso (& data) (& req))
              [(ReadFailed error)
                (match error.kind
                  [(UnsupportedMetadata) true]
                  [_ false])]
              [_ false])
            "ambiguous total count is explicit unsupported metadata"))])
    (let
      [data : (__tl_dyn-array u8) (clone empty-both)]
      (le.set-u64! (&mut data) 40 0)
      (le.set-u16! (&mut data) 58 0)
      (le.set-u16! (&mut data) 60 0)
      (le.set-u16! (&mut data) 62 0)
      (assert-fixture (& data) (& empty-both-oracle) true))))

(define (self-test) : i64
  (producer-tests)
  (lookup-tests)
  (limit-tests)
  (truncation-tests)
  (payload-tests)
  (malformed-tests)
  (lookup-boundary-tests)
  (chain-and-pointer-tests)
  (mutation-corpus-tests)
  (numbering-and-empty-tests)
  (empty-gnu-tests)
  42)

(test elf-dso-producer-records (producer-tests))

(test elf-dso-hash-lookups-vs-linear-scan (lookup-tests))

(test elf-dso-caller-resource-boundaries (limit-tests))

(test elf-dso-every-truncated-prefix-and-script-dispatch (truncation-tests))

(test elf-dso-borrowed-payload-allocation (payload-tests))

(test elf-dso-malformed-pointers-hashes-versions-and-sections (malformed-tests))

(test elf-dso-lookup-version-nul-and-unavailable-hash (lookup-boundary-tests))

(test
  elf-dso-truncated-gnu-chains-and-every-dynamic-pointer
  (chain-and-pointer-tests))

(test elf-dso-finite-hostile-wire-corpus (mutation-corpus-tests))

(test elf-dso-extended-numbering-and-empty-loads (numbering-and-empty-tests))

(test elf-dso-empty-gnu-hash-undefined-count-and-ambiguity (empty-gnu-tests))