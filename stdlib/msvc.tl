;# MSVC tool discovery (#855): find link.exe and its command environment.
;#
;# Detect an already-configured MSVC command environment (a Developer Command
;# Prompt or equivalent) first. If that is absent, scan the standard Visual
;# Studio / Build Tools install locations, combine the selected VC toolset with
;# Windows SDK discovery, and return the `PATH`, `LIB`, and `INCLUDE` overrides
;# needed to invoke the requested MSVC tool from a normal shell.
;#
;# Usage: `(import stdlib.msvc)`
;#
;# ```typelisp
;# (import stdlib.msvc as msvc)
;# (define target : String "x86_64-pc-windows-msvc")
;# (define tool : String "link.exe")
;# (define resolved : msvc.ResultMsvcTool
;#   (msvc.msvc-find-tool (& target) (& tool)))
;# ```
(module stdlib.msvc)

(import stdlib.env as env_mod)

(import stdlib.io as io_mod)

(import stdlib.fs as fs_mod)

(import stdlib.process as process_mod)

(import stdlib.string as string_mod)

(import stdlib.vector as vector_mod)

;: Resolved MSVC tool: executable path plus the command-environment overrides.
(defstruct MsvcTool
  (executable String)
  (path String)
  (lib String)
  (include String))

;: Structured MSVC discovery failures.
(defenum MsvcError
  (MsvcUnsupported String)
  (MsvcMissingEnvironment String)
  (MsvcToolNotFound String)
  (MsvcSetupUnavailable String))

;: Result type for MSVC tool discovery.
(defenum ResultMsvcTool
  (OkMsvcTool MsvcTool)
  (ErrMsvcTool MsvcError))

;: Optional resolved-path result for the PATH search.
(defenum MsvcMaybeString
  (MsvcNoString)
  (MsvcSomeString String))

;: Parsed version segment plus the index where parsing stopped.
(defstruct MsvcVersionCursor
  (value i64)
  (next i64))

;: Usable VC toolset candidate found under a standard install location.
(defstruct MsvcToolset
  (root String)
  (version String))

;: Optional VC toolset result while scanning standard install locations.
(defenum MsvcMaybeToolset
  (MsvcNoToolset)
  (MsvcSomeToolset MsvcToolset))

;: Usable Windows SDK candidate with root and version.
(defstruct MsvcSdk
  (root String)
  (version String))

;: Optional Windows SDK result while scanning SDK roots.
(defenum MsvcMaybeSdk
  (MsvcNoSdk)
  (MsvcSomeSdk MsvcSdk))

;: Return the resolved tool executable path.
(define (msvc-tool-executable [tool : MsvcTool]) : String
  (struct-get tool executable))

;: Return the PATH override for invoking the tool.
(define (msvc-tool-path [tool : MsvcTool]) : String
  (struct-get tool path))

;: Return the LIB override for invoking the tool.
(define (msvc-tool-lib [tool : MsvcTool]) : String
  (struct-get tool lib))

;: Return the INCLUDE override for invoking the tool.
(define (msvc-tool-include [tool : MsvcTool]) : String
  (struct-get tool include))

;: Return process environment overrides for invoking the tool.
(define (msvc-tool-process-env [tool : MsvcTool]) : process_mod.ProcessEnvList
  (process_mod.process-env-cons
    "PATH"
    (stdlib.msvc.msvc-tool-path tool)
    (process_mod.process-env-cons
      "LIB"
      (stdlib.msvc.msvc-tool-lib tool)
      (process_mod.process-env-cons
        "INCLUDE"
        (stdlib.msvc.msvc-tool-include tool)
        (process_mod.process-env-empty)))))

;: Render a discovery error as a diagnostic message.
(define (msvc-error-message [error : MsvcError]) : String
  (match error
    [(MsvcUnsupported message) message]
    [(MsvcMissingEnvironment message) message]
    [(MsvcToolNotFound message) message]
    [(MsvcSetupUnavailable message) message]))

;: Return true when the host path-list separator identifies Windows.
(define (msvc-host-windows?) : bool
  (string_mod.string-eq (env_mod.env-path-list-separator) ";"))

;: Return true when `target` is a v1-supported MSVC target triple.
(define (msvc-supported-target? [target : (& target str)]) : bool
  (let
    [supported : String "x86_64-pc-windows-msvc"]
    (string_mod.string-eq-borrowed target (& supported))))

