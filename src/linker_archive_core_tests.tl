(import linker_archive_core as archive)
(import linker_archive_output as output)
(import stdlib.byte_buf as buf)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)
(import stdlib.profile as runtime-profile)

(define (profile) : archive.ArchiveProfile
  (archive.ArchiveProfile
    (cast 1 : u64)
    (array
      (archive.ArchiveNumberRule 10 true 999999999999)
      (archive.ArchiveNumberRule 10 true 999999)
      (archive.ArchiveNumberRule 10 true 999999)
      (archive.ArchiveNumberRule 8 true 16777215)
      (archive.ArchiveNumberRule 10 false 9999999999))
    (__tl_make-array String 0)
    true
    false))

(define (limits) : archive.ArchiveLimits
  (archive.ArchiveLimits 1048576 128 65536 16 128 256 1048576))

(define (identity) : archive.ArchiveIdentity
  (archive.ArchiveIdentity (cast 41 : u64) (cast 73 : u64)))

(define (one-member) : String
  (cat.str-cat
    "!<arch>\n"
    "dup/            "
    "0           "
    "0     "
    "0     "
    "644     "
    "3         "
    "`\n"
    "abc\n"))

(define (assert-empty) : unit
  (let
    [data : String "!<arch>\n"]
    [policy : archive.ArchiveProfile (profile)]
    (match (archive.scan (& data) (identity) (& policy) (limits))
      [(archive.Scanned directory)
        (test.assert-i64-eq (array-length directory.members) 0 "empty archive")]
      [_ (test.assert-true false "empty archive must scan")])))

(define (assert-open) : unit
  (let
    [data : String (one-member)]
    [policy : archive.ArchiveProfile (profile)]
    (begin
      (test.assert-i64-eq (string.string-length (& data)) 72 "fixture size")
      (match (archive.scan (& data) (identity) (& policy) (limits))
        [(archive.Scanned directory)
          (begin
            (test.assert-i64-eq (array-length directory.members) 1 "one member")
            (match (archive.new-session (& directory))
              [(archive.SessionReady session)
                (match (archive.map-index! (& directory) (&mut session) 8 true)
                  [(archive.IndexMapped id)
                    (match (archive.open! (& directory) (&mut session) id)
                      [(archive.Opened opened payload)
                        (begin
                          (test.assert-i64-eq
                            opened.header-offset
                            8
                            "header provenance")
                          (match (archive.open! (& directory) (&mut session) id)
                            [(archive.AlreadyOpened again)
                              (test.assert-i64-eq
                                again.ordinal
                                0
                                "repeated claim identity")]
                            [_ (test.assert-true false "load once")])
                          (test.assert-true
                            (string.eq payload "abc")
                            "retained borrowed payload"))]
                      [_ (test.assert-true false "first open")])]
                  [_ (test.assert-true false "existing header target")])]
              [_ (test.assert-true false "session")]))]
        [_ (test.assert-true false "one-member scan")]))))

(define (kind-code [kind : archive.ArchiveErrorKind]) : i64
  (match kind
    [(archive.InvalidLimits) 1]
    [(archive.InvalidProfile) 2]
    [(archive.InputLimit) 3]
    [(archive.MemberLimit) 4]
    [(archive.RetainedLimit) 5]
    [(archive.SpecialLimit) 6]
    [(archive.IndexLimit) 7]
    [(archive.WorkLimit) 8]
    [(archive.DiagnosticLimit) 9]
    [(archive.BadSignature) 10]
    [(archive.TruncatedHeader) 11]
    [(archive.BadTerminator) 12]
    [(archive.BadNumeric) 13]
    [(archive.NumericOverflow) 14]
    [(archive.BadName) 15]
    [(archive.BadPadding) 16]
    [(archive.PayloadRange) 17]
    [(archive.WrongInput) 18]
    [(archive.StaleIdentity) 19]
    [(archive.InvalidMember) 20]
    [(archive.InvalidIndexTarget) 21]
    [(archive.SpecialTarget) 22]
    [(archive.InvalidEncoder) 23]))

