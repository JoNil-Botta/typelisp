;# Closed, fail-safe HTTP trailer-field policy.
;#
;# This module decides whether already-typed fields are eligible trailers. It
;# performs no trailer-section parsing or serialization and never merges field
;# values. Policy construction allocates normalized names in the active arena;
;# policy lookup and field-list validation borrow existing storage and allocate
;# nothing.
;#
;# Usage: `(import stdlib.net.http_trailer_policy)`.
(import stdlib.byte_buf)
(import stdlib.net.http_types)

;: Closed duplicate handling attached to every approved trailer name.
(defenum HttpTrailerMultiplicity
  (HttpTrailerAtMostOnce)
  (HttpTrailerRepeatableList)
  (HttpTrailerRepeatableSeparate))

;: Bounded policy-construction limits. Total bytes count normalized names.
(defstruct HttpTrailerPolicyLimits
  (max-entries i64)
  (max-name-bytes i64)
  (max-total-name-bytes i64))

;: One normalized approved extension name and its required dispositions.
(defstruct HttpTrailerPolicyEntry
  (name http_types.HttpHeaderName)
  (sensitivity http_types.HttpHeaderSensitivity)
  (multiplicity HttpTrailerMultiplicity))

;: Immutable-by-API ordered policy. Only `[0, len)` is live.
(defstruct HttpTrailerPolicy
  (slots (__tl_dyn-array HttpTrailerPolicyEntry))
  (len i64)
  (total-name-bytes i64)
  (limits HttpTrailerPolicyLimits))

;: Stable policy-construction and field-validation failure categories.
(defenum HttpTrailerErrorKind
  (HttpTrailerInvalidPolicyLimits)
  (HttpTrailerCorruptPolicy)
  (HttpTrailerTooManyPolicyEntries)
  (HttpTrailerPolicyNameTooLong)
  (HttpTrailerPolicyNameBytesExceeded)
  (HttpTrailerInvalidPolicyName)
  (HttpTrailerForbiddenName)
  (HttpTrailerDuplicatePolicyName)
  (HttpTrailerInvalidFieldCollection)
  (HttpTrailerTooManyFields)
  (HttpTrailerFieldBytesExceeded)
  (HttpTrailerInvalidField http_types.HttpHeadErrorKind)
  (HttpTrailerUnapprovedName)
  (HttpTrailerUndeclaredName)
  (HttpTrailerSensitivityMismatch)
  (HttpTrailerDuplicateField))

;: First stable failing policy-entry or trailer-field index and byte offset.
;: The error intentionally retains no field value bytes.
(defstruct HttpTrailerError
  (kind HttpTrailerErrorKind)
  (index i64)
  (offset i64))

;: Checked custom policy construction result.
(defenum HttpTrailerPolicyNewResult
  (HttpTrailerPolicyNewOk HttpTrailerPolicy)
  (HttpTrailerPolicyNewErr HttpTrailerError))

;: Functional policy extension result.
(defenum HttpTrailerPolicyAddResult
  (HttpTrailerPolicyAddOk HttpTrailerPolicy)
  (HttpTrailerPolicyAddErr HttpTrailerError))

;: Allocation-free validation result for an ordered typed trailer collection.
(defenum HttpTrailerValidationResult
  (HttpTrailerValidationOk)
  (HttpTrailerValidationErr HttpTrailerError))

;: Conservative construction bounds for an ordinary explicit extension list.
(define (default-trailer-policy-limits) : HttpTrailerPolicyLimits
  (HttpTrailerPolicyLimits 64 1024 8192))

;: True when policy bounds are nonnegative and usable without overflow.
(define (trailer-policy-limits-valid?
  [limits : (& limits HttpTrailerPolicyLimits)]) : bool
  (and
    (>= limits.max-entries 0)
    (>= limits.max-name-bytes 0)
    (>= limits.max-total-name-bytes 0)
    (or (= limits.max-entries 0) (> limits.max-name-bytes 0))))

