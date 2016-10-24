# etl-utils 

##query wrapper

The query wrapper is a lightweight object-oriented Lua script used as a library to build procedural etl jobs on top of it in Lua.
Basically it consists of uniform handling of query parameters,error handling and logging into log tables (JOB_LOG and JOB_DETAILS) and iterating over result sets.

The basic initial example shows how to initialize the query wrapper,
iterate over a result set, setting parameters, executing queries and finishing the query wrapper in the end.
```
CREATE OR REPLACE LUA SCRIPT ETL.EXAMPLE_SCRIPT RETURNS TABLE AS

import('ETL.QUERY_WRAPPER','QW')

wrapper = QW.new( 'ETL.JOB_LOG', 'ETL.JOB_DETAILS', 'EXAMPLE_SCRIPT')

for table_schema, table_name in wrapper:query_values( 'select table_schema, table_name from exa_all_tables' ) do
		wrapper:set_param('SCHEM',quote(table_schema))	
		wrapper:set_param('TAB',quote(table_name))	
		wrapper:query([[select count(*) from ::SCHEM.::TAB ]])			
end

return wrapper:finish()

/

EXECUTE SCRIPT ETL.EXAMPLE_SCRIPT();
```


###### Please note that this is an open source project which is *not officially supported* by EXASOL. We will try to help you as much as possible, but can't guarantee anything since this is not an official EXASOL product.
