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
;# Usage: `(import "stdlib/byte_buf.tl")`
;#
;# ```typelisp
;# (import "stdlib/byte_buf.tl")
;# (define (main) : i64
;#   (let
;#     [buf : ByteBuf
;#       (byte-buf-push (byte-buf-append-string (byte-buf-new) "A") (cast 0 : u8))]
;#     (if (= (byte-buf-len buf) 2)
;#       42
;#       1)))
;# ```
(import "string.tl")

;: Owned mutable binary byte buffer. Only the prefix `[0, len)` is live.
(defstruct ByteBuf
  (slots (Array u8))
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
(define (byte-buf-len [buf : ByteBuf]) : i64
  (struct-get buf len))

;: Number of live bytes in `buf`.
(define (byte-buf-length [buf : ByteBuf]) : i64
  (byte-buf-len buf))

;: Number of bytes the backing array can hold without growing.
(define (byte-buf-capacity [buf : ByteBuf]) : i64
  (array-length (struct-get buf slots)))

;: True when `buf` has no live bytes.
(define (byte-buf-empty? [buf : ByteBuf]) : bool
  (<= (byte-buf-len buf) 0))

;: Create an empty buffer with backing capacity `capacity`. Non-positive
;: capacity is clamped to 1 so growth can always double the backing array.
(define (byte-buf-with-capacity [capacity : i64]) : ByteBuf
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ByteBuf (make-array u8 cap) 0)))

;: Create an empty buffer with a small default capacity.
(define (byte-buf-new) : ByteBuf
  (byte-buf-with-capacity 16))

;: Trap when `[start, start + count)` is outside a sequence of `length` bytes.
(define (byte-buf-check-range [length : i64] [start : i64] [count : i64]) : unit
  (cond
    [(< start 0) (tl_oob_abort)]
    [(< count 0) (tl_oob_abort)]
    [(> start length) (tl_oob_abort)]
    [else
      (let
        [remaining : i64 (- length start)]
        (if (> count remaining)
          (tl_oob_abort)
          unit))]))

;: Number of bytes in an immutable borrowed byte view.
(define (bytes-length [view : (& source bytes)]) : i64
  (__tl_string_length view))

;: Number of bytes in a mutable borrowed byte view.
(define (bytes-mut-length [view : (&mut source bytes)]) : i64
  (__tl_string_length view))

;: Raw immutable data pointer for low-level stdlib internals.
(define (bytes-data [view : (& source bytes)]) : (Ptr u8)
  (unsafe
    (string-data view)))

;: Raw mutable data pointer for low-level stdlib internals.
(define (bytes-mut-data [view : (&mut source bytes)]) : (MutPtr u8)
  (unsafe
    (ptr-cast (string-data view) : (MutPtr u8))))

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
    (byte-buf-check-range (bytes-length view) index 1)
    (unsafe
      (ptr-read (ptr-offset (bytes-data view) index)))))

;: Read byte `index` from a mutable view, trapping when outside the view.
(define (bytes-mut-ref [view : (&mut source bytes)] [index : i64]) : u8
  (begin
    (byte-buf-check-range (bytes-mut-length view) index 1)
    (unsafe
      (ptr-read (ptr-offset (ptr-cast (bytes-mut-data view) : (Ptr u8)) index)))))

;: Overwrite byte `index` inside a mutable fixed-length view.
(define (bytes-set! [view : (&mut source bytes)] [index : i64] [value : u8]) : unit
  (begin
    (byte-buf-check-range (bytes-mut-length view) index 1)
    (unsafe
      (ptr-write! (ptr-offset (bytes-mut-data view) index) value))))

;: Convert a borrowed `str` view into an immutable borrowed byte view.
(define (str-as-bytes [text : (& source str)]) : (& source bytes)
  (unsafe
    (tl_bytes_view_from_str_parts
      (string-data text)
      (__tl_string_length text)
      text)))

;: Borrow a checked immutable sub-slice without copying.
(define (bytes-slice-view [view : (& source bytes)] [start : i64] [count : i64]) : (&
    source
    bytes)
  (begin
    (byte-buf-check-range (bytes-length view) start count)
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
    (byte-buf-check-range (bytes-mut-length view) start count)
    (unsafe
      (tl_bytes_mut_view_from_bytes_parts
        (ptr-offset (bytes-mut-data view) start)
        count
        view))))

