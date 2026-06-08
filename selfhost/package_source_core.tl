;; package_source_core.tl - Shared package source discovery helpers (#1986).
;;
;; Package-wide tool commands should agree on which files belong to a package.
;; This module resolves a `typelisp.pkg` path, loads the manifest, and walks the
;; package root for regular `.tl` files in deterministic order. Hosts without
;; directory enumeration fall back to the manifest entry source.
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "../stdlib/fs.tl")

(import "../stdlib/io.tl")

(import "../stdlib/list.tl")

(import "../stdlib/string.tl")

(import "compiler_diagnostic.tl")

(import "compiler_load.tl")

(defstruct PackageSourceSet
  (manifest-path String)
  (manifest-dir String)
  (manifest CompilerPkgManifest)
  (sources StringList))

(defenum ResultPackageSourceSet
  (OkPackageSourceSet PackageSourceSet)
  (ErrPackageSourceSet String))

(defenum ResultPackageSourceList
  (OkPackageSourceList StringList)
  (ErrPackageSourceList String))

(define (package-source-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (package-source-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (package-source-string-less? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
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

(define (package-source-list-insert [items : StringList] [value : String]) : StringList
  (match items
    [(StringNil) (StringCons value (box StringNil))]
    [(StringCons head rest)
      (if (string-eq head value)
        items
        (if (package-source-string-less? value head)
          (StringCons value (box items))
          (StringCons
            head
            (box (package-source-list-insert (box-get rest) value)))))]))

(define (package-source-manifest-dir [manifest-path : String]) : String
  (let
    [dir : String (compiler-load-dirname manifest-path)]
    (if (= (string-length dir) 0)
      "."
      dir)))

(define (package-source-discover-manifest-up [prefix : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (string-append prefix "typelisp.pkg")]
      (if (file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (package-source-discover-manifest-up
          (string-append prefix "../")
          (- fuel 1))))))

(define (package-source-load-manifest [path : String]) : ResultPackageSourceSet
  (if (file-exists? path)
    (match (compiler-load-parse-manifest-diagnostic-infer-kind
      path
      (read-file path))
      [(ErrCompilerPkgManifestDiagnostic diag)
        (ErrPackageSourceSet
          (package-source-cat3
            "invalid package manifest '"
            (compiler-diagnostic-path diag)
            (string-append "': " (compiler-diagnostic-message diag))))]
      [(OkCompilerPkgManifestDiagnostic manifest)
        (OkPackageSourceSet
          (PackageSourceSet
            path
            (package-source-manifest-dir path)
            manifest
            (StringNil)))])
    (ErrPackageSourceSet
      (package-source-cat3 "cannot read package manifest '" path "'"))))

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
        (ErrPackageSourceSet
          (string-append
            command
            ": could not find typelisp.pkg from '.' or any parent directory"))]
      [(CompilerLoadSomePath path) (package-source-load-manifest path)])))

(define (package-source-relative-join [prefix : String] [name : String]) : String
  (if (= (string-length prefix) 0)
    name
    (compiler-load-join-root-path prefix name)))

(define (package-source-root-join [root : String] [relative : String]) : String
  (if (= (string-length relative) 0)
    root
    (compiler-load-join-root-path root relative)))

(define (package-source-internal-dir? [name : String]) : bool
  (or
    (string-eq name "target")
    (or
      (string-eq name ".git")
      (or
        (string-eq name ".hg")
        (or (string-eq name ".svn") (string-eq name ".jj"))))))

(define (package-source-dir-has-manifest? [dir : String]) : bool
  (file-exists? (compiler-load-join-root-path dir "typelisp.pkg")))

(define (package-source-tl-file? [path : String]) : bool
  (string-eq (fs-extension (& path)) "tl"))

(define (package-source-include-file? [path : String] [metadata : FsMetadata]) : bool
  (and
    (fs-file-kind-regular? (fs-metadata-kind metadata))
    (package-source-tl-file? path)))

(define (package-source-entry-error
  [command : String]
  [path : String]
  [error : IoError]) : ResultPackageSourceList
  (ErrPackageSourceList
    (package-source-cat3
      (string-append command ": failed to inspect package path '")
      path
      (string-append "': " (io-error-message error)))))

