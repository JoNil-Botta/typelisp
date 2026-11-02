;# RFC 5869 HKDF-Extract and HKDF-Expand specialized to SHA-256.
;#
;# Extract borrows IKM and deliberately distinguishes absent, exact public and
;# exact secret salt. Only Extract creates a nominal PRK. Expand borrows that
;# reusable PRK and public binary info, returning an exact-length secret OKM.
;# Both owners are opaque and move-only, with no safe readable view, formatting,
;# cloning or serialization. Use their generated close functions or `with`.
;#
;# Every operation requires explicit caller limits. Expand preflights all work
;# before allocating, including HMAC's own message budget (which accounts for
;# the internal 64-byte prefix). It rolls distinct previous/current blocks and
;# copies only each requested prefix through crypto_secret's checked range sink.
;# Temporary keys, blocks, keyed HMAC state and partial output are cleanup-owned.
;# Allocation exhaustion remains fatal under SPEC 7.2. Wiped allocations remain
;# in the active arena until reset; volatile wiping is not side-channel certification.
;# This is neither a password KDF nor a TLS label/schedule implementation.
;# Reference: https://www.rfc-editor.org/rfc/rfc5869.html
(import stdlib.byte_buf as buf)
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_hmac_sha256 as hmac)

;: Explicit nonnegative input/output/work maxima and independent HMAC limits.
;: Expand work counts only externally fed message bytes, never HMAC's prefix.
(defstruct HkdfSha256Limits
  (max-salt-bytes i64)
  (max-ikm-bytes i64)
  (max-info-bytes i64)
  (max-output-bytes i64)
  (max-extract-work i64)
  (max-expand-work i64)
  (hmac-limits hmac.HmacSha256Limits))

;: Errors contain public lengths and categories, never secret bytes or handles.
(defenum HkdfSha256Error
  (HkdfSha256InvalidLimits)
  (HkdfSha256SaltLimit i64 i64)
  (HkdfSha256IkmLimit i64 i64)
  (HkdfSha256InfoLimit i64 i64)
  (HkdfSha256OutputLimit i64 i64)
  (HkdfSha256ExtractWorkLimit i64 i64)
  (HkdfSha256ExpandWorkLimit i64 i64)
  (HkdfSha256WorkOverflow)
  (HkdfSha256InvalidPrk)
  (HkdfSha256HmacError hmac.HmacSha256Error)
  (HkdfSha256SecretError secret.SecretError))

;: Only Extract constructs this opaque owner. The nested pointer-backed nominal
;: state rotates the original fixed allocation's generation without copying it.
;: Generic nominal handles cannot be substituted for the protected PRK field.
(defstruct HkdfSha256PrkStorage
  (:opaque)
  (:cleanup close-prk-storage)
  (value secret.SecretNominal (:owned)))

;: Public move-only token for HKDF-owned opaque pointer-backed PRK storage.
;: Copying the pointer identifies the same lifetime, never a new PRK.
(defstruct HkdfSha256Prk
  (:cleanup close-prk)
  (storage (MutPtr HkdfSha256PrkStorage) (:cleanup prk-storage-close)))

;: Opaque exact-length output, with the variable owner's whole-capacity cleanup.
(defstruct HkdfSha256OkmStorage
  (:opaque)
  (:cleanup close-okm-storage)
  (value secret.SecretBytes (:owned)))

;: Public move-only token for HKDF-owned opaque exact-length output storage.
(defstruct HkdfSha256Okm
  (:cleanup close-okm)
  (storage (MutPtr HkdfSha256OkmStorage) (:cleanup okm-storage-close)))

;: Arena allocation for the two small opaque owner wrappers.
(unsafe
  (extern (hkdf-runtime-alloc [size : i64]) : (MutPtr u8) (:symbol "tl_alloc")))

;: Nested nominal cleanup checks identity and poisons before the sole inner wipe.
;: The retained pointer may be closed repeatedly; it never creates a new lifetime.
(define (prk-storage-close [storage : (MutPtr HkdfSha256PrkStorage)]) : unit
  (unless
    (ptr-null? storage)
    (unsafe
      (close-prk-storage (ptr-read storage)))))

;: Nested variable-owner cleanup poisons before wiping the entire capacity.
(define (okm-storage-close [storage : (MutPtr HkdfSha256OkmStorage)]) : unit
  (unless
    (ptr-null? storage)
    (unsafe
      (close-okm-storage (ptr-read storage)))))

