;; git_ssh_remote_core.tl - Pure Git-over-SSH remote/service boundary.
;;
;; This module parses only the SSH remote forms used by native Git fetching and
;; constructs exactly one `git-upload-pack` remote-exec command. It performs no
;; DNS, socket, SSH, Git protocol, process, credential, or cache operation.
;; Rejected input is represented by payload-free error variants so a password
;; or raw URI authority can never survive in a diagnostic value.
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.string)

(defenum GitSshRemoteSyntax
  (Uri)
  (Scp))

(defenum GitSshHostKind
  (Name)
  (Ipv6Literal))

(defenum GitSshPathKind
  (Absolute)
  (Relative)
  (Tilde))

(defstruct GitSshEndpoint
  (has-user bool)
  (user String)
  (host String)
  (host-kind GitSshHostKind)
  (port i64))

(defstruct GitSshRemote
  (syntax GitSshRemoteSyntax)
  (endpoint GitSshEndpoint)
  (path String)
  (path-kind GitSshPathKind))

(defstruct GitSshUploadPackRequest
  (remote GitSshRemote)
  ;; Opaque bytes for one SSH `exec` request. Downstream code must not parse,
  ;; quote, prefix, or otherwise reconstruct this command.
  (command String))

(defenum GitSshRemoteError
  (UnsupportedSyntax)
  (AmbiguousSyntax)
  (ControlByte)
  (PasswordUserinfo)
  (InvalidUser)
  (EmptyHost)
  (InvalidHost)
  (InvalidIpv6Literal)
  (InvalidPort)
  (EmptyPath)
  (UnsafePercentEncoding)
  (LeadingDashPath)
  (InvalidStructuredRemote))

(defenum ResultGitSshEndpoint
  (Ok GitSshEndpoint)
  (Err GitSshRemoteError))

(defenum ResultGitSshPath
  (Ok String GitSshPathKind)
  (Err GitSshRemoteError))

(defenum ResultGitSshPort
  (Ok i64)
  (Err GitSshRemoteError))

(defenum ResultGitSshRemote
  (Ok GitSshRemote)
  (Err GitSshRemoteError))

(defenum ResultGitSshCommand
  (Ok String)
  (Err GitSshRemoteError))

(defenum ResultGitSshUploadPackRequest
  (Ok GitSshUploadPackRequest)
  (Err GitSshRemoteError))

;: Stable credential-free diagnostic for a parse/encoding rejection.
(define (git-ssh-remote-error-message [error : GitSshRemoteError]) : String
  (match error
    [(GitSshRemoteError.UnsupportedSyntax) "git ssh remote: unsupported syntax"]
    [(GitSshRemoteError.AmbiguousSyntax)
      "git ssh remote: ambiguous URI or scp-like syntax"]
    [(GitSshRemoteError.ControlByte)
      "git ssh remote: control byte is forbidden"]
    [(GitSshRemoteError.PasswordUserinfo)
      "git ssh remote: password-bearing userinfo is forbidden"]
    [(GitSshRemoteError.InvalidUser) "git ssh remote: invalid SSH user"]
    [(GitSshRemoteError.EmptyHost) "git ssh remote: host is empty"]
    [(GitSshRemoteError.InvalidHost)
      "git ssh remote: host must be a deterministic ASCII name or bracketed IPv6 literal"]
    [(GitSshRemoteError.InvalidIpv6Literal)
      "git ssh remote: invalid bracketed IPv6 literal"]
    [(GitSshRemoteError.InvalidPort)
      "git ssh remote: port must be an integer from 1 through 65535"]
    [(GitSshRemoteError.EmptyPath) "git ssh remote: repository path is empty"]
    [(GitSshRemoteError.UnsafePercentEncoding)
      "git ssh remote: unsafe percent encoding"]
    [(GitSshRemoteError.LeadingDashPath)
      "git ssh remote: relative repository path must not begin with '-'"]
    [(GitSshRemoteError.InvalidStructuredRemote)
      "git ssh remote: inconsistent structured remote"]
    [_ "git ssh remote: unknown rejection"]))

(define (git-ssh-byte [text : (& text str)] [index : i64]) : i64
  (cast (string.string-ref text index) : i64))

(define (git-ssh-builder-push!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf.byte-buf-builder-push out (cast value : u8)))

(define (git-ssh-builder-append!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (while (< index length)
      (begin
        (git-ssh-builder-push! out (git-ssh-byte text index))
        (set! index (+ index 1))))))

