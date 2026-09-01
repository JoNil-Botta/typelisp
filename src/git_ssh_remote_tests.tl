;; Valid, malformed, and adversarial fixtures for git_ssh_remote_core.
(import git_ssh_remote_core as git_ssh)
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (git-ssh-test-string=? [left : (& left str)] [right : (& right str)]) : bool
  (let
    [left-length : i64 (string.string-length left)]
    [right-length : i64 (string.string-length right)]
    [index : i64 0]
    [same : bool (= left-length right-length)]
    (begin
      (while (and same (< index left-length))
        (begin
          (if (= (string.string-ref left index) (string.string-ref right index))
            unit
            (set! same false))
          (set! index (+ index 1))))
      same)))

(define (git-ssh-test-syntax-code
  [syntax : (& syntax git_ssh.GitSshRemoteSyntax)]) : i64
  (match syntax
    [(git_ssh.GitSshRemoteSyntax.Uri) 1]
    [(git_ssh.GitSshRemoteSyntax.Scp) 2]
    [_ 0]))

(define (git-ssh-test-host-kind-code [kind : (& kind git_ssh.GitSshHostKind)]) : i64
  (match kind
    [(git_ssh.GitSshHostKind.Name) 1]
    [(git_ssh.GitSshHostKind.Ipv6Literal) 2]
    [_ 0]))

(define (git-ssh-test-path-kind-code [kind : (& kind git_ssh.GitSshPathKind)]) : i64
  (match kind
    [(git_ssh.GitSshPathKind.Absolute) 1]
    [(git_ssh.GitSshPathKind.Relative) 2]
    [(git_ssh.GitSshPathKind.Tilde) 3]
    [_ 0]))

(define (git-ssh-test-error-code [error : (& error git_ssh.GitSshRemoteError)]) : i64
  (match error
    [(git_ssh.GitSshRemoteError.UnsupportedSyntax) 1]
    [(git_ssh.GitSshRemoteError.AmbiguousSyntax) 2]
    [(git_ssh.GitSshRemoteError.ControlByte) 3]
    [(git_ssh.GitSshRemoteError.PasswordUserinfo) 4]
    [(git_ssh.GitSshRemoteError.InvalidUser) 5]
    [(git_ssh.GitSshRemoteError.EmptyHost) 6]
    [(git_ssh.GitSshRemoteError.InvalidHost) 7]
    [(git_ssh.GitSshRemoteError.InvalidIpv6Literal) 8]
    [(git_ssh.GitSshRemoteError.InvalidPort) 9]
    [(git_ssh.GitSshRemoteError.EmptyPath) 10]
    [(git_ssh.GitSshRemoteError.UnsafePercentEncoding) 11]
    [(git_ssh.GitSshRemoteError.LeadingDashPath) 12]
    [(git_ssh.GitSshRemoteError.InvalidStructuredRemote) 13]
    [_ 0]))

(define (git-ssh-test-command-prefix? [command : (& command str)]) : bool
  (let
    [prefix : String "git-upload-pack "]
    [prefix-length : i64 (string.string-length (& prefix))]
    [index : i64 0]
    [same : bool (>= (string.string-length command) (+ prefix-length 2))]
    (begin
      (while (and same (< index prefix-length))
        (begin
          (if (=
            (string.string-ref command index)
            (string.string-ref (& prefix) index))
            unit
            (set! same false))
          (set! index (+ index 1))))
      same)))

