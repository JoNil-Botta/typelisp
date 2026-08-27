;# Owned mutable byte buffer utilities.
;#
;# `ByteBuf` stores binary bytes in an active-arena backing array plus a live
;# byte length. Mutating operations thread the buffer value forward: push,
;# append, reserve, and growth may replace the backing array, while set and
;# clear mutate the current backing storage.
;#
;# Byte buffers are binary containers, not text. String conversion helpers are
;# explicit copy boundaries and preserve NUL bytes and bytes outside ASCII.
;# Borrowed `bytes` views expose fixed-length live ranges without copying; view
;# constructors are tied to an owner witness so the borrow checker can keep the
;# source alive.
;#
;# Compiler-hot append-only builders that do not need borrowed `bytes` views can
;# import `stdlib.byte_buf_core` directly.
;#
;# Usage: `(import stdlib.byte_buf)`
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (let
;#     [buf : byte_buf.ByteBuf
;#       (byte_buf.push
;#         (byte_buf.append-string (byte_buf.new) "A")
;#         (cast 0 : u8))]
;#     (if (= (byte_buf.len buf) 2)
;#       42
;#       1)))
;# ```
(import stdlib.string)

;: Owned mutable binary byte buffer. Only the prefix `[0, len)` is live.
(defstruct ByteBuf
  (slots (__tl_dyn-array u8))
  (len i64))

(unsafe
  (extern (tl_bytes_view_from_str_parts
    [data : (Ptr u8)]
    [len : i64]
    [owner : (& source str)]) : (& source bytes)))

(unsafe
  (extern (tl_bytes_view_from_buf_parts
    [data : (Ptr u8)]
    [len : i64]
    [owner : (& source ByteBuf)]) : (& source bytes)))

(unsafe
  (extern (tl_bytes_mut_view_from_buf_parts
    [data : (MutPtr u8)]
    [len : i64]
    [owner : (&mut source ByteBuf)]) : (&mut source bytes)))

(unsafe
  (extern (tl_bytes_view_from_bytes_parts
    [data : (Ptr u8)]
    [len : i64]
    [owner : (& source bytes)]) : (& source bytes)))

(unsafe
  (extern (tl_bytes_mut_view_from_bytes_parts
    [data : (MutPtr u8)]
    [len : i64]
    [owner : (&mut source bytes)]) : (&mut source bytes)))

;: Number of live bytes in `buf`.
(define (len [buf : ByteBuf]) : i64
  buf.len)

;: Number of live bytes in `buf`.
(define (length [buf : ByteBuf]) : i64
  (len buf))

;: Number of bytes the backing array can hold without growing.
(define (capacity [buf : ByteBuf]) : i64
  (array-length buf.slots))

;: True when `buf` has no live bytes.
(define (empty? [buf : ByteBuf]) : bool
  (<= (len buf) 0))

;: Create an empty buffer with backing capacity `capacity`. Non-positive
;: capacity is clamped to 1 so growth can always double the backing array.
(define (with-capacity [capacity : i64]) : ByteBuf
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ByteBuf (__tl_make-array u8 cap) 0)))

;: Create an empty buffer with a small default capacity.
(define (new) : ByteBuf
  (with-capacity 16))

;: Take ownership of a dynamic byte array with every slot marked live.
(define (from-array [slots : (__tl_dyn-array u8)]) : ByteBuf
  (let
    [n : i64 (array-length slots)]
    (ByteBuf slots n)))

;: Take ownership of a dynamic byte array with only its prefix marked live.
(define (from-array-prefix [slots : (__tl_dyn-array u8)] [count : i64]) : ByteBuf
  (begin
    (check-range (array-length slots) 0 count)
    (ByteBuf slots count)))

