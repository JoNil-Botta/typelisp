;# stdlib/fs.tl - Minimal filesystem helpers for TypeLisp tools (#850).
;#
;# Provides recoverable current-directory and temporary-directory APIs, path-join,
;# lexical path normalization, safe relative suffix checks, and cleanup helpers on
;# top of direct platform FFI bindings:
;#
;# `fs-mkdir-status`, `fs-remove-file-status`, `fs-remove-dir-status`,
;# `fs-rename-status`, `fs-read-dir-status`, `fs-read-dir`,
;# `fs-file-kind-status`, `fs-file-size-status`, `fs-file-size`,
;# `fs-process-id`, `fs-current-dir-status`, and `fs-current-dir`.
;#
;# Usage: `(import "stdlib/fs.tl")`
;#
;# ```typelisp
;# (import "stdlib/fs.tl")
;# (define joined : String
;#   (let
;#     [left : String "target"]
;#     [right : String "tool-output.s"]
;#     (fs-path-join (& left) (& right))))
;# (define nested : String
;#   (fs-path-join-many "target" "typelisp" "cache"))
;# ```
(import "core_macros.tl" module stdlib.core-macros as core)

(import "env.tl")

(import "io.tl")

(import "list.tl")

(import "string.tl")

;: Result type for directory-listing APIs.
(defenum ResultIoStringList
  (OkIoStringList StringList)
  (ErrIoStringList IoError))

;: Linux `mkdir` via the `mkdir` syscall (number 83).
(define (fs-linux-syscall-mkdir [path : (Ptr u8)] [mode : i64]) : i64
  (io-linux-syscall-status (syscall 83 (io-linux-ptr-arg path) mode)))

;: Linux `unlink` via the `unlink` syscall (number 87).
(define (fs-linux-syscall-unlink [path : (Ptr u8)]) : i64
  (io-linux-syscall-status (syscall 87 (io-linux-ptr-arg path))))

;: Linux `rmdir` via the `rmdir` syscall (number 84).
(define (fs-linux-syscall-rmdir [path : (Ptr u8)]) : i64
  (io-linux-syscall-status (syscall 84 (io-linux-ptr-arg path))))

;: Linux `rename` via the `rename` syscall (number 82).
(define (fs-linux-syscall-rename [source : (Ptr u8)] [destination : (Ptr u8)]) : i64
  (io-linux-syscall-status
    (syscall 82 (io-linux-ptr-arg source) (io-linux-ptr-arg destination))))

;: Linux `getpid` via the `getpid` syscall (number 39); never fails.
(define (fs-linux-syscall-getpid) : i64
  (syscall 39))

;: Linux `getcwd` via the `getcwd` syscall (number 79).
;: Returns the buffer pointer on success or a null pointer on error, matching
;: the C `getcwd` contract the callers expect.
(define (fs-linux-syscall-getcwd [buf : (MutPtr u8)] [size : i64]) : (Ptr u8)
  (let
    [ptr : i64
      (io-linux-ptr-arg
        (unsafe
          (ptr-cast buf : (Ptr u8))))]
    [result : i64 (io-linux-syscall-status (syscall 79 ptr size))]
    (if (< result 0)
      (unsafe
        (int->ptr (cast 0 : u64) : (Ptr u8)))
      (unsafe
        (int->ptr (cast ptr : u64) : (Ptr u8))))))

;: Linux `openat` syscall (number 257), used for directory enumeration.
(define (fs-linux-syscall-openat
  [dirfd : i64]
  [path : (Ptr u8)]
  [flags : i64]
  [mode : i64]) : i64
  (io-linux-syscall-status
    (syscall 257 dirfd (io-linux-ptr-arg path) flags mode)))

;: Linux `getdents64` syscall (number 217), returning bytes read or -1.
(define (fs-linux-syscall-getdents64
  [fd : i64]
  [buf : (MutPtr u8)]
  [count : i64]) : i64
  (io-linux-syscall-status
    (syscall
      217
      fd
      (io-linux-ptr-arg
        (unsafe
          (ptr-cast buf : (Ptr u8))))
      count)))

;: Windows kernel32 bindings backing the directory/file primitives (#2142
;: slice 1), replacing the former `_mkdir`/`_unlink`/`_rmdir` CRT-ABI shims.
(cfg
  windows
  (extern (fs-win-create-directory [arg0 : (Ptr u8)] [arg1 : i64]) : i32 (:symbol "CreateDirectoryA")))

(cfg
  windows
  (extern (fs-win-remove-directory [arg0 : (Ptr u8)]) : i32 (:symbol "RemoveDirectoryA")))

(cfg
  windows
  (extern (fs-win-delete-file [arg0 : (Ptr u8)]) : i32 (:symbol "DeleteFileA")))

(cfg windows (extern (fs-win-get-last-error) : i32 (:symbol "GetLastError")))

(cfg
  windows
  (extern (fs-win-get-file-attributes-ex
    [arg0 : (Ptr u8)]
    [arg1 : i32]
    [arg2 : (MutPtr u8)]) : i32 (:symbol "GetFileAttributesExA")))

(cfg
  windows
  (extern (fs-win-find-first-file [arg0 : (Ptr u8)] [arg1 : (MutPtr u8)]) : i64 (:symbol "FindFirstFileA")))

(cfg
  windows
  (extern (fs-win-find-next-file [arg0 : i64] [arg1 : (MutPtr u8)]) : i32 (:symbol "FindNextFileA")))

(cfg
  windows
  (extern (fs-win-find-close [arg0 : i64]) : i32 (:symbol "FindClose")))

;: Windows `_mkdir` replacement via CreateDirectoryA; ERROR_ALREADY_EXISTS
;: (183) maps to EEXIST (17) so building over an existing directory keeps the
;: prior behavior (see the freestanding errno-mapping fix).
(cfg
  windows
  (define (fs-windows-mkdir [path : (Ptr u8)]) : i32
    (if (= (fs-win-create-directory path 0) (cast 0 : i32))
      (begin
        (io-set-error-code
          (if (= (fs-win-get-last-error) (cast 183 : i32))
            17
            2))
        (cast -1 : i32))
      (cast 0 : i32))))

;: Windows `_unlink` replacement via DeleteFileA.
(cfg
  windows
  (define (fs-windows-unlink [path : (Ptr u8)]) : i32
    (if (= (fs-win-delete-file path) (cast 0 : i32))
      (begin
        (io-set-error-code 2)
        (cast -1 : i32))
      (cast 0 : i32))))

