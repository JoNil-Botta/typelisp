;; Pure GNU ELF version sections for #8293 and #7042. Physical offsets belong
;; to the model: GNU ld interleaves headers and auxiliaries, while lld groups
;; Verneed headers first. Padding contains only bytes outside modeled records.
(import stdlib.byte_le as le)
(import stdlib.byte_reader as reader)
(import stdlib.vector)
(import stdlib.string)

(define flag-base : i64
  1)
(define flag-weak : i64
  2)
(define index-hidden : i64
  32768)
(define index-mask : i64
  32767)

(defstruct VersionLimits
  (max-bytes i64)
  (max-records i64)
  (max-aux i64)
  (max-name-bytes i64)
  (max-work i64))

(define (default-limits) : VersionLimits
  (VersionLimits 1048576 4096 16384 4096 16777216))

;; For Verdaux only offset/name are used; flags/index must be zero.
(defstruct VersionAux
  (offset i64)
  (name i64)
  (flags i64)
  (index i64))

(import (vector.vector VersionAux core) as aux_vec)

;; Verdef uses flags/index, Verneed uses file. Unused fields must be zero.
;; Auxiliaries and records are in chain order, not necessarily adjacent.
(defstruct VersionRecord
  (offset i64)
  (flags i64)
  (index i64)
  (file i64)
  (aux aux_vec.Vec))

(import (vector.vector VersionRecord core) as record_vec)

(defstruct VersionSection
  (padding (__tl_dyn-array u8))
  (records record_vec.Vec))

(defstruct Versions
  (symbols (__tl_dyn-array u16))
  (definitions VersionSection)
  (needs VersionSection))

(defstruct VersionBytes
  (symbols (__tl_dyn-array u8))
  (definitions (__tl_dyn-array u8))
  (needs (__tl_dyn-array u8)))

(defstruct VersionError
  (field String)
  (offset i64))

(defenum VersionDecodeResult
  (Ok Versions)
  (Err VersionError))

(defenum VersionEncodeResult
  (Ok VersionBytes)
  (Err VersionError))

;; Counts come from dynsym and the section/dynamic metadata. Requiring them
;; makes a prematurely terminated header chain an error, including count zero.
(defstruct DecodeRequest
  (bytes VersionBytes)
  (dynstr (__tl_dyn-array u8))
  (symbol-count i64)
  (definition-count i64)
  (need-count i64)
  (require-base bool)
  (limits VersionLimits))

(defstruct VersionCheck
  (ok bool)
  (error VersionError)
  (left i64)
  (limits VersionLimits))

(define (require!
  [check : (&mut c VersionCheck)]
  [valid : bool]
  [field : (& f str)]
  [offset : i64]) : unit
  (when
    (and check.ok (not valid))
    (set! check.ok false)
    (set! check.error (VersionError (string.copy field) offset)))
  unit)

(define (charge! [check : (&mut c VersionCheck)] [amount : i64]) : bool
  (require! check (and (>= amount 0) (<= amount check.left)) "work-limit" 0)
  (if check.ok
    (begin
      (set! check.left (- check.left amount))
      true)
    false))

(define (new-check [limits : (& l VersionLimits)]) : VersionCheck
  (let
    [check : VersionCheck
      (VersionCheck
        true
        (VersionError "" 0)
        limits.max-work
        (VersionLimits
          limits.max-bytes
          limits.max-records
          limits.max-aux
          limits.max-name-bytes
          limits.max-work))]
    (require!
      (&mut check)
      (and
        (>= limits.max-bytes 0)
        (>= limits.max-records 0)
        (>= limits.max-aux 0)
        (>= limits.max-name-bytes 0)
        (>= limits.max-work 0))
      "limits"
      0)
    check))

