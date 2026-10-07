;; doc_extract.tl - Self-hosted TypeLisp doc comment extractor.
;;
;; Public docs use explicit semicolon markers:
;;   ;#   module/file doc line, collected separately
;;   ;:   outer item doc line, attached to the next supported top-level item
;; `;;` and `;` ordinary comments are ignored.
;;
;; Item doc lines stay pending across blank physical lines because the
;; self-hosted formatter may separate doc comment lines. Ordinary comments,
;; module docs, unsupported top-level forms, or other source text clear pending
;; item docs. Pending item docs at EOF are ignored. Declaration identities are read
;; from the captured top-level form with the formatter token lexer so original
;; source text remains available as the item signature.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import source_text_core as source_text)
(import stdlib.vector)

(defenum DocItemKind
  (Define)
  (Function)
  (Extern)
  (DefEnum)
  (DefStruct)
  (DefMacro)
  (GeneratedImport))

(defenum DocItem
  ;; `source-line` is one-based for source declarations and zero for synthetic
  ;; declarations produced from expanded ASTs.
  (Item DocItemKind String String String i64))

(import (vector.vector DocItem core) as doc_item_vec)

(defenum DocExtraction
  (Extraction String doc_item_vec.Vec))

(define (doc-extraction-empty) : DocExtraction
  (Extraction "" (doc_item_vec.new)))

(defenum DocMaybeDeclInfo
  (No)
  (DocDeclInfo DocItemKind String))

(define (doc-kind-tag [kind : DocItemKind]) : i64
  (match kind
    [(Define) 1]
    [(Function) 2]
    [(Extern) 3]
    [(DefEnum) 4]
    [(DefStruct) 5]
    [(DefMacro) 6]
    [(GeneratedImport) 7]))

(define (doc-kind-name [kind : DocItemKind]) : String
  (match kind
    [(Define) "define"]
    [(Function) "define-function"]
    [(Extern) "extern"]
    [(DefEnum) "defenum"]
    [(DefStruct) "defstruct"]
    [(DefMacro) "defmacro"]
    [(GeneratedImport) "generated-module-import"]))

(define (doc-extraction-module-doc [docs : DocExtraction]) : String
  (match docs
    [(Extraction module-doc _) module-doc]))

(define (doc-extraction-items [docs : DocExtraction]) : doc_item_vec.Vec
  (match docs
    [(Extraction _ items) items]))

(define (doc-item-kind [item : DocItem]) : DocItemKind
  (match item
    [(Item kind _ _ _ _) kind]))

(define (doc-item-name [item : DocItem]) : String
  (match item
    [(Item _ name _ _ _) name]))

(define (doc-item-doc [item : DocItem]) : String
  (match item
    [(Item _ _ doc-text _ _) doc-text]))

(define (doc-item-signature [item : DocItem]) : String
  (match item
    [(Item _ _ _ signature _) signature]))

(define (doc-item-source-line [item : DocItem]) : i64
  (match item
    [(Item _ _ _ _ source-line) source-line]))

(define (doc-item-fallback) : DocItem
  (Item (Define) "" "" "" 0))

(define (doc-item-list-count [items : (& items doc_item_vec.Vec)]) : i64
  (doc_item_vec.len (& items)))

(define (doc-item-list-ref [items : (& items doc_item_vec.Vec)] [index : i64]) : DocItem
  (doc_item_vec.get (& items) index (doc-item-fallback)))

(define (doc-item-array-copy-to-list
  [out : (&mut out doc_item_vec.Vec)]
  [items : (__tl_dyn-array DocItem)]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (doc_item_vec.push-ref!
      out
      (owned_view.compiler-owned-array-element-shared-view items index))
    (doc-item-array-copy-to-list out items (+ index 1) count)))

(define (doc-item-array-to-list [items : (__tl_dyn-array DocItem)]) : doc_item_vec.Vec
  (let
    [out : doc_item_vec.Vec (doc_item_vec.with-capacity (array-length items))]
    (doc-item-array-copy-to-list
      (&mut out)
      (owned_view.compiler-owned-shared-view items)
      0
      (array-length items))
    out))

