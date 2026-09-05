;# stdlib/thread.tl - Native thread primitives and checked task wrappers.
;#
;# Provides a narrow cross-target raw thread surface: spawn a `(-> i64 i64)`
;# entry with one raw integer context, observe completion with a bounded
;# non-consuming wait, join it, use a counting semaphore, and query a default
;# worker count. Linux uses raw `clone`/`futex`/`eventfd2` syscalls. Windows
;# uses kernel32 `CreateThread`, `WaitForSingleObject`, and semaphores.
;#
;# Each thread has its own default arena. The raw `i64` context/result surface
;# does not transfer ownership; callers that smuggle addresses through those
;# integers remain responsible for synchronization in unsafe code.
;#
;# `(handle T)` emits the safe scalar task-threading surface. Generated
;# modules accept direct nullary closures whose captures are checked by the
;# structural thread-safety classifier and consume typed handles on join. The
;# concrete aggregate `spawn-*` wrappers copy current aggregate results into
;# atomic arenas that span the worker and joiner. The growable integer result
;# surface uses the owned generated `(vector i64)` family.
;#
;# Usage: `(import stdlib.thread)`
;#
;# ```typelisp run
;# ;; doctest-exit: 42
;# (import stdlib.thread)
;# (define (main) : i64
;#   (if (>= (thread.default-worker-count) 1) 42 1))
;# ```
(import stdlib.arena)
(import stdlib.comptime)
(import stdlib.string)
(import stdlib.time)
(import stdlib.vector)
(import (vector.vector i64) as thread-i64-vec)

;: Opaque native thread handle plus runtime-owned join state.
(defstruct Thread
  (handle i64)
  (clear-tid-addr i64)
  (result-addr i64)
  ;; TypeLisp has no standalone `!Copy` declaration yet. A static empty String
  ;; gives the raw handle a non-cleanup-owning, structurally move-only field.
  (ownership-marker String))

;: Result returned by `spawn`.
(defenum ThreadSpawnResult
  (ThreadSpawnOk Thread)
  (ThreadSpawnErr String))

;: Result returned by `join`.
(defenum ThreadJoinResult
  (ThreadJoinOk i64)
  (ThreadJoinErr String))

;: Result returned by the non-consuming `wait-for` completion observer.
(defenum ThreadWaitResult
  (ThreadWaitReady)
  (ThreadWaitTimedOut)
  (ThreadWaitErr String))

;: Emit a generated typed handle module for scalar task result type `T`.
;:
;: Supported result types are `i64`, `bool`, and `unit`. Import each
;: instantiation with an alias and use module-relative names:
;: `(import (thread.handle i64) as thread_i64)`.
(defmacro (handle [T : type]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "stdlib.thread.generated." (type-key T)))]
    (match (type-key T)
      ["i64"
        `(begin
          (module ,module-name)
          (import stdlib.thread)
          (defstruct Handle
            (raw thread.Thread))
          (defenum SpawnResult
            (I64SpawnOk Handle)
            (I64SpawnErr String))
          (defenum JoinResult
            (I64JoinOk i64)
            (I64JoinErr String))
          (define (spawn [task : (-> i64)]) : SpawnResult
            (let
              [raw-result : thread.ThreadSpawnResult
                (thread.handle-spawn-i64 task)]
              (match raw-result
                [(thread.ThreadSpawnOk raw) (I64SpawnOk (Handle raw))]
                [(thread.ThreadSpawnErr message) (I64SpawnErr message)])))
          (define (wait-for [worker : (& worker Handle)] [timeout-ms : i64]) : thread.ThreadWaitResult
            (thread.wait-for (& worker.raw) timeout-ms))
          (define (join [worker : Handle]) : JoinResult
            (match (thread.join worker.raw)
              [(thread.ThreadJoinOk value) (I64JoinOk value)]
              [(thread.ThreadJoinErr message) (I64JoinErr message)]))
          (define (join-value-or [result : JoinResult] [fallback : i64]) : i64
            (match result
              [(I64JoinOk value) value]
              [(I64JoinErr _) fallback])))]
      ["bool"
        `(begin
          (module ,module-name)
          (import stdlib.thread)
          (defstruct Handle
            (raw thread.Thread))
          (defenum SpawnResult
            (BoolSpawnOk Handle)
            (BoolSpawnErr String))
          (defenum JoinResult
            (BoolJoinOk bool)
            (BoolJoinErr String))
          (define (spawn [task : (-> bool)]) : SpawnResult
            (let
              [raw-result : thread.ThreadSpawnResult
                (thread.handle-spawn-bool task)]
              (match raw-result
                [(thread.ThreadSpawnOk raw) (BoolSpawnOk (Handle raw))]
                [(thread.ThreadSpawnErr message) (BoolSpawnErr message)])))
          (define (wait-for [worker : (& worker Handle)] [timeout-ms : i64]) : thread.ThreadWaitResult
            (thread.wait-for (& worker.raw) timeout-ms))
          (define (join [worker : Handle]) : JoinResult
            (match (thread.join worker.raw)
              [(thread.ThreadJoinOk value) (BoolJoinOk (not (= value 0)))]
              [(thread.ThreadJoinErr message) (BoolJoinErr message)])))]
      ["unit"
        `(begin
          (module ,module-name)
          (import stdlib.thread)
          (defstruct Handle
            (raw thread.Thread))
          (defenum SpawnResult
            (UnitSpawnOk Handle)
            (UnitSpawnErr String))
          (defenum JoinResult
            (UnitJoinOk)
            (UnitJoinErr String))
          (define (spawn [task : (-> unit)]) : SpawnResult
            (let
              [raw-result : thread.ThreadSpawnResult
                (thread.handle-spawn-unit task)]
              (match raw-result
                [(thread.ThreadSpawnOk raw) (UnitSpawnOk (Handle raw))]
                [(thread.ThreadSpawnErr message) (UnitSpawnErr message)])))
          (define (wait-for [worker : (& worker Handle)] [timeout-ms : i64]) : thread.ThreadWaitResult
            (thread.wait-for (& worker.raw) timeout-ms))
          (define (join [worker : Handle]) : JoinResult
            (match (thread.join worker.raw)
              [(thread.ThreadJoinOk _) (UnitJoinOk)]
              [(thread.ThreadJoinErr message) (UnitJoinErr message)])))]
      [_
        `(begin
          (module ,module-name))])))

