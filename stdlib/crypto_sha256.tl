;# Streaming SHA-256 message digests.
;#
;# This module implements FIPS 180-4 SHA-256 over exact borrowed byte views.
;# `Sha256State` retains at most one 64-byte partial block, checks the
;# byte-oriented `< 2^64 bits` message domain before mutation, and does not
;# allocate during update or finalization.
;#
;# Digests are ordinary public 32-byte values. Callers hashing secret-derived
;# material can use the unsafe scoped raw-source/exact-sink adapters and
;# explicitly consume and wipe a state or digest. Those helpers do not make
;# every public hash cleanup-owning or promise whole-machine erasure or
;# secret-independent timing. SHA-256 is an integrity primitive, not an
;# authenticity, signature, password-hashing, or MAC API.
;#
;# Usage: `(import stdlib.crypto_sha256)`
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (import stdlib.crypto_sha256)
;# (define (main) : i64
;#   (let
;#     [text : String "abc"]
;#     (match
;#       (crypto_sha256.digest (byte_buf.str-as-bytes (& text)))
;#       [(crypto_sha256.Sha256FinalizeOk digest)
;#         (if (= (string-length (crypto_sha256.to-hex (& digest))) 64)
;#           42
;#           1)]
;#       [(crypto_sha256.Sha256FinalizeErr _) 1])))
;# ```
(import stdlib.byte_buf)
(import stdlib.clone as clone_gen)
(import stdlib.string)

;: Stable SHA-256 update and finalization failures.
(defenum Sha256Error
  (Sha256Finalized)
  (Sha256MessageTooLong u64 u64)
  (Sha256InvalidSource)
  (Sha256InvalidSourceLength i64)
  (Sha256InvalidOutput)
  (Sha256InvalidOutputLength i64)
  (Sha256InvalidState))

;: Result of adding one public input length to the checked byte count.
(defenum Sha256LengthResult
  (Sha256LengthOk u64)
  (Sha256LengthErr Sha256Error))

;: Incremental SHA-256 state. Construct with `new`; a directly constructed
;: aggregate is not necessarily a valid state.
(defstruct Sha256State
  (words (Array u32 8))
  (block (Array u8 64))
  (block-length i64)
  (byte-length u64)
  (finalized bool))

;: Exact public SHA-256 digest bytes in network order.
(defstruct Sha256Digest
  (octets (Array u8 32)))

;: Result of extending an incremental SHA-256 state.
(defenum Sha256UpdateResult
  (Sha256UpdateOk)
  (Sha256UpdateErr Sha256Error))

;: Result of finalizing an incremental SHA-256 state.
(defenum Sha256FinalizeResult
  (Sha256FinalizeOk Sha256Digest)
  (Sha256FinalizeErr Sha256Error))

;: Result of consuming a state into exact caller-owned 32-byte storage.
(defenum Sha256FinalizeIntoResult
  (Sha256FinalizeIntoOk)
  (Sha256FinalizeIntoErr Sha256Error))

;: Largest byte count whose eight-times bit count is below 2^64.
(define (max-byte-length) : u64
  0x1fffffffffffffff)

;: Add one byte count without wrapping the FIPS SHA-256 message domain.
(define (length-add [current : u64] [additional : u64]) : Sha256LengthResult
  (let
    [next : u64 (+ current additional)]
    (if (or
      (> current (max-byte-length))
      (< next current)
      (> next (max-byte-length)))
      (Sha256LengthErr (Sha256MessageTooLong current additional))
      (Sha256LengthOk next))))

;: Construct the FIPS 180-4 SHA-256 initial state.
(define (new) : Sha256State
  (Sha256State
    (array
      0x6a09e667
      0xbb67ae85
      0x3c6ef372
      0xa54ff53a
      0x510e527f
      0x9b05688c
      0x1f83d9ab
      0x5be0cd19)
    (make-array u8 64)
    0
    (cast 0 : u64)
    false))

;: Store the checked 64-bit bit count in the last eight block bytes.
(define (write-bit-length!
  [block : (&mut block (Array u8 64))]
  [byte-length : u64]) : unit
  (let
    [bit-length : u64 (shl byte-length (cast 3 : u64))]
    [index : i64 0]
    (while (< index 8)
      (let
        [shift : i64 (- 56 (* index 8))]
        (set!
          (array-ref block (+ 56 index))
          (cast
            (bit-and (shr bit-length (cast shift : u64)) (cast 255 : u64))
            : u8))
        (set! index (+ index 1))))))