;: Return true when `c` is an ASCII decimal digit.
(define (msvc-digit? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (and (>= code (cast #0' : i64)) (<= code (cast #9' : i64)))))

;: Return the numeric value of an ASCII decimal digit, or zero otherwise.
(define (msvc-digit-value [c : char]) : i64
  (if (stdlib.msvc.msvc-digit? c)
    (- (cast c : i64) (cast #0' : i64))
    0))

;: Read one dotted numeric version segment starting at `index`.
(define (msvc-version-read-segment [version : String] [index : i64]) : MsvcVersionCursor
  (let
    [n : i64 (string-length version)]
    [i : i64 index]
    [value : i64 0]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (let
          [c : char (string-ref version i)]
          (if (string_mod.char-eq c #.')
            (set! done true)
            (begin
              (if (stdlib.msvc.msvc-digit? c)
                (set! value (+ (* value 10) (stdlib.msvc.msvc-digit-value c)))
                unit)
              (set! i (+ i 1))))))
      (MsvcVersionCursor value i))))

;: Advance past a dotted version separator if one is present.
(define (msvc-version-next-index [version : String] [index : i64]) : i64
  (let
    [n : i64 (string-length version)]
    (if (and (< index n) (string_mod.char-eq (string-ref version index) #.'))
      (+ index 1)
      index)))

;: Return true when owned `left` is a newer dotted numeric version than `right`.
(define (msvc-version-greater-owned? [left : String] [right : String]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    [left-index : i64 0]
    [right-index : i64 0]
    [greater : bool false]
    [done : bool false]
    (begin
      (while (and
        (not done)
        (or (< left-index left-len) (< right-index right-len)))
        (let
          [left-segment : MsvcVersionCursor
            (stdlib.msvc.msvc-version-read-segment left left-index)]
          [right-segment : MsvcVersionCursor
            (stdlib.msvc.msvc-version-read-segment right right-index)]
          [left-value : i64 (struct-get left-segment value)]
          [right-value : i64 (struct-get right-segment value)]
          (if (> left-value right-value)
            (begin
              (set! greater true)
              (set! done true))
            (if (< left-value right-value)
              (set! done true)
              (begin
                (set!
                  left-index
                  (stdlib.msvc.msvc-version-next-index
                    left
                    (struct-get left-segment next)))
                (set!
                  right-index
                  (stdlib.msvc.msvc-version-next-index
                    right
                    (struct-get right-segment next))))))))
      greater)))

;: Return true when `left` is a newer dotted numeric version than `right`.
(define (msvc-version-greater? [left : (& left str)] [right : (& right str)]) : bool
  (let
    [left-text : String (string_mod.string-copy-borrowed left)]
    [right-text : String (string_mod.string-copy-borrowed right)]
    (stdlib.msvc.msvc-version-greater-owned? left-text right-text)))

;: Return true when `path` exists, mapping probe errors to false.
(define (msvc-path-exists? [path : (& path str)]) : bool
  (match (io_mod.try-file-exists? path)
    [(io_mod.OkIoBool exists) exists]
    [(io_mod.ErrIoBool _) false]))

;: Return true when an owned path exists through the borrowed public helper.
(define (msvc-path-exists-owned? [path : String]) : bool
  (stdlib.msvc.msvc-path-exists? (& path)))

;: Return true when an owned path exists and is a directory.
(define (msvc-dir-exists-owned? [path : String]) : bool
  (= (fs_mod.fs-file-kind-status path) fs_mod.fs-file-kind-directory-code))

;: Join two filesystem path segments using the platform separator.
(define (msvc-path-join [left : String] [right : String]) : String
  (fs_mod.fs-path-join (& left) (& right)))

;: Join three filesystem path segments.
(define (msvc-path-join3 [a : String] [b : String] [c : String]) : String
  (stdlib.msvc.msvc-path-join (stdlib.msvc.msvc-path-join a b) c))

;: Join four filesystem path segments.
(define (msvc-path-join4 [a : String] [b : String] [c : String] [d : String]) : String
  (stdlib.msvc.msvc-path-join (stdlib.msvc.msvc-path-join3 a b c) d))

;: Join five filesystem path segments.
(define (msvc-path-join5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (stdlib.msvc.msvc-path-join (stdlib.msvc.msvc-path-join4 a b c d) e))

;: Join six filesystem path segments.
(define (msvc-path-join6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : String
  (stdlib.msvc.msvc-path-join (stdlib.msvc.msvc-path-join5 a b c d e) f))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-vec-owned-from
  [dirs : vector_mod.StringVec]
  [index : i64]
  [tool : String]) : MsvcMaybeString
  (if (>= index (vector_mod.string-vec-len dirs))
    stdlib.msvc.MsvcNoString
    (let
      [candidate : String
        (stdlib.msvc.msvc-path-join
          (vector_mod.string-vec-get dirs index "")
          tool)]
      (if (stdlib.msvc.msvc-path-exists-owned? candidate)
        (MsvcSomeString candidate)
        (stdlib.msvc.msvc-search-dirs-vec-owned-from dirs (+ index 1) tool)))))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-vec-owned
  [dirs : vector_mod.StringVec]
  [tool : String]) : MsvcMaybeString
  (stdlib.msvc.msvc-search-dirs-vec-owned-from dirs 0 tool))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-owned [dirs : env_mod.EnvStringList] [tool : String]) : MsvcMaybeString
  (stdlib.msvc.msvc-search-dirs-vec-owned
    (env_mod.env-string-list-to-vec dirs)
    tool))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs-vec
  [dirs : vector_mod.StringVec]
  [tool : (& tool str)]) : MsvcMaybeString
  (let
    [tool-text : String (string_mod.string-copy-borrowed tool)]
    (stdlib.msvc.msvc-search-dirs-vec-owned dirs tool-text)))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (msvc-search-dirs [dirs : env_mod.EnvStringList] [tool : (& tool str)]) : MsvcMaybeString
  (let
    [tool-text : String (string_mod.string-copy-borrowed tool)]
    (stdlib.msvc.msvc-search-dirs-owned dirs tool-text)))

;: Locate `tool` on the PATH environment variable.
(define (msvc-find-on-path [tool : (& tool str)]) : MsvcMaybeString
  (let
    [name : String "PATH"]
    (match (env_mod.env-path-list-vec (& name))
      [(env_mod.EnvNoStringVec) stdlib.msvc.MsvcNoString]
      [(env_mod.EnvSomeStringVec dirs)
        (stdlib.msvc.msvc-search-dirs-vec dirs tool)])))

;: Read an environment variable or the empty string when it is unset.
(define (msvc-env-or-empty [name : (& name str)]) : String
  (match (env_mod.env-get name)
    [(env_mod.EnvSomeString value) value]
    [(env_mod.EnvNoString) ""]))

;: Read an owned environment variable name or the empty string when it is unset.
(define (msvc-env-or-empty-owned [name : String]) : String
  (stdlib.msvc.msvc-env-or-empty (& name)))

;: Read an owned environment variable name, or return `fallback`.
(define (msvc-env-or-default-owned [name : String] [fallback : String]) : String
  (let
    [value : String (stdlib.msvc.msvc-env-or-empty-owned name)]
    (if (string_mod.string-eq value "")
      fallback
      value)))

;: Join owned `head` before an optional PATH-style suffix.
(define (msvc-path-list-prepend-owned [head : String] [tail : String]) : String
  (if (string_mod.string-eq tail "")
    head
    (string_mod.string-append
      (string_mod.string-append head (env_mod.env-path-list-separator))
      tail)))

;: Join `head` before an optional PATH-style suffix.
(define (msvc-path-list-prepend [head : (& head str)] [tail : (& tail str)]) : String
  (let
    [head-text : String (string_mod.string-copy-borrowed head)]
    [tail-text : String (string_mod.string-copy-borrowed tail)]
    (stdlib.msvc.msvc-path-list-prepend-owned head-text tail-text)))

;: Join two owned required PATH-style entries.
(define (msvc-path-list-join2-owned [a : String] [b : String]) : String
  (string_mod.string-append
    (string_mod.string-append a (env_mod.env-path-list-separator))
    b))

;: Join two required PATH-style entries.
(define (msvc-path-list-join2 [a : (& a str)] [b : (& b str)]) : String
  (let
    [a-text : String (string_mod.string-copy-borrowed a)]
    [b-text : String (string_mod.string-copy-borrowed b)]
    (stdlib.msvc.msvc-path-list-join2-owned a-text b-text)))

;: Join three owned required PATH-style entries.
(define (msvc-path-list-join3-owned [a : String] [b : String] [c : String]) : String
  (stdlib.msvc.msvc-path-list-join2-owned
    (stdlib.msvc.msvc-path-list-join2-owned a b)
    c))

;: Join three required PATH-style entries.
(define (msvc-path-list-join3 [a : (& a str)] [b : (& b str)] [c : (& c str)]) : String
  (let
    [a-text : String (string_mod.string-copy-borrowed a)]
    [b-text : String (string_mod.string-copy-borrowed b)]
    [c-text : String (string_mod.string-copy-borrowed c)]
    (stdlib.msvc.msvc-path-list-join3-owned a-text b-text c-text)))

;: Join four owned required PATH-style entries.
(define (msvc-path-list-join4-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (stdlib.msvc.msvc-path-list-join2-owned
    (stdlib.msvc.msvc-path-list-join3-owned a b c)
    d))

;: Join four required PATH-style entries.
(define (msvc-path-list-join4
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]) : String
  (let
    [a-text : String (string_mod.string-copy-borrowed a)]
    [b-text : String (string_mod.string-copy-borrowed b)]
    [c-text : String (string_mod.string-copy-borrowed c)]
    [d-text : String (string_mod.string-copy-borrowed d)]
    (stdlib.msvc.msvc-path-list-join4-owned a-text b-text c-text d-text)))

;: Join an optional inherited path list after required entries.
(define (msvc-path-list-join3-with-tail-owned
  [a : String]
  [b : String]
  [c : String]
  [tail : String]) : String
  (stdlib.msvc.msvc-path-list-prepend-owned
    (stdlib.msvc.msvc-path-list-join3-owned a b c)
    tail))

;: Join an optional inherited path list after required entries.
(define (msvc-path-list-join3-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [tail : (& tail str)]) : String
  (let
    [a-text : String (string_mod.string-copy-borrowed a)]
    [b-text : String (string_mod.string-copy-borrowed b)]
    [c-text : String (string_mod.string-copy-borrowed c)]
    [tail-text : String (string_mod.string-copy-borrowed tail)]
    (stdlib.msvc.msvc-path-list-join3-with-tail-owned
      a-text
      b-text
      c-text
      tail-text)))

;: Join an optional inherited path list after two required entries.
(define (msvc-path-list-join2-with-tail-owned
  [a : String]
  [b : String]
  [tail : String]) : String
  (stdlib.msvc.msvc-path-list-prepend-owned
    (stdlib.msvc.msvc-path-list-join2-owned a b)
    tail))

;: Join an optional inherited path list after two required entries.
(define (msvc-path-list-join2-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [tail : (& tail str)]) : String
  (let
    [a-text : String (string_mod.string-copy-borrowed a)]
    [b-text : String (string_mod.string-copy-borrowed b)]
    [tail-text : String (string_mod.string-copy-borrowed tail)]
    (stdlib.msvc.msvc-path-list-join2-with-tail-owned a-text b-text tail-text)))

;: Join an optional inherited path list after four required entries.
(define (msvc-path-list-join4-with-tail-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [tail : String]) : String
  (stdlib.msvc.msvc-path-list-prepend-owned
    (stdlib.msvc.msvc-path-list-join4-owned a b c d)
    tail))

;: Join an optional inherited path list after four required entries.
(define (msvc-path-list-join4-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]
  [tail : (& tail str)]) : String
  (let
    [a-text : String (string_mod.string-copy-borrowed a)]
    [b-text : String (string_mod.string-copy-borrowed b)]
    [c-text : String (string_mod.string-copy-borrowed c)]
    [d-text : String (string_mod.string-copy-borrowed d)]
    [tail-text : String (string_mod.string-copy-borrowed tail)]
    (stdlib.msvc.msvc-path-list-join4-with-tail-owned
      a-text
      b-text
      c-text
      d-text
      tail-text)))

