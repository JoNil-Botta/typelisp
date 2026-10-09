;; package_source_core_tests.tl - White-box tests for package sources: the
;; fetched-boundary lexer, directory skips, lock stage names, entries that
;; vanish between listing and inspection, source vectors and sorting, and
;; source-set binding.
(cfg test (import compiler_owned_view as owned_view))
(import stdlib.fs)
(cfg test (import stdlib.byte_buf))
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import stdlib.string)
(cfg test (import stdlib.str_cat_runtime as str_cat))
(cfg test (import compiler_load))
(cfg test (import tlci_core as tlci))
(import package_source_core as pkgsrc)
(cfg test (import package_lock_core))

(test
  package-source-fetched-boundary-rejects-lexical-escapes-before-io
  (unless
    (and
      (string.eq
        (pkgsrc.package-source-fetched-boundary-message
          "dep"
          "entry"
          "../outside.tl"
          "cache/checkout")
        "build: fetched package `dep` field `entry` path `../outside.tl` is not confined to locked checkout `cache/checkout`")
      (match (pkgsrc.package-source-confined-existing-file
        "dep"
        "entry"
        "../outside.tl"
        "cache/checkout")
        [(Err message)
          (string.eq
            message
            "build: fetched package `dep` field `entry` path `../outside.tl` is not confined to locked checkout `cache/checkout`")]
        [_ false])
      (match (pkgsrc.package-source-confined-existing-file
        "dep"
        "entry"
        "C:outside.tl"
        "cache/checkout")
        [(Err _) true]
        [_ false])
      (match (pkgsrc.package-source-confined-existing-file
        "dep"
        "entry"
        "\\\\server\\share\\outside.tl"
        "cache/checkout")
        [(Err _) true]
        [_ false]))
    (io.panic "package-source: fetched boundary lexical smoke failed")))

(test
  package-source-skips-package-test-directories
  (if (and
    (pkgsrc.package-source-skip-dir? "target")
    (pkgsrc.package-source-skip-dir? ".git")
    (pkgsrc.package-source-skip-dir? "tests")
    (not (pkgsrc.package-source-skip-dir? "tests_extra"))
    (not (pkgsrc.package-source-skip-dir? "src")))
    unit
    (io.panic "package-source: skip-dir self-test mismatch")))

(test
  package-source-vector-insert-sorts-and-dedups
  (if (let
    [items : svec.Vec
      (pkgsrc.package-source-vec-insert
        (pkgsrc.package-source-vec-insert
          (pkgsrc.package-source-vec-insert
            (pkgsrc.package-source-vec-insert (svec.new) "src/z.tl")
            "src/a.tl")
          "src/m.tl")
        "src/a.tl")]
    (and
      (= (svec.len (& items)) 3)
      (string.eq (svec.get (& items) 0 "") "src/a.tl")
      (string.eq (svec.get (& items) 1 "") "src/m.tl")
      (string.eq (svec.get (& items) 2 "") "src/z.tl")))
    unit
    (io.panic "package-source: vector insert self-test mismatch")))

(test
  package-source-generated-vector-grows-past-initial-capacity
  (if (let
    [items : svec.Vec (svec.new)]
    (svec.push-ref! (&mut items) "src/a.tl")
    (svec.push-ref! (&mut items) "src/b.tl")
    (svec.push-ref! (&mut items) "src/c.tl")
    (svec.push-ref! (&mut items) "src/d.tl")
    (svec.push-ref! (&mut items) "src/e.tl")
    (and
      (= (svec.len (& items)) 5)
      (string.eq (svec.get (& items) 0 "") "src/a.tl")
      (string.eq (svec.get (& items) 4 "") "src/e.tl")))
    unit
    (io.panic "package-source: generated vector growth self-test mismatch")))

