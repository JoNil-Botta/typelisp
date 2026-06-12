;# File I/O utility library for TypeLisp (#702).
;#
;# Provides file, argv, panic, and stdio helpers through direct extern bindings
;# to platform FFI symbols plus low-level language forms for argv and raw bytes.
;#
;# Public platform-facing functions such as `print-string`, `panic`, `arg`,
;# `read-file`, `write-file`, file-handle status helpers, and stdin/stdout
;# helpers are stdlib definitions in this module. Programs must import this module
;# to use them.
;#
;# The `try-*` helpers return explicit monomorphic result enums. Host errors
;# are reported through status-code primitives and mapped into `IoError`.
;#
;# Usage: `(import "stdlib/io.tl")`
;#
;# ```typelisp
;# (import "stdlib/io.tl")
;# (define fallback : ResultIoString
;#   (let [path : String "missing-file-for-docs.txt"] (try-read-file (& path))))
;# ```
;#
;# ```typelisp
;# (import "stdlib/io.tl")
;# (define empty-read : StdinRead (stdin-read-bytes 0))
;# ```
;#
;# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stdout: literal:hello from io\n
;# (import "stdlib/io.tl")
;# (define (main) : i64
;#   (begin
;#     (let [text : String "hello from io\n"] (stdout-write (& text)))
;#     0))
;# ```
(import "core_macros.tl" module stdlib.core_macros as core)

(import "string.tl")

;: Private errno-style status slot used by stdlib IO/FS helpers. This is not
;: libc errno; it preserves the previous backend-owned slot semantics in TL.
(define io-private-error-code : i64
  0)

;: Store the current private errno-style status code.
(define (io-set-error-code [code : i64]) : unit
  (begin
    (set! io-private-error-code code)
    unit))