;: Store one digest word in network order through an audited raw sink.
(unsafe
  (define (store-pointer-word-be!
    [output : (MutPtr u8)]
    [offset : i64]
    [value : u32]) : unit
    (let
      [index : i64 0]
      (while (< index 4)
        (let
          [shift : i64 (- 24 (* index 8))]
          (unsafe
            (ptr-write!
              (ptr-offset output (+ offset index))
              (cast
                (bit-and (shr value (cast shift : u64)) (cast 255 : u32))
                : u8)))
          (set! index (+ index 1)))))))

;: Volatile-wipe a completed 64-word compression schedule.
(unsafe
  (define (wipe-schedule-pointer! [data : (MutPtr u32)]) : unit
    (let
      [index : i64 0]
      (while (< index 64)
        (unsafe
          (volatile-store! (ptr-offset data index) (cast 0 : u32)))
        (set! index (+ index 1))))))

;: FIPS 180-4 SHA-256 round constants.
(define sha256-round-constants : (Array u32 64)
  (array
    0x428a2f98
    0x71374491
    0xb5c0fbcf
    0xe9b5dba5
    0x3956c25b
    0x59f111f1
    0x923f82a4
    0xab1c5ed5
    0xd807aa98
    0x12835b01
    0x243185be
    0x550c7dc3
    0x72be5d74
    0x80deb1fe
    0x9bdc06a7
    0xc19bf174
    0xe49b69c1
    0xefbe4786
    0x0fc19dc6
    0x240ca1cc
    0x2de92c6f
    0x4a7484aa
    0x5cb0a9dc
    0x76f988da
    0x983e5152
    0xa831c66d
    0xb00327c8
    0xbf597fc7
    0xc6e00bf3
    0xd5a79147
    0x06ca6351
    0x14292967
    0x27b70a85
    0x2e1b2138
    0x4d2c6dfc
    0x53380d13
    0x650a7354
    0x766a0abb
    0x81c2c92e
    0x92722c85
    0xa2bfe8a1
    0xa81a664b
    0xc24b8b70
    0xc76c51a3
    0xd192e819
    0xd6990624
    0xf40e3585
    0x106aa070
    0x19a4c116
    0x1e376c08
    0x2748774c
    0x34b0bcb5
    0x391c0cb3
    0x4ed8aa4a
    0x5b9cca4f
    0x682e6ff3
    0x748f82ee
    0x78a5636f
    0x84c87814
    0x8cc70208
    0x90befffa
    0xa4506ceb
    0xbef9a3f7
    0xc67178f2))

;: Build the 64-word SHA-256 message schedule from a validated 64-byte pointer.
(unsafe
  (define (build-schedule-from-pointer!
    [sched : (MutPtr u32)]
    [block : (Ptr u8)]) : unit
    (unsafe
      (let
        [index : i64 0]
        (while (< index 16)
          (let
            [off : i64 (shl index 2)]
            [b0 : u32 (cast (ptr-read (ptr-offset block off)) : u32)]
            [b1 : u32 (cast (ptr-read (ptr-offset block (+ off 1))) : u32)]
            [b2 : u32 (cast (ptr-read (ptr-offset block (+ off 2))) : u32)]
            [b3 : u32 (cast (ptr-read (ptr-offset block (+ off 3))) : u32)]
            (ptr-write!
              (ptr-offset sched index)
              (bit-or
                (shl b0 (cast 24 : u64))
                (shl b1 (cast 16 : u64))
                (shl b2 (cast 8 : u64))
                b3)))
          (+= index 1))
        (while (< index 64)
          (let
            [w2 : u32 (ptr-read (ptr-offset sched (- index 2)))]
            [w15 : u32 (ptr-read (ptr-offset sched (- index 15)))]
            [s1 : u32
              (bit-xor
                (bit-or (shr w2 (cast 17 : u64)) (shl w2 (cast 15 : u64)))
                (bit-or (shr w2 (cast 19 : u64)) (shl w2 (cast 13 : u64)))
                (shr w2 (cast 10 : u64)))]
            [s0 : u32
              (bit-xor
                (bit-or (shr w15 (cast 7 : u64)) (shl w15 (cast 25 : u64)))
                (bit-or (shr w15 (cast 18 : u64)) (shl w15 (cast 14 : u64)))
                (shr w15 (cast 3 : u64)))]
            (ptr-write!
              (ptr-offset sched index)
              (+
                s1
                (ptr-read (ptr-offset sched (- index 7)))
                s0
                (ptr-read (ptr-offset sched (- index 16))))))
          (+= index 1))))))

