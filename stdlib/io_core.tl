;# Private backing storage for stdlib.io file-handle state.
;#
;# This module keeps raw handle-table implementation details out of the public
;# `stdlib.io` module surface. User programs should import `stdlib.io`.
(import stdlib.byte_buf)

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

;: Raw table access requires completed initialization, an in-range slot, and
;: the appropriate live-slot ownership. These helpers carry unsafe declaration
;: metadata so importing this implementation module cannot bypass that proof.
;: Return the raw file descriptor table pointer after external initialization.
(unsafe
  (define (io-file-fds-ptr) : (MutPtr i64)
    (unsafe
      (int->ptr io-file-fds-addr : (MutPtr i64)))))

;: Return the raw file mode table pointer.
(unsafe
  (define (io-file-modes-ptr) : (MutPtr i64)
    (unsafe
      (int->ptr io-file-modes-addr : (MutPtr i64)))))

;: Return the raw file handle state table pointer.
(unsafe
  (define (io-file-states-ptr) : (MutPtr i64)
    (unsafe
      (int->ptr io-file-states-addr : (MutPtr i64)))))

;: Return the raw file EOF state table pointer.
(unsafe
  (define (io-file-eofs-ptr) : (MutPtr bool)
    (unsafe
      (int->ptr io-file-eofs-addr : (MutPtr bool)))))

;: Return the raw cached-read readiness table pointer.
(unsafe
  (define (io-file-last-ready-ptr) : (MutPtr bool)
    (unsafe
      (int->ptr io-file-last-ready-addr : (MutPtr bool)))))

;: Return the raw cached-read byte table pointer.
(unsafe
  (define (io-file-last-bytes-ptr) : (MutPtr byte_buf.ByteBuf)
    (unsafe
      (int->ptr io-file-last-bytes-addr : (MutPtr byte_buf.ByteBuf)))))

;: Convert a mutable byte pointer into an integer address for global storage.
(unsafe
  (define (io-file-ptr-addr [ptr : (MutPtr u8)]) : u64
    (unsafe
      (ptr->int (ptr-cast ptr : (Ptr u8))))))

;: Read an i64 from a raw table at `index`.
(unsafe
  (define (io-file-i64-ref [items : (MutPtr i64)] [index : i64]) : i64
    (unsafe
      (ptr-read (ptr-cast (ptr-offset items index) : (Ptr i64))))))

;: Write an i64 to a raw table at `index`.
(unsafe
  (define (io-file-i64-set! [items : (MutPtr i64)] [index : i64] [value : i64]) : unit
    (unsafe
      (ptr-write! (ptr-offset items index) value))))

;: Read a bool from a raw table at `index`.
(unsafe
  (define (io-file-bool-ref [items : (MutPtr bool)] [index : i64]) : bool
    (unsafe
      (ptr-read (ptr-cast (ptr-offset items index) : (Ptr bool))))))

;: Write a bool to a raw table at `index`.
(unsafe
  (define (io-file-bool-set!
    [items : (MutPtr bool)]
    [index : i64]
    [value : bool]) : unit
    (unsafe
      (ptr-write! (ptr-offset items index) value))))

;: Read a byte buffer from a raw table at `index`.
(unsafe
  (define (io-file-byte-buf-ref
    [items : (MutPtr byte_buf.ByteBuf)]
    [index : i64]) : byte_buf.ByteBuf
    (unsafe
      (ptr-read (ptr-cast (ptr-offset items index) : (Ptr byte_buf.ByteBuf))))))

;: Write a byte buffer to a raw table at `index`.
(unsafe
  (define (io-file-byte-buf-set!
    [items : (MutPtr byte_buf.ByteBuf)]
    [index : i64]
    [value : byte_buf.ByteBuf]) : unit
    (unsafe
      (ptr-write! (ptr-offset items index) value))))

