;; doc_extract.tl - Self-hosted TypeLisp doc comment extractor (#387).
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
(import "../stdlib/io.tl")

(import "format_tokens.tl")

(defenum DocItemKind
  (DocKindDefine)
  (DocKindFunction)
  (DocKindExtern)
  (DocKindDefEnum)
  (DocKindDefStruct)
  (DocKindDefMacro))

(defenum DocItem
  (DocItem DocItemKind String String String))

(defenum DocItemList
  (DocItemNil)
  (DocItemCons DocItem (Box DocItemList)))

(defenum DocExtraction
  (DocExtraction String DocItemList))

(defenum DocMaybeDeclInfo
  (DocNoDeclInfo)
  (DocDeclInfo DocItemKind String))

(define (doc-kind-tag [kind : DocItemKind]) : i64
  (match kind
    [(DocKindDefine) 1]
    [(DocKindFunction) 2]
    [(DocKindExtern) 3]
    [(DocKindDefEnum) 4]
    [(DocKindDefStruct) 5]
    [(DocKindDefMacro) 6]))

(define (doc-kind-name [kind : DocItemKind]) : String
  (match kind
    [(DocKindDefine) "define"]
    [(DocKindFunction) "define-function"]
    [(DocKindExtern) "extern"]
    [(DocKindDefEnum) "defenum"]
    [(DocKindDefStruct) "defstruct"]
    [(DocKindDefMacro) "defmacro"]))

(define (doc-extraction-module-doc [docs : DocExtraction]) : String
  (match docs
    [(DocExtraction module-doc _) module-doc]))

(define (doc-extraction-items [docs : DocExtraction]) : DocItemList
  (match docs
    [(DocExtraction _ items) items]))

(define (doc-item-kind [item : DocItem]) : DocItemKind
  (match item
    [(DocItem kind _ _ _) kind]))

(define (doc-item-name [item : DocItem]) : String
  (match item
    [(DocItem _ name _ _) name]))

(define (doc-item-doc [item : DocItem]) : String
  (match item
    [(DocItem _ _ doc-text _) doc-text]))

(define (doc-item-signature [item : DocItem]) : String
  (match item
    [(DocItem _ _ _ signature) signature]))

(define (doc-item-list-count [items : DocItemList]) : i64
  (match items
    [(DocItemNil) 0]
    [(DocItemCons _ rest) (+ 1 (doc-item-list-count (box-get rest)))]))

(define (doc-item-list-reverse-into [items : DocItemList] [acc : DocItemList]) : DocItemList
  (match items
    [(DocItemNil) acc]
    [(DocItemCons item rest)
      (doc-item-list-reverse-into (box-get rest) (DocItemCons item (box acc)))]))

(define (doc-item-list-reverse [items : DocItemList]) : DocItemList
  (doc-item-list-reverse-into items DocItemNil))

(define (doc-inline-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab')))

(define (doc-newline? [c : char]) : bool
  (or (= c #\newline') (= c #\return')))

(define (doc-line-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (doc-newline? (string-ref src i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (begin
    (unless (< line-end n) (return line-end))
    (let
      [k : char (string-ref src line-end)]
      (begin
        (unless (= k #\return') (return (+ line-end 1)))
        (unless (< (+ line-end 1) n) (return (+ line-end 1)))
        (if (= (string-ref src (+ line-end 1)) #\newline')
          (+ line-end 2)
          (+ line-end 1))))))

(define (doc-first-nonspace [src : String] [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< i end)
          (if (doc-inline-space? (string-ref src i))
            (set! i (+ i 1))
            (set! keep false))
          (set! keep false)))
      i)))

(define (doc-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
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
                (if (= (string-ref text (+ start i)) (string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (doc-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
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
    (string-append current (string-append "\n" line))
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
        (if (= (string-ref src body-start) #\space')
          (set! body-start (+ body-start 1))
          (set! body-start body-start))
        (set! body-start body-start))
      (substring src body-start (- line-end body-start)))))

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
            [c : char (string-ref src i)]
            (cond
              [escaped
                (begin
                  (set! escaped false)
                  (set! i (+ i 1)))]
              [(= c #\\')
                (begin
                  (set! escaped true)
                  (set! i (+ i 1)))]
              [(= c #"')
                (begin
                  (set! i (+ i 1))
                  (set! keep false))]
              [else (set! i (+ i 1))]))
          (set! keep false)))
      i)))

(define (doc-scan-char-literal-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 (+ start 1)]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (if (= (string-ref src i) #'')
            (begin
              (set! i (+ i 1))
              (set! keep false))
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-scan-form-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [depth : i64 0]
    [keep : bool true]
    (begin
      (while keep
        (if (< i n)
          (let
            [c : char (string-ref src i)]
            (cond
              [(= c #;')
                (set! i (doc-next-line-start src (doc-line-end src i n) n))]
              [(= c #"') (set! i (doc-scan-string-end src i n))]
              [(= c ##') (set! i (doc-scan-char-literal-end src i n))]
              [(or (= c #(') (= c #['))
                (begin
                  (set! depth (+ depth 1))
                  (set! i (+ i 1)))]
              [(or (= c #)') (= c #]'))
                (begin
                  (set! depth (- depth 1))
                  (set! i (+ i 1))
                  (if (<= depth 0)
                    (set! keep false)
                    (set! keep keep)))]
              [else (set! i (+ i 1))]))
          (set! keep false)))
      i)))

(define (doc-next-code-token-index [stream : FormatTokenStream] [idx : i64]) : i64
  (let
    [i : i64 idx]
    [keep : bool true]
    (begin
      (while keep
        (let
          [tag : i64 (format-token-tag (format-token-at stream i))]
          (if (= tag (fmt-tag-comment))
            (set! i (+ i 1))
            (set! keep false))))
      i)))

(define (doc-token-symbol? [stream : FormatTokenStream] [idx : i64]) : bool
  (= (format-token-tag (format-token-at stream idx)) (fmt-tag-symbol)))

(define (doc-symbol-text [stream : FormatTokenStream] [idx : i64]) : String
  (format-token-text (format-token-at stream idx)))

(define (doc-info-after-name
  [kind : DocItemKind]
  [stream : FormatTokenStream]
  [idx : i64]) : DocMaybeDeclInfo
  (let
    [name-idx : i64 (doc-next-code-token-index stream idx)]
    (if (doc-token-symbol? stream name-idx)
      (DocDeclInfo kind (doc-symbol-text stream name-idx))
      (DocNoDeclInfo))))

(define (doc-info-after-define [stream : FormatTokenStream] [idx : i64]) : DocMaybeDeclInfo
  (let
    [next : i64 (doc-next-code-token-index stream idx)]
    (if (= (format-token-tag (format-token-at stream next)) (fmt-tag-lparen))
      (doc-info-after-name (DocKindFunction) stream (+ next 1))
      (doc-info-after-name (DocKindDefine) stream next))))

(define (doc-info-after-defmacro [stream : FormatTokenStream] [idx : i64]) : DocMaybeDeclInfo
  (let
    [next : i64 (doc-next-code-token-index stream idx)]
    (if (= (format-token-tag (format-token-at stream next)) (fmt-tag-lparen))
      (doc-info-after-name (DocKindDefMacro) stream (+ next 1))
      (DocNoDeclInfo))))

(define (doc-decl-info [signature : String]) : DocMaybeDeclInfo
  (let
    [stream : FormatTokenStream (format-lex signature)]
    [open-idx : i64 (doc-next-code-token-index stream 0)]
    (if (=
      (format-token-tag (format-token-at stream open-idx))
      (fmt-tag-lparen))
      (let
        [head-idx : i64 (doc-next-code-token-index stream (+ open-idx 1))]
        (if (doc-token-symbol? stream head-idx)
          (let
            [head : String (doc-symbol-text stream head-idx)]
            [after-head : i64 (+ head-idx 1)]
            (cond
              [(string-eq head "define")
                (doc-info-after-define stream after-head)]
              [(string-eq head "extern")
                (doc-info-after-name (DocKindExtern) stream after-head)]
              [(string-eq head "defenum")
                (doc-info-after-name (DocKindDefEnum) stream after-head)]
              [(string-eq head "defstruct")
                (doc-info-after-name (DocKindDefStruct) stream after-head)]
              [(string-eq head "defmacro")
                (doc-info-after-defmacro stream after-head)]
              [else (DocNoDeclInfo)]))
          (DocNoDeclInfo)))
      (DocNoDeclInfo))))

(define (doc-extract-source [src : String]) : DocExtraction
  (let
    [n : i64 (string-length src)]
    [i : i64 0]
    [module-doc : String ""]
    [module-has : bool false]
    [pending-doc : String ""]
    [pending-has : bool false]
    [items : DocItemList DocItemNil]
    (begin
      (while (< i n)
        (let
          [line-end : i64 (doc-line-end src i n)]
          [line-start : i64 (doc-first-nonspace src i line-end)]
          (if (= line-start line-end)
            (set! i (doc-next-line-start src line-end n))
            (let
              [c : char (string-ref src line-start)]
              (if (= c #;')
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
                (if (= c #(')
                  (let
                    [form-end : i64 (doc-scan-form-end src line-start n)]
                    [signature : String
                      (substring src line-start (- form-end line-start))]
                    (begin
                      (if pending-has
                        (match (doc-decl-info signature)
                          [(DocDeclInfo kind name)
                            (set!
                              items
                              (DocItemCons
                                (DocItem kind name pending-doc signature)
                                (box items)))]
                          [(DocNoDeclInfo) (set! items items)])
                        (set! items items))
                      (set! pending-doc "")
                      (set! pending-has false)
                      (set! i form-end)))
                  (begin
                    (set! pending-doc "")
                    (set! pending-has false)
                    (set! i (doc-next-line-start src line-end n)))))))))
      (DocExtraction module-doc (doc-item-list-reverse items)))))

(define (doc-extract-file [path : String]) : DocExtraction
  (doc-extract-source (read-file path)))

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
;: function doc
(define (main [argc : i64]) : i64
  answer)
; ordinary comment clears pending docs
;: enum doc
(defenum Maybe (None) (Some i64))

;# later module
;: external doc
(extern print : (-> String unit))
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

(define (doc-item-ok?
  [item : DocItem]
  [kind-tag : i64]
  [name : String]
  [doc-text : String]
  [signature-fragment : String]) : bool
  (match item
    [(DocItem kind item-name item-doc signature)
      (begin
        (unless (= (doc-kind-tag kind) kind-tag) (return false))
        (unless (string-eq item-name name) (return false))
        (unless (string-eq item-doc doc-text) (return false))
        (doc-string-contains? signature signature-fragment))]))

(define (doc-extract-smoke-items-ok? [items : DocItemList]) : bool
  (match items
    [(DocItemCons answer rest-answer)
      (match (box-get rest-answer)
        [(DocItemCons main-fn rest-main)
          (match (box-get rest-main)
            [(DocItemCons maybe rest-maybe)
              (match (box-get rest-maybe)
                [(DocItemCons print rest-print)
                  (match (box-get rest-print)
                    [(DocItemCons point rest-point)
                      (match (box-get rest-point)
                        [(DocItemCons guard rest-guard)
                          (match (box-get rest-guard)
                            [(DocItemNil)
                              (begin
                                (unless
                                  (doc-item-ok?
                                    answer
                                    1
                                    "answer"
                                    "answer doc\nstill answer"
                                    "(define answer : i64 42)")
                                  (return false))
                                (unless
                                  (doc-item-ok?
                                    main-fn
                                    2
                                    "main"
                                    "function doc"
                                    "(define (main [argc : i64])")
                                  (return false))
                                (unless
                                  (doc-item-ok?
                                    maybe
                                    4
                                    "Maybe"
                                    "enum doc"
                                    "(defenum Maybe")
                                  (return false))
                                (unless
                                  (doc-item-ok?
                                    print
                                    3
                                    "print"
                                    "external doc"
                                    "(extern print")
                                  (return false))
                                (unless
                                  (doc-item-ok?
                                    point
                                    5
                                    "Point"
                                    "struct doc"
                                    "(defstruct Point")
                                  (return false))
                                (doc-item-ok?
                                  guard
                                  6
                                  "guard"
                                  "macro doc"
                                  "(defmacro (guard"))]
                            [_ false])]
                        [_ false])]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]
    [_ false]))

(define (doc-extract-smoke) : i64
  (match (doc-extract-source (doc-extract-smoke-source))
    [(DocExtraction module-doc items)
      (begin
        (unless
          (string-eq
            module-doc
            "Module title\nsecond module line\nlater module")
          (return
            (begin
              (panic "doc-extract: module doc smoke mismatch")
              0)))
        (unless
          (= (doc-item-list-count items) 6)
          (return
            (begin
              (panic "doc-extract: item count smoke mismatch")
              0)))
        (unless
          (doc-extract-smoke-items-ok? items)
          (return
            (begin
              (panic "doc-extract: item doc smoke mismatch")
              0)))
        (match (doc-extract-source (doc-extract-legacy-smoke-source))
          [(DocExtraction legacy-module legacy-items)
            (begin
              (unless
                (string-eq legacy-module "Legacy module")
                (return
                  (begin
                    (panic "doc-extract: legacy module doc mismatch")
                    0)))
              (unless
                (= (doc-item-list-count legacy-items) 1)
                (return
                  (begin
                    (panic "doc-extract: legacy item count mismatch")
                    0)))
              (match legacy-items
                [(DocItemCons legacy legacy-rest)
                  (match (box-get legacy-rest)
                    [(DocItemNil)
                      (begin
                        (unless
                          (doc-item-ok?
                            legacy
                            1
                            "legacy"
                            "legacy item"
                            "(define legacy : i64 1)")
                          (return
                            (begin
                              (panic "doc-extract: legacy item mismatch")
                              0)))
                        42)]
                    [_ 0])]
                [_ 0]))]))]))