;; doc_html.tl - Deterministic HTML renderer for extracted docs.
;;
;; The renderer stays in TypeLisp and consumes the same extracted documentation
;; model as the Markdown renderer. Anchors intentionally reuse `doc-render-anchor`
;; so standalone item links remain compatible with existing Markdown anchors.
(import compiler_owned_view as owned_view)
(import stdlib.io)
(import stdlib.vector)
(import doc_render)
(import doc_extract)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define (doc-html-escape-one [text : (& text str)] [idx : i64]) : String
  (let
    [c : char (string.string-ref text idx)]
    (cond
      [(= c '&') "&amp;"]
      [(= c '<') "&lt;"]
      [(= c '>') "&gt;"]
      [(= c '"') "&quot;"]
      [else (string.substring text idx 1)])))

(define (doc-html-escape [text : (& text str)]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-with-capacity n)]
    (begin
      (while (< i n)
        (begin
          (byte_buf.byte-buf-builder-append-string
            (&mut out)
            (doc-html-escape-one text i))
          (set! i (+ i 1))))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (doc-html-escape-text-one [text : (& text str)] [idx : i64]) : String
  (let
    [c : char (string.string-ref text idx)]
    (if (= c '\n')
      "<br>\n"
      (if (= c '\r')
        ""
        (doc-html-escape-one text idx)))))

(define (doc-html-escape-text [text : (& text str)]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-with-capacity n)]
    (begin
      (while (< i n)
        (begin
          (byte_buf.byte-buf-builder-append-string
            (&mut out)
            (doc-html-escape-text-one text i))
          (set! i (+ i 1))))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (doc-html-page-open [title : String]) : String
  (str_cat.str-cat
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"
    (doc-html-escape title)
    "</title>\n<link rel=\"stylesheet\" href=\"typelisp-docs.css\">\n</head>\n<body class=\"tl-docs\">\n"
    ""
    ""))

(define (doc-html-page-open-with-metadata
  [title : String]
  [compiler-identity : String]
  [source-identity : String]
  [package-identity : String]) : String
  (str_cat.str-cat
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"
    (doc-html-escape title)
    "</title>\n<meta name=\"typelisp-compiler-identity\" content=\""
    (doc-html-escape compiler-identity)
    "\">\n<meta name=\"typelisp-source-identity\" content=\""
    (doc-html-escape source-identity)
    "\">\n<meta name=\"typelisp-package-identity\" content=\""
    (doc-html-escape package-identity)
    "\">\n<link rel=\"stylesheet\" href=\"typelisp-docs.css\">\n<script defer src=\"typelisp-docs-search-index.js\"></script>\n<script defer src=\"typelisp-docs.js\"></script>\n</head>\n<body class=\"tl-docs\">\n"
    ""
    ""))

(define (doc-html-page-close) : String
  "</body>\n</html>\n")

(define (doc-html-header [title : String] [subtitle : String]) : String
  (str_cat.str-cat
    "<header class=\"tl-doc-header\">\n<h1>"
    (doc-html-escape title)
    "</h1>\n<p><code>"
    (doc-html-escape subtitle)
    "</code></p>\n</header>\n"))

(define (doc-html-doc-block
  [class-name : String]
  [doc-text : String]
  [empty-text : String]) : String
  (if (= (string.string-length doc-text) 0)
    (str_cat.str-cat
      "<p class=\"tl-doc-empty\">"
      (doc-html-escape empty-text)
      "</p>\n")
    (str_cat.str-cat
      "<div class=\""
      class-name
      "\"><p>"
      (doc-html-escape-text doc-text)
      "</p></div>\n")))

(define (doc-html-code-block-meta-attr [meta : String]) : String
  (if (= (string.string-length meta) 0)
    ""
    (str_cat.str-cat " data-meta=\"" (doc-html-escape meta) "\"")))

(define (doc-html-syntax-span [class-name : String] [text : String]) : String
  (str_cat.str-cat
    "<span class=\""
    class-name
    "\">"
    (doc-html-escape text)
    "</span>"))