;: Trap when `[start, start + count)` is outside a sequence of `length` bytes.
(define (check-range [length : i64] [start : i64] [count : i64]) : unit
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

;: Number of bytes in an immutable borrowed byte view.
(define (bytes-length [view : (& source bytes)]) : i64
  (string-length view))

;: Number of bytes in a mutable borrowed byte view.
(define (bytes-mut-length [view : (&mut source bytes)]) : i64
  (string-length view))

;: Raw immutable data pointer for low-level stdlib internals.
(unsafe
  (define (bytes-data [view : (& source bytes)]) : (Ptr u8)
    (unsafe
      (string-data view))))

;: Raw mutable data pointer for low-level stdlib internals.
(unsafe
  (define (bytes-mut-data [view : (&mut source bytes)]) : (MutPtr u8)
    (unsafe
      (ptr-cast (string-data view) : (MutPtr u8)))))

;: Read byte `index`, returning `fallback` when `index` is outside the view.
(define (bytes-get [view : (& source bytes)] [index : i64] [fallback : u8]) : u8
  (if (if (>= index 0)
    (< index (bytes-length view))
    false)
    (unsafe
      (ptr-read (ptr-offset (bytes-data view) index)))
    fallback))

;: Read byte `index` from a mutable view, returning `fallback` when out of range.
(define (bytes-mut-get
  [view : (&mut source bytes)]
  [index : i64]
  [fallback : u8]) : u8
  (if (if (>= index 0)
    (< index (bytes-mut-length view))
    false)
    (unsafe
      (ptr-read (ptr-offset (ptr-cast (bytes-mut-data view) : (Ptr u8)) index)))
    fallback))

;: Read byte `index`, trapping when `index` is outside the view.
(define (bytes-ref [view : (& source bytes)] [index : i64]) : u8
  (begin
    (check-range (bytes-length view) index 1)
    (unsafe
      (ptr-read (ptr-offset (bytes-data view) index)))))

;: Read byte `index` from a mutable view, trapping when outside the view.
(define (bytes-mut-ref [view : (&mut source bytes)] [index : i64]) : u8
  (begin
    (check-range (bytes-mut-length view) index 1)
    (unsafe
      (ptr-read (ptr-offset (ptr-cast (bytes-mut-data view) : (Ptr u8)) index)))))

;: Overwrite byte `index` inside a mutable fixed-length view.
(define (bytes-set! [view : (&mut source bytes)] [index : i64] [value : u8]) : unit
  (begin
    (check-range (bytes-mut-length view) index 1)
    (unsafe
      (ptr-write! (ptr-offset (bytes-mut-data view) index) value))))

;: Convert a borrowed `str` view into an immutable borrowed byte view.
(define (str-as-bytes [text : (& source str)]) : (& source bytes)
  (unsafe
    (tl_bytes_view_from_str_parts (string-data text) (string-length text) text)))

;: Borrow a checked immutable sub-slice without copying.
(define (bytes-slice-view [view : (& source bytes)] [start : i64] [count : i64]) : (&
    source
    bytes)
  (begin
    (check-range (bytes-length view) start count)
    (unsafe
      (tl_bytes_view_from_bytes_parts
        (ptr-offset (bytes-data view) start)
        count
        view))))

;: Borrow a checked mutable fixed-length sub-slice without copying.
(define (bytes-mut-slice-view
  [view : (&mut source bytes)]
  [start : i64]
  [count : i64]) : (&mut source bytes)
  (begin
    (check-range (bytes-mut-length view) start count)
    (unsafe
      (tl_bytes_mut_view_from_bytes_parts
        (ptr-offset (bytes-mut-data view) start)
        count
        view))))

;: Copy all bytes in `view` into a fresh `String`.
(define (bytes-to-string [view : (& source bytes)]) : String
  (let
    [n : i64 (bytes-length view)]
    (if (= n 0)
      ""
      (let
        [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
        [dst : (MutPtr u8)
          (unsafe
            (__tl_array-data out))]
        (begin
          (string.str-copy-bytes-into
            (unsafe
              (bytes-data view))
            dst
            0
            n)
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) n)))))))

;: Borrow the live range of a `ByteBuf` as immutable bytes.
(define (as-bytes [buf : (& source ByteBuf)]) : (& source bytes)
  (unsafe
    (tl_bytes_view_from_buf_parts
      (ptr-cast (__tl_array-data buf.slots) : (Ptr u8))
      buf.len
      buf)))

