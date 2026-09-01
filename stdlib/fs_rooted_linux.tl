;# stdlib/fs_rooted_linux.tl - Private rooted exclusive-create Linux leaf.
;#
;# This module is the Linux implementation boundary consumed by the future
;# cross-platform rooted filesystem adapter in `stdlib.fs`. The caller chooses
;# and trusts the staging-root prefix. After that root is opened, every child
;# operation is relative to a retained directory descriptor and accepts exactly
;# one validated component.
;#
;# Descendant acquisition uses `openat2` with
;# `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS |
;# RESOLVE_NO_XDEV`. There is deliberately no path-string, `chdir`,
;# `/proc/self/fd`, plain-`open`, or weaker `openat` fallback.
;#
;# Directory and file capabilities are cleanup-owning and move-only. Their only
;# source-visible field is an opaque state pointer; safe callers cannot copy or
;# close the raw descriptor. Explicit finish functions report close failures,
;# while lexical cleanup closes still-live descriptors on recoverable early
;# exits.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

;: Stable Linux rooted-operation outcomes. Numeric errno values never cross
;: this boundary.
(defenum FsLinuxRootedResult
  (LinuxRootedOk)
  (LinuxRootedInvalidComponent)
  (LinuxRootedNotFound)
  (LinuxRootedAlreadyExists)
  (LinuxRootedUnsafeResolution)
  (LinuxRootedWrongKind)
  (LinuxRootedPermissionDenied)
  (LinuxRootedUnsupported)
  (LinuxRootedIoFailure)
  (LinuxRootedCancelled)
  (LinuxRootedWriteFailure)
  (LinuxRootedModeFailure)
  (LinuxRootedFlushFailure)
  (LinuxRootedCloseFailure)
  (LinuxRootedClosed))

;: Portable file-mode intent owned by the Linux leaf.
(defenum FsLinuxRootedFileMode
  (LinuxRootedRegularFile)
  (LinuxRootedExecutableFile))

;: File completion preserves an operation failure and an independent close
;: failure. This avoids hiding a failed write/flush when close also fails.
(defstruct FsLinuxRootedFinishResult
  (operation FsLinuxRootedResult)
  (close FsLinuxRootedResult))

;: Audited Linux UAPI layout for `struct open_how`.
(defstruct FsLinuxOpenHow
  (:repr c)
  (flags u64)
  (mode u64)
  (resolve u64))

;: Linux x86-64 timespec used only by the compiled-in mount-race test pause.
(cfg
  fs-rooted-linux-test-hooks
  (defstruct FsLinuxRootedTestTimespec
    (:repr c)
    (seconds i64)
    (nanoseconds i64)))

;: Private mutable state shared by a single cleanup-owning capability. The raw
;: pointer wrapper prevents safe callers from projecting or copying `fd`.
(defstruct FsLinuxRootedHandleState
  (fd i64)
  (result FsLinuxRootedResult)
  (close FsLinuxRootedResult))

;: Return true exactly for successful rooted operations.
(define (linux-rooted-result-ok? [result : FsLinuxRootedResult]) : bool
  (match result
    [(LinuxRootedOk) true]
    [_ false]))

;: Return true when both the file operation and its one close succeeded.
(define (linux-rooted-finish-ok? [result : FsLinuxRootedFinishResult]) : bool
  (and
    (linux-rooted-result-ok? result.operation)
    (linux-rooted-result-ok? result.close)))

;: Operation portion of a file completion result.
(define (linux-rooted-finish-operation [result : FsLinuxRootedFinishResult]) : FsLinuxRootedResult
  result.operation)

;: Close portion of a file completion result.
(define (linux-rooted-finish-close [result : FsLinuxRootedFinishResult]) : FsLinuxRootedResult
  result.close)

;: Linux x86-64 syscall and ABI constants. Keep the value tests next to the
;: representation tests below so changing a target constant is deliberate.
(define fs-linux-rooted-syscall-write : i64
  1)

;: Linux x86-64 `close` syscall number.
(define fs-linux-rooted-syscall-close : i64
  3)

;: Linux x86-64 `fstat` syscall number.
(define fs-linux-rooted-syscall-fstat : i64
  5)

;: Linux x86-64 `fsync` syscall number.
(define fs-linux-rooted-syscall-fsync : i64
  74)

;: Linux x86-64 `fchmod` syscall number.
(define fs-linux-rooted-syscall-fchmod : i64
  91)

;: Linux x86-64 `openat` syscall number.
(define fs-linux-rooted-syscall-openat : i64
  257)

;: Linux x86-64 `mkdirat` syscall number.
(define fs-linux-rooted-syscall-mkdirat : i64
  258)

;: Linux x86-64 `openat2` syscall number.
(define fs-linux-rooted-syscall-openat2 : i64
  437)

;: Linux `AT_FDCWD` pseudo-descriptor.
(define fs-linux-rooted-at-fdcwd : i64
  -100)

;: Audited byte size of Linux `struct open_how`.
(define fs-linux-rooted-open-how-size : i64
  24)

;: Linux one-component `NAME_MAX` bound.
(define fs-linux-rooted-component-max-bytes : i64
  255)

;: Linux open flags used by this boundary.
(define fs-linux-rooted-o-wronly : u64
  (cast 1 : u64))

;: Linux `O_CREAT` flag.
(define fs-linux-rooted-o-creat : u64
  (cast 64 : u64))

;: Linux `O_EXCL` flag.
(define fs-linux-rooted-o-excl : u64
  (cast 128 : u64))

;: Linux `O_DIRECTORY` flag.
(define fs-linux-rooted-o-directory : u64
  (cast 65536 : u64))

;: Linux `O_NOFOLLOW` flag.
(define fs-linux-rooted-o-nofollow : u64
  (cast 131072 : u64))

;: Linux `O_CLOEXEC` flag.
(define fs-linux-rooted-o-cloexec : u64
  (cast 524288 : u64))

;: Linux `openat2` resolution flags.
(define fs-linux-rooted-resolve-no-xdev : u64
  (cast 1 : u64))

;: Linux `RESOLVE_NO_MAGICLINKS` flag.
(define fs-linux-rooted-resolve-no-magiclinks : u64
  (cast 2 : u64))

;: Linux `RESOLVE_NO_SYMLINKS` flag.
(define fs-linux-rooted-resolve-no-symlinks : u64
  (cast 4 : u64))

