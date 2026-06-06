;; compiler_diagnostic.tl - Shared selfhost compiler diagnostic payloads.
(import "../stdlib/string.tl")

(import "token.tl")

(import "compiler_ast_types.tl")

(import "../stdlib/string.tl")

(defenum CompilerDiagnosticLevel
  (CompilerDiagnosticError)
  (CompilerDiagnosticWarning)
  (CompilerDiagnosticNote))

(defenum CompilerDiagnosticMaybeString
  (CompilerDiagnosticNoString)
  (CompilerDiagnosticSomeString String))

(defstruct CompilerDiagnosticSpan
  (path String)
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defstruct CompilerDiagnosticLabel
  (span CompilerDiagnosticSpan)
  (label CompilerDiagnosticMaybeString))

(defenum CompilerDiagnosticLabelList
  (CompilerDiagnosticLabelNil)
  (CompilerDiagnosticLabelCons
    CompilerDiagnosticLabel
    (Box CompilerDiagnosticLabelList)))

(defenum CompilerDiagnosticNoteList
  (CompilerDiagnosticNoteNil)
  (CompilerDiagnosticNoteCons String (Box CompilerDiagnosticNoteList)))

(defstruct CompilerDiagnostic
  (message String)
  (level CompilerDiagnosticLevel)
  (code CompilerDiagnosticMaybeString)
  (category CompilerDiagnosticMaybeString)
  (primary CompilerDiagnosticSpan)
  (help CompilerDiagnosticMaybeString)
  (secondary CompilerDiagnosticLabelList)
  (notes CompilerDiagnosticNoteList))

(define (compiler-diagnostic-cat3
  [left : String]
  [middle : String]
  [right : String]) : String
  (string-append left (string-append middle right)))

(define (compiler-diagnostic-span-path [span : CompilerDiagnosticSpan]) : String
  (struct-get span path))

(define (compiler-diagnostic-span-start-line [span : CompilerDiagnosticSpan]) : i64
  (struct-get span start-line))

(define (compiler-diagnostic-span-start-col [span : CompilerDiagnosticSpan]) : i64
  (struct-get span start-col))

(define (compiler-diagnostic-span-end-line [span : CompilerDiagnosticSpan]) : i64
  (struct-get span end-line))

(define (compiler-diagnostic-span-end-col [span : CompilerDiagnosticSpan]) : i64
  (struct-get span end-col))

(define (compiler-diagnostic-path [diag : CompilerDiagnostic]) : String
  (compiler-diagnostic-span-path (struct-get diag primary)))

(define (compiler-diagnostic-line [diag : CompilerDiagnostic]) : i64
  (compiler-diagnostic-span-start-line (struct-get diag primary)))

(define (compiler-diagnostic-col [diag : CompilerDiagnostic]) : i64
  (compiler-diagnostic-span-start-col (struct-get diag primary)))

(define (compiler-diagnostic-message [diag : CompilerDiagnostic]) : String
  (struct-get diag message))

(define (compiler-diagnostic-end-line [diag : CompilerDiagnostic]) : i64
  (compiler-diagnostic-span-end-line (struct-get diag primary)))

(define (compiler-diagnostic-end-col [diag : CompilerDiagnostic]) : i64
  (compiler-diagnostic-span-end-col (struct-get diag primary)))

(define (compiler-diagnostic-level [diag : CompilerDiagnostic]) : CompilerDiagnosticLevel
  (struct-get diag level))

(define (compiler-diagnostic-code [diag : CompilerDiagnostic]) : CompilerDiagnosticMaybeString
  (struct-get diag code))

(define (compiler-diagnostic-code-parse) : String
  "E0100")

(define (compiler-diagnostic-code-typecheck) : String
  "E0200")

(define (compiler-diagnostic-code-or-empty [diag : CompilerDiagnostic]) : String
  (match (compiler-diagnostic-code diag)
    [(CompilerDiagnosticSomeString code) code]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-category [diag : CompilerDiagnostic]) : CompilerDiagnosticMaybeString
  (struct-get diag category))

(define (compiler-diagnostic-help [diag : CompilerDiagnostic]) : CompilerDiagnosticMaybeString
  (struct-get diag help))

(define (compiler-diagnostic-secondary-spans [diag : CompilerDiagnostic]) : CompilerDiagnosticLabelList
  (struct-get diag secondary))

(define (compiler-diagnostic-notes [diag : CompilerDiagnostic]) : CompilerDiagnosticNoteList
  (struct-get diag notes))

