;# Declaration generators for the owned and borrowed TextBuf families.
;#
;# The two public families are emitted as one declaration splice each.  Owned
;# chunks use a typed chronological String store; borrowed chunks retain the
;# same dense committed prefix and one value-local String tail plus merge flag.
(import stdlib.comptime)

(unsafe
  (extern (text-buf-family-copy-bytes!
    [dst : (MutPtr u8)]
    [src : (Ptr u8)]
    [n : i64]) : unit (:symbol "tl_memcpy")))

;: Resolve an arena handle to the owner-root handle stored in its header,
;: preserving zero for the null handle.
(define (text-buf-family-arena-owner-root [handle : i64]) : i64
  (if (= handle 0)
    0
    (let
      [root : i64
        (unsafe
          (ptr-read (ptr-offset (int->ptr handle : (Ptr i64)) 5)))]
      (if (= root 0)
        handle
        root))))

;: Return the in-memory byte stride of String slots used by generated stores.
(define (text-buf-family-string-stride) : i64
  (comptime (size-of (type String))))

;: Write one typed owned String slot.  This expression macro keeps the hot
;: commit path on a direct unsafe array write without introducing a generated
;: runtime helper.
(defmacro (text-buf-owned-store-write!
  [store : comptime.Expr]
  [index : comptime.Expr]
  [entry : comptime.Expr]) : unit
  `(unsafe
    (ptr-write!
      (ptr-offset
        (ptr-cast
          (array-data (struct-get (box-get ,store) slots))
          : (MutPtr String))
        ,index)
      ,entry)))

;: Inline only the same-head owned-prefix commit fast path at each chunk-cons
;: call site.  All other ownership/COW recovery and allocation decisions stay
;: in the generated cold helper below.
(defmacro (text-buf-owned-store-commit!
  [store : comptime.Expr]
  [visible-count : comptime.Expr]
  [entry : comptime.Expr]) : comptime.Expr
  `(let
    [capacity : i64
      (stdlib.text_buf.text-buf-store-capacity (& (box-get ,store)))]
    [current-head : i64 (tls-current-arena)]
    [prefix-available? : bool
      (and
        (= ,visible-count (struct-get (box-get ,store) len))
        (< ,visible-count capacity))]
    (if (and
      prefix-available?
      (not (= current-head 0))
      (= current-head (struct-get (box-get ,store) owner-head)))
      (begin
        (stdlib.text_buf_family.text-buf-owned-store-write!
          ,store
          ,visible-count
          ,entry)
        (set! (struct-get (box-get ,store) len) (+ ,visible-count 1))
        ,store)
      (stdlib.text_buf.text-buf-store-commit-slow
        ,store
        ,visible-count
        ,entry
        capacity
        current-head
        prefix-available?))))

