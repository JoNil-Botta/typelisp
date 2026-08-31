;# stdlib/runtime.tl - Always-linked runtime prelude.
;#
;# This module holds the pieces of the runtime that call into the OS but that
;# the backend used to hand-write as assembly: the fault/abort handlers
;# (`{oob,div,shift}-abort`, emitted by bounds/division/shift checks)
;# and the low-level OS write/exit primitives they need.
;#
;# It is implicitly imported into every executable (the compile driver injects
;# it for the entry program) and its abort handlers are kept as reachability
;# roots, so a program that can fault always links them — replacing the former
;# `tl_oob_abort`/`tl_div_abort`/`tl_shift_abort` assembly shims. Per-target
;# bodies are selected with `(cfg windows …)`; the Linux side issues raw
;# syscalls (the freestanding target has no libc), the Windows side calls
;# kernel32 directly.
;#
;# Usage: imported implicitly; programs do not need to import it by hand.
;#
;# This module imports nothing: it must be the always-linked prelude, so it
;# only uses builtins (string-length/string-data, syscall, raw pointer ops)
;# and its own externs. Keeping it import-free also avoids a shared-module
;# double-load when the entry program is given by an absolute path (its stdlib
;# imports would resolve to different path keys than a relative prelude load).
;: Windows kernel32 `GetStdHandle` binding for mapping fds 0/1/2 to handles.
(define (string-length [text : (& text str)]) : i64
  (__tl_string_length text))

(cfg
  windows
  (extern (runtime-windows-get-std-handle [arg0 : i32]) : i64 (:symbol "GetStdHandle")))

;: Windows kernel32 `WriteFile` binding for the OS write primitive.
(cfg
  windows
  (extern (runtime-windows-write-file
    [arg0 : i64]
    [arg1 : (Ptr u8)]
    [arg2 : i32]
    [arg3 : (MutPtr i32)]
    [arg4 : i64]) : i32 (:symbol "WriteFile")))

;: Windows kernel32 `ExitProcess` binding for the OS exit primitive.
(cfg
  windows
  (extern (runtime-windows-exit-process [arg0 : i32]) : never (:symbol "ExitProcess")))

;; Debug/backtrace builds use backend-owned accessors rather than exposing raw
;; section/TLS symbols to ordinary TypeLisp lowering. The whole block is
;; removed for release/direct-object builds by compiler-driver's internal cfg.
(cfg
  compiler-backtrace
  (extern (runtime-backtrace-map-begin) : (Ptr i64) (:symbol "tl_backtrace_map_begin")))
(cfg
  compiler-backtrace
  (extern (runtime-backtrace-map-end) : (Ptr i64) (:symbol "tl_backtrace_map_end")))
(cfg
  compiler-backtrace
  (extern (runtime-backtrace-string-begin) : (Ptr u8) (:symbol "tl_backtrace_string_begin")))
(cfg
  compiler-backtrace
  (extern (runtime-backtrace-string-end) : (Ptr u8) (:symbol "tl_backtrace_string_end")))
(cfg
  (all linux compiler-backtrace)
  (extern (runtime-backtrace-frame-pointer) : (Ptr i64) (:symbol "tl_backtrace_frame_pointer")))
(cfg
  (all linux compiler-backtrace)
  (extern (runtime-backtrace-stack-low) : i64 (:symbol "tl_backtrace_stack_low_get")))
(cfg
  (all linux compiler-backtrace)
  (extern (runtime-backtrace-stack-high) : i64 (:symbol "tl_backtrace_stack_high_get")))
(cfg
  (all windows compiler-backtrace)
  (extern (runtime-windows-capture-stack-back-trace
    [skip : u32]
    [count : u32]
    [frames : (MutPtr i64)]
    [hash : (MutPtr u32)]) : u16 (:symbol "RtlCaptureStackBackTrace")))
(cfg
  (all windows compiler-backtrace)
  (extern (runtime-windows-get-environment-strings) : (Ptr u8) (:symbol "GetEnvironmentStringsA")))

