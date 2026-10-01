;; compiler_semantic_index_tests.tl - White-box tests for the semantic source index:
;; record, visibility, macro, partial-check and canonical-symbol checks.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.string)
(import stdlib.vector)
(import stdlib.option)
(import sym_i64_env)
(import (vector.vector String) as svec)
(import (option.option i64) as option_i64)
(import compiler_check_core as check_core)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as cdiag)
(import compiler_typecheck_core as tc)
(import compiler_ast_types as ast)
(import compiler_semantic_index as sem)

;; Layout queries need the struct names unqualified. Lint does not count a use
;; inside `(type ...)`.
;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticBinding)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticModuleEvent)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticModuleInfo)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticRecord)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticScopeEvent)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticSourcePathInfo)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticTopCandidateRef)

;; lint-allow: unused-import
(import compiler_semantic_index.CompilerSemanticVisibleBinding)

;; The frontend smoke suite keeps semantic stdout/stderr empty, so its opt-in
;; timing evidence goes directly to the inherited CI timing artifact. These
;; helpers are also used by the suite parent for child-process rows.
(define (compiler-semantic-index-smoke-timing-enabled?) : bool
  (and
    (string.eq (env.var-value "TYPELISP_CI_TIMING") "1")
    (> (string.string-length (env.var-value "TYPELISP_CI_TIMING_FILE")) 0)))

(define (compiler-semantic-index-smoke-timing-start) : i64
  (if (compiler-semantic-index-smoke-timing-enabled?)
    (profile.now-ms)
    -1))

(define (compiler-semantic-index-smoke-timing-env-or
  [name : String]
  [fallback : String]) : String
  (let
    [value : String (env.var-value name)]
    (if (> (string.string-length value) 0)
      value
      fallback)))

(define (compiler-semantic-index-smoke-timing-record
  [phase : String]
  [started-ms : i64]
  [status : i64]) : bool
  (if (< started-ms 0)
    true
    (let
      [path : String (env.var-value "TYPELISP_CI_TIMING_FILE")]
      [gate : String
        (compiler-semantic-index-smoke-timing-env-or
          "TYPELISP_CI_TIMING_GATE"
          "ungated")]
      [host : String
        (compiler-semantic-index-smoke-timing-env-or
          "TYPELISP_CI_TIMING_HOST"
          "unknown")]
      [elapsed-ms : i64 (- (profile.now-ms) started-ms)]
      [row : String
        (str_cat.str-cat
          gate
          "\tcompiler_frontend_smoke_suite\t"
          phase
          "\t"
          (string.int->string elapsed-ms)
          "\t"
          (string.int->string status)
          "\t"
          host
          "\n")]
      (match (io.try-append-file (& path) (byte_buf.str-as-bytes (& row)))
        [(io.OkIoUnit) true]
        [(io.ErrIoUnit _) false]))))

(define (compiler-semantic-binding-namespace-all-mask) : i64
  7)

(define (compiler-semantic-binding-namespace-tag
  [namespace : sem.CompilerSemanticBindingNamespace]) : i64
  (match namespace
    [(sem.CompilerSemanticBindingNamespace.Value) 1]
    [(sem.CompilerSemanticBindingNamespace.Type) 2]
    [(sem.CompilerSemanticBindingNamespace.Macro) 4]))

(define (compiler-semantic-source-index-live-owner-count) : i64
  sem.compiler-semantic-source-index-live-owners)

(define (compiler-semantic-source-index-canonical-symbol-count
  [index : (& index sem.CompilerSemanticSourceIndex)]) : i64
  index.canonical-symbol-len)

(define (compiler-semantic-source-index-records-canonical-eq?
  [left-index : (& left-index sem.CompilerSemanticSourceIndex)]
  [left-record : (& left-record sem.CompilerSemanticRecord)]
  [right-index : (& right-index sem.CompilerSemanticSourceIndex)]
  [right-record : (& right-record sem.CompilerSemanticRecord)]) : bool
  (and
    (>= left-record.canonical-index 0)
    (>= right-record.canonical-index 0)
    (string.eq
      (sem.compiler-semantic-source-index-record-canonical-key
        left-index
        left-record)
      (sem.compiler-semantic-source-index-record-canonical-key
        right-index
        right-record))))

(define (compiler-semantic-source-index-canonical-key-byte-count
  [index : (& index sem.CompilerSemanticSourceIndex)]) : i64
  (let
    [canonical-index : i64 0]
    [bytes : i64 0]
    (begin
      (while (< canonical-index index.canonical-symbol-len)
        (begin
          (set!
            bytes
            (+
              bytes
              (string.string-length
                (array-ref index.canonical-symbols canonical-index))))
          (set! canonical-index (+ canonical-index 1))))
      bytes)))

(define (compiler-semantic-source-index-scope-region-count
  [index : (& index sem.CompilerSemanticSourceIndex)]) : i64
  index.scope-region-count)

(define (compiler-semantic-source-index-top-candidate-count
  [index : (& index sem.CompilerSemanticSourceIndex)]) : i64
  index.top-candidate-len)

(define (compiler-semantic-source-index-path-count
  [index : (& index sem.CompilerSemanticSourceIndex)]) : i64
  index.path-len)

(define (compiler-semantic-source-index-retained-byte-estimate
  [index : (& index sem.CompilerSemanticSourceIndex)]) : i64
  (let
    [bytes : i64
      (+
        (* index.len (comptime (size-of (type CompilerSemanticRecord))))
        (+
          (* index.canonical-symbol-len (comptime (size-of (type String))))
          (compiler-semantic-source-index-canonical-key-byte-count index)))]
    [path-index : i64 0]
    [binding-index : i64 0]
    [candidate-index : i64 0]
    (begin
      (set!
        bytes
        (+
          bytes
          (+
            (*
              index.path-len
              (comptime (size-of (type CompilerSemanticSourcePathInfo))))
            (+
              (*
                index.module-len
                (comptime (size-of (type CompilerSemanticModuleInfo))))
              (+
                (*
                  index.module-event-len
                  (comptime (size-of (type CompilerSemanticModuleEvent))))
                (+
                  (*
                    index.scope-event-len
                    (comptime (size-of (type CompilerSemanticScopeEvent))))
                  (*
                    index.binding-len
                    (comptime (size-of (type CompilerSemanticBinding))))))))))
      (set!
        bytes
        (+
          bytes
          (+
            (*
              index.top-candidate-len
              (comptime (size-of (type CompilerSemanticTopCandidateRef))))
            (+
              (* index.top-candidate-len (comptime (size-of (type String))))
              (*
                index.top-candidate-len
                (comptime (size-of (type CompilerSemanticVisibleBinding))))))))
      (while (< path-index index.path-len)
        (begin
          (set!
            bytes
            (+
              bytes
              (string.string-length
                (owned_view.compiler-owned-array-element-shared-view
                  index.paths
                  path-index).path)))
          (set! path-index (+ path-index 1))))
      (while (< binding-index index.binding-len)
        (let
          [binding : sem.CompilerSemanticBinding
            (owned_view.compiler-owned-array-element-shared-view
              index.bindings
              binding-index)]
          (begin
            (set!
              bytes
              (+
                bytes
                (+
                  (string.string-length binding.display-name)
                  (string.string-length binding.resolved-type))))
            (set! binding-index (+ binding-index 1)))))
      (while (< candidate-index index.top-candidate-len)
        (begin
          (set!
            bytes
            (+
              bytes
              (string.string-length
                (owned_view.compiler-owned-array-element-shared-view
                  index.top-labels
                  candidate-index))))
          (set! candidate-index (+ candidate-index 1))))
      bytes)))

(define (compiler-semantic-source-index-visible-binding-count
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [query : sem.CompilerSemanticVisibleBindingQuery]
  [namespace-mask : i64]) : i64
  (let
    [cursor : sem.CompilerSemanticVisibleBindingCursor
      (sem.compiler-semantic-visible-binding-cursor index query namespace-mask)]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (match (sem.compiler-semantic-visible-binding-cursor-step index cursor)
          [(sem.CompilerSemanticVisibleBindingStep.Some _ next)
            (begin
              (set! cursor next)
              (set! count (+ count 1)))]
          [(sem.CompilerSemanticVisibleBindingStep.Done) (set! done true)]))
      count)))

;; Return current-buffer records whenever recovery establishes safe identities.
;; Fatal prelude/lexing failures remain distinct from an owned partial index.
(define (compiler-check-source-index-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]) : sem.ResultCompilerCheckWithSemanticIndex
  (sem.compiler-check-source-index-with-roots-and-cfg
    path
    source
    stdlib-roots
    (check_core.compiler-check-language-cfgs)))

(define (compiler-semantic-source-index-find-definition
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : (& path str)]
  [name : String]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index index.len))
        (let
          [record : sem.CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          (begin
            (if (and
              (match record.role
                [(sem.CompilerSemanticRecordRole.Definition) true]
                [_ false])
              record.editable
              (string.eq record.display-name name)
              (string.eq record.span.path path))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-check-semantic-index-record-ok?
  [source : (& source str)]
  [record : (& record sem.CompilerSemanticRecord)]
  [name : String]
  [kind : sem.CompilerSemanticSymbolKind]) : bool
  (let
    [span : sem.CompilerSemanticSpan record.span]
    [start : i64 span.start-byte]
    [end : i64 span.end-byte]
    (and
      record.editable
      (match record.provenance
        [(sem.CompilerSemanticProvenance.EditableSource) true]
        [_ false])
      (match kind
        [(sem.CompilerSemanticSymbolKind.Value)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.Value) true]
            [_ false])]
        [(sem.CompilerSemanticSymbolKind.Function)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.Function) true]
            [_ false])]
        [(sem.CompilerSemanticSymbolKind.Struct)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.Struct) true]
            [_ false])]
        [(sem.CompilerSemanticSymbolKind.Enum)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.Enum) true]
            [_ false])]
        [(sem.CompilerSemanticSymbolKind.Module)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.Module) true]
            [_ false])]
        [(sem.CompilerSemanticSymbolKind.Field)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.Field) true]
            [_ false])]
        [(sem.CompilerSemanticSymbolKind.EnumMember)
          (match record.kind
            [(sem.CompilerSemanticSymbolKind.EnumMember) true]
            [_ false])]
        [_ false])
      (>= start 0)
      (= (- end start) (string.string-length name))
      (string.eq (string.substring source start (- end start)) name)
      (not (string.eq record.resolved-type "")))))

