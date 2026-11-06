;# AEAD_AES_128_GCM: 16-byte secret keys, 12-byte nonces, full 16-byte tags.
;#
;# `new` consumes the key into the shared typed AES-128 schedule and computes
;# H once. Borrow the cleanup-owning context for repeated `seal`/`open` calls.
;# Nonces must be unique under a key: protocol adapters own their construction,
;# usage accounting and rekey policy. This module has no protocol state.
;#
;# Borrowed inputs and fresh allocating outputs exclude in-place overlap.
;# `open` preallocates fresh storage, then authenticates the entire tag before
;# writing any plaintext or publishing an output value.
;# Returned authenticated plaintext is an explicit public ByteBuf boundary.
;# Inner loops allocate nothing. Cleanup wipes schedule, H and fixed scratch
;# on structured paths. Synchronous calls have no cancellation checkpoint.
;# Compiler spill slots, registers, caches and dumps are outside the erasure
;# guarantee. Opt2 is the default release profile and can leave secret spills.
;# Fatal OOM/panic/abort cleanup is not guaranteed.
;# Assembly/work gates are regression evidence, not a side-channel audit.
;#
;# Usage: `(import stdlib.crypto_aes128_gcm)`
;#
;# ```typelisp
;# (import stdlib.crypto_aes128_gcm as gcm)
;# (import stdlib.crypto_secret as secret)
;# (import stdlib.byte_buf as buf)
;# (define (main) : i64
;#   (let [nonce : gcm.GcmNonce (gcm.GcmNonce (make-array u8 12))]
;#        [text : String "one record"]
;#        [input : (& text bytes) (buf.str-as-bytes (& text))]
;#     (match (gcm.new (secret.fixed-zero (secret.Secret16)))
;#       [(gcm.GcmKeyOk key)
;#         (with ([owner key gcm.close])
;#           (match (gcm.seal (& owner) (& nonce) input input)
;#             [(gcm.GcmSealOk sealed)
;#               (match (gcm.open (& owner) (& nonce) input
;#                 (buf.as-bytes (& sealed.ciphertext)) (& sealed.tag))
;#                 [(gcm.GcmOpenOk plain) (if (= (buf.len (& plain)) 10) 42 1)]
;#                 [_ 1])]
;#             [_ 1]))]
;#       [_ 1])))
;# ```
(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_ghash_core as ghash)
(import stdlib.byte_buf as buf)

; Reuse the existing runtime-fatal ABI without pulling platform I/O into GCM.
(import stdlib.checked_size as checked)

;: Public errors contain only status/lengths, never secret intermediates.
(defenum GcmError
  (GcmLength i64 i64)
  (GcmNonceLength i64)
  (GcmTagLength i64)
  (GcmAuthentication)
  (GcmAes aes.AesError)
  (GcmSecret secret.SecretError))

;: Pure public-size validation result.
(defenum GcmStatus
  (:must-use)
  (GcmOk)
  (GcmErr GcmError))

;: Exact public nonce; its bytes are not secret key material.
(defstruct GcmNonce
  (octets (Array u8 12)))

;: Exact public authenticator, released only when seal completes.
(defstruct GcmTag
  (octets (Array u8 16)))

;: Exact nonce construction or a public length error.
(defenum GcmNonceResult
  (:must-use)
  (GcmNonceOk GcmNonce)
  (GcmNonceErr GcmError))

;: Exact tag construction or a public length error.
(defenum GcmTagResult
  (:must-use)
  (GcmTagOk GcmTag)
  (GcmTagErr GcmError))

;: One nested cleanup obligation per schedule/H owner; no clone/Debug API.
(defstruct GcmKey
  (:cleanup close)
  (schedule aes.Aes128Schedule (:owned))
  (h secret.SecretFixed (:owned)))

;: Consuming key construction owns its successful context payload.
(defenum GcmKeyResult
  (:cleanup close-key-result)
  (:must-use)
  (GcmKeyOk GcmKey (:owned))
  (GcmKeyErr GcmError))

;: Successful encryption publishes its fresh ciphertext and tag together.
(defstruct GcmSealed
  (ciphertext buf.ByteBuf)
  (tag GcmTag))

