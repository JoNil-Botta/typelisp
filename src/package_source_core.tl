;; package_source_core.tl - Shared package source discovery helpers.
;;
;; Package-wide tool commands should agree on which files belong to a package.
;; This module resolves a `typelisp.pkg` path, loads the manifest, and walks the
;; package root for regular `.tl` files in deterministic order. Package-local
;; `tests` directories are reserved for `typelisp test` and fixture corpora, so
;; ordinary package source discovery skips them. Hosts without directory
;; enumeration fall back to the manifest entry source.
(import compiler_owned_view as owned_view)
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
(import package_lock_core)

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

;; A fetched checkout is an authority boundary, not merely a lexical prefix.
;; Callers must validate a package-controlled path without following symbolic
;; links or Windows reparse points before any later API is allowed to open it.
(defenum ResultPackageSourceConfinedPath
  (Ok String)
  (Err String))

(defenum PackageSourceConfinedPathKind
  (File)
  (Directory)
  (Any))

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

(define (package-source-char-code-at [text : (& text str)] [idx : i64]) : i64
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
      (< left-len right-len))))

(define (package-source-vec-insert-slot-from
  [items : (& items svec.Vec)]
  [value : String]
  [index : i64]) : i64
  (if (>= index (svec.len (& items)))
    index
    (let
      [head : String (svec.get (& items) index "")]
      (if (string.eq head value)
        -1
        (if (package-source-string-less?
          (owned_view.compiler-owned-shared-view value)
          head)
          index
          (package-source-vec-insert-slot-from items value (+ index 1)))))))

(define (package-source-vec-copy-range
  [items : (& items svec.Vec)]
  [out : svec.Vec]
  [start : i64]
  [end : i64]) : svec.Vec
  (let
    [idx : i64 start]
    [cur : svec.Vec out]
    (while (< idx end)
      (svec.push-ref! (&mut cur) (svec.get (& items) idx ""))
      (set! idx (+ idx 1)))
    cur))

(define (package-source-vec-insert-at
  [items : svec.Vec]
  [value : String]
  [slot : i64]) : svec.Vec
  (let
    [out : svec.Vec (svec.with-capacity (+ (svec.len (& items)) 1))]
    (set! out (package-source-vec-copy-range items out 0 slot))
    (svec.push-ref! (&mut out) value)
    (set!
      out
      (package-source-vec-copy-range items out slot (svec.len (& items))))
    out))

(define (package-source-vec-insert [items : svec.Vec] [value : String]) : svec.Vec
  (let
    [slot : i64
      (package-source-vec-insert-slot-from
        items
        (owned_view.compiler-owned-shared-view value)
        0)]
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
    (CompilerLoadNoPath)
    (let
      [candidate : String
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view prefix)
          "typelisp.pkg")]
      (if (io.file-exists? (owned_view.compiler-owned-shared-view candidate))
        (CompilerLoadSomePath candidate)
        (package-source-discover-manifest-up
          (str_cat.str-cat prefix "../")
          (- fuel 1))))))

(define (package-source-load-manifest [path : String]) : ResultPackageSourceSet
  (if (io.file-exists? (owned_view.compiler-owned-shared-view path))
    (match (compiler_load.compiler-load-parse-manifest-diagnostic-infer-kind
      (owned_view.compiler-owned-shared-view path)
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view path))))
      [(Err diag)
        (Err
          (str_cat.str-cat
            "invalid package manifest '"
            (compiler_diagnostic.compiler-diagnostic-path (__tl-box-place diag))
            "': "
            (compiler_diagnostic.compiler-diagnostic-message
              (__tl-box-place diag))))]
      [(Ok manifest)
        (Ok
          (PackageSourceSet
            (owned_view.compiler-owned-shared-view path)
            (package-source-manifest-dir path)
            manifest
            (svec.new)))])
    (Err (str_cat.str-cat "cannot read package manifest '" path "'"))))

(define (package-source-resolve-manifest
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]) : ResultPackageSourceSet
  (let
    [resolved : compiler_load.CompilerLoadMaybePath
      (if has-manifest
        (CompilerLoadSomePath manifest-path)
        (package-source-discover-manifest-up "" 256))]
    (match resolved
      [(CompilerLoadNoPath)
        (Err
          (str_cat.str-cat
            command
            ": could not find typelisp.pkg from '.' or any parent directory"))]
      [(CompilerLoadSomePath path) (package-source-load-manifest path)])))