;: Windows kernel32 bindings backing the file-IO primitives (#2142 slice 1).
;: These replace the former backend-emitted `_open`/`_read`/`_write`/`_close`/
;: `_lseeki64`/`_access` CRT-ABI shims: the TypeLisp bodies below call kernel32
;: directly, mirroring how the Linux side issues raw syscalls.
(cfg
  windows
  (extern (io-win-get-std-handle [arg0 : i32]) : i64 (:symbol "GetStdHandle")))

(cfg
  windows
  (extern (io-win-write-file
    [arg0 : i64]
    [arg1 : (Ptr u8)]
    [arg2 : i32]
    [arg3 : (MutPtr i32)]
    [arg4 : i64]) : i32 (:symbol "WriteFile")))

(cfg
  windows
  (extern (io-win-read-file
    [arg0 : i64]
    [arg1 : (MutPtr u8)]
    [arg2 : i32]
    [arg3 : (MutPtr i32)]
    [arg4 : i64]) : i32 (:symbol "ReadFile")))

(cfg
  windows
  (extern (io-win-create-file
    [arg0 : (Ptr u8)]
    [arg1 : i64]
    [arg2 : i64]
    [arg3 : i64]
    [arg4 : i64]
    [arg5 : i64]
    [arg6 : i64]) : i64 (:symbol "CreateFileA")))

(cfg
  windows
  (extern (io-win-close-handle [arg0 : i64]) : i32 (:symbol "CloseHandle")))

(cfg
  windows
  (extern (io-win-set-file-pointer-ex
    [arg0 : i64]
    [arg1 : i64]
    [arg2 : (MutPtr i64)]
    [arg3 : i32]) : i32 (:symbol "SetFilePointerEx")))

(cfg
  windows
  (extern (io-win-get-file-attributes [arg0 : (Ptr u8)]) : i32 (:symbol "GetFileAttributesA")))

(cfg windows (extern (io-win-get-last-error) : i32 (:symbol "GetLastError")))

;: Map a stdio fd (0/1/2) to its Windows standard handle; other fd values are
;: already kernel32 handles and pass through. Matches the former `_write` shim.
(cfg
  windows
  (define (io-windows-fd-handle [fd : i32]) : i64
    (core/cond
      (= fd (cast 0 : i32))
      (io-win-get-std-handle (cast -10 : i32))
      (= fd (cast 1 : i32))
      (io-win-get-std-handle (cast -11 : i32))
      (= fd (cast 2 : i32))
      (io-win-get-std-handle (cast -12 : i32))
      (cast fd : i64))))

;: Windows `_write` replacement via WriteFile; returns bytes written or -1.
(cfg
  windows
  (define (io-windows-write [fd : i32] [buf : (Ptr u8)] [count : i32]) : i32
    (let
      [handle : i64 (io-windows-fd-handle fd)]
      [written : (Array i32) (make-array i32 1)]
      [ok : i32
        (io-win-write-file
          handle
          buf
          count
          (unsafe
            (ptr-cast (array-data written) : (MutPtr i32)))
          0)]
      (if (= ok (cast 0 : i32))
        (cast -1 : i32)
        (array-ref written 0)))))

;: Windows `_read` replacement via ReadFile; a broken pipe (error 109) is EOF.
(cfg
  windows
  (define (io-windows-read [fd : i32] [buf : (MutPtr u8)] [count : i32]) : i32
    (let
      [handle : i64 (io-windows-fd-handle fd)]
      [nread : (Array i32) (make-array i32 1)]
      [ok : i32
        (io-win-read-file
          handle
          buf
          count
          (unsafe
            (ptr-cast (array-data nread) : (MutPtr i32)))
          0)]
      (if (= ok (cast 0 : i32))
        (if (= (io-win-get-last-error) (cast 109 : i32))
          (cast 0 : i32)
          (cast -1 : i32))
        (array-ref nread 0)))))

;: Windows `_close` replacement: std handles (fd 0/1/2) are a no-op, else
;: CloseHandle. Always reports success, matching the former shim.
(cfg
  windows
  (define (io-windows-close [fd : i32]) : i32
    (if (<= fd (cast 2 : i32))
      (cast 0 : i32)
      (begin
        (io-win-close-handle (cast fd : i64))
        (cast 0 : i32)))))

;: Windows `_lseeki64` replacement via SetFilePointerEx; returns offset or -1.
(cfg
  windows
  (define (io-windows-lseek [fd : i32] [offset : i64] [whence : i32]) : i64
    (let
      [handle : i64 (io-windows-fd-handle fd)]
      [newpos : (Array i64) (make-array i64 1)]
      [ok : i32
        (io-win-set-file-pointer-ex
          handle
          offset
          (unsafe
            (ptr-cast (array-data newpos) : (MutPtr i64)))
          whence)]
      (if (= ok (cast 0 : i32))
        -1
        (array-ref newpos 0)))))

;: Windows `_open` replacement via CreateFileA, translating the POSIX-style
;: open flags (O_APPEND/O_RDWR/O_WRONLY, O_CREAT/O_TRUNC) into the kernel32
;: desired-access and creation-disposition the former shim used. `mode` is
;: unused (files are created with FILE_ATTRIBUTE_NORMAL), matching the shim.
(cfg
  windows
  (define (io-windows-open [path : (Ptr u8)] [flags : i32] [mode : i32]) : i32
    (let
      [ignore-mode : i32 mode]
      [f : i64 (cast flags : i64)]
      [access : i64
        (if (= (bit-and f 0x8) 0)
          (if (= (bit-and f 0x2) 0)
            (if (= (bit-and f 0x1) 0)
              0x80000000
              0x40000000)
            0xc0000000)
          0x4)]
      [disp : i64
        (if (= (bit-and f 0x100) 0)
          (if (= (bit-and f 0x200) 0)
            3
            5)
          (if (= (bit-and f 0x200) 0)
            4
            2))]
      [handle : i64 (io-win-create-file path access 0x3 0 disp 0x80 0)]
      (if (= handle -1)
        (begin
          (io-set-error-code 2)
          (cast -1 : i32))
        (cast handle : i32)))))

;: Windows `_access` replacement via GetFileAttributesA existence probe.
(cfg
  windows
  (define (io-windows-access [path : (Ptr u8)] [mode : i32]) : i32
    (let
      [ignore-mode : i32 mode]
      (if (= (io-win-get-file-attributes path) (cast -1 : i32))
        (begin
          (io-set-error-code 2)
          (cast -1 : i32))
        (cast 0 : i32)))))

;: Windows process exit via kernel32 ExitProcess; never returns. Replaces the
;: former backend `exit` CRT-ABI shim (#2142 slice 1).
(cfg
  windows
  (extern (io-win-exit-process [arg0 : i32]) : never (:symbol "ExitProcess")))

(cfg
  windows
  (define (io-windows-exit [code : i32]) : never
    (io-win-exit-process code)))

;: Runtime allocator binding used to allocate raw handle tables.
(extern (io-runtime-alloc [arg0 : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

;: Runtime binding to create a fresh independent arena for the handle tables.
(extern (io-arena-make) : i64 (:symbol "tl_arena_make"))

;: Runtime binding for the current active arena handle.
(extern (io-arena-current) : i64 (:symbol "tl_arena_current"))

;: Runtime binding to switch the active arena.
(extern (io-arena-set [arg0 : i64]) : unit (:symbol "tl_arena_set"))

;: Maximum number of stdlib file handles tracked by the raw handle table.
(define io-file-handle-cap : i64
  1024)

;: Next stdlib file handle id to allocate.
(define io-file-handle-next : i64
  1)

;: Integer address of the file descriptor table, initialized lazily.
(define io-file-fds-addr : u64
  (cast 0 : u64))

;: Integer address of the file mode table, initialized lazily.
(define io-file-modes-addr : u64
  (cast 0 : u64))

;: Integer address of the file handle state table, initialized lazily.
(define io-file-states-addr : u64
  (cast 0 : u64))

;: Integer address of the file EOF state table, initialized lazily.
(define io-file-eofs-addr : u64
  (cast 0 : u64))

;: Integer address of the cached-read readiness table, initialized lazily.
(define io-file-last-ready-addr : u64
  (cast 0 : u64))

;: Integer address of the cached-read byte table, initialized lazily.
(define io-file-last-bytes-addr : u64
  (cast 0 : u64))

;: Return the raw file descriptor table pointer.
(define (io-file-fds-ptr) : (MutPtr i64)
  (unsafe
    (int->ptr io-file-fds-addr : (MutPtr i64))))

;: Return the raw file mode table pointer.
(define (io-file-modes-ptr) : (MutPtr i64)
  (unsafe
    (int->ptr io-file-modes-addr : (MutPtr i64))))

;: Return the raw file handle state table pointer.
(define (io-file-states-ptr) : (MutPtr i64)
  (unsafe
    (int->ptr io-file-states-addr : (MutPtr i64))))

;: Return the raw file EOF state table pointer.
(define (io-file-eofs-ptr) : (MutPtr bool)
  (unsafe
    (int->ptr io-file-eofs-addr : (MutPtr bool))))

;: Return the raw cached-read readiness table pointer.
(define (io-file-last-ready-ptr) : (MutPtr bool)
  (unsafe
    (int->ptr io-file-last-ready-addr : (MutPtr bool))))

;: Return the raw cached-read byte table pointer.
(define (io-file-last-bytes-ptr) : (MutPtr String)
  (unsafe
    (int->ptr io-file-last-bytes-addr : (MutPtr String))))

;: Convert a mutable byte pointer into an integer address for global storage.
(define (io-file-ptr-addr [ptr : (MutPtr u8)]) : u64
  (unsafe
    (ptr->int (ptr-cast ptr : (Ptr u8)))))

;: Read an i64 from a raw table at `index`.
(define (io-file-i64-ref [items : (MutPtr i64)] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (ptr-offset items index) : (Ptr i64)))))

;: Write an i64 to a raw table at `index`.
(define (io-file-i64-set! [items : (MutPtr i64)] [index : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset items index) value)))

;: Read a bool from a raw table at `index`.
(define (io-file-bool-ref [items : (MutPtr bool)] [index : i64]) : bool
  (unsafe
    (ptr-read (ptr-cast (ptr-offset items index) : (Ptr bool)))))

;: Write a bool to a raw table at `index`.
(define (io-file-bool-set! [items : (MutPtr bool)] [index : i64] [value : bool]) : unit
  (unsafe
    (ptr-write! (ptr-offset items index) value)))

;: Read a String from a raw table at `index`.
(define (io-file-string-ref [items : (MutPtr String)] [index : i64]) : String
  (unsafe
    (ptr-read (ptr-cast (ptr-offset items index) : (Ptr String)))))

;: Write a String to a raw table at `index`.
(define (io-file-string-set!
  [items : (MutPtr String)]
  [index : i64]
  [value : String]) : unit
  (unsafe
    (ptr-write! (ptr-offset items index) value)))

;; #2357: the table pointers are stored as raw integer addresses the region
;; checker cannot see, and this init can fire inside a (with-arena ...) region
;; (the batch compile driver scopes each entry). Allocate the tables in a
;; dedicated persistent arena so a region reset cannot reclaim them; the
;; active arena is restored before returning.
;: Lazily allocate and zero the raw file-handle tables in a persistent arena.
(define (io-file-table-init!) : unit
  (if (= io-file-fds-addr (cast 0 : u64))
    (let
      [table-arena : i64 (io-arena-make)]
      [prev-arena : i64 (io-arena-current)]
      [switched : unit
        (unsafe
          (io-arena-set table-arena))]
      [fds : (MutPtr i64)
        (unsafe
          (ptr-cast (io-runtime-alloc 8192) : (MutPtr i64)))]
      [modes : (MutPtr i64)
        (unsafe
          (ptr-cast (io-runtime-alloc 8192) : (MutPtr i64)))]
      [states : (MutPtr i64)
        (unsafe
          (ptr-cast (io-runtime-alloc 8192) : (MutPtr i64)))]
      [eofs : (MutPtr bool)
        (unsafe
          (ptr-cast (io-runtime-alloc 1024) : (MutPtr bool)))]
      [last-ready : (MutPtr bool)
        (unsafe
          (ptr-cast (io-runtime-alloc 1024) : (MutPtr bool)))]
      [last-bytes : (MutPtr String)
        (unsafe
          (ptr-cast (io-runtime-alloc 16384) : (MutPtr String)))]
      [restored : unit
        (unsafe
          (io-arena-set prev-arena))]
      [i : i64 0]
      (begin
        (set!
          io-file-fds-addr
          (io-file-ptr-addr
            (unsafe
              (ptr-cast fds : (MutPtr u8)))))
        (set!
          io-file-modes-addr
          (io-file-ptr-addr
            (unsafe
              (ptr-cast modes : (MutPtr u8)))))
        (set!
          io-file-states-addr
          (io-file-ptr-addr
            (unsafe
              (ptr-cast states : (MutPtr u8)))))
        (set!
          io-file-eofs-addr
          (io-file-ptr-addr
            (unsafe
              (ptr-cast eofs : (MutPtr u8)))))
        (set!
          io-file-last-ready-addr
          (io-file-ptr-addr
            (unsafe
              (ptr-cast last-ready : (MutPtr u8)))))
        (set!
          io-file-last-bytes-addr
          (io-file-ptr-addr
            (unsafe
              (ptr-cast last-bytes : (MutPtr u8)))))
        (while (< i io-file-handle-cap)
          (begin
            (io-file-i64-set! (io-file-fds-ptr) i 0)
            (io-file-i64-set! (io-file-modes-ptr) i 0)
            (io-file-i64-set! (io-file-states-ptr) i 0)
            (io-file-bool-set! (io-file-eofs-ptr) i false)
            (io-file-bool-set! (io-file-last-ready-ptr) i false)
            (set! i (+ i 1))))
        unit))
    unit))

;: Sticky EOF state for stdin chunk reads.
(define io-stdin-eof-state : bool
  false)

;: Copy `text` into a NUL-terminated byte array for C library calls.
(define (io-c-string [text : String]) : (Array u8)
  (let
    [n : i64 (string-length text)]
    [buf : (Array u8) (make-array u8 (+ n 1))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! buf i (cast (string-ref text i) : u8))
          (set! i (+ i 1))))
      (array-set! buf n (cast #\nul' : u8))
      buf)))

;: Return a mutable pointer to an Array u8 backing buffer.
(define (io-array-ptr [buf : (Array u8)]) : (MutPtr u8)
  (unsafe
    (array-data buf)))

;: Return a const pointer to an Array u8 backing buffer.
(define (io-array-const-ptr [buf : (Array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (array-data buf) : (Ptr u8))))

;: Return a const pointer to a String's byte storage.
(define (io-string-data [text : String]) : (Ptr u8)
  (unsafe
    (string-data text)))

;: Copy a NUL-terminated C string into an owned TypeLisp String.
(define (io-copy-c-string [ptr : (Ptr u8)]) : String
  (let
    [n : i64 (io-c-string-length ptr)]
    [buf : (Array u8) (make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set!
            buf
            i
            (unsafe
              (ptr-read (ptr-offset ptr i))))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (io-array-const-ptr buf) n)))))