(define (git-ssh-ascii-alpha? [code : i64]) : bool
  (or (and (>= code 65) (<= code 90)) (and (>= code 97) (<= code 122))))

(define (git-ssh-ascii-digit? [code : i64]) : bool
  (and (>= code 48) (<= code 57)))

(define (git-ssh-ascii-alnum? [code : i64]) : bool
  (or (git-ssh-ascii-alpha? code) (git-ssh-ascii-digit? code)))

(define (git-ssh-ascii-hex-value [code : i64]) : i64
  (cond
    [(and (>= code 48) (<= code 57)) (- code 48)]
    [(and (>= code 65) (<= code 70)) (+ (- code 65) 10)]
    [(and (>= code 97) (<= code 102)) (+ (- code 97) 10)]
    [else -1]))

(define (git-ssh-ascii-lower [code : i64]) : i64
  (if (and (>= code 65) (<= code 90))
    (+ code 32)
    code))

(define (git-ssh-control-code? [code : i64]) : bool
  (or (< code 32) (= code 127)))

(define (git-ssh-has-control? [text : (& text str)]) : bool
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    [found : bool false]
    (begin
      (while (and (not found) (< index length))
        (begin
          (if (git-ssh-control-code? (git-ssh-byte text index))
            (set! found true)
            unit)
          (set! index (+ index 1))))
      found)))

(define (git-ssh-find-byte [text : (& text str)] [start : i64] [wanted : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length text)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index length))
        (begin
          (if (= (git-ssh-byte text index) wanted)
            (set! found index)
            unit)
          (set! index (+ index 1))))
      found)))

(define (git-ssh-count-byte [text : (& text str)] [wanted : i64]) : i64
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    [count : i64 0]
    (begin
      (while (< index length)
        (begin
          (if (= (git-ssh-byte text index) wanted)
            (set! count (+ count 1))
            unit)
          (set! index (+ index 1))))
      count)))

(define (git-ssh-has-scheme-separator? [text : (& text str)]) : bool
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    [found : bool false]
    (begin
      (while (and (not found) (< (+ index 2) length))
        (begin
          (if (and
            (= (git-ssh-byte text index) 58)
            (= (git-ssh-byte text (+ index 1)) 47)
            (= (git-ssh-byte text (+ index 2)) 47))
            (set! found true)
            unit)
          (set! index (+ index 1))))
      found)))

(define (git-ssh-uri-prefix? [text : (& text str)]) : bool
  (and
    (>= (string.string-length text) 6)
    (= (git-ssh-ascii-lower (git-ssh-byte text 0)) 115)
    (= (git-ssh-ascii-lower (git-ssh-byte text 1)) 115)
    (= (git-ssh-ascii-lower (git-ssh-byte text 2)) 104)
    (= (git-ssh-byte text 3) 58)
    (= (git-ssh-byte text 4) 47)
    (= (git-ssh-byte text 5) 47)))

(define (git-ssh-normalize-ascii [text : (& text str)]) : String
  (let
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity (string.string-length text))]
    [index : i64 0]
    [length : i64 (string.string-length text)]
    (begin
      (while (< index length)
        (begin
          (git-ssh-builder-push!
            (&mut out)
            (git-ssh-ascii-lower (git-ssh-byte text index)))
          (set! index (+ index 1))))
      (byte_buf.byte-buf-builder-finish-string (& out)))))

(define (git-ssh-user-valid? [user : (& user str)]) : bool
  (let
    [index : i64 0]
    [length : i64 (string.string-length user)]
    [valid : bool (> length 0)]
    (begin
      (while (and valid (< index length))
        (let
          [code : i64 (git-ssh-byte user index)]
          (begin
            (if (or
              (git-ssh-ascii-alnum? code)
              (= code 45)
              (= code 46)
              (= code 95)
              (= code 43))
              unit
              (set! valid false))
            (set! index (+ index 1)))))
      valid)))

(define (git-ssh-userinfo-password-marker? [userinfo : (& userinfo str)]) : bool
  (let
    [index : i64 0]
    [length : i64 (string.string-length userinfo)]
    [found : bool false]
    (begin
      (while (and (not found) (< index length))
        (let
          [code : i64 (git-ssh-byte userinfo index)]
          (cond
            [(= code 58) (set! found true)]
            [(and (= code 37) (< (+ index 2) length))
              (let
                [hi : i64
                  (git-ssh-ascii-hex-value (git-ssh-byte userinfo (+ index 1)))]
                [lo : i64
                  (git-ssh-ascii-hex-value (git-ssh-byte userinfo (+ index 2)))]
                (if (and (>= hi 0) (>= lo 0) (= (+ (* hi 16) lo) 58))
                  (set! found true)
                  unit))]
            [else unit])
          (set! index (+ index 1))))
      found)))

