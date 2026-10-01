;# stdlib/fs_rooted_linux.tl - Private rooted staging/publication Linux leaf.
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
;# Directory, exclusive-create file, and verified read capabilities are
;# cleanup-owning and move-only. Their only source-visible field is an opaque
;# state pointer; safe callers cannot copy or close the raw descriptor. Explicit
;# finish/close functions report close failures, while lexical cleanup closes
;# still-live descriptors on recoverable early exits.
;# `linux-rooted-read-file-into!` accepts an exclusive initialized byte view so
;# a read loop can retain one caller-owned buffer and receive only scalar
;# operation/count/EOF metadata without allocating per read.
;# `linux-rooted-read-file-rewind!` resets that same acquired file to offset
;# zero without allocation or reopening its path; it does not freeze contents.
;#
;# Source rewrites take an owned `FsLinuxRootedSourceSnapshot` from the read
;# capability they read through, revalidate a name against it through the
;# retained parent, and finish their private stage with the admitted source
;# permissions, verified by a fresh `fstat` before flush and close.
;#
;# Cooperating rewriters serialize through `FsLinuxRootedGuard`: a cleanup-owning,
;# move-only capability holding one exclusive `flock` on a permanent sidecar
;# below the retained parent. Acquisition makes exactly one nonblocking attempt;
;# retry, deadline and cancellation policy belong to the caller. The lock lives
;# on the guard's own open file description, so an explicit release, the
;# guard's cleanup, or process death releases it. No writer ever unlinks or
;# replaces the sidecar.
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
  (LinuxRootedClosed)
  (LinuxRootedCrossDevice)
  (LinuxRootedDirectoryNotEmpty)
  (LinuxRootedInvalidLength)
  (LinuxRootedLengthMismatch)
  (LinuxRootedReadFailure)
  (LinuxRootedIdentityChanged)
  (LinuxRootedSourceChanged)
  (LinuxRootedInvalidPermissions)
  (LinuxRootedModeMismatch)
  (LinuxRootedLockConflict))

;: Portable file-mode intent owned by the Linux leaf.
(defenum FsLinuxRootedFileMode
  (LinuxRootedRegularFile)
  (LinuxRootedExecutableFile))

;: File completion preserves an operation failure and an independent close
;: failure. This avoids hiding a failed write/flush when close also fails.
(defstruct FsLinuxRootedFinishResult
  (operation FsLinuxRootedResult)
  (close FsLinuxRootedResult))

;: Exact descriptor metadata returned without exposing the descriptor.
(defstruct FsLinuxRootedFileMetadata
  (result FsLinuxRootedResult)
  (length i64))

;: Owned identity and admission metadata of one regular source file, captured
;: by `fstat` of an acquired descriptor. `device` and `inode` are its physical
;: identity. `permissions` holds only the nine `rwx` bits: a source with
;: setuid, setgid or sticky set is `LinuxRootedUnsupported`, never admitted,
;: but keeps its linked file's identity so revalidation can compare it. The
;: other fields are meaningful only when `result` is `LinuxRootedOk`.
(defstruct FsLinuxRootedSourceSnapshot
  (result FsLinuxRootedResult)
  (device u64)
  (inode u64)
  (length i64)
  (links u64)
  (owner u32)
  (group u32)
  (permissions i64))

;: One bounded read from a retained regular-file descriptor. A short read is
;: successful and distinct from EOF; EOF is true only after a zero-byte read.
(defstruct FsLinuxRootedReadResult
  (operation FsLinuxRootedResult)
  (bytes byte_buf.ByteBuf)
  (eof bool)
  (short bool))

;: Scalar outcome from reading into caller-owned initialized mutable bytes.
;: `count` is the exact newly read prefix length and is zero on every failure.
(defstruct FsLinuxRootedReadIntoResult
  (operation FsLinuxRootedResult)
  (count i64)
  (eof bool)
  (short bool))

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

;: Private state of one guard. `fd` is live only while an acquired lock is
;: held; `device` and `inode` identify the sidecar that lock is on.
(defstruct FsLinuxRootedGuardState
  (fd i64)
  (result FsLinuxRootedResult)
  (device u64)
  (inode u64)
  (unlock FsLinuxRootedResult)
  (close FsLinuxRootedResult))

;: Outcome of releasing a guard: its one `LOCK_UN` attempt and its one close
;: attempt, reported independently.
(defstruct FsLinuxRootedGuardRelease
  (unlock FsLinuxRootedResult)
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

;: Operation status returned by a descriptor metadata query.
(define (linux-rooted-metadata-result [metadata : FsLinuxRootedFileMetadata]) : FsLinuxRootedResult
  metadata.result)

;: Exact `st_size` captured from the retained regular-file descriptor.
(define (linux-rooted-metadata-length [metadata : FsLinuxRootedFileMetadata]) : i64
  metadata.length)

;: Admission status of a source snapshot.
(define (linux-rooted-source-result
  [source : (& source FsLinuxRootedSourceSnapshot)]) : FsLinuxRootedResult
  (clone source.result))

;: Source `st_size` when the snapshot is admitted.
(define (linux-rooted-source-length
  [source : (& source FsLinuxRootedSourceSnapshot)]) : i64
  source.length)

;: Source `st_nlink`: a value above one means other names alias this inode.
(define (linux-rooted-source-links
  [source : (& source FsLinuxRootedSourceSnapshot)]) : u64
  source.links)

;: Admitted source permission bits, at most `0777`.
(define (linux-rooted-source-permissions
  [source : (& source FsLinuxRootedSourceSnapshot)]) : i64
  source.permissions)

;: True exactly when two admitted snapshots name the same physical file: equal
;: device and inode. Names, hard-link spellings and contents do not matter.
(define (linux-rooted-source-same-file?
  [left : (& left FsLinuxRootedSourceSnapshot)]
  [right : (& right FsLinuxRootedSourceSnapshot)]) : bool
  (and
    (linux-rooted-result-ok? (clone left.result))
    (linux-rooted-result-ok? (clone right.result))
    (= left.device right.device)
    (= left.inode right.inode)))

;: Operation status returned by one bounded read.
(define (linux-rooted-read-operation [read : (& read FsLinuxRootedReadResult)]) : FsLinuxRootedResult
  (clone read.operation))

;: Owned bytes returned by one bounded read.
(define (linux-rooted-read-bytes [read : FsLinuxRootedReadResult]) : byte_buf.ByteBuf
  read.bytes)

;: True only when the underlying read returned zero bytes for a positive
;: request. A zero-length request never claims EOF.
(define (linux-rooted-read-eof? [read : (& read FsLinuxRootedReadResult)]) : bool
  read.eof)

;: True when a successful positive read returned fewer bytes than requested.
(define (linux-rooted-read-short? [read : (& read FsLinuxRootedReadResult)]) : bool
  read.short)

;: Operation status returned by one caller-owned-buffer read.
(define (linux-rooted-read-into-operation
  [read : (& read FsLinuxRootedReadIntoResult)]) : FsLinuxRootedResult
  (clone read.operation))

;: True when a caller-owned-buffer read succeeded. This observes the scalar
;: operation tag in place so hot read loops need not clone the typed outcome.
(define (linux-rooted-read-into-ok?
  [read : (& read FsLinuxRootedReadIntoResult)]) : bool
  (match read.operation
    [(LinuxRootedOk) true]
    [_ false]))

;: Exact initialized prefix written by one successful caller-owned-buffer read.
;: Failures and zero-length requests return zero.
(define (linux-rooted-read-into-count
  [read : (& read FsLinuxRootedReadIntoResult)]) : i64
  read.count)

;: True only when a positive caller-owned-buffer request reached EOF.
(define (linux-rooted-read-into-eof?
  [read : (& read FsLinuxRootedReadIntoResult)]) : bool
  read.eof)

;: True when a successful positive caller-owned-buffer read made progress but
;: returned fewer bytes than requested.
(define (linux-rooted-read-into-short?
  [read : (& read FsLinuxRootedReadIntoResult)]) : bool
  read.short)

;: Linux x86-64 syscall and ABI constants. Keep the value tests next to the
;: representation tests below so changing a target constant is deliberate.
(define fs-linux-rooted-syscall-read : i64
  0)

;: Linux x86-64 `write` syscall number.
(define fs-linux-rooted-syscall-write : i64
  1)

;: Linux x86-64 `close` syscall number.
(define fs-linux-rooted-syscall-close : i64
  3)

;: Linux x86-64 `fstat` syscall number.
(define fs-linux-rooted-syscall-fstat : i64
  5)

;: Linux x86-64 `lseek` syscall number.
(define fs-linux-rooted-syscall-lseek : i64
  8)

;: Linux x86-64 `fsync` syscall number.
(define fs-linux-rooted-syscall-fsync : i64
  74)

;: Linux x86-64 `fchmod` syscall number.
(define fs-linux-rooted-syscall-fchmod : i64
  91)

;: Linux x86-64 `flock` syscall number.
(define fs-linux-rooted-syscall-flock : i64
  73)

;: Linux x86-64 `geteuid` syscall number.
(define fs-linux-rooted-syscall-geteuid : i64
  107)

;: Linux x86-64 `openat` syscall number.
(define fs-linux-rooted-syscall-openat : i64
  257)

;: Linux x86-64 `mkdirat` syscall number.
(define fs-linux-rooted-syscall-mkdirat : i64
  258)

;: Linux x86-64 `unlinkat` syscall number.
(define fs-linux-rooted-syscall-unlinkat : i64
  263)

;: Linux x86-64 `renameat` syscall number.
(define fs-linux-rooted-syscall-renameat : i64
  264)

;: Linux x86-64 `renameat2` syscall number.
(define fs-linux-rooted-syscall-renameat2 : i64
  316)

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

;: Largest byte count accepted by one bounded streaming read call.
(define fs-linux-rooted-read-max-bytes : i64
  1048576)

;: Linux `AT_REMOVEDIR` flag for exact empty-directory cleanup.
(define fs-linux-rooted-at-removedir : i64
  512)

;: Linux `RENAME_NOREPLACE` flag.
(define fs-linux-rooted-rename-noreplace : i64
  1)

;: Linux `flock` operations: exclusive, nonblocking, and unlock.
(define fs-linux-rooted-lock-exclusive : i64
  2)

;: Linux `LOCK_NB`.
(define fs-linux-rooted-lock-nonblocking : i64
  4)

;: Linux `LOCK_UN`.
(define fs-linux-rooted-lock-unlock : i64
  8)

;: Linux open flags used by this boundary.
(define fs-linux-rooted-o-wronly : u64
  (cast 1 : u64))

;: Linux `O_NONBLOCK` flag. This prevents a hostile FIFO substituted before
;: reopen from blocking the verifier before its descriptor kind is checked.
(define fs-linux-rooted-o-nonblock : u64
  (cast 2048 : u64))

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

;: Linux `O_PATH` flag: the descriptor names the file without opening it.
(define fs-linux-rooted-o-path : u64
  (cast 2097152 : u64))

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

;: Guard sidecar create-or-open flags: read-only (`flock` needs no write
;: access), created without `O_EXCL` because the sidecar is permanent and
;: shared, never following a final symlink, and nonblocking so a substituted
;: FIFO is opened and then rejected by kind instead of stalling. `flock` needs a
;: real open file description, so unlike revalidation this open cannot use
;: `O_PATH`: a device node at the name is opened before its kind is rejected.
(define fs-linux-rooted-guard-open-flags : u64
  (bit-or
    fs-linux-rooted-o-creat
    (bit-or
      fs-linux-rooted-o-nonblock
      (bit-or fs-linux-rooted-o-nofollow fs-linux-rooted-o-cloexec))))

;: Existing-file read flags. `O_RDONLY` is zero on Linux.
(define fs-linux-rooted-file-read-flags : u64
  (bit-or
    fs-linux-rooted-o-nonblock
    (bit-or fs-linux-rooted-o-nofollow fs-linux-rooted-o-cloexec)))

;: Revalidation flags, for sources and guard sidecars. `O_PATH` only names the
;: file for `fstat`, so a device, FIFO or socket at the name is never opened
;: and a mode that no longer grants read access is still observed. Without `O_NOFOLLOW`, the policy's
;: `RESOLVE_NO_SYMLINKS` rejects a symlink at the final name as it does
;: everywhere else.
(define fs-linux-rooted-revalidate-flags : u64
  (bit-or fs-linux-rooted-o-path fs-linux-rooted-o-cloexec))

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

;: x86-64 Linux `stat.st_size` byte offset.
(define fs-linux-rooted-stat-size-offset : i64
  48)

;: x86-64 Linux `stat.st_dev` byte offset.
(define fs-linux-rooted-stat-device-offset : i64
  0)

;: x86-64 Linux `stat.st_ino` byte offset.
(define fs-linux-rooted-stat-inode-offset : i64
  8)

;: x86-64 Linux `stat.st_nlink` byte offset.
(define fs-linux-rooted-stat-links-offset : i64
  16)

;: x86-64 Linux `stat.st_uid` byte offset.
(define fs-linux-rooted-stat-owner-offset : i64
  28)

;: x86-64 Linux `stat.st_gid` byte offset.
(define fs-linux-rooted-stat-group-offset : i64
  32)

;: The nine `rwx` permission bits a source rewrite preserves (`0777`).
(define fs-linux-rooted-permission-mask : i64
  511)

;: setuid, setgid and sticky (`07000`). No admitted source carries them.
(define fs-linux-rooted-special-mode-mask : i64
  3584)

;: Every mode bit below the file kind (`07777`).
(define fs-linux-rooted-mode-bits-mask : i64
  4095)

;: Group and other write bits (`022`). A guard sidecar must carry neither.
(define fs-linux-rooted-shared-write-mask : i64
  18)

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

;: Fault-injection ID for reopening an existing child with `openat2`.
(define fs-linux-rooted-syscall-kind-reopen : i64
  9)

;: Fault-injection ID for `read`.
(define fs-linux-rooted-syscall-kind-read : i64
  10)

;: Fault-injection ID for replace-existing `renameat`.
(define fs-linux-rooted-syscall-kind-renameat : i64
  11)

;: Fault-injection ID for no-replace `renameat2`.
(define fs-linux-rooted-syscall-kind-renameat2 : i64
  12)

;: Fault-injection ID for exact file/symlink `unlinkat`.
(define fs-linux-rooted-syscall-kind-unlinkat : i64
  13)

;: Fault-injection ID for empty-directory `unlinkat(AT_REMOVEDIR)`.
(define fs-linux-rooted-syscall-kind-rmdirat : i64
  14)

;: Fault-injection ID for parent-directory `fsync`.
(define fs-linux-rooted-syscall-kind-directory-fsync : i64
  15)

;: Fault-injection ID for reopening an existing child directory with
;: `openat2`. Keep this distinct from existing regular-file reopen so focused
;: failures cannot accidentally perturb the other acquisition path.
(define fs-linux-rooted-syscall-kind-reopen-directory : i64
  16)

;: Fault-injection ID for retained-file rewind via `lseek`.
(define fs-linux-rooted-syscall-kind-lseek : i64
  17)

;: Fault-injection ID for the guard sidecar's create-or-open `openat2`.
(define fs-linux-rooted-syscall-kind-guard-open : i64
  18)

;: Fault-injection ID for the guard's one `flock(LOCK_EX | LOCK_NB)`.
(define fs-linux-rooted-syscall-kind-flock : i64
  19)

;: Fault-injection ID for the guard release's one `flock(LOCK_UN)`.
(define fs-linux-rooted-syscall-kind-unlock : i64
  20)

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
  (define fs-linux-rooted-test-reopen-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-read-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-renameat-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-renameat2-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-unlinkat-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-rmdirat-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-directory-fsync-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-reopen-directory-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-lseek-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-guard-open-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-flock-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-unlock-calls : i64
    0))
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-read-max : i64
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
(cfg
  fs-rooted-linux-test-hooks
  (define fs-linux-rooted-test-mode-drift-enabled : bool
    false))

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
      (set! fs-linux-rooted-test-reopen-calls 0)
      (set! fs-linux-rooted-test-read-calls 0)
      (set! fs-linux-rooted-test-renameat-calls 0)
      (set! fs-linux-rooted-test-renameat2-calls 0)
      (set! fs-linux-rooted-test-unlinkat-calls 0)
      (set! fs-linux-rooted-test-rmdirat-calls 0)
      (set! fs-linux-rooted-test-directory-fsync-calls 0)
      (set! fs-linux-rooted-test-reopen-directory-calls 0)
      (set! fs-linux-rooted-test-lseek-calls 0)
      (set! fs-linux-rooted-test-guard-open-calls 0)
      (set! fs-linux-rooted-test-flock-calls 0)
      (set! fs-linux-rooted-test-unlock-calls 0)
      (set! fs-linux-rooted-test-read-max 0)
      (set! fs-linux-rooted-test-mkdir-race-enabled false)
      (set! fs-linux-rooted-test-mkdir-race-ok false)
      (set! fs-linux-rooted-test-after-mkdir-pause-ms 0)
      (set! fs-linux-rooted-test-mode-drift-enabled false))))

