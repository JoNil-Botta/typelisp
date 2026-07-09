;; format_doc.tl - Small document algebra for the self-hosted formatter.
;;
;; The formatter front end and rule traversal are separate issues. This module
;; owns the reusable layout engine: callers build `Doc` values, then render them
;; with deterministic width-aware grouping and indentation.
(import stdlib.string)
(import format_render_buf as fmt_buf)

(define (fmt-len [text : String]) : i64
  (string.string-length text))

(define (fmt-eq? [left : String] [right : String]) : bool
  (string.eq left right))

(define (fmt-cat [left : String] [right : String]) : String
  (string.append left right))

(define (fmt-cat3 [left : String] [middle : String] [right : String]) : String
  (string.concat3 left middle right))

(defenum Doc
  (Empty)
  (Text String)
  (SoftLine)
  (HardLine)
  (Concat (Box Doc) (Box Doc))
  (Nest i64 (Box Doc))
  (Group (Box Doc)))

(defenum RenderedDoc
  (Rendered String i64))

(define (doc-empty) : Doc
  (Doc.Empty))

(define (doc-empty? [doc : Doc]) : bool
  (match doc
    [(Doc.Empty) true]
    [_ false]))

(define (doc-text [text : String]) : Doc
  (Doc.Text text))

(define (doc-soft-line) : Doc
  (Doc.SoftLine))

(define (doc-hard-line) : Doc
  (Doc.HardLine))

(define (doc-append [left : Doc] [right : Doc]) : Doc
  (match left
    [(Doc.Empty) right]
    [_
      (match right
        [(Doc.Empty) left]
        [_ (Doc.Concat (box left) (box right))])]))

(define (doc-nest [indent : i64] [doc : Doc]) : Doc
  (Doc.Nest indent (box doc)))

(define (doc-group [doc : Doc]) : Doc
  (Doc.Group (box doc)))

(define (flat-width [doc : Doc]) : i64
  (match doc
    [(Doc.Empty) 0]
    [(Doc.Text text) (fmt-len text)]
    [(Doc.SoftLine) 1]
    [(Doc.HardLine) 1000000]
    [(Doc.Concat left right)
      (+ (flat-width (box-get left)) (flat-width (box-get right)))]
    [(Doc.Nest _ inner) (flat-width (box-get inner))]
    [(Doc.Group inner) (flat-width (box-get inner))]))

;; Add the flat width of `doc` to `acc`, but stop descending as soon as the
;; running total exceeds `limit`: once a subtree is over budget the rest is left
;; unvisited and the (over-budget) accumulator is returned. `flat-width` walked
;; the whole subtree on every group-fit check, which is O(subtree) per group and
;; O(n^2) over deeply nested forms. Bounding each check to ~`limit` characters of
;; work makes it O(width) per group. The total is monotonically non-decreasing,
;; so `(<= (flat-width-capped doc 0 r) r)` equals `(<= (flat-width doc) r)` for
;; every `doc` and `r` (used by `fits-flat`).
(define (flat-width-capped [doc : Doc] [acc : i64] [limit : i64]) : i64
  (if (> acc limit)
    acc
    (match doc
      [(Doc.Empty) acc]
      [(Doc.Text text) (+ acc (fmt-len text))]
      [(Doc.SoftLine) (+ acc 1)]
      [(Doc.HardLine) (+ acc 1000000)]
      [(Doc.Concat left right)
        (flat-width-capped
          (box-get right)
          (flat-width-capped (box-get left) acc limit)
          limit)]
      [(Doc.Nest _ inner) (flat-width-capped (box-get inner) acc limit)]
      [(Doc.Group inner) (flat-width-capped (box-get inner) acc limit)])))

(define (fits-flat [doc : Doc] [remaining : i64]) : bool
  (<= (flat-width-capped doc 0 remaining) remaining))

(define (rendered-text [result : RenderedDoc]) : String
  (match result
    [(RenderedDoc.Rendered text _) text]))