;: Run the 64 SHA-256 compression rounds, writing the 8 round outputs to `out`.
;: Taking initial words by value keeps the 64-round loop free of caller-state
;: aliasing so all working registers stay live in GPRs.
(unsafe
  (define (compress-rounds-into!
    [out : (MutPtr u32)]
    [sched : (Ptr u32)]
    [a0 : u32]
    [b0 : u32]
    [c0 : u32]
    [d0 : u32]
    [e0 : u32]
    [f0 : u32]
    [g0 : u32]
    [h0 : u32]) : unit
    (unsafe
      (let
        [k : (Ptr u32)
          (ptr-cast
            (ptr-addr-of (array-ref sha256-round-constants 0))
            : (Ptr u32))]
        [a : u32 a0]
        [b : u32 b0]
        [c : u32 c0]
        [d : u32 d0]
        [e : u32 e0]
        [f : u32 f0]
        [g : u32 g0]
        [h : u32 h0]
        [round : i64 0]
        (while (< round 64)
          (let
            [t1 : u32
              (+
                h
                (ptr-read (ptr-offset k round))
                (ptr-read (ptr-offset sched round)))]
            [ab : u32 (bit-or a b)]
            [t2 : u32 (bit-or (bit-and a b) (bit-and c ab))]
            (set!
              t1
              (+
                t1
                (bit-xor
                  (bit-or (shr e (cast 6 : u64)) (shl e (cast 26 : u64)))
                  (bit-or (shr e (cast 11 : u64)) (shl e (cast 21 : u64)))
                  (bit-or (shr e (cast 25 : u64)) (shl e (cast 7 : u64))))
                (bit-xor g (bit-and e (bit-xor f g)))))
            (set!
              t2
              (+
                t2
                (bit-xor
                  (bit-or (shr a (cast 2 : u64)) (shl a (cast 30 : u64)))
                  (bit-or (shr a (cast 13 : u64)) (shl a (cast 19 : u64)))
                  (bit-or (shr a (cast 22 : u64)) (shl a (cast 10 : u64))))))
            (set! h g)
            (set! g f)
            (set! f e)
            (set! e (+ d t1))
            (set! d c)
            (set! c b)
            (set! b a)
            (set! a (+ t1 t2))
            (+= round 1)))
        (ptr-write! out a)
        (ptr-write! (ptr-offset out 1) b)
        (ptr-write! (ptr-offset out 2) c)
        (ptr-write! (ptr-offset out 3) d)
        (ptr-write! (ptr-offset out 4) e)
        (ptr-write! (ptr-offset out 5) f)
        (ptr-write! (ptr-offset out 6) g)
        (ptr-write! (ptr-offset out 7) h)))))

