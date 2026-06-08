;# Arena-aware text buffer utilities for incremental string construction.
;#
;# `TextBuf` is a byte-oriented text builder backed by active-arena chunk
;# nodes. Appending records owned chunks without concatenating the accumulated
;# prefix on every step; `text-buf-render` is the single operation that
;# materializes an owned `String` in the active arena.
;#
;# The borrowed-chunk companion surface lives in
;# `stdlib/text_buf_borrowed.tl` while `TextBuf` keeps the owned chunk API.
;#
;# Usage: `(import "stdlib/text_buf.tl")`
;#
;# ```typelisp
;# (import "stdlib/text_buf.tl")
;# (define (main) : i64
;#   (let ([buf : TextBuf
;#     (text-buf-append-int (text-buf-append (text-buf-empty) "n=") 7)])
;#     (if (string-eq (text-buf-render buf) "n=7") 42 1)))
;# ```
;#
;# The buffer and rendered strings allocate in the active arena: the default
;# program-lifetime arena outside `(with-arena ...)`, or the scoped arena inside
;# one.
(import "core_macros.tl" module stdlib.core-macros as core)

(import "io.tl")

;: Reversed chunk list. Each cons node is allocated in the active arena.
(defenum TextBufChunkList
  (TextBufChunkNil)
  (TextBufChunkCons String (Box TextBufChunkList)))

;: Text buffer value with reversed chunks and cached byte length.
(defenum TextBuf
  (TextBuf TextBufChunkList i64))

;: Printable ASCII lookup table used by `text-buf-append-char`.
(define text-buf-ascii-printable-table : String
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

;: Return an empty text buffer.
(define (text-buf-empty) : TextBuf
  (TextBuf TextBufChunkNil 0))

;: Return true when `buf` contains no bytes.
(define (text-buf-empty? [buf : TextBuf]) : bool
  (match buf
    [(TextBuf _ len) (= len 0)]))

;: Return the byte length currently represented by `buf`.
(define (text-buf-length [buf : TextBuf]) : i64
  (match buf
    [(TextBuf _ len) len]))

;: Append `chunk` to `buf` without rendering the existing prefix.
(define (text-buf-append [buf : TextBuf] [chunk : String]) : TextBuf
  (let
    [chunk-len : i64 (string-length chunk)]
    (if (= chunk-len 0)
      buf
      (match buf
        [(TextBuf chunks len)
          (TextBuf (TextBufChunkCons chunk (box chunks)) (+ len chunk-len))]))))

;: Convert a supported byte-sized char to a one-byte String.
(define (text-buf-char-string [c : char]) : String
  (let
    [code : i64 (cast c : i64)]
    (core/cond
      (= code 9)
      "\t"
      (= code 10)
      "\n"
      (= code 13)
      "\r"
      (and (>= code 32) (<= code 126))
      (substring text-buf-ascii-printable-table (- code 32) 1)
      (panic "text-buf: unsupported non-printable char"))))

;: Append one char byte to `buf`.
(define (text-buf-append-char [buf : TextBuf] [c : char]) : TextBuf
  (text-buf-append buf (text-buf-char-string c)))

;: Append the decimal text for `value` to `buf`.
(define (text-buf-append-int [buf : TextBuf] [value : i64]) : TextBuf
  (text-buf-append buf (int->string value)))

;: Concatenate chunk lists while preserving their current order.
(define (text-buf-chunk-list-concat
  [front : TextBufChunkList]
  [back : TextBufChunkList]) : TextBufChunkList
  (match front
    [(TextBufChunkNil) back]
    [(TextBufChunkCons chunk rest)
      (TextBufChunkCons
        chunk
        (box (text-buf-chunk-list-concat (box-get rest) back)))]))

;: Append all chunks from `right` after `left`.
(define (text-buf-append-buffer [left : TextBuf] [right : TextBuf]) : TextBuf
  (match left
    [(TextBuf left-chunks left-len)
      (match right
        [(TextBuf right-chunks right-len)
          (if (= right-len 0)
            left
            (if (= left-len 0)
              right
              (TextBuf
                (text-buf-chunk-list-concat right-chunks left-chunks)
                (+ left-len right-len))))])]))

;: Render reversed chunks into `out`.
(define (text-buf-chunks-render-rev [chunks : TextBufChunkList] [out : String]) : String
  (match chunks
    [(TextBufChunkNil) out]
    [(TextBufChunkCons chunk rest)
      (text-buf-chunks-render-rev (box-get rest) (string-append chunk out))]))

;: Return the number of chunk nodes in `chunks`, accumulating into `count`.
(define (text-buf-chunk-count [chunks : TextBufChunkList] [count : i64]) : i64
  (match chunks
    [(TextBufChunkNil) count]
    [(TextBufChunkCons _ rest)
      (text-buf-chunk-count (box-get rest) (+ count 1))]))

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
        (text-buf-chunks-fill-array-rev (box-get rest) items (- index 1)))]))

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
        (string-append
          (text-buf-chunks-render-array-range items lo mid)
          (text-buf-chunks-render-array-range items mid hi))))))

