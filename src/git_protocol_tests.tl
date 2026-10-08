;; git_protocol_tests.tl - pkt-line framing, sideband, upload-pack codecs and
;; the fetch session over fragmented, malformed and adversarial input (#7074).
(import git_object_core as git_object)
(import git_pkt_line_core as pkt)
(import git_protocol_core as proto)
(import stdlib.byte_buf_core as byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define (gp-require [ok : bool] [message : String]) : unit
  (unless ok (io.panic message)))

(define (gp-error-name [error : (& error pkt.GitProtocolError)]) : String
  (match error
    [(InvalidLengthHex) "InvalidLengthHex"]
    [(ReservedLength) "ReservedLength"]
    [(EmptyPacket) "EmptyPacket"]
    [(OversizedPacket) "OversizedPacket"]
    [(TruncatedPacket) "TruncatedPacket"]
    [(TrailingBytes) "TrailingBytes"]
    [(InvalidSideband) "InvalidSideband"]
    [(MissingAdvertisement) "MissingAdvertisement"]
    [(MalformedAdvertisement) "MalformedAdvertisement"]
    [(UnsupportedVersion) "UnsupportedVersion"]
    [(MalformedCapability) "MalformedCapability"]
    [(DuplicateCapability) "DuplicateCapability"]
    [(CapabilityLimit) "CapabilityLimit"]
    [(ConflictingObjectFormat) "ConflictingObjectFormat"]
    [(UnsupportedObjectFormat) "UnsupportedObjectFormat"]
    [(MissingCapability) "MissingCapability"]
    [(MalformedRef) "MalformedRef"]
    [(DuplicateRef) "DuplicateRef"]
    [(RefLimit) "RefLimit"]
    [(InvalidObjectId) "InvalidObjectId"]
    [(InvalidRefPrefix) "InvalidRefPrefix"]
    [(InvalidWant) "InvalidWant"]
    [(DuplicateWant) "DuplicateWant"]
    [(WantNotAdvertised) "WantNotAdvertised"]
    [(UnsupportedLegacyCapability) "UnsupportedLegacyCapability"]
    [(UnexpectedPacket) "UnexpectedPacket"]
    [(MalformedSection) "MalformedSection"]
    [(UnexpectedSection) "UnexpectedSection"]
    [(OutOfOrderSection) "OutOfOrderSection"]
    [(MissingShallowInfo) "MissingShallowInfo"]
    [(MalformedShallow) "MalformedShallow"]
    [(UnexpectedUnshallow) "UnexpectedUnshallow"]
    [(DuplicateShallow) "DuplicateShallow"]
    [(MalformedAcknowledgment) "MalformedAcknowledgment"]
    [(TruncatedResponse) "TruncatedResponse"]))

;: One data packet carrying `payload` exactly.
(define (gp-pkt [payload : String]) : String
  (match (pkt.git-pkt-encode-data (& payload))
    [(Ok bytes) bytes]
    [(Err _) (io.panic "gp-pkt: payload does not encode")]))

;: One text packet: `text` and LF.
(define (gp-line [text : String]) : String
  (gp-pkt (str_cat.str-cat text "\n")))

(define (gp-byte [value : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder (byte_buf.byte-buf-builder-with-capacity 1)]
    (byte_buf.byte-buf-builder-push (&mut out) (cast value : u8))
    (byte_buf.byte-buf-builder-finish-string (& out))))

(define (gp-repeat [byte : i64] [count : i64]) : String
  (let
    [out : byte_buf.ByteBufBuilder
      (byte_buf.byte-buf-builder-with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (byte_buf.byte-buf-builder-push (&mut out) (cast byte : u8))
      (set! index (+ index 1)))
    (byte_buf.byte-buf-builder-finish-string (& out))))

;: A sideband packet on `channel`.
(define (gp-band [channel : i64] [body : String]) : String
  (gp-pkt (str_cat.str-cat (gp-byte channel) body)))

(define (gp-describe-packet [packet : pkt.GitPkt]) : String
  (match packet
    [(Data payload) (str_cat.str-cat "D:" payload)]
    [(Flush) "F"]
    [(Delim) "M"]
    [(ResponseEnd) "E"]))

;: Every packet `reader` can yield now, as "|"-joined descriptions, ending at
;: its first error.
(define (gp-drain [reader : (&mut reader pkt.GitPktReader)]) : String
  (let
    [out : String ""]
    (while true
      (match (pkt.git-pkt-reader-next! reader)
        [(NeedMore) (return out)]
        [(Err error)
          (return (str_cat.str-cat out "!" (gp-error-name (& error))))]
        [(Packet packet)
          (set! out (str_cat.str-cat out (gp-describe-packet packet) "|"))]))
    out))

(define (gp-feed [reader : (&mut reader pkt.GitPktReader)] [chunk : String]) : unit
  (match (pkt.git-pkt-reader-feed! reader (& chunk))
    [(Ok) unit]
    [(Err _) (io.panic "gp-feed: input refused")]))

;: The packets of `stream` fed whole, then the end of input, stopping at the
;: first error.
(define (gp-frame [stream : String]) : String
  (let
    [reader : pkt.GitPktReader (pkt.git-pkt-reader-new)]
    (gp-feed (&mut reader) stream)
    (let
      [out : String (gp-drain (&mut reader))]
      (if (>= (proto.git-protocol-find (& out) 33 0) 0)
        out
        (match (pkt.git-pkt-reader-end (& reader))
          [(Ok) out]
          [(Err error) (str_cat.str-cat out "!" (gp-error-name (& error)))])))))

(define (gp-sub [text : (& text str)] [start : i64] [end : i64]) : String
  (string.substring text start (- end start)))

;; --- pkt-line framing -------------------------------------------------------
(test
  git-pkt-encodes-each-packet-kind
  (gp-require
    (string.eq (gp-pkt "version 2\n") "000eversion 2\n")
    "data header")
  (gp-require (string.eq (gp-pkt "a") "0005a") "one-byte payload")
  (gp-require (string.eq (pkt.git-pkt-flush) "0000") "flush")
  (gp-require (string.eq (pkt.git-pkt-delim) "0001") "delim")
  (gp-require (string.eq (pkt.git-pkt-response-end) "0002") "response-end")
  (gp-require
    (match (pkt.git-pkt-encode-data "")
      [(Err (EmptyPacket)) true]
      [_ false])
    "an empty data packet is not encoded")
  (let
    [largest : String (gp-repeat 120 pkt.git-pkt-max-payload)]
    [over : String (gp-repeat 120 (+ pkt.git-pkt-max-payload 1))]
    (gp-require
      (match (pkt.git-pkt-encode-data (& largest))
        [(Ok bytes)
          (and
            (= (string.string-length (& bytes)) pkt.git-pkt-max-length)
            (string.eq (gp-sub (& bytes) 0 4) "fff0"))]
        [_ false])
      "the largest payload encodes as fff0")
    (gp-require
      (match (pkt.git-pkt-encode-data (& over))
        [(Err (OversizedPacket)) true]
        [_ false])
      "one byte more is oversized")))

(define (gp-split-stream) : String
  (str_cat.str-cat
    (gp-line "version 2")
    (pkt.git-pkt-delim)
    (gp-pkt (str_cat.str-cat "bin" (gp-byte 0) (gp-byte 255) (gp-byte 10)))
    (pkt.git-pkt-flush)
    (pkt.git-pkt-response-end)))

(define (gp-split-expected) : String
  (str_cat.str-cat
    "D:version 2\n|M|D:bin"
    (gp-byte 0)
    (gp-byte 255)
    (gp-byte 10)
    "|F|E|"))

(test
  git-pkt-reader-yields-the-same-packets-at-every-split
  (let
    [stream : String (gp-split-stream)]
    [expected : String (gp-split-expected)]
    [count : i64 (string.string-length (& stream))]
    [split : i64 0]
    (gp-require
      (string.eq (gp-frame (string.copy (& stream))) (& expected))
      "whole stream")
    (while (<= split count)
      (let
        [reader : pkt.GitPktReader (pkt.git-pkt-reader-new)]
        (gp-feed (&mut reader) (gp-sub (& stream) 0 split))
        (let
          [first : String (gp-drain (&mut reader))]
          (gp-feed (&mut reader) (gp-sub (& stream) split count))
          (let
            [all : String (str_cat.str-cat first (gp-drain (&mut reader)))]
            (gp-require
              (string.eq (& all) (& expected))
              "split changes the packets")
            (gp-require
              (match (pkt.git-pkt-reader-end (& reader))
                [(Ok) true]
                [_ false])
              "a whole stream ends cleanly"))))
      (set! split (+ split 1)))
    (let
      [reader : pkt.GitPktReader (pkt.git-pkt-reader-new)]
      [all : String ""]
      [index : i64 0]
      (while (< index count)
        (gp-feed (&mut reader) (gp-sub (& stream) index (+ index 1)))
        (set! all (str_cat.str-cat all (gp-drain (&mut reader))))
        (set! index (+ index 1)))
      (gp-require (string.eq (& all) (& expected)) "byte-at-a-time input"))))

(test
  git-pkt-reader-rejects-malformed-lengths
  (gp-require
    (string.eq (gp-frame "0003") "!ReservedLength")
    "0003 is reserved")
  (gp-require
    (string.eq (gp-frame "0004") "!EmptyPacket")
    "0004 is an empty packet")
  (gp-require
    (string.eq (gp-frame "00g5a") "!InvalidLengthHex")
    "a non-hex length")
  (gp-require
    (string.eq (gp-frame " 005a") "!InvalidLengthHex")
    "a space in the length")
  (gp-require
    (string.eq (gp-frame "fff1") "!OversizedPacket")
    "65521 is oversized")
  (gp-require
    (string.eq (gp-frame "ffff") "!OversizedPacket")
    "the largest length field")
  (gp-require
    (string.eq (gp-frame "000Ahello\n") "D:hello\n|")
    "upper-case hex is accepted")
  (gp-require
    (string.eq (gp-frame "0009abc") "!TruncatedPacket")
    "a truncated payload")
  (gp-require
    (string.eq (gp-frame "00") "!TruncatedPacket")
    "a truncated header")
  (gp-require
    (string.eq (gp-frame "0000000") "F|!TruncatedPacket")
    "a header cut after a flush")
  (gp-require
    (string.eq (gp-frame "0006ok0003") "D:ok|!ReservedLength")
    "an error after good packets keeps them"))

(test
  git-pkt-reader-refuses-input-after-its-terminal-packet
  (let
    [reader : pkt.GitPktReader (pkt.git-pkt-reader-new)]
    (gp-feed (&mut reader) "0000")
    (gp-require (string.eq (gp-drain (&mut reader)) "F|") "the terminal flush")
    (gp-require
      (match (pkt.git-pkt-reader-terminate! (&mut reader))
        [(Ok) true]
        [_ false])
      "nothing buffered at the terminal packet")
    (gp-require
      (match (pkt.git-pkt-reader-feed! (&mut reader) "")
        [(Ok) true]
        [_ false])
      "no bytes is not trailing input")
    (gp-require
      (match (pkt.git-pkt-reader-feed! (&mut reader) "0")
        [(Err (TrailingBytes)) true]
        [_ false])
      "a byte after the terminal packet"))
  (let
    [reader : pkt.GitPktReader (pkt.git-pkt-reader-new)]
    (gp-feed (&mut reader) "00000000")
    (gp-require
      (string.eq (gp-drain (&mut reader)) "F|F|")
      "two flushes buffered")
    (gp-feed (&mut reader) "x")
    (let
      [_ : String (gp-drain (&mut reader))]
      (gp-require
        (match (pkt.git-pkt-reader-terminate! (&mut reader))
          [(Err (TrailingBytes)) true]
          [_ false])
        "a buffered byte at the terminal packet"))))

;; --- sideband and remote text ------------------------------------------------
(define (gp-sideband [payload : String] [max-text : i64]) : String
  (match (pkt.git-pkt-sideband (& payload) max-text)
    [(Ok band)
      (match band
        [(Pack bytes) (str_cat.str-cat "pack:" bytes)]
        [(Progress text) (str_cat.str-cat "progress:" text)]
        [(Fatal text) (str_cat.str-cat "fatal:" text)])]
    [(Err error) (str_cat.str-cat "!" (gp-error-name (& error)))]))

(test
  git-pkt-sideband-demultiplexes-and-sanitizes
  (let
    [binary : String
      (str_cat.str-cat
        "PACK"
        (gp-byte 0)
        (gp-byte 27)
        (gp-byte 255)
        (gp-byte 13))]
    (gp-require
      (string.eq
        (gp-sideband (str_cat.str-cat (gp-byte 1) (string.copy (& binary))) 8)
        (str_cat.str-cat "pack:" binary))
      "channel 1 is the exact pack bytes, unlimited by the text bound"))
  (gp-require
    (string.eq
      (gp-sideband
        (str_cat.str-cat
          (gp-byte 2)
          "Counting"
          (gp-byte 27)
          "[2K"
          (gp-byte 13)
          "objects:"
          (gp-byte 200)
          "\n")
        64)
      "progress:Counting?[2K objects:?")
    "progress: escape and high bytes become ?, CR/LF spaces, trailing space trimmed")
  (gp-require
    (string.eq
      (gp-sideband (str_cat.str-cat (gp-byte 2) "abcdefgh") 5)
      "progress:abcde")
    "progress is cut to the text bound")
  (gp-require
    (string.eq
      (gp-sideband (str_cat.str-cat (gp-byte 3) "access denied\n") 64)
      "fatal:access denied")
    "channel 3 is a fatal remote error")
  (gp-require
    (string.eq (gp-sideband "" 64) "!InvalidSideband")
    "no channel byte")
  (gp-require
    (string.eq
      (gp-sideband (str_cat.str-cat (gp-byte 0) "x") 64)
      "!InvalidSideband")
    "channel 0")
  (gp-require
    (string.eq
      (gp-sideband (str_cat.str-cat (gp-byte 4) "x") 64)
      "!InvalidSideband")
    "channel 4")
  (gp-require
    (string.eq (pkt.git-pkt-sanitize-text "a\tb" 64) "a b")
    "a tab becomes a space"))

;; --- fixtures ----------------------------------------------------------------
;: A SHA-1 hex ID of one repeated hex digit.
(define (gp-id [digit : i64]) : String
  (gp-repeat digit 40))

;: A SHA-256 hex ID of one repeated hex digit.
(define (gp-id256 [digit : i64]) : String
  (gp-repeat digit 64))

;: Text packet payloads from `text`, one per "|"-separated item, each ending
;: in LF.
(define (gp-payloads [text : String]) : (__tl_dyn-array String)
  (let
    [out : (__tl_dyn-array String) (__tl_make-array String 0)]
    [count : i64 (string.string-length (& text))]
    [start : i64 0]
    (while (< start count)
      (let
        [bar : i64 (proto.git-protocol-find (& text) 124 start)]
        [end : i64
          (if (< bar 0)
            count
            bar)]
        (let
          [item : String (str_cat.str-cat (gp-sub (& text) start end) "\n")]
          (__tl_array-push! out item))
        (set! start (+ end 1))))
    out))

(define (gp-limits) : proto.GitProtocolLimits
  (proto.git-protocol-default-limits))

(define (gp-format-name [format : (& format git_object.GitObjectFormat)]) : String
  (match format
    [(Sha1) "sha1"]
    [(Sha256) "sha256"]))

(define (gp-version-name [version : (& version proto.GitProtocolVersion)]) : String
  (match version
    [(V0) "v0"]
    [(V1) "v1"]
    [(V2) "v2"]))

;: "<version> <format> caps=<n> refs=<name>[=<id-digit>][^<peeled-digit>],...".
(define (gp-advert-text [advert : (& advert proto.GitAdvertisement)]) : String
  (let
    [out : String
      (str_cat.str-cat
        (gp-version-name (& advert.version))
        " "
        (gp-format-name (& advert.format))
        " caps="
        (string.int->string (array-length advert.capabilities))
        " refs=")]
    [index : i64 0]
    (while (< index (array-length advert.refs))
      (let
        [ref : (& advert git_object.GitAdvertisedRef)
          (& (array-ref advert.refs index))]
        (set!
          out
          (str_cat.str-cat
            out
            (string.copy (& ref.name))
            "="
            (gp-sub (& ref.id.hex) 0 1)
            (match (& ref.peeled)
              [(Present peeled)
                (str_cat.str-cat "^" (gp-sub (& peeled.hex) 0 1))]
              [(Absent) ""])
            ",")))
      (set! index (+ index 1)))
    out))

(define (gp-advert [lines : (__tl_dyn-array String)]) : String
  (match (proto.git-advertisement-parse (& lines) (& (gp-limits)))
    [(Ok advert) (gp-advert-text (& advert))]
    [(Err error) (str_cat.str-cat "!" (gp-error-name (& error)))]))

(define (gp-advert-ok [lines : (__tl_dyn-array String)]) : proto.GitAdvertisement
  (match (proto.git-advertisement-parse (& lines) (& (gp-limits)))
    [(Ok advert) advert]
    [(Err error)
      (io.panic (str_cat.str-cat "advertisement: " (gp-error-name (& error))))]))

(define (gp-v2-advert [extra : String]) : proto.GitAdvertisement
  (gp-advert-ok
    (gp-payloads
      (str_cat.str-cat
        "version 2|agent=git/2.45.0|ls-refs=unborn|fetch=shallow wait-for-done|server-option"
        extra))))

;: A v0/v1 first ref line: `<id> <name>` NUL `<capabilities>` LF.
(define (gp-first-ref [id : String] [name : String] [caps : String]) : String
  (str_cat.str-cat id " " name (gp-byte 0) caps "\n"))

;: v0 lines: the first ref with `caps`, then each "|"-separated `<id> <name>`.
(define (gp-legacy-lines [version-line : bool] [first : String] [rest : String]) : (__tl_dyn-array
    String)
  (let
    [out : (__tl_dyn-array String) (__tl_make-array String 0)]
    [tail : (__tl_dyn-array String) (gp-payloads rest)]
    [index : i64 0]
    (when version-line (__tl_array-push! out "version 1\n"))
    (__tl_array-push! out first)
    (while (< index (array-length tail))
      (__tl_array-push! out (string.copy (& (array-ref tail index))))
      (set! index (+ index 1)))
    out))

;; --- advertisements ----------------------------------------------------------
(test
  git-protocol-v2-advertisement-validates-capabilities
  (gp-require
    (string.eq
      (gp-advert
        (gp-payloads
          "version 2|agent=git/2.45.0|ls-refs=unborn|fetch=shallow wait-for-done|x-unknown-feature=1"))
      "v2 sha1 caps=4 refs=")
    "unknown capabilities are kept; no object-format means SHA-1")
  (let
    [advert : proto.GitAdvertisement (gp-v2-advert "|object-format=sha256")]
    (gp-require
      (string.eq (gp-advert-text (& advert)) "v2 sha256 caps=5 refs=")
      "SHA-256")
    (gp-require advert.has-object-format "the format was advertised")
    (gp-require
      (proto.git-advertisement-has-feature? (& advert) "fetch" "shallow")
      "fetch lists shallow")
    (gp-require
      (not (proto.git-advertisement-has-feature? (& advert) "fetch" "filter"))
      "fetch does not list filter")
    (gp-require
      (proto.git-advertisement-has-capability? (& advert) "server-option")
      "a capability without a value"))
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 2|fetch|fetch=shallow"))
      "!DuplicateCapability")
    "a repeated capability")
  (gp-require
    (string.eq
      (gp-advert
        (gp-payloads "version 2|object-format=sha1|object-format=sha256"))
      "!ConflictingObjectFormat")
    "two object formats")
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 2|object-format=md5"))
      "!UnsupportedObjectFormat")
    "an unknown object format")
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 2|bad key"))
      "!MalformedCapability")
    "a space in a key")
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 2|=value"))
      "!MalformedCapability")
    "an empty key")
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 2|key="))
      "!MalformedCapability")
    "an empty value after =")
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 2|agent=a~b"))
      "!MalformedCapability")
    "a value outside the v2 character set")
  (gp-require
    (string.eq
      (gp-advert (gp-payloads "version 3|fetch"))
      "!UnsupportedVersion")
    "version 3")
  (gp-require
    (string.eq (gp-advert (__tl_make-array String 0)) "!MissingAdvertisement")
    "no packets")
  (let
    [lines : (__tl_dyn-array String) (gp-payloads "version 2")]
    [limits : proto.GitProtocolLimits (proto.GitProtocolLimits 16 2 64 64)]
    [index : i64 0]
    (while (< index 3)
      (let
        [item : String (str_cat.str-cat "cap" (string.int->string index) "\n")]
        (__tl_array-push! lines item))
      (set! index (+ index 1)))
    (gp-require
      (match (proto.git-advertisement-parse (& lines) (& limits))
        [(Err (CapabilityLimit)) true]
        [_ false])
      "more capabilities than the limit")))

