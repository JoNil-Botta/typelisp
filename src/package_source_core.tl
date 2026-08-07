;; package_source_core.tl - Shared package source discovery helpers.
;;
;; Package-wide tool commands should agree on which files belong to a package.
;; This module resolves a `typelisp.pkg` path, loads the manifest, and walks the
;; package root for regular `.tl` files in deterministic order. Package-local
;; `tests` directories are reserved for `typelisp test` and fixture corpora, so
;; ordinary package source discovery skips them. Hosts without directory
;; enumeration fall back to the manifest entry source.
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_diagnostic)
(import compiler_load)
(import tlci_core as tlci)

(defstruct PackageSourceSet
  (manifest-path String)
  (manifest-dir String)
  (manifest compiler_load.CompilerPkgManifest)
  (sources svec.Vec))

(defenum ResultPackageSourceSet
  (Ok PackageSourceSet)
  (Err String))

(defenum ResultPackageSourceList
  (Ok svec.Vec)
  (Err String))

(defenum ResultPackageSourceDigest
  (Ok i64)
  (Err String))

(defenum PackageSourceBindingVerification
  (Match i64)
  ;; Stable ordering: expected/current-source digest first, actual/image
  ;; digest second.
  (Mismatch i64 i64)
  (Unreadable String)
  (MissingOrLegacy)
  (UnsupportedSchema i64)
  (Malformed String))

(define (package-source-char-code-at [text : String] [idx : i64]) : i64
  (cast (string.string-ref text idx) : i64))

(define (package-source-string-less? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string.string-length left)]
    [right-len : i64 (string.string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [idx : i64 0]
    [done : bool false]
    [less : bool false]
    (begin
      (while (and (not done) (< idx limit))
        (let
          [lc : i64 (package-source-char-code-at left idx)]
          [rc : i64 (package-source-char-code-at right idx)]
          (if (= lc rc)
            (set! idx (+ idx 1))
            (begin
              (set! less (< lc rc))
              (set! done true)))))
      (if done
        less
        (< left-len right-len)))))

(define (package-source-vec-insert-slot-from
  [items : svec.Vec]
  [value : String]
  [index : i64]) : i64
  (if (>= index (svec.len (& items)))
    index
    (let
      [head : String (svec.get (& items) index "")]
      (if (string.eq head value)
        -1
        (if (package-source-string-less? value head)
          index
          (package-source-vec-insert-slot-from items value (+ index 1)))))))

(define (package-source-vec-copy-range
  [items : svec.Vec]
  [out : svec.Vec (:consume)]
  [start : i64]
  [end : i64]) : svec.Vec
  (let
    [idx : i64 start]
    [cur : svec.Vec out]
    (begin
      (while (< idx end)
        (begin
          (svec.push (&mut cur) (svec.get (& items) idx ""))
          (set! idx (+ idx 1))))
      cur)))

(define (package-source-vec-insert-at
  [items : svec.Vec]
  [value : String]
  [slot : i64]) : svec.Vec
  (let
    [out : svec.Vec (svec.with-capacity (+ (svec.len (& items)) 1))]
    (begin
      (set! out (package-source-vec-copy-range items out 0 slot))
      (svec.push (&mut out) value)
      (set!
        out
        (package-source-vec-copy-range items out slot (svec.len (& items))))
      out)))

(define (package-source-vec-insert [items : svec.Vec] [value : String]) : svec.Vec
  (let
    [slot : i64 (package-source-vec-insert-slot-from items value 0)]
    (if (< slot 0)
      items
      (package-source-vec-insert-at items value slot))))

(define (package-source-manifest-dir [manifest-path : String]) : String
  (let
    [dir : String (compiler_load.compiler-load-dirname manifest-path)]
    (if (= (string.string-length dir) 0)
      "."
      dir)))

(define (package-source-discover-manifest-up [prefix : String] [fuel : i64]) : compiler_load.CompilerLoadMaybePath
  (if (<= fuel 0)
    (compiler_load.CompilerLoadNoPath)
    (let
      [candidate : String (string.append prefix "typelisp.pkg")]
      (if (io.file-exists? candidate)
        (compiler_load.CompilerLoadSomePath candidate)
        (package-source-discover-manifest-up
          (string.append prefix "../")
          (- fuel 1))))))

(define (package-source-load-manifest [path : String]) : ResultPackageSourceSet
  (if (io.file-exists? path)
    (match (compiler_load.compiler-load-parse-manifest-diagnostic-infer-kind
      path
      (byte_buf.to-string (io.read-file path)))
      [(compiler_load.ResultCompilerPkgManifestDiagnostic.Err diag)
        (ResultPackageSourceSet.Err
          (string.concat3
            "invalid package manifest '"
            (compiler_diagnostic.compiler-diagnostic-path (box-get diag))
            (string.append
              "': "
              (compiler_diagnostic.compiler-diagnostic-message (box-get diag)))))]
      [(compiler_load.ResultCompilerPkgManifestDiagnostic.Ok manifest)
        (ResultPackageSourceSet.Ok
          (PackageSourceSet
            path
            (package-source-manifest-dir path)
            manifest
            (svec.new)))])
    (ResultPackageSourceSet.Err
      (string.concat3 "cannot read package manifest '" path "'"))))

