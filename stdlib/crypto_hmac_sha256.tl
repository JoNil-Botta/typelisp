;# Exact HMAC-SHA-256 authentication over borrowed secret keys.
;#
;# Construct a fresh cleanup-owned state per message. Key normalization, pads,
;# keyed SHA states and intermediate digests stay in opaque pointer-backed
;# storage; only `finalize!` releases a public 32-byte tag. `finalize-secret!`
;# instead returns a move-only `crypto_secret.SecretFixed` of exactly 32 bytes
;# for KDF consumers. No public digest intermediate or key view is created.
;#
;# Source/borrow preflight refusals preserve the live state. Cumulative length
;# failures terminate and wipe before absorbing any chunk. Finalization and
;# verification always terminate and wipe, including wrong expected lengths
;# and mismatches. Every later operation reports `HmacSha256Closed`.
;# Cleanup is idempotent. Active empty updates are no-ops.
;# Use `with` for lexical cleanup or explicitly consume owners with `close`.
;# Wiped backing allocations remain in their arena until it is reset.
;#
;# Keys and message lengths are public. Empty/short keys are supported for
;# exact RFC semantics; authentication policy should use suitably generated
;# keys of at least 128 bits. RFC 4231 case 5 is truncated and its 16-byte tag
;# is rejected. There is no truncation or keyed-state clone operation.
;# Fixed-work verification reuses crypto_secret's complete difference loop.
;# Volatile wipes and code-shape checks are regression boundaries, not a
;# side-channel certification or erasure of registers, caches, dumps or swap.
;#
;# Usage: `(import stdlib.crypto_hmac_sha256)`
(import stdlib.byte_buf as buf)
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_sha256 as sha)

;: Nonnegative public key and cumulative message budgets.
(defstruct HmacSha256Limits
  (max-key-bytes i64)
  (max-message-bytes i64))

;: Public errors never include key or message content.
(defenum HmacSha256Error
  (HmacSha256Closed)
  (HmacSha256InvalidLimits)
  (HmacSha256KeyTooLong i64 i64)
  (HmacSha256InvalidSource)
  (HmacSha256InvalidSourceLength i64)
  (HmacSha256MessageTooLong i64 i64 i64)
  (HmacSha256TagLength i64)
  (HmacSha256SecretError secret.SecretError)
  (HmacSha256ShaError sha.Sha256Error))

;: Backing allocation. Safe callers can neither project nor copy this type.
;: Phase: 0 active, 1 finalized, 2 failed, 3 closed. Generation is poisoned
;: before every terminal wipe. Everything after the first two words is wiped.
(defstruct HmacSha256Storage
  (:opaque)
  (phase i64)
  (generation i64)
  (limits HmacSha256Limits)
  (message-length i64)
  (inner sha.Sha256State)
  (outer sha.Sha256State)
  (pad (Array u64 8))
  (digest (Array u64 4)))

;: Cleanup token checks the stamp as well as the pointer before retiring it.
(defstruct HmacSha256Handle
  (storage (MutPtr HmacSha256Storage))
  (generation i64))

;: Move-only keyed owner; its raw pointer exposes no safe readable state.
(defstruct HmacSha256State
  (:cleanup close)
  (handle HmacSha256Handle (:cleanup handle-close)))

;: Exact public full-length authenticator, distinct from a secret result.
(defstruct HmacSha256Tag
  (octets (Array u8 32)))

;: Construction result owns its successful state until moved or cleaned.
(defenum HmacSha256NewResult
  (:cleanup close-new-result)
  (:must-use)
  (HmacSha256NewOk HmacSha256State (:owned))
  (HmacSha256NewErr HmacSha256Error))

;: Public authentication result with no partial tag on error.
(defenum HmacSha256TagResult
  (:must-use)
  (HmacSha256TagOk HmacSha256Tag)
  (HmacSha256TagErr HmacSha256Error))

;: Move-only exact-32 secret result, transferable into a nominal KDF owner.
(defenum HmacSha256SecretResult
  (:cleanup close-secret-result)
  (:must-use)
  (HmacSha256SecretOk secret.SecretFixed (:owned))
  (HmacSha256SecretErr HmacSha256Error))