(define (git-ssh-host-name-valid? [host : (& host str)]) : bool
  (let
    [index : i64 0]
    [length : i64 (string.string-length host)]
    [previous : i64 -1]
    [valid : bool (> length 0)]
    (begin
      (while (and valid (< index length))
        (let
          [code : i64 (git-ssh-byte host index)]
          (begin
            (cond
              [(git-ssh-ascii-alnum? code) unit]
              [(= code 95) unit]
              [(= code 45)
                (if (or (= index 0) (= previous 46))
                  (set! valid false)
                  unit)]
              [(= code 46)
                (if (or (= index 0) (= previous 46) (= previous 45))
                  (set! valid false)
                  unit)]
              [else (set! valid false)])
            (set! previous code)
            (set! index (+ index 1)))))
      (and valid (!= previous 46) (!= previous 45)))))

;; Pure hexadecimal IPv6 validation. Dotted IPv4 tails and zone identifiers
;; are intentionally unsupported in this first boundary; callers can use the
;; equivalent hexadecimal form. Compression (`::`) is accepted exactly once.
(define (git-ssh-ipv6-valid? [host : (& host str)]) : bool
  (let
    [length : i64 (string.string-length host)]
    [index : i64 0]
    [groups : i64 0]
    [compressed : bool false]
    [valid : bool (> length 0)]
    (begin
      (if (and valid (= (git-ssh-byte host 0) 58))
        (if (and (> length 1) (= (git-ssh-byte host 1) 58))
          (begin
            (set! compressed true)
            (set! index 2))
          (set! valid false))
        unit)
      (while (and valid (< index length))
        (let
          [group-start : i64 index]
          [digits : i64 0]
          (begin
            (while (and
              (< index length)
              (!= (git-ssh-byte host index) 58)
              (< digits 5))
              (begin
                (if (< (git-ssh-ascii-hex-value (git-ssh-byte host index)) 0)
                  (set! valid false)
                  unit)
                (set! digits (+ digits 1))
                (set! index (+ index 1))))
            (if (or (not valid) (= digits 0) (> digits 4) (= group-start index))
              (set! valid false)
              (set! groups (+ groups 1)))
            (if (and valid (< index length))
              (if (and
                (< (+ index 1) length)
                (= (git-ssh-byte host (+ index 1)) 58))
                (if compressed
                  (set! valid false)
                  (begin
                    (set! compressed true)
                    (set! index (+ index 2))))
                (begin
                  (set! index (+ index 1))
                  (if (= index length)
                    (set! valid false)
                    unit)))
              unit))))
      (and
        valid
        (if compressed
          (< groups 8)
          (= groups 8))))))

(define (git-ssh-port-parse [text : (& text str)]) : ResultGitSshPort
  (let
    [index : i64 0]
    [length : i64 (string.string-length text)]
    [value : i64 0]
    [valid : bool (> length 0)]
    (begin
      (while (and valid (< index length))
        (let
          [code : i64 (git-ssh-byte text index)]
          (begin
            (if (not (git-ssh-ascii-digit? code))
              (set! valid false)
              (let
                [digit : i64 (- code 48)]
                (if (> value (/ (- 65535 digit) 10))
                  (set! valid false)
                  (set! value (+ (* value 10) digit)))))
            (set! index (+ index 1)))))
      (if (and valid (>= value 1) (<= value 65535))
        (ResultGitSshPort.Ok value)
        (ResultGitSshPort.Err (GitSshRemoteError.InvalidPort))))))