;: Typed handle returned by `spawn-string`.
(defstruct ThreadString
  (raw Thread)
  (result-addr i64))

;: Typed handle returned by `spawn-i64-vec`.
(defstruct ThreadI64Vec
  (raw Thread)
  (result-addr i64))

;: Typed handle returned by `spawn-box-i64`.
(defstruct ThreadBoxI64
  (raw Thread)
  (result-addr i64)
  (owner arena.Arena))

;: Result returned by `spawn-string`.
(defenum ThreadStringSpawnResult
  (ThreadStringSpawnOk ThreadString)
  (ThreadStringSpawnErr String))

;: Result returned by `spawn-i64-vec`.
(defenum ThreadI64VecSpawnResult
  (ThreadI64VecSpawnOk ThreadI64Vec)
  (ThreadI64VecSpawnErr String))

;: Result returned by `spawn-box-i64`.
(defenum ThreadBoxI64SpawnResult
  (ThreadBoxI64SpawnOk ThreadBoxI64)
  (ThreadBoxI64SpawnErr String))

;: Result returned by `join-string`.
(defenum ThreadStringJoinResult
  (ThreadStringJoinOk String)
  (ThreadStringJoinErr String))

;: Result returned by `join-i64-vec`.
(defenum ThreadI64VecJoinResult
  (ThreadI64VecJoinOk thread-i64-vec.Vec)
  (ThreadI64VecJoinErr String))

;: Result returned by `join-box-i64`.
(defenum ThreadBoxI64JoinResult
  (ThreadBoxI64JoinOk (Box i64))
  (ThreadBoxI64JoinErr String))

;: Opaque counting semaphore handle.
(defstruct ThreadSemaphore
  (handle i64))

;: Result returned by `semaphore-create`.
(defenum ThreadSemaphoreResult
  (ThreadSemaphoreOk ThreadSemaphore)
  (ThreadSemaphoreErr String))

;: Return true when raw thread spawn succeeded.
(define (spawn-result-ok? [result : (& result ThreadSpawnResult)]) : bool
  (match result
    [(ThreadSpawnOk _) true]
    [(ThreadSpawnErr _) false]))

;: Return the raw spawned thread handle, or `fallback` when spawn failed.
(define (spawn-result-handle-or
  [result : (& result ThreadSpawnResult)]
  [fallback : i64]) : i64
  (match result
    [(ThreadSpawnOk thread) thread.handle]
    [(ThreadSpawnErr _) fallback]))

;: Return the raw spawned thread clear-tid address, or `fallback`.
(define (spawn-result-clear-tid-addr-or
  [result : (& result ThreadSpawnResult)]
  [fallback : i64]) : i64
  (match result
    [(ThreadSpawnOk thread) thread.clear-tid-addr]
    [(ThreadSpawnErr _) fallback]))

