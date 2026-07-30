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
(import stdlib.io)
(import stdlib.string)
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
  (Item DocItemKind String String String))

(import (vector.vector DocItem core) as doc_item_vec)

(defenum DocExtraction
  (Extraction String doc_item_vec.Vec))

(define (doc-extraction-empty) : DocExtraction
  (DocExtraction.Extraction "" (doc_item_vec.new)))

(defenum DocMaybeDeclInfo
  (No)
  (DocDeclInfo DocItemKind String))

(define (doc-kind-tag [kind : DocItemKind]) : i64
  (match kind
    [(DocItemKind.Define) 1]
    [(DocItemKind.Function) 2]
    [(DocItemKind.Extern) 3]
    [(DocItemKind.DefEnum) 4]
    [(DocItemKind.DefStruct) 5]
    [(DocItemKind.DefMacro) 6]
    [(DocItemKind.GeneratedImport) 7]))

(define (doc-kind-name [kind : DocItemKind]) : String
  (match kind
    [(DocItemKind.Define) "define"]
    [(DocItemKind.Function) "define-function"]
    [(DocItemKind.Extern) "extern"]
    [(DocItemKind.DefEnum) "defenum"]
    [(DocItemKind.DefStruct) "defstruct"]
    [(DocItemKind.DefMacro) "defmacro"]
    [(DocItemKind.GeneratedImport) "generated-module-import"]))

(define (doc-extraction-module-doc [docs : DocExtraction]) : String
  (match docs
    [(DocExtraction.Extraction module-doc _) module-doc]))

(define (doc-extraction-items [docs : DocExtraction]) : doc_item_vec.Vec
  (match docs
    [(DocExtraction.Extraction _ items) items]))

(define (doc-item-kind [item : DocItem]) : DocItemKind
  (match item
    [(DocItem.Item kind _ _ _) kind]))

(define (doc-item-name [item : DocItem]) : String
  (match item
    [(DocItem.Item _ name _ _) name]))

(define (doc-item-doc [item : DocItem]) : String
  (match item
    [(DocItem.Item _ _ doc-text _) doc-text]))

(define (doc-item-signature [item : DocItem]) : String
  (match item
    [(DocItem.Item _ _ _ signature) signature]))

(define (doc-item-fallback) : DocItem
  (DocItem.Item (DocItemKind.Define) "" "" ""))

(define (doc-item-list-count [items : doc_item_vec.Vec]) : i64
  (doc_item_vec.len (& items)))

(define (doc-item-list-ref [items : doc_item_vec.Vec] [index : i64]) : DocItem
  (doc_item_vec.get (& items) index (doc-item-fallback)))

(define (doc-item-array-copy-to-list
  [out : (&mut out doc_item_vec.Vec)]
  [items : (__tl_dyn-array DocItem)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (doc_item_vec.push out (array-ref items index))
      (doc-item-array-copy-to-list out items (+ index 1) count))))

(define (doc-item-array-to-list [items : (__tl_dyn-array DocItem)]) : doc_item_vec.Vec
  (let
    [out : doc_item_vec.Vec (doc_item_vec.with-capacity (array-length items))]
    (begin
      (doc-item-array-copy-to-list (&mut out) items 0 (array-length items))
      out)))

(define (doc-inline-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (doc-newline? [c : char]) : bool
  (or (= c '\n') (= c '\r')))

(define (doc-line-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (doc-newline? (string.string-ref src i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (begin
    (unless (< line-end n) (return line-end))
    (let
      [k : char (string.string-ref src line-end)]
      (begin
        (unless (= k '\r') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string.string-ref src (+ line-end 1)) '\n')
          (+ line-end 2)
          (+ line-end 1))))))

(define (doc-first-nonspace [src : String] [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i end)
          (if (doc-inline-space? (string.string-ref src i))
            (set! i (+ i 1))
            (set! keep false))
          (set! keep false)))
      i)))