(test
  git-protocol-legacy-advertisement-reads-refs-and-capabilities
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref
            (gp-id 97)
            "HEAD"
            "multi_ack side-band-64k ofs-delta shallow symref=HEAD:refs/heads/main agent=git/2.45.0")
          (str_cat.str-cat
            (gp-id 97)
            " refs/heads/main|"
            (gp-id 98)
            " refs/tags/v1|"
            (gp-id 99)
            " refs/tags/v1^{}")))
      "v0 sha1 caps=6 refs=HEAD=a,refs/heads/main=a,refs/tags/v1=b^c,")
    "v0 refs with a peeled tag")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          true
          (gp-first-ref
            (gp-id256 100)
            "refs/heads/main"
            "side-band-64k object-format=sha256")
          ""))
      "v1 sha256 caps=2 refs=refs/heads/main=d,")
    "v1 with SHA-256 IDs")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 48) "capabilities^{}" "side-band-64k")
          ""))
      "v0 sha1 caps=1 refs=")
    "an empty repository advertises capabilities only")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id256 48) "capabilities^{}" "object-format=sha256")
          ""))
      "v0 sha256 caps=1 refs=")
    "an empty SHA-256 repository"))

(test
  git-protocol-legacy-advertisement-rejects-malformed-refs
  (gp-require
    (string.eq
      (gp-advert (gp-payloads (str_cat.str-cat (gp-id 97) " refs/heads/main")))
      "!MalformedAdvertisement")
    "a first ref without the capability suffix")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "side-band-64k")
          ""))
      "v0 sha1 caps=1 refs=refs/heads/a=a,")
    "the control fixture parses")
  (let
    [lines : (__tl_dyn-array String)
      (gp-legacy-lines false (gp-first-ref (gp-id 97) "refs/heads/a" "") "")]
    (__tl_array-push! lines (gp-first-ref (gp-id 98) "refs/heads/b" "x"))
    (gp-require
      (string.eq (gp-advert lines) "!MalformedRef")
      "a NUL after the first ref"))
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "")
          (str_cat.str-cat (gp-id 98) " refs/tags/v1^{}")))
      "!MalformedRef")
    "a peeled line that does not follow its ref")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/tags/v1" "")
          (str_cat.str-cat
            (gp-id 98)
            " refs/tags/v1^{}|"
            (gp-id 99)
            " refs/tags/v1^{}")))
      "!DuplicateRef")
    "a ref peeled twice")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "")
          (str_cat.str-cat (gp-id 98) " refs/heads/a")))
      "!DuplicateRef")
    "a ref named twice")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "")
          (str_cat.str-cat (gp-id256 98) " refs/heads/b")))
      "!InvalidObjectId")
    "a SHA-256 ID in a SHA-1 advertisement")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "")
          "zz refs/heads/b"))
      "!InvalidObjectId")
    "a non-hex ID")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/../x" "")
          ""))
      "!MalformedRef")
    "an invalid ref name")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines false (gp-first-ref (gp-id 48) "refs/heads/a" "") ""))
      "!InvalidObjectId")
    "the zero ID names no ref")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 48) "capabilities^{}" "")
          (str_cat.str-cat (gp-id 97) " refs/heads/a")))
      "!MalformedAdvertisement")
    "an empty repository with refs")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "a  b")
          ""))
      "!MalformedCapability")
    "an empty capability token")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id 97) "refs/heads/a" "a a")
          ""))
      "!DuplicateCapability")
    "a repeated capability")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref
            (gp-id 97)
            "refs/heads/a"
            "symref=HEAD:refs/heads/a symref=refs/x:refs/heads/a")
          ""))
      "v0 sha1 caps=2 refs=refs/heads/a=a,")
    "symref may repeat")
  (gp-require
    (string.eq
      (gp-advert
        (gp-legacy-lines
          false
          (gp-first-ref (gp-id256 97) "refs/heads/a" "object-format=sha1")
          ""))
      "!InvalidObjectId")
    "IDs must match the advertised format")
  (let
    [lines : (__tl_dyn-array String)
      (gp-legacy-lines
        false
        (gp-first-ref (gp-id 97) "refs/heads/a" "")
        (str_cat.str-cat (gp-id 98) " refs/heads/b|" (gp-id 99) " refs/heads/c"))]
    [limits : proto.GitProtocolLimits (proto.GitProtocolLimits 2 8 64 64)]
    (gp-require
      (match (proto.git-advertisement-parse (& lines) (& limits))
        [(Err (RefLimit)) true]
        [_ false])
      "more refs than the limit")))