;: Return the raw spawned thread result address, or `fallback`.
(define (spawn-result-result-addr-or
  [result : (& result ThreadSpawnResult)]
  [fallback : i64]) : i64
  (match result
    [(ThreadSpawnOk thread) thread.result-addr]
    [(ThreadSpawnErr _) fallback]))

;: Return the raw spawned thread, or `fallback` when spawn failed.
(define (spawn-result-thread-or
  [result : ThreadSpawnResult]
  [fallback : Thread]) : Thread
  (match result
    [(ThreadSpawnOk thread) thread]
    [(ThreadSpawnErr _) fallback]))

;: Return the raw join code, or `fallback` when join failed.
(define (join-result-value-or [result : ThreadJoinResult] [fallback : i64]) : i64
  (match result
    [(ThreadJoinOk value) value]
    [(ThreadJoinErr _) fallback]))

;: Windows raw entry pointer cell emitted by the backend runtime.
(cfg
  windows
  (extern thread-windows-entry (:symbol "tl_thread_entry_ptr") : (-> i64 i64)))

;: Linux runtime hook that installs this thread's default arena TLS slot.
(cfg
  linux
  (extern (thread-linux-runtime-init) : unit (:symbol "tl_thread_init")))

;: Install the raw-clone worker's stack bounds for allocation-free debug-build
;: fatal backtraces. The declaration and call disappear outside backtrace
;: builds, so ordinary thread startup remains byte-for-byte unchanged.
(cfg
  (all linux compiler-backtrace)
  (extern (thread-linux-backtrace-stack-set [low : i64] [high : i64]) : unit (:symbol "tl_backtrace_stack_set")))

;: Windows kernel32 `CreateThread`.
(cfg
  windows
  (extern (thread-windows-create-thread
    [security : i64]
    [stack-size : i64]
    [entry : (-> i64 i64)]
    [context : i64]
    [flags : i32]
    [thread-id : i64]) : i64 (:symbol "CreateThread")))

;: Windows kernel32 `WaitForSingleObject`.
(cfg
  windows
  (extern (thread-windows-wait-single [handle : i64] [ms : u32]) : u32 (:symbol "WaitForSingleObject")))

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
(define default-stack-size : i64
  1048576)

;: Maximum semaphore count used by the Windows wrapper.
(define semaphore-max-count : i32
  (cast 2147483647 : i32))

;: Windows wait status and timeout constants.
(define windows-wait-object-0 : u32
  (cast 0 : u32))

;: Windows status returned when a finite wait reaches its deadline.
(define windows-wait-timeout : u32
  (cast 258 : u32))

;: Windows sentinel used only by the consuming blocking operations.
(define windows-wait-infinite : u32
  (cast 4294967295 : u32))

;: Largest finite timeout accepted by one Windows wait call.
(define windows-wait-max-finite-ms : i64
  4294967294)

;: Return the integer address of a private dynamic u8 backing buffer.
(define (array-u8-addr [buf : (& buf (__tl_dyn-array u8))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as buf (__tl_dyn-array u8)))
          : (Ptr u8)))
      : i64)))

;: Return the integer address of a private dynamic u64 backing buffer.
(define (array-u64-addr [buf : (& buf (__tl_dyn-array u64))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as
              buf
              (__tl_dyn-array u64)))
          : (Ptr u8)))
      : i64)))

;: Return the integer address of a private dynamic i64 backing buffer.
(define (array-i64-addr [buf : (& buf (__tl_dyn-array i64))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as
              buf
              (__tl_dyn-array i64)))
          : (Ptr u8)))
      : i64)))

;: Return the integer address of a private dynamic i32 backing buffer.
(define (array-i32-addr [buf : (& buf (__tl_dyn-array i32))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as
              buf
              (__tl_dyn-array i32)))
          : (Ptr u8)))
      : i64)))

;: Return the integer address of a private dynamic String backing buffer.
(define (array-string-addr [buf : (& buf (__tl_dyn-array String))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as
              buf
              (__tl_dyn-array String)))
          : (Ptr u8)))
      : i64)))

;: Return the integer address of a private i64 Vec result cell.
(define (array-i64-vec-addr [buf : (& buf (__tl_dyn-array thread-i64-vec.Vec))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as
              buf
              (__tl_dyn-array thread-i64-vec.Vec)))
          : (Ptr u8)))
      : i64)))

;: Convert an integer address into a mutable i32 pointer.
(define (addr->mut-i32 [addr : i64]) : (MutPtr i32)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i32))))

;: Convert an integer address into a mutable i64 pointer.
(define (addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

;: Convert an integer address into a mutable `String` pointer.
(define (addr->mut-string [addr : i64]) : (MutPtr String)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr String))))