;: Runtime active-arena allocator. The backend still emits `tl_alloc`; this
;: prelude uses it for helpers that moved out of hand-written assembly.
(extern (runtime-alloc [arg0 : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

;: Stage2+ compiler builds expose a forward-only entry for destinations whose
;: allocation proves they cannot overlap the source. The embedded-stdlib cfg
;: is deliberately the bootstrap boundary: stage1 uses the old helper, then
;: the candidate compiler emits this symbol while building stage2.
(cfg
  (all compiler-build-identity embedded-stdlib-tlci)
  (unsafe
    (extern (runtime-copy-bytes! [dst : (MutPtr u8)] [src : (Ptr u8)] [n : i64]) : unit (:symbol "tl_memcpy_fresh"))))

(cfg
  (not (all compiler-build-identity embedded-stdlib-tlci))
  (unsafe
    (extern (runtime-copy-bytes! [dst : (MutPtr u8)] [src : (Ptr u8)] [n : i64]) : unit (:symbol "tl_memcpy"))))

;: Return the currently active arena handle.
(extern (runtime-arena-current) : i64 (:symbol "tl_arena_current"))

;: Create the process-lifetime atomic arena used for borrowed view records.
(extern (runtime-arena-make-atomic) : i64 (:symbol "tl_arena_make_atomic"))

(unsafe
  (extern (runtime-arena-set [arg0 : i64]) : unit (:symbol "tl_arena_set")))

;: Sequentially consistent atomic load of one raw `i64` pointer.
(define (atomic-i64-load-ptr [ptr : (Ptr i64)])
  (:export-symbol "tl_atomic_i64_load_ptr") : i64
  (unsafe
    (atomic-load ptr)))

;: Sequentially consistent atomic store of one raw `i64` pointer.
(define (atomic-i64-store-ptr! [ptr : (MutPtr i64)] [value : i64])
  (:export-symbol "tl_atomic_i64_store_ptr") : unit
  (unsafe
    (atomic-store! ptr value)))

;: Sequentially consistent atomic add of one raw `i64` pointer.
(define (atomic-i64-add-ptr! [ptr : (MutPtr i64)] [delta : i64])
  (:export-symbol "tl_atomic_i64_add_ptr") : unit
  (unsafe
    (atomic-add! ptr delta)))

;: Sequentially consistent atomic fetch-add of one raw `i64` pointer.
(define (atomic-i64-fetch-add-ptr! [ptr : (MutPtr i64)] [delta : i64])
  (:export-symbol "tl_atomic_i64_fetch_add_ptr") : i64
  (unsafe
    (atomic-fetch-add! ptr delta)))

;: Sequentially consistent compare-exchange of one raw `i64` pointer. Returns
;: the previous value observed at `ptr`.
(define (atomic-i64-cas-ptr!
  [ptr : (MutPtr i64)]
  [expected : i64]
  [new-value : i64])
  (:export-symbol "tl_atomic_i64_cas_ptr") : i64
  (unsafe
    (atomic-cas! ptr expected new-value)))

;: Sequentially consistent atomic load of one raw `i32` pointer.
(define (atomic-i32-load-ptr [ptr : (Ptr i32)])
  (:export-symbol "tl_atomic_i32_load_ptr") : i32
  (unsafe
    (atomic-load ptr)))

;: Sequentially consistent atomic store of one raw `i32` pointer.
(define (atomic-i32-store-ptr! [ptr : (MutPtr i32)] [value : i32])
  (:export-symbol "tl_atomic_i32_store_ptr") : unit
  (unsafe
    (atomic-store! ptr value)))

;: Sequentially consistent atomic add of one raw `i32` pointer.
(define (atomic-i32-add-ptr! [ptr : (MutPtr i32)] [delta : i32])
  (:export-symbol "tl_atomic_i32_add_ptr") : unit
  (unsafe
    (atomic-add! ptr delta)))

;: Sequentially consistent atomic fetch-add of one raw `i32` pointer.
(define (atomic-i32-fetch-add-ptr! [ptr : (MutPtr i32)] [delta : i32])
  (:export-symbol "tl_atomic_i32_fetch_add_ptr") : i32
  (unsafe
    (atomic-fetch-add! ptr delta)))

;: Sequentially consistent compare-exchange of one raw `i32` pointer. Returns
;: the previous value observed at `ptr`.
(define (atomic-i32-cas-ptr!
  [ptr : (MutPtr i32)]
  [expected : i32]
  [new-value : i32])
  (:export-symbol "tl_atomic_i32_cas_ptr") : i32
  (unsafe
    (atomic-cas! ptr expected new-value)))

;: Convert a read-only byte pointer into an integer (syscall/handle) argument.
(define (ptr-arg [ptr : (Ptr u8)]) : i64
  (unsafe
    (cast (ptr->int ptr) : i64)))

;: Map a stdio fd (0/1/2) to its Windows standard handle, else treat the fd
;: value as the handle directly. Matches the former `_write` shim behavior.
(cfg
  windows
  (define (runtime-windows-fd-handle [fd : i64]) : i64
    (if (= fd 0)
      (runtime-windows-get-std-handle (cast -10 : i32))
      (if (= fd 1)
        (runtime-windows-get-std-handle (cast -11 : i32))
        (if (= fd 2)
          (runtime-windows-get-std-handle (cast -12 : i32))
          fd)))))

;: Write `count` bytes from `buf` to `fd`; returns the bytes written or `-1`.
;: OS write primitive shared by the abort handlers (and, in later slices, the
;: stdlib IO layer). Linux uses the `write` syscall (1); Windows uses WriteFile.
(define (os-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg
    windows
    (let
      [handle : i64 (runtime-windows-fd-handle fd)]
      [written-cell : i32 (cast 0 : i32)]
      [written : (MutPtr i32)
        (unsafe
          (ptr-addr-of written-cell))]
      [ok : i32
        (runtime-windows-write-file handle buf (cast count : i32) written 0)]
      (if (= ok (cast 0 : i32))
        -1
        (cast
          (unsafe
            (ptr-read (ptr-cast written : (Ptr i32))))
          : i64)))
    (unsafe
      (syscall 1 fd (ptr-arg buf) count))))

;: Terminate the process with `code`; never returns. Linux uses the
;: `exit_group` syscall (231); Windows uses ExitProcess.
(define (os-exit [code : i64]) : never
  (cfg
    windows
    (runtime-windows-exit-process (cast code : i32))
    (begin
      (unsafe
        (syscall 231 code))
      (os-exit code))))

;: Write a fixed diagnostic message to stderr (fd 2), ignoring partial writes.
(define (abort-write [message : (& message str)]) : unit
  (let
    [len : i64 (string-length message)]
    [data : (Ptr u8)
      (unsafe
        (string-data message))]
    (begin
      (os-write 2 data len)
      unit)))

;: Debug-only never-reset arena diagnostics. The backend guard reaches these
;: fixed exports only when `compiler-arena-debug` is enabled, so default builds
;: carry neither the messages nor the failure paths.
(cfg
  compiler-arena-debug
  (define (arena-debug-protect-abort)
    (:export-symbol "tl_arena_debug_protect_abort") : never
    (begin
      (abort-write "tl: invalid never-reset arena protection\n")
      (os-exit 134))))

(cfg
  compiler-arena-debug
  (define (arena-debug-reset-abort)
    (:export-symbol "tl_arena_debug_reset_abort") : never
    (begin
      (abort-write "tl: never-reset arena reset\n")
      (os-exit 134))))

(cfg
  compiler-arena-debug
  (define (arena-debug-destroy-abort)
    (:export-symbol "tl_arena_debug_destroy_abort") : never
    (begin
      (abort-write "tl: never-reset arena destroy\n")
      (os-exit 134))))

(cfg
  compiler-arena-debug
  (define (arena-debug-pool-install-abort)
    (:export-symbol "tl_arena_debug_pool_install_abort") : never
    (begin
      (abort-write "tl: never-reset arena pool install\n")
      (os-exit 134))))

;: Write one non-negative integer without constructing a String. The digit
;: bytes come from static storage and recursion uses only the native stack, so
;: this stays safe when the current arena is null or exhausted.
(define (abort-write-decimal [value : u64]) : unit
  (begin
    (if (>= value 10)
      (abort-write-decimal (/ value 10))
      unit)
    (let
      [digit : u64 (% value 10)]
      [digits : (Ptr u8)
        (unsafe
          (string-data "0123456789"))]
      (begin
        (os-write
          2
          (unsafe
            (ptr-offset digits (cast digit : i64)))
          1)
        unit))))

;: Write a negative-domain integer magnitude. Keeping the value non-positive
;: makes INT64_MIN representable throughout the recursion.
(define (abort-write-negative-decimal [value : i64]) : unit
  (begin
    (if (<= value -10)
      (abort-write-negative-decimal (/ value 10))
      unit)
    (let
      [digit : i64 (- 0 (% value 10))]
      [digits : (Ptr u8)
        (unsafe
          (string-data "0123456789"))]
      (begin
        (os-write
          2
          (unsafe
            (ptr-offset digits digit))
          1)
        unit))))

;: Write a signed integer without allocating, including the full INT64_MIN
;: range needed by division and bounds diagnostics.
(define (abort-write-signed-decimal [value : i64]) : unit
  (if (< value 0)
    (begin
      (abort-write "-")
      (abort-write-negative-decimal value))
    (abort-write-decimal (cast value : u64))))

(cfg
  compiler-backtrace
  (define (abort-write-hex [value : u64]) : unit
    (begin
      (if (>= value 16)
        (abort-write-hex (/ value 16))
        unit)
      (let
        [digit : i64 (cast (% value 16) : i64)]
        [digits : (Ptr u8)
          (unsafe
            (string-data "0123456789abcdef"))]
        (begin
          (os-write
            2
            (unsafe
              (ptr-offset digits digit))
            1)
          unit)))))

(cfg
  compiler-backtrace
  (define (abort-write-address [value : i64]) : unit
    (begin
      (abort-write "0x")
      (abort-write-hex (cast value : u64)))))

;; Compare one NUL-terminated environment value with a static TypeLisp string
;; without allocating. The explicit length bound also makes a malformed host
;; block fail closed instead of turning a diagnostic into an unbounded scan.
(cfg
  compiler-backtrace
  (define (backtrace-c-string-eq?
    [value : (Ptr u8)]
    [expected : (& expected str)]) : bool
    (let
      [n : i64 (string-length expected)]
      [expected-data : (Ptr u8)
        (unsafe
          (string-data expected))]
      [i : i64 0]
      [equal : bool true]
      (begin
        (while (and equal (< i n))
          (if (=
            (unsafe
              (ptr-read (ptr-offset value i)))
            (unsafe
              (ptr-read (ptr-offset expected-data i))))
            (set! i (+ i 1))
            (set! equal false)))
        (and
          equal
          (=
            (unsafe
              (ptr-read (ptr-offset value n)))
            (cast 0 : u8)))))))

(cfg
  compiler-backtrace
  (define (backtrace-env-entry-value [entry : (Ptr u8)] [fold-ascii? : bool]) : (Ptr
      u8)
    (let
      [name-data : (Ptr u8)
        (unsafe
          (string-data "TYPELISP_BACKTRACE"))]
      [n : i64 18]
      [i : i64 0]
      [equal : bool true]
      (begin
        (while (and equal (< i n))
          (let
            [actual : u8
              (unsafe
                (ptr-read (ptr-offset entry i)))]
            [expected : u8
              (unsafe
                (ptr-read (ptr-offset name-data i)))]
            [actual-folded : u8
              (if (and
                fold-ascii?
                (>= actual (cast 'a' : u8))
                (<= actual (cast 'z' : u8)))
                (cast (- (cast actual : i64) 32) : u8)
                actual)]
            (if (and (not (= actual (cast 0 : u8))) (= actual-folded expected))
              (set! i (+ i 1))
              (set! equal false))))
        (if (and
          equal
          (=
            (unsafe
              (ptr-read (ptr-offset entry n)))
            (cast '=' : u8)))
          (unsafe
            (ptr-offset entry (+ n 1)))
          (ptr-null : (Ptr u8)))))))

(cfg
  (all linux compiler-backtrace)
  (define (backtrace-env-value) : (Ptr u8)
    (let
      [envp : (Ptr (Ptr u8))
        (unsafe
          (program-envp))]
      [index : i64 0]
      [result : (Ptr u8) (ptr-null : (Ptr u8))]
      [done : bool (ptr-null? envp)]
      (begin
        (while (and (not done) (< index 4096))
          (let
            [entry : (Ptr u8)
              (unsafe
                (ptr-read (ptr-offset envp index)))]
            (if (ptr-null? entry)
              (set! done true)
              (let
                [value : (Ptr u8) (backtrace-env-entry-value entry false)]
                (if (ptr-null? value)
                  (set! index (+ index 1))
                  (begin
                    (set! result value)
                    (set! done true)))))))
        result))))

(cfg
  (all windows compiler-backtrace)
  (define (backtrace-env-value) : (Ptr u8)
    (let
      [block : (Ptr u8) (runtime-windows-get-environment-strings)]
      [entry : (Ptr u8) block]
      [result : (Ptr u8) (ptr-null : (Ptr u8))]
      [scanned : i64 0]
      [done : bool (ptr-null? block)]
      (begin
        (while (and (not done) (< scanned 1048576))
          (if (=
            (unsafe
              (ptr-read entry))
            (cast 0 : u8))
            (set! done true)
            (let
              [value : (Ptr u8) (backtrace-env-entry-value entry true)]
              [length : i64 0]
              (if (ptr-null? value)
                (begin
                  (while (and
                    (< (+ scanned length) 1048576)
                    (not
                      (=
                        (unsafe
                          (ptr-read (ptr-offset entry length)))
                        (cast 0 : u8))))
                    (set! length (+ length 1)))
                  (set! length (+ length 1))
                  (set!
                    entry
                    (unsafe
                      (ptr-offset entry length)))
                  (set! scanned (+ scanned length)))
                (begin
                  (set! result value)
                  (set! done true))))))
        result))))

;; 0 = disabled, 1 = short (eight captured frames), 2 = full (64). The command
;; option controls whether metadata exists; the runtime environment is the last
;; word so one artifact can be quiet in automation and verbose interactively.
(cfg
  compiler-backtrace
  (define (backtrace-mode) : i64
    (let
      [value : (Ptr u8) (backtrace-env-value)]
      (if (ptr-null? value)
        2
        (cond
          [(or
              (backtrace-c-string-eq? value "0")
              (backtrace-c-string-eq? value "off")
              (backtrace-c-string-eq? value "disabled"))
            0]
          [(backtrace-c-string-eq? value "short") 1]
          [(backtrace-c-string-eq? value "full") 2]
          [else 2])))))

(cfg
  compiler-backtrace
  (define (backtrace-map-word [row : (Ptr i64)] [offset : i64]) : i64
    (unsafe
      (ptr-read (ptr-offset row offset)))))

(cfg
  compiler-backtrace
  (define (backtrace-string-range-valid?
    [address : i64]
    [length : i64]
    [begin : i64]
    [end : i64]) : bool
    (and
      (>= length 0)
      (<= length 4096)
      (>= address begin)
      (<= address end)
      (<= length (- end address)))))

(cfg
  compiler-backtrace
  (define (backtrace-row-valid?
    [row : (Ptr i64)]
    [string-begin : i64]
    [string-end : i64]) : bool
    (and
      (>= string-end string-begin)
      (<= (- string-end string-begin) 67108864)
      (backtrace-string-range-valid?
        (backtrace-map-word row 2)
        (backtrace-map-word row 3)
        string-begin
        string-end)
      (backtrace-string-range-valid?
        (backtrace-map-word row 4)
        (backtrace-map-word row 5)
        string-begin
        string-end))))

(cfg
  compiler-backtrace
  (define (backtrace-map-find [pc : i64] [begin : (Ptr i64)] [row-count : i64]) : (Ptr
      i64)
    (let
      [index : i64 0]
      [found : (Ptr i64) (ptr-null : (Ptr i64))]
      (begin
        (while (and (< index row-count) (ptr-null? found))
          (let
            [row : (Ptr i64)
              (unsafe
                (ptr-offset begin (* index 8)))]
            [start : i64 (backtrace-map-word row 0)]
            [end : i64 (backtrace-map-word row 1)]
            (if (and (> start 0) (> end start) (>= pc start) (< pc end))
              (set! found row)
              (set! index (+ index 1)))))
        found))))

(cfg
  compiler-backtrace
  (define (backtrace-runtime-path? [row : (Ptr i64)]) : bool
    (let
      [path-address : i64 (backtrace-map-word row 4)]
      [path-length : i64 (backtrace-map-word row 5)]
      [suffix-length : i64 17]
      [suffix-data : (Ptr u8)
        (unsafe
          (string-data "stdlib/runtime.tl"))]
      [path-data : (Ptr u8)
        (unsafe
          (int->ptr (cast path-address : u64) : (Ptr u8)))]
      [i : i64 0]
      [equal : bool (>= path-length suffix-length)]
      (begin
        (while (and equal (< i suffix-length))
          (let
            [actual : u8
              (unsafe
                (ptr-read
                  (ptr-offset path-data (+ (- path-length suffix-length) i))))]
            [expected : u8
              (unsafe
                (ptr-read (ptr-offset suffix-data i)))]
            (if (or
              (= actual expected)
              (and (= expected (cast '/' : u8)) (= actual (cast '\\' : u8))))
              (set! i (+ i 1))
              (set! equal false))))
        equal))))

(cfg
  compiler-backtrace
  (define (backtrace-write-frame [ordinal : i64] [pc : i64] [row : (Ptr i64)]) : unit
    (begin
      (abort-write "  ")
      (abort-write-signed-decimal ordinal)
      (abort-write ": ")
      (if (ptr-null? row)
        (begin
          (abort-write "<unknown> (")
          (abort-write-address pc)
          (abort-write ")\n"))
        (let
          [name-address : i64 (backtrace-map-word row 2)]
          [name-length : i64 (backtrace-map-word row 3)]
          [path-address : i64 (backtrace-map-word row 4)]
          [path-length : i64 (backtrace-map-word row 5)]
          [line : i64 (backtrace-map-word row 6)]
          [column : i64 (backtrace-map-word row 7)]
          (begin
            (os-write
              2
              (unsafe
                (int->ptr (cast name-address : u64) : (Ptr u8)))
              name-length)
            (if (> path-length 0)
              (begin
                (abort-write " at ")
                (os-write
                  2
                  (unsafe
                    (int->ptr (cast path-address : u64) : (Ptr u8)))
                  path-length)
                (if (> line 0)
                  (begin
                    (abort-write ":")
                    (abort-write-signed-decimal line)
                    (if (> column 0)
                      (begin
                        (abort-write ":")
                        (abort-write-signed-decimal column))
                      unit))
                  unit))
              (begin
                (abort-write " (")
                (abort-write-address pc)
                (abort-write ")")))
            (abort-write "\n")))))))

(cfg
  compiler-backtrace
  (define (backtrace-write-repeat [count : i64]) : unit
    (when
      (> count 1)
      (begin
        (abort-write "     [repeated ")
        (abort-write-signed-decimal count)
        (abort-write " frames]\n")))))

(cfg
  compiler-backtrace
  (define (backtrace-render-addresses
    [addresses : (Ptr i64)]
    [count : i64]
    [limit : i64]) : unit
    (let
      [map-begin : (Ptr i64) (runtime-backtrace-map-begin)]
      [map-end : (Ptr i64) (runtime-backtrace-map-end)]
      [string-begin : (Ptr u8) (runtime-backtrace-string-begin)]
      [string-end : (Ptr u8) (runtime-backtrace-string-end)]
      [begin-address : i64
        (cast
          (unsafe
            (ptr->int map-begin))
          : i64)]
      [end-address : i64
        (cast
          (unsafe
            (ptr->int map-end))
          : i64)]
      [string-begin-address : i64
        (cast
          (unsafe
            (ptr->int string-begin))
          : i64)]
      [string-end-address : i64
        (cast
          (unsafe
            (ptr->int string-end))
          : i64)]
      [byte-count : i64 (- end-address begin-address)]
      [valid-map? : bool
        (and (>= byte-count 0) (<= byte-count 67108864) (= (% byte-count 64) 0))]
      [row-count : i64
        (if valid-map?
          (/ byte-count 64)
          0)]
      [index : i64 0]
      [shown : i64 0]
      (when
        (and (> row-count 0) (> count 0))
        (begin
          (abort-write "stack backtrace:\n")
          (while (and (< index count) (< shown limit))
            (let
              [return-address : i64
                (unsafe
                  (ptr-read (ptr-offset addresses index)))]
              [pc : i64
                (if (> return-address 0)
                  (- return-address 1)
                  0)]
              [located-row : (Ptr i64)
                (backtrace-map-find pc map-begin row-count)]
              [row : (Ptr i64)
                (if (or
                  (ptr-null? located-row)
                  (not
                    (backtrace-row-valid?
                      located-row
                      string-begin-address
                      string-end-address)))
                  (ptr-null : (Ptr i64))
                  located-row)]
              [repeat-count : i64 1]
              (begin
                (while (and
                  (< (+ index repeat-count) count)
                  (=
                    (unsafe
                      (ptr-read (ptr-offset addresses (+ index repeat-count))))
                    return-address))
                  (set! repeat-count (+ repeat-count 1)))
                (if (and (not (ptr-null? row)) (backtrace-runtime-path? row))
                  unit
                  (begin
                    (backtrace-write-frame shown pc row)
                    (backtrace-write-repeat repeat-count)
                    (set! shown (+ shown 1))))
                (set! index (+ index repeat-count))))))))))

(cfg
  (all linux compiler-backtrace)
  (define (abort-write-backtrace) : unit
    (let
      [mode : i64 (backtrace-mode)]
      [limit : i64
        (if (= mode 1)
          8
          64)]
      [low : i64 (runtime-backtrace-stack-low)]
      [high : i64 (runtime-backtrace-stack-high)]
      [frame : (Ptr i64) (runtime-backtrace-frame-pointer)]
      [addresses : (Array i64 64) (init)]
      [count : i64 0]
      [done : bool (= mode 0)]
      (begin
        (while (and (not done) (< count limit))
          (let
            [frame-address : i64
              (cast
                (unsafe
                  (ptr->int frame))
                : i64)]
            (if (or
              (= frame-address 0)
              (not (= (bit-and frame-address 7) 0))
              (< frame-address low)
              (> frame-address (- high 16)))
              (set! done true)
              (let
                [next-address : i64 (backtrace-map-word frame 0)]
                [return-address : i64 (backtrace-map-word frame 1)]
                (begin
                  (set! (array-ref addresses count) return-address)
                  (set! count (+ count 1))
                  (if (or
                    (<= next-address frame-address)
                    (< next-address low)
                    (> next-address (- high 16)))
                    (set! done true)
                    (set!
                      frame
                      (unsafe
                        (int->ptr (cast next-address : u64) : (Ptr i64))))))))))
        (backtrace-render-addresses
          (unsafe
            (ptr-cast (ptr-addr-of (array-ref addresses 0)) : (Ptr i64)))
          count
          limit)
        ;; Keep ADDRESSES live across rendering. A tail call would release this
        ;; frame and let the renderer overwrite its stack-backed input array.
        unit))))

(cfg
  (all windows compiler-backtrace)
  (define (abort-write-backtrace) : unit
    (let
      [mode : i64 (backtrace-mode)]
      [limit : i64
        (if (= mode 1)
          8
          64)]
      [addresses : (Array i64 64) (init)]
      [count : u16
        (if (= mode 0)
          (cast 0 : u16)
          (runtime-windows-capture-stack-back-trace
            (cast 0 : u32)
            (cast limit : u32)
            (unsafe
              (ptr-addr-of (array-ref addresses 0)))
            (ptr-null : (MutPtr u32))))]
      (backtrace-render-addresses
        (unsafe
          (ptr-cast (ptr-addr-of (array-ref addresses 0)) : (Ptr i64)))
        (cast count : i64)
        limit)
      ;; Keep ADDRESSES live across rendering; see the Linux path above.
      unit)))

;: Emit the optional fatal backtrace, then terminate with `code`.
(cfg
  compiler-backtrace
  (define (abort-exit [code : i64]) : never
    (begin
      (abort-write-backtrace)
      (os-exit code))))

;: Allocation-free Windows VirtualAlloc failure reporter. KIND is 0 for an
;: ordinary arena and 1 for an atomic arena. OPERATION is 0 for reserve, 1 for
;: initial commit, and 2 for incremental growth commit. The backend captures
;: GetLastError immediately and passes it here after any required reservation
;: cleanup. Static message fragments plus stack-only decimal rendering avoid
;: re-entering tl_alloc on every path.
(cfg
  windows
  (define (windows-allocation-abort
    [kind : i64]
    [operation : i64]
    [requested : u64]
    [reserved : u64]
    [committed : u64]
    [windows-error : u64])
    (:export-symbol "tl_windows_allocation_abort") : never
    (begin
      (abort-write "tl: allocation failed: arena=")
      (if (= kind 1)
        (abort-write "atomic")
        (abort-write "ordinary"))
      (abort-write " operation=")
      (if (= operation 0)
        (abort-write "reserve")
        (if (= operation 1)
          (abort-write "initial-commit")
          (abort-write "growth-commit")))
      (abort-write " requested=")
      (abort-write-decimal requested)
      (abort-write " reserved=")
      (abort-write-decimal reserved)
      (abort-write " committed=")
      (abort-write-decimal committed)
      (abort-write " windows-error=")
      (abort-write-decimal windows-error)
      (abort-write "\n")
      (os-exit 134))))

;: Fault handler for an out-of-bounds index. Exported as the fixed `tl_oob_abort`
;: symbol so the backend's emitted bounds checks call it unchanged.
(define (oob-abort)
  (:export-symbol "tl_oob_abort") : never
  (begin
    (abort-write "tl: array index out of bounds\n")
    (cfg compiler-backtrace (abort-exit 134) (os-exit 134))))

;: Fault handler for division (or remainder) by zero, exported as `tl_div_abort`.
(define (div-abort)
  (:export-symbol "tl_div_abort") : never
  (begin
    (abort-write "tl: integer division or remainder error\n")
    (cfg compiler-backtrace (abort-exit 135) (os-exit 135))))

;: Fault handler for an out-of-range shift amount, exported as `tl_shift_abort`.
(define (shift-abort)
  (:export-symbol "tl_shift_abort") : never
  (begin
    (abort-write "tl: shift count out of range\n")
    (cfg compiler-backtrace (abort-exit 129) (os-exit 129))))

;: A compiler-emitted abort-site descriptor is four machine words:
;: path-data pointer, path byte length, one-based line, and one-based column.
;: Reading and rendering it stays allocation-free so diagnostics also work
;: while the active arena is unavailable.
(define (abort-site-word [site : (Ptr i64)] [offset : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset site offset))))

;: Render one compiler-emitted abort-site descriptor as `path:line:column: `.
(define (abort-write-site [site : (Ptr i64)]) : unit
  (let
    [path-address : i64 (abort-site-word site 0)]
    [path-length : i64 (abort-site-word site 1)]
    [line : i64 (abort-site-word site 2)]
    [column : i64 (abort-site-word site 3)]
    (begin
      (os-write
        2
        (unsafe
          (int->ptr (cast path-address : u64) : (Ptr u8)))
        path-length)
      (abort-write ":")
      (abort-write-signed-decimal line)
      (abort-write ":")
      (abort-write-signed-decimal column)
      (abort-write ": "))))

;: Report a source-located bounds failure with its index and length, then exit
;: with the legacy bounds-abort status.
(define (oob-abort-at [site : (Ptr i64)] [index : i64] [length : i64])
  (:export-symbol "tl_oob_abort_at") : never
  (begin
    (abort-write "tl: ")
    (abort-write-site site)
    (abort-write "array index out of bounds: index=")
    (abort-write-signed-decimal index)
    (abort-write " length=")
    (abort-write-signed-decimal length)
    (abort-write "\n")
    (cfg compiler-backtrace (abort-exit 134) (os-exit 134))))

;: Report a source-located integer division or remainder failure with both
;: operands, then exit with the legacy division-abort status.
(define (div-abort-at [site : (Ptr i64)] [dividend : i64] [divisor : i64])
  (:export-symbol "tl_div_abort_at") : never
  (begin
    (abort-write "tl: ")
    (abort-write-site site)
    (abort-write "integer division or remainder error: dividend=")
    (abort-write-signed-decimal dividend)
    (abort-write " divisor=")
    (abort-write-signed-decimal divisor)
    (abort-write "\n")
    (cfg compiler-backtrace (abort-exit 135) (os-exit 135))))

;: Report a source-located invalid shift with its count and operand width, then
;: exit with the legacy shift-abort status.  The fourth ABI flag selects
;: unsigned decimal rendering for unsigned count types.
(define (shift-abort-at
  [site : (Ptr i64)]
  [count : i64]
  [width : i64]
  [unsigned-count? : bool])
  (:export-symbol "tl_shift_abort_at") : never
  (begin
    (abort-write "tl: ")
    (abort-write-site site)
    (abort-write "shift count out of range: count=")
    (if unsigned-count?
      (abort-write-decimal (cast count : u64))
      (abort-write-signed-decimal count))
    (abort-write " width=")
    (abort-write-signed-decimal width)
    (abort-write "\n")
    (cfg compiler-backtrace (abort-exit 129) (os-exit 129))))

;: Report a source-located panic message and exit with the legacy panic status.
;: A trailing newline in `message` is preserved without adding a second one.
(define (panic-abort-at [site : (Ptr i64)] [message : (& message str)])
  (:export-symbol "tl_panic_at") : never
  (let
    [len : i64 (string-length message)]
    [ends-with-newline? : bool
      (if (> len 0)
        (=
          (cast
            (unsafe
              (ptr-read (ptr-offset (string-data message) (- len 1))))
            : i64)
          10)
        false)]
    (begin
      (abort-write "tl: ")
      (abort-write-site site)
      (abort-write "panic: ")
      (abort-write message)
      (if ends-with-newline?
        unit
        (abort-write "\n"))
      (cfg compiler-backtrace (abort-exit 134) (os-exit 134)))))

;: General panic abort: write the supplied message to stderr and exit 134.
;: Exported as the fixed `tl_abort_string` symbol so `(panic …)` call sites and
;: the runtime's own error paths reach it unchanged (replaces the former
;: hand-written Linux/Windows `tl_abort_string` asm).
(define (abort-string [message : (& message str)])
  (:export-symbol "tl_abort_string") : never
  (begin
    (abort-write message)
    (cfg compiler-backtrace (abort-exit 134) (os-exit 134))))

;; `typelisp test` enables this process-local state in its generated harness.
;; Outside that harness, stdlib.test assertion failures retain their historical
;; abort behavior. Hard faults and explicit panic calls never route through this
;; state and therefore still terminate the harness.
;: Whether the current process is running a generated `typelisp test` suite.
(define runtime-test-suite-active : bool
  false)

;: Whether an assertion has failed in the current generated test case.
(define runtime-test-case-failed : bool
  false)

;: Number of failed cases recorded by the current generated test suite.
(define runtime-test-failed-count : i64
  0)

;: Reset process-local reporting state before a generated test suite runs.
(define (runtime-test-suite-begin!) : unit
  (begin
    (set! runtime-test-suite-active true)
    (set! runtime-test-case-failed false)
    (set! runtime-test-failed-count 0)))

;: Reset the failure marker before a generated test case runs.
(define (runtime-test-case-begin!) : unit
  (set! runtime-test-case-failed false))

;: Record an assertion diagnostic, or abort outside a generated test suite.
(define (runtime-test-assertion-failure! [message : String]) : unit
  (if runtime-test-suite-active
    (begin
      (set! runtime-test-case-failed true)
      (abort-write "  ")
      (abort-write message)
      (abort-write "\n"))
    (begin
      (abort-write message)
      (os-exit 134))))

;: Finish the current case and return whether any assertion failed.
(define (runtime-test-case-finish!) : bool
  (begin
    (if runtime-test-case-failed
      (set! runtime-test-failed-count (+ runtime-test-failed-count 1))
      unit)
    runtime-test-case-failed))

;: Print the suite summary and return zero on success or one on test failures.
(define (runtime-test-suite-finish [total : i64]) : i64
  (let
    [passed : i64 (- total runtime-test-failed-count)]
    (begin
      (set! runtime-test-suite-active false)
      (abort-write "TypeLisp tests: ")
      (abort-write-signed-decimal passed)
      (abort-write " passed; ")
      (abort-write-signed-decimal runtime-test-failed-count)
      (abort-write " failed; ")
      (abort-write-signed-decimal total)
      (abort-write " total\n")
      (if (= runtime-test-failed-count 0)
        0
        1))))

;: Render an integer into a fresh active-arena decimal string.
(define (int-to-string [value : i64])
  (:export-symbol "tl_int_to_string") : String
  (let
    [negative : bool (< value 0)]
    [magnitude : i64
      (if negative
        value
        (- 0 value))]
    [digit-count : i64 1]
    [count-cursor : i64 magnitude]
    (begin
      (while (<= count-cursor -10)
        (begin
          (set! count-cursor (/ count-cursor 10))
          (set! digit-count (+ digit-count 1))))
      (let
        [len : i64
          (if negative
            (+ digit-count 1)
            digit-count)]
        [buf : (MutPtr u8) (runtime-alloc len)]
        [digit-index : i64 (- digit-count 1)]
        [write-cursor : i64 magnitude]
        [digit-base : i64
          (if negative
            1
            0)]
        (begin
          (if negative
            (unsafe
              (ptr-write! buf (cast 45 : u8)))
            unit)
          (while (>= digit-index 0)
            (let
              [digit : i64 (- 0 (% write-cursor 10))]
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset buf (+ digit-base digit-index))
                    (cast (+ 48 digit) : u8)))
                (set! write-cursor (/ write-cursor 10))
                (set! digit-index (- digit-index 1)))))
          (unsafe
            (string-from-bytes (ptr-cast buf : (Ptr u8)) len)))))))

