#!/usr/bin/env bash


function exit_with_usage {
  cat << EOF

=== Usage: run mlsql cluster in Aliyun ===

-- Aliyun configuration

SECURITY_GROUP       - the security-group id of  aliyun.  Notice that by default, the master will allocate public ip so we can visit them, but there are no any protect except the
                        SECURITY_GROUP. So please create a proper SECURITY_GROUP in Aliyun before run this script.
AK                   - access key
AKS                  - access key secret

-- MLSQL configuration

MLSQL_KEY_PARE_NAME  - a ssh key which you can connect to the esc server.
                      if you do not have one, use pymlsql to create one:
                      pymlsql start --image-id m-bp13ubsorlrxdb9lmv2x --need-public-ip false --init-ssh-key true
                      then the ssh key file will be created in your directory ~/.ssh

MLSQL_SPARK_VERSION  - the spark version, 2.2/2.3/2.4 default 2.3
MLSQL_VERSION        - the mlsql version, 1.1.6 default 1.1.6



EOF
  exit 0
}

set -e
set -o pipefail

if [[ $@ == *"help"* ]]; then
  exit_with_usage
fi

for env in AK AKS MLSQL_KEY_PARE_NAME; do
  if [[ -z "${!env}" ]]; then
    echo "===$env must be set to run this script==="
    exit 1
  fi
done

pymlsql --help

if [[ "$?" != "0"  ]];then
    echo "=== please use pip install pymlsql first==="
    exit 1
fi


#export MLSQL_KEY_PARE_NAME=mlsql-build-env-local

export MLSQL_SPARK_VERSION=${MLSQL_SPARK_VERSION:-2.3}
export MLSQL_VERSION=${MLSQL_VERSION:-1.1.6}
export SECURITY_GROUP=${SECURITY_GROUP:-sg-bp1hi23xfzybp0exjp8a}

export MLSQL_TAR="streamingpro-spark_${MLSQL_SPARK_VERSION}-${MLSQL_VERSION}.tar.gz"
export MLSQL_NAME="streamingpro-spark_${MLSQL_SPARK_VERSION}-${MLSQL_VERSION}"
export SCRIPT_FILE="/tmp/k.sh"

echo "Create ECS instance for master"
start_output=$(pymlsql start --image-id m-bp13ubsorlrxdb9lmv2x --need-public-ip true --init-ssh-key false --security-group ${SECURITY_GROUP})
echo ----"${start_output}"-----

export instance_id=$(echo "${start_output}"|grep '^instance_id:'|cut -d ':' -f2)
export public_ip=$(echo "${start_output}"|grep '^public_ip:'|cut -d ':' -f2)
export inter_ip=$(echo "${start_output}"|grep '^intern_ip:'|cut -d ':' -f2)

echo "${instance_id}" > mlsql.master

cat << EOF
master instance_id : ${instance_id}
master public_ip : ${public_ip}
master inter_ip : ${inter_ip}
EOF


echo "Fetch master hostname"
cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
hostname
EOF

export master_hostname=$(pymlsql exec-shell --instance-id ${instance_id} --script-file ${SCRIPT_FILE} --execute-user root)


echo "Start spark master"

cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
source activate mlsql-3.5
cd /home/webuser/apps/spark-2.3
mkdir -p ~/.ssh
./sbin/start-master.sh -h ${inter_ip}
EOF

pymlsql exec-shell --instance-id ${instance_id} \
--script-file ${SCRIPT_FILE} \
--execute-user webuser


echo "copy ssh file and script to master, so we can create/start slave in master"
pymlsql copy-from-local --instance-id ${instance_id} --execute-user root \
--source /Users/allwefantasy/.ssh/mlsql-build-env-local \
--target /home/webuser/.ssh/


pymlsql copy-from-local --instance-id ${instance_id} --execute-user root \
--source start-slaves.sh \
--target /home/webuser

echo "configure auth of the script"

cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
chown -R webuser:webuser /home/webuser/start-slaves.sh
chown -R webuser:webuser /home/webuser/.ssh/mlsql-build-env-local
chmod 600 /home/webuser/.ssh/mlsql-build-env-local
chmod u+x /home/webuser/start-slaves.sh
EOF