(test
  package-source-sorts-directory-entries-before-scanning
  (if (let
    [entries : fs.FsStringVector (fs.string-vector-new)]
    [items : svec.Vec
      (begin
        (fs.string-vector-push! (&mut entries) "zeta")
        (fs.string-vector-push! (&mut entries) "alpha")
        (fs.string-vector-push! (&mut entries) "middle")
        (pkgsrc.package-source-sort-entries entries))]
    (match (& items)
      [_
        (and
          (= (svec.len (& items)) 3)
          (string.eq (svec.get (& items) 0 "") "alpha")
          (string.eq (svec.get (& items) 1 "") "middle")
          (string.eq (svec.get (& items) 2 "") "zeta"))]))
    unit
    (io.panic "package-source: entry sort self-test mismatch")))

(define (package-source-verify-binding-for
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]
  [rodata : (__tl_dyn-array u8)]) : pkgsrc.PackageSourceBindingVerification
  (match (pkgsrc.package-source-discover-for command manifest-path has-manifest)
    [(Err message) (Unreadable message)]
    [(Ok source-set) (pkgsrc.package-source-verify-binding source-set rodata)]))

(cfg
  test
  (define package-source-binding-test-root : String
    (str_cat.str-cat
      "target/package_source_binding_fixture/"
      (string.int->string (fs.process-id)))))
(cfg
  test
  (define package-source-binding-test-alternate-root : String
    (str_cat.str-cat
      "target/./package_source_binding_fixture/"
      (string.int->string (fs.process-id)))))
(cfg
  test
  (define package-source-binding-test-target : String
    "target"))
(cfg
  test
  (define package-source-binding-test-parent : String
    "target/package_source_binding_fixture"))
(cfg
  test
  (define package-source-binding-test-manifest-text : String
    "(package\n  (name \"binding_fixture\")\n  (version \"0.1.0\")\n  (kind \"bin\")\n  (entry \"a.tl\"))\n"))

(cfg
  test
  (define (package-source-binding-test-write
    [path : (& path str)]
    [contents : (& contents str)]) : bool
    (match (io.try-write-file path (byte_buf.str-as-bytes contents))
      [(OkIoUnit) true]
      [(ErrIoUnit _) false])))

(cfg
  test
  (define (package-source-binding-test-remove [path : (& path str)]) : unit
    (match (fs.try-remove-file path)
      [(or (OkIoUnit) (ErrIoUnit _)) unit])))

(cfg
  test
  (define (package-source-binding-test-ensure-root [root : (& root str)]) : bool
    (and
      (match (fs.try-mkdir-if-missing (& package-source-binding-test-target))
        [(OkIoUnit) true]
        [(ErrIoUnit _) false])
      (match (fs.try-mkdir-if-missing (& package-source-binding-test-parent))
        [(OkIoUnit) true]
        [(ErrIoUnit _) false])
      (match (fs.try-mkdir-if-missing root)
        [(OkIoUnit) true]
        [(ErrIoUnit _) false]))))

(cfg
  test
  (define (package-source-binding-test-manifest) : compiler_load.CompilerPkgManifest
    (compiler_load.CompilerPkgManifest
      "binding-fixture"
      "1.0.0"
      CompilerPkgKindBin
      "a.tl"
      (compiler_load.compiler-pkg-deps-empty)
      (compiler_load.compiler-pkg-link-empty))))

(cfg
  test
  (define (package-source-binding-test-source-set-from-sources
    [root : String]
    [sources : svec.Vec]) : pkgsrc.PackageSourceSet
    (pkgsrc.PackageSourceSet
      (pkgsrc.package-source-root-join root "typelisp.pkg")
      root
      (package-source-binding-test-manifest)
      sources)))

(cfg
  test
  (define (package-source-binding-test-source-set
    [root : String]
    [extra : bool]) : pkgsrc.PackageSourceSet
    (let
      [sources : svec.Vec (svec.new)]
      (svec.push-ref!
        (&mut sources)
        (pkgsrc.package-source-root-join root "a.tl"))
      (svec.push-ref!
        (&mut sources)
        (pkgsrc.package-source-root-join root "b.tl"))
      (if extra
        (svec.push-ref!
          (&mut sources)
          (pkgsrc.package-source-root-join root "c.tl"))
        unit)
      (package-source-binding-test-source-set-from-sources root sources))))