(define (rendered-col [result : RenderedDoc]) : i64
  (match result
    [(RenderedDoc.Rendered _ col) col]))

(define (render-newline [indent : i64]) : RenderedDoc
  (RenderedDoc.Rendered (fmt-cat "\n" (fmt_buf.spaces indent)) indent))

;; Render `doc` by appending into `buf` in place, returning the resulting column.
;; The buffer is owned by `render-doc-width` and threaded by reference, so the
;; renderer no longer allocates a fresh `TextBuf` (and a wrapping `RenderState`)
;; per node -- it mutates one builder and passes the column along as a plain i64.
(define (render-doc-into
  [doc : Doc]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [buf : fmt_buf.FmtRenderBuf]) : i64
  (match doc
    [(Doc.Empty) col]
    [(Doc.Text text)
      (let
        [text-width : i64 (fmt-len text)]
        (begin
          (fmt_buf.fmt-render-buf-append buf text)
          (+ col text-width)))]
    [(Doc.SoftLine)
      (if flat
        (begin
          (fmt_buf.fmt-render-buf-append buf " ")
          (+ col 1))
        (begin
          (fmt_buf.render-newline-into! buf indent)
          indent))]
    [(Doc.HardLine)
      (begin
        (fmt_buf.render-newline-into! buf indent)
        indent)]
    [(Doc.Concat left right)
      (let
        [left-col : i64
          (render-doc-into (box-get left) width indent col flat buf)]
        (render-doc-into (box-get right) width indent left-col flat buf))]
    [(Doc.Nest extra inner)
      (render-doc-into (box-get inner) width (+ indent extra) col flat buf)]
    [(Doc.Group inner)
      (if (fits-flat (box-get inner) (- width col))
        (render-doc-into (box-get inner) width indent col true buf)
        (render-doc-into (box-get inner) width indent col false buf))]))

(define (render-doc-in
  [doc : Doc]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]) : RenderedDoc
  (match doc
    [(Doc.Empty) (RenderedDoc.Rendered "" col)]
    [(Doc.Text text) (RenderedDoc.Rendered text (+ col (fmt-len text)))]
    [(Doc.SoftLine)
      (if flat
        (RenderedDoc.Rendered " " (+ col 1))
        (render-newline indent))]
    [(Doc.HardLine) (render-newline indent)]
    [(Doc.Concat left right)
      (match (render-doc-in (box-get left) width indent col flat)
        [(RenderedDoc.Rendered left-text left-col)
          (match (render-doc-in (box-get right) width indent left-col flat)
            [(RenderedDoc.Rendered right-text right-col)
              (RenderedDoc.Rendered (fmt-cat left-text right-text) right-col)])])]
    [(Doc.Nest extra inner)
      (render-doc-in (box-get inner) width (+ indent extra) col flat)]
    [(Doc.Group inner)
      (if (fits-flat (box-get inner) (- width col))
        (render-doc-in (box-get inner) width indent col true)
        (render-doc-in (box-get inner) width indent col false))]))

(define (render-doc-width [doc : Doc] [width : i64]) : String
  (let
    [buf : fmt_buf.FmtRenderBuf (fmt_buf.fmt-render-buf-new)]
    (begin
      (render-doc-into doc width 0 0 false buf)
      (fmt_buf.fmt-render-buf-string buf))))

(define (render-doc [doc : Doc]) : String
  (render-doc-width doc (fmt_buf.format-width)))

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
      (fmt-eq? flat "a b c")
      (fmt-eq? broken "a\n    b\n    c")
      (= (flat-width doc) 5))))

(define (format-doc-repeat-text [count : i64]) : Doc
  (let
    [i : i64 0]
    [doc : Doc (doc-empty)]
    (begin
      (while (< i count)
        (begin
          (set! doc (doc-append doc (doc-text "x")))
          (set! i (+ i 1))))
      doc)))

