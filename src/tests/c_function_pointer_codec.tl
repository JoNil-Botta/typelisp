(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_surface_ast_codec_core as codec)
(import stdlib.test)

(define (c-function-codec-session) : cis.InternStructuralSessionHandle
  (let
    [interns : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    (cis.intern-structural-session-handle-from-source-names
      (ci.intern-source-name-session-handle-from-state interns))))

(define (c-function-codec-bytes
  [signature : i64]
  [mode : i64]
  [complete : bool]) : (__tl_dyn-array u8)
  (let
    [bytes : (__tl_dyn-array u8)
      (__tl_make-array
        u8
        (if complete
          24
          16))]
    [index : i64 0]
    (begin
      (set! (array-ref bytes 0) 38)
      (while (< index 8)
        (begin
          (set!
            (array-ref bytes (+ 8 index))
            (cast (bit-and (shr signature (* index 8)) 255) : u8))
          (if complete
            (set!
              (array-ref bytes (+ 16 index))
              (cast (bit-and (shr mode (* index 8)) 255) : u8))
            unit)
          (set! index (+ index 1))))
      bytes)))

(define (c-function-codec-decode [mode : ast.AstCFunctionMode]) : bool
  (let
    [reader : codec.SurfaceAstReader
      (codec.surface-ast-reader-new
        (c-function-codec-bytes 17 (ast.ast-c-function-mode-key mode) true)
        (c-function-codec-session)
        (__tl_make-array i64 0))]
    [decoded : ast.AstType (codec.surface-ast-read-type! (& reader))]
    (and
      (codec.surface-ast-reader-valid? (& reader))
      (= (codec.surface-ast-reader-offset (& reader)) 24)
      (match decoded
        [(ast.AstType.CFunc signature actual)
          (and (= signature 17) (ast.ast-c-function-mode-eq? actual mode))]
        [_ false]))))

(define (c-function-codec-invalid
  [signature : i64]
  [mode : i64]
  [complete : bool]) : bool
  (let
    [reader : codec.SurfaceAstReader
      (codec.surface-ast-reader-new
        (c-function-codec-bytes signature mode complete)
        (c-function-codec-session)
        (__tl_make-array i64 0))]
    [_decoded : ast.AstType (codec.surface-ast-read-type! (& reader))]
    (not (codec.surface-ast-reader-valid? (& reader)))))

(test
  c-function-codec-mode-decode
  (begin
    (test.assert-true
      (c-function-codec-decode ast.AstCFunctionMode.Nullable)
      "nullable decode")
    (test.assert-true
      (c-function-codec-decode ast.AstCFunctionMode.NonNull)
      "non-null decode")
    (test.assert-true
      (c-function-codec-decode ast.AstCFunctionMode.UnsafeNullable)
      "unsafe nullable decode")
    (test.assert-true
      (c-function-codec-decode ast.AstCFunctionMode.UnsafeNonNull)
      "unsafe non-null decode")))

(test
  c-function-codec-malformed
  (begin
    (test.assert-true
      (c-function-codec-invalid 17 -1 true)
      "negative mode rejected")
    (test.assert-true
      (c-function-codec-invalid 17 4 true)
      "unknown mode rejected")
    (test.assert-true
      (c-function-codec-invalid -1 0 true)
      "negative signature rejected")
    (test.assert-true
      (c-function-codec-invalid 17 0 false)
      "truncated mode rejected")))