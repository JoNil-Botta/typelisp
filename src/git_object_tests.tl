;; Git object format, malformed byte stream, and resolution fixtures.
(import git_object_core as git_object)
(import stdlib.byte_buf as bytes)
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.crypto_sha1_git as sha1)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define (git-object-test-limits) : git_object.GitObjectLimits
  (git_object.GitObjectLimits 4096 32 32 512 32 8 16))

(define (git-object-test-require [ok : bool] [message : String]) : unit
  (unless ok (io.panic message)))

(define (git-object-test-id-error? [result : git_object.ResultGitObjectId]) : bool
  (match result
    [(git_object.ResultGitObjectId.Err _) true]
    [_ false]))

(define (git-object-test-commit-error? [result : git_object.ResultGitCommit]) : bool
  (match result
    [(git_object.ResultGitCommit.Err _) true]
    [_ false]))

(define (git-object-test-tree-error? [result : git_object.ResultGitTree]) : bool
  (match result
    [(git_object.ResultGitTree.Err _) true]
    [_ false]))

(define (git-object-test-tag-error? [result : git_object.ResultGitTag]) : bool
  (match result
    [(git_object.ResultGitTag.Err _) true]
    [_ false]))

(define (git-object-test-resolve-error? [result : git_object.ResultGitCommitId]) : bool
  (match result
    [(git_object.ResultGitCommitId.Err _) true]
    [_ false]))

(define (git-object-test-resolve-error-is?
  [result : git_object.ResultGitCommitId]
  [expected : (& expected str)]) : bool
  (match result
    [(git_object.ResultGitCommitId.Err message)
      (string.eq (& message) expected)]
    [_ false]))

(define (git-object-test-id
  [format : git_object.GitObjectFormat]
  [hex : (& hex str)]) : git_object.GitObjectId
  (match (git_object.git-object-id-from-hex format hex)
    [(git_object.ResultGitObjectId.Ok id) id]
    [(git_object.ResultGitObjectId.Err _)
      (io.panic "git object test: invalid fixture ID")]))

