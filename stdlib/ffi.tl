;# FFI boundary helpers.
;#
;# Provides C string marshalling helpers for raw-pointer FFI boundaries. The
;# `ffi-c-string-copy!` family writes into caller-owned storage without
;# allocating. `ffi-c-string-alloc` and `ffi-cstr` allocate a NUL-terminated byte
;# buffer in the active arena and return its `(Ptr u8)`.
;#
;# Usage: `(import stdlib.ffi)`
;#
;# ```typelisp run
;# ;; doctest-exit: 0
;# (import stdlib.ffi)
;# (define (main) : i64
;#   (let
;#     [ptr : (Ptr u8) (ffi.ffi-cstr "abc")]
;#     (if (or
;#       (ptr-null? ptr)
;#       (not (= (cast (unsafe (ptr-read (ptr-offset ptr 3))) : i64) 0)))
;#       1
;#       0)))
;# ```
;: Result type for copying a TypeLisp string into caller-owned C string storage.
(module stdlib.ffi)

(defenum FfiCStringCopyResult
  (FfiCStringCopyOk i64)
  (FfiCStringInteriorNul)
  (FfiCStringBufferTooSmall i64))

;: Return the byte count needed for a NUL-terminated copy of `text`.
(define (ffi-c-string-required-bytes [text : String]) : i64
  (+ (string-length text) 1))

;: Return true when `text` contains an interior NUL byte.
(define (ffi-c-string-interior-nul? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (= (string-ref text i) #\nul')
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Copy exactly `n` bytes from `text` into `dst`.
;:
;: The caller must ensure `n` is at most `(string-length text)` and that `dst`
;: points to writable storage for at least `n` bytes.
(define (ffi-c-string-copy-bytes! [text : String] [dst : (MutPtr u8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (unsafe
          (ptr-write! (ptr-offset dst i) (cast (string-ref text i) : u8)))
        (set! i (+ i 1))))))

;: Copy `text` to caller-owned mutable storage and append the trailing NUL byte.
;:
;: Returns `FfiCStringInteriorNul` without writing when `text` contains a NUL
;: byte. Returns `FfiCStringBufferTooSmall required` without writing when
;: `capacity` is smaller than `(ffi-c-string-required-bytes text)`. On success,
;: returns `FfiCStringCopyOk bytes-written`, where `bytes-written` includes the
;: trailing NUL. Raw-pointer validity, alignment, and lifetime remain the
;: caller's responsibility.
(define (ffi-c-string-copy!
  [text : String]
  [dst : (MutPtr u8)]
  [capacity : i64]) : FfiCStringCopyResult
  (let
    [needed : i64 (stdlib.ffi.ffi-c-string-required-bytes text)]
    (if (stdlib.ffi.ffi-c-string-interior-nul? text)
      stdlib.ffi.FfiCStringInteriorNul
      (if (< capacity needed)
        (FfiCStringBufferTooSmall needed)
        (let
          [n : i64 (string-length text)]
          (begin
            (stdlib.ffi.ffi-c-string-copy-bytes! text dst n)
            (unsafe
              (ptr-write! (ptr-offset dst n) (cast #\nul' : u8)))
            (FfiCStringCopyOk needed)))))))

;: Allocate a NUL-terminated C string copy in the active arena.
;:
;: Returns null when `text` contains an interior NUL byte. On success, the
;: returned pointer remains valid until the active arena is rewound, reset, or
;: destroyed; callers must not free it and must not use it after the owning arena
;: is invalidated.
(define (ffi-c-string-alloc [text : String]) : (Ptr u8)
  (if (stdlib.ffi.ffi-c-string-interior-nul? text)
    (ptr-null : (Ptr u8))
    (let
      [needed : i64 (stdlib.ffi.ffi-c-string-required-bytes text)]
      [n : i64 (string-length text)]
      [buf : (Array u8) (make-array u8 needed)]
      [dst : (MutPtr u8)
        (unsafe
          (array-data buf))]
      (begin
        (stdlib.ffi.ffi-c-string-copy-bytes! text dst n)
        (unsafe
          (ptr-write! (ptr-offset dst n) (cast #\nul' : u8)))
        (unsafe
          (ptr-cast dst : (Ptr u8)))))))

;: Short alias for `ffi-c-string-alloc`.
(define (ffi-cstr [text : String]) : (Ptr u8)
  (stdlib.ffi.ffi-c-string-alloc text))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value ffi-c-string-required-bytes)
  (value ffi-c-string-interior-nul?)
  (value ffi-c-string-copy-bytes!)
  (value ffi-c-string-copy!)
  (value ffi-c-string-alloc)
  (value ffi-cstr)
  (type FfiCStringCopyResult)
  (variant FfiCStringCopyOk)
  (variant FfiCStringInteriorNul)
  (variant FfiCStringBufferTooSmall))