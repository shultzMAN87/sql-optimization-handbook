/* =====================================================================
   Статистика: где хранится, как появляется автостатистика,
   автоматический процент выборки и выборка по страницам
   Вопросы 29б, 33, 34 методички. Тестовый экземпляр, SQL Server 2016 SP1+.
   Таблица ~1 млн строк (~150 МБ): больше порога 8 МБ, поэтому выборка будет не 100%.
   Выполнять ПО БЛОКАМ.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'StatsSampleDemo') IS NOT NULL
BEGIN
    ALTER DATABASE StatsSampleDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE StatsSampleDemo;
END;
GO
CREATE DATABASE StatsSampleDemo;
GO
ALTER DATABASE StatsSampleDemo SET AUTO_CREATE_STATISTICS ON;
GO
USE StatsSampleDemo;
GO

/* ---------- 0. Данные: 1 000 000 строк.
   ClusteredVal: «Rare» — 300 строк ПОДРЯД (физически на нескольких соседних страницах).
   ScatteredVal: «Rare» — 300 строк, разбросанных по всей таблице (каждая 3 333-я строка).
   Остальные значения — 50 «обычных» V0…V49. ---------- */
CREATE TABLE dbo.T
(
    Id           int        NOT NULL CONSTRAINT PK_T PRIMARY KEY CLUSTERED,
    ClusteredVal varchar(10) NOT NULL,
    ScatteredVal varchar(10) NOT NULL,
    Filler       char(120)  NOT NULL
);
GO
;WITH n AS
(
    SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_columns a CROSS JOIN sys.all_columns b
)
INSERT dbo.T (Id, ClusteredVal, ScatteredVal, Filler)
SELECT n,
       CASE WHEN n BETWEEN 500001 AND 500300 THEN 'Rare' ELSE 'V' + CAST(n % 50 AS varchar(2)) END,
       CASE WHEN n % 3333 = 0 AND n <= 999900 THEN 'Rare' ELSE 'V' + CAST(n % 50 AS varchar(2)) END,
       'x'
FROM n;
GO
SELECT ClusteredVal = SUM(CASE WHEN ClusteredVal = 'Rare' THEN 1 ELSE 0 END),
       ScatteredVal = SUM(CASE WHEN ScatteredVal = 'Rare' THEN 1 ELSE 0 END)
FROM dbo.T;                      -- по 300 «Rare» в обоих столбцах
EXEC sp_spaceused N'dbo.T';      -- размер таблицы: заметно больше 8 МБ
GO

/* =====================================================================
   БЛОК 1. Где живёт статистика (вопрос 29б)
   ===================================================================== */
-- 1.1 Описание статистик — представления поверх системных таблиц базы
SELECT s.name, s.stats_id, s.auto_created, s.user_created, s.no_recompute
FROM sys.stats s
WHERE s.object_id = OBJECT_ID(N'dbo.T');
GO
-- 1.2 Содержимое статистики первичного ключа — двоичный блок (НЕДОКУМЕНТИРОВАННАЯ опция)
DBCC SHOW_STATISTICS (N'dbo.T', N'PK_T') WITH STATS_STREAM;
GO

/* =====================================================================
   БЛОК 2. Автостатистика появляется при компиляции и записывается в базу (вопрос 33)
   ===================================================================== */
-- 2.1 До: статистик по ClusteredVal и ScatteredVal нет
SELECT name, auto_created FROM sys.stats WHERE object_id = OBJECT_ID(N'dbo.T');
GO
-- 2.2 Запросы с условием -> при компиляции создаются _WA_Sys_ (запрос ждёт построения)
SET STATISTICS TIME ON;
SELECT COUNT(*) FROM dbo.T WHERE ClusteredVal = 'V7';
SELECT COUNT(*) FROM dbo.T WHERE ScatteredVal = 'V7';
SET STATISTICS TIME OFF;     -- в Messages: у первого выполнения заметное время компиляции
GO
-- 2.3 После: появились _WA_Sys_…, auto_created = 1, выборка не 100%
SELECT s.name, c.name AS column_name, s.auto_created, sp.last_updated,
       sp.rows, sp.rows_sampled,
       CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS decimal(5,2)) AS sample_pct