;: Compress one validated 64-byte block pointer directly into `state.words`.
(unsafe
  (define (compress-block-pointer!
    [state : (&mut state Sha256State)]
    [block : (Ptr u8)]) : unit
    (unsafe
      (let
        [schedule : (Array u32 64) (make-array u32 64)]
        [delta : (Array u32 8) (make-array u32 8)]
        [sched-mut : (MutPtr u32)
          (ptr-cast (ptr-addr-of schedule) : (MutPtr u32))]
        [sched-ro : (Ptr u32) (ptr-cast (ptr-addr-of schedule) : (Ptr u32))]
        [delta-mut : (MutPtr u32) (ptr-cast (ptr-addr-of delta) : (MutPtr u32))]
        (build-schedule-from-pointer! sched-mut block)
        (compress-rounds-into!
          delta-mut
          sched-ro
          (array-ref state.words 0)
          (array-ref state.words 1)
          (array-ref state.words 2)
          (array-ref state.words 3)
          (array-ref state.words 4)
          (array-ref state.words 5)
          (array-ref state.words 6)
          (array-ref state.words 7))
        (set!
          (array-ref state.words 0)
          (+ (array-ref state.words 0) (array-ref delta 0)))
        (set!
          (array-ref state.words 1)
          (+ (array-ref state.words 1) (array-ref delta 1)))
        (set!
          (array-ref state.words 2)
          (+ (array-ref state.words 2) (array-ref delta 2)))
        (set!
          (array-ref state.words 3)
          (+ (array-ref state.words 3) (array-ref delta 3)))
        (set!
          (array-ref state.words 4)
          (+ (array-ref state.words 4) (array-ref delta 4)))
        (set!
          (array-ref state.words 5)
          (+ (array-ref state.words 5) (array-ref delta 5)))
        (set!
          (array-ref state.words 6)
          (+ (array-ref state.words 6) (array-ref delta 6)))
        (set!
          (array-ref state.words 7)
          (+ (array-ref state.words 7) (array-ref delta 7)))
        (wipe-schedule-pointer! sched-mut)
        ;; The round delta is keyed material for HMAC/HKDF callers too.
        (volatile-store! delta-mut (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 1) (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 2) (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 3) (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 4) (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 5) (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 6) (cast 0 : u32))
        (volatile-store! (ptr-offset delta-mut 7) (cast 0 : u32))))))

;: Compress the complete 64-byte block currently stored in `state`.
(define (compress! [state : (&mut state Sha256State)]) : unit
  (let
    [schedule : (Array u32 64) (make-array u32 64)]
    [index : i64 0]
    (while (< index 16)
      (let
        [off : i64 (shl index 2)]
        [b0 : u32 (cast (array-ref state.block off) : u32)]
        [b1 : u32 (cast (array-ref state.block (+ off 1)) : u32)]
        [b2 : u32 (cast (array-ref state.block (+ off 2)) : u32)]
        [b3 : u32 (cast (array-ref state.block (+ off 3)) : u32)]
        (set!
          (array-ref schedule index)
          (bit-or
            (shl b0 (cast 24 : u64))
            (shl b1 (cast 16 : u64))
            (shl b2 (cast 8 : u64))
            b3)))
      (+= index 1))
    (while (< index 64)
      (let
        [w2 : u32 (array-ref schedule (- index 2))]
        [w15 : u32 (array-ref schedule (- index 15))]
        [s1 : u32
          (bit-xor
            (bit-or (shr w2 (cast 17 : u64)) (shl w2 (cast 15 : u64)))
            (bit-or (shr w2 (cast 19 : u64)) (shl w2 (cast 13 : u64)))
            (shr w2 (cast 10 : u64)))]
        [s0 : u32
          (bit-xor
            (bit-or (shr w15 (cast 7 : u64)) (shl w15 (cast 25 : u64)))
            (bit-or (shr w15 (cast 18 : u64)) (shl w15 (cast 14 : u64)))
            (shr w15 (cast 3 : u64)))]
        (set!
          (array-ref schedule index)
          (+
            s1
            (array-ref schedule (- index 7))
            s0
            (array-ref schedule (- index 16)))))
      (+= index 1))
    (let
      [a : u32 (array-ref state.words 0)]
      [b : u32 (array-ref state.words 1)]
      [c : u32 (array-ref state.words 2)]
      [d : u32 (array-ref state.words 3)]
      [e : u32 (array-ref state.words 4)]
      [f : u32 (array-ref state.words 5)]
      [g : u32 (array-ref state.words 6)]
      [h : u32 (array-ref state.words 7)]
      [round : i64 0]
      (while (< round 64)
        (let
          [t1 : u32
            (+
              h
              (array-ref sha256-round-constants round)
              (array-ref schedule round))]
          [ab : u32 (bit-or a b)]
          [t2 : u32 (bit-or (bit-and a b) (bit-and c ab))]
          (set!
            t1
            (+
              t1
              (bit-xor
                (bit-or (shr e (cast 6 : u64)) (shl e (cast 26 : u64)))
                (bit-or (shr e (cast 11 : u64)) (shl e (cast 21 : u64)))
                (bit-or (shr e (cast 25 : u64)) (shl e (cast 7 : u64))))
              (bit-xor g (bit-and e (bit-xor f g)))))
          (set!
            t2
            (+
              t2
              (bit-xor
                (bit-or (shr a (cast 2 : u64)) (shl a (cast 30 : u64)))
                (bit-or (shr a (cast 13 : u64)) (shl a (cast 19 : u64)))
                (bit-or (shr a (cast 22 : u64)) (shl a (cast 10 : u64))))))
          (set! h g)
          (set! g f)
          (set! f e)
          (set! e (+ d t1))
          (set! d c)
          (set! c b)
          (set! b a)
          (set! a (+ t1 t2))
          (+= round 1)))
      (set! (array-ref state.words 0) (+ (array-ref state.words 0) a))
      (set! (array-ref state.words 1) (+ (array-ref state.words 1) b))
      (set! (array-ref state.words 2) (+ (array-ref state.words 2) c))
      (set! (array-ref state.words 3) (+ (array-ref state.words 3) d))
      (set! (array-ref state.words 4) (+ (array-ref state.words 4) e))
      (set! (array-ref state.words 5) (+ (array-ref state.words 5) f))
      (set! (array-ref state.words 6) (+ (array-ref state.words 6) g))
      (set! (array-ref state.words 7) (+ (array-ref state.words 7) h)))
    (unsafe
      (wipe-schedule-pointer! (ptr-cast (ptr-addr-of schedule) : (MutPtr u32))))))

