;; lsp_frame_smoke.tl - Runnable smoke for LSP diagnostic metadata adapters.
(import stdlib.json)
(import stdlib.string)
(import "../lsp_frame_core.tl")

(define (lsp-smoke-string-vec-contains? [items : StringVec] [needle : String]) : bool
  (let
    [idx : i64 0]
    [found : bool false]
    (begin
      (while (< idx (string-vec-len items))
        (if (string.string-eq (string-vec-get items idx "") needle)
          (begin
            (set! found true)
            (set! idx (string-vec-len items)))
          (set! idx (+ idx 1))))
      found)))

(define (lsp-completion-smoke-ok?) : bool
  (let
    [src : String
      "(define (square [x : i64]) : i64 (* x x)) (define answer : i64 42)"]
    [names : StringVec (lsp-collect-def-names src (string-vec-new))]
    [keywords : StringVec (lsp-split-spaces (lsp-completion-keywords))]
    [builtins : StringVec (lsp-split-spaces (lsp-completion-builtins))]
    [types : StringVec (lsp-split-spaces (lsp-completion-types))]
    (and
      (lsp-smoke-string-vec-contains? names "square")
      (lsp-smoke-string-vec-contains? names "answer")
      (lsp-smoke-string-vec-contains? keywords "define")
      (lsp-smoke-string-vec-contains? builtins "make-array")
      (lsp-smoke-string-vec-contains? types "i64"))))