;: Build a configured tool result once the executable path is known.
(define (msvc-configured-result [executable : String]) : ResultMsvcTool
  (let
    [name : String "LIB"]
    (match (env_mod.env-get (& name))
      [(env_mod.EnvNoString)
        (ErrMsvcTool
          (MsvcMissingEnvironment
            "msvc: LIB is not set; run from a Developer Command Prompt or use auto-discovery"))]
      [(env_mod.EnvSomeString lib)
        (let
          [name : String "INCLUDE"]
          (match (env_mod.env-get (& name))
            [(env_mod.EnvNoString)
              (ErrMsvcTool
                (MsvcMissingEnvironment
                  "msvc: INCLUDE is not set; run from a Developer Command Prompt or use auto-discovery"))]
            [(env_mod.EnvSomeString include)
              (OkMsvcTool
                (MsvcTool
                  executable
                  (stdlib.msvc.msvc-env-or-empty-owned "PATH")
                  lib
                  include))]))])))

;: Detect a configured MSVC command environment and resolve `tool`.
(define (msvc-find-tool-configured [tool : (& tool str)]) : ResultMsvcTool
  (match (stdlib.msvc.msvc-find-on-path tool)
    [(MsvcSomeString executable)
      (stdlib.msvc.msvc-configured-result executable)]
    [(MsvcNoString)
      (let
        [tool-text : String (string_mod.string-copy-borrowed tool)]
        (ErrMsvcTool
          (MsvcToolNotFound
            (string_mod.string-append
              (string_mod.string-append "msvc: could not find " tool-text)
              " on PATH; run from a Developer Command Prompt or install Visual Studio Build Tools"))))]))

