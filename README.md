# Brucke - Inter-cluster bridge of kafka topics
Brucke is a kafka consumer+producer powered by [Brod](https://github.com/klarna/brod)

Brucke bridges messages from upstream topic to downstream topic with configurable re-partitionning strategy.

# Configuration

A brucke config file is a YAML file.

Config file path should be set in config_file variable of brucke app config, or via BRUCKE_CONFIG_FILE OS env variable.

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
- strict_p2p: strictly map the upstream partition number to downstream partition number, worker will refuse to start if 
upstream and downstream topic has different number of partitions
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

Brucke package installs release and creates corresponding systemd service. Config files are in /etc/brucke, OS env can 
be set at /etc/sysconfig/brucke, logs are in /var/log/brucke.

Operating via systemctl:

    systemctl start brucke
    systemctl enable brucke
    systemctl status brucke

# Healthcheck
To enable http healthcheck handler add `{healthcheck, true}` to sys.config for `brucke` application.  
Alternatively, you can use corresponding OS env variables:  
- BRUCKE_HEALTHCHECK
- BRUCKE_HEALTHCHECK_PORT

After that you can query healthcheck on `http://Host:8080/healthckeck`.  
Response:

    {
    
        "clients": [
            {
                "brod_client_1": "ok"
            }
        ],
        "routes": [
            {
                "downstream": {
                    "id": "brod_client_1",
                    "topic": "topic_2"
                },
                "members": {
                    "brucke_member1": "ok"
                },
                "status": "ok",
                "upstream": {
                    "client_id": "brod_client_1",
                    "topic": "topic_1"
                }
            }
        ]
    
    }
Where:  
__routes__ is a list of `brucke_member_sup` processes.  
__members__ is a list of `brucke_member` processes.  
__consumers__ and __producers__ can be a list or an object with `{"status" : Error}` meaning that no 
consumers/producers can be found for this id and topic.  
__Error__ is a string, f.e. `{"status": "client_down"}`

### Custom query
To make custom query use parameters in healthcheck request:  
__clients__ - if `false` will return empty clients. Default is `true`.  
__routes__ - if `false` will return empty routes. Default is `true`.  
Example:
`http://127.0.0.1:8080/health?routes=false`

    {
    
        "clients": [
            {
                "client_2": "undefined"
            },
            {
                "client_1": "undefined"
            }
        ],
        "routes": [ ]
    
    }