(import stdlib.iterator)
(import compiler_module_name as module_name)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import lsp_frame_core as lsp)
(import token)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import stdlib.test)

(defstruct NameCase
  (name String)
  (valid bool)
  (path String)
  (alias String)
  (source-token bool))

(define (assert-name [item : (& item NameCase)]) : unit
  (test.assert-bool-eq
    (module_name.compiler-module-name-valid? (& item.name))
    item.valid
    (string.copy (& item.name)))
  (test.assert-bool-eq
    (match (lsp.lsp-dotted-import-name-kind (& item.name) true)
      [(Complete) true]
      [_ false])
    item.valid
    "complete LSP name agrees with grammar")
  ;; Construct a symbol directly: the name contract accepts UTF-8 bytes even
  ;; though the source lexer has a narrower symbol alphabet.
  (match (parser.parse-ast-dotted-import-tail
    (parser.compiler-cfg-empty)
    (ci.intern-source-slice
      (& item.name)
      0
      (string.string-length (& item.name)))
    (List 0 0 (token.SourceSpan 2 3 4 5))
    (ast.ast-source-span 2 3 4 5))
    [(Ok (Import _ (Spec kind path (Some module-id) (Some alias-id) span-box)))
      (test.assert-true item.valid "parser must reject invalid names")
      (test.assert-true (string.eq (& path) (& item.path)) "owned import path")
      (test.assert-true
        (string.eq (ci.intern-str module-id) (& item.path))
        "module identity metadata")
      (test.assert-true
        (string.eq (ci.intern-str alias-id) (& item.alias))
        "default alias metadata")
      (test.assert-bool-eq
        (match kind
          [(ModuleAll) true]
          [(Module) false]
          [_
            (test.assert-true false "named import kind")
            false])
        (string.eq (& item.alias) "")
        "wildcard kind")
      (test.assert-true
        (ast.ast-source-span-eq? (deref span-box) (ast.ast-source-span 2 3 4 5))
        "import span remains intact")]
    [(Err message)
      (test.assert-true (not item.valid) "parser must accept valid names")
      (test.assert-true
        (string.eq (& message) "parse: invalid dotted import module name")
        "invalid-name diagnostic remains exact")]
    [_ (test.assert-true false "named import metadata shape")])
  (if item.source-token
    (let
      [text : String
        (str_cat.str-cat "(import " (string.copy (& item.name)) ")")]
      (test.assert-bool-eq
        (match (parser.parse-ast-source (string.copy (& text)))
          [(Ok _) true]
          [_ false])
        item.valid
        "complete source parser acceptance")
      (match (lsp.lsp-resolve-import-target-at
        (& text)
        "__7525__/main.tl"
        (svec.new)
        8)
        [(Found _ start end)
          (test.assert-true item.valid "invalid complete operand resolved")
          (test.assert-i64-eq start 8 "import operand start")
          (test.assert-i64-eq
            end
            (+ 8 (string.string-length (& item.name)))
            "complete import operand end")]
        [(Missing)
          (test.assert-true (not item.valid) "valid complete operand missing")]))
    unit))

(test
  complete-dotted-import-grammar-and-metadata-parity
  (let
    [cases : (Array NameCase 28)
      (array
        (NameCase "" false "" "" true)
        (NameCase "probe" true "probe" "probe" true)
        (NameCase "probe.math.core" true "probe.math.core" "core" true)
        (NameCase ".probe" false "" "" true)
        (NameCase "probe." false "" "" true)
        (NameCase "probe..core" false "" "" true)
        (NameCase "probe...core" false "" "" true)
        (NameCase "." false "" "" true)
        (NameCase ".." false "" "" true)
        (NameCase "probe.tl" false "" "" true)
        (NameCase "tl" true "tl" "tl" true)
        (NameCase "probe.TL" true "probe.TL" "TL" true)
        (NameCase "probe.tl.core" true "probe.tl.core" "core" true)
        (NameCase "probe/core" false "" "" true)
        (NameCase "probe\\core" false "" "" true)
        (NameCase "probe:core" false "" "" true)
        (NameCase "pkg:probe.core" false "" "" true)
        (NameCase "probe.*" true "probe" "" true)
        (NameCase "*" true "*" "*" true)
        (NameCase
          "probe._x-+?!%&<=>*"
          true
          "probe._x-+?!%&<=>*"
          "_x-+?!%&<=>*"
          true)
        (NameCase "probe.123" true "probe.123" "123" true)
        (NameCase "å.日本語" true "å.日本語" "日本語" false)
        (NameCase "😀.é" true "😀.é" "é" false)
        (NameCase "å..日本語" false "" "" false)
        (NameCase "å.tl" false "" "" false)
        (NameCase "a b" true "a b" "a b" false)
        (NameCase "a$" true "a$" "a$" false)
        (NameCase "probe.*.core" true "probe.*.core" "core" true))]
    (for [index (iterator.range 0 (array-length cases))]
      (assert-name (& (array-ref cases index))))))

