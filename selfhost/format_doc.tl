;; format_doc.tl - Small document algebra for the self-hosted formatter (#213).
;;
;; The formatter front end and rule traversal are separate issues. This module
;; owns the reusable layout engine: callers build `Doc` values, then render them
;; with deterministic width-aware grouping and indentation.
(defenum Doc
  (DEmpty)
  (DText String)
  (DSoftLine)
  (DHardLine)
  (DConcat Doc Doc)
  (DNest i64 Doc)
  (DGroup Doc))

(defenum RenderedDoc
  (Rendered String i64))

(define (format-width) : i64
  80)

(define (doc-empty) : Doc
  (DEmpty))

(define (doc-text [text : String]) : Doc
  (DText text))

(define (doc-soft-line) : Doc
  (DSoftLine))

(define (doc-hard-line) : Doc
  (DHardLine))

(define (doc-append [left : Doc] [right : Doc]) : Doc
  (match left
    [(DEmpty) right]
    [_
      (match right
        [(DEmpty) left]
        [_ (DConcat left right)])]))

(define (doc-nest [indent : i64] [doc : Doc]) : Doc
  (DNest indent doc))

(define (doc-group [doc : Doc]) : Doc
  (DGroup doc))

(define (spaces [count : i64]) : String
  (let
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i count)
        (begin
          (set! out (string-append out " "))
          (set! i (+ i 1))))
      out)))

(define (flat-width [doc : Doc]) : i64
  (match doc
    [(DEmpty) 0]
    [(DText text) (string-length text)]
    [(DSoftLine) 1]
    [(DHardLine) 1000000]
    [(DConcat left right) (+ (flat-width left) (flat-width right))]
    [(DNest _ inner) (flat-width inner)]
    [(DGroup inner) (flat-width inner)]))

(define (fits-flat [doc : Doc] [remaining : i64]) : bool
  (<= (flat-width doc) remaining))

(define (rendered-text [result : RenderedDoc]) : String
  (match result
    [(Rendered text _) text]))

(define (rendered-col [result : RenderedDoc]) : i64
  (match result
    [(Rendered _ col) col]))

(define (render-newline [indent : i64]) : RenderedDoc
  (Rendered (string-append "\n" (spaces indent)) indent))

(define (render-doc-in
  [doc : Doc]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]) : RenderedDoc
  (match doc
    [(DEmpty) (Rendered "" col)]
    [(DText text) (Rendered text (+ col (string-length text)))]
    [(DSoftLine)
      (if flat
        (Rendered " " (+ col 1))
        (render-newline indent))]
    [(DHardLine) (render-newline indent)]
    [(DConcat left right)
      (match (render-doc-in left width indent col flat)
        [(Rendered left-text left-col)
          (match (render-doc-in right width indent left-col flat)
            [(Rendered right-text right-col)
              (Rendered (string-append left-text right-text) right-col)])])]
    [(DNest extra inner) (render-doc-in inner width (+ indent extra) col flat)]
    [(DGroup inner)
      (if (fits-flat inner (- width col))
        (render-doc-in inner width indent col true)
        (render-doc-in inner width indent col false))]))

(define (render-doc-width [doc : Doc] [width : i64]) : String
  (rendered-text (render-doc-in doc width 0 0 false)))

(define (render-doc [doc : Doc]) : String
  (render-doc-width doc (format-width)))

(define (sample-group-doc) : Doc
  (DGroup
    (DNest 2 (DConcat (DText "alpha") (DConcat (DSoftLine) (DText "beta"))))))

(define (sample-hard-line-doc) : Doc
  (DGroup (DConcat (DText "a") (DConcat (DHardLine) (DText "b")))))

(define (format-doc-self-test) : i64
  (let
    [flat : String (render-doc-width (sample-group-doc) 80)]
    [broken : String (render-doc-width (sample-group-doc) 6)]
    [hard : String (render-doc-width (sample-hard-line-doc) 80)]
    [empty : String (render-doc (doc-append (doc-empty) (DText "x")))]
    (begin
      (unless (string-eq flat "alpha beta") (return 1))
      (unless (string-eq broken "alpha\n  beta") (return 2))
      (unless (string-eq hard "a\nb") (return 3))
      (unless (string-eq empty "x") (return 4))
      42)))