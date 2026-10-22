;; Pure ET_DYN metadata. Every address is translated through a unique PT_LOAD;
;; section headers corroborate that mapping and never replace it.
(import linker_elf_object_reader as elf)
(import linker_elf_dynamic as dynamic)
(import linker_elf_version_codec as versions)
(import stdlib.byte_le as le)
(import stdlib.byte_reader as bytes)
(import stdlib.string)
(import stdlib.math)

(defstruct DsoLimits
  (max-input-bytes i64)
  (max-segments i64)
  (max-sections i64)
  (max-dynamic-entries i64)
  (max-symbols i64)
  (max-versions i64)
  (max-string-bytes i64)
  (max-retained-bytes i64)
  (max-work i64))

(define (default-limits) : DsoLimits
  (DsoLimits
    67108864
    4096
    131072
    65536
    1048576
    65536
    16777216
    268435456
    536870912))

(defstruct DsoReadRequest
  (identity elf.ElfIdentity)
  (limits DsoLimits))

(defenum DsoErrorKind
  (NotElf)
  (InvalidInput)
  (UnsupportedMetadata)
  (ResourceLimit))

;; Field names are fixed literals; hostile input cannot allocate diagnostics.
(defstruct DsoError
  (kind DsoErrorKind)
  (identity elf.ElfIdentity)
  (field String)
  (offset i64))

(defstruct DsoSegment
  (index i64)
  (offset i64)
  (kind i64)
  (flags i64)
  (file-offset u64)
  (address u64)
  (file-size u64)
  (memory-size u64)
  (alignment u64))

(defstruct DsoDynamic
  (index i64)
  (offset i64)
  (tag i64)
  (value u64)
  (name elf.ElfSpan))

(defstruct DsoHash
  (span elf.ElfSpan)
  (buckets i64)
  (symbol-offset i64)
  (bloom-size i64)
  (bloom-shift i64)
  (bucket-offset i64)
  (chain-offset i64)
  (symbol-count i64)
  (chain-count i64))

(define (empty-hash) : DsoHash
  (DsoHash (elf.ElfSpan 0 0) 0 0 0 0 0 0 0 0))

(defenum DsoVersions
  (Unversioned)
  (Versioned versions.Versions))

(defstruct DsoObject
  (:lifetimes input)
  (bytes (& input (__tl_dyn-array u8)))
  (identity elf.ElfIdentity)
  (header elf.ElfHeader)
  (segments (__tl_dyn-array DsoSegment))
  (dynamic-span elf.ElfSpan)
  (entries (__tl_dyn-array DsoDynamic))
  (strings elf.ElfSpan)
  (symbol-span elf.ElfSpan)
  (symbols (__tl_dyn-array elf.ElfSymbol))
  (sysv DsoHash)
  (gnu DsoHash)
  (version-spans (__tl_dyn-array elf.ElfSpan))
  (versions DsoVersions)
  (soname elf.ElfSpan)
  (flags u64)
  (flags-1 u64))

(defenum DsoReadResult
  (:lifetimes input)
  (:must-use)
  (ReadDso (DsoObject input))
  (ReadFailed DsoError))

(defstruct DsoCheck
  (identity elf.ElfIdentity)
  (limits DsoLimits)
  (ok bool)
  (error DsoError)
  (left i64)
  (retained i64)
  (versions-used i64))

(define (require!
  [check : (&mut c DsoCheck)]
  [valid : bool]
  [field : (& f str)]
  [at : i64]) : unit
  (when
    (and check.ok (not valid))
    (set! check.ok false)
    (set!
      check.error
      (DsoError (InvalidInput) (clone check.identity) (string.copy field) at)))
  unit)

(define (check-dynamic-pointers!
  [segments : (& s (__tl_dyn-array DsoSegment))]
  [entries : (& e (__tl_dyn-array DsoDynamic))]
  [check : (&mut c DsoCheck)]) : unit
  (let
    [i : i64 0]
    (while (and check.ok (< i (array-length entries)))
      (let
        [entry : (& e DsoDynamic) (& (array-ref entries i))]
        (when
          (and
            (dynamic.pointer-tag? entry.tag)
            (not (= entry.value (cast 0 : u64))))
          (let
            [field : String (dynamic.pointer-field entry.tag)]
            [_mapped : elf.ElfSpan
              (map-range!
                segments
                entry.value
                (cast 1 : u64)
                check
                field
                (+ entry.offset 8))]
            unit)))
      (set! i (+ i 1))))
  unit)

(define (check-sections!
  [sections : (& s (__tl_dyn-array elf.ElfSection))]
  [entries : (& e (__tl_dyn-array DsoDynamic))]
  [dynamic-span : (& d elf.ElfSpan)]
  [strings : (& t elf.ElfSpan)]
  [symbols : (& y elf.ElfSpan)]
  [sysv : (& h DsoHash)]
  [gnu : (& g DsoHash)]
  [spans : (& v (__tl_dyn-array elf.ElfSpan))]
  [check : (&mut c DsoCheck)]) : unit
  (let
    [i : i64 0]
    [dynsyms : i64 0]
    [dynamics : i64 0]
    [string-section : i64 -1]
    [string-address : u64 (tag-value entries dynamic.dt-strtab)]
    ;; Other allocated string tables are not dynamic metadata. The symbol
    ;; table's link identifies dynstr even when its address disagrees.
    (while (< i (array-length sections))
      (when
        (= (array-ref sections i).section-type 11)
        (set! string-section (array-ref sections i).link))
      (set! i (+ i 1)))
    (set! i 0)
    (while (and check.ok (< i (array-length sections)))
      (let
        [section : (& s elf.ElfSection) (& (array-ref sections i))]
        [expected : elf.ElfSpan (elf.ElfSpan 0 0)]
        [tag : i64 -1]
        [width : i64 0]
        (match section.section-type
          [6
            (set! expected (clone (deref dynamic-span)))
            (set! dynamics (+ dynamics 1))
            (set! width 16)]
          [11
            (set! expected (clone (deref symbols)))
            (set! tag dynamic.dt-symtab)
            (set! dynsyms (+ dynsyms 1))
            (set! width 24)
            (require!
              check
              (and (> section.link 0) (< section.link (array-length sections)))
              "dynsym-sh_link"
              (+ section.id.offset 40))
            (when
              check.ok
              (require!
                check
                (and
                  (= (array-ref sections section.link).section-type 3)
                  (=
                    (array-ref sections section.link).file-offset
                    (cast strings.offset : u64)))
                "dynsym-sh_link"
                (+ section.id.offset 40)))]
          [5
            (set! expected (clone sysv.span))
            (set! tag dynamic.dt-hash)]
          [1879048182
            (set! expected (clone gnu.span))
            (set! tag dynamic.dt-gnu-hash)]
          [1879048189
            (set! expected (clone (array-ref spans 1)))
            (set! tag dynamic.dt-verdef)]
          [1879048190
            (set! expected (clone (array-ref spans 2)))
            (set! tag dynamic.dt-verneed)]
          [1879048191
            (set! expected (clone (array-ref spans 0)))
            (set! tag dynamic.dt-versym)
            (set! width 2)]
          [3
            (when
              (or
                (= i string-section)
                (and
                  (elf.flag? section.flags 2)
                  (= section.address string-address)))
              (set! expected (clone (deref strings)))
              (set! tag dynamic.dt-strtab))]
          [_ unit])
        (when
          (or (>= tag 0) (= section.section-type 6))
          (require!
            check
            (and
              (> expected.size 0)
              (= section.file-offset (cast expected.offset : u64))
              (= section.size (cast expected.size : u64))
              (or (< tag 0) (= section.address (tag-value entries tag))))
            "section-dynamic-disagreement"
            (+ section.id.offset 24))
          (when
            (> width 0)
            (require!
              check
              (= section.entry-size (cast width : u64))
              "sh_entsize"
              (+ section.id.offset 56)))))
      (set! i (+ i 1)))
    (require!
      check
      (and (<= dynsyms 1) (<= dynamics 1))
      "duplicate-dynamic-section"
      40))
  unit)

