;; git_protocol_core.tl - Transport-independent Git upload-pack protocol for a
;; fresh exact-object fetch (#7074).
;;
;; Protocol v2 (capability advertisement, ls-refs, fetch) and the documented
;; v0/v1 upload-pack subset that fetch needs, over the pkt-line framing of
;; `git_pkt_line_core`. Everything here consumes and produces byte strings and
;; typed records: no process, network, compression, hashing or filesystem
;; operation, and no HTTP or SSH policy. `git-session-*` drives one fetch from
;; arbitrarily fragmented upload-pack output for the transport adapters.
;;
;; The fetch request is the package cache's exact-want profile: no `have`, no
;; thin pack, filter, packfile URI or bundle URI; `done`; and `deepen 1` exactly
;; when the server supports shallow. `ofs-delta` and `no-progress` are opt-in,
;; and in v0/v1 only when advertised. A response section the request did not
;; ask for, or one out of order, fails.
(import git_object_core as git_object)
(import git_pkt_line_core as pkt)
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.set)
(import stdlib.str_cat)
(import stdlib.string)

;; Name sets are written with `insert-ref!`: the generated `insert!` macro does
;; not resolve in a test-bearing importer (#8760).
(import (set.set String) as git_name_set)

(defstruct GitCapability
  (key String)
  (value String)
  (has-value bool))

(defenum GitProtocolVersion
  (V0)
  (V1)
  (V2))

;: Bounds on peer-controlled sizes. Remote text (progress and fatal errors) is
;: cut to `max-text-bytes` per message; progress past `max-progress-bytes` in
;: total is dropped.
(defstruct GitProtocolLimits
  (max-refs i64)
  (max-capabilities i64)
  (max-text-bytes i64)
  (max-progress-bytes i64))

(define (git-protocol-default-limits) : GitProtocolLimits
  (GitProtocolLimits 65536 256 1024 1048576))

;: A validated advertisement. `refs` is empty for v2, which advertises refs
;: only through ls-refs, and for an empty v0/v1 repository.
(defstruct GitAdvertisement
  (version GitProtocolVersion)
  (format git_object.GitObjectFormat)
  (has-object-format bool)
  (capabilities (__tl_dyn-array GitCapability))
  (refs (__tl_dyn-array git_object.GitAdvertisedRef)))

(defenum ResultGitAdvertisement
  (Ok GitAdvertisement)
  (Err pkt.GitProtocolError))

(defenum ResultGitCapability
  (Ok GitCapability)
  (Err pkt.GitProtocolError))

(defenum ResultGitFormat
  (Ok git_object.GitObjectFormat)
  (Err pkt.GitProtocolError))

(defenum ResultGitRef
  (Ok git_object.GitAdvertisedRef)
  (Err pkt.GitProtocolError))

(defenum ResultGitProtocolId
  (Ok git_object.GitObjectId)
  (Err pkt.GitProtocolError))

(defenum ResultGitUnit
  (Ok)
  (Err pkt.GitProtocolError))

(define (git-protocol-byte [bytes : (& bytes str)] [index : i64]) : i64
  (cast (string.string-ref bytes index) : i64))

(define (git-protocol-copy [text : (& text str)]) : String
  (string.substring text 0 (string.string-length text)))

(define (git-protocol-starts-with?
  [text : (& text str)]
  [prefix : (& prefix str)]) : bool
  (let
    [count : i64 (string.string-length prefix)]
    (and
      (>= (string.string-length text) count)
      (string.eq (string.substring text 0 count) prefix))))

;: The bytes of `text` after `prefix`; the caller has checked the prefix.
(define (git-protocol-after [text : (& text str)] [prefix : (& prefix str)]) : String
  (let
    [start : i64 (string.string-length prefix)]
    (string.substring text start (- (string.string-length text) start))))

;: The first index of `byte` in `text` at or after `start`, or -1.
(define (git-protocol-find [text : (& text str)] [byte : i64] [start : i64]) : i64
  (let
    [index : i64 start]
    [count : i64 (string.string-length text)]
    (while (< index count)
      (when (= (git-protocol-byte text index) byte) (return index))
      (set! index (+ index 1)))
    -1))

;: Whether `text` holds a NUL or LF byte; a text packet carries neither.
(define (git-protocol-control-byte? [text : (& text str)]) : bool
  (or (>= (git-protocol-find text 0 0) 0) (>= (git-protocol-find text 10 0) 0)))

(define (git-protocol-object-id
  [format : git_object.GitObjectFormat]
  [hex : (& hex str)]) : ResultGitProtocolId
  (match (git_object.git-object-id-from-hex format hex)
    [(Ok id) (Ok id)]
    [(Err _) (Err InvalidObjectId)]))

(define (git-protocol-format-copy
  [format : (& format git_object.GitObjectFormat)]) : git_object.GitObjectFormat
  (match format
    [(Sha1) (Sha1)]
    [(Sha256) (Sha256)]))

(define (git-protocol-format-name [format : git_object.GitObjectFormat]) : String
  (match format
    [(Sha1) "sha1"]
    [(Sha256) "sha256"]))

(define (git-protocol-format-from-name [name : (& name str)]) : ResultGitFormat
  (cond
    [(string.eq name "sha1") (Ok (Sha1))]
    [(string.eq name "sha256") (Ok (Sha256))]
    [else (Err UnsupportedObjectFormat)]))

;; --- capabilities ------------------------------------------------------------
(define (git-protocol-key-byte? [byte : i64]) : bool
  (or
    (and (>= byte 97) (<= byte 122))
    (and (>= byte 65) (<= byte 90))
    (and (>= byte 48) (<= byte 57))
    (= byte 45)
    (= byte 95)))

;: A protocol-v2 capability value byte: printable ASCII except the quote,
;: apostrophe, backtick, bar and tilde that gitprotocol-v2 leaves out.
(define (git-protocol-v2-value-byte? [byte : i64]) : bool
  (and
    (>= byte 32)
    (<= byte 126)
    (not (= byte 34))
    (not (= byte 39))
    (not (= byte 96))
    (not (= byte 124))
    (not (= byte 126))))

;: `key[=value]`. A v2 value may hold spaces; a v0/v1 capability is one
;: space-free token, so its value is checked as printable without spaces.
(define (git-protocol-capability [text : (& text str)] [v2 : bool]) : ResultGitCapability
  (let
    [count : i64 (string.string-length text)]
    [equals : i64 (git-protocol-find text 61 0)]
    [key-end : i64
      (if (< equals 0)
        count
        equals)]
    [index : i64 0]
    (when (= key-end 0) (return (Err MalformedCapability)))
    (while (< index key-end)
      (unless
        (git-protocol-key-byte? (git-protocol-byte text index))
        (return (Err MalformedCapability)))
      (set! index (+ index 1)))
    (when (= equals (- count 1)) (return (Err MalformedCapability)))
    (set! index (+ key-end 1))
    (while (< index count)
      (let
        [byte : i64 (git-protocol-byte text index)]
        (unless
          (if v2
            (git-protocol-v2-value-byte? byte)
            (and (> byte 32) (<= byte 126)))
          (return (Err MalformedCapability))))
      (set! index (+ index 1)))
    (Ok
      (GitCapability
        (string.substring text 0 key-end)
        (if (< equals 0)
          ""
          (string.substring text (+ equals 1) (- count (+ equals 1))))
        (>= equals 0)))))

(defenum GitCapabilityLookup
  (Absent)
  (Present String))

;: The value of capability `key` ("" when it has none), or `Absent`.
(define (git-advertisement-capability
  [advert : (& advert GitAdvertisement)]
  [key : (& key str)]) : GitCapabilityLookup
  (let
    [index : i64 0]
    (while (< index (array-length advert.capabilities))
      (let
        [capability : (& advert GitCapability)
          (& (array-ref advert.capabilities index))]
        (when
          (string.eq (& capability.key) key)
          (return (Present (git-protocol-copy (& capability.value))))))
      (set! index (+ index 1)))
    (Absent)))

(define (git-advertisement-has-capability?
  [advert : (& advert GitAdvertisement)]
  [key : (& key str)]) : bool
  (match (git-advertisement-capability advert key)
    [(Present _) true]
    [(Absent) false]))

;: Whether the space-separated feature list `value` names `feature`.
(define (git-protocol-has-feature?
  [value : (& value str)]
  [feature : (& feature str)]) : bool
  (let
    [count : i64 (string.string-length value)]
    [start : i64 0]
    (while (<= start count)
      (let
        [space : i64 (git-protocol-find value 32 start)]
        [end : i64
          (if (< space 0)
            count
            space)]
        (when
          (string.eq (string.substring value start (- end start)) feature)
          (return true))
        (set! start (+ end 1))))
    false))

;: Whether v2 capability `key` lists `feature` in its value.
(define (git-advertisement-has-feature?
  [advert : (& advert GitAdvertisement)]
  [key : (& key str)]
  [feature : (& feature str)]) : bool
  (match (git-advertisement-capability advert key)
    [(Present value) (git-protocol-has-feature? (& value) feature)]
    [(Absent) false]))

;: Record `capability`, refusing a repeated key (other than v0/v1 `symref`,
;: which names one symbolic ref per occurrence). A second `object-format`
;: conflicts with the first.
(define (git-protocol-add-capability!
  [capabilities : (&mut capabilities (__tl_dyn-array GitCapability))]
  [capability : GitCapability]
  [limits : (& limits GitProtocolLimits)]) : ResultGitUnit
  (let
    [index : i64 0]
    (when
      (>= (array-length capabilities) limits.max-capabilities)
      (return (Err CapabilityLimit)))
    (unless
      (string.eq (& capability.key) "symref")
      (while (< index (array-length capabilities))
        (when
          (string.eq (& (array-ref capabilities index).key) (& capability.key))
          (return
            (Err
              (if (string.eq (& capability.key) "object-format")
                (ConflictingObjectFormat)
                (DuplicateCapability)))))
        (set! index (+ index 1))))
    (__tl_array-push! capabilities capability)
    (Ok)))

;: The negotiated object format: `object-format` when advertised, else SHA-1.
(define (git-protocol-capabilities-format
  [capabilities : (& capabilities (__tl_dyn-array GitCapability))]) : ResultGitFormat
  (let
    [index : i64 0]
    (while (< index (array-length capabilities))
      (let
        [capability : (& capabilities GitCapability)
          (& (array-ref capabilities index))]
        (when
          (string.eq (& capability.key) "object-format")
          (return (git-protocol-format-from-name (& capability.value)))))
      (set! index (+ index 1)))
    (Ok (Sha1))))

(define (git-protocol-capabilities-have?
  [capabilities : (& capabilities (__tl_dyn-array GitCapability))]
  [key : (& key str)]) : bool
  (let
    [index : i64 0]
    (while (< index (array-length capabilities))
      (when
        (string.eq (& (array-ref capabilities index).key) key)
        (return true))
      (set! index (+ index 1)))
    false))

;; --- advertisements ----------------------------------------------------------
;: Protocol v2: `version 2`, one capability per packet, up to the flush the
;: caller stripped. `lines` are raw packet payloads.
(define (git-advertisement-parse-v2
  [lines : (& lines (__tl_dyn-array String))]
  [limits : (& limits GitProtocolLimits)]) : ResultGitAdvertisement
  (let
    [capabilities : (__tl_dyn-array GitCapability)
      (__tl_make-array GitCapability 0)]
    [index : i64 1]
    (while (< index (array-length lines))
      (let
        [text : String (pkt.git-pkt-text (& (array-ref lines index)))]
        (when
          (git-protocol-control-byte? (& text))
          (return (Err MalformedCapability)))
        (let
          [capability (try (git-protocol-capability (& text) true))]
          (try
            (git-protocol-add-capability! (&mut capabilities) capability limits))))
      (set! index (+ index 1)))
    (let
      [format (try (git-protocol-capabilities-format (& capabilities)))]
      [has-object-format : bool
        (git-protocol-capabilities-have? (& capabilities) "object-format")]
      (Ok
        (GitAdvertisement
          (V2)
          format
          has-object-format
          capabilities
          (__tl_make-array git_object.GitAdvertisedRef 0))))))

;: The space-separated capability list after a v0/v1 first ref's NUL.
(define (git-protocol-legacy-capabilities
  [text : (& text str)]
  [limits : (& limits GitProtocolLimits)]) : ResultGitCapabilityList
  (let
    [capabilities : (__tl_dyn-array GitCapability)
      (__tl_make-array GitCapability 0)]
    [count : i64 (string.string-length text)]
    [start : i64 0]
    (while (< start count)
      (let
        [space : i64 (git-protocol-find text 32 start)]
        [end : i64
          (if (< space 0)
            count
            space)]
        (when (= end start) (return (Err MalformedCapability)))
        (let
          [token : String (string.substring text start (- end start))]
          [capability (try (git-protocol-capability (& token) false))]
          (try
            (git-protocol-add-capability! (&mut capabilities) capability limits)))
        (set! start (+ end 1))
        (when
          (and (= space (- count 1)) (>= space 0))
          (return (Err MalformedCapability)))))
    (Ok capabilities)))

(defenum ResultGitCapabilityList
  (Ok (__tl_dyn-array GitCapability))
  (Err pkt.GitProtocolError))

;: Whether `hex` is all `0` at the width of `format`: the empty repository's
;: placeholder ID, which is never a real object.
(define (git-protocol-zero-id?
  [format : git_object.GitObjectFormat]
  [hex : (& hex str)]) : bool
  (let
    [width : i64 (* 2 (git_object.git-object-id-bytes format))]
    [index : i64 0]
    (when (!= (string.string-length hex) width) (return false))
    (while (< index width)
      (when (!= (git-protocol-byte hex index) 48) (return false))
      (set! index (+ index 1)))
    true))

;: One `<id> SP <name>` ref line, validated through `git_object`.
(define (git-protocol-legacy-ref
  [format : git_object.GitObjectFormat]
  [text : (& text str)]) : ResultGitRef
  (let
    [space : i64 (git-protocol-find text 32 0)]
    (when (< space 0) (return (Err MalformedRef)))
    (let
      [hex : String (string.substring text 0 space)]
      [name : String
        (string.substring
          text
          (+ space 1)
          (- (string.string-length text) (+ space 1)))]
      (try (git-protocol-object-id format (& hex)))
      (match (git_object.git-object-advertised-ref
        format
        (& name)
        (& hex)
        ""
        "")
        [(Ok advert) (Ok advert)]
        [(Err _) (Err MalformedRef)]))))

;: Protocol v0/v1 refs from `lines[start]`: the first carries the capability
;: list after a NUL; `<id> <name>^{}` peels the ref just before it.
(define (git-advertisement-parse-legacy
  [lines : (& lines (__tl_dyn-array String))]
  [start : i64]
  [version : GitProtocolVersion]
  [limits : (& limits GitProtocolLimits)]) : ResultGitAdvertisement
  (when (>= start (array-length lines)) (return (Err MissingAdvertisement)))
  (let
    [first : String (pkt.git-pkt-text (& (array-ref lines start)))]
    [nul : i64 (git-protocol-find (& first) 0 0)]
    (when (< nul 0) (return (Err MalformedAdvertisement)))
    (let
      [head : String (string.substring (& first) 0 nul)]
      [tail : String
        (string.substring
          (& first)
          (+ nul 1)
          (- (string.string-length (& first)) (+ nul 1)))]
      (when
        (git-protocol-control-byte? (& tail))
        (return (Err MalformedCapability)))
      (let
        [capabilities (try (git-protocol-legacy-capabilities (& tail) limits))]
        [format (try (git-protocol-capabilities-format (& capabilities)))]
        [has-object-format : bool
          (git-protocol-capabilities-have? (& capabilities) "object-format")]
        [refs : (__tl_dyn-array git_object.GitAdvertisedRef)
          (__tl_make-array git_object.GitAdvertisedRef 0)]
        [names : git_name_set.Set (git_name_set.new)]
        [space : i64 (git-protocol-find (& head) 32 0)]
        [index : i64 (+ start 1)]
        (when (< space 0) (return (Err MalformedRef)))
        (if (and
          (git-protocol-zero-id? format (& (string.substring (& head) 0 space)))
          (string.eq
            (git-protocol-after
              (& head)
              (& (string.substring (& head) 0 (+ space 1))))
            "capabilities^{}"))
          (when
            (< index (array-length lines))
            (return (Err MalformedAdvertisement)))
          (let
            [advert (try (git-protocol-legacy-ref format (& head)))]
            (git_name_set.insert-ref!
              (&mut names)
              (git-protocol-copy (& advert.name)))
            (__tl_array-push! refs advert)))
        (while (< index (array-length lines))
          (let
            [text : String (pkt.git-pkt-text (& (array-ref lines index)))]
            [count : i64 (string.string-length (& text))]
            (when
              (git-protocol-control-byte? (& text))
              (return (Err MalformedRef)))
            (if (and
              (> count 3)
              (string.eq (string.substring (& text) (- count 3) 3) "^{}"))
              (let
                [base : String (string.substring (& text) 0 (- count 3))]
                [peeled (try (git-protocol-legacy-ref format (& base)))]
                [last : i64 (- (array-length refs) 1)]
                (when (< last 0) (return (Err MalformedRef)))
                (let
                  [previous : (& refs git_object.GitAdvertisedRef)
                    (& (array-ref refs last))]
                  (unless
                    (string.eq (& previous.name) (& peeled.name))
                    (return (Err MalformedRef)))
                  (match (& previous.peeled)
                    [(Present _) (return (Err DuplicateRef))]
                    [(Absent) unit]))
                (set!
                  (array-ref refs last).peeled
                  (Present (git_object.git-object-id-copy format (& peeled.id)))))
              (let
                [advert (try (git-protocol-legacy-ref format (& text)))]
                (when
                  (git_name_set.contains-borrowed? (& names) (& advert.name))
                  (return (Err DuplicateRef)))
                (when
                  (>= (array-length refs) limits.max-refs)
                  (return (Err RefLimit)))
                (git_name_set.insert-ref!
                  (&mut names)
                  (git-protocol-copy (& advert.name)))
                (__tl_array-push! refs advert))))
          (set! index (+ index 1)))
        (Ok
          (GitAdvertisement version format has-object-format capabilities refs))))))

;: The advertisement up to its flush: v2 when it starts `version 2`, v1 after
;: `version 1`, otherwise v0. Any other version is unsupported.
(define (git-advertisement-parse
  [lines : (& lines (__tl_dyn-array String))]
  [limits : (& limits GitProtocolLimits)]) : ResultGitAdvertisement
  (when (= (array-length lines) 0) (return (Err MissingAdvertisement)))
  (let
    [first : String (pkt.git-pkt-text (& (array-ref lines 0)))]
    (cond
      [(string.eq (& first) "version 2")
        (git-advertisement-parse-v2 lines limits)]
      [(string.eq (& first) "version 1")
        (git-advertisement-parse-legacy lines 1 (V1) limits)]
      [(git-protocol-starts-with? (& first) "version ")
        (Err UnsupportedVersion)]
      [else (git-advertisement-parse-legacy lines 0 (V0) limits)])))

;; --- requests ----------------------------------------------------------------
(defenum ResultGitString
  (Ok String)
  (Err pkt.GitProtocolError))

;: Append one text packet `text` LF to `out`.
(define (git-protocol-push-line!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [text : String]) : ResultGitUnit
  (let
    [line : String (str_cat.str-cat text "\n")]
    [encoded (try (git-protocol-encode (& line)))]
    (byte_buf.byte-buf-builder-append-string out encoded)
    (Ok)))

(define (git-protocol-encode [line : (& line str)]) : ResultGitString
  (match (pkt.git-pkt-encode-data line)
    [(Ok bytes) (Ok bytes)]
    [(Err error) (Err error)]))

(define (git-protocol-push-raw!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [bytes : String]) : unit
  (byte_buf.byte-buf-builder-append-string out bytes))

;: The v2 `command=` header: the command, then `object-format` when the server
;: advertised one, then the delimiter before the arguments.
(define (git-protocol-v2-command!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [advert : (& advert GitAdvertisement)]
  [command : String]) : ResultGitUnit
  (try (git-protocol-push-line! out (str_cat.str-cat "command=" command)))
  (when
    advert.has-object-format
    (try
      (git-protocol-push-line!
        out
        (str_cat.str-cat
          "object-format="
          (git-protocol-format-name
            (git-protocol-format-copy (& advert.format)))))))
  (git-protocol-push-raw! out (pkt.git-pkt-delim))
  (Ok))

(defstruct GitLsRefsPlan
  (request String)
  (unborn bool))

(defenum ResultGitLsRefsPlan
  (Ok GitLsRefsPlan)
  (Err pkt.GitProtocolError))

(define (git-protocol-ref-prefix-valid? [prefix : (& prefix str)]) : bool
  (let
    [count : i64 (string.string-length prefix)]
    [index : i64 0]
    (when (or (= count 0) (> count 1024)) (return false))
    (while (< index count)
      (let
        [byte : i64 (git-protocol-byte prefix index)]
        (when (or (<= byte 32) (>= byte 127)) (return false)))
      (set! index (+ index 1)))
    true))

;: A v2 ls-refs request for `prefixes` with peeled IDs and symref targets.
;: `unborn` is asked for only when both requested and advertised; the plan
;: records whether it was, which the response parser needs.
(define (git-ls-refs-request
  [advert : (& advert GitAdvertisement)]
  [prefixes : (& prefixes (__tl_dyn-array String))]
  [unborn : bool]) : ResultGitLsRefsPlan
  (match (& advert.version)
    [(V2) unit]
    [_ (return (Err UnsupportedVersion))])
  (unless
    (git-advertisement-has-capability? advert "ls-refs")
    (return (Err MissingCapability)))
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [send-unborn : bool
      (and unborn (git-advertisement-has-feature? advert "ls-refs" "unborn"))]
    [index : i64 0]
    (try (git-protocol-v2-command! (&mut out) advert "ls-refs"))
    (try (git-protocol-push-line! (&mut out) "peel"))
    (try (git-protocol-push-line! (&mut out) "symrefs"))
    (when send-unborn (try (git-protocol-push-line! (&mut out) "unborn")))
    (while (< index (array-length prefixes))
      (let
        [prefix : (& prefixes str) (& (array-ref prefixes index))]
        (unless
          (git-protocol-ref-prefix-valid? prefix)
          (return (Err InvalidRefPrefix)))
        (try
          (git-protocol-push-line!
            (&mut out)
            (str_cat.str-cat "ref-prefix " (git-protocol-copy prefix)))))
      (set! index (+ index 1)))
    (git-protocol-push-raw! (&mut out) (pkt.git-pkt-flush))
    (Ok
      (GitLsRefsPlan
        (byte_buf.byte-buf-builder-finish-string (& out))
        send-unborn))))

