;; doc_extract.tl - Self-hosted TypeLisp doc comment extractor (#387).

;;

;; Public docs use Rust-style semicolon levels:

;;   ;;;; module/file doc line, collected separately

;;   ;;;  outer item doc line, attached to the next supported top-level item

;;   ;;   ordinary comment, ignored

;;   ;    ordinary comment, ignored

;;

;; Item doc lines must be contiguous. A blank line, ordinary comment, module

;; doc, unsupported top-level form, or other source text clears pending item

;; docs. Pending item docs at EOF are ignored. Declaration identities are read

;; from the captured top-level form with the formatter token lexer so original

;; source text remains available as the item signature.

(import "format_tokens.tl")

(defenum DocItemKind
  (DocKindDefine)
  (DocKindFunction)
  (DocKindExtern)
  (DocKindDefEnum)
  (DocKindDefStruct))

(defenum DocItem
  (DocItem DocItemKind String String String))

(defenum DocItemList
  (DocItemNil)
  (DocItemCons DocItem DocItemList))

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
    [(DocKindDefStruct) 5]))

(define (doc-kind-name [kind : DocItemKind]) : String
  (match kind
    [(DocKindDefine) "define"]
    [(DocKindFunction) "define-function"]
    [(DocKindExtern) "extern"]
    [(DocKindDefEnum) "defenum"]
    [(DocKindDefStruct) "defstruct"]))

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
    [(DocItemCons _ rest) (+ 1 (doc-item-list-count rest))]))

(define (doc-item-list-reverse-into [items : DocItemList] [acc : DocItemList]) : DocItemList
  (match items
    [(DocItemNil) acc]
    [(DocItemCons item rest)
      (doc-item-list-reverse-into rest (DocItemCons item acc))]))

(define (doc-item-list-reverse [items : DocItemList]) : DocItemList
  (doc-item-list-reverse-into items DocItemNil))

