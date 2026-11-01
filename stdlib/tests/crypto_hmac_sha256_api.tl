(module stdlib.crypto_hmac_sha256.tests)

(import stdlib.byte_buf as buf)
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_hmac_sha256 as hmac)
(import stdlib.crypto_sha256 as sha)
(import stdlib.test)
(cfg compile-profile (import stdlib.profile))

;: Public fixture bytes with exact initialized length and excess capacity.
(define (filled [count : i64] [value : u8]) : buf.ByteBuf
  (let
    [out : buf.ByteBuf (buf.with-capacity (+ count 17))]
    [i : i64 0]
    (while (< i count)
      (set! out (buf.push out value))
      (set! i (+ i 1)))
    out))

;: Move one expected successful owner out of its result.
(define (key-from [input : (& input bytes)]) : secret.SecretBytes
  (match (secret.bytes-from-bytes input (+ (buf.bytes-length input) 17))
    [(SecretBytesOk key) key]
    [(SecretBytesErr _)
      (test.assert-true false "key construction")
      (key-from input)]))

;: Move one expected successful HMAC state out of its result.
(define (state-from
  [key : (& key secret.SecretBytes)]
  [limits : hmac.HmacSha256Limits]) : hmac.HmacSha256State
  (match (hmac.new key limits)
    [(HmacSha256NewOk state)
      (let
        [scratch : (Ptr u64)
          (unsafe
            (ptr-cast
              (ptr-offset
                (ptr-cast state.handle.storage : (Ptr u8))
                (comptime (offset-of (type hmac.HmacSha256Storage) pad)))
              : (Ptr u64)))]
        [index : i64 0]
        (while (< index 12)
          (test.assert-true
            (=
              (unsafe
                (ptr-read (ptr-offset scratch index)))
              (cast 0 : u64))
            "normalization scratch wiped after init")
          (set! index (+ index 1))))
      state]
    [(HmacSha256NewErr _)
      (test.assert-true false "state construction")
      (state-from key limits)]))

;: Require complete absorption.
(define (require-ok [status : hmac.HmacSha256Status]) : unit
  (match status
    [(HmacSha256Ok) unit]
    [(HmacSha256Err _) (test.assert-true false "HMAC operation")]))

;: Require an exact public authenticator.
(define (tag-from [result : hmac.HmacSha256TagResult]) : hmac.HmacSha256Tag
  (match result
    [(HmacSha256TagOk tag) tag]
    [(HmacSha256TagErr _)
      (test.assert-true false "public finalization")
      (hmac.HmacSha256Tag (make-array u8 32))]))