(defenum GitLsRef
  (Ref git_object.GitAdvertisedRef)
  ;; An unborn ref: its name, and its symref target or "".
  (Unborn String String))

(defenum ResultGitLsRefs
  (Ok (__tl_dyn-array GitLsRef))
  (Err pkt.GitProtocolError))

;: One ls-refs response line: `<id>|unborn SP <name> *(SP attribute)`, where an
;: attribute is `symref-target:<ref>` or (for an ID) `peeled:<id>`, each at
;: most once.
(define (git-protocol-ls-ref
  [format : git_object.GitObjectFormat]
  [text : (& text str)]
  [unborn-sent : bool]) : ResultGitLsRef
  (let
    [count : i64 (string.string-length text)]
    [first-space : i64 (git-protocol-find text 32 0)]
    (when (< first-space 0) (return (Err MalformedRef)))
    (let
      [id-text : String (string.substring text 0 first-space)]
      [name-start : i64 (+ first-space 1)]
      [name-space : i64 (git-protocol-find text 32 name-start)]
      [name-end : i64
        (if (< name-space 0)
          count
          name-space)]
      [name : String (string.substring text name-start (- name-end name-start))]
      [symref : String ""]
      [peeled : String ""]
      [has-symref : bool false]
      [has-peeled : bool false]
      [start : i64 (+ name-end 1)]
      (when (= name-end name-start) (return (Err MalformedRef)))
      (when (= name-end (- count 1)) (return (Err MalformedRef)))
      (while (< start count)
        (let
          [space : i64 (git-protocol-find text 32 start)]
          [end : i64
            (if (< space 0)
              count
              space)]
          [attribute : String (string.substring text start (- end start))]
          (cond
            [(git-protocol-starts-with? (& attribute) "symref-target:")
              (when has-symref (return (Err MalformedRef)))
              (set! has-symref true)
              (set! symref (git-protocol-after (& attribute) "symref-target:"))]
            [(git-protocol-starts-with? (& attribute) "peeled:")
              (when has-peeled (return (Err MalformedRef)))
              (set! has-peeled true)
              (set! peeled (git-protocol-after (& attribute) "peeled:"))]
            [else (return (Err MalformedRef))])
          (when
            (and (>= space 0) (= space (- count 1)))
            (return (Err MalformedRef)))
          (set! start (+ end 1))))
      (when
        (and has-symref (= (string.string-length (& symref)) 0))
        (return (Err MalformedRef)))
      (if (string.eq (& id-text) "unborn")
        (begin
          (when (or (not unborn-sent) has-peeled) (return (Err MalformedRef)))
          (unless
            (git_object.git-object-refname-valid? (& name) true)
            (return (Err MalformedRef)))
          (when
            (and
              has-symref
              (or
                (not (git_object.git-object-symref-target-valid? (& symref)))
                (string.eq (& name) (& symref))))
            (return (Err MalformedRef)))
          (Ok (Unborn name symref)))
        (begin
          (try (git-protocol-object-id format (& id-text)))
          (when
            has-peeled
            (let
              [_ (try (git-protocol-object-id format (& peeled)))]
              unit))
          (match (git_object.git-object-advertised-ref
            format
            (& name)
            (& id-text)
            (& symref)
            (& peeled))
            [(Ok advert) (Ok (Ref advert))]
            [(Err _) (Err MalformedRef)]))))))