(define (assert-error
  [error : archive.ArchiveError]
  [kind : i64]
  [ordinal : i64]
  [offset : i64]) : unit
  (begin
    (test.assert-i64-eq (kind-code error.kind) kind "error kind")
    (test.assert-i64-eq error.ordinal ordinal "error member provenance")
    (test.assert-i64-eq error.offset offset "error byte provenance")
    (test.assert-true
      (= error.archive.input (cast 41 : u64))
      "error input identity")
    (test.assert-true
      (= error.archive.content (cast 73 : u64))
      "error content identity")))

(define (assert-scan-error
  [data : (& d str)]
  [policy : (& p archive.ArchiveProfile)]
  [caps : archive.ArchiveLimits]
  [kind : i64]
  [ordinal : i64]
  [offset : i64]) : unit
  (match (archive.scan data (identity) policy caps)
    [(archive.ScanFailed error) (assert-error error kind ordinal offset)]
    [_ (test.assert-true false "invalid archive accepted")]))

(define (patch [data : (& d str)] [offset : i64] [byte : i64]) : String
  (let
    [out : buf.ByteBuf (buf.append-bytes (buf.new) (buf.str-as-bytes data))]
    (begin
      (buf.bytes-set! (buf.as-mut-bytes (&mut out)) offset (cast byte : u8))
      (buf.to-string out))))

(define (assert-truncations) : unit
  (let
    [data : String (one-member)]
    [policy : archive.ArchiveProfile (profile)]
    [length : i64 0]
    (begin
      ;; Every byte boundary of the signature, header, payload and odd pad.
      (while (< length 72)
        (begin
          (if (= length 8)
            (match (archive.scan
              (string.substring-view (& data) 0 length)
              (identity)
              (& policy)
              (limits))
              [(archive.Scanned _) unit]
              [_ (test.assert-true false "signature-only prefix")])
            (assert-scan-error
              (string.substring-view (& data) 0 length)
              (& policy)
              (limits)
              (cond
                [(< length 8) 10]
                [(< length 68) 11]
                [(< length 71) 17]
                [else 16])
              (if (< length 8)
                -1
                0)
              (cond
                [(< length 8) 0]
                [(< length 68) 8]
                [(< length 71) 68]
                [else 71])))
          (set! length (+ length 1))))
      (let
        [trailing : String (cat.str-cat data "x")]
        (assert-scan-error (& trailing) (& policy) (limits) 11 1 72)))))

(defstruct BadByte
  (offset i64)
  (value i64)
  (kind i64)
  (error-offset i64))

(define (assert-bad-bytes) : unit
  (let
    [data : String (one-member)]
    [policy : archive.ArchiveProfile (profile)]
    [cases : (Array BadByte 14)
      (array
        (BadByte 0 63 10 0)
        (BadByte 7 13 10 0)
        (BadByte 8 0 15 8)
        (BadByte 23 255 15 8)
        (BadByte 24 45 13 24)
        (BadByte 26 57 13 26)
        (BadByte 36 43 13 36)
        (BadByte 42 9 13 42)
        (BadByte 48 56 13 48)
        (BadByte 56 32 13 56)
        (BadByte 58 57 13 58)
        (BadByte 66 39 12 66)
        (BadByte 67 13 12 66)
        (BadByte 71 0 16 71))]
    [index : i64 0]
    (begin
      (while (< index (array-length cases))
        (let
          [item : BadByte (array-ref cases index)]
          [changed : String (patch (& data) item.offset item.value)]
          (begin
            (assert-scan-error
              (& changed)
              (& policy)
              (limits)
              item.kind
              (if (< item.offset 8)
                -1
                0)
              item.error-offset)
            (set! index (+ index 1)))))
      ;; A declared giant payload and a removed inter-member pad fail at the
      ;; container boundary; no object or name parser is needed to reject them.
      (let
        [large : String
          (cat.str-cat (string.substring data 0 56) "9999999999`\nabc\n")]
        (assert-scan-error (& large) (& policy) (limits) 17 0 68))
      (let
        [unaligned : String
          (cat.str-cat
            (string.substring data 0 71)
            (string.substring data 8 64))]
        (assert-scan-error (& unaligned) (& policy) (limits) 16 0 71))
      (set! policy.allow-unpadded-final true)
      (match (archive.scan
        (string.substring-view (& data) 0 71)
        (identity)
        (& policy)
        (limits))
        [(archive.Scanned directory)
          (test.assert-i64-eq
            (array-length directory.members)
            1
            "explicit final pad policy")]
        [_ (test.assert-true false "permitted unpadded final payload")]))))