;: Linux `RESOLVE_BENEATH` flag.
(define fs-linux-rooted-resolve-beneath : u64
  (cast 8 : u64))

;: Complete descendant resolution policy. No individual bit is optional.
(define fs-linux-rooted-resolve-policy : u64
  (bit-or
    fs-linux-rooted-resolve-no-xdev
    (bit-or
      fs-linux-rooted-resolve-no-magiclinks
      (bit-or
        fs-linux-rooted-resolve-no-symlinks
        fs-linux-rooted-resolve-beneath))))

;: Root and retained child-directory open flags.
(define fs-linux-rooted-directory-open-flags : u64
  (bit-or
    fs-linux-rooted-o-directory
    (bit-or fs-linux-rooted-o-nofollow fs-linux-rooted-o-cloexec)))

;: Exclusive regular-file create flags.
(define fs-linux-rooted-file-create-flags : u64
  (bit-or
    fs-linux-rooted-o-wronly
    (bit-or
      fs-linux-rooted-o-creat
      (bit-or
        fs-linux-rooted-o-excl
        (bit-or fs-linux-rooted-o-nofollow fs-linux-rooted-o-cloexec)))))

;: Creation and final mode values.
(define fs-linux-rooted-private-directory-mode : u64
  (cast 448 : u64))

;: Initial private file mode (`0600`).
(define fs-linux-rooted-private-file-mode : u64
  (cast 384 : u64))

;: Final directory mode (`0755`).
(define fs-linux-rooted-directory-mode : u64
  (cast 493 : u64))

;: Final regular-file mode (`0644`).
(define fs-linux-rooted-regular-file-mode : u64
  (cast 420 : u64))

;: Final executable-file mode (`0755`).
(define fs-linux-rooted-executable-file-mode : u64
  (cast 493 : u64))

;: x86-64 Linux `struct stat` facts used only to verify an already-open fd.
(define fs-linux-rooted-stat-buffer-size : i64
  160)

;: x86-64 Linux `stat.st_mode` byte offset.
(define fs-linux-rooted-stat-mode-offset : i64
  24)

;: Linux `S_IFMT` mask.
(define fs-linux-rooted-stat-kind-mask : i64
  61440)

;: Linux `S_IFREG` value.
(define fs-linux-rooted-stat-regular-mode : i64
  32768)

;: Linux `S_IFDIR` value.
(define fs-linux-rooted-stat-directory-mode : i64
  16384)

;: Syscall-kind IDs used only by the compiled-in fault-injection gate.
(define fs-linux-rooted-syscall-kind-openat : i64
  1)

;: Fault-injection ID for `mkdirat`.
(define fs-linux-rooted-syscall-kind-mkdirat : i64
  2)

;: Fault-injection ID for `openat2`.
(define fs-linux-rooted-syscall-kind-openat2 : i64
  3)

;: Fault-injection ID for `fstat`.
(define fs-linux-rooted-syscall-kind-fstat : i64
  4)

;: Fault-injection ID for `fchmod`.
(define fs-linux-rooted-syscall-kind-fchmod : i64
  5)

;: Fault-injection ID for `write`.
(define fs-linux-rooted-syscall-kind-write : i64
  6)

;: Fault-injection ID for `fsync`.
(define fs-linux-rooted-syscall-kind-fsync : i64
  7)

;: Fault-injection ID for `close`.
(define fs-linux-rooted-syscall-kind-close : i64
  8)

;: Sentinel distinct from every valid raw syscall result.
(define fs-linux-rooted-no-injection : i64
  -9223372036854775808)

; Fault injection is absent from ordinary artifacts. The focused native gate
; compiles this cfg in both direct-object and assembly-fallback builds.
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-fail-kind : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-fail-call : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-fail-errno : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-write-max : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-openat-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-mkdirat-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-openat2-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-fstat-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-fchmod-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-write-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-fsync-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-close-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-mkdir-race-enabled : bool
    false))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-mkdir-race-ok : bool
    false))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-after-mkdir-pause-ms : i64
    0))

;: Reset every focused fault-injection setting and call counter.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-reset!) : unit
    (begin
      (set! fs-linux-rooted-test-fail-kind 0)
      (set! fs-linux-rooted-test-fail-call 0)
      (set! fs-linux-rooted-test-fail-errno 0)
      (set! fs-linux-rooted-test-write-max 0)
      (set! fs-linux-rooted-test-openat-calls 0)
      (set! fs-linux-rooted-test-mkdirat-calls 0)
      (set! fs-linux-rooted-test-openat2-calls 0)
      (set! fs-linux-rooted-test-fstat-calls 0)
      (set! fs-linux-rooted-test-fchmod-calls 0)
      (set! fs-linux-rooted-test-write-calls 0)
      (set! fs-linux-rooted-test-fsync-calls 0)
      (set! fs-linux-rooted-test-close-calls 0)
      (set! fs-linux-rooted-test-mkdir-race-enabled false)
      (set! fs-linux-rooted-test-mkdir-race-ok false)
      (set! fs-linux-rooted-test-after-mkdir-pause-ms 0))))

;: Inject `errno-code` (zero means a zero-progress return) for one numbered
;: syscall attempt of `kind`.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-fail-on!
    [kind : i64]
    [call : i64]
    [errno-code : i64]) : unit
    (begin
      (set! fs-linux-rooted-test-fail-kind kind)
      (set! fs-linux-rooted-test-fail-call call)
      (set! fs-linux-rooted-test-fail-errno errno-code))))

;: Bound each real write call to force deterministic short-write coverage.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-set-write-max! [count : i64]) : unit
    (set! fs-linux-rooted-test-write-max count)))

;: Enable a deterministic symlink substitution in the mkdir/openat2 race window.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-enable-mkdir-race!) : unit
    (set! fs-linux-rooted-test-mkdir-race-enabled true)))

;: Return whether the deterministic descriptor-relative substitution succeeded.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-mkdir-race-ok?) : bool
    fs-linux-rooted-test-mkdir-race-ok))

;: Pause after mkdir so a privileged shell gate can install a real bind mount
;: before openat2. Non-positive durations disable the pause.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-set-after-mkdir-pause-ms! [milliseconds : i64]) : unit
    (set! fs-linux-rooted-test-after-mkdir-pause-ms milliseconds)))