;: Inject `errno-code` (zero means a zero-progress return) for one numbered
;: syscall attempt of `kind`. A negative code injects a positive raw result,
;: including defensive unexpected-offset coverage for rewind.
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

;: Bound each real read call to force deterministic short-read coverage.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-set-read-max! [count : i64]) : unit
    (set! fs-linux-rooted-test-read-max count)))

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

;: Make the next source-permission finish see its stage mode drift: right
;: after its checked `fchmod`, an uncounted `fchmod` sets the stage to `0600`.
(cfg
  fs-rooted-linux-test-hooks
  (define (linux-rooted-test-enable-mode-drift!) : unit
    (set! fs-linux-rooted-test-mode-drift-enabled true)))

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
      [(= kind fs-linux-rooted-syscall-kind-reopen)
        fs-linux-rooted-test-reopen-calls]
      [(= kind fs-linux-rooted-syscall-kind-read)
        fs-linux-rooted-test-read-calls]
      [(= kind fs-linux-rooted-syscall-kind-renameat)
        fs-linux-rooted-test-renameat-calls]
      [(= kind fs-linux-rooted-syscall-kind-renameat2)
        fs-linux-rooted-test-renameat2-calls]
      [(= kind fs-linux-rooted-syscall-kind-unlinkat)
        fs-linux-rooted-test-unlinkat-calls]
      [(= kind fs-linux-rooted-syscall-kind-rmdirat)
        fs-linux-rooted-test-rmdirat-calls]
      [(= kind fs-linux-rooted-syscall-kind-directory-fsync)
        fs-linux-rooted-test-directory-fsync-calls]
      [(= kind fs-linux-rooted-syscall-kind-reopen-directory)
        fs-linux-rooted-test-reopen-directory-calls]
      [(= kind fs-linux-rooted-syscall-kind-lseek)
        fs-linux-rooted-test-lseek-calls]
      [(= kind fs-linux-rooted-syscall-kind-guard-open)
        fs-linux-rooted-test-guard-open-calls]
      [(= kind fs-linux-rooted-syscall-kind-flock)
        fs-linux-rooted-test-flock-calls]
      [(= kind fs-linux-rooted-syscall-kind-unlock)
        fs-linux-rooted-test-unlock-calls]
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
          [(= kind fs-linux-rooted-syscall-kind-reopen)
            (begin
              (set!
                fs-linux-rooted-test-reopen-calls
                (+ fs-linux-rooted-test-reopen-calls 1))
              fs-linux-rooted-test-reopen-calls)]
          [(= kind fs-linux-rooted-syscall-kind-read)
            (begin
              (set!
                fs-linux-rooted-test-read-calls
                (+ fs-linux-rooted-test-read-calls 1))
              fs-linux-rooted-test-read-calls)]
          [(= kind fs-linux-rooted-syscall-kind-renameat)
            (begin
              (set!
                fs-linux-rooted-test-renameat-calls
                (+ fs-linux-rooted-test-renameat-calls 1))
              fs-linux-rooted-test-renameat-calls)]
          [(= kind fs-linux-rooted-syscall-kind-renameat2)
            (begin
              (set!
                fs-linux-rooted-test-renameat2-calls
                (+ fs-linux-rooted-test-renameat2-calls 1))
              fs-linux-rooted-test-renameat2-calls)]
          [(= kind fs-linux-rooted-syscall-kind-unlinkat)
            (begin
              (set!
                fs-linux-rooted-test-unlinkat-calls
                (+ fs-linux-rooted-test-unlinkat-calls 1))
              fs-linux-rooted-test-unlinkat-calls)]
          [(= kind fs-linux-rooted-syscall-kind-rmdirat)
            (begin
              (set!
                fs-linux-rooted-test-rmdirat-calls
                (+ fs-linux-rooted-test-rmdirat-calls 1))
              fs-linux-rooted-test-rmdirat-calls)]
          [(= kind fs-linux-rooted-syscall-kind-directory-fsync)
            (begin
              (set!
                fs-linux-rooted-test-directory-fsync-calls
                (+ fs-linux-rooted-test-directory-fsync-calls 1))
              fs-linux-rooted-test-directory-fsync-calls)]
          [(= kind fs-linux-rooted-syscall-kind-reopen-directory)
            (begin
              (set!
                fs-linux-rooted-test-reopen-directory-calls
                (+ fs-linux-rooted-test-reopen-directory-calls 1))
              fs-linux-rooted-test-reopen-directory-calls)]
          [(= kind fs-linux-rooted-syscall-kind-lseek)
            (begin
              (set!
                fs-linux-rooted-test-lseek-calls
                (+ fs-linux-rooted-test-lseek-calls 1))
              fs-linux-rooted-test-lseek-calls)]
          [(= kind fs-linux-rooted-syscall-kind-guard-open)
            (begin
              (set!
                fs-linux-rooted-test-guard-open-calls
                (+ fs-linux-rooted-test-guard-open-calls 1))
              fs-linux-rooted-test-guard-open-calls)]
          [(= kind fs-linux-rooted-syscall-kind-flock)
            (begin
              (set!
                fs-linux-rooted-test-flock-calls
                (+ fs-linux-rooted-test-flock-calls 1))
              fs-linux-rooted-test-flock-calls)]
          [(= kind fs-linux-rooted-syscall-kind-unlock)
            (begin
              (set!
                fs-linux-rooted-test-unlock-calls
                (+ fs-linux-rooted-test-unlock-calls 1))
              fs-linux-rooted-test-unlock-calls)]
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