;: Immediate checked crypto access. Only HKDF can populate the backing storage.
;: The unsafe snapshot copies only the checked metadata, retaining the original
;: cleanup owner at the call site. It neither closes it nor creates a new lifetime.
(unsafe
  (define (prk-storage-read [snapshot : HkdfSha256PrkStorage]) : secret.SecretReadResult
    ;; A checked refusal for 33 bytes proves the initialized length is exactly
    ;; 32. The probe reads no bytes; oversized state is invalid for this PRK.
    (match (unsafe
      (secret.nominal-read-pointer (& snapshot.value) 0 33))
      [(SecretReadErr (SecretRange 0 33 32))
        (unsafe
          (secret.nominal-read-pointer (& snapshot.value) 0 32))]
      [(SecretReadErr error) (secret.SecretReadErr error)]
      [(SecretReadOk _) (secret.SecretReadErr (secret.SecretClosed))])))

;: Checked direct access through a protected PRK wrapper; no safe view escapes.
(unsafe
  (define (prk-read-pointer [prk : (& prk HkdfSha256Prk)]) : secret.SecretReadResult
    (if (ptr-null? prk.storage)
      (secret.SecretReadErr (secret.SecretClosed))
      (unsafe
        (prk-storage-read (ptr-read prk.storage))))))

;: Direct checked output access for crypto implementations, never a safe view.
(unsafe
  (define (okm-read-pointer
    [output : (& output HkdfSha256Okm)]
    [offset : i64]
    [count : i64]) : secret.SecretReadResult
    (if (ptr-null? output.storage)
      (secret.SecretReadErr (secret.SecretClosed))
      (let
        [handle : secret.SecretHandle
          (unsafe
            (deref output.storage).value.handle)]
        (unsafe
          (secret.read-pointer handle.storage handle.generation offset count))))))

;: A live nominal PRK or a complete recoverable error.
(defenum HkdfSha256ExtractResult
  (:cleanup close-extract-result)
  (:must-use)
  (HkdfSha256ExtractOk HkdfSha256Prk (:owned))
  (HkdfSha256ExtractErr HkdfSha256Error))

;: A live exact-length OKM or an error with no retained partial output.
(defenum HkdfSha256ExpandResult
  (:cleanup close-expand-result)
  (:must-use)
  (HkdfSha256ExpandOk HkdfSha256Okm (:owned))
  (HkdfSha256ExpandErr HkdfSha256Error))

;: Complete validation or a public error.
(defenum HkdfSha256Status
  (:must-use)
  (HkdfSha256Ok)
  (HkdfSha256Err HkdfSha256Error))

;: Public preflight result; no owner, allocation or HMAC state is created.
(defstruct HkdfSha256Plan
  (blocks i64)
  (feed-bytes i64))

;: A completely checked expansion plan.
(defenum HkdfSha256PlanResult
  (:must-use)
  (HkdfSha256PlanOk HkdfSha256Plan)
  (HkdfSha256PlanErr HkdfSha256Error))

;: Cleanup-owned rolling block; the initial variant represents empty T(0).
(defenum HkdfSha256Block
  (:cleanup close-block)
  (HkdfSha256NoBlock)
  (HkdfSha256BlockValue secret.SecretFixed (:owned)))

;: Validate all caller budgets, including those unused by a zero-block request.
(define (limits-valid? [limits : (& limits HkdfSha256Limits)]) : bool
  (and
    (>= limits.max-salt-bytes 0)
    (>= limits.max-ikm-bytes 0)
    (>= limits.max-info-bytes 0)
    (>= limits.max-output-bytes 0)
    (<= limits.max-output-bytes 8160)
    (>= limits.max-extract-work 0)
    (>= limits.max-expand-work 0)
    (hmac.limits-valid? (& limits.hmac-limits))))

;: Check exact salt, IKM, work and HMAC budgets before temporary-key allocation.
(define (extract-preflight
  [salt-length : i64]
  [ikm-length : i64]
  [limits : (& limits HkdfSha256Limits)]) : HkdfSha256Status
  (cond
    [(not (limits-valid? limits)) (HkdfSha256Err (HkdfSha256InvalidLimits))]
    [(or (< salt-length 0) (> salt-length limits.max-salt-bytes))
      (HkdfSha256Err (HkdfSha256SaltLimit salt-length limits.max-salt-bytes))]
    [(> salt-length (secret.max-capacity))
      (HkdfSha256Err (HkdfSha256SaltLimit salt-length (secret.max-capacity)))]
    [(or (< ikm-length 0) (> ikm-length limits.max-ikm-bytes))
      (HkdfSha256Err (HkdfSha256IkmLimit ikm-length limits.max-ikm-bytes))]
    [(> salt-length (- 9223372036854775807 ikm-length))
      (HkdfSha256Err (HkdfSha256WorkOverflow))]
    [(> (+ salt-length ikm-length) limits.max-extract-work)
      (HkdfSha256Err
        (HkdfSha256ExtractWorkLimit
          (+ salt-length ikm-length)
          limits.max-extract-work))]
    [(> salt-length limits.hmac-limits.max-key-bytes)
      (HkdfSha256Err
        (HkdfSha256HmacError
          (hmac.HmacSha256KeyTooLong
            salt-length
            limits.hmac-limits.max-key-bytes)))]
    [(> ikm-length limits.hmac-limits.max-message-bytes)
      (HkdfSha256Err
        (HkdfSha256HmacError
          (hmac.HmacSha256MessageTooLong
            0
            ikm-length
            limits.hmac-limits.max-message-bytes)))]
    [else (HkdfSha256Ok)]))

