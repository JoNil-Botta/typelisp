;# Arena-aware text buffer utilities for incremental string construction.
;#
;# `TextBuf` is a byte-oriented text builder backed by active-arena chunk
;# nodes. Appending records owned chunks without concatenating the accumulated
;# prefix on every step; `text-buf-render` is the single operation that
;# materializes an owned `String` in the active arena.
;#
;# `TextBufBorrowed` is the lifetime-parameterized borrowed-chunk surface. It
;# stores `(& text str)` chunks without copying at append time, plus owned chunks
;# for explicit copy boundaries. `text-buf-borrowed-render` copies borrowed
;# chunks while materializing the final owned `String`.
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
;# The owned buffer and rendered strings allocate in the active arena: the
;# default program-lifetime arena outside `(with-arena ...)`, or the scoped arena
;# inside one. Borrowed buffer chunks are tied to their source lifetime; use
;# `text-buf-borrowed-append-copy` or `text-buf-borrowed-append-owned` when a
;# chunk should not constrain the borrowed buffer lifetime.
(import "io.tl")

;: Reversed chunk list. Each cons node is allocated in the active arena.
(defenum TextBufChunkList
  (TextBufChunkNil)
  (TextBufChunkCons String (Box TextBufChunkList)))

;: Text buffer value with reversed chunks and cached byte length.
(defenum TextBuf
  (TextBuf TextBufChunkList i64))

;: Borrowed buffer chunk. Borrowed chunks are not copied until render; owned
;: chunks are available as explicit lifetime boundaries.
(defenum TextBufBorrowedChunk
  (:lifetimes text)
  (TextBufBorrowedChunkBorrowed (& text str))
  (TextBufBorrowedChunkOwned String))

;: Reversed borrowed chunk list. Each cons node is allocated in the active arena.
(defenum TextBufBorrowedChunkList
  (:lifetimes text)
  (TextBufBorrowedChunkNil)
  (TextBufBorrowedChunkCons
    (TextBufBorrowedChunk text)
    (Box (TextBufBorrowedChunkList text))))

;: Lifetime-parameterized text buffer with borrowed or owned chunks.
(defenum TextBufBorrowed
  (:lifetimes text)
  (TextBufBorrowed (TextBufBorrowedChunkList text) i64))

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

;: Return an empty borrowed buffer tied to `text` without storing `text`.
(define (text-buf-borrowed-empty-like [text : (& text str)]) : (TextBufBorrowed
  text)
  (TextBufBorrowed TextBufBorrowedChunkNil 0))

;: Return a borrowed buffer containing one borrowed chunk.
(define (text-buf-borrowed-single [text : (& text str)]) : (TextBufBorrowed
  text)
  (let
    [chunk-len : i64 (string-length text)]
    (TextBufBorrowed
      (TextBufBorrowedChunkCons
        (TextBufBorrowedChunkBorrowed text)
        (box TextBufBorrowedChunkNil))
      chunk-len)))

;: Return true when `buf` contains no bytes.
(define (text-buf-borrowed-empty? [buf : (TextBufBorrowed text)]) : bool
  (match buf
    [(TextBufBorrowed _ len) (= len 0)]))

;: Return the byte length currently represented by `buf`.
(define (text-buf-borrowed-length [buf : (TextBufBorrowed text)]) : i64
  (match buf
    [(TextBufBorrowed _ len) len]))

;: Append borrowed `text` to `buf` without copying bytes at append time.
(define (text-buf-borrowed-append
  [buf : (TextBufBorrowed text)]
  [text : (& text str)]) : (TextBufBorrowed text)
  (let
    [chunk-len : i64 (string-length text)]
    (match buf
      [(TextBufBorrowed chunks len)
        (TextBufBorrowed
          (TextBufBorrowedChunkCons
            (TextBufBorrowedChunkBorrowed text)
            (box chunks))
          (+ len chunk-len))])))

;: Append owned `chunk` to `buf`. The chunk does not constrain `buf`'s lifetime.
(define (text-buf-borrowed-append-owned
  [buf : (TextBufBorrowed text)]
  [chunk : String]) : (TextBufBorrowed text)
  (let
    [chunk-len : i64 (string-length chunk)]
    (match buf
      [(TextBufBorrowed chunks len)
        (TextBufBorrowed
          (TextBufBorrowedChunkCons
            (TextBufBorrowedChunkOwned chunk)
            (box chunks))
          (+ len chunk-len))])))

;: Copy borrowed `chunk` into active-arena storage before appending it.
(define (text-buf-borrowed-append-copy
  [buf : (TextBufBorrowed text)]
  [chunk : (& chunk str)]) : (TextBufBorrowed text)
  (text-buf-borrowed-append-owned buf (substring chunk 0 (string-length chunk))))

