;; compiler_diagnostic_tests.tl - Diagnostic self-check fixtures split
;; from production compiler_diagnostic.tl (simplify.md A1, #5169 pattern).
;;
;; Holds the render/metadata/typecheck-code fixtures, the test-only
;; compiler-diagnostic-string-eq? helper (its only consumers were these
;; fixtures), and the compiler-diagnostic-self-test entry that drives them.
;; All production rendering and classification machinery stays in
;; compiler_diagnostic.tl.
(import compiler_diagnostic)
(import token)
(import stdlib.string)

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
    (compiler_diagnostic.compiler-diagnostic-render
      (compiler_diagnostic.compiler-diagnostic-simple
        "demo.tl"
        3
        7
        "parse: malformed define"))
    "demo.tl:3:7: parse: malformed define"))

(define (compiler-diagnostic-flat-secondary-ok?) : bool
  (string.eq
    (compiler_diagnostic.compiler-diagnostic-render
      (compiler_diagnostic.compiler-diagnostic-with-secondary
        (compiler_diagnostic.compiler-diagnostic-simple
          "template.tl"
          2
          14
          "type mismatch")
        (compiler_diagnostic.CompilerDiagnosticSpan "caller.tl" 7 9 7 15)
        (compiler_diagnostic.CompilerDiagnosticSomeString
          "in expansion of macro `demo` invoked here")))
    "template.tl:2:14: type mismatch\nrelated: caller.tl:7:9: in expansion of macro `demo` invoked here"))

(define (compiler-diagnostic-source-error-ok?) : bool
  (let
    [err : token.SourceError
      (token.SourceError
        "lexer: unexpected character"
        (token.SourceSpan 4 5 4 6))]
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-from-source-error "input.tl" err)]
    (and
      (string.eq (compiler_diagnostic.compiler-diagnostic-path diag) "input.tl")
      (= (compiler_diagnostic.compiler-diagnostic-line diag) 4)
      (= (compiler_diagnostic.compiler-diagnostic-col diag) 5)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-message diag)
        "lexer: unexpected character"))))

(define (compiler-diagnostic-rewrite-ok?) : bool
  (let
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-simple "old.tl" 1 2 "old")]
    [moved : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-path diag "new.tl")]
    [rewritten : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-message moved "new message")]
    (and
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-path rewritten)
        "new.tl")
      (= (compiler_diagnostic.compiler-diagnostic-line rewritten) 1)
      (= (compiler_diagnostic.compiler-diagnostic-col rewritten) 2)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-message rewritten)
        "new message"))))

(define (compiler-diagnostic-fallback-path-ok?) : bool
  (let
    [unlocated : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-simple "" 4 9 "synthetic")]
    [located : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-simple "leaf.tl" 7 22 "source")]
    [fallback : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-fallback-path
        unlocated
        "root.tl")]
    [preserved : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-fallback-path
        located
        "root.tl")]
    [empty-fallback : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-fallback-path unlocated "")]
    (and
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-path fallback)
        "root.tl")
      (= (compiler_diagnostic.compiler-diagnostic-line fallback) 4)
      (= (compiler_diagnostic.compiler-diagnostic-col fallback) 9)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-path preserved)
        "leaf.tl")
      (= (compiler_diagnostic.compiler-diagnostic-line preserved) 7)
      (= (compiler_diagnostic.compiler-diagnostic-col preserved) 22)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-path empty-fallback)
        ""))))

(define (compiler-diagnostic-source-render-ok?) : bool
  (let
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-help
        (compiler_diagnostic.compiler-diagnostic-with-code
          (compiler_diagnostic.compiler-diagnostic-simple
            "test.tl"
            3
            6
            "type mismatch")
          "E0001")
        "expected i64, found bool")]
    [source : String "(define x true)\n(define y 42)\n(+ x y)\n"]
    [out : String
      (compiler_diagnostic.compiler-diagnostic-render-source diag source)]
    (compiler-diagnostic-string-eq?
      out
      "error[E0001]: type mismatch\n  --> test.tl:3:6\n   |\n 3 | (+ x y)\n   |      ^\n   = help: expected i64, found bool\n")))

(define (compiler-diagnostic-source-render-minimal-ok?) : bool
  (let
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-level
        (compiler_diagnostic.compiler-diagnostic-simple "lib.tl" 1 1 "heads up")
        compiler_diagnostic.CompilerDiagnosticWarning)]
    [out : String
      (compiler_diagnostic.compiler-diagnostic-render-source diag "x\n")]
    (compiler-diagnostic-string-eq?
      out
      "warning: heads up\n  --> lib.tl:1:1\n   |\n 1 | x\n   | ^\n")))

