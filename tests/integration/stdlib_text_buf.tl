;; stdlib_text_buf.tl - Integration witness for stdlib/text_buf.tl.
(import stdlib.text_buf)
(import stdlib.text_buf_borrowed)
(import stdlib.text_buf_family)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import stdlib.byte_buf)

(define (text-buf-integration-ok?) : bool
  (let
    [left : text_buf.TextBuf
      (text_buf.append-char (text_buf.append (text_buf.empty) "left") '-')]
    [right : text_buf.TextBuf
      (text_buf.append-int (text_buf.append (text_buf.empty) "right") 7)]
    (string.eq
      (text_buf.render (text_buf.append-buffer left right))
      "left-right7")))

(define (text-buf-owned-persistence-integration-ok?) : bool
  (let
    [base : text_buf.TextBuf
      (text_buf.append
        (text_buf.append (text_buf.append (text_buf.empty) "a") "b")
        "c")]
    [left : text_buf.TextBuf (text_buf.append (clone base) "-left")]
    [right : text_buf.TextBuf (text_buf.append (clone base) "-right")]
    (and
      (= (text_buf.length base) 3)
      (= (text_buf.length left) 8)
      (= (text_buf.length right) 9)
      (= (text_buf.chunk-count (clone base.chunks) 0) 3)
      (= (text_buf.chunk-count (clone left.chunks) 0) 4)
      (= (text_buf.chunk-count (clone right.chunks) 0) 4)
      (string.eq (text_buf.render base) "abc")
      (string.eq (text_buf.render left) "abc-left")
      (string.eq (text_buf.render right) "abc-right"))))

(define (text-buf-owned-clone-out-integration-ok?) : bool
  (let
    [escaped : text_buf.TextBuf
      (with-scratch
        (let
          [base : text_buf.TextBuf (text_buf.append (text_buf.empty) "clone:")]
          [with-int : text_buf.TextBuf (text_buf.append-int base 2718)]
          (text_buf.append with-int "!")))]
    [noise : String
      (with-scratch (string.append "clobber:" (string.int->string 99)))]
    [child : text_buf.TextBuf (text_buf.append (clone escaped) "child")]
    [noise-again : String
      (with-scratch (string.append "clobber-again:" (string.int->string 100)))]
    (and
      (string.eq (& noise) "clobber:99")
      (string.eq (& noise-again) "clobber-again:100")
      (= (text_buf.length escaped) 11)
      (= (text_buf.chunk-count (clone escaped.chunks) 0) 3)
      (string.eq (text_buf.render escaped) "clone:2718!")
      (= (text_buf.length child) 16)
      (= (text_buf.chunk-count (clone child.chunks) 0) 4)
      (string.eq (text_buf.render child) "clone:2718!child"))))

(define (text-buf-owned-nested-arena-integration-ok?) : bool
  (let
    [base : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    (begin
      (while (< i 32)
        (begin
          (set! base (text_buf.append base "o"))
          (set! i (+ i 1))))
      (let
        [outer-arena (arena.make)]
        [child-ok : bool
          (with-escape
            outer-arena
            (let
              [child : text_buf.TextBuf (text_buf.append (clone base) "-inner")]
              (string.eq
                (text_buf.render child)
                "oooooooooooooooooooooooooooooooo-inner")))]
        [sibling-ok : bool
          (with-escape
            outer-arena
            (let
              [sibling : text_buf.TextBuf
                (text_buf.append (clone base) "-sibling")]
              (string.eq
                (text_buf.render sibling)
                "oooooooooooooooooooooooooooooooo-sibling")))]
        [base-ok : bool
          (string.eq (text_buf.render base) "oooooooooooooooooooooooooooooooo")]
        (and child-ok sibling-ok base-ok)))))

(define (text-buf-borrowed-many-integration-ok?) : bool
  (let
    [source : String "x"]
    [buf : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.empty-like (& source))]
    [index : i64 0]
    (begin
      (while (< index 40)
        (begin
          (set! buf (text_buf_borrowed.append buf (& source)))
          (set! index (+ index 1))))
      (and
        (= (text_buf_borrowed.chunk-count buf) 40)
        (= (text_buf_borrowed.length buf) 40)
        (string.eq
          (text_buf_borrowed.render buf)
          "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")))))

(define (text-buf-borrowed-empty-branch-integration-ok?) : bool
  (let
    [source : String "branch"]
    [base : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.empty-like (& source))]
    [left : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-char
        (text_buf_family.text-buf-family-shared-view base)
        '!')]
    [right : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-owned
        (text_buf_family.text-buf-family-shared-view base)
        "?")]
    (and
      (= (text_buf_borrowed.chunk-count base) 0)
      (= (text_buf_borrowed.length base) 0)
      (string.eq (text_buf_borrowed.render base) "")
      (= (text_buf_borrowed.chunk-count left) 1)
      (= (text_buf_borrowed.chunk-count right) 1)
      (string.eq (text_buf_borrowed.render left) "!")
      (string.eq (text_buf_borrowed.render right) "?"))))

