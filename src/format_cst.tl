;; format_cst.tl - Neutral formatter CST over format_tokens.tl.
;;
;; The CST keeps enough shape for a formatter without committing to final
;; layout: atoms keep original token spelling, comments stay as trivia nodes,
;; and parenthesized/bracketed lists keep their delimiter kind.
(import stdlib.io)
(import stdlib.string)
(import format_tokens as tokens)

(defenum FormatCst
  (Atom tokens.FormatToken)
  (Comment String)
  (Prefix tokens.FormatToken (Box FormatCst))
  (List (Box FormatCstList))
  (BracketList (Box FormatCstList))
  (Forms (Box FormatCstList)))

;; A list is a contiguous slice `slots[start .. start + len)`. Tails share the
;; backing array, so stepping is index arithmetic instead of a pointer chase,
;; and every walker can also take the whole run at once.
(defstruct FormatCstList
  (slots (__tl_dyn-array FormatCst))
  (start i64)
  (len i64))

(defstruct FormatCstVec
  (slots (__tl_dyn-array FormatCst))
  (len i64))

(defenum FormatCstListStep
  (Empty)
  (Item FormatCst FormatCstList))

(defenum FormatParsedCst
  (Parsed FormatCst i64))

(defenum FormatParsedCstList
  (ParsedList FormatCstList i64))

(defenum ResultFormatCst
  (Ok FormatCst)
  (Err tokens.FormatSourceError))

(defenum ResultFormatParsedCst
  (Ok FormatParsedCst)
  (Err tokens.FormatSourceError))

(defenum ResultFormatParsedCstList
  (Ok FormatParsedCstList)
  (Err tokens.FormatSourceError))

(defenum ResultFormatParseSeqEnd
  (Ok i64)
  (Err tokens.FormatSourceError))

(define (format-cst-vec-new) : FormatCstVec
  (FormatCstVec (make-array FormatCst 4) 0))

(define (format-cst-vec-copy-range!
  [dst : (&mut dst (__tl_dyn-array FormatCst))]
  [src : (& src (__tl_dyn-array FormatCst))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (format-cst-vec-copy-range! dst src (+ index 1) count))))

(define (format-cst-vec-grow! [v : (&mut v FormatCstVec)]) : unit
  (let
    [count : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array FormatCst) (make-array FormatCst new-cap)]
    (begin
      (format-cst-vec-copy-range!
        (&mut bigger)
        (& (struct-get v slots))
        0
        count)
      (set! (struct-get v slots) bigger))))

(define (format-cst-vec-push! [v : (&mut v FormatCstVec)] [value : FormatCst]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (format-cst-vec-grow! v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (set! (struct-get v len) (+ index 1))))))

(define (fmt-cst-list-nil) : FormatCstList
  (FormatCstList (make-array FormatCst 0) 0 0))

(define (fmt-cst-list-from-vec [items : FormatCstVec]) : FormatCstList
  (FormatCstList (struct-get items slots) 0 (struct-get items len)))

(define (fmt-cst-vec-push-list!
  [v : (&mut v FormatCstVec)]
  [items : FormatCstList]) : unit
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) unit]
    [(FormatCstListStep.Item node rest)
      (begin
        (format-cst-vec-push! v node)
        (fmt-cst-vec-push-list! v rest))]))

(define (fmt-cst-list-cons [head : FormatCst] [rest : FormatCstList]) : FormatCstList
  (let
    [out : FormatCstVec (format-cst-vec-new)]
    (begin
      (format-cst-vec-push! (&mut out) head)
      (fmt-cst-vec-push-list! (&mut out) rest)
      (fmt-cst-list-from-vec out))))

(define (fmt-cst-list-step [items : FormatCstList]) : FormatCstListStep
  (let
    [start : i64 (struct-get items start)]
    [count : i64 (struct-get items len)]
    (if (<= count 0)
      (FormatCstListStep.Empty)
      (FormatCstListStep.Item
        (array-ref (struct-get items slots) start)
        (FormatCstList (struct-get items slots) (+ start 1) (- count 1))))))

(define (fmt-cst-list-empty? [items : FormatCstList]) : bool
  (<= (struct-get items len) 0))

(define (fmt-list-count [items : FormatCstList]) : i64
  (struct-get items len))

(define (fmt-cst-count [node : FormatCst]) : i64
  (match node
    [(FormatCst.Atom _) 1]
    [(FormatCst.Comment _) 1]
    [(FormatCst.Prefix _ child) (+ 1 (fmt-cst-count (box-get child)))]
    [(FormatCst.List items) (+ 1 (fmt-cst-list-total (box-get items)))]
    [(FormatCst.BracketList items) (+ 1 (fmt-cst-list-total (box-get items)))]
    [(FormatCst.Forms items) (+ 1 (fmt-cst-list-total (box-get items)))]))

