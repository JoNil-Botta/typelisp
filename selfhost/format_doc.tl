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
  (DConcat (Box Doc) (Box Doc))
  (DNest i64 (Box Doc))
  (DGroup (Box Doc)))

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
        [_ (DConcat (box left) (box right))])]))

(define (doc-nest [indent : i64] [doc : Doc]) : Doc
  (DNest indent (box doc)))

(define (doc-group [doc : Doc]) : Doc
  (DGroup (box doc)))

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
    [(DConcat left right)
      (+ (flat-width (box-get left)) (flat-width (box-get right)))]
    [(DNest _ inner) (flat-width (box-get inner))]
    [(DGroup inner) (flat-width (box-get inner))]))

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
      (match (render-doc-in (box-get left) width indent col flat)
        [(Rendered left-text left-col)
          (match (render-doc-in (box-get right) width indent left-col flat)
            [(Rendered right-text right-col)
              (Rendered (string-append left-text right-text) right-col)])])]
    [(DNest extra inner)
      (render-doc-in (box-get inner) width (+ indent extra) col flat)]
    [(DGroup inner)
      (if (fits-flat (box-get inner) (- width col))
        (render-doc-in (box-get inner) width indent col true)
        (render-doc-in (box-get inner) width indent col false))]))

(define (render-doc-width [doc : Doc] [width : i64]) : String
  (rendered-text (render-doc-in doc width 0 0 false)))

(define (render-doc [doc : Doc]) : String
  (render-doc-width doc (format-width)))

(define (sample-group-doc) : Doc
  (doc-group
    (doc-nest
      2
      (doc-append
        (doc-text "alpha")
        (doc-append (doc-soft-line) (doc-text "beta"))))))

(define (sample-hard-line-doc) : Doc
  (doc-group
    (doc-append (doc-text "a") (doc-append (doc-hard-line) (doc-text "b")))))

(define (format-doc-boxed-algebra-ok?) : bool
  (let
    [doc : Doc
      (doc-group
        (doc-nest
          4
          (doc-append
            (doc-text "a")
            (doc-append
              (doc-soft-line)
              (doc-append
                (doc-text "b")
                (doc-append (doc-soft-line) (doc-text "c")))))))]
    [flat : String (render-doc-width doc 80)]
    [broken : String (render-doc-width doc 4)]
    (and
      (string-eq flat "a b c")
      (and (string-eq broken "a\n    b\n    c") (= (flat-width doc) 5)))))

(define (format-doc-self-test) : i64
  (let
    [flat : String (render-doc-width (sample-group-doc) 80)]
    [broken : String (render-doc-width (sample-group-doc) 6)]
    [hard : String (render-doc-width (sample-hard-line-doc) 80)]
    [empty : String (render-doc (doc-append (doc-empty) (doc-text "x")))]
    (begin
      (unless (string-eq flat "alpha beta") (return 1))
      (unless (string-eq broken "alpha\n  beta") (return 2))
      (unless (string-eq hard "a\nb") (return 3))
      (unless (string-eq empty "x") (return 4))
      (unless (format-doc-boxed-algebra-ok?) (return 5))
      42)))