(define (package-source-read-dir-error
  [command : String]
  [path : String]
  [error : IoError]) : ResultPackageSourceList
  (ErrPackageSourceList
    (package-source-cat3
      (string-append command ": failed to read package directory '")
      path
      (string-append "': " (io-error-message error)))))

(define (package-source-entry-list [source-set : PackageSourceSet]) : StringList
  (let
    [manifest : CompilerPkgManifest (struct-get source-set manifest)]
    [entry : String
      (compiler-load-normalize-path
        (package-source-root-join
          (struct-get source-set manifest-dir)
          (struct-get manifest entry)))]
    (StringCons entry (box StringNil))))

(define (package-source-scan-dir
  [command : String]
  [root : String]
  [relative : String]
  [acc : StringList]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (try-read-dir (& dir))
      [(ErrIoStringList error)
        (package-source-read-dir-error command dir error)]
      [(OkIoStringList entries)
        (package-source-scan-entries command root relative entries acc)])))

(define (package-source-scan-optional-dir
  [command : String]
  [root : String]
  [relative : String]
  [acc : StringList]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (try-read-dir (& dir))
      [(ErrIoStringList error)
        (if (or (io-error-not-found? error) (io-error-unsupported? error))
          (OkPackageSourceList acc)
          (package-source-read-dir-error command dir error))]
      [(OkIoStringList entries)
        (package-source-scan-entries command root relative entries acc)])))

(define (package-source-scan-root
  [command : String]
  [source-set : PackageSourceSet]) : ResultPackageSourceList
  (let
    [root : String (struct-get source-set manifest-dir)]
    (match (try-read-dir (& root))
      [(ErrIoStringList error)
        (if (io-error-unsupported? error)
          (OkPackageSourceList (package-source-entry-list source-set))
          (package-source-read-dir-error command root error))]
      [(OkIoStringList entries)
        (package-source-scan-entries command root "" entries StringNil)])))

(define (package-source-scan-one
  [command : String]
  [root : String]
  [relative : String]
  [name : String]
  [acc : StringList]) : ResultPackageSourceList
  (if (package-source-internal-dir? name)
    (OkPackageSourceList acc)
    (let
      [child-relative : String (package-source-relative-join relative name)]
      [child-path : String (package-source-root-join root child-relative)]
      (match (try-file-metadata (& child-path))
        [(ErrFsMetadata error)
          (package-source-entry-error command child-path error)]
        [(OkFsMetadata metadata)
          (let
            [kind : FsFileKind (fs-metadata-kind metadata)]
            (core/cond
              (fs-file-kind-directory? kind)
              (if (package-source-dir-has-manifest? child-path)
                (OkPackageSourceList acc)
                (package-source-scan-dir command root child-relative acc))
              (package-source-include-file? child-path metadata)
              (OkPackageSourceList
                (package-source-list-insert
                  acc
                  (compiler-load-normalize-path child-path)))
              (OkPackageSourceList acc)))]))))

(define (package-source-scan-entries
  [command : String]
  [root : String]
  [relative : String]
  [entries : StringList]
  [acc : StringList]) : ResultPackageSourceList
  (match entries
    [(StringNil) (OkPackageSourceList acc)]
    [(StringCons name rest)
      (match (package-source-scan-one command root relative name acc)
        [(ErrPackageSourceList message) (ErrPackageSourceList message)]
        [(OkPackageSourceList next)
          (package-source-scan-entries
            command
            root
            relative
            (box-get rest)
            next)])]))

(define (package-source-discover-for
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]) : ResultPackageSourceSet
  (match (package-source-resolve-manifest command manifest-path has-manifest)
    [(ErrPackageSourceSet message) (ErrPackageSourceSet message)]
    [(OkPackageSourceSet base)
      (match (package-source-scan-root command base)
        [(ErrPackageSourceList message) (ErrPackageSourceSet message)]
        [(OkPackageSourceList sources)
          (if (= (string-list-count sources) 0)
            (ErrPackageSourceSet
              (package-source-cat3
                (string-append
                  command
                  ": no TypeLisp source files found in package '")
                (struct-get base manifest-path)
                "'"))
            (OkPackageSourceSet
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
    (package-source-scan-optional-dir command root "tests" StringNil)))

(define (package-source-discover [manifest-path : String] [has-manifest : bool]) : ResultPackageSourceSet
  (package-source-discover-for "check" manifest-path has-manifest))