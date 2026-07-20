;# MSVC tool discovery: find link.exe and its command environment.
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
;# (import stdlib.msvc)
;# (define target : String "x86_64-pc-windows-msvc")
;# (define tool : String "link.exe")
;# (define resolved : msvc.ResultMsvcTool
;#   (msvc.find-tool (& target) (& tool)))
;# ```
(import stdlib.env)
(import stdlib.io)
(import stdlib.fs)
(import stdlib.process)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

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
(define (tool-executable [tool : MsvcTool]) : String
  (struct-get tool executable))

;: Return the PATH override for invoking the tool.
(define (tool-path [tool : MsvcTool]) : String
  (struct-get tool path))

;: Return the LIB override for invoking the tool.
(define (tool-lib [tool : MsvcTool]) : String
  (struct-get tool lib))

;: Return the INCLUDE override for invoking the tool.
(define (tool-include [tool : MsvcTool]) : String
  (struct-get tool include))

;: Return process environment overrides for invoking the tool.
(define (tool-process-env [tool : MsvcTool]) : process.ProcessEnvList
  (process.env-cons
    "PATH"
    (tool-path tool)
    (process.env-cons
      "LIB"
      (tool-lib tool)
      (process.env-cons "INCLUDE" (tool-include tool) (process.env-empty)))))

;: Return vector-backed process environment overrides for invoking the tool.
(define (tool-process-env-vec [tool : MsvcTool]) : process.ProcessEnvVec
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (begin
      (process.env-vec-append (&mut env) "PATH" (tool-path tool))
      (process.env-vec-append (&mut env) "LIB" (tool-lib tool))
      (process.env-vec-append (&mut env) "INCLUDE" (tool-include tool))
      env)))

;: Render a discovery error as a diagnostic message.
(define (error-message [error : MsvcError]) : String
  (match error
    [(MsvcUnsupported message) message]
    [(MsvcMissingEnvironment message) message]
    [(MsvcToolNotFound message) message]
    [(MsvcSetupUnavailable message) message]))

;: Return true when the host path-list separator identifies Windows.
(define (host-windows?) : bool
  (string.eq (env.path-list-separator) ";"))

;: Return true when `target` is a v1-supported MSVC target triple.
(define (supported-target? [target : (& target str)]) : bool
  (let
    [supported : String "x86_64-pc-windows-msvc"]
    (string.eq target (& supported))))

;: Return true when `c` is an ASCII decimal digit.
(define (digit? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (and (>= code (cast '0' : i64)) (<= code (cast '9' : i64)))))

;: Return the numeric value of an ASCII decimal digit, or zero otherwise.
(define (digit-value [c : char]) : i64
  (if (digit? c)
    (- (cast c : i64) (cast '0' : i64))
    0))

;: Read one dotted numeric version segment starting at `index`.
(define (version-read-segment [version : String] [index : i64]) : MsvcVersionCursor
  (let
    [n : i64 (string-length version)]
    [i : i64 index]
    [value : i64 0]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (let
          [c : char (string-ref version i)]
          (if (string.char-eq c '.')
            (set! done true)
            (begin
              (if (digit? c)
                (set! value (+ (* value 10) (digit-value c)))
                unit)
              (set! i (+ i 1))))))
      (MsvcVersionCursor value i))))

;: Advance past a dotted version separator if one is present.
(define (version-next-index [version : String] [index : i64]) : i64
  (let
    [n : i64 (string-length version)]
    (if (and (< index n) (string.char-eq (string-ref version index) '.'))
      (+ index 1)
      index)))

;: Return true when owned `left` is a newer dotted numeric version than `right`.
(define (version-greater-owned? [left : String] [right : String]) : bool
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
            (stdlib.msvc.version-read-segment left left-index)]
          [right-segment : MsvcVersionCursor
            (stdlib.msvc.version-read-segment right right-index)]
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
                  (version-next-index left (struct-get left-segment next)))
                (set!
                  right-index
                  (version-next-index right (struct-get right-segment next))))))))
      greater)))

;: Return true when `left` is a newer dotted numeric version than `right`.
(define (version-greater? [left : (& left str)] [right : (& right str)]) : bool
  (let
    [left-text : String (string.copy left)]
    [right-text : String (string.copy right)]
    (version-greater-owned? left-text right-text)))

;: Return true when `path` exists, mapping probe errors to false.
(define (path-exists? [path : (& path str)]) : bool
  (match (io.try-file-exists? path)
    [(io.OkIoBool exists) exists]
    [(io.ErrIoBool _) false]))

