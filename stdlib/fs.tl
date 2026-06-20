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
;# Usage: `(import stdlib.fs)`
;#
;# ```typelisp
;# (import stdlib.fs)
;# (define joined : String
;#   (let
;#     [left : String "target"]
;#     [right : String "tool-output.s"]
;#     (fs.fs-path-join (& left) (& right))))
;# ```
(module stdlib.fs)

(import stdlib.env)
(import stdlib.io)
(import stdlib.list)
(import stdlib.string)
(import stdlib.vector)

;: Result type for directory-listing APIs.
(defenum ResultIoStringList
  (OkIoStringList list.StringList)
  (ErrIoStringList io.IoError))

;: Result type for vector-backed directory-listing APIs.
(defenum ResultIoStringVec
  (OkIoStringVec vector.StringVec)
  (ErrIoStringVec io.IoError))

;: Linux `mkdir` via the `mkdir` syscall (number 83).
(define (fs-linux-syscall-mkdir [path : (Ptr u8)] [mode : i64]) : i64
  (io.io-linux-syscall-status
    (unsafe
      (syscall 83 (io.io-linux-ptr-arg path) mode))))

;: Linux `unlink` via the `unlink` syscall (number 87).
(define (fs-linux-syscall-unlink [path : (Ptr u8)]) : i64
  (io.io-linux-syscall-status
    (unsafe
      (syscall 87 (io.io-linux-ptr-arg path)))))

;: Linux `rmdir` via the `rmdir` syscall (number 84).
(define (fs-linux-syscall-rmdir [path : (Ptr u8)]) : i64
  (io.io-linux-syscall-status
    (unsafe
      (syscall 84 (io.io-linux-ptr-arg path)))))

;: Linux `rename` via the `rename` syscall (number 82).
(define (fs-linux-syscall-rename [source : (Ptr u8)] [destination : (Ptr u8)]) : i64
  (io.io-linux-syscall-status
    (unsafe
      (syscall
        82
        (io.io-linux-ptr-arg source)
        (io.io-linux-ptr-arg destination)))))

;: Linux `getpid` via the `getpid` syscall (number 39); never fails.
(define (fs-linux-syscall-getpid) : i64
  (unsafe
    (syscall 39)))

;: Linux `getcwd` via the `getcwd` syscall (number 79).
;: Returns the buffer pointer on success or a null pointer on error, matching
;: the C `getcwd` contract the callers expect.
(define (fs-linux-syscall-getcwd [buf : (MutPtr u8)] [size : i64]) : (Ptr u8)
  (let
    [ptr : i64
      (io.io-linux-ptr-arg
        (unsafe
          (ptr-cast buf : (Ptr u8))))]
    [result : i64
      (io.io-linux-syscall-status
        (unsafe
          (syscall 79 ptr size)))]
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
  (io.io-linux-syscall-status
    (unsafe
      (syscall 257 dirfd (io.io-linux-ptr-arg path) flags mode))))

;: Linux `getdents64` syscall (number 217), returning bytes read or -1.
(define (fs-linux-syscall-getdents64
  [fd : i64]
  [buf : (MutPtr u8)]
  [count : i64]) : i64
  (io.io-linux-syscall-status
    (unsafe
      (syscall
        217
        fd
        (io.io-linux-ptr-arg
          (unsafe
            (ptr-cast buf : (Ptr u8))))
        count))))

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
        (io.io-set-error-code
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
        (io.io-set-error-code 2)
        (cast -1 : i32))
      (cast 0 : i32))))

;: Windows `_rmdir` replacement via RemoveDirectoryA.
(cfg
  windows
  (define (fs-windows-rmdir [path : (Ptr u8)]) : i32
    (if (= (fs-win-remove-directory path) (cast 0 : i32))
      (begin
        (io.io-set-error-code 2)
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
        (io.io-set-error-code 2)
        (cast -1 : i32))
      (cast 0 : i32))))

;: Convert a zero-success C result into the current host error code.
(define (fs-status-from-result [result : i64]) : i64
  (if (= result 0)
    0
    (io.io-last-error-code)))

;: Create an owned path string as a directory and return a host status code.
(define (fs-mkdir-status-owned [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io.io-c-string path)]
    [path-ptr : (Ptr u8) (io.io-array-const-ptr path-bytes)]
    (fs-status-from-result
      (cfg
        windows
        (cast (fs-windows-mkdir path-ptr) : i64)
        (fs-linux-syscall-mkdir path-ptr 448)))))

;: Return the host status code for creating a directory.
(define (fs-mkdir-status [path : (& path str)]) : i64
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (fs-mkdir-status-owned path-text)))

;: Remove an owned path string as a file and return a host status code.
(define (fs-remove-file-status-owned [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io.io-c-string path)]
    [path-ptr : (Ptr u8) (io.io-array-const-ptr path-bytes)]
    (fs-status-from-result
      (cfg
        windows
        (cast (fs-windows-unlink path-ptr) : i64)
        (fs-linux-syscall-unlink path-ptr)))))

;: Return the host status code for removing a file.
(define (fs-remove-file-status [path : (& path str)]) : i64
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (fs-remove-file-status-owned path-text)))

;: Remove an owned path string as an empty directory and return a host status code.
(define (fs-remove-dir-status-owned [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io.io-c-string path)]
    [path-ptr : (Ptr u8) (io.io-array-const-ptr path-bytes)]
    (fs-status-from-result
      (cfg
        windows
        (cast (fs-windows-rmdir path-ptr) : i64)
        (fs-linux-syscall-rmdir path-ptr)))))

;: Return the host status code for removing an empty directory.
(define (fs-remove-dir-status [path : (& path str)]) : i64
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (fs-remove-dir-status-owned path-text)))

;: Rename owned source and destination path strings and return a host status code.
(define (fs-rename-status-owned [source : String] [destination : String]) : i64
  (let
    [source-bytes : (Array u8) (io.io-c-string source)]
    [destination-bytes : (Array u8) (io.io-c-string destination)]
    (fs-status-from-result
      (cfg
        windows
        (cast
          (fs-windows-rename
            (io.io-array-const-ptr source-bytes)
            (io.io-array-const-ptr destination-bytes))
          : i64)
        (fs-linux-syscall-rename
          (io.io-array-const-ptr source-bytes)
          (io.io-array-const-ptr destination-bytes))))))

;: Return the host status code for renaming a path.
(define (fs-rename-status
  [source : (& source str)]
  [destination : (& destination str)]) : i64
  (let
    [source-text : String (string.string-copy-borrowed source)]
    [destination-text : String (string.string-copy-borrowed destination)]
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
  (if (!= (stdlib.fs.fs-c-string-byte name 0) 46)
    false
    (let
      [second : i64 (stdlib.fs.fs-c-string-byte name 1)]
      (if (= second 0)
        true
        (if (= second 46)
          (= (stdlib.fs.fs-c-string-byte name 2) 0)
          false)))))

;: Append one non-dot entry name plus a newline to `out`.
(define (fs-read-dir-append-entry! [out : (Array u8)] [name : (Ptr u8)]) : unit
  (if (stdlib.fs.fs-read-dir-dot-entry? name)
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
        (array-push! out (cast '\n' : u8))))))

;: Convert the accumulated newline-delimited bytes into a String.
(define (fs-read-dir-bytes-string [out : (Array u8)]) : String
  (unsafe
    (string-from-bytes (io.io-array-const-ptr out) (array-length out))))

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
      [path-bytes : (Array u8) (io.io-c-string path)]
      (fs-linux-syscall-openat
        fs-linux-at-fdcwd
        (io.io-array-const-ptr path-bytes)
        fs-linux-open-directory
        0))))

;: Return the Linux host status code for opening and closing a directory.
(cfg
  (not windows)
  (define (fs-linux-read-dir-status [path : String]) : i64
    (let
      [fd : i64 (fs-linux-open-dir-owned path)]
      (if (< fd 0)
        (io.io-last-error-code)
        (fs-status-from-result (io.io-linux-syscall-close fd))))))

;: Append entries from one Linux getdents64 buffer page.
(cfg
  (not windows)
  (define (fs-linux-read-dir-append-page!
    [buf : (Array u8)]
    [read-count : i64]
    [out : (Array u8)]) : unit
    (let
      [base : (Ptr u8) (io.io-array-const-ptr buf)]
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
                    (io.io-array-ptr buf)
                    fs-read-dir-buffer-size)]
                (if (< read-count 0)
                  (begin
                    (set! ok false)
                    (set! done true))
                  (if (= read-count 0)
                    (set! done true)
                    (fs-linux-read-dir-append-page! buf read-count out)))))
            (io.io-linux-syscall-close fd)
            (if ok
              (fs-read-dir-bytes-string out)
              "")))))))

;: Map Windows `GetLastError` values to errno-style stdlib statuses.
(cfg
  windows
  (define (fs-windows-last-error-status) : i64
    (let
      [code : i64 (cast (fs-win-get-last-error) : i64)]
      (if (= code 2)
        io.io-status-not-found
        (if (= code 3)
          io.io-status-not-directory
          (if (= code 5)
            io.io-status-permission-denied
            (if (= code 87)
              io.io-status-invalid
              (if (= code 123)
                io.io-status-invalid
                (if (= code 161)
                  io.io-status-invalid
                  (if (= code 206)
                    io.io-status-name-too-long
                    (if (= code 267)
                      io.io-status-not-directory
                      code)))))))))))

;: Return an I/O error status when Windows reported no concrete code.
(cfg
  windows
  (define (fs-windows-nonzero-status [status : i64]) : i64
    (if (= status io.io-status-ok)
      io.io-status-io-error
      status)))

;: Build the `path\*` search pattern expected by FindFirstFileA.
(cfg
  windows
  (define (fs-windows-read-dir-pattern [path : String]) : String
    (string.string-append path "\\*")))