;; --- ls-refs -----------------------------------------------------------------
(define (gp-ls-refs-request
  [advert : proto.GitAdvertisement]
  [prefixes : String]
  [unborn : bool]) : String
  (let
    [list : (__tl_dyn-array String) (__tl_make-array String 0)]
    [items : (__tl_dyn-array String)
      (if (= (string.string-length (& prefixes)) 0)
        (__tl_make-array String 0)
        (gp-payloads prefixes))]
    [index : i64 0]
    (while (< index (array-length items))
      (let
        [item : String (pkt.git-pkt-text (& (array-ref items index)))]
        (__tl_array-push! list item))
      (set! index (+ index 1)))
    (match (proto.git-ls-refs-request (& advert) (& list) unborn)
      [(Ok plan)
        (str_cat.str-cat
          (if plan.unborn
            "unborn:"
            "plain:")
          plan.request)]
      [(Err error) (str_cat.str-cat "!" (gp-error-name (& error)))])))

(test
  git-protocol-ls-refs-request-encodes-prefixes
  (gp-require
    (string.eq
      (gp-ls-refs-request (gp-v2-advert "") "refs/heads/|HEAD" true)
      (str_cat.str-cat
        "unborn:"
        (gp-line "command=ls-refs")
        (pkt.git-pkt-delim)
        (gp-line "peel")
        (gp-line "symrefs")
        (gp-line "unborn")
        (gp-line "ref-prefix refs/heads/")
        (gp-line "ref-prefix HEAD")
        (pkt.git-pkt-flush)))
    "ls-refs with unborn and two prefixes")
  (gp-require
    (string.eq
      (gp-ls-refs-request (gp-v2-advert "|object-format=sha256") "" false)
      (str_cat.str-cat
        "plain:"
        (gp-line "command=ls-refs")
        (gp-line "object-format=sha256")
        (pkt.git-pkt-delim)
        (gp-line "peel")
        (gp-line "symrefs")
        (pkt.git-pkt-flush)))
    "the advertised object format is echoed")
  (gp-require
    (string.eq
      (gp-ls-refs-request
        (gp-advert-ok (gp-payloads "version 2|ls-refs|fetch"))
        ""
        true)
      (str_cat.str-cat
        "plain:"
        (gp-line "command=ls-refs")
        (pkt.git-pkt-delim)
        (gp-line "peel")
        (gp-line "symrefs")
        (pkt.git-pkt-flush)))
    "unborn is not asked of a server that does not advertise it")
  (gp-require
    (string.eq
      (gp-ls-refs-request (gp-v2-advert "") "refs/heads/ x" false)
      "!InvalidRefPrefix")
    "a prefix with a space")
  (gp-require
    (string.eq
      (gp-ls-refs-request
        (gp-advert-ok (gp-payloads "version 2|fetch"))
        ""
        false)
      "!MissingCapability")
    "a server without ls-refs")
  (gp-require
    (string.eq
      (gp-ls-refs-request
        (gp-advert-ok
          (gp-legacy-lines
            false
            (gp-first-ref (gp-id 97) "refs/heads/a" "side-band-64k")
            ""))
        ""
        false)
      "!UnsupportedVersion")
    "ls-refs is a v2 command"))