(define (package-source-resolve-manifest
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]) : ResultPackageSourceSet
  (let
    [resolved : compiler_load.CompilerLoadMaybePath
      (if has-manifest
        (compiler_load.CompilerLoadSomePath manifest-path)
        (package-source-discover-manifest-up "" 256))]
    (match resolved
      [(compiler_load.CompilerLoadNoPath)
        (ResultPackageSourceSet.Err
          (string.append
            command
            ": could not find typelisp.pkg from '.' or any parent directory"))]
      [(compiler_load.CompilerLoadSomePath path)
        (package-source-load-manifest path)])))

(define (package-source-relative-join [prefix : String] [name : String]) : String
  (if (= (string.string-length prefix) 0)
    name
    (compiler_load.compiler-load-join-root-path prefix name)))

(define (package-source-root-join [root : String] [relative : String]) : String
  (if (= (string.string-length relative) 0)
    root
    (compiler_load.compiler-load-join-root-path root relative)))

(define (package-source-internal-dir? [name : String]) : bool
  (or
    (string.eq name "target")
    (string.eq name ".git")
    (string.eq name ".hg")
    (string.eq name ".svn")
    (string.eq name ".jj")))

(define (package-source-test-dir? [name : String]) : bool
  (string.eq name "tests"))

(define (package-source-skip-dir? [name : String]) : bool
  (or (package-source-internal-dir? name) (package-source-test-dir? name)))

(define (package-source-skip-dir-self-test?) : bool
  (and
    (package-source-skip-dir? "target")
    (package-source-skip-dir? ".git")
    (package-source-skip-dir? "tests")
    (not (package-source-skip-dir? "tests_extra"))
    (not (package-source-skip-dir? "src"))))

(test
  package-source-skips-package-test-directories
  (if (package-source-skip-dir-self-test?)
    unit
    (io.panic "package-source: skip-dir self-test mismatch")))

(define (package-source-vec-insert-self-test?) : bool
  (let
    [items : svec.Vec
      (package-source-vec-insert
        (package-source-vec-insert
          (package-source-vec-insert
            (package-source-vec-insert (svec.new) "src/z.tl")
            "src/a.tl")
          "src/m.tl")
        "src/a.tl")]
    (and
      (= (svec.len (& items)) 3)
      (string.eq (svec.get (& items) 0 "") "src/a.tl")
      (string.eq (svec.get (& items) 1 "") "src/m.tl")
      (string.eq (svec.get (& items) 2 "") "src/z.tl"))))

(test
  package-source-vector-insert-sorts-and-dedups
  (if (package-source-vec-insert-self-test?)
    unit
    (io.panic "package-source: vector insert self-test mismatch")))

(define (package-source-vector-growth-self-test?) : bool
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut items) "src/a.tl")
      (svec.push (&mut items) "src/b.tl")
      (svec.push (&mut items) "src/c.tl")
      (svec.push (&mut items) "src/d.tl")
      (svec.push (&mut items) "src/e.tl")
      (and
        (= (svec.len (& items)) 5)
        (string.eq (svec.get (& items) 0 "") "src/a.tl")
        (string.eq (svec.get (& items) 4 "") "src/e.tl")))))

(test
  package-source-generated-vector-grows-past-initial-capacity
  (if (package-source-vector-growth-self-test?)
    unit
    (io.panic "package-source: generated vector growth self-test mismatch")))

(define (package-source-sort-entries-from
  [entries : fs.FsStringVector]
  [index : i64]
  [acc : svec.Vec]) : svec.Vec
  (if (>= index (fs.string-vector-len (& entries)))
    acc
    (package-source-sort-entries-from
      entries
      (+ index 1)
      (package-source-vec-insert
        acc
        (fs.string-vector-get (& entries) index "")))))

(define (package-source-sort-entries [entries : fs.FsStringVector]) : svec.Vec
  (package-source-sort-entries-from entries 0 (svec.new)))

(define (package-source-sort-entries-self-test?) : bool
  (let
    [entries : fs.FsStringVector (fs.string-vector-new)]
    [items : svec.Vec
      (begin
        (fs.string-vector-push! (&mut entries) "zeta")
        (fs.string-vector-push! (&mut entries) "alpha")
        (fs.string-vector-push! (&mut entries) "middle")
        (package-source-sort-entries entries))]
    (match items
      [_
        (and
          (= (svec.len (& items)) 3)
          (string.eq (svec.get (& items) 0 "") "alpha")
          (string.eq (svec.get (& items) 1 "") "middle")
          (string.eq (svec.get (& items) 2 "") "zeta"))])))

(test
  package-source-sorts-directory-entries-before-scanning
  (if (package-source-sort-entries-self-test?)
    unit
    (io.panic "package-source: entry sort self-test mismatch")))

(define (package-source-dir-has-manifest? [dir : String]) : bool
  (io.file-exists?
    (compiler_load.compiler-load-join-root-path dir "typelisp.pkg")))

(define (package-source-tl-file? [path : String]) : bool
  (string.eq (fs.extension (& path)) "tl"))

(define (package-source-include-kind? [path : String] [kind : fs.FsFileKind]) : bool
  (and (fs.file-kind-regular? kind) (package-source-tl-file? path)))

(define (package-source-entry-error
  [command : String]
  [path : String]
  [error : io.IoError]) : ResultPackageSourceList
  (ResultPackageSourceList.Err
    (string.concat3
      (string.append command ": failed to inspect package path '")
      path
      (string.append "': " (io.error-message error)))))

(define (package-source-read-dir-error
  [command : String]
  [path : String]
  [error : io.IoError]) : ResultPackageSourceList
  (ResultPackageSourceList.Err
    (string.concat3
      (string.append command ": failed to read package directory '")
      path
      (string.append "': " (io.error-message error)))))