(defenum ResultGitLsRef
  (Ok GitLsRef)
  (Err pkt.GitProtocolError))

(define (git-protocol-ls-ref-name [entry : (& entry GitLsRef)]) : String
  (match entry
    [(Ref advert) (git-protocol-copy (& advert.name))]
    [(Unborn name _) (git-protocol-copy name)]))

;: The ls-refs response up to its flush. Ref names are unique.
(define (git-ls-refs-parse
  [format : git_object.GitObjectFormat]
  [lines : (& lines (__tl_dyn-array String))]
  [unborn-sent : bool]
  [limits : (& limits GitProtocolLimits)]) : ResultGitLsRefs
  (let
    [refs : (__tl_dyn-array GitLsRef) (__tl_make-array GitLsRef 0)]
    [names : git_name_set.Set (git_name_set.new)]
    [index : i64 0]
    (when (> (array-length lines) limits.max-refs) (return (Err RefLimit)))
    (while (< index (array-length lines))
      (let
        [text : String (pkt.git-pkt-text (& (array-ref lines index)))]
        (when (git-protocol-control-byte? (& text)) (return (Err MalformedRef)))
        (let
          [entry (try (git-protocol-ls-ref format (& text) unborn-sent))]
          [name : String (git-protocol-ls-ref-name (& entry))]
          (when
            (git_name_set.contains-borrowed? (& names) (& name))
            (return (Err DuplicateRef)))
          (git_name_set.insert-ref! (&mut names) name)
          (__tl_array-push! refs entry)))
      (set! index (+ index 1)))
    (Ok refs)))