;: Return the byte length of a NUL-terminated C string.
(define (io-c-string-length [ptr : (Ptr u8)]) : i64
  (let
    [n : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (if (=
          (cast
            (unsafe
              (ptr-read (ptr-offset ptr n)))
            : i64)
          0)
          (set! done true)
          (set! n (+ n 1))))
      n)))

;: Return the current private errno-style status value as an i64.
(define (io-last-error-code) : i64
  io-private-error-code)

;: Translate a raw Linux syscall return into libc `-1` + `errno` semantics.
;: Syscalls report errors as a small negative `-errno` in `[-4095, -1]`; the
;: stdlib reads the private error slot through `io-last-error-code`, so failures
;: are surfaced by storing `errno` and returning `-1`, matching the former asm
;: shim.
(define (io-linux-syscall-status [result : i64]) : i64
  (if (and (>= result -4095) (< result 0))
    (begin
      (io-set-error-code (- 0 result))
      -1)
    result))

;: Convert a read-only byte pointer into an integer syscall argument.
(define (io-linux-ptr-arg [ptr : (Ptr u8)]) : i64
  (unsafe
    (cast (ptr->int ptr) : i64)))

;: Linux `open` via the `openat`-style `open` syscall (number 2).
(define (io-linux-syscall-open [path : (Ptr u8)] [flags : i64] [mode : i64]) : i64
  (cfg
    windows
    -1
    (io-linux-syscall-status (syscall 2 (io-linux-ptr-arg path) flags mode))))

;: Linux `read` via the `read` syscall (number 0).
(define (io-linux-syscall-read [fd : i64] [buf : (MutPtr u8)] [count : i64]) : i64
  (cfg
    windows
    -1
    (io-linux-syscall-status
      (syscall
        0
        fd
        (io-linux-ptr-arg
          (unsafe
            (ptr-cast buf : (Ptr u8))))
        count))))

;: Linux `write` via the `write` syscall (number 1).
(define (io-linux-syscall-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg
    windows
    -1
    (io-linux-syscall-status (syscall 1 fd (io-linux-ptr-arg buf) count))))

;: Linux `close` via the `close` syscall (number 3).
(define (io-linux-syscall-close [fd : i64]) : i64
  (cfg windows -1 (io-linux-syscall-status (syscall 3 fd))))

;: Linux `lseek` via the `lseek` syscall (number 8).
(define (io-linux-syscall-lseek [fd : i64] [offset : i64] [whence : i64]) : i64
  (cfg windows -1 (io-linux-syscall-status (syscall 8 fd offset whence))))

;: Linux `access` via the `access` syscall (number 21).
(define (io-linux-syscall-access [path : (Ptr u8)] [mode : i64]) : i64
  (cfg
    windows
    -1
    (io-linux-syscall-status (syscall 21 (io-linux-ptr-arg path) mode))))

;: Linux process exit via the `exit_group` syscall (number 231); never returns.
;: The tail call is unreachable at runtime (the syscall terminates the process)
;: and only gives the body its `never` type.
(define (io-linux-exit [code : i64]) : never
  (cfg
    windows
    (io-windows-exit (cast code : i32))
    (begin
      (syscall 231 code)
      (io-linux-exit code))))

;: Dispatch a platform process exit; never returns.
(define (io-platform-exit [code : i64]) : never
  (cfg windows (io-windows-exit (cast code : i32)) (io-linux-exit code)))

;: Dispatch a platform `open` call and return its file descriptor or negative status.
(define (io-platform-open [path : (Ptr u8)] [flags : i64] [mode : i64]) : i64
  (cfg
    windows
    (cast (io-windows-open path (cast flags : i32) (cast mode : i32)) : i64)
    (io-linux-syscall-open path flags mode)))

;: Dispatch a platform `read` call and return its byte count or negative status.
(define (io-platform-read [fd : i64] [buf : (MutPtr u8)] [count : i64]) : i64
  (cfg
    windows
    (cast (io-windows-read (cast fd : i32) buf (cast count : i32)) : i64)
    (io-linux-syscall-read fd buf count)))

;: Dispatch a platform `write` call and return its byte count or negative status.
(define (io-platform-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg
    windows
    (cast (io-windows-write (cast fd : i32) buf (cast count : i32)) : i64)
    (io-linux-syscall-write fd buf count)))

;: Dispatch a platform `close` call and return zero or negative status.
(define (io-platform-close [fd : i64]) : i64
  (cfg
    windows
    (cast (io-windows-close (cast fd : i32)) : i64)
    (io-linux-syscall-close fd)))

;: Dispatch a platform seek call and return the resulting offset or negative status.
(define (io-platform-lseek [fd : i64] [offset : i64] [whence : i64]) : i64
  (cfg
    windows
    (io-windows-lseek (cast fd : i32) offset (cast whence : i32))
    (io-linux-syscall-lseek fd offset whence)))

;: Dispatch a platform existence/access probe and return zero or negative status.
(define (io-platform-access [path : (Ptr u8)] [mode : i64]) : i64
  (cfg
    windows
    (cast (io-windows-access path (cast mode : i32)) : i64)
    (io-linux-syscall-access path mode)))

;: Return platform flags for opening a path read-only.
(define (io-open-read-flags) : i64
  (cfg windows 32768 0))

;: Return platform flags for opening a path write-only with truncation.
(define (io-open-write-truncate-flags) : i64
  (cfg windows 33537 577))

;: Return platform flags for opening a path write-only with append semantics.
(define (io-open-write-append-flags) : i64
  (cfg windows 33033 1089))

;: Return platform permissions for creating files.
(define (io-open-mode) : i64
  384)

;: Return platform open flags for stdlib file mode `mode`.
(define (io-open-flags-for-mode [mode : i64]) : i64
  (core/cond
    (= mode 0)
    (io-open-read-flags)
    (= mode 1)
    (io-open-write-truncate-flags)
    (io-open-write-append-flags)))

;: Return `code` as a negative status value.
(define (io-neg-status [code : i64]) : i64
  (- 0 code))

;: Write all bytes from `data` to `fd`, returning a host status code.
(define (io-write-all-fd-status [fd : i64] [data : (Ptr u8)] [len : i64]) : i64
  (let
    [offset : i64 0]
    [status : i64 0]
    (begin
      (while (and (= status 0) (< offset len))
        (let
          [written : i64
            (io-platform-write
              fd
              (unsafe
                (ptr-offset data offset))
              (- len offset))]
          (if (< written 0)
            (set! status (io-last-error-code))
            (if (= written 0)
              (set! status 5)
              (set! offset (+ offset written))))))
      status)))

;: Write a whole String to `fd`, returning a host status code.
(define (io-write-string-fd-status [fd : i64] [text : String]) : i64
  (io-write-all-fd-status fd (io-string-data text) (string-length text)))

;: Write a string to stdout without adding a newline.
(define (print-string [text : String]) : unit
  (let
    [status : i64 (io-write-string-fd-status 1 text)]
    (if (= status 0)
      unit
      (io-platform-exit 134))))

;: Compatibility alias for `print-string`.
(define (print-str [text : String]) : unit
  (print-string text))

;: Write a trailing newline to stdout.
(define (print-newline) : unit
  (print-string "\n"))

;: Write an integer followed by a newline.
(define (print [value : i64]) : unit
  (begin
    (print-string (int->string value))
    (print-newline)))

