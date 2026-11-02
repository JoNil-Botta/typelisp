(module stdlib.crypto_hkdf_sha256.tests)

(import stdlib.byte_buf as buf)
(import stdlib.crypto_hmac_sha256 as hmac)
(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_secret as secret)
(import stdlib.test)
(import stdlib.io)

;: Explicit test budgets, never a production default.
(define (limits) : hkdf.HkdfSha256Limits
  (hkdf.HkdfSha256Limits
    65536
    65536
    65536
    8160
    131072
    16777216
    (hmac.HmacSha256Limits 65536 131072)))

;: Decode only public RFC fixture material.
(define (hex [text : (& text str)]) : buf.ByteBuf
  (let
    [input (buf.str-as-bytes text)]
    [out (buf.new)]
    [i : i64 0]
    (while (< i (buf.bytes-length input))
      (let
        [a : i64 (cast (buf.bytes-get input i (cast 0 : u8)) : i64)]
        [b : i64 (cast (buf.bytes-get input (+ i 1) (cast 0 : u8)) : i64)]
        (set!
          a
          (if (<= a 57)
            (- a 48)
            (- a 87)))
        (set!
          b
          (if (<= b 57)
            (- b 48)
            (- b 87)))
        (set! out (buf.push out (cast (+ (* a 16) b) : u8))))
      (set! i (+ i 2)))
    out))

;: Initialize a cleanup-owned input or expected vector.
(define (input-from [source : (& source bytes)]) : secret.SecretBytes
  (match (secret.bytes-from-bytes source (buf.bytes-length source))
    [(SecretBytesOk value) value]
    [(SecretBytesErr _)
      (test.assert-true false "input construction")
      (input-from source)]))

;: Require Extract success without introducing a PRK constructor.
(define (prk-from [result : hkdf.HkdfSha256ExtractResult]) : hkdf.HkdfSha256Prk
  (match result
    [(HkdfSha256ExtractOk value) value]
    [(HkdfSha256ExtractErr _) (io.panic "Extract must succeed")]))

;: Compare opaque PRK with cleanup-owned expected material, using fixed work.
(define (assert-prk
  [actual : (& actual hkdf.HkdfSha256Prk)]
  [expected-hex : (& expected-hex str)]) : unit
  (let
    [public (hex expected-hex)]
    [expected (input-from (buf.as-bytes (& public)))]
    (match (unsafe
      (hkdf.prk-read-pointer actual))
      [(SecretReadOk a)
        (match (unsafe
          (secret.bytes-read-pointer (& expected) 0 32))
          [(SecretReadOk b)
            (test.assert-true
              (=
                (unsafe
                  (secret.difference-bits a b 32))
                (cast 0 : u64))
              "RFC PRK")]
          [_ (test.assert-true false "expected live")])]
      [_ (test.assert-true false "PRK live")])
    (secret.close-bytes expected)))

;: Compare opaque OKM with cleanup-owned expected material.
(define (assert-okm
  [result : hkdf.HkdfSha256ExpandResult]
  [expected-hex : (& expected-hex str)]) : unit
  (match result
    [(HkdfSha256ExpandOk output)
      (let
        [public (hex expected-hex)]
        [expected (input-from (buf.as-bytes (& public)))]
        (test.assert-i64-eq
          (hkdf.okm-length (& output))
          (buf.length (& public))
          "exact OKM length")
        (match (unsafe
          (hkdf.okm-read-pointer
            (& output)
            0
            (secret.bytes-length (& expected))))
          [(SecretReadOk actual)
            (match (unsafe
              (secret.bytes-read-pointer
                (& expected)
                0
                (secret.bytes-length (& expected))))
              [(SecretReadOk want)
                (test.assert-true
                  (=
                    (unsafe
                      (secret.difference-bits
                        actual
                        want
                        (secret.bytes-length (& expected))))
                    (cast 0 : u64))
                  "RFC OKM")]
              [_ (test.assert-true false "expected live")])]
          [_ (test.assert-true false "live exact-length OKM")])
        (secret.close-bytes expected))
      (hkdf.close-okm output)]
    [_ (test.assert-true false "Expand succeeds")]))