;: Erased production bridge to the short-read limit.
(define (linux-rooted-read-request-count [count : i64]) : i64
  (cfg
    fs-rooted-linux-test-hooks
    (if (and
      (> fs-linux-rooted-test-read-max 0)
      (> count fs-linux-rooted-test-read-max))
      fs-linux-rooted-test-read-max
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

;: Erased production bridge to the deterministic mode-drift hook.
(define (linux-rooted-after-source-mode [_fd : i64]) : unit
  (cfg
    fs-rooted-linux-test-hooks
    (if fs-linux-rooted-test-mode-drift-enabled
      (begin
        (set! fs-linux-rooted-test-mode-drift-enabled false)
        (cfg
          windows
          unit
          (begin
            (unsafe
              (syscall
                fs-linux-rooted-syscall-fchmod
                _fd
                (cast fs-linux-rooted-private-file-mode : i64)))
            unit)))
      unit)
    unit))

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

;: Raw Linux `openat2` dedicated to existing-file reopen fault coverage.
(unsafe
  (define (linux-rooted-raw-reopenat2
    [dirfd : i64]
    [path : (Ptr u8)]
    [how : FsLinuxOpenHow]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-reopen)]
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

;: Raw Linux `openat2` dedicated to existing-directory reopen fault coverage.
(unsafe
  (define (linux-rooted-raw-reopen-directory-at2
    [dirfd : i64]
    [path : (Ptr u8)]
    [how : FsLinuxOpenHow]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result
          fs-linux-rooted-syscall-kind-reopen-directory)]
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

;: Raw Linux `lseek(fd, 0, SEEK_SET)` with the rooted boundary's errno and
;: fault-injection contract. The legacy I/O wrapper normalizes away errno.
(unsafe
  (define (linux-rooted-raw-rewind [fd : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-lseek)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall fs-linux-rooted-syscall-lseek fd 0 0)))))))

;: Raw Linux `openat2` dedicated to guard-sidecar create-or-open faults.
(unsafe
  (define (linux-rooted-raw-guard-openat2
    [dirfd : i64]
    [path : (Ptr u8)]
    [how : FsLinuxOpenHow]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-guard-open)]
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

;: Raw Linux `flock(fd, LOCK_EX | LOCK_NB)`.
(unsafe
  (define (linux-rooted-raw-lock [fd : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-flock)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-flock
              fd
              (bit-or
                fs-linux-rooted-lock-exclusive
                fs-linux-rooted-lock-nonblocking))))))))

;: Raw Linux `flock(fd, LOCK_UN)`.
(unsafe
  (define (linux-rooted-raw-unlock [fd : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-unlock)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-flock
              fd
              fs-linux-rooted-lock-unlock)))))))

;: The calling process's effective user ID. `geteuid` cannot fail.
(define (linux-rooted-effective-user) : u32
  (cfg
    windows
    (cast 0 : u32)
    (cast
      (unsafe
        (syscall fs-linux-rooted-syscall-geteuid))
      : u32)))

;: Raw Linux `read`, optionally bounded by the focused short-read hook.
(unsafe
  (define (linux-rooted-raw-read [fd : i64] [data : (MutPtr u8)] [count : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-read)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-read
              fd
              (cast (ptr->int (ptr-cast data : (Ptr u8))) : i64)
              (linux-rooted-read-request-count count))))))))

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

;: Raw Linux `fsync` dedicated to parent-directory durability fault coverage.
(unsafe
  (define (linux-rooted-raw-directory-fsync [fd : i64]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result
          fs-linux-rooted-syscall-kind-directory-fsync)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall fs-linux-rooted-syscall-fsync fd)))))))

;: Raw direct `renameat` for atomic replace-existing publication.
(unsafe
  (define (linux-rooted-raw-renameat
    [source-dirfd : i64]
    [source : (Ptr u8)]
    [destination-dirfd : i64]
    [destination : (Ptr u8)]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-renameat)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-renameat
              source-dirfd
              (linux-rooted-ptr-arg source)
              destination-dirfd
              (linux-rooted-ptr-arg destination))))))))

;: Raw direct `renameat2(RENAME_NOREPLACE)` with no compatibility fallback.
(unsafe
  (define (linux-rooted-raw-renameat2-noreplace
    [source-dirfd : i64]
    [source : (Ptr u8)]
    [destination-dirfd : i64]
    [destination : (Ptr u8)]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-renameat2)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-renameat2
              source-dirfd
              (linux-rooted-ptr-arg source)
              destination-dirfd
              (linux-rooted-ptr-arg destination)
              fs-linux-rooted-rename-noreplace)))))))

;: Raw direct `unlinkat` for one file or symlink directory entry.
(unsafe
  (define (linux-rooted-raw-unlinkat [dirfd : i64] [path : (Ptr u8)]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-unlinkat)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-unlinkat
              dirfd
              (linux-rooted-ptr-arg path)
              0)))))))

;: Raw direct `unlinkat(AT_REMOVEDIR)` for one exact empty directory.
(unsafe
  (define (linux-rooted-raw-rmdirat [dirfd : i64] [path : (Ptr u8)]) : i64
    (let
      [injected : i64
        (linux-rooted-injected-result fs-linux-rooted-syscall-kind-rmdirat)]
      (if (not (= injected fs-linux-rooted-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall
              fs-linux-rooted-syscall-unlinkat
              dirfd
              (linux-rooted-ptr-arg path)
              fs-linux-rooted-at-removedir)))))))

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

;: Rename-specific normalization keeps a mount-crossing publication distinct
;: from openat2's resolution-policy EXDEV.
(define (linux-rooted-rename-result-from-raw [raw : i64]) : FsLinuxRootedResult
  (cond
    [(= raw -18) LinuxRootedCrossDevice]
    [(= raw -39) LinuxRootedDirectoryNotEmpty]
    [else (linux-rooted-result-from-raw raw)]))

;: Guard-acquire open normalization: the sidecar is opened for I/O so it can
;: be locked, and opening a socket reports ENXIO, which for a sidecar name
;: means the name is not a regular file.
(define (linux-rooted-guard-open-result-from-raw [raw : i64]) : FsLinuxRootedResult
  (if (= raw -6)
    LinuxRootedWrongKind
    (linux-rooted-result-from-raw raw)))

;: Cleanup-specific normalization treats both permitted nonempty-directory
;: errno values as one stable result while preserving ordinary EEXIST elsewhere.
(define (linux-rooted-cleanup-result-from-raw [raw : i64]) : FsLinuxRootedResult
  (if (or (= raw -17) (= raw -39))
    LinuxRootedDirectoryNotEmpty
    (linux-rooted-result-from-raw raw)))

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

;: Read a u64 field from an x86-64 `struct stat` buffer.
(unsafe
  (define (linux-rooted-stat-u64 [statbuf : (MutPtr u8)] [offset : i64]) : u64
    (unsafe
      (ptr-read (ptr-cast (ptr-offset statbuf offset) : (Ptr u64))))))

;: Read an i64 field from an x86-64 `struct stat` buffer.
(unsafe
  (define (linux-rooted-stat-i64 [statbuf : (MutPtr u8)] [offset : i64]) : i64
    (unsafe
      (ptr-read (ptr-cast (ptr-offset statbuf offset) : (Ptr i64))))))

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

