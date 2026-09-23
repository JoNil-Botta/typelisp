;; Pure, bounded Git object identities and decoders. All String values here
;; are byte strings; no repository-controlled byte is placed in an error.
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.str_cat)
(import stdlib.string)

(defenum GitObjectFormat
  (Sha1)
  (Sha256))

(defenum GitObjectKind
  (Blob)
  (Tree)
  (Commit)
  (Tag))

(defstruct GitObjectId
  (format GitObjectFormat)
  (binary String)
  (hex String))

(defenum ResultGitObjectId
  (Ok GitObjectId)
  (Err String))

(define (git-object-id-bytes [format : GitObjectFormat]) : i64
  (match format
    [(GitObjectFormat.Sha1) 20]
    [(GitObjectFormat.Sha256) 32]))

(define (git-object-byte [bytes : (& bytes str)] [index : i64]) : i64
  (cast (string.string-ref bytes index) : i64))

(define (git-object-hex-digit [byte : i64]) : i64
  (cond
    [(and (>= byte 48) (<= byte 57)) (- byte 48)]
    [(and (>= byte 97) (<= byte 102)) (+ 10 (- byte 97))]
    [else -1]))

(define (git-object-id-from-binary
  [format : GitObjectFormat]
  [binary : (& binary str)]) : ResultGitObjectId
  (let
    [width : i64 (git-object-id-bytes format)]
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity (* width 2))]
    [index : i64 0]
    [nonzero : bool false]
    (begin
      (when
        (!= (string.string-length binary) width)
        (return
          (ResultGitObjectId.Err "git object: invalid binary object ID width")))
      (while (< index width)
        (let
          [octet : i64 (git-object-byte binary index)]
          (begin
            (when (!= octet 0) (set! nonzero true))
            (byte_buf.byte-buf-builder-push
              (&mut out)
              (cast
                (if (< (shr octet 4) 10)
                  (+ 48 (shr octet 4))
                  (+ 87 (shr octet 4)))
                : u8))
            (let
              [low : i64 (bit-and octet 15)]
              (byte_buf.byte-buf-builder-push
                (&mut out)
                (cast
                  (if (< low 10)
                    (+ 48 low)
                    (+ 87 low))
                  : u8)))
            (set! index (+ index 1)))))
      (if nonzero
        (ResultGitObjectId.Ok
          (GitObjectId
            format
            (string.substring binary 0 width)
            (byte_buf.byte-buf-builder-finish-string (& out))))
        (ResultGitObjectId.Err "git object: zero object ID is reserved")))))

(define (git-object-id-from-hex [format : GitObjectFormat] [hex : (& hex str)]) : ResultGitObjectId
  (let
    [width : i64 (git-object-id-bytes format)]
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity width)]
    [index : i64 0]
    (begin
      (when
        (!= (string.string-length hex) (* width 2))
        (return
          (ResultGitObjectId.Err
            "git object: invalid hexadecimal object ID width")))
      (while (< index (* width 2))
        (let
          [high : i64 (git-object-hex-digit (git-object-byte hex index))]
          [low : i64 (git-object-hex-digit (git-object-byte hex (+ index 1)))]
          (begin
            (when
              (or (< high 0) (< low 0))
              (return
                (ResultGitObjectId.Err
                  "git object: noncanonical hexadecimal object ID")))
            (byte_buf.byte-buf-builder-push
              (&mut out)
              (cast (+ (* high 16) low) : u8))
            (set! index (+ index 2)))))
      (git-object-id-from-binary
        format
        (byte_buf.byte-buf-builder-finish-string (& out))))))

(define (git-object-id-valid?
  [format : GitObjectFormat]
  [id : (& id GitObjectId)]) : bool
  (and
    (match (& id.format)
      [(GitObjectFormat.Sha1)
        (match format
          [(GitObjectFormat.Sha1) true]
          [_ false])]
      [(GitObjectFormat.Sha256)
        (match format
          [(GitObjectFormat.Sha256) true]
          [_ false])])
    (match (git-object-id-from-hex format (& id.hex))
      [(ResultGitObjectId.Err _) false]
      [(ResultGitObjectId.Ok checked) (string.eq checked.binary (& id.binary))])))

(define (git-object-kind-name [kind : GitObjectKind]) : String
  (match kind
    [(GitObjectKind.Blob) "blob"]
    [(GitObjectKind.Tree) "tree"]
    [(GitObjectKind.Commit) "commit"]
    [(GitObjectKind.Tag) "tag"]))