(define (read-dso
  [data : (& input (__tl_dyn-array u8))]
  [request : (& r DsoReadRequest)]) : (DsoReadResult input)
  (let
    [check : DsoCheck (new-check request)]
    [header : elf.ElfHeader (read-header! data (&mut check))]
    (unless check.ok (return (ReadFailed (clone check.error))))
    ;; Result owners and the version codec's empty vectors have fixed storage
    ;; even when their variable record counts are zero.
    (reserve! (&mut check) 4096 1)
    (unless check.ok (return (ReadFailed (clone check.error))))
    (let
      [segments : (__tl_dyn-array DsoSegment)
        (read-segments! data (& header) (&mut check))]
      [sections : (__tl_dyn-array elf.ElfSection)
        (read-sections! data (& header) (&mut check))]
      [dynamic-span : elf.ElfSpan (dynamic-span! (& segments) (&mut check))]
      (unless check.ok (return (ReadFailed (clone check.error))))
      (let
        [entries : (__tl_dyn-array DsoDynamic)
          (read-dynamic! data (& dynamic-span) (&mut check))]
        (check-dynamic-pointers! (& segments) (& entries) (&mut check))
        ;; At most 64 fixed tag scans below; account their comparisons once.
        (charge! (&mut check) (* (array-length entries) 64) dynamic-span.offset)
        (require!
          (&mut check)
          (and
            (>= (tag-index (& entries) dynamic.dt-strtab) 0)
            (>= (tag-index (& entries) dynamic.dt-strsz) 0)
            (>= (tag-index (& entries) dynamic.dt-symtab) 0)
            (= (tag-value (& entries) dynamic.dt-syment) (cast 24 : u64)))
          "dynamic-required-tags"
          dynamic-span.offset)
        (let
          [string-size : u64 (tag-value (& entries) dynamic.dt-strsz)]
          (limit!
            (&mut check)
            (<= string-size (cast check.limits.max-string-bytes : u64))
            "string-limit"
            (tag-offset (& entries) dynamic.dt-strsz))
          (unless check.ok (return (ReadFailed (clone check.error))))
          (let
            [strings : elf.ElfSpan
              (map-range!
                (& segments)
                (tag-value (& entries) dynamic.dt-strtab)
                string-size
                (&mut check)
                "DT_STRSZ"
                (tag-offset (& entries) dynamic.dt-strsz))]
            [sysv : DsoHash
              (read-hash! data (& segments) (& entries) false (&mut check))]
            [gnu : DsoHash
              (read-hash! data (& segments) (& entries) true (&mut check))]
            [count : i64
              (complete-symbol-count!
                (& sections)
                (& entries)
                (& sysv)
                (&mut gnu)
                (&mut check))]
            (require!
              (&mut check)
              (> strings.size 0)
              "DT_STRSZ-empty"
              (tag-offset (& entries) dynamic.dt-strsz))
            (unless check.ok (return (ReadFailed (clone check.error))))
            (require!
              (&mut check)
              (and
                (= (le.byte-le-at data strings.offset) 0)
                (= (le.byte-le-at data (- (+ strings.offset strings.size) 1)) 0))
              "dynstr-boundaries"
              strings.offset)
            (require!
              (&mut check)
              (and
                (> count 0)
                (or
                  (= sysv.span.size 0)
                  (= gnu.span.size 0)
                  (= sysv.symbol-count gnu.symbol-count)))
              "hash-symbol-count"
              dynamic-span.offset)
            (limit!
              (&mut check)
              (<= count check.limits.max-symbols)
              "symbol-limit"
              0)
            (unless check.ok (return (ReadFailed (clone check.error))))
            (let
              [symbol-span : elf.ElfSpan
                (map-range!
                  (& segments)
                  (tag-value (& entries) dynamic.dt-symtab)
                  (cast (* count 24) : u64)
                  (&mut check)
                  "DT_SYMTAB"
                  (tag-offset (& entries) dynamic.dt-symtab))]
              (unless check.ok (return (ReadFailed (clone check.error))))
              (let
                [symbols : (__tl_dyn-array elf.ElfSymbol)
                  (read-symbols!
                    data
                    (& symbol-span)
                    (& strings)
                    (& sections)
                    count
                    (&mut check))]
                [soname : elf.ElfSpan (elf.ElfSpan 0 0)]
                [i : i64 0]
                (while (and check.ok (< i (array-length entries)))
                  (when
                    (dynamic.string-tag? (array-ref entries i).tag)
                    (let
                      [span : elf.ElfSpan
                        (name-span!
                          data
                          (& strings)
                          (array-ref entries i).value
                          (&mut check)
                          (+ (array-ref entries i).offset 8))]
                      (when
                        (= (array-ref entries i).tag dynamic.dt-soname)
                        (set! soname (clone span)))
                      (set! (array-ref entries i).name span)))
                  (set! i (+ i 1)))
                (validate-hash! data (& sysv) (& symbols) false (&mut check))
                (validate-hash! data (& gnu) (& symbols) true (&mut check))
                (unless check.ok (return (ReadFailed (clone check.error))))
                (reserve!
                  (&mut check)
                  3
                  (comptime (size-of (type elf.ElfSpan))))
                (unless check.ok (return (ReadFailed (clone check.error))))
                (let
                  [spans : (__tl_dyn-array elf.ElfSpan)
                    (__tl_make-array elf.ElfSpan 3)]
                  [flags : u64 (tag-value (& entries) dynamic.dt-flags)]
                  [flags-1 : u64 (tag-value (& entries) dynamic.dt-flags-1)]
                  ;; Pay for the final section cross-check before handing the
                  ;; remaining work budget to the shared version decoder.
                  (limit!
                    (&mut check)
                    (<=
                      (array-length sections)
                      (/ check.left (+ 2 (array-length entries))))
                    "work-limit"
                    header.section-offset)
                  (unless check.ok (return (ReadFailed (clone check.error))))
                  (charge!
                    (&mut check)
                    (* (array-length sections) (+ 2 (array-length entries)))
                    header.section-offset)
                  (let
                    [version-data : DsoVersions
                      (read-versions!
                        data
                        (& segments)
                        (& entries)
                        (& strings)
                        count
                        (&mut spans)
                        (&mut check))]
                    (check-sections!
                      (& sections)
                      (& entries)
                      (& dynamic-span)
                      (& strings)
                      (& symbol-span)
                      (& sysv)
                      (& gnu)
                      (& spans)
                      (&mut check))
                    (if check.ok
                      (ReadDso
                        (DsoObject
                          data
                          (clone request.identity)
                          header
                          segments
                          dynamic-span
                          entries
                          strings
                          symbol-span
                          symbols
                          sysv
                          gnu
                          spans
                          version-data
                          soname
                          flags
                          flags-1))
                      (ReadFailed (clone check.error)))))))))))))

(define (limit!
  [check : (&mut c DsoCheck)]
  [valid : bool]
  [field : (& f str)]
  [at : i64]) : unit
  (when
    (and check.ok (not valid))
    (require! check false field at)
    (set! check.error.kind (ResourceLimit)))
  unit)

(define (charge! [check : (&mut c DsoCheck)] [amount : i64] [at : i64]) : unit
  (limit! check (and (>= amount 0) (<= amount check.left)) "work-limit" at)
  (when check.ok (set! check.left (- check.left amount)))
  unit)