;: Convert an integer address into a mutable i64 Vec pointer.
(define (addr->mut-i64-vec [addr : i64]) : (MutPtr thread-i64-vec.Vec)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr thread-i64-vec.Vec))))

;: Read an i32 from `addr`.
(define (read-i32 [addr : i64]) : i32
  (unsafe
    (ptr-read (ptr-cast (addr->mut-i32 addr) : (Ptr i32)))))

;: Write an i32 to `addr`.
(define (write-i32! [addr : i64] [value : i32]) : unit
  (unsafe
    (ptr-write! (addr->mut-i32 addr) value)))

;: Read an i64 from `addr`.
(define (read-i64 [addr : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (addr->mut-i64 addr) : (Ptr i64)))))

;: Write an i64 to `addr`.
(define (write-i64! [addr : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (addr->mut-i64 addr) value)))

;: Read a `String` from `addr`.
(define (read-string [addr : i64]) : String
  (unsafe
    (ptr-read (ptr-cast (addr->mut-string addr) : (Ptr String)))))

;: Write a `String` to `addr`.
(define (write-string! [addr : i64] [value : String]) : unit
  (unsafe
    (ptr-write! (addr->mut-string addr) value)))

;: Read an owned i64 Vec from `addr`.
(define (read-i64-vec [addr : i64]) : thread-i64-vec.Vec
  (unsafe
    (ptr-read (ptr-cast (addr->mut-i64-vec addr) : (Ptr thread-i64-vec.Vec)))))

;: Write an owned i64 Vec to `addr`.
(define (write-i64-vec! [addr : i64] [value : thread-i64-vec.Vec]) : unit
  (unsafe
    (ptr-write! (addr->mut-i64-vec addr) value)))

;: Consume an i64 Vec and copy its live prefix into fresh active-arena storage.
(define (i64-vec-copy [src : thread-i64-vec.Vec]) : thread-i64-vec.Vec
  (let
    [n : i64 (thread-i64-vec.len (& src))]
    [out : thread-i64-vec.Vec (thread-i64-vec.with-capacity n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (thread-i64-vec.push-ref! (&mut out) (thread-i64-vec.get (& src) i 0))
          (set! i (+ i 1))))
      out)))

;: Linux raw clone flags for same-process worker threads.
(define (linux-clone-flags) : i64
  2428672)

;: Linux futex wait operation.
(define (linux-futex-wait [addr : i64] [expected : i64]) : i64
  (unsafe
    (syscall 202 addr 0 expected 0 0 0)))

;: Linux futex wait with a bounded relative timespec.
(define (linux-futex-wait-for
  [addr : i64]
  [expected : i64]
  [timeout-addr : i64]) : i64
  (unsafe
    (syscall 202 addr 0 expected timeout-addr 0 0)))

;: Read Linux CLOCK_MONOTONIC into caller-owned reusable timespec storage.
(define (linux-monotonic-ms [timespec : (&mut timespec (__tl_dyn-array i64))]) : i64
  (let
    [status : i64
      (unsafe
        (syscall 228 1 (array-i64-addr timespec)))]
    (if (< status 0)
      -1
      (+ (* (array-ref timespec 0) 1000) (/ (array-ref timespec 1) 1000000)))))

;: Linux futex wake operation.
(define (linux-futex-wake [addr : i64]) : i64
  (unsafe
    (syscall 202 addr 1 2147483647 0 0 0)))

;: Linux current-thread exit syscall wrapper.
(define (linux-exit-current [code : i64]) : never
  (begin
    (unsafe
      (syscall 60 code))
    (linux-exit-current code)))

;: Linux child path entered immediately after raw `clone` returns zero.
(define (linux-child-main
  [entry : (-> i64 i64)]
  [arg : i64]
  [result-addr : i64]
  [started-addr : i64]
  ;; lint-allow: unused-variable -- consumed only in compiler-backtrace builds.
  [stack-low : i64]
  ;; lint-allow: unused-variable -- consumed only in compiler-backtrace builds.
  [stack-high : i64]) : never
  (begin
    (cfg linux (thread-linux-runtime-init) unit)
    (cfg
      (all linux compiler-backtrace)
      (thread-linux-backtrace-stack-set stack-low stack-high)
      unit)
    (write-i32! started-addr (cast 1 : i32))
    (linux-futex-wake started-addr)
    (let
      [result : i64 (entry arg)]
      (begin
        (write-i64! result-addr result)
        (linux-exit-current result)))))

;: Wait until the i32 at `addr` no longer equals `expected`.
(define (linux-wait-i32-change [addr : i64] [expected : i32]) : unit
  (while (= (read-i32 addr) expected)
    (begin
      (linux-futex-wait addr (cast expected : i64))
      unit)))

