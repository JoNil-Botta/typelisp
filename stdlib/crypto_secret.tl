;# Cleanup-owned secret bytes and fixed-work primitives for protocol crypto.
;#
;# `SecretFixed` holds exactly 16, 20, 32, 48 or 64 secret bytes and
;# `SecretBytes` holds a bounded, exactly tracked prefix of at most 65,536.
;# Both are cleanup-owning and move-only: they have no clone, Debug, format,
;# serialization, content equality, hash or `String` path, and safe code sees
;# only an opaque storage pointer. Structural `=` on two owners compares their
;# handles (storage address and stamp), never their bytes; compare contents
;# with `fixed-equal` or `bytes-equal`. Closing an owner, explicitly or by lexical cleanup,
;# poisons it and then wipes its whole capacity with volatile word stores;
;# closing again does nothing. A null, non-live or generation-mismatched
;# handle owns no live storage: its cleanup returns `unit` without mutation.
;#
;# The fixed-work helpers compare equal public lengths by visiting every byte
;# and select or swap through masks, with no branch or table lookup on secret
;# data. Crypto code reads and writes an exact checked range through the
;# `unsafe` pointer accessors, which check liveness, generation, offset and
;# count before returning.
;#
;# `fixed-copy-range!` and `bytes-copy-range!` copy checked public ranges into
;# a variable owner without a readable view. Same-storage copies are rejected
;# intentionally, including zero-count and disjoint ranges. A successful copy
;# publishes exactly max(previous length, destination offset + count).
;# `transfer-fixed` is an unsafe consuming macro for crypto implementations:
;# it transfers one exact fixed allocation into pointer-backed nominal state,
;# rotates its generation to invalidate old handles, and never copies secret
;# bytes. Nominal cleanup poisons outer state before cleaning its inner owner.
;#
;# These guarantees are a source and code-shape regression boundary, not a
;# side-channel review or certified erasure: copies in registers, caches, core
;# dumps or swapped-out pages are out of scope.
;#
;# Usage: `(import stdlib.crypto_secret)`
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (import stdlib.crypto_secret)
;# (define (main) : i64
;#   (let
;#     [key : String "0123456789abcdef"]
;#     (match
;#       (crypto_secret.fixed-from-bytes
;#         (crypto_secret.Secret16)
;#         (byte_buf.str-as-bytes (& key)))
;#       [(crypto_secret.SecretFixedOk secret)
;#         (let
;#           [length : i64 (crypto_secret.fixed-length (& secret))]
;#           (crypto_secret.close-fixed secret)
;#           (if (= length 16)
;#             42
;#             1))]
;#       [(crypto_secret.SecretFixedErr _) 1])))
;# ```
(import stdlib.byte_buf)