;: Flush one retained parent directory, retrying EINTR while cancellation is
;: clear. A separate raw wrapper keeps directory-fsync injection independent.
(unsafe
  (define (linux-rooted-flush-directory-fd
    [fd : i64]
    [cancel-check : (-> bool)]) : FsLinuxRootedResult
    (let
      [raw : i64 -4]
      (begin
        (while (and (= raw -4) (not (cancel-check)))
          (set!
            raw
            (unsafe
              (linux-rooted-raw-directory-fsync fd))))
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

;: Cleanup-owning, move-only rooted regular-file read capability.
(defstruct FsLinuxRootedReadFile
  (:cleanup cleanup-linux-rooted-read-file)
  (state
    (MutPtr FsLinuxRootedHandleState)
    (:cleanup linux-rooted-state-cleanup)))

;: Allocate private active-arena state for one guard.
(unsafe
  (define (linux-rooted-guard-state-new [value : FsLinuxRootedGuardState]) : (MutPtr
      FsLinuxRootedGuardState)
    (let
      [states : (__tl_dyn-array FsLinuxRootedGuardState)
        (__tl_make-array FsLinuxRootedGuardState 1)]
      [state : (MutPtr FsLinuxRootedGuardState)
        (unsafe
          (__tl_array-data states))]
      (begin
        (unsafe
          (ptr-write! state value))
        state))))

;: Snapshot guard state, failing closed for a null pointer.
(unsafe
  (define (linux-rooted-guard-state-read
    [state : (MutPtr FsLinuxRootedGuardState)]) : FsLinuxRootedGuardState
    (if (ptr-null? state)
      (FsLinuxRootedGuardState
        -1
        LinuxRootedClosed
        (cast 0 : u64)
        (cast 0 : u64)
        LinuxRootedClosed
        LinuxRootedClosed)
      (unsafe
        (ptr-read state)))))

;: Store guard state after checking its opaque pointer.
(unsafe
  (define (linux-rooted-guard-state-write!
    [state : (MutPtr FsLinuxRootedGuardState)]
    [value : FsLinuxRootedGuardState]) : unit
    (if (ptr-null? state)
      unit
      (unsafe
        (ptr-write! state value)))))

;: Cleanup-field adapter: one close of a still-held descriptor. Closing the
;: guard's only open file description releases its lock; the outcome is
;: observable only through `linux-rooted-guard-release!`.
(define (linux-rooted-guard-state-cleanup
  [state : (MutPtr FsLinuxRootedGuardState)]) : unit
  (unsafe
    (let
      [held : FsLinuxRootedGuardState (linux-rooted-guard-state-read state)]
      (if (< held.fd 0)
        unit
        (begin
          (linux-rooted-guard-state-write!
            state
            (FsLinuxRootedGuardState
              -1
              held.result
              held.device
              held.inode
              held.unlock
              LinuxRootedClosed))
          (let
            [close-result : FsLinuxRootedResult
              (linux-rooted-close-fd-once held.fd)]
            (linux-rooted-guard-state-write!
              state
              (FsLinuxRootedGuardState
                -1
                held.result
                held.device
                held.inode
                held.unlock
                close-result))))))))

;: Cleanup-owning, move-only exclusive lock on one rooted sidecar.
(defstruct FsLinuxRootedGuard
  (:cleanup cleanup-linux-rooted-guard)
  (state
    (MutPtr FsLinuxRootedGuardState)
    (:cleanup linux-rooted-guard-state-cleanup)))

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

;: Return the stable construction result for a rooted read capability.
(define (linux-rooted-read-file-result [file : (& file FsLinuxRootedReadFile)]) : FsLinuxRootedResult
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

;: Return the recorded close outcome for a rooted read capability.
(define (linux-rooted-read-file-close-result
  [file : (& file FsLinuxRootedReadFile)]) : FsLinuxRootedResult
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

;: True when a rooted read capability owns a live descriptor.
(define (linux-rooted-read-file-open? [file : (& file FsLinuxRootedReadFile)]) : bool
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

;: Build a failed read capability with the same ownership shape as success.
(define (linux-rooted-failed-read-file [result : FsLinuxRootedResult]) : FsLinuxRootedReadFile
  (FsLinuxRootedReadFile
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

;: Preserve failed read construction and its independent close result.
(unsafe
  (define (linux-rooted-failed-read-file-after-close
    [result : FsLinuxRootedResult]
    [fd : i64]) : FsLinuxRootedReadFile
    (FsLinuxRootedReadFile
      (unsafe
        (linux-rooted-state-new-after-close
          result
          (unsafe
            (linux-rooted-discard-fd fd)))))))

;: Acquire and verify one child-directory descriptor through the complete
;: descendant policy. Creation uses the ordinary openat2 fault seam and applies
;: its final mode after verification. Existing-directory reopen uses its own
;: fault seam and deliberately performs no mutation after acquisition.
(unsafe
  (define (linux-rooted-acquire-directory
    [parent-fd : i64]
    [component : (Ptr u8)]
    [existing : bool]
    [cancel-check : (-> bool)]) : FsLinuxRootedDirectory
    (let
      [how : FsLinuxOpenHow
        (FsLinuxOpenHow
          fs-linux-rooted-directory-open-flags
          (cast 0 : u64)
          fs-linux-rooted-resolve-policy)]
      [fd : i64
        (if existing
          (unsafe
            (linux-rooted-raw-reopen-directory-at2 parent-fd component how))
          (unsafe
            (linux-rooted-raw-openat2 parent-fd component how)))]
      (if (< fd 0)
        (linux-rooted-failed-directory (linux-rooted-result-from-raw fd))
        (let
          [kind-result : FsLinuxRootedResult
            (unsafe
              (linux-rooted-verify-kind
                fd
                fs-linux-rooted-stat-directory-mode
                cancel-check))]
          (if (not (linux-rooted-result-ok? kind-result))
            (unsafe
              (linux-rooted-failed-directory-after-close kind-result fd))
            (if existing
              (FsLinuxRootedDirectory
                (unsafe
                  (linux-rooted-state-new fd LinuxRootedOk)))
              (let
                [mode-result : FsLinuxRootedResult
                  (unsafe
                    (linux-rooted-apply-mode
                      fd
                      fs-linux-rooted-directory-mode
                      cancel-check))]
                (if (linux-rooted-result-ok? mode-result)
                  (FsLinuxRootedDirectory
                    (unsafe
                      (linux-rooted-state-new fd LinuxRootedOk)))
                  (unsafe
                    (linux-rooted-failed-directory-after-close mode-result fd)))))))))))

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
                  (linux-rooted-acquire-directory
                    parent-state.fd
                    component-ptr
                    false
                    cancel-check)))))]))))

;: Reopen one existing child directory without mutating it. Acquisition is one
;: openat2 call relative to the retained parent and uses the exact same flags,
;: resolution policy, kind verification, and close discipline as creation.
(define (linux-rooted-reopen-directory
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
            (linux-rooted-acquire-directory
              parent-state.fd
              (io.array-const-ptr component-bytes)
              true
              cancel-check))]))))

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

;: Reopen one existing child for bounded reads. Acquisition is relative to the
;: retained parent and uses the complete openat2 resolution policy. O_NONBLOCK
;: ensures that a substituted FIFO cannot stall before fstat rejects its kind.
(define (linux-rooted-reopen-file
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedReadFile
  (unsafe
    (let
      [parent-state : FsLinuxRootedHandleState
        (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          (linux-rooted-failed-read-file LinuxRootedInvalidComponent)]
        [(or
            (< parent-state.fd 0)
            (not (linux-rooted-result-ok? parent-state.result)))
          (linux-rooted-failed-read-file LinuxRootedClosed)]
        [(cancel-check) (linux-rooted-failed-read-file LinuxRootedCancelled)]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [how : FsLinuxOpenHow
              (FsLinuxOpenHow
                fs-linux-rooted-file-read-flags
                (cast 0 : u64)
                fs-linux-rooted-resolve-policy)]
            [fd : i64
              (linux-rooted-raw-reopenat2
                parent-state.fd
                (io.array-const-ptr component-bytes)
                how)]
            (if (< fd 0)
              (linux-rooted-failed-read-file (linux-rooted-result-from-raw fd))
              (let
                [kind-result : FsLinuxRootedResult
                  (linux-rooted-verify-kind
                    fd
                    fs-linux-rooted-stat-regular-mode
                    cancel-check)]
                (if (linux-rooted-result-ok? kind-result)
                  (FsLinuxRootedReadFile
                    (linux-rooted-state-new fd LinuxRootedOk))
                  (linux-rooted-failed-read-file-after-close kind-result fd)))))]))))

;: Reset a live acquired regular file to absolute offset zero with one checked
;: lseek. Liveness and cancellation rejection perform no host access and leave
;: the cursor unchanged. Host errors use the existing rooted taxonomy; a
;: nonzero returned offset is IoFailure. After a host failure this API promises
;: no cursor position; a successful rewind is required before restarting reads.
;: The descriptor stays owned and open on failure. This operation allocates no
;: storage, performs no pathname lookup/read, and does not verify content
;: stability or strengthen the original acquisition guarantee.
(define (linux-rooted-read-file-rewind!
  [file : (&mut file FsLinuxRootedReadFile)]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read file.state)]
      (cond
        [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
          LinuxRootedClosed]
        [(cancel-check) LinuxRootedCancelled]
        [else
          (let
            [raw : i64 (linux-rooted-raw-rewind state.fd)]
            (cond
              [(= raw 0) LinuxRootedOk]
              [(< raw 0) (linux-rooted-result-from-raw raw)]
              [else LinuxRootedIoFailure]))]))))

;: Capture exact length metadata from the retained descriptor and recheck that
;: it still names a regular file.
(define (linux-rooted-read-file-metadata
  [file : (& file FsLinuxRootedReadFile)]
  [cancel-check : (-> bool)]) : FsLinuxRootedFileMetadata
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read file.state)]
      (cond
        [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
          (FsLinuxRootedFileMetadata LinuxRootedClosed -1)]
        [(cancel-check) (FsLinuxRootedFileMetadata LinuxRootedCancelled -1)]
        [else
          (let
            [stat-bytes : (__tl_dyn-array u8)
              (__tl_make-array u8 fs-linux-rooted-stat-buffer-size)]
            [statbuf : (MutPtr u8) (__tl_array-data stat-bytes)]
            [raw : i64 (linux-rooted-raw-fstat state.fd statbuf)]
            (if (< raw 0)
              (FsLinuxRootedFileMetadata (linux-rooted-result-from-raw raw) -1)
              (let
                [mode : i64
                  (bit-and
                    (cast
                      (linux-rooted-stat-u32
                        statbuf
                        fs-linux-rooted-stat-mode-offset)
                      : i64)
                    fs-linux-rooted-stat-kind-mask)]
                [length : i64
                  (linux-rooted-stat-i64
                    statbuf
                    fs-linux-rooted-stat-size-offset)]
                (cond
                  [(not (= mode fs-linux-rooted-stat-regular-mode))
                    (FsLinuxRootedFileMetadata LinuxRootedWrongKind -1)]
                  [(< length 0)
                    (FsLinuxRootedFileMetadata LinuxRootedIoFailure -1)]
                  [else (FsLinuxRootedFileMetadata LinuxRootedOk length)]))))]))))

;: Check one caller-promised exact length against descriptor metadata.
(define (linux-rooted-read-file-check-length
  [file : (& file FsLinuxRootedReadFile)]
  [expected-length : i64]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (if (< expected-length 0)
    LinuxRootedInvalidLength
    (let
      [metadata : FsLinuxRootedFileMetadata
        (linux-rooted-read-file-metadata file cancel-check)]
      (if (not (linux-rooted-result-ok? metadata.result))
        metadata.result
        (if (= metadata.length expected-length)
          LinuxRootedOk
          LinuxRootedLengthMismatch)))))

;: A rejected snapshot. Its identity fields are zero and never compared.
(define (linux-rooted-failed-source-snapshot [result : FsLinuxRootedResult]) : FsLinuxRootedSourceSnapshot
  (FsLinuxRootedSourceSnapshot
    result
    (cast 0 : u64)
    (cast 0 : u64)
    -1
    (cast 0 : u64)
    (cast 0 : u32)
    (cast 0 : u32)
    0))

;: Admit or reject one filled x86-64 `struct stat` as a rewrite source. Only a
;: linked regular file with a nonnegative size and no setuid, setgid or sticky
;: bit is admitted; every other shape gets a stable result. A linked regular
;: file carrying a special bit keeps all its fields under `Unsupported`, so a
;: revalidation can tell another file from a changed one.
(unsafe
  (define (linux-rooted-source-snapshot-from-stat [statbuf : (MutPtr u8)]) : FsLinuxRootedSourceSnapshot
    (let
      [mode : i64
        (cast
          (unsafe
            (linux-rooted-stat-u32 statbuf fs-linux-rooted-stat-mode-offset))
          : i64)]
      [length : i64
        (unsafe
          (linux-rooted-stat-i64 statbuf fs-linux-rooted-stat-size-offset))]
      [links : u64
        (unsafe
          (linux-rooted-stat-u64 statbuf fs-linux-rooted-stat-links-offset))]
      (cond
        [(not
            (=
              (bit-and mode fs-linux-rooted-stat-kind-mask)
              fs-linux-rooted-stat-regular-mode))
          (linux-rooted-failed-source-snapshot LinuxRootedWrongKind)]
        [(< length 0)
          (linux-rooted-failed-source-snapshot LinuxRootedIoFailure)]
        [(= links (cast 0 : u64))
          (linux-rooted-failed-source-snapshot LinuxRootedNotFound)]
        [else
          (FsLinuxRootedSourceSnapshot
            (if (= (bit-and mode fs-linux-rooted-special-mode-mask) 0)
              LinuxRootedOk
              LinuxRootedUnsupported)
            (unsafe
              (linux-rooted-stat-u64 statbuf fs-linux-rooted-stat-device-offset))
            (unsafe
              (linux-rooted-stat-u64 statbuf fs-linux-rooted-stat-inode-offset))
            length
            links
            (unsafe
              (linux-rooted-stat-u32 statbuf fs-linux-rooted-stat-owner-offset))
            (unsafe
              (linux-rooted-stat-u32 statbuf fs-linux-rooted-stat-group-offset))
            (bit-and mode fs-linux-rooted-permission-mask))]))))

;: Snapshot one acquired descriptor with a single `fstat`.
(unsafe
  (define (linux-rooted-fd-source-snapshot [fd : i64]) : FsLinuxRootedSourceSnapshot
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
        (linux-rooted-failed-source-snapshot (linux-rooted-result-from-raw raw))
        (unsafe
          (linux-rooted-source-snapshot-from-stat statbuf))))))