(define (doc-inline-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab')))

(define (doc-newline? [c : char]) : bool
  (or (= c #\newline') (= c #\return')))

(define (doc-line-end [src : String] [start : i64] [n : i64]) : i64
  (let ([i : i64 start] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (if (doc-newline? (string-ref src i))
            (set! keep false)
            (set! i (+ i 1)))
          (set! keep false)))
      i)))

(define (doc-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (if (< line-end n)
    (let ([k : char (string-ref src line-end)])
      (if (= k #\return')
        (if (< (+ line-end 1) n)
          (if (= (string-ref src (+ line-end 1)) #\newline')
            (+ line-end 2)
            (+ line-end 1))
          (+ line-end 1))
        (+ line-end 1)))
    line-end))

(define (doc-first-nonspace [src : String] [start : i64] [end : i64]) : i64
  (let ([i : i64 start] [keep : bool true])
    (begin
      (while keep
        (if (< i end)
          (if (doc-inline-space? (string-ref src i))
            (set! i (+ i 1))
            (set! keep false))
          (set! keep false)))
      i)))

(define (doc-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
  (let ([text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)])
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let ([i : i64 0] [ok : bool true])
          (begin
            (while ok
              (if (< i prefix-len)
                (if (= (string-ref text (+ start i)) (string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (doc-string-contains? [text : String] [needle : String]) : bool
  (let ([text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)])
    (if (= needle-len 0)
      true
      (let ([i : i64 0] [found : bool false] [done : bool false])
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
  (let ([body-start : i64 (+ line-start prefix-len)])
    (begin
      (if (< body-start line-end)
        (if (= (string-ref src body-start) #\space')
          (set! body-start (+ body-start 1))
          (set! body-start body-start))
        (set! body-start body-start))
      (substring src body-start (- line-end body-start)))))

(define (doc-scan-string-end [src : String] [start : i64] [n : i64]) : i64
  (let ([i : i64 (+ start 1)] [escaped : bool false] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (let ([c : char (string-ref src i)])
            (if escaped
              (begin
                (set! escaped false)
                (set! i (+ i 1)))
              (if (= c #\\')
                (begin
                  (set! escaped true)
                  (set! i (+ i 1)))
                (if (= c #"')
                  (begin
                    (set! i (+ i 1))
                    (set! keep false))
                  (set! i (+ i 1))))))
          (set! keep false)))
      i)))

(define (doc-scan-char-literal-end [src : String] [start : i64] [n : i64]) : i64
  (let ([i : i64 (+ start 1)] [keep : bool true])
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
  (let ([i : i64 start] [depth : i64 0] [keep : bool true])
    (begin
      (while keep
        (if (< i n)
          (let ([c : char (string-ref src i)])
            (if (= c #;')
              (set! i (doc-next-line-start src (doc-line-end src i n) n))
              (if (= c #"')
                (set! i (doc-scan-string-end src i n))
                (if (= c ##')
                  (set! i (doc-scan-char-literal-end src i n))
                  (if (or (= c #(') (= c #['))
                    (begin
                      (set! depth (+ depth 1))
                      (set! i (+ i 1)))
                    (if (or (= c #)') (= c #]'))
                      (begin
                        (set! depth (- depth 1))
                        (set! i (+ i 1))
                        (if (<= depth 0)
                          (set! keep false)
                          (set! keep keep)))
                      (set! i (+ i 1))))))))
          (set! keep false)))
      i)))

(define (doc-next-code-token-index [stream : FormatTokenStream] [idx : i64]) : i64
  (let ([i : i64 idx] [keep : bool true])
    (begin
      (while keep
        (let ([tag : i64 (format-token-tag (format-token-at stream i))])
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
  (let ([name-idx : i64 (doc-next-code-token-index stream idx)])
    (if (doc-token-symbol? stream name-idx)
      (DocDeclInfo kind (doc-symbol-text stream name-idx))
      (DocNoDeclInfo))))

(define (doc-info-after-define [stream : FormatTokenStream] [idx : i64]) : DocMaybeDeclInfo
  (let ([next : i64 (doc-next-code-token-index stream idx)])
    (if (= (format-token-tag (format-token-at stream next)) (fmt-tag-lparen))
      (doc-info-after-name (DocKindFunction) stream (+ next 1))
      (doc-info-after-name (DocKindDefine) stream next))))

(define (doc-decl-info [signature : String]) : DocMaybeDeclInfo
  (let ([stream : FormatTokenStream (format-lex signature)])
    (let ([open-idx : i64 (doc-next-code-token-index stream 0)])
      (if (=
        (format-token-tag (format-token-at stream open-idx))
        (fmt-tag-lparen))
        (let ([head-idx : i64 (doc-next-code-token-index stream (+ open-idx 1))])
          (if (doc-token-symbol? stream head-idx)
            (let ([head : String (doc-symbol-text stream head-idx)]
              [after-head : i64 (+ head-idx 1)])
              (if (string-eq head "define")
                (doc-info-after-define stream after-head)
                (if (string-eq head "extern")
                  (doc-info-after-name (DocKindExtern) stream after-head)
                  (if (string-eq head "defenum")
                    (doc-info-after-name (DocKindDefEnum) stream after-head)
                    (if (string-eq head "defstruct")
                      (doc-info-after-name (DocKindDefStruct) stream after-head)
                      (DocNoDeclInfo))))))
            (DocNoDeclInfo)))
        (DocNoDeclInfo)))))

(define (doc-extract-source [src : String]) : DocExtraction
  (let ([n : i64 (string-length src)]
    [i : i64 0]
    [module-doc : String ""]
    [module-has : bool false]
    [pending-doc : String ""]
    [pending-has : bool false]
    [items : DocItemList DocItemNil])
    (begin
      (while (< i n)
        (let ([line-end : i64 (doc-line-end src i n)])
          (let ([line-start : i64 (doc-first-nonspace src i line-end)])
            (if (= line-start line-end)
              (begin
                (set! pending-doc "")
                (set! pending-has false)
                (set! i (doc-next-line-start src line-end n)))
              (let ([c : char (string-ref src line-start)])
                (if (= c #;')
                  (if (doc-string-prefix-at? src ";;;;" line-start)
                    (begin
                      (set!
                        module-doc
                        (doc-append-line
                          module-doc
                          module-has
                          (doc-comment-body src line-start line-end 4)))
                      (set! module-has true)
                      (set! pending-doc "")
                      (set! pending-has false)
                      (set! i (doc-next-line-start src line-end n)))
                    (if (doc-string-prefix-at? src ";;;" line-start)
                      (begin
                        (set!
                          pending-doc
                          (doc-append-line
                            pending-doc
                            pending-has
                            (doc-comment-body src line-start line-end 3)))
                        (set! pending-has true)
                        (set! i (doc-next-line-start src line-end n)))
                      (begin
                        (set! pending-doc "")
                        (set! pending-has false)
                        (set! i (doc-next-line-start src line-end n)))))
                  (if (= c #(')
                    (let ([form-end : i64 (doc-scan-form-end src line-start n)])
                      (let ([signature
                          :
                          String
                          (substring src line-start (- form-end line-start))])
                        (begin
                          (if pending-has
                            (match (doc-decl-info signature)
                              [(DocDeclInfo kind name)
                                (set!
                                  items
                                  (DocItemCons
                                    (DocItem kind name pending-doc signature)
                                    items))]
                              [(DocNoDeclInfo) (set! items items)])
                            (set! items items))
                          (set! pending-doc "")
                          (set! pending-has false)
                          (set! i form-end))))
                    (begin
                      (set! pending-doc "")
                      (set! pending-has false)
                      (set! i (doc-next-line-start src line-end n))))))))))
      (DocExtraction module-doc (doc-item-list-reverse items)))))

(define (doc-extract-file [path : String]) : DocExtraction
  (doc-extract-source (read-file path)))

(define (doc-extract-smoke-source) : String
  ";;;; Module title
;;;; second module line

;; ordinary comment ignored
;;; answer doc
;;; still answer
(define answer : i64 42)

;;; lost before blank

(define missed : i64 0)
;;; function doc
(define (main [argc : i64]) : i64
  answer)
; ordinary comment clears pending docs
;;; enum doc
(defenum Maybe (None) (Some i64))
;;;; later module
;;; external doc
(extern print : (-> String unit))
;;; struct doc
(defstruct Point (x i64) (y i64))
;;; EOF unattached")

(define (doc-item-ok?
  [item : DocItem]
  [kind-tag : i64]
  [name : String]
  [doc-text : String]
  [signature-fragment : String]) : bool
  (match item
    [(DocItem kind item-name item-doc signature)
      (if (= (doc-kind-tag kind) kind-tag)
        (if (string-eq item-name name)
          (if (string-eq item-doc doc-text)
            (doc-string-contains? signature signature-fragment)
            false)
          false)
        false)]))

(define (doc-extract-smoke-items-ok? [items : DocItemList]) : bool
  (match items
    [(DocItemCons
        answer
        (DocItemCons
          main-fn
          (DocItemCons maybe (DocItemCons print (DocItemCons point DocItemNil)))))
      (if (doc-item-ok?
        answer
        1
        "answer"
        "answer doc\nstill answer"
        "(define answer : i64 42)")
        (if (doc-item-ok?
          main-fn
          2
          "main"
          "function doc"
          "(define (main [argc : i64])")
          (if (doc-item-ok? maybe 4 "Maybe" "enum doc" "(defenum Maybe")
            (if (doc-item-ok? print 3 "print" "external doc" "(extern print")
              (doc-item-ok? point 5 "Point" "struct doc" "(defstruct Point")
              false)
            false)
          false)
        false)]
    [_ false]))

(define (doc-extract-smoke) : i64
  (match (doc-extract-source (doc-extract-smoke-source))
    [(DocExtraction module-doc items)
      (if (string-eq
        module-doc
        "Module title\nsecond module line\nlater module")
        (if (= (doc-item-list-count items) 5)
          (if (doc-extract-smoke-items-ok? items)
            42
            (begin
              (panic "doc-extract: item doc smoke mismatch")
              0))
          (begin
            (panic "doc-extract: item count smoke mismatch")
            0))
        (begin
          (panic "doc-extract: module doc smoke mismatch")
          0))]))