;: Return the safe default policy, which approves no trailer fields.
(define (trailer-policy-empty) : HttpTrailerPolicy
  (HttpTrailerPolicy
    (__tl_make-array HttpTrailerPolicyEntry 0)
    0
    0
    (default-trailer-policy-limits)))

;: Construct an empty policy with checked caller limits.
(define (trailer-policy-new [limits : HttpTrailerPolicyLimits]) : HttpTrailerPolicyNewResult
  (if (trailer-policy-limits-valid? (& limits))
    (HttpTrailerPolicyNewOk
      (HttpTrailerPolicy (__tl_make-array HttpTrailerPolicyEntry 0) 0 0 limits))
    (HttpTrailerPolicyNewErr
      (HttpTrailerError (HttpTrailerInvalidPolicyLimits) 0 0))))

;: Number of reviewed forbidden names in the closed source table below.
(define (forbidden-trailer-name-count) : i64
  54)

;: Return one reviewed lowercase forbidden name. Callers must establish a
;: valid index. This table is deliberately source-controlled rather than an
;: ambient or heuristic HTTP registry.
(define (forbidden-trailer-name [index : i64]) : String
  (cond
    [(= index 0) "accept"]
    [(= index 1) "accept-charset"]
    [(= index 2) "accept-encoding"]
    [(= index 3) "accept-language"]
    [(= index 4) "accept-ranges"]
    [(= index 5) "age"]
    [(= index 6) "allow"]
    [(= index 7) "authentication-info"]
    [(= index 8) "authorization"]
    [(= index 9) "cache-control"]
    [(= index 10) "connection"]
    [(= index 11) "content-disposition"]
    [(= index 12) "content-encoding"]
    [(= index 13) "content-language"]
    [(= index 14) "content-length"]
    [(= index 15) "content-location"]
    [(= index 16) "content-range"]
    [(= index 17) "content-type"]
    [(= index 18) "cookie"]
    [(= index 19) "date"]
    [(= index 20) "etag"]
    [(= index 21) "expect"]
    [(= index 22) "expires"]
    [(= index 23) "forwarded"]
    [(= index 24) "host"]
    [(= index 25) "if-match"]
    [(= index 26) "if-modified-since"]
    [(= index 27) "if-none-match"]
    [(= index 28) "if-range"]
    [(= index 29) "if-unmodified-since"]
    [(= index 30) "keep-alive"]
    [(= index 31) "last-modified"]
    [(= index 32) "location"]
    [(= index 33) "max-forwards"]
    [(= index 34) "origin"]
    [(= index 35) "pragma"]
    [(= index 36) "proxy-authenticate"]
    [(= index 37) "proxy-authentication-info"]
    [(= index 38) "proxy-authorization"]
    [(= index 39) "proxy-connection"]
    [(= index 40) "range"]
    [(= index 41) "referer"]
    [(= index 42) "retry-after"]
    [(= index 43) "server"]
    [(= index 44) "set-cookie"]
    [(= index 45) "te"]
    [(= index 46) "trailer"]
    [(= index 47) "transfer-encoding"]
    [(= index 48) "upgrade"]
    [(= index 49) "user-agent"]
    [(= index 50) "vary"]
    [(= index 51) "via"]
    [(= index 52) "warning"]
    [else "www-authenticate"]))

;: True when name bytes equal one reviewed header-time-only field.
(define (trailer-name-forbidden-bytes? [name : (& name bytes)]) : bool
  (let
    [index : i64 0]
    [forbidden : bool false]
    (begin
      (while (and (< index (forbidden-trailer-name-count)) (not forbidden))
        (let
          [spelling : String (forbidden-trailer-name index)]
          [spelling-bytes : (& spelling bytes)
            (byte_buf.str-as-bytes (& spelling))]
          (begin
            (if (http_types.bytes-eq-ascii-case name spelling-bytes)
              (set! forbidden true)
              unit)
            (set! index (+ index 1)))))
      forbidden)))