(cfg
  test
  (define (package-source-binding-test-pack
    [schema : i64]
    [payload : (__tl_dyn-array u8)]) : (__tl_dyn-array u8)
    (let
      [sections : (__tl_dyn-array tlci.TlciAuxSection)
        (__tl_make-array tlci.TlciAuxSection 1)]
      (set!
        (array-ref sections 0)
        (tlci.TlciAuxSection
          tlci.tlci-aux-kind-package-source-binding
          schema
          payload))
      (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
        [(Ok packed) packed]
        [(Err message) (io.panic message)]))))

(cfg
  test
  (define (package-source-binding-test-bound-pack [digest : i64]) : (__tl_dyn-array
      u8)
    (package-source-binding-test-pack
      tlci.tlci-package-source-binding-schema-version
      (let
        [payload : (__tl_dyn-array u8) (__tl_make-array u8 8)]
        (tlci.tlci-set-u64! (&mut payload) 0 digest)
        payload))))

(cfg
  test
  (define (package-source-binding-test-digest
    [source-set : pkgsrc.PackageSourceSet]) : i64
    (match (pkgsrc.package-source-set-digest source-set)
      [(Ok digest) digest]
      [(Err message) (io.panic message)])))

(cfg
  test
  (test
    package-source-binding-transcript-and-admission
    (let
      [root : String (string.copy (& package-source-binding-test-root))]
      [a : String (pkgsrc.package-source-root-join root "a.tl")]
      [b : String (pkgsrc.package-source-root-join root "b.tl")]
      [c : String (pkgsrc.package-source-root-join root "c.tl")]
      [setup : bool
        (and
          (package-source-binding-test-ensure-root root)
          (package-source-binding-test-write a "(a)\n")
          (package-source-binding-test-write b "(b)\n"))]
      (if (not setup)
        (io.panic "package-source: unable to create digest fixture")
        (let
          [source-set : pkgsrc.PackageSourceSet
            (package-source-binding-test-source-set
              (owned_view.compiler-owned-shared-view root)
              false)]
          [alternate : pkgsrc.PackageSourceSet
            (package-source-binding-test-source-set
              (string.copy (& package-source-binding-test-alternate-root))
              false)]
          [baseline : i64 0]
          [binding : (__tl_dyn-array u8) (tlci.tlci-empty-bytes)]
          (match (pkgsrc.package-source-set-digest
            (owned_view.compiler-owned-shared-view source-set))
            [(Ok digest) (set! baseline digest)]
            [(Err message) (io.panic message)])
          (if (not (= baseline 1959683407))
            (io.panic "package-source: pinned digest mismatch")
            unit)
          (match (pkgsrc.package-source-set-digest alternate)
            [(Ok digest)
              (if (not (= digest baseline))
                (io.panic
                  "package-source: alternate root spelling changed digest")
                unit)]
            [(Err message) (io.panic message)])
          (set! binding (package-source-binding-test-bound-pack baseline))
          (match (pkgsrc.package-source-verify-binding
            (owned_view.compiler-owned-shared-view source-set)
            (owned_view.compiler-owned-shared-view binding))
            [(Match digest)
              (if (not (= digest baseline))
                (io.panic "package-source: bound digest did not match")
                unit)]
            [_ (io.panic "package-source: bound digest admission failed")])
          (if (not (package-source-binding-test-write a "(changed)\n"))
            (io.panic "package-source: unable to mutate digest fixture")
            unit)
          (match (pkgsrc.package-source-set-digest
            (owned_view.compiler-owned-shared-view source-set))
            [(Ok digest)
              (if (= digest baseline)
                (io.panic
                  "package-source: content mutation did not change digest")
                unit)]
            [(Err message) (io.panic message)])
          (if (not (package-source-binding-test-write a "(a)\n"))
            (io.panic "package-source: unable to restore digest fixture")
            unit)
          (if (not (package-source-binding-test-write c "(c)\n"))
            (io.panic "package-source: unable to add digest fixture")
            unit)
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set root true))
            [(Ok digest)
              (if (= digest baseline)
                (io.panic "package-source: add source did not change digest")
                unit)]
            [(Err message) (io.panic message)])
          (match (pkgsrc.package-source-verify-binding
            (owned_view.compiler-owned-shared-view source-set)
            (package-source-binding-test-bound-pack 12345))
            [(Mismatch expected actual)
              (if (and (= expected baseline) (= actual 12345))
                unit
                (io.panic
                  "package-source: mismatch did not preserve expected/actual order"))]
            [_ (io.panic "package-source: mismatch admission failed")])
          (match (pkgsrc.package-source-verify-binding
            (owned_view.compiler-owned-shared-view source-set)
            (tlci.tlci-empty-bytes))
            [(MissingOrLegacy) unit]
            [_ (io.panic "package-source: missing binding admission failed")])
          (match (pkgsrc.package-source-verify-binding
            (owned_view.compiler-owned-shared-view source-set)
            (package-source-binding-test-pack
              2
              (tlci.tlci-string->bytes "future")))
            [(UnsupportedSchema schema)
              (if (= schema 2)
                unit
                (io.panic "package-source: unsupported schema changed"))]
            [_
              (io.panic "package-source: unsupported binding admission failed")])
          (match (pkgsrc.package-source-verify-binding
            (owned_view.compiler-owned-shared-view source-set)
            (package-source-binding-test-pack
              tlci.tlci-package-source-binding-schema-version
              (__tl_make-array u8 7)))
            [(Malformed _) unit]
            [_ (io.panic "package-source: malformed binding admission failed")])
          (match (pkgsrc.package-source-verify-binding
            (owned_view.compiler-owned-shared-view source-set)
            (owned_view.compiler-owned-shared-view binding))
            [(Match _) unit]
            [_ (io.panic "package-source: restore did not recover digest")])
          (if (not (package-source-binding-test-write a "(a)\n"))
            (io.panic
              "package-source: unable to restore source before unreadable check")
            unit)
          (match (fs.try-remove-file (& a))
            [(OkIoUnit) unit]
            [(ErrIoUnit _)
              (io.panic "package-source: unable to delete fixture")])
          (match (pkgsrc.package-source-verify-binding source-set binding)
            [(Unreadable _) unit]
            [_ (io.panic "package-source: deleted source was not unreadable")])
          ;; Leave the ignored fixture in a restorable state for a rerun.
          (package-source-binding-test-write a "(a)\n")
          (fs.try-remove-file (& c))
          unit)))))

