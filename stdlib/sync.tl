;# stdlib/sync.tl - Safe synchronization helpers over the raw thread substrate.
;#
;# Provides first concrete synchronization surfaces for native threads:
;# `ChannelI64` for copyable scalar ownership transfer, `ChannelI64PairChannel`
;# for a move-based two-field aggregate channel, `ChannelString` for atomic
;# arena-owned text messages, and `MutexI64` for shared scalar mutation through a
;# lexical cleanup guard. Handles are small copyable values; shared state lives
;# in runtime-owned OS memory and is serialized with semaphore-backed
;# synchronization.
;#
;# `ChannelString` accepts heap-backed messages only when their storage is owned
;# by a spanning atomic arena. `MutexI64` makes the protected scalar race-free
;# only while mutation goes through its lexical guard; atomic arena allocation
;# alone does not protect ordinary mutable storage.
;#
;# Usage: `(import stdlib.sync)`
;#
;# ```typelisp
;# (import stdlib.sync)
;#
;# (define ok : bool
;#   (match (sync.channel-i64-create 2)
;#     [(sync.ChannelI64CreateErr _) false]
;#     [(sync.ChannelI64CreateOk ch)
;#       (begin
;#         (sync.channel-i64-close ch)
;#         true)]))
;# ```
(module stdlib.sync)

(import stdlib.thread)

;: Maximum supported channel capacity for this first concrete channel surface.
(define channel-i64-max-capacity : i64
  1048576)

;: Number of raw `i64` fields needed to serialize a `ChannelI64` handle.
(define channel-i64-raw-field-count : i64
  7)

;: Number of raw `i64` fields needed to serialize a `ChannelI64PairChannel`.
(define channel-i64-pair-raw-field-count : i64
  7)

;: Number of raw `i64` fields needed to serialize a `ChannelString`.
(define channel-string-raw-field-count : i64
  7)

;: Number of raw `i64` fields needed to serialize a `MutexI64` handle.
(define mutex-i64-raw-field-count : i64
  3)

;: Runtime-owned bytes for the close-state/live-user control cell.
(define mutex-i64-control-byte-count : i64
  16)

;: Control slot set to nonzero after a mutex has been permanently closed.
(define mutex-i64-control-closed-slot : i64
  0)

;: Control slot tracking live lock attempts and cleanup-owned guards.
(define mutex-i64-control-users-slot : i64
  1)

;: Negative live-user delta used to claim close without a compare-exchange.
(define mutex-i64-users-closing-delta : i64
  -1073741824)

;: Positive inverse of `mutex-i64-users-closing-delta`.
(define mutex-i64-users-closing-undo : i64
  1073741824)

;: Runtime-owned mutex-protected `i64` slot.
(defstruct MutexI64
  (value-addr i64)
  (mutex-handle i64)
  (control-addr i64))

;: Runtime-owned bounded channel handle for `i64` messages.
(defstruct ChannelI64
  (slots-addr i64)
  (state-addr i64)
  (capacity i64)
  (slots-bytes i64)
  (mutex-handle i64)
  (items-handle i64)
  (spaces-handle i64))

;: Move-transferred two-field aggregate message for `ChannelI64PairChannel`.
(defstruct ChannelI64Pair
  (left i64)
  (right i64))

;: Runtime-owned bounded channel handle for `ChannelI64Pair` messages.
(defstruct ChannelI64PairChannel
  (slots-addr i64)
  (state-addr i64)
  (capacity i64)
  (slots-bytes i64)
  (mutex-handle i64)
  (items-handle i64)
  (spaces-handle i64))

;: Runtime-owned bounded channel handle for `String` messages.
(defstruct ChannelString
  (slots-addr i64)
  (state-addr i64)
  (capacity i64)
  (slots-bytes i64)
  (mutex-handle i64)
  (items-handle i64)
  (spaces-handle i64))

;: Result returned by `channel-i64-create`.
(defenum ChannelI64CreateResult
  (ChannelI64CreateOk ChannelI64)
  (ChannelI64CreateErr i64))

;: Result returned by `channel-i64-pair-create`.
(defenum ChannelI64PairCreateResult
  (ChannelI64PairCreateOk ChannelI64PairChannel)
  (ChannelI64PairCreateErr i64))

;: Result returned by `channel-string-create`.
(defenum ChannelStringCreateResult
  (ChannelStringCreateOk ChannelString)
  (ChannelStringCreateErr i64))

;: Result returned by `mutex-i64-create`.
(defenum MutexI64CreateResult
  (MutexI64CreateOk MutexI64)
  (MutexI64CreateErr i64))

;: Result returned by `channel-i64-send`.
(defenum ChannelI64SendResult
  (ChannelI64SendOk)
  (ChannelI64SendErr i64))

;: Result returned by `channel-i64-pair-send`.
(defenum ChannelI64PairSendResult
  (ChannelI64PairSendOk)
  (ChannelI64PairSendErr i64))

;: Result returned by `channel-string-send`.
(defenum ChannelStringSendResult
  (ChannelStringSendOk)
  (ChannelStringSendErr i64))

;: Result returned by `channel-i64-recv`.
(defenum ChannelI64RecvResult
  (ChannelI64RecvOk i64)
  (ChannelI64RecvErr i64))

;: Result returned by `channel-i64-pair-recv`.
(defenum ChannelI64PairRecvResult
  (ChannelI64PairRecvOk ChannelI64Pair)
  (ChannelI64PairRecvErr i64))

;: Result returned by `channel-string-recv`.
(defenum ChannelStringRecvResult
  (ChannelStringRecvOk String)
  (ChannelStringRecvErr i64))

(define (channel-i64-send-ok-result) : ChannelI64SendResult
  ChannelI64SendOk)

(define (channel-i64-send-err-result [_message : String]) : ChannelI64SendResult
  (ChannelI64SendErr 1))

(define (channel-i64-pair-send-ok-result) : ChannelI64PairSendResult
  ChannelI64PairSendOk)

(define (channel-i64-pair-send-err-result [_message : String]) : ChannelI64PairSendResult
  (ChannelI64PairSendErr 1))

(define (channel-string-send-ok-result) : ChannelStringSendResult
  ChannelStringSendOk)

(define (channel-string-send-err-result [_message : String]) : ChannelStringSendResult
  (ChannelStringSendErr 1))

(define (channel-i64-recv-ok-result [value : i64]) : ChannelI64RecvResult
  (ChannelI64RecvOk value))

(define (channel-i64-recv-err-result [_message : String]) : ChannelI64RecvResult
  (ChannelI64RecvErr 1))

(define (channel-i64-pair-recv-ok-result [value : ChannelI64Pair]) : ChannelI64PairRecvResult
  (ChannelI64PairRecvOk value))

(define (channel-i64-pair-recv-err-result [_message : String]) : ChannelI64PairRecvResult
  (ChannelI64PairRecvErr 1))

(define (channel-string-recv-err-result [_message : String]) : ChannelStringRecvResult
  (ChannelStringRecvErr 1))

(define (channel-i64-create-ok-result [value : ChannelI64]) : ChannelI64CreateResult
  (ChannelI64CreateOk value))

(define (channel-i64-create-err-result [_message : String]) : ChannelI64CreateResult
  (ChannelI64CreateErr 1))