;: The callback receives the exact uncompressed Git preimage and returns raw
;: digest bytes. No hash implementation is selected by this module.
(define (git-object-identity
  [format : GitObjectFormat]
  [kind : GitObjectKind]
  [content : (& content str)]
  [digest : (-> String String)]) : ResultGitObjectId
  (let
    [prefix : String (git-object-kind-name kind)]
    [length : i64 (string.string-length content)]
    [size : String (string.int->string length)]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    (begin
      (byte_buf.byte-buf-builder-append-string (&mut out) prefix)
      (byte_buf.byte-buf-builder-push (&mut out) (cast 32 : u8))
      (byte_buf.byte-buf-builder-append-string (&mut out) size)
      (byte_buf.byte-buf-builder-push (&mut out) (cast 0 : u8))
      (byte_buf.byte-buf-builder-append-string-range
        (&mut out)
        (string.substring content 0 length)
        0
        length)
      (git-object-id-from-binary
        format
        (digest (byte_buf.byte-buf-builder-finish-string (& out)))))))

;: Git check-ref-format rules for full ref names. HEAD is admitted only as
;: the advertised pseudoref, never as a branch/tag component.
(define (git-object-refname-valid? [name : (& name str)] [allow-head : bool]) : bool
  (let
    [length : i64 (string.string-length name)]
    [index : i64 0]
    [component-start : i64 0]
    [slashes : i64 0]
    (begin
      (when (and allow-head (string.eq name "HEAD")) (return true))
      (when
        (or
          (< length 3)
          (= (git-object-byte name 0) 47)
          (= (git-object-byte name (- length 1)) 47)
          (= (git-object-byte name (- length 1)) 46)
          (string.eq name "@"))
        (return false))
      (while (< index length)
        (let
          [byte : i64 (git-object-byte name index)]
          (begin
            (when
              (or
                (< byte 32)
                (= byte 127)
                (= byte 32)
                (= byte 126)
                (= byte 94)
                (= byte 58)
                (= byte 63)
                (= byte 42)
                (= byte 91)
                (= byte 92))
              (return false))
            (when
              (and
                (> index 0)
                (or
                  (and (= byte 46) (= (git-object-byte name (- index 1)) 46))
                  (and (= byte 123) (= (git-object-byte name (- index 1)) 64))))
              (return false))
            (when
              (= byte 47)
              (begin
                (when (= index component-start) (return false))
                (when
                  (= (git-object-byte name component-start) 46)
                  (return false))
                (when
                  (and
                    (>= (- index component-start) 5)
                    (string.eq (string.substring name (- index 5) 5) ".lock"))
                  (return false))
                (set! slashes (+ slashes 1))
                (set! component-start (+ index 1))))
            (set! index (+ index 1)))))
      (and
        (> slashes 0)
        (!= (git-object-byte name component-start) 46)
        (not
          (and
            (>= (- length component-start) 5)
            (string.eq (string.substring name (- length 5) 5) ".lock")))))))

(defenum GitAdvertisedPeeled
  (Absent)
  (Present GitObjectId))

(defstruct GitAdvertisedRef
  (name String)
  (id GitObjectId)
  (has-symref bool)
  (symref-target String)
  (peeled GitAdvertisedPeeled))

(defenum ResultGitAdvertisedRef
  (Ok GitAdvertisedRef)
  (Err String))

(define (git-object-advertised-ref
  [format : GitObjectFormat]
  [name : (& name str)]
  [hex : (& hex str)]
  [symref-target : (& symref_target str)]
  [peeled-hex : (& peeled_hex str)]) : ResultGitAdvertisedRef
  (begin
    (unless
      (git-object-refname-valid? name true)
      (return
        (ResultGitAdvertisedRef.Err "git object: invalid advertised ref name")))
    (when
      (and
        (> (string.string-length symref-target) 0)
        (or
          (not (git-object-refname-valid? symref-target false))
          (string.eq name symref-target)))
      (return (ResultGitAdvertisedRef.Err "git object: invalid symref target")))
    (match (git-object-id-from-hex format hex)
      [(ResultGitObjectId.Err error) (ResultGitAdvertisedRef.Err error)]
      [(ResultGitObjectId.Ok id)
        (let
          [peeled : GitAdvertisedPeeled (GitAdvertisedPeeled.Absent)]
          (begin
            (when
              (> (string.string-length peeled-hex) 0)
              (match (git-object-id-from-hex format peeled-hex)
                [(ResultGitObjectId.Err error)
                  (return (ResultGitAdvertisedRef.Err error))]
                [(ResultGitObjectId.Ok peeled-id)
                  (set! peeled (GitAdvertisedPeeled.Present peeled-id))]))
            (ResultGitAdvertisedRef.Ok
              (GitAdvertisedRef
                (string.substring name 0 (string.string-length name))
                id
                (> (string.string-length symref-target) 0)
                (string.substring
                  symref-target
                  0
                  (string.string-length symref-target))
                peeled))))])))

