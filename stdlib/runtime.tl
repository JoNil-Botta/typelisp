;# stdlib/runtime.tl - Always-linked runtime prelude (#2142 / #2150).
;#
;# This module holds the pieces of the runtime that call into the OS but that
;# the backend used to hand-write as assembly: the fault/abort handlers
;# (`tl-runtime-{oob,div,shift}-abort`, emitted by bounds/division/shift checks)
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

;: Convert a read-only byte pointer into an integer (syscall/handle) argument.
(define (runtime-ptr-arg [ptr : (Ptr u8)]) : i64
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
(define (runtime-os-write [fd : i64] [buf : (Ptr u8)] [count : i64]) : i64
  (cfg
    windows
    (cfg
      feature-ptr-addr-of
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
      (let
        [handle : i64 (runtime-windows-fd-handle fd)]
        [written : (MutPtr i32)
          (unsafe
            (ptr-cast (runtime-alloc 4) : (MutPtr i32)))]
        [ok : i32
          (runtime-windows-write-file handle buf (cast count : i32) written 0)]
        (if (= ok (cast 0 : i32))
          -1
          (cast
            (unsafe
              (ptr-read (ptr-cast written : (Ptr i32))))
            : i64))))
    (unsafe
      (syscall 1 fd (runtime-ptr-arg buf) count))))

;: Terminate the process with `code`; never returns. Linux uses the
;: `exit_group` syscall (231); Windows uses ExitProcess.
(define (runtime-os-exit [code : i64]) : never
  (cfg
    windows
    (runtime-windows-exit-process (cast code : i32))
    (begin
      (unsafe
        (syscall 231 code))
      (runtime-os-exit code))))

;: Write a fixed diagnostic message to stderr (fd 2), ignoring partial writes.
(define (runtime-abort-write [message : String]) : unit
  (let
    [len : i64 (string-length message)]
    [data : (Ptr u8)
      (unsafe
        (string-data message))]
    (begin
      (runtime-os-write 2 data len)
      unit)))

;: Fault handler for an out-of-bounds index. Exported as the fixed `tl_oob_abort`
;: symbol (#2143) so the backend's emitted bounds checks call it unchanged.
(define (tl-runtime-oob-abort)
  (:export-symbol "tl_oob_abort") : never
  (begin
    (runtime-abort-write "tl: array index out of bounds\n")
    (runtime-os-exit 134)))

;: Fault handler for division (or remainder) by zero, exported as `tl_div_abort`.
(define (tl-runtime-div-abort)
  (:export-symbol "tl_div_abort") : never
  (begin
    (runtime-abort-write "tl: integer division or remainder error\n")
    (runtime-os-exit 135)))

;: Fault handler for an out-of-range shift amount, exported as `tl_shift_abort`.
(define (tl-runtime-shift-abort)
  (:export-symbol "tl_shift_abort") : never
  (begin
    (runtime-abort-write "tl: shift count out of range\n")
    (runtime-os-exit 129)))

;: General panic abort: write the supplied message to stderr and exit 134.
;: Exported as the fixed `tl_abort_string` symbol so `(panic …)` call sites and
;: the runtime's own error paths reach it unchanged (replaces the former
;: hand-written Linux/Windows `tl_abort_string` asm).
(define (tl-runtime-abort-string [message : String])
  (:export-symbol "tl_abort_string") : never
  (begin
    (runtime-abort-write message)
    (runtime-os-exit 134)))

;: Render an integer into a fresh active-arena decimal string.
(define (tl-runtime-int-to-string [value : i64]) : String
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
(define (tl-runtime-substring [src : (Ptr u8)] [start : i64] [len : i64]) : String
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
(define (runtime-str-view-arena-get) : i64
  (if (= runtime-str-view-arena 0)
    (begin
      (set! runtime-str-view-arena (runtime-arena-make-atomic))
      runtime-str-view-arena)
    runtime-str-view-arena))

;: Build a borrowed `str` view record. `String` has the same two-word runtime
;: layout as a borrowed str record; callers see this fixed symbol through an
;: extern returning `(& text str)`.
(define (tl-runtime-str-view [text : (& text str)] [start : i64] [len : i64]) : String
  (let
    [src : (Ptr u8)
      (unsafe
        (ptr-offset (string-data text) start))]
    [home : i64 (runtime-arena-current)]
    [view-arena : i64 (runtime-str-view-arena-get)]
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

;: Concatenate two byte ranges into a fresh active-arena string.
(define (tl-runtime-string-concat
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]) : String
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
(define (tl-runtime-string-concat3
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]) : String
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
(define (tl-runtime-string-concat4
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]) : String
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
(define (tl-runtime-string-concat5
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]
  [e : (Ptr u8)]
  [e-len : i64]) : String
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
(define (tl-runtime-array-fill8 [buf : (MutPtr u8)] [len : i64] [value : u64])
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

;: Zero `byte-count` bytes starting at `buf`. Zero eight bytes per iteration
;: over the 64-bit-aligned prefix, then a byte tail for the remainder. The
;: previous byte-at-a-time loop was the single largest zeroing cost in the
;: self-compile (every `make-array` zero-fills its backing storage); writing
;: whole words cuts the loop trip count ~8x.
(define (tl-runtime-array-zero [buf : (MutPtr u8)] [byte-count : i64])
  (:export-symbol "tl_array_zero") : unit
  (let
    [word-count : i64 (/ byte-count 8)]
    [tail-start : i64 (* word-count 8)]
    [slots : (MutPtr u64)
      (unsafe
        (ptr-cast buf : (MutPtr u64)))]
    [w : i64 0]
    [i : i64 tail-start]
    (begin
      (while (< w word-count)
        (begin
          (unsafe
            (ptr-write! (ptr-offset slots w) (cast 0 : u64)))
          (set! w (+ w 1))))
      (while (< i byte-count)
        (begin
          (unsafe
            (ptr-write! (ptr-offset buf i) (cast 0 : u8)))
          (set! i (+ i 1))))
      unit)))

;: Abort handler for an invalid arena/region mark, exported as `tl_region_abort`.
;: Reached from the allocator's region-reset validation (not the out-of-memory
;: path), so the allocating write is safe here.
(define (tl-runtime-region-abort)
  (:export-symbol "tl_region_abort") : never
  (begin
    (runtime-abort-write "tl: invalid region mark\n")
    (runtime-os-exit 134)))

;: Out-of-memory abort, exported as `tl_oom_abort` (#2221). Reached from the
;: allocator (`tl_alloc`) when it cannot obtain more memory, so it MUST NOT
;: allocate: `runtime-abort-write` only takes the address/length of a static
;: string literal, and current Windows builds use `ptr-addr-of` so
;: `runtime-os-write` passes WriteFile a stack-backed byte-count cell.
;: Replaces the former hand-written `.L_tl_alloc_abort` asm (and its Windows
;: `.L_tl_win_write_abort` helper) on both targets.
(define (tl-runtime-oom-abort)
  (:export-symbol "tl_oom_abort") : never
  (begin
    (runtime-abort-write "tl: allocation failed\n")
    (runtime-os-exit 134)))