(define (channel-i64-pair-create-ok-result [value : ChannelI64PairChannel]) : ChannelI64PairCreateResult
  (ChannelI64PairCreateOk value))

(define (channel-i64-pair-create-err-result [_message : String]) : ChannelI64PairCreateResult
  (ChannelI64PairCreateErr 1))

(define (channel-string-create-ok-result [value : ChannelString]) : ChannelStringCreateResult
  (ChannelStringCreateOk value))

(define (channel-string-create-err-result [_message : String]) : ChannelStringCreateResult
  (ChannelStringCreateErr 1))

(define (mutex-i64-create-ok-result [value : MutexI64]) : MutexI64CreateResult
  (MutexI64CreateOk value))

(define (mutex-i64-create-err-result [_message : String]) : MutexI64CreateResult
  (MutexI64CreateErr 1))

;: Windows kernel32 `VirtualAlloc` for runtime-owned channel storage.
(cfg
  windows
  (extern (sync-windows-virtual-alloc
    [address : i64]
    [size : i64]
    [allocation-type : i32]
    [protect : i32]) : i64 (:symbol "VirtualAlloc")))

;: Windows kernel32 `VirtualFree` for runtime-owned channel storage.
(cfg
  windows
  (extern (sync-windows-virtual-free
    [address : i64]
    [size : i64]
    [free-type : i32]) : i32 (:symbol "VirtualFree")))

;: Windows process exit for unrecoverable synchronization misuse.
(cfg
  windows
  (extern (sync-windows-exit-process [code : i32]) : never (:symbol "ExitProcess")))

;: Abort the process on impossible safe-surface lock failures.
(define (sync-abort [code : i64]) : never
  (cfg
    windows
    (sync-windows-exit-process (cast code : i32))
    (begin
      (unsafe
        (syscall 231 code))
      (sync-abort code))))

;: Allocate runtime-owned memory that is independent of TypeLisp arenas.
(define (sync-runtime-alloc [bytes : i64]) : i64
  (if (<= bytes 0)
    0
    (cfg
      windows
      (sync-windows-virtual-alloc 0 bytes (cast 12288 : i32) (cast 4 : i32))
      (let
        [addr : i64
          (unsafe
            (syscall 9 0 bytes 3 34 -1 0))]
        (if (< addr 0)
          0
          addr)))))

;: Release runtime-owned memory allocated by `sync-runtime-alloc`.
(define (sync-runtime-free [addr : i64] [bytes : i64]) : bool
  (if (or (= addr 0) (<= bytes 0))
    true
    (cfg
      windows
      (not
        (= (sync-windows-virtual-free addr 0 (cast 32768 : i32)) (cast 0 : i32)))
      (=
        (unsafe
          (syscall 11 addr bytes))
        0))))

;: Convert an integer address into a mutable `i64` pointer.
(define (sync-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

;: Convert an integer address into a mutable `String` pointer.
(define (sync-addr->mut-string [addr : i64]) : (MutPtr String)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr String))))

;: Sequentially consistent atomic load of one raw `i64` pointer.
(extern (sync-atomic-i64-load-ptr [ptr : (Ptr i64)]) : i64 (:symbol "tl_atomic_i64_load_ptr"))

;: Sequentially consistent atomic store of one raw `i64` pointer.
(extern (sync-atomic-i64-store-ptr! [ptr : (MutPtr i64)] [value : i64]) : unit (:symbol "tl_atomic_i64_store_ptr"))

;: Sequentially consistent atomic add of one raw `i64` pointer.
(extern (sync-atomic-i64-add-ptr! [ptr : (MutPtr i64)] [delta : i64]) : unit (:symbol "tl_atomic_i64_add_ptr"))

;: Sequentially consistent atomic fetch-add of one raw `i64` pointer.
(extern (sync-atomic-i64-fetch-add-ptr! [ptr : (MutPtr i64)] [delta : i64]) : i64 (:symbol "tl_atomic_i64_fetch_add_ptr"))

;: Sequentially consistent compare-exchange of one raw `i64` pointer. Returns
;: the previous value observed at `ptr`.
(extern (sync-atomic-i64-cas-ptr!
  [ptr : (MutPtr i64)]
  [expected : i64]
  [new-value : i64]) : i64 (:symbol "tl_atomic_i64_cas_ptr"))

;: Convert an integer address and slot into a mutable `i64` pointer.
(define (sync-addr-slot->mut-i64 [addr : i64] [slot : i64]) : (MutPtr i64)
  (unsafe
    (ptr-offset (sync-addr->mut-i64 addr) slot)))

;: Convert an integer address and slot into an immutable `i64` pointer.
(define (sync-addr-slot->i64 [addr : i64] [slot : i64]) : (Ptr i64)
  (unsafe
    (ptr-cast (sync-addr-slot->mut-i64 addr slot) : (Ptr i64))))

;: Sequentially consistent atomic load of one runtime-owned `i64` slot.
(define (sync-atomic-i64-load [addr : i64] [slot : i64]) : i64
  (sync-atomic-i64-load-ptr (sync-addr-slot->i64 addr slot)))

;: Sequentially consistent atomic store of one runtime-owned `i64` slot.
(define (sync-atomic-i64-store! [addr : i64] [slot : i64] [value : i64]) : unit
  (sync-atomic-i64-store-ptr! (sync-addr-slot->mut-i64 addr slot) value))

;: Sequentially consistent atomic add of one runtime-owned `i64` slot.
(define (sync-atomic-i64-add! [addr : i64] [slot : i64] [delta : i64]) : unit
  (sync-atomic-i64-add-ptr! (sync-addr-slot->mut-i64 addr slot) delta))

;: Sequentially consistent atomic fetch-add of one runtime-owned `i64` slot.
(define (sync-atomic-i64-fetch-add! [addr : i64] [slot : i64] [delta : i64]) : i64
  (sync-atomic-i64-fetch-add-ptr! (sync-addr-slot->mut-i64 addr slot) delta))

;: Sequentially consistent compare-exchange of one runtime-owned `i64` slot.
;: Returns the previous value observed in the slot.
(define (sync-atomic-i64-cas!
  [addr : i64]
  [slot : i64]
  [expected : i64]
  [new-value : i64]) : i64
  (sync-atomic-i64-cas-ptr!
    (sync-addr-slot->mut-i64 addr slot)
    expected
    new-value))

;: Read one `i64` slot from runtime-owned storage.
(define (sync-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (sync-addr->mut-i64 addr) slot) : (Ptr i64)))))

;: Write one `i64` slot into runtime-owned storage.
(define (sync-write-i64! [addr : i64] [slot : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (sync-addr->mut-i64 addr) slot) value)))

;: Read one `String` slot from runtime-owned storage.
(define (sync-read-string [addr : i64] [slot : i64]) : String
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (sync-addr->mut-string addr) slot) : (Ptr String)))))

;: Write one `String` slot into runtime-owned storage.
(define (sync-write-string! [addr : i64] [slot : i64] [value : String]) : unit
  (unsafe
    (ptr-write! (ptr-offset (sync-addr->mut-string addr) slot) value)))

;: Wrap a raw semaphore handle for calls into `thread.tl`.
(define (sync-semaphore [handle : i64]) : thread.ThreadSemaphore
  (thread.ThreadSemaphore handle))

;: Wait for a channel semaphore token.
(define (sync-semaphore-wait [handle : i64]) : bool
  (thread.thread-semaphore-wait (sync-semaphore handle)))

