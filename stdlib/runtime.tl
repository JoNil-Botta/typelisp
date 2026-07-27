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
(define (string-length [text : String]) : i64
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

;: Runtime active-arena allocator. The backend still emits `tl_alloc`; this
;: prelude uses it for helpers that moved out of hand-written assembly.
(extern (runtime-alloc [arg0 : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

;: Internal raw byte copy primitive. Caller contract: `n >= 0`, `src` has at
;: least `n` readable initialized bytes, `dst` has at least `n` writable bytes,
;: and both ranges stay live for the call. `tl_memcpy` is memmove-safe for
;: overlapping `dst > src`.
(unsafe
  (extern (runtime-copy-bytes! [dst : (MutPtr u8)] [src : (Ptr u8)] [n : i64]) : unit (:symbol "tl_memcpy")))

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
(define (abort-write [message : String]) : unit
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

(define (abort-write-signed-decimal [value : i64]) : unit
  (if (< value 0)
    (begin
      (abort-write "-")
      (abort-write-negative-decimal value))
    (abort-write-decimal (cast value : u64))))

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
    (os-exit 134)))

;: Fault handler for division (or remainder) by zero, exported as `tl_div_abort`.
(define (div-abort)
  (:export-symbol "tl_div_abort") : never
  (begin
    (abort-write "tl: integer division or remainder error\n")
    (os-exit 135)))

;: Fault handler for an out-of-range shift amount, exported as `tl_shift_abort`.
(define (shift-abort)
  (:export-symbol "tl_shift_abort") : never
  (begin
    (abort-write "tl: shift count out of range\n")
    (os-exit 129)))

;: A compiler-emitted abort-site descriptor is four machine words:
;: path-data pointer, path byte length, one-based line, and one-based column.
;: Reading and rendering it stays allocation-free so diagnostics also work
;: while the active arena is unavailable.
(define (abort-site-word [site : (Ptr i64)] [offset : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset site offset))))

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
    (os-exit 134)))

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
    (os-exit 135)))

(define (shift-abort-at [site : (Ptr i64)] [count : i64] [width : i64])
  (:export-symbol "tl_shift_abort_at") : never
  (begin
    (abort-write "tl: ")
    (abort-write-site site)
    (abort-write "shift count out of range: count=")
    (abort-write-signed-decimal count)
    (abort-write " width=")
    (abort-write-signed-decimal width)
    (abort-write "\n")
    (os-exit 129)))

(define (panic-abort-at [site : (Ptr i64)] [message : String])
  (:export-symbol "tl_panic_at") : never
  (let
    [len : i64 (string-length message)]
    (begin
      (abort-write "tl: ")
      (abort-write-site site)
      (abort-write "panic: ")
      (abort-write message)
      (if (and
        (> len 0)
        (=
          (cast
            (unsafe
              (ptr-read (ptr-offset (string-data message) (- len 1))))
            : i64)
          10))
        unit
        (abort-write "\n"))
      (os-exit 134))))

;: General panic abort: write the supplied message to stderr and exit 134.
;: Exported as the fixed `tl_abort_string` symbol so `(panic …)` call sites and
;: the runtime's own error paths reach it unchanged (replaces the former
;: hand-written Linux/Windows `tl_abort_string` asm).
(define (abort-string [message : String])
  (:export-symbol "tl_abort_string") : never
  (begin
    (abort-write message)
    (os-exit 134)))

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

;: Zero `byte-count` bytes starting at `buf`. The backend provides the body
;: as a qword `rep stosq` plus a byte `rep stosb` tail (see
;: compiler-backend-runtime-array-zero-functions), which costs one instruction
;: per eight bytes under the deterministic instruction-count gate. The
;: byte-at-a-time loop before it was the single largest zeroing cost in the
;: self-compile (every `array.make-array` zero-fills its backing storage).
(extern (array-zero [buf : (MutPtr u8)] [byte-count : i64]) : unit (:symbol "tl_array_zero"))

;: Abort handler for an invalid arena/region mark, exported as `tl_region_abort`.
;: Reached from the allocator's region-reset validation (not the out-of-memory
;: path), so the allocating write is safe here.
(define (region-abort)
  (:export-symbol "tl_region_abort") : never
  (begin
    (abort-write "tl: invalid region mark\n")
    (os-exit 134)))

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