(test
  dotted-import-long-name-boundary
  (let
    [name : String "probe"]
    (for [index (iterator.range 0 12)]
      (set!
        name
        (str_cat.str-cat (string.copy (& name)) (string.copy (& name)) "")))
    (let
      [item : NameCase
        (NameCase
          (string.copy (& name))
          true
          (string.copy (& name))
          (string.copy (& name))
          false)]
      (assert-name (& item)))))

(defstruct PrefixCase
  (name String)
  (prefix bool))

(test
  complete-editor-name-at-eof-and-token-boundaries
  (let
    [cases : (Array String 4)
      (array
        "(import probe"
        "(import probe)"
        "(import probe\t"
        "(import probe; comment")]
    (test.assert-true
      (match (lsp.lsp-dotted-import-name-kind "probe" false)
        [(Complete) true]
        [_ false])
      "valid name remains complete in an unfinished form")
    (for [index (iterator.range 0 (array-length cases))]
      (match (lsp.lsp-resolve-import-target-at
        (& (array-ref cases index))
        "__7525__/main.tl"
        (svec.new)
        8)
        [(Found _ start end)
          (test.assert-i64-eq start 8 "editor operand start")
          (test.assert-i64-eq end 13 "editor operand end")]
        [_ (test.assert-true false "complete editor name must resolve")]))))

(test
  incomplete-editor-prefixes-do-not-change-complete-grammar
  (let
    [cases : (Array PrefixCase 8)
      (array
        (PrefixCase "" true)
        (PrefixCase "probe." true)
        (PrefixCase "probe.tl" true)
        (PrefixCase ".probe" false)
        (PrefixCase "probe.." false)
        (PrefixCase "probe/core" false)
        (PrefixCase "probe\\core" false)
        (PrefixCase "probe:core" false))]
    (for [index (iterator.range 0 (array-length cases))]
      (let
        [item : (& cases PrefixCase) (& (array-ref cases index))]
        [text : String
          (str_cat.str-cat "(import " (string.copy (& item.name)) "")]
        (test.assert-bool-eq
          (match (lsp.lsp-dotted-import-name-kind (& item.name) false)
            [(Prefix) true]
            [_ false])
          item.prefix
          "editor prefix classification")
        (test.assert-true
          (match (lsp.lsp-dotted-import-name-kind (& item.name) true)
            [(Invalid) true]
            [_ false])
          "closed invalid name cannot be an editor prefix")
        (test.assert-true
          (match (lsp.lsp-resolve-import-target-at
            (& text)
            "__7525__/main.tl"
            (svec.new)
            8)
            [(Missing) true]
            [_ false])
          "incomplete invalid name cannot resolve a valid prefix")))))

(test
  unsupported-import-token-bytes-cannot-resolve-a-prefix
  (let
    [cases : (Array String 4)
      (array
        "(import probe\\invalid)"
        "(import probe$invalid)"
        "(import probe@invalid)"
        "(import probeé)")]
    (for [index (iterator.range 0 (array-length cases))]
      (let
        [text : (& cases str) (& (array-ref cases index))]
        (test.assert-true
          (match (lsp.lsp-resolve-import-target-at
            text
            "__7525__/main.tl"
            (svec.new)
            8)
            [(Missing) true]
            [_ false])
          "unsupported byte cannot delimit a valid import prefix")))))