(defstruct NumberCase
  (text String)
  (radix i64)
  (blank bool)
  (maximum i64)
  (value i64)
  (kind i64)
  (offset i64))

(define (assert-numbers) : unit
  (let
    [cases : (Array NumberCase 12)
      (array
        (NumberCase "999999999999" 10 false 999999999999 999999999999 0 0)
        (NumberCase "77777777" 8 false 16777215 16777215 0 0)
        (NumberCase
          "9223372036854775807"
          10
          false
          9223372036854775807
          9223372036854775807
          0
          0)
        (NumberCase "9223372036854775808" 10 false 9223372036854775807 0 14 18)
        (NumberCase "18446744073709551615" 10 false 9223372036854775807 0 14 19)
        (NumberCase "0   " 10 false 0 0 0 0)
        (NumberCase "1" 10 false 0 0 14 0)
        (NumberCase "    " 10 true 99 0 0 0)
        (NumberCase "    " 10 false 99 0 13 0)
        (NumberCase " 1" 10 true 99 0 13 1)
        (NumberCase "8" 8 false 99 0 13 0)
        (NumberCase "1\t" 10 false 99 0 13 1))]
    [index : i64 0]
    (while (< index (array-length cases))
      (let
        [item : (& cases NumberCase) (& (array-ref cases index))]
        [rule : archive.ArchiveNumberRule
          (archive.ArchiveNumberRule item.radix item.blank item.maximum)]
        (begin
          (match (archive.read-number
            (& item.text)
            0
            (string.string-length (& item.text))
            (& rule))
            [(archive.Number value blank)
              (begin
                (test.assert-i64-eq item.kind 0 "numeric success")
                (test.assert-i64-eq value item.value "numeric maximum/value")
                (test.assert-bool-eq
                  blank
                  (string.eq (& item.text) "    ")
                  "blank metadata"))]
            [(archive.NumberFailed kind offset)
              (begin
                (test.assert-i64-eq (kind-code kind) item.kind "numeric error")
                (test.assert-i64-eq offset item.offset "numeric error byte"))])
          (set! index (+ index 1)))))))