;: Program Files root used by ordinary Visual Studio SKUs.
(define (msvc-program-files) : String
  (stdlib.msvc.msvc-env-or-default-owned "ProgramFiles" "C:/Program Files"))

;: Program Files (x86) root used by Build Tools and Windows Kits.
(define (msvc-program-files-x86) : String
  (stdlib.msvc.msvc-env-or-default-owned
    "ProgramFiles(x86)"
    "C:/Program Files (x86)"))

;: Return a standard Visual Studio VC toolset parent directory.
(define (msvc-vs-toolset-parent
  [program-files : String]
  [year : String]
  [edition : String]) : String
  (stdlib.msvc.msvc-path-join6
    program-files
    "Microsoft Visual Studio"
    year
    edition
    "VC"
    "Tools/MSVC"))

;: Candidate Visual Studio / Build Tools toolset parent directories.
(define (msvc-toolset-parent-candidates) : vector_mod.StringVec
  (let
    [pf : String (stdlib.msvc.msvc-program-files)]
    [pfx : String (stdlib.msvc.msvc-program-files-x86)]
    [items : vector_mod.StringVec (vector_mod.string-vec-with-capacity 8)]
    (begin
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pf "2022" "Enterprise")))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pf "2022" "Professional")))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pf "2022" "Community")))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pfx "2022" "BuildTools")))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pf "2019" "Enterprise")))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pf "2019" "Professional")))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-vs-toolset-parent pf "2019" "Community")))
      (vector_mod.string-vec-push
        items
        (stdlib.msvc.msvc-vs-toolset-parent pfx "2019" "BuildTools")))))

