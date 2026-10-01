/* =====================================================================
   Расследования: кейсы по метрикам Duration / CPU / Reads / Writes / RowCount
   Документ docs/11-case-studies.md. Тестовый экземпляр, SQL Server 2016+.

   Скрипт сам собирает трассу Extended Events по ВАШЕЙ сессии (фильтр по SPID)
   и в конце строит сводку метрик по query_hash — как при разборе трассы Profiler.
   Выполнять ПО БЛОКАМ в ОДНОМ окне SSMS. Для блока 4 нужно второе окно.
   Совет: Query → Query Options → Results → Grid → «Discard results after execution»,
   чтобы SSMS не тратил время на показ сотен тысяч строк.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'CasesDemo') IS NOT NULL
BEGIN
    ALTER DATABASE CasesDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CasesDemo;
END;
GO
CREATE DATABASE CasesDemo;
GO
USE CasesDemo;
GO

/* ---------- 0. Данные: 50 000 клиентов, 1 000 000 заказов.
   Клиент 1 — «крупный»: 20% всех заказов (для кейса 3). ---------- */
CREATE TABLE dbo.Customers
(
    CustomerID int          NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Name       nvarchar(50) NOT NULL,
    Region     nvarchar(30) NOT NULL
);
CREATE TABLE dbo.Orders
(
    OrderID    int           NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int           NOT NULL,
    OrderDate  date          NOT NULL,
    Status     tinyint       NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Comment    nvarchar(100) NOT NULL
);
GO
;WITH n AS (SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
SELECT n INTO #N FROM n;
INSERT dbo.Customers SELECT n, N'Клиент ' + CAST(n AS nvarchar(10)),
       CASE n % 5 WHEN 0 THEN N'Москва' WHEN 1 THEN N'Казань' WHEN 2 THEN N'Пермь' WHEN 3 THEN N'Томск' ELSE N'Омск' END
FROM #N WHERE n <= 50000;
INSERT dbo.Orders SELECT n,
       CASE WHEN n % 5 = 0 THEN 1 ELSE n % 50000 + 1 END,
       DATEADD(DAY, -(n % 1500), '20260101'), (n / 7) % 5, n % 1000, N'комментарий'
FROM #N;
DROP TABLE #N;
GO
CREATE INDEX IX_Orders_OrderDate ON dbo.Orders (OrderDate) INCLUDE (CustomerID, Amount);
GO

/* ---------- Трасса XE по текущей сессии ---------- */
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'CasesTrace')
    DROP EVENT SESSION [CasesTrace] ON SERVER;
DECLARE @sql nvarchar(max) = N'
CREATE EVENT SESSION [CasesTrace] ON SERVER
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (sqlserver.query_hash)
    WHERE sqlserver.session_id = ' + CAST(@@SPID AS nvarchar(10)) + N'
      AND sqlserver.database_name = N''CasesDemo'')
ADD TARGET package0.ring_buffer (SET max_events_limit = 50000)
WITH (MAX_DISPATCH_LATENCY = 1 SECONDS);';
EXEC (@sql);
ALTER EVENT SESSION [CasesTrace] ON SERVER STATE = START;
GO

/* =====================================================================
   КЕЙС 1. Вложенный (коррелированный) подзапрос на каждую строку
   ===================================================================== */
-- 1.1 «До»: индекса по Orders.CustomerID нет -> NL, нижний вход выполняется на каждого клиента
--     (скан / Index Spool). Ограничили 300 клиентами, чтобы не ждать слишком долго.
SELECT c.CustomerID, c.Name,
       (SELECT TOP (1) o.OrderDate FROM dbo.Orders o
        WHERE o.CustomerID = c.CustomerID ORDER BY o.OrderDate DESC) AS LastOrderDate