(define (assert-scan-limits) : unit
  (let
    [data : String (one-member)]
    [policy : archive.ArchiveProfile (profile)]
    [caps : archive.ArchiveLimits (limits)]
    (begin
      (set! caps.max-input-bytes 71)
      (assert-scan-error (& data) (& policy) caps 3 -1 0)
      (set! caps (limits))
      (set! caps.max-members 0)
      (assert-scan-error (& data) (& policy) caps 4 0 8)
      (set! caps (limits))
      (set! caps.max-retained-bytes (- archive.retained-member-bytes 1))
      (assert-scan-error (& data) (& policy) caps 5 0 8)
      (set! caps (limits))
      (set! caps.max-work 12)
      (assert-scan-error (& data) (& policy) caps 8 -1 0)
      (set! caps (limits))
      (set! caps.max-work 149)
      (assert-scan-error (& data) (& policy) caps 8 0 8)
      (set! caps (limits))
      (set! caps.max-diagnostic-rows 0)
      (assert-scan-error (& data) (& policy) caps 1 -1 0)
      (set! caps (limits))
      (set! caps.max-index-entries -1)
      (assert-scan-error (& data) (& policy) caps 1 -1 0)
      (set! caps (limits))
      (set! policy.special-names (__tl_make-array String 1))
      (set! (array-ref policy.special-names 0) "dup/            ")
      (set! caps.max-special-members 0)
      (assert-scan-error (& data) (& policy) caps 6 0 8)
      ;; All four scan caps exactly sufficient; profile comparisons are charged.
      (set! caps.max-input-bytes 72)
      (set! caps.max-members 1)
      (set! caps.max-retained-bytes archive.retained-member-bytes)
      (set! caps.max-special-members 1)
      (set! caps.max-work 199)
      (match (archive.scan (& data) (identity) (& policy) caps)
        [(archive.Scanned directory)
          (begin
            (test.assert-i64-eq directory.work-left 0 "exact scan work cap")
            (match (archive.new-session (& directory))
              [(archive.SessionFailed error) (assert-error error 8 -1 0)]
              [_ (test.assert-true false "session initialization needs budget")]))]
        [_ (test.assert-true false "exact scan limits")])
      (set! (array-ref policy.special-names 0) "short")
      (assert-scan-error (& data) (& policy) (limits) 2 -1 0)
      (set! policy (profile))
      (set! (array-ref policy.numbers 4) (archive.ArchiveNumberRule 8 false 99))
      (assert-scan-error (& data) (& policy) (limits) 2 -1 4)
      (set! (array-ref policy.numbers 4) (archive.ArchiveNumberRule 10 true 99))
      (assert-scan-error (& data) (& policy) (limits) 2 -1 4)
      (set! (array-ref policy.numbers 0) (archive.ArchiveNumberRule 2 false 99))
      (assert-scan-error (& data) (& policy) (limits) 2 -1 0))))

(define (multi-member) : String
  (let
    [policy : archive.ArchiveProfile (profile)]
    [plans : (Array output.ArchiveEncodeMember 3)
      (array
        (output.ArchiveEncodeMember "dup/            " (array 0 0 0 420) "abc")
        (output.ArchiveEncodeMember
          "dup/            "
          (array 999999999999 999999 999999 16777215)
          "xy")
        (output.ArchiveEncodeMember "/               " (array -1 -1 -1 -1) ""))]
    (match (output.encode (& plans) (identity) (& policy) (limits))
      [(output.Output bytes) bytes]
      [_
        (begin
          (test.assert-true false "canonical encode")
          "")])))

(define (special-profile) : archive.ArchiveProfile
  (let
    [policy : archive.ArchiveProfile (profile)]
    (begin
      (set! policy.special-names (__tl_make-array String 1))
      (set! (array-ref policy.special-names 0) "/               ")
      policy)))

(define (assert-output-error
  [result : output.ArchiveOutputResult]
  [kind : i64]
  [ordinal : i64]
  [offset : i64]) : unit
  (match result
    [(output.OutputFailed error) (assert-error error kind ordinal offset)]
    [_ (test.assert-true false "output should fail")]))

(define (assert-index-error
  [result : archive.ArchiveIndexResult]
  [kind : i64]
  [ordinal : i64]
  [offset : i64]) : unit
  (match result
    [(archive.IndexFailed error) (assert-error error kind ordinal offset)]
    [_ (test.assert-true false "index should fail")]))

(define (assert-claim-error
  [result : (archive.ArchiveClaimResult input)]
  [kind : i64]
  [ordinal : i64]
  [offset : i64]) : unit
  (match result
    [(archive.ClaimFailed error) (assert-error error kind ordinal offset)]
    [_ (test.assert-true false "claim should fail")]))