;: Post one channel semaphore token.
(define (sync-semaphore-post [handle : i64]) : bool
  (thread.thread-semaphore-post (sync-semaphore handle)))

;: Close one channel semaphore handle.
(define (sync-semaphore-close [handle : i64]) : bool
  (thread.thread-semaphore-close (sync-semaphore handle)))

;: Unlock a mutex guard field during cleanup.
(define (mutex-i64-unlock-handle [handle : i64]) : unit
  (begin
    (sync-semaphore-post handle)
    unit))

;: Stop tracking one live lock attempt or guard during cleanup.
(define (mutex-i64-untrack-user [control-addr : i64]) : unit
  (begin
    (sync-atomic-i64-fetch-add! control-addr mutex-i64-control-users-slot -1)
    unit))

;: Track one live lock attempt before touching the semaphore/value fields.
(define (mutex-i64-track-user [control-addr : i64]) : i64
  (sync-atomic-i64-fetch-add! control-addr mutex-i64-control-users-slot 1))

;: Return true once `mutex` has permanently closed its semaphore/value fields.
(define (mutex-i64-closed? [control-addr : i64]) : bool
  (not (= (sync-atomic-i64-load control-addr mutex-i64-control-closed-slot) 0)))

;: Abort a failed lock attempt after removing its live-user claim.
(define (mutex-i64-lock-abort [control-addr : i64]) : never
  (begin
    (mutex-i64-untrack-user control-addr)
    (sync-abort 134)))

;: Lexical guard returned by `mutex-i64-lock`.
(defstruct MutexI64Guard
  (:cleanup mutex-i64-unlock)
  ; Field cleanups run in reverse declaration order, so post before untrack.
  (control-addr i64 (:cleanup mutex-i64-untrack-user))
  (mutex-handle i64 (:cleanup mutex-i64-unlock-handle))
  (value-addr i64))

;: Finish mutex creation after storage allocation.
(define (mutex-i64-create-semaphore [value-addr : i64] [control-addr : i64]) : MutexI64CreateResult
  (let
    [mutex-handle : i64 (thread.thread-semaphore-create-handle-or 1 -1)]
    (if (= mutex-handle -1)
      (begin
        (sync-runtime-free value-addr 8)
        (sync-runtime-free control-addr mutex-i64-control-byte-count)
        (mutex-i64-create-err-result "sync: semaphore create failed"))
      (mutex-i64-create-ok-result
        (MutexI64 value-addr mutex-handle control-addr)))))

;: Create a mutex-protected `i64` initialized to `initial`.
(define (mutex-i64-create [initial : i64]) : MutexI64CreateResult
  (let
    [value-addr : i64 (sync-runtime-alloc 8)]
    (if (= value-addr 0)
      (mutex-i64-create-err-result "sync: mutex allocation failed")
      (let
        [control-addr : i64 (sync-runtime-alloc mutex-i64-control-byte-count)]
        (if (= control-addr 0)
          (begin
            (sync-runtime-free value-addr 8)
            (mutex-i64-create-err-result "sync: mutex allocation failed"))
          (begin
            (sync-write-i64! value-addr 0 initial)
            (sync-write-i64! control-addr mutex-i64-control-closed-slot 0)
            (sync-write-i64! control-addr mutex-i64-control-users-slot 0)
            (mutex-i64-create-semaphore value-addr control-addr)))))))

;: Lock `mutex`, blocking until the protected value is available.
(define (mutex-i64-lock [mutex : MutexI64]) : MutexI64Guard
  (let
    [control-addr : i64 (struct-get mutex control-addr)]
    [mutex-handle : i64 (struct-get mutex mutex-handle)]
    [value-addr : i64 (struct-get mutex value-addr)]
    (if (mutex-i64-closed? control-addr)
      (sync-abort 134)
      (let
        [previous-users : i64 (mutex-i64-track-user control-addr)]
        (if (< previous-users 0)
          (begin
            (mutex-i64-untrack-user control-addr)
            (mutex-i64-lock mutex))
          (if (sync-semaphore-wait mutex-handle)
            (MutexI64Guard control-addr mutex-handle value-addr)
            (mutex-i64-lock-abort control-addr)))))))

;: Return the control cell address from a mutex guard.
(define (mutex-i64-guard-control-addr [guard : (& guard MutexI64Guard)]) : i64
  (struct-get guard control-addr))

;: Return the semaphore handle from a mutex guard.
(define (mutex-i64-guard-mutex-handle [guard : (& guard MutexI64Guard)]) : i64
  (struct-get guard mutex-handle))

;: Return the protected value address from a mutex guard.
(define (mutex-i64-guard-value-addr [guard : (& guard MutexI64Guard)]) : i64
  (struct-get guard value-addr))

;: Read the protected value while holding `guard`.
(define (mutex-i64-get [guard : (& guard MutexI64Guard)]) : i64
  (sync-read-i64 (struct-get guard value-addr) 0))

;: Write the protected value while holding `guard`.
(define (mutex-i64-set! [guard : (& guard MutexI64Guard)] [value : i64]) : unit
  (sync-write-i64! (struct-get guard value-addr) 0 value))

;: Add `delta` to the protected value and return the new value.
(define (mutex-i64-add! [guard : (& guard MutexI64Guard)] [delta : i64]) : i64
  (let
    [next : i64 (+ (mutex-i64-get guard) delta)]
    (begin
      (mutex-i64-set! guard next)
      next)))

;: Close mutex resources if no users or guards are live.
;:
;: The small control cell is retained so copied handles can fail closed instead
;: of touching freed semaphore/value storage after a successful close.
(define (mutex-i64-close [mutex : MutexI64]) : bool
  (let
    [control-addr : i64 (struct-get mutex control-addr)]
    (if (mutex-i64-closed? control-addr)
      false
      (if (=
        (sync-atomic-i64-fetch-add!
          control-addr
          mutex-i64-control-users-slot
          mutex-i64-users-closing-delta)
        0)
        (let
          [ok : bool true]
          (begin
            (sync-atomic-i64-store!
              control-addr
              mutex-i64-control-closed-slot
              1)
            (set!
              ok
              (if (sync-semaphore-close (struct-get mutex mutex-handle))
                ok
                false))
            (set!
              ok
              (if (sync-runtime-free (struct-get mutex value-addr) 8)
                ok
                false))
            ok))
        (begin
          (sync-atomic-i64-fetch-add!
            control-addr
            mutex-i64-control-users-slot
            mutex-i64-users-closing-undo)
          false)))))

;: Store a mutex handle into a raw `i64` array at `offset`.
(define (mutex-i64-store-raw!
  [mutex : MutexI64]
  [dst : (Array i64)]
  [offset : i64]) : unit
  (begin
    (array-set! dst offset (struct-get mutex value-addr))
    (array-set! dst (+ offset 1) (struct-get mutex mutex-handle))
    (array-set! dst (+ offset 2) (struct-get mutex control-addr))))

;: Rebuild a mutex handle from a raw `i64` array at `offset`.
(define (mutex-i64-load-raw [src : (Array i64)] [offset : i64]) : MutexI64
  (MutexI64
    (array-ref src offset)
    (array-ref src (+ offset 1))
    (array-ref src (+ offset 2))))