(define (compiler-diagnostic-note-render-ok?) : bool
  (let
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-note
        (compiler_diagnostic.compiler-diagnostic-simple
          "note.tl"
          2
          3
          "has note")
        "generated identity: generated:demo")]
    [source-out : String
      (compiler_diagnostic.compiler-diagnostic-render-source diag "a\nb\n")]
    (and
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-render diag)
        "note.tl:2:3: has note\nnote: generated identity: generated:demo")
      (compiler-diagnostic-string-eq?
        source-out
        "error: has note\n  --> note.tl:2:3\n   |\n 2 | b\n   |   ^\n   = note: generated identity: generated:demo\n"))))

(cfg
  test
  (define (compiler-diagnostic-source-render-secondary-ok?) : bool
    (let
      [diag : compiler_diagnostic.CompilerDiagnostic
        (compiler_diagnostic.compiler-diagnostic-with-note
          (compiler_diagnostic.compiler-diagnostic-with-help
            (compiler_diagnostic.compiler-diagnostic-with-code
              (compiler_diagnostic.compiler-diagnostic-with-secondary
                (compiler_diagnostic.compiler-diagnostic-with-secondary
                  (compiler_diagnostic.compiler-diagnostic-from-span
                    "meta.tl"
                    (token.SourceSpan 1 2 1 8)
                    "metadata")
                  (compiler_diagnostic.CompilerDiagnosticSpan "" 3 4 3 5)
                  (compiler_diagnostic.CompilerDiagnosticSomeString
                    "second related"))
                (compiler_diagnostic.CompilerDiagnosticSpan "" 2 11 2 13)
                (compiler_diagnostic.CompilerDiagnosticSomeString
                  "first related"))
              "E1234")
            "inspect references")
          "first note")]
      [source : String "(define x true)\n(define y 42)\n(+ x y)\n"]
      [out : String
        (compiler_diagnostic.compiler-diagnostic-render-source diag source)]
      (compiler-diagnostic-string-eq?
        out
        "error[E1234]: metadata\n  --> meta.tl:1:2\n   |\n 1 | (define x true)\n   |  ^^^^^^\n  --> meta.tl:2:11\n   |\n 2 | (define y 42)\n   |           ^^ first related\n  --> meta.tl:3:4\n   |\n 3 | (+ x y)\n   |    ^ second related\n   = help: inspect references\n   = note: first note\n"))))

(define (compiler-diagnostic-end-span-ok?) : bool
  (let
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-from-span
        "input.tl"
        (token.SourceSpan 2 3 2 9)
        "wide token")]
    [moved : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-path diag "moved.tl")]
    (and
      (= (compiler_diagnostic.compiler-diagnostic-end-line moved) 2)
      (= (compiler_diagnostic.compiler-diagnostic-end-col moved) 9)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-path moved)
        "moved.tl"))))

(define (compiler-diagnostic-metadata-ok?) : bool
  (let
    [diag : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-note
        (compiler_diagnostic.compiler-diagnostic-with-note
          (compiler_diagnostic.compiler-diagnostic-with-secondary
            (compiler_diagnostic.compiler-diagnostic-with-secondary
              (compiler_diagnostic.compiler-diagnostic-with-category
                (compiler_diagnostic.compiler-diagnostic-with-code
                  (compiler_diagnostic.compiler-diagnostic-simple
                    "meta.tl"
                    1
                    2
                    "metadata")
                  "E1234")
                "typecheck")
              (compiler_diagnostic.CompilerDiagnosticSpan "first.tl" 3 4 3 7)
              (compiler_diagnostic.CompilerDiagnosticSomeString "first related"))
            (compiler_diagnostic.CompilerDiagnosticSpan "other.tl" 4 5 4 8)
            (compiler_diagnostic.CompilerDiagnosticSomeString "related"))
          "first note")
        "second note")]
    [labels : compiler_diagnostic.CompilerDiagnosticLabelList
      (compiler_diagnostic.compiler-diagnostic-secondary-spans diag)]
    [notes : compiler_diagnostic.CompilerDiagnosticNoteList
      (compiler_diagnostic.compiler-diagnostic-notes diag)]
    [first-label : compiler_diagnostic.CompilerDiagnosticLabel
      (compiler_diagnostic.compiler-diagnostic-label-list-get labels 0)]
    [second-label : compiler_diagnostic.CompilerDiagnosticLabel
      (compiler_diagnostic.compiler-diagnostic-label-list-get labels 1)]
    (and
      (= (compiler_diagnostic.compiler-diagnostic-label-list-count labels) 2)
      (= (compiler_diagnostic.compiler-diagnostic-note-list-count notes) 2)
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-note-list-get notes 0)
        "second note")
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-note-list-get notes 1)
        "first note")
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-span-path (& first-label.span))
        "other.tl")
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-span-path
          (& second-label.span))
        "first.tl")
      (match (compiler_diagnostic.compiler-diagnostic-code diag)
        [(compiler_diagnostic.CompilerDiagnosticSomeString code)
          (string.eq code "E1234")]
        [compiler_diagnostic.CompilerDiagnosticNoString false]))))