(define (git-ssh-name-endpoint
  [has-user : bool]
  [user : String]
  [hostport : (& hostport str)]
  [allow-port : bool]) : ResultGitSshEndpoint
  (let
    [colon-count : i64 (git-ssh-count-byte hostport 58)]
    [colon : i64 (git-ssh-find-byte hostport 0 58)]
    (cond
      [(> colon-count 1)
        (ResultGitSshEndpoint.Err (GitSshRemoteError.AmbiguousSyntax))]
      [(and (= colon-count 1) (not allow-port))
        (ResultGitSshEndpoint.Err (GitSshRemoteError.AmbiguousSyntax))]
      [else
        (let
          [host-raw : String
            (if (= colon-count 1)
              (string.substring hostport 0 colon)
              (string.copy hostport))]
          [host : String (git-ssh-normalize-ascii (& host-raw))]
          (cond
            [(= (string.string-length (& host)) 0)
              (ResultGitSshEndpoint.Err (GitSshRemoteError.EmptyHost))]
            [(not (git-ssh-host-name-valid? (& host)))
              (ResultGitSshEndpoint.Err (GitSshRemoteError.InvalidHost))]
            [(= colon-count 0)
              (ResultGitSshEndpoint.Ok
                (GitSshEndpoint has-user user host (GitSshHostKind.Name) 22))]
            [else
              (let
                [port-text : String
                  (string.substring
                    hostport
                    (+ colon 1)
                    (- (string.string-length hostport) (+ colon 1)))]
                (match (git-ssh-port-parse (& port-text))
                  [(ResultGitSshPort.Err error)
                    (ResultGitSshEndpoint.Err error)]
                  [(ResultGitSshPort.Ok port)
                    (ResultGitSshEndpoint.Ok
                      (GitSshEndpoint
                        has-user
                        user
                        host
                        (GitSshHostKind.Name)
                        port))]))]))])))

(define (git-ssh-ipv6-endpoint
  [has-user : bool]
  [user : String]
  [hostport : (& hostport str)]
  [allow-port : bool]) : ResultGitSshEndpoint
  (let
    [close : i64 (git-ssh-find-byte hostport 1 93)]
    [hostport-length : i64 (string.string-length hostport)]
    (if (< close 0)
      (ResultGitSshEndpoint.Err (GitSshRemoteError.InvalidIpv6Literal))
      (let
        [host-raw : String (string.substring hostport 1 (- close 1))]
        [host : String (git-ssh-normalize-ascii (& host-raw))]
        [tail-start : i64 (+ close 1)]
        (cond
          [(not (git-ssh-ipv6-valid? (& host)))
            (ResultGitSshEndpoint.Err (GitSshRemoteError.InvalidIpv6Literal))]
          [(= tail-start hostport-length)
            (ResultGitSshEndpoint.Ok
              (GitSshEndpoint
                has-user
                user
                host
                (GitSshHostKind.Ipv6Literal)
                22))]
          [(or
              (not allow-port)
              (!= (git-ssh-byte hostport tail-start) 58)
              (= (+ tail-start 1) hostport-length))
            (ResultGitSshEndpoint.Err (GitSshRemoteError.AmbiguousSyntax))]
          [else
            (let
              [port-text : String
                (string.substring
                  hostport
                  (+ tail-start 1)
                  (- hostport-length (+ tail-start 1)))]
              (match (git-ssh-port-parse (& port-text))
                [(ResultGitSshPort.Err error) (ResultGitSshEndpoint.Err error)]
                [(ResultGitSshPort.Ok port)
                  (ResultGitSshEndpoint.Ok
                    (GitSshEndpoint
                      has-user
                      user
                      host
                      (GitSshHostKind.Ipv6Literal)
                      port))]))])))))

(define (git-ssh-parse-authority
  [authority : (& authority str)]
  [allow-port : bool]) : ResultGitSshEndpoint
  (let
    [length : i64 (string.string-length authority)]
    [at-count : i64 (git-ssh-count-byte authority 64)]
    [at : i64 (git-ssh-find-byte authority 0 64)]
    (cond
      [(= length 0) (ResultGitSshEndpoint.Err (GitSshRemoteError.EmptyHost))]
      [(> at-count 1)
        (ResultGitSshEndpoint.Err (GitSshRemoteError.AmbiguousSyntax))]
      [else
        (let
          [has-user : bool (= at-count 1)]
          [user : String
            (if has-user
              (string.substring authority 0 at)
              "")]
          [hostport-start : i64
            (if has-user
              (+ at 1)
              0)]
          [hostport : String
            (string.substring
              authority
              hostport-start
              (- length hostport-start))]
          (cond
            [(and has-user (git-ssh-userinfo-password-marker? (& user)))
              (ResultGitSshEndpoint.Err (GitSshRemoteError.PasswordUserinfo))]
            [(and has-user (not (git-ssh-user-valid? (& user))))
              (ResultGitSshEndpoint.Err (GitSshRemoteError.InvalidUser))]
            [(= (string.string-length (& hostport)) 0)
              (ResultGitSshEndpoint.Err (GitSshRemoteError.EmptyHost))]
            [(= (git-ssh-byte (& hostport) 0) 91)
              (git-ssh-ipv6-endpoint has-user user (& hostport) allow-port)]
            [else (git-ssh-name-endpoint has-user user (& hostport) allow-port)]))])))