(cfg
  test
  (test
    package-source-binding-order-framing-and-rename
    (let
      [root : String (string.copy (& package-source-binding-test-root))]
      [a : String (pkgsrc.package-source-root-join root "a.tl")]
      [b : String (pkgsrc.package-source-root-join root "b.tl")]
      [renamed : String (pkgsrc.package-source-root-join root "renamed.tl")]
      [collision-root : String
        (pkgsrc.package-source-root-join root "collision")]
      [collision-a : String
        (pkgsrc.package-source-root-join collision-root "a.tl")]
      [collision-b : String
        (pkgsrc.package-source-root-join collision-root "a.tlb.tl")]
      [setup : bool
        (and
          (package-source-binding-test-ensure-root root)
          (match (fs.try-mkdir-if-missing (& collision-root))
            [(OkIoUnit) true]
            [(ErrIoUnit _) false])
          (package-source-binding-test-write a "(a)\n")
          (package-source-binding-test-write b "(b)\n")
          (package-source-binding-test-write collision-a "b.tlX")
          (package-source-binding-test-write collision-b "X"))]
      (if (not setup)
        (io.panic "package-source: unable to create ordering fixture")
        (let
          [baseline : i64
            (package-source-binding-test-digest
              (package-source-binding-test-source-set
                (owned_view.compiler-owned-shared-view root)
                false))]
          [reversed : svec.Vec (svec.new)]
          [duplicate : svec.Vec (svec.new)]
          [collision-left : svec.Vec (svec.new)]
          [collision-right : svec.Vec (svec.new)]
          [renamed-sources : svec.Vec (svec.new)]
          (svec.push-ref! (&mut reversed) (string.copy (& b)))
          (svec.push-ref! (&mut reversed) (string.copy (& a)))
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view root)
              reversed))
            [(Err _) unit]
            [_ (io.panic "package-source: reversed source list was accepted")])
          (svec.push-ref! (&mut duplicate) (string.copy (& a)))
          (svec.push-ref! (&mut duplicate) (string.copy (& a)))
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view root)
              duplicate))
            [(Err _) unit]
            [_ (io.panic "package-source: duplicate source list was accepted")])
          (svec.push-ref! (&mut collision-left) collision-a)
          (svec.push-ref! (&mut collision-right) collision-b)
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view collision-root)
              collision-left))
            [(Ok left)
              (match (pkgsrc.package-source-set-digest
                (package-source-binding-test-source-set-from-sources
                  collision-root
                  collision-right))
                [(Ok right)
                  (if (= left right)
                    (io.panic
                      "package-source: framed collision was not distinguished")
                    unit)]
                [(Err message) (io.panic message)])]
            [(Err message) (io.panic message)])
          (package-source-binding-test-remove renamed)
          (match (fs.try-rename (& b) (& renamed))
            [(OkIoUnit) unit]
            [(ErrIoUnit _) (io.panic "package-source: rename fixture failed")])
          (svec.push-ref! (&mut renamed-sources) (string.copy (& a)))
          (svec.push-ref! (&mut renamed-sources) (string.copy (& renamed)))
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view root)
              renamed-sources))
            [(Ok changed)
              (if (= changed baseline)
                (io.panic "package-source: rename did not change digest")
                unit)]
            [(Err message) (io.panic message)])
          (match (fs.try-rename (& renamed) (& b))
            [(OkIoUnit) unit]
            [(ErrIoUnit _) (io.panic "package-source: rename restore failed")])
          (if (not
            (=
              (package-source-binding-test-digest
                (package-source-binding-test-source-set root false))
              baseline))
            (io.panic "package-source: rename restoration changed digest")
            unit)
          unit)))))