;: Return a pointer to `WIN32_FIND_DATAA.cFileName`.
(cfg
  windows
  (define (fs-windows-find-data-name [data : (Array u8)]) : (Ptr u8)
    (unsafe
      (ptr-cast
        (ptr-offset (io.io-array-ptr data) fs-windows-find-data-name-offset)
        : (Ptr u8)))))

;: Return the Windows host status code for opening and closing a directory scan.
(cfg
  windows
  (define (fs-windows-read-dir-status [path : String]) : i64
    (let
      [pattern : String (fs-windows-read-dir-pattern path)]
      [pattern-bytes : (Array u8) (io.io-c-string pattern)]
      [data : (Array u8) (make-array u8 fs-windows-find-data-size)]
      [handle : i64
        (fs-win-find-first-file
          (io.io-array-const-ptr pattern-bytes)
          (io.io-array-ptr data))]
      (if (= handle -1)
        (fs-windows-nonzero-status (fs-windows-last-error-status))
        (if (= (fs-win-find-close handle) (cast 0 : i32))
          (fs-windows-nonzero-status (fs-windows-last-error-status))
          io.io-status-ok)))))

;: Return the newline-delimited Windows directory listing payload.
(cfg
  windows
  (define (fs-windows-read-dir [path : String]) : String
    (let
      [pattern : String (fs-windows-read-dir-pattern path)]
      [pattern-bytes : (Array u8) (io.io-c-string pattern)]
      [data : (Array u8) (make-array u8 fs-windows-find-data-size)]
      [out : (Array u8) (make-array u8 0)]
      [handle : i64
        (fs-win-find-first-file
          (io.io-array-const-ptr pattern-bytes)
          (io.io-array-ptr data))]
      (if (= handle -1)
        ""
        (let
          [done : bool false]
          (begin
            (while (not done)
              (begin
                (fs-read-dir-append-entry! out (fs-windows-find-data-name data))
                (if (=
                  (fs-win-find-next-file handle (io.io-array-ptr data))
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
    (io.io-linux-syscall-status
      (unsafe
        (syscall
          262
          fs-linux-at-fdcwd
          (io.io-linux-ptr-arg path)
          (io.io-linux-ptr-arg
            (unsafe
              (ptr-cast statbuf : (Ptr u8))))
          0)))))

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
      (if (= kind fs-linux-stat-regular-mode)
        fs-file-kind-regular-code
        (if (= kind fs-linux-stat-directory-mode)
          fs-file-kind-directory-code
          fs-file-kind-other-code)))))

(cfg
  (not windows)
  (define (fs-linux-file-metadata-probe [path : (Ptr u8)]) : FsFileMetadataProbe
    (let
      [statbuf : (Array u8) (make-array u8 fs-linux-stat-buffer-size)]
      [statptr : (MutPtr u8) (io.io-array-ptr statbuf)]
      [status : i64
        (fs-status-from-result (fs-linux-syscall-newfstatat path statptr))]
      (if (= status io.io-status-ok)
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
      (if (= status io.io-status-ok)
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
      [dataptr : (MutPtr u8) (io.io-array-ptr data)]
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
            io.io-status-ok
            kind
            (if (= kind fs-file-kind-regular-code)
              (fs-windows-file-size-from-data dataptr)
              0)))))))

;: Probe path metadata and return status, kind sentinel, and regular-file size.
(define (fs-file-metadata-probe [path : String]) : FsFileMetadataProbe
  (let
    [path-bytes : (Array u8) (io.io-c-string path)]
    [path-ptr : (Ptr u8) (io.io-array-const-ptr path-bytes)]
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
    (if (> capacity stdlib.fs.fs-current-dir-max-capacity)
      io.io-status-name-too-long
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [written : i64
          (cast
            (stdlib.fs.fs-windows-get-current-directory
              (cast capacity : u32)
              (io.io-array-ptr buf))
            : i64)]
        (if (= written 0)
          io.io-status-io-error
          (if (< written capacity)
            io.io-status-ok
            (stdlib.fs.fs-current-dir-status-loop
              (stdlib.fs.fs-current-dir-next-capacity capacity written))))))
    (if (> capacity stdlib.fs.fs-current-dir-max-capacity)
      io.io-status-name-too-long
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [result : (Ptr u8)
          (stdlib.fs.fs-linux-syscall-getcwd (io.io-array-ptr buf) capacity)]
        (if (ptr-null? result)
          (let
            [status : i64 (io.io-last-error-code)]
            (if (= status stdlib.fs.fs-status-range)
              (if (< capacity stdlib.fs.fs-current-dir-max-capacity)
                (stdlib.fs.fs-current-dir-status-loop (* capacity 2))
                io.io-status-name-too-long)
              status))
          io.io-status-ok)))))

;: Read the current directory into an owned String.
(define (fs-current-dir-loop [capacity : i64]) : String
  (cfg
    windows
    (if (> capacity stdlib.fs.fs-current-dir-max-capacity)
      ""
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [written : i64
          (cast
            (stdlib.fs.fs-windows-get-current-directory
              (cast capacity : u32)
              (io.io-array-ptr buf))
            : i64)]
        (if (= written 0)
          ""
          (if (< written capacity)
            (io.io-copy-c-string (io.io-array-const-ptr buf))
            (stdlib.fs.fs-current-dir-loop
              (stdlib.fs.fs-current-dir-next-capacity capacity written))))))
    (if (> capacity stdlib.fs.fs-current-dir-max-capacity)
      ""
      (let
        [buf : (Array u8) (make-array u8 capacity)]
        [result : (Ptr u8)
          (stdlib.fs.fs-linux-syscall-getcwd (io.io-array-ptr buf) capacity)]
        (if (ptr-null? result)
          (let
            [status : i64 (io.io-last-error-code)]
            (if (= status stdlib.fs.fs-status-range)
              (if (< capacity stdlib.fs.fs-current-dir-max-capacity)
                (stdlib.fs.fs-current-dir-loop (* capacity 2))
                "")
              ""))
          (io.io-copy-c-string result))))))

;: Return the host status code for retrieving the current working directory.
(define (fs-current-dir-status) : i64
  (stdlib.fs.fs-current-dir-status-loop
    stdlib.fs.fs-current-dir-initial-capacity))

;: Return the process current directory as an owned String.
(define (fs-current-dir) : String
  (stdlib.fs.fs-current-dir-loop stdlib.fs.fs-current-dir-initial-capacity))

;: Common host status code for attempting to create an already-existing path.
(define fs-status-already-exists : i64
  17)

;: Maximum collision retries for `try-create-temp-dir`.
(define fs-temp-attempt-limit : i64
  100)

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
  (ErrFsFileKind io.IoError))

;: Result type for filesystem metadata probes.
(defenum ResultFsMetadata
  (OkFsMetadata FsMetadata)
  (ErrFsMetadata io.IoError))

;: Return true on Windows-style hosts.
(define (fs-windows?) : bool
  (string.string-eq (env.env-path-list-separator) ";"))

;: Return the preferred path separator for the current host.
(define (fs-path-separator) : String
  (if (stdlib.fs.fs-windows?)
    "\\"
    "/"))

;: Return the preferred path separator as a character.
(define (fs-path-separator-char) : char
  (if (stdlib.fs.fs-windows?)
    '\\'
    '/'))

;: Return true when `c` is either Unix or Windows path separator syntax.
(define (fs-path-separator? [c : char]) : bool
  (if (string.char-eq c '/')
    true
    (string.char-eq c '\\')))

;: Return true when `path` starts with either supported separator character.
(define (fs-path-starts-separator? [path : (& path str)]) : bool
  (if (> (string-length path) 0)
    (stdlib.fs.fs-path-separator? (string-ref path 0))
    false))

;: Return true when `path` ends with either supported separator character.
(define (fs-path-ends-separator? [path : (& path str)]) : bool
  (let
    [n : i64 (string-length path)]
    (if (> n 0)
      (stdlib.fs.fs-path-separator? (string-ref path (- n 1)))
      false)))

;: Return true when `path` starts with a Windows drive designator like `C:`.
;:
;: `C:relative` is drive-qualified but not absolute. `fs-path-safe-relative?`
;: rejects drive-qualified strings because they are not portable root suffixes.
(define (fs-path-drive-qualified? [path : (& path str)]) : bool
  (if (> (string-length path) 1)
    (string.char-eq (string-ref path 1) ':')
    false))