(define (reserve! [check : (&mut c DsoCheck)] [count : i64] [width : i64]) : unit
  (limit!
    check
    (and
      (>= count 0)
      (> width 0)
      (<= check.retained check.limits.max-retained-bytes)
      (<= count (/ (- check.limits.max-retained-bytes check.retained) width)))
    "retained-limit"
    0)
  (when check.ok (set! check.retained (+ check.retained (* count width))))
  unit)

(define (new-check [request : (& r DsoReadRequest)]) : DsoCheck
  (let
    [out : DsoCheck
      (DsoCheck
        (clone request.identity)
        (clone request.limits)
        true
        (DsoError (InvalidInput) (clone request.identity) "ELF.header" 0)
        request.limits.max-work
        0
        0)]
    [l : (& r DsoLimits) (& request.limits)]
    (limit!
      (&mut out)
      (and
        (>= l.max-input-bytes 0)
        (>= l.max-segments 0)
        (>= l.max-sections 0)
        (>= l.max-dynamic-entries 0)
        (>= l.max-symbols 0)
        (>= l.max-versions 0)
        (>= l.max-string-bytes 0)
        (>= l.max-retained-bytes 0)
        (>= l.max-work 0))
      "limits"
      0)
    out))

;; Addition of hostile virtual extents is permitted only after this proof.
(define (address-range? [address : u64] [size : u64]) : bool
  (<= size (- (cast -1 : u64) address)))

(define (map-range!
  [segments : (& s (__tl_dyn-array DsoSegment))]
  [address : u64]
  [width : u64]
  [check : (&mut c DsoCheck)]
  [field : (& f str)]
  [at : i64]) : elf.ElfSpan
  (let
    [found : i64 0]
    [offset : i64 0]
    [i : i64 0]
    (while (and check.ok (< i (array-length segments)))
      (charge! check 1 at)
      (let
        [segment : (& s DsoSegment) (& (array-ref segments i))]
        (when
          (and
            (= segment.kind 1)
            (>= address segment.address)
            (< (- address segment.address) segment.file-size)
            (<= width (- segment.file-size (- address segment.address))))
          (set! found (+ found 1))
          (set!
            offset
            (cast (+ segment.file-offset (- address segment.address)) : i64))))
      (set! i (+ i 1)))
    (require! check (= found 1) field at)
    (elf.ElfSpan
      offset
      (if check.ok
        (cast width : i64)
        0))))

;; An open-ended table is bounded by the containing segment's file extent,
;; never by memory size or a section header's untrusted claimed size.
(define (mapped-tail!
  [segments : (& s (__tl_dyn-array DsoSegment))]
  [address : u64]
  [check : (&mut c DsoCheck)]
  [field : (& f str)]
  [at : i64]) : elf.ElfSpan
  (let
    [span : elf.ElfSpan
      (map-range! segments address (cast 1 : u64) check field at)]
    [i : i64 0]
    (while (and check.ok (< i (array-length segments)))
      (let
        [s : (& s DsoSegment) (& (array-ref segments i))]
        (when
          (and
            (= s.kind 1)
            (>= address s.address)
            (< (- address s.address) s.file-size))
          (set! span.size (cast (- s.file-size (- address s.address)) : i64))))
      (set! i (+ i 1)))
    span))

(define (read-header!
  [data : (& b (__tl_dyn-array u8))]
  [check : (&mut c DsoCheck)]) : elf.ElfHeader
  (let
    [out : elf.ElfHeader (elf.ElfHeader 0 0 0 (cast 0 : u64) 0 0 0)]
    [length : i64 (array-length data)]
    (limit! check (<= length check.limits.max-input-bytes) "input-limit" 0)
    (when
      check.ok
      (require! check (bytes.range-present? length 0 4) "ELF.magic" 0)
      (unless check.ok (set! check.error.kind (NotElf))))
    (when
      (and
        check.ok
        (not
          (and
            (= (le.byte-le-at data 0) 127)
            (= (le.byte-le-at data 1) 69)
            (= (le.byte-le-at data 2) 76)
            (= (le.byte-le-at data 3) 70))))
      (require! check false "ELF.magic" 0)
      (set! check.error.kind (NotElf)))
    (unless check.ok (return out))
    (charge! check 64 0)
    (unless check.ok (return out))
    (let
      [limits : elf.ElfLimits (elf.default-limits)]
      (set! limits.max-input-bytes check.limits.max-input-bytes)
      (set! limits.max-work 64)
      (let
        [request : elf.ElfReadRequest
          (elf.ElfReadRequest (clone check.identity) limits)]
        [common : elf.ElfCheck (elf.new-check (& request))]
        (elf.check-ident! data (&mut common) 3)
        (let
          [field : String
            (match common.error.offset
              [4 "EI_CLASS"]
              [5 "EI_DATA"]
              [6 "EI_VERSION"]
              [7 "EI_OSABI"]
              [16 "e_type"]
              [18 "e_machine"]
              [20 "e_version"]
              [_ "ELF.header"])]
          (require! check common.ok field common.error.offset))))
    (unless check.ok (return out))
    (require! check (= (le.read-u16 data 52) 64) "e_ehsize" 52)
    (let
      [offset : u64 (elf.word data 40)]
      [count : i64 (le.read-u16 data 60)]
      [names : i64 (le.read-u16 data 62)]
      (if (= offset (cast 0 : u64))
        (require! check (and (= count 0) (= names 0)) "e_shoff" 40)
        (begin
          (require!
            check
            (and
              (= (le.read-u16 data 58) 64)
              (>= offset (cast 64 : u64))
              (elf.file-range? length offset (cast 64 : u64)))
            "e_shoff"
            40)
          (unless check.ok (return out))
          (let
            [at : i64 (cast offset : i64)]
            (require!
              check
              (= (le.read-u32 data (+ at 4)) 0)
              "section-zero"
              (+ at 4))
            (when
              (> count 0)
              (require! check (< count 65280) "e_shnum" 60)
              (require!
                check
                (= (elf.word data (+ at 32)) (cast 0 : u64))
                "section-zero-size"
                (+ at 32)))
            (unless
              (= names 65535)
              (require! check (< names 65280) "e_shstrndx" 62)
              (require!
                check
                (= (le.read-u32 data (+ at 40)) 0)
                "section-zero-link"
                (+ at 40)))
            (unless
              (= (le.read-u16 data 56) 65535)
              (require!
                check
                (= (le.read-u32 data (+ at 44)) 0)
                "section-zero-info"
                (+ at 44)))
            (when
              (= count 0)
              (limit!
                check
                (<=
                  (elf.word data (+ at 32))
                  (cast check.limits.max-sections : u64))
                "section-limit"
                (+ at 32))
              (when
                check.ok
                (set! count (cast (elf.word data (+ at 32)) : i64))))
            (when (= names 65535) (set! names (le.read-u32 data (+ at 40))))
            (require!
              check
              (and (> count 0) (< names count) (<= count (/ (- length at) 64)))
              "section-table"
              40))))
      (limit! check (<= count check.limits.max-sections) "section-limit" 60)
      (when
        check.ok
        (set!
          out
          (elf.ElfHeader
            (le.byte-le-at data 7)
            (le.byte-le-at data 8)
            (le.read-u32 data 48)
            (elf.word data 24)
            (cast offset : i64)
            count
            names))))
    out))

