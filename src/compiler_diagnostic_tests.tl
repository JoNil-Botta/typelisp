;; compiler_diagnostic_tests.tl - Diagnostic self-check fixtures split
;; from production compiler_diagnostic.tl.
;;
;; Holds the render/metadata/typecheck-code fixtures, the test-only
;; compiler-diagnostic-string-eq? helper (its only consumers are these
;; fixtures), the advisory producers (compiler-advisory-sink-push! and the list
;; push; no compiler phase emits advisories yet, only tests do), and the
;; compiler-diagnostic-self-test entry that drives them.
;; All production rendering and classification machinery stays in
;; compiler_diagnostic.tl.
(import compiler_diagnostic as cdiag)
(import token)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.arena)

(define (compiler-diagnostic-string-eq? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string.string-length left)]
    [right-len : i64 (string.string-length right)]
    (if (= left-len right-len)
      (let
        [idx : i64 0]
        [ok : bool true]
        (begin
          (while (and ok (< idx left-len))
            (begin
              (if (= (string.string-ref left idx) (string.string-ref right idx))
                unit
                (set! ok false))
              (set! idx (+ idx 1))))
          ok))
      false)))

(define (compiler-diagnostic-render-ok?) : bool
  (string.eq
    (let
      [diag
        (cdiag.compiler-diagnostic-simple
          "demo.tl"
          3
          7
          "parse: malformed define")]
      (cdiag.compiler-diagnostic-render diag))
    "demo.tl:3:7: parse: malformed define"))

(define (compiler-diagnostic-flat-secondary-ok?) : bool
  (string.eq
    (let
      [diag
        (cdiag.compiler-diagnostic-with-secondary
          (cdiag.compiler-diagnostic-simple "template.tl" 2 14 "type mismatch")
          (cdiag.CompilerDiagnosticSpan "caller.tl" 7 9 7 15)
          (cdiag.CompilerDiagnosticSomeString
            "in expansion of macro `demo` invoked here"))]
      (cdiag.compiler-diagnostic-render diag))
    "template.tl:2:14: type mismatch\nrelated: caller.tl:7:9: in expansion of macro `demo` invoked here"))

(define (compiler-diagnostic-source-error-ok?) : bool
  (let
    [err : token.SourceError
      (token.SourceError
        "lexer: unexpected character"
        (token.SourceSpan 4 5 4 6))]
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-from-source-error "input.tl" err)]
    (and
      (string.eq (cdiag.compiler-diagnostic-path diag) "input.tl")
      (= (cdiag.compiler-diagnostic-line diag) 4)
      (= (cdiag.compiler-diagnostic-col diag) 5)
      (string.eq
        (cdiag.compiler-diagnostic-message diag)
        "lexer: unexpected character"))))

(define (compiler-diagnostic-rewrite-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple "old.tl" 1 2 "old")]
    [moved : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-path diag "new.tl")]
    [rewritten : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-message moved "new message")]
    (and
      (string.eq (cdiag.compiler-diagnostic-path rewritten) "new.tl")
      (= (cdiag.compiler-diagnostic-line rewritten) 1)
      (= (cdiag.compiler-diagnostic-col rewritten) 2)
      (string.eq (cdiag.compiler-diagnostic-message rewritten) "new message"))))

(define (compiler-diagnostic-fallback-path-ok?) : bool
  (let
    [unlocated : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple "" 4 9 "synthetic")]
    [located : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple "leaf.tl" 7 22 "source")]
    [fallback : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-fallback-path (clone unlocated) "root.tl")]
    [preserved : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-fallback-path located "root.tl")]
    [empty-fallback : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-fallback-path unlocated "")]
    (and
      (string.eq (cdiag.compiler-diagnostic-path fallback) "root.tl")
      (= (cdiag.compiler-diagnostic-line fallback) 4)
      (= (cdiag.compiler-diagnostic-col fallback) 9)
      (string.eq (cdiag.compiler-diagnostic-path preserved) "leaf.tl")
      (= (cdiag.compiler-diagnostic-line preserved) 7)
      (= (cdiag.compiler-diagnostic-col preserved) 22)
      (string.eq (cdiag.compiler-diagnostic-path empty-fallback) ""))))

;; A diagnostic in `whole.tl`, a three-line head followed by a tail: pathless
;; and `whole.tl` spans move to the head or the tail by line, tail lines count
;; from the tail's first line, and a span in another file stays put.
(define (compiler-diagnostic-split-at-line-span-is?
  [span : (& span cdiag.CompilerDiagnosticSpan)]
  [path : String]
  [start-line : i64]
  [end-line : i64]) : bool
  (and
    (string.eq (cdiag.compiler-diagnostic-span-path span) path)
    (= (cdiag.compiler-diagnostic-span-start-line span) start-line)
    (= (cdiag.compiler-diagnostic-span-end-line span) end-line)))