(define (fmt-cst-list-total [items : FormatCstList]) : i64
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) 0]
    [(FormatCstListStep.Item node rest)
      (+ (fmt-cst-count node) (fmt-cst-list-total rest))]))

(define (fmt-cst-comment-count [node : FormatCst]) : i64
  (match node
    [(FormatCst.Atom _) 0]
    [(FormatCst.Comment _) 1]
    [(FormatCst.Prefix _ child) (fmt-cst-comment-count (box-get child))]
    [(FormatCst.List items) (fmt-cst-list-comment-count (box-get items))]
    [(FormatCst.BracketList items) (fmt-cst-list-comment-count (box-get items))]
    [(FormatCst.Forms items) (fmt-cst-list-comment-count (box-get items))]))

(define (fmt-cst-list-comment-count [items : FormatCstList]) : i64
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) 0]
    [(FormatCstListStep.Item node rest)
      (+ (fmt-cst-comment-count node) (fmt-cst-list-comment-count rest))]))

(define (fmt-cst-bracket-count [node : FormatCst]) : i64
  (match node
    [(FormatCst.Atom _) 0]
    [(FormatCst.Comment _) 0]
    [(FormatCst.Prefix _ child) (fmt-cst-bracket-count (box-get child))]
    [(FormatCst.List items) (fmt-cst-list-bracket-count (box-get items))]
    [(FormatCst.BracketList items)
      (+ 1 (fmt-cst-list-bracket-count (box-get items)))]
    [(FormatCst.Forms items) (fmt-cst-list-bracket-count (box-get items))]))

(define (fmt-cst-list-bracket-count [items : FormatCstList]) : i64
  (match (fmt-cst-list-step items)
    [(FormatCstListStep.Empty) 0]
    [(FormatCstListStep.Item node rest)
      (+ (fmt-cst-bracket-count node) (fmt-cst-list-bracket-count rest))]))

(define (fmt-unexpected-closing [tag : i64]) : bool
  (or (= tag (tokens.fmt-tag-rparen)) (= tag (tokens.fmt-tag-rbracket))))

(define (fmt-prefix-tag? [tag : i64]) : bool
  (or
    (= tag (tokens.fmt-tag-quote))
    (= tag (tokens.fmt-tag-backtick))
    (= tag (tokens.fmt-tag-comma))
    (= tag (tokens.fmt-tag-comma-at))))

(define (fmt-parse-seq-into-result
  [stream : tokens.FormatTokenStream]
  [idx : i64]
  [stop-tag : i64]
  [items : (&mut items FormatCstVec)]) : ResultFormatParseSeqEnd
  (let
    [tag : i64 (tokens.format-token-tag (tokens.format-token-at stream idx))]
    (cond
      [(= tag (tokens.fmt-tag-end))
        (if (= stop-tag 0)
          (ResultFormatParseSeqEnd.Ok idx)
          (ResultFormatParseSeqEnd.Err
            (tokens.FormatSourceError
              "format cst: unclosed delimiter"
              (tokens.format-token-span stream idx))))]
      [(and (!= stop-tag 0) (= tag stop-tag))
        (ResultFormatParseSeqEnd.Ok (+ idx 1))]
      [(fmt-unexpected-closing tag)
        (ResultFormatParseSeqEnd.Err
          (tokens.FormatSourceError
            "format cst: unexpected closing delimiter"
            (tokens.format-token-span stream idx)))]
      [else
        (match (fmt-parse-one-result stream idx)
          [(ResultFormatParsedCst.Ok parsed)
            (match parsed
              [(FormatParsedCst.Parsed node next)
                (begin
                  (format-cst-vec-push! items node)
                  (fmt-parse-seq-into-result stream next stop-tag items))])]
          [(ResultFormatParsedCst.Err err) (ResultFormatParseSeqEnd.Err err)])])))