;: Update/sink status.
(defenum HmacSha256Status
  (:must-use)
  (HmacSha256Ok)
  (HmacSha256Err HmacSha256Error))

;: Complete verification, or a public typed error.
(defenum HmacSha256VerifyResult
  (:must-use)
  (HmacSha256VerifyOk bool)
  (HmacSha256VerifyErr HmacSha256Error))

;: Arena allocator. Storage has fixed size, independent of key/message size.
(unsafe
  (extern (hmac-runtime-alloc [size : i64]) : (MutPtr u8) (:symbol "tl_alloc")))

;: Owner stamp, shared with the backing allocation.
(define hmac-generation : i64
  0)

;: Practical default budgets: 64 KiB keys and 16 MiB messages.
(define (default-limits) : HmacSha256Limits
  (HmacSha256Limits 65536 16777216))

;: SHA's whole-byte maximum, minus the complete 64-byte inner prefix.
(define (max-message-bytes) : i64
  (cast (- (sha.max-byte-length) (cast 64 : u64)) : i64))

;: Validate budgets before inspecting the borrowed key or allocating.
(define (limits-valid? [limits : (& limits HmacSha256Limits)]) : bool
  (and
    (>= limits.max-key-bytes 0)
    (<= (cast limits.max-key-bytes : u64) (sha.max-byte-length))
    (>= limits.max-message-bytes 0)
    (<= limits.max-message-bytes (max-message-bytes))))

;: Poison before wiping every backing word other than phase/generation.
(unsafe
  (define (terminate! [storage : (MutPtr HmacSha256Storage)] [phase : i64]) : unit
    (unsafe
      (if (= (deref storage).phase 0)
        (begin
          (volatile-store! (ptr-cast storage : (MutPtr i64)) phase)
          (volatile-store! (ptr-offset (ptr-cast storage : (MutPtr i64)) 1) 0)
          (secret.wipe-words!
            (ptr-offset (ptr-cast storage : (MutPtr u64)) 2)
            (- (/ (comptime (size-of (type HmacSha256Storage))) 8) 2)))
        unit))))

;: Exact internal field address; never exported as a safe readable view.
(unsafe
  (define (inner-pointer [storage : (MutPtr HmacSha256Storage)]) : (MutPtr
      sha.Sha256State)
    (unsafe
      (ptr-cast
        (ptr-offset
          (ptr-cast storage : (MutPtr u8))
          (comptime (offset-of (type HmacSha256Storage) inner)))
        : (MutPtr sha.Sha256State)))))

;: Exact outer SHA state address inside the backing allocation.
(unsafe
  (define (outer-pointer [storage : (MutPtr HmacSha256Storage)]) : (MutPtr
      sha.Sha256State)
    (unsafe
      (ptr-cast
        (ptr-offset
          (ptr-cast storage : (MutPtr u8))
          (comptime (offset-of (type HmacSha256Storage) outer)))
        : (MutPtr sha.Sha256State)))))

;: Field cleanup leaves null, terminal and generation-mismatched handles alone.
(define (handle-close [handle : HmacSha256Handle]) : unit
  (if (and
    (not (ptr-null? handle.storage))
    (unsafe
      (= (deref handle.storage).generation handle.generation))
    (not (= handle.generation 0)))
    (unsafe
      (terminate! handle.storage 3))
    unit))

;: Explicit borrowed closure for protocols that retain a terminal handle.
(define (close! [state : (&mut state HmacSha256State)]) : unit
  (when
    (live? state)
    (unsafe
      (terminate! state.handle.storage 3))))

;: Check the live header without copying keyed fields.
(define (live? [state : (& state HmacSha256State)]) : bool
  (and
    (not (ptr-null? state.handle.storage))
    (unsafe
      (and
        (= (deref state.handle.storage).phase 0)
        (= (deref state.handle.storage).generation state.handle.generation)
        (not (= state.handle.generation 0))))))

