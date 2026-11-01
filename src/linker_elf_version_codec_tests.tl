(import stdlib.iterator)
(import linker_elf_version_codec as codec)
(import stdlib.byte_le as le)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)

(include-bin gnu-def-str "../tests/fixtures/elf-dynamic/ld-a.dynstr.expected")

(include-bin
  gnu-def-sym
  "../tests/fixtures/elf-dynamic/ld-a.gnu.version.expected")

(include-bin
  gnu-def
  "../tests/fixtures/elf-dynamic/ld-a.gnu.version_d.expected")

(include-bin
  gnu-need-str
  "../tests/fixtures/elf-dynamic/ld-use.dynstr.expected")

(include-bin
  gnu-need-sym
  "../tests/fixtures/elf-dynamic/ld-use.gnu.version.expected")

(include-bin
  gnu-need
  "../tests/fixtures/elf-dynamic/ld-use.gnu.version_r.expected")

(include-bin
  lld-def-str
  "../tests/fixtures/elf-dynamic/ld.lld-a.dynstr.expected")

(include-bin
  lld-def-sym
  "../tests/fixtures/elf-dynamic/ld.lld-a.gnu.version.expected")

(include-bin
  lld-def
  "../tests/fixtures/elf-dynamic/ld.lld-a.gnu.version_d.expected")

(include-bin
  lld-need-str
  "../tests/fixtures/elf-dynamic/ld.lld-use.dynstr.expected")

(include-bin
  lld-need-sym
  "../tests/fixtures/elf-dynamic/ld.lld-use.gnu.version.expected")

(include-bin
  lld-need
  "../tests/fixtures/elf-dynamic/ld.lld-use.gnu.version_r.expected")

(include-bin
  lld23-need-str
  "../tests/fixtures/elf-dynamic/lld23-use.dynstr.expected")

(include-bin
  lld23-need-sym
  "../tests/fixtures/elf-dynamic/lld23-use.gnu.version.expected")

(include-bin
  lld23-need
  "../tests/fixtures/elf-dynamic/lld23-use.gnu.version_r.expected")

(define (assert [ok : bool] [message : String]) : unit
  (unless ok (io.panic message)))

(define (copy-bytes [data : (& d (__tl_dyn-array u8))] [size : i64]) : (__tl_dyn-array
    u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 size)]
    (for [i (iterator.range 0 size)]
      (set! (array-ref out i) (array-ref data i)))
    out))

(define (same? [a : (& a (__tl_dyn-array u8))] [b : (& b (__tl_dyn-array u8))]) : bool
  (let
    [ok : bool (= (array-length a) (array-length b))]
    [i : i64 0]
    (while (and ok (< i (array-length a)))
      (set! ok (= (array-ref a i) (array-ref b i)))
      (+= i 1))
    ok))

(define (fixture [lld : bool] [definitions : bool]) : codec.DecodeRequest
  (let
    [sym : (__tl_dyn-array u8)
      (if definitions
        (if lld
          (copy-bytes (& lld-def-sym) (array-length lld-def-sym))
          (copy-bytes (& gnu-def-sym) (array-length gnu-def-sym)))
        (if lld
          (copy-bytes (& lld-need-sym) (array-length lld-need-sym))
          (copy-bytes (& gnu-need-sym) (array-length gnu-need-sym))))]
    [data : (__tl_dyn-array u8)
      (if definitions
        (if lld
          (copy-bytes (& lld-def) (array-length lld-def))
          (copy-bytes (& gnu-def) (array-length gnu-def)))
        (if lld
          (copy-bytes (& lld-need) (array-length lld-need))
          (copy-bytes (& gnu-need) (array-length gnu-need))))]
    [dynstr : (__tl_dyn-array u8)
      (if definitions
        (if lld
          (copy-bytes (& lld-def-str) (array-length lld-def-str))
          (copy-bytes (& gnu-def-str) (array-length gnu-def-str)))
        (if lld
          (copy-bytes (& lld-need-str) (array-length lld-need-str))
          (copy-bytes (& gnu-need-str) (array-length gnu-need-str))))]
    [count : i64 (/ (array-length sym) 2)]
    (codec.DecodeRequest
      (if definitions
        (codec.VersionBytes sym data (__tl_make-array u8 0))
        (codec.VersionBytes sym (__tl_make-array u8 0) data))
      dynstr
      count
      (if definitions
        4
        0)
      (if definitions
        0
        2)
      true
      (codec.default-limits))))