;: True when public bookkeeping fields describe a live streaming state.
(define (state-valid? [state : (& state Sha256State)]) : bool
  (and
    (>= state.block-length 0)
    (< state.block-length 64)
    (<= state.byte-length (max-byte-length))
    (=
      state.block-length
      (cast (bit-and state.byte-length (cast 63 : u64)) : i64))))

;: Extend `state` from a raw call-scoped source without constructing a public
;: byte container. `input` must remain readable for `input-length` bytes and
;: must not alias `state`. All state, length, and pointer checks complete
;: before the first source read or state mutation. Null is valid only for zero
;: bytes; no pointer is retained after return.
(unsafe
  (define (update-from-pointer!
    [state : (&mut state Sha256State)]
    [input : (Ptr u8)]
    [input-length : i64]) : Sha256UpdateResult
    (cond
      [state.finalized (Sha256UpdateErr (Sha256Finalized))]
      [(not (state-valid? state)) (Sha256UpdateErr (Sha256InvalidState))]
      [(< input-length 0)
        (Sha256UpdateErr (Sha256InvalidSourceLength input-length))]
      [(and (> input-length 0) (ptr-null? input))
        (Sha256UpdateErr (Sha256InvalidSource))]
      [else
        (match (length-add state.byte-length (cast input-length : u64))
          [(Sha256LengthErr error) (Sha256UpdateErr error)]
          [(Sha256LengthOk length)
            (let
              [offset : i64 0]
              (set! state.byte-length length)
              (when
                (and (> state.block-length 0) (< offset input-length))
                (let
                  [available : i64 (- 64 state.block-length)]
                  [remaining : i64 (- input-length offset)]
                  [take : i64
                    (if (< remaining available)
                      remaining
                      available)]
                  [copy-index : i64 0]
                  (while (< copy-index take)
                    (set!
                      (array-ref state.block (+ state.block-length copy-index))
                      (unsafe
                        (ptr-read (ptr-offset input (+ offset copy-index)))))
                    (+= copy-index 1))
                  (+= state.block-length take)
                  (+= offset take)
                  (when
                    (= state.block-length 64)
                    (compress! state)
                    (set! state.block-length 0))))
              (while (<= (+ offset 64) input-length)
                (unsafe
                  (compress-block-pointer! state (ptr-offset input offset)))
                (+= offset 64))
              (while (< offset input-length)
                (set!
                  (array-ref state.block state.block-length)
                  (unsafe
                    (ptr-read (ptr-offset input offset))))
                (+= state.block-length 1)
                (+= offset 1))
              (Sha256UpdateOk))])])))

;: Extend `state` with every byte in an exact borrowed view. Update is
;: allocation-free, and any rejected update leaves the state unchanged.
(define (update! [state : (&mut state Sha256State)] [input : (& input bytes)]) : Sha256UpdateResult
  (unsafe
    (update-from-pointer!
      state
      (byte_buf.bytes-data input)
      (byte_buf.bytes-length input))))