(define (format-doc-repeat-soft-text [count : i64]) : Doc
  (let
    [i : i64 0]
    [doc : Doc (doc-empty)]
    (begin
      (while (< i count)
        (begin
          (if (= i 0)
            (set! doc (doc-append doc (doc-text "x")))
            (set!
              doc
              (doc-append doc (doc-append (doc-soft-line) (doc-text "x")))))
          (set! i (+ i 1))))
      doc)))

(define (format-doc-repeat-soft-right [count : i64]) : Doc
  (if (< count 1)
    (doc-empty)
    (if (= count 1)
      (doc-text "x")
      (doc-append
        (doc-text "x")
        (doc-append (doc-soft-line) (format-doc-repeat-soft-right (- count 1)))))))

(define (format-doc-repeat-soft-flat [count : i64]) : String
  (let
    [i : i64 1]
    [out : String "x"]
    (begin
      (while (< i count)
        (begin
          (set! out (fmt-cat3 out " x" ""))
          (set! i (+ i 1))))
      out)))

(define (format-doc-repeat-soft-broken [count : i64]) : String
  (let
    [i : i64 1]
    [out : String "x"]
    (begin
      (while (< i count)
        (begin
          (set! out (fmt-cat3 out "\n  x" ""))
          (set! i (+ i 1))))
      out)))

(define (format-doc-long-sequence-ok?) : bool
  (let
    [doc : Doc (format-doc-repeat-text 64)]
    [rendered : String (render-doc-width doc 80)]
    [flow : Doc (doc-group (doc-nest 2 (format-doc-repeat-soft-text 16)))]
    [flat-flow : String (render-doc-width flow 80)]
    [broken-flow : String (render-doc-width flow 3)]
    [right-doc : Doc (format-doc-repeat-soft-right 16)]
    [right-flow : Doc (doc-group (doc-nest 2 right-doc))]
    [right-broken-flow : String (render-doc-width right-flow 3)]
    [plain-ok : bool (and (= (fmt-len rendered) 64) (= (flat-width doc) 64))]
    [flow-ok : bool
      (and
        (fmt-eq? flat-flow (format-doc-repeat-soft-flat 16))
        (fmt-eq? broken-flow (format-doc-repeat-soft-broken 16)))]
    [right-ok : bool
      (fmt-eq? right-broken-flow (format-doc-repeat-soft-broken 16))]
    (and plain-ok flow-ok right-ok)))

(define (format-doc-seq-branching-ok?) : bool
  (let
    [base : Doc (doc-append (doc-text "a") (doc-text "b"))]
    [with-c : Doc (doc-append base (doc-text "c"))]
    [with-d : Doc (doc-append base (doc-text "d"))]
    [tail : Doc
      (doc-append (doc-text "b") (doc-append (doc-text "c") (doc-text "d")))]
    [with-a : Doc (doc-append (doc-text "a") tail)]
    [with-z : Doc (doc-append (doc-text "z") tail)]
    (and
      (fmt-eq? (render-doc-width base 80) "ab")
      (fmt-eq? (render-doc-width with-c 80) "abc")
      (fmt-eq? (render-doc-width with-d 80) "abd")
      (fmt-eq? (render-doc-width with-a 80) "abcd")
      (fmt-eq? (render-doc-width with-z 80) "zbcd"))))

(define (format-doc-self-test) : i64
  (let
    [flat : String (render-doc-width (sample-group-doc) 80)]
    [broken : String (render-doc-width (sample-group-doc) 6)]
    [hard : String (render-doc-width (sample-hard-line-doc) 80)]
    [empty : String (render-doc (doc-append (doc-empty) (doc-text "x")))]
    (begin
      (unless (fmt-eq? flat "alpha beta") (return 1))
      (unless (fmt-eq? broken "alpha\n  beta") (return 2))
      (unless (fmt-eq? hard "a\nb") (return 3))
      (unless (fmt-eq? empty "x") (return 4))
      (unless (format-doc-boxed-algebra-ok?) (return 5))
      (unless (format-doc-long-sequence-ok?) (return 6))
      (unless (format-doc-seq-branching-ok?) (return 7))
      42)))