;: True when a checked header name is forbidden in a trailer section.
(define (trailer-name-forbidden? [name : (& name http_types.HttpHeaderName)]) : bool
  (trailer-name-forbidden-bytes? (http_types.header-name-bytes name)))

;: Return `-1` when addition would overflow or exceed a nonnegative cap.
(define (bounded-add [current : i64] [amount : i64] [limit : i64]) : i64
  (if (or
    (< current 0)
    (< amount 0)
    (< limit current)
    (> amount (- limit current)))
    -1
    (+ current amount)))

;: True when nonempty name bytes are an RFC token.
(define (trailer-name-syntax-valid? [name : (& name bytes)]) : bool
  (let
    [index : i64 0]
    [valid : bool (> (byte_buf.bytes-length name) 0)]
    (begin
      (while (and valid (< index (byte_buf.bytes-length name)))
        (begin
          (if (not (http_types.token-byte? (byte_buf.bytes-ref name index)))
            (set! valid false)
            unit)
          (set! index (+ index 1))))
      valid)))

;: True when stored policy bytes already use deterministic lowercase ASCII.
(define (trailer-name-normalized? [name : (& name bytes)]) : bool
  (let
    [index : i64 0]
    [normalized : bool true]
    (begin
      (while (and normalized (< index (byte_buf.bytes-length name)))
        (begin
          (if (=
            (byte_buf.bytes-ref name index)
            (http_types.ascii-lower (byte_buf.bytes-ref name index)))
            unit
            (set! normalized false))
          (set! index (+ index 1))))
      normalized)))

;: Return the first policy index matching name bytes, or `-1` when absent.
(define (trailer-policy-find-unchecked
  [policy : (& policy HttpTrailerPolicy)]
  [name : (& name bytes)]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index policy.len) (< found 0))
        (let
          [entry : (& policy HttpTrailerPolicyEntry)
            (& (array-ref policy.slots index))]
          [stored : (& policy bytes)
            (http_types.header-name-bytes (& entry.name))]
          (begin
            (if (http_types.bytes-eq-ascii-case stored name)
              (set! found index)
              unit)
            (set! index (+ index 1)))))
      found)))

;: Validate the representational invariants of a possibly directly-constructed
;: policy before any indexed access is trusted.
(define (trailer-policy-valid? [policy : (& policy HttpTrailerPolicy)]) : bool
  (let
    [valid : bool (trailer-policy-limits-valid? (& policy.limits))]
    [index : i64 0]
    [computed-total : i64 0]
    (begin
      (if (or
        (< policy.len 0)
        (> policy.len (array-length policy.slots))
        (> policy.len policy.limits.max-entries)
        (< policy.total-name-bytes 0)
        (> policy.total-name-bytes policy.limits.max-total-name-bytes))
        (set! valid false)
        unit)
      (while (and valid (< index policy.len))
        (let
          [entry : (& policy HttpTrailerPolicyEntry)
            (& (array-ref policy.slots index))]
          [name : (& policy bytes)
            (http_types.header-name-bytes (& entry.name))]
          [name-len : i64 (byte_buf.bytes-length name)]
          [prior : i64 0]
          (begin
            (if (or
              (> name-len policy.limits.max-name-bytes)
              (not (trailer-name-syntax-valid? name))
              (not (trailer-name-normalized? name))
              (trailer-name-forbidden-bytes? name))
              (set! valid false)
              unit)
            (while (and valid (< prior index))
              (let
                [other : (& policy HttpTrailerPolicyEntry)
                  (& (array-ref policy.slots prior))]
                [other-name : (& policy bytes)
                  (http_types.header-name-bytes (& other.name))]
                (begin
                  (if (http_types.bytes-eq-ascii-case other-name name)
                    (set! valid false)
                    unit)
                  (set! prior (+ prior 1)))))
            (set!
              computed-total
              (bounded-add
                computed-total
                name-len
                policy.limits.max-total-name-bytes))
            (if (< computed-total 0)
              (set! valid false)
              unit)
            (set! index (+ index 1)))))
      (and valid (= computed-total policy.total-name-bytes)))))