(define (compiler-diagnostic-primary-span [diag : CompilerDiagnostic]) : CompilerDiagnosticSpan
  (struct-get diag primary))

(define (compiler-diagnostic-new
  [message : String]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]
  [category : CompilerDiagnosticMaybeString]
  [primary : CompilerDiagnosticSpan]
  [help : CompilerDiagnosticMaybeString]
  [secondary : CompilerDiagnosticLabelList]
  [notes : CompilerDiagnosticNoteList]) : CompilerDiagnostic
  (CompilerDiagnostic message level code category primary help secondary notes))

(define (compiler-diagnostic-simple
  [path : String]
  [line : i64]
  [col : i64]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    CompilerDiagnosticError
    CompilerDiagnosticNoString
    CompilerDiagnosticNoString
    (CompilerDiagnosticSpan path line col line col)
    CompilerDiagnosticNoString
    CompilerDiagnosticLabelNil
    CompilerDiagnosticNoteNil))

(define (compiler-diagnostic-from-span
  [path : String]
  [span : SourceSpan]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    CompilerDiagnosticError
    CompilerDiagnosticNoString
    CompilerDiagnosticNoString
    (CompilerDiagnosticSpan
      path
      (span-start-line span)
      (span-start-col span)
      (span-end-line span)
      (span-end-col span))
    CompilerDiagnosticNoString
    CompilerDiagnosticLabelNil
    CompilerDiagnosticNoteNil))

(define (compiler-diagnostic-from-ast-span
  [path : String]
  [span : AstSourceSpan]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    CompilerDiagnosticError
    CompilerDiagnosticNoString
    CompilerDiagnosticNoString
    (CompilerDiagnosticSpan
      path
      (struct-get span start-line)
      (struct-get span start-col)
      (struct-get span end-line)
      (struct-get span end-col))
    CompilerDiagnosticNoString
    CompilerDiagnosticLabelNil
    CompilerDiagnosticNoteNil))