(define (package-source-relative-join
  [prefix : (& prefix str)]
  [name : (& name str)]) : String
  (if (= (string.string-length prefix) 0)
    (string.copy name)
    (compiler_load.compiler-load-join-root-path
      (string.copy prefix)
      (string.copy name))))

(define (package-source-root-join
  [root : (& root str)]
  [relative : (& relative str)]) : String
  (if (= (string.string-length relative) 0)
    (string.copy root)
    (compiler_load.compiler-load-join-root-path
      (string.copy root)
      (string.copy relative))))

(define (package-source-fetched-boundary-message
  [package-name : String]
  [field : String]
  [requested : String]
  [checkout-root : String]) : String
  (str_cat.str-cat
    "build: fetched package `"
    package-name
    "` field `"
    field
    "` path `"
    requested
    "` is not confined to locked checkout `"
    checkout-root
    "`"))

(define (package-source-confined-kind-ok?
  [kind : fs.FsFileKind]
  [expected : PackageSourceConfinedPathKind]) : bool
  (match expected
    [(File) (fs.file-kind-regular? kind)]
    [(Directory) (fs.file-kind-directory? kind)]
    [(Any) (or (fs.file-kind-regular? kind) (fs.file-kind-directory? kind))]))

(define (package-source-confined-existing-path-from
  [package-name : String]
  [field : String]
  [requested : String]
  [checkout-root : String]
  [normalized : (& normalized str)]
  [cursor : i64]
  [prefix : String]
  [expected : PackageSourceConfinedPathKind]) : ResultPackageSourceConfinedPath
  (let
    [n : i64 (string.string-length normalized)]
    [separator : i64 (package-source-relative-separator normalized cursor n)]
    [segment : String (string.substring normalized cursor (- separator cursor))]
    [next-prefix : String (package-source-relative-join prefix segment)]
    [candidate : String (package-source-root-join checkout-root next-prefix)]
    [last : bool (>= separator n)]
    (match (fs.try-file-kind-no-follow (& candidate))
      [(ErrFsFileKind _)
        (Err
          (package-source-fetched-boundary-message
            package-name
            field
            requested
            checkout-root))]
      [(OkFsFileKind kind)
        (if (if last
          (package-source-confined-kind-ok? kind expected)
          (fs.file-kind-directory? kind))
          (if last
            (Ok candidate)
            (package-source-confined-existing-path-from
              package-name
              field
              requested
              checkout-root
              normalized
              (+ separator 1)
              next-prefix
              expected))
          (Err
            (package-source-fetched-boundary-message
              package-name
              field
              requested
              checkout-root)))])))

;; Resolve one package-controlled suffix below a fetched checkout. Every path
;; segment must already exist and be an ordinary directory or regular file;
;; links/reparse points and missing components fail with the same deterministic
;; boundary diagnostic, so an outside target is never probed.
(define (package-source-confined-existing-path
  [package-name : String]
  [field : String]
  [requested : String]
  [checkout-root : String]
  [expected : PackageSourceConfinedPathKind]) : ResultPackageSourceConfinedPath
  (let
    [normalized-root : String
      (compiler_load.compiler-load-normalize-path checkout-root)]
    [normalized-request : String (fs.path-normalize (& requested))]
    (if (not (fs.path-safe-relative? (& requested)))
      (Err
        (package-source-fetched-boundary-message
          package-name
          field
          requested
          normalized-root))
      (match (fs.try-file-kind-no-follow (& normalized-root))
        [(ErrFsFileKind _)
          (Err
            (package-source-fetched-boundary-message
              package-name
              field
              requested
              normalized-root))]
        [(OkFsFileKind root-kind)
          (if (fs.file-kind-directory? root-kind)
            (package-source-confined-existing-path-from
              package-name
              field
              requested
              normalized-root
              normalized-request
              0
              ""
              expected)
            (Err
              (package-source-fetched-boundary-message
                package-name
                field
                requested
                normalized-root)))]))))

(define (package-source-confined-existing-file
  [package-name : String]
  [field : String]
  [requested : String]
  [checkout-root : String]) : ResultPackageSourceConfinedPath
  (package-source-confined-existing-path
    package-name
    field
    requested
    checkout-root
    (File)))