;: Return one focused syscall call count.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-call-count [kind : i64]) : i64
    (cond
      [(= kind fs-linux-rooted-syscall-kind-openat)
        fs-linux-rooted-test-openat-calls]
      [(= kind fs-linux-rooted-syscall-kind-mkdirat)
        fs-linux-rooted-test-mkdirat-calls]
      [(= kind fs-linux-rooted-syscall-kind-openat2)
        fs-linux-rooted-test-openat2-calls]
      [(= kind fs-linux-rooted-syscall-kind-fstat)
        fs-linux-rooted-test-fstat-calls]
      [(= kind fs-linux-rooted-syscall-kind-fchmod)
        fs-linux-rooted-test-fchmod-calls]
      [(= kind fs-linux-rooted-syscall-kind-write)
        fs-linux-rooted-test-write-calls]
      [(= kind fs-linux-rooted-syscall-kind-fsync)
        fs-linux-rooted-test-fsync-calls]
      [(= kind fs-linux-rooted-syscall-kind-close)
        fs-linux-rooted-test-close-calls]
      [else 0])))

;: Record one syscall attempt and return an injected raw result or the sentinel.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-injected-result [kind : i64]) : i64
    (let
      [call : i64
        (cond
          [(= kind fs-linux-rooted-syscall-kind-openat)
            (begin
              (set!
                fs-linux-rooted-test-openat-calls
                (+ fs-linux-rooted-test-openat-calls 1))
              fs-linux-rooted-test-openat-calls)]
          [(= kind fs-linux-rooted-syscall-kind-mkdirat)
            (begin
              (set!
                fs-linux-rooted-test-mkdirat-calls
                (+ fs-linux-rooted-test-mkdirat-calls 1))
              fs-linux-rooted-test-mkdirat-calls)]
          [(= kind fs-linux-rooted-syscall-kind-openat2)
            (begin
              (set!
                fs-linux-rooted-test-openat2-calls
                (+ fs-linux-rooted-test-openat2-calls 1))
              fs-linux-rooted-test-openat2-calls)]
          [(= kind fs-linux-rooted-syscall-kind-fstat)
            (begin
              (set!
                fs-linux-rooted-test-fstat-calls
                (+ fs-linux-rooted-test-fstat-calls 1))
              fs-linux-rooted-test-fstat-calls)]
          [(= kind fs-linux-rooted-syscall-kind-fchmod)
            (begin
              (set!
                fs-linux-rooted-test-fchmod-calls
                (+ fs-linux-rooted-test-fchmod-calls 1))
              fs-linux-rooted-test-fchmod-calls)]
          [(= kind fs-linux-rooted-syscall-kind-write)
            (begin
              (set!
                fs-linux-rooted-test-write-calls
                (+ fs-linux-rooted-test-write-calls 1))
              fs-linux-rooted-test-write-calls)]
          [(= kind fs-linux-rooted-syscall-kind-fsync)
            (begin
              (set!
                fs-linux-rooted-test-fsync-calls
                (+ fs-linux-rooted-test-fsync-calls 1))
              fs-linux-rooted-test-fsync-calls)]
          [(= kind fs-linux-rooted-syscall-kind-close)
            (begin
              (set!
                fs-linux-rooted-test-close-calls
                (+ fs-linux-rooted-test-close-calls 1))
              fs-linux-rooted-test-close-calls)]
          [else 0])]
      (if (and
        (= kind fs-linux-rooted-test-fail-kind)
        (= call fs-linux-rooted-test-fail-call))
        (- 0 fs-linux-rooted-test-fail-errno)
        fs-linux-rooted-no-injection))))

;: Erased production bridge to the optional injection state.
(define (linux-rooted-injected-result [_kind : i64]) : i64
  (cfg
    fs-rooted-linux-test-hooks
    (linux-rooted-test-injected-result _kind)
    fs-linux-rooted-no-injection))

;: Erased production bridge to the short-write limit.
(define (linux-rooted-write-request-count [count : i64]) : i64
  (cfg
    fs-rooted-linux-test-hooks
    (if (and
      (> fs-linux-rooted-test-write-max 0)
      (> count fs-linux-rooted-test-write-max))
      fs-linux-rooted-test-write-max
      count)
    count))

;: Convert a pointer into the integer form expected by the syscall ABI.
(unsafe
  (define (linux-rooted-ptr-arg [ptr : (Ptr u8)]) : i64
    (unsafe
      (cast (ptr->int ptr) : i64))))

;: Deterministically replace a just-created child directory with an
;: outside-pointing symlink. This is compiled only into the native adversarial
;: gate.
(cfg
  fs-rooted-linux-test-hooks
  (unsafe
    (define (linux-rooted-test-replace-mkdir-with-symlink
      [parent-fd : i64]
      [component : (Ptr u8)]) : unit
      (let
        [saved : String "race-original"]
        [target : String "../outside"]
        [saved-c : (__tl_dyn-array u8) (linux-rooted-c-string (& saved))]
        [target-c : (__tl_dyn-array u8) (linux-rooted-c-string (& target))]
        [saved-ptr : (Ptr u8) (io.array-const-ptr saved-c)]
        [target-ptr : (Ptr u8) (io.array-const-ptr target-c)]
        [rename-result : i64
          (cfg
            windows
            -38
            (unsafe
              (syscall
                264
                parent-fd
                (linux-rooted-ptr-arg component)
                parent-fd
                (linux-rooted-ptr-arg saved-ptr))))]
        [symlink-result : i64
          (if (= rename-result 0)
            (cfg
              windows
              -38
              (unsafe
                (syscall
                  266
                  (linux-rooted-ptr-arg target-ptr)
                  parent-fd
                  (linux-rooted-ptr-arg component))))
            -1)]
        (set!
          fs-linux-rooted-test-mkdir-race-ok
          (and (= rename-result 0) (= symlink-result 0)))))))

(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-pause-after-mkdir) : unit
    (if (<= fs-linux-rooted-test-after-mkdir-pause-ms 0)
      unit
      (let
        [seconds : i64 (/ fs-linux-rooted-test-after-mkdir-pause-ms 1000)]
        [milliseconds : i64 (% fs-linux-rooted-test-after-mkdir-pause-ms 1000)]
        [duration : FsLinuxRootedTestTimespec
          (FsLinuxRootedTestTimespec seconds (* milliseconds 1000000))]
        [raw : i64 -4]
        (while (= raw -4)
          (set!
            raw
            (cfg
              windows
              -38
              (unsafe
                (syscall
                  35
                  (cast
                    (ptr->int (ptr-cast (ptr-addr-of duration) : (Ptr u8)))
                    : i64)
                  0)))))))))

