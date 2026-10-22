;; Pure ELF64 x86-64 ET_REL syntax. All spans borrow one immutable input;
;; identity tokens are caller-assigned provenance, not capabilities.
(import stdlib.byte_le as le)
(import stdlib.byte_reader as bytes)
(import stdlib.vector)
(import stdlib.sort)
(import stdlib.string)

(defstruct ElfIdentity
  (input u64)
  (content u64))

(defstruct ElfSpan
  (offset i64)
  (size i64))

(defstruct ElfSectionId
  (input ElfIdentity)
  (index i64)
  (offset i64))

(defstruct ElfEntryId
  (section ElfSectionId)
  (index i64)
  (offset i64))

(defstruct ElfLimits
  (max-input-bytes i64)
  (max-sections i64)
  (max-symbols i64)
  (max-relocations i64)
  (max-groups i64)
  (max-notes i64)
  (max-string-bytes i64)
  (max-retained-bytes i64)
  (max-diagnostics i64)
  (max-work i64))

(define (default-limits) : ElfLimits
  (ElfLimits
    67108864
    131072
    1048576
    1048576
    65536
    65536
    16777216
    268435456
    1
    536870912))

(defstruct ElfReadRequest
  (identity ElfIdentity)
  (limits ElfLimits))

(defenum ElfErrorKind
  (InvalidLimits)
  (InputLimit)
  (SectionLimit)
  (SymbolLimit)
  (RelocationLimit)
  (GroupLimit)
  (NoteLimit)
  (StringLimit)
  (RetainedLimit)
  (DiagnosticLimit)
  (WorkLimit)
  (BadHeader)
  (UnsupportedClass)
  (UnsupportedEncoding)
  (UnsupportedVersion)
  (UnsupportedOsAbi)
  (UnsupportedObjectType)
  (UnsupportedMachine)
  (UnexpectedProgramHeaders)
  (UnsupportedCompressedMetadata)
  (UnsupportedRelFormat)
  (BadNumbering)
  (BadRange)
  (OverlappingRanges)
  (BadSection)
  (BadString)
  (BadSymbol)
  (BadExtendedIndex)
  (BadRelocation)
  (BadGroup)
  (BadNote)
  (BadCompression))

;; One fixed-size diagnostic: malformed input never supplies owned text.
(defstruct ElfError
  (kind ElfErrorKind)
  (input ElfIdentity)
  (section i64)
  (entry i64)
  (offset i64))

(defstruct ElfHeader
  (osabi i64)
  (abi-version i64)
  (flags i64)
  (entry u64)
  (section-offset i64)
  (section-count i64)
  (name-table i64))

(defenum ElfSectionClass
  (KnownSection)
  (UnknownNonAllocSection)
  (UnknownAllocSection))

(defenum ElfCompressionKind
  (Zlib)
  (Zstd)
  (UnknownCompression i64))

(defstruct ElfCompression
  (kind ElfCompressionKind)
  (size u64)
  (alignment u64)
  (payload ElfSpan))

(defenum ElfSectionBody
  (Uncompressed)
  (NoFileBytes)
  (Compressed ElfCompression))

(defenum ElfPriority
  (NoPriority)
  (Priority u64))

(defstruct ElfSection
  (id ElfSectionId)
  (name-index i64)
  (name ElfSpan)
  (section-type i64)
  (class ElfSectionClass)
  (flags u64)
  (address u64)
  (file-offset u64)
  (size u64)
  (link i64)
  (info i64)
  (alignment u64)
  (entry-size u64)
  (payload ElfSpan)
  (body ElfSectionBody)
  (priority ElfPriority)
  (gnu-stack bool)
  (symbol-start i64)
  (symbol-count i64)
  (extended-index i64)
  (relocation-start i64)
  (relocation-count i64)
  (group-index i64)
  (note-start i64)
  (note-count i64))

(defenum ElfSymbolBinding
  (Local)
  (Global)
  (Weak)
  (GnuUnique)
  (UnknownBinding i64))

(defenum ElfSymbolType
  (NoType)
  (ObjectSymbol)
  (FunctionSymbol)
  (SectionSymbol)
  (FileSymbol)
  (CommonSymbol)
  (TlsSymbol)
  (GnuIfunc)
  (UnknownSymbolType i64))

(defenum ElfVisibility
  (DefaultVisibility)
  (Internal)
  (Hidden)
  (Protected))

(defenum ElfSymbolSection
  (Undefined)
  (Absolute)
  (CommonSection)
  (DefinedSection ElfSectionId)
  (ReservedSection i64))

(defstruct ElfSymbol
  (id ElfEntryId)
  (name-index i64)
  (name ElfSpan)
  (binding ElfSymbolBinding)
  (symbol-type ElfSymbolType)
  (visibility ElfVisibility)
  (other i64)
  (raw-section i64)
  (section-index-offset i64)
  (section ElfSymbolSection)
  (value u64)
  (size u64))

(defenum ElfRelocationKind
  (NoneRelocation)
  (Abs64)
  (Pc32)
  (Got32)
  (Plt32)
  (CopyRelocation)
  (GlobDat)
  (JumpSlot)
  (Relative)
  (GotPcRel)
  (Abs32)
  (Abs32Signed)
  (Abs16)
  (Pc16)
  (Abs8)
  (Pc8)
  (DtpMod64)
  (DtpOff64)
  (TpOff64)
  (TlsGd)
  (TlsLd)
  (DtpOff32)
  (GotTpOff)
  (TpOff32)
  (Pc64)
  (GotOff64)
  (GotPc32)
  (Got64)
  (GotPcRel64)
  (GotPc64)
  (GotPlt64)
  (PltOff64)
  (Size32)
  (Size64)
  (GotPc32TlsDesc)
  (TlsDescCall)
  (TlsDesc)
  (IRelative)
  (Relative64)
  (GotPcRelX)
  (RexGotPcRelX)
  (Code4GotPcRelX)
  (Code4GotTpOff)
  (Code4GotPc32TlsDesc)
  (Code5GotPcRelX)
  (Code5GotTpOff)
  (Code5GotPc32TlsDesc)
  (Code6GotPcRelX)
  (Code6GotTpOff)
  (Code6GotPc32TlsDesc)
  (UnknownRelocation i64))

;; Width 0 denotes a defined marker/no fixed field; -1 denotes an unknown type.
(defstruct ElfRelocation
  (id ElfEntryId)
  (target ElfSectionId)
  (symbol ElfEntryId)
  (offset u64)
  (number i64)
  (kind ElfRelocationKind)
  (width i64)
  (addend i64))

(defstruct ElfGroup
  (section ElfSectionId)
  (flags i64)
  (signature ElfEntryId)
  (member-start i64)
  (member-count i64))

(defstruct ElfNote
  (id ElfEntryId)
  (note-type i64)
  (owner ElfSpan)
  (descriptor ElfSpan)
  (alignment i64))