;: Windows `_rmdir` replacement via RemoveDirectoryA.
(cfg
  windows
  (define (fs-windows-rmdir [path : (Ptr u8)]) : i32
    (if (= (fs-win-remove-directory path) (cast 0 : i32))
      (begin
        (io-set-error-code 2)
        (cast -1 : i32))
      (cast 0 : i32))))

;: Windows `GetCurrentProcessId` binding for process ids.
(extern (fs-windows-get-current-process-id) : u32 (:symbol "GetCurrentProcessId"))

;: Windows `GetCurrentDirectoryA` binding for current-directory lookup.
(extern (fs-windows-get-current-directory [arg0 : u32] [arg1 : (MutPtr u8)]) : u32 (:symbol "GetCurrentDirectoryA"))

;: Windows kernel32 binding for path moves (#2142 slice 1), replacing the
;: former `rename` CRT-ABI shim.
(cfg
  windows
  (extern (fs-win-move-file-ex [arg0 : (Ptr u8)] [arg1 : (Ptr u8)] [arg2 : i32]) : i32 (:symbol "MoveFileExA")))

;: Windows `rename` replacement via MoveFileExA with MOVEFILE_REPLACE_EXISTING.
(cfg
  windows
  (define (fs-windows-rename [source : (Ptr u8)] [destination : (Ptr u8)]) : i32
    (if (=
      (fs-win-move-file-ex source destination (cast 1 : i32))
      (cast 0 : i32))
      (begin
        (io-set-error-code 2)
        (cast -1 : i32))
      (cast 0 : i32))))

;: Convert a zero-success C result into the current host error code.
(define (fs-status-from-result [result : i64]) : i64
  (if (= result 0)
    0
    (io-last-error-code)))

;: Create an owned path string as a directory and return a host status code.
(define (fs-mkdir-status-owned [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [path-ptr : (Ptr u8) (io-array-const-ptr path-bytes)]
    (fs-status-from-result
      (cfg
        windows
        (cast (fs-windows-mkdir path-ptr) : i64)
        (fs-linux-syscall-mkdir path-ptr 448)))))

;: Return the host status code for creating a directory.
(define (fs-mkdir-status [path : (& path str)]) : i64
  (let
    [path-text : String (string-copy-borrowed path)]
    (fs-mkdir-status-owned path-text)))

;: Remove an owned path string as a file and return a host status code.
(define (fs-remove-file-status-owned [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [path-ptr : (Ptr u8) (io-array-const-ptr path-bytes)]
    (fs-status-from-result
      (cfg
        windows
        (cast (fs-windows-unlink path-ptr) : i64)
        (fs-linux-syscall-unlink path-ptr)))))

;: Return the host status code for removing a file.
(define (fs-remove-file-status [path : (& path str)]) : i64
  (let
    [path-text : String (string-copy-borrowed path)]
    (fs-remove-file-status-owned path-text)))

;: Remove an owned path string as an empty directory and return a host status code.
(define (fs-remove-dir-status-owned [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [path-ptr : (Ptr u8) (io-array-const-ptr path-bytes)]
    (fs-status-from-result
      (cfg
        windows
        (cast (fs-windows-rmdir path-ptr) : i64)
        (fs-linux-syscall-rmdir path-ptr)))))

;: Return the host status code for removing an empty directory.
(define (fs-remove-dir-status [path : (& path str)]) : i64
  (let
    [path-text : String (string-copy-borrowed path)]
    (fs-remove-dir-status-owned path-text)))

;: Rename owned source and destination path strings and return a host status code.
(define (fs-rename-status-owned [source : String] [destination : String]) : i64
  (let
    [source-bytes : (Array u8) (io-c-string source)]
    [destination-bytes : (Array u8) (io-c-string destination)]
    (fs-status-from-result
      (cfg
        windows
        (cast
          (fs-windows-rename
            (io-array-const-ptr source-bytes)
            (io-array-const-ptr destination-bytes))
          : i64)
        (fs-linux-syscall-rename
          (io-array-const-ptr source-bytes)
          (io-array-const-ptr destination-bytes))))))

;: Return the host status code for renaming a path.
(define (fs-rename-status
  [source : (& source str)]
  [destination : (& destination str)]) : i64
  (let
    [source-text : String (string-copy-borrowed source)]
    [destination-text : String (string-copy-borrowed destination)]
    (fs-rename-status-owned source-text destination-text)))

;: Return the host process id.
(define (fs-process-id) : i64
  (cfg
    windows
    (cast (fs-windows-get-current-process-id) : i64)
    (fs-linux-syscall-getpid)))

;: Linux `AT_FDCWD` for path-relative `openat`.
(define fs-linux-at-fdcwd : i64
  -100)

;: Linux `O_DIRECTORY`, requiring the opened path to be a directory.
(define fs-linux-open-directory : i64
  65536)

;: Directory enumeration scratch buffer size used by the former backend runtime.
(define fs-read-dir-buffer-size : i64
  32768)

;: Size of the Windows `WIN32_FIND_DATAA` structure used by FindFirstFileA.
(define fs-windows-find-data-size : i64
  320)

;: Offset of `cFileName` within `WIN32_FIND_DATAA`.
(define fs-windows-find-data-name-offset : i64
  44)

;: Read one byte from a C string-like pointer as an integer.
(define (fs-c-string-byte [ptr : (Ptr u8)] [offset : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset ptr offset)))
    : i64))

;: Return true when a directory entry name is `.` or `..`.
(define (fs-read-dir-dot-entry? [name : (Ptr u8)]) : bool
  (if (!= (fs-c-string-byte name 0) 46)
    false
    (let
      [second : i64 (fs-c-string-byte name 1)]
      (if (= second 0)
        true
        (and (= second 46) (= (fs-c-string-byte name 2) 0))))))

;: Append one non-dot entry name plus a newline to `out`.
(define (fs-read-dir-append-entry! [out : (Array u8)] [name : (Ptr u8)]) : unit
  (if (fs-read-dir-dot-entry? name)
    unit
    (let
      [i : i64 0]
      [done : bool false]
      (begin
        (while (not done)
          (let
            [byte : u8
              (unsafe
                (ptr-read (ptr-offset name i)))]
            (if (= (cast byte : i64) 0)
              (set! done true)
              (begin
                (array-push! out byte)
                (set! i (+ i 1))))))
        (array-push! out (cast #\newline' : u8))))))

;: Convert the accumulated newline-delimited bytes into a String.
(define (fs-read-dir-bytes-string [out : (Array u8)]) : String
  (unsafe
    (string-from-bytes (io-array-const-ptr out) (array-length out))))

;: Read the Linux `d_reclen` field from a `linux_dirent64` record.
(cfg
  (not windows)
  (define (fs-linux-dirent-reclen [base : (Ptr u8)] [offset : i64]) : i64
    (cast
      (unsafe
        (ptr-read (ptr-cast (ptr-offset base (+ offset 16)) : (Ptr u16))))
      : i64)))

;: Return the Linux `d_name` pointer from a `linux_dirent64` record.
(cfg
  (not windows)
  (define (fs-linux-dirent-name [base : (Ptr u8)] [offset : i64]) : (Ptr u8)
    (unsafe
      (ptr-offset base (+ offset 19)))))

;: Open an owned path as a Linux directory.
(cfg
  (not windows)
  (define (fs-linux-open-dir-owned [path : String]) : i64
    (let
      [path-bytes : (Array u8) (io-c-string path)]
      (fs-linux-syscall-openat
        fs-linux-at-fdcwd
        (io-array-const-ptr path-bytes)
        fs-linux-open-directory
        0))))

;: Return the Linux host status code for opening and closing a directory.
(cfg
  (not windows)
  (define (fs-linux-read-dir-status [path : String]) : i64
    (let
      [fd : i64 (fs-linux-open-dir-owned path)]
      (if (< fd 0)
        (io-last-error-code)
        (fs-status-from-result (io-linux-syscall-close fd))))))

;: Append entries from one Linux getdents64 buffer page.
(cfg
  (not windows)
  (define (fs-linux-read-dir-append-page!
    [buf : (Array u8)]
    [read-count : i64]
    [out : (Array u8)]) : unit
    (let
      [base : (Ptr u8) (io-array-const-ptr buf)]
      [offset : i64 0]
      [done : bool false]
      (while (not done)
        (if (>= offset read-count)
          (set! done true)
          (let
            [reclen : i64 (fs-linux-dirent-reclen base offset)]
            (if (<= reclen 0)
              (set! done true)
              (begin
                (fs-read-dir-append-entry!
                  out
                  (fs-linux-dirent-name base offset))
                (set! offset (+ offset reclen))))))))))

;: Return the newline-delimited Linux directory listing payload.
(cfg
  (not windows)
  (define (fs-linux-read-dir [path : String]) : String
    (let
      [fd : i64 (fs-linux-open-dir-owned path)]
      (if (< fd 0)
        ""
        (let
          [buf : (Array u8) (make-array u8 fs-read-dir-buffer-size)]
          [out : (Array u8) (make-array u8 0)]
          [ok : bool true]
          [done : bool false]
          (begin
            (while (not done)
              (let
                [read-count : i64
                  (fs-linux-syscall-getdents64
                    fd
                    (io-array-ptr buf)
                    fs-read-dir-buffer-size)]
                (core/cond
                  (< read-count 0)
                  (begin
                    (set! ok false)
                    (set! done true))
                  (= read-count 0)
                  (set! done true)
                  (fs-linux-read-dir-append-page! buf read-count out))))
            (io-linux-syscall-close fd)
            (if ok
              (fs-read-dir-bytes-string out)
              "")))))))

;: Map Windows `GetLastError` values to errno-style stdlib statuses.
(cfg
  windows
  (define (fs-windows-last-error-status) : i64
    (let
      [code : i64 (cast (fs-win-get-last-error) : i64)]
      (core/cond
        (= code 2)
        io-status-not-found
        (= code 3)
        io-status-not-directory
        (= code 5)
        io-status-permission-denied
        (= code 87)
        io-status-invalid
        (= code 123)
        io-status-invalid
        (= code 161)
        io-status-invalid
        (= code 206)
        io-status-name-too-long
        (= code 267)
        io-status-not-directory
        code))))

;: Return an I/O error status when Windows reported no concrete code.
(cfg
  windows
  (define (fs-windows-nonzero-status [status : i64]) : i64
    (if (= status io-status-ok)
      io-status-io-error
      status)))

;: Build the `path\*` search pattern expected by FindFirstFileA.
(cfg
  windows
  (define (fs-windows-read-dir-pattern [path : String]) : String
    (string-append path "\\*")))

;: Return a pointer to `WIN32_FIND_DATAA.cFileName`.
(cfg
  windows
  (define (fs-windows-find-data-name [data : (Array u8)]) : (Ptr u8)
    (unsafe
      (ptr-cast
        (ptr-offset (io-array-ptr data) fs-windows-find-data-name-offset)
        : (Ptr u8)))))

;: Return the Windows host status code for opening and closing a directory scan.
(cfg
  windows
  (define (fs-windows-read-dir-status [path : String]) : i64
    (let
      [pattern : String (fs-windows-read-dir-pattern path)]
      [pattern-bytes : (Array u8) (io-c-string pattern)]
      [data : (Array u8) (make-array u8 fs-windows-find-data-size)]
      [handle : i64
        (fs-win-find-first-file
          (io-array-const-ptr pattern-bytes)
          (io-array-ptr data))]
      (if (= handle -1)
        (fs-windows-nonzero-status (fs-windows-last-error-status))
        (if (= (fs-win-find-close handle) (cast 0 : i32))
          (fs-windows-nonzero-status (fs-windows-last-error-status))
          io-status-ok)))))

;: Return the newline-delimited Windows directory listing payload.
(cfg
  windows
  (define (fs-windows-read-dir [path : String]) : String
    (let
      [pattern : String (fs-windows-read-dir-pattern path)]
      [pattern-bytes : (Array u8) (io-c-string pattern)]
      [data : (Array u8) (make-array u8 fs-windows-find-data-size)]
      [out : (Array u8) (make-array u8 0)]
      [handle : i64
        (fs-win-find-first-file
          (io-array-const-ptr pattern-bytes)
          (io-array-ptr data))]
      (if (= handle -1)
        ""
        (let
          [done : bool false]
          (begin
            (while (not done)
              (begin
                (fs-read-dir-append-entry! out (fs-windows-find-data-name data))
                (if (=
                  (fs-win-find-next-file handle (io-array-ptr data))
                  (cast 0 : i32))
                  (set! done true)
                  unit)))
            (fs-win-find-close handle)
            (fs-read-dir-bytes-string out)))))))

;: Return the host status code for reading a directory listing.
(define (fs-read-dir-status [path : String]) : i64
  (cfg
    windows
    (fs-windows-read-dir-status path)
    (fs-linux-read-dir-status path)))

;: Return the newline-delimited host directory listing payload.
(define (fs-read-dir [path : String]) : String
  (cfg windows (fs-windows-read-dir path) (fs-linux-read-dir path)))

;: Status sentinel for regular files returned by `fs-file-kind-status`.
(define fs-file-kind-regular-code : i64
  -1)

;: Status sentinel for directories returned by `fs-file-kind-status`.
(define fs-file-kind-directory-code : i64
  -2)

;: Status sentinel for filesystem nodes that are neither files nor directories.
(define fs-file-kind-other-code : i64
  -3)

;: Private result tuple for a filesystem metadata probe.
(defstruct FsFileMetadataProbe
  (status i64)
  (kind i64)
  (size i64))

;: Byte size of the Windows `WIN32_FILE_ATTRIBUTE_DATA` buffer.
(define fs-windows-file-attribute-data-size : i64
  40)

;: Windows file attribute bit that marks a directory.
(define fs-windows-file-attribute-directory : i64
  16)

;: Byte offset of `dwFileAttributes` in `WIN32_FILE_ATTRIBUTE_DATA`.
(define fs-windows-file-attributes-offset : i64
  0)

;: Byte offset of `nFileSizeHigh` in `WIN32_FILE_ATTRIBUTE_DATA`.
(define fs-windows-file-size-high-offset : i64
  28)

;: Byte offset of `nFileSizeLow` in `WIN32_FILE_ATTRIBUTE_DATA`.
(define fs-windows-file-size-low-offset : i64
  32)

;: Read a `u32` field from a metadata buffer at a byte offset.
(define (fs-metadata-read-u32-at [base : (MutPtr u8)] [offset : i64]) : u32
  (unsafe
    (ptr-read (ptr-cast (ptr-offset base offset) : (Ptr u32)))))

;: Read an `i64` field from a metadata buffer at a byte offset.
(define (fs-metadata-read-i64-at [base : (MutPtr u8)] [offset : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (ptr-offset base offset) : (Ptr i64)))))

;: Linux `newfstatat(AT_FDCWD, path, statbuf, 0)` syscall.
(cfg
  (not windows)
  (define (fs-linux-syscall-newfstatat
    [path : (Ptr u8)]
    [statbuf : (MutPtr u8)]) : i64
    (io-linux-syscall-status
      (syscall
        262
        fs-linux-at-fdcwd
        (io-linux-ptr-arg path)
        (io-linux-ptr-arg
          (unsafe
            (ptr-cast statbuf : (Ptr u8))))
        0))))

(cfg
  (not windows)
  (define fs-linux-stat-buffer-size : i64
    160))

(cfg
  (not windows)
  (define fs-linux-stat-mode-offset : i64
    24))

(cfg
  (not windows)
  (define fs-linux-stat-size-offset : i64
    48))

(cfg
  (not windows)
  (define fs-linux-stat-mode-kind-mask : i64
    61440))

(cfg
  (not windows)
  (define fs-linux-stat-regular-mode : i64
    32768))

(cfg
  (not windows)
  (define fs-linux-stat-directory-mode : i64
    16384))

(cfg
  (not windows)
  (define (fs-linux-file-kind-from-mode [mode : i64]) : i64
    (let
      [kind : i64 (bit-and mode fs-linux-stat-mode-kind-mask)]
      (core/cond
        (= kind fs-linux-stat-regular-mode)
        fs-file-kind-regular-code
        (= kind fs-linux-stat-directory-mode)
        fs-file-kind-directory-code
        fs-file-kind-other-code))))

(cfg
  (not windows)
  (define (fs-linux-file-metadata-probe [path : (Ptr u8)]) : FsFileMetadataProbe
    (let
      [statbuf : (Array u8) (make-array u8 fs-linux-stat-buffer-size)]
      [statptr : (MutPtr u8) (io-array-ptr statbuf)]
      [status : i64
        (fs-status-from-result (fs-linux-syscall-newfstatat path statptr))]
      (if (= status io-status-ok)
        (let
          [kind : i64
            (fs-linux-file-kind-from-mode
              (cast
                (fs-metadata-read-u32-at statptr fs-linux-stat-mode-offset)
                : i64))]
          (FsFileMetadataProbe
            status
            kind
            (if (= kind fs-file-kind-regular-code)
              (fs-metadata-read-i64-at statptr fs-linux-stat-size-offset)
              0)))
        (FsFileMetadataProbe status status 0)))))

;: Preserve the former metadata runtime's raw fallback when Windows gives no code.
(cfg
  windows
  (define (fs-windows-metadata-error-status) : i64
    (let
      [status : i64 (fs-windows-last-error-status)]
      (if (= status io-status-ok)
        1
        status))))

(cfg
  windows
  (define (fs-windows-file-kind-from-attributes [attrs : i64]) : i64
    (if (not (= (bit-and attrs fs-windows-file-attribute-directory) 0))
      fs-file-kind-directory-code
      fs-file-kind-regular-code)))

(cfg
  windows
  (define (fs-windows-file-size-from-data [data : (MutPtr u8)]) : i64
    (let
      [high : u64
        (cast
          (fs-metadata-read-u32-at data fs-windows-file-size-high-offset)
          : u64)]
      [low : u64
        (cast
          (fs-metadata-read-u32-at data fs-windows-file-size-low-offset)
          : u64)]
      (cast (bit-or low (shl high 32)) : i64))))

(cfg
  windows
  (define (fs-windows-file-metadata-probe [path : (Ptr u8)]) : FsFileMetadataProbe
    (let
      [data : (Array u8) (make-array u8 fs-windows-file-attribute-data-size)]
      [dataptr : (MutPtr u8) (io-array-ptr data)]
      [ok : i32 (fs-win-get-file-attributes-ex path (cast 0 : i32) dataptr)]
      (if (= ok (cast 0 : i32))
        (let
          [status : i64 (fs-windows-metadata-error-status)]
          (FsFileMetadataProbe status status 0))
        (let
          [kind : i64
            (fs-windows-file-kind-from-attributes
              (cast
                (fs-metadata-read-u32-at
                  dataptr
                  fs-windows-file-attributes-offset)
                : i64))]
          (FsFileMetadataProbe
            io-status-ok
            kind
            (if (= kind fs-file-kind-regular-code)
              (fs-windows-file-size-from-data dataptr)
              0)))))))

;: Probe path metadata and return status, kind sentinel, and regular-file size.
(define (fs-file-metadata-probe [path : String]) : FsFileMetadataProbe
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [path-ptr : (Ptr u8) (io-array-const-ptr path-bytes)]
    (cfg
      windows
      (fs-windows-file-metadata-probe path-ptr)
      (fs-linux-file-metadata-probe path-ptr))))

;: Return the host status code or sentinel for a filesystem node kind.
(define (fs-file-kind-status [path : String]) : i64
  (struct-get (fs-file-metadata-probe path) kind))

;: Return the host status code for retrieving a regular-file size.
(define (fs-file-size-status [path : String]) : i64
  (struct-get (fs-file-metadata-probe path) status))

;: Return the host-reported byte size for a regular file.
(define (fs-file-size [path : String]) : i64
  (struct-get (fs-file-metadata-probe path) size))

;: Linux `ERANGE` status returned when the current-dir buffer is too small.
(define fs-status-range : i64
  34)

;: Initial current-directory FFI buffer size including the trailing NUL.
(define fs-current-dir-initial-capacity : i64
  256)

;: Maximum current-directory buffer size attempted by the bounded grow loop.
(define fs-current-dir-max-capacity : i64
  32768)

;: Grow the current-directory buffer, honoring an explicit platform request.
(define (fs-current-dir-next-capacity [capacity : i64] [requested : i64]) : i64
  (if (> requested capacity)
    requested
    (* capacity 2)))

;: Probe the current directory with a platform-specific bounded grow loop.
(define (fs-current-dir-status-loop [capacity : i64]) : i64
  (cfg
    windows
    (if (> capacity fs-current-dir-max-capacity)
      io-status-name-too-long
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [written : i64
          (cast
            (fs-windows-get-current-directory
              (cast capacity : u32)
              (io-array-ptr buf))
            : i64)]
        (core/cond
          (= written 0)
          io-status-io-error
          (< written capacity)
          io-status-ok
          (fs-current-dir-status-loop
            (fs-current-dir-next-capacity capacity written)))))
    (if (> capacity fs-current-dir-max-capacity)
      io-status-name-too-long
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [result : (Ptr u8)
          (fs-linux-syscall-getcwd (io-array-ptr buf) capacity)]
        (if (ptr-null? result)
          (let
            [status : i64 (io-last-error-code)]
            (if (= status fs-status-range)
              (if (< capacity fs-current-dir-max-capacity)
                (fs-current-dir-status-loop (* capacity 2))
                io-status-name-too-long)
              status))
          io-status-ok)))))

;: Read the current directory into an owned String.
(define (fs-current-dir-loop [capacity : i64]) : String
  (cfg
    windows
    (if (> capacity fs-current-dir-max-capacity)
      ""
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [written : i64
          (cast
            (fs-windows-get-current-directory
              (cast capacity : u32)
              (io-array-ptr buf))
            : i64)]
        (core/cond
          (= written 0)
          ""
          (< written capacity)
          (io-copy-c-string (io-array-const-ptr buf))
          (fs-current-dir-loop (fs-current-dir-next-capacity capacity written)))))
    (if (> capacity fs-current-dir-max-capacity)
      ""
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [result : (Ptr u8)
          (fs-linux-syscall-getcwd (io-array-ptr buf) capacity)]
        (if (ptr-null? result)
          (let
            [status : i64 (io-last-error-code)]
            (if (and
              (= status fs-status-range)
              (< capacity fs-current-dir-max-capacity))
              (fs-current-dir-loop (* capacity 2))
              ""))
          (io-copy-c-string result))))))

;: Return the host status code for retrieving the current working directory.
(define (fs-current-dir-status) : i64
  (fs-current-dir-status-loop fs-current-dir-initial-capacity))

;: Return the process current directory as an owned String.
(define (fs-current-dir) : String
  (fs-current-dir-loop fs-current-dir-initial-capacity))

;: Common host status code for attempting to create an already-existing path.
(define fs-status-already-exists : i64
  17)

;: Maximum collision retries for `try-create-temp-dir`.
(define fs-temp-attempt-limit : i64
  100)

;: Reversed path segment stack used by lexical path normalization.
(defenum FsPathSegmentList
  (FsPathSegmentNil)
  (FsPathSegmentCons String (Box FsPathSegmentList)))

;: Portable coarse filesystem node kind.
(defenum FsFileKind
  (FsFileRegular)
  (FsFileDirectory)
  (FsFileOther))

;: Minimal filesystem metadata. `size` is the byte length for regular files.
(defstruct FsMetadata
  (kind FsFileKind)
  (size i64))

;: Result type for file-kind probes.
(defenum ResultFsFileKind
  (OkFsFileKind FsFileKind)
  (ErrFsFileKind IoError))

;: Result type for filesystem metadata probes.
(defenum ResultFsMetadata
  (OkFsMetadata FsMetadata)
  (ErrFsMetadata IoError))

;: Return true on Windows-style hosts.
(define (fs-windows?) : bool
  (string-eq (env-path-list-separator) ";"))

;: Return the preferred path separator for the current host.
(define (fs-path-separator) : String
  (if (fs-windows?)
    "\\"
    "/"))

;: Return the preferred path separator as a character.
(define (fs-path-separator-char) : char
  (if (fs-windows?)
    #\\'
    #/'))

;: Return true when `c` is either Unix or Windows path separator syntax.
(define (fs-path-separator? [c : char]) : bool
  (or (char-eq c #/') (char-eq c #\\')))

;: Return true when `path` starts with either supported separator character.
(define (fs-path-starts-separator? [path : (& path str)]) : bool
  (and (> (string-length path) 0) (fs-path-separator? (string-ref path 0))))

;: Return true when `path` ends with either supported separator character.
(define (fs-path-ends-separator? [path : (& path str)]) : bool
  (let
    [n : i64 (string-length path)]
    (and (> n 0) (fs-path-separator? (string-ref path (- n 1))))))

;: Return true when `path` starts with a Windows drive designator like `C:`.
;:
;: `C:relative` is drive-qualified but not absolute. `fs-path-safe-relative?`
;: rejects drive-qualified strings because they are not portable root suffixes.
(define (fs-path-drive-qualified? [path : (& path str)]) : bool
  (and (> (string-length path) 1) (char-eq (string-ref path 1) #:')))

;: Return true when `path` is rooted or drive-absolute.
;:
;: Both `/` and `\` count as rooted separators. Windows drive-style absolute
;: paths require a separator after the drive designator, such as `C:/tmp` or
;: `C:\tmp`; drive-relative strings like `C:tmp` return false.
(define (fs-path-absolute? [path : (& path str)]) : bool
  (let
    [n : i64 (string-length path)]
    (if (= n 0)
      false
      (if (fs-path-separator? (string-ref path 0))
        true
        (and
          (> n 2)
          (fs-path-drive-qualified? path)
          (fs-path-separator? (string-ref path 2)))))))

;: Render a reversed normalized path segment stack using `/` separators.
(define (fs-path-segment-list-render [segments : FsPathSegmentList]) : String
  (match segments
    [(FsPathSegmentNil) ""]
    [(FsPathSegmentCons head rest)
      (let
        [prefix : String (fs-path-segment-list-render (box-get rest))]
        (if (= (string-length prefix) 0)
          head
          (string-append prefix (string-append "/" head))))]))

;: Fold one lexical path segment into the normalized segment stack.
(define (fs-path-normalize-segment
  [segment : String]
  [segments : FsPathSegmentList]
  [rooted : bool]) : FsPathSegmentList
  (if (or (string-eq segment "") (string-eq segment "."))
    segments
    (if (string-eq segment "..")
      (match segments
        [(FsPathSegmentNil)
          (if rooted
            FsPathSegmentNil
            (FsPathSegmentCons segment (box segments)))]
        [(FsPathSegmentCons top rest)
          (if (string-eq top "..")
            (FsPathSegmentCons segment (box segments))
            (box-get rest))])
      (FsPathSegmentCons segment (box segments)))))

;: Lexically normalize `path` without resolving symlinks or touching the host FS.
;:
;: Both `/` and `\` are accepted as separators. Repeated separators and `.`
;: segments are removed, `..` pops a normal segment, rooted paths stay rooted,
;: and leading `..` segments are preserved for relative paths. Normalized output
;: uses `/` as its stable separator on every host; empty relative paths normalize
;: to `"."`.
(define (fs-path-normalize [path : (& path str)]) : String
  (let
    [n : i64 (string-length path)]
    [drive-root : bool
      (and
        (> n 2)
        (fs-path-drive-qualified? path)
        (fs-path-separator? (string-ref path 2)))]
    [rooted : bool
      (if drive-root
        true
        (and (> n 0) (fs-path-separator? (string-ref path 0))))]
    [i : i64
      (if drive-root
        3
        (if rooted
          1
          0))]
    [segment-start : i64 i]
    [segments : FsPathSegmentList FsPathSegmentNil]
    (begin
      (while (< i n)
        (begin
          (if (fs-path-separator? (string-ref path i))
            (begin
              (set!
                segments
                (fs-path-normalize-segment
                  (substring-borrowed path segment-start (- i segment-start))
                  segments
                  rooted))
              (set! segment-start (+ i 1)))
            (set! segment-start segment-start))
          (set! i (+ i 1))))
      (set!
        segments
        (fs-path-normalize-segment
          (substring-borrowed path segment-start (- n segment-start))
          segments
          rooted))
      (let
        [body : String (fs-path-segment-list-render segments)]
        (core/cond
          (and drive-root (= (string-length body) 0))
          (string-append (substring-borrowed path 0 2) "/")
          drive-root
          (string-append (substring-borrowed path 0 2) (string-append "/" body))
          (and rooted (= (string-length body) 0))
          "/"
          rooted
          (string-append "/" body)
          (= (string-length body) 0)
          "."
          body)))))

;: Return true when a normalized relative path still escapes via leading `..`.
(define (fs-path-normalized-escapes? [normalized : (& normalized str)]) : bool
  (let
    [n : i64 (string-length normalized)]
    [parent : String ".."]
    (if (string-eq-borrowed normalized (& parent))
      true
      (and
        (> n 2)
        (char-eq (string-ref normalized 0) #.')
        (char-eq (string-ref normalized 1) #.')
        (fs-path-separator? (string-ref normalized 2))))))

;: Return true when `path` is a non-empty relative suffix that stays below root.
;:
;: This is a lexical guard to use before joining user-controlled suffixes under
;: a trusted root. It rejects empty/`.` paths, absolute or drive-qualified paths,
;: and normalized paths whose first segment is `..`. It does not canonicalize
;: symlinks or query the filesystem.
(define (fs-path-safe-relative? [path : (& path str)]) : bool
  (if (or (fs-path-absolute? path) (fs-path-drive-qualified? path))
    false
    (let
      [normalized : String (fs-path-normalize path)]
      (and
        (not (string-eq normalized "."))
        (not (fs-path-normalized-escapes? (& normalized)))))))

;: Join `left` and `right` with exactly one host path separator when needed.
;:
;: Empty sides are returned without allocating an extra separator.
(define (fs-path-join [left : (& left str)] [right : (& right str)]) : String
  (core/cond
    (= (string-length left) 0)
    (string-copy-borrowed right)
    (= (string-length right) 0)
    (string-copy-borrowed left)
    (fs-path-separator? (string-ref left (- (string-length left) 1)))
    (if (fs-path-separator? (string-ref right 0))
      (let
        [trimmed-right : String
          (substring-borrowed right 1 (- (string-length right) 1))]
        (string-append-borrowed left (& trimmed-right)))
      (string-append-borrowed left right))
    (fs-path-separator? (string-ref right 0))
    (string-append-borrowed left right)
    (let
      [separator : String (fs-path-separator)]
      [left-with-separator : String (string-append-borrowed left (& separator))]
      (string-append-borrowed (& left-with-separator) right))))

;: Join two owned `String` path segments by delegating to `fs-path-join`.
;:
;: This helper is the fixed-arity expansion target for `fs-path-join-many`;
;: call `fs-path-join` directly when the caller already has borrowed text.
(define (fs-path-join-owned-pair [left : String] [right : String]) : String
  (fs-path-join (& left) (& right)))

;: Join zero or more owned `String` path segments by chaining pairwise joins.
;:
;: This macro is the variadic public spelling because `fs-path-join` remains the
;: two-argument borrowed function. With no segments it expands to `""`; with one
;: segment it expands to that segment unchanged.
(defmacro (fs-path-join-many [segments : String ...]) : String
  (if (expr-list-empty? segments)
    `""
    (let
      [first : Expr (expr-list-head segments)]
      [rest : ExprList (expr-list-tail segments)]
      (if (expr-list-empty? rest)
        first
        (let
          [second : Expr (expr-list-head rest)]
          [tail : ExprList (expr-list-tail rest)]
          (if (expr-list-empty? tail)
            `(fs-path-join-owned-pair ,first ,second)
            `(fs-path-join-many (fs-path-join-owned-pair ,first ,second) ,@tail)))))))

;: Index of the last path separator in `path`, or `-1` when there is none.
(define (fs-last-separator-index [path : (& path str)]) : i64
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (fs-path-separator? (string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      last)))

;: Directory portion of `path`, without a trailing separator.
;:
;: Returns `"."` when `path` has no separator, and the host separator when the
;: only separator is the leading one (a root child such as `/main.tl`).
(define (fs-dirname [path : (& path str)]) : String
  (let
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      "."
      (if (= last 0)
        (fs-path-separator)
        (substring-borrowed path 0 last)))))

;: Final component of `path` (the part after the last separator).
;:
;: Returns `path` unchanged when there is no separator, and `""` when `path`
;: ends with a separator.
(define (fs-basename [path : (& path str)]) : String
  (let
    [n : i64 (string-length path)]
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      (string-copy-borrowed path)
      (substring-borrowed path (+ last 1) (- n (+ last 1))))))

;: Extension of `path` without the leading dot (e.g. `"tl"` for `main.tl`).
;:
;: Operates on the basename, so directory dots do not count. Returns `""` when
;: the basename has no dot or is a dotfile (a leading-dot name like
;: `.gitignore`, which has no extension).
(define (fs-extension [path : (& path str)]) : String
  (let
    [base : String (fs-basename path)]
    [bn : i64 (string-length base)]
    [i : i64 0]
    [dot : i64 -1]
    (begin
      (while (< i bn)
        (begin
          (if (char-eq (string-ref base i) #.')
            (set! dot i)
            (set! dot dot))
          (set! i (+ i 1))))
      (if (<= dot 0)
        ""
        (substring base (+ dot 1) (- bn (+ dot 1)))))))

;: Convert a runtime filesystem status into a structured `ResultIoUnit`.
(define (fs-status-result [path : (& path str)] [status : i64]) : ResultIoUnit
  (if (= status io-status-ok)
    OkIoUnit
    (ErrIoUnit (io-error-from-status path status))))

;: Convert a runtime file-kind status into a structured result.
(define (fs-file-kind-status-result [path : (& path str)] [status : i64]) : ResultFsFileKind
  (core/cond
    (= status fs-file-kind-regular-code)
    (OkFsFileKind (FsFileRegular))
    (= status fs-file-kind-directory-code)
    (OkFsFileKind (FsFileDirectory))
    (= status fs-file-kind-other-code)
    (OkFsFileKind (FsFileOther))
    (ErrFsFileKind (io-error-from-status path status))))

;: Create `path` as a directory, returning a structured status.
;:
;: Linux uses mode `0700`; Windows uses the CRT `_mkdir` function.
(define (try-mkdir [path : (& path str)]) : ResultIoUnit
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoUnit (io-invalid-path-error path))
      (fs-status-result path (fs-mkdir-status-owned path-text)))))

;: Create `path` as a directory when it is missing.
;:
;: A pre-existing path reported by the host as already-created is accepted.
(define (try-mkdir-if-missing [path : (& path str)]) : ResultIoUnit
  (match (try-mkdir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (match error
        [(IoSystemCode code _)
          (if (= code fs-status-already-exists)
            OkIoUnit
            (ErrIoUnit error))]
        [_ (ErrIoUnit error)])]))

;: Remove a file path, returning a structured status.
(define (try-remove-file [path : (& path str)]) : ResultIoUnit
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoUnit (io-invalid-path-error path))
      (fs-status-result path (fs-remove-file-status-owned path-text)))))

;: Remove an empty directory path, returning a structured status.
(define (try-remove-dir [path : (& path str)]) : ResultIoUnit
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoUnit (io-invalid-path-error path))
      (fs-status-result path (fs-remove-dir-status-owned path-text)))))

