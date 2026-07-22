;; Build the host-native stdlib comptime image catalog from the exact embedded
;; source manifest. Macro bodies remain on the interpreted path until general
;; source-to-native comptime lowering lands; the registered identities and
;; loader/container path are production-shaped build inputs now.
(import "../../src/compiler_parse_core.tl")
(import "../../src/compiler_tlci_native_producer.tl")
(import "../../src/tlci_core.tl")
(import "../../src/compiler_backend.tl")
(import "../../src/compiler_tlci_native_image.tl")
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define embedded-stdlib-tlci-build-error : String
  "")
(define embedded-stdlib-tlci-source-hash : i64
  7)

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
      (str-cat "stdlib." (string.substring suffix 0 (- length 3)))
      "")))

(define (embedded-stdlib-tlci-push-name!
  [names : (&mut names svec.Vec)]
  [module : String]
  [name-id : i64]) : unit
  (let
    [name : String
      (if (= (string.string-length module) 0)
        (intern-str name-id)
        (str-cat module "/" (intern-str name-id)))]
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
          (str-cat "duplicate stdlib macro identity: " name))
        (svec.push names name)))))

(define (embedded-stdlib-tlci-collect-decl!
  [decl : AstDecl]
  [module : String]
  [names : (&mut names svec.Vec)]) : unit
  (match decl
    [(AstDecl.DefMacro decl-meta name params _ body)
      (begin
        (embedded-stdlib-tlci-push-name! names module name)
        (let
          [slot : i64 (array-ref embedded-stdlib-tlci-capture-count 0)]
          (when
            (< slot embedded-stdlib-tlci-capture-cap)
            (array-set!
              embedded-stdlib-tlci-capture-identities
              slot
              (embedded-stdlib-tlci-identity module name))
            (array-set! embedded-stdlib-tlci-capture-params slot params)
            (array-set! embedded-stdlib-tlci-capture-bodies slot body)
            (array-set! embedded-stdlib-tlci-capture-count 0 (+ slot 1)))))]
    [(AstDecl.Unsafe inner)
      (embedded-stdlib-tlci-collect-decl! (box-get inner) module names)]
    [(AstDecl.ModuleBody nested body)
      (embedded-stdlib-tlci-collect-decls!
        (box-get body)
        (intern-str nested)
        names)]
    [_ unit]))

(define (embedded-stdlib-tlci-collect-decls!
  [decls : AstDeclList]
  [module : String]
  [names : (&mut names svec.Vec)]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.Module next-module)
          (embedded-stdlib-tlci-collect-decls!
            rest
            (intern-str next-module)
            names)]
        [_
          (begin
            (embedded-stdlib-tlci-collect-decl! decl module names)
            (embedded-stdlib-tlci-collect-decls! rest module names))])]))

(define (embedded-stdlib-tlci-collect-file!
  [root : String]
  [suffix : String]
  [names : (&mut names svec.Vec)]) : unit
  (let
    [module : String (embedded-stdlib-tlci-module-name suffix)]
    [path : String (str-cat root "/" suffix)]
    [source : String (io.read-file path)]
    (if (= (string.string-length module) 0)
      (set!
        embedded-stdlib-tlci-build-error
        (str-cat "invalid embedded stdlib module suffix: " suffix))
      (begin
        (embedded-stdlib-tlci-hash-text! suffix)
        (embedded-stdlib-tlci-hash-text! source)
        (match (parse-ast-source source)
          [(ResultAstProgram.Err message)
            (set!
              embedded-stdlib-tlci-build-error
              (str-cat "cannot parse " path ": " message))]
          [(ResultAstProgram.Ok program)
            (match program
              [(AstProgram.Program decls)
                (embedded-stdlib-tlci-collect-decls!
                  (box-get decls)
                  module
                  names)])])))))

(define (embedded-stdlib-tlci-collect-manifest!
  [manifest : String]
  [root : String]
  [start : i64]
  [names : (&mut names svec.Vec)]) : unit
  (when
    (and
      (= (string.string-length embedded-stdlib-tlci-build-error) 0)
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
          (embedded-stdlib-tlci-collect-file! root line names))
        (embedded-stdlib-tlci-collect-manifest! manifest root next names)))))

(define (embedded-native-write
  [output : String]
  [build-hash : String]
  [windows-target : bool]
  [rodata : (Array u8)]
  [names : (Array String)]) : i64
  (match (embedded-native-emit-package
    (tlci-metadata-emit (tlci-make-metadata "v1" "stdlib" "0.1.0"))
    build-hash
    windows-target
    rodata
    names)
    [(ResultProducerBytes.Err message)
      (begin
        (io.print-error (str-cat "embedded stdlib tlci: " message "\n"))
        1)]
    [(ResultProducerBytes.Ok bytes)
      (begin
        (io.write-file output (tlci-bytes->string bytes 0 (array-length bytes)))
        (io.print-string
          (str-cat
            "embedded stdlib tlci: wrote "
            (string.int->string (array-length bytes))
            " bytes for "
            (string.int->string (array-length names))
            " macro entries ("
            (string.int->string
              (array-ref embedded-stdlib-tlci-native-report-count 0))
            " native)\n"))
        0)]))

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
      (if (or (string.eq target "linux") (string.eq target "windows"))
        (let
          [rodata : (Array u8) (tlci-string->bytes (io.read-file rodata-path))]
          (begin
            (embedded-stdlib-tlci-collect-manifest!
              (io.read-file manifest-path)
              root
              0
              (&mut names))
            (if (> (string.string-length embedded-stdlib-tlci-build-error) 0)
              (begin
                (io.print-error
                  (str-cat
                    "embedded stdlib tlci: "
                    embedded-stdlib-tlci-build-error
                    "\n"))
                1)
              (embedded-native-write
                output
                build-hash
                (string.eq target "windows")
                rodata
                (svec.to-array (& names))))))
        (begin
          (io.print-error
            (str-cat "embedded stdlib tlci: invalid host target: " target "\n"))
          1)))))