(defstruct GitObjectLimits
  (max-object-bytes i64)
  (max-headers i64)
  (max-tree-entries i64)
  (max-name-comparisons i64)
  (max-refs i64)
  (max-peel-depth i64)
  (max-lookups i64))

(define (git-object-limits-valid? [limits : (& limits GitObjectLimits)]) : bool
  (and
    (>= limits.max-object-bytes 0)
    (>= limits.max-headers 0)
    (>= limits.max-tree-entries 0)
    (>= limits.max-name-comparisons 0)
    (>= limits.max-refs 0)
    (>= limits.max-peel-depth 0)
    (>= limits.max-lookups 0)))

(defstruct GitObjectHeader
  (name String)
  (value String))

(defstruct GitObjectHeaders
  (items (__tl_dyn-array GitObjectHeader))
  (message-start i64))

(defenum ResultGitObjectHeaders
  (Ok GitObjectHeaders)
  (Err String))

(define (git-object-find-byte
  [bytes : (& bytes str)]
  [start : i64]
  [wanted : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length bytes)]
    (begin
      (while (< index length)
        (begin
          (when (= (git-object-byte bytes index) wanted) (return index))
          (set! index (+ index 1))))
      -1)))

(define (git-object-header-key-valid? [bytes : (& bytes str)] [end : i64]) : bool
  (let
    [index : i64 0]
    (begin
      (when (<= end 0) (return false))
      (while (< index end)
        (let
          [byte : i64 (git-object-byte bytes index)]
          (begin
            (when (or (< byte 33) (> byte 126) (= byte 58)) (return false))
            (set! index (+ index 1)))))
      true)))

;: Parses all headers before the first empty line. A continuation belongs to
;: its preceding header and is retained verbatim, including LF and leading SP.
(define (git-object-read-headers
  [bytes : (& bytes str)]
  [limits : (& limits GitObjectLimits)]) : ResultGitObjectHeaders
  (let
    [length : i64 (string.string-length bytes)]
    [items : (__tl_dyn-array GitObjectHeader)
      (__tl_make-array GitObjectHeader 0)]
    [cursor : i64 0]
    (begin
      (unless
        (git-object-limits-valid? limits)
        (return (ResultGitObjectHeaders.Err "git object: invalid limits")))
      (when
        (> length limits.max-object-bytes)
        (return
          (ResultGitObjectHeaders.Err "git object: object exceeds byte limit")))
      (while (< cursor length)
        (let
          [line-end : i64 (git-object-find-byte bytes cursor 10)]
          (begin
            (when
              (< line-end 0)
              (return
                (ResultGitObjectHeaders.Err "git object: unterminated header")))
            (when
              (= line-end cursor)
              (return
                (ResultGitObjectHeaders.Ok
                  (GitObjectHeaders items (+ line-end 1)))))
            (when
              (= (git-object-byte bytes cursor) 32)
              (return
                (ResultGitObjectHeaders.Err "git object: orphan continuation")))
            (when
              (>= (array-length items) limits.max-headers)
              (return
                (ResultGitObjectHeaders.Err "git object: header limit exceeded")))
            (let
              [space : i64 (git-object-find-byte bytes cursor 32)]
              [value-end : i64 line-end]
              [next : i64 (+ line-end 1)]
              (begin
                (when
                  (or
                    (< space 0)
                    (>= space line-end)
                    (not
                      (git-object-header-key-valid?
                        (string.substring bytes cursor (- space cursor))
                        (- space cursor))))
                  (return
                    (ResultGitObjectHeaders.Err
                      "git object: invalid header name")))
                (while (and (< next length) (= (git-object-byte bytes next) 32))
                  (let
                    [continuation-end : i64
                      (git-object-find-byte bytes next 10)]
                    (begin
                      (when
                        (< continuation-end 0)
                        (return
                          (ResultGitObjectHeaders.Err
                            "git object: truncated continuation")))
                      (set! value-end continuation-end)
                      (set! next (+ continuation-end 1)))))
                (let
                  [header-name : String
                    (string.substring bytes cursor (- space cursor))]
                  [header-value : String
                    (string.substring
                      bytes
                      (+ space 1)
                      (- (- value-end space) 1))]
                  [nul : i64 (git-object-find-byte (& header-value) 0 0)]
                  (begin
                    (when
                      (>= nul 0)
                      (return
                        (ResultGitObjectHeaders.Err "git object: NUL in header")))
                    (__tl_array-push!
                      items
                      (GitObjectHeader header-name header-value))
                    (set! cursor next))))))))
      (ResultGitObjectHeaders.Err
        "git object: missing header/message separator"))))

(defstruct GitCommit
  (tree GitObjectId)
  (parents (__tl_dyn-array GitObjectId))
  (author String)
  (committer String)
  (extra-headers (__tl_dyn-array GitObjectHeader))
  (message String))