;: Rename `source` to `destination`, returning a structured status.
;:
;: Host replacement behavior is target-defined: Linux follows `rename(2)`;
;: Windows follows the CRT rename policy.
(define (try-rename
  [source : (& source str)]
  [destination : (& destination str)]) : ResultIoUnit
  (if (= (string-length source) 0)
    (ErrIoUnit (IoInvalidPath (string-copy-borrowed source)))
    (if (= (string-length destination) 0)
      (ErrIoUnit (IoInvalidPath (string-copy-borrowed destination)))
      (let
        [source-text : String (string-copy-borrowed source)]
        [destination-text : String (string-copy-borrowed destination)]
        [arrow : String " -> "]
        [source-arrow : String (string-append-borrowed source (& arrow))]
        [path : String (string-append-borrowed (& source-arrow) destination)]
        [status : i64 (fs-rename-status-owned source-text destination-text)]
        (if (= status io-status-ok)
          OkIoUnit
          (ErrIoUnit (io-error-from-owned-status path status)))))))

;: Probe the coarse filesystem kind of `path`.
;:
;: Linux and Windows report regular files, directories, and other node kinds.
(define (try-file-kind [path : (& path str)]) : ResultFsFileKind
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrFsFileKind (io-invalid-path-error path))
      (fs-file-kind-status-result path (fs-file-kind-status path-text)))))

