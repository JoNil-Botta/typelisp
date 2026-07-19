;; Build the host-native stdlib comptime image catalog from the exact embedded
;; source manifest. Macro bodies remain on the interpreted path until general
;; source-to-native comptime lowering lands; the registered identities and
;; loader/container path are production-shaped build inputs now.
(import "../../src/compiler_parse_core.tl")
(import "../../src/tlci_core.tl")
(import compiler_comptime_image_core as comptime_image)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector String) as svec)

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

(define (embedded-stdlib-tlci-identity [module : String] [name-id : i64]) : String
  (if (= (string.string-length module) 0)
    (intern-str name-id)
    (str-cat module "/" (intern-str name-id))))

;; The one macro whose checked source body is compiled to a native entry in
;; this slice; every other catalog identity stays a registration shell with
;; the counted interpreted fallback. Refs #5212.
(define embedded-stdlib-tlci-native-name : String
  "stdlib.array/length")
(define embedded-stdlib-tlci-native-found : (Array i64)
  (make-array 0))
(define embedded-stdlib-tlci-native-params : (Array AstMacroParamList)
  (array.make-array AstMacroParamList 1))
(define embedded-stdlib-tlci-native-body : (Array i64)
  (make-array 0))

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
        (when
          (string.eq
            (embedded-stdlib-tlci-identity module name)
            embedded-stdlib-tlci-native-name)
          (array-set! embedded-stdlib-tlci-native-found 0 1)
          (array-set! embedded-stdlib-tlci-native-params 0 params)
          (array-set! embedded-stdlib-tlci-native-body 0 body)))]
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

(define (embedded-stdlib-tlci-unwrap-expr [node : i64]) : AstExpr
  (match (ast-node-get node)
    [(AstExpr.Spanned inner _) (embedded-stdlib-tlci-unwrap-expr inner)]
    [_ (ast-node-get node)]))

(define (embedded-stdlib-tlci-param-index
  [params : (& params AstMacroParamList)]
  [name-id : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index (struct-get params len)))
        (begin
          (match (array-ref (struct-get params slots) index)
            [(AstMacroParam.Param pname _ _ _)
              (if (= pname name-id)
                (set! found index)
                unit)])
          (set! index (+ index 1))))
      found)))

(define (embedded-stdlib-tlci-body-fail [reason : String]) : bool
  (begin
    (set!
      embedded-stdlib-tlci-build-error
      (str-cat
        "native body for "
        embedded-stdlib-tlci-native-name
        " is unsupported: "
        reason))
    false))

;; Compile the splice-only quasiquote subset: the body must be a quasiquoted
;; call form whose head is a plain name and whose arguments are unquoted
;; macro parameters. Anything else fails the image build with a diagnostic
;; naming the construct, keeping the producer honest about coverage.
(define (embedded-stdlib-tlci-compile-native-program
  [out : (&mut out (Array comptime_image.CompilerComptimeMacroProgram))]
  [slot : i64]) : bool
  (let
    [params : AstMacroParamList
      (array-ref embedded-stdlib-tlci-native-params 0)]
    [body-node : i64 (array-ref embedded-stdlib-tlci-native-body 0)]
    (match (embedded-stdlib-tlci-unwrap-expr body-node)
      [(AstExpr.Quasiquote quoted)
        (match (embedded-stdlib-tlci-unwrap-expr quoted)
          [(AstExpr.Call func-id args)
            (match (embedded-stdlib-tlci-unwrap-expr func-id)
              [(AstExpr.Var head-id)
                (let
                  [argc : i64 (ast-expr-list-len (& args))]
                  [ops : (Array comptime_image.CompilerComptimeOperation)
                    (array.make-array
                      comptime_image.CompilerComptimeOperation
                      (+ 4 (* argc 2)))]
                  [names : (Array String) (array.make-array String 1)]
                  [index : i64 0]
                  [ok : bool true]
                  (begin
                    (array-set! names 0 (intern-str head-id))
                    (array-set!
                      ops
                      0
                      (comptime_image.CompilerComptimeOperation.HostCallName
                        tlci-host-callback-op-expr-var
                        0))
                    (array-set!
                      ops
                      1
                      (comptime_image.CompilerComptimeOperation.HostCall
                        tlci-host-callback-op-expr-list-empty))
                    (while (and ok (< index argc))
                      (match (embedded-stdlib-tlci-unwrap-expr
                        (ast-expr-list-get (& args) index 0))
                        [(AstExpr.Unquote unquoted)
                          (match (embedded-stdlib-tlci-unwrap-expr unquoted)
                            [(AstExpr.Var pname)
                              (let
                                [param : i64
                                  (embedded-stdlib-tlci-param-index
                                    (& params)
                                    pname)]
                                (if (< param 0)
                                  (set!
                                    ok
                                    (embedded-stdlib-tlci-body-fail
                                      "unquote references a non-parameter"))
                                  (begin
                                    (array-set!
                                      ops
                                      (+ 2 (* index 2))
                                      (comptime_image.CompilerComptimeOperation.HostCallArgs
                                        tlci-host-callback-op-push-operand
                                        param
                                        0
                                        0))
                                    (array-set!
                                      ops
                                      (+ 3 (* index 2))
                                      (comptime_image.CompilerComptimeOperation.HostCall
                                        tlci-host-callback-op-expr-list-append))
                                    (set! index (+ index 1)))))]
                            [_
                              (set!
                                ok
                                (embedded-stdlib-tlci-body-fail
                                  "unquote payload is not a parameter name"))])]
                        [_
                          (set!
                            ok
                            (embedded-stdlib-tlci-body-fail
                              "argument is not an unquoted parameter"))]))
                    (when
                      ok
                      (array-set!
                        ops
                        (+ 2 (* argc 2))
                        (comptime_image.CompilerComptimeOperation.HostCall
                          tlci-host-callback-op-expr-call))
                      (array-set!
                        ops
                        (+ 3 (* argc 2))
                        (comptime_image.CompilerComptimeOperation.HostCall
                          tlci-host-callback-op-commit-result))
                      (array-set!
                        out
                        slot
                        (comptime_image.CompilerComptimeMacroProgram
                          embedded-stdlib-tlci-native-name
                          ops
                          names
                          0
                          0)))
                    ok))]
              [_ (embedded-stdlib-tlci-body-fail "call head is not a name")])]
          [_ (embedded-stdlib-tlci-body-fail "quasiquote is not a call form")])]
      [_ (embedded-stdlib-tlci-body-fail "body is not a quasiquote")])))

