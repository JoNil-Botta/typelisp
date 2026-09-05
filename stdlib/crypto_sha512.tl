;# Streaming SHA-512 message digests.
;#
;# This module implements FIPS 180-4 SHA-512 over exact borrowed byte views.
;# `Sha512State` retains at most one 128-byte partial block, and `update!` does
;# not allocate or depend on host byte order. The checked high/low byte count
;# admits exactly the SHA-512 message domain below 2^128 bits.
;#
;# Digests are ordinary public 64-byte values. Callers hashing secret-derived
;# material can use unsafe scoped raw-source/exact-sink adapters and explicitly
;# consume and wipe a state or digest; those helpers do not make every public
;# hash cleanup-owning. Compression scratch is wiped with volatile stores before
;# it leaves scope. This is a narrow erasure seam, not a side-channel or
;# whole-machine erasure claim.
;#
;# Usage: `(import stdlib.crypto_sha512)`
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (import stdlib.crypto_sha512)
;# (define (main) : i64
;#   (let
;#     [text : String "abc"]
;#     [state : crypto_sha512.Sha512State (crypto_sha512.new)]
;#     (match
;#       (crypto_sha512.update!
;#         (&mut state)
;#         (byte_buf.str-as-bytes (& text)))
;#       [(crypto_sha512.Sha512UpdateOk)
;#         (match (crypto_sha512.finalize! (&mut state))
;#           [(crypto_sha512.Sha512FinalizeOk digest)
;#             (if (= (string-length (crypto_sha512.to-hex (& digest))) 128)
;#               42
;#               1)]
;#           [(crypto_sha512.Sha512FinalizeErr _) 1])]
;#       [(crypto_sha512.Sha512UpdateErr _) 1])))
;# ```
(import stdlib.byte_buf)
(import stdlib.string)

;: Stable SHA-512 update/finalization failures. Lifecycle misuse shares one
;: `Sha512Finalized` variant and never exposes message or chaining bytes.
(defenum Sha512Error
  (Sha512Finalized)
  (Sha512MessageTooLong u64 u64 u64)
  (Sha512InvalidSource)
  (Sha512InvalidSourceLength i64)
  (Sha512InvalidOutput)
  (Sha512InvalidOutputLength i64)
  (Sha512InvalidState))

;: Checked 128-bit byte count represented without a host `u128`.
(defstruct Sha512Length
  (high u64)
  (low u64))

;: Result of adding public input length to a SHA-512 byte count.
(defenum Sha512LengthResult
  (Sha512LengthOk Sha512Length)
  (Sha512LengthErr Sha512Error))

;: Incremental SHA-512 state. Construct with `new` and mutate through
;: `update!`/`finalize!`; direct aggregate construction is not a valid state.
(defstruct Sha512State
  (words (Array u64 8))
  (block (Array u8 128))
  (block-length i64)
  (byte-length-high u64)
  (byte-length-low u64)
  (finalized bool))

;: Exact public SHA-512 digest bytes in network order.
(defstruct Sha512Digest
  (octets (Array u8 64)))

;: Result of extending a streaming SHA-512 state.
(defenum Sha512UpdateResult
  (Sha512UpdateOk)
  (Sha512UpdateErr Sha512Error))

;: Result of finalizing a SHA-512 state.
(defenum Sha512FinalizeResult
  (Sha512FinalizeOk Sha512Digest)
  (Sha512FinalizeErr Sha512Error))

;: Result of consuming a state into caller-owned exact 64-byte storage.
(defenum Sha512FinalizeIntoResult
  (Sha512FinalizeIntoOk)
  (Sha512FinalizeIntoErr Sha512Error))

;: Largest permitted high half of the byte count. Together with an all-one
;: low half this is 2^125 - 1 bytes, the exact FIPS `< 2^128`-bit domain.
(define (max-byte-length-high) : u64
  0x1fffffffffffffff)

;: Add one nonnegative public byte count without wrapping the FIPS domain.
(define (length-add [high : u64] [low : u64] [additional : u64]) : Sha512LengthResult
  (let
    [next-low : u64 (+ low additional)]
    [carry : u64
      (if (< next-low low)
        (cast 1 : u64)
        (cast 0 : u64))]
    [next-high : u64 (+ high carry)]
    (if (or
      (< next-high high)
      (> high (max-byte-length-high))
      (> next-high (max-byte-length-high)))
      (Sha512LengthErr (Sha512MessageTooLong high low additional))
      (Sha512LengthOk (Sha512Length next-high next-low)))))