;: Emit the complete owned TextBuf family.
(defmacro (owned) : Decls
  `(begin
    (defstruct TextBufStringStore
      (slots (Array String))
      (len i64)
      (owner-root i64)
      (owner-head i64))
    (defenum TextBufChunkList
      (TextBufChunkNil)
      (TextBufChunkInline String)
      (TextBufChunkDense (Box TextBufStringStore) i64))
    (defstruct TextBuf
      (chunks TextBufChunkList)
      (len i64))
    (define text-buf-ascii-printable-table : String
      " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")
    (define (text-buf-store-string-stride) : i64
      (stdlib.text_buf_family.text-buf-family-string-stride))
    (define (text-buf-store-new) : (Box TextBufStringStore)
      (let
        [store : (Box TextBufStringStore)
          (box (TextBufStringStore (make-array String 32) 0 0 0))]
        [current-head : i64 (tls-current-arena)]
        [current-owner-root : i64
          (stdlib.text_buf_family.text-buf-family-arena-owner-root current-head)]
        (begin
          (set! (struct-get (box-get store) owner-root) current-owner-root)
          (set! (struct-get (box-get store) owner-head) current-head)
          store)))
    (define (text-buf-store-capacity [store : (& store TextBufStringStore)]) : i64
      (array-length (struct-get store slots)))
    (define (text-buf-store-entry-at
      [store : (& store TextBufStringStore)]
      [index : i64]) : String
      (unsafe
        (ptr-read
          (ptr-cast
            (ptr-offset
              (ptr-cast (array-data (struct-get store slots)) : (Ptr String))
              index)
            : (Ptr String)))))
    ;: Allocation, growth, and prefix memcpy are cold.  The same-head commit
    ;: macro above keeps the common direct-write case inline; the generated
    ;: slow helper below reaches this routine only after that check fails.
    (define (text-buf-store-copy-and-commit
      [store : (Box TextBufStringStore)]
      [visible-count : i64]
      [entry : String]
      [capacity : i64]
      [current-owner-root : i64]
      [current-head : i64]) : (Box TextBufStringStore)
      (let
        [new-capacity : i64
          (if (< visible-count capacity)
            (if (< capacity 1)
              1
              capacity)
            (let
              [doubled : i64
                (if (< capacity 1)
                  1
                  (* capacity 2))]
              (if (< doubled (+ visible-count 1))
                (+ visible-count 1)
                doubled)))]
        [new-store : (Box TextBufStringStore)
          (box
            (TextBufStringStore
              (make-array String new-capacity)
              (+ visible-count 1)
              current-owner-root
              current-head))]
        (begin
          (unsafe
            (stdlib.text_buf_family.text-buf-family-copy-bytes!
              (ptr-cast
                (array-data (struct-get (box-get new-store) slots))
                : (MutPtr u8))
              (ptr-cast
                (array-data (struct-get (box-get store) slots))
                : (Ptr u8))
              (* visible-count (stdlib.text_buf.text-buf-store-string-stride))))
          (stdlib.text_buf_family.text-buf-owned-store-write!
            new-store
            visible-count
            entry)
          new-store)))
    ;: Recover same-owner-root prefix reuse on the cold path, then delegate
    ;: capacity growth and prefix copying to text-buf-store-copy-and-commit.
    (define (text-buf-store-commit-slow
      [store : (Box TextBufStringStore)]
      [visible-count : i64]
      [entry : String]
      [capacity : i64]
      [current-head : i64]
      [prefix-available? : bool]) : (Box TextBufStringStore)
      (let
        [current-owner-root : i64
          (stdlib.text_buf_family.text-buf-family-arena-owner-root current-head)]
        (if (and
          prefix-available?
          (not (= current-head 0))
          (not (= current-owner-root 0))
          (= current-owner-root (struct-get (box-get store) owner-root)))
          (begin
            (set! (struct-get (box-get store) owner-head) current-head)
            (stdlib.text_buf_family.text-buf-owned-store-write!
              store
              visible-count
              entry)
            (set! (struct-get (box-get store) len) (+ visible-count 1))
            store)
          (stdlib.text_buf.text-buf-store-copy-and-commit
            store
            visible-count
            entry
            capacity
            current-owner-root
            current-head))))
    (define (text-buf-empty-chunks) : TextBufChunkList
      (TextBufChunkNil))
    (define (empty) : TextBuf
      (TextBuf (stdlib.text_buf.text-buf-empty-chunks) 0))
    (define (empty? [buf : TextBuf]) : bool
      (= (struct-get buf len) 0))
    (define (length [buf : TextBuf]) : i64
      (struct-get buf len))
    (define (chunk-cons [chunk : String] [rest : TextBufChunkList]) : TextBufChunkList
      (match rest
        [(TextBufChunkNil) (TextBufChunkInline chunk)]
        [(TextBufChunkInline old)
          (let
            [store : (Box TextBufStringStore)
              (stdlib.text_buf.text-buf-store-new)]
            [with-old : (Box TextBufStringStore)
              (stdlib.text_buf_family.text-buf-owned-store-commit! store 0 old)]
            [with-new : (Box TextBufStringStore)
              (stdlib.text_buf_family.text-buf-owned-store-commit!
                with-old
                1
                chunk)]
            (TextBufChunkDense with-new 2))]
        [(TextBufChunkDense store old-count)
          (TextBufChunkDense
            (stdlib.text_buf_family.text-buf-owned-store-commit!
              store
              old-count
              chunk)
            (+ old-count 1))]))
    (define (append [buf : TextBuf] [chunk : String]) : TextBuf
      (let
        [chunk-len : i64 (string-length chunk)]
        (if (= chunk-len 0)
          buf
          (TextBuf
            (stdlib.text_buf.chunk-cons chunk (struct-get buf chunks))
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
      (let
        [front-count : i64 (stdlib.text_buf.chunk-count front 0)]
        [items : (Array String) (make-array String front-count)]
        [result : TextBufChunkList back]
        [index : i64 0]
        (begin
          (stdlib.text_buf.chunks-fill-array-rev front items (- front-count 1))
          (while (< index front-count)
            (begin
              (set!
                result
                (stdlib.text_buf.chunk-cons (array-ref items index) result))
              (set! index (+ index 1))))
          result)))
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
        [(TextBufChunkInline _) (+ count 1)]
        [(TextBufChunkDense _ visible-count) (+ count visible-count)]))
    (define (chunks-fill-array-rev
      [chunks : TextBufChunkList]
      [items : (Array String)]
      [index : i64]) : unit
      (match chunks
        [(TextBufChunkNil) unit]
        [(TextBufChunkInline chunk)
          (if (>= index 0)
            (array-set! items index chunk)
            unit)]
        [(TextBufChunkDense store visible-count)
          (let
            [cursor : i64 (- visible-count 1)]
            [out-index : i64 index]
            (while (and (>= cursor 0) (>= out-index 0))
              (let
                [chunk : String
                  (stdlib.text_buf.text-buf-store-entry-at
                    (& (box-get store))
                    cursor)]
                (begin
                  (array-set! items out-index chunk)
                  (set! out-index (- out-index 1))
                  (set! cursor (- cursor 1))))))]))
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
          [total : i64 0]
          (begin
            (while (< index hi)
              (begin
                (set! total (+ total (string-length (array-ref items index))))
                (set! index (+ index 1))))
            (if (= total 0)
              ""
              (let
                [out : (Array u8) (make-array u8 total)]
                [dst : (MutPtr u8)
                  (unsafe
                    (array-data out))]
                [cursor : i64 lo]
                [pos : i64 0]
                (begin
                  (while (< cursor hi)
                    (let
                      [chunk : String (array-ref items cursor)]
                      [chunk-len : i64 (string-length (& chunk))]
                      (begin
                        (stdlib.text_buf.copy-chunk-into (& chunk) dst pos)
                        (set! pos (+ pos chunk-len))
                        (set! cursor (+ cursor 1)))))
                  (unsafe
                    (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))))))
    (define (render-small-chunk-limit) : i64
      16)
    (define (fill-rev-into
      [chunks : TextBufChunkList]
      [dst : (MutPtr u8)]
      [pos : i64]) : unit
      (let
        [small-limit : i64 (stdlib.text_buf.render-small-chunk-limit)]
        (match chunks
          [(TextBufChunkNil) unit]
          [(TextBufChunkInline chunk)
            (let
              [clen : i64 (string-length (& chunk))]
              [start : i64 (- pos clen)]
              (if (<= clen small-limit)
                (let
                  [src : (Ptr u8)
                    (unsafe
                      (string-data (& chunk)))]
                  [index : i64 0]
                  (begin
                    (while (< index clen)
                      (begin
                        (unsafe
                          (ptr-write!
                            (ptr-offset dst (+ start index))
                            (ptr-read (ptr-offset src index))))
                        (set! index (+ index 1))))
                    unit))
                (stdlib.text_buf.copy-chunk-into (& chunk) dst start)))]
          [(TextBufChunkDense store visible-count)
            (let
              [cursor : i64 (- visible-count 1)]
              [out-pos : i64 pos]
              [byte-index : i64 0]
              (begin
                (while (>= cursor 0)
                  (let
                    [chunk : String
                      (stdlib.text_buf.text-buf-store-entry-at
                        (& (box-get store))
                        cursor)]
                    [clen : i64 (string-length (& chunk))]
                    [start : i64 (- out-pos clen)]
                    (begin
                      (if (<= clen small-limit)
                        (let
                          [src : (Ptr u8)
                            (unsafe
                              (string-data (& chunk)))]
                          (begin
                            (set! byte-index 0)
                            (while (< byte-index clen)
                              (begin
                                (unsafe
                                  (ptr-write!
                                    (ptr-offset dst (+ start byte-index))
                                    (ptr-read (ptr-offset src byte-index))))
                                (set! byte-index (+ byte-index 1))))
                            unit))
                        (stdlib.text_buf.copy-chunk-into (& chunk) dst start))
                      (set! out-pos start)
                      (set! cursor (- cursor 1)))))
                unit))])))
    (define (render-chunks [chunks : TextBufChunkList] [total : i64]) : String
      (if (= total 0)
        ""
        (let
          [out : (Array u8) (make-array u8 total)]
          [dst : (MutPtr u8)
            (unsafe
              (array-data out))]
          (begin
            (stdlib.text_buf.fill-rev-into chunks dst total)
            (unsafe
              (string-from-bytes (ptr-cast dst : (Ptr u8)) total))))))
    (define (render [buf : TextBuf]) : String
      (stdlib.text_buf.render-chunks
        (struct-get buf chunks)
        (struct-get buf len)))
    (define (write-chunks-rev
      [raw : i64]
      [write-chunks-list : TextBufChunkList]) : i64
      (let
        [count : i64 (stdlib.text_buf.chunk-count write-chunks-list 0)]
        [items : (Array String) (make-array String count)]
        [index : i64 0]
        [status : i64 io.io-status-ok]
        (begin
          (stdlib.text_buf.chunks-fill-array-rev
            write-chunks-list
            items
            (- count 1))
          (while (and (< index count) (= status io.io-status-ok))
            (let
              [chunk : String (array-ref items index)]
              (begin
                (set!
                  status
                  (io.file-write-status raw (byte_buf.str-as-bytes (& chunk))))
                (set! index (+ index 1)))))
          status)))
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
                (let
                  [rendered : String
                    (stdlib.text_buf.chunks-render-array-range
                      items
                      start
                      index)]
                  (set!
                    status
                    (io.file-write-status
                      raw
                      (byte_buf.str-as-bytes (& rendered))))))))
          status)))
    (define (write-chunks-batched
      [raw : i64]
      [write-chunks-list : TextBufChunkList]) : i64
      (let
        [count : i64 (stdlib.text_buf.chunk-count write-chunks-list 0)]
        [items : (Array String) (make-array String count)]
        (begin
          (stdlib.text_buf.chunks-fill-array-rev
            write-chunks-list
            items
            (- count 1))
          (stdlib.text_buf.write-array-batches
            raw
            items
            count
            (stdlib.text_buf.batched-write-threshold)))))
    (define (write-file [path : String] [buf : TextBuf]) : i64
      (let
        [open-result : io.ResultIoFile
          (io.file-open (& path) (io.OpenWriteTruncate))]
        (if (io.result-file-ok? open-result)
          (let
            [handle : io.FileHandle
              (io.result-file-value-or open-result (io.FileHandle -1))]
            [chunks : TextBufChunkList (struct-get buf chunks)]
            [status : i64
              (if (>
                (struct-get buf len)
                (stdlib.text_buf.batched-write-threshold))
                (stdlib.text_buf.write-chunks-batched
                  (struct-get handle id)
                  chunks)
                (stdlib.text_buf.write-chunks-rev (struct-get handle id) chunks))]
            [close-result : io.ResultIoUnit (io.file-close handle)]
            (if (io.result-unit-ok? close-result)
              status
              1))
          1)))
    (define (clear-ref! [buf : (&mut buf TextBuf)]) : unit
      (begin
        (set! (struct-get buf chunks) (TextBufChunkNil))
        (set! (struct-get buf len) 0)))
    (define (clear [_buf : TextBuf]) : TextBuf
      (stdlib.text_buf.empty))
    (define (reset [buf : TextBuf]) : TextBuf
      (stdlib.text_buf.clear buf))))

;: Emit the complete borrowed TextBuf family.
(defmacro (borrowed) : Decls
  `(begin
    (defenum TextBufBorrowedChunk
      (:lifetimes text)
      (TextBufBorrowedChunkBorrowed (& text str))
      (TextBufBorrowedChunkSlice (& text str) i64 i64)
      (TextBufBorrowedChunkChar char)
      (TextBufBorrowedChunkOwned String))
    ;: Every value-local tail is a declared String field.  The bool records
    ;: whether that String is a borrowed view eligible for adjacent merging;
    ;: the surrounding anchor keeps the view's source lifetime live.
    (defenum TextBufBorrowedChunkList
      (:lifetimes text)
      (TextBufBorrowedChunkNil (& text str))
      (TextBufBorrowedChunkInline (& text str) String bool)
      (TextBufBorrowedChunkDense
        (& text str)
        text_buf.TextBufChunkList
        i64
        String
        bool))
    (defenum TextBufBorrowed
      (:lifetimes text)
      (TextBufBorrowed (TextBufBorrowedChunkList text) i64))
    ;: Construct a String header over borrowed bytes.  This helper is unsafe
    ;: by design: the enclosing chunk list retains the lifetime anchor, and no
    ;: safe API exposes the returned view without that anchor.
    (define (text-buf-borrowed-view
      [text : (& text str)]
      [start : i64]
      [len : i64]) : String
      (let
        [data : (Ptr u8)
          (unsafe
            (ptr-offset (string-data text) start))]
        (unsafe
          (string-from-bytes data len))))
    (define (text-buf-borrowed-empty-owned-chunks) : text_buf.TextBufChunkList
      (struct-get (text_buf.empty) chunks))
    (define (text-buf-borrowed-empty-chunks [_text : (& text str)]) : (TextBufBorrowedChunkList
        text)
      (TextBufBorrowedChunkNil _text))
    (define (empty-like [_text : (& text str)]) : (TextBufBorrowed text)
      (TextBufBorrowed
        (stdlib.text_buf_borrowed.text-buf-borrowed-empty-chunks _text)
        0))
    (define (single [text : (& text str)]) : (TextBufBorrowed text)
      (append (empty-like text) text))
    (define (empty? [buf : (TextBufBorrowed text)]) : bool
      (match buf
        [(TextBufBorrowed _ len) (= len 0)]))
    (define (length [buf : (TextBufBorrowed text)]) : i64
      (match buf
        [(TextBufBorrowed _ len) len]))
    (define (slice-valid? [source : (& text str)] [start : i64] [len : i64]) : bool
      (let
        [n : i64 (string-length source)]
        (and (>= start 0) (>= len 0) (<= start n) (<= len (- n start)))))
    ;: Rare scalar-tail paths share this helper.  The dense-prefix case uses
    ;: the same direct owned-store commit as the hot paths below; Nil/Inline
    ;: and non-dense prefixes retain the general chunk-cons fallback.
    (define (text-buf-borrowed-append-tail
      [chunks : (TextBufBorrowedChunkList text)]
      [new-tail-text : String]
      [new-tail-borrowed? : bool]) : (TextBufBorrowedChunkList text)
      (match chunks
        [(TextBufBorrowedChunkNil anchor)
          (TextBufBorrowedChunkInline anchor new-tail-text new-tail-borrowed?)]
        [(TextBufBorrowedChunkInline anchor old-tail-text _old-tail-borrowed?)
          (TextBufBorrowedChunkDense
            anchor
            (text_buf.chunk-cons
              old-tail-text
              (struct-get (text_buf.empty) chunks))
            1
            new-tail-text
            new-tail-borrowed?)]
        [(TextBufBorrowedChunkDense
            anchor
            prefix
            prefix-count
            old-tail-text
            _old-tail-borrowed?)
          (let
            [next-prefix : text_buf.TextBufChunkList
              (match prefix
                [(text_buf.TextBufChunkDense store visible-count)
                  (text_buf.TextBufChunkDense
                    (text_buf_family.text-buf-owned-store-commit!
                      store
                      visible-count
                      old-tail-text)
                    (+ visible-count 1))]
                [_ (text_buf.chunk-cons old-tail-text prefix)])]
            (TextBufBorrowedChunkDense
              anchor
              next-prefix
              (+ prefix-count 1)
              new-tail-text
              new-tail-borrowed?))]))
    (define (append-slice-chunks
      [chunks : (TextBufBorrowedChunkList text)]
      [text : (& text str)]
      [start : i64]
      [len : i64]) : (TextBufBorrowedChunkList text)
      (let
        [new-data : i64
          (cast
            (unsafe
              (ptr->int (ptr-offset (string-data text) start)))
            : i64)]
        (match chunks
          [(TextBufBorrowedChunkNil anchor)
            (TextBufBorrowedChunkInline
              anchor
              (stdlib.text_buf_borrowed.text-buf-borrowed-view text start len)
              true)]
          [(TextBufBorrowedChunkInline anchor old-tail old-borrowed?)
            (if (and
              old-borrowed?
              (=
                (+
                  (cast
                    (unsafe
                      (ptr->int (string-data (& old-tail))))
                    : i64)
                  (string-length (& old-tail)))
                new-data))
              (TextBufBorrowedChunkInline
                anchor
                (unsafe
                  (string-from-bytes
                    (string-data (& old-tail))
                    (+ (string-length (& old-tail)) len)))
                true)
              (TextBufBorrowedChunkDense
                anchor
                (text_buf.chunk-cons
                  old-tail
                  (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks))
                1
                (stdlib.text_buf_borrowed.text-buf-borrowed-view text start len)
                true))]
          [(TextBufBorrowedChunkDense
              anchor
              prefix
              prefix-count
              old-tail
              old-borrowed?)
            (if (and
              old-borrowed?
              (=
                (+
                  (cast
                    (unsafe
                      (ptr->int (string-data (& old-tail))))
                    : i64)
                  (string-length (& old-tail)))
                new-data))
              (TextBufBorrowedChunkDense
                anchor
                prefix
                prefix-count
                (unsafe
                  (string-from-bytes
                    (string-data (& old-tail))
                    (+ (string-length (& old-tail)) len)))
                true)
              (let
                [next-prefix : text_buf.TextBufChunkList
                  (match prefix
                    [(text_buf.TextBufChunkDense store visible-count)
                      (text_buf.TextBufChunkDense
                        (text_buf_family.text-buf-owned-store-commit!
                          store
                          visible-count
                          old-tail)
                        (+ visible-count 1))]
                    [_ (text_buf.chunk-cons old-tail prefix)])]
                (TextBufBorrowedChunkDense
                  anchor
                  next-prefix
                  (+ prefix-count 1)
                  (stdlib.text_buf_borrowed.text-buf-borrowed-view
                    text
                    start
                    len)
                  true)))])))
    ;: Unsafe validated-range fast path.  Callers must prove
    ;: 0 <= start, 0 <= len, and start + len <= string-length(text).
    (unsafe
      (define (append-slice-unchecked
        [buf : (TextBufBorrowed text)]
        [text : (& text str)]
        [start : i64]
        [len : i64]) : (TextBufBorrowed text)
        (match buf
          [(TextBufBorrowed chunks total-len)
            (TextBufBorrowed
              (stdlib.text_buf_borrowed.append-slice-chunks
                chunks
                text
                start
                len)
              (+ total-len len))])))
    (define (append-slice
      [buf : (TextBufBorrowed text)]
      [text : (& text str)]
      [start : i64]
      [len : i64]) : (TextBufBorrowed text)
      (if (not (stdlib.text_buf_borrowed.slice-valid? text start len))
        (begin
          (io.panic "text-buf-borrowed: invalid slice")
          buf)
        (if (= len 0)
          buf
          (unsafe
            (stdlib.text_buf_borrowed.append-slice-unchecked buf text start len)))))
    (define (append [buf : (TextBufBorrowed text)] [text : (& text str)]) : (TextBufBorrowed
        text)
      (let
        [n : i64 (string-length text)]
        (if (= n 0)
          buf
          (unsafe
            (stdlib.text_buf_borrowed.append-slice-unchecked buf text 0 n)))))
    (define (append-char-supported? [c : char]) : bool
      (let
        [code : i64 (cast c : i64)]
        (or (= code 9) (= code 10) (= code 13) (and (>= code 32) (<= code 126)))))
    (define (append-char [buf : (TextBufBorrowed text)] [c : char]) : (TextBufBorrowed
        text)
      (if (not (stdlib.text_buf_borrowed.append-char-supported? c))
        (begin
          (io.panic "text-buf-borrowed: unsupported non-printable char")
          buf)
        (match buf
          [(TextBufBorrowed chunks len)
            (TextBufBorrowed
              (stdlib.text_buf_borrowed.text-buf-borrowed-append-tail
                chunks
                (text_buf.char-string c)
                false)
              (+ len 1))])))
    (define (append-owned [buf : (TextBufBorrowed text)] [chunk : String]) : (TextBufBorrowed
        text)
      (let
        [chunk-len : i64 (string-length chunk)]
        (match buf
          [(TextBufBorrowed chunks len)
            (let
              [next-chunks : (TextBufBorrowedChunkList text)
                (match chunks
                  [(TextBufBorrowedChunkNil anchor)
                    (TextBufBorrowedChunkInline anchor chunk false)]
                  [(TextBufBorrowedChunkInline
                      anchor
                      old-tail
                      _old-tail-borrowed?)
                    (TextBufBorrowedChunkDense
                      anchor
                      (text_buf.chunk-cons
                        old-tail
                        (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks))
                      1
                      chunk
                      false)]
                  [(TextBufBorrowedChunkDense
                      anchor
                      prefix
                      prefix-count
                      old-tail
                      _old-tail-borrowed?)
                    (let
                      [next-prefix : text_buf.TextBufChunkList
                        (match prefix
                          [(text_buf.TextBufChunkDense store visible-count)
                            (text_buf.TextBufChunkDense
                              (text_buf_family.text-buf-owned-store-commit!
                                store
                                visible-count
                                old-tail)
                              (+ visible-count 1))]
                          [_ (text_buf.chunk-cons old-tail prefix)])]
                      (TextBufBorrowedChunkDense
                        anchor
                        next-prefix
                        (+ prefix-count 1)
                        chunk
                        false))])]
              (TextBufBorrowed next-chunks (+ len chunk-len)))])))
    (define (append-copy [buf : (TextBufBorrowed text)] [chunk : (& chunk str)]) : (TextBufBorrowed
        text)
      (append-owned buf (string.substring chunk 0 (string-length chunk))))
    ;: Replay a dense right-hand prefix one chunk at a time.  Prefix entries
    ;: are String headers replayed without byte copies.  Only the value-local
    ;: tail carries its borrowed-view merge flag; chunks-to-owned is the actual
    ;: copy boundary.
    (define (text-buf-borrowed-append-buffer-dense
      [left : (TextBufBorrowedChunkList text)]
      [prefix : text_buf.TextBufChunkList]
      [tail-text : String]
      [tail-borrowed? : bool]) : (TextBufBorrowedChunkList text)
      (let
        [count : i64 (text_buf.chunk-count prefix 0)]
        [items : (Array String) (make-array String count)]
        [result : (TextBufBorrowedChunkList text) left]
        [index : i64 0]
        (begin
          (text_buf.chunks-fill-array-rev prefix items (- count 1))
          (while (< index count)
            (begin
              (set!
                result
                (stdlib.text_buf_borrowed.text-buf-borrowed-append-tail
                  result
                  (array-ref items index)
                  false))
              (set! index (+ index 1))))
          (stdlib.text_buf_borrowed.text-buf-borrowed-append-tail
            result
            tail-text
            tail-borrowed?))))
    (define (append-buffer
      [left : (TextBufBorrowed text)]
      [right : (TextBufBorrowed text)]) : (TextBufBorrowed text)
      (match left
        [(TextBufBorrowed left-chunks left-len)
          (match right
            [(TextBufBorrowed right-chunks right-len)
              (let
                [next-chunks : (TextBufBorrowedChunkList text)
                  (match right-chunks
                    [(TextBufBorrowedChunkNil _) left-chunks]
                    [(TextBufBorrowedChunkInline _ right-tail right-borrowed?)
                      (stdlib.text_buf_borrowed.text-buf-borrowed-append-tail
                        left-chunks
                        right-tail
                        right-borrowed?)]
                    [(TextBufBorrowedChunkDense
                        _
                        right-prefix
                        _
                        right-tail
                        right-borrowed?)
                      (stdlib.text_buf_borrowed.text-buf-borrowed-append-buffer-dense
                        left-chunks
                        right-prefix
                        right-tail
                        right-borrowed?)])]
                (TextBufBorrowed next-chunks (+ left-len right-len)))])]))
    (define (chunk-string [chunk : (TextBufBorrowedChunk text)]) : String
      (match chunk
        [(TextBufBorrowedChunkBorrowed text)
          (string.substring text 0 (string-length text))]
        [(TextBufBorrowedChunkSlice text start len)
          (string.substring text start len)]
        [(TextBufBorrowedChunkChar c) (text_buf.char-string c)]
        [(TextBufBorrowedChunkOwned text) text]))
    (define (chunk-length [chunk : (TextBufBorrowedChunk text)]) : i64
      (match chunk
        [(TextBufBorrowedChunkBorrowed text) (string-length text)]
        [(TextBufBorrowedChunkSlice _ _ len) len]
        [(TextBufBorrowedChunkChar _) 1]
        [(TextBufBorrowedChunkOwned text) (string-length text)]))
    ;: Kept for compiler_backend.tl's byte-copy helper call site.
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
    (define (text-buf-borrowed-copy-string [text : String]) : String
      (string.substring (& text) 0 (string-length text)))
    (define (text-buf-borrowed-copy-prefix [prefix : text_buf.TextBufChunkList]) : text_buf.TextBufChunkList
      (let
        [count : i64 (text_buf.chunk-count prefix 0)]
        [items : (Array String) (make-array String count)]
        [owned : text_buf.TextBufChunkList
          (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks)]
        [index : i64 0]
        (begin
          (text_buf.chunks-fill-array-rev prefix items (- count 1))
          (while (< index count)
            (let
              [entry : String (array-ref items index)]
              (begin
                (set!
                  owned
                  (text_buf.chunk-cons
                    (stdlib.text_buf_borrowed.text-buf-borrowed-copy-string
                      entry)
                    owned))
                (set! index (+ index 1)))))
          owned)))
    (define (text-buf-borrowed-render-chunks
      [chunks : (TextBufBorrowedChunkList text)]) : text_buf.TextBufChunkList
      (match chunks
        [(TextBufBorrowedChunkNil _)
          (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks)]
        [(TextBufBorrowedChunkInline _ tail-text _tail-borrowed?)
          (text_buf.chunk-cons
            tail-text
            (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks))]
        [(TextBufBorrowedChunkDense _ prefix _ tail-text _tail-borrowed?)
          (text_buf.chunk-cons tail-text prefix)]))
    ;: Explicit ownership boundary: copy every committed String (borrowed
    ;: views included) and the value-local tail before returning a TextBuf list.
    (define (chunks-to-owned [chunks : (TextBufBorrowedChunkList text)]) : text_buf.TextBufChunkList
      (match chunks
        [(TextBufBorrowedChunkNil _)
          (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks)]
        [(TextBufBorrowedChunkInline _ tail-text _tail-borrowed?)
          (text_buf.chunk-cons
            (stdlib.text_buf_borrowed.text-buf-borrowed-copy-string tail-text)
            (stdlib.text_buf_borrowed.text-buf-borrowed-empty-owned-chunks))]
        [(TextBufBorrowedChunkDense _ prefix _ tail-text _tail-borrowed?)
          (text_buf.chunk-cons
            (stdlib.text_buf_borrowed.text-buf-borrowed-copy-string tail-text)
            (stdlib.text_buf_borrowed.text-buf-borrowed-copy-prefix prefix))]))
    (define (chunks-count
      [chunks : (TextBufBorrowedChunkList text)]
      [count : i64]) : i64
      (match chunks
        [(TextBufBorrowedChunkNil _) count]
        [(TextBufBorrowedChunkInline _ _ _) (+ count 1)]
        [(TextBufBorrowedChunkDense _ _ prefix-count _ _)
          (+ count (+ prefix-count 1))]))
    (define (chunk-count [buf : (TextBufBorrowed text)]) : i64
      (match buf
        [(TextBufBorrowed chunks _)
          (stdlib.text_buf_borrowed.chunks-count chunks 0)]))
    (define (text-buf-borrowed-render-list
      [chunks : (TextBufBorrowedChunkList text)]
      [total : i64]) : String
      (text_buf.render-chunks
        (stdlib.text_buf_borrowed.text-buf-borrowed-render-chunks chunks)
        total))
    (define (render [buf : (TextBufBorrowed text)]) : String
      (match buf
        [(TextBufBorrowed chunks total-len)
          (stdlib.text_buf_borrowed.text-buf-borrowed-render-list
            chunks
            total-len)]))))