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