(define (assert-members) : unit
  (let
    [data : String (multi-member)]
    [policy : archive.ArchiveProfile (special-profile)]
    [golden : String
      (cat.str-cat
        (one-member)
        "dup/            999999999999999999999999777777772         `\nxy"
        "/                                               0         `\n")]
    (begin
      (test.assert-true
        (string.eq (& data) (& golden))
        "canonical bytes, maxima and blanks")
      (test.assert-true
        (string.eq (& data) (multi-member))
        "deterministic encoder")
      (match (archive.scan (& data) (identity) (& policy) (limits))
        [(archive.Scanned directory)
          (begin
            (test.assert-i64-eq
              (array-length directory.members)
              3
              "three physical members")
            (match (archive.new-session (& directory))
              [(archive.SessionReady session)
                (let
                  [one : (& directory archive.ArchiveMember)
                    (& (array-ref directory.members 0))]
                  [two : (& directory archive.ArchiveMember)
                    (& (array-ref directory.members 1))]
                  [three : (& directory archive.ArchiveMember)
                    (& (array-ref directory.members 2))]
                  [first : archive.ArchiveMemberId (clone one.id)]
                  [second : archive.ArchiveMemberId (clone two.id)]
                  [third : archive.ArchiveMemberId (clone three.id)]
                  (begin
                    (test.assert-i64-eq first.header-offset 8 "first header")
                    (test.assert-i64-eq
                      second.header-offset
                      72
                      "even second header")
                    (test.assert-i64-eq
                      third.header-offset
                      134
                      "empty special header")
                    (test.assert-true
                      (!= first.ordinal second.ordinal)
                      "duplicate names distinct")
                    (assert-index-error
                      (archive.map-index! (& directory) (&mut session) 134 true)
                      22
                      2
                      134)
                    (match (archive.map-index!
                      (& directory)
                      (&mut session)
                      134
                      false)
                      [(archive.IndexMapped id)
                        (test.assert-i64-eq
                          id.ordinal
                          2
                          "special hook identity")]
                      [_ (test.assert-true false "special hook")])
                    (match (archive.open! (& directory) (&mut session) first)
                      [(archive.Opened _ payload)
                        (begin
                          (match (archive.open!
                            (& directory)
                            (&mut session)
                            second)
                            [(archive.Opened id second-payload)
                              (begin
                                (test.assert-i64-eq id.ordinal 1 "second claim")
                                (test.assert-true
                                  (string.eq second-payload "xy")
                                  "even payload"))]
                            [_
                              (test.assert-true
                                false
                                "distinct duplicate claim")])
                          (test.assert-true
                            (string.eq payload "abc")
                            "payload survives another claim")
                          (unsafe
                            (test.assert-true
                              (=
                                (ptr->int (string-data payload))
                                (ptr->int
                                  (ptr-offset (string-data (& data)) 68)))
                              "payload borrows exact source span")))]
                      [_ (test.assert-true false "first claim")])
                    (match (archive.open! (& directory) (&mut session) third)
                      [(archive.Opened _ payload)
                        (test.assert-i64-eq
                          (string.string-length payload)
                          0
                          "empty payload")]
                      [_ (test.assert-true false "special payload")])
                    (match (archive.open! (& directory) (&mut session) first)
                      [(archive.AlreadyOpened id)
                        (test.assert-i64-eq
                          id.header-offset
                          8
                          "repeat stable ID")]
                      [_ (test.assert-true false "first stays claimed")])
                    (match (output.dump (& directory) (&mut session))
                      [(output.Output dump)
                        (begin
                          (test.assert-i64-eq
                            (string.string-length (& dump))
                            351
                            "bounded dump size")
                          (test.assert-string-eq
                            (string.substring-view (& dump) 0 145)
                            "archive 0000000000000029:0000000000000049\n0000000000000000 0000000000000008 0000000000000044 0000000000000003 6475702f202020202020202020202020 O\n"
                            "stable dump golden")
                          (match (output.dump (& directory) (&mut session))
                            [(output.Output again)
                              (test.assert-true
                                (string.eq (& dump) (& again))
                                "repeat dump")]
                            [_ (test.assert-true false "repeat dump budget")]))]
                      [_ (test.assert-true false "directory dump")])))]
              [_ (test.assert-true false "multi session")]))]
        [_ (test.assert-true false "encode/rescan")]))))