;; Scalar spans refer to bytes through this single input borrow. No section,
;; symbol name, compressed payload, or note descriptor is copied or interned.
(defstruct ElfObject
  (:lifetimes input)
  (bytes (& input (__tl_dyn-array u8)))
  (identity ElfIdentity)
  (header ElfHeader)
  (sections (__tl_dyn-array ElfSection))
  (symbols (__tl_dyn-array ElfSymbol))
  (relocations (__tl_dyn-array ElfRelocation))
  (groups (__tl_dyn-array ElfGroup))
  (members (__tl_dyn-array ElfSectionId))
  (notes (__tl_dyn-array ElfNote))
  (work i64))

(defenum ElfReadResult
  (:lifetimes input)
  (:must-use)
  (ReadObject (ElfObject input))
  (ReadFailed ElfError))

(defstruct ElfCheck
  (identity ElfIdentity)
  (limits ElfLimits)
  (ok bool)
  (error ElfError)
  (section i64)
  (entry i64)
  (left i64))

(defenum ElfHeaderResult
  (HeaderReady ElfHeader)
  (HeaderFailed ElfError))

(define (require!
  [check : (&mut c ElfCheck)]
  [valid : bool]
  [kind : ElfErrorKind]
  [offset : i64]) : unit
  (when
    (and check.ok (not valid))
    (set! check.ok false)
    (set!
      check.error
      (ElfError kind (clone check.identity) check.section check.entry offset)))
  unit)

(define (charge! [check : (&mut c ElfCheck)] [amount : i64] [at : i64]) : unit
  (require! check (and (>= amount 0) (<= amount check.left)) (WorkLimit) at)
  (when check.ok (set! check.left (- check.left amount)))
  unit)

(define (valid-limits? [l : (& l ElfLimits)]) : bool
  (and
    (>= l.max-input-bytes 0)
    (>= l.max-sections 0)
    (>= l.max-symbols 0)
    (>= l.max-relocations 0)
    (>= l.max-groups 0)
    (>= l.max-notes 0)
    (>= l.max-string-bytes 0)
    (>= l.max-retained-bytes 0)
    (>= l.max-diagnostics 0)
    (>= l.max-work 0)))

(define (new-check [request : (& r ElfReadRequest)]) : ElfCheck
  (ElfCheck
    (clone request.identity)
    (clone request.limits)
    true
    (ElfError (BadHeader) (clone request.identity) -1 -1 0)
    -1
    -1
    request.limits.max-work))

(define (word [data : (& b (__tl_dyn-array u8))] [at : i64]) : u64
  (cast (le.read-u64 data at) : u64))

;; Subtraction precedes every conversion/addition of hostile 64-bit offsets.
(define (file-range? [length : i64] [start : u64] [size : u64]) : bool
  (and (<= start (cast length : u64)) (<= size (- (cast length : u64) start))))

(define (alignment? [value : u64]) : bool
  (or
    (= value (cast 0 : u64))
    (= (bit-and value (- value (cast 1 : u64))) (cast 0 : u64))))

(define (check-ident!
  [data : (& b (__tl_dyn-array u8))]
  [check : (&mut c ElfCheck)]
  [object-type : i64]) : unit
  (let
    [length : i64 (array-length data)]
    (require! check (valid-limits? (& check.limits)) (InvalidLimits) 0)
    (require! check (> check.limits.max-diagnostics 0) (DiagnosticLimit) 0)
    (require! check (<= length check.limits.max-input-bytes) (InputLimit) 0)
    (require! check (bytes.range-present? length 0 64) (BadRange) length)
    (charge! check 64 0)
    (unless check.ok (return unit))
    (require! check (= (le.byte-le-at data 0) 127) (BadHeader) 0)
    (require! check (= (le.byte-le-at data 1) 69) (BadHeader) 1)
    (require! check (= (le.byte-le-at data 2) 76) (BadHeader) 2)
    (require! check (= (le.byte-le-at data 3) 70) (BadHeader) 3)
    (require! check (= (le.byte-le-at data 4) 2) (UnsupportedClass) 4)
    (require! check (= (le.byte-le-at data 5) 1) (UnsupportedEncoding) 5)
    (require! check (= (le.byte-le-at data 6) 1) (UnsupportedVersion) 6)
    (require!
      check
      (or (= (le.byte-le-at data 7) 0) (= (le.byte-le-at data 7) 3))
      (UnsupportedOsAbi)
      7)
    (require!
      check
      (= (le.read-u16 data 16) object-type)
      (UnsupportedObjectType)
      16)
    (require! check (= (le.read-u16 data 18) 62) (UnsupportedMachine) 18)
    (require! check (= (le.read-u32 data 20) 1) (UnsupportedVersion) 20)))

(define (read-header
  [data : (& b (__tl_dyn-array u8))]
  [check : (&mut c ElfCheck)]) : ElfHeaderResult
  (check-ident! data check 1)
  (unless check.ok (return (HeaderFailed (clone check.error))))
  (let
    [length : i64 (array-length data)]
    (require!
      check
      (= (word data 32) (cast 0 : u64))
      (UnexpectedProgramHeaders)
      32)
    (require! check (= (le.read-u16 data 56) 0) (UnexpectedProgramHeaders) 56)
    (require! check (= (le.read-u16 data 52) 64) (BadHeader) 52)
    (require! check (= (le.read-u16 data 58) 64) (BadHeader) 58)
    (unless check.ok (return (HeaderFailed (clone check.error))))
    (let
      [table : u64 (word data 40)]
      [count : i64 (le.read-u16 data 60)]
      [names : i64 (le.read-u16 data 62)]
      (if (= table (cast 0 : u64))
        (begin
          (require! check (= count 0) (BadNumbering) 60)
          (require! check (= names 0) (BadNumbering) 62))
        (begin
          (require!
            check
            (and
              (>= table (cast 64 : u64))
              (file-range? length table (cast 64 : u64)))
            (BadRange)
            40)
          (unless check.ok (return (HeaderFailed (clone check.error))))
          (let
            [at : i64 (cast table : i64)]
            (charge! check 64 at)
            (unless check.ok (return (HeaderFailed (clone check.error))))
            (if (= count 0)
              (let
                [extended : u64 (word data (+ at 32))]
                (require!
                  check
                  (<= extended (cast check.limits.max-sections : u64))
                  (SectionLimit)
                  (+ at 32))
                (unless check.ok (return (HeaderFailed (clone check.error))))
                (set! count (cast extended : i64)))
              (begin
                (require! check (< count 65280) (BadNumbering) 60)
                (require!
                  check
                  (= (word data (+ at 32)) (cast 0 : u64))
                  (BadNumbering)
                  (+ at 32))
                unit))
            (if (= names 65535)
              (set! names (le.read-u32 data (+ at 40)))
              (begin
                (require! check (< names 65280) (BadNumbering) 62)
                (require!
                  check
                  (= (le.read-u32 data (+ at 40)) 0)
                  (BadNumbering)
                  (+ at 40))
                unit))
            (require! check (> count 0) (BadNumbering) (+ at 32))
            (require! check (< names count) (BadNumbering) 62)
            (require! check (<= count (/ (- length at) 64)) (BadRange) 40))))
      (require! check (<= count check.limits.max-sections) (SectionLimit) 60)
      (if check.ok
        (HeaderReady
          (ElfHeader
            (le.byte-le-at data 7)
            (le.byte-le-at data 8)
            (le.read-u32 data 48)
            (word data 24)
            (cast table : i64)
            count
            names))
        (HeaderFailed (clone check.error))))))