(define (round-trip [request : (& r codec.DecodeRequest)]) : unit
  (match (codec.decode request)
    [(Err error) (io.panic (cat.str-cat "decode: " error.field))]
    [(Ok versions)
      (match (codec.encode
        (& versions)
        (& request.dynstr)
        request.require-base
        (codec.default-limits))
        [(Err error) (io.panic (cat.str-cat "encode: " error.field))]
        [(Ok bytes)
          (assert
            (same? (& bytes.symbols) (& request.bytes.symbols))
            "versym bytes")
          (assert
            (same? (& bytes.definitions) (& request.bytes.definitions))
            "verdef bytes")
          (assert
            (same? (& bytes.needs) (& request.bytes.needs))
            "verneed bytes")])]))

(test
  elf-version-producer-layouts
  (for [producer (iterator.range 0 2)]
    (let
      [definitions : codec.DecodeRequest (fixture (= producer 1) true)]
      [needs : codec.DecodeRequest (fixture (= producer 1) false)]
      (round-trip (& definitions))
      (round-trip (& needs))
      (match (codec.decode (& definitions))
        [(Err _) (io.panic "definitions")]
        [(Ok decoded)
          (assert
            (=
              (array-ref decoded.definitions.records.slots 0).flags
              codec.flag-base)
            "base flag")
          (assert
            (= (array-ref decoded.definitions.records.slots 2).index 3)
            "V2 index")
          (assert
            (=
              (array-ref decoded.definitions.records.slots 2).aux.len
              (if (= producer 1)
                1
                2))
            "producer inheritance")
          (assert
            (= (cast (array-ref decoded.symbols 2) : i64) 32770)
            "hidden V1 symbol")])
      (match (codec.decode (& needs))
        [(Err _) (io.panic "needs")]
        [(Ok decoded)
          (assert (= decoded.needs.records.len 2) "two providers")
          (assert
            (=
              (array-ref decoded.needs.records.slots 1).offset
              (if (= producer 1)
                16
                32))
            "producer header placement")
          (assert
            (=
              (array-ref (array-ref decoded.needs.records.slots 0).aux.slots 0).offset
              (if (= producer 1)
                32
                16))
            "producer aux placement")]))))

(defstruct BadField
  (definitions bool)
  (section i64)
  (offset i64)
  (width i64)
  (value i64)
  (field String))

(define (expect-error [request : (& r codec.DecodeRequest)] [field : (& f str)]) : unit
  (match (codec.decode request)
    [(Ok _) (io.panic (cat.str-cat "accepted bad " (string.copy field)))]
    [(Err error)
      (assert
        (string.eq error.field field)
        (cat.str-cat "wanted " (string.copy field) ", got " error.field))]))