(define (package-source-entry-list [source-set : PackageSourceSet]) : svec.Vec
  (let
    [manifest : compiler_load.CompilerPkgManifest
      (struct-get source-set manifest)]
    [entry : String
      (compiler_load.compiler-load-normalize-path
        (package-source-root-join
          (struct-get source-set manifest-dir)
          (struct-get manifest entry)))]
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut items) entry)
      items)))

(define (package-source-scan-dir
  [command : String]
  [root : String]
  [relative : String]
  [acc : svec.Vec]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (fs.try-read-dir (& dir))
      [(fs.ErrIoStringVector error)
        (package-source-read-dir-error command dir error)]
      [(fs.OkIoStringVector entries)
        (package-source-scan-entries
          command
          root
          relative
          (package-source-sort-entries entries)
          acc)])))

(define (package-source-scan-optional-dir
  [command : String]
  [root : String]
  [relative : String]
  [acc : svec.Vec]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (fs.try-read-dir (& dir))
      [(fs.ErrIoStringVector error)
        (if (or (io.error-not-found? error) (io.error-unsupported? error))
          (ResultPackageSourceList.Ok acc)
          (package-source-read-dir-error command dir error))]
      [(fs.OkIoStringVector entries)
        (package-source-scan-entries
          command
          root
          relative
          (package-source-sort-entries entries)
          acc)])))

(define (package-source-scan-root
  [command : String]
  [source-set : PackageSourceSet]) : ResultPackageSourceList
  (let
    [root : String (struct-get source-set manifest-dir)]
    (match (fs.try-read-dir (& root))
      [(fs.ErrIoStringVector error)
        (if (io.error-unsupported? error)
          (ResultPackageSourceList.Ok (package-source-entry-list source-set))
          (package-source-read-dir-error command root error))]
      [(fs.OkIoStringVector entries)
        (package-source-scan-entries
          command
          root
          ""
          (package-source-sort-entries entries)
          (svec.new))])))

(define (package-source-scan-one
  [command : String]
  [root : String]
  [relative : String]
  [name : String]
  [acc : svec.Vec]) : ResultPackageSourceList
  (if (package-source-skip-dir? name)
    (ResultPackageSourceList.Ok acc)
    (let
      [child-relative : String (package-source-relative-join relative name)]
      [child-path : String (package-source-root-join root child-relative)]
      ;; Do not follow symbolic links or Windows reparse points. Package and
      ;; workspace discovery must stay inside the lexical root and a directory
      ;; link back to an ancestor must not turn traversal into a cycle.
      (match (fs.try-file-kind-no-follow (& child-path))
        [(fs.ErrFsFileKind error)
          (package-source-entry-error command child-path error)]
        [(fs.OkFsFileKind kind)
          (if (fs.file-kind-directory? kind)
            (if (package-source-dir-has-manifest? child-path)
              (ResultPackageSourceList.Ok acc)
              (package-source-scan-dir command root child-relative acc))
            (if (package-source-include-kind? child-path kind)
              (ResultPackageSourceList.Ok
                (package-source-vec-insert
                  acc
                  (compiler_load.compiler-load-normalize-path child-path)))
              (ResultPackageSourceList.Ok acc)))]))))

(define (package-source-scan-entries-from
  [command : String]
  [root : String]
  [relative : String]
  [entries : svec.Vec]
  [index : i64]
  [acc : svec.Vec]) : ResultPackageSourceList
  (if (>= index (svec.len (& entries)))
    (ResultPackageSourceList.Ok acc)
    (match (package-source-scan-one
      command
      root
      relative
      (svec.get (& entries) index "")
      acc)
      [(ResultPackageSourceList.Err message)
        (ResultPackageSourceList.Err message)]
      [(ResultPackageSourceList.Ok next)
        (package-source-scan-entries-from
          command
          root
          relative
          entries
          (+ index 1)
          next)])))

(define (package-source-scan-entries
  [command : String]
  [root : String]
  [relative : String]
  [entries : svec.Vec]
  [acc : svec.Vec]) : ResultPackageSourceList
  (package-source-scan-entries-from command root relative entries 0 acc))

;; Discover ordinary package-style TypeLisp sources below an explicit root.
;; Unlike `package-source-discover-for`, this does not require or parse a
;; manifest at the root. It exists for tooling such as the LSP workspace index
;; that receives roots from its protocol while still needing exactly the same
;; deterministic traversal, exclusion, regular-file, and nested-package rules.
(define (package-source-discover-root-for [command : String] [root : String]) : ResultPackageSourceList
  (let
    [normalized-root : String (compiler_load.compiler-load-normalize-path root)]
    (match (fs.try-read-dir (& normalized-root))
      [(fs.ErrIoStringVector error)
        (package-source-read-dir-error command normalized-root error)]
      [(fs.OkIoStringVector entries)
        (package-source-scan-entries
          command
          normalized-root
          ""
          (package-source-sort-entries entries)
          (svec.new))])))

;; Return the next normalized path-separator position, or `end`.
(define (package-source-relative-separator
  [relative : String]
  [start : i64]
  [end : i64]) : i64
  (let
    [index : i64 start]
    (begin
      (while (and
        (< index end)
        (not (fs.path-separator? (string.string-ref relative index))))
        (set! index (+ index 1)))
      index)))