(define (text-buf-borrowed-dense-branch-integration-ok?) : bool
  (let
    [source : String "dense"]
    [base : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-char
        (text_buf_borrowed.append-owned
          (text_buf_borrowed.append-owned
            (text_buf_borrowed.empty-like (& source))
            "a")
          "b")
        '!')]
    [left : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-owned
        (text_buf_family.text-buf-family-shared-view base)
        "-left")]
    [right : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-owned
        (text_buf_family.text-buf-family-shared-view base)
        "-right")]
    (and
      (= (text_buf_borrowed.chunk-count base) 3)
      (string.eq
        (text_buf_borrowed.render
          (text_buf_family.text-buf-family-shared-view base))
        "ab!")
      (= (text_buf_borrowed.chunk-count left) 4)
      (= (text_buf_borrowed.chunk-count right) 4)
      (string.eq (text_buf_borrowed.render left) "ab!-left")
      (string.eq (text_buf_borrowed.render right) "ab!-right")
      (string.eq (text_buf_borrowed.render base) "ab!"))))

(define (text-buf-borrowed-boundary-arena-integration-ok?) : bool
  (let
    [source : String "x"]
    [child-source : String "child"]
    [sibling-source : String "sibling"]
    [base : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.empty-like (& source))]
    [index : i64 0]
    (begin
      (while (< index 33)
        (begin
          (set! base (text_buf_borrowed.append base (& source)))
          (set! index (+ index 1))))
      (let
        [outer-arena (arena.make)]
        (with-escape
          outer-arena
          (let
            [child : (text_buf_borrowed.TextBufBorrowed source)
              (text_buf_borrowed.append-copy
                (text_buf_family.text-buf-family-shared-view base)
                (& child-source))]
            [sibling : (text_buf_borrowed.TextBufBorrowed source)
              (text_buf_borrowed.append-copy
                (text_buf_family.text-buf-family-shared-view base)
                (& sibling-source))]
            (and
              (= (text_buf_borrowed.chunk-count base) 33)
              (= (text_buf_borrowed.length base) 33)
              (string.eq
                (text_buf_borrowed.render base)
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
              (= (text_buf_borrowed.chunk-count child) 34)
              (= (text_buf_borrowed.length child) 38)
              (string.eq
                (text_buf_borrowed.render child)
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxchild")
              (= (text_buf_borrowed.chunk-count sibling) 34)
              (= (text_buf_borrowed.length sibling) 40)
              (string.eq
                (text_buf_borrowed.render sibling)
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxsibling"))))))))

(define (text-buf-borrowed-owned-growth-integration-ok?) : bool
  (let
    [source : String "seed"]
    [base : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append
        (text_buf_borrowed.empty-like (& source))
        (& source))]
    [many : (text_buf_borrowed.TextBufBorrowed source) base]
    [index : i64 0]
    (begin
      (while (< index 5)
        (begin
          (set! many (text_buf_borrowed.append-owned many "x"))
          (set! index (+ index 1))))
      (let
        [left : (text_buf_borrowed.TextBufBorrowed source)
          (text_buf_borrowed.append-owned
            (text_buf_family.text-buf-family-shared-view many)
            "-left")]
        [right : (text_buf_borrowed.TextBufBorrowed source)
          (text_buf_borrowed.append-owned
            (text_buf_family.text-buf-family-shared-view many)
            "-right")]
        (and
          (= (text_buf_borrowed.chunk-count many) 6)
          (string.eq
            (text_buf_borrowed.render
              (text_buf_family.text-buf-family-shared-view many))
            "seedxxxxx")
          (string.eq (text_buf_borrowed.render left) "seedxxxxx-left")
          (string.eq (text_buf_borrowed.render right) "seedxxxxx-right")
          (= (text_buf_borrowed.chunk-count many) 6)
          (string.eq (text_buf_borrowed.render many) "seedxxxxx"))))))

(define (text-buf-borrowed-replay-integration-ok?) : bool
  (let
    [source : String "abc"]
    [empty : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.empty-like (& source))]
    [left : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-slice
        (text_buf_family.text-buf-family-shared-view empty)
        (& source)
        0
        2)]
    [right : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-char
        (text_buf_borrowed.append-owned
          (text_buf_borrowed.append-slice
            (text_buf_family.text-buf-family-shared-view empty)
            (& source)
            2
            1)
          "-")
        '!')]
    [joined : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-buffer left right)]
    [same-base : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-owned
        (text_buf_borrowed.append-slice
          (text_buf_family.text-buf-family-shared-view empty)
          (& source)
          0
          1)
        "-")]
    [same-joined : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-buffer
        (text_buf_family.text-buf-family-shared-view same-base)
        same-base)]
    [owned-rendered : String
      (match (text_buf_family.text-buf-family-shared-view joined)
        [(text_buf_borrowed.TextBufBorrowed joined-chunks joined-len)
          (let
            [owned : text_buf.TextBuf
              (text_buf.TextBuf
                (text_buf_borrowed.chunks-to-owned joined-chunks)
                joined-len)]
            (text_buf.render owned))])]
    (and
      (= (text_buf_borrowed.chunk-count joined) 4)
      (string.eq
        (text_buf_borrowed.render
          (text_buf_family.text-buf-family-shared-view joined))
        "abc-!")
      (string.eq owned-rendered (text_buf_borrowed.render joined))
      (= (text_buf_borrowed.chunk-count same-joined) 4)
      (string.eq (text_buf_borrowed.render same-joined) "a-a-"))))

(define (text-buf-borrowed-merge-persistence-integration-ok?) : bool
  (let
    [source : String "abcd"]
    [empty : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.empty-like (& source))]
    [base : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-slice
        (text_buf_borrowed.append-slice empty (& source) 0 1)
        (& source)
        2
        1)]
    [merged : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.append-slice
        (text_buf_family.text-buf-family-shared-view base)
        (& source)
        3
        1)]
    (and
      (= (text_buf_borrowed.chunk-count base) 2)
      (= (text_buf_borrowed.chunk-count merged) 2)
      (string.eq (text_buf_borrowed.render base) "ac")
      (string.eq (text_buf_borrowed.render merged) "acd"))))