;; Decode the deliberately tiny grammar emitted by git-ssh-upload-pack-command:
;; one fixed service name, one space, then one Git sq-quoted repository path.
;; This verifies that hostile bytes cannot become a second token or command.
(define (git-ssh-test-command-decodes-to?
  [command : (& command str)]
  [expected : (& expected str)]) : bool
  (let
    [length : i64 (string.string-length command)]
    [expected-length : i64 (string.string-length expected)]
    [index : i64 17]
    [expected-index : i64 0]
    [valid : bool
      (and
        (git-ssh-test-command-prefix? command)
        (= (cast (string.string-ref command 16) : i64) 39)
        (= (cast (string.string-ref command (- length 1)) : i64) 39))]
    (begin
      (while (and valid (< index (- length 1)))
        (let
          [code : i64 (cast (string.string-ref command index) : i64)]
          (begin
            (if (= code 39)
              (if (and
                (< (+ index 3) length)
                (= (cast (string.string-ref command (+ index 1)) : i64) 92)
                (or
                  (= (cast (string.string-ref command (+ index 2)) : i64) 39)
                  (= (cast (string.string-ref command (+ index 2)) : i64) 33))
                (= (cast (string.string-ref command (+ index 3)) : i64) 39))
                (begin
                  (set!
                    code
                    (cast (string.string-ref command (+ index 2)) : i64))
                  (set! index (+ index 4)))
                (set! valid false))
              (set! index (+ index 1)))
            (if (and valid (< expected-index expected-length))
              (if (=
                code
                (cast (string.string-ref expected expected-index) : i64))
                (set! expected-index (+ expected-index 1))
                (set! valid false))
              (set! valid false)))))
      (and valid (= index (- length 1)) (= expected-index expected-length)))))

(define (git-ssh-test-remote-fixture?
  [input : (& input str)]
  [syntax-code : i64]
  [user : (& user str)]
  [host : (& host str)]
  [host-kind-code : i64]
  [port : i64]
  [path : (& path str)]
  [path-kind-code : i64]) : bool
  (match (git_ssh.git-ssh-remote-parse input)
    [(git_ssh.ResultGitSshRemote.Err _) false]
    [(git_ssh.ResultGitSshRemote.Ok remote)
      (and
        (= (git-ssh-test-syntax-code (& remote.syntax)) syntax-code)
        (= remote.endpoint.has-user (> (string.string-length user) 0))
        (git-ssh-test-string=? (& remote.endpoint.user) user)
        (git-ssh-test-string=? (& remote.endpoint.host) host)
        (=
          (git-ssh-test-host-kind-code (& remote.endpoint.host-kind))
          host-kind-code)
        (= remote.endpoint.port port)
        (git-ssh-test-string=? (& remote.path) path)
        (= (git-ssh-test-path-kind-code (& remote.path-kind)) path-kind-code)
        (match (git_ssh.git-ssh-upload-pack-command (& remote))
          [(git_ssh.ResultGitSshCommand.Err _) false]
          [(git_ssh.ResultGitSshCommand.Ok command)
            (git-ssh-test-command-decodes-to? (& command) path)]))]))

(define (git-ssh-test-parse-error? [input : (& input str)]) : bool
  (match (git_ssh.git-ssh-remote-parse input)
    [(git_ssh.ResultGitSshRemote.Err _) true]
    [(git_ssh.ResultGitSshRemote.Ok _) false]))

(define (git-ssh-test-parse-error-is?
  [input : (& input str)]
  [expected-code : i64]) : bool
  (match (git_ssh.git-ssh-remote-parse input)
    [(git_ssh.ResultGitSshRemote.Err error)
      (= (git-ssh-test-error-code (& error)) expected-code)]
    [(git_ssh.ResultGitSshRemote.Ok _) false]))

(define (git-ssh-test-valid-remotes?) : bool
  (and
    (git-ssh-test-remote-fixture?
      "SSH://Alice@EXAMPLE.COM/project.git"
      1
      "Alice"
      "example.com"
      1
      22
      "/project.git"
      1)
    (git-ssh-test-remote-fixture?
      "ssh://git@example.com:2222/team/repo.git"
      1
      "git"
      "example.com"
      1
      2222
      "/team/repo.git"
      1)
    (git-ssh-test-remote-fixture?
      "ssh://git@[2001:DB8::1]:2200/repo.git"
      1
      "git"
      "2001:db8::1"
      2
      2200
      "/repo.git"
      1)
    (git-ssh-test-remote-fixture?
      "Git@EXAMPLE.COM:team/repo.git"
      2
      "Git"
      "example.com"
      1
      22
      "team/repo.git"
      2)
    (git-ssh-test-remote-fixture?
      "git@[2001:DB8::1]:team/repo.git"
      2
      "git"
      "2001:db8::1"
      2
      22
      "team/repo.git"
      2)
    (git-ssh-test-remote-fixture?
      "host:/srv/repo.git"
      2
      ""
      "host"
      1
      22
      "/srv/repo.git"
      1)
    (git-ssh-test-remote-fixture?
      "ssh://host/~alice/repo.git"
      1
      ""
      "host"
      1
      22
      "~alice/repo.git"
      3)
    (git-ssh-test-remote-fixture?
      "host:~alice/repo.git"
      2
      ""
      "host"
      1
      22
      "~alice/repo.git"
      3)
    (git-ssh-test-remote-fixture?
      "ssh://host/repo%20a%27b%21c%23d%25.git"
      1
      ""
      "host"
      1
      22
      "/repo a'b!c#d%.git"
      1)
    (git-ssh-test-remote-fixture?
      "host:repo%2Fstill-literal"
      2
      ""
      "host"
      1
      22
      "repo%2Fstill-literal"
      2)
    (git-ssh-test-remote-fixture?
      "host:repo:with:colons"
      2
      ""
      "host"
      1
      22
      "repo:with:colons"
      2)
    (git-ssh-test-remote-fixture?
      "git@[2001:db8::1]:repo:with:colons"
      2
      "git"
      "2001:db8::1"
      2
      22
      "repo:with:colons"
      2)))