;; Check the directory segments that lead to one source. The root's own
;; manifest is allowed; a manifest below it is a nested-package boundary.
(define (package-source-relative-parent-eligible?
  [root : String]
  [relative : String]) : bool
  (let
    [end : i64 (fs.last-separator-index (& relative))]
    [cursor : i64 0]
    [prefix : String ""]
    [eligible : bool true]
    (begin
      (while (and eligible (>= end 0) (< cursor end))
        (let
          [separator : i64
            (package-source-relative-separator relative cursor end)]
          [name : String
            (string.substring relative cursor (- separator cursor))]
          (begin
            (if (or
              (= (string.string-length name) 0)
              (package-source-skip-dir? name))
              (set! eligible false)
              (let
                [next-prefix : String
                  (package-source-relative-join prefix name)]
                [parent : String (package-source-root-join root next-prefix)]
                (begin
                  (set! prefix next-prefix)
                  ;; Match recursive discovery: every parent must be a real
                  ;; directory, never a symlink or Windows reparse point.
                  (match (fs.try-file-kind-no-follow (& parent))
                    [(fs.ErrFsFileKind _) (set! eligible false)]
                    [(fs.OkFsFileKind kind)
                      (if (and
                        (fs.file-kind-directory? kind)
                        (not (package-source-dir-has-manifest? parent)))
                        unit
                        (set! eligible false))]))))
            (set! cursor (+ separator 1)))))
      eligible)))

;; Parent-policy half of the single-path check. This intentionally does not
;; require the file itself to exist so an unsaved open document can still be
;; associated with its workspace root.
(define (package-source-path-location-eligible-for-root?
  [root : String]
  [path : String]) : bool
  (let
    [normalized-root : String (compiler_load.compiler-load-normalize-path root)]
    [normalized-path : String (compiler_load.compiler-load-normalize-path path)]
    [relative : String
      (compiler_load.compiler-load-root-relative-path
        normalized-root
        normalized-path)]
    (and
      (not (string.eq relative normalized-path))
      (fs.path-safe-relative? (& relative))
      (package-source-tl-file? normalized-path)
      (package-source-relative-parent-eligible? normalized-root relative))))

;; Fast single-path counterpart to root discovery for file-watcher events.
;; The path must additionally be a current regular file.
(define (package-source-path-eligible-for-root? [root : String] [path : String]) : bool
  (let
    [normalized-path : String (compiler_load.compiler-load-normalize-path path)]
    (and
      (package-source-path-location-eligible-for-root? root normalized-path)
      (match (fs.try-file-kind-no-follow (& normalized-path))
        [(fs.OkFsFileKind kind)
          (package-source-include-kind? normalized-path kind)]
        [(fs.ErrFsFileKind _) false]))))

(define (package-source-discover-for
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]) : ResultPackageSourceSet
  (match (package-source-resolve-manifest command manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message) (ResultPackageSourceSet.Err message)]
    [(ResultPackageSourceSet.Ok base)
      (match (package-source-scan-root command base)
        [(ResultPackageSourceList.Err message)
          (ResultPackageSourceSet.Err message)]
        [(ResultPackageSourceList.Ok sources)
          (if (= (svec.len (& sources)) 0)
            (ResultPackageSourceSet.Err
              (string.concat3
                (string.append
                  command
                  ": no TypeLisp source files found in package '")
                (struct-get base manifest-path)
                "'"))
            (ResultPackageSourceSet.Ok
              (PackageSourceSet
                (struct-get base manifest-path)
                (struct-get base manifest-dir)
                (struct-get base manifest)
                sources)))])]))

(define (package-source-discover-tests-for
  [command : String]
  [source-set : PackageSourceSet]) : ResultPackageSourceList
  (let
    [root : String (struct-get source-set manifest-dir)]
    (package-source-scan-optional-dir command root "tests" (svec.new))))

;; Source-set provenance transcript -------------------------------------------------
;;
;; The transcript is framed with little-endian u64 lengths so concatenation
;; shapes cannot collide.  Files are read as bytes through `io.try-read-file`;
;; no text conversion or newline normalization is involved.
(define package-source-binding-domain : String
  "typelisp-package-source-set")
(define package-source-binding-schema-version : i64
  1)
(define package-source-binding-hash-modulus : i64
  2147483647)
(define package-source-binding-hash-multiplier : i64
  131)

(define (package-source-binding-hash-byte [hash : i64] [value : i64]) : i64
  (%
    (+ (* hash package-source-binding-hash-multiplier) (bit-and value 0xff))
    package-source-binding-hash-modulus))

(define (package-source-binding-hash-u64 [hash : i64] [value : i64]) : i64
  (let
    [next : i64 hash]
    [index : i64 0]
    (begin
      (while (< index 8)
        (begin
          (set!
            next
            (package-source-binding-hash-byte next (shr value (* index 8))))
          (set! index (+ index 1))))
      next)))

(define (package-source-binding-hash-string [hash : i64] [text : String]) : i64
  (let
    [next : i64 hash]
    [index : i64 0]
    [count : i64 (string.string-length text)]
    (begin
      (while (< index count)
        (begin
          (set!
            next
            (package-source-binding-hash-byte
              next
              (cast (string.string-ref text index) : i64)))
          (set! index (+ index 1))))
      next)))

(define (package-source-binding-hash-bytes
  [hash : i64]
  [bytes : (__tl_dyn-array u8)]) : i64
  (let
    [next : i64 hash]
    [index : i64 0]
    [count : i64 (array-length bytes)]
    (begin
      (while (< index count)
        (begin
          (set!
            next
            (package-source-binding-hash-byte
              next
              (cast (array-ref bytes index) : i64)))
          (set! index (+ index 1))))
      next)))