;: Return true when `kind` is `FsFileRegular`.
(define (fs-file-kind-regular? [kind : FsFileKind]) : bool
  (match kind
    [(FsFileRegular) true]
    [_ false]))

;: Return true when `kind` is `FsFileDirectory`.
(define (fs-file-kind-directory? [kind : FsFileKind]) : bool
  (match kind
    [(FsFileDirectory) true]
    [_ false]))

;: Return true when `kind` is `FsFileOther`.
(define (fs-file-kind-other? [kind : FsFileKind]) : bool
  (match kind
    [(FsFileOther) true]
    [_ false]))

;: Return the node kind stored in `metadata`.
(define (fs-metadata-kind [metadata : FsMetadata]) : FsFileKind
  (struct-get metadata kind))

;: Return the regular-file byte size stored in `metadata`.
(define (fs-metadata-size [metadata : FsMetadata]) : i64
  (struct-get metadata size))

;: Probe minimal metadata for `path`.
;:
;: Linux and Windows report the coarse kind and, for regular files, byte size
;: through the runtime metadata helper. Directory and other node sizes are
;: reported as zero.
(define (try-file-metadata [path : (& path str)]) : ResultFsMetadata
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrFsMetadata (io-invalid-path-error path))
      (match (try-file-kind path)
        [(ErrFsFileKind error) (ErrFsMetadata error)]
        [(OkFsFileKind kind)
          (if (fs-file-kind-regular? kind)
            (let
              [status : i64 (fs-file-size-status path-text)]
              (if (= status io-status-ok)
                (OkFsMetadata (FsMetadata kind (fs-file-size path-text)))
                (ErrFsMetadata (io-error-from-status path status))))
            (OkFsMetadata (FsMetadata kind 0)))]))))