;: Copy a byte slice into a fresh active-arena string.
(define (substring [src : (Ptr u8)] [start : i64] [len : i64])
  (:export-symbol "tl_substring") : String
  (let
    [dst : (MutPtr u8) (runtime-alloc len)]
    (begin
      (unsafe
        (runtime-copy-bytes! dst (ptr-offset src start) len))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))

;: Cached process-lifetime arena used for borrowed string views.
(define runtime-str-view-arena : i64
  0)

;: Return the borrowed-view arena, creating it on first use.
(define (str-view-arena-get) : i64
  (if (= runtime-str-view-arena 0)
    (begin
      (set! runtime-str-view-arena (runtime-arena-make-atomic))
      runtime-str-view-arena)
    runtime-str-view-arena))

;: Build a borrowed `str` view record. `String` has the same two-word runtime
;: layout as a borrowed str record; callers see this fixed symbol through an
;: extern returning `(& text str)`.
(define (str-view [text : (& text str)] [start : i64] [len : i64])
  (:export-symbol "tl_str_view") : String
  (let
    [src : (Ptr u8)
      (unsafe
        (ptr-offset (string-data text) start))]
    [home : i64 (runtime-arena-current)]
    [view-arena : i64 (str-view-arena-get)]
    (begin
      (unsafe
        (runtime-arena-set view-arena))
      (let
        [view : String
          (unsafe
            (string-from-bytes src len))]
        (begin
          (unsafe
            (runtime-arena-set home))
          view)))))

;; This is the low-level compatibility primitive used to implement public
;; string building and cannot depend on `stdlib.str_cat`.
;: Concatenate two byte ranges into a fresh active-arena string.
;; lint-allow: deprecated-string-concat
(define (string-concat
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64])
  (:export-symbol "tl_string_concat") : String
  (let
    [total : i64 (+ a-len b-len)]
    [dst : (MutPtr u8) (runtime-alloc total)]
    (begin
      (unsafe
        (runtime-copy-bytes! dst a a-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst a-len) b b-len))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))

