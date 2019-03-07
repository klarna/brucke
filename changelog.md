- 1.12.0
    Make upstream consumer group ID configurable
- 1.12.1/2
    Fix Route config validation
- 1.13.0
    * Update README to document configs
    * Upgrade brod from 2.5.0 to 3.2.0
- 1.13.1
    * Fix discarded route formatting for healthcheck
- 1.14.0
    * Support `required_acks` producer config
- 1.14.1
    * Upgrade brod from 3.2.0 to 3.3.0 to include the fix of heartbeat timeout issue for brod_group_coordinator
    * Add discarded routes to discarded ets after initial validation
- 1.14.3
    * Handle deleted topic
    * Upgrade to brod 3.3.4 --- 1.14.1 will not respect default beging_offset in yml config
- 1.14.4
    * Ensure string (instead of integer array) in healthcheck JSON report
- 1.14.5
    * Fix duplicate upstream topic validation
- 1.15.0
    * Upgrade brod to `3.6.1`
    * Add scram sasl support
    * Support magic-v2 message format (message timestamp and headers).
- 1.15.1
    * Allow single new format message as filter result
- 1.16.0
    * Add reate limit plugin
- 1.17.0
    * Add escript for config validation
    * Logger replace lager
    * Upgrade brod from 3.7.0 to 3.7.2
- 1.17.1
    * Upgrade brod from 3.7.2 to 3.7.5