(define (git-ssh-test-invalid-authorities?) : bool
  (and
    (git-ssh-test-parse-error-is? "ssh://user:password@host/repo" 4)
    (git-ssh-test-parse-error-is? "ssh://user%3Apassword@host/repo" 4)
    (git-ssh-test-parse-error-is? "user%3apassword@host:repo" 4)
    (git-ssh-test-parse-error? "ssh://a@b@host/repo")
    (git-ssh-test-parse-error? "ssh://@host/repo")
    (git-ssh-test-parse-error? "ssh:///repo")
    (git-ssh-test-parse-error? "ssh://host:/repo")
    (git-ssh-test-parse-error? "ssh://host:0/repo")
    (git-ssh-test-parse-error? "ssh://host:65536/repo")
    (git-ssh-test-parse-error? "ssh://host:no/repo")
    (git-ssh-test-parse-error? "ssh://2001:db8::1/repo")
    (git-ssh-test-parse-error? "ssh://[2001:db8:::1]/repo")
    (git-ssh-test-parse-error? "ssh://[1::2::3]/repo")
    (git-ssh-test-parse-error? "ssh://[::ffff:192.0.2.1]/repo")
    (git-ssh-test-parse-error? "ssh://[fe80::1%25eth0]/repo")
    (git-ssh-test-parse-error? "ssh://höst/repo")
    (git-ssh-test-parse-error? "ssh://-host/repo")
    (git-ssh-test-parse-error? "ssh://host-/repo")))

(define (git-ssh-test-invalid-paths-and-syntax?) : bool
  (and
    (git-ssh-test-parse-error-is? "host:-strict" 12)
    (git-ssh-test-parse-error? "host:")
    (git-ssh-test-parse-error? "ssh://host")
    (git-ssh-test-parse-error? "ssh://host/%")
    (git-ssh-test-parse-error? "ssh://host/%ZZ")
    (git-ssh-test-parse-error? "ssh://host/%00")
    (git-ssh-test-parse-error? "ssh://host/%0A")
    (git-ssh-test-parse-error? "ssh://host/%2F")
    (git-ssh-test-parse-error? "ssh://host/%5C")
    (git-ssh-test-parse-error? "ssh://host/repo?query")
    (git-ssh-test-parse-error? "ssh://host/repo#fragment")
    (git-ssh-test-parse-error? "ssh://host/repo\\path")
    (git-ssh-test-parse-error? "ssh://host/repo\nnext")
    (git-ssh-test-parse-error? "host:repo\tnext")
    (git-ssh-test-parse-error? "file://host/repo")
    (git-ssh-test-parse-error? "https://host/repo")
    (git-ssh-test-parse-error? "/local/repo")
    (git-ssh-test-parse-error? "host")
    (git-ssh-test-parse-error? "2001:db8::1/repo")
    (git-ssh-test-parse-error? "git@2001:db8::1/repo")
    (git-ssh-test-parse-error? "C:repo")
    (git-ssh-test-parse-error? "c:\\repo")))

(define (git-ssh-test-structured-remote [path : String]) : git_ssh.GitSshRemote
  (git_ssh.GitSshRemote
    (git_ssh.GitSshRemoteSyntax.Scp)
    (git_ssh.GitSshEndpoint
      false
      ""
      "example.com"
      (git_ssh.GitSshHostKind.Name)
      22)
    path
    (git_ssh.GitSshPathKind.Relative)))