;: Construct the FIPS 180-4 SHA-512 initial state.
(define (new) : Sha512State
  (Sha512State
    (array
      0x6a09e667f3bcc908
      0xbb67ae8584caa73b
      0x3c6ef372fe94f82b
      0xa54ff53a5f1d36f1
      0x510e527fade682d1
      0x9b05688c2b3e6c1f
      0x1f83d9abfb41bd6b
      0x5be0cd19137e2179)
    (init)
    0
    (cast 0 : u64)
    (cast 0 : u64)
    false))

;: Rotate one 64-bit word right by a checked nonzero count below 64.
(define (rotate-right [value : u64] [count : i64]) : u64
  (bit-or (shr value (cast count : u64)) (shl value (cast (- 64 count) : u64))))

;: SHA-512 choose function.
(define (choose [x : u64] [y : u64] [z : u64]) : u64
  (bit-xor (bit-and x y) (bit-and (bit-not x) z)))

;: SHA-512 majority function.
(define (majority [x : u64] [y : u64] [z : u64]) : u64
  (bit-xor (bit-and x y) (bit-and x z) (bit-and y z)))

;: SHA-512 uppercase sigma zero.
(define (sigma-big-zero [value : u64]) : u64
  (bit-xor
    (rotate-right value 28)
    (rotate-right value 34)
    (rotate-right value 39)))

;: SHA-512 uppercase sigma one.
(define (sigma-big-one [value : u64]) : u64
  (bit-xor
    (rotate-right value 14)
    (rotate-right value 18)
    (rotate-right value 41)))

;: SHA-512 lowercase sigma zero.
(define (sigma-small-zero [value : u64]) : u64
  (bit-xor
    (rotate-right value 1)
    (rotate-right value 8)
    (shr value (cast 7 : u64))))

;: SHA-512 lowercase sigma one.
(define (sigma-small-one [value : u64]) : u64
  (bit-xor
    (rotate-right value 19)
    (rotate-right value 61)
    (shr value (cast 6 : u64))))

;: Load one network-order word from a caller-validated block offset.
(define (load-word-be [block : (& block (Array u8 128))] [offset : i64]) : u64
  (bit-or
    (shl (cast (array-ref block offset) : u64) (cast 56 : u64))
    (shl (cast (array-ref block (+ offset 1)) : u64) (cast 48 : u64))
    (shl (cast (array-ref block (+ offset 2)) : u64) (cast 40 : u64))
    (shl (cast (array-ref block (+ offset 3)) : u64) (cast 32 : u64))
    (shl (cast (array-ref block (+ offset 4)) : u64) (cast 24 : u64))
    (shl (cast (array-ref block (+ offset 5)) : u64) (cast 16 : u64))
    (shl (cast (array-ref block (+ offset 6)) : u64) (cast 8 : u64))
    (cast (array-ref block (+ offset 7)) : u64)))

;: Store one word in network order in a caller-validated block range.
(define (store-block-word-be!
  [block : (&mut block (Array u8 128))]
  [offset : i64]
  [value : u64]) : unit
  (let
    [index : i64 0]
    (while (< index 8)
      (let
        [shift : i64 (- 56 (* index 8))]
        (begin
          (set!
            (array-ref block (+ offset index))
            (cast
              (bit-and (shr value (cast shift : u64)) (cast 255 : u64))
              : u8))
          (set! index (+ index 1)))))))

;: Store one word in network order through an audited caller-owned sink.
(unsafe
  (define (store-pointer-word-be!
    [output : (MutPtr u8)]
    [offset : i64]
    [value : u64]) : unit
    (let
      [index : i64 0]
      (while (< index 8)
        (let
          [shift : i64 (- 56 (* index 8))]
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset output (+ offset index))
                (cast
                  (bit-and (shr value (cast shift : u64)) (cast 255 : u64))
                  : u8)))
            (set! index (+ index 1))))))))

;: Encode the checked 128-bit bit count into the last sixteen block bytes.
(define (write-bit-length!
  [block : (&mut block (Array u8 128))]
  [byte-high : u64]
  [byte-low : u64]) : unit
  (let
    [bit-high : u64
      (bit-or (shl byte-high (cast 3 : u64)) (shr byte-low (cast 61 : u64)))]
    [bit-low : u64 (shl byte-low (cast 3 : u64))]
    (begin
      (store-block-word-be! block 112 bit-high)
      (store-block-word-be! block 120 bit-low))))