;: Borrow the live range of a `ByteBuf` as mutable fixed-length bytes.
(define (as-mut-bytes [buf : (&mut source ByteBuf)]) : (&mut source bytes)
  (unsafe
    (tl_bytes_mut_view_from_buf_parts (__tl_array-data buf.slots) buf.len buf)))

;: Read live byte `index`, returning `fallback` when `index` is outside
;: `[0, len)`.
(define (get [buf : ByteBuf] [index : i64] [fallback : u8]) : u8
  (if (if (>= index 0)
    (< index (len buf))
    false)
    (array-ref buf.slots index)
    fallback))

;: Read live byte `index`, trapping when `index` is outside `[0, len)`.
(define (ref [buf : ByteBuf] [index : i64]) : u8
  (begin
    (check-range (len buf) index 1)
    (array-ref buf.slots index)))

;: Overwrite live byte `index`, trapping when `index` is outside `[0, len)`.
;: Returns the same buffer value.
(define (set! [buf : ByteBuf] [index : i64] [value : u8]) : ByteBuf
  (begin
    (check-range (len buf) index 1)
    (set! (array-ref buf.slots index) value)
    buf))

;: Copy `count` bytes from `src[src-start..]` into `dst[dst-start..]`,
;: trapping on invalid source or destination ranges.
(define (byte-buf-copy-slots-range-into
  [dst : (__tl_dyn-array u8)]
  [dst-start : i64]
  [src : (__tl_dyn-array u8)]
  [src-start : i64]
  [count : i64]) : unit
  (begin
    (check-range (array-length dst) dst-start count)
    (check-range (array-length src) src-start count)
    (let
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (set!
              (array-ref dst (+ dst-start index))
              (array-ref src (+ src-start index)))
            (set! index (+ index 1))))
        unit))))

;: Ensure the backing array can hold at least `min-capacity` bytes.
(define (grow-to [buf : ByteBuf] [min-capacity : i64]) : ByteBuf
  (if (<= min-capacity (capacity buf))
    buf
    (let
      [old-capacity : i64 (capacity buf)]
      [doubled : i64
        (if (< old-capacity 1)
          1
          (* old-capacity 2))]
      [new-capacity : i64
        (if (< doubled min-capacity)
          min-capacity
          doubled)]
      [bigger : (__tl_dyn-array u8) (__tl_make-array u8 new-capacity)]
      (begin
        (byte-buf-copy-slots-range-into bigger 0 buf.slots 0 (len buf))
        (ByteBuf bigger (len buf))))))

;: Grow `buf` to at least twice its current capacity.
(define (grow [buf : ByteBuf]) : ByteBuf
  (grow-to
    buf
    (if (< (capacity buf) 1)
      1
      (* (capacity buf) 2))))

;: Reserve space for `additional` more bytes without changing `len`.
(define (reserve [buf : ByteBuf] [additional : i64]) : ByteBuf
  (if (<= additional 0)
    buf
    (grow-to buf (+ (len buf) additional))))

;: Clear all live bytes while retaining the backing capacity for reuse.
(define (clear! [buf : ByteBuf]) : ByteBuf
  (ByteBuf buf.slots 0))

;: Clear all live bytes while retaining the backing capacity for reuse.
(define (clear [buf : ByteBuf]) : ByteBuf
  (clear! buf))

;: Append one byte to `buf`, growing if needed.
(define (push [buf : ByteBuf] [value : u8]) : ByteBuf
  (let
    [ready : ByteBuf (reserve buf 1)]
    [index : i64 (len ready)]
    (begin
      (set! (array-ref ready.slots index) value)
      (set! ready.len (+ index 1))
      ready)))