(define (git-ssh-test-command-roundtrip? [path : (& path str)]) : bool
  (let
    [expected : String (string.copy path)]
    [remote : git_ssh.GitSshRemote
      (git-ssh-test-structured-remote (string.copy path))]
    (match (git_ssh.git-ssh-upload-pack-command (& remote))
      [(git_ssh.ResultGitSshCommand.Err _) false]
      [(git_ssh.ResultGitSshCommand.Ok command)
        (git-ssh-test-command-decodes-to? (& command) (& expected))])))

(define (git-ssh-test-path-with-byte [code : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-with-capacity 6)]
    (begin
      (byte_buf.byte-buf-builder-append-string (&mut out) "repo/")
      (byte_buf.byte-buf-builder-push (&mut out) (cast code : u8))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-ssh-test-all-non-control-bytes?) : bool
  (let
    [code : i64 32]
    [valid : bool true]
    (begin
      (while (and valid (<= code 255))
        (begin
          (if (= code 127)
            unit
            (let
              [path : String (git-ssh-test-path-with-byte code)]
              (if (git-ssh-test-command-roundtrip? (& path))
                unit
                (set! valid false))))
          (set! code (+ code 1))))
      valid)))

(define (git-ssh-test-control-bytes-rejected?) : bool
  (let
    [code : i64 0]
    [valid : bool true]
    (begin
      (while (and valid (< code 32))
        (let
          [path : String (git-ssh-test-path-with-byte code)]
          [remote : git_ssh.GitSshRemote (git-ssh-test-structured-remote path)]
          (begin
            (match (git_ssh.git-ssh-upload-pack-command (& remote))
              [(git_ssh.ResultGitSshCommand.Err error)
                (if (= (git-ssh-test-error-code (& error)) 3)
                  unit
                  (set! valid false))]
              [(git_ssh.ResultGitSshCommand.Ok _) (set! valid false)])
            (set! code (+ code 1)))))
      (let
        [path : String (git-ssh-test-path-with-byte 127)]
        [remote : git_ssh.GitSshRemote (git-ssh-test-structured-remote path)]
        (and
          valid
          (match (git_ssh.git-ssh-upload-pack-command (& remote))
            [(git_ssh.ResultGitSshCommand.Err error)
              (= (git-ssh-test-error-code (& error)) 3)]
            [(git_ssh.ResultGitSshCommand.Ok _) false]))))))

(define (git-ssh-test-injection-corpus?) : bool
  (and
    (git-ssh-test-command-roundtrip? "repo/a b")
    (git-ssh-test-command-roundtrip? "repo/a'b")
    (git-ssh-test-command-roundtrip? "repo/a!b")
    (git-ssh-test-command-roundtrip? "repo/a\\b")
    (git-ssh-test-command-roundtrip? "repo/$HOME")
    (git-ssh-test-command-roundtrip? "repo/`id`")
    (git-ssh-test-command-roundtrip? "repo/$(id)")
    (git-ssh-test-command-roundtrip? "repo/a;b")
    (git-ssh-test-command-roundtrip? "repo/a|b")
    (git-ssh-test-command-roundtrip? "repo/a&b")
    (git-ssh-test-command-roundtrip? "repo/(a)")
    (git-ssh-test-command-roundtrip? "repo/a>b")
    (git-ssh-test-command-roundtrip? "repo/a<b")
    (git-ssh-test-command-roundtrip? "repo/*")
    (git-ssh-test-command-roundtrip? "repo/?")
    (git-ssh-test-command-roundtrip? "repo/A=B")))