;: Convert a supported byte-sized char to a one-byte String.
(define (text-buf-char-string [c : char]) : String
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(= code 9) "\t"]
      [(= code 10) "\n"]
      [(= code 13) "\r"]
      [(and (>= code 32) (<= code 126))
        (substring text-buf-ascii-printable-table (- code 32) 1)]
      [else (panic "text-buf: unsupported non-printable char")])))

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

;: Append rendered `right` after `left`. This is an explicit owned-copy
;: boundary, so `right` may be assembled independently before being appended.
(define (text-buf-borrowed-append-buffer
  [left : (TextBufBorrowed text)]
  [right : (TextBufBorrowed text)]) : (TextBufBorrowed text)
  (text-buf-borrowed-append-owned left (text-buf-borrowed-render right)))

;: Render reversed chunks into `out`.
(define (text-buf-chunks-render-rev [chunks : TextBufChunkList] [out : String]) : String
  (match chunks
    [(TextBufChunkNil) out]
    [(TextBufChunkCons chunk rest)
      (text-buf-chunks-render-rev (box-get rest) (string-append chunk out))]))

;: Return `chunk` as owned active-arena text. Borrowed chunks are copied.
(define (text-buf-borrowed-chunk-string [chunk : (TextBufBorrowedChunk text)]) : String
  (match chunk
    [(TextBufBorrowedChunkBorrowed text)
      (substring text 0 (string-length text))]
    [(TextBufBorrowedChunkOwned text) text]))

;: Render reversed borrowed chunks into `out`.
(define (text-buf-borrowed-chunks-render-rev
  [chunks : (TextBufBorrowedChunkList text)]
  [out : String]) : String
  (match chunks
    [(TextBufBorrowedChunkNil) out]
    [(TextBufBorrowedChunkCons chunk rest)
      (text-buf-borrowed-chunks-render-rev
        (box-get rest)
        (string-append (text-buf-borrowed-chunk-string chunk) out))]))

;: Return the number of chunk nodes in `chunks`, accumulating into `count`.
(define (text-buf-chunk-count [chunks : TextBufChunkList] [count : i64]) : i64
  (match chunks
    [(TextBufChunkNil) count]
    [(TextBufChunkCons _ rest)
      (text-buf-chunk-count (box-get rest) (+ count 1))]))

;: Return the number of borrowed chunk nodes in `chunks`, accumulating into
;: `count`.
(define (text-buf-borrowed-chunk-count
  [chunks : (TextBufBorrowedChunkList text)]
  [count : i64]) : i64
  (match chunks
    [(TextBufBorrowedChunkNil) count]
    [(TextBufBorrowedChunkCons _ rest)
      (text-buf-borrowed-chunk-count (box-get rest) (+ count 1))]))

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

;: Fill `items` with owned copies from a reversed borrowed chunk list.
(define (text-buf-borrowed-chunks-fill-array-rev
  [chunks : (TextBufBorrowedChunkList text)]
  [items : (Array String)]
  [index : i64]) : unit
  (match chunks
    [(TextBufBorrowedChunkNil) unit]
    [(TextBufBorrowedChunkCons chunk rest)
      (begin
        (array-set! items index (text-buf-borrowed-chunk-string chunk))
        (text-buf-borrowed-chunks-fill-array-rev
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

;: Render many borrowed chunks through an owned String array to avoid a deep
;: left-leaning concat chain while preserving borrowed append-time storage.
(define (text-buf-borrowed-chunks-render-balanced
  [chunks : (TextBufBorrowedChunkList text)]
  [count : i64]) : String
  (let
    [items : (Array String) (make-array String count)]
    (begin
      (text-buf-borrowed-chunks-fill-array-rev chunks items (- count 1))
      (text-buf-chunks-render-array-range items 0 count))))

;: Render `buf` to an owned String allocated in the active arena.
(define (text-buf-render [buf : TextBuf]) : String
  (match buf
    [(TextBuf chunks _)
      (let
        [count : i64 (text-buf-chunk-count chunks 0)]
        (if (> count 32)
          (text-buf-chunks-render-balanced chunks count)
          (text-buf-chunks-render-rev chunks "")))]))

;: Render borrowed `buf` to an owned String allocated in the active arena.
(define (text-buf-borrowed-render [buf : (TextBufBorrowed text)]) : String
  (match buf
    [(TextBufBorrowed chunks _)
      (let
        [count : i64 (text-buf-borrowed-chunk-count chunks 0)]
        (if (> count 32)
          (text-buf-borrowed-chunks-render-balanced chunks count)
          (text-buf-borrowed-chunks-render-rev chunks "")))]))

;: Return an empty buffer, leaving the old immutable `buf` value unchanged.
(define (text-buf-clear [buf : TextBuf]) : TextBuf
  (match buf
    [(TextBuf _ _) (text-buf-empty)]))

;: Alias for `text-buf-clear` for call sites that model builder reuse as reset.
(define (text-buf-reset [buf : TextBuf]) : TextBuf
  (text-buf-clear buf))