;: Append `count` bytes from `src` starting at `start`, trapping on invalid
;: source ranges.
(define (append-string-range
  [buf : ByteBuf]
  [src : String]
  [start : i64]
  [count : i64]) : ByteBuf
  (begin
    (check-range (string-length src) start count)
    (let
      [ready : ByteBuf (reserve buf count)]
      [old-len : i64 (len ready)]
      [src-ptr : (Ptr u8)
        (unsafe
          (string-data (& src)))]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (set!
              (array-ref ready.slots (+ old-len index))
              (unsafe
                (ptr-read (ptr-offset src-ptr (+ start index)))))
            (set! index (+ index 1))))
        (set! ready.len (+ old-len count))
        ready))))

;: Append every byte from `src`.
(define (append-string [buf : ByteBuf] [src : String]) : ByteBuf
  (append-string-range buf src 0 (string-length src)))

;: Append `count` bytes from a borrowed byte view, trapping on invalid ranges.
(define (append-bytes-range
  [buf : ByteBuf]
  [src : (& source bytes)]
  [start : i64]
  [count : i64]) : ByteBuf
  (begin
    (check-range (bytes-length src) start count)
    (let
      [ready : ByteBuf (reserve buf count)]
      [old-len : i64 (len ready)]
      [dst : (MutPtr u8)
        (unsafe
          (__tl_array-data ready.slots))]
      (begin
        (string.str-copy-bytes-into
          (unsafe
            (ptr-offset (bytes-data src) start))
          dst
          old-len
          count)
        (set! ready.len (+ old-len count))
        ready))))

;: Append every byte from a borrowed byte view.
(define (append-bytes [buf : ByteBuf] [src : (& source bytes)]) : ByteBuf
  (append-bytes-range buf src 0 (bytes-length src)))

;: Raw Formatter destination adapter for a caller-owned ByteBuf cell.
;:
;: `context` points at the live writer cell created by `format.write!`; the
;: callback is synchronous and the macro moves the updated buffer back into
;: the caller's place before returning. Zero is the only success status.
(define (format-writer-cell [buf : ByteBuf]) : (Array ByteBuf 1)
  (array buf))

(define (format-write-raw [context : i64] [data : (Ptr u8)] [count : i64]) : i64
  (if (< count 0)
    22
    (let
      [slot : (MutPtr ByteBuf)
        (unsafe
          (int->ptr (cast context : u64) : (MutPtr ByteBuf)))]
      [buf : ByteBuf
        (unsafe
          (ptr-read (ptr-cast slot : (Ptr ByteBuf))))]
      [ready : ByteBuf (reserve buf count)]
      [start : i64 (len ready)]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (set!
              (array-ref ready.slots (+ start index))
              (unsafe
                (ptr-read (ptr-offset data index))))
            (set! index (+ index 1))))
        (set! ready.len (+ start count))
        (unsafe
          (ptr-write! slot ready))
        0))))

;: Copy `count` bytes from `src` starting at `start` into a new buffer.
(define (from-string-range [src : String] [start : i64] [count : i64]) : ByteBuf
  (append-string-range (with-capacity count) src start count))

;: Copy every byte from `src` into a new buffer.
(define (from-string [src : String]) : ByteBuf
  (from-string-range src 0 (string-length src)))

;: Copy `count` borrowed bytes into a new buffer.
(define (from-bytes-range [src : (& source bytes)] [start : i64] [count : i64]) : ByteBuf
  (append-bytes-range (with-capacity count) src start count))

;: Copy every borrowed byte into a new buffer.
(define (from-bytes [src : (& source bytes)]) : ByteBuf
  (from-bytes-range src 0 (bytes-length src)))

;: Copy all live bytes into a fresh dynamic array.
(define (to-array [buf : ByteBuf]) : (__tl_dyn-array u8)
  (let
    [n : i64 (len buf)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    (begin
      (byte-buf-copy-slots-range-into out 0 buf.slots 0 n)
      out)))

;: Copy all live bytes into a fresh `String`.
(define (to-string [buf : ByteBuf]) : String
  (let
    [n : i64 (len buf)]
    (if (= n 0)
      ""
      (let
        [out : (__tl_dyn-array u8) (to-array buf)]
        (unsafe
          (string-from-bytes (ptr-cast (__tl_array-data out) : (Ptr u8)) n))))))