;: The sole Extract implementation/nominal construction boundary. Callers prove
;: both exact pointers live and preflight all limits before invoking it.
(unsafe
  (define (extract-worker
    [key : (Ptr u8)]
    [key-length : i64]
    [ikm : (Ptr u8)]
    [ikm-length : i64]
    [limits : HkdfSha256Limits]) : HkdfSha256ExtractResult
    (match (unsafe
      (hmac.new-from-pointer key key-length limits.hmac-limits))
      [(HmacSha256NewErr error)
        (HkdfSha256ExtractErr (HkdfSha256HmacError error))]
      [(HmacSha256NewOk state)
        (with
          ([active state hmac.close])
          (match (unsafe
            (hmac.update-from-pointer! (&mut active) ikm ikm-length))
            [(HmacSha256Err error)
              (return (HkdfSha256ExtractErr (HkdfSha256HmacError error)))]
            [(HmacSha256Ok) unit])
          (match (hmac.finalize-secret! (&mut active))
            [(HmacSha256SecretErr error)
              (HkdfSha256ExtractErr (HkdfSha256HmacError error))]
            [(HmacSha256SecretOk fixed)
              (match (unsafe
                (secret.transfer-fixed fixed (secret.Secret32)))
                [(SecretNominalErr error)
                  (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
                [(SecretNominalOk value)
                  (let
                    [storage : (MutPtr HkdfSha256PrkStorage)
                      (unsafe
                        (ptr-cast
                          (hkdf-runtime-alloc
                            (comptime (size-of (type HkdfSha256PrkStorage))))
                          : (MutPtr HkdfSha256PrkStorage)))]
                    (unsafe
                      (ptr-write! storage (HkdfSha256PrkStorage value)))
                    (HkdfSha256ExtractOk (HkdfSha256Prk storage)))])]))])))

;: Extract with RFC's absent salt, exactly 32 temporary zero octets.
(define (extract [ikm : (& ikm secret.SecretBytes)] [limits : HkdfSha256Limits]) : HkdfSha256ExtractResult
  (let
    [length : i64 (secret.bytes-length ikm)]
    (match (extract-preflight 32 length (& limits))
      [(HkdfSha256Err error) (return (HkdfSha256ExtractErr error))]
      [(HkdfSha256Ok) unit])
    (match (unsafe
      (secret.bytes-read-pointer ikm 0 length))
      [(SecretReadErr error)
        (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
      [(SecretReadOk input)
        (with
          ([key (secret.fixed-zero (secret.Secret32)) secret.close-fixed])
          (match (unsafe
            (secret.fixed-read-pointer (& key) 0 32))
            [(SecretReadErr error)
              (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
            [(SecretReadOk salt)
              (unsafe
                (extract-worker salt 32 input length limits))]))])))

;: Extract with exact public salt, including empty/NUL bytes. Only the temporary
;: secret key copy is owned here; caller salt and IKM remain borrowed.
(define (extract-public
  [salt : (& salt bytes)]
  [ikm : (& ikm secret.SecretBytes)]
  [limits : HkdfSha256Limits]) : HkdfSha256ExtractResult
  (let
    [salt-length : i64 (buf.bytes-length salt)]
    [length : i64 (secret.bytes-length ikm)]
    (match (extract-preflight salt-length length (& limits))
      [(HkdfSha256Err error) (return (HkdfSha256ExtractErr error))]
      [(HkdfSha256Ok) unit])
    (match (unsafe
      (secret.bytes-read-pointer ikm 0 length))
      [(SecretReadErr error)
        (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
      [(SecretReadOk input)
        (match (secret.bytes-from-bytes salt salt-length)
          [(SecretBytesErr error)
            (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
          [(SecretBytesOk key)
            (with
              ([temporary key secret.close-bytes])
              (match (unsafe
                (secret.bytes-read-pointer (& temporary) 0 salt-length))
                [(SecretReadErr error)
                  (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
                [(SecretReadOk source)
                  (unsafe
                    (extract-worker source salt-length input length limits))]))])])))

;: Extract with borrowed live exact secret salt and IKM, including live empties.
(define (extract-secret
  [salt : (& salt secret.SecretBytes)]
  [ikm : (& ikm secret.SecretBytes)]
  [limits : HkdfSha256Limits]) : HkdfSha256ExtractResult
  (let
    [salt-length : i64 (secret.bytes-length salt)]
    [length : i64 (secret.bytes-length ikm)]
    (match (extract-preflight salt-length length (& limits))
      [(HkdfSha256Err error) (return (HkdfSha256ExtractErr error))]
      [(HkdfSha256Ok) unit])
    (match (unsafe
      (secret.bytes-read-pointer ikm 0 length))
      [(SecretReadErr error)
        (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
      [(SecretReadOk input)
        (match (unsafe
          (secret.bytes-read-pointer salt 0 salt-length))
          [(SecretReadErr error)
            (HkdfSha256ExtractErr (HkdfSha256SecretError error))]
          [(SecretReadOk source)
            (unsafe
              (extract-worker source salt-length input length limits))])])))

;: Plan all external work with checked arithmetic. The zero-block branch occurs
;: before N-1 or hypothetical HMAC message arithmetic; one block checks only its
;: actual info+1 message. HMAC separately accounts for its 64-byte inner prefix.
(define (expand-plan
  [info-length : i64]
  [length : i64]
  [limits : (& limits HkdfSha256Limits)]) : HkdfSha256PlanResult
  (unless
    (limits-valid? limits)
    (return (HkdfSha256PlanErr (HkdfSha256InvalidLimits))))
  (when
    (or (< length 0) (> length limits.max-output-bytes))
    (return
      (HkdfSha256PlanErr (HkdfSha256OutputLimit length limits.max-output-bytes))))
  (when
    (or (< info-length 0) (> info-length limits.max-info-bytes))
    (return
      (HkdfSha256PlanErr
        (HkdfSha256InfoLimit info-length limits.max-info-bytes))))
  (when (= length 0) (return (HkdfSha256PlanOk (HkdfSha256Plan 0 0))))
  (let
    [blocks : i64 (+ 1 (/ (- length 1) 32))]
    [overhead : i64 (+ blocks (* 32 (- blocks 1)))]
    (when
      (> info-length (/ (- 9223372036854775807 overhead) blocks))
      (return (HkdfSha256PlanErr (HkdfSha256WorkOverflow))))
    (let
      [work : i64 (+ (* blocks info-length) overhead)]
      [prefix : i64
        (if (= blocks 1)
          1
          33)]
      (when
        (> work limits.max-expand-work)
        (return
          (HkdfSha256PlanErr
            (HkdfSha256ExpandWorkLimit work limits.max-expand-work))))
      (when
        (> 32 limits.hmac-limits.max-key-bytes)
        (return
          (HkdfSha256PlanErr
            (HkdfSha256HmacError
              (hmac.HmacSha256KeyTooLong 32 limits.hmac-limits.max-key-bytes)))))
      (when
        (> info-length (- limits.hmac-limits.max-message-bytes prefix))
        (return
          (HkdfSha256PlanErr
            (HkdfSha256HmacError
              (hmac.HmacSha256MessageTooLong
                prefix
                info-length
                limits.hmac-limits.max-message-bytes)))))
      (HkdfSha256PlanOk (HkdfSha256Plan blocks work)))))

;: A liveness query validates nominal outer identity and exact inner length,
;: including for a zero-length expansion. No raw handle or byte view escapes.
(define (prk-live? [prk : (& prk HkdfSha256Prk)]) : bool
  (match (unsafe
    (prk-read-pointer prk))
    [(SecretReadOk _) true]
    [_ false]))

;: Public initialized output length, zero also for a closed owner.
(define (okm-length [output : (& output HkdfSha256Okm)]) : i64
  (if (ptr-null? output.storage)
    0
    (let
      [handle : secret.SecretHandle
        (unsafe
          (deref output.storage).value.handle)]
      (unsafe
        (secret.live-length handle.storage handle.generation)))))

;: Compute a fresh distinct T(n), keeping the borrowed previous block live
;: through HMAC finalization. The counter is one binary octet.
(unsafe
  (define (next-block
    [key : (Ptr u8)]
    [previous : (& previous HkdfSha256Block)]
    [info : (& info bytes)]
    [counter : i64]
    [limits : hmac.HmacSha256Limits]) : hmac.HmacSha256SecretResult
    (match (unsafe
      (hmac.new-from-pointer key 32 limits))
      [(HmacSha256NewErr error) (hmac.HmacSha256SecretErr error)]
      [(HmacSha256NewOk state)
        (with
          ([active state hmac.close])
          (match previous
            [(HkdfSha256NoBlock) unit]
            [(HkdfSha256BlockValue value)
              (match (hmac.update-fixed! (&mut active) value)
                [(HmacSha256Err error)
                  (return (hmac.HmacSha256SecretErr error))]
                [(HmacSha256Ok) unit])])
          (match (hmac.update! (&mut active) info)
            [(HmacSha256Err error) (return (hmac.HmacSha256SecretErr error))]
            [(HmacSha256Ok) unit])
          (let
            [octet : u8 (cast counter : u8)]
            (match (unsafe
              (hmac.update-from-pointer!
                (&mut active)
                (ptr-cast (ptr-addr-of octet) : (Ptr u8))
                1))
              [(HmacSha256Err error) (return (hmac.HmacSha256SecretErr error))]
              [(HmacSha256Ok) (hmac.finalize-secret! (&mut active))])))])))

;: Fill a fresh output under rolling-block cleanup. A failed range copy wipes
;: the current block before returning; lexical cleanup always retires previous.
(unsafe
  (define (expand-into!
    [key : (Ptr u8)]
    [info : (& info bytes)]
    [length : i64]
    [plan : HkdfSha256Plan]
    [limits : hmac.HmacSha256Limits]
    [output : (&mut output secret.SecretBytes)]) : HkdfSha256Status
    (with
      ([previous (HkdfSha256NoBlock) close-block])
      (let
        [counter : i64 1]
        [offset : i64 0]
        (while (<= counter plan.blocks)
          (match (unsafe
            (next-block key (& previous) info counter limits))
            [(HmacSha256SecretErr error)
              (return (HkdfSha256Err (HkdfSha256HmacError error)))]
            [(HmacSha256SecretOk current)
              (let
                [count : i64
                  (if (< (- length offset) 32)
                    (- length offset)
                    32)]
                (match (secret.fixed-copy-range!
                  (& current)
                  (secret.Secret32)
                  0
                  output
                  offset
                  count)
                  [(SecretErr error)
                    (secret.close-fixed current)
                    (return (HkdfSha256Err (HkdfSha256SecretError error)))]
                  [(SecretOk) unit])
                (close-block previous)
                (set! previous (HkdfSha256BlockValue current))
                (set! offset (+ offset count)))])
          (set! counter (+ counter 1)))
        (HkdfSha256Ok)))))

;: Borrow a live Extract-produced PRK and public binary info. All limits, exact
;: work and PRK liveness are checked before even the live empty OKM allocation.
;: Success preserves the PRK and transfers a distinct live output to the caller.
(define (expand
  [prk : (& prk HkdfSha256Prk)]
  [info : (& info bytes)]
  [length : i64]
  [limits : HkdfSha256Limits]) : HkdfSha256ExpandResult
  (match (expand-plan (buf.bytes-length info) length (& limits))
    [(HkdfSha256PlanErr error) (HkdfSha256ExpandErr error)]
    [(HkdfSha256PlanOk plan)
      (match (unsafe
        (prk-read-pointer prk))
        [(SecretReadErr _) (HkdfSha256ExpandErr (HkdfSha256InvalidPrk))]
        [(SecretReadOk key)
          (match (secret.bytes-new length)
            [(SecretBytesErr error)
              (HkdfSha256ExpandErr (HkdfSha256SecretError error))]
            [(SecretBytesOk output)
              (match (unsafe
                (expand-into!
                  key
                  info
                  length
                  plan
                  limits.hmac-limits
                  (&mut output)))
                [(HkdfSha256Err error)
                  (secret.close-bytes output)
                  (HkdfSha256ExpandErr error)]
                [(HkdfSha256Ok)
                  (let
                    [storage : (MutPtr HkdfSha256OkmStorage)
                      (unsafe
                        (ptr-cast
                          (hkdf-runtime-alloc
                            (comptime (size-of (type HkdfSha256OkmStorage))))
                          : (MutPtr HkdfSha256OkmStorage)))]
                    (unsafe
                      (ptr-write! storage (HkdfSha256OkmStorage output)))
                    (HkdfSha256ExpandOk (HkdfSha256Okm storage)))])])])]))