(defstruct ElfCounts
  (symbols i64)
  (relocations i64)
  (groups i64)
  (members i64)
  (notes i64)
  (strings i64)
  (retained i64))

(defstruct ElfFileRange
  (start i64)
  (end i64)
  (section i64)
  (field i64))

(import (vector.vector ElfFileRange) as ranges)
(import (sort.vec ElfFileRange) as range_sort)

(define (flag? [flags : u64] [mask : i64]) : bool
  (not (= (bit-and flags (cast mask : u64)) (cast 0 : u64))))

(define (section-class [kind : i64] [flags : u64]) : ElfSectionClass
  (if (or
    (and (>= kind 0) (<= kind 4))
    (= kind 7)
    (= kind 8)
    (= kind 11)
    (and (>= kind 14) (<= kind 18))
    (= kind 1879048193)
    (= kind 1879048180))
    (KnownSection)
    (if (flag? flags 2)
      (UnknownAllocSection)
      (UnknownNonAllocSection))))

;; The complete section table has already passed the header range proof.
(define (section-at
  [data : (& b (__tl_dyn-array u8))]
  [header : (& h ElfHeader)]
  [identity : (& i ElfIdentity)]
  [index : i64]) : ElfSection
  (let
    [at : i64 (+ header.section-offset (* index 64))]
    [kind : i64 (le.read-u32 data (+ at 4))]
    [flags : u64 (word data (+ at 8))]
    (ElfSection
      (ElfSectionId (ElfIdentity identity.input identity.content) index at)
      (le.read-u32 data at)
      (ElfSpan 0 0)
      kind
      (section-class kind flags)
      flags
      (word data (+ at 16))
      (word data (+ at 24))
      (word data (+ at 32))
      (le.read-u32 data (+ at 40))
      (le.read-u32 data (+ at 44))
      (word data (+ at 48))
      (word data (+ at 56))
      (ElfSpan 0 0)
      (if (or (= kind 0) (= kind 8))
        (NoFileBytes)
        (Uncompressed))
      (NoPriority)
      false
      0
      0
      -1
      0
      0
      -1
      0
      0)))

(define (add-count!
  [check : (&mut c ElfCheck)]
  [current : i64]
  [amount : i64]
  [limit : i64]
  [kind : ElfErrorKind]
  [at : i64]) : i64
  (require!
    check
    (and (>= amount 0) (<= current limit) (<= amount (- limit current)))
    kind
    at)
  (if check.ok
    (+ current amount)
    current))

(define (retained!
  [check : (&mut c ElfCheck)]
  [total : i64]
  [count : i64]
  [width : i64]) : i64
  (require!
    check
    (and
      (>= count 0)
      (> width 0)
      (<= total check.limits.max-retained-bytes)
      (<= count (/ (- check.limits.max-retained-bytes total) width)))
    (RetainedLimit)
    0)
  (if check.ok
    (+ total (* count width))
    total))

(define (table-kind? [kind : i64]) : bool
  (or (= kind 2) (= kind 11)))

(defenum ElfLinkResult
  (LinkedSection ElfSection)
  (LinkFailed))

(define (section-link!
  [data : (& b (__tl_dyn-array u8))]
  [header : (& h ElfHeader)]
  [check : (&mut c ElfCheck)]
  [section : (& s ElfSection)]
  [symbol-table : bool]) : ElfLinkResult
  (require!
    check
    (and (> section.link 0) (< section.link header.section-count))
    (BadSection)
    (+ section.id.offset 40))
  (charge! check 64 (+ header.section-offset (* section.link 64)))
  (unless check.ok (return (LinkFailed)))
  (let
    [linked : ElfSection
      (section-at data header (& check.identity) section.link)]
    (require!
      check
      (if symbol-table
        (table-kind? linked.section-type)
        (= linked.section-type 3))
      (BadSection)
      (+ section.id.offset 40))
    (require!
      check
      (not (flag? linked.flags 2048))
      (UnsupportedCompressedMetadata)
      (+ linked.id.offset 8))
    (if check.ok
      (LinkedSection linked)
      (LinkFailed))))

;; Note headers remain three 32-bit fields on x86-64. GNU property notes use
;; eight-byte alignment; ordinary GNU notes use four. Alignment is relative to
;; the section's start, including the twelve-byte header before the owner.
(define (note-next!
  [data : (& b (__tl_dyn-array u8))]
  [check : (&mut c ElfCheck)]
  [start : i64]
  [end : i64]
  [at : i64]
  [alignment : i64]) : i64
  (require! check (bytes.range-present? end at 12) (BadNote) at)
  (charge! check 12 at)
  (unless check.ok (return end))
  (let
    [owner-size : i64 (le.read-u32 data at)]
    [desc-size : i64 (le.read-u32 data (+ at 4))]
    [owner : i64 (+ at 12)]
    (require! check (bytes.range-present? end owner owner-size) (BadNote) at)
    (unless check.ok (return end))
    (when
      (> owner-size 0)
      (charge! check 1 (+ owner (- owner-size 1)))
      (unless check.ok (return end))
      (require!
        check
        (= (le.byte-le-at data (+ owner (- owner-size 1))) 0)
        (BadNote)
        owner))
    (let
      [owner-end : i64 (+ owner owner-size)]
      [padding : i64
        (% (- alignment (% (- owner-end start) alignment)) alignment)]
      (require!
        check
        (bytes.range-present? end owner-end padding)
        (BadNote)
        owner-end)
      (unless check.ok (return end))
      (let
        [descriptor : i64 (+ owner-end padding)]
        (require!
          check
          (bytes.range-present? end descriptor desc-size)
          (BadNote)
          (+ at 4))
        (unless check.ok (return end))
        (let
          [desc-end : i64 (+ descriptor desc-size)]
          [tail : i64
            (% (- alignment (% (- desc-end start) alignment)) alignment)]
          (require!
            check
            (bytes.range-present? end desc-end tail)
            (BadNote)
            desc-end)
          (if check.ok
            (+ desc-end tail)
            end))))))

