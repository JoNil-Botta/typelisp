;# Complete bounded resolver snapshots, with no DNS, socket, cache, or live state.
;# These are immutable-by-API owned values: constructors publish a replacement,
;# accessors borrow it, and no operation mutates a published snapshot.
;# Administrative input errors fail the whole replacement. Unknown resolv.conf
;# directives are ignored with at most 64 retained diagnostics plus a count.
(import stdlib.byte_buf)
(import stdlib.net.dns_name)
(import stdlib.net.ip)
(import stdlib.sort)
(import stdlib.string)

;: Logical source identity. Diagnostics never retain source text or arbitrary paths.
(defenum ConfigSource
  (ConfigExplicit)
  (ConfigHosts)
  (ConfigResolv))

;: Stable failure categories for construction, parsing, and bounded loading.
(defenum ConfigErrorKind
  (ConfigFileTooLarge)
  (ConfigLineTooLong)
  (ConfigTooManyRecords)
  (ConfigTooManyAliases)
  (ConfigTooManyBindings)
  (ConfigTooManyServers)
  (ConfigTooManySuffixes)
  (ConfigSuffixWireLimit)
  (ConfigMalformedDirective)
  (ConfigInvalidAddress ip.IpAddrErrorKind)
  (ConfigInvalidName dns_name.DnsNameErrorKind)
  (ConfigInvalidPort)
  (ConfigInvalidScope)
  (ConfigInvalidTimeout)
  (ConfigUnavailable))

;: One bounded error. Line is one-based for files, zero for explicit values;
;: offset is zero-based in the original byte snapshot. Host status is optional.
(defstruct ConfigError
  (source ConfigSource)
  (line i64)
  (offset i64)
  (kind ConfigErrorKind)
  (host-code i64))

;: Checked endpoint tuple. System parsing always supplies port 53 and scope 0.
(defstruct Nameserver
  (address ip.IpAddr)
  (port u16)
  (scope-id u32))

;: Result of checked explicit endpoint construction.
(defenum NameserverResult
  (NameserverOk Nameserver)
  (NameserverErr ConfigError))

;: One normalized name/address binding. Rootedness does not split hosts keys.
(defstruct HostBinding
  (name dns_name.DnsName)
  (address ip.IpAddr))

;: Immutable-by-API hosts storage, sorted unique indices into bounded bindings.
(defstruct HostsSnapshot
  (bindings (__tl_dyn-array HostBinding))
  (order (__tl_dyn-array i64))
  (len i64))

;: Complete hosts construction result.
(defenum HostsSnapshotResult
  (HostsSnapshotOk HostsSnapshot)
  (HostsSnapshotErr ConfigError))

;: Bounded ordered lookup result. Localhost synthesis is separate policy.
(defstruct HostAddresses
  (slots (__tl_dyn-array ip.IpAddr))
  (len i64))

;: Unsupported directives are diagnosed without copying their input tokens.
(defenum ConfigDiagnosticKind
  (ConfigUnsupportedDirective))

;: Source, location and category of an ignored directive.
(defstruct ConfigDiagnostic
  (source ConfigSource)
  (line i64)
  (offset i64)
  (kind ConfigDiagnosticKind))

;: Complete normalized replacement, built before publication to the caller.
(defstruct ResolverConfig
  (host-data HostsSnapshot)
  (servers (Array Nameserver 8))
  (server-len i64)
  (suffixes (Array dns_name.DnsName 6))
  (suffix-len i64)
  (timeout-ms i64)
  (diagnostics (Array ConfigDiagnostic 64))
  (diagnostic-len i64)
  (ignored-directives i64))

;: Unpublished mutable construction state, distinct from the snapshot type.
(defstruct ConfigBuilder
  (host-data HostsSnapshot)
  (servers (Array Nameserver 8))
  (server-len i64)
  (suffixes (Array dns_name.DnsName 6))
  (suffix-len i64)
  (timeout-ms i64)
  (diagnostics (Array ConfigDiagnostic 64))
  (diagnostic-len i64)
  (ignored-directives i64))

;: Construction never mutates a caller's previous snapshot.
(defenum ResolverConfigResult
  (ResolverConfigOk ResolverConfig)
  (ResolverConfigErr ConfigError))

;: Validation-only result, also used by the Linux adapter.
(defenum ConfigStatus
  (ConfigValid)
  (ConfigInvalid ConfigError))