(define (compiler-semantic-source-index-find-record
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : (& path str)]
  [name : String]
  [role : sem.CompilerSemanticRecordRole]
  [local-ordinal : i64]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index index.len))
        (let
          [record : sem.CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          [symbol : sem.CompilerSemanticSymbolId record.symbol]
          (begin
            (if (and
              (string.eq record.display-name name)
              (match role
                [(sem.CompilerSemanticRecordRole.Definition)
                  (match record.role
                    [(sem.CompilerSemanticRecordRole.Definition) true]
                    [_ false])]
                [(sem.CompilerSemanticRecordRole.Use)
                  (match record.role
                    [(sem.CompilerSemanticRecordRole.Use) true]
                    [_ false])])
              (= symbol.local-ordinal local-ordinal)
              (or (string.eq path "") (string.eq record.span.path path)))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-semantic-source-index-find-name-occurrence
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : (& path str)]
  [name : String]
  [role : sem.CompilerSemanticRecordRole]
  [occurrence : i64]) : i64
  (let
    [record-index : i64 0]
    [seen : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index index.len))
        (let
          [record : sem.CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          (begin
            (if (and
              (string.eq record.display-name name)
              (match role
                [(sem.CompilerSemanticRecordRole.Definition)
                  (match record.role
                    [(sem.CompilerSemanticRecordRole.Definition) true]
                    [_ false])]
                [(sem.CompilerSemanticRecordRole.Use)
                  (match record.role
                    [(sem.CompilerSemanticRecordRole.Use) true]
                    [_ false])])
              (or (string.eq path "") (string.eq record.span.path path)))
              (if (= seen occurrence)
                (set! found record-index)
                (set! seen (+ seen 1)))
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-semantic-source-index-name-symbol-match?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : (& path str)]
  [name : String]
  [definition-occurrence : i64]
  [use-occurrence : i64]) : bool
  (let
    [definition-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        (owned_view.compiler-owned-shared-view name)
        sem.CompilerSemanticRecordRole.Definition
        definition-occurrence)]
    [use-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        name
        sem.CompilerSemanticRecordRole.Use
        use-occurrence)]
    (and
      (>= definition-index 0)
      (>= use-index 0)
      (sem.compiler-semantic-symbol-id-eq?
        (__tl-project-field
          (sem.compiler-semantic-source-index-get index definition-index)
          symbol)
        (__tl-project-field
          (sem.compiler-semantic-source-index-get index use-index)
          symbol)))))

(define (compiler-semantic-record-span-text-eq?
  [source : (& source str)]
  [record : (& record sem.CompilerSemanticRecord)]
  [expected : String]) : bool
  (let
    [span : sem.CompilerSemanticSpan record.span]
    [start : i64 span.start-byte]
    [end : i64 span.end-byte]
    (and
      (>= start 0)
      (>= end start)
      (string.eq (string.substring source start (- end start)) expected))))

(define (compiler-semantic-source-index-find-macro-use
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [name : String]
  [editable : bool]
  [occurrence : i64]) : i64
  (let
    [record-index : i64 0]
    [seen : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index index.len))
        (let
          [record : sem.CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          (begin
            (if (and
              (match record.role
                [(sem.CompilerSemanticRecordRole.Use) true]
                [_ false])
              (match record.kind
                [(sem.CompilerSemanticSymbolKind.Macro) true]
                [_ false])
              (= record.editable editable)
              (string.eq record.display-name name))
              (if (= seen occurrence)
                (set! found record-index)
                (set! seen (+ seen 1)))
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-semantic-source-index-count-macro-uses
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [name : String]
  [editable : bool]) : i64
  (let
    [record-index : i64 0]
    [count : i64 0]
    (begin
      (while (< record-index index.len)
        (let
          [record : sem.CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          (begin
            (if (and
              (match record.role
                [(sem.CompilerSemanticRecordRole.Use) true]
                [_ false])
              (match record.kind
                [(sem.CompilerSemanticSymbolKind.Macro) true]
                [_ false])
              (= record.editable editable)
              (string.eq record.display-name name))
              (set! count (+ count 1))
              unit)
            (set! record-index (+ record-index 1)))))
      count)))

(define (compiler-semantic-record-vec-growth-ok?) : bool
  (let
    [records : sem.CompilerSemanticRecordVec
      (sem.compiler-semantic-record-vec-new 1)]
    (begin
      (sem.compiler-semantic-record-vec-push!
        (&mut records)
        (sem.compiler-semantic-record-fallback))
      (sem.compiler-semantic-record-vec-push!
        (&mut records)
        (sem.compiler-semantic-record-fallback))
      (sem.compiler-semantic-record-vec-push!
        (&mut records)
        (sem.compiler-semantic-record-fallback))
      (and
        (= records.len 3)
        (>= (array-length records.items) 3)
        (array-ref records.live 0)
        (array-ref records.live 1)
        (array-ref records.live 2)))))

(define (compiler-semantic-test-source-find-from
  [source : (& source str)]
  [needle : String]
  [start : i64]) : i64
  (let
    [index : i64
      (if (< start 0)
        0
        start)]
    [limit : i64
      (- (string.string-length source) (string.string-length needle))]
    (begin
      (while (<= index limit)
        (if (string.is-string-prefix-at source (& needle) index)
          (return index)
          (set! index (+ index 1))))
      -1)))

(define (compiler-semantic-test-visible-label-count
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [query : sem.CompilerSemanticVisibleBindingQuery]
  [namespace-mask : i64]
  [label : String]) : i64
  (let
    [cursor : sem.CompilerSemanticVisibleBindingCursor
      (sem.compiler-semantic-visible-binding-cursor index query namespace-mask)]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (match (sem.compiler-semantic-visible-binding-cursor-step index cursor)
          [(sem.CompilerSemanticVisibleBindingStep.Some binding next)
            (begin
              (if (string.eq binding.display-name label)
                (set! count (+ count 1))
                unit)
              (set! cursor next))]
          [(sem.CompilerSemanticVisibleBindingStep.Done) (set! done true)]))
      count)))

(define (compiler-semantic-test-visible-symbol?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [query : sem.CompilerSemanticVisibleBindingQuery]
  [namespace-mask : i64]
  [label : String]
  [symbol : sem.CompilerSemanticSymbolId]) : bool
  (let
    [cursor : sem.CompilerSemanticVisibleBindingCursor
      (sem.compiler-semantic-visible-binding-cursor index query namespace-mask)]
    [done : bool false]
    (begin
      (while (not done)
        (match (sem.compiler-semantic-visible-binding-cursor-step index cursor)
          [(sem.CompilerSemanticVisibleBindingStep.Some binding next)
            (if (and
              (string.eq binding.display-name label)
              (sem.compiler-semantic-symbol-id-eq? binding.symbol symbol))
              (return true)
              (set! cursor next))]
          [(sem.CompilerSemanticVisibleBindingStep.Done) (set! done true)]))
      false)))

(define (compiler-semantic-test-visible-order-eq?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [query : sem.CompilerSemanticVisibleBindingQuery]
  [namespace-mask : i64]) : bool
  (let
    [left : sem.CompilerSemanticVisibleBindingCursor
      (sem.compiler-semantic-visible-binding-cursor index query namespace-mask)]
    [right : sem.CompilerSemanticVisibleBindingCursor
      (sem.compiler-semantic-visible-binding-cursor index query namespace-mask)]
    [done : bool false]
    (begin
      (while (not done)
        (match (sem.compiler-semantic-visible-binding-cursor-step index left)
          [(sem.CompilerSemanticVisibleBindingStep.Some left-binding left-next)
            (match (sem.compiler-semantic-visible-binding-cursor-step
              index
              right)
              [(sem.CompilerSemanticVisibleBindingStep.Some
                  right-binding
                  right-next)
                (if (and
                  (string.eq
                    left-binding.display-name
                    right-binding.display-name)
                  (=
                    (compiler-semantic-binding-namespace-tag
                      left-binding.namespace)
                    (compiler-semantic-binding-namespace-tag
                      right-binding.namespace))
                  (sem.compiler-semantic-symbol-id-eq?
                    left-binding.symbol
                    right-binding.symbol))
                  (begin
                    (set! left left-next)
                    (set! right right-next))
                  (return false))]
              [(sem.CompilerSemanticVisibleBindingStep.Done) (return false)])]
          [(sem.CompilerSemanticVisibleBindingStep.Done)
            (match (sem.compiler-semantic-visible-binding-cursor-step
              index
              right)
              [(sem.CompilerSemanticVisibleBindingStep.Some _ _) (return false)]
              [(sem.CompilerSemanticVisibleBindingStep.Done) (set! done true)])]))
      true)))

(define (compiler-semantic-test-query-at
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : String]
  [offset : i64]) : sem.CompilerSemanticVisibleBindingQuery
  (match (sem.compiler-semantic-source-index-query index path offset)
    [(sem.CompilerSemanticMaybeVisibleBindingQuery.Some query) query]
    [(sem.CompilerSemanticMaybeVisibleBindingQuery.None)
      (sem.CompilerSemanticVisibleBindingQuery -1 -1 -1)]))

(define (compiler-check-semantic-index-base-visibility-ok?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : String]
  [source : (& source str)]) : bool
  (let
    [init-offset : i64
      (compiler-semantic-test-source-find-from source "dep.imported-value" 0)]
    [body-marker : i64
      (compiler-semantic-test-source-find-from source "\n    answer))" 0)]
    [after-offset : i64
      (compiler-semantic-test-source-find-from source "(define (call-use" 0)]
    [top-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        "answer"
        sem.CompilerSemanticRecordRole.Definition
        0)]
    [parameter-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        "answer"
        sem.CompilerSemanticRecordRole.Definition
        1)]
    [local-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        "answer"
        sem.CompilerSemanticRecordRole.Definition
        2)]
    [qualified-import-index : i64
      (sem.compiler-semantic-source-index-find-editable-record-at
        index
        (& path)
        init-offset)]
    (if (or
      (< init-offset 0)
      (< body-marker 0)
      (< after-offset 0)
      (< top-index 0)
      (< parameter-index 0)
      (< local-index 0)
      (< qualified-import-index 0))
      false
      (let
        [init-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            init-offset)]
        [bound-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ body-marker 5))]
        [boundary-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ init-offset (string.string-length "dep.imported-value")))]
        [after-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            after-offset)]
        [top-record : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index top-index)]
        [parameter-record : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index parameter-index)]
        [local-record : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index local-index)]
        [qualified-import-record : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index qualified-import-index)]
        [repeated-count : i64
          (compiler-semantic-source-index-visible-binding-count
            index
            bound-query
            (compiler-semantic-binding-namespace-all-mask))]
        [repeat : i64 0]
        [repeated-ok : bool true]
        (begin
          (while (< repeat 100)
            (begin
              (if (=
                (compiler-semantic-source-index-visible-binding-count
                  index
                  bound-query
                  (compiler-semantic-binding-namespace-all-mask))
                repeated-count)
                unit
                (set! repeated-ok false))
              (set! repeat (+ repeat 1))))
          (and
            (>= init-query.path-index 0)
            (>= bound-query.path-index 0)
            (>= after-query.path-index 0)
            (string.eq qualified-import-record.display-name "imported-value")
            (compiler-semantic-record-span-text-eq?
              source
              qualified-import-record
              "dep.imported-value")
            (compiler-semantic-test-visible-symbol?
              index
              init-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "answer"
              parameter-record.symbol)
            (compiler-semantic-test-visible-symbol?
              index
              bound-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "answer"
              local-record.symbol)
            (compiler-semantic-test-visible-symbol?
              index
              boundary-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "answer"
              local-record.symbol)
            (compiler-semantic-test-visible-symbol?
              index
              after-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "answer"
              top-record.symbol)
            (=
              (compiler-semantic-test-visible-label-count
                index
                bound-query
                (sem.compiler-semantic-binding-namespace-value-mask)
                "answer")
              1)
            (=
              (compiler-semantic-test-visible-label-count
                index
                bound-query
                (sem.compiler-semantic-binding-namespace-value-mask)
                "imported-value")
              0)
            (=
              (compiler-semantic-test-visible-label-count
                index
                bound-query
                (sem.compiler-semantic-binding-namespace-value-mask)
                "Pair")
              1)
            (=
              (compiler-semantic-test-visible-label-count
                index
                bound-query
                (sem.compiler-semantic-binding-namespace-type-mask)
                "Pair")
              1)
            (=
              (compiler-semantic-test-visible-label-count
                index
                bound-query
                (sem.compiler-semantic-binding-namespace-macro-mask)
                "wrap")
              1)
            (=
              (compiler-semantic-test-visible-label-count
                index
                bound-query
                (sem.compiler-semantic-binding-namespace-macro-mask)
                "when")
              1)
            (=
              (compiler-semantic-test-visible-label-count
                index
                init-query
                (sem.compiler-semantic-binding-namespace-value-mask)
                "match-use")
              1)
            (compiler-semantic-test-visible-order-eq?
              index
              bound-query
              (compiler-semantic-binding-namespace-all-mask))
            repeated-ok
            (> repeated-count 0)
            (> (compiler-semantic-source-index-path-count index) 0)
            (> (compiler-semantic-source-index-scope-region-count index) 0)
            (> (compiler-semantic-source-index-top-candidate-count index) 0)
            (> (compiler-semantic-source-index-retained-byte-estimate index) 0)
            (=
              (compiler-semantic-source-index-visible-binding-count
                index
                (sem.CompilerSemanticVisibleBindingQuery -1 -1 999999)
                (compiler-semantic-binding-namespace-all-mask))
              0)
            (match (sem.compiler-semantic-source-index-query
              index
              path
              (+ (string.string-length source) 1))
              [(sem.CompilerSemanticMaybeVisibleBindingQuery.None) true]
              [_ false])))))))