;: Volatile-wipe a completed compression schedule in its owning frame.
(unsafe
  (define (wipe-schedule-pointer! [data : (MutPtr u64)]) : unit
    (let
      [index : i64 0]
      (while (< index 80)
        (begin
          (unsafe
            (volatile-store! (ptr-offset data index) (cast 0 : u64)))
          (set! index (+ index 1)))))))

;: Compress the complete block currently stored in `state`.
(define (compress! [state : (&mut state Sha512State)]) : unit
  (let
    [constants : (Array u64 80)
      (array
        0x428a2f98d728ae22
        0x7137449123ef65cd
        0xb5c0fbcfec4d3b2f
        0xe9b5dba58189dbbc
        0x3956c25bf348b538
        0x59f111f1b605d019
        0x923f82a4af194f9b
        0xab1c5ed5da6d8118
        0xd807aa98a3030242
        0x12835b0145706fbe
        0x243185be4ee4b28c
        0x550c7dc3d5ffb4e2
        0x72be5d74f27b896f
        0x80deb1fe3b1696b1
        0x9bdc06a725c71235
        0xc19bf174cf692694
        0xe49b69c19ef14ad2
        0xefbe4786384f25e3
        0x0fc19dc68b8cd5b5
        0x240ca1cc77ac9c65
        0x2de92c6f592b0275
        0x4a7484aa6ea6e483
        0x5cb0a9dcbd41fbd4
        0x76f988da831153b5
        0x983e5152ee66dfab
        0xa831c66d2db43210
        0xb00327c898fb213f
        0xbf597fc7beef0ee4
        0xc6e00bf33da88fc2
        0xd5a79147930aa725
        0x06ca6351e003826f
        0x142929670a0e6e70
        0x27b70a8546d22ffc
        0x2e1b21385c26c926
        0x4d2c6dfc5ac42aed
        0x53380d139d95b3df
        0x650a73548baf63de
        0x766a0abb3c77b2a8
        0x81c2c92e47edaee6
        0x92722c851482353b
        0xa2bfe8a14cf10364
        0xa81a664bbc423001
        0xc24b8b70d0f89791
        0xc76c51a30654be30
        0xd192e819d6ef5218
        0xd69906245565a910
        0xf40e35855771202a
        0x106aa07032bbd1b8
        0x19a4c116b8d2d0c8
        0x1e376c085141ab53
        0x2748774cdf8eeb99
        0x34b0bcb5e19b48a8
        0x391c0cb3c5c95a63
        0x4ed8aa4ae3418acb
        0x5b9cca4f7763e373
        0x682e6ff3d6b2b8a3
        0x748f82ee5defb2fc
        0x78a5636f43172f60
        0x84c87814a1f0ab72
        0x8cc702081a6439ec
        0x90befffa23631e28
        0xa4506cebde82bde9
        0xbef9a3f7b2c67915
        0xc67178f2e372532b
        0xca273eceea26619c
        0xd186b8c721c0c207
        0xeada7dd6cde0eb1e
        0xf57d4f7fee6ed178
        0x06f067aa72176fba
        0x0a637dc5a2c898a6
        0x113f9804bef90dae
        0x1b710b35131c471b
        0x28db77f523047d84
        0x32caab7b40c72493
        0x3c9ebe0a15c9bebc
        0x431d67c49c100d4c
        0x4cc5d4becb3e42b6
        0x597f299cfc657e2a
        0x5fcb6fab3ad6faec
        0x6c44198c4a475817)]
    [schedule : (Array u64 80) (init)]
    [index : i64 0]
    (begin
      (while (< index 16)
        (begin
          (set!
            (array-ref schedule index)
            (load-word-be (& state.block) (* index 8)))
          (set! index (+ index 1))))
      (while (< index 80)
        (begin
          (set!
            (array-ref schedule index)
            (+
              (sigma-small-one (array-ref schedule (- index 2)))
              (array-ref schedule (- index 7))
              (sigma-small-zero (array-ref schedule (- index 15)))
              (array-ref schedule (- index 16))))
          (set! index (+ index 1))))
      (let
        [a : u64 (array-ref state.words 0)]
        [b : u64 (array-ref state.words 1)]
        [c : u64 (array-ref state.words 2)]
        [d : u64 (array-ref state.words 3)]
        [e : u64 (array-ref state.words 4)]
        [f : u64 (array-ref state.words 5)]
        [g : u64 (array-ref state.words 6)]
        [h : u64 (array-ref state.words 7)]
        [round : i64 0]
        (begin
          (while (< round 80)
            (let
              [t1 : u64
                (+
                  h
                  (sigma-big-one e)
                  (choose e f g)
                  (array-ref constants round)
                  (array-ref schedule round))]
              [t2 : u64 (+ (sigma-big-zero a) (majority a b c))]
              (begin
                (set! h g)
                (set! g f)
                (set! f e)
                (set! e (+ d t1))
                (set! d c)
                (set! c b)
                (set! b a)
                (set! a (+ t1 t2))
                (set! round (+ round 1)))))
          (set! (array-ref state.words 0) (+ (array-ref state.words 0) a))
          (set! (array-ref state.words 1) (+ (array-ref state.words 1) b))
          (set! (array-ref state.words 2) (+ (array-ref state.words 2) c))
          (set! (array-ref state.words 3) (+ (array-ref state.words 3) d))
          (set! (array-ref state.words 4) (+ (array-ref state.words 4) e))
          (set! (array-ref state.words 5) (+ (array-ref state.words 5) f))
          (set! (array-ref state.words 6) (+ (array-ref state.words 6) g))
          (set! (array-ref state.words 7) (+ (array-ref state.words 7) h))))
      (unsafe
        (wipe-schedule-pointer!
          (ptr-cast (ptr-addr-of schedule) : (MutPtr u64)))))))

