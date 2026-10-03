;; package_lock_smoke.tl - Runnable package lockfile helper smoke.
(import package_lock_core)
(cfg test (import stdlib.byte_buf))
(cfg test (import stdlib.env))
(cfg test (import stdlib.fs))
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector package_lock_core.PackageLockEntry core) as package_lock_entry_vec)

(define (main) : i64
  (package-lock-self-test))

(define (package-lock-valid-source) : String
  "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"zeta\") (url \"https://github.com/owner/zeta.git\") (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\")) (commit \"abcdef0123456789abcdef0123456789abcdef01\")) (dependency (alias \"alpha\") (url \"https://github.com/owner/alpha.git\") (pin (branch \"main\")) (commit \"1111111111111111111111111111111111111111\"))))")

(cfg
  test
  (define (package-lock-growth-source) : String
    "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"foxtrot\") (url \"u\") (pin (rev \"f\")) (commit \"f\")) (dependency (alias \"alpha\") (url \"u\") (pin (rev \"a\")) (commit \"a\")) (dependency (alias \"echo\") (url \"u\") (pin (rev \"e\")) (commit \"e\")) (dependency (alias \"bravo\") (url \"u\") (pin (rev \"b\")) (commit \"b\")) (dependency (alias \"delta\") (url \"u\") (pin (rev \"d\")) (commit \"d\")) (dependency (alias \"charlie\") (url \"u\") (pin (rev \"c\")) (commit \"c\"))))"))

(define (package-lock-expected-emitted) : String
  (str_cat.str-cat
    "(typelisp-lock\n"
    "  (version \"v1\")\n"
    "  (dependencies\n"
    "    (dependency\n      (alias \"alpha\")\n      (url \"https://github.com/owner/alpha.git\")\n      (pin (branch \"main\"))\n      (commit \"1111111111111111111111111111111111111111\"))\n"
    "    (dependency\n      (alias \"zeta\")\n      (url \"https://github.com/owner/zeta.git\")\n      (pin (rev \"abcdef0123456789abcdef0123456789abcdef01\"))\n      (commit \"abcdef0123456789abcdef0123456789abcdef01\"))\n"
    "  ))\n"))

(define (package-lock-valid-parse-ok?) : bool
  (match (package_lock_core.package-lock-parse (package-lock-valid-source))
    [(Err _) false]
    [(Ok lock)
      (let
        [entries : package_lock_entry_vec.Vec lock.entries]
        (and
          (string.eq lock.version package_lock_core.package-lock-version)
          (= (package_lock_entry_vec.len (& entries)) 2)
          (package_lock_core.package-lock-list-has-entry?
            entries
            "alpha"
            "https://github.com/owner/alpha.git"
            (Branch)
            "main"
            "1111111111111111111111111111111111111111")
          (package_lock_core.package-lock-list-has-entry?
            entries
            "zeta"
            "https://github.com/owner/zeta.git"
            (Rev)
            "abcdef0123456789abcdef0123456789abcdef01"
            "abcdef0123456789abcdef0123456789abcdef01")))]))

(define (package-lock-emit-stable-ok?) : bool
  (match (package_lock_core.package-lock-parse (package-lock-valid-source))
    [(Err _) false]
    [(Ok lock)
      (string.eq
        (package_lock_core.package-lock-emit lock)
        (package-lock-expected-emitted))]))

(define (package-lock-round-trip-ok?) : bool
  (match (package_lock_core.package-lock-parse (package-lock-valid-source))
    [(Err _) false]
    [(Ok lock)
      (match (package_lock_core.package-lock-parse
        (package_lock_core.package-lock-emit lock))
        [(Err _) false]
        [(Ok again)
          (let
            [entries : package_lock_entry_vec.Vec again.entries]
            (and
              (= (package_lock_entry_vec.len (& entries)) 2)
              (package_lock_core.package-lock-list-has-entry?
                entries
                "alpha"
                "https://github.com/owner/alpha.git"
                (Branch)
                "main"
                "1111111111111111111111111111111111111111")
              (package_lock_core.package-lock-list-has-entry?
                entries
                "zeta"
                "https://github.com/owner/zeta.git"
                (Rev)
                "abcdef0123456789abcdef0123456789abcdef01"
                "abcdef0123456789abcdef0123456789abcdef01")))])]))

