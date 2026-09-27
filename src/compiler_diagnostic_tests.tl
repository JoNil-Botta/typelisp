;; compiler_diagnostic_tests.tl - Diagnostic self-check fixtures split
;; from production compiler_diagnostic.tl.
;;
;; Holds the render/metadata/typecheck-code fixtures, the test-only
;; compiler-diagnostic-string-eq? helper (its only consumers are these
;; fixtures), and the compiler-diagnostic-self-test entry that drives them.
;; All production rendering and classification machinery stays in
;; compiler_diagnostic.tl.
(import compiler_diagnostic as cdiag)
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
    (cdiag.compiler-diagnostic-render
      (cdiag.compiler-diagnostic-simple "demo.tl" 3 7 "parse: malformed define"))
    "demo.tl:3:7: parse: malformed define"))

(define (compiler-diagnostic-flat-secondary-ok?) : bool
  (string.eq
    (cdiag.compiler-diagnostic-render
      (cdiag.compiler-diagnostic-with-secondary
        (cdiag.compiler-diagnostic-simple "template.tl" 2 14 "type mismatch")
        (cdiag.CompilerDiagnosticSpan "caller.tl" 7 9 7 15)
        (cdiag.CompilerDiagnosticSomeString
          "in expansion of macro `demo` invoked here")))
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
        (= (cdiag.compiler-diagnostic-list-count (clone diagnostics)) 3)
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
    (cdiag.compiler-diagnostic-code-for-typecheck-message message)
    expected))

(define (compiler-diagnostic-typecheck-code-kinds-ok?) : bool
  (and
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: unbound name io/print-line"
      (cdiag.compiler-diagnostic-code-typecheck-unbound-name))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: unknown type MissingType"
      (cdiag.compiler-diagnostic-code-typecheck-unbound-name))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: call arity mismatch: f expected 1 argument, got 2 arguments"
      (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: slice-view expected 3 arguments"
      (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: pattern arity mismatch"
      (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: annotation type mismatch: expected i64, found bool"
      (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
    ;; The wording the exhaustiveness check actually emits. Pinning the other
    ;; spelling alone let that rule pass while never firing on a real compile,
    ;; which is how the first version of this shipped E0200 for a missing arm.
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: match missing arm for variant Err"
      (cdiag.compiler-diagnostic-code-typecheck-non-exhaustive-match))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: non-exhaustive match"
      (cdiag.compiler-diagnostic-code-typecheck-non-exhaustive-match))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: unknown struct field len"
      (cdiag.compiler-diagnostic-code-typecheck-unknown-struct-field))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: region-tagged value cannot escape its arena"
      (cdiag.compiler-diagnostic-code-typecheck-region-escape))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cannot pass region-tagged value to function parameter; region value would escape; borrow slots from a vector place"
      (cdiag.compiler-diagnostic-code-typecheck-region-escape))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: borrow requires a local, parameter, or aggregate place"
      (cdiag.compiler-diagnostic-code-typecheck-borrow-violation))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cannot mutably borrow borrowed place `items[0]`"
      (cdiag.compiler-diagnostic-code-typecheck-borrow-violation))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cannot move borrowed place `handle`"
      (cdiag.compiler-diagnostic-code-typecheck-borrow-violation))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: use of moved value `ticket`"
      (cdiag.compiler-diagnostic-code-typecheck-move-violation))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cannot move out of global `items`; borrow the global instead"
      (cdiag.compiler-diagnostic-code-typecheck-move-violation))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: ptr-read requires unsafe context"
      (cdiag.compiler-diagnostic-code-typecheck-unsafe-context))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: danger is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe"
      (cdiag.compiler-diagnostic-code-typecheck-unsafe-callable-effect))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cannot assign to global `counter` owned by module `dep` from module `main`; only its defining module may write it, so call a function that `dep` defines instead"
      (cdiag.compiler-diagnostic-code-typecheck-foreign-global-write))
    ;; The `mutably borrow` wording must not fall into the borrow rule.
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cannot mutably borrow global `counter` owned by module `dep` from module `main`; only its defining module may write it, so call a function that `dep` defines instead"
      (cdiag.compiler-diagnostic-code-typecheck-foreign-global-write))
    ;; A lifetime cause appended to a type-mismatch prefix must win over E0206.
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: call argument type mismatch; source lifetime `short` does not outlive required lifetime `long`"
      (cdiag.compiler-diagnostic-code-typecheck-lifetime-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: cleanup owner `handle` moved before with scope exit"
      (cdiag.compiler-diagnostic-code-typecheck-resource-ownership))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: arena.destroy-safe! requires a direct arena owner"
      (cdiag.compiler-diagnostic-code-typecheck-arena-ownership))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: elided reference return is ambiguous; write an explicit lifetime"
      (cdiag.compiler-diagnostic-code-typecheck-lifetime-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: integer operator expects matching integer operands"
      (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: arithmetic operator requires numeric types"
      (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: integer literal 256 does not fit expected type u8"
      (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: unreachable match arm after wildcard `_`"
      (cdiag.compiler-diagnostic-code-typecheck-pattern))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: SPMD masked if does not support nested foreach"
      (cdiag.compiler-diagnostic-code-typecheck-spmd))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: expression is not a storage place"
      (cdiag.compiler-diagnostic-code-typecheck-place))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: break requires enclosing scalar while"
      (cdiag.compiler-diagnostic-code-typecheck-control-flow))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: raw pointers cannot cross thread boundaries in safe code"
      (cdiag.compiler-diagnostic-code-typecheck-thread-safety))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: make-array length must be a non-negative compile-time integer"
      (cdiag.compiler-diagnostic-code-typecheck-comptime-constraint))
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: if branches must match"
      (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
    ;; an unclassified kind keeps the generic code
    (compiler-diagnostic-typecheck-code-kind-is?
      "typecheck: internal unclassified fixture"
      (cdiag.compiler-diagnostic-code-typecheck))
    ;; the codes must actually differ from one another
    (not
      (string.eq
        (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch)
        (cdiag.compiler-diagnostic-code-typecheck-type-mismatch)))))

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
            (cdiag.compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Semantic
              (& semantic))
            (cdiag.compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Lowering
              (& lowering))
            (cdiag.compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Optimization
              (& optimization))
            (cdiag.compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.RegisterAllocation
              (& regalloc))
            (cdiag.compiler-advisory-sink-push!
              sink-a
              cdiag.CompilerAdvisoryPhase.Backend
              (& backend))
            (cdiag.compiler-advisory-sink-push!
              sink-b
              cdiag.CompilerAdvisoryPhase.Semantic
              (& other))
            (cdiag.compiler-advisory-sink-push!
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
    (unless (compiler-diagnostic-code-registry-ok?) (return 4))
    (unless (compiler-diagnostic-advisory-sink-ok?) (return 4))
    (unless (compiler-diagnostic-typecheck-code-kinds-ok?) (return 5))
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