;: One vector through one-shot, bytewise and every two-chunk split.
(define (vector
  [key-bytes : (& key-bytes bytes)]
  [message : (& message bytes)]
  [expected : String]) : unit
  (let
    [key : secret.SecretBytes (key-from key-bytes)]
    [tag : hmac.HmacSha256Tag
      (tag-from (hmac.authenticate (& key) message (hmac.default-limits)))]
    [actual : String (hmac.to-hex (& tag))]
    [split : i64 0]
    (test.assert-string-eq (& actual) (& expected) "RFC 4231 one shot")
    (while (<= split (buf.bytes-length message))
      (let
        [state : hmac.HmacSha256State
          (state-from (& key) (hmac.default-limits))]
        (require-ok
          (hmac.update! (&mut state) (buf.bytes-slice-view message 0 0)))
        (require-ok
          (hmac.update! (&mut state) (buf.bytes-slice-view message 0 split)))
        (require-ok
          (hmac.update!
            (&mut state)
            (buf.bytes-slice-view
              message
              split
              (- (buf.bytes-length message) split))))
        (let
          [streamed : hmac.HmacSha256Tag
            (tag-from (hmac.finalize! (&mut state)))]
          (test.assert-true
            (hmac.tag-equal? (& tag) (& streamed))
            "every split"))
        (hmac.close state))
      (set! split (+ split 1)))
    (let
      [state : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
      [i : i64 0]
      (while (< i (buf.bytes-length message))
        (require-ok
          (hmac.update! (&mut state) (buf.bytes-slice-view message i 1)))
        (set! i (+ i 1)))
      (let
        [streamed : hmac.HmacSha256Tag (tag-from (hmac.finalize! (&mut state)))]
        (test.assert-true
          (hmac.tag-equal? (& tag) (& streamed))
          "one byte chunks"))
      (hmac.close state))
    (secret.close-bytes key)))

;: Check all retained backing words after a terminal operation.
(define (assert-wiped [storage : (MutPtr hmac.HmacSha256Storage)]) : unit
  (let
    [i : i64 2]
    [left : u64 (cast 0 : u64)]
    (while (< i (/ (comptime (size-of (type hmac.HmacSha256Storage))) 8))
      (set!
        left
        (bit-or
          left
          (unsafe
            (ptr-read (ptr-offset (ptr-cast storage : (Ptr u64)) i)))))
      (set! i (+ i 1)))
    (test.assert-true (= left (cast 0 : u64)) "all keyed backing words wiped")
    (test.assert-true
      (unsafe
        (not (= (deref storage).phase 0)))
      "phase poisoned")
    (test.assert-i64-eq
      (unsafe
        (deref storage).generation)
      0
      "generation poisoned")))

;: Every operation on a terminal handle has the same closed-state error.
(define (assert-closed
  [state : (&mut state hmac.HmacSha256State)]
  [key : (& key secret.SecretBytes)]) : unit
  (match (hmac.update! state (buf.str-as-bytes ""))
    [(HmacSha256Err (HmacSha256Closed)) unit]
    [_ (test.assert-true false "closed public update")])
  (match (hmac.update-secret! state key)
    [(HmacSha256Err (HmacSha256Closed)) unit]
    [_ (test.assert-true false "closed secret update")])
  (match (hmac.finalize! state)
    [(HmacSha256TagErr (HmacSha256Closed)) unit]
    [_ (test.assert-true false "closed public finalize")])
  (match (hmac.finalize-secret! state)
    [(HmacSha256SecretErr (HmacSha256Closed)) unit]
    [(HmacSha256SecretErr _)
      (test.assert-true false "closed secret finalize error")]
    [(HmacSha256SecretOk output)
      (secret.close-fixed output)
      (test.assert-true false "closed secret finalize")])
  (match (hmac.verify! state (buf.str-as-bytes ""))
    [(HmacSha256VerifyErr (HmacSha256Closed)) unit]
    [_ (test.assert-true false "closed verify")]))

;: Exact edge semantics and adversarial splits around SHA padding/blocks.
(define (hmac-binary-empty-and-block-boundaries) : unit
  (vector
    (buf.str-as-bytes "")
    (buf.str-as-bytes "")
    "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad")
  (let
    [sizes : (Array i64 8) (array 0 1 31 32 63 64 65 131)]
    [splits : (Array i64 16)
      (array 0 1 54 55 56 57 62 63 64 65 66 127 128 129 255 4097)]
    [message : buf.ByteBuf (buf.new)]
    [empty-key : secret.SecretBytes (key-from (buf.str-as-bytes ""))]
    [baseline : hmac.HmacSha256Tag (hmac.HmacSha256Tag (make-array u8 32))]
    [i : i64 0]
    (while (< i 4097)
      (set! message (buf.push message (cast (% i 256) : u8)))
      (set! i (+ i 1)))
    (set! i 0)
    (set!
      baseline
      (tag-from
        (hmac.authenticate
          (& empty-key)
          (buf.as-bytes (& message))
          (hmac.default-limits))))
    (while (< i 8)
      (let
        [public-key : buf.ByteBuf (filled (array-ref sizes i) (cast 0 : u8))]
        [key : secret.SecretBytes (key-from (buf.as-bytes (& public-key)))]
        [expected : hmac.HmacSha256Tag
          (tag-from
            (hmac.authenticate
              (& key)
              (buf.as-bytes (& message))
              (hmac.default-limits)))]
        [j : i64 0]
        (if (<= (array-ref sizes i) 64)
          (test.assert-true
            (hmac.tag-equal? (& baseline) (& expected))
            "zero-padding identity includes exact64 key")
          (test.assert-false
            (hmac.tag-equal? (& baseline) (& expected))
            "long zero key is hashed"))
        (while (< j 16)
          (let
            [split : i64 (array-ref splits j)]
            [state : hmac.HmacSha256State
              (state-from (& key) (hmac.default-limits))]
            (require-ok
              (hmac.update!
                (&mut state)
                (buf.bytes-slice-view (buf.as-bytes (& message)) 0 split)))
            (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "")))
            (require-ok
              (hmac.update!
                (&mut state)
                (buf.bytes-slice-view
                  (buf.as-bytes (& message))
                  split
                  (- 4097 split))))
            (let
              [actual : hmac.HmacSha256Tag
                (tag-from (hmac.finalize! (&mut state)))]
              (test.assert-true
                (hmac.tag-equal? (& expected) (& actual))
                "binary multi-block split"))
            (assert-closed (&mut state) (& key))
            (assert-wiped state.handle.storage)
            (hmac.close state))
          (set! j (+ j 1)))
        (secret.close-bytes key))
      (set! i (+ i 1)))
    (secret.close-bytes empty-key)))