(define (compiler-diagnostic-split-at-line-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-fix
        (cdiag.compiler-diagnostic-with-secondary
          (cdiag.compiler-diagnostic-with-secondary
            (cdiag.compiler-diagnostic-with-secondary
              (cdiag.compiler-diagnostic-with-primary-span
                (cdiag.compiler-diagnostic-simple "" 5 2 "in the tail")
                (cdiag.CompilerDiagnosticSpan "" 5 2 6 4))
              (cdiag.CompilerDiagnosticSpan "other.tl" 9 1 9 3)
              cdiag.CompilerDiagnosticNoString)
            (cdiag.CompilerDiagnosticSpan "whole.tl" 4 1 4 2)
            cdiag.CompilerDiagnosticNoString)
          (cdiag.CompilerDiagnosticSpan "" 2 1 2 5)
          cdiag.CompilerDiagnosticNoString)
        (cdiag.compiler-diagnostic-fix-new
          "fix"
          cdiag.CompilerDiagnosticMachineApplicable
          (cdiag.compiler-diagnostic-text-edit-single
            (cdiag.compiler-diagnostic-text-edit-new
              (cdiag.CompilerDiagnosticSpan "" 6 1 6 1)
              "x"))))]
    [split : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-split-at-line
        diag
        "whole.tl"
        3
        "head.tl"
        "tail.tl")]
    [primary : cdiag.CompilerDiagnosticSpan
      (cdiag.compiler-diagnostic-primary-span split)]
    [labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans split)]
    [head-label : cdiag.CompilerDiagnosticLabel
      (cdiag.compiler-diagnostic-label-list-get labels 0)]
    [tail-label : cdiag.CompilerDiagnosticLabel
      (cdiag.compiler-diagnostic-label-list-get labels 1)]
    [other-label : cdiag.CompilerDiagnosticLabel
      (cdiag.compiler-diagnostic-label-list-get labels 2)]
    [fixes : cdiag.CompilerDiagnosticFixSeq
      (cdiag.compiler-diagnostic-fixes split)]
    [fix : cdiag.CompilerDiagnosticFix
      (unsafe
        (ptr-read (ptr-offset (__tl_array-data fixes.slots) 0)))]
    [edit : cdiag.CompilerDiagnosticTextEdit
      (unsafe
        (ptr-read (ptr-offset (__tl_array-data fix.edits.slots) 0)))]
    [in-head : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-split-at-line
        (cdiag.compiler-diagnostic-simple "whole.tl" 3 7 "in the head")
        "whole.tl"
        3
        "head.tl"
        "tail.tl")]
    (and
      (compiler-diagnostic-split-at-line-span-is? (& primary) "tail.tl" 2 3)
      (= (cdiag.compiler-diagnostic-col split) 2)
      (compiler-diagnostic-split-at-line-span-is?
        (& head-label.span)
        "head.tl"
        2
        2)
      (compiler-diagnostic-split-at-line-span-is?
        (& tail-label.span)
        "tail.tl"
        1
        1)
      (compiler-diagnostic-split-at-line-span-is?
        (& other-label.span)
        "other.tl"
        9
        9)
      (compiler-diagnostic-split-at-line-span-is? (& edit.span) "tail.tl" 3 3)
      (string.eq (cdiag.compiler-diagnostic-path in-head) "head.tl")
      (= (cdiag.compiler-diagnostic-line in-head) 3)
      (= (cdiag.compiler-diagnostic-col in-head) 7))))

(define (compiler-diagnostic-source-render-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-help
        (cdiag.compiler-diagnostic-with-code
          (cdiag.compiler-diagnostic-simple "test.tl" 3 6 "type mismatch")
          "E0001")
        "expected i64, found bool")]
    [source : String "(define x true)\n(define y 42)\n(+ x y)\n"]
    [out : String (cdiag.compiler-diagnostic-render-source diag source)]
    (compiler-diagnostic-string-eq?
      out
      "error[E0001]: type mismatch\n  --> test.tl:3:6\n   |\n 3 | (+ x y)\n   |      ^\n   = help: expected i64, found bool\n")))

(define (compiler-diagnostic-source-render-minimal-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-level
        (cdiag.compiler-diagnostic-simple "lib.tl" 1 1 "heads up")
        cdiag.CompilerDiagnosticWarning)]
    [out : String (cdiag.compiler-diagnostic-render-source diag "x\n")]
    (compiler-diagnostic-string-eq?
      out
      "warning: heads up\n  --> lib.tl:1:1\n   |\n 1 | x\n   | ^\n")))

