;; Checked, target-neutral ar containers for #7033, #7038 and #7244.
;; Payloads borrow the immutable input; names and indexes remain dialect policy.
(import compiler_incremental_binary as binary)
(import stdlib.string)

;; The caller assigns stable input and content/revision tokens. Reusing a
;; content token for changed bytes violates the input contract. These tokens
;; identify provenance; they are not secret or unforgeable capabilities.
(defstruct ArchiveIdentity
  (input u64)
  (content u64))

(defstruct ArchiveMemberId
  (archive ArchiveIdentity)
  (ordinal i64)
  (header-offset i64))

(defstruct ArchiveNumberRule
  (radix i64)
  (allow-blank bool)
  (maximum i64))

;; Rules are date, uid, gid, mode, size, in physical field order. Size must
;; be nonblank decimal. Special names are exact, padded, sixteen-byte fields.
;; A profile tag is supplied explicitly, never inferred from an input path.
(defstruct ArchiveProfile
  (tag u64)
  (numbers (Array ArchiveNumberRule 5))
  (special-names (__tl_dyn-array String))
  (ascii-names bool)
  (allow-unpadded-final bool))

(defstruct ArchiveLimits
  (max-input-bytes i64)
  (max-members i64)
  (max-retained-bytes i64)
  (max-special-members i64)
  (max-index-entries i64)
  (max-diagnostic-rows i64)
  (max-work i64))

(defenum ArchiveErrorKind
  (InvalidLimits)
  (InvalidProfile)
  (InputLimit)
  (MemberLimit)
  (RetainedLimit)
  (SpecialLimit)
  (IndexLimit)
  (WorkLimit)
  (DiagnosticLimit)
  (BadSignature)
  (TruncatedHeader)
  (BadTerminator)
  (BadNumeric)
  (NumericOverflow)
  (BadName)
  (BadPadding)
  (PayloadRange)
  (WrongInput)
  (StaleIdentity)
  (InvalidMember)
  (InvalidIndexTarget)
  (SpecialTarget)
  (InvalidEncoder))

;; A failure is one fixed-size value, with no copied input or hostile text.
;; ordinal=-1 denotes the archive/profile rather than a physical member.
(defstruct ArchiveError
  (kind ArchiveErrorKind)
  (archive ArchiveIdentity)
  (ordinal i64)
  (offset i64))

(defstruct ArchiveMember
  (id ArchiveMemberId)
  (payload-offset i64)
  (payload-size i64)
  (raw-name (Array u8 16))
  (special bool))

;; Consumers and dialect hooks borrow this directory immutably. Payload views
;; keep its source input alive; mutable claim bookkeeping stays separate.
(defstruct ArchiveDirectory
  (:lifetimes input)
  (bytes (& input str))
  (identity ArchiveIdentity)
  (profile-tag u64)
  (members (__tl_dyn-array ArchiveMember))
  (limits ArchiveLimits)
  (work-left i64))

(defenum ArchiveScanResult
  (:lifetimes input)
  (:must-use)
  (Scanned (ArchiveDirectory input))
  (ScanFailed ArchiveError))

(defstruct ArchiveSession
  (identity ArchiveIdentity)
  (profile-tag u64)
  (limits ArchiveLimits)
  (claimed (__tl_dyn-array bool))
  (index-entries i64)
  (work-left i64))

(defenum ArchiveSessionResult
  (:must-use)
  (SessionReady ArchiveSession)
  (SessionFailed ArchiveError))

(defenum ArchiveClaimResult
  (:lifetimes input)
  (:must-use)
  (Opened ArchiveMemberId (& input str))
  (AlreadyOpened ArchiveMemberId)
  (ClaimFailed ArchiveError))

(defenum ArchiveIndexResult
  (:must-use)
  (IndexMapped ArchiveMemberId)
  (IndexFailed ArchiveError))

(defenum ArchiveIdCheck
  (ValidId)
  (InvalidId ArchiveErrorKind))

(defenum ArchiveNumberResult
  (:must-use)
  (Number i64 bool)
  (NumberFailed ArchiveErrorKind i64))