;: True when public bookkeeping fields describe a live streaming state.
(define (state-valid? [state : (& state Sha512State)]) : bool
  (and
    (>= state.block-length 0)
    (< state.block-length 128)
    (<= state.byte-length-high (max-byte-length-high))
    (=
      state.block-length
      (cast (bit-and state.byte-length-low (cast 127 : u64)) : i64))))

;: Extend `state` with every byte in `input` without allocation.
;:
;: Length admission completes before the first state or block mutation. A
;: finalized or invalid state returns a typed error and remains unchanged.
(define (update! [state : (&mut state Sha512State)] [input : (& input bytes)]) : Sha512UpdateResult
  (cond
    [state.finalized (Sha512UpdateErr (Sha512Finalized))]
    [(not (state-valid? state)) (Sha512UpdateErr (Sha512InvalidState))]
    [else
      (let
        [input-length : i64 (byte_buf.bytes-length input)]
        (match (length-add
          state.byte-length-high
          state.byte-length-low
          (cast input-length : u64))
          [(Sha512LengthErr error) (Sha512UpdateErr error)]
          [(Sha512LengthOk length)
            (let
              [offset : i64 0]
              (begin
                (set! state.byte-length-high length.high)
                (set! state.byte-length-low length.low)
                (while (< offset input-length)
                  (let
                    [available : i64 (- 128 state.block-length)]
                    [remaining : i64 (- input-length offset)]
                    [take : i64
                      (if (< remaining available)
                        remaining
                        available)]
                    [copy-index : i64 0]
                    (begin
                      (while (< copy-index take)
                        (begin
                          (set!
                            (array-ref
                              state.block
                              (+ state.block-length copy-index))
                            (byte_buf.bytes-ref input (+ offset copy-index)))
                          (set! copy-index (+ copy-index 1))))
                      (set! state.block-length (+ state.block-length take))
                      (set! offset (+ offset take))
                      (if (= state.block-length 128)
                        (begin
                          (compress! state)
                          (set! state.block-length 0))
                        unit))))
                (Sha512UpdateOk)))]))]))

