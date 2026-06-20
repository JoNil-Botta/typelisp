;# Arena-aware text buffer utilities for incremental string construction.
;#
;# `TextBuf` is a byte-oriented text builder backed by active-arena chunk
;# nodes. Appending records owned chunks without concatenating the accumulated
;# prefix on every step; mutable `text-buf-append!` helpers update a builder
;# in place, and `text-buf-render` is the single operation that materializes an
;# owned `String` in the active arena.
;#
;# The borrowed-chunk companion surface lives in
;# `stdlib/text_buf_borrowed.tl` while `TextBuf` keeps the owned chunk API. Both
;# modules share the owned ordered-chunk render helper so the final materialize
;# path stays in one place.
;#
;# Usage: `(import stdlib.text_buf)`
;#
;# ```typelisp
;# (import stdlib.text_buf)
;# (import stdlib.string)
;# (define (main) : i64
;#   (let ([buf : text_buf.TextBuf
;#     (text_buf.text-buf-append-int
;#       (text_buf.text-buf-append (text_buf.text-buf-empty) "n=")
;#       7)])
;#     (if (string.string-eq (text_buf.text-buf-render buf) "n=7") 42 1)))
;# ```
;#
;# The buffer and rendered strings allocate in the active arena: the default
;# program-lifetime arena outside `(with-arena ...)`, or the scoped arena inside
;# one.
(module stdlib.text_buf)

(import stdlib.io)
(import stdlib.string as string_mod)

;: Reversed chunk list. Each cons node is allocated in the active arena.
(defenum TextBufChunkList
  (TextBufChunkNil)
  (TextBufChunkCons String (Box TextBufChunkList)))

;: Text buffer value with reversed chunks and cached byte length.
(defstruct TextBuf
  (chunks TextBufChunkList)
  (len i64))