;; The SysV ELF name hash is shared with the dynamic-section codec (#8296).
;; The caller proves [start,end) present; bytes are hashed without NUL.
(define (elf-hash [data : (& d (__tl_dyn-array u8))] [start : i64] [end : i64]) : i64
  (let
    [hash : i64 0]
    [at : i64 start]
    (while (< at end)
      (set! hash (+ (shl hash 4) (cast (array-ref data at) : i64)))
      (let
        [high : i64 (bit-and hash 4026531840)]
        (set! hash (bit-and (bit-xor hash (shr high 24)) 268435455)))
      (set! at (+ at 1)))
    hash))

(define (check-dynstr!
  [check : (&mut c VersionCheck)]
  [dynstr : (& d (__tl_dyn-array u8))]) : unit
  (let
    [size : i64 (array-length dynstr)]
    (require!
      check
      (and
        (<= size check.limits.max-bytes)
        (or
          (= size 0)
          (and
            (= (array-ref dynstr 0) (cast 0 : u8))
            (= (array-ref dynstr (- size 1)) (cast 0 : u8)))))
      "dynstr"
      0)))

(define (name-hash
  [check : (&mut c VersionCheck)]
  [dynstr : (& d (__tl_dyn-array u8))]
  [start : i64]
  [field : (& f str)]) : i64
  (let
    [at : i64 start]
    [end : i64 (array-length dynstr)]
    [found : bool false]
    (require! check (and (> start 0) (< start end)) field start)
    (while (and check.ok (not found) (< at end))
      (require! check (< (- at start) check.limits.max-name-bytes) field start)
      (when
        (charge! check 1)
        (if (= (array-ref dynstr at) (cast 0 : u8))
          (set! found true)
          (set! at (+ at 1)))))
    (require! check (and found (> at start)) field start)
    (if (and check.ok (charge! check (- at start)))
      (elf-hash dynstr start at)
      0)))

;; Range ownership rejects header/aux overlap and repeated chain targets.
;; VersionCheck range and work before any index arithmetic or memory access.
(define (claim!
  [check : (&mut c VersionCheck)]
  [used : (&mut u (__tl_dyn-array bool))]
  [at : i64]
  [width : i64]
  [field : (& f str)]) : bool
  (require! check (reader.range-present? (array-length used) at width) field at)
  (when
    (charge! check width)
    (let
      [i : i64 at]
      (while (and check.ok (< i (+ at width)))
        (require! check (not (array-ref used i)) field i)
        (when check.ok (set! (array-ref used i) true))
        (set! i (+ i 1)))))
  check.ok)

(define (target
  [check : (&mut c VersionCheck)]
  [size : i64]
  [at : i64]
  [relative : i64]
  [width : i64]
  [field : (& f str)]) : i64
  (require!
    check
    (and
      (> relative 0)
      (reader.range-present? size at relative)
      (reader.range-present? size (+ at relative) width))
    field
    at)
  (if check.ok
    (+ at relative)
    0))

(define (decode-section
  [check : (&mut c VersionCheck)]
  [data : (& d (__tl_dyn-array u8))]
  [dynstr : (& s (__tl_dyn-array u8))]
  [count : i64]
  [definitions : bool]) : VersionSection
  (let
    [size : i64 (array-length data)]
    [out : VersionSection
      (VersionSection (__tl_make-array u8 0) (record_vec.new))]
    [header-size : i64
      (if definitions
        20
        16)]
    [aux-size : i64
      (if definitions
        8
        16)]
    [prefix : String
      (if definitions
        "vd_next"
        "vn_next")]
    [at : i64 0]
    [ordinal : i64 0]
    [total-aux : i64 0]
    (require!
      check
      (and (>= count 0) (<= count check.limits.max-records))
      "record-count"
      0)
    (require! check (<= size check.limits.max-bytes) "section-size" 0)
    (require! check (or (> count 0) (= size 0)) prefix 0)
    (when
      check.ok
      (let
        [used : (__tl_dyn-array bool) (__tl_make-array bool size)]
        (while (and check.ok (< ordinal count))
          (when
            (claim! check (&mut used) at header-size prefix)
            (require!
              check
              (= (le.read-u16 data at) 1)
              (if definitions
                "vd_version"
                "vn_version")
              at)
            (let
              [aux-count : i64
                (le.read-u16
                  data
                  (+
                    at
                    (if definitions
                      6
                      2)))]
              [aux-rel : i64
                (le.read-u32
                  data
                  (+
                    at
                    (if definitions
                      12
                      8)))]
              [next : i64
                (le.read-u32
                  data
                  (+
                    at
                    (if definitions
                      16
                      12)))]
              [record : VersionRecord
                (VersionRecord
                  at
                  (if definitions
                    (le.read-u16 data (+ at 2))
                    0)
                  (if definitions
                    (le.read-u16 data (+ at 4))
                    0)
                  (if definitions
                    0
                    (le.read-u32 data (+ at 4)))
                  (aux_vec.new))]
              [aux-at : i64
                (target
                  check
                  size
                  at
                  aux-rel
                  aux-size
                  (if definitions
                    "vd_aux"
                    "vn_aux"))]
              [i : i64 0]
              (require!
                check
                (and
                  (> aux-count 0)
                  (<= aux-count (- check.limits.max-aux total-aux)))
                (if definitions
                  "vd_cnt"
                  "vn_cnt")
                (+
                  at
                  (if definitions
                    6
                    2)))
              (set! total-aux (+ total-aux aux-count))
              (unless
                definitions
                (let
                  [_hash : i64 (name-hash check dynstr record.file "vn_file")]
                  unit))
              (while (and check.ok (< i aux-count))
                (when
                  (claim!
                    check
                    (&mut used)
                    aux-at
                    aux-size
                    (if definitions
                      "vda_next"
                      "vna_next"))
                  (let
                    [name : i64
                      (le.read-u32
                        data
                        (+
                          aux-at
                          (if definitions
                            0
                            8)))]
                    [hash : i64
                      (name-hash
                        check
                        dynstr
                        name
                        (if definitions
                          "vda_name"
                          "vna_name"))]
                    [aux-next : i64
                      (le.read-u32
                        data
                        (+
                          aux-at
                          (if definitions
                            4
                            12)))]
                    (when
                      (or (not definitions) (= i 0))
                      (require!
                        check
                        (=
                          hash
                          (le.read-u32
                            data
                            (if definitions
                              (+ at 8)
                              aux-at)))
                        (if definitions
                          "vd_hash"
                          "vna_hash")
                        (if definitions
                          (+ at 8)
                          aux-at)))
                    (aux_vec.push-ref!
                      (&mut record.aux)
                      (VersionAux
                        aux-at
                        name
                        (if definitions
                          0
                          (le.read-u16 data (+ aux-at 4)))
                        (if definitions
                          0
                          (le.read-u16 data (+ aux-at 6)))))
                    (if (= (+ i 1) aux-count)
                      (require!
                        check
                        (= aux-next 0)
                        (if definitions
                          "vd_cnt"
                          "vn_cnt")
                        aux-at)
                      (set!
                        aux-at
                        (target
                          check
                          size
                          aux-at
                          aux-next
                          aux-size
                          (if definitions
                            "vd_cnt"
                            "vn_cnt"))))))
                (set! i (+ i 1)))
              (record_vec.push-ref! (&mut out.records) record)
              (if (= (+ ordinal 1) count)
                (require! check (= next 0) prefix at)
                (set! at (target check size at next header-size prefix)))))
          (set! ordinal (+ ordinal 1)))
        (when
          (and check.ok (charge! check size))
          (set! out.padding (__tl_make-array u8 size))
          (let
            [i : i64 0]
            (while (< i size)
              (unless
                (array-ref used i)
                (set! (array-ref out.padding i) (array-ref data i)))
              (set! i (+ i 1)))))))
    out))

(define (map-index!
  [check : (&mut c VersionCheck)]
  [mapped : (&mut m (__tl_dyn-array bool))]
  [index : i64]
  [base : bool]
  [field : (& f str)]
  [offset : i64]) : unit
  (let
    [id : i64 (bit-and index index-mask)]
    (require!
      check
      (and
        (>= index 0)
        (<= index 65535)
        (if base
          (= index 1)
          (> id 1)))
      field
      offset)
    (when
      check.ok
      (require! check (not (array-ref mapped id)) field offset)
      (when check.ok (set! (array-ref mapped id) true)))))

(define (validate-indices!
  [check : (&mut c VersionCheck)]
  [versions : (& v Versions)]
  [require-base : bool]) : unit
  (let
    [mapped : (__tl_dyn-array bool) (__tl_make-array bool 32768)]
    [base : bool false]
    [i : i64 0]
    (while (and check.ok (< i versions.definitions.records.len))
      (let
        [record : (& v VersionRecord)
          (& (array-ref versions.definitions.records.slots i))]
        [is-base : bool (not (= (bit-and record.flags flag-base) 0))]
        (map-index!
          check
          (&mut mapped)
          record.index
          is-base
          "vd_ndx"
          (+ record.offset 4))
        (set! base (or base is-base)))
      (set! i (+ i 1)))
    (require!
      check
      (or (not require-base) (= versions.definitions.records.len 0) base)
      "vd_flags: missing VER_FLG_BASE"
      0)
    (set! i 0)
    (while (and check.ok (< i versions.needs.records.len))
      (let
        [record : (& v VersionRecord)
          (& (array-ref versions.needs.records.slots i))]
        [j : i64 0]
        (while (and check.ok (< j record.aux.len))
          (let
            [aux : (& v VersionAux) (& (array-ref record.aux.slots j))]
            (map-index!
              check
              (&mut mapped)
              aux.index
              false
              "vna_other"
              (+ aux.offset 6)))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    (set! i 0)
    (while (and check.ok (< i (array-length versions.symbols)))
      (let
        [raw : i64 (cast (array-ref versions.symbols i) : i64)]
        [id : i64 (bit-and raw index-mask)]
        (when
          (charge! check 1)
          (require!
            check
            (or (and (<= id 1) (= raw id)) (and (> id 1) (array-ref mapped id)))
            "versym"
            (* i 2))))
      (set! i (+ i 1)))))

(define (decode [request : (& r DecodeRequest)]) : VersionDecodeResult
  (let
    [check : VersionCheck (new-check (& request.limits))]
    [size : i64 (array-length request.bytes.symbols)]
    [symbols : (__tl_dyn-array u16) (__tl_make-array u16 0)]
    (check-dynstr! (&mut check) (& request.dynstr))
    (require!
      (&mut check)
      (and
        (>= request.symbol-count 0)
        (<= request.symbol-count (/ request.limits.max-bytes 2))
        (= size (* request.symbol-count 2))
        (<= (array-length request.dynstr) request.limits.max-bytes))
      "versym-size"
      0)
    (when
      (and check.ok (charge! (&mut check) size))
      (set! symbols (__tl_make-array u16 request.symbol-count))
      (let
        [i : i64 0]
        (while (< i request.symbol-count)
          (set!
            (array-ref symbols i)
            (cast (le.read-u16 (& request.bytes.symbols) (* i 2)) : u16))
          (set! i (+ i 1)))))
    (let
      [definitions : VersionSection
        (decode-section
          (&mut check)
          (& request.bytes.definitions)
          (& request.dynstr)
          request.definition-count
          true)]
      [needs : VersionSection
        (decode-section
          (&mut check)
          (& request.bytes.needs)
          (& request.dynstr)
          request.need-count
          false)]
      [versions : Versions (Versions symbols definitions needs)]
      (validate-indices! (&mut check) (& versions) request.require-base)
      (if check.ok
        (Ok versions)
        (Err check.error)))))

(define (relative
  [check : (&mut c VersionCheck)]
  [at : i64]
  [next : i64]
  [field : (& f str)]) : i64
  (require! check (and (> next at) (<= (- next at) 4294967295)) field at)
  (if check.ok
    (- next at)
    0))

(define (encode-section
  [check : (&mut c VersionCheck)]
  [section : (& s VersionSection)]
  [dynstr : (& d (__tl_dyn-array u8))]
  [definitions : bool]) : (__tl_dyn-array u8)
  (let
    [size : i64 (array-length section.padding)]
    [data : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    [i : i64 0]
    [total-aux : i64 0]
    (require!
      check
      (and
        (<= size check.limits.max-bytes)
        (>= section.records.len 0)
        (<= section.records.len (array-length section.records.slots))
        (<= section.records.len check.limits.max-records)
        (or (> section.records.len 0) (= size 0)))
      "section-size"
      0)
    (when
      (and check.ok (charge! check size))
      (set! data (__tl_make-array u8 size))
      (let
        [used : (__tl_dyn-array bool) (__tl_make-array bool size)]
        (while (and check.ok (< i section.records.len))
          (let
            [record : (& s VersionRecord)
              (& (array-ref section.records.slots i))]
            [at : i64 record.offset]
            [count : i64 record.aux.len]
            [j : i64 0]
            (require!
              check
              (and
                (> count 0)
                (<= count 65535)
                (<= count (array-length record.aux.slots))
                (<= count (- check.limits.max-aux total-aux)))
              (if definitions
                "vd_cnt"
                "vn_cnt")
              at)
            (set! total-aux (+ total-aux count))
            (when (= i 0) (require! check (= at 0) "first-record-offset" at))
            (require!
              check
              (and
                (>= record.flags 0)
                (<= record.flags 65535)
                (>= record.index 0)
                (<= record.index 65535)
                (>= record.file 0)
                (<= record.file 4294967295)
                (if definitions
                  (= record.file 0)
                  (and (= record.flags 0) (= record.index 0))))
              "record-fields"
              at)
            (when
              (claim!
                check
                (&mut used)
                at
                (if definitions
                  20
                  16)
                (if definitions
                  "vd_next"
                  "vn_next"))
              (le.set-u16! (&mut data) at 1)
              (if definitions
                (begin
                  (le.set-u16! (&mut data) (+ at 2) record.flags)
                  (le.set-u16! (&mut data) (+ at 4) record.index)
                  (le.set-u16! (&mut data) (+ at 6) count))
                (begin
                  (name-hash check dynstr record.file "vn_file")
                  (le.set-u16! (&mut data) (+ at 2) count)
                  (le.set-u32! (&mut data) (+ at 4) record.file)))
              (when
                check.ok
                (le.set-u32!
                  (&mut data)
                  (+
                    at
                    (if definitions
                      12
                      8))
                  (relative
                    check
                    at
                    (array-ref record.aux.slots 0).offset
                    (if definitions
                      "vd_aux"
                      "vn_aux"))))
              (when
                (< (+ i 1) section.records.len)
                (le.set-u32!
                  (&mut data)
                  (+
                    at
                    (if definitions
                      16
                      12))
                  (relative
                    check
                    at
                    (array-ref section.records.slots (+ i 1)).offset
                    (if definitions
                      "vd_next"
                      "vn_next"))))
              (while (and check.ok (< j count))
                (let
                  [aux : (& s VersionAux) (& (array-ref record.aux.slots j))]
                  [hash : i64
                    (name-hash
                      check
                      dynstr
                      aux.name
                      (if definitions
                        "vda_name"
                        "vna_name"))]
                  (require!
                    check
                    (and
                      (>= aux.name 0)
                      (<= aux.name 4294967295)
                      (>= aux.flags 0)
                      (<= aux.flags 65535)
                      (>= aux.index 0)
                      (<= aux.index 65535)
                      (or
                        (not definitions)
                        (and (= aux.flags 0) (= aux.index 0))))
                    "aux-fields"
                    aux.offset)
                  (when
                    (claim!
                      check
                      (&mut used)
                      aux.offset
                      (if definitions
                        8
                        16)
                      (if definitions
                        "vda_next"
                        "vna_next"))
                    (le.set-u32!
                      (&mut data)
                      (+
                        aux.offset
                        (if definitions
                          0
                          8))
                      aux.name)
                    (if definitions
                      (when (= j 0) (le.set-u32! (&mut data) (+ at 8) hash))
                      (begin
                        (le.set-u32! (&mut data) aux.offset hash)
                        (le.set-u16! (&mut data) (+ aux.offset 4) aux.flags)
                        (le.set-u16! (&mut data) (+ aux.offset 6) aux.index)))
                    (when
                      (< (+ j 1) count)
                      (le.set-u32!
                        (&mut data)
                        (+
                          aux.offset
                          (if definitions
                            4
                            12))
                        (relative
                          check
                          aux.offset
                          (array-ref record.aux.slots (+ j 1)).offset
                          (if definitions
                            "vda_next"
                            "vna_next"))))))
                (set! j (+ j 1)))))
          (set! i (+ i 1)))
        (set! i 0)
        (while (and check.ok (< i size))
          (if (array-ref used i)
            (require!
              check
              (= (array-ref section.padding i) (cast 0 : u8))
              "padding-overlap"
              i)
            (set! (array-ref data i) (array-ref section.padding i)))
          (set! i (+ i 1)))))
    data))

(define (encode
  [versions : (& v Versions)]
  [dynstr : (& d (__tl_dyn-array u8))]
  [require-base : bool]
  [limits : VersionLimits]) : VersionEncodeResult
  (let
    [check : VersionCheck (new-check (& limits))]
    [symbols : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    [count : i64 (array-length versions.symbols)]
    (check-dynstr! (&mut check) dynstr)
    (require!
      (&mut check)
      (and
        (<= count (/ limits.max-bytes 2))
        (<= (array-length dynstr) limits.max-bytes))
      "versym-size"
      0)
    (when
      (and check.ok (charge! (&mut check) (* count 2)))
      (set! symbols (__tl_make-array u8 (* count 2)))
      (let
        [i : i64 0]
        (while (< i count)
          (le.set-u16!
            (&mut symbols)
            (* i 2)
            (cast (array-ref versions.symbols i) : i64))
          (set! i (+ i 1)))))
    (let
      [definitions : (__tl_dyn-array u8)
        (encode-section (&mut check) (& versions.definitions) dynstr true)]
      [needs : (__tl_dyn-array u8)
        (encode-section (&mut check) (& versions.needs) dynstr false)]
      (validate-indices! (&mut check) versions require-base)
      (if check.ok
        (Ok (VersionBytes symbols definitions needs))
        (Err check.error)))))