;: Stable path label for a structured source identity.
(define (source-path [source : ConfigSource]) : String
  (match source
    [(ConfigExplicit) "<explicit>"]
    [(ConfigHosts) "/etc/hosts"]
    [(ConfigResolv) "/etc/resolv.conf"]))

;: Construct a source-local parser error without input retention.
(define (error-at
  [source : ConfigSource]
  [line : i64]
  [offset : i64]
  [kind : ConfigErrorKind]) : ConfigError
  (ConfigError source line offset kind 0))

;: The next newline or the end of a bounded input.
(define (line-end [input : (& input bytes)] [start : i64]) : i64
  (let
    [end : i64 start]
    [length : i64 (byte_buf.bytes-length input)]
    (while (and (< end length) (!= (byte_buf.bytes-ref input end) 10))
      (set! end (+ end 1)))
    end))

;: Validate source size and every complete logical line before allocation.
;: CRLF's terminator is excluded from the 8192-byte logical line limit.
(define (validate-source [input : (& input bytes)] [source : ConfigSource]) : ConfigStatus
  (let
    [length : i64 (byte_buf.bytes-length input)]
    [start : i64 0]
    [line : i64 1]
    (when
      (> length 1048576)
      (return (ConfigInvalid (error-at source 0 1048576 (ConfigFileTooLarge)))))
    (while (< start length)
      (let
        [end : i64 (line-end input start)]
        [logical-end : i64
          (if (and (> end start) (= (byte_buf.bytes-ref input (- end 1)) 13))
            (- end 1)
            end)]
        (when
          (> (- logical-end start) 8192)
          (return
            (ConfigInvalid
              (error-at source line (+ start 8192) (ConfigLineTooLong)))))
        (set!
          start
          (if (< end length)
            (+ end 1)
            end)))
      (set! line (+ line 1)))
    (ConfigValid)))

;: Spaces and tabs separate administrative input tokens.
(define (space? [value : u8]) : bool
  (or (= value 32) (= value 9)))

;: Remove comments and an optional CR from one prevalidated line.
(define (content-end
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [resolv : bool]) : i64
  (let
    [cursor : i64 start]
    (while (< cursor end)
      (let
        [value : u8 (byte_buf.bytes-ref input cursor)]
        (when (or (= value 35) (and resolv (= value 59))) (return cursor)))
      (set! cursor (+ cursor 1)))
    (if (and (> end start) (= (byte_buf.bytes-ref input (- end 1)) 13))
      (- end 1)
      end)))

;: Skip spaces and tabs within a checked line.
(define (skip-space [input : (& input bytes)] [start : i64] [end : i64]) : i64
  (let
    [cursor : i64 start]
    (while (and (< cursor end) (space? (byte_buf.bytes-ref input cursor)))
      (set! cursor (+ cursor 1)))
    cursor))

;: Find the end of a token within a checked line.
(define (token-end [input : (& input bytes)] [start : i64] [end : i64]) : i64
  (let
    [cursor : i64 start]
    (while (and (< cursor end) (not (space? (byte_buf.bytes-ref input cursor))))
      (set! cursor (+ cursor 1)))
    cursor))

;: Parse a bounded IP token with the canonical public codec, without copying a
;: potentially 8192-byte invalid token into a String.
(define (parse-address [input : (& input bytes)] [start : i64] [end : i64]) : ip.IpAddrResult
  (if (> (- end start) 45)
    (IpErr (ip.IpAddrError (IpInputTooLong) 45))
    (let
      [token : String
        (byte_buf.bytes-to-string
          (byte_buf.bytes-slice-view input start (- end start)))]
      (ip.parse-ip (& token)))))

;: IPv6 first, then ascending network bytes within each distinct family.
(define (address-compare
  [left : (& left ip.IpAddr)]
  [right : (& right ip.IpAddr)]) : i64
  (match left
    [(V6 a)
      (match right
        [(V6 b) (ip.ipv6-compare (& a) (& b))]
        [(V4 _) -1])]
    [(V4 a)
      (match right
        [(V4 b) (ip.ipv4-compare (& a) (& b))]
        [(V6 _) 1])]))

;: Compare host keys, ignoring the optional final dot.
(define (name-compare
  [left : (& left dns_name.DnsName)]
  [right : (& right dns_name.DnsName)]) : i64
  (cond
    [(string.eq (dns_name.text left) (dns_name.text right)) 0]
    [(sort.string-less-borrowed? (dns_name.text left) (dns_name.text right)) -1]
    [else 1]))

