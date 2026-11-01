;; Canonical container bytes and bounded structural dumps. Dialect writers
;; supply raw names, metadata and physical order; no index/name synthesis.
(import stdlib.iterator)
(import linker_archive_core as archive)
(import stdlib.byte_buf as buf)
(import stdlib.string)

;; Plans own their strings; encode borrows the collection and copies payloads
;; only into the final output buffer. Adapters retain their existing owners.
(defstruct ArchiveEncodeMember
  (raw-name String)
  ;; -1 denotes an explicitly blank date/uid/gid/mode field.
  (metadata (Array i64 4))
  (payload String))

(defenum ArchiveOutputResult
  (:must-use)
  (Output String)
  (OutputFailed archive.ArchiveError))

(define (number-fits?
  [value : i64]
  [width : i64]
  [rule : (& r archive.ArchiveNumberRule)]) : bool
  (if (< value 0)
    (and (= value -1) rule.allow-blank)
    (let
      [remaining : i64 value]
      [digits : i64 1]
      (while (>= remaining rule.radix)
        (set! remaining (/ remaining rule.radix))
        (+= digits 1))
      (and (<= value rule.maximum) (<= digits width)))))

;; The preflight proves value/radix/width validity before this writer runs.
(define (append-number
  [output : buf.ByteBuf]
  [value : i64]
  [radix : i64]
  [width : i64]) : buf.ByteBuf
  (let
    [digits : (Array u8 12) (init : (Array u8 12))]
    [count : i64 0]
    [remaining : i64 value]
    (when
      (>= remaining 0)
      (set! (array-ref digits count) (cast (+ 48 (% remaining radix)) : u8))
      (+= count 1)
      (set! remaining (/ remaining radix))
      (while (> remaining 0)
        (set! (array-ref digits count) (cast (+ 48 (% remaining radix)) : u8))
        (+= count 1)
        (set! remaining (/ remaining radix))))
    (for [index (iterator.range 0 width)]
      (set!
        output
        (buf.push
          output
          (if (< index count)
            (array-ref digits (- (- count index) 1))
            (cast 32 : u8)))))
    output))

(define (encode
  [members : (& m (Slice ArchiveEncodeMember))]
  [identity : archive.ArchiveIdentity]
  [profile : (& p archive.ArchiveProfile)]
  [limits : archive.ArchiveLimits]) : ArchiveOutputResult
  (let
    [count : i64 (array-length members)]
    [patterns : i64 (array-length profile.special-names)]
    [work : i64 limits.max-work]
    [total : i64 8]
    [specials : i64 0]
    (unless
      (archive.valid-limits? (& limits))
      (return
        (OutputFailed (archive.ArchiveError (InvalidLimits) identity -1 0))))
    (when
      (> total limits.max-input-bytes)
      (return (OutputFailed (archive.ArchiveError (InputLimit) identity -1 0))))
    (match (archive.check-profile profile work)
      [(ProfileReady remaining) (set! work remaining)]
      [(ProfileFailed kind offset)
        (return (OutputFailed (archive.ArchiveError kind identity -1 offset)))])
    ;; Validate the entire plan and reserve all output work before allocating.
    (for [index (iterator.range 0 count)]
      (let
        [member : (& m ArchiveEncodeMember) (& (array-ref members index))]
        [size : i64 (string.string-length (& member.payload))]
        [pad : i64 (% size 2)]
        (when
          (>= index limits.max-members)
          (return
            (OutputFailed
              (archive.ArchiveError (MemberLimit) identity index total))))
        (when
          (>= index (/ limits.max-retained-bytes archive.retained-member-bytes))
          (return
            (OutputFailed
              (archive.ArchiveError (RetainedLimit) identity index total))))
        (when
          (or (< work 120) (> patterns (/ (- work 120) 16)))
          (return
            (OutputFailed
              (archive.ArchiveError (WorkLimit) identity index total))))
        (set! work (- (- work 120) (* patterns 16)))
        (unless
          (archive.valid-name? (& member.raw-name) profile.ascii-names)
          (return
            (OutputFailed (archive.ArchiveError (BadName) identity index total))))
        (for [field (iterator.range 0 5)]
          (unless
            (number-fits?
              (if (= field 4)
                size
                (array-ref member.metadata field))
              (array-ref archive.field-widths field)
              (& (array-ref profile.numbers field)))
            (return
              (OutputFailed
                (archive.ArchiveError
                  (InvalidEncoder)
                  identity
                  index
                  (+ total (array-ref archive.field-starts field)))))))
        (when
          (archive.special-name-at? (& member.raw-name) 0 profile)
          (when
            (>= specials limits.max-special-members)
            (return
              (OutputFailed
                (archive.ArchiveError (SpecialLimit) identity index total))))
          (+= specials 1))
        ;; Subtraction checks make each subsequent addition representable.
        (when
          (or
            (< (- limits.max-input-bytes total) 60)
            (> size (- (- limits.max-input-bytes total) 60)))
          (return
            (OutputFailed
              (archive.ArchiveError (InputLimit) identity index total))))
        (set! total (+ (+ total 60) size))
        (when
          (> pad (- limits.max-input-bytes total))
          (return
            (OutputFailed
              (archive.ArchiveError (InputLimit) identity index total))))
        (+= total pad)))
    ;; Zero-initialization, writes and the final String copy are all bounded.
    (when
      (> total (/ work 3))
      (return
        (OutputFailed (archive.ArchiveError (WorkLimit) identity -1 total))))
    (let
      [output : buf.ByteBuf (buf.with-capacity total)]
      (set! output (buf.append-bytes output (buf.str-as-bytes "!<arch>\n")))
      (for [member-index (iterator.range 0 count)]
        (let
          [member : (& m ArchiveEncodeMember)
            (& (array-ref members member-index))]
          [size : i64 (string.string-length (& member.payload))]
          (set!
            output
            (buf.append-bytes output (buf.str-as-bytes (& member.raw-name))))
          (for [field (iterator.range 0 5)]
            (let
              [rule : (& p archive.ArchiveNumberRule)
                (& (array-ref profile.numbers field))]
              (set!
                output
                (append-number
                  output
                  (if (= field 4)
                    size
                    (array-ref member.metadata field))
                  rule.radix
                  (array-ref archive.field-widths field)))))
          (set! output (buf.append-bytes output (buf.str-as-bytes "`\n")))
          (set!
            output
            (buf.append-bytes output (buf.str-as-bytes (& member.payload))))
          (when
            (!= (% size 2) 0)
            (set! output (buf.push output (cast 10 : u8))))))
      (Output (buf.to-string output)))))