(define (doc-html-syntax-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

(define (doc-html-syntax-alpha? [c : char]) : bool
  (or (and (>= c 'A') (<= c 'Z')) (and (>= c 'a') (<= c 'z'))))

(define (doc-html-syntax-upper? [c : char]) : bool
  (and (>= c 'A') (<= c 'Z')))

(define (doc-html-syntax-digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (doc-html-syntax-hex-digit? [c : char]) : bool
  (or
    (doc-html-syntax-digit? c)
    (and (>= c 'A') (<= c 'F'))
    (and (>= c 'a') (<= c 'f'))))

(define (doc-html-syntax-ident-start? [c : char]) : bool
  (or (doc-html-syntax-alpha? c) (= c '_')))

(define (doc-html-syntax-ident-part? [c : char]) : bool
  (or
    (doc-html-syntax-ident-start? c)
    (doc-html-syntax-digit? c)
    (= c '!')
    (= c '?')
    (= c '*')
    (= c '/')
    (= c '<')
    (= c '>')
    (= c '=')
    (= c '+')
    (= c '-')))

(define (doc-html-syntax-wordish? [c : char]) : bool
  (or (doc-html-syntax-alpha? c) (doc-html-syntax-digit? c) (= c '_') (= c '-')))

(define (doc-html-syntax-operator-start? [c : char]) : bool
  (or
    (= c '!')
    (= c '<')
    (= c '>')
    (= c '=')
    (= c '+')
    (= c '-')
    (= c '*')
    (= c '/')
    (= c '%')
    (= c '&')))

(define (doc-html-syntax-token-start? [c : char]) : bool
  (or (doc-html-syntax-ident-start? c) (doc-html-syntax-operator-start? c)))

(define (doc-html-syntax-token-delim? [c : char]) : bool
  (or
    (doc-html-syntax-space? c)
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c '"')
    (= c '\'')
    (= c ';')))

(define (doc-html-syntax-token-end [source : String] [start : i64]) : i64
  (let
    [i : i64 start]
    [n : i64 (string.string-length source)]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (doc-html-syntax-token-delim? (string.string-ref source i))
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (doc-html-syntax-number-start? [source : String] [start : i64]) : bool
  (let
    [n : i64 (string.string-length source)]
    (if (>= start n)
      false
      (let
        [c : char (string.string-ref source start)]
        [prev-ok : bool
          (if (= start 0)
            true
            (not
              (doc-html-syntax-wordish? (string.string-ref source (- start 1)))))]
        (and
          prev-ok
          (or
            (doc-html-syntax-digit? c)
            (and
              (= c '-')
              (< (+ start 1) n)
              (doc-html-syntax-digit? (string.string-ref source (+ start 1))))))))))

(define (doc-html-syntax-string-end [source : String] [start : i64]) : i64
  (let
    [i : i64 (+ start 1)]
    [n : i64 (string.string-length source)]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (let
          [c : char (string.string-ref source i)]
          (if (= c '\\')
            (set! i (+ i 2))
            (if (= c '"')
              (begin
                (set! done true)
                (set! i (+ i 1)))
              (set! i (+ i 1))))))
      i)))

(define (doc-html-syntax-valid-escape-end
  [source : String]
  [start : i64]
  [limit : i64]) : i64
  (if (>= (+ start 1) limit)
    start
    (let
      [payload : char (string.string-ref source (+ start 1))]
      (cond
        [(or
            (= payload 'n')
            (= payload 't')
            (= payload 'r')
            (= payload '0')
            (= payload '\\')
            (= payload '"')
            (= payload '\''))
          (+ start 2)]
        [(= payload 'x')
          (if (and
            (< (+ start 3) limit)
            (doc-html-syntax-hex-digit? (string.string-ref source (+ start 2)))
            (doc-html-syntax-hex-digit? (string.string-ref source (+ start 3))))
            (+ start 4)
            start)]
        [else start]))))

(define (doc-html-syntax-render-string
  [source : String]
  [start : i64]
  [end : i64]) : String
  (let
    [i : i64 start]
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity (- end start))]
    (begin
      (byte_buf.byte-buf-builder-append-string
        (&mut out)
        "<span class=\"tl-syn-string\">")
      (while (< i end)
        (if (= (string.string-ref source i) '\\')
          (let
            [escape-end : i64
              (doc-html-syntax-valid-escape-end
                (owned_view.compiler-owned-shared-view source)
                i
                end)]
            (if (> escape-end i)
              (begin
                (byte_buf.byte-buf-builder-append-string
                  (&mut out)
                  "<span class=\"tl-syn-escape\">")
                (byte_buf.byte-buf-builder-append-string
                  (&mut out)
                  (doc-html-escape (string.substring source i (- escape-end i))))
                (byte_buf.byte-buf-builder-append-string (&mut out) "</span>")
                (set! i escape-end))
              (begin
                (byte_buf.byte-buf-builder-append-string
                  (&mut out)
                  (doc-html-escape-one
                    (owned_view.compiler-owned-shared-view source)
                    i))
                (set! i (+ i 1)))))
          (begin
            (byte_buf.byte-buf-builder-append-string
              (&mut out)
              (doc-html-escape-one
                (owned_view.compiler-owned-shared-view source)
                i))
            (set! i (+ i 1)))))
      (byte_buf.byte-buf-builder-append-string (&mut out) "</span>")
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (doc-html-syntax-char-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

(define (doc-html-syntax-char-literal-end [source : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    (if (< (+ start 1) n)
      (let
        [payload : char (string.string-ref source (+ start 1))]
        (cond
          [(= payload '\\')
            (if (and
              (< (+ start 3) n)
              (doc-html-syntax-char-escape?
                (string.string-ref source (+ start 2)))
              (= (string.string-ref source (+ start 3)) '\''))
              (+ start 4)
              start)]
          [(or (= payload '\'') (= payload '\n') (= payload '\r')) start]
          [else
            (if (and
              (< (+ start 2) n)
              (= (string.string-ref source (+ start 2)) '\''))
              (+ start 3)
              start)]))
      start)))

(define (doc-html-syntax-line-end [source : String] [start : i64]) : i64
  (let
    [i : i64 start]
    [n : i64 (string.string-length source)]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (or
          (= (string.string-ref source i) '\n')
          (= (string.string-ref source i) '\r'))
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (doc-html-syntax-list-member? [items : String] [token : String]) : bool
  (let
    [needle : String (str_cat.str-cat "|" token "|")]
    (string.contains (& items) (& needle))))

(define (doc-html-syntax-keyword? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|comptime|defdispatch|defstruct|defmacro|defenum|define|include-str|include-bin|spmd-shuffle|spmd-broadcast|spmd-reduce|with-arena|with-escape|with|unquote-splicing|unquote|quasiquote|quote|foreach|unsafe|return|export|extern|import|module|lambda|begin|while|match|unless|when|cond|cast|test|try|set!|type|init|ann|let|and|or|if|"
    token))

(define (doc-html-syntax-builtin? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|ptr-addr-of|ptr-offset|ptr-write!|ptr-null?|ptr-null|ptr-read|ptr-cast|ptr->int|int->ptr|array-ref|tuple-ref|deref|string-from-bytes|string-data|program-argc|program-argv|program-envp|cpuid-eax|cpuid-ebx|cpuid-ecx|cpuid-edx|xgetbv|syscall|box|array|tuple|"
    token))

(define (doc-html-syntax-operator? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|->|!=|<=|>=|+|-|*|/|%|=|<|>|bit-and|bit-or|bit-xor|bit-not|shl|shr|not|neg|&mut|&|"
    token))

(define (doc-html-syntax-boolean? [token : String]) : bool
  (or (string.eq token "true") (string.eq token "false")))

(define (doc-html-syntax-type? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|i64|i32|i16|i8|u64|u32|u16|u8|f64|f32|bool|char|String|str|unit|never|Array|Tuple|Box|MutPtr|Ptr|"
    token))

(define (doc-html-syntax-head-position? [source : String] [start : i64]) : bool
  (and (> start 0) (= (string.string-ref source (- start 1)) '(')))

(define (doc-html-syntax-skip-back-spaces [source : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (doc-html-syntax-space? (string.string-ref source i))
          (set! i (- i 1))
          (set! done true)))
      i)))

(define (doc-html-syntax-word-start-back [source : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (doc-html-syntax-ident-part? (string.string-ref source i))
          (set! i (- i 1))
          (set! done true)))
      (+ i 1))))

(define (doc-html-syntax-preceding-form [source : String] [start : i64]) : String
  (let
    [before : i64
      (doc-html-syntax-skip-back-spaces
        (owned_view.compiler-owned-shared-view source)
        (- start 1))]
    (begin
      (if (and (>= before 0) (= (string.string-ref source before) '('))
        (set!
          before
          (doc-html-syntax-skip-back-spaces
            (owned_view.compiler-owned-shared-view source)
            (- before 1)))
        unit)
      (if (< before 0)
        ""
        (let
          [word-start : i64
            (doc-html-syntax-word-start-back
              (owned_view.compiler-owned-shared-view source)
              before)]
          (if (and
            (> word-start 0)
            (= (string.string-ref source (- word-start 1)) '('))
            (string.substring source word-start (+ (- before word-start) 1))
            ""))))))

(define (doc-html-syntax-definition-name? [source : String] [start : i64]) : bool
  (let
    [form : String (doc-html-syntax-preceding-form source start)]
    (or
      (string.eq form "define")
      (string.eq form "defmacro")
      (string.eq form "defdispatch")
      (string.eq form "defstruct")
      (string.eq form "defenum"))))

(define (doc-html-syntax-token-class
  [source : String]
  [start : i64]
  [token : String]) : String
  (let
    [head : bool
      (doc-html-syntax-head-position?
        (owned_view.compiler-owned-shared-view source)
        start)]
    [before : i64
      (doc-html-syntax-skip-back-spaces
        (owned_view.compiler-owned-shared-view source)
        (- start 1))]
    (cond
      [(and
          head
          (doc-html-syntax-keyword?
            (owned_view.compiler-owned-shared-view token)))
        "tl-syn-keyword"]
      [(and
          head
          (doc-html-syntax-builtin?
            (owned_view.compiler-owned-shared-view token)))
        "tl-syn-builtin"]
      [(and
          head
          (doc-html-syntax-operator?
            (owned_view.compiler-owned-shared-view token)))
        "tl-syn-operator"]
      [(doc-html-syntax-definition-name?
          (owned_view.compiler-owned-shared-view source)
          start)
        "tl-syn-definition"]
      [(and (>= before 0) (= (string.string-ref source before) '['))
        "tl-syn-binding"]
      [(doc-html-syntax-boolean? (owned_view.compiler-owned-shared-view token))
        "tl-syn-boolean"]
      [(doc-html-syntax-type? (owned_view.compiler-owned-shared-view token))
        "tl-syn-type"]
      [(doc-html-syntax-upper? (string.string-ref token 0)) "tl-syn-type"]
      [(and head (doc-html-syntax-ident-start? (string.string-ref token 0)))
        "tl-syn-call"]
      [else ""])))

(define (doc-html-syntax-language? [language : String]) : bool
  (or (string.eq language "typelisp") (string.eq language "tl")))

(define (doc-html-highlight-typelisp [source : String]) : String
  (let
    [i : i64 0]
    [n : i64
      (string.string-length (owned_view.compiler-owned-shared-view source))]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-with-capacity n)]
    (begin
      (while (< i n)
        (let
          [c : char
            (string.string-ref (owned_view.compiler-owned-shared-view source) i)]
          (cond
            [(= c ';')
              (let
                [end : i64
                  (doc-html-syntax-line-end
                    (owned_view.compiler-owned-shared-view source)
                    i)]
                [line : String
                  (string.substring
                    (owned_view.compiler-owned-shared-view source)
                    i
                    (- end i))]
                [class-name : String
                  (if (and
                    (< (+ i 1) n)
                    (or
                      (=
                        (string.string-ref
                          (owned_view.compiler-owned-shared-view source)
                          (+ i 1))
                        '#')
                      (=
                        (string.string-ref
                          (owned_view.compiler-owned-shared-view source)
                          (+ i 1))
                        ':')))
                    "tl-syn-doc-comment"
                    "tl-syn-comment")]
                (begin
                  (byte_buf.byte-buf-builder-append-string
                    (&mut out)
                    (doc-html-syntax-span class-name line))
                  (set! i end)))]
            [(= c '"')
              (let
                [end : i64
                  (doc-html-syntax-string-end
                    (owned_view.compiler-owned-shared-view source)
                    i)]
                (begin
                  (byte_buf.byte-buf-builder-append-string
                    (&mut out)
                    (doc-html-syntax-render-string
                      (owned_view.compiler-owned-shared-view source)
                      i
                      end))
                  (set! i end)))]
            [(= c '\'')
              (let
                [end : i64
                  (doc-html-syntax-char-literal-end
                    (owned_view.compiler-owned-shared-view source)
                    i)]
                (if (> end i)
                  (begin
                    (byte_buf.byte-buf-builder-append-string
                      (&mut out)
                      (doc-html-syntax-span
                        "tl-syn-string"
                        (string.substring
                          (owned_view.compiler-owned-shared-view source)
                          i
                          (- end i))))
                    (set! i end))
                  (begin
                    (byte_buf.byte-buf-builder-append-string
                      (&mut out)
                      (doc-html-escape-one
                        (owned_view.compiler-owned-shared-view source)
                        i))
                    (set! i (+ i 1)))))]
            [(doc-html-syntax-number-start?
                (owned_view.compiler-owned-shared-view source)
                i)
              (let
                [end : i64
                  (doc-html-syntax-token-end
                    (owned_view.compiler-owned-shared-view source)
                    i)]
                (begin
                  (byte_buf.byte-buf-builder-append-string
                    (&mut out)
                    (doc-html-syntax-span
                      "tl-syn-number"
                      (string.substring
                        (owned_view.compiler-owned-shared-view source)
                        i
                        (- end i))))
                  (set! i end)))]
            [(doc-html-syntax-token-start? c)
              (let
                [end : i64
                  (doc-html-syntax-token-end
                    (owned_view.compiler-owned-shared-view source)
                    i)]
                [token : String
                  (string.substring
                    (owned_view.compiler-owned-shared-view source)
                    i
                    (- end i))]
                [class-name : String
                  (doc-html-syntax-token-class
                    (owned_view.compiler-owned-shared-view source)
                    i
                    (owned_view.compiler-owned-shared-view token))]
                (begin
                  (byte_buf.byte-buf-builder-append-string
                    (&mut out)
                    (if (= (string.string-length class-name) 0)
                      (doc-html-escape token)
                      (doc-html-syntax-span class-name token)))
                  (set! i end)))]
            [else
              (begin
                (byte_buf.byte-buf-builder-append-string
                  (&mut out)
                  (doc-html-escape-one
                    (owned_view.compiler-owned-shared-view source)
                    i))
                (set! i (+ i 1)))])))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (doc-html-code-block-with-info
  [language : String]
  [meta : String]
  [source : String]) : String
  (str_cat.str-cat
    "<pre><code class=\"language-"
    (doc-html-escape (owned_view.compiler-owned-shared-view language))
    "\""
    (doc-html-code-block-meta-attr meta)
    ">"
    (if (doc-html-syntax-language? language)
      (doc-html-highlight-typelisp source)
      (doc-html-escape source))
    "</code></pre>\n"))

(define (doc-html-code-block [source : String]) : String
  (doc-html-code-block-with-info "typelisp" "" source))

(define (doc-html-item-nav-entry [path : String] [item : doc_extract.DocItem]) : String
  (let
    [name : String
      (doc_extract.doc-item-name (owned_view.compiler-owned-shared-view item))]
    [anchor : String (doc_render.doc-render-item-anchor path item)]
    (str_cat.str-cat
      "<li><a href=\"#"
      (owned_view.compiler-owned-shared-view anchor)
      "\"><code>"
      (doc-html-escape name)
      "</code></a></li>\n")))

(define (doc-html-item-nav-entries-from
  [path : String]
  [items : doc_item_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-html-item-nav-entry
        (owned_view.compiler-owned-shared-view path)
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          index))
      (doc-html-item-nav-entries-from path items (+ index 1) count))))