;: Write a boolean followed by a newline.
(define (print-bool [value : bool]) : unit
  (if value
    (print-string "true\n")
    (print-string "false\n")))

;: Write one character byte to stdout without adding a newline.
(define (print-char [ch : char]) : unit
  (let
    [buf : (Array u8) (make-array u8 1)]
    (begin
      (array-set! buf 0 (cast ch : u8))
      (if (= (io-write-all-fd-status 1 (io-array-const-ptr buf) 1) 0)
        unit
        (io-platform-exit 134)))))

;: Fixed-capacity base-2^32 bignum backing the pure-TL f64 formatter.
(defstruct BigNum
  (limbs (Array u64))
  (len i64))

;: Limb capacity of formatter bignum scratch buffers.
(define ftoa-cap : i64
  96)

;: Low 32-bit mask isolating a base-2^32 limb.
(define ftoa-mask32 : u64
  (cast 0xffffffff : u64))

;: A zero-valued BigNum.
(define (bn-zero) : BigNum
  (BigNum (make-array u64 ftoa-cap) 0))

;: BigNum holding the u64 value x.
(define (bn-from-u64 [x : u64]) : BigNum
  (let
    [r : BigNum (bn-zero)]
    [lo : u64 (bit-and x ftoa-mask32)]
    [hi : u64 (shr x 32)]
    (begin
      (array-set! (struct-get r limbs) 0 lo)
      (array-set! (struct-get r limbs) 1 hi)
      (core/cond
        (> hi (cast 0 : u64))
        (BigNum (struct-get r limbs) 2)
        (> lo (cast 0 : u64))
        (BigNum (struct-get r limbs) 1)
        (BigNum (struct-get r limbs) 0)))))

;: Compare BigNums a and b; -1 if a<b, 0 if equal, 1 if a>b.
(define (bn-cmp [a : BigNum] [b : BigNum]) : i64
  (let
    [la : i64 (struct-get a len)]
    [lb : i64 (struct-get b len)]
    (if (> la lb)
      1
      (if (< la lb)
        -1
        (let
          [i : i64 (- la 1)]
          [res : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (>= i 0))
              (let
                [av : u64 (array-ref (struct-get a limbs) i)]
                [bv : u64 (array-ref (struct-get b limbs) i)]
                (begin
                  (core/cond
                    (> av bv)
                    (begin
                      (set! res 1)
                      (set! done true))
                    (< av bv)
                    (begin
                      (set! res -1)
                      (set! done true))
                    unit)
                  (set! i (- i 1)))))
            res))))))

;: Limb count of arr with high zero limbs trimmed, starting from hint.
(define (bn-norm-len [arr : (Array u64)] [hint : i64]) : i64
  (let
    [i : i64 hint]
    (begin
      (while (and (> i 0) (= (array-ref arr (- i 1)) (cast 0 : u64)))
        (set! i (- i 1)))
      i)))

;: Sum of BigNums a and b.
(define (bn-add [a : BigNum] [b : BigNum]) : BigNum
  (let
    [r : (Array u64) (make-array u64 ftoa-cap)]
    [la : i64 (struct-get a len)]
    [lb : i64 (struct-get b len)]
    [n : i64
      (if (> la lb)
        la
        lb)]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [av : u64
            (if (< i la)
              (array-ref (struct-get a limbs) i)
              (cast 0 : u64))]
          [bv : u64
            (if (< i lb)
              (array-ref (struct-get b limbs) i)
              (cast 0 : u64))]
          [s : u64 (+ (+ av bv) carry)]
          (begin
            (array-set! r i (bit-and s ftoa-mask32))
            (set! carry (shr s 32))
            (set! i (+ i 1)))))
      (when
        (> carry (cast 0 : u64))
        (begin
          (array-set! r i carry)
          (set! n (+ n 1))))
      (BigNum r (bn-norm-len r n)))))

;: Product of BigNum a and a value m that fits in 32 bits.
(define (bn-mul-u32 [a : BigNum] [m : u64]) : BigNum
  (let
    [r : (Array u64) (make-array u64 ftoa-cap)]
    [la : i64 (struct-get a len)]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i la)
        (let
          [p : u64 (+ (* (array-ref (struct-get a limbs) i) m) carry)]
          (begin
            (array-set! r i (bit-and p ftoa-mask32))
            (set! carry (shr p 32))
            (set! i (+ i 1)))))
      (while (> carry (cast 0 : u64))
        (begin
          (array-set! r i (bit-and carry ftoa-mask32))
          (set! carry (shr carry 32))
          (set! i (+ i 1))))
      (BigNum r (bn-norm-len r i)))))

;: BigNum a shifted left by n bits.
(define (bn-shl-bits [a : BigNum] [n : i64]) : BigNum
  (if (= (struct-get a len) 0)
    a
    (let
      [limb-shift : i64 (/ n 32)]
      [bit-shift : i64 (% n 32)]
      [r : (Array u64) (make-array u64 ftoa-cap)]
      [la : i64 (struct-get a len)]
      [carry : u64 (cast 0 : u64)]
      [i : i64 0]
      (begin
        (if (= bit-shift 0)
          (while (< i la)
            (begin
              (array-set! r (+ i limb-shift) (array-ref (struct-get a limbs) i))
              (set! i (+ i 1))))
          (while (< i la)
            (let
              [v : u64 (array-ref (struct-get a limbs) i)]
              [shifted : u64
                (bit-or (bit-and (shl v bit-shift) ftoa-mask32) carry)]
              (begin
                (array-set! r (+ i limb-shift) shifted)
                (set! carry (shr v (- 32 bit-shift)))
                (set! i (+ i 1))))))
        (when
          (and (not (= bit-shift 0)) (> carry (cast 0 : u64)))
          (array-set! r (+ la limb-shift) carry))
        (BigNum r (bn-norm-len r (+ la (+ limb-shift 1))))))))

;: Product of BigNum a and the 64-bit value m.
(define (bn-mul-u64 [a : BigNum] [m : u64]) : BigNum
  (let
    [lo : u64 (bit-and m ftoa-mask32)]
    [hi : u64 (shr m 32)]
    [low : BigNum (bn-mul-u32 a lo)]
    (if (= hi (cast 0 : u64))
      low
      (bn-add low (bn-shl-bits (bn-mul-u32 a hi) 32)))))

;: BigNum a multiplied by ten raised to p.
(define (bn-mul-pow10 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [i : i64 0]
    (begin
      (while (< i p)
        (begin
          (set! r (bn-mul-u32 r (cast 10 : u64)))
          (set! i (+ i 1))))
      r)))

;: floor(num/den) as u64, assuming the quotient fits in 60 bits.
(define (bn-div-floor-u64 [num : BigNum] [den : BigNum]) : u64
  (let
    [q : u64 (cast 0 : u64)]
    [bit : i64 59]
    (begin
      (while (>= bit 0)
        (let
          [cand : u64 (+ q (shl (cast 1 : u64) bit))]
          [prod : BigNum (bn-mul-u64 den cand)]
          (begin
            (when (<= (bn-cmp prod num) 0) (set! q cand))
            (set! bit (- bit 1)))))
      q)))

;: floor(a / b) for b > 0 (TL `/` truncates toward zero).
(define (ftoa-floor-div [a : i64] [b : i64]) : i64
  (if (>= a 0)
    (/ a b)
    (- 0 (/ (+ (- 0 a) (- b 1)) b))))

;: Index of the highest set bit of m.
(define (ftoa-msb-index [m : u64]) : i64
  (let
    [i : i64 0]
    [v : u64 m]
    (begin
      (while (> v (cast 1 : u64))
        (begin
          (set! v (shr v 1))
          (set! i (+ i 1))))
      i)))

;: Significant-digit string of `d` with trailing zeros removed (>= 1 digit).
(define (ftoa-strip-zeros [d : i64]) : String
  (let
    [dd : i64 d]
    (begin
      (while (and (> dd 9) (= (% dd 10) 0))
        (set! dd (/ dd 10)))
      (int->string dd))))

