;; The independent oracle wrapper supplies a file; the reader never does I/O.
(import linker_elf_dso_reader as dso)
(import linker_elf_object_reader as elf)
(import linker_elf_dso_reader_test_dump as dump)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.string)

(define (main) : i64
  (unless
    (or
      (= (io.arg-count) 2)
      (and (= (io.arg-count) 3) (string.eq (io.arg 2) "--no-version-records")))
    (io.panic "usage: elf-dso-oracle FILE [--no-version-records]\n"))
  (let
    [buffer : byte_buf.ByteBuf (io.read-file (io.arg 1))]
    [data : (__tl_dyn-array u8) (__tl_make-array u8 buffer.len)]
    [i : i64 0]
    [request : dso.DsoReadRequest
      (dso.DsoReadRequest
        (elf.ElfIdentity (cast 41 : u64) (cast 7 : u64))
        (dso.default-limits))]
    (while (< i buffer.len)
      (set! (array-ref data i) (array-ref buffer.slots i))
      (set! i (+ i 1)))
    (match (dso.read-dso (& data) (& request))
      [(ReadDso object)
        (io.print "{}" (dump.dump (& object) (= (io.arg-count) 2)))
        0]
      [(ReadFailed error)
        (io.eprint "ELF DSO {} at {}\n" error.field error.offset)
        1])))