(define (doc-html-item-nav-entries [path : String] [items : doc_item_vec.Vec]) : String
  (doc-html-item-nav-entries-from
    path
    (owned_view.compiler-owned-shared-view items)
    0
    (doc_extract.doc-item-list-count items)))

(define (doc-html-item-nav [path : String] [items : doc_item_vec.Vec]) : String
  (if (=
    (doc_extract.doc-item-list-count
      (owned_view.compiler-owned-shared-view items))
    0)
    ""
    (str_cat.str-cat
      "<nav class=\"tl-doc-item-nav\" aria-label=\"Declarations\">\n<h3>Declarations</h3>\n<ul>\n"
      (doc-html-item-nav-entries path items)
      "</ul>\n</nav>\n")))

(define (doc-html-source-link [source-url : String] [line : i64]) : String
  (if (= (string.string-length source-url) 0)
    ""
    (str_cat.str-cat
      "<dt>Source</dt><dd><a class=\"tl-doc-source-link\" href=\""
      (doc-html-escape source-url)
      (if (> line 0)
        (str_cat.str-cat "#L" (string.int->string line) "")
        "")
      "\">view source"
      (if (> line 0)
        (str_cat.str-cat " (line " (string.int->string line) ")")
        "")
      "</a></dd>")))

(define (doc-html-item
  [path : String]
  [source-url : String]
  [item : doc_extract.DocItem]) : String
  (let
    [name : String
      (doc_extract.doc-item-name (owned_view.compiler-owned-shared-view item))]
    [anchor : String
      (doc_render.doc-render-item-anchor
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view item))]
    [kind : String
      (doc_extract.doc-kind-name
        (doc_extract.doc-item-kind (owned_view.compiler-owned-shared-view item)))]
    (str_cat.str-cat
      "<a id=\""
      (owned_view.compiler-owned-shared-view anchor)
      "\"></a>\n<section class=\"tl-doc-item\" data-doc-identity=\""
      (owned_view.compiler-owned-shared-view anchor)
      "\">\n<h3><a href=\"#"
      (owned_view.compiler-owned-shared-view anchor)
      "\">"
      (doc-html-escape name)
      "</a></h3>\n<dl class=\"tl-doc-meta\"><dt>Kind</dt><dd>"
      (doc-html-escape kind)
      "</dd>"
      (doc-html-source-link
        source-url
        (doc_extract.doc-item-source-line
          (owned_view.compiler-owned-shared-view item)))
      "</dl>\n"
      (doc-html-code-block
        (doc_extract.doc-item-signature
          (owned_view.compiler-owned-shared-view item)))
      (doc-html-doc-block
        "tl-doc-item-text"
        (doc_extract.doc-item-doc item)
        "No item docs.")
      "</section>\n")))

