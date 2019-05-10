#!/bin/bash

#make sure you have a new version of docker-compose, for example version 1.23.2. 1.21.0 doesn't work with the docker-compose.yml file
#optional. start process-exporter: docker run -d --rm -p 9256:9256 --privileged -v /proc:/host/proc -v `pwd`/proc-exp:/config ncabatoff/process-exporter --procfs /host/proc -config.path /config/process-exporter.yml 
# for additional information on process exporter see: https://github.com/ncabatoff/process-exporter

#Mind that the below line requires the bash shell
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
echo Running from $DIR

jarfilelist=("sb-rest-service-8.jar")
indicator=("_sb")

#jarfilelist=("mp-rest-service-8.jar")
test_outputdir=$DIR/jdktest_8_`date +"%Y%m%d%H%M%S"`
loadgenduration=600
echo Isolated CPUs `cat /sys/devices/system/cpu/isolated`
cpulistperftest=4,5,6,7
cpulistjava=8,9,10,11

echo CPUs used for Performance test $cpulistperftest
echo CPUs used for Java process $cpulistjava

function init() {
git checkout -- Dockerfile
docker stop perftest > /dev/null 2>&1
docker rm perftest > /dev/null 2>&1
docker stop spring-boot-jdk > /dev/null 2>&1
docker rm spring-boot-jdk > /dev/null 2>&1
docker rmi spring-boot-jdk > /dev/null 2>&1
docker-compose stop > /dev/null 2>&1
docker-compose rm -f > /dev/null 2>&1
docker-compose up -d > /dev/null 2>&1
}

echo Redirecting output to $test_outputdir
mkdir -p $test_outputdir
exec > $test_outputdir/outputfile.txt
exec 2>&1
echo Initializing: cleaning up
init

function clean_image() {
	docker stop spring-boot-jdk
	docker rm spring-boot-jdk
	docker rmi spring-boot-jdk
}

function rebuild() {
    clean_image
    var="$@"
    echo USING JARFILE: $var
    docker build -t spring-boot-jdk -f Dockerfile --build-arg JAR_FILE=$var .
    docker run -d --name spring-boot-jdk -p 8080:8080 --network testscripts_dockernet spring-boot-jdk
    export mypid=`ps -o pid,sess,cmd afx | egrep "( |/)java.*app.jar.*( -f)?$" | awk '{print $1}'`
    echo Java process PID: $mypid setting CPU affinity to $cpulistjava
    sudo taskset -pc $cpulistjava $mypid
    #give it some time to startup
    sleep 60
}

#update the Dockerfile so it can be rebuild with a new JVM
function replacer() {
	var="$@"
	echo STARTING NEW TEST $var
	sed -i "1s/.*/$var/" Dockerfile
}

#SetJVMParams
function setjvmparams() {
	var="$@"
	echo REPLACE LINE WITH $var
    sed -i '$ d' Dockerfile
	echo $var >> Dockerfile
}


#get the start time
function get_start_time() {
    echo $1 `docker logs spring-boot-jdk | grep "STARTED Controller started"`
    echo $1 `docker logs spring-boot-jdk | grep "STARTED Application started"`
}

function start_loadgen() {
    docker run -d --name perftest --network testscripts_dockernet -e URL=$1 perftest
    for mypid in `ps -e -o pid,comm,cgroup | grep "/docker/${cid}" | awk '$2=="node" {print $1}'`
    do
        echo Setting CPU affinity for $mypid to $cpulistperftest       
        taskset -a -cp $cpulistperftest $mypid
    done
    sleep $3
    docker exec --user node perftest "/bin/sh" -c "cat /home/node/app/*.log > /home/node/app/combined.log"
    docker cp perftest:/home/node/app/combined.log $2
    docker stop perftest
    docker rm perftest
}