(define field-starts : (Array i64 5)
  (array 16 28 34 40 48))
(define field-widths : (Array i64 5)
  (array 12 6 6 8 10))
(define retained-member-bytes : i64
  ;; Reserve the two-word payload view record as well as the claim slot.
  (comptime (+ (+ (size-of (type ArchiveMember)) (size-of (type bool))) 16)))

(define (valid-limits? [limits : (& l ArchiveLimits)]) : bool
  (and
    (>= limits.max-input-bytes 0)
    (>= limits.max-members 0)
    (>= limits.max-retained-bytes 0)
    (>= limits.max-special-members 0)
    (>= limits.max-index-entries 0)
    (>= limits.max-diagnostic-rows 1)
    (>= limits.max-work 0)))

(define (valid-rule? [rule : (& r ArchiveNumberRule)]) : bool
  (and (or (= rule.radix 8) (= rule.radix 10)) (>= rule.maximum 0)))

;; Left-justified digits followed only by ASCII spaces; a blank is explicit.
;; Check the caller maximum before multiplication and addition, including for
;; a wider adapter-supplied field than the common header's twelve-byte maximum.
(define (read-number
  [data : (& d str)]
  [start : i64]
  [width : i64]
  [rule : (& r ArchiveNumberRule)]) : ArchiveNumberResult
  (if (or
    (not (valid-rule? rule))
    (<= width 0)
    (not
      (binary.compiler-incremental-binary-range-present?
        (string.string-length data)
        start
        width)))
    (NumberFailed (InvalidProfile) start)
    (let
      [index : i64 0]
      [value : i64 0]
      [digits : i64 0]
      [padding : bool false]
      (begin
        (while (< index width)
          (let
            [at : i64 (+ start index)]
            [byte : i64 (cast (string.string-ref data at) : i64)]
            [digit : i64 (- byte 48)]
            (begin
              (if (= byte 32)
                (set! padding true)
                (begin
                  (when
                    (or padding (< digit 0) (>= digit rule.radix))
                    (return (NumberFailed (BadNumeric) at)))
                  (when
                    (or
                      (> digit rule.maximum)
                      (> value (/ (- rule.maximum digit) rule.radix)))
                    (return (NumberFailed (NumericOverflow) at)))
                  (set! value (+ (* value rule.radix) digit))
                  (set! digits (+ digits 1))))
              (set! index (+ index 1)))))
        (if (and (= digits 0) (not rule.allow-blank))
          (NumberFailed (BadNumeric) start)
          (Number value (= digits 0)))))))

(define (valid-name-at? [data : (& n str)] [start : i64] [ascii-only : bool]) : bool
  (and
    (binary.compiler-incremental-binary-range-present?
      (string.string-length data)
      start
      16)
    (or
      (not ascii-only)
      (let
        [index : i64 0]
        [valid : bool true]
        (begin
          (while (and valid (< index 16))
            (let
              [byte : i64 (cast (string.string-ref data (+ start index)) : i64)]
              (begin
                (set! valid (and (>= byte 32) (<= byte 126)))
                (set! index (+ index 1)))))
          valid)))))

(define (valid-name? [name : (& n str)] [ascii-only : bool]) : bool
  (and (= (string.string-length name) 16) (valid-name-at? name 0 ascii-only)))

;; Caller has validated the fixed-width profile patterns and name span.
;; Compare in place so scanning never allocates temporary substring records.
(define (special-name-at?
  [data : (& n str)]
  [start : i64]
  [profile : (& p ArchiveProfile)]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index (array-length profile.special-names))
        (begin
          (when
            (string.is-string-prefix-at
              data
              (& (array-ref profile.special-names index))
              start)
            (return true))
          (set! index (+ index 1))))
      false)))

(defenum ArchiveHeaderResult
  (Header i64 bool)
  (HeaderFailed ArchiveErrorKind i64))

