;; format_doc.tl - Small document algebra for the self-hosted formatter (#213).
;;
;; The formatter front end and rule traversal are separate issues. This module
;; owns the reusable layout engine: callers build `Doc` values, then render them
;; with deterministic width-aware grouping and indentation.
(import "../stdlib/text_buf.tl")
(import "../stdlib/string.tl")

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

(define (doc-empty? [doc : Doc]) : bool
  (match doc
    [(DEmpty) true]
    [_ false]))

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
      [(DEmpty) acc]
      [(DText text) (+ acc (string-length text))]
      [(DSoftLine) (+ acc 1)]
      [(DHardLine) (+ acc 1000000)]
      [(DConcat left right)
        (flat-width-capped
          (box-get right)
          (flat-width-capped (box-get left) acc limit)
          limit)]
      [(DNest _ inner) (flat-width-capped (box-get inner) acc limit)]
      [(DGroup inner) (flat-width-capped (box-get inner) acc limit)])))

(define (fits-flat [doc : Doc] [remaining : i64]) : bool
  (<= (flat-width-capped doc 0 remaining) remaining))

(define (rendered-text [result : RenderedDoc]) : String
  (match result
    [(Rendered text _) text]))

(define (rendered-col [result : RenderedDoc]) : i64
  (match result
    [(Rendered _ col) col]))

(define (render-newline [indent : i64]) : RenderedDoc
  (Rendered (string-append "\n" (spaces indent)) indent))

;; Append a newline plus `indent` spaces to the owned buffer in place.
(define (render-newline-into! [buf : TextBuf] [indent : i64]) : unit
  (begin
    (text-buf-append! buf "\n")
    (text-buf-append! buf (spaces indent))))

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
  [buf : TextBuf]) : i64
  (match doc
    [(DEmpty) col]
    [(DText text)
      (let
        [text-width : i64 (string-length text)]
        (begin
          (text-buf-append! buf text)
          (+ col text-width)))]
    [(DSoftLine)
      (if flat
        (begin
          (text-buf-append! buf " ")
          (+ col 1))
        (begin
          (render-newline-into! buf indent)
          indent))]
    [(DHardLine)
      (begin
        (render-newline-into! buf indent)
        indent)]
    [(DConcat left right)
      (let
        [left-col : i64
          (render-doc-into (box-get left) width indent col flat buf)]
        (render-doc-into (box-get right) width indent left-col flat buf))]
    [(DNest extra inner)
      (render-doc-into (box-get inner) width (+ indent extra) col flat buf)]
    [(DGroup inner)
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
  (let
    [buf : TextBuf (text-buf-empty)]
    (begin
      (render-doc-into doc width 0 0 false buf)
      (text-buf-render buf))))

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
      (string-eq broken "a\n    b\n    c")
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
          (set! out (string-append out " x"))
          (set! i (+ i 1))))
      out)))

(define (format-doc-repeat-soft-broken [count : i64]) : String
  (let
    [i : i64 1]
    [out : String "x"]
    (begin
      (while (< i count)
        (begin
          (set! out (string-append out "\n  x"))
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
    [plain-ok : bool
      (and (= (string-length rendered) 64) (= (flat-width doc) 64))]
    [flow-ok : bool
      (and
        (string-eq flat-flow (format-doc-repeat-soft-flat 16))
        (string-eq broken-flow (format-doc-repeat-soft-broken 16)))]
    [right-ok : bool
      (string-eq right-broken-flow (format-doc-repeat-soft-broken 16))]
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
      (string-eq (render-doc-width base 80) "ab")
      (string-eq (render-doc-width with-c 80) "abc")
      (string-eq (render-doc-width with-d 80) "abd")
      (string-eq (render-doc-width with-a 80) "abcd")
      (string-eq (render-doc-width with-z 80) "zbcd"))))

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
      (unless (format-doc-long-sequence-ok?) (return 6))
      (unless (format-doc-seq-branching-ok?) (return 7))
      42)))