;: What the caller asks of a fetch. Each is honoured only when the server
;: supports it; `GitFetchFacts` says what was sent.
(defstruct GitFetchOptions
  (shallow bool)
  (ofs-delta bool)
  (no-progress bool))

(defstruct GitFetchFacts
  (version GitProtocolVersion)
  (format git_object.GitObjectFormat)
  (deepen bool)
  (ofs-delta bool)
  (no-progress bool)
  (want-count i64))

(defstruct GitFetchPlan
  (request String)
  (facts GitFetchFacts))

(defenum ResultGitFetchPlan
  (Ok GitFetchPlan)
  (Err pkt.GitProtocolError))

(defenum ResultGitIds
  (Ok (__tl_dyn-array git_object.GitObjectId))
  (Err pkt.GitProtocolError))

(define (git-protocol-wants
  [format : git_object.GitObjectFormat]
  [wants : (& wants (__tl_dyn-array String))]) : ResultGitIds
  (let
    [ids : (__tl_dyn-array git_object.GitObjectId)
      (__tl_make-array git_object.GitObjectId 0)]
    [seen : git_name_set.Set (git_name_set.new)]
    [index : i64 0]
    (when (= (array-length wants) 0) (return (Err InvalidWant)))
    (while (< index (array-length wants))
      (match (git_object.git-object-id-from-hex
        format
        (& (array-ref wants index)))
        [(Err _) (return (Err InvalidWant))]
        [(Ok id)
          (when
            (git_name_set.contains-borrowed? (& seen) (& id.hex))
            (return (Err DuplicateWant)))
          (git_name_set.insert-ref! (&mut seen) (git-protocol-copy (& id.hex)))
          (__tl_array-push! ids id)])
      (set! index (+ index 1)))
    (Ok ids)))

