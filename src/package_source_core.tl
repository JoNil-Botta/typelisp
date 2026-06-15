;; package_source_core.tl - Shared package source discovery helpers (#1986).
;;
;; Package-wide tool commands should agree on which files belong to a package.
;; This module resolves a `typelisp.pkg` path, loads the manifest, and walks the
;; package root for regular `.tl` files in deterministic order. Package-local
;; `tests` directories are reserved for `typelisp test` and fixture corpora, so
;; ordinary package source discovery skips them. Hosts without directory
;; enumeration fall back to the manifest entry source.
(import stdlib.fs as fs_mod)

(import stdlib.io as io_mod)

(import stdlib.list as list_mod)

(import stdlib.vector as vector_mod)

(import stdlib.string as string_mod)

(import stdlib.str_cat)

(import "compiler_diagnostic.tl")

(import "compiler_load.tl")

(defstruct PackageSourceSet
  (manifest-path String)
  (manifest-dir String)
  (manifest CompilerPkgManifest)
  (sources vector_mod.StringVec))

(defenum ResultPackageSourceSet
  (OkPackageSourceSet PackageSourceSet)
  (ErrPackageSourceSet String))

(defenum ResultPackageSourceList
  (OkPackageSourceList vector_mod.StringVec)
  (ErrPackageSourceList String))

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

(define (package-source-vec-insert-slot-from
  [items : vector_mod.StringVec]
  [value : String]
  [index : i64]) : i64
  (if (>= index (vector_mod.string-vec-len items))
    index
    (let
      [head : String (vector_mod.string-vec-get items index "")]
      (if (string_mod.string-eq head value)
        -1
        (if (package-source-string-less? value head)
          index
          (package-source-vec-insert-slot-from items value (+ index 1)))))))

(define (package-source-vec-insert-at
  [items : vector_mod.StringVec]
  [value : String]
  [slot : i64]) : vector_mod.StringVec
  (let
    [out : vector_mod.StringVec (vector_mod.string-vec-push items value)]
    [slots : (Array String) (vector_mod.string-vec-slots out)]
    [i : i64 (- (vector_mod.string-vec-len out) 1)]
    (begin
      (while (> i slot)
        (begin
          (array-set! slots i (array-ref slots (- i 1)))
          (set! i (- i 1))))
      (array-set! slots slot value)
      out)))

(define (package-source-vec-insert
  [items : vector_mod.StringVec]
  [value : String]) : vector_mod.StringVec
  (let
    [slot : i64 (package-source-vec-insert-slot-from items value 0)]
    (if (< slot 0)
      items
      (package-source-vec-insert-at items value slot))))

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
      [candidate : String (string_mod.string-append prefix "typelisp.pkg")]
      (if (io_mod.file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (package-source-discover-manifest-up
          (string_mod.string-append prefix "../")
          (- fuel 1))))))

(define (package-source-load-manifest [path : String]) : ResultPackageSourceSet
  (if (io_mod.file-exists? path)
    (match (compiler-load-parse-manifest-diagnostic-infer-kind
      path
      (io_mod.read-file path))
      [(ErrCompilerPkgManifestDiagnostic diag)
        (ErrPackageSourceSet
          (str_cat.str-cat
            "invalid package manifest '"
            (compiler-diagnostic-path diag)
            (string_mod.string-append "': " (compiler-diagnostic-message diag))))]
      [(OkCompilerPkgManifestDiagnostic manifest)
        (OkPackageSourceSet
          (PackageSourceSet
            path
            (package-source-manifest-dir path)
            manifest
            (vector_mod.string-vec-new)))])
    (ErrPackageSourceSet
      (str_cat.str-cat "cannot read package manifest '" path "'"))))

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
          (string_mod.string-append
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
    (string_mod.string-eq name "target")
    (string_mod.string-eq name ".git")
    (string_mod.string-eq name ".hg")
    (string_mod.string-eq name ".svn")
    (string_mod.string-eq name ".jj")))

(define (package-source-test-dir? [name : String]) : bool
  (string_mod.string-eq name "tests"))

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
    (io_mod.panic "package-source: skip-dir self-test mismatch")))

(define (package-source-vec-insert-self-test?) : bool
  (let
    [items : vector_mod.StringVec
      (package-source-vec-insert
        (package-source-vec-insert
          (package-source-vec-insert
            (package-source-vec-insert (vector_mod.string-vec-new) "src/z.tl")
            "src/a.tl")
          "src/m.tl")
        "src/a.tl")]
    (and
      (= (vector_mod.string-vec-len items) 3)
      (string_mod.string-eq (vector_mod.string-vec-get items 0 "") "src/a.tl")
      (string_mod.string-eq (vector_mod.string-vec-get items 1 "") "src/m.tl")
      (string_mod.string-eq (vector_mod.string-vec-get items 2 "") "src/z.tl"))))

(test
  package-source-vector-insert-sorts-and-dedups
  (if (package-source-vec-insert-self-test?)
    unit
    (io_mod.panic "package-source: vector insert self-test mismatch")))

