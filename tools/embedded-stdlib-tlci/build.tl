;; Build the host-native stdlib comptime image catalog from the exact embedded
;; source manifest. Macro bodies remain on the interpreted path until general
;; source-to-native comptime lowering lands; the registered identities and
;; loader/container path are production-shaped build inputs now.
(import compiler_parse_core)
(import compiler_tlci_native_producer)
(import tlci_core)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define embedded-stdlib-tlci-build-error : String
  "")
(define embedded-stdlib-tlci-source-hash : i64
  7)

(define (embedded-stdlib-tlci-build-error-shared-view) : String
  (cfg
    stage0-seed-bootstrap
    embedded-stdlib-tlci-build-error
    (unsafe
      (ptr-read (ptr-addr-of embedded-stdlib-tlci-build-error)))))

(define (embedded-stdlib-tlci-hash-text! [text : String]) : unit
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (while (< index length)
      (begin
        (set!
          embedded-stdlib-tlci-source-hash
          (%
            (+
              (* embedded-stdlib-tlci-source-hash 131)
              (cast (string.string-ref text index) : i64))
            2147483647))
        (set! index (+ index 1))))))

(define (embedded-stdlib-tlci-line-end [text : String] [start : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length text)]
    (begin
      (while (and (< index length) (!= (string.string-ref text index) '\n'))
        (set! index (+ index 1)))
      index)))

(define (embedded-stdlib-tlci-trim-cr [line : String]) : String
  (let
    [length : i64 (string.string-length line)]
    (if (and (> length 0) (= (string.string-ref line (- length 1)) '\r'))
      (string.substring line 0 (- length 1))
      line)))

(define (embedded-stdlib-tlci-module-name [suffix : String]) : String
  (let
    [length : i64 (string.string-length suffix)]
    (if (and
      (> length 3)
      (= (string.string-ref suffix (- length 3)) '.')
      (= (string.string-ref suffix (- length 2)) 't')
      (= (string.string-ref suffix (- length 1)) 'l'))
      (str_cat.str-cat "stdlib." (string.substring suffix 0 (- length 3)))
      "")))

(define (embedded-stdlib-tlci-push-name!
  [names : (&mut names svec.Vec)]
  [module : String]
  [name-id : i64]) : unit
  (let
    [name : String
      (if (= (string.string-length module) 0)
        (ci.intern-str name-id)
        (str_cat.str-cat module "/" (ci.intern-str name-id)))]
    [index : i64 0]
    [duplicate : bool false]
    (begin
      (while (and (not duplicate) (< index (svec.len names)))
        (if (string.eq (svec.get names index "") name)
          (set! duplicate true)
          (set! index (+ index 1))))
      (if duplicate
        (set!
          embedded-stdlib-tlci-build-error
          (str_cat.str-cat "duplicate stdlib macro identity: " name))
        (svec.push names name)))))

