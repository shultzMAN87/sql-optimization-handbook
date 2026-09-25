/* =====================================================================
   Предупреждения (warnings) в плане выполнения — демонстрация
   ---------------------------------------------------------------------
   Требования: SQL Server 2016 SP1+ (2019+ желательно).
   Запускать на тестовом экземпляре.

   Основные примеры:
     A. Неявное преобразование (PlanAffectingConvert)
     B. Сброс в tempdb (SpillToTempDb: Sort Warning, Hash Warning)
   Бонус:
     C. Columns With No Statistics
     D. Поиск предупреждений в кэше планов

   Смотреть: фактический план (Ctrl+M) → жёлтый треугольник
   на операторе / на корневом SELECT → F4 (Properties) → Warnings.
   ===================================================================== */

USE master;
GO
IF DB_ID(N'WarningsDemo') IS NOT NULL
BEGIN
    ALTER DATABASE WarningsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE WarningsDemo;
END;
GO
CREATE DATABASE WarningsDemo;
GO
ALTER DATABASE WarningsDemo SET RECOVERY SIMPLE;
GO
USE WarningsDemo;
GO

/* ---------------------------------------------------------------------
   0. Данные
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Numbers (n int NOT NULL PRIMARY KEY);
INSERT dbo.Numbers WITH (TABLOCK) (n)
SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c;
GO

-- Clients: одни и те же коды в столбцах varchar с РАЗНЫМИ сортировками
CREATE TABLE dbo.Clients
(
    ClientID int NOT NULL PRIMARY KEY,
    CodeSql  varchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL, -- SQL-сортировка
    CodeWin  varchar(20) COLLATE Cyrillic_General_CI_AS        NOT NULL, -- Windows-сортировка
    Inn      varchar(12) NOT NULL,          -- "числовой" код, хранящийся строкой
    City     varchar(50) NOT NULL
);

INSERT dbo.Clients WITH (TABLOCK) (ClientID, CodeSql, CodeWin, Inn, City)
SELECT n,
       'CL' + RIGHT('0000000' + CAST(n AS varchar(10)), 7),
       'CL' + RIGHT('0000000' + CAST(n AS varchar(10)), 7),
       CAST(7700000000 + n AS varchar(12)),
       CASE n % 5 WHEN 0 THEN 'Москва' WHEN 1 THEN 'Казань'
                  WHEN 2 THEN 'Пермь'  WHEN 3 THEN 'Тула' ELSE 'Омск' END
FROM dbo.Numbers;

CREATE INDEX IX_Clients_CodeSql ON dbo.Clients (CodeSql);
CREATE INDEX IX_Clients_CodeWin ON dbo.Clients (CodeWin);
CREATE INDEX IX_Clients_Inn     ON dbo.Clients (Inn);

-- Sales: "широкие" строки, чтобы сортировка требовала много памяти
CREATE TABLE dbo.Sales
(
    SaleID   int           NOT NULL PRIMARY KEY,
    ClientID int           NOT NULL,
    SaleDate datetime2(0)  NOT NULL,
    Amount   decimal(18,2) NOT NULL,
    Filler   char(300)     NOT NULL
);

INSERT dbo.Sales WITH (TABLOCK) (SaleID, ClientID, SaleDate, Amount, Filler)
SELECT n,
       1 + ABS(CHECKSUM(NEWID())) % 1000000,
       DATEADD(MINUTE, ABS(CHECKSUM(NEWID())) % 1000000, '20250101'),
       CAST(ABS(CHECKSUM(NEWID())) % 1000000 AS decimal(18,2)) / 100,
       'x'
FROM dbo.Numbers;
GO

SET STATISTICS IO ON;
GO

/* =====================================================================
   A. НЕЯВНОЕ ПРЕОБРАЗОВАНИЕ (PlanAffectingConvert)
   Правило: при сравнении разных типов SQL Server приводит тип
   с МЕНЬШИМ приоритетом к типу с БОЛЬШИМ (nvarchar > varchar,
   int > varchar). Если преобразуется СТОЛБЕЦ — индекс по нему
   не может использоваться обычным seek'ом.
   ===================================================================== */

