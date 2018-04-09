# etl-utils 

## query wrapper

The query wrapper is a lightweight object-oriented Lua script used as a library to build procedural etl jobs on top of it in Lua.
Basically it consists of uniform handling of query parameters,error handling and logging into log tables (JOB_LOG and JOB_DETAILS) and iterating over result sets.

The basic initial example shows how to initialize the query wrapper,
iterate over a result set, setting parameters, executing queries, writing custom log messages and finishing the query wrapper in the end.
```lua
CREATE OR REPLACE LUA SCRIPT ETL.EXAMPLE_SCRIPT RETURNS TABLE AS

import('ETL.QUERY_WRAPPER','QW')

wrapper = QW.new( 'ETL.JOB_LOG', 'ETL.JOB_DETAILS', 'TEST_SCRIPT')

for table_schema, table_name in wrapper:query_values( [[select table_schema, table_name from exa_all_tables ]] ) do
		wrapper:set_param('SCHEM',quote(table_schema))	
		wrapper:set_param('TAB',quote(table_name))

		wrapper:query([[select count(*) from ::SCHEM.::TAB ]])
		
		-- just as example, query whether table contains a date value
		wrapper:set_param('SCHEM_unquoted',table_schema)	
		wrapper:set_param('TAB_unquoted',table_name)	

		suc, res = wrapper:query([[select count(*) from exa_all_columns where column_schema = :SCHEM_unquoted
			and column_table = :TAB_unquoted and column_type = 'DATE';]])
		-- if table contains date value, create a custom log message
		if res[1][1] > 0 then
			wrapper:log('MY_LOG', table_schema..'.'..table_name.. ' contains '..res[1][1] .. ' date-columns')
		end

end

return wrapper:finish()

/

EXECUTE SCRIPT ETL.EXAMPLE_SCRIPT();
```

The query wrapper from the example generates two tables:

- JOB_LOG:

<p align="center">
  <img src="job_log.png">
</p>

- JOB_DETAILS:
<p align="center">
  <img src="job_details.png">
</p>

###### Please note that this is an open source project which is *not officially supported* by EXASOL. We will try to help you as much as possible, but can't guarantee anything since this is not an official EXASOL product.
