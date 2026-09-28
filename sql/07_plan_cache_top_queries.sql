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

/* ---------- 7. Хранилища кэша и эксперимент «разный литерал — один query_hash» ---------- */
SELECT type, name, pages_kb, entries_count
FROM sys.dm_os_memory_cache_counters
WHERE type IN (N'CACHESTORE_SQLCP', N'CACHESTORE_OBJCP', N'CACHESTORE_PHDR');
GO
-- Подставьте свою таблицу. Запросы отличаются только литералом.
-- SELECT * FROM dbo.Orders WHERE CustomerID = 1 AND Amount > 100;
-- GO
-- SELECT * FROM dbo.Orders WHERE CustomerID = 2 AND Amount > 100;
-- GO
SELECT cp.objtype, cp.usecounts, cp.size_in_bytes,
       qs.sql_handle, qs.query_hash, qs.query_plan_hash, st.text
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
LEFT JOIN sys.dm_exec_query_stats qs ON qs.plan_handle = cp.plan_handle
WHERE st.text LIKE N'%dbo.Orders%' AND st.text NOT LIKE N'%dm_exec%';
-- Разные sql_handle + одинаковый query_hash = запрос не параметризован.
-- Пара «маленький Adhoc (shell) + Prepared» = сработала простая параметризация.
GO

/* ---------- 8. Планы, оптимизация которых закончилась по таймауту (вопрос 20) ---------- */
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (50)
    qs.total_worker_time / 1000 AS total_cpu_ms,
    qs.execution_count,
    SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, 300) AS statement_start,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qp.query_plan.exist('//StmtSimple[@StatementOptmEarlyAbortReason="TimeOut"]') = 1
ORDER BY qs.total_worker_time DESC;
-- Для очень больших планов sys.dm_exec_query_plan может вернуть NULL (вложенность XML > 128):
-- тогда используйте sys.dm_exec_text_query_plan и поиск по тексту.
GO

/* ---------- 9. Операторы плана из кэша по стоимости (вопрос 55а) ---------- */
-- Подставьте фильтр текста запроса. Берётся самый «тяжёлый» по чтениям план.
DECLARE @text_filter nvarchar(200) = N'%dbo.Orders%';
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
p AS
(
    SELECT TOP (1) qp.query_plan
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
    WHERE st.text LIKE @text_filter AND st.text NOT LIKE N'%dm_exec%'
    ORDER BY qs.total_logical_reads DESC
)
SELECT
    r.value('@NodeId', 'int')                             AS node_id,
    r.value('@PhysicalOp', 'nvarchar(60)')                AS physical_op,
    r.value('@LogicalOp', 'nvarchar(60)')                 AS logical_op,
    r.value('@EstimatedTotalSubtreeCost', 'float')
      - r.value('sum(*/RelOp/@EstimatedTotalSubtreeCost)', 'float') AS operator_cost,   -- собственная
    r.value('@EstimatedTotalSubtreeCost', 'float')        AS subtree_cost,
    r.value('@EstimateIO', 'float')                       AS io_cost_per_exec,
    r.value('@EstimateCPU', 'float')                      AS cpu_cost_per_exec,
    r.value('@EstimateRows', 'float')                     AS est_rows_per_exec,
    1 + r.value('@EstimateRebinds', 'float')
      + r.value('@EstimateRewinds', 'float')              AS est_executions
FROM p
CROSS APPLY p.query_plan.nodes('//RelOp') AS x(r)
ORDER BY operator_cost DESC;
-- Это оценки. Фактические строки, выполнения и чтения смотрите в фактическом плане.
GO

/* ---------- 10. Перекомпиляции: кто, сколько и почему (вопрос 14) ---------- */
-- 10.1 Инструкции, которые перекомпилировались чаще всего
SELECT TOP (20)
       qs.plan_generation_num, qs.execution_count, qs.creation_time, qs.last_execution_time,
       SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, 200) AS stmt
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.plan_generation_num DESC;
GO
-- 10.2 Компиляции и перекомпиляции по серверу (накопительные значения:
--      сделайте два снимка с интервалом и посчитайте разницу)
SELECT counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%SQL Statistics%'
  AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec');
GO
-- 10.3 Причины перекомпиляций: XE-сессия (подставьте имя базы)
-- CREATE EVENT SESSION [Recompiles] ON SERVER
-- ADD EVENT sqlserver.sql_statement_recompile (
--     ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id)
--     WHERE sqlserver.database_name = N'MyDb')
-- ADD TARGET package0.ring_buffer;
-- ALTER EVENT SESSION [Recompiles] ON SERVER STATE = START;
-- -- Watch Live Data -> поле recompile_cause
-- ALTER EVENT SESSION [Recompiles] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [Recompiles] ON SERVER;

-- 10.4 Демонстрация причин (на тестовой таблице dbo.T с индексом и запросом в цикле):
--   ALTER TABLE / CREATE INDEX           -> Schema changed
--   UPDATE STATISTICS после изменений     -> Statistics changed
--   EXEC sp_recompile N'dbo.T'           -> следующий вызов перекомпилируется
--   SET ANSI_NULLS OFF внутри пакета      -> Set option change
