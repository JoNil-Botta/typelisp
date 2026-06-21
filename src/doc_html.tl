;; doc_html.tl - Deterministic HTML renderer for extracted docs (#870).
;;
;; The renderer stays in TypeLisp and consumes the same extracted documentation
;; model as the Markdown renderer. Anchors intentionally reuse `doc-render-anchor`
;; so standalone item links remain compatible with existing Markdown anchors.
(import "../stdlib/io.tl")
(import "doc_render.tl")
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")

(define (doc-html-escape-one [text : String] [idx : i64]) : String
  (let
    [c : char (string-ref text idx)]
    (cond
      [(= c '&') "&amp;"]
      [(= c '<') "&lt;"]
      [(= c '>') "&gt;"]
      [(= c '"') "&quot;"]
      [else (substring text idx 1)])))

(define (doc-html-escape [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set! out (string-append out (doc-html-escape-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-html-escape-text-one [text : String] [idx : i64]) : String
  (let
    [c : char (string-ref text idx)]
    (if (= c '\n')
      "<br>\n"
      (if (= c '\r')
        ""
        (doc-html-escape-one text idx)))))

(define (doc-html-escape-text [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set! out (string-append out (doc-html-escape-text-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-html-page-open [title : String]) : String
  (str-cat
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"
    (doc-html-escape title)
    "</title>\n<link rel=\"stylesheet\" href=\"typelisp-docs.css\">\n</head>\n<body class=\"tl-docs\">\n"
    ""
    ""))

(define (doc-html-page-close) : String
  "</body>\n</html>\n")

(define (doc-html-header [title : String] [subtitle : String]) : String
  (str-cat
    "<header class=\"tl-doc-header\">\n<h1>"
    (doc-html-escape title)
    "</h1>\n<p><code>"
    (doc-html-escape subtitle)
    "</code></p>\n</header>\n"))

(define (doc-html-doc-block
  [class-name : String]
  [doc-text : String]
  [empty-text : String]) : String
  (if (= (string-length doc-text) 0)
    (str-cat "<p class=\"tl-doc-empty\">" (doc-html-escape empty-text) "</p>\n")
    (str-cat
      "<div class=\""
      class-name
      "\"><p>"
      (doc-html-escape-text doc-text)
      "</p></div>\n")))

(define (doc-html-code-block-meta-attr [meta : String]) : String
  (if (= (string-length meta) 0)
    ""
    (str-cat " data-meta=\"" (doc-html-escape meta) "\"")))

(define (doc-html-syntax-span [class-name : String] [text : String]) : String
  (str-cat "<span class=\"" class-name "\">" (doc-html-escape text) "</span>"))

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
    [n : i64 (string-length source)]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (doc-html-syntax-token-delim? (string-ref source i))
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (doc-html-syntax-number-start? [source : String] [start : i64]) : bool
  (let
    [n : i64 (string-length source)]
    (if (>= start n)
      false
      (let
        [c : char (string-ref source start)]
        [prev-ok : bool
          (if (= start 0)
            true
            (not (doc-html-syntax-wordish? (string-ref source (- start 1)))))]
        (and
          prev-ok
          (or
            (doc-html-syntax-digit? c)
            (and
              (= c '-')
              (< (+ start 1) n)
              (doc-html-syntax-digit? (string-ref source (+ start 1))))))))))

(define (doc-html-syntax-string-end [source : String] [start : i64]) : i64
  (let
    [i : i64 (+ start 1)]
    [n : i64 (string-length source)]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (let
          [c : char (string-ref source i)]
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
      [payload : char (string-ref source (+ start 1))]
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
            (doc-html-syntax-hex-digit? (string-ref source (+ start 2)))
            (doc-html-syntax-hex-digit? (string-ref source (+ start 3))))
            (+ start 4)
            start)]
        [else start]))))

(define (doc-html-syntax-render-string
  [source : String]
  [start : i64]
  [end : i64]) : String
  (let
    [i : i64 start]
    [out : String "<span class=\"tl-syn-string\">"]
    (begin
      (while (< i end)
        (if (= (string-ref source i) '\\')
          (let
            [escape-end : i64 (doc-html-syntax-valid-escape-end source i end)]
            (if (> escape-end i)
              (begin
                (set!
                  out
                  (str-cat
                    out
                    "<span class=\"tl-syn-escape\">"
                    (doc-html-escape (substring source i (- escape-end i)))
                    "</span>"))
                (set! i escape-end))
              (begin
                (set! out (string-append out (doc-html-escape-one source i)))
                (set! i (+ i 1)))))
          (begin
            (set! out (string-append out (doc-html-escape-one source i)))
            (set! i (+ i 1)))))
      (string-append out "</span>"))))

(define (doc-html-syntax-char-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

(define (doc-html-syntax-char-literal-end [source : String] [start : i64]) : i64
  (let
    [n : i64 (string-length source)]
    (if (< (+ start 1) n)
      (let
        [payload : char (string-ref source (+ start 1))]
        (cond
          [(= payload '\\')
            (if (and
              (< (+ start 3) n)
              (doc-html-syntax-char-escape? (string-ref source (+ start 2)))
              (= (string-ref source (+ start 3)) '\''))
              (+ start 4)
              start)]
          [(or (= payload '\'') (= payload '\n') (= payload '\r')) start]
          [else
            (if (and (< (+ start 2) n) (= (string-ref source (+ start 2)) '\''))
              (+ start 3)
              start)]))
      start)))

(define (doc-html-syntax-line-end [source : String] [start : i64]) : i64
  (let
    [i : i64 start]
    [n : i64 (string-length source)]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (or (= (string-ref source i) '\n') (= (string-ref source i) '\r'))
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (doc-html-syntax-list-member? [items : String] [token : String]) : bool
  (let
    [needle : String (str-cat "|" token "|")]
    (string-contains (& items) (& needle))))

(define (doc-html-syntax-keyword? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|comptime-decls|comptime-decl|comptime|defdispatch|defstruct|defmacro|defenum|define|include-str|include-bin|spmd-broadcast|spmd-reduce|with-arena|with-escape|with|unquote-splicing|unquote|quasiquote|quote|foreach|unsafe|return|export|extern|import|module|lambda|begin|while|match|unless|when|cond|cast|test|try|set!|type|init|ann|let|and|or|if|"
    token))

(define (doc-html-syntax-builtin? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|ptr-addr-of|ptr-offset|ptr-write!|ptr-null?|ptr-null|ptr-read|ptr-cast|ptr->int|int->ptr|array-push!|array-set!|array-data|array-ref|make-array|tuple-ref|struct-get|string-from-bytes|string-data|program-argc|program-argv|program-envp|cpuid-eax|cpuid-ebx|cpuid-ecx|cpuid-edx|xgetbv|syscall|box-get|box|array|tuple|"
    token))

(define (doc-html-syntax-operator? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|->|!=|<=|>=|+|-|*|/|%|=|<|>|bit-and|bit-or|bit-xor|bit-not|shl|shr|not|neg|&mut|&|"
    token))

(define (doc-html-syntax-boolean? [token : String]) : bool
  (or (string-eq token "true") (string-eq token "false")))

(define (doc-html-syntax-type? [token : String]) : bool
  (doc-html-syntax-list-member?
    "|i64|i32|i16|i8|u64|u32|u16|u8|f64|f32|bool|char|String|str|unit|never|Array|Tuple|Box|MutPtr|Ptr|"
    token))

(define (doc-html-syntax-head-position? [source : String] [start : i64]) : bool
  (and (> start 0) (= (string-ref source (- start 1)) '(')))

(define (doc-html-syntax-skip-back-spaces [source : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (doc-html-syntax-space? (string-ref source i))
          (set! i (- i 1))
          (set! done true)))
      i)))

(define (doc-html-syntax-word-start-back [source : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    [done : bool false]
    (begin
      (while (and (not done) (>= i 0))
        (if (doc-html-syntax-ident-part? (string-ref source i))
          (set! i (- i 1))
          (set! done true)))
      (+ i 1))))

(define (doc-html-syntax-preceding-form [source : String] [start : i64]) : String
  (let
    [before : i64 (doc-html-syntax-skip-back-spaces source (- start 1))]
    (begin
      (if (and (>= before 0) (= (string-ref source before) '('))
        (set! before (doc-html-syntax-skip-back-spaces source (- before 1)))
        unit)
      (if (< before 0)
        ""
        (let
          [word-start : i64 (doc-html-syntax-word-start-back source before)]
          (if (and
            (> word-start 0)
            (= (string-ref source (- word-start 1)) '('))
            (substring source word-start (+ (- before word-start) 1))
            ""))))))

(define (doc-html-syntax-definition-name? [source : String] [start : i64]) : bool
  (let
    [form : String (doc-html-syntax-preceding-form source start)]
    (or
      (string-eq form "define")
      (string-eq form "defmacro")
      (string-eq form "defdispatch")
      (string-eq form "defstruct")
      (string-eq form "defenum"))))

(define (doc-html-syntax-token-class
  [source : String]
  [start : i64]
  [token : String]) : String
  (let
    [head : bool (doc-html-syntax-head-position? source start)]
    [before : i64 (doc-html-syntax-skip-back-spaces source (- start 1))]
    (cond
      [(and head (doc-html-syntax-keyword? token)) "tl-syn-keyword"]
      [(and head (doc-html-syntax-builtin? token)) "tl-syn-builtin"]
      [(and head (doc-html-syntax-operator? token)) "tl-syn-operator"]
      [(doc-html-syntax-definition-name? source start) "tl-syn-definition"]
      [(and (>= before 0) (= (string-ref source before) '[')) "tl-syn-binding"]
      [(doc-html-syntax-boolean? token) "tl-syn-boolean"]
      [(doc-html-syntax-type? token) "tl-syn-type"]
      [(doc-html-syntax-upper? (string-ref token 0)) "tl-syn-type"]
      [(and head (doc-html-syntax-ident-start? (string-ref token 0)))
        "tl-syn-call"]
      [else ""])))

(define (doc-html-syntax-language? [language : String]) : bool
  (or (string-eq language "typelisp") (string-eq language "tl")))

(define (doc-html-highlight-typelisp [source : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length source)]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref source i)]
          (cond
            [(= c ';')
              (let
                [end : i64 (doc-html-syntax-line-end source i)]
                [line : String (substring source i (- end i))]
                [class-name : String
                  (if (and
                    (< (+ i 1) n)
                    (or
                      (= (string-ref source (+ i 1)) '#')
                      (= (string-ref source (+ i 1)) ':')))
                    "tl-syn-doc-comment"
                    "tl-syn-comment")]
                (begin
                  (set!
                    out
                    (string-append out (doc-html-syntax-span class-name line)))
                  (set! i end)))]
            [(= c '"')
              (let
                [end : i64 (doc-html-syntax-string-end source i)]
                (begin
                  (set!
                    out
                    (string-append
                      out
                      (doc-html-syntax-render-string source i end)))
                  (set! i end)))]
            [(= c '\'')
              (let
                [end : i64 (doc-html-syntax-char-literal-end source i)]
                (if (> end i)
                  (begin
                    (set!
                      out
                      (string-append
                        out
                        (doc-html-syntax-span
                          "tl-syn-string"
                          (substring source i (- end i)))))
                    (set! i end))
                  (begin
                    (set!
                      out
                      (string-append out (doc-html-escape-one source i)))
                    (set! i (+ i 1)))))]
            [(doc-html-syntax-number-start? source i)
              (let
                [end : i64 (doc-html-syntax-token-end source i)]
                (begin
                  (set!
                    out
                    (string-append
                      out
                      (doc-html-syntax-span
                        "tl-syn-number"
                        (substring source i (- end i)))))
                  (set! i end)))]
            [(doc-html-syntax-token-start? c)
              (let
                [end : i64 (doc-html-syntax-token-end source i)]
                [token : String (substring source i (- end i))]
                [class-name : String
                  (doc-html-syntax-token-class source i token)]
                (begin
                  (set!
                    out
                    (string-append
                      out
                      (if (= (string-length class-name) 0)
                        (doc-html-escape token)
                        (doc-html-syntax-span class-name token))))
                  (set! i end)))]
            [else
              (begin
                (set! out (string-append out (doc-html-escape-one source i)))
                (set! i (+ i 1)))])))
      out)))