;: Copy a checked borrowed byte range into a fresh `(Array u8)`.
(define (bytes-copy-range [view : (& source bytes)] [start : i64] [count : i64]) : (Array
    u8)
  (begin
    (byte-buf-check-range (bytes-length view) start count)
    (let
      [out : (Array u8) (make-array u8 count)]
      [dst : (MutPtr u8)
        (unsafe
          (array-data out))]
      (begin
        (str-copy-bytes-into
          (unsafe
            (ptr-offset (bytes-data view) start))
          dst
          0
          count)
        out))))

;: Copy all bytes in `view` into a fresh `(Array u8)`.
(define (bytes-to-array [view : (& source bytes)]) : (Array u8)
  (bytes-copy-range view 0 (bytes-length view)))

;: Copy all bytes in `view` into a fresh `String`.
(define (bytes-to-string [view : (& source bytes)]) : String
  (let
    [n : i64 (bytes-length view)]
    (if (= n 0)
      ""
      (let
        [out : (Array u8) (bytes-to-array view)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) n))))))

;: Borrow the live range of a `ByteBuf` as immutable bytes.
(define (byte-buf-as-bytes [buf : (& source ByteBuf)]) : (& source bytes)
  (unsafe
    (tl_bytes_view_from_buf_parts
      (ptr-cast (array-data (struct-get buf slots)) : (Ptr u8))
      (struct-get buf len)
      buf)))

;: Borrow the live range of a `ByteBuf` as mutable fixed-length bytes.
(define (byte-buf-as-mut-bytes [buf : (&mut source ByteBuf)]) : (&mut
    source
    bytes)
  (unsafe
    (tl_bytes_mut_view_from_buf_parts
      (array-data (struct-get buf slots))
      (struct-get buf len)
      buf)))

;: Read live byte `index`, returning `fallback` when `index` is outside
;: `[0, len)`.
(define (byte-buf-get [buf : ByteBuf] [index : i64] [fallback : u8]) : u8
  (if (if (>= index 0)
    (< index (byte-buf-len buf))
    false)
    (array-ref (struct-get buf slots) index)
    fallback))

;: Read live byte `index`, trapping when `index` is outside `[0, len)`.
(define (byte-buf-ref [buf : ByteBuf] [index : i64]) : u8
  (begin
    (byte-buf-check-range (byte-buf-len buf) index 1)
    (array-ref (struct-get buf slots) index)))

;: Overwrite live byte `index`, trapping when `index` is outside `[0, len)`.
;: Returns the same buffer value.
(define (byte-buf-set! [buf : ByteBuf] [index : i64] [value : u8]) : ByteBuf
  (begin
    (byte-buf-check-range (byte-buf-len buf) index 1)
    (array-set! (struct-get buf slots) index value)
    buf))