;: Limits include exact N and N-1 pins, with no key read on refusal.
(define (hmac-limits-and-invalid-keys) : unit
  (match (unsafe
    (hmac.new-from-pointer
      (int->ptr (cast 1 : u64) : (Ptr u8))
      131
      (hmac.HmacSha256Limits 130 0)))
    [(HmacSha256NewErr (HmacSha256KeyTooLong 131 130)) unit]
    [(HmacSha256NewErr _) (test.assert-true false "long key preflight error")]
    [(HmacSha256NewOk state)
      (hmac.close state)
      (test.assert-true false "long key must fail before source read")])
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    (match (hmac.new (& key) (hmac.HmacSha256Limits 2 3))
      [(HmacSha256NewErr (HmacSha256KeyTooLong 3 2)) unit]
      [(HmacSha256NewErr _) (test.assert-true false "key limit error")]
      [(HmacSha256NewOk state)
        (hmac.close state)
        (test.assert-true false "N-1 key cap")])
    (let
      [state : hmac.HmacSha256State
        (state-from (& key) (hmac.HmacSha256Limits 3 3))]
      (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "abc")))
      (let
        [tag : hmac.HmacSha256Tag (tag-from (hmac.finalize! (&mut state)))]
        (test.assert-i64-eq
          (array-length tag.octets)
          32
          "N key and message cap"))
      (assert-wiped state.handle.storage)
      (hmac.close state))
    (let
      [invalid : (Array hmac.HmacSha256Limits 4)
        (array
          (hmac.HmacSha256Limits -1 0)
          (hmac.HmacSha256Limits 0 -1)
          (hmac.HmacSha256Limits 0 (+ (hmac.max-message-bytes) 1))
          (hmac.HmacSha256Limits 9223372036854775807 0))]
      [i : i64 0]
      (while (< i 4)
        (match (hmac.new (& key) (array-ref invalid i))
          [(HmacSha256NewErr (HmacSha256InvalidLimits)) unit]
          [(HmacSha256NewErr _) (test.assert-true false "invalid limits error")]
          [(HmacSha256NewOk state)
            (hmac.close state)
            (test.assert-true false "invalid limits accepted")])
        (set! i (+ i 1))))
    (secret.close-bytes key))
  (let
    [null-key : secret.SecretBytes
      (secret.SecretBytes (ptr-null : (MutPtr secret.SecretStorage)) 9)]
    (match (hmac.new (& null-key) (hmac.default-limits))
      [(HmacSha256NewErr (HmacSha256SecretError (secret.SecretClosed))) unit]
      [(HmacSha256NewErr _) (test.assert-true false "null key error")]
      [(HmacSha256NewOk state)
        (hmac.close state)
        (test.assert-true false "null key accepted")])
    (secret.close-bytes null-key)))

;: Tiny injected counters exercise the algorithmic prefix boundary, never
;: allocating or reading an enormous input. Pointer 1 must never be read.
(define (hmac-sha-prefix-limit-and-preflight) : unit
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    [state : hmac.HmacSha256State
      (state-from (& key) (hmac.HmacSha256Limits 3 (hmac.max-message-bytes)))]
    (match (unsafe
      (hmac.update-from-pointer! (&mut state) (ptr-null : (Ptr u8)) 1))
      [(HmacSha256Err (HmacSha256InvalidSource)) unit]
      [_ (test.assert-true false "null source preflight")])
    (match (unsafe
      (hmac.update-from-pointer! (&mut state) (ptr-null : (Ptr u8)) -1))
      [(HmacSha256Err (HmacSha256InvalidSourceLength -1)) unit]
      [_ (test.assert-true false "negative source preflight")])
    (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "abc")))
    (unsafe
      (set!
        (deref state.handle.storage).message-length
        (- (hmac.max-message-bytes) 1))
      (set!
        (deref state.handle.storage).inner.byte-length
        (- (sha.max-byte-length) (cast 1 : u64)))
      (set! (deref state.handle.storage).inner.block-length 62))
    (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "x")))
    (match (unsafe
      (hmac.update-from-pointer!
        (&mut state)
        (int->ptr (cast 1 : u64) : (Ptr u8))
        1))
      [(HmacSha256Err (HmacSha256MessageTooLong _ 1 _)) unit]
      [_ (test.assert-true false "64-byte prefix accounted before source read")])
    (assert-wiped state.handle.storage)
    (assert-closed (&mut state) (& key))
    (hmac.close state)
    (secret.close-bytes key)))