;: Concatenate three byte ranges into a fresh active-arena string.
(define (string-concat3
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64])
  (:export-symbol "tl_string_concat3") : String
  (let
    [total : i64 (+ a-len (+ b-len c-len))]
    [dst : (MutPtr u8) (runtime-alloc total)]
    [off-b : i64 a-len]
    [off-c : i64 (+ a-len b-len)]
    (begin
      (unsafe
        (runtime-copy-bytes! dst a a-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-b) b b-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-c) c c-len))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))

;: Concatenate four byte ranges into a fresh active-arena string.
(define (string-concat4
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64])
  (:export-symbol "tl_string_concat4") : String
  (let
    [total : i64 (+ a-len (+ b-len (+ c-len d-len)))]
    [dst : (MutPtr u8) (runtime-alloc total)]
    [off-b : i64 a-len]
    [off-c : i64 (+ a-len b-len)]
    [off-d : i64 (+ a-len (+ b-len c-len))]
    (begin
      (unsafe
        (runtime-copy-bytes! dst a a-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-b) b b-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-c) c c-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-d) d d-len))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))

;: Concatenate five byte ranges into a fresh active-arena string.
(define (string-concat5
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]
  [e : (Ptr u8)]
  [e-len : i64])
  (:export-symbol "tl_string_concat5") : String
  (let
    [total : i64 (+ a-len (+ b-len (+ c-len (+ d-len e-len))))]
    [dst : (MutPtr u8) (runtime-alloc total)]
    [off-b : i64 a-len]
    [off-c : i64 (+ a-len b-len)]
    [off-d : i64 (+ a-len (+ b-len c-len))]
    [off-e : i64 (+ a-len (+ b-len (+ c-len d-len)))]
    (begin
      (unsafe
        (runtime-copy-bytes! dst a a-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-b) b b-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-c) c c-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-d) d d-len))
      (unsafe
        (runtime-copy-bytes! (ptr-offset dst off-e) e e-len))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))