(cfg
  test
  (define (package-lock-entry-alias-at?
    [entries : (& entries package_lock_entry_vec.Vec)]
    [index : i64]
    [alias : String]) : bool
    (string.eq
      (__tl-project-field
        (package_lock_entry_vec.get
          entries
          index
          (package_lock_core.package-lock-entry-list-fallback))
        alias)
      alias)))

(cfg
  test
  (define (package-lock-growth-entries-ok?
    [entries : (& entries package_lock_entry_vec.Vec)]) : bool
    (and
      (= (package_lock_entry_vec.len entries) 6)
      (= (package_lock_entry_vec.capacity entries) 8)
      (package-lock-entry-alias-at? entries 0 "alpha")
      (package-lock-entry-alias-at? entries 1 "bravo")
      (package-lock-entry-alias-at? entries 2 "charlie")
      (package-lock-entry-alias-at? entries 3 "delta")
      (package-lock-entry-alias-at? entries 4 "echo")
      (package-lock-entry-alias-at? entries 5 "foxtrot"))))

(cfg
  test
  (define (package-lock-growth-order-ok?) : bool
    (match (package_lock_core.package-lock-parse (package-lock-growth-source))
      [(Err _) false]
      [(Ok lock)
        (if (package-lock-growth-entries-ok? (& lock.entries))
          (match (package_lock_core.package-lock-parse
            (package_lock_core.package-lock-emit lock))
            [(Err _) false]
            [(Ok again) (package-lock-growth-entries-ok? (& again.entries))])
          false)])))

(define (package-lock-parse-rejects? [source : String] [expected : String]) : bool
  (match (package_lock_core.package-lock-parse source)
    [(Err message) (string.eq message expected)]
    [(Ok _) false]))

(define (package-lock-rejections-ok?) : bool
  (and
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"dup\") (url \"u\") (pin (rev \"a\")) (commit \"a\")) (dependency (alias \"dup\") (url \"u\") (pin (tag \"v1\")) (commit \"b\"))))"
      "package-lock: duplicate dependency alias `dup`")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"a\") (url \"u\") (pin (rev \"a\")))))"
      "package-lock: dependency missing required field `commit`")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias a) (url \"u\") (pin (rev \"a\")) (commit \"a\"))))"
      "package-lock: field `alias` must have a string value")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v2\") (dependencies))"
      "package-lock: unsupported version `v2`")
    (package-lock-parse-rejects?
      "(typelisp-lock (version \"v1\") (dependencies (dependency (alias \"a\") (url \"u\") (pin (sha \"a\")) (commit \"a\"))))"
      "package-lock: pin kind must be `rev`, `tag`, or `branch`")))

(cfg
  test
  (define (package-lock-transaction-test-fail [message : String]) : never
    (io.panic message)))

(cfg
  test
  (define (package-lock-transaction-test-snapshot [path : String]) : package_lock_core.PackageLockSnapshot
    (match (package_lock_core.package-lock-transaction-read path)
      [(Err message) (package-lock-transaction-test-fail message)]
      [(Ok snapshot) snapshot])))

(cfg
  test
  (define (package-lock-transaction-test-read [path : String]) : String
    (match (io.try-read-file (& path))
      [(ErrIoBytes error)
        (package-lock-transaction-test-fail (io.error-message error))]
      [(OkIoBytes contents) (byte_buf.to-string contents)])))