;: Number of approved extension names. Directly-constructed corrupt policies
;: are rejected by construction/validation APIs before this accessor is used.
(define (trailer-policy-len [policy : (& policy HttpTrailerPolicy)]) : i64
  policy.len)

;: Borrow one approved entry. Callers must establish a valid policy and index.
(define (trailer-policy-ref
  [policy : (& source HttpTrailerPolicy)]
  [index : i64]) : (& source HttpTrailerPolicyEntry)
  (& (array-ref policy.slots index)))

;: Find an approved entry with ASCII folding, returning `-1` for absence or a
;: corrupt directly-constructed policy.
(define (trailer-policy-find
  [policy : (& policy HttpTrailerPolicy)]
  [name : (& name bytes)]) : i64
  (if (trailer-policy-valid? policy)
    (trailer-policy-find-unchecked policy name)
    -1))

;: Add one approved extension name functionally. Stored spelling is normalized
;: to lowercase ASCII, and duplicate/forbidden inputs never alter the policy.
(define (trailer-policy-add
  [policy : HttpTrailerPolicy]
  [name : http_types.HttpHeaderName]
  [sensitivity : http_types.HttpHeaderSensitivity]
  [multiplicity : HttpTrailerMultiplicity]) : HttpTrailerPolicyAddResult
  (let
    [name-bytes : (& name bytes) (http_types.header-name-bytes (& name))]
    [name-len : i64 (byte_buf.bytes-length name-bytes)]
    [next-total : i64
      (bounded-add
        policy.total-name-bytes
        name-len
        policy.limits.max-total-name-bytes)]
    (cond
      [(not (trailer-policy-valid? (& policy)))
        (HttpTrailerPolicyAddErr
          (HttpTrailerError (HttpTrailerCorruptPolicy) policy.len 0))]
      [(>= policy.len policy.limits.max-entries)
        (HttpTrailerPolicyAddErr
          (HttpTrailerError (HttpTrailerTooManyPolicyEntries) policy.len 0))]
      [(= name-len 0)
        (HttpTrailerPolicyAddErr
          (HttpTrailerError (HttpTrailerInvalidPolicyName) policy.len 0))]
      [(> name-len policy.limits.max-name-bytes)
        (HttpTrailerPolicyAddErr
          (HttpTrailerError
            (HttpTrailerPolicyNameTooLong)
            policy.len
            policy.limits.max-name-bytes))]
      [(not (trailer-name-syntax-valid? name-bytes))
        (HttpTrailerPolicyAddErr
          (HttpTrailerError (HttpTrailerInvalidPolicyName) policy.len 0))]
      [(trailer-name-forbidden-bytes? name-bytes)
        (HttpTrailerPolicyAddErr
          (HttpTrailerError (HttpTrailerForbiddenName) policy.len 0))]
      [(>= (trailer-policy-find-unchecked (& policy) name-bytes) 0)
        (HttpTrailerPolicyAddErr
          (HttpTrailerError (HttpTrailerDuplicatePolicyName) policy.len 0))]
      [(< next-total 0)
        (HttpTrailerPolicyAddErr
          (HttpTrailerError
            (HttpTrailerPolicyNameBytesExceeded)
            policy.len
            policy.limits.max-total-name-bytes))]
      [else
        (let
          [slots : (__tl_dyn-array HttpTrailerPolicyEntry)
            (__tl_make-array HttpTrailerPolicyEntry (+ policy.len 1))]
          [normalized : byte_buf.ByteBuf (byte_buf.with-capacity name-len)]
          [index : i64 0]
          (begin
            (while (< index policy.len)
              (begin
                (set!
                  (array-ref slots index)
                  (clone (array-ref policy.slots index)))
                (set! index (+ index 1))))
            (set! index 0)
            (while (< index name-len)
              (begin
                (set!
                  normalized
                  (byte_buf.push
                    normalized
                    (http_types.ascii-lower
                      (byte_buf.bytes-ref name-bytes index))))
                (set! index (+ index 1))))
            (set!
              (array-ref slots policy.len)
              (HttpTrailerPolicyEntry
                (http_types.HttpHeaderName normalized)
                sensitivity
                multiplicity))
            (HttpTrailerPolicyAddOk
              (HttpTrailerPolicy
                slots
                (+ policy.len 1)
                next-total
                policy.limits))))])))