;: Return the next ring index for a channel with `capacity`.
(define (channel-i64-next-index [capacity : i64] [index : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next capacity)
      0
      next)))

;: Build a channel handle from allocated storage and semaphore handles.
(define (channel-i64-handle
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]
  [mutex : thread.ThreadSemaphore]
  [items : thread.ThreadSemaphore]
  [spaces : thread.ThreadSemaphore]) : ChannelI64
  (ChannelI64
    slots-addr
    state-addr
    capacity
    slots-bytes
    (struct-get mutex handle)
    (struct-get items handle)
    (struct-get spaces handle)))

;: Finish channel creation after storage allocation.
(define (channel-i64-create-semaphores
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]) : ChannelI64CreateResult
  (let
    [mutex-handle : i64 (thread.thread-semaphore-create-handle-or 1 -1)]
    (if (= mutex-handle -1)
      (begin
        (sync-runtime-free slots-addr slots-bytes)
        (sync-runtime-free state-addr 16)
        (channel-i64-create-err-result "sync: semaphore create failed"))
      (let
        [items-handle : i64 (thread.thread-semaphore-create-handle-or 0 -1)]
        (if (= items-handle -1)
          (begin
            (sync-semaphore-close mutex-handle)
            (sync-runtime-free slots-addr slots-bytes)
            (sync-runtime-free state-addr 16)
            (channel-i64-create-err-result "sync: semaphore create failed"))
          (let
            [spaces-handle : i64
              (thread.thread-semaphore-create-handle-or capacity -1)]
            (if (= spaces-handle -1)
              (begin
                (sync-semaphore-close mutex-handle)
                (sync-semaphore-close items-handle)
                (sync-runtime-free slots-addr slots-bytes)
                (sync-runtime-free state-addr 16)
                (channel-i64-create-err-result "sync: semaphore create failed"))
              (begin
                (sync-write-i64! state-addr 0 0)
                (sync-write-i64! state-addr 1 0)
                (channel-i64-create-ok-result
                  (ChannelI64
                    slots-addr
                    state-addr
                    capacity
                    slots-bytes
                    mutex-handle
                    items-handle
                    spaces-handle))))))))))

;: Create a bounded `i64` channel with `capacity` queued messages.
(define (channel-i64-create [capacity : i64]) : ChannelI64CreateResult
  (if (<= capacity 0)
    (channel-i64-create-err-result "sync: channel capacity must be positive")
    (if (> capacity channel-i64-max-capacity)
      (channel-i64-create-err-result "sync: channel capacity exceeds maximum")
      (let
        [slots-bytes : i64 (* capacity 8)]
        [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
        (if (= slots-addr 0)
          (channel-i64-create-err-result "sync: channel allocation failed")
          (let
            [state-addr : i64 (sync-runtime-alloc 16)]
            (if (= state-addr 0)
              (begin
                (sync-runtime-free slots-addr slots-bytes)
                (channel-i64-create-err-result
                  "sync: channel allocation failed"))
              (channel-i64-create-semaphores
                slots-addr
                state-addr
                capacity
                slots-bytes))))))))

;: Send `value`, blocking until one slot is available.
(define (channel-i64-send [channel : ChannelI64] [value : i64]) : ChannelI64SendResult
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    (channel-i64-send-err-result "sync: channel send wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        (channel-i64-send-err-result "sync: channel lock failed"))
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        (begin
          (sync-write-i64! (struct-get channel slots-addr) tail value)
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-i64-next-index (struct-get channel capacity) tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (channel-i64-send-err-result "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel items-handle))
              (channel-i64-send-ok-result)
              (channel-i64-send-err-result "sync: channel send signal failed"))))))))

;: Receive one value, blocking until one queued message is available.
(define (channel-i64-recv [channel : ChannelI64]) : ChannelI64RecvResult
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    (channel-i64-recv-err-result "sync: channel recv wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        (channel-i64-recv-err-result "sync: channel lock failed"))
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [value : i64 (sync-read-i64 (struct-get channel slots-addr) head)]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-i64-next-index (struct-get channel capacity) head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (channel-i64-recv-err-result "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              (channel-i64-recv-ok-result value)
              (channel-i64-recv-err-result "sync: channel recv signal failed"))))))))

;: Close channel resources after all senders/receivers are done.
(define (channel-i64-close [channel : ChannelI64]) : bool
  (let
    [ok : bool true]
    (begin
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel mutex-handle))
          ok
          false))
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel items-handle))
          ok
          false))
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel spaces-handle))
          ok
          false))
      (set!
        ok
        (if (sync-runtime-free
          (struct-get channel slots-addr)
          (struct-get channel slots-bytes))
          ok
          false))
      (set!
        ok
        (if (sync-runtime-free (struct-get channel state-addr) 16)
          ok
          false))
      ok)))

;: Store a channel handle into a raw `i64` array at `offset`.
(define (channel-i64-store-raw!
  [channel : ChannelI64]
  [dst : (Array i64)]
  [offset : i64]) : unit
  (begin
    (array-set! dst offset (struct-get channel slots-addr))
    (array-set! dst (+ offset 1) (struct-get channel state-addr))
    (array-set! dst (+ offset 2) (struct-get channel capacity))
    (array-set! dst (+ offset 3) (struct-get channel slots-bytes))
    (array-set! dst (+ offset 4) (struct-get channel mutex-handle))
    (array-set! dst (+ offset 5) (struct-get channel items-handle))
    (array-set! dst (+ offset 6) (struct-get channel spaces-handle))))

;: Rebuild a channel handle from a raw `i64` array at `offset`.
(define (channel-i64-load-raw [src : (Array i64)] [offset : i64]) : ChannelI64
  (ChannelI64
    (array-ref src offset)
    (array-ref src (+ offset 1))
    (array-ref src (+ offset 2))
    (array-ref src (+ offset 3))
    (array-ref src (+ offset 4))
    (array-ref src (+ offset 5))
    (array-ref src (+ offset 6))))

;: Return the next ring index for `channel`.
(define (channel-i64-pair-next-index
  [channel : ChannelI64PairChannel]
  [index : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next (struct-get channel capacity))
      0
      next)))

;: Build a pair channel handle from allocated storage and semaphore handles.
(define (channel-i64-pair-handle
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]
  [mutex : thread.ThreadSemaphore]
  [items : thread.ThreadSemaphore]
  [spaces : thread.ThreadSemaphore]) : ChannelI64PairChannel
  (ChannelI64PairChannel
    slots-addr
    state-addr
    capacity
    slots-bytes
    (struct-get mutex handle)
    (struct-get items handle)
    (struct-get spaces handle)))