(cfg
  test
  (test
    package-source-binding-discovery-exclusions-and-removal
    (let
      [root : String
        (str_cat.str-cat
          (string.copy (& package-source-binding-test-root))
          "/discover")]
      [manifest-path : String
        (pkgsrc.package-source-root-join root "typelisp.pkg")]
      [a : String (pkgsrc.package-source-root-join root "a.tl")]
      [b : String (pkgsrc.package-source-root-join root "b.tl")]
      [target-root : String (pkgsrc.package-source-root-join root "target")]
      [target-source : String
        (pkgsrc.package-source-root-join target-root "ignored.tl")]
      [nested-root : String (pkgsrc.package-source-root-join root "nested")]
      [nested-manifest : String
        (pkgsrc.package-source-root-join nested-root "typelisp.pkg")]
      [nested-source : String
        (pkgsrc.package-source-root-join nested-root "ignored.tl")]
      [setup : bool
        (and
          (package-source-binding-test-ensure-root
            (string.copy (& package-source-binding-test-root)))
          (match (fs.try-mkdir-if-missing (& root))
            [(OkIoUnit) true]
            [(ErrIoUnit _) false])
          (match (fs.try-mkdir-if-missing (& target-root))
            [(OkIoUnit) true]
            [(ErrIoUnit _) false])
          (match (fs.try-mkdir-if-missing (& nested-root))
            [(OkIoUnit) true]
            [(ErrIoUnit _) false])
          (package-source-binding-test-write
            manifest-path
            (string.copy (& package-source-binding-test-manifest-text)))
          (package-source-binding-test-write a "(a)\n")
          (package-source-binding-test-write b "(b)\n")
          (package-source-binding-test-write target-source "(target)\n")
          (package-source-binding-test-write
            nested-manifest
            (string.copy (& package-source-binding-test-manifest-text)))
          (package-source-binding-test-write nested-source "(nested)\n"))]
      (if (not setup)
        (io.panic "package-source: unable to create discovery fixture")
        (let
          [binding : (__tl_dyn-array u8) (tlci.tlci-empty-bytes)]
          [baseline : i64 0]
          [empty-sources : svec.Vec (svec.new)]
          [target-sources : svec.Vec (svec.new)]
          [nested-sources : svec.Vec (svec.new)]
          [outside-sources : svec.Vec (svec.new)]
          [outside : String
            (pkgsrc.package-source-root-join root "../outside.tl")]
          (svec.push-ref! (&mut target-sources) (string.copy (& target-source)))
          (svec.push-ref! (&mut nested-sources) (string.copy (& nested-source)))
          (svec.push-ref! (&mut outside-sources) outside)
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view root)
              empty-sources))
            [(Err _) unit]
            [_ (io.panic "package-source: empty source set was accepted")])
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view root)
              target-sources))
            [(Err _) unit]
            [_ (io.panic "package-source: target source was accepted")])
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              (owned_view.compiler-owned-shared-view root)
              nested-sources))
            [(Err _) unit]
            [_ (io.panic "package-source: nested source was accepted")])
          (match (pkgsrc.package-source-set-digest
            (package-source-binding-test-source-set-from-sources
              root
              outside-sources))
            [(Err _) unit]
            [_ (io.panic "package-source: outside source was accepted")])
          (match (pkgsrc.package-source-discover-for
            "test"
            (owned_view.compiler-owned-shared-view manifest-path)
            true)
            [(Err message) (io.panic message)]
            [(Ok discovered)
              (set! baseline (package-source-binding-test-digest discovered))
              (if (not (= baseline 1959683407))
                (io.panic "package-source: discovery baseline mismatch")
                unit)])
          (set! binding (package-source-binding-test-bound-pack baseline))
          (match (package-source-verify-binding-for
            "test"
            (owned_view.compiler-owned-shared-view manifest-path)
            true
            (owned_view.compiler-owned-shared-view binding))
            [(Match digest)
              (if (= digest baseline)
                unit
                (io.panic "package-source: discovered binding did not match"))]
            [_ (io.panic "package-source: discovered match admission failed")])
          (if (not
            (package-source-binding-test-write
              target-source
              "(target changed)\n"))
            (io.panic "package-source: target fixture mutation failed")
            unit)
          (if (not
            (package-source-binding-test-write
              nested-source
              "(nested changed)\n"))
            (io.panic "package-source: nested fixture mutation failed")
            unit)
          (match (package-source-verify-binding-for
            "test"
            (owned_view.compiler-owned-shared-view manifest-path)
            true
            (owned_view.compiler-owned-shared-view binding))
            [(Match _) unit]
            [_ (io.panic "package-source: excluded source changed digest")])
          (match (fs.try-remove-file (& b))
            [(OkIoUnit) unit]
            [(ErrIoUnit _) (io.panic "package-source: removal fixture failed")])
          (match (package-source-verify-binding-for
            "test"
            (owned_view.compiler-owned-shared-view manifest-path)
            true
            (owned_view.compiler-owned-shared-view binding))
            [(Mismatch expected actual)
              (if (and (not (= expected actual)) (= actual baseline))
                unit
                (io.panic
                  "package-source: removal mismatch was not current-first"))]
            [_ (io.panic "package-source: removal did not produce mismatch")])
          (if (not (package-source-binding-test-write b "(b)\n"))
            (io.panic "package-source: removal restore failed")
            unit)
          (match (package-source-verify-binding-for
            "test"
            manifest-path
            true
            binding)
            [(Match _) unit]
            [_ (io.panic "package-source: restored discovery did not match")]))))))

