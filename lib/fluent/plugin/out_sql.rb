module Fluent
  class SQLOutput < BufferedOutput
    Plugin.register_output('sql', self)

    include SetTimeKeyMixin
    include SetTagKeyMixin

    config_param :host, :string
    config_param :port, :integer, :default => nil
    config_param :adapter, :string
    config_param :username, :string, :default => nil
    config_param :password, :string, :default => nil
    config_param :database, :string
    config_param :remove_tag_prefix, :string, :default => nil

    attr_accessor :tables

    unless method_defined?(:log)
      define_method(:log) { $log }
    end

    # TODO: Merge SQLInput's TableElement
    class TableElement
      include Configurable

      config_param :table, :string
      config_param :key_names, :string, :default => nil
      config_param :column_names, :string

      attr_reader :model
      attr_reader :pattern

      def initialize(pattern, log)
        super()
        @pattern = MatchPattern.create(pattern)
        @log = log
      end

      def configure(conf)
        super

        @column_names = @column_names.split(',')
        if @key_names.nil?
          @format_proc = Proc.new { |record|
            new_record = {}
            @column_names.each { |c|
              new_record[c] = record[c]
            }
            new_record
          }
        else
          @key_names = @key_names.split(',')
          if @key_names.size != @column_names.size
            @log.warn "key_name and column_names are different size"
          end

          @format_proc = Proc.new { |record|
            new_record = {}
            @key_names.map.with_index { |k, i|
              new_record[@column_names[i]] = record[k]
            }
            new_record
          }
        end
      end

      def init(base_model)
        # See SQLInput for more details of following code
        table_name = @table
        @model = Class.new(base_model) do
          self.table_name = table_name
          self.inheritance_column = '_never_use_output_'
        end

        class_name = table_name.singularize.camelize
        base_model.const_set(class_name, @model)
        model_name = ActiveModel::Name.new(@model, nil, class_name)
        @model.define_singleton_method(:model_name) { model_name }

        # TODO: check column_names and table schema
        columns = @model.columns.map { |column| column.name }.sort
      end

      def import(chunk)
        records = []
        chunk.msgpack_each { |tag, time, data|
          begin
            # format process should be moved to emit / format after supports error stream.
            records << @model.new(@format_proc.call(data))
          rescue => e
            args = {:error => e.message, :error_class => e.class, :table => @table, :record => Yajl.dump(data)}
            @log.warn "Failed to create the model. Ignore a record:", args
          end
        }
        @model.import(records)
      end
    end

    def initialize
      super
      require 'active_record'
      require 'activerecord-import'
    end

    def configure(conf)
      super

      if remove_tag_prefix = conf['remove_tag_prefix']
        @remove_tag_prefix = Regexp.new('^' + Regexp.escape(remove_tag_prefix))
      end

      @tables = []
      @default_table = nil
      conf.elements.select { |e|
        e.name == 'table'
      }.each { |e|
        te = TableElement.new(e.arg, log)
        te.configure(e)
        if e.arg.empty?
          $log.warn "Detect duplicate default table definition" if @default_table
          @default_table = te
        else
          @tables << te
        end
      }
      @only_default = @tables.empty?

      if @default_table.nil?
        raise ConfigError, "There is no default table. <table> is required in sql output"
      end
    end

    def start
      super

      config = {
        :adapter => @adapter,
        :host => @host,
        :port => @port,
        :database => @database,
        :username => @username,
        :password => @password,
      }

      @base_model = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
      end

      SQLOutput.const_set("BaseModel_#{rand(1 << 31)}", @base_model)
      @base_model.establish_connection(config)

      # ignore tables if TableElement#init failed
      @tables.reject! do |te|
        init_table(te, @base_model)
      end
      init_table(@default_table, @base_model)
    end

    def shutdown
      super
    end

    def emit(tag, es, chain)
      if @only_default
        super(tag, es, chain)
      else
        super(tag, es, chain, format_tag(tag))
      end
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      @tables.each { |table|
        if table.pattern.match(chunk.key)
          return table.import(chunk)
        end
      }
      @default_table.import(chunk)
    end

    private

    def init_table(te, base_model)
      begin
        te.init(base_model)
        log.info "Selecting '#{te.table}' table"
        false
      rescue => e
        log.warn "Can't handle '#{te.table}' table. Ignoring.", :error => e
        log.warn_backtrace e.backtrace
        true
      end
    end

    def format_tag(tag)
      if @remove_tag_prefix
        tag.gsub(@remove_tag_prefix, '')
      else
        tag
      end
    end
  end
end