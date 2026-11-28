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
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf)
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

(define (doc-extraction-empty)
  (:cold) : DocExtraction
  (Extraction "" (doc_item_vec.new)))

(defenum DocMaybeDeclInfo
  (No)
  (DocDeclInfo DocItemKind String))

(define (doc-kind-tag [kind : DocItemKind])
  (:cold) : i64
  (match kind
    [(Define) 1]
    [(Function) 2]
    [(Extern) 3]
    [(DefEnum) 4]
    [(DefStruct) 5]
    [(DefMacro) 6]
    [(GeneratedImport) 7]))

(define (doc-kind-name [kind : DocItemKind])
  (:cold) : String
  (match kind
    [(Define) "define"]
    [(Function) "define-function"]
    [(Extern) "extern"]
    [(DefEnum) "defenum"]
    [(DefStruct) "defstruct"]
    [(DefMacro) "defmacro"]
    [(GeneratedImport) "generated-module-import"]))

(define (doc-extraction-module-doc [docs : DocExtraction])
  (:cold) : String
  (match docs
    [(Extraction module-doc _) module-doc]))

(define (doc-extraction-items [docs : DocExtraction])
  (:cold) : doc_item_vec.Vec
  (match docs
    [(Extraction _ items) items]))

(define (doc-item-kind [item : DocItem])
  (:cold) : DocItemKind
  (match item
    [(Item kind _ _ _ _) kind]))

(define (doc-item-name [item : DocItem])
  (:cold) : String
  (match item
    [(Item _ name _ _ _) name]))

(define (doc-item-doc [item : DocItem])
  (:cold) : String
  (match item
    [(Item _ _ doc-text _ _) doc-text]))

(define (doc-item-signature [item : DocItem])
  (:cold) : String
  (match item
    [(Item _ _ _ signature _) signature]))

(define (doc-item-source-line [item : DocItem])
  (:cold) : i64
  (match item
    [(Item _ _ _ _ source-line) source-line]))

(define (doc-item-fallback)
  (:cold) : DocItem
  (Item (Define) "" "" "" 0))

(define (doc-item-copy [item : (& item DocItem)])
  (:cold) : DocItem
  (match item
    [(Item kind name doc-text signature source-line)
      (Item
        kind
        (string.copy name)
        (string.copy doc-text)
        (string.copy signature)
        source-line)]))

(define (doc-item-list-count [items : (& items doc_item_vec.Vec)])
  (:cold) : i64
  (doc_item_vec.len (& items)))

(define (doc-item-list-ref [items : (& items doc_item_vec.Vec)] [index : i64])
  (:cold) : DocItem
  (if (and (>= index 0) (< index (doc_item_vec.len items)))
    (let
      [view : (& items (Slice DocItem)) (doc_item_vec.view items)]
      (doc-item-copy (& (array-ref view index))))
    (doc-item-fallback)))

(define (doc-item-array-copy-to-list
  [out : (&mut out doc_item_vec.Vec)]
  [items : (__tl_dyn-array DocItem)]
  [index : i64]
  [count : i64])
  (:cold) : unit
  (unless
    (>= index count)
    (doc_item_vec.push-ref!
      out
      (owned_view.compiler-owned-array-element-shared-view items index))
    (doc-item-array-copy-to-list out items (+ index 1) count)))

(define (doc-item-array-to-list [items : (__tl_dyn-array DocItem)])
  (:cold) : doc_item_vec.Vec
  (let
    [out : doc_item_vec.Vec (doc_item_vec.with-capacity (array-length items))]
    (doc-item-array-copy-to-list
      (&mut out)
      (owned_view.compiler-owned-shared-view items)
      0
      (array-length items))
    out))

(define (doc-inline-space? [c : char])
  (:cold) : bool
  (or (= c ' ') (= c '\t')))

(define (doc-newline? [c : char])
  (:cold) : bool
  (or (= c '\n') (= c '\r')))

(define (doc-first-nonspace [src : (& src str)] [start : i64] [end : i64])
  (:cold) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (while keep
      (if (< i end)
        (if (doc-inline-space? (string.string-ref src i))
          (+= i 1)
          (set! keep false))
        (set! keep false)))
    i))

(define (doc-append-line
  [current : String]
  [has-current : bool]
  [line : String])
  (:cold) : String
  (if has-current
    (str_cat.str-cat current "\n" line)
    line))