;: Split the runtime's newline-delimited directory payload into entry names.
(define (fs-read-dir-split [entries : String]) : StringList
  (let
    [n : i64 (string-length entries)]
    [items : StringList (StringNil)]
    [start : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (if (char-eq (string-ref entries i) #\newline')
          (begin
            (if (> i start)
              (set!
                items
                (string-list-cons (substring entries start (- i start)) items))
              unit)
            (set! start (+ i 1))
            (set! i (+ i 1)))
          (set! i (+ i 1))))
      (if (< start n)
        (string-list-reverse
          (string-list-cons (substring entries start (- n start)) items))
        (string-list-reverse items)))))

;: Read one directory and return entry names as a `StringList`.
;:
;: Entries are names only, not joined paths. The runtime filters `.` and `..`.
;: Host directory order is preserved and not guaranteed to be stable; callers
;: that need stable ordering should sort the returned list. The returned list
;: spine and entry strings allocate in the active arena.
(define (try-read-dir [path : (& path str)]) : ResultIoStringList
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoStringList (io-invalid-path-error path))
      (let
        [status : i64 (fs-read-dir-status path-text)]
        (if (= status io-status-ok)
          (OkIoStringList (fs-read-dir-split (fs-read-dir path-text)))
          (ErrIoStringList (io-error-from-status path status)))))))

