;# Lightweight append-only byte-buffer core.
;#
;# This module intentionally excludes borrowed `bytes` views, mutation helpers,
;# and full conversion surface from `stdlib.byte_buf`. Compiler-hot modules that
;# only need builder-style byte accumulation can import this small module without
;# pulling the full public owner/view API.
(import stdlib.array)
(import stdlib.string)

;: Append-only owned binary byte buffer. Only the prefix `[0, len)` is live.
(defstruct ByteBufBuilder
  (slots (__tl_dyn-array u8))
  (len i64))

;: Trap when `[start, start + count)` is outside a sequence of `length` bytes.
(define (byte-buf-builder-check-range
  [length : i64]
  [start : i64]
  [count : i64]) : unit
  (cond
    [(< start 0) (string.tl_oob_abort)]
    [(< count 0) (string.tl_oob_abort)]
    [(> start length) (string.tl_oob_abort)]
    [else
      (let
        [remaining : i64 (- length start)]
        (if (> count remaining)
          (string.tl_oob_abort)
          unit))]))

;: Number of live bytes in `buf`.
(define (byte-buf-builder-len [buf : (& buf ByteBufBuilder)]) : i64
  (struct-get buf len))

;: Number of live bytes in `buf`.
(define (byte-buf-builder-length [buf : (& buf ByteBufBuilder)]) : i64
  (byte-buf-builder-len buf))

;: Number of bytes the backing array can hold without growing.
(define (byte-buf-builder-capacity [buf : (& buf ByteBufBuilder)]) : i64
  (array-length (struct-get buf slots)))

;: True when `buf` has no live bytes.
(define (byte-buf-builder-empty? [buf : (& buf ByteBufBuilder)]) : bool
  (<= (byte-buf-builder-len buf) 0))

;: Create an empty buffer with backing capacity `capacity`.
(define (byte-buf-builder-with-capacity [capacity : i64]) : ByteBufBuilder
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ByteBufBuilder (array.make-array u8 cap) 0)))

;: Create an empty buffer with a small default capacity.
(define (byte-buf-builder-new) : ByteBufBuilder
  (byte-buf-builder-with-capacity 16))

;: Copy `count` bytes from `src[src-start..]` into `dst[dst-start..]`.
(define (byte-buf-builder-copy-array-range-into
  [dst : (&mut dst (__tl_dyn-array u8))]
  [dst-start : i64]
  [src : (& src (__tl_dyn-array u8))]
  [src-start : i64]
  [count : i64]) : unit
  (begin
    (byte-buf-builder-check-range (array-length dst) dst-start count)
    (byte-buf-builder-check-range (array-length src) src-start count)
    (let
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (array-set!
              dst
              (+ dst-start index)
              (array-ref src (+ src-start index)))
            (set! index (+ index 1))))
        unit))))

;: Ensure the backing array can hold at least `min-capacity` bytes.
(define (byte-buf-builder-grow-to
  [buf : (&mut buf ByteBufBuilder)]
  [min-capacity : i64]) : unit
  (if (<= min-capacity (array-length (struct-get buf slots)))
    unit
    (let
      [old-capacity : i64 (array-length (struct-get buf slots))]
      [old-len : i64 (struct-get buf len)]
      [doubled : i64
        (if (< old-capacity 1)
          1
          (* old-capacity 2))]
      [new-capacity : i64
        (if (< doubled min-capacity)
          min-capacity
          doubled)]
      [bigger : (__tl_dyn-array u8) (array.make-array u8 new-capacity)]
      (begin
        (byte-buf-builder-copy-array-range-into
          (&mut bigger)
          0
          (& (struct-get buf slots))
          0
          old-len)
        (set! (struct-get buf slots) bigger)))))

;: Grow `buf` to at least twice its current capacity.
(define (byte-buf-builder-grow [buf : (&mut buf ByteBufBuilder)]) : unit
  (byte-buf-builder-grow-to
    buf
    (if (< (array-length (struct-get buf slots)) 1)
      1
      (* (array-length (struct-get buf slots)) 2))))