(define (read-segments!
  [data : (& b (__tl_dyn-array u8))]
  [header : (& h elf.ElfHeader)]
  [check : (&mut c DsoCheck)]) : (__tl_dyn-array DsoSegment)
  (let
    [out : (__tl_dyn-array DsoSegment) (__tl_make-array DsoSegment 0)]
    [offset : u64 (elf.word data 32)]
    [count : i64 (le.read-u16 data 56)]
    [length : i64 (array-length data)]
    (when
      (= count 65535)
      (require! check (> header.section-count 0) "PN_XNUM" 56)
      (when
        check.ok
        (set! count (le.read-u32 data (+ header.section-offset 44)))))
    (limit! check (<= count check.limits.max-segments) "segment-limit" 56)
    (require!
      check
      (and
        (> count 0)
        (= (le.read-u16 data 54) 56)
        (>= offset (cast 64 : u64))
        (elf.file-range? length offset (cast (* count 56) : u64)))
      "program-table"
      32)
    (reserve! check count (comptime (size-of (type DsoSegment))))
    (charge! check (* count 56) 32)
    (unless check.ok (return out))
    (set! out (__tl_make-array DsoSegment count))
    (let
      [i : i64 0]
      (while (and check.ok (< i count))
        (let
          [at : i64 (+ (cast offset : i64) (* i 56))]
          [segment : DsoSegment
            (DsoSegment
              i
              at
              (le.read-u32 data at)
              (le.read-u32 data (+ at 4))
              (elf.word data (+ at 8))
              (elf.word data (+ at 16))
              (elf.word data (+ at 32))
              (elf.word data (+ at 40))
              (elf.word data (+ at 48)))]
          (require!
            check
            (elf.file-range? length segment.file-offset segment.file-size)
            "p_filesz"
            (+ at 32))
          (require!
            check
            (address-range? segment.address segment.memory-size)
            "p_memsz-overflow"
            (+ at 40))
          (when
            (= segment.kind 1)
            (require!
              check
              (<= segment.file-size segment.memory-size)
              "p_memsz"
              (+ at 40))
            (require!
              check
              (elf.alignment? segment.alignment)
              "p_align"
              (+ at 48))
            (when
              (> segment.alignment (cast 1 : u64))
              (require!
                check
                (=
                  (% segment.address segment.alignment)
                  (% segment.file-offset segment.alignment))
                "p_align-congruence"
                (+ at 48))))
          (let
            [j : i64 0]
            (while (and check.ok (< j i))
              (charge! check 1 at)
              (let
                [other : (& out DsoSegment) (& (array-ref out j))]
                (when
                  (and (= segment.kind 1) (= other.kind 1))
                  (require!
                    check
                    (or
                      (= segment.memory-size (cast 0 : u64))
                      (= other.memory-size (cast 0 : u64))
                      (<= (+ segment.address segment.memory-size) other.address)
                      (<= (+ other.address other.memory-size) segment.address))
                    "PT_LOAD-overlap"
                    (+ at 16))
                  (require!
                    check
                    (or
                      (= segment.file-size (cast 0 : u64))
                      (= other.file-size (cast 0 : u64))
                      (<=
                        (+ segment.file-offset segment.file-size)
                        other.file-offset)
                      (<=
                        (+ other.file-offset other.file-size)
                        segment.file-offset))
                    "PT_LOAD-file-overlap"
                    (+ at 8))))
              (set! j (+ j 1))))
          (set! (array-ref out i) segment))
        (set! i (+ i 1))))
    out))

(define (read-sections!
  [data : (& b (__tl_dyn-array u8))]
  [header : (& h elf.ElfHeader)]
  [check : (&mut c DsoCheck)]) : (__tl_dyn-array elf.ElfSection)
  (reserve!
    check
    header.section-count
    (comptime (size-of (type elf.ElfSection))))
  (charge! check (* header.section-count 64) header.section-offset)
  (unless check.ok (return (__tl_make-array elf.ElfSection 0)))
  (let
    [out : (__tl_dyn-array elf.ElfSection)
      (__tl_make-array elf.ElfSection header.section-count)]
    [i : i64 0]
    (while (and check.ok (< i header.section-count))
      (let
        [s : elf.ElfSection (elf.section-at data header (& check.identity) i)]
        (unless
          (or (= s.section-type 0) (= s.section-type 8))
          (require!
            check
            (elf.file-range? (array-length data) s.file-offset s.size)
            "sh_size"
            (+ s.id.offset 32)))
        (set! (array-ref out i) s))
      (set! i (+ i 1)))
    out))

(define (dynamic-span!
  [segments : (& s (__tl_dyn-array DsoSegment))]
  [check : (&mut c DsoCheck)]) : elf.ElfSpan
  (let
    [out : elf.ElfSpan (elf.ElfSpan 0 0)]
    [found : i64 0]
    [i : i64 0]
    (while (and check.ok (< i (array-length segments)))
      (let
        [s : (& s DsoSegment) (& (array-ref segments i))]
        (when
          (= s.kind 2)
          (set! found (+ found 1))
          (require!
            check
            (and
              (> s.file-size (cast 0 : u64))
              (= (% s.file-size (cast 16 : u64)) (cast 0 : u64)))
            "PT_DYNAMIC-size"
            (+ s.offset 32))
          (set!
            out
            (map-range!
              segments
              s.address
              s.file-size
              check
              "PT_DYNAMIC-address"
              (+ s.offset 16)))
          (require!
            check
            (= (cast out.offset : u64) s.file-offset)
            "PT_DYNAMIC-offset"
            (+ s.offset 8))))
      (set! i (+ i 1)))
    (require! check (= found 1) "PT_DYNAMIC-count" 32)
    out))

(define (read-dynamic!
  [data : (& b (__tl_dyn-array u8))]
  [span : (& s elf.ElfSpan)]
  [check : (&mut c DsoCheck)]) : (__tl_dyn-array DsoDynamic)
  (let
    [count : i64 0]
    [found : bool false]
    (while (and check.ok (not found) (< count (/ span.size 16)))
      (limit!
        check
        (< count check.limits.max-dynamic-entries)
        "dynamic-limit"
        (+ span.offset (* count 16)))
      (charge! check 16 (+ span.offset (* count 16)))
      (when
        check.ok
        (set! found (= (le.read-u64 data (+ span.offset (* count 16))) 0))
        (set! count (+ count 1))))
    (require! check found "DT_NULL" (+ span.offset span.size))
    (reserve! check count (comptime (size-of (type DsoDynamic))))
    (unless check.ok (return (__tl_make-array DsoDynamic 0)))
    (let
      [out : (__tl_dyn-array DsoDynamic) (__tl_make-array DsoDynamic count)]
      [i : i64 0]
      (while (and check.ok (< i count))
        (let
          [at : i64 (+ span.offset (* i 16))]
          [tag : i64 (le.read-u64 data at)]
          [j : i64 0]
          (when
            (dynamic.singleton-tag? tag)
            (while (and check.ok (< j i))
              (charge! check 1 at)
              (require!
                check
                (not (= (array-ref out j).tag tag))
                "duplicate-DT-tag"
                at)
              (set! j (+ j 1))))
          (set!
            (array-ref out i)
            (DsoDynamic i at tag (elf.word data (+ at 8)) (elf.ElfSpan 0 0))))
        (set! i (+ i 1)))
      out)))

(define (tag-index [entries : (& e (__tl_dyn-array DsoDynamic))] [tag : i64]) : i64
  (let
    [i : i64 0]
    (while (< i (array-length entries))
      (when (= (array-ref entries i).tag tag) (return i))
      (set! i (+ i 1)))
    -1))

(define (tag-value [entries : (& e (__tl_dyn-array DsoDynamic))] [tag : i64]) : u64
  (let
    [i : i64 (tag-index entries tag)]
    (if (>= i 0)
      (array-ref entries i).value
      (cast 0 : u64))))

(define (tag-offset [entries : (& e (__tl_dyn-array DsoDynamic))] [tag : i64]) : i64
  (let
    [i : i64 (tag-index entries tag)]
    (if (>= i 0)
      (+ (array-ref entries i).offset 8)
      0)))