(define (compiler-diagnostic-note-render-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-note
        (cdiag.compiler-diagnostic-simple "note.tl" 2 3 "has note")
        "generated identity: generated:demo")]
    [source-out : String
      (cdiag.compiler-diagnostic-render-source (clone diag) "a\nb\n")]
    (and
      (string.eq
        (cdiag.compiler-diagnostic-render diag)
        "note.tl:2:3: has note\nnote: generated identity: generated:demo")
      (compiler-diagnostic-string-eq?
        source-out
        "error: has note\n  --> note.tl:2:3\n   |\n 2 | b\n   |   ^\n   = note: generated identity: generated:demo\n"))))

(cfg
  test
  (define (compiler-diagnostic-source-render-secondary-ok?) : bool
    (let
      [diag : cdiag.CompilerDiagnostic
        (cdiag.compiler-diagnostic-with-note
          (cdiag.compiler-diagnostic-with-help
            (cdiag.compiler-diagnostic-with-code
              (cdiag.compiler-diagnostic-with-secondary
                (cdiag.compiler-diagnostic-with-secondary
                  (cdiag.compiler-diagnostic-from-span
                    "meta.tl"
                    (token.SourceSpan 1 2 1 8)
                    "metadata")
                  (cdiag.CompilerDiagnosticSpan "" 3 4 3 5)
                  (cdiag.CompilerDiagnosticSomeString "second related"))
                (cdiag.CompilerDiagnosticSpan "" 2 11 2 13)
                (cdiag.CompilerDiagnosticSomeString "first related"))
              "E1234")
            "inspect references")
          "first note")]
      [source : String "(define x true)\n(define y 42)\n(+ x y)\n"]
      [out : String (cdiag.compiler-diagnostic-render-source diag source)]
      (compiler-diagnostic-string-eq?
        out
        "error[E1234]: metadata\n  --> meta.tl:1:2\n   |\n 1 | (define x true)\n   |  ^^^^^^\n  --> meta.tl:2:11\n   |\n 2 | (define y 42)\n   |           ^^ first related\n  --> meta.tl:3:4\n   |\n 3 | (+ x y)\n   |    ^ second related\n   = help: inspect references\n   = note: first note\n"))))

;; The line index answers exactly what a scan from byte 0 answered: lines
;; between `\n` bytes, CR kept, one more line than there are newlines.
(define (compiler-diagnostic-source-line-is?
  [text : String]
  [line : i64]
  [expected : String]) : bool
  (let
    [source : cdiag.CompilerDiagnosticSource
      (cdiag.compiler-diagnostic-source-index text)]
    (match (cdiag.compiler-diagnostic-source-line (& source) line)
      [(cdiag.CompilerDiagnosticSomeString got) (string.eq got expected)]
      [cdiag.CompilerDiagnosticNoString false])))

(define (compiler-diagnostic-source-line-none? [text : String] [line : i64]) : bool
  (let
    [source : cdiag.CompilerDiagnosticSource
      (cdiag.compiler-diagnostic-source-index text)]
    (match (cdiag.compiler-diagnostic-source-line (& source) line)
      [(cdiag.CompilerDiagnosticSomeString _) false]
      [cdiag.CompilerDiagnosticNoString true])))

(define (compiler-diagnostic-source-index-ok?) : bool
  (and
    ;; First line, and a last line with no trailing newline.
    (compiler-diagnostic-source-line-is? "ab\ncd" 1 "ab")
    (compiler-diagnostic-source-line-is? "ab\ncd" 2 "cd")
    ;; A trailing newline leaves an empty last line; one past it is absent.
    (compiler-diagnostic-source-line-is? "ab\n" 2 "")
    (compiler-diagnostic-source-line-none? "ab\n" 3)
    ;; The empty text has one empty line.
    (compiler-diagnostic-source-line-is? "" 1 "")
    (compiler-diagnostic-source-line-none? "" 2)
    ;; Lines past the end, and before the first.
    (compiler-diagnostic-source-line-none? "ab\ncd" 3)
    (compiler-diagnostic-source-line-none? "ab\ncd" 0)
    ;; CRLF: the CR stays on its line, as a byte scan leaves it.
    (compiler-diagnostic-source-line-is? "a\r\nb\r\n" 1 "a\r")
    (compiler-diagnostic-source-line-is? "a\r\nb\r\n" 2 "b\r")
    (compiler-diagnostic-source-line-is? "a\r\nb\r\n" 3 "")
    (compiler-diagnostic-source-line-is? "x\n\n\ny" 3 "")
    (compiler-diagnostic-source-line-is? "x\n\n\ny" 4 "y")))