(define (doc-inline-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (doc-newline? [c : char]) : bool
  (or (= c '\n') (= c '\r')))

(define (doc-first-nonspace [src : (& src str)] [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (while keep
      (if (< i end)
        (if (doc-inline-space? (string.string-ref src i))
          (set! i (+ i 1))
          (set! keep false))
        (set! keep false)))
    i))

(define (doc-append-line
  [current : String]
  [has-current : bool]
  [line : String]) : String
  (if has-current
    (str_cat.str-cat current "\n" line)
    line))

(define (doc-comment-body
  [src : (& src str)]
  [line-start : i64]
  [line-end : i64]
  [prefix-len : i64]) : String
  (let
    [body-start : i64 (+ line-start prefix-len)]
    (if (< body-start line-end)
      (if (= (string.string-ref src body-start) ' ')
        (set! body-start (+ body-start 1))
        (set! body-start body-start))
      (set! body-start body-start))
    (string.substring src body-start (- line-end body-start))))

(define (doc-module-doc-prefix-len [src : (& src str)] [line-start : i64]) : i64
  (if (string.is-string-prefix-at src ";#" line-start)
    2
    0))

(define (doc-item-doc-prefix-len [src : (& src str)] [line-start : i64]) : i64
  (if (string.is-string-prefix-at src ";:" line-start)
    2
    0))

(define (doc-scan-string-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [i : i64 (+ start 1)]
    [escaped : bool false]
    [keep : bool true]
    (while keep
      (if (< i n)
        (let
          [c : char (string.string-ref src i)]
          (cond
            [escaped
              (set! escaped false)
              (set! i (+ i 1))]
            [(= c '\\')
              (set! escaped true)
              (set! i (+ i 1))]
            [(= c '"')
              (set! i (+ i 1))
              (set! keep false)]
            [else (set! i (+ i 1))]))
        (set! keep false)))
    i))

(define (doc-scan-form-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [depth : i64 0]
    [keep : bool true]
    (while keep
      (if (< i n)
        (let
          [c : char (string.string-ref src i)]
          (cond
            [(= c ';')
              (set!
                i
                (source_text.next-line-start src (source_text.line-end src i)))]
            [(= c '"') (set! i (doc-scan-string-end src i n))]
            [(= c '\'')
              (set! i (source_text.source-text-skip-char-literal src i n))]
            [(or (= c '(') (= c '['))
              (set! depth (+ depth 1))
              (set! i (+ i 1))]
            [(or (= c ')') (= c ']'))
              (set! depth (- depth 1))
              (set! i (+ i 1))
              (if (<= depth 0)
                (set! keep false)
                (set! keep keep))]
            [else (set! i (+ i 1))]))
        (set! keep false)))
    i))

(define (doc-decl-symbol-char? [c : char]) : bool
  (or
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c 'a') (<= c 'z'))
    (and (>= c '0') (<= c '9'))
    (=
      (if (or
        (= c '-')
        (= c '+')
        (= c '*')
        (= c '/')
        (= c '?')
        (= c '!')
        (= c '>')
        (= c '<')
        (= c '=')
        (= c '_')
        (= c '$')
        (= c '.')
        (= c '%')
        (= c '&'))
        1
        0)
      1)))

(define (doc-decl-symbol-start? [src : (& src str)] [idx : i64] [n : i64]) : bool
  (if (< idx n)
    (let
      [c : char (string.string-ref src idx)]
      (and
        (doc-decl-symbol-char? c)
        (not
          (or
            (and (>= c '0') (<= c '9'))
            (and
              (= c '-')
              (if (< (+ idx 1) n)
                (let
                  [next : char (string.string-ref src (+ idx 1))]
                  (and (>= next '0') (<= next '9')))
                false))))))
    false))

(define (doc-decl-next-token [src : (& src str)] [idx : i64] [n : i64]) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (while keep
      (if (< i n)
        (let
          [c : char (string.string-ref src i)]
          (cond
            [(or (doc-inline-space? c) (doc-newline? c)) (set! i (+ i 1))]
            [(= c ';')
              (set!
                i
                (source_text.next-line-start src (source_text.line-end src i)))]
            [else (set! keep false)]))
        (set! keep false)))
    i))

(define (doc-decl-symbol-end [src : (& src str)] [idx : i64] [n : i64]) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (while keep
      (if (< i n)
        (if (doc-decl-symbol-char? (string.string-ref src i))
          (set! i (+ i 1))
          (set! keep false))
        (set! keep false)))
    i))

(define (doc-info-after-name
  [kind : DocItemKind]
  [src : (& src str)]
  [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [name-idx : i64 (doc-decl-next-token src idx n)]
    (if (doc-decl-symbol-start? src name-idx n)
      (DocDeclInfo
        kind
        (string.substring
          src
          name-idx
          (- (doc-decl-symbol-end src name-idx n) name-idx)))
      (No))))

(define (doc-info-after-define [src : (& src str)] [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (Function) src (+ next 1))
      (doc-info-after-name (Define) src next))))

