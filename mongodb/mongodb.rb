#!/usr/bin/env ruby
#
# CopperEgg mongodb monitoring    mongodb.rb
#
# Copyright 2013 CopperEgg Corporation.  All rights reserved.
#
# License:: MIT License
#

require 'rubygems'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'mongo'

class CopperEggAgentError < Exception; end

####################################################################

def help
  puts "usage: $0 args"
  puts "Examples:"
  puts "  -c config.yml"
  puts "  -f 60                 (for 60s updates. Valid values: 5, 15, 60, 300, 900, 3600)"
  puts "  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)"
  puts "  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])"
end

TIME_STRING='%Y/%m/%d %H:%M:%S'
##########
# Used to prefix the log message with a date.
def log(str)
  begin
    str.split("\n").each do |str|
      puts "#{Time.now.strftime(TIME_STRING)} pid:#{Process.pid}> #{str}"
    end
    $stdout.flush
  rescue Exception => e
    # do nothing -- just catches unimportant errors when we kill the process
    # and it's in the middle of logging or flushing.
  end
end

def interruptible_sleep(seconds)
  seconds.times {|i| sleep 1 if !@interrupted}
end

def child_interrupt
  # do child clean-up here
  @interrupted = true
  log "Exiting pid #{Process.pid}"
end

def parent_interrupt
  log "INTERRUPTED"
  # parent clean-up
  @interrupted = true

  @worker_pids.each do |pid|
    Process.kill 'TERM', pid
  end

  log "Waiting for all workers to exit"
  Process.waitall

  if @monitor_thread
    log "Waiting for monitor thread to exit"
    @monitor_thread.join
  end

  log "Exiting cleanly"
  exit
end

####################################################################