;: Return true when an owned path exists through the borrowed public helper.
(define (path-exists-owned? [path : String]) : bool
  (path-exists? (& path)))

;: Return true when an owned path exists and is a directory.
(define (dir-exists-owned? [path : String]) : bool
  (= (fs.file-kind-status path) fs.fs-file-kind-directory-code))

;: Join two filesystem path segments using the platform separator.
(define (path-join [left : String] [right : String]) : String
  (fs.path-join (& left) (& right)))

;: Join three filesystem path segments.
(define (path-join3 [a : String] [b : String] [c : String]) : String
  (path-join (path-join a b) c))

;: Join four filesystem path segments.
(define (path-join4 [a : String] [b : String] [c : String] [d : String]) : String
  (path-join (path-join3 a b c) d))

;: Join five filesystem path segments.
(define (path-join5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (path-join (path-join4 a b c d) e))

;: Join six filesystem path segments.
(define (path-join6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : String
  (path-join (path-join5 a b c d e) f))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (search-dirs-vec-owned-from
  [dirs : (& dirs svec.Vec)]
  [index : i64]
  [tool : String]) : MsvcMaybeString
  (if (>= index (svec.len dirs))
    (MsvcNoString)
    (let
      [candidate : String (path-join (svec.get dirs index "") tool)]
      (if (path-exists-owned? candidate)
        (MsvcSomeString candidate)
        (search-dirs-vec-owned-from dirs (+ index 1) tool)))))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (search-dirs-vec-owned [dirs : svec.Vec] [tool : String]) : MsvcMaybeString
  (search-dirs-vec-owned-from (& dirs) 0 tool))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (search-dirs-owned [dirs : env.EnvStringList] [tool : String]) : MsvcMaybeString
  (search-dirs-vec-owned (env.string-list-to-vec dirs) tool))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (search-dirs-vec [dirs : svec.Vec] [tool : (& tool str)]) : MsvcMaybeString
  (let
    [tool-text : String (string.copy tool)]
    (search-dirs-vec-owned dirs tool-text)))

;: Search PATH directories for `tool`, returning the first existing candidate.
(define (search-dirs [dirs : env.EnvStringList] [tool : (& tool str)]) : MsvcMaybeString
  (let
    [tool-text : String (string.copy tool)]
    (search-dirs-owned dirs tool-text)))

;: Locate `tool` on the PATH environment variable.
(define (find-on-path [tool : (& tool str)]) : MsvcMaybeString
  (let
    [name : String "PATH"]
    (match (env.path-list-vec (& name))
      [(env.EnvNoStringVec) (MsvcNoString)]
      [(env.EnvSomeStringVec dirs) (search-dirs-vec dirs tool)])))

;: Read an environment variable or the empty string when it is unset.
(define (env-or-empty [name : (& name str)]) : String
  (match (env.get name)
    [(env.EnvSomeString value) value]
    [(env.EnvNoString) ""]))

;: Read an owned environment variable name or the empty string when it is unset.
(define (env-or-empty-owned [name : String]) : String
  (env-or-empty (& name)))

;: Read an owned environment variable name, or return `fallback`.
(define (env-or-default-owned [name : String] [fallback : String]) : String
  (let
    [value : String (env-or-empty-owned name)]
    (if (string.eq value "")
      fallback
      value)))

;: Join owned `head` before an optional PATH-style suffix.
(define (path-list-prepend-owned [head : String] [tail : String]) : String
  (if (string.eq tail "")
    head
    (str_cat.str-cat head (env.path-list-separator) tail)))

;: Join `head` before an optional PATH-style suffix.
(define (path-list-prepend [head : (& head str)] [tail : (& tail str)]) : String
  (let
    [head-text : String (string.copy head)]
    [tail-text : String (string.copy tail)]
    (path-list-prepend-owned head-text tail-text)))

;: Join two owned required PATH-style entries.
(define (path-list-join2-owned [a : String] [b : String]) : String
  (str_cat.str-cat a (env.path-list-separator) b))

;: Join two required PATH-style entries.
(define (path-list-join2 [a : (& a str)] [b : (& b str)]) : String
  (let
    [a-text : String (string.copy a)]
    [b-text : String (string.copy b)]
    (path-list-join2-owned a-text b-text)))

;: Join three owned required PATH-style entries.
(define (path-list-join3-owned [a : String] [b : String] [c : String]) : String
  (path-list-join2-owned (path-list-join2-owned a b) c))