(define (doc-html-item-list-from
  [path : String]
  [source-url : String]
  [items : doc_item_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-html-item
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view source-url)
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          index))
      (doc-html-item-list-from path source-url items (+ index 1) count))))

(define (doc-html-item-list
  [path : String]
  [source-url : String]
  [items : doc_item_vec.Vec]) : String
  (doc-html-item-list-from
    path
    source-url
    (owned_view.compiler-owned-shared-view items)
    0
    (doc_extract.doc-item-list-count items)))

(define (doc-html-items
  [path : String]
  [source-url : String]
  [items : doc_item_vec.Vec]) : String
  (if (=
    (doc_extract.doc-item-list-count
      (owned_view.compiler-owned-shared-view items))
    0)
    "<p class=\"tl-doc-empty\">No documented declarations.</p>\n"
    (doc-html-item-list
      path
      source-url
      (owned_view.compiler-owned-shared-view items))))

(define (doc-html-json-escape-one [text : (& text str)] [idx : i64]) : String
  (let
    [c : char (string.string-ref text idx)]
    (cond
      [(= c '"') "\\\""]
      [(= c '\\') "\\\\"]
      [(= c '\n') "\\n"]
      [(= c '\r') "\\r"]
      [(= c '\t') "\\t"]
      ;; Avoid closing an inline script if a future consumer embeds the same
      ;; deterministic JSON payload instead of loading it as an asset.
      [(= c '<') "\\u003c"]
      [(= c '>') "\\u003e"]
      [(= c '&') "\\u0026"]
      [else (string.substring text idx 1)])))

