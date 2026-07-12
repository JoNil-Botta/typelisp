;# File I/O utility library for TypeLisp.
;#
;# Provides file, argv, panic, and stdio helpers through direct extern bindings
;# to platform FFI symbols plus low-level language forms for argv and raw bytes.
;#
;# Public platform-facing functions such as the `print` / `println` format
;# macros, `print-string`, `panic`, `arg`,
;# `read-file`, `write-file`, file-handle status helpers, and stdin/stdout
;# helpers are stdlib definitions in this module. Programs must import this module
;# to use them.
;#
;# The `try-*` helpers return explicit monomorphic result enums. Host errors
;# are reported through status-code primitives and mapped into `IoError`.
;#
;# Usage: `(import stdlib.io)`
;#
;# ```typelisp
;# (import stdlib.io)
;# (define fallback : io.ResultIoString
;#   (let [path : String "missing-file-for-docs.txt"] (io.try-read-file (& path))))
;# ```
;#
;# ```typelisp
;# (import stdlib.io)
;# (define empty-read : io.StdinRead (io.stdin-read-bytes 0))
;# ```
;#
;# ```typelisp run
;# ;; doctest-exit: 0
;# ;; doctest-stdout: literal:hello from io\n
;# (import stdlib.io)
;# (define (main) : i64
;#   (begin
;#     (let [text : String "hello from io\n"] (io.stdout-write (& text)))
;#     0))
;# ```
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.comptime)
(import stdlib.format)
(import stdlib.io_core)
(import stdlib.string)

;: Private errno-style status slot used by stdlib IO/FS helpers. This is not
;: libc errno; it preserves the previous backend-owned slot semantics in TL.
(define io-private-error-code : i64
  0)

;: Store the current private errno-style status code.
(define (set-error-code [code : i64]) : unit
  (begin
    (set! io-private-error-code code)
    unit))

;: Windows kernel32 bindings backing the file-IO primitives.
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
    (if (= fd (cast 0 : i32))
      (io-win-get-std-handle (cast -10 : i32))
      (if (= fd (cast 1 : i32))
        (io-win-get-std-handle (cast -11 : i32))
        (if (= fd (cast 2 : i32))
          (io-win-get-std-handle (cast -12 : i32))
          (cast fd : i64))))))

;: Windows `_write` replacement via WriteFile; returns bytes written or -1.
(cfg
  windows
  (define (io-windows-write [fd : i32] [buf : (Ptr u8)] [count : i32]) : i32
    (let
      [handle : i64 (io-windows-fd-handle fd)]
      [written : (Array i32) (array.make-array i32 1)]
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
      [nread : (Array i32) (array.make-array i32 1)]
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
      [newpos : (Array i64) (array.make-array i64 1)]
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
          (set-error-code 2)
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
          (set-error-code 2)
          (cast -1 : i32))
        (cast 0 : i32)))))

;: Windows process exit via kernel32 ExitProcess; never returns. Replaces the
;: former backend `exit` CRT-ABI shim.
(cfg
  windows
  (extern (io-win-exit-process [arg0 : i32]) : never (:symbol "ExitProcess")))

(cfg
  windows
  (define (io-windows-exit [code : i32]) : never
    (io-win-exit-process code)))

;: Sticky EOF state for stdin chunk reads.
(define io-stdin-eof-state : bool
  false)

;: Copy `text` into a NUL-terminated byte array for C library calls.
(define (c-string [text : String]) : (Array u8)
  (let
    [n : i64 (string-length text)]
    [buf : (Array u8) (array.make-array u8 (+ n 1))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! buf i (cast (string-ref text i) : u8))
          (set! i (+ i 1))))
      (array-set! buf n (cast '\0' : u8))
      buf)))

;: Return a mutable pointer to an Array u8 backing buffer.
(define (array-ptr [buf : (Array u8)]) : (MutPtr u8)
  (unsafe
    (array-data buf)))

;: Return a const pointer to an Array u8 backing buffer.
(define (array-const-ptr [buf : (Array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (array-data buf) : (Ptr u8))))

;: Return a const pointer to a String's byte storage.
(define (string-const-ptr [text : String]) : (Ptr u8)
  (unsafe
    (string-data text)))

;: Copy a NUL-terminated C string into an owned TypeLisp String.
(define (copy-c-string [ptr : (Ptr u8)]) : String
  (let
    [n : i64 (c-string-length ptr)]
    [buf : (Array u8) (array.make-array u8 n)]
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
        (string-from-bytes (array-const-ptr buf) n)))))

