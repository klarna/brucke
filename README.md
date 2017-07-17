# Brucke - Inter-cluster bridge of kafka topics
Brucke is a Inter-cluster bridge of kafka topics powered by [Brod](https://github.com/klarna/brod)

Brucke bridges messages from upstream topic to downstream topic with configurable re-partitionning strategy.

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

## Options for repartitioning strategy
NOTE: For compacted topics, strict_p2p is the only choice.

- key_hash: hash the message key to downstream partition number
- strict_p2p: strictly map the upstream partition number to downstream partition number, worker will refuse to start if
upstream and downstream topic has different number of partitions
- random: randomly distribute upstream messages to downstream partitions

## Customized Message Filtering and or Transformation

Implement `brucke_filter` behaviour to have messages filtered and or transformed before produced to downstream topic.

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

# Http endpoint
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