(define (compiler-diagnostic-from-source-error
  [path : String]
  [err : SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-from-span
    path
    (source-error-span err)
    (source-error-message err)))

(define (compiler-diagnostic-at-start [path : String] [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-simple path 1 1 message))

(define (compiler-diagnostic-with-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (CompilerDiagnosticSpan
      path
      (compiler-diagnostic-line diag)
      (compiler-diagnostic-col diag)
      (compiler-diagnostic-end-line diag)
      (compiler-diagnostic-end-col diag))
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-with-level
  [diag : CompilerDiagnostic]
  [level : CompilerDiagnosticLevel]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    level
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-with-code
  [diag : CompilerDiagnostic]
  [code : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (CompilerDiagnosticSomeString code)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-with-category
  [diag : CompilerDiagnostic]
  [category : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (CompilerDiagnosticSomeString category)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-with-help
  [diag : CompilerDiagnostic]
  [help : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (CompilerDiagnosticSomeString help)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-with-secondary
  [diag : CompilerDiagnostic]
  [span : CompilerDiagnosticSpan]
  [label : CompilerDiagnosticMaybeString]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (CompilerDiagnosticLabelCons
      (CompilerDiagnosticLabel span label)
      (box (compiler-diagnostic-secondary-spans diag)))
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-with-note
  [diag : CompilerDiagnostic]
  [note : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (CompilerDiagnosticNoteCons note (box (compiler-diagnostic-notes diag)))))

(define (compiler-diagnostic-with-primary-span
  [diag : CompilerDiagnostic]
  [span : CompilerDiagnosticSpan]) : CompilerDiagnostic
  (compiler-diagnostic-new
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    span
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

;; Reuse a diagnostic's location (path/line/col) with a new message. Used by the
;;
;; backend to stamp an error message onto a function's source span (#605).
(define (compiler-diagnostic-with-message
  [diag : CompilerDiagnostic]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-new
    message
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-category diag)
    (compiler-diagnostic-primary-span diag)
    (compiler-diagnostic-help diag)
    (compiler-diagnostic-secondary-spans diag)
    (compiler-diagnostic-notes diag)))

(define (compiler-diagnostic-render-notes [notes : CompilerDiagnosticNoteList]) : String
  (match notes
    [(CompilerDiagnosticNoteNil) ""]
    [(CompilerDiagnosticNoteCons note rest)
      (string-append
        "\nnote: "
        (string-append note (compiler-diagnostic-render-notes (box-get rest))))]))

(define (compiler-diagnostic-render [diag : CompilerDiagnostic]) : String
  (string-append
    (string-append
      (compiler-diagnostic-path diag)
      (string-append
        ":"
        (string-append
          (int->string (compiler-diagnostic-line diag))
          (string-append
            ":"
            (string-append
              (int->string (compiler-diagnostic-col diag))
              (string-append ": " (compiler-diagnostic-message diag)))))))
    (compiler-diagnostic-render-notes (compiler-diagnostic-notes diag))))

(define (compiler-diagnostic-level-render [level : CompilerDiagnosticLevel]) : String
  (match level
    [(CompilerDiagnosticError) "error"]
    [(CompilerDiagnosticWarning) "warning"]
    [(CompilerDiagnosticNote) "note"]))

(define (compiler-diagnostic-repeat [chunk : String] [count : i64]) : String
  (let
    [idx : i64 0]
    [out : String ""]
    (begin
      (while (< idx count)
        (begin
          (set! out (string-append out chunk))
          (set! idx (+ idx 1))))
      out)))

(define (compiler-diagnostic-line-gutter [line : i64]) : String
  (let
    [line-text : String (int->string line)]
    (if (< line 10)
      (string-append " " line-text)
      line-text)))

(define (compiler-diagnostic-blank-gutter [line : i64]) : String
  (compiler-diagnostic-repeat
    " "
    (string-length (compiler-diagnostic-line-gutter line))))

(define (compiler-diagnostic-column-padding [col : i64]) : i64
  (if (> col 1)
    (- col 1)
    0))

(define (compiler-diagnostic-string-eq? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    (if (= left-len right-len)
      (let
        [idx : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< idx left-len))
            (begin
              (if (= (string-ref left idx) (string-ref right idx))
                unit
                (set! ok false))
              (set! idx (+ idx 1))))
          ok))
      false)))

(define (compiler-diagnostic-source-line [source : String] [target-line : i64]) : CompilerDiagnosticMaybeString
  (if (< target-line 1)
    CompilerDiagnosticNoString
    (let
      [idx : i64 0]
      [n : i64 (string-length source)]
      [line : i64 1]
      [start : i64 0]
      [done : bool false]
      [out : String ""]
      (begin
        (while (and (< idx n) (not done))
          (begin
            (if (= line target-line)
              (if (= (string-ref source idx) #\newline')
                (begin
                  (set! out (substring source start (- idx start)))
                  (set! done true))
                unit)
              unit)
            (if (and (not done) (= (string-ref source idx) #\newline'))
              (begin
                (set! line (+ line 1))
                (set! start (+ idx 1)))
              unit)
            (set! idx (+ idx 1))))
        (if done
          (CompilerDiagnosticSomeString out)
          (if (= line target-line)
            (CompilerDiagnosticSomeString (substring source start (- n start)))
            CompilerDiagnosticNoString))))))

(define (compiler-diagnostic-render-header
  [diag : CompilerDiagnostic]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]) : String
  (let
    [level-text : String (compiler-diagnostic-level-render level)]
    (match code
      [(CompilerDiagnosticSomeString code-text)
        (compiler-diagnostic-cat3
          level-text
          "["
          (compiler-diagnostic-cat3
            code-text
            "]: "
            (string-append (compiler-diagnostic-message diag) "\n")))]
      [CompilerDiagnosticNoString
        (compiler-diagnostic-cat3
          level-text
          ": "
          (string-append (compiler-diagnostic-message diag) "\n"))])))

(define (compiler-diagnostic-render-location [diag : CompilerDiagnostic]) : String
  (compiler-diagnostic-cat3
    "  --> "
    (compiler-diagnostic-path diag)
    (compiler-diagnostic-cat3
      ":"
      (int->string (compiler-diagnostic-line diag))
      (compiler-diagnostic-cat3
        ":"
        (int->string (compiler-diagnostic-col diag))
        "\n"))))

(define (compiler-diagnostic-render-source-snippet
  [diag : CompilerDiagnostic]
  [source : String]) : String
  (match (compiler-diagnostic-source-line
    source
    (compiler-diagnostic-line diag))
    [(CompilerDiagnosticSomeString line-text)
      (let
        [line : i64 (compiler-diagnostic-line diag)]
        [gutter : String (compiler-diagnostic-line-gutter line)]
        [blank : String (compiler-diagnostic-blank-gutter line)]
        [padding : String
          (compiler-diagnostic-repeat
            " "
            (compiler-diagnostic-column-padding (compiler-diagnostic-col diag)))]
        (string-append
          (compiler-diagnostic-cat3 gutter " | " (string-append line-text "\n"))
          (compiler-diagnostic-cat3
            blank
            " | "
            (compiler-diagnostic-cat3 padding "^" "\n"))))]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-help [help : CompilerDiagnosticMaybeString]) : String
  (match help
    [(CompilerDiagnosticSomeString text)
      (compiler-diagnostic-cat3 "   = help: " text "\n")]
    [CompilerDiagnosticNoString ""]))

(define (compiler-diagnostic-render-source-notes
  [notes : CompilerDiagnosticNoteList]) : String
  (match notes
    [(CompilerDiagnosticNoteNil) ""]
    [(CompilerDiagnosticNoteCons note rest)
      (compiler-diagnostic-cat3
        "   = note: "
        note
        (string-append
          "\n"
          (compiler-diagnostic-render-source-notes (box-get rest))))]))

(define (compiler-diagnostic-render-source-with-metadata
  [diag : CompilerDiagnostic]
  [source : String]
  [level : CompilerDiagnosticLevel]
  [code : CompilerDiagnosticMaybeString]
  [help : CompilerDiagnosticMaybeString]) : String
  (string-append
    (compiler-diagnostic-render-header diag level code)
    (string-append
      (compiler-diagnostic-render-location diag)
      (string-append
        "   |\n"
        (string-append
          (compiler-diagnostic-render-source-snippet diag source)
          (string-append
            (compiler-diagnostic-render-help help)
            (compiler-diagnostic-render-source-notes
              (compiler-diagnostic-notes diag))))))))

(define (compiler-diagnostic-render-source
  [diag : CompilerDiagnostic]
  [source : String]) : String
  (compiler-diagnostic-render-source-with-metadata
    diag
    source
    (compiler-diagnostic-level diag)
    (compiler-diagnostic-code diag)
    (compiler-diagnostic-help diag)))

(define (compiler-diagnostic-render-ok?) : bool
  (string-eq
    (compiler-diagnostic-render
      (compiler-diagnostic-simple "demo.tl" 3 7 "parse: malformed define"))
    "demo.tl:3:7: parse: malformed define"))

(define (compiler-diagnostic-source-error-ok?) : bool
  (let
    [err : SourceError
      (SourceError "lexer: unexpected character" (SourceSpan 4 5 4 6))]
    [diag : CompilerDiagnostic
      (compiler-diagnostic-from-source-error "input.tl" err)]
    (and
      (string-eq (compiler-diagnostic-path diag) "input.tl")
      (and
        (= (compiler-diagnostic-line diag) 4)
        (and
          (= (compiler-diagnostic-col diag) 5)
          (string-eq
            (compiler-diagnostic-message diag)
            "lexer: unexpected character"))))))

(define (compiler-diagnostic-rewrite-ok?) : bool
  (let
    [diag : CompilerDiagnostic (compiler-diagnostic-simple "old.tl" 1 2 "old")]
    [moved : CompilerDiagnostic (compiler-diagnostic-with-path diag "new.tl")]
    [rewritten : CompilerDiagnostic
      (compiler-diagnostic-with-message moved "new message")]
    (and
      (string-eq (compiler-diagnostic-path rewritten) "new.tl")
      (and
        (= (compiler-diagnostic-line rewritten) 1)
        (and
          (= (compiler-diagnostic-col rewritten) 2)
          (string-eq (compiler-diagnostic-message rewritten) "new message"))))))

(define (compiler-diagnostic-source-render-ok?) : bool
  (let
    [diag : CompilerDiagnostic
      (compiler-diagnostic-with-help
        (compiler-diagnostic-with-code
          (compiler-diagnostic-simple "test.tl" 3 6 "type mismatch")
          "E0001")
        "expected i64, found bool")]
    [source : String "(define x true)\n(define y 42)\n(+ x y)\n"]
    [out : String (compiler-diagnostic-render-source diag source)]
    (compiler-diagnostic-string-eq?
      out
      "error[E0001]: type mismatch\n  --> test.tl:3:6\n   |\n 3 | (+ x y)\n   |      ^\n   = help: expected i64, found bool\n")))

(define (compiler-diagnostic-source-render-minimal-ok?) : bool
  (let
    [diag : CompilerDiagnostic
      (compiler-diagnostic-with-level
        (compiler-diagnostic-simple "lib.tl" 1 1 "heads up")
        CompilerDiagnosticWarning)]
    [out : String (compiler-diagnostic-render-source diag "x\n")]
    (compiler-diagnostic-string-eq?
      out
      "warning: heads up\n  --> lib.tl:1:1\n   |\n 1 | x\n   | ^\n")))

(define (compiler-diagnostic-note-render-ok?) : bool
  (let
    [diag : CompilerDiagnostic
      (compiler-diagnostic-with-note
        (compiler-diagnostic-simple "note.tl" 2 3 "has note")
        "generated identity: generated:demo")]
    [source-out : String (compiler-diagnostic-render-source diag "a\nb\n")]
    (and
      (string-eq
        (compiler-diagnostic-render diag)
        "note.tl:2:3: has note\nnote: generated identity: generated:demo")
      (compiler-diagnostic-string-eq?
        source-out
        "error: has note\n  --> note.tl:2:3\n   |\n 2 | b\n   |   ^\n   = note: generated identity: generated:demo\n"))))

(define (compiler-diagnostic-end-span-ok?) : bool
  (let
    [diag : CompilerDiagnostic
      (compiler-diagnostic-from-span
        "input.tl"
        (SourceSpan 2 3 2 9)
        "wide token")]
    [moved : CompilerDiagnostic (compiler-diagnostic-with-path diag "moved.tl")]
    (and
      (= (compiler-diagnostic-end-line moved) 2)
      (and
        (= (compiler-diagnostic-end-col moved) 9)
        (string-eq (compiler-diagnostic-path moved) "moved.tl")))))

(define (compiler-diagnostic-metadata-ok?) : bool
  (let
    [diag : CompilerDiagnostic
      (compiler-diagnostic-with-note
        (compiler-diagnostic-with-note
          (compiler-diagnostic-with-secondary
            (compiler-diagnostic-with-secondary
              (compiler-diagnostic-with-category
                (compiler-diagnostic-with-code
                  (compiler-diagnostic-simple "meta.tl" 1 2 "metadata")
                  "E1234")
                "typecheck")
              (CompilerDiagnosticSpan "first.tl" 3 4 3 7)
              (CompilerDiagnosticSomeString "first related"))
            (CompilerDiagnosticSpan "other.tl" 4 5 4 8)
            (CompilerDiagnosticSomeString "related"))
          "first note")
        "second note")]
    (match (compiler-diagnostic-secondary-spans diag)
      [(CompilerDiagnosticLabelCons label rest-labels-box)
        (match (compiler-diagnostic-notes diag)
          [(CompilerDiagnosticNoteCons note rest-notes-box)
            (let
              [rest-labels : CompilerDiagnosticLabelList
                (box-get rest-labels-box)]
              [rest-notes : CompilerDiagnosticNoteList (box-get rest-notes-box)]
              (and
                (string-eq note "second note")
                (and
                  (match rest-notes
                    [(CompilerDiagnosticNoteCons tail-note _)
                      (string-eq tail-note "first note")]
                    [CompilerDiagnosticNoteNil false])
                  (and
                    (match rest-labels
                      [(CompilerDiagnosticLabelCons _ _)
                        (string-eq
                          (compiler-diagnostic-span-path
                            (struct-get label span))
                          "other.tl")]
                      [CompilerDiagnosticLabelNil false])
                    (match (compiler-diagnostic-code diag)
                      [(CompilerDiagnosticSomeString code)
                        (string-eq code "E1234")]
                      [CompilerDiagnosticNoString false])))))]
          [CompilerDiagnosticNoteNil false])]
      [CompilerDiagnosticLabelNil false])))

(define (compiler-diagnostic-code-or-empty-ok?) : bool
  (let
    [uncoded : CompilerDiagnostic
      (compiler-diagnostic-simple "none.tl" 1 1 "none")]
    [coded : CompilerDiagnostic (compiler-diagnostic-with-code uncoded "E1234")]
    (and
      (string-eq (compiler-diagnostic-code-or-empty uncoded) "")
      (string-eq (compiler-diagnostic-code-or-empty coded) "E1234"))))

(define (compiler-diagnostic-self-test) : i64
  (begin
    (unless (compiler-diagnostic-render-ok?) (return 1))
    (unless (compiler-diagnostic-source-error-ok?) (return 2))
    (unless (compiler-diagnostic-rewrite-ok?) (return 3))
    (unless (compiler-diagnostic-source-render-ok?) (return 4))
    (unless (compiler-diagnostic-source-render-minimal-ok?) (return 4))
    (unless (compiler-diagnostic-note-render-ok?) (return 4))
    (unless (compiler-diagnostic-end-span-ok?) (return 4))
    (unless (compiler-diagnostic-metadata-ok?) (return 4))
    (unless (compiler-diagnostic-code-or-empty-ok?) (return 4))
    42))