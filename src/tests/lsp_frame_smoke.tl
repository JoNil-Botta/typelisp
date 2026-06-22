;; lsp_frame_smoke.tl - Runnable smoke for LSP diagnostic metadata adapters.
(import stdlib.json)
(import "../lsp_frame_core.tl")

(define (lsp-smoke-string-vec-contains? [items : StringVec] [needle : String]) : bool
  (let
    [idx : i64 0]
    [found : bool false]
    (begin
      (while (< idx (string-vec-len items))
        (begin
          (if (string-eq (string-vec-get items idx "") needle)
            (begin
              (set! found true)
              (set! idx (string-vec-len items)))
            (set! idx (+ idx 1)))))
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

(define (main) : i64
  (let
    [base-result : i64 (lsp-diagnostic-metadata-smoke)]
    (if (not (= base-result 42))
      base-result
      (begin
        (unless (lsp-completion-smoke-ok?) (return 6))
        (unless (lsp-inlay-smoke-ok?) (return 7))
        (unless (lsp-formatting-smoke-ok?) (return 8))
        42))))