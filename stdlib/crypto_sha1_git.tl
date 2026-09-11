;# Streaming SHA-1 only for legacy Git object and pack compatibility.
;#
;# SHA-1 is collision-broken and must not be used here for signatures,
;# passwords, package authenticity, TLS, new MACs, or new protocols. This
;# module exists so TypeLisp's Git implementation can reproduce traditional
;# SHA-1 object IDs and pack/index checksums. A separately restricted
;# hashed-known-hosts HMAC adapter may use the exact raw sink seam; no other
;# production use is supported.
;#
;# The implementation follows the archived SHA-1 definition in FIPS 180-4.
;# `GitSha1State` retains one 64-byte partial block, checks the byte-oriented
;# `< 2^64 bits` domain before mutation, and executes the fixed 80-round
;# schedule. Inputs and digests are public compatibility data, not secrets.
;# Compression scratch and consumed state snapshots are volatile-wiped as a
;# narrow cleanup seam, not as a side-channel or whole-machine erasure claim.
;#
;# Usage: `(import stdlib.crypto_sha1_git)`
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (import stdlib.crypto_sha1_git)
;# (define (main) : i64
;#   (let
;#     [object-preimage : byte_buf.ByteBuf
;#       (byte_buf.append-string
;#         (byte_buf.push
;#           (byte_buf.append-string (byte_buf.new) "blob 6")
;#           (cast 0 : u8))
;#         "hello\n")]
;#     (match
;#       (crypto_sha1_git.git-digest (byte_buf.as-bytes (& object-preimage)))
;#       [(crypto_sha1_git.GitSha1FinalizeOk digest)
;#         (if (= (string-length (crypto_sha1_git.to-hex (& digest))) 40)
;#           42
;#           1)]
;#       [(crypto_sha1_git.GitSha1FinalizeErr _) 1])))
;# ```
(import stdlib.byte_buf)
(import stdlib.string)

;: Stable failures for the legacy-Git SHA-1 compatibility surface.
(defenum GitSha1Error
  (GitSha1Finalized)
  (GitSha1MessageTooLong u64 u64)
  (GitSha1InvalidSource)
  (GitSha1InvalidSourceLength i64)
  (GitSha1InvalidOutput)
  (GitSha1InvalidOutputLength i64)
  (GitSha1InvalidState))

;: Result of adding public input bytes to the checked SHA-1 byte count.
(defenum GitSha1LengthResult
  (GitSha1LengthOk u64)
  (GitSha1LengthErr GitSha1Error))

;: Incremental legacy-Git SHA-1 state. Construct only with `new`.
(defstruct GitSha1State
  (words (Array u32 5))
  (block (Array u8 64))
  (block-length i64)
  (byte-length u64)
  (open bool))

;: Exact public traditional-Git SHA-1 digest bytes in network order.
(defstruct GitSha1Digest
  (octets (Array u8 20)))

;: Result of extending an incremental legacy-Git digest.
(defenum GitSha1UpdateResult
  (GitSha1UpdateOk)
  (GitSha1UpdateErr GitSha1Error))

;: Result of finalizing an incremental legacy-Git digest.
(defenum GitSha1FinalizeResult
  (GitSha1FinalizeOk GitSha1Digest)
  (GitSha1FinalizeErr GitSha1Error))

;: Result of consuming a state into exact caller-owned 20-byte storage.
(defenum GitSha1FinalizeIntoResult
  (GitSha1FinalizeIntoOk)
  (GitSha1FinalizeIntoErr GitSha1Error))

;: Largest byte count whose eight-times bit count is below 2^64.
(define (max-byte-length) : u64
  0x1fffffffffffffff)

;: Add one public byte count without wrapping the FIPS SHA-1 domain.
(define (length-add [current : u64] [additional : u64]) : GitSha1LengthResult
  (let
    [next : u64 (+ current additional)]
    (if (or
      (> current (max-byte-length))
      (< next current)
      (> next (max-byte-length)))
      (GitSha1LengthErr (GitSha1MessageTooLong current additional))
      (GitSha1LengthOk next))))

;: Construct the FIPS 180-4 SHA-1 initial state.
(define (new) : GitSha1State
  (GitSha1State
    (array 0x67452301 0xefcdab89 0x98badcfe 0x10325476 0xc3d2e1f0)
    (init)
    0
    (cast 0 : u64)
    true))

;: Rotate one 32-bit word left by a checked nonzero count below 32.
(define (rotate-left [value : u32] [count : i64]) : u32
  (bit-or (shl value (cast count : u64)) (shr value (cast (- 32 count) : u64))))

;: SHA-1 choose function used in rounds 0 through 19.
(define (choose [x : u32] [y : u32] [z : u32]) : u32
  (bit-xor (bit-and x y) (bit-and (bit-not x) z)))

