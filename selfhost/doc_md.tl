;; doc_md.tl - Constrained-Markdown scanner and inline-span renderer for #871's
;; language reference renderer (#1276). Splits the SPEC.md/README.md subset into
;; typed blocks and converts inline constructs to escaped HTML:
;;   `code`  -> <code>...</code>
;;   *em*    -> <em>...</em>     (also _em_)
;;   [t](u)  -> <a href="u">t</a>
;; All other text is HTML-escaped. An unmatched/degenerate marker (an opening
;; backtick/`*`/`_`/`[` with no valid closer) is emitted literally (escaped),
;; never dropped. Block->HTML rendering is the sibling #1277 slice.
;;
;; Reuses `doc-html-escape` (entity escaping for & < > ") from doc_html.tl.
(import "doc_html.tl")

(defenum MdStringList
  (MdStringNil)
  (MdStringCons String MdStringList))

(defenum MdTableRow
  (MdTableRow MdStringList))

(defenum MdTableRowList
  (MdTableRowNil)
  (MdTableRowCons MdTableRow MdTableRowList))

(defenum MdBlock
  (MdHeading i64 String)
  (MdParagraph String)
  (MdBlockquote MdStringList)
  (MdBulletList MdStringList)
  (MdNumberedList MdStringList)
  (MdCodeFence String String String)
  (MdTable MdStringList MdTableRowList)
  (MdBlank))

(defenum MdBlockList
  (MdBlockNil)
  (MdBlockCons MdBlock MdBlockList))

(defenum MdScanBlock
  (MdScanBlock i64 MdBlock))

(defenum MdScanRows
  (MdScanRows i64 MdTableRowList))

(defenum MdMaybeBlock
  (MdNoBlock)
  (MdSomeBlock MdBlock))

(defenum MdMaybeString
  (MdNoString)
  (MdSomeString String))

(define (md-string-list-reverse-into
  [items : MdStringList]
  [acc : MdStringList]) : MdStringList
  (match items
    [(MdStringNil) acc]
    [(MdStringCons head rest)
      (md-string-list-reverse-into rest (MdStringCons head acc))]))

(define (md-string-list-reverse [items : MdStringList]) : MdStringList
  (md-string-list-reverse-into items MdStringNil))

(define (md-table-row-list-reverse-into
  [items : MdTableRowList]
  [acc : MdTableRowList]) : MdTableRowList
  (match items
    [(MdTableRowNil) acc]
    [(MdTableRowCons head rest)
      (md-table-row-list-reverse-into rest (MdTableRowCons head acc))]))

(define (md-table-row-list-reverse [items : MdTableRowList]) : MdTableRowList
  (md-table-row-list-reverse-into items MdTableRowNil))

(define (md-block-list-reverse-into [items : MdBlockList] [acc : MdBlockList]) : MdBlockList
  (match items
    [(MdBlockNil) acc]
    [(MdBlockCons head rest)
      (md-block-list-reverse-into rest (MdBlockCons head acc))]))

(define (md-block-list-reverse [items : MdBlockList]) : MdBlockList
  (md-block-list-reverse-into items MdBlockNil))

(define (md-string-list-count [items : MdStringList]) : i64
  (match items
    [(MdStringNil) 0]
    [(MdStringCons _ rest) (+ 1 (md-string-list-count rest))]))

(define (md-string-list-ref [items : MdStringList] [index : i64]) : MdMaybeString
  (if (< index 0)
    MdNoString
    (match items
      [(MdStringNil) MdNoString]
      [(MdStringCons head rest)
        (if (= index 0)
          (MdSomeString head)
          (md-string-list-ref rest (- index 1)))])))

(define (md-string-list-ref-eq?
  [items : MdStringList]
  [index : i64]
  [expected : String]) : bool
  (match (md-string-list-ref items index)
    [(MdSomeString actual) (string-eq actual expected)]
    [(MdNoString) false]))

(define (md-string-list-eq2?
  [items : MdStringList]
  [first : String]
  [second : String]) : bool
  (and
    (= (md-string-list-count items) 2)
    (and
      (md-string-list-ref-eq? items 0 first)
      (md-string-list-ref-eq? items 1 second))))

(define (md-table-row-list-count [items : MdTableRowList]) : i64
  (match items
    [(MdTableRowNil) 0]
    [(MdTableRowCons _ rest) (+ 1 (md-table-row-list-count rest))]))

(define (md-table-row-eq2?
  [row : MdTableRow]
  [first : String]
  [second : String]) : bool
  (match row
    [(MdTableRow cells) (md-string-list-eq2? cells first second)]))

(define (md-table-row-list-eq1?
  [rows : MdTableRowList]
  [first : String]
  [second : String]) : bool
  (match rows
    [(MdTableRowNil) false]
    [(MdTableRowCons row rest)
      (and
        (= (md-table-row-list-count rest) 0)
        (md-table-row-eq2? row first second))]))

(define (md-block-list-count [items : MdBlockList]) : i64
  (match items
    [(MdBlockNil) 0]
    [(MdBlockCons _ rest) (+ 1 (md-block-list-count rest))]))

(define (md-block-list-ref [items : MdBlockList] [index : i64]) : MdMaybeBlock
  (if (< index 0)
    MdNoBlock
    (match items
      [(MdBlockNil) MdNoBlock]
      [(MdBlockCons head rest)
        (if (= index 0)
          (MdSomeBlock head)
          (md-block-list-ref rest (- index 1)))])))

(define (md-check-heading?
  [blocks : MdBlockList]
  [index : i64]
  [level : i64]
  [text : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdHeading actual-level actual-text)
          (and (= actual-level level) (string-eq actual-text text))]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-blank? [blocks : MdBlockList] [index : i64]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdBlank) true]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-paragraph?
  [blocks : MdBlockList]
  [index : i64]
  [text : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdParagraph actual) (string-eq actual text)]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-blockquote2?
  [blocks : MdBlockList]
  [index : i64]
  [first : String]
  [second : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdBlockquote lines) (md-string-list-eq2? lines first second)]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-bullet-list2?
  [blocks : MdBlockList]
  [index : i64]
  [first : String]
  [second : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdBulletList items) (md-string-list-eq2? items first second)]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-numbered-list2?
  [blocks : MdBlockList]
  [index : i64]
  [first : String]
  [second : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdNumberedList items) (md-string-list-eq2? items first second)]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-code-fence?
  [blocks : MdBlockList]
  [index : i64]
  [lang : String]
  [meta : String]
  [body : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdCodeFence actual-lang actual-meta actual-body)
          (and
            (string-eq actual-lang lang)
            (and (string-eq actual-meta meta) (string-eq actual-body body)))]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-check-table1?
  [blocks : MdBlockList]
  [index : i64]
  [header-first : String]
  [header-second : String]
  [row-first : String]
  [row-second : String]) : bool
  (match (md-block-list-ref blocks index)
    [(MdSomeBlock block)
      (match block
        [(MdTable header rows)
          (and
            (md-string-list-eq2? header header-first header-second)
            (md-table-row-list-eq1? rows row-first row-second))]
        [_ false])]
    [(MdNoBlock) false]))