;: Clear all per-handle table state for a closed or reusable handle slot.
(unsafe
  (define (io-file-handle-clear! [handle : i64]) : unit
    (unsafe
      (begin
        (io-file-i64-set! (io-file-fds-ptr) handle 0)
        (io-file-i64-set! (io-file-modes-ptr) handle 0)
        (io-file-i64-set! (io-file-states-ptr) handle 0)
        (io-file-bool-set! (io-file-eofs-ptr) handle false)
        (io-file-bool-set! (io-file-last-ready-ptr) handle false)
        (io-file-byte-buf-set! (io-file-last-bytes-ptr) handle (byte_buf.new))
        unit))))

;: Return the first currently closed file-handle slot at or after `start`.
(unsafe
  (define (io-file-find-free-handle-from [start : i64]) : i64
    (let
      [i : i64 start]
      (begin
        (while (< i io-file-handle-cap)
          (begin
            (when
              (unsafe
                (= (io-file-i64-ref (io-file-states-ptr) i) 0))
              (return i))
            (set! i (+ i 1))))
        -1))))

;: Reserve a stdlib file-handle slot, reusing closed slots before failing.
(unsafe
  (define (io-file-alloc-handle!) : i64
    (begin
      (io-file-table-init!)
      (let
        [handle : i64
          (unsafe
            (io-file-find-free-handle-from io-file-handle-next))]
        [fallback : i64
          (if (< handle 0)
            (unsafe
              (io-file-find-free-handle-from 1))
            handle)]
        (if (< fallback 0)
          -1
          (begin
            (set! io-file-handle-next (+ fallback 1))
            (if (>= io-file-handle-next io-file-handle-cap)
              (set! io-file-handle-next 1)
              unit)
            fallback))))))

;; The table pointers are stored as raw integer addresses the region
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
      [_switched : unit (io-arena-set table-arena)]
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
      [last-bytes : (MutPtr byte_buf.ByteBuf)
        (unsafe
          (ptr-cast (io-runtime-alloc 16384) : (MutPtr byte_buf.ByteBuf)))]
      [_restored : unit (io-arena-set prev-arena)]
      [i : i64 0]
      (begin
        (set!
          io-file-fds-addr
          (unsafe
            (io-file-ptr-addr
              (unsafe
                (ptr-cast fds : (MutPtr u8))))))
        (set!
          io-file-modes-addr
          (unsafe
            (io-file-ptr-addr
              (unsafe
                (ptr-cast modes : (MutPtr u8))))))
        (set!
          io-file-states-addr
          (unsafe
            (io-file-ptr-addr
              (unsafe
                (ptr-cast states : (MutPtr u8))))))
        (set!
          io-file-eofs-addr
          (unsafe
            (io-file-ptr-addr
              (unsafe
                (ptr-cast eofs : (MutPtr u8))))))
        (set!
          io-file-last-ready-addr
          (unsafe
            (io-file-ptr-addr
              (unsafe
                (ptr-cast last-ready : (MutPtr u8))))))
        (set!
          io-file-last-bytes-addr
          (unsafe
            (io-file-ptr-addr
              (unsafe
                (ptr-cast last-bytes : (MutPtr u8))))))
        (while (< i io-file-handle-cap)
          (begin
            (unsafe
              (io-file-i64-set! (io-file-fds-ptr) i 0))
            (unsafe
              (io-file-i64-set! (io-file-modes-ptr) i 0))
            (unsafe
              (io-file-i64-set! (io-file-states-ptr) i 0))
            (unsafe
              (io-file-bool-set! (io-file-eofs-ptr) i false))
            (unsafe
              (io-file-bool-set! (io-file-last-ready-ptr) i false))
            (set! i (+ i 1))))
        unit))
    unit))

;: Return true when `raw` names an open stdlib file handle.
(define (io-file-valid-handle? [raw : i64]) : bool
  (begin
    (io-file-table-init!)
    (if (> raw 0)
      (if (< raw io-file-handle-cap)
        (unsafe
          (= (io-file-i64-ref (io-file-states-ptr) raw) 1))
        false)
      false)))

;: Clear and release a closed handle slot for reuse.
(unsafe
  (define (io-file-release-handle! [handle : i64]) : unit
    (begin
      (unsafe
        (io-file-handle-clear! handle))
      (if (< handle io-file-handle-next)
        (set! io-file-handle-next handle)
        unit)
      unit)))