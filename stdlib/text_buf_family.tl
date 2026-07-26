;# Declaration generators for the owned and borrowed TextBuf families.
;#
;# `text_buf.tl` and `text_buf_borrowed.tl` preserve their public module names,
;# while this module owns the generated declaration bodies for both families.
;# The public modules import this file and splice the appropriate family through
;# `: Decls`, keeping the owned and borrowed surfaces generated from one source.
;: Emit the owned `TextBuf` family declarations for `stdlib.text_buf`.
(defmacro (owned) : Decls
  `(begin
    (defenum TextBufChunkList
      (TextBufChunkNil)
      (TextBufChunkCons String (Box TextBufChunkList)))
    (defstruct TextBuf
      (chunks TextBufChunkList)
      (len i64))
    (define text-buf-ascii-printable-table : String
      " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")
    (define (empty) : TextBuf
      (TextBuf TextBufChunkNil 0))
    (define (empty? [buf : TextBuf]) : bool
      (= (struct-get buf len) 0))
    (define (length [buf : TextBuf]) : i64
      (struct-get buf len))
    (define (chunk-cons [chunk : String] [rest : TextBufChunkList]) : TextBufChunkList
      (TextBufChunkCons chunk (box rest)))
    (define (append [buf : TextBuf] [chunk : String]) : TextBuf
      (let
        [chunk-len : i64 (string-length chunk)]
        (if (= chunk-len 0)
          buf
          (TextBuf
            (TextBufChunkCons chunk (box (struct-get buf chunks)))
            (+ (struct-get buf len) chunk-len)))))
    (define (char-string [c : char]) : String
      (let
        [code : i64 (cast c : i64)]
        (cond
          [(= code 9) "\t"]
          [(= code 10) "\n"]
          [(= code 13) "\r"]
          [(and (>= code 32) (<= code 126))
            (string.substring text-buf-ascii-printable-table (- code 32) 1)]
          [else (io.panic "text-buf: unsupported non-printable char")])))
    (define (append-char [buf : TextBuf] [c : char]) : TextBuf
      (stdlib.text_buf.append buf (stdlib.text_buf.char-string c)))
    (define (append-int [buf : TextBuf] [value : i64]) : TextBuf
      (stdlib.text_buf.append buf (string.int->string value)))
    (define (int-string [value : i64]) : String
      (string.int->string value))
    (define (chunk-list-concat
      [front : TextBufChunkList]
      [back : TextBufChunkList]) : TextBufChunkList
      (match front
        [(TextBufChunkNil) back]
        [(TextBufChunkCons chunk rest)
          (TextBufChunkCons
            chunk
            (box (stdlib.text_buf.chunk-list-concat (box-get rest) back)))]))
    (define (append-buffer [left : TextBuf] [right : TextBuf]) : TextBuf
      (let
        [left-len : i64 (struct-get left len)]
        [right-len : i64 (struct-get right len)]
        (if (= right-len 0)
          left
          (if (= left-len 0)
            right
            (TextBuf
              (stdlib.text_buf.chunk-list-concat
                (struct-get right chunks)
                (struct-get left chunks))
              (+ left-len right-len))))))
    (define (chunk-count [chunks : TextBufChunkList] [count : i64]) : i64
      (match chunks
        [(TextBufChunkNil) count]
        [(TextBufChunkCons _ rest)
          (stdlib.text_buf.chunk-count (box-get rest) (+ count 1))]))
    (define (chunks-fill-array-rev
      [chunks : TextBufChunkList]
      [items : (Array String)]
      [index : i64]) : unit
      (match chunks
        [(TextBufChunkNil) unit]
        [(TextBufChunkCons chunk rest)
          (begin
            (array-set! items index chunk)
            (stdlib.text_buf.chunks-fill-array-rev
              (box-get rest)
              items
              (- index 1)))]))
    (define (copy-chunk-into
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
        (begin
          (while (< w words)
            (begin
              (unsafe
                (ptr-write!
                  (ptr-offset dst64 w)
                  (ptr-read (ptr-offset src64 w))))
              (set! w (+ w 1))))
          (while (< b clen)
            (begin
              (unsafe
                (ptr-write!
                  (ptr-offset dst (+ start b))
                  (ptr-read (ptr-offset src b))))
              (set! b (+ b 1))))
          unit)))
    (define (chunks-render-array-range
      [items : (Array String)]
      [lo : i64]
      [hi : i64]) : String
      (if (>= lo hi)
        ""
        (let
          [index : i64 lo]
          [len : i64 0]
          (begin
            (while (< index hi)
              (begin
                (set! len (+ len (string-length (array-ref items index))))
                (set! index (+ index 1))))
            (if (= len 0)
              ""
              (let
                [out : (Array u8) (array.make-array u8 len)]
                [dst : (MutPtr u8)
                  (unsafe
                    (array-data out))]
                [copy-index : i64 lo]
                [pos : i64 0]
                (begin
                  (while (< copy-index hi)
                    (let
                      [chunk : String (array-ref items copy-index)]
                      [clen : i64 (string-length (& chunk))]
                      (begin
                        (stdlib.text_buf.copy-chunk-into (& chunk) dst pos)
                        (set! pos (+ pos clen))
                        (set! copy-index (+ copy-index 1)))))
                  (unsafe
                    (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))))))
    (define (chunks-render-rev [chunks : TextBufChunkList] [out : String]) : String
      (let
        [count : i64 (stdlib.text_buf.chunk-count chunks 0)]
        [items : (Array String) (array.make-array String (+ count 1))]
        (begin
          (stdlib.text_buf.chunks-fill-array-rev chunks items (- count 1))
          (array-set! items count out)
          (stdlib.text_buf.chunks-render-array-range items 0 (+ count 1)))))
    (define (chunks-render-balanced [chunks : TextBufChunkList] [count : i64]) : String
      (let
        [items : (Array String) (array.make-array String count)]
        (begin
          (stdlib.text_buf.chunks-fill-array-rev chunks items (- count 1))
          (stdlib.text_buf.chunks-render-array-range items 0 count))))
    (define (render-small-chunk-limit) : i64
      16)
    (define (fill-rev-into
      [chunks : TextBufChunkList]
      [dst : (MutPtr u8)]
      [pos : i64]) : unit
      (let
        [cursor : TextBufChunkList chunks]
        [out-pos : i64 pos]
        [done : bool false]
        [small-limit : i64 (stdlib.text_buf.render-small-chunk-limit)]
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
                                [small-len : i64
                                  (string-length (& small-chunk))]
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
                        (stdlib.text_buf.copy-chunk-into (& chunk) dst start)
                        (set! out-pos start)
                        (set! cursor (box-get rest))))))]))
          unit)))
    (define (render-chunks [chunks : TextBufChunkList] [len : i64]) : String
      (if (= len 0)
        ""
        (let
          [out : (Array u8) (array.make-array u8 len)]
          [dst : (MutPtr u8)
            (unsafe
              (array-data out))]
          (begin
            (stdlib.text_buf.fill-rev-into chunks dst len)
            (unsafe
              (string-from-bytes (ptr-cast dst : (Ptr u8)) len))))))
    (define (render [buf : TextBuf]) : String
      (stdlib.text_buf.render-chunks
        (struct-get buf chunks)
        (struct-get buf len)))
    (define (write-chunks-rev [raw : i64] [chunks : TextBufChunkList]) : i64
      (match chunks
        [(TextBufChunkNil) io.io-status-ok]
        [(TextBufChunkCons chunk rest)
          (let
            [status : i64 (stdlib.text_buf.write-chunks-rev raw (box-get rest))]
            (if (= status io.io-status-ok)
              (io.file-write-status raw chunk)
              status))]))
    (define (batched-write-threshold) : i64
      1048576)
    (define (write-array-batches
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
                    (stdlib.text_buf.chunks-render-array-range
                      items
                      start
                      index))))))
          status)))
    (define (write-chunks-batched [raw : i64] [chunks : TextBufChunkList]) : i64
      (let
        [count : i64 (stdlib.text_buf.chunk-count chunks 0)]
        [items : (Array String) (array.make-array String count)]
        (begin
          (stdlib.text_buf.chunks-fill-array-rev chunks items (- count 1))
          (stdlib.text_buf.write-array-batches
            raw
            items
            count
            (stdlib.text_buf.batched-write-threshold)))))
    (define (write-file [path : String] [buf : TextBuf]) : i64
      (let
        [chunks : TextBufChunkList (struct-get buf chunks)]
        [len : i64 (struct-get buf len)]
        [open-result : io.ResultIoFile
          (io.file-open (& path) (io.OpenWriteTruncate))]
        (if (io.result-file-ok? open-result)
          (let
            [handle : io.FileHandle
              (io.result-file-value-or open-result (io.FileHandle -1))]
            [write-status : i64
              (if (> len (stdlib.text_buf.batched-write-threshold))
                (stdlib.text_buf.write-chunks-batched
                  (struct-get handle id)
                  chunks)
                (stdlib.text_buf.write-chunks-rev (struct-get handle id) chunks))]
            [close-result : io.ResultIoUnit (io.file-close handle)]
            (if (io.result-unit-ok? close-result)
              write-status
              1))
          1)))
    (define (clear-ref! [buf : (&mut buf TextBuf)]) : unit
      (begin
        (set! (struct-get buf chunks) TextBufChunkNil)
        (set! (struct-get buf len) 0)))
    (define (clear [_buf : TextBuf]) : TextBuf
      (stdlib.text_buf.empty))
    (define (reset [buf : TextBuf]) : TextBuf
      (stdlib.text_buf.clear buf))))

;: Emit the borrowed `TextBufBorrowed` family declarations for
;: `stdlib.text_buf_borrowed`.
(defmacro (borrowed) : Decls
  `(begin
    (defenum TextBufBorrowedChunk
      (:lifetimes text)
      (TextBufBorrowedChunkBorrowed (& text str))
      (TextBufBorrowedChunkSlice (& text str) i64 i64)
      (TextBufBorrowedChunkChar char)
      (TextBufBorrowedChunkOwned String))
    (defenum TextBufBorrowedChunkList
      (:lifetimes text)
      (TextBufBorrowedChunkNil)
      (TextBufBorrowedChunkCons
        (TextBufBorrowedChunk text)
        (Box (TextBufBorrowedChunkList text))))
    (defenum TextBufBorrowed
      (:lifetimes text)
      (TextBufBorrowed (TextBufBorrowedChunkList text) i64))
    (define (empty-like [_text : (& text str)]) : (TextBufBorrowed text)
      (TextBufBorrowed TextBufBorrowedChunkNil 0))
    (define (single [text : (& text str)]) : (TextBufBorrowed text)
      (append (empty-like text) text))
    (define (empty? [buf : (TextBufBorrowed text)]) : bool
      (match buf
        [(TextBufBorrowed _ len) (= len 0)]))
    (define (length [buf : (TextBufBorrowed text)]) : i64
      (match buf
        [(TextBufBorrowed _ len) len]))
    (define (append [buf : (TextBufBorrowed text)] [text : (& text str)]) : (TextBufBorrowed
        text)
      (append-slice buf text 0 (string-length text)))
    (define (slice-valid? [text : (& text str)] [start : i64] [len : i64]) : bool
      (let
        [n : i64 (string-length text)]
        (and (>= start 0) (>= len 0) (<= start n) (<= len (- n start)))))
    (define (same-borrowed-source? [left : (& text str)] [right : (& text str)]) : bool
      (=
        (unsafe
          (ptr->int (string-data left)))
        (unsafe
          (ptr->int (string-data right)))))
    (define (append-slice-chunks
      [chunks : (TextBufBorrowedChunkList text)]
      [text : (& text str)]
      [start : i64]
      [len : i64]) : (TextBufBorrowedChunkList text)
      (match chunks
        [(TextBufBorrowedChunkCons chunk rest)
          (match chunk
            [(TextBufBorrowedChunkSlice prev-text prev-start prev-len)
              (if (and
                (same-borrowed-source? prev-text text)
                (= (+ prev-start prev-len) start))
                (TextBufBorrowedChunkCons
                  (TextBufBorrowedChunkSlice
                    prev-text
                    prev-start
                    (+ prev-len len))
                  rest)
                (TextBufBorrowedChunkCons
                  (TextBufBorrowedChunkSlice text start len)
                  (box chunks)))]
            [(TextBufBorrowedChunkBorrowed prev-text)
              (let
                [prev-len : i64 (string-length prev-text)]
                (if (and
                  (same-borrowed-source? prev-text text)
                  (= prev-len start))
                  (TextBufBorrowedChunkCons
                    (TextBufBorrowedChunkSlice prev-text 0 (+ prev-len len))
                    rest)
                  (TextBufBorrowedChunkCons
                    (TextBufBorrowedChunkSlice text start len)
                    (box chunks))))]
            [_
              (TextBufBorrowedChunkCons
                (TextBufBorrowedChunkSlice text start len)
                (box chunks))])]
        [(TextBufBorrowedChunkNil)
          (TextBufBorrowedChunkCons
            (TextBufBorrowedChunkSlice text start len)
            (box TextBufBorrowedChunkNil))]))
    (define (append-slice
      [buf : (TextBufBorrowed text)]
      [text : (& text str)]
      [start : i64]
      [len : i64]) : (TextBufBorrowed text)
      (if (not (slice-valid? text start len))
        (begin
          (io.panic "text-buf-borrowed: invalid slice")
          buf)
        (if (= len 0)
          buf
          (match buf
            [(TextBufBorrowed chunks total-len)
              (TextBufBorrowed
                (append-slice-chunks chunks text start len)
                (+ total-len len))]))))
    (define (append-char-supported? [c : char]) : bool
      (let
        [code : i64 (cast c : i64)]
        (or (= code 9) (= code 10) (= code 13) (and (>= code 32) (<= code 126)))))
    (define (append-char [buf : (TextBufBorrowed text)] [c : char]) : (TextBufBorrowed
        text)
      (if (not (append-char-supported? c))
        (begin
          (io.panic "text-buf-borrowed: unsupported non-printable char")
          buf)
        (match buf
          [(TextBufBorrowed chunks len)
            (TextBufBorrowed
              (TextBufBorrowedChunkCons
                (TextBufBorrowedChunkChar c)
                (box chunks))
              (+ len 1))])))
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
    (define (append-copy [buf : (TextBufBorrowed text)] [chunk : (& chunk str)]) : (TextBufBorrowed
        text)
      (append-owned buf (string.substring chunk 0 (string-length chunk))))
    (define (append-buffer
      [left : (TextBufBorrowed text)]
      [right : (TextBufBorrowed text)]) : (TextBufBorrowed text)
      (append-owned left (render right)))
    (define (chunk-string [chunk : (TextBufBorrowedChunk text)]) : String
      (match chunk
        [(TextBufBorrowedChunkBorrowed text)
          (string.substring text 0 (string-length text))]
        [(TextBufBorrowedChunkSlice text start len)
          (string.substring text start len)]
        [(TextBufBorrowedChunkChar c) (text_buf.char-string c)]
        [(TextBufBorrowedChunkOwned text) text]))
    (define (chunks-to-owned [chunks : (TextBufBorrowedChunkList text)]) : text_buf.TextBufChunkList
      (match chunks
        [(TextBufBorrowedChunkNil) text_buf.TextBufChunkNil]
        [(TextBufBorrowedChunkCons chunk rest)
          (text_buf.TextBufChunkCons
            (chunk-string chunk)
            (box (chunks-to-owned (box-get rest))))]))
    (define (chunk-length [chunk : (TextBufBorrowedChunk text)]) : i64
      (match chunk
        [(TextBufBorrowedChunkBorrowed text) (string-length text)]
        [(TextBufBorrowedChunkSlice _ _ len) len]
        [(TextBufBorrowedChunkChar _) 1]
        [(TextBufBorrowedChunkOwned text) (string-length text)]))
    (define (chunks-count
      [chunks : (TextBufBorrowedChunkList text)]
      [count : i64]) : i64
      (match chunks
        [(TextBufBorrowedChunkNil) count]
        [(TextBufBorrowedChunkCons _ rest)
          (chunks-count (box-get rest) (+ count 1))]))
    (define (chunk-count [buf : (TextBufBorrowed text)]) : i64
      (match buf
        [(TextBufBorrowed chunks _) (chunks-count chunks 0)]))
    (define (copy-byte-range-into
      [src : (Ptr u8)]
      [src-start : i64]
      [clen : i64]
      [dst : (MutPtr u8)]
      [dst-start : i64]) : unit
      (let
        [base : (Ptr u8)
          (unsafe
            (ptr-offset src src-start))]
        [words : i64 (/ clen 8)]
        [src64 : (Ptr i64)
          (unsafe
            (ptr-cast base : (Ptr i64)))]
        [dst64 : (MutPtr i64)
          (unsafe
            (ptr-cast (ptr-offset dst dst-start) : (MutPtr i64)))]
        [w : i64 0]
        [b : i64 (* words 8)]
        (begin
          (while (< w words)
            (begin
              (unsafe
                (ptr-write!
                  (ptr-offset dst64 w)
                  (ptr-read (ptr-offset src64 w))))
              (set! w (+ w 1))))
          (while (< b clen)
            (begin
              (unsafe
                (ptr-write!
                  (ptr-offset dst (+ dst-start b))
                  (ptr-read (ptr-offset base b))))
              (set! b (+ b 1))))
          unit)))
    (define (copy-chunk-into
      [chunk : (TextBufBorrowedChunk text)]
      [dst : (MutPtr u8)]
      [start : i64]) : unit
      (match chunk
        [(TextBufBorrowedChunkBorrowed text)
          (copy-byte-range-into
            (unsafe
              (string-data text))
            0
            (string-length text)
            dst
            start)]
        [(TextBufBorrowedChunkSlice text slice-start len)
          (copy-byte-range-into
            (unsafe
              (string-data text))
            slice-start
            len
            dst
            start)]
        [(TextBufBorrowedChunkChar c)
          (unsafe
            (ptr-write! (ptr-offset dst start) (cast c : u8)))]
        [(TextBufBorrowedChunkOwned text)
          (copy-byte-range-into
            (unsafe
              (string-data (& text)))
            0
            (string-length text)
            dst
            start)]))
    (define (fill-rev-into
      [chunks : (TextBufBorrowedChunkList text)]
      [dst : (MutPtr u8)]
      [pos : i64]) : unit
      (match chunks
        [(TextBufBorrowedChunkNil) unit]
        [(TextBufBorrowedChunkCons chunk rest)
          (let
            [clen : i64 (chunk-length chunk)]
            [start : i64 (- pos clen)]
            (begin
              (copy-chunk-into chunk dst start)
              (fill-rev-into (box-get rest) dst start)))]))
    (define (render [buf : (TextBufBorrowed text)]) : String
      (match buf
        [(TextBufBorrowed chunks len)
          (if (= len 0)
            ""
            (let
              [out : (Array u8) (array.make-array u8 len)]
              [dst : (MutPtr u8)
                (unsafe
                  (array-data out))]
              (begin
                (fill-rev-into chunks dst len)
                (unsafe
                  (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))]))))