pymlsql exec-shell --instance-id ${instance_id} \
--script-file ${SCRIPT_FILE} \
--execute-user root

cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
source activate mlsql-3.5
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free/
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/
conda config --set show_channel_urls yes
mkdir ~/.pip
echo -e "[global]\ntrusted-host = mirrors.aliyun.com\nindex-url = https://mirrors.aliyun.com/pypi/simple" > ~/.pip/pip.conf

if [[ -z "${PyMLSQL_PIP}" ]];then
    git clone https://github.com/allwefantasy/PyMLSQL.git
    cd PyMLSQL
    rm -rf ./dist && pip uninstall -y pymlsql && python setup.py sdist bdist_wheel && cd ./dist/ && pip install pymlsql-1.1.6.2-py2.py3-none-any.whl && cd -
else
    pip install pymlsql
fi

EOF

pymlsql exec-shell --instance-id ${instance_id} \
--script-file ${SCRIPT_FILE} \
--execute-user webuser

echo "run start slave script in master"
cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
source activate mlsql-3.5
cd /home/webuser

export instance_id=${instance_id}
export public_ip=${public_ip}
export inter_ip=${inter_ip}
export master_hostname=${master_hostname}
export MLSQL_KEY_PARE_NAME=mlsql-build-env-local
export AK=${AK}
export AKS=${AKS}
export SCRIPT_FILE="/tmp/k.sh"
export SECURITY_GROUP=${SECURITY_GROUP}

./start-slaves.sh
EOF

pymlsql exec-shell --instance-id ${instance_id} \
--script-file ${SCRIPT_FILE} \
--execute-user webuser

echo "copy mlsql.slaves from master"
pymlsql copy-to-local --instance-id ${instance_id} --execute-user root \
--source /home/webuser/mlsql.slaves \
--target .


echo "Download MLSQL to master"

cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
cd /home/webuser
source activate mlsql-3.5
export AK=${AK}
export AKS=${AKS}

pymlsql oss-download --bucket-name mlsql-release-repo --source ${MLSQL_TAR}  --target ${MLSQL_TAR}
tar xf ${MLSQL_TAR}
EOF

pymlsql exec-shell --instance-id ${instance_id} \
--script-file ${SCRIPT_FILE} \
--execute-user webuser

echo "submit MLSQL"

cat << EOF > ${SCRIPT_FILE}
#!/usr/bin/env bash
source activate mlsql-3.5
cd /home/webuser
cd ${MLSQL_NAME}
export SPARK_HOME=/home/webuser/apps/spark-2.3
export MLSQL_HOME=\`pwd\`
JARS=\$(echo \${MLSQL_HOME}/libs/*.jar | tr ' ' ',')
MAIN_JAR=\$(ls \${MLSQL_HOME}/libs|grep 'streamingpro-mlsql')
echo \$JARS
echo \${MAIN_JAR}
cd \$SPARK_HOME
nohup ./bin/spark-submit --class streaming.core.StreamingApp \
        --jars \${JARS} \
        --master spark://${inter_ip}:7077 \
        --deploy-mode client \
        --name mlsql \
        --conf "spark.kryoserializer.buffer=256k" \
        --conf "spark.kryoserializer.buffer.max=1024m" \
        --conf "spark.serializer=org.apache.spark.serializer.KryoSerializer" \
        --conf "spark.scheduler.mode=FAIR" \
        \${MLSQL_HOME}/libs/\${MAIN_JAR}    \
        -streaming.name mlsql    \
        -streaming.platform spark   \
        -streaming.rest true   \
        -streaming.driver.port 9003   \
        -streaming.spark.service true \
        -streaming.thrift false \
        -streaming.enableHiveSupport false > /dev/null 2>&1 &
EOF

pymlsql exec-shell --instance-id ${instance_id} \
--script-file ${SCRIPT_FILE} \
--execute-user webuser


cat << EOF > cluster.info
#!/usr/bin/env bash
cluster ui: http://${public_ip}:8080
spark ui: http://${public_ip}:4040
mlsql ui/api: http://${public_ip}:9003

instance ids are stored in  mlsql.master/mlsql.slaves
EOF

cat cluster.info