(define (git-protocol-v2-fetch-request
  [advert : (& advert GitAdvertisement)]
  [ids : (& ids (__tl_dyn-array git_object.GitObjectId))]
  [options : (& options GitFetchOptions)]) : ResultGitFetchPlan
  (unless
    (git-advertisement-has-capability? advert "fetch")
    (return (Err MissingCapability)))
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [deepen : bool
      (and
        options.shallow
        (git-advertisement-has-feature? advert "fetch" "shallow"))]
    [index : i64 0]
    (try (git-protocol-v2-command! (&mut out) advert "fetch"))
    (when
      options.ofs-delta
      (try (git-protocol-push-line! (&mut out) "ofs-delta")))
    (when
      options.no-progress
      (try (git-protocol-push-line! (&mut out) "no-progress")))
    (while (< index (array-length ids))
      (try
        (git-protocol-push-line!
          (&mut out)
          (str_cat.str-cat
            "want "
            (git-protocol-copy (& (array-ref ids index).hex)))))
      (set! index (+ index 1)))
    (when deepen (try (git-protocol-push-line! (&mut out) "deepen 1")))
    (try (git-protocol-push-line! (&mut out) "done"))
    (git-protocol-push-raw! (&mut out) (pkt.git-pkt-flush))
    (Ok
      (GitFetchPlan
        (byte_buf.byte-buf-builder-finish-string (& out))
        (GitFetchFacts
          (V2)
          (git-protocol-format-copy (& advert.format))
          deepen
          options.ofs-delta
          options.no-progress
          (array-length ids))))))

;: Whether `id` is an advertised ref tip or peeled target.
(define (git-protocol-advertised-id?
  [advert : (& advert GitAdvertisement)]
  [id : (& id git_object.GitObjectId)]) : bool
  (let
    [index : i64 0]
    (while (< index (array-length advert.refs))
      (let
        [ref : (& advert git_object.GitAdvertisedRef)
          (& (array-ref advert.refs index))]
        (when (string.eq (& ref.id.hex) (& id.hex)) (return true))
        (match (& ref.peeled)
          [(Present peeled)
            (when (string.eq (& peeled.hex) (& id.hex)) (return true))]
          [(Absent) unit]))
      (set! index (+ index 1)))
    false))

