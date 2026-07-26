;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.
(import "../compiler_check_core.tl")
(import "../compiler_semantic_index.tl")
(import compiler_builtin_ids as cbi)

(define (compiler-check-fix-test-position-index
  [source : String]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [idx : i64 0]
    [source-len : i64 (string.string-length source)]
    [line : i64 1]
    [col : i64 1]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< idx source-len))
        (if (and (= line target-line) (= col target-col))
          (set! found idx)
          (begin
            (if (= (string.string-ref source idx) '\n')
              (begin
                (set! line (+ line 1))
                (set! col 1))
              (set! col (+ col 1)))
            (set! idx (+ idx 1)))))
      (if (and (< found 0) (= line target-line) (= col target-col))
        source-len
        found))))

(define (compiler-check-fix-test-apply
  [source : String]
  [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticMaybeString
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-text-edit-span edit)]
    [start : i64
      (compiler-check-fix-test-position-index
        source
        (compiler-diagnostic-span-start-line span)
        (compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-check-fix-test-position-index
        source
        (compiler-diagnostic-span-end-line span)
        (compiler-diagnostic-span-end-col span))]
    [source-len : i64 (string.string-length source)]
    (if (or (< start 0) (< end start))
      CompilerDiagnosticNoString
      (CompilerDiagnosticSomeString
        (string.concat3
          (string.substring source 0 start)
          (compiler-diagnostic-text-edit-replacement edit)
          (string.substring source end (- source-len end)))))))

(define (compiler-check-near-miss-fix-source) : String
  "(define (render-value [value : i64]) : i64
  value)

(define (main) : i64
  (render-vaule 42))")

(define (compiler-check-near-miss-fixed-source) : String
  "(define (render-value [value : i64]) : i64
  value)

(define (main) : i64
  (render-value 42))")

(define (compiler-check-near-miss-fix-ok?) : bool
  (let
    [path : String "tests/near_miss_fix.tl"]
    [source : String (compiler-check-near-miss-fix-source)]
    (match (compiler-check-source path source)
      [(ResultCompilerCheck.Ok _) false]
      [(ResultCompilerCheck.Err diag-box)
        (let
          [diag : CompilerDiagnostic (box-get diag-box)]
          [fixes : CompilerDiagnosticFixSeq (compiler-diagnostic-fixes diag)]
          (and
            (= (struct-get fixes len) 1)
            (let
              [fix : CompilerDiagnosticFix
                (array-ref (struct-get fixes slots) 0)]
              [edits : CompilerDiagnosticTextEditSeq
                (compiler-diagnostic-fix-edits fix)]
              (and
                (string.eq
                  (compiler-diagnostic-fix-title fix)
                  "Replace misspelled name")
                (match (compiler-diagnostic-fix-applicability fix)
                  [CompilerDiagnosticMachineApplicable true]
                  [_ false])
                (= (struct-get edits len) 1)
                (let
                  [edit : CompilerDiagnosticTextEdit
                    (array-ref (struct-get edits slots) 0)]
                  [span : CompilerDiagnosticSpan
                    (compiler-diagnostic-text-edit-span edit)]
                  (and
                    (string.eq (compiler-diagnostic-span-path span) path)
                    (= (compiler-diagnostic-span-start-line span) 5)
                    (= (compiler-diagnostic-span-start-col span) 4)
                    (= (compiler-diagnostic-span-end-line span) 5)
                    (= (compiler-diagnostic-span-end-col span) 16)
                    (string.eq
                      (compiler-diagnostic-text-edit-replacement edit)
                      "render-value")
                    (match (compiler-check-fix-test-apply source edit)
                      [(CompilerDiagnosticSomeString updated)
                        (and
                          (string.eq
                            updated
                            (compiler-check-near-miss-fixed-source))
                          (compiler-check-source-ok? path updated))]
                      [CompilerDiagnosticNoString false])))))))])))

(define (compiler-check-import-help-not-machine-fix-ok?) : bool
  (match (compiler-check-source
    "tests/import_help_only.tl"
    "(define (main) : i64 (begin (print 1) 0))")
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (= (struct-get (compiler-diagnostic-fixes (box-get diag)) len) 0)]))

(define (compiler-check-duplicate-type-location-ok?) : bool
  (let
    [path : String "tests/duplicate_type_location.tl"]
    [source : String
      "(defstruct Point (x i64))
(defstruct Point (y i64))
(define (main) : i64 0)"]
    (match (compiler-check-source path source)
      [(ResultCompilerCheck.Ok _) false]
      [(ResultCompilerCheck.Err diag-box)
        (let
          [diag : CompilerDiagnostic (box-get diag-box)]
          (and
            (string.eq
              (compiler-diagnostic-message diag)
              "symbols: duplicate type declaration Point")
            (string.eq (compiler-diagnostic-path diag) path)
            (= (compiler-diagnostic-line diag) 2)
            (= (compiler-diagnostic-col diag) 1)))])))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (cond
      [(and
          (= (compiler-check-self-test) 42)
          (compiler-check-near-miss-fix-ok?)
          (compiler-check-import-help-not-machine-fix-ok?)
          (compiler-check-duplicate-type-location-ok?)
          (compiler-check-semantic-index-ok?))
        42]
      [else 1])))