;; A secondary label on a line before the primary one, and on the primary's
;; own line, both quote the right source line from the one index.
(define (compiler-diagnostic-source-render-earlier-secondary-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-secondary
        (cdiag.compiler-diagnostic-with-secondary
          (cdiag.compiler-diagnostic-from-span
            "back.tl"
            (token.SourceSpan 3 2 3 3)
            "late use")
          (cdiag.CompilerDiagnosticSpan "" 3 4 3 5)
          (cdiag.CompilerDiagnosticSomeString "same line"))
        (cdiag.CompilerDiagnosticSpan "" 1 9 1 10)
        (cdiag.CompilerDiagnosticSomeString "defined here"))]
    [source : String "(define x true)\n(define y 42)\n(+ x y)"]
    [out : String (cdiag.compiler-diagnostic-render-source diag source)]
    (compiler-diagnostic-string-eq?
      out
      "error: late use\n  --> back.tl:3:2\n   |\n 3 | (+ x y)\n   |  ^\n  --> back.tl:1:9\n   |\n 1 | (define x true)\n   |         ^ defined here\n  --> back.tl:3:4\n   |\n 3 | (+ x y)\n   |    ^ same line\n")))

(define (compiler-diagnostic-end-span-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-from-span
        "input.tl"
        (token.SourceSpan 2 3 2 9)
        "wide token")]
    [moved : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-path diag "moved.tl")]
    (and
      (= (cdiag.compiler-diagnostic-end-line moved) 2)
      (= (cdiag.compiler-diagnostic-end-col moved) 9)
      (string.eq (cdiag.compiler-diagnostic-path moved) "moved.tl"))))

(define (compiler-diagnostic-metadata-ok?) : bool
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-note
        (cdiag.compiler-diagnostic-with-note
          (cdiag.compiler-diagnostic-with-secondary
            (cdiag.compiler-diagnostic-with-secondary
              (cdiag.compiler-diagnostic-with-category
                (cdiag.compiler-diagnostic-with-code
                  (cdiag.compiler-diagnostic-simple "meta.tl" 1 2 "metadata")
                  "E1234")
                "typecheck")
              (cdiag.CompilerDiagnosticSpan "first.tl" 3 4 3 7)
              (cdiag.CompilerDiagnosticSomeString "first related"))
            (cdiag.CompilerDiagnosticSpan "other.tl" 4 5 4 8)
            (cdiag.CompilerDiagnosticSomeString "related"))
          "first note")
        "second note")]
    [labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans diag)]
    [notes : cdiag.CompilerDiagnosticNoteList
      (cdiag.compiler-diagnostic-notes diag)]
    [first-label : cdiag.CompilerDiagnosticLabel
      (cdiag.compiler-diagnostic-label-list-get labels 0)]
    [second-label : cdiag.CompilerDiagnosticLabel
      (cdiag.compiler-diagnostic-label-list-get labels 1)]
    (and
      (= (cdiag.compiler-diagnostic-label-list-count labels) 2)
      (= (cdiag.compiler-diagnostic-note-list-count notes) 2)
      (string.eq
        (cdiag.compiler-diagnostic-note-list-get notes 0)
        "second note")
      (string.eq (cdiag.compiler-diagnostic-note-list-get notes 1) "first note")
      (string.eq
        (cdiag.compiler-diagnostic-span-path (& first-label.span))
        "other.tl")
      (string.eq
        (cdiag.compiler-diagnostic-span-path (& second-label.span))
        "first.tl")
      (match (cdiag.compiler-diagnostic-code diag)
        [(cdiag.CompilerDiagnosticSomeString code) (string.eq code "E1234")]
        [cdiag.CompilerDiagnosticNoString false]))))

(define (compiler-diagnostic-code-or-empty-ok?) : bool
  (let
    [uncoded : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple "none.tl" 1 1 "none")]
    [coded : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-code (clone uncoded) "E1234")]
    (and
      (string.eq (cdiag.compiler-diagnostic-code-or-empty uncoded) "")
      (string.eq (cdiag.compiler-diagnostic-code-or-empty coded) "E1234"))))