;: True when two closed sensitivity values agree.
(define (trailer-sensitivity-eq?
  [left : http_types.HttpHeaderSensitivity]
  [right : http_types.HttpHeaderSensitivity]) : bool
  (match left
    [(http_types.HttpHeaderPublic)
      (match right
        [(http_types.HttpHeaderPublic) true]
        [(http_types.HttpHeaderSensitive) false])]
    [(http_types.HttpHeaderSensitive)
      (match right
        [(http_types.HttpHeaderPublic) false]
        [(http_types.HttpHeaderSensitive) true])]))

;: True when field name already appeared before `end` in wire order.
(define (trailer-name-seen-before?
  [fields : (& fields http_types.HttpHeaders)]
  [end : i64]
  [name : (& name bytes)]) : bool
  (let
    [index : i64 0]
    [seen : bool false]
    (begin
      (while (and (< index end) (not seen))
        (let
          [prior : (& fields http_types.HttpHeaderField)
            (& (array-ref fields.slots index))]
          [prior-name : (& fields bytes)
            (http_types.header-name-bytes (& prior.name))]
          (begin
            (if (http_types.bytes-eq-ascii-case prior-name name)
              (set! seen true)
              unit)
            (set! index (+ index 1)))))
      seen)))

;: Validate typed trailers in original order. When `require-declared` is true,
;: every approved field must independently occur in `declared`; declaration
;: membership never grants policy approval. The helper allocates no storage.
(define (validate-trailer-fields
  [policy : (& policy HttpTrailerPolicy)]
  [fields : (& fields http_types.HttpHeaders)]
  [declared : (& declared http_types.HttpHeaderNameSet)]
  [require-declared : bool]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpTrailerValidationResult
  (cond
    [(not (trailer-policy-valid? policy))
      (HttpTrailerValidationErr
        (HttpTrailerError (HttpTrailerCorruptPolicy) 0 0))]
    [(not (http_types.head-limits-valid? limits))
      (HttpTrailerValidationErr
        (HttpTrailerError
          (HttpTrailerInvalidField (http_types.HttpInvalidLimits))
          0
          0))]
    [(or (< fields.len 0) (> fields.len (array-length fields.slots)))
      (HttpTrailerValidationErr
        (HttpTrailerError (HttpTrailerInvalidFieldCollection) 0 0))]
    [(> fields.len limits.max-fields)
      (HttpTrailerValidationErr
        (HttpTrailerError (HttpTrailerTooManyFields) limits.max-fields 0))]
    [else
      (let
        [index : i64 0]
        [total : i64 0]
        [failed : bool false]
        [failure : HttpTrailerError
          (HttpTrailerError (HttpTrailerInvalidFieldCollection) 0 0)]
        (begin
          (while (and (< index fields.len) (not failed))
            (let
              [field : (& fields http_types.HttpHeaderField)
                (& (array-ref fields.slots index))]
              [name : (& fields bytes)
                (http_types.header-name-bytes (& field.name))]
              [value : (& fields bytes)
                (http_types.header-value-bytes (& field.value))]
              [name-len : i64 (byte_buf.bytes-length name)]
              [value-len : i64 (byte_buf.bytes-length value)]
              [line-size-0 : i64
                (bounded-add name-len 2 limits.max-total-bytes)]
              [line-size-1 : i64
                (bounded-add line-size-0 value-len limits.max-total-bytes)]
              [line-size-2 : i64
                (bounded-add line-size-1 2 limits.max-total-bytes)]
              [next-total : i64
                (bounded-add total line-size-2 limits.max-total-bytes)]
              (match (http_types.validate-typed-field field total limits)
                [(http_types.HttpTypedFieldErr error)
                  (begin
                    (set!
                      failure
                      (HttpTrailerError
                        (HttpTrailerInvalidField (clone error.kind))
                        index
                        error.offset))
                    (set! failed true))]
                [(http_types.HttpTypedFieldOk)
                  (let
                    [policy-index : i64
                      (trailer-policy-find-unchecked policy name)]
                    (cond
                      [(< next-total 0)
                        (begin
                          (set!
                            failure
                            (HttpTrailerError
                              (HttpTrailerFieldBytesExceeded)
                              index
                              limits.max-total-bytes))
                          (set! failed true))]
                      [(trailer-name-forbidden-bytes? name)
                        (begin
                          (set!
                            failure
                            (HttpTrailerError
                              (HttpTrailerForbiddenName)
                              index
                              total))
                          (set! failed true))]
                      [(< policy-index 0)
                        (begin
                          (set!
                            failure
                            (HttpTrailerError
                              (HttpTrailerUnapprovedName)
                              index
                              total))
                          (set! failed true))]
                      [(and
                          require-declared
                          (not
                            (http_types.header-name-set-contains? declared name)))
                        (begin
                          (set!
                            failure
                            (HttpTrailerError
                              (HttpTrailerUndeclaredName)
                              index
                              total))
                          (set! failed true))]
                      [else
                        (let
                          [entry : (& policy HttpTrailerPolicyEntry)
                            (& (array-ref policy.slots policy-index))]
                          (if (not
                            (trailer-sensitivity-eq?
                              (clone entry.sensitivity)
                              (clone field.sensitivity)))
                            (begin
                              (set!
                                failure
                                (HttpTrailerError
                                  (HttpTrailerSensitivityMismatch)
                                  index
                                  total))
                              (set! failed true))
                            (match entry.multiplicity
                              [(HttpTrailerAtMostOnce)
                                (if (trailer-name-seen-before?
                                  fields
                                  index
                                  name)
                                  (begin
                                    (set!
                                      failure
                                      (HttpTrailerError
                                        (HttpTrailerDuplicateField)
                                        index
                                        total))
                                    (set! failed true))
                                  unit)]
                              [(HttpTrailerRepeatableList) unit]
                              [(HttpTrailerRepeatableSeparate) unit])))]))])
              (if (not failed)
                (set! total next-total)
                unit)
              (set! index (+ index 1))))
          (if failed
            (HttpTrailerValidationErr failure)
            (HttpTrailerValidationOk))))]))

;: Validate request trailers, requiring independent normalized declaration
;: membership for every policy-approved field.
(define (validate-request-trailer-fields
  [policy : (& policy HttpTrailerPolicy)]
  [fields : (& fields http_types.HttpHeaders)]
  [declared : (& declared http_types.HttpHeaderNameSet)]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpTrailerValidationResult
  (validate-trailer-fields policy fields declared true limits))

;: Validate response trailers without treating the peer declaration as
;: authorization. `declared` is accepted for symmetric composition/provenance
;: but does not gate retention.
(define (validate-response-trailer-fields
  [policy : (& policy HttpTrailerPolicy)]
  [fields : (& fields http_types.HttpHeaders)]
  [declared : (& declared http_types.HttpHeaderNameSet)]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpTrailerValidationResult
  (validate-trailer-fields policy fields declared false limits))