;; Called only after the complete sixty-byte header span is present.
(define (read-header
  [data : (& d str)]
  [at : i64]
  [profile : (& p ArchiveProfile)]) : ArchiveHeaderResult
  (let
    [field : i64 0]
    [size : i64 0]
    (begin
      (unless
        (valid-name-at? data at profile.ascii-names)
        (return (HeaderFailed (BadName) at)))
      (unless
        (and
          (= (string.string-ref data (+ at 58)) '`')
          (= (string.string-ref data (+ at 59)) '\n'))
        (return (HeaderFailed (BadTerminator) (+ at 58))))
      (while (< field 5)
        (begin
          (match (read-number
            data
            (+ at (array-ref field-starts field))
            (array-ref field-widths field)
            (& (array-ref profile.numbers field)))
            [(Number value _) (set! size value)]
            [(NumberFailed kind offset) (return (HeaderFailed kind offset))])
          (set! field (+ field 1))))
      (Header size (special-name-at? data at profile)))))

(defenum ArchiveProfileResult
  (ProfileReady i64)
  (ProfileFailed ArchiveErrorKind i64))

;; Both scanners and writers validate the same explicit numeric/name policy.
;; The eight signature bytes and five rules are included in the base charge.
(define (check-profile [profile : (& p ArchiveProfile)] [work : i64]) : ArchiveProfileResult
  (let
    [patterns : i64 (array-length profile.special-names)]
    [field : i64 0]
    [index : i64 0]
    (begin
      (when
        (or (< work 13) (> patterns (/ (- work 13) 17)))
        (return (ProfileFailed (WorkLimit) 0)))
      (while (< field 5)
        (begin
          (unless
            (valid-rule? (& (array-ref profile.numbers field)))
            (return (ProfileFailed (InvalidProfile) field)))
          (set! field (+ field 1))))
      (let
        [size-rule : (& p ArchiveNumberRule) (& (array-ref profile.numbers 4))]
        (when
          (or (!= size-rule.radix 10) size-rule.allow-blank)
          (return (ProfileFailed (InvalidProfile) 4))))
      (while (< index patterns)
        (begin
          (unless
            (valid-name?
              (& (array-ref profile.special-names index))
              profile.ascii-names)
            (return (ProfileFailed (InvalidProfile) index)))
          (set! index (+ index 1))))
      (ProfileReady (- (- work 13) (* patterns 17))))))