(define (package-source-binding-relative-path [root : String] [path : String]) : String
  (let
    [normalized-root : String (compiler_load.compiler-load-normalize-path root)]
    [normalized-path : String (compiler_load.compiler-load-normalize-path path)]
    [relative : String
      (if (= normalized-root ".")
        normalized-path
        (compiler_load.compiler-load-root-relative-path
          normalized-root
          normalized-path))]
    (if (and
      (> (string.string-length relative) 0)
      (not (string.eq relative "."))
      (fs.path-safe-relative? (& relative))
      (package-source-tl-file? relative)
      (not (string.eq relative normalized-path)))
      relative
      ;; A root of `.` has no lexical prefix after normalization; its
      ;; normalized path is nevertheless a valid package-relative spelling.
      (if (and
        (string.eq normalized-root ".")
        (> (string.string-length normalized-path) 0)
        (not (string.eq normalized-path "."))
        (fs.path-safe-relative? (& normalized-path))
        (package-source-tl-file? normalized-path))
        normalized-path
        ""))))

(define (package-source-binding-invalid-set-error
  [source-set : PackageSourceSet]
  [path : String]
  [reason : String]) : String
  (str_cat.str-cat
    "package '"
    (struct-get source-set manifest-path)
    "' source '"
    path
    "': "
    reason))

(define (package-source-binding-read-error
  [source-set : PackageSourceSet]
  [path : String]
  [error : io.IoError]) : String
  (package-source-binding-invalid-set-error
    source-set
    path
    (str_cat.str-cat "unreadable source: " (io.error-message error))))

;; Hash one already-read source after its relative path and file length.  This
;; small helper keeps the main walker readable and makes the exact framing
;; explicit in one place.
(define (package-source-binding-hash-source
  [hash : i64]
  [relative : String]
  [bytes : (__tl_dyn-array u8)]) : i64
  (let
    [with-path-len : i64
      (package-source-binding-hash-u64 hash (string.string-length relative))]
    [with-path : i64
      (package-source-binding-hash-string with-path-len relative)]
    [with-file-len : i64
      (package-source-binding-hash-u64 with-path (array-length bytes))]
    (package-source-binding-hash-bytes with-file-len bytes)))

(define (package-source-set-digest [source-set : PackageSourceSet]) : ResultPackageSourceDigest
  (let
    [sources : svec.Vec (struct-get source-set sources)]
    [root : String
      (compiler_load.compiler-load-normalize-path
        (struct-get source-set manifest-dir))]
    [count : i64 (svec.len (& sources))]
    [hash0 : i64
      (package-source-binding-hash-u64
        (package-source-binding-hash-u64
          (package-source-binding-hash-string
            (package-source-binding-hash-u64
              1
              (string.string-length package-source-binding-domain))
            (string.copy (& package-source-binding-domain)))
          package-source-binding-schema-version)
        count)]
    [index : i64 0]
    [hash : i64 hash0]
    [previous-relative : String ""]
    [error : String
      (if (<= count 0)
        "package source set must contain at least one source"
        "")]
    (while (and (= (string.string-length error) 0) (< index count))
      (let
        [path : String (svec.get (& sources) index "")]
        [relative : String (package-source-binding-relative-path root path)]
        (cond
          [(= (string.string-length relative) 0)
            (set!
              error
              (package-source-binding-invalid-set-error
                source-set
                path
                "source path is not a safe nonempty relative path under package root"))]
          [(if (= (string.string-length previous-relative) 0)
              false
              (not (package-source-string-less? previous-relative relative)))
            (set!
              error
              (package-source-binding-invalid-set-error
                source-set
                path
                "source paths must be unique and in deterministic order"))]
          [(not (package-source-relative-parent-eligible? root relative))
            (set!
              error
              (package-source-binding-invalid-set-error
                source-set
                path
                "source is excluded by package discovery policy"))]
          [else
            (match (fs.try-file-kind-no-follow (& path))
              [(fs.ErrFsFileKind io-error)
                (set!
                  error
                  (package-source-binding-read-error source-set path io-error))]
              [(fs.OkFsFileKind kind)
                (if (not (package-source-include-kind? path kind))
                  (set!
                    error
                    (package-source-binding-invalid-set-error
                      source-set
                      path
                      "source is no longer a regular TypeLisp file"))
                  (match (io.try-read-file (& path))
                    [(io.ErrIoBytes io-error)
                      (set!
                        error
                        (package-source-binding-read-error
                          source-set
                          path
                          io-error))]
                    [(io.OkIoBytes contents)
                      (let
                        [bytes : (__tl_dyn-array u8)
                          (byte_buf.to-array contents)]
                        (set!
                          hash
                          (package-source-binding-hash-source
                            hash
                            relative
                            bytes))
                        (set! previous-relative relative))]))])])
        (set! index (+ index 1))))
    (if (> (string.string-length error) 0)
      (ResultPackageSourceDigest.Err error)
      (ResultPackageSourceDigest.Ok hash))))

(define (package-source-binding-verification-from-admission
  [admission : tlci.TlciPackageSourceBindingAdmission]) : PackageSourceBindingVerification
  (match admission
    [(tlci.TlciPackageSourceBindingAdmission.Match digest)
      (PackageSourceBindingVerification.Match digest)]
    [(tlci.TlciPackageSourceBindingAdmission.Mismatch expected actual)
      (PackageSourceBindingVerification.Mismatch expected actual)]
    [(tlci.TlciPackageSourceBindingAdmission.MissingOrLegacy)
      (PackageSourceBindingVerification.MissingOrLegacy)]
    [(tlci.TlciPackageSourceBindingAdmission.UnsupportedSchema schema)
      (PackageSourceBindingVerification.UnsupportedSchema schema)]
    [(tlci.TlciPackageSourceBindingAdmission.Malformed message)
      (PackageSourceBindingVerification.Malformed message)]))