;: SHA-1 majority function used in rounds 40 through 59.
(define (majority [x : u32] [y : u32] [z : u32]) : u32
  (bit-xor (bit-and x y) (bit-and x z) (bit-and y z)))

;: Select the fixed SHA-1 Boolean function for one public round number.
(define (round-function [round : i64] [b : u32] [c : u32] [d : u32]) : u32
  (cond
    [(< round 20) (choose b c d)]
    [(< round 40) (bit-xor b c d)]
    [(< round 60) (majority b c d)]
    [else (bit-xor b c d)]))

;: Select the fixed SHA-1 additive constant for one public round number.
(define (round-constant [round : i64]) : u32
  (cond
    [(< round 20) 0x5a827999]
    [(< round 40) 0x6ed9eba1]
    [(< round 60) 0x8f1bbcdc]
    [else 0xca62c1d6]))

;: Load one network-order 32-bit word from a validated block offset.
(define (load-word-be [block : (& block (Array u8 64))] [offset : i64]) : u32
  (bit-or
    (shl (cast (array-ref block offset) : u32) (cast 24 : u64))
    (shl (cast (array-ref block (+ offset 1)) : u32) (cast 16 : u64))
    (shl (cast (array-ref block (+ offset 2)) : u32) (cast 8 : u64))
    (cast (array-ref block (+ offset 3)) : u32)))

;: Store the final checked 64-bit bit count in network order.
(define (write-bit-length!
  [block : (&mut block (Array u8 64))]
  [byte-length : u64]) : unit
  (let
    [bit-length : u64 (shl byte-length (cast 3 : u64))]
    [index : i64 0]
    (while (< index 8)
      (let
        [shift : i64 (- 56 (* index 8))]
        (begin
          (set!
            (array-ref block (+ 56 index))
            (cast
              (bit-and (shr bit-length (cast shift : u64)) (cast 255 : u64))
              : u8))
          (set! index (+ index 1)))))))

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
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset output (+ offset index))
                (cast
                  (bit-and (shr value (cast shift : u64)) (cast 255 : u32))
                  : u8)))
            (set! index (+ index 1))))))))

;: Volatile-wipe one completed 80-word compression schedule.
(unsafe
  (define (wipe-schedule-pointer! [data : (MutPtr u32)]) : unit
    (let
      [index : i64 0]
      (while (< index 80)
        (begin
          (unsafe
            (volatile-store! (ptr-offset data index) (cast 0 : u32)))
          (set! index (+ index 1)))))))

;: Compress the complete 64-byte block currently stored in `state`.
(define (compress! [state : (&mut state GitSha1State)]) : unit
  (let
    [schedule : (Array u32 80) (init)]
    [index : i64 0]
    (begin
      (while (< index 16)
        (begin
          (set!
            (array-ref schedule index)
            (load-word-be (& state.block) (* index 4)))
          (set! index (+ index 1))))
      (while (< index 80)
        (begin
          (set!
            (array-ref schedule index)
            (rotate-left
              (bit-xor
                (array-ref schedule (- index 3))
                (array-ref schedule (- index 8))
                (array-ref schedule (- index 14))
                (array-ref schedule (- index 16)))
              1))
          (set! index (+ index 1))))
      (let
        [a : u32 (array-ref state.words 0)]
        [b : u32 (array-ref state.words 1)]
        [c : u32 (array-ref state.words 2)]
        [d : u32 (array-ref state.words 3)]
        [e : u32 (array-ref state.words 4)]
        [round : i64 0]
        (begin
          (while (< round 80)
            (let
              [next : u32
                (+
                  (rotate-left a 5)
                  (round-function round b c d)
                  e
                  (round-constant round)
                  (array-ref schedule round))]
              (begin
                (set! e d)
                (set! d c)
                (set! c (rotate-left b 30))
                (set! b a)
                (set! a next)
                (set! round (+ round 1)))))
          (set! (array-ref state.words 0) (+ (array-ref state.words 0) a))
          (set! (array-ref state.words 1) (+ (array-ref state.words 1) b))
          (set! (array-ref state.words 2) (+ (array-ref state.words 2) c))
          (set! (array-ref state.words 3) (+ (array-ref state.words 3) d))
          (set! (array-ref state.words 4) (+ (array-ref state.words 4) e))))
      (unsafe
        (wipe-schedule-pointer!
          (ptr-cast (ptr-addr-of schedule) : (MutPtr u32)))))))

;: True when public bookkeeping fields describe a live streaming state.
(define (state-valid? [state : (& state GitSha1State)]) : bool
  (and
    (>= state.block-length 0)
    (< state.block-length 64)
    (<= state.byte-length (max-byte-length))
    (=
      state.block-length
      (cast (bit-and state.byte-length (cast 63 : u64)) : i64))))