;: Active-arena allocation for owner storage.
(extern (secret-runtime-alloc [arg0 : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

;: Public secret-storage failures. They carry only lengths and offsets, never
;: secret bytes.
(defenum SecretError
  (SecretClosed)
  (SecretBadLength i64)
  (SecretLengthMismatch i64 i64)
  (SecretRange i64 i64 i64)
  (SecretAlias))

;: The exact fixed sizes protocol consumers use.
(defenum SecretSize
  (Secret16)
  (Secret20)
  (Secret32)
  (Secret48)
  (Secret64))

;: Header of one owner's storage allocation. The data words follow it in
;: the same allocation, and bytes past `length` are zero. Pointers of this type
;: come only from this module's constructors.
(defstruct SecretStorage
  (state u64)
  (generation u64)
  (length u64)
  (capacity u64))

;: Pointer and stamp passed together to cleanup. This is a checked handle,
;: not a unique capability; copying it does not create a new storage generation.
(defstruct SecretHandle
  (storage (MutPtr SecretStorage))
  (generation i64))

;: Exactly `size` secret bytes. Construct with `fixed-zero` or
;: `fixed-from-bytes`. The fields are not a capability: safe code can read
;: neither the storage nor a byte of the secret through them.
(defstruct SecretFixed
  (:cleanup close-fixed)
  (handle SecretHandle (:cleanup storage-close)))

;: A bounded secret buffer whose initialized length is tracked exactly.
;: Construct with `bytes-new` or `bytes-from-bytes`.
(defstruct SecretBytes
  (:cleanup close-bytes)
  (handle SecretHandle (:cleanup storage-close)))

;: Crypto-internal nominal state. Its separate allocation cannot be populated
;: from safe code, even where opaque representation authority is unavailable.
(defstruct SecretNominalStorage
  (:opaque)
  (state u64)
  (generation i64)
  (inner SecretHandle))

;: Checked identity of one nominal allocation, not its secret storage.
(defstruct SecretNominalHandle
  (storage (MutPtr SecretNominalStorage))
  (generation i64))

;: A move-only nominal secret. Only an unsafe transfer can create live state;
;: consumer modules retain this inside their own protocol-specific owner.
(defstruct SecretNominal
  (:cleanup close-nominal)
  (handle SecretNominalHandle (:cleanup nominal-handle-close)))

;: Transfer the caller's cleanup obligation into the consuming operation.
(defstruct SecretTransferInput
  (:cleanup close-transfer-input)
  (value SecretFixed (:owned)))

;: Transfer consumes its input on success and failure.
(defenum SecretNominalResult
  (:cleanup close-nominal-result)
  (:must-use)
  (SecretNominalOk SecretNominal (:owned))
  (SecretNominalErr SecretError))

;: A new fixed owner, or a public construction failure.
(defenum SecretFixedResult
  (:cleanup close-fixed-result)
  (:must-use)
  (SecretFixedOk SecretFixed (:owned))
  (SecretFixedErr SecretError))

;: A new variable owner, or a public construction failure.
(defenum SecretBytesResult
  (:cleanup close-bytes-result)
  (:must-use)
  (SecretBytesOk SecretBytes (:owned))
  (SecretBytesErr SecretError))

;: A completed operation, or a failure raised before any mutation.
(defenum SecretStatus
  (:must-use)
  (SecretOk)
  (SecretErr SecretError))

;: A fixed-work comparison of two live owners of equal public length.
(defenum SecretCompareResult
  (:must-use)
  (SecretCompareOk bool)
  (SecretCompareErr SecretError))

;: A checked read pointer to an exact live range.
(defenum SecretReadResult
  (:must-use)
  (SecretReadOk (Ptr u8))
  (SecretReadErr SecretError))

;: A checked write pointer to an exact live range.
(defenum SecretWriteResult
  (:must-use)
  (SecretWriteOk (MutPtr u8))
  (SecretWriteErr SecretError))

;: Largest capacity a variable owner accepts.
(define (max-capacity) : i64
  65536)

;: Bytes held by a fixed owner of `size`.
(define (size-bytes [size : SecretSize]) : i64
  (match size
    [(Secret16) 16]
    [(Secret20) 20]
    [(Secret32) 32]
    [(Secret48) 48]
    [(Secret64) 64]))

;; Storage is one allocation: a `SecretStorage` header, then capacity/8 data
;; words.
;: Header state of storage that holds a live secret.
(define (state-live) : u64
  (cast 0 : u64))

;: Header state while a close is wiping the storage.
(define (state-poisoned) : u64
  (cast 1 : u64))

;: Header state after the wipe completed.
(define (state-closed) : u64
  (cast 2 : u64))

;: Monotonic stamp shared by an owner and its storage; a handle whose stamp
;: differs from its storage's names storage reused by another owner.
(define secret-generation : i64
  0)

;: The next owner stamp.
(define (next-generation) : i64
  (set! secret-generation (+ secret-generation 1))
  secret-generation)

;: Data words that hold `capacity` bytes.
(define (data-words [capacity : i64]) : i64
  (/ (+ capacity 7) 8))

;: The data bytes of `storage`.
(unsafe
  (define (storage-data [storage : (MutPtr SecretStorage)]) : (MutPtr u8)
    (unsafe
      (ptr-cast (ptr-offset (ptr-cast storage : (MutPtr u64)) 4) : (MutPtr u8)))))

;: A snapshot of the header of non-null `storage`.
(unsafe
  (define (storage-header [storage : (MutPtr SecretStorage)]) : SecretStorage
    (unsafe
      (ptr-read storage))))

;: Allocate zeroed live storage for a validated capacity.
(unsafe
  (define (storage-new [capacity : i64] [generation : i64]) : (MutPtr
      SecretStorage)
    (let
      [words : i64 (+ 4 (data-words capacity))]
      [raw : (MutPtr u64)
        (unsafe
          (ptr-cast (secret-runtime-alloc (* words 8)) : (MutPtr u64)))]
      [index : i64 0]
      (while (< index words)
        (unsafe
          (ptr-write! (ptr-offset raw index) (cast 0 : u64)))
        (set! index (+ index 1)))
      (let
        [storage : (MutPtr SecretStorage)
          (unsafe
            (ptr-cast raw : (MutPtr SecretStorage)))]
        (unsafe
          (ptr-write!
            storage
            (SecretStorage
              (state-live)
              (cast generation : u64)
              (cast 0 : u64)
              (cast capacity : u64))))
        storage))))

;: Publish `length` initialized bytes.
(unsafe
  (define (storage-set-length!
    [storage : (MutPtr SecretStorage)]
    [length : i64]) : unit
    (let
      [header : SecretStorage
        (unsafe
          (storage-header storage))]
      (unsafe
        (ptr-write!
          storage
          (SecretStorage
            header.state
            header.generation
            (cast length : u64)
            header.capacity))))))

;: Whether `storage` is non-null, live and still stamped with `generation`.
(unsafe
  (define (storage-live? [storage : (MutPtr SecretStorage)] [generation : i64]) : bool
    (if (ptr-null? storage)
      false
      (let
        [header : SecretStorage
          (unsafe
            (storage-header storage))]
        (and
          (= header.state (state-live))
          (= header.generation (cast generation : u64)))))))

;: Volatile-wipe `count` words at `data`. The caller owns the region for the
;: whole call; use it for fixed secret scratch outside an owner.
(unsafe
  (define (wipe-words! [data : (MutPtr u64)] [count : i64]) : unit
    (let
      [index : i64 0]
      (while (< index count)
        (unsafe
          (volatile-store! (ptr-offset data index) (cast 0 : u64)))
        (set! index (+ index 1))))))

;: Field cleanup of both owners: poison, wipe the whole capacity and the
;: length, then mark closed. Null, non-live or mismatched-generation handles
;: are no-ops. Check only public metadata before the first mutation.
(define (storage-close [handle : SecretHandle]) : unit
  (if (ptr-null? handle.storage)
    unit
    (let
      [header : SecretStorage
        (unsafe
          (storage-header handle.storage))]
      [words : (MutPtr u64)
        (unsafe
          (ptr-cast handle.storage : (MutPtr u64)))]
      (if (and
        (= header.state (state-live))
        (= header.generation (cast handle.generation : u64)))
        (begin
          (unsafe
            (volatile-store! words (state-poisoned)))
          (unsafe
            (wipe-words!
              (ptr-offset words 4)
              (data-words (cast header.capacity : i64))))
          (unsafe
            (volatile-store! (ptr-offset words 2) (cast 0 : u64)))
          (unsafe
            (volatile-store! words (state-closed))))
        unit))))

;: Copy exact public bytes into fresh storage and publish them.
(unsafe
  (define (storage-from-bytes
    [source : (& source bytes)]
    [capacity : i64]
    [generation : i64]) : (MutPtr SecretStorage)
    (let
      [storage : (MutPtr SecretStorage)
        (unsafe
          (storage-new capacity generation))]
      [data : (MutPtr u8)
        (unsafe
          (storage-data storage))]
      [length : i64 (byte_buf.bytes-length source)]
      [index : i64 0]
      (while (< index length)
        (unsafe
          (ptr-write! (ptr-offset data index) (byte_buf.bytes-ref source index)))
        (set! index (+ index 1)))
      (unsafe
        (storage-set-length! storage length))
      storage)))

;: Initialized length of live storage, or 0 once closed.
(unsafe
  (define (live-length [storage : (MutPtr SecretStorage)] [generation : i64]) : i64
    (if (unsafe
      (storage-live? storage generation))
      (cast
        (unsafe
          (storage-header storage)).length
        : i64)
      0)))

;: Capacity of live storage, or 0 once closed.
(unsafe
  (define (live-capacity [storage : (MutPtr SecretStorage)] [generation : i64]) : i64
    (if (unsafe
      (storage-live? storage generation))
      (cast
        (unsafe
          (storage-header storage)).capacity
        : i64)
      0)))

;: A live all-zero fixed owner of `size`.
(define (fixed-zero [size : SecretSize]) : SecretFixed
  (let
    [length : i64 (size-bytes size)]
    [generation : i64 (next-generation)]
    [storage : (MutPtr SecretStorage)
      (unsafe
        (storage-new length generation))]
    (unsafe
      (storage-set-length! storage length))
    (SecretFixed (SecretHandle storage generation))))

;: A fixed owner copied from exactly `size` public bytes, such as a test
;: vector or protocol constant. A length mismatch allocates nothing.
(define (fixed-from-bytes [size : SecretSize] [source : (& source bytes)]) : SecretFixedResult
  (let
    [length : i64 (size-bytes size)]
    [actual : i64 (byte_buf.bytes-length source)]
    (if (= actual length)
      (let
        [generation : i64 (next-generation)]
        (SecretFixedOk
          (SecretFixed
            (SecretHandle
              (unsafe
                (storage-from-bytes source length generation))
              generation))))
      (SecretFixedErr (SecretLengthMismatch length actual)))))

;: A live empty variable owner with room for `capacity` bytes, checked
;: against `max-capacity` before allocation.
(define (bytes-new [capacity : i64]) : SecretBytesResult
  (if (and (>= capacity 0) (<= capacity (max-capacity)))
    (let
      [generation : i64 (next-generation)]
      (SecretBytesOk
        (SecretBytes
          (SecretHandle
            (unsafe
              (storage-new capacity generation))
            generation))))
    (SecretBytesErr (SecretBadLength capacity))))

;: A variable owner initialized from public bytes, with room for `capacity`.
(define (bytes-from-bytes [source : (& source bytes)] [capacity : i64]) : SecretBytesResult
  (let
    [length : i64 (byte_buf.bytes-length source)]
    (cond
      [(or (< capacity 0) (> capacity (max-capacity)))
        (SecretBytesErr (SecretBadLength capacity))]
      [(> length capacity)
        (SecretBytesErr (SecretLengthMismatch capacity length))]
      [else
        (let
          [generation : i64 (next-generation)]
          (SecretBytesOk
            (SecretBytes
              (SecretHandle
                (unsafe
                  (storage-from-bytes source capacity generation))
                generation))))])))

;: Public length of a live fixed owner, or 0 once its storage is closed.
(define (fixed-length [owner : (& owner SecretFixed)]) : i64
  (unsafe
    (live-length owner.handle.storage owner.handle.generation)))

;: Initialized length of a live variable owner, or 0 once closed.
(define (bytes-length [owner : (& owner SecretBytes)]) : i64
  (unsafe
    (live-length owner.handle.storage owner.handle.generation)))

;: Capacity of a live variable owner, or 0 once closed.
(define (bytes-capacity [owner : (& owner SecretBytes)]) : i64
  (unsafe
    (live-capacity owner.handle.storage owner.handle.generation)))

;: OR of the byte differences over `count` bytes. The loop visits every byte
;: and has no data-dependent branch.
(unsafe
  (define (difference-bits [left : (Ptr u8)] [right : (Ptr u8)] [count : i64]) : u64
    (let
      [different : u64 (cast 0 : u64)]
      [index : i64 0]
      (while (< index count)
        (set!
          different
          (bit-or
            different
            (cast
              (bit-xor
                (unsafe
                  (ptr-read (ptr-offset left index)))
                (unsafe
                  (ptr-read (ptr-offset right index))))
              : u64)))
        (set! index (+ index 1)))
      different)))

;: Compare two live storages of equal public length in fixed work.
(unsafe
  (define (storage-equal
    [left : (MutPtr SecretStorage)]
    [left-generation : i64]
    [right : (MutPtr SecretStorage)]
    [right-generation : i64]) : SecretCompareResult
    (if (and
      (unsafe
        (storage-live? left left-generation))
      (unsafe
        (storage-live? right right-generation)))
      (let
        [left-length : i64
          (unsafe
            (live-length left left-generation))]
        [right-length : i64
          (unsafe
            (live-length right right-generation))]
        (if (= left-length right-length)
          (SecretCompareOk
            (=
              (unsafe
                (difference-bits
                  (ptr-cast (storage-data left) : (Ptr u8))
                  (ptr-cast (storage-data right) : (Ptr u8))
                  left-length))
              (cast 0 : u64)))
          (SecretCompareErr (SecretLengthMismatch left-length right-length))))
      (SecretCompareErr (SecretClosed)))))

;: Compare two live fixed owners of the same size, visiting every byte.
(define (fixed-equal
  [left : (& left SecretFixed)]
  [right : (& right SecretFixed)]) : SecretCompareResult
  (unsafe
    (storage-equal
      left.handle.storage
      left.handle.generation
      right.handle.storage
      right.handle.generation)))

;: Compare two live variable owners of the same initialized length, visiting
;: every byte.
(define (bytes-equal
  [left : (& left SecretBytes)]
  [right : (& right SecretBytes)]) : SecretCompareResult
  (unsafe
    (storage-equal
      left.handle.storage
      left.handle.generation
      right.handle.storage
      right.handle.generation)))

;: All ones when the low bit of `bit` is set, otherwise zero.
(define (mask-u64 [bit : u64]) : u64
  (- (cast 0 : u64) (bit-and bit (cast 1 : u64))))

;: All ones when `value` is nonzero, otherwise zero, without a branch.
(define (nonzero-mask-u64 [value : u64]) : u64
  (mask-u64 (shr (bit-or value (- (cast 0 : u64) value)) (cast 63 : u64))))

;: `a` where `mask` is all ones and `b` where it is zero.
(define (select-u64 [mask : u64] [a : u64] [b : u64]) : u64
  (bit-xor b (bit-and mask (bit-xor a b))))

;: `a` where `mask` is all ones and `b` where it is zero.
(define (select-u32 [mask : u32] [a : u32] [b : u32]) : u32
  (bit-xor b (bit-and mask (bit-xor a b))))

;: `a` where `mask` is all ones and `b` where it is zero.
(define (select-u8 [mask : u8] [a : u8] [b : u8]) : u8
  (bit-xor b (bit-and mask (bit-xor a b))))

;: Exchange `a` and `b` where `mask` is all ones; leave both where it is zero.
(define (swap-u64! [mask : u64] [a : (&mut a u64)] [b : (&mut b u64)]) : unit
  (let
    [delta : u64 (bit-and mask (bit-xor (deref a) (deref b)))]
    (set! (deref a) (bit-xor (deref a) delta))
    (set! (deref b) (bit-xor (deref b) delta))))

;: Exchange `a` and `b` where `mask` is all ones; leave both where it is zero.
(define (swap-u32! [mask : u32] [a : (&mut a u32)] [b : (&mut b u32)]) : unit
  (let
    [delta : u32 (bit-and mask (bit-xor (deref a) (deref b)))]
    (set! (deref a) (bit-xor (deref a) delta))
    (set! (deref b) (bit-xor (deref b) delta))))

;: Exchange `a` and `b` where `mask` is all ones; leave both where it is zero.
(define (swap-u8! [mask : u8] [a : (&mut a u8)] [b : (&mut b u8)]) : unit
  (let
    [delta : u8 (bit-and mask (bit-xor (deref a) (deref b)))]
    (set! (deref a) (bit-xor (deref a) delta))
    (set! (deref b) (bit-xor (deref b) delta))))

;: Check a live range `[offset, offset + count)` within `limit` bytes.
(unsafe
  (define (range-check
    [storage : (MutPtr SecretStorage)]
    [generation : i64]
    [offset : i64]
    [count : i64]
    [limit : i64]) : SecretStatus
    (cond
      [(not
          (unsafe
            (storage-live? storage generation)))
        (SecretErr (SecretClosed))]
      [(or (< offset 0) (< count 0) (> offset limit) (> count (- limit offset)))
        (SecretErr (SecretRange offset count limit))]
      [else (SecretOk)])))

;: A read pointer to `count` initialized bytes at `offset` of a live owner's
;: storage, valid while the owner stays borrowed and live.
(unsafe
  (define (read-pointer
    [storage : (MutPtr SecretStorage)]
    [generation : i64]
    [offset : i64]
    [count : i64]) : SecretReadResult
    (match (unsafe
      (range-check
        storage
        generation
        offset
        count
        (live-length storage generation)))
      [(SecretErr error) (SecretReadErr error)]
      [(SecretOk)
        (SecretReadOk
          (unsafe
            (ptr-cast (ptr-offset (storage-data storage) offset) : (Ptr u8))))])))

;: A write pointer to `count` bytes at `offset` below `limit`.
(unsafe
  (define (write-pointer
    [storage : (MutPtr SecretStorage)]
    [generation : i64]
    [offset : i64]
    [count : i64]
    [limit : i64]) : SecretWriteResult
    (match (unsafe
      (range-check storage generation offset count limit))
      [(SecretErr error) (SecretWriteErr error)]
      [(SecretOk)
        (SecretWriteOk
          (unsafe
            (ptr-offset (storage-data storage) offset)))])))

;: A read pointer to `count` bytes at `offset` of a live fixed owner. It is
;: valid only while `owner` stays borrowed and live.
(unsafe
  (define (fixed-read-pointer
    [owner : (& owner SecretFixed)]
    [offset : i64]
    [count : i64]) : SecretReadResult
    (unsafe
      (read-pointer owner.handle.storage owner.handle.generation offset count))))

;: A write pointer to `count` bytes at `offset` of a live fixed owner.
(unsafe
  (define (fixed-write-pointer
    [owner : (&mut owner SecretFixed)]
    [offset : i64]
    [count : i64]) : SecretWriteResult
    (unsafe
      (write-pointer
        owner.handle.storage
        owner.handle.generation
        offset
        count
        (live-length owner.handle.storage owner.handle.generation)))))

;: A read pointer to `count` initialized bytes at `offset` of a live variable
;: owner.
(unsafe
  (define (bytes-read-pointer
    [owner : (& owner SecretBytes)]
    [offset : i64]
    [count : i64]) : SecretReadResult
    (unsafe
      (read-pointer owner.handle.storage owner.handle.generation offset count))))

;: A write pointer to `count` bytes at `offset` within the capacity of a live
;: variable owner. Publish the written bytes with `bytes-set-length!`.
(unsafe
  (define (bytes-write-pointer
    [owner : (&mut owner SecretBytes)]
    [offset : i64]
    [count : i64]) : SecretWriteResult
    (unsafe
      (write-pointer
        owner.handle.storage
        owner.handle.generation
        offset
        count
        (live-capacity owner.handle.storage owner.handle.generation)))))

;: Set the initialized length of a live variable owner after a sink write.
;: Shrinking zeroes the released bytes, so bytes past the length stay zero.
(unsafe
  (define (bytes-set-length! [owner : (&mut owner SecretBytes)] [length : i64]) : SecretStatus
    (match (unsafe
      (range-check
        owner.handle.storage
        owner.handle.generation
        0
        length
        (live-capacity owner.handle.storage owner.handle.generation)))
      [(SecretErr error) (SecretErr error)]
      [(SecretOk)
        (let
          [data : (MutPtr u8)
            (unsafe
              (storage-data owner.handle.storage))]
          [index : i64 length]
          (while (<
            index
            (unsafe
              (live-length owner.handle.storage owner.handle.generation)))
            (unsafe
              (ptr-write! (ptr-offset data index) (cast 0 : u8)))
            (set! index (+ index 1)))
          (unsafe
            (storage-set-length! owner.handle.storage length))
          (SecretOk))])))

;: Copy a validated public count. Neither addresses nor control depend on a
;: secret byte. The caller has rejected every alias before entering this loop.
(unsafe
  (define (copy-secret-range!
    [source : (Ptr u8)]
    [destination : (MutPtr u8)]
    [count : i64]) : unit
    (let
      [index : i64 0]
      (while (< index count)
        (unsafe
          (ptr-write!
            (ptr-offset destination index)
            (ptr-read (ptr-offset source index))))
        (set! index (+ index 1))))))

;: Preflight both complete ranges before reading or changing secret bytes.
;: expected=0 admits a variable source; otherwise its fixed length is exact.
(unsafe
  (define (storage-copy-range!
    [source : (& source SecretHandle)]
    [expected : i64]
    [source-offset : i64]
    [destination : (& destination SecretHandle)]
    [destination-offset : i64]
    [count : i64]) : SecretStatus
    (cond
      [(not
          (and
            (unsafe
              (storage-live? source.storage source.generation))
            (unsafe
              (storage-live? destination.storage destination.generation))))
        (SecretErr (SecretClosed))]
      [else
        (let
          [source-length : i64
            (unsafe
              (live-length source.storage source.generation))]
          [destination-length : i64
            (unsafe
              (live-length destination.storage destination.generation))]
          [capacity : i64
            (unsafe
              (live-capacity destination.storage destination.generation))]
          (cond
            [(and (> expected 0) (not (= source-length expected)))
              (SecretErr (SecretLengthMismatch expected source-length))]
            [(and
                (> expected 0)
                (not
                  (=
                    (unsafe
                      (live-capacity source.storage source.generation))
                    expected)))
              (SecretErr
                (SecretLengthMismatch
                  expected
                  (unsafe
                    (live-capacity source.storage source.generation))))]
            [(or
                (< source-offset 0)
                (< count 0)
                (> source-offset source-length)
                (> count (- source-length source-offset)))
              (SecretErr (SecretRange source-offset count source-length))]
            [(or
                (< destination-offset 0)
                (> destination-offset capacity)
                (> count (- capacity destination-offset)))
              (SecretErr (SecretRange destination-offset count capacity))]
            [else
              (let
                [source-data : (Ptr u8)
                  (unsafe
                    (ptr-cast
                      (ptr-offset (storage-data source.storage) source-offset)
                      : (Ptr u8)))]
                [destination-data : (MutPtr u8)
                  (unsafe
                    (ptr-offset
                      (storage-data destination.storage)
                      destination-offset))]
                [source-address : u64
                  (unsafe
                    (ptr->int source-data))]
                [destination-address : u64
                  (unsafe
                    (ptr->int destination-data))]
                [overlap : bool
                  (if (<= source-address destination-address)
                    (<
                      (- destination-address source-address)
                      (cast count : u64))
                    (<
                      (- source-address destination-address)
                      (cast count : u64)))]
                (if (or (= source.storage destination.storage) overlap)
                  (SecretErr (SecretAlias))
                  (let
                    [end : i64 (+ destination-offset count)]
                    (unsafe
                      (copy-secret-range! source-data destination-data count))
                    (when
                      (> end destination-length)
                      (unsafe
                        (storage-set-length! destination.storage end)))
                    (SecretOk))))]))])))

;: Copy from an exact fixed source into a variable owner. Offsets and count
;: are public. Failure preserves all destination bytes and its length.
(define (fixed-copy-range!
  [source : (& source SecretFixed)]
  [size : SecretSize]
  [source-offset : i64]
  [destination : (&mut destination SecretBytes)]
  [destination-offset : i64]
  [count : i64]) : SecretStatus
  (unsafe
    (storage-copy-range!
      (& source.handle)
      (size-bytes size)
      source-offset
      (& destination.handle)
      destination-offset
      count)))

;: Copy an initialized variable-secret range without producing a byte view.
;: Same-storage copies are intentionally rejected even for count=0 or disjoint
;: ranges; exact and partial address overlap are also rejected before mutation.
;: Success publishes max(previous-length, destination-offset + count).
(define (bytes-copy-range!
  [source : (& source SecretBytes)]
  [source-offset : i64]
  [destination : (&mut destination SecretBytes)]
  [destination-offset : i64]
  [count : i64]) : SecretStatus
  (unsafe
    (storage-copy-range!
      (& source.handle)
      0
      source-offset
      (& destination.handle)
      destination-offset
      count)))

;: Live outer identity, checked without reading the secret allocation.
(unsafe
  (define (nominal-live? [handle : (& handle SecretNominalHandle)]) : bool
    (and
      (not (ptr-null? handle.storage))
      (unsafe
        (= (deref handle.storage).state (state-live)))
      (unsafe
        (= (deref handle.storage).generation handle.generation)))))

;: Poison the outer allocation before invoking the inner owner's cleanup.
;: A repeated, closed or stale outer handle cannot invoke that cleanup again.
(define (nominal-handle-close [handle : SecretNominalHandle]) : unit
  (when
    (unsafe
      (nominal-live? (& handle)))
    (let
      [inner : SecretHandle
        (unsafe
          (deref handle.storage).inner)]
      [words : (MutPtr u64)
        (unsafe
          (ptr-cast handle.storage : (MutPtr u64)))]
      (unsafe
        (volatile-store! words (state-poisoned)))
      (close-fixed (SecretFixed inner))
      (unsafe
        (volatile-store! words (state-closed))))))

;: Move one exact live fixed owner into nominal state without copying bytes.
;: This is an unsafe immediate-call boundary: only the consuming crypto
;: implementation may assert that an arbitrary fixed value has its nominal
;: protocol meaning. All pre-transfer handles become stale. Failure consumes
;: and cleans the input, allocating no outer state.
(unsafe
  (define (transfer-fixed-input
    [input : SecretTransferInput]
    [size : SecretSize]) : SecretNominalResult
    (let
      [owner : SecretFixed input.value]
      [handle : SecretHandle owner.handle]
      [expected : i64 (size-bytes size)]
      [actual : i64 (fixed-length (& owner))]
      (cond
        [(not
          (unsafe
            (storage-live? handle.storage handle.generation)))
          (close-fixed owner)
          (SecretNominalErr (SecretClosed))]
        [(not (= actual expected))
          (close-fixed owner)
          (SecretNominalErr (SecretLengthMismatch expected actual))]
        [(not
            (=
              (unsafe
                (live-capacity handle.storage handle.generation))
              expected))
          (let
            [capacity : i64
              (unsafe
                (live-capacity handle.storage handle.generation))]
            (close-fixed owner)
            (SecretNominalErr (SecretLengthMismatch expected capacity)))]
        [else
          (let
            [generation : i64 (next-generation)]
            [header : SecretStorage
              (unsafe
                (storage-header handle.storage))]
            [storage : (MutPtr SecretNominalStorage)
              (unsafe
                (ptr-cast
                  (secret-runtime-alloc
                    (comptime (size-of (type SecretNominalStorage))))
                  : (MutPtr SecretNominalStorage)))]
            (unsafe
              (ptr-write!
                handle.storage
                (SecretStorage
                  header.state
                  (cast generation : u64)
                  header.length
                  header.capacity)))
            (unsafe
              (ptr-write!
                storage
                (SecretNominalStorage
                  (state-live)
                  generation
                  (SecretHandle handle.storage generation))))
            (close-fixed owner)
            (SecretNominalOk
              (SecretNominal (SecretNominalHandle storage generation))))]))))

;: Consume a fixed owner into the unsafe immediate-call transfer operation.
;: The expansion deliberately retains the caller's unsafe-context requirement.
(defmacro (transfer-fixed [owner : Expr] [size : Expr]) : SecretNominalResult
  `(transfer-fixed-input (SecretTransferInput ,owner) ,size))

;: Direct checked access for a crypto implementation borrowing nominal state.
;: No safe view or first-class raw-pointer callable is produced.
(unsafe
  (define (nominal-read-pointer
    [owner : (& owner SecretNominal)]
    [offset : i64]
    [count : i64]) : SecretReadResult
    (if (unsafe
      (nominal-live? (& owner.handle)))
      (let
        [inner : SecretHandle
          (unsafe
            (deref owner.handle.storage).inner)]
        (unsafe
          (read-pointer inner.storage inner.generation offset count)))
      (SecretReadErr (SecretClosed)))))