FROM dbo.Customers c
WHERE c.Region = N'Москва' AND c.CustomerID BETWEEN 2 AND 1500;
GO
-- 1.2 «После», вариант А: переписать на множество
SELECT c.CustomerID, c.Name, lo.LastOrderDate
FROM dbo.Customers c
LEFT JOIN (SELECT CustomerID, MAX(OrderDate) AS LastOrderDate
           FROM dbo.Orders GROUP BY CustomerID) lo ON lo.CustomerID = c.CustomerID
WHERE c.Region = N'Москва' AND c.CustomerID BETWEEN 2 AND 1500;
GO
-- 1.3 «После», вариант Б: индекс под подзапрос -> Seek + Top 1 на клиента
CREATE INDEX IX_Orders_Customer_Date ON dbo.Orders (CustomerID, OrderDate DESC);
GO
SELECT c.CustomerID, c.Name,
       (SELECT TOP (1) o.OrderDate FROM dbo.Orders o
        WHERE o.CustomerID = c.CustomerID ORDER BY o.OrderDate DESC) AS LastOrderDate
FROM dbo.Customers c
WHERE c.Region = N'Москва' AND c.CustomerID BETWEEN 2 AND 1500;
GO

/* =====================================================================
   КЕЙС 2. Несаргабельное условие
   ===================================================================== */
-- 2.1 «До»: YEAR() над столбцом -> скан индекса по дате, Reads ≫ RowCount
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND YEAR(OrderDate) = 2025;
GO
-- 2.2 «После»: диапазон (IX_Orders_Customer_Date из кейса 1 даёт Seek по обоим условиям)
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND OrderDate >= '20250101' AND OrderDate < '20260101';
GO

/* =====================================================================
   КЕЙС 3. Один запрос: то мгновенно, то долго (parameter sniffing)
   ===================================================================== */
DROP INDEX IX_Orders_Customer_Date ON dbo.Orders;
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID);          -- НЕ покрывающий
GO
CREATE OR ALTER PROCEDURE dbo.GetCustomerOrders @c int AS
    SELECT OrderID, OrderDate, Amount FROM dbo.Orders WHERE CustomerID = @c;
GO
-- 3.1 Первым пришёл маленький клиент -> в кэше Seek + Key Lookup.
--     Крупный клиент (1) получает 200 000 Key Lookup.
EXEC sp_recompile N'dbo.GetCustomerOrders';
EXEC dbo.GetCustomerOrders @c = 7;
EXEC dbo.GetCustomerOrders @c = 8;
EXEC dbo.GetCustomerOrders @c = 1;     -- долгий
EXEC dbo.GetCustomerOrders @c = 9;
GO
-- 3.2 «После»: покрывающий индекс — один план хорош для всех
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID) INCLUDE (OrderDate, Amount)
WITH (DROP_EXISTING = ON);
GO
EXEC dbo.GetCustomerOrders @c = 7;
EXEC dbo.GetCustomerOrders @c = 1;
GO

/* =====================================================================
   КЕЙС 4. Ждёт блокировку (нужно второе окно)
   ===================================================================== */
/* Окно 2:  USE CasesDemo; BEGIN TRAN; UPDATE dbo.Orders SET Amount = Amount WHERE OrderID = 12345;
   Окно 1 (это): выполните запрос ниже — он повиснет.
   Окно 3 (или окно 2 позже): блок 2 скрипта 09_waits_and_blocking.sql -> LCK_M_S, blocking_session_id.
   Окно 2:  через ~15 секунд ROLLBACK.
   В сводке ниже у этого запроса Duration ≈ 15 000 мс, CPU ≈ 0, Reads ≈ 3. */
-- SELECT Status, Amount FROM dbo.Orders WHERE OrderID = 12345;

/* =====================================================================
   КЕЙС 5. SELECT, который пишет (spill)
   ===================================================================== */