;: Return the byte length of a NUL-terminated C string.
(define (c-string-length [ptr : (Ptr u8)]) : i64
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
(define (last-error-code) : i64
  io-private-error-code)

;: Translate a raw Linux syscall return into libc `-1` + `errno` semantics.
;: Syscalls report errors as a small negative `-errno` in `[-4095, -1]`; the
;: stdlib reads the private error slot through `last-error-code`, so failures
;: are surfaced by storing `errno` and returning `-1`, matching the former asm
;: shim.
(define (linux-syscall-status [result : i64]) : i64
  (if (and (>= result -4095) (< result 0))
    (begin
      (set-error-code (- 0 result))
      -1)
    result))

;: Convert a read-only byte pointer into an integer syscall argument.
(define (linux-ptr-arg [ptr : (Ptr u8)]) : i64
  (unsafe
    (cast (ptr->int ptr) : i64)))

;: Linux `open` via the `openat`-style `open` syscall (number 2).
(define (linux-syscall-open [path : (Ptr u8)] [flags : i64] [mode : i64]) : i64
  (cfg
    windows
    -1
    (linux-syscall-status
      (unsafe
        (syscall 2 (linux-ptr-arg path) flags mode)))))

;: Linux `read` via the `read` syscall (number 0).
(define (linux-syscall-read [fd : i64] [buf : (MutPtr u8)] [count : i64]) : i64
  (cfg
    windows
    -1
    (linux-syscall-status
      (unsafe
        (syscall
          0
          fd
          (linux-ptr-arg
            (unsafe
              (ptr-cast buf : (Ptr u8))))
          count)))))

;: Linux `write` via the `write` syscall (number 1).
(define (linux-syscall-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg
    windows
    -1
    (linux-syscall-status
      (unsafe
        (syscall 1 fd (linux-ptr-arg buf) count)))))

;: Linux `close` via the `close` syscall (number 3).
(define (linux-syscall-close [fd : i64]) : i64
  (cfg
    windows
    -1
    (linux-syscall-status
      (unsafe
        (syscall 3 fd)))))

;: Linux `lseek` via the `lseek` syscall (number 8).
(define (linux-syscall-lseek [fd : i64] [offset : i64] [whence : i64]) : i64
  (cfg
    windows
    -1
    (linux-syscall-status
      (unsafe
        (syscall 8 fd offset whence)))))

;: Linux `access` via the `access` syscall (number 21).
(define (linux-syscall-access [path : (Ptr u8)] [mode : i64]) : i64
  (cfg
    windows
    -1
    (linux-syscall-status
      (unsafe
        (syscall 21 (linux-ptr-arg path) mode)))))

;: Linux process exit via the `exit_group` syscall (number 231); never returns.
;: The tail call is unreachable at runtime (the syscall terminates the process)
;: and only gives the body its `never` type.
(define (linux-exit [code : i64]) : never
  (cfg
    windows
    (io-windows-exit (cast code : i32))
    (begin
      (unsafe
        (syscall 231 code))
      (linux-exit code))))

;: Dispatch a platform process exit; never returns.
(define (platform-exit [code : i64]) : never
  (cfg windows (io-windows-exit (cast code : i32)) (linux-exit code)))

;: Dispatch a platform `open` call and return its file descriptor or negative status.
(define (platform-open [path : (Ptr u8)] [flags : i64] [mode : i64]) : i64
  (cfg
    windows
    (cast (io-windows-open path (cast flags : i32) (cast mode : i32)) : i64)
    (linux-syscall-open path flags mode)))

;: Dispatch a platform `read` call and return its byte count or negative status.
(define (platform-read [fd : i64] [buf : (MutPtr u8)] [count : i64]) : i64
  (cfg
    windows
    (cast (io-windows-read (cast fd : i32) buf (cast count : i32)) : i64)
    (linux-syscall-read fd buf count)))

;: Dispatch a platform `write` call and return its byte count or negative status.
(define (platform-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg
    windows
    (cast (io-windows-write (cast fd : i32) buf (cast count : i32)) : i64)
    (linux-syscall-write fd buf count)))

;: Dispatch a platform `close` call and return zero or negative status.
(define (platform-close [fd : i64]) : i64
  (cfg
    windows
    (cast (io-windows-close (cast fd : i32)) : i64)
    (linux-syscall-close fd)))

;: Dispatch a platform seek call and return the resulting offset or negative status.
(define (platform-lseek [fd : i64] [offset : i64] [whence : i64]) : i64
  (cfg
    windows
    (io-windows-lseek (cast fd : i32) offset (cast whence : i32))
    (linux-syscall-lseek fd offset whence)))

;: Dispatch a platform existence/access probe and return zero or negative status.
(define (platform-access [path : (Ptr u8)] [mode : i64]) : i64
  (cfg
    windows
    (cast (io-windows-access path (cast mode : i32)) : i64)
    (linux-syscall-access path mode)))

;: Return platform flags for opening a path read-only.
(define (open-read-flags) : i64
  (cfg windows 32768 0))

;: Return platform flags for opening a path write-only with truncation.
(define (open-write-truncate-flags) : i64
  (cfg windows 33537 577))

;: Return platform flags for opening a path write-only with append semantics.
(define (open-write-append-flags) : i64
  (cfg windows 33033 1089))

;: Return platform permissions for creating files.
(define (open-mode) : i64
  384)

;: Return platform open flags for stdlib file mode `mode`.
(define (open-flags-for-mode [mode : i64]) : i64
  (if (= mode 0)
    (open-read-flags)
    (if (= mode 1)
      (open-write-truncate-flags)
      (open-write-append-flags))))

;: Return `code` as a negative status value.
(define (neg-status [code : i64]) : i64
  (- 0 code))

;: Write all bytes from `data` to `fd`, returning a host status code.
(define (write-all-fd-status [fd : i64] [data : (Ptr u8)] [len : i64]) : i64
  (let
    [offset : i64 0]
    [status : i64 0]
    (begin
      (while (if (= status 0)
        (< offset len)
        false)
        (let
          [written : i64
            (platform-write
              fd
              (unsafe
                (ptr-offset data offset))
              (- len offset))]
          (if (< written 0)
            (set! status (last-error-code))
            (if (= written 0)
              (set! status 5)
              (set! offset (+ offset written))))))
      status)))

;: Write a whole String to `fd`, returning a host status code.
(define (write-string-fd-status [fd : i64] [text : String]) : i64
  (write-all-fd-status fd (string-const-ptr text) (string-length text)))

;: Write a string to stdout without adding a newline.
(define (print-string [text : String]) : unit
  (let
    [status : i64 (write-string-fd-status 1 text)]
    (if (= status 0)
      unit
      (platform-exit 134))))

;: Compatibility alias for `print-string`.
(define (print-str [text : String]) : unit
  (print-string text))

;: Write a trailing newline to stdout.
(define (print-newline) : unit
  (print-string "\n"))

;: Compatibility implementation for the historical `(print i64)` call.
(define (print-i64 [value : i64]) : unit
  (begin
    (print-string (string.int->string value))
    (print-newline)))

;: Format a literal template and write it to stdout without a newline.
;:
;: The template and arguments follow `stdlib.format.format`: `{}` consumes one
;: value and `{{` / `}}` produce literal braces. Formatting creates one final
;: String and `print-string` writes that body once.
;:
;: For source compatibility, the historical single-i64 call `(print value)`
;: still writes the integer followed by a newline. New formatted calls always
;: start with a string literal, including `(print "{}" value)`.
(defmacro (print [template : comptime.Expr] [args : comptime.Expr ...]) : unit
  (match (type-kind (comptime.expr-type template))
    ["i64"
      (if (= (comptime.expr-list-length args) 0)
        `(stdlib.io.print-i64 ,template)
        `(stdlib.io.print-string (stdlib.format.format ,template ,@args)))]
    ["i32"
      (if (= (comptime.expr-list-length args) 0)
        `(stdlib.io.print-i64 (cast ,template : i64))
        `(stdlib.io.print-string (stdlib.format.format ,template ,@args)))]
    [_ `(stdlib.io.print-string (stdlib.format.format ,template ,@args))]))

;: Format a literal template, write it to stdout, then write one newline.
;:
;: The formatted body is built once and written once; the newline is a second,
;: explicit stream write.
(defmacro (println [template : comptime.Expr] [args : comptime.Expr ...]) : unit
  `(let
    [formatted : String (stdlib.format.format ,template ,@args)]
    (begin
      (stdlib.io.print-string formatted)
      (stdlib.io.print-newline))))

;: Write a boolean followed by a newline.
(define (print-bool [value : bool]) : unit
  (if value
    (print-string "true\n")
    (print-string "false\n")))

;: Write one character byte to stdout without adding a newline.
(define (print-char [ch : char]) : unit
  (let
    [buf : (Array u8) (array.make-array u8 1)]
    (begin
      (array-set! buf 0 (cast ch : u8))
      (if (= (write-all-fd-status 1 (array-const-ptr buf) 1) 0)
        unit
        (platform-exit 134)))))

;: Fixed-capacity base-2^32 bignum backing the pure-TL f64 formatter.
(defstruct BigNum
  (limbs (Array u64))
  (len i64))

;: Limb capacity of formatter bignum scratch buffers.
(define ftoa-cap : i64
  96)

;: Low 32-bit mask isolating a base-2^32 limb.
(define ftoa-mask32 : u64
  0xffffffff)

;: A zero-valued BigNum.
(define (bn-zero) : BigNum
  (BigNum (array.make-array u64 stdlib.io.ftoa-cap) 0))

;: BigNum holding the u64 value x.
(define (bn-from-u64 [x : u64]) : BigNum
  (let
    [r : BigNum (bn-zero)]
    [lo : u64 (bit-and x stdlib.io.ftoa-mask32)]
    [hi : u64 (shr x 32)]
    (begin
      (array-set! (struct-get r limbs) 0 lo)
      (array-set! (struct-get r limbs) 1 hi)
      (if (> hi (cast 0 : u64))
        (BigNum (struct-get r limbs) 2)
        (if (> lo (cast 0 : u64))
          (BigNum (struct-get r limbs) 1)
          (BigNum (struct-get r limbs) 0))))))

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
                  (if (> av bv)
                    (begin
                      (set! res 1)
                      (set! done true))
                    (if (< av bv)
                      (begin
                        (set! res -1)
                        (set! done true))
                      unit))
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
    [r : (Array u64) (array.make-array u64 stdlib.io.ftoa-cap)]
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
            (array-set! r i (bit-and s stdlib.io.ftoa-mask32))
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
    [r : (Array u64) (array.make-array u64 stdlib.io.ftoa-cap)]
    [la : i64 (struct-get a len)]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i la)
        (let
          [p : u64 (+ (* (array-ref (struct-get a limbs) i) m) carry)]
          (begin
            (array-set! r i (bit-and p stdlib.io.ftoa-mask32))
            (set! carry (shr p 32))
            (set! i (+ i 1)))))
      (while (> carry (cast 0 : u64))
        (begin
          (array-set! r i (bit-and carry stdlib.io.ftoa-mask32))
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
      [r : (Array u64) (array.make-array u64 stdlib.io.ftoa-cap)]
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
                (bit-or (bit-and (shl v bit-shift) stdlib.io.ftoa-mask32) carry)]
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
    [lo : u64 (bit-and m stdlib.io.ftoa-mask32)]
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
            (if (<= (bn-cmp prod num) 0)
              (set! q cand)
              unit)
            (set! bit (- bit 1)))))
      q)))

;: Optional f64 result for deterministic decimal parsing.
(defenum IoFloatMaybeF64
  (IoFloatNoF64)
  (IoFloatSomeF64 f64))

;: Internal exact decimal components used by the f64 parser.
(defenum IoFloatMaybeDecimal
  (IoFloatNoDecimal)
  (IoFloatSomeDecimal bool BigNum i64))

;: True when c is an ASCII decimal digit.
(define (float-decimal-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

;: Numeric value of an ASCII decimal digit.
(define (float-decimal-digit-value [c : char]) : i64
  (- (cast c : i64) (cast '0' : i64)))

;: True when c is an exponent marker accepted by the float parser.
(define (float-exponent-char? [c : char]) : bool
  (or (= c 'e') (= c 'E')))

;: Append one decimal digit to an exact bignum significand.
(define (float-bn-append-digit [value : BigNum] [digit : i64]) : BigNum
  (bn-add (bn-mul-u32 value (cast 10 : u64)) (bn-from-u64 (cast digit : u64))))

;: Parse decimal text into exact sign, significand, and decimal exponent.
(define (float-parse-decimal [text : String]) : IoFloatMaybeDecimal
  (let
    [n : i64 (string-length text)]
    [index : i64 0]
    [negative : bool false]
    [significand : BigNum (stdlib.io.bn-zero)]
    [int-digits : i64 0]
    [frac-digits : i64 0]
    [exp-negative : bool false]
    [exp-value : i64 0]
    [exp-digits : i64 0]
    (if (= n 0)
      (IoFloatNoDecimal)
      (begin
        (if (= (string-ref text 0) '-')
          (begin
            (set! negative true)
            (set! index 1))
          unit)
        (while (if (< index n)
          (stdlib.io.float-decimal-digit? (string-ref text index))
          false)
          (let
            [digit : i64
              (stdlib.io.float-decimal-digit-value (string-ref text index))]
            (begin
              (set!
                significand
                (stdlib.io.float-bn-append-digit significand digit))
              (set! int-digits (+ int-digits 1))
              (set! index (+ index 1)))))
        (cond
          [(= (+ int-digits frac-digits) 0) (IoFloatNoDecimal)]
          [(= index n) (IoFloatSomeDecimal negative significand 0)]
          [(= (string-ref text index) '.')
            (begin
              (set! index (+ index 1))
              (while (if (< index n)
                (stdlib.io.float-decimal-digit? (string-ref text index))
                false)
                (let
                  [digit : i64
                    (stdlib.io.float-decimal-digit-value
                      (string-ref text index))]
                  (begin
                    (set!
                      significand
                      (stdlib.io.float-bn-append-digit significand digit))
                    (set! frac-digits (+ frac-digits 1))
                    (set! index (+ index 1)))))
              (if (= frac-digits 0)
                (IoFloatNoDecimal)
                (begin
                  (if (if (< index n)
                    (stdlib.io.float-exponent-char? (string-ref text index))
                    false)
                    (begin
                      (set! index (+ index 1))
                      (if (if (< index n)
                        (= (string-ref text index) '-')
                        false)
                        (begin
                          (set! exp-negative true)
                          (set! index (+ index 1)))
                        (if (if (< index n)
                          (= (string-ref text index) '+')
                          false)
                          (set! index (+ index 1))
                          unit))
                      (while (if (< index n)
                        (stdlib.io.float-decimal-digit? (string-ref text index))
                        false)
                        (let
                          [digit : i64
                            (stdlib.io.float-decimal-digit-value
                              (string-ref text index))]
                          (begin
                            (if (< exp-value 4000)
                              (set! exp-value (+ (* exp-value 10) digit))
                              unit)
                            (set! exp-digits (+ exp-digits 1))
                            (set! index (+ index 1)))))
                      (if (= exp-digits 0)
                        (set! index (+ n 1))
                        unit))
                    unit)
                  (if (!= index n)
                    (IoFloatNoDecimal)
                    (IoFloatSomeDecimal
                      negative
                      significand
                      (-
                        (if exp-negative
                          (- 0 exp-value)
                          exp-value)
                        frac-digits))))))]
          [(stdlib.io.float-exponent-char? (string-ref text index))
            (begin
              (set! index (+ index 1))
              (if (if (< index n)
                (= (string-ref text index) '-')
                false)
                (begin
                  (set! exp-negative true)
                  (set! index (+ index 1)))
                (if (if (< index n)
                  (= (string-ref text index) '+')
                  false)
                  (set! index (+ index 1))
                  unit))
              (while (if (< index n)
                (stdlib.io.float-decimal-digit? (string-ref text index))
                false)
                (let
                  [digit : i64
                    (stdlib.io.float-decimal-digit-value
                      (string-ref text index))]
                  (begin
                    (if (< exp-value 4000)
                      (set! exp-value (+ (* exp-value 10) digit))
                      unit)
                    (set! exp-digits (+ exp-digits 1))
                    (set! index (+ index 1)))))
              (if (if (= exp-digits 0)
                true
                (!= index n))
                (IoFloatNoDecimal)
                (IoFloatSomeDecimal
                  negative
                  significand
                  (if exp-negative
                    (- 0 exp-value)
                    exp-value))))]
          [else (IoFloatNoDecimal)])))))

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

;: Bit length of a non-negative BigNum.
(define (float-bn-bit-length [value : BigNum]) : i64
  (let
    [len : i64 (struct-get value len)]
    (if (= len 0)
      0
      (+
        (* (- len 1) 32)
        (+
          (stdlib.io.ftoa-msb-index
            (array-ref (struct-get value limbs) (- len 1)))
          1)))))

;: Floor log2 of the positive rational `num / den`.
(define (float-ratio-floor-log2 [num : BigNum] [den : BigNum]) : i64
  (let
    [estimate : i64
      (-
        (stdlib.io.float-bn-bit-length num)
        (stdlib.io.float-bn-bit-length den))]
    [ok : bool
      (if (>= estimate 0)
        (>= (bn-cmp num (bn-shl-bits den estimate)) 0)
        (>= (bn-cmp (bn-shl-bits num (- 0 estimate)) den) 0))]
    (if ok
      estimate
      (- estimate 1))))

;: Rounded quotient of `num / den`, ties to even.
(define (float-round-div-u64 [num : BigNum] [den : BigNum]) : u64
  (let
    [q : u64 (bn-div-floor-u64 num den)]
    [twice-num : BigNum (bn-shl-bits num 1)]
    [mid : BigNum (bn-mul-u64 den (+ (* (cast 2 : u64) q) (cast 1 : u64)))]
    [cmp : i64 (bn-cmp twice-num mid)]
    (if (> cmp 0)
      (+ q (cast 1 : u64))
      (if (= cmp 0)
        (if (= (bit-and q (cast 1 : u64)) (cast 1 : u64))
          (+ q (cast 1 : u64))
          q)
        q))))

;: Rounded quotient of `num * 2^shift / den`, ties to even.
(define (float-round-scaled-u64 [num : BigNum] [den : BigNum] [shift : i64]) : u64
  (if (>= shift 0)
    (stdlib.io.float-round-div-u64 (stdlib.io.bn-shl-bits num shift) den)
    (stdlib.io.float-round-div-u64 num (stdlib.io.bn-shl-bits den (- 0 shift)))))

;: Reinterpret IEEE-754 binary64 bits as f64.
(define (float-f64-from-bits [bits : u64]) : f64
  (let
    [buf : (Array u64) (array.make-array u64 1)]
    (begin
      (array-set! buf 0 bits)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr f64)))))))

