(cfg test (import stdlib.crypto_aes_core as aes))
(cfg test (import stdlib.crypto_secret as secret))
(cfg test (import stdlib.test))
(cfg test (import stdlib.io))

;: Paired-key/state bit changes exercise the instrumented production helpers.
;: Only public work counts escape; no key, schedule or output byte is returned.
(cfg
  test
  (define (paired-work [wide : bool] [bit : i64] [state-bit : bool]) : (Tuple
      i64
      i64)
    (let
      [key : secret.SecretFixed
        (secret.fixed-zero
          (if wide
            (secret.Secret32)
            (secret.Secret16)))]
      [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      [setup : i64 0]
      [block : i64 0]
      (when
        (>= bit 0)
        (let
          [storage : (MutPtr secret.SecretStorage)
            (if state-bit
              source.handle.storage
              key.handle.storage)]
          [data : (MutPtr u8)
            (unsafe
              (secret.storage-data storage))]
          (unsafe
            (ptr-write!
              (ptr-offset data (/ bit 8))
              (shl (cast 1 : u8) (cast (% bit 8) : u64))))))
      (let
        [before : i64 aes.source-work]
        (if wide
          (match (aes.new-256 key)
            [(Aes256Ok schedule)
              (set! setup (- aes.source-work before))
              (let
                [before-block : i64 aes.source-work]
                (match (aes.encrypt-256!
                  (& schedule)
                  (& source)
                  (&mut destination))
                  [(AesOk) unit]
                  [_ (test.assert-true false "AES-256 paired block")])
                (set! block (- aes.source-work before-block)))
              (aes.close-256 schedule)]
            [_ (test.assert-true false "AES-256 paired setup")])
          (match (aes.new-128 key)
            [(Aes128Ok schedule)
              (set! setup (- aes.source-work before))
              (let
                [before-block : i64 aes.source-work]
                (match (aes.encrypt-128!
                  (& schedule)
                  (& source)
                  (&mut destination))
                  [(AesOk) unit]
                  [_ (test.assert-true false "AES-128 paired block")])
                (set! block (- aes.source-work before-block)))
              (aes.close-128 schedule)]
            [_ (test.assert-true false "AES-128 paired setup")])))
      (secret.close-fixed source)
      (secret.close-fixed destination)
      (tuple setup block))))

(cfg
  test
  (define (check-pairs [wide : bool]) : unit
    (let
      [baseline : (Tuple i64 i64) (paired-work wide -1 false)]
      [key-bits : (Array i64 3)
        (array
          0
          (if wide
            128
            64)
          (if wide
            255
            127))]
      [state-bits : (Array i64 3) (array 0 64 127)]
      [index : i64 0]
      (while (< index 3)
        (let
          [key-pair : (Tuple i64 i64)
            (paired-work wide (array-ref key-bits index) false)]
          [state-pair : (Tuple i64 i64)
            (paired-work wide (array-ref state-bits index) true)]
          (test.assert-i64-eq
            (tuple-ref baseline 0)
            (tuple-ref key-pair 0)
            "key bit setup work")
          (test.assert-i64-eq
            (tuple-ref baseline 1)
            (tuple-ref key-pair 1)
            "key bit block work")
          (test.assert-i64-eq
            (tuple-ref baseline 0)
            (tuple-ref state-pair 0)
            "state bit setup work")
          (test.assert-i64-eq
            (tuple-ref baseline 1)
            (tuple-ref state-pair 1)
            "state bit block work"))
        (set! index (+ index 1)))
      (test.assert-i64-eq
        (tuple-ref baseline 0)
        (if wide
          6884
          5352)
        "complete expansion work")
      (test.assert-i64-eq
        (tuple-ref baseline 1)
        (if wide
          8381
          6073)
        "complete cipher work")
      (io.println
        "AES-{} instrumented source work: setup={} block={}"
        (if wide
          256
          128)
        (tuple-ref baseline 0)
        (tuple-ref baseline 1)))))

(cfg
  test
  (test
    aes-paired-source-work
    (begin
      (check-pairs false)
      (check-pairs true))))