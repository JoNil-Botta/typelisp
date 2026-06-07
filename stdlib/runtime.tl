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
  (extern runtime-windows-get-std-handle (:symbol "GetStdHandle") : (-> i32 i64)))

;: Windows kernel32 `WriteFile` binding for the OS write primitive.
(cfg
  windows
  (extern runtime-windows-write-file (:symbol "WriteFile") : (->
    i64
    (Ptr u8)
    i32
    (MutPtr i32)
    i64
    i32)))

;: Windows kernel32 `ExitProcess` binding for the OS exit primitive.
(cfg
  windows
  (extern runtime-windows-exit-process (:symbol "ExitProcess") : (-> i32 never)))

;: Bootstrap fallback for stage0 compilers that predate local address-of.
(cfg
  (all windows (not feature-ptr-addr-of))
  (extern runtime-alloc (:symbol "tl_alloc") : (-> i64 (MutPtr u8))))

;: Convert a read-only byte pointer into an integer (syscall/handle) argument.
(define (runtime-ptr-arg [ptr : (Ptr u8)]) : i64
  (unsafe
    (cast (ptr->int ptr) : i64)))

;: Map a stdio fd (0/1/2) to its Windows standard handle, else treat the fd
;: value as the handle directly. Matches the former `_write` shim behavior.
(cfg
  windows
  (define (runtime-windows-fd-handle [fd : i64]) : i64
    (cond
      [(= fd 0) (runtime-windows-get-std-handle (cast -10 : i32))]
      [(= fd 1) (runtime-windows-get-std-handle (cast -11 : i32))]
      [(= fd 2) (runtime-windows-get-std-handle (cast -12 : i32))]
      [else fd])))

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
            :
            i64)))
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
            :
            i64))))
    (syscall 1 fd (runtime-ptr-arg buf) count)))

;: Terminate the process with `code`; never returns. Linux uses the
;: `exit_group` syscall (231); Windows uses ExitProcess.
(define (runtime-os-exit [code : i64]) : never
  (cfg
    windows
    (runtime-windows-exit-process (cast code : i32))
    (begin
      (syscall 231 code)
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
  (:export-symbol "tl_oob_abort")
  :
  never
  (begin
    (runtime-abort-write "tl: array index out of bounds\n")
    (runtime-os-exit 134)))

;: Fault handler for division (or remainder) by zero, exported as `tl_div_abort`.
(define (tl-runtime-div-abort)
  (:export-symbol "tl_div_abort")
  :
  never
  (begin
    (runtime-abort-write "tl: integer division or remainder error\n")
    (runtime-os-exit 135)))

;: Fault handler for an out-of-range shift amount, exported as `tl_shift_abort`.
(define (tl-runtime-shift-abort)
  (:export-symbol "tl_shift_abort")
  :
  never
  (begin
    (runtime-abort-write "tl: shift count out of range\n")
    (runtime-os-exit 129)))

;: General panic abort: write the supplied message to stderr and exit 134.
;: Exported as the fixed `tl_abort_string` symbol so `(panic …)` call sites and
;: the runtime's own error paths reach it unchanged (replaces the former
;: hand-written Linux/Windows `tl_abort_string` asm).
(define (tl-runtime-abort-string [message : String])
  (:export-symbol "tl_abort_string")
  :
  never
  (begin
    (runtime-abort-write message)
    (runtime-os-exit 134)))

;: Abort handler for an invalid arena/region mark, exported as `tl_region_abort`.
;: Reached from the allocator's region-reset validation (not the out-of-memory
;: path), so the allocating write is safe here.
(define (tl-runtime-region-abort)
  (:export-symbol "tl_region_abort")
  :
  never
  (begin
    (runtime-abort-write "tl: invalid region mark\n")
    (runtime-os-exit 134)))

;; NOTE: strlen / fflush are deliberately NOT moved here. They live in the
;; backend libc-shim block, which the published stage0 emits UNCONDITIONALLY
;; (unlike the gated abort handlers), and `strlen` is also called by
;; backend-emitted asm (tl_setup_argv). A TypeLisp export of `strlen`/`fflush`
;; therefore collides with the seed's shim during the no-Rust bootstrap. Moving
;; them needs a publish-first sequence (the new backend must ship as stage0
;; before the stdlib export lands) — tracked alongside the OOM-abort port
;; (#2221).