;: Erased production bridge to the deterministic race-window hook.
(unsafe
  (define (linux-rooted-after-mkdir [_parent-fd : i64] [_component : (Ptr u8)]) : unit
    (cfg
      fs-rooted-linux-test-hooks
      (begin
        (if fs-linux-rooted-test-mkdir-race-enabled
          (unsafe
            (linux-rooted-test-replace-mkdir-with-symlink _parent-fd _component))
          unit)
        (linux-rooted-test-pause-after-mkdir))
      unit)))

;: Raw Linux `openat` used only to acquire the caller-selected root prefix.
(unsafe
  (define (linux-rooted-raw-openat
    [dirfd : i64]
    [path : (Ptr u8)]
    [flags : u64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-openat)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-openat
              dirfd
              (linux-rooted-ptr-arg path)
              (cast flags : i64)
              0)))))))

;: Raw Linux `mkdirat` for one already-validated child component.
(unsafe
  (define (linux-rooted-raw-mkdirat
    [dirfd : i64]
    [path : (Ptr u8)]
    [mode : u64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-mkdirat)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-mkdirat
              dirfd
              (linux-rooted-ptr-arg path)
              (cast mode : i64))))))))

;: Raw Linux `openat2` with an exact 24-byte `open_how`.
(unsafe
  (define (linux-rooted-raw-openat2
    [dirfd : i64]
    [path : (Ptr u8)]
    [how : FsLinuxOpenHow]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-openat2)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-openat2
              dirfd
              (linux-rooted-ptr-arg path)
              (cast (ptr->int (ptr-cast (ptr-addr-of how) : (Ptr u8))) : i64)
              fs-linux-rooted-open-how-size)))))))

;: Raw Linux `fstat` for kind verification on an acquired descriptor.
(unsafe
  (define (linux-rooted-raw-fstat [fd : i64] [statbuf : (MutPtr u8)]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-fstat)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-fstat
              fd
              (cast (ptr->int (ptr-cast statbuf : (Ptr u8))) : i64))))))))

;: Raw Linux `fchmod` used after exclusive creation.
(unsafe
  (define (linux-rooted-raw-fchmod [fd : i64] [mode : u64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-fchmod)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall fs-linux-rooted-syscall-fchmod fd (cast mode : i64))))))))

;: Raw Linux `write`, optionally bounded by the focused short-write hook.
(unsafe
  (define (linux-rooted-raw-write [fd : i64] [data : (Ptr u8)] [count : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-write)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-write
              fd
              (linux-rooted-ptr-arg data)
              (linux-rooted-write-request-count count))))))))

;: Raw Linux `fsync` for an explicitly requested durability boundary.
(unsafe
  (define (linux-rooted-raw-fsync [fd : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-fsync)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall fs-linux-rooted-syscall-fsync fd)))))))

;: Raw Linux `close`. An injected failure still performs the real close first,
;: so the fault-injection gate cannot leak descriptors. Production and logical
;: test code issue exactly one close attempt and never retry EINTR.
(unsafe
  (define (linux-rooted-raw-close [fd : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-close)]
      (if (not (= injected fs-linux-rooted-no-injection))
        (begin
          (cfg
            windows
            -38
            (unsafe
              (syscall fs-linux-rooted-syscall-close fd)))
          injected)
        (cfg
          windows
          -38
          (unsafe
            (syscall fs-linux-rooted-syscall-close fd)))))))

;: Collapse one private Linux errno into the stable rooted taxonomy.
(define (linux-rooted-result-from-errno [code : i64]) : FsLinuxRootedResult
  (cond
    [(= code 0) LinuxRootedOk]
    [(or (= code 4) (= code 125)) LinuxRootedCancelled]
    [(= code 2) LinuxRootedNotFound]
    [(= code 17) LinuxRootedAlreadyExists]
    [(or (= code 11) (= code 18) (= code 40)) LinuxRootedUnsafeResolution]
    [(or (= code 20) (= code 21)) LinuxRootedWrongKind]
    [(or (= code 1) (= code 13) (= code 30)) LinuxRootedPermissionDenied]
    [(or (= code 7) (= code 22) (= code 38) (= code 95)) LinuxRootedUnsupported]
    [(= code 36) LinuxRootedInvalidComponent]
    [else LinuxRootedIoFailure]))

;: Convert a raw negative syscall result to the stable taxonomy.
(define (linux-rooted-result-from-raw [raw : i64]) : FsLinuxRootedResult
  (if (< raw 0)
    (linux-rooted-result-from-errno (- 0 raw))
    LinuxRootedOk))

;: True when a caller-selected root path can be copied to a C string without
;: truncation or signed-length overflow. Separators and dot components are
;: allowed here because the prefix is explicitly outside the descendant trust
;: boundary.
(define (linux-rooted-root-path-valid? [path : (& path str)]) : bool
  (let
    [len : i64 (string-length path)]
    (and
      (> len 0)
      (< len 9223372036854775807)
      (< (string.index-of-byte path 0 (cast 0 : u8)) 0))))

;: Defensive one-component validation. The future portable adapter performs
;: checked UTF-8 scalar validation first; this Linux leaf still rejects every
;: byte shape that could change resolution or overflow its C-string copy.
(define (linux-rooted-component-valid? [component : (& component str)]) : bool
  (let
    [len : i64 (string-length component)]
    (and
      (> len 0)
      (<= len fs-linux-rooted-component-max-bytes)
      (not (string.eq component "."))
      (not (string.eq component ".."))
      (< (string.index-of-byte component 0 (cast 0 : u8)) 0)
      (< (string.index-of-byte component 0 (cast '/' : u8)) 0)
      (< (string.index-of-byte component 0 (cast '\\' : u8)) 0))))

;: Allocate one NUL-terminated copy after validation has bounded `len + 1`.
(define (linux-rooted-c-string [text : (& text str)]) : (__tl_dyn-array u8)
  (io.c-string text))

;: Read a u32 field from an x86-64 `struct stat` buffer.
(unsafe
  (define (linux-rooted-stat-u32 [statbuf : (MutPtr u8)] [offset : i64]) : u32
    (unsafe
      (ptr-read (ptr-cast (ptr-offset statbuf offset) : (Ptr u32))))))