FROM sys.stats s
JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id AND sc.stats_column_id = 1
JOIN sys.columns c        ON c.object_id = sc.object_id AND c.column_id = sc.column_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.T');
GO

/* =====================================================================
   БЛОК 3. Выборка по страницам: сгруппированные и разбросанные значения (вопрос 34)
   Для наглядности — маленькая явная выборка 2%. Результат случайный:
   повторите 3.1–3.3 несколько раз и сравните.
   ===================================================================== */
-- 3.1 Строим обе статистики по одинаковой маленькой выборке
IF EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID(N'dbo.T') AND name = N'st_Clustered')
    DROP STATISTICS dbo.T.st_Clustered;
IF EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID(N'dbo.T') AND name = N'st_Scattered')
    DROP STATISTICS dbo.T.st_Scattered;
CREATE STATISTICS st_Clustered ON dbo.T (ClusteredVal) WITH SAMPLE 2 PERCENT;
CREATE STATISTICS st_Scattered ON dbo.T (ScatteredVal) WITH SAMPLE 2 PERCENT;
GO
-- 3.2 Что гистограммы знают о «Rare» (реально по 300 строк в каждом столбце)
DBCC SHOW_STATISTICS (N'dbo.T', N'st_Clustered') WITH HISTOGRAM;   -- Rare часто нет вовсе или EQ_ROWS далеко от 300
DBCC SHOW_STATISTICS (N'dbo.T', N'st_Scattered') WITH HISTOGRAM;   -- Rare есть, EQ_ROWS близко к 300
GO
-- 3.3 Оценка против факта (фактический план, Ctrl+M): ClusteredVal — «лотерея», ScatteredVal — близко
SELECT COUNT(*) FROM dbo.T WITH (INDEX(0)) WHERE ClusteredVal = 'Rare' OPTION (RECOMPILE);
SELECT COUNT(*) FROM dbo.T WITH (INDEX(0)) WHERE ScatteredVal = 'Rare' OPTION (RECOMPILE);
GO
-- 3.4 Полное сканирование -> обе оценки точные (300)
UPDATE STATISTICS dbo.T st_Clustered WITH FULLSCAN;
UPDATE STATISTICS dbo.T st_Scattered WITH FULLSCAN;
DBCC SHOW_STATISTICS (N'dbo.T', N'st_Clustered') WITH HISTOGRAM;
GO
-- 3.5 Закрепить FULLSCAN для будущих автообновлений
UPDATE STATISTICS dbo.T st_Clustered WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;
SELECT s.name, sp.rows_sampled, sp.rows, sp.persisted_sample_percent
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.T');
GO

/* =====================================================================
   БЛОК 4. Статистика без данных: DBCC CLONEDATABASE (вопрос 29б)
   Клон содержит схему и статистику, но 0 строк. Предполагаемые планы — как на исходной базе.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'StatsSampleDemo_Clone') IS NOT NULL DROP DATABASE StatsSampleDemo_Clone;
DBCC CLONEDATABASE (StatsSampleDemo, StatsSampleDemo_Clone);   -- клон создаётся только для чтения
GO
USE StatsSampleDemo_Clone;
GO
SELECT COUNT(*) AS real_rows FROM dbo.T;                      -- 0 строк
-- Предполагаемый план (Ctrl+L): Estimated Number of Rows ≈ 1 000 000 и ≈ 300 — из статистики
SELECT COUNT(*) FROM dbo.T WHERE ScatteredVal = 'Rare';
GO

-- Уборка
-- USE master;
-- DROP DATABASE StatsSampleDemo_Clone;
-- ALTER DATABASE StatsSampleDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE StatsSampleDemo;
