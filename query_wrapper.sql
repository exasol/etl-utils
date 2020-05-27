CREATE SCHEMA IF NOT EXISTS ETL;

/** Example DDL for logging tables **/
CREATE TABLE IF NOT EXISTS etl.job_log(
    run_id       INT IDENTITY NOT NULL PRIMARY KEY
  , script_name  VARCHAR(100) NOT NULL
  , status       VARCHAR(100)
  , start_time   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  , end_time     TIMESTAMP
);

CREATE TABLE IF NOT EXISTS etl.job_details (
    detail_id    INT IDENTITY NOT NULL
  , run_id       INT NOT NULL REFERENCES etl.job_log ( run_id )
  , log_time     TIMESTAMP
  , log_level    VARCHAR(10)
  , log_message  VARCHAR(2000000)
  , rowcount     DECIMAL(18)
);

--/
CREATE OR REPLACE LUA SCRIPT etl.query_wrapper () RETURNS ROWCOUNT AS

    local function is_null( X )
        -- Result values returned by EXASolution 4.1 and above, as well as non-existing columns/variables (EXASOL-1064) within result sets
        if X == null then return true end
        -- Result values returned by pre-4.1 and non-existing columns/variables pre-4.1 and post-4.2
        if X == nil then return true end
        return false
    end

    local function trim(str, chs)
        if not str then return nil end
        chs = chs or "%s"
        return string.match(str, "[^" .. chs .. "]+.+[^" .. chs .. "]+")
    end

    function wrap_query( self, sql_text, options )
        options = options or {logging=true}
        local success,info = pquery( sql_text, options.params or self.query_params )
        if not success then
            self:log( 'INFO', info.statement_text )
            self:log( 'ERROR', info.error_message )
            if self.on_error == 'abort' or self.on_error == 'rollback' then
                self:finish({rollback=(self.on_error=='rollback')})
                -- The second parameter is the error level, 2 is the calling function, 1 would be the query_wrapper itself
                error( info.error_message .. '\n Statement was: ' .. info.statement_text .. '\n', 2 )
            end
            return success, info
        else
            local rows = #info
            if not is_null( info.rows_affected ) then
                rows = info.rows_affected
            else
                if rows == 1 and #info[1] == 1 and string.find( info.statement_text, 'count' ) then
                    -- simple count(...) statement?
                    rows = info[1][1]
                end
            end

            if self.verbosity >= 3 and options.logging then
                self:log( 'DEBUG', info.statement_text, rows )
            elseif self.verbosity == 2 and options.logging then
                self:log( 'INFO', info.statement_text, rows )
            end
        end
        return success, info
    end

    function wrap_log( self, message_type, message_text, rowcount )
        message_text = trim(message_text) or ''
        
        if string.len( message_type ) > 10 then
            message_type = string.sub( message_type, 1, 7 ) .. '...'
        end

        if string.len( message_text ) > 20000 then
            message_text = string.sub( message_text, 1, 19995 ) .. '...'
        end

        self.messages[1+#self.messages] = { self.run_id, os.date( '%Y-%m-%d %H:%M:%S' ), message_type, message_text, rowcount }
        if message_type == 'ERROR' then
            self.errors = self.errors + 1
        end
    end

    local
    function write_log_details( self )
        if self.message_log_offset == nil then
            self.message_log_offset = 1
        end

        -- Finally insert all messages in log_table
        if self.message_log_offset <= #self.messages then
            self:set_param( 'TMP_LOG_TABLE', self.log_table )
            local prep = self:prepare( [[
                INSERT INTO ::TMP_LOG_TABLE( RUN_ID, LOG_TIME, LOG_LEVEL, LOG_MESSAGE, ROWCOUNT )
                VALUES ( ?, TO_TIMESTAMP( ?, 'YYYY-MM-DD HH24:MI:SS' ), ?, ?, ? )
                ]]
            )

            -- Limit number of executed statements to avoid "out of resultsets" error
            local vector_size = 100
            local i_max = #self.messages

            while self.message_log_offset <= i_max do
                local i_end = self.message_log_offset + vector_size

                if i_end > i_max then
                    i_end = i_max
                end

                local success, res = prep:execute( self.messages, self.message_log_offset, i_end, {logging=false} )

                -- #res is the number of attempted executions, it will include the failed one. Thus, we skip that next time
                self.message_log_offset = self.message_log_offset + #res
                if not success then
                    self.log( 'WARNING', 'Failed to write detail log: ['..res[#res].error_code..'] '..res[#res].error_message )
                    -- Optionally: abort here, but we will just try to get all messages written.
                end
                res = nil
            end
            prep = nil
        end
    end

    local
    function wrap_transaction( obj, sql, options )
        local success, info = obj:query( sql, options )
        if success and obj.log_table ~= nil then
            write_log_details( obj )
            -- Do not call wrap_commit to avoid recursion!
            obj:query( 'commit -- wrapper-log', {logging=false} )
        end
        return success, info
    end

    function wrap_commit( self, options )
        return wrap_transaction( self, 'commit -- wrapper', options )
    end

    function wrap_rollback( self, options )
        return wrap_transaction( self, 'rollback -- wrapper', options )
    end

    function wrap_finish( self, options )
        options = options or {}
        
        -- Commit / rollback will also write log details.
        if options.rollback then
          success, res = self:rollback()
        else
          success, res = self:commit()
        end
        
        if not success  then
            error( '[querywrapper] finish() while commiting / rollbacking [' .. res.error_code .. '] ' .. res.error_message )
        end
        
        -- Persist messages?
        if ( self.run_id ~= nil ) then
            -- Close entry in MAIN_LOG for corresponding RUN_ID
            main_state = 'FINISHED SUCCESSFULLY'
            if self.errors > 0 then
                main_state = 'FINISHED WITH ERROR'
            end

            local success, res = self:query( [[
                UPDATE ::MAIN_LOG_TABLE 
                SET    end_time = CURRENT_TIMESTAMP
                     , status   = :MAIN_STATE
                WHERE  run_id = :ID
                ]],
                {logging=false, params={ MAIN_LOG_TABLE = self.main_log_table, ID = self.run_id, MAIN_STATE = main_state }}
            )
            if not success then
                error( '[querywrapper] during finish [' .. res.error_code .. '] ' .. res.error_message )
            end
            
            success, res = self:commit({logging=false})
            if not success  then
                error( '[querywrapper] finish() while commiting [' .. res.error_code .. '] ' .. res.error_message )
            end
        end -- if


        if not is_null( self.starting_schema ) then
            -- rollback any schema movements
            self:query( 'OPEN SCHEMA ' .. self.starting_schema, {logging=false} )
        end

        return self.messages, self.messages_types -- Return messages
    end -- wrap_finish

    function wrap_setParam( self, name, value )
        self.query_params[name] = value
    end

    function wrap_getParam( self, name )
        return self.query_params[name]
    end

    function wrap_loadParams( self, paramDict )
        if paramDict ~= nil then
            for name, value in pairs( paramDict ) do
                self:set_param( name, value )
            end
        end
    end

    function wrap_loadParamsFromTable( self, table_name )
        self:set_param( 'PARAMETERS_TABLE', table_name )
        suc, res = self:query( [[SELECT * FROM ::PARAMETERS_TABLE]] )

        local str = "{ "
        for i = 1,#res do
            self:set_param( res[i][1], res[i][2] )
            if #str > 2 then str = str..', ' end
            str = str..'"'..res[i][1]..'" = "'..res[i][2]..'"'
        end
        str = str.." }"
        -- write state of parameter table in log
        self:log("INFO", "Loaded Parameters from Table "..table_name..": "..str)
    end

    function wrap_run( self, package, function_name, ... )
        if package[function_name] ~= nil then
            self:log( 'START', 'Entering function ' .. function_name )
            local success, info = pcall( package[function_name], self, ... )
            if not success then
                self:log( 'ERROR', function_name .. ' returned with error: ' .. info )
                if self.on_error == 'abort' then
                    error( info )
                end
            else
                self:log( 'INFO', 'Finished function ' .. function_name )
            end
            return success, info
        else
            self:log( 'ERROR', 'Undefined function ' .. function_name )
            error( 'Undefined function ' .. function_name )
        end
    end

    -- This function returns a unique id for the current execution context
    function get_unique_run_id( self, main_log_table, log_table, script_name )
        if  is_null( main_log_table ) then
            return nil
        end

        self.main_log_table = main_log_table
        self.log_table = log_table

        -- Step 1) insert a new row -> generates RUN_ID
        local success, res = pquery( [[
            INSERT INTO ::MAIN_LOG_TABLE ( status, script_name )
            VALUES ( 'RUNNING', :SN )
            ]],
            { MAIN_LOG_TABLE = main_log_table, SN = script_name }
        )

        if not success then
            self:log( 'WARNING', 'Failed to register job for persistent logging: [' .. res.error_code .. '] ' .. res.error_message )
            return nil
        end

        -- Step 2) retrieve max ELT_RUN_ID
        local success, res = pquery( [[SELECT MAX( run_id ) FROM ::MAIN_LOG_TABLE]], {MAIN_LOG_TABLE = main_log_table} )
        if not success then
            self:log( 'WARNING', 'Failed to retrieve job id: [' .. res.error_code .. '] ' .. res.error_message )
            pquery( [[ROLLBACK]] )
            return nil
        end
        self.run_id = res[1][1]
        self:log( 'INFO', 'Job nr. ' .. self.run_id .. ' registered' )

        -- Step 3) COMMIT to avoid transaction conflicts
        success, res = self:commit({logging=false})
        if not success then
            self.run_id = nil
            error( '[querywrapper] get_unique_run_id() while commiting [' .. res.error_code .. '] ' .. res.error_message )
        end
    end

    -- Prepared_Statement::execute
    -- Returns array of query results {success, info} -- watch out for max. number of open result sets!
    function wrap_ps_execute( self, values, start_index, end_index, options )
        local res = {}
        for row=( start_index or 1 ),  (end_index or #values ) do
            for p=1,self.ps_param_count do
                self.ps_wrapper:set_param( 'PS_VAL_' .. p, ( values[row][p] or null ) )
            end
            local a, b = self.ps_wrapper:query( self.ps_sql_text, options )
            res[1+#res] = b
            if not a then
                -- early abort
                return false, res
            end
        end
        return true, res
    end

    -- Prepared_Statement::new == Wrappper::prepare
    -- Returns class: Prepared_Statement
    function wrap_prepare( self, sql_text )
        local query_tokens = sqlparsing.tokenize( sql_text )
        local param_count = 0
        local startPos = 1

        while startPos < #query_tokens do
            local paramFound = sqlparsing.find( query_tokens, startPos, true, false, sqlparsing.iswhitespaceorcomment, '?' )

            if paramFound ~= nil then
                startPos = paramFound[1]
                param_count = param_count + 1
                query_tokens[startPos] = ':PS_VAL_' .. param_count
            else
                break
            end
        end

        if param_count > 0 then
            sql_text = table.concat( query_tokens, '' )
        end

        return {
            -- Member variables
            ps_wrapper = self,
            ps_sql_text = sql_text,
            ps_param_count = param_count,

            -- Class functions
            execute = wrap_ps_execute
        }
    end

    --[[ Iterator functionality for result sets ]]--

    --[[
        Checks if the argument is a string or a resultset. In the first case, it will execute the given query.
        @returns: given query result or result of executed sql text
    --]]
    local function query_or_result( self, sql_or_result )
        if type( sql_or_result ) == 'string' then
            return self:query( sql_or_result )
        end
        if type( sql_or_result.statement_text ) == 'string' then
            return true, sql_or_result
        end
    end

    --[[
        Takes a result set or sql text and returns an iterator for the ROWS of the result.
        Result fields can be adressed by name or by index (startig at column 1)

        Example:
            -----
            for data in wrapper:query_rows( 'SELECT * FROM CAT' ) do
                output( data.TABLE_NAME .. data[2] )
            end
            -----
    --]]
    function wrap_row_iterator( self, sql_text )
        local status, resultset = query_or_result( self, sql_text )
        local cursor_pos = 0

        return function()
            if cursor_pos < #resultset then
                cursor_pos = cursor_pos + 1
                return resultset[cursor_pos]
            end
        end
    end

    --[[
        Takes a result set or sql text and returns an iterator for the expanded rows of the result.
        Result fields are returned in order

        Example:
            -----
            for table_name, table_type in wrapper:query_values( 'SELECT * FROM CAT' ) do
                output( table_name .. table_type )
            end
            -----
    --]]
    function wrap_values_iterator( self, sql_text )
        local status, resultset = query_or_result( self, sql_text )
        local cursor_pos = 0
        local width = 0
        if #resultset > 0 then
            width = #resultset[1]
        end

        local function array_split( data, offset )
            if offset < width then
                return data[offset], array_split( data, offset+1 )
            else
                return data[offset]
            end
        end

        return function()
            if cursor_pos < #resultset then
                cursor_pos = cursor_pos + 1
                return array_split( resultset[cursor_pos], 1 )
            end
        end
    end

    function new( main_log_table, log_table, script_name)
        local tmp_obj = {
            -- member variables
            messages = {},
            messages_types = "run_id INT, msg_time VARCHAR2(20), msg_type VARCHAR(10), message VARCHAR(20000), rowcount DECIMAL(18)",
            query_params = {},
            verbosity = 2,
            on_error = 'abort', -- abort (no rollback) | rollback | continue
            errors = 0,

            -- helper function
            is_null = is_null,

            -- logging functionality
            log = wrap_log,
            register = get_unique_run_id,
            finish = wrap_finish,

            -- query parameter handling
            set_param = wrap_setParam,
            get_param = wrap_getParam,
            load_params = wrap_loadParams,
            load_params_from_table = wrap_loadParamsFromTable,

            -- statement stuff
            query = wrap_query,
            query_rows = wrap_row_iterator,
            query_values = wrap_values_iterator,
            prepare = wrap_prepare,

            -- transactional
            commit = wrap_commit,
            rollback = wrap_rollback,

            -- procedural
            run = wrap_run
        }

        if main_log_table ~= nil then
            tmp_obj:register( main_log_table, log_table, script_name )
        end
        -- determine current schema
        local success, info = tmp_obj:query( 'SELECT CURRENT_SCHEMA', {logging=false} )
        if success then
            tmp_obj.starting_schema = info[1][1]
        end

        return tmp_obj
    end
/
