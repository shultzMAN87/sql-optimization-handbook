/* =====================================================================
   Extended Events: долгие запросы 1С вместо Profiler
   Вопросы 61–63, 69 методички. Подставьте имя базы и путь.
   ===================================================================== */
CREATE EVENT SESSION [LongQueries] ON SERVER
ADD EVENT sqlserver.rpc_completed (            -- sp_executesql от 1С
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.client_app_name,
            sqlserver.client_hostname, sqlserver.session_id)
    WHERE sqlserver.database_name = N'MyBase1C' AND duration >= 1000000),   -- 1 с, микросекунды
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.client_app_name,
            sqlserver.client_hostname, sqlserver.session_id)
    WHERE sqlserver.database_name = N'MyBase1C' AND duration >= 1000000)
ADD TARGET package0.event_file (SET filename = N'D:\XE\LongQueries.xel',
                                    max_file_size = 256, max_rollover_files = 10)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);
GO
ALTER EVENT SESSION [LongQueries] ON SERVER STATE = START;
GO

-- Чтение результата (или просто открыть .xel в SSMS двойным щелчком)
SELECT
    x.value('(event/@name)[1]', 'nvarchar(50)')                               AS event_name,
    x.value('(event/@timestamp)[1]', 'datetime2')                             AS event_time_utc,
    x.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000       AS duration_ms,
    x.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') / 1000       AS cpu_ms,
    x.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint')         AS logical_reads,
    x.value('(event/data[@name="writes"]/value)[1]', 'bigint')                AS writes,
    x.value('(event/action[@name="session_id"]/value)[1]', 'int')             AS spid,   -- = dbpid из ТЖ 1С
    x.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)')     AS sql_text
FROM (SELECT CAST(event_data AS xml) AS x
      FROM sys.fn_xe_file_target_read_file(N'D:\XE\LongQueries*.xel', NULL, NULL, NULL)) t
ORDER BY logical_reads DESC;
GO

/* Фактический план — отдельной КОРОТКОЙ сессией с жёстким фильтром (дорогое событие!):
ADD EVENT sqlserver.query_post_execution_showplan (
    ACTION (sqlserver.sql_text)
    WHERE sqlserver.session_id = 87 AND duration >= 1000000)            */

-- ALTER EVENT SESSION [LongQueries] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [LongQueries] ON SERVER;