(define (package-source-verify-binding
  [source-set : PackageSourceSet]
  [rodata : (__tl_dyn-array u8)]) : PackageSourceBindingVerification
  (match (package-source-set-digest source-set)
    [(ResultPackageSourceDigest.Err message)
      (PackageSourceBindingVerification.Unreadable message)]
    [(ResultPackageSourceDigest.Ok expected)
      (package-source-binding-verification-from-admission
        (tlci.tlci-package-source-binding-admit rodata expected))]))

(define (package-source-verify-binding-for
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]
  [rodata : (__tl_dyn-array u8)]) : PackageSourceBindingVerification
  (match (package-source-discover-for command manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (PackageSourceBindingVerification.Unreadable message)]
    [(ResultPackageSourceSet.Ok source-set)
      (package-source-verify-binding source-set rodata)]))

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
    [path : String]
    [contents : String]) : bool
    (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& contents)))
      [(io.OkIoUnit) true]
      [(io.ErrIoUnit _) false])))

(cfg
  test
  (define (package-source-binding-test-remove [path : String]) : unit
    (match (fs.try-remove-file (& path))
      [(io.OkIoUnit) unit]
      [(io.ErrIoUnit _) unit])))

(cfg
  test
  (define (package-source-binding-test-ensure-root [root : String]) : bool
    (and
      (match (fs.try-mkdir-if-missing (& package-source-binding-test-target))
        [(io.OkIoUnit) true]
        [(io.ErrIoUnit _) false])
      (match (fs.try-mkdir-if-missing (& package-source-binding-test-parent))
        [(io.OkIoUnit) true]
        [(io.ErrIoUnit _) false])
      (match (fs.try-mkdir-if-missing (& root))
        [(io.OkIoUnit) true]
        [(io.ErrIoUnit _) false]))))

(cfg
  test
  (define (package-source-binding-test-manifest) : compiler_load.CompilerPkgManifest
    (compiler_load.CompilerPkgManifest
      "binding-fixture"
      "1.0.0"
      compiler_load.CompilerPkgKindBin
      "a.tl"
      (compiler_load.compiler-pkg-deps-empty)
      (compiler_load.compiler-pkg-link-empty))))

(cfg
  test
  (define (package-source-binding-test-source-set-from-sources
    [root : String]
    [sources : svec.Vec]) : PackageSourceSet
    (PackageSourceSet
      (package-source-root-join root "typelisp.pkg")
      root
      (package-source-binding-test-manifest)
      sources)))

(cfg
  test
  (define (package-source-binding-test-source-set
    [root : String]
    [extra : bool]) : PackageSourceSet
    (let
      [sources : svec.Vec (svec.new)]
      (begin
        (svec.push (&mut sources) (package-source-root-join root "a.tl"))
        (svec.push (&mut sources) (package-source-root-join root "b.tl"))
        (if extra
          (svec.push (&mut sources) (package-source-root-join root "c.tl"))
          unit)
        (package-source-binding-test-source-set-from-sources root sources)))))

(cfg
  test
  (define (package-source-binding-test-pack
    [schema : i64]
    [payload : (__tl_dyn-array u8)]) : (__tl_dyn-array u8)
    (let
      [sections : (__tl_dyn-array tlci.TlciAuxSection)
        (make-array tlci.TlciAuxSection 1)]
      (begin
        (array-set!
          sections
          0
          (tlci.TlciAuxSection
            tlci.tlci-aux-kind-package-source-binding
            schema
            payload))
        (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
          [(tlci.ResultTlciAuxBytes.Ok packed) packed]
          [(tlci.ResultTlciAuxBytes.Err message) (io.panic message)])))))

(cfg
  test
  (define (package-source-binding-test-bound-pack [digest : i64]) : (__tl_dyn-array
      u8)
    (package-source-binding-test-pack
      tlci.tlci-package-source-binding-schema-version
      (let
        [payload : (__tl_dyn-array u8) (make-array u8 8)]
        (begin
          (tlci.tlci-set-u64! payload 0 digest)
          payload)))))

(cfg
  test
  (define (package-source-binding-test-digest [source-set : PackageSourceSet]) : i64
    (match (package-source-set-digest source-set)
      [(ResultPackageSourceDigest.Ok digest) digest]
      [(ResultPackageSourceDigest.Err message) (io.panic message)])))