(define (doc-comment-body
  [src : (& src str)]
  [line-start : i64]
  [line-end : i64]
  [prefix-len : i64])
  (:cold) : String
  (let
    [body-start : i64 (+ line-start prefix-len)]
    (if (< body-start line-end)
      (if (= (string.string-ref src body-start) ' ')
        (+= body-start 1)
        (set! body-start body-start))
      (set! body-start body-start))
    (string.substring src body-start (- line-end body-start))))

(define (doc-module-doc-prefix-len [src : (& src str)] [line-start : i64])
  (:cold) : i64
  (if (string.is-string-prefix-at src ";#" line-start)
    2
    0))

(define (doc-item-doc-prefix-len [src : (& src str)] [line-start : i64])
  (:cold) : i64
  (if (string.is-string-prefix-at src ";:" line-start)
    2
    0))

(define (doc-scan-string-end [src : (& src str)] [start : i64] [n : i64])
  (:cold) : i64
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
              (+= i 1)]
            [(= c '\\')
              (set! escaped true)
              (+= i 1)]
            [(= c '"')
              (+= i 1)
              (set! keep false)]
            [else (+= i 1)]))
        (set! keep false)))
    i))

(define (doc-scan-form-end [src : (& src str)] [start : i64] [n : i64])
  (:cold) : i64
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
              (+= depth 1)
              (+= i 1)]
            [(or (= c ')') (= c ']'))
              (-= depth 1)
              (+= i 1)
              (if (<= depth 0)
                (set! keep false)
                (set! keep keep))]
            [else (+= i 1)]))
        (set! keep false)))
    i))

(define (doc-decl-symbol-char? [c : char])
  (:cold) : bool
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

(define (doc-decl-symbol-start? [src : (& src str)] [idx : i64] [n : i64])
  (:cold) : bool
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

(define (doc-decl-next-token [src : (& src str)] [idx : i64] [n : i64])
  (:cold) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (while keep
      (if (< i n)
        (let
          [c : char (string.string-ref src i)]
          (cond
            [(or (doc-inline-space? c) (doc-newline? c)) (+= i 1)]
            [(= c ';')
              (set!
                i
                (source_text.next-line-start src (source_text.line-end src i)))]
            [else (set! keep false)]))
        (set! keep false)))
    i))

(define (doc-decl-symbol-end [src : (& src str)] [idx : i64] [n : i64])
  (:cold) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (while keep
      (if (< i n)
        (if (doc-decl-symbol-char? (string.string-ref src i))
          (+= i 1)
          (set! keep false))
        (set! keep false)))
    i))

(define (doc-info-after-name
  [kind : DocItemKind]
  [src : (& src str)]
  [idx : i64])
  (:cold) : DocMaybeDeclInfo
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

(define (doc-info-after-define [src : (& src str)] [idx : i64])
  (:cold) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (Function) src (+ next 1))
      (doc-info-after-name (Define) src next))))

(define (doc-info-after-extern [src : (& src str)] [idx : i64])
  (:cold) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (Extern) src (+ next 1))
      (doc-info-after-name (Extern) src next))))

(define (doc-info-after-defmacro [src : (& src str)] [idx : i64])
  (:cold) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (DefMacro) src (+ next 1))
      (No))))

(define (doc-decl-info-at-list [src : (& src str)] [open-idx : i64])
  (:cold) : DocMaybeDeclInfo
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

(define (doc-decl-info [signature : (& signature str)])
  (:cold) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length signature)]
    [open-idx : i64 (doc-decl-next-token signature 0 n)]
    (doc-decl-info-at-list signature open-idx)))

;; The extractor keeps the written signature for module pages and doc
;; expansion. Public renderers scan only immediate metadata forms, so
;; parentheses in a field type or comments cannot act as opacity markers.
(define (doc-list-start? [src : (& src str)] [start : i64] [end : i64])
  (:cold) : bool
  (and
    (< start end)
    (let
      [c : char (string.string-ref src start)]
      (or (= c '(') (= c '[')))))

(define (doc-opaque-form? [src : (& src str)] [start : i64] [end : i64])
  (:cold) : bool
  (let
    [head : i64 (doc-decl-next-token src (+ start 1) end)]
    [after : i64 (+ head 7)]
    (and
      (< after end)
      (= (string.string-ref src start) '(')
      (string.is-string-prefix-at src ":opaque" head)
      (= (doc-decl-next-token src after end) (- end 1))
      (= (string.string-ref src (- end 1)) ')'))))