(defenum ResultGitCommit
  (Ok GitCommit)
  (Err String))

(define (git-object-decode-commit
  [format : GitObjectFormat]
  [bytes : (& bytes str)]
  [limits : (& limits GitObjectLimits)]) : ResultGitCommit
  (match (git-object-read-headers bytes limits)
    [(ResultGitObjectHeaders.Err error) (ResultGitCommit.Err error)]
    [(ResultGitObjectHeaders.Ok parsed)
      (let
        [tree-count : i64 0]
        [author-count : i64 0]
        [committer-count : i64 0]
        [tree : GitObjectId (GitObjectId format "" "")]
        [parents : (__tl_dyn-array GitObjectId) (__tl_make-array GitObjectId 0)]
        [author : String ""]
        [committer : String ""]
        [extra : (__tl_dyn-array GitObjectHeader)
          (__tl_make-array GitObjectHeader 0)]
        [index : i64 0]
        (begin
          (while (< index (array-length parsed.items))
            (let
              [header : (& parsed GitObjectHeader)
                (& (array-ref parsed.items index))]
              (begin
                (cond
                  [(string.eq header.name "tree")
                    (begin
                      (set! tree-count (+ tree-count 1))
                      (when
                        (> tree-count 1)
                        (return
                          (ResultGitCommit.Err
                            "git object: duplicate commit tree")))
                      (match (git-object-id-from-hex format (& header.value))
                        [(ResultGitObjectId.Err error)
                          (return (ResultGitCommit.Err error))]
                        [(ResultGitObjectId.Ok id) (set! tree id)]))]
                  [(string.eq header.name "parent")
                    (match (git-object-id-from-hex format (& header.value))
                      [(ResultGitObjectId.Err error)
                        (return (ResultGitCommit.Err error))]
                      [(ResultGitObjectId.Ok id) (__tl_array-push! parents id)])]
                  [(string.eq header.name "author")
                    (begin
                      (set! author-count (+ author-count 1))
                      (when
                        (> author-count 1)
                        (return
                          (ResultGitCommit.Err
                            "git object: duplicate commit author")))
                      (when
                        (>= (git-object-find-byte (& header.value) 0 10) 0)
                        (return
                          (ResultGitCommit.Err
                            "git object: continued commit author")))
                      (set!
                        author
                        (string.substring
                          (& header.value)
                          0
                          (string.string-length (& header.value)))))]
                  [(string.eq header.name "committer")
                    (begin
                      (set! committer-count (+ committer-count 1))
                      (when
                        (> committer-count 1)
                        (return
                          (ResultGitCommit.Err
                            "git object: duplicate commit committer")))
                      (when
                        (>= (git-object-find-byte (& header.value) 0 10) 0)
                        (return
                          (ResultGitCommit.Err
                            "git object: continued commit committer")))
                      (set!
                        committer
                        (string.substring
                          (& header.value)
                          0
                          (string.string-length (& header.value)))))]
                  [else
                    (__tl_array-push!
                      extra
                      (GitObjectHeader
                        (string.substring
                          (& header.name)
                          0
                          (string.string-length (& header.name)))
                        (string.substring
                          (& header.value)
                          0
                          (string.string-length (& header.value)))))])
                (set! index (+ index 1)))))
          (if (or
            (!= tree-count 1)
            (!= author-count 1)
            (!= committer-count 1)
            (= (string.string-length (& author)) 0)
            (= (string.string-length (& committer)) 0))
            (ResultGitCommit.Err "git object: required commit header missing")
            (ResultGitCommit.Ok
              (GitCommit
                tree
                parents
                author
                committer
                extra
                (string.substring
                  bytes
                  parsed.message-start
                  (- (string.string-length bytes) parsed.message-start)))))))]))

(defenum GitTreeEntryKind
  (Tree)
  (Regular)
  (Executable)
  (Symlink)
  (Gitlink))

(defstruct GitTreeEntry
  (mode i64)
  (kind GitTreeEntryKind)
  (name String)
  (id GitObjectId))

(defstruct GitTree
  (entries (__tl_dyn-array GitTreeEntry)))

(defenum ResultGitTree
  (Ok GitTree)
  (Err String))

(define (git-object-tree-mode [mode : i64]) : i64
  (cond
    [(= mode 16384) 1]
    ;; 040000, tree
    [(= mode 33188) 2]
    ;; 100644, regular
    [(= mode 33261) 3]
    ;; 100755, executable
    [(= mode 40960) 4]
    ;; 120000, symlink
    [(= mode 57344) 5]
    ;; 160000, gitlink
    [else 0]))