;: Extend `state` from a raw, scoped source without constructing an ordinary
;: byte container. This is the unsafe adapter boundary for cleanup-owned crypto
;: storage: `input` must remain valid for `input-length` readable bytes and
;: must not alias `state`. All public length/state checks complete before the
;: first pointer read or state mutation. A null pointer is accepted only for a
;: zero-length source.
(unsafe
  (define (update-from-pointer!
    [state : (&mut state Sha512State)]
    [input : (Ptr u8)]
    [input-length : i64]) : Sha512UpdateResult
    (cond
      [state.finalized (Sha512UpdateErr (Sha512Finalized))]
      [(not (state-valid? state)) (Sha512UpdateErr (Sha512InvalidState))]
      [(< input-length 0)
        (Sha512UpdateErr (Sha512InvalidSourceLength input-length))]
      [(and (> input-length 0) (ptr-null? input))
        (Sha512UpdateErr (Sha512InvalidSource))]
      [else
        (match (length-add
          state.byte-length-high
          state.byte-length-low
          (cast input-length : u64))
          [(Sha512LengthErr error) (Sha512UpdateErr error)]
          [(Sha512LengthOk length)
            (let
              [offset : i64 0]
              (begin
                (set! state.byte-length-high length.high)
                (set! state.byte-length-low length.low)
                (while (< offset input-length)
                  (let
                    [available : i64 (- 128 state.block-length)]
                    [remaining : i64 (- input-length offset)]
                    [take : i64
                      (if (< remaining available)
                        remaining
                        available)]
                    [copy-index : i64 0]
                    (begin
                      (while (< copy-index take)
                        (begin
                          (set!
                            (array-ref
                              state.block
                              (+ state.block-length copy-index))
                            (unsafe
                              (ptr-read
                                (ptr-offset input (+ offset copy-index)))))
                          (set! copy-index (+ copy-index 1))))
                      (set! state.block-length (+ state.block-length take))
                      (set! offset (+ offset take))
                      (if (= state.block-length 128)
                        (begin
                          (compress! state)
                          (set! state.block-length 0))
                        unit))))
                (Sha512UpdateOk)))])])))

;: Finalize into a caller-validated, non-overlapping 64-byte raw sink. This is
;: unsafe so an imported call cannot accidentally erase pointer validity,
;: lifetime, capacity, or alias obligations. Prefer `finalize!` for public
;: digests and `consume-finalize-into!` from a checked secret-storage adapter.
(unsafe
  (define (finalize-into-pointer!
    [state : (&mut state Sha512State)]
    [output : (MutPtr u8)]) : Sha512FinalizeIntoResult
    (cond
      [state.finalized (Sha512FinalizeIntoErr (Sha512Finalized))]
      [(not (state-valid? state)) (Sha512FinalizeIntoErr (Sha512InvalidState))]
      [else
        (let
          [cursor : i64 state.block-length]
          (begin
            (set! (array-ref state.block cursor) (cast 128 : u8))
            (set! cursor (+ cursor 1))
            (if (> cursor 112)
              (begin
                (while (< cursor 128)
                  (begin
                    (set! (array-ref state.block cursor) (cast 0 : u8))
                    (set! cursor (+ cursor 1))))
                (compress! state)
                (set! cursor 0))
              unit)
            (while (< cursor 112)
              (begin
                (set! (array-ref state.block cursor) (cast 0 : u8))
                (set! cursor (+ cursor 1))))
            (write-bit-length!
              (&mut state.block)
              state.byte-length-high
              state.byte-length-low)
            (compress! state)
            (let
              [word-index : i64 0]
              (begin
                (while (< word-index 8)
                  (begin
                    (unsafe
                      (store-pointer-word-be!
                        output
                        (* word-index 8)
                        (array-ref state.words word-index)))
                    (set! word-index (+ word-index 1))))
                (set! state.finalized true)
                (set! state.block-length 0)
                (let
                  [block-index : i64 0]
                  (while (< block-index 128)
                    (begin
                      (set! (array-ref state.block block-index) (cast 0 : u8))
                      (set! block-index (+ block-index 1)))))
                (Sha512FinalizeIntoOk)))))])))

;: Finalize `state` exactly once and return its ordinary public 64-byte digest.
(define (finalize! [state : (&mut state Sha512State)]) : Sha512FinalizeResult
  (let
    [octets : (Array u8 64) (init)]
    [output : (MutPtr u8)
      (unsafe
        (ptr-cast (ptr-addr-of octets) : (MutPtr u8)))]
    (match (unsafe
      (finalize-into-pointer! state output))
      [(Sha512FinalizeIntoOk) (Sha512FinalizeOk (Sha512Digest octets))]
      [(Sha512FinalizeIntoErr error) (Sha512FinalizeErr error)])))

;: Compute a one-shot SHA-512 digest over exact borrowed bytes.
(define (digest [input : (& input bytes)]) : Sha512FinalizeResult
  (let
    [state : Sha512State (new)]
    (match (update! (&mut state) input)
      [(Sha512UpdateErr error) (Sha512FinalizeErr error)]
      [(Sha512UpdateOk) (finalize! (&mut state))])))

;: Return one public digest byte, trapping when `index` is outside `[0, 64)`.
(define (digest-byte [digest : (& digest Sha512Digest)] [index : i64]) : u8
  (array-ref digest.octets index))