(define (name-span!
  [data : (& b (__tl_dyn-array u8))]
  [strings : (& s elf.ElfSpan)]
  [index : u64]
  [check : (&mut c DsoCheck)]
  [at : i64]) : elf.ElfSpan
  (require! check (< index (cast strings.size : u64)) "dynstr-index" at)
  (unless check.ok (return (elf.ElfSpan 0 0)))
  (let
    [start : i64 (+ strings.offset (cast index : i64))]
    [end : i64 (+ strings.offset strings.size)]
    [i : i64 start]
    (while (and check.ok (< i end))
      (charge! check 1 i)
      (unless check.ok (return (elf.ElfSpan 0 0)))
      (when
        (= (le.byte-le-at data i) 0)
        (return (elf.ElfSpan start (- i start))))
      (set! i (+ i 1)))
    (require! check false "dynstr-terminator" at)
    (elf.ElfSpan 0 0)))

;; Discover the tight extent needed by the shared version decoder. Relative
;; links must advance inside this mapped file tail; the decoder subsequently
;; checks disjoint ownership, hashes, indices, flags and exact chain counts.
(define (version-extent!
  [data : (& b (__tl_dyn-array u8))]
  [strings : (& s elf.ElfSpan)]
  [tail : (& t elf.ElfSpan)]
  [count : i64]
  [definitions : bool]
  [check : (&mut c DsoCheck)]) : elf.ElfSpan
  (let
    [at : i64 tail.offset]
    [end : i64 tail.offset]
    [ordinal : i64 0]
    [aux-total : i64 0]
    [header-size : i64
      (if definitions
        20
        16)]
    [aux-size : i64
      (if definitions
        8
        16)]
    [field : String
      (if definitions
        "Verdef"
        "Verneed")]
    (limit!
      check
      (<= count (- check.limits.max-versions check.versions-used))
      "version-limit"
      tail.offset)
    (when check.ok (set! check.versions-used (+ check.versions-used count)))
    (while (and check.ok (< ordinal count))
      (require!
        check
        (bytes.range-present? (+ tail.offset tail.size) at header-size)
        field
        at)
      (charge! check header-size at)
      (unless check.ok (return (elf.ElfSpan tail.offset 0)))
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
        [aux-at : i64 (+ at aux-rel)]
        [i : i64 0]
        (set! end (math.i64-max end (+ at header-size)))
        (limit!
          check
          (<= aux-count (- check.limits.max-versions check.versions-used))
          "version-aux-limit"
          at)
        (when
          check.ok
          (set! check.versions-used (+ check.versions-used aux-count)))
        (set! aux-total (+ aux-total aux-count))
        (require!
          check
          (and
            (> aux-rel 0)
            (bytes.range-present? (+ tail.offset tail.size) aux-at aux-size))
          (if definitions
            "vd_aux"
            "vn_aux")
          (+
            at
            (if definitions
              12
              8)))
        (unless
          definitions
          (let
            [name : elf.ElfSpan
              (name-span!
                data
                strings
                (cast (le.read-u32 data (+ at 4)) : u64)
                check
                (+ at 4))]
            (require! check (> name.size 0) "vn_file" (+ at 4))))
        (while (and check.ok (< i aux-count))
          (require!
            check
            (bytes.range-present? (+ tail.offset tail.size) aux-at aux-size)
            field
            aux-at)
          (charge! check aux-size aux-at)
          (unless check.ok (return (elf.ElfSpan tail.offset 0)))
          (let
            [name-at : i64
              (+
                aux-at
                (if definitions
                  0
                  8))]
            [name : elf.ElfSpan
              (name-span!
                data
                strings
                (cast (le.read-u32 data name-at) : u64)
                check
                name-at)]
            (require!
              check
              (> name.size 0)
              (if definitions
                "vda_name"
                "vna_name")
              name-at))
          (set! end (math.i64-max end (+ aux-at aux-size)))
          (let
            [relative : i64
              (le.read-u32
                data
                (+
                  aux-at
                  (if definitions
                    4
                    12)))]
            (require!
              check
              (if (= (+ i 1) aux-count)
                (= relative 0)
                (and
                  (> relative 0)
                  (bytes.range-present?
                    (+ tail.offset tail.size)
                    (+ aux-at relative)
                    aux-size)))
              (if definitions
                "vda_next"
                "vna_next")
              (+
                aux-at
                (if definitions
                  4
                  12)))
            (set! aux-at (+ aux-at relative)))
          (set! i (+ i 1)))
        (require!
          check
          (if (= (+ ordinal 1) count)
            (= next 0)
            (and
              (> next 0)
              (bytes.range-present?
                (+ tail.offset tail.size)
                (+ at next)
                header-size)))
          (if definitions
            "vd_next"
            "vn_next")
          (+
            at
            (if definitions
              16
              12)))
        (set! at (+ at next)))
      (set! ordinal (+ ordinal 1)))
    ;; Vectors grow geometrically; this is a conservative retained-storage
    ;; reservation, distinct from OS usage and from the logical wire extent.
    (reserve! check (+ count aux-total) 256)
    (elf.ElfSpan tail.offset (- end tail.offset))))

(define (copy-span!
  [data : (& b (__tl_dyn-array u8))]
  [span : (& s elf.ElfSpan)]
  [check : (&mut c DsoCheck)]) : (__tl_dyn-array u8)
  (charge! check span.size span.offset)
  (unless check.ok (return (__tl_make-array u8 0)))
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 span.size)]
    [i : i64 0]
    (while (< i span.size)
      (set! (array-ref out i) (array-ref data (+ span.offset i)))
      (set! i (+ i 1)))
    out))