;: Verify the exact kind of an acquired fd without reopening a name.
(unsafe
  (define (linux-rooted-verify-kind
    [fd : i64]
    [expected-mode : i64]
    [cancel-check : (-> bool)]) : FsLinuxRootedResult
    (if (cancel-check)
      LinuxRootedCancelled
      (let
        [stat-bytes : (__tl_dyn-array u8)
          (__tl_make-array u8 fs-linux-rooted-stat-buffer-size)]
        [statbuf : (MutPtr u8)
          (unsafe
            (__tl_array-data stat-bytes))]
        [raw : i64
          (unsafe
            (linux-rooted-raw-fstat fd statbuf))]
        (if (< raw 0)
          (linux-rooted-result-from-raw raw)
          (if (=
            (bit-and
              (cast
                (unsafe
                  (linux-rooted-stat-u32
                    statbuf
                    fs-linux-rooted-stat-mode-offset))
                : i64)
              fs-linux-rooted-stat-kind-mask)
            expected-mode)
            LinuxRootedOk
            LinuxRootedWrongKind))))))

;: Apply one mode, retrying only the unambiguous retained-fd EINTR case.
(unsafe
  (define (linux-rooted-apply-mode
    [fd : i64]
    [mode : u64]
    [cancel-check : (-> bool)]) : FsLinuxRootedResult
    (let
      [raw : i64 -4]
      (begin
        (while (and (= raw -4) (not (cancel-check)))
          (set!
            raw
            (unsafe
              (linux-rooted-raw-fchmod fd mode))))
        (cond
          [(= raw 0) LinuxRootedOk]
          [(or (= raw -4) (= raw -125)) LinuxRootedCancelled]
          [else LinuxRootedModeFailure])))))

;: Flush one retained fd, retrying EINTR while cancellation remains clear.
(unsafe
  (define (linux-rooted-flush-fd [fd : i64] [cancel-check : (-> bool)]) : FsLinuxRootedResult
    (let
      [raw : i64 -4]
      (begin
        (while (and (= raw -4) (not (cancel-check)))
          (set!
            raw
            (unsafe
              (linux-rooted-raw-fsync fd))))
        (cond
          [(= raw 0) LinuxRootedOk]
          [(or (= raw -4) (= raw -125)) LinuxRootedCancelled]
          [else LinuxRootedFlushFailure])))))

;: Close one raw fd exactly once. Linux close is never retried because EINTR
;: leaves descriptor state unspecified and a retry could close a reused fd.
(unsafe
  (define (linux-rooted-close-fd-once [fd : i64]) : FsLinuxRootedResult
    (if (< fd 0)
      LinuxRootedClosed
      (if (=
        (unsafe
          (linux-rooted-raw-close fd))
        0)
        LinuxRootedOk
        LinuxRootedCloseFailure))))

;: Allocate private active-arena state for one capability.
(unsafe
  (define (linux-rooted-state-new [fd : i64] [result : FsLinuxRootedResult]) : (MutPtr
      FsLinuxRootedHandleState)
    (let
      [states : (__tl_dyn-array FsLinuxRootedHandleState)
        (__tl_make-array FsLinuxRootedHandleState 1)]
      [state : (MutPtr FsLinuxRootedHandleState)
        (unsafe
          (__tl_array-data states))]
      (begin
        (unsafe
          (ptr-write!
            state
            (FsLinuxRootedHandleState fd result LinuxRootedClosed)))
        state))))

;: Snapshot private state, failing closed for a null pointer.
(unsafe
  (define (linux-rooted-state-read [state : (MutPtr FsLinuxRootedHandleState)]) : FsLinuxRootedHandleState
    (if (ptr-null? state)
      (FsLinuxRootedHandleState -1 LinuxRootedClosed LinuxRootedClosed)
      (unsafe
        (ptr-read state)))))

;: Store private state after checking its opaque pointer.
(unsafe
  (define (linux-rooted-state-write!
    [state : (MutPtr FsLinuxRootedHandleState)]
    [value : FsLinuxRootedHandleState]) : unit
    (if (ptr-null? state)
      unit
      (unsafe
        (ptr-write! state value)))))

;: Allocate private state for a constructor that acquired and then closed an
;: fd. Both outcomes remain inspectable instead of collapsing a close failure
;: into the primary verification or mode result.
(unsafe
  (define (linux-rooted-state-new-after-close
    [result : FsLinuxRootedResult]
    [close-result : FsLinuxRootedResult]) : (MutPtr FsLinuxRootedHandleState)
    (let
      [state : (MutPtr FsLinuxRootedHandleState)
        (unsafe
          (linux-rooted-state-new -1 result))]
      (begin
        (unsafe
          (linux-rooted-state-write!
            state
            (FsLinuxRootedHandleState -1 result close-result)))
        state))))

;: Close one state exactly once and poison its fd before the syscall.
(unsafe
  (define (linux-rooted-state-close-result
    [state-ptr : (MutPtr FsLinuxRootedHandleState)]) : FsLinuxRootedResult
    (let
      [state : FsLinuxRootedHandleState
        (unsafe
          (linux-rooted-state-read state-ptr))]
      [fd : i64 state.fd]
      (if (< fd 0)
        LinuxRootedClosed
        (begin
          (unsafe
            (linux-rooted-state-write!
              state-ptr
              (FsLinuxRootedHandleState -1 state.result LinuxRootedClosed)))
          (let
            [result : FsLinuxRootedResult
              (unsafe
                (linux-rooted-close-fd-once fd))]
            (begin
              (unsafe
                (linux-rooted-state-write!
                  state-ptr
                  (FsLinuxRootedHandleState -1 state.result result)))
              result)))))))

;: Cleanup-field adapter. Close failures are observable only through explicit
;: finish/close APIs; lexical cleanup must return unit.
(define (linux-rooted-state-cleanup [state : (MutPtr FsLinuxRootedHandleState)]) : unit
  (begin
    (unsafe
      (linux-rooted-state-close-result state))
    unit))

;: Cleanup-owning, move-only rooted directory capability.
(defstruct FsLinuxRootedDirectory
  (:cleanup cleanup-linux-rooted-directory)
  (state
    (MutPtr FsLinuxRootedHandleState)
    (:cleanup linux-rooted-state-cleanup)))

;: Cleanup-owning, move-only exclusive child-file capability.
(defstruct FsLinuxRootedFile
  (:cleanup cleanup-linux-rooted-file)
  (state
    (MutPtr FsLinuxRootedHandleState)
    (:cleanup linux-rooted-state-cleanup)))