(define (doc-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (string.string-ref text (+ start i))
                  (string.string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (doc-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    (if (= needle-len 0)
      true
      (let
        [i : i64 0]
        [found : bool false]
        [done : bool false]
        (begin
          (while (not done)
            (if (<= (+ i needle-len) text-len)
              (if (doc-string-prefix-at? text needle i)
                (begin
                  (set! found true)
                  (set! done true))
                (set! i (+ i 1)))
              (set! done true)))
          found)))))

(define (doc-append-line
  [current : String]
  [has-current : bool]
  [line : String]) : String
  (if has-current
    (string.append current (string.append "\n" line))
    line))

(define (doc-comment-body
  [src : String]
  [line-start : i64]
  [line-end : i64]
  [prefix-len : i64]) : String
  (let
    [body-start : i64 (+ line-start prefix-len)]
    (begin
      (if (< body-start line-end)
        (if (= (string.string-ref src body-start) ' ')
          (set! body-start (+ body-start 1))
          (set! body-start body-start))
        (set! body-start body-start))
      (string.substring src body-start (- line-end body-start)))))

(define (doc-module-doc-prefix-len [src : String] [line-start : i64]) : i64
  (if (doc-string-prefix-at? src ";#" line-start)
    2
    0))

(define (doc-item-doc-prefix-len [src : String] [line-start : i64]) : i64
  (if (doc-string-prefix-at? src ";:" line-start)
    2
    0))

(define (doc-scan-string-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 (+ start 1)]
    [escaped : bool false]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (let
            [c : char (string.string-ref src i)]
            (cond
              [escaped
                (begin
                  (set! escaped false)
                  (set! i (+ i 1)))]
              [(= c '\\')
                (begin
                  (set! escaped true)
                  (set! i (+ i 1)))]
              [(= c '"')
                (begin
                  (set! i (+ i 1))
                  (set! keep false))]
              [else (set! i (+ i 1))]))
          (set! keep false)))
      i)))

(define (doc-apostrophe-char-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

(define (doc-scan-apostrophe-char-literal-end
  [src : String]
  [start : i64]
  [n : i64]) : i64
  (if (< (+ start 1) n)
    (let
      [payload : char (string.string-ref src (+ start 1))]
      (cond
        [(= payload '\\')
          (if (and
            (< (+ start 3) n)
            (doc-apostrophe-char-escape? (string.string-ref src (+ start 2)))
            (= (string.string-ref src (+ start 3)) '\''))
            (+ start 4)
            (+ start 1))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r')) (+ start 1)]
        [else
          (if (and
            (< (+ start 2) n)
            (= (string.string-ref src (+ start 2)) '\''))
            (+ start 3)
            (+ start 1))]))
    (+ start 1)))

(define (doc-scan-form-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [depth : i64 0]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (let
            [c : char (string.string-ref src i)]
            (cond
              [(= c ';')
                (set! i (doc-next-line-start src (doc-line-end src i n) n))]
              [(= c '"') (set! i (doc-scan-string-end src i n))]
              [(= c '\'')
                (set! i (doc-scan-apostrophe-char-literal-end src i n))]
              [(or (= c '(') (= c '['))
                (begin
                  (set! depth (+ depth 1))
                  (set! i (+ i 1)))]
              [(or (= c ')') (= c ']'))
                (begin
                  (set! depth (- depth 1))
                  (set! i (+ i 1))
                  (if (<= depth 0)
                    (set! keep false)
                    (set! keep keep)))]
              [else (set! i (+ i 1))]))
          (set! keep false)))
      i)))

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

(define (doc-decl-symbol-start? [src : String] [idx : i64] [n : i64]) : bool
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

(define (doc-decl-next-token [src : String] [idx : i64] [n : i64]) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (let
            [c : char (string.string-ref src i)]
            (cond
              [(or (doc-inline-space? c) (doc-newline? c)) (set! i (+ i 1))]
              [(= c ';')
                (set! i (doc-next-line-start src (doc-line-end src i n) n))]
              [else (set! keep false)]))
          (set! keep false)))
      i)))

(define (doc-decl-symbol-end [src : String] [idx : i64] [n : i64]) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (doc-decl-symbol-char? (string.string-ref src i))
            (set! i (+ i 1))
            (set! keep false))
          (set! keep false)))
      i)))