;: Normalize an audited, borrowed key directly into fixed backing scratch.
;: `input` is valid for `length` bytes and does not alias the fresh storage.
(unsafe
  (define (initialize!
    [storage : (MutPtr HmacSha256Storage)]
    [input : (Ptr u8)]
    [length : i64]) : HmacSha256Status
    (let
      [pad : (MutPtr u8)
        (unsafe
          (ptr-offset
            (ptr-cast storage : (MutPtr u8))
            (comptime (offset-of (type HmacSha256Storage) pad))))]
      [i : i64 0]
      (if (> length 64)
        (begin
          (match (unsafe
            (sha.update-state-from-pointer!
              (inner-pointer storage)
              input
              length))
            [(Sha256UpdateErr error)
              (return (HmacSha256Err (HmacSha256ShaError error)))]
            [(Sha256UpdateOk) unit])
          (match (unsafe
            (sha.consume-state-pointer-into! (inner-pointer storage) pad 32))
            [(Sha256FinalizeIntoErr error)
              (return (HmacSha256Err (HmacSha256ShaError error)))]
            [(Sha256FinalizeIntoOk) unit])
          (unsafe
            (ptr-write! (inner-pointer storage) (sha.new))))
        (while (< i length)
          (unsafe
            (ptr-write! (ptr-offset pad i) (ptr-read (ptr-offset input i))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 64)
        (unsafe
          (ptr-write!
            (ptr-offset pad i)
            (bit-xor (ptr-read (ptr-offset pad i)) (cast 54 : u8))))
        (set! i (+ i 1)))
      (match (unsafe
        (sha.update-state-from-pointer!
          (inner-pointer storage)
          (ptr-cast pad : (Ptr u8))
          64))
        [(Sha256UpdateErr error)
          (return (HmacSha256Err (HmacSha256ShaError error)))]
        [(Sha256UpdateOk) unit])
      (set! i 0)
      (while (< i 64)
        (unsafe
          (ptr-write!
            (ptr-offset pad i)
            (bit-xor (ptr-read (ptr-offset pad i)) (cast 106 : u8))))
        (set! i (+ i 1)))
      (match (unsafe
        (sha.update-state-from-pointer!
          (outer-pointer storage)
          (ptr-cast pad : (Ptr u8))
          64))
        [(Sha256UpdateErr error)
          (return (HmacSha256Err (HmacSha256ShaError error)))]
        [(Sha256UpdateOk) unit])
      (unsafe
        (secret.wipe-words! (ptr-cast pad : (MutPtr u64)) 8))
      (HmacSha256Ok))))

;: Internal scoped constructor; the caller checks a live secret source first.
(unsafe
  (define (new-from-pointer
    [input : (Ptr u8)]
    [length : i64]
    [limits : HmacSha256Limits]) : HmacSha256NewResult
    (cond
      [(not (limits-valid? (& limits)))
        (HmacSha256NewErr (HmacSha256InvalidLimits))]
      [(or (< length 0) (> length limits.max-key-bytes))
        (HmacSha256NewErr (HmacSha256KeyTooLong length limits.max-key-bytes))]
      [(and (> length 0) (ptr-null? input))
        (HmacSha256NewErr (HmacSha256InvalidSource))]
      [else
        (let
          [storage : (MutPtr HmacSha256Storage)
            (unsafe
              (ptr-cast
                (hmac-runtime-alloc
                  (comptime (size-of (type HmacSha256Storage))))
                : (MutPtr HmacSha256Storage)))]
          (set! hmac-generation (+ hmac-generation 1))
          (unsafe
            (ptr-write!
              storage
              (HmacSha256Storage
                0
                hmac-generation
                limits
                0
                (sha.new)
                (sha.new)
                (make-array u64 8)
                (make-array u64 4))))
          (match (unsafe
            (initialize! storage input length))
            [(HmacSha256Err error)
              (unsafe
                (terminate! storage 2))
              (HmacSha256NewErr error)]
            [(HmacSha256Ok)
              (HmacSha256NewOk
                (HmacSha256State (HmacSha256Handle storage hmac-generation)))]))])))

;: Construct from a borrowed variable secret; validate public budgets first.
(define (new [key : (& key secret.SecretBytes)] [limits : HmacSha256Limits]) : HmacSha256NewResult
  (unless
    (limits-valid? (& limits))
    (return (HmacSha256NewErr (HmacSha256InvalidLimits))))
  (let
    [length : i64 (secret.bytes-length key)]
    (when
      (> length limits.max-key-bytes)
      (return
        (HmacSha256NewErr (HmacSha256KeyTooLong length limits.max-key-bytes))))
    (match (unsafe
      (secret.bytes-read-pointer key 0 length))
      [(SecretReadErr error) (HmacSha256NewErr (HmacSha256SecretError error))]
      [(SecretReadOk input)
        (unsafe
          (new-from-pointer input length limits))])))

;: Construct from a borrowed fixed secret, including a prior KDF result.
(define (new-fixed
  [key : (& key secret.SecretFixed)]
  [limits : HmacSha256Limits]) : HmacSha256NewResult
  (unless
    (limits-valid? (& limits))
    (return (HmacSha256NewErr (HmacSha256InvalidLimits))))
  (let
    [length : i64 (secret.fixed-length key)]
    (when
      (> length limits.max-key-bytes)
      (return
        (HmacSha256NewErr (HmacSha256KeyTooLong length limits.max-key-bytes))))
    (match (unsafe
      (secret.fixed-read-pointer key 0 length))
      [(SecretReadErr error) (HmacSha256NewErr (HmacSha256SecretError error))]
      [(SecretReadOk input)
        (unsafe
          (new-from-pointer input length limits))])))

;: Shared scoped update. Source preconditions refuse without mutation;
;: accounting failure terminates before any chunk byte is read.
(unsafe
  (define (update-from-pointer!
    [state : (&mut state HmacSha256State)]
    [input : (Ptr u8)]
    [length : i64]) : HmacSha256Status
    (unless (live? state) (return (HmacSha256Err (HmacSha256Closed))))
    (when
      (< length 0)
      (return (HmacSha256Err (HmacSha256InvalidSourceLength length))))
    (when
      (and (> length 0) (ptr-null? input))
      (return (HmacSha256Err (HmacSha256InvalidSource))))
    (unsafe
      (update-storage! state.handle.storage input length))))

;: Validated backing update; subtraction avoids both signed and SHA overflow.
(unsafe
  (define (update-storage!
    [storage : (MutPtr HmacSha256Storage)]
    [input : (Ptr u8)]
    [length : i64]) : HmacSha256Status
    (unsafe
      (when
        (or
          (>
            length
            (-
              (deref storage).limits.max-message-bytes
              (deref storage).message-length))
          (> length (- (max-message-bytes) (deref storage).message-length)))
        (let
          [current : i64 (deref storage).message-length]
          [limit : i64 (deref storage).limits.max-message-bytes]
          (terminate! storage 2)
          (return
            (HmacSha256Err (HmacSha256MessageTooLong current length limit)))))
      (when (= length 0) (return (HmacSha256Ok)))
      (match (unsafe
        (sha.update-state-from-pointer! (inner-pointer storage) input length))
        [(Sha256UpdateErr error)
          (terminate! storage 2)
          (HmacSha256Err (HmacSha256ShaError error))]
        [(Sha256UpdateOk)
          (set!
            (deref storage).message-length
            (+ (deref storage).message-length length))
          (HmacSha256Ok)]))))

;: Absorb exact borrowed public message bytes.
(define (update!
  [state : (&mut state HmacSha256State)]
  [input : (& input bytes)]) : HmacSha256Status
  (unsafe
    (update-from-pointer! state (buf.bytes-data input) (buf.bytes-length input))))

;: Feed initialized variable-secret bytes directly, without a readable view.
(define (update-secret!
  [state : (&mut state HmacSha256State)]
  [input : (& input secret.SecretBytes)]) : HmacSha256Status
  (unless (live? state) (return (HmacSha256Err (HmacSha256Closed))))
  (let
    [length : i64 (secret.bytes-length input)]
    (match (unsafe
      (secret.bytes-read-pointer input 0 length))
      [(SecretReadErr error) (HmacSha256Err (HmacSha256SecretError error))]
      [(SecretReadOk source)
        (unsafe
          (update-from-pointer! state source length))])))

;: Feed a fixed-secret KDF block directly with the same cumulative budget.
(define (update-fixed!
  [state : (&mut state HmacSha256State)]
  [input : (& input secret.SecretFixed)]) : HmacSha256Status
  (unless (live? state) (return (HmacSha256Err (HmacSha256Closed))))
  (let
    [length : i64 (secret.fixed-length input)]
    (match (unsafe
      (secret.fixed-read-pointer input 0 length))
      [(SecretReadErr error) (HmacSha256Err (HmacSha256SecretError error))]
      [(SecretReadOk source)
        (unsafe
          (update-from-pointer! state source length))])))

;: Internal exact sink. The caller owns a nonaliasing writable 32-byte sink.
(unsafe
  (define (finish-storage!
    [storage : (MutPtr HmacSha256Storage)]
    [output : (MutPtr u8)]) : HmacSha256Status
    (let
      [digest : (MutPtr u8)
        (unsafe
          (ptr-offset
            (ptr-cast storage : (MutPtr u8))
            (comptime (offset-of (type HmacSha256Storage) digest))))]
      (match (unsafe
        (sha.consume-state-pointer-into! (inner-pointer storage) digest 32))
        [(Sha256FinalizeIntoErr error)
          (return (HmacSha256Err (HmacSha256ShaError error)))]
        [(Sha256FinalizeIntoOk) unit])
      (match (unsafe
        (sha.update-state-from-pointer!
          (outer-pointer storage)
          (ptr-cast digest : (Ptr u8))
          32))
        [(Sha256UpdateErr error)
          (return (HmacSha256Err (HmacSha256ShaError error)))]
        [(Sha256UpdateOk) unit])
      (match (unsafe
        (sha.consume-state-pointer-into! (outer-pointer storage) output 32))
        [(Sha256FinalizeIntoErr error)
          (HmacSha256Err (HmacSha256ShaError error))]
        [(Sha256FinalizeIntoOk) (HmacSha256Ok)]))))

;: Exact consuming sink; success and processing failure both wipe the owner.
(unsafe
  (define (finish-into!
    [state : (&mut state HmacSha256State)]
    [output : (MutPtr u8)]) : HmacSha256Status
    (unless (live? state) (return (HmacSha256Err (HmacSha256Closed))))
    (let
      [result : HmacSha256Status
        (unsafe
          (finish-storage! state.handle.storage output))]
      (unsafe
        (terminate!
          state.handle.storage
          (match result
            [(HmacSha256Ok) 1]
            [_ 2])))
      result)))

;: Release one public full-length tag and permanently terminate the state.
(define (finalize! [state : (&mut state HmacSha256State)]) : HmacSha256TagResult
  (let
    [octets : (Array u8 32) (make-array u8 32)]
    (match (unsafe
      (finish-into! state (ptr-cast (ptr-addr-of octets) : (MutPtr u8))))
      [(HmacSha256Ok) (HmacSha256TagOk (HmacSha256Tag octets))]
      [(HmacSha256Err error)
        (unsafe
          (secret.wipe-words! (ptr-cast (ptr-addr-of octets) : (MutPtr u64)) 4))
        (HmacSha256TagErr error)])))

;: Write directly into a cleanup-owned exact-32 secret, never a public tag.
(define (finalize-secret! [state : (&mut state HmacSha256State)]) : HmacSha256SecretResult
  (unless (live? state) (return (HmacSha256SecretErr (HmacSha256Closed))))
  (let
    [output : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    (match (unsafe
      (secret.fixed-write-pointer (&mut output) 0 32))
      [(SecretWriteErr error)
        (close! state)
        (secret.close-fixed output)
        (HmacSha256SecretErr (HmacSha256SecretError error))]
      [(SecretWriteOk sink)
        (match (unsafe
          (finish-into! state sink))
          [(HmacSha256Err error)
            (secret.close-fixed output)
            (HmacSha256SecretErr error)]
          [(HmacSha256Ok) (HmacSha256SecretOk output)])])))

;: Verify exactly 32 public bytes using crypto_secret's fixed-work loop.
;: Wrong length, processing error and mismatch all permanently end the state.
(define (verify!
  [state : (&mut state HmacSha256State)]
  [expected : (& expected bytes)]) : HmacSha256VerifyResult
  (unless (live? state) (return (HmacSha256VerifyErr (HmacSha256Closed))))
  (let
    [length : i64 (buf.bytes-length expected)]
    (unless
      (= length 32)
      (close! state)
      (return (HmacSha256VerifyErr (HmacSha256TagLength length))))
    (match (finalize-secret! state)
      [(HmacSha256SecretErr error) (HmacSha256VerifyErr error)]
      [(HmacSha256SecretOk actual)
        (with
          ([value actual secret.close-fixed])
          (match (unsafe
            (secret.fixed-read-pointer (& value) 0 32))
            [(SecretReadErr error)
              (HmacSha256VerifyErr (HmacSha256SecretError error))]
            [(SecretReadOk source)
              (HmacSha256VerifyOk
                (=
                  (unsafe
                    (secret.difference-bits source (buf.bytes-data expected) 32))
                  (cast 0 : u64)))]))])))

;: One-shot authentication uses exactly the streaming checks and lifecycle.
(define (authenticate
  [key : (& key secret.SecretBytes)]
  [message : (& message bytes)]
  [limits : HmacSha256Limits]) : HmacSha256TagResult
  (match (new key limits)
    [(HmacSha256NewErr error) (HmacSha256TagErr error)]
    [(HmacSha256NewOk state)
      (with
        ([active state close])
        (match (update! (&mut active) message)
          [(HmacSha256Err error) (HmacSha256TagErr error)]
          [(HmacSha256Ok) (finalize! (&mut active))]))]))

;: One-shot designated secret result for constructions with public input.
(define (authenticate-secret
  [key : (& key secret.SecretBytes)]
  [message : (& message bytes)]
  [limits : HmacSha256Limits]) : HmacSha256SecretResult
  (match (new key limits)
    [(HmacSha256NewErr error) (HmacSha256SecretErr error)]
    [(HmacSha256NewOk state)
      (with
        ([active state close])
        (match (update! (&mut active) message)
          [(HmacSha256Err error) (HmacSha256SecretErr error)]
          [(HmacSha256Ok) (finalize-secret! (&mut active))]))]))

;: One-shot exact verification, including the same full-length rejection.
(define (verify
  [key : (& key secret.SecretBytes)]
  [message : (& message bytes)]
  [expected : (& expected bytes)]
  [limits : HmacSha256Limits]) : HmacSha256VerifyResult
  (match (new key limits)
    [(HmacSha256NewErr error) (HmacSha256VerifyErr error)]
    [(HmacSha256NewOk state)
      (with
        ([active state close])
        (match (update! (&mut active) message)
          [(HmacSha256Err error) (HmacSha256VerifyErr error)]
          [(HmacSha256Ok) (verify! (&mut active) expected)]))]))

;: Public tag comparison visits the complete fixed-width value.
(define (tag-equal?
  [left : (& left HmacSha256Tag)]
  [right : (& right HmacSha256Tag)]) : bool
  (let
    [a : sha.Sha256Digest (sha.Sha256Digest left.octets)]
    [b : sha.Sha256Digest (sha.Sha256Digest right.octets)]
    (sha.digest-eq? (& a) (& b))))

;: Hex formatting exists only for public tags.
(define (to-hex [tag : (& tag HmacSha256Tag)]) : String
  (let
    [digest : sha.Sha256Digest (sha.Sha256Digest tag.octets)]
    (sha.to-hex (& digest))))