(import stdlib.format)
(import stdlib.profile)
(import stdlib.str_cat)
(import stdlib.string)

(define (debug-one-byte-string [code : i64]) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 1)]
    (begin
      (set! (array-ref bytes 0) (cast code : u8))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) 1)))))

(define (debug-expected-hex-digit [value : i64]) : String
  (string.substring "0123456789abcdef" value 1))

(define (debug-expected-byte-body [code : i64] [delimiter : i64]) : String
  (let
    [printable : String
      " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"]
    (cond
      [(= code 0) "\\0"]
      [(= code 9) "\\t"]
      [(= code 10) "\\n"]
      [(= code 13) "\\r"]
      [(= code 92) "\\\\"]
      [(= code delimiter)
        (if (= delimiter 34)
          "\\\""
          "\\'")]
      [(and (>= code 32) (<= code 126))
        (string.substring printable (- code 32) 1)]
      [else
        (str_cat.str-cat
          "\\x"
          (debug-expected-hex-digit (/ code 16))
          (debug-expected-hex-digit (% code 16)))])))

(define (debug-expected-one-byte [code : i64] [delimiter : i64]) : String
  (let
    [quote : String
      (if (= delimiter 34)
        "\""
        "'")]
    (str_cat.str-cat
      (clone quote)
      (debug-expected-byte-body code delimiter)
      quote)))

(define (debug-ascii-only? [rendered : (& rendered str)]) : bool
  (let
    [index : i64 0]
    [ok : bool true]
    [len : i64 (string.string-length rendered)]
    (begin
      (while (and ok (< index len))
        (begin
          (set! ok (<= (cast (string.string-ref rendered index) : i64) 127))
          (set! index (+ index 1))))
      ok)))

(define (debug-expected-runtime-bytes [rendered : (& rendered str)]) : i64
  ;; One aligned backing-byte allocation plus the normal 16-byte String handle.
  (+ 16 (* 8 (/ (+ (string.string-length rendered) 7) 8))))

(define (debug-exhaustive-byte-table-ok?) : bool
  (let
    [code : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< code 256))
        (let
          [text : String (debug-one-byte-string code)]
          [expected-text : String (debug-expected-one-byte code 34)]
          [before-text : i64 (profile.alloc-total)]
          [rendered-text : String (format.format-debug-string-core (& text))]
          [text-allocated-bytes : i64 (- (profile.alloc-total) before-text)]
          [char-value : char (cast code : char)]
          [expected-char : String (debug-expected-one-byte code 39)]
          [before-char : i64 (profile.alloc-total)]
          [rendered-char : String (format.format-debug-char-core char-value)]
          [char-allocated-bytes : i64 (- (profile.alloc-total) before-char)]
          (begin
            (set!
              ok
              (and
                (=
                  text-allocated-bytes
                  (debug-expected-runtime-bytes (& rendered-text)))
                (=
                  char-allocated-bytes
                  (debug-expected-runtime-bytes (& rendered-char)))
                (string.eq (& rendered-text) (& expected-text))
                (string.eq (& rendered-char) (& expected-char))
                (debug-ascii-only? (& rendered-text))
                (debug-ascii-only? (& rendered-char))
                (= (string.string-length (& text)) 1)
                (= (cast (string.string-ref (& text) 0) : i64) code)
                (= (cast char-value : i64) code)))
            (set! code (+ code 1)))))
      ok)))

(define (debug-heavy-source) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 12)]
    (begin
      (set! (array-ref bytes 0) (cast 0 : u8))
      (set! (array-ref bytes 1) (cast 9 : u8))
      (set! (array-ref bytes 2) (cast 10 : u8))
      (set! (array-ref bytes 3) (cast 13 : u8))
      (set! (array-ref bytes 4) (cast 31 : u8))
      (set! (array-ref bytes 5) (cast 32 : u8))
      (set! (array-ref bytes 6) (cast 34 : u8))
      (set! (array-ref bytes 7) (cast 39 : u8))
      (set! (array-ref bytes 8) (cast 92 : u8))
      (set! (array-ref bytes 9) (cast 126 : u8))
      (set! (array-ref bytes 10) (cast 127 : u8))
      (set! (array-ref bytes 11) (cast 255 : u8))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) 12)))))

(define (debug-focused-goldens-ok?) : bool
  (let
    [borrowed-owner : String "xborrowedx"]
    [borrowed : (& borrowed-owner str)
      (string.substring-view (& borrowed-owner) 1 8)]
    [nul : String (debug-one-byte-string 0)]
    [heavy : String (debug-heavy-source)]
    [before-plain : i64 (profile.alloc-total)]
    [plain : String (format.format-debug-string-core "plain ASCII")]
    [plain-allocated-bytes : i64 (- (profile.alloc-total) before-plain)]
    [before-heavy : i64 (profile.alloc-total)]
    [heavy-rendered : String (format.format-debug-string-core (& heavy))]
    [heavy-allocated-bytes : i64 (- (profile.alloc-total) before-heavy)]
    (and
      (= plain-allocated-bytes (debug-expected-runtime-bytes (& plain)))
      (=
        heavy-allocated-bytes
        (debug-expected-runtime-bytes (& heavy-rendered)))
      (string.eq (format.format-debug-string-core "") "\"\"")
      (string.eq (format.format-debug-string-core "\"") "\"\\\"\"")
      (string.eq (format.format-debug-string-core "'") "\"'\"")
      (string.eq (format.format-debug-string-core "\\") "\"\\\\\"")
      (string.eq (format.format-debug-string-core (& nul)) "\"\\0\"")
      (string.eq (format.format-debug-string-core "\t\n\r") "\"\\t\\n\\r\"")
      (string.eq (format.format-debug-char-core '\'') "'\\''")
      (string.eq (format.format-debug-char-core '"') "'\"'")
      (string.eq (format.format-debug-char-core '\\') "'\\\\'")
      (string.eq (format.format-debug-string-core borrowed) "\"borrowed\"")
      (string.eq (& plain) "\"plain ASCII\"")
      (string.eq
        (& heavy-rendered)
        "\"\\0\\t\\n\\r\\x1f \\\"'\\\\~\\x7f\\xff\"")
      (debug-ascii-only? (& heavy-rendered))
      (= (string.string-length (& heavy)) 12)
      (= (cast (string.string-ref (& heavy) 11) : i64) 255)
      (string.eq (& borrowed-owner) "xborrowedx"))))

(define (main) : i64
  (if (and (debug-exhaustive-byte-table-ok?) (debug-focused-goldens-ok?))
    42
    1))