(define (preflight
  [data : (& b (__tl_dyn-array u8))]
  [header : (& h ElfHeader)]
  [check : (&mut c ElfCheck)]) : ElfCounts
  (let
    [counts : ElfCounts (ElfCounts 0 0 0 0 0 0 0)]
    [index : i64 0]
    [length : i64 (array-length data)]
    (while (and check.ok (< index header.section-count))
      (set! check.section index)
      (charge! check 64 (+ header.section-offset (* index 64)))
      (unless check.ok (return counts))
      (let
        [section : ElfSection (section-at data header (& check.identity) index)]
        [at : i64 section.id.offset]
        [kind : i64 section.section-type]
        [logical-size : u64 section.size]
        (when
          (= index 0)
          (require!
            check
            (and
              (= section.name-index 0)
              (= kind 0)
              (= section.flags (cast 0 : u64))
              (= section.address (cast 0 : u64))
              (= section.file-offset (cast 0 : u64))
              (= section.info 0)
              (= section.alignment (cast 0 : u64))
              (= section.entry-size (cast 0 : u64)))
            (BadSection)
            at))
        (require! check (alignment? section.alignment) (BadSection) (+ at 48))
        (when
          (and (not (= kind 0)) (not (= kind 8)))
          (require!
            check
            (file-range? length section.file-offset section.size)
            (BadRange)
            (+ at 24)))
        (when
          (flag? section.flags 128)
          (require!
            check
            (< section.link header.section-count)
            (BadSection)
            (+ at 40)))
        (when
          (flag? section.flags 64)
          (require!
            check
            (< section.info header.section-count)
            (BadSection)
            (+ at 44)))
        (unless check.ok (return counts))
        (when (= kind 9) (require! check false (UnsupportedRelFormat) (+ at 4)))
        (when
          (flag? section.flags 2048)
          (require!
            check
            (and
              (not (= kind 0))
              (not (= kind 8))
              (>= section.size (cast 24 : u64)))
            (BadCompression)
            (+ at 32))
          (unless check.ok (return counts))
          (let
            [body : i64 (cast section.file-offset : i64)]
            (charge! check 24 body)
            (unless check.ok (return counts))
            (set! logical-size (word data (+ body 8)))
            (require!
              check
              (= (le.read-u32 data (+ body 4)) 0)
              (BadCompression)
              (+ body 4))
            (require!
              check
              (alignment? (word data (+ body 16)))
              (BadCompression)
              (+ body 16)))
          ;; Structured metadata must be directly readable to validate its links.
          (require!
            check
            (not
              (or
                (table-kind? kind)
                (= kind 3)
                (= kind 4)
                (= kind 7)
                (= kind 17)
                (= kind 18)))
            (UnsupportedCompressedMetadata)
            (+ at 8)))
        (unless check.ok (return counts))
        (when
          (or (flag? section.flags 16) (flag? section.flags 32))
          (require!
            check
            (> section.entry-size (cast 0 : u64))
            (BadSection)
            (+ at 56))
          (when
            check.ok
            (require!
              check
              (= (% logical-size section.entry-size) (cast 0 : u64))
              (BadSection)
              (+ at 32))))
        (when
          (or (= kind 14) (= kind 15) (= kind 16))
          ;; LLVM leaves sh_entsize zero; ELFCLASS64 still fixes pointer width.
          (require!
            check
            (or
              (= section.entry-size (cast 0 : u64))
              (= section.entry-size (cast 8 : u64)))
            (BadSection)
            (+ at 56))
          (require!
            check
            (= (% logical-size (cast 8 : u64)) (cast 0 : u64))
            (BadSection)
            (+ at 32)))
        (when
          (= kind 3)
          (set!
            counts.strings
            (add-count!
              check
              counts.strings
              (cast section.size : i64)
              check.limits.max-string-bytes
              (StringLimit)
              (+ at 32)))
          (when
            (> section.size (cast 0 : u64))
            (let
              [start : i64 (cast section.file-offset : i64)]
              [size : i64 (cast section.size : i64)]
              (charge! check 2 start)
              (unless check.ok (return counts))
              (require!
                check
                (and
                  (= (le.byte-le-at data start) 0)
                  (= (le.byte-le-at data (+ start (- size 1))) 0))
                (BadString)
                start))))
        (when
          (or (table-kind? kind) (= kind 4) (= kind 17) (= kind 18))
          (let
            [width : i64
              (if (or (table-kind? kind) (= kind 4))
                24
                4)]
            (require!
              check
              (= section.entry-size (cast width : u64))
              (BadSection)
              (+ at 56))
            (require!
              check
              (= (% section.size (cast width : u64)) (cast 0 : u64))
              (BadSection)
              (+ at 32))
            (unless check.ok (return counts))
            (let
              [entries : i64 (/ (cast section.size : i64) width)]
              (cond
                [(table-kind? kind)
                  (match (section-link! data header check (& section) false)
                    [(LinkedSection _) unit]
                    [(LinkFailed) (return counts)])
                  (require!
                    check
                    (and
                      (> entries 0)
                      (> section.info 0)
                      (<= section.info entries))
                    (BadSymbol)
                    (+ at 44))
                  (set!
                    counts.symbols
                    (add-count!
                      check
                      counts.symbols
                      entries
                      check.limits.max-symbols
                      (SymbolLimit)
                      (+ at 32)))]
                [(= kind 4)
                  (match (section-link! data header check (& section) true)
                    [(LinkedSection _) unit]
                    [(LinkFailed) (return counts)])
                  (require!
                    check
                    (and
                      (> section.info 0)
                      (< section.info header.section-count))
                    (BadRelocation)
                    (+ at 44))
                  (set!
                    counts.relocations
                    (add-count!
                      check
                      counts.relocations
                      entries
                      check.limits.max-relocations
                      (RelocationLimit)
                      (+ at 32)))]
                [(= kind 17)
                  (match (section-link! data header check (& section) true)
                    [(LinkedSection _) unit]
                    [(LinkFailed) (return counts)])
                  (require!
                    check
                    (and (> entries 0) (= section.flags (cast 0 : u64)))
                    (BadGroup)
                    at)
                  (set!
                    counts.groups
                    (add-count!
                      check
                      counts.groups
                      1
                      check.limits.max-groups
                      (GroupLimit)
                      at))
                  (set!
                    counts.members
                    (add-count!
                      check
                      counts.members
                      (- entries 1)
                      header.section-count
                      (BadGroup)
                      (+ at 32)))]
                [else
                  (match (section-link! data header check (& section) true)
                    [(LinkFailed) (return counts)]
                    [(LinkedSection linked)
                      (require!
                        check
                        (and
                          (= section.info 0)
                          (=
                            section.size
                            (* (/ linked.size (cast 24 : u64)) (cast 4 : u64))))
                        (BadExtendedIndex)
                        (+ at 32))
                      unit])]))))
        (when
          (= kind 7)
          (let
            [start : i64 (cast section.file-offset : i64)]
            [end : i64 (+ start (cast section.size : i64))]
            [note : i64 start]
            [alignment : i64
              (if (= section.alignment (cast 8 : u64))
                8
                4)]
            (require!
              check
              (<= section.alignment (cast 8 : u64))
              (BadNote)
              (+ at 48))
            (while (and check.ok (< note end))
              (set!
                counts.notes
                (add-count!
                  check
                  counts.notes
                  1
                  check.limits.max-notes
                  (NoteLimit)
                  note))
              (set! note (note-next! data check start end note alignment)))))
        (set! index (+ index 1))))
    (set! check.section -1)
    (let
      [retained : i64 1024]
      (set!
        retained
        (retained!
          check
          retained
          header.section-count
          (comptime (size-of (type ElfSection)))))
      (set!
        retained
        (retained!
          check
          retained
          counts.symbols
          (comptime (size-of (type ElfSymbol)))))
      (set!
        retained
        (retained!
          check
          retained
          counts.relocations
          (comptime (size-of (type ElfRelocation)))))
      (set!
        retained
        (retained!
          check
          retained
          counts.groups
          (comptime (size-of (type ElfGroup)))))
      (set!
        retained
        (retained!
          check
          retained
          counts.members
          (comptime (size-of (type ElfSectionId)))))
      (set!
        retained
        (retained!
          check
          retained
          counts.notes
          (comptime (size-of (type ElfNote)))))
      (set! retained (retained! check retained header.section-count 8))
      (set!
        retained
        (retained!
          check
          retained
          (+ header.section-count 2)
          (* 2 (comptime (size-of (type ElfFileRange))))))
      (set! counts.retained retained))
    counts))