(define (md-inline-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab')))

(define (md-newline? [c : char]) : bool
  (or (= c #\newline') (= c #\return')))

(define (md-decimal-digit? [c : char]) : bool
  (and (>= c #0') (<= c #9')))

(define (md-trim-left [text : String]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (md-inline-space? (string-ref text i))
          (set! i (+ i 1))
          (set! done true)))
      (substring text i (- n i)))))

(define (md-trim-right [text : String]) : String
  (let
    [end : i64 (string-length text)]
    [done : bool false]
    (begin
      (while (and (not done) (> end 0))
        (if (md-inline-space? (string-ref text (- end 1)))
          (set! end (- end 1))
          (set! done true)))
      (substring text 0 end))))

(define (md-trim [text : String]) : String
  (md-trim-right (md-trim-left text)))

(define (md-string-prefix-at? [text : String] [prefix : String] [start : i64]) : bool
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
            (while (and ok (< i prefix-len))
              (if (= (string-ref text (+ start i)) (string-ref prefix i))
                (set! i (+ i 1))
                (set! ok false)))
            ok))))))

(define (md-string-prefix? [text : String] [prefix : String]) : bool
  (md-string-prefix-at? text prefix 0))

(define (md-line-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [i : i64 start]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (md-newline? (string-ref src i))
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (md-next-line-start [src : String] [line-end : i64] [n : i64]) : i64
  (if (< line-end n)
    (let
      [c : char (string-ref src line-end)]
      (if (= c #\return')
        (if (< (+ line-end 1) n)
          (if (= (string-ref src (+ line-end 1)) #\newline')
            (+ line-end 2)
            (+ line-end 1))
          (+ line-end 1))
        (+ line-end 1)))
    line-end))

(define (md-line-at [src : String] [pos : i64] [n : i64]) : String
  (let
    [line-end : i64 (md-line-end src pos n)]
    (substring src pos (- line-end pos))))

(define (md-blank-line? [line : String]) : bool
  (= (string-length (md-trim line)) 0))

(define (md-heading-level [line : String]) : i64
  (let
    [trimmed : String (md-trim-left line)]
    [n : i64 (string-length trimmed)]
    [i : i64 0]
    (begin
      (while (and (< i n) (= (string-ref trimmed i) ##'))
        (set! i (+ i 1)))
      (if (and (>= i 1) (<= i 6))
        (if (< i n)
          (if (md-inline-space? (string-ref trimmed i))
            i
            0)
          0)
        0))))

(define (md-heading-text [line : String] [level : i64]) : String
  (let
    [trimmed : String (md-trim-left line)]
    (md-trim
      (substring trimmed (+ level 1) (- (string-length trimmed) (+ level 1))))))

(define (md-blockquote-start? [line : String]) : bool
  (let
    [trimmed : String (md-trim-left line)]
    (and (> (string-length trimmed) 0) (= (string-ref trimmed 0) #>'))))

(define (md-blockquote-text [line : String]) : String
  (let
    [trimmed : String (md-trim-left line)]
    [n : i64 (string-length trimmed)]
    (if (> n 1)
      (let
        [body : String (substring trimmed 1 (- n 1))]
        (md-trim-right
          (if (and
            (> (string-length body) 0)
            (md-inline-space? (string-ref body 0)))
            (substring body 1 (- (string-length body) 1))
            body)))
      "")))

(define (md-bullet-start? [line : String]) : bool
  (let
    [trimmed : String (md-trim-left line)]
    [n : i64 (string-length trimmed)]
    (and
      (>= n 2)
      (and
        (or (= (string-ref trimmed 0) #-') (= (string-ref trimmed 0) #*'))
        (md-inline-space? (string-ref trimmed 1))))))

(define (md-bullet-text [line : String]) : String
  (let
    [trimmed : String (md-trim-left line)]
    (md-trim (substring trimmed 2 (- (string-length trimmed) 2)))))

(define (md-numbered-marker-end [line : String]) : i64
  (let
    [trimmed : String (md-trim-left line)]
    [n : i64 (string-length trimmed)]
    [i : i64 0]
    (begin
      (while (and (< i n) (md-decimal-digit? (string-ref trimmed i)))
        (set! i (+ i 1)))
      (if (> i 0)
        (if (< (+ i 1) n)
          (if (and
            (= (string-ref trimmed i) #.')
            (md-inline-space? (string-ref trimmed (+ i 1))))
            (+ i 2)
            -1)
          -1)
        -1))))

(define (md-numbered-start? [line : String]) : bool
  (>= (md-numbered-marker-end line) 0))

(define (md-numbered-text [line : String]) : String
  (let
    [trimmed : String (md-trim-left line)]
    [marker-end : i64 (md-numbered-marker-end line)]
    (md-trim
      (substring trimmed marker-end (- (string-length trimmed) marker-end)))))

(define (md-code-fence-start? [line : String]) : bool
  (md-string-prefix? (md-trim-left line) "```"))

(define (md-code-fence-info [line : String]) : String
  (let
    [trimmed : String (md-trim-left line)]
    (md-trim (substring trimmed 3 (- (string-length trimmed) 3)))))

(define (md-code-info-word-end [info : String]) : i64
  (let
    [n : i64 (string-length info)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (md-inline-space? (string-ref info i))
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (md-code-info-lang [info : String]) : String
  (let
    [trimmed : String (md-trim info)]
    [end : i64 (md-code-info-word-end (md-trim info))]
    (substring trimmed 0 end)))

(define (md-code-info-meta [info : String]) : String
  (let
    [trimmed : String (md-trim info)]
    [n : i64 (string-length (md-trim info))]
    [end : i64 (md-code-info-word-end (md-trim info))]
    (if (< end n)
      (md-trim (substring trimmed end (- n end)))
      "")))

(define (md-pipe-row-line? [line : String]) : bool
  (let
    [trimmed : String (md-trim line)]
    [n : i64 (string-length (md-trim line))]
    (if (and (> n 1) (= (string-ref trimmed 0) #|'))
      (let
        [i : i64 1]
        [found : bool false]
        (begin
          (while (and (not found) (< i n))
            (if (= (string-ref trimmed i) #|')
              (set! found true)
              (set! i (+ i 1))))
          found))
      false)))

(define (md-table-delimiter-char? [c : char]) : bool
  (or (= c #|') (or (= c #-') (or (= c #:') (or (= c #\space') (= c #\tab'))))))

(define (md-table-delimiter? [line : String]) : bool
  (let
    [trimmed : String (md-trim line)]
    [n : i64 (string-length trimmed)]
    [i : i64 0]
    [ok : bool (> n 0)]
    [has-dash : bool false]
    (begin
      (while (and ok (< i n))
        (let
          [c : char (string-ref trimmed i)]
          (begin
            (if (= c #-')
              (set! has-dash true)
              (set! has-dash has-dash))
            (if (md-table-delimiter-char? c)
              (set! i (+ i 1))
              (set! ok false)))))
      (and ok has-dash))))

(define (md-table-start-at? [src : String] [pos : i64] [n : i64]) : bool
  (let
    [line-end : i64 (md-line-end src pos n)]
    [line : String (substring src pos (- line-end pos))]
    [next : i64 (md-next-line-start src line-end n)]
    (if (and (md-pipe-row-line? line) (< next n))
      (let
        [next-end : i64 (md-line-end src next n)]
        [next-line : String (substring src next (- next-end next))]
        (md-table-delimiter? next-line))
      false)))

(define (md-strip-pipe-edges [line : String]) : String
  (let
    [trimmed : String (md-trim line)]
    [start : i64 0]
    [end : i64 (string-length (md-trim line))]
    (begin
      (if (and (> end 0) (= (string-ref trimmed 0) #|'))
        (set! start 1)
        (set! start start))
      (if (and (> end start) (= (string-ref trimmed (- end 1)) #|'))
        (set! end (- end 1))
        (set! end end))
      (substring trimmed start (- end start)))))

(define (md-split-pipe-row [line : String]) : MdStringList
  (let
    [body : String (md-strip-pipe-edges line)]
    [n : i64 (string-length (md-strip-pipe-edges line))]
    [i : i64 0]
    [segment-start : i64 0]
    [items : MdStringList MdStringNil]
    (begin
      (while (< i n)
        (if (= (string-ref body i) #|')
          (begin
            (set!
              items
              (MdStringCons
                (md-trim (substring body segment-start (- i segment-start)))
                items))
            (set! segment-start (+ i 1))
            (set! i (+ i 1)))
          (set! i (+ i 1))))
      (md-string-list-reverse
        (MdStringCons
          (md-trim (substring body segment-start (- n segment-start)))
          items)))))

(define (md-block-start-at? [src : String] [pos : i64] [n : i64]) : bool
  (let
    [line : String (md-line-at src pos n)]
    (or
      (md-blank-line? line)
      (or
        (> (md-heading-level line) 0)
        (or
          (md-code-fence-start? line)
          (or
            (md-table-start-at? src pos n)
            (or
              (md-blockquote-start? line)
              (or (md-bullet-start? line) (md-numbered-start? line)))))))))

(define (md-scan-code-fence [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [line-end : i64 (md-line-end src pos n)]
    [line : String (substring src pos (- line-end pos))]
    [info : String (md-code-fence-info line)]
    [scan-pos : i64 (md-next-line-start src line-end n)]
    [body : String ""]
    [done : bool false]
    (begin
      (while (and (not done) (< scan-pos n))
        (let
          [body-end : i64 (md-line-end src scan-pos n)]
          [body-line : String (substring src scan-pos (- body-end scan-pos))]
          [body-next : i64 (md-next-line-start src body-end n)]
          (if (md-code-fence-start? body-line)
            (begin
              (set! scan-pos body-next)
              (set! done true))
            (begin
              (set! body (string-append body (string-append body-line "\n")))
              (set! scan-pos body-next)))))
      (MdScanBlock
        scan-pos
        (MdCodeFence (md-code-info-lang info) (md-code-info-meta info) body)))))

(define (md-scan-blockquote [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [scan-pos : i64 pos]
    [items : MdStringList MdStringNil]
    [done : bool false]
    (begin
      (while (and (not done) (< scan-pos n))
        (let
          [line-end : i64 (md-line-end src scan-pos n)]
          [line : String (substring src scan-pos (- line-end scan-pos))]
          [next : i64 (md-next-line-start src line-end n)]
          (if (md-blockquote-start? line)
            (begin
              (set! items (MdStringCons (md-blockquote-text line) items))
              (set! scan-pos next))
            (set! done true))))
      (MdScanBlock scan-pos (MdBlockquote (md-string-list-reverse items))))))

(define (md-scan-bullet-list [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [scan-pos : i64 pos]
    [items : MdStringList MdStringNil]
    [done : bool false]
    (begin
      (while (and (not done) (< scan-pos n))
        (let
          [line-end : i64 (md-line-end src scan-pos n)]
          [line : String (substring src scan-pos (- line-end scan-pos))]
          [next : i64 (md-next-line-start src line-end n)]
          (if (md-bullet-start? line)
            (begin
              (set! items (MdStringCons (md-bullet-text line) items))
              (set! scan-pos next))
            (set! done true))))
      (MdScanBlock scan-pos (MdBulletList (md-string-list-reverse items))))))

(define (md-scan-numbered-list [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [scan-pos : i64 pos]
    [items : MdStringList MdStringNil]
    [done : bool false]
    (begin
      (while (and (not done) (< scan-pos n))
        (let
          [line-end : i64 (md-line-end src scan-pos n)]
          [line : String (substring src scan-pos (- line-end scan-pos))]
          [next : i64 (md-next-line-start src line-end n)]
          (if (md-numbered-start? line)
            (begin
              (set! items (MdStringCons (md-numbered-text line) items))
              (set! scan-pos next))
            (set! done true))))
      (MdScanBlock scan-pos (MdNumberedList (md-string-list-reverse items))))))

(define (md-scan-table-rows [src : String] [pos : i64] [n : i64]) : MdScanRows
  (let
    [scan-pos : i64 pos]
    [rows : MdTableRowList MdTableRowNil]
    [done : bool false]
    (begin
      (while (and (not done) (< scan-pos n))
        (let
          [line-end : i64 (md-line-end src scan-pos n)]
          [line : String (substring src scan-pos (- line-end scan-pos))]
          [next : i64 (md-next-line-start src line-end n)]
          (if (md-pipe-row-line? line)
            (begin
              (set!
                rows
                (MdTableRowCons (MdTableRow (md-split-pipe-row line)) rows))
              (set! scan-pos next))
            (set! done true))))
      (MdScanRows scan-pos (md-table-row-list-reverse rows)))))

(define (md-scan-table [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [header-end : i64 (md-line-end src pos n)]
    [header-line : String (substring src pos (- header-end pos))]
    [delimiter-pos : i64 (md-next-line-start src header-end n)]
    [delimiter-end : i64 (md-line-end src delimiter-pos n)]
    [body-pos : i64 (md-next-line-start src delimiter-end n)]
    (match (md-scan-table-rows src body-pos n)
      [(MdScanRows next rows)
        (MdScanBlock next (MdTable (md-split-pipe-row header-line) rows))])))

(define (md-scan-paragraph [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [scan-pos : i64 pos]
    [text : String ""]
    [done : bool false]
    (begin
      (while (and (not done) (< scan-pos n))
        (let
          [line-end : i64 (md-line-end src scan-pos n)]
          [line : String (substring src scan-pos (- line-end scan-pos))]
          [next : i64 (md-next-line-start src line-end n)]
          (if (md-block-start-at? src scan-pos n)
            (set! done true)
            (begin
              (set!
                text
                (if (= (string-length text) 0)
                  (md-trim line)
                  (string-append text (string-append " " (md-trim line)))))
              (set! scan-pos next)))))
      (MdScanBlock scan-pos (MdParagraph text)))))

(define (md-scan-block-at [src : String] [pos : i64] [n : i64]) : MdScanBlock
  (let
    [line-end : i64 (md-line-end src pos n)]
    [line : String (substring src pos (- line-end pos))]
    [next : i64 (md-next-line-start src line-end n)]
    [level : i64 (md-heading-level line)]
    (cond
      [(md-blank-line? line) (MdScanBlock next (MdBlank))]
      [(md-code-fence-start? line) (md-scan-code-fence src pos n)]
      [(> level 0)
        (MdScanBlock next (MdHeading level (md-heading-text line level)))]
      [(md-table-start-at? src pos n) (md-scan-table src pos n)]
      [(md-blockquote-start? line) (md-scan-blockquote src pos n)]
      [(md-bullet-start? line) (md-scan-bullet-list src pos n)]
      [(md-numbered-start? line) (md-scan-numbered-list src pos n)]
      [else (md-scan-paragraph src pos n)])))

(define (md-scan-blocks [src : String]) : MdBlockList
  (let
    [n : i64 (string-length src)]
    [pos : i64 0]
    [blocks : MdBlockList MdBlockNil]
    (begin
      (while (< pos n)
        (match (md-scan-block-at src pos n)
          [(MdScanBlock next block)
            (begin
              (set! blocks (MdBlockCons block blocks))
              (set! pos next))]))
      (md-block-list-reverse blocks))))

;;; Index of the first `target` char at or after `from`; returns the string
;;; length (a never-an-index sentinel) when there is no such character.
(define (md-find-char [text : String] [from : i64] [target : char]) : i64
  (let
    [i : i64 from]
    [n : i64 (string-length text)]
    [found : i64 (string-length text)]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (set!
            found
            (if (= (string-ref text i) target)
              i
              found))
          (set! i (+ i 1))))
      found)))

;;; HTML-escape the single character at `idx` (reuses the doc_html entity escaper).
(define (md-escape-char [text : String] [idx : i64]) : String
  (doc-html-escape (substring text idx 1)))

;;; Render a well-formed `[label](url)` link given the `[` at `lbracket`, the `]`
;;; at `jclose`, and the `)` at `kclose`. Label and URL are HTML-escaped.
(define (md-render-link
  [text : String]
  [lbracket : i64]
  [jclose : i64]
  [kclose : i64]) : String
  (let
    [label : String
      (doc-html-escape
        (substring text (+ lbracket 1) (- jclose (+ lbracket 1))))]
    [url : String
      (doc-html-escape (substring text (+ jclose 2) (- kclose (+ jclose 2))))]
    (doc-html-cat5 "<a href=\"" url "\">" label "</a>")))

;;; Inline-render `text` to HTML: `code`, *em*/_em_, [t](u), everything else
;;; HTML-escaped; unmatched markers are emitted literally.
(define (md-render-inline [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (cond
            [(= c #`')
              (let
                [j : i64 (md-find-char text (+ i 1) #`')]
                (if (< j n)
                  (begin
                    (set!
                      out
                      (doc-html-cat3
                        (string-append out "<code>")
                        (doc-html-escape (substring text (+ i 1) (- j (+ i 1))))
                        "</code>"))
                    (set! i (+ j 1)))
                  (begin
                    (set! out (string-append out (md-escape-char text i)))
                    (set! i (+ i 1)))))]
            [(or (= c #*') (= c #_'))
              (let
                [j : i64 (md-find-char text (+ i 1) c)]
                (if (< j n)
                  (begin
                    (set!
                      out
                      (doc-html-cat3
                        (string-append out "<em>")
                        (doc-html-escape (substring text (+ i 1) (- j (+ i 1))))
                        "</em>"))
                    (set! i (+ j 1)))
                  (begin
                    (set! out (string-append out (md-escape-char text i)))
                    (set! i (+ i 1)))))]
            [(= c #[')
              (let
                [jclose : i64 (md-find-char text (+ i 1) #]')]
                (if (< jclose n)
                  (if (< (+ jclose 1) n)
                    (if (= (string-ref text (+ jclose 1)) #(')
                      (let
                        [kclose : i64 (md-find-char text (+ jclose 2) #)')]
                        (if (< kclose n)
                          (begin
                            (set!
                              out
                              (string-append
                                out
                                (md-render-link text i jclose kclose)))
                            (set! i (+ kclose 1)))
                          (begin
                            (set!
                              out
                              (string-append out (md-escape-char text i)))
                            (set! i (+ i 1)))))
                      (begin
                        (set! out (string-append out (md-escape-char text i)))
                        (set! i (+ i 1))))
                    (begin
                      (set! out (string-append out (md-escape-char text i)))
                      (set! i (+ i 1))))
                  (begin
                    (set! out (string-append out (md-escape-char text i)))
                    (set! i (+ i 1)))))]
            [else
              (begin
                (set! out (string-append out (md-escape-char text i)))
                (set! i (+ i 1)))])))
      out)))

;; ---- self-test (driven by doc_md_smoke.tl) ----
(define (compiler-doc-md-block-self-test) : i64
  (let
    [fixture : String
      (string-append
        "# Title `x`\n\n"
        (string-append
          "Paragraph with *em*\n"
          (string-append
            "> quote [a](b)\n> second\n"
            (string-append
              "- one\n- two\n"
              (string-append
                "1. first\n2. second\n"
                (string-append
                  "```typelisp run expect=42\n(define x : i64 1)\n```\n"
                  "| Name | Type |\n| --- | --- |\n| x | i64 |\n"))))))]
    [blocks : MdBlockList (md-scan-blocks fixture)]
    (if (= (md-block-list-count blocks) 8)
      (if (md-check-heading? blocks 0 1 "Title `x`")
        (if (md-check-blank? blocks 1)
          (if (md-check-paragraph? blocks 2 "Paragraph with *em*")
            (if (md-check-blockquote2? blocks 3 "quote [a](b)" "second")
              (if (md-check-bullet-list2? blocks 4 "one" "two")
                (if (md-check-numbered-list2? blocks 5 "first" "second")
                  (if (md-check-code-fence?
                    blocks
                    6
                    "typelisp"
                    "run expect=42"
                    "(define x : i64 1)\n")
                    (if (md-check-table1? blocks 7 "Name" "Type" "x" "i64")
                      42
                      108)
                    107)
                  106)
                105)
              104)
            103)
          102)
        101)
      100)))

(define (compiler-doc-md-self-test) : i64
  (if (string-eq (md-render-inline "plain text") "plain text")
    (if (string-eq (md-render-inline "a `b` c") "a <code>b</code> c")
      (if (string-eq (md-render-inline "x *y* z") "x <em>y</em> z")
        (if (string-eq (md-render-inline "u _v_ w") "u <em>v</em> w")
          (if (string-eq
            (md-render-inline "see [docs](https://x/y)")
            "see <a href=\"https://x/y\">docs</a>")
            (if (string-eq
              (md-render-inline "1 < 2 & 3 > 0")
              "1 &lt; 2 &amp; 3 &gt; 0")
              (if (string-eq
                (md-render-inline "code `a<b`")
                "code <code>a&lt;b</code>")
                (if (string-eq (md-render-inline "bare [link") "bare [link")
                  (compiler-doc-md-block-self-test)
                  7)
                6)
              5)
            4)
          3)
        2)
      1)
    0))