(test
  package-source-lock-stage-names-match-the-writer-spelling-exactly
  (let
    [built : String
      (package_lock_core.package-lock-stage-path
        (package_lock_core.package-lock-file-name)
        7
        3)]
    (unless
      (and
        (package_lock_core.package-lock-stage-name?
          "typelisp.lock.stage.28860.1.0")
        (package_lock_core.package-lock-stage-name? (& built))
        (not (package_lock_core.package-lock-stage-name? ""))
        (not (package_lock_core.package-lock-stage-name? "typelisp.lock"))
        (not
          (package_lock_core.package-lock-stage-name? "typelisp.lock.stage."))
        (not
          (package_lock_core.package-lock-stage-name? "typelisp.lock.stage.1.2"))
        (not
          (package_lock_core.package-lock-stage-name?
            "typelisp.lock.stage.1.2."))
        (not
          (package_lock_core.package-lock-stage-name?
            "typelisp.lock.stage.1.2.3.4"))
        (not
          (package_lock_core.package-lock-stage-name?
            "typelisp.lock.stage.1..3"))
        (not
          (package_lock_core.package-lock-stage-name?
            "typelisp.lock.stage.-1.2.3"))
        (not
          (package_lock_core.package-lock-stage-name?
            "typelisp.lock.stage.1.2.x"))
        (not
          (package_lock_core.package-lock-stage-name?
            "typelisp.lock.stage.1.2.3.tl"))
        (not
          (package_lock_core.package-lock-stage-name?
            "xtypelisp.lock.stage.1.2.3"))
        (not
          (package_lock_core.package-lock-stage-name?
            "Typelisp.lock.stage.1.2.3")))
      (io.panic "package-source: lock stage name predicate mismatch"))))