(define (doc-html-json-string [text : (& text str)]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity (+ n 2))]
    (begin
      (byte_buf.byte-buf-builder-append-string (&mut out) "\"")
      (while (< i n)
        (begin
          (byte_buf.byte-buf-builder-append-string
            (&mut out)
            (doc-html-json-escape-one text i))
          (set! i (+ i 1))))
      (byte_buf.byte-buf-builder-append-string (&mut out) "\"")
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (doc-html-short-doc [doc-text : String]) : String
  (let
    [n : i64 (string.string-length doc-text)]
    (if (> n 240)
      (string.substring doc-text 0 240)
      doc-text)))

(define (doc-html-search-record
  [identity : String]
  [kind : String]
  [label : String]
  [module-path : String]
  [href : String]
  [signature : String]
  [doc-text : String]
  [source-line : i64]) : String
  (str_cat.str-cat
    "{\"identity\":"
    (doc-html-json-string identity)
    ",\"kind\":"
    (doc-html-json-string kind)
    ",\"label\":"
    (doc-html-json-string label)
    ",\"module\":"
    (doc-html-json-string module-path)
    ",\"href\":"
    (doc-html-json-string href)
    ",\"signature\":"
    (doc-html-json-string signature)
    ",\"docs\":"
    (doc-html-json-string (doc-html-short-doc doc-text))
    ",\"sourceLine\":"
    (string.int->string source-line)
    "}"))