(define (name-span!
  [data : (& b (__tl_dyn-array u8))]
  [table : (& t ElfSection)]
  [index : i64]
  [check : (&mut c ElfCheck)]
  [field : i64]) : ElfSpan
  (require!
    check
    (and
      (= table.section-type 3)
      (>= index 0)
      (or
        (and (= table.size (cast 0 : u64)) (= index 0))
        (< (cast index : u64) table.size)))
    (BadString)
    field)
  (unless check.ok (return (ElfSpan 0 0)))
  (let
    [start : i64 (+ (cast table.file-offset : i64) index)]
    [end : i64 (+ (cast table.file-offset : i64) (cast table.size : i64))]
    [at : i64 start]
    (when (= table.size (cast 0 : u64)) (return (ElfSpan start 0)))
    (while (and check.ok (< at end))
      (charge! check 1 at)
      (unless check.ok (return (ElfSpan 0 0)))
      (when (= (le.byte-le-at data at) 0) (return (ElfSpan start (- at start))))
      (set! at (+ at 1)))
    (require! check false (BadString) field)
    (ElfSpan 0 0)))

(define (name-prefix?
  [data : (& b (__tl_dyn-array u8))]
  [span : (& s ElfSpan)]
  [literal : String]
  [check : (&mut c ElfCheck)]) : bool
  (let
    [size : i64 (string.string-length (& literal))]
    [index : i64 0]
    (when (< span.size size) (return false))
    (charge! check size span.offset)
    (unless check.ok (return false))
    (while (< index size)
      (unless
        (=
          (le.byte-le-at data (+ span.offset index))
          (cast (string.string-ref (& literal) index) : i64))
        (return false))
      (set! index (+ index 1)))
    true))

(define (priority!
  [data : (& b (__tl_dyn-array u8))]
  [section : (& s ElfSection)]
  [check : (&mut c ElfCheck)]) : ElfPriority
  (let
    [prefix : String
      (match section.section-type
        [14 ".init_array."]
        [15 ".fini_array."]
        [16 ".preinit_array."]
        [_ ""])]
    [size : i64 (string.string-length (& prefix))]
    (when (or (= size 0) (<= section.name.size size)) (return (NoPriority)))
    (unless
      (name-prefix? data (& section.name) prefix check)
      (return (NoPriority)))
    (let
      [index : i64 size]
      [value : u64 (cast 0 : u64)]
      [overflow : i64 -1]
      (while (< index section.name.size)
        (let
          [at : i64 (+ section.name.offset index)]
          (charge! check 1 at)
          (unless check.ok (return (NoPriority)))
          (let
            [digit : i64 (- (le.byte-le-at data at) 48)]
            (when (or (< digit 0) (> digit 9)) (return (NoPriority)))
            (when
              (< overflow 0)
              (if (>
                value
                (/ (- (cast -1 : u64) (cast digit : u64)) (cast 10 : u64)))
                (set! overflow at)
                (set! value (+ (* value (cast 10 : u64)) (cast digit : u64)))))))
        (set! index (+ index 1)))
      (require!
        check
        (< overflow 0)
        (BadSection)
        (if (< overflow 0)
          section.name.offset
          overflow))
      (if check.ok
        (Priority value)
        (NoPriority)))))

(define (charge-records!
  [check : (&mut c ElfCheck)]
  [count : i64]
  [width : i64]
  [at : i64]) : unit
  (require!
    check
    (and (>= count 0) (> width 0) (<= count (/ check.left width)))
    (WorkLimit)
    at)
  (when check.ok (charge! check (* count width) at)))

;; Preflight has proved every table/range/count and its retained allocation.
;; Directory order remains physical section order; only scratch ranges sort.
(define (read-sections
  [data : (& b (__tl_dyn-array u8))]
  [header : (& h ElfHeader)]
  [check : (&mut c ElfCheck)]) : (__tl_dyn-array ElfSection)
  (charge-records! check header.section-count 64 header.section-offset)
  (unless check.ok (return (__tl_make-array ElfSection 0)))
  (let
    [sections : (__tl_dyn-array ElfSection)
      (__tl_make-array ElfSection header.section-count)]
    [index : i64 0]
    [symbols : i64 0]
    [relocations : i64 0]
    [groups : i64 0]
    [notes : i64 0]
    (while (and check.ok (< index header.section-count))
      (let
        [section : ElfSection (section-at data header (& check.identity) index)]
        (unless
          (or (= section.section-type 0) (= section.section-type 8))
          (set!
            section.payload
            (ElfSpan (cast section.file-offset : i64) (cast section.size : i64))))
        (when
          (flag? section.flags 2048)
          (let
            [at : i64 (cast section.file-offset : i64)]
            [kind : ElfCompressionKind
              (match (le.read-u32 data at)
                [1 (Zlib)]
                [2 (Zstd)]
                [other (UnknownCompression other)])]
            (set!
              section.body
              (Compressed
                (ElfCompression
                  kind
                  (word data (+ at 8))
                  (word data (+ at 16))
                  (ElfSpan (+ at 24) (- (cast section.size : i64) 24)))))))
        (when
          (table-kind? section.section-type)
          (set! section.symbol-start symbols)
          (set! section.symbol-count (/ (cast section.size : i64) 24))
          (set! symbols (+ symbols section.symbol-count)))
        (when
          (= section.section-type 4)
          (set! section.relocation-start relocations)
          (set! section.relocation-count (/ (cast section.size : i64) 24))
          (set! relocations (+ relocations section.relocation-count)))
        (when
          (= section.section-type 17)
          (set! section.group-index groups)
          (set! groups (+ groups 1)))
        (when
          (= section.section-type 7)
          (set! section.note-start notes)
          (let
            [start : i64 section.payload.offset]
            [end : i64 (+ start section.payload.size)]
            [at : i64 start]
            [alignment : i64
              (if (= section.alignment (cast 8 : u64))
                8
                4)]
            (while (and check.ok (< at end))
              (set! at (note-next! data check start end at alignment))
              (set! section.note-count (+ section.note-count 1))
              (set! notes (+ notes 1)))))
        (set! (array-ref sections index) section))
      (set! index (+ index 1)))
    (unless
      (= header.name-table 0)
      (require!
        check
        (= (array-ref sections header.name-table).section-type 3)
        (BadString)
        62))
    (set! index 0)
    (while (and check.ok (< index header.section-count))
      (set! check.section index)
      (let
        [section : ElfSection (clone (array-ref sections index))]
        (unless
          (= section.section-type 0)
          (if (= header.name-table 0)
            (require!
              check
              (= section.name-index 0)
              (BadString)
              section.id.offset)
            (set!
              section.name
              (name-span!
                data
                (& (array-ref sections header.name-table))
                section.name-index
                check
                section.id.offset)))
          (set! section.priority (priority! data (& section) check))
          (when
            (= section.name.size 15)
            (set!
              section.gnu-stack
              (name-prefix? data (& section.name) ".note.GNU-stack" check))))
        (when
          (= section.section-type 18)
          (let
            [table : ElfSection (clone (array-ref sections section.link))]
            (require!
              check
              (= table.extended-index -1)
              (BadExtendedIndex)
              (+ section.id.offset 40))
            (set! table.extended-index index)
            (set! (array-ref sections section.link) table)))
        (set! (array-ref sections index) section))
      (set! index (+ index 1)))
    (set! check.section -1)
    sections))