;: Nominal downstream ownership transfer, with identical storage address.
(defstruct TestKdfOwner
  (:cleanup close-test-kdf-owner)
  (output secret.SecretFixed (:owned)))

;: Both secret adapters share accounting and exact initialized ranges.
(define (hmac-secret-input-output-and-move) : unit
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    [public : buf.ByteBuf (filled 32 (cast 0 : u8))]
    [input : secret.SecretBytes (key-from (buf.as-bytes (& public)))]
    [fixed : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [state : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
    [second : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
    (require-ok (hmac.update-secret! (&mut state) (& input)))
    (require-ok (hmac.update-fixed! (&mut second) (& fixed)))
    (match (hmac.finalize-secret! (&mut state))
      [(HmacSha256SecretErr _) (test.assert-true false "secret output")]
      [(HmacSha256SecretOk output)
        (let
          [address : u64
            (unsafe
              (ptr->int output.storage))]
          [consumer : TestKdfOwner (TestKdfOwner output)]
          [tag : hmac.HmacSha256Tag (tag-from (hmac.finalize! (&mut second)))]
          [public-tag : String
            (unsafe
              (string-from-bytes
                (ptr-cast (ptr-addr-of tag.octets) : (Ptr u8))
                32))]
          (test.assert-true
            (=
              address
              (unsafe
                (ptr->int consumer.output.storage)))
            "move without byte copy")
          (match (secret.fixed-from-bytes
            (secret.Secret32)
            (buf.str-as-bytes (& public-tag)))
            [(SecretFixedErr _)
              (test.assert-true false "public expected owner")]
            [(SecretFixedOk expected)
              (match (secret.fixed-equal (& consumer.output) (& expected))
                [(SecretCompareOk equal)
                  (test.assert-true
                    equal
                    "secret result equals full public tag")]
                [_ (test.assert-true false "secret result comparison")])
              (secret.close-fixed expected)])
          (close-test-kdf-owner consumer))])
    (let
      [short : hmac.HmacSha256State
        (state-from (& key) (hmac.HmacSha256Limits 3 31))]
      (match (hmac.update-fixed! (&mut short) (& fixed))
        [(HmacSha256Err (HmacSha256MessageTooLong 0 32 31)) unit]
        [_ (test.assert-true false "fixed adapter budget")])
      (assert-wiped short.handle.storage)
      (hmac.close short))
    (match (hmac.new-fixed (& fixed) (hmac.default-limits))
      [(HmacSha256NewErr _) (test.assert-true false "fixed key")]
      [(HmacSha256NewOk fixed-state)
        (let
          [variable-key : secret.SecretBytes
            (key-from (buf.as-bytes (& public)))]
          [expected : hmac.HmacSha256Tag
            (tag-from
              (hmac.authenticate
                (& variable-key)
                (buf.str-as-bytes "")
                (hmac.default-limits)))]
          [actual : hmac.HmacSha256Tag
            (tag-from (hmac.finalize! (&mut fixed-state)))]
          (test.assert-true
            (hmac.tag-equal? (& actual) (& expected))
            "fixed key uses same normalization")
          (secret.close-bytes variable-key))
        (hmac.close fixed-state)])
    (assert-wiped state.handle.storage)
    (assert-wiped second.handle.storage)
    (hmac.close state)
    (hmac.close second)
    (secret.close-fixed fixed)
    (secret.close-bytes input)
    (secret.close-bytes key)))

;: All equal-length mismatches, a fixed-seed mutation corpus, and exact width.
(define (hmac-verification-and-negative-corpus) : unit
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    [tag : hmac.HmacSha256Tag
      (tag-from
        (hmac.authenticate
          (& key)
          (buf.str-as-bytes "message")
          (hmac.default-limits)))]
    [expected : buf.ByteBuf (buf.new)]
    [i : i64 0]
    [seed : u64 (cast 7311 : u64)]
    (while (< i 32)
      (set! expected (buf.push expected (array-ref tag.octets i)))
      (set! i (+ i 1)))
    (match (hmac.verify
      (& key)
      (buf.str-as-bytes "message")
      (buf.as-bytes (& expected))
      (hmac.default-limits))
      [(HmacSha256VerifyOk equal) (test.assert-true equal "valid full tag")]
      [_ (test.assert-true false "valid verification")])
    (set! i 0)
    (while (< i 128)
      (let
        [position : i64
          (if (< i 32)
            i
            (cast (% seed (cast 32 : u64)) : i64))]
        [original : u8 (buf.ref (& expected) position)]
        [state : hmac.HmacSha256State
          (state-from (& key) (hmac.default-limits))]
        (set! seed (+ (* seed (cast 1664525 : u64)) (cast 1013904223 : u64)))
        (set!
          expected
          (buf.set! expected position (bit-xor original (cast 1 : u8))))
        (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "message")))
        (match (hmac.verify! (&mut state) (buf.as-bytes (& expected)))
          [(HmacSha256VerifyOk equal)
            (test.assert-false equal "mismatch anywhere")]
          [_ (test.assert-true false "equal length comparison must complete")])
        (assert-wiped state.handle.storage)
        (assert-closed (&mut state) (& key))
        (hmac.close state)
        (set! expected (buf.set! expected position original)))
      (set! i (+ i 1)))
    (let
      [widths : (Array i64 6) (array 0 1 16 31 33 64)]
      [j : i64 0]
      (while (< j 6)
        (let
          [bad-tag : buf.ByteBuf (filled (array-ref widths j) (cast 0 : u8))]
          [state : hmac.HmacSha256State
            (state-from (& key) (hmac.default-limits))]
          (match (hmac.verify! (&mut state) (buf.as-bytes (& bad-tag)))
            [(HmacSha256VerifyErr (HmacSha256TagLength actual))
              (test.assert-i64-eq
                actual
                (array-ref widths j)
                "no truncated/prefix verification")]
            [_ (test.assert-true false "wrong tag length")])
          (assert-wiped state.handle.storage)
          (assert-closed (&mut state) (& key))
          (hmac.close state))
        (set! j (+ j 1))))
    (secret.close-bytes key)))