;: Linux implementation of `spawn`.
(define (linux-spawn [entry : (-> i64 i64)] [arg : i64]) : ThreadSpawnResult
  (let
    [stack : (__tl_dyn-array u8) (__tl_make-array u8 default-stack-size)]
    [clear-cell : (__tl_dyn-array i32) (__tl_make-array i32 1)]
    [started-cell : (__tl_dyn-array i32) (__tl_make-array i32 1)]
    [result-cell : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [clear-addr : i64 (array-i32-addr clear-cell)]
    [started-addr : i64 (array-i32-addr started-cell)]
    [result-addr : i64 (array-i64-addr result-cell)]
    [stack-top : i64 (bit-and (+ (array-u8-addr stack) default-stack-size) -16)]
    (begin
      (set! (array-ref clear-cell 0) (cast 1 : i32))
      (let
        [tid : i64
          (unsafe
            (syscall 56 (linux-clone-flags) stack-top 0 clear-addr 0))]
        (if (< tid 0)
          (ThreadSpawnErr "thread: spawn failed")
          (if (= tid 0)
            (linux-child-main
              entry
              arg
              result-addr
              started-addr
              (array-u8-addr stack)
              stack-top)
            (begin
              (linux-wait-i32-change started-addr (cast 0 : i32))
              (ThreadSpawnOk (Thread tid clear-addr result-addr "")))))))))

;: Windows spin-wait until the backend trampoline copies its start context.
(cfg
  windows
  (define (thread-windows-wait-started [started-addr : i64]) : unit
    (while (= (read-i32 started-addr) (cast 0 : i32))
      (begin
        (thread-windows-switch-to-thread)
        unit))))

;: Windows implementation of `spawn`.
(cfg
  windows
  (define (thread-windows-spawn [entry : (-> i64 i64)] [arg : i64]) : ThreadSpawnResult
    (let
      [context : (__tl_dyn-array u64) (__tl_make-array u64 4)]
      [started-cell : (__tl_dyn-array i32) (__tl_make-array i32 1)]
      [result-cell : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      [context-addr : i64 (array-u64-addr context)]
      [started-addr : i64 (array-i32-addr started-cell)]
      [result-addr : i64 (array-i64-addr result-cell)]
      (begin
        (set!
          (array-ref context 0)
          (unsafe
            (cast entry : u64)))
        (set! (array-ref context 1) (cast arg : u64))
        (set! (array-ref context 2) (cast result-addr : u64))
        (set! (array-ref context 3) (cast started-addr : u64))
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
              (thread-windows-wait-started started-addr)
              (ThreadSpawnOk (Thread handle 0 result-addr "")))))))))

;: Spawn `entry`, passing `arg`; the result can be joined exactly once.
(define (spawn [entry : (-> i64 i64)] [arg : i64]) : ThreadSpawnResult
  (cfg windows (thread-windows-spawn entry arg) (linux-spawn entry arg)))

;: Private bridge used by generated `(handle i64)` modules.
(define (handle-spawn-i64 [task : (-> i64)]) : ThreadSpawnResult
  (spawn
    (lambda ([_ignored : i64]) : i64
      (task))
    0))

;: Private bridge used by generated `(handle bool)` modules.
(define (handle-spawn-bool [task : (-> bool)]) : ThreadSpawnResult
  (spawn
    (lambda ([_ignored : i64]) : i64
      (if (task)
        1
        0))
    0))

;: Private bridge used by generated `(handle (type unit))` modules.
(define (handle-spawn-unit [task : (-> unit)]) : ThreadSpawnResult
  (spawn
    (lambda ([_ignored : i64]) : i64
      (begin
        (task)
        0))
    0))

;: Spawn a compiler-checked direct nullary closure returning `String`.
;: The task runs with a fresh atomic arena as the active allocation target, then
;: copies its result into that arena before publishing it to the joiner. The
;: joined `String` therefore owns storage in an arena that can outlive both the
;: worker and the joining thread. The handle must be joined exactly once.
(define (spawn-string [task : (-> String)]) : ThreadStringSpawnResult
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [result : (__tl_dyn-array String)
      (in-arena owner (__tl_make-array String 1))]
    [result-addr : i64 (array-string-addr result)]
    (match (spawn
      (lambda ([_ignored : i64]) : i64
        (let
          [value : String (in-arena owner (task))]
          [copied : String (in-arena owner (string.copy (& value)))]
          (begin
            (write-string! result-addr copied)
            0)))
      0)
      [(ThreadSpawnOk raw) (ThreadStringSpawnOk (ThreadString raw result-addr))]
      [(ThreadSpawnErr message) (ThreadStringSpawnErr message)])))

