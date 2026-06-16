;; format_doc.tl - Small document algebra for the self-hosted formatter (#213).
;;
;; The formatter front end and rule traversal are separate issues. This module
;; owns the reusable layout engine: callers build `Doc` values, then render them
;; with deterministic width-aware grouping and indentation.
(import "../stdlib/text_buf.tl")
(import "../stdlib/string.tl")

(defstruct DocSeq
  (items (Array Doc))
  (start i64)
  (len i64))

(defenum Doc
  (DEmpty)
  (DText String)
  (DSoftLine)
  (DHardLine)
  (DConcat (Box Doc) (Box Doc))
  (DSeq DocSeq)
  (DNest i64 (Box Doc))
  (DGroup (Box Doc)))

(defenum RenderedDoc
  (Rendered String i64))

(defenum RenderState
  (RenderState TextBuf i64))

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

(define (doc-seq-slots [seq : DocSeq]) : (Array Doc)
  (struct-get seq items))

(define (doc-seq-start [seq : DocSeq]) : i64
  (struct-get seq start))

(define (doc-seq-len [seq : DocSeq]) : i64
  (struct-get seq len))

(define (doc-seq-capacity [seq : DocSeq]) : i64
  (array-length (doc-seq-slots seq)))

(define (doc-seq-end [seq : DocSeq]) : i64
  (+ (doc-seq-start seq) (doc-seq-len seq)))

(define (doc-seq-ref [seq : DocSeq] [index : i64]) : Doc
  (array-ref (doc-seq-slots seq) (+ (doc-seq-start seq) index)))

(define (doc-seq-with-capacity [capacity : i64]) : DocSeq
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (DocSeq (make-array Doc cap) 0 0)))

(define (doc-seq-new) : DocSeq
  (doc-seq-with-capacity 4))

(define (doc-seq-copy-range
  [dst : (Array Doc)]
  [dst-index : i64]
  [src : (Array Doc)]
  [src-index : i64]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! dst (+ dst-index i) (array-ref src (+ src-index i)))
        (set! i (+ i 1))))))

(define (doc-seq-grow-back [seq : DocSeq]) : DocSeq
  (let
    [n : i64 (doc-seq-len seq)]
    [bigger : (Array Doc) (make-array Doc (* (doc-seq-capacity seq) 2))]
    (begin
      (doc-seq-copy-range bigger 0 (doc-seq-slots seq) (doc-seq-start seq) n)
      (DocSeq bigger 0 n))))

(define (doc-seq-grow-front [seq : DocSeq]) : DocSeq
  (let
    [n : i64 (doc-seq-len seq)]
    [bigger : (Array Doc) (make-array Doc (* (doc-seq-capacity seq) 2))]
    [new-start : i64 (- (array-length bigger) n)]
    (begin
      (doc-seq-copy-range
        bigger
        new-start
        (doc-seq-slots seq)
        (doc-seq-start seq)
        n)
      (DocSeq bigger new-start n))))

(define (doc-seq-push [seq : DocSeq] [doc : Doc]) : DocSeq
  (if (< (doc-seq-end seq) (doc-seq-capacity seq))
    (let
      [slots : (Array Doc) (doc-seq-slots seq)]
      [end : i64 (doc-seq-end seq)]
      (if (doc-empty? (array-ref slots end))
        (begin
          (array-set! slots end doc)
          (DocSeq slots (doc-seq-start seq) (+ (doc-seq-len seq) 1)))
        (doc-seq-push (doc-seq-grow-back seq) doc)))
    (doc-seq-push (doc-seq-grow-back seq) doc)))

(define (doc-seq-prepend [seq : DocSeq] [doc : Doc]) : DocSeq
  (if (> (doc-seq-start seq) 0)
    (let
      [slots : (Array Doc) (doc-seq-slots seq)]
      [new-start : i64 (- (doc-seq-start seq) 1)]
      (if (doc-empty? (array-ref slots new-start))
        (begin
          (array-set! slots new-start doc)
          (DocSeq slots new-start (+ (doc-seq-len seq) 1)))
        (doc-seq-prepend (doc-seq-grow-front seq) doc)))
    (doc-seq-prepend (doc-seq-grow-front seq) doc)))

(define (doc-seq-from-two [left : Doc] [right : Doc]) : DocSeq
  (doc-seq-push (doc-seq-push (doc-seq-new) left) right))

(define (doc-seq-append-seq [seq : DocSeq] [items : DocSeq]) : DocSeq
  (let
    [i : i64 0]
    [out : DocSeq seq]
    (begin
      (while (< i (doc-seq-len items))
        (begin
          (set! out (doc-seq-push out (doc-seq-ref items i)))
          (set! i (+ i 1))))
      out)))

(define (doc-seq-prepend-doc [doc : Doc] [seq : DocSeq]) : DocSeq
  (doc-seq-prepend seq doc))