-- Табличная переменная: оценка 1 строка -> маленький грант -> Sort/Hash уходят в tempdb (Writes > 0)
DECLARE @Recent TABLE (OrderID int, CustomerID int, Amount decimal(12,2));
INSERT @Recent SELECT OrderID, CustomerID, Amount FROM dbo.Orders WHERE OrderDate >= '20250101';
SELECT CustomerID, COUNT(*) AS Cnt, SUM(Amount) AS Total
FROM @Recent
GROUP BY CustomerID
ORDER BY Total DESC
OPTION (USE HINT('DISABLE_DEFERRED_COMPILATION_TV'));
GO
-- «После»: временная таблица со статистикой — грант по реальному числу строк, Writes = 0
CREATE TABLE #Recent (OrderID int, CustomerID int, Amount decimal(12,2));
INSERT #Recent SELECT OrderID, CustomerID, Amount FROM dbo.Orders WHERE OrderDate >= '20250101';
SELECT CustomerID, COUNT(*) AS Cnt, SUM(Amount) AS Total
FROM #Recent
GROUP BY CustomerID
ORDER BY Total DESC;
DROP TABLE #Recent;
GO

/* =====================================================================
   КЕЙС 6. Запрос в цикле
   ===================================================================== */
-- 6.1 «До»: 5 000 обращений по ключу (как реквизит через точку в цикле 1С)
DECLARE @i int = 1, @a decimal(12,2), @sum decimal(18,2) = 0;
WHILE @i <= 5000
BEGIN
    SELECT @a = Amount FROM dbo.Orders WHERE OrderID = @i;
    SET @sum += @a;
    SET @i += 1;
END;
SELECT @sum AS total_loop;
GO
-- 6.2 «После»: один запрос на множество
SELECT SUM(Amount) AS total_set FROM dbo.Orders WHERE OrderID BETWEEN 1 AND 5000;
GO

/* =====================================================================
   КЕЙС 7. Огромный результат
   ===================================================================== */
-- RowCount — сотни тысяч, CPU небольшой, Duration зависит от клиента (ASYNC_NETWORK_IO)
SELECT OrderID, CustomerID, OrderDate, Amount, Comment
FROM dbo.Orders WHERE OrderDate >= '20240101';
GO

/* =====================================================================
   КЕЙС 9. Компиляции: тексты отличаются только литералами
   ===================================================================== */
-- Компиляции считаем серверным счётчиком (компиляция не входит в cpu_time события выполнения).
-- Счётчик общий на сервер — запускайте на тестовом сервере без нагрузки.
IF OBJECT_ID(N'tempdb..#comp') IS NOT NULL DROP TABLE #comp;
CREATE TABLE #comp (id int IDENTITY, step varchar(30), compilations bigint);
INSERT #comp (step, compilations)
SELECT 'start', cntr_value FROM sys.dm_os_performance_counters
WHERE counter_name = N'SQL Compilations/sec' AND object_name LIKE N'%SQL Statistics%';
GO
-- 9.1 «До»: 500 разных текстов -> 500 компиляций
DECLARE @i int = 1, @t nvarchar(300);
WHILE @i <= 500
BEGIN
    SET @t = N'SELECT COUNT(*) FROM dbo.Orders o JOIN dbo.Customers c ON c.CustomerID = o.CustomerID '
           + N'WHERE c.CustomerID = ' + CAST(@i + 100 AS nvarchar(10)) + N' AND o.Status = 2;';
    EXEC (@t);
    SET @i += 1;
END;
INSERT #comp (step, compilations)
SELECT 'after 9.1 (literals)', cntr_value FROM sys.dm_os_performance_counters
WHERE counter_name = N'SQL Compilations/sec' AND object_name LIKE N'%SQL Statistics%';
GO
-- 9.2 «После»: один параметризованный текст -> одна компиляция
--     (COUNT_BIG вместо COUNT — чтобы в сводке ниже у варианта был свой query_hash)
DECLARE @i int = 1;
WHILE @i <= 500
BEGIN
    EXEC sp_executesql
        N'SELECT COUNT_BIG(*) FROM dbo.Orders o JOIN dbo.Customers c ON c.CustomerID = o.CustomerID
          WHERE c.CustomerID = @c AND o.Status = 2;',
        N'@c int', @c = @i + 100;
    SET @i += 1;