(define (git-ssh-uri-path-decode [raw : (& raw str)]) : ResultGitSshPath
  (let
    [index : i64 0]
    [length : i64 (string.string-length raw)]
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity length)]
    [valid : bool (> length 0)]
    [error : GitSshRemoteError (GitSshRemoteError.UnsafePercentEncoding)]
    (begin
      (while (and valid (< index length))
        (let
          [code : i64 (git-ssh-byte raw index)]
          (cond
            [(= code 37)
              (if (>= (+ index 2) length)
                (set! valid false)
                (let
                  [hi : i64
                    (git-ssh-ascii-hex-value (git-ssh-byte raw (+ index 1)))]
                  [lo : i64
                    (git-ssh-ascii-hex-value (git-ssh-byte raw (+ index 2)))]
                  (if (or (< hi 0) (< lo 0))
                    (set! valid false)
                    (let
                      [decoded : i64 (+ (* hi 16) lo)]
                      (if (or
                        (git-ssh-control-code? decoded)
                        (= decoded 47)
                        (= decoded 92))
                        (set! valid false)
                        (begin
                          (git-ssh-builder-push! (&mut out) decoded)
                          (set! index (+ index 2))))))))]
            [(or (= code 63) (= code 35) (= code 92))
              (begin
                (set! error (GitSshRemoteError.AmbiguousSyntax))
                (set! valid false))]
            [else (git-ssh-builder-push! (&mut out) code)])
          (set! index (+ index 1))))
      (if (not valid)
        (ResultGitSshPath.Err error)
        (let
          [decoded : String (byte_buf.byte-buf-builder-finish-string (& out))]
          [decoded-length : i64 (string.string-length (& decoded))]
          (if (= decoded-length 0)
            (ResultGitSshPath.Err (GitSshRemoteError.EmptyPath))
            (if (and
              (> decoded-length 1)
              (= (git-ssh-byte (& decoded) 0) 47)
              (= (git-ssh-byte (& decoded) 1) 126))
              (ResultGitSshPath.Ok
                (string.substring (& decoded) 1 (- decoded-length 1))
                (GitSshPathKind.Tilde))
              (ResultGitSshPath.Ok decoded (GitSshPathKind.Absolute)))))))))

(define (git-ssh-scp-path [raw : (& raw str)]) : ResultGitSshPath
  (let
    [length : i64 (string.string-length raw)]
    (if (= length 0)
      (ResultGitSshPath.Err (GitSshRemoteError.EmptyPath))
      (let
        [first : i64 (git-ssh-byte raw 0)]
        (cond
          [(= first 45)
            (ResultGitSshPath.Err (GitSshRemoteError.LeadingDashPath))]
          [(= first 47)
            (ResultGitSshPath.Ok (string.copy raw) (GitSshPathKind.Absolute))]
          [(= first 126)
            (ResultGitSshPath.Ok (string.copy raw) (GitSshPathKind.Tilde))]
          [else
            (ResultGitSshPath.Ok (string.copy raw) (GitSshPathKind.Relative))])))))

(define (git-ssh-parse-uri [remote : (& remote str)]) : ResultGitSshRemote
  (let
    [length : i64 (string.string-length remote)]
    [path-start : i64 (git-ssh-find-byte remote 6 47)]
    (if (< path-start 0)
      (ResultGitSshRemote.Err (GitSshRemoteError.EmptyPath))
      (let
        [authority : String (string.substring remote 6 (- path-start 6))]
        [raw-path : String
          (string.substring remote path-start (- length path-start))]
        (match (git-ssh-parse-authority (& authority) true)
          [(ResultGitSshEndpoint.Err error) (ResultGitSshRemote.Err error)]
          [(ResultGitSshEndpoint.Ok endpoint)
            (match (git-ssh-uri-path-decode (& raw-path))
              [(ResultGitSshPath.Err error) (ResultGitSshRemote.Err error)]
              [(ResultGitSshPath.Ok path path-kind)
                (ResultGitSshRemote.Ok
                  (GitSshRemote
                    (GitSshRemoteSyntax.Uri)
                    endpoint
                    path
                    path-kind))])])))))