;: RFC 5869 Appendix A.1/A.2/A.3, exact PRK and exact-length OKM.
(define (rfc-vector
  [ikm-hex : String]
  [salt-hex : String]
  [info-hex : String]
  [prk-hex : String]
  [okm-hex : String]
  [length : i64]
  [absent : bool]) : unit
  (let
    [ikm-public (hex (& ikm-hex))]
    [salt-public (hex (& salt-hex))]
    [info (hex (& info-hex))]
    [ikm (input-from (buf.as-bytes (& ikm-public)))]
    [salt (input-from (buf.as-bytes (& salt-public)))]
    [prk
      (prk-from
        (hkdf.extract-public (buf.as-bytes (& salt-public)) (& ikm) (limits)))]
    [secret-prk (prk-from (hkdf.extract-secret (& salt) (& ikm) (limits)))]
    (assert-prk (& prk) (& prk-hex))
    (assert-prk (& secret-prk) (& prk-hex))
    (assert-okm
      (hkdf.expand (& prk) (buf.as-bytes (& info)) length (limits))
      (& okm-hex))
    (assert-okm
      (hkdf.expand (& secret-prk) (buf.as-bytes (& info)) length (limits))
      (& okm-hex))
    (when
      absent
      (let
        [absent-prk (prk-from (hkdf.extract (& ikm) (limits)))]
        (assert-prk (& absent-prk) (& prk-hex))
        (assert-okm
          (hkdf.expand (& absent-prk) (buf.as-bytes (& info)) length (limits))
          (& okm-hex))
        (hkdf.close-prk absent-prk)))
    (test.assert-i64-eq
      (secret.bytes-length (& ikm))
      (buf.length (& ikm-public))
      "IKM borrowed")
    (test.assert-i64-eq
      (secret.bytes-length (& salt))
      (buf.length (& salt-public))
      "salt borrowed")
    (hkdf.close-prk secret-prk)
    (hkdf.close-prk prk)
    (secret.close-bytes salt)
    (secret.close-bytes ikm)))

;: Exact RFC SHA-256 cases 1 through 3.
(define (rfc-vectors) : unit
  (rfc-vector
    "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
    "000102030405060708090a0b0c"
    "f0f1f2f3f4f5f6f7f8f9"
    "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    42
    false)
  (rfc-vector
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
    "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
    "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244"
    "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"
    82
    false)
  (rfc-vector
    "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
    ""
    ""
    "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"
    "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
    42
    true))

;: The RFC maximum rejects before any output/block construction.
(define (reject-8161) : unit
  (let
    [ikm (input-from (buf.str-as-bytes ""))]
    [prk (prk-from (hkdf.extract (& ikm) (limits)))]
    (match (hkdf.expand (& prk) (buf.str-as-bytes "") 8161 (limits))
      [(HkdfSha256ExpandErr (HkdfSha256OutputLimit 8161 8160)) unit]
      [(HkdfSha256ExpandOk output)
        (hkdf.close-okm output)
        (test.assert-true false "8161 rejected")]
      [_ (test.assert-true false "typed RFC output rejection")])
    (hkdf.close-prk prk)
    (secret.close-bytes ikm)))

(define (main) : i64
  (rfc-vectors)
  (reject-8161)
  (work-planning)
  (output-boundaries)
  (limit-and-liveness)
  (owner-cleanup)
  (wrong-prk-sizes)
  (rolling-lifecycle)
  (internal-failures)
  (cfg compile-profile (allocation-contract))
  42)

;: Match only public error categories and clean any unexpected owner.
(define (expand-error [result : hkdf.HkdfSha256ExpandResult]) : i64
  (match result
    [(HkdfSha256ExpandErr (HkdfSha256InvalidLimits)) 1]
    [(HkdfSha256ExpandErr (HkdfSha256InfoLimit _ _)) 2]
    [(HkdfSha256ExpandErr (HkdfSha256OutputLimit _ _)) 3]
    [(HkdfSha256ExpandErr (HkdfSha256ExpandWorkLimit _ _)) 4]
    [(HkdfSha256ExpandErr (HkdfSha256WorkOverflow)) 5]
    [(HkdfSha256ExpandErr (HkdfSha256InvalidPrk)) 6]
    [(HkdfSha256ExpandErr (HkdfSha256HmacError _)) 7]
    [(HkdfSha256ExpandErr (HkdfSha256SecretError _)) 8]
    [(HkdfSha256ExpandOk value)
      (hkdf.close-okm value)
      0]
    [(HkdfSha256ExpandErr _) 9]))