(define (compiler-diagnostic-dense-sequences-ok?) : bool
  (let
    [base : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple "dense.tl" 1 1 "base")]
    [note-one : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-note (clone base) "one")]
    [note-two : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-note (clone note-one) "two")]
    [label-one : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-secondary
        (clone base)
        (cdiag.CompilerDiagnosticSpan "one.tl" 1 1 1 2)
        cdiag.CompilerDiagnosticNoString)]
    [label-two : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-secondary
        (clone label-one)
        (cdiag.CompilerDiagnosticSpan "two.tl" 2 1 2 2)
        cdiag.CompilerDiagnosticNoString)]
    [base-notes : cdiag.CompilerDiagnosticNoteList
      (cdiag.compiler-diagnostic-notes base)]
    [one-notes : cdiag.CompilerDiagnosticNoteList
      (cdiag.compiler-diagnostic-notes note-one)]
    [two-notes : cdiag.CompilerDiagnosticNoteList
      (cdiag.compiler-diagnostic-notes note-two)]
    [base-labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans base)]
    [one-labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans label-one)]
    [two-labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans label-two)]
    [empty-diagnostics : cdiag.CompilerDiagnosticList
      (cdiag.compiler-diagnostic-list-empty)]
    [single-diagnostics : cdiag.CompilerDiagnosticList
      (cdiag.compiler-diagnostic-list-single
        (cdiag.compiler-diagnostic-simple "dense.tl" 1 1 "single"))]
    [diagnostics : cdiag.CompilerDiagnosticList
      (cdiag.compiler-diagnostic-list-empty)]
    (begin
      (cdiag.compiler-diagnostic-list-push!
        (&mut diagnostics)
        (cdiag.compiler-diagnostic-simple "dense.tl" 1 1 "one"))
      (cdiag.compiler-diagnostic-list-push!
        (&mut diagnostics)
        (cdiag.compiler-diagnostic-simple "dense.tl" 3 1 "three"))
      (cdiag.compiler-diagnostic-list-insert!
        (&mut diagnostics)
        1
        (cdiag.compiler-diagnostic-simple "dense.tl" 2 1 "two"))
      (and
        (= (cdiag.compiler-diagnostic-note-list-count base-notes) 0)
        (= (cdiag.compiler-diagnostic-note-list-count one-notes) 1)
        (= (cdiag.compiler-diagnostic-note-list-count two-notes) 2)
        (string.eq (cdiag.compiler-diagnostic-note-list-get one-notes 0) "one")
        (string.eq (cdiag.compiler-diagnostic-note-list-get two-notes 0) "two")
        (string.eq (cdiag.compiler-diagnostic-note-list-get two-notes 1) "one")
        (= (cdiag.compiler-diagnostic-label-list-count base-labels) 0)
        (= (cdiag.compiler-diagnostic-label-list-count one-labels) 1)
        (= (cdiag.compiler-diagnostic-label-list-count two-labels) 2)
        (= (cdiag.compiler-diagnostic-list-count empty-diagnostics) 0)
        (= (cdiag.compiler-diagnostic-list-count single-diagnostics) 1)
        (= (cdiag.compiler-diagnostic-list-count diagnostics) 3)
        (=
          (cdiag.compiler-diagnostic-line
            (cdiag.compiler-diagnostic-list-ref (& diagnostics) 0))
          1)
        (=
          (cdiag.compiler-diagnostic-line
            (cdiag.compiler-diagnostic-list-ref (& diagnostics) 1))
          2)
        (=
          (cdiag.compiler-diagnostic-line
            (cdiag.compiler-diagnostic-list-ref (& diagnostics) 2))
          3)))))

;; A typecheck error states its kind where it is raised and the code follows
;; the kind, never the wording (#7139). Kinds map one-to-one onto the
;; typecheck rows of the registry, in registry order.
(define (compiler-diagnostic-typecheck-kind-row-is?
  [kind : cdiag.CompilerTypecheckKind]
  [index : i64]) : bool
  (and
    (string.eq
      (cdiag.compiler-diagnostic-code-for-typecheck-kind kind)
      (cdiag.compiler-diagnostic-code-registry-code index))
    (string.eq
      (cdiag.compiler-diagnostic-typecheck-tag kind)
      (str_cat.str-cat
        (cdiag.compiler-diagnostic-typecheck-tag-prefix)
        (cdiag.compiler-diagnostic-code-registry-code index)
        ":"))))

(define (compiler-diagnostic-typecheck-kind-rows-ok?) : bool
  (and
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.Unclassified)
      1)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.UnboundName)
      2)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ArityMismatch)
      3)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.NonExhaustiveMatch)
      4)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.UnknownStructField)
      5)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.RegionEscape)
      6)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.TypeMismatch)
      7)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.BorrowViolation)
      8)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.MoveViolation)
      9)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.UnsafeContext)
      10)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.LifetimeMismatch)
      11)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ResourceOwnership)
      12)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ArenaOwnership)
      13)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.Pattern)
      14)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.Spmd)
      15)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.Place)
      16)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ControlFlow)
      17)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ThreadSafety)
      18)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ComptimeConstraint)
      19)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.UnsafeCallableEffect)
      20)
    (compiler-diagnostic-typecheck-kind-row-is?
      (cdiag.CompilerTypecheckKind.ForeignGlobalWrite)
      21)))

;; The code a diagnostic built from `message` carries, or "" for none.
(define (compiler-diagnostic-built-code [message : String]) : String
  (let
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-at-start "" message)]
    (match (cdiag.compiler-diagnostic-code (& diag))
      [(CompilerDiagnosticSomeString code) code]
      [CompilerDiagnosticNoString ""])))