function get_prom_stats_sb() {
    echo $1 Starting get prom stats from $2
    PROM_REQUESTS=`wget -qO- $2 | egrep 'http_server_requests_seconds_count.*status\=\"200\",\uri\=\"\/greeting' | awk '{print $2}'`
    PROM_TOTALTIME_S=`wget -qO- $2 | egrep 'http_server_requests_seconds_sum.*status\=\"200\",\uri\=\"\/greeting' | awk '{print $2}'`
    PROM_AVERAGE_MS=`awk "BEGIN {printf \"%.5f\n\", 1000*$PROM_TOTALTIME_S/$PROM_REQUESTS}"`
    echo $1 PROM_REQUESTS: $PROM_REQUESTS
    echo $1 PROM_TOTALTIME_S: $PROM_TOTALTIME_S
    echo $1 PROM_AVERAGE_MS: $PROM_AVERAGE_MS
}

function get_prom_stats_vertx() {
    echo $1 Starting get prom stats from $2
    PROM_REQUESTS=`wget -qO- $2 | egrep 'http_server_responseTime_seconds_count.*code\=\"200\",\path\=\"\/greeting' | awk '{print $2}'`
    PROM_TOTALTIME_S=`wget -qO- $2 | egrep 'http_server_responseTime_seconds_sum.*code\=\"200\",\path\=\"\/greeting' | awk '{print $2}'`
    PROM_AVERAGE_MS=`awk "BEGIN {printf \"%.5f\n\", 1000*$PROM_TOTALTIME_S/$PROM_REQUESTS}"`
    echo $1 PROM_REQUESTS: $PROM_REQUESTS
    echo $1 PROM_TOTALTIME_S: $PROM_TOTALTIME_S
    echo $1 PROM_AVERAGE_MS: $PROM_AVERAGE_MS
}

function get_prom_stats_mp() {
    echo $1 Starting get prom stats from $2
    PROM_AVERAGE_S=`wget -qO- $2 | egrep '^application:messages_processed_mean_seconds' | awk '{print $2}'`
    PROM_AVERAGE_MS=`awk "BEGIN {printf \"%.5f\n\", 1000*$PROM_AVERAGE_S}"`
    PROM_REQUESTS=`wget -qO- $2 | egrep '^application:messages_processed_seconds_count' | awk '{print $2}'`
    PROM_TOTALTIME_S=`awk "BEGIN {printf \"%.5f\n\", $PROM_AVERAGE_S*$PROM_REQUESTS}"`
    echo $1 PROM_REQUESTS: $PROM_REQUESTS
    echo $1 PROM_TOTALTIME_S: $PROM_TOTALTIME_S
    echo $1 PROM_AVERAGE_MS: $PROM_AVERAGE_MS
}

function check_sb_prom() {
    return `wget -qO- http://localhost:8080/prometheus | egrep 'http_server_requests_seconds_count.*status\=\"200\",\uri\=\"\/greeting' | wc -l`
}

function check_vertx_prom() {
    return `wget -qO- http://localhost:8080/metrics | egrep 'http_server_responseTime_seconds_count.*code\=\"200\",\path\=\"\/greeting' | wc -l`
}

function check_mp_prom() {
    return `wget -qO- http://localhost:8080/metrics | egrep '^application:messages_processed_seconds_count' | wc -l`
}