(define (fmt-parse-seq-result
  [stream : tokens.FormatTokenStream]
  [idx : i64]
  [stop-tag : i64]) : ResultFormatParsedCstList
  (let
    [tag : i64 (tokens.format-token-tag (tokens.format-token-at stream idx))]
    (cond
      [(= tag (tokens.fmt-tag-end))
        (if (= stop-tag 0)
          (ResultFormatParsedCstList.Ok
            (FormatParsedCstList.ParsedList (fmt-cst-list-nil) idx))
          (ResultFormatParsedCstList.Err
            (tokens.FormatSourceError
              "format cst: unclosed delimiter"
              (tokens.format-token-span stream idx))))]
      [(and (!= stop-tag 0) (= tag stop-tag))
        (ResultFormatParsedCstList.Ok
          (FormatParsedCstList.ParsedList (fmt-cst-list-nil) (+ idx 1)))]
      [(fmt-unexpected-closing tag)
        (ResultFormatParsedCstList.Err
          (tokens.FormatSourceError
            "format cst: unexpected closing delimiter"
            (tokens.format-token-span stream idx)))]
      [else
        (let
          [items : FormatCstVec (format-cst-vec-new)]
          (match (fmt-parse-one-result stream idx)
            [(ResultFormatParsedCst.Ok parsed)
              (match parsed
                [(FormatParsedCst.Parsed node next)
                  (begin
                    (format-cst-vec-push! (&mut items) node)
                    (match (fmt-parse-seq-into-result
                      stream
                      next
                      stop-tag
                      (&mut items))
                      [(ResultFormatParseSeqEnd.Ok final)
                        (ResultFormatParsedCstList.Ok
                          (FormatParsedCstList.ParsedList
                            (fmt-cst-list-from-vec items)
                            final))]
                      [(ResultFormatParseSeqEnd.Err err)
                        (ResultFormatParsedCstList.Err err)]))])]
            [(ResultFormatParsedCst.Err err)
              (ResultFormatParsedCstList.Err err)]))])))

(define (fmt-parse-one-result [stream : tokens.FormatTokenStream] [idx : i64]) : ResultFormatParsedCst
  (let
    [tok : tokens.FormatToken (tokens.format-token-at stream idx)]
    [tag : i64 (tokens.format-token-tag (tokens.format-token-at stream idx))]
    (cond
      [(= tag (tokens.fmt-tag-lparen))
        (match (fmt-parse-seq-result stream (+ idx 1) (tokens.fmt-tag-rparen))
          [(ResultFormatParsedCstList.Ok parsed)
            (match parsed
              [(FormatParsedCstList.ParsedList items next)
                (ResultFormatParsedCst.Ok
                  (FormatParsedCst.Parsed (FormatCst.List (box items)) next))])]
          [(ResultFormatParsedCstList.Err err) (ResultFormatParsedCst.Err err)])]
      [(= tag (tokens.fmt-tag-lbracket))
        (match (fmt-parse-seq-result stream (+ idx 1) (tokens.fmt-tag-rbracket))
          [(ResultFormatParsedCstList.Ok parsed)
            (match parsed
              [(FormatParsedCstList.ParsedList items next)
                (ResultFormatParsedCst.Ok
                  (FormatParsedCst.Parsed
                    (FormatCst.BracketList (box items))
                    next))])]
          [(ResultFormatParsedCstList.Err err) (ResultFormatParsedCst.Err err)])]
      [(= tag (tokens.fmt-tag-comment))
        (ResultFormatParsedCst.Ok
          (FormatParsedCst.Parsed
            (FormatCst.Comment (tokens.format-token-text tok))
            (+ idx 1)))]
      [(fmt-prefix-tag? tag)
        (match (fmt-parse-one-result stream (+ idx 1))
          [(ResultFormatParsedCst.Ok parsed)
            (match parsed
              [(FormatParsedCst.Parsed child next)
                (ResultFormatParsedCst.Ok
                  (FormatParsedCst.Parsed
                    (FormatCst.Prefix tok (box child))
                    next))])]
          [(ResultFormatParsedCst.Err err) (ResultFormatParsedCst.Err err)])]
      [(fmt-unexpected-closing tag)
        (ResultFormatParsedCst.Err
          (tokens.FormatSourceError
            "format cst: unexpected closing delimiter"
            (tokens.format-token-span stream idx)))]
      [(= tag (tokens.fmt-tag-end))
        (ResultFormatParsedCst.Err
          (tokens.FormatSourceError
            "format cst: unexpected end"
            (tokens.format-token-span stream idx)))]
      [else
        (ResultFormatParsedCst.Ok
          (FormatParsedCst.Parsed (FormatCst.Atom tok) (+ idx 1)))])))

(define (parse-format-tokens-result [stream : tokens.FormatTokenStream]) : ResultFormatCst
  (match (fmt-parse-seq-result stream 0 0)
    [(ResultFormatParsedCstList.Ok parsed)
      (match parsed
        [(FormatParsedCstList.ParsedList items _)
          (ResultFormatCst.Ok (FormatCst.Forms (box items)))])]
    [(ResultFormatParsedCstList.Err err) (ResultFormatCst.Err err)]))

(define (parse-format-source-result [src : String]) : ResultFormatCst
  (match (tokens.format-lex-result src)
    [(tokens.ResultFormatTokenStream.Ok stream)
      (parse-format-tokens-result stream)]
    [(tokens.ResultFormatTokenStream.Err err) (ResultFormatCst.Err err)]))

