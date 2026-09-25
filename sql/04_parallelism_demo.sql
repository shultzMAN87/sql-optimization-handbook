/* =====================================================================
   Демонстрация параллелизма в SQL Server
   ---------------------------------------------------------------------
   Требования: SQL Server 2016+ (часть примеров — 2019+, помечено).
   Запускать ТОЛЬКО на тестовом экземпляре: в разделе 7 временно
   меняется серверный параметр cost threshold for parallelism.

   Порядок работы:
     1) выполнить разделы 0–1 (создание базы и данных, ~1–2 мин);
     2) далее выполнять запросы по одному с включённым фактическим
        планом (SSMS: Ctrl+M, "Include Actual Execution Plan");
     3) в плане смотреть свойства операторов Parallelism:
        Logical Operation, Partitioning Type, Partition Columns,
        Order By, а также Actual Number of Rows → разбивку по потокам.
   ===================================================================== */

/* ---------------------------------------------------------------------
   0. Подготовка базы и текущие настройки
   --------------------------------------------------------------------- */
USE master;
GO
IF DB_ID(N'ParallelDemo') IS NOT NULL
BEGIN
    ALTER DATABASE ParallelDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ParallelDemo;
END;
GO
CREATE DATABASE ParallelDemo;
GO
ALTER DATABASE ParallelDemo SET RECOVERY SIMPLE;
GO
USE ParallelDemo;
GO

-- Серверные параметры
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN (N'max degree of parallelism',
               N'cost threshold for parallelism',
               N'max worker threads');

-- MAXDOP на уровне базы (0 = берётся серверное значение)
SELECT name, value
FROM sys.database_scoped_configurations
WHERE name = N'MAXDOP';

-- Сколько процессоров/планировщиков видит сервер
SELECT cpu_count, scheduler_count, max_workers_count
FROM sys.dm_os_sys_info;
GO

/* ---------------------------------------------------------------------
   1. Тестовые данные
      Numbers   — вспомогательная таблица чисел (4 млн)
      Regions   — 20 строк (маленькая, для Broadcast)
      Customers — 200 тыс.
      Orders    — 4 млн; ManagerID намеренно перекошен:
                  90% строк имеют ManagerID = 1 (для демонстрации skew)
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Numbers (n int NOT NULL PRIMARY KEY);

INSERT dbo.Numbers WITH (TABLOCK) (n)
SELECT TOP (4000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM sys.all_objects AS a
CROSS JOIN sys.all_objects AS b
CROSS JOIN sys.all_objects AS c;
GO

CREATE TABLE dbo.Regions
(
    RegionID   int          NOT NULL PRIMARY KEY,
    RegionName nvarchar(50) NOT NULL
);
INSERT dbo.Regions (RegionID, RegionName)
SELECT n, N'Регион ' + CAST(n AS nvarchar(10))
FROM dbo.Numbers
WHERE n <= 20;

CREATE TABLE dbo.Customers
(
    CustomerID int           NOT NULL PRIMARY KEY,
    RegionID   int           NOT NULL,
    Name       nvarchar(100) NOT NULL
);
INSERT dbo.Customers WITH (TABLOCK) (CustomerID, RegionID, Name)
SELECT n, 1 + n % 20, N'Клиент ' + CAST(n AS nvarchar(10))
FROM dbo.Numbers
WHERE n <= 200000;

CREATE TABLE dbo.Orders
(
    OrderID    int           NOT NULL PRIMARY KEY,
    CustomerID int           NOT NULL,
    OrderDate  date          NOT NULL,
    Amount     decimal(18,2) NOT NULL,
    ManagerID  int           NOT NULL,
    Comment    char(200)     NOT NULL DEFAULT ('')  -- "утяжеляем" строки,
);                                                  -- чтобы росла стоимость

INSERT dbo.Orders WITH (TABLOCK) (OrderID, CustomerID, OrderDate, Amount, ManagerID)
SELECT
    n,
    1 + ABS(CHECKSUM(NEWID())) % 200000,
    DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 1095, '20240101'),
    CAST(ABS(CHECKSUM(NEWID())) % 10000000 AS decimal(18,2)) / 100,
    CASE WHEN n % 10 < 9 THEN 1 ELSE 2 + n % 50 END
FROM dbo.Numbers;
GO

UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
UPDATE STATISTICS dbo.Orders    WITH FULLSCAN;
GO

SET STATISTICS TIME ON;   -- в параллельном плане CPU time > elapsed time
SET STATISTICS IO   ON;
GO

/* ---------------------------------------------------------------------
   2. Gather Streams (N → 1) + параллельное сканирование
      Ожидаемый план:
        Clustered Index Scan (параллельный, страницы раздаёт
        parallel page supplier)
        → Stream Aggregate (частичный, в каждом потоке)
        → Parallelism (Gather Streams)
        → Stream Aggregate (глобальный)
      Сравните время и CPU с последовательным вариантом.
   --------------------------------------------------------------------- */