(cfg
  test
  (test
    package-source-binding-transcript-and-admission
    (let
      [root : String (string.copy (& package-source-binding-test-root))]
      [a : String (package-source-root-join root "a.tl")]
      [b : String (package-source-root-join root "b.tl")]
      [c : String (package-source-root-join root "c.tl")]
      [setup : bool
        (and
          (package-source-binding-test-ensure-root root)
          (package-source-binding-test-write a "(a)\n")
          (package-source-binding-test-write b "(b)\n"))]
      (if (not setup)
        (io.panic "package-source: unable to create digest fixture")
        (let
          [source-set : PackageSourceSet
            (package-source-binding-test-source-set root false)]
          [alternate : PackageSourceSet
            (package-source-binding-test-source-set
              (string.copy (& package-source-binding-test-alternate-root))
              false)]
          [baseline : i64 0]
          [binding : (__tl_dyn-array u8) (tlci.tlci-empty-bytes)]
          (begin
            (match (package-source-set-digest source-set)
              [(ResultPackageSourceDigest.Ok digest) (set! baseline digest)]
              [(ResultPackageSourceDigest.Err message) (io.panic message)])
            (if (not (= baseline 1959683407))
              (io.panic "package-source: pinned digest mismatch")
              unit)
            (match (package-source-set-digest alternate)
              [(ResultPackageSourceDigest.Ok digest)
                (if (not (= digest baseline))
                  (io.panic
                    "package-source: alternate root spelling changed digest")
                  unit)]
              [(ResultPackageSourceDigest.Err message) (io.panic message)])
            (set! binding (package-source-binding-test-bound-pack baseline))
            (match (package-source-verify-binding source-set binding)
              [(PackageSourceBindingVerification.Match digest)
                (if (not (= digest baseline))
                  (io.panic "package-source: bound digest did not match")
                  unit)]
              [_ (io.panic "package-source: bound digest admission failed")])
            (if (not (package-source-binding-test-write a "(changed)\n"))
              (io.panic "package-source: unable to mutate digest fixture")
              unit)
            (match (package-source-set-digest source-set)
              [(ResultPackageSourceDigest.Ok digest)
                (if (= digest baseline)
                  (io.panic
                    "package-source: content mutation did not change digest")
                  unit)]
              [(ResultPackageSourceDigest.Err message) (io.panic message)])
            (if (not (package-source-binding-test-write a "(a)\n"))
              (io.panic "package-source: unable to restore digest fixture")
              unit)
            (if (not (package-source-binding-test-write c "(c)\n"))
              (io.panic "package-source: unable to add digest fixture")
              unit)
            (match (package-source-set-digest
              (package-source-binding-test-source-set root true))
              [(ResultPackageSourceDigest.Ok digest)
                (if (= digest baseline)
                  (io.panic "package-source: add source did not change digest")
                  unit)]
              [(ResultPackageSourceDigest.Err message) (io.panic message)])
            (match (package-source-verify-binding
              source-set
              (package-source-binding-test-bound-pack 12345))
              [(PackageSourceBindingVerification.Mismatch expected actual)
                (if (and (= expected baseline) (= actual 12345))
                  unit
                  (io.panic
                    "package-source: mismatch did not preserve expected/actual order"))]
              [_ (io.panic "package-source: mismatch admission failed")])
            (match (package-source-verify-binding
              source-set
              (tlci.tlci-empty-bytes))
              [(PackageSourceBindingVerification.MissingOrLegacy) unit]
              [_ (io.panic "package-source: missing binding admission failed")])
            (match (package-source-verify-binding
              source-set
              (package-source-binding-test-pack
                2
                (tlci.tlci-string->bytes "future")))
              [(PackageSourceBindingVerification.UnsupportedSchema schema)
                (if (= schema 2)
                  unit
                  (io.panic "package-source: unsupported schema changed"))]
              [_
                (io.panic
                  "package-source: unsupported binding admission failed")])
            (match (package-source-verify-binding
              source-set
              (package-source-binding-test-pack
                tlci.tlci-package-source-binding-schema-version
                (make-array u8 7)))
              [(PackageSourceBindingVerification.Malformed _) unit]
              [_
                (io.panic "package-source: malformed binding admission failed")])
            (match (package-source-verify-binding source-set binding)
              [(PackageSourceBindingVerification.Match _) unit]
              [_ (io.panic "package-source: restore did not recover digest")])
            (if (not (package-source-binding-test-write a "(a)\n"))
              (io.panic
                "package-source: unable to restore source before unreadable check")
              unit)
            (match (fs.try-remove-file (& a))
              [(io.OkIoUnit) unit]
              [(io.ErrIoUnit _)
                (io.panic "package-source: unable to delete fixture")])
            (match (package-source-verify-binding source-set binding)
              [(PackageSourceBindingVerification.Unreadable _) unit]
              [_ (io.panic "package-source: deleted source was not unreadable")])
            ;; Leave the ignored fixture in a restorable state for a rerun.
            (package-source-binding-test-write a "(a)\n")
            (fs.try-remove-file (& c))
            unit))))))

