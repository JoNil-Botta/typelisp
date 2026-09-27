;; format_cst.tl - Neutral formatter CST over format_tokens.tl.
;;
;; The CST keeps enough shape for a formatter without committing to final
;; layout: atoms keep original token spelling, comments stay as trivia nodes,
;; and parenthesized/bracketed lists keep their delimiter kind.
(import compiler_owned_view as owned_view)
(import stdlib.string)
(import format_tokens as tokens)

(defenum FormatCst
  (Atom tokens.FormatToken)
  (Comment String)
  (Prefix tokens.FormatToken (Box FormatCst))
  (Projection (Box FormatCst) String)
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
  (FormatCstVec (__tl_make-array FormatCst 4) 0))

(define (format-cst-vec-copy-range!
  [dst : (&mut dst (__tl_dyn-array FormatCst))]
  [src : (& src (__tl_dyn-array FormatCst))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (format-cst-vec-copy-range! dst src (+ index 1) count))))

(define (format-cst-vec-grow! [v : (&mut v FormatCstVec)]) : unit
  (let
    [count : i64 v.len]
    [old-cap : i64 (array-length v.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array FormatCst) (__tl_make-array FormatCst new-cap)]
    (begin
      (format-cst-vec-copy-range! (&mut bigger) (& v.slots) 0 count)
      (set! v.slots bigger))))

(define (format-cst-vec-push! [v : (&mut v FormatCstVec)] [value : FormatCst]) : unit
  (begin
    (if (< v.len (array-length v.slots))
      unit
      (format-cst-vec-grow! v))
    (let
      [index : i64 v.len]
      (begin
        (set! (array-ref v.slots index) value)
        (set! v.len (+ index 1))))))

(define (fmt-cst-list-nil) : FormatCstList
  (FormatCstList (__tl_make-array FormatCst 0) 0 0))

(define (fmt-cst-list-from-vec [items : FormatCstVec]) : FormatCstList
  (FormatCstList items.slots 0 items.len))

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
    [start : i64 items.start]
    [count : i64 items.len]
    (if (<= count 0)
      (FormatCstListStep.Empty)
      (FormatCstListStep.Item
        (owned_view.compiler-owned-array-element-shared-view items.slots start)
        (FormatCstList items.slots (+ start 1) (- count 1))))))

(define (fmt-cst-list-empty? [items : (& items FormatCstList)]) : bool
  (<= items.len 0))

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
    [tag : i64
      (tokens.format-token-tag
        (tokens.format-token-at
          (owned_view.compiler-owned-shared-view stream)
          idx))]
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
        (match (fmt-parse-one-result
          (owned_view.compiler-owned-shared-view stream)
          idx)
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
    [tag : i64
      (tokens.format-token-tag
        (tokens.format-token-at
          (owned_view.compiler-owned-shared-view stream)
          idx))]
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
          (match (fmt-parse-one-result
            (owned_view.compiler-owned-shared-view stream)
            idx)
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

(define (fmt-parse-one-primary-result
  [stream : tokens.FormatTokenStream]
  [idx : i64]) : ResultFormatParsedCst
  (let
    [tok : tokens.FormatToken
      (tokens.format-token-at
        (owned_view.compiler-owned-shared-view stream)
        idx)]
    [tag : i64
      (tokens.format-token-tag
        (tokens.format-token-at
          (owned_view.compiler-owned-shared-view stream)
          idx))]
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

(define (fmt-token-end [stream : tokens.FormatTokenStream] [idx : i64]) : i64
  (+
    (tokens.format-token-start stream idx)
    (string.string-length
      (tokens.format-token-text (tokens.format-token-at stream idx)))))

(define (fmt-tokens-adjacent?
  [stream : tokens.FormatTokenStream]
  [left : i64]
  [right : i64]) : bool
  (=
    (fmt-token-end (owned_view.compiler-owned-shared-view stream) left)
    (tokens.format-token-start stream right)))

(define (fmt-parse-projection-suffix-result
  [stream : tokens.FormatTokenStream]
  [parsed : FormatParsedCst]) : ResultFormatParsedCst
  (match (owned_view.compiler-owned-shared-view parsed)
    [(FormatParsedCst.Parsed node next)
      (let
        [dot : tokens.FormatToken
          (tokens.format-token-at
            (owned_view.compiler-owned-shared-view stream)
            next)]
        (if (and
          (> next 0)
          (= (tokens.format-token-tag dot) (tokens.fmt-tag-dot))
          (fmt-tokens-adjacent?
            (owned_view.compiler-owned-shared-view stream)
            (- next 1)
            next))
          (let
            [field-index : i64 (+ next 1)]
            [field : tokens.FormatToken
              (tokens.format-token-at
                (owned_view.compiler-owned-shared-view stream)
                field-index)]
            (if (and
              (=
                (tokens.format-token-tag
                  (owned_view.compiler-owned-shared-view field))
                (tokens.fmt-tag-symbol))
              (fmt-tokens-adjacent?
                (owned_view.compiler-owned-shared-view stream)
                next
                field-index))
              (fmt-parse-projection-suffix-result
                stream
                (FormatParsedCst.Parsed
                  (FormatCst.Projection
                    (box node)
                    (tokens.format-token-text field))
                  (+ field-index 1)))
              (ResultFormatParsedCst.Ok parsed)))
          (ResultFormatParsedCst.Ok parsed)))]))

(define (fmt-parse-one-result [stream : tokens.FormatTokenStream] [idx : i64]) : ResultFormatParsedCst
  (match (fmt-parse-one-primary-result
    (owned_view.compiler-owned-shared-view stream)
    idx)
    [(ResultFormatParsedCst.Ok parsed)
      (fmt-parse-projection-suffix-result stream parsed)]
    [(ResultFormatParsedCst.Err err) (ResultFormatParsedCst.Err err)]))

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