;: Join three required PATH-style entries.
(define (path-list-join3 [a : (& a str)] [b : (& b str)] [c : (& c str)]) : String
  (let
    [a-text : String (string.copy a)]
    [b-text : String (string.copy b)]
    [c-text : String (string.copy c)]
    (path-list-join3-owned a-text b-text c-text)))

;: Join four owned required PATH-style entries.
(define (path-list-join4-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (path-list-join2-owned (path-list-join3-owned a b c) d))

;: Join four required PATH-style entries.
(define (path-list-join4
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]) : String
  (let
    [a-text : String (string.copy a)]
    [b-text : String (string.copy b)]
    [c-text : String (string.copy c)]
    [d-text : String (string.copy d)]
    (path-list-join4-owned a-text b-text c-text d-text)))

;: Join an optional inherited path list after required entries.
(define (path-list-join3-with-tail-owned
  [a : String]
  [b : String]
  [c : String]
  [tail : String]) : String
  (path-list-prepend-owned (path-list-join3-owned a b c) tail))

;: Join an optional inherited path list after required entries.
(define (path-list-join3-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [tail : (& tail str)]) : String
  (let
    [a-text : String (string.copy a)]
    [b-text : String (string.copy b)]
    [c-text : String (string.copy c)]
    [tail-text : String (string.copy tail)]
    (path-list-join3-with-tail-owned a-text b-text c-text tail-text)))

;: Join an optional inherited path list after two required entries.
(define (path-list-join2-with-tail-owned
  [a : String]
  [b : String]
  [tail : String]) : String
  (path-list-prepend-owned (path-list-join2-owned a b) tail))

;: Join an optional inherited path list after two required entries.
(define (path-list-join2-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [tail : (& tail str)]) : String
  (let
    [a-text : String (string.copy a)]
    [b-text : String (string.copy b)]
    [tail-text : String (string.copy tail)]
    (path-list-join2-with-tail-owned a-text b-text tail-text)))

;: Join an optional inherited path list after four required entries.
(define (path-list-join4-with-tail-owned
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [tail : String]) : String
  (path-list-prepend-owned (path-list-join4-owned a b c d) tail))

;: Join an optional inherited path list after four required entries.
(define (path-list-join4-with-tail
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]
  [tail : (& tail str)]) : String
  (let
    [a-text : String (string.copy a)]
    [b-text : String (string.copy b)]
    [c-text : String (string.copy c)]
    [d-text : String (string.copy d)]
    [tail-text : String (string.copy tail)]
    (path-list-join4-with-tail-owned a-text b-text c-text d-text tail-text)))

;: Build a configured tool result once the executable path is known.
(define (configured-result [executable : String]) : ResultMsvcTool
  (let
    [name : String "LIB"]
    (match (env.get (& name))
      [(env.EnvNoString)
        (ErrMsvcTool
          (MsvcMissingEnvironment
            "msvc: LIB is not set; run from a Developer Command Prompt or use auto-discovery"))]
      [(env.EnvSomeString lib)
        (let
          [name : String "INCLUDE"]
          (match (env.get (& name))
            [(env.EnvNoString)
              (ErrMsvcTool
                (MsvcMissingEnvironment
                  "msvc: INCLUDE is not set; run from a Developer Command Prompt or use auto-discovery"))]
            [(env.EnvSomeString include)
              (OkMsvcTool
                (MsvcTool executable (env-or-empty-owned "PATH") lib include))]))])))

;: Detect a configured MSVC command environment and resolve `tool`.
(define (find-tool-configured [tool : (& tool str)]) : ResultMsvcTool
  (match (find-on-path tool)
    [(MsvcSomeString executable) (configured-result executable)]
    [(MsvcNoString)
      (let
        [tool-text : String (string.copy tool)]
        (ErrMsvcTool
          (MsvcToolNotFound
            (str_cat.str-cat
              "msvc: could not find "
              tool-text
              " on PATH; run from a Developer Command Prompt or install Visual Studio Build Tools"))))]))

;: Program Files root used by ordinary Visual Studio SKUs.
(define (program-files) : String
  (env-or-default-owned "ProgramFiles" "C:/Program Files"))

;: Program Files (x86) root used by Build Tools and Windows Kits.
(define (program-files-x86) : String
  (env-or-default-owned "ProgramFiles(x86)" "C:/Program Files (x86)"))

;: Return a standard Visual Studio VC toolset parent directory.
(define (vs-toolset-parent
  [program-files : String]
  [year : String]
  [edition : String]) : String
  (path-join6
    program-files
    "Microsoft Visual Studio"
    year
    edition
    "VC"
    "Tools/MSVC"))