(define (append-hex [output : buf.ByteBuf] [value : u64] [digits : i64]) : buf.ByteBuf
  (let
    [index : i64 digits]
    (while (> index 0)
      (let
        [shift : i64 (* (- index 1) 4)]
        [digit : i64 (cast (bit-and (shr value shift) (cast 15 : u64)) : i64)]
        (set!
          output
          (buf.push
            output
            (cast
              (if (< digit 10)
                (+ digit 48)
                (+ digit 87))
              : u8)))
        (-= index 1)))
    output))

;; Fixed-width hex is locale independent and makes the allocation bound exact.
;; One archive row (42 bytes), then one physical-member row (103 bytes) each.
;; Dumping shares the session work budget but does not claim/open any payload.
(define (dump
  [directory : (& d (archive.ArchiveDirectory input))]
  [session : (&mut s archive.ArchiveSession)]) : ArchiveOutputResult
  (let
    [identity : archive.ArchiveIdentity (clone directory.identity)]
    [count : i64 (array-length directory.members)]
    (match (archive.check-session directory (& session))
      [(InvalidId kind)
        (return (OutputFailed (archive.ArchiveError kind identity -1 0)))]
      [(ValidId) unit])
    (when
      (>= count session.limits.max-diagnostic-rows)
      (return
        (OutputFailed (archive.ArchiveError (DiagnosticLimit) identity -1 0))))
    (when
      (or (< session.work-left 126) (> count (/ (- session.work-left 126) 309)))
      (return (OutputFailed (archive.ArchiveError (WorkLimit) identity -1 0))))
    (let
      [total : i64 (+ 42 (* count 103))]
      [output : buf.ByteBuf (buf.with-capacity total)]
      (-= session.work-left (* total 3))
      (set! output (buf.append-bytes output (buf.str-as-bytes "archive ")))
      (set! output (append-hex output identity.input 16))
      (set! output (buf.push output (cast 58 : u8)))
      (set! output (append-hex output identity.content 16))
      (set! output (buf.push output (cast 10 : u8)))
      (for [index (iterator.range 0 count)]
        (let
          [member : (& d archive.ArchiveMember)
            (& (array-ref directory.members index))]
          [values : (Array i64 4)
            (array
              member.id.ordinal
              member.id.header-offset
              member.payload-offset
              member.payload-size)]
          (for [field (iterator.range 0 4)]
            (set!
              output
              (append-hex output (cast (array-ref values field) : u64) 16))
            (set! output (buf.push output (cast 32 : u8))))
          (for [byte (iterator.range 0 16)]
            (set!
              output
              (append-hex
                output
                (cast (array-ref member.raw-name byte) : u64)
                2)))
          (set! output (buf.push output (cast 32 : u8)))
          (set!
            output
            (buf.push
              output
              (cast
                (if member.special
                  83
                  79)
                : u8)))
          (set! output (buf.push output (cast 10 : u8)))))
      (Output (buf.to-string output)))))