(test
  package-source-inspection-not-found-skips-and-other-errors-stay-fatal
  (unless
    (and
      (match (pkgsrc.package-source-scan-kind
        "build"
        "root"
        "gone"
        "root/gone"
        (ErrFsFileKind (IoNotFound "root/gone"))
        (svec.new))
        [(Ok items) (= (svec.len (& items)) 0)]
        [_ false])
      (match (pkgsrc.package-source-scan-kind
        "build"
        "root"
        "locked"
        "root/locked"
        (ErrFsFileKind (IoPermissionDenied "root/locked"))
        (svec.new))
        [(Err message)
          (string.eq
            message
            "build: failed to inspect package path 'root/locked': io: permission denied: root/locked")]
        [_ false])
      (match (pkgsrc.package-source-scan-kind
        "check"
        "root"
        "odd.tl"
        "root/odd.tl"
        (ErrFsFileKind (IoSystemCode 5 "root/odd.tl"))
        (svec.new))
        [(Err message)
          (string.eq
            message
            "check: failed to inspect package path 'root/odd.tl': io: system error 5: root/odd.tl")]
        [_ false])
      (match (pkgsrc.package-source-scan-kind
        "build"
        "root"
        "bad"
        "root/bad"
        (ErrFsFileKind (IoInvalidPath "root/bad"))
        (svec.new))
        [(Err message)
          (string.eq
            message
            "build: failed to inspect package path 'root/bad': io: invalid path: root/bad")]
        [_ false]))
    (io.panic "package-source: inspection error classification mismatch")))

(cfg
  test
  (define (package-source-vanish-test-sources
    [root : (& root str)]
    [names : svec.Vec]) : svec.Vec
    (match (pkgsrc.package-source-scan-entries "build" root "" names (svec.new))
      [(Err message) (io.panic message)]
      [(Ok items) items])))