(define (text-buf-borrowed-integration-render [seed : String] [tail : String]) : String
  (let
    [borrowed : (text_buf_borrowed.TextBufBorrowed seed)
      (text_buf_borrowed.append-owned
        (text_buf_borrowed.append (text_buf_borrowed.single (& seed)) (& seed))
        "-")]
    [copied : (text_buf_borrowed.TextBufBorrowed seed)
      (text_buf_borrowed.append-copy borrowed (& tail))]
    (text_buf_borrowed.render copied)))

(define (text-buf-borrowed-integration-ok?) : bool
  (let
    [seed : String "xy"]
    [tail : String "z"]
    (string.eq (text-buf-borrowed-integration-render seed tail) "xyxy-z")))

(define (text-buf-write-file-integration-ok?) : bool
  (let
    [path : String "target/stdlib-text-buf-write-file.txt"]
    [buf : text_buf.TextBuf
      (text_buf.append (text_buf.append (text_buf.empty) "file") "-out")]
    [status : i64 (text_buf.write-file path buf)]
    [readback : String (byte_buf.to-string (io.read-file path))]
    (if (= status io.io-status-ok)
      (string.eq readback "file-out")
      false)))

(define (text-buf-large-text [rounds : i64]) : String
  (let
    [text : String "x"]
    [index : i64 0]
    (begin
      (while (< index rounds)
        (begin
          (set! text (string.append (& text) (& text)))
          (set! index (+ index 1))))
      text)))

(define (text-buf-batched-write-file-integration-ok?) : bool
  (let
    [path : String "target/stdlib-text-buf-batched-write-file.txt"]
    [chunk : String (text-buf-large-text 19)]
    [buf : text_buf.TextBuf
      (text_buf.append
        (text_buf.append
          (text_buf.append (text_buf.empty) (string.copy (& chunk)))
          (string.copy (& chunk)))
        chunk)]
    [status : i64 (text_buf.write-file path buf)]
    [readback : String (byte_buf.to-string (io.read-file path))]
    (and (= status io.io-status-ok) (= (string-length (& readback)) 1572864))))

(define (text-buf-oversized-chunk-write-file-integration-ok?) : bool
  (let
    [path : String "target/stdlib-text-buf-oversized-chunk-write-file.txt"]
    [buf : text_buf.TextBuf
      (text_buf.append (text_buf.empty) (text-buf-large-text 21))]
    [status : i64 (text_buf.write-file path buf)]
    [readback : String (byte_buf.to-string (io.read-file path))]
    (and (= status io.io-status-ok) (= (string-length (& readback)) 2097152))))

(define (main) : i64
  (begin
    (unless (text-buf-integration-ok?) (return 2))
    (unless (text-buf-borrowed-integration-ok?) (return 3))
    (unless (text-buf-write-file-integration-ok?) (return 4))
    (unless (text-buf-owned-persistence-integration-ok?) (return 5))
    (unless (text-buf-owned-nested-arena-integration-ok?) (return 6))
    (unless (text-buf-borrowed-many-integration-ok?) (return 7))
    (unless (text-buf-borrowed-empty-branch-integration-ok?) (return 8))
    (unless (text-buf-borrowed-dense-branch-integration-ok?) (return 9))
    (unless (text-buf-borrowed-boundary-arena-integration-ok?) (return 10))
    (unless (text-buf-borrowed-owned-growth-integration-ok?) (return 11))
    (unless (text-buf-borrowed-replay-integration-ok?) (return 12))
    (unless (text-buf-borrowed-merge-persistence-integration-ok?) (return 13))
    (unless (text-buf-owned-clone-out-integration-ok?) (return 14))
    (unless (text-buf-batched-write-file-integration-ok?) (return 15))
    (unless (text-buf-oversized-chunk-write-file-integration-ok?) (return 16))
    42))