(define (embedded-stdlib-tlci-programs [names : (Array String)]) : (Array
    comptime_image.CompilerComptimeMacroProgram)
  (let
    [count : i64 (array-length names)]
    [programs : (Array comptime_image.CompilerComptimeMacroProgram)
      (array.make-array comptime_image.CompilerComptimeMacroProgram count)]
    [index : i64 0]
    [native-count : i64 0]
    (begin
      (while (and
        (= (string.string-length embedded-stdlib-tlci-build-error) 0)
        (< index count))
        (let
          [name : String (array-ref names index)]
          (begin
            (if (string.eq name embedded-stdlib-tlci-native-name)
              (if (= (array-ref embedded-stdlib-tlci-native-found 0) 1)
                (begin
                  (if (embedded-stdlib-tlci-compile-native-program
                    (&mut programs)
                    index)
                    (set! native-count (+ native-count 1))
                    unit)
                  unit)
                (set!
                  embedded-stdlib-tlci-build-error
                  (str-cat
                    "native macro source not captured: "
                    embedded-stdlib-tlci-native-name)))
              (array-set!
                programs
                index
                (comptime_image.compiler-comptime-registration-shell-program
                  name)))
            (set! index (+ index 1)))))
      (when
        (and
          (= (string.string-length embedded-stdlib-tlci-build-error) 0)
          (= native-count 0))
        (set!
          embedded-stdlib-tlci-build-error
          (str-cat
            "native macro identity missing from catalog: "
            embedded-stdlib-tlci-native-name)))
      programs)))

(define (embedded-stdlib-tlci-write
  [output : String]
  [build-hash : String]
  [windows-target : bool]
  [names : (Array String)]) : i64
  (let
    [programs : (Array comptime_image.CompilerComptimeMacroProgram)
      (embedded-stdlib-tlci-programs names)]
    (if (> (string.string-length embedded-stdlib-tlci-build-error) 0)
      (begin
        (io.print-error
          (str-cat
            "embedded stdlib tlci: "
            embedded-stdlib-tlci-build-error
            "\n"))
        1)
      (match (tlci-emit-code-bearing-package-image-from-programs
        (tlci-make-metadata "v1" "stdlib" "0.1.0")
        build-hash
        programs
        windows-target)
        [(ResultTlciBytes.Err message)
          (begin
            (io.print-error (str-cat "embedded stdlib tlci: " message "\n"))
            1)]
        [(ResultTlciBytes.Ok bytes)
          (begin
            (io.write-file
              output
              (tlci-bytes->string bytes 0 (array-length bytes)))
            (io.print-string
              (str-cat
                "embedded stdlib tlci: wrote "
                (string.int->string (array-length bytes))
                " bytes for "
                (string.int->string (array-length names))
                " macro entries (1 native)\n"))
            0)]))))

(define (main) : i64
  (if (not (= (io.arg-count) 6))
    (begin
      (io.print-error
        "usage: build <module-manifest> <stdlib-root> <output.tlci> <linux|windows> <build-hash>\n")
      2)
    (let
      [manifest-path : String (io.arg 1)]
      [root : String (io.arg 2)]
      [output : String (io.arg 3)]
      [target : String (io.arg 4)]
      [build-hash : String (io.arg 5)]
      [names : svec.Vec (svec.new)]
      (begin
        (if (or (string.eq target "linux") (string.eq target "windows"))
          (embedded-stdlib-tlci-collect-manifest!
            (io.read-file manifest-path)
            root
            0
            (&mut names))
          (set!
            embedded-stdlib-tlci-build-error
            (str-cat "invalid host target: " target)))
        (if (> (string.string-length embedded-stdlib-tlci-build-error) 0)
          (begin
            (io.print-error
              (str-cat
                "embedded stdlib tlci: "
                embedded-stdlib-tlci-build-error
                "\n"))
            1)
          (embedded-stdlib-tlci-write
            output
            (str-cat
              build-hash
              "-stdlib-"
              (string.int->string embedded-stdlib-tlci-source-hash))
            (string.eq target "windows")
            (svec.to-array (& names))))))))