(define (doc-html-search-item-record
  [page : String]
  [path : String]
  [item : doc_extract.DocItem]) : String
  (let
    [identity : String
      (doc_render.doc-render-item-anchor
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view item))]
    (doc-html-search-record
      (owned_view.compiler-owned-shared-view identity)
      (doc_extract.doc-kind-name
        (doc_extract.doc-item-kind (owned_view.compiler-owned-shared-view item)))
      (doc_extract.doc-item-name (owned_view.compiler-owned-shared-view item))
      (owned_view.compiler-owned-shared-view path)
      (str_cat.str-cat page "#" identity)
      (doc_extract.doc-item-signature
        (owned_view.compiler-owned-shared-view item))
      (doc_extract.doc-item-doc (owned_view.compiler-owned-shared-view item))
      (doc_extract.doc-item-source-line item))))

(define (doc-html-search-item-records-from
  [page : String]
  [path : String]
  [items : doc_item_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      ","
      (doc-html-search-item-record
        (owned_view.compiler-owned-shared-view page)
        (owned_view.compiler-owned-shared-view path)
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          index))
      (doc-html-search-item-records-from page path items (+ index 1) count))))

;; Emit one module record followed by its declarations. The caller supplies
;; modules in deterministic site order and wraps the records in a JSON array.
(define (doc-html-search-records-for-module
  [page : String]
  [module : doc_render.DocModule]) : String
  (let
    [path : String
      (doc_render.doc-module-path
        (owned_view.compiler-owned-shared-view module))]
    [docs : doc_extract.DocExtraction
      (doc_render.doc-module-docs
        (owned_view.compiler-owned-shared-view module))]
    [items : doc_item_vec.Vec
      (doc_extract.doc-extraction-items
        (owned_view.compiler-owned-shared-view docs))]
    [item-count : i64
      (doc_extract.doc-item-list-count
        (owned_view.compiler-owned-shared-view items))]
    (str_cat.str-cat
      (doc-html-search-record
        (doc_render.doc-render-anchor
          (owned_view.compiler-owned-shared-view path))
        "module"
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view path)
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view page)
          "#"
          (doc_render.doc-render-anchor
            (owned_view.compiler-owned-shared-view path)))
        ""
        (doc_extract.doc-extraction-module-doc docs)
        1)
      (doc-html-search-item-records-from page path items 0 item-count))))