;: Snapshot the source behind a live read capability. Taking it from the same
;: descriptor the caller reads through ties the identity to those bytes.
(define (linux-rooted-read-file-source-snapshot
  [file : (& file FsLinuxRootedReadFile)]
  [cancel-check : (-> bool)]) : FsLinuxRootedSourceSnapshot
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read file.state)]
      (cond
        [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
          (linux-rooted-failed-source-snapshot LinuxRootedClosed)]
        [(cancel-check)
          (linux-rooted-failed-source-snapshot LinuxRootedCancelled)]
        [else (linux-rooted-fd-source-snapshot state.fd)]))))

;: Compare a fresh snapshot of a name with the admitted one. A different
;: physical file is `IdentityChanged`, whether or not it carries a special bit;
;: the same file with any other admitted field changed, or newly carrying a
;: special bit, is `SourceChanged`; a fresh snapshot that is no longer a linked
;: regular file, or whose `fstat` failed, keeps its own result.
(define (linux-rooted-source-compare
  [admitted : (& admitted FsLinuxRootedSourceSnapshot)]
  [current : (& current FsLinuxRootedSourceSnapshot)]) : FsLinuxRootedResult
  (match (clone current.result)
    [(LinuxRootedOk)
      (cond
        [(not
            (and
              (= admitted.device current.device)
              (= admitted.inode current.inode)))
          LinuxRootedIdentityChanged]
        [(not
            (and
              (= admitted.length current.length)
              (= admitted.links current.links)
              (= admitted.owner current.owner)
              (= admitted.group current.group)
              (= admitted.permissions current.permissions)))
          LinuxRootedSourceChanged]
        [else LinuxRootedOk])]
    [(LinuxRootedUnsupported)
      (cond
        ;; A failed snapshot has no identity; only an admitted shape is linked.
        [(= current.links (cast 0 : u64)) LinuxRootedUnsupported]
        [(not
            (and
              (= admitted.device current.device)
              (= admitted.inode current.inode)))
          LinuxRootedIdentityChanged]
        [else LinuxRootedSourceChanged])]
    [_ (clone current.result)]))

;: Revalidate `component` below the retained `parent` against an admitted
;: snapshot: one `O_PATH` `openat2` with the complete descendant policy, one
;: `fstat`, and one close. Nothing is resolved through a process-relative path
;: and nothing at the name is opened for I/O. A symlink or mount crossing is
;: `UnsafeResolution`, a missing name `NotFound`, a directory, FIFO, socket or
;: device `WrongKind`. The close outcome is reported independently of the
;: comparison.
(define (linux-rooted-source-revalidate
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [admitted : (& admitted FsLinuxRootedSourceSnapshot)]
  [cancel-check : (-> bool)]) : FsLinuxRootedFinishResult
  (unsafe
    (let
      [parent-state : FsLinuxRootedHandleState
        (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          (FsLinuxRootedFinishResult
            LinuxRootedInvalidComponent
            LinuxRootedClosed)]
        [(or
            (< parent-state.fd 0)
            (not (linux-rooted-result-ok? parent-state.result)))
          (FsLinuxRootedFinishResult LinuxRootedClosed LinuxRootedClosed)]
        [(not (linux-rooted-result-ok? (clone admitted.result)))
          (FsLinuxRootedFinishResult (clone admitted.result) LinuxRootedClosed)]
        [(cancel-check)
          (FsLinuxRootedFinishResult LinuxRootedCancelled LinuxRootedClosed)]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [how : FsLinuxOpenHow
              (FsLinuxOpenHow
                fs-linux-rooted-revalidate-flags
                (cast 0 : u64)
                fs-linux-rooted-resolve-policy)]
            [fd : i64
              (linux-rooted-raw-reopenat2
                parent-state.fd
                (io.array-const-ptr component-bytes)
                how)]
            (if (< fd 0)
              (FsLinuxRootedFinishResult
                (linux-rooted-result-from-raw fd)
                LinuxRootedClosed)
              (let
                [current : FsLinuxRootedSourceSnapshot
                  (linux-rooted-fd-source-snapshot fd)]
                [operation : FsLinuxRootedResult
                  (linux-rooted-source-compare admitted (& current))]
                (FsLinuxRootedFinishResult
                  operation
                  (linux-rooted-close-fd-once fd)))))]))))

;: One nonblocking exclusive lock attempt. Another open file description
;: holding the lock is `LockConflict`; a kernel or filesystem without `flock`
;: support is `Unsupported`; an interrupted attempt is `Cancelled`.
(define (linux-rooted-lock-result-from-raw [raw : i64]) : FsLinuxRootedResult
  (cond
    [(= raw 0) LinuxRootedOk]
    [(= raw -11) LinuxRootedLockConflict]
    [(or (= raw -4) (= raw -125)) LinuxRootedCancelled]
    [(or (= raw -22) (= raw -37) (= raw -38) (= raw -95))
      LinuxRootedUnsupported]
    [else LinuxRootedIoFailure]))

;: One `LOCK_UN` attempt. It is never retried: the close that follows it
;: releases the lock in any case.
(define (linux-rooted-unlock-result-from-raw [raw : i64]) : FsLinuxRootedResult
  (cond
    [(= raw 0) LinuxRootedOk]
    [(or (= raw -4) (= raw -125)) LinuxRootedCancelled]
    [else LinuxRootedIoFailure]))

;: Sidecar policy, checked before locking: a linked regular file with exactly
;: one name, owned by the effective user, writable by neither group nor
;: others. Any other shape could let another user substitute or alias it, so
;: it is not trusted to serialize writers.
(define (linux-rooted-guard-sidecar-result
  [sidecar : (& sidecar FsLinuxRootedSourceSnapshot)]) : FsLinuxRootedResult
  (cond
    [(not (linux-rooted-result-ok? (clone sidecar.result)))
      (clone sidecar.result)]
    [(not (= sidecar.links (cast 1 : u64))) LinuxRootedUnsupported]
    [(not (= sidecar.owner (linux-rooted-effective-user)))
      LinuxRootedUnsupported]
    [(not (= (bit-and sidecar.permissions fs-linux-rooted-shared-write-mask) 0))
      LinuxRootedUnsupported]
    [else LinuxRootedOk]))

;: A guard that holds no descriptor and no lock.
(define (linux-rooted-failed-guard [result : FsLinuxRootedResult]) : FsLinuxRootedGuard
  (FsLinuxRootedGuard
    (unsafe
      (linux-rooted-guard-state-new
        (FsLinuxRootedGuardState
          -1
          result
          (cast 0 : u64)
          (cast 0 : u64)
          LinuxRootedClosed
          LinuxRootedClosed)))))

;: A failed guard after its acquired sidecar descriptor was closed once; the
;: close outcome stays observable beside `result`.
(unsafe
  (define (linux-rooted-failed-guard-after-close
    [result : FsLinuxRootedResult]
    [fd : i64]) : FsLinuxRootedGuard
    (FsLinuxRootedGuard
      (unsafe
        (linux-rooted-guard-state-new
          (FsLinuxRootedGuardState
            -1
            result
            (cast 0 : u64)
            (cast 0 : u64)
            LinuxRootedClosed
            (unsafe
              (linux-rooted-close-fd-once fd))))))))

;: Create or open the permanent sidecar `component` below the retained parent
;: and make exactly one nonblocking exclusive lock attempt on it. The open uses
;: the complete descendant policy; the sidecar must pass
;: `linux-rooted-guard-sidecar-result` before the lock is attempted, and
;: cancellation is checked before each host step. A successful lock commits and
;: is returned as a live guard. Every failure after the open closes its
;: descriptor once and reports that close beside the failure. Blocking,
;: retries and deadlines are the caller's policy.
(define (linux-rooted-guard-acquire
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedGuard
  (unsafe
    (let
      [parent-state : FsLinuxRootedHandleState
        (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          (linux-rooted-failed-guard LinuxRootedInvalidComponent)]
        [(or
            (< parent-state.fd 0)
            (not (linux-rooted-result-ok? parent-state.result)))
          (linux-rooted-failed-guard LinuxRootedClosed)]
        [(cancel-check) (linux-rooted-failed-guard LinuxRootedCancelled)]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [how : FsLinuxOpenHow
              (FsLinuxOpenHow
                fs-linux-rooted-guard-open-flags
                fs-linux-rooted-private-file-mode
                fs-linux-rooted-resolve-policy)]
            [fd : i64
              (linux-rooted-raw-guard-openat2
                parent-state.fd
                (io.array-const-ptr component-bytes)
                how)]
            (if (< fd 0)
              (linux-rooted-failed-guard
                (linux-rooted-guard-open-result-from-raw fd))
              (let
                [sidecar : FsLinuxRootedSourceSnapshot
                  (linux-rooted-fd-source-snapshot fd)]
                [policy : FsLinuxRootedResult
                  (linux-rooted-guard-sidecar-result (& sidecar))]
                (cond
                  [(not (linux-rooted-result-ok? policy))
                    (linux-rooted-failed-guard-after-close policy fd)]
                  [(cancel-check)
                    (linux-rooted-failed-guard-after-close
                      LinuxRootedCancelled
                      fd)]
                  [else
                    (let
                      [locked : FsLinuxRootedResult
                        (linux-rooted-lock-result-from-raw
                          (linux-rooted-raw-lock fd))]
                      (if (linux-rooted-result-ok? locked)
                        (FsLinuxRootedGuard
                          (linux-rooted-guard-state-new
                            (FsLinuxRootedGuardState
                              fd
                              LinuxRootedOk
                              sidecar.device
                              sidecar.inode
                              LinuxRootedClosed
                              LinuxRootedClosed)))
                        (linux-rooted-failed-guard-after-close locked fd)))]))))]))))

