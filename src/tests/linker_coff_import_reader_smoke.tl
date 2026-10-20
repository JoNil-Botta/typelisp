(import linker_coff_import_reader_tests as import_tests)

(define (main) : i64
  (import_tests.self-test)
  42)