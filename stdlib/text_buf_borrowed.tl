;# Borrowed text buffer companion surface.
;#
;# `TextBufBorrowed` stores `(& text str)` chunks without copying at append
;# time, plus owned chunks for explicit copy boundaries. Rendering copies
;# borrowed chunks while materializing the final owned `String`.
;#
;# This module intentionally remains separate from `text_buf.tl` while the
;# compatibility surface keeps owned chunk storage.
(module stdlib.text_buf_borrowed)

(import stdlib.text_buf as text_buf_mod)

(import stdlib.string as string_mod)

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

;: Return an empty borrowed buffer tied to `text` without storing `text`.
(define (text-buf-borrowed-empty-like [text : (& text str)]) : (TextBufBorrowed
    text)
  (TextBufBorrowed stdlib.text_buf_borrowed.TextBufBorrowedChunkNil 0))

;: Return a borrowed buffer containing one borrowed chunk.
(define (text-buf-borrowed-single [text : (& text str)]) : (TextBufBorrowed
    text)
  (let
    [chunk-len : i64 (string-length text)]
    (TextBufBorrowed
      (TextBufBorrowedChunkCons
        (TextBufBorrowedChunkBorrowed text)
        (box stdlib.text_buf_borrowed.TextBufBorrowedChunkNil))
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
  (stdlib.text_buf_borrowed.text-buf-borrowed-append-owned
    buf
    (string_mod.substring-borrowed chunk 0 (string-length chunk))))

;: Append rendered `right` after `left`. This is an explicit owned-copy
;: boundary, so `right` may be assembled independently before being appended.
(define (text-buf-borrowed-append-buffer
  [left : (TextBufBorrowed text)]
  [right : (TextBufBorrowed text)]) : (TextBufBorrowed text)
  (stdlib.text_buf_borrowed.text-buf-borrowed-append-owned
    left
    (stdlib.text_buf_borrowed.text-buf-borrowed-render right)))

;: Return `chunk` as owned active-arena text. Borrowed chunks are copied.
(define (text-buf-borrowed-chunk-string [chunk : (TextBufBorrowedChunk text)]) : String
  (match chunk
    [(TextBufBorrowedChunkBorrowed text)
      (string_mod.substring-borrowed text 0 (string-length text))]
    [(TextBufBorrowedChunkOwned text) text]))

;: Render reversed borrowed chunks into `out`.
(define (text-buf-borrowed-chunks-render-rev
  [chunks : (TextBufBorrowedChunkList text)]
  [out : String]) : String
  (match chunks
    [(TextBufBorrowedChunkNil) out]
    [(TextBufBorrowedChunkCons chunk rest)
      (stdlib.text_buf_borrowed.text-buf-borrowed-chunks-render-rev
        (box-get rest)
        (string_mod.string-append
          (stdlib.text_buf_borrowed.text-buf-borrowed-chunk-string chunk)
          out))]))

;: Return the number of borrowed chunk nodes in `chunks`, accumulating into
;: `count`.
(define (text-buf-borrowed-chunk-count
  [chunks : (TextBufBorrowedChunkList text)]
  [count : i64]) : i64
  (match chunks
    [(TextBufBorrowedChunkNil) count]
    [(TextBufBorrowedChunkCons _ rest)
      (stdlib.text_buf_borrowed.text-buf-borrowed-chunk-count
        (box-get rest)
        (+ count 1))]))

;: Fill `items` with owned copies from a reversed borrowed chunk list.
(define (text-buf-borrowed-chunks-fill-array-rev
  [chunks : (TextBufBorrowedChunkList text)]
  [items : (Array String)]
  [index : i64]) : unit
  (match chunks
    [(TextBufBorrowedChunkNil) unit]
    [(TextBufBorrowedChunkCons chunk rest)
      (begin
        (array-set!
          items
          index
          (stdlib.text_buf_borrowed.text-buf-borrowed-chunk-string chunk))
        (stdlib.text_buf_borrowed.text-buf-borrowed-chunks-fill-array-rev
          (box-get rest)
          items
          (- index 1)))]))

;: Render many borrowed chunks through an owned String array to avoid a deep
;: left-leaning concat chain while preserving borrowed append-time storage.
(define (text-buf-borrowed-chunks-render-balanced
  [chunks : (TextBufBorrowedChunkList text)]
  [count : i64]) : String
  (let
    [items : (Array String) (make-array String count)]
    (begin
      (stdlib.text_buf_borrowed.text-buf-borrowed-chunks-fill-array-rev
        chunks
        items
        (- count 1))
      (text_buf_mod.text-buf-chunks-render-array-range items 0 count))))

;: Render borrowed `buf` to an owned String allocated in the active arena.
(define (text-buf-borrowed-render [buf : (TextBufBorrowed text)]) : String
  (match buf
    [(TextBufBorrowed chunks _)
      (let
        [count : i64
          (stdlib.text_buf_borrowed.text-buf-borrowed-chunk-count chunks 0)]
        (if (> count 32)
          (stdlib.text_buf_borrowed.text-buf-borrowed-chunks-render-balanced
            chunks
            count)
          (stdlib.text_buf_borrowed.text-buf-borrowed-chunks-render-rev
            chunks
            "")))]))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value text-buf-borrowed-empty-like)
  (value text-buf-borrowed-single)
  (value text-buf-borrowed-empty?)
  (value text-buf-borrowed-length)
  (value text-buf-borrowed-append)
  (value text-buf-borrowed-append-owned)
  (value text-buf-borrowed-append-copy)
  (value text-buf-borrowed-append-buffer)
  (value text-buf-borrowed-chunk-string)
  (value text-buf-borrowed-chunks-render-rev)
  (value text-buf-borrowed-chunk-count)
  (value text-buf-borrowed-chunks-fill-array-rev)
  (value text-buf-borrowed-chunks-render-balanced)
  (value text-buf-borrowed-render)
  (type TextBufBorrowedChunk)
  (type TextBufBorrowedChunkList)
  (type TextBufBorrowed)
  (variant TextBufBorrowedChunkBorrowed)
  (variant TextBufBorrowedChunkOwned)
  (variant TextBufBorrowedChunkNil)
  (variant TextBufBorrowedChunkCons)
  (variant TextBufBorrowed))