;: Compare two indices without cloning retained name storage.
(define (binding-compare
  [bindings : (& bindings (__tl_dyn-array HostBinding))]
  [left : i64]
  [right : i64]) : i64
  (let
    [a : (& bindings HostBinding) (& (array-ref bindings left))]
    [b : (& bindings HostBinding) (& (array-ref bindings right))]
    [names : i64 (name-compare (& a.name) (& b.name))]
    (if (= names 0)
      (address-compare (& a.address) (& b.address))
      names)))

;: Sift an index heap in place; bounded arithmetic uses at most 16384 entries.
(define (sift-indices!
  [order : (&mut order (__tl_dyn-array i64))]
  [bindings : (& bindings (__tl_dyn-array HostBinding))]
  [root : i64]
  [length : i64]) : unit
  (let
    [parent : i64 root]
    (while (< (+ (* parent 2) 1) length)
      (let
        [child : i64 (+ (* parent 2) 1)]
        (when
          (and
            (< (+ child 1) length)
            (<
              (binding-compare
                bindings
                (array-ref order child)
                (array-ref order (+ child 1)))
              0))
          (set! child (+ child 1)))
        (when
          (>=
            (binding-compare
              bindings
              (array-ref order parent)
              (array-ref order child))
            0)
          (return unit))
        (let
          [saved : i64 (array-ref order parent)]
          (set! (array-ref order parent) (array-ref order child))
          (set! (array-ref order child) saved))
        (set! parent child)))))

;: Sort binding indices in O(n log n), then compact exact duplicate tuples.
(define (finish-hosts [bindings : (__tl_dyn-array HostBinding)] [length : i64]) : HostsSnapshot
  (let
    [order : (__tl_dyn-array i64) (__tl_make-array i64 length)]
    [cursor : i64 0]
    (while (< cursor length)
      (set! (array-ref order cursor) cursor)
      (set! cursor (+ cursor 1)))
    (set! cursor (/ length 2))
    (while (> cursor 0)
      (set! cursor (- cursor 1))
      (sift-indices! (&mut order) (& bindings) cursor length))
    (set! cursor (- length 1))
    (while (> cursor 0)
      (let
        [saved : i64 (array-ref order 0)]
        (set! (array-ref order 0) (array-ref order cursor))
        (set! (array-ref order cursor) saved))
      (sift-indices! (&mut order) (& bindings) 0 cursor)
      (set! cursor (- cursor 1)))
    (let
      [unique : i64 0]
      (set! cursor 0)
      (while (< cursor length)
        (let
          [index : i64 (array-ref order cursor)]
          (when
            (or
              (= unique 0)
              (!=
                (binding-compare
                  (& bindings)
                  (array-ref order (- unique 1))
                  index)
                0))
            (set! (array-ref order unique) index)
            (set! unique (+ unique 1))))
        (set! cursor (+ cursor 1)))
      (HostsSnapshot bindings order unique))))