;; The wording of a tagged message never changes its code: text full of other
;; families' words keeps the kind it was raised with, and a reworded message
;; keeps its code. The tag never reaches the rendered text, an explicit code
;; wins over it, and it survives a round trip through error text only for a
;; typecheck code.
(define (compiler-diagnostic-typecheck-kind-transport-ok?) : bool
  (let
    [decoy : String
      "typecheck: cleanup foreach SPMD arity mismatch unbound name cannot escape borrow requires"]
    [tagged : String
      (cdiag.compiler-diagnostic-typecheck-tagged
        (cdiag.CompilerTypecheckKind.TypeMismatch)
        (string.copy (& decoy)))]
    [diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-at-start "" (string.copy (& tagged)))]
    [explicit : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-new
        (string.copy (& tagged))
        CompilerDiagnosticError
        (CompilerDiagnosticSomeString "E0100")
        CompilerDiagnosticNoString
        (cdiag.CompilerDiagnosticSpan "" 1 1 1 1)
        CompilerDiagnosticNoString
        (cdiag.compiler-diagnostic-label-list-empty)
        (cdiag.compiler-diagnostic-note-list-empty))]
    (and
      (string.eq
        (compiler-diagnostic-built-code (string.copy (& tagged)))
        "E0206")
      (string.eq (cdiag.compiler-diagnostic-message diag) decoy)
      (string.eq
        (compiler-diagnostic-built-code
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.UnboundName)
            "typecheck: no binding called `x` is visible here"))
        "E0201")
      (string.eq
        (compiler-diagnostic-built-code
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.UnboundName)
            "typecheck: unbound name x"))
        "E0201")
      (string.eq
        (compiler-diagnostic-built-code "typecheck: unbound name x")
        "")
      (string.eq (compiler-diagnostic-built-code "__tl_tc_kind:E0206") "")
      (string.eq
        (compiler-diagnostic-built-code "__tl_tc_kind:E0299:typecheck: x")
        "E0299")
      (string.eq
        (compiler-diagnostic-built-code "__tl_tc_kind:E0106:typecheck: x")
        "E0106")
      (string.eq
        (compiler-diagnostic-built-code "__tl_tc_kind:E0206-typecheck: x")
        "")
      (not (string.contains (& tagged) "|"))
      (match (cdiag.compiler-diagnostic-code (& explicit))
        [(CompilerDiagnosticSomeString code) (string.eq code "E0100")]
        [CompilerDiagnosticNoString false])
      (string.eq (cdiag.compiler-diagnostic-message explicit) decoy)
      (string.eq
        (cdiag.compiler-diagnostic-typecheck-error-text (& diag))
        tagged)
      (string.eq
        (cdiag.compiler-diagnostic-typecheck-error-text (& explicit))
        decoy)
      (string.eq
        (cdiag.compiler-diagnostic-untagged-message (string.copy (& decoy)))
        decoy))))

(define (compiler-diagnostic-code-registry-ok?) : bool
  (let
    [count : i64 (cdiag.compiler-diagnostic-code-registry-count)]
    [index : i64 0]
    [ok : bool (= count 22)]
    (begin
      (while (and ok (< index count))
        (let
          [code : String (cdiag.compiler-diagnostic-code-registry-code index)]
          [other : i64 (+ index 1)]
          (begin
            (if (and
              (> (string.string-length code) 0)
              (>
                (string.string-length
                  (cdiag.compiler-diagnostic-code-registry-title index))
                0)
              (>
                (string.string-length
                  (compiler-diagnostic-code-registry-category index))
                0)
              (>
                (string.string-length
                  (compiler-diagnostic-code-registry-owner index))
                0))
              unit
              (set! ok false))
            (while (and ok (< other count))
              (begin
                (if (string.eq
                  code
                  (cdiag.compiler-diagnostic-code-registry-code other))
                  (set! ok false)
                  unit)
                (set! other (+ other 1))))))
        (set! index (+ index 1)))
      (and
        ok
        (string.eq (cdiag.compiler-diagnostic-code-registry-code count) "")
        (string.eq (cdiag.compiler-diagnostic-code-registry-title count) "")
        (string.eq (compiler-diagnostic-code-registry-category count) "")
        (string.eq (compiler-diagnostic-code-registry-owner count) "")))))

(define (compiler-advisory-phase-copy [phase : cdiag.CompilerAdvisoryPhase]) : cdiag.CompilerAdvisoryPhase
  (match phase
    [(cdiag.CompilerAdvisoryPhase.Semantic)
      cdiag.CompilerAdvisoryPhase.Semantic]
    [(cdiag.CompilerAdvisoryPhase.Lowering)
      cdiag.CompilerAdvisoryPhase.Lowering]
    [(cdiag.CompilerAdvisoryPhase.Optimization)
      cdiag.CompilerAdvisoryPhase.Optimization]
    [(cdiag.CompilerAdvisoryPhase.RegisterAllocation)
      cdiag.CompilerAdvisoryPhase.RegisterAllocation]
    [(cdiag.CompilerAdvisoryPhase.Backend) cdiag.CompilerAdvisoryPhase.Backend]))