;: Classify Extract failures without ever revealing the derived value.
(define (extract-error [result : hkdf.HkdfSha256ExtractResult]) : i64
  (match result
    [(HkdfSha256ExtractErr (HkdfSha256InvalidLimits)) 1]
    [(HkdfSha256ExtractErr (HkdfSha256SaltLimit _ _)) 2]
    [(HkdfSha256ExtractErr (HkdfSha256IkmLimit _ _)) 3]
    [(HkdfSha256ExtractErr (HkdfSha256ExtractWorkLimit _ _)) 4]
    [(HkdfSha256ExtractErr (HkdfSha256WorkOverflow)) 5]
    [(HkdfSha256ExtractErr (HkdfSha256HmacError _)) 7]
    [(HkdfSha256ExtractErr (HkdfSha256SecretError _)) 8]
    [(HkdfSha256ExtractErr _) 9]
    [(HkdfSha256ExtractOk value)
      (hkdf.close-prk value)
      0]))

;: Independently sum the actual messages for every possible block count.
(define (work-planning) : unit
  (let
    [infos : (Array i64 4) (array 0 10 256 65536)]
    [j : i64 0]
    (while (< j 4)
      (let
        [n : i64 0]
        [info : i64 (array-ref infos j)]
        (while (<= n 255)
          (let
            [sum : i64 0]
            [block : i64 1]
            [budget (limits)]
            (while (<= block n)
              (set!
                sum
                (+
                  sum
                  (+
                    info
                    (if (= block 1)
                      1
                      33))))
              (set! block (+ block 1)))
            (set! budget.max-expand-work sum)
            (match (hkdf.expand-plan info (* n 32) (& budget))
              [(HkdfSha256PlanOk plan)
                (test.assert-i64-eq plan.blocks n "exact blocks")
                (test.assert-i64-eq
                  plan.feed-bytes
                  sum
                  "independent streamed feed sum")]
              [_ (test.assert-true false "exact work admitted")])
            (when
              (> sum 0)
              (set! budget.max-expand-work (- sum 1))
              (match (hkdf.expand-plan info (* n 32) (& budget))
                [(HkdfSha256PlanErr (HkdfSha256ExpandWorkLimit _ _)) unit]
                [_ (test.assert-true false "one-less work refuses")])))
          (set! n (+ n 1))))
      (set! j (+ j 1))))
  (let
    [budget (limits)]
    (set! budget.max-info-bytes 9223372036854775807)
    (set! budget.max-expand-work 9223372036854775807)
    (match (hkdf.expand-plan 9223372036854775807 8160 (& budget))
      [(HkdfSha256PlanErr (HkdfSha256WorkOverflow)) unit]
      [_ (test.assert-true false "checked work overflow")])
    (match (hkdf.expand-plan 9223372036854775807 0 (& budget))
      [(HkdfSha256PlanOk plan)
        (test.assert-i64-eq
          plan.feed-bytes
          0
          "zero avoids hypothetical overflow")]
      [_ (test.assert-true false "zero ignores nonexistent messages")])
    (set! budget.hmac-limits (hmac.HmacSha256Limits 32 11))
    (match (hkdf.expand-plan 10 32 (& budget))
      [(HkdfSha256PlanOk _) unit]
      [_ (test.assert-true false "one block exact message cap")])
    (match (hkdf.expand-plan 10 33 (& budget))
      [(HkdfSha256PlanErr (HkdfSha256HmacError _)) unit]
      [_ (test.assert-true false "two blocks need previous T budget")])))

;: The reference uses independent HMAC feeds/counter sequencing and range reads.
;: It never converts an actual PRK, block or OKM into public fixture material.
(define (reference-block
  [prk : (& prk hkdf.HkdfSha256Prk)]
  [prior : (& prior secret.SecretBytes)]
  [info : (& info bytes)]
  [counter : u8]) : secret.SecretFixed
  (match (unsafe
    (hkdf.prk-read-pointer (& prk)))
    [(SecretReadErr _) (io.panic "reference PRK")]
    [(SecretReadOk key)
      (match (unsafe
        (hmac.new-from-pointer key 32 (hmac.HmacSha256Limits 32 131072)))
        [(HmacSha256NewErr _) (io.panic "reference HMAC")]
        [(HmacSha256NewOk state)
          (with
            ([active state hmac.close])
            (match (hmac.update-secret! (&mut active) prior)
              [(HmacSha256Ok) unit]
              [_ (io.panic "reference previous")])
            (match (hmac.update! (&mut active) info)
              [(HmacSha256Ok) unit]
              [_ (io.panic "reference info")])
            (match (unsafe
              (hmac.update-from-pointer!
                (&mut active)
                (ptr-cast (ptr-addr-of counter) : (Ptr u8))
                1))
              [(HmacSha256Ok) unit]
              [_ (io.panic "reference counter")])
            (match (hmac.finalize-secret! (&mut active))
              [(HmacSha256SecretOk value) value]
              [_ (io.panic "reference finalization")]))])]))