;: Fill `len` pointer-sized array slots with `value`.
(define (array-fill8 [buf : (MutPtr u8)] [len : i64] [value : u64])
  (:export-symbol "tl_array_fill8") : unit
  (let
    [slots : (MutPtr u64)
      (unsafe
        (ptr-cast buf : (MutPtr u64)))]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (unsafe
            (ptr-write! (ptr-offset slots i) value))
          (set! i (+ i 1))))
      unit)))

;: Fill `count` pointer-sized slots at `buf` with `value`. The backend provides
;: the body as a `rep stosq` (see compiler-backend-runtime-mem-fill8-functions),
;: one instruction per slot under the deterministic instruction-count gate, and
;: a non-positive `count` writes nothing. Unlike `array-zero` this NEVER skips
;: its fill: array-zero's virgin-arena early-out is sound only for storage the
;: bump allocator just handed out, never for an arbitrary live buffer.
(extern (mem-fill8 [buf : (MutPtr u8)] [count : i64] [value : u64]) : unit (:symbol "tl_mem_fill8"))

;: Copy `count` bytes from `src` to `dst` FORWARD and byte-exactly: this is the
;: machine equivalent of `for (i = 0; i < count; i += 1) dst[i] = src[i]` for
;: every argument triple, which is what the optimizer's `copy_call` pass relies
;: on when it rewrites such a loop into one call (see its header). Deliberately
;: NOT `string`'s memcpy: that one is memmove, and memmove copies BACKWARD when
;: the destination overlaps above the source, where this loop instead
;: PROPAGATES the bytes it has just written. A non-positive `count` copies
;: nothing. The backend supplies the body (a wide `rep movsq` when `dst <= src`
;: or the ranges are disjoint, a byte `rep movsb` otherwise), so a copy costs
;: one instruction per eight bytes under the deterministic instruction-count
;: gate where the source loop cost three and a half per byte.
(extern (mem-copy-fwd [dst : (MutPtr u8)] [src : (Ptr u8)] [count : i64]) : unit (:symbol "tl_mem_copy_fwd"))

