;; compiler_object_coff_overflow_fixture.tl - emit the bounded extended-count
;; COFF fixture consumed by scripts/verify-coff-relocation-overflow.sh.
(import compiler_owned_view as owned_view)
(import compiler_object as cobj)
(import compiler_object_coff as coff)
(import stdlib.byte_buf)
(import stdlib.io)

(define (main) : i64
  (if (< (io.arg-count) 2)
    (begin
      (io.print-error
        "compiler-object-coff-overflow-fixture: expected output path")
      2)
    (let
      [image : cobj.CompilerObjectImage
        (coff.compiler-object-coff-boundary-image 0xffff 0x10000)]
      (match (coff.compiler-object-coff-render
        (owned_view.compiler-owned-shared-view image))
        [(coff.ResultCompilerObjectCoff.Ok bytes)
          (begin
            (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& bytes)))
            0)]
        [(coff.ResultCompilerObjectCoff.Err message)
          (begin
            (io.print-error message)
            1)]))))