;: Return the stable construction/current result without exposing the fd.
(define (linux-rooted-directory-result
  [directory : (& directory FsLinuxRootedDirectory)]) : FsLinuxRootedResult
  (let
    [state : FsLinuxRootedHandleState
      (unsafe
        (linux-rooted-state-read directory.state))]
    state.result))

;: Return the stable construction/current result without exposing the fd.
(define (linux-rooted-file-result [file : (& file FsLinuxRootedFile)]) : FsLinuxRootedResult
  (let
    [state : FsLinuxRootedHandleState
      (unsafe
        (linux-rooted-state-read file.state))]
    state.result))

;: Return the close outcome recorded by a constructor or explicit close. A
;: live or never-opened capability reports `LinuxRootedClosed` because no close
;: attempt has occurred.
(define (linux-rooted-directory-close-result
  [directory : (& directory FsLinuxRootedDirectory)]) : FsLinuxRootedResult
  (let
    [state : FsLinuxRootedHandleState
      (unsafe
        (linux-rooted-state-read directory.state))]
    state.close))

;: Return the recorded close outcome for a rooted file capability.
(define (linux-rooted-file-close-result [file : (& file FsLinuxRootedFile)]) : FsLinuxRootedResult
  (let
    [state : FsLinuxRootedHandleState
      (unsafe
        (linux-rooted-state-read file.state))]
    state.close))

;: True when a directory capability owns a live descriptor.
(define (linux-rooted-directory-open?
  [directory : (& directory FsLinuxRootedDirectory)]) : bool
  (let
    [state : FsLinuxRootedHandleState
      (unsafe
        (linux-rooted-state-read directory.state))]
    (and (>= state.fd 0) (linux-rooted-result-ok? state.result))))

;: True when a file capability owns a live descriptor.
(define (linux-rooted-file-open? [file : (& file FsLinuxRootedFile)]) : bool
  (let
    [state : FsLinuxRootedHandleState
      (unsafe
        (linux-rooted-state-read file.state))]
    (and (>= state.fd 0) (linux-rooted-result-ok? state.result))))

;: A cancellation callback suitable for callers without cancellation state.
(define (linux-rooted-never-cancelled) : bool
  false)

;: Build a failed directory capability so every constructor has one ownership
;: shape and callers always bind it with its declared cleanup function.
(define (linux-rooted-failed-directory [result : FsLinuxRootedResult]) : FsLinuxRootedDirectory
  (FsLinuxRootedDirectory
    (unsafe
      (linux-rooted-state-new -1 result))))

;: Build a failed file capability.
(define (linux-rooted-failed-file [result : FsLinuxRootedResult]) : FsLinuxRootedFile
  (FsLinuxRootedFile
    (unsafe
      (linux-rooted-state-new -1 result))))

;: Close an acquired fd after a post-open verification failure. No name is
;: removed or reopened, and the close result remains independently observable.
(unsafe
  (define (linux-rooted-discard-fd [fd : i64]) : FsLinuxRootedResult
    (unsafe
      (linux-rooted-close-fd-once fd))))

;: Preserve a failed directory construction and its independent close result.
(unsafe
  (define (linux-rooted-failed-directory-after-close
    [result : FsLinuxRootedResult]
    [fd : i64]) : FsLinuxRootedDirectory
    (FsLinuxRootedDirectory
      (unsafe
        (linux-rooted-state-new-after-close
          result
          (unsafe
            (linux-rooted-discard-fd fd)))))))

;: Preserve a failed file construction and its independent close result.
(unsafe
  (define (linux-rooted-failed-file-after-close
    [result : FsLinuxRootedResult]
    [fd : i64]) : FsLinuxRootedFile
    (FsLinuxRootedFile
      (unsafe
        (linux-rooted-state-new-after-close
          result
          (unsafe
            (linux-rooted-discard-fd fd)))))))