(define (compiler-check-semantic-index-base-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_entry.tl"]
    [source : String
      "(module semantic.demo)
(import semantic.index.import_dep as dep)
(defstruct Pair (left i64))
(defmacro (emit-generated) : Decls
  `(define generated-value : i64 7))
(emit-generated)
(define prior-text : String \"(answer)\")
(define prior-char : char '(')
; ordinary λ source text mentions an unmatched (answer
;: Top answer documentation.
;# Additional answer detail.
  (define answer : i64 42)
(defmacro (wrap [value : Expr]) : Expr
  `(__tl-project-field-name ,value \"left\"))
(define wrapped-answer : i64 (wrap (Pair 8)))
(define (use
  ; answer appears in a comment before the parameter binder.
  [answer : i64]) : i64
  (let
    ; answer appears in a comment before the local binder.
    [answer : i64 (+ answer dep.imported-value)]
    answer))
(define (call-use) : i64 (use answer))
(define (match-use [value : i64]) : i64
  (match value
    [bound bound]))
(defmacro (nested-template [hidden : Expr]) : Expr
  `(quasiquote (begin (unquote hidden))))"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [answer-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              path
              "answer")]
          [use-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              path
              "use")]
          [pair-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              path
              "Pair")]
          [param-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [param-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [local-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [local-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              sem.CompilerSemanticRecordRole.Use
              1)]
          [macro-param-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "value"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [macro-param-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "value"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [import-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              ""
              "imported-value"
              sem.CompilerSemanticRecordRole.Definition
              -1)]
          [import-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "imported-value"
              sem.CompilerSemanticRecordRole.Use
              -1)]
          [answer-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              sem.CompilerSemanticRecordRole.Use
              -1)]
          [function-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "use"
              sem.CompilerSemanticRecordRole.Use
              -1)]
          [generated-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              ""
              "generated-value"
              sem.CompilerSemanticRecordRole.Definition
              -1)]
          [pattern-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "bound"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [pattern-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "bound"
              sem.CompilerSemanticRecordRole.Use
              1)]
          [nested-param-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "hidden"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [nested-param-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "hidden"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [first-len : i64 (sem.compiler-semantic-source-index-len (& first))]
          (if (or
            (< answer-index 0)
            (< use-index 0)
            (< pair-index 0)
            (< param-definition-index 0)
            (< param-use-index 0)
            (< local-definition-index 0)
            (< local-use-index 0)
            (< macro-param-definition-index 0)
            (< macro-param-use-index 0)
            (< import-definition-index 0)
            (< import-use-index 0)
            (< answer-use-index 0)
            (< function-use-index 0)
            (< generated-index 0)
            (< pattern-definition-index 0)
            (< pattern-use-index 0)
            (< nested-param-definition-index 0)
            (>= nested-param-use-index 0))
            (begin
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)
            (let
              [answer : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& first) answer-index)]
              [use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& first) use-index)]
              [pair : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& first) pair-index)]
              [param-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  param-definition-index)]
              [param-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  param-use-index)]
              [local-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  local-definition-index)]
              [local-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  local-use-index)]
              [macro-param-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  macro-param-definition-index)]
              [macro-param-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  macro-param-use-index)]
              [import-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  import-definition-index)]
              [import-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  import-use-index)]
              [answer-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  answer-use-index)]
              [function-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  function-use-index)]
              [generated : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  generated-index)]
              [pattern-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  pattern-definition-index)]
              [pattern-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  pattern-use-index)]
              [answer-symbol : sem.CompilerSemanticSymbolId answer.symbol]
              [answer-start : i64 answer.span.start-byte]
              (match (compiler-check-source-index-with-roots
                (owned_view.compiler-owned-shared-view path)
                (owned_view.compiler-owned-shared-view source)
                (svec.new))
                [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ second)
                  (let
                    [second-answer-index : i64
                      (compiler-semantic-source-index-find-definition
                        (& second)
                        path
                        "answer")]
                    [second-answer : sem.CompilerSemanticRecord
                      (sem.compiler-semantic-source-index-get
                        (& second)
                        second-answer-index)]
                    [second-param-index : i64
                      (compiler-semantic-source-index-find-record
                        (& second)
                        path
                        "answer"
                        sem.CompilerSemanticRecordRole.Definition
                        0)]
                    [second-param : sem.CompilerSemanticRecord
                      (sem.compiler-semantic-source-index-get
                        (& second)
                        second-param-index)]
                    [second-generated-index : i64
                      (compiler-semantic-source-index-find-record
                        (& second)
                        ""
                        "generated-value"
                        sem.CompilerSemanticRecordRole.Definition
                        -1)]
                    [second-generated : sem.CompilerSemanticRecord
                      (sem.compiler-semantic-source-index-get
                        (& second)
                        second-generated-index)]
                    [second-symbol : sem.CompilerSemanticSymbolId
                      second-answer.symbol]
                    [invalid-keeps-first : bool
                      (match (compiler-check-source-index-with-roots
                        (owned_view.compiler-owned-shared-view path)
                        "(define broken : i64 true)"
                        (svec.new))
                        [(sem.ResultCompilerCheckWithSemanticIndex.Ok
                            _
                            replacement)
                          (begin
                            (sem.compiler-semantic-source-index-release!
                              (&mut replacement))
                            false)]
                        [(sem.ResultCompilerCheckWithSemanticIndex.Partial
                            diagnostics
                            replacement)
                          (let
                            [ok : bool
                              (and
                                (=
                                  (cdiag.compiler-diagnostic-list-count
                                    (deref diagnostics))
                                  1)
                                (not
                                  (sem.compiler-semantic-source-index-complete?
                                    (& replacement)))
                                (>=
                                  (compiler-semantic-source-index-find-definition
                                    (& replacement)
                                    path
                                    "broken")
                                  0))]
                            (begin
                              (sem.compiler-semantic-source-index-release!
                                (&mut replacement))
                              ok))]
                        [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])]
                    [ok : bool
                      (and
                        (compiler-semantic-record-vec-growth-ok?)
                        (sem.compiler-semantic-source-index-complete? (& first))
                        (compiler-check-semantic-index-record-ok?
                          source
                          answer
                          "answer"
                          sem.CompilerSemanticSymbolKind.Value)
                        (=
                          (ast.ast-source-span-start-line answer.span.source)
                          12)
                        (=
                          (ast.ast-source-span-start-col answer.span.source)
                          11)
                        (compiler-check-semantic-index-record-ok?
                          source
                          use
                          "use"
                          sem.CompilerSemanticSymbolKind.Function)
                        (compiler-check-semantic-index-record-ok?
                          source
                          pair
                          "Pair"
                          sem.CompilerSemanticSymbolKind.Struct)
                        (string.eq
                          answer.documentation
                          "Top answer documentation.\nAdditional answer detail.")
                        (sem.compiler-semantic-symbol-id-eq?
                          param-definition.symbol
                          param-use.symbol)
                        (sem.compiler-semantic-symbol-id-eq?
                          local-definition.symbol
                          local-use.symbol)
                        (sem.compiler-semantic-symbol-id-eq?
                          macro-param-definition.symbol
                          macro-param-use.symbol)
                        (=
                          use.symbol.module-id
                          param-definition.symbol.module-id)
                        (=
                          use.symbol.declaration-ordinal
                          param-definition.symbol.declaration-ordinal)
                        (not
                          (sem.compiler-semantic-symbol-id-eq?
                            answer.symbol
                            param-definition.symbol))
                        (not
                          (sem.compiler-semantic-symbol-id-eq?
                            param-definition.symbol
                            local-definition.symbol))
                        (compiler-semantic-record-span-text-eq?
                          source
                          param-definition
                          "answer")
                        (=
                          (ast.ast-source-span-start-line
                            param-definition.span.source)
                          18)
                        (=
                          (ast.ast-source-span-start-col
                            param-definition.span.source)
                          4)
                        (compiler-semantic-record-span-text-eq?
                          source
                          param-use
                          "answer")
                        (compiler-semantic-record-span-text-eq?
                          source
                          local-definition
                          "answer")
                        (=
                          (ast.ast-source-span-start-line
                            local-definition.span.source)
                          21)
                        (=
                          (ast.ast-source-span-start-col
                            local-definition.span.source)
                          6)
                        (compiler-semantic-record-span-text-eq?
                          source
                          local-use
                          "answer")
                        (compiler-semantic-record-span-text-eq?
                          source
                          macro-param-definition
                          "value")
                        (compiler-semantic-record-span-text-eq?
                          source
                          macro-param-use
                          "value")
                        (string.eq param-definition.resolved-type "i64")
                        (string.eq local-definition.resolved-type "i64")
                        (compiler-semantic-record-span-text-eq?
                          source
                          import-use
                          "dep.imported-value")
                        (sem.compiler-semantic-symbol-id-eq?
                          import-definition.symbol
                          import-use.symbol)
                        (sem.compiler-semantic-symbol-id-eq?
                          answer.symbol
                          answer-use.symbol)
                        (sem.compiler-semantic-symbol-id-eq?
                          use.symbol
                          function-use.symbol)
                        (compiler-semantic-record-span-text-eq?
                          source
                          answer-use
                          "answer")
                        (compiler-semantic-record-span-text-eq?
                          source
                          function-use
                          "use")
                        (not generated.editable)
                        (match generated.provenance
                          [(sem.CompilerSemanticProvenance.Generated _ _ _)
                            true]
                          [_ false])
                        (sem.compiler-semantic-symbol-id-eq?
                          pattern-definition.symbol
                          pattern-use.symbol)
                        (compiler-semantic-source-index-records-canonical-eq?
                          (& first)
                          (& pattern-definition)
                          (& first)
                          (& pattern-use))
                        (compiler-semantic-record-span-text-eq?
                          source
                          pattern-definition
                          "bound")
                        (compiler-semantic-record-span-text-eq?
                          source
                          pattern-use
                          "bound")
                        (string.eq pattern-definition.resolved-type "i64")
                        (string.eq
                          import-definition.documentation
                          "Imported value documentation.\nAdditional import detail.")
                        (> answer.module-id 0)
                        (= answer-symbol.module-id second-symbol.module-id)
                        (=
                          answer-symbol.declaration-ordinal
                          second-symbol.declaration-ordinal)
                        (>= second-param-index 0)
                        (>= second-generated-index 0)
                        (sem.compiler-semantic-symbol-id-eq?
                          param-definition.symbol
                          second-param.symbol)
                        (compiler-semantic-source-index-records-canonical-eq?
                          (& first)
                          (& generated)
                          (& second)
                          (& second-generated))
                        (= answer-start second-answer.span.start-byte)
                        invalid-keeps-first
                        (compiler-check-semantic-index-base-visibility-ok?
                          (& first)
                          path
                          source)
                        (=
                          (sem.compiler-semantic-source-index-len (& first))
                          first-len)
                        (string.eq answer.display-name "answer"))]
                    (begin
                      (sem.compiler-semantic-source-index-release!
                        (&mut second))
                      (sem.compiler-semantic-source-index-release! (&mut first))
                      (and
                        ok
                        (= (sem.compiler-semantic-source-index-len (& first)) 0)
                        (=
                          (sem.compiler-semantic-source-index-len (& second))
                          0))))]
                [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
                  (begin
                    (sem.compiler-semantic-source-index-release! (&mut partial))
                    (sem.compiler-semantic-source-index-release! (&mut first))
                    false)]
                [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
                  (begin
                    (sem.compiler-semantic-source-index-release! (&mut first))
                    false)]))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-macro-records-ok?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : String]
  [source : (& source str)]) : bool
  (let
    [local-definition-index : i64
      (compiler-semantic-source-index-find-definition index path "local-wrap")]
    [outer-definition-index : i64
      (compiler-semantic-source-index-find-definition index path "outer-wrap")]
    [import-definition-index : i64
      (compiler-semantic-source-index-find-definition
        index
        "src/tests/semantic/index/macro_dep.tl"
        "imported-wrap")]
    [shadow-definition-index : i64
      (compiler-semantic-source-index-find-definition
        index
        path
        "imported-wrap")]
    [local-use-zero-index : i64
      (compiler-semantic-source-index-find-macro-use index "local-wrap" true 0)]
    [local-use-one-index : i64
      (compiler-semantic-source-index-find-macro-use index "local-wrap" true 1)]
    [local-use-two-index : i64
      (compiler-semantic-source-index-find-macro-use index "local-wrap" true 2)]
    [generated-use-index : i64
      (compiler-semantic-source-index-find-macro-use index "local-wrap" false 0)]
    [import-use-index : i64
      (compiler-semantic-source-index-find-macro-use
        index
        "imported-wrap"
        true
        1)]
    [shadow-use-index : i64
      (compiler-semantic-source-index-find-macro-use
        index
        "imported-wrap"
        true
        0)]
    [emit-use-index : i64
      (compiler-semantic-source-index-find-macro-use index "emit-one" true 0)]
    [module-use-index : i64
      (compiler-semantic-source-index-find-macro-use index "make-module" true 0)]
    [outer-use-index : i64
      (compiler-semantic-source-index-find-macro-use index "outer-wrap" true 0)]
    (if (or
      (< local-definition-index 0)
      (< outer-definition-index 0)
      (< import-definition-index 0)
      (< shadow-definition-index 0)
      (< local-use-zero-index 0)
      (< local-use-one-index 0)
      (< local-use-two-index 0)
      (< generated-use-index 0)
      (< import-use-index 0)
      (< shadow-use-index 0)
      (< emit-use-index 0)
      (< module-use-index 0)
      (< outer-use-index 0))
      false
      (let
        [local-definition : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index local-definition-index)]
        [outer-definition : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index outer-definition-index)]
        [import-definition : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index import-definition-index)]
        [shadow-definition : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index shadow-definition-index)]
        [local-use-zero : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index local-use-zero-index)]
        [local-use-one : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index local-use-one-index)]
        [local-use-two : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index local-use-two-index)]
        [generated-use : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index generated-use-index)]
        [import-use : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index import-use-index)]
        [shadow-use : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index shadow-use-index)]
        [emit-use : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index emit-use-index)]
        [module-use : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index module-use-index)]
        [outer-use : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index outer-use-index)]
        (and
          (=
            (compiler-semantic-source-index-count-macro-uses
              index
              "local-wrap"
              true)
            3)
          (=
            (compiler-semantic-source-index-count-macro-uses
              index
              "local-wrap"
              false)
            1)
          (=
            (compiler-semantic-source-index-count-macro-uses
              index
              "imported-wrap"
              true)
            2)
          (=
            (compiler-semantic-source-index-count-macro-uses
              index
              "emit-one"
              true)
            1)
          (=
            (compiler-semantic-source-index-count-macro-uses
              index
              "make-module"
              true)
            1)
          (=
            (compiler-semantic-source-index-count-macro-uses
              index
              "outer-wrap"
              true)
            1)
          (=
            (compiler-semantic-source-index-count-macro-uses index "plain" true)
            0)
          (sem.compiler-semantic-symbol-id-eq?
            local-definition.symbol
            local-use-zero.symbol)
          (sem.compiler-semantic-symbol-id-eq?
            local-definition.symbol
            local-use-one.symbol)
          (sem.compiler-semantic-symbol-id-eq?
            local-definition.symbol
            local-use-two.symbol)
          (sem.compiler-semantic-symbol-id-eq?
            local-definition.symbol
            generated-use.symbol)
          (sem.compiler-semantic-symbol-id-eq?
            outer-definition.symbol
            outer-use.symbol)
          (sem.compiler-semantic-symbol-id-eq?
            import-definition.symbol
            import-use.symbol)
          (sem.compiler-semantic-symbol-id-eq?
            shadow-definition.symbol
            shadow-use.symbol)
          (string.eq
            local-definition.resolved-type
            local-use-zero.resolved-type)
          (string.eq import-definition.resolved-type import-use.resolved-type)
          (string.eq shadow-definition.resolved-type shadow-use.resolved-type)
          (< local-use-zero.span.start-byte local-use-one.span.start-byte)
          (< local-use-one.span.start-byte local-use-two.span.start-byte)
          (not
            (sem.compiler-semantic-symbol-id-eq?
              import-definition.symbol
              shadow-use.symbol))
          (compiler-semantic-record-span-text-eq?
            source
            local-use-zero
            "local-wrap")
          (compiler-semantic-record-span-text-eq?
            source
            local-use-one
            "local-wrap")
          (compiler-semantic-record-span-text-eq?
            source
            local-use-two
            "local-wrap")
          (compiler-semantic-record-span-text-eq?
            source
            import-use
            "dep.imported-wrap")
          (compiler-semantic-record-span-text-eq?
            source
            shadow-use
            "imported-wrap")
          (compiler-semantic-record-span-text-eq? source emit-use "emit-one")
          (compiler-semantic-record-span-text-eq?
            source
            module-use
            "make-module")
          (compiler-semantic-record-span-text-eq? source outer-use "outer-wrap")
          (string.eq
            local-definition.documentation
            "Local macro documentation.")
          (string.eq
            import-definition.documentation
            "Imported macro documentation.")
          (not (string.eq local-use-zero.resolved-type ""))
          (not (string.eq import-use.resolved-type ""))
          (< generated-use.span.start-byte 0)
          (not generated-use.editable)
          (match generated-use.provenance
            [(sem.CompilerSemanticProvenance.Generated generator _ key)
              (and (not (string.eq generator "")) (not (string.eq key "")))]
            [_ false]))))))

(define (compiler-check-semantic-index-macro-call-sites-ok?) : bool
  (let
    [path : String "src/tests/semantic_macro_entry.tl"]
    [source : String
      "(module semantic.macro.entry)
(import semantic.index.macro_dep as dep)
;: Local macro documentation.
(defmacro (local-wrap [value : Expr]) : Expr
  `(+ ,value 1))
(defmacro (outer-wrap [value : Expr]) : Expr
  `(local-wrap ,value))
(defmacro (imported-wrap [value : Expr]) : Expr
  `(+ ,value 10))
(defmacro (unused-template) : Expr
  `(local-wrap 99))
(defmacro (emit-one) : Decls
  `(define generated-from-macro : i64 (local-wrap 5)))
(defmacro (make-module [key : String]) : Module
  `(begin
    (module semantic.generated.module)
    (define generated-key : String ,key)))
(emit-one)
(import (make-module \"one\") as made)
(define same-text : String \"local-wrap\")
; local-wrap in a comment is not a call.
(define (plain [value : i64]) : i64 value)
(define (ordinary-shadow) : i64
  (let [local-wrap : i64 4] local-wrap))
(define (run) : i64
  (+ (local-wrap 1)
    (+ (local-wrap (local-wrap 2))
      (+ (imported-wrap 3)
        (+ (dep.imported-wrap 4)
          (+ (outer-wrap 5) (plain 6)))))))
"]
    [owners-before : i64 (compiler-semantic-source-index-live-owner-count)]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [first-ok : bool
            (compiler-check-semantic-index-macro-records-ok?
              (& first)
              (owned_view.compiler-owned-shared-view path)
              source)]
          [first-local-index : i64
            (compiler-semantic-source-index-find-macro-use
              (& first)
              "local-wrap"
              true
              0)]
          [first-local : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& first) first-local-index)]
          (match (compiler-check-source-index-with-roots
            (owned_view.compiler-owned-shared-view path)
            (owned_view.compiler-owned-shared-view source)
            (svec.new))
            [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ second)
              (let
                [second-local-index : i64
                  (compiler-semantic-source-index-find-macro-use
                    (& second)
                    "local-wrap"
                    true
                    0)]
                [second-local : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-local-index)]
                [reset-ok : bool
                  (match (compiler-check-source-index-with-roots
                    (owned_view.compiler-owned-shared-view path)
                    "(module semantic.macro.entry)
(define plain : i64 1)"
                    (svec.new))
                    [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ replacement)
                      (let
                        [empty : bool
                          (and
                            (=
                              (compiler-semantic-source-index-count-macro-uses
                                (& replacement)
                                "local-wrap"
                                true)
                              0)
                            (=
                              (compiler-semantic-source-index-count-macro-uses
                                (& replacement)
                                "imported-wrap"
                                true)
                              0)
                            (=
                              (compiler-semantic-source-index-count-macro-uses
                                (& replacement)
                                "emit-one"
                                true)
                              0))]
                        (begin
                          (sem.compiler-semantic-source-index-release!
                            (&mut replacement))
                          empty))]
                    [(sem.ResultCompilerCheckWithSemanticIndex.Partial
                        _
                        partial)
                      (begin
                        (sem.compiler-semantic-source-index-release!
                          (&mut partial))
                        false)]
                    [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])]
                [ok : bool
                  (and
                    first-ok
                    reset-ok
                    (compiler-check-semantic-index-macro-records-ok?
                      (& second)
                      path
                      source)
                    (>= first-local-index 0)
                    (>= second-local-index 0)
                    (sem.compiler-semantic-symbol-id-eq?
                      first-local.symbol
                      second-local.symbol)
                    (= first-local.span.start-byte second-local.span.start-byte))]
                (begin
                  (sem.compiler-semantic-source-index-release! (&mut second))
                  (sem.compiler-semantic-source-index-release! (&mut first))
                  (and
                    ok
                    (=
                      owners-before
                      (compiler-semantic-source-index-live-owner-count))
                    (not
                      (tc.tc-macro-call-site-state-enabled?
                        (tc.tc-job-state-macro-call-sites
                          (tc.tc-serial-job-state)))))))]
            [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut partial))
                (sem.compiler-semantic-source-index-release! (&mut first))
                false)]
            [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut first))
                false)]))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-inferred-visibility-ok?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : String]
  [source : (& source str)]) : bool
  (let
    [lambda-body-offset : i64
      (compiler-semantic-test-source-find-from source "(if scalar x x)" 0)]
    [alias-init-offset : i64
      (compiler-semantic-test-source-find-from source "[alias closure]" 0)]
    [inner-lambda-offset : i64
      (compiler-semantic-test-source-find-from source ") : bool flag)" 0)]
    [inner-call-offset : i64
      (compiler-semantic-test-source-find-from source "(callback scalar))]" 0)]
    [outer-callback-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        "callback"
        sem.CompilerSemanticRecordRole.Definition
        0)]
    [inner-callback-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        "callback"
        sem.CompilerSemanticRecordRole.Definition
        1)]
    (if (or
      (< lambda-body-offset 0)
      (< alias-init-offset 0)
      (< inner-lambda-offset 0)
      (< inner-call-offset 0)
      (< outer-callback-index 0)
      (< inner-callback-index 0))
      false
      (let
        [lambda-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            lambda-body-offset)]
        [alias-init-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ alias-init-offset (string.string-length "[alias ")))]
        [inner-lambda-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ inner-lambda-offset (string.string-length ") : bool ")))]
        [inner-call-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at index path inner-call-offset)]
        [outer-callback : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index outer-callback-index)]
        [inner-callback : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index inner-callback-index)]
        (and
          (=
            (compiler-semantic-test-visible-label-count
              index
              lambda-query
              1
              "x")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              lambda-query
              1
              "scalar")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              lambda-query
              1
              "closure")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              alias-init-query
              1
              "x")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              alias-init-query
              1
              "closure")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              alias-init-query
              1
              "alias")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              inner-lambda-query
              1
              "flag")
            1)
          (compiler-semantic-test-visible-symbol?
            index
            inner-lambda-query
            1
            "callback"
            outer-callback.symbol)
          (not
            (compiler-semantic-test-visible-symbol?
              index
              inner-lambda-query
              1
              "callback"
              inner-callback.symbol))
          (compiler-semantic-test-visible-symbol?
            index
            inner-call-query
            1
            "callback"
            inner-callback.symbol))))))

(define (compiler-check-semantic-index-inferred-locals-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_inferred_locals.tl"]
    [source : String
      "(define (plus-one [x : i64]) : i64 (+ x 1))
(define (drop-i64 [_value : i64]) : unit unit)
(defenum SemanticChoice (SemanticEmpty) (SemanticFull i64))
(define (enum-probe [value : SemanticChoice]) : i64
  (match value
    [SemanticEmpty 0]
    [(SemanticFull item) item]))
(define (resource-probe) : i64
  (with ([resource 7 drop-i64]) (+ resource 1)))
(define (probe) : i64
  (let
    [scalar true]
    [closure (lambda ([x : i64]) : i64 (if scalar x x))]
    [alias closure]
    [callback plus-one]
    [nested
      (let
        [callback (lambda ([flag : bool]) : bool flag)]
        (callback scalar))]
    (if nested (alias (callback 0)) 0)))"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [scalar-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "scalar"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [closure-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "closure"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [alias-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "alias"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [outer-callback-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "callback"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [inner-callback-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "callback"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [resource-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "resource"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [enum-variant-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "SemanticEmpty"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [enum-item-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "item"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          (if (or
            (< scalar-definition-index 0)
            (< closure-definition-index 0)
            (< alias-definition-index 0)
            (< outer-callback-definition-index 0)
            (< inner-callback-definition-index 0)
            (< resource-definition-index 0)
            (< enum-variant-definition-index 0)
            (< enum-item-definition-index 0))
            (begin
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)
            (let
              [scalar-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  scalar-definition-index)]
              [closure-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  closure-definition-index)]
              [alias-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  alias-definition-index)]
              [outer-callback-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  outer-callback-definition-index)]
              [inner-callback-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  inner-callback-definition-index)]
              [resource-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  resource-definition-index)]
              [enum-item-definition : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  enum-item-definition-index)]
              [closure-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  closure-definition.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [alias-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  alias-definition.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [outer-callback-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  outer-callback-definition.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [inner-callback-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  inner-callback-definition.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [resource-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  resource-definition.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [enum-item-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  enum-item-definition.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [closure-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  closure-use-index)]
              [alias-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  alias-use-index)]
              [outer-callback-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  outer-callback-use-index)]
              [inner-callback-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  inner-callback-use-index)]
              [resource-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  resource-use-index)]
              [enum-item-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  enum-item-use-index)]
              (match (compiler-check-source-index-with-roots
                (owned_view.compiler-owned-shared-view path)
                (owned_view.compiler-owned-shared-view source)
                (svec.new))
                [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ second)
                  (let
                    [second-alias-index : i64
                      (compiler-semantic-source-index-find-name-occurrence
                        (& second)
                        path
                        "alias"
                        sem.CompilerSemanticRecordRole.Definition
                        0)]
                    [second-alias : sem.CompilerSemanticRecord
                      (sem.compiler-semantic-source-index-get
                        (& second)
                        second-alias-index)]
                    [ok : bool
                      (and
                        (>= closure-use-index 0)
                        (>= alias-use-index 0)
                        (>= outer-callback-use-index 0)
                        (>= inner-callback-use-index 0)
                        (>= resource-use-index 0)
                        (>= enum-item-use-index 0)
                        (string.eq scalar-definition.resolved-type "bool")
                        (string.eq
                          closure-definition.resolved-type
                          "(-> i64 i64)")
                        (string.eq
                          alias-definition.resolved-type
                          "(-> i64 i64)")
                        (string.eq
                          outer-callback-definition.resolved-type
                          "(-> i64 i64)")
                        (string.eq
                          inner-callback-definition.resolved-type
                          "(-> bool bool)")
                        (string.eq resource-definition.resolved-type "i64")
                        (string.eq enum-item-definition.resolved-type "i64")
                        (string.eq closure-use.resolved-type "(-> i64 i64)")
                        (string.eq alias-use.resolved-type "(-> i64 i64)")
                        (string.eq
                          outer-callback-use.resolved-type
                          "(-> i64 i64)")
                        (string.eq
                          inner-callback-use.resolved-type
                          "(-> bool bool)")
                        (string.eq resource-use.resolved-type "i64")
                        (string.eq enum-item-use.resolved-type "i64")
                        (not
                          (sem.compiler-semantic-symbol-id-eq?
                            outer-callback-definition.symbol
                            inner-callback-definition.symbol))
                        (string.eq second-alias.resolved-type "(-> i64 i64)")
                        (compiler-check-semantic-index-inferred-visibility-ok?
                          (& first)
                          path
                          source)
                        ;; The second complete check resets compiler state; the
                        ;; first index must still own its rendered type text.
                        (string.eq
                          alias-definition.resolved-type
                          "(-> i64 i64)"))]
                    (begin
                      (sem.compiler-semantic-source-index-release!
                        (&mut second))
                      (sem.compiler-semantic-source-index-release! (&mut first))
                      (and
                        ok
                        (= (sem.compiler-semantic-source-index-len (& first)) 0)
                        (=
                          (sem.compiler-semantic-source-index-len (& second))
                          0))))]
                [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
                  (begin
                    (sem.compiler-semantic-source-index-release! (&mut partial))
                    (sem.compiler-semantic-source-index-release! (&mut first))
                    false)]
                [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
                  (begin
                    (sem.compiler-semantic-source-index-release! (&mut first))
                    false)]))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

;; Slice pattern binders are ordinary locals: element binders take the element
;; type and the rest binder the borrowed view's type.
(define (compiler-check-semantic-index-slice-pattern-locals-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_slice_pattern_locals.tl"]
    [source : String
      "(define (slice-probe [items : (& (Slice i64))]) : i64
  (match items
    [(slice) 0]
    [(slice head & tail) (+ head (array-length tail))]))"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [head-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "head"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [tail-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "tail"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          (if (or (< head-index 0) (< tail-index 0))
            (begin
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)
            (let
              [head : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& first) head-index)]
              [tail : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& first) tail-index)]
              [head-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  head.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [tail-use-index : i64
                (sem.compiler-semantic-source-index-find-symbol-role
                  (& first)
                  tail.symbol
                  sem.CompilerSemanticRecordRole.Use)]
              [ok : bool
                (and
                  (>= head-use-index 0)
                  (>= tail-use-index 0)
                  (string.eq head.resolved-type "i64")
                  (string.eq tail.resolved-type "(& (Slice i64))"))]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut first))
                ok))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-retained-transitions-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_retained_transitions.tl"]
    [source : String
      "(import stdlib.arena)
(import stdlib.string)
(extern raw-fn (:symbol \"semantic_index_raw_fn\") : (CFunc non-null (-> i64 i64)))
(define (read-ref [value : (& owner i64)]) : i64 1)
(define (read-owned [value : String]) : i64 1)
(define (probe [n : i64]) : i64
  (let
    [ref (& n)]
    [ref-closure (lambda () : i64 (read-ref ref))]
    [owned : String \"repeat\"]
    [move-closure (lambda () : i64 (read-owned owned))]
    [once : String \"once\"]
    [consume-closure (lambda () : String once)]
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [raw-copy raw-fn]
    [score (+ (ref-closure) (+ (move-closure) (raw-copy 39)))]
    [taken (consume-closure)]
    (begin
      (arena.rewind-safe! phase)
      (arena.destroy-safe! owner)
      (+ score (string.string-length taken)))))"]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push-ref! (&mut items) "stdlib")
          items))]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      source
      roots)
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [ref-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ref"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [ref-closure-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ref-closure"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [move-closure-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "move-closure"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [consume-closure-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "consume-closure"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [owner-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "owner"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [phase-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "phase"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [raw-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "raw-copy"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [taken-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "taken"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [ok : bool
            (and
              (>= ref-index 0)
              (>= ref-closure-index 0)
              (>= move-closure-index 0)
              (>= consume-closure-index 0)
              (>= owner-index 0)
              (>= phase-index 0)
              (>= raw-index 0)
              (>= taken-index 0)
              (string.eq
                (sem.compiler-semantic-source-index-get (& index) raw-index).resolved-type
                "(CFunc non-null (-> i64 i64))"))]
          (begin
            (sem.compiler-semantic-source-index-release! (&mut index))
            (and ok (= (sem.compiler-semantic-source-index-len (& index)) 0))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-dense-visibility-ok?
  [index : (& index sem.CompilerSemanticSourceIndex)]
  [path : String]
  [source : (& source str)]) : bool
  (let
    [resource-body : i64
      (compiler-semantic-test-source-find-from source "(+ item resource)" 0)]
    [resource-init : i64
      (compiler-semantic-test-source-find-from source "[resource item" 0)]
    [resource-sibling : i64
      (compiler-semantic-test-source-find-from source "[ScopeNone 0]" 0)]
    [foreach-body : i64
      (compiler-semantic-test-source-find-from source "[i : i64 0 n]" 0)]
    [scan-value : i64
      (compiler-semantic-test-source-find-from source "\n      k\n" 0)]
    [scan-body : i64
      (compiler-semantic-test-source-find-from source "_seen-prefix" 0)]
    [reduce-value : i64
      (compiler-semantic-test-source-find-from source " 0 j)))" 0)]
    [inner-shadow : i64
      (compiler-semantic-test-source-find-from
        source
        "                        shadow))))"
        0)]
    [sibling-shadow : i64
      (compiler-semantic-test-source-find-from
        source
        "[shadow : i64 (+ shadow 20)] shadow"
        0)]
    [shadow-definition-index : i64
      (compiler-semantic-source-index-find-name-occurrence
        index
        path
        "shadow"
        sem.CompilerSemanticRecordRole.Definition
        10)]
    (if (or
      (< resource-body 0)
      (< resource-init 0)
      (< resource-sibling 0)
      (< foreach-body 0)
      (< scan-value 0)
      (< scan-body 0)
      (< reduce-value 0)
      (< inner-shadow 0)
      (< sibling-shadow 0)
      (< shadow-definition-index 0))
      false
      (let
        [resource-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            resource-body)]
        [resource-init-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ resource-init (string.string-length "[resource ")))]
        [resource-sibling-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            resource-sibling)]
        [foreach-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+
              foreach-body
              (string.string-length "[i : i64 0 n]) (let [_seen : i64 ")))]
        [scan-value-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ scan-value 7))]
        [scan-body-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            scan-body)]
        [reduce-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ reduce-value 3))]
        [inner-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ inner-shadow 24))]
        [sibling-init-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            (owned_view.compiler-owned-shared-view path)
            (+ sibling-shadow (string.string-length "[shadow : i64 (+ ")))]
        [sibling-body-query : sem.CompilerSemanticVisibleBindingQuery
          (compiler-semantic-test-query-at
            index
            path
            (+
              sibling-shadow
              (string.string-length "[shadow : i64 (+ shadow 20)] ")))]
        [inner-shadow-record : sem.CompilerSemanticRecord
          (sem.compiler-semantic-source-index-get index shadow-definition-index)]
        (and
          (=
            (compiler-semantic-test-visible-label-count
              index
              resource-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "item")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              resource-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "resource")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              resource-init-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "resource")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              resource-sibling-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "item")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              resource-sibling-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "resource")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              foreach-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "i")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              scan-value-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "k")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              scan-value-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "prefix")
            0)
          (=
            (compiler-semantic-test-visible-label-count
              index
              scan-body-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "k")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              scan-body-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "prefix")
            1)
          (=
            (compiler-semantic-test-visible-label-count
              index
              reduce-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "j")
            1)
          (compiler-semantic-test-visible-symbol?
            index
            inner-query
            (sem.compiler-semantic-binding-namespace-value-mask)
            "shadow"
            inner-shadow-record.symbol)
          (not
            (compiler-semantic-test-visible-symbol?
              index
              sibling-init-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "shadow"
              inner-shadow-record.symbol))
          (=
            (compiler-semantic-test-visible-label-count
              index
              sibling-body-query
              (sem.compiler-semantic-binding-namespace-value-mask)
              "shadow")
            1))))))

;; Paired scan/compact fixtures pin the shared two-level scope protocol.
;; Range/init references see parameters; the element sees only the inner index;
;; the body sees both inner names, and the following expression restores both.
(define (compiler-check-semantic-index-spmd-state-scopes-ok? [source : String]) : bool
  (let
    [path : String "src/tests/semantic_spmd_state.tl"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      source
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [ok : bool
            (and
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "i"
                0
                0)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "i"
                0
                1)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "i"
                1
                2)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "i"
                1
                3)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "i"
                0
                4)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "state"
                0
                0)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "state"
                0
                1)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "state"
                1
                2)
              (compiler-semantic-source-index-name-symbol-match?
                (& index)
                path
                "state"
                0
                3))]
          (begin
            (sem.compiler-semantic-source-index-release! (&mut index))
            ok))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-spmd-paired-scopes-ok?) : bool
  (and
    (compiler-check-semantic-index-spmd-state-scopes-ok?
      "(define (scan [i : i64] [state : i64]) : i64
  (begin (spmd-scan sum ([i : i64 i (+ i 2)] [state : i64 state])
       (+ i state) (let [_seen : i64 (+ i state)] unit))
     (+ i state)))")
    (compiler-check-semantic-index-spmd-state-scopes-ok?
      "(define (compact [i : i64] [state : i64]) : i64
  (begin (spmd-compact ([i : i64 i (+ i 2)] [state : i64 state])
       (> (+ i state) 0) (let [_seen : i64 (+ i state)] unit))
     (+ i state)))")))

(define (compiler-check-semantic-index-dense-scopes-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_dense_scopes.tl"]
    [source : String
      "(defenum ScopeChoice (ScopeNone) (ScopeSome i64))

(define (drop-i64 [_value : i64]) : unit unit)

(defmacro (emit-active [value : Expr]) : Expr
  `(let [macro-local : i64 1] (+ ,value macro-local)))

(define (deep [shadow : i64]) : i64
  (begin
    (let
      [shadow : i64 (+ shadow 1)]
      (let
        [shadow : i64 (+ shadow 1)]
        (let
          [shadow : i64 (+ shadow 1)]
          (let
            [shadow : i64 (+ shadow 1)]
            (let
              [shadow : i64 (+ shadow 1)]
              (let
                [shadow : i64 (+ shadow 1)]
                (let
                  [shadow : i64 (+ shadow 1)]
                  (let
                    [shadow : i64 (+ shadow 1)]
                    (let
                      [shadow : i64 (+ shadow 1)]
                      (let
                        [shadow : i64 (+ shadow 1)]
                        shadow))))))))))
    (let [shadow : i64 (+ shadow 20)] shadow)
    shadow))

(define (pattern-resource [choice : ScopeChoice]) : i64
  (match choice
    [(ScopeSome item)
      (with ([resource item drop-i64]) (+ item resource))]
    [ScopeNone 0]))

(define (macro-use [value : i64]) : i64
  (emit-active value))

(define (spmd-scope [n : i64]) : i64
  (begin
    (foreach ([i : i64 0 n]) (let [_seen : i64 i] unit))
    (spmd-scan
      sum
      ([k : i64 0 n] [prefix : i64 0])
      k
      (let [_seen-prefix : i64 prefix] unit))
    (spmd-reduce sum ([j : i64 0 n]) 0 j)))

(define (main) : i64
  (+ (deep 1) (pattern-resource (ScopeSome 2)) (macro-use 3) (spmd-scope 4)))"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [shadow-chain-ok : bool true]
          [shadow-occurrence : i64 0]
          (begin
            (while (<= shadow-occurrence 10)
              (begin
                (if (compiler-semantic-source-index-name-symbol-match?
                  (& index)
                  path
                  "shadow"
                  shadow-occurrence
                  shadow-occurrence)
                  unit
                  (set! shadow-chain-ok false))
                (set! shadow-occurrence (+ shadow-occurrence 1))))
            (let
              [ok : bool
                (and
                  shadow-chain-ok
                  ;; The first sibling's nested chain must restore the
                  ;; parameter before the next sibling initializer and after
                  ;; both siblings have completed.
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "shadow"
                    0
                    11)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "shadow"
                    11
                    12)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "shadow"
                    0
                    13)
                  ;; Active unquote and its caller parameter retain distinct,
                  ;; stable local identities.
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "value"
                    0
                    0)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "value"
                    1
                    1)
                  (>=
                    (compiler-semantic-source-index-find-name-occurrence
                      (& index)
                      path
                      "macro-local"
                      sem.CompilerSemanticRecordRole.Definition
                      0)
                    0)
                  ;; Match patterns, resources, foreach indices, and SPMD
                  ;; indices all extend only their lexical child snapshots.
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "item"
                    0
                    0)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "resource"
                    0
                    0)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "i"
                    0
                    0)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "j"
                    0
                    0)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "k"
                    0
                    0)
                  (compiler-semantic-source-index-name-symbol-match?
                    (& index)
                    path
                    "prefix"
                    0
                    0)
                  (compiler-check-semantic-index-dense-visibility-ok?
                    (& index)
                    path
                    source))]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut index))
                ok))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-partial-type-error-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_partial_type_error.tl"]
    [invalid-source : String
      "(define good : i64 1)
(define (broken [same : i64]) : i64
  (let [same : i64 (+ same good)] (+ same true)))
(define (later [same : i64]) : i64 (+ same good))"]
    [valid-source : String
      "(define good : i64 1)
(define (broken [same : i64]) : i64
  (let [same : i64 (+ same good)] (+ same 1)))
(define (later [same : i64]) : i64 (+ same good))"]
    [owners-before : i64 (compiler-semantic-source-index-live-owner-count)]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view invalid-source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial diagnostics partial)
        (let
          [partial-good-index : i64
            (compiler-semantic-source-index-find-definition
              (& partial)
              path
              "good")]
          [partial-broken-index : i64
            (compiler-semantic-source-index-find-definition
              (& partial)
              path
              "broken")]
          [partial-later-index : i64
            (compiler-semantic-source-index-find-definition
              (& partial)
              path
              "later")]
          [partial-good : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-good-index)]
          [partial-broken : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-broken-index)]
          [partial-later : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-later-index)]
          [partial-same-param-index : i64
            (compiler-semantic-source-index-find-record
              (& partial)
              path
              "same"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [partial-same-local-index : i64
            (compiler-semantic-source-index-find-record
              (& partial)
              path
              "same"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [partial-same-param : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-same-param-index)]
          [partial-same-local : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-same-local-index)]
          (match (compiler-check-source-index-with-roots
            (owned_view.compiler-owned-shared-view path)
            valid-source
            (svec.new))
            [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ complete)
              (let
                [complete-good-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& complete)
                    path
                    "good")]
                [complete-broken-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& complete)
                    path
                    "broken")]
                [complete-later-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& complete)
                    path
                    "later")]
                [complete-good : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& complete)
                    complete-good-index)]
                [complete-broken : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& complete)
                    complete-broken-index)]
                [complete-later : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& complete)
                    complete-later-index)]
                [ok : bool
                  (and
                    (=
                      (cdiag.compiler-diagnostic-list-count (deref diagnostics))
                      1)
                    (not
                      (sem.compiler-semantic-source-index-complete? (& partial)))
                    (sem.compiler-semantic-source-index-complete? (& complete))
                    (match (sem.compiler-semantic-source-index-query
                      (& partial)
                      (owned_view.compiler-owned-shared-view path)
                      partial-same-local.span.end-byte)
                      [(sem.CompilerSemanticMaybeVisibleBindingQuery.Some query)
                        (>
                          (compiler-semantic-source-index-visible-binding-count
                            (& partial)
                            query
                            (sem.compiler-semantic-binding-namespace-value-mask))
                          0)]
                      [_ false])
                    (>= partial-good-index 0)
                    (>= partial-broken-index 0)
                    (>= partial-later-index 0)
                    (>= partial-same-param-index 0)
                    (>= partial-same-local-index 0)
                    (compiler-semantic-record-span-text-eq?
                      invalid-source
                      partial-good
                      "good")
                    (compiler-semantic-record-span-text-eq?
                      invalid-source
                      partial-broken
                      "broken")
                    (compiler-semantic-record-span-text-eq?
                      invalid-source
                      partial-later
                      "later")
                    (not
                      (sem.compiler-semantic-symbol-id-eq?
                        partial-same-param.symbol
                        partial-same-local.symbol))
                    (compiler-semantic-source-index-name-symbol-match?
                      (& partial)
                      path
                      "same"
                      0
                      0)
                    (compiler-semantic-source-index-name-symbol-match?
                      (& partial)
                      path
                      "same"
                      1
                      1)
                    (sem.compiler-semantic-symbol-id-eq?
                      partial-good.symbol
                      complete-good.symbol)
                    (sem.compiler-semantic-symbol-id-eq?
                      partial-broken.symbol
                      complete-broken.symbol)
                    (sem.compiler-semantic-symbol-id-eq?
                      partial-later.symbol
                      complete-later.symbol))]
                (begin
                  (sem.compiler-semantic-source-index-release! (&mut complete))
                  (sem.compiler-semantic-source-index-release! (&mut partial))
                  (and
                    ok
                    (=
                      owners-before
                      (compiler-semantic-source-index-live-owner-count)))))]
            [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ unexpected)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut unexpected))
                (sem.compiler-semantic-source-index-release! (&mut partial))
                false)]
            [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut partial))
                false)]))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ unexpected)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut unexpected))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-partial-syntax-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_partial_syntax.tl"]
    [invalid-source : String
      "(define partial-anchor : i64 1)
(define (uses-anchor) : i64 (+ partial-anchor 1))
(define unfinished : i64 (+ partial-anchor"]
    [valid-source : String
      "(define partial-anchor : i64 1)
(define (uses-anchor) : i64 (+ partial-anchor 1))
(define unfinished : i64 (+ partial-anchor 2))"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view invalid-source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial diagnostics partial)
        (let
          [partial-first-index : i64
            (compiler-semantic-source-index-find-definition
              (& partial)
              path
              "partial-anchor")]
          [partial-use-index : i64
            (compiler-semantic-source-index-find-record
              (& partial)
              path
              "partial-anchor"
              sem.CompilerSemanticRecordRole.Use
              -1)]
          [partial-unfinished-index : i64
            (compiler-semantic-source-index-find-definition
              (& partial)
              path
              "unfinished")]
          [partial-first : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-first-index)]
          [partial-use : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get
              (& partial)
              partial-use-index)]
          (match (compiler-check-source-index-with-roots
            (owned_view.compiler-owned-shared-view path)
            valid-source
            (svec.new))
            [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ complete)
              (let
                [complete-first-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& complete)
                    path
                    "partial-anchor")]
                [complete-first : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& complete)
                    complete-first-index)]
                [ok : bool
                  (and
                    (=
                      (cdiag.compiler-diagnostic-list-count (deref diagnostics))
                      1)
                    (not
                      (sem.compiler-semantic-source-index-complete? (& partial)))
                    (>= partial-first-index 0)
                    (>= partial-use-index 0)
                    (< partial-unfinished-index 0)
                    (compiler-semantic-record-span-text-eq?
                      invalid-source
                      partial-first
                      "partial-anchor")
                    (compiler-semantic-record-span-text-eq?
                      invalid-source
                      partial-use
                      "partial-anchor")
                    (sem.compiler-semantic-symbol-id-eq?
                      partial-first.symbol
                      partial-use.symbol)
                    (sem.compiler-semantic-symbol-id-eq?
                      partial-first.symbol
                      complete-first.symbol))]
                (begin
                  (sem.compiler-semantic-source-index-release! (&mut complete))
                  (sem.compiler-semantic-source-index-release! (&mut partial))
                  ok))]
            [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ unexpected)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut unexpected))
                (sem.compiler-semantic-source-index-release! (&mut partial))
                false)]
            [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut partial))
                false)]))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ unexpected)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut unexpected))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-partial-diagnostics-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_partial_diagnostics.tl"]
    [source : String "(define)
(define later : i64 missing-value)"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial diagnostics partial)
        (let
          [diagnostic-list : cdiag.CompilerDiagnosticList (deref diagnostics)]
          [later-index : i64
            (compiler-semantic-source-index-find-definition
              (& partial)
              path
              "later")]
          [missing-index : i64
            (compiler-semantic-source-index-find-record
              (& partial)
              path
              "missing-value"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [later : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& partial) later-index)]
          [ok : bool
            (and
              (= diagnostic-list.len 2)
              (string.eq
                (cdiag.compiler-diagnostic-message
                  (cdiag.compiler-diagnostic-list-ref (& diagnostic-list) 0))
                "parse: malformed define")
              (string.eq
                (cdiag.compiler-diagnostic-message
                  (cdiag.compiler-diagnostic-list-ref (& diagnostic-list) 1))
                "typecheck: unbound name missing-value")
              (>= later-index 0)
              (< missing-index 0)
              (compiler-semantic-record-span-text-eq? source later "later"))]
          (begin
            (sem.compiler-semantic-source-index-release! (&mut partial))
            ok))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ unexpected)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut unexpected))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-partial-edge-result-ok?
  [path : String]
  [source : String]
  [expected-name : String]
  [expected-present : bool]) : bool
  (match (compiler-check-source-index-with-roots
    (owned_view.compiler-owned-shared-view path)
    source
    (svec.new))
    [(sem.ResultCompilerCheckWithSemanticIndex.Partial diagnostics partial)
      (let
        [record-index : i64
          (compiler-semantic-source-index-find-definition
            (& partial)
            path
            expected-name)]
        [ok : bool
          (and
            (> (cdiag.compiler-diagnostic-list-count (deref diagnostics)) 0)
            (not (sem.compiler-semantic-source-index-complete? (& partial)))
            (if expected-present
              (>= record-index 0)
              (< record-index 0)))]
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          ok))]
    [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ unexpected)
      (begin
        (sem.compiler-semantic-source-index-release! (&mut unexpected))
        false)]
    [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false]))