(define (package-source-fetched-checkout-audit-entry
  [package-name : String]
  [checkout-root : String]
  [relative : (& relative str)]
  [name : String]) : ResultPackageSourceConfinedPath
  ;; The checkout implementation owns the root `.git` directory; it is not a
  ;; package-controlled input. A nested `.git` remains subject to the audit.
  (if (and (string.eq relative "") (string.eq name ".git"))
    (Ok checkout-root)
    (let
      [child-relative : String (package-source-relative-join relative name)]
      [child : String (package-source-root-join checkout-root child-relative)]
      (match (fs.try-file-kind-no-follow (& child))
        [(ErrFsFileKind _)
          (Err
            (package-source-fetched-boundary-message
              package-name
              "checkout path"
              child-relative
              checkout-root))]
        [(OkFsFileKind kind)
          (if (fs.file-kind-directory? kind)
            (package-source-fetched-checkout-audit-dir
              package-name
              checkout-root
              child-relative)
            (if (fs.file-kind-regular? kind)
              (Ok child)
              (Err
                (package-source-fetched-boundary-message
                  package-name
                  "checkout path"
                  child-relative
                  checkout-root))))]))))

(define (package-source-fetched-checkout-audit-entries-from
  [package-name : String]
  [checkout-root : String]
  [relative : (& relative str)]
  [entries : svec.Vec]
  [index : i64]) : ResultPackageSourceConfinedPath
  (if (>= index (svec.len (& entries)))
    (Ok checkout-root)
    (match (package-source-fetched-checkout-audit-entry
      (owned_view.compiler-owned-shared-view package-name)
      (owned_view.compiler-owned-shared-view checkout-root)
      relative
      (svec.get (& entries) index ""))
      [(Err message) (Err message)]
      [(Ok _)
        (package-source-fetched-checkout-audit-entries-from
          package-name
          checkout-root
          relative
          entries
          (+ index 1))])))

(define (package-source-fetched-checkout-audit-dir
  [package-name : String]
  [checkout-root : String]
  [relative : String]) : ResultPackageSourceConfinedPath
  (let
    [dir : String (package-source-root-join checkout-root relative)]
    (match (fs.try-read-dir (& dir))
      [(ErrIoStringVector _)
        (Err
          (package-source-fetched-boundary-message
            package-name
            "checkout path"
            (if (string.eq relative "")
              "."
              relative)
            checkout-root))]
      [(OkIoStringVector entries)
        (package-source-fetched-checkout-audit-entries-from
          package-name
          checkout-root
          relative
          (package-source-sort-entries entries)
          0)])))

;; Refuse any package-controlled symbolic link, junction, reparse point, or
;; other special filesystem object before graph loading starts. This is a
;; conservative physical-containment proof: ordinary in-checkout layouts and
;; normalized `..` segments remain valid, while links are never followed.
(define (package-source-fetched-checkout-audit
  [package-name : String]
  [checkout-root : String]) : ResultPackageSourceConfinedPath
  (let
    [normalized-root : String
      (compiler_load.compiler-load-normalize-path checkout-root)]
    (match (fs.try-file-kind-no-follow (& normalized-root))
      [(ErrFsFileKind _)
        (Err
          (package-source-fetched-boundary-message
            package-name
            "checkout root"
            "."
            normalized-root))]
      [(OkFsFileKind kind)
        (if (fs.file-kind-directory? kind)
          (package-source-fetched-checkout-audit-dir
            package-name
            normalized-root
            "")
          (Err
            (package-source-fetched-boundary-message
              package-name
              "checkout root"
              "."
              normalized-root)))])))