(define (doc-append [left : Doc] [right : Doc]) : Doc
  (match left
    [(DEmpty) right]
    [(DSeq left-seq)
      (match right
        [(DEmpty) left]
        [(DSeq right-seq) (DSeq (doc-seq-append-seq left-seq right-seq))]
        [_ (DSeq (doc-seq-push left-seq right))])]
    [_
      (match right
        [(DEmpty) left]
        [(DSeq right-seq) (DSeq (doc-seq-prepend-doc left right-seq))]
        [_ (DSeq (doc-seq-from-two left right))])]))

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

(define (flat-width-seq [seq : DocSeq]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (doc-seq-len seq))
        (begin
          (set! total (+ total (flat-width (doc-seq-ref seq i))))
          (set! i (+ i 1))))
      total)))

(define (flat-width [doc : Doc]) : i64
  (match doc
    [(DEmpty) 0]
    [(DText text) (string-length text)]
    [(DSoftLine) 1]
    [(DHardLine) 1000000]
    [(DConcat left right)
      (+ (flat-width (box-get left)) (flat-width (box-get right)))]
    [(DSeq seq) (flat-width-seq seq)]
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

(define (render-state-buf [state : RenderState]) : TextBuf
  (match state
    [(RenderState buf _) buf]))

(define (render-state-col [state : RenderState]) : i64
  (match state
    [(RenderState _ col) col]))

(define (render-newline-into [buf : TextBuf] [indent : i64]) : TextBuf
  (text-buf-append (text-buf-append buf "\n") (spaces indent)))

(define (render-doc-seq-into
  [seq : DocSeq]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [buf : TextBuf]) : RenderState
  (let
    [i : i64 0]
    [state : RenderState (RenderState buf col)]
    (begin
      (while (< i (doc-seq-len seq))
        (begin
          (match state
            [(RenderState cur-buf cur-col)
              (set!
                state
                (render-doc-into
                  (doc-seq-ref seq i)
                  width
                  indent
                  cur-col
                  flat
                  cur-buf))])
          (set! i (+ i 1))))
      state)))

(define (render-doc-into
  [doc : Doc]
  [width : i64]
  [indent : i64]
  [col : i64]
  [flat : bool]
  [buf : TextBuf]) : RenderState
  (match doc
    [(DEmpty) (RenderState buf col)]
    [(DText text)
      (RenderState (text-buf-append buf text) (+ col (string-length text)))]
    [(DSoftLine)
      (if flat
        (RenderState (text-buf-append buf " ") (+ col 1))
        (RenderState (render-newline-into buf indent) indent))]
    [(DHardLine) (RenderState (render-newline-into buf indent) indent)]
    [(DConcat left right)
      (let
        [left-state : RenderState
          (render-doc-into (box-get left) width indent col flat buf)]
        (render-doc-into
          (box-get right)
          width
          indent
          (render-state-col left-state)
          flat
          (render-state-buf left-state)))]
    [(DSeq seq) (render-doc-seq-into seq width indent col flat buf)]
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
    [(DSeq seq)
      (let
        [i : i64 0]
        [result : RenderedDoc (Rendered "" col)]
        (begin
          (while (< i (doc-seq-len seq))
            (begin
              (match result
                [(Rendered left-text left-col)
                  (match (render-doc-in
                    (doc-seq-ref seq i)
                    width
                    indent
                    left-col
                    flat)
                    [(Rendered right-text right-col)
                      (set!
                        result
                        (Rendered
                          (string-append left-text right-text)
                          right-col))])])
              (set! i (+ i 1))))
          result))]
    [(DNest extra inner)
      (render-doc-in (box-get inner) width (+ indent extra) col flat)]
    [(DGroup inner)
      (if (fits-flat (box-get inner) (- width col))
        (render-doc-in (box-get inner) width indent col true)
        (render-doc-in (box-get inner) width indent col false))]))

(define (render-doc-width [doc : Doc] [width : i64]) : String
  (match (render-doc-into doc width 0 0 false (text-buf-empty))
    [(RenderState buf _) (text-buf-render buf)]))

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

(define (format-doc-seq-len-or-negative [doc : Doc]) : i64
  (match doc
    [(DSeq seq) (doc-seq-len seq)]
    [_ -1]))

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
      (and
        (= (format-doc-seq-len-or-negative doc) 64)
        (= (string-length rendered) 64)
        (= (flat-width doc) 64))]
    [flow-ok : bool
      (and
        (string-eq flat-flow (format-doc-repeat-soft-flat 16))
        (string-eq broken-flow (format-doc-repeat-soft-broken 16)))]
    [right-ok : bool
      (and
        (= (format-doc-seq-len-or-negative right-doc) 31)
        (string-eq right-broken-flow (format-doc-repeat-soft-broken 16)))]
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