;: Reinterpret an f64 as IEEE-754 binary64 bits.
(define (float-f64-bits [value : f64]) : u64
  (let
    [buf : (Array f64) (array.make-array f64 1)]
    (begin
      (array-set! buf 0 value)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr u64)))))))

;: Reinterpret an f32 as IEEE-754 binary32 bits.
(define (float-f32-bits [value : f32]) : u32
  (let
    [buf : (Array f32) (array.make-array f32 1)]
    (begin
      (array-set! buf 0 value)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr u32)))))))

;: Return true when an f64 is neither NaN nor infinity.
(define (float-f64-finite? [value : f64]) : bool
  (let
    [bits : u64 (stdlib.io.float-f64-bits value)]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    (not (= expf (cast 0x7ff : u64)))))

;: Return true when an f32 is neither NaN nor infinity.
(define (float-f32-finite? [value : f32]) : bool
  (let
    [bits : u32 (stdlib.io.float-f32-bits value)]
    [expf : u32 (bit-and (shr bits 23) (cast 0xff : u32))]
    (not (= expf (cast 0xff : u32)))))

;: Return true when the f64 magnitude bits are zero.
(define (float-f64-zero-magnitude? [value : f64]) : bool
  (=
    (bit-and (stdlib.io.float-f64-bits value) 0x7fffffffffffffff)
    (cast 0 : u64)))

;: Return true when the f32 magnitude bits are zero.
(define (float-f32-zero-magnitude? [value : f32]) : bool
  (=
    (bit-and (stdlib.io.float-f32-bits value) (cast 0x7fffffff : u32))
    (cast 0 : u32)))

;: Convert exact decimal components to an IEEE-754 binary64 value.
(define (float-decimal-to-f64
  [negative : bool]
  [significand : BigNum]
  [decimal-exp : i64]) : IoFloatMaybeF64
  (let
    [sign-bit : u64
      (if negative
        (shl (cast 1 : u64) 63)
        (cast 0 : u64))]
    [num : BigNum significand]
    [den : BigNum (stdlib.io.bn-from-u64 (cast 1 : u64))]
    (if (= (struct-get num len) 0)
      (IoFloatSomeF64 (stdlib.io.float-f64-from-bits sign-bit))
      (begin
        (if (>= decimal-exp 0)
          (set! num (stdlib.io.bn-mul-pow10 num decimal-exp))
          (set! den (stdlib.io.bn-mul-pow10 den (- 0 decimal-exp))))
        (let
          [e : i64 (stdlib.io.float-ratio-floor-log2 num den)]
          [two52 : u64 0x10000000000000]
          [two53 : u64 0x20000000000000]
          (if (> e 1023)
            (IoFloatNoF64)
            (if (>= e -1022)
              (let
                [m0 : u64 (stdlib.io.float-round-scaled-u64 num den (- 52 e))]
                [m : u64 m0]
                [exp : i64 e]
                (begin
                  (if (= m two53)
                    (begin
                      (set! m two52)
                      (set! exp (+ exp 1)))
                    unit)
                  (if (> exp 1023)
                    (IoFloatNoF64)
                    (IoFloatSomeF64
                      (stdlib.io.float-f64-from-bits
                        (bit-or
                          sign-bit
                          (bit-or
                            (shl (cast (+ exp 1023) : u64) 52)
                            (- m two52))))))))
              (let
                [m : u64 (stdlib.io.float-round-scaled-u64 num den 1074)]
                (if (= m (cast 0 : u64))
                  (IoFloatSomeF64 (stdlib.io.float-f64-from-bits sign-bit))
                  (if (>= m two52)
                    (IoFloatSomeF64
                      (stdlib.io.float-f64-from-bits
                        (bit-or sign-bit (shl (cast 1 : u64) 52))))
                    (IoFloatSomeF64
                      (stdlib.io.float-f64-from-bits (bit-or sign-bit m)))))))))))))

;: Parse finite decimal text into an IEEE-754 binary64 value.
(define (float-parse-f64 [text : String]) : IoFloatMaybeF64
  (match (stdlib.io.float-parse-decimal text)
    [(IoFloatSomeDecimal negative significand decimal-exp)
      (stdlib.io.float-decimal-to-f64 negative significand decimal-exp)]
    [(IoFloatNoDecimal) (IoFloatNoF64)]))

;: Return `value` rounded to f32 precision and widened back to f64.
(define (float-round-f32-as-f64 [value : f64]) : f64
  (cast (cast value : f32) : f64))

;: Significant-digit string of `d` with trailing zeros removed (>= 1 digit).
(define (ftoa-strip-zeros [d : i64]) : String
  (let
    [dd : i64 d]
    (begin
      (while (and (> dd 9) (= (% dd 10) 0))
        (set! dd (/ dd 10)))
      (string.int->string dd))))

;: Exponent k formatted with sign and at least two digits.
(define (ftoa-pad-exp [k : i64]) : String
  (let
    [mag : i64
      (if (< k 0)
        (- 0 k)
        k)]
    [digits : String (string.int->string mag)]
    [sign : String
      (if (< k 0)
        "-"
        "+")]
    (string.concat3
      sign
      (if (< (string-length digits) 2)
        (string.concat3 "0" digits "")
        digits)
      "")))

;: A string of n zero characters.
(define (ftoa-zeros [n : i64]) : String
  (let
    [s : String ""]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! s (string.concat3 s "0" ""))
          (set! i (+ i 1))))
      s)))

;: Format significant-digit string `s` whose leading digit has decimal
;: exponent `k`, following printf %g (precision 17) style.
(define (ftoa-render [neg : bool] [s : String] [k : i64]) : String
  (let
    [body : String ""]
    [ndig : i64 (string-length s)]
    (begin
      (cond
        [(or (< k -4) (>= k 17))
          (set!
            body
            (string.concat4
              (string.substring s 0 1)
              (if (> ndig 1)
                (string.concat3 "." (string.substring s 1 (- ndig 1)) "")
                "")
              "e"
              (stdlib.io.ftoa-pad-exp k)))]
        [(< k 0)
          (set!
            body
            (string.concat3 "0." (stdlib.io.ftoa-zeros (- (- 0 k) 1)) s))]
        [(>= (+ k 1) ndig)
          (set!
            body
            (string.concat3 s (stdlib.io.ftoa-zeros (- (+ k 1) ndig)) ""))]
        [else
          (set!
            body
            (string.concat3
              (string.substring s 0 (+ k 1))
              "."
              (string.substring s (+ k 1) (- ndig (+ k 1)))))])
      (if neg
        (string.concat3 "-" body "")
        body))))