;: Compare every requested boundary byte against a separately streamed recurrence.
(define (output-boundaries) : unit
  (let
    [ikm (input-from (buf.str-as-bytes "a\0b"))]
    [prk (prk-from (hkdf.extract (& ikm) (limits)))]
    [info-text : String "public\0info"]
    [info (buf.str-as-bytes (& info-text))]
    [sizes : (Array i64 8) (array 0 1 31 32 33 8128 8159 8160)]
    [j : i64 0]
    (while (< j 8)
      (let
        [length : i64 (array-ref sizes j)]
        [expected
          (match (secret.bytes-new 32)
            [(SecretBytesOk value) value]
            [_ (io.panic "reference storage")])]
        [offset : i64 0]
        [counter : i64 1]
        (match (hkdf.expand (& prk) info length (limits))
          [(HkdfSha256ExpandErr _)
            (test.assert-true false "boundary expansion")]
          [(HkdfSha256ExpandOk output)
            (test.assert-i64-eq
              (hkdf.okm-length (& output))
              length
              "exact boundary length")
            (while (< offset length)
              (let
                [block
                  (reference-block
                    (& prk)
                    (& expected)
                    info
                    (cast counter : u8))]
                [count : i64
                  (if (< (- length offset) 32)
                    (- length offset)
                    32)]
                (match (unsafe
                  (secret.fixed-read-pointer (& block) 0 count))
                  [(SecretReadOk want)
                    (match (unsafe
                      (hkdf.okm-read-pointer (& output) offset count))
                      [(SecretReadOk actual)
                        (test.assert-true
                          (=
                            (unsafe
                              (secret.difference-bits actual want count))
                            (cast 0 : u64))
                          "every output byte and binary counter")]
                      [_ (test.assert-true false "output prefix initialized")])]
                  [_ (test.assert-true false "reference block live")])
                (match (secret.fixed-copy-range!
                  (& block)
                  (secret.Secret32)
                  0
                  (&mut expected)
                  0
                  32)
                  [(SecretOk) unit]
                  [_ (io.panic "reference rotation")])
                (secret.close-fixed block)
                (set! offset (+ offset count)))
              (set! counter (+ counter 1)))
            (test.assert-i64-eq
              (- counter 1)
              (if (= length 0)
                0
                (+ 1 (/ (- length 1) 32)))
              "exact counter range")
            (match (unsafe
              (hkdf.okm-read-pointer (& output) 0 length))
              [(SecretReadOk _) unit]
              [_ (test.assert-true false "live even when empty")])
            (hkdf.close-okm output)])
        (secret.close-bytes expected))
      (set! j (+ j 1)))
    (test.assert-true
      (hkdf.prk-live? (& prk))
      "PRK reusable after independent expansions")
    (hkdf.close-prk prk)
    (secret.close-bytes ikm)))