(define (doc-field-opaque? [src : (& src str)] [start : i64] [end : i64])
  (:cold) : bool
  (let
    [name : i64 (doc-decl-next-token src (+ start 1) end)]
    [ty : i64 (doc-decl-next-token src (doc-decl-symbol-end src name end) end)]
    [i : i64
      (doc-decl-next-token
        src
        (if (doc-list-start? src ty end)
          (doc-scan-form-end src ty end)
          (doc-decl-symbol-end src ty end))
        end)]
    (while (doc-list-start? src i end)
      (let
        [next : i64 (doc-scan-form-end src i end)]
        (when (doc-opaque-form? src i next) (return true))
        (set! i (doc-decl-next-token src next end))))
    false))

(defenum DocAggregateOpacity
  (NoOpacity)
  (OpaqueAggregate)
  (OpaqueField i64 i64))

(define (doc-next-aggregate-opacity
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [struct? : bool])
  (:cold) : DocAggregateOpacity
  (let
    [previous-end : i64 start]
    [i : i64 (doc-decl-next-token src start end)]
    (while (doc-list-start? src i end)
      (let
        [next : i64 (doc-scan-form-end src i end)]
        (when (doc-opaque-form? src i next) (return OpaqueAggregate))
        (when
          (and struct? (doc-field-opaque? src i next))
          (return (OpaqueField previous-end next)))
        (set! previous-end next)
        (set! i (doc-decl-next-token src next end))))
    NoOpacity))

(define (doc-struct-constructor-restricted?
  [src : (& src str)]
  [name-end : i64]
  [end : i64])
  (:cold) : bool
  (match (doc-next-aggregate-opacity src name-end end true)
    [(NoOpacity) false]
    [_ true]))

(define (doc-field-inline-comment-end
  [src : (& src str)]
  [after-field : i64]
  [end : i64])
  (:cold) : i64
  (let
    [i : i64 after-field]
    (while (and (< i end) (doc-inline-space? (string.string-ref src i)))
      (+= i 1))
    (if (and (< i end) (= (string.string-ref src i) ';'))
      (source_text.line-end src i)
      after-field)))

(define (doc-public-aggregate-signature
  [signature : String]
  [head : String]
  [name : String]
  [struct? : bool])
  (:cold) : String
  (let
    [n : i64 (string.string-length signature)]
    [open : i64 (doc-decl-next-token (& signature) 0 n)]
    [form-head : i64 (doc-decl-next-token (& signature) (+ open 1) n)]
    [name-start : i64
      (doc-decl-next-token
        (& signature)
        (doc-decl-symbol-end (& signature) form-head n)
        n)]
    [prefix-end : i64 (doc-decl-symbol-end (& signature) name-start n)]
    [copy-start : i64 0]
    [out : text_buf.TextBuf (text_buf.empty)]
    [opacity : DocAggregateOpacity
      (doc-next-aggregate-opacity (& signature) prefix-end n struct?)]
    (while true
      (match opacity
        [(OpaqueAggregate)
          (return (str_cat.str-cat "(" head " " name " (:opaque))"))]
        [(OpaqueField previous-end next)
          (text_buf.append!
            out
            (string.substring
              (& signature)
              copy-start
              (- previous-end copy-start)))
          (set! copy-start (doc-field-inline-comment-end (& signature) next n))
          (set!
            opacity
            (doc-next-aggregate-opacity (& signature) copy-start n struct?))]
        [(NoOpacity)
          (return
            (if (> copy-start 0)
              (text_buf.render
                (text_buf.append
                  out
                  (string.substring (& signature) copy-start (- n copy-start))))
              signature))]))
    signature))

(define (doc-item-public-signature [item : (& item DocItem)])
  (:cold) : String
  (match item
    [(Item kind name _ signature _)
      (match kind
        [(DefStruct)
          (doc-public-aggregate-signature
            (string.copy signature)
            "defstruct"
            (string.copy name)
            true)]
        [(DefEnum)
          (doc-public-aggregate-signature
            (string.copy signature)
            "defenum"
            (string.copy name)
            false)]
        [_ (string.copy signature)])]))

(define (doc-source-line-at [src : (& src str)] [offset : i64])
  (:cold) : i64
  (let
    [line : i64 1]
    (for [i (iterator.range 0 offset)]
      (if (= (string.string-ref src i) '\n')
        (+= line 1)
        unit))
    line))

(define (doc-extract-source [src : String])
  (:cold) : DocExtraction
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

(define (doc-extract-file [path : String])
  (:cold) : DocExtraction
  (doc-extract-source (byte_buf.to-string (io.read-file path))))