(define (git-object-tree-kind [mode-code : i64]) : GitTreeEntryKind
  (cond
    [(= mode-code 1) (GitTreeEntryKind.Tree)]
    [(= mode-code 2) (GitTreeEntryKind.Regular)]
    [(= mode-code 3) (GitTreeEntryKind.Executable)]
    [(= mode-code 4) (GitTreeEntryKind.Symlink)]
    [else (GitTreeEntryKind.Gitlink)]))

;: Compare Git tree names as if directory names had a trailing slash.
(define (git-object-tree-name-compare
  [left : (& left str)]
  [left-tree : bool]
  [right : (& right str)]
  [right-tree : bool]) : i64
  (let
    [left-length : i64 (string.string-length left)]
    [right-length : i64 (string.string-length right)]
    [index : i64 0]
    (begin
      (while (and (< index left-length) (< index right-length))
        (let
          [a : i64 (git-object-byte left index)]
          [b : i64 (git-object-byte right index)]
          (begin
            (when (!= a b) (return (- a b)))
            (set! index (+ index 1)))))
      (let
        [a : i64
          (if (< index left-length)
            (git-object-byte left index)
            (if left-tree
              47
              0))]
        [b : i64
          (if (< index right-length)
            (git-object-byte right index)
            (if right-tree
              47
              0))]
        (- a b)))))

(define (git-object-decode-tree
  [format : GitObjectFormat]
  [bytes : (& bytes str)]
  [limits : (& limits GitObjectLimits)]) : ResultGitTree
  (let
    [length : i64 (string.string-length bytes)]
    [width : i64 (git-object-id-bytes format)]
    [entries : (__tl_dyn-array GitTreeEntry) (__tl_make-array GitTreeEntry 0)]
    [cursor : i64 0]
    [comparisons : i64 0]
    (begin
      (unless
        (git-object-limits-valid? limits)
        (return (ResultGitTree.Err "git object: invalid limits")))
      (when
        (> length limits.max-object-bytes)
        (return (ResultGitTree.Err "git object: tree exceeds byte limit")))
      (while (< cursor length)
        (begin
          (when
            (>= (array-length entries) limits.max-tree-entries)
            (return (ResultGitTree.Err "git object: tree entry limit exceeded")))
          (let
            [space : i64 (git-object-find-byte bytes cursor 32)]
            [mode : i64 0]
            (begin
              (when
                (or (< space 0) (= space cursor) (> (- space cursor) 6))
                (return (ResultGitTree.Err "git object: malformed tree mode")))
              (when
                (and
                  (> (- space cursor) 1)
                  (= (git-object-byte bytes cursor) 48))
                (return
                  (ResultGitTree.Err "git object: noncanonical tree mode")))
              (let
                [index : i64 cursor]
                (while (< index space)
                  (let
                    [digit : i64 (- (git-object-byte bytes index) 48)]
                    (begin
                      (when
                        (or (< digit 0) (> digit 7))
                        (return
                          (ResultGitTree.Err
                            "git object: invalid octal tree mode")))
                      (set! mode (+ (* mode 8) digit))
                      (set! index (+ index 1))))))
              (let
                [mode-code : i64 (git-object-tree-mode mode)]
                [name-start : i64 (+ space 1)]
                [nul : i64 (git-object-find-byte bytes (+ space 1) 0)]
                (begin
                  (when
                    (= mode-code 0)
                    (return
                      (ResultGitTree.Err "git object: unsupported tree mode")))
                  (when
                    (or (< nul 0) (= nul name-start))
                    (return
                      (ResultGitTree.Err "git object: malformed tree name")))
                  (when
                    (> width (- length (+ nul 1)))
                    (return
                      (ResultGitTree.Err "git object: truncated tree object ID")))
                  (let
                    [name : String
                      (string.substring bytes name-start (- nul name-start))]
                    [slash : i64 (git-object-find-byte (& name) 0 47)]
                    (begin
                      (when
                        (>= slash 0)
                        (return
                          (ResultGitTree.Err "git object: forbidden tree name")))
                      (let
                        [prior-index : i64 0]
                        (while (< prior-index (array-length entries))
                          (let
                            [prior : (& entries GitTreeEntry)
                              (& (array-ref entries prior-index))]
                            (begin
                              (when
                                (>= comparisons limits.max-name-comparisons)
                                (return
                                  (ResultGitTree.Err
                                    "git object: tree name comparison limit exceeded")))
                              (set! comparisons (+ comparisons 1))
                              (when
                                (string.eq (& prior.name) (& name))
                                (return
                                  (ResultGitTree.Err
                                    "git object: duplicate tree name")))
                              (set! prior-index (+ prior-index 1))))))
                      (when
                        (> (array-length entries) 0)
                        (let
                          [previous : (& entries GitTreeEntry)
                            (& (array-ref entries (- (array-length entries) 1)))]
                          (when
                            (>=
                              (git-object-tree-name-compare
                                (& previous.name)
                                (= previous.mode 16384)
                                (& name)
                                (= mode 16384))
                              0)
                            (return
                              (ResultGitTree.Err
                                "git object: tree entries out of order")))))
                      (match (git-object-id-from-binary
                        format
                        (string.substring bytes (+ nul 1) width))
                        [(ResultGitObjectId.Err error)
                          (return (ResultGitTree.Err error))]
                        [(ResultGitObjectId.Ok id)
                          (__tl_array-push!
                            entries
                            (GitTreeEntry
                              mode
                              (git-object-tree-kind mode-code)
                              name
                              id))])
                      (set! cursor (+ (+ nul 1) width))))))))))
      (ResultGitTree.Ok (GitTree entries)))))

