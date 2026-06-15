;# stdlib/thread.tl - Minimal native thread primitives for selfhost worker pools.
;#
;# Provides a narrow cross-target thread surface: spawn a `(-> i64 i64)` entry
;# with one raw integer context, join it, use a counting semaphore, and query a
;# default worker count. Linux uses raw `clone`/`futex`/`eventfd2` syscalls.
;# Windows uses kernel32 `CreateThread`, `WaitForSingleObject`, and semaphores.
;#
;# Each thread has its own default arena. The raw `i64` context/result surface
;# does not transfer ownership; callers that smuggle addresses through those
;# integers remain responsible for synchronization in unsafe code.
;#
;# Usage: `(import stdlib.thread)`
;#
;# ```typelisp run
;# ;; doctest-exit: 42
;# (import stdlib.thread)
;# (define (main) : i64
;#   (if (>= (thread.thread-default-worker-count) 1) 42 1))
;# ```
;: Opaque native thread handle plus runtime-owned join state.
(module stdlib.thread)

(defstruct Thread
  (handle i64)
  (clear-tid-addr i64)
  (result-addr i64))

;: Result returned by `thread-spawn`.
(defenum ThreadSpawnResult
  (ThreadSpawnOk Thread)
  (ThreadSpawnErr String))

;: Result returned by `thread-join`.
(defenum ThreadJoinResult
  (ThreadJoinOk i64)
  (ThreadJoinErr String))

;: Typed handle returned by `thread-spawn-i64`.
(defstruct ThreadI64
  (raw Thread))

;: Result returned by `thread-spawn-i64`.
(defenum ThreadI64SpawnResult
  (ThreadI64SpawnOk ThreadI64)
  (ThreadI64SpawnErr String))

;: Result returned by `thread-join-i64`.
(defenum ThreadI64JoinResult
  (ThreadI64JoinOk i64)
  (ThreadI64JoinErr String))

;: Opaque counting semaphore handle.
(defstruct ThreadSemaphore
  (handle i64))

;: Result returned by `thread-semaphore-create`.
(defenum ThreadSemaphoreResult
  (ThreadSemaphoreOk ThreadSemaphore)
  (ThreadSemaphoreErr String))

;: Windows raw entry pointer cell emitted by the backend runtime.
(cfg
  windows
  (extern thread-windows-entry (:symbol "tl_thread_entry_ptr") : (-> i64 i64)))

;: Linux runtime hook that installs this thread's default arena TLS slot.
(cfg
  linux
  (extern (thread-linux-runtime-init) : unit (:symbol "tl_thread_init")))

;: Windows kernel32 `CreateThread`.
(cfg
  windows
  (extern (thread-windows-create-thread
    [security : i64]
    [stack-size : i64]
    [entry : (-> i64 i64)]
    [context : i64]
    [flags : i32]
    [thread-id : i64]) : i64 (:abi c) (:symbol "CreateThread")))

;: Windows kernel32 `WaitForSingleObject`.
(cfg
  windows
  (extern (thread-windows-wait-single [handle : i64] [ms : i32]) : i32 (:symbol "WaitForSingleObject")))

;: Windows kernel32 `CloseHandle`.
(cfg
  windows
  (extern (thread-windows-close-handle [handle : i64]) : i32 (:symbol "CloseHandle")))

;: Windows kernel32 `SwitchToThread`.
(cfg
  windows
  (extern (thread-windows-switch-to-thread) : i32 (:symbol "SwitchToThread")))

;: Windows kernel32 `GetActiveProcessorCount`.
(cfg
  windows
  (extern (thread-windows-active-processor-count [group : u16]) : u32 (:symbol "GetActiveProcessorCount")))

;: Windows kernel32 `CreateSemaphoreA`.
(cfg
  windows
  (extern (thread-windows-create-semaphore
    [security : i64]
    [initial : i32]
    [maximum : i32]
    [name : i64]) : i64 (:symbol "CreateSemaphoreA")))

;: Windows kernel32 `ReleaseSemaphore`.
(cfg
  windows
  (extern (thread-windows-release-semaphore
    [handle : i64]
    [release-count : i32]
    [previous-count : i64]) : i32 (:symbol "ReleaseSemaphore")))

