;; Ordinary archive compatibility for #7038/#8302; never a canonical-writer
;; admission test. All spans borrow the checked container's immutable bytes.
(import linker_archive_core as archive)
(import stdlib.byte_reader as reader)
(import stdlib.string)

;; BSD ranlib words are native-endian on disk. The caller selects the input
;; ABI explicitly; neither the host nor a file/path spelling selects it.
(defenum ArDialect
  (GnuSystemV)
  (BsdLittleEndian)
  (BsdBigEndian))

(defenum ArMemberKind
  (Ordinary)
  (LongNames)
  (SymbolIndex i64 bool bool))

;; word width, BSD layout, sorted names
(defstruct ArMember
  (kind ArMemberKind)
  (name-offset i64)
  (name-size i64)
  (content-offset i64)
  (content-size i64))

;; Hints retain index order, including duplicates. A resolver must parse the
;; target and verify its symbols before committing a hint (#7038/#7099).
(defstruct ArSymbolHint
  (name-offset i64)
  (name-size i64)
  (target archive.ArchiveMemberId))

(defstruct ArArchive
  (:lifetimes input)
  (directory (archive.ArchiveDirectory input))
  (session archive.ArchiveSession)
  (members (__tl_dyn-array ArMember))
  (index-member i64)
  (hints (__tl_dyn-array ArSymbolHint)))

(defenum ArErrorKind
  (Container archive.ArchiveErrorKind)
  (WrongDialect)
  (BadName)
  (NameReference)
  (NameLength)
  (UnterminatedName)
  (SpecialOrder)
  (IndexSize)
  (NumberOverflow)
  (StringOffset)
  (UnterminatedSymbol)
  (TrailingData)
  (UnsortedIndex))

;; One fixed diagnostic, with the physical index member, entry ordinal and
;; offending absolute byte offset. value retains even an overflowing u64.
(defstruct ArError
  (kind ArErrorKind)
  (archive archive.ArchiveIdentity)
  (member i64)
  (entry i64)
  (offset i64)
  (value u64))

(defenum ArReadResult
  (:lifetimes input)
  (:must-use)
  (ReadArchive (ArArchive input))
  (ReadFailed ArError))

(defstruct ArCheck
  (ok bool)
  (error ArError)
  (work-left i64)
  (retained-left i64))

(define (container-error [error : archive.ArchiveError]) : ArError
  (ArError
    (Container error.kind)
    error.archive
    error.ordinal
    -1
    error.offset
    (cast error.offset : u64)))

(define (fail!
  [check : (&mut c ArCheck)]
  [kind : ArErrorKind]
  [offset : i64]
  [value : u64]) : unit
  (when
    check.ok
    (set! check.ok false)
    (set! check.error.kind kind)
    (set! check.error.offset offset)
    (set! check.error.value value)))

(define (charge! [check : (&mut c ArCheck)] [count : i64] [offset : i64]) : bool
  (when
    (and check.ok (or (< count 0) (> count check.work-left)))
    (fail! check (Container (WorkLimit)) offset (cast count : u64)))
  (when check.ok (set! check.work-left (- check.work-left count)))
  check.ok)

(define (reserve!
  [check : (&mut c ArCheck)]
  [count : i64]
  [width : i64]
  [offset : i64]) : bool
  (when
    (and check.ok (> count (/ check.retained-left width)))
    (fail! check (Container (RetainedLimit)) offset (cast count : u64)))
  (when
    check.ok
    (set! check.retained-left (- check.retained-left (* count width))))
  check.ok)

(define (gnu? [dialect : ArDialect]) : bool
  (match dialect
    [(GnuSystemV) true]
    [_ false]))

(define (profile [dialect : ArDialect]) : archive.ArchiveProfile
  (archive.ArchiveProfile
    (match dialect
      [(GnuSystemV) (cast 83010 : u64)]
      [(BsdLittleEndian) (cast 83011 : u64)]
      [(BsdBigEndian) (cast 83012 : u64)])
    (array
      (archive.ArchiveNumberRule 10 true 999999999999)
      (archive.ArchiveNumberRule 10 true 999999)
      (archive.ArchiveNumberRule 10 true 999999)
      (archive.ArchiveNumberRule 8 true 16777215)
      (archive.ArchiveNumberRule 10 false 9999999999))
    ;; BSD extended names are classified after resolution, before index maps.
    (__tl_make-array String 0)
    false
    false))

(define (name-is?
  [data : (& d str)]
  [start : i64]
  [size : i64]
  [expected : (& e str)]) : bool
  (and
    (= size (string.string-length expected))
    (string.is-string-prefix-at data expected start)))

(define (classify [data : (& d str)] [start : i64] [size : i64]) : ArMemberKind
  (cond
    [(name-is? data start size "//") (LongNames)]
    [(name-is? data start size "/") (SymbolIndex 4 false false)]
    [(name-is? data start size "/SYM64/") (SymbolIndex 8 false false)]
    [(name-is? data start size "__.SYMDEF") (SymbolIndex 4 true false)]
    [(name-is? data start size "__.SYMDEF SORTED") (SymbolIndex 4 true true)]
    [(name-is? data start size "__.SYMDEF_64") (SymbolIndex 8 true false)]
    [(name-is? data start size "__.SYMDEF_64 SORTED") (SymbolIndex 8 true true)]
    [else (Ordinary)]))

(define (decimal!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [start : i64]
  [size : i64]) : i64
  (when (<= size 0) (fail! check (BadName) start (cast 0 : u64)) (return 0))
  (let
    [rule : archive.ArchiveNumberRule
      (archive.ArchiveNumberRule 10 false 9223372036854775807)]
    (match (archive.read-number data start size (& rule))
      [(Number value _) value]
      [(NumberFailed kind offset)
        (fail! check (Container kind) offset (cast 0 : u64))
        0])))

;; Each long-table entry has a /LF delimiter; the sole final LF used by GNU
;; ar to make the table even-sized is padding, never an empty named entry.
(define (long-name-end!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [at : i64 start]
    (while (and (< at end) (charge! check 1 at))
      (let
        [byte : char (string.string-ref data at)]
        (when
          (= byte '\n')
          (if (and (> at start) (= (string.string-ref data (- at 1)) '/'))
            (return (- at 1))
            (begin
              (fail! check (UnterminatedName) at (cast 0 : u64))
              (return start))))
        (when
          (= byte '\0')
          (fail! check (BadName) at (cast 0 : u64))
          (return start)))
      (set! at (+ at 1)))
    (fail! check (UnterminatedName) end (cast 0 : u64))
    start))

(define (check-long-table!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [start : i64]
  [size : i64]) : unit
  (let
    [at : i64 start]
    [end : i64 (+ start size)]
    (while (and check.ok (< at end))
      (when
        (and
          (= at (- end 1))
          (= (% size 2) 0)
          (= (string.string-ref data at) '\n'))
        (unless (charge! check 1 at) (return unit))
        (return unit))
      (let
        [last : i64 (long-name-end! check data at end)]
        (unless check.ok (return unit))
        (set! at (+ last 2))))))

(define (resolve-name!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [raw : (& r archive.ArchiveMember)]
  [dialect : ArDialect]
  [table-start : i64]
  [table-size : i64]) : ArMember
  (let
    [start : i64 raw.id.header-offset]
    [size : i64 16]
    [content : i64 raw.payload-offset]
    [content-size : i64 raw.payload-size]
    [short-name : bool true]
    [gnu-reference : bool false]
    (unless
      (charge! check 192 start)
      (return (ArMember (Ordinary) start 0 content content-size)))
    (while (and
      (> size 0)
      (= (string.string-ref data (+ start (- size 1))) ' '))
      (set! size (- size 1)))
    (cond
      [(and (>= size 3) (string.is-string-prefix-at data "#1/" start))
        (set! short-name false)
        (when (gnu? dialect) (fail! check (WrongDialect) start (cast 0 : u64)))
        (let
          [length : i64 (decimal! check data (+ start 3) (- size 3))]
          (when
            (> length content-size)
            (fail! check (NameLength) content (cast length : u64)))
          (unless
            check.ok
            (return (ArMember (Ordinary) start 0 content content-size)))
          (set! start content)
          (set! size length)
          (set! content (+ content length))
          (set! content-size (- content-size length))
          (unless
            (charge! check length start)
            (return (ArMember (Ordinary) start 0 content content-size)))
          (while (and
            (> size 0)
            (= (string.string-ref data (+ start (- size 1))) '\0'))
            (set! size (- size 1))))]
      [(and
        (> size 1)
        (= (string.string-ref data start) '/')
        (match (classify data start size)
          [(Ordinary) true]
          [_ false]))
        (set! short-name false)
        (set! gnu-reference true)
        (unless
          (gnu? dialect)
          (fail! check (WrongDialect) start (cast 0 : u64)))
        (let
          [relative : i64 (decimal! check data (+ start 1) (- size 1))]
          (when
            (or
              (< table-start 0)
              (>= relative table-size)
              (and
                (> relative 0)
                (or
                  (< relative 2)
                  (!=
                    (string.string-ref data (+ table-start (- relative 1)))
                    '\n')
                  (!=
                    (string.string-ref data (+ table-start (- relative 2)))
                    '/'))))
            (fail! check (NameReference) start (cast relative : u64)))
          (unless
            check.ok
            (return (ArMember (Ordinary) start 0 content content-size)))
          (set! start (+ table-start relative))
          (set!
            size
            (-
              (long-name-end! check data start (+ table-start table-size))
              start)))]
      [else unit])
    (let
      ;; A GNU /N is an ordinary member even when its resolved filename has
      ;; a reserved spelling. Only the raw short field carries that policy.
      [kind : ArMemberKind
        (if gnu-reference
          (Ordinary)
          (classify data start size))]
      (match kind
        [(Ordinary)
          (when
            (and
              short-name
              (gnu? dialect)
              (> size 0)
              (= (string.string-ref data (+ start (- size 1))) '/'))
            (set! size (- size 1)))]
        [_ unit])
      (when
        (charge! check size start)
        (let
          [at : i64 0]
          (while (< at size)
            (when
              (= (string.string-ref data (+ start at)) '\0')
              (fail! check (BadName) (+ start at) (cast 0 : u64)))
            (set! at (+ at 1)))))
      (ArMember kind start size content content-size))))

;; Decode an unsigned word only after proving the entire span. Reject values
;; outside the signed offset domain before multiplication or pointer arithmetic.
(define (word!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [at : i64]
  [end : i64]
  [width : i64]
  [little : bool]) : i64
  (unless
    (reader.range-present? end at width)
    (fail! check (IndexSize) at (cast width : u64))
    (return 0))
  (unless (charge! check width at) (return 0))
  (let
    [value : u64 (cast 0 : u64)]
    [i : i64 0]
    (while (< i width)
      (let
        [index : i64
          (if little
            (- (- width 1) i)
            i)]
        (set!
          value
          (bit-or
            (shl value 8)
            (cast (string.string-ref data (+ at index)) : u64))))
      (set! i (+ i 1)))
    (when
      (> value (cast 9223372036854775807 : u64))
      (fail! check (NumberOverflow) at value)
      (return 0))
    (cast value : i64)))

(define (symbol-end!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [at : i64 start]
    (while (and (< at end) (charge! check 1 at))
      (when (= (string.string-ref data at) '\0') (return at))
      (set! at (+ at 1)))
    (fail! check (UnterminatedSymbol) end (cast 0 : u64))
    start))

(define (check-tail!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [start : i64]
  [at : i64]
  [end : i64]
  [alignment : i64]) : unit
  (let
    [padding : i64 (% (- alignment (% (- at start) alignment)) alignment)]
    (when
      (and (!= at end) (!= (- end at) padding))
      (fail! check (TrailingData) at (cast (- end at) : u64)))
    (while (and (< at end) (charge! check 1 at))
      (when
        (!= (string.string-ref data at) '\0')
        (fail! check (TrailingData) at (cast (string.string-ref data at) : u64)))
      (set! at (+ at 1)))))

(define (ordered!
  [check : (&mut c ArCheck)]
  [data : (& d str)]
  [before : (& a ArSymbolHint)]
  [after : (& b ArSymbolHint)]) : bool
  (let
    [i : i64 0]
    (while (and (< i before.name-size) (< i after.name-size))
      (unless (charge! check 2 after.name-offset) (return false))
      (let
        [a : char (string.string-ref data (+ before.name-offset i))]
        [b : char (string.string-ref data (+ after.name-offset i))]
        (when (!= a b) (return (< a b))))
      (set! i (+ i 1)))
    (<= before.name-size after.name-size)))

(define (read-index!
  [check : (&mut c ArCheck)]
  [directory : (& d (archive.ArchiveDirectory input))]
  [session : (&mut s archive.ArchiveSession)]
  [member : (& m ArMember)]
  [dialect : ArDialect]) : (__tl_dyn-array ArSymbolHint)
  (let
    [empty : (__tl_dyn-array ArSymbolHint) (__tl_make-array ArSymbolHint 0)]
    [start : i64 member.content-offset]
    [end : i64 (+ start member.content-size)]
    (match member.kind
      [(SymbolIndex width bsd sorted)
        (let
          [little : bool
            (and
              bsd
              (match dialect
                [(BsdLittleEndian) true]
                [_ false]))]
          [raw-count : i64 (word! check directory.bytes start end width little)]
          [stride : i64
            (if bsd
              (* width 2)
              width)]
          [count : i64
            (if bsd
              (/ raw-count stride)
              raw-count)]
          (when
            (or
              (and bsd (!= (% raw-count stride) 0))
              (not (reader.range-present? end start width))
              (> count (/ (- (- end start) width) stride)))
            (fail! check (IndexSize) start (cast raw-count : u64)))
          (when
            (> count directory.limits.max-index-entries)
            (fail! check (Container (IndexLimit)) start (cast count : u64)))
          (unless
            (and
              check.ok
              (reserve!
                check
                count
                (comptime (size-of (type ArSymbolHint)))
                start))
            (return empty))
          (let
            [strings : i64 (+ (+ start width) (* count stride))]
            [strings-end : i64 end]
            [at : i64 0]
            (when
              bsd
              (let
                [size : i64
                  (word! check directory.bytes strings end width little)]
                (unless check.ok (return empty))
                (set! strings (+ strings width))
                (unless
                  (reader.range-present? end strings size)
                  (fail! check (IndexSize) (- strings width) (cast size : u64)))
                (unless check.ok (return empty))
                (set! strings-end (+ strings size))
                (when
                  (and
                    (> size 0)
                    (!=
                      (string.string-ref directory.bytes (- strings-end 1))
                      '\0'))
                  (fail! check (UnterminatedSymbol) strings-end (cast 0 : u64)))))
            (unless check.ok (return empty))
            (let
              [hints : (__tl_dyn-array ArSymbolHint)
                (__tl_make-array ArSymbolHint count)]
              [next-name : i64 strings]
              (while (and check.ok (< at count))
                (set! check.error.entry at)
                (let
                  [row : i64 (+ (+ start width) (* at stride))]
                  [name : i64 next-name]
                  (when
                    bsd
                    (let
                      [relative : i64
                        (word! check directory.bytes row end width little)]
                      (when
                        (>= relative (- strings-end strings))
                        (fail! check (StringOffset) row (cast relative : u64)))
                      (unless check.ok (return empty))
                      (set! name (+ strings relative))))
                  (let
                    [offset-at : i64
                      (+
                        row
                        (if bsd
                          width
                          0))]
                    [offset : i64
                      (word! check directory.bytes offset-at end width little)]
                    [name-end : i64
                      (symbol-end! check directory.bytes name strings-end)]
                    (unless check.ok (return empty))
                    (set! session.work-left check.work-left)
                    (match (archive.map-index! directory session offset true)
                      [(IndexFailed error)
                        (fail!
                          check
                          (Container error.kind)
                          offset-at
                          (cast offset : u64))]
                      [(IndexMapped id)
                        (set!
                          (array-ref hints at)
                          (ArSymbolHint name (- name-end name) id))])
                    (set! check.work-left session.work-left)
                    (when
                      (and
                        check.ok
                        sorted
                        (> at 0)
                        (not
                          (ordered!
                            check
                            directory.bytes
                            (& (array-ref hints (- at 1)))
                            (& (array-ref hints at)))))
                      (fail! check (UnsortedIndex) row (cast at : u64)))
                    (set! next-name (+ name-end 1))))
                (set! at (+ at 1)))
              (when check.ok (set! check.error.entry -1))
              (check-tail!
                check
                directory.bytes
                start
                (if bsd
                  strings-end
                  next-name)
                end
                (if bsd
                  8
                  2))
              hints)))]
      [_ empty])))

(define (resolve
  [directory : (archive.ArchiveDirectory input)]
  [dialect : ArDialect]) : (ArReadResult input)
  (let
    [count : i64 (array-length directory.members)]
    [check : ArCheck
      (ArCheck
        true
        (ArError (BadName) (clone directory.identity) -1 -1 0 (cast 0 : u64))
        directory.work-left
        (-
          directory.limits.max-retained-bytes
          (* count archive.retained-member-bytes)))]
    (unless
      (reserve! (&mut check) count (comptime (size-of (type ArMember))) 0)
      (return (ReadFailed check.error)))
    (match (archive.new-session (& directory))
      [(SessionFailed error) (ReadFailed (container-error error))]
      [(SessionReady session)
        (set! check.work-left session.work-left)
        (let
          [members : (__tl_dyn-array ArMember) (__tl_make-array ArMember count)]
          [at : i64 0]
          [index-member : i64 -1]
          [table-start : i64 -1]
          [table-size : i64 0]
          [specials : i64 0]
          [ordinary : bool false]
          (while (and check.ok (< at count))
            (set! check.error.member at)
            (let
              [raw : (& directory archive.ArchiveMember)
                (& (array-ref directory.members at))]
              [member : ArMember
                (resolve-name!
                  (&mut check)
                  directory.bytes
                  raw
                  dialect
                  table-start
                  table-size)]
              [special : bool
                (match member.kind
                  [(Ordinary) false]
                  [_ true])]
              (unless check.ok (return (ReadFailed check.error)))
              (when
                special
                (when
                  (>= specials directory.limits.max-special-members)
                  (fail!
                    (&mut check)
                    (Container (SpecialLimit))
                    raw.id.header-offset
                    (cast specials : u64)))
                (when
                  ordinary
                  (fail!
                    (&mut check)
                    (SpecialOrder)
                    raw.id.header-offset
                    (cast at : u64)))
                (set! specials (+ specials 1)))
              (match member.kind
                [(Ordinary) (set! ordinary true)]
                [(LongNames)
                  (unless
                    (gnu? dialect)
                    (fail!
                      (&mut check)
                      (WrongDialect)
                      raw.id.header-offset
                      (cast 0 : u64)))
                  (when
                    (>= table-start 0)
                    (fail!
                      (&mut check)
                      (SpecialOrder)
                      raw.id.header-offset
                      (cast at : u64)))
                  (set! table-start member.content-offset)
                  (set! table-size member.content-size)
                  (check-long-table!
                    (&mut check)
                    directory.bytes
                    table-start
                    table-size)]
                [(SymbolIndex _ bsd _)
                  (when
                    (= bsd (gnu? dialect))
                    (fail!
                      (&mut check)
                      (WrongDialect)
                      raw.id.header-offset
                      (cast 0 : u64)))
                  (when
                    (or (!= at 0) (>= index-member 0))
                    (fail!
                      (&mut check)
                      (SpecialOrder)
                      raw.id.header-offset
                      (cast at : u64)))
                  (set! index-member at)])
              (set! (array-ref members at) member)
              (set! (array-ref directory.members at).special special))
            (set! at (+ at 1)))
          (unless check.ok (return (ReadFailed check.error)))
          (set! check.error.member index-member)
          (let
            [hints : (__tl_dyn-array ArSymbolHint)
              (if (< index-member 0)
                (__tl_make-array ArSymbolHint 0)
                (read-index!
                  (&mut check)
                  (& directory)
                  (&mut session)
                  (& (array-ref members index-member))
                  dialect))]
            (if check.ok
              (begin
                (set! session.work-left check.work-left)
                (ReadArchive
                  (ArArchive directory session members index-member hints)))
              (ReadFailed check.error))))])))

(define (read
  [data : (& input str)]
  [identity : archive.ArchiveIdentity]
  [dialect : ArDialect]
  [limits : archive.ArchiveLimits]) : (ArReadResult input)
  (let
    [policy : archive.ArchiveProfile (profile dialect)]
    (match (archive.scan data identity (& policy) limits)
      [(ScanFailed error) (ReadFailed (container-error error))]
      [(Scanned directory) (resolve directory dialect)])))