(define (doc-html-code-block-with-info
  [language : String]
  [meta : String]
  [source : String]) : String
  (str-cat
    "<pre><code class=\"language-"
    (doc-html-escape language)
    "\""
    (doc-html-code-block-meta-attr meta)
    ">"
    (if (doc-html-syntax-language? language)
      (doc-html-highlight-typelisp source)
      (doc-html-escape source))
    "</code></pre>\n"))

(define (doc-html-code-block [source : String]) : String
  (doc-html-code-block-with-info "typelisp" "" source))

(define (doc-html-item-nav-entry [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    (str-cat
      "<li><a href=\"#"
      anchor
      "\"><code>"
      (doc-html-escape name)
      "</code></a></li>\n")))

(define (doc-html-item-nav-entries [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [(DocItemCons item rest)
      (string-append
        (doc-html-item-nav-entry item)
        (doc-html-item-nav-entries (box-get rest)))]))

(define (doc-html-item-nav [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [_
      (str-cat
        "<nav class=\"tl-doc-item-nav\" aria-label=\"Declarations\">\n<h3>Declarations</h3>\n<ul>\n"
        (doc-html-item-nav-entries items)
        "</ul>\n</nav>\n")]))

(define (doc-html-item [item : DocItem]) : String
  (let
    [name : String (doc-item-name item)]
    [anchor : String (doc-render-anchor (doc-item-name item))]
    [kind : String (doc-kind-name (doc-item-kind item))]
    (str-cat
      "<a id=\""
      anchor
      "\"></a>\n<section class=\"tl-doc-item\">\n<h3><a href=\"#"
      anchor
      "\">"
      (doc-html-escape name)
      "</a></h3>\n<dl class=\"tl-doc-meta\"><dt>Kind</dt><dd>"
      (doc-html-escape kind)
      "</dd></dl>\n"
      (doc-html-code-block (doc-item-signature item))
      (doc-html-doc-block
        "tl-doc-item-text"
        (doc-item-doc item)
        "No item docs.")
      "</section>\n")))

(define (doc-html-item-list [items : DocItemList]) : String
  (match items
    [(DocItemNil) ""]
    [(DocItemCons item rest)
      (string-append (doc-html-item item) (doc-html-item-list (box-get rest)))]))

(define (doc-html-items [items : DocItemList]) : String
  (match items
    [(DocItemNil) "<p class=\"tl-doc-empty\">No documented declarations.</p>\n"]
    [_ (doc-html-item-list items)]))

(define (doc-html-module-nav-entry [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [anchor : String (doc-render-anchor (doc-module-path module))]
    (str-cat
      "<li><a href=\"#"
      anchor
      "\">"
      (doc-html-escape path)
      "</a></li>\n")))

(define (doc-html-module-nav-entries [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) ""]
    [(DocModuleCons module rest)
      (string-append
        (doc-html-module-nav-entry module)
        (doc-html-module-nav-entries (box-get rest)))]))

(define (doc-html-module-nav [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) "<p class=\"tl-doc-empty\">No modules.</p>\n"]
    [_
      (str-cat
        "<nav class=\"tl-doc-module-nav\" aria-label=\"Modules\">\n<h2>Modules</h2>\n<ul>\n"
        (doc-html-module-nav-entries modules)
        "</ul>\n</nav>\n")]))

(define (doc-html-module-section [module : DocModule]) : String
  (let
    [path : String (doc-module-path module)]
    [docs : DocExtraction (doc-module-docs module)]
    [anchor : String (doc-render-anchor (doc-module-path module))]
    (str-cat
      "<section class=\"tl-doc-module\" id=\""
      anchor
      "\">\n<h2><a href=\"#"
      anchor
      "\">"
      (doc-html-escape path)
      "</a></h2>\n<p class=\"tl-doc-source\"><code>"
      (doc-html-escape path)
      "</code></p>\n"
      (doc-html-doc-block
        "tl-doc-module-text"
        (doc-extraction-module-doc docs)
        "No module docs.")
      (doc-html-item-nav (doc-extraction-items docs))
      (doc-html-items (doc-extraction-items docs))
      "</section>\n")))

(define (doc-html-module-sections [modules : DocModuleList]) : String
  (match modules
    [(DocModuleNil) ""]
    [(DocModuleCons module rest)
      (string-append
        (doc-html-module-section module)
        (doc-html-module-sections (box-get rest)))]))

(define (doc-html-render-module-page [path : String] [docs : DocExtraction]) : String
  (let
    [title : String (str-cat "TypeLisp API: " path "")]
    (str-cat
      (doc-html-page-open title)
      (doc-html-header "TypeLisp API" path)
      "<main>\n"
      (doc-html-module-section (DocModule path docs))
      "</main>\n"
      (doc-html-page-close))))

(define (doc-html-render-source [path : String] [source : String]) : String
  (doc-html-render-module-page path (doc-extract-source source)))

(define (doc-html-render-module-graph [modules : DocModuleList]) : String
  (str-cat
    (doc-html-page-open "TypeLisp API")
    (doc-html-header "TypeLisp API" "module index")
    (doc-html-module-nav modules)
    "<main>\n"
    (doc-html-module-sections modules)
    "</main>\n"
    (doc-html-page-close)))

(define (doc-html-require-contains
  [rendered : String]
  [needle : String]
  [message : String]) : bool
  (if (doc-string-contains? rendered needle)
    true
    (begin
      (panic message)
      ;; lint-allow: unreachable-code
      false)))