(define (gp-ls-refs
  [format : git_object.GitObjectFormat]
  [lines : String]
  [unborn : bool]) : String
  (match (proto.git-ls-refs-parse
    format
    (& (gp-payloads lines))
    unborn
    (& (gp-limits)))
    [(Err error) (str_cat.str-cat "!" (gp-error-name (& error)))]
    [(Ok refs)
      (let
        [out : String ""]
        [index : i64 0]
        (while (< index (array-length refs))
          (set!
            out
            (str_cat.str-cat
              out
              (match (& (array-ref refs index))
                [(Ref advert)
                  (str_cat.str-cat
                    (string.copy (& advert.name))
                    "="
                    (gp-sub (& advert.id.hex) 0 1)
                    (if advert.has-symref
                      (str_cat.str-cat
                        "->"
                        (string.copy (& advert.symref-target)))
                      "")
                    (match (& advert.peeled)
                      [(Present peeled)
                        (str_cat.str-cat "^" (gp-sub (& peeled.hex) 0 1))]
                      [(Absent) ""]))]
                [(Unborn name target)
                  (str_cat.str-cat
                    "unborn "
                    (string.copy name)
                    "->"
                    (string.copy target))])
              ","))
          (set! index (+ index 1)))
        out)]))

(test
  git-protocol-ls-refs-parses-ordinary-symbolic-peeled-and-unborn-refs
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat
          (gp-id 97)
          " HEAD symref-target:refs/heads/main|"
          (gp-id 97)
          " refs/heads/main|"
          (gp-id 98)
          " refs/tags/v1 peeled:"
          (gp-id 99)
          "|unborn refs/heads/dev")
        true)
      "HEAD=a->refs/heads/main,refs/heads/main=a,refs/tags/v1=b^c,unborn refs/heads/dev->,")
    "SHA-1 refs")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha256)
        (str_cat.str-cat
          (gp-id256 101)
          " refs/heads/main|unborn HEAD symref-target:refs/heads/main")
        true)
      "refs/heads/main=e,unborn HEAD->refs/heads/main,")
    "SHA-256 refs and an unborn HEAD")
  (gp-require
    (string.eq
      (gp-ls-refs (Sha1) "unborn HEAD symref-target:refs/heads/main" false)
      "!MalformedRef")
    "unborn without asking for it")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat "unborn HEAD peeled:" (gp-id 97))
        true)
      "!MalformedRef")
    "an unborn ref has nothing to peel")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha256)
        (str_cat.str-cat (gp-id 97) " refs/heads/main")
        false)
      "!InvalidObjectId")
    "a SHA-1 width under SHA-256")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat (gp-id 97) " refs/tags/v1 peeled:" (gp-id256 98))
        false)
      "!InvalidObjectId")
    "a peeled ID of the wrong width")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat
          (gp-id 97)
          " HEAD symref-target:refs/heads/a symref-target:refs/heads/b")
        false)
      "!MalformedRef")
    "a repeated attribute")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat (gp-id 97) " refs/heads/a owner:me")
        false)
      "!MalformedRef")
    "an unknown attribute")
  (gp-require
    (string.eq
      (gp-ls-refs (Sha1) (str_cat.str-cat (gp-id 97) " refs/heads/a ") false)
      "!MalformedRef")
    "a trailing space")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat (gp-id 97) " HEAD symref-target:")
        false)
      "!MalformedRef")
    "an empty symref target")
  (gp-require
    (string.eq
      (gp-ls-refs
        (Sha1)
        (str_cat.str-cat (gp-id 97) " refs/heads/a|" (gp-id 98) " refs/heads/a")
        false)
      "!DuplicateRef")
    "a ref listed twice")
  (gp-require
    (string.eq (gp-ls-refs (Sha1) (gp-id 97) false) "!MalformedRef")
    "an ID without a name"))