;: v0/v1: the first `want` carries the capabilities this client uses, then a
;: flush, then `done`. Pack data must arrive on side-band-64k, and a want must be
;: an advertised ID unless the server allows unadvertised wants.
(define (git-protocol-legacy-fetch-request
  [advert : (& advert GitAdvertisement)]
  [ids : (& ids (__tl_dyn-array git_object.GitObjectId))]
  [options : (& options GitFetchOptions)]) : ResultGitFetchPlan
  (unless
    (git-advertisement-has-capability? advert "side-band-64k")
    (return (Err UnsupportedLegacyCapability)))
  (let
    [any-want : bool
      (or
        (git-advertisement-has-capability?
          advert
          "allow-reachable-sha1-in-want")
        (git-advertisement-has-capability? advert "allow-tip-sha1-in-want"))]
    [deepen : bool
      (and options.shallow (git-advertisement-has-capability? advert "shallow"))]
    [ofs-delta : bool
      (and
        options.ofs-delta
        (git-advertisement-has-capability? advert "ofs-delta"))]
    [no-progress : bool
      (and
        options.no-progress
        (git-advertisement-has-capability? advert "no-progress"))]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [index : i64 0]
    (while (< index (array-length ids))
      (unless
        (or
          any-want
          (git-protocol-advertised-id? advert (& (array-ref ids index))))
        (return (Err WantNotAdvertised)))
      (set! index (+ index 1)))
    (let
      [first : String
        (str_cat.str-cat
          "want "
          (git-protocol-copy (& (array-ref ids 0).hex))
          " side-band-64k")]
      (when ofs-delta (set! first (str_cat.str-cat first " ofs-delta")))
      (when deepen (set! first (str_cat.str-cat first " shallow")))
      (when no-progress (set! first (str_cat.str-cat first " no-progress")))
      (when
        advert.has-object-format
        (set!
          first
          (str_cat.str-cat
            first
            " object-format="
            (git-protocol-format-name
              (git-protocol-format-copy (& advert.format))))))
      (try (git-protocol-push-line! (&mut out) first)))
    (set! index 1)
    (while (< index (array-length ids))
      (try
        (git-protocol-push-line!
          (&mut out)
          (str_cat.str-cat
            "want "
            (git-protocol-copy (& (array-ref ids index).hex)))))
      (set! index (+ index 1)))
    (when deepen (try (git-protocol-push-line! (&mut out) "deepen 1")))
    (git-protocol-push-raw! (&mut out) (pkt.git-pkt-flush))
    (try (git-protocol-push-line! (&mut out) "done"))
    (Ok
      (GitFetchPlan
        (byte_buf.byte-buf-builder-finish-string (& out))
        (GitFetchFacts
          (match (& advert.version)
            [(V1) (V1)]
            [_ (V0)])
          (git-protocol-format-copy (& advert.format))
          deepen
          ofs-delta
          no-progress
          (array-length ids))))))

;: The exact-want fetch request for `wants` (hex IDs in the negotiated format)
;: and the facts of what it asks for.
(define (git-fetch-request
  [advert : (& advert GitAdvertisement)]
  [wants : (& wants (__tl_dyn-array String))]
  [options : (& options GitFetchOptions)]) : ResultGitFetchPlan
  (let
    [ids
      (try
        (git-protocol-wants (git-protocol-format-copy (& advert.format)) wants))]
    (match (& advert.version)
      [(V2) (git-protocol-v2-fetch-request advert (& ids) options)]
      [_ (git-protocol-legacy-fetch-request advert (& ids) options)])))

;; --- fetch response ----------------------------------------------------------
(defenum GitFetchEvent
  (Continue)
  (PackBytes String)
  (Progress String)
  (Shallow git_object.GitObjectId)
  (Complete)
  (RemoteFailed String)
  (Err pkt.GitProtocolError))

;: Response phases.
(define git-fetch-phase-section : i64
  0)
(define git-fetch-phase-shallow-info : i64
  1)
(define git-fetch-phase-packfile : i64
  2)
(define git-fetch-phase-complete : i64
  3)
(define git-fetch-phase-failed : i64
  4)
(define git-fetch-phase-legacy-shallow : i64
  5)
(define git-fetch-phase-legacy-nak : i64
  6)

;: The v2 response section order.
(define git-fetch-section-acknowledgments : i64
  1)
(define git-fetch-section-shallow-info : i64
  2)
(define git-fetch-section-wanted-refs : i64
  3)
(define git-fetch-section-packfile-uris : i64
  4)
(define git-fetch-section-packfile : i64
  5)

(defstruct GitFetchResponse
  (facts GitFetchFacts)
  (limits GitProtocolLimits)
  (phase i64)
  (last-section i64)
  (shallows git_name_set.Set)
  (progress-bytes i64))

(define (git-fetch-response-new
  [facts : GitFetchFacts]
  [limits : GitProtocolLimits]) : GitFetchResponse
  (let
    [phase : i64
      (match (& facts.version)
        [(V2) git-fetch-phase-section]
        [_
          (if facts.deepen
            git-fetch-phase-legacy-shallow
            git-fetch-phase-legacy-nak)])]
    (GitFetchResponse facts limits phase 0 (git_name_set.new) 0)))

(define (git-fetch-response-fail!
  [response : (&mut response GitFetchResponse)]
  [error : pkt.GitProtocolError]) : GitFetchEvent
  (set! response.phase git-fetch-phase-failed)
  (Err error))

;: `ERR <text>`, the remote's own failure report outside pack data.
(define (git-fetch-response-remote-error!
  [response : (&mut response GitFetchResponse)]
  [text : (& text str)]) : GitFetchEvent
  (set! response.phase git-fetch-phase-failed)
  (RemoteFailed
    (pkt.git-pkt-sanitize-text
      (& (git-protocol-after text "ERR "))
      response.limits.max-text-bytes)))

;: `shallow <id>` in a fresh fetch's shallow exchange. Nothing is shallow here
;: yet, so an `unshallow` is inconsistent with the request.
(define (git-fetch-response-shallow!
  [response : (&mut response GitFetchResponse)]
  [text : (& text str)]) : GitFetchEvent
  (cond
    [(git-protocol-starts-with? text "unshallow ")
      (git-fetch-response-fail! response (UnexpectedUnshallow))]
    [(git-protocol-starts-with? text "shallow ")
      (match (git_object.git-object-id-from-hex
        (git-protocol-format-copy (& response.facts.format))
        (& (git-protocol-after text "shallow ")))
        [(Err _) (git-fetch-response-fail! response (MalformedShallow))]
        [(Ok id)
          (if (git_name_set.contains-borrowed? (& response.shallows) (& id.hex))
            (git-fetch-response-fail! response (DuplicateShallow))
            (begin
              (git_name_set.insert-ref!
                (&mut response.shallows)
                (git-protocol-copy (& id.hex)))
              (Shallow id)))])]
    [else (git-fetch-response-fail! response (MalformedShallow))]))

(define (git-fetch-response-sideband!
  [response : (&mut response GitFetchResponse)]
  [payload : (& payload str)]) : GitFetchEvent
  (match (pkt.git-pkt-sideband payload response.limits.max-text-bytes)
    [(Err error) (git-fetch-response-fail! response error)]
    [(Ok band)
      (match band
        [(Pack bytes)
          (if (= (string.string-length (& bytes)) 0)
            (Continue)
            (PackBytes bytes))]
        [(Progress text)
          (let
            [count : i64 (string.string-length (& text))]
            (if (or
              (= count 0)
              (>
                (+ response.progress-bytes count)
                response.limits.max-progress-bytes))
              (Continue)
              (begin
                (set! response.progress-bytes (+ response.progress-bytes count))
                (Progress text))))]
        [(Fatal text)
          (set! response.phase git-fetch-phase-failed)
          (RemoteFailed text)])]))