(define (git-ssh-scp-delimiter [remote : (& remote str)]) : i64
  (let
    [index : i64 0]
    [length : i64 (string.string-length remote)]
    [bracketed : bool false]
    [delimiter : i64 -1]
    [valid : bool true]
    (begin
      (while (and valid (< index length))
        (let
          [code : i64 (git-ssh-byte remote index)]
          (cond
            [(= code 91)
              (if bracketed
                (set! valid false)
                (set! bracketed true))]
            [(= code 93)
              (if bracketed
                (set! bracketed false)
                (set! valid false))]
            [(and (= code 58) (not bracketed))
              (if (< delimiter 0)
                (set! delimiter index)
                unit)]
            [(and (< delimiter 0) (or (= code 47) (= code 92)))
              (set! valid false)]
            [else unit])
          (set! index (+ index 1))))
      (if (or (not valid) bracketed)
        -1
        delimiter))))

;; A second colon in the repository path is ordinarily literal. Reject only
;; the shape that could instead be an unbracketed hexadecimal IPv6 authority:
;; a hexadecimal host segment followed by hexadecimal/colon segments up to the
;; first slash. Callers must bracket that address to make the boundary explicit.
(define (git-ssh-scp-unbracketed-ipv6-ambiguous?
  [remote : (& remote str)]
  [delimiter : i64]) : bool
  (let
    [at : i64 (git-ssh-find-byte remote 0 64)]
    [host-start : i64
      (if (and (>= at 0) (< at delimiter))
        (+ at 1)
        0)]
    [index : i64 host-start]
    [host-hex : bool (< host-start delimiter)]
    [tail-hex : bool true]
    [extra-colon : bool false]
    [length : i64 (string.string-length remote)]
    (begin
      (while (and host-hex (< index delimiter))
        (begin
          (if (< (git-ssh-ascii-hex-value (git-ssh-byte remote index)) 0)
            (set! host-hex false)
            unit)
          (set! index (+ index 1))))
      (set! index (+ delimiter 1))
      (while (and tail-hex (< index length) (!= (git-ssh-byte remote index) 47))
        (let
          [code : i64 (git-ssh-byte remote index)]
          (begin
            (cond
              [(= code 58) (set! extra-colon true)]
              [(>= (git-ssh-ascii-hex-value code) 0) unit]
              [else (set! tail-hex false)])
            (set! index (+ index 1)))))
      (and host-hex tail-hex extra-colon))))

(define (git-ssh-parse-scp [remote : (& remote str)]) : ResultGitSshRemote
  (let
    [length : i64 (string.string-length remote)]
    [delimiter : i64 (git-ssh-scp-delimiter remote)]
    (if (< delimiter 0)
      (ResultGitSshRemote.Err (GitSshRemoteError.AmbiguousSyntax))
      (let
        [authority : String (string.substring remote 0 delimiter)]
        [raw-path : String
          (string.substring remote (+ delimiter 1) (- length (+ delimiter 1)))]
        [at : i64 (git-ssh-find-byte (& authority) 0 64)]
        (if (or
          (and
            (< at 0)
            (= (string.string-length (& authority)) 1)
            (git-ssh-ascii-alpha? (git-ssh-byte (& authority) 0)))
          (git-ssh-scp-unbracketed-ipv6-ambiguous? remote delimiter))
          (ResultGitSshRemote.Err (GitSshRemoteError.AmbiguousSyntax))
          (match (git-ssh-parse-authority (& authority) false)
            [(ResultGitSshEndpoint.Err error) (ResultGitSshRemote.Err error)]
            [(ResultGitSshEndpoint.Ok endpoint)
              (match (git-ssh-scp-path (& raw-path))
                [(ResultGitSshPath.Err error) (ResultGitSshRemote.Err error)]
                [(ResultGitSshPath.Ok path path-kind)
                  (ResultGitSshRemote.Ok
                    (GitSshRemote
                      (GitSshRemoteSyntax.Scp)
                      endpoint
                      path
                      path-kind))])]))))))