(test
  elf-version-invalid-fields
  (let
    [cases : (__tl_dyn-array BadField) (__tl_make-array BadField 14)]
    (set! (array-ref cases 0) (BadField true 0 0 2 7 "versym"))
    (set! (array-ref cases 1) (BadField true 1 0 2 2 "vd_version"))
    (set! (array-ref cases 2) (BadField true 1 6 2 0 "vd_cnt"))
    (set! (array-ref cases 3) (BadField true 1 6 2 2 "vd_cnt"))
    (set! (array-ref cases 4) (BadField true 1 16 4 0 "vd_next"))
    (set! (array-ref cases 5) (BadField true 1 16 4 4294967295 "vd_next"))
    (set! (array-ref cases 6) (BadField true 1 8 4 1 "vd_hash"))
    (set! (array-ref cases 7) (BadField true 1 2 2 0 "vd_ndx"))
    (set! (array-ref cases 8) (BadField false 2 2 2 0 "vn_cnt"))
    (set! (array-ref cases 9) (BadField false 2 2 2 2 "vn_cnt"))
    (set! (array-ref cases 10) (BadField false 2 12 4 0 "vn_next"))
    (set! (array-ref cases 11) (BadField false 2 12 4 4294967295 "vn_next"))
    (set! (array-ref cases 12) (BadField false 2 16 4 1 "vna_hash"))
    (set! (array-ref cases 13) (BadField false 2 4 4 4294967295 "vn_file"))
    (for [i (iterator.range 0 (array-length cases))]
      (let
        [case : (& cases BadField) (& (array-ref cases i))]
        [request : codec.DecodeRequest (fixture false case.definitions)]
        (cond
          [(= case.section 0)
            (le.set-u16! (&mut request.bytes.symbols) case.offset case.value)]
          [(= case.section 1)
            (if (= case.width 2)
              (le.set-u16!
                (&mut request.bytes.definitions)
                case.offset
                case.value)
              (le.set-u32!
                (&mut request.bytes.definitions)
                case.offset
                case.value))]
          [else
            (if (= case.width 2)
              (le.set-u16! (&mut request.bytes.needs) case.offset case.value)
              (le.set-u32! (&mut request.bytes.needs) case.offset case.value))])
        (expect-error (& request) case.field)))
    (let
      [request : codec.DecodeRequest (fixture false true)]
      (le.set-u16! (&mut request.bytes.definitions) 2 0)
      (le.set-u16! (&mut request.bytes.definitions) 4 5)
      (expect-error (& request) "vd_flags: missing VER_FLG_BASE"))))

(test
  elf-version-truncation-and-limits
  (for [producer (iterator.range 0 2)]
    (for [kind (iterator.range 0 2)]
      (let
        [original : codec.DecodeRequest (fixture (= producer 1) (= kind 0))]
        [size : i64
          (if (= kind 0)
            (array-length original.bytes.definitions)
            (array-length original.bytes.needs))]
        (for [i (iterator.range 0 size)]
          (let
            [request : codec.DecodeRequest (fixture (= producer 1) (= kind 0))]
            (if (= kind 0)
              (set!
                request.bytes.definitions
                (copy-bytes (& original.bytes.definitions) i))
              (set! request.bytes.needs (copy-bytes (& original.bytes.needs) i)))
            (match (codec.decode (& request))
              [(Ok _) (io.panic "accepted truncated section")]
              [(Err _) unit]))))))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.limits.max-work 0)
    (expect-error (& request) "work-limit"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.limits.max-aux 0)
    (expect-error (& request) "vd_cnt")))

(test
  elf-version-flags-and-padding
  (let
    [request : codec.DecodeRequest
      (codec.DecodeRequest
        (codec.VersionBytes
          (copy-bytes (& lld23-need-sym) (array-length lld23-need-sym))
          (__tl_make-array u8 0)
          (copy-bytes (& lld23-need) (array-length lld23-need)))
        (copy-bytes (& lld23-need-str) (array-length lld23-need-str))
        5
        0
        2
        true
        (codec.default-limits))]
    (round-trip (& request))
    (match (codec.decode (& request))
      [(Err _) (io.panic "lld 23 weak fixture")]
      [(Ok versions)
        (assert
          (=
            (array-ref (array-ref versions.needs.records.slots 0).aux.slots 0).flags
            0)
          "non-weak provider")
        (assert
          (=
            (array-ref (array-ref versions.needs.records.slots 1).aux.slots 0).flags
            codec.flag-weak)
          "weak provider")]))
  (let
    [request : codec.DecodeRequest (fixture true false)]
    (le.set-u16! (&mut request.bytes.needs) 36 codec.flag-weak)
    (le.set-u16! (&mut request.bytes.needs) 38 32770)
    (round-trip (& request)))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (match (codec.decode (& request))
      [(Err _) (io.panic "padding fixture")]
      [(Ok versions)
        (set! (array-ref versions.definitions.padding 0) (cast 7 : u8))
        (match (codec.encode
          (& versions)
          (& request.dynstr)
          true
          (codec.default-limits))
          [(Ok _) (io.panic "accepted padding over record")]
          [(Err error)
            (assert
              (string.eq error.field "padding-overlap")
              "padding diagnostic")])])))

