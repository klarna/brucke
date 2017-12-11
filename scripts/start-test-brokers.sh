#!/bin/bash -eu

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

BROD_VSN=$(erl -noinput -eval "
                {ok, Configs} = file:consult(\"$THIS_DIR/../rebar.config\"),
                {deps, Deps} = lists:keyfind(deps, 1, Configs),
                {brod, Version} = lists:keyfind(brod, 1, Deps),
                io:format(Version),
                erlang:halt(0).")

wget -O brod.zip https://github.com/klarna/brod/archive/$BROD_VSN.zip -o brod.zip
unzip -qo brod.zip || true
cd "./brod-$BROD_VSN/docker"

## maybe rebuild
sudo docker-compose -f docker-compose-basic.yml build

## stop everything first
sudo docker-compose -f docker-compose-kafka-2.yml down || true

## start the cluster
sudo docker-compose -f docker-compose-kafka-2.yml up -d

## wait 4 secons for kafka to be ready
n=0
while [ "$(sudo docker exec kafka_1 bash -c '/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --list')" != '' ]; do
  if [ $n -gt 4 ]; then
    echo "timedout waiting for kafka"
    exit 1
  fi
  n=$(( n + 1 ))
  sleep 1
done

## loop
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 3 --replication-factor 2 --topic brucke-test-topic-1"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 3 --replication-factor 2 --topic brucke-test-topic-2"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 2 --replication-factor 2 --topic brucke-test-topic-3"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 3 --replication-factor 2 --topic brucke-test-topic-4"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 25 --replication-factor 2 --topic brucke-test-topic-5"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 13 --replication-factor 2 --topic brucke-test-topic-6"

## basic test
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 1 --replication-factor 2 --topic brucke-basic-test-upstream"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 1 --replication-factor 2 --topic brucke-basic-test-downstream"

## filter test
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 1 --replication-factor 2 --topic brucke-filter-test-upstream"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 1 --replication-factor 2 --topic brucke-filter-test-downstream"

