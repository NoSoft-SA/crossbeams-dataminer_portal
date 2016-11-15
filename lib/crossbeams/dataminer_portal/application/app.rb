#TODO: This should probably be changed to use Sinatra::Base so that Object is not poluted with Sinatra methods...
#      - Use filenames instead of ids as keys.
#      - Change this to just handle routes and pass the coding on to external objects.
#      - code reloading
require 'sinatra'
require 'sinatra/contrib'
require 'sequel'
require 'rack-flash'

module Crossbeams
  module DataminerPortal

    class ConfigMerger
      # Write a new config file by applying the client-specific settings over the defaults.
      def self.merge_config_files(base_file, over_file, new_config_file_name)
        f = File.open(new_config_file_name, 'w')
        YAML.dump(YAML.load_file(base_file).merge(YAML.load_file(over_file)), f)
        f.close

        hold = File.readlines(new_config_file_name)[1..-1].join
        File.open(new_config_file_name,"w") {|fw| fw.write(hold) }
      end
    end

    class WebPortal < Sinatra::Application

      configure do
        enable :logging
        # mkdir log if it does not exist...
        Dir.mkdir('log') unless Dir.exist?('log')
        file = File.new("log/dm_#{settings.environment}.log", 'a+')
        file.sync = true
        use Rack::CommonLogger, file

        enable :sessions
        use Rack::Flash, :sweep => true

        set :environment, :production
        set :root, File.dirname(__FILE__)
        # :method_override - use for PATCH etc forms? http://www.rubydoc.info/github/rack/rack/Rack/MethodOverride
        set :app_file, __FILE__
        # :raise_errors - should be set so that Rack::ShowExceptions or the server can be used to handle the error...
        enable :show_exceptions # because we are forcing the environment to production...
        set :appname, 'tst'
        set :url_prefix, ENV['DM_PREFIX']  ? "#{ENV['DM_PREFIX']}/" : ''
        set :protection, except: :frame_options # so it can be loaded in another app's iframe...


        set :base_file, "#{FileUtils.pwd}/config/dm_defaults.yml"
        set :over_file, "#{FileUtils.pwd}/config/dm_#{ENV['DM_CLIENT'] || 'defaults'}.yml"
        set :new_config_file_name, "#{FileUtils.pwd}/config/dm_config_file.yml" # This could be a StringIO...
      end

      if settings.base_file == settings.over_file
        FileUtils.cp(settings.base_file, settings.new_config_file_name)
      else
        ConfigMerger.merge_config_files(settings.base_file, settings.over_file, settings.new_config_file_name)
      end
      config_file settings.new_config_file_name

      # TODO: Need to see how this should be done when running under passenger/thin/puma...
      DB = Sequel.postgres(settings.database['name'], :user => settings.database['user'], :password => settings.database['password'], :host => settings.database['host'] || 'localhost')


      def sql_to_highlight(sql)
        # wrap sql @ 120
        width = 120
        ar = sql.gsub(/from /i, "\nFROM ").gsub(/where /i, "\nWHERE ").gsub(/(left outer join |left join |inner join |join )/i, "\n\\1").split("\n")
        wrapped_sql = ar.map {|a| a.scan(/\S.{0,#{width-2}}\S(?=\s|$)|\S+/).join("\n") }.join("\n")

        theme = Rouge::Themes::Github.new
        formatter = Rouge::Formatters::HTMLInline.new(theme)
        lexer  = Rouge::Lexers::SQL.new
        formatter.format(lexer.lex(wrapped_sql))
      end

      def yml_to_highlight(yml)
        theme = Rouge::Themes::Github.new
        formatter = Rouge::Formatters::HTMLInline.new(theme)
        lexer  = Rouge::Lexers::YAML.new
        formatter.format(lexer.lex(yml))
      end

      # TODO: Change this to work from filenames.
      def lookup_report(id)
        DmReportLister.new(settings.dm_reports_location).get_report_by_id(id)
      end

      def clean_where(sql)
        rems = sql.scan( /\{(.+?)\}/).flatten.map {|s| "#{s}={#{s}}" }
        rems.each {|r| sql.gsub!(%r|and\s+#{r}|i,'') }
        rems.each {|r| sql.gsub!(r,'') }
        sql.sub!(/where\s*\(\s+\)/i, '')
        sql
      end

      # TODO: Move out of app...
      def setup_report_with_parameters(rpt, params)
        #{"col"=>"users.department_id", "op"=>"=", "opText"=>"is", "val"=>"17", "text"=>"Finance", "caption"=>"Department"}
        input_parameters = JSON.parse(params[:json_var])
        # logger.info input_parameters.inspect
        parms = []
        # Check if this should become an IN parmeter (list of equal checks for a column.
        eq_sel = input_parameters.select { |p| p['op'] == '=' }.group_by { |p| p['col'] }
        in_sets = {}
        in_keys = []
        eq_sel.each do |col, qp|
          in_keys << col if qp.length > 1
        end

        input_parameters.each do |in_param|
          col = in_param['col']
          if in_keys.include?(col)
            in_sets[col] ||= []
            in_sets[col] << in_param['val']
            next
          end
          param_def = @rpt.parameter_definition(col)
          if 'between' == in_param['op']
            parms << Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new(in_param['op'], [in_param['val'], in_param['val_to']], param_def.data_type))
          else
            parms << Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new(in_param['op'], in_param['val'], param_def.data_type))
          end
        end
        in_sets.each do |col, vals|
          param_def = @rpt.parameter_definition(col)
          parms << Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new('in', vals, param_def.data_type))
        end

        rpt.limit  = params[:limit].to_i  if params[:limit] != ''
        rpt.offset = params[:offset].to_i if params[:offset] != ''
        begin
          rpt.apply_params(parms)
        rescue StandardError => e
          return "ERROR: #{e.message}"
        end
      end


      # ERB helpers.
      helpers do
        # def h(text)
        #   Rack::Utils.escape_html(text)
        # end
        def make_options(ar)
          ar.map do |a|
            if a.kind_of?(Array)
              "<option value=\"#{a.last}\">#{a.first}</option>"
            else
              "<option value=\"#{a}\">#{a}</option>"
            end
          end.join("\n")
        end

        def the_url_prefix
          settings.url_prefix
        end

        def menu(options = {})
          admin_menu = options[:with_admin] ? " | <a href='/#{settings.url_prefix}admin'>Return to admin index</a>" : ''
          back_menu  = options[:return_to_report] ? " | <a href='#{options[:return_action]}'>Back</a>" : ''
          "<p><a href='/#{settings.url_prefix}index'>Return to report index</a>#{admin_menu}#{back_menu}</p>"
        end

        def h(text)
          Rack::Utils.escape_html(text)
        end

        def select_options(value, opts, with_blank = true)
          ar = []
          ar << "<option value=''></option>" if with_blank
          opts.each do |opt|
            if opt.kind_of? Array
              text, val = opt
            else
              val = opt
              text  = opt
            end
            is_sel = val.to_s == value.to_s
            ar << "<option value='#{val}'#{is_sel ? ' selected' : ''}>#{text}</option>"
          end
          ar.join("\n")
        end

        def make_query_param_json(query_params)
          common_ops = [
            ['is', "="],
            ['is not', "<>"],
            ['greater than', ">"],
            ['less than', "<"],
            ['greater than or equal to', ">="],
            ['less than or equal to', "<="],
            ['is blank', "is_null"],
            ['is NOT blank', "not_null"]
          ]
          text_ops = [
            ['starts with', "starts_with"],
            ['ends with', "ends_with"],
            ['contains', "contains"]
          ]
          date_ops = [
            ['between', "between"]
          ]
          # ar = []
          qp_hash = {}
          query_params.each do |query_param|
            hs = {column: query_param.column, caption: query_param.caption,
                  default_value: query_param.default_value, data_type: query_param.data_type,
                  control_type: query_param.control_type}
            if query_param.control_type == :list
              hs[:operator] = common_ops
              if query_param.includes_list_options?
                hs[:list_values] = query_param.build_list.list_values
              else
                hs[:list_values] = query_param.build_list {|sql| DB[sql].all.map {|r| r.values } }.list_values
              end
            elsif query_param.control_type == :daterange
              hs[:operator] = date_ops + common_ops
            else
              hs[:operator] = common_ops + text_ops
            end
            # ar << hs
            qp_hash[query_param.column] = hs
          end
          # ar.to_json
          qp_hash.to_json
        end
      end


      get '/' do
        # dataset = DB['select id from users']
        # "GOT THERE... running with #{settings.appname} <a href='#{settings.url_prefix}test_page'>Go to test page</a><p>Users: #{dataset.count} with ids: #{dataset.map(:id).join(', ')}.</p><p>Random user: #{DB['select user_name FROM users LIMIT 1'].first[:user_name]}</p>"
        erb "<a href='/#{settings.url_prefix}index'>DATAMINER REPORT INDEX</a> | <a href='/#{settings.url_prefix}admin'>Admin index</a>"
      end

      get '/index' do
        # TODO: sort report list, group, add tags etc...

        rpt_list = DmReportLister.new(settings.dm_reports_location).get_report_list(persist: true)

        erb(<<-EOS)
        <h1>Dataminer Reports</h1>
        <ol><li>#{rpt_list.map {|r| "<a href='/#{settings.url_prefix}report/#{r[:id]}'>#{r[:caption]}</a>" }.join('</li><li>')}</li></ol>
        <p><a href='/#{settings.url_prefix}admin'>Admin index</a></p>
        EOS
      end

      get '/report/:id' do
        @rpt = lookup_report(params[:id])
        @qps = @rpt.query_parameter_definitions

        @menu = menu
        @report_action = "/#{settings.url_prefix}run_rpt/#{params[:id]}"
        @excel_action = "/#{settings.url_prefix}run_xls_rpt/#{params[:id]}"

        erb :report_parameters
      end

      # Return a grid with the report.
      post '/run_xls_rpt/:id' do
        @rpt = lookup_report(params[:id])
        setup_report_with_parameters(@rpt, params)

        begin
          xls_possible_types = {string: :string, integer: :integer, date: :string, datetime: :time, time: :time, boolean: :boolean, number: :float}
          heads = []
          fields = []
          xls_types = []
          x_styles = []
          Axlsx::Package.new do | p |
            p.workbook do | wb |
              styles     = wb.styles
              tbl_header = styles.add_style :b => true, :font_name => 'arial', :alignment => {:horizontal => :center}
              # red_negative = styles.add_style :num_fmt => 8
              delim4 = styles.add_style(:format_code=>"#,##0.0000;[Red]-#,##0.0000")
              delim2 = styles.add_style(:format_code=>"#,##0.00;[Red]-#,##0.00")
              and_styles = {delimited_1000_4: delim4, delimited_1000: delim2}
              @rpt.ordered_columns.each do | col|
                xls_types << xls_possible_types[col.data_type] || :string # BOOLEAN == 0,1 ... need to change this to Y/N...or use format TRUE|FALSE...
                heads << col.caption
                fields << col.name
                # x_styles << (col.format == :delimited_1000_4 ? delim4 : :delimited_1000 ? delim2 : nil) # :num_fmt => Axlsx::NUM_FMT_YYYYMMDDHHMMSS / Axlsx::NUM_FMT_PERCENT
                x_styles << and_styles[col.format]
              end
              puts x_styles.inspect
              wb.add_worksheet do | sheet |
                sheet.add_row heads, :style => tbl_header
                DB[@rpt.runnable_sql].each do |row|
                  sheet.add_row(fields.map {|f| v = row[f.to_sym]; v.is_a?(BigDecimal) ? v.to_f : v }, :types => xls_types, :style => x_styles)
                end
              end
            end
            response.headers['content_type'] = "application/vnd.ms-excel"
            attachment(@rpt.caption.strip.gsub(/[\/:*?"\\<>\|\r\n]/i, '-') + '.xls')
            response.write(p.to_stream.read) # NOTE: could this streaming to start downloading quicker?
          end

        rescue Sequel::DatabaseError => e
          erb(<<-EOS)
          #{menu}<p style='color:red;'>There is a problem with the SQL definition of this report:</p>
          <p>Report: <em>#{@rpt.caption}</em></p>The error message is:
          <pre>#{e.message}</pre>
          <button class="pure-button" onclick="crossbeamsUtils.toggle_visibility('sql_code', this);return false">
            <i class="fa fa-info"></i> Toggle SQL
          </button>
          <pre id="sql_code" style="display:none;"><%= sql_to_highlight(@rpt.runnable_sql) %></pre>
          EOS
        end
      end

      post '/run_rpt/:id' do
        @rpt = lookup_report(params[:id])
        setup_report_with_parameters(@rpt, params)

        @col_defs = []
        @rpt.ordered_columns.each do | col|
          hs                  = {headerName: col.caption, field: col.name, hide: col.hide, headerTooltip: col.caption}
          hs[:width]          = col.width unless col.width.nil?
          hs[:enableValue]    = true if [:integer, :number].include?(col.data_type)
          hs[:enableRowGroup] = true unless hs[:enableValue] && !col.groupable
          hs[:enablePivot]    = true unless hs[:enableValue] && !col.groupable
          if [:integer, :number].include?(col.data_type)
            hs[:cellClass] = 'grid-number-column'
            hs[:width]     = 100 if col.width.nil? && col.data_type == :integer
            hs[:width]     = 120 if col.width.nil? && col.data_type == :number
          end
          if col.format == :delimited_1000
            hs[:cellRenderer] = 'crossbeamsGridFormatters.numberWithCommas2'
          end
          if col.format == :delimited_1000_4
            hs[:cellRenderer] = 'crossbeamsGridFormatters.numberWithCommas4'
          end
          if col.data_type == :boolean
            hs[:cellRenderer] = 'crossbeamsGridFormatters.booleanFormatter'
            hs[:cellClass]    = 'grid-boolean-column'
            hs[:width]        = 100 if col.width.nil?
          end

          # hs[:cellClassRules] = {"grid-row-red": "x === 'Fred'"} if col.name == 'author'

          @col_defs << hs
        end

        begin
          # Use module for BigDecimal change? - register_extension...?
          @row_defs = DB[@rpt.runnable_sql].to_a.map {|m| m.keys.each {|k| if m[k].is_a?(BigDecimal) then m[k] = m[k].to_f; end }; m; }

          @return_action = "/#{settings.url_prefix}report/#{params[:id]}"
          erb :report_display

        rescue Sequel::DatabaseError => e
          erb(<<-EOS)
          #{menu}<p style='color:red;'>There is a problem with the SQL definition of this report:</p>
          <p>Report: <em>#{@rpt.caption}</em></p>The error message is:
          <pre>#{e.message}</pre>
          <button class="pure-button" onclick="crossbeamsUtils.toggle_visibility('sql_code', this);return false">
            <i class="fa fa-info"></i> Toggle SQL
          </button>
          <pre id="sql_code" style="display:none;"><%= sql_to_highlight(@rpt.runnable_sql) %></pre>
          EOS
        end
      end

      get '/admin' do
        # Need some kind of login verification.
        # List reports for editing.
        # Button to import old-style report.
        # Button to create new report.
        # "NOT YET WRITTEN..."
        @rpt_list = DmReportLister.new(settings.dm_reports_location).get_report_list(from_cache: true)
        @menu     = menu
        erb :admin_index
      end

      post '/admin/convert' do
        unless params[:file] &&
               (@tmpfile = params[:file][:tempfile]) &&
               (@name = params[:file][:filename])
          return "No file selected"
        end
        @yml  = @tmpfile.read
        @hash = YAML.load(@yml)
        @menu =  menu(with_admin: true)
        erb :admin_convert
      end

      post '/admin/save_conversion' do
        yml = nil
        File.open(params[:temp_path], 'r') {|f| yml = f.read }
        hash = YAML.load(yml)
        hash['query'] = params[:sql]
        rpt = DmConverter.new(settings.dm_reports_location).convert_hash(hash, params[:filename])
        # yp = Crossbeams::Dataminer::YamlPersistor.new('report1.yml')
        # rpt.save(yp)
        erb(<<-EOS)
        <h1>Converted</h1>#{menu(with_admin: true)}
        <p>New YAML code:</p>
        <pre>#{yml_to_highlight(rpt.to_hash.to_yaml)}</pre>
        EOS
      end

      get '/admin/new' do
        @filename=''
        @caption=''
        @sql=''
        @err=''
        erb :admin_new
      end

      post '/admin/create' do
        #@filename = params[:filename].trim.downcase.gsub(' ', '_').gsub(/_+/, '_')
        # Ensure the filename:
        # * is lowercase
        # * has spaces converted to underscores
        # * more than one underscore in a row becomes one
        # * the name ends in ".yml"
        s = params[:filename].strip.downcase.gsub(' ', '_').gsub(/_+/, '_').gsub(/[\/:*?"\\<>\|\r\n]/i, '-')
        @filename = File.basename(s).reverse.sub(File.extname(s).reverse, '').reverse << '.yml'
        @caption  = params[:caption]
        @sql      = params[:sql]
        @err      = ''

        @rpt = Crossbeams::Dataminer::Report.new(@caption)
        begin
          @rpt.sql = @sql
        rescue StandardError => e
          @err = e.message
        end
        # Check for existing file name...
        if File.exists?(File.join(settings.dm_reports_location, @filename))
          @err = 'A file with this name already exists'
        end
        # Write file, rebuild index and go to edit...

        if @err.empty?
          # run the report with limit 1 and set up datatypes etc.
          DmCreator.new(DB, @rpt).modify_column_datatypes
          yp = Crossbeams::Dataminer::YamlPersistor.new(File.join(settings.dm_reports_location, @filename))
          @rpt.save(yp)
          DmReportLister.new(settings.dm_reports_location).get_report_list(persist: true) # Kludge to ensure list is rebuilt... (stuffs up anyone else running reports if id changes....)

          erb(<<-EOS)
          <h1>Saved file...got to admin index and edit...</h1>#{menu(with_admin: true)}
          <p>Filename: <em><%= @filename %></em></p>
          <p>Caption: <em><%= @rpt.caption %></em></p>
          <p>SQL: <em><%= @rpt.runnable_sql %></em></p>
          <p>Columns:<br><% @rpt.columns.each do | column| %>
            <p><%= column %></p>
          <% end %>
          </p>
          EOS
        else
          erb :admin_new
        end
      end

      get '/admin/edit/:id' do
        @rpt = lookup_report(params[:id])
        @filename = File.basename(DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(params[:id]))

        @col_defs = [{headerName: 'Column Name', field: 'name'},
                     {headerName: 'Sequence', field: 'sequence_no', cellClass: 'grid-number-column'}, # to be changed in group...
                     {headerName: 'Caption', field: 'caption', editable: true},
                     {headerName: 'Namespaced Name', field: 'namespaced_name'},
                     {headerName: 'Data type', field: 'data_type', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: ['string', 'integer', 'number', 'date', 'datetime']
                     }},
                     {headerName: 'Width', field: 'width', cellClass: 'grid-number-column', editable: true, cellEditor: 'NumericCellEditor'}, # editable NUM ONLY...
                     {headerName: 'Format', field: 'format', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: ['', 'delimited_1000', 'delimited_1000_4']
                     }},
                     {headerName: 'Hide?', field: 'hide', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }},
                     {headerName: 'Can group by?', field: 'groupable', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }},
                     {headerName: 'Group Seq', field: 'group_by_seq', cellClass: 'grid-number-column', headerTooltip: 'If the grid opens grouped, this is the grouping level', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }},
                     {headerName: 'Sum?', field: 'group_sum', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }},
                     {headerName: 'Avg?', field: 'group_avg', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }},
                     {headerName: 'Min?', field: 'group_min', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }},
                     {headerName: 'Max?', field: 'group_max', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                       values: [true, false]
                     }}
        ]
        @row_defs = @rpt.ordered_columns.map {|c| c.to_hash }

        @col_defs_params = [
          {headerName: '', width: 60, suppressMenu: true, suppressSorting: true, suppressMovable: true, suppressFilter: true,
           enableRowGroup: false, enablePivot: false, enableValue: false, suppressCsvExport: true,
           valueGetter: "'/#{settings.url_prefix}admin/delete_param/#{params[:id]}/' + data.column + '|delete|Are you sure?|delete'", colId: 'delete_link', cellRenderer: 'crossbeamsGridFormatters.hrefPromptFormatter'},

          {headerName: 'Column', field: 'column'},
          {headerName: 'Caption', field: 'caption'},
          {headerName: 'Data type', field: 'data_type'},
          {headerName: 'Control type', field: 'control_type'},
          {headerName: 'List definition', field: 'list_def'},
          {headerName: 'UI priority', field: 'ui_priority'},
          {headerName: 'Default value', field: 'default_value'}#,
          #{headerName: 'List values', field: 'list_values'}
        ]

        @row_defs_params = []
        @rpt.query_parameter_definitions.each do |query_def|
          @row_defs_params << query_def.to_hash
        end
        @save_url = "/#{settings.url_prefix}save_param_grid_col/#{params[:id]}"
        erb :admin_edit
      end

      #TODO:
      #      - Make JS scoped by crossbeams.
      #      - split editors into another JS file
      #      - ditto formatters etc...
      post '/save_param_grid_col/:id' do
        content_type :json

        @rpt = lookup_report(params[:id])
        col = @rpt.columns[params[:key_val]]
        attrib = params[:col_name]
        value  = params[:col_val]
        value  = nil if value.strip == ''
        # Should validate - width numeric, range... caption cannot be blank...
        # group_sum, avg etc should act as radio grps... --> Create service class to do validation.
        # FIXME: width cannot be 0...
        if ['format', 'data_type'].include?(attrib) && !value.nil?
          col.send("#{attrib}=", value.to_sym)
        else
          value = value.to_i if attrib == 'width' && !value.nil?
          col.send("#{attrib}=", value)
        end
        puts ">>> ATTR: #{attrib} - #{value} #{value.class}"
        if attrib == 'group_sum' && value == 'true' # NOTE string value of bool...
          puts 'CHANGING...'
          col.group_avg = false
          col.group_min = false
          col.group_max = false
          send_changes = true
        else
          send_changes = false
        end

        if value.nil? && attrib == 'caption' # Cannot be nil...
          {status: 'error', message: "Caption for #{params[:key_val]} cannot be blank"}.to_json
        else
          filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(params[:id])
          yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
          @rpt.save(yp)
          if send_changes
            {status: 'ok', message: "Changed #{attrib} for #{params[:key_val]}",
             changedFields: {group_avg: false, group_min: false, group_max: false, group_none: 'A TEST'} }.to_json
          else
            {status: 'ok', message: "Changed #{attrib} for #{params[:key_val]}"}.to_json
          end
        end
      end

      get '/admin/new_parameter/:id' do
        @rpt = lookup_report(params[:id])
        @cols = @rpt.ordered_columns.map { |c| c.namespaced_name }.compact
        @tables = @rpt.tables
        erb :admin_new_parameter
      end

      post '/admin/create_parameter_def/:id' do
        # Validate... also cannot ad dif col exists as param already
        @rpt = lookup_report(params[:id])

        col_name = params[:column]
        if col_name.nil? || col_name.empty?
          col_name = "#{params[:table]}.#{params[:field]}"
        end
        opts = {:control_type => params[:control_type].to_sym,
                :data_type => params[:data_type].to_sym, caption: params[:caption]}
        unless params[:list_def].nil? || params[:list_def].empty?
          if params[:list_def].start_with?('[') # Array
            opts[:list_def] = eval(params[:list_def]) # TODO: unpack the string into an array... (Job for the gem?)
          else
            opts[:list_def] = params[:list_def]
          end
        end

        param = Crossbeams::Dataminer::QueryParameterDefinition.new(col_name, opts)
        @rpt.add_parameter_definition(param)

        filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(params[:id])
        yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
        @rpt.save(yp)

        flash[:notice] = "Parameter has been added."
        redirect to("/#{settings.url_prefix}admin/edit/#{params[:id]}")
      end

      delete '/admin/delete_param/:rpt_id/:id' do
        @rpt = lookup_report(params[:rpt_id])
        id   = params[:id]
        # puts ">>> #{id}"
        # puts @rpt.query_parameter_definitions.length
        # puts @rpt.query_parameter_definitions.map { |p| p.column }.sort.join('; ')
        @rpt.query_parameter_definitions.delete_if { |p| p.column == id }
        # puts @rpt.query_parameter_definitions.length
        filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(params[:rpt_id])
        # puts filename
        yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
        @rpt.save(yp)
        #puts @rpt.query_parameter_definitions.map { |p| p.column }.sort.join('; ')
        #params.inspect
        flash[:notice] = "Parameter has been deleted."
        redirect to("/#{settings.url_prefix}admin/edit/#{params[:rpt_id]}")
      end

      post '/admin/save_rpt_header/:id' do
        # if new name <> old name, make sure new name has .yml, no spaces and lowercase....
        @rpt = lookup_report(params[:id])

        filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(params[:id])
        if File.basename(filename) != params[:filename]
          puts "new name: #{params[:filename]} for #{File.basename(filename)}"
        else
          puts "No change to file name"
        end
        @rpt.caption = params[:caption]
        @rpt.limit = params[:limit].empty? ? nil : params[:limit].to_i
        @rpt.offset = params[:offset].empty? ? nil : params[:offset].to_i
        yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
        @rpt.save(yp)

        # Need a flash here...
        flash[:notice] = "Report's header has been changed."
        redirect to("/#{settings.url_prefix}admin/edit/#{params[:id]}")
      end

      get '/test_page' do
        gots = %w{methodoverride inline_templates}
        meths = (Crossbeams::DataminerPortal::WebPortal.methods(false) + Sinatra::Base.methods(false)).
                  sort.map(&:to_s).select {|e| e[/=$/] }.map {|e| e[0..-2] } - gots
        # meths.map {|meth| [meth, (Crossbeams::DataminerPortal::WebPortal.send(meth) rescue $!.inspect)] }
        @res = meths.uniq.map {|m| [m, (Crossbeams::DataminerPortal::WebPortal.send(m) rescue $!.inspect)] }
        erb :test
      end
    end

  end

end
# Could we have two dm's connected to different databases?
# ...and store each set of yml files in different dirs.
# --- how to use the same gem twice on diferent routes?????
#