;: Finish pair channel creation after storage allocation.
(define (channel-i64-pair-create-semaphores
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]) : ChannelI64PairCreateResult
  (let
    [mutex-handle : i64 (thread.thread-semaphore-create-handle-or 1 -1)]
    (if (= mutex-handle -1)
      (begin
        (sync-runtime-free slots-addr slots-bytes)
        (sync-runtime-free state-addr 16)
        (channel-i64-pair-create-err-result "sync: semaphore create failed"))
      (let
        [items-handle : i64 (thread.thread-semaphore-create-handle-or 0 -1)]
        (if (= items-handle -1)
          (begin
            (sync-semaphore-close mutex-handle)
            (sync-runtime-free slots-addr slots-bytes)
            (sync-runtime-free state-addr 16)
            (channel-i64-pair-create-err-result "sync: semaphore create failed"))
          (let
            [spaces-handle : i64
              (thread.thread-semaphore-create-handle-or capacity -1)]
            (if (= spaces-handle -1)
              (begin
                (sync-semaphore-close mutex-handle)
                (sync-semaphore-close items-handle)
                (sync-runtime-free slots-addr slots-bytes)
                (sync-runtime-free state-addr 16)
                (channel-i64-pair-create-err-result
                  "sync: semaphore create failed"))
              (begin
                (sync-write-i64! state-addr 0 0)
                (sync-write-i64! state-addr 1 0)
                (channel-i64-pair-create-ok-result
                  (ChannelI64PairChannel
                    slots-addr
                    state-addr
                    capacity
                    slots-bytes
                    mutex-handle
                    items-handle
                    spaces-handle))))))))))

;: Create a bounded `ChannelI64Pair` channel with `capacity` queued messages.
(define (channel-i64-pair-create [capacity : i64]) : ChannelI64PairCreateResult
  (if (<= capacity 0)
    (channel-i64-pair-create-err-result
      "sync: channel capacity must be positive")
    (if (> capacity channel-i64-max-capacity)
      (channel-i64-pair-create-err-result
        "sync: channel capacity exceeds maximum")
      (let
        [slots-bytes : i64 (* capacity 16)]
        [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
        (if (= slots-addr 0)
          (channel-i64-pair-create-err-result "sync: channel allocation failed")
          (let
            [state-addr : i64 (sync-runtime-alloc 16)]
            (if (= state-addr 0)
              (begin
                (sync-runtime-free slots-addr slots-bytes)
                (channel-i64-pair-create-err-result
                  "sync: channel allocation failed"))
              (channel-i64-pair-create-semaphores
                slots-addr
                state-addr
                capacity
                slots-bytes))))))))

;: Send `value`, blocking until one pair slot is available.
(define (channel-i64-pair-send
  [channel : ChannelI64PairChannel]
  [value : ChannelI64Pair]) : ChannelI64PairSendResult
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    (channel-i64-pair-send-err-result "sync: channel send wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        (channel-i64-pair-send-err-result "sync: channel lock failed"))
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        [slot : i64 (* tail 2)]
        (begin
          (sync-write-i64!
            (struct-get channel slots-addr)
            slot
            (struct-get value left))
          (sync-write-i64!
            (struct-get channel slots-addr)
            (+ slot 1)
            (struct-get value right))
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-i64-pair-next-index channel tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (channel-i64-pair-send-err-result "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel items-handle))
              (channel-i64-pair-send-ok-result)
              (channel-i64-pair-send-err-result
                "sync: channel send signal failed"))))))))

;: Receive one pair value, blocking until one queued message is available.
(define (channel-i64-pair-recv [channel : ChannelI64PairChannel]) : ChannelI64PairRecvResult
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    (channel-i64-pair-recv-err-result "sync: channel recv wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        (channel-i64-pair-recv-err-result "sync: channel lock failed"))
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [slot : i64 (* head 2)]
        [left : i64 (sync-read-i64 (struct-get channel slots-addr) slot)]
        [right : i64 (sync-read-i64 (struct-get channel slots-addr) (+ slot 1))]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-i64-pair-next-index channel head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (channel-i64-pair-recv-err-result "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              (channel-i64-pair-recv-ok-result (ChannelI64Pair left right))
              (channel-i64-pair-recv-err-result
                "sync: channel recv signal failed"))))))))

;: Close pair channel resources after all senders/receivers are done.
(define (channel-i64-pair-close [channel : ChannelI64PairChannel]) : bool
  (let
    [ok : bool true]
    (begin
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel mutex-handle))
          ok
          false))
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel items-handle))
          ok
          false))
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel spaces-handle))
          ok
          false))
      (set!
        ok
        (if (sync-runtime-free
          (struct-get channel slots-addr)
          (struct-get channel slots-bytes))
          ok
          false))
      (set!
        ok
        (if (sync-runtime-free (struct-get channel state-addr) 16)
          ok
          false))
      ok)))

;: Store a pair channel handle into a raw `i64` array at `offset`.
(define (channel-i64-pair-store-raw!
  [channel : ChannelI64PairChannel]
  [dst : (Array i64)]
  [offset : i64]) : unit
  (begin
    (array-set! dst offset (struct-get channel slots-addr))
    (array-set! dst (+ offset 1) (struct-get channel state-addr))
    (array-set! dst (+ offset 2) (struct-get channel capacity))
    (array-set! dst (+ offset 3) (struct-get channel slots-bytes))
    (array-set! dst (+ offset 4) (struct-get channel mutex-handle))
    (array-set! dst (+ offset 5) (struct-get channel items-handle))
    (array-set! dst (+ offset 6) (struct-get channel spaces-handle))))

;: Rebuild a pair channel handle from a raw `i64` array at `offset`.
(define (channel-i64-pair-load-raw [src : (Array i64)] [offset : i64]) : ChannelI64PairChannel
  (ChannelI64PairChannel
    (array-ref src offset)
    (array-ref src (+ offset 1))
    (array-ref src (+ offset 2))
    (array-ref src (+ offset 3))
    (array-ref src (+ offset 4))
    (array-ref src (+ offset 5))
    (array-ref src (+ offset 6))))

;: Return the next ring index for `channel`.
(define (channel-string-next-index [channel : ChannelString] [index : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next (struct-get channel capacity))
      0
      next)))

;: Build a string channel handle from allocated storage and semaphore handles.
(define (channel-string-handle
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]
  [mutex : thread.ThreadSemaphore]
  [items : thread.ThreadSemaphore]
  [spaces : thread.ThreadSemaphore]) : ChannelString
  (ChannelString
    slots-addr
    state-addr
    capacity
    slots-bytes
    (struct-get mutex handle)
    (struct-get items handle)
    (struct-get spaces handle)))

;: Finish string channel creation after storage allocation.
(define (channel-string-create-semaphores
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]) : ChannelStringCreateResult
  (let
    [mutex-handle : i64 (thread.thread-semaphore-create-handle-or 1 -1)]
    (if (= mutex-handle -1)
      (begin
        (sync-runtime-free slots-addr slots-bytes)
        (sync-runtime-free state-addr 16)
        (channel-string-create-err-result "sync: semaphore create failed"))
      (let
        [items-handle : i64 (thread.thread-semaphore-create-handle-or 0 -1)]
        (if (= items-handle -1)
          (begin
            (sync-semaphore-close mutex-handle)
            (sync-runtime-free slots-addr slots-bytes)
            (sync-runtime-free state-addr 16)
            (channel-string-create-err-result "sync: semaphore create failed"))
          (let
            [spaces-handle : i64
              (thread.thread-semaphore-create-handle-or capacity -1)]
            (if (= spaces-handle -1)
              (begin
                (sync-semaphore-close mutex-handle)
                (sync-semaphore-close items-handle)
                (sync-runtime-free slots-addr slots-bytes)
                (sync-runtime-free state-addr 16)
                (channel-string-create-err-result
                  "sync: semaphore create failed"))
              (begin
                (sync-write-i64! state-addr 0 0)
                (sync-write-i64! state-addr 1 0)
                (channel-string-create-ok-result
                  (ChannelString
                    slots-addr
                    state-addr
                    capacity
                    slots-bytes
                    mutex-handle
                    items-handle
                    spaces-handle))))))))))