END;
INSERT #comp (step, compilations)
SELECT 'after 9.2 (parameters)', cntr_value FROM sys.dm_os_performance_counters
WHERE counter_name = N'SQL Compilations/sec' AND object_name LIKE N'%SQL Statistics%';
GO
-- 9.3 Сколько компиляций дал каждый вариант (cntr_value накопительный)
SELECT step, compilations - LAG(compilations) OVER (ORDER BY id) AS compilations_in_step
FROM #comp ORDER BY id;     -- ожидаемо: ~500 и единицы
GO

/* =====================================================================
   СВОДКА ТРАССЫ: метрики по query_hash (как группировка трассы Profiler)
   Время в XE — микросекунды; здесь переведено в миллисекунды.
   ===================================================================== */
WITH x AS
(
    SELECT CAST(t.target_data AS xml) AS d
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
    WHERE s.name = N'CasesTrace' AND t.target_name = N'ring_buffer'
),
e AS
(
    SELECT ev.value('(data[@name="duration"]/value)[1]',      'bigint')        AS duration_us,
           ev.value('(data[@name="cpu_time"]/value)[1]',      'bigint')        AS cpu_us,
           ev.value('(data[@name="logical_reads"]/value)[1]', 'bigint')        AS reads,
           ev.value('(data[@name="physical_reads"]/value)[1]','bigint')        AS physical_reads,
           ev.value('(data[@name="writes"]/value)[1]',        'bigint')        AS writes,
           ev.value('(data[@name="row_count"]/value)[1]',     'bigint')        AS row_count,
           ev.value('(action[@name="query_hash"]/value)[1]',  'decimal(20,0)') AS query_hash,
           ev.value('(data[@name="statement"]/value)[1]',     'nvarchar(max)') AS stmt
    FROM x CROSS APPLY x.d.nodes('/RingBufferTarget/event') AS n(ev)
)
SELECT LEFT(MIN(stmt), 120)              AS statement_start,
       COUNT(*)                          AS executions,
       SUM(duration_us) / 1000           AS total_duration_ms,
       AVG(duration_us) / 1000           AS avg_duration_ms,
       SUM(cpu_us) / 1000                AS total_cpu_ms,
       SUM(reads)                        AS total_reads,
       MIN(reads)                        AS min_reads,
       MAX(reads)                        AS max_reads,
       SUM(physical_reads)               AS physical_reads,
       SUM(writes)                       AS writes,
       SUM(row_count)                    AS rows_total
FROM e
WHERE stmt NOT LIKE N'%RingBufferTarget%'
GROUP BY query_hash
ORDER BY total_duration_ms DESC;
/* Что искать (см. «Карта сигнатур» в docs/11-case-studies.md):
   - кейс 1: огромные reads на небольшое число строк, у «после» — на порядки меньше;
   - кейс 2: reads ≫ rows_total; после — reads ≈ единицы;
   - кейс 3: у процедуры min_reads ≪ max_reads;
   - кейс 5: writes > 0 у SELECT по табличной переменной, у #Recent — 0;
   - кейс 6: executions = 5 000 при reads ≈ 3 на вызов против одного запроса;
   - кейс 7: rows_total — сотни тысяч, cpu мал относительно duration;
   - кейс 9: 500 текстов с литералами сгруппированы в одну строку (одинаковый query_hash),
     параметризованный вариант — отдельной строкой; число компиляций — в результате блока 9.3. */
GO
-- Остановить и удалить трассу
-- ALTER EVENT SESSION [CasesTrace] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [CasesTrace] ON SERVER;
-- Уборка
-- USE master; ALTER DATABASE CasesDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE CasesDemo;