;: Default stack bytes reserved for Linux raw-clone workers.
(define thread-default-stack-size : i64
  1048576)

;: Maximum semaphore count used by the Windows wrapper.
(define thread-semaphore-max-count : i32
  (cast 2147483647 : i32))

;: Return the integer address of an `Array u8` backing buffer.
(define (thread-array-u8-addr [buf : (Array u8)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of an `Array u64` backing buffer.
(define (thread-array-u64-addr [buf : (Array u64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of an `Array i64` backing buffer.
(define (thread-array-i64-addr [buf : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of an `Array i32` backing buffer.
(define (thread-array-i32-addr [buf : (Array i32)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Convert an integer address into a mutable i32 pointer.
(define (thread-addr->mut-i32 [addr : i64]) : (MutPtr i32)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i32))))

;: Convert an integer address into a mutable i64 pointer.
(define (thread-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

;: Read an i32 from `addr`.
(define (thread-read-i32 [addr : i64]) : i32
  (unsafe
    (ptr-read (ptr-cast (stdlib.thread.thread-addr->mut-i32 addr) : (Ptr i32)))))

;: Write an i32 to `addr`.
(define (thread-write-i32! [addr : i64] [value : i32]) : unit
  (unsafe
    (ptr-write! (stdlib.thread.thread-addr->mut-i32 addr) value)))

;: Read an i64 from `addr`.
(define (thread-read-i64 [addr : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (stdlib.thread.thread-addr->mut-i64 addr) : (Ptr i64)))))

;: Write an i64 to `addr`.
(define (thread-write-i64! [addr : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (stdlib.thread.thread-addr->mut-i64 addr) value)))

;: Linux raw clone flags for same-process worker threads.
(define (thread-linux-clone-flags) : i64
  2428672)

;: Linux futex wait operation.
(define (thread-linux-futex-wait [addr : i64] [expected : i64]) : i64
  (unsafe
    (syscall 202 addr 0 expected 0 0 0)))

;: Linux futex wake operation.
(define (thread-linux-futex-wake [addr : i64]) : i64
  (unsafe
    (syscall 202 addr 1 2147483647 0 0 0)))

;: Linux current-thread exit syscall wrapper.
(define (thread-linux-exit-current [code : i64]) : never
  (begin
    (unsafe
      (syscall 60 code))
    (stdlib.thread.thread-linux-exit-current code)))

;: Linux child path entered immediately after raw `clone` returns zero.
(define (thread-linux-child-main
  [entry : (-> i64 i64)]
  [arg : i64]
  [result-addr : i64]
  [started-addr : i64]) : never
  (begin
    (cfg linux (stdlib.thread.thread-linux-runtime-init) unit)
    (stdlib.thread.thread-write-i32! started-addr (cast 1 : i32))
    (stdlib.thread.thread-linux-futex-wake started-addr)
    (let
      [result : i64 (entry arg)]
      (begin
        (stdlib.thread.thread-write-i64! result-addr result)
        (stdlib.thread.thread-linux-exit-current result)))))

;: Wait until the i32 at `addr` no longer equals `expected`.
(define (thread-linux-wait-i32-change [addr : i64] [expected : i32]) : unit
  (while (= (stdlib.thread.thread-read-i32 addr) expected)
    (begin
      (stdlib.thread.thread-linux-futex-wait addr (cast expected : i64))
      unit)))

;: Linux implementation of `thread-spawn`.
(define (thread-linux-spawn [entry : (-> i64 i64)] [arg : i64]) : ThreadSpawnResult
  (let
    [stack : (Array u8) (make-array u8 stdlib.thread.thread-default-stack-size)]
    [clear-cell : (Array i32) (make-array i32 1)]
    [started-cell : (Array i32) (make-array i32 1)]
    [result-cell : (Array i64) (make-array i64 1)]
    [clear-addr : i64 (stdlib.thread.thread-array-i32-addr clear-cell)]
    [started-addr : i64 (stdlib.thread.thread-array-i32-addr started-cell)]
    [result-addr : i64 (stdlib.thread.thread-array-i64-addr result-cell)]
    [stack-top : i64
      (bit-and
        (+
          (stdlib.thread.thread-array-u8-addr stack)
          stdlib.thread.thread-default-stack-size)
        -16)]
    (begin
      (array-set! clear-cell 0 (cast 1 : i32))
      (let
        [tid : i64
          (unsafe
            (syscall
              56
              (stdlib.thread.thread-linux-clone-flags)
              stack-top
              0
              clear-addr
              0))]
        (if (< tid 0)
          (ThreadSpawnErr "thread: spawn failed")
          (if (= tid 0)
            (stdlib.thread.thread-linux-child-main
              entry
              arg
              result-addr
              started-addr)
            (begin
              (stdlib.thread.thread-linux-wait-i32-change
                started-addr
                (cast 0 : i32))
              (ThreadSpawnOk (Thread tid clear-addr result-addr)))))))))

;: Windows spin-wait until the backend trampoline copies its start context.
(cfg
  windows
  (define (thread-windows-wait-started [started-addr : i64]) : unit
    (while (= (stdlib.thread.thread-read-i32 started-addr) (cast 0 : i32))
      (begin
        (stdlib.thread.thread-windows-switch-to-thread)
        unit))))

;: Windows implementation of `thread-spawn`.
(cfg
  windows
  (define (thread-windows-spawn [entry : (-> i64 i64)] [arg : i64]) : ThreadSpawnResult
    (let
      [context : (Array u64) (make-array u64 4)]
      [started-cell : (Array i32) (make-array i32 1)]
      [result-cell : (Array i64) (make-array i64 1)]
      [context-addr : i64 (stdlib.thread.thread-array-u64-addr context)]
      [started-addr : i64 (stdlib.thread.thread-array-i32-addr started-cell)]
      [result-addr : i64 (stdlib.thread.thread-array-i64-addr result-cell)]
      (begin
        (array-set!
          context
          0
          (unsafe
            (cast entry : u64)))
        (array-set! context 1 (cast arg : u64))
        (array-set! context 2 (cast result-addr : u64))
        (array-set! context 3 (cast started-addr : u64))
        (let
          [handle : i64
            (thread-windows-create-thread
              0
              0
              thread-windows-entry
              context-addr
              (cast 0 : i32)
              0)]
          (if (= handle 0)
            (ThreadSpawnErr "thread: spawn failed")
            (begin
              (stdlib.thread.thread-windows-wait-started started-addr)
              (ThreadSpawnOk (Thread handle 0 result-addr)))))))))

;: Spawn `entry`, passing `arg`; the result can be joined exactly once.
(define (thread-spawn [entry : (-> i64 i64)] [arg : i64]) : ThreadSpawnResult
  (cfg
    windows
    (stdlib.thread.thread-windows-spawn entry arg)
    (stdlib.thread.thread-linux-spawn entry arg)))

;: Spawn a compiler-checked direct nullary closure returning `i64`.
;:
;: Safe calls must pass a direct lambda. The typechecker rejects captures that
;: are not copyable scalar values and rejects calls from scoped arenas.
(define (thread-spawn-i64 [task : (-> i64)]) : ThreadI64SpawnResult
  (match (stdlib.thread.thread-spawn
    (lambda ([ignored : i64]) : i64
      (task))
    0)
    [(ThreadSpawnOk raw) (ThreadI64SpawnOk (ThreadI64 raw))]
    [(ThreadSpawnErr message) (ThreadI64SpawnErr message)]))

;: Wait for a Linux raw-clone thread to clear its join cell.
(define (thread-linux-join [thread : Thread]) : ThreadJoinResult
  (let
    [clear-addr : i64 (struct-get thread clear-tid-addr)]
    (begin
      (while (not (= (stdlib.thread.thread-read-i32 clear-addr) (cast 0 : i32)))
        (begin
          (stdlib.thread.thread-linux-futex-wait clear-addr (cast 1 : i64))
          unit))
      (ThreadJoinOk
        (stdlib.thread.thread-read-i64 (struct-get thread result-addr))))))

;: Windows implementation of `thread-join`.
(cfg
  windows
  (define (thread-windows-join [thread : Thread]) : ThreadJoinResult
    (let
      [waited : i32
        (stdlib.thread.thread-windows-wait-single
          (struct-get thread handle)
          (cast -1 : i32))]
      (if (not (= waited (cast 0 : i32)))
        (ThreadJoinErr "thread: join failed")
        (begin
          (stdlib.thread.thread-windows-close-handle (struct-get thread handle))
          (ThreadJoinOk
            (stdlib.thread.thread-read-i64 (struct-get thread result-addr))))))))

;: Join a thread and return the entry function's i64 result.
(define (thread-join [thread : Thread]) : ThreadJoinResult
  (cfg
    windows
    (stdlib.thread.thread-windows-join thread)
    (stdlib.thread.thread-linux-join thread)))

;: Join a typed `i64` thread and return its closure result.
(define (thread-join-i64 [thread : ThreadI64]) : ThreadI64JoinResult
  (match (stdlib.thread.thread-join (struct-get thread raw))
    [(ThreadJoinOk value) (ThreadI64JoinOk value)]
    [(ThreadJoinErr message) (ThreadI64JoinErr message)]))

;: Count set bits in a positive byte value.
(define (thread-count-byte-bits [byte : i64]) : i64
  (let
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i 8)
        (begin
          (if (= (bit-and (shr byte i) 1) 1)
            (set! count (+ count 1))
            unit)
          (set! i (+ i 1))))
      count)))

;: Count set CPU bits in a Linux affinity mask buffer.
(define (thread-count-affinity-bytes [mask : (Array u8)]) : i64
  (let
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i (array-length mask))
        (begin
          (set!
            count
            (+
              count
              (stdlib.thread.thread-count-byte-bits
                (cast (array-ref mask i) : i64))))
          (set! i (+ i 1))))
      count)))

;: Linux implementation of `thread-default-worker-count`.
(define (thread-linux-default-worker-count) : i64
  (let
    [mask : (Array u8) (make-array u8 128)]
    [rc : i64
      (unsafe
        (syscall 204 0 128 (stdlib.thread.thread-array-u8-addr mask)))]
    (if (< rc 0)
      1
      (let
        [count : i64 (stdlib.thread.thread-count-affinity-bytes mask)]
        (if (< count 1)
          1
          count)))))

;: Windows implementation of `thread-default-worker-count`.
(cfg
  windows
  (define (thread-windows-default-worker-count) : i64
    (let
      [count : i64
        (cast
          (stdlib.thread.thread-windows-active-processor-count
            (cast 0xffff : u16))
          : i64)]
      (if (< count 1)
        1
        count))))

;: Return the host's default worker count, falling back to 1.
(define (thread-default-worker-count) : i64
  (cfg
    windows
    (stdlib.thread.thread-windows-default-worker-count)
    (stdlib.thread.thread-linux-default-worker-count)))

;: Create a counting semaphore.
(define (thread-semaphore-create [initial : i64]) : ThreadSemaphoreResult
  (if (< initial 0)
    (ThreadSemaphoreErr "thread: semaphore initial count must be non-negative")
    (if (> initial (cast stdlib.thread.thread-semaphore-max-count : i64))
      (ThreadSemaphoreErr "thread: semaphore initial count exceeds maximum")
      (cfg
        windows
        (let
          [handle : i64
            (stdlib.thread.thread-windows-create-semaphore
              0
              (cast initial : i32)
              stdlib.thread.thread-semaphore-max-count
              0)]
          (if (= handle 0)
            (ThreadSemaphoreErr "thread: semaphore create failed")
            (ThreadSemaphoreOk (ThreadSemaphore handle))))
        (let
          [fd : i64
            (unsafe
              (syscall 290 initial 1))]
          (if (< fd 0)
            (ThreadSemaphoreErr "thread: semaphore create failed")
            (ThreadSemaphoreOk (ThreadSemaphore fd))))))))

;: Wait for one semaphore token.
(define (thread-semaphore-wait [sem : ThreadSemaphore]) : bool
  (cfg
    windows
    (=
      (stdlib.thread.thread-windows-wait-single
        (struct-get sem handle)
        (cast -1 : i32))
      (cast 0 : i32))
    (let
      [buf : (Array u64) (make-array u64 1)]
      [done : bool false]
      [ok : bool false]
      (begin
        (while (not done)
          (let
            [n : i64
              (unsafe
                (syscall
                  0
                  (struct-get sem handle)
                  (stdlib.thread.thread-array-u64-addr buf)
                  8))]
            (if (= n 8)
              (begin
                (set! ok true)
                (set! done true))
              (if (= n -4)
                unit
                (set! done true)))))
        ok))))

;: Post one semaphore token.
(define (thread-semaphore-post [sem : ThreadSemaphore]) : bool
  (cfg
    windows
    (not
      (=
        (stdlib.thread.thread-windows-release-semaphore
          (struct-get sem handle)
          (cast 1 : i32)
          0)
        (cast 0 : i32)))
    (let
      [buf : (Array u64) (make-array u64 1)]
      (begin
        (array-set! buf 0 (cast 1 : u64))
        (=
          (unsafe
            (syscall
              1
              (struct-get sem handle)
              (stdlib.thread.thread-array-u64-addr buf)
              8))
          8)))))

;: Close a semaphore handle.
(define (thread-semaphore-close [sem : ThreadSemaphore]) : bool
  (cfg
    windows
    (not
      (=
        (stdlib.thread.thread-windows-close-handle (struct-get sem handle))
        (cast 0 : i32)))
    (=
      (unsafe
        (syscall 3 (struct-get sem handle)))
      0)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value thread-default-stack-size)
  (value thread-semaphore-max-count)
  (value thread-array-u8-addr)
  (value thread-array-u64-addr)
  (value thread-array-i64-addr)
  (value thread-array-i32-addr)
  (value thread-addr->mut-i32)
  (value thread-addr->mut-i64)
  (value thread-read-i32)
  (value thread-write-i32!)
  (value thread-read-i64)
  (value thread-write-i64!)
  (value thread-linux-clone-flags)
  (value thread-linux-futex-wait)
  (value thread-linux-futex-wake)
  (value thread-linux-exit-current)
  (value thread-linux-child-main)
  (value thread-linux-wait-i32-change)
  (value thread-linux-spawn)
  (value thread-spawn)
  (value thread-spawn-i64)
  (value thread-linux-join)
  (value thread-join)
  (value thread-join-i64)
  (value thread-count-byte-bits)
  (value thread-count-affinity-bytes)
  (value thread-linux-default-worker-count)
  (value thread-default-worker-count)
  (value thread-semaphore-create)
  (value thread-semaphore-wait)
  (value thread-semaphore-post)
  (value thread-semaphore-close)
  (type Thread)
  (type ThreadSpawnResult)
  (type ThreadJoinResult)
  (type ThreadI64)
  (type ThreadI64SpawnResult)
  (type ThreadI64JoinResult)
  (type ThreadSemaphore)
  (type ThreadSemaphoreResult)
  (constructor Thread)
  (constructor ThreadI64)
  (constructor ThreadSemaphore)
  (field Thread handle)
  (field Thread clear-tid-addr)
  (field Thread result-addr)
  (field ThreadI64 raw)
  (field ThreadSemaphore handle)
  (variant ThreadSpawnOk)
  (variant ThreadSpawnErr)
  (variant ThreadJoinOk)
  (variant ThreadJoinErr)
  (variant ThreadI64SpawnOk)
  (variant ThreadI64SpawnErr)
  (variant ThreadI64JoinOk)
  (variant ThreadI64JoinErr)
  (variant ThreadSemaphoreOk)
  (variant ThreadSemaphoreErr))

(cfg linux (export (value thread-linux-runtime-init)))

(cfg
  windows
  (export
    (value thread-windows-entry)
    (value thread-windows-create-thread)
    (value thread-windows-wait-single)
    (value thread-windows-close-handle)
    (value thread-windows-switch-to-thread)
    (value thread-windows-active-processor-count)
    (value thread-windows-create-semaphore)
    (value thread-windows-release-semaphore)
    (value thread-windows-wait-started)
    (value thread-windows-spawn)
    (value thread-windows-join)
    (value thread-windows-default-worker-count)))