;: Candidate Visual Studio / Build Tools toolset parent directories.
(define (toolset-parent-candidates) : svec.Vec
  (let
    [pf : String (program-files)]
    [pfx : String (program-files-x86)]
    [items : svec.Vec (svec.with-capacity 8)]
    (begin
      (svec.push (&mut items) (vs-toolset-parent pf "2022" "Enterprise"))
      (svec.push (&mut items) (vs-toolset-parent pf "2022" "Professional"))
      (svec.push (&mut items) (vs-toolset-parent pf "2022" "Community"))
      (svec.push (&mut items) (vs-toolset-parent pfx "2022" "BuildTools"))
      (svec.push (&mut items) (vs-toolset-parent pf "2019" "Enterprise"))
      (svec.push (&mut items) (vs-toolset-parent pf "2019" "Professional"))
      (svec.push (&mut items) (vs-toolset-parent pf "2019" "Community"))
      (svec.push (&mut items) (vs-toolset-parent pfx "2019" "BuildTools"))
      items)))

;: Return the bin directory for host x64 -> target x64 tools.
(define (toolset-bin-dir [toolset-root : String]) : String
  (path-join4 toolset-root "bin" "Hostx64" "x64"))

;: Return a tool executable path inside a toolset root.
(define (toolset-tool-path [toolset-root : String] [tool : String]) : String
  (path-join (toolset-bin-dir toolset-root) tool))