;: Render value as a shortest round-tripping decimal string (printf %.17g style).
(define (format-float-core [value : f64]) : String
  (let
    [buf : (Array f64) (array.make-array f64 1)]
    (begin
      (array-set! buf 0 value)
      (let
        [bits : u64
          (unsafe
            (ptr-read (ptr-cast (array-data buf) : (Ptr u64))))]
        [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
        [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
        [frac : u64 (bit-and bits 0xfffffffffffff)]
        (begin
          (when
            (= expf (cast 0x7ff : u64))
            (return
              (if (= frac (cast 0 : u64))
                (if neg
                  "-inf"
                  "inf")
                (if neg
                  "-nan"
                  "nan"))))
          (when
            (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
            (return
              (if neg
                "-0"
                "0")))
          (let
            [m : u64
              (if (= expf (cast 0 : u64))
                frac
                (bit-or frac 0x10000000000000))]
            [e2 : i64
              (if (= expf (cast 0 : u64))
                -1074
                (- (cast expf : i64) 1075))]
            [msb : i64 (stdlib.io.ftoa-msb-index m)]
            [kest : i64 (stdlib.io.ftoa-floor-div (* (+ msb e2) 30103) 100000)]
            [d : u64 (cast 0 : u64)]
            [iters : i64 0]
            [settled : bool false]
            (begin
              (while (if (not settled)
                (< iters 6)
                false)
                (let
                  [p : i64 (- 16 kest)]
                  [num : BigNum (stdlib.io.bn-from-u64 m)]
                  [den : BigNum (stdlib.io.bn-from-u64 (cast 1 : u64))]
                  (begin
                    (if (>= e2 0)
                      (set! num (stdlib.io.bn-shl-bits num e2))
                      (set! den (stdlib.io.bn-shl-bits den (- 0 e2))))
                    (if (>= p 0)
                      (set! num (stdlib.io.bn-mul-pow10 num p))
                      (set! den (stdlib.io.bn-mul-pow10 den (- 0 p))))
                    (let
                      [q : u64 (stdlib.io.bn-div-floor-u64 num den)]
                      [two-num : BigNum (stdlib.io.bn-shl-bits num 1)]
                      [t : BigNum
                        (stdlib.io.bn-mul-u64
                          den
                          (+ (* (cast 2 : u64) q) (cast 1 : u64)))]
                      [c : i64 (stdlib.io.bn-cmp two-num t)]
                      (begin
                        (set! d q)
                        (if (> c 0)
                          (set! d (+ q (cast 1 : u64)))
                          (if (= c 0)
                            (if (= (bit-and q (cast 1 : u64)) (cast 1 : u64))
                              (set! d (+ q (cast 1 : u64)))
                              unit)
                            unit))
                        (if (>= d 100000000000000000)
                          (set! kest (+ kest 1))
                          (if (< d 10000000000000000)
                            (set! kest (- kest 1))
                            (set! settled true)))
                        (set! iters (+ iters 1)))))))
              (let
                [s0 : String (string.int->string (cast d : i64))]
                [k : i64 (+ (- (string-length s0) 17) kest)]
                (stdlib.io.ftoa-render
                  neg
                  (stdlib.io.ftoa-strip-zeros (cast d : i64))
                  k)))))))))

;: Format an f64 with `%.17g` and a trailing newline.
(define (format-float [value : f64]) : String
  (string.concat3 (stdlib.io.format-float-core value) "\n" ""))

;: Write a floating-point value to stdout using `%.17g` plus a newline.
(define (print-float [value : f64]) : unit
  (print-string (stdlib.io.format-float value)))

;: Write a string to stderr without adding a newline.
(define (print-error [text : String]) : unit
  (let
    [status : i64 (write-string-fd-status 2 text)]
    (if (= status 0)
      unit
      (platform-exit 134))))

;: Abort the process after writing `message` to stderr.
(define (panic [message : String]) : never
  (begin
    (print-error message)
    (platform-exit 134)))

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
        (copy-c-string raw)))))

;: Read the entire seekable descriptor `fd` into a String.
(define (read-fd-to-string [fd : i64]) : String
  (let
    [end : i64 (stdlib.io.platform-lseek fd 0 2)]
    (if (< end 0)
      (panic "tl: read-file failed\n")
      (begin
        (if (< (stdlib.io.platform-lseek fd 0 0) 0)
          (panic "tl: read-file failed\n")
          unit)
        (let
          [buf : (Array u8) (array.make-array u8 end)]
          [offset : i64 0]
          [done : bool false]
          (begin
            (while (if (not done)
              (< offset end)
              false)
              (let
                [read-count : i64
                  (stdlib.io.platform-read
                    fd
                    (unsafe
                      (ptr-offset (stdlib.io.array-ptr buf) offset))
                    (- end offset))]
                (if (< read-count 0)
                  (panic "tl: read-file failed\n")
                  (if (= read-count 0)
                    (set! done true)
                    (set! offset (+ offset read-count))))))
            (unsafe
              (string-from-bytes (stdlib.io.array-const-ptr buf) offset))))))))

;: Return the host status code for reading `path`.
(define (read-file-status [path : String]) : i64
  (let
    [path-bytes : (Array u8) (stdlib.io.c-string path)]
    [fd : i64
      (stdlib.io.platform-open
        (stdlib.io.array-const-ptr path-bytes)
        (stdlib.io.open-read-flags)
        0)]
    (if (< fd 0)
      (stdlib.io.last-error-code)
      (let
        [probe : (Array u8) (array.make-array u8 1)]
        [read-count : i64
          (stdlib.io.platform-read fd (stdlib.io.array-ptr probe) 1)]
        [status : i64
          (if (< read-count 0)
            (stdlib.io.last-error-code)
            0)]
        (begin
          (stdlib.io.platform-close fd)
          status)))))

;: Read a whole file, aborting on host read failure.
(define (read-file [path : String]) : String
  (let
    [path-bytes : (Array u8) (c-string path)]
    [fd : i64 (platform-open (array-const-ptr path-bytes) (open-read-flags) 0)]
    (if (< fd 0)
      (panic "tl: read-file failed\n")
      (let
        [contents : String (read-fd-to-string fd)]
        (begin
          (platform-close fd)
          contents)))))

;: Write `contents` to `path` using platform `flags`, returning a host status code.
(define (write-path-status [path : String] [contents : String] [flags : i64]) : i64
  (let
    [path-bytes : (Array u8) (c-string path)]
    [fd : i64 (platform-open (array-const-ptr path-bytes) flags (open-mode))]
    (if (< fd 0)
      (last-error-code)
      (let
        [status : i64 (write-string-fd-status fd contents)]
        [close-status : i64 (platform-close fd)]
        (if (= status 0)
          (if (< close-status 0)
            (last-error-code)
            0)
          status)))))

;: Return the host status code for writing `contents` to `path`.
(define (write-file-status [path : String] [contents : String]) : i64
  (stdlib.io.write-path-status
    path
    contents
    (stdlib.io.open-write-truncate-flags)))

;: Render the raw `write-file` panic payload with path and host status.
(define (write-file-failure-message [path : String] [status : i64]) : String
  (string.concat3
    "tl: write-file failed: "
    (stdlib.io.error-message (stdlib.io.error-from-owned-status path status))
    "\n"))

;: Write a whole file, aborting on host write failure.
(define (write-file [path : String] [contents : String]) : unit
  (let
    [status : i64 (stdlib.io.write-file-status path contents)]
    (if (= status 0)
      unit
      (panic (stdlib.io.write-file-failure-message path status)))))

;: Return the host status code for appending `contents` to `path`.
(define (append-file-status [path : String] [contents : String]) : i64
  (stdlib.io.write-path-status
    path
    contents
    (stdlib.io.open-write-append-flags)))

;: Return the host status code for probing `path`.
(define (file-exists-status [path : String]) : i64
  (let
    [path-bytes : (Array u8) (stdlib.io.c-string path)]
    [status : i64
      (stdlib.io.platform-access (stdlib.io.array-const-ptr path-bytes) 0)]
    (if (= status 0)
      0
      (stdlib.io.last-error-code))))

;: Return true when `path` exists, aborting on hard host probe failure.
(define (file-exists? [path : String]) : bool
  (let
    [status : i64 (stdlib.io.file-exists-status path)]
    (if (= status 0)
      true
      (if (if (= status 2)
        true
        (= status 20))
        false
        (panic "tl: file-exists? failed\n")))))

;: Return true when `raw` names an open stdlib file handle.
(define (valid-handle? [raw : i64]) : bool
  (io_core.io-file-valid-handle? raw))

;: Return a stdlib file handle id or negative status for opening `path`.
(define (file-open-status [path : String] [mode : i64]) : i64
  (begin
    (io_core.io-file-table-init!)
    (let
      [path-bytes : (Array u8) (stdlib.io.c-string path)]
      [fd : i64
        (stdlib.io.platform-open
          (stdlib.io.array-const-ptr path-bytes)
          (stdlib.io.open-flags-for-mode mode)
          (stdlib.io.open-mode))]
      (if (< fd 0)
        (stdlib.io.neg-status (stdlib.io.last-error-code))
        (let
          [handle : i64 (io_core.io-file-alloc-handle!)]
          (if (< handle 0)
            (begin
              (stdlib.io.platform-close fd)
              (stdlib.io.neg-status 38))
            (begin
              (io_core.io-file-i64-set! (io_core.io-file-fds-ptr) handle fd)
              (io_core.io-file-i64-set! (io_core.io-file-modes-ptr) handle mode)
              (io_core.io-file-i64-set! (io_core.io-file-states-ptr) handle 1)
              (io_core.io-file-bool-set!
                (io_core.io-file-eofs-ptr)
                handle
                false)
              (io_core.io-file-bool-set!
                (io_core.io-file-last-ready-ptr)
                handle
                false)
              handle)))))))