(define (read-versions!
  [data : (& b (__tl_dyn-array u8))]
  [segments : (& s (__tl_dyn-array DsoSegment))]
  [entries : (& e (__tl_dyn-array DsoDynamic))]
  [strings : (& t elf.ElfSpan)]
  [count : i64]
  [spans : (&mut p (__tl_dyn-array elf.ElfSpan))]
  [check : (&mut c DsoCheck)]) : DsoVersions
  (let
    [present : bool (>= (tag-index entries dynamic.dt-versym) 0)]
    [definitions : u64 (tag-value entries dynamic.dt-verdefnum)]
    [needs : u64 (tag-value entries dynamic.dt-verneednum)]
    (require!
      check
      (=
        (>= (tag-index entries dynamic.dt-verdef) 0)
        (>= (tag-index entries dynamic.dt-verdefnum) 0))
      "DT_VERDEFNUM-pair"
      (tag-offset entries dynamic.dt-verdef))
    (require!
      check
      (=
        (>= (tag-index entries dynamic.dt-verneed) 0)
        (>= (tag-index entries dynamic.dt-verneednum) 0))
      "DT_VERNEEDNUM-pair"
      (tag-offset entries dynamic.dt-verneed))
    (require!
      check
      (or present (and (= definitions (cast 0 : u64)) (= needs (cast 0 : u64))))
      "DT_VERSYM-missing"
      0)
    (limit!
      check
      (and
        (<= definitions (cast check.limits.max-versions : u64))
        (<= needs (- (cast check.limits.max-versions : u64) definitions)))
      "version-limit"
      0)
    (unless (and check.ok present) (return (Unversioned)))
    (set!
      (array-ref spans 0)
      (map-range!
        segments
        (tag-value entries dynamic.dt-versym)
        (cast (* count 2) : u64)
        check
        "DT_VERSYM"
        (tag-offset entries dynamic.dt-versym)))
    (let
      [i : i64 0]
      (while (and check.ok (< i 2))
        (let
          [tag : i64
            (if (= i 0)
              dynamic.dt-verdef
              dynamic.dt-verneed)]
          [number : i64
            (cast
              (if (= i 0)
                definitions
                needs)
              : i64)]
          (when
            (>= (tag-index entries tag) 0)
            (require!
              check
              (> number 0)
              "version-count-zero"
              (tag-offset entries tag))
            (let
              [tail : elf.ElfSpan
                (mapped-tail!
                  segments
                  (tag-value entries tag)
                  check
                  (if (= i 0)
                    "DT_VERDEF"
                    "DT_VERNEED")
                  (tag-offset entries tag))]
              (set!
                (array-ref spans (+ i 1))
                (version-extent! data strings (& tail) number (= i 0) check)))))
        (set! i (+ i 1))))
    (let
      [size : i64
        (+
          (array-ref spans 0).size
          (array-ref spans 1).size
          (array-ref spans 2).size)]
      ;; Copies, decoder ownership maps, padding, symbol indices and its fixed
      ;; index map all fit this reservation before any decoder allocation.
      (reserve! check size 5)
      (reserve! check strings.size 1)
      (reserve! check 32768 (comptime (size-of (type bool))))
      (charge! check (+ (* count 2) size) 0)
      (unless check.ok (return (Unversioned)))
      (let
        [wire : versions.VersionBytes
          (versions.VersionBytes
            (copy-span! data (& (array-ref spans 0)) check)
            (copy-span! data (& (array-ref spans 1)) check)
            (copy-span! data (& (array-ref spans 2)) check))]
        [names : (__tl_dyn-array u8) (copy-span! data strings check)]
        (unless check.ok (return (Unversioned)))
        (let
          [request : versions.DecodeRequest
            (versions.DecodeRequest
              wire
              names
              count
              (cast definitions : i64)
              (cast needs : i64)
              true
              (versions.VersionLimits
                (math.i64-max strings.size size)
                check.limits.max-versions
                check.limits.max-versions
                check.limits.max-string-bytes
                check.left))]
          (match (versions.decode (& request))
            [(Ok result) (Versioned result)]
            [(Err error)
              (let
                [base : i64 (array-ref spans 1).offset]
                (when
                  (or
                    (string.eq error.field "versym")
                    (string.eq error.field "versym-size"))
                  (set! base (array-ref spans 0).offset))
                (when
                  (and
                    (>= (string.string-length error.field) 2)
                    (= (string.char-at error.field 1) 'n'))
                  (set! base (array-ref spans 2).offset))
                (when
                  (or
                    (string.eq error.field "vn_file")
                    (string.eq error.field "vda_name")
                    (string.eq error.field "vna_name")
                    (string.eq error.field "dynstr"))
                  (set! base strings.offset))
                (require! check false error.field (+ base error.offset))
                (when
                  (string.eq error.field "work-limit")
                  (set! check.error.kind (ResourceLimit)))
                (Unversioned))]))))))

(define (read-hash!
  [data : (& b (__tl_dyn-array u8))]
  [segments : (& s (__tl_dyn-array DsoSegment))]
  [entries : (& e (__tl_dyn-array DsoDynamic))]
  [gnu : bool]
  [check : (&mut c DsoCheck)]) : DsoHash
  (let
    [tag : i64
      (if gnu
        dynamic.dt-gnu-hash
        dynamic.dt-hash)]
    [out : DsoHash (empty-hash)]
    (when (< (tag-index entries tag) 0) (return out))
    (let
      [field : String
        (if gnu
          "DT_GNU_HASH"
          "DT_HASH")]
      [tail : elf.ElfSpan
        (mapped-tail!
          segments
          (tag-value entries tag)
          check
          field
          (tag-offset entries tag))]
      [header : i64
        (if gnu
          16
          8)]
      (require! check (>= tail.size header) field tail.offset)
      (charge! check header tail.offset)
      (unless check.ok (return out))
      (let
        [buckets : i64 (le.read-u32 data tail.offset)]
        [second : i64 (le.read-u32 data (+ tail.offset 4))]
        [bloom : i64
          (if gnu
            (le.read-u32 data (+ tail.offset 8))
            0)]
        [shift : i64
          (if gnu
            (le.read-u32 data (+ tail.offset 12))
            0)]
        [prefix : i64 (+ header (* bloom 8))]
        (require!
          check
          (and
            (> buckets 0)
            (<= prefix tail.size)
            (<= buckets (/ (- tail.size prefix) 4)))
          field
          tail.offset)
        (limit!
          check
          (<= second check.limits.max-symbols)
          "symbol-limit"
          (+ tail.offset 4))
        (when
          gnu
          (require!
            check
            (and
              (> second 0)
              (> bloom 0)
              (= (bit-and bloom (- bloom 1)) 0)
              (< shift 64))
            "GNU-hash-header"
            (+ tail.offset 4)))
        (unless check.ok (return out))
        (let
          [bucket-at : i64 (+ tail.offset prefix)]
          [chain-at : i64 (+ bucket-at (* buckets 4))]
          [count : i64 second]
          (if gnu
            (let
              [i : i64 0]
              (while (and check.ok (< i buckets))
                (charge! check 4 (+ bucket-at (* i 4)))
                (unless check.ok (return out))
                (let
                  [symbol : i64 (le.read-u32 data (+ bucket-at (* i 4)))]
                  [done : bool (= symbol 0)]
                  (unless
                    done
                    (require!
                      check
                      (>= symbol second)
                      "GNU-hash-bucket"
                      (+ bucket-at (* i 4))))
                  (while (and check.ok (not done))
                    (limit!
                      check
                      (< symbol check.limits.max-symbols)
                      "symbol-limit"
                      (+ bucket-at (* i 4)))
                    (let
                      [at : i64 (+ chain-at (* (- symbol second) 4))]
                      (require!
                        check
                        (bytes.range-present? (+ tail.offset tail.size) at 4)
                        "GNU-hash-chain"
                        at)
                      (charge! check 4 at)
                      (when
                        check.ok
                        (set!
                          done
                          (not (= (bit-and (le.read-u32 data at) 1) 0)))
                        (set! count (math.i64-max count (+ symbol 1)))
                        (set! symbol (+ symbol 1))))))
                (set! i (+ i 1))))
            (begin
              (require!
                check
                (and
                  (> count 0)
                  (<= count (/ (- (+ tail.offset tail.size) chain-at) 4)))
                "SysV-hash-chain-size"
                (+ tail.offset 4))
              (charge! check (* (+ count buckets) 4) chain-at)))
          (when
            check.ok
            (set!
              out
              (DsoHash
                (elf.ElfSpan
                  tail.offset
                  (+
                    prefix
                    (* buckets 4)
                    (*
                      (if gnu
                        (- count second)
                        count)
                      4)))
                buckets
                (if gnu
                  second
                  0)
                bloom
                shift
                bucket-at
                chain-at
                count
                (if gnu
                  (- count second)
                  count)))))))
    out))

;; GNU ld writes symoffset=1 for an empty hash even when undefined symbols
;; follow the null row. An empty GNU table is not a total-symbol-count oracle.
(define (complete-symbol-count!
  [sections : (& s (__tl_dyn-array elf.ElfSection))]
  [entries : (& e (__tl_dyn-array DsoDynamic))]
  [sysv : (& h DsoHash)]
  [gnu : (&mut g DsoHash)]
  [check : (&mut c DsoCheck)]) : i64
  (let
    [count : i64
      (if (> sysv.span.size 0)
        sysv.symbol-count
        gnu.symbol-count)]
    (when
      (and (> gnu.span.size 0) (= gnu.chain-count 0))
      (when
        (= sysv.span.size 0)
        (let
          [found : i64 0]
          [i : i64 0]
          (while (and check.ok (< i (array-length sections)))
            (charge! check 1 (array-ref sections i).id.offset)
            (let
              [section : (& s elf.ElfSection) (& (array-ref sections i))]
              (when
                (= section.section-type 11)
                (set! found (+ found 1))
                (require! check (= found 1) "duplicate-dynamic-section" 40)
                (charge! check (array-length entries) section.id.offset)
                (unless check.ok (return count))
                (require!
                  check
                  (and
                    (= section.entry-size (cast 24 : u64))
                    (= (% section.size (cast 24 : u64)) (cast 0 : u64))
                    (= section.address (tag-value entries dynamic.dt-symtab)))
                  "section-dynamic-disagreement"
                  (+ section.id.offset 24))
                (set! count (cast (/ section.size (cast 24 : u64)) : i64))))
            (set! i (+ i 1)))
          (require! check (<= found 1) "duplicate-dynamic-section" 40)
          (when
            (and check.ok (= found 0))
            (require!
              check
              false
              "GNU-empty-symbol-count"
              (+ gnu.span.offset 4))
            (set! check.error.kind (UnsupportedMetadata)))))
      (require!
        check
        (>= count gnu.symbol-offset)
        "hash-symbol-count"
        (+ gnu.span.offset 4))
      (set! gnu.symbol-count count))
    count))