(cfg
  test
  (test
    package-source-binding-order-framing-and-rename
    (let
      [root : String (string.copy (& package-source-binding-test-root))]
      [a : String (package-source-root-join root "a.tl")]
      [b : String (package-source-root-join root "b.tl")]
      [renamed : String (package-source-root-join root "renamed.tl")]
      [collision-root : String (package-source-root-join root "collision")]
      [collision-a : String (package-source-root-join collision-root "a.tl")]
      [collision-b : String
        (package-source-root-join collision-root "a.tlb.tl")]
      [setup : bool
        (and
          (package-source-binding-test-ensure-root root)
          (match (fs.try-mkdir-if-missing (& collision-root))
            [(io.OkIoUnit) true]
            [(io.ErrIoUnit _) false])
          (package-source-binding-test-write a "(a)\n")
          (package-source-binding-test-write b "(b)\n")
          (package-source-binding-test-write collision-a "b.tlX")
          (package-source-binding-test-write collision-b "X"))]
      (if (not setup)
        (io.panic "package-source: unable to create ordering fixture")
        (let
          [baseline : i64
            (package-source-binding-test-digest
              (package-source-binding-test-source-set root false))]
          [reversed : svec.Vec (svec.new)]
          [duplicate : svec.Vec (svec.new)]
          [collision-left : svec.Vec (svec.new)]
          [collision-right : svec.Vec (svec.new)]
          [renamed-sources : svec.Vec (svec.new)]
          (begin
            (svec.push (&mut reversed) b)
            (svec.push (&mut reversed) a)
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                reversed))
              [(ResultPackageSourceDigest.Err _) unit]
              [_ (io.panic "package-source: reversed source list was accepted")])
            (svec.push (&mut duplicate) a)
            (svec.push (&mut duplicate) a)
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                duplicate))
              [(ResultPackageSourceDigest.Err _) unit]
              [_
                (io.panic "package-source: duplicate source list was accepted")])
            (svec.push (&mut collision-left) collision-a)
            (svec.push (&mut collision-right) collision-b)
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                collision-root
                collision-left))
              [(ResultPackageSourceDigest.Ok left)
                (match (package-source-set-digest
                  (package-source-binding-test-source-set-from-sources
                    collision-root
                    collision-right))
                  [(ResultPackageSourceDigest.Ok right)
                    (if (= left right)
                      (io.panic
                        "package-source: framed collision was not distinguished")
                      unit)]
                  [(ResultPackageSourceDigest.Err message) (io.panic message)])]
              [(ResultPackageSourceDigest.Err message) (io.panic message)])
            (package-source-binding-test-remove renamed)
            (match (fs.try-rename (& b) (& renamed))
              [(io.OkIoUnit) unit]
              [(io.ErrIoUnit _)
                (io.panic "package-source: rename fixture failed")])
            (svec.push (&mut renamed-sources) a)
            (svec.push (&mut renamed-sources) renamed)
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                renamed-sources))
              [(ResultPackageSourceDigest.Ok changed)
                (if (= changed baseline)
                  (io.panic "package-source: rename did not change digest")
                  unit)]
              [(ResultPackageSourceDigest.Err message) (io.panic message)])
            (match (fs.try-rename (& renamed) (& b))
              [(io.OkIoUnit) unit]
              [(io.ErrIoUnit _)
                (io.panic "package-source: rename restore failed")])
            (if (not
              (=
                (package-source-binding-test-digest
                  (package-source-binding-test-source-set root false))
                baseline))
              (io.panic "package-source: rename restoration changed digest")
              unit)
            unit))))))

(cfg
  test
  (test
    package-source-binding-discovery-exclusions-and-removal
    (let
      [root : String
        (str_cat.str-cat
          (string.copy (& package-source-binding-test-root))
          "/discover")]
      [manifest-path : String (package-source-root-join root "typelisp.pkg")]
      [a : String (package-source-root-join root "a.tl")]
      [b : String (package-source-root-join root "b.tl")]
      [target-root : String (package-source-root-join root "target")]
      [target-source : String
        (package-source-root-join target-root "ignored.tl")]
      [nested-root : String (package-source-root-join root "nested")]
      [nested-manifest : String
        (package-source-root-join nested-root "typelisp.pkg")]
      [nested-source : String
        (package-source-root-join nested-root "ignored.tl")]
      [setup : bool
        (and
          (package-source-binding-test-ensure-root
            (string.copy (& package-source-binding-test-root)))
          (match (fs.try-mkdir-if-missing (& root))
            [(io.OkIoUnit) true]
            [(io.ErrIoUnit _) false])
          (match (fs.try-mkdir-if-missing (& target-root))
            [(io.OkIoUnit) true]
            [(io.ErrIoUnit _) false])
          (match (fs.try-mkdir-if-missing (& nested-root))
            [(io.OkIoUnit) true]
            [(io.ErrIoUnit _) false])
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
          [outside : String (package-source-root-join root "../outside.tl")]
          (begin
            (svec.push (&mut target-sources) target-source)
            (svec.push (&mut nested-sources) nested-source)
            (svec.push (&mut outside-sources) outside)
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                empty-sources))
              [(ResultPackageSourceDigest.Err _) unit]
              [_ (io.panic "package-source: empty source set was accepted")])
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                target-sources))
              [(ResultPackageSourceDigest.Err _) unit]
              [_ (io.panic "package-source: target source was accepted")])
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                nested-sources))
              [(ResultPackageSourceDigest.Err _) unit]
              [_ (io.panic "package-source: nested source was accepted")])
            (match (package-source-set-digest
              (package-source-binding-test-source-set-from-sources
                root
                outside-sources))
              [(ResultPackageSourceDigest.Err _) unit]
              [_ (io.panic "package-source: outside source was accepted")])
            (match (package-source-discover-for "test" manifest-path true)
              [(ResultPackageSourceSet.Err message) (io.panic message)]
              [(ResultPackageSourceSet.Ok discovered)
                (begin
                  (set!
                    baseline
                    (package-source-binding-test-digest discovered))
                  (if (not (= baseline 1959683407))
                    (io.panic "package-source: discovery baseline mismatch")
                    unit))])
            (set! binding (package-source-binding-test-bound-pack baseline))
            (match (package-source-verify-binding-for
              "test"
              manifest-path
              true
              binding)
              [(PackageSourceBindingVerification.Match digest)
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
              manifest-path
              true
              binding)
              [(PackageSourceBindingVerification.Match _) unit]
              [_ (io.panic "package-source: excluded source changed digest")])
            (match (fs.try-remove-file (& b))
              [(io.OkIoUnit) unit]
              [(io.ErrIoUnit _)
                (io.panic "package-source: removal fixture failed")])
            (match (package-source-verify-binding-for
              "test"
              manifest-path
              true
              binding)
              [(PackageSourceBindingVerification.Mismatch expected actual)
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
              [(PackageSourceBindingVerification.Match _) unit]
              [_ (io.panic "package-source: restored discovery did not match")])))))))