(defstruct GitTag
  (target GitObjectId)
  (target-kind GitObjectKind)
  (name String)
  (has-tagger bool)
  (tagger String)
  (extra-headers (__tl_dyn-array GitObjectHeader))
  (message String))

(defenum ResultGitTag
  (Ok GitTag)
  (Err String))

(define (git-object-kind-from-name [name : (& name str)]) : i64
  (cond
    [(string.eq name "blob") 1]
    [(string.eq name "tree") 2]
    [(string.eq name "commit") 3]
    [(string.eq name "tag") 4]
    [else 0]))

(define (git-object-kind-from-code [code : i64]) : GitObjectKind
  (cond
    [(= code 1) (GitObjectKind.Blob)]
    [(= code 2) (GitObjectKind.Tree)]
    [(= code 3) (GitObjectKind.Commit)]
    [else (GitObjectKind.Tag)]))

(define (git-object-decode-tag
  [format : GitObjectFormat]
  [bytes : (& bytes str)]
  [limits : (& limits GitObjectLimits)]) : ResultGitTag
  (match (git-object-read-headers bytes limits)
    [(ResultGitObjectHeaders.Err error) (ResultGitTag.Err error)]
    [(ResultGitObjectHeaders.Ok parsed)
      (let
        [object-count : i64 0]
        [type-count : i64 0]
        [tag-count : i64 0]
        [tagger-count : i64 0]
        [target : GitObjectId (GitObjectId format "" "")]
        [target-code : i64 0]
        [name : String ""]
        [tagger : String ""]
        [extra : (__tl_dyn-array GitObjectHeader)
          (__tl_make-array GitObjectHeader 0)]
        [index : i64 0]
        (begin
          (while (< index (array-length parsed.items))
            (let
              [header : (& parsed GitObjectHeader)
                (& (array-ref parsed.items index))]
              (begin
                (cond
                  [(string.eq header.name "object")
                    (begin
                      (set! object-count (+ object-count 1))
                      (when
                        (> object-count 1)
                        (return
                          (ResultGitTag.Err "git object: duplicate tag object")))
                      (match (git-object-id-from-hex format (& header.value))
                        [(ResultGitObjectId.Err error)
                          (return (ResultGitTag.Err error))]
                        [(ResultGitObjectId.Ok id) (set! target id)]))]
                  [(string.eq header.name "type")
                    (begin
                      (set! type-count (+ type-count 1))
                      (when
                        (> type-count 1)
                        (return
                          (ResultGitTag.Err "git object: duplicate tag type")))
                      (set!
                        target-code
                        (git-object-kind-from-name (& header.value))))]
                  [(string.eq header.name "tag")
                    (begin
                      (set! tag-count (+ tag-count 1))
                      (when
                        (> tag-count 1)
                        (return
                          (ResultGitTag.Err "git object: duplicate tag name")))
                      (set!
                        name
                        (string.substring
                          (& header.value)
                          0
                          (string.string-length (& header.value)))))]
                  [(string.eq header.name "tagger")
                    (begin
                      (set! tagger-count (+ tagger-count 1))
                      (when
                        (> tagger-count 1)
                        (return
                          (ResultGitTag.Err "git object: duplicate tagger")))
                      (when
                        (>= (git-object-find-byte (& header.value) 0 10) 0)
                        (return
                          (ResultGitTag.Err "git object: continued tagger")))
                      (set!
                        tagger
                        (string.substring
                          (& header.value)
                          0
                          (string.string-length (& header.value)))))]
                  [else
                    (__tl_array-push!
                      extra
                      (GitObjectHeader
                        (string.substring
                          (& header.name)
                          0
                          (string.string-length (& header.name)))
                        (string.substring
                          (& header.value)
                          0
                          (string.string-length (& header.value)))))])
                (set! index (+ index 1)))))
          (if (or
            (!= object-count 1)
            (!= type-count 1)
            (!= tag-count 1)
            (= target-code 0)
            (= (string.string-length (& name)) 0)
            (not
              (git-object-refname-valid?
                (str_cat.str-cat "refs/tags/" name)
                false))
            (and (= tagger-count 1) (= (string.string-length (& tagger)) 0)))
            (ResultGitTag.Err
              "git object: required tag header missing or invalid")
            (ResultGitTag.Ok
              (GitTag
                target
                (git-object-kind-from-code target-code)
                name
                (= tagger-count 1)
                tagger
                extra
                (string.substring
                  bytes
                  parsed.message-start
                  (- (string.string-length bytes) parsed.message-start)))))))]))

