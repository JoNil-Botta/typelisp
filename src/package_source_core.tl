;; package_source_core.tl - Shared package source discovery helpers.
;;
;; Package-wide tool commands should agree on which files belong to a package.
;; This module resolves a `typelisp.pkg` path, loads the manifest, and walks the
;; package root for regular `.tl` files in deterministic order. Package-local
;; `tests` directories are reserved for `typelisp test` and fixture corpora, so
;; ordinary package source discovery skips them. Hosts without directory
;; enumeration fall back to the manifest entry source.
(import stdlib.fs)
(import stdlib.io)
(import stdlib.vector)
(import (vector String) as svec)
(import stdlib.string)
(import "compiler_diagnostic.tl")
(import "compiler_load.tl")

(defstruct PackageSourceList
  (items svec.Vec))

(defstruct PackageSourceSet
  (manifest-path String)
  (manifest-dir String)
  (manifest CompilerPkgManifest)
  (sources PackageSourceList))

(defenum ResultPackageSourceSet
  (Ok PackageSourceSet)
  (Err String))

(defenum ResultPackageSourceList
  (Ok PackageSourceList)
  (Err String))

(define (package-source-list-from-vec [items : svec.Vec]) : PackageSourceList
  (PackageSourceList items))

(define (package-source-list-new) : PackageSourceList
  (package-source-list-from-vec (svec.new)))

(define (package-source-list-items [sources : PackageSourceList]) : svec.Vec
  (struct-get sources items))

(define (package-source-list-len [sources : PackageSourceList]) : i64
  (svec.len (& (struct-get sources items))))

(define (package-source-list-get
  [sources : PackageSourceList]
  [index : i64]
  [fallback : String]) : String
  (svec.get (& (struct-get sources items)) index fallback))

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
  [out : svec.Vec]
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
    [dir : String (compiler-load-dirname manifest-path)]
    (if (= (string.string-length dir) 0)
      "."
      dir)))

(define (package-source-discover-manifest-up [prefix : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (string.append prefix "typelisp.pkg")]
      (if (io.file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (package-source-discover-manifest-up
          (string.append prefix "../")
          (- fuel 1))))))

(define (package-source-load-manifest [path : String]) : ResultPackageSourceSet
  (if (io.file-exists? path)
    (match (compiler-load-parse-manifest-diagnostic-infer-kind
      path
      (io.read-file path))
      [(ResultCompilerPkgManifestDiagnostic.Err diag)
        (ResultPackageSourceSet.Err
          (string.concat3
            "invalid package manifest '"
            (compiler-diagnostic-path (box-get diag))
            (string.append "': " (compiler-diagnostic-message (box-get diag)))))]
      [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
        (ResultPackageSourceSet.Ok
          (PackageSourceSet
            path
            (package-source-manifest-dir path)
            manifest
            (package-source-list-new)))])
    (ResultPackageSourceSet.Err
      (string.concat3 "cannot read package manifest '" path "'"))))

(define (package-source-resolve-manifest
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]) : ResultPackageSourceSet
  (let
    [resolved : CompilerLoadMaybePath
      (if has-manifest
        (CompilerLoadSomePath manifest-path)
        (package-source-discover-manifest-up "" 256))]
    (match resolved
      [(CompilerLoadNoPath)
        (ResultPackageSourceSet.Err
          (string.append
            command
            ": could not find typelisp.pkg from '.' or any parent directory"))]
      [(CompilerLoadSomePath path) (package-source-load-manifest path)])))

(define (package-source-relative-join [prefix : String] [name : String]) : String
  (if (= (string.string-length prefix) 0)
    name
    (compiler-load-join-root-path prefix name)))

(define (package-source-root-join [root : String] [relative : String]) : String
  (if (= (string.string-length relative) 0)
    root
    (compiler-load-join-root-path root relative)))

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
  (io.file-exists? (compiler-load-join-root-path dir "typelisp.pkg")))

(define (package-source-tl-file? [path : String]) : bool
  (string.eq (fs.extension (& path)) "tl"))

(define (package-source-include-file?
  [path : String]
  [metadata : fs.FsMetadata]) : bool
  (and
    (fs.file-kind-regular? (fs.metadata-kind metadata))
    (package-source-tl-file? path)))

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

(define (package-source-entry-list [source-set : PackageSourceSet]) : PackageSourceList
  (let
    [manifest : CompilerPkgManifest (struct-get source-set manifest)]
    [entry : String
      (compiler-load-normalize-path
        (package-source-root-join
          (struct-get source-set manifest-dir)
          (struct-get manifest entry)))]
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut items) entry)
      (package-source-list-from-vec items))))

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
          (ResultPackageSourceList.Ok (package-source-list-from-vec acc))
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
    (ResultPackageSourceList.Ok (package-source-list-from-vec acc))
    (let
      [child-relative : String (package-source-relative-join relative name)]
      [child-path : String (package-source-root-join root child-relative)]
      (match (fs.try-file-metadata (& child-path))
        [(fs.ErrFsMetadata error)
          (package-source-entry-error command child-path error)]
        [(fs.OkFsMetadata metadata)
          (let
            [kind : fs.FsFileKind (fs.metadata-kind metadata)]
            (if (fs.file-kind-directory? kind)
              (if (package-source-dir-has-manifest? child-path)
                (ResultPackageSourceList.Ok (package-source-list-from-vec acc))
                (package-source-scan-dir command root child-relative acc))
              (if (package-source-include-file? child-path metadata)
                (ResultPackageSourceList.Ok
                  (package-source-list-from-vec
                    (package-source-vec-insert
                      acc
                      (compiler-load-normalize-path child-path))))
                (ResultPackageSourceList.Ok (package-source-list-from-vec acc)))))]))))

(define (package-source-scan-entries-from
  [command : String]
  [root : String]
  [relative : String]
  [entries : svec.Vec]
  [index : i64]
  [acc : svec.Vec]) : ResultPackageSourceList
  (if (>= index (svec.len (& entries)))
    (ResultPackageSourceList.Ok (package-source-list-from-vec acc))
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
          (package-source-list-items next))])))

(define (package-source-scan-entries
  [command : String]
  [root : String]
  [relative : String]
  [entries : svec.Vec]
  [acc : svec.Vec]) : ResultPackageSourceList
  (package-source-scan-entries-from command root relative entries 0 acc))

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
          (if (= (package-source-list-len sources) 0)
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