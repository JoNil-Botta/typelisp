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
;# closing again does nothing.
;#
;# The fixed-work helpers compare equal public lengths by visiting every byte
;# and select or swap through masks, with no branch or table lookup on secret
;# data. Crypto code reads and writes an exact checked range through the
;# `unsafe` pointer accessors, which check liveness, generation, offset and
;# count before returning.
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
  (SecretRange i64 i64 i64))

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

;: Exactly `size` secret bytes. Construct with `fixed-zero` or
;: `fixed-from-bytes`. The fields are not a capability: safe code can read
;: neither the storage nor a byte of the secret through them.
(defstruct SecretFixed
  (:cleanup close-fixed)
  (storage (MutPtr SecretStorage) (:cleanup storage-close))
  (generation i64))

;: A bounded secret buffer whose initialized length is tracked exactly.
;: Construct with `bytes-new` or `bytes-from-bytes`.
(defstruct SecretBytes
  (:cleanup close-bytes)
  (storage (MutPtr SecretStorage) (:cleanup storage-close))
  (generation i64))

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
;: length, then mark closed. Null or non-live storage is left untouched, so
;: closing twice does nothing.
(define (storage-close [storage : (MutPtr SecretStorage)]) : unit
  (if (ptr-null? storage)
    unit
    (let
      [header : SecretStorage
        (unsafe
          (storage-header storage))]
      [words : (MutPtr u64)
        (unsafe
          (ptr-cast storage : (MutPtr u64)))]
      (if (= header.state (state-live))
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
    (SecretFixed storage generation)))

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
            (unsafe
              (storage-from-bytes source length generation))
            generation)))
      (SecretFixedErr (SecretLengthMismatch length actual)))))

;: A live empty variable owner with room for `capacity` bytes, checked
;: against `max-capacity` before allocation.
(define (bytes-new [capacity : i64]) : SecretBytesResult
  (if (and (>= capacity 0) (<= capacity (max-capacity)))
    (let
      [generation : i64 (next-generation)]
      (SecretBytesOk
        (SecretBytes
          (unsafe
            (storage-new capacity generation))
          generation)))
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
              (unsafe
                (storage-from-bytes source capacity generation))
              generation)))])))

;: Public length of a live fixed owner, or 0 once its storage is closed.
(define (fixed-length [owner : (& owner SecretFixed)]) : i64
  (unsafe
    (live-length owner.storage owner.generation)))

;: Initialized length of a live variable owner, or 0 once closed.
(define (bytes-length [owner : (& owner SecretBytes)]) : i64
  (unsafe
    (live-length owner.storage owner.generation)))

;: Capacity of a live variable owner, or 0 once closed.
(define (bytes-capacity [owner : (& owner SecretBytes)]) : i64
  (unsafe
    (live-capacity owner.storage owner.generation)))

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
    (storage-equal left.storage left.generation right.storage right.generation)))

;: Compare two live variable owners of the same initialized length, visiting
;: every byte.
(define (bytes-equal
  [left : (& left SecretBytes)]
  [right : (& right SecretBytes)]) : SecretCompareResult
  (unsafe
    (storage-equal left.storage left.generation right.storage right.generation)))

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
      (read-pointer owner.storage owner.generation offset count))))

;: A write pointer to `count` bytes at `offset` of a live fixed owner.
(unsafe
  (define (fixed-write-pointer
    [owner : (&mut owner SecretFixed)]
    [offset : i64]
    [count : i64]) : SecretWriteResult
    (unsafe
      (write-pointer
        owner.storage
        owner.generation
        offset
        count
        (live-length owner.storage owner.generation)))))

;: A read pointer to `count` initialized bytes at `offset` of a live variable
;: owner.
(unsafe
  (define (bytes-read-pointer
    [owner : (& owner SecretBytes)]
    [offset : i64]
    [count : i64]) : SecretReadResult
    (unsafe
      (read-pointer owner.storage owner.generation offset count))))

;: A write pointer to `count` bytes at `offset` within the capacity of a live
;: variable owner. Publish the written bytes with `bytes-set-length!`.
(unsafe
  (define (bytes-write-pointer
    [owner : (&mut owner SecretBytes)]
    [offset : i64]
    [count : i64]) : SecretWriteResult
    (unsafe
      (write-pointer
        owner.storage
        owner.generation
        offset
        count
        (live-capacity owner.storage owner.generation)))))

;: Set the initialized length of a live variable owner after a sink write.
;: Shrinking zeroes the released bytes, so bytes past the length stay zero.
(unsafe
  (define (bytes-set-length! [owner : (&mut owner SecretBytes)] [length : i64]) : SecretStatus
    (match (unsafe
      (range-check
        owner.storage
        owner.generation
        0
        length
        (live-capacity owner.storage owner.generation)))
      [(SecretErr error) (SecretErr error)]
      [(SecretOk)
        (let
          [data : (MutPtr u8)
            (unsafe
              (storage-data owner.storage))]
          [index : i64 length]
          (while (<
            index
            (unsafe
              (live-length owner.storage owner.generation)))
            (unsafe
              (ptr-write! (ptr-offset data index) (cast 0 : u8)))
            (set! index (+ index 1)))
          (unsafe
            (storage-set-length! owner.storage length))
          (SecretOk))])))