;: Acquisition result of a guard. `LinuxRootedOk` means the lock was taken;
;: it stays `Ok` after release, so use `linux-rooted-guard-locked?` for the
;: current state.
(define (linux-rooted-guard-result [guard : (& guard FsLinuxRootedGuard)]) : FsLinuxRootedResult
  (let
    [held : FsLinuxRootedGuardState
      (unsafe
        (linux-rooted-guard-state-read guard.state))]
    held.result))

;: True while the guard holds its lock.
(define (linux-rooted-guard-locked? [guard : (& guard FsLinuxRootedGuard)]) : bool
  (let
    [held : FsLinuxRootedGuardState
      (unsafe
        (linux-rooted-guard-state-read guard.state))]
    (and (>= held.fd 0) (linux-rooted-result-ok? held.result))))

;: The recorded close of a failed acquisition or of a release.
(define (linux-rooted-guard-close-result [guard : (& guard FsLinuxRootedGuard)]) : FsLinuxRootedResult
  (let
    [held : FsLinuxRootedGuardState
      (unsafe
        (linux-rooted-guard-state-read guard.state))]
    held.close))

;: Unlock outcome of a release.
(define (linux-rooted-guard-release-unlock
  [release : FsLinuxRootedGuardRelease]) : FsLinuxRootedResult
  release.unlock)

;: Close outcome of a release.
(define (linux-rooted-guard-release-close [release : FsLinuxRootedGuardRelease]) : FsLinuxRootedResult
  release.close)

;: True when both the unlock and the close of a release succeeded.
(define (linux-rooted-guard-release-ok? [release : FsLinuxRootedGuardRelease]) : bool
  (and
    (linux-rooted-result-ok? release.unlock)
    (linux-rooted-result-ok? release.close)))

;: Compare a fresh snapshot of a sidecar name with the locked sidecar's
;: identity. Another physical file is `IdentityChanged`, whether or not it
;: carries a special bit; the locked file is `Ok`, or `Unsupported` if it now
;: carries a special bit; a snapshot without identity (not a linked regular
;: file, or a failed `fstat`) keeps its own result.
(define (linux-rooted-guard-compare
  [device : u64]
  [inode : u64]
  [current : (& current FsLinuxRootedSourceSnapshot)]) : FsLinuxRootedResult
  (cond
    [(= current.links (cast 0 : u64)) (clone current.result)]
    [(not (and (= current.device device) (= current.inode inode)))
      LinuxRootedIdentityChanged]
    [else (clone current.result)]))

;: Check, before a transaction's first source cutover, that `component` below
;: the retained parent still names the sidecar this guard locked: one `O_PATH`
;: `openat2` without create, one `fstat`, one close. Another file at the name
;: (a hostile or careless substitution) is `IdentityChanged`, a symlink
;: `UnsafeResolution`, a removed sidecar `NotFound`; none of them is reported
;: as serialized. The close outcome is reported separately.
(define (linux-rooted-guard-revalidate
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [guard : (& guard FsLinuxRootedGuard)]
  [cancel-check : (-> bool)]) : FsLinuxRootedFinishResult
  (unsafe
    (let
      [parent-state : FsLinuxRootedHandleState
        (linux-rooted-state-read parent.state)]
      [held : FsLinuxRootedGuardState
        (linux-rooted-guard-state-read guard.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          (FsLinuxRootedFinishResult
            LinuxRootedInvalidComponent
            LinuxRootedClosed)]
        [(or
            (< parent-state.fd 0)
            (not (linux-rooted-result-ok? parent-state.result))
            (< held.fd 0)
            (not (linux-rooted-result-ok? held.result)))
          (FsLinuxRootedFinishResult LinuxRootedClosed LinuxRootedClosed)]
        [(cancel-check)
          (FsLinuxRootedFinishResult LinuxRootedCancelled LinuxRootedClosed)]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [how : FsLinuxOpenHow
              (FsLinuxOpenHow
                fs-linux-rooted-revalidate-flags
                (cast 0 : u64)
                fs-linux-rooted-resolve-policy)]
            [fd : i64
              (linux-rooted-raw-reopenat2
                parent-state.fd
                (io.array-const-ptr component-bytes)
                how)]
            (if (< fd 0)
              (FsLinuxRootedFinishResult
                (linux-rooted-result-from-raw fd)
                LinuxRootedClosed)
              (let
                [current : FsLinuxRootedSourceSnapshot
                  (linux-rooted-fd-source-snapshot fd)]
                [operation : FsLinuxRootedResult
                  (linux-rooted-guard-compare
                    held.device
                    held.inode
                    (& current))]
                (FsLinuxRootedFinishResult
                  operation
                  (linux-rooted-close-fd-once fd)))))]))))

;: Release a guard: one `LOCK_UN` attempt while the lock is held, then one
;: close regardless of its outcome. The descriptor is poisoned first, so later
;: cleanup is a no-op. A guard that holds nothing reports `Closed` for the
;: unlock and its recorded close.
(define (linux-rooted-guard-release! [guard : (&mut guard FsLinuxRootedGuard)]) : FsLinuxRootedGuardRelease
  (unsafe
    (let
      [held : FsLinuxRootedGuardState
        (linux-rooted-guard-state-read guard.state)]
      (if (< held.fd 0)
        (FsLinuxRootedGuardRelease LinuxRootedClosed held.close)
        (let
          [unlock : FsLinuxRootedResult
            (if (linux-rooted-result-ok? held.result)
              (linux-rooted-unlock-result-from-raw
                (linux-rooted-raw-unlock held.fd))
              LinuxRootedClosed)]
          (begin
            (linux-rooted-guard-state-write!
              guard.state
              (FsLinuxRootedGuardState
                -1
                held.result
                held.device
                held.inode
                unlock
                LinuxRootedClosed))
            (let
              [close-result : FsLinuxRootedResult
                (linux-rooted-close-fd-once held.fd)]
              (begin
                (linux-rooted-guard-state-write!
                  guard.state
                  (FsLinuxRootedGuardState
                    -1
                    held.result
                    held.device
                    held.inode
                    unlock
                    close-result))
                (FsLinuxRootedGuardRelease unlock close-result)))))))))

;: Construct a no-data read outcome.
(define (linux-rooted-empty-read-result
  [operation : FsLinuxRootedResult]
  [eof : bool]) : FsLinuxRootedReadResult
  (FsLinuxRootedReadResult
    operation
    (byte_buf.from-array (__tl_make-array u8 0))
    eof
    false))

;: Construct a scalar caller-owned-buffer read outcome with no valid new bytes.
(define (linux-rooted-empty-read-into-result
  [operation : FsLinuxRootedResult]
  [eof : bool]) : FsLinuxRootedReadIntoResult
  (FsLinuxRootedReadIntoResult operation 0 eof false))

;: Read at most one MiB into an initialized caller-owned mutable byte range.
;:
;: `count` is checked against both the fixed request ceiling and the borrowed
;: view before descriptor access or I/O. On success exactly `[0, result.count)`
;: contains newly read bytes; the initialized suffix remains outside the valid
;: result prefix. A positive short read is successful progress, a zero-byte
;: positive read is EOF, and a zero request is successful without claiming
;: EOF. On failure `result.count` is zero, so no buffer prefix is exposed as
;: newly read. The mutable borrow ends with the call and no pointer escapes.
(define (linux-rooted-read-file-into!
  [file : (&mut file FsLinuxRootedReadFile)]
  [out : (&mut out bytes)]
  [count : i64]
  [cancel-check : (-> bool)]) : FsLinuxRootedReadIntoResult
  (unsafe
    (let
      [length : i64 (byte_buf.bytes-mut-length out)]
      (cond
        [(or
            (< count 0)
            (> count fs-linux-rooted-read-max-bytes)
            (> count length))
          (linux-rooted-empty-read-into-result LinuxRootedInvalidLength false)]
        [else
          (let
            [state : FsLinuxRootedHandleState
              (linux-rooted-state-read file.state)]
            (cond
              [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
                (linux-rooted-empty-read-into-result LinuxRootedClosed false)]
              [(cancel-check)
                (linux-rooted-empty-read-into-result LinuxRootedCancelled false)]
              [(= count 0)
                (linux-rooted-empty-read-into-result LinuxRootedOk false)]
              [else
                (let
                  [raw : i64 -4]
                  (begin
                    (while (and (= raw -4) (not (cancel-check)))
                      (set!
                        raw
                        (linux-rooted-raw-read
                          state.fd
                          (byte_buf.bytes-mut-data out)
                          count)))
                    (cond
                      [(>= raw 0)
                        (FsLinuxRootedReadIntoResult
                          LinuxRootedOk
                          raw
                          (= raw 0)
                          (and (> raw 0) (< raw count)))]
                      [(or (= raw -4) (= raw -125))
                        (linux-rooted-empty-read-into-result
                          LinuxRootedCancelled
                          false)]
                      [else
                        (linux-rooted-empty-read-into-result
                          LinuxRootedReadFailure
                          false)])))]))]))))

;: Read at most one MiB from a retained regular-file descriptor. EINTR retries
;: only while cancellation remains clear. Short success and EOF are explicit.
(define (linux-rooted-read-file-chunk!
  [file : (&mut file FsLinuxRootedReadFile)]
  [count : i64]
  [cancel-check : (-> bool)]) : FsLinuxRootedReadResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read file.state)]
      (cond
        [(or (< count 0) (> count fs-linux-rooted-read-max-bytes))
          (linux-rooted-empty-read-result LinuxRootedInvalidLength false)]
        [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
          (linux-rooted-empty-read-result LinuxRootedClosed false)]
        [(cancel-check)
          (linux-rooted-empty-read-result LinuxRootedCancelled false)]
        [(= count 0) (linux-rooted-empty-read-result LinuxRootedOk false)]
        [else
          (let
            [slots : (__tl_dyn-array u8) (__tl_make-array u8 count)]
            [raw : i64 -4]
            (begin
              (while (and (= raw -4) (not (cancel-check)))
                (set!
                  raw
                  (linux-rooted-raw-read state.fd (__tl_array-data slots) count)))
              (cond
                [(>= raw 0)
                  (FsLinuxRootedReadResult
                    LinuxRootedOk
                    (byte_buf.from-array-prefix slots raw)
                    (= raw 0)
                    (and (> raw 0) (< raw count)))]
                [(or (= raw -4) (= raw -125))
                  (FsLinuxRootedReadResult
                    LinuxRootedCancelled
                    (byte_buf.from-array-prefix slots 0)
                    false
                    false)]
                [else
                  (FsLinuxRootedReadResult
                    LinuxRootedReadFailure
                    (byte_buf.from-array-prefix slots 0)
                    false
                    false)])))]))))