;: Each individual caller/HMAC limit, zero-block rules and stale input checks.
(define (limit-and-liveness) : unit
  (let
    [ikm (input-from (buf.str-as-bytes "a\0b"))]
    [salt (input-from (buf.str-as-bytes "salt"))]
    [ikm-copy (input-from (buf.str-as-bytes "a\0b"))]
    [salt-copy (input-from (buf.str-as-bytes "salt"))]
    [prk (prk-from (hkdf.extract-secret (& salt) (& ikm) (limits)))]
    [budget (limits)]
    [i : i64 0]
    (while (< i 10)
      (set! budget (limits))
      (cond
        [(= i 0) (set! budget.max-salt-bytes -1)]
        [(= i 1) (set! budget.max-ikm-bytes -1)]
        [(= i 2) (set! budget.max-info-bytes -1)]
        [(= i 3) (set! budget.max-output-bytes -1)]
        [(= i 4) (set! budget.max-output-bytes 8161)]
        [(= i 5) (set! budget.max-extract-work -1)]
        [(= i 6) (set! budget.max-expand-work -1)]
        [(= i 7) (set! budget.hmac-limits (hmac.HmacSha256Limits -1 0))]
        [(= i 8) (set! budget.hmac-limits (hmac.HmacSha256Limits 32 -1))]
        [else
          (set!
            budget.hmac-limits
            (hmac.HmacSha256Limits 32 9223372036854775807))])
      (test.assert-i64-eq
        (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 0 budget))
        1
        "invalid configuration rejects zero")
      (test.assert-i64-eq
        (extract-error (hkdf.extract (& ikm) budget))
        1
        "invalid Extract limits")
      (set! i (+ i 1)))
    (set! budget (limits))
    (set! budget.max-salt-bytes 3)
    (test.assert-i64-eq
      (extract-error (hkdf.extract-secret (& salt) (& ikm) budget))
      2
      "salt cap")
    (test.assert-i64-eq
      (extract-error
        (hkdf.extract-public (buf.str-as-bytes "salt") (& ikm) budget))
      2
      "public salt cap")
    (set! budget (limits))
    (set! budget.max-ikm-bytes 2)
    (test.assert-i64-eq
      (extract-error (hkdf.extract-secret (& salt) (& ikm) budget))
      3
      "IKM cap")
    (set! budget (limits))
    (set! budget.max-extract-work 6)
    (test.assert-i64-eq
      (extract-error (hkdf.extract-secret (& salt) (& ikm) budget))
      4
      "salt plus message work cap")
    (set! budget (limits))
    (set! budget.hmac-limits (hmac.HmacSha256Limits 3 3))
    (test.assert-i64-eq
      (extract-error (hkdf.extract-secret (& salt) (& ikm) budget))
      7
      "HMAC key cap")
    (set! budget (limits))
    (set! budget.hmac-limits (hmac.HmacSha256Limits 4 2))
    (test.assert-i64-eq
      (extract-error (hkdf.extract-secret (& salt) (& ikm) budget))
      7
      "HMAC message cap")
    (set! budget (limits))
    (set! budget.max-info-bytes 0)
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "x") 0 budget))
      2
      "info cap even for zero")
    (set! budget (limits))
    (set! budget.max-output-bytes 31)
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 32 budget))
      3
      "caller output cap")
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") -1 (limits)))
      3
      "negative output")
    (set! budget (limits))
    (set! budget.max-expand-work 33)
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 33 budget))
      4
      "exact work 34 for two blocks")
    (set! budget (limits))
    (set! budget.hmac-limits (hmac.HmacSha256Limits 31 33))
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 1 budget))
      7
      "PRK key cap")
    (set! budget (limits))
    (set! budget.hmac-limits (hmac.HmacSha256Limits 32 1))
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 33 budget))
      7
      "previous block message cap")
    (set! budget.max-expand-work 1)
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 1 budget))
      0
      "one actual block with exact feed and message budgets")
    (set! budget.max-expand-work 0)
    (assert-okm (hkdf.expand (& prk) (buf.str-as-bytes "") 0 budget) "")
    (match (secret.bytes-equal (& ikm) (& ikm-copy))
      [(SecretCompareOk equal)
        (test.assert-true equal "all refusals preserve IKM bytes")]
      [_ (test.assert-true false "IKM remains live")])
    (match (secret.bytes-equal (& salt) (& salt-copy))
      [(SecretCompareOk equal)
        (test.assert-true equal "all refusals preserve salt bytes")]
      [_ (test.assert-true false "salt remains live")])
    (test.assert-true
      (hkdf.prk-live? (& prk))
      "preflight refusals preserve PRK")
    (let
      [stale
        (secret.SecretBytes
          (secret.SecretHandle ikm.handle.storage (+ ikm.handle.generation 1)))]
      (test.assert-i64-eq
        (extract-error (hkdf.extract (& stale) (limits)))
        8
        "stale IKM")
      (test.assert-i64-eq
        (extract-error (hkdf.extract-secret (& stale) (& ikm) (limits)))
        8
        "stale salt")
      (secret.close-bytes stale))
    (secret.nominal-handle-close
      (unsafe
        (deref prk.storage).value.handle))
    (test.assert-i64-eq
      (expand-error (hkdf.expand (& prk) (buf.str-as-bytes "") 0 (limits)))
      6
      "closed PRK rejects zero")
    (hkdf.close-prk prk)
    (secret.close-bytes salt-copy)
    (secret.close-bytes ikm-copy)
    (secret.close-bytes salt)
    (secret.close-bytes ikm)))

;: Read only retained test metadata after transfer; no production accessor added.
(unsafe
  (define (inner-handle [nominal : secret.SecretNominalHandle]) : secret.SecretHandle
    (let
      [words : (Ptr u64)
        (unsafe
          (ptr-cast nominal.storage : (Ptr u64)))]
      (secret.SecretHandle
        (unsafe
          (int->ptr
            (ptr-read (ptr-offset words 2))
            : (MutPtr secret.SecretStorage)))
        (cast
          (unsafe
            (ptr-read (ptr-offset words 3)))
          : i64)))))