(define (doc-html-module-nav-entry [module : doc_render.DocModule]) : String
  (let
    [path : String
      (doc_render.doc-module-path
        (owned_view.compiler-owned-shared-view module))]
    [anchor : String
      (doc_render.doc-render-anchor (doc_render.doc-module-path module))]
    (str_cat.str-cat
      "<li><a href=\"#"
      anchor
      "\">"
      (doc-html-escape (owned_view.compiler-owned-shared-view path))
      "</a></li>\n")))

(define (doc-html-module-nav-entries-from
  [modules : doc_module_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-html-module-nav-entry
        (doc_render.doc-module-list-ref
          (owned_view.compiler-owned-shared-view modules)
          index))
      (doc-html-module-nav-entries-from modules (+ index 1) count))))

(define (doc-html-module-nav-entries [modules : doc_module_vec.Vec]) : String
  (doc-html-module-nav-entries-from
    (owned_view.compiler-owned-shared-view modules)
    0
    (doc_render.doc-module-list-count modules)))

(define (doc-html-module-nav [modules : doc_module_vec.Vec]) : String
  (if (=
    (doc_render.doc-module-list-count
      (owned_view.compiler-owned-shared-view modules))
    0)
    "<p class=\"tl-doc-empty\">No modules.</p>\n"
    (str_cat.str-cat
      "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">\n<h2>Modules</h2>\n<ul>\n"
      (doc-html-module-nav-entries modules)
      "</ul>\n</nav>\n")))