(define (compiler-diagnostic-code-or-empty-ok?) : bool
  (let
    [uncoded : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-simple "none.tl" 1 1 "none")]
    [coded : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-code uncoded "E1234")]
    (and
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-code-or-empty uncoded)
        "")
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-code-or-empty coded)
        "E1234"))))

(define (compiler-diagnostic-dense-sequences-ok?) : bool
  (let
    [base : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-simple "dense.tl" 1 1 "base")]
    [note-one : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-note base "one")]
    [note-two : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-note note-one "two")]
    [label-one : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-secondary
        base
        (compiler_diagnostic.CompilerDiagnosticSpan "one.tl" 1 1 1 2)
        compiler_diagnostic.CompilerDiagnosticNoString)]
    [label-two : compiler_diagnostic.CompilerDiagnostic
      (compiler_diagnostic.compiler-diagnostic-with-secondary
        label-one
        (compiler_diagnostic.CompilerDiagnosticSpan "two.tl" 2 1 2 2)
        compiler_diagnostic.CompilerDiagnosticNoString)]
    [base-notes : compiler_diagnostic.CompilerDiagnosticNoteList
      (compiler_diagnostic.compiler-diagnostic-notes base)]
    [one-notes : compiler_diagnostic.CompilerDiagnosticNoteList
      (compiler_diagnostic.compiler-diagnostic-notes note-one)]
    [two-notes : compiler_diagnostic.CompilerDiagnosticNoteList
      (compiler_diagnostic.compiler-diagnostic-notes note-two)]
    [base-labels : compiler_diagnostic.CompilerDiagnosticLabelList
      (compiler_diagnostic.compiler-diagnostic-secondary-spans base)]
    [one-labels : compiler_diagnostic.CompilerDiagnosticLabelList
      (compiler_diagnostic.compiler-diagnostic-secondary-spans label-one)]
    [two-labels : compiler_diagnostic.CompilerDiagnosticLabelList
      (compiler_diagnostic.compiler-diagnostic-secondary-spans label-two)]
    [empty-diagnostics : compiler_diagnostic.CompilerDiagnosticList
      (compiler_diagnostic.compiler-diagnostic-list-empty)]
    [single-diagnostics : compiler_diagnostic.CompilerDiagnosticList
      (compiler_diagnostic.compiler-diagnostic-list-single
        (compiler_diagnostic.compiler-diagnostic-simple "dense.tl" 1 1 "single"))]
    [diagnostics : compiler_diagnostic.CompilerDiagnosticList
      (compiler_diagnostic.compiler-diagnostic-list-empty)]
    (begin
      (compiler_diagnostic.compiler-diagnostic-list-push!
        (&mut diagnostics)
        (compiler_diagnostic.compiler-diagnostic-simple "dense.tl" 1 1 "one"))
      (compiler_diagnostic.compiler-diagnostic-list-push!
        (&mut diagnostics)
        (compiler_diagnostic.compiler-diagnostic-simple "dense.tl" 3 1 "three"))
      (compiler_diagnostic.compiler-diagnostic-list-insert!
        (&mut diagnostics)
        1
        (compiler_diagnostic.compiler-diagnostic-simple "dense.tl" 2 1 "two"))
      (and
        (=
          (compiler_diagnostic.compiler-diagnostic-note-list-count base-notes)
          0)
        (=
          (compiler_diagnostic.compiler-diagnostic-note-list-count one-notes)
          1)
        (=
          (compiler_diagnostic.compiler-diagnostic-note-list-count two-notes)
          2)
        (string.eq
          (compiler_diagnostic.compiler-diagnostic-note-list-get one-notes 0)
          "one")
        (string.eq
          (compiler_diagnostic.compiler-diagnostic-note-list-get two-notes 0)
          "two")
        (string.eq
          (compiler_diagnostic.compiler-diagnostic-note-list-get two-notes 1)
          "one")
        (=
          (compiler_diagnostic.compiler-diagnostic-label-list-count base-labels)
          0)
        (=
          (compiler_diagnostic.compiler-diagnostic-label-list-count one-labels)
          1)
        (=
          (compiler_diagnostic.compiler-diagnostic-label-list-count two-labels)
          2)
        (=
          (compiler_diagnostic.compiler-diagnostic-list-count empty-diagnostics)
          0)
        (=
          (compiler_diagnostic.compiler-diagnostic-list-count
            single-diagnostics)
          1)
        (= (compiler_diagnostic.compiler-diagnostic-list-count diagnostics) 3)
        (=
          (compiler_diagnostic.compiler-diagnostic-line
            (compiler_diagnostic.compiler-diagnostic-list-get diagnostics 0))
          1)
        (=
          (compiler_diagnostic.compiler-diagnostic-line
            (compiler_diagnostic.compiler-diagnostic-list-get diagnostics 1))
          2)
        (=
          (compiler_diagnostic.compiler-diagnostic-line
            (compiler_diagnostic.compiler-diagnostic-list-get diagnostics 2))
          3)))))