;: A full-capacity wipe is observable only in this unsafe test boundary.
(define (assert-wiped [handle : secret.SecretHandle] [capacity : i64]) : unit
  (let
    [data : (MutPtr u8)
      (unsafe
        (secret.storage-data handle.storage))]
    [i : i64 0]
    [bits : u64 (cast 0 : u64)]
    (while (< i capacity)
      (set!
        bits
        (bit-or
          bits
          (cast
            (unsafe
              (ptr-read (ptr-offset data i)))
            : u64)))
      (set! i (+ i 1)))
    (test.assert-true (= bits (cast 0 : u64)) "entire secret capacity wiped")
    (test.assert-true
      (=
        (unsafe
          (secret.storage-header handle.storage)).state
        (secret.state-closed))
      "storage closed")
    (test.assert-true
      (=
        (unsafe
          (secret.storage-header handle.storage)).length
        (cast 0 : u64))
      "initialized length poisoned")))

;: Successful outputs stay live; nested lexical cleanup poisons and wipes once.
(define (owner-cleanup) : unit
  (let
    [empty (input-from (buf.str-as-bytes ""))]
    [zeros-public
      (hex "0000000000000000000000000000000000000000000000000000000000000000")]
    [zeros (input-from (buf.as-bytes (& zeros-public)))]
    [prk (prk-from (hkdf.extract (& empty) (limits)))]
    [zero-prk (prk-from (hkdf.extract (& zeros) (limits)))]
    [nominal : secret.SecretNominalHandle
      (unsafe
        (deref prk.storage).value.handle)]
    [inner : secret.SecretHandle
      (unsafe
        (inner-handle nominal))]
    (match (unsafe
      (hkdf.prk-read-pointer (& zero-prk)))
      [(SecretReadOk a)
        (match (unsafe
          (hkdf.prk-read-pointer (& prk)))
          [(SecretReadOk b)
            (test.assert-false
              (=
                (unsafe
                  (secret.difference-bits a b 32))
                (cast 0 : u64))
              "empty IKM differs from 32 zeros")]
          [_ (test.assert-true false "empty PRK live")])]
      [_ (test.assert-true false "zero IKM PRK live")])
    (let
      [forged
        (hkdf.HkdfSha256Prk (ptr-null : (MutPtr hkdf.HkdfSha256PrkStorage)))]
      (test.assert-i64-eq
        (expand-error (hkdf.expand (& forged) (buf.str-as-bytes "") 0 (limits)))
        6
        "null PRK rejects zero")
      (hkdf.close-prk forged))
    (let
      [stale
        (hkdf.HkdfSha256Prk
          (unsafe
            (ptr-cast
              (secret.secret-runtime-alloc 16)
              : (MutPtr hkdf.HkdfSha256PrkStorage))))]
      (unsafe
        (ptr-write!
          stale.storage
          (hkdf.HkdfSha256PrkStorage
            (secret.SecretNominal
              (secret.SecretNominalHandle
                nominal.storage
                (+ nominal.generation 1))))))
      (test.assert-i64-eq
        (expand-error (hkdf.expand (& stale) (buf.str-as-bytes "") 0 (limits)))
        6
        "stale nominal generation rejects zero")
      (hkdf.close-prk stale))
    (match (hkdf.expand (& prk) (buf.str-as-bytes "") 31 (limits))
      [(HkdfSha256ExpandErr _) (test.assert-true false "cleanup output")]
      [(HkdfSha256ExpandOk output)
        (let
          [handle : secret.SecretHandle
            (unsafe
              (deref output.storage).value.handle)]
          (with
            ([owned output hkdf.close-okm])
            (test.assert-i64-eq
              (hkdf.okm-length (& owned))
              31
              "live ownership transferred"))
          (assert-wiped handle 32))])
    (with
      ([owned prk hkdf.close-prk])
      (test.assert-true
        (hkdf.prk-live? (& owned))
        "PRK stays live until cleanup"))
    (assert-wiped inner 32)
    (test.assert-true
      (=
        (unsafe
          (ptr-read (ptr-cast nominal.storage : (Ptr u64))))
        (secret.state-closed))
      "outer poisoned/closed")
    (unsafe
      (ptr-write! (secret.storage-data inner.storage) (cast 81 : u8)))
    (secret.nominal-handle-close nominal)
    (test.assert-i64-eq
      (cast
        (unsafe
          (ptr-read (secret.storage-data inner.storage)))
        : i64)
      81
      "second cleanup cannot wipe again")
    (unsafe
      (ptr-write! (secret.storage-data inner.storage) (cast 0 : u8)))
    (hkdf.close-prk zero-prk)
    (secret.close-bytes zeros)
    (secret.close-bytes empty)))