;: Return true when `path` is rooted or drive-absolute.
;:
;: Both `/` and `\` count as rooted separators. Windows drive-style absolute
;: paths require a separator after the drive designator, such as `C:/tmp` or
;: `C:\tmp`; drive-relative strings like `C:tmp` return false.
(define (fs-path-absolute? [path : (& path str)]) : bool
  (let
    [n : i64 (string-length path)]
    (cond
      [(= n 0) false]
      [(stdlib.fs.fs-path-separator? (string-ref path 0)) true]
      [(> n 2)
        (and
          (stdlib.fs.fs-path-drive-qualified? path)
          (stdlib.fs.fs-path-separator? (string-ref path 2)))]
      [else false])))

;: Render normalized path segments using `/` separators.
(define (fs-path-segment-vec-render-from
  [segments : vector.StringVec]
  [index : i64]
  [prefix : String]) : String
  (if (>= index (vector.string-vec-len segments))
    prefix
    (let
      [segment : String (vector.string-vec-get segments index "")]
      [next-prefix : String
        (if (= (string-length prefix) 0)
          segment
          (string.string-append prefix (string.string-append "/" segment)))]
      (stdlib.fs.fs-path-segment-vec-render-from
        segments
        (+ index 1)
        next-prefix))))

;: Render normalized path segments using `/` separators.
(define (fs-path-segment-vec-render [segments : vector.StringVec]) : String
  (stdlib.fs.fs-path-segment-vec-render-from segments 0 ""))

;: Fold one lexical path segment into the normalized segment stack.
(define (fs-path-normalize-segment
  [segment : String]
  [segments : vector.StringVec]
  [rooted : bool]) : vector.StringVec
  (cond
    [(string.string-eq segment "") segments]
    [(string.string-eq segment ".") segments]
    [(not (string.string-eq segment ".."))
      (vector.string-vec-push segments segment)]
    [(<= (vector.string-vec-len segments) 0)
      (if rooted
        segments
        (vector.string-vec-push segments segment))]
    [else
      (let
        [top : String (vector.string-vec-last segments "")]
        (if (string.string-eq top "..")
          (vector.string-vec-push segments segment)
          (vector.string-vec-pop-rest-or
            (vector.string-vec-pop segments)
            segments)))]))

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
      (if (> n 2)
        (if (stdlib.fs.fs-path-drive-qualified? path)
          (stdlib.fs.fs-path-separator? (string-ref path 2))
          false)
        false)]
    [rooted : bool
      (if drive-root
        true
        (if (> n 0)
          (stdlib.fs.fs-path-separator? (string-ref path 0))
          false))]
    [i : i64
      (if drive-root
        3
        (if rooted
          1
          0))]
    [segment-start : i64 i]
    [segments : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< i n)
        (begin
          (if (stdlib.fs.fs-path-separator? (string-ref path i))
            (begin
              (set!
                segments
                (stdlib.fs.fs-path-normalize-segment
                  (string.substring-borrowed
                    path
                    segment-start
                    (- i segment-start))
                  segments
                  rooted))
              (set! segment-start (+ i 1)))
            (set! segment-start segment-start))
          (set! i (+ i 1))))
      (set!
        segments
        (stdlib.fs.fs-path-normalize-segment
          (string.substring-borrowed path segment-start (- n segment-start))
          segments
          rooted))
      (let
        [body : String (stdlib.fs.fs-path-segment-vec-render segments)]
        (cond
          [(if drive-root
              (= (string-length body) 0)
              false)
            (string.string-append (string.substring-borrowed path 0 2) "/")]
          [drive-root
            (string.string-append
              (string.substring-borrowed path 0 2)
              (string.string-append "/" body))]
          [(if rooted
              (= (string-length body) 0)
              false)
            "/"]
          [rooted (string.string-append "/" body)]
          [(= (string-length body) 0) "."]
          [else body])))))

;: Return true when a normalized relative path still escapes via leading `..`.
(define (fs-path-normalized-escapes? [normalized : (& normalized str)]) : bool
  (let
    [n : i64 (string-length normalized)]
    [parent : String ".."]
    (or
      (string.string-eq-borrowed normalized (& parent))
      (and
        (> n 2)
        (string.char-eq (string-ref normalized 0) '.')
        (string.char-eq (string-ref normalized 1) '.')
        (stdlib.fs.fs-path-separator? (string-ref normalized 2))))))

;: Return true when `path` is a non-empty relative suffix that stays below root.
;:
;: This is a lexical guard to use before joining user-controlled suffixes under
;: a trusted root. It rejects empty/`.` paths, absolute or drive-qualified paths,
;: and normalized paths whose first segment is `..`. It does not canonicalize
;: symlinks or query the filesystem.
(define (fs-path-safe-relative? [path : (& path str)]) : bool
  (if (stdlib.fs.fs-path-absolute? path)
    false
    (if (stdlib.fs.fs-path-drive-qualified? path)
      false
      (let
        [normalized : String (stdlib.fs.fs-path-normalize path)]
        (if (not (string.string-eq normalized "."))
          (not (stdlib.fs.fs-path-normalized-escapes? (& normalized)))
          false)))))

;: Join `left` and `right` with exactly one host path separator when needed.
;:
;: Empty sides are returned without allocating an extra separator.
(define (fs-path-join [left : (& left str)] [right : (& right str)]) : String
  (cond
    [(= (string-length left) 0) (string.string-copy-borrowed right)]
    [(= (string-length right) 0) (string.string-copy-borrowed left)]
    [(stdlib.fs.fs-path-separator? (string-ref left (- (string-length left) 1)))
      (if (stdlib.fs.fs-path-separator? (string-ref right 0))
        (let
          [trimmed-right : String
            (string.substring-borrowed right 1 (- (string-length right) 1))]
          (string.string-append-borrowed left (& trimmed-right)))
        (string.string-append-borrowed left right))]
    [(stdlib.fs.fs-path-separator? (string-ref right 0))
      (string.string-append-borrowed left right)]
    [else
      (let
        [separator : String (stdlib.fs.fs-path-separator)]
        [left-with-separator : String
          (string.string-append-borrowed left (& separator))]
        (string.string-append-borrowed (& left-with-separator) right))]))

;: Join two owned `String` path segments by delegating to `fs-path-join`.
;:
;: This helper is the fixed-arity expansion target for `fs-path-join-many`;
;: call `fs-path-join` directly when the caller already has borrowed text.
(define (fs-path-join-owned-pair [left : String] [right : String]) : String
  (stdlib.fs.fs-path-join (& left) (& right)))

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
          (if (stdlib.fs.fs-path-separator? (string-ref path i))
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
        (stdlib.fs.fs-path-separator)
        (string.substring-borrowed path 0 last)))))

;: Final component of `path` (the part after the last separator).
;:
;: Returns `path` unchanged when there is no separator, and `""` when `path`
;: ends with a separator.
(define (fs-basename [path : (& path str)]) : String
  (let
    [n : i64 (string-length path)]
    [last : i64 (fs-last-separator-index path)]
    (if (< last 0)
      (string.string-copy-borrowed path)
      (string.substring-borrowed path (+ last 1) (- n (+ last 1))))))

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
          (if (string.char-eq (string-ref base i) '.')
            (set! dot i)
            (set! dot dot))
          (set! i (+ i 1))))
      (if (<= dot 0)
        ""
        (string.substring base (+ dot 1) (- bn (+ dot 1)))))))

;: Convert a runtime filesystem status into a structured `ResultIoUnit`.
(define (fs-status-result [path : (& path str)] [status : i64]) : io.ResultIoUnit
  (if (= status io.io-status-ok)
    io.OkIoUnit
    (io.ErrIoUnit (io.io-error-from-status path status))))

;: Convert a runtime file-kind status into a structured result.
(define (fs-file-kind-status-result [path : (& path str)] [status : i64]) : ResultFsFileKind
  (cond
    [(= status stdlib.fs.fs-file-kind-regular-code)
      (OkFsFileKind (FsFileRegular))]
    [(= status stdlib.fs.fs-file-kind-directory-code)
      (OkFsFileKind (FsFileDirectory))]
    [(= status stdlib.fs.fs-file-kind-other-code) (OkFsFileKind (FsFileOther))]
    [else (ErrFsFileKind (io.io-error-from-status path status))]))

;: Create `path` as a directory, returning a structured status.
;:
;: Linux uses mode `0700`; Windows uses the CRT `_mkdir` function.
(define (try-mkdir [path : (& path str)]) : io.ResultIoUnit
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (if (io.io-empty-path? path)
      (io.ErrIoUnit (io.io-invalid-path-error path))
      (stdlib.fs.fs-status-result
        path
        (stdlib.fs.fs-mkdir-status-owned path-text)))))

;: Create `path` as a directory when it is missing.
;:
;: A pre-existing path reported by the host as already-created is accepted.
(define (try-mkdir-if-missing [path : (& path str)]) : io.ResultIoUnit
  (let
    [result : io.ResultIoUnit (stdlib.fs.try-mkdir path)]
    (if (io.io-result-unit-ok? result)
      io.OkIoUnit
      (let
        [error : io.IoError
          (io.io-result-unit-error-or result (io.io-invalid-path-error path))]
        [code : i64 (io.io-error-system-code-or error -1)]
        (if (= code stdlib.fs.fs-status-already-exists)
          io.OkIoUnit
          (io.ErrIoUnit error))))))

;: Remove a file path, returning a structured status.
(define (try-remove-file [path : (& path str)]) : io.ResultIoUnit
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (if (io.io-empty-path? path)
      (io.ErrIoUnit (io.io-invalid-path-error path))
      (stdlib.fs.fs-status-result
        path
        (stdlib.fs.fs-remove-file-status-owned path-text)))))

;: Remove an empty directory path, returning a structured status.
(define (try-remove-dir [path : (& path str)]) : io.ResultIoUnit
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (if (io.io-empty-path? path)
      (io.ErrIoUnit (io.io-invalid-path-error path))
      (stdlib.fs.fs-status-result
        path
        (stdlib.fs.fs-remove-dir-status-owned path-text)))))

;: Rename `source` to `destination`, returning a structured status.
;:
;: Host replacement behavior is target-defined: Linux follows `rename(2)`;
;: Windows follows the CRT rename policy.
(define (try-rename
  [source : (& source str)]
  [destination : (& destination str)]) : io.ResultIoUnit
  (if (= (string-length source) 0)
    (io.ErrIoUnit (io.IoInvalidPath (string.string-copy-borrowed source)))
    (if (= (string-length destination) 0)
      (io.ErrIoUnit
        (io.IoInvalidPath (string.string-copy-borrowed destination)))
      (let
        [source-text : String (string.string-copy-borrowed source)]
        [destination-text : String (string.string-copy-borrowed destination)]
        [arrow : String " -> "]
        [source-arrow : String (string.string-append-borrowed source (& arrow))]
        [path : String
          (string.string-append-borrowed (& source-arrow) destination)]
        [status : i64
          (stdlib.fs.fs-rename-status-owned source-text destination-text)]
        (if (= status io.io-status-ok)
          io.OkIoUnit
          (io.ErrIoUnit (io.io-error-from-owned-status path status)))))))

;: Probe the coarse filesystem kind of `path`.
;:
;: Linux and Windows report regular files, directories, and other node kinds.
(define (try-file-kind [path : (& path str)]) : ResultFsFileKind
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (if (io.io-empty-path? path)
      (ErrFsFileKind (io.io-invalid-path-error path))
      (stdlib.fs.fs-file-kind-status-result
        path
        (stdlib.fs.fs-file-kind-status path-text)))))

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
    [path-text : String (string.string-copy-borrowed path)]
    (if (io.io-empty-path? path)
      (ErrFsMetadata (io.io-invalid-path-error path))
      (match (stdlib.fs.try-file-kind path)
        [(ErrFsFileKind error) (ErrFsMetadata error)]
        [(OkFsFileKind kind)
          (if (stdlib.fs.fs-file-kind-regular? kind)
            (let
              [status : i64 (stdlib.fs.fs-file-size-status path-text)]
              (if (= status io.io-status-ok)
                (OkFsMetadata
                  (FsMetadata kind (stdlib.fs.fs-file-size path-text)))
                (ErrFsMetadata (io.io-error-from-status path status))))
            (OkFsMetadata (FsMetadata kind 0)))]))))

;: Split the runtime's newline-delimited directory payload into entry names.
(define (fs-read-dir-split-vec [entries : String]) : vector.StringVec
  (let
    [n : i64 (string-length entries)]
    [items : vector.StringVec (vector.string-vec-new)]
    [start : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (if (string.char-eq (string-ref entries i) '\n')
          (begin
            (if (> i start)
              (set!
                items
                (vector.string-vec-push
                  items
                  (string.substring entries start (- i start))))
              unit)
            (set! start (+ i 1))
            (set! i (+ i 1)))
          (set! i (+ i 1))))
      (if (< start n)
        (vector.string-vec-push
          items
          (string.substring entries start (- n start)))
        items))))

;: Split the runtime's newline-delimited directory payload into entry names.
(define (fs-read-dir-split [entries : String]) : list.StringList
  (list.string-list-from-vec (stdlib.fs.fs-read-dir-split-vec entries)))

;: Read one directory and return entry names as a `StringVec`.
;:
;: Entries are names only, not joined paths. The runtime filters `.` and `..`.
;: Host directory order is preserved and not guaranteed to be stable; callers
;: that need stable ordering should sort the returned vector. The returned
;: vector storage and entry strings allocate in the active arena.
(define (try-read-dir-vec [path : (& path str)]) : ResultIoStringVec
  (let
    [path-text : String (string.string-copy-borrowed path)]
    (if (io.io-empty-path? path)
      (ErrIoStringVec (io.io-invalid-path-error path))
      (let
        [status : i64 (stdlib.fs.fs-read-dir-status path-text)]
        (if (= status io.io-status-ok)
          (OkIoStringVec
            (stdlib.fs.fs-read-dir-split-vec (stdlib.fs.fs-read-dir path-text)))
          (ErrIoStringVec (io.io-error-from-status path status)))))))

;: Read one directory and return entry names as a `StringList`.
;:
;: Entries are names only, not joined paths. The runtime filters `.` and `..`.
;: Host directory order is preserved and not guaranteed to be stable; callers
;: that need stable ordering should sort the returned list. The returned list
;: spine and entry strings allocate in the active arena.
(define (try-read-dir [path : (& path str)]) : ResultIoStringList
  (match (try-read-dir-vec path)
    [(OkIoStringVec entries)
      (OkIoStringList (list.string-list-from-vec entries))]
    [(ErrIoStringVec error) (ErrIoStringList error)]))

;: Remove a file if present. Missing paths are considered already cleaned.
(define (try-remove-file-if-exists [path : (& path str)]) : io.ResultIoUnit
  (let
    [result : io.ResultIoUnit (stdlib.fs.try-remove-file path)]
    (if (io.io-result-unit-ok? result)
      io.OkIoUnit
      (let
        [error : io.IoError
          (io.io-result-unit-error-or result (io.io-invalid-path-error path))]
        (if (io.io-error-not-found? error)
          io.OkIoUnit
          (io.ErrIoUnit error))))))

;: Remove an empty directory if present. Missing paths are considered cleaned.
(define (try-remove-dir-if-exists [path : (& path str)]) : io.ResultIoUnit
  (let
    [result : io.ResultIoUnit (stdlib.fs.try-remove-dir path)]
    (if (io.io-result-unit-ok? result)
      io.OkIoUnit
      (let
        [error : io.IoError
          (io.io-result-unit-error-or result (io.io-invalid-path-error path))]
        (if (io.io-error-not-found? error)
          io.OkIoUnit
          (io.ErrIoUnit error))))))

;: Return the host temporary root used by `try-create-temp-dir`.
(define (fs-temp-root) : String
  (if (stdlib.fs.fs-windows?)
    (let
      [name : String "TEMP"]
      (match (env.env-get (& name))
        [(env.EnvSomeString value) value]
        [(env.EnvNoString)
          (let
            [name : String "TMP"]
            (match (env.env-get (& name))
              [(env.EnvSomeString value) value]
              [(env.EnvNoString) "."]))]))
    (let
      [name : String "TMPDIR"]
      (match (env.env-get (& name))
        [(env.EnvSomeString value) value]
        [(env.EnvNoString) "/tmp"]))))

;: Return the process current directory as an owned active-arena String.
;:
;: The returned path is the host-reported cwd; it is not symlink-canonicalized.
;: Host lookup failures return `ErrIoString` with the mapped status.
(define (try-current-dir) : io.ResultIoString
  (let
    [status : i64 (stdlib.fs.fs-current-dir-status)]
    (if (= status io.io-status-ok)
      (io.OkIoString (stdlib.fs.fs-current-dir))
      (io.ErrIoString (io.io-error-from-label "current directory" status)))))

;: Compose one candidate temporary directory basename from prefix, pid, and attempt.
(define (fs-temp-name [prefix : (& prefix str)] [pid : i64] [attempt : i64]) : String
  (let
    [dash : String "-"]
    [prefix-dash : String (string.string-append-borrowed prefix (& dash))]
    [pid-text : String (string.int->string pid)]
    [attempt-text : String (string.int->string attempt)]
    [pid-dash : String (string.string-append pid-text dash)]
    (string.string-append
      prefix-dash
      (string.string-append pid-dash attempt-text))))

;: Retry temporary directory creation until an unused candidate is found.
(define (fs-create-temp-dir-loop
  [root : (& root str)]
  [prefix : (& prefix str)]
  [pid : i64]
  [attempt : i64]) : io.ResultIoString
  (if (>= attempt stdlib.fs.fs-temp-attempt-limit)
    (io.ErrIoString
      (io.IoSystemCode
        stdlib.fs.fs-status-already-exists
        (string.string-copy-borrowed prefix)))
    (let
      [name : String (stdlib.fs.fs-temp-name prefix pid attempt)]
      [path : String
        (cond
          [(= (string-length root) 0) name]
          [(= (string-length name) 0) (string.string-copy-borrowed root)]
          [(stdlib.fs.fs-path-separator?
              (string-ref root (- (string-length root) 1)))
            (if (stdlib.fs.fs-path-separator? (string-ref name 0))
              (let
                [trimmed-name : String
                  (string.substring-borrowed
                    (& name)
                    1
                    (- (string-length name) 1))]
                (string.string-append-borrowed root (& trimmed-name)))
              (string.string-append-borrowed root (& name)))]
          [(stdlib.fs.fs-path-separator? (string-ref name 0))
            (string.string-append-borrowed root (& name))]
          [else
            (let
              [separator : String (stdlib.fs.fs-path-separator)]
              [root-with-separator : String
                (string.string-append-borrowed root (& separator))]
              (string.string-append root-with-separator name))])]
      [status : i64 (stdlib.fs.fs-mkdir-status-owned path)]
      (if (= status io.io-status-ok)
        (io.OkIoString path)
        (if (= status stdlib.fs.fs-status-already-exists)
          (stdlib.fs.fs-create-temp-dir-loop root prefix pid (+ attempt 1))
          (io.ErrIoString (io.io-error-from-owned-status path status)))))))

;: Create a unique temporary directory for tool artifacts.
;:
;: The directory is created below `$TMPDIR` on Linux (or `/tmp` when `TMPDIR` is
;: missing), and below `%TEMP%`/`%TMP%` (or `.`) on Windows. The unique name is
;: seeded by the process id (`GetCurrentProcessId` on Windows, `getpid` on
;: Linux) and an attempt counter, retrying on collision.
(define (try-create-temp-dir [prefix : (& prefix str)]) : io.ResultIoString
  (if (= (string-length prefix) 0)
    (io.ErrIoString (io.IoInvalidPath (string.string-copy-borrowed prefix)))
    (let
      [root : String (stdlib.fs.fs-temp-root)]
      (stdlib.fs.fs-create-temp-dir-loop
        (& root)
        prefix
        (stdlib.fs.fs-process-id)
        0))))

;; Inline coverage migrated from stdlib/tests/fs_api.tl and
;; stdlib/tests/fs_path_join_many_api.tl (#3085).
(cfg
  test
  (define (fs-test-fail [message : String]) : unit
    (io.panic message)))

(cfg
  test
  (define (fs-test-assert-true [condition : bool] [message : String]) : unit
    (if condition
      unit
      (fs-test-fail message))))

(cfg
  test
  (define (fs-test-assert-false [condition : bool] [message : String]) : unit
    (fs-test-assert-true (not condition) message)))

(cfg
  test
  (define (fs-test-assert-bool-eq
    [actual : bool]
    [expected : bool]
    [message : String]) : unit
    (fs-test-assert-true (= actual expected) message)))

(cfg
  test
  (define (fs-test-assert-i64-eq
    [actual : i64]
    [expected : i64]
    [message : String]) : unit
    (fs-test-assert-true (= actual expected) message)))

(cfg
  test
  (define (fs-test-assert-string-eq
    [actual : (& actual str)]
    [expected : (& expected str)]
    [message : String]) : unit
    (fs-test-assert-true (string.string-eq-borrowed actual expected) message)))

(cfg
  test
  (define (fs-path-join-many-api-assert
    [got : String]
    [want : String]
    [message : String]) : unit
    (fs-test-assert-string-eq (& got) (& want) message)))

(cfg
  test
  (define (fs-path-join-many-api-expected3
    [a : String]
    [b : String]
    [c : String]) : String
    (string.string-append
      (string.string-append
        (string.string-append a (stdlib.fs.fs-path-separator))
        b)
      (string.string-append (stdlib.fs.fs-path-separator) c))))

(cfg
  test
  (define (fs-path-join-many-api-expected4
    [a : String]
    [b : String]
    [c : String]
    [d : String]) : String
    (string.string-append
      (fs-path-join-many-api-expected3 a b c)
      (string.string-append (stdlib.fs.fs-path-separator) d))))

(cfg
  test
  (define (fs-test-path-join-many-main) : i64
    (begin
      (fs-path-join-many-api-assert
        (fs-path-join-many)
        ""
        "fs-path-join-many zero")
      (fs-path-join-many-api-assert
        (fs-path-join-many "solo")
        "solo"
        "fs-path-join-many one")
      (fs-path-join-many-api-assert
        (fs-path-join-many "left path" "right file")
        (string.string-append
          (string.string-append "left path" (fs-path-separator))
          "right file")
        "fs-path-join-many two")
      (fs-path-join-many-api-assert
        (fs-path-join-many "left" "middle" "right")
        (fs-path-join-many-api-expected3 "left" "middle" "right")
        "fs-path-join-many three")
      (fs-path-join-many-api-assert
        (fs-path-join-many "left" "middle" "right" "leaf")
        (fs-path-join-many-api-expected4 "left" "middle" "right" "leaf")
        "fs-path-join-many four")
      (fs-path-join-many-api-assert
        (fs-path-join-many "left/" "/right" "leaf")
        (string.string-append
          "left/right"
          (string.string-append (fs-path-separator) "leaf"))
        "fs-path-join-many duplicate separator")
      42)))

(cfg
  test
  (test
    fs-path-join-many-api
    (if (= (fs-test-path-join-many-main) 42)
      unit
      (fs-test-fail "fs-path-join-many-api did not return 42"))))

(cfg
  test
  (define (fs-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (fs-test-assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (fs-test-assert-ok-unit [result : io.ResultIoUnit] [message : String]) : unit
    (match result
      [(io.OkIoUnit) unit]
      [(io.ErrIoUnit error) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-not-found-unit
    [result : io.ResultIoUnit]
    [message : String]) : unit
    (match result
      [(io.OkIoUnit) (io.panic message)]
      [(io.ErrIoUnit error) unit])))

(cfg
  test
  (define (fs-test-assert-invalid-unit
    [result : io.ResultIoUnit]
    [message : String]) : unit
    (match result
      [(io.OkIoUnit) (io.panic message)]
      [(io.ErrIoUnit error) unit])))

(cfg
  test
  (define (fs-test-assert-unsupported-unit
    [result : io.ResultIoUnit]
    [message : String]) : unit
    (match result
      [(io.OkIoUnit) (io.panic message)]
      [(io.ErrIoUnit error) unit])))

(cfg
  test
  (define (fs-test-expect-ok-string
    [result : io.ResultIoString]
    [message : String]) : String
    (match result
      [(io.OkIoString value) value]
      [(io.ErrIoString error) (io.panic message)])))

(cfg
  test
  (define (fs-test-expect-ok-string-list
    [result : ResultIoStringList]
    [message : String]) : list.StringList
    (match result
      [(OkIoStringList value) value]
      [(ErrIoStringList error) (io.panic message)])))

(cfg
  test
  (define (fs-test-expect-ok-string-vec
    [result : ResultIoStringVec]
    [message : String]) : vector.StringVec
    (match result
      [(OkIoStringVec value) value]
      [(ErrIoStringVec error) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-unsupported-string-list
    [result : ResultIoStringList]
    [message : String]) : unit
    (match result
      [(OkIoStringList _) (io.panic message)]
      [(ErrIoStringList error) unit])))

(cfg
  test
  (define (fs-test-assert-not-found-string-list
    [result : ResultIoStringList]
    [message : String]) : unit
    (match result
      [(OkIoStringList _) (io.panic message)]
      [(ErrIoStringList error) unit])))

(cfg
  test
  (define (fs-test-assert-invalid-string-list
    [result : ResultIoStringList]
    [message : String]) : unit
    (match result
      [(OkIoStringList _) (io.panic message)]
      [(ErrIoStringList error) unit])))

(cfg
  test
  (define (fs-test-assert-error-string-list
    [result : ResultIoStringList]
    [message : String]) : unit
    (match result
      [(OkIoStringList _) (io.panic message)]
      [(ErrIoStringList _) unit])))

(cfg
  test
  (define (fs-api-test-try-file-exists? [path : String]) : io.ResultIoBool
    (io.try-file-exists? (& path))))

(cfg
  test
  (define (fs-api-test-try-read-file [path : String]) : io.ResultIoString
    (io.try-read-file (& path))))

(cfg
  test
  (define (fs-api-test-try-write-file [path : String] [contents : String]) : io.ResultIoUnit
    (io.try-write-file (& path) (& contents))))

(cfg
  test
  (define (fs-api-test-fs-path-join [left : String] [right : String]) : String
    (stdlib.fs.fs-path-join (& left) (& right))))

(cfg
  test
  (define (fs-api-test-fs-path-join-many0) : String
    (stdlib.fs.fs-path-join-many)))

(cfg
  test
  (define (fs-api-test-fs-path-join-many1 [a : String]) : String
    (stdlib.fs.fs-path-join-many a)))

(cfg
  test
  (define (fs-api-test-fs-path-join-many2 [a : String] [b : String]) : String
    (stdlib.fs.fs-path-join-many a b)))

(cfg
  test
  (define (fs-api-test-fs-path-join-many3
    [a : String]
    [b : String]
    [c : String]) : String
    (stdlib.fs.fs-path-join-many a b c)))

(cfg
  test
  (define (fs-api-test-fs-path-join-many4
    [a : String]
    [b : String]
    [c : String]
    [d : String]) : String
    (stdlib.fs.fs-path-join-many a b c d)))

(cfg
  test
  (define (fs-api-test-fs-path-starts-separator? [path : String]) : bool
    (stdlib.fs.fs-path-starts-separator? (& path))))

(cfg
  test
  (define (fs-api-test-fs-dirname [path : String]) : String
    (stdlib.fs.fs-dirname (& path))))

(cfg
  test
  (define (fs-api-test-fs-basename [path : String]) : String
    (stdlib.fs.fs-basename (& path))))

(cfg
  test
  (define (fs-api-test-fs-extension [path : String]) : String
    (stdlib.fs.fs-extension (& path))))

(cfg
  test
  (define (fs-api-test-fs-path-normalize [path : String]) : String
    (stdlib.fs.fs-path-normalize (& path))))

(cfg
  test
  (define (fs-api-test-fs-path-absolute? [path : String]) : bool
    (stdlib.fs.fs-path-absolute? (& path))))

(cfg
  test
  (define (fs-api-test-fs-path-safe-relative? [path : String]) : bool
    (stdlib.fs.fs-path-safe-relative? (& path))))

(cfg
  test
  (define (fs-api-test-try-mkdir [path : String]) : io.ResultIoUnit
    (stdlib.fs.try-mkdir (& path))))

(cfg
  test
  (define (fs-api-test-try-mkdir-if-missing [path : String]) : io.ResultIoUnit
    (stdlib.fs.try-mkdir-if-missing (& path))))

(cfg
  test
  (define (fs-api-test-try-remove-file [path : String]) : io.ResultIoUnit
    (stdlib.fs.try-remove-file (& path))))

(cfg
  test
  (define (fs-api-test-try-remove-dir [path : String]) : io.ResultIoUnit
    (stdlib.fs.try-remove-dir (& path))))

(cfg
  test
  (define (fs-api-test-try-rename [source : String] [destination : String]) : io.ResultIoUnit
    (stdlib.fs.try-rename (& source) (& destination))))

(cfg
  test
  (define (fs-api-test-try-read-dir [path : String]) : ResultIoStringList
    (stdlib.fs.try-read-dir (& path))))

(cfg
  test
  (define (fs-api-test-try-read-dir-vec [path : String]) : ResultIoStringVec
    (stdlib.fs.try-read-dir-vec (& path))))

(cfg
  test
  (define (fs-api-test-try-file-kind [path : String]) : ResultFsFileKind
    (stdlib.fs.try-file-kind (& path))))

(cfg
  test
  (define (fs-api-test-try-file-metadata [path : String]) : ResultFsMetadata
    (stdlib.fs.try-file-metadata (& path))))

(cfg
  test
  (define (fs-api-test-fs-file-kind-status [path : String]) : i64
    (stdlib.fs.fs-file-kind-status path)))

(cfg
  test
  (define (fs-api-test-fs-file-size-status [path : String]) : i64
    (stdlib.fs.fs-file-size-status path)))

(cfg
  test
  (define (fs-api-test-fs-file-size [path : String]) : i64
    (stdlib.fs.fs-file-size path)))

(cfg
  test
  (define (fs-api-test-try-remove-file-if-exists [path : String]) : io.ResultIoUnit
    (stdlib.fs.try-remove-file-if-exists (& path))))

(cfg
  test
  (define (fs-api-test-try-remove-dir-if-exists [path : String]) : io.ResultIoUnit
    (stdlib.fs.try-remove-dir-if-exists (& path))))

(cfg
  test
  (define (fs-api-test-try-create-temp-dir [prefix : String]) : io.ResultIoString
    (stdlib.fs.try-create-temp-dir (& prefix))))

(cfg
  test
  (define (fs-test-assert-exists
    [path : String]
    [expected : bool]
    [message : String]) : unit
    (match (fs-api-test-try-file-exists? path)
      [(io.OkIoBool exists) (fs-test-assert-bool-eq exists expected message)]
      [(io.ErrIoBool error) (io.panic message)])))

(cfg
  test
  (define (fs-test-expect-file-kind
    [result : ResultFsFileKind]
    [message : String]) : FsFileKind
    (match result
      [(OkFsFileKind kind) kind]
      [(ErrFsFileKind error) (io.panic message)])))

(cfg
  test
  (define (fs-test-expect-file-metadata
    [result : ResultFsMetadata]
    [message : String]) : FsMetadata
    (match result
      [(OkFsMetadata metadata) metadata]
      [(ErrFsMetadata error) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-kind-regular [path : String] [message : String]) : unit
    (match (fs-test-expect-file-kind (fs-api-test-try-file-kind path) message)
      [(FsFileRegular) unit]
      [_ (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-kind-directory
    [path : String]
    [message : String]) : unit
    (match (fs-test-expect-file-kind (fs-api-test-try-file-kind path) message)
      [(FsFileDirectory) unit]
      [_ (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-kind-not-found
    [path : String]
    [message : String]) : unit
    (match (fs-api-test-try-file-kind path)
      [(ErrFsFileKind error) unit]
      [(OkFsFileKind _) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-kind-invalid [path : String] [message : String]) : unit
    (match (fs-api-test-try-file-kind path)
      [(ErrFsFileKind error) unit]
      [(OkFsFileKind _) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-kind-unsupported
    [path : String]
    [message : String]) : unit
    (match (fs-api-test-try-file-kind path)
      [(ErrFsFileKind error) unit]
      [(OkFsFileKind _) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-metadata-regular-size
    [path : String]
    [expected-size : i64]
    [message : String]) : unit
    (let
      [metadata : FsMetadata
        (fs-test-expect-file-metadata
          (fs-api-test-try-file-metadata path)
          message)]
      (begin
        (match (fs-metadata-kind metadata)
          [(FsFileRegular) unit]
          [_ (io.panic message)])
        (fs-test-assert-i64-eq
          (fs-metadata-size metadata)
          expected-size
          message)))))

(cfg
  test
  (define (fs-test-assert-file-metadata-directory
    [path : String]
    [message : String]) : unit
    (match (fs-metadata-kind
      (fs-test-expect-file-metadata
        (fs-api-test-try-file-metadata path)
        message))
      [(FsFileDirectory) unit]
      [_ (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-metadata-not-found
    [path : String]
    [message : String]) : unit
    (match (fs-api-test-try-file-metadata path)
      [(ErrFsMetadata error) unit]
      [(OkFsMetadata _) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-metadata-invalid
    [path : String]
    [message : String]) : unit
    (match (fs-api-test-try-file-metadata path)
      [(ErrFsMetadata error) unit]
      [(OkFsMetadata _) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-file-metadata-unsupported
    [path : String]
    [message : String]) : unit
    (match (fs-api-test-try-file-metadata path)
      [(ErrFsMetadata error) unit]
      [(OkFsMetadata _) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-runtime-metadata-regular
    [path : String]
    [expected-size : i64]
    [message : String]) : unit
    (begin
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-kind-status path)
        fs-file-kind-regular-code
        message)
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-size-status path)
        io.io-status-ok
        message)
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-size path)
        expected-size
        message))))

(cfg
  test
  (define (fs-test-assert-runtime-metadata-directory
    [path : String]
    [message : String]) : unit
    (begin
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-kind-status path)
        fs-file-kind-directory-code
        message)
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-size-status path)
        io.io-status-ok
        message)
      (fs-test-assert-i64-eq (fs-api-test-fs-file-size path) 0 message))))

(cfg
  test
  (define (fs-test-assert-runtime-metadata-not-found
    [path : String]
    [message : String]) : unit
    (begin
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-kind-status path)
        io.io-status-not-found
        message)
      (fs-test-assert-i64-eq
        (fs-api-test-fs-file-size-status path)
        io.io-status-not-found
        message)
      (fs-test-assert-i64-eq (fs-api-test-fs-file-size path) 0 message))))

(cfg
  test
  (define (fs-test-assert-string-vec3
    [items : vector.StringVec]
    [first : String]
    [second : String]
    [third : String]
    [message : String]) : unit
    (begin
      (fs-test-assert-i64-eq (vector.string-vec-len items) 3 message)
      (fs-test-assert-owned-string-eq
        (vector.string-vec-get items 0 "missing")
        first
        message)
      (fs-test-assert-owned-string-eq
        (vector.string-vec-get items 1 "missing")
        second
        message)
      (fs-test-assert-owned-string-eq
        (vector.string-vec-get items 2 "missing")
        third
        message))))

(cfg
  test
  (define (fs-test-assert-file-contents
    [path : String]
    [expected : String]
    [message : String]) : unit
    (match (fs-api-test-try-read-file path)
      [(io.OkIoString contents)
        (fs-test-assert-owned-string-eq contents expected message)]
      [(io.ErrIoString error) (io.panic message)])))

(cfg
  test
  (define (fs-test-assert-created-temp-dir) : unit
    (let
      [dir-a : String
        (fs-test-expect-ok-string
          (fs-api-test-try-create-temp-dir "typelisp fs test")
          "create temp dir a: ")]
      [dir-b : String
        (fs-test-expect-ok-string
          (fs-api-test-try-create-temp-dir "typelisp fs test")
          "create temp dir b: ")]
      (begin
        (fs-test-assert-true
          (not (string.string-eq dir-a dir-b))
          "temp directories are unique")
        (fs-test-assert-exists dir-a true "temp dir a exists")
        (fs-test-assert-exists dir-b true "temp dir b exists")))))

(cfg
  test
  (define (fs-test-assert-invalid-temp-dir) : unit
    (match (fs-api-test-try-create-temp-dir "")
      [(io.ErrIoString _) unit]
      [(io.OkIoString _) (io.panic "empty temp prefix unexpectedly succeeded")])))

(cfg
  test
  (define (fs-test-assert-mkdir-if-missing [parent : String] [cleanup : bool]) : unit
    (let
      [dir : String (fs-api-test-fs-path-join parent "mkdir-if-missing")]
      (begin
        (fs-test-assert-ok-unit
          (fs-api-test-try-mkdir-if-missing dir)
          "mkdir-if-missing new dir: ")
        (fs-test-assert-exists dir true "mkdir-if-missing dir exists")
        (fs-test-assert-ok-unit
          (fs-api-test-try-mkdir-if-missing dir)
          "mkdir-if-missing existing dir: ")
        (if cleanup
          (fs-test-assert-ok-unit
            (fs-api-test-try-remove-dir dir)
            "mkdir-if-missing cleanup dir: ")
          unit)))))

(cfg
  test
  (define (fs-test-assert-linux-rename-api [root : String]) : unit
    (let
      [file-source : String
        (fs-api-test-fs-path-join root "rename source with space.txt")]
      [file-destination : String
        (fs-api-test-fs-path-join root "rename destination with space.txt")]
      [replace-source : String
        (fs-api-test-fs-path-join root "replace source.txt")]
      [replace-destination : String
        (fs-api-test-fs-path-join root "replace destination.txt")]
      [dir-source : String
        (fs-api-test-fs-path-join root "dir source with space")]
      [dir-destination : String
        (fs-api-test-fs-path-join root "dir destination with space")]
      [missing-source : String
        (fs-api-test-fs-path-join root "missing source.txt")]
      [missing-destination : String
        (fs-api-test-fs-path-join root "missing destination.txt")]
      (begin
        (fs-test-assert-ok-unit
          (fs-api-test-try-write-file file-source "alpha")
          "write rename source: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-rename file-source file-destination)
          "rename file with spaces: ")
        (fs-test-assert-exists file-source false "renamed source is gone")
        (fs-test-assert-exists
          file-destination
          true
          "renamed destination exists")
        (fs-test-assert-file-contents
          file-destination
          "alpha"
          "renamed destination preserves contents")
        (fs-test-assert-not-found-unit
          (fs-api-test-try-rename missing-source missing-destination)
          "missing rename source is not found")
        (fs-test-assert-invalid-unit
          (fs-api-test-try-rename "" file-destination)
          "empty rename source is invalid")
        (fs-test-assert-invalid-unit
          (fs-api-test-try-rename file-destination "")
          "empty rename destination is invalid")
        (fs-test-assert-ok-unit
          (fs-api-test-try-write-file replace-source "replacement")
          "write replacement source: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-write-file replace-destination "old")
          "write replacement destination: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-rename replace-source replace-destination)
          "rename replaces existing file: ")
        (fs-test-assert-exists
          replace-source
          false
          "replacement source is gone")
        (fs-test-assert-file-contents
          replace-destination
          "replacement"
          "rename replacement policy overwrites destination")
        (fs-test-assert-ok-unit
          (fs-api-test-try-mkdir dir-source)
          "create rename dir source: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-rename dir-source dir-destination)
          "rename directory with spaces: ")
        (fs-test-assert-exists
          dir-source
          false
          "renamed directory source is gone")
        (fs-test-assert-exists
          dir-destination
          true
          "renamed directory destination exists")
        (fs-test-assert-ok-unit
          (fs-api-test-try-remove-file file-destination)
          "cleanup renamed file: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-remove-file replace-destination)
          "cleanup replacement file: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-remove-dir dir-destination)
          "cleanup renamed directory: ")))))

(cfg
  test
  (define (fs-test-assert-windows-rename-api) : unit
    (begin
      (fs-test-assert-not-found-unit
        (fs-api-test-try-rename "windows source" "windows destination")
        "windows missing rename source reports not found")
      (fs-test-assert-invalid-unit
        (fs-api-test-try-rename "" "windows destination")
        "windows empty rename source is invalid")
      (fs-test-assert-invalid-unit
        (fs-api-test-try-rename "windows source" "")
        "windows empty rename destination is invalid"))))

(cfg
  test
  (define (fs-test-assert-read-dir-api [root : String]) : unit
    (let
      [file-a : String (fs-api-test-fs-path-join root "alpha.txt")]
      [file-b : String (fs-api-test-fs-path-join root "beta data.txt")]
      [child-dir : String (fs-api-test-fs-path-join root "child-dir")]
      [missing : String (fs-api-test-fs-path-join root "missing")]
      (begin
        (fs-test-assert-ok-unit
          (fs-api-test-try-write-file file-a "alpha")
          "read-dir file a: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-write-file file-b "beta")
          "read-dir file b: ")
        (fs-test-assert-ok-unit
          (fs-api-test-try-mkdir child-dir)
          "read-dir child dir: ")
        (let
          [entries : list.StringList
            (fs-test-expect-ok-string-list
              (fs-api-test-try-read-dir root)
              "read dir: ")]
          [entries-vec : vector.StringVec
            (fs-test-expect-ok-string-vec
              (fs-api-test-try-read-dir-vec root)
              "read dir vec: ")]
          (begin
            (fs-test-assert-true
              (list.string-list-contains? entries "alpha.txt")
              "read-dir includes first file name")
            (fs-test-assert-true
              (list.string-list-contains? entries "beta data.txt")
              "read-dir includes second file name")
            (fs-test-assert-true
              (list.string-list-contains? entries "child-dir")
              "read-dir includes subdirectory name")
            (fs-test-assert-false
              (list.string-list-contains? entries ".")
              "read-dir filters dot")
            (fs-test-assert-false
              (list.string-list-contains? entries "..")
              "read-dir filters dotdot")
            (fs-test-assert-true
              (vector.string-vec-contains? entries-vec "alpha.txt")
              "read-dir vec includes first file name")
            (fs-test-assert-true
              (vector.string-vec-contains? entries-vec "beta data.txt")
              "read-dir vec includes second file name")
            (fs-test-assert-true
              (vector.string-vec-contains? entries-vec "child-dir")
              "read-dir vec includes subdirectory name")
            (fs-test-assert-false
              (vector.string-vec-contains? entries-vec ".")
              "read-dir vec filters dot")
            (fs-test-assert-false
              (vector.string-vec-contains? entries-vec "..")
              "read-dir vec filters dotdot")
            (fs-test-assert-not-found-string-list
              (fs-api-test-try-read-dir missing)
              "read-dir missing path reports not found")
            (fs-test-assert-error-string-list
              (fs-api-test-try-read-dir file-a)
              "read-dir file path reports an IoError")
            (fs-test-assert-invalid-string-list
              (fs-api-test-try-read-dir "")
              "read-dir empty path invalid")
            (fs-test-assert-ok-unit
              (fs-api-test-try-remove-file file-a)
              "cleanup read-dir file a: ")
            (fs-test-assert-ok-unit
              (fs-api-test-try-remove-file file-b)
              "cleanup read-dir file b: ")
            (fs-test-assert-ok-unit
              (fs-api-test-try-remove-dir child-dir)
              "cleanup read-dir child: ")))))))

(cfg
  test
  (define (fs-test-drive-absolute? [path : String]) : bool
    (and
      (> (string-length path) 2)
      (= (string-ref path 1) ':')
      (stdlib.fs.fs-path-separator? (string-ref path 2)))))

(cfg
  test
  (define (fs-test-assert-current-dir-api) : unit
    (begin
      (fs-test-assert-i64-eq
        (stdlib.fs.fs-current-dir-status)
        io.io-status-ok
        "current dir status ok")
      (let
        [direct-cwd : String (stdlib.fs.fs-current-dir)]
        (fs-test-assert-true
          (> (string-length direct-cwd) 0)
          "direct current dir is non-empty"))
      (match (stdlib.fs.try-current-dir)
        [(io.OkIoString cwd)
          (begin
            (fs-test-assert-true
              (> (string-length cwd) 0)
              "current dir is non-empty")
            (fs-test-assert-true
              (if (stdlib.fs.fs-windows?)
                (if (fs-api-test-fs-path-starts-separator? cwd)
                  true
                  (fs-test-drive-absolute? cwd))
                (fs-api-test-fs-path-starts-separator? cwd))
              "current dir has rooted shape"))]
        [(io.ErrIoString _)
          (fs-test-assert-true false "current dir unexpectedly failed")]))))

(cfg
  test
  (define (fs-test-api-main) : i64
    (let
      [joined : String (fs-api-test-fs-path-join "left path" "right file")]
      [expected-join : String
        (string.string-append
          (string.string-append "left path" (stdlib.fs.fs-path-separator))
          "right file")]
      (begin
        (fs-test-assert-owned-string-eq
          joined
          expected-join
          "path join inserts separator")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join "left/" "/right")
          "left/right"
          "path join avoids duplicate separator")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join-many0)
          ""
          "path join many zero segments")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join-many1 "solo")
          "solo"
          "path join many one segment")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join-many2 "left path" "right file")
          expected-join
          "path join many two segments")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join-many3 "left" "middle" "right")
          (string.string-append
            (string.string-append
              (string.string-append "left" (stdlib.fs.fs-path-separator))
              "middle")
            (string.string-append (stdlib.fs.fs-path-separator) "right"))
          "path join many three segments")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join-many4 "left" "middle" "right" "leaf")
          (string.string-append
            (string.string-append
              (string.string-append
                (string.string-append "left" (stdlib.fs.fs-path-separator))
                "middle")
              (string.string-append (stdlib.fs.fs-path-separator) "right"))
            (string.string-append (stdlib.fs.fs-path-separator) "leaf"))
          "path join many four segments")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-join-many3 "left/" "/right" "leaf")
          (string.string-append
            "left/right"
            (string.string-append (stdlib.fs.fs-path-separator) "leaf"))
          "path join many avoids duplicate separator")
        (fs-test-assert-string-vec3
          (stdlib.fs.fs-read-dir-split-vec "first\nsecond\nthird\n")
          "first"
          "second"
          "third"
          "read-dir split vec preserves payload order")
        ;; #822: pure path-string helpers (separator-agnostic; `/` cases are
        ;; stable on both Linux and Windows).
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-dirname "src/app/main.tl")
          "src/app"
          "dirname strips final component")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-dirname "main.tl")
          "."
          "dirname of bare name is dot")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-basename "src/app/main.tl")
          "main.tl"
          "basename is final component")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-basename "main.tl")
          "main.tl"
          "basename of bare name is itself")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-extension "src/main.tl")
          "tl"
          "extension after last dot")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-extension "archive.tar.gz")
          "gz"
          "extension uses last dot")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-extension "Makefile")
          ""
          "no dot means no extension")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-extension ".gitignore")
          ""
          "leading-dot name has no extension")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "")
          "."
          "normalize empty path to dot")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize ".")
          "."
          "normalize dot path")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "src/./x/../compiler_load.tl")
          "src/compiler_load.tl"
          "normalize dot and parent segments")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "target\\loader\\..\\dep.tl")
          "target/dep.tl"
          "normalize windows separators to slash")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "src//./app\\../main.tl")
          "src/main.tl"
          "normalize repeated and mixed separators")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "../pkg/lib.tl")
          "../pkg/lib.tl"
          "normalize preserves leading relative parent")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "a/../../b")
          "../b"
          "normalize preserves escaping relative parent")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "/a/..")
          "/"
          "normalize preserves root")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "\\a\\..\\b")
          "/b"
          "normalize rooted windows separators")
        (fs-test-assert-owned-string-eq
          (fs-api-test-fs-path-normalize "C:\\tmp\\..\\file.tl")
          "C:/file.tl"
          "normalize drive absolute path")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-absolute? "/root")
          true
          "slash-rooted path is absolute")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-absolute? "\\root")
          true
          "backslash-rooted path is absolute")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-absolute? "C:/root")
          true
          "drive slash path is absolute")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-absolute? "C:\\root")
          true
          "drive backslash path is absolute")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-absolute? "C:root")
          false
          "drive-relative path is not absolute")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-absolute? "src/main.tl")
          false
          "relative path is not absolute")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "src/main.tl")
          true
          "normal relative path is safe")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "src//./lib/../main.tl")
          true
          "normalizing relative path below root is safe")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "")
          false
          "empty path is not a safe suffix")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? ".")
          false
          "dot path is not a safe suffix")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "..")
          false
          "parent path is not a safe suffix")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "../escape.tl")
          false
          "leading parent traversal is not safe")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "a/../../escape.tl")
          false
          "normalized parent traversal is not safe")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "/abs.tl")
          false
          "rooted path is not a safe suffix")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "C:/abs.tl")
          false
          "drive absolute path is not a safe suffix")
        (fs-test-assert-bool-eq
          (fs-api-test-fs-path-safe-relative? "C:relative.tl")
          false
          "drive-relative path is not a safe suffix")
        (fs-test-assert-current-dir-api)
        (if (stdlib.fs.fs-windows?)
          (begin
            (fs-test-assert-created-temp-dir)
            (let
              [dir : String
                (fs-test-expect-ok-string
                  (fs-api-test-try-create-temp-dir "typelisp fs mkdir test")
                  "create temp dir mkdir: ")]
              [dir-d : String
                (fs-test-expect-ok-string
                  (fs-api-test-try-create-temp-dir "typelisp fs read dir test")
                  "create temp dir read dir: ")]
              [file-a : String
                (fs-api-test-fs-path-join dir "artifact with space.s")]
              (begin
                (fs-test-assert-mkdir-if-missing dir true)
                (fs-test-assert-file-kind-directory
                  dir
                  "windows temp dir is directory")
                (fs-test-assert-file-metadata-directory
                  dir
                  "windows temp dir metadata is directory")
                (fs-test-assert-runtime-metadata-directory
                  dir
                  "windows runtime metadata dir")
                (fs-test-assert-ok-unit
                  (fs-api-test-try-write-file file-a "assembly")
                  "windows write temp artifact: ")
                (fs-test-assert-file-kind-regular
                  file-a
                  "windows temp artifact is regular")
                (fs-test-assert-file-metadata-regular-size
                  file-a
                  8
                  "windows temp artifact metadata size")
                (fs-test-assert-runtime-metadata-regular
                  file-a
                  8
                  "windows runtime metadata file")
                (fs-test-assert-file-kind-not-found
                  (fs-api-test-fs-path-join dir "missing artifact.s")
                  "windows missing file kind is not found")
                (fs-test-assert-file-metadata-not-found
                  (fs-api-test-fs-path-join dir "missing artifact.s")
                  "windows missing file metadata is not found")
                (fs-test-assert-runtime-metadata-not-found
                  (fs-api-test-fs-path-join dir "missing artifact.s")
                  "windows runtime metadata missing")
                (fs-test-assert-ok-unit
                  (fs-api-test-try-remove-file file-a)
                  "windows remove temp artifact: ")
                (fs-test-assert-read-dir-api dir-d)
                (fs-test-assert-ok-unit
                  (fs-api-test-try-remove-dir dir-d)
                  "windows cleanup read-dir temp dir: ")
                (fs-test-assert-ok-unit
                  (fs-api-test-try-remove-dir dir)
                  "windows cleanup mkdir temp dir: ")))
            (fs-test-assert-windows-rename-api)
            (fs-test-assert-file-kind-invalid
              ""
              "windows empty file-kind path invalid")
            (fs-test-assert-file-metadata-invalid
              ""
              "windows empty metadata path invalid")
            42)
          (let
            [dir-a : String
              (fs-test-expect-ok-string
                (fs-api-test-try-create-temp-dir "typelisp fs test")
                "create temp dir a: ")]
            [dir-b : String
              (fs-test-expect-ok-string
                (fs-api-test-try-create-temp-dir "typelisp fs test")
                "create temp dir b: ")]
            [dir-c : String
              (fs-test-expect-ok-string
                (fs-api-test-try-create-temp-dir "typelisp fs rename test")
                "create temp dir c: ")]
            [dir-d : String
              (fs-test-expect-ok-string
                (fs-api-test-try-create-temp-dir "typelisp fs read dir test")
                "create temp dir d: ")]
            [file-a : String
              (fs-api-test-fs-path-join dir-a "artifact with space.s")]
            [file-b : String (fs-api-test-fs-path-join dir-b "cleanup.obj")]
            (begin
              (fs-test-assert-true
                (not (string.string-eq dir-a dir-b))
                "temp directories are unique")
              (fs-test-assert-exists dir-a true "temp dir a exists")
              (fs-test-assert-exists dir-b true "temp dir b exists")
              (fs-test-assert-file-kind-directory
                dir-a
                "temp dir a is directory")
              (fs-test-assert-file-metadata-directory
                dir-a
                "temp dir a metadata is directory")
              (fs-test-assert-runtime-metadata-directory
                dir-a
                "runtime metadata dir")
              (fs-test-assert-ok-unit
                (fs-api-test-try-write-file file-a "assembly")
                "write temp artifact a: ")
              (fs-test-assert-ok-unit
                (fs-api-test-try-write-file file-b "object")
                "write temp artifact b: ")
              (fs-test-assert-mkdir-if-missing dir-a true)
              (fs-test-assert-exists file-a true "temp artifact a exists")
              (fs-test-assert-file-kind-regular
                file-a
                "temp artifact a is regular")
              (fs-test-assert-file-metadata-regular-size
                file-a
                8
                "temp artifact a metadata size")
              (fs-test-assert-runtime-metadata-regular
                file-a
                8
                "runtime metadata file")
              (fs-test-assert-file-kind-not-found
                (fs-api-test-fs-path-join dir-a "missing artifact.s")
                "missing file kind is not found")
              (fs-test-assert-file-metadata-not-found
                (fs-api-test-fs-path-join dir-a "missing artifact.s")
                "missing file metadata is not found")
              (fs-test-assert-runtime-metadata-not-found
                (fs-api-test-fs-path-join dir-a "missing artifact.s")
                "runtime metadata missing")
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-file file-a)
                "remove temp artifact a: ")
              (fs-test-assert-exists file-a false "temp artifact a removed")
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-dir dir-a)
                "remove temp dir a: ")
              (fs-test-assert-exists dir-a false "temp dir a removed")
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-file-if-exists file-b)
                "cleanup temp artifact b: ")
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-file-if-exists file-b)
                "cleanup missing temp artifact b: ")
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-dir-if-exists dir-b)
                "cleanup temp dir b: ")
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-dir-if-exists dir-b)
                "cleanup missing temp dir b: ")
              (fs-test-assert-invalid-temp-dir)
              (fs-test-assert-file-kind-invalid
                ""
                "empty file-kind path invalid")
              (fs-test-assert-file-metadata-invalid
                ""
                "empty metadata path invalid")
              (fs-test-assert-linux-rename-api dir-c)
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-dir dir-c)
                "cleanup rename temp dir: ")
              (fs-test-assert-read-dir-api dir-d)
              (fs-test-assert-ok-unit
                (fs-api-test-try-remove-dir dir-d)
                "cleanup read-dir temp dir: ")
              42)))))))

(cfg
  test
  (test
    fs-api
    (if (= (fs-test-api-main) 42)
      unit
      (fs-test-fail "fs-api did not return 42"))))

(export
  (value fs-linux-syscall-mkdir)
  (value fs-linux-syscall-unlink)
  (value fs-linux-syscall-rmdir)
  (value fs-linux-syscall-rename)
  (value fs-linux-syscall-getpid)
  (value fs-linux-syscall-getcwd)
  (value fs-linux-syscall-openat)
  (value fs-linux-syscall-getdents64)
  (value fs-windows-get-current-process-id)
  (value fs-windows-get-current-directory)
  (value fs-status-from-result)
  (value fs-mkdir-status-owned)
  (value fs-mkdir-status)
  (value fs-remove-file-status-owned)
  (value fs-remove-file-status)
  (value fs-remove-dir-status-owned)
  (value fs-remove-dir-status)
  (value fs-rename-status-owned)
  (value fs-rename-status)
  (value fs-process-id)
  (value fs-linux-at-fdcwd)
  (value fs-linux-open-directory)
  (value fs-read-dir-buffer-size)
  (value fs-windows-find-data-size)
  (value fs-windows-find-data-name-offset)
  (value fs-c-string-byte)
  (value fs-read-dir-dot-entry?)
  (value fs-read-dir-append-entry!)
  (value fs-read-dir-bytes-string)
  (value fs-read-dir-status)
  (value fs-read-dir)
  (value fs-file-kind-regular-code)
  (value fs-file-kind-directory-code)
  (value fs-file-kind-other-code)
  (value fs-windows-file-attribute-data-size)
  (value fs-windows-file-attribute-directory)
  (value fs-windows-file-attributes-offset)
  (value fs-windows-file-size-high-offset)
  (value fs-windows-file-size-low-offset)
  (value fs-metadata-read-u32-at)
  (value fs-metadata-read-i64-at)
  (value fs-file-metadata-probe)
  (value fs-file-kind-status)
  (value fs-file-size-status)
  (value fs-file-size)
  (value fs-status-range)
  (value fs-current-dir-initial-capacity)
  (value fs-current-dir-max-capacity)
  (value fs-current-dir-next-capacity)
  (value fs-current-dir-status-loop)
  (value fs-current-dir-loop)
  (value fs-current-dir-status)
  (value fs-current-dir)
  (value fs-status-already-exists)
  (value fs-temp-attempt-limit)
  (value fs-windows?)
  (value fs-path-separator)
  (value fs-path-separator-char)
  (value fs-path-separator?)
  (value fs-path-starts-separator?)
  (value fs-path-ends-separator?)
  (value fs-path-drive-qualified?)
  (value fs-path-absolute?)
  (value fs-path-segment-vec-render-from)
  (value fs-path-segment-vec-render)
  (value fs-path-normalize-segment)
  (value fs-path-normalize)
  (value fs-path-normalized-escapes?)
  (value fs-path-safe-relative?)
  (value fs-path-join)
  (value fs-path-join-owned-pair)
  (value fs-last-separator-index)
  (value fs-dirname)
  (value fs-basename)
  (value fs-extension)
  (value fs-status-result)
  (value fs-file-kind-status-result)
  (value try-mkdir)
  (value try-mkdir-if-missing)
  (value try-remove-file)
  (value try-remove-dir)
  (value try-rename)
  (value try-file-kind)
  (value fs-file-kind-regular?)
  (value fs-file-kind-directory?)
  (value fs-file-kind-other?)
  (value fs-metadata-kind)
  (value fs-metadata-size)
  (value try-file-metadata)
  (value fs-read-dir-split-vec)
  (value fs-read-dir-split)
  (value try-read-dir-vec)
  (value try-read-dir)
  (value try-remove-file-if-exists)
  (value try-remove-dir-if-exists)
  (value fs-temp-root)
  (value try-current-dir)
  (value fs-temp-name)
  (value fs-create-temp-dir-loop)
  (value try-create-temp-dir)
  (type ResultIoStringList)
  (type ResultIoStringVec)
  (type FsFileMetadataProbe)
  (type FsFileKind)
  (type FsMetadata)
  (type ResultFsFileKind)
  (type ResultFsMetadata)
  (constructor FsFileMetadataProbe)
  (constructor FsMetadata)
  (field FsFileMetadataProbe status)
  (field FsFileMetadataProbe kind)
  (field FsFileMetadataProbe size)
  (field FsMetadata kind)
  (field FsMetadata size)
  (variant OkIoStringList)
  (variant ErrIoStringList)
  (variant OkIoStringVec)
  (variant ErrIoStringVec)
  (variant FsFileRegular)
  (variant FsFileDirectory)
  (variant FsFileOther)
  (variant OkFsFileKind)
  (variant ErrFsFileKind)
  (variant OkFsMetadata)
  (variant ErrFsMetadata)
  (macro fs-path-join-many))