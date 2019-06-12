require 'optparse'
require 'pp'
require 'wdm'

Thread.abort_on_exception = true

class KSync
  Rules = []

  def initialize target, action: nil, recursive: false, &b
    Rules << self
    @target = target
    @action = action || b || raise("action is not given")
    @recursive = recursive
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
    $unaccept_filters.each{|f|
      return false if f =~ path
    }

    if $accept_filters.empty?
      true
    else
      $accept_filters.each{|f|
        return true if f =~ path
      }
      false
    end
  end

  def run
    monitor = WDM::Monitor.new
    monitor.send(@recursive ? :watch_recursively : :watch, @target){|change|
      if acceptable?(change.path)
        @q << [change, Time.now]
      end
    }
    monitor.run!
  end

  def self.run
    ts = Rules.map{|rule|
      Thread.new{
        rule.run
      }
    }
    ts.each{|t| t.join}
  end
end

def scp_handler_proc upload_paths, scp: $scp
  qs = upload_paths.map{|upload_path|
    q = Queue.new
    Thread.new{
      while files = q.pop
        cmd = "#{scp} #{files.join(' ')} #{upload_path}"
        # puts "$ #{cmd}"
        r = `#{cmd}`
        unless $?.success?
          puts "#{Time.now} faild: #{cmd} #{r}"
        else
          puts "#{Time.now} success: #{upload_path}"
        end
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

def rsync src, dsts
  dsts.each{|dst|
    STDERR. puts cmd = "rsync -avzr --exclude=.git --exclude=.svn #{src} #{dst}"
    system(cmd)
  }
end

def sync src, *dsts, type: :scp
  STDERR.puts src: src, dsts: dsts, type: type
  rsync src, dsts
  KSync.new(File.expand_path(src), action: send("#{type}_handler_proc", dsts))
end

def sync_r src, *dsts, type: :scp
  STDERR.puts recursive: true, src: src, dsts: dsts, type: type
  rsync src, dsts
  KSync.new(File.expand_path(src), action: send("#{type}_handler_proc", dsts), recursive: true)
end

#
# RC file notation
#
# Directory sync
#  sync 'src_dir/', 'user@dst_dir/'
#  sync 'src_dir/', 'user@dst_dir/', type: :scp
#  sync 'src_dir/', 'user@dst_dir/', type: :scp, scp: 'c:\ko1\app\putty\PSCP.EXE'
#
# File sync
#  sync 'dir/src_file', 'user@dst_dir/dst_file'
#
# Recursive
#
#  sync_r src, dst1, dst2, ...
#

# configuration variables

$unaccept_filters = [/\A\#/]
$accept_filters   = []
$wait_time = 1
$scp = 'scp'


if File.exist?(pscp = 'c:\ko1\app\putty\PSCP.EXE') # ko1's special
  $scp = pscp
end

opt = OptionParser.new
opt.on('--rc=[RCFILE]'){|rc|
  load(rc)
}
opt.on('--script=[SCRIPT]'){|script|
  eval(script)
}
opt.on('--scp=[SCPCMD]'){|s|
  $scp = s
}
opt.on('--wait-time=[SEC]'){|s|
  $wait_time = s.to_i
}
opt.on('--accept-filters=[REGEXP1 ...]'){|res|
  res.split(' ').each{|re|
    $accept_filters << Regexp.compile(re)
  }
}
opt.on('--unaccept-filters=[REGEXP1 ...]'){|res|
  res.split(' ').each{|re|
    $unaccept_filters << Regexp.compile(re)
  }
}

opt.parse!(ARGV)

unless ARGV.empty?
  sync './', *ARGV.to_a
end

STDOUT.sync = true
KSync.run