(define (range-less? [left : ElfFileRange] [right : ElfFileRange]) : bool
  (or
    (< left.start right.start)
    (and
      (= left.start right.start)
      (or
        (< left.end right.end)
        (and (= left.end right.end) (< left.section right.section))))))

(define (check-overlaps!
  [header : (& h ElfHeader)]
  [sections : (& s (__tl_dyn-array ElfSection))]
  [check : (&mut c ElfCheck)]) : unit
  (let
    [count : i64 (+ header.section-count 2)]
    [levels : i64 0]
    [width : i64 count]
    (while (> width 1)
      (set! width (/ (+ width 1) 2))
      (set! levels (+ levels 1)))
    ;; Bounds insertion blocks, merge comparisons/moves and the final scan.
    (charge-records! check count (+ (* 4 levels) 64) header.section-offset)
    (unless check.ok (return unit))
    (let
      [files : ranges.Vec (ranges.with-capacity count)]
      [index : i64 0]
      (ranges.push! files (ElfFileRange 0 64 -2 0))
      (when
        (> header.section-count 0)
        (ranges.push!
          files
          (ElfFileRange
            header.section-offset
            (+ header.section-offset (* header.section-count 64))
            -1
            40)))
      (while (< index header.section-count)
        (let
          [section : (& s ElfSection) (& (array-ref sections index))]
          (unless
            (or
              (= section.section-type 0)
              (= section.section-type 8)
              (= section.payload.size 0))
            (ranges.push!
              files
              (ElfFileRange
                section.payload.offset
                (+ section.payload.offset section.payload.size)
                index
                (+ section.id.offset 24)))))
        (set! index (+ index 1)))
      (range_sort.sort! (&mut files) range-less?)
      (set! index 1)
      (while (and check.ok (< index (ranges.len (& files))))
        (let
          [left : ElfFileRange
            (ranges.get (& files) (- index 1) (ElfFileRange 0 0 0 0))]
          [right : ElfFileRange
            (ranges.get (& files) index (ElfFileRange 0 0 0 0))]
          ;; If a payload sorts before the header at the same byte, report
          ;; its sh_offset rather than blaming the fixed header at offset zero.
          [bad : ElfFileRange
            (if (and (< right.section 0) (>= left.section 0))
              left
              right)]
          (set! check.section bad.section)
          (require!
            check
            (<= left.end right.start)
            (OverlappingRanges)
            bad.field))
        (set! index (+ index 1)))
      (set! check.section -1))))

(define (symbol-binding [value : i64]) : ElfSymbolBinding
  (match value
    [0 (Local)]
    [1 (Global)]
    [2 (Weak)]
    [10 (GnuUnique)]
    [other (UnknownBinding other)]))

(define (symbol-type [value : i64]) : ElfSymbolType
  (match value
    [0 (NoType)]
    [1 (ObjectSymbol)]
    [2 (FunctionSymbol)]
    [3 (SectionSymbol)]
    [4 (FileSymbol)]
    [5 (CommonSymbol)]
    [6 (TlsSymbol)]
    [10 (GnuIfunc)]
    [other (UnknownSymbolType other)]))

(define (symbol-visibility [other : i64]) : ElfVisibility
  (match (bit-and other 3)
    [0 (DefaultVisibility)]
    [1 (Internal)]
    [2 (Hidden)]
    [_ (Protected)]))

(define (symbol-section!
  [data : (& b (__tl_dyn-array u8))]
  [sections : (& s (__tl_dyn-array ElfSection))]
  [table : (& t ElfSection)]
  [index : i64]
  [raw : i64]
  [at : i64]
  [check : (&mut c ElfCheck)]) : ElfSymbolSection
  (let
    [extended : i64 0]
    [field : i64 (+ at 6)]
    (when
      (>= table.extended-index 0)
      (let
        [extra : (& s ElfSection) (& (array-ref sections table.extended-index))]
        (set! field (+ (cast extra.file-offset : i64) (* index 4)))
        (charge! check 4 field)
        (unless check.ok (return (Undefined)))
        (set! extended (le.read-u32 data field))
        (unless
          (= raw 65535)
          (require! check (= extended 0) (BadExtendedIndex) field))))
    (cond
      [(= raw 65535)
        (require! check (>= table.extended-index 0) (BadExtendedIndex) (+ at 6))
        (require!
          check
          (and (> extended 0) (< extended (array-length sections)))
          (BadExtendedIndex)
          field)
        (if check.ok
          (DefinedSection (clone (array-ref sections extended).id))
          (Undefined))]
      [(= raw 0) (Undefined)]
      [(= raw 65521) (Absolute)]
      [(= raw 65522) (CommonSection)]
      [(>= raw 65280) (ReservedSection raw)]
      [else
        (require! check (< raw (array-length sections)) (BadSymbol) (+ at 6))
        (if check.ok
          (DefinedSection (clone (array-ref sections raw).id))
          (Undefined))])))