(cfg
  test
  (define (package-lock-transaction-test-expect-commit
    [snapshot : package_lock_core.PackageLockSnapshot]
    [source : String]
    [kind : i64]) : unit
    (match (package_lock_core.package-lock-transaction-commit snapshot source)
      [(Err message) (package-lock-transaction-test-fail message)]
      [(Ok outcome)
        (let
          [actual : i64
            (match outcome
              [(Unchanged _) 0]
              [(Reused _) 1]
              [(Replaced _) 2])]
          (if (= actual kind)
            unit
            (package-lock-transaction-test-fail
              "package-lock transaction: unexpected commit outcome")))])))

(cfg
  test
  (define (package-lock-transaction-test-expect-error
    [snapshot : package_lock_core.PackageLockSnapshot]
    [source : String]
    [needle : String]) : unit
    (match (package_lock_core.package-lock-transaction-commit snapshot source)
      [(Ok _)
        (package-lock-transaction-test-fail
          "package-lock transaction unexpectedly succeeded")]
      [(Err message)
        (if (string.contains (& message) (& needle))
          unit
          (package-lock-transaction-test-fail message))])))

(cfg
  test
  (define (package-lock-transaction-test-set-fault [phase : String]) : unit
    (let
      [name : String "TYPELISP_PACKAGE_LOCK_TEST_FAULT"]
      (if (env.set! (& name) (& phase))
        unit
        (package-lock-transaction-test-fail
          "package-lock transaction: cannot set fault injection")))))

(cfg
  test
  (define (package-lock-transaction-test-clear-fault) : unit
    (let
      [name : String "TYPELISP_PACKAGE_LOCK_TEST_FAULT"]
      (if (env.unset! (& name))
        unit
        (package-lock-transaction-test-fail
          "package-lock transaction: cannot clear fault injection")))))

(cfg
  test
  (define (package-lock-transaction-test-cleanup
    [root : String]
    [path : String]
    [collision : String]) : unit
    (let
      [target-name : String "target"]
      [typelisp-name : String "typelisp"]
      [locks-name : String "locks"]
      [guard-name : String "package-lock.writer-lock"]
      [target : String (fs.path-join (& root) (& target-name))]
      [typelisp : String (fs.path-join (& target) (& typelisp-name))]
      [locks : String (fs.path-join (& typelisp) (& locks-name))]
      [guard : String (fs.path-join (& locks) (& guard-name))]
      (fs.try-remove-file-if-exists (& path))
      (fs.try-remove-file-if-exists (& collision))
      (fs.try-remove-file-if-exists (& guard))
      (fs.try-remove-dir-if-exists (& locks))
      (fs.try-remove-dir-if-exists (& typelisp))
      (fs.try-remove-dir-if-exists (& target))
      (fs.try-remove-dir-if-exists (& root))
      unit)))