;: Spawn a compiler-checked direct nullary closure returning an owned i64 Vec.
;:
;: The task runs with a fresh atomic arena as the active allocation target, then
;: copies the Vec's live prefix once into that arena before publishing it to the
;: joiner. The explicit copy prevents a task from laundering storage returned
;: from a non-spanning owner. The handle must be joined exactly once.
(define (spawn-i64-vec [task : (-> thread-i64-vec.Vec)]) : ThreadI64VecSpawnResult
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [result : (__tl_dyn-array thread-i64-vec.Vec)
      (in-arena owner (__tl_make-array thread-i64-vec.Vec 1))]
    [result-addr : i64 (array-i64-vec-addr result)]
    (match (spawn
      (lambda ([_ignored : i64]) : i64
        (let
          [value : thread-i64-vec.Vec (in-arena owner (task))]
          [copied : thread-i64-vec.Vec (in-arena owner (i64-vec-copy value))]
          (begin
            (write-i64-vec! result-addr copied)
            0)))
      0)
      [(ThreadSpawnOk raw) (ThreadI64VecSpawnOk (ThreadI64Vec raw result-addr))]
      [(ThreadSpawnErr message) (ThreadI64VecSpawnErr message)])))

;: Spawn a compiler-checked direct nullary closure returning `(Box i64)`.
;:
;: The task runs with a fresh atomic arena as the active allocation target, then
;: copies the boxed scalar payload to an atomic result cell. Join reconstructs a
;: fresh box in that same spanning owner. The handle must be joined exactly once.
(define (spawn-box-i64 [task : (-> (Box i64))]) : ThreadBoxI64SpawnResult
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [result : (__tl_dyn-array i64) (in-arena owner (__tl_make-array i64 1))]
    [result-addr : i64 (array-i64-addr result)]
    (match (spawn
      (lambda ([_ignored : i64]) : i64
        (let
          [value : (Box i64) (in-arena owner (task))]
          (begin
            (write-i64! result-addr (__tl-box-place value))
            0)))
      0)
      [(ThreadSpawnOk raw)
        (ThreadBoxI64SpawnOk (ThreadBoxI64 raw result-addr owner))]
      [(ThreadSpawnErr message) (ThreadBoxI64SpawnErr message)])))

;: True when a Linux futex result should be followed by another state/deadline check.
(define (linux-wait-retry? [status : i64]) : bool
  (or (= status 0) (= status -4) (= status -11) (= status -110)))

;: Linux non-consuming bounded wait over the kernel-owned clear-TID cell.
(define (linux-wait-for [thread : (& thread Thread)] [timeout-ms : i64]) : ThreadWaitResult
  (let
    [clear-addr : i64 thread.clear-tid-addr]
    (if (= (read-i32 clear-addr) (cast 0 : i32))
      (ThreadWaitReady)
      (if (= timeout-ms 0)
        (ThreadWaitTimedOut)
        (let
          [clock : (__tl_dyn-array i64) (__tl_make-array i64 2)]
          [timeout : (__tl_dyn-array i64) (__tl_make-array i64 2)]
          [start-ms : i64 (linux-monotonic-ms (&mut clock))]
          (if (< start-ms 0)
            (ThreadWaitErr "thread: wait monotonic clock unavailable")
            (let
              [done : bool false]
              [result : ThreadWaitResult (ThreadWaitTimedOut)]
              (begin
                (while (not done)
                  (if (= (read-i32 clear-addr) (cast 0 : i32))
                    (begin
                      (set! result (ThreadWaitReady))
                      (set! done true))
                    (let
                      [now-ms : i64 (linux-monotonic-ms (&mut clock))]
                      (if (< now-ms start-ms)
                        (begin
                          (set!
                            result
                            (ThreadWaitErr
                              "thread: wait monotonic clock unavailable"))
                          (set! done true))
                        (let
                          [elapsed-ms : i64 (- now-ms start-ms)]
                          (if (>= elapsed-ms timeout-ms)
                            (begin
                              (if (= (read-i32 clear-addr) (cast 0 : i32))
                                (set! result (ThreadWaitReady))
                                (set! result (ThreadWaitTimedOut)))
                              (set! done true))
                            (let
                              [remaining-ms : i64 (- timeout-ms elapsed-ms)]
                              (begin
                                (time.timespec-from-ms!
                                  (&mut timeout)
                                  remaining-ms)
                                (let
                                  [status : i64
                                    (linux-futex-wait-for
                                      clear-addr
                                      1
                                      (array-i64-addr (& timeout)))]
                                  (if (linux-wait-retry? status)
                                    unit
                                    (begin
                                      (set!
                                        result
                                        (ThreadWaitErr "thread: wait failed"))
                                      (set! done true))))))))))))
                result))))))))