;: Zero `byte-count` bytes starting at `buf`. The backend provides the body
;: as a qword `rep stosq` plus a byte `rep stosb` tail (see
;: compiler-backend-runtime-array-zero-functions), which costs one instruction
;: per eight bytes under the deterministic instruction-count gate. The
;: byte-at-a-time loop before it was the single largest zeroing cost in the
;: self-compile (every `__tl_make-array` zero-fills its backing storage).
(extern (array-zero [buf : (MutPtr u8)] [byte-count : i64]) : unit (:symbol "tl_array_zero"))

;: Abort handler for an invalid arena/region mark, exported as `tl_region_abort`.
;: Reached from the allocator's region-reset validation (not the out-of-memory
;: path), so the allocating write is safe here.
(define (region-abort)
  (:export-symbol "tl_region_abort") : never
  (begin
    (abort-write "tl: invalid region mark\n")
    (cfg compiler-backtrace (abort-exit 134) (os-exit 134))))

;: Out-of-memory abort, exported as `tl_oom_abort`. Reached from the
;: allocator (`tl_alloc`) when it cannot obtain more memory, so it MUST NOT
;: allocate: `abort-write` only takes the address/length of a static
;: string literal, and current Windows builds use `ptr-addr-of` so
;: `os-write` passes WriteFile a stack-backed byte-count cell.
;: Replaces the former hand-written `.L_tl_alloc_abort` asm (and its Windows
;: `.L_tl_win_write_abort` helper) on both targets.
(define (oom-abort)
  (:export-symbol "tl_oom_abort") : never
  (begin
    (abort-write "tl: allocation failed\n")
    (os-exit 134)))