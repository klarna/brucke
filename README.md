# Brucke - Inter-cluster bridge of kafka topics
Brucke is a kafka consumer+producer powered by [Brod](https://github.com/klarna/brod)

Brucke bridges messages from upstream topic to downstream topic with configurable re-partitionning strategy.

# Configuration

A brucke config file is a YAML file.

Config file path should be set in config_file variable of brucke app config, or via BRUCKE_CONFIG_FILE OS env variable.

Cluster names and client names must comply to erlang atom syntax.

    kafka_clusters:
      kafka_cluster_1:
        - host: "localhost"
          port: 9092
      kafka_cluster_2:
        - host: "kafka-1"
          port: 9092
        - host: "kafka-2"
          port: 9092
    brod_clients:
      - client: brod_client_1
        cluster: kafka_cluster_1
        config: [] # optional
    routes:
      - upstream_client: brod_client_1
        downstream_client: brod_client_1
        upstream_topics:
          - "topic_1"
        downstream_topic: "topic_2"
        repartitioning_strategy: strict_p2p
        default_begin_offset: earliest # optional

## Options for repartitioning strategy
NOTE: For compacted topics, strict_p2p is the only choice.

- key_hash: hash the message key to downstream partition number
- strict_p2p: strictly map the upstream partition number to downstream partition number, worker will refuse to start if upstream and downstream topic has different number of partitions
- random: randomly distribute upstream messages to downstream partitions

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

Brucke package installs release and creates corresponding systemd service. Config files are in /etc/brucke, OS env can be set at /etc/sysconfig/brucke, logs are in /var/log/brucke.

Operating via systemctl:

    systemctl start brucke
    systemctl enable brucke
    systemctl status brucke
