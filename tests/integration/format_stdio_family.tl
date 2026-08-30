(import stdlib.format)
(import stdlib.io)

(define (main) : i64
  (if (> (io.arg-count) 1)
    (begin
      (io.eprint "error={}" (cast 9 : i64))
      (io.eprintln " line={}" (cast 10 : i64))
      (io.eprint "error={:?}" "e\n")
      (io.eprintln " hex={:#X?}" (cast -1 : i8))
      (io.eprintln
        " retained={:#?}"
        (format.args "value={:#x?}" (cast -1 : i8)))
      42)
    (begin
      (io.print "print={}" (cast 7 : i64))
      (io.println " line={}" (cast 8 : i64))
      (io.print "print={:?}" "o\n")
      (io.println " hex={:#x?}" (cast -1 : i8))
      (io.println " retained={:X?}" (format.args "value={:#x?}" (cast -1 : i8)))
      42)))