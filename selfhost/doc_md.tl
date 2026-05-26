;; doc_md.tl - Constrained-Markdown inline-span renderer for #871's language
;; reference renderer (#1276, inline-span slice). Converts the inline constructs
;; of the SPEC.md/README.md Markdown subset to escaped HTML:
;;   `code`  -> <code>...</code>
;;   *em*    -> <em>...</em>     (also _em_)
;;   [t](u)  -> <a href="u">t</a>
;; All other text is HTML-escaped. An unmatched/degenerate marker (an opening
;; backtick/`*`/`_`/`[` with no valid closer) is emitted literally (escaped),
;; never dropped. The block scanner (`md-scan-blocks` + the `MdBlock` model) and
;; block->HTML rendering are the sibling #1276 slices.
;;
;; Reuses `doc-html-escape` (entity escaping for & < > ") from doc_html.tl.
(import "doc_html.tl")

;;; Index of the first `target` char at or after `from`; returns the string
;;; length (a never-an-index sentinel) when there is no such character.
(define (md-find-char [text : String] [from : i64] [target : char]) : i64
  (let
    [i : i64 from]
    [n : i64 (string-length text)]
    [found : i64 (string-length text)]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (set!
            found
            (if (= (string-ref text i) target)
              i
              found))
          (set! i (+ i 1))))
      found)))

;;; HTML-escape the single character at `idx` (reuses the doc_html entity escaper).
(define (md-escape-char [text : String] [idx : i64]) : String
  (doc-html-escape (substring text idx 1)))

;;; Render a well-formed `[label](url)` link given the `[` at `lbracket`, the `]`
;;; at `jclose`, and the `)` at `kclose`. Label and URL are HTML-escaped.
(define (md-render-link
  [text : String]
  [lbracket : i64]
  [jclose : i64]
  [kclose : i64]) : String
  (let
    [label : String
      (doc-html-escape
        (substring text (+ lbracket 1) (- jclose (+ lbracket 1))))]
    [url : String
      (doc-html-escape (substring text (+ jclose 2) (- kclose (+ jclose 2))))]
    (doc-html-cat5 "<a href=\"" url "\">" label "</a>")))

;;; Inline-render `text` to HTML: `code`, *em*/_em_, [t](u), everything else
;;; HTML-escaped; unmatched markers are emitted literally.
(define (md-render-inline [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (cond
            [(= c #`')
              (let
                [j : i64 (md-find-char text (+ i 1) #`')]
                (if (< j n)
                  (begin
                    (set!
                      out
                      (doc-html-cat3
                        (string-append out "<code>")
                        (doc-html-escape (substring text (+ i 1) (- j (+ i 1))))
                        "</code>"))
                    (set! i (+ j 1)))
                  (begin
                    (set! out (string-append out (md-escape-char text i)))
                    (set! i (+ i 1)))))]
            [(or (= c #*') (= c #_'))
              (let
                [j : i64 (md-find-char text (+ i 1) c)]
                (if (< j n)
                  (begin
                    (set!
                      out
                      (doc-html-cat3
                        (string-append out "<em>")
                        (doc-html-escape (substring text (+ i 1) (- j (+ i 1))))
                        "</em>"))
                    (set! i (+ j 1)))
                  (begin
                    (set! out (string-append out (md-escape-char text i)))
                    (set! i (+ i 1)))))]
            [(= c #[')
              (let
                [jclose : i64 (md-find-char text (+ i 1) #]')]
                (if (< jclose n)
                  (if (< (+ jclose 1) n)
                    (if (= (string-ref text (+ jclose 1)) #(')
                      (let
                        [kclose : i64 (md-find-char text (+ jclose 2) #)')]
                        (if (< kclose n)
                          (begin
                            (set!
                              out
                              (string-append
                                out
                                (md-render-link text i jclose kclose)))
                            (set! i (+ kclose 1)))
                          (begin
                            (set!
                              out
                              (string-append out (md-escape-char text i)))
                            (set! i (+ i 1)))))
                      (begin
                        (set! out (string-append out (md-escape-char text i)))
                        (set! i (+ i 1))))
                    (begin
                      (set! out (string-append out (md-escape-char text i)))
                      (set! i (+ i 1))))
                  (begin
                    (set! out (string-append out (md-escape-char text i)))
                    (set! i (+ i 1)))))]
            [else
              (begin
                (set! out (string-append out (md-escape-char text i)))
                (set! i (+ i 1)))])))
      out)))

;; ---- self-test (driven by doc_md_smoke.tl) ----
(define (compiler-doc-md-self-test) : i64
  (if (string-eq (md-render-inline "plain text") "plain text")
    (if (string-eq (md-render-inline "a `b` c") "a <code>b</code> c")
      (if (string-eq (md-render-inline "x *y* z") "x <em>y</em> z")
        (if (string-eq (md-render-inline "u _v_ w") "u <em>v</em> w")
          (if (string-eq
            (md-render-inline "see [docs](https://x/y)")
            "see <a href=\"https://x/y\">docs</a>")
            (if (string-eq
              (md-render-inline "1 < 2 & 3 > 0")
              "1 &lt; 2 &amp; 3 &gt; 0")
              (if (string-eq
                (md-render-inline "code `a<b`")
                "code <code>a&lt;b</code>")
                (if (string-eq (md-render-inline "bare [link") "bare [link")
                  42
                  7)
                6)
              5)
            4)
          3)
        2)
      1)
    0))