(define (compiler-check-semantic-index-partial-edge-cases-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_partial_edges.tl"]
    [owners-before : i64 (compiler-semantic-source-index-live-owner-count)]
    [before-first : bool
      (compiler-check-semantic-index-partial-edge-result-ok?
        (owned_view.compiler-owned-shared-view path)
        ")\n(define later : i64 1)"
        "later"
        true)]
    [bad-import : bool
      (compiler-check-semantic-index-partial-edge-result-ok?
        (owned_view.compiler-owned-shared-view path)
        "(import semantic.index.definitely_missing as missing)\n(define local : i64 1)"
        "local"
        false)]
    [iteration : i64 0]
    [bounded : bool true]
    (begin
      (while (< iteration 8)
        (begin
          (if (compiler-check-semantic-index-partial-edge-result-ok?
            (owned_view.compiler-owned-shared-view path)
            "(define current : i64 true)"
            "current"
            true)
            unit
            (set! bounded false))
          (set! iteration (+ iteration 1))))
      (and
        before-first
        bad-import
        bounded
        (= owners-before (compiler-semantic-source-index-live-owner-count))
        (match (compiler-check-source-index-with-roots
          path
          "\"unterminated"
          (svec.new))
          [(sem.ResultCompilerCheckWithSemanticIndex.Err diagnostics)
            (> (cdiag.compiler-diagnostic-list-count (deref diagnostics)) 0)]
          [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ unexpected)
            (begin
              (sem.compiler-semantic-source-index-release! (&mut unexpected))
              false)]
          [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ unexpected)
            (begin
              (sem.compiler-semantic-source-index-release! (&mut unexpected))
              false)])))))