;; --- fetch requests ----------------------------------------------------------
(define (gp-options [shallow : bool] [ofs-delta : bool] [no-progress : bool]) : proto.GitFetchOptions
  (proto.GitFetchOptions shallow ofs-delta no-progress))

(define (gp-facts-text [facts : (& facts proto.GitFetchFacts)]) : String
  (str_cat.str-cat
    (gp-version-name (& facts.version))
    " "
    (gp-format-name (& facts.format))
    (if facts.deepen
      " deepen"
      "")
    (if facts.ofs-delta
      " ofs-delta"
      "")
    (if facts.no-progress
      " no-progress"
      "")
    " wants="
    (string.int->string facts.want-count)))

(define (gp-fetch-request
  [advert : proto.GitAdvertisement]
  [wants : String]
  [options : proto.GitFetchOptions]) : String
  (let
    [list : (__tl_dyn-array String) (__tl_make-array String 0)]
    [items : (__tl_dyn-array String) (gp-payloads wants)]
    [index : i64 0]
    (while (< index (array-length items))
      (let
        [item : String (pkt.git-pkt-text (& (array-ref items index)))]
        (__tl_array-push! list item))
      (set! index (+ index 1)))
    (match (proto.git-fetch-request (& advert) (& list) (& options))
      [(Ok plan)
        (str_cat.str-cat (gp-facts-text (& plan.facts)) "|" plan.request)]
      [(Err error) (str_cat.str-cat "!" (gp-error-name (& error)))])))

(test
  git-protocol-v2-fetch-request-is-the-exact-want-profile
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-v2-advert "")
        (str_cat.str-cat (gp-id 97) "|" (gp-id 98))
        (gp-options true true true))
      (str_cat.str-cat
        "v2 sha1 deepen ofs-delta no-progress wants=2|"
        (gp-line "command=fetch")
        (pkt.git-pkt-delim)
        (gp-line "ofs-delta")
        (gp-line "no-progress")
        (gp-line (str_cat.str-cat "want " (gp-id 97)))
        (gp-line (str_cat.str-cat "want " (gp-id 98)))
        (gp-line "deepen 1")
        (gp-line "done")
        (pkt.git-pkt-flush)))
    "shallow, ofs-delta and no-progress all requested")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-advert-ok (gp-payloads "version 2|fetch|object-format=sha256"))
        (gp-id256 97)
        (gp-options true false false))
      (str_cat.str-cat
        "v2 sha256 wants=1|"
        (gp-line "command=fetch")
        (gp-line "object-format=sha256")
        (pkt.git-pkt-delim)
        (gp-line (str_cat.str-cat "want " (gp-id256 97)))
        (gp-line "done")
        (pkt.git-pkt-flush)))
    "no deepen without shallow support; the SHA-256 format is echoed")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-advert-ok (gp-payloads "version 2|ls-refs"))
        (gp-id 97)
        (gp-options false false false))
      "!MissingCapability")
    "a server without fetch")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-v2-advert "|object-format=sha256")
        (gp-id 97)
        (gp-options false false false))
      "!InvalidWant")
    "a SHA-1 want under SHA-256")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-v2-advert "")
        (gp-id 48)
        (gp-options false false false))
      "!InvalidWant")
    "the zero ID")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-v2-advert "")
        (str_cat.str-cat (gp-id 97) "|" (gp-id 97))
        (gp-options false false false))
      "!DuplicateWant")
    "a repeated want")
  (gp-require
    (match (proto.git-fetch-request
      (& (gp-v2-advert ""))
      (& (__tl_make-array String 0))
      (& (gp-options false false false)))
      [(Err (InvalidWant)) true]
      [_ false])
    "no wants"))

(define (gp-legacy-advert [caps : String] [rest : String]) : proto.GitAdvertisement
  (gp-advert-ok
    (gp-legacy-lines
      false
      (gp-first-ref (gp-id 97) "refs/heads/main" caps)
      rest)))

(test
  git-protocol-legacy-fetch-request-uses-only-advertised-capabilities
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-legacy-advert
          "multi_ack side-band-64k ofs-delta shallow no-progress"
          (str_cat.str-cat
            (gp-id 98)
            " refs/tags/v1|"
            (gp-id 99)
            " refs/tags/v1^{}"))
        (str_cat.str-cat (gp-id 97) "|" (gp-id 99))
        (gp-options true true true))
      (str_cat.str-cat
        "v0 sha1 deepen ofs-delta no-progress wants=2|"
        (gp-line
          (str_cat.str-cat
            "want "
            (gp-id 97)
            " side-band-64k ofs-delta shallow no-progress"))
        (gp-line (str_cat.str-cat "want " (gp-id 99)))
        (gp-line "deepen 1")
        (pkt.git-pkt-flush)
        (gp-line "done")))
    "every option advertised; a peeled ID is an advertised want")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-legacy-advert "side-band-64k" "")
        (gp-id 97)
        (gp-options true true true))
      (str_cat.str-cat
        "v0 sha1 wants=1|"
        (gp-line (str_cat.str-cat "want " (gp-id 97) " side-band-64k"))
        (pkt.git-pkt-flush)
        (gp-line "done")))
    "options the server does not advertise are not sent")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-advert-ok
          (gp-legacy-lines
            true
            (gp-first-ref
              (gp-id256 97)
              "refs/heads/main"
              "side-band-64k object-format=sha256")
            ""))
        (gp-id256 97)
        (gp-options false false false))
      (str_cat.str-cat
        "v1 sha256 wants=1|"
        (gp-line
          (str_cat.str-cat
            "want "
            (gp-id256 97)
            " side-band-64k object-format=sha256"))
        (pkt.git-pkt-flush)
        (gp-line "done")))
    "v1 SHA-256 echoes the object format")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-legacy-advert "ofs-delta" "")
        (gp-id 97)
        (gp-options false false false))
      "!UnsupportedLegacyCapability")
    "pack data must come on side-band-64k")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-legacy-advert "side-band-64k" "")
        (gp-id 98)
        (gp-options false false false))
      "!WantNotAdvertised")
    "an unadvertised want")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-legacy-advert "side-band-64k allow-reachable-sha1-in-want" "")
        (gp-id 98)
        (gp-options false false false))
      (str_cat.str-cat
        "v0 sha1 wants=1|"
        (gp-line (str_cat.str-cat "want " (gp-id 98) " side-band-64k"))
        (pkt.git-pkt-flush)
        (gp-line "done")))
    "an unadvertised want the server allows")
  (gp-require
    (string.eq
      (gp-fetch-request
        (gp-advert-ok
          (gp-legacy-lines
            false
            (gp-first-ref (gp-id 48) "capabilities^{}" "side-band-64k")
            ""))
        (gp-id 97)
        (gp-options false false false))
      "!WantNotAdvertised")
    "an empty repository has nothing to want"))

;; --- fetch responses ---------------------------------------------------------
(define (gp-event-text [event : proto.GitFetchEvent]) : String
  (match event
    [(Continue) ""]
    [(PackBytes bytes) (str_cat.str-cat "pack:" bytes "|")]
    [(Progress text) (str_cat.str-cat "progress:" text "|")]
    [(Shallow id) (str_cat.str-cat "shallow:" (gp-sub (& id.hex) 0 1) "|")]
    [(Complete) "complete|"]
    [(RemoteFailed text) (str_cat.str-cat "remote:" text "|")]
    [(Err error) (str_cat.str-cat "!" (gp-error-name (& error)))]))