(define (package-source-internal-dir? [name : (& name str)]) : bool
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

(define (package-source-sort-entries-from
  [entries : (& entries fs.FsStringVector)]
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

(define (package-source-dir-has-manifest? [dir : String]) : bool
  (io.file-exists?
    (compiler_load.compiler-load-join-root-path dir "typelisp.pkg")))

(define (package-source-tl-file? [path : (& path str)]) : bool
  (string.eq (fs.extension path) "tl"))

(define (package-source-include-kind?
  [path : (& path str)]
  [kind : fs.FsFileKind]) : bool
  (and (fs.file-kind-regular? kind) (package-source-tl-file? path)))

(define (package-source-entry-error
  [command : String]
  [path : String]
  [error : io.IoError]) : ResultPackageSourceList
  (Err
    (str_cat.str-cat
      command
      ": failed to inspect package path '"
      path
      "': "
      (io.error-message error))))

(define (package-source-read-dir-error
  [command : String]
  [path : String]
  [error : io.IoError]) : ResultPackageSourceList
  (Err
    (str_cat.str-cat
      command
      ": failed to read package directory '"
      path
      "': "
      (io.error-message error))))

(define (package-source-entry-list [source-set : PackageSourceSet]) : svec.Vec
  (let
    [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
    [entry : String
      (compiler_load.compiler-load-normalize-path
        (package-source-root-join source-set.manifest-dir manifest.entry))]
    [items : svec.Vec (svec.new)]
    (svec.push-ref! (&mut items) entry)
    items))

(define (package-source-scan-dir
  [command : String]
  [root : (& root str)]
  [relative : String]
  [acc : svec.Vec]) : ResultPackageSourceList
  (let
    [dir : String (package-source-root-join root relative)]
    (match (fs.try-read-dir (& dir))
      [(ErrIoStringVector error)
        (package-source-read-dir-error command dir error)]
      [(OkIoStringVector entries)
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
      [(ErrIoStringVector error)
        (if (or
          (io.error-not-found? (owned_view.compiler-owned-shared-view error))
          (io.error-unsupported? (owned_view.compiler-owned-shared-view error)))
          (ResultPackageSourceList.Ok acc)
          (package-source-read-dir-error command dir error))]
      [(OkIoStringVector entries)
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
    [root : String
      (owned_view.compiler-owned-shared-view source-set.manifest-dir)]
    (match (fs.try-read-dir (& root))
      [(ErrIoStringVector error)
        (if (io.error-unsupported?
          (owned_view.compiler-owned-shared-view error))
          (ResultPackageSourceList.Ok (package-source-entry-list source-set))
          (package-source-read-dir-error command root error))]
      [(OkIoStringVector entries)
        (package-source-scan-entries
          command
          root
          ""
          (package-source-sort-entries entries)
          (svec.new))])))

;; Classify one listed entry from its no-follow inspection. The listing and
;; the inspection are separate syscalls, so another process may remove the
;; entry in between (a concurrent lock writer renames its stage sibling away):
;; not-found means "vanished since listing" and contributes nothing. Every
;; other inspection failure stays fatal. A source file that vanishes after it
;; was selected still fails when it is read.
(define (package-source-scan-kind
  [command : String]
  [root : (& root str)]
  [child-relative : String]
  [child-path : String]
  [inspected : fs.ResultFsFileKind]
  [acc : svec.Vec]) : ResultPackageSourceList
  (match inspected
    [(ErrFsFileKind error)
      (if (io.error-not-found? (owned_view.compiler-owned-shared-view error))
        (ResultPackageSourceList.Ok acc)
        (package-source-entry-error command child-path error))]
    [(OkFsFileKind kind)
      (if (fs.file-kind-directory? kind)
        (if (package-source-dir-has-manifest? child-path)
          (ResultPackageSourceList.Ok acc)
          (package-source-scan-dir command root child-relative acc))
        (if (package-source-include-kind? child-path kind)
          (ResultPackageSourceList.Ok
            (package-source-vec-insert
              acc
              (compiler_load.compiler-load-normalize-path child-path)))
          (ResultPackageSourceList.Ok acc)))]))

;; Names are classified before any inspection: skipped directories and lock
;; stage siblings (at any depth, whatever their kind) are never inspected.
(define (package-source-scan-one
  [command : String]
  [root : (& root str)]
  [relative : (& relative str)]
  [name : String]
  [acc : svec.Vec]) : ResultPackageSourceList
  (if (or
    (package-source-skip-dir? (owned_view.compiler-owned-shared-view name))
    (package_lock_core.package-lock-stage-name? (& name)))
    (ResultPackageSourceList.Ok acc)
    (let
      [child-relative : String (package-source-relative-join relative name)]
      [child-path : String (package-source-root-join root child-relative)]
      ;; Do not follow symbolic links or Windows reparse points. Package and
      ;; workspace discovery must stay inside the lexical root and a directory
      ;; link back to an ancestor must not turn traversal into a cycle.
      [inspected : fs.ResultFsFileKind
        (fs.try-file-kind-no-follow (& child-path))]
      (package-source-scan-kind
        command
        root
        child-relative
        child-path
        inspected
        acc))))

(define (package-source-scan-entries-from
  [command : String]
  [root : (& root str)]
  [relative : (& relative str)]
  [entries : svec.Vec]
  [index : i64]
  [acc : svec.Vec]) : ResultPackageSourceList
  (if (>= index (svec.len (& entries)))
    (ResultPackageSourceList.Ok acc)
    (match (package-source-scan-one
      (owned_view.compiler-owned-shared-view command)
      root
      relative
      (svec.get (& entries) index "")
      acc)
      [(Err message) (Err message)]
      [(Ok next)
        (package-source-scan-entries-from
          command
          root
          relative
          entries
          (+ index 1)
          next)])))

(define (package-source-scan-entries
  [command : String]
  [root : (& root str)]
  [relative : String]
  [entries : svec.Vec]
  [acc : svec.Vec]) : ResultPackageSourceList
  (package-source-scan-entries-from command root relative entries 0 acc))

;; Discover ordinary package-style TypeLisp sources below an explicit root.
;; Unlike `package-source-discover-for`, this does not require or parse a
;; manifest at the root. It exists for tooling such as the LSP workspace index
;; that receives roots from its protocol while still needing exactly the same
;; deterministic traversal, exclusion, regular-file, and nested-package rules.
(define (package-source-discover-root-for
  [command : String]
  [root : (& root str)]) : ResultPackageSourceList
  (let
    [normalized-root : String (compiler_load.compiler-load-normalize-path root)]
    (match (fs.try-read-dir (& normalized-root))
      [(ErrIoStringVector error)
        (package-source-read-dir-error command normalized-root error)]
      [(OkIoStringVector entries)
        (package-source-scan-entries
          command
          normalized-root
          ""
          (package-source-sort-entries entries)
          (svec.new))])))

;; Return the next normalized path-separator position, or `end`.
(define (package-source-relative-separator
  [relative : (& relative str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [index : i64 start]
    (while (and
      (< index end)
      (not (fs.path-separator? (string.string-ref relative index))))
      (set! index (+ index 1)))
    index))

;; Check the directory segments that lead to one source. The root's own
;; manifest is allowed; a manifest below it is a nested-package boundary.
(define (package-source-relative-parent-eligible?
  [root : (& root str)]
  [relative : (& relative str)]) : bool
  (let
    [end : i64 (fs.last-separator-index relative)]
    [cursor : i64 0]
    [prefix : String ""]
    [eligible : bool true]
    (while (and eligible (>= end 0) (< cursor end))
      (let
        [separator : i64
          (package-source-relative-separator relative cursor end)]
        [name : String (string.substring relative cursor (- separator cursor))]
        (if (or
          (= (string.string-length name) 0)
          (package-source-skip-dir?
            (owned_view.compiler-owned-shared-view name)))
          (set! eligible false)
          (let
            [next-prefix : String (package-source-relative-join prefix name)]
            [parent : String (package-source-root-join root next-prefix)]
            (set! prefix next-prefix)
            ;; Match recursive discovery: every parent must be a real
            ;; directory, never a symlink or Windows reparse point.
            (match (fs.try-file-kind-no-follow (& parent))
              [(ErrFsFileKind _) (set! eligible false)]
              [(OkFsFileKind kind)
                (if (and
                  (fs.file-kind-directory? kind)
                  (not (package-source-dir-has-manifest? parent)))
                  unit
                  (set! eligible false))])))
        (set! cursor (+ separator 1))))
    eligible))

;; Parent-policy half of the single-path check. This intentionally does not
;; require the file itself to exist so an unsaved open document can still be
;; associated with its workspace root.
(define (package-source-path-location-eligible-for-root?
  [root : (& root str)]
  [path : (& path str)]) : bool
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
(define (package-source-path-eligible-for-root?
  [root : (& root str)]
  [path : (& path str)]) : bool
  (let
    [normalized-path : String (compiler_load.compiler-load-normalize-path path)]
    (and
      (package-source-path-location-eligible-for-root? root normalized-path)
      (match (fs.try-file-kind-no-follow (& normalized-path))
        [(OkFsFileKind kind)
          (package-source-include-kind? normalized-path kind)]
        [(ErrFsFileKind _) false]))))

(define (package-source-discover-for
  [command : String]
  [manifest-path : String]
  [has-manifest : bool]) : ResultPackageSourceSet
  (match (package-source-resolve-manifest
    (owned_view.compiler-owned-shared-view command)
    manifest-path
    has-manifest)
    [(Err message) (Err message)]
    [(Ok base)
      (match (package-source-scan-root
        (owned_view.compiler-owned-shared-view command)
        (owned_view.compiler-owned-shared-view base))
        [(Err message) (Err message)]
        [(Ok sources)
          (if (= (svec.len (& sources)) 0)
            (Err
              (str_cat.str-cat
                command
                ": no TypeLisp source files found in package '"
                base.manifest-path
                "'"))
            (Ok
              (PackageSourceSet
                base.manifest-path
                base.manifest-dir
                base.manifest
                sources)))])]))

(define (package-source-discover-tests-for
  [command : String]
  [source-set : PackageSourceSet]) : ResultPackageSourceList
  (let
    [root : String source-set.manifest-dir]
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
    (while (< index 8)
      (set!
        next
        (package-source-binding-hash-byte next (shr value (* index 8))))
      (set! index (+ index 1)))
    next))

(define (package-source-binding-hash-string [hash : i64] [text : String]) : i64
  (let
    [next : i64 hash]
    [index : i64 0]
    [count : i64 (string.string-length text)]
    (while (< index count)
      (set!
        next
        (package-source-binding-hash-byte
          next
          (cast (string.string-ref text index) : i64)))
      (set! index (+ index 1)))
    next))

(define (package-source-binding-hash-bytes
  [hash : i64]
  [bytes : (__tl_dyn-array u8)]) : i64
  (let
    [next : i64 hash]
    [index : i64 0]
    [count : i64 (array-length bytes)]
    (while (< index count)
      (set!
        next
        (package-source-binding-hash-byte
          next
          (cast (array-ref bytes index) : i64)))
      (set! index (+ index 1)))
    next))

(define (package-source-binding-relative-path
  [root : (& root str)]
  [path : (& path str)]) : String
  (let
    [normalized-root : String (compiler_load.compiler-load-normalize-path root)]
    [normalized-path : String (compiler_load.compiler-load-normalize-path path)]
    [relative : String
      (if (= normalized-root ".")
        (owned_view.compiler-owned-shared-view normalized-path)
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
    source-set.manifest-path
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
    [sources : svec.Vec
      (owned_view.compiler-owned-shared-view source-set.sources)]
    [root : String
      (compiler_load.compiler-load-normalize-path source-set.manifest-dir)]
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
                (owned_view.compiler-owned-shared-view source-set)
                path
                "source path is not a safe nonempty relative path under package root"))]
          [(if (= (string.string-length previous-relative) 0)
              false
              (not
                (package-source-string-less?
                  (owned_view.compiler-owned-shared-view previous-relative)
                  (owned_view.compiler-owned-shared-view relative))))
            (set!
              error
              (package-source-binding-invalid-set-error
                (owned_view.compiler-owned-shared-view source-set)
                path
                "source paths must be unique and in deterministic order"))]
          [(not (package-source-relative-parent-eligible? root relative))
            (set!
              error
              (package-source-binding-invalid-set-error
                (owned_view.compiler-owned-shared-view source-set)
                path
                "source is excluded by package discovery policy"))]
          [else
            (match (fs.try-file-kind-no-follow (& path))
              [(ErrFsFileKind io-error)
                (set!
                  error
                  (package-source-binding-read-error
                    (owned_view.compiler-owned-shared-view source-set)
                    path
                    io-error))]
              [(OkFsFileKind kind)
                (if (not (package-source-include-kind? path kind))
                  (set!
                    error
                    (package-source-binding-invalid-set-error
                      (owned_view.compiler-owned-shared-view source-set)
                      path
                      "source is no longer a regular TypeLisp file"))
                  (match (io.try-read-file (& path))
                    [(ErrIoBytes io-error)
                      (set!
                        error
                        (package-source-binding-read-error
                          (owned_view.compiler-owned-shared-view source-set)
                          path
                          io-error))]
                    [(OkIoBytes contents)
                      (let
                        [bytes : (__tl_dyn-array u8)
                          (byte_buf.to-array contents)]
                        (set!
                          hash
                          (package-source-binding-hash-source
                            hash
                            (owned_view.compiler-owned-shared-view relative)
                            bytes))
                        (set! previous-relative relative))]))])])
        (set! index (+ index 1))))
    (if (> (string.string-length error) 0)
      (Err error)
      (Ok hash))))

(define (package-source-binding-verification-from-admission
  [admission : tlci.TlciPackageSourceBindingAdmission]) : PackageSourceBindingVerification
  (match admission
    [(Match digest) (Match digest)]
    [(Mismatch expected actual) (Mismatch expected actual)]
    [(MissingOrLegacy) (MissingOrLegacy)]
    [(UnsupportedSchema schema) (UnsupportedSchema schema)]
    [(Malformed message) (Malformed message)]))

(define (package-source-verify-binding
  [source-set : PackageSourceSet]
  [rodata : (__tl_dyn-array u8)]) : PackageSourceBindingVerification
  (match (package-source-set-digest source-set)
    [(Err message) (Unreadable message)]
    [(Ok expected)
      (package-source-binding-verification-from-admission
        (tlci.tlci-package-source-binding-admit rodata expected))]))