(define (assert-invalid-requests) : unit
  (let
    [data : String (multi-member)]
    [policy : archive.ArchiveProfile (special-profile)]
    (match (archive.scan (& data) (identity) (& policy) (limits))
      [(archive.Scanned directory)
        (match (archive.new-session (& directory))
          [(archive.SessionReady session)
            (let
              [offsets : (Array i64 9)
                (array -1 0 7 9 68 71 73 194 9223372036854775807)]
              [index : i64 0]
              [bad : archive.ArchiveMemberId
                (archive.ArchiveMemberId (identity) -1 8)]
              (begin
                (while (< index (array-length offsets))
                  (let
                    [offset : i64 (array-ref offsets index)]
                    (begin
                      (assert-index-error
                        (archive.map-index!
                          (& directory)
                          (&mut session)
                          offset
                          false)
                        21
                        -1
                        offset)
                      (set! index (+ index 1)))))
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  20
                  -1
                  8)
                (set! bad.ordinal 3)
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  20
                  3
                  8)
                (set! bad.ordinal 0)
                (set! bad.header-offset 72)
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  20
                  0
                  72)
                (set! bad.header-offset 8)
                (set! bad.archive.input (cast 42 : u64))
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  18
                  0
                  8)
                (set! bad.archive.input (cast 41 : u64))
                (set! bad.archive.content (cast 74 : u64))
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  19
                  0
                  8)
                (set! bad.archive.content (cast 73 : u64))
                (match (archive.open! (& directory) (&mut session) bad)
                  [(archive.Opened _ _) unit]
                  [_ (test.assert-true false "invalid IDs never claim")])
                (set! session.limits.max-index-entries session.index-entries)
                (assert-index-error
                  (archive.map-index! (& directory) (&mut session) 8 true)
                  7
                  -1
                  8)
                (set! session.limits.max-diagnostic-rows 3)
                (assert-output-error
                  (output.dump (& directory) (&mut session))
                  9
                  -1
                  0)
                (set! session.limits.max-diagnostic-rows 4)
                (set! session.work-left 1052)
                (assert-output-error
                  (output.dump (& directory) (&mut session))
                  8
                  -1
                  0)
                (set! session.work-left 0)
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  8
                  0
                  8)
                (set! session.limits.max-index-entries 100)
                (assert-index-error
                  (archive.map-index! (& directory) (&mut session) 8 true)
                  8
                  -1
                  8)
                (set! session.work-left 1)
                (assert-index-error
                  (archive.map-index! (& directory) (&mut session) 8 true)
                  8
                  -1
                  8)
                (set! session.work-left 100)
                (set! session.profile-tag (cast 2 : u64))
                (assert-claim-error
                  (archive.open! (& directory) (&mut session) bad)
                  2
                  0
                  8)
                (set! session.profile-tag (cast 1 : u64))
                ;; A session belongs to its input/content revision too.
                (let
                  [foreign : archive.ArchiveIdentity
                    (archive.ArchiveIdentity (cast 42 : u64) (cast 73 : u64))]
                  (match (archive.scan (& data) foreign (& policy) (limits))
                    [(archive.Scanned other)
                      (assert-claim-error
                        (archive.open! (& other) (&mut session) bad)
                        18
                        0
                        8)]
                    [_ (test.assert-true false "foreign directory")]))
                (let
                  [stale : archive.ArchiveIdentity
                    (archive.ArchiveIdentity (cast 41 : u64) (cast 74 : u64))]
                  (match (archive.scan (& data) stale (& policy) (limits))
                    [(archive.Scanned other)
                      (assert-index-error
                        (archive.map-index! (& other) (&mut session) 8 true)
                        19
                        -1
                        8)]
                    [_ (test.assert-true false "new revision directory")]))))]
          [_ (test.assert-true false "request session")])]
      [_ (test.assert-true false "request directory")])))