;: Exponent k formatted with sign and at least two digits.
(define (ftoa-pad-exp [k : i64]) : String
  (let
    [mag : i64
      (if (< k 0)
        (- 0 k)
        k)]
    [digits : String (int->string mag)]
    [sign : String
      (if (< k 0)
        "-"
        "+")]
    (string-append
      sign
      (if (< (string-length digits) 2)
        (string-append "0" digits)
        digits))))

;: A string of n zero characters.
(define (ftoa-zeros [n : i64]) : String
  (let
    [s : String ""]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! s (string-append s "0"))
          (set! i (+ i 1))))
      s)))

;: Format significant-digit string `s` whose leading digit has decimal
;: exponent `k`, following printf %g (precision 17) style.
(define (ftoa-render [neg : bool] [s : String] [k : i64]) : String
  (let
    [body : String ""]
    [ndig : i64 (string-length s)]
    (begin
      (core/cond
        (or (< k -4) (>= k 17))
        (set!
          body
          (string-append
            (substring s 0 1)
            (string-append
              (if (> ndig 1)
                (string-append "." (substring s 1 (- ndig 1)))
                "")
              (string-append "e" (ftoa-pad-exp k)))))
        (< k 0)
        (set!
          body
          (string-append "0." (string-append (ftoa-zeros (- (- 0 k) 1)) s)))
        (>= (+ k 1) ndig)
        (set! body (string-append s (ftoa-zeros (- (+ k 1) ndig))))
        (set!
          body
          (string-append
            (substring s 0 (+ k 1))
            (string-append "." (substring s (+ k 1) (- ndig (+ k 1)))))))
      (if neg
        (string-append "-" body)
        body))))

;: Render value as a shortest round-tripping decimal string (printf %.17g style).
(define (io-format-float-core [value : f64]) : String
  (let
    [buf : (Array f64) (make-array f64 1)]
    [bits : u64 (cast 0 : u64)]
    (begin
      (array-set! buf 0 value)
      (set!
        bits
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr u64)))))
      (let
        [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
        [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
        [frac : u64 (bit-and bits (cast 0xfffffffffffff : u64))]
        (core/cond
          (= expf (cast 0x7ff : u64))
          (if (= frac (cast 0 : u64))
            (if neg
              "-inf"
              "inf")
            (if neg
              "-nan"
              "nan"))
          (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
          (if neg
            "-0"
            "0")
          (let
            [m : u64
              (if (= expf (cast 0 : u64))
                frac
                (bit-or frac (cast 0x10000000000000 : u64)))]
            [e2 : i64
              (if (= expf (cast 0 : u64))
                -1074
                (- (cast expf : i64) 1075))]
            [msb : i64 (ftoa-msb-index m)]
            [kest : i64 (ftoa-floor-div (* (+ msb e2) 30103) 100000)]
            [d : u64 (cast 0 : u64)]
            [iters : i64 0]
            [settled : bool false]
            (begin
              (while (and (not settled) (< iters 6))
                (let
                  [p : i64 (- 16 kest)]
                  [num : BigNum (bn-from-u64 m)]
                  [den : BigNum (bn-from-u64 (cast 1 : u64))]
                  (begin
                    (if (>= e2 0)
                      (set! num (bn-shl-bits num e2))
                      (set! den (bn-shl-bits den (- 0 e2))))
                    (if (>= p 0)
                      (set! num (bn-mul-pow10 num p))
                      (set! den (bn-mul-pow10 den (- 0 p))))
                    (let
                      [q : u64 (bn-div-floor-u64 num den)]
                      [two-num : BigNum (bn-shl-bits num 1)]
                      [t : BigNum
                        (bn-mul-u64 den (+ (* (cast 2 : u64) q) (cast 1 : u64)))]
                      [c : i64 (bn-cmp two-num t)]
                      (begin
                        (set! d q)
                        (core/cond
                          (> c 0)
                          (set! d (+ q (cast 1 : u64)))
                          (= c 0)
                          (when
                            (= (bit-and q (cast 1 : u64)) (cast 1 : u64))
                            (set! d (+ q (cast 1 : u64))))
                          unit)
                        (core/cond
                          (>= d (cast 100000000000000000 : u64))
                          (set! kest (+ kest 1))
                          (< d (cast 10000000000000000 : u64))
                          (set! kest (- kest 1))
                          (set! settled true))
                        (set! iters (+ iters 1)))))))
              (let
                [s0 : String (int->string (cast d : i64))]
                [k : i64 (+ (- (string-length s0) 17) kest)]
                (ftoa-render neg (ftoa-strip-zeros (cast d : i64)) k)))))))))

;: Format an f64 with `%.17g` and a trailing newline.
(define (io-format-float [value : f64]) : String
  (string-append (io-format-float-core value) "
"))

;: Write a floating-point value to stdout using `%.17g` plus a newline.
(define (print-float [value : f64]) : unit
  (print-string (io-format-float value)))

;: Write a string to stderr without adding a newline.
(define (print-error [text : String]) : unit
  (let
    [status : i64 (io-write-string-fd-status 2 text)]
    (if (= status 0)
      unit
      (io-platform-exit 134))))

;: Abort the process after writing `message` to stderr.
(define (panic [message : String]) : never
  (begin
    (print-error message)
    (io-platform-exit 134)))

;: Alias for `panic`.
(define (error [message : String]) : never
  (panic message))

;: Return the number of process argv entries.
(define (arg-count) : i64
  (program-argc))

;: Return argv entry `index`, aborting on out-of-range indices.
(define (arg [index : i64]) : String
  (if (< index 0)
    (panic "tl: argv index out of bounds\n")
    (if (>= index (arg-count))
      (panic "tl: argv index out of bounds\n")
      (let
        [argv : (Ptr (Ptr u8))
          (unsafe
            (program-argv))]
        [raw : (Ptr u8)
          (unsafe
            (ptr-read (ptr-offset argv index)))]
        (io-copy-c-string raw)))))

;: Read the entire seekable descriptor `fd` into a String.
(define (io-read-fd-to-string [fd : i64]) : String
  (let
    [end : i64 (io-platform-lseek fd 0 2)]
    (if (< end 0)
      (panic "tl: read-file failed\n")
      (begin
        (if (< (io-platform-lseek fd 0 0) 0)
          (panic "tl: read-file failed\n")
          unit)
        (let
          [buf : (Array u8) (make-array u8 end)]
          [offset : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (< offset end))
              (let
                [read-count : i64
                  (io-platform-read
                    fd
                    (unsafe
                      (ptr-offset (io-array-ptr buf) offset))
                    (- end offset))]
                (if (< read-count 0)
                  (panic "tl: read-file failed\n")
                  (if (= read-count 0)
                    (set! done true)
                    (set! offset (+ offset read-count))))))
            (unsafe
              (string-from-bytes (io-array-const-ptr buf) offset))))))))

;: Return the host status code for reading `path`.
(define (read-file-status [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64
      (io-platform-open (io-array-const-ptr path-bytes) (io-open-read-flags) 0)]
    (if (< fd 0)
      (io-last-error-code)
      (let
        [probe : (Array u8) (make-array u8 1)]
        [read-count : i64 (io-platform-read fd (io-array-ptr probe) 1)]
        [status : i64
          (if (< read-count 0)
            (io-last-error-code)
            0)]
        (begin
          (io-platform-close fd)
          status)))))

;: Read a whole file, aborting on host read failure.
(define (read-file [path : String]) : String
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64
      (io-platform-open (io-array-const-ptr path-bytes) (io-open-read-flags) 0)]
    (if (< fd 0)
      (panic "tl: read-file failed\n")
      (let
        [contents : String (io-read-fd-to-string fd)]
        (begin
          (io-platform-close fd)
          contents)))))

;: Write `contents` to `path` using platform `flags`, returning a host status code.
(define (io-write-path-status [path : String] [contents : String] [flags : i64]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [fd : i64
      (io-platform-open (io-array-const-ptr path-bytes) flags (io-open-mode))]
    (if (< fd 0)
      (io-last-error-code)
      (let
        [status : i64 (io-write-string-fd-status fd contents)]
        [close-status : i64 (io-platform-close fd)]
        (if (= status 0)
          (if (< close-status 0)
            (io-last-error-code)
            0)
          status)))))