(defstruct GitObjectRecord
  (id GitObjectId)
  (kind GitObjectKind)
  (content String))

(defenum ResultGitObjectRecord
  (Ok GitObjectRecord)
  (Missing))

(defenum GitRevSelector
  (ExactId String)
  (Branch String)
  (Tag String))

(defenum ResultGitCommitId
  (Ok GitObjectId)
  (Err String))

(define (git-object-validated-advertisement?
  [format : GitObjectFormat]
  [advert : (& advert GitAdvertisedRef)]) : bool
  (and
    (git-object-refname-valid? (& advert.name) true)
    (git-object-id-valid? format (& advert.id))
    (match (& advert.peeled)
      [(GitAdvertisedPeeled.Absent) true]
      [(GitAdvertisedPeeled.Present peeled-id)
        (git-object-id-valid? format peeled-id)])
    (if advert.has-symref
      (and
        (git-object-refname-valid? (& advert.symref-target) false)
        (not (string.eq (& advert.name) (& advert.symref-target))))
      (= (string.string-length (& advert.symref-target)) 0))))

(define (git-object-id-copy
  [format : GitObjectFormat]
  [id : (& id GitObjectId)]) : GitObjectId
  (GitObjectId
    format
    (string.substring (& id.binary) 0 (string.string-length (& id.binary)))
    (string.substring (& id.hex) 0 (string.string-length (& id.hex)))))