;: Push every packet of `stream` through a response parser, stopping at its
;: first error or remote failure.
(define (gp-response [facts : proto.GitFetchFacts] [stream : String]) : String
  (let
    [reader : pkt.GitPktReader (pkt.git-pkt-reader-new)]
    [response : proto.GitFetchResponse
      (proto.git-fetch-response-new facts (proto.GitProtocolLimits 64 8 32 40))]
    [out : String ""]
    (gp-feed (&mut reader) stream)
    (while true
      (match (pkt.git-pkt-reader-next! (&mut reader))
        [(NeedMore) (return out)]
        [(Err error)
          (return (str_cat.str-cat out "!framing:" (gp-error-name (& error))))]
        [(Packet packet)
          (let
            [text : String
              (gp-event-text
                (proto.git-fetch-response-push! (&mut response) packet))]
            (set! out (str_cat.str-cat out text))
            (when
              (or
                (proto.git-protocol-starts-with? (& text) "!")
                (proto.git-protocol-starts-with? (& text) "remote:"))
              (return out)))]))
    out))

(define (gp-v2-facts [deepen : bool]) : proto.GitFetchFacts
  (proto.GitFetchFacts (V2) (Sha1) deepen false false 1))

(define (gp-v0-facts [deepen : bool]) : proto.GitFetchFacts
  (proto.GitFetchFacts (V0) (Sha1) deepen false false 1))

(define (gp-v2-pack-stream) : String
  (str_cat.str-cat
    (gp-line "packfile")
    (gp-band 2 "Enumerating objects: 3\n")
    (gp-band 1 "PACK")
    (gp-band
      1
      (str_cat.str-cat (gp-byte 0) (gp-byte 0) (gp-byte 0) (gp-byte 2)))
    (gp-band 2 "Total 3\r")
    (gp-band 1 "tail")
    (pkt.git-pkt-flush)))

;: The data events of `gp-v2-pack-stream`, before its completion.
(define (gp-v2-pack-data-events) : String
  (str_cat.str-cat
    "progress:Enumerating objects: 3|pack:PACK|pack:"
    (gp-byte 0)
    (gp-byte 0)
    (gp-byte 0)
    (gp-byte 2)
    "|progress:Total 3|pack:tail|"))

(define (gp-v2-pack-events) : String
  (str_cat.str-cat (gp-v2-pack-data-events) "complete|"))

(test
  git-protocol-v2-fetch-response-orders-and-demultiplexes-sections
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (gp-v2-pack-stream))
      (gp-v2-pack-events))
    "a plain packfile section")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts true)
        (str_cat.str-cat
          (gp-line "shallow-info")
          (gp-line (str_cat.str-cat "shallow " (gp-id 97)))
          (gp-line (str_cat.str-cat "shallow " (gp-id 98)))
          (pkt.git-pkt-delim)
          (gp-v2-pack-stream)))
      (str_cat.str-cat "shallow:a|shallow:b|" (gp-v2-pack-events)))
    "shallow-info before the packfile when deepen was sent")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat (gp-line "acknowledgments") (gp-line "NAK")))
      "!UnexpectedSection")
    "acknowledgments after done")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (gp-line "wanted-refs"))
      "!UnexpectedSection")
    "wanted-refs without want-ref")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (gp-line "packfile-uris"))
      "!UnexpectedSection")
    "packfile URIs were not asked for")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (gp-line "shallow-info"))
      "!UnexpectedSection")
    "shallow-info without deepen")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts true) (gp-v2-pack-stream))
      "!MissingShallowInfo")
    "deepen without shallow-info")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts true)
        (str_cat.str-cat
          (gp-line "shallow-info")
          (pkt.git-pkt-delim)
          (gp-line "shallow-info")))
      "!OutOfOrderSection")
    "a repeated section")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts true)
        (str_cat.str-cat
          (gp-line "shallow-info")
          (gp-line (str_cat.str-cat "unshallow " (gp-id 97)))))
      "!UnexpectedUnshallow")
    "unshallow in a fresh fetch")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts true)
        (str_cat.str-cat
          (gp-line "shallow-info")
          (gp-line (str_cat.str-cat "shallow " (gp-id 97)))
          (gp-line (str_cat.str-cat "shallow " (gp-id 97)))))
      "shallow:a|!DuplicateShallow")
    "the same shallow commit twice")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts true)
        (str_cat.str-cat (gp-line "shallow-info") (gp-line "shallow zz")))
      "!MalformedShallow")
    "a malformed shallow ID")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts true)
        (str_cat.str-cat (gp-line "shallow-info") (pkt.git-pkt-flush)))
      "!MalformedSection")
    "the response cannot end inside shallow-info")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (gp-line "objects"))
      "!MalformedSection")
    "an unknown section")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (pkt.git-pkt-flush))
      "!MalformedSection")
    "a response with no packfile")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat
          (gp-line "packfile")
          (gp-band 1 "PACK")
          (pkt.git-pkt-delim)))
      "pack:PACK|!MalformedSection")
    "a delimiter inside the packfile")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat
          (gp-line "packfile")
          (gp-band 3 "disk full\n")
          (gp-band 1 "PACK")))
      "remote:disk full|")
    "a channel-3 fatal error ends the exchange")
  (gp-require
    (string.eq
      (gp-response (gp-v2-facts false) (gp-line "ERR upload-pack: not our ref"))
      "remote:upload-pack: not our ref|")
    "an ERR packet")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat (gp-line "packfile") (gp-pkt "PACK")))
      "!InvalidSideband")
    "pack data must be multiplexed")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat (gp-v2-pack-stream) (pkt.git-pkt-flush)))
      (str_cat.str-cat (gp-v2-pack-events) "!TrailingBytes"))
    "a packet after the terminal flush"))

(test
  git-protocol-fetch-response-bounds-remote-text
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat
          (gp-line "packfile")
          (gp-band 2 "0123456789012345678901234567890123456789")
          (gp-band 2 "abcdefghij")
          (gp-band 2 "klmnopqrst")
          (gp-band 1 "PACK")
          (pkt.git-pkt-flush)))
      "progress:01234567890123456789012345678901|pack:PACK|complete|")
    "progress is cut per message and dropped past the total budget")
  (gp-require
    (string.eq
      (gp-response
        (gp-v2-facts false)
        (str_cat.str-cat
          (gp-line "packfile")
          (gp-band
            3
            (str_cat.str-cat "password=" (gp-byte 27) "]0;owned" (gp-byte 7)))))
      "remote:password=?]0;owned?|")
    "remote text cannot carry terminal control bytes"))

(test
  git-protocol-legacy-fetch-response-reads-shallow-nak-and-sideband
  (gp-require
    (string.eq
      (gp-response
        (gp-v0-facts true)
        (str_cat.str-cat
          (gp-line (str_cat.str-cat "shallow " (gp-id 97)))
          (pkt.git-pkt-flush)
          (gp-line "NAK")
          (gp-band 1 "PACK")
          (pkt.git-pkt-flush)))
      "shallow:a|pack:PACK|complete|")
    "shallow update, NAK, then the pack")
  (gp-require
    (string.eq
      (gp-response
        (gp-v0-facts false)
        (str_cat.str-cat
          (gp-line "NAK")
          (gp-band 2 "Counting\n")
          (gp-band 1 "PACK")
          (pkt.git-pkt-flush)))
      "progress:Counting|pack:PACK|complete|")
    "no shallow update without deepen")
  (gp-require
    (string.eq
      (gp-response
        (gp-v0-facts false)
        (gp-line (str_cat.str-cat "ACK " (gp-id 97))))
      "!MalformedAcknowledgment")
    "an ACK for a request without haves")
  (gp-require
    (string.eq
      (gp-response
        (gp-v0-facts true)
        (gp-line (str_cat.str-cat "unshallow " (gp-id 97))))
      "!UnexpectedUnshallow")
    "unshallow in a fresh fetch")
  (gp-require
    (string.eq
      (gp-response (gp-v0-facts false) (gp-line "ERR upload-pack: not our ref"))
      "remote:upload-pack: not our ref|")
    "an ERR line before the pack")
  (gp-require
    (string.eq
      (gp-response
        (gp-v0-facts true)
        (str_cat.str-cat (gp-line "ERR denied") (pkt.git-pkt-flush)))
      "remote:denied|")
    "an ERR line in the shallow update")
  (gp-require
    (string.eq
      (gp-response (gp-v0-facts false) (pkt.git-pkt-delim))
      "!UnexpectedPacket")
    "a delimiter in a v0 response"))