-- A1. Эталон: тип параметра совпадает со столбцом → Index Seek, без warning
DECLARE @codeA varchar(20) = 'CL0123456';
SELECT ClientID, CodeSql FROM dbo.Clients WHERE CodeSql = @codeA;
GO

-- A2. nvarchar против varchar с SQL-сортировкой
--     → CONVERT_IMPLICIT(nvarchar, CodeSql) на столбце → Index SCAN
--     Warning: "Type conversion in expression ... may affect
--              "SeekPlan" in query plan choice" (+ "CardinalityEstimate")
--     Типичный источник: ORM/драйвер передаёт строки как nvarchar.
DECLARE @codeN nvarchar(20) = N'CL0123456';
SELECT ClientID, CodeSql FROM dbo.Clients WHERE CodeSql = @codeN;
GO

-- A3. То же, но столбец с Windows-сортировкой
--     → план спасается "динамическим" seek'ом:
--       Compute Scalar + Constant Scan + GetRangeThroughConvert → Index Seek.
--     Warning на CardinalityEstimate всё равно есть, оценка строк хуже.
DECLARE @codeN nvarchar(20) = N'CL0123456';
SELECT ClientID, CodeWin FROM dbo.Clients WHERE CodeWin = @codeN;
GO

-- A4. Строковый столбец сравнивается с ЧИСЛОМ
--     int имеет больший приоритет → CONVERT_IMPLICIT(int, Inn) для
--     каждой строки → Index Scan. Бонус: если в Inn окажется
--     нечисловое значение, запрос упадёт с ошибкой преобразования.
SELECT ClientID, Inn FROM dbo.Clients WHERE Inn = 7700123456;
GO

-- A5. Исправление A4: литерал того же типа, что столбец → Seek
SELECT ClientID, Inn FROM dbo.Clients WHERE Inn = '7700123456';
GO

-- A6. Для сравнения: преобразуется КОНСТАНТА, а не столбец → проблемы нет
--     (ClientID int, литерал varchar приводится к int один раз)
SELECT ClientID FROM dbo.Clients WHERE ClientID = '123456';
GO

-- A7. "Ложная тревога": преобразование только в списке SELECT.
--     Warning про CardinalityEstimate может появиться, но на выбор
--     плана не влияет — такие предупреждения можно игнорировать.
SELECT TOP (10) CAST(ClientID AS varchar(10)) + CodeSql AS Txt
FROM dbo.Clients;
GO

/* =====================================================================
   B. СБРОС В TEMPDB (SpillToTempDb)
   Причина: оператору (Sort, Hash Match) выдали памяти меньше, чем
   понадобилось. Память выдаётся ДО выполнения по ОЦЕНКЕ строк
   и их размера, поэтому главный источник spill — недооценка.
   Предупреждения видны ТОЛЬКО в фактическом плане.
   Смотреть в свойствах:
     - оператора: Warnings → SpillToTempDb (SpillLevel,
       SpilledThreadCount, для 2016 SP2+/2017+ — Spilled pages,
       Writes/Reads to TempDb);
     - корневого SELECT: MemoryGrantInfo (GrantedMemory, MaxUsedMemory).
   OPTION (RECOMPILE) — чтобы memory grant feedback (2019+) не
   "подлечил" грант между запусками и эффект был воспроизводим.
   ===================================================================== */

-- B1. Sort spill из-за недооценки
--     Предикат над выражением от столбца нельзя оценить по статистике —
--     оптимизатор берёт фиксированную долю (для неравенства ~30%).
--     Фактически подходят ВСЕ строки → памяти на сортировку не хватает.
--     Сравните Estimated vs Actual Number of Rows у Sort.
SELECT SaleID, ClientID, SaleDate, Amount, Filler
FROM dbo.Sales
WHERE LEN(Filler) > 0
ORDER BY SaleDate
OPTION (RECOMPILE, MAXDOP 1);
GO

-- B1-fix. Та же выборка без "непрозрачного" предиката: оценка точная,
--         памяти выдано достаточно → Sort без предупреждения
SELECT SaleID, ClientID, SaleDate, Amount, Filler
FROM dbo.Sales
ORDER BY SaleDate
OPTION (RECOMPILE, MAXDOP 1);
GO