;: Parse a complete hosts byte snapshot. Bounds count input records/bindings,
;: including duplicates, before sorting or deduplication can reduce them.
(define (parse-hosts [input : (& input bytes)]) : HostsSnapshotResult
  (match (validate-source input (ConfigHosts))
    [(ConfigInvalid error) (return (HostsSnapshotErr error))]
    [(ConfigValid) unit])
  (let
    [length : i64 (byte_buf.bytes-length input)]
    [capacity : i64
      (if (< length 16384)
        length
        16384)]
    [bindings : (__tl_dyn-array HostBinding)
      (__tl_make-array HostBinding capacity)]
    [count : i64 0]
    [records : i64 0]
    [start : i64 0]
    [line : i64 1]
    (while (< start length)
      (let
        [end : i64 (line-end input start)]
        [content : i64 (content-end input start end false)]
        [cursor : i64 (skip-space input start content)]
        (when
          (< cursor content)
          (set! records (+ records 1))
          (when
            (> records 4096)
            (return
              (HostsSnapshotErr
                (error-at (ConfigHosts) line cursor (ConfigTooManyRecords)))))
          (let
            [address-end : i64 (token-end input cursor content)]
            (match (parse-address input cursor address-end)
              [(IpErr error)
                (return
                  (HostsSnapshotErr
                    (error-at
                      (ConfigHosts)
                      line
                      (+ cursor error.offset)
                      (ConfigInvalidAddress error.kind))))]
              [(IpOk address)
                (set! cursor (skip-space input address-end content))
                (when
                  (= cursor content)
                  (return
                    (HostsSnapshotErr
                      (error-at
                        (ConfigHosts)
                        line
                        cursor
                        (ConfigMalformedDirective)))))
                (let
                  [names : i64 0]
                  (while (< cursor content)
                    (when
                      (>= names 17)
                      (return
                        (HostsSnapshotErr
                          (error-at
                            (ConfigHosts)
                            line
                            cursor
                            (ConfigTooManyAliases)))))
                    (when
                      (>= count 16384)
                      (return
                        (HostsSnapshotErr
                          (error-at
                            (ConfigHosts)
                            line
                            cursor
                            (ConfigTooManyBindings)))))
                    (let
                      [name-end : i64 (token-end input cursor content)]
                      (match (dns_name.parse-bytes
                        (byte_buf.bytes-slice-view
                          input
                          cursor
                          (- name-end cursor)))
                        [(DnsNameErr error)
                          (return
                            (HostsSnapshotErr
                              (error-at
                                (ConfigHosts)
                                line
                                (+ cursor error.offset)
                                (ConfigInvalidName error.kind))))]
                        [(DnsNameOk name)
                          (set!
                            (array-ref bindings count)
                            (HostBinding name (clone address)))
                          (set! count (+ count 1))])
                      (set! names (+ names 1))
                      (set! cursor (skip-space input name-end content)))))])))
        (set!
          start
          (if (< end length)
            (+ end 1)
            end)))
      (set! line (+ line 1)))
    (HostsSnapshotOk (finish-hosts bindings count))))

;: Borrow a unique binding by its sorted position.
(define (binding-ref [snapshot : (& snapshot HostsSnapshot)] [index : i64]) : (&
    snapshot
    HostBinding)
  (byte_buf.check-range snapshot.len index 1)
  (& (array-ref snapshot.bindings (array-ref snapshot.order index))))

;: Unique name/address binding count.
(define (binding-count [snapshot : (& snapshot HostsSnapshot)]) : i64
  snapshot.len)

;: Binary-search normalized names, then return every address in fixed order.
;: Callers implement localhost policy before consulting this administrative map.
(define (hosts-lookup
  [snapshot : (& snapshot HostsSnapshot)]
  [name : (& name dns_name.DnsName)]) : HostAddresses
  (let
    [low : i64 0]
    [high : i64 snapshot.len]
    (while (< low high)
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        [binding : (& snapshot HostBinding) (binding-ref snapshot middle)]
        (if (< (name-compare (& binding.name) name) 0)
          (set! low (+ middle 1))
          (set! high middle))))
    (let
      [end : i64 low]
      (while (and
        (< end snapshot.len)
        (let
          [binding : (& snapshot HostBinding) (binding-ref snapshot end)]
          (= (name-compare (& binding.name) name) 0)))
        (set! end (+ end 1)))
      (let
        [slots : (__tl_dyn-array ip.IpAddr)
          (__tl_make-array ip.IpAddr (- end low))]
        [cursor : i64 low]
        (while (< cursor end)
          (let
            [binding : (& snapshot HostBinding) (binding-ref snapshot cursor)]
            (set! (array-ref slots (- cursor low)) (clone binding.address)))
          (set! cursor (+ cursor 1)))
        (HostAddresses slots (- end low))))))

;: Address result count.
(define (address-count [addresses : (& addresses HostAddresses)]) : i64
  addresses.len)

;: Copy one canonical address by checked index.
(define (address-ref [addresses : (& addresses HostAddresses)] [index : i64]) : ip.IpAddr
  (byte_buf.check-range addresses.len index 1)
  (clone (array-ref addresses.slots index)))

;: Reserved localhost policy result, independent of all administrative hosts
;: entries. Consumers test dns_name.localhost? before hosts lookup or DNS.
(define (localhost-addresses) : HostAddresses
  (let
    [slots : (__tl_dyn-array ip.IpAddr) (__tl_make-array ip.IpAddr 2)]
    (set! (array-ref slots 0) (V6 (ip.ipv6 0 0 0 0 0 0 0 1)))
    (set! (array-ref slots 1) (V4 (ip.ipv4 127 0 0 1)))
    (HostAddresses slots 2)))