(define (git-ssh-test-structured-rejections?) : bool
  (let
    [leading : git_ssh.GitSshRemote (git-ssh-test-structured-remote "-strict")]
    [bad-port : git_ssh.GitSshRemote
      (git_ssh.GitSshRemote
        (git_ssh.GitSshRemoteSyntax.Scp)
        (git_ssh.GitSshEndpoint
          false
          ""
          "example.com"
          (git_ssh.GitSshHostKind.Name)
          23)
        "repo"
        (git_ssh.GitSshPathKind.Relative))]
    [bad-host : git_ssh.GitSshRemote
      (git_ssh.GitSshRemote
        (git_ssh.GitSshRemoteSyntax.Uri)
        (git_ssh.GitSshEndpoint
          false
          ""
          "EXAMPLE.com"
          (git_ssh.GitSshHostKind.Name)
          22)
        "/repo"
        (git_ssh.GitSshPathKind.Absolute))]
    (and
      (match (git_ssh.git-ssh-upload-pack-command (& leading))
        [(git_ssh.ResultGitSshCommand.Err error)
          (= (git-ssh-test-error-code (& error)) 12)]
        [(git_ssh.ResultGitSshCommand.Ok _) false])
      (match (git_ssh.git-ssh-upload-pack-command (& bad-port))
        [(git_ssh.ResultGitSshCommand.Err error)
          (= (git-ssh-test-error-code (& error)) 13)]
        [(git_ssh.ResultGitSshCommand.Ok _) false])
      (match (git_ssh.git-ssh-upload-pack-command (& bad-host))
        [(git_ssh.ResultGitSshCommand.Err error)
          (= (git-ssh-test-error-code (& error)) 13)]
        [(git_ssh.ResultGitSshCommand.Ok _) false]))))

(define (git-ssh-test-request-and-diagnostics?) : bool
  (and
    (match (git_ssh.git-ssh-upload-pack-request "git@EXAMPLE.COM:team/repo.git")
      [(git_ssh.ResultGitSshUploadPackRequest.Err _) false]
      [(git_ssh.ResultGitSshUploadPackRequest.Ok request)
        (let
          [summary : String (git_ssh.git-ssh-remote-summary (& request.remote))]
          (and
            (git-ssh-test-string=?
              (& request.remote.endpoint.host)
              "example.com")
            (git-ssh-test-command-decodes-to?
              (& request.command)
              "team/repo.git")
            (git-ssh-test-string=?
              (& summary)
              "ssh{syntax=scp,user=git,host=example.com,host-kind=name,port=22,path-kind=relative,path=team/repo.git}")))])
    (match (git_ssh.git-ssh-remote-parse "ssh://user:secret@host/repo")
      [(git_ssh.ResultGitSshRemote.Ok _) false]
      [(git_ssh.ResultGitSshRemote.Err error)
        (let
          [message : String (git_ssh.git-ssh-remote-error-message error)]
          (git-ssh-test-string=?
            (& message)
            "git ssh remote: password-bearing userinfo is forbidden"))])))

(define (git-ssh-remote-self-test-ok?) : bool
  (and
    (git-ssh-test-valid-remotes?)
    (git-ssh-test-invalid-authorities?)
    (git-ssh-test-invalid-paths-and-syntax?)
    (git-ssh-test-all-non-control-bytes?)
    (git-ssh-test-control-bytes-rejected?)
    (git-ssh-test-injection-corpus?)
    (git-ssh-test-structured-rejections?)
    (git-ssh-test-request-and-diagnostics?)))

(define (git-ssh-remote-self-test) : i64
  (if (git-ssh-remote-self-test-ok?)
    42
    (io.panic "git ssh remote: self-test mismatch")))

(define (git-ssh-test-require [ok : bool] [message : String]) : unit
  (if ok
    unit
    (io.panic message)))

(test
  git-ssh-remote-valid-and-normalized
  (git-ssh-test-require
    (git-ssh-test-valid-remotes?)
    "git ssh remote: valid fixture mismatch"))

(test
  git-ssh-remote-rejections
  (git-ssh-test-require
    (and
      (git-ssh-test-invalid-authorities?)
      (git-ssh-test-invalid-paths-and-syntax?)
      (git-ssh-test-structured-rejections?))
    "git ssh remote: malformed fixture mismatch"))

(test
  git-ssh-upload-pack-command-safety
  (git-ssh-test-require
    (and
      (git-ssh-test-all-non-control-bytes?)
      (git-ssh-test-control-bytes-rejected?)
      (git-ssh-test-injection-corpus?))
    "git ssh remote: command framing mismatch"))

(test
  git-ssh-upload-pack-handoff-and-diagnostics
  (git-ssh-test-require
    (git-ssh-test-request-and-diagnostics?)
    "git ssh remote: request/diagnostic mismatch"))