(define (scan
  [data : (& input str)]
  [identity : ArchiveIdentity]
  [profile : (& p ArchiveProfile)]
  [limits : ArchiveLimits]) : (ArchiveScanResult input)
  (let
    [length : i64 (string.string-length data)]
    [patterns : i64 (array-length profile.special-names)]
    [work : i64 limits.max-work]
    [ordinal : i64 0]
    [specials : i64 0]
    [cursor : i64 8]
    (begin
      (unless
        (valid-limits? (& limits))
        (return (ScanFailed (ArchiveError (InvalidLimits) identity -1 0))))
      (when
        (> length limits.max-input-bytes)
        (return (ScanFailed (ArchiveError (InputLimit) identity -1 0))))
      (match (check-profile profile work)
        [(ProfileReady remaining) (set! work remaining)]
        [(ProfileFailed kind offset)
          (return (ScanFailed (ArchiveError kind identity -1 offset)))])
      (unless
        (and (>= length 8) (string.is-string-prefix-at data "!<arch>\n" 0))
        (return (ScanFailed (ArchiveError (BadSignature) identity -1 0))))
      (while (< cursor length)
        (begin
          (when
            (>= ordinal limits.max-members)
            (return
              (ScanFailed (ArchiveError (MemberLimit) identity ordinal cursor))))
          (when
            (>= ordinal (/ limits.max-retained-bytes retained-member-bytes))
            (return
              (ScanFailed
                (ArchiveError (RetainedLimit) identity ordinal cursor))))
          ;; Two header reads, one sixteen-byte name copy, one padding byte,
          ;; and at most two full comparisons per special-name pattern. This
          ;; reserves the fill pass before allocating the exact-size directory.
          (when
            (or (< work 137) (> patterns (/ (- work 137) 32)))
            (return
              (ScanFailed (ArchiveError (WorkLimit) identity ordinal cursor))))
          (set! work (- (- work 137) (* patterns 32)))
          (unless
            (binary.compiler-incremental-binary-range-present? length cursor 60)
            (return
              (ScanFailed
                (ArchiveError (TruncatedHeader) identity ordinal cursor))))
          (match (read-header data cursor profile)
            [(HeaderFailed kind offset)
              (return (ScanFailed (ArchiveError kind identity ordinal offset)))]
            [(Header size special)
              (let
                [payload : i64 (+ cursor 60)]
                (begin
                  (unless
                    (binary.compiler-incremental-binary-range-present?
                      length
                      payload
                      size)
                    (return
                      (ScanFailed
                        (ArchiveError (PayloadRange) identity ordinal payload))))
                  (when
                    special
                    (when
                      (>= specials limits.max-special-members)
                      (return
                        (ScanFailed
                          (ArchiveError (SpecialLimit) identity ordinal cursor))))
                    (set! specials (+ specials 1)))
                  (set! cursor (+ payload size))
                  (when
                    (!= (% cursor 2) 0)
                    (if (and (= cursor length) profile.allow-unpadded-final)
                      unit
                      (begin
                        (unless
                          (and
                            (< cursor length)
                            (= (string.string-ref data cursor) '\n'))
                          (return
                            (ScanFailed
                              (ArchiveError
                                (BadPadding)
                                identity
                                ordinal
                                cursor))))
                        (set! cursor (+ cursor 1)))))))])
          (set! ordinal (+ ordinal 1))))
      (let
        [members : (__tl_dyn-array ArchiveMember)
          (__tl_make-array ArchiveMember ordinal)]
        [index : i64 0]
        [at : i64 8]
        (begin
          (while (< index ordinal)
            (match (read-header data at profile)
              [(HeaderFailed kind offset)
                (return (ScanFailed (ArchiveError kind identity index offset)))]
              [(Header size special)
                (let
                  [name : (Array u8 16) (init : (Array u8 16))]
                  [byte : i64 0]
                  [end : i64 (+ (+ at 60) size)]
                  (begin
                    (while (< byte 16)
                      (begin
                        (set!
                          (array-ref name byte)
                          (cast (string.string-ref data (+ at byte)) : u8))
                        (set! byte (+ byte 1))))
                    (set!
                      (array-ref members index)
                      (ArchiveMember
                        (ArchiveMemberId identity index at)
                        (+ at 60)
                        size
                        name
                        special))
                    (set!
                      at
                      (if (and (< end length) (!= (% end 2) 0))
                        (+ end 1)
                        end))
                    (set! index (+ index 1))))]))
          (Scanned
            (ArchiveDirectory data identity profile.tag members limits work)))))))

;; A session is the single load-once owner for one consumer's archive input.
;; It stores claim bits, never parsed objects, symbols or resolver decisions.
(define (new-session [directory : (& d (ArchiveDirectory input))]) : ArchiveSessionResult
  (let
    [count : i64 (array-length directory.members)]
    (if (> count directory.work-left)
      (SessionFailed (ArchiveError (WorkLimit) (clone directory.identity) -1 0))
      (SessionReady
        (ArchiveSession
          (clone directory.identity)
          directory.profile-tag
          (clone directory.limits)
          (__tl_make-array bool count)
          0
          (- directory.work-left count))))))

(define (check-session
  [directory : (& d (ArchiveDirectory input))]
  [session : (& s ArchiveSession)]) : ArchiveIdCheck
  (cond
    [(!= directory.identity.input session.identity.input)
      (InvalidId (WrongInput))]
    [(!= directory.identity.content session.identity.content)
      (InvalidId (StaleIdentity))]
    [(or
        (!= directory.profile-tag session.profile-tag)
        (!= (array-length directory.members) (array-length session.claimed)))
      (InvalidId (InvalidProfile))]
    [else (ValidId)]))

