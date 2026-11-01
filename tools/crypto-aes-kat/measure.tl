;; Local raw measurements: build opt1/opt2 without cfg test instrumentation.
(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)
(import stdlib.profile)
(import stdlib.io)
(import stdlib.test)

(define (measure-128) : unit
  (let
    [setup-ticks : i64 0]
    [index : i64 0]
    (while (< index 256)
      (let
        [key : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
        [start : i64 (profile.now-ticks)]
        (match (aes.new-128 key)
          [(Aes128Ok schedule)
            (set! setup-ticks (+ setup-ticks (- (profile.now-ticks) start)))
            (aes.close-128 schedule)]
          [_ (test.assert-true false "schedule construction")]))
      (set! index (+ index 1)))
    (let
      [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
        [(Aes128Ok schedule)
          (let
            [before : i64 (profile.alloc-total)]
            [start : i64 (profile.now-ticks)]
            [block : i64 0]
            (while (< block 4096)
              (match (aes.encrypt-128!
                (& schedule)
                (& source)
                (&mut destination))
                [(AesOk) unit]
                [_ (test.assert-true false "block encryption")])
              (set! block (+ block 1)))
            (let
              [ticks : i64 (- (profile.now-ticks) start)]
              [allocated : i64 (- (profile.alloc-total) before)]
              (test.assert-i64-eq allocated 0 "steady-state allocation")
              (io.println
                "AES-128 setup_count=256 setup_ticks={} block_count=4096 block_ticks={} ticks_per_second={} block_allocated_bytes={}"
                setup-ticks
                ticks
                (profile.ticks-per-second)
                allocated)))
          (aes.close-128 schedule)]
        [_ (test.assert-true false "schedule construction")])
      (secret.close-fixed source)
      (secret.close-fixed destination))))

(define (measure-256) : unit
  (let
    [setup-ticks : i64 0]
    [index : i64 0]
    (while (< index 256)
      (let
        [key : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
        [start : i64 (profile.now-ticks)]
        (match (aes.new-256 key)
          [(Aes256Ok schedule)
            (set! setup-ticks (+ setup-ticks (- (profile.now-ticks) start)))
            (aes.close-256 schedule)]
          [_ (test.assert-true false "schedule construction")]))
      (set! index (+ index 1)))
    (let
      [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
      (match (aes.new-256 (secret.fixed-zero (secret.Secret32)))
        [(Aes256Ok schedule)
          (let
            [before : i64 (profile.alloc-total)]
            [start : i64 (profile.now-ticks)]
            [block : i64 0]
            (while (< block 4096)
              (match (aes.encrypt-256!
                (& schedule)
                (& source)
                (&mut destination))
                [(AesOk) unit]
                [_ (test.assert-true false "block encryption")])
              (set! block (+ block 1)))
            (let
              [ticks : i64 (- (profile.now-ticks) start)]
              [allocated : i64 (- (profile.alloc-total) before)]
              (test.assert-i64-eq allocated 0 "steady-state allocation")
              (io.println
                "AES-256 setup_count=256 setup_ticks={} block_count=4096 block_ticks={} ticks_per_second={} block_allocated_bytes={}"
                setup-ticks
                ticks
                (profile.ticks-per-second)
                allocated)))
          (aes.close-256 schedule)]
        [_ (test.assert-true false "schedule construction")])
      (secret.close-fixed source)
      (secret.close-fixed destination))))

(define (main) : i64
  (measure-128)
  (measure-256)
  42)