;: Atomically move one exact entry, replacing the destination entry current at
;: syscall time. A destination symlink is replaced as an entry and not followed.
(define (linux-rooted-rename-replace
  [source-parent : (& source-parent FsLinuxRootedDirectory)]
  [source-component : (& source-component str)]
  [destination-parent : (& destination-parent FsLinuxRootedDirectory)]
  [destination-component : (& destination-component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (unsafe
    (let
      [source-state : FsLinuxRootedHandleState
        (linux-rooted-state-read source-parent.state)]
      [destination-state : FsLinuxRootedHandleState
        (linux-rooted-state-read destination-parent.state)]
      (cond
        [(or
            (not (linux-rooted-component-valid? source-component))
            (not (linux-rooted-component-valid? destination-component)))
          LinuxRootedInvalidComponent]
        [(or
            (< source-state.fd 0)
            (< destination-state.fd 0)
            (not (linux-rooted-result-ok? source-state.result))
            (not (linux-rooted-result-ok? destination-state.result)))
          LinuxRootedClosed]
        [(cancel-check) LinuxRootedCancelled]
        [else
          (let
            [source-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string source-component)]
            [destination-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string destination-component)]
            [raw : i64
              (linux-rooted-raw-renameat
                source-state.fd
                (io.array-const-ptr source-bytes)
                destination-state.fd
                (io.array-const-ptr destination-bytes))]
            (linux-rooted-rename-result-from-raw raw))]))))

;: Remove one exact non-directory entry relative to a retained parent. If the
;: component currently names a symlink, the symlink itself is removed.
(define (linux-rooted-unlink-entry
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          LinuxRootedInvalidComponent]
        [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
          LinuxRootedClosed]
        [(cancel-check) LinuxRootedCancelled]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [raw : i64
              (linux-rooted-raw-unlinkat
                state.fd
                (io.array-const-ptr component-bytes))]
            (linux-rooted-cleanup-result-from-raw raw))]))))

;: Atomically move one exact entry only when the destination is absent.
;: Unsupported syscall or filesystem flag support is returned as typed failure;
;: this operation never degrades to a check-then-rename sequence.
(define (linux-rooted-rename-no-replace
  [source-parent : (& source-parent FsLinuxRootedDirectory)]
  [source-component : (& source-component str)]
  [destination-parent : (& destination-parent FsLinuxRootedDirectory)]
  [destination-component : (& destination-component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (unsafe
    (let
      [source-state : FsLinuxRootedHandleState
        (linux-rooted-state-read source-parent.state)]
      [destination-state : FsLinuxRootedHandleState
        (linux-rooted-state-read destination-parent.state)]
      (cond
        [(or
            (not (linux-rooted-component-valid? source-component))
            (not (linux-rooted-component-valid? destination-component)))
          LinuxRootedInvalidComponent]
        [(or
            (< source-state.fd 0)
            (< destination-state.fd 0)
            (not (linux-rooted-result-ok? source-state.result))
            (not (linux-rooted-result-ok? destination-state.result)))
          LinuxRootedClosed]
        [(cancel-check) LinuxRootedCancelled]
        [else
          (let
            [source-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string source-component)]
            [destination-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string destination-component)]
            [raw : i64
              (linux-rooted-raw-renameat2-noreplace
                source-state.fd
                (io.array-const-ptr source-bytes)
                destination-state.fd
                (io.array-const-ptr destination-bytes))]
            (linux-rooted-rename-result-from-raw raw))]))))

;: Remove one exact empty directory relative to a retained parent. This never
;: enumerates or traverses descendants.
(define (linux-rooted-remove-empty-directory
  [parent : (& parent FsLinuxRootedDirectory)]
  [component : (& component str)]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read parent.state)]
      (cond
        [(not (linux-rooted-component-valid? component))
          LinuxRootedInvalidComponent]
        [(or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
          LinuxRootedClosed]
        [(cancel-check) LinuxRootedCancelled]
        [else
          (let
            [component-bytes : (__tl_dyn-array u8)
              (linux-rooted-c-string component)]
            [raw : i64
              (linux-rooted-raw-rmdirat
                state.fd
                (io.array-const-ptr component-bytes))]
            (linux-rooted-cleanup-result-from-raw raw))]))))

;: Flush the retained parent directory as an explicit namespace-durability
;: boundary. This is separate from file-data fsync and from rename visibility.
(define (linux-rooted-directory-flush
  [directory : (& directory FsLinuxRootedDirectory)]
  [cancel-check : (-> bool)]) : FsLinuxRootedResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState
        (linux-rooted-state-read directory.state)]
      (if (or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
        LinuxRootedClosed
        (linux-rooted-flush-directory-fd state.fd cancel-check)))))

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

;: Prove a live stage descriptor is a regular file whose permission and
;: special bits are exactly `permissions`.
(unsafe
  (define (linux-rooted-verify-stage-mode [fd : i64] [permissions : i64]) : FsLinuxRootedResult
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
        (let
          [mode : i64
            (cast
              (unsafe
                (linux-rooted-stat-u32 statbuf fs-linux-rooted-stat-mode-offset))
              : i64)]
          (if (and
            (=
              (bit-and mode fs-linux-rooted-stat-kind-mask)
              fs-linux-rooted-stat-regular-mode)
            (= (bit-and mode fs-linux-rooted-mode-bits-mask) permissions))
            LinuxRootedOk
            LinuxRootedModeMismatch))))))

;: Check before writing that a newly created stage already has the source's
;: owner and group. Reproducing any other ownership would need privilege, so
;: such a source is `LinuxRootedUnsupported` for an unprivileged rewrite.
(unsafe
  (define (linux-rooted-stage-ownership
    [fd : i64]
    [source : (& source FsLinuxRootedSourceSnapshot)]) : FsLinuxRootedResult
    (let
      [stat-bytes : (__tl_dyn-array u8)
        (__tl_make-array u8 fs-linux-rooted-stat-buffer-size)]
      [statbuf : (MutPtr u8)
        (unsafe
          (__tl_array-data stat-bytes))]
      [raw : i64
        (unsafe
          (linux-rooted-raw-fstat fd statbuf))]
      (cond
        [(< raw 0) (linux-rooted-result-from-raw raw)]
        [(and
            (=
              (unsafe
                (linux-rooted-stat-u32
                  statbuf
                  fs-linux-rooted-stat-owner-offset))
              source.owner)
            (=
              (unsafe
                (linux-rooted-stat-u32
                  statbuf
                  fs-linux-rooted-stat-group-offset))
              source.group))
          LinuxRootedOk]
        [else LinuxRootedUnsupported]))))

;: Finish a private stage as the replacement for an admitted source. A source
;: that is not admitted, or whose permissions are not within `0777`, is
;: `InvalidPermissions`; a stage the caller cannot give the source's owner and
;: group is `Unsupported`. Both are reported before any byte is written.
;: Otherwise the contents are written, `fchmod` applies exactly the source
;: permissions, and a fresh `fstat` must show a regular file with exactly those
;: mode bits (`ModeMismatch` otherwise) before the optional flush. Every live
;: stage gets one close, reported independently as in `linux-rooted-file-finish!`.
(define (linux-rooted-file-finish-with-source-permissions!
  [file : (&mut file FsLinuxRootedFile)]
  [contents : (& contents bytes)]
  [promised-length : i64]
  [source : (& source FsLinuxRootedSourceSnapshot)]
  [flush : bool]
  [cancel-check : (-> bool)]) : FsLinuxRootedFinishResult
  (unsafe
    (let
      [state : FsLinuxRootedHandleState (linux-rooted-state-read file.state)]
      (if (or (< state.fd 0) (not (linux-rooted-result-ok? state.result)))
        (FsLinuxRootedFinishResult LinuxRootedClosed LinuxRootedClosed)
        (let
          [operation : FsLinuxRootedResult
            (if (and
              (linux-rooted-result-ok? (clone source.result))
              (>= source.permissions 0)
              (=
                (bit-and source.permissions fs-linux-rooted-permission-mask)
                source.permissions))
              (linux-rooted-stage-ownership state.fd source)
              LinuxRootedInvalidPermissions)]
          (begin
            (if (linux-rooted-result-ok? operation)
              (set!
                operation
                (linux-rooted-write-all
                  state.fd
                  contents
                  promised-length
                  cancel-check))
              unit)
            (if (linux-rooted-result-ok? operation)
              (set!
                operation
                (linux-rooted-apply-mode
                  state.fd
                  (cast source.permissions : u64)
                  cancel-check))
              unit)
            (if (linux-rooted-result-ok? operation)
              (begin
                (linux-rooted-after-source-mode state.fd)
                (set!
                  operation
                  (linux-rooted-verify-stage-mode state.fd source.permissions)))
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

;: Explicitly close a rooted read capability exactly once.
(define (linux-rooted-read-file-close!
  [file : (&mut file FsLinuxRootedReadFile)]) : FsLinuxRootedResult
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
      [(LinuxRootedClosed) 14]
      [(LinuxRootedCrossDevice) 15]
      [(LinuxRootedDirectoryNotEmpty) 16]
      [(LinuxRootedInvalidLength) 17]
      [(LinuxRootedLengthMismatch) 18]
      [(LinuxRootedReadFailure) 19]
      [(LinuxRootedIdentityChanged) 20]
      [(LinuxRootedSourceChanged) 21]
      [(LinuxRootedInvalidPermissions) 22]
      [(LinuxRootedModeMismatch) 23]
      [(LinuxRootedLockConflict) 24])))

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
  (define (linux-rooted-test-stat
    [device : u64]
    [inode : u64]
    [links : u64]
    [mode : u32]
    [owner : u32]
    [group : u32]
    [length : i64]) : (__tl_dyn-array u8)
    (let
      [bytes : (__tl_dyn-array u8)
        (__tl_make-array u8 fs-linux-rooted-stat-buffer-size)]
      [data : (MutPtr u8)
        (unsafe
          (__tl_array-data bytes))]
      (begin
        (unsafe
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-device-offset)
              : (MutPtr u64))
            device)
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-inode-offset)
              : (MutPtr u64))
            inode)
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-links-offset)
              : (MutPtr u64))
            links)
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-mode-offset)
              : (MutPtr u32))
            mode)
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-owner-offset)
              : (MutPtr u32))
            owner)
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-group-offset)
              : (MutPtr u32))
            group)
          (ptr-write!
            (ptr-cast
              (ptr-offset data fs-linux-rooted-stat-size-offset)
              : (MutPtr i64))
            length))
        bytes))))

(cfg
  test
  (define (linux-rooted-test-snapshot
    [device : i64]
    [inode : i64]
    [links : i64]
    [mode : i64]
    [length : i64]) : FsLinuxRootedSourceSnapshot
    (let
      [bytes : (__tl_dyn-array u8)
        (linux-rooted-test-stat
          (cast device : u64)
          (cast inode : u64)
          (cast links : u64)
          (cast mode : u32)
          (cast 1000 : u32)
          (cast 1001 : u32)
          length)]
      (unsafe
        (linux-rooted-source-snapshot-from-stat (__tl_array-data bytes))))))