(define (git-object-test-sha1 [preimage : String]) : String
  (match (sha1.git-digest (bytes.str-as-bytes (& preimage)))
    [(sha1.GitSha1FinalizeErr _) (io.panic "git object test: SHA-1 failed")]
    [(sha1.GitSha1FinalizeOk value)
      (let
        [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
        [index : i64 0]
        (begin
          (while (< index 20)
            (begin
              (byte_buf.byte-buf-builder-push
                (&mut out)
                (sha1.digest-byte (& value) index))
              (set! index (+ index 1))))
          (byte_buf.byte-buf-builder-finish-string (& out))))]))

(define (git-object-test-sha256 [preimage : String]) : String
  (match (sha256.digest (bytes.str-as-bytes (& preimage)))
    [(sha256.Sha256FinalizeErr _) (io.panic "git object test: SHA-256 failed")]
    [(sha256.Sha256FinalizeOk value)
      (let
        [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
        [index : i64 0]
        (begin
          (while (< index 32)
            (begin
              (byte_buf.byte-buf-builder-push
                (&mut out)
                (sha256.digest-byte (& value) index))
              (set! index (+ index 1))))
          (byte_buf.byte-buf-builder-finish-string (& out))))]))

(define (git-object-test-identity?
  [format : git_object.GitObjectFormat]
  [content : String]
  [expected : (& expected str)]
  [digest : (-> String String)]) : bool
  (match (git_object.git-object-identity
    format
    (git_object.GitObjectKind.Blob)
    (& content)
    digest)
    [(git_object.ResultGitObjectId.Err _) false]
    [(git_object.ResultGitObjectId.Ok id) (string.eq (& id.hex) expected)]))

(define (git-object-test-ids-and-preimages?) : bool
  (let
    [sha1-hex : String "ce013625030ba8dba906f756967f9e9ca394464a"]
    [sha256-hex : String
      "2cf8d83d9ee29543b34a87727421fdecb7e3f3a183d337639025de576db9ebb4"]
    [upper : String "CE013625030BA8DBA906F756967F9E9CA394464A"]
    [zero : String "0000000000000000000000000000000000000000"]
    [sha1-id : git_object.GitObjectId
      (git-object-test-id (git_object.GitObjectFormat.Sha1) (& sha1-hex))]
    (and
      (git-object-test-identity?
        (git_object.GitObjectFormat.Sha1)
        "hello\n"
        (& sha1-hex)
        git-object-test-sha1)
      (git-object-test-identity?
        (git_object.GitObjectFormat.Sha256)
        "hello\n"
        (& sha256-hex)
        git-object-test-sha256)
      (git_object.git-object-id-valid?
        (git_object.GitObjectFormat.Sha1)
        (& sha1-id))
      (not
        (git_object.git-object-id-valid?
          (git_object.GitObjectFormat.Sha256)
          (& sha1-id)))
      (git-object-test-id-error?
        (git_object.git-object-id-from-hex
          (git_object.GitObjectFormat.Sha1)
          (& sha256-hex)))
      (git-object-test-id-error?
        (git_object.git-object-id-from-hex
          (git_object.GitObjectFormat.Sha1)
          (& upper)))
      (git-object-test-id-error?
        (git_object.git-object-id-from-hex
          (git_object.GitObjectFormat.Sha1)
          (& zero)))
      (git-object-test-id-error?
        (git_object.git-object-id-from-binary
          (git_object.GitObjectFormat.Sha256)
          (& sha1-id.binary))))))

(define (git-object-test-refs?) : bool
  (let
    [bad : (__tl_dyn-array String) (__tl_make-array String 0)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (__tl_array-push! bad "")
      (__tl_array-push! bad "refs//heads/x")
      (__tl_array-push! bad "refs/heads/.bad")
      (__tl_array-push! bad "refs/heads/x.lock")
      (__tl_array-push! bad "refs/heads/x..y")
      (__tl_array-push! bad "refs/heads/x@{1}")
      (__tl_array-push! bad "refs/heads/x y")
      (__tl_array-push! bad "refs/heads/x\ny")
      (__tl_array-push! bad "refs/heads/x\\y")
      (__tl_array-push! bad "refs/heads/x.")
      (while (< index (array-length bad))
        (begin
          (when
            (git_object.git-object-refname-valid? (array-ref bad index) true)
            (set! ok false))
          (set! index (+ index 1))))
      (and
        ok
        (git_object.git-object-refname-valid? "a/b" false)
        (git_object.git-object-refname-valid? "refs/heads/main" false)
        (git_object.git-object-refname-valid? "HEAD" true)
        (not (git_object.git-object-refname-valid? "HEAD" false))
        (match (git_object.git-object-advertised-ref
          (git_object.GitObjectFormat.Sha1)
          "HEAD"
          "ce013625030ba8dba906f756967f9e9ca394464a"
          "refs/heads/main"
          "")
          [(git_object.ResultGitAdvertisedRef.Ok advert) advert.has-symref]
          [_ false])
        (match (git_object.git-object-advertised-ref
          (git_object.GitObjectFormat.Sha1)
          "HEAD"
          "ce013625030ba8dba906f756967f9e9ca394464a"
          "refs/heads/x..y"
          "")
          [(git_object.ResultGitAdvertisedRef.Err _) true]
          [_ false])))))

(define (git-object-test-commit-body [hex : (& hex str)]) : String
  (str_cat.str-cat
    "tree "
    (string.substring hex 0 (string.string-length hex))
    "\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\n\nmessage"))

(define (git-object-test-commit?) : bool
  (let
    [hex : String "1111111111111111111111111111111111111111"]
    [body : String (git-object-test-commit-body (& hex))]
    [duplicate : String
      (str_cat.str-cat
        "tree "
        (string.substring (& hex) 0 40)
        "\ntree 1111111111111111111111111111111111111111\nauthor A\ncommitter B\n\n")]
    [continuation : String
      (str_cat.str-cat
        "tree "
        (string.substring (& hex) 0 40)
        "\nauthor A\ncommitter B\ngpgsig -----BEGIN-----\n continuation\n\nraw")]
    [nul-builder : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (begin
      (byte_buf.byte-buf-builder-append-string
        (&mut nul-builder)
        (str_cat.str-cat "tree " (string.substring (& hex) 0 40) "\nauthor A"))
      (byte_buf.byte-buf-builder-push (&mut nul-builder) (cast 0 : u8))
      (byte_buf.byte-buf-builder-append-string
        (&mut nul-builder)
        "\ncommitter B\n\n")
      (let
        [nul : String (byte_buf.byte-buf-builder-finish-string (& nul-builder))]
        (and
          (match (git_object.git-object-decode-commit
            (git_object.GitObjectFormat.Sha1)
            (& body)
            (& limits))
            [(git_object.ResultGitCommit.Ok commit)
              (and
                (string.eq (& commit.tree.hex) (& hex))
                (= (array-length commit.parents) 0)
                (string.eq (& commit.message) "message"))]
            [_ false])
          (match (git_object.git-object-decode-commit
            (git_object.GitObjectFormat.Sha1)
            (& continuation)
            (& limits))
            [(git_object.ResultGitCommit.Ok commit)
              (and
                (= (array-length commit.extra-headers) 1)
                (string.eq
                  (& (array-ref commit.extra-headers 0).value)
                  "-----BEGIN-----\n continuation"))]
            [_ false])
          (git-object-test-commit-error?
            (git_object.git-object-decode-commit
              (git_object.GitObjectFormat.Sha1)
              (& duplicate)
              (& limits)))
          (git-object-test-commit-error?
            (git_object.git-object-decode-commit
              (git_object.GitObjectFormat.Sha1)
              (& nul)
              (& limits)))
          (git-object-test-commit-error?
            (git_object.git-object-decode-commit
              (git_object.GitObjectFormat.Sha256)
              (& body)
              (& limits)))
          (git-object-test-commit-error?
            (git_object.git-object-decode-commit
              (git_object.GitObjectFormat.Sha1)
              "tree x\n"
              (& limits))))))))

(define (git-object-test-append-tree-entry!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [mode : String]
  [name : String]
  [binary : (& binary str)]) : unit
  (begin
    (byte_buf.byte-buf-builder-append-string out mode)
    (byte_buf.byte-buf-builder-push out (cast 32 : u8))
    (byte_buf.byte-buf-builder-append-string out name)
    (byte_buf.byte-buf-builder-push out (cast 0 : u8))
    (byte_buf.byte-buf-builder-append-string-range
      out
      (string.substring binary 0 (string.string-length binary))
      0
      (string.string-length binary))))

(define (git-object-test-tree-kind-code
  [kind : (& kind git_object.GitTreeEntryKind)]) : i64
  (match kind
    [(git_object.GitTreeEntryKind.Tree) 1]
    [(git_object.GitTreeEntryKind.Regular) 2]
    [(git_object.GitTreeEntryKind.Executable) 3]
    [(git_object.GitTreeEntryKind.Symlink) 4]
    [(git_object.GitTreeEntryKind.Gitlink) 5]))

(define (git-object-test-tree?) : bool
  (let
    [hex1 : String "1111111111111111111111111111111111111111"]
    [hex2 : String
      "2222222222222222222222222222222222222222222222222222222222222222"]
    [id1 : git_object.GitObjectId
      (git-object-test-id (git_object.GitObjectFormat.Sha1) (& hex1))]
    [id2 : git_object.GitObjectId
      (git-object-test-id (git_object.GitObjectFormat.Sha256) (& hex2))]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [bad-order : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [duplicate : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [sha256-tree : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    [ok : bool true]
    (begin
      (git-object-test-append-tree-entry!
        (&mut out)
        "100644"
        "a"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut out)
        "100755"
        "b"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut out)
        "120000"
        "c"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut out)
        "160000"
        "d"
        (& id1.binary))
      (git-object-test-append-tree-entry! (&mut out) "40000" "e" (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut bad-order)
        "100644"
        "b"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut bad-order)
        "100644"
        "a"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut duplicate)
        "100644"
        "a"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut duplicate)
        "100644"
        "a-"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut duplicate)
        "40000"
        "a"
        (& id1.binary))
      (git-object-test-append-tree-entry!
        (&mut sha256-tree)
        "40000"
        "dir"
        (& id2.binary))
      (let
        [good : String (byte_buf.byte-buf-builder-finish-string (& out))]
        [bad : String (byte_buf.byte-buf-builder-finish-string (& bad-order))]
        [dup : String (byte_buf.byte-buf-builder-finish-string (& duplicate))]
        [wide : String
          (byte_buf.byte-buf-builder-finish-string (& sha256-tree))]
        [index : i64 1]
        (begin
          (while (< index 28)
            (begin
              (unless
                (git-object-test-tree-error?
                  (git_object.git-object-decode-tree
                    (git_object.GitObjectFormat.Sha1)
                    (string.substring (& good) 0 index)
                    (& limits)))
                (set! ok false))
              (set! index (+ index 1))))
          (and
            ok
            (match (git_object.git-object-decode-tree
              (git_object.GitObjectFormat.Sha1)
              (& good)
              (& limits))
              [(git_object.ResultGitTree.Ok tree)
                (and
                  (= (array-length tree.entries) 5)
                  (= (array-ref tree.entries 0).mode 33188)
                  (= (array-ref tree.entries 4).mode 16384)
                  (=
                    (git-object-test-tree-kind-code
                      (& (array-ref tree.entries 0).kind))
                    2)
                  (=
                    (git-object-test-tree-kind-code
                      (& (array-ref tree.entries 1).kind))
                    3)
                  (=
                    (git-object-test-tree-kind-code
                      (& (array-ref tree.entries 2).kind))
                    4)
                  (=
                    (git-object-test-tree-kind-code
                      (& (array-ref tree.entries 3).kind))
                    5)
                  (=
                    (git-object-test-tree-kind-code
                      (& (array-ref tree.entries 4).kind))
                    1))]
              [_ false])
            (match (git_object.git-object-decode-tree
              (git_object.GitObjectFormat.Sha256)
              (& wide)
              (& limits))
              [(git_object.ResultGitTree.Ok tree)
                (and
                  (= (array-length tree.entries) 1)
                  (string.eq (& (array-ref tree.entries 0).id.hex) (& hex2)))]
              [_ false])
            (git-object-test-tree-error?
              (git_object.git-object-decode-tree
                (git_object.GitObjectFormat.Sha1)
                (& bad)
                (& limits)))
            (git-object-test-tree-error?
              (git_object.git-object-decode-tree
                (git_object.GitObjectFormat.Sha1)
                (& dup)
                (& limits)))
            (git-object-test-tree-error?
              (git_object.git-object-decode-tree
                (git_object.GitObjectFormat.Sha256)
                (& good)
                (& limits)))
            (git-object-test-tree-error?
              (git_object.git-object-decode-tree
                (git_object.GitObjectFormat.Sha1)
                "100644 x"
                (& limits)))))))))