SELECT COUNT_BIG(*) AS Cnt, SUM(Amount) AS Total
FROM dbo.Orders
WHERE Amount > 10;

SELECT COUNT_BIG(*) AS Cnt, SUM(Amount) AS Total
FROM dbo.Orders
WHERE Amount > 10
OPTION (MAXDOP 1);   -- тот же запрос, последовательный план
GO

/* ---------------------------------------------------------------------
   3. Repartition Streams (N → N), Partitioning Type = Hash
      Группировка по ключу, отличному от ключа кластерного индекса.
      Типичный план:
        Scan → Hash Match (Partial Aggregate)
        → Repartition Streams (Hash, по CustomerID)
        → Hash Match (Aggregate) → Gather Streams
      Смысл: все строки одного CustomerID должны попасть в один поток.
   --------------------------------------------------------------------- */
SELECT o.CustomerID, COUNT_BIG(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Orders AS o
GROUP BY o.CustomerID;
GO

/* ---------------------------------------------------------------------
   4. Hash join: Repartition обеих сторон или Broadcast маленькой
      Orders ⋈ Customers — обычно обе стороны перераспределяются
      по CustomerID (Repartition Streams, Hash).
      Regions (20 строк) — обычно Distribute/Repartition Streams
      с Partitioning Type = Broadcast: каждому потоку копия таблицы.
      Также обратите внимание на оператор Bitmap перед probe-стороной.
   --------------------------------------------------------------------- */
SELECT r.RegionName, COUNT_BIG(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Orders    AS o
JOIN dbo.Customers AS c ON c.CustomerID = o.CustomerID
JOIN dbo.Regions   AS r ON r.RegionID   = c.RegionID
GROUP BY r.RegionName;
GO

/* ---------------------------------------------------------------------
   5. Order-preserving Gather Streams и Distribute Streams (1 → N)
      TOP + ORDER BY создаёт последовательную зону внутри плана:
        параллельная Sort (Top N Sort) в каждом потоке
        → Gather Streams со свойством Order By (слияние отсортированных
          потоков — merging exchange)
        → Top (выполняется в одном потоке)
        → Distribute Streams (Hash по CustomerID) — снова в параллель
        → Hash Match join с Customers → ...
   --------------------------------------------------------------------- */
SELECT t.CustomerID, c.Name, SUM(t.Amount) AS Total
FROM
(
    SELECT TOP (1000000) o.CustomerID, o.Amount
    FROM dbo.Orders AS o
    ORDER BY o.OrderDate DESC, o.OrderID DESC
) AS t
JOIN dbo.Customers AS c ON c.CustomerID = t.CustomerID
GROUP BY t.CustomerID, c.Name;
GO

/* ---------------------------------------------------------------------
   6. Перекос (skew) при Repartition Streams
      ROW_NUMBER() OVER (PARTITION BY ...) требует, чтобы все строки
      одной секции оказались в одном потоке → Repartition по ManagerID.
      90% строк имеют ManagerID = 1 → почти вся работа в одном потоке.
      Сравните Actual Number of Rows по потокам у оператора Sort
      в первом и втором запросе.
   --------------------------------------------------------------------- */
-- С перекосом
SELECT ManagerID, MAX(rn) AS MaxRn
FROM
(
    SELECT ManagerID,
           ROW_NUMBER() OVER (PARTITION BY ManagerID ORDER BY Amount) AS rn
    FROM dbo.Orders
) AS t
GROUP BY ManagerID;

-- Равномерное распределение
SELECT CustomerID, MAX(rn) AS MaxRn
FROM
(
    SELECT CustomerID,
           ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY Amount) AS rn
    FROM dbo.Orders
) AS t
GROUP BY CustomerID;
GO

/* ---------------------------------------------------------------------
   7. cost threshold for parallelism
      Порог сравнивается со стоимостью ПОСЛЕДОВАТЕЛЬНОГО плана.
      Шаг 1. Смотрим Estimated Subtree Cost корневого SELECT
             в последовательном плане (OPTION (MAXDOP 1)).
      Шаг 2. Ставим порог выше этой стоимости → план станет
             последовательным. Ставим ниже → снова параллельный.
      !!! Параметр серверный — только тестовый экземпляр.
   --------------------------------------------------------------------- */
SELECT c.RegionID, COUNT_BIG(*) AS Cnt
FROM dbo.Customers AS c
GROUP BY c.RegionID
OPTION (MAXDOP 1);   -- запомнить Estimated Subtree Cost
GO

-- Сохраняем исходное значение
DECLARE @old int =
    (SELECT CAST(value_in_use AS int) FROM sys.configurations
     WHERE name = N'cost threshold for parallelism');
SELECT @old AS OriginalCostThreshold;   -- ЗАПИШИТЕ, вернём в конце
GO

EXEC sp_configure 'show advanced options', 1;  RECONFIGURE;
EXEC sp_configure 'cost threshold for parallelism', 0; RECONFIGURE;
GO
-- Порог 0: даже дешёвый запрос по Customers станет параллельным
-- (если параллельный вариант окажется дешевле последовательного)
SELECT c.RegionID, COUNT_BIG(*) AS Cnt
FROM dbo.Customers AS c
GROUP BY c.RegionID
OPTION (RECOMPILE);
GO

EXEC sp_configure 'cost threshold for parallelism', 1000; RECONFIGURE;
GO
-- Порог 1000: даже тяжёлый запрос из раздела 3 станет последовательным
SELECT o.CustomerID, COUNT_BIG(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Orders AS o
GROUP BY o.CustomerID
OPTION (RECOMPILE);
GO

-- Вернуть исходное значение (подставьте то, что записали; по умолчанию 5)
EXEC sp_configure 'cost threshold for parallelism', 5; RECONFIGURE;
GO

/* ---------------------------------------------------------------------
   8. Приоритет настроек MAXDOP: база vs хинт запроса
      Хинт OPTION (MAXDOP n) перекрывает настройку базы и сервера
      (но не MAX_DOP группы Resource Governor).
      Фактический DOP — в свойстве Degree of Parallelism корневого
      SELECT фактического плана и в last_dop (раздел 10).
   --------------------------------------------------------------------- */
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 2;
GO
SELECT COUNT_BIG(*) FROM dbo.Orders WHERE Amount > 20
OPTION (RECOMPILE);                -- DOP = 2 (из настройки базы)

SELECT COUNT_BIG(*) FROM dbo.Orders WHERE Amount > 20
OPTION (RECOMPILE, MAXDOP 4);      -- DOP = 4 (хинт сильнее)
GO
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;
GO

/* ---------------------------------------------------------------------
   9. Ингибиторы параллелизма и NonParallelPlanReason
      9.1 Скалярная UDF, которую нельзя инлайнить.
          SQL Server 2019+: WITH INLINE = OFF запрещает инлайнинг.
          На 2016/2017 уберите "WITH INLINE = OFF" — там скалярные
          UDF и так всегда блокируют параллелизм.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_Vat (@a decimal(18,2))
RETURNS decimal(18,2)
WITH INLINE = OFF
AS
BEGIN
    RETURN @a * 0.2;
END;
GO

SELECT SUM(dbo.fn_Vat(Amount)) AS Vat
FROM dbo.Orders;
-- В свойствах корневого SELECT: NonParallelPlanReason =
-- TSQLUserDefinedFunctionsNotParallelizable
GO

-- 9.2 Модификация табличной переменной
DECLARE @t TABLE (CustomerID int, Total decimal(18,2));
INSERT @t (CustomerID, Total)
SELECT CustomerID, SUM(Amount)
FROM dbo.Orders
GROUP BY CustomerID;
-- NonParallelPlanReason у оператора INSERT (обычно
-- TableVariableTransactionsDoNotSupportParallelNestedTransaction).
-- Для сравнения: INSERT во временную таблицу #t может быть параллельным.
GO

/* ---------------------------------------------------------------------
   10. Анализ по кэшу планов: какие запросы параллельные, их DOP,
       стоимость последовательной части и причина отказа от параллелизма
   --------------------------------------------------------------------- */
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (30)
    qs.execution_count,
    qs.last_dop,
    qs.max_dop,
    qs.total_worker_time  / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.total_elapsed_time / qs.execution_count / 1000 AS avg_elapsed_ms,
    qp.query_plan.value('(//StmtSimple/@StatementSubTreeCost)[1]', 'float')
        AS EstimatedCost,
    qp.query_plan.value('(//QueryPlan/@DegreeOfParallelism)[1]', 'int')
        AS PlanDOP,
    qp.query_plan.value('(//QueryPlan/@NonParallelPlanReason)[1]', 'nvarchar(200)')
        AS NonParallelPlanReason,
    SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
        (CASE qs.statement_end_offset
             WHEN -1 THEN DATALENGTH(st.text)
             ELSE qs.statement_end_offset
         END - qs.statement_start_offset) / 2 + 1) AS StatementText,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)     AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle)  AS qp
