ARG BASE_IMAGE_TAG=latest
FROM edxops/xenial-common:${BASE_IMAGE_TAG}
LABEL maintainer="edxops"

USER root
ENV BOTO_CONFIG=/dev/null \
    JDK_URL=http://download.oracle.com/otn-pub/java/jdk/8u131-b11/d54c1d3a095b4ff2b6607d096fa80163/jdk-8u131-linux-x64.tar.gz \
    JDK_DIST_FILE=jdk-8u131-linux-x64.tar.gz \
    JAVA_HOME=/usr/lib/jvm/java-8-oracle \
    HADOOP_URL=https://archive.apache.org/dist/hadoop/common/hadoop-2.7.2/hadoop-2.7.2.tar.gz \
    HADOOP_DIST_FILE=hadoop-2.7.2.tar.gz \
    HADOOP_HOME=/edx/app/hadoop/hadoop \
    HADOOP_PREFIX=/edx/app/hadoop/hadoop \
    HIVE_URL=https://archive.apache.org/dist/hive/hive-2.1.1/apache-hive-2.1.1-bin.tar.gz \
    HIVE_DIST_FILE=apache-hive-2.1.1-bin.tar.gz \
    HIVE_HOME=/edx/app/hadoop/hive \
    SQOOP_URL=http://archive.apache.org/dist/sqoop/1.4.6/sqoop-1.4.6.bin__hadoop-2.0.4-alpha.tar.gz \
    SQOOP_DIST_FILE=sqoop-1.4.6.bin__hadoop-2.0.4-alpha.tar.gz \
    SQOOP_MYSQL_CONNECTOR_URL=http://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.29.tar.gz \
    SQOOP_MYSQL_CONNECTOR_FILE=mysql-connector-java-5.1.29 \
    SQOOP_HOME=/edx/app/hadoop/sqoop \
    SQOOP_LIB=/edx/app/hadoop/sqoop/lib \
    SQOOP_VERTICA_CONNECTOR_URL=https://vertica.com/client_drivers/9.1.x/9.1.1-0/vertica-jdbc-9.1.1-0.jar \
    SQOOP_VERTICA_CONNECTOR_FILE=vertica-jdbc-9.1.1-0.jar \
    SPARK_URL=https://archive.apache.org/dist/spark/spark-2.1.0/spark-2.1.0-bin-hadoop2.7.tgz \
    SPARK_DIST_FILE=spark-2.1.0-bin-hadoop2.7.tgz \
    SPARK_HOME=/edx/app/hadoop/spark \
    LUIGI_CONFIG_PATH=/edx/app/analytics_pipeline/analytics_pipeline/config/luigi_docker.cfg \
    ANALYTICS_PIPELINE_VENV=/edx/app/analytics_pipeline/venvs \
    BOOTSTRAP=/etc/bootstrap.sh \
    COMMON_BASE_DIR=/edx \
    COMMON_PIP_PACKAGES_PIP='pip==21.2.1' \
    COMMON_PIP_PACKAGES_SETUPTOOLS='setuptools==44.1.0' \
    COMMON_PIP_PACKAGES_VIRTUALENV='virtualenv==20.1.0' \
    COMMON_MYSQL_READ_ONLY_USER='read_only' \
    COMMON_MYSQL_READ_ONLY_PASS='password' \
    ANALYTICS_PIPELINE_OUTPUT_DATABASE_USER='pipeline001' \
    ANALYTICS_PIPELINE_OUTPUT_DATABASE_PASSWORD='password' \
    EDX_PPA_KEY_SERVER='keyserver.ubuntu.com' \
    EDX_PPA_KEY_ID='69464050'