(define (assert-encoder-errors) : unit
  (let
    [plans : (Array output.ArchiveEncodeMember 1)
      (array
        (output.ArchiveEncodeMember "dup/            " (array 0 0 0 420) "abc"))]
    [policy : archive.ArchiveProfile (profile)]
    [caps : archive.ArchiveLimits (limits)]
    (begin
      (set!
        (array-ref plans 0)
        (output.ArchiveEncodeMember "dup/            " (array 0 0 0 420) "abc"))
      (set! caps.max-input-bytes 71)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        3
        0
        71)
      (set! caps.max-input-bytes 70)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        3
        0
        8)
      (set! caps.max-input-bytes 7)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        3
        -1
        0)
      (set! caps (limits))
      (set! caps.max-members 0)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        4
        0
        8)
      (set! caps (limits))
      (set! caps.max-retained-bytes 0)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        5
        0
        8)
      (set! caps (limits))
      (set! caps.max-work 348)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        8
        -1
        72)
      (set! caps.max-work 132)
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        8
        0
        8)
      (set! caps.max-work 349)
      (match (output.encode (& plans) (identity) (& policy) caps)
        [(output.Output data)
          (test.assert-true
            (string.eq (& data) (one-member))
            "exact encoder work")]
        [_ (test.assert-true false "exact encoder cap")])
      (set! caps (limits))
      (set!
        (array-ref plans 0)
        (output.ArchiveEncodeMember "short" (array 0 0 0 0) ""))
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        15
        0
        8)
      (set!
        (array-ref plans 0)
        (output.ArchiveEncodeMember "dup/            " (array -2 0 0 0) ""))
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        23
        0
        24)
      (set!
        (array-ref plans 0)
        (output.ArchiveEncodeMember "dup/            " (array 0 1000000 0 0) ""))
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        23
        0
        36)
      (set!
        (array-ref policy.numbers 1)
        (archive.ArchiveNumberRule 10 true 9223372036854775807))
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        23
        0
        36)
      (set! policy (special-profile))
      (set! caps.max-special-members 0)
      (set!
        (array-ref plans 0)
        (output.ArchiveEncodeMember "/               " (array 0 0 0 0) ""))
      (assert-output-error
        (output.encode (& plans) (identity) (& policy) caps)
        6
        0
        8)
      (match (output.encode (slice-view plans 0 0) (identity) (& policy) caps)
        [(output.Output data)
          (test.assert-true (string.eq (& data) "!<arch>\n") "empty encode")]
        [_ (test.assert-true false "empty encoder")]))))

(define (assert-binary-and-ranges) : unit
  (let
    [data : String (one-member)]
    [binary : String (patch (& data) 8 0)]
    [policy : archive.ArchiveProfile (profile)]
    [rule : archive.ArchiveNumberRule
      (archive.ArchiveNumberRule 10 false 9223372036854775807)]
    (begin
      (set! binary (patch (& binary) 68 255))
      (set! policy.ascii-names false)
      (match (archive.scan (& binary) (identity) (& policy) (limits))
        [(archive.Scanned directory)
          (let
            [member : (& directory archive.ArchiveMember)
              (& (array-ref directory.members 0))]
            (begin
              (test.assert-true
                (= (array-ref member.raw-name 0) (cast 0 : u8))
                "raw name preserves NUL")
              (match (archive.new-session (& directory))
                [(archive.SessionReady session)
                  (match (archive.open!
                    (& directory)
                    (&mut session)
                    (clone member.id))
                    [(archive.Opened _ payload)
                      (test.assert-i64-eq
                        (cast (string.string-ref payload 0) : i64)
                        255
                        "opaque binary payload")]
                    [_ (test.assert-true false "binary open")])]
                [_ (test.assert-true false "binary session")])))]
        [_ (test.assert-true false "explicit raw-name policy")])
      (match (archive.read-number
        "9"
        9223372036854775807
        9223372036854775807
        (& rule))
        [(archive.NumberFailed kind offset)
          (begin
            (test.assert-i64-eq (kind-code kind) 2 "overflowing field range")
            (test.assert-i64-eq
              offset
              9223372036854775807
              "overflow provenance"))]
        [_ (test.assert-true false "overflowing field range accepted")])
      (match (archive.read-number "9" -1 1 (& rule))
        [(archive.NumberFailed _ _) unit]
        [_ (test.assert-true false "negative field range")]))))

