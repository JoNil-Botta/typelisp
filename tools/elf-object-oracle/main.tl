;; Test driver only: checked objects or independent LLVM JSON enter here.
(import linker_elf_object_reader as elf)
(import linker_elf_object_reader_test_dump as dump)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.iterator)
(import stdlib.string)
(import normalize)
(import readelf)

(define (main) : i64
  (when
    (and (= (io.arg-count) 3) (string.eq (io.arg 1) "--normalize"))
    (io.print
      "{}"
      (normalize.normalize (byte_buf.to-string (io.read-file (io.arg 2)))))
    (return 0))
  (unless
    (or
      (= (io.arg-count) 2)
      (and (= (io.arg-count) 3) (string.eq (io.arg 1) "--readelf")))
    (io.panic "usage: elf-object-oracle [--readelf] OBJECT\n"))
  (let
    [gnu : bool (and (= (io.arg-count) 3) (string.eq (io.arg 1) "--readelf"))]
    [buffer : byte_buf.ByteBuf
      (io.read-file
        (io.arg
          (if gnu
            2
            1)))]
    [data : (__tl_dyn-array u8) (__tl_make-array u8 buffer.len)]
    [request : elf.ElfReadRequest
      (elf.ElfReadRequest
        (elf.ElfIdentity (cast 41 : u64) (cast 7 : u64))
        (elf.default-limits))]
    (for [i (iterator.range 0 buffer.len)]
      (set! (array-ref data i) (array-ref buffer.slots i)))
    (match (elf.read-object (& data) (& request))
      [(ReadObject object)
        (io.print
          "{}"
          (if gnu
            (readelf.dump (& object))
            (dump.dump (& object) false)))
        0]
      [(ReadFailed error)
        (io.eprint
          "ELF reader rejected section={} entry={} offset={}\n"
          error.section
          error.entry
          error.offset)
        1])))