;: Construct the poisoned all-zero replacement installed after consumption.
(define (wiped-state) : Sha256State
  (Sha256State (make-array u32 8) (make-array u8 64) 0 (cast 0 : u64) true))

;: Poison the caller's state, then volatile-wipe its prior chaining words,
;: partial block, byte counter, and cursor.
(define (wipe-state! [state : (&mut state Sha256State)]) : unit
  (let
    [previous : Sha256State (replace! (deref state) (wiped-state))]
    [word-data : (MutPtr u32)
      (unsafe
        (ptr-cast (ptr-addr-of previous.words) : (MutPtr u32)))]
    [block-data : (MutPtr u32)
      (unsafe
        (ptr-cast (ptr-addr-of previous.block) : (MutPtr u32)))]
    [cursor-data : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-addr-of previous.block-length) : (MutPtr i64)))]
    [length-data : (MutPtr u64)
      (unsafe
        (ptr-cast (ptr-addr-of previous.byte-length) : (MutPtr u64)))]
    [index : i64 0]
    (set! previous.finalized false)
    (while (< index 8)
      (unsafe
        (volatile-store! (ptr-offset word-data index) (cast 0 : u32)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 16)
      (unsafe
        (volatile-store! (ptr-offset block-data index) (cast 0 : u32)))
      (set! index (+ index 1)))
    (unsafe
      (volatile-store! cursor-data (cast 0 : i64)))
    (unsafe
      (volatile-store! length-data (cast 0 : u64)))))

;: Finalize into a caller-validated, non-overlapping raw 32-byte sink. The
;: sink must be non-null and writable. Prefer `finalize!` for public digests
;: and `consume-finalize-into!` from checked secret-storage adapters.
(unsafe
  (define (finalize-into-pointer!
    [state : (&mut state Sha256State)]
    [output : (MutPtr u8)]) : Sha256FinalizeIntoResult
    (cond
      [state.finalized (Sha256FinalizeIntoErr (Sha256Finalized))]
      [(not (state-valid? state)) (Sha256FinalizeIntoErr (Sha256InvalidState))]
      [else
        (let
          [cursor : i64 state.block-length]
          (set! (array-ref state.block cursor) (cast 128 : u8))
          (set! cursor (+ cursor 1))
          (if (> cursor 56)
            (begin
              (while (< cursor 64)
                (set! (array-ref state.block cursor) (cast 0 : u8))
                (set! cursor (+ cursor 1)))
              (compress! state)
              (set! cursor 0))
            unit)
          (while (< cursor 56)
            (set! (array-ref state.block cursor) (cast 0 : u8))
            (set! cursor (+ cursor 1)))
          (write-bit-length! (&mut state.block) state.byte-length)
          (compress! state)
          (let
            [word-index : i64 0]
            (while (< word-index 8)
              (unsafe
                (store-pointer-word-be!
                  output
                  (* word-index 4)
                  (array-ref state.words word-index)))
              (set! word-index (+ word-index 1)))
            (wipe-state! state)
            (Sha256FinalizeIntoOk)))])))

;: Finalize `state` exactly once into an ordinary public 32-byte digest.
(define (finalize! [state : (&mut state Sha256State)]) : Sha256FinalizeResult
  (let
    [octets : (Array u8 32) (make-array u8 32)]
    [output : (MutPtr u8)
      (unsafe
        (ptr-cast (ptr-addr-of octets) : (MutPtr u8)))]
    (match (unsafe
      (finalize-into-pointer! state output))
      [(Sha256FinalizeIntoOk) (Sha256FinalizeOk (Sha256Digest octets))]
      [(Sha256FinalizeIntoErr error) (Sha256FinalizeErr error)])))

;: Compute a one-shot SHA-256 digest over exact borrowed bytes.
(define (digest [input : (& input bytes)]) : Sha256FinalizeResult
  (let
    [state : Sha256State (new)]
    (match (update! (&mut state) input)
      [(Sha256UpdateErr error)
        (wipe-state! (&mut state))
        (Sha256FinalizeErr error)]
      [(Sha256UpdateOk) (finalize! (&mut state))])))

;: Return one public digest byte, trapping outside `[0, 32)`.
(define (digest-byte [digest : (& digest Sha256Digest)] [index : i64]) : u8
  (array-ref digest.octets index))