(define (doc-info-after-extern [src : (& src str)] [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (Extern) src (+ next 1))
      (doc-info-after-name (Extern) src next))))

(define (doc-info-after-defmacro [src : (& src str)] [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (DefMacro) src (+ next 1))
      (No))))

(define (doc-decl-info-at-list [src : (& src str)] [open-idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    (if (if (< open-idx n)
      (= (string.string-ref src open-idx) '(')
      false)
      (let
        [head-idx : i64 (doc-decl-next-token src (+ open-idx 1) n)]
        (if (doc-decl-symbol-start? src head-idx n)
          (let
            [head : String
              (string.substring
                src
                head-idx
                (- (doc-decl-symbol-end src head-idx n) head-idx))]
            [after-head : i64 (doc-decl-symbol-end src head-idx n)]
            (cond
              [(string.eq head "define") (doc-info-after-define src after-head)]
              [(string.eq head "extern") (doc-info-after-extern src after-head)]
              [(string.eq head "defenum")
                (doc-info-after-name (DefEnum) src after-head)]
              [(string.eq head "defstruct")
                (doc-info-after-name (DefStruct) src after-head)]
              [(string.eq head "defmacro")
                (doc-info-after-defmacro src after-head)]
              [else (No)]))
          (No)))
      (No))))

(define (doc-decl-info [signature : (& signature str)]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length signature)]
    [open-idx : i64 (doc-decl-next-token signature 0 n)]
    (doc-decl-info-at-list signature open-idx)))

(define (doc-source-line-at [src : (& src str)] [offset : i64]) : i64
  (let
    [i : i64 0]
    [line : i64 1]
    (while (< i offset)
      (if (= (string.string-ref src i) '\n')
        (set! line (+ line 1))
        unit)
      (set! i (+ i 1)))
    line))

(define (doc-extract-source [src : String]) : DocExtraction
  (let
    [n : i64 (string.string-length src)]
    [i : i64 0]
    [module-doc : String ""]
    [module-has : bool false]
    [pending-doc : String ""]
    [pending-has : bool false]
    [items : (__tl_dyn-array DocItem) (__tl_make-array DocItem 0)]
    (while (< i n)
      (let
        [line-end : i64 (source_text.line-end src i)]
        [line-start : i64 (doc-first-nonspace src i line-end)]
        (if (= line-start line-end)
          (set! i (source_text.next-line-start src line-end))
          (let
            [c : char (string.string-ref src line-start)]
            (if (= c ';')
              (let
                [module-prefix-len : i64
                  (doc-module-doc-prefix-len src line-start)]
                (if (> module-prefix-len 0)
                  (begin
                    (set!
                      module-doc
                      (doc-append-line
                        module-doc
                        module-has
                        (doc-comment-body
                          src
                          line-start
                          line-end
                          module-prefix-len)))
                    (set! module-has true)
                    (set! pending-doc "")
                    (set! pending-has false)
                    (set! i (source_text.next-line-start src line-end)))
                  (let
                    [item-prefix-len : i64
                      (doc-item-doc-prefix-len src line-start)]
                    (if (> item-prefix-len 0)
                      (begin
                        (set!
                          pending-doc
                          (doc-append-line
                            pending-doc
                            pending-has
                            (doc-comment-body
                              src
                              line-start
                              line-end
                              item-prefix-len)))
                        (set! pending-has true)
                        (set! i (source_text.next-line-start src line-end)))
                      (begin
                        (set! pending-doc "")
                        (set! pending-has false)
                        (set! i (source_text.next-line-start src line-end)))))))
              (if (= c '(')
                (let
                  [form-end : i64 (doc-scan-form-end src line-start n)]
                  [signature : String
                    (string.substring src line-start (- form-end line-start))]
                  (if pending-has
                    (match (doc-decl-info signature)
                      [(DocDeclInfo kind name)
                        (__tl_array-push!
                          items
                          (Item
                            kind
                            name
                            (unsafe
                              (ptr-read (ptr-addr-of pending-doc)))
                            signature
                            (doc-source-line-at src line-start)))]
                      [(No) unit])
                    unit)
                  (set! pending-doc "")
                  (set! pending-has false)
                  (set! i form-end))
                (begin
                  (set! pending-doc "")
                  (set! pending-has false)
                  (set! i (source_text.next-line-start src line-end)))))))))
    (Extraction module-doc (doc-item-array-to-list items))))

(define (doc-extract-file [path : String]) : DocExtraction
  (doc-extract-source (byte_buf.to-string (io.read-file path))))