;: Resolve only exact advertised object IDs or full advertised branch/tag refs.
;: Lookup and digest are injected; returned objects are checked against IDs and
;: tag-declared types before each peel step. No revision expressions are parsed.
(define (git-object-resolve-commit
  [format : GitObjectFormat]
  [selector : GitRevSelector]
  [refs : (& refs (__tl_dyn-array GitAdvertisedRef))]
  [limits : (& limits GitObjectLimits)]
  [lookup : (-> String ResultGitObjectRecord)]
  [digest : (-> String String)]) : ResultGitCommitId
  (let
    [selected : String ""]
    [mode : i64 0]
    [ref-index : i64 0]
    [matches : i64 0]
    [current : GitObjectId (GitObjectId format "" "")]
    [seen : (__tl_dyn-array String) (__tl_make-array String 0)]
    [expected-code : i64 0]
    [depth : i64 0]
    [lookups : i64 0]
    (begin
      (unless
        (git-object-limits-valid? limits)
        (return (ResultGitCommitId.Err "git object: invalid limits")))
      (when
        (> (array-length refs) limits.max-refs)
        (return
          (ResultGitCommitId.Err "git object: advertised ref limit exceeded")))
      (match selector
        [(GitRevSelector.ExactId hex)
          (begin
            (set! mode 1)
            (match (git-object-id-from-hex format hex)
              [(ResultGitObjectId.Err error)
                (return (ResultGitCommitId.Err error))]
              [(ResultGitObjectId.Ok id) (set! selected id.hex)]))]
        [(GitRevSelector.Branch name)
          (begin
            (set! mode 2)
            (unless
              (and
                (git-object-refname-valid? name false)
                (>= (string.string-length name) 11)
                (string.eq (string.substring name 0 11) "refs/heads/"))
              (return
                (ResultGitCommitId.Err "git object: invalid branch selector")))
            (set!
              selected
              (string.substring name 0 (string.string-length name))))]
        [(GitRevSelector.Tag name)
          (begin
            (set! mode 3)
            (unless
              (and
                (git-object-refname-valid? name false)
                (>= (string.string-length name) 10)
                (string.eq (string.substring name 0 10) "refs/tags/"))
              (return
                (ResultGitCommitId.Err "git object: invalid tag selector")))
            (set!
              selected
              (string.substring name 0 (string.string-length name))))])
      (while (< ref-index (array-length refs))
        (let
          [advert : (& refs GitAdvertisedRef) (& (array-ref refs ref-index))]
          (begin
            (unless
              (git-object-validated-advertisement? format advert)
              (return
                (ResultGitCommitId.Err "git object: malformed advertised ref")))
            (if (= mode 1)
              (begin
                (when
                  (string.eq (& advert.id.hex) (& selected))
                  (begin
                    (set! matches (+ matches 1))
                    (set! current (git-object-id-copy format (& advert.id)))))
                (match (& advert.peeled)
                  [(GitAdvertisedPeeled.Absent) unit]
                  [(GitAdvertisedPeeled.Present peeled-id)
                    (when
                      (string.eq (& peeled-id.hex) (& selected))
                      (begin
                        (set! matches (+ matches 1))
                        (set! current (git-object-id-copy format peeled-id))))]))
              (when
                (string.eq (& advert.name) (& selected))
                (begin
                  (set! matches (+ matches 1))
                  (set! current (git-object-id-copy format (& advert.id)))))))
          (set! ref-index (+ ref-index 1))))
      (when
        (= matches 0)
        (return
          (ResultGitCommitId.Err "git object: revision is not advertised")))
      (when
        (and (!= mode 1) (> matches 1))
        (return (ResultGitCommitId.Err "git object: ambiguous advertised ref")))
      (while true
        (begin
          (when
            (>= lookups limits.max-lookups)
            (return (ResultGitCommitId.Err "git object: lookup limit exceeded")))
          (when
            (> depth limits.max-peel-depth)
            (return (ResultGitCommitId.Err "git object: tag depth exceeded")))
          (let
            [index : i64 0]
            (while (< index (array-length seen))
              (begin
                (when
                  (string.eq (array-ref seen index) (& current.hex))
                  (return (ResultGitCommitId.Err "git object: tag cycle")))
                (set! index (+ index 1)))))
          (__tl_array-push!
            seen
            (string.substring
              (& current.hex)
              0
              (string.string-length (& current.hex))))
          (set! lookups (+ lookups 1))
          (match (lookup
            (string.substring
              (& current.hex)
              0
              (string.string-length (& current.hex))))
            [(ResultGitObjectRecord.Missing)
              (return (ResultGitCommitId.Err "git object: object is missing"))]
            [(ResultGitObjectRecord.Ok record)
              (begin
                (unless
                  (and
                    (git-object-id-valid? format (& record.id))
                    (string.eq (& record.id.hex) (& current.hex))
                    (<=
                      (string.string-length (& record.content))
                      limits.max-object-bytes))
                  (return
                    (ResultGitCommitId.Err "git object: invalid lookup result")))
                (match (git-object-identity
                  format
                  (match (& record.kind)
                    [(GitObjectKind.Blob) (GitObjectKind.Blob)]
                    [(GitObjectKind.Tree) (GitObjectKind.Tree)]
                    [(GitObjectKind.Commit) (GitObjectKind.Commit)]
                    [(GitObjectKind.Tag) (GitObjectKind.Tag)])
                  (& record.content)
                  digest)
                  [(ResultGitObjectId.Err error)
                    (return (ResultGitCommitId.Err error))]
                  [(ResultGitObjectId.Ok verified)
                    (unless
                      (string.eq (& verified.hex) (& current.hex))
                      (return
                        (ResultGitCommitId.Err
                          "git object: object digest mismatch")))])
                (when
                  (and
                    (!= expected-code 0)
                    (!=
                      expected-code
                      (git-object-kind-from-name
                        (git-object-kind-name
                          (match (& record.kind)
                            [(GitObjectKind.Blob) (GitObjectKind.Blob)]
                            [(GitObjectKind.Tree) (GitObjectKind.Tree)]
                            [(GitObjectKind.Commit) (GitObjectKind.Commit)]
                            [(GitObjectKind.Tag) (GitObjectKind.Tag)])))))
                  (return
                    (ResultGitCommitId.Err
                      "git object: tag target type mismatch")))
                (match (& record.kind)
                  [(GitObjectKind.Commit)
                    (match (git-object-decode-commit
                      format
                      (& record.content)
                      limits)
                      [(ResultGitCommit.Err error)
                        (return (ResultGitCommitId.Err error))]
                      [(ResultGitCommit.Ok _)
                        (return (ResultGitCommitId.Ok current))])]
                  [(GitObjectKind.Tag)
                    (match (git-object-decode-tag
                      format
                      (& record.content)
                      limits)
                      [(ResultGitTag.Err error)
                        (return (ResultGitCommitId.Err error))]
                      [(ResultGitTag.Ok tag)
                        (begin
                          (set! current tag.target)
                          (set!
                            expected-code
                            (git-object-kind-from-name
                              (git-object-kind-name tag.target-kind)))
                          (set! depth (+ depth 1)))])]
                  [_
                    (return
                      (ResultGitCommitId.Err
                        "git object: revision does not resolve to a commit"))]))])))
      (ResultGitCommitId.Err "git object: unreachable peel state"))))