;: Return the host status code for closing a stdlib file handle id.
(define (file-close-status [raw : i64]) : i64
  (if (stdlib.io.valid-handle? raw)
    (let
      [fd : i64 (io_core.io-file-i64-ref (io_core.io-file-fds-ptr) raw)]
      [status : i64 (stdlib.io.platform-close fd)]
      (begin
        (io_core.io-file-release-handle! raw)
        (if (< status 0)
          (stdlib.io.last-error-code)
          0)))
    38))

;: Return the host status code for reading a chunk into the stdlib handle cache.
(define (file-read-chunk-status [raw : i64] [count : i64]) : i64
  (cond
    [(not (stdlib.io.valid-handle? raw)) 38]
    [(not (= (io_core.io-file-i64-ref (io_core.io-file-modes-ptr) raw) 0)) 38]
    [(< count 0) 22]
    [(= count 0)
      (begin
        (io_core.io-file-string-set! (io_core.io-file-last-bytes-ptr) raw "")
        (io_core.io-file-bool-set! (io_core.io-file-last-ready-ptr) raw true)
        0)]
    [else
      (let
        [buf : (Array u8) (array.make-array u8 count)]
        [fd : i64 (io_core.io-file-i64-ref (io_core.io-file-fds-ptr) raw)]
        [read-count : i64
          (stdlib.io.platform-read fd (stdlib.io.array-ptr buf) count)]
        (if (< read-count 0)
          (stdlib.io.last-error-code)
          (begin
            (if (= read-count 0)
              (io_core.io-file-bool-set! (io_core.io-file-eofs-ptr) raw true)
              (io_core.io-file-bool-set! (io_core.io-file-eofs-ptr) raw false))
            (io_core.io-file-string-set!
              (io_core.io-file-last-bytes-ptr)
              raw
              (unsafe
                (string-from-bytes (stdlib.io.array-const-ptr buf) read-count)))
            (io_core.io-file-bool-set!
              (io_core.io-file-last-ready-ptr)
              raw
              true)
            0)))]))

;: Return the host status code for writing `contents` through a stdlib handle.
(define (file-write-status [raw : i64] [contents : String]) : i64
  (if (not (stdlib.io.valid-handle? raw))
    38
    (if (= (io_core.io-file-i64-ref (io_core.io-file-modes-ptr) raw) 0)
      38
      (stdlib.io.write-string-fd-status
        (io_core.io-file-i64-ref (io_core.io-file-fds-ptr) raw)
        contents))))

;: Return the host status code for flushing a stdlib handle.
(define (file-flush-status [raw : i64]) : i64
  (if (not (stdlib.io.valid-handle? raw))
    38
    (if (= (io_core.io-file-i64-ref (io_core.io-file-modes-ptr) raw) 0)
      38
      0)))

;: Return bytes from the last successful stdlib file chunk read.
(define (file-read-chunk-bytes [raw : i64]) : String
  (if (if (stdlib.io.valid-handle? raw)
    (io_core.io-file-bool-ref (io_core.io-file-last-ready-ptr) raw)
    false)
    (io_core.io-file-string-ref (io_core.io-file-last-bytes-ptr) raw)
    ""))

;: Return the sticky EOF bit from the last successful stdlib file chunk read.
(define (file-read-chunk-eof? [raw : i64]) : bool
  (if (stdlib.io.valid-handle? raw)
    (io_core.io-file-bool-ref (io_core.io-file-eofs-ptr) raw)
    true))

;: Read up to `count` bytes from stdin, continuing across positive short reads.
(define (read-stdin-bytes [count : i64]) : String
  (if (< count 0)
    (panic "tl: stdin failed\n")
    (if (= count 0)
      ""
      (let
        [buf : (Array u8) (array.make-array u8 count)]
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
                  (platform-read
                    0
                    (unsafe
                      (ptr-offset (array-ptr buf) offset))
                    (- count offset))]
                (if (< read-count 0)
                  (panic "tl: stdin failed\n")
                  (if (= read-count 0)
                    (begin
                      (set! io-stdin-eof-state true)
                      (set! done true))
                    (set! offset (+ offset read-count)))))))
          (unsafe
            (string-from-bytes (array-const-ptr buf) offset)))))))

;: Read one stdin line without the trailing newline.
(define (read-stdin-line) : String
  (let
    [bytes : byte_buf_core.ByteBufBuilder
      (byte_buf_core.ByteBufBuilder (array.make-array u8 0) 0)]
    [one : (Array u8) (array.make-array u8 1)]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [read-count : i64 (platform-read 0 (array-ptr one) 1)]
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
                    (array-push! (struct-get bytes slots) byte)
                    (set! done false))))))))
      (begin
        (set! (struct-get bytes len) (array-length (struct-get bytes slots)))
        (byte_buf_core.byte-buf-builder-finish-string (& bytes))))))

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

;: Return the host status code from a system-code error, or `fallback`.
(define (error-system-code-or [error : IoError] [fallback : i64]) : i64
  (match error
    [(IoSystemCode code _) code]
    [_ fallback]))

;: Return true when a unit result succeeded.
(define (result-unit-ok? [result : ResultIoUnit]) : bool
  (match result
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

;: Return the unit-result error, or `fallback` when the result succeeded.
(define (result-unit-error-or [result : ResultIoUnit] [fallback : IoError]) : IoError
  (match result
    [(OkIoUnit) fallback]
    [(ErrIoUnit error) error]))

;: Return true when a string result succeeded.
(define (result-string-ok? [result : ResultIoString]) : bool
  (match result
    [(OkIoString _) true]
    [(ErrIoString _) false]))

;: Return the string-result value, or `fallback` when the result failed.
(define (result-string-value-or [result : ResultIoString] [fallback : String]) : String
  (match result
    [(OkIoString value) value]
    [(ErrIoString _) fallback]))

;: Return the string-result error, or `fallback` when the result succeeded.
(define (result-string-error-or [result : ResultIoString] [fallback : IoError]) : IoError
  (match result
    [(OkIoString _) fallback]
    [(ErrIoString error) error]))

;: Return true when a bool result succeeded.
(define (result-bool-ok? [result : ResultIoBool]) : bool
  (match result
    [(OkIoBool _) true]
    [(ErrIoBool _) false]))

;: Return the bool-result value, or `fallback` when the result failed.
(define (result-bool-value-or [result : ResultIoBool] [fallback : bool]) : bool
  (match result
    [(OkIoBool value) value]
    [(ErrIoBool _) fallback]))

;: Return the bool-result error, or `fallback` when the result succeeded.
(define (result-bool-error-or [result : ResultIoBool] [fallback : IoError]) : IoError
  (match result
    [(OkIoBool _) fallback]
    [(ErrIoBool error) error]))

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

;: Return true when a file-open result succeeded.
(define (result-file-ok? [result : ResultIoFile]) : bool
  (match result
    [(OkIoFile _) true]
    [(ErrIoFile _) false]))

;: Return the file handle, or `fallback` when the open failed.
(define (result-file-value-or [result : ResultIoFile] [fallback : FileHandle]) : FileHandle
  (match result
    [(OkIoFile value) value]
    [(ErrIoFile _) fallback]))

;: Streaming file read chunk backed by active-arena owned bytes.
;:
;: `bytes` uses `String` as a byte container.
(defstruct FileRead
  (bytes String)
  (eof bool))

;: Result type for streaming file reads.
(defenum ResultIoRead
  (OkIoRead FileRead)
  (ErrIoRead IoError))

;: Stdin read result containing the bytes/text read plus the post-read EOF flag.
;:
;: `text` is a `String` for both line and fixed-byte reads.
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
(define (copy-path [path : (& path str)]) : String
  (string.copy path))

;: Return true when `path` is syntactically empty.
(define (empty-path? [path : (& path str)]) : bool
  (= (string-length path) 0))

;: Render an I/O error into a human-readable diagnostic string.
(define (error-message [error : IoError]) : String
  (match error
    [(IoNotFound path) (string.append "io: not found: " path)]
    [(IoPermissionDenied path) (string.append "io: permission denied: " path)]
    [(IoInvalidPath path) (string.append "io: invalid path: " path)]
    [(IoUnsupported message) (string.append "io: unsupported: " message)]
    [(IoInterrupted path) (string.append "io: interrupted: " path)]
    [(IoSystemCode code path)
      (string.concat4 "io: system error " (string.int->string code) ": " path)]
    [(IoUnknown path) (string.append "io: unknown failure: " path)]))

;: Return true when `error` is a not-found diagnostic.
(define (error-not-found? [error : IoError]) : bool
  (match error
    [(IoNotFound _) true]
    [_ false]))

;: Return true when `error` is an invalid-path diagnostic.
(define (error-invalid-path? [error : IoError]) : bool
  (match error
    [(IoInvalidPath _) true]
    [_ false]))

;: Return true when `error` is an unsupported-runtime diagnostic.
(define (error-unsupported? [error : IoError]) : bool
  (match error
    [(IoUnsupported _) true]
    [_ false]))

;: Return true when `code` means a path is absent rather than a hard probe error.
(define (status-expected-absence? [code : i64]) : bool
  (if (= code stdlib.io.io-status-not-found)
    true
    (= code stdlib.io.io-status-not-directory)))

;: Construct an invalid-path diagnostic from a borrowed path.
(define (invalid-path-error [path : (& path str)]) : IoError
  (IoInvalidPath (stdlib.io.copy-path path)))

;: Convert a runtime status code into the public structured error model.
(define (error-from-status [path : (& path str)] [code : i64]) : IoError
  (let
    [owned-path : String (stdlib.io.copy-path path)]
    (cond
      [(stdlib.io.status-expected-absence? code) (IoNotFound owned-path)]
      [(= code stdlib.io.io-status-permission-denied)
        (IoPermissionDenied owned-path)]
      [(= code stdlib.io.io-status-invalid) (IoInvalidPath owned-path)]
      [(= code stdlib.io.io-status-name-too-long) (IoInvalidPath owned-path)]
      [(= code stdlib.io.io-status-interrupted) (IoInterrupted owned-path)]
      [(= code stdlib.io.io-status-is-directory) (IoUnsupported owned-path)]
      [(= code stdlib.io.io-status-unsupported) (IoUnsupported owned-path)]
      [(= code stdlib.io.io-status-ok) (IoUnknown owned-path)]
      [else (IoSystemCode code owned-path)])))

;: Convert a runtime status code for an already-owned path.
(define (error-from-owned-status [path : String] [code : i64]) : IoError
  (cond
    [(stdlib.io.status-expected-absence? code) (IoNotFound path)]
    [(= code stdlib.io.io-status-permission-denied) (IoPermissionDenied path)]
    [(= code stdlib.io.io-status-invalid) (IoInvalidPath path)]
    [(= code stdlib.io.io-status-name-too-long) (IoInvalidPath path)]
    [(= code stdlib.io.io-status-interrupted) (IoInterrupted path)]
    [(= code stdlib.io.io-status-is-directory) (IoUnsupported path)]
    [(= code stdlib.io.io-status-unsupported) (IoUnsupported path)]
    [(= code stdlib.io.io-status-ok) (IoUnknown path)]
    [else (IoSystemCode code path)]))

;: Convert a status code for a fixed diagnostic label.
(define (error-from-label [label : String] [code : i64]) : IoError
  (let
    [path : String label]
    (error-from-status (& path) code)))

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
    [path-text : String (string.copy path)]
    (if (empty-path? path)
      (ErrIoFile (invalid-path-error path))
      (let
        [raw : i64 (file-open-status path-text (open-mode-code mode))]
        (if (< raw 0)
          (ErrIoFile (error-from-status path (- 0 raw)))
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
        (ErrIoUnit (error-from-label "file-close" status))))))

;: Return the bytes captured by a streaming file read.
(define (file-read-bytes [read : FileRead]) : String
  (struct-get read bytes))

;: Return true when a streaming file read observed EOF after the read.
(define (file-read-eof? [read : FileRead]) : bool
  (struct-get read eof))

;: Read up to `count` bytes from a stdlib-managed read-mode file handle.
;:
;: The returned bytes are represented as `String`. A short read does not imply
;: EOF; EOF becomes true only after the stdlib receives a zero-byte host read.
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
          (ErrIoRead (error-from-label "file-read-chunk" status)))))))

