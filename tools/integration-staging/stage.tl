;; stage.tl - Execute a native integration staging copy plan (#8395).
;;
;; Usage: typelisp run tools/integration-staging/stage.tl -- PLAN
;;
;; PLAN holds one `source<TAB>destination` line per copy, in the order
;; scripts/verify-integration.sh planned them, with both paths relative to the
;; working directory (the repository root), so no host path translation happens
;; per file. Each copy creates the destination's missing parent directories and
;; writes the source's exact bytes. A line whose destination already holds the
;; same source from an earlier line is skipped; a different source in between
;; (A, then B, then A again) makes the later line write again, so every
;; destination ends with the bytes of the last line naming it. The first failure
;; (unreadable plan, malformed line, missing source, directory or write failure)
;; is reported with its line number and ends the run with status 1 before any
;; later line; status 0 means every line was satisfied.
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.hashmap)
(import (hashmap.hashmap String String) as written_map)
(import (hashmap.hashmap String i64) as dir_set)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define (stage-fail [line-number : i64] [message : String]) : i64
  (begin
    (io.print-error
      (str_cat.str-cat
        "integration staging: plan line "
        (string.int->string line-number)
        ": "
        message
        "\n"))
    1))

;; Create every missing directory above `path`, remembering the ones already
;; made or found so repeated destinations cost no further system calls.
(define (stage-ensure-parents
  [path : (& path str)]
  [dirs : (&mut dirs dir_set.Map)]) : io.ResultIoUnit
  (let
    [length : i64 (string.string-length path)]
    [index : i64 1]
    [result : io.ResultIoUnit OkIoUnit]
    [failed : bool false]
    (begin
      (while (and (not failed) (< index length))
        (begin
          (if (= (string.string-ref path index) '/')
            (let
              [prefix : String (string.substring path 0 index)]
              (if (dir_set.contains? dirs (string.copy (& prefix)))
                unit
                (match (fs.try-mkdir-if-missing (& prefix))
                  [(OkIoUnit) (dir_set.insert-ref! dirs prefix 1)]
                  [(ErrIoUnit error)
                    (begin
                      (set! result (ErrIoUnit error))
                      (set! failed true))])))
            unit)
          (set! index (+ index 1))))
      result)))

(define (stage-copy
  [line-number : i64]
  [source : String]
  [destination : String]
  [dirs : (&mut dirs dir_set.Map)]) : i64
  (match (io.try-read-file (& source))
    [(ErrIoBytes error)
      (stage-fail
        line-number
        (str_cat.str-cat "cannot read " source ": " (io.error-message error)))]
    [(OkIoBytes contents)
      (match (stage-ensure-parents (& destination) dirs)
        [(ErrIoUnit error)
          (stage-fail
            line-number
            (str_cat.str-cat
              "cannot create the directory for "
              destination
              ": "
              (io.error-message error)))]
        [(OkIoUnit)
          (match (io.try-write-file
            (& destination)
            (byte_buf.as-bytes (& contents)))
            [(ErrIoUnit error)
              (stage-fail
                line-number
                (str_cat.str-cat
                  "cannot write "
                  destination
                  " from "
                  source
                  ": "
                  (io.error-message error)))]
            [(OkIoUnit) 0])])]))

(define (stage-line-end [plan : (& plan str)] [start : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length plan)]
    (begin
      (while (and (< index length) (!= (string.string-ref plan index) '\n'))
        (set! index (+ index 1)))
      index)))

(define (stage-run-plan [plan : String]) : i64
  (let
    [written : written_map.Map (written_map.new)]
    [dirs : dir_set.Map (dir_set.new)]
    [length : i64 (string.string-length (& plan))]
    [start : i64 0]
    [line-number : i64 0]
    [status : i64 0]
    (begin
      (while (and (= status 0) (< start length))
        (let
          [end : i64 (stage-line-end (& plan) start)]
          [raw-end : i64
            (if (and
              (> end start)
              (= (string.string-ref (& plan) (- end 1)) '\r'))
              (- end 1)
              end)]
          [line : String (string.substring (& plan) start (- raw-end start))]
          [tab : i64 (string.index-of-byte (& line) 0 (cast 9 : u8))]
          (begin
            (set! line-number (+ line-number 1))
            (set! start (+ end 1))
            (cond
              [(= (string.string-length (& line)) 0) unit]
              [(or
                  (< tab 1)
                  (>= tab (- (string.string-length (& line)) 1))
                  (>= (string.index-of-byte (& line) (+ tab 1) (cast 9 : u8)) 0))
                (set!
                  status
                  (stage-fail
                    line-number
                    "expected `source<TAB>destination` with both paths nonempty"))]
              [else
                (let
                  [source : String (string.substring (& line) 0 tab)]
                  [destination : String
                    (string.substring
                      (& line)
                      (+ tab 1)
                      (- (string.string-length (& line)) (+ tab 1)))]
                  (if (string.eq
                    (written_map.get-value-or
                      (& written)
                      (string.copy (& destination))
                      "")
                    (string.copy (& source)))
                    unit
                    (begin
                      (set!
                        status
                        (stage-copy
                          line-number
                          (string.copy (& source))
                          (string.copy (& destination))
                          (&mut dirs)))
                      (if (= status 0)
                        (written_map.insert-ref!
                          (&mut written)
                          destination
                          source)
                        unit))))]))))
      status)))

(define (main) : i64
  (if (!= (io.arg-count) 2)
    (begin
      (io.print-error
        "usage: typelisp run tools/integration-staging/stage.tl -- PLAN\n")
      2)
    (let
      [plan-path : String (io.arg 1)]
      (match (io.try-read-file (& plan-path))
        [(ErrIoBytes error)
          (begin
            (io.print-error
              (str_cat.str-cat
                "integration staging: cannot read plan "
                plan-path
                ": "
                (io.error-message error)
                "\n"))
            1)]
        [(OkIoBytes contents) (stage-run-plan (byte_buf.to-string contents))]))))