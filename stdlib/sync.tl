;# stdlib/sync.tl - Safe synchronization helpers over the raw thread substrate.
;#
;# Provides first concrete synchronization surfaces for native threads:
;# `ChannelI64` for copyable scalar ownership transfer and `MutexI64` for shared
;# scalar mutation through a lexical cleanup guard. Handles are small copyable
;# values; shared state lives in runtime-owned OS memory and is serialized with
;# semaphore-backed synchronization.
;#
;# Usage: `(import "stdlib/sync.tl")`
;#
;# ```typelisp
;# (import "stdlib/sync.tl")
;#
;# (define ok : bool
;#   (match (channel-i64-create 2)
;#     [(ChannelI64CreateErr _) false]
;#     [(ChannelI64CreateOk ch)
;#       (begin
;#         (channel-i64-close ch)
;#         true)]))
;# ```
(import "thread.tl")

;: Maximum supported channel capacity for this first concrete channel surface.
(define channel-i64-max-capacity : i64
  1048576)

;: Number of raw `i64` fields needed to serialize a `ChannelI64` handle.
(define channel-i64-raw-field-count : i64
  7)

;: Number of raw `i64` fields needed to serialize a `MutexI64` handle.
(define mutex-i64-raw-field-count : i64
  2)

;: Runtime-owned mutex-protected `i64` slot.
(defstruct MutexI64
  (value-addr i64)
  (mutex-handle i64))

;: Runtime-owned bounded channel handle for `i64` messages.
(defstruct ChannelI64
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
  (ChannelI64CreateErr String))

;: Result returned by `mutex-i64-create`.
(defenum MutexI64CreateResult
  (MutexI64CreateOk MutexI64)
  (MutexI64CreateErr String))

;: Result returned by `channel-i64-send`.
(defenum ChannelI64SendResult
  (ChannelI64SendOk)
  (ChannelI64SendErr String))

;: Result returned by `channel-i64-recv`.
(defenum ChannelI64RecvResult
  (ChannelI64RecvOk i64)
  (ChannelI64RecvErr String))

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

;: Read one `i64` slot from runtime-owned storage.
(define (sync-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (sync-addr->mut-i64 addr) slot) : (Ptr i64)))))

;: Write one `i64` slot into runtime-owned storage.
(define (sync-write-i64! [addr : i64] [slot : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (sync-addr->mut-i64 addr) slot) value)))

;: Wrap a raw semaphore handle for calls into `thread.tl`.
(define (sync-semaphore [handle : i64]) : ThreadSemaphore
  (ThreadSemaphore handle))

;: Wait for a channel semaphore token.
(define (sync-semaphore-wait [handle : i64]) : bool
  (thread-semaphore-wait (sync-semaphore handle)))

;: Post one channel semaphore token.
(define (sync-semaphore-post [handle : i64]) : bool
  (thread-semaphore-post (sync-semaphore handle)))

;: Close one channel semaphore handle.
(define (sync-semaphore-close [handle : i64]) : bool
  (thread-semaphore-close (sync-semaphore handle)))

;: Unlock a mutex guard field during cleanup.
(define (mutex-i64-unlock-handle [handle : i64]) : unit
  (begin
    (sync-semaphore-post handle)
    unit))

;: Lexical guard returned by `mutex-i64-lock`.
(defstruct MutexI64Guard
  (:cleanup mutex-i64-unlock)
  (mutex-handle i64 (:cleanup mutex-i64-unlock-handle))
  (value-addr i64))

;: Finish mutex creation after storage allocation.
(define (mutex-i64-create-semaphore [value-addr : i64]) : MutexI64CreateResult
  (match (thread-semaphore-create 1)
    [(ThreadSemaphoreErr message)
      (begin
        (sync-runtime-free value-addr 8)
        (MutexI64CreateErr message))]
    [(ThreadSemaphoreOk mutex)
      (MutexI64CreateOk (MutexI64 value-addr (struct-get mutex handle)))]))

;: Create a mutex-protected `i64` initialized to `initial`.
(define (mutex-i64-create [initial : i64]) : MutexI64CreateResult
  (let
    [value-addr : i64 (sync-runtime-alloc 8)]
    (if (= value-addr 0)
      (MutexI64CreateErr "sync: mutex allocation failed")
      (begin
        (sync-write-i64! value-addr 0 initial)
        (mutex-i64-create-semaphore value-addr)))))

;: Lock `mutex`, blocking until the protected value is available.
(define (mutex-i64-lock [mutex : MutexI64]) : MutexI64Guard
  (if (sync-semaphore-wait (struct-get mutex mutex-handle))
    (MutexI64Guard
      (struct-get mutex mutex-handle)
      (struct-get mutex value-addr))
    (sync-abort 134)))

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

;: Close mutex resources after all users and guards are done.
(define (mutex-i64-close [mutex : MutexI64]) : bool
  (let
    [mutex-ok : bool (sync-semaphore-close (struct-get mutex mutex-handle))]
    [value-ok : bool (sync-runtime-free (struct-get mutex value-addr) 8)]
    (and mutex-ok value-ok)))

;: Store a mutex handle into a raw `i64` array at `offset`.
(define (mutex-i64-store-raw!
  [mutex : MutexI64]
  [dst : (Array i64)]
  [offset : i64]) : unit
  (begin
    (array-set! dst offset (struct-get mutex value-addr))
    (array-set! dst (+ offset 1) (struct-get mutex mutex-handle))))

;: Rebuild a mutex handle from a raw `i64` array at `offset`.
(define (mutex-i64-load-raw [src : (Array i64)] [offset : i64]) : MutexI64
  (MutexI64 (array-ref src offset) (array-ref src (+ offset 1))))