;: Write `contents` to a stdlib-managed write-mode file handle.
;:
;: The stdlib retries short host writes until all bytes are accepted or a
;: host error is returned. Closed, invalid, read-only, and unsupported handles
;: return `IoUnsupported`.
(define (file-write [handle : FileHandle] [contents : (& contents str)]) : ResultIoUnit
  (let
    [contents-text : String (string.copy contents)]
    [status : i64 (file-write-status (struct-get handle id) contents-text)]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-write-unsupported-message)))
        (ErrIoUnit (error-from-label "file-write" status))))))

;: Flush a stdlib-managed write-mode file handle.
;:
;: Closed, invalid, read-only, and unsupported handles return
;: `IoUnsupported`; host flush failures are mapped through `error-from-status`.
(define (file-flush [handle : FileHandle]) : ResultIoUnit
  (let
    [status : i64 (file-flush-status (struct-get handle id))]
    (if (= status io-status-ok)
      OkIoUnit
      (if (= status io-status-unsupported)
        (ErrIoUnit (IoUnsupported (file-flush-unsupported-message)))
        (ErrIoUnit (error-from-label "file-flush" status))))))

;: Read `path` and return either its contents or a structured I/O error.
;:
;: Missing paths return `IoNotFound`. Empty paths return `IoInvalidPath`.
(define (try-read-file [path : (& path str)]) : ResultIoString
  (let
    [path-text : String (string.copy path)]
    (if (empty-path? path)
      (ErrIoString (invalid-path-error path))
      (let
        [status : i64 (read-file-status path-text)]
        (if (= status io-status-ok)
          (OkIoString (read-file path-text))
          (ErrIoString (error-from-status path status)))))))

;: Write `contents` to `path`, returning a structured result.
;:
;: Empty paths return `IoInvalidPath`.
(define (try-write-file [path : (& path str)] [contents : (& contents str)]) : ResultIoUnit
  (let
    [path-text : String (string.copy path)]
    [contents-text : String (string.copy contents)]
    (if (empty-path? path)
      (ErrIoUnit (invalid-path-error path))
      (let
        [status : i64 (write-file-status path-text contents-text)]
        (if (= status io-status-ok)
          OkIoUnit
          (ErrIoUnit (error-from-status path status)))))))

;: Probe whether `path` exists, returning a structured result.
;:
;: Missing paths are represented as `OkIoBool false`, because absence is an
;: expected result of an existence probe. Empty paths return `IoInvalidPath`.
(define (try-file-exists? [path : (& path str)]) : ResultIoBool
  (let
    [path-text : String (string.copy path)]
    (if (empty-path? path)
      (ErrIoBool (invalid-path-error path))
      (let
        [status : i64 (file-exists-status path-text)]
        (if (= status io-status-ok)
          (OkIoBool true)
          (if (status-expected-absence? status)
            (OkIoBool false)
            (ErrIoBool (error-from-status path status))))))))

;: Append `contents` to `path`, returning a structured result.
;:
;: The runtime opens the path in host append mode where available, preserving
;: existing contents and creating the file when missing. Empty paths return
;: `IoInvalidPath`.
(define (try-append-file [path : (& path str)] [contents : (& contents str)]) : ResultIoUnit
  (let
    [path-text : String (string.copy path)]
    [contents-text : String (string.copy contents)]
    (if (empty-path? path)
      (ErrIoUnit (invalid-path-error path))
      (let
        [status : i64 (append-file-status path-text contents-text)]
        (if (= status io-status-ok)
          OkIoUnit
          (ErrIoUnit (error-from-status path status)))))))

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
    [(ErrIoUnit error) (panic (error-message error))]))

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
;: The returned bytes are represented as `String`.
(define (stdin-read-bytes [count : i64]) : StdinRead
  (let
    [text : String (read-stdin-bytes count)]
    (StdinRead text (stdin-eof?))))

;: Write `text` to stdout without adding a newline.
(define (stdout-write [text : (& text str)]) : unit
  (print-string (string.copy text)))

;: Write `text` and a trailing newline to stdout.
;:
;: This convenience helper allocates the newline-appended string.
(define (stdout-write-line [text : (& text str)]) : unit
  (let
    [newline : String "\n"]
    (print-string (string.append text (& newline)))))

;: Flush stdout.
(define (stdout-flush) : unit
  (flush-stdout))

;: Write `text` to stderr without adding a newline.
(define (stderr-write [text : (& text str)]) : unit
  (print-error (string.copy text)))

;: Write `text` and a trailing newline to stderr.
;:
;: This convenience helper allocates the newline-appended string.
(define (stderr-write-line [text : (& text str)]) : unit
  (let
    [newline : String "\n"]
    (print-error (string.append text (& newline)))))

(test
  io-core-macros-prelude
  (let
    [zero : i64
      (if (> (stdlib.io.arg-count) 0)
        0
        0)]
    [value : i64 0]
    (begin
      (if (not (and (!= zero 0) (= (/ 100 zero) 100)))
        unit
        (begin
          (/ 1 0)
          unit))
      (if (or (= zero 0) (= (/ 100 zero) 100))
        unit
        (begin
          (/ 1 0)
          unit))
      (when (= zero 0) (set! value 11))
      (unless (!= zero 0) (set! value (+ value 31)))
      (if (= value 42)
        unit
        (begin
          (/ 1 0)
          unit)))))

;; Inline test coverage.
(cfg
  test
  (define (io-edges-test-fail [message : String]) : unit
    (panic message)))

(cfg
  test
  (define (io-edges-test-assert-true [condition : bool] [message : String]) : unit
    (if condition
      unit
      (io-edges-test-fail message))))

(cfg
  test
  (define (io-edges-test-assert-false [condition : bool] [message : String]) : unit
    (io-edges-test-assert-true (not condition) message)))

(cfg
  test
  (define (io-edges-test-assert-string-eq
    [actual : (& actual str)]
    [expected : (& expected str)]
    [message : String]) : unit
    (io-edges-test-assert-true (string.eq actual expected) message)))

