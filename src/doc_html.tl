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

(define (doc-html-syntax-binary-digit? [c : char]) : bool
  (or (= c '0') (= c '1')))

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

(define (doc-html-syntax-scan-digits
  [source : String]
  [start : i64]
  [base : i64]) : i64
  (let
    [i : i64 start]
    [n : i64 (string-length source)]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (let
          [c : char (string-ref source i)]
          (if (if (= base 2)
            (doc-html-syntax-binary-digit? c)
            (if (= base 16)
              (doc-html-syntax-hex-digit? c)
              (doc-html-syntax-digit? c)))
            (set! i (+ i 1))
            (set! done true))))
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

(define (doc-html-syntax-number-end [source : String] [start : i64]) : i64
  (let
    [n : i64 (string-length source)]
    [i : i64 start]
    (begin
      (unless (doc-html-syntax-number-start? source start) (return start))
      (if (= (string-ref source i) '-')
        (set! i (+ i 1))
        unit)
      (if (and
        (< (+ i 2) n)
        (= (string-ref source i) '0')
        (or
          (= (string-ref source (+ i 1)) 'x')
          (= (string-ref source (+ i 1)) 'X')))
        (let
          [digits-start : i64 (+ i 2)]
          [digits-end : i64 (doc-html-syntax-scan-digits source (+ i 2) 16)]
          (if (> digits-end digits-start)
            digits-end
            start))
        (if (and
          (< (+ i 2) n)
          (= (string-ref source i) '0')
          (or
            (= (string-ref source (+ i 1)) 'b')
            (= (string-ref source (+ i 1)) 'B')))
          (let
            [digits-start : i64 (+ i 2)]
            [digits-end : i64 (doc-html-syntax-scan-digits source (+ i 2) 2)]
            (if (> digits-end digits-start)
              digits-end
              start))
          (let
            [digits-end : i64 (doc-html-syntax-scan-digits source i 10)]
            [out-end : i64 (doc-html-syntax-scan-digits source i 10)]
            (begin
              (set! out-end digits-end)
              (if (and
                (< (+ out-end 1) n)
                (= (string-ref source out-end) '.')
                (doc-html-syntax-digit? (string-ref source (+ out-end 1))))
                (begin
                  (set!
                    out-end
                    (doc-html-syntax-scan-digits source (+ out-end 1) 10))
                  (if (and
                    (< (+ out-end 1) n)
                    (or
                      (= (string-ref source out-end) 'e')
                      (= (string-ref source out-end) 'E')))
                    (let
                      [exp-start : i64
                        (if (and
                          (< (+ out-end 2) n)
                          (or
                            (= (string-ref source (+ out-end 1)) '+')
                            (= (string-ref source (+ out-end 1)) '-')))
                          (+ out-end 2)
                          (+ out-end 1))]
                      [exp-end : i64
                        (doc-html-syntax-scan-digits
                          source
                          (if (and
                            (< (+ out-end 2) n)
                            (or
                              (= (string-ref source (+ out-end 1)) '+')
                              (= (string-ref source (+ out-end 1)) '-')))
                            (+ out-end 2)
                            (+ out-end 1))
                          10)]
                      (if (> exp-end exp-start)
                        (set! out-end exp-end)
                        unit))
                    unit))
                unit)
              out-end)))))))

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

(define (doc-html-syntax-char-literal-class [source : String] [start : i64]) : String
  (if (and
    (< (+ start 1) (string-length source))
    (= (string-ref source (+ start 1)) '\\'))
    "tl-syn-escape"
    "tl-syn-char"))

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

(define (doc-html-syntax-keyword? [token : String]) : bool
  (or
    (string-eq token "comptime-decls")
    (string-eq token "comptime-decl")
    (string-eq token "comptime")
    (string-eq token "defdispatch")
    (string-eq token "defstruct")
    (string-eq token "defmacro")
    (string-eq token "defenum")
    (string-eq token "define")
    (string-eq token "include-str")
    (string-eq token "include-bin")
    (string-eq token "spmd-broadcast")
    (string-eq token "spmd-reduce")
    (string-eq token "with-arena")
    (string-eq token "with-escape")
    (string-eq token "with")
    (string-eq token "unquote-splicing")
    (string-eq token "unquote")
    (string-eq token "quasiquote")
    (string-eq token "quote")
    (string-eq token "foreach")
    (string-eq token "unsafe")
    (string-eq token "return")
    (string-eq token "export")
    (string-eq token "extern")
    (string-eq token "import")
    (string-eq token "module")
    (string-eq token "lambda")
    (string-eq token "begin")
    (string-eq token "while")
    (string-eq token "match")
    (string-eq token "unless")
    (string-eq token "when")
    (string-eq token "cond")
    (string-eq token "cast")
    (string-eq token "test")
    (string-eq token "try")
    (string-eq token "set!")
    (string-eq token "type")
    (string-eq token "init")
    (string-eq token "ann")
    (string-eq token "let")
    (string-eq token "and")
    (string-eq token "or")
    (string-eq token "if")))

(define (doc-html-syntax-builtin? [token : String]) : bool
  (or
    (string-eq token "ptr-addr-of")
    (string-eq token "ptr-offset")
    (string-eq token "ptr-write!")
    (string-eq token "ptr-null?")
    (string-eq token "ptr-null")
    (string-eq token "ptr-read")
    (string-eq token "ptr-cast")
    (string-eq token "ptr->int")
    (string-eq token "int->ptr")
    (string-eq token "array-push!")
    (string-eq token "array-set!")
    (string-eq token "array-data")
    (string-eq token "array-ref")
    (string-eq token "make-array")
    (string-eq token "tuple-ref")
    (string-eq token "struct-get")
    (string-eq token "string-from-bytes")
    (string-eq token "string-data")
    (string-eq token "program-argc")
    (string-eq token "program-argv")
    (string-eq token "program-envp")
    (string-eq token "cpuid-eax")
    (string-eq token "cpuid-ebx")
    (string-eq token "cpuid-ecx")
    (string-eq token "cpuid-edx")
    (string-eq token "xgetbv")
    (string-eq token "syscall")
    (string-eq token "box-get")
    (string-eq token "box")
    (string-eq token "array")
    (string-eq token "tuple")))

(define (doc-html-syntax-operator? [token : String]) : bool
  (or
    (string-eq token "->")
    (string-eq token "!=")
    (string-eq token "<=")
    (string-eq token ">=")
    (string-eq token "+")
    (string-eq token "-")
    (string-eq token "*")
    (string-eq token "/")
    (string-eq token "%")
    (string-eq token "=")
    (string-eq token "<")
    (string-eq token ">")
    (string-eq token "bit-and")
    (string-eq token "bit-or")
    (string-eq token "bit-xor")
    (string-eq token "bit-not")
    (string-eq token "shl")
    (string-eq token "shr")
    (string-eq token "not")
    (string-eq token "neg")
    (string-eq token "&mut")
    (string-eq token "&")))

(define (doc-html-syntax-boolean? [token : String]) : bool
  (or (string-eq token "true") (string-eq token "false")))

(define (doc-html-syntax-type? [token : String]) : bool
  (or
    (string-eq token "i64")
    (string-eq token "i32")
    (string-eq token "i16")
    (string-eq token "i8")
    (string-eq token "u64")
    (string-eq token "u32")
    (string-eq token "u16")
    (string-eq token "u8")
    (string-eq token "f64")
    (string-eq token "f32")
    (string-eq token "bool")
    (string-eq token "char")
    (string-eq token "String")
    (string-eq token "str")
    (string-eq token "unit")
    (string-eq token "never")
    (string-eq token "Array")
    (string-eq token "Tuple")
    (string-eq token "Box")
    (string-eq token "MutPtr")
    (string-eq token "Ptr")))

(define (doc-html-syntax-function-def-form? [token : String]) : bool
  (or
    (string-eq token "define")
    (string-eq token "defmacro")
    (string-eq token "defdispatch")))

(define (doc-html-syntax-type-def-form? [token : String]) : bool
  (or (string-eq token "defstruct") (string-eq token "defenum")))

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

(define (doc-html-syntax-definition-function-name?
  [source : String]
  [start : i64]) : bool
  (doc-html-syntax-function-def-form?
    (doc-html-syntax-preceding-form source start)))

(define (doc-html-syntax-definition-type-name? [source : String] [start : i64]) : bool
  (doc-html-syntax-type-def-form? (doc-html-syntax-preceding-form source start)))

(define (doc-html-syntax-binding-name? [source : String] [start : i64]) : bool
  (let
    [before : i64 (doc-html-syntax-skip-back-spaces source (- start 1))]
    (and (>= before 0) (= (string-ref source before) '['))))

(define (doc-html-syntax-user-type? [token : String]) : bool
  (and
    (> (string-length token) 0)
    (doc-html-syntax-upper? (string-ref token 0))))

(define (doc-html-syntax-function-call-token? [token : String]) : bool
  (and
    (> (string-length token) 0)
    (doc-html-syntax-ident-start? (string-ref token 0))))

(define (doc-html-syntax-token-class
  [source : String]
  [start : i64]
  [token : String]) : String
  (cond
    [(and
        (doc-html-syntax-head-position? source start)
        (doc-html-syntax-keyword? token))
      "tl-syn-keyword"]
    [(and
        (doc-html-syntax-head-position? source start)
        (doc-html-syntax-builtin? token))
      "tl-syn-builtin"]
    [(and
        (doc-html-syntax-head-position? source start)
        (doc-html-syntax-operator? token))
      "tl-syn-operator"]
    [(doc-html-syntax-definition-function-name? source start)
      "tl-syn-definition"]
    [(doc-html-syntax-definition-type-name? source start) "tl-syn-definition"]
    [(doc-html-syntax-binding-name? source start) "tl-syn-binding"]
    [(doc-html-syntax-boolean? token) "tl-syn-boolean"]
    [(doc-html-syntax-type? token) "tl-syn-type"]
    [(doc-html-syntax-user-type? token) "tl-syn-type"]
    [(and
        (doc-html-syntax-head-position? source start)
        (doc-html-syntax-function-call-token? token))
      "tl-syn-call"]
    [else ""]))

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
                          (doc-html-syntax-char-literal-class source i)
                          (substring source i (- end i)))))
                    (set! i end))
                  (begin
                    (set!
                      out
                      (string-append out (doc-html-escape-one source i)))
                    (set! i (+ i 1)))))]
            [(doc-html-syntax-number-start? source i)
              (let
                [end : i64 (doc-html-syntax-number-end source i)]
                (if (> end i)
                  (begin
                    (set!
                      out
                      (string-append
                        out
                        (doc-html-syntax-span
                          "tl-syn-number"
                          (substring source i (- end i)))))
                    (set! i end))
                  (begin
                    (set!
                      out
                      (string-append out (doc-html-escape-one source i)))
                    (set! i (+ i 1)))))]
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

