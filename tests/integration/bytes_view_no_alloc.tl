;; Borrowed `bytes` views are two-word values, a data pointer and a length
;; (#8089), so taking one never allocates. Each window takes 1000 views of one
;; kind and measures `profile.alloc-total` around them; `main` yields 42 only
;; if every window is exactly zero bytes and every view reads the right bytes.
;; With an argument it takes one out-of-range view, which must trap before any
;; pointer is formed.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.string)

(define views : i64
  1000)

(define (text-window [text : (& text str)]) : bool
  (let
    [sum : i64 0]
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< index views)
        (let
          [view : (& text bytes) (byte_buf.str-as-bytes text)]
          (begin
            (set!
              sum
              (+ sum (cast (byte_buf.bytes-ref view (% index 5)) : i64)))
            (set! index (+ index 1)))))
      (and (= (profile.alloc-total) before) (= sum 106400)))))

(define (buf-window [buf : (& buf byte_buf.ByteBuf)]) : bool
  (let
    [sum : i64 0]
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< index views)
        (let
          [view : (& buf bytes) (byte_buf.as-bytes buf)]
          (begin
            (set! sum (+ sum (byte_buf.bytes-length view)))
            (set! index (+ index 1)))))
      (and (= (profile.alloc-total) before) (= sum 5000)))))

;; A view of a view of a view, down to the empty view at the end.
(define (subview-window [view : (& source bytes)]) : bool
  (let
    [sum : i64 0]
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< index views)
        (let
          [inner : (& source bytes) (byte_buf.bytes-slice-view view 1 3)]
          [last : (& source bytes) (byte_buf.bytes-slice-view inner 2 1)]
          [empty : (& source bytes) (byte_buf.bytes-slice-view last 1 0)]
          (begin
            (set!
              sum
              (+
                sum
                (+
                  (cast (byte_buf.bytes-ref last 0) : i64)
                  (byte_buf.bytes-length empty))))
            (set! index (+ index 1)))))
      (and (= (profile.alloc-total) before) (= sum 108000)))))

;; Mutable views of a buffer, and a mutable view of that view, write through
;; to the buffer.
(define (mut-window [buf : (&mut buf byte_buf.ByteBuf)]) : bool
  (let
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< index views)
        (let
          [whole : (&mut buf bytes) (byte_buf.as-mut-bytes buf)]
          [tail : (&mut buf bytes) (byte_buf.bytes-mut-slice-view whole 3 2)]
          (begin
            (byte_buf.bytes-set! tail 1 (cast (% index 256) : u8))
            (set! index (+ index 1)))))
      (= (profile.alloc-total) before))))

;; The private builtin the stdlib views are made of, over every source kind.
(define (builtin-window
  [text : (& text str)]
  [buf : (&mut buf byte_buf.ByteBuf)]) : bool
  (let
    [fixed : (Array u8 4)
      (array (cast 1 : u8) (cast 2 : u8) (cast 3 : u8) (cast 4 : u8))]
    [sum : i64 0]
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< index views)
        (let
          [from-text : (& text bytes) (__tl_bytes-view text 0 5)]
          [from-view : (& text bytes) (__tl_bytes-view from-text 4 1)]
          [from-fixed : (& fixed bytes) (__tl_bytes-view fixed 3 1)]
          [whole : (& fixed bytes) (__tl_bytes-view fixed 0 4)]
          (begin
            (set!
              sum
              (+
                sum
                (+
                  (cast (byte_buf.bytes-ref from-view 0) : i64)
                  (+
                    (cast (byte_buf.bytes-ref from-fixed 0) : i64)
                    (byte_buf.bytes-length whole)))))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (< index views)
        (let
          [slots : (&mut buf bytes) (__tl_bytes-mut-view buf.slots 0 buf.len)]
          [first : (&mut buf bytes) (__tl_bytes-mut-view slots 0 1)]
          (begin
            (byte_buf.bytes-set! first 0 (cast 65 : u8))
            (set! index (+ index 1)))))
      (and (= (profile.alloc-total) before) (= sum 119000)))))

;; One out-of-range view, selected by `which`.
(define (trap [text : (& text str)] [which : i64]) : i64
  (let
    [huge : i64 9223372036854775807]
    [view : (& text bytes)
      (cond
        [(= which 1) (__tl_bytes-view text -1 1)]
        [(= which 2) (__tl_bytes-view text 0 -1)]
        [(= which 3) (__tl_bytes-view text 1 huge)]
        [(= which 4) (__tl_bytes-view text 5 1)]
        [else (byte_buf.bytes-slice-view (byte_buf.str-as-bytes text) 6 0)])]
    (byte_buf.bytes-length view)))

(define (main) : i64
  (let
    [text : String "hello"]
    [buf : byte_buf.ByteBuf (byte_buf.append-string (byte_buf.new) "bytes")]
    (if (> (io.arg-count) 1)
      (trap (& text) (string.>int (io.arg 1)))
      (if (and
        (text-window (& text))
        (buf-window (& buf))
        (subview-window (byte_buf.str-as-bytes (& text)))
        (mut-window (&mut buf))
        (= (byte_buf.bytes-ref (byte_buf.as-bytes (& buf)) 4) (cast 231 : u8))
        (builtin-window (& text) (&mut buf))
        (= (byte_buf.bytes-ref (byte_buf.as-bytes (& buf)) 0) (cast 65 : u8))
        (= (byte_buf.len (& buf)) 5))
        42
        1))))