(define (doc-info-after-name [kind : DocItemKind] [src : String] [idx : i64]) : DocMaybeDeclInfo
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
      (DocMaybeDeclInfo.No))))

(define (doc-info-after-define [src : String] [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (DocItemKind.Function) src (+ next 1))
      (doc-info-after-name (DocItemKind.Define) src next))))

(define (doc-info-after-extern [src : String] [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (DocItemKind.Extern) src (+ next 1))
      (doc-info-after-name (DocItemKind.Extern) src next))))

(define (doc-info-after-defmacro [src : String] [idx : i64]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length src)]
    [next : i64 (doc-decl-next-token src idx n)]
    (if (if (< next n)
      (= (string.string-ref src next) '(')
      false)
      (doc-info-after-name (DocItemKind.DefMacro) src (+ next 1))
      (DocMaybeDeclInfo.No))))

(define (doc-decl-info-at-list [src : String] [open-idx : i64]) : DocMaybeDeclInfo
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
                (doc-info-after-name (DocItemKind.DefEnum) src after-head)]
              [(string.eq head "defstruct")
                (doc-info-after-name (DocItemKind.DefStruct) src after-head)]
              [(string.eq head "defmacro")
                (doc-info-after-defmacro src after-head)]
              [else (DocMaybeDeclInfo.No)]))
          (DocMaybeDeclInfo.No)))
      (DocMaybeDeclInfo.No))))

(define (doc-decl-info [signature : String]) : DocMaybeDeclInfo
  (let
    [n : i64 (string.string-length signature)]
    [open-idx : i64 (doc-decl-next-token signature 0 n)]
    (doc-decl-info-at-list signature open-idx)))

(define (doc-extract-source [src : String]) : DocExtraction
  (let
    [n : i64 (string.string-length src)]
    [i : i64 0]
    [module-doc : String ""]
    [module-has : bool false]
    [pending-doc : String ""]
    [pending-has : bool false]
    [items : (__tl_dyn-array DocItem) (make-array DocItem 0)]
    (begin
      (while (< i n)
        (let
          [line-end : i64 (doc-line-end src i n)]
          [line-start : i64 (doc-first-nonspace src i line-end)]
          (if (= line-start line-end)
            (set! i (doc-next-line-start src line-end n))
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
                      (set! i (doc-next-line-start src line-end n)))
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
                          (set! i (doc-next-line-start src line-end n)))
                        (begin
                          (set! pending-doc "")
                          (set! pending-has false)
                          (set! i (doc-next-line-start src line-end n)))))))
                (if (= c '(')
                  (let
                    [form-end : i64 (doc-scan-form-end src line-start n)]
                    [signature : String
                      (string.substring src line-start (- form-end line-start))]
                    (begin
                      (if pending-has
                        (match (doc-decl-info signature)
                          [(DocDeclInfo kind name)
                            (array-push!
                              items
                              (DocItem.Item kind name pending-doc signature))]
                          [(DocMaybeDeclInfo.No) unit])
                        unit)
                      (set! pending-doc "")
                      (set! pending-has false)
                      (set! i form-end)))
                  (begin
                    (set! pending-doc "")
                    (set! pending-has false)
                    (set! i (doc-next-line-start src line-end n)))))))))
      (DocExtraction.Extraction module-doc (doc-item-array-to-list items)))))

(define (doc-extract-file [path : String]) : DocExtraction
  (doc-extract-source (io.read-file path)))