(define (git-object-test-tag-body [hex : (& hex str)]) : String
  (str_cat.str-cat
    "object "
    (string.substring hex 0 (string.string-length hex))
    "\ntype commit\ntag v1\ntagger A <a@b> 0 +0000\n\nmessage"))

(define (git-object-test-tag?) : bool
  (let
    [hex : String "1111111111111111111111111111111111111111"]
    [hex2 : String
      "2222222222222222222222222222222222222222222222222222222222222222"]
    [body : String (git-object-test-tag-body (& hex))]
    [body2 : String (git-object-test-tag-body (& hex2))]
    [duplicate : String
      (str_cat.str-cat
        "object "
        (string.substring (& hex) 0 40)
        "\ntype commit\ntype tree\ntag v1\n\n")]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (and
      (match (git_object.git-object-decode-tag
        (git_object.GitObjectFormat.Sha256)
        (& body2)
        (& limits))
        [(git_object.ResultGitTag.Ok tag)
          (string.eq (& tag.target.hex) (& hex2))]
        [_ false])
      (match (git_object.git-object-decode-tag
        (git_object.GitObjectFormat.Sha1)
        (& body)
        (& limits))
        [(git_object.ResultGitTag.Ok tag)
          (and
            (string.eq (& tag.target.hex) (& hex))
            (string.eq (& tag.name) "v1")
            tag.has-tagger
            (string.eq (& tag.message) "message"))]
        [_ false])
      (git-object-test-tag-error?
        (git_object.git-object-decode-tag
          (git_object.GitObjectFormat.Sha1)
          (& duplicate)
          (& limits)))
      (git-object-test-tag-error?
        (git_object.git-object-decode-tag
          (git_object.GitObjectFormat.Sha256)
          (& body)
          (& limits)))
      (git-object-test-tag-error?
        (git_object.git-object-decode-tag
          (git_object.GitObjectFormat.Sha1)
          "object 1111111111111111111111111111111111111111\ntype commit\ntag v1\ntagger A\n"
          (& limits))))))

