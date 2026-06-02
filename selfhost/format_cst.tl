;; format_cst.tl - Neutral formatter CST over format_tokens.tl (#326).
;;
;; The CST keeps enough shape for a formatter without committing to final
;; layout: atoms keep original token spelling, comments stay as trivia nodes,
;; and parenthesized/bracketed lists keep their delimiter kind.
(import "../stdlib/io.tl")

(import "format_tokens.tl")

(defenum FormatCst
  (FmtCstAtom FormatToken)
  (FmtCstComment String)
  (FmtCstPrefix FormatToken FormatCst)
  (FmtCstList FormatCstList)
  (FmtCstBracketList FormatCstList)
  (FmtCstForms FormatCstList))

(defenum FormatCstList
  (FmtCstNil)
  (FmtCstCons FormatCst FormatCstList))

(defenum FormatParsedCst
  (FmtParsedCst FormatCst i64))

(defenum FormatParsedCstList
  (FmtParsedCstList FormatCstList i64))

(define (fmt-list-count [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons _ rest) (+ 1 (fmt-list-count rest))]))

(define (fmt-cst-count [node : FormatCst]) : i64
  (match node
    [(FmtCstAtom _) 1]
    [(FmtCstComment _) 1]
    [(FmtCstPrefix _ child) (+ 1 (fmt-cst-count child))]
    [(FmtCstList items) (+ 1 (fmt-cst-list-total items))]
    [(FmtCstBracketList items) (+ 1 (fmt-cst-list-total items))]
    [(FmtCstForms items) (+ 1 (fmt-cst-list-total items))]))

(define (fmt-cst-list-total [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons node rest) (+ (fmt-cst-count node) (fmt-cst-list-total rest))]))

(define (fmt-cst-comment-count [node : FormatCst]) : i64
  (match node
    [(FmtCstAtom _) 0]
    [(FmtCstComment _) 1]
    [(FmtCstPrefix _ child) (fmt-cst-comment-count child)]
    [(FmtCstList items) (fmt-cst-list-comment-count items)]
    [(FmtCstBracketList items) (fmt-cst-list-comment-count items)]
    [(FmtCstForms items) (fmt-cst-list-comment-count items)]))

(define (fmt-cst-list-comment-count [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons node rest)
      (+ (fmt-cst-comment-count node) (fmt-cst-list-comment-count rest))]))

(define (fmt-cst-bracket-count [node : FormatCst]) : i64
  (match node
    [(FmtCstAtom _) 0]
    [(FmtCstComment _) 0]
    [(FmtCstPrefix _ child) (fmt-cst-bracket-count child)]
    [(FmtCstList items) (fmt-cst-list-bracket-count items)]
    [(FmtCstBracketList items) (+ 1 (fmt-cst-list-bracket-count items))]
    [(FmtCstForms items) (fmt-cst-list-bracket-count items)]))

(define (fmt-cst-list-bracket-count [items : FormatCstList]) : i64
  (match items
    [(FmtCstNil) 0]
    [(FmtCstCons node rest)
      (+ (fmt-cst-bracket-count node) (fmt-cst-list-bracket-count rest))]))

(define (fmt-unexpected-closing [tag : i64]) : bool
  (or (= tag (fmt-tag-rparen)) (= tag (fmt-tag-rbracket))))

(define (fmt-prefix-tag? [tag : i64]) : bool
  (or
    (= tag (fmt-tag-quote))
    (or
      (= tag (fmt-tag-backtick))
      (or (= tag (fmt-tag-comma)) (= tag (fmt-tag-comma-at))))))

(define (fmt-parse-seq
  [stream : FormatTokenStream]
  [idx : i64]
  [stop-tag : i64]) : FormatParsedCstList
  (let
    [tag : i64 (format-token-tag (format-token-at stream idx))]
    (cond
      [(= tag (fmt-tag-end))
        (if (= stop-tag 0)
          (FmtParsedCstList FmtCstNil idx)
          (begin
            (panic "format cst: unclosed delimiter")
            (FmtParsedCstList FmtCstNil idx)))]
      [(and (!= stop-tag 0) (= tag stop-tag))
        (FmtParsedCstList FmtCstNil (+ idx 1))]
      [(fmt-unexpected-closing tag)
        (begin
          (panic "format cst: unexpected closing delimiter")
          (FmtParsedCstList FmtCstNil (+ idx 1)))]
      [else
        (match (fmt-parse-one stream idx)
          [(FmtParsedCst node next)
            (match (fmt-parse-seq stream next stop-tag)
              [(FmtParsedCstList rest final)
                (FmtParsedCstList (FmtCstCons node rest) final)])])])))

(define (fmt-parse-one [stream : FormatTokenStream] [idx : i64]) : FormatParsedCst
  (let
    [tok : FormatToken (format-token-at stream idx)]
    [tag : i64 (format-token-tag (format-token-at stream idx))]
    (cond
      [(= tag (fmt-tag-lparen))
        (match (fmt-parse-seq stream (+ idx 1) (fmt-tag-rparen))
          [(FmtParsedCstList items next) (FmtParsedCst (FmtCstList items) next)])]
      [(= tag (fmt-tag-lbracket))
        (match (fmt-parse-seq stream (+ idx 1) (fmt-tag-rbracket))
          [(FmtParsedCstList items next)
            (FmtParsedCst (FmtCstBracketList items) next)])]
      [(= tag (fmt-tag-comment))
        (FmtParsedCst (FmtCstComment (format-token-text tok)) (+ idx 1))]
      [(fmt-prefix-tag? tag)
        (match (fmt-parse-one stream (+ idx 1))
          [(FmtParsedCst child next)
            (FmtParsedCst (FmtCstPrefix tok child) next)])]
      [(fmt-unexpected-closing tag)
        (begin
          (panic "format cst: unexpected closing delimiter")
          (FmtParsedCst (FmtCstAtom tok) (+ idx 1)))]
      [(= tag (fmt-tag-end))
        (begin
          (panic "format cst: unexpected end")
          (FmtParsedCst (FmtCstAtom tok) idx))]
      [else (FmtParsedCst (FmtCstAtom tok) (+ idx 1))])))

(define (parse-format-tokens [stream : FormatTokenStream]) : FormatCst
  (match (fmt-parse-seq stream 0 0)
    [(FmtParsedCstList items _) (FmtCstForms items)]))

(define (parse-format-source [src : String]) : FormatCst
  (parse-format-tokens (format-lex src)))

(define (format-cst-fixture) : String
  "(import \"std.tl\")
; header comment
(extern print : (-> i64 unit))
(defenum Maybe (Some i64) (None))
(defstruct Point (x i64) (y i64))
(define (main [xs : (Array i64)] [p : Point]) : i64
  (let
    [n : i64 (array-ref xs 0)]
    [c : char #\\space']
    (match (Some n)
      [(Some v) (+ v (cast c : i64))]
      [None 0])))")

(define (format-cst-self-test) : i64
  (let
    [stream : FormatTokenStream (format-lex (format-cst-fixture))]
    [tree : FormatCst (parse-format-source (format-cst-fixture))]
    (if (> (format-token-count stream) 40)
      (if (> (fmt-cst-count tree) 40)
        (if (= (fmt-cst-comment-count tree) 1)
          (if (> (fmt-cst-bracket-count tree) 4)
            (if (= (format-token-tag-count stream (fmt-tag-char)) 1)
              42
              5)
            4)
          3)
        2)
      1)))