# etl-utils 

##query wrapper

The query wrapper is a lightweight object-oriented Lua script used as a library to build procedural etl jobs on top of it in Lua.
Basically it consists of uniform error handling, basic logging into log tables (JOB_LOG and JOB_DETAILS) and iterating
over result sets.

Basic initial example shows how to initialize the query wrapper,
execute a query and finish the query wrapper in the end
```
CREATE OR REPLACE LUA SCRIPT ETL.EXAMPLE_SCRIPT RETURNS TABLE AS

import('ETL.QUERY_WRAPPER','QW')

wrapper = QW.new( 'ETL.JOB_LOG', 'ETL.JOB_DETAILS', 'EXAMPLE_SCRIPT')

wrapper:query([[select * from exa_all_tables ]])

return wrapper:finish()

/

EXECUTE SCRIPT ETL.EXAMPLE_SCRIPT();
```