(define (embedded-stdlib-tlci-collect-decl!
  [decl : ast.AstDecl]
  [module : String]
  [names : (&mut names svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match decl
    [(ast.AstDecl.DefMacro decl-meta name params _ body)
      (begin
        (embedded-stdlib-tlci-push-name! names module name)
        (compiler_tlci_native_producer.tlci-native-macro-captures-push!
          captures
          (compiler_tlci_native_producer.TlciNativeMacroCapture
            (compiler_tlci_native_producer.embedded-stdlib-tlci-identity
              module
              name)
            params
            body)))]
    [(ast.AstDecl.Unsafe inner)
      (embedded-stdlib-tlci-collect-decl!
        (__tl-box-place inner)
        module
        names
        captures)]
    [(ast.AstDecl.ModuleBody nested body)
      (embedded-stdlib-tlci-collect-decls!
        (__tl-box-place body)
        (ci.intern-str nested)
        names
        captures)]
    [_ unit]))

(define (embedded-stdlib-tlci-collect-decls!
  [decls : ast.AstDeclList]
  [module : String]
  [names : (&mut names svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons decl rest)
      (match decl
        [(ast.AstDecl.Module next-module)
          (embedded-stdlib-tlci-collect-decls!
            rest
            (ci.intern-str next-module)
            names
            captures)]
        [_
          (begin
            (embedded-stdlib-tlci-collect-decl! decl module names captures)
            (embedded-stdlib-tlci-collect-decls! rest module names captures))])]))

(define (embedded-stdlib-tlci-collect-file!
  [root : String]
  [suffix : String]
  [names : (&mut names svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (let
    [module : String (embedded-stdlib-tlci-module-name suffix)]
    [path : String (str_cat.str-cat root "/" suffix)]
    [source : String (byte_buf.to-string (io.read-file path))]
    (if (= (string.string-length module) 0)
      (set!
        embedded-stdlib-tlci-build-error
        (str_cat.str-cat "invalid embedded stdlib module suffix: " suffix))
      (begin
        (embedded-stdlib-tlci-hash-text! suffix)
        (embedded-stdlib-tlci-hash-text! source)
        (match (compiler_parse_core.parse-ast-source source)
          [(compiler_parse_core.ResultAstProgram.Err message)
            (set!
              embedded-stdlib-tlci-build-error
              (str_cat.str-cat "cannot parse " path ": " message))]
          [(compiler_parse_core.ResultAstProgram.Ok program)
            (match program
              [(ast.AstProgram.Program decls)
                (embedded-stdlib-tlci-collect-decls!
                  (__tl-box-place decls)
                  module
                  names
                  captures)])])))))

(define (embedded-stdlib-tlci-collect-manifest!
  [manifest : String]
  [root : String]
  [start : i64]
  [names : (&mut names svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (when
    (and
      (=
        (string.string-length (embedded-stdlib-tlci-build-error-shared-view))
        0)
      (< start (string.string-length manifest)))
    (let
      [end : i64 (embedded-stdlib-tlci-line-end manifest start)]
      [line : String
        (embedded-stdlib-tlci-trim-cr
          (string.substring manifest start (- end start)))]
      [next : i64
        (if (< end (string.string-length manifest))
          (+ end 1)
          end)]
      (begin
        (when
          (> (string.string-length line) 0)
          (embedded-stdlib-tlci-collect-file! root line names captures))
        (embedded-stdlib-tlci-collect-manifest!
          manifest
          root
          next
          names
          captures)))))

(define (embedded-native-write
  [output : String]
  [build-hash : String]
  [windows-target : bool]
  [rodata : (__tl_dyn-array u8)]
  [names : (__tl_dyn-array String)]
  [captures
    : (& captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : i64
  (match (compiler_tlci_native_producer.embedded-native-emit-package
    (tlci_core.tlci-metadata-emit
      (tlci_core.tlci-make-metadata "v1" "stdlib" "0.1.0"))
    build-hash
    windows-target
    rodata
    names
    captures)
    [(compiler_tlci_native_producer.ResultProducerBytes.Err message)
      (begin
        (io.print-error (str_cat.str-cat "embedded stdlib tlci: " message "\n"))
        1)]
    [(compiler_tlci_native_producer.ResultProducerBytes.Ok bytes)
      (let
        [bytes-len : i64 (array-length bytes)]
        [contents : byte_buf.ByteBuf (byte_buf.from-array bytes)]
        (begin
          (io.write-file output (byte_buf.as-bytes (& contents)))
          (io.print-string
            (str_cat.str-cat
              "embedded stdlib tlci: wrote "
              (string.int->string bytes-len)
              " bytes for "
              (string.int->string (array-length names))
              " macro entries ("
              (string.int->string
                (array-ref
                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                  0))
              " native)\n"))
          ;; The native entry count is an upper bound on coverage: a native entry
          ;; may still route single arms back to the interpreter. Report the arm
          ;; sites separately so #5596's zero-fallback goal is measurable.
          ;; Per-shell reasons on stderr, one `identity<TAB>reason` line each, so
          ;; a family's real blocker is read out of the producer instead of
          ;; inferred from an AST histogram -- which mis-predicted the residue
          ;; twice (#5605, #5600). stdout keeps exactly the two lines the gates
          ;; match on. Refs #5596.
          (io.print-error
            (array-ref
              compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-reasons
              0))
          (io.print-string
            (str_cat.str-cat
              "embedded stdlib tlci: coverage native-entries="
              (string.int->string
                (array-ref
                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                  0))
              " shell-entries="
              (string.int->string
                (-
                  (array-length names)
                  (array-ref
                    compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                    0)))
              " partial-entries="
              (string.int->string
                (array-ref
                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-partial-count
                  0))
              " interpreted-arms="
              (string.int->string
                (array-ref
                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-interpreted-arms
                  0))
              "\n"))
          0))]))

(define (main) : i64
  (if (not (= (io.arg-count) 7))
    (begin
      (io.print-error
        "usage: build <module-manifest> <stdlib-root> <output.tlci> <linux|windows> <build-hash> <surface-rodata>\n")
      2)
    (let
      [manifest-path : String (io.arg 1)]
      [root : String (io.arg 2)]
      [output : String (io.arg 3)]
      [target : String (io.arg 4)]
      [build-hash : String (io.arg 5)]
      [rodata-path : String (io.arg 6)]
      [names : svec.Vec (svec.new)]
      [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
        (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
      (if (or (string.eq target "linux") (string.eq target "windows"))
        (let
          [rodata : (__tl_dyn-array u8)
            (byte_buf.to-array (io.read-file rodata-path))]
          (begin
            (embedded-stdlib-tlci-collect-manifest!
              (byte_buf.to-string (io.read-file manifest-path))
              root
              0
              (&mut names)
              (&mut captures))
            (if (>
              (string.string-length
                (embedded-stdlib-tlci-build-error-shared-view))
              0)
              (begin
                (io.print-error
                  (str_cat.str-cat
                    "embedded stdlib tlci: "
                    (embedded-stdlib-tlci-build-error-shared-view)
                    "\n"))
                1)
              (let
                [name-count : i64 (svec.len (& names))]
                [name-array (make-array String name-count)]
                [name-index : i64 0]
                (begin
                  (while (< name-index name-count)
                    (begin
                      (set!
                        (array-ref name-array name-index)
                        (svec.get (& names) name-index ""))
                      (set! name-index (+ name-index 1))))
                  (embedded-native-write
                    output
                    build-hash
                    (string.eq target "windows")
                    rodata
                    name-array
                    (& captures)))))))
        (begin
          (io.print-error
            (str_cat.str-cat
              "embedded stdlib tlci: invalid host target: "
              target
              "\n"))
          1)))))