;: Return the bin directory for host x64 -> target x64 tools.
(define (msvc-toolset-bin-dir [toolset-root : String]) : String
  (stdlib.msvc.msvc-path-join4 toolset-root "bin" "Hostx64" "x64"))

;: Return a tool executable path inside a toolset root.
(define (msvc-toolset-tool-path [toolset-root : String] [tool : String]) : String
  (stdlib.msvc.msvc-path-join
    (stdlib.msvc.msvc-toolset-bin-dir toolset-root)
    tool))

;: Scan one VC Tools/MSVC parent for the newest version containing `tool`.
(define (msvc-toolset-scan-entries
  [entries : vector_mod.StringVec]
  [index : i64]
  [parent : String]
  [tool : String]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeToolset
  (if (>= index (vector_mod.string-vec-len entries))
    (if has-best
      (MsvcSomeToolset (MsvcToolset best-root best-version))
      stdlib.msvc.MsvcNoToolset)
    (let
      [version : String (vector_mod.string-vec-get entries index "")]
      [toolset-root : String (stdlib.msvc.msvc-path-join parent version)]
      [tool-path : String
        (stdlib.msvc.msvc-toolset-tool-path toolset-root tool)]
      [usable : bool (stdlib.msvc.msvc-path-exists-owned? tool-path)]
      [newer : bool
        (if has-best
          (stdlib.msvc.msvc-version-greater-owned? version best-version)
          true)]
      (if (and usable newer)
        (stdlib.msvc.msvc-toolset-scan-entries
          entries
          (+ index 1)
          parent
          tool
          toolset-root
          version
          true)
        (stdlib.msvc.msvc-toolset-scan-entries
          entries
          (+ index 1)
          parent
          tool
          best-root
          best-version
          has-best)))))

;: Return the newest toolset under one parent, if any.
(define (msvc-find-toolset-in-parent [parent : String] [tool : String]) : MsvcMaybeToolset
  (match (fs_mod.try-read-dir-vec (& parent))
    [(fs_mod.OkIoStringVec entries)
      (stdlib.msvc.msvc-toolset-scan-entries entries 0 parent tool "" "" false)]
    [(fs_mod.ErrIoStringVec _) stdlib.msvc.MsvcNoToolset]))

;: Return true when `candidate` should replace the current best toolset.
(define (msvc-toolset-candidate-newer?
  [candidate : MsvcToolset]
  [best-version : String]
  [has-best : bool]) : bool
  (if has-best
    (stdlib.msvc.msvc-version-greater-owned?
      (struct-get candidate version)
      best-version)
    true))

;: Scan standard Visual Studio locations for the newest toolset containing `tool`.
(define (msvc-find-toolset-parents
  [parents : vector_mod.StringVec]
  [index : i64]
  [tool : String]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeToolset
  (if (>= index (vector_mod.string-vec-len parents))
    (if has-best
      (MsvcSomeToolset (MsvcToolset best-root best-version))
      stdlib.msvc.MsvcNoToolset)
    (let
      [parent : String (vector_mod.string-vec-get parents index "")]
      (match (stdlib.msvc.msvc-find-toolset-in-parent parent tool)
        [(MsvcNoToolset)
          (stdlib.msvc.msvc-find-toolset-parents
            parents
            (+ index 1)
            tool
            best-root
            best-version
            has-best)]
        [(MsvcSomeToolset candidate)
          (if (stdlib.msvc.msvc-toolset-candidate-newer?
            candidate
            best-version
            has-best)
            (stdlib.msvc.msvc-find-toolset-parents
              parents
              (+ index 1)
              tool
              (struct-get candidate root)
              (struct-get candidate version)
              true)
            (stdlib.msvc.msvc-find-toolset-parents
              parents
              (+ index 1)
              tool
              best-root
              best-version
              has-best))]))))

;: Find the newest installed VC toolset containing `tool`.
(define (msvc-find-toolset [tool : String]) : MsvcMaybeToolset
  (stdlib.msvc.msvc-find-toolset-parents
    (stdlib.msvc.msvc-toolset-parent-candidates)
    0
    tool
    ""
    ""
    false))

;: Candidate Windows SDK roots.
(define (msvc-sdk-root-candidates) : vector_mod.StringVec
  (let
    [env-root : String (stdlib.msvc.msvc-env-or-empty-owned "WindowsSdkDir")]
    [pfx : String (stdlib.msvc.msvc-program-files-x86)]
    [pf : String (stdlib.msvc.msvc-program-files)]
    [items : vector_mod.StringVec (vector_mod.string-vec-with-capacity 3)]
    (begin
      (if (string_mod.string-eq env-root "")
        unit
        (set! items (vector_mod.string-vec-push items env-root)))
      (set!
        items
        (vector_mod.string-vec-push
          items
          (stdlib.msvc.msvc-path-join3 pfx "Windows Kits" "10")))
      (vector_mod.string-vec-push
        items
        (stdlib.msvc.msvc-path-join3 pf "Windows Kits" "10")))))

;: Return the root for one Windows SDK version.
(define (msvc-sdk-version-root [sdk-root : String] [version : String]) : String
  (stdlib.msvc.msvc-path-join
    (stdlib.msvc.msvc-path-join sdk-root "Lib")
    version))

;: Return the SDK um/x64 library directory.
(define (msvc-sdk-um-lib-dir [sdk : MsvcSdk]) : String
  (stdlib.msvc.msvc-path-join4
    (struct-get sdk root)
    "Lib"
    (struct-get sdk version)
    "um/x64"))

;: Return the SDK ucrt/x64 library directory.
(define (msvc-sdk-ucrt-lib-dir [sdk : MsvcSdk]) : String
  (stdlib.msvc.msvc-path-join4
    (struct-get sdk root)
    "Lib"
    (struct-get sdk version)
    "ucrt/x64"))

;: Return one SDK include directory.
(define (msvc-sdk-include-dir [sdk : MsvcSdk] [name : String]) : String
  (stdlib.msvc.msvc-path-join4
    (struct-get sdk root)
    "Include"
    (struct-get sdk version)
    name))

;: Return true when a Windows SDK version has the pieces needed by link.exe.
(define (msvc-sdk-version-usable? [sdk-root : String] [version : String]) : bool
  (let
    [lib-root : String (stdlib.msvc.msvc-sdk-version-root sdk-root version)]
    [kernel32 : String
      (stdlib.msvc.msvc-path-join3 lib-root "um/x64" "kernel32.lib")]
    [ucrt : String (stdlib.msvc.msvc-path-join3 lib-root "ucrt/x64" "ucrt.lib")]
    [include-root : String
      (stdlib.msvc.msvc-path-join
        (stdlib.msvc.msvc-path-join sdk-root "Include")
        version)]
    (and
      (stdlib.msvc.msvc-path-exists-owned? kernel32)
      (stdlib.msvc.msvc-path-exists-owned? ucrt)
      (stdlib.msvc.msvc-dir-exists-owned?
        (stdlib.msvc.msvc-path-join include-root "shared"))
      (stdlib.msvc.msvc-dir-exists-owned?
        (stdlib.msvc.msvc-path-join include-root "um"))
      (stdlib.msvc.msvc-dir-exists-owned?
        (stdlib.msvc.msvc-path-join include-root "ucrt")))))

;: Scan one Windows SDK root for the newest usable version.
(define (msvc-sdk-scan-entries
  [entries : vector_mod.StringVec]
  [index : i64]
  [sdk-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeSdk
  (if (>= index (vector_mod.string-vec-len entries))
    (if has-best
      (MsvcSomeSdk (MsvcSdk sdk-root best-version))
      stdlib.msvc.MsvcNoSdk)
    (let
      [version : String (vector_mod.string-vec-get entries index "")]
      [usable : bool (stdlib.msvc.msvc-sdk-version-usable? sdk-root version)]
      [newer : bool
        (if has-best
          (stdlib.msvc.msvc-version-greater-owned? version best-version)
          true)]
      (if (and usable newer)
        (stdlib.msvc.msvc-sdk-scan-entries
          entries
          (+ index 1)
          sdk-root
          version
          true)
        (stdlib.msvc.msvc-sdk-scan-entries
          entries
          (+ index 1)
          sdk-root
          best-version
          has-best)))))

;: Return the newest usable SDK under one root, if any.
(define (msvc-find-sdk-in-root [sdk-root : String]) : MsvcMaybeSdk
  (let
    [lib-dir : String (stdlib.msvc.msvc-path-join sdk-root "Lib")]
    (match (fs_mod.try-read-dir-vec (& lib-dir))
      [(fs_mod.OkIoStringVec entries)
        (stdlib.msvc.msvc-sdk-scan-entries entries 0 sdk-root "" false)]
      [(fs_mod.ErrIoStringVec _) stdlib.msvc.MsvcNoSdk])))

;: Return true when `candidate` should replace the current best SDK.
(define (msvc-sdk-candidate-newer?
  [candidate : MsvcSdk]
  [best-version : String]
  [has-best : bool]) : bool
  (if has-best
    (stdlib.msvc.msvc-version-greater-owned?
      (struct-get candidate version)
      best-version)
    true))

;: Scan standard Windows SDK roots.
(define (msvc-find-sdk-roots
  [roots : vector_mod.StringVec]
  [index : i64]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeSdk
  (if (>= index (vector_mod.string-vec-len roots))
    (if has-best
      (MsvcSomeSdk (MsvcSdk best-root best-version))
      stdlib.msvc.MsvcNoSdk)
    (let
      [root : String (vector_mod.string-vec-get roots index "")]
      (match (stdlib.msvc.msvc-find-sdk-in-root root)
        [(MsvcNoSdk)
          (stdlib.msvc.msvc-find-sdk-roots
            roots
            (+ index 1)
            best-root
            best-version
            has-best)]
        [(MsvcSomeSdk candidate)
          (if (stdlib.msvc.msvc-sdk-candidate-newer?
            candidate
            best-version
            has-best)
            (stdlib.msvc.msvc-find-sdk-roots
              roots
              (+ index 1)
              (struct-get candidate root)
              (struct-get candidate version)
              true)
            (stdlib.msvc.msvc-find-sdk-roots
              roots
              (+ index 1)
              best-root
              best-version
              has-best))]))))

;: Find the newest usable Windows SDK.
(define (msvc-find-sdk) : MsvcMaybeSdk
  (stdlib.msvc.msvc-find-sdk-roots
    (stdlib.msvc.msvc-sdk-root-candidates)
    0
    ""
    ""
    false))

;: Build an auto-discovered MSVC tool result from a toolset and SDK.
(define (msvc-auto-result
  [toolset : MsvcToolset]
  [sdk : MsvcSdk]
  [tool : String]) : MsvcTool
  (let
    [toolset-root : String (struct-get toolset root)]
    [bin-dir : String (stdlib.msvc.msvc-toolset-bin-dir toolset-root)]
    [toolset-lib : String
      (stdlib.msvc.msvc-path-join3 toolset-root "lib" "x64")]
    [toolset-include : String
      (stdlib.msvc.msvc-path-join toolset-root "include")]
    [sdk-um-lib : String (stdlib.msvc.msvc-sdk-um-lib-dir sdk)]
    [sdk-ucrt-lib : String (stdlib.msvc.msvc-sdk-ucrt-lib-dir sdk)]
    [sdk-shared-include : String
      (stdlib.msvc.msvc-sdk-include-dir sdk "shared")]
    [sdk-um-include : String (stdlib.msvc.msvc-sdk-include-dir sdk "um")]
    [sdk-ucrt-include : String (stdlib.msvc.msvc-sdk-include-dir sdk "ucrt")]
    (MsvcTool
      (stdlib.msvc.msvc-toolset-tool-path toolset-root tool)
      (stdlib.msvc.msvc-path-list-prepend-owned
        bin-dir
        (stdlib.msvc.msvc-env-or-empty-owned "PATH"))
      (stdlib.msvc.msvc-path-list-join3-with-tail-owned
        toolset-lib
        sdk-um-lib
        sdk-ucrt-lib
        (stdlib.msvc.msvc-env-or-empty-owned "LIB"))
      (stdlib.msvc.msvc-path-list-join4-with-tail-owned
        toolset-include
        sdk-shared-include
        sdk-um-include
        sdk-ucrt-include
        (stdlib.msvc.msvc-env-or-empty-owned "INCLUDE")))))

;: Discover a Visual Studio toolset and Windows SDK from standard locations.
(define (msvc-find-tool-auto [tool : (& tool str)]) : ResultMsvcTool
  (let
    [tool-text : String (string_mod.string-copy-borrowed tool)]
    (match (stdlib.msvc.msvc-find-toolset tool-text)
      [(MsvcNoToolset)
        (ErrMsvcTool
          (MsvcToolNotFound
            (string_mod.string-append
              (string_mod.string-append "msvc: could not discover " tool-text)
              " under standard Visual Studio Build Tools locations")))]
      [(MsvcSomeToolset toolset)
        (match (stdlib.msvc.msvc-find-sdk)
          [(MsvcNoSdk)
            (ErrMsvcTool
              (MsvcSetupUnavailable
                "msvc: could not discover a usable Windows SDK under standard locations"))]
          [(MsvcSomeSdk sdk)
            (OkMsvcTool (stdlib.msvc.msvc-auto-result toolset sdk tool-text))])])))

;: Find an MSVC tool such as `link.exe` and its command environment.
;:
;: Resolves the tool from a configured Developer Command Prompt environment
;: first, then from standard Visual Studio / Windows SDK install locations.
(define (msvc-find-tool [target : (& target str)] [tool : (& tool str)]) : ResultMsvcTool
  (if (not (stdlib.msvc.msvc-host-windows?))
    (ErrMsvcTool
      (MsvcUnsupported
        "msvc: tool discovery is unsupported on non-Windows hosts"))
    (if (not (stdlib.msvc.msvc-supported-target? target))
      (ErrMsvcTool
        (let
          [target-text : String (string_mod.string-copy-borrowed target)]
          (MsvcUnsupported
            (string_mod.string-append "msvc: unsupported target " target-text))))
      (match (stdlib.msvc.msvc-find-tool-configured tool)
        [(OkMsvcTool resolved) (OkMsvcTool resolved)]
        [(ErrMsvcTool _) (stdlib.msvc.msvc-find-tool-auto tool)]))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value msvc-tool-executable)
  (value msvc-tool-path)
  (value msvc-tool-lib)
  (value msvc-tool-include)
  (value msvc-tool-process-env)
  (value msvc-error-message)
  (value msvc-host-windows?)
  (value msvc-supported-target?)
  (value msvc-digit?)
  (value msvc-digit-value)
  (value msvc-version-read-segment)
  (value msvc-version-next-index)
  (value msvc-version-greater-owned?)
  (value msvc-version-greater?)
  (value msvc-path-exists?)
  (value msvc-path-exists-owned?)
  (value msvc-dir-exists-owned?)
  (value msvc-path-join)
  (value msvc-path-join3)
  (value msvc-path-join4)
  (value msvc-path-join5)
  (value msvc-path-join6)
  (value msvc-search-dirs-vec-owned-from)
  (value msvc-search-dirs-vec-owned)
  (value msvc-search-dirs-owned)
  (value msvc-search-dirs-vec)
  (value msvc-search-dirs)
  (value msvc-find-on-path)
  (value msvc-env-or-empty)
  (value msvc-env-or-empty-owned)
  (value msvc-env-or-default-owned)
  (value msvc-path-list-prepend-owned)
  (value msvc-path-list-prepend)
  (value msvc-path-list-join2-owned)
  (value msvc-path-list-join2)
  (value msvc-path-list-join3-owned)
  (value msvc-path-list-join3)
  (value msvc-path-list-join4-owned)
  (value msvc-path-list-join4)
  (value msvc-path-list-join3-with-tail-owned)
  (value msvc-path-list-join3-with-tail)
  (value msvc-path-list-join2-with-tail-owned)
  (value msvc-path-list-join2-with-tail)
  (value msvc-path-list-join4-with-tail-owned)
  (value msvc-path-list-join4-with-tail)
  (value msvc-configured-result)
  (value msvc-find-tool-configured)
  (value msvc-program-files)
  (value msvc-program-files-x86)
  (value msvc-vs-toolset-parent)
  (value msvc-toolset-parent-candidates)
  (value msvc-toolset-bin-dir)
  (value msvc-toolset-tool-path)
  (value msvc-toolset-scan-entries)
  (value msvc-find-toolset-in-parent)
  (value msvc-toolset-candidate-newer?)
  (value msvc-find-toolset-parents)
  (value msvc-find-toolset)
  (value msvc-sdk-root-candidates)
  (value msvc-sdk-version-root)
  (value msvc-sdk-um-lib-dir)
  (value msvc-sdk-ucrt-lib-dir)
  (value msvc-sdk-include-dir)
  (value msvc-sdk-version-usable?)
  (value msvc-sdk-scan-entries)
  (value msvc-find-sdk-in-root)
  (value msvc-sdk-candidate-newer?)
  (value msvc-find-sdk-roots)
  (value msvc-find-sdk)
  (value msvc-auto-result)
  (value msvc-find-tool-auto)
  (value msvc-find-tool)
  (type MsvcTool)
  (type MsvcError)
  (type ResultMsvcTool)
  (type MsvcMaybeString)
  (type MsvcVersionCursor)
  (type MsvcToolset)
  (type MsvcMaybeToolset)
  (type MsvcSdk)
  (type MsvcMaybeSdk)
  (constructor MsvcTool)
  (constructor MsvcVersionCursor)
  (constructor MsvcToolset)
  (constructor MsvcSdk)
  (field MsvcTool executable)
  (field MsvcTool path)
  (field MsvcTool lib)
  (field MsvcTool include)
  (field MsvcVersionCursor value)
  (field MsvcVersionCursor next)
  (field MsvcToolset root)
  (field MsvcToolset version)
  (field MsvcSdk root)
  (field MsvcSdk version)
  (variant MsvcUnsupported)
  (variant MsvcMissingEnvironment)
  (variant MsvcToolNotFound)
  (variant MsvcSetupUnavailable)
  (variant OkMsvcTool)
  (variant ErrMsvcTool)
  (variant MsvcNoString)
  (variant MsvcSomeString)
  (variant MsvcNoToolset)
  (variant MsvcSomeToolset)
  (variant MsvcNoSdk)
  (variant MsvcSomeSdk))