;: Open the caller-selected staging root. Resolution of prefix ancestors is
;: caller-trusted; the final node is protected by O_NOFOLLOW, required to be a
;: directory, and marked close-on-exec. Descendants never use this path again.
(define (linux-rooted-open-root
  [path : (& path str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedDirectory
  (unsafe
    (cond
      [(not (linux-rooted-root-path-valid? path))
        (linux-rooted-failed-directory LinuxRootedInvalidComponent)]
      [(cancel-check) (linux-rooted-failed-directory LinuxRootedCancelled)]
      [else
        (let
          [path-bytes : (__tl_dyn-array u8) (linux-rooted-c-string path)]
          [fd : i64
            (linux-rooted-raw-openat
              fs-linux-rooted-at-fdcwd
              (io.array-const-ptr path-bytes)
              fs-linux-rooted-directory-open-flags)]
          (if (< fd 0)
            (linux-rooted-failed-directory (linux-rooted-result-from-raw fd))
            (let
              [kind-result : FsLinuxRootedResult
                (linux-rooted-verify-kind
                  fd
                  fs-linux-rooted-stat-directory-mode
                  cancel-check)]
              (if (linux-rooted-result-ok? kind-result)
                (FsLinuxRootedDirectory
                  (linux-rooted-state-new fd LinuxRootedOk))
                (linux-rooted-failed-directory-after-close kind-result fd)))))])))

;: Create one child directory exclusively with mkdirat, reacquire it only with
;: the complete openat2 policy, verify directory kind, apply 0755, and retain
;: the descriptor. A failure after mkdir leaves the possibly substituted name
;: for the caller's unique-stage cleanup; this leaf never deletes it.
(define (linux-rooted-create-directory
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedDirectory
  (unsafe
    (let
      [parent-state : FsLinuxRootedHandleState
        (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          (linux-rooted-failed-directory LinuxRootedInvalidComponent)]
        [(or
            (< parent-state.fd 0)
            (not (linux-rooted-result-ok? parent-state.result)))
          (linux-rooted-failed-directory LinuxRootedClosed)]
        [(cancel-check) (linux-rooted-failed-directory LinuxRootedCancelled)]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [component-ptr : (Ptr u8) (io.array-const-ptr component-bytes)]
            [mkdir-raw : i64
              (linux-rooted-raw-mkdirat
                parent-state.fd
                component-ptr
                fs-linux-rooted-private-directory-mode)]
            (if (< mkdir-raw 0)
              (linux-rooted-failed-directory
                (linux-rooted-result-from-raw mkdir-raw))
              (begin
                (linux-rooted-after-mkdir parent-state.fd component-ptr)
                (if (cancel-check)
                  (linux-rooted-failed-directory LinuxRootedCancelled)
                  (let
                    [how : FsLinuxOpenHow
                      (FsLinuxOpenHow
                        fs-linux-rooted-directory-open-flags
                        (cast 0 : u64)
                        fs-linux-rooted-resolve-policy)]
                    [fd : i64
                      (linux-rooted-raw-openat2
                        parent-state.fd
                        component-ptr
                        how)]
                    (if (< fd 0)
                      (linux-rooted-failed-directory
                        (linux-rooted-result-from-raw fd))
                      (let
                        [kind-result : FsLinuxRootedResult
                          (linux-rooted-verify-kind
                            fd
                            fs-linux-rooted-stat-directory-mode
                            cancel-check)]
                        (if (not (linux-rooted-result-ok? kind-result))
                          (linux-rooted-failed-directory-after-close
                            kind-result
                            fd)
                          (let
                            [mode-result : FsLinuxRootedResult
                              (linux-rooted-apply-mode
                                fd
                                fs-linux-rooted-directory-mode
                                cancel-check)]
                            (if (linux-rooted-result-ok? mode-result)
                              (FsLinuxRootedDirectory
                                (linux-rooted-state-new fd LinuxRootedOk))
                              (linux-rooted-failed-directory-after-close
                                mode-result
                                fd)))))))))))]))))

;: Create one regular child file atomically through one openat2 call. O_EXCL
;: means an existing file, directory, symlink, or other node is never reopened
;: as success. The file remains private 0600 until explicit finish applies its
;: requested final mode.
(define (linux-rooted-create-file
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedFile
  (unsafe
    (let
      [parent-state : FsLinuxRootedHandleState
        (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          (linux-rooted-failed-file LinuxRootedInvalidComponent)]
        [(or
            (< parent-state.fd 0)
            (not (linux-rooted-result-ok? parent-state.result)))
          (linux-rooted-failed-file LinuxRootedClosed)]
        [(cancel-check) (linux-rooted-failed-file LinuxRootedCancelled)]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [component-ptr : (Ptr u8) (io.array-const-ptr component-bytes)]
            [how : FsLinuxOpenHow
              (FsLinuxOpenHow
                fs-linux-rooted-file-create-flags
                fs-linux-rooted-private-file-mode
                fs-linux-rooted-resolve-policy)]
            [fd : i64
              (linux-rooted-raw-openat2 parent-state.fd component-ptr how)]
            (if (< fd 0)
              (linux-rooted-failed-file (linux-rooted-result-from-raw fd))
              (let
                [kind-result : FsLinuxRootedResult
                  (linux-rooted-verify-kind
                    fd
                    fs-linux-rooted-stat-regular-mode
                    cancel-check)]
                (if (linux-rooted-result-ok? kind-result)
                  (FsLinuxRootedFile (linux-rooted-state-new fd LinuxRootedOk))
                  (linux-rooted-failed-file-after-close kind-result fd)))))]))))

;: Write exactly `promised-length` bytes, retrying partial writes and EINTR.
;: A zero-progress write is a stable write failure. The caller's cancellation
;: callback is checked before every attempt.
(unsafe
  (define (linux-rooted-write-all
    [fd : i64]
    [contents : (& contents bytes)]
    [promised-length : i64]
    [cancel-check : (-> bool)]) : FsLinuxRootedResult
    (let
      [actual-length : i64 (byte_buf.bytes-length contents)]
      (if (or (< promised-length 0) (not (= promised-length actual-length)))
        LinuxRootedWriteFailure
        (let
          [data : (Ptr u8)
            (unsafe
              (byte_buf.bytes-data contents))]
          [offset : i64 0]
          [result : FsLinuxRootedResult LinuxRootedOk]
          (begin
            (while (and
              (linux-rooted-result-ok? result)
              (< offset promised-length))
              (if (cancel-check)
                (set! result LinuxRootedCancelled)
                (let
                  [written : i64
                    (unsafe
                      (linux-rooted-raw-write
                        fd
                        (unsafe
                          (ptr-offset data offset))
                        (- promised-length offset)))]
                  (cond
                    [(> written 0) (set! offset (+ offset written))]
                    [(= written -4) unit]
                    [(= written -125) (set! result LinuxRootedCancelled)]
                    [else (set! result LinuxRootedWriteFailure)]))))
            (if (and
              (linux-rooted-result-ok? result)
              (not (= offset promised-length)))
              LinuxRootedWriteFailure
              result)))))))

;: Return the concrete final Linux mode for one portable file intent.
(define (linux-rooted-file-mode-value [mode : FsLinuxRootedFileMode]) : u64
  (match mode
    [(LinuxRootedRegularFile) fs-linux-rooted-regular-file-mode]
    [(LinuxRootedExecutableFile) fs-linux-rooted-executable-file-mode]))

;: Finish a child file. Every path attempts one close after the optional
;: write/mode/flush work; close status is returned independently. The state fd
;: is poisoned before close so lexical cleanup is an idempotent no-op.
(define (linux-rooted-file-finish!
  [file : (&mut file FsLinuxRootedFile)]
  [contents : (& contents bytes)]
  [promised-length : i64]
  [mode : FsLinuxRootedFileMode]
  [flush : bool]
  [cancel-check : (-> bool)]) : FsLinuxRootedFinishResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read file.state)]
      (if (or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
        (FsLinuxRootedFinishResult LinuxRootedClosed LinuxRootedClosed)
        (let
          [operation : FsLinuxRootedResult
            (linux-rooted-write-all
              state.fd
              contents
              promised-length
              cancel-check)]
          (begin
            (if (linux-rooted-result-ok? operation)
              (set!
                operation
                (linux-rooted-apply-mode
                  state.fd
                  (linux-rooted-file-mode-value mode)
                  cancel-check))
              unit)
            (if (and (linux-rooted-result-ok? operation) flush)
              (set! operation (linux-rooted-flush-fd state.fd cancel-check))
              unit)
            (linux-rooted-state-write!
              file.state
              (FsLinuxRootedHandleState state.fd operation LinuxRootedClosed))
            (let
              [close-result : FsLinuxRootedResult
                (linux-rooted-state-close-result file.state)]
              (FsLinuxRootedFinishResult operation close-result))))))))