;: Remove a file if present. Missing paths are considered already cleaned.
(define (try-remove-file-if-exists [path : (& path str)]) : ResultIoUnit
  (match (try-remove-file path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;: Remove an empty directory if present. Missing paths are considered cleaned.
(define (try-remove-dir-if-exists [path : (& path str)]) : ResultIoUnit
  (match (try-remove-dir path)
    [(OkIoUnit) OkIoUnit]
    [(ErrIoUnit error)
      (if (io-error-not-found? error)
        OkIoUnit
        (ErrIoUnit error))]))

;: Return the host temporary root used by `try-create-temp-dir`.
(define (fs-temp-root) : String
  (if (fs-windows?)
    (let
      [name : String "TEMP"]
      (match (env-get (& name))
        [(EnvSomeString value) value]
        [(EnvNoString)
          (let
            [name : String "TMP"]
            (match (env-get (& name))
              [(EnvSomeString value) value]
              [(EnvNoString) "."]))]))
    (let
      [name : String "TMPDIR"]
      (match (env-get (& name))
        [(EnvSomeString value) value]
        [(EnvNoString) "/tmp"]))))

;: Return the process current directory as an owned active-arena String.
;:
;: The returned path is the host-reported cwd; it is not symlink-canonicalized.
;: Host lookup failures return `ErrIoString` with the mapped status.
(define (try-current-dir) : ResultIoString
  (let
    [status : i64 (fs-current-dir-status)]
    (if (= status io-status-ok)
      (OkIoString (fs-current-dir))
      (ErrIoString (io-error-from-label "current directory" status)))))

;: Compose one candidate temporary directory basename from prefix, pid, and attempt.
(define (fs-temp-name [prefix : (& prefix str)] [pid : i64] [attempt : i64]) : String
  (let
    [dash : String "-"]
    [prefix-dash : String (string-append-borrowed prefix (& dash))]
    [pid-text : String (int->string pid)]
    [attempt-text : String (int->string attempt)]
    [pid-dash : String (string-append pid-text dash)]
    (string-append prefix-dash (string-append pid-dash attempt-text))))

;: Retry temporary directory creation until an unused candidate is found.
(define (fs-create-temp-dir-loop
  [root : (& root str)]
  [prefix : (& prefix str)]
  [pid : i64]
  [attempt : i64]) : ResultIoString
  (if (>= attempt fs-temp-attempt-limit)
    (ErrIoString
      (IoSystemCode fs-status-already-exists (string-copy-borrowed prefix)))
    (let
      [name : String (fs-temp-name prefix pid attempt)]
      [path : String
        (core/cond
          (= (string-length root) 0)
          name
          (= (string-length name) 0)
          (string-copy-borrowed root)
          (fs-path-separator? (string-ref root (- (string-length root) 1)))
          (if (fs-path-separator? (string-ref name 0))
            (let
              [trimmed-name : String
                (substring-borrowed (& name) 1 (- (string-length name) 1))]
              (string-append-borrowed root (& trimmed-name)))
            (string-append-borrowed root (& name)))
          (fs-path-separator? (string-ref name 0))
          (string-append-borrowed root (& name))
          (let
            [separator : String (fs-path-separator)]
            [root-with-separator : String
              (string-append-borrowed root (& separator))]
            (string-append root-with-separator name)))]
      [status : i64 (fs-mkdir-status-owned path)]
      (if (= status io-status-ok)
        (OkIoString path)
        (if (= status fs-status-already-exists)
          (fs-create-temp-dir-loop root prefix pid (+ attempt 1))
          (ErrIoString (io-error-from-owned-status path status)))))))

;: Create a unique temporary directory for tool artifacts.
;:
;: The directory is created below `$TMPDIR` on Linux (or `/tmp` when `TMPDIR` is
;: missing), and below `%TEMP%`/`%TMP%` (or `.`) on Windows. The unique name is
;: seeded by the process id (`GetCurrentProcessId` on Windows, `getpid` on
;: Linux) and an attempt counter, retrying on collision.
(define (try-create-temp-dir [prefix : (& prefix str)]) : ResultIoString
  (if (= (string-length prefix) 0)
    (ErrIoString (IoInvalidPath (string-copy-borrowed prefix)))
    (let
      [root : String (fs-temp-root)]
      (fs-create-temp-dir-loop (& root) prefix (fs-process-id) 0))))