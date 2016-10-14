$wait_time = 1

Thread.abort_on_exception = true

require 'wdm'
class KSync
  def initialize target, action: nil, &b
    @target = target
    @action = action || b || raise("action is not given")
    @q = Queue.new
    @th = Thread.new{
      tasks = []
      while (wdm, time = @q.pop)
        wait_time = $wait_time - (Time.now.to_i - time.to_i)
        # p [wdm, time, wait_time, @q.empty?]
        case
        when wait_time > 0
          flush_task tasks
          sleep wait_time
          check_task tasks, wdm
        when @q.empty?
          check_task tasks, wdm
          flush_task tasks
        else
          check_task tasks, wdm
        end
      end
    }
  end

  # invoked from working threads
  def action files
    @action.call(files) unless files.empty?
  end

  def flush_task tasks
    action tasks.map{|e| e.path}.sort.uniq
    tasks.clear
  end

  def check_task tasks, wdm
    if File.exist?(wdm.path)
      tasks << wdm
    end
  end

  # filter
  def acceptable? path
    case path
    when /\A\#/
      false
    else
      true
    end
  end

  def run
    monitor = WDM::Monitor.new
    monitor.watch(@target){|change|
      if acceptable?(change.path)
        @q << [change, Time.now]
      end
    }
    monitor.run!
  end
end

def pscp_action_proc upload_paths
  qs = upload_paths.map{|upload_path|
    q = Queue.new
    Thread.new{
      while files = q.pop
        cmd = 'c:\ko1\app\putty\PSCP.EXE ' + "#{files.join(' ')} #{upload_path}"
        puts "$ #{cmd}"
        system(cmd)
      end
    }
    q
  }
  lambda{|files|
    qs.each{|q|
      q << files
    }
  }
end

require 'optparse'
require 'pp'

STDOUT.sync = true
ks = KSync.new(File.expand_path('./'), action: pscp_action_proc(ARGV.to_a))
ks.run