;: Scan one VC Tools/MSVC parent for the newest version containing `tool`.
(define (toolset-scan-entries
  [entries : fs.FsStringVector]
  [index : i64]
  [parent : String]
  [tool : String]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeToolset
  (if (>= index (fs.string-vector-len (& entries)))
    (if has-best
      (MsvcSomeToolset (MsvcToolset best-root best-version))
      (MsvcNoToolset))
    (let
      [version : String (fs.string-vector-get (& entries) index "")]
      [toolset-root : String (path-join parent version)]
      [tool-path : String (toolset-tool-path toolset-root tool)]
      [usable : bool (path-exists-owned? tool-path)]
      (if (if usable
        (if has-best
          (version-greater-owned? version best-version)
          true)
        false)
        (toolset-scan-entries
          entries
          (+ index 1)
          parent
          tool
          toolset-root
          version
          true)
        (toolset-scan-entries
          entries
          (+ index 1)
          parent
          tool
          best-root
          best-version
          has-best)))))

;: Return the newest toolset under one parent, if any.
(define (find-toolset-in-parent [parent : String] [tool : String]) : MsvcMaybeToolset
  (let
    [result : MsvcMaybeToolset (MsvcNoToolset)]
    (begin
      ;; Keep the explicit result local: aggregate match-arm returns are not supported.
      (match (fs.try-read-dir-vec (& parent))
        [(fs.OkIoStringVector entries)
          (set! result (toolset-scan-entries entries 0 parent tool "" "" false))]
        [(fs.ErrIoStringVector _) (set! result (MsvcNoToolset))])
      result)))

;: Return true when `candidate` should replace the current best toolset.
(define (toolset-candidate-newer?
  [candidate : MsvcToolset]
  [best-version : String]
  [has-best : bool]) : bool
  (if has-best
    (version-greater-owned? (struct-get candidate version) best-version)
    true))

;: Scan standard Visual Studio locations for the newest toolset containing `tool`.
(define (find-toolset-parents
  [parents : (& parents svec.Vec)]
  [index : i64]
  [tool : String]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeToolset
  (if (>= index (svec.len parents))
    (if has-best
      (MsvcSomeToolset (MsvcToolset best-root best-version))
      (MsvcNoToolset))
    (let
      [parent : String (svec.get parents index "")]
      (match (find-toolset-in-parent parent tool)
        [(MsvcNoToolset)
          (find-toolset-parents
            parents
            (+ index 1)
            tool
            best-root
            best-version
            has-best)]
        [(MsvcSomeToolset candidate)
          (if (toolset-candidate-newer? candidate best-version has-best)
            (find-toolset-parents
              parents
              (+ index 1)
              tool
              (struct-get candidate root)
              (struct-get candidate version)
              true)
            (find-toolset-parents
              parents
              (+ index 1)
              tool
              best-root
              best-version
              has-best))]))))

;: Find the newest installed VC toolset containing `tool`.
(define (find-toolset [tool : String]) : MsvcMaybeToolset
  (let
    [parents : svec.Vec (toolset-parent-candidates)]
    (find-toolset-parents (& parents) 0 tool "" "" false)))

;: Candidate Windows SDK roots.
(define (sdk-root-candidates) : svec.Vec
  (let
    [env-root : String (env-or-empty-owned "WindowsSdkDir")]
    [pfx : String (program-files-x86)]
    [pf : String (program-files)]
    [items : svec.Vec (svec.with-capacity 3)]
    (begin
      (if (string.eq env-root "")
        unit
        (svec.push (&mut items) env-root))
      (svec.push (&mut items) (path-join3 pfx "Windows Kits" "10"))
      (svec.push (&mut items) (path-join3 pf "Windows Kits" "10"))
      items)))

;: Return the root for one Windows SDK version.
(define (sdk-version-root [sdk-root : String] [version : String]) : String
  (path-join (path-join sdk-root "Lib") version))

;: Return the SDK um/x64 library directory.
(define (sdk-um-lib-dir [sdk : MsvcSdk]) : String
  (path-join4 (struct-get sdk root) "Lib" (struct-get sdk version) "um/x64"))

;: Return the SDK ucrt/x64 library directory.
(define (sdk-ucrt-lib-dir [sdk : MsvcSdk]) : String
  (path-join4 (struct-get sdk root) "Lib" (struct-get sdk version) "ucrt/x64"))

;: Return one SDK include directory.
(define (sdk-include-dir [sdk : MsvcSdk] [name : String]) : String
  (path-join4 (struct-get sdk root) "Include" (struct-get sdk version) name))

;: Return true when a Windows SDK version has the pieces needed by link.exe.
(define (sdk-version-usable? [sdk-root : String] [version : String]) : bool
  (let
    [lib-root : String (stdlib.msvc.sdk-version-root sdk-root version)]
    [kernel32 : String
      (stdlib.msvc.path-join3 lib-root "um/x64" "kernel32.lib")]
    [ucrt : String (stdlib.msvc.path-join3 lib-root "ucrt/x64" "ucrt.lib")]
    [include-root : String
      (stdlib.msvc.path-join (stdlib.msvc.path-join sdk-root "Include") version)]
    (and
      (stdlib.msvc.path-exists-owned? kernel32)
      (stdlib.msvc.path-exists-owned? ucrt)
      (stdlib.msvc.dir-exists-owned?
        (stdlib.msvc.path-join include-root "shared"))
      (stdlib.msvc.dir-exists-owned? (stdlib.msvc.path-join include-root "um"))
      (stdlib.msvc.dir-exists-owned?
        (stdlib.msvc.path-join include-root "ucrt")))))

;: Scan one Windows SDK root for the newest usable version.
(define (sdk-scan-entries
  [entries : fs.FsStringVector]
  [index : i64]
  [sdk-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeSdk
  (if (>= index (fs.string-vector-len (& entries)))
    (if has-best
      (MsvcSomeSdk (MsvcSdk sdk-root best-version))
      (MsvcNoSdk))
    (let
      [version : String (fs.string-vector-get (& entries) index "")]
      [usable : bool (sdk-version-usable? sdk-root version)]
      (if (if usable
        (if has-best
          (version-greater-owned? version best-version)
          true)
        false)
        (sdk-scan-entries entries (+ index 1) sdk-root version true)
        (sdk-scan-entries entries (+ index 1) sdk-root best-version has-best)))))

;: Return the newest usable SDK under one root, if any.
(define (find-sdk-in-root [sdk-root : String]) : MsvcMaybeSdk
  (let
    [lib-dir : String (path-join sdk-root "Lib")]
    (match (fs.try-read-dir-vec (& lib-dir))
      [(fs.OkIoStringVector entries)
        (sdk-scan-entries entries 0 sdk-root "" false)]
      [(fs.ErrIoStringVector _) (MsvcNoSdk)])))

;: Return true when `candidate` should replace the current best SDK.
(define (sdk-candidate-newer?
  [candidate : MsvcSdk]
  [best-version : String]
  [has-best : bool]) : bool
  (if has-best
    (version-greater-owned? (struct-get candidate version) best-version)
    true))

;: Scan standard Windows SDK roots.
(define (find-sdk-roots
  [roots : (& roots svec.Vec)]
  [index : i64]
  [best-root : String]
  [best-version : String]
  [has-best : bool]) : MsvcMaybeSdk
  (if (>= index (svec.len roots))
    (if has-best
      (MsvcSomeSdk (MsvcSdk best-root best-version))
      (MsvcNoSdk))
    (let
      [root : String (svec.get roots index "")]
      (match (find-sdk-in-root root)
        [(MsvcNoSdk)
          (find-sdk-roots roots (+ index 1) best-root best-version has-best)]
        [(MsvcSomeSdk candidate)
          (if (sdk-candidate-newer? candidate best-version has-best)
            (find-sdk-roots
              roots
              (+ index 1)
              (struct-get candidate root)
              (struct-get candidate version)
              true)
            (find-sdk-roots roots (+ index 1) best-root best-version has-best))]))))

;: Find the newest usable Windows SDK.
(define (find-sdk) : MsvcMaybeSdk
  (let
    [roots : svec.Vec (sdk-root-candidates)]
    (find-sdk-roots (& roots) 0 "" "" false)))

;: Build an auto-discovered MSVC tool result from a toolset and SDK.
(define (auto-result [toolset : MsvcToolset] [sdk : MsvcSdk] [tool : String]) : MsvcTool
  (let
    [toolset-root : String (struct-get toolset root)]
    [bin-dir : String (toolset-bin-dir toolset-root)]
    [toolset-lib : String (path-join3 toolset-root "lib" "x64")]
    [toolset-include : String (path-join toolset-root "include")]
    [sdk-um-lib : String (sdk-um-lib-dir sdk)]
    [sdk-ucrt-lib : String (sdk-ucrt-lib-dir sdk)]
    [sdk-shared-include : String (sdk-include-dir sdk "shared")]
    [sdk-um-include : String (sdk-include-dir sdk "um")]
    [sdk-ucrt-include : String (sdk-include-dir sdk "ucrt")]
    (MsvcTool
      (toolset-tool-path toolset-root tool)
      (path-list-prepend-owned bin-dir (env-or-empty-owned "PATH"))
      (path-list-join3-with-tail-owned
        toolset-lib
        sdk-um-lib
        sdk-ucrt-lib
        (env-or-empty-owned "LIB"))
      (path-list-join4-with-tail-owned
        toolset-include
        sdk-shared-include
        sdk-um-include
        sdk-ucrt-include
        (env-or-empty-owned "INCLUDE")))))

;: Discover a Visual Studio toolset and Windows SDK from standard locations.
(define (find-tool-auto [tool : (& tool str)]) : ResultMsvcTool
  (let
    [tool-text : String (string.copy tool)]
    (match (find-toolset tool-text)
      [(MsvcNoToolset)
        (ErrMsvcTool
          (MsvcToolNotFound
            (str_cat.str-cat
              "msvc: could not discover "
              tool-text
              " under standard Visual Studio Build Tools locations")))]
      [(MsvcSomeToolset toolset)
        (match (find-sdk)
          [(MsvcNoSdk)
            (ErrMsvcTool
              (MsvcSetupUnavailable
                "msvc: could not discover a usable Windows SDK under standard locations"))]
          [(MsvcSomeSdk sdk) (OkMsvcTool (auto-result toolset sdk tool-text))])])))

;: Find an MSVC tool such as `link.exe` and its command environment.
;:
;: Resolves the tool from a configured Developer Command Prompt environment
;: first, then from standard Visual Studio / Windows SDK install locations.
(define (find-tool [target : (& target str)] [tool : (& tool str)]) : ResultMsvcTool
  (if (not (host-windows?))
    (ErrMsvcTool
      (MsvcUnsupported
        "msvc: tool discovery is unsupported on non-Windows hosts"))
    (if (not (supported-target? target))
      (ErrMsvcTool
        (let
          [target-text : String (string.copy target)]
          (MsvcUnsupported
            (str_cat.str-cat "msvc: unsupported target " target-text))))
      (match (find-tool-configured tool)
        [(OkMsvcTool resolved) (OkMsvcTool resolved)]
        [(ErrMsvcTool _) (find-tool-auto tool)]))))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (test-fail)))

;: Inline test integer assertion.
(define (test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (test-assert-string-eq [actual : String] [expected : String]) : unit
  (test-assert (string.eq actual expected)))

;: Inline test helper to unwrap `ResultIoString`.
(define (test-expect-ok-string [result : io.ResultIoString]) : String
  (match result
    [(io.OkIoString value) value]
    [(io.ErrIoString _) ""]))

;: Inline test helper to assert `ResultIoUnit`.
(define (test-assert-ok-unit [result : io.ResultIoUnit]) : unit
  (match result
    [(io.OkIoUnit) unit]
    [(io.ErrIoUnit _) (test-fail)]))

;: Inline test mkdir helper.
(define (test-mkdir [path : String]) : unit
  (test-assert-ok-unit (fs.try-mkdir-if-missing (& path))))

;: Inline test write-file helper.
(define (test-write [path : String] [contents : String]) : unit
  (test-assert-ok-unit (io.try-write-file (& path) (& contents))))

;: Inline test helper to create a fake toolset bin directory.
(define (test-mkdir-toolset-bin [toolset-root : String]) : String
  (let
    [bin-root : String (path-join toolset-root "bin")]
    [host-root : String (path-join bin-root "Hostx64")]
    [target-root : String (path-join host-root "x64")]
    (begin
      (test-mkdir bin-root)
      (test-mkdir host-root)
      (test-mkdir target-root)
      target-root)))

;: Inline test helper to create one fake MSVC toolset version.
(define (test-make-toolset-version
  [parent : String]
  [version : String]
  [with-tool : bool]) : String
  (let
    [toolset-root : String (path-join parent version)]
    (begin
      (test-mkdir toolset-root)
      (let
        [target-root : String (test-mkdir-toolset-bin toolset-root)]
        (if with-tool
          (test-write (path-join target-root "link.exe") "fake")
          unit))
      toolset-root)))

;: Inline test assertion for fake toolset scanning.
(define (test-assert-toolset-scan [parent : String]) : unit
  (let
    [old-root : String (test-make-toolset-version parent "14.10.0" true)]
    [new-root : String (test-make-toolset-version parent "14.20.0" true)]
    [_ignored-root : String (test-make-toolset-version parent "14.99.0" false)]
    (match (find-toolset-in-parent parent "link.exe")
      [(MsvcSomeToolset toolset)
        (begin
          (test-assert-string-eq (struct-get toolset version) "14.20.0")
          (test-assert-string-eq (struct-get toolset root) new-root)
          (test-assert (not (string.eq old-root new-root))))]
      [(MsvcNoToolset) (test-fail)])))

;: Inline test helper to create fake SDK directory roots.
(define (test-mkdir-sdk-version-roots [sdk-root : String] [version : String]) : unit
  (let
    [lib-root : String (path-join sdk-root "Lib")]
    [include-root : String (path-join sdk-root "Include")]
    [lib-version : String (path-join lib-root version)]
    [include-version : String (path-join include-root version)]
    [um-root : String (path-join lib-version "um")]
    [ucrt-root : String (path-join lib-version "ucrt")]
    (begin
      (test-mkdir lib-root)
      (test-mkdir include-root)
      (test-mkdir lib-version)
      (test-mkdir include-version)
      (test-mkdir um-root)
      (test-mkdir (path-join um-root "x64"))
      (test-mkdir ucrt-root)
      (test-mkdir (path-join ucrt-root "x64"))
      (test-mkdir (path-join include-version "shared"))
      (test-mkdir (path-join include-version "um"))
      (test-mkdir (path-join include-version "ucrt")))))

;: Inline test helper to create one fake SDK version.
(define (test-make-sdk-version
  [sdk-root : String]
  [version : String]
  [usable : bool]) : unit
  (begin
    (test-mkdir-sdk-version-roots sdk-root version)
    (if usable
      (let
        [lib-version : String (path-join (path-join sdk-root "Lib") version)]
        (begin
          (test-write
            (path-join (path-join lib-version "um/x64") "kernel32.lib")
            "kernel32")
          (test-write
            (path-join (path-join lib-version "ucrt/x64") "ucrt.lib")
            "ucrt")))
      unit)))

;: Inline test assertion for fake SDK scanning.
(define (test-assert-sdk-scan [sdk-root : String]) : unit
  (begin
    (test-make-sdk-version sdk-root "10.0.1" true)
    (test-make-sdk-version sdk-root "10.0.2" true)
    (test-make-sdk-version sdk-root "10.0.9" false)
    (match (find-sdk-in-root sdk-root)
      [(MsvcSomeSdk sdk)
        (begin
          (test-assert-string-eq (struct-get sdk root) sdk-root)
          (test-assert-string-eq (struct-get sdk version) "10.0.2"))]
      [(MsvcNoSdk) (test-fail)])))

;: Inline test: verify the default toolset parent candidate list.
(define (test-candidates-main) : unit
  (let
    [items : svec.Vec (toolset-parent-candidates)]
    (test-assert-i64-eq (svec.len (& items)) 8)))

;: Inline test: scan a minimal fake toolset parent directory.
(define (test-toolset-scan-main) : unit
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String (test-expect-ok-string (fs.try-create-temp-dir (& prefix)))]
    [toolset-parent : String (path-join root "ToolsMSVC")]
    (begin
      (test-mkdir toolset-parent)
      (test-assert-toolset-scan toolset-parent))))

;: Inline test fixture: create fake toolset versions without scanning them.
(define (test-toolset-fixture-main) : unit
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String (test-expect-ok-string (fs.try-create-temp-dir (& prefix)))]
    [toolset-parent : String (path-join root "ToolsMSVC")]
    (begin
      (test-mkdir toolset-parent)
      (test-make-toolset-version toolset-parent "14.10.0" true)
      (test-make-toolset-version toolset-parent "14.20.0" true)
      (test-make-toolset-version toolset-parent "14.99.0" false)
      unit)))