(define (doc-html-module-section-with-source-url
  [module : doc_render.DocModule]
  [source-url : String]) : String
  (let
    [path : String
      (doc_render.doc-module-path
        (owned_view.compiler-owned-shared-view module))]
    [docs : doc_extract.DocExtraction
      (doc_render.doc-module-docs
        (owned_view.compiler-owned-shared-view module))]
    [anchor : String
      (doc_render.doc-render-anchor
        (doc_render.doc-module-path
          (owned_view.compiler-owned-shared-view module)))]
    (str_cat.str-cat
      "<section class=\"tl-doc-module\" data-module-identity=\""
      (doc-html-escape path)
      "\" id=\""
      (owned_view.compiler-owned-shared-view anchor)
      "\">\n<h2><a href=\"#"
      (owned_view.compiler-owned-shared-view anchor)
      "\">"
      (doc-html-escape (owned_view.compiler-owned-shared-view path))
      "</a></h2>\n<p class=\"tl-doc-source\">"
      (if (= (string.string-length source-url) 0)
        (str_cat.str-cat "<code>" (doc-html-escape path) "</code>")
        (str_cat.str-cat
          "<a class=\"tl-doc-source-link\" href=\""
          (doc-html-escape source-url)
          "\"><code>"
          (doc-html-escape path)
          "</code></a>"))
      "</p>\n"
      (doc-html-doc-block
        "tl-doc-module-text"
        (doc_extract.doc-extraction-module-doc
          (owned_view.compiler-owned-shared-view docs))
        "No module docs.")
      (doc-html-item-nav
        (owned_view.compiler-owned-shared-view path)
        (doc_extract.doc-extraction-items
          (owned_view.compiler-owned-shared-view docs)))
      (doc-html-items
        path
        (owned_view.compiler-owned-shared-view source-url)
        (doc_extract.doc-extraction-items
          (owned_view.compiler-owned-shared-view docs)))
      "</section>\n")))

(define (doc-html-module-section [module : doc_render.DocModule]) : String
  (doc-html-module-section-with-source-url module ""))

(define (doc-html-module-sections-from
  [modules : doc_module_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-html-module-section
        (doc_render.doc-module-list-ref
          (owned_view.compiler-owned-shared-view modules)
          index))
      (doc-html-module-sections-from
        (owned_view.compiler-owned-shared-view modules)
        (+ index 1)
        count))))

(define (doc-html-module-sections [modules : doc_module_vec.Vec]) : String
  (doc-html-module-sections-from
    (owned_view.compiler-owned-shared-view modules)
    0
    (doc_render.doc-module-list-count
      (owned_view.compiler-owned-shared-view modules))))

(define (doc-html-render-module-page
  [path : String]
  [docs : doc_extract.DocExtraction]) : String
  (let
    [title : String
      (str_cat.str-cat
        "TypeLisp API: "
        (owned_view.compiler-owned-shared-view path)
        "")]
    (str_cat.str-cat
      (doc-html-page-open title)
      (doc-html-header
        "TypeLisp API"
        (owned_view.compiler-owned-shared-view path))
      "<main>\n"
      (doc-html-module-section (doc_render.DocModule.Module path docs))
      "</main>\n"
      (doc-html-page-close))))

(define (doc-html-render-source [path : String] [source : String]) : String
  (doc-html-render-module-page path (doc_extract.doc-extract-source source)))

(define (doc-html-render-module-graph [modules : doc_module_vec.Vec]) : String
  (str_cat.str-cat
    (doc-html-page-open "TypeLisp API")
    (doc-html-header "TypeLisp API" "module index")
    (doc-html-module-nav (owned_view.compiler-owned-shared-view modules))
    "<main>\n"
    (doc-html-module-sections modules)
    "</main>\n"
    (doc-html-page-close)))

(defmacro (doc-html-require-contains
  [rendered : Expr]
  [needle : Expr]
  [message : Expr]) : Expr
  `(if (doc_extract.doc-string-contains? ,rendered ,needle)
    true
    (io.panic ,message)))