;: Return the next ring index for `channel`.
(define (channel-i64-next-index [channel : ChannelI64] [index : i64]) : i64
  (let
    [next : i64 (+ index 1)]
    (if (>= next (struct-get channel capacity))
      0
      next)))

;: Build a channel handle from allocated storage and semaphore handles.
(define (channel-i64-handle
  [slots-addr : i64]
  [state-addr : i64]
  [capacity : i64]
  [slots-bytes : i64]
  [mutex : ThreadSemaphore]
  [items : ThreadSemaphore]
  [spaces : ThreadSemaphore]) : ChannelI64
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
  (match (thread-semaphore-create 1)
    [(ThreadSemaphoreErr message)
      (begin
        (sync-runtime-free slots-addr slots-bytes)
        (sync-runtime-free state-addr 16)
        (ChannelI64CreateErr message))]
    [(ThreadSemaphoreOk mutex)
      (match (thread-semaphore-create 0)
        [(ThreadSemaphoreErr message)
          (begin
            (sync-semaphore-close (struct-get mutex handle))
            (sync-runtime-free slots-addr slots-bytes)
            (sync-runtime-free state-addr 16)
            (ChannelI64CreateErr message))]
        [(ThreadSemaphoreOk items)
          (match (thread-semaphore-create capacity)
            [(ThreadSemaphoreErr message)
              (begin
                (sync-semaphore-close (struct-get mutex handle))
                (sync-semaphore-close (struct-get items handle))
                (sync-runtime-free slots-addr slots-bytes)
                (sync-runtime-free state-addr 16)
                (ChannelI64CreateErr message))]
            [(ThreadSemaphoreOk spaces)
              (begin
                (sync-write-i64! state-addr 0 0)
                (sync-write-i64! state-addr 1 0)
                (ChannelI64CreateOk
                  (channel-i64-handle
                    slots-addr
                    state-addr
                    capacity
                    slots-bytes
                    mutex
                    items
                    spaces)))])])]))

;: Create a bounded `i64` channel with `capacity` queued messages.
(define (channel-i64-create [capacity : i64]) : ChannelI64CreateResult
  (if (<= capacity 0)
    (ChannelI64CreateErr "sync: channel capacity must be positive")
    (if (> capacity channel-i64-max-capacity)
      (ChannelI64CreateErr "sync: channel capacity exceeds maximum")
      (let
        [slots-bytes : i64 (* capacity 8)]
        [slots-addr : i64 (sync-runtime-alloc slots-bytes)]
        (if (= slots-addr 0)
          (ChannelI64CreateErr "sync: channel allocation failed")
          (let
            [state-addr : i64 (sync-runtime-alloc 16)]
            (if (= state-addr 0)
              (begin
                (sync-runtime-free slots-addr slots-bytes)
                (ChannelI64CreateErr "sync: channel allocation failed"))
              (channel-i64-create-semaphores
                slots-addr
                state-addr
                capacity
                slots-bytes))))))))

;: Send `value`, blocking until one slot is available.
(define (channel-i64-send [channel : ChannelI64] [value : i64]) : ChannelI64SendResult
  (if (not (sync-semaphore-wait (struct-get channel spaces-handle)))
    (ChannelI64SendErr "sync: channel send wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel spaces-handle))
        (ChannelI64SendErr "sync: channel lock failed"))
      (let
        [tail : i64 (sync-read-i64 (struct-get channel state-addr) 1)]
        (begin
          (sync-write-i64! (struct-get channel slots-addr) tail value)
          (sync-write-i64!
            (struct-get channel state-addr)
            1
            (channel-i64-next-index channel tail))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (ChannelI64SendErr "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel items-handle))
              (ChannelI64SendOk)
              (ChannelI64SendErr "sync: channel send signal failed"))))))))

;: Receive one value, blocking until one queued message is available.
(define (channel-i64-recv [channel : ChannelI64]) : ChannelI64RecvResult
  (if (not (sync-semaphore-wait (struct-get channel items-handle)))
    (ChannelI64RecvErr "sync: channel recv wait failed")
    (if (not (sync-semaphore-wait (struct-get channel mutex-handle)))
      (begin
        (sync-semaphore-post (struct-get channel items-handle))
        (ChannelI64RecvErr "sync: channel lock failed"))
      (let
        [head : i64 (sync-read-i64 (struct-get channel state-addr) 0)]
        [value : i64 (sync-read-i64 (struct-get channel slots-addr) head)]
        (begin
          (sync-write-i64!
            (struct-get channel state-addr)
            0
            (channel-i64-next-index channel head))
          (if (not (sync-semaphore-post (struct-get channel mutex-handle)))
            (ChannelI64RecvErr "sync: channel unlock failed")
            (if (sync-semaphore-post (struct-get channel spaces-handle))
              (ChannelI64RecvOk value)
              (ChannelI64RecvErr "sync: channel recv signal failed"))))))))

;: Close channel resources after all senders/receivers are done.
(define (channel-i64-close [channel : ChannelI64]) : bool
  (let
    [mutex-ok : bool (sync-semaphore-close (struct-get channel mutex-handle))]
    [items-ok : bool (sync-semaphore-close (struct-get channel items-handle))]
    [spaces-ok : bool (sync-semaphore-close (struct-get channel spaces-handle))]
    [slots-ok : bool
      (sync-runtime-free
        (struct-get channel slots-addr)
        (struct-get channel slots-bytes))]
    [state-ok : bool (sync-runtime-free (struct-get channel state-addr) 16)]
    (and mutex-ok items-ok spaces-ok slots-ok state-ok)))

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