;: Lexical cleanup, repeated closure, stale generations and internal errors.
(define (hmac-cleanup-generation-and-processing-failure) : unit
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    [state : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
    [forged : hmac.HmacSha256State
      (hmac.HmacSha256State
        (hmac.HmacSha256Handle
          state.handle.storage
          (+ state.handle.generation 1)))]
    [storage : (MutPtr hmac.HmacSha256Storage) state.handle.storage]
    (assert-closed (&mut forged) (& key))
    (hmac.close! (&mut forged))
    (hmac.close forged)
    (test.assert-true
      (hmac.live? (& state))
      "stale cleanup cannot retire current generation")
    (with
      ([active state hmac.close])
      (require-ok
        (hmac.update! (&mut active) (buf.str-as-bytes "pending message"))))
    (assert-wiped storage)
    (let
      [bad : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
      (unsafe
        (set! (deref bad.handle.storage).inner.block-length 64))
      (match (hmac.update! (&mut bad) (buf.str-as-bytes "x"))
        [(HmacSha256Err (HmacSha256ShaError (sha.Sha256InvalidState))) unit]
        [_ (test.assert-true false "internal SHA update failure")])
      (assert-wiped bad.handle.storage)
      (assert-closed (&mut bad) (& key))
      (hmac.close bad))
    (let
      [bad : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
      (unsafe
        (set! (deref bad.handle.storage).outer.finalized true))
      (match (hmac.finalize-secret! (&mut bad))
        [(HmacSha256SecretErr (HmacSha256ShaError (sha.Sha256Finalized))) unit]
        [(HmacSha256SecretErr _)
          (test.assert-true false "internal finalize error")]
        [(HmacSha256SecretOk output)
          (secret.close-fixed output)
          (test.assert-true false "no partial secret result")])
      (assert-wiped bad.handle.storage)
      (assert-closed (&mut bad) (& key))
      (hmac.close! (&mut bad))
      (hmac.close! (&mut bad))
      (hmac.close bad))
    (secret.close-bytes key)))

;: RFC 4231 sections 4.2-4.5 and 4.7-4.8; case 5 is truncated.
(define (hmac-rfc4231-full-vectors) : unit
  (let
    [key1 : buf.ByteBuf (filled 20 (cast 11 : u8))]
    [key3 : buf.ByteBuf (filled 20 (cast 170 : u8))]
    [key4 : buf.ByteBuf (buf.new)]
    [key6 : buf.ByteBuf (filled 131 (cast 170 : u8))]
    [msg3 : buf.ByteBuf (filled 50 (cast 221 : u8))]
    [msg4 : buf.ByteBuf (filled 50 (cast 205 : u8))]
    [i : i64 1]
    (while (<= i 25)
      (set! key4 (buf.push key4 (cast i : u8)))
      (set! i (+ i 1)))
    (vector
      (buf.as-bytes (& key1))
      (buf.str-as-bytes "Hi There")
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    (vector
      (buf.str-as-bytes "Jefe")
      (buf.str-as-bytes "what do ya want for nothing?")
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    (vector
      (buf.as-bytes (& key3))
      (buf.as-bytes (& msg3))
      "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
    (vector
      (buf.as-bytes (& key4))
      (buf.as-bytes (& msg4))
      "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
    (vector
      (buf.as-bytes (& key6))
      (buf.str-as-bytes
        "Test Using Larger Than Block-Size Key - Hash Key First")
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    (vector
      (buf.as-bytes (& key6))
      (buf.str-as-bytes
        "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.")
      "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")))

;: Borrow precondition refusal preserves the exact live stream.
(define (hmac-preflight-refusal-keeps-live) : unit
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    [bad : secret.SecretBytes (key-from (buf.str-as-bytes "secret"))]
    [empty : secret.SecretBytes (key-from (buf.str-as-bytes ""))]
    [stale : secret.SecretBytes
      (secret.SecretBytes bad.storage (+ bad.generation 1))]
    [state : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
    (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "a")))
    (require-ok (hmac.update-secret! (&mut state) (& empty)))
    (match (hmac.update-secret! (&mut state) (& stale))
      [(HmacSha256Err (HmacSha256SecretError (secret.SecretClosed))) unit]
      [_ (test.assert-true false "stale source refusal")])
    (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "bc")))
    (let
      [actual : hmac.HmacSha256Tag (tag-from (hmac.finalize! (&mut state)))]
      [expected : hmac.HmacSha256Tag
        (tag-from
          (hmac.authenticate
            (& key)
            (buf.str-as-bytes "abc")
            (hmac.default-limits)))]
      (test.assert-true
        (hmac.tag-equal? (& actual) (& expected))
        "refusal preserves stream"))
    (hmac.close state)
    (secret.close-bytes stale)
    (secret.close-bytes empty)
    (secret.close-bytes bad)
    (secret.close-bytes key)))

;: Exact total boundary succeeds, one less terminates before absorption.
(define (hmac-total-limit-is-terminal) : unit
  (let
    [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
    [state : hmac.HmacSha256State
      (state-from (& key) (hmac.HmacSha256Limits 3 3))]
    [short : hmac.HmacSha256State
      (state-from (& key) (hmac.HmacSha256Limits 3 2))]
    (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "abc")))
    (require-ok (hmac.update! (&mut short) (buf.str-as-bytes "ab")))
    (match (hmac.update! (&mut short) (buf.str-as-bytes "c"))
      [(HmacSha256Err (HmacSha256MessageTooLong _ _ _)) unit]
      [_ (test.assert-true false "cumulative refusal")])
    (match (hmac.update! (&mut short) (buf.str-as-bytes ""))
      [(HmacSha256Err (HmacSha256Closed)) unit]
      [_ (test.assert-true false "overflow must close")])
    (match (hmac.finalize! (&mut short))
      [(HmacSha256TagErr (HmacSha256Closed)) unit]
      [_ (test.assert-true false "no partial tag after overflow")])
    (let
      [tag : hmac.HmacSha256Tag (tag-from (hmac.finalize! (&mut state)))]
      (test.assert-i64-eq (array-length tag.octets) 32 "exact boundary"))
    (hmac.close short)
    (hmac.close state)
    (secret.close-bytes key)))

;: Shared native and inline entry points exercise exactly the same bodies.
;: Positive allocation control and exact fixed-size allocation contracts.
(cfg
  compile-profile
  (define (hmac-allocation-contract) : unit
    (let
      [key : secret.SecretBytes (key-from (buf.str-as-bytes "key"))]
      [before : i64 (profile.alloc-total)]
      [state : hmac.HmacSha256State (state-from (& key) (hmac.default-limits))]
      [after-new : i64 (profile.alloc-total)]
      (test.assert-i64-eq
        (- after-new before)
        (comptime (size-of (type hmac.HmacSha256Storage)))
        "one fixed backing allocation")
      (test.assert-true (> after-new before) "allocation counters active")
      (require-ok (hmac.update! (&mut state) (buf.str-as-bytes "abc")))
      (test.assert-i64-eq
        (profile.alloc-total)
        after-new
        "update allocates nothing")
      (match (hmac.new (& key) (hmac.HmacSha256Limits 2 3))
        [(HmacSha256NewErr _) unit]
        [(HmacSha256NewOk unexpected)
          (hmac.close unexpected)
          (test.assert-true false "key cap refusal")])
      (test.assert-i64-eq
        (profile.alloc-total)
        after-new
        "key refusal allocates nothing")
      (match (hmac.finalize-secret! (&mut state))
        [(HmacSha256SecretErr _) (test.assert-true false "secret allocation")]
        [(HmacSha256SecretOk output)
          (test.assert-i64-eq
            (- (profile.alloc-total) after-new)
            64
            "32-byte header and exact32 result")
          (secret.close-fixed output)])
      (hmac.close state)
      (secret.close-bytes key))))

(cfg
  (not compile-profile)
  (define (hmac-allocation-contract) : unit
    unit))

;: RFC 4231 case 5 is exactly a 16-byte truncated expected value.
(define (hmac-rfc4231-truncation-rejected) : unit
  (let
    [raw : buf.ByteBuf (filled 20 (cast 12 : u8))]
    [key : secret.SecretBytes (key-from (buf.as-bytes (& raw)))]
    [truncated : (Array u8 16)
      (array 163 182 22 116 115 16 14 224 110 12 121 108 41 85 85 43)]
    [text : String
      (unsafe
        (string-from-bytes (ptr-cast (ptr-addr-of truncated) : (Ptr u8)) 16))]
    (match (hmac.verify
      (& key)
      (buf.str-as-bytes "Test With Truncation")
      (buf.str-as-bytes (& text))
      (hmac.default-limits))
      [(HmacSha256VerifyErr (HmacSha256TagLength 16)) unit]
      [_ (test.assert-true false "RFC truncated tag is not full verification")])
    (secret.close-bytes key)))

(cfg
  test
  (test hmac-rfc4231-truncation-rejected (hmac-rfc4231-truncation-rejected)))

(cfg test (test hmac-allocation-contract (hmac-allocation-contract)))

(cfg
  test
  (test
    hmac-binary-empty-and-block-boundaries
    (hmac-binary-empty-and-block-boundaries)))

(cfg test (test hmac-limits-and-invalid-keys (hmac-limits-and-invalid-keys)))

(cfg
  test
  (test
    hmac-sha-prefix-limit-and-preflight
    (hmac-sha-prefix-limit-and-preflight)))

(cfg
  test
  (test hmac-secret-input-output-and-move (hmac-secret-input-output-and-move)))

(cfg
  test
  (test
    hmac-verification-and-negative-corpus
    (hmac-verification-and-negative-corpus)))

(cfg
  test
  (test
    hmac-cleanup-generation-and-processing-failure
    (hmac-cleanup-generation-and-processing-failure)))

(cfg test (test hmac-rfc4231-full-vectors (hmac-rfc4231-full-vectors)))

(cfg
  test
  (test hmac-preflight-refusal-keeps-live (hmac-preflight-refusal-keeps-live)))

(cfg test (test hmac-total-limit-is-terminal (hmac-total-limit-is-terminal)))

(define (main) : i64
  (hmac-allocation-contract)
  (hmac-rfc4231-truncation-rejected)
  (hmac-binary-empty-and-block-boundaries)
  (hmac-limits-and-invalid-keys)
  (hmac-sha-prefix-limit-and-preflight)
  (hmac-secret-input-output-and-move)
  (hmac-verification-and-negative-corpus)
  (hmac-cleanup-generation-and-processing-failure)
  (hmac-rfc4231-full-vectors)
  (hmac-preflight-refusal-keeps-live)
  (hmac-total-limit-is-terminal)
  42)