(define (read-symbols!
  [data : (& b (__tl_dyn-array u8))]
  [span : (& s elf.ElfSpan)]
  [strings : (& t elf.ElfSpan)]
  [sections : (& h (__tl_dyn-array elf.ElfSection))]
  [count : i64]
  [check : (&mut c DsoCheck)]) : (__tl_dyn-array elf.ElfSymbol)
  (reserve! check count (comptime (size-of (type elf.ElfSymbol))))
  (charge! check (* count 24) span.offset)
  (unless check.ok (return (__tl_make-array elf.ElfSymbol 0)))
  (let
    [out : (__tl_dyn-array elf.ElfSymbol) (__tl_make-array elf.ElfSymbol count)]
    [table-id : elf.ElfSectionId
      (elf.ElfSectionId (clone check.identity) -1 span.offset)]
    [local-count : i64 -1]
    [global-seen : bool false]
    [i : i64 0]
    [j : i64 0]
    (while (< j (array-length sections))
      (when
        (= (array-ref sections j).section-type 11)
        (set! table-id (clone (array-ref sections j).id))
        (set! local-count (array-ref sections j).info))
      (set! j (+ j 1)))
    (while (and check.ok (< i count))
      (let
        [at : i64 (+ span.offset (* i 24))]
        [name : i64 (le.read-u32 data at)]
        [info : i64 (le.byte-le-at data (+ at 4))]
        [other : i64 (le.byte-le-at data (+ at 5))]
        [raw : i64 (le.read-u16 data (+ at 6))]
        [section : elf.ElfSymbolSection (elf.Undefined)]
        (let
          [binding : i64 (shr info 4)]
          (if (= binding 0)
            (require! check (not global-seen) "dynsym-local-order" (+ at 4))
            (set! global-seen true))
          (when
            (>= local-count 0)
            (require!
              check
              (if (< i local-count)
                (= binding 0)
                (not (= binding 0)))
              "dynsym-sh_info"
              (+ table-id.offset 44))))
        (require! check (not (= raw 65535)) "dynsym-SHN_XINDEX" (+ at 6))
        (when
          (and (> raw 0) (< raw 65280))
          (require!
            check
            (or (= (array-length sections) 0) (< raw (array-length sections)))
            "st_shndx"
            (+ at 6))
          (set!
            section
            (elf.DefinedSection
              (elf.ElfSectionId
                (clone check.identity)
                raw
                (if (< raw (array-length sections))
                  (array-ref sections raw).id.offset
                  -1)))))
        (when
          (>= raw 65280)
          (set!
            section
            (match raw
              [65521 (elf.Absolute)]
              [65522 (elf.CommonSection)]
              [_ (elf.ReservedSection raw)])))
        (when
          (= i 0)
          (require!
            check
            (and
              (= name 0)
              (= info 0)
              (= other 0)
              (= raw 0)
              (= (elf.word data (+ at 8)) (cast 0 : u64))
              (= (elf.word data (+ at 16)) (cast 0 : u64)))
            "dynsym-zero"
            at))
        (set!
          (array-ref out i)
          (elf.ElfSymbol
            (elf.ElfEntryId (clone table-id) i at)
            name
            (name-span! data strings (cast name : u64) check at)
            (elf.symbol-binding (shr info 4))
            (elf.symbol-type (bit-and info 15))
            (elf.symbol-visibility other)
            other
            raw
            (+ at 6)
            section
            (elf.word data (+ at 8))
            (elf.word data (+ at 16)))))
      (set! i (+ i 1)))
    out))

(define (validate-hash!
  [data : (& b (__tl_dyn-array u8))]
  [hash : (& h DsoHash)]
  [symbols : (& y (__tl_dyn-array elf.ElfSymbol))]
  [gnu : bool]
  [check : (&mut c DsoCheck)]) : unit
  (when (= hash.span.size 0) (return unit))
  (reserve! check hash.symbol-count (comptime (size-of (type bool))))
  (charge! check hash.symbol-count hash.span.offset)
  (unless check.ok (return unit))
  (let
    [seen : (__tl_dyn-array bool) (__tl_make-array bool hash.symbol-count)]
    [bucket : i64 0]
    (unless
      gnu
      (require!
        check
        (= (le.read-u32 data hash.chain-offset) 0)
        "SysV-hash-zero"
        hash.chain-offset)
      (let
        [i : i64 0]
        (while (and check.ok (< i hash.symbol-count))
          (charge! check 1 (+ hash.chain-offset (* i 4)))
          (require!
            check
            (<
              (le.read-u32 data (+ hash.chain-offset (* i 4)))
              hash.symbol-count)
            "SysV-hash-chain"
            (+ hash.chain-offset (* i 4)))
          (set! i (+ i 1)))))
    (while (and check.ok (< bucket hash.buckets))
      (charge! check 1 (+ hash.bucket-offset (* bucket 4)))
      (let
        [index : i64 (le.read-u32 data (+ hash.bucket-offset (* bucket 4)))]
        [done : bool (= index 0)]
        (while (and check.ok (not done))
          (require!
            check
            (and (>= index hash.symbol-offset) (< index hash.symbol-count))
            "hash-symbol"
            (+ hash.bucket-offset (* bucket 4)))
          (unless check.ok (return unit))
          (require!
            check
            (not (array-ref seen index))
            "hash-cycle-or-overlap"
            (+ hash.chain-offset (* (- index hash.symbol-offset) 4)))
          (set! (array-ref seen index) true)
          (let
            [symbol : (& y elf.ElfSymbol) (& (array-ref symbols index))]
            [at : i64 (+ hash.chain-offset (* (- index hash.symbol-offset) 4))]
            [value : i64 (le.read-u32 data at)]
            [name : (& y elf.ElfSpan) (& symbol.name)]
            (charge! check (+ 1 name.size) at)
            (unless check.ok (return unit))
            (let
              [name-hash : i64
                (if gnu
                  (dynamic.gnu-hash data name.offset (+ name.offset name.size))
                  (versions.elf-hash data name.offset (+ name.offset name.size)))]
              (require!
                check
                (= (% name-hash hash.buckets) bucket)
                "hash-bucket-name"
                at)
              (if gnu
                (let
                  [bloom-at : i64
                    (+
                      hash.span.offset
                      16
                      (* (% (/ name-hash 64) hash.bloom-size) 8))]
                  [bloom : u64 (elf.word data bloom-at)]
                  [mask : u64
                    (bit-or
                      (shl (cast 1 : u64) (% name-hash 64))
                      (shl
                        (cast 1 : u64)
                        (% (shr name-hash hash.bloom-shift) 64)))]
                  (require!
                    check
                    (=
                      (bit-and value 4294967294)
                      (bit-and name-hash 4294967294))
                    "GNU-hash-value"
                    at)
                  (require!
                    check
                    (= (bit-and bloom mask) mask)
                    "GNU-hash-bloom"
                    bloom-at)
                  (set! done (not (= (bit-and value 1) 0)))
                  (set! index (+ index 1)))
                (begin
                  (set! index value)
                  (set! done (= value 0))))))))
      (set! bucket (+ bucket 1)))
    (let
      [i : i64
        (if gnu
          (if (= hash.chain-count 0)
            hash.symbol-count
            hash.symbol-offset)
          1)]
      (while (and check.ok (< i hash.symbol-count))
        (charge! check 1 hash.span.offset)
        (require!
          check
          (array-ref seen i)
          "hash-unreachable-symbol"
          (+ (array-ref symbols i).id.offset 4))
        (set! i (+ i 1)))))
  unit)

