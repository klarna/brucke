[![Build Status](https://travis-ci.org/klarna/brucke.svg)](https://travis-ci.org/klarna/brucke) [![Coverage Status](https://coveralls.io/repos/github/klarna/brucke/badge.svg?branch=master)](https://coveralls.io/github/klarna/brucke?branch=master)

# Brucke - Inter-cluster bridge of kafka topics
Brucke is a Inter-cluster bridge of kafka topics powered by [Brod](https://github.com/klarna/brod)

Brucke bridges messages from upstream topic to downstream topic with
configurable re-partitionning strategy and message filter/transform plugins

# Configuration

A brucke config file is a YAML file.

Config file path should be set in config_file variable of brucke app config, or via `BRUCKE_CONFIG_FILE` OS env variable.

Cluster names and client names must comply to erlang atom syntax.

    kafka_clusters:
      kafka_cluster_1:
        - "localhost:9092"
      kafka_cluster_2:
        - "kafka-1:9092"
        - "kafka-2:9092"
    brod_clients:
      - client: brod_client_1
        cluster: kafka_cluster_1
        config: [] # optional
      - client: brod_client_2 # example for SSL connection
        cluster: kafka_cluster_1
        config:
          ssl: true
      - client: brod_client_3 # example for SASL_SSL and custom certificates
        cluster: kafka_cluster_1
        config:
          ssl:
            # start with "priv/" or provide full path
            cacertfile: priv/ssl/ca.crt
            certfile: priv/ssl/client.crt
            keyfile: priv/ssl/client.key
          sasl:
            # or 'plain' or 'scram_sha_256'
            mechanism: scram_sha_512
            username: brucke
            password: secret
    routes:
      - upstream_client: brod_client_1
        downstream_client: brod_client_1
        upstream_topics:
          - "topic_1"
        downstream_topic: "topic_2"
        repartitioning_strategy: strict_p2p
        default_begin_offset: earliest # optional
        filter_module: brucke_filter # optional
        filter_init_arg: "" # optional
        upstream_cg_id: example-consumer-group-1 # optional, build from cluster name otherwise

## Client Configs

- `ssl` Either set to `true` or be specific about the cert/key files to use
        `cacertfile`, `certfile` and `keyfile`. In case the file paths start with `priv/`
        `brucke` will look in application `priv` dir (i.e. `code:priv_dir(brucke)`).
- `sasl` Configure SASL auth `mechanism`, `username` and `password` for SASL PLAIN authentication.
- `query_api_versions` Set to `false` when connecting to kafka 0.9.x or earlier

See more configs in `brod:start_client/4` API doc.

## Routing Configs

### Upstream Consumer Group ID

`upstream_cg_id` identifies the consumer group which route workers (maybe distributed across different Erlang nodes) should join in, and commit offsets to.
Group IDs don't have to be unique, two or more routes may share the same group ID.
However, the same topic may not appear in two routes share the same group ID.

### Default Begin Offset

The `default_begin_offset` route config is to tell upstream consumer from where to start streaming messsages.
Supported values are `earliest`, `latest` (default) or a kafka offset (integer) value.
This config is to tell brucke route worker from which offset it should start streaming messages for the first run.
In case of restart, brucke should continue from committed offset.

NOTE: Offsets committed to kafka may expire, in that case, brucke will fallback to this default being offset.
NOTE: Currently this option is used for ALL partitions in upstream topic(s).

In case there is a need to discard committed offsets, pick a new group ID.

### Offset Commit Policy
The `Offset_commit_policy` specify how upstream consumer manages the offset per topic-partition.
Two values are available: `commit_to_kafka_v2` or `consumer_managed`.
when `consumer_managed` is used, topic-partition offsets will be stored in dets (set). see "PATH to offsets DETS file".

default: `commit_to_kafka_v2`

### Repartitioning strategy

NOTE: For compacted topics, strict_p2p is the only choice.

- key_hash: hash the message key to downstream partition number
- strict_p2p: strictly map the upstream partition number to downstream partition number, worker will refuse to start if
upstream and downstream topic has different number of partitions
- random: randomly distribute upstream messages to downstream partitions

### Message Transformation

Depending on message format version in kafka broker, possible message formats from kafka are

- Version 0: key-value without timestamp (kafka prior to `0.10`)
- Version 1: key-value with timestamp (since kafka `0.10`)
- Version 2: key-value with headers and timestamp (since kafka `0.11`)

When downstream kafka supports lower version than upstream, unsupported fields are dropped.
Otherwise messages are upgraded using default values as below:
- Local host's OS time is used as default timestamp if upstream message message has no `create` timestamp
- Empty list `[]` is used as default `headers` field for downstream message if upstream message has no `headers`

### Customized Message Filtering and or Transformation

Implement `brucke_filter` behaviour to have messages filtered and or transformed before produced to downstream topic.

If `brucke` is packed standalone (i.e. not used as a dependency in a parent project), and the beam files for
`brucke_filter` modules are installed elsewhere, configure `filter_ebin_dirs` app env (sys.config),
or set system OS env variables `BRUCKE_FILTER_EBIN_PATHS`.

### Other Routing Options

- `compression`: `no_compression` (defulat), `gzip` or `snappy`
- `max_partitions_per_group_member`: default = 12, Number of partitions one group member should work on.
- `required_acks`: `all` (default), `leader` or `none`


## Offsets DETS file
You can config brucke where to start consuming by providing the none empty 'Offsets DETS file' when brucke starts.

It should be set table and the record should be in following spec:

```
{ {GroupID :: binary() , Topic :: binary(), Partition :: non_neg_integer() }, Offset :: -1 | non_neg_integer() }.
```

`offsets_dets_path` specify the PATH to the offsets dets file which is used by 'Offset Commit Policy'.
If file does not exists, brucke will create empty one and use it.
default: "/tmp/brucke_offsets.DETS"

## ratelimit
Ratelimit the number of messages produced to downstream.

`ratelimit_interval`  defines the interval in milliseconds,  default: 0 means disabled.
`ratelimit_threshold` defines the threshold, set to 0 to pause.

You can change these two settings in realtime via restapi.

example:

Limit the msg rate of consumer group: `group1` of cluster: `clusterA` to 10 msgs/s:

```
POST /plugins/ratelimiter/clusterA/group1
{"interval": "100", "threshold", "1"}

```

# Graphite reporting

If the following app config variables are set, brucke will send metrics to a configured graphite endpoint:

- graphite_root_path: a prefix for metrics, e.g "myservice"
- graphite_host: e.g. "localhost"
- graphite_port: e.g. 2003

Alternatively, you can use corresponding OS env variables:

- BRUCKE_GRAPHITE_ROOT_PATH
- BRUCKE_GRAPHITE_HOST
- BRUCKE_GRAPHITE_PORT

# RPM packaging

Generate a release and package it into an rpm package:

    make rpm

Brucke package installs release and creates corresponding systemd service. Config files are in /etc/brucke, OS env can
be set at /etc/sysconfig/brucke, logs are in /var/log/brucke.

Operating via systemctl:

    systemctl start brucke
    systemctl enable brucke
    systemctl status brucke

# Script for config validation

Build:
```
make escript
```

Usage:
```
brucke <path/to/config.yml>
```

Set `BRUCKE_FILTER_MODULE_BEAM_DIRS` for extra filter module beam lookup.
For valid configs the validation command should silently exit with code 0.

# Http Endpoint for Healcheck

Default port is 8080, customize via `http_port` config option or via `BRUCKE_HTTP_PORT` OS env variable.

    GET /ping
Returns `pong` if the application is up and running.

    GET /healthcheck
Responds with status 200 if everything is OK, and 500 if something is not OK.
Also returns healthy and unhealthy routes in response body in JSON format.

Example response:

    {
        "discarded": [
            {
                "downstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9192
                        }
                    ],
                    "topic": "brucke-filter-test-downstream"
                },
                "options": {
                    "default_begin_offset": "earliest",
                    "filter_init_arg": [],
                    "filter_module": "brucke_test_filter",
                    "repartitioning_strategy": "strict_p2p"
                },
                "reason": [
                    "filter module brucke_test_filter is not found\nreason:embedded\n"
                ],
                "upstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9092
                        }
                    ],
                    "topics": [
                        "brucke-filter-test-upstream"
                    ]
                }
            }
        ],
        "healthy": [
            {
                "downstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9192
                        }
                    ],
                    "topic": "brucke-basic-test-downstream"
                },
                "options": {
                    "consumer_config": {
                        "begin_offset": "earliest"
                    },
                    "filter_init_arg": [],
                    "filter_module": "brucke_filter",
                    "max_partitions_per_group_member": 12,
                    "producer_config": {
                        "compression": "no_compression"
                    },
                    "repartitioning_strategy": "strict_p2p"
                },
                "upstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9092
                        }
                    ],
                    "topics": "brucke-basic-test-upstream"
                }
            },
            {
                "downstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9092
                        }
                    ],
                    "topic": "brucke-test-topic-2"
                },
                "options": {
                    "consumer_config": {
                        "begin_offset": "earliest"
                    },
                    "filter_init_arg": [],
                    "filter_module": "brucke_filter",
                    "max_partitions_per_group_member": 12,
                    "producer_config": {
                        "compression": "no_compression"
                    },
                    "repartitioning_strategy": "strict_p2p"
                },
                "upstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9092
                        }
                    ],
                    "topics": "brucke-test-topic-1"
                }
            },
            {
                "downstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9092
                        }
                    ],
                    "topic": "brucke-test-topic-3"
                },
                "options": {
                    "consumer_config": {
                        "begin_offset": "latest"
                    },
                    "filter_init_arg": [],
                    "filter_module": "brucke_filter",
                    "max_partitions_per_group_member": 12,
                    "producer_config": {
                        "compression": "no_compression"
                    },
                    "repartitioning_strategy": "key_hash"
                },
                "upstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9092
                        }
                    ],
                    "topics": "brucke-test-topic-2"
                }
            },
            {
                "downstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9192
                        }
                    ],
                    "topic": "brucke-test-topic-1"
                },
                "options": {
                    "consumer_config": {
                        "begin_offset": "latest"
                    },
                    "filter_init_arg": [],
                    "filter_module": "brucke_filter",
                    "max_partitions_per_group_member": 12,
                    "producer_config": {
                        "compression": "no_compression"
                    },
                    "repartitioning_strategy": "random"
                },
                "upstream": {
                    "endpoints": [
                        {
                            "host": "localhost",
                            "port": 9192
                        }
                    ],
                    "topics": "brucke-test-topic-3"
                }
            }
        ],
        "status": "failing",
        "unhealthy": []
    }