;: Create a bounded `String` channel with `capacity` queued messages.
(define (channel-string-create [capacity : i64]) : ChannelStringCreateResult
  (if (<= capacity 0)
    (channel-string-create-err-result "sync: channel capacity must be positive")
    (if (> capacity channel-i64-max-capacity)
      (channel-string-create-err-result
        "sync: channel capacity exceeds maximum")
      (let
        [slots-bytes : i64 (* capacity 8)]
        [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
        (if (= slots-addr 0)
          (channel-string-create-err-result "sync: channel allocation failed")
          (let
            [state-addr : i64 (sync-runtime-alloc 16)]
            (if (= state-addr 0)
              (begin
                (sync-runtime-free slots-addr slots-bytes)
                (channel-string-create-err-result
                  "sync: channel allocation failed"))
              (channel-string-create-semaphores
                slots-addr
                state-addr
                capacity
                slots-bytes))))))))

;: Send `value`, blocking until one string slot is available.
(define (channel-string-send [channel : ChannelString] [value : String]) : ChannelStringSendResult
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    (channel-string-send-err-result "sync: channel send wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        (channel-string-send-err-result "sync: channel lock failed"))
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        (begin
          (sync-write-string! (struct-get channel slots-addr) tail value)
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-string-next-index channel tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (channel-string-send-err-result "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel items-handle))
              (channel-string-send-ok-result)
              (channel-string-send-err-result
                "sync: channel send signal failed"))))))))

;: Receive one string value, blocking until one queued message is available.
(define (channel-string-recv [channel : ChannelString]) : ChannelStringRecvResult
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    (channel-string-recv-err-result "sync: channel recv wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        (channel-string-recv-err-result "sync: channel lock failed"))
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [value : String (sync-read-string (struct-get channel slots-addr) head)]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-string-next-index channel head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (channel-string-recv-err-result "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              (ChannelStringRecvOk value)
              (channel-string-recv-err-result
                "sync: channel recv signal failed"))))))))

;: Close string channel resources after all senders/receivers are done.
(define (channel-string-close [channel : ChannelString]) : bool
  (let
    [ok : bool true]
    (begin
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel mutex-handle))
          ok
          false))
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel items-handle))
          ok
          false))
      (set!
        ok
        (if (sync-semaphore-close (struct-get channel spaces-handle))
          ok
          false))
      (set!
        ok
        (if (sync-runtime-free
          (struct-get channel slots-addr)
          (struct-get channel slots-bytes))
          ok
          false))
      (set!
        ok
        (if (sync-runtime-free (struct-get channel state-addr) 16)
          ok
          false))
      ok)))

;: Store a string channel handle into a raw `i64` array at `offset`.
(define (channel-string-store-raw!
  [channel : ChannelString]
  [dst : (Array i64)]
  [offset : i64]) : unit
  (begin
    (array-set! dst offset (struct-get channel slots-addr))
    (array-set! dst (+ offset 1) (struct-get channel state-addr))
    (array-set! dst (+ offset 2) (struct-get channel capacity))
    (array-set! dst (+ offset 3) (struct-get channel slots-bytes))
    (array-set! dst (+ offset 4) (struct-get channel mutex-handle))
    (array-set! dst (+ offset 5) (struct-get channel items-handle))
    (array-set! dst (+ offset 6) (struct-get channel spaces-handle))))

;: Rebuild a string channel handle from a raw `i64` array at `offset`.
(define (channel-string-load-raw [src : (Array i64)] [offset : i64]) : ChannelString
  (ChannelString
    (array-ref src offset)
    (array-ref src (+ offset 1))
    (array-ref src (+ offset 2))
    (array-ref src (+ offset 3))
    (array-ref src (+ offset 4))
    (array-ref src (+ offset 5))
    (array-ref src (+ offset 6))))

;: Return true when creating an i64 channel with `capacity` succeeds.
(define (channel-i64-create-capacity-ok? [capacity : i64]) : bool
  (if (> capacity 0)
    (<= capacity channel-i64-max-capacity)
    false))

;: Create an i64 channel with `capacity`, or return `fallback` on error.
(define (channel-i64-create-capacity-or
  [capacity : i64]
  [fallback : ChannelI64]) : ChannelI64
  (if (not (channel-i64-create-capacity-ok? capacity))
    fallback
    (let
      [slots-bytes : i64 (* capacity 8)]
      [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
      (if (= slots-addr 0)
        fallback
        (let
          [state-addr : i64 (sync-runtime-alloc 16)]
          (if (= state-addr 0)
            (begin
              (sync-runtime-free slots-addr slots-bytes)
              fallback)
            (let
              [mutex-handle : i64
                (thread.thread-semaphore-create-handle-or 1 -1)]
              (if (= mutex-handle -1)
                (begin
                  (sync-runtime-free slots-addr slots-bytes)
                  (sync-runtime-free state-addr 16)
                  fallback)
                (let
                  [items-handle : i64
                    (thread.thread-semaphore-create-handle-or 0 -1)]
                  (if (= items-handle -1)
                    (begin
                      (sync-semaphore-close mutex-handle)
                      (sync-runtime-free slots-addr slots-bytes)
                      (sync-runtime-free state-addr 16)
                      fallback)
                    (let
                      [spaces-handle : i64
                        (thread.thread-semaphore-create-handle-or capacity -1)]
                      (if (= spaces-handle -1)
                        (begin
                          (sync-semaphore-close mutex-handle)
                          (sync-semaphore-close items-handle)
                          (sync-runtime-free slots-addr slots-bytes)
                          (sync-runtime-free state-addr 16)
                          fallback)
                        (begin
                          (sync-write-i64! state-addr 0 0)
                          (sync-write-i64! state-addr 1 0)
                          (ChannelI64
                            slots-addr
                            state-addr
                            capacity
                            slots-bytes
                            mutex-handle
                            items-handle
                            spaces-handle))))))))))))))

;: Send one i64 value and return whether the send succeeded.
(define (channel-i64-send-value-ok? [channel : ChannelI64] [value : i64]) : bool
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    false
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        false)
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        (begin
          (sync-write-i64! (struct-get channel slots-addr) tail value)
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-i64-next-index (struct-get channel capacity) tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            false
            (sync-semaphore-post (struct-get channel items-handle))))))))

;: Receive one i64 value, or return `fallback` on error.
(define (channel-i64-recv-or [channel : ChannelI64] [fallback : i64]) : i64
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    fallback
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        fallback)
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [value : i64 (sync-read-i64 (struct-get channel slots-addr) head)]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-i64-next-index (struct-get channel capacity) head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            fallback
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              value
              fallback)))))))

;: Return true when creating a pair channel with `capacity` succeeds.
(define (channel-i64-pair-create-capacity-ok? [capacity : i64]) : bool
  (if (> capacity 0)
    (<= capacity channel-i64-max-capacity)
    false))