-- B2. Гарантированный Sort spill: искусственно урезаем грант.
--     Хинт MAX_GRANT_PERCENT ограничивает выдачу памяти в %
--     от лимита пула — здесь только для демонстрации.
SELECT SaleID, ClientID, SaleDate, Amount, Filler
FROM dbo.Sales
ORDER BY SaleDate
OPTION (RECOMPILE, MAXDOP 1, MAX_GRANT_PERCENT = 0.1);
GO

-- B3. Hash spill (Hash Warning): хеш-таблице build-стороны
--     не хватает памяти → часть секций уходит в tempdb.
--     В STATISTICS IO появится Workfile с чтениями/записями.
--     SpillLevel > 1 означает рекурсивное разбиение;
--     "bailout" — хеш-таблица так и не поместилась в память.
SELECT c.City, COUNT_BIG(*) AS Cnt, SUM(s.Amount) AS Total
FROM dbo.Sales   AS s
JOIN dbo.Clients AS c ON c.ClientID = s.ClientID
GROUP BY c.City
OPTION (RECOMPILE, MAXDOP 1, HASH JOIN, MAX_GRANT_PERCENT = 0.1);
GO

-- B4. Посмотреть гранты памяти "вживую" (из другой сессии,
--     пока выполняется тяжёлый запрос, например B1):
--     requested/granted/used, ideal_memory_kb; wait_time_ms > 0 —
--     запрос ждал выдачи памяти (RESOURCE_SEMAPHORE).
SELECT session_id, requested_memory_kb, granted_memory_kb,
       used_memory_kb, max_used_memory_kb, ideal_memory_kb,
       wait_time_ms, dop
FROM sys.dm_exec_query_memory_grants;
GO

/* =====================================================================
   C. БОНУС: Columns With No Statistics
   Появляется, когда оптимизатору нужна статистика по столбцу,
   а её нет и автосоздание выключено (AUTO_CREATE_STATISTICS OFF,
   read-only база без статистики и т.п.). Оценка — "угадайка".
   Предупреждение видно и в предполагаемом плане.
   ===================================================================== */
ALTER DATABASE WarningsDemo SET AUTO_CREATE_STATISTICS OFF;
GO
-- City не проиндексирован, статистики по нему нет
SELECT COUNT_BIG(*) FROM dbo.Clients WHERE City = 'Казань'
OPTION (RECOMPILE);
GO
-- Исправление: создать статистику (или включить автосоздание обратно)
CREATE STATISTICS ST_Clients_City ON dbo.Clients (City) WITH FULLSCAN;
GO
SELECT COUNT_BIG(*) FROM dbo.Clients WHERE City = 'Казань'
OPTION (RECOMPILE);
GO
ALTER DATABASE WarningsDemo SET AUTO_CREATE_STATISTICS ON;
GO

/* =====================================================================
   D. БОНУС: поиск предупреждений в кэше планов
   В кэше лежат ПРЕДПОЛАГАЕМЫЕ планы → spill и предупреждения
   о гранте там не видны; видны преобразования, отсутствие
   статистики, NoJoinPredicate, отсутствующие индексы.
   ===================================================================== */
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (50)
    qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qp.query_plan.exist('//Warnings/PlanAffectingConvert')     AS HasConvert,
    qp.query_plan.exist('//Warnings/ColumnsWithNoStatistics')  AS HasNoStats,
    qp.query_plan.exist('//Warnings[@NoJoinPredicate="1"]')    AS HasNoJoinPred,
    qp.query_plan.exist('//MissingIndexes')                    AS HasMissingIdx,
    qp.query_plan.value('(//Warnings/PlanAffectingConvert/@Expression)[1]',
                        'nvarchar(400)')                       AS ConvertExpr,
    st.text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qp.query_plan.exist('//Warnings') = 1
   OR qp.query_plan.exist('//MissingIndexes') = 1
ORDER BY qs.total_worker_time DESC;
GO

/* ---------------------------------------------------------------------
   Очистка
   --------------------------------------------------------------------- */
SET STATISTICS IO OFF;
GO
-- База WarningsDemo НЕ удаляется: она нужна скрипту 05_query_store_practice.sql.
-- Когда закончите с обоими скриптами, раскомментируйте:
-- USE master;
-- ALTER DATABASE WarningsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE WarningsDemo;
