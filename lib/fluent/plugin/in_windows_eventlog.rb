require 'win32/eventlog'
require 'fluent/plugin/input'
require 'fluent/plugin'

module Fluent::Plugin
  class WindowsEventLogInput < Input
    Fluent::Plugin.register_input('windows_eventlog', self)

    helpers :timer

    @@KEY_MAP = {"record_number" => :record_number,
                 "time_generated" => :time_generated,
                 "time_written" => :time_written,
                 "event_id" => :event_id,
                 "event_type" => :event_type,
                 "event_category" => :category,
                 "source_name" => :source,
                 "computer_name" => :computer,
                 "user" => :user,
                 "description" => :description}

    config_param :tag, :string
    config_param :read_interval, :time, :default => 2
    config_param :pos_file, :string, :default => nil
    config_param :channel, :string, :default => 'Application'
    config_param :key, :string, :default => ''
    config_param :read_from_head, :bool, :default => false
    config_param :from_encoding, :string, :default => nil
    config_param :encoding, :string, :default => nil

    attr_reader :chs

    def initialize
      super
      @chs = []
      @keynames = []
      @tails = {}
    end

    def configure(conf)
      super
      @chs = @channel.split(',').map {|ch| ch.strip.downcase }.uniq
      if @chs.empty?
        raise Fluent::ConfigError, "winevtlog: 'channel' parameter is required on winevtlog input"
      end
      @keynames = @key.split(',').map {|k| k.strip }.uniq
      if @keynames.empty?
        @keynames = @@KEY_MAP.keys
      end
      @tag = tag
      @stop = false
      configure_encoding
      @receive_handlers = if @encoding
                            method(:encode_record)
                          else
                            method(:no_encode_record)
                          end
    end

    def configure_encoding
      unless @encoding
        if @from_encoding
          raise Fluent::ConfigError, "winevtlog: 'from_encoding' parameter must be specied with 'encoding' parameter."
        end
      end

      @encoding = parse_encoding_param(@encoding) if @encoding
      @from_encoding = parse_encoding_param(@from_encoding) if @from_encoding
    end

    def parse_encoding_param(encoding_name)
      begin
        Encoding.find(encoding_name) if encoding_name
      rescue ArgumentError => e
        raise Fluent::ConfigError, e.message
      end
    end

    def encode_record(record)
      if @encoding
        if @from_encoding
          record.encode!(@encoding, @from_encoding)
        else
          record.force_encoding(@encoding)
        end
      end
    end

    def no_encode_record(record)
      record
    end

    def start
      super
      if @pos_file
        @pf_file = File.open(@pos_file, File::RDWR|File::CREAT|File::BINARY)
        @pf_file.sync = true
        @pf = PositionFile.parse(@pf_file)
      end
      start_watchers(@chs)
    end

    def shutdown
      stop_watchers(@tails.keys, true)
      @pf_file.close if @pf_file
      super
    end

    def setup_wacther(ch, pe)
      wlw = WindowsLogWatcher.new(ch, pe, &method(:receive_lines))
      wlw.attach do |watcher|
        wlw.timer_trigger = timer_execute(:in_winevtlog, @read_interval, &watcher.method(:on_notify))
      end
      wlw
    end

    def start_watchers(chs)
      chs.each { |ch|
        pe = nil
        if @pf
          pe = @pf[ch]
          if @read_from_head && pe.read_num.zero?
            el = Win32::EventLog.open(ch)
            pe.update(el.oldest_record_number-1,1)
            el.close
          end
        end
        @tails[ch] = setup_wacther(ch, pe)
      }
    end

    def stop_watchers(chs, unwatched = false)
      chs.each { |ch|
        wlw = @tails.delete(ch)
        if wlw
          wlw.unwatched = unwatched
          close_watcher(wlw)
        end
      }
    end

    def close_watcher(wlw)
      wlw.close
      # flush_buffer(wlw)
    end

    def receive_lines(ch, lines, pe)
      return if lines.empty?
      begin
        for r in lines
          h = {"channel" => ch}
          @keynames.each {|k| h[k]=@receive_handlers.call(r.send(@@KEY_MAP[k]).to_s)}
          #h = Hash[@keynames.map {|k| [k, r.send(@@KEY_MAP[k]).to_s]}]
          router.emit(@tag, Fluent::Engine.now, h)
          pe[1] +=1
        end
      rescue
        $log.error "unexpected error", :error=>$!.to_s
        $log.error_backtrace
      end
    end


    class WindowsLogWatcher
      def initialize(ch, pe, &receive_lines)
        @ch = ch
        @pe = pe || MemoryPositionEntry.new
        @receive_lines = receive_lines
        @timer_trigger = nil
      end

      attr_reader   :ch
      attr_accessor :unwatched
      attr_accessor :pe
      attr_accessor :timer_trigger

      def attach
        yield self
        on_notify
      end

      def detach
        @timer_trigger.detach if @timer_trigger.attached?
      end

      def close
        detach
      end

      def on_notify
        el = Win32::EventLog.open(@ch)
        rl_sn = [el.oldest_record_number, el.total_records]
        pe_sn = [@pe.read_start, @pe.read_num]
        # if total_records is zero, oldest_record_number has no meaning.
        if rl_sn[1] == 0
          return
        end

        if pe_sn[0] == 0 && pe_sn[1] == 0
          @pe.update(rl_sn[0], rl_sn[1])
          return
        end

        cur_end = rl_sn[0] + rl_sn[1] -1
        old_end = pe_sn[0] + pe_sn[1] -1

        if (rl_sn[0] < pe_sn[0])
          # may be a record number rotated.
          cur_end += 0xFFFFFFFF
        end

        if (cur_end < old_end)
          # something occured.
          @pe.update(rl_sn[0], rl_sn[1])
          return
        end

        read_more = false
        begin
          numlines = cur_end - old_end

          winlogs = el.read(Win32::EventLog::SEEK_READ | Win32::EventLog::FORWARDS_READ, old_end + 1)
          @receive_lines.call(@ch, winlogs, pe_sn)

          @pe.update(pe_sn[0], pe_sn[1])
          old_end = pe_sn[0] + pe_sn[1] -1
        end while read_more
        el.close
      end
    end

    class PositionFile
      def initialize(file, map, last_pos)
        @file = file
        @map = map
        @last_pos = last_pos
      end

      def [](ch)
        if m = @map[ch]
          return m
        end
        @file.pos = @last_pos
        @file.write ch
        @file.write "\t"
        seek = @file.pos
        @file.write "00000000\t00000000\n"
        @last_pos = @file.pos
        @map[ch] = FilePositionEntry.new(@file, seek)
      end

      # parsing file and rebuild mysself
      def self.parse(file)
        map = {}
        file.pos = 0
        file.each_line {|line|
          # check and get a matched line as m
          m = /^([^\t]+)\t([0-9a-fA-F]+)\t([0-9a-fA-F]+)/.match(line)
          next unless m
          ch = m[1]
          pos = m[2].to_i(16)
          seek = file.pos - line.bytesize + ch.bytesize + 1
          map[ch] = FilePositionEntry.new(file, seek)
        }
        new(file, map, file.pos)
      end
    end

    class FilePositionEntry
      START_SIZE = 8
      NUM_OFFSET = 9
      NUM_SIZE   = 8
      LN_OFFSET = 17
      SIZE = 18

      def initialize(file, seek)
        @file = file
        @seek = seek
      end

      def update(start, num)
        @file.pos = @seek
        @file.write "%08x\t%08x" % [start, num]
      end

      def read_start
        @file.pos = @seek
        raw = @file.read(START_SIZE)
        raw ? raw.to_i(16) : 0
      end

      def read_num
        @file.pos = @seek + NUM_OFFSET
        raw = @file.read(NUM_SIZE)
        raw ? raw.to_i(16) : 0
      end
    end

    class MemoryPositionEntry
      def initialize
        @start = 0
        @num = 0
      end

      def update(start, num)
        @start = start
        @num = num
      end

      def read_start
        @start
      end

      def read_num
        @num
      end
    end

  end
end
