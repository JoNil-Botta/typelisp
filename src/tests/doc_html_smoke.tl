;; doc_html_smoke.tl - Runnable golden smoke for doc_html.tl.
(import "../doc_html.tl")

(define (doc-html-smoke-source) : String
  ";# Module docs with `code`, [links], <tag>, & amp.
;# Quote docs say \"hello\".

;; ignored ordinary comment
;: Global docs for answer mention <answer>, & value, and \"quote\".
(define answer : i64 42)

;: Function docs with `tick` and [arg].
(define (add-one [x : i64]) : i64 (+ x 1))")

(define (doc-html-second-smoke-source) : String
  ";# Second module docs.

(define hidden : i64 1)")

(define (doc-html-smoke) : i64
  (let
    [docs : DocExtraction (doc-extract-source (doc-html-smoke-source))]
    [second-docs : DocExtraction
      (doc-extract-source (doc-html-second-smoke-source))]
    [page : String (doc-html-render-module-page "smoke<&>.tl" docs)]
    [graph : String
      (doc-html-render-module-graph
        (DocModuleCons
          (DocModule "smoke<&>.tl" docs)
          (box
            (DocModuleCons
              (DocModule "second.tl" second-docs)
              (box DocModuleNil)))))]
    (if (and
      (doc-html-require-contains
        page
        "<!doctype html>"
        "doc-html: doctype missing")
      (doc-html-require-contains
        page
        "<title>TypeLisp API: smoke&lt;&amp;&gt;.tl</title>"
        "doc-html: title escaping missing")
      (doc-html-require-contains
        page
        "id=\"tl-smoke-60-38-62-46tl\""
        "doc-html: module anchor missing")
      (doc-html-require-contains
        page
        "Module docs with `code`, [links], &lt;tag&gt;, &amp; amp.<br>"
        "doc-html: module doc escaping missing")
      (doc-html-require-contains
        page
        "Quote docs say &quot;hello&quot;."
        "doc-html: quote escaping missing")
      (doc-html-require-contains
        page
        "id=\"tl-answer\""
        "doc-html: item anchor missing")
      (doc-html-require-contains
        page
        "<code class=\"language-typelisp\">(<span class=\"tl-syn-keyword\">define</span> <span class=\"tl-syn-definition\">answer</span> : <span class=\"tl-syn-type\">i64</span> <span class=\"tl-syn-number\">42</span>)</code>"
        "doc-html: signature code block missing")
      (doc-html-require-contains
        page
        "Global docs for answer mention &lt;answer&gt;, &amp; value, and &quot;quote&quot;."
        "doc-html: item doc escaping missing")
      (doc-html-require-contains
        page
        "href=\"#tl-add-one\""
        "doc-html: item nav link missing")
      (doc-html-require-contains
        graph
        "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">"
        "doc-html: module nav missing")
      (doc-html-require-contains
        graph
        "href=\"#tl-second-46tl\""
        "doc-html: second module nav link missing")
      (doc-html-require-contains
        graph
        "Second module docs."
        "doc-html: second module docs missing")
      (doc-html-require-contains
        graph
        "No documented declarations."
        "doc-html: empty item message missing"))
      42
      0)))

(define (doc-html-syntax-smoke-source) : String
  (str-cat
    ";# docs <tag> &\n"
    "; ordinary comment\n"
    "(define (add-one [x : i64]) : i64\n"
    "  (let ([flag : bool true]\n"
    "        [ch : char '\\n']\n"
    "        [plain-ch : char 'a']\n"
    "        [text : String \"a\\n<>&\"]\n"
    "        [hex : u64 0x2a]\n"
    "        [bin : i64 0b1010]\n"
    "        [flt : f64 -1.25e+3]\n"
    "        [n : i64 -42]\n"
    "        [ptr : (Ptr Point) (ptr-null)])\n"
    "    (when false (return (+ n 1)))\n"
    "    (if (not flag) (box-get (box n)) (custom-call Point text))\n"
    "    (unsafe (ptr-read (& ptr)))))\n"
    "(defstruct Point (x i64))\n"
    "(defenum Shape (Circle i64))\n"))

(define (doc-html-syntax-smoke) : bool
  (let
    [html : String (doc-html-code-block (doc-html-syntax-smoke-source))]
    [tl-html : String (doc-html-code-block-with-info "tl" "" "(if true 1 0)\n")]
    [plain-html : String
      (doc-html-code-block-with-info "text" "m<>&" "(define x : i64 1)\n")]
    (and
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-doc-comment\">;# docs &lt;tag&gt; &amp;</span>"
        "doc-html: documentation comment highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-comment\">; ordinary comment</span>"
        "doc-html: ordinary comment highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-keyword\">define</span> (<span class=\"tl-syn-definition\">add-one</span>"
        "doc-html: keyword or definition-name highlighting missing")
      (doc-html-require-contains
        html
        "[<span class=\"tl-syn-binding\">x</span> : <span class=\"tl-syn-type\">i64</span>]"
        "doc-html: binding or primitive type highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-boolean\">true</span>"
        "doc-html: boolean highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-string\">'\\n'</span>"
        "doc-html: escaped char literal highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-string\">'a'</span>"
        "doc-html: char literal highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-string\">&quot;a<span class=\"tl-syn-escape\">\\n</span>&lt;&gt;&amp;&quot;</span>"
        "doc-html: string or escape highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-number\">0x2a</span>"
        "doc-html: hex number highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-number\">0b1010</span>"
        "doc-html: binary number highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-number\">-1.25e+3</span>"
        "doc-html: float number highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-number\">-42</span>"
        "doc-html: integer number highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-builtin\">ptr-null</span>)"
        "doc-html: builtin highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-operator\">+</span> n <span class=\"tl-syn-number\">1</span>)"
        "doc-html: arithmetic operator highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-operator\">&amp;</span> ptr)"
        "doc-html: reference operator highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-type\">Ptr</span> <span class=\"tl-syn-type\">Point</span>)"
        "doc-html: constructor or user type highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-call\">custom-call</span> <span class=\"tl-syn-type\">Point</span> text)"
        "doc-html: function-call highlighting missing")
      (doc-html-require-contains
        html
        "(<span class=\"tl-syn-keyword\">defstruct</span> <span class=\"tl-syn-definition\">Point</span>"
        "doc-html: type definition highlighting missing")
      (doc-html-require-contains
        tl-html
        "<code class=\"language-tl\">(<span class=\"tl-syn-keyword\">if</span> <span class=\"tl-syn-boolean\">true</span>"
        "doc-html: tl language alias highlighting missing")
      (doc-html-require-contains
        plain-html
        "<pre><code class=\"language-text\" data-meta=\"m&lt;&gt;&amp;\">(define x : i64 1)\n</code></pre>\n"
        "doc-html: non-TypeLisp code fence behavior changed"))))

(define (main) : i64
  (if (and (= (doc-html-smoke) 42) (doc-html-syntax-smoke))
    42
    0))