;: Checked explicit endpoint constructor; no zone text or narrowing casts.
(define (nameserver [address : ip.IpAddr] [port : i64] [scope-id : i64]) : NameserverResult
  (when
    (or (< port 1) (> port 65535))
    (return (NameserverErr (error-at (ConfigExplicit) 0 0 (ConfigInvalidPort)))))
  (when
    (or (< scope-id 0) (> scope-id 4294967295))
    (return
      (NameserverErr (error-at (ConfigExplicit) 0 0 (ConfigInvalidScope)))))
  (match address
    [(V4 _)
      (when
        (!= scope-id 0)
        (return
          (NameserverErr (error-at (ConfigExplicit) 0 0 (ConfigInvalidScope)))))]
    [(V6 _) unit])
  (NameserverOk (Nameserver address (cast port : u16) (cast scope-id : u32))))

;: A complete tuple is the endpoint deduplication key.
(define (server-equal?
  [left : (& left Nameserver)]
  [right : (& right Nameserver)]) : bool
  (and
    (= left.port right.port)
    (= left.scope-id right.scope-id)
    (ip.ip-eq? (& left.address) (& right.address))))

;: Internal unpublished builder with fixed bounded configuration arrays.
(define (empty-config [host-data : HostsSnapshot]) : ConfigBuilder
  (ConfigBuilder
    host-data
    (init : (Array Nameserver 8))
    0
    (init : (Array dns_name.DnsName 6))
    0
    1000
    (init : (Array ConfigDiagnostic 64))
    0
    0))

;: Consume completed construction state and publish one owned snapshot.
(define (finish-config [builder : ConfigBuilder]) : ResolverConfig
  (ResolverConfig
    builder.host-data
    builder.servers
    builder.server-len
    builder.suffixes
    builder.suffix-len
    builder.timeout-ms
    builder.diagnostics
    builder.diagnostic-len
    builder.ignored-directives))

;: Validate a server even if its public record was built without the constructor.
;: Only the unpublished local builder is mutated.
(define (add-server!
  [builder : (&mut builder ConfigBuilder)]
  [server : Nameserver]
  [source : ConfigSource]
  [line : i64]
  [offset : i64]) : ConfigStatus
  (when
    (= server.port 0)
    (return (ConfigInvalid (error-at source line offset (ConfigInvalidPort)))))
  (match server.address
    [(V4 _)
      (when
        (!= server.scope-id 0)
        (return
          (ConfigInvalid (error-at source line offset (ConfigInvalidScope)))))]
    [(V6 _) unit])
  (let
    [index : i64 0]
    (while (< index builder.server-len)
      (when
        (server-equal? (& (array-ref builder.servers index)) (& server))
        (return (ConfigValid)))
      (set! index (+ index 1))))
  (when
    (= builder.server-len 8)
    (return
      (ConfigInvalid (error-at source line offset (ConfigTooManyServers)))))
  (set! (array-ref builder.servers builder.server-len) server)
  (set! builder.server-len (+ builder.server-len 1))
  (ConfigValid))

;: Checked ordered suffix insertion. Duplicate suffixes retain declared order.
(define (add-suffix!
  [builder : (&mut builder ConfigBuilder)]
  [name : dns_name.DnsName]
  [source : ConfigSource]
  [line : i64]
  [offset : i64]) : ConfigStatus
  (when
    (= builder.suffix-len 6)
    (return
      (ConfigInvalid (error-at source line offset (ConfigTooManySuffixes)))))
  (let
    [wire : i64 (dns_name.wire-length (& name))]
    [index : i64 0]
    (while (< index builder.suffix-len)
      (set!
        wire
        (+ wire (dns_name.wire-length (& (array-ref builder.suffixes index)))))
      (set! index (+ index 1)))
    (when
      (> wire 256)
      (return
        (ConfigInvalid (error-at source line offset (ConfigSuffixWireLimit))))))
  (set! (array-ref builder.suffixes builder.suffix-len) name)
  (set! builder.suffix-len (+ builder.suffix-len 1))
  (ConfigValid))