;: Return a by-value copy of all 32 public digest bytes.
(define (digest-bytes [digest : (& digest Sha256Digest)]) : (Array u8 32)
  digest.octets)

;: Compare two public digests exactly while visiting all 32 bytes.
(define (digest-eq?
  [left : (& left Sha256Digest)]
  [right : (& right Sha256Digest)]) : bool
  (let
    [different : u32 (cast 0 : u32)]
    [index : i64 0]
    (while (< index 32)
      (set!
        different
        (bit-or
          different
          (cast
            (bit-xor
              (array-ref left.octets index)
              (array-ref right.octets index))
            : u32)))
      (set! index (+ index 1)))
    (= different (cast 0 : u32))))

;: Render a public digest as exactly 64 lowercase hexadecimal characters.
(define (to-hex [digest : (& digest Sha256Digest)]) : String
  (let
    [output : (MutPtr u8) (string.string-runtime-alloc 64)]
    [index : i64 0]
    (while (< index 32)
      (let
        [byte : i64 (cast (array-ref digest.octets index) : i64)]
        [high : i64 (/ byte 16)]
        [low : i64 (% byte 16)]
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
        (set! index (+ index 1))))
    (unsafe
      (string-from-bytes (ptr-cast output : (Ptr u8)) 64))))

;: Zero the caller's digest, volatile-wiping its previous by-value contents.
(define (wipe-digest! [digest : (&mut digest Sha256Digest)]) : unit
  (let
    [previous : Sha256Digest
      (replace! (deref digest) (Sha256Digest (make-array u8 32)))]
    [data : (MutPtr u32)
      (unsafe
        (ptr-cast (ptr-addr-of previous.octets) : (MutPtr u32)))]
    [index : i64 0]
    (while (< index 8)
      (unsafe
        (volatile-store! (ptr-offset data index) (cast 0 : u32)))
      (set! index (+ index 1)))))

;: Consume state into an exact caller-owned 32-byte sink and wipe the state on
;: success or typed failure. Length, pointer, lifecycle, and state checks occur
;: before destination mutation. The caller must keep the non-null sink valid,
;: writable, non-overlapping, and generation-checked for the whole call.
(unsafe
  (define (consume-finalize-into!
    [state : (&mut state Sha256State)]
    [output : (MutPtr u8)]
    [output-length : i64]) : Sha256FinalizeIntoResult
    (let
      [result : Sha256FinalizeIntoResult
        (cond
          [(not (= output-length 32))
            (Sha256FinalizeIntoErr (Sha256InvalidOutputLength output-length))]
          [(ptr-null? output) (Sha256FinalizeIntoErr (Sha256InvalidOutput))]
          [else
            (unsafe
              (finalize-into-pointer! state output))])]
      (wipe-state! state)
      result)))

;: Scoped pointer-backed owner adapter. The caller owns initialized, aligned
;: state storage and a disjoint source for the whole call. A temporary state
;: is wiped after publishing the result; rejected updates preserve the state.
(unsafe
  (define (update-state-from-pointer!
    [state : (MutPtr Sha256State)]
    [input : (Ptr u8)]
    [input-length : i64]) : Sha256UpdateResult
    (let
      [working : Sha256State
        (unsafe
          (ptr-read state))]
      [result : Sha256UpdateResult
        (unsafe
          (update-from-pointer! (&mut working) input input-length))]
      (unsafe
        (ptr-write! state working))
      (wipe-state! (&mut working))
      result)))

;: Consuming scoped pointer-backed owner adapter. Poison the original before
;: finalization and wipe the temporary on every outcome. The exact sink must
;: remain disjoint from the state and caller-validated for the whole call.
(unsafe
  (define (consume-state-pointer-into!
    [state : (MutPtr Sha256State)]
    [output : (MutPtr u8)]
    [output-length : i64]) : Sha256FinalizeIntoResult
    (let
      [working : Sha256State
        (unsafe
          (ptr-read state))]
      (unsafe
        (ptr-write! state (wiped-state)))
      (let
        [result : Sha256FinalizeIntoResult
          (unsafe
            (consume-finalize-into! (&mut working) output output-length))]
        (wipe-state! (&mut working))
        result))))

;: Copy a digest into caller-owned metadata.
(clone_gen.gen-clone Sha256Digest)