(define (read-symbols
  [data : (& b (__tl_dyn-array u8))]
  [sections : (& s (__tl_dyn-array ElfSection))]
  [counts : (& n ElfCounts)]
  [check : (&mut c ElfCheck)]) : (__tl_dyn-array ElfSymbol)
  (charge-records! check counts.symbols 24 0)
  (unless check.ok (return (__tl_make-array ElfSymbol 0)))
  (let
    [symbols : (__tl_dyn-array ElfSymbol)
      (__tl_make-array ElfSymbol counts.symbols)]
    [section-index : i64 0]
    (while (and check.ok (< section-index (array-length sections)))
      (let
        [table : (& s ElfSection) (& (array-ref sections section-index))]
        (when
          (table-kind? table.section-type)
          (set! check.section section-index)
          (let
            [index : i64 0]
            (while (and check.ok (< index table.symbol-count))
              (set! check.entry index)
              (let
                [at : i64 (+ (cast table.file-offset : i64) (* index 24))]
                [name : i64 (le.read-u32 data at)]
                [info : i64 (le.byte-le-at data (+ at 4))]
                [other : i64 (le.byte-le-at data (+ at 5))]
                [raw : i64 (le.read-u16 data (+ at 6))]
                [value : u64 (word data (+ at 8))]
                [size : u64 (word data (+ at 16))]
                [binding : i64 (shr info 4)]
                [symbol-section : ElfSymbolSection
                  (symbol-section! data sections table index raw at check)]
                [name-span : ElfSpan
                  (name-span!
                    data
                    (& (array-ref sections table.link))
                    name
                    check
                    at)]
                [index-offset : i64
                  (if (= raw 65535)
                    (if (>= table.extended-index 0)
                      (+
                        (cast
                          (array-ref sections table.extended-index).file-offset
                          : i64)
                        (* index 4))
                      (+ at 6))
                    (+ at 6))]
                (require!
                  check
                  (if (< index table.info)
                    (= binding 0)
                    (not (= binding 0)))
                  (BadSymbol)
                  (+ at 4))
                (when
                  (= index 0)
                  (require!
                    check
                    (and
                      (= name 0)
                      (= info 0)
                      (= other 0)
                      (= raw 0)
                      (= value (cast 0 : u64))
                      (= size (cast 0 : u64)))
                    (BadSymbol)
                    at))
                (when
                  (= raw 65522)
                  (require! check (alignment? value) (BadSymbol) (+ at 8)))
                (set!
                  (array-ref symbols (+ table.symbol-start index))
                  (ElfSymbol
                    (ElfEntryId (clone table.id) index at)
                    name
                    name-span
                    (symbol-binding binding)
                    (symbol-type (bit-and info 15))
                    (symbol-visibility other)
                    other
                    raw
                    index-offset
                    symbol-section
                    value
                    size)))
              (set! index (+ index 1))))))
      (set! section-index (+ section-index 1)))
    (set! check.section -1)
    (set! check.entry -1)
    symbols))

(define (relocation-kind [number : i64]) : ElfRelocationKind
  (match number
    [0 (NoneRelocation)]
    [1 (Abs64)]
    [2 (Pc32)]
    [3 (Got32)]
    [4 (Plt32)]
    [5 (CopyRelocation)]
    [6 (GlobDat)]
    [7 (JumpSlot)]
    [8 (Relative)]
    [9 (GotPcRel)]
    [10 (Abs32)]
    [11 (Abs32Signed)]
    [12 (Abs16)]
    [13 (Pc16)]
    [14 (Abs8)]
    [15 (Pc8)]
    [16 (DtpMod64)]
    [17 (DtpOff64)]
    [18 (TpOff64)]
    [19 (TlsGd)]
    [20 (TlsLd)]
    [21 (DtpOff32)]
    [22 (GotTpOff)]
    [23 (TpOff32)]
    [24 (Pc64)]
    [25 (GotOff64)]
    [26 (GotPc32)]
    [27 (Got64)]
    [28 (GotPcRel64)]
    [29 (GotPc64)]
    [30 (GotPlt64)]
    [31 (PltOff64)]
    [32 (Size32)]
    [33 (Size64)]
    [34 (GotPc32TlsDesc)]
    [35 (TlsDescCall)]
    [36 (TlsDesc)]
    [37 (IRelative)]
    [38 (Relative64)]
    [41 (GotPcRelX)]
    [42 (RexGotPcRelX)]
    [43 (Code4GotPcRelX)]
    [44 (Code4GotTpOff)]
    [45 (Code4GotPc32TlsDesc)]
    [46 (Code5GotPcRelX)]
    [47 (Code5GotTpOff)]
    [48 (Code5GotPc32TlsDesc)]
    [49 (Code6GotPcRelX)]
    [50 (Code6GotTpOff)]
    [51 (Code6GotPc32TlsDesc)]
    [other (UnknownRelocation other)]))

;; psABI field widths, including the two-word TLS descriptor. COPY and the
;; marker relocations have no fixed field; deprecated/unknown numbers stay -1.
(define (relocation-width [number : i64]) : i64
  (cond
    [(or (= number 0) (= number 5) (= number 35)) 0]
    [(or (= number 12) (= number 13)) 2]
    [(or (= number 14) (= number 15)) 1]
    [(= number 36) 16]
    [(or
        (= number 1)
        (and (>= number 6) (<= number 8))
        (and (>= number 16) (<= number 18))
        (= number 24)
        (= number 25)
        (and (>= number 27) (<= number 31))
        (= number 33)
        (= number 37)
        (= number 38))
      8]
    [(or (and (>= number 0) (<= number 38)) (and (>= number 41) (<= number 51)))
      4]
    [else -1]))

(define (logical-size [section : (& s ElfSection)]) : u64
  (match section.body
    [(Compressed encoding) encoding.size]
    [_ section.size]))

(define (read-relocations
  [data : (& b (__tl_dyn-array u8))]
  [sections : (& s (__tl_dyn-array ElfSection))]
  [counts : (& n ElfCounts)]
  [check : (&mut c ElfCheck)]) : (__tl_dyn-array ElfRelocation)
  (charge-records! check counts.relocations 24 0)
  (unless check.ok (return (__tl_make-array ElfRelocation 0)))
  (let
    [relocations : (__tl_dyn-array ElfRelocation)
      (__tl_make-array ElfRelocation counts.relocations)]
    [section-index : i64 0]
    (while (and check.ok (< section-index (array-length sections)))
      (let
        [section : (& s ElfSection) (& (array-ref sections section-index))]
        (when
          (= section.section-type 4)
          (set! check.section section-index)
          (let
            [table : (& s ElfSection) (& (array-ref sections section.link))]
            [target : (& s ElfSection) (& (array-ref sections section.info))]
            [size : u64 (logical-size target)]
            [index : i64 0]
            (while (and check.ok (< index section.relocation-count))
              (set! check.entry index)
              (let
                [at : i64 (+ (cast section.file-offset : i64) (* index 24))]
                [offset : u64 (word data at)]
                [info : u64 (word data (+ at 8))]
                [symbol : i64 (cast (shr info 32) : i64)]
                [number : i64
                  (cast (bit-and info (cast 4294967295 : u64)) : i64)]
                [width : i64 (relocation-width number)]
                (require!
                  check
                  (< symbol table.symbol-count)
                  (BadRelocation)
                  (+ at 8))
                (require!
                  check
                  (and
                    (<= offset size)
                    (or (<= width 0) (<= (cast width : u64) (- size offset))))
                  (BadRelocation)
                  at)
                (unless check.ok (return relocations))
                (set!
                  (array-ref relocations (+ section.relocation-start index))
                  (ElfRelocation
                    (ElfEntryId (clone section.id) index at)
                    (clone target.id)
                    (ElfEntryId
                      (clone table.id)
                      symbol
                      (+ (cast table.file-offset : i64) (* symbol 24)))
                    offset
                    number
                    (relocation-kind number)
                    width
                    (le.read-u64 data (+ at 16)))))
              (set! index (+ index 1))))))
      (set! section-index (+ section-index 1)))
    (set! check.section -1)
    (set! check.entry -1)
    relocations))