ENV PATH="/edx/app/analytics_pipeline/venvs/analytics_pipeline/bin:${JAVA_HOME}/bin:${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${HIVE_HOME}/bin:${SPARK_HOME}/bin:${SPARK_HOME}/sbin:${SQOOP_HOME}/bin:$PATH" \
    COMMON_DATA_DIR=$COMMON_BASE_DIR/var \
    COMMON_APP_DIR=$COMMON_BASE_DIR/app \
    COMMON_LOG_DIR=$COMMON_BASE_DIR/var/log \
    COMMON_BIN_DIR=$COMMON_BASE_DIR/bin \
    COMMON_CFG_DIR=$COMMON_BASE_DIR/etc

# add custom PPAs & install packages
RUN apt-get update -y && apt-get install -y software-properties-common \
    && apt-key adv --keyserver $EDX_PPA_KEY_SERVER --recv-keys $EDX_PPA_KEY_ID \
    && add-apt-repository -y 'deb http://ppa.edx.org xenial main' \
    && apt-get update -y \
    && apt-get install --no-install-recommends -y \
           python2.7 python2.7-dev python-pip python-apt python-yaml python-jinja2 libmysqlclient-dev libffi-dev libssl-dev \
           libatlas-base-dev libblas-dev liblapack-dev libpq-dev sudo make build-essential git-core \
           openssh-server openssh-client rsync software-properties-common vim net-tools curl netcat mysql-client-5.6 \
           apt-transport-https ntp acl lynx-cur logrotate rsyslog unzip \
           ack-grep mosh tree screen tmux dnsutils inetutils-telnet \
    && rm -rf /var/lib/apt/lists/*

# creating directory structure
RUN mkdir -p $HADOOP_HOME $JAVA_HOME $ANALYTICS_PIPELINE_VENV /edx/app/hadoop/lib $HIVE_HOME /etc/luigi \
    $SPARK_HOME $SQOOP_HOME $COMMON_DATA_DIR $COMMON_APP_DIR $COMMON_LOG_DIR $COMMON_BIN_DIR $COMMON_CFG_DIR/edx-analytics-pipeline

# create user & group for hadoop
RUN groupadd hadoop
RUN useradd -ms /bin/bash hadoop -g hadoop -d /edx/app/hadoop
RUN echo '%hadoop ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# JAVA
RUN curl -fSL --header "Cookie:oraclelicense=accept-securebackup-cookie" "$JDK_URL" -o /var/tmp/$JDK_DIST_FILE \
    && tar -xzf /var/tmp/$JDK_DIST_FILE -C $JAVA_HOME --strip-components=1 \
    && rm -f /var/tmp/$JDK_DIST_FILE

# HADOOP
RUN curl -fSL "$HADOOP_URL" -o /var/tmp/$HADOOP_DIST_FILE \
    && tar -xzf /var/tmp/$HADOOP_DIST_FILE -C $HADOOP_HOME --strip-components=1 \
    && sed -i '/^export JAVA_HOME/ s:.*:export JAVA_HOME=/usr/lib/jvm/java-8-oracle\nexport HADOOP_PREFIX=/edx/app/hadoop/hadoop\nexport HADOOP_HOME=/edx/app/hadoop/hadoop\n:' $HADOOP_HOME/etc/hadoop/hadoop-env.sh \
    && sed -i '/^export HADOOP_CONF_DIR/ s:.*:export HADOOP_CONF_DIR=/edx/app/hadoop/hadoop/etc/hadoop/:' $HADOOP_HOME/etc/hadoop/hadoop-env.sh \
    && sed -i 's#<configuration>#<configuration><property><name>fs.defaultFS</name><value>hdfs://namenode:8020</value></property>#' $HADOOP_HOME/etc/hadoop/core-site.xml \
    && sed 's#<configuration>#<configuration><property><name>mapreduce.framework.name</name><value>yarn</value></property>#' $HADOOP_HOME/etc/hadoop/mapred-site.xml.template > $HADOOP_HOME/etc/hadoop/mapred-site.xml \
    && sed -i 's#<configuration>#<configuration><property><name>yarn.resourcemanager.hostname</name><value>resourcemanager</value></property>#' $HADOOP_HOME/etc/hadoop/yarn-site.xml \
    && rm -f /var/tmp/$HADOOP_DIST_FILE

# HIVE
RUN curl -fSL "$HIVE_URL" -o /var/tmp/$HIVE_DIST_FILE \
    && tar -xzf /var/tmp/$HIVE_DIST_FILE -C $HIVE_HOME --strip-components=1 \
    && rm -f /var/tmp/$HIVE_DIST_FILE
ADD docker/build/analytics_pipeline/hive-site.xml.template $HIVE_HOME/conf/hive-site.xml

# SPARK
RUN curl -fSL "$SPARK_URL" -o /var/tmp/$SPARK_DIST_FILE \
    && tar -xzf /var/tmp/$SPARK_DIST_FILE -C $SPARK_HOME --strip-components=1 \
    && echo 'spark.master  spark://sparkmaster:7077\nspark.eventLog.enabled  true\nspark.eventLog.dir  hdfs://namenode:8020/tmp/spark-events\nspark.history.fs.logDirectory  hdfs://namenode:8020/tmp/spark-events\nspark.sql.warehouse.dir hdfs://namenode:8020/spark-warehouse' > $SPARK_HOME/conf/spark-defaults.conf \
    && rm -f /var/tmp/$SPARK_DIST_FILE
ADD docker/build/analytics_pipeline/spark-log4j.properties $SPARK_HOME/conf/log4j.properties

# SQOOP
RUN curl -fSL "$SQOOP_URL" -o /var/tmp/$SQOOP_DIST_FILE \
    && curl -fSL "$SQOOP_MYSQL_CONNECTOR_URL" -o /var/tmp/$SQOOP_MYSQL_CONNECTOR_FILE.tar.gz \
    && curl -fSL "$SQOOP_VERTICA_CONNECTOR_URL" -o /var/tmp/$SQOOP_VERTICA_CONNECTOR_FILE \
    && tar -xzf /var/tmp/$SQOOP_DIST_FILE -C $SQOOP_HOME --strip-components=1 \
    && tar -xzf /var/tmp/$SQOOP_MYSQL_CONNECTOR_FILE.tar.gz -C /var/tmp/ \
    && cp /var/tmp/$SQOOP_MYSQL_CONNECTOR_FILE/$SQOOP_MYSQL_CONNECTOR_FILE-bin.jar $SQOOP_LIB \
    && cp /var/tmp/$SQOOP_MYSQL_CONNECTOR_FILE/$SQOOP_MYSQL_CONNECTOR_FILE-bin.jar $HIVE_HOME/lib/ \
    && cp /var/tmp/$SQOOP_VERTICA_CONNECTOR_FILE $SQOOP_LIB \
    && rm -rf /var/tmp/$SQOOP_DIST_FILE /var/tmp/$SQOOP_MYSQL_CONNECTOR_FILE* /var/tmp/$SQOOP_VERTICA_CONNECTOR_FILE*

WORKDIR /var/tmp
# Edx Hadoop Util Library
RUN git clone https://github.com/edx/edx-analytics-hadoop-util \
    && cd /var/tmp/edx-analytics-hadoop-util \
    && $JAVA_HOME/bin/javac -cp `/edx/app/hadoop/hadoop/bin/hadoop classpath` org/edx/hadoop/input/ManifestTextInputFormat.java \
    && $JAVA_HOME/bin/jar cf /edx/app/hadoop/lib/edx-analytics-hadoop-util.jar org/edx/hadoop/input/ManifestTextInputFormat.class

# configure bootstrap scripts for container
ADD docker/build/analytics_pipeline/bootstrap.sh /etc/bootstrap.sh
RUN chown hadoop:hadoop /etc/bootstrap.sh \
    && chmod 700 /etc/bootstrap.sh \
    && chown -R hadoop:hadoop /edx/app/hadoop

# Analytics pipeline
ARG OPENEDX_RELEASE=master
ENV OPENEDX_RELEASE=${OPENEDX_RELEASE}
RUN git clone https://github.com/openedx/edx-analytics-pipeline \
    && cd edx-analytics-pipeline \
    && git checkout ${OPENEDX_RELEASE} \
    && cd .. \
    && cp /var/tmp/edx-analytics-pipeline/Makefile /var/tmp/Makefile \
    && cp -r /var/tmp/edx-analytics-pipeline/requirements /var/tmp/requirements \
    && rm -rf /var/tmp/edx-analytics-pipeline

RUN pip install $COMMON_PIP_PACKAGES_PIP $COMMON_PIP_PACKAGES_SETUPTOOLS $COMMON_PIP_PACKAGES_VIRTUALENV \
    && virtualenv $ANALYTICS_PIPELINE_VENV/analytics_pipeline/ \
    && chown -R hadoop:hadoop $ANALYTICS_PIPELINE_VENV/analytics_pipeline/ \
    && echo '[hadoop]\nversion: cdh4\ncommand: /edx/app/hadoop/hadoop/bin/hadoop\nstreaming-jar: /edx/app/hadoop/hadoop/share/hadoop/tools/lib/hadoop-streaming-2.7.2.jar' > /etc/luigi/client.cfg

RUN apt-get update && make system-requirements
ADD docker/build/analytics_pipeline/devstack.sh /edx/app/analytics_pipeline/devstack.sh
RUN chown hadoop:hadoop /edx/app/analytics_pipeline/devstack.sh && chmod a+x /edx/app/analytics_pipeline/devstack.sh
USER hadoop
RUN touch /edx/app/hadoop/.bashrc \
    && echo 'export JAVA_HOME=/usr/lib/jvm/java-8-oracle\nexport HADOOP_HOME=/edx/app/hadoop/hadoop\nexport HIVE_HOME=/edx/app/hadoop/hive\nexport SQOOP_HOME=/edx/app/hadoop/sqoop\nexport SPARK_HOME=/edx/app/hadoop/spark\nexport PATH="/edx/app/analytics_pipeline/venvs/analytics_pipeline/bin:${JAVA_HOME}/bin:${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${HIVE_HOME}/bin:${SPARK_HOME}/bin:${SPARK_HOME}/sbin:${SQOOP_HOME}/bin:$PATH"' > /edx/app/hadoop/.bashrc \
    && . $ANALYTICS_PIPELINE_VENV/analytics_pipeline/bin/activate \
    && make test-requirements requirements

RUN sudo chown hadoop:hadoop $COMMON_CFG_DIR/edx-analytics-pipeline/ \
    && echo "{\"username\": \"$COMMON_MYSQL_READ_ONLY_USER\", \"host\": \"mysql\", \"password\": \"$COMMON_MYSQL_READ_ONLY_PASS\", \"port\": 3306}" > $COMMON_CFG_DIR/edx-analytics-pipeline/input.json \
    && echo "{\"username\": \"$ANALYTICS_PIPELINE_OUTPUT_DATABASE_USER\", \"host\": \"mysql\", \"password\": \"$ANALYTICS_PIPELINE_OUTPUT_DATABASE_PASSWORD\", \"port\": 3306}" > $COMMON_CFG_DIR/edx-analytics-pipeline/output.json \
    && echo "{\"username\": \"dbadmin\", \"host\": \"vertica\", \"password\": \"\", \"port\": 5433}" > $COMMON_CFG_DIR/edx-analytics-pipeline/warehouse.json

ADD docker/build/analytics_pipeline/acceptance.json $COMMON_CFG_DIR/edx-analytics-pipeline/acceptance.json
WORKDIR /edx/app/analytics_pipeline/analytics_pipeline

CMD ["/etc/bootstrap.sh", "-d"]