;: Render many chunks through an array to avoid a deep left-leaning concat chain.
(define (text-buf-chunks-render-balanced
  [chunks : TextBufChunkList]
  [count : i64]) : String
  (let
    [items : (Array String) (make-array String count)]
    (begin
      (text-buf-chunks-fill-array-rev chunks items (- count 1))
      (text-buf-chunks-render-array-range items 0 count))))

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

;: Fill the reversed `chunks` into `dst`, ending at byte offset `pos`. The first
;: node is the last-appended (rightmost) chunk, so it lands at the end and we walk
;: leftward, reproducing append order.
(define (text-buf-fill-rev-into
  [chunks : TextBufChunkList]
  [dst : (MutPtr u8)]
  [pos : i64]) : unit
  (match chunks
    [(TextBufChunkNil) unit]
    [(TextBufChunkCons chunk rest)
      (let
        [start : i64 (- pos (string-length (& chunk)))]
        (begin
          (text-buf-copy-chunk-into (& chunk) dst start)
          (text-buf-fill-rev-into (box-get rest) dst start)))]))

;: Render the buffer in O(total length): allocate the exact byte count once and
;: copy each chunk into place (the cached length makes this a single allocation
;: plus linear copies, vs the O(n^2) prefix concatenation of the fallbacks).
(define (text-buf-render [buf : TextBuf]) : String
  (match buf
    [(TextBuf chunks len)
      (if (= len 0)
        ""
        (let
          [out : (Array u8) (make-array u8 len)]
          [dst : (MutPtr u8)
            (unsafe
              (array-data out))]
          (begin
            (text-buf-fill-rev-into chunks dst len)
            (unsafe
              (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))]))

;: Write chunks in insertion order to an open raw file handle.
(define (text-buf-write-chunks-rev [raw : i64] [chunks : TextBufChunkList]) : i64
  (match chunks
    [(TextBufChunkNil) io-status-ok]
    [(TextBufChunkCons chunk rest)
      (let
        [status : i64 (text-buf-write-chunks-rev raw (box-get rest))]
        (if (= status io-status-ok)
          (file-write-status raw chunk)
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
    [status : i64 io-status-ok]
    (begin
      (while (and (= status io-status-ok) (< index count))
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
              (file-write-status
                raw
                (text-buf-chunks-render-array-range items start index))))))
      status)))

;: Write chunked buffer contents to `raw` by first flattening chunk order into
;: an array, then emitting bounded batches.
(define (text-buf-write-chunks-batched [raw : i64] [chunks : TextBufChunkList]) : i64
  (let
    [count : i64 (text-buf-chunk-count chunks 0)]
    [items : (Array String) (make-array String count)]
    (begin
      (text-buf-chunks-fill-array-rev chunks items (- count 1))
      (text-buf-write-array-batches
        raw
        items
        count
        (text-buf-batched-write-threshold)))))

;: Write the rendered buffer contents to `path`, replacing any existing file.
(define (text-buf-write-file [path : String] [buf : TextBuf]) : i64
  (match buf
    [(TextBuf chunks len)
      (match (file-open (& path) (OpenWriteTruncate))
        [(OkIoFile handle)
          (let
            [write-status : i64
              (if (> len (text-buf-batched-write-threshold))
                (text-buf-write-chunks-batched (struct-get handle id) chunks)
                (text-buf-write-chunks-rev (struct-get handle id) chunks))]
            [close-result : ResultIoUnit (file-close handle)]
            (match close-result
              [(OkIoUnit) write-status]
              [(ErrIoUnit _) 1]))]
        [(ErrIoFile _) 1])]))

;: Return an empty buffer, leaving the old immutable `buf` value unchanged.
(define (text-buf-clear [buf : TextBuf]) : TextBuf
  (match buf
    [(TextBuf _ _) (text-buf-empty)]))

;: Alias for `text-buf-clear` for call sites that model builder reuse as reset.
(define (text-buf-reset [buf : TextBuf]) : TextBuf
  (text-buf-clear buf))