;: Corrupted nominal sizes cannot masquerade as exact32 PRKs, even for L=0.
(define (wrong-prk-sizes) : unit
  (let
    [sizes : (Array secret.SecretSize 2)
      (array (secret.Secret16) (secret.Secret64))]
    [i : i64 0]
    (while (< i 2)
      (let
        [size : secret.SecretSize (array-ref sizes i)]
        (match (unsafe
          (secret.transfer-fixed (secret.fixed-zero size) size))
          [(SecretNominalErr _)
            (test.assert-true false "malformed size fixture")]
          [(SecretNominalOk nominal)
            (let
              [storage : (MutPtr hkdf.HkdfSha256PrkStorage)
                (unsafe
                  (ptr-cast
                    (secret.secret-runtime-alloc 16)
                    : (MutPtr hkdf.HkdfSha256PrkStorage)))]
              (unsafe
                (ptr-write! storage (hkdf.HkdfSha256PrkStorage nominal)))
              (let
                [prk (hkdf.HkdfSha256Prk storage)]
                (test.assert-false
                  (hkdf.prk-live? (& prk))
                  "wrong exact PRK length")
                (test.assert-i64-eq
                  (expand-error
                    (hkdf.expand (& prk) (buf.str-as-bytes "") 0 (limits)))
                  6
                  "wrong length rejects zero")
                (hkdf.close-prk prk)))])
        (set! i (+ i 1))))))

;: Previous blocks stay live and distinct until the next finalization completes.
;: All 255 binary counters and 254 full previous retirements are exercised.
(define (rolling-lifecycle) : unit
  (let
    [ikm (input-from (buf.str-as-bytes "key"))]
    [prk (prk-from (hkdf.extract (& ikm) (limits)))]
    [previous : hkdf.HkdfSha256Block (hkdf.HkdfSha256NoBlock)]
    [counter : i64 1]
    [retired : i64 0]
    (match (unsafe
      (hkdf.prk-read-pointer (& prk)))
      [(SecretReadErr _) (test.assert-true false "rolling PRK")]
      [(SecretReadOk key)
        (while (<= counter 255)
          (match (unsafe
            (hkdf.next-block
              key
              (& previous)
              (buf.str-as-bytes "")
              counter
              (hmac.HmacSha256Limits 32 33)))
            [(HmacSha256SecretErr _) (test.assert-true false "rolling block")]
            [(HmacSha256SecretOk current)
              (match (& previous)
                [(HkdfSha256NoBlock)
                  (test.assert-i64-eq counter 1 "only T0 empty")]
                [(HkdfSha256BlockValue prior)
                  (test.assert-i64-eq
                    (secret.fixed-length prior)
                    32
                    "previous survives next finalization")
                  (test.assert-false
                    (= prior.handle.storage current.handle.storage)
                    "distinct current owner")
                  (let
                    [address : u64
                      (unsafe
                        (ptr->int prior.handle.storage))]
                    [old : secret.SecretHandle
                      (secret.SecretHandle
                        (unsafe
                          (int->ptr address : (MutPtr secret.SecretStorage)))
                        prior.handle.generation)]
                    (secret.storage-close old)
                    (assert-wiped old 32)
                    (set! retired (+ retired 1)))])
              (hkdf.close-block previous)
              (set! previous (hkdf.HkdfSha256BlockValue current))])
          (set! counter (+ counter 1)))])
    (test.assert-i64-eq retired 254 "254 full previous retirements")
    (match (& previous)
      [(HkdfSha256BlockValue final)
        (let
          [address : u64
            (unsafe
              (ptr->int final.handle.storage))]
          [old : secret.SecretHandle
            (secret.SecretHandle
              (unsafe
                (int->ptr address : (MutPtr secret.SecretStorage)))
              final.handle.generation)]
          (secret.storage-close old)
          (assert-wiped old 32))]
      [_ (test.assert-true false "final T255 owned")])
    (hkdf.close-block previous)
    (hkdf.close-prk prk)
    (secret.close-bytes ikm)))