(define (compiler-check-semantic-index-partial-ok?) : bool
  (and
    (compiler-check-semantic-index-partial-type-error-ok?)
    (compiler-check-semantic-index-partial-syntax-ok?)
    (compiler-check-semantic-index-partial-diagnostics-ok?)
    (compiler-check-semantic-index-partial-edge-cases-ok?)))

(define (compiler-check-semantic-index-canonical-cross-snapshot-ok?) : bool
  (let
    [first-path : String "src/tests/semantic_canonical_entry_a.tl"]
    [second-path : String "src/tests/semantic_canonical_entry_b.tl"]
    [shared-path : String "src/tests/semantic/canonical/shared.tl"]
    [noise-path : String "src/tests/semantic/canonical/noise.tl"]
    [first-source : String
      "(module semantic.canonical.entry_a)
(import semantic.canonical.noise as noise)
(import semantic.canonical.shared.*)
(define (consume [local : i64]) : i64
  (+
    noise.shared-value
    (function (macro shared-value))
    local))
(define (pair-value [pair : SharedPair]) : i64 pair.value)"]
    [second-source : String
      "(module semantic.canonical.entry_b)
(import semantic.canonical.shared.shared-value as chosen-value)
(import semantic.canonical.shared.function as chosen-function)
(import semantic.canonical.shared.macro as chosen-macro)
(import semantic.canonical.shared.SharedPair as ChosenPair)
(import semantic.canonical.noise as noise)
(define (consume [local : i64]) : i64
  (+
    (chosen-function (chosen-macro chosen-value))
    noise.shared-value
    local))
(define (pair-value [pair : ChosenPair]) : i64 pair.value)"]
    [owners-before : i64 (compiler-semantic-source-index-live-owner-count)]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view first-path)
      first-source
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [first-shared-definition-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              shared-path
              "shared-value")]
          [first-shared-use-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              first-path
              "shared-value"
              sem.CompilerSemanticRecordRole.Use
              1)]
          [first-noise-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              noise-path
              "shared-value")]
          [first-local-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              first-path
              "local"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [first-function-definition-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              shared-path
              "function")]
          [first-function-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              first-path
              "function"
              sem.CompilerSemanticRecordRole.Use
              -1)]
          [first-macro-definition-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              shared-path
              "macro")]
          [first-macro-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              first-path
              "macro"
              sem.CompilerSemanticRecordRole.Use
              -1)]
          [first-type-definition-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              shared-path
              "SharedPair")]
          (match (compiler-check-source-index-with-roots
            (owned_view.compiler-owned-shared-view second-path)
            (owned_view.compiler-owned-shared-view second-source)
            (svec.new))
            [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ second)
              (let
                [second-shared-definition-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& second)
                    shared-path
                    "shared-value")]
                [second-shared-use-index : i64
                  (compiler-semantic-source-index-find-name-occurrence
                    (& second)
                    second-path
                    "shared-value"
                    sem.CompilerSemanticRecordRole.Use
                    0)]
                [second-shared-alias-definition-index : i64
                  (compiler-semantic-source-index-find-name-occurrence
                    (& second)
                    second-path
                    "shared-value"
                    sem.CompilerSemanticRecordRole.Definition
                    0)]
                [second-shared-alias-use-index : i64
                  (compiler-semantic-source-index-find-name-occurrence
                    (& second)
                    second-path
                    "shared-value"
                    sem.CompilerSemanticRecordRole.Use
                    1)]
                [second-local-index : i64
                  (compiler-semantic-source-index-find-record
                    (& second)
                    second-path
                    "local"
                    sem.CompilerSemanticRecordRole.Definition
                    0)]
                [second-function-definition-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& second)
                    shared-path
                    "function")]
                [second-function-use-index : i64
                  (compiler-semantic-source-index-find-record
                    (& second)
                    second-path
                    "function"
                    sem.CompilerSemanticRecordRole.Use
                    -1)]
                [second-macro-definition-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& second)
                    shared-path
                    "macro")]
                [second-macro-use-index : i64
                  (compiler-semantic-source-index-find-record
                    (& second)
                    second-path
                    "macro"
                    sem.CompilerSemanticRecordRole.Use
                    -1)]
                [second-type-definition-index : i64
                  (compiler-semantic-source-index-find-definition
                    (& second)
                    shared-path
                    "SharedPair")]
                [first-shared-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-shared-definition-index)]
                [first-shared-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-shared-use-index)]
                [first-noise : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-noise-index)]
                [first-local : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-local-index)]
                [second-shared-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-shared-definition-index)]
                [second-shared-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-shared-use-index)]
                [second-shared-alias-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-shared-alias-definition-index)]
                [second-shared-alias-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-shared-alias-use-index)]
                [second-local : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-local-index)]
                [first-function-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-function-definition-index)]
                [first-function-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-function-use-index)]
                [first-macro-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-macro-definition-index)]
                [first-macro-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-macro-use-index)]
                [first-type-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& first)
                    first-type-definition-index)]
                [second-function-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-function-definition-index)]
                [second-function-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-function-use-index)]
                [second-macro-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-macro-definition-index)]
                [second-macro-use : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-macro-use-index)]
                [second-type-definition : sem.CompilerSemanticRecord
                  (sem.compiler-semantic-source-index-get
                    (& second)
                    second-type-definition-index)]
                [ok : bool
                  (and
                    (>= first-shared-definition-index 0)
                    (>= first-shared-use-index 0)
                    (>= first-noise-index 0)
                    (>= first-local-index 0)
                    (>= second-shared-definition-index 0)
                    (>= second-shared-use-index 0)
                    (>= second-shared-alias-definition-index 0)
                    (>= second-shared-alias-use-index 0)
                    (>= second-local-index 0)
                    (>= first-function-definition-index 0)
                    (>= first-function-use-index 0)
                    (>= first-macro-definition-index 0)
                    (>= first-macro-use-index 0)
                    (>= first-type-definition-index 0)
                    (>= second-function-definition-index 0)
                    (>= second-function-use-index 0)
                    (>= second-macro-definition-index 0)
                    (>= second-macro-use-index 0)
                    (>= second-type-definition-index 0)
                    ;; The deliberate load-order change proves the old dense
                    ;; identity is not a cross-snapshot contract.
                    (not
                      (sem.compiler-semantic-symbol-id-eq?
                        first-shared-definition.symbol
                        second-shared-definition.symbol))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-shared-definition)
                      (& second)
                      (& second-shared-definition))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-shared-definition)
                      (& first)
                      (& first-shared-use))
                    (=
                      first-shared-definition.canonical-index
                      first-shared-use.canonical-index)
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& second)
                      (& second-shared-definition)
                      (& second)
                      (& second-shared-use))
                    (=
                      second-shared-definition.canonical-index
                      second-shared-use.canonical-index)
                    (sem.compiler-semantic-symbol-id-eq?
                      second-shared-definition.symbol
                      second-shared-alias-definition.symbol)
                    (sem.compiler-semantic-symbol-id-eq?
                      second-shared-definition.symbol
                      second-shared-alias-use.symbol)
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& second)
                      (& second-shared-definition)
                      (& second)
                      (& second-shared-alias-definition))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& second)
                      (& second-shared-definition)
                      (& second)
                      (& second-shared-alias-use))
                    (compiler-semantic-record-span-text-eq?
                      second-source
                      second-shared-use
                      "shared-value")
                    (compiler-semantic-record-span-text-eq?
                      second-source
                      second-shared-alias-definition
                      "chosen-value")
                    (compiler-semantic-record-span-text-eq?
                      second-source
                      second-shared-alias-use
                      "chosen-value")
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-function-definition)
                      (& second)
                      (& second-function-definition))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-function-definition)
                      (& first)
                      (& first-function-use))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& second)
                      (& second-function-definition)
                      (& second)
                      (& second-function-use))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-macro-definition)
                      (& second)
                      (& second-macro-definition))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-macro-definition)
                      (& first)
                      (& first-macro-use))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& second)
                      (& second-macro-definition)
                      (& second)
                      (& second-macro-use))
                    (compiler-semantic-source-index-records-canonical-eq?
                      (& first)
                      (& first-type-definition)
                      (& second)
                      (& second-type-definition))
                    (not
                      (compiler-semantic-source-index-records-canonical-eq?
                        (& first)
                        (& first-shared-definition)
                        (& first)
                        (& first-noise)))
                    (not
                      (compiler-semantic-source-index-records-canonical-eq?
                        (& first)
                        (& first-local)
                        (& second)
                        (& second-local)))
                    (<
                      (compiler-semantic-source-index-canonical-symbol-count
                        (& first))
                      (sem.compiler-semantic-source-index-len (& first)))
                    (>
                      (compiler-semantic-source-index-canonical-key-byte-count
                        (& first))
                      0))]
                (begin
                  (sem.compiler-semantic-source-index-release! (&mut second))
                  (sem.compiler-semantic-source-index-release! (&mut first))
                  (and
                    ok
                    (=
                      owners-before
                      (compiler-semantic-source-index-live-owner-count)))))]
            [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut partial))
                (sem.compiler-semantic-source-index-release! (&mut first))
                false)]
            [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
              (begin
                (sem.compiler-semantic-source-index-release! (&mut first))
                false)]))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-canonical-shift-ok?) : bool
  (let
    [path : String "src/tests/semantic_canonical_shift.tl"]
    [first-source : String
      "(module semantic.canonical.shift)
(define steady : i64 1)"]
    [second-source : String
      "(module semantic.canonical.shift)
;; A harmless edit moves the declaration without changing its owner.

(define steady : i64 1)"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      first-source
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (match (compiler-check-source-index-with-roots
          (owned_view.compiler-owned-shared-view path)
          second-source
          (svec.new))
          [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ second)
            (let
              [first-record : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  (compiler-semantic-source-index-find-definition
                    (& first)
                    path
                    "steady"))]
              [second-record : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& second)
                  (compiler-semantic-source-index-find-definition
                    (& second)
                    path
                    "steady"))]
              [ok : bool
                (and
                  (!=
                    first-record.span.start-byte
                    second-record.span.start-byte)
                  (compiler-semantic-source-index-records-canonical-eq?
                    (& first)
                    (& first-record)
                    (& second)
                    (& second-record)))]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut second))
                (sem.compiler-semantic-source-index-release! (&mut first))
                ok))]
          [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
            (begin
              (sem.compiler-semantic-source-index-release! (&mut partial))
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)]
          [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
            (begin
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)])]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-canonical-collision-ok?) : bool
  (let
    [path : String "src/tests/semantic_canonical_collision.tl"]
    [source : String
      "(module semantic.canonical.collision)
(define Same : i64 1)
(defenum Same (Only))
(define (left [local : i64]) : i64 local)
(define (right [local : i64]) : i64 local)"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      source
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [value-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "Same"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [type-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "Same"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [left-local-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "local"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [right-local-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "local"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [value : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& index) value-index)]
          [type-record : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& index) type-index)]
          [left-local : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& index) left-local-index)]
          [right-local : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& index) right-local-index)]
          [ok : bool
            (and
              (>= value-index 0)
              (>= type-index 0)
              (>= left-local-index 0)
              (>= right-local-index 0)
              (not
                (compiler-semantic-source-index-records-canonical-eq?
                  (& index)
                  (& value)
                  (& index)
                  (& type-record)))
              (not
                (compiler-semantic-source-index-records-canonical-eq?
                  (& index)
                  (& left-local)
                  (& index)
                  (& right-local))))]
          (begin
            (sem.compiler-semantic-source-index-release! (&mut index))
            ok))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-canonical-rename-ok?) : bool
  (let
    [path : String "src/tests/semantic_canonical_rename.tl"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      "(module semantic.canonical.rename)\n(define before : i64 1)"
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (match (compiler-check-source-index-with-roots
          (owned_view.compiler-owned-shared-view path)
          "(module semantic.canonical.rename)\n(define after : i64 1)"
          (svec.new))
          [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ second)
            (let
              [first-record : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& first)
                  (compiler-semantic-source-index-find-definition
                    (& first)
                    path
                    "before"))]
              [second-record : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& second)
                  (compiler-semantic-source-index-find-definition
                    (& second)
                    path
                    "after"))]
              [ok : bool
                (not
                  (compiler-semantic-source-index-records-canonical-eq?
                    (& first)
                    (& first-record)
                    (& second)
                    (& second-record)))]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut second))
                (sem.compiler-semantic-source-index-release! (&mut first))
                ok))]
          [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
            (begin
              (sem.compiler-semantic-source-index-release! (&mut partial))
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)]
          [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
            (begin
              (sem.compiler-semantic-source-index-release! (&mut first))
              false)])]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-semantic-index-canonical-ok?) : bool
  (and
    (compiler-check-semantic-index-canonical-cross-snapshot-ok?)
    (compiler-check-semantic-index-canonical-shift-ok?)
    (compiler-check-semantic-index-canonical-collision-ok?)
    (compiler-check-semantic-index-canonical-rename-ok?)))