;: Windows non-consuming bounded wait, split to avoid the `INFINITE` sentinel.
(cfg
  windows
  (define (thread-windows-wait-for
    [thread : (& thread Thread)]
    [timeout-ms : i64]) : ThreadWaitResult
    (let
      [remaining-ms : i64 timeout-ms]
      [done : bool false]
      [result : ThreadWaitResult (ThreadWaitTimedOut)]
      (begin
        (while (not done)
          (let
            [chunk-ms : i64
              (if (> remaining-ms windows-wait-max-finite-ms)
                windows-wait-max-finite-ms
                remaining-ms)]
            [waited : u32
              (thread-windows-wait-single thread.handle (cast chunk-ms : u32))]
            (cond
              [(= waited windows-wait-object-0)
                (begin
                  (set! result (ThreadWaitReady))
                  (set! done true))]
              [(= waited windows-wait-timeout)
                (if (<= remaining-ms chunk-ms)
                  (begin
                    (set! result (ThreadWaitTimedOut))
                    (set! done true))
                  (set! remaining-ms (- remaining-ms chunk-ms)))]
              [else
                (begin
                  (set! result (ThreadWaitErr "thread: wait failed"))
                  (set! done true))])))
        result))))

;: Observe thread completion for at most `timeout-ms` without consuming the handle.
;:
;: A timeout of zero is a nonblocking poll. Ready, timeout, and wait failure all
;: leave the handle valid for another wait and for exactly one later `join`.
(define (wait-for [thread : (& thread Thread)] [timeout-ms : i64]) : ThreadWaitResult
  (if (< timeout-ms 0)
    (ThreadWaitErr "thread: wait timeout must be nonnegative")
    (cfg
      windows
      (thread-windows-wait-for thread timeout-ms)
      (linux-wait-for thread timeout-ms))))

;: Wait for a Linux raw-clone thread to clear its join cell.
(define (linux-join [thread : Thread]) : ThreadJoinResult
  (let
    [clear-addr : i64 thread.clear-tid-addr]
    (begin
      (while (not (= (read-i32 clear-addr) (cast 0 : i32)))
        (begin
          (linux-futex-wait clear-addr (cast 1 : i64))
          unit))
      (ThreadJoinOk (read-i64 thread.result-addr)))))

;: Windows implementation of `join`.
(cfg
  windows
  (define (thread-windows-join [thread : Thread]) : ThreadJoinResult
    (let
      [waited : u32
        (thread-windows-wait-single thread.handle windows-wait-infinite)]
      (if (not (= waited windows-wait-object-0))
        (ThreadJoinErr "thread: join failed")
        (begin
          (thread-windows-close-handle thread.handle)
          (ThreadJoinOk (read-i64 thread.result-addr)))))))

;: Join a thread and return the entry function's i64 result.
(define (join [thread : Thread]) : ThreadJoinResult
  (cfg windows (thread-windows-join thread) (linux-join thread)))

;: Join a typed `String` thread and return its closure result.
(define (join-string [thread : ThreadString]) : ThreadStringJoinResult
  (match (join thread.raw)
    [(ThreadJoinOk _) (ThreadStringJoinOk (read-string thread.result-addr))]
    [(ThreadJoinErr message) (ThreadStringJoinErr message)]))

;: Join a typed i64 Vec thread and return its owned closure result.
(define (join-i64-vec [thread : ThreadI64Vec]) : ThreadI64VecJoinResult
  (match (join thread.raw)
    [(ThreadJoinOk _) (ThreadI64VecJoinOk (read-i64-vec thread.result-addr))]
    [(ThreadJoinErr message) (ThreadI64VecJoinErr message)]))

;: Join a typed `(Box i64)` thread and return its closure result.
(define (join-box-i64 [thread : ThreadBoxI64]) : ThreadBoxI64JoinResult
  (match (join thread.raw)
    [(ThreadJoinOk _)
      (ThreadBoxI64JoinOk
        (in-arena thread.owner (box (read-i64 thread.result-addr))))]
    [(ThreadJoinErr message) (ThreadBoxI64JoinErr message)]))

;: Count set bits in a positive byte value.
(define (count-byte-bits [byte : i64]) : i64
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
(define (count-affinity-bytes [mask : (__tl_dyn-array u8)]) : i64
  (let
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i (array-length mask))
        (begin
          (set!
            count
            (+ count (count-byte-bits (cast (array-ref mask i) : i64))))
          (set! i (+ i 1))))
      count)))

