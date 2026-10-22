(import linker_elf_dso_reader_tests as dso_tests)

(define (main) : i64
  (dso_tests.self-test))