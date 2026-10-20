;; Pure AMD64 short-import syntax. Archive selection and symbol/import liveness
;; belong to #7102; #7175 consumes the normalized live imports for PE layout.
(import linker_archive_core as archive)
(import linker_coff_import_member_writer as imports)
(import stdlib.byte_le as le)
(import stdlib.byte_reader as reader)
(import stdlib.byte_buf_core as bytes)
(import stdlib.str_cat_runtime as cat)

(defstruct CoffImportReadLimits
  (max-input-bytes i64)
  (max-name-bytes i64)
  (max-output-bytes i64)
  (max-work i64))

(define (default-limits) : CoffImportReadLimits
  (CoffImportReadLimits 16777216 4096 32768 268435520))

(defenum CoffImportErrorKind
  (InvalidLimits)
  (InvalidMember)
  (InputLimit)
  (NameLimit)
  (OutputLimit)
  (WorkLimit)
  (MalformedHeader)
  (UnsupportedVersion)
  (UnsupportedMachine)
  (UnsupportedKind)
  (ReservedBits)
  (UnsupportedNameMode)
  (UnsupportedExportAs)
  (SizeMismatch)
  (UnterminatedString)
  (InvalidName)
  (TrailingData)
  (ZeroOrdinal))

;; The physical archive ID is supplied by the caller, never an archive name.
;; Field is static text; offset is relative to the member payload, not its ar
;; header. A failure copies no hostile input and retains one bounded record.
(defstruct CoffImportError
  (kind CoffImportErrorKind)
  (member archive.ArchiveMemberId)
  (field String)
  (offset i64))

;; The plan shares the encoder's exact code/data/const and name-mode contract.
;; DLL identity is ASCII-folded; written DLL/public names and timestamp remain
;; provenance. Timestamp and hint must not enter a resolver's identity/order.
;; Code defines a public thunk; data exposes only its literal IAT symbol; const
;; may also expose a public IAT alias. No symbol winner is selected here.
(defstruct CoffImportRecord
  (member archive.ArchiveMemberId)
  (timestamp i64)
  (dll-spelling String)
  (dll-key String)
  (plan imports.CoffImportPlan)
  (iat-symbol String)
  (public-offset i64)
  (dll-offset i64))

;; Other COFF results validate only the fixed header and table extents. Their
;; section/symbol semantics remain the ordinary/bigobj reader's responsibility.
(defenum CoffImportReadResult
  (:must-use)
  (ShortImport CoffImportRecord)
  (OrdinaryCoff)
  (BigObj)
  (ReadFailed CoffImportError))

(define (failed
  [member : archive.ArchiveMemberId]
  [kind : CoffImportErrorKind]
  [field : String]
  [offset : i64]) : CoffImportReadResult
  (ReadFailed (CoffImportError kind member field offset)))

(define (limits-valid? [limits : (& l CoffImportReadLimits)]) : bool
  (and
    (>= limits.max-input-bytes 0)
    (<= limits.max-input-bytes 16777216)
    (>= limits.max-name-bytes 0)
    (<= limits.max-name-bytes 4096)
    (>= limits.max-output-bytes 0)
    (<= limits.max-output-bytes 1048576)
    (>= limits.max-work 0)
    (<= limits.max-work 268435520)))

(define (object-tables-fit? [data : (& d (__tl_dyn-array u8))] [big : bool]) : bool
  (let
    [n : i64 (array-length data)]
    [header : i64
      (if big
        56
        20)]
    [optional : i64
      (if big
        0
        (le.read-u16 data 16))]
    [sections : i64
      (if big
        (le.read-u32 data 44)
        (le.read-u16 data 2))]
    [symbols : i64
      (le.read-u32
        data
        (if big
          52
          12))]
    [offset : i64
      (le.read-u32
        data
        (if big
          48
          8))]
    [width : i64
      (if big
        20
        18)]
    (unless (reader.range-present? n header optional) (return false))
    (when (> sections (/ (- (- n header) optional) 40)) (return false))
    (if (= offset 0)
      (= symbols 0)
      (and
        (>= offset (+ header optional (* sections 40)))
        (reader.range-present? n offset 4)
        (<= symbols (/ (- (- n offset) 4) width))
        (let
          [strings : i64 (+ offset (* symbols width))]
          [size : i64 (le.read-u32 data strings)]
          (and (>= size 4) (reader.range-present? n strings size)))))))

(define (string-end [data : (& d (__tl_dyn-array u8))] [start : i64]) : i64
  (let
    [at : i64 start]
    (while (and (< at (array-length data)) (not (= (array-ref data at) 0)))
      (set! at (+ at 1)))
    (if (< at (array-length data))
      at
      -1)))

(define (copy-text
  [data : (& d (__tl_dyn-array u8))]
  [start : i64]
  [size : i64]
  [fold : bool]) : String
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-with-capacity size)]
    [at : i64 start]
    (while (< at (+ start size))
      (let
        [value : i64 (le.byte-le-at data at)]
        (bytes.byte-buf-builder-push
          (&mut out)
          (cast
            (if (and fold (>= value 65) (<= value 90))
              (+ value 32)
              value)
            : u8))
        (set! at (+ at 1))))
    (bytes.byte-buf-builder-to-string (& out))))