;: Parse one supported SSH Git remote without retaining the input authority.
;:
;: URI paths are percent-decoded only after the authority is split. Encodings
;: of `/`, `\\`, NUL, or another control byte are rejected because decoding
;: them would change structure or command framing. Scp-like paths are literal
;: bytes and are never percent-decoded. Host names are ASCII-only and folded to
;: lowercase without locale rules; bracketed hexadecimal IPv6 is folded the
;: same way. The normalized default port is always 22.
(define (git-ssh-remote-parse [remote : (& remote str)]) : ResultGitSshRemote
  (cond
    [(= (string.string-length remote) 0)
      (ResultGitSshRemote.Err (GitSshRemoteError.UnsupportedSyntax))]
    [(git-ssh-has-control? remote)
      (ResultGitSshRemote.Err (GitSshRemoteError.ControlByte))]
    [(git-ssh-uri-prefix? remote) (git-ssh-parse-uri remote)]
    [(git-ssh-has-scheme-separator? remote)
      (ResultGitSshRemote.Err (GitSshRemoteError.UnsupportedSyntax))]
    [else (git-ssh-parse-scp remote)]))

(define (git-ssh-syntax-uri? [syntax : (& syntax GitSshRemoteSyntax)]) : bool
  (match syntax
    [(GitSshRemoteSyntax.Uri) true]
    [_ false]))

(define (git-ssh-host-kind-valid?
  [host : (& host str)]
  [kind : (& kind GitSshHostKind)]) : bool
  (match kind
    [(GitSshHostKind.Name) (git-ssh-host-name-valid? host)]
    [(GitSshHostKind.Ipv6Literal) (git-ssh-ipv6-valid? host)]
    [_ false]))

(define (git-ssh-path-kind-valid?
  [path : (& path str)]
  [kind : (& kind GitSshPathKind)]) : bool
  (let
    [length : i64 (string.string-length path)]
    (if (= length 0)
      false
      (let
        [first : i64 (git-ssh-byte path 0)]
        (match kind
          [(GitSshPathKind.Absolute) (= first 47)]
          [(GitSshPathKind.Relative)
            (and (!= first 47) (!= first 126) (!= first 45))]
          [(GitSshPathKind.Tilde) (= first 126)]
          [_ false])))))

(define (git-ssh-host-normalized? [host : (& host str)]) : bool
  (let
    [index : i64 0]
    [length : i64 (string.string-length host)]
    [normalized : bool true]
    (begin
      (while (and normalized (< index length))
        (begin
          (if (!=
            (git-ssh-byte host index)
            (git-ssh-ascii-lower (git-ssh-byte host index)))
            (set! normalized false)
            unit)
          (set! index (+ index 1))))
      normalized)))

(define (git-ssh-structured-remote-valid? [remote : (& remote GitSshRemote)]) : bool
  (and
    (> (string.string-length (& remote.endpoint.host)) 0)
    (git-ssh-host-kind-valid?
      (& remote.endpoint.host)
      (& remote.endpoint.host-kind))
    (git-ssh-host-normalized? (& remote.endpoint.host))
    (>= remote.endpoint.port 1)
    (<= remote.endpoint.port 65535)
    (if remote.endpoint.has-user
      (git-ssh-user-valid? (& remote.endpoint.user))
      (= (string.string-length (& remote.endpoint.user)) 0))
    (git-ssh-path-kind-valid? (& remote.path) (& remote.path-kind))
    (not (git-ssh-has-control? (& remote.path)))
    (if (git-ssh-syntax-uri? (& remote.syntax))
      (match remote.path-kind
        [(GitSshPathKind.Relative) false]
        [_ true])
      (= remote.endpoint.port 22))))

;; Append Git's sq_quote_buf representation for one repository argument. Both
;; apostrophe and `!` leave the quoted span as `\\X` and immediately re-enter
;; it. No path byte is ever emitted as an unquoted shell token.
(define (git-ssh-quote-repository!
  [out : (&mut out byte_buf.ByteBufBuilder)]
  [path : (& path str)]) : unit
  (let
    [index : i64 0]
    [length : i64 (string.string-length path)]
    (begin
      (git-ssh-builder-push! out 39)
      (while (< index length)
        (let
          [code : i64 (git-ssh-byte path index)]
          (begin
            (if (or (= code 39) (= code 33))
              (begin
                (git-ssh-builder-push! out 39)
                (git-ssh-builder-push! out 92)
                (git-ssh-builder-push! out code)
                (git-ssh-builder-push! out 39))
              (git-ssh-builder-push! out code))
            (set! index (+ index 1)))))
      (git-ssh-builder-push! out 39))))

