;; Refs #7817. Native measurement driver; the shell runner checks zero growth
;; for a candidate and can retain unrestricted measurements for a baseline.
(import test_cli_entry_memory_smoke as memory)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (begin
    (unless
      (= (io.arg-count) 3)
      (io.panic "usage: test-entry-memory heavy|mixed 4|16|32\n"))
    (let
      [mode : String (io.arg 1)]
      [count-text : String (io.arg 2)]
      [count : i64
        (cond
          [(string.eq count-text "4") 4]
          [(string.eq count-text "16") 16]
          [(string.eq count-text "32") 32]
          [else 0])]
      [workload : memory.EntryMemoryWorkload
        (cond
          [(string.eq mode "heavy") memory.EntryMemoryWorkload.Heavy]
          [(string.eq mode "mixed") memory.EntryMemoryWorkload.Mixed]
          [else (io.panic "test-entry-memory: expected heavy or mixed\n")])]
      (begin
        (unless
          (> count 0)
          (io.panic "test-entry-memory: expected 4, 16, or 32 entries\n"))
        (let
          [sample : memory.EntryMemorySample
            (memory.entry-memory-sample workload count)]
          (begin
            (unless
              (> sample.warm-live 0)
              (io.panic "test-entry-memory: inactive allocation counters\n"))
            (io.print-format
              "test-entry-memory|{}|{}|{}|{}|{}\n"
              mode
              count
              sample.warm-live
              sample.final-live
              (- sample.final-live sample.warm-live))))
        0))))