;: Copy `count` bytes from `src[src-start..]` into `dst[dst-start..]`,
;: trapping on invalid source or destination ranges.
(define (byte-buf-copy-array-range-into
  [dst : (Array u8)]
  [dst-start : i64]
  [src : (Array u8)]
  [src-start : i64]
  [count : i64]) : unit
  (begin
    (byte-buf-check-range (array-length dst) dst-start count)
    (byte-buf-check-range (array-length src) src-start count)
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
(define (byte-buf-grow-to [buf : ByteBuf] [min-capacity : i64]) : ByteBuf
  (if (<= min-capacity (byte-buf-capacity buf))
    buf
    (let
      [old-capacity : i64 (byte-buf-capacity buf)]
      [doubled : i64
        (if (< old-capacity 1)
          1
          (* old-capacity 2))]
      [new-capacity : i64
        (if (< doubled min-capacity)
          min-capacity
          doubled)]
      [bigger : (Array u8) (make-array u8 new-capacity)]
      (begin
        (byte-buf-copy-array-range-into
          bigger
          0
          (struct-get buf slots)
          0
          (byte-buf-len buf))
        (set! (struct-get buf slots) bigger)
        buf))))

;: Grow `buf` to at least twice its current capacity.
(define (byte-buf-grow [buf : ByteBuf]) : ByteBuf
  (byte-buf-grow-to
    buf
    (if (< (byte-buf-capacity buf) 1)
      1
      (* (byte-buf-capacity buf) 2))))

;: Reserve space for `additional` more bytes without changing `len`.
(define (byte-buf-reserve [buf : ByteBuf] [additional : i64]) : ByteBuf
  (if (<= additional 0)
    buf
    (byte-buf-grow-to buf (+ (byte-buf-len buf) additional))))

;: Clear all live bytes while retaining the backing capacity for reuse.
(define (byte-buf-clear! [buf : ByteBuf]) : ByteBuf
  (begin
    (set! (struct-get buf len) 0)
    buf))

;: Clear all live bytes while retaining the backing capacity for reuse.
(define (byte-buf-clear [buf : ByteBuf]) : ByteBuf
  (byte-buf-clear! buf))

;: Append one byte to `buf`, growing if needed.
(define (byte-buf-push [buf : ByteBuf] [value : u8]) : ByteBuf
  (let
    [ready : ByteBuf (byte-buf-reserve buf 1)]
    [index : i64 (byte-buf-len ready)]
    (begin
      (array-set! (struct-get ready slots) index value)
      (set! (struct-get ready len) (+ index 1))
      ready)))

;: Append `count` bytes from `src` starting at `start`, trapping on invalid
;: source ranges.
(define (byte-buf-append-array-range
  [buf : ByteBuf]
  [src : (Array u8)]
  [start : i64]
  [count : i64]) : ByteBuf
  (begin
    (byte-buf-check-range (array-length src) start count)
    (let
      [ready : ByteBuf (byte-buf-reserve buf count)]
      [old-len : i64 (byte-buf-len ready)]
      (begin
        (byte-buf-copy-array-range-into
          (struct-get ready slots)
          old-len
          src
          start
          count)
        (set! (struct-get ready len) (+ old-len count))
        ready))))

;: Append every byte from `src`.
(define (byte-buf-append-array [buf : ByteBuf] [src : (Array u8)]) : ByteBuf
  (byte-buf-append-array-range buf src 0 (array-length src)))

;: Append `count` bytes from `src` starting at `start`, trapping on invalid
;: source ranges.
(define (byte-buf-append-string-range
  [buf : ByteBuf]
  [src : String]
  [start : i64]
  [count : i64]) : ByteBuf
  (begin
    (byte-buf-check-range (string-length src) start count)
    (let
      [ready : ByteBuf (byte-buf-reserve buf count)]
      [old-len : i64 (byte-buf-len ready)]
      [src-ptr : (Ptr u8)
        (unsafe
          (string-data (& src)))]
      [index : i64 0]
      (begin
        (while (< index count)
          (begin
            (array-set!
              (struct-get ready slots)
              (+ old-len index)
              (unsafe
                (ptr-read (ptr-offset src-ptr (+ start index)))))
            (set! index (+ index 1))))
        (set! (struct-get ready len) (+ old-len count))
        ready))))

;: Append every byte from `src`.
(define (byte-buf-append-string [buf : ByteBuf] [src : String]) : ByteBuf
  (byte-buf-append-string-range buf src 0 (string-length src)))

;: Append `count` bytes from a borrowed byte view, trapping on invalid ranges.
(define (byte-buf-append-bytes-range
  [buf : ByteBuf]
  [src : (& source bytes)]
  [start : i64]
  [count : i64]) : ByteBuf
  (begin
    (byte-buf-check-range (bytes-length src) start count)
    (let
      [ready : ByteBuf (byte-buf-reserve buf count)]
      [old-len : i64 (byte-buf-len ready)]
      [dst : (MutPtr u8)
        (unsafe
          (array-data (struct-get ready slots)))]
      (begin
        (str-copy-bytes-into
          (unsafe
            (ptr-offset (bytes-data src) start))
          dst
          old-len
          count)
        (set! (struct-get ready len) (+ old-len count))
        ready))))

;: Append every byte from a borrowed byte view.
(define (byte-buf-append-bytes [buf : ByteBuf] [src : (& source bytes)]) : ByteBuf
  (byte-buf-append-bytes-range buf src 0 (bytes-length src)))

;: Copy `count` bytes from `src` starting at `start` into a new buffer.
(define (byte-buf-from-array-range
  [src : (Array u8)]
  [start : i64]
  [count : i64]) : ByteBuf
  (byte-buf-append-array-range (byte-buf-with-capacity count) src start count))

;: Copy every byte from `src` into a new buffer.
(define (byte-buf-from-array [src : (Array u8)]) : ByteBuf
  (byte-buf-from-array-range src 0 (array-length src)))

;: Copy `count` bytes from `src` starting at `start` into a new buffer.
(define (byte-buf-from-string-range [src : String] [start : i64] [count : i64]) : ByteBuf
  (byte-buf-append-string-range (byte-buf-with-capacity count) src start count))

;: Copy every byte from `src` into a new buffer.
(define (byte-buf-from-string [src : String]) : ByteBuf
  (byte-buf-from-string-range src 0 (string-length src)))

;: Copy `count` borrowed bytes into a new buffer.
(define (byte-buf-from-bytes-range
  [src : (& source bytes)]
  [start : i64]
  [count : i64]) : ByteBuf
  (byte-buf-append-bytes-range (byte-buf-with-capacity count) src start count))

;: Copy every borrowed byte into a new buffer.
(define (byte-buf-from-bytes [src : (& source bytes)]) : ByteBuf
  (byte-buf-from-bytes-range src 0 (bytes-length src)))

;: Copy a live byte range into a fresh `(Array u8)` snapshot.
(define (byte-buf-copy-range [buf : ByteBuf] [start : i64] [count : i64]) : (Array
    u8)
  (begin
    (byte-buf-check-range (byte-buf-len buf) start count)
    (let
      [out : (Array u8) (make-array u8 count)]
      (begin
        (byte-buf-copy-array-range-into
          out
          0
          (struct-get buf slots)
          start
          count)
        out))))

;: Copy all live bytes into a fresh `(Array u8)` snapshot.
(define (byte-buf-to-array [buf : ByteBuf]) : (Array u8)
  (byte-buf-copy-range buf 0 (byte-buf-len buf)))

;: Copy all live bytes into a fresh `String`.
(define (byte-buf-to-string [buf : ByteBuf]) : String
  (let
    [n : i64 (byte-buf-len buf)]
    (if (= n 0)
      ""
      (let
        [out : (Array u8) (byte-buf-to-array buf)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) n))))))