(cfg
  test
  (define (io-edges-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (io-edges-test-assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define io-file : String
    "tests/scratch/io_edges_file.txt"))
(cfg
  test
  (define io-empty-file : String
    "tests/scratch/io_edges_empty.txt"))
(cfg
  test
  (define io-created-file : String
    "tests/scratch/io_edges_created_"))
(cfg
  test
  (define io-missing-file : String
    "tests/scratch/io_edges_missing.txt"))
(cfg
  test
  (define io-missing-parent-file : String
    "tests/scratch/stdlib-inline-missing-parent/io_edges.txt"))
(cfg
  test
  (define io-directory-path : String
    "tests/scratch"))

(cfg
  test
  (define (io-edges-test-expect-try-read-ok [path : String] [expected : String]) : unit
    (match (try-read-file (& path))
      [(OkIoString contents)
        (io-edges-test-assert-owned-string-eq
          contents
          expected
          "try-read-file returned contents")]
      [(ErrIoString error) (panic (error-message error))])))

(cfg
  test
  (define (io-edges-test-expect-try-read-missing [path : String]) : unit
    (match (try-read-file (& path))
      [(OkIoString _) (panic "try-read-file unexpectedly read missing file")]
      [(ErrIoString error)
        (begin
          (io-edges-test-assert-true
            (error-not-found? error)
            "missing read error kind")
          (io-edges-test-assert-owned-string-eq
            (error-message error)
            (string.append "io: not found: " path)
            "missing read error render"))])))

(cfg
  test
  (define (io-edges-test-expect-try-write-ok
    [path : String]
    [contents : String]) : unit
    (match (try-write-file (& path) (& contents))
      [(OkIoUnit) unit]
      [(ErrIoUnit error) (panic (error-message error))])))

(cfg
  test
  (define (io-edges-test-expect-try-read-error [path : String]) : unit
    (match (try-read-file (& path))
      [(OkIoString _) (panic "try-read-file unexpectedly succeeded")]
      [(ErrIoString _) unit])))

(cfg
  test
  (define (io-edges-test-expect-try-write-error [path : String]) : unit
    (let
      [contents : String "bad"]
      (match (try-write-file (& path) (& contents))
        [(OkIoUnit) (panic "try-write-file unexpectedly succeeded")]
        [(ErrIoUnit _) unit]))))

(cfg
  test
  (define (io-edges-test-expect-try-append-error [path : String]) : unit
    (let
      [contents : String "bad"]
      (match (try-append-file (& path) (& contents))
        [(OkIoUnit) (panic "try-append-file unexpectedly succeeded")]
        [(ErrIoUnit _) unit]))))

(cfg
  test
  (define (io-edges-test-try-file-exists? [path : String]) : ResultIoBool
    (try-file-exists? (& path))))

(cfg
  test
  (define (io-edges-test-missing-path [prefix : String]) : String
    (let
      [index : i64 0]
      [candidate : String (string.copy (& prefix))]
      [done : bool false]
      (begin
        (while (not done)
          (let
            [suffix : String (string.int->string index)]
            [path : String (string.append (& prefix) (& suffix))]
            (match (io-edges-test-try-file-exists? path)
              [(OkIoBool exists)
                (if exists
                  (set! index (+ index 1))
                  (begin
                    (set! candidate path)
                    (set! done true)))]
              [(ErrIoBool error) (panic (error-message error))])))
        candidate))))

(cfg
  test
  (define (io-edges-test-read-file-or [path : String] [fallback : String]) : String
    (read-file-or (& path) fallback)))

(cfg
  test
  (define (io-edges-test-file-nonempty? [path : String]) : bool
    (file-nonempty? (& path))))

(cfg
  test
  (define (io-edges-test-try-append-file [path : String] [contents : String]) : ResultIoUnit
    (try-append-file (& path) (& contents))))

(cfg
  test
  (define (io-edges-test-append-file [path : String] [contents : String]) : unit
    (append-file (& path) (& contents))))

(cfg
  test
  (define (io-edges-test-expect-invalid-path [error : IoError]) : unit
    (begin
      (io-edges-test-assert-true
        (error-invalid-path? error)
        "invalid path error kind")
      (io-edges-test-assert-owned-string-eq
        (error-message error)
        "io: invalid path: "
        "invalid path error render"))))

(cfg
  test
  (define (io-edges-test-main) : i64
    (begin
      (io-edges-test-expect-try-read-missing io-missing-file)
      (match (io-edges-test-try-file-exists? io-missing-file)
        [(OkIoBool exists)
          (io-edges-test-assert-false exists "missing file does not exist")]
        [(ErrIoBool error) (panic (error-message error))])
      (let
        [path : String ""]
        (match (try-read-file (& path))
          [(OkIoString _) (panic "empty path read should fail")]
          [(ErrIoString error) (io-edges-test-expect-invalid-path error)]))
      (let
        [path : String ""]
        [contents : String "bad"]
        (match (try-write-file (& path) (& contents))
          [(OkIoUnit) (panic "empty path write should fail")]
          [(ErrIoUnit error) (io-edges-test-expect-invalid-path error)]))
      (let
        [path : String ""]
        [contents : String "bad"]
        (match (try-append-file (& path) (& contents))
          [(OkIoUnit) (panic "empty path append should fail")]
          [(ErrIoUnit error) (io-edges-test-expect-invalid-path error)]))
      (io-edges-test-expect-try-read-error io-directory-path)
      (io-edges-test-expect-try-write-error io-missing-parent-file)
      (io-edges-test-expect-try-append-error io-missing-parent-file)
      (io-edges-test-assert-owned-string-eq
        (io-edges-test-read-file-or io-missing-file "fallback")
        "fallback"
        "missing file fallback")
      (io-edges-test-assert-false
        (io-edges-test-file-nonempty? io-missing-file)
        "missing file is not nonempty")
      (write-file io-empty-file "")
      (io-edges-test-assert-false
        (io-edges-test-file-nonempty? io-empty-file)
        "empty file is not nonempty")
      (io-edges-test-expect-try-write-ok io-file "alpha")
      (io-edges-test-expect-try-read-ok io-file "alpha")
      (io-edges-test-assert-owned-string-eq
        (io-edges-test-read-file-or io-file "fallback")
        "alpha"
        "read existing file")
      (io-edges-test-assert-true
        (io-edges-test-file-nonempty? io-file)
        "written file is nonempty")
      (let
        [contents : String "-beta"]
        (match (io-edges-test-try-append-file io-file contents)
          [(OkIoUnit) unit]
          [(ErrIoUnit error) (panic (error-message error))]))
      (io-edges-test-assert-owned-string-eq
        (read-file io-file)
        "alpha-beta"
        "append existing file")
      (let
        [created-file : String (io-edges-test-missing-path io-created-file)]
        [contents : String "created"]
        (begin
          (io-edges-test-append-file created-file contents)
          (io-edges-test-assert-owned-string-eq
            (read-file created-file)
            "created"
            "append creates missing file")))
      42)))

(cfg
  test
  (test
    io-edges-api
    (if (= (io-edges-test-main) 42)
      unit
      (io-edges-test-fail "io-edges-api did not return 42"))))

;; Inline test coverage.
(cfg
  test
  (define (io-handle-test-fail [message : String]) : unit
    (panic message)))

(cfg
  test
  (define (io-handle-test-assert-true [condition : bool] [message : String]) : unit
    (if condition
      unit
      (io-handle-test-fail message))))

(cfg
  test
  (define (io-handle-test-assert-false [condition : bool] [message : String]) : unit
    (io-handle-test-assert-true (not condition) message)))

(cfg
  test
  (define (io-handle-test-assert-bool-eq
    [actual : bool]
    [expected : bool]
    [message : String]) : unit
    (io-handle-test-assert-true (= actual expected) message)))

(cfg
  test
  (define (io-handle-test-assert-string-eq
    [actual : (& actual str)]
    [expected : (& expected str)]
    [message : String]) : unit
    (io-handle-test-assert-true (string.eq actual expected) message)))

(cfg
  test
  (define (io-handle-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (io-handle-test-assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define handle-read-file : String
    "target/io_file_handle_read.txt"))
(cfg
  test
  (define handle-truncate-file : String
    "target/io_file_handle_truncate.txt"))
(cfg
  test
  (define handle-append-file : String
    "target/io_file_handle_append.txt"))
(cfg
  test
  (define handle-created-file-prefix : String
    "target/io_file_handle_created_"))
(cfg
  test
  (define handle-missing-file : String
    "target/io_file_handle_missing.txt"))

(cfg
  test
  (define (io-handle-test-assert-ok-unit
    [result : ResultIoUnit]
    [message : String]) : unit
    (match result
      [(OkIoUnit) unit]
      [(ErrIoUnit error) (panic (string.append message (error-message error)))])))

(cfg
  test
  (define (io-handle-test-expect-open-ok
    [result : ResultIoFile]
    [message : String]) : FileHandle
    (match result
      [(OkIoFile handle) handle]
      [(ErrIoFile error) (panic (string.append message (error-message error)))])))

(cfg
  test
  (define (io-handle-test-assert-close-unsupported
    [result : ResultIoUnit]
    [message : String]) : unit
    (match result
      [(OkIoUnit)
        (panic (string.append message "close unexpectedly succeeded"))]
      [(ErrIoUnit error)
        (io-handle-test-assert-true (error-unsupported? error) message)])))

(cfg
  test
  (define (io-handle-test-assert-unit-unsupported
    [result : ResultIoUnit]
    [operation : String]
    [message : String]) : unit
    (match result
      [(OkIoUnit)
        (panic
          (string.append
            message
            (string.append operation " unexpectedly succeeded")))]
      [(ErrIoUnit error)
        (io-handle-test-assert-true (error-unsupported? error) message)])))

(cfg
  test
  (define (io-handle-test-assert-open-unsupported
    [result : ResultIoFile]
    [message : String]) : unit
    (match result
      [(OkIoFile _)
        (panic (string.append message "open unexpectedly succeeded"))]
      [(ErrIoFile error)
        (io-handle-test-assert-true (error-unsupported? error) message)])))

(cfg
  test
  (define (io-handle-test-assert-open-invalid
    [result : ResultIoFile]
    [message : String]) : unit
    (match result
      [(OkIoFile _)
        (panic (string.append message "open unexpectedly succeeded"))]
      [(ErrIoFile error)
        (io-handle-test-assert-true (error-invalid-path? error) message)])))

(cfg
  test
  (define (io-handle-test-assert-open-not-found
    [result : ResultIoFile]
    [message : String]) : unit
    (match result
      [(OkIoFile _)
        (panic (string.append message "open unexpectedly succeeded"))]
      [(ErrIoFile error)
        (io-handle-test-assert-true (error-not-found? error) message)])))

(cfg
  test
  (define (io-handle-test-assert-read-ok
    [result : ResultIoRead]
    [expected-bytes : String]
    [expected-eof : bool]
    [message : String]) : unit
    (match result
      [(OkIoRead read)
        (begin
          (io-handle-test-assert-owned-string-eq
            (file-read-bytes read)
            expected-bytes
            (string.append message " bytes"))
          (io-handle-test-assert-bool-eq
            (file-read-eof? read)
            expected-eof
            (string.append message " eof")))]
      [(ErrIoRead error) (panic (string.append message (error-message error)))])))

(cfg
  test
  (define (io-handle-test-assert-read-unsupported
    [result : ResultIoRead]
    [message : String]) : unit
    (match result
      [(OkIoRead _)
        (panic (string.append message "read unexpectedly succeeded"))]
      [(ErrIoRead error)
        (io-handle-test-assert-true (error-unsupported? error) message)])))

(cfg
  test
  (define (io-handle-test-assert-read-invalid
    [result : ResultIoRead]
    [message : String]) : unit
    (match result
      [(OkIoRead _)
        (panic (string.append message "read unexpectedly succeeded"))]
      [(ErrIoRead error)
        (io-handle-test-assert-true (error-invalid-path? error) message)])))

(cfg
  test
  (define (io-handle-test-try-read-file [path : String]) : ResultIoString
    (try-read-file (& path))))

(cfg
  test
  (define (io-handle-test-try-file-exists? [path : String]) : ResultIoBool
    (try-file-exists? (& path))))

(cfg
  test
  (define (io-handle-test-missing-path [prefix : String]) : String
    (let
      [index : i64 0]
      [candidate : String (string.copy (& prefix))]
      [done : bool false]
      (begin
        (while (not done)
          (let
            [suffix : String (string.int->string index)]
            [path : String (string.append (& prefix) (& suffix))]
            (match (io-handle-test-try-file-exists? path)
              [(OkIoBool exists)
                (if exists
                  (set! index (+ index 1))
                  (begin
                    (set! candidate path)
                    (set! done true)))]
              [(ErrIoBool error) (panic (error-message error))])))
        candidate))))

(cfg
  test
  (define (io-handle-test-try-write-file [path : String] [contents : String]) : ResultIoUnit
    (try-write-file (& path) (& contents))))

(cfg
  test
  (define (io-handle-test-file-open [path : String] [mode : OpenMode]) : ResultIoFile
    (file-open (& path) mode)))

(cfg
  test
  (define (io-handle-test-file-write [handle : FileHandle] [contents : String]) : ResultIoUnit
    (file-write handle (& contents))))

(cfg
  test
  (define (io-handle-test-assert-file-contents
    [path : String]
    [expected : String]
    [message : String]) : unit
    (match (io-handle-test-try-read-file path)
      [(OkIoString contents)
        (io-handle-test-assert-owned-string-eq contents expected message)]
      [(ErrIoString error)
        (panic (string.append message (error-message error)))])))

(cfg
  test
  (define (io-handle-test-assert-file-exists
    [path : String]
    [expected : bool]
    [message : String]) : unit
    (match (io-handle-test-try-file-exists? path)
      [(OkIoBool exists)
        (io-handle-test-assert-bool-eq exists expected message)]
      [(ErrIoBool error) (panic (string.append message (error-message error)))])))

(cfg
  test
  (define (exercise-linux-file-handles) : unit
    (let
      [read-handle : FileHandle
        (begin
          (io-handle-test-assert-ok-unit
            (io-handle-test-try-write-file handle-read-file "abcdef")
            "seed read handle file: ")
          (io-handle-test-expect-open-ok
            (io-handle-test-file-open handle-read-file OpenRead)
            "open read: "))]
      (begin
        (io-handle-test-assert-read-invalid
          (file-read-chunk read-handle -1)
          "negative read count returns invalid path")
        (io-handle-test-assert-read-ok
          (file-read-chunk read-handle 0)
          ""
          false
          "zero read keeps current eof")
        (io-handle-test-assert-read-ok
          (file-read-chunk read-handle 2)
          "ab"
          false
          "first fixed chunk")
        (io-handle-test-assert-read-ok
          (file-read-chunk read-handle 3)
          "cde"
          false
          "second fixed chunk")
        (io-handle-test-assert-read-ok
          (file-read-chunk read-handle 10)
          "f"
          false
          "short read before eof")
        (io-handle-test-assert-read-ok
          (file-read-chunk read-handle 10)
          ""
          true
          "empty read observes eof")
        (io-handle-test-assert-read-ok
          (file-read-chunk read-handle 10)
          ""
          true
          "eof remains sticky")
        (io-handle-test-assert-ok-unit
          (file-close read-handle)
          "close read handle: ")
        (io-handle-test-assert-read-unsupported
          (file-read-chunk read-handle 1)
          "read after close returns unsupported")
        (io-handle-test-assert-close-unsupported
          (file-close read-handle)
          "double close returns unsupported")
        (io-handle-test-assert-read-unsupported
          (file-read-chunk (FileHandle 999) 1)
          "invalid read handle returns unsupported")
        (io-handle-test-assert-close-unsupported
          (file-close (FileHandle 999))
          "invalid handle returns unsupported")
        (io-handle-test-assert-unit-unsupported
          (io-handle-test-file-write (FileHandle 999) "x")
          "write"
          "invalid write handle returns unsupported")
        (io-handle-test-assert-unit-unsupported
          (file-flush (FileHandle 999))
          "flush"
          "invalid flush handle returns unsupported")
        (io-handle-test-assert-open-not-found
          (io-handle-test-file-open handle-missing-file OpenRead)
          "missing read open")
        (io-handle-test-assert-open-invalid
          (io-handle-test-file-open "" OpenRead)
          "empty path open")
        (io-handle-test-assert-ok-unit
          (io-handle-test-try-write-file handle-truncate-file "payload")
          "seed truncate file: ")
        (let
          [truncate-handle : FileHandle
            (io-handle-test-expect-open-ok
              (io-handle-test-file-open handle-truncate-file OpenWriteTruncate)
              "open truncate: ")]
          (begin
            (io-handle-test-assert-read-unsupported
              (file-read-chunk truncate-handle 1)
              "write-only handle read returns unsupported")
            (io-handle-test-assert-ok-unit
              (io-handle-test-file-write truncate-handle "alpha")
              "write truncate alpha: ")
            (io-handle-test-assert-ok-unit
              (io-handle-test-file-write truncate-handle "")
              "write truncate empty chunk: ")
            (io-handle-test-assert-ok-unit
              (io-handle-test-file-write truncate-handle "-beta")
              "write truncate beta: ")
            (io-handle-test-assert-ok-unit
              (file-flush truncate-handle)
              "flush truncate handle: ")
            (io-handle-test-assert-ok-unit
              (file-close truncate-handle)
              "close truncate handle: ")
            (io-handle-test-assert-file-contents
              handle-truncate-file
              "alpha-beta"
              "truncate writes replace existing file")
            (io-handle-test-assert-unit-unsupported
              (io-handle-test-file-write truncate-handle "after-close")
              "write"
              "write after close returns unsupported")
            (io-handle-test-assert-unit-unsupported
              (file-flush truncate-handle)
              "flush"
              "flush after close returns unsupported")))
        (io-handle-test-assert-ok-unit
          (io-handle-test-try-write-file handle-truncate-file "readonly")
          "seed read-only write test file: ")
        (let
          [read-only-handle : FileHandle
            (io-handle-test-expect-open-ok
              (io-handle-test-file-open handle-truncate-file OpenRead)
              "open read-only for write test: ")]
          (begin
            (io-handle-test-assert-unit-unsupported
              (io-handle-test-file-write read-only-handle "x")
              "write"
              "read-only handle write returns unsupported")
            (io-handle-test-assert-unit-unsupported
              (file-flush read-only-handle)
              "flush"
              "read-only handle flush returns unsupported")
            (io-handle-test-assert-ok-unit
              (file-close read-only-handle)
              "close read-only handle: ")))
        (io-handle-test-assert-ok-unit
          (io-handle-test-try-write-file handle-append-file "seed")
          "seed append file: ")
        (let
          [append-handle : FileHandle
            (io-handle-test-expect-open-ok
              (io-handle-test-file-open handle-append-file OpenWriteAppend)
              "open append existing: ")]
          (begin
            (io-handle-test-assert-ok-unit
              (io-handle-test-file-write append-handle "-tail")
              "write append tail: ")
            (io-handle-test-assert-ok-unit
              (file-flush append-handle)
              "flush append handle: ")
            (io-handle-test-assert-ok-unit
              (file-close append-handle)
              "close append handle: ")
            (io-handle-test-assert-file-contents
              handle-append-file
              "seed-tail"
              "append mode writes at end of file")))
        (let
          [created-path : String
            (io-handle-test-missing-path handle-created-file-prefix)]
          [created-handle : FileHandle
            (io-handle-test-expect-open-ok
              (io-handle-test-file-open created-path OpenWriteAppend)
              "open append create: ")]
          (begin
            (io-handle-test-assert-ok-unit
              (io-handle-test-file-write created-handle "created")
              "write append-created file: ")
            (io-handle-test-assert-ok-unit
              (file-flush created-handle)
              "flush created handle: ")
            (io-handle-test-assert-ok-unit
              (file-close created-handle)
              "close created handle: ")
            (io-handle-test-assert-file-exists
              created-path
              true
              "append mode creates a missing file")
            (io-handle-test-assert-file-contents
              created-path
              "created"
              "append-created file contains written bytes")))))))

(cfg
  test
  (define (exercise-linux-file-handle-reuse) : unit
    (let
      [i : i64 0]
      (begin
        (io-handle-test-assert-ok-unit
          (io-handle-test-try-write-file handle-read-file "reuse")
          "seed reusable handle file: ")
        (while (< i 1100)
          (let
            [handle : FileHandle
              (io-handle-test-expect-open-ok
                (io-handle-test-file-open handle-read-file OpenRead)
                "reopen reusable read handle: ")]
            (begin
              (io-handle-test-assert-ok-unit
                (file-close handle)
                "close reusable handle: ")
              (set! i (+ i 1)))))
        unit))))

(cfg
  test
  (define (io-handle-test-main) : i64
    (begin
      (cfg
        windows
        (begin
          (io-handle-test-assert-open-not-found
            (io-handle-test-file-open handle-missing-file OpenRead)
            "windows missing read handle reports not found")
          (io-handle-test-assert-read-unsupported
            (file-read-chunk (FileHandle 1) 1)
            "windows file reads are unsupported")
          (io-handle-test-assert-unit-unsupported
            (io-handle-test-file-write (FileHandle 1) "x")
            "write"
            "windows file writes are unsupported")
          (io-handle-test-assert-unit-unsupported
            (file-flush (FileHandle 1))
            "flush"
            "windows file flush is unsupported"))
        (begin
          (exercise-linux-file-handles)
          (exercise-linux-file-handle-reuse)))
      42)))

(cfg
  test
  (test
    io-file-handle-api
    (if (= (io-handle-test-main) 42)
      unit
      (io-handle-test-fail "io-file-handle-api did not return 42"))))