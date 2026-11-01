;# Exercise all resolver snapshot imports through source and embedded stdlib.
(import stdlib.byte_buf)
(import stdlib.net.dns_name)
(import stdlib.net.resolver_config)
(import stdlib.net.resolver_config_linux)

(define (fixture-source [source : resolver_config.ConfigSource]) : resolver_config_linux.ConfigBytesResult
  (match source
    [(ConfigHosts)
      (ConfigBytesOk (byte_buf.append-string (byte_buf.new) "::1 fixture"))]
    [(ConfigResolv)
      (ConfigBytesOk
        (byte_buf.append-string
          (byte_buf.new)
          "nameserver ::1\nsearch example."))]
    [(ConfigExplicit)
      (ConfigBytesErr (resolver_config_linux.unavailable source 22))]))

(define (main) : i64
  (match (resolver_config_linux.load-with-source fixture-source)
    [(ResolverConfigErr _) 1]
    [(ResolverConfigOk snapshot)
      (if (and
        (= (resolver_config.server-count (& snapshot)) 1)
        (= (resolver_config.suffix-count (& snapshot)) 1)
        (dns_name.rooted? (resolver_config.suffix-ref (& snapshot) 0))
        (= (resolver_config.attempt-timeout-ms (& snapshot)) 1000))
        42
        2)]))