(define (lsp-smoke-index-of [haystack : String] [needle : String]) : i64
  (let
    [n : i64 (string-length haystack)]
    [m : i64 (string-length needle)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (if (and (<= (+ i m) n) (is-string-prefix-at (& haystack) (& needle) i))
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (lsp-inlay-smoke-ok?) : bool
  (let
    [src : String
      "(define (main) : i64 (let [total 41] [typed : i64 5] [next (+ total 1)] next))"]
    [total-off : i64 (lsp-smoke-index-of src "41")]
    [typed-off : i64 (lsp-smoke-index-of src "5]")]
    [next-off : i64 (lsp-smoke-index-of src "(+ total 1)")]
    (if (or (< total-off 0) (< typed-off 0) (< next-off 0))
      false
      (begin
        (tc-inlay-hints-enable!)
        (tc-inlay-hint-record! 1 (+ total-off 1) "i64")
        (tc-inlay-hint-record! 1 (+ typed-off 1) "i64")
        (tc-inlay-hint-record! 1 (+ next-off 1) "i64")
        (let
          [hints : json.JsonList (lsp-inlay-build src 0 0)]
          [rendered : String (json.json-stringify (lsp-json-array hints))]
          [type-label : String "\": i64\""]
          [total-pos : String "\"character\":33"]
          [next-pos : String "\"character\":59"]
          (begin
            (tc-inlay-hints-disable!)
            (and
              (= (json.json-list-count hints) 2)
              (string-contains (& rendered) (& type-label))
              (string-contains (& rendered) (& total-pos))
              (string-contains (& rendered) (& next-pos)))))))))

(define (lsp-formatting-smoke-ok?) : bool
  (let
    [messy : String "(define   (f)  :  i64   (+ 1   2))"]
    (match (format-rules-render-source-width-result messy 80)
      [(OkFormatString formatted)
        (let
          [rendered : String
            (json.json-stringify (lsp-formatting-edit messy formatted))]
          [sig : String "(define (f) : i64"]
          [newtext-key : String "\"newText\""]
          [range-key : String "\"range\""]
          (and
            (string-contains (& formatted) (& sig))
            (string-contains (& rendered) (& newtext-key))
            (string-contains (& rendered) (& range-key))))]
      [(ErrFormatString _) false])))

(define (lsp-check-smoke-ok?) : bool
  (let
    [ok-src : String "(define (main) : i64 42)"]
    [bad-src : String "(define (main) : i64 (+ 1 \"two\"))"]
    [ok-result : bool
      (match (compiler-check-source-with-roots "ok.tl" ok-src (string-vec-new))
        [(OkCompilerCheck _) true]
        [(ErrCompilerCheck _) false])]
    [bad-result : bool
      (match (compiler-check-source-with-roots
        "bad.tl"
        bad-src
        (string-vec-new))
        [(OkCompilerCheck _) false]
        [(ErrCompilerCheck _) true])]
    (and ok-result bad-result)))

(define (lsp-get-type-smoke-ok?) : bool
  (let
    [src : String
      "(define (main) : i32 (let [total 41] [next (+ total 1)] next))"]
    [total-off : i64 (lsp-smoke-index-of src "41")]
    (if (< total-off 0)
      false
      (begin
        (tc-inlay-hints-enable!)
        (match (compiler-check-source-with-roots "test.tl" src (string-vec-new))
          [(OkCompilerCheck _) unit]
          [(ErrCompilerCheck _) unit])
        (let
          [size : i64 (tc-inlay-hints-size)]
          [i : i64 0]
          [found-ok : bool false]
          [near-ok : bool false]
          (begin
            (while (and (< i size) (not found-ok))
              (let
                [hint-line : i64 (tc-inlay-hint-line-at i)]
                [hint-col : i64 (tc-inlay-hint-col-at i)]
                [target-line : i64 1]
                [target-col : i64 (+ total-off 1)]
                (begin
                  (if (and (= hint-line target-line) (= hint-col target-col))
                    (set! found-ok (string-eq (tc-inlay-hint-type-at i) "i32"))
                    unit)
                  (set! i (+ i 1)))))
            (let
              [near-idx : i64 (lsp-nearest-inlay-hint-index 1 (+ total-off 3))]
              (if (>= near-idx 0)
                (set!
                  near-ok
                  (string-eq (tc-inlay-hint-type-at near-idx) "i32"))
                unit))
            (tc-inlay-hints-disable!)
            (and found-ok near-ok)))))))

(define (lsp-find-references-smoke-ok?) : bool
  (let
    [src : String
      "(define (foo [x : i64]) : i64 x) (define (bar) : i64 (foo 1))"]
    [refs : json.JsonList
      (lsp-find-references-in-text
        src
        "foo"
        0
        (string-length src)
        json.JsonListNil)]
    [rendered : String (json.json-stringify (lsp-json-array refs))]
    [count-ok : bool (= (json.json-list-count refs) 2)]
    [needle0 : String "\"line\":0"]
    [line0-ok : bool (string-contains (& rendered) (& needle0))]
    (and count-ok line0-ok)))

(define (lsp-scan-decls-cache-local-smoke-ok?) : bool
  (let
    [first : String "(define (alpha) : i64 1)"]
    [second : String
      ";; one\n;; two\n;; three\n\n(define (wide) : i64 2)\n(define (next) : i64 3)"]
    [first-decls : LspDeclList (lsp-scan-decls first)]
    [second-decls : LspDeclList (lsp-scan-decls second)]
    [wide : LspDeclEntry
      (lsp-decl-list-get second-decls 0 (lsp-decl-entry-fallback))]
    [next : LspDeclEntry
      (lsp-decl-list-get second-decls 1 (lsp-decl-entry-fallback))]
    (and
      (= (lsp-decl-list-len first-decls) 1)
      (= (lsp-decl-list-len second-decls) 2)
      (string-eq (struct-get wide name) "wide")
      (= (struct-get wide form-start-line) 5)
      (= (struct-get wide form-start-col) 1)
      (= (struct-get wide name-line) 5)
      (= (struct-get wide name-col) 10)
      (string-eq (struct-get next name) "next")
      (= (struct-get next form-start-line) 6)
      (= (struct-get next form-start-col) 1)
      (= (struct-get next name-line) 6)
      (= (struct-get next name-col) 10))))

(define (main) : i64
  (let
    [base-result : i64 (lsp-diagnostic-metadata-smoke)]
    (if (not (= base-result 42))
      base-result
      (begin
        (unless (lsp-completion-smoke-ok?) (return 6))
        (unless (lsp-inlay-smoke-ok?) (return 7))
        (unless (lsp-formatting-smoke-ok?) (return 8))
        (unless (lsp-check-smoke-ok?) (return 9))
        (unless (lsp-get-type-smoke-ok?) (return 10))
        (unless (lsp-find-references-smoke-ok?) (return 11))
        (unless (lsp-scan-decls-cache-local-smoke-ok?) (return 12))
        42))))