(define (git-object-test-identity-id
  [kind : git_object.GitObjectKind]
  [content : (& content str)]) : git_object.GitObjectId
  (match (git_object.git-object-identity
    (git_object.GitObjectFormat.Sha1)
    kind
    content
    git-object-test-sha1)
    [(git_object.ResultGitObjectId.Ok id) id]
    [(git_object.ResultGitObjectId.Err _)
      (io.panic "git object test: identity failed")]))

(define (git-object-test-outer-tag-body) : String
  "object 8be0a88af0e53a8f5dd93582cd219f080ad8713a\ntype tag\ntag v2\ntagger A <a@b> 0 +0000\n\nouter")

(define (git-object-test-lookup [hex : String]) : git_object.ResultGitObjectRecord
  (cond
    [(string.eq (& hex) "068203eaabc9b581e73a45788cb560137b1937e0")
      (git_object.ResultGitObjectRecord.Ok
        (git_object.GitObjectRecord
          (git-object-test-id
            (git_object.GitObjectFormat.Sha1)
            "068203eaabc9b581e73a45788cb560137b1937e0")
          (git_object.GitObjectKind.Tag)
          (git-object-test-outer-tag-body)))]
    [(string.eq (& hex) "8be0a88af0e53a8f5dd93582cd219f080ad8713a")
      (git_object.ResultGitObjectRecord.Ok
        (git_object.GitObjectRecord
          (git-object-test-id
            (git_object.GitObjectFormat.Sha1)
            "8be0a88af0e53a8f5dd93582cd219f080ad8713a")
          (git_object.GitObjectKind.Tag)
          (git-object-test-tag-body "7f7c16029d5de18ead72216fa7301a8de0e137f1")))]
    [(string.eq (& hex) "7f7c16029d5de18ead72216fa7301a8de0e137f1")
      (git_object.ResultGitObjectRecord.Ok
        (git_object.GitObjectRecord
          (git-object-test-id
            (git_object.GitObjectFormat.Sha1)
            "7f7c16029d5de18ead72216fa7301a8de0e137f1")
          (git_object.GitObjectKind.Commit)
          (git-object-test-commit-body
            "1111111111111111111111111111111111111111")))]
    [else (git_object.ResultGitObjectRecord.Missing)]))

(define (git-object-test-lookup-sha256 [hex : String]) : git_object.ResultGitObjectRecord
  (if (string.eq
    (& hex)
    "3bab679794760a0c4d7d5ba0274fdaf2c4770bba6373c406b4aea81679afa132")
    (git_object.ResultGitObjectRecord.Ok
      (git_object.GitObjectRecord
        (git-object-test-id
          (git_object.GitObjectFormat.Sha256)
          "3bab679794760a0c4d7d5ba0274fdaf2c4770bba6373c406b4aea81679afa132")
        (git_object.GitObjectKind.Commit)
        (git-object-test-commit-body
          "2222222222222222222222222222222222222222222222222222222222222222")))
    (git_object.ResultGitObjectRecord.Missing)))