(defstruct ElfGroupData
  (groups (__tl_dyn-array ElfGroup))
  (members (__tl_dyn-array ElfSectionId)))

(define (read-groups
  [data : (& b (__tl_dyn-array u8))]
  [sections : (& s (__tl_dyn-array ElfSection))]
  [counts : (& n ElfCounts)]
  [check : (&mut c ElfCheck)]) : ElfGroupData
  (charge-records! check (array-length sections) 1 0)
  (charge-records! check counts.groups 4 0)
  (charge-records! check counts.members 4 0)
  (unless
    check.ok
    (return
      (ElfGroupData
        (__tl_make-array ElfGroup 0)
        (__tl_make-array ElfSectionId 0))))
  (let
    [groups : (__tl_dyn-array ElfGroup)
      (__tl_make-array ElfGroup counts.groups)]
    [members : (__tl_dyn-array ElfSectionId)
      (__tl_make-array ElfSectionId counts.members)]
    [owners : (__tl_dyn-array i64)
      (__tl_make-array i64 (array-length sections))]
    [section-index : i64 0]
    [cursor : i64 0]
    (while (< section-index (array-length sections))
      (set! (array-ref owners section-index) -1)
      (set! section-index (+ section-index 1)))
    (set! section-index 0)
    (while (and check.ok (< section-index (array-length sections)))
      (let
        [section : (& s ElfSection) (& (array-ref sections section-index))]
        (when
          (= section.section-type 17)
          (set! check.section section-index)
          (set! check.entry -1)
          (let
            [table : (& s ElfSection) (& (array-ref sections section.link))]
            [start : i64 (cast section.file-offset : i64)]
            [count : i64 (- (/ (cast section.size : i64) 4) 1)]
            [index : i64 0]
            (require!
              check
              (< section.info table.symbol-count)
              (BadGroup)
              (+ section.id.offset 44))
            (unless check.ok (return (ElfGroupData groups members)))
            (set!
              (array-ref groups section.group-index)
              (ElfGroup
                (clone section.id)
                (le.read-u32 data start)
                (ElfEntryId
                  (clone table.id)
                  section.info
                  (+ (cast table.file-offset : i64) (* section.info 24)))
                cursor
                count))
            (while (and check.ok (< index count))
              (set! check.entry index)
              (let
                [at : i64 (+ start (* (+ index 1) 4))]
                [member : i64 (le.read-u32 data at)]
                (require!
                  check
                  (and
                    (> member section-index)
                    (< member (array-length sections)))
                  (BadGroup)
                  at)
                (unless check.ok (return (ElfGroupData groups members)))
                (require!
                  check
                  (and
                    (flag? (array-ref sections member).flags 512)
                    (= (array-ref owners member) -1))
                  (BadGroup)
                  at)
                (set! (array-ref owners member) section.group-index)
                (set!
                  (array-ref members cursor)
                  (clone (array-ref sections member).id))
                (set! cursor (+ cursor 1)))
              (set! index (+ index 1))))))
      (set! section-index (+ section-index 1)))
    (set! check.entry -1)
    (set! section-index 0)
    (while (and check.ok (< section-index (array-length sections)))
      (let
        [section : (& s ElfSection) (& (array-ref sections section-index))]
        (set! check.section section-index)
        (when
          (flag? section.flags 512)
          (require!
            check
            (>= (array-ref owners section-index) 0)
            (BadGroup)
            (+ section.id.offset 8))))
      (set! section-index (+ section-index 1)))
    (set! check.section -1)
    (ElfGroupData groups members)))

(define (read-notes
  [data : (& b (__tl_dyn-array u8))]
  [sections : (& s (__tl_dyn-array ElfSection))]
  [counts : (& n ElfCounts)]
  [check : (&mut c ElfCheck)]) : (__tl_dyn-array ElfNote)
  (charge-records! check counts.notes 12 0)
  (unless check.ok (return (__tl_make-array ElfNote 0)))
  (let
    [notes : (__tl_dyn-array ElfNote) (__tl_make-array ElfNote counts.notes)]
    [section-index : i64 0]
    (while (and check.ok (< section-index (array-length sections)))
      (let
        [section : (& s ElfSection) (& (array-ref sections section-index))]
        (when
          (= section.section-type 7)
          (let
            [start : i64 section.payload.offset]
            [at : i64 start]
            [index : i64 0]
            [alignment : i64
              (if (= section.alignment (cast 8 : u64))
                8
                4)]
            (while (< index section.note-count)
              (let
                [owner-size : i64 (le.read-u32 data at)]
                [owner : i64 (+ at 12)]
                [desc-size : i64 (le.read-u32 data (+ at 4))]
                [owner-end : i64 (+ owner owner-size)]
                [padding : i64
                  (% (- alignment (% (- owner-end start) alignment)) alignment)]
                [descriptor : i64 (+ owner-end padding)]
                [end : i64 (+ descriptor desc-size)]
                [tail : i64
                  (% (- alignment (% (- end start) alignment)) alignment)]
                (set!
                  (array-ref notes (+ section.note-start index))
                  (ElfNote
                    (ElfEntryId (clone section.id) index at)
                    (le.read-u32 data (+ at 8))
                    (ElfSpan owner owner-size)
                    (ElfSpan descriptor desc-size)
                    alignment))
                (set! at (+ end tail)))
              (set! index (+ index 1))))))
      (set! section-index (+ section-index 1)))
    notes))

(define (read-object
  [data : (& input (__tl_dyn-array u8))]
  [request : (& r ElfReadRequest)]) : (ElfReadResult input)
  (let
    [check : ElfCheck (new-check request)]
    (match (read-header data (&mut check))
      [(HeaderFailed error) (ReadFailed error)]
      [(HeaderReady header)
        (let
          [counts : ElfCounts (preflight data (& header) (&mut check))]
          (unless check.ok (return (ReadFailed (clone check.error))))
          (let
            [sections : (__tl_dyn-array ElfSection)
              (read-sections data (& header) (&mut check))]
            (check-overlaps! (& header) (& sections) (&mut check))
            (unless check.ok (return (ReadFailed (clone check.error))))
            (let
              [symbols : (__tl_dyn-array ElfSymbol)
                (read-symbols data (& sections) (& counts) (&mut check))]
              (unless check.ok (return (ReadFailed (clone check.error))))
              (let
                [relocations : (__tl_dyn-array ElfRelocation)
                  (read-relocations data (& sections) (& counts) (&mut check))]
                (unless check.ok (return (ReadFailed (clone check.error))))
                (let
                  [group-data : ElfGroupData
                    (read-groups data (& sections) (& counts) (&mut check))]
                  (unless check.ok (return (ReadFailed (clone check.error))))
                  (let
                    [notes : (__tl_dyn-array ElfNote)
                      (read-notes data (& sections) (& counts) (&mut check))]
                    (if check.ok
                      (ReadObject
                        (ElfObject
                          data
                          (clone request.identity)
                          header
                          sections
                          symbols
                          relocations
                          group-data.groups
                          group-data.members
                          notes
                          (- request.limits.max-work check.left)))
                      (ReadFailed (clone check.error)))))))))])))