(defenum DsoHashKind
  (PreferGnu)
  (SysvHash)
  (GnuHash))

(defstruct DsoLookupRequest
  (:lifetimes name version)
  (name (& name (__tl_dyn-array u8)))
  (version (& version (__tl_dyn-array u8)))
  (hash DsoHashKind)
  (max-work i64))

(defenum DsoLookupResult
  (:must-use)
  (Found elf.ElfSymbol)
  (Absent)
  (LookupFailed DsoError))

(define (equal-name?
  [data : (& b (__tl_dyn-array u8))]
  [span : (& s elf.ElfSpan)]
  [name : (& n (__tl_dyn-array u8))]
  [check : (&mut c DsoCheck)]) : bool
  (unless (= span.size (array-length name)) (return false))
  (charge! check span.size span.offset)
  (unless check.ok (return false))
  (let
    [i : i64 0]
    (while (< i span.size)
      (unless
        (= (array-ref data (+ span.offset i)) (array-ref name i))
        (return false))
      (set! i (+ i 1)))
    true))

(define (version-name!
  [object : (& o (DsoObject input))]
  [index : i64]
  [check : (&mut c DsoCheck)]) : elf.ElfSpan
  (match object.versions
    [(Unversioned) (elf.ElfSpan 0 0)]
    [(Versioned table)
      (let
        [id : i64
          (bit-and
            (cast (array-ref table.symbols index) : i64)
            versions.index-mask)]
        [i : i64 0]
        (when (<= id 1) (return (elf.ElfSpan 0 0)))
        (while (and check.ok (< i table.definitions.records.len))
          (charge! check 1 (array-ref object.version-spans 1).offset)
          (let
            [record : (& table versions.VersionRecord)
              (& (array-ref table.definitions.records.slots i))]
            (when
              (= record.index id)
              (return
                (name-span!
                  object.bytes
                  (& object.strings)
                  (cast (array-ref record.aux.slots 0).name : u64)
                  check
                  (+ (array-ref object.version-spans 1).offset record.offset)))))
          (set! i (+ i 1)))
        (set! i 0)
        (while (and check.ok (< i table.needs.records.len))
          (let
            [record : (& table versions.VersionRecord)
              (& (array-ref table.needs.records.slots i))]
            [j : i64 0]
            (while (and check.ok (< j record.aux.len))
              (charge! check 1 (array-ref object.version-spans 2).offset)
              (let
                [aux : (& table versions.VersionAux)
                  (& (array-ref record.aux.slots j))]
                (when
                  (= (bit-and aux.index versions.index-mask) id)
                  (return
                    (name-span!
                      object.bytes
                      (& object.strings)
                      (cast aux.name : u64)
                      check
                      (+ (array-ref object.version-spans 2).offset aux.offset)))))
              (set! j (+ j 1))))
          (set! i (+ i 1)))
        (elf.ElfSpan 0 0))]))

(define (lookup-match?
  [object : (& o (DsoObject input))]
  [index : i64]
  [request : (& r (DsoLookupRequest name version))]
  [check : (&mut c DsoCheck)]) : bool
  (let
    [symbol : (& o elf.ElfSymbol) (& (array-ref object.symbols index))]
    (unless
      (and
        (not (= symbol.raw-section 0))
        (match symbol.binding
          [(Global) true]
          [(Weak) true]
          [(GnuUnique) true]
          [_ false])
        (match symbol.visibility
          [(DefaultVisibility) true]
          [(Protected) true]
          [_ false])
        (equal-name? object.bytes (& symbol.name) request.name check))
      (return false))
    (let
      [raw : i64
        (match object.versions
          [(Unversioned) 1]
          [(Versioned table) (cast (array-ref table.symbols index) : i64)])]
      (if (= (array-length request.version) 0)
        (and
          (> (bit-and raw versions.index-mask) 0)
          (= (bit-and raw versions.index-hidden) 0))
        (let
          [span : elf.ElfSpan (version-name! object index check)]
          (and
            (> span.size 0)
            (equal-name? object.bytes (& span) request.version check)))))))

;; Lookup exposes definitions admitted by the DSO's own hash, including weak,
;; TLS, IFUNC and protected records. It performs no provider/relocation policy.
(define (lookup
  [object : (& o (DsoObject input))]
  [request : (& r (DsoLookupRequest name version))]) : DsoLookupResult
  (let
    [limits : DsoLimits (default-limits)]
    (set! limits.max-work request.max-work)
    (let
      [read-request : DsoReadRequest
        (DsoReadRequest (clone object.identity) limits)]
      [check : DsoCheck (new-check (& read-request))]
      [gnu : bool
        (match request.hash
          [(PreferGnu) (> object.gnu.span.size 0)]
          [(GnuHash) true]
          [(SysvHash) false])]
      [hash : (& o DsoHash)
        (if gnu
          (& object.gnu)
          (& object.sysv))]
      (require! (&mut check) (> hash.span.size 0) "lookup-hash-unavailable" 0)
      (charge!
        (&mut check)
        (+ (array-length request.name) (array-length request.version))
        0)
      (unless check.ok (return (LookupFailed (clone check.error))))
      (let
        [name-hash : i64
          (if gnu
            (dynamic.gnu-hash request.name 0 (array-length request.name))
            (versions.elf-hash request.name 0 (array-length request.name)))]
        [bucket : i64 (% name-hash hash.buckets)]
        [index : i64
          (le.read-u32 object.bytes (+ hash.bucket-offset (* bucket 4)))]
        [steps : i64 0]
        (when
          gnu
          (let
            [bloom : u64
              (elf.word
                object.bytes
                (+
                  hash.span.offset
                  16
                  (* (% (/ name-hash 64) hash.bloom-size) 8)))]
            [mask : u64
              (bit-or
                (shl (cast 1 : u64) (% name-hash 64))
                (shl (cast 1 : u64) (% (shr name-hash hash.bloom-shift) 64)))]
            (unless (= (bit-and bloom mask) mask) (return (Absent)))))
        (while (and check.ok (> index 0) (< steps hash.symbol-count))
          (charge!
            (&mut check)
            1
            (+ hash.chain-offset (* (- index hash.symbol-offset) 4)))
          (require!
            (&mut check)
            (and
              (>= index hash.symbol-offset)
              (< index (array-length object.symbols)))
            "lookup-hash-index"
            hash.bucket-offset)
          (unless check.ok (return (LookupFailed (clone check.error))))
          (when
            (lookup-match? object index request (&mut check))
            (return (Found (clone (array-ref object.symbols index)))))
          (let
            [next : i64
              (le.read-u32
                object.bytes
                (+ hash.chain-offset (* (- index hash.symbol-offset) 4)))]
            (set!
              index
              (if gnu
                (if (= (bit-and next 1) 0)
                  (+ index 1)
                  0)
                next)))
          (set! steps (+ steps 1)))
        (if check.ok
          (Absent)
          (LookupFailed (clone check.error)))))))