(define (compiler-advisory-list-grow!
  [advisories : (&mut advisories cdiag.CompilerAdvisoryList)]) : unit
  (let
    [count : i64 advisories.len]
    [old-capacity : i64 (array-length advisories.slots)]
    [new-capacity : i64
      (if (< old-capacity 1)
        4
        (* old-capacity 2))]
    [next : (__tl_dyn-array cdiag.CompilerAdvisory)
      (__tl_make-array cdiag.CompilerAdvisory new-capacity)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref next index)
            (cdiag.compiler-advisory-copy-ref
              (& (array-ref advisories.slots index))))
          (set! index (+ index 1))))
      (set! advisories.slots next))))

(define (compiler-advisory-list-push!
  [advisories : (&mut advisories cdiag.CompilerAdvisoryList)]
  [phase : cdiag.CompilerAdvisoryPhase]
  [diagnostic : cdiag.CompilerDiagnostic]) : unit
  (begin
    (if (< advisories.len (array-length advisories.slots))
      unit
      (compiler-advisory-list-grow! advisories))
    (let
      [index : i64 advisories.len]
      (begin
        (set!
          (array-ref advisories.slots index)
          (cdiag.CompilerAdvisory phase diagnostic))
        (set! advisories.len (+ index 1))))))

;; Return false for an error-level diagnostic instead of silently reclassifying
;; it. The caller retains the original value and must take its ordinary fatal
;; path. Accepted advisories are deep-copied while the sink arena is current.
(define (compiler-advisory-sink-push!
  [sink : cdiag.CompilerAdvisorySink]
  [phase : cdiag.CompilerAdvisoryPhase]
  [diagnostic : (& diagnostic cdiag.CompilerDiagnostic)]) : bool
  (if (match (cdiag.compiler-diagnostic-level diagnostic)
    [(cdiag.CompilerDiagnosticError) true]
    [_ false])
    false
    (let
      [data : cdiag.CompilerAdvisorySinkData
        (cdiag.compiler-advisory-sink-data sink)]
      [payload-arena : i64
        (if (= data.payload-arena 0)
          (arena.tl_arena_make_small)
          data.payload-arena)]
      [advisories : cdiag.CompilerAdvisoryList
        (if (= data.payload-arena 0)
          (in-arena
            (arena.Arena payload-arena)
            (cdiag.compiler-advisory-list-with-capacity 4))
          data.advisories)]
      (begin
        (in-arena
          (arena.Arena payload-arena)
          (compiler-advisory-list-push!
            (&mut advisories)
            (compiler-advisory-phase-copy phase)
            (cdiag.compiler-diagnostic-copy-ref diagnostic)))
        (cdiag.compiler-advisory-sink-data-set!
          sink
          (cdiag.CompilerAdvisorySinkData
            payload-arena
            advisories
            data.generation))
        true))))