(define (read
  [data : (& d (__tl_dyn-array u8))]
  [member : archive.ArchiveMemberId]
  [limits : (& l CoffImportReadLimits)]) : CoffImportReadResult
  (let
    [n : i64 (array-length data)]
    (unless
      (limits-valid? limits)
      (return (failed member (InvalidLimits) "limits" 0)))
    (when
      (or (< member.ordinal 0) (< member.header-offset 0))
      (return (failed member (InvalidMember) "member" 0)))
    (when
      (> n limits.max-input-bytes)
      (return (failed member (InputLimit) "member" 0)))
    ;; Two string scans, portable-name checks, ASCII folding and owned copies
    ;; visit at most sixteen times the input bytes, plus fixed header work.
    ;; Charge the bound before touching fields or allocating output strings.
    (when
      (> (+ 64 (* 16 n)) limits.max-work)
      (return (failed member (WorkLimit) "member" 0)))
    (when (< n 20) (return (failed member (MalformedHeader) "header" n)))
    (let
      [sig1 : i64 (le.read-u16 data 0)]
      [sig2 : i64 (le.read-u16 data 2)]
      [version : i64 (le.read-u16 data 4)]
      (when
        (= sig1 0x8664)
        (return
          (if (object-tables-fit? data false)
            (OrdinaryCoff)
            (failed member (MalformedHeader) "COFF tables" 2))))
      (unless
        (= sig1 0)
        (return (failed member (UnsupportedMachine) "Machine/Sig1" 0)))
      (unless
        (= sig2 0xffff)
        (return (failed member (MalformedHeader) "Sig2" 2)))
      (when
        (= version 2)
        (when
          (< n 56)
          (return (failed member (MalformedHeader) "bigobj header" n)))
        (unless
          (= (le.read-u16 data 6) 0x8664)
          (return (failed member (UnsupportedMachine) "Machine" 6)))
        (let
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
          [i : i64 0]
          (while (< i 16)
            (unless
              (= (array-ref data (+ 12 i)) (array-ref magic i))
              (return (failed member (MalformedHeader) "bigobj UUID" (+ 12 i))))
            (set! i (+ i 1))))
        (return
          (if (object-tables-fit? data true)
            (BigObj)
            (failed member (MalformedHeader) "bigobj tables" 44))))
      (unless
        (= version 0)
        (return (failed member (UnsupportedVersion) "Version" 4)))
      (unless
        (= (le.read-u16 data 6) 0x8664)
        (return (failed member (UnsupportedMachine) "Machine" 6))))
    (let
      [size : i64 (le.read-u32 data 12)]
      [hint : i64 (le.read-u16 data 16)]
      [info : i64 (le.read-u16 data 18)]
      [kind : i64 (bit-and info 3)]
      [mode : i64 (bit-and (shr info 2) 7)]
      (unless
        (= (shr info 5) 0)
        (return (failed member (ReservedBits) "Reserved" 18)))
      (when (= kind 3) (return (failed member (UnsupportedKind) "Type" 18)))
      (when
        (= mode 4)
        (return (failed member (UnsupportedExportAs) "IMPORT_NAME_EXPORTAS" 18)))
      (when
        (> mode 4)
        (return (failed member (UnsupportedNameMode) "NameType" 18)))
      (unless
        (= size (- n 20))
        (return (failed member (SizeMismatch) "SizeOfData" 12)))
      (when
        (and (= mode 0) (= hint 0))
        (return (failed member (ZeroOrdinal) "Ordinal" 16)))
      (let
        [public-end : i64 (string-end data 20)]
        (when
          (< public-end 0)
          (return (failed member (UnterminatedString) "public name" n)))
        (let
          [dll-start : i64 (+ public-end 1)]
          [dll-end : i64 (string-end data dll-start)]
          [public-size : i64 (- public-end 20)]
          [dll-size : i64 (- dll-end dll-start)]
          (when
            (< dll-end 0)
            (return (failed member (UnterminatedString) "DLL name" n)))
          (unless
            (= (+ dll-end 1) n)
            (return
              (failed member (TrailingData) "string region" (+ dll-end 1))))
          (when
            (> (+ public-size 6) limits.max-name-bytes)
            (return (failed member (NameLimit) "public/IAT name" 20)))
          (when
            (> dll-size limits.max-name-bytes)
            (return (failed member (NameLimit) "DLL name" dll-start)))
          ;; Reserve the worst-case retained string bytes before copying: public,
          ;; transformed import, literal IAT, written DLL and folded DLL key.
          (when
            (> (+ 6 (* 3 public-size) (* 2 dll-size)) limits.max-output-bytes)
            (return (failed member (OutputLimit) "normalized strings" 20)))
          (let
            [public : String (copy-text data 20 public-size false)]
            [dll : String (copy-text data dll-start dll-size false)]
            (unless
              (imports.coff-import-valid-name? (& public) true)
              (return (failed member (InvalidName) "public name" 20)))
            (unless
              (imports.coff-import-valid-dll-part? (& dll))
              (return (failed member (InvalidName) "DLL basename" dll-start)))
            (let
              [import-name : String
                (if (= mode 0)
                  ""
                  (imports.coff-import-effective-name (clone public) mode))]
              (when
                (and
                  (not (= mode 0))
                  (not (imports.coff-import-valid-name? (& import-name) true)))
                (return
                  (failed member (InvalidName) "transformed import name" 20)))
              (ShortImport
                (CoffImportRecord
                  member
                  (le.read-u32 data 8)
                  dll
                  (copy-text data dll-start dll-size true)
                  (imports.CoffImportPlan
                    (clone public)
                    import-name
                    (if (= mode 0)
                      hint
                      0)
                    (if (= mode 0)
                      0
                      hint)
                    kind
                    mode)
                  (cat.str-cat "__imp_" public)
                  20
                  dll-start)))))))))