;; A fixed small mutation corpus exercises every byte without generating large
;; archives. Repeated scans must agree on the entire structured failure or the
;; member count; accepted layouts retain checked, aligned payload spans.
(define (assert-mutations) : unit
  (let
    [data : String (one-member)]
    [policy : archive.ArchiveProfile (profile)]
    [values : (Array i64 9) (array 0 9 10 32 47 48 57 127 255)]
    [at : i64 0]
    (while (< at 72)
      (let
        [index : i64 0]
        (begin
          (while (< index 9)
            (let
              [changed : String (patch (& data) at (array-ref values index))]
              (begin
                (match (archive.scan (& changed) (identity) (& policy) (limits))
                  [(archive.ScanFailed first)
                    (assert-scan-error
                      (& changed)
                      (& policy)
                      (limits)
                      (kind-code first.kind)
                      first.ordinal
                      first.offset)]
                  [(archive.Scanned first)
                    (begin
                      (match (archive.scan
                        (& changed)
                        (identity)
                        (& policy)
                        (limits))
                        [(archive.Scanned second)
                          (test.assert-i64-eq
                            (array-length second.members)
                            (array-length first.members)
                            "deterministic member count")]
                        [_ (test.assert-true false "nondeterministic scan")])
                      (let
                        [member : (& first archive.ArchiveMember)
                          (& (array-ref first.members 0))]
                        (begin
                          (test.assert-i64-eq
                            member.id.header-offset
                            8
                            "mutation header identity")
                          (test.assert-i64-eq
                            member.payload-offset
                            68
                            "mutation payload start")
                          (test.assert-true
                            (and
                              (>= member.payload-size 0)
                              (<= member.payload-size 4))
                            "mutation bounded payload"))))])
                (set! index (+ index 1)))))
          (set! at (+ at 1)))))))

(define (scan-allocation [data : (& d str)]) : i64
  (let
    [policy : archive.ArchiveProfile (profile)]
    [before : i64 (runtime-profile.alloc-total)]
    (begin
      (match (archive.scan data (identity) (& policy) (limits))
        [(archive.Scanned directory)
          (test.assert-i64-eq
            (array-length directory.members)
            1
            "allocation fixture")]
        [_ (test.assert-true false "allocation fixture scan")])
      (- (runtime-profile.alloc-total) before))))

(define (assert-allocation-bound) : unit
  (let
    [payload : buf.ByteBuf (buf.with-capacity 8192)]
    [index : i64 0]
    [policy : archive.ArchiveProfile (profile)]
    (begin
      (while (< index 8192)
        (begin
          (set! payload (buf.push payload (cast 255 : u8)))
          (set! index (+ index 1))))
      (let
        [plans : (Array output.ArchiveEncodeMember 1)
          (array
            (output.ArchiveEncodeMember
              "large/          "
              (array 0 0 0 0)
              (buf.to-string payload)))]
        [small : String (one-member)]
        [small-allocation : i64 (scan-allocation (& small))]
        (match (output.encode (& plans) (identity) (& policy) (limits))
          [(output.Output large)
            (let
              [large-allocation : i64 (scan-allocation (& large))]
              (begin
                (test.assert-i64-eq
                  large-allocation
                  small-allocation
                  "scan allocation independent of payload bytes")
                (test.assert-true
                  (<= large-allocation 512)
                  "one-member metadata allocation bound")))]
          [_ (test.assert-true false "allocation encoder fixture")])))))

(test archive-empty (assert-empty))

(test archive-open (assert-open))

(test archive-truncations (assert-truncations))

(test archive-bad-bytes (assert-bad-bytes))

(test archive-numbers (assert-numbers))

(test archive-scan-limits (assert-scan-limits))

(test archive-members (assert-members))

(test archive-invalid-requests (assert-invalid-requests))

(test archive-encoder-errors (assert-encoder-errors))

(test archive-binary-and-ranges (assert-binary-and-ranges))

(test archive-mutations (assert-mutations))

(test archive-allocation-bound (assert-allocation-bound))

(define (main) : i64
  (begin
    (assert-empty)
    (assert-open)
    (assert-truncations)
    (assert-bad-bytes)
    (assert-numbers)
    (assert-scan-limits)
    (assert-members)
    (assert-invalid-requests)
    (assert-encoder-errors)
    (assert-binary-and-ranges)
    (assert-mutations)
    (assert-allocation-bound)
    42))