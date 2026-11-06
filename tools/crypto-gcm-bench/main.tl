; Reproducible native report for the admitted portable implementation.
; Timings are observations, never thresholds or a variant-selection rule.
(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)
(import stdlib.byte_buf as buf)
(import stdlib.profile)
(import stdlib.io)
(import stdlib.string)
(cfg test (import stdlib.crypto_aes_core as aes))
(cfg test (import stdlib.crypto_ghash_core as ghash))

(define (report
  [name : String]
  [bytes : i64]
  [rounds : i64]
  [ticks : i64]
  [allocated : i64]
  [checksum : i64]) : unit
  (let
    [frequency : i64 (profile.ticks-per-second)]
    (when
      (or (<= ticks 0) (<= frequency 0))
      (io.panic "GCM benchmark clock unavailable"))
    (io.println
      "gcm-bench mode={} bytes={} rounds={} ticks={} frequency={} ns/op={} bytes/sec={} allocated/op={} checksum={}"
      name
      bytes
      rounds
      ticks
      frequency
      (/ (* (/ (* ticks 1000000) frequency) 1000) rounds)
      (/ (* (* bytes rounds) frequency) ticks)
      (/ allocated rounds)
      checksum)))

(define (setup) : unit
  (let
    [rounds : i64 256]
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    [start : i64 (profile.now-ticks)]
    (while (< index rounds)
      (match (gcm.new (secret.fixed-zero (secret.Secret16)))
        [(GcmKeyOk key) (gcm.close key)]
        [_ (io.panic "GCM benchmark setup")])
      (set! index (+ index 1)))
    (let
      [elapsed : i64 (- (profile.now-ticks) start)]
      [allocated : i64 (- (profile.alloc-total) before)]
      (report "setup-including-key-import" 0 rounds elapsed allocated index))))

(define (payload [length : i64] [decrypt : bool]) : unit
  (let
    [plain : buf.ByteBuf (buf.with-capacity length)]
    [aad : String "aad!!"]
    [nonce : gcm.GcmNonce (gcm.GcmNonce (make-array u8 12))]
    [rounds : i64
      (if (= length 16384)
        32
        512)]
    (set! plain.len length)
    (match (gcm.new (secret.fixed-zero (secret.Secret16)))
      [(GcmKeyOk key)
        (with
          ([owner key gcm.close])
          (match (gcm.seal
            (& owner)
            (& nonce)
            (buf.str-as-bytes (& aad))
            (buf.as-bytes (& plain)))
            [(GcmSealOk reference)
              (let
                [index : i64 0]
                [checksum : i64 0]
                [before : i64 (profile.alloc-total)]
                [start : i64 (profile.now-ticks)]
                (while (< index rounds)
                  ; This benchmark deliberately repeats public test-vector
                  ; material. Protocol callers must never reuse a nonce.
                  (if decrypt
                    (match (gcm.open
                      (& owner)
                      (& nonce)
                      (buf.str-as-bytes (& aad))
                      (buf.as-bytes (& reference.ciphertext))
                      (& reference.tag))
                      [(GcmOpenOk output)
                        (set! checksum (+ checksum (buf.len (& output))))]
                      [_ (io.panic "GCM benchmark open")])
                    (match (gcm.seal
                      (& owner)
                      (& nonce)
                      (buf.str-as-bytes (& aad))
                      (buf.as-bytes (& plain)))
                      [(GcmSealOk output)
                        (set!
                          checksum
                          (+
                            checksum
                            (cast (array-ref output.tag.octets 15) : i64)))]
                      [_ (io.panic "GCM benchmark seal")]))
                  (set! index (+ index 1)))
                (let
                  [elapsed : i64 (- (profile.now-ticks) start)]
                  [allocated : i64 (- (profile.alloc-total) before)]
                  (report
                    (if decrypt
                      "open"
                      "seal")
                    length
                    rounds
                    elapsed
                    allocated
                    checksum)))]
            [_ (io.panic "GCM benchmark reference")]))]
      [_ (io.panic "GCM benchmark context")])))

;: Counts instrumented source sites separately from uninstrumented timings.
(cfg
  test
  (define (work-report) : unit
    (let
      [plain : buf.ByteBuf (buf.with-capacity 16384)]
      [aad : String "aad!!"]
      [nonce : gcm.GcmNonce (gcm.GcmNonce (make-array u8 12))]
      [before : i64 aes.source-work]
      (set! plain.len 16384)
      (match (gcm.new (secret.fixed-zero (secret.Secret16)))
        [(GcmKeyOk key)
          (io.println "gcm-work setup-aes-units={}" (- aes.source-work before))
          (let
            [aes-before : i64 aes.source-work]
            [ghash-before : i64 ghash.multiply-steps]
            (match (gcm.seal
              (& key)
              (& nonce)
              (buf.str-as-bytes (& aad))
              (buf.as-bytes (& plain)))
              [(GcmSealOk sealed)
                (io.println
                  "gcm-work seal-bytes=16384 aes-units={} ghash-bit-steps={}"
                  (- aes.source-work aes-before)
                  (- ghash.multiply-steps ghash-before))
                (let
                  [aes-open : i64 aes.source-work]
                  [ghash-open : i64 ghash.multiply-steps]
                  (match (gcm.open
                    (& key)
                    (& nonce)
                    (buf.str-as-bytes (& aad))
                    (buf.as-bytes (& sealed.ciphertext))
                    (& sealed.tag))
                    [(GcmOpenOk _) unit]
                    [_ (io.panic "GCM work open")])
                  (io.println
                    "gcm-work open-bytes=16384 aes-units={} ghash-bit-steps={}"
                    (- aes.source-work aes-open)
                    (- ghash.multiply-steps ghash-open)))]
              [_ (io.panic "GCM work seal")]))
          (gcm.close key)]
        [_ (io.panic "GCM work setup")]))))

(define (main) : i64
  (let
    [mode : String
      (if (= (io.arg-count) 2)
        (io.arg 1)
        "all")]
    (cond
      [(string.eq mode "setup") (setup)]
      [(string.eq mode "seal16") (payload 16 false)]
      [(string.eq mode "open16") (payload 16 true)]
      [(string.eq mode "seal16384") (payload 16384 false)]
      [(string.eq mode "open16384") (payload 16384 true)]
      [(string.eq mode "work")
        (cfg
          test
          (work-report)
          (io.panic "GCM work requires test instrumentation"))]
      [(string.eq mode "all")
        (setup)
        (payload 16 false)
        (payload 16 true)
        (payload 16384 false)
        (payload 16384 true)]
      [else (io.panic "unknown GCM benchmark mode")])
    0))