(define (compiler-check-semantic-index-nominal-members-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_nominal_members.tl"]
    [source : String
      "(import semantic.index.nominal_dep as nd)
(defstruct SemanticPair (left i64) (right i64))
(defstruct OtherPair (left i64))
(defstruct SemanticOuter (inner SemanticPair))
(defenum SemanticChoice (SemanticEmpty) (SemanticFull i64))
(defenum OtherChoice (OtherEmpty) (SemanticFull String))
(define (make-full [x : i64]) : SemanticChoice (SemanticFull x))
(define (pair-sum [p : SemanticPair]) : i64
  (+ p.left p.right))
(define (nested-left [o : SemanticOuter]) : i64
  o.inner.left)
(define (set-left [p : SemanticPair]) : unit
  (set! p.left 9))
(define (dispatch-scalar [x : i64]) : i64 x)
(defdispatch dispatch-probe (scalar dispatch-scalar))
(define imported-choice : nd.ImportedChoice
  (nd.ImportedSome (nd.ImportedBox 3)))
(define (imported-value [b : nd.ImportedBox]) : i64 b.value)
(define (imported-probe [c : nd.ImportedChoice]) : i64
  (match c
    [nd.ImportedNone 0]
    [(nd.ImportedSome item) item.value]))
(define (probe [c : SemanticChoice]) : i64
  (match c
    [SemanticEmpty 0]
    [(SemanticFull item) item]))
(define (probe-other [c : OtherChoice]) : i64
  (match c
    [OtherEmpty 0]
    [(SemanticFull item) 1]))"]
    [imported-path : String "src/tests/semantic/index/nominal_dep.tl"]
    [build-start : i64 (compiler-semantic-index-smoke-timing-start)]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [build-timing-ok : bool
            (compiler-semantic-index-smoke-timing-record
              "semantic-nominal-build"
              build-start
              0)]
          [selection-start : i64 (compiler-semantic-index-smoke-timing-start)]
          [left-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "left"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [other-left-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "left"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [right-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "right"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [full-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "SemanticFull"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [other-full-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "SemanticFull"
              sem.CompilerSemanticRecordRole.Definition
              1)]
          [left-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "left"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [right-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "right"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [full-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "SemanticFull"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [other-full-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "SemanticFull"
              sem.CompilerSemanticRecordRole.Use
              2)]
          [pair-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "SemanticPair"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [left-write-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "left"
              sem.CompilerSemanticRecordRole.Use
              2)]
          [dispatch-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "dispatch-scalar"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [dispatch-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "dispatch-scalar"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [alias-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "nd"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [alias-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "nd"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [imported-box-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              imported-path
              "ImportedBox"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [imported-box-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ImportedBox"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [imported-choice-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              imported-path
              "ImportedChoice"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [imported-choice-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ImportedChoice"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [imported-some-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              imported-path
              "ImportedSome"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [imported-some-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ImportedSome"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [imported-some-pattern-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ImportedSome"
              sem.CompilerSemanticRecordRole.Use
              1)]
          [imported-none-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              imported-path
              "ImportedNone"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [imported-none-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "ImportedNone"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [imported-field-def-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              imported-path
              "value"
              sem.CompilerSemanticRecordRole.Definition
              0)]
          [imported-field-use-i : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "value"
              sem.CompilerSemanticRecordRole.Use
              0)]
          [selection-timing-ok : bool
            (compiler-semantic-index-smoke-timing-record
              "semantic-nominal-select"
              selection-start
              0)]
          (if (or
            (< left-def-i 0)
            (< other-left-def-i 0)
            (< right-def-i 0)
            (< full-def-i 0)
            (< other-full-def-i 0)
            (< left-use-i 0)
            (< right-use-i 0)
            (< full-use-i 0)
            (< other-full-use-i 0)
            (< pair-use-i 0)
            (< left-write-i 0)
            (< dispatch-def-i 0)
            (< dispatch-use-i 0)
            (< alias-def-i 0)
            (< alias-use-i 0)
            (< imported-box-def-i 0)
            (< imported-box-use-i 0)
            (< imported-choice-def-i 0)
            (< imported-choice-use-i 0)
            (< imported-some-def-i 0)
            (< imported-some-use-i 0)
            (< imported-some-pattern-i 0)
            (< imported-none-def-i 0)
            (< imported-none-use-i 0)
            (< imported-field-def-i 0)
            (< imported-field-use-i 0)
            (not build-timing-ok)
            (not selection-timing-ok))
            (let
              [release-start : i64 (compiler-semantic-index-smoke-timing-start)]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut index))
                (compiler-semantic-index-smoke-timing-record
                  "semantic-nominal-release"
                  release-start
                  1)
                false))
            (let
              [assertion-start : i64
                (compiler-semantic-index-smoke-timing-start)]
              [left-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) left-def-i)]
              [other-left-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  other-left-def-i)]
              [right-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) right-def-i)]
              [full-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) full-def-i)]
              [other-full-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  other-full-def-i)]
              [left-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) left-use-i)]
              [right-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) right-use-i)]
              [full-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) full-use-i)]
              [other-full-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  other-full-use-i)]
              [pair-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) pair-use-i)]
              [left-write : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) left-write-i)]
              [dispatch-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  dispatch-def-i)]
              [dispatch-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  dispatch-use-i)]
              [alias-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) alias-def-i)]
              [alias-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get (& index) alias-use-i)]
              [imported-box-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-box-def-i)]
              [imported-box-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-box-use-i)]
              [imported-choice-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-choice-def-i)]
              [imported-choice-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-choice-use-i)]
              [imported-some-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-some-def-i)]
              [imported-some-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-some-use-i)]
              [imported-some-pattern : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-some-pattern-i)]
              [imported-none-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-none-def-i)]
              [imported-none-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-none-use-i)]
              [imported-field-def : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-field-def-i)]
              [imported-field-use : sem.CompilerSemanticRecord
                (sem.compiler-semantic-source-index-get
                  (& index)
                  imported-field-use-i)]
              [ok : bool
                (and
                  (compiler-check-semantic-index-record-ok?
                    source
                    left-def
                    "left"
                    sem.CompilerSemanticSymbolKind.Field)
                  (compiler-check-semantic-index-record-ok?
                    source
                    right-def
                    "right"
                    sem.CompilerSemanticSymbolKind.Field)
                  (compiler-check-semantic-index-record-ok?
                    source
                    full-def
                    "SemanticFull"
                    sem.CompilerSemanticSymbolKind.EnumMember)
                  (compiler-check-semantic-index-record-ok?
                    source
                    pair-use
                    "SemanticPair"
                    sem.CompilerSemanticSymbolKind.Struct)
                  (compiler-check-semantic-index-record-ok?
                    source
                    left-write
                    "left"
                    sem.CompilerSemanticSymbolKind.Field)
                  (match left-write.access
                    [(sem.CompilerSemanticAccess.Write) true]
                    [_ false])
                  (compiler-check-semantic-index-record-ok?
                    source
                    dispatch-use
                    "dispatch-scalar"
                    sem.CompilerSemanticSymbolKind.Function)
                  (compiler-check-semantic-index-record-ok?
                    source
                    alias-def
                    "nd"
                    sem.CompilerSemanticSymbolKind.Module)
                  (compiler-check-semantic-index-record-ok?
                    source
                    alias-use
                    "nd"
                    sem.CompilerSemanticSymbolKind.Module)
                  (compiler-check-semantic-index-record-ok?
                    source
                    imported-box-use
                    "ImportedBox"
                    sem.CompilerSemanticSymbolKind.Struct)
                  (compiler-check-semantic-index-record-ok?
                    source
                    imported-choice-use
                    "ImportedChoice"
                    sem.CompilerSemanticSymbolKind.Enum)
                  (compiler-check-semantic-index-record-ok?
                    source
                    imported-some-use
                    "ImportedSome"
                    sem.CompilerSemanticSymbolKind.EnumMember)
                  (compiler-check-semantic-index-record-ok?
                    source
                    imported-some-pattern
                    "ImportedSome"
                    sem.CompilerSemanticSymbolKind.EnumMember)
                  (compiler-check-semantic-index-record-ok?
                    source
                    imported-none-use
                    "ImportedNone"
                    sem.CompilerSemanticSymbolKind.EnumMember)
                  (compiler-check-semantic-index-record-ok?
                    source
                    imported-field-use
                    "value"
                    sem.CompilerSemanticSymbolKind.Field)
                  (sem.compiler-semantic-symbol-id-eq?
                    left-def.symbol
                    left-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    right-def.symbol
                    right-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    full-def.symbol
                    full-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    other-full-def.symbol
                    other-full-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    left-def.symbol
                    left-write.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    dispatch-def.symbol
                    dispatch-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    alias-def.symbol
                    alias-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    imported-box-def.symbol
                    imported-box-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    imported-choice-def.symbol
                    imported-choice-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    imported-some-def.symbol
                    imported-some-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    imported-some-def.symbol
                    imported-some-pattern.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    imported-none-def.symbol
                    imported-none-use.symbol)
                  (sem.compiler-semantic-symbol-id-eq?
                    imported-field-def.symbol
                    imported-field-use.symbol)
                  (not
                    (sem.compiler-semantic-symbol-id-eq?
                      left-def.symbol
                      other-left-def.symbol))
                  (not
                    (sem.compiler-semantic-symbol-id-eq?
                      full-def.symbol
                      other-full-def.symbol)))]
              [assertion-timing-ok : bool
                (compiler-semantic-index-smoke-timing-record
                  "semantic-nominal-assert"
                  assertion-start
                  (if ok
                    0
                    1))]
              [release-start : i64 (compiler-semantic-index-smoke-timing-start)]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut index))
                (let
                  [release-timing-ok : bool
                    (compiler-semantic-index-smoke-timing-record
                      "semantic-nominal-release"
                      release-start
                      0)]
                  (and
                    ok
                    assertion-timing-ok
                    release-timing-ok
                    (= (sem.compiler-semantic-source-index-len (& index)) 0)))))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (compiler-semantic-index-smoke-timing-record
            "semantic-nominal-build"
            build-start
            1)
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _)
        (begin
          (compiler-semantic-index-smoke-timing-record
            "semantic-nominal-build"
            build-start
            1)
          false)])))