WHERE st.text LIKE N'%dbo.Orders%'
  AND st.text NOT LIKE N'%dm_exec_query_stats%'
ORDER BY qs.last_execution_time DESC;
GO

/* ---------------------------------------------------------------------
   11. Потоки и ожидания CX* во время выполнения
       Сессия А: запустить тяжёлый запрос ниже (десятки секунд).
       Сессия Б: пока он выполняется — запросы 11.2 и 11.3,
                 подставив session_id сессии А.
   --------------------------------------------------------------------- */
-- 11.1 (сессия А) Тяжёлый запрос: самосоединение ~80 млн строк
SELECT o1.CustomerID, COUNT_BIG(*) AS Pairs
FROM dbo.Orders AS o1
JOIN dbo.Orders AS o2 ON o2.CustomerID = o1.CustomerID
GROUP BY o1.CustomerID;
GO

-- 11.2 (сессия Б) DOP и количество задач/потоков запроса
--      Потоков будет больше, чем DOP: DOP × число активных веток + координатор
SELECT r.session_id, r.dop, r.parallel_worker_count,
       COUNT(t.task_address) AS tasks
FROM sys.dm_exec_requests AS r
JOIN sys.dm_os_tasks      AS t ON t.session_id = r.session_id
WHERE r.session_id = 55              -- <== session_id сессии А
GROUP BY r.session_id, r.dop, r.parallel_worker_count;

-- 11.3 (сессия Б) Кто чего ждёт внутри параллельного запроса
--      exec_context_id = 0 — координатор; resource_description
--      содержит детали порта обмена (nodeId оператора Parallelism)
SELECT wt.session_id, wt.exec_context_id, wt.wait_type,
       wt.wait_duration_ms, wt.resource_description
FROM sys.dm_os_waiting_tasks AS wt
WHERE wt.session_id = 55             -- <== session_id сессии А
ORDER BY wt.exec_context_id;
GO

-- 11.4 (сессия А, после завершения) Накопленные ожидания своей сессии
SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_exec_session_wait_stats
WHERE session_id = @@SPID
  AND wait_type LIKE N'CX%'
ORDER BY wait_time_ms DESC;
GO

/* ---------------------------------------------------------------------
   12. Очистка
   --------------------------------------------------------------------- */
SET STATISTICS TIME OFF;
SET STATISTICS IO   OFF;
GO
USE master;
GO
ALTER DATABASE ParallelDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE ParallelDemo;
GO