;: Return a by-value copy of all 64 public digest bytes.
(define (digest-bytes [digest : (& digest Sha512Digest)]) : (Array u8 64)
  digest.octets)

;: Compare two public digests exactly while visiting all 64 bytes.
(define (digest-eq?
  [left : (& left Sha512Digest)]
  [right : (& right Sha512Digest)]) : bool
  (let
    [different : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index 64)
        (begin
          (set!
            different
            (bit-or
              different
              (cast
                (bit-xor
                  (array-ref left.octets index)
                  (array-ref right.octets index))
                : u64)))
          (set! index (+ index 1))))
      (= different (cast 0 : u64)))))

;: Render a public digest as exactly 128 lowercase hexadecimal characters.
(define (to-hex [digest : (& digest Sha512Digest)]) : String
  (let
    [output : (MutPtr u8) (string.string-runtime-alloc 128)]
    [index : i64 0]
    (begin
      (while (< index 64)
        (let
          [byte : i64 (cast (array-ref digest.octets index) : i64)]
          [high : i64 (/ byte 16)]
          [low : i64 (% byte 16)]
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset output (* index 2))
                (cast
                  (if (< high 10)
                    (+ 48 high)
                    (+ 87 high))
                  : u8)))
            (unsafe
              (ptr-write!
                (ptr-offset output (+ (* index 2) 1))
                (cast
                  (if (< low 10)
                    (+ 48 low)
                    (+ 87 low))
                  : u8)))
            (set! index (+ index 1)))))
      (unsafe
        (string-from-bytes (ptr-cast output : (Ptr u8)) 128)))))

;: Construct the poisoned all-zero replacement installed by `wipe-state!`.
(define (wiped-state) : Sha512State
  (Sha512State (init) (init) 0 (cast 0 : u64) (cast 0 : u64) true))

;: Poison the caller's state before volatile-wiping its previous contents.
(define (wipe-state! [state : (&mut state Sha512State)]) : unit
  (let
    [previous : Sha512State (replace! (deref state) (wiped-state))]
    [word-data : (MutPtr u64)
      (unsafe
        (ptr-cast (ptr-addr-of previous.words) : (MutPtr u64)))]
    [block-data : (MutPtr u64)
      (unsafe
        (ptr-cast (ptr-addr-of previous.block) : (MutPtr u64)))]
    [index : i64 0]
    (begin
      (set! previous.finalized true)
      (set! previous.block-length 0)
      (set! previous.byte-length-high (cast 0 : u64))
      (set! previous.byte-length-low (cast 0 : u64))
      (while (< index 8)
        (begin
          (unsafe
            (volatile-store! (ptr-offset word-data index) (cast 0 : u64)))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index 16)
        (begin
          (unsafe
            (volatile-store! (ptr-offset block-data index) (cast 0 : u64)))
          (set! index (+ index 1)))))))

;: Zero the caller's digest before volatile-wiping its previous contents.
(define (wipe-digest! [digest : (&mut digest Sha512Digest)]) : unit
  (let
    [previous : Sha512Digest (replace! (deref digest) (Sha512Digest (init)))]
    [data : (MutPtr u64)
      (unsafe
        (ptr-cast (ptr-addr-of previous.octets) : (MutPtr u64)))]
    [index : i64 0]
    (while (< index 8)
      (begin
        (unsafe
          (volatile-store! (ptr-offset data index) (cast 0 : u64)))
        (set! index (+ index 1))))))

;: Consume a state into an exact caller-owned 64-byte sink, then poison and
;: volatile-wipe the context on success or typed failure. The output length,
;: pointer, and state are checked before destination mutation. The non-null
;: sink must be valid, writable, and non-overlapping with `state`; callers must
;: enter through `unsafe`, while #7309-style storage adapters retain the scoped
;: generation and ownership checks around this narrow primitive.
(unsafe
  (define (consume-finalize-into!
    [state : (&mut state Sha512State)]
    [output : (MutPtr u8)]
    [output-length : i64]) : Sha512FinalizeIntoResult
    (let
      [result : Sha512FinalizeIntoResult
        (cond
          [(not (= output-length 64))
            (Sha512FinalizeIntoErr (Sha512InvalidOutputLength output-length))]
          [(ptr-null? output) (Sha512FinalizeIntoErr (Sha512InvalidOutput))]
          [else
            (unsafe
              (finalize-into-pointer! state output))])]
      (begin
        (wipe-state! state)
        result))))