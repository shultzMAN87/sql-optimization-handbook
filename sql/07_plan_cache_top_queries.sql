/* =====================================================================
   Кэш планов: что в нём лежит и какие запросы самые тяжёлые
   Вопросы 13–17, 59 методички.
   ===================================================================== */

/* ---------- 1. Состав кэша: сколько одноразовых ad hoc планов ---------- */
SELECT objtype,                                           -- Adhoc / Prepared / Proc
       COUNT(*)                                            AS plans,
       SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)      AS single_use,
       SUM(CAST(size_in_bytes AS bigint)) / 1024 / 1024    AS size_mb
FROM sys.dm_exec_cached_plans
GROUP BY objtype
ORDER BY size_mb DESC;
GO

/* ---------- 2. Топ-20 инструкций по суммарным логическим чтениям ---------- */
SELECT TOP (20)
    qs.execution_count,
    qs.total_logical_reads,
    qs.total_logical_reads / qs.execution_count            AS avg_logical_reads,
    qs.total_worker_time  / qs.execution_count / 1000.0    AS avg_cpu_ms,
    qs.total_elapsed_time / qs.execution_count / 1000.0    AS avg_duration_ms,
    qs.min_logical_reads, qs.max_logical_reads,            -- большой разброс -> подозрение на sniffing
    SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
        (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
              ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2 + 1) AS statement_text,
    qp.query_plan,                                          -- ПРЕДПОЛАГАЕМЫЙ план из кэша
    qs.creation_time, qs.last_execution_time
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)     AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle)  AS qp
ORDER BY qs.total_logical_reads DESC;       -- или total_worker_time / total_elapsed_time
GO

/* ---------- 3. Непараметризованные запросы: одинаковый query_hash, разные тексты ---------- */
SELECT TOP (20)
    qs.query_hash,
    COUNT(DISTINCT qs.sql_handle)                          AS different_texts,
    SUM(qs.execution_count)                                AS executions,
    SUM(qs.total_worker_time) / 1000                       AS total_cpu_ms,
    MIN(SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, 200)) AS sample_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
GROUP BY qs.query_hash
HAVING COUNT(DISTINCT qs.sql_handle) > 5
ORDER BY different_texts DESC;
GO

/* ---------- 4. Ключ кэша конкретного плана (set_options, dbid, user_id...) ---------- */
-- DECLARE @ph varbinary(64) = 0x...;   -- plan_handle из запроса 2
-- SELECT attribute, value FROM sys.dm_exec_plan_attributes(@ph) WHERE is_cache_key = 1;

/* ---------- 5. Точечно выбросить один план (НЕ весь кэш!) ---------- */
-- DBCC FREEPROCCACHE (0x0600...);                                  -- plan_handle
-- ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;       -- только текущая база (2016+)
-- EXEC sp_recompile N'dbo.MyProc';                                 -- перекомпилировать при след. вызове

/* ---------- 6. Счётчики фаз оптимизатора по серверу ---------- */
SELECT counter, occurrence, value
FROM sys.dm_exec_query_optimizer_info
WHERE counter IN (N'optimizations', N'trivial plan', N'search 0', N'search 1',
                  N'search 2', N'timeout', N'memory limit exceeded');
GO