(define (doc-extract-smoke-source) : String
  ";# Module title
;# second module line

;; ordinary comment ignored
;: answer doc
;: still answer
(define answer : i64 42)

;: lost before ordinary comment
;; ordinary comment clears pending docs
(define missed : i64 0)
(define ignored-quote-char : char '\"')
(define ignored-paren-char : char '(')
;: function doc
(define (main [argc : i64]) : i64
  answer)
; ordinary comment clears pending docs
;: enum doc
(defenum Maybe (None) (Some i64))

;# later module
;: external doc
(extern (io.print [arg0 : String]) : unit)
;: struct doc
(defstruct Point (x i64) (y i64))
;: macro doc
(defmacro (guard [condition : bool] [body : unit]) : unit
  `(if ,condition ,body unit))
;: EOF unattached")

(define (doc-extract-legacy-smoke-source) : String
  ";# Legacy module
;: legacy item
(define legacy : i64 1)")

(define (doc-extract-declaration-smoke-source) : String
  ";: box doc
(defstruct Box_String
  (value String))

;: helper doc
(define (box-string-value [value : Box_String]) : String
  (struct-get value value))")

(define (doc-item-ok?
  [item : DocItem]
  [kind-tag : i64]
  [name : String]
  [doc-text : String]
  [signature-fragment : String]) : bool
  (match item
    [(DocItem.Item kind item-name item-doc signature)
      (begin
        (unless (= (doc-kind-tag kind) kind-tag) (return false))
        (unless (string.eq item-name name) (return false))
        (unless (string.eq item-doc doc-text) (return false))
        (doc-string-contains? signature signature-fragment))]))

(define (doc-extract-smoke-items-ok? [items : doc_item_vec.Vec]) : bool
  (begin
    (unless (= (doc-item-list-count items) 6) (return false))
    (unless
      (doc-item-ok?
        (doc-item-list-ref items 0)
        1
        "answer"
        "answer doc\nstill answer"
        "(define answer : i64 42)")
      (return false))
    (unless
      (doc-item-ok?
        (doc-item-list-ref items 1)
        2
        "main"
        "function doc"
        "(define (main [argc : i64])")
      (return false))
    (unless
      (doc-item-ok?
        (doc-item-list-ref items 2)
        4
        "Maybe"
        "enum doc"
        "(defenum Maybe")
      (return false))
    (unless
      (doc-item-ok?
        (doc-item-list-ref items 3)
        3
        "io.print"
        "external doc"
        "(extern (io.print")
      (return false))
    (unless
      (doc-item-ok?
        (doc-item-list-ref items 4)
        5
        "Point"
        "struct doc"
        "(defstruct Point")
      (return false))
    (doc-item-ok?
      (doc-item-list-ref items 5)
      6
      "guard"
      "macro doc"
      "(defmacro (guard")))

(define (doc-extract-declaration-smoke-ok?) : bool
  (match (doc-extract-source (doc-extract-declaration-smoke-source))
    [(DocExtraction.Extraction _ items)
      (and
        (= (doc-item-list-count items) 2)
        (doc-item-ok?
          (doc-item-list-ref items 0)
          5
          "Box_String"
          "box doc"
          "(defstruct Box_String")
        (doc-item-ok?
          (doc-item-list-ref items 1)
          2
          "box-string-value"
          "helper doc"
          "(define (box-string-value"))]))

(define (doc-extract-smoke) : i64
  (match (doc-extract-source (doc-extract-smoke-source))
    [(DocExtraction.Extraction module-doc items)
      (begin
        (unless
          (string.eq
            module-doc
            "Module title\nsecond module line\nlater module")
          (return (io.panic "doc-extract: module doc smoke mismatch")))
        (unless
          (= (doc-item-list-count items) 6)
          (return (io.panic "doc-extract: item count smoke mismatch")))
        (unless
          (doc-extract-smoke-items-ok? items)
          (return (io.panic "doc-extract: item doc smoke mismatch")))
        (unless
          (doc-extract-declaration-smoke-ok?)
          (return (io.panic "doc-extract: declaration item mismatch")))
        (match (doc-extract-source (doc-extract-legacy-smoke-source))
          [(DocExtraction.Extraction legacy-module legacy-items)
            (begin
              (unless
                (string.eq legacy-module "Legacy module")
                (return (io.panic "doc-extract: legacy module doc mismatch")))
              (unless
                (= (doc-item-list-count legacy-items) 1)
                (return (io.panic "doc-extract: legacy item count mismatch")))
              (unless
                (doc-item-ok?
                  (doc-item-list-ref legacy-items 0)
                  1
                  "legacy"
                  "legacy item"
                  "(define legacy : i64 1)")
                (return (io.panic "doc-extract: legacy item mismatch")))
              42)]))]))