(define (doc-html-vscode-grammar-expected-patterns) : String
  (str-cat
    "  \"patterns\": [\n"
    "    { \"include\": \"#comments\" },\n"
    "    { \"include\": \"#strings\" },\n"
    "    { \"include\": \"#char-literals\" },\n"
    "    { \"include\": \"#numbers\" },\n"
    "    { \"include\": \"#keywords\" },\n"
    "    { \"include\": \"#builtins\" },\n"
    "    { \"include\": \"#operators\" },\n"
    "    { \"include\": \"#constants\" },\n"
    "    { \"include\": \"#types\" },\n"
    "    { \"include\": \"#definition-name\" },\n"
    "    { \"include\": \"#bindings\" },\n"
    "    { \"include\": \"#user-types\" },\n"
    "    { \"include\": \"#function-call\" }\n"
    "  ],"))

(define (doc-html-vscode-grammar-drift-ok?) : bool
  (doc-html-require-contains
    (read-file "tools/vs-code-extension/syntaxes/typelisp.tmLanguage.json")
    (doc-html-vscode-grammar-expected-patterns)
    "doc-html: VS Code grammar categories changed; update docs highlighter"))

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
        "<span class=\"tl-syn-escape\">'\\n'</span>"
        "doc-html: escaped char literal highlighting missing")
      (doc-html-require-contains
        html
        "<span class=\"tl-syn-char\">'a'</span>"
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
        "doc-html: non-TypeLisp code fence behavior changed")
      (doc-html-vscode-grammar-drift-ok?))))

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
        "doc-html: empty item message missing")
      (doc-html-syntax-smoke))
      42
      0)))