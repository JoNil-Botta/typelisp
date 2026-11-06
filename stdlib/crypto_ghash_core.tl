;# Internal SP 800-38D GHASH, exclusively for AES-GCM.
;#
;# Unsafe entry points require validated disjoint ranges. Secret state remains
;# in fixed local scratch, wiped with crypto_secret's volatile word stores.
;# Every multiplication executes two public 64-step loops, most significant
;# bit first, with masked reduction by x^128+x^7+x^2+x+1. No keyed hash API.
;# Compiler spill slots retain secret-derived copies outside explicit scratch;
;# they are outside the wipe guarantee, including at default release opt2.
;# The enclosing GCM operation reclaims its retired tree at exit on every
;# structured path; this best-effort mechanism does not certify erasure.
(import stdlib.crypto_secret as secret)

;: High limb of the public reflected reduction polynomial for Algorithm 1.
;: The low limb is zero; this names x^128+x^7+x^2+x+1 in GHASH bit order.
(define (reduction-high) : u64
  (cast 0xe100000000000000 : u64))

;: Regression work count only; no secret values escape the production path.
(cfg
  test
  (define multiply-steps : i64
    0))

;: Load up to eight public-count bytes in specification big-endian order.
(unsafe
  (define (load-be [source : (Ptr u8)] [count : i64]) : u64
    (let
      [value : u64 (cast 0 : u64)]
      [index : i64 0]
      (while (< index count)
        (set!
          value
          (bit-or
            (shl value (cast 8 : u64))
            (cast
              (unsafe
                (ptr-read (ptr-offset source index)))
              : u64)))
        (set! index (+ index 1)))
      (while (< index 8)
        (set! value (shl value (cast 8 : u64)))
        (set! index (+ index 1)))
      value)))

;: Store one full big-endian limb at an already validated destination.
(unsafe
  (define (store-be! [destination : (MutPtr u8)] [value : u64]) : unit
    (let
      [index : i64 0]
      [remaining : u64 value]
      (while (< index 8)
        (unsafe
          (ptr-write!
            (ptr-offset destination index)
            (cast (shr remaining (cast 56 : u64)) : u8)))
        (set! remaining (shl remaining (cast 8 : u64)))
        (set! index (+ index 1))))))

;: Multiply a two-limb accumulator by H, Algorithm 1. Scratch contains
;: X[0..1], V[2..3], Z[4..5]; addresses depend only on public half/step.
(unsafe
  (define (multiply! [state : (MutPtr u64)] [h : (Ptr u8)]) : unit
    (let
      [scratch : (Array u64 6) (make-array u64 6)]
      [work : (MutPtr u64)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)))]
      [half : i64 0]
      (unsafe
        (ptr-write! work (ptr-read state))
        (ptr-write! (ptr-offset work 1) (ptr-read (ptr-offset state 1)))
        (ptr-write! (ptr-offset work 2) (load-be h 8))
        (ptr-write! (ptr-offset work 3) (load-be (ptr-offset h 8) 8)))
      (while (< half 2)
        (let
          [step : i64 0]
          (while (< step 64)
            (cfg test (set! multiply-steps (+ multiply-steps 1)) unit)
            (let
              [mask : u64
                (secret.mask-u64
                  (shr
                    (unsafe
                      (ptr-read (ptr-offset work half)))
                    (cast 63 : u64)))]
              [high : u64
                (unsafe
                  (ptr-read (ptr-offset work 2)))]
              [low : u64
                (unsafe
                  (ptr-read (ptr-offset work 3)))]
              (unsafe
                (ptr-write!
                  (ptr-offset work half)
                  (shl (ptr-read (ptr-offset work half)) (cast 1 : u64))))
              (unsafe
                (ptr-write!
                  (ptr-offset work 4)
                  (bit-xor (ptr-read (ptr-offset work 4)) (bit-and high mask)))
                (ptr-write!
                  (ptr-offset work 5)
                  (bit-xor (ptr-read (ptr-offset work 5)) (bit-and low mask)))
                (ptr-write!
                  (ptr-offset work 2)
                  (bit-xor
                    (shr high (cast 1 : u64))
                    (bit-and (reduction-high) (secret.mask-u64 low))))
                (ptr-write!
                  (ptr-offset work 3)
                  (bit-or (shr low (cast 1 : u64)) (shl high (cast 63 : u64))))))
            (set! step (+ step 1))))
        (set! half (+ half 1)))
      (unsafe
        (ptr-write! state (ptr-read (ptr-offset work 4)))
        (ptr-write! (ptr-offset state 1) (ptr-read (ptr-offset work 5)))
        (secret.wipe-words! work 6)))))

;: Absorb one block or its public-length zero-padded tail, 1..16 bytes.
(unsafe
  (define (absorb!
    [state : (MutPtr u64)]
    [h : (Ptr u8)]
    [source : (Ptr u8)]
    [count : i64]) : unit
    (let
      [first : i64
        (if (< count 8)
          count
          8)]
      (unsafe
        (ptr-write! state (bit-xor (ptr-read state) (load-be source first)))
        (when
          (> count 8)
          (ptr-write!
            (ptr-offset state 1)
            (bit-xor
              (ptr-read (ptr-offset state 1))
              (load-be (ptr-offset source 8) (- count 8)))))
        (multiply! state h)))))

;: Stream one public-length region, including its separate zero padding.
(unsafe
  (define (region!
    [state : (MutPtr u64)]
    [h : (Ptr u8)]
    [source : (Ptr u8)]
    [length : i64]) : unit
    (let
      [offset : i64 0]
      (while (<= 16 (- length offset))
        (unsafe
          (absorb! state h (ptr-offset source offset) 16))
        (set! offset (+ offset 16)))
      (when
        (< offset length)
        (unsafe
          (absorb! state h (ptr-offset source offset) (- length offset)))))))

;: XOR GHASH(A || pad || C || pad || lengths) into the secret AES(J0)
;: destination. Input byte-to-bit conversions were checked by GCM preflight.
(unsafe
  (define (authenticate!
    [h : (Ptr u8)]
    [aad : (Ptr u8)]
    [aad-length : i64]
    [ciphertext : (Ptr u8)]
    [ciphertext-length : i64]
    [destination : (MutPtr u8)]) : unit
    (let
      [scratch : (Array u64 4) (make-array u64 4)]
      [state : (MutPtr u64)
        (unsafe
          (ptr-cast (ptr-addr-of scratch) : (MutPtr u64)))]
      [encoded : (MutPtr u8)
        (unsafe
          (ptr-cast (ptr-offset state 2) : (MutPtr u8)))]
      [index : i64 0]
      (unsafe
        (region! state h aad aad-length)
        (region! state h ciphertext ciphertext-length)
        (ptr-write!
          state
          (bit-xor (ptr-read state) (* (cast aad-length : u64) (cast 8 : u64))))
        (ptr-write!
          (ptr-offset state 1)
          (bit-xor
            (ptr-read (ptr-offset state 1))
            (* (cast ciphertext-length : u64) (cast 8 : u64))))
        (multiply! state h)
        (store-be! encoded (ptr-read state))
        (store-be! (ptr-offset encoded 8) (ptr-read (ptr-offset state 1))))
      (while (< index 16)
        (unsafe
          (ptr-write!
            (ptr-offset destination index)
            (bit-xor
              (ptr-read (ptr-offset destination index))
              (ptr-read (ptr-offset encoded index)))))
        (set! index (+ index 1)))
      (unsafe
        (secret.wipe-words! state 4)))))