;: A v2 section header: sections arrive at most once, in protocol order, and
;: only those the request asked for. With `done` sent there are no
;: acknowledgments; without `want-ref` or packfile URIs those sections are
;: unsolicited; shallow-info comes exactly when `deepen` was sent.
(define (git-fetch-response-section!
  [response : (&mut response GitFetchResponse)]
  [text : (& text str)]) : GitFetchEvent
  (let
    [section : i64
      (cond
        [(string.eq text "acknowledgments") git-fetch-section-acknowledgments]
        [(string.eq text "shallow-info") git-fetch-section-shallow-info]
        [(string.eq text "wanted-refs") git-fetch-section-wanted-refs]
        [(string.eq text "packfile-uris") git-fetch-section-packfile-uris]
        [(string.eq text "packfile") git-fetch-section-packfile]
        [else 0])]
    (cond
      [(git-protocol-starts-with? text "ERR ")
        (git-fetch-response-remote-error! response text)]
      [(= section 0) (git-fetch-response-fail! response (MalformedSection))]
      [(<= section response.last-section)
        (git-fetch-response-fail! response (OutOfOrderSection))]
      [(or
          (= section git-fetch-section-acknowledgments)
          (= section git-fetch-section-wanted-refs)
          (= section git-fetch-section-packfile-uris)
          (and
            (= section git-fetch-section-shallow-info)
            (not response.facts.deepen)))
        (git-fetch-response-fail! response (UnexpectedSection))]
      [(and
          (= section git-fetch-section-packfile)
          response.facts.deepen
          (< response.last-section git-fetch-section-shallow-info))
        (git-fetch-response-fail! response (MissingShallowInfo))]
      [else
        (set! response.last-section section)
        (set!
          response.phase
          (if (= section git-fetch-section-shallow-info)
            git-fetch-phase-shallow-info
            git-fetch-phase-packfile))
        (Continue)])))

;: Feed one response packet. `Complete` follows the flush that ends the pack;
;: any packet after it, and any packet after a failure, is an error.
(define (git-fetch-response-push!
  [response : (&mut response GitFetchResponse)]
  [packet : pkt.GitPkt]) : GitFetchEvent
  (let
    [phase : i64 response.phase]
    (cond
      [(= phase git-fetch-phase-complete)
        (git-fetch-response-fail! response (TrailingBytes))]
      [(= phase git-fetch-phase-failed) (Err UnexpectedPacket)]
      [(= phase git-fetch-phase-packfile)
        (match packet
          [(Data payload) (git-fetch-response-sideband! response (& payload))]
          [(Flush)
            (set! response.phase git-fetch-phase-complete)
            (Complete)]
          [_ (git-fetch-response-fail! response (MalformedSection))])]
      [(= phase git-fetch-phase-section)
        (match packet
          [(Data payload)
            (git-fetch-response-section!
              response
              (& (pkt.git-pkt-text (& payload))))]
          [_ (git-fetch-response-fail! response (MalformedSection))])]
      [(= phase git-fetch-phase-shallow-info)
        (match packet
          [(Data payload)
            (git-fetch-response-shallow!
              response
              (& (pkt.git-pkt-text (& payload))))]
          [(Delim)
            (set! response.phase git-fetch-phase-section)
            (Continue)]
          [_ (git-fetch-response-fail! response (MalformedSection))])]
      [(= phase git-fetch-phase-legacy-shallow)
        (match packet
          [(Data payload)
            (let
              [text : String (pkt.git-pkt-text (& payload))]
              (if (git-protocol-starts-with? (& text) "ERR ")
                (git-fetch-response-remote-error! response (& text))
                (git-fetch-response-shallow! response (& text))))]
          [(Flush)
            (set! response.phase git-fetch-phase-legacy-nak)
            (Continue)]
          [_ (git-fetch-response-fail! response (UnexpectedPacket))])]
      [else
        (match packet
          [(Data payload)
            (let
              [text : String (pkt.git-pkt-text (& payload))]
              (cond
                [(string.eq (& text) "NAK")
                  (set! response.phase git-fetch-phase-packfile)
                  (Continue)]
                [(git-protocol-starts-with? (& text) "ERR ")
                  (git-fetch-response-remote-error! response (& text))]
                [else
                  (git-fetch-response-fail! response (MalformedAcknowledgment))]))]
          [_ (git-fetch-response-fail! response (UnexpectedPacket))])])))

;; --- session -----------------------------------------------------------------
(defenum GitSessionEvent
  ;; Feed more upload-pack output, or end the input.
  (NeedInput)
  ;; Write these bytes to upload-pack, exactly once.
  (Send String)
  (PackBytes String)
  (Progress String)
  (Shallow git_object.GitObjectId)
  ;; The pack ended at its terminal flush; repeated until more input arrives.
  (Complete GitFetchFacts)
  ;; The remote reported a fatal error (sanitized, size-limited text).
  (RemoteFailed String)
  (Failed pkt.GitProtocolError))

;: Session phases.
(define git-session-phase-start : i64
  0)
(define git-session-phase-service-flush : i64
  1)
(define git-session-phase-advertisement : i64
  2)
(define git-session-phase-response : i64
  3)
(define git-session-phase-complete : i64
  4)
(define git-session-phase-failed : i64
  5)
(define git-session-phase-remote-failed : i64
  6)

(defstruct GitSession
  (reader pkt.GitPktReader)
  (phase i64)
  (lines (__tl_dyn-array String))
  (wants (__tl_dyn-array String))
  (options GitFetchOptions)
  (limits GitProtocolLimits)
  (response GitFetchResponse)
  (eof bool)
  (failure pkt.GitProtocolError)
  (remote-text String))

;: A session fetching `wants`, hex object IDs in whatever object format the
;: server negotiates.
(define (git-session-new
  [wants : (__tl_dyn-array String)]
  [options : GitFetchOptions]
  [limits : GitProtocolLimits]) : GitSession
  (GitSession
    (pkt.git-pkt-reader-new)
    git-session-phase-start
    (__tl_make-array String 0)
    wants
    options
    limits
    (git-fetch-response-new
      (GitFetchFacts (V2) (Sha1) false false false 0)
      limits)
    false
    (TruncatedResponse)
    ""))

(define (git-session-fail!
  [session : (&mut session GitSession)]
  [error : pkt.GitProtocolError]) : GitSessionEvent
  (set! session.phase git-session-phase-failed)
  (set! session.failure error)
  (Failed error))

(define (git-session-remote-failed!
  [session : (&mut session GitSession)]
  [text : String]) : GitSessionEvent
  (set! session.phase git-session-phase-remote-failed)
  (set! session.remote-text (git-protocol-copy (& text)))
  (RemoteFailed text))