;: Explicitly close a rooted directory and report the one close attempt. This
;: is used when overall operation success must include directory close success;
;: lexical cleanup remains the early-return fallback.
(define (linux-rooted-directory-close!
  [directory : (&mut directory FsLinuxRootedDirectory)]) : FsLinuxRootedResult
  (unsafe
    (linux-rooted-state-close-result directory.state)))

;: Explicitly close an unfinished file without writing it.
(define (linux-rooted-file-close! [file : (&mut file FsLinuxRootedFile)]) : FsLinuxRootedResult
  (unsafe
    (linux-rooted-state-close-result file.state)))

;; Inline tests cover target-independent validation, errno normalization, and
;; the audited `open_how` ABI. Linux syscall behavior has a separate native
;; integration gate so these tests remain runnable on Windows CI.
(cfg test (import stdlib.test))

(cfg
  test
  (define (linux-rooted-test-result-code [result : FsLinuxRootedResult]) : i64
    (match result
      [(LinuxRootedOk) 0]
      [(LinuxRootedInvalidComponent) 1]
      [(LinuxRootedNotFound) 2]
      [(LinuxRootedAlreadyExists) 3]
      [(LinuxRootedUnsafeResolution) 4]
      [(LinuxRootedWrongKind) 5]
      [(LinuxRootedPermissionDenied) 6]
      [(LinuxRootedUnsupported) 7]
      [(LinuxRootedIoFailure) 8]
      [(LinuxRootedCancelled) 9]
      [(LinuxRootedWriteFailure) 10]
      [(LinuxRootedModeFailure) 11]
      [(LinuxRootedFlushFailure) 12]
      [(LinuxRootedCloseFailure) 13]
      [(LinuxRootedClosed) 14])))

(cfg
  test
  (define (linux-rooted-test-string-with-nul) : String
    (let
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
      [data : (MutPtr u8)
        (unsafe
          (__tl_array-data bytes))]
      (begin
        (set! (array-ref bytes 0) (cast 'a' : u8))
        (set! (array-ref bytes 1) (cast 0 : u8))
        (set! (array-ref bytes 2) (cast 'b' : u8))
        (unsafe
          (string-from-bytes (ptr-cast data : (Ptr u8)) 3))))))

(cfg
  test
  (define (linux-rooted-test-long-component [length : i64]) : String
    (let
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 length)]
      [index : i64 0]
      (begin
        (while (< index length)
          (begin
            (set! (array-ref bytes index) (cast 'x' : u8))
            (set! index (+ index 1))))
        (unsafe
          (string-from-bytes
            (ptr-cast (__tl_array-data bytes) : (Ptr u8))
            length))))))

(cfg
  test
  (test
    fs-rooted-linux-component-validation
    (let
      [with-nul : String (linux-rooted-test-string-with-nul)]
      [max-component : String
        (linux-rooted-test-long-component fs-linux-rooted-component-max-bytes)]
      [too-long : String
        (linux-rooted-test-long-component
          (+ fs-linux-rooted-component-max-bytes 1))]
      (begin
        (test.assert-true
          (linux-rooted-component-valid? "leaf")
          "ordinary component is valid")
        (test.assert-true
          (linux-rooted-component-valid? "räksmörgås")
          "non-ASCII UTF-8 bytes are preserved")
        (test.assert-true
          (linux-rooted-component-valid? (& max-component))
          "255-byte component is valid")
        (test.assert-false
          (linux-rooted-component-valid? "")
          "empty component is invalid")
        (test.assert-false
          (linux-rooted-component-valid? ".")
          "dot component is invalid")
        (test.assert-false
          (linux-rooted-component-valid? "..")
          "dot-dot component is invalid")
        (test.assert-false
          (linux-rooted-component-valid? "a/b")
          "slash component is invalid")
        (test.assert-false
          (linux-rooted-component-valid? "a\\b")
          "backslash component is invalid")
        (test.assert-false
          (linux-rooted-component-valid? (& with-nul))
          "embedded NUL component is invalid")
        (test.assert-false
          (linux-rooted-component-valid? (& too-long))
          "256-byte component is invalid")))))

(cfg
  test
  (test
    fs-rooted-linux-result-taxonomy
    (begin
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 0))
        0
        "zero is success")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 4))
        9
        "EINTR is cancellation")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 2))
        2
        "ENOENT is not found")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 17))
        3
        "EEXIST is conflict")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 18))
        4
        "EXDEV is unsafe resolution")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 20))
        5
        "ENOTDIR is wrong kind")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 13))
        6
        "EACCES is permission denied")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 38))
        7
        "ENOSYS is unsupported")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 22))
        7
        "EINVAL for rejected open_how policy is unsupported")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 36))
        1
        "ENAMETOOLONG is invalid component")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 5))
        8
        "unclassified errno is generic I/O"))))

(cfg
  test
  (test
    fs-rooted-linux-open-how-abi
    (begin
      (test.assert-i64-eq
        (comptime (size-of (type FsLinuxOpenHow)))
        fs-linux-rooted-open-how-size
        "open_how size")
      (test.assert-i64-eq
        (comptime (offset-of (type FsLinuxOpenHow) flags))
        0
        "open_how.flags offset")
      (test.assert-i64-eq
        (comptime (offset-of (type FsLinuxOpenHow) mode))
        8
        "open_how.mode offset")
      (test.assert-i64-eq
        (comptime (offset-of (type FsLinuxOpenHow) resolve))
        16
        "open_how.resolve offset")
      (test.assert-i64-eq
        (cast fs-linux-rooted-resolve-policy : i64)
        15
        "complete openat2 resolve mask")
      (test.assert-i64-eq
        (cast fs-linux-rooted-resolve-no-xdev : i64)
        1
        "RESOLVE_NO_XDEV value")
      (test.assert-i64-eq
        (cast fs-linux-rooted-resolve-no-magiclinks : i64)
        2
        "RESOLVE_NO_MAGICLINKS value")
      (test.assert-i64-eq
        (cast fs-linux-rooted-resolve-no-symlinks : i64)
        4
        "RESOLVE_NO_SYMLINKS value")
      (test.assert-i64-eq
        (cast fs-linux-rooted-resolve-beneath : i64)
        8
        "RESOLVE_BENEATH value")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-openat2
        437
        "x86-64 openat2 syscall number")
      (test.assert-i64-eq
        (cast fs-linux-rooted-directory-open-flags : i64)
        720896
        "directory open flags")
      (test.assert-i64-eq
        (cast fs-linux-rooted-file-create-flags : i64)
        655553
        "exclusive file create flags"))))