;: Return the host status code for writing `contents` to `path`.
(define (write-file-status [path : String] [contents : String]) : i64
  (io-write-path-status path contents (io-open-write-truncate-flags)))

;: Render the raw `write-file` panic payload with path and host status.
(define (write-file-failure-message [path : String] [status : i64]) : String
  (string-append
    "tl: write-file failed: "
    (string-append
      (io-error-message (io-error-from-owned-status path status))
      "\n")))

;: Write a whole file, aborting on host write failure.
(define (write-file [path : String] [contents : String]) : unit
  (let
    [status : i64 (write-file-status path contents)]
    (if (= status 0)
      unit
      (panic (write-file-failure-message path status)))))

;: Return the host status code for appending `contents` to `path`.
(define (append-file-status [path : String] [contents : String]) : i64
  (io-write-path-status path contents (io-open-write-append-flags)))

;: Return the host status code for probing `path`.
(define (file-exists-status [path : String]) : i64
  (let
    [path-bytes : (Array u8) (io-c-string path)]
    [status : i64 (io-platform-access (io-array-const-ptr path-bytes) 0)]
    (if (= status 0)
      0
      (io-last-error-code))))

;: Return true when `path` exists, aborting on hard host probe failure.
(define (file-exists? [path : String]) : bool
  (let
    [status : i64 (file-exists-status path)]
    (if (= status 0)
      true
      (if (or (= status 2) (= status 20))
        false
        (begin
          (panic "tl: file-exists? failed\n")
          false)))))

;: Return true when `raw` names an open stdlib file handle.
(define (io-valid-handle? [raw : i64]) : bool
  (begin
    (io-file-table-init!)
    (and
      (> raw 0)
      (< raw io-file-handle-cap)
      (= (io-file-i64-ref (io-file-states-ptr) raw) 1))))

;: Return a stdlib file handle id or negative status for opening `path`.
(define (file-open-status [path : String] [mode : i64]) : i64
  (begin
    (io-file-table-init!)
    (let
      [path-bytes : (Array u8) (io-c-string path)]
      [fd : i64
        (io-platform-open
          (io-array-const-ptr path-bytes)
          (io-open-flags-for-mode mode)
          (io-open-mode))]
      (if (< fd 0)
        (io-neg-status (io-last-error-code))
        (let
          [handle : i64 io-file-handle-next]
          [handle-cap : i64 io-file-handle-cap]
          (if (>= handle handle-cap)
            (begin
              (io-platform-close fd)
              (io-neg-status 38))
            (begin
              (set! io-file-handle-next (+ handle 1))
              (io-file-i64-set! (io-file-fds-ptr) handle fd)
              (io-file-i64-set! (io-file-modes-ptr) handle mode)
              (io-file-i64-set! (io-file-states-ptr) handle 1)
              (io-file-bool-set! (io-file-eofs-ptr) handle false)
              (io-file-bool-set! (io-file-last-ready-ptr) handle false)
              handle)))))))

;: Return the host status code for closing a stdlib file handle id.
(define (file-close-status [raw : i64]) : i64
  (if (io-valid-handle? raw)
    (let
      [fd : i64 (io-file-i64-ref (io-file-fds-ptr) raw)]
      [status : i64 (io-platform-close fd)]
      (begin
        (io-file-i64-set! (io-file-states-ptr) raw 0)
        (if (< status 0)
          (io-last-error-code)
          0)))
    38))

;: Return the host status code for reading a chunk into the stdlib handle cache.
(define (file-read-chunk-status [raw : i64] [count : i64]) : i64
  (core/cond
    (not (io-valid-handle? raw))
    38
    (not (= (io-file-i64-ref (io-file-modes-ptr) raw) 0))
    38
    (< count 0)
    22
    (= count 0)
    (begin
      (io-file-string-set! (io-file-last-bytes-ptr) raw "")
      (io-file-bool-set! (io-file-last-ready-ptr) raw true)
      0)
    (let
      [buf : (Array u8) (make-array u8 count)]
      [fd : i64 (io-file-i64-ref (io-file-fds-ptr) raw)]
      [read-count : i64 (io-platform-read fd (io-array-ptr buf) count)]
      (if (< read-count 0)
        (io-last-error-code)
        (begin
          (if (= read-count 0)
            (io-file-bool-set! (io-file-eofs-ptr) raw true)
            (io-file-bool-set! (io-file-eofs-ptr) raw false))
          (io-file-string-set!
            (io-file-last-bytes-ptr)
            raw
            (unsafe
              (string-from-bytes (io-array-const-ptr buf) read-count)))
          (io-file-bool-set! (io-file-last-ready-ptr) raw true)
          0)))))

;: Return the host status code for writing `contents` through a stdlib handle.
(define (file-write-status [raw : i64] [contents : String]) : i64
  (if (not (io-valid-handle? raw))
    38
    (if (= (io-file-i64-ref (io-file-modes-ptr) raw) 0)
      38
      (io-write-string-fd-status
        (io-file-i64-ref (io-file-fds-ptr) raw)
        contents))))

;: Return the host status code for flushing a stdlib handle.
(define (file-flush-status [raw : i64]) : i64
  (if (not (io-valid-handle? raw))
    38
    (if (= (io-file-i64-ref (io-file-modes-ptr) raw) 0)
      38
      0)))

;: Return bytes from the last successful stdlib file chunk read.
(define (file-read-chunk-bytes [raw : i64]) : String
  (if (and
    (io-valid-handle? raw)
    (io-file-bool-ref (io-file-last-ready-ptr) raw))
    (io-file-string-ref (io-file-last-bytes-ptr) raw)
    ""))

;: Return the sticky EOF bit from the last successful stdlib file chunk read.
(define (file-read-chunk-eof? [raw : i64]) : bool
  (if (io-valid-handle? raw)
    (io-file-bool-ref (io-file-eofs-ptr) raw)
    true))

;: Read up to `count` bytes from stdin, continuing across positive short reads.
(define (read-stdin-bytes [count : i64]) : String
  (if (< count 0)
    (panic "tl: stdin failed\n")
    (if (= count 0)
      ""
      (let
        [buf : (Array u8) (make-array u8 count)]
        [offset : i64 0]
        [done : bool false]
        (begin
          (while (not done)
            (if (>= offset count)
              (begin
                (set! io-stdin-eof-state false)
                (set! done true))
              (let
                [read-count : i64
                  (io-platform-read
                    0
                    (unsafe
                      (ptr-offset (io-array-ptr buf) offset))
                    (- count offset))]
                (if (< read-count 0)
                  (panic "tl: stdin failed\n")
                  (if (= read-count 0)
                    (begin
                      (set! io-stdin-eof-state true)
                      (set! done true))
                    (set! offset (+ offset read-count)))))))
          (unsafe
            (string-from-bytes (io-array-const-ptr buf) offset)))))))

;: Read one stdin line without the trailing newline.
(define (read-stdin-line) : String
  (let
    [bytes : (Array u8) (make-array u8 0)]
    [one : (Array u8) (make-array u8 1)]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [read-count : i64 (io-platform-read 0 (io-array-ptr one) 1)]
          (if (< read-count 0)
            (panic "tl: stdin failed\n")
            (if (= read-count 0)
              (begin
                (set! io-stdin-eof-state true)
                (set! done true))
              (let
                [byte : u8 (array-ref one 0)]
                (if (= (cast byte : i64) 10)
                  (set! done true)
                  (begin
                    (array-push! bytes byte)
                    (set! done false))))))))
      (unsafe
        (string-from-bytes (io-array-const-ptr bytes) (array-length bytes))))))

;: Return the sticky stdin EOF state.
(define (stdin-eof?) : bool
  io-stdin-eof-state)

;: Flush stdout. The freestanding runtime writes stdout through direct,
;: unbuffered OS calls (the Linux `write` syscall, Windows `WriteFile`), so there
;: is no userspace buffer to flush — this is a genuine no-op. (Replaces the former
;: `fflush` libc shim, which was itself a no-op stub.)
(define (flush-stdout) : unit
  unit)

