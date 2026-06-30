;# Borrowed text buffer companion surface.
;#
;# `TextBufBorrowed` stores `(& text str)` chunks without copying at append
;# time, plus owned chunks for explicit copy boundaries. Rendering copies
;# borrowed chunks at the materialization boundary, then delegates final ordered
;# chunk rendering to `text_buf.tl`.
;#
;# This module intentionally remains separate from `text_buf.tl` while the
;# compatibility surface keeps owned chunk storage.
(module stdlib.text_buf_borrowed)

(import stdlib.text_buf)
(import stdlib.string)

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
(define (empty-like [_text : (& text str)]) : (TextBufBorrowed text)
  (TextBufBorrowed TextBufBorrowedChunkNil 0))

;: Return a borrowed buffer containing one borrowed chunk.
(define (single [text : (& text str)]) : (TextBufBorrowed text)
  (let
    [chunk-len : i64 (string-length text)]
    (TextBufBorrowed
      (TextBufBorrowedChunkCons
        (TextBufBorrowedChunkBorrowed text)
        (box TextBufBorrowedChunkNil))
      chunk-len)))

;: Return true when `buf` contains no bytes.
(define (empty? [buf : (TextBufBorrowed text)]) : bool
  (match buf
    [(TextBufBorrowed _ len) (= len 0)]))

;: Return the byte length currently represented by `buf`.
(define (length [buf : (TextBufBorrowed text)]) : i64
  (match buf
    [(TextBufBorrowed _ len) len]))

;: Append borrowed `text` to `buf` without copying bytes at append time.
(define (append [buf : (TextBufBorrowed text)] [text : (& text str)]) : (TextBufBorrowed
    text)
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
(define (append-owned [buf : (TextBufBorrowed text)] [chunk : String]) : (TextBufBorrowed
    text)
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
(define (append-copy [buf : (TextBufBorrowed text)] [chunk : (& chunk str)]) : (TextBufBorrowed
    text)
  (append-owned buf (string.substring chunk 0 (string-length chunk))))

;: Append rendered `right` after `left`. This is an explicit owned-copy
;: boundary, so `right` may be assembled independently before being appended.
(define (append-buffer
  [left : (TextBufBorrowed text)]
  [right : (TextBufBorrowed text)]) : (TextBufBorrowed text)
  (append-owned left (render right)))

;: Return `chunk` as owned active-arena text. Borrowed chunks are copied.
(define (chunk-string [chunk : (TextBufBorrowedChunk text)]) : String
  (match chunk
    [(TextBufBorrowedChunkBorrowed text)
      (string.substring text 0 (string-length text))]
    [(TextBufBorrowedChunkOwned text) text]))

;: Convert borrowed chunks to the owned chunk-list shape without changing the
;: reversed render order. Borrowed chunks copy here; owned chunks are reused.
(define (chunks-to-owned [chunks : (TextBufBorrowedChunkList text)]) : text_buf.TextBufChunkList
  (match chunks
    [(TextBufBorrowedChunkNil) text_buf.TextBufChunkNil]
    [(TextBufBorrowedChunkCons chunk rest)
      (text_buf.TextBufChunkCons
        (chunk-string chunk)
        (box (chunks-to-owned (box-get rest))))]))

;: Render borrowed `buf` to an owned String allocated in the active arena.
(define (render [buf : (TextBufBorrowed text)]) : String
  (match buf
    [(TextBufBorrowed chunks len)
      (text_buf.render-chunks (chunks-to-owned chunks) len)]))

;: Inline test helper that forces a borrowed text buffer test failure.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test helper that exercises borrowed text buffer rendering.
(define (test-render [text : String] [chunk : String]) : String
  (let
    [left : (TextBufBorrowed text) (append-owned (single (& text)) "-")]
    [right : (TextBufBorrowed text) (append (empty-like (& text)) (& text))]
    [joined : (TextBufBorrowed text) (append-buffer left right)]
    [copied : (TextBufBorrowed text) (append-copy joined (& chunk))]
    (render copied)))

(test
  text-buf-borrowed-api
  (let
    [text : String "alpha"]
    [chunk : String "tail"]
    [empty : (TextBufBorrowed text) (empty-like (& text))]
    [rendered : String (test-render text chunk)]
    (begin
      (if (empty? empty)
        unit
        (test-fail))
      (if (= (length empty) 0)
        unit
        (test-fail))
      (if (string.eq rendered "alpha-alphatail")
        unit
        (test-fail)))))