;: Create a pair channel with `capacity`, or return `fallback` on error.
(define (channel-i64-pair-create-capacity-or
  [capacity : i64]
  [fallback : ChannelI64PairChannel]) : ChannelI64PairChannel
  (if (not (channel-i64-pair-create-capacity-ok? capacity))
    fallback
    (let
      [slots-bytes : i64 (* capacity 16)]
      [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
      (if (= slots-addr 0)
        fallback
        (let
          [state-addr : i64 (sync-runtime-alloc 16)]
          (if (= state-addr 0)
            (begin
              (sync-runtime-free slots-addr slots-bytes)
              fallback)
            (let
              [mutex-handle : i64
                (thread.thread-semaphore-create-handle-or 1 -1)]
              (if (= mutex-handle -1)
                (begin
                  (sync-runtime-free slots-addr slots-bytes)
                  (sync-runtime-free state-addr 16)
                  fallback)
                (let
                  [items-handle : i64
                    (thread.thread-semaphore-create-handle-or 0 -1)]
                  (if (= items-handle -1)
                    (begin
                      (sync-semaphore-close mutex-handle)
                      (sync-runtime-free slots-addr slots-bytes)
                      (sync-runtime-free state-addr 16)
                      fallback)
                    (let
                      [spaces-handle : i64
                        (thread.thread-semaphore-create-handle-or capacity -1)]
                      (if (= spaces-handle -1)
                        (begin
                          (sync-semaphore-close mutex-handle)
                          (sync-semaphore-close items-handle)
                          (sync-runtime-free slots-addr slots-bytes)
                          (sync-runtime-free state-addr 16)
                          fallback)
                        (begin
                          (sync-write-i64! state-addr 0 0)
                          (sync-write-i64! state-addr 1 0)
                          (ChannelI64PairChannel
                            slots-addr
                            state-addr
                            capacity
                            slots-bytes
                            mutex-handle
                            items-handle
                            spaces-handle))))))))))))))

;: Send one pair value and return whether the send succeeded.
(define (channel-i64-pair-send-value-ok?
  [channel : ChannelI64PairChannel]
  [value : ChannelI64Pair]) : bool
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    false
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        false)
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        [slot : i64 (* tail 2)]
        (begin
          (sync-write-i64!
            (struct-get channel slots-addr)
            slot
            (struct-get value left))
          (sync-write-i64!
            (struct-get channel slots-addr)
            (+ slot 1)
            (struct-get value right))
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-i64-pair-next-index channel tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            false
            (sync-semaphore-post (struct-get channel items-handle))))))))

;: Receive one pair value, or return `fallback` on error.
(define (channel-i64-pair-recv-or
  [channel : ChannelI64PairChannel]
  [fallback : ChannelI64Pair]) : ChannelI64Pair
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    fallback
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        fallback)
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [slot : i64 (* head 2)]
        [left : i64 (sync-read-i64 (struct-get channel slots-addr) slot)]
        [right : i64 (sync-read-i64 (struct-get channel slots-addr) (+ slot 1))]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-i64-pair-next-index channel head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            fallback
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              (ChannelI64Pair left right)
              fallback)))))))

;: Return true when creating a string channel with `capacity` succeeds.
(define (channel-string-create-capacity-ok? [capacity : i64]) : bool
  (if (> capacity 0)
    (<= capacity channel-i64-max-capacity)
    false))

;: Create a string channel with `capacity`, or return `fallback` on error.
(define (channel-string-create-capacity-or
  [capacity : i64]
  [fallback : ChannelString]) : ChannelString
  (if (not (channel-string-create-capacity-ok? capacity))
    fallback
    (let
      [slots-bytes : i64 (* capacity 8)]
      [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
      (if (= slots-addr 0)
        fallback
        (let
          [state-addr : i64 (sync-runtime-alloc 16)]
          (if (= state-addr 0)
            (begin
              (sync-runtime-free slots-addr slots-bytes)
              fallback)
            (let
              [mutex-handle : i64
                (thread.thread-semaphore-create-handle-or 1 -1)]
              (if (= mutex-handle -1)
                (begin
                  (sync-runtime-free slots-addr slots-bytes)
                  (sync-runtime-free state-addr 16)
                  fallback)
                (let
                  [items-handle : i64
                    (thread.thread-semaphore-create-handle-or 0 -1)]
                  (if (= items-handle -1)
                    (begin
                      (sync-semaphore-close mutex-handle)
                      (sync-runtime-free slots-addr slots-bytes)
                      (sync-runtime-free state-addr 16)
                      fallback)
                    (let
                      [spaces-handle : i64
                        (thread.thread-semaphore-create-handle-or capacity -1)]
                      (if (= spaces-handle -1)
                        (begin
                          (sync-semaphore-close mutex-handle)
                          (sync-semaphore-close items-handle)
                          (sync-runtime-free slots-addr slots-bytes)
                          (sync-runtime-free state-addr 16)
                          fallback)
                        (begin
                          (sync-write-i64! state-addr 0 0)
                          (sync-write-i64! state-addr 1 0)
                          (ChannelString
                            slots-addr
                            state-addr
                            capacity
                            slots-bytes
                            mutex-handle
                            items-handle
                            spaces-handle))))))))))))))

;: Send one string value and return whether the send succeeded.
(define (channel-string-send-value-ok?
  [channel : ChannelString]
  [value : String]) : bool
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    false
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        false)
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        (begin
          (sync-write-string! (struct-get channel slots-addr) tail value)
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-string-next-index channel tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            false
            (sync-semaphore-post (struct-get channel items-handle))))))))

;: Receive one string value, or return `fallback` on error.
(define (channel-string-recv-or [channel : ChannelString] [fallback : String]) : String
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    fallback
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        fallback)
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [value : String (sync-read-string (struct-get channel slots-addr) head)]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-string-next-index channel head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            fallback
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              value
              fallback)))))))

;: Return true when creating a mutex with `initial` succeeds.
(define (mutex-i64-create-initial-ok? [initial : i64]) : bool
  (let
    [mutex : MutexI64 (mutex-i64-create-initial-or initial (MutexI64 0 0 0))]
    [ok : bool (not (= (struct-get mutex mutex-handle) 0))]
    (begin
      (if ok
        (begin
          (mutex-i64-close mutex)
          unit)
        unit)
      ok)))

;: Create a mutex with `initial`, or return `fallback` on error.
(define (mutex-i64-create-initial-or [initial : i64] [fallback : MutexI64]) : MutexI64
  (let
    [value-addr : i64 (sync-runtime-alloc 8)]
    (if (= value-addr 0)
      fallback
      (let
        [control-addr : i64 (sync-runtime-alloc mutex-i64-control-byte-count)]
        (if (= control-addr 0)
          (begin
            (sync-runtime-free value-addr 8)
            fallback)
          (let
            [mutex-handle : i64 (thread.thread-semaphore-create-handle-or 1 -1)]
            (if (= mutex-handle -1)
              (begin
                (sync-runtime-free value-addr 8)
                (sync-runtime-free control-addr mutex-i64-control-byte-count)
                fallback)
              (begin
                (sync-write-i64! value-addr 0 initial)
                (sync-write-i64! control-addr mutex-i64-control-closed-slot 0)
                (sync-write-i64! control-addr mutex-i64-control-users-slot 0)
                (MutexI64 value-addr mutex-handle control-addr)))))))))