(cfg
  test
  (define (package-source-vanish-test-only?
    [items : svec.Vec]
    [expected : String]) : bool
    (and
      (= (svec.len (& items)) 1)
      (string.eq (svec.get (& items) 0 "") expected))))

;; Entries listed and then gone before inspection: the scan sees a name the
;; directory no longer holds, which is exactly the state a concurrent lock
;; writer leaves between this process's listing and its inspection.
(test
  package-source-scan-skips-entries-vanished-since-listing
  (match (fs.try-create-temp-dir "typelisp package source vanish")
    [(ErrIoString error) (io.panic (io.error-message error))]
    [(OkIoString root)
      (let
        [a-name : String "a.tl"]
        [a : String (fs.path-join (& root) (& a-name))]
        [nested-name : String "typelisp.lock.stage.1.2.3.tl"]
        [nested-dir-name : String "sub"]
        [sub : String (fs.path-join (& root) (& nested-dir-name))]
        [resembling : String (fs.path-join (& sub) (& nested-name))]
        [stage-dir-name : String "typelisp.lock.stage.4.5.6"]
        [stage-dir : String (fs.path-join (& root) (& stage-dir-name))]
        [hidden-name : String "hidden.tl"]
        [hidden : String (fs.path-join (& stage-dir) (& hidden-name))]
        [stage-file-name : String "typelisp.lock.stage.7.8.9"]
        [stage-file : String (fs.path-join (& sub) (& stage-file-name))]
        [listed : svec.Vec (svec.new)]
        [expected-a : String (compiler_load.compiler-load-normalize-path a)]
        [expected-resembling : String
          (compiler_load.compiler-load-normalize-path resembling)]
        (unless
          (and
            (match (fs.try-mkdir-if-missing (& sub))
              [(OkIoUnit) true]
              [(ErrIoUnit _) false])
            (match (fs.try-mkdir-if-missing (& stage-dir))
              [(OkIoUnit) true]
              [(ErrIoUnit _) false])
            (package-source-binding-test-write (& a) "(a)\n")
            (package-source-binding-test-write (& resembling) "(r)\n")
            (package-source-binding-test-write (& hidden) "(h)\n")
            (package-source-binding-test-write (& stage-file) "stage\n"))
          (io.panic "package-source: unable to create vanish fixture"))
        ;; A vanished non-source file, a vanished `.tl`-named entry, and a
        ;; vanished directory name are all skipped around a present source.
        (svec.push-ref! (&mut listed) "a.tl")
        (svec.push-ref! (&mut listed) "gone.lock")
        (svec.push-ref! (&mut listed) "gone.tl")
        (svec.push-ref! (&mut listed) "gone-dir")
        (unless
          (package-source-vanish-test-only?
            (package-source-vanish-test-sources (& root) listed)
            (string.copy (& expected-a)))
          (io.panic "package-source: vanished entries changed the scan"))
        ;; A stage-named directory is never package content, even with a
        ;; source inside; a stage-named file in a subdirectory is skipped;
        ;; a name that only resembles the stage spelling is ordinary.
        (match (pkgsrc.package-source-discover-root-for "build" (& root))
          [(Err message) (io.panic message)]
          [(Ok items)
            (unless
              (and
                (= (svec.len (& items)) 2)
                (string.eq (svec.get (& items) 0 "") expected-a)
                (string.eq (svec.get (& items) 1 "") expected-resembling))
              (io.panic "package-source: stage-named entries were scanned"))])
        (package-source-binding-test-remove (& hidden))
        (package-source-binding-test-remove (& stage-file))
        (package-source-binding-test-remove (& resembling))
        (package-source-binding-test-remove (& a))
        (fs.try-remove-dir-if-exists (& stage-dir))
        (fs.try-remove-dir-if-exists (& sub))
        (fs.try-remove-dir-if-exists (& root))
        unit)]))