;: Inline test: choose the newest complete fake toolset version.
(define (test-toolset-find-main) : unit
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String (test-expect-ok-string (fs.try-create-temp-dir (& prefix)))]
    [toolset-parent : String (path-join root "ToolsMSVC")]
    (begin
      (test-mkdir toolset-parent)
      (let
        [old-root : String
          (test-make-toolset-version toolset-parent "14.10.0" true)]
        [new-root : String
          (test-make-toolset-version toolset-parent "14.20.0" true)]
        [_ignored-root : String
          (test-make-toolset-version toolset-parent "14.99.0" false)]
        (match (find-toolset-in-parent toolset-parent "link.exe")
          [(MsvcSomeToolset toolset)
            (begin
              (test-assert-string-eq (struct-get toolset version) "14.20.0")
              (test-assert-string-eq (struct-get toolset root) new-root)
              (test-assert (not (string.eq old-root new-root))))]
          [(MsvcNoToolset) (test-fail)])))))

;: Inline test: read back fake toolset directory entries.
(define (test-toolset-read-dir-main) : unit
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String (test-expect-ok-string (fs.try-create-temp-dir (& prefix)))]
    [toolset-parent : String (path-join root "ToolsMSVC")]
    (begin
      (test-mkdir toolset-parent)
      (test-make-toolset-version toolset-parent "14.10.0" true)
      (test-make-toolset-version toolset-parent "14.20.0" true)
      (test-make-toolset-version toolset-parent "14.99.0" false)
      (match (fs.try-read-dir-vec (& toolset-parent))
        [(fs.OkIoStringVector entries)
          (begin
            (test-assert (fs.string-vector-contains? (& entries) "14.10.0"))
            (test-assert (fs.string-vector-contains? (& entries) "14.20.0"))
            (test-assert (fs.string-vector-contains? (& entries) "14.99.0")))]
        [(fs.ErrIoStringVector _) (test-fail)]))))