;: Inline test failure helper.
(define (sync-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (sync-test-assert [ok : bool]) : unit
  (if ok
    unit
    (sync-test-fail)))

(test
  sync-api
  (begin
    (sync-test-assert (= channel-i64-raw-field-count 7))
    (sync-test-assert (= channel-i64-pair-raw-field-count 7))
    (sync-test-assert (= channel-string-raw-field-count 7))
    (sync-test-assert (= mutex-i64-raw-field-count 3))
    (sync-test-assert (not (channel-i64-create-capacity-ok? 0)))
    (sync-test-assert
      (not (channel-i64-create-capacity-ok? (+ channel-i64-max-capacity 1))))
    (sync-test-assert (not (channel-i64-pair-create-capacity-ok? 0)))
    (sync-test-assert
      (not
        (channel-i64-pair-create-capacity-ok? (+ channel-i64-max-capacity 1))))
    (sync-test-assert (not (channel-string-create-capacity-ok? 0)))
    (sync-test-assert
      (not (channel-string-create-capacity-ok? (+ channel-i64-max-capacity 1))))))

(export
  (value channel-i64-max-capacity)
  (value channel-i64-raw-field-count)
  (value channel-i64-pair-raw-field-count)
  (value channel-string-raw-field-count)
  (value mutex-i64-raw-field-count)
  (value mutex-i64-control-byte-count)
  (value mutex-i64-control-closed-slot)
  (value mutex-i64-control-users-slot)
  (value mutex-i64-users-closing-delta)
  (value mutex-i64-users-closing-undo)
  (value channel-i64-create-capacity-ok?)
  (value channel-i64-create-capacity-or)
  (value channel-i64-send-value-ok?)
  (value channel-i64-recv-or)
  (value channel-i64-pair-create-capacity-ok?)
  (value channel-i64-pair-create-capacity-or)
  (value channel-i64-pair-send-value-ok?)
  (value channel-i64-pair-recv-or)
  (value channel-string-create-capacity-ok?)
  (value channel-string-create-capacity-or)
  (value channel-string-send-value-ok?)
  (value channel-string-recv-or)
  (value mutex-i64-create-initial-ok?)
  (value mutex-i64-create-initial-or)
  (value sync-abort)
  (value sync-runtime-alloc)
  (value sync-runtime-free)
  (value sync-addr->mut-i64)
  (value sync-addr->mut-string)
  (value sync-atomic-i64-load-ptr)
  (value sync-atomic-i64-store-ptr!)
  (value sync-atomic-i64-add-ptr!)
  (value sync-atomic-i64-fetch-add-ptr!)
  (value sync-atomic-i64-cas-ptr!)
  (value sync-addr-slot->mut-i64)
  (value sync-addr-slot->i64)
  (value sync-atomic-i64-load)
  (value sync-atomic-i64-store!)
  (value sync-atomic-i64-add!)
  (value sync-atomic-i64-fetch-add!)
  (value sync-atomic-i64-cas!)
  (value sync-read-i64)
  (value sync-write-i64!)
  (value sync-read-string)
  (value sync-write-string!)
  (value sync-semaphore)
  (value sync-semaphore-wait)
  (value sync-semaphore-post)
  (value sync-semaphore-close)
  (value mutex-i64-unlock-handle)
  (value mutex-i64-untrack-user)
  (value mutex-i64-track-user)
  (value mutex-i64-closed?)
  (value mutex-i64-lock-abort)
  (value mutex-i64-create-semaphore)
  (value mutex-i64-create)
  (value mutex-i64-lock)
  (value mutex-i64-guard-control-addr)
  (value mutex-i64-guard-mutex-handle)
  (value mutex-i64-guard-value-addr)
  (value mutex-i64-get)
  (value mutex-i64-set!)
  (value mutex-i64-add!)
  (value mutex-i64-close)
  (value mutex-i64-store-raw!)
  (value mutex-i64-load-raw)
  (value channel-i64-next-index)
  (value channel-i64-handle)
  (value channel-i64-create-semaphores)
  (value channel-i64-create)
  (value channel-i64-send)
  (value channel-i64-recv)
  (value channel-i64-close)
  (value channel-i64-store-raw!)
  (value channel-i64-load-raw)
  (value channel-i64-pair-next-index)
  (value channel-i64-pair-handle)
  (value channel-i64-pair-create-semaphores)
  (value channel-i64-pair-create)
  (value channel-i64-pair-send)
  (value channel-i64-pair-recv)
  (value channel-i64-pair-close)
  (value channel-i64-pair-store-raw!)
  (value channel-i64-pair-load-raw)
  (value channel-string-next-index)
  (value channel-string-handle)
  (value channel-string-create-semaphores)
  (value channel-string-create)
  (value channel-string-send)
  (value channel-string-recv)
  (value channel-string-close)
  (value channel-string-store-raw!)
  (value channel-string-load-raw)
  (type MutexI64)
  (type ChannelI64)
  (type ChannelI64Pair)
  (type ChannelI64PairChannel)
  (type ChannelString)
  (type ChannelI64CreateResult)
  (type ChannelI64PairCreateResult)
  (type ChannelStringCreateResult)
  (type MutexI64CreateResult)
  (type ChannelI64SendResult)
  (type ChannelI64PairSendResult)
  (type ChannelStringSendResult)
  (type ChannelI64RecvResult)
  (type ChannelI64PairRecvResult)
  (type ChannelStringRecvResult)
  (type MutexI64Guard)
  (constructor MutexI64)
  (constructor ChannelI64)
  (constructor ChannelI64Pair)
  (constructor ChannelI64PairChannel)
  (constructor ChannelString)
  (constructor MutexI64Guard)
  (field MutexI64 value-addr)
  (field MutexI64 mutex-handle)
  (field MutexI64 control-addr)
  (field ChannelI64 slots-addr)
  (field ChannelI64 state-addr)
  (field ChannelI64 capacity)
  (field ChannelI64 slots-bytes)
  (field ChannelI64 mutex-handle)
  (field ChannelI64 items-handle)
  (field ChannelI64 spaces-handle)
  (field ChannelI64Pair left)
  (field ChannelI64Pair right)
  (field ChannelI64PairChannel slots-addr)
  (field ChannelI64PairChannel state-addr)
  (field ChannelI64PairChannel capacity)
  (field ChannelI64PairChannel slots-bytes)
  (field ChannelI64PairChannel mutex-handle)
  (field ChannelI64PairChannel items-handle)
  (field ChannelI64PairChannel spaces-handle)
  (field ChannelString slots-addr)
  (field ChannelString state-addr)
  (field ChannelString capacity)
  (field ChannelString slots-bytes)
  (field ChannelString mutex-handle)
  (field ChannelString items-handle)
  (field ChannelString spaces-handle)
  (variant ChannelI64CreateOk)
  (variant ChannelI64CreateErr)
  (variant ChannelI64PairCreateOk)
  (variant ChannelI64PairCreateErr)
  (variant ChannelStringCreateOk)
  (variant ChannelStringCreateErr)
  (variant MutexI64CreateOk)
  (variant MutexI64CreateErr)
  (variant ChannelI64SendOk)
  (variant ChannelI64SendErr)
  (variant ChannelI64PairSendOk)
  (variant ChannelI64PairSendErr)
  (variant ChannelStringSendOk)
  (variant ChannelStringSendErr)
  (variant ChannelI64RecvOk)
  (variant ChannelI64RecvErr)
  (variant ChannelI64PairRecvOk)
  (variant ChannelI64PairRecvErr)
  (variant ChannelStringRecvOk)
  (variant ChannelStringRecvErr))