;: Extend `state` with every public compatibility byte in `input`.
;:
;: Length admission completes before the first state mutation. Finalized or
;: invalid state returns a typed error and remains closed or unchanged.
(define (update! [state : (&mut state GitSha1State)] [input : (& input bytes)]) : GitSha1UpdateResult
  (cond
    [(not state.open) (GitSha1UpdateErr (GitSha1Finalized))]
    [(not (state-valid? state)) (GitSha1UpdateErr (GitSha1InvalidState))]
    [else
      (let
        [input-length : i64 (byte_buf.bytes-length input)]
        (match (length-add state.byte-length (cast input-length : u64))
          [(GitSha1LengthErr error) (GitSha1UpdateErr error)]
          [(GitSha1LengthOk length)
            (let
              [offset : i64 0]
              (begin
                (set! state.byte-length length)
                (while (< offset input-length)
                  (let
                    [available : i64 (- 64 state.block-length)]
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
                      (if (= state.block-length 64)
                        (begin
                          (compress! state)
                          (set! state.block-length 0))
                        unit))))
                (GitSha1UpdateOk)))]))]))

;: Extend `state` from a raw scoped source without an ordinary byte container.
;: The source must remain valid for `input-length` bytes and not alias state.
;: All checks finish before pointer reads or state mutation; null is accepted
;: only for a zero-length source.
(unsafe
  (define (update-from-pointer!
    [state : (&mut state GitSha1State)]
    [input : (Ptr u8)]
    [input-length : i64]) : GitSha1UpdateResult
    (cond
      [(not state.open) (GitSha1UpdateErr (GitSha1Finalized))]
      [(not (state-valid? state)) (GitSha1UpdateErr (GitSha1InvalidState))]
      [(< input-length 0)
        (GitSha1UpdateErr (GitSha1InvalidSourceLength input-length))]
      [(and (> input-length 0) (ptr-null? input))
        (GitSha1UpdateErr (GitSha1InvalidSource))]
      [else
        (match (length-add state.byte-length (cast input-length : u64))
          [(GitSha1LengthErr error) (GitSha1UpdateErr error)]
          [(GitSha1LengthOk length)
            (let
              [offset : i64 0]
              (begin
                (set! state.byte-length length)
                (while (< offset input-length)
                  (let
                    [available : i64 (- 64 state.block-length)]
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
                      (if (= state.block-length 64)
                        (begin
                          (compress! state)
                          (set! state.block-length 0))
                        unit))))
                (GitSha1UpdateOk)))])])))

;: Construct the closed all-zero replacement installed after consumption.
(define (wiped-state) : GitSha1State
  (GitSha1State (init) (init) 0 (cast 0 : u64) false))

;: Poison state, then volatile-wipe its previous words and partial block.
(define (wipe-state! [state : (&mut state GitSha1State)]) : unit
  (let
    [previous : GitSha1State (replace! (deref state) (wiped-state))]
    [word-data : (MutPtr u32)
      (unsafe
        (ptr-cast (ptr-addr-of previous.words) : (MutPtr u32)))]
    [block-data : (MutPtr u64)
      (unsafe
        (ptr-cast (ptr-addr-of previous.block) : (MutPtr u64)))]
    [index : i64 0]
    (begin
      (set! previous.open false)
      (set! previous.block-length 0)
      (set! previous.byte-length (cast 0 : u64))
      (while (< index 5)
        (begin
          (unsafe
            (volatile-store! (ptr-offset word-data index) (cast 0 : u32)))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index 8)
        (begin
          (unsafe
            (volatile-store! (ptr-offset block-data index) (cast 0 : u64)))
          (set! index (+ index 1)))))))

;: Finalize into a caller-validated non-overlapping raw 20-byte sink.
;: `output` must be non-null and writable for exactly 20 bytes. Prefer
;: `finalize!` for Git object IDs and `consume-finalize-into!` for the future
;: checked restricted-HMAC adapter.
(unsafe
  (define (finalize-into-pointer!
    [state : (&mut state GitSha1State)]
    [output : (MutPtr u8)]) : GitSha1FinalizeIntoResult
    (cond
      [(not state.open) (GitSha1FinalizeIntoErr (GitSha1Finalized))]
      [(not (state-valid? state))
        (GitSha1FinalizeIntoErr (GitSha1InvalidState))]
      [else
        (let
          [cursor : i64 state.block-length]
          (begin
            (set! (array-ref state.block cursor) (cast 128 : u8))
            (set! cursor (+ cursor 1))
            (if (> cursor 56)
              (begin
                (while (< cursor 64)
                  (begin
                    (set! (array-ref state.block cursor) (cast 0 : u8))
                    (set! cursor (+ cursor 1))))
                (compress! state)
                (set! cursor 0))
              unit)
            (while (< cursor 56)
              (begin
                (set! (array-ref state.block cursor) (cast 0 : u8))
                (set! cursor (+ cursor 1))))
            (write-bit-length! (&mut state.block) state.byte-length)
            (compress! state)
            (let
              [word-index : i64 0]
              (begin
                (while (< word-index 5)
                  (begin
                    (unsafe
                      (store-pointer-word-be!
                        output
                        (* word-index 4)
                        (array-ref state.words word-index)))
                    (set! word-index (+ word-index 1))))
                (wipe-state! state)
                (GitSha1FinalizeIntoOk)))))])))