(cfg
  test
  (test
    fs-rooted-linux-source-snapshot-admission
    (let
      ;; 0100640: regular, rw-r-----.
      [admitted : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 2 33184 10)]
      [empty : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33188 0)]
      [directory : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 2 16877 10)]
      [fifo : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 4516 0)]
      ;; 0104755 (setuid), 0102755 (setgid), 0101644 (sticky).
      [setuid : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 35309 10)]
      [setgid : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 34285 10)]
      [sticky : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33700 10)]
      [unlinked : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 0 33184 10)]
      [negative : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33184 -1)]
      (begin
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& admitted)))
          0
          "regular source is admitted")
        (test.assert-i64-eq
          (linux-rooted-source-permissions (& admitted))
          416
          "admitted permissions keep exactly 0640")
        (test.assert-i64-eq
          (linux-rooted-source-length (& admitted))
          10
          "length")
        (test.assert-true
          (= (linux-rooted-source-links (& admitted)) (cast 2 : u64))
          "link count")
        (test.assert-true
          (and
            (= admitted.owner (cast 1000 : u32))
            (= admitted.group (cast 1001 : u32)))
          "owner and group")
        (test.assert-i64-eq
          (linux-rooted-test-result-code (linux-rooted-source-result (& empty)))
          0
          "an empty regular file is admitted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& directory)))
          5
          "directory is wrong kind")
        (test.assert-i64-eq
          (linux-rooted-test-result-code (linux-rooted-source-result (& fifo)))
          5
          "FIFO is wrong kind")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& setuid)))
          7
          "setuid source is not admitted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& setgid)))
          7
          "setgid source is not admitted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& sticky)))
          7
          "sticky source is not admitted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& unlinked)))
          2
          "an unlinked source is not found")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-result (& negative)))
          8
          "a negative size is an I/O failure")))))

(cfg
  test
  (test
    fs-rooted-linux-source-compare
    (let
      [admitted : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33184 10)]
      [same : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33184 10)]
      [other-inode : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 100 1 33184 10)]
      [other-device : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 8 99 1 33184 10)]
      [rewritten : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33184 11)]
      [linked : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 2 33184 10)]
      [chmodded : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33188 10)]
      [made-setuid : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 35232 10)]
      [replaced-setuid : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 100 1 35232 10)]
      [unreadable : FsLinuxRootedSourceSnapshot
        (linux-rooted-failed-source-snapshot LinuxRootedUnsupported)]
      [now-directory : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 2 16877 10)]
      (begin
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& same)))
          0
          "an unchanged source revalidates")
        (test.assert-true
          (linux-rooted-source-same-file? (& admitted) (& same))
          "equal device and inode are the same file")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& other-inode)))
          20
          "another inode is a changed identity")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& other-device)))
          20
          "the same inode number on another device is a changed identity")
        (test.assert-false
          (linux-rooted-source-same-file? (& admitted) (& other-device))
          "identity needs both device and inode")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& rewritten)))
          21
          "a size change on the same file is a changed source")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& linked)))
          21
          "a new hard link is a changed source")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& chmodded)))
          21
          "a permission change is a changed source")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& made-setuid)))
          21
          "a special bit added to the same file is a changed source")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& replaced-setuid)))
          20
          "another inode carrying a special bit is a changed identity")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& unreadable)))
          7
          "a failed fresh snapshot keeps its own result")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-source-compare (& admitted) (& now-directory)))
          5
          "a name that became a directory keeps its own result")))))

(cfg
  test
  (define (linux-rooted-test-sidecar
    [links : i64]
    [owner : u32]
    [permissions : i64]) : FsLinuxRootedSourceSnapshot
    (FsLinuxRootedSourceSnapshot
      LinuxRootedOk
      (cast 7 : u64)
      (cast 99 : u64)
      0
      (cast links : u64)
      owner
      (cast 1001 : u32)
      permissions)))

(cfg
  test
  (test
    fs-rooted-linux-guard-policy
    (let
      [user : u32 (linux-rooted-effective-user)]
      [private : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-sidecar 1 user 384)]
      [read-only : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-sidecar 1 user 292)]
      [aliased : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-sidecar 2 user 384)]
      [foreign : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-sidecar 1 (+ user (cast 1 : u32)) 384)]
      [group-writable : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-sidecar 1 user 432)]
      [other-writable : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-sidecar 1 user 386)]
      [directory : FsLinuxRootedSourceSnapshot
        (linux-rooted-failed-source-snapshot LinuxRootedWrongKind)]
      (begin
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& private)))
          0
          "a private sidecar owned by the effective user is trusted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& read-only)))
          0
          "a read-only sidecar can still be locked")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& aliased)))
          7
          "a hard-linked sidecar is not trusted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& foreign)))
          7
          "another user's sidecar is not trusted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& group-writable)))
          7
          "a group-writable sidecar is not trusted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& other-writable)))
          7
          "an other-writable sidecar is not trusted")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-sidecar-result (& directory)))
          5
          "a sidecar that is not a regular file keeps its kind result")))))

(cfg
  test
  (test
    fs-rooted-linux-lock-taxonomy
    (begin
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw 0))
        0
        "an acquired lock is Ok")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw -11))
        24
        "EWOULDBLOCK is a lock conflict")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw -4))
        9
        "EINTR is cancellation")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw -37))
        7
        "ENOLCK is unsupported")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw -22))
        7
        "EINVAL is unsupported")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw -95))
        7
        "EOPNOTSUPP is unsupported")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-lock-result-from-raw -5))
        8
        "other lock errors are I/O failures")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-unlock-result-from-raw 0))
        0
        "an unlock is Ok")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-unlock-result-from-raw -4))
        9
        "an interrupted unlock is cancellation")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-unlock-result-from-raw -9))
        8
        "other unlock errors are I/O failures"))))

(cfg
  test
  (test
    fs-rooted-linux-guard-compare
    (let
      [same : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 33152 0)]
      [other : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 100 1 33152 0)]
      [other-setuid : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 100 1 35200 0)]
      [same-setuid : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 1 35200 0)]
      [now-directory : FsLinuxRootedSourceSnapshot
        (linux-rooted-test-snapshot 7 99 2 16877 0)]
      [unreadable : FsLinuxRootedSourceSnapshot
        (linux-rooted-failed-source-snapshot LinuxRootedUnsupported)]
      [device : u64 (cast 7 : u64)]
      [inode : u64 (cast 99 : u64)]
      (begin
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-compare device inode (& same)))
          0
          "the locked sidecar revalidates")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-compare device inode (& other)))
          20
          "another file at the name is a changed identity")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-compare device inode (& other-setuid)))
          20
          "another file carrying a special bit is a changed identity")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-compare device inode (& same-setuid)))
          7
          "the locked sidecar newly carrying a special bit is unsupported")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-compare device inode (& now-directory)))
          5
          "a name that became a directory keeps its own result")
        (test.assert-i64-eq
          (linux-rooted-test-result-code
            (linux-rooted-guard-compare device inode (& unreadable)))
          7
          "a failed fresh snapshot keeps its own result")))))

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
        (linux-rooted-test-result-code
          (linux-rooted-rename-result-from-raw -18))
        15
        "rename EXDEV is cross-device")
      (test.assert-i64-eq
        (linux-rooted-test-result-code
          (linux-rooted-cleanup-result-from-raw -39))
        16
        "cleanup ENOTEMPTY is directory-not-empty")
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
        "unclassified errno is generic I/O")
      (test.assert-i64-eq
        (linux-rooted-test-result-code (linux-rooted-result-from-errno 40))
        4
        "a source symlink (ELOOP) is unsafe resolution")
      (test.assert-i64-eq
        (linux-rooted-test-result-code
          (linux-rooted-guard-open-result-from-raw -6))
        5
        "a guard sidecar that is a socket (ENXIO) is wrong kind")
      (test.assert-i64-eq
        (linux-rooted-test-result-code
          (linux-rooted-guard-open-result-from-raw -40))
        4
        "a guard sidecar symlink (ELOOP) stays unsafe resolution"))))

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
        fs-linux-rooted-syscall-read
        0
        "x86-64 read syscall number")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-lseek
        8
        "x86-64 lseek syscall number")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-unlinkat
        263
        "x86-64 unlinkat syscall number")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-renameat
        264
        "x86-64 renameat syscall number")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-renameat2
        316
        "x86-64 renameat2 syscall number")
      (test.assert-i64-eq fs-linux-rooted-at-removedir 512 "AT_REMOVEDIR value")
      (test.assert-i64-eq
        fs-linux-rooted-rename-noreplace
        1
        "RENAME_NOREPLACE value")
      (test.assert-i64-eq
        fs-linux-rooted-stat-size-offset
        48
        "x86-64 stat.st_size offset")
      (test.assert-i64-eq
        fs-linux-rooted-stat-device-offset
        0
        "x86-64 stat.st_dev offset")
      (test.assert-i64-eq
        fs-linux-rooted-stat-inode-offset
        8
        "x86-64 stat.st_ino offset")
      (test.assert-i64-eq
        fs-linux-rooted-stat-links-offset
        16
        "x86-64 stat.st_nlink offset")
      (test.assert-i64-eq
        fs-linux-rooted-stat-owner-offset
        28
        "x86-64 stat.st_uid offset")
      (test.assert-i64-eq
        fs-linux-rooted-stat-group-offset
        32
        "x86-64 stat.st_gid offset")
      (test.assert-i64-eq fs-linux-rooted-permission-mask 511 "0777 mask")
      (test.assert-i64-eq fs-linux-rooted-special-mode-mask 3584 "07000 mask")
      (test.assert-i64-eq fs-linux-rooted-mode-bits-mask 4095 "07777 mask")
      (test.assert-i64-eq fs-linux-rooted-shared-write-mask 18 "022 mask")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-flock
        73
        "x86-64 flock syscall number")
      (test.assert-i64-eq
        fs-linux-rooted-syscall-geteuid
        107
        "x86-64 geteuid syscall number")
      (test.assert-i64-eq fs-linux-rooted-lock-exclusive 2 "LOCK_EX value")
      (test.assert-i64-eq fs-linux-rooted-lock-nonblocking 4 "LOCK_NB value")
      (test.assert-i64-eq fs-linux-rooted-lock-unlock 8 "LOCK_UN value")
      (test.assert-i64-eq
        (cast fs-linux-rooted-guard-open-flags : i64)
        657472
        "guard sidecar create-or-open flags")
      (test.assert-i64-eq
        fs-linux-rooted-read-max-bytes
        1048576
        "bounded read allocation ceiling")
      (test.assert-i64-eq
        (cast fs-linux-rooted-directory-open-flags : i64)
        720896
        "directory open flags")
      (test.assert-i64-eq
        (cast fs-linux-rooted-file-create-flags : i64)
        655553
        "exclusive file create flags")
      (test.assert-i64-eq
        (cast fs-linux-rooted-file-read-flags : i64)
        657408
        "verified reopen read flags"))))