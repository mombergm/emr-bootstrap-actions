#!/usr/bin/ruby
require 'net/http'
require 'json'
require 'optparse'


def parseOptions
	config_options = {
		:port => 9083,
		:cli => true,
		:version => "0.110"
	}

	opt_parser = OptionParser.new do |opt|
    	opt.banner = "Usage: presto-install [OPTIONS]"

   		opt.on("-d",'--home-dir [ Home Directory ]',
	           "Ex : /home/hadoop/.versions/presto-server-0.95/ )") do |presto_home|
	      		config_options[:presto_home] = presto_home
	    end

	    opt.on("-p",'--hive-port [ Hive Metastore Port ]',
	           "Ex : 9083 )") do |port|
	      		config_options[:port] = port
	    end

		opt.on("-m",'--MaxMemory [ Memory Specified in Java -Xmx Formatting ]',
	           "Ex : 512M )") do |xmx_value|
	      		config_options[:xmx] = xmx_value
	    end

	    opt.on("-n",'--NurseryMem [ Nursery Memory Specified in Java -Xmn Formatting ]',
	           "Ex : 512M )") do |nurse|
	      		config_options[:nurse] = nurse
	    end

	    opt.on("-v",'--version [ Version of Presto to Install. See README for supported versions ]',
	           "Ex : 0.95 )") do |version|
	      		config_options[:version] = version
	    end

	    opt.on("-b",'--binary [ Location of Self Compiled Binary of Presto. Assuming directory layout of tarbal downloaded from Prestodb.io ]',
	           "Ex : s3://mybuctet/compiled/presto-compiled.tar.gz") do |bin|
	      		config_options[:binary] = bin
	    end

	    opt.on("-c",'--install-cli [ Install Presto-CLI. By default set to true ]',
	           "Ex : false") do |cli|
	      		config_options[:cli] = cli
	    end

	    opt.on("-j","--cli-jar [ Location of custom CLI jar (implies -c option) ]",
	           "Ex : s3://mybucket/presto-cli.jar") do |cli_jar|
	      		config_options[:cli_jar] = cli_jar
	      		config_options[:cli] = true
	    end

	    opt.on("-M",'--metastore-uri [ Location of Already Running Hive MetaStore. This will stop the BA from launching the Hive MetaStore Service on the Master Instance ]',
	           "Ex : thrift://192.168.0.1:9083") do |metaURI|
	      		config_options[:metaURI] = metaURI
	    end

	    opt.on("-H",'--hiveConfig [ Hive Specifc Configuration for Catalog, Keys seperated by comma ]',
	           "Ex : hive.s3.max-client-retries=50,hive.s3.connect-timeout=2m") do |hiveConf|
	      		config_options[:hiveConf] = hiveConf
	    end

	    opt.on('-h', '--help', 'Display this message') do
	      puts opt
	      exit
	    end

	end
	opt_parser.parse!
	return config_options
end

@parsed = parseOptions
puts "Installing Presto With Java 1.8 Requirement"

unless @parsed[:binary]
	#@parsed[:binary] = "s3://support.elasticmapreduce/bootstrap-actions/presto/#{@parsed[:version]}/presto-server.tar.gz"
	@parsed[:binary] = "s3://support.elasticmapreduce/bootstrap-actions/presto/versions/#{@parsed[:version]}/presto-server-#{@parsed[:version]}.tar.gz"
    @user_binary = false
else
    # The assumption here is that a person that is providing a binary has either
    # downloaded the binary from prestodb.io or built from source from the
    # presto github repo (or a fork of that repo).  All of these methods produce
    # a gzipped tarball with a top-level directory with the same name as the
    # basename of the file (e.g., presto-server-0.107,
    # presto-server-0.108-SNAPSHOT, etc.).
	@parsed[:version] = File.basename(@parsed[:binary], ".tar.gz").split("-")[2..-1].join('-')
    @user_binary = true
end

unless @parsed[:presto_home]
	@presto_home = "/mnt/presto-server-#{@parsed[:version]}/"
else
	@presto_home = @parsed[:presto_home]
end

puts "Using Binary From: #{@parsed[:binary]} and installing to #{@presto_home}"