;: Linux implementation of `default-worker-count`.
(define (linux-default-worker-count) : i64
  (let
    [mask : (__tl_dyn-array u8) (__tl_make-array u8 128)]
    [rc : i64
      (unsafe
        (syscall 204 0 128 (array-u8-addr (& mask))))]
    (if (< rc 0)
      1
      (let
        [count : i64 (count-affinity-bytes mask)]
        (if (< count 1)
          1
          count)))))

;: Windows implementation of `default-worker-count`.
(cfg
  windows
  (define (thread-windows-default-worker-count) : i64
    (let
      [count : i64
        (cast (thread-windows-active-processor-count (cast 0xffff : u16)) : i64)]
      (if (< count 1)
        1
        count))))

;: Return the host's default worker count, falling back to 1.
(define (default-worker-count) : i64
  (cfg
    windows
    (thread-windows-default-worker-count)
    (linux-default-worker-count)))

;: Create a counting semaphore and return its raw handle, or `fallback`.
(define (semaphore-create-handle-or [initial : i64] [fallback : i64]) : i64
  (if (< initial 0)
    fallback
    (if (> initial (cast semaphore-max-count : i64))
      fallback
      (cfg
        windows
        (let
          [handle : i64
            (thread-windows-create-semaphore
              0
              (cast initial : i32)
              semaphore-max-count
              0)]
          (if (= handle 0)
            fallback
            handle))
        (let
          [fd : i64
            (unsafe
              (syscall 290 initial 1))]
          (if (< fd 0)
            fallback
            fd))))))

;: Create a counting semaphore.
(define (semaphore-create [initial : i64]) : ThreadSemaphoreResult
  (if (< initial 0)
    (ThreadSemaphoreErr "thread: semaphore initial count must be non-negative")
    (if (> initial (cast semaphore-max-count : i64))
      (ThreadSemaphoreErr "thread: semaphore initial count exceeds maximum")
      (let
        [handle : i64 (semaphore-create-handle-or initial -1)]
        (if (= handle -1)
          (ThreadSemaphoreErr "thread: semaphore create failed")
          (ThreadSemaphoreOk (ThreadSemaphore handle)))))))

;: Wait for one semaphore token.
(define (semaphore-wait [sem : ThreadSemaphore]) : bool
  (cfg
    windows
    (=
      (thread-windows-wait-single sem.handle windows-wait-infinite)
      windows-wait-object-0)
    (let
      [buf : (__tl_dyn-array u64) (__tl_make-array u64 1)]
      [done : bool false]
      [ok : bool false]
      (begin
        (while (not done)
          (let
            [n : i64
              (unsafe
                (syscall 0 sem.handle (array-u64-addr (& buf)) 8))]
            (if (= n 8)
              (begin
                (set! ok true)
                (set! done true))
              (if (= n -4)
                unit
                (set! done true)))))
        ok))))

;: Post one semaphore token.
(define (semaphore-post [sem : ThreadSemaphore]) : bool
  (cfg
    windows
    (not
      (=
        (thread-windows-release-semaphore sem.handle (cast 1 : i32) 0)
        (cast 0 : i32)))
    (let
      [buf : (__tl_dyn-array u64) (__tl_make-array u64 1)]
      (begin
        (set! (array-ref buf 0) (cast 1 : u64))
        (=
          (unsafe
            (syscall 1 sem.handle (array-u64-addr (& buf)) 8))
          8)))))

;: Close a semaphore handle.
(define (semaphore-close [sem : ThreadSemaphore]) : bool
  (cfg
    windows
    (not (= (thread-windows-close-handle sem.handle) (cast 0 : i32)))
    (=
      (unsafe
        (syscall 3 sem.handle))
      0)))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (test-fail)))

;: Inline test integer assertion.
(define (test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (test-assert (= actual expected)))

;: Inline test assertion for semaphore validation failures.
(define (test-assert-semaphore-err [initial : i64]) : unit
  (test-assert (= (semaphore-create-handle-or initial -1) -1)))

(test
  thread-api
  (let
    [mask : (__tl_dyn-array u8) (__tl_make-array u8 4)]
    (begin
      (set! (array-ref mask 0) (cast 0 : u8))
      (set! (array-ref mask 1) (cast 1 : u8))
      (set! (array-ref mask 2) (cast 3 : u8))
      (set! (array-ref mask 3) (cast 255 : u8))
      (test-assert (>= (default-worker-count) 1))
      (test-assert-i64-eq (count-byte-bits 0) 0)
      (test-assert-i64-eq (count-byte-bits 1) 1)
      (test-assert-i64-eq (count-byte-bits 3) 2)
      (test-assert-i64-eq (count-byte-bits 255) 8)
      (test-assert-i64-eq (count-affinity-bytes mask) 11)
      (test-assert-semaphore-err -1)
      (test-assert-semaphore-err 2147483648))))