(include-bin
  gnu-client-str
  "../tests/fixtures/elf-dynamic/ld-client.dynstr.expected")

(include-bin
  gnu-client-sym
  "../tests/fixtures/elf-dynamic/ld-client.gnu.version.expected")

(include-bin
  gnu-client-def
  "../tests/fixtures/elf-dynamic/ld-client.gnu.version_d.expected")

(include-bin
  gnu-client-need
  "../tests/fixtures/elf-dynamic/ld-client.gnu.version_r.expected")

(include-bin
  lld-client-str
  "../tests/fixtures/elf-dynamic/ld.lld-client.dynstr.expected")

(include-bin
  lld-client-sym
  "../tests/fixtures/elf-dynamic/ld.lld-client.gnu.version.expected")

(include-bin
  lld-client-def
  "../tests/fixtures/elf-dynamic/ld.lld-client.gnu.version_d.expected")

(include-bin
  lld-client-need
  "../tests/fixtures/elf-dynamic/ld.lld-client.gnu.version_r.expected")

(test
  elf-version-combined-namespace
  (for [producer (iterator.range 0 2)]
    (let
      [request : codec.DecodeRequest
        (codec.DecodeRequest
          (codec.VersionBytes
            (if (= producer 0)
              (copy-bytes (& gnu-client-sym) (array-length gnu-client-sym))
              (copy-bytes (& lld-client-sym) (array-length lld-client-sym)))
            (if (= producer 0)
              (copy-bytes (& gnu-client-def) (array-length gnu-client-def))
              (copy-bytes (& lld-client-def) (array-length lld-client-def)))
            (if (= producer 0)
              (copy-bytes (& gnu-client-need) (array-length gnu-client-need))
              (copy-bytes (& lld-client-need) (array-length lld-client-need))))
          (if (= producer 0)
            (copy-bytes (& gnu-client-str) (array-length gnu-client-str))
            (copy-bytes (& lld-client-str) (array-length lld-client-str)))
          (if (= producer 0)
            6
            5)
          2
          2
          true
          (codec.default-limits))]
      (round-trip (& request))
      (le.set-u16!
        (&mut request.bytes.needs)
        (if (= producer 0)
          22
          38)
        2)
      (expect-error (& request) "vna_other"))))

(test
  elf-version-model-and-padding-boundaries
  (let
    [request : codec.DecodeRequest (fixture false true)]
    [original : i64 (array-length request.bytes.definitions)]
    [padded : (__tl_dyn-array u8) (__tl_make-array u8 (+ original 3))]
    (for [i (iterator.range 0 original)]
      (set! (array-ref padded i) (array-ref request.bytes.definitions i)))
    (set! (array-ref padded (+ original 1)) (cast 99 : u8))
    (set! request.bytes.definitions padded)
    (round-trip (& request)))
  (for [i (iterator.range 0 5)]
    (let
      [request : codec.DecodeRequest (fixture false true)]
      (match (codec.decode (& request))
        [(Err _) (io.panic "model fixture")]
        [(Ok versions)
          (cond
            [(= i 0)
              (set! versions.definitions.records.len 9223372036854775807)]
            [(= i 1)
              (set!
                (array-ref versions.definitions.records.slots 0).aux.len
                9223372036854775807)]
            [(= i 2)
              (set! (array-ref versions.definitions.records.slots 0).offset 1)]
            [(= i 3)
              (set!
                (array-ref
                  (array-ref versions.definitions.records.slots 0).aux.slots
                  0).offset
                -1)]
            [else
              (set!
                (array-ref
                  (array-ref versions.definitions.records.slots 0).aux.slots
                  0).name
                9223372036854775807)])
          (match (codec.encode
            (& versions)
            (& request.dynstr)
            true
            (codec.default-limits))
            [(Ok _) (io.panic "accepted malformed model")]
            [(Err _) unit])])))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (le.set-u16! (&mut request.bytes.symbols) 0 32769)
    (expect-error (& request) "versym")))

