#!/usr/bin/env ruby
require 'rubygems'
require 'json'
require 'logger'
require 'optparse'
require 'usagewatch'

$options = {}
optparse = OptionParser.new do|opts|
[
  ['verbose', false, 'v', nil, 'Output more information', lambda {|b| true }],
  ['debug', false, 'D', nil, 'Output more information', lambda {|p| true }],
  ['api_name', nil, 'a', 'APINAME', 'instance type', lambda {|p| p}],
  ['region', 'us-east-1', 'r', 'REGION', 'AWS region', lambda {|p| p}],
  ['distribution', :auto, 'q', 'DIST', 'Linux distribution', lambda{|p| p}],

  ['cpu', :auto, 'c', 'TOTALLOAD', 'Load like from uptime', lambda {|p| p.to_f}],
  ['cpu_type', 'sar', 'C', 'TYPE', 'uptime, sar', lambda {|p| p}],
  ['memory', :auto, 'm', 'MEMORYGB', 'RAM in GB', lambda {|p| p.to_f}],
  ['disk', nil, 'd', 'GB', 'disk in GB', lambda {|p| p.to_f}],
  ['net_bandwidth', nil, 'n', 'MB/s', 'MegaBytes per second', lambda {|p| p.to_f}],
  ['target_peak', 0.5, 't', '%', 'percentage of peake.g. 0.7 = 70% peak', lambda{|p| p.to_f}],
  ].each do |option, default_value, short_option, arg, desc, proc|
    $options[option.to_sym] = default_value
    opts.on("-#{short_option}", "--#{option} #{arg}".strip, desc) do |p|
      $options[option.to_sym] = proc.call(p)
    end
  end
end
optparse.parse!


def info(_str)
  puts _str if $options[:verbose]
end
def debug(_str)
  puts _str if $options[:debug]
end

info "options: #{$options.inspect}"

if $options[:distribution] == :auto
  if File.exist? '/etc/redhat-release'
    $options[:distribution] = :redhat
  end
end

require 'bigdecimal'
require 'statsd'

class Float
  def round(val=0)
     BigDecimal.new(self.to_s).round(val).to_f
  end
end

class InstanceInfo
  attr_accessor :mem, :ecu, :disk, :max_bandwidth, :api_name, :linux_cost, :feasible, :vcpu

  def initialize(kwargs)
    @mem = kwargs[:mem].to_f || 1
    @ecu = kwargs[:ecu].to_f || 1
    @vcpu = kwargs[:vcpu].to_f || 1
    @disk = kwargs[:disk].to_f || 1
    @max_bandwidth = kwargs[:max_bandwidth] || 1
    @api_name = kwargs[:api_name] || 'm1.small'
    @linux_cost = kwargs[:linux_cost].to_f || 0.01
  end
end

class InstancePick
  def doit
    linux_od = JSON.parse(File.read 'instances.json')

    instance_types = []

    linux_od.each do |r|
      debug "r: #{r.inspect}"
      i = InstanceInfo.new(
        :api_name => r['instance_type'],
        :vcpu => r['vCPU'], 
        :mem => r['memory'],
        :linux_cost => r['pricing'][$options[:region]]['linux']
      )

      i.max_bandwidth = r['max_bandwidth']
      if r['max_bandwidth'] == 0
        i.max_bandwidth = 1000 / 8.0 # 1Gb/s 
      end

      i.ecu = r['ECU']
      if r['ECU'] == 0
        i.ecu = r['vCPU']
      end

      if r.has_key? 'storage' && !r['storage'].nil?
        i.disk = r['storage']['devices'] * r['storage']['size'].to_f
      end
      debug "i: #{i.inspect}"
      instance_types << i
    end

    target_peak = $options[:target_peak]

    api_name = $options[:api_name]
    debug "api_name: #{api_name}"
    this_instance_type = instance_types.find {|t| t.api_name == api_name }
    debug "this_instance_type: #{this_instance_type.inspect}"

    usw = Usagewatch
    if $options[:cpu_type] == 'sar'
      debug "using sar"
      total_processing_used_percent = (100.0 - `sar -u`.map{|x|Float(x.split[-1]) rescue nil}.compact.min) / 100.0
      cpu_load = total_processing_used_percent * this_instance_type.vcpu
    elsif $options[:cpu] == :auto || $options[:cpu_type] == 'uptime'
      cpu_load = `uptime`.split[-1].to_f
    else
      cpu_load = $options[:cpu]
    end

    if $options[:memory] == :auto
      mem = usw.uw_memused * this_instance_type.mem / 100.0
    else
      mem = $options[:memory]
    end

    max_bandwidth = ([usw.uw_bandrx, usw.uw_bandtx].max) / 8.0
    debug "usw bandwidth: %0.2f options: %0.2f" % [max_bandwidth, $options[:net_bandwidth] || 0.0]
    max_bandwidth ||= $options[:net_bandwidth]

    compute_units = this_instance_type.ecu
    ecu_per_core = compute_units.to_f / this_instance_type.vcpu
    ecu = cpu_load * ecu_per_core
    debug "cpu_load: %0.2f compute_units: %d ecu/core: %.2f ecu: %.2f" % [cpu_load, compute_units, ecu_per_core, ecu]
    disk_usage = $options[:disk]
    current_usage = InstanceInfo.new(
      :current_count => 1,
      :mem => mem,
      :ecu => ecu,
      :disk => disk_usage,
      :api_name => api_name,
      :max_bandwidth =>  max_bandwidth,
      :linux_cost => this_instance_type.linux_cost
    )

    info "current_usage: #{current_usage.inspect}"

    target_usage = InstanceInfo.new(
      :mem => current_usage.mem / target_peak,
      :ecu => current_usage.ecu / target_peak,
      :disk => current_usage.disk / target_peak,
      :max_bandwidth => current_usage.max_bandwidth / target_peak
    )

    info "target_usage: #{target_usage.inspect}"

    first_feasible = nil
    feasible_instance_types = []
    t = target_usage
    instance_types.sort! { |a,b| a.linux_cost <=> b.linux_cost}
    instance_types.each do |i|
      name = '%20s' % i.api_name
      if i.mem >= t.mem &&
         i.ecu >= t.ecu &&
         i.disk >= t.disk &&
         i.max_bandwidth >= t.max_bandwidth

         i.feasible = true
         first_feasible = i if first_feasible.nil?
      end
      feasible_instance_types << i
    end

    debug '    api_name    mem  ecu     disk  net monthly_cost hourly feasible'
    feasible_instance_types.each do |f|
      info '%12s %6.1f %4.0f %8.1f %4.0f %12.2f %6.2f %s' % [
        f.api_name, f.mem, f.ecu, f.disk, f.max_bandwidth, f.linux_cost * 24 * 30, f.linux_cost, f.feasible
      ]
      info '^^^^^^^^  current cluster' if current_usage.api_name == f.api_name
    end


    puts "current_cost #{current_usage.linux_cost.to_f} monthly: #{current_usage.linux_cost.to_f*24*30}"
    puts "lowest_cost #{first_feasible.linux_cost.to_f} monthly: #{first_feasible.linux_cost.to_f*24*30}"
    overspend = current_usage.linux_cost - first_feasible.linux_cost
    puts "overspend #{overspend} monthly: #{overspend*24*30}"
    
    statsd = Statsd.new
    statsd.gauge('aws.ec2.cost.current', current_usage.linux_cost.to_f)
    statsd.gauge('aws.ec2.cost.lowest', first_feasible.linux_cost.to_f)
    statsd.gauge('aws.ec2.cost.overspend', overspend.to_f)
  end
end

picker = InstancePick.new
picker.doit