;; --- the fetch session -------------------------------------------------------
(define (gp-session-event-text [event : proto.GitSessionEvent]) : String
  (match event
    [(NeedInput) ""]
    [(Send bytes) (str_cat.str-cat "send:" bytes "|")]
    [(PackBytes bytes) (str_cat.str-cat "pack:" bytes "|")]
    [(Progress text) (str_cat.str-cat "progress:" text "|")]
    [(Shallow id) (str_cat.str-cat "shallow:" (gp-sub (& id.hex) 0 1) "|")]
    [(Complete facts)
      (str_cat.str-cat "complete:" (gp-facts-text (& facts)) "|")]
    [(RemoteFailed text) (str_cat.str-cat "remote:" text "|")]
    [(Failed error) (str_cat.str-cat "failed:" (gp-error-name (& error)) "|")]))

(define (gp-terminal? [text : (& text str)]) : bool
  (or
    (proto.git-protocol-starts-with? text "complete:")
    (proto.git-protocol-starts-with? text "remote:")
    (proto.git-protocol-starts-with? text "failed:")))

;: Step `session` until it asks for input or reaches a terminal event: the
;: events it reported and whether it is terminal.
(defstruct GpPump
  (text String)
  (terminal bool))

(define (gp-session-pump [session : (&mut session proto.GitSession)]) : GpPump
  (let
    [out : String ""]
    [steps : i64 0]
    (while (< steps 100000)
      (let
        [event : proto.GitSessionEvent (proto.git-session-step! session)]
        [waiting : bool (proto.git-session-waiting? (& event))]
        [text : String (gp-session-event-text event)]
        (set! out (str_cat.str-cat out (string.copy (& text))))
        (when (gp-terminal? (& text)) (return (GpPump out true)))
        (when waiting (return (GpPump out false))))
      (set! steps (+ steps 1)))
    (io.panic "gp-session-pump: the session did not settle")))

(define (gp-wants [text : String]) : (__tl_dyn-array String)
  (let
    [list : (__tl_dyn-array String) (__tl_make-array String 0)]
    [items : (__tl_dyn-array String) (gp-payloads text)]
    [index : i64 0]
    (while (< index (array-length items))
      (let
        [item : String (pkt.git-pkt-text (& (array-ref items index)))]
        (__tl_array-push! list item))
      (set! index (+ index 1)))
    list))

;: Run a session over `stream` fed in two pieces at `split`, then (when `eof`)
;: the end of input; the events it reports, "|"-joined.
(define (gp-session
  [wants : String]
  [options : proto.GitFetchOptions]
  [stream : (& stream str)]
  [split : i64]
  [eof : bool]) : String
  (let
    [session : proto.GitSession
      (proto.git-session-new
        (gp-wants wants)
        options
        (proto.GitProtocolLimits 64 32 64 4096))]
    [count : i64 (string.string-length stream)]
    (proto.git-session-feed! (&mut session) (& (gp-sub stream 0 split)))
    (let
      [first : GpPump (gp-session-pump (&mut session))]
      (when first.terminal (return (string.copy (& first.text))))
      (proto.git-session-feed! (&mut session) (& (gp-sub stream split count)))
      (let
        [second : GpPump (gp-session-pump (&mut session))]
        [out : String
          (str_cat.str-cat
            (string.copy (& first.text))
            (string.copy (& second.text)))]
        (when (or second.terminal (not eof)) (return out))
        (proto.git-session-end-of-input! (&mut session))
        (let
          [last : GpPump (gp-session-pump (&mut session))]
          (str_cat.str-cat out (string.copy (& last.text))))))))

(define (gp-v2-session-stream) : String
  (str_cat.str-cat
    (gp-line "version 2")
    (gp-line "agent=git/2.45.0")
    (gp-line "ls-refs=unborn")
    (gp-line "fetch=shallow")
    (gp-line "object-format=sha1")
    (pkt.git-pkt-flush)
    (gp-line "shallow-info")
    (gp-line (str_cat.str-cat "shallow " (gp-id 97)))
    (pkt.git-pkt-delim)
    (gp-v2-pack-stream)))

(define (gp-v2-session-events) : String
  (str_cat.str-cat
    "send:"
    (gp-line "command=fetch")
    (gp-line "object-format=sha1")
    (pkt.git-pkt-delim)
    (gp-line "ofs-delta")
    (gp-line (str_cat.str-cat "want " (gp-id 97)))
    (gp-line "deepen 1")
    (gp-line "done")
    (pkt.git-pkt-flush)
    "|shallow:a|"
    (gp-v2-pack-data-events)
    "complete:v2 sha1 deepen ofs-delta wants=1|"))

(test
  git-protocol-session-v2-is-independent-of-fragmentation
  (let
    [stream : String (gp-v2-session-stream)]
    [expected : String (gp-v2-session-events)]
    [count : i64 (string.string-length (& stream))]
    [split : i64 0]
    (gp-require
      (string.eq
        (gp-session
          (gp-id 97)
          (gp-options true true false)
          (& stream)
          count
          true)
        (& expected))
      "the whole stream")
    (while (<= split count)
      (gp-require
        (string.eq
          (gp-session
            (gp-id 97)
            (gp-options true true false)
            (& stream)
            split
            true)
          (& expected))
        "a split changes the session's events")
      (set! split (+ split 1)))
    (let
      [session : proto.GitSession
        (proto.git-session-new
          (gp-wants (gp-id 97))
          (gp-options true true false)
          (proto.GitProtocolLimits 64 32 64 4096))]
      [out : String ""]
      [index : i64 0]
      (while (< index count)
        (proto.git-session-feed!
          (&mut session)
          (& (gp-sub (& stream) index (+ index 1))))
        (let
          [pumped : GpPump (gp-session-pump (&mut session))]
          (set! out (str_cat.str-cat out (string.copy (& pumped.text)))))
        (set! index (+ index 1)))
      (gp-require (string.eq (& out) (& expected)) "byte-at-a-time input")
      (gp-require
        (string.eq
          (gp-session-event-text (proto.git-session-step! (&mut session)))
          "complete:v2 sha1 deepen ofs-delta wants=1|")
        "Complete repeats"))))

(test
  git-protocol-session-truncation-is-never-complete
  (let
    [stream : String (gp-v2-session-stream)]
    [count : i64 (string.string-length (& stream))]
    [prefix : i64 0]
    (while (< prefix count)
      (let
        [ended : String
          (gp-session
            (gp-id 97)
            (gp-options true true false)
            (& (gp-sub (& stream) 0 prefix))
            prefix
            true)]
        [waiting : String
          (gp-session
            (gp-id 97)
            (gp-options true true false)
            (& (gp-sub (& stream) 0 prefix))
            prefix
            false)]
        (gp-require
          (or
            (gp-ends-with? (& ended) "failed:TruncatedPacket|")
            (gp-ends-with? (& ended) "failed:TruncatedResponse|"))
          (str_cat.str-cat
            "a truncated stream must fail: "
            (string.int->string prefix)))
        (gp-require
          (not (gp-terminal-anywhere? (& waiting)))
          "a prefix without end of input waits for more"))
      (set! prefix (+ prefix 1)))))

(define (gp-ends-with? [text : (& text str)] [suffix : (& suffix str)]) : bool
  (let
    [count : i64 (string.string-length text)]
    [width : i64 (string.string-length suffix)]
    (and
      (>= count width)
      (string.eq (string.substring text (- count width) width) suffix))))

(define (gp-terminal-anywhere? [text : (& text str)]) : bool
  (or
    (>= (gp-index-of text "complete:") 0)
    (>= (gp-index-of text "failed:") 0)
    (>= (gp-index-of text "remote:") 0)))

(define (gp-index-of [text : (& text str)] [needle : (& needle str)]) : i64
  (let
    [count : i64 (string.string-length text)]
    [width : i64 (string.string-length needle)]
    [index : i64 0]
    (while (<= (+ index width) count)
      (when
        (string.eq (string.substring text index width) needle)
        (return index))
      (set! index (+ index 1)))
    -1))