(define (package-source-dir-has-manifest? [dir : String]) : bool
  (io_mod.file-exists? (compiler-load-join-root-path dir "typelisp.pkg")))

(define (package-source-tl-file? [path : String]) : bool
  (string_mod.string-eq (fs_mod.fs-extension (& path)) "tl"))

(define (package-source-include-file?
  [path : String]
  [metadata : fs_mod.FsMetadata]) : bool
  (and
    (fs_mod.fs-file-kind-regular? (fs_mod.fs-metadata-kind metadata))
    (package-source-tl-file? path)))

(define (package-source-entry-error
  [command : String]
  [path : String]
  [error : io_mod.IoError]) : ResultPackageSourceList
  (ErrPackageSourceList
    (str_cat.str-cat
      (string_mod.string-append command ": failed to inspect package path '")
      path
      (string_mod.string-append "': " (io_mod.io-error-message error)))))

(define (package-source-read-dir-error
  [command : String]
  [path : String]
  [error : io_mod.IoError]) : ResultPackageSourceList
  (ErrPackageSourceList
    (str_cat.str-cat
      (string_mod.string-append command ": failed to read package directory '")
      path
      (string_mod.string-append "': " (io_mod.io-error-message error)))))

(define (package-source-entry-vec [source-set : PackageSourceSet]) : vector_mod.StringVec
  (let
    [manifest : CompilerPkgManifest (struct-get source-set manifest)]
    [entry : String
      (compiler-load-normalize-path
        (package-source-root-join
          (struct-get source-set manifest-dir)
          (struct-get manifest entry)))]
    (vector_mod.string-vec-push (vector_mod.string-vec-new) entry)))

(define (package-source-scan-dir
  [command : String]
  [root : String]
  [relative : String]
  [acc : vector_mod.StringVec]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (fs_mod.try-read-dir (& dir))
      [(fs_mod.ErrIoStringList error)
        (package-source-read-dir-error command dir error)]
      [(fs_mod.OkIoStringList entries)
        (package-source-scan-entries command root relative entries acc)])))

(define (package-source-scan-optional-dir
  [command : String]
  [root : String]
  [relative : String]
  [acc : vector_mod.StringVec]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (fs_mod.try-read-dir (& dir))
      [(fs_mod.ErrIoStringList error)
        (if (or
          (io_mod.io-error-not-found? error)
          (io_mod.io-error-unsupported? error))
          (OkPackageSourceList acc)
          (package-source-read-dir-error command dir error))]
      [(fs_mod.OkIoStringList entries)
        (package-source-scan-entries command root relative entries acc)])))

(define (package-source-scan-root
  [command : String]
  [source-set : PackageSourceSet]) : ResultPackageSourceList
  (let
    [root : String (struct-get source-set manifest-dir)]
    (match (fs_mod.try-read-dir (& root))
      [(fs_mod.ErrIoStringList error)
        (if (io_mod.io-error-unsupported? error)
          (OkPackageSourceList (package-source-entry-vec source-set))
          (package-source-read-dir-error command root error))]
      [(fs_mod.OkIoStringList entries)
        (package-source-scan-entries
          command
          root
          ""
          entries
          (vector_mod.string-vec-new))])))

(define (package-source-scan-one
  [command : String]
  [root : String]
  [relative : String]
  [name : String]
  [acc : vector_mod.StringVec]) : ResultPackageSourceList
  (if (package-source-skip-dir? name)
    (OkPackageSourceList acc)
    (let
      [child-relative : String (package-source-relative-join relative name)]
      [child-path : String (package-source-root-join root child-relative)]
      (match (fs_mod.try-file-metadata (& child-path))
        [(fs_mod.ErrFsMetadata error)
          (package-source-entry-error command child-path error)]
        [(fs_mod.OkFsMetadata metadata)
          (let
            [kind : fs_mod.FsFileKind (fs_mod.fs-metadata-kind metadata)]
            (if (fs_mod.fs-file-kind-directory? kind)
              (if (package-source-dir-has-manifest? child-path)
                (OkPackageSourceList acc)
                (package-source-scan-dir command root child-relative acc))
              (if (package-source-include-file? child-path metadata)
                (OkPackageSourceList
                  (package-source-vec-insert
                    acc
                    (compiler-load-normalize-path child-path)))
                (OkPackageSourceList acc))))]))))

(define (package-source-scan-entries
  [command : String]
  [root : String]
  [relative : String]
  [entries : list_mod.StringList]
  [acc : vector_mod.StringVec]) : ResultPackageSourceList
  (match entries
    [(list_mod.StringNil) (OkPackageSourceList acc)]
    [(list_mod.StringCons name rest)
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
          (if (= (vector_mod.string-vec-len sources) 0)
            (ErrPackageSourceSet
              (str_cat.str-cat
                (string_mod.string-append
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
    (package-source-scan-optional-dir
      command
      root
      "tests"
      (vector_mod.string-vec-new))))

(define (package-source-discover [manifest-path : String] [has-manifest : bool]) : ResultPackageSourceSet
  (package-source-discover-for "check" manifest-path has-manifest))