;: Encode exactly `git-upload-pack` and one opaque repository argument.
;:
;: There is deliberately no service-name, option, environment, or fragment
;: parameter. Relative paths beginning with `-` are rejected by the structured
;: invariant instead of rewritten.
(define (git-ssh-upload-pack-command [remote : (& remote GitSshRemote)]) : ResultGitSshCommand
  (cond
    [(= (string.string-length (& remote.path)) 0)
      (ResultGitSshCommand.Err (GitSshRemoteError.EmptyPath))]
    [(git-ssh-has-control? (& remote.path))
      (ResultGitSshCommand.Err (GitSshRemoteError.ControlByte))]
    [(and
        (match remote.path-kind
          [(GitSshPathKind.Relative) true]
          [_ false])
        (= (git-ssh-byte (& remote.path) 0) 45))
      (ResultGitSshCommand.Err (GitSshRemoteError.LeadingDashPath))]
    [(not (git-ssh-structured-remote-valid? remote))
      (ResultGitSshCommand.Err (GitSshRemoteError.InvalidStructuredRemote))]
    [else
      (let
        [out : byte_buf.ByteBufBuilder
          (byte_buf.byte-buf-builder-with-capacity
            (+ (string.string-length (& remote.path)) 32))]
        (begin
          (git-ssh-builder-append! (&mut out) "git-upload-pack ")
          (git-ssh-quote-repository! (&mut out) (& remote.path))
          (ResultGitSshCommand.Ok
            (byte_buf.byte-buf-builder-finish-string (& out)))))]))

;: Parse a remote and return the sole structured endpoint/service handoff.
(define (git-ssh-upload-pack-request [remote-text : (& remote-text str)]) : ResultGitSshUploadPackRequest
  (match (git-ssh-remote-parse remote-text)
    [(ResultGitSshRemote.Err error) (ResultGitSshUploadPackRequest.Err error)]
    [(ResultGitSshRemote.Ok remote)
      (match (git-ssh-upload-pack-command (& remote))
        [(ResultGitSshCommand.Err error)
          (ResultGitSshUploadPackRequest.Err error)]
        [(ResultGitSshCommand.Ok command)
          (ResultGitSshUploadPackRequest.Ok
            (GitSshUploadPackRequest remote command))])]))

(define (git-ssh-syntax-name [syntax : (& syntax GitSshRemoteSyntax)]) : String
  (match syntax
    [(GitSshRemoteSyntax.Uri) "uri"]
    [(GitSshRemoteSyntax.Scp) "scp"]
    [_ "unknown"]))

(define (git-ssh-host-kind-name [kind : (& kind GitSshHostKind)]) : String
  (match kind
    [(GitSshHostKind.Name) "name"]
    [(GitSshHostKind.Ipv6Literal) "ipv6"]
    [_ "unknown"]))

(define (git-ssh-path-kind-name [kind : (& kind GitSshPathKind)]) : String
  (match kind
    [(GitSshPathKind.Absolute) "absolute"]
    [(GitSshPathKind.Relative) "relative"]
    [(GitSshPathKind.Tilde) "tilde"]
    [_ "unknown"]))

;: Credential-free structured summary. It never contains a raw URI authority,
;: password, generated command, environment assignment, or local path.
(define (git-ssh-remote-summary [remote : (& remote GitSshRemote)]) : String
  (let
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity 128)]
    [port : String (string.int->string remote.endpoint.port)]
    [syntax : String (git-ssh-syntax-name (& remote.syntax))]
    [host-kind : String (git-ssh-host-kind-name (& remote.endpoint.host-kind))]
    [path-kind : String (git-ssh-path-kind-name (& remote.path-kind))]
    (begin
      (git-ssh-builder-append! (&mut out) "ssh{syntax=")
      (git-ssh-builder-append! (&mut out) (& syntax))
      (git-ssh-builder-append! (&mut out) ",user=")
      (if remote.endpoint.has-user
        (git-ssh-builder-append! (&mut out) (& remote.endpoint.user))
        (git-ssh-builder-append! (&mut out) "<none>"))
      (git-ssh-builder-append! (&mut out) ",host=")
      (git-ssh-builder-append! (&mut out) (& remote.endpoint.host))
      (git-ssh-builder-append! (&mut out) ",host-kind=")
      (git-ssh-builder-append! (&mut out) (& host-kind))
      (git-ssh-builder-append! (&mut out) ",port=")
      (git-ssh-builder-append! (&mut out) (& port))
      (git-ssh-builder-append! (&mut out) ",path-kind=")
      (git-ssh-builder-append! (&mut out) (& path-kind))
      (git-ssh-builder-append! (&mut out) ",path=")
      (git-ssh-builder-append! (&mut out) (& remote.path))
      (git-ssh-builder-push! (&mut out) 125)
      (byte_buf.byte-buf-builder-finish-string (& out)))))