;: A complete ciphertext/tag pair, or a preflight failure.
(defenum GcmSealResult
  (:must-use)
  (GcmSealOk GcmSealed)
  (GcmSealErr GcmError))

;: Fresh authenticated plaintext, or a failure with no plaintext value.
(defenum GcmOpenResult
  (:must-use)
  (GcmOpenOk buf.ByteBuf)
  (GcmOpenErr GcmError))

;: SP 800-38D bound, correcting RFC 5116 erratum 5219.
(define (p-max) : i64
  68719476704)

;: Largest AAD byte count whose bit length fits in u64.
(define (a-max) : i64
  2305843009213693951)

;: Largest combined ciphertext and full tag byte count.
(define (c-max) : i64
  68719476720)

;: Factored arithmetic admits at most 2^32-2 payload blocks. Bounds imply
;: length+15, length+16 and both u64 bit-length products cannot overflow.
(define (validate-lengths [aad-length : i64] [payload-length : i64]) : GcmStatus
  (cond
    [(or (< aad-length 0) (> aad-length (a-max)))
      (GcmErr (GcmLength aad-length (a-max)))]
    [(or (< payload-length 0) (> payload-length (p-max)))
      (GcmErr (GcmLength payload-length (p-max)))]
    [else (GcmOk)]))

;: Validate combined RFC 5116 ciphertext/tag length without allocating it.
(define (validate-combined-length [aad-length : i64] [combined : i64]) : GcmStatus
  (if (or (< combined 16) (> combined (c-max)))
    (GcmErr (GcmLength combined (c-max)))
    (validate-lengths aad-length (- combined 16))))

;: Construct exactly twelve public nonce bytes, rejecting every truncation.
(define (nonce-from-bytes [input : (& input bytes)]) : GcmNonceResult
  (let
    [length : i64 (buf.bytes-length input)]
    (if (!= length 12)
      (GcmNonceErr (GcmNonceLength length))
      (let
        [octets : (Array u8 12) (make-array u8 12)]
        [i : i64 0]
        (while (< i 12)
          (set! (array-ref octets i) (buf.bytes-ref input i))
          (set! i (+ i 1)))
        (GcmNonceOk (GcmNonce octets))))))

;: Construct exactly sixteen public tag bytes; shortened tags are unsupported.
(define (tag-from-bytes [input : (& input bytes)]) : GcmTagResult
  (let
    [length : i64 (buf.bytes-length input)]
    (if (!= length 16)
      (GcmTagErr (GcmTagLength length))
      (let
        [octets : (Array u8 16) (make-array u8 16)]
        [i : i64 0]
        (while (< i 16)
          (set! (array-ref octets i) (buf.bytes-ref input i))
          (set! i (+ i 1)))
        (GcmTagOk (GcmTag octets))))))