(define (git-object-test-sha256-resolve?) : bool
  (let
    [refs : (__tl_dyn-array git_object.GitAdvertisedRef)
      (__tl_make-array git_object.GitAdvertisedRef 0)]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (begin
      (match (git_object.git-object-advertised-ref
        (git_object.GitObjectFormat.Sha256)
        "refs/heads/main"
        "3bab679794760a0c4d7d5ba0274fdaf2c4770bba6373c406b4aea81679afa132"
        ""
        "")
        [(git_object.ResultGitAdvertisedRef.Err _) (return false)]
        [(git_object.ResultGitAdvertisedRef.Ok advert)
          (__tl_array-push! refs advert)])
      (match (git_object.git-object-resolve-commit
        (git_object.GitObjectFormat.Sha256)
        (git_object.GitRevSelector.Branch "refs/heads/main")
        (& refs)
        (& limits)
        git-object-test-lookup-sha256
        git-object-test-sha256)
        [(git_object.ResultGitCommitId.Ok id)
          (string.eq
            (& id.hex)
            "3bab679794760a0c4d7d5ba0274fdaf2c4770bba6373c406b4aea81679afa132")]
        [_ false]))))

(define (git-object-test-resolve?) : bool
  (let
    [tree-hex : String "1111111111111111111111111111111111111111"]
    [commit-body : String (git-object-test-commit-body (& tree-hex))]
    [commit-id : git_object.GitObjectId
      (git-object-test-identity-id
        (git_object.GitObjectKind.Commit)
        (& commit-body))]
    [tag-body : String (git-object-test-tag-body (& commit-id.hex))]
    [tag-id : git_object.GitObjectId
      (git-object-test-identity-id (git_object.GitObjectKind.Tag) (& tag-body))]
    [outer-body : String (git-object-test-outer-tag-body)]
    [outer-id : git_object.GitObjectId
      (git-object-test-identity-id
        (git_object.GitObjectKind.Tag)
        (& outer-body))]
    [refs : (__tl_dyn-array git_object.GitAdvertisedRef)
      (__tl_make-array git_object.GitAdvertisedRef 0)]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (begin
      (unless
        (and
          (string.eq
            (& commit-id.hex)
            "7f7c16029d5de18ead72216fa7301a8de0e137f1")
          (string.eq (& tag-id.hex) "8be0a88af0e53a8f5dd93582cd219f080ad8713a")
          (string.eq
            (& outer-id.hex)
            "068203eaabc9b581e73a45788cb560137b1937e0"))
        (return false))
      (match (git_object.git-object-advertised-ref
        (git_object.GitObjectFormat.Sha1)
        "refs/tags/v1"
        (& tag-id.hex)
        ""
        (& commit-id.hex))
        [(git_object.ResultGitAdvertisedRef.Err _)
          (io.panic "git object test: tag advertisement failed")]
        [(git_object.ResultGitAdvertisedRef.Ok advert)
          (__tl_array-push! refs advert)])
      (match (git_object.git-object-advertised-ref
        (git_object.GitObjectFormat.Sha1)
        "refs/tags/v2"
        (& outer-id.hex)
        ""
        (& commit-id.hex))
        [(git_object.ResultGitAdvertisedRef.Err _) (return false)]
        [(git_object.ResultGitAdvertisedRef.Ok advert)
          (__tl_array-push! refs advert)])
      (match (git_object.git-object-advertised-ref
        (git_object.GitObjectFormat.Sha1)
        "refs/tags/light"
        (& commit-id.hex)
        ""
        "")
        [(git_object.ResultGitAdvertisedRef.Err _) (return false)]
        [(git_object.ResultGitAdvertisedRef.Ok advert)
          (__tl_array-push! refs advert)])
      (and
        (match (git_object.git-object-resolve-commit
          (git_object.GitObjectFormat.Sha1)
          (git_object.GitRevSelector.Tag "refs/tags/v2")
          (& refs)
          (& limits)
          git-object-test-lookup
          git-object-test-sha1)
          [(git_object.ResultGitCommitId.Ok id)
            (string.eq (& id.hex) (& commit-id.hex))]
          [_ false])
        (match (git_object.git-object-resolve-commit
          (git_object.GitObjectFormat.Sha1)
          (git_object.GitRevSelector.Tag "refs/tags/light")
          (& refs)
          (& limits)
          git-object-test-lookup
          git-object-test-sha1)
          [(git_object.ResultGitCommitId.Ok id)
            (string.eq (& id.hex) (& commit-id.hex))]
          [_ false])
        (match (git_object.git-object-resolve-commit
          (git_object.GitObjectFormat.Sha1)
          (git_object.GitRevSelector.ExactId
            (string.substring (& commit-id.hex) 0 40))
          (& refs)
          (& limits)
          git-object-test-lookup
          git-object-test-sha1)
          [(git_object.ResultGitCommitId.Ok id)
            (string.eq (& id.hex) (& commit-id.hex))]
          [_ false])
        (match (git_object.git-object-resolve-commit
          (git_object.GitObjectFormat.Sha1)
          (git_object.GitRevSelector.Tag "refs/tags/v1")
          (& refs)
          (& limits)
          git-object-test-lookup
          git-object-test-sha1)
          [(git_object.ResultGitCommitId.Ok id)
            (string.eq (& id.hex) (& commit-id.hex))]
          [_ false])
        (git-object-test-resolve-error?
          (git_object.git-object-resolve-commit
            (git_object.GitObjectFormat.Sha1)
            (git_object.GitRevSelector.ExactId
              "1111111111111111111111111111111111111111")
            (& refs)
            (& limits)
            git-object-test-lookup
            git-object-test-sha1))
        (git-object-test-resolve-error?
          (git_object.git-object-resolve-commit
            (git_object.GitObjectFormat.Sha1)
            (git_object.GitRevSelector.Tag "refs/tags/v1^{commit}")
            (& refs)
            (& limits)
            git-object-test-lookup
            git-object-test-sha1))
        (git-object-test-resolve-error?
          (git_object.git-object-resolve-commit
            (git_object.GitObjectFormat.Sha1)
            (git_object.GitRevSelector.Tag "refs/tags/v1")
            (& refs)
            (& limits)
            (lambda ([_hex : String]) : git_object.ResultGitObjectRecord
              (git_object.ResultGitObjectRecord.Missing))
            git-object-test-sha1))))))