;: Inline test: scan already-read fake toolset entries.
(define (test-toolset-scan-entries-main) : unit
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String (test-expect-ok-string (fs.try-create-temp-dir (& prefix)))]
    [toolset-parent : String (path-join root "ToolsMSVC")]
    (begin
      (test-mkdir toolset-parent)
      (let
        [old-root : String
          (test-make-toolset-version toolset-parent "14.10.0" true)]
        [new-root : String
          (test-make-toolset-version toolset-parent "14.20.0" true)]
        [_ignored-root : String
          (test-make-toolset-version toolset-parent "14.99.0" false)]
        (match (fs.try-read-dir-vec (& toolset-parent))
          [(fs.OkIoStringVector entries)
            (match (toolset-scan-entries
              entries
              0
              toolset-parent
              "link.exe"
              ""
              ""
              false)
              [(MsvcSomeToolset toolset)
                (begin
                  (test-assert-string-eq (struct-get toolset version) "14.20.0")
                  (test-assert-string-eq (struct-get toolset root) new-root)
                  (test-assert (not (string.eq old-root new-root))))]
              [(MsvcNoToolset) (test-fail)])]
          [(fs.ErrIoStringVector _) (test-fail)])))))

;: Inline test: choose the newest complete fake Windows SDK version.
(define (test-sdk-scan-main) : unit
  (let
    [prefix : String "typelisp msvc vector scan"]
    [root : String (test-expect-ok-string (fs.try-create-temp-dir (& prefix)))]
    [sdk-root : String (path-join root "WindowsKits10")]
    (begin
      (test-mkdir sdk-root)
      (test-assert-sdk-scan sdk-root))))

;: Inline test entry point for the MSVC discovery API.
(define (test-api-main) : unit
  (begin
    (test-candidates-main)
    (test-toolset-scan-main)
    (test-sdk-scan-main)))