;: Force internal HMAC/accounting and partial-output range failures through the
;: audited unsafe helpers; borrowed input owners survive every error.
(define (internal-failures) : unit
  (let
    [ikm (input-from (buf.str-as-bytes "input"))]
    [salt (input-from (buf.str-as-bytes "salt"))]
    [prk (prk-from (hkdf.extract-secret (& salt) (& ikm) (limits)))]
    (match (unsafe
      (secret.bytes-read-pointer (& salt) 0 4))
      [(SecretReadErr _) (test.assert-true false "salt pointer")]
      [(SecretReadOk key)
        (match (unsafe
          (secret.bytes-read-pointer (& ikm) 0 5))
          [(SecretReadErr _) (test.assert-true false "IKM pointer")]
          [(SecretReadOk input)
            (let
              [budget (limits)]
              (set! budget.hmac-limits (hmac.HmacSha256Limits 4 4))
              (test.assert-i64-eq
                (extract-error
                  (unsafe
                    (hkdf.extract-worker key 4 input 5 budget)))
                7
                "terminal HMAC failure cleaned"))])])
    (match (secret.bytes-new 32)
      [(SecretBytesErr _) (test.assert-true false "partial output")]
      [(SecretBytesOk partial)
        (let
          [handle : secret.SecretHandle partial.handle]
          (match (unsafe
            (hkdf.prk-read-pointer (& prk)))
            [(SecretReadErr _) (test.assert-true false "PRK for partial")]
            [(SecretReadOk key)
              (match (unsafe
                (hkdf.expand-into!
                  key
                  (buf.str-as-bytes "")
                  64
                  (hkdf.HkdfSha256Plan 2 34)
                  (hmac.HmacSha256Limits 32 33)
                  (&mut partial)))
                [(HkdfSha256Err (HkdfSha256SecretError _)) unit]
                [_ (test.assert-true false "second range failure")])])
          (test.assert-i64-eq
            (secret.bytes-length (& partial))
            32
            "failed copy keeps initialized prefix")
          (secret.close-bytes partial)
          (assert-wiped handle 32))])
    (test.assert-i64-eq (secret.bytes-length (& ikm)) 5 "failure borrows IKM")
    (test.assert-i64-eq (secret.bytes-length (& salt)) 4 "failure borrows salt")
    (test.assert-true (hkdf.prk-live? (& prk)) "failure borrows PRK")
    (hkdf.close-prk prk)
    (secret.close-bytes salt)
    (secret.close-bytes ikm)))

(cfg compile-profile (import stdlib.profile))

;: Exact allocation equations witness zero/one/two/254/255 HMAC finalizations.
;: Rejection allocates nothing. Counter activity has a positive allocation control.
(cfg
  compile-profile
  (define (allocation-contract) : unit
    (let
      [ikm (input-from (buf.str-as-bytes "key"))]
      [prk (prk-from (hkdf.extract (& ikm) (limits)))]
      [before-state : i64 (profile.alloc-total)]
      [state (hmac.new (& ikm) (hmac.HmacSha256Limits 32 33))]
      [state-bytes : i64 (- (profile.alloc-total) before-state)]
      [info-text : String ""]
      [info (buf.str-as-bytes (& info-text))]
      [counts : (Array i64 5) (array 0 1 2 254 255)]
      [i : i64 0]
      (hmac.close-new-result state)
      (test.assert-true (> state-bytes 0) "HMAC allocation positive control")
      (while (< i 5)
        (let
          [n : i64 (array-ref counts i)]
          [before : i64 (profile.alloc-total)]
          [result (hkdf.expand (& prk) info (* n 32) (limits))]
          [allocated : i64 (- (profile.alloc-total) before)]
          (test.assert-i64-eq
            allocated
            (+ 48 (+ (* n 32) (* n (+ 64 state-bytes))))
            "exact per-block state/result and output allocations")
          (test.assert-true (> allocated 0) "allocation counters active")
          (match (& result)
            [(HkdfSha256ExpandOk _) unit]
            [_ (test.assert-true false "profile expansion succeeds")])
          (hkdf.close-expand-result result))
        (set! i (+ i 1)))
      (let
        [before : i64 (profile.alloc-total)]
        [kind : i64 (expand-error (hkdf.expand (& prk) info 8161 (limits)))]
        (test.assert-i64-eq kind 3 "max rejection")
        (test.assert-i64-eq
          (- (profile.alloc-total) before)
          0
          "8161 zero allocations/finalizations"))
      (hkdf.close-prk prk)
      (secret.close-bytes ikm))))

(test hkdf-rfc5869 (rfc-vectors))

(test hkdf-maximum (reject-8161))

(test hkdf-work-planning (work-planning))

(test hkdf-output-boundaries (output-boundaries))

(test hkdf-limits (limit-and-liveness))

(test hkdf-owner-cleanup (owner-cleanup))

(test hkdf-rolling-cleanup (rolling-lifecycle))

(test hkdf-internal-failures (internal-failures))

(test hkdf-wrong-prk-sizes (wrong-prk-sizes))