;: Structured file I/O failures.
;:
;: `IoSystemCode` stores a target-specific positive error code and path.
(defenum IoError
  (IoNotFound String)
  (IoPermissionDenied String)
  (IoInvalidPath String)
  (IoUnsupported String)
  (IoInterrupted String)
  (IoSystemCode i64 String)
  (IoUnknown String))

;: Result type for string-returning file I/O APIs.
(defenum ResultIoString
  (OkIoString String)
  (ErrIoString IoError))

;: Result type for unit-returning file I/O APIs.
(defenum ResultIoUnit
  (OkIoUnit)
  (ErrIoUnit IoError))

;: Result type for bool-returning file I/O APIs.
(defenum ResultIoBool
  (OkIoBool bool)
  (ErrIoBool IoError))

;: Opaque stdlib-managed file handle id.
;:
;: v1 handles must be closed explicitly with `file-close`; there is no implicit
;: drop until move-only/drop semantics land.
(defstruct FileHandle
  (id i64))

;: File open mode for v1 streaming handles.
(defenum OpenMode
  (OpenRead)
  (OpenWriteTruncate)
  (OpenWriteAppend))

;: Result type for file-handle opening.
(defenum ResultIoFile
  (OkIoFile FileHandle)
  (ErrIoFile IoError))

;: Streaming file read chunk backed by active-arena owned bytes.
;:
;: `bytes` currently uses `String` as a byte container until #807 splits text
;: strings from binary byte slices.
(defstruct FileRead
  (bytes String)
  (eof bool))

;: Result type for streaming file reads.
(defenum ResultIoRead
  (OkIoRead FileRead)
  (ErrIoRead IoError))

;: Stdin read result containing the bytes/text read plus the post-read EOF flag.
;:
;: `text` is currently a `String` for both line and fixed-byte reads. This will
;: remain source-compatible but may gain a byte-slice variant after #807 splits
;: owned text strings from borrowed/binary bytes.
(defstruct StdinRead
  (text String)
  (eof bool))

;: Portable errno-style status code used by stdlib host helpers for success.
(define io-status-ok : i64
  0)

;: Common host status code for interrupted syscalls.
(define io-status-interrupted : i64
  4)

;: Common host status code for I/O errors such as short writes.
(define io-status-io-error : i64
  5)

;: Common host status code for paths that cannot be accessed due to permissions.
(define io-status-permission-denied : i64
  13)

;: Common host status code for a missing file or final path component.
(define io-status-not-found : i64
  2)

;: Common host status code for a missing path prefix component.
(define io-status-not-directory : i64
  20)

;: Common host status code for trying to read a directory as a file.
(define io-status-is-directory : i64
  21)

;: Common host status code for unsupported operations.
(define io-status-unsupported : i64
  38)

;: Common host status code for invalid arguments or path encodings.
(define io-status-invalid : i64
  22)

;: Common Linux host status code for an overlong path.
(define io-status-name-too-long : i64
  36)

;: Copy a borrowed path into an owned String for public diagnostics.
(define (io-copy-path [path : (& path str)]) : String
  (string-copy-borrowed path))

;: Return true when `path` is syntactically empty.
(define (io-empty-path? [path : (& path str)]) : bool
  (= (string-length path) 0))

;: Render an I/O error into a human-readable diagnostic string.
(define (io-error-message [error : IoError]) : String
  (match error
    [(IoNotFound path) (string-append "io: not found: " path)]
    [(IoPermissionDenied path) (string-append "io: permission denied: " path)]
    [(IoInvalidPath path) (string-append "io: invalid path: " path)]
    [(IoUnsupported message) (string-append "io: unsupported: " message)]
    [(IoInterrupted path) (string-append "io: interrupted: " path)]
    [(IoSystemCode code path)
      (string-append
        (string-append "io: system error " (int->string code))
        (string-append ": " path))]
    [(IoUnknown path) (string-append "io: unknown failure: " path)]))

;: Return true when `error` is a not-found diagnostic.
(define (io-error-not-found? [error : IoError]) : bool
  (match error
    [(IoNotFound _) true]
    [_ false]))

;: Return true when `error` is an invalid-path diagnostic.
(define (io-error-invalid-path? [error : IoError]) : bool
  (match error
    [(IoInvalidPath _) true]
    [_ false]))

;: Return true when `error` is an unsupported-runtime diagnostic.
(define (io-error-unsupported? [error : IoError]) : bool
  (match error
    [(IoUnsupported _) true]
    [_ false]))

;: Return true when `code` means a path is absent rather than a hard probe error.
(define (io-status-expected-absence? [code : i64]) : bool
  (if (= code io-status-not-found)
    true
    (= code io-status-not-directory)))

;: Construct an invalid-path diagnostic from a borrowed path.
(define (io-invalid-path-error [path : (& path str)]) : IoError
  (IoInvalidPath (io-copy-path path)))

;: Convert a runtime status code into the public structured error model.
(define (io-error-from-status [path : (& path str)] [code : i64]) : IoError
  (let
    [owned-path : String (io-copy-path path)]
    (core/cond
      (io-status-expected-absence? code)
      (IoNotFound owned-path)
      (= code io-status-permission-denied)
      (IoPermissionDenied owned-path)
      (= code io-status-invalid)
      (IoInvalidPath owned-path)
      (= code io-status-name-too-long)
      (IoInvalidPath owned-path)
      (= code io-status-interrupted)
      (IoInterrupted owned-path)
      (= code io-status-is-directory)
      (IoUnsupported owned-path)
      (= code io-status-unsupported)
      (IoUnsupported owned-path)
      (= code io-status-ok)
      (IoUnknown owned-path)
      (IoSystemCode code owned-path))))

;: Convert a runtime status code for an already-owned path.
(define (io-error-from-owned-status [path : String] [code : i64]) : IoError
  (core/cond
    (io-status-expected-absence? code)
    (IoNotFound path)
    (= code io-status-permission-denied)
    (IoPermissionDenied path)
    (= code io-status-invalid)
    (IoInvalidPath path)
    (= code io-status-name-too-long)
    (IoInvalidPath path)
    (= code io-status-interrupted)
    (IoInterrupted path)
    (= code io-status-is-directory)
    (IoUnsupported path)
    (= code io-status-unsupported)
    (IoUnsupported path)
    (= code io-status-ok)
    (IoUnknown path)
    (IoSystemCode code path)))

;: Convert a status code for a fixed diagnostic label.
(define (io-error-from-label [label : String] [code : i64]) : IoError
  (let
    [path : String label]
    (io-error-from-status (& path) code)))

;: Convert an open mode into the stdlib helper's compact mode code.
(define (open-mode-code [mode : OpenMode]) : i64
  (match mode
    [(OpenRead) 0]
    [(OpenWriteTruncate) 1]
    [(OpenWriteAppend) 2]))

;: Diagnostic payload for invalid or already-closed file handles.
(define (file-handle-invalid-message) : String
  "file handle is closed or invalid")

;: Diagnostic payload for invalid streaming reads.
(define (file-read-unsupported-message) : String
  "file handle is closed, invalid, or not open for reading")

;: Diagnostic payload for invalid streaming writes.
(define (file-write-unsupported-message) : String
  "file handle is closed, invalid, or not open for writing")

;: Diagnostic payload for invalid streaming flushes.
(define (file-flush-unsupported-message) : String
  "file handle is closed, invalid, or not open for writing")

;: Diagnostic payload for invalid streaming read counts.
(define (file-read-invalid-count-message) : String
  "file-read-chunk count must be non-negative")

;: Open `path` in `mode`, returning a stdlib-managed file handle.
;:
;: The returned handle must be passed to `file-close`. Empty paths return
;: `IoInvalidPath`; unsupported targets and mode/host failures are reported as
;: structured `IoError` values.
(define (file-open [path : (& path str)] [mode : OpenMode]) : ResultIoFile
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoFile (io-invalid-path-error path))
      (let
        [raw : i64 (file-open-status path-text (open-mode-code mode))]
        (if (< raw 0)
          (ErrIoFile (io-error-from-status path (- 0 raw)))
          (OkIoFile (FileHandle raw)))))))

