/* =====================================================================
   Ожидания и блокировки: где сервер теряет время
   Вопросы 64, 66, 67 методички.
   ===================================================================== */

/* ---------- 1. Накопленные ожидания сервера (с момента старта / очистки) ---------- */
WITH w AS
(
    SELECT wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (   -- фоновые «безобидные» ожидания
        N'SLEEP_TASK', N'LAZYWRITER_SLEEP', N'SQLTRACE_BUFFER_FLUSH', N'BROKER_TASK_STOP',
        N'XE_TIMER_EVENT', N'XE_DISPATCHER_WAIT', N'REQUEST_FOR_DEADLOCK_SEARCH',
        N'LOGMGR_QUEUE', N'CHECKPOINT_QUEUE', N'FT_IFTS_SCHEDULER_IDLE_WAIT',
        N'BROKER_TO_FLUSH', N'BROKER_EVENTHANDLER', N'DIRTY_PAGE_POLL',
        N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'SP_SERVER_DIAGNOSTICS_SLEEP',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'WAITFOR', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'SLEEP_SYSTEMTASK')
      AND wait_type NOT LIKE N'PREEMPTIVE_%'
      AND wait_time_ms > 0
)
SELECT TOP (15)
    wait_type,
    wait_time_ms / 1000.0                                   AS wait_s,
    CAST(100.0 * wait_time_ms / SUM(wait_time_ms) OVER () AS decimal(5,2)) AS pct,
    signal_wait_time_ms / 1000.0                            AS signal_s,   -- ожидание CPU после сигнала
    waiting_tasks_count,
    wait_time_ms / NULLIF(waiting_tasks_count, 0)           AS avg_ms
FROM w
ORDER BY wait_time_ms DESC;
/*  Как читать:
    PAGEIOLATCH_*      — ждём чтения страницы с диска: много физ. чтений / мало памяти / медленный диск
    LCK_M_*            — ждём блокировку другой транзакции
    CXPACKET/CXCONSUMER— синхронизация параллельных потоков (часто симптом перекоса или лишнего параллелизма)
    SOS_SCHEDULER_YIELD— задачам не хватает CPU (тяжёлые вычисления, сканы в памяти)
    WRITELOG           — медленная запись журнала транзакций
    RESOURCE_SEMAPHORE — очередь за грантом памяти (завышенные memory grant)
    ASYNC_NETWORK_IO   — клиент медленно забирает результат
    PAGELATCH_*        — конкуренция за страницу в памяти (горячая страница, tempdb) */
GO

-- Сбросить статистику ожиданий, чтобы померить «окно» (осторожно на проде):
-- DBCC SQLPERF (N'sys.dm_os_wait_stats', CLEAR);

/* ---------- 2. Кто сейчас выполняется и чего ждёт ---------- */
SELECT r.session_id, r.status, r.blocking_session_id,
       r.wait_type, r.wait_time AS wait_ms, r.last_wait_type,
       r.cpu_time AS cpu_ms, r.total_elapsed_time AS elapsed_ms, r.logical_reads,
       DB_NAME(r.database_id) AS db, s.program_name, s.host_name,
       SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
         (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
               ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1) AS stmt
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id <> @@SPID AND s.is_user_process = 1
ORDER BY r.total_elapsed_time DESC;
/*  Медленный запрос:     cpu_ms и logical_reads растут между запусками, blocking_session_id = 0.
    Ждёт блокировку:      wait_type = LCK_M_*, blocking_session_id <> 0, cpu/reads стоят на месте. */
GO

/* ---------- 3. Цепочки блокировок: кто голова ---------- */
SELECT wt.session_id, wt.blocking_session_id, wt.wait_type, wt.wait_duration_ms,
       wt.resource_description
FROM sys.dm_os_waiting_tasks wt
WHERE wt.blocking_session_id IS NOT NULL AND wt.blocking_session_id <> wt.session_id
ORDER BY wt.wait_duration_ms DESC;
GO

/* ---------- 4. Ожидания конкретной сессии (SQL Server 2016+) ---------- */
-- SELECT * FROM sys.dm_exec_session_wait_stats WHERE session_id = 55 ORDER BY wait_time_ms DESC;

/* ---------- 5. Демонстрация блокировки (два окна SSMS) ----------
   Окно 1:  BEGIN TRAN; UPDATE StatsDemo.dbo.Orders SET Amount = Amount WHERE OrderID = 1;
   Окно 2:  SELECT * FROM StatsDemo.dbo.Orders WHERE OrderID = 1;    -- висит
   Окно 3:  запрос из блока 2 -> у окна 2 wait_type = LCK_M_S, blocking_session_id = SPID окна 1
   Окно 1:  ROLLBACK;                                                -- окно 2 сразу завершается */

/* ---------- 6. Дедлоки уже лежат в system_health ---------- */
SELECT CAST(event_data AS xml) AS deadlock_xml
FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL)
WHERE object_name = N'xml_deadlock_report';
GO
