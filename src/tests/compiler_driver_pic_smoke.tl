;; compiler_driver_pic_smoke.tl - Driver-level smoke for no-entry PIC images.
(import "../../stdlib/string.tl")
(import "../compiler_driver_core.tl")

(define (compiler-driver-pic-smoke-roots) : StringVec
  (string-vec-push (string-vec-push (string-vec-new) "stdlib") "../stdlib"))

(define (compiler-driver-pic-smoke-contains? [text : String] [needle : String]) : bool
  (string-contains (& text) (& needle)))

(define (compiler-driver-pic-smoke-paths-contain?
  [paths : AstDeclPathList]
  [needle : String]) : bool
  (match paths
    [(AstDeclPathNil) false]
    [(AstDeclPathCons path rest)
      (or
        (compiler-driver-pic-smoke-contains? path needle)
        (compiler-driver-pic-smoke-paths-contain? (box-get rest) needle))]))

(define (compiler-driver-pic-smoke-output-ok?
  [output : CompilerBackendPicOutput]) : bool
  (let
    [asm : String (struct-get output asm)]
    [fixups : String (struct-get output fixups)]
    (and
      (> (string-length asm) 0)
      (compiler-driver-pic-smoke-contains? asm ".L_tl_pic_image_base:\n")
      (not (compiler-driver-pic-smoke-contains? asm "_tl_start"))
      (not (compiler-driver-pic-smoke-contains? asm "main:"))
      (not (compiler-driver-pic-smoke-contains? asm ".extern"))
      (not (compiler-driver-pic-smoke-contains? asm "tl_alloc"))
      (compiler-driver-pic-smoke-contains? fixups "typelisp-pic-fixups v1\n"))))

(define (compiler-driver-pic-smoke-core-macros-path-ok?
  [target : CompilerBackendTarget]
  [input-path : String]) : bool
  (match (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    input-path
    target
    true
    (compiler-driver-pic-smoke-roots)
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty))
    [(OkCompilerDriverPic output) (compiler-driver-pic-smoke-output-ok? output)]
    [(ErrCompilerDriverPic _) false]))

(define (compiler-driver-pic-smoke-core-macros-ok?
  [target : CompilerBackendTarget]) : bool
  (or
    (compiler-driver-pic-smoke-core-macros-path-ok?
      target
      "stdlib/core_macros.tl")
    (compiler-driver-pic-smoke-core-macros-path-ok?
      target
      "../stdlib/core_macros.tl")))

(define (compiler-driver-pic-smoke-write-fixture-at?
  [path : String]
  [contents : String]) : bool
  (match (try-write-file (& path) (& contents))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (compiler-driver-pic-smoke-write-extern-fixture) : String
  (let
    [path : String "target/compiler_driver_pic_extern_fixture.tl"]
    [fallback-path : String "compiler_driver_pic_extern_fixture.tl"]
    [contents : String
      "(extern (foreign-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define (main) : i64
  (foreign-call 1))"]
    (if (compiler-driver-pic-smoke-write-fixture-at? path contents)
      path
      (begin
        (write-file fallback-path contents)
        fallback-path))))

(define (compiler-driver-pic-smoke-extern-reject-ok?) : bool
  (match (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    (compiler-driver-pic-smoke-write-extern-fixture)
    (BackendTargetWindows)
    true
    (compiler-driver-pic-smoke-roots)
    (compiler-optimize-default-level)
    (BackendModeScalar)
    (compiler-cfg-empty))
    [(OkCompilerDriverPic _) false]
    [(ErrCompilerDriverPic diag)
      (compiler-driver-pic-smoke-contains?
        (compiler-diagnostic-render diag)
        "backend: --pic supports only internal references")]))

(define (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?) : bool
  (match (compiler-driver-load-runtime-prelude-cold
    (compiler-driver-pic-smoke-roots)
    (compiler-cfg-enable (compiler-cfg-empty) "__typelisp_pic_image"))
    [(OkCompilerLoadWithPaths _ paths _ _)
      (compiler-driver-pic-smoke-paths-contain? paths "stdlib/runtime.tl")]
    [(ErrCompilerLoadWithPaths _) false]))

(define (main) : i64
  (begin
    (unless
      (compiler-driver-pic-smoke-core-macros-ok? (BackendTargetLinux))
      (return 1))
    (unless
      (compiler-driver-pic-smoke-core-macros-ok? (BackendTargetWindows))
      (return 2))
    (unless (compiler-driver-pic-smoke-extern-reject-ok?) (return 3))
    (unless
      (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?)
      (return 4))
    42))