(cfg
  test
  (define (package-lock-transaction-test) : unit
    (match (fs.try-create-temp-dir "typelisp package lock transaction")
      [(ErrIoString error)
        (package-lock-transaction-test-fail (io.error-message error))]
      [(OkIoString root)
        (let
          [lock-name : String "typelisp.lock"]
          [path : String (fs.path-join (& root) (& lock-name))]
          [collision : String
            (package_lock_core.package-lock-stage-path
              (string.copy path)
              (+ package_lock_core.package-lock-stage-sequence 1)
              0)]
          [collision-source : String "unrelated staging owner\n"]
          [source-a : String
            "(typelisp-lock\n  (version \"v1\")\n  (dependencies\n  ))\n"]
          [source-b : String
            "(typelisp-lock\n  (version \"v1\")\n  (dependencies\n    (dependency\n      (alias \"dep\")\n      (url \"https://example.invalid/a.git\")\n      (pin (rev \"a\"))\n      (commit \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"))\n  ))\n"]
          [source-c : String
            "(typelisp-lock\n  (version \"v1\")\n  (dependencies\n    (dependency\n      (alias \"dep\")\n      (url \"https://example.invalid/a.git\")\n      (pin (rev \"b\"))\n      (commit \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"))\n  ))\n"]
          (match (io.try-write-file
            (& collision)
            (byte_buf.str-as-bytes (& collision-source)))
            [(ErrIoUnit error)
              (package-lock-transaction-test-fail (io.error-message error))]
            [(OkIoUnit) unit])
          (package-lock-transaction-test-expect-commit
            (package-lock-transaction-test-snapshot (string.copy path))
            (string.copy source-a)
            2)
          (if (string.eq
            (package-lock-transaction-test-read (string.copy path))
            source-a)
            unit
            (package-lock-transaction-test-fail
              "package-lock transaction: initial replacement mismatch"))
          (package-lock-transaction-test-expect-commit
            (package-lock-transaction-test-snapshot (string.copy path))
            (string.copy source-a)
            0)
          (let
            [snapshot-a : package_lock_core.PackageLockSnapshot
              (package-lock-transaction-test-snapshot (string.copy path))]
            (match (io.try-write-file
              (& path)
              (byte_buf.str-as-bytes (& source-b)))
              [(ErrIoUnit error)
                (package-lock-transaction-test-fail (io.error-message error))]
              [(OkIoUnit) unit])
            (package-lock-transaction-test-expect-error
              snapshot-a
              (string.copy source-c)
              "changed since resolution"))
          (match (io.file-open (& path) (OpenWriteCreateNew))
            [(OkIoFile handle)
              (io.file-close handle)
              (package-lock-transaction-test-fail
                "package-lock transaction: exclusive create reopened lock")]
            [(ErrIoFile _) unit])
          (if (string.eq
            (package-lock-transaction-test-read (string.copy path))
            source-b)
            unit
            (package-lock-transaction-test-fail
              "package-lock transaction: conflict overwrote winner"))
          (package-lock-transaction-test-set-fault "before-stage")
          (package-lock-transaction-test-expect-error
            (package-lock-transaction-test-snapshot (string.copy path))
            (string.copy source-c)
            "before-stage")
          (package-lock-transaction-test-clear-fault)
          (package-lock-transaction-test-set-fault "during-stage")
          (package-lock-transaction-test-expect-error
            (package-lock-transaction-test-snapshot (string.copy path))
            (string.copy source-c)
            "during-stage")
          (package-lock-transaction-test-clear-fault)
          (if (string.eq
            (package-lock-transaction-test-read (string.copy collision))
            collision-source)
            unit
            (package-lock-transaction-test-fail
              "package-lock transaction: removed another staging owner"))
          (package-lock-transaction-test-set-fault "before-replace")
          (package-lock-transaction-test-expect-error
            (package-lock-transaction-test-snapshot (string.copy path))
            source-c
            "before-replace")
          (package-lock-transaction-test-clear-fault)
          (if (string.eq
            (package-lock-transaction-test-read (string.copy path))
            source-b)
            unit
            (package-lock-transaction-test-fail
              "package-lock transaction: injected failure changed lock"))
          (package-lock-transaction-test-cleanup root path collision))])))

(define (package-lock-self-test-ok?) : bool
  (and
    (package-lock-valid-parse-ok?)
    (package-lock-emit-stable-ok?)
    (package-lock-round-trip-ok?)
    (package-lock-rejections-ok?)))

(define (package-lock-self-test) : i64
  (if (package-lock-self-test-ok?)
    42
    (io.panic "package-lock: self-test mismatch")))

(test
  package-lock-parse-emit-round-trip
  (if (package-lock-self-test-ok?)
    unit
    (io.panic "package-lock: inline self-test mismatch")))

(test
  package-lock-generated-vector-growth-order
  (if (package-lock-growth-order-ok?)
    unit
    (io.panic "package-lock: generated vector growth/order mismatch")))

(test package-lock-atomic-transaction (package-lock-transaction-test))