;: Finalize `state` once into an ordinary public Git compatibility digest.
(define (finalize! [state : (&mut state GitSha1State)]) : GitSha1FinalizeResult
  (let
    [octets : (Array u8 20) (init)]
    [output : (MutPtr u8)
      (unsafe
        (ptr-cast (ptr-addr-of octets) : (MutPtr u8)))]
    (match (unsafe
      (finalize-into-pointer! state output))
      [(GitSha1FinalizeIntoOk) (GitSha1FinalizeOk (GitSha1Digest octets))]
      [(GitSha1FinalizeIntoErr error) (GitSha1FinalizeErr error)])))

;: One-shot SHA-1 only for an exact legacy Git object or pack preimage.
(define (git-digest [input : (& input bytes)]) : GitSha1FinalizeResult
  (let
    [state : GitSha1State (new)]
    (match (update! (&mut state) input)
      [(GitSha1UpdateErr error)
        (begin
          (wipe-state! (&mut state))
          (GitSha1FinalizeErr error))]
      [(GitSha1UpdateOk) (finalize! (&mut state))])))

;: Return one public Git digest byte; trap outside `[0, 20)`.
(define (digest-byte [digest : (& digest GitSha1Digest)] [index : i64]) : u8
  (array-ref digest.octets index))

;: Return a by-value copy of all 20 public Git digest bytes.
(define (digest-bytes [digest : (& digest GitSha1Digest)]) : (Array u8 20)
  digest.octets)

;: Compare two public Git digests while visiting all 20 bytes.
(define (digest-eq?
  [left : (& left GitSha1Digest)]
  [right : (& right GitSha1Digest)]) : bool
  (let
    [different : u32 (cast 0 : u32)]
    [index : i64 0]
    (begin
      (while (< index 20)
        (begin
          (set!
            different
            (bit-or
              different
              (cast
                (bit-xor
                  (array-ref left.octets index)
                  (array-ref right.octets index))
                : u32)))
          (set! index (+ index 1))))
      (= different (cast 0 : u32)))))

;: Render a public traditional Git object ID as 40 lowercase hex bytes.
(define (to-hex [digest : (& digest GitSha1Digest)]) : String
  (let
    [output : (MutPtr u8) (string.string-runtime-alloc 40)]
    [index : i64 0]
    (begin
      (while (< index 20)
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
        (string-from-bytes (ptr-cast output : (Ptr u8)) 40)))))

;: Zero a public digest, volatile-wiping its previous by-value contents.
(define (wipe-digest! [digest : (&mut digest GitSha1Digest)]) : unit
  (let
    [previous : GitSha1Digest (replace! (deref digest) (GitSha1Digest (init)))]
    [data : (MutPtr u32)
      (unsafe
        (ptr-cast (ptr-addr-of previous.octets) : (MutPtr u32)))]
    [index : i64 0]
    (while (< index 5)
      (begin
        (unsafe
          (volatile-store! (ptr-offset data index) (cast 0 : u32)))
        (set! index (+ index 1))))))

;: Consume state into an exact caller-owned 20-byte sink and wipe it on every
;: path. Pointer, length, and lifecycle checks happen before destination
;: mutation. A non-null sink must be valid, writable, and not overlap `state`;
;: the future restricted HMAC wrapper must retain its own generation, lifetime,
;: and ownership checks around this unsafe primitive.
(unsafe
  (define (consume-finalize-into!
    [state : (&mut state GitSha1State)]
    [output : (MutPtr u8)]
    [output-length : i64]) : GitSha1FinalizeIntoResult
    (let
      [result : GitSha1FinalizeIntoResult
        (cond
          [(not (= output-length 20))
            (GitSha1FinalizeIntoErr (GitSha1InvalidOutputLength output-length))]
          [(ptr-null? output) (GitSha1FinalizeIntoErr (GitSha1InvalidOutput))]
          [else
            (unsafe
              (finalize-into-pointer! state output))])]
      (begin
        (wipe-state! state)
        result))))