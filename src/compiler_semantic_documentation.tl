;; Documentation facts copied from an owned checked source index. Registry
;; handles are used only through its identity API, never as URL components.
(import compiler_semantic_index as semantic)
(import compiler_owned_view as owned_view)
(import compiler_ast_types as ast)
(import doc_extract)
(import stdlib.iterator)
(import stdlib.string)

(defstruct SemanticDocumentation
  (module String)
  (source-path String)
  (source-sha256 String)
  (identity doc_extract.DocIdentity)
  (definition-index i64)
  (source-line i64))

(defenum MaybeSemanticDocumentation
  (Some SemanticDocumentation)
  (None))

(define (documentation-kind [kind : semantic.CompilerSemanticSymbolKind]) : doc_extract.DocItemKind
  (match kind
    [(Function) Function]
    [(Macro) DefMacro]
    [(or (ExternValue) (ExternFunction)) Extern]
    [(Struct) DefStruct]
    [(Enum) DefEnum]
    [(Module) ImportAlias]
    [(Field) Field]
    [(EnumMember) EnumVariant]
    [_ Define]))

(define (documentation-origin [origin : semantic.CompilerSemanticProvenance]) : doc_extract.DocOrigin
  (match origin
    [(EditableSource) Source]
    [(Generated generator item key)
      (Generated
        (string.copy (& generator))
        (string.copy (& item))
        (string.copy (& key)))]))

(define (documentation-definition-index
  [index : (& index semantic.CompilerSemanticSourceIndex)]
  [cursor : semantic.CompilerSemanticRecord]) : i64
  ;; Module aliases share the target module's symbol identity. Prefer the
  ;; actual alias in this source rather than a same-target alias elsewhere.
  (match cursor.kind
    [(Module)
      (for [i (iterator.range 0 index.len)]
        (let
          [record : semantic.CompilerSemanticRecord
            (semantic.compiler-semantic-source-index-get index i)]
          (when
            (and
              (match record.role
                [(Definition) true]
                [_ false])
              (match record.kind
                [(Module) true]
                [_ false])
              (semantic.compiler-semantic-symbol-id-eq?
                record.symbol
                cursor.symbol)
              (string.eq record.span.path cursor.span.path)
              (string.eq record.display-name cursor.display-name))
            (return i))))
      -1]
    [_
      (semantic.compiler-semantic-source-index-find-symbol-role
        index
        cursor.symbol
        Definition)]))

(define (documentation-at
  [index : (& index semantic.CompilerSemanticSourceIndex)]
  [record-index : i64]) : MaybeSemanticDocumentation
  (when
    (or
      (<= index.owner-arena 0)
      (not (semantic.compiler-semantic-source-index-complete? index))
      (< record-index 0)
      (>= record-index index.len))
    (return None))
  (let
    [cursor : semantic.CompilerSemanticRecord
      (semantic.compiler-semantic-source-index-get index record-index)]
    [definition-index : i64
      (match cursor.role
        [(Definition) record-index]
        [_ (documentation-definition-index index cursor)])]
    (when (< definition-index 0) (return None))
    (let
      [definition : semantic.CompilerSemanticRecord
        (semantic.compiler-semantic-source-index-get index definition-index)]
      [kind : semantic.CompilerSemanticSymbolKind definition.kind]
      [parent : String ""]
      (when
        (or
          (>= definition.symbol.local-ordinal 0)
          (match kind
            [(or (Local) (Parameter)) true]
            [_ false]))
        (return None))
      (match (owned_view.compiler-owned-shared-view definition.provenance)
        [(EditableSource)
          (when
            (or
              (< definition.span.start-byte 0)
              (<= definition.span.end-byte definition.span.start-byte))
            (return None))]
        [(Generated _ _ _) unit])
      (when
        (match kind
          [(or (Field) (EnumMember)) true]
          [_ false])
        (for [i (iterator.range 0 index.len)]
          (let
            [owner : semantic.CompilerSemanticRecord
              (semantic.compiler-semantic-source-index-get index i)]
            (when
              (and
                (match owner.role
                  [(Definition) true]
                  [_ false])
                (match kind
                  [(Field)
                    (match owner.kind
                      [(Struct) true]
                      [_ false])]
                  [_
                    (match owner.kind
                      [(Enum) true]
                      [_ false])])
                (semantic.compiler-semantic-member-symbol-owned-by?
                  (& owner.symbol)
                  (& definition.symbol)))
              (set! parent (string.copy (& owner.display-name)))
              (break))))
        (when (string.eq parent "") (return None)))
      (let
        [range-index : i64 (documentation-range-index index definition-index)]
        [path-index : i64
          (semantic.compiler-semantic-path-index-find
            (& index.paths)
            index.path-len
            (string.copy (& definition.span.path)))]
        (when (or (< range-index 0) (< path-index 0)) (return None))
        (let
          [range : (& index semantic.CompilerSemanticDocumentationModule)
            (& (array-ref index.documentation-modules range-index))]
          [path : semantic.CompilerSemanticSourcePathInfo
            (owned_view.compiler-owned-array-element-shared-view
              index.paths
              path-index)]
          [module : semantic.CompilerSemanticModuleInfo
            (owned_view.compiler-owned-array-element-shared-view
              index.modules
              range.module-index)]
          ;; A source module marker has a page identity, not an import-alias
          ;; declaration. Never invent an alias item for that marker.
          (when
            (and
              (not range.import)
              (match kind
                [(Module) true]
                [_ false]))
            (return None))
          (when (string.eq path.source-sha256 "") (return None))
          (Some
            (SemanticDocumentation
              (string.copy (& module.name))
              (string.copy (& path.path))
              (string.copy (& path.source-sha256))
              (doc_extract.DocIdentity
                (if range.import
                  ImportAlias
                  (documentation-kind kind))
                (if (and range.import (not (string.eq range.alias "")))
                  (string.copy (& range.alias))
                  (string.copy (& definition.display-name)))
                parent
                (documentation-origin
                  (owned_view.compiler-owned-shared-view definition.provenance)))
              definition-index
              (match definition.provenance
                [(EditableSource)
                  (cast
                    (ast.ast-source-span-start-line definition.span.source)
                    : i64)]
                [(Generated _ _ _) 0]))))))))

(define (documentation-range-index
  [index : (& index semantic.CompilerSemanticSourceIndex)]
  [record-index : i64]) : i64
  (when
    (or (<= index.owner-arena 0) (< record-index 0) (>= record-index index.len))
    (return -1))
  (let
    [low : i64 0]
    [high : i64 (array-length index.documentation-modules)]
    (while (< low high)
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        (if (<=
          (array-ref index.documentation-modules middle).record-start
          record-index)
          (set! low (+ middle 1))
          (set! high middle))))
    (when (= low 0) (return -1))
    (let
      [range : (& index semantic.CompilerSemanticDocumentationModule)
        (& (array-ref index.documentation-modules (- low 1)))]
      (if (and
        (>= record-index range.record-start)
        (< record-index range.record-end)
        (>= range.module-index 0)
        (< range.module-index index.module-len))
        (- low 1)
        -1))))