(define (git-object-test-cycle-tag-body [target : String] [kind : String]) : String
  (str_cat.str-cat "object " target "\ntype " kind "\ntag cycle\n\n"))

;; Artificial digest mapping makes a cyclic object graph testable without
;; finding a SHA collision; production callers inject real digest functions.
(define (git-object-test-cycle-digest [preimage : String]) : String
  (cond
    [(string.contains
        (& preimage)
        "object bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
      (git-object-test-id
        (git_object.GitObjectFormat.Sha1)
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").binary]
    [(string.contains
        (& preimage)
        "object aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      (git-object-test-id
        (git_object.GitObjectFormat.Sha1)
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").binary]
    [else ""]))

(define (git-object-test-cycle-lookup [hex : String]) : git_object.ResultGitObjectRecord
  (cond
    [(string.eq (& hex) "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      (git_object.ResultGitObjectRecord.Ok
        (git_object.GitObjectRecord
          (git-object-test-id
            (git_object.GitObjectFormat.Sha1)
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
          (git_object.GitObjectKind.Tag)
          (git-object-test-cycle-tag-body
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            "tag")))]
    [(string.eq (& hex) "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
      (git_object.ResultGitObjectRecord.Ok
        (git_object.GitObjectRecord
          (git-object-test-id
            (git_object.GitObjectFormat.Sha1)
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
          (git_object.GitObjectKind.Tag)
          (git-object-test-cycle-tag-body
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            "tag")))]
    [else (git_object.ResultGitObjectRecord.Missing)]))

(define (git-object-test-mismatch-lookup [hex : String]) : git_object.ResultGitObjectRecord
  (if (string.eq (& hex) "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    (git_object.ResultGitObjectRecord.Ok
      (git_object.GitObjectRecord
        (git-object-test-id
          (git_object.GitObjectFormat.Sha1)
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        (git_object.GitObjectKind.Tag)
        (git-object-test-cycle-tag-body
          "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          "commit")))
    (git-object-test-cycle-lookup hex)))

(define (git-object-test-cycle-and-limits?) : bool
  (let
    [refs : (__tl_dyn-array git_object.GitAdvertisedRef)
      (__tl_make-array git_object.GitAdvertisedRef 0)]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (begin
      (match (git_object.git-object-advertised-ref
        (git_object.GitObjectFormat.Sha1)
        "refs/tags/cycle"
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ""
        "")
        [(git_object.ResultGitAdvertisedRef.Err _) (return false)]
        [(git_object.ResultGitAdvertisedRef.Ok advert)
          (__tl_array-push! refs advert)])
      (let
        [cycle : git_object.ResultGitCommitId
          (git_object.git-object-resolve-commit
            (git_object.GitObjectFormat.Sha1)
            (git_object.GitRevSelector.Tag "refs/tags/cycle")
            (& refs)
            (& limits)
            git-object-test-cycle-lookup
            git-object-test-cycle-digest)]
        [mismatch : git_object.ResultGitCommitId
          (git_object.git-object-resolve-commit
            (git_object.GitObjectFormat.Sha1)
            (git_object.GitRevSelector.Tag "refs/tags/cycle")
            (& refs)
            (& limits)
            git-object-test-mismatch-lookup
            git-object-test-cycle-digest)]
        (begin
          (set! limits.max-peel-depth 0)
          (and
            (git-object-test-resolve-error-is? cycle "git object: tag cycle")
            (git-object-test-resolve-error-is?
              mismatch
              "git object: tag target type mismatch")
            (git-object-test-resolve-error-is?
              (git_object.git-object-resolve-commit
                (git_object.GitObjectFormat.Sha1)
                (git_object.GitRevSelector.Tag "refs/tags/cycle")
                (& refs)
                (& limits)
                git-object-test-cycle-lookup
                git-object-test-cycle-digest)
              "git object: tag depth exceeded")))))))

(define (git-object-test-deterministic-invalid-bytes?) : bool
  (let
    [state : i64 24681357]
    [round : i64 0]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    [ok : bool true]
    (begin
      (while (< round 128)
        (let
          [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
          [index : i64 0]
          (begin
            (while (< index 24)
              (begin
                (set! state (% (+ (* state 1664525) 1013904223) 2147483647))
                (byte_buf.byte-buf-builder-push
                  (&mut out)
                  (cast (bit-and state 255) : u8))
                (set! index (+ index 1))))
            (let
              [sample : String
                (byte_buf.byte-buf-builder-finish-string (& out))]
              (unless
                (and
                  (git-object-test-tree-error?
                    (git_object.git-object-decode-tree
                      (git_object.GitObjectFormat.Sha1)
                      (& sample)
                      (& limits)))
                  (git-object-test-commit-error?
                    (git_object.git-object-decode-commit
                      (git_object.GitObjectFormat.Sha1)
                      (& sample)
                      (& limits)))
                  (git-object-test-tag-error?
                    (git_object.git-object-decode-tag
                      (git_object.GitObjectFormat.Sha1)
                      (& sample)
                      (& limits))))
                (set! ok false)))))
        (set! round (+ round 1)))
      ok)))

(define (git-object-test-boundaries?) : bool
  (let
    [hex : String "1111111111111111111111111111111111111111"]
    [id : git_object.GitObjectId
      (git-object-test-id (git_object.GitObjectFormat.Sha1) (& hex))]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [commit : String (git-object-test-commit-body (& hex))]
    [tag : String (git-object-test-tag-body (& hex))]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (begin
      (git-object-test-append-tree-entry! (&mut out) "100644" "a" (& id.binary))
      (git-object-test-append-tree-entry! (&mut out) "100644" "b" (& id.binary))
      (let
        [tree : String (byte_buf.byte-buf-builder-finish-string (& out))]
        [ok : bool true]
        (begin
          (set! limits.max-object-bytes 1)
          (unless
            (and
              (git-object-test-commit-error?
                (git_object.git-object-decode-commit
                  (git_object.GitObjectFormat.Sha1)
                  (& commit)
                  (& limits)))
              (git-object-test-tree-error?
                (git_object.git-object-decode-tree
                  (git_object.GitObjectFormat.Sha1)
                  (& tree)
                  (& limits)))
              (git-object-test-tag-error?
                (git_object.git-object-decode-tag
                  (git_object.GitObjectFormat.Sha1)
                  (& tag)
                  (& limits))))
            (set! ok false))
          (set! limits.max-object-bytes 4096)
          (set! limits.max-headers 0)
          (unless
            (git-object-test-commit-error?
              (git_object.git-object-decode-commit
                (git_object.GitObjectFormat.Sha1)
                (& commit)
                (& limits)))
            (set! ok false))
          (set! limits.max-headers 32)
          (set! limits.max-tree-entries 1)
          (unless
            (git-object-test-tree-error?
              (git_object.git-object-decode-tree
                (git_object.GitObjectFormat.Sha1)
                (& tree)
                (& limits)))
            (set! ok false))
          (set! limits.max-tree-entries 32)
          (set! limits.max-name-comparisons 0)
          (unless
            (git-object-test-tree-error?
              (git_object.git-object-decode-tree
                (git_object.GitObjectFormat.Sha1)
                (& tree)
                (& limits)))
            (set! ok false))
          (and
            ok
            (git-object-test-commit-error?
              (git_object.git-object-decode-commit
                (git_object.GitObjectFormat.Sha1)
                "tree 1111111111111111111111111111111111111111\nauthor A\ncommitter B\ngpgsig X\n broken"
                (& limits)))
            (git-object-test-commit-error?
              (git_object.git-object-decode-commit
                (git_object.GitObjectFormat.Sha1)
                "tree 1111111111111111111111111111111111111111\nauthor A\n continued\ncommitter B\n\n"
                (& limits)))
            (git-object-test-tag-error?
              (git_object.git-object-decode-tag
                (git_object.GitObjectFormat.Sha1)
                "object 1111111111111111111111111111111111111111\ntype commit\ntag bad..name\n\n"
                (& limits)))
            (git-object-test-tag-error?
              (git_object.git-object-decode-tag
                (git_object.GitObjectFormat.Sha1)
                "object 1111111111111111111111111111111111111111\ntype commit\ntag v1\ntagger A\n continued\n\n"
                (& limits)))))))))

(define (git-object-test-opaque-and-parent-bytes?) : bool
  (let
    [hex : String "1111111111111111111111111111111111111111"]
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-new)]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    (begin
      (byte_buf.byte-buf-builder-append-string
        (&mut out)
        (str_cat.str-cat
          "tree "
          (string.substring (& hex) 0 40)
          "\nparent "
          (string.substring (& hex) 0 40)
          "\nparent "
          (string.substring (& hex) 0 40)
          "\nauthor A\ncommitter B\n\n"))
      (byte_buf.byte-buf-builder-push (&mut out) (cast 0 : u8))
      (byte_buf.byte-buf-builder-push (&mut out) (cast 255 : u8))
      (byte_buf.byte-buf-builder-push (&mut out) (cast 10 : u8))
      (let
        [bytes : String (byte_buf.byte-buf-builder-finish-string (& out))]
        (match (git_object.git-object-decode-commit
          (git_object.GitObjectFormat.Sha1)
          (& bytes)
          (& limits))
          [(git_object.ResultGitCommit.Ok commit)
            (and
              (= (array-length commit.parents) 2)
              (string.eq (& (array-ref commit.parents 0).hex) (& hex))
              (string.eq (& (array-ref commit.parents 1).hex) (& hex))
              (= (string.string-length (& commit.message)) 3)
              (= (git_object.git-object-byte (& commit.message) 0) 0)
              (= (git_object.git-object-byte (& commit.message) 1) 255)
              (= (git_object.git-object-byte (& commit.message) 2) 10))]
          [_ false])))))

(define (git-object-test-header-prefixes?) : bool
  (let
    [hex : String "1111111111111111111111111111111111111111"]
    [commit : String (git-object-test-commit-body (& hex))]
    [tag : String (git-object-test-tag-body (& hex))]
    [limits : git_object.GitObjectLimits (git-object-test-limits)]
    [index : i64 1]
    [ok : bool true]
    (begin
      (while (< index (- (string.string-length (& commit)) 7))
        (begin
          (unless
            (git-object-test-commit-error?
              (git_object.git-object-decode-commit
                (git_object.GitObjectFormat.Sha1)
                (string.substring (& commit) 0 index)
                (& limits)))
            (set! ok false))
          (set! index (+ index 1))))
      (set! index 1)
      (while (< index (- (string.string-length (& tag)) 7))
        (begin
          (unless
            (git-object-test-tag-error?
              (git_object.git-object-decode-tag
                (git_object.GitObjectFormat.Sha1)
                (string.substring (& tag) 0 index)
                (& limits)))
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

(define (git-object-self-test) : i64
  (begin
    (git-object-test-require
      (git-object-test-ids-and-preimages?)
      "git object: ID/preimage fixture mismatch")
    (git-object-test-require
      (git-object-test-refs?)
      "git object: ref fixture mismatch")
    (git-object-test-require
      (git-object-test-commit?)
      "git object: commit fixture mismatch")
    (git-object-test-require
      (git-object-test-tree?)
      "git object: tree fixture mismatch")
    (git-object-test-require
      (git-object-test-tag?)
      "git object: tag fixture mismatch")
    (git-object-test-require
      (git-object-test-resolve?)
      "git object: resolution fixture mismatch")
    (git-object-test-require
      (git-object-test-sha256-resolve?)
      "git object: SHA-256 resolution fixture mismatch")
    (git-object-test-require
      (git-object-test-cycle-and-limits?)
      "git object: peel bounds fixture mismatch")
    (git-object-test-require
      (git-object-test-boundaries?)
      "git object: decoder bounds fixture mismatch")
    (git-object-test-require
      (git-object-test-opaque-and-parent-bytes?)
      "git object: parent/message byte fixture mismatch")
    (git-object-test-require
      (git-object-test-header-prefixes?)
      "git object: header truncation fixture mismatch")
    (git-object-test-require
      (git-object-test-deterministic-invalid-bytes?)
      "git object: deterministic malformed corpus mismatch")
    42))

(test
  git-object-identities
  (git-object-test-require
    (git-object-test-ids-and-preimages?)
    "git object: ID/preimage fixture mismatch"))

(test
  git-object-decoding
  (git-object-test-require
    (and
      (git-object-test-commit?)
      (git-object-test-tree?)
      (git-object-test-tag?))
    "git object: decode fixture mismatch"))

(test
  git-object-refs-and-resolution
  (git-object-test-require
    (and
      (git-object-test-refs?)
      (git-object-test-resolve?)
      (git-object-test-sha256-resolve?)
      (git-object-test-cycle-and-limits?))
    "git object: ref/resolution fixture mismatch"))

(test
  git-object-bounds
  (git-object-test-require
    (and
      (git-object-test-boundaries?)
      (git-object-test-opaque-and-parent-bytes?)
      (git-object-test-header-prefixes?))
    "git object: decoder bounds fixture mismatch"))

(test
  git-object-deterministic-invalid-corpus
  (git-object-test-require
    (git-object-test-deterministic-invalid-bytes?)
    "git object: deterministic malformed corpus mismatch"))