;: Construct from explicit values/hosts bytes, without any ambient state.
;: Snapshot inputs are copied/normalized and do not alias mutable caller buffers.
(define (from-explicit
  [servers : (& servers (Slice Nameserver))]
  [suffixes : (& suffixes (Slice String))]
  [hosts-input : (& hosts-input bytes)]
  [timeout-ms : i64]) : ResolverConfigResult
  (when
    (or (< timeout-ms 1) (> timeout-ms 30000))
    (return
      (ResolverConfigErr (error-at (ConfigExplicit) 0 0 (ConfigInvalidTimeout)))))
  (when
    (> (array-length servers) 8)
    (return
      (ResolverConfigErr (error-at (ConfigExplicit) 0 8 (ConfigTooManyServers)))))
  (when
    (> (array-length suffixes) 6)
    (return
      (ResolverConfigErr
        (error-at (ConfigExplicit) 0 6 (ConfigTooManySuffixes)))))
  (match (parse-hosts hosts-input)
    [(HostsSnapshotErr error) (ResolverConfigErr error)]
    [(HostsSnapshotOk host-data)
      (let
        [builder : ConfigBuilder (empty-config host-data)]
        [index : i64 0]
        (set! builder.timeout-ms timeout-ms)
        (while (< index (array-length servers))
          (match (add-server!
            (&mut builder)
            (clone (array-ref servers index))
            (ConfigExplicit)
            0
            index)
            [(ConfigInvalid error) (return (ResolverConfigErr error))]
            [(ConfigValid) unit])
          (set! index (+ index 1)))
        (set! index 0)
        (while (< index (array-length suffixes))
          (match (dns_name.parse (& (array-ref suffixes index)))
            [(DnsNameErr error)
              (return
                (ResolverConfigErr
                  (error-at
                    (ConfigExplicit)
                    0
                    error.offset
                    (ConfigInvalidName error.kind))))]
            [(DnsNameOk name)
              (match (add-suffix! (&mut builder) name (ConfigExplicit) 0 index)
                [(ConfigInvalid error) (return (ResolverConfigErr error))]
                [(ConfigValid) unit])])
          (set! index (+ index 1)))
        (ResolverConfigOk (finish-config builder)))]))

;: Parse the Linux strict subset from two injected byte snapshots. A supported
;: malformed directive fails; an unknown directive yields one bounded diagnostic.
;: Last search/domain wins, including an empty search list. No ambient defaults.
(define (parse-linux
  [hosts-input : (& hosts-input bytes)]
  [resolv-input : (& resolv-input bytes)]) : ResolverConfigResult
  (match (validate-source resolv-input (ConfigResolv))
    [(ConfigInvalid error) (return (ResolverConfigErr error))]
    [(ConfigValid) unit])
  (match (parse-hosts hosts-input)
    [(HostsSnapshotErr error) (ResolverConfigErr error)]
    [(HostsSnapshotOk host-data)
      (let
        [builder : ConfigBuilder (empty-config host-data)]
        [length : i64 (byte_buf.bytes-length resolv-input)]
        [start : i64 0]
        [line : i64 1]
        (while (< start length)
          (let
            [end : i64 (line-end resolv-input start)]
            [content : i64 (content-end resolv-input start end true)]
            [cursor : i64 (skip-space resolv-input start content)]
            (when
              (< cursor content)
              (let
                [keyword-end : i64 (token-end resolv-input cursor content)]
                [keyword : String
                  (byte_buf.bytes-to-string
                    (byte_buf.bytes-slice-view
                      resolv-input
                      cursor
                      (- keyword-end cursor)))]
                [directive-offset : i64 cursor]
                (set! cursor (skip-space resolv-input keyword-end content))
                (cond
                  [(string.eq (& keyword) "nameserver")
                    (let
                      [value-end : i64 (token-end resolv-input cursor content)]
                      (when
                        (or
                          (= cursor content)
                          (!=
                            (skip-space resolv-input value-end content)
                            content))
                        (return
                          (ResolverConfigErr
                            (error-at
                              (ConfigResolv)
                              line
                              cursor
                              (ConfigMalformedDirective)))))
                      (match (parse-address resolv-input cursor value-end)
                        [(IpErr error)
                          (return
                            (ResolverConfigErr
                              (error-at
                                (ConfigResolv)
                                line
                                (+ cursor error.offset)
                                (ConfigInvalidAddress error.kind))))]
                        [(IpOk address)
                          (match (add-server!
                            (&mut builder)
                            (Nameserver address 53 0)
                            (ConfigResolv)
                            line
                            cursor)
                            [(ConfigInvalid error)
                              (return (ResolverConfigErr error))]
                            [(ConfigValid) unit])]))]
                  [(or
                    (string.eq (& keyword) "search")
                    (string.eq (& keyword) "domain"))
                    (set! builder.suffix-len 0)
                    (when
                      (and (string.eq (& keyword) "domain") (= cursor content))
                      (return
                        (ResolverConfigErr
                          (error-at
                            (ConfigResolv)
                            line
                            cursor
                            (ConfigMalformedDirective)))))
                    (while (< cursor content)
                      (let
                        [value-end : i64
                          (token-end resolv-input cursor content)]
                        (match (dns_name.parse-bytes
                          (byte_buf.bytes-slice-view
                            resolv-input
                            cursor
                            (- value-end cursor)))
                          [(DnsNameErr error)
                            (return
                              (ResolverConfigErr
                                (error-at
                                  (ConfigResolv)
                                  line
                                  (+ cursor error.offset)
                                  (ConfigInvalidName error.kind))))]
                          [(DnsNameOk name)
                            (match (add-suffix!
                              (&mut builder)
                              name
                              (ConfigResolv)
                              line
                              cursor)
                              [(ConfigInvalid error)
                                (return (ResolverConfigErr error))]
                              [(ConfigValid) unit])])
                        (set!
                          cursor
                          (skip-space resolv-input value-end content))
                        (when
                          (and
                            (string.eq (& keyword) "domain")
                            (< cursor content))
                          (return
                            (ResolverConfigErr
                              (error-at
                                (ConfigResolv)
                                line
                                cursor
                                (ConfigMalformedDirective)))))))]
                  [else
                    (when
                      (< builder.diagnostic-len 64)
                      (set!
                        (array-ref builder.diagnostics builder.diagnostic-len)
                        (ConfigDiagnostic
                          (ConfigResolv)
                          line
                          directive-offset
                          (ConfigUnsupportedDirective)))
                      (set! builder.diagnostic-len (+ builder.diagnostic-len 1)))
                    (set!
                      builder.ignored-directives
                      (+ builder.ignored-directives 1))])))
            (set!
              start
              (if (< end length)
                (+ end 1)
                end)))
          (set! line (+ line 1)))
        (ResolverConfigOk (finish-config builder)))]))