(define (compiler-check-semantic-index-exact-top-candidate-storage-ok?) : bool
  (let
    [owners-before : i64 (compiler-semantic-source-index-live-owner-count)]
    [path : String "src/tests/semantic_index_sparse_candidates.tl"]
    [source : String
      "(module semantic.index.sparse.entry)
(import semantic.index.sparse.m00)
(import semantic.index.sparse.m01)
(import semantic.index.sparse.m02)
(import semantic.index.sparse.m03)
(import semantic.index.sparse.m04)
(import semantic.index.sparse.m05)
(import semantic.index.sparse.m06)
(import semantic.index.sparse.m07)
(import semantic.index.sparse.m08)
(import semantic.index.sparse.m09)
(import semantic.index.sparse.m10)
(import semantic.index.sparse.m11)
(define sparse-value-00 : i64 (m00.sparse-candidate 0))
(define sparse-value-01 : i64 (m01.sparse-candidate 1))
(define sparse-value-02 : i64 (m02.sparse-candidate 2))
(define sparse-value-03 : i64 (m03.sparse-candidate 3))
(define sparse-value-04 : i64 (m04.sparse-candidate 4))
(define sparse-value-05 : i64 (m05.sparse-candidate 5))
(define sparse-value-06 : i64 (m06.sparse-candidate 6))
(define sparse-value-07 : i64 (m07.sparse-candidate 7))
(define sparse-value-08 : i64 (m08.sparse-candidate 8))
(define sparse-value-09 : i64 (m09.sparse-candidate 9))
(define sparse-value-10 : i64 (m10.sparse-candidate 10))
(define sparse-value-11 : i64 (m11.sparse-candidate 11))"]
    (match (compiler-check-source-index-with-roots path source (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [candidate-index : i64 0]
          [sparse-macro-count : i64 0]
          (begin
            (while (< candidate-index index.top-candidate-len)
              (begin
                (if (string.eq
                  (array-ref index.top-labels candidate-index)
                  "sparse-candidate")
                  (set! sparse-macro-count (+ sparse-macro-count 1))
                  unit)
                (set! candidate-index (+ candidate-index 1))))
            (let
              [ok : bool
                (and
                  (>= index.module-len 12)
                  (= sparse-macro-count 12)
                  (< sparse-macro-count (* 12 index.module-len))
                  (=
                    (array-length index.top-candidates)
                    index.top-candidate-len)
                  (= (array-length index.top-labels) index.top-candidate-len)
                  (=
                    (array-length index.top-visible-bindings)
                    index.top-candidate-len))]
              (begin
                (sem.compiler-semantic-source-index-release! (&mut index))
                (and
                  ok
                  (=
                    (compiler-semantic-source-index-live-owner-count)
                    owners-before))))))]
      [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (sem.compiler-semantic-source-index-release! (&mut partial))
          false)]
      [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])))