(define (compiler-diagnostic-advisory-warning
  [path : String]
  [line : i64]
  [message : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-level
    (cdiag.compiler-diagnostic-simple path line 1 message)
    cdiag.CompilerDiagnosticWarning))

(define (compiler-diagnostic-advisory-sink-ok?) : bool
  (let
    [sink-a : cdiag.CompilerAdvisorySink (cdiag.compiler-advisory-sink-new)]
    [sink-b : cdiag.CompilerAdvisorySink (cdiag.compiler-advisory-sink-new)]
    [_append : unit
      (with-scratch
        (let
          [semantic : cdiag.CompilerDiagnostic
            (compiler-diagnostic-advisory-warning "first.tl" 1 "semantic")]
          [lowering : cdiag.CompilerDiagnostic
            (compiler-diagnostic-advisory-warning "first.tl" 2 "lowering")]
          [optimization : cdiag.CompilerDiagnostic
            (compiler-diagnostic-advisory-warning "first.tl" 3 "optimization")]
          [regalloc : cdiag.CompilerDiagnostic
            (compiler-diagnostic-advisory-warning "first.tl" 4 "regalloc")]
          [backend : cdiag.CompilerDiagnostic
            (compiler-diagnostic-advisory-warning "first.tl" 5 "backend")]
          [other : cdiag.CompilerDiagnostic
            (compiler-diagnostic-advisory-warning "other.tl" 1 "other job")]
          [fatal : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-simple "first.tl" 6 1 "fatal")]
          (begin
            (compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Semantic
              (& semantic))
            (compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Lowering
              (& lowering))
            (compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Optimization
              (& optimization))
            (compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.RegisterAllocation
              (& regalloc))
            (compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Backend
              (& backend))
            (compiler-advisory-sink-push!
              sink-b
              cdiag.CompilerAdvisoryPhase.Semantic
              (& other))
            (compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Backend
              (& fatal))
            unit)))]
    [a : cdiag.CompilerAdvisoryList
      (cdiag.compiler-advisory-sink-snapshot sink-a)]
    [b : cdiag.CompilerAdvisoryList
      (cdiag.compiler-advisory-sink-snapshot sink-b)]
    [a0 : cdiag.CompilerAdvisory (cdiag.compiler-advisory-list-get (& a) 0)]
    [a4 : cdiag.CompilerAdvisory (cdiag.compiler-advisory-list-get (& a) 4)]
    [b0 : cdiag.CompilerAdvisory (cdiag.compiler-advisory-list-get (& b) 0)]
    [a0-diagnostic : cdiag.CompilerDiagnostic
      (cdiag.compiler-advisory-diagnostic (& a0))]
    [a4-diagnostic : cdiag.CompilerDiagnostic
      (cdiag.compiler-advisory-diagnostic (& a4))]
    [b0-diagnostic : cdiag.CompilerDiagnostic
      (cdiag.compiler-advisory-diagnostic (& b0))]
    [before-reset : bool
      (and
        (= (cdiag.compiler-advisory-list-count (& a)) 5)
        (= (cdiag.compiler-advisory-list-count (& b)) 1)
        (match (cdiag.compiler-advisory-phase (& a0))
          [(cdiag.CompilerAdvisoryPhase.Semantic) true]
          [_ false])
        (match (cdiag.compiler-advisory-phase (& a4))
          [(cdiag.CompilerAdvisoryPhase.Backend) true]
          [_ false])
        (string.eq (cdiag.compiler-diagnostic-message a0-diagnostic) "semantic")
        (string.eq (cdiag.compiler-diagnostic-message a4-diagnostic) "backend")
        (string.eq
          (cdiag.compiler-diagnostic-message b0-diagnostic)
          "other job"))]
    (begin
      (cdiag.compiler-advisory-sink-reset! sink-a)
      (let
        [after-reset : cdiag.CompilerAdvisoryList
          (cdiag.compiler-advisory-sink-snapshot sink-a)]
        (and
          before-reset
          (= (cdiag.compiler-advisory-list-count (& after-reset)) 0)
          (= (compiler-advisory-sink-generation sink-a) 1)
          (let
            [still-b : cdiag.CompilerAdvisoryList
              (cdiag.compiler-advisory-sink-snapshot sink-b)]
            (= (cdiag.compiler-advisory-list-count (& still-b)) 1)))))))

(define (compiler-diagnostic-self-test) : i64
  (begin
    (unless (compiler-diagnostic-render-ok?) (return 1))
    (unless (compiler-diagnostic-flat-secondary-ok?) (return 1))
    (unless (compiler-diagnostic-source-error-ok?) (return 2))
    (unless (compiler-diagnostic-rewrite-ok?) (return 3))
    (unless (compiler-diagnostic-fallback-path-ok?) (return 3))
    (unless (compiler-diagnostic-split-at-line-ok?) (return 3))
    (unless (compiler-diagnostic-source-render-ok?) (return 4))
    (unless (compiler-diagnostic-source-render-minimal-ok?) (return 4))
    (unless (compiler-diagnostic-note-render-ok?) (return 4))
    (cfg
      test
      (unless (compiler-diagnostic-source-render-secondary-ok?) (return 4))
      unit)
    (unless (compiler-diagnostic-source-index-ok?) (return 4))
    (unless
      (compiler-diagnostic-source-render-earlier-secondary-ok?)
      (return 4))
    (unless (compiler-diagnostic-end-span-ok?) (return 4))
    (unless (compiler-diagnostic-metadata-ok?) (return 4))
    (unless (compiler-diagnostic-code-or-empty-ok?) (return 4))
    (unless (compiler-diagnostic-dense-sequences-ok?) (return 4))
    (unless (compiler-diagnostic-code-registry-ok?) (return 4))
    (unless (compiler-diagnostic-advisory-sink-ok?) (return 4))
    (unless (compiler-diagnostic-typecheck-kind-rows-ok?) (return 5))
    (unless (compiler-diagnostic-typecheck-kind-transport-ok?) (return 5))
    42))

(define (compiler-advisory-sink-generation [sink : cdiag.CompilerAdvisorySink]) : i64
  (cdiag.compiler-advisory-sink-data sink).generation)

(define (compiler-diagnostic-code-registry-category [index : i64]) : String
  (cond
    [(= index 0) "parse"]
    [(and (> index 0) (< index (cdiag.compiler-diagnostic-code-registry-count)))
      "typecheck"]
    [else ""]))

(define (compiler-diagnostic-code-registry-owner [index : i64]) : String
  (cond
    [(= index 0) "parser"]
    [(and (> index 0) (< index (cdiag.compiler-diagnostic-code-registry-count)))
      "typechecker"]
    [else ""]))