#single parameter indicating the outputdir
function run_test() {
    echo $1 STARTED AT: `date`
    mkdir -p $test_outputdir/$1
    start_loadgen http://spring-boot-jdk:8080/greeting?name=Maarten $test_outputdir/$1/results.txt $loadgenduration
    check_sb_prom
    valResult=$?
    if [[ $valResult -gt 0 ]] 
    then   
        get_prom_stats_sb $1 http://localhost:8080/prometheus
    else
        echo $1 No Spring Boot Prometheus available
    fi
    check_mp_prom
    valResult=$?
    if [[ $valResult -gt 0 ]] 
    then
        get_prom_stats_mp $1 http://localhost:8080/metrics
    else
        echo $1 No MicroProfile Prometheus available
    fi
    check_vertx_prom
    valResult=$?
    if [[ $valResult -gt 0 ]] 
    then
        get_prom_stats_vertx $1 http://localhost:8080/metrics
    else
        echo $1 No Vert.X Prometheus available
    fi

    echo $1 COMPLETED_AT: `date`
    echo $1 REQUESTS_PROCESSED: `cat $test_outputdir/$1/results.txt | grep MEASURE | wc -l`
    echo $1 AVERAGE_PROCESSING_TIME_MS: `cat $test_outputdir/$1/results.txt | grep MEASURE | awk -F " " '{ total += $3 } END { print total/NR }'`
    echo $1 STANDARD_DEVIATION_MS: `cat $test_outputdir/$1/results.txt | grep MEASURE | awk '{delta = $3 - avg; avg += delta / NR; mean2 += delta * ($3 - avg); } END { print sqrt(mean2 / NR); }'`
}

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8:jdk8u202-b08"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-XX:+UseSerialGC","-Xmx20m","-Xms20m","-jar","/app.jar"]'
rebuild $jarfilename
run_test adoptopenjdkserial${indicator[$counter]}
get_start_time adoptopenjdkserial${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8:jdk8u202-b08"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-XX:+UseParallelGC","-Xmx20m","-Xms20m","-jar","/app.jar"]'
rebuild $jarfilename
run_test adoptopenjdkpargc${indicator[$counter]}
get_start_time adoptopenjdkpargc${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8:jdk8u202-b08"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-XX:+UseParNewGC","-Xmx20m","-Xms20m","-jar","/app.jar"]'
rebuild $jarfilename
run_test adoptopenjdkcms${indicator[$counter]}
get_start_time adoptopenjdkcms${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8:jdk8u202-b08"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-XX:+UseG1GC","-Xmx20m","-Xms20m","-jar","/app.jar"]'
rebuild $jarfilename
run_test adoptopenjdkg1gc${indicator[$counter]}
get_start_time adoptopenjdkg1gc${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8-openj9:jdk8u202-b08_openj9-0.12.1"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-Xgcpolicy:gencon","-Xmx20m","-Xms20m","-Xshareclasses:name=Cache1","-jar","/app.jar"]'
rebuild $jarfilename
run_test openj9gencon${indicator[$counter]}
get_start_time openj9gencon${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8-openj9:jdk8u202-b08_openj9-0.12.1"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-Xgcpolicy:balanced","-Xmx20m","-Xms20m","-Xshareclasses:name=Cache1","-jar","/app.jar"]'
rebuild $jarfilename
run_test openj9balanced${indicator[$counter]}
get_start_time openj9balanced${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8-openj9:jdk8u202-b08_openj9-0.12.1"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-Xgcpolicy:metronome","-Xmx20m","-Xms20m","-Xshareclasses:name=Cache1","-jar","/app.jar"]'
rebuild $jarfilename
run_test openj9metronome${indicator[$counter]}
get_start_time openj9metronome${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8-openj9:jdk8u202-b08_openj9-0.12.1"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-Xgcpolicy:optavgpause","-Xmx20m","-Xms20m","-Xshareclasses:name=Cache1","-jar","/app.jar"]'
rebuild $jarfilename
run_test openj9optavgpause${indicator[$counter]}
get_start_time openj9optavgpause${indicator[$counter]}
sleep 20
done

counter=-1
for jarfilename in ${jarfilelist[@]}
do
counter=$(( $counter + 1 ))
replacer "FROM adoptopenjdk\/openjdk8-openj9:jdk8u202-b08_openj9-0.12.1"
setjvmparams 'ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-XX:+UnlockExperimentalVMOptions","-Xgcpolicy:optthrupu","-Xmx20m","-Xms20m","-Xshareclasses:name=Cache1","-jar","/app.jar"]'
rebuild $jarfilename
run_test openj9optthrupu${indicator[$counter]}
get_start_time openj9optthrupu${indicator[$counter]}
sleep 20
done