;; Rechecking the same source under alternating cfg inputs must invalidate the
;; typecheck prefix and preserve the editor's complete semantic result.
(define (compiler-check-semantic-index-generated-cfg-one-ok? [enabled : bool]) : bool
  (let
    [cfgs : sym_i64_env.SymI64Env
      (if enabled
        (cfg_core.compiler-cfg-enable
          (check_core.compiler-check-language-cfgs)
          "semantic-feature")
        (check_core.compiler-check-language-cfgs))]
    [source : String
      "(defmacro (emit-configured) : Decls
  (let [head : Expr (expr-var \"cfg\")]
    `(begin
      (,head semantic-feature (define (enabled-answer) : i64 42))
      (,head (not semantic-feature) (define (disabled-answer) : i64 42)))))
(emit-configured)
(define (main) : i64
  (cfg semantic-feature (enabled-answer) (disabled-answer)))"]
    [owners-before : i64 (compiler-semantic-source-index-live-owner-count)]
    [complete : bool
      (match (sem.compiler-check-source-index-with-roots-and-cfg
        "src/tests/generated_cfg_semantic.tl"
        source
        (svec.new)
        cfgs)
        [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
          (begin
            (sem.compiler-semantic-source-index-release! (&mut index))
            true)]
        [(sem.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
          (begin
            (sem.compiler-semantic-source-index-release! (&mut partial))
            false)]
        [(sem.ResultCompilerCheckWithSemanticIndex.Err _) false])]
    (and
      complete
      (= owners-before (compiler-semantic-source-index-live-owner-count)))))

(define (compiler-check-semantic-index-generated-cfg-ok?) : bool
  (begin
    (unless
      (compiler-check-semantic-index-generated-cfg-one-ok? true)
      (io.panic "semantic-index: enabled generated cfg failed"))
    (unless
      (compiler-check-semantic-index-generated-cfg-one-ok? false)
      (io.panic "semantic-index: disabled generated cfg failed"))
    (unless
      (compiler-check-semantic-index-generated-cfg-one-ok? true)
      (io.panic "semantic-index: repeated generated cfg failed"))
    true))

;; A binder from a match pattern is in scope through every form of a
;; multi-form arm body: the use in the last form resolves to the pattern.
(define (compiler-check-semantic-index-multiform-arm-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_multiform_arm.tl"]
    [source : String
      "(defenum Opt (Some i64) (None))
(define (arm-use [o : Opt] [n : i64]) : i64
  (match o
    [(Some inner)
      (set! n (+ n 1))
      (+ inner n)]
    [(None) n]))"]
    (match (compiler-check-source-index-with-roots
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (svec.new))
      [(sem.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [ok : bool
            (let
              [definition-index : i64
                (compiler-semantic-source-index-find-definition
                  (& index)
                  path
                  "inner")]
              (and
                (>= definition-index 0)
                (let
                  [definition : sem.CompilerSemanticRecord
                    (sem.compiler-semantic-source-index-get
                      (& index)
                      definition-index)]
                  [use-index : i64
                    (compiler-semantic-source-index-find-record
                      (& index)
                      path
                      "inner"
                      sem.CompilerSemanticRecordRole.Use
                      definition.symbol.local-ordinal)]
                  (and
                    (>= definition.symbol.local-ordinal 0)
                    (>= use-index 0)
                    (>
                      (sem.compiler-semantic-source-index-get
                        (& index)
                        use-index).span.start-byte
                      definition.span.start-byte)))))]
          (begin
            (sem.compiler-semantic-source-index-release! (&mut index))
            ok))]
      [_ false])))

(define (compiler-check-semantic-index-ok?) : bool
  (let
    [base-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [base-ok : bool
      (and
        (compiler-check-semantic-index-base-ok?)
        (compiler-check-semantic-index-multiform-arm-ok?))]
    [base-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-base"
        base-start
        (if base-ok
          0
          1))]
    [macro-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [macro-ok : bool
      (and
        (compiler-check-semantic-index-macro-call-sites-ok?)
        (compiler-check-semantic-index-generated-cfg-ok?))]
    [macro-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-macro-call-sites"
        macro-start
        (if macro-ok
          0
          1))]
    [locals-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [locals-ok : bool
      (and
        (compiler-check-semantic-index-inferred-locals-ok?)
        (compiler-check-semantic-index-slice-pattern-locals-ok?))]
    [locals-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-inferred-locals"
        locals-start
        (if locals-ok
          0
          1))]
    [transitions-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [transitions-ok : bool
      (compiler-check-semantic-index-retained-transitions-ok?)]
    [transitions-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-retained-transitions"
        transitions-start
        (if transitions-ok
          0
          1))]
    [scopes-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [scopes-ok : bool
      (and
        (compiler-check-semantic-index-dense-scopes-ok?)
        (compiler-check-semantic-index-spmd-paired-scopes-ok?))]
    [scopes-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-dense-scopes"
        scopes-start
        (if scopes-ok
          0
          1))]
    [partial-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [partial-ok : bool (compiler-check-semantic-index-partial-ok?)]
    [partial-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-partial"
        partial-start
        (if partial-ok
          0
          1))]
    [canonical-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [canonical-ok : bool (compiler-check-semantic-index-canonical-ok?)]
    [canonical-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-canonical"
        canonical-start
        (if canonical-ok
          0
          1))]
    [nominal-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [nominal-ok : bool (compiler-check-semantic-index-nominal-members-ok?)]
    [nominal-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-nominal-members"
        nominal-start
        (if nominal-ok
          0
          1))]
    [storage-start : i64 (compiler-semantic-index-smoke-timing-start)]
    [storage-ok : bool
      (compiler-check-semantic-index-exact-top-candidate-storage-ok?)]
    [storage-timing-ok : bool
      (compiler-semantic-index-smoke-timing-record
        "semantic-exact-top-candidate-storage"
        storage-start
        (if storage-ok
          0
          1))]
    (and
      base-ok
      base-timing-ok
      macro-ok
      macro-timing-ok
      locals-ok
      locals-timing-ok
      transitions-ok
      transitions-timing-ok
      scopes-ok
      scopes-timing-ok
      partial-ok
      partial-timing-ok
      canonical-ok
      canonical-timing-ok
      nominal-ok
      nominal-timing-ok
      storage-ok
      storage-timing-ok)))