;: Borrow the immutable administrative hosts data.
(define (hosts [snapshot : (& snapshot ResolverConfig)]) : (&
    snapshot
    HostsSnapshot)
  (& snapshot.host-data))

;: Number of distinct server tuples, in first-occurrence order.
(define (server-count [snapshot : (& snapshot ResolverConfig)]) : i64
  snapshot.server-len)

;: Borrow one normalized server tuple.
(define (server-ref [snapshot : (& snapshot ResolverConfig)] [index : i64]) : (&
    snapshot
    Nameserver)
  (byte_buf.check-range snapshot.server-len index 1)
  (& (array-ref snapshot.servers index)))

;: Number of configured suffixes, in declared order.
(define (suffix-count [snapshot : (& snapshot ResolverConfig)]) : i64
  snapshot.suffix-len)

;: Borrow one normalized suffix, retaining its rooted identity.
(define (suffix-ref [snapshot : (& snapshot ResolverConfig)] [index : i64]) : (&
    snapshot
    dns_name.DnsName)
  (byte_buf.check-range snapshot.suffix-len index 1)
  (& (array-ref snapshot.suffixes index)))

;: Checked positive per-attempt timeout in monotonic milliseconds.
(define (attempt-timeout-ms [snapshot : (& snapshot ResolverConfig)]) : i64
  snapshot.timeout-ms)

;: Number of retained unsupported-directive diagnostics (at most 64).
(define (diagnostic-count [snapshot : (& snapshot ResolverConfig)]) : i64
  snapshot.diagnostic-len)

;: Borrow a bounded diagnostic. Its category is always unsupported directive.
(define (diagnostic-ref [snapshot : (& snapshot ResolverConfig)] [index : i64]) : (&
    snapshot
    ConfigDiagnostic)
  (byte_buf.check-range snapshot.diagnostic-len index 1)
  (& (array-ref snapshot.diagnostics index)))

;: Total ignored directives, including diagnostics omitted after the cap.
(define (ignored-directive-count [snapshot : (& snapshot ResolverConfig)]) : i64
  snapshot.ignored-directives)