(test
  git-protocol-session-legacy-over-smart-http
  (let
    [stream : String
      (str_cat.str-cat
        (gp-line "# service=git-upload-pack")
        (pkt.git-pkt-flush)
        (gp-pkt
          (gp-first-ref
            (gp-id 97)
            "refs/heads/main"
            "side-band-64k ofs-delta shallow"))
        (pkt.git-pkt-flush)
        (gp-line (str_cat.str-cat "shallow " (gp-id 97)))
        (pkt.git-pkt-flush)
        (gp-line "NAK")
        (gp-band 1 "PACK")
        (pkt.git-pkt-flush))]
    (gp-require
      (string.eq
        (gp-session (gp-id 97) (gp-options true true false) (& stream) 7 true)
        (str_cat.str-cat
          "send:"
          (gp-line
            (str_cat.str-cat
              "want "
              (gp-id 97)
              " side-band-64k ofs-delta shallow"))
          (gp-line "deepen 1")
          (pkt.git-pkt-flush)
          (gp-line "done")
          "|shallow:a|pack:PACK|complete:v0 sha1 deepen ofs-delta wants=1|"))
      "a v0 exchange behind the smart-HTTP service header"))
  (gp-require
    (string.eq
      (gp-session
        (gp-id 97)
        (gp-options false false false)
        (&
          (str_cat.str-cat
            (gp-line "# service=git-upload-pack")
            (gp-line "version 2")))
        0
        true)
      "failed:MalformedAdvertisement|")
    "the service header must be followed by a flush")
  (gp-require
    (string.eq
      (gp-session
        (gp-id 97)
        (gp-options false false false)
        (& (pkt.git-pkt-flush))
        0
        true)
      "failed:MissingAdvertisement|")
    "a stream that starts with a flush")
  (gp-require
    (string.eq
      (gp-session
        (gp-id 97)
        (gp-options false false false)
        (& (gp-line "ERR access denied or repository not exported: /x"))
        0
        true)
      "remote:access denied or repository not exported: /x|")
    "a git:// server's ERR in place of the advertisement"))

(test
  git-protocol-session-rejects-trailing-and-reports-remote-failure
  (let
    [stream : String (gp-v2-session-stream)]
    [count : i64 (string.string-length (& stream))]
    (gp-require
      (gp-ends-with?
        (&
          (gp-session
            (gp-id 97)
            (gp-options true true false)
            (& (str_cat.str-cat (string.copy (& stream)) "0000"))
            (+ count 4)
            true))
        "failed:TrailingBytes|")
      "bytes after the terminal flush in the same input")
    (let
      [session : proto.GitSession
        (proto.git-session-new
          (gp-wants (gp-id 97))
          (gp-options true true false)
          (gp-limits))]
      (proto.git-session-feed! (&mut session) (& stream))
      (let
        [pumped : GpPump (gp-session-pump (&mut session))]
        (gp-require pumped.terminal "the session completes"))
      (proto.git-session-feed! (&mut session) "x")
      (gp-require
        (string.eq
          (gp-session-event-text (proto.git-session-step! (&mut session)))
          "failed:TrailingBytes|")
        "a later byte after Complete")
      (gp-require
        (string.eq
          (gp-session-event-text (proto.git-session-step! (&mut session)))
          "failed:TrailingBytes|")
        "the failure repeats")))
  (let
    [stream : String
      (str_cat.str-cat
        (gp-line "version 2")
        (gp-line "fetch")
        (pkt.git-pkt-flush)
        (gp-line "packfile")
        (gp-band 1 "PA")
        (gp-band 3 "pack-objects died\n"))]
    [count : i64 (string.string-length (& stream))]
    (gp-require
      (gp-ends-with?
        (&
          (gp-session
            (gp-id 97)
            (gp-options false false false)
            (& stream)
            count
            true))
        "pack:PA|remote:pack-objects died|")
      "a remote failure after some pack data is not Complete"))
  (gp-require
    (string.eq
      (gp-session
        (gp-id256 97)
        (gp-options false false false)
        (&
          (str_cat.str-cat
            (gp-line "version 2")
            (gp-line "fetch")
            (pkt.git-pkt-flush)))
        0
        true)
      "failed:InvalidWant|")
    "a SHA-256 want against a SHA-1 server"))

;; --- deterministic malformed corpus ------------------------------------------
(define (gp-next-random [state : i64]) : i64
  (% (+ (* state 1103515245) 12345) 2147483648))

(define (gp-set-byte [text : (& text str)] [index : i64] [value : i64]) : String
  (str_cat.str-cat
    (gp-sub text 0 index)
    (gp-byte value)
    (gp-sub text (+ index 1) (string.string-length text))))

(test
  git-protocol-session-survives-every-single-byte-mutation
  (let
    [stream : String (gp-v2-session-stream)]
    [count : i64 (string.string-length (& stream))]
    [state : i64 7074]
    [index : i64 0]
    [failures : i64 0]
    [completes : i64 0]
    (while (< index count)
      (set! state (gp-next-random state))
      (let
        [original : i64 (cast (string.string-ref (& stream) index) : i64)]
        [value : i64 (% (+ original 1 (% state 255)) 256)]
        [mutated : String (gp-set-byte (& stream) index value)]
        [first : String
          (gp-session
            (gp-id 97)
            (gp-options true true false)
            (& mutated)
            (% state (+ count 1))
            true)]
        [second : String
          (gp-session
            (gp-id 97)
            (gp-options true true false)
            (& mutated)
            0
            true)]
        (gp-require
          (gp-terminal-anywhere? (& first))
          "a mutated stream settles")
        (gp-require
          (string.eq (& first) (& second))
          "the outcome does not depend on the split")
        (if (>= (gp-index-of (& first) "complete:") 0)
          (set! completes (+ completes 1))
          (set! failures (+ failures 1))))
      (set! index (+ index 1)))
    (gp-require (> failures (/ count 2)) "most mutations are rejected")
    (gp-require (> completes 0) "mutations inside pack bytes still complete")))

(define (gp-corpus-packet [choice : i64]) : String
  (cond
    [(= choice 0) (pkt.git-pkt-flush)]
    [(= choice 1) (pkt.git-pkt-delim)]
    [(= choice 2) (pkt.git-pkt-response-end)]
    [(= choice 3) (gp-line "version 2")]
    [(= choice 4) (gp-line "fetch=shallow")]
    [(= choice 5) (gp-line "packfile")]
    [(= choice 6) (gp-line "shallow-info")]
    [(= choice 7) (gp-line (str_cat.str-cat "shallow " (gp-id 97)))]
    [(= choice 8) (gp-band 1 "PACK")]
    [(= choice 9) (gp-band 2 "progress")]
    [(= choice 10) (gp-band 3 "fatal")]
    [(= choice 11) (gp-line "acknowledgments")]
    [(= choice 12) (gp-line "NAK")]
    [(= choice 13)
      (gp-pkt
        (gp-first-ref (gp-id 97) "refs/heads/main" "side-band-64k shallow"))]
    [(= choice 14) "0003"]
    [(= choice 15) "fff9"]
    [(= choice 16) (gp-line "ERR no")]
    [else (gp-line "object-format=sha256")]))

(test
  git-protocol-session-settles-on-random-packet-sequences
  (let
    [state : i64 8318]
    [round : i64 0]
    (while (< round 400)
      (set! state (gp-next-random state))
      (let
        [length : i64 (+ 1 (% state 12))]
        [stream : String ""]
        [index : i64 0]
        (while (< index length)
          (set! state (gp-next-random state))
          (set!
            stream
            (str_cat.str-cat stream (gp-corpus-packet (% (/ state 7) 18))))
          (set! index (+ index 1)))
        (let
          [first : String
            (gp-session
              (gp-id 97)
              (gp-options true false false)
              (& stream)
              (% state (+ (string.string-length (& stream)) 1))
              true)]
          [second : String
            (gp-session
              (gp-id 97)
              (gp-options true false false)
              (& stream)
              0
              true)]
          (gp-require
            (gp-terminal-anywhere? (& first))
            "a random stream settles")
          (gp-require
            (string.eq (& first) (& second))
            "the outcome does not depend on the split")))
      (set! round (+ round 1)))))