;: Reserve space for `additional` more bytes without changing `len`.
(define (byte-buf-builder-reserve
  [buf : (&mut buf ByteBufBuilder)]
  [additional : i64]) : unit
  (if (<= additional 0)
    unit
    (byte-buf-builder-grow-to buf (+ (struct-get buf len) additional))))

;: Append one byte to `buf`, growing if needed.
(define (byte-buf-builder-push [buf : (&mut buf ByteBufBuilder)] [value : u8]) : unit
  (begin
    (byte-buf-builder-reserve buf 1)
    (let
      [index : i64 (struct-get buf len)]
      (begin
        (array-set! (struct-get buf slots) index value)
        (set! (struct-get buf len) (+ index 1))))))

;: Append `count` bytes from `src` starting at `start`.
(define (byte-buf-builder-append-array-range
  [buf : (&mut buf ByteBufBuilder)]
  [src : (& src (__tl_dyn-array u8))]
  [start : i64]
  [count : i64]) : unit
  (begin
    (byte-buf-builder-check-range (array-length src) start count)
    (byte-buf-builder-reserve buf count)
    (let
      [old-len : i64 (struct-get buf len)]
      (begin
        (byte-buf-builder-copy-array-range-into
          (&mut (struct-get buf slots))
          old-len
          src
          start
          count)
        (set! (struct-get buf len) (+ old-len count))))))

;: Append every byte from `src`.
(define (byte-buf-builder-append-array
  [buf : (&mut buf ByteBufBuilder)]
  [src : (& src (__tl_dyn-array u8))]) : unit
  (byte-buf-builder-append-array-range buf src 0 (array-length src)))

;: Append `count` bytes from `src` starting at `start`.
(define (byte-buf-builder-append-string-range
  [buf : (&mut buf ByteBufBuilder)]
  [src : String]
  [start : i64]
  [count : i64]) : unit
  (begin
    (byte-buf-builder-check-range (string.string-length src) start count)
    (byte-buf-builder-reserve buf count)
    (let
      [old-len : i64 (struct-get buf len)]
      [src-ptr : (Ptr u8)
        (unsafe
          (string-data (& src)))]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (array-set!
              (struct-get buf slots)
              (+ old-len index)
              (unsafe
                (ptr-read (ptr-offset src-ptr (+ start index)))))
            (set! index (+ index 1))))
        (set! (struct-get buf len) (+ old-len count))))))

;: Append every byte from `src`.
(define (byte-buf-builder-append-string
  [buf : (&mut buf ByteBufBuilder)]
  [src : String]) : unit
  (byte-buf-builder-append-string-range buf src 0 (string.string-length src)))

;: Copy a live byte range into private compatibility storage.
(define (byte-buf-builder-copy-range
  [buf : (& buf ByteBufBuilder)]
  [start : i64]
  [count : i64]) : (__tl_dyn-array u8)
  (begin
    (byte-buf-builder-check-range (byte-buf-builder-len buf) start count)
    (let
      [out : (__tl_dyn-array u8) (array.make-array u8 count)]
      (begin
        (byte-buf-builder-copy-array-range-into
          (&mut out)
          0
          (& (struct-get buf slots))
          start
          count)
        out))))

;: Copy all live bytes into private compatibility storage.
(define (byte-buf-builder-to-array [buf : (& buf ByteBufBuilder)]) : (__tl_dyn-array
    u8)
  (byte-buf-builder-copy-range buf 0 (byte-buf-builder-len buf)))

;: Copy all live bytes into a fresh `String`.
(define (byte-buf-builder-to-string [buf : (& buf ByteBufBuilder)]) : String
  (let
    [n : i64 (byte-buf-builder-len buf)]
    (if (= n 0)
      ""
      (let
        [out : (__tl_dyn-array u8) (byte-buf-builder-to-array buf)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) n))))))

;: Finish into private compatibility storage for compiler/runtime internals.
(define (byte-buf-builder-finish-array [buf : (& buf ByteBufBuilder)]) : (__tl_dyn-array
    u8)
  (byte-buf-builder-to-array buf))

;: Explicit append-builder finish boundary to a fresh String.
(define (byte-buf-builder-finish-string [buf : (& buf ByteBufBuilder)]) : String
  (byte-buf-builder-to-string buf))