;; Pin every classifier row against a real message from the typechecker, using
;; the exact wording the compiler emits. The classifier keys on message text, so
;; without this a reword or a message added to the wrong family silently falls
;; back to `E0200` and the code stops distinguishing anything -- a regression no
;; other test would see. Also pins that an unrecognised kind still gets `E0200`,
;; because losing a code entirely would be worse than an imprecise one.
(define (compiler-diagnostic-typecheck-code-kind-is?
  [message : String]
  [expected : String]) : bool
  (string.eq
    (compiler_diagnostic.compiler-diagnostic-code-for-typecheck-message message)
    expected))

(define (compiler-diagnostic-typecheck-code-kinds-ok?) : bool
  (and
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: unbound name io/print-line"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-unbound-name))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: call arity mismatch: f expected 1 argument, got 2 arguments"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-arity-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: pattern arity mismatch"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-arity-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: annotation type mismatch: expected i64, found bool"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-type-mismatch))
    ;; The wording the exhaustiveness check actually emits. Pinning the other
    ;; spelling alone let that rule pass while never firing on a real compile,
    ;; which is how the first version of this shipped E0200 for a missing arm.
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: match missing arm for variant Err"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-non-exhaustive-match))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: non-exhaustive match"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-non-exhaustive-match))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: unknown struct field len"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-unknown-struct-field))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: region-tagged value cannot escape its arena"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck-region-escape))
    ;; an unclassified kind keeps the generic code
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: nominal type not found Foo"
      (compiler_diagnostic.compiler-diagnostic-code-typecheck))
    ;; the codes must actually differ from one another
    (not
      (string.eq
        (compiler_diagnostic.compiler-diagnostic-code-typecheck-arity-mismatch)
        (compiler_diagnostic.compiler-diagnostic-code-typecheck-type-mismatch)))))

(define (compiler-diagnostic-self-test) : i64
  (begin
    (unless (compiler-diagnostic-render-ok?) (return 1))
    (unless (compiler-diagnostic-flat-secondary-ok?) (return 1))
    (unless (compiler-diagnostic-source-error-ok?) (return 2))
    (unless (compiler-diagnostic-rewrite-ok?) (return 3))
    (unless (compiler-diagnostic-fallback-path-ok?) (return 3))
    (unless (compiler-diagnostic-source-render-ok?) (return 4))
    (unless (compiler-diagnostic-source-render-minimal-ok?) (return 4))
    (unless (compiler-diagnostic-note-render-ok?) (return 4))
    (cfg
      test
      (unless (compiler-diagnostic-source-render-secondary-ok?) (return 4))
      unit)
    (unless (compiler-diagnostic-end-span-ok?) (return 4))
    (unless (compiler-diagnostic-metadata-ok?) (return 4))
    (unless (compiler-diagnostic-code-or-empty-ok?) (return 4))
    (unless (compiler-diagnostic-dense-sequences-ok?) (return 4))
    (unless (compiler-diagnostic-typecheck-code-kinds-ok?) (return 5))
    42))