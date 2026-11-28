(import compiler_coff_asm_codeview as cv)
(import compiler_coff_asm_object as object)
(import compiler_coff_asm_unwind as unwind)
(import compiler_linux_asm_reader as reader)
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_resolve as resolve)
(import compiler_object_coff as coff)
(import stdlib.byte_buf_core as buf)
(import stdlib.iterator)

(define (assemble-windows-x64 [final-text : (& str)]) : coff.ResultCompilerObjectCoff
  (let
    [parser (reader.new-windows-reader)]
    (try (reader.parse-final! (&mut parser) final-text))
    (let
      [image (&mut parser.image)]
      [n image.items.len]
      [raw (__tl_make-array buf.ByteBufBuilder n)]
      [size : i64 (+ 20 (* n 40))]
      (for [i (iterator.range 0 n)]
        (let
          [s (&mut (array-ref image.items.slots i))]
          (try (asm.relax! s i (& image.table)))
          (unless (= s.ty 8) (+= size s.size))
          (when
            (> size coff.compiler-object-coff-max-output-size)
            (return (Err "COFF object exceeds size limit")))))
      (let
        [values (try (resolve.resolve-all image))]
        (for [i (iterator.range 0 n)]
          (set!
            (array-ref raw i)
            (asm.materialize!
              (&mut (array-ref image.items.slots i))
              i
              (& image.table)))
          (try
            (resolve.apply-fields!
              image
              i
              (&mut values)
              (&mut (array-ref raw i)))))
        (try (unwind.generate! (& parser.unwind) image (&mut raw)))
        (try (cv.generate! (& parser.codeview) image (& values) (&mut raw)))
        (object.serialize image (& values) raw)))))