;: Printable ASCII lookup table used by `text-buf-append-char`.
(define text-buf-ascii-printable-table : String
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

;: Return an empty text buffer.
(define (text-buf-empty) : TextBuf
  (TextBuf TextBufChunkNil 0))

;: Return true when `buf` contains no bytes.
(define (text-buf-empty? [buf : TextBuf]) : bool
  (= (struct-get buf len) 0))

;: Return the byte length currently represented by `buf`.
(define (text-buf-length [buf : TextBuf]) : i64
  (struct-get buf len))

;: Construct a chunk-list cons node for imported macro expansions.
(define (text-buf-chunk-cons [chunk : String] [rest : TextBufChunkList]) : TextBufChunkList
  (TextBufChunkCons chunk (box rest)))

;: Mutably append `chunk` to the owned `buf` place without rendering its prefix.
(defmacro (text-buf-append! [buf : Expr] [chunk : String]) : unit
  `(let
    [text-buf-append-chunk : String ,chunk]
    [text-buf-append-chunk-len : i64 (string-length text-buf-append-chunk)]
    (if (= text-buf-append-chunk-len 0)
      unit
      (begin
        (set!
          (struct-get ,buf chunks)
          (text-buf-chunk-cons text-buf-append-chunk (struct-get ,buf chunks)))
        (set!
          (struct-get ,buf len)
          (+ (struct-get ,buf len) text-buf-append-chunk-len))))))

;: Append `chunk` to `buf` without rendering the existing prefix.
(define (text-buf-append [buf : TextBuf] [chunk : String]) : TextBuf
  (let
    [chunk-len : i64 (string-length chunk)]
    (if (= chunk-len 0)
      buf
      (TextBuf
        (TextBufChunkCons chunk (box (struct-get buf chunks)))
        (+ (struct-get buf len) chunk-len)))))

;: Convert a supported byte-sized char to a one-byte String.
(define (text-buf-char-string [c : char]) : String
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(= code 9) "\t"]
      [(= code 10) "\n"]
      [(= code 13) "\r"]
      [(and (>= code 32) (<= code 126))
        (string_mod.substring
          stdlib.text_buf.text-buf-ascii-printable-table
          (- code 32)
          1)]
      [else (io.panic "text-buf: unsupported non-printable char")])))

;: Append one char byte to `buf`.
(define (text-buf-append-char [buf : TextBuf] [c : char]) : TextBuf
  (stdlib.text_buf.text-buf-append buf (stdlib.text_buf.text-buf-char-string c)))

;: Mutably append one char byte to `buf`.
(defmacro (text-buf-append-char! [buf : Expr] [c : char]) : unit
  `(text-buf-append! ,buf (text-buf-char-string ,c)))

;: Append the decimal text for `value` to `buf`.
(define (text-buf-append-int [buf : TextBuf] [value : i64]) : TextBuf
  (stdlib.text_buf.text-buf-append buf (string_mod.int->string value)))

;: Wrapper used by `text-buf-append-int!` macro expansions.
(define (text-buf-int-string [value : i64]) : String
  (string_mod.int->string value))

;: Mutably append the decimal text for `value` to `buf`.
(defmacro (text-buf-append-int! [buf : Expr] [value : i64]) : unit
  `(text-buf-append! ,buf (text-buf-int-string ,value)))

;: Concatenate chunk lists while preserving their current order.
(define (text-buf-chunk-list-concat
  [front : TextBufChunkList]
  [back : TextBufChunkList]) : TextBufChunkList
  (match front
    [(TextBufChunkNil) back]
    [(TextBufChunkCons chunk rest)
      (TextBufChunkCons
        chunk
        (box (stdlib.text_buf.text-buf-chunk-list-concat (box-get rest) back)))]))

;: Append all chunks from `right` after `left`.
(define (text-buf-append-buffer [left : TextBuf] [right : TextBuf]) : TextBuf
  (let
    [left-len : i64 (struct-get left len)]
    [right-len : i64 (struct-get right len)]
    (if (= right-len 0)
      left
      (if (= left-len 0)
        right
        (TextBuf
          (stdlib.text_buf.text-buf-chunk-list-concat
            (struct-get right chunks)
            (struct-get left chunks))
          (+ left-len right-len))))))

;: Render reversed chunks into `out`.
(define (text-buf-chunks-render-rev [chunks : TextBufChunkList] [out : String]) : String
  (match chunks
    [(TextBufChunkNil) out]
    [(TextBufChunkCons chunk rest)
      (stdlib.text_buf.text-buf-chunks-render-rev
        (box-get rest)
        (string_mod.string-append chunk out))]))

;: Return the number of chunk nodes in `chunks`, accumulating into `count`.
(define (text-buf-chunk-count [chunks : TextBufChunkList] [count : i64]) : i64
  (match chunks
    [(TextBufChunkNil) count]
    [(TextBufChunkCons _ rest)
      (stdlib.text_buf.text-buf-chunk-count (box-get rest) (+ count 1))]))

;: Fill `items` from a reversed chunk list so array order matches render order.
(define (text-buf-chunks-fill-array-rev
  [chunks : TextBufChunkList]
  [items : (Array String)]
  [index : i64]) : unit
  (match chunks
    [(TextBufChunkNil) unit]
    [(TextBufChunkCons chunk rest)
      (begin
        (array-set! items index chunk)
        (stdlib.text_buf.text-buf-chunks-fill-array-rev
          (box-get rest)
          items
          (- index 1)))]))

;: Render the half-open chunk array range `[lo, hi)` with balanced concatenation.
(define (text-buf-chunks-render-array-range
  [items : (Array String)]
  [lo : i64]
  [hi : i64]) : String
  (if (>= lo hi)
    ""
    (if (= (+ lo 1) hi)
      (array-ref items lo)
      (let
        [mid : i64 (/ (+ lo hi) 2)]
        (string_mod.string-append
          (stdlib.text_buf.text-buf-chunks-render-array-range items lo mid)
          (stdlib.text_buf.text-buf-chunks-render-array-range items mid hi))))))

;: Render many chunks through an array to avoid a deep left-leaning concat chain.
(define (text-buf-chunks-render-balanced
  [chunks : TextBufChunkList]
  [count : i64]) : String
  (let
    [items : (Array String) (make-array String count)]
    (begin
      (stdlib.text_buf.text-buf-chunks-fill-array-rev chunks items (- count 1))
      (stdlib.text_buf.text-buf-chunks-render-array-range items 0 count))))

;: Render `buf` to an owned String allocated in the active arena.
;: Copy `chunk`'s bytes into `dst` starting at byte offset `start`.
(define (text-buf-copy-chunk-into
  [chunk : (& chunk str)]
  [dst : (MutPtr u8)]
  [start : i64]) : unit
  (let
    [clen : i64 (string-length chunk)]
    [src : (Ptr u8)
      (unsafe
        (string-data chunk))]
    [words : i64 (/ clen 8)]
    [src64 : (Ptr i64)
      (unsafe
        (ptr-cast src : (Ptr i64)))]
    [dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset dst start) : (MutPtr i64)))]
    [w : i64 0]
    [b : i64 (* words 8)]
    ;; Copy eight bytes per step (x86 tolerates the unaligned word stores) and
    ;; finish the partial tail byte-wise so no read passes the chunk's end.
    (begin
      (while (< w words)
        (begin
          (unsafe
            (ptr-write! (ptr-offset dst64 w) (ptr-read (ptr-offset src64 w))))
          (set! w (+ w 1))))
      (while (< b clen)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst (+ start b))
              (ptr-read (ptr-offset src b))))
          (set! b (+ b 1))))
      unit)))

;: Small chunks are cheaper to copy inline while walking a render batch than to
;: enter the generic word-copy helper for each individual node.
(define (text-buf-render-small-chunk-limit) : i64
  16)

;: Fill the reversed `chunks` into `dst`, ending at byte offset `pos`. The first
;: node is the last-appended (rightmost) chunk, so it lands at the end and we walk
;: leftward, reproducing append order.
(define (text-buf-fill-rev-into
  [chunks : TextBufChunkList]
  [dst : (MutPtr u8)]
  [pos : i64]) : unit
  (let
    [cursor : TextBufChunkList chunks]
    [out-pos : i64 pos]
    [done : bool false]
    [small-limit : i64 (stdlib.text_buf.text-buf-render-small-chunk-limit)]
    (begin
      (while (not done)
        (match cursor
          [(TextBufChunkNil) (set! done true)]
          [(TextBufChunkCons chunk rest)
            (let
              [clen : i64 (string-length (& chunk))]
              (if (<= clen small-limit)
                (let
                  [small-run : bool true]
                  (begin
                    (while small-run
                      (match cursor
                        [(TextBufChunkNil)
                          (begin
                            (set! done true)
                            (set! small-run false))]
                        [(TextBufChunkCons small-chunk small-rest)
                          (let
                            [small-len : i64 (string-length (& small-chunk))]
                            (if (<= small-len small-limit)
                              (let
                                [small-start : i64 (- out-pos small-len)]
                                [src : (Ptr u8)
                                  (unsafe
                                    (string-data (& small-chunk)))]
                                [b : i64 0]
                                (begin
                                  (while (< b small-len)
                                    (begin
                                      (unsafe
                                        (ptr-write!
                                          (ptr-offset dst (+ small-start b))
                                          (ptr-read (ptr-offset src b))))
                                      (set! b (+ b 1))))
                                  (set! out-pos small-start)
                                  (set! cursor (box-get small-rest))))
                              (set! small-run false)))]))
                    unit))
                (let
                  [start : i64 (- out-pos clen)]
                  (begin
                    (stdlib.text_buf.text-buf-copy-chunk-into
                      (& chunk)
                      dst
                      start)
                    (set! out-pos start)
                    (set! cursor (box-get rest))))))]))
      unit)))

;: Render reversed owned chunks in O(total length): allocate the exact byte
;: count once and copy each chunk into place. This helper is the shared final
;: materialization path for owned and borrowed text buffers.
(define (text-buf-render-chunks [chunks : TextBufChunkList] [len : i64]) : String
  (if (= len 0)
    ""
    (let
      [out : (Array u8) (make-array u8 len)]
      [dst : (MutPtr u8)
        (unsafe
          (array-data out))]
      (begin
        (stdlib.text_buf.text-buf-fill-rev-into chunks dst len)
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) len))))))

;: Render the buffer to an owned String allocated in the active arena.
(define (text-buf-render [buf : TextBuf]) : String
  (stdlib.text_buf.text-buf-render-chunks
    (struct-get buf chunks)
    (struct-get buf len)))

;: Write chunks in insertion order to an open raw file handle.
(define (text-buf-write-chunks-rev [raw : i64] [chunks : TextBufChunkList]) : i64
  (match chunks
    [(TextBufChunkNil) io.io-status-ok]
    [(TextBufChunkCons chunk rest)
      (let
        [status : i64
          (stdlib.text_buf.text-buf-write-chunks-rev raw (box-get rest))]
        (if (= status io.io-status-ok)
          (io.file-write-status raw chunk)
          status))]))

;: Buffers larger than this are rendered and written in bounded batches. This
;: avoids pathological many-small-write behavior on mounted host filesystems
;: without materializing the entire buffer in one extra String.
(define (text-buf-batched-write-threshold) : i64
  1048576)

;: Write `items` to `raw` in rendered batches no larger than `batch-limit`
;: bytes, stopping at the first file-write error status.
(define (text-buf-write-array-batches
  [raw : i64]
  [items : (Array String)]
  [count : i64]
  [batch-limit : i64]) : i64
  (let
    [index : i64 0]
    [status : i64 io.io-status-ok]
    (begin
      (while (and (= status io.io-status-ok) (< index count))
        (let
          [start : i64 index]
          [bytes : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (< index count))
              (let
                [chunk : String (array-ref items index)]
                [chunk-len : i64 (string-length chunk)]
                (if (and (> bytes 0) (> (+ bytes chunk-len) batch-limit))
                  (set! done true)
                  (begin
                    (set! bytes (+ bytes chunk-len))
                    (set! index (+ index 1))))))
            (set!
              status
              (io.file-write-status
                raw
                (stdlib.text_buf.text-buf-chunks-render-array-range
                  items
                  start
                  index))))))
      status)))

;: Write chunked buffer contents to `raw` by first flattening chunk order into
;: an array, then emitting bounded batches.
(define (text-buf-write-chunks-batched [raw : i64] [chunks : TextBufChunkList]) : i64
  (let
    [count : i64 (stdlib.text_buf.text-buf-chunk-count chunks 0)]
    [items : (Array String) (make-array String count)]
    (begin
      (stdlib.text_buf.text-buf-chunks-fill-array-rev chunks items (- count 1))
      (stdlib.text_buf.text-buf-write-array-batches
        raw
        items
        count
        (stdlib.text_buf.text-buf-batched-write-threshold)))))

;: Write the rendered buffer contents to `path`, replacing any existing file.
(define (text-buf-write-file [path : String] [buf : TextBuf]) : i64
  (let
    [chunks : TextBufChunkList (struct-get buf chunks)]
    [len : i64 (struct-get buf len)]
    [open-result : io.ResultIoFile
      (io.file-open (& path) (io.OpenWriteTruncate))]
    (if (io.io-result-file-ok? open-result)
      (let
        [handle : io.FileHandle
          (io.io-result-file-value-or open-result (io.FileHandle -1))]
        [write-status : i64
          (if (> len (stdlib.text_buf.text-buf-batched-write-threshold))
            (stdlib.text_buf.text-buf-write-chunks-batched
              (struct-get handle id)
              chunks)
            (stdlib.text_buf.text-buf-write-chunks-rev
              (struct-get handle id)
              chunks))]
        [close-result : io.ResultIoUnit (io.file-close handle)]
        (if (io.io-result-unit-ok? close-result)
          write-status
          1))
      1)))

;: Mutably clear `buf`, leaving it ready for reuse.
(define (text-buf-clear-ref! [buf : (&mut buf TextBuf)]) : unit
  (begin
    (set! (struct-get buf chunks) TextBufChunkNil)
    (set! (struct-get buf len) 0)))

;: Mutably clear the owned `buf` place, leaving it ready for reuse.
(defmacro (text-buf-clear! [buf : Expr]) : unit
  `(text-buf-clear-ref! (&mut ,buf)))

;: Return an empty buffer, leaving the old immutable `buf` value unchanged.
(define (text-buf-clear [_buf : TextBuf]) : TextBuf
  (stdlib.text_buf.text-buf-empty))

;: Mutably reset `buf`, leaving it ready for reuse.
(defmacro (text-buf-reset! [buf : Expr]) : unit
  `(text-buf-clear-ref! (&mut ,buf)))

;: Alias for `text-buf-clear` for call sites that model builder reuse as reset.
(define (text-buf-reset [buf : TextBuf]) : TextBuf
  (stdlib.text_buf.text-buf-clear buf))

(test
  text-buf-scoped-arena-render-policy
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [program-buf : TextBuf
      (stdlib.text_buf.text-buf-append
        (stdlib.text_buf.text-buf-empty)
        "scoped")]
    (with-arena
      outer
      (with-arena
        inner
        (let
          [rendered : String (stdlib.text_buf.text-buf-render program-buf)]
          [expected : String "scoped"]
          (if (string_mod.string-eq-borrowed (& rendered) (& expected))
            unit
            (fail)))))))

;; Inline coverage migrated from stdlib/tests/text_buf_api.tl (#3082).
(cfg test (import stdlib.test))

(cfg
  test
  (define (text-buf-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (text-buf-test-assert-text-buf
    [buf : TextBuf]
    [expected : String]
    [message : String]) : unit
    (begin
      (stdlib.text_buf.text-buf-test-assert-owned-string-eq
        (stdlib.text_buf.text-buf-render buf)
        expected
        message)
      (test.assert-i64-eq
        (stdlib.text_buf.text-buf-length buf)
        (string-length expected)
        message))))

(cfg
  test
  (define (text-buf-test-main) : i64
    (begin
      (test.assert-true
        (stdlib.text_buf.text-buf-empty? (stdlib.text_buf.text-buf-empty))
        "empty buffer predicate")
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.text-buf-empty)
        ""
        "empty buffer renders empty")
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.text-buf-append
          (stdlib.text_buf.text-buf-append
            (stdlib.text_buf.text-buf-append
              (stdlib.text_buf.text-buf-empty)
              "alpha")
            " ")
          "beta")
        "alpha beta"
        "append order")
      (let
        [buf : TextBuf (stdlib.text_buf.text-buf-empty)]
        (begin
          (stdlib.text_buf.text-buf-append! buf "")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            ""
            "mutable empty append leaves buffer empty")
          (stdlib.text_buf.text-buf-append! buf "alpha")
          (stdlib.text_buf.text-buf-append! buf "")
          (stdlib.text_buf.text-buf-append! buf " beta")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "alpha beta"
            "mutable append order")))
      (let
        [buf : TextBuf (stdlib.text_buf.text-buf-empty)]
        [i : i64 0]
        (begin
          (while (< i 6)
            (begin
              (set! buf (stdlib.text_buf.text-buf-append buf "ha"))
              (set! i (+ i 1))))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "hahahahahaha"
            "repeated append")))
      (let
        [buf : TextBuf (stdlib.text_buf.text-buf-empty)]
        [i : i64 0]
        (begin
          (while (< i 6)
            (begin
              (stdlib.text_buf.text-buf-append! buf "ha")
              (set! i (+ i 1))))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "hahahahahaha"
            "mutable repeated append")))
      (let
        [buf : TextBuf (stdlib.text_buf.text-buf-empty)]
        [i : i64 0]
        (begin
          (while (< i 40)
            (begin
              (set! buf (stdlib.text_buf.text-buf-append buf "x"))
              (set! i (+ i 1))))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            "balanced repeated append")))
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.text-buf-append
          (stdlib.text_buf.text-buf-append
            (stdlib.text_buf.text-buf-append
              (stdlib.text_buf.text-buf-append
                (stdlib.text_buf.text-buf-empty)
                "0123456789abcdefg")
              "a")
            "b")
          "0123456789abcdefg")
        "0123456789abcdefgab0123456789abcdefg"
        "mixed small and large chunks")
      (stdlib.text_buf.text-buf-test-assert-text-buf
        (stdlib.text_buf.text-buf-append-int
          (stdlib.text_buf.text-buf-append-char
            (stdlib.text_buf.text-buf-append-char
              (stdlib.text_buf.text-buf-append
                (stdlib.text_buf.text-buf-empty)
                "A")
              '\n')
            '\t')
          -12)
        "A\n\t-12"
        "char and int append")
      (let
        [buf : TextBuf (stdlib.text_buf.text-buf-empty)]
        (begin
          (stdlib.text_buf.text-buf-append! buf "A")
          (stdlib.text_buf.text-buf-append-char! buf '\n')
          (stdlib.text_buf.text-buf-append-char! buf '\t')
          (stdlib.text_buf.text-buf-append-int! buf (cast -12 : i64))
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "A\n\t-12"
            "mutable char and int append")))
      (let
        [left : TextBuf
          (stdlib.text_buf.text-buf-append
            (stdlib.text_buf.text-buf-append
              (stdlib.text_buf.text-buf-empty)
              "left")
            "-")]
        [right : TextBuf
          (stdlib.text_buf.text-buf-append
            (stdlib.text_buf.text-buf-append
              (stdlib.text_buf.text-buf-empty)
              "right")
            "\n")]
        (stdlib.text_buf.text-buf-test-assert-text-buf
          (stdlib.text_buf.text-buf-append-buffer left right)
          "left-right\n"
          "append buffer"))
      (let
        [original : TextBuf
          (stdlib.text_buf.text-buf-append
            (stdlib.text_buf.text-buf-empty)
            "keep")]
        (begin
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (stdlib.text_buf.text-buf-clear original)
            ""
            "clear returns empty")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            (stdlib.text_buf.text-buf-reset original)
            ""
            "reset returns empty")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            original
            "keep"
            "clear leaves original value")))
      (let
        [buf : TextBuf
          (stdlib.text_buf.text-buf-append
            (stdlib.text_buf.text-buf-empty)
            "drop")]
        (begin
          (stdlib.text_buf.text-buf-clear! buf)
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            ""
            "mutable clear empties buffer")
          (stdlib.text_buf.text-buf-append! buf "again")
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            "again"
            "mutable append after clear")
          (stdlib.text_buf.text-buf-reset! buf)
          (stdlib.text_buf.text-buf-test-assert-text-buf
            buf
            ""
            "mutable reset empties buffer")))
      42)))

(cfg
  test
  (test
    text-buf-api
    (test.assert-i64-eq
      (stdlib.text_buf.text-buf-test-main)
      42
      "text-buf-api fixture result")))

(cfg
  test
  (export
    (value text-buf-test-assert-owned-string-eq)
    (value text-buf-test-assert-text-buf)
    (value text-buf-test-main)))

(export
  (value text-buf-ascii-printable-table)
  (value text-buf-empty)
  (value text-buf-empty?)
  (value text-buf-length)
  (value text-buf-chunk-cons)
  (value text-buf-append)
  (value text-buf-char-string)
  (value text-buf-append-char)
  (value text-buf-append-int)
  (value text-buf-int-string)
  (value text-buf-chunk-list-concat)
  (value text-buf-append-buffer)
  (value text-buf-chunks-render-rev)
  (value text-buf-chunk-count)
  (value text-buf-chunks-fill-array-rev)
  (value text-buf-chunks-render-array-range)
  (value text-buf-chunks-render-balanced)
  (value text-buf-copy-chunk-into)
  (value text-buf-render-small-chunk-limit)
  (value text-buf-fill-rev-into)
  (value text-buf-render-chunks)
  (value text-buf-render)
  (value text-buf-write-chunks-rev)
  (value text-buf-batched-write-threshold)
  (value text-buf-write-array-batches)
  (value text-buf-write-chunks-batched)
  (value text-buf-write-file)
  (value text-buf-clear-ref!)
  (value text-buf-clear)
  (value text-buf-reset)
  (type TextBufChunkList)
  (type TextBuf)
  (constructor TextBuf)
  (field TextBuf chunks)
  (field TextBuf len)
  (variant TextBufChunkNil)
  (variant TextBufChunkCons)
  (macro text-buf-append!)
  (macro text-buf-append-char!)
  (macro text-buf-append-int!)
  (macro text-buf-clear!)
  (macro text-buf-reset!))