;; Inline coverage for the owned ByteBuf core (#3061).
(cfg test (import "test.tl"))

(cfg
  test
  (define (byte-buf-test-u8 [value : i64]) : u8
    (cast value : u8)))

(cfg
  test
  (define (byte-buf-test-assert-u8-eq
    [actual : u8]
    [expected : i64]
    [message : String]) : unit
    (assert-i64-eq (cast actual : i64) expected message)))

(cfg
  test
  (define (byte-buf-test-string-byte [text : String] [index : i64]) : u8
    (unsafe
      (ptr-read (ptr-offset (string-data (& text)) index)))))

(cfg
  test
  (define (byte-buf-test-main) : i64
    (begin
      (let
        [empty : ByteBuf (byte-buf-with-capacity 2)]
        (begin
          (assert-i64-eq (byte-buf-len empty) 0 "empty len")
          (assert-i64-eq (byte-buf-length empty) 0 "empty length alias")
          (assert-i64-eq (byte-buf-capacity empty) 2 "empty capacity")
          (assert-true (byte-buf-empty? empty) "empty predicate")
          (byte-buf-test-assert-u8-eq
            (byte-buf-get empty 0 (byte-buf-test-u8 77))
            77
            "empty get fallback")))
      (assert-i64-eq
        (byte-buf-capacity (byte-buf-with-capacity 0))
        1
        "zero capacity clamps")
      (let
        [buf : ByteBuf (byte-buf-with-capacity 2)]
        (begin
          (set! buf (byte-buf-push buf (byte-buf-test-u8 10)))
          (set! buf (byte-buf-push buf (byte-buf-test-u8 20)))
          (assert-i64-eq (byte-buf-len buf) 2 "push len")
          (assert-i64-eq (byte-buf-capacity buf) 2 "push no growth")
          (byte-buf-test-assert-u8-eq (byte-buf-ref buf 0) 10 "ref first")
          (byte-buf-test-assert-u8-eq (byte-buf-ref buf 1) 20 "ref second")
          (set! buf (byte-buf-push buf (byte-buf-test-u8 30)))
          (assert-i64-eq (byte-buf-len buf) 3 "growth push len")
          (assert-i64-eq (byte-buf-capacity buf) 4 "growth capacity")
          (byte-buf-test-assert-u8-eq (byte-buf-ref buf 2) 30 "growth value")
          (set! buf (byte-buf-set! buf 1 (byte-buf-test-u8 99)))
          (byte-buf-test-assert-u8-eq (byte-buf-ref buf 1) 99 "set value")
          (set! buf (byte-buf-reserve buf 5))
          (assert-i64-eq (byte-buf-len buf) 3 "reserve keeps len")
          (assert-true (>= (byte-buf-capacity buf) 8) "reserve grows enough")
          (set! buf (byte-buf-clear! buf))
          (assert-true (byte-buf-empty? buf) "clear empties")
          (set! buf (byte-buf-push buf (byte-buf-test-u8 7)))
          (assert-i64-eq (byte-buf-len buf) 1 "reuse after clear")
          (byte-buf-test-assert-u8-eq (byte-buf-ref buf 0) 7 "reuse value")))
      (let
        [src : (Array u8) (make-array u8 4)]
        (begin
          (array-set! src 0 (byte-buf-test-u8 1))
          (array-set! src 1 (byte-buf-test-u8 0))
          (array-set! src 2 (byte-buf-test-u8 200))
          (array-set! src 3 (byte-buf-test-u8 255))
          (let
            [buf : ByteBuf (byte-buf-from-array src)]
            (begin
              (assert-i64-eq (byte-buf-len buf) 4 "from-array len")
              (array-set! src 2 (byte-buf-test-u8 2))
              (byte-buf-test-assert-u8-eq
                (byte-buf-ref buf 2)
                200
                "from-array copies")
              (let
                [slice : (Array u8) (byte-buf-copy-range buf 1 2)]
                (begin
                  (assert-i64-eq (array-length slice) 2 "copy-range len")
                  (byte-buf-test-assert-u8-eq
                    (array-ref slice 0)
                    0
                    "copy-range first")
                  (byte-buf-test-assert-u8-eq
                    (array-ref slice 1)
                    200
                    "copy-range second")))
              (let
                [snap : (Array u8) (byte-buf-to-array buf)]
                (begin
                  (assert-i64-eq (array-length snap) 4 "to-array len")
                  (byte-buf-test-assert-u8-eq
                    (array-ref snap 3)
                    255
                    "to-array last")
                  (array-set! snap 3 (byte-buf-test-u8 3))
                  (byte-buf-test-assert-u8-eq
                    (byte-buf-ref buf 3)
                    255
                    "to-array copies")))))))
      (let
        [src : (Array u8) (make-array u8 3)]
        (begin
          (array-set! src 0 (byte-buf-test-u8 65))
          (array-set! src 1 (byte-buf-test-u8 66))
          (array-set! src 2 (byte-buf-test-u8 67))
          (let
            [buf : ByteBuf
              (byte-buf-append-array-range
                (byte-buf-append-string (byte-buf-new) "xy")
                src
                1
                2)]
            (begin
              (let
                [actual : String (byte-buf-to-string buf)]
                [expected : String "xyBC"]
                (assert-string-eq
                  (& actual)
                  (& expected)
                  "append string and array range"))
              (assert-i64-eq (byte-buf-len buf) 4 "append mixed len")))))
      (let
        [buf : ByteBuf (byte-buf-from-string "hello")]
        (begin
          (assert-i64-eq (byte-buf-len buf) 5 "from-string len")
          (byte-buf-test-assert-u8-eq (byte-buf-ref buf 1) 101 "from-string e")
          (let
            [out : String (byte-buf-to-string buf)]
            [expected : String "hello"]
            (assert-string-eq (& out) (& expected) "to-string text"))))
      (let
        [text : String "abcdef"]
        [view : (& text bytes) (str-as-bytes (& text))]
        [middle : (& text bytes) (bytes-slice-view view 2 3)]
        (begin
          (assert-i64-eq (bytes-length view) 6 "bytes view len")
          (byte-buf-test-assert-u8-eq (bytes-ref view 1) 98 "bytes ref")
          (byte-buf-test-assert-u8-eq
            (bytes-get view 99 (byte-buf-test-u8 77))
            77
            "bytes get fallback")
          (assert-i64-eq (bytes-length middle) 3 "bytes sub-slice len")
          (byte-buf-test-assert-u8-eq
            (bytes-ref middle 0)
            99
            "bytes sub-slice first")
          (let
            [arr : (Array u8) (bytes-to-array middle)]
            (begin
              (assert-i64-eq (array-length arr) 3 "bytes to-array len")
              (byte-buf-test-assert-u8-eq
                (array-ref arr 2)
                101
                "bytes to-array last")))
          (let
            [copy : String (bytes-to-string middle)]
            [expected : String "cde"]
            (assert-string-eq (& copy) (& expected) "bytes to-string"))
          (let
            [buf : ByteBuf (byte-buf-from-bytes middle)]
            [actual : String (byte-buf-to-string buf)]
            [expected : String "cde"]
            (assert-string-eq (& actual) (& expected) "byte-buf from bytes"))
          (let
            [buf : ByteBuf
              (byte-buf-append-bytes (byte-buf-from-string "x") middle)]
            [actual : String (byte-buf-to-string buf)]
            [expected : String "xcde"]
            (assert-string-eq (& actual) (& expected) "byte-buf append bytes"))))
      (let
        [buf : ByteBuf (byte-buf-from-string "view")]
        [view : (& buf bytes) (byte-buf-as-bytes (& buf))]
        (begin
          (assert-i64-eq (bytes-length view) 4 "byte-buf view len")
          (byte-buf-test-assert-u8-eq
            (bytes-ref view 2)
            101
            "byte-buf view reads live data")))
      (let
        [buf : ByteBuf (byte-buf-from-string "abc")]
        (begin
          (let
            [view : (&mut buf bytes) (byte-buf-as-mut-bytes (&mut buf))]
            (begin
              (assert-i64-eq (bytes-mut-length view) 3 "mutable bytes len")
              (byte-buf-test-assert-u8-eq
                (bytes-mut-ref view 0)
                97
                "mutable bytes read")
              (bytes-set! view 1 (byte-buf-test-u8 90))
              (let
                [tail : (&mut buf bytes) (bytes-mut-slice-view view 2 1)]
                (bytes-set! tail 0 (byte-buf-test-u8 81)))))
          (byte-buf-test-assert-u8-eq
            (byte-buf-ref buf 1)
            90
            "mutable bytes writes through")
          (byte-buf-test-assert-u8-eq
            (byte-buf-ref buf 2)
            81
            "mutable bytes sub-slice writes through")))
      (let
        [binary : ByteBuf
          (byte-buf-push
            (byte-buf-push
              (byte-buf-push (byte-buf-new) (byte-buf-test-u8 0))
              (byte-buf-test-u8 128))
            (byte-buf-test-u8 255))]
        [text : String (byte-buf-to-string binary)]
        (begin
          (assert-i64-eq (string-length text) 3 "binary string length")
          (byte-buf-test-assert-u8-eq
            (byte-buf-test-string-byte text 0)
            0
            "binary nul byte")
          (byte-buf-test-assert-u8-eq
            (byte-buf-test-string-byte text 1)
            128
            "binary high byte")
          (byte-buf-test-assert-u8-eq
            (byte-buf-test-string-byte text 2)
            255
            "binary max byte")))
      42)))

(cfg
  test
  (test
    byte-buf-api
    (assert-i64-eq (byte-buf-test-main) 42 "byte-buf-api fixture result")))