;: Feed upload-pack output bytes, in any fragmentation.
(define (git-session-feed!
  [session : (&mut session GitSession)]
  [chunk : (& chunk str)]) : unit
  (unless
    (or
      (= session.phase git-session-phase-failed)
      (= session.phase git-session-phase-remote-failed))
    (match (pkt.git-pkt-reader-feed! (&mut session.reader) chunk)
      [(Ok) unit]
      [(Err error)
        (let
          [_ : GitSessionEvent (git-session-fail! session error)]
          unit)])))

;: The upload-pack output has ended.
(define (git-session-end-of-input! [session : (&mut session GitSession)]) : unit
  (set! session.eof true))

(define (git-session-facts [session : (& session GitSession)]) : GitFetchFacts
  (let
    [facts : (& session GitFetchFacts) (& session.response.facts)]
    (GitFetchFacts
      (match (& facts.version)
        [(V0) (V0)]
        [(V1) (V1)]
        [(V2) (V2)])
      (match (& facts.format)
        [(Sha1) (Sha1)]
        [(Sha256) (Sha256)])
      facts.deepen
      facts.ofs-delta
      facts.no-progress
      facts.want-count)))

;: The advertisement is complete: validate it, plan the fetch, and send it.
(define (git-session-request! [session : (&mut session GitSession)]) : GitSessionEvent
  (match (git-advertisement-parse (& session.lines) (& session.limits))
    [(Err error) (git-session-fail! session error)]
    [(Ok advert)
      (match (git-fetch-request
        (& advert)
        (& session.wants)
        (& session.options))
        [(Err error) (git-session-fail! session error)]
        [(Ok plan)
          (set!
            session.response
            (git-fetch-response-new
              plan.facts
              (GitProtocolLimits
                session.limits.max-refs
                session.limits.max-capabilities
                session.limits.max-text-bytes
                session.limits.max-progress-bytes)))
          (set! session.lines (__tl_make-array String 0))
          (set! session.phase git-session-phase-response)
          (Send plan.request)])]))

;: Collect one advertisement packet.
(define (git-session-advertisement!
  [session : (&mut session GitSession)]
  [packet : pkt.GitPkt]) : GitSessionEvent
  (match packet
    [(Data payload)
      (if (>=
        (array-length session.lines)
        (+ session.limits.max-refs session.limits.max-capabilities 2))
        (git-session-fail! session (RefLimit))
        (begin
          (__tl_array-push! session.lines payload)
          (NeedInput)))]
    [(Flush)
      (if (= (array-length session.lines) 0)
        (git-session-fail! session (MissingAdvertisement))
        (git-session-request! session))]
    [_ (git-session-fail! session (MalformedAdvertisement))]))

(define (git-session-service-header? [payload : (& payload str)]) : bool
  (let
    [text : String (pkt.git-pkt-text payload)]
    (string.eq (& text) "# service=git-upload-pack")))

;: The first packet: a smart-HTTP `# service=git-upload-pack` header (with its
;: flush), the server's `ERR` report (a git:// server's missing repository), or
;: the advertisement itself.
(define (git-session-first!
  [session : (&mut session GitSession)]
  [packet : pkt.GitPkt]) : GitSessionEvent
  (let
    [kind : i64
      (match (& packet)
        [(Data payload)
          (cond
            [(git-session-service-header? payload) 1]
            [(git-protocol-starts-with? payload "ERR ") 3]
            [else 2])]
        [_ 0])]
    (cond
      [(= kind 1)
        (set! session.phase git-session-phase-service-flush)
        (NeedInput)]
      [(= kind 2)
        (set! session.phase git-session-phase-advertisement)
        (git-session-advertisement! session packet)]
      [(= kind 3)
        (match packet
          [(Data payload)
            (git-session-remote-failed!
              session
              (pkt.git-pkt-sanitize-text
                (&
                  (git-protocol-after (& (pkt.git-pkt-text (& payload))) "ERR "))
                session.limits.max-text-bytes))]
          [_ (git-session-fail! session (MissingAdvertisement))])]
      [else (git-session-fail! session (MissingAdvertisement))])))

(define (git-session-response!
  [session : (&mut session GitSession)]
  [packet : pkt.GitPkt]) : GitSessionEvent
  (match (git-fetch-response-push! (&mut session.response) packet)
    [(Continue) (NeedInput)]
    [(PackBytes bytes) (PackBytes bytes)]
    [(Progress text) (Progress text)]
    [(Shallow id) (Shallow id)]
    [(Complete)
      (match (pkt.git-pkt-reader-terminate! (&mut session.reader))
        [(Err error) (git-session-fail! session error)]
        [(Ok)
          (set! session.phase git-session-phase-complete)
          (Complete (git-session-facts (& session)))])]
    [(RemoteFailed text) (git-session-remote-failed! session text)]
    [(Err error) (git-session-fail! session error)]))

(define (git-session-waiting? [event : (& event GitSessionEvent)]) : bool
  (match event
    [(NeedInput) true]
    [_ false]))

;: Advance the session by one observable event. `NeedInput` asks for more
;: upload-pack output; at end of input an unfinished exchange is `Failed` with
;: `TruncatedPacket` (inside a packet) or `TruncatedResponse`.
(define (git-session-step! [session : (&mut session GitSession)]) : GitSessionEvent
  (while true
    (let
      [phase : i64 session.phase]
      (cond
        [(= phase git-session-phase-failed)
          (return (Failed (pkt.git-pkt-error-copy (& session.failure))))]
        [(= phase git-session-phase-remote-failed)
          (return (RemoteFailed (git-protocol-copy (& session.remote-text))))]
        [(= phase git-session-phase-complete)
          (return (Complete (git-session-facts (& session))))]
        [else
          (match (pkt.git-pkt-reader-next! (&mut session.reader))
            [(Err error) (return (git-session-fail! session error))]
            [(NeedMore)
              (unless session.eof (return (NeedInput)))
              (match (pkt.git-pkt-reader-end (& session.reader))
                [(Err error) (return (git-session-fail! session error))]
                [(Ok) (return (git-session-fail! session (TruncatedResponse)))])]
            [(Packet packet)
              (let
                [event : GitSessionEvent
                  (cond
                    [(= phase git-session-phase-start)
                      (git-session-first! session packet)]
                    [(= phase git-session-phase-service-flush)
                      (match packet
                        [(Flush)
                          (set! session.phase git-session-phase-advertisement)
                          (NeedInput)]
                        [_ (git-session-fail! session (MalformedAdvertisement))])]
                    [(= phase git-session-phase-advertisement)
                      (git-session-advertisement! session packet)]
                    [else (git-session-response! session packet)])]
                [waiting : bool (git-session-waiting? (& event))]
                (unless waiting (return event)))])])))
  (NeedInput))