;: Close a stdlib-managed file handle.
;:
;: Closing a valid handle returns `OkIoUnit`. Closing an invalid or already
;: closed handle returns `ErrIoUnit (IoUnsupported ...)` and never panics.
(define (file-close [handle : FileHandle]) : ResultIoUnit
  (let
    [status : i64 (file-close-status (struct-get handle id))]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-handle-invalid-message)))
        (ErrIoUnit (io-error-from-label "file-close" status))))))

;: Return the bytes captured by a streaming file read.
(define (file-read-bytes [read : FileRead]) : String
  (struct-get read bytes))

;: Return true when a streaming file read observed EOF after the read.
(define (file-read-eof? [read : FileRead]) : bool
  (struct-get read eof))

;: Read up to `count` bytes from a stdlib-managed read-mode file handle.
;:
;: The returned bytes are represented as `String` until #807 adds a distinct
;: byte-string/slice type. A short read does not imply EOF; EOF becomes true
;: only after the stdlib receives a zero-byte host read.
(define (file-read-chunk [handle : FileHandle] [count : i64]) : ResultIoRead
  (if (< count 0)
    (ErrIoRead (IoInvalidPath (file-read-invalid-count-message)))
    (let
      [raw : i64 (struct-get handle id)]
      [status : i64 (file-read-chunk-status raw count)]
      (if (= status io-status-ok)
        (OkIoRead
          (FileRead (file-read-chunk-bytes raw) (file-read-chunk-eof? raw)))
        (if (= status io-status-unsupported)
          (ErrIoRead (IoUnsupported (file-read-unsupported-message)))
          (ErrIoRead (io-error-from-label "file-read-chunk" status)))))))

;: Write `contents` to a stdlib-managed write-mode file handle.
;:
;: The stdlib retries short host writes until all bytes are accepted or a
;: host error is returned. Closed, invalid, read-only, and unsupported handles
;: return `IoUnsupported`.
(define (file-write [handle : FileHandle] [contents : (& contents str)]) : ResultIoUnit
  (let
    [contents-text : String (string-copy-borrowed contents)]
    [status : i64 (file-write-status (struct-get handle id) contents-text)]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-write-unsupported-message)))
        (ErrIoUnit (io-error-from-label "file-write" status))))))

;: Flush a stdlib-managed write-mode file handle.
;:
;: Closed, invalid, read-only, and unsupported handles return
;: `IoUnsupported`; host flush failures are mapped through `io-error-from-status`.
(define (file-flush [handle : FileHandle]) : ResultIoUnit
  (let
    [status : i64 (file-flush-status (struct-get handle id))]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-flush-unsupported-message)))
        (ErrIoUnit (io-error-from-label "file-flush" status))))))

;: Read `path` and return either its contents or a structured I/O error.
;:
;: Missing paths return `IoNotFound`. Empty paths return `IoInvalidPath`.
(define (try-read-file [path : (& path str)]) : ResultIoString
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoString (io-invalid-path-error path))
      (let
        [status : i64 (read-file-status path-text)]
        (if (= status io-status-ok)
          (OkIoString (read-file path-text))
          (ErrIoString (io-error-from-status path status)))))))

;: Write `contents` to `path`, returning a structured result.
;:
;: Empty paths return `IoInvalidPath`.
(define (try-write-file [path : (& path str)] [contents : (& contents str)]) : ResultIoUnit
  (let
    [path-text : String (string-copy-borrowed path)]
    [contents-text : String (string-copy-borrowed contents)]
    (if (io-empty-path? path)
      (ErrIoUnit (io-invalid-path-error path))
      (let
        [status : i64 (write-file-status path-text contents-text)]
        (if (= status io-status-ok)
          OkIoUnit
          (ErrIoUnit (io-error-from-status path status)))))))

;: Probe whether `path` exists, returning a structured result.
;:
;: Missing paths are represented as `OkIoBool false`, because absence is an
;: expected result of an existence probe. Empty paths return `IoInvalidPath`.
(define (try-file-exists? [path : (& path str)]) : ResultIoBool
  (let
    [path-text : String (string-copy-borrowed path)]
    (if (io-empty-path? path)
      (ErrIoBool (io-invalid-path-error path))
      (let
        [status : i64 (file-exists-status path-text)]
        (if (= status io-status-ok)
          (OkIoBool true)
          (if (io-status-expected-absence? status)
            (OkIoBool false)
            (ErrIoBool (io-error-from-status path status))))))))

;: Append `contents` to `path`, returning a structured result.
;:
;: The runtime opens the path in host append mode where available, preserving
;: existing contents and creating the file when missing. Empty paths return
;: `IoInvalidPath`.
(define (try-append-file [path : (& path str)] [contents : (& contents str)]) : ResultIoUnit
  (let
    [path-text : String (string-copy-borrowed path)]
    [contents-text : String (string-copy-borrowed contents)]
    (if (io-empty-path? path)
      (ErrIoUnit (io-invalid-path-error path))
      (let
        [status : i64 (append-file-status path-text contents-text)]
        (if (= status io-status-ok)
          OkIoUnit
          (ErrIoUnit (io-error-from-status path status)))))))

;: Read the contents of `path` if it exists, otherwise return `fallback`.
;:
;: This is a convenience wrapper over `try-read-file`. It returns `fallback`
;: for every structured error, preserving the historical optional-file API.
(define (read-file-or [path : (& path str)] [fallback : String]) : String
  (match (try-read-file path)
    [(OkIoString contents) contents]
    [(ErrIoString _) fallback]))

;: Append `contents` to the file at `path`, creating it when absent.
;:
;: Uses the platform append status path: non-truncating, create-if-missing,
;: and best-effort host append semantics.
(define (append-file [path : (& path str)] [contents : (& contents str)]) : unit
  (match (try-append-file path contents)
    [(OkIoUnit) unit]
    [(ErrIoUnit error)
      (begin
        (panic (io-error-message error))
        unit)]))

;: Return true when `path` exists and its contents are non-empty.
;:
;: Structured errors return false.
(define (file-nonempty? [path : (& path str)]) : bool
  (match (try-read-file path)
    [(OkIoString contents) (> (string-length contents) 0)]
    [(ErrIoString _) false]))

;: Return the text/bytes captured by a stdin read result.
(define (stdin-read-text [read : StdinRead]) : String
  (struct-get read text))

;: Return true when a stdin read observed EOF after the read completed.
(define (stdin-read-eof? [read : StdinRead]) : bool
  (struct-get read eof))

;: Return the current sticky stdin EOF state without performing a read.
(define (stdin-at-eof?) : bool
  (stdin-eof?))

;: Read one stdin line without the trailing newline and report post-read EOF.
;:
;: The returned string is allocated by the runtime in the active arena. Blank
;: lines return an empty string with `eof` false; end-of-file after the final
;: unterminated line returns that line with `eof` true.
(define (stdin-read-line) : StdinRead
  (let
    [text : String (read-stdin-line)]
    (StdinRead text (stdin-eof?))))

;: Read up to `count` bytes from stdin and report post-read EOF.
;:
;: The returned bytes are represented as `String` until #807 adds a distinct
;: byte-string/slice type.
(define (stdin-read-bytes [count : i64]) : StdinRead
  (let
    [text : String (read-stdin-bytes count)]
    (StdinRead text (stdin-eof?))))

;: Write `text` to stdout without adding a newline.
(define (stdout-write [text : (& text str)]) : unit
  (print-string (string-copy-borrowed text)))

;: Write `text` and a trailing newline to stdout.
;:
;: This convenience helper allocates the newline-appended string.
(define (stdout-write-line [text : (& text str)]) : unit
  (let
    [newline : String "\n"]
    (print-string (string-append-borrowed text (& newline)))))

;: Flush stdout.
(define (stdout-flush) : unit
  (flush-stdout))

;: Write `text` to stderr without adding a newline.
(define (stderr-write [text : (& text str)]) : unit
  (print-error (string-copy-borrowed text)))

;: Write `text` and a trailing newline to stderr.
;:
;: This convenience helper allocates the newline-appended string.
(define (stderr-write-line [text : (& text str)]) : unit
  (let
    [newline : String "\n"]
    (print-error (string-append-borrowed text (& newline)))))