(define (parse-format-source [src : String]) : FormatCst
  (match (parse-format-source-result src)
    [(ResultFormatCst.Ok tree) tree]
    [(ResultFormatCst.Err err)
      (io.panic (tokens.format-source-error-message err))]))

(define (format-cst-fixture) : String
  "(import \"std.tl\")
; header comment
(extern (io.print [arg0 : i64]) : unit)
(defenum Maybe (Some i64) (None))
(defstruct Point (x i64) (y i64))
(define (main [xs : (__tl_dyn-array i64)] [p : Point]) : i64
  (let
    [n : i64 (array-ref xs 0)]
    [c : char ' ']
    (match (Some n)
      [(Some v) (+ v (cast c : i64))]
      [None 0])))")

(define (format-cst-boxed-nested-ok?) : bool
  (let
    [tree : FormatCst (parse-format-source "'(outer [x ; inner\n y] ,z)")]
    (and
      (= (fmt-cst-comment-count tree) 1)
      (> (fmt-cst-bracket-count tree) 0)
      (> (fmt-cst-count tree) 8))))

(define (format-cst-prefixed-int-ok?) : bool
  (let
    [stream : tokens.FormatTokenStream (tokens.format-lex "(0x2a -0b101010)")]
    (and
      (= (tokens.format-token-tag-count stream (tokens.fmt-tag-int)) 2)
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 1))
        (tokens.fmt-tag-int))
      (string.eq
        (tokens.format-token-text (tokens.format-token-at stream 1))
        "0x2a")
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 2))
        (tokens.fmt-tag-int))
      (string.eq
        (tokens.format-token-text (tokens.format-token-at stream 2))
        "-0b101010")
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 4))
        (tokens.fmt-tag-end)))))

(define (format-cst-apostrophe-char-ok?) : bool
  (let
    [stream : tokens.FormatTokenStream (tokens.format-lex "'a' '\"' '('")]
    (and
      (= (tokens.format-token-tag-count stream (tokens.fmt-tag-char)) 3)
      (=
        (tokens.format-token-tag (tokens.format-token-at stream 3))
        (tokens.fmt-tag-end)))))

(define (format-cst-error-location-ok?) : bool
  (match (parse-format-source-result "(define x\n  ]")
    [(ResultFormatCst.Ok _) false]
    [(ResultFormatCst.Err err)
      (and
        (string.eq
          (tokens.format-source-error-message err)
          "format cst: unexpected closing delimiter")
        (tokens.format-source-span-eq?
          (tokens.format-source-error-span err)
          2
          3
          2
          3))]))

(define (format-cst-legacy-char-rejected-ok?) : bool
  (and
    (match (parse-format-source-result "#x'")
      [(ResultFormatCst.Ok _) false]
      [(ResultFormatCst.Err err)
        (string.eq
          (tokens.format-source-error-message err)
          "format lexer: unexpected character")])
    (match (parse-format-source-result "#\\space'")
      [(ResultFormatCst.Ok _) false]
      [(ResultFormatCst.Err err)
        (string.eq
          (tokens.format-source-error-message err)
          "format lexer: unexpected character")])))

(define (format-cst-dense-storage-ok?) : bool
  (match (parse-format-source "(a b c)")
    [(FormatCst.Forms forms)
      (and
        (= (fmt-list-count (box-get forms)) 1)
        (match (fmt-cst-list-step (box-get forms))
          [(FormatCstListStep.Item node _)
            (match node
              [(FormatCst.List items) (= (fmt-list-count (box-get items)) 3)]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (format-cst-self-test) : i64
  (let
    [stream : tokens.FormatTokenStream (tokens.format-lex (format-cst-fixture))]
    [tree : FormatCst (parse-format-source (format-cst-fixture))]
    (begin
      (unless (> (tokens.format-token-count stream) 40) (return 1))
      (unless (> (fmt-cst-count tree) 40) (return 2))
      (unless (= (fmt-cst-comment-count tree) 1) (return 3))
      (unless (> (fmt-cst-bracket-count tree) 4) (return 4))
      (unless
        (= (tokens.format-token-tag-count stream (tokens.fmt-tag-char)) 1)
        (return 5))
      (unless (format-cst-boxed-nested-ok?) (return 6))
      (unless (format-cst-prefixed-int-ok?) (return 7))
      (unless (format-cst-apostrophe-char-ok?) (return 8))
      (unless (format-cst-error-location-ok?) (return 9))
      (unless (format-cst-legacy-char-rejected-ok?) (return 10))
      (unless (format-cst-dense-storage-ok?) (return 11))
      42)))