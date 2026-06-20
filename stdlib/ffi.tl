;# FFI boundary helpers.
;#
;# Provides C string marshalling helpers for raw-pointer FFI boundaries. The
;# `ffi-c-bytes-copy!` family writes borrowed bytes into caller-owned storage
;# without allocating. `ffi-c-bytes-alloc` and `ffi-cbytes` allocate a
;# NUL-terminated byte buffer in the active arena and return its `(Ptr u8)`.
;# Compatibility `ffi-c-string-*` wrappers borrow their input text as bytes and
;# delegate to the byte-slice path.
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
(module stdlib.ffi)

(import stdlib.byte_buf)

;: Result type for copying TypeLisp bytes into caller-owned C string storage.
(defenum FfiCStringCopyResult
  (FfiCStringCopyOk i64)
  (FfiCStringInteriorNul)
  (FfiCStringBufferTooSmall i64))

;: Return the byte count needed for a NUL-terminated copy of `view`.
(define (ffi-c-bytes-required-bytes [view : (& source bytes)]) : i64
  (+ (byte_buf.bytes-length view) 1))

;: Return true when `view` contains an interior NUL byte.
(define (ffi-c-bytes-interior-nul? [view : (& source bytes)]) : bool
  (let
    [n : i64 (byte_buf.bytes-length view)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (= (byte_buf.bytes-ref view i) (cast '\0' : u8))
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Copy exactly `n` bytes from `view` into `dst`.
;:
;: The caller must ensure `n` is at most `(bytes-length view)` and that `dst`
;: points to writable storage for at least `n` bytes.
(define (ffi-c-bytes-copy-bytes!
  [view : (& source bytes)]
  [dst : (MutPtr u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (unsafe
          (ptr-write! (ptr-offset dst i) (byte_buf.bytes-ref view i)))
        (set! i (+ i 1))))))

;: Copy `view` to caller-owned mutable storage and append the trailing NUL byte.
;:
;: Returns `FfiCStringInteriorNul` without writing when `view` contains a NUL
;: byte. Returns `FfiCStringBufferTooSmall required` without writing when
;: `capacity` is smaller than `(ffi-c-bytes-required-bytes view)`. On success,
;: returns `FfiCStringCopyOk bytes-written`, where `bytes-written` includes the
;: trailing NUL. Raw-pointer validity, alignment, and lifetime remain the
;: caller's responsibility.
(define (ffi-c-bytes-copy!
  [view : (& source bytes)]
  [dst : (MutPtr u8)]
  [capacity : i64]) : FfiCStringCopyResult
  (let
    [needed : i64 (ffi-c-bytes-required-bytes view)]
    (if (ffi-c-bytes-interior-nul? view)
      (FfiCStringInteriorNul)
      (if (< capacity needed)
        (FfiCStringBufferTooSmall needed)
        (let
          [n : i64 (byte_buf.bytes-length view)]
          (begin
            (ffi-c-bytes-copy-bytes! view dst n)
            (unsafe
              (ptr-write! (ptr-offset dst n) (cast '\0' : u8)))
            (FfiCStringCopyOk needed)))))))

;: Allocate a NUL-terminated C string copy of `view` in the active arena.
;:
;: Returns null when `view` contains an interior NUL byte. On success, the
;: returned pointer remains valid until the active arena is rewound, reset, or
;: destroyed; callers must not free it and must not use it after the owning arena
;: is invalidated.
(define (ffi-c-bytes-alloc [view : (& source bytes)]) : (Ptr u8)
  (if (ffi-c-bytes-interior-nul? view)
    (ptr-null : (Ptr u8))
    (let
      [needed : i64 (ffi-c-bytes-required-bytes view)]
      [n : i64 (byte_buf.bytes-length view)]
      [buf : (Array u8) (make-array u8 needed)]
      [dst : (MutPtr u8)
        (unsafe
          (array-data buf))]
      (begin
        (ffi-c-bytes-copy-bytes! view dst n)
        (unsafe
          (ptr-write! (ptr-offset dst n) (cast '\0' : u8)))
        (unsafe
          (ptr-cast dst : (Ptr u8)))))))

;: Short alias for `ffi-c-bytes-alloc`.
(define (ffi-cbytes [view : (& source bytes)]) : (Ptr u8)
  (ffi-c-bytes-alloc view))

;: Return the byte count needed for a NUL-terminated copy of `text`.
(define (ffi-c-string-required-bytes [text : String]) : i64
  (ffi-c-bytes-required-bytes (byte_buf.str-as-bytes (& text))))

;: Return true when `text` contains an interior NUL byte.
(define (ffi-c-string-interior-nul? [text : String]) : bool
  (ffi-c-bytes-interior-nul? (byte_buf.str-as-bytes (& text))))

;: Copy exactly `n` bytes from `text` into `dst`.
;:
;: The caller must ensure `n` is at most `(string-length text)` and that `dst`
;: points to writable storage for at least `n` bytes.
(define (ffi-c-string-copy-bytes! [text : String] [dst : (MutPtr u8)] [n : i64]) : unit
  (ffi-c-bytes-copy-bytes! (byte_buf.str-as-bytes (& text)) dst n))

;: Copy `text` to caller-owned mutable storage and append the trailing NUL byte.
;:
;: Compatibility wrapper over `ffi-c-bytes-copy!`.
(define (ffi-c-string-copy!
  [text : String]
  [dst : (MutPtr u8)]
  [capacity : i64]) : FfiCStringCopyResult
  (ffi-c-bytes-copy! (byte_buf.str-as-bytes (& text)) dst capacity))

;: Allocate a NUL-terminated C string copy in the active arena.
;:
;: Compatibility wrapper over `ffi-c-bytes-alloc`.
(define (ffi-c-string-alloc [text : String]) : (Ptr u8)
  (ffi-c-bytes-alloc (byte_buf.str-as-bytes (& text))))

;: Short alias for `ffi-c-string-alloc`.
(define (ffi-cstr [text : String]) : (Ptr u8)
  (ffi-c-string-alloc text))

;: Inline test helper that reads a mutable byte pointer at `index`.
(define (ffi-test-read-u8 [ptr : (MutPtr u8)] [index : i64]) : u8
  (unsafe
    (ptr-read (ptr-offset ptr index))))

;: Inline test helper that reads a const byte pointer at `index`.
(define (ffi-test-read-const-u8 [ptr : (Ptr u8)] [index : i64]) : u8
  (unsafe
    (ptr-read (ptr-offset ptr index))))

;: Inline test helper that writes `value` to a mutable byte pointer.
(define (ffi-test-write-u8! [ptr : (MutPtr u8)] [index : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset ptr index) (cast value : u8))))

;: Inline test helper that forces a test failure.
(define (ffi-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for byte values.
(define (ffi-test-assert-u8-eq [actual : u8] [expected : i64]) : unit
  (if (= (cast actual : i64) expected)
    unit
    (ffi-test-fail)))

;: Inline test assertion for successful C string copies.
(define (ffi-test-assert-copy-ok
  [result : FfiCStringCopyResult]
  [expected : i64]) : unit
  (match result
    [(FfiCStringCopyOk written)
      (if (= written expected)
        unit
        (ffi-test-fail))]
    [_ (ffi-test-fail)]))

;: Inline test assertion for too-small C string copy buffers.
(define (ffi-test-assert-too-small
  [result : FfiCStringCopyResult]
  [expected : i64]) : unit
  (match result
    [(FfiCStringBufferTooSmall required)
      (if (= required expected)
        unit
        (ffi-test-fail))]
    [_ (ffi-test-fail)]))

;: Inline test assertion for rejected interior NUL strings.
(define (ffi-test-assert-interior-nul [result : FfiCStringCopyResult]) : unit
  (match result
    [(FfiCStringInteriorNul) unit]
    [_ (ffi-test-fail)]))

;: Inline test helper that builds a string containing an interior NUL byte.
(define (ffi-test-string-with-nul) : String
  (let
    [data : (Array u8) (make-array u8 3)]
    [dst : (MutPtr u8)
      (unsafe
        (array-data data))]
    (begin
      (ffi-test-write-u8! dst 0 97)
      (ffi-test-write-u8! dst 1 0)
      (ffi-test-write-u8! dst 2 98)
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) 3)))))

(test
  ffi-c-string-api
  (begin
    (if (= (ffi-c-string-required-bytes "") 1)
      unit
      (ffi-test-fail))
    (if (= (ffi-c-string-required-bytes "abc") 4)
      unit
      (ffi-test-fail))
    (let
      [view-text : String "bytes"]
      [view : (& view-text bytes) (byte_buf.str-as-bytes (& view-text))]
      (begin
        (if (= (ffi-c-bytes-required-bytes view) 6)
          unit
          (ffi-test-fail))
        (if (not (ffi-c-bytes-interior-nul? view))
          unit
          (ffi-test-fail))))
    (if (not (ffi-c-string-interior-nul? "abc"))
      unit
      (ffi-test-fail))
    (let
      [empty-storage : (Array u8) (make-array u8 1)]
      [empty-buf : (MutPtr u8)
        (unsafe
          (array-data empty-storage))]
      (begin
        (ffi-test-assert-copy-ok (ffi-c-string-copy! "" empty-buf 1) 1)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 empty-buf 0) 0)))
    (let
      [exact-storage : (Array u8) (make-array u8 4)]
      [exact : (MutPtr u8)
        (unsafe
          (array-data exact-storage))]
      (begin
        (ffi-test-assert-copy-ok (ffi-c-string-copy! "abc" exact 4) 4)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 0) 97)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 1) 98)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 2) 99)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 3) 0)))
    (let
      [bytes-text : String "buf"]
      [bytes-view : (& bytes-text bytes) (byte_buf.str-as-bytes (& bytes-text))]
      [bytes-storage : (Array u8) (make-array u8 4)]
      [bytes-dst : (MutPtr u8)
        (unsafe
          (array-data bytes-storage))]
      (begin
        (ffi-test-assert-copy-ok (ffi-c-bytes-copy! bytes-view bytes-dst 4) 4)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 bytes-dst 0) 98)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 bytes-dst 1) 117)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 bytes-dst 2) 102)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 bytes-dst 3) 0)))
    (let
      [small-storage : (Array u8) (make-array u8 3)]
      [small : (MutPtr u8)
        (unsafe
          (array-data small-storage))]
      (begin
        (ffi-test-write-u8! small 0 77)
        (ffi-test-assert-too-small (ffi-c-string-copy! "abc" small 3) 4)
        (ffi-test-assert-u8-eq (ffi-test-read-u8 small 0) 77)))
    (let
      [with-nul : String (ffi-test-string-with-nul)]
      [nul-storage : (Array u8) (make-array u8 4)]
      [nul-buf : (MutPtr u8)
        (unsafe
          (array-data nul-storage))]
      (begin
        (ffi-test-write-u8! nul-buf 0 88)
        (if (ffi-c-string-interior-nul? with-nul)
          unit
          (ffi-test-fail))
        (ffi-test-assert-interior-nul (ffi-c-string-copy! with-nul nul-buf 4))
        (ffi-test-assert-u8-eq (ffi-test-read-u8 nul-buf 0) 88)))
    (let
      [binary : byte_buf.ByteBuf
        (byte_buf.byte-buf-push
          (byte_buf.byte-buf-push (byte_buf.byte-buf-new) (cast 97 : u8))
          (cast 0 : u8))]
      [binary-view : (& binary bytes) (byte_buf.byte-buf-as-bytes (& binary))]
      [binary-storage : (Array u8) (make-array u8 3)]
      [binary-buf : (MutPtr u8)
        (unsafe
          (array-data binary-storage))]
      (begin
        (ffi-test-write-u8! binary-buf 0 66)
        (if (ffi-c-bytes-interior-nul? binary-view)
          unit
          (ffi-test-fail))
        (ffi-test-assert-interior-nul
          (ffi-c-bytes-copy! binary-view binary-buf 3))
        (ffi-test-assert-u8-eq (ffi-test-read-u8 binary-buf 0) 66)))
    (let
      [empty-ptr : (Ptr u8) (ffi-c-string-alloc "")]
      (begin
        (if (not (ptr-null? empty-ptr))
          unit
          (ffi-test-fail))
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 empty-ptr 0) 0)))
    (let
      [ptr : (Ptr u8) (ffi-c-string-alloc "abc")]
      (begin
        (if (not (ptr-null? ptr))
          unit
          (ffi-test-fail))
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 ptr 0) 97)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 ptr 1) 98)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 ptr 2) 99)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 ptr 3) 0)))
    (let
      [bytes-text : String "pq"]
      [bytes-view : (& bytes-text bytes) (byte_buf.str-as-bytes (& bytes-text))]
      [bytes-ptr : (Ptr u8) (ffi-cbytes bytes-view)]
      (begin
        (if (not (ptr-null? bytes-ptr))
          unit
          (ffi-test-fail))
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 bytes-ptr 0) 112)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 bytes-ptr 1) 113)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 bytes-ptr 2) 0)))
    (let
      [alias-ptr : (Ptr u8) (ffi-cstr "xy")]
      (begin
        (if (not (ptr-null? alias-ptr))
          unit
          (ffi-test-fail))
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 alias-ptr 0) 120)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 alias-ptr 1) 121)
        (ffi-test-assert-u8-eq (ffi-test-read-const-u8 alias-ptr 2) 0)))
    (let
      [with-nul : String (ffi-test-string-with-nul)]
      (if (ptr-null? (ffi-c-string-alloc with-nul))
        unit
        (ffi-test-fail)))))

(export
  (value ffi-c-bytes-required-bytes)
  (value ffi-c-bytes-interior-nul?)
  (value ffi-c-bytes-copy-bytes!)
  (value ffi-c-bytes-copy!)
  (value ffi-c-bytes-alloc)
  (value ffi-cbytes)
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