(test
  elf-version-size-and-name-boundaries
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.symbol-count -1)
    (expect-error (& request) "versym-size"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.limits.max-bytes 0)
    (expect-error (& request) "dynstr"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.limits.max-records 3)
    (expect-error (& request) "record-count"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.limits.max-name-bytes 0)
    (expect-error (& request) "vda_name"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (le.set-u32! (&mut request.bytes.definitions) 20 0)
    (expect-error (& request) "vda_name"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (le.set-u32! (&mut request.bytes.definitions) 12 1)
    (expect-error (& request) "vda_next"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (le.set-u32! (&mut request.bytes.definitions) 24 1)
    (expect-error (& request) "vd_cnt"))
  (let
    [request : codec.DecodeRequest (fixture false false)]
    (set! request.need-count 3)
    (expect-error (& request) "vn_next")))

(test
  elf-version-empty-and-dynstr-boundaries
  (let
    [request : codec.DecodeRequest
      (codec.DecodeRequest
        (codec.VersionBytes
          (__tl_make-array u8 0)
          (__tl_make-array u8 0)
          (__tl_make-array u8 0))
        (__tl_make-array u8 0)
        0
        0
        0
        true
        (codec.VersionLimits 0 0 0 0 0))]
    (round-trip (& request)))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! (array-ref request.dynstr 0) (cast 65 : u8))
    (expect-error (& request) "dynstr"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set!
      (array-ref request.dynstr (- (array-length request.dynstr) 1))
      (cast 65 : u8))
    (expect-error (& request) "dynstr"))
  (let
    [request : codec.DecodeRequest (fixture false true)]
    (set! request.limits.max-work -1)
    (expect-error (& request) "limits")))

(include-bin
  gnu-many-str
  "../tests/fixtures/elf-dynamic/ld-many.dynstr.expected")

(include-bin
  gnu-many-sym
  "../tests/fixtures/elf-dynamic/ld-many.gnu.version.expected")

(include-bin
  gnu-many-need
  "../tests/fixtures/elf-dynamic/ld-many.gnu.version_r.expected")

(include-bin
  lld-many-str
  "../tests/fixtures/elf-dynamic/ld.lld-many.dynstr.expected")

(include-bin
  lld-many-sym
  "../tests/fixtures/elf-dynamic/ld.lld-many.gnu.version.expected")

(include-bin
  lld-many-need
  "../tests/fixtures/elf-dynamic/ld.lld-many.gnu.version_r.expected")

(test
  elf-version-multiple-needs-per-provider
  (for [producer (iterator.range 0 2)]
    (let
      [request : codec.DecodeRequest
        (codec.DecodeRequest
          (codec.VersionBytes
            (if (= producer 0)
              (copy-bytes (& gnu-many-sym) (array-length gnu-many-sym))
              (copy-bytes (& lld-many-sym) (array-length lld-many-sym)))
            (__tl_make-array u8 0)
            (if (= producer 0)
              (copy-bytes (& gnu-many-need) (array-length gnu-many-need))
              (copy-bytes (& lld-many-need) (array-length lld-many-need))))
          (if (= producer 0)
            (copy-bytes (& gnu-many-str) (array-length gnu-many-str))
            (copy-bytes (& lld-many-str) (array-length lld-many-str)))
          5
          0
          2
          true
          (codec.default-limits))]
      (round-trip (& request))
      (match (codec.decode (& request))
        [(Err _) (io.panic "multiple need fixture")]
        [(Ok versions)
          (assert
            (=
              (array-ref
                versions.needs.records.slots
                (if (= producer 0)
                  1
                  0)).aux.len
              2)
            "two versions from liba.so")])
      (le.set-u32!
        (&mut request.bytes.needs)
        (if (= producer 0)
          60
          44)
        0)
      (expect-error (& request) "vn_cnt"))))