# get options
opts = GetoptLong.new(
  ['--help',      '-h', GetoptLong::NO_ARGUMENT],
  ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
  ['--verbose',   '-v', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

config_file = "config.yml"
@apihost = nil
@debug = false
@verbose = false
@freq = 60  # update frequency in seconds
@interupted = false
@worker_pids = []
@services = []

# Options and examples:
opts.each do |opt, arg|
  case opt
  when '--help'
    help
    exit
  when '--debug'
    @debug = true
  when '--verbose'
    @verbose = true
  when '--config'
    config_file = arg
  when '--apikey'
    CopperEgg::Api.apikey = arg
  when '--frequency'
    @freq = arg.to_i
  when '--apihost'
    CopperEgg::Api.host = arg
  end
end

# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  # load config
  if !@config["copperegg"].nil?
    CopperEgg::Api.apikey = @config["copperegg"]["apikey"] if !@config["copperegg"]["apikey"].nil? && CopperEgg::Api.apikey.nil?
    CopperEgg::Api.host = @config["copperegg"]["host"] if !@config["copperegg"]["host"].nil?
    @freq = @config["copperegg"]["frequency"] if !@config["copperegg"]["frequency"].nil?
    @services = @config['copperegg']['services']
  else
    log "You have no copperegg entry in your config.yml!"
    log "Edit your config.yml and restart."
    exit
  end
end

if CopperEgg::Api.apikey.nil?
  log "You need to supply an apikey with the -k option or in the config.yml."
  exit
end

if @services.length == 0
  log "No services listed in the config file."
  log "Nothing will be monitored!"
  exit
end

@freq = 60 if ![5, 15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."


####################################################################

def connect_to_mongo(hostname, port, user, pw, db)

  begin
    connection = Mongo::Connection.new(hostname,port,:slave_ok=>true)
  rescue CopperEggAgentError.new("Unable to connect to Mongo at #{hostname}:#{port}")
    return nil
  end

  mongo = connection.db(db)
  begin 
    mongo.authenticate(user,pw) unless pw.nil?
  rescue Exception => e
    log "Error connecting to mongodb #{db}, on #{hostname}:#{port}"
    return nil
  end
  return  mongo
end

def monitor_mongodb(mongo_servers, group_name)
  log "Monitoring mongo databases: "
  return if @interrupted

  while !@interupted do
    return if @interrupted

    mongo_servers.each do |mhost|
      return if @interrupted

      my_dbs = mhost['databases']
      my_dbs.each do |dbname|
        return if @interrupted
        mongo_db = connect_to_mongo(mhost["hostname"], mhost["port"], dbname["username"], dbname["password"], dbname['name'])

        if mongo_db 
          begin
            dbstats = mongo_db.stats
          rescue Exception => e
            log "Error getting mongo stats for database: #{mhost['database']} [skipping]"
            next
          end
          metrics = {}
          metrics['db_objects']            = dbstats['objects'].to_i
          metrics['db_indexes']            = dbstats['indexes'].to_i
          metrics['db_datasize']           = (dbstats['datasize'].to_f/(1024*1024).to_f)
          metrics['db_storage_size']       = (dbstats['storage_size'].to_f/(1024*1024).to_f)
          metrics['db_index_size']         = (dbstats['index_size'].to_f/(1024*1024).to_f)
        end

        oname = mhost['name'] + '-' + dbname['name']
        puts "#{group_name} - #{mhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
        rslt = CopperEgg::MetricSample.save(group_name, oname, Time.now.to_i, metrics)
      end
    end
    interruptible_sleep @freq
  end
end


def monitor_mongo_dbadmin(mongo_servers, group_name)
  log "Monitoring mongo admin: "
  return if @interrupted

  while !@interupted do
    return if @interrupted

    mongo_servers.each do |mhost|
      return if @interrupted

      mongo_admin = connect_to_mongo(mhost["hostname"], mhost["port"], mhost["username"], mhost["password"], 'admin')
      if mongo_admin 
        begin
          mstats = mongo_admin.command('serverStatus' => 1)
        rescue Exception => e
          log "Error getting mongo admin stats from: #{mhost['hostname']} [skipping]"
          next
        end
        metrics = {}
        metrics['btree_accesses']           = mstats['indexCounters']['accesses'].to_i
        metrics['btree_misses']             = mstats['indexCounters']['misses'].to_i
        metrics['btree_hits']               = mstats['indexCounters']['hits'].to_i
        metrics['cursors_totalOpen']        = mstats['cursors']['totalOpen'].to_i
        metrics['cursors_timedOut']         = mstats['cursors']['timedOut'].to_i
        metrics['op_inserts']               = mstats['opcounters']['insert'].to_i
        metrics['op_queries']               = mstats['opcounters']['query'].to_i
        metrics['op_updates']               = mstats['opcounters']['update'].to_i
        metrics['op_deletes']               = mstats['opcounters']['delete'].to_i
        metrics['op_getmores']              = mstats['opcounters']['getmore'].to_i
        metrics['op_commands']              = mstats['opcounters']['command'].to_i
        metrics['asserts_regular']          = mstats['asserts']['regular'].to_i
        metrics['asserts_warning']          = mstats['asserts']['warning'].to_i
        metrics['asserts_msg']              = mstats['asserts']['msg'].to_i
        metrics['asserts_user']             = mstats['asserts']['user'].to_i
        metrics['asserts_rollover']         = mstats['asserts']['rollovers'].to_i
        metrics['connections_available']    = mstats['connections']['available'].to_i
        metrics['connections_current']      = mstats['connections']['current'].to_i
        metrics['mem_resident']             = mstats['mem']['resident'].to_i
        metrics['mem_virtual']              = mstats['mem']['virtual'].to_i
        metrics['mem_mapped']               = mstats['mem']['mapped'].to_i
        metrics['globalLock_ratio']         = (mstats['globalLock']['lockTime'] / mstats['globalLock']['totalTime']).to_f
        metrics['globalLock_currentQueue']  = mstats['globalLock']['currentQueue']['total'].to_i
        metrics['globalLock_activeClients'] = mstats['globalLock']['activeClients']['total'].to_i
        metrics['uptime']                   = mstats['uptime'].to_i

        #  TODO add replication status check
        #  rstatus = mongo_admin.command({'replSetGetStatus' => 1}, :check_response => false)

      end

      puts "#{group_name} - #{mhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      rslt = CopperEgg::MetricSample.save(group_name, mhost["name"], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_mongodb_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating mongo db metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating Mongo db metric group"
    metric_group.frequency = @freq
  end
  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge", :name => "db_objects",      :unit => "objects"}
  metric_group.metrics << {:type => "ce_gauge", :name => "db_indexes",      :unit => "indexes"}
  metric_group.metrics << {:type => "ce_gauge", :name => "db_datasize",     :unit => "megabytes"}
  metric_group.metrics << {:type => "ce_gauge", :name => "db_storage_size", :unit => "megabytes"}
  metric_group.metrics << {:type => "ce_gauge", :name => "db_index_size",   :unit => "megabytes"}

  metric_group.save
  metric_group
end

def ensure_mongo_dbadmin_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating mongo dbadmin metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating Mongo dbadmin metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_counter", :name => "btree_accesses",            :unit => "accesses"}
  metric_group.metrics << {:type => "ce_counter", :name => "btree_misses",              :unit => "misses"}
  metric_group.metrics << {:type => "ce_counter", :name => "btree_hits",                :unit => "hits"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "cursors_totalOpen",         :unit => "cursors"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "cursors_timedOut",          :unit => "ops/s"}
  metric_group.metrics << {:type => "ce_counter", :name => "op_inserts",                :unit => "inserts"}
  metric_group.metrics << {:type => "ce_counter", :name => "op_queries",                :unit => "queries"}
  metric_group.metrics << {:type => "ce_counter", :name => "op_updates",                :unit => "updates"}
  metric_group.metrics << {:type => "ce_counter", :name => "op_deletes",                :unit => "deletes"}
  metric_group.metrics << {:type => "ce_counter", :name => "op_getmores",               :unit => "getmores"}
  metric_group.metrics << {:type => "ce_counter", :name => "op_commands",               :unit => "commands"}
  metric_group.metrics << {:type => "ce_counter", :name => "asserts_regular",           :unit => "asserts"}
  metric_group.metrics << {:type => "ce_counter", :name => "asserts_warning",           :unit => "asserts"}
  metric_group.metrics << {:type => "ce_counter", :name => "asserts_msg",               :unit => "asserts"}
  metric_group.metrics << {:type => "ce_counter", :name => "asserts_user",              :unit => "asserts"}
  metric_group.metrics << {:type => "ce_counter", :name => "asserts_rollover",          :unit => "asserts"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "connections_available",     :unit => "connections"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "connections_current",       :unit => "connections"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "mem_resident",              :unit => "megabytes"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "mem_virtual",               :unit => "megabytes"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "mem_mapped",                :unit => "megabytes"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "globalLock_ratio",          :unit => ""}
  metric_group.metrics << {:type => "ce_gauge",   :name => "globalLock_currentQueue",   :unit => "entries"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "globalLock_activeClients",  :unit => "clients"}
  metric_group.metrics << {:type => "ce_counter", :name => "uptime",                    :unit => "seconds"}
  metric_group.save
  metric_group
end

def create_mongo_dashboard(metric_group, name, server_list)
  log "Creating new MongDB Dashboard"
  servers = server_list.map {|server_entry| server_entry["name"]}
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
  # Create a dashboard for only the servers we've defined:
  #CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => servers, :metrics => metrics)
end

####################################################################

# init - check apikey? make sure site is valid, and apikey is ok
trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }

#################################

def ensure_metric_group(metric_group, service)
  if service == "mongo_dbadmin"
    return ensure_mongo_dbadmin_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "mongodb"
    return ensure_mongodb_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if (service == "mongo_dbadmin") || (service == "mongodb")
    create_mongo_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == "mongo_dbadmin"
    monitor_mongo_dbadmin(@config[service]["servers"], metric_group.name)
  elsif service == "mongodb"
    monitor_mongodb(@config[service]["servers"], metric_group.name)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

#################################

MAX_RETRIES = 30
last_failure = 0

MAX_SETUP_RETRIES = 5
setup_retries = MAX_SETUP_RETRIES

begin
  dashboards = CopperEgg::CustomDashboard.find
  metric_groups = CopperEgg::MetricGroup.find
rescue => e
  log "Error connecting to server.  Retying (#{setup_retries}) more times..."
  raise e if @debug
  sleep 2
  setup_retries -= 1
  retry if setup_retries > 0
  # If we can't succeed with setup on the servcies, let's just error out
  raise e
end


@services.each do |service|
  if @config[service] && @config[service]["servers"].length > 0
    begin
      log "Checking for existence of metric group for #{service}"
      metric_group = metric_groups.detect {|m| m.name == @config[service]["group_name"]}
      metric_group = ensure_metric_group(metric_group, service)
      raise "Could not create a metric group for #{service}" if metric_group.nil?
      log "Checking for existence of #{@config[service]['dashboard']}"
      dashboard = dashboards.detect {|d| d.name == @config[service]["dashboard"]} || create_dashboard(service, metric_group)
      log "Could not create a dashboard for #{service}" if dashboard.nil?
    rescue => e
      log e.message
      next
    end

    child_pid = fork {
      trap("INT") { child_interrupt if !@interrupted }
      trap("TERM") { child_interrupt if !@interrupted }
      last_failure = 0
      retries = MAX_RETRIES
      begin
        monitor_service(service, metric_group)
      rescue => e
        log "Error monitoring #{service}.  Retying (#{retries}) more times..."
        # updated 7-9-2013, removed the # before if @debug
        raise e   if @debug
        sleep 2
        retries -= 1
        # reset retries counter if last failure was more than 10 minutes ago
        retries = MAX_RETRIES if Time.now.to_i - last_failure > 600
        last_failure = Time.now.to_i
      retry if retries > 0
        raise e
      end
    }
    @worker_pids.push child_pid
  end
end

# ... wait for all processes to exit ...
p Process.waitall

