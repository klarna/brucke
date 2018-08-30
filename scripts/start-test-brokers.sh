#!/bin/bash -eu

KAFKA_VERSION=1.1
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

BROD_VSN=$(erl -noinput -eval "
                {ok, Configs} = file:consult(\"$THIS_DIR/../rebar.config\"),
                {deps, Deps} = lists:keyfind(deps, 1, Configs),
                {brod, Version} = lists:keyfind(brod, 1, Deps),
                io:format(Version),
                erlang:halt(0).")

wget -O brod.zip https://github.com/klarna/brod/archive/$BROD_VSN.zip -o brod.zip
unzip -qo brod.zip || true
cd "./brod-$BROD_VSN/scripts"

sudo KAFKA_VERSION=${KAFKA_VERSION} docker-compose -f docker-compose.yml down || true
sudo KAFKA_VERSION=${KAFKA_VERSION} docker-compose -f docker-compose.yml up -d

## wait 4 secons for kafka to be ready
n=0
while [ "$(sudo docker exec kafka-1 bash -c '/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --list')" != '' ]; do
  if [ $n -gt 4 ]; then
    echo "timedout waiting for kafka"
    exit 1
  fi
  n=$(( n + 1 ))
  sleep 1
done

function create_topic {
  TOPIC_NAME="$1"
  PARTITIONS="${2:-1}"
  REPLICAS="${3:-1}"
  CMD="/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions $PARTITIONS --replication-factor $REPLICAS --topic $TOPIC_NAME"
  sudo docker exec kafka-1 bash -c "$CMD"
}

## loop
create_topic brucke-test-topic-1 3 2
create_topic brucke-test-topic-2 3 2
create_topic brucke-test-topic-3 2 2
create_topic brucke-test-topic-4 3 2
create_topic brucke-test-topic-5 25 2
create_topic brucke-test-topic-6 13 2

## basic test
create_topic brucke-basic-test-upstream 1 2
create_topic brucke-basic-test-downstream 1 2

## filter test
create_topic brucke-filter-test-upstream 1 2
create_topic brucke-filter-test-downstream 1 2

## consumer managed offsets test
create_topic brucke-filter-consumer-managed-offsets-test-upstream 3 2
create_topic brucke-filter-consumer-managed-offsets-test-downstream 3 2

# this is to warm-up kafka group coordinator for deterministic in tests
sudo docker exec kafka-1 /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --new-consumer --group test-group --describe > /dev/null 2>&1

# for kafka 0.11 or later, add sasl-scram test credentials
sudo docker exec kafka-1 /opt/kafka/bin/kafka-configs.sh --zookeeper zookeeper:2181 --alter --add-config 'SCRAM-SHA-256=[iterations=8192,password=ecila],SCRAM-SHA-512=[password=ecila]' --entity-type users --entity-name alice