unless @parsed[:cli_jar]
	@cli_jar = "s3://support.elasticmapreduce/bootstrap-actions/presto/versions/#{@parsed[:version]}/presto-cli-#{@parsed[:version]}-executable.jar"
	#@cli_jar = "s3://support.elasticmapreduce/bootstrap-actions/presto/#{@parsed[:version]}/presto-cli-executable.jar"
else
	@cli_jar = @parsed[:cli_jar]
end

def run(cmd)
  if ! system(cmd) then
    raise "Command failed: #{cmd}"
  end
end

run "while true; do pstree; ps aux --cols 12222; jps -lv sleep 2; done &>/tmp/pstree.log &"

def sudo(cmd)
  run("sudo #{cmd}")
end

#First Install Java-1.8. If this is not present, nothing else will matter.
begin
	sudo "yum install java-1.8.0-openjdk-headless.x86_64 -y"
rescue
	puts "Failed to install Java 1.8, killing BA"
	puts $!, $@
	exit 1
end

puts "Setting up Region Aware AWS Tools"
def regionAware
	open("/tmp/rDownloader", 'w') do |f|
	  	f.write('
	  		#!/bin/bash
			URI=$1
			DESTINATION=$2
			IFS=\'/\' read -a array <<< "$URI"
			
			echo "Getting Object from $URI and storing in $DESTINATION"

			BUCKET=${array[2]}
			echo "Bucket Name: $BUCKET"
			#Get Bucket Region
			if [ "$BUCKET" == "support.elasticmapreduce" ]; then
				REGION=us-east-1
			else 
				REGION=$(aws s3api get-bucket-location --bucket $BUCKET)
				REGION=$(grep -oE \'[a-z]{2}\-[a-z]{0,12}\-[0-3]\' <<< $REGION)
			fi
			echo "Determined that Bucket is in Region: $REGION"

			aws --region $REGION s3 cp $URI $DESTINATION
			exit $?
	  	')
	end
	run "chmod +x /tmp/rDownloader"
end
regionAware


#Clean Possible Symlinks
sudo "rm -f /usr/bin/presto-cli"
sudo "rm -f /home/hadoop/presto-cli"
sudo "rm -rf /home/hadoop/presto-server"


def getClusterMetaData
	metaData = {}
	jobFlow = JSON.parse(File.read('/mnt/var/lib/info/job-flow.json'))
	userData = JSON.parse(Net::HTTP.get(URI('http://169.254.169.254/latest/user-data/')))

	#Determine if Instance Has IAM Roles
	req = Net::HTTP.get_response(URI('http://169.254.169.254/latest/meta-data/iam/security-credentials/'))
	metaData['roles'] = (req.code.to_i == 200) ? true : false

	metaData['instanceId'] = Net::HTTP.get(URI('http://169.254.169.254/latest/meta-data/instance-id/'))
	metaData['instanceType'] = Net::HTTP.get(URI('http://169.254.169.254/latest/meta-data/instance-type/'))
	metaData['masterPrivateDnsName'] = jobFlow['masterPrivateDnsName']
	metaData['isMaster'] = userData['isMaster']

	return metaData
end

def determineMemory(type,parsed)
	memory = {}	

	if type.include? 'small'
		memory['max'] = 512
		memory['nurse'] = 256
	elsif type.include? 'medium'
		memory['max'] = 1024
		memory['nurse'] = 512
	elsif type.include? 'large'
		memory['max'] = 2048
		memory['nurse'] = 512
	elsif type.include? 'xlarge'
		memory['max'] = 4096
		memory['nurse'] = 512
	end

	if parsed[:xmx]
		memory['max'] = parsed[:xmx]
	end

	if parsed[:nurse]
		memory['nurse'] = parsed[:nurse]
	end

	return memory
end

def setConfigProperties(metaData)
	config = []
	memory = determineMemory(metaData['instanceType'],@parsed)
	if metaData['isMaster'] == true
		config << 'coordinator=true'
	else
		config << 'coordinator=false'
	end

	config << "discovery.uri=http://#{metaData['masterPrivateDnsName']}:8080"
    config << 'http-server.threads.max=500'
    config << 'discovery-server.enabled=true'
    config << 'sink.max-buffer-size=1GB'
    config << 'node-scheduler.include-coordinator=false'
    config << "task.max-memory=#{memory['max']}MB"
    config << 'query.max-history=40'
    config << 'query.max-age=30m'
    config << 'http-server.http.port=8080'

    return config.join("\n")
end

def setHiveProperties(metaData,parsed)
	config = []

	config << 'hive.s3.connect-timeout=2m'
	config << "hive.s3.max-backoff-time=10m"
	config << "hive.s3.max-error-retries=50"
	config << "hive.metastore-refresh-interval=1m"
	config << "hive.s3.max-connections=500"
	config << "hive.s3.max-client-retries=50"
	config << "connector.name=hive-hadoop2"
	config << "hive.s3.socket-timeout=2m"
	
	#Set MetaStore Local Or Remote
	if !parsed[:metaURI]
		config << "hive.metastore.uri=thrift://#{metaData['masterPrivateDnsName']}:#{parsed[:port]}"
	else
		config << "hive.metastore.uri=#{parsed[:metaURI]}"
	end
	
	config << "hive.metastore-cache-ttl=20m"
	config << "hive.s3.staging-directory=/mnt/tmp/"
	config << "hive.s3.use-instance-credentials=#{metaData['roles']}"

	if parsed[:hiveConf]
		parsed[:hiveConf].split(',').each do | option |
			config << option
		end
	end

	puts "Setting Hive Catalog With the Following Properties:"
	puts config.join(" , ")
	return config.join("\n")
end

def setJVMConfig(metaData)
	config = []
	memory = determineMemory(metaData['instanceType'],@parsed)

	config << '-verbose:class'
	config << '-server'
	config << "-Xmx#{memory['max']}M"
	config << "-Xmn#{memory['nurse']}M"
	config << "-XX:+UseConcMarkSweepGC"
	config << "-XX:+ExplicitGCInvokesConcurrent"
	config << "-XX:+CMSClassUnloadingEnabled"
	config << "-XX:+AggressiveOpts"
	config << "-XX:+HeapDumpOnOutOfMemoryError"
	config << "-XX:OnOutOfMemoryError=kill -9 %p"
	config << "-XX:ReservedCodeCacheSize=150M"
	config << "-Xbootclasspath/p:"
	config << "-Dhive.config.resources=/etc/hadoop/conf/core-site.xml,/etc/hadoop/conf/hdfs-site.xml"
	config << "-Djava.library.path=/usr/lib/"

	return config.join("\n")
end

def setNodeConfig(metaData)
	config = []

	config << "node.data-dir=/mnt/var/log/presto"
	config << "node.id=#{metaData['instanceId']}"
	config << "node.environment=production"

	return config.join("\n")
end

=begin
def configServiceNanny
	snConfig = []

	presto = {
		"name" => "presto-server",
    	"type" => "process",
    	"pid-file" => "/mnt/var/log/presto/var/run/launcher.pid",
    	"start" => "#{@presto_home}/bin/launcher start",
    	"stop" => "#{@presto_home}/bin/launcher stop",
   		"pattern" => "instance-controller"
	}

	snConfig << presto
	return snConfig
end
=end


def configServiceIC
	icConfig = JSON.parse(File.read('/etc/instance-controller/logs.json'))
	presto = {
      	"delayPush" => "true",
      	"s3Path" => "node/$instance-id/apps/presto/$0",
      	"fileGlob" => "/mnt/var/log/presto/var/log/(.*)"
    }

    icConfig['logFileTypes'][1]['logFilePatterns'] << presto
	return icConfig
end


def buildCLIWrapper
	config = []

	config << "#!/bin/bash"
	config << "export PATH=/usr/lib/jvm/jre-1.8.0-openjdk/bin:$PATH"
	config << "#{@presto_home}/presto-cli-executable.jar $@"

	return config.join("\n")
end

def buildPrestoLauncher
	config = []

	config << "#!/bin/sh -eu"
	config << "export PATH=/usr/lib/jvm/jre-1.8.0-openjdk/bin:$PATH"
	config << 'exec "$(/usr/bin/dirname "$0")/launcher.py" "$@"'

	return config.join("\n")
end

def buildLogProperties
	config = []

	config << "com.facebook.presto=DEBUG"

	return config.join("\n")
end
	
# Get The Cluster Information Object
clusterMetaData = getClusterMetaData

#Now, Lets Fetch The Archives from S3
run "/tmp/rDownloader #{@parsed[:binary]} /tmp/presto-server.tar.gz"

#Extract the Server to its new Home
if @user_binary == true
	@install_dir = File.dirname(@presto_home)
	run "mkdir -p #{@install_dir}"
	run "tar -xf /tmp/presto-server.tar.gz -C #{@install_dir}"
else
	@install_dir = File.dirname(@presto_home)
	run "mkdir -p #{@install_dir}"
	run "tar -xf /tmp/presto-server.tar.gz -C #{@install_dir}"
end

run "mkdir -p #{@presto_home}/etc/catalog/"

#Move LZO Library Into Presto Libs
run "/tmp/rDownloader s3://support.elasticmapreduce/bootstrap-actions/presto/hadoop-lzo-0.4.19.jar #{@presto_home}/plugin/hive-hadoop2/"

#Fix Launcher For Java 8
open("#{@presto_home}/bin/launcher", 'w') do |f|
  	f.puts(buildPrestoLauncher)
end

#Set config.properties
open("#{@presto_home}/etc/config.properties", 'w') do |f|
  	f.puts(setConfigProperties(clusterMetaData))
end

#Set jvm.config
open("#{@presto_home}/etc/jvm.config", 'w') do |f|
  	f.puts(setJVMConfig(clusterMetaData))
end

#Set Hive.config
open("#{@presto_home}/etc/catalog/hive.properties", 'w') do |f|
  	f.puts(setHiveProperties(clusterMetaData,@parsed))
end

#Set node.properties
open("#{@presto_home}/etc/node.properties", 'w') do |f|
  	f.puts(setNodeConfig(clusterMetaData))
end

#Set IC Settings
conf = JSON.generate(configServiceIC)
open("/tmp/ic-logs.json", 'w') do |f|
  	f.puts(conf)
end
sudo "cp /tmp/ic-logs.json /etc/instance-controller/logs.json"

#Set Service-Nanny
#No Longer Using SN
=begin
conf = JSON.generate(configServiceNanny)
open("/tmp/sn-presto.conf", 'w') do |f|
  	f.puts(conf)
end
sudo "cp /tmp/sn-presto.conf /etc/service-nanny/presto.conf"
=end

#Set Log Properties
open("#{@presto_home}/etc/log.properties", 'w') do |f|
  	f.puts(buildLogProperties)
end

#Create Presto Wrapper for CLI if CLI to be installed
if @parsed[:cli] == true
	run "/tmp/rDownloader #{@cli_jar} /tmp/presto-cli-executable.jar"
	run "cp /tmp/presto-cli-executable.jar #{@presto_home}"
	run "chmod +x #{@presto_home}/presto-cli-executable.jar"
	if clusterMetaData['isMaster'] == true
		open("/home/hadoop/presto-cli", 'w') do |f|
		  	f.puts(buildCLIWrapper)
		end
		run "chmod +x /home/hadoop/presto-cli"
		sudo "ln -s /home/hadoop/presto-cli /usr/bin/"
	end
end

#Set Symnlinkg For Presto to Home-Folder
if File.exist? "/home/hadoop/hive/bin/hive-init"
	run "rm -f home/hadoop/presto-server"
end
run "ln -s #{@presto_home} /home/hadoop/presto-server"

def launchMetaStoreLauncher
	open("/tmp/start-metastore", 'w') do |f|
	  	f.write("
	  		#!/bin/bash
			while true; do
			HIVE_SERVER=$(ps aux | grep hiveserver2 | grep -v grep | awk '{print $2}')
			if [ $HIVE_SERVER ]; then
			        sleep 10
			        echo Hive Server Running, Lets Check the Metastore
			        STORE_PID=$(ps aux | grep -i metastore | grep -v grep | grep -v \"start-metastore\"| awk '{print $2}')
			        if [ \"$STORE_PID\" ]; then
			                for pid in $STORE_PID; do
			                        echo killing pid $pid
			                        sudo kill -9 $pid
			                done
			        fi
			        echo Launching Metastore
			        /home/hadoop/hive/bin/hive --service metastore -p #{@parsed[:port]} 2>&1 >> /mnt/var/log/apps/hive-metastore.log &
			        exit 0
			fi
			echo Hive Server Not Running Yet
			sleep 10;
			done
	  	")
	end
	run "chmod +x /tmp/start-metastore"
	run "/tmp/start-metastore 2>&1 >> /mnt/var/log/apps/meta-store-starter.log &"
end

#Set The MetaStore
=begin
if clusterMetaData['isMaster'] == true

	if !@parsed[:metaURI]
		launchMetaStoreLauncher
	end
end
=end
	

#Restart IC and SN
=begin
def reloadServiceNanny
  puts "restart service-nanny"
  if File.exists?('/mnt/var/run/service-nanny/service-nanny.pid')
    sudo 'kill -9 `cat /mnt/var/run/service-nanny/service-nanny.pid`'
  else
    sudo '/etc/init.d/service-nanny start'
  end
end


def reloadIC
  puts "restart instance-controller"
  if File.exists?('/mnt/var/run/instance-controller/instance-controller.pid')
    sudo '/etc/init.d/instance-controller restart'
  else
    sudo '/etc/init.d/instance-controller start'
  end
end
=end

#sudo "/etc/init.d/service-nanny stop"
#sudo "/etc/init.d/service-nanny start"

#sudo "/etc/init.d/instance-controller stop"
#sudo "/etc/init.d/instance-controller start"


#Now Using Upstart, So Lets build the Upstart Config
def upstartConfig(clusterMetaData)
	if clusterMetaData['isMaster'] == true
		startCond = "start on runlevel [2345] and on started hive-metastore"
	else
		startCond = "start on runlevel [2345]"
	end
	config = "# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the \"License\"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an \"AS IS\" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

description \"Presto Launcher\"
author \"mombergm\"

#{startCond}
stop on runlevel [016]

start on started netfs
start on started rsyslog
start on started hive-metastore

stop on stopping netfs
stop on stopping rsyslog
stop on stopping hive-metastore

respawn

# respawn unlimited times with 5 seconds time interval
respawn limit 0 5

env SLEEP_TIME=10

env DAEMON=\"presto-server\"
env DESC=\"Presto Server Deamon\"
env EXEC_PATH=\"#{@presto_home}/bin/launcher\"
env SVC_USER=\"hadoop\"
env DAEMON_FLAGS=\"\"
env CONF_DIR=\"#{@presto_home}/conf\"
env PIDFILE=\"/mnt/var/log/presto/var/run/launcher.pid\"
env WORKING_DIR=\"#{@presto_home}\"

pre-start script
	  install -d -m 0755 -o $SVC_USER -g $SVC_USER $(dirname $PIDFILE) 1>/dev/null 2>&1 || :

	  LOG_FILE=/mnt/var/log/presto/presto.out
	  mkdir -p /mnt/var/log/presto
	  chown -R hadoop:hadoop /mnt/var/log/presto
    su -s /bin/bash $SVC_USER -c \"$EXEC_PATH start &> /mnt/var/log/presto/var/run/launcher.out\"
end script

script
  # sleep for sometime for the daemon to start running
  sleep $SLEEP_TIME
  if [ ! -f $PIDFILE ]; then
    echo \"$PIDFILE not found\"
    exit 1
  fi
  pid=$(<\"$PIDFILE\")
  while ps -p $pid > /dev/null; do
    sleep $SLEEP_TIME
  done
  echo \"$pid stopped running...\"

end script

pre-stop script

 # do nothing

end script

post-stop script
  if [ ! -f $PIDFILE ]; then
    echo \"$PIDFILE not found\"
    exit
  fi
  pid=$(<\"$PIDFILE\")
  if kill $pid > /dev/null 2>&1; then
    echo \"process $pid is killed\"
  fi
  rm -rf $PIDFILE
end script
"
return config
end

open("/tmp/presto-init.conf", 'w') do |f|
  	f.puts(upstartConfig(clusterMetaData))
end
sudo "mkdir -p /mnt/var/log/presto"
sudo "chown -R hadoop:hadoop /mnt/var/log/presto"
sudo "chown -R hadoop:hadoop #{@presto_home}"
sudo "cp /tmp/presto-init.conf /etc/init/presto.conf"
sudo "chmod +x /etc/init/presto.conf"
sudo "initctl reload-configuration"
sudo "initctl start presto"

#reloadServiceNanny
#reloadIC
puts "If Nothing Went Wrong, You should now have a Latest Version of Presto Installed"
exit! 0