;: Constructor implementation consumes the same nominal key transfer as AES.
(define (construct-key [input : aes.RawKey]) : GcmKeyResult
  (match (aes.check-fixed (& input.value) 16)
    [(SecretErr error)
      (aes.close-raw-key input)
      (GcmKeyErr (GcmAes (aes.AesSecret error)))]
    [(SecretOk)
      (let
        [zero : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
        [h : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
        (match (aes.construct-128 input)
          [(Aes128Err error)
            (secret.close-fixed zero)
            (secret.close-fixed h)
            (GcmKeyErr (GcmAes error))]
          [(Aes128Ok schedule)
            (match (aes.encrypt-128! (& schedule) (& zero) (&mut h))
              [(AesOk)
                (secret.close-fixed zero)
                (GcmKeyOk (GcmKey schedule h))]
              [(AesErr error)
                (secret.close-fixed zero)
                (secret.close-fixed h)
                (aes.close-128 schedule)
                (GcmKeyErr (GcmAes error))])]))]))

;: Consume one live exact-16 key; the raw key is wiped by the shared core.
(defmacro (new [key : Expr]) : GcmKeyResult
  `(construct-key (aes.RawKey ,key)))

;: Test seam counts only payload AES calls, so bad tags must leave it zero.
(cfg
  test
  (define payload-blocks : i64
    0))

;: Set nonce || BE32(counter). Only public indices/counter affect addressing.
(unsafe
  (define (counter!
    [nonce : (& nonce GcmNonce)]
    [counter : u32]
    [destination : (MutPtr u8)]) : unit
    (let
      [index : i64 0]
      (while (< index 12)
        (unsafe
          (ptr-write!
            (ptr-offset destination index)
            (array-ref nonce.octets index)))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index 4)
        (unsafe
          (ptr-write!
            (ptr-offset destination (+ 12 index))
            (cast (shr counter (cast (- 24 (* index 8)) : u64)) : u8)))
        (set! index (+ index 1))))))

;: All owners have been validated by the successful AES(J0) preflight.
;: They stay exclusively borrowed/live for the entire synchronous operation.
;: Thus later typed AES calls have no recoverable failure. A violated internal
;: invariant is fatal before publication, never a partial success/error value.
(unsafe
  (define (gctr!
    [key : (& key GcmKey)]
    [nonce : (& nonce GcmNonce)]
    [source : (Ptr u8)]
    [length : i64]
    [destination : (MutPtr u8)]
    [counter : (&mut counter secret.SecretFixed)]
    [stream : (&mut stream secret.SecretFixed)]
    [counter-data : (MutPtr u8)]
    [stream-data : (Ptr u8)]) : unit
    (let
      [offset : i64 0]
      [block : u32 (cast 2 : u32)]
      (while (< offset length)
        (unsafe
          (counter! nonce block counter-data))
        (match (aes.encrypt-128! (& key.schedule) counter stream)
          [(AesOk) unit]
          [(AesErr _) (checked.size-abort "GCM validated AES invariant\n")])
        (cfg test (set! payload-blocks (+ payload-blocks 1)) unit)
        (let
          [count : i64
            (if (< (- length offset) 16)
              (- length offset)
              16)]
          [index : i64 0]
          (while (< index count)
            (unsafe
              (ptr-write!
                (ptr-offset destination (+ offset index))
                (bit-xor
                  (ptr-read (ptr-offset source (+ offset index)))
                  (ptr-read (ptr-offset stream-data index)))))
            (set! index (+ index 1)))
          (set! offset (+ offset count)))
        (set! block (+ block (cast 1 : u32)))))))

;: Allocate fixed scratch before secret work, then validate the complete key
;: and scratch via typed AES(J0). The returned tag secret is not public yet.
(unsafe
  (define (prepare!
    [key : (& key GcmKey)]
    [nonce : (& nonce GcmNonce)]
    [counter : (&mut counter secret.SecretFixed)]
    [stream : (&mut stream secret.SecretFixed)]) : GcmStatus
    (match (aes.check-fixed (& key.h) 16)
      [(SecretErr error) (GcmErr (GcmSecret error))]
      [(SecretOk)
        (unsafe
          (counter!
            nonce
            (cast 1 : u32)
            (secret.storage-data counter.handle.storage)))
        (match (aes.encrypt-128! (& key.schedule) counter stream)
          [(AesOk) (GcmOk)]
          [(AesErr error) (GcmErr (GcmAes error))])])))

;: Fresh output means no caller-buffer aliasing. Validate/allocate before AES.
(define (seal
  [key : (& key GcmKey)]
  [nonce : (& nonce GcmNonce)]
  [aad : (& aad bytes)]
  [plaintext : (& plaintext bytes)]) : GcmSealResult
  (let
    [length : i64 (buf.bytes-length plaintext)]
    [aad-length : i64 (buf.bytes-length aad)]
    (match (validate-lengths aad-length length)
      [(GcmErr error) (return (GcmSealErr error))]
      [(GcmOk) unit])
    (let
      [output : buf.ByteBuf (buf.with-capacity length)]
      (with
        ([counter (secret.fixed-zero (secret.Secret16)) secret.close-fixed]
          [stream (secret.fixed-zero (secret.Secret16)) secret.close-fixed]
          [expected (secret.fixed-zero (secret.Secret16)) secret.close-fixed])
        (match (unsafe
          (prepare! key nonce (&mut counter) (&mut stream)))
          [(GcmErr error) (GcmSealErr error)]
          [(GcmOk)
            (let
              [counter-data : (MutPtr u8)
                (unsafe
                  (secret.storage-data counter.handle.storage))]
              [stream-data : (MutPtr u8)
                (unsafe
                  (secret.storage-data stream.handle.storage))]
              [tag : GcmTag (GcmTag (make-array u8 16))]
              [index : i64 0]
              ; Retain AES(J0) in secret storage until the tag is complete.
              (let
                [tag-data : (MutPtr u8)
                  (unsafe
                    (secret.storage-data expected.handle.storage))]
                (while (< index 16)
                  (unsafe
                    (ptr-write!
                      (ptr-offset tag-data index)
                      (ptr-read (ptr-offset stream-data index))))
                  (set! index (+ index 1)))
                (unsafe
                  (gctr!
                    key
                    nonce
                    (buf.bytes-data plaintext)
                    length
                    (__tl_array-data output.slots)
                    (&mut counter)
                    (&mut stream)
                    counter-data
                    (ptr-cast stream-data : (Ptr u8)))
                  (ghash.authenticate!
                    (ptr-cast
                      (secret.storage-data key.h.handle.storage)
                      : (Ptr u8))
                    (buf.bytes-data aad)
                    aad-length
                    (ptr-cast (__tl_array-data output.slots) : (Ptr u8))
                    length
                    tag-data))
                (set! index 0)
                (while (< index 16)
                  (set!
                    (array-ref tag.octets index)
                    (unsafe
                      (ptr-read (ptr-offset tag-data index))))
                  (set! index (+ index 1))))
              (set! output.len length)
              (GcmSealOk (GcmSealed output tag)))])))))

;: Preallocate before keyed work; authenticate completely before plaintext writes.
(define (open
  [key : (& key GcmKey)]
  [nonce : (& nonce GcmNonce)]
  [aad : (& aad bytes)]
  [ciphertext : (& ciphertext bytes)]
  [tag : (& tag GcmTag)]) : GcmOpenResult
  (let
    [length : i64 (buf.bytes-length ciphertext)]
    [aad-length : i64 (buf.bytes-length aad)]
    [received : GcmTag (deref tag)]
    (match (validate-lengths aad-length length)
      [(GcmErr error) (return (GcmOpenErr error))]
      [(GcmOk) unit])
    (let
      [output : buf.ByteBuf (buf.with-capacity length)]
      (with
        ([counter (secret.fixed-zero (secret.Secret16)) secret.close-fixed]
          [stream (secret.fixed-zero (secret.Secret16)) secret.close-fixed])
        (match (unsafe
          (prepare! key nonce (&mut counter) (&mut stream)))
          [(GcmErr error) (GcmOpenErr error)]
          [(GcmOk)
            (let
              [counter-data : (MutPtr u8)
                (unsafe
                  (secret.storage-data counter.handle.storage))]
              [stream-data : (MutPtr u8)
                (unsafe
                  (secret.storage-data stream.handle.storage))]
              (unsafe
                (ghash.authenticate!
                  (ptr-cast
                    (secret.storage-data key.h.handle.storage)
                    : (Ptr u8))
                  (buf.bytes-data aad)
                  aad-length
                  (buf.bytes-data ciphertext)
                  length
                  stream-data))
              (if (!=
                (unsafe
                  (secret.difference-bits
                    (ptr-cast stream-data : (Ptr u8))
                    (ptr-cast (ptr-addr-of received.octets) : (Ptr u8))
                    16))
                (cast 0 : u64))
                (GcmOpenErr (GcmAuthentication))
                (begin
                  (unsafe
                    (gctr!
                      key
                      nonce
                      (buf.bytes-data ciphertext)
                      length
                      (__tl_array-data output.slots)
                      (&mut counter)
                      (&mut stream)
                      counter-data
                      (ptr-cast stream-data : (Ptr u8))))
                  (set! output.len length)
                  (GcmOpenOk output))))])))))