(define (check-id
  [directory : (& d (ArchiveDirectory input))]
  [id : ArchiveMemberId]) : ArchiveIdCheck
  (cond
    [(!= id.archive.input directory.identity.input) (InvalidId (WrongInput))]
    [(!= id.archive.content directory.identity.content)
      (InvalidId (StaleIdentity))]
    [(or (< id.ordinal 0) (>= id.ordinal (array-length directory.members)))
      (InvalidId (InvalidMember))]
    [else
      (let
        [member : (& d ArchiveMember)
          (& (array-ref directory.members id.ordinal))]
        (if (= member.id.header-offset id.header-offset)
          (ValidId)
          (InvalidId (InvalidMember))))]))

;; A valid ordinal is checked before indexing and its header offset must match
;; the directory. Payload bounds come only from the completed immutable scan.
(define (open!
  [directory : (& d (ArchiveDirectory input))]
  [session : (&mut s ArchiveSession)]
  [id : ArchiveMemberId]) : (ArchiveClaimResult input)
  (begin
    (when
      (< session.work-left 1)
      (return
        (ClaimFailed
          (ArchiveError
            (WorkLimit)
            (clone session.identity)
            id.ordinal
            id.header-offset))))
    (set! session.work-left (- session.work-left 1))
    (match (check-session directory (& session))
      [(InvalidId kind)
        (return
          (ClaimFailed
            (ArchiveError
              kind
              (clone session.identity)
              id.ordinal
              id.header-offset)))]
      [(ValidId) unit])
    (match (check-id directory id)
      [(InvalidId kind)
        (return
          (ClaimFailed
            (ArchiveError
              kind
              (clone session.identity)
              id.ordinal
              id.header-offset)))]
      [(ValidId) unit])
    (if (array-ref session.claimed id.ordinal)
      (AlreadyOpened id)
      (begin
        (set! (array-ref session.claimed id.ordinal) true)
        (let
          [member : (& d ArchiveMember)
            (& (array-ref directory.members id.ordinal))]
          (Opened
            id
            (string.substring-view
              directory.bytes
              member.payload-offset
              member.payload-size)))))))

;; This is the dialect hook: an adapter submits each decoded index offset.
;; The hook returns only an existing ID, never a caller-manufactured span.
;; Failed attempts consume index/work budget too. A special member's payload
;; may be opened for bounded dialect parsing; ordinary-only index maps forbid
;; an object resolver from treating that special member as an object hint.
(define (map-index!
  [directory : (& d (ArchiveDirectory input))]
  [session : (&mut s ArchiveSession)]
  [header-offset : i64]
  [ordinary-only : bool]) : ArchiveIndexResult
  (let
    [identity : ArchiveIdentity (clone session.identity)]
    [left : i64 0]
    [right : i64 (array-length directory.members)]
    (begin
      (when
        (>= session.index-entries session.limits.max-index-entries)
        (return
          (IndexFailed (ArchiveError (IndexLimit) identity -1 header-offset))))
      (set! session.index-entries (+ session.index-entries 1))
      (when
        (< session.work-left 1)
        (return
          (IndexFailed (ArchiveError (WorkLimit) identity -1 header-offset))))
      (set! session.work-left (- session.work-left 1))
      (match (check-session directory (& session))
        [(InvalidId kind)
          (return (IndexFailed (ArchiveError kind identity -1 header-offset)))]
        [(ValidId) unit])
      (while (< left right)
        (begin
          (when
            (< session.work-left 1)
            (return
              (IndexFailed (ArchiveError (WorkLimit) identity -1 header-offset))))
          (set! session.work-left (- session.work-left 1))
          (let
            [middle : i64 (+ left (/ (- right left) 2))]
            [member : (& d ArchiveMember)
              (& (array-ref directory.members middle))]
            (cond
              [(< header-offset member.id.header-offset) (set! right middle)]
              [(> header-offset member.id.header-offset)
                (set! left (+ middle 1))]
              [else
                (if (and ordinary-only member.special)
                  (return
                    (IndexFailed
                      (ArchiveError
                        (SpecialTarget)
                        identity
                        middle
                        header-offset)))
                  (return (IndexMapped (clone member.id))))]))))
      (IndexFailed
        (ArchiveError (InvalidIndexTarget) identity -1 header-offset)))))