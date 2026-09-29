/* =====================================================================
   Статистика в MS SQL Server: заголовок, вектор плотности, гистограмма
   ---------------------------------------------------------------------
   Выполнять ПО БЛОКАМ (выделить блок -> F5).
   В блоках 5–9 включите фактический план выполнения (Ctrl+M) и
   сравнивайте у операторов Estimated Number of Rows / Actual Number of Rows.
   Требуется SQL Server 2016 SP1 CU2+ (sys.dm_db_stats_histogram).
   ===================================================================== */


/* ---------- БЛОК 0. Учебная база ---------- */
USE master;
GO
IF DB_ID(N'StatsDemo') IS NOT NULL
BEGIN
    ALTER DATABASE StatsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE StatsDemo;
END
GO
CREATE DATABASE StatsDemo;
GO
ALTER DATABASE StatsDemo SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE StatsDemo SET AUTO_UPDATE_STATISTICS ON;
GO
USE StatsDemo;
GO


/* ---------- БЛОК 1. Таблица с НЕРАВНОМЕРНЫМИ данными (100 000 строк) ---------- */
CREATE TABLE dbo.Orders
(
    OrderID    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int           NOT NULL,
    Region     nvarchar(30)  NOT NULL,
    OrderDate  date          NOT NULL,
    Amount     decimal(12,2) NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_columns a CROSS JOIN sys.all_columns b
)
INSERT dbo.Orders (CustomerID, Region, OrderDate, Amount)
SELECT
    CASE WHEN n % 10 = 0 THEN 1 ELSE n % 5000 + 1 END,   -- клиент №1 «крупный»: ~10% заказов
    CASE WHEN n % 100 < 50 THEN N'Москва'                 -- 50%
         WHEN n % 100 < 75 THEN N'Санкт-Петербург'        -- 25%
         WHEN n % 100 < 90 THEN N'Казань'                 -- 15%
         WHEN n % 100 < 97 THEN N'Новосибирск'            --  7%
         ELSE                   N'Владивосток' END,       --  3%
    DATEADD(DAY, -(n % 730), '20260101'),
    (n * 37) % 10000 / 1.0
FROM n;
GO


/* ---------- БЛОК 2. Создаём статистики ---------- */
-- Статистика индекса создаётся АВТОМАТИЧЕСКИ вместе с индексом (по полному сканированию)
CREATE NONCLUSTERED INDEX IX_Orders_Region_Customer ON dbo.Orders (Region, CustomerID);

-- Статистика, созданная ВРУЧНУЮ (без индекса), по столбцу с большим числом значений
CREATE STATISTICS st_Orders_CustomerID ON dbo.Orders (CustomerID) WITH FULLSCAN;
GO

-- Список статистик таблицы
SELECT  s.stats_id,
        s.name          AS stats_name,
        s.auto_created,                 -- 1 = создана автоматически (_WA_Sys_...)
        s.user_created,                 -- 1 = CREATE STATISTICS
        CASE WHEN i.index_id IS NOT NULL THEN 1 ELSE 0 END AS is_index_stats,
        STUFF((SELECT N', ' + c.name
               FROM sys.stats_columns sc
               JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
               WHERE sc.object_id = s.object_id AND sc.stats_id = s.stats_id
               ORDER BY sc.stats_column_id
               FOR XML PATH('')), 1, 2, N'') AS stats_columns
FROM sys.stats s
LEFT JOIN sys.indexes i
       ON i.object_id = s.object_id AND i.index_id = s.stats_id AND i.name = s.name
WHERE s.object_id = OBJECT_ID(N'dbo.Orders')
ORDER BY s.stats_id;
GO


/* ---------- БЛОК 3. Три части статистики ---------- */
-- Всё сразу: 3 результирующих набора
DBCC SHOW_STATISTICS (N'dbo.Orders', N'IX_Orders_Region_Customer');

-- По отдельности
DBCC SHOW_STATISTICS (N'dbo.Orders', N'IX_Orders_Region_Customer') WITH STAT_HEADER;
DBCC SHOW_STATISTICS (N'dbo.Orders', N'IX_Orders_Region_Customer') WITH DENSITY_VECTOR;
    -- Ожидаем 3 строки: Region = 0,2 | Region,CustomerID | Region,CustomerID,OrderID = 1E-05
    -- OrderID попал сюда, т.к. ключ кластерного индекса неявно входит в некластерный
DBCC SHOW_STATISTICS (N'dbo.Orders', N'IX_Orders_Region_Customer') WITH HISTOGRAM;
    -- 5 шагов (по одному на регион), RANGE_ROWS = 0, EQ_ROWS = точное число строк.
    -- Гистограмма ТОЛЬКО по первому столбцу (Region), про CustomerID её нет!

-- Гистограмма статистики по CustomerID: здесь шаги «сжимают» ~4500 значений в <= 200 шагов
DBCC SHOW_STATISTICS (N'dbo.Orders', N'st_Orders_CustomerID') WITH HISTOGRAM;

-- Заголовок через DMV (современный способ) + счётчик изменений
SELECT  s.name, sp.last_updated, sp.rows, sp.rows_sampled, sp.steps,
        sp.unfiltered_rows, sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.Orders');
GO


/* ---------- БЛОК 4. Проверяем цифры статистики «руками» ---------- */
-- Плотность = 1 / число уникальных значений (для каждого префикса ключа)
SELECT
    1.0 / COUNT(DISTINCT Region)                                   AS [Density: Region],
    1.0 / (SELECT COUNT(*)
           FROM (SELECT DISTINCT Region, CustomerID FROM dbo.Orders) d) AS [Density: Region, CustomerID],
    1.0 / COUNT(*)                                                 AS [Density: + OrderID]
FROM dbo.Orders;

-- EQ_ROWS гистограммы должны совпасть с фактом
SELECT Region, COUNT(*) AS fact_rows
FROM dbo.Orders
GROUP BY Region
ORDER BY Region;
GO


/* ---------- БЛОК 5. Оценка ПО ГИСТОГРАММЕ (значение известно) ---------- */
-- OPTION (RECOMPILE) — чтобы каждый запрос компилировался заново, а не брал план из кэша
SELECT COUNT(*) FROM dbo.Orders WHERE Region = N'Москва'      OPTION (RECOMPILE); -- оценка ≈ 50 000 = EQ_ROWS
SELECT COUNT(*) FROM dbo.Orders WHERE Region = N'Владивосток' OPTION (RECOMPILE); -- оценка ≈  3 000 = EQ_ROWS
GO


/* ---------- БЛОК 6. Оценка ПО ПЛОТНОСТИ (значение неизвестно при компиляции) ---------- */
DECLARE @r nvarchar(30) = N'Москва',
        @c int          = 1;

-- Локальная переменная: оптимизатор не знает значение -> Rows * Density = 100 000 * 0,2 = 20 000
-- (факт 50 000 — плотность ничего не знает о перекосе)
SELECT COUNT(*) FROM dbo.Orders WHERE Region = @r;

-- То же самое, но с RECOMPILE: значение подставляется -> снова гистограмма -> 50 000
SELECT COUNT(*) FROM dbo.Orders WHERE Region = @r OPTION (RECOMPILE);

-- Два столбца индекса + неизвестные значения -> Rows * Density(Region, CustomerID)
SELECT COUNT(*) FROM dbo.Orders WHERE Region = @r AND CustomerID = @c;
GO


/* ---------- БЛОК 7. Гистограмма: граница шага (EQ_ROWS) vs внутри шага (AVG_RANGE_ROWS) ---------- */
DECLARE @stats_id int =
    (SELECT stats_id FROM sys.stats
     WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'st_Orders_CustomerID');

-- Первые шаги гистограммы по CustomerID
SELECT TOP (10)
       h.step_number,
       CAST(h.range_high_key AS int) AS range_high_key,
       h.range_rows, h.equal_rows, h.distinct_range_rows, h.average_range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(N'dbo.Orders'), @stats_id) h
ORDER BY h.step_number;

-- Берём значение ВНУТРИ шага (не границу), у которого точно есть строки
DECLARE @inside int, @avg float;
SELECT TOP (1)
       @inside = CAST(h.range_high_key AS int) - 1,
       @avg    = h.average_range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(N'dbo.Orders'), @stats_id) h
WHERE h.distinct_range_rows > 0
  AND (CAST(h.range_high_key AS int) - 2) % 10 <> 0
ORDER BY h.step_number;

SELECT @inside AS customer_inside_step, @avg AS expected_estimate_AVG_RANGE_ROWS;

-- Граница шага: клиент №1 -> оценка = EQ_ROWS (≈ 10 000+)
SELECT COUNT(*) FROM dbo.Orders WHERE CustomerID = 1       OPTION (RECOMPILE);
-- Внутри шага -> оценка = AVG_RANGE_ROWS
SELECT COUNT(*) FROM dbo.Orders WHERE CustomerID = @inside OPTION (RECOMPILE);
-- Диапазон -> сумма по шагам
SELECT COUNT(*) FROM dbo.Orders WHERE CustomerID BETWEEN 100 AND 300 OPTION (RECOMPILE);
GO


/* ---------- БЛОК 8. Автоматическое создание статистики (_WA_Sys_...) ---------- */
-- По Amount нет ни индекса, ни статистики -> SQL Server создаст её сам при компиляции
SELECT COUNT(*) FROM dbo.Orders WHERE Amount > 9500;

SELECT s.name, s.auto_created, sp.rows, sp.rows_sampled, sp.steps
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.Orders');
-- Обратите внимание: rows_sampled у автостатистики может быть меньше rows (выборка)
GO


/* ---------- БЛОК 9. Устаревшая статистика ---------- */
-- Для чистоты эксперимента отключаем автообновление
ALTER DATABASE StatsDemo SET AUTO_UPDATE_STATISTICS OFF;
GO

-- Добавляем 30 000 заказов НОВОГО региона
INSERT dbo.Orders (CustomerID, Region, OrderDate, Amount)
SELECT TOP (30000) CustomerID, N'Екатеринбург', OrderDate, Amount
FROM dbo.Orders;
GO

-- Заголовок: Rows старое, modification_counter вырос
SELECT s.name, sp.last_updated, sp.rows, sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.Orders');

-- Гистограмма не знает про «Екатеринбург» -> оценка ~1 строка, факт 30 000
SELECT COUNT(*) FROM dbo.Orders WHERE Region = N'Екатеринбург' OPTION (RECOMPILE);
GO

-- Пересчитываем статистику индекса
UPDATE STATISTICS dbo.Orders IX_Orders_Region_Customer WITH FULLSCAN;
GO

-- Теперь в гистограмме 6 шагов, оценка = 30 000
DBCC SHOW_STATISTICS (N'dbo.Orders', N'IX_Orders_Region_Customer') WITH STAT_HEADER, HISTOGRAM;
SELECT COUNT(*) FROM dbo.Orders WHERE Region = N'Екатеринбург' OPTION (RECOMPILE);
GO

ALTER DATABASE StatsDemo SET AUTO_UPDATE_STATISTICS ON;
GO


/* ---------- БЛОК 10. Модель итераторов (включите фактический план) ---------- */
USE StatsDemo;
GO
-- 10.1 «Вытягивание»: Top получил 10 строк и перестал просить.
--      У Clustered Index Scan Actual Number of Rows = 10, а не 100 000+.
SELECT TOP (10) * FROM dbo.Orders WHERE Region = N'Москва';

-- 10.2 Блокирующий оператор: чтобы найти 10 самых дорогих заказов,
--      Sort вынужден прочитать ВСЮ таблицу.
SELECT TOP (10) * FROM dbo.Orders ORDER BY Amount DESC;

-- 10.3 Nested Loops: Index Seek (верхний вход) выполняется один раз,
--      Key Lookup (нижний) — по разу на каждую строку (Number of Executions).
SELECT OrderID, Amount, OrderDate
FROM dbo.Orders
WHERE Region = N'Владивосток' AND CustomerID < 100
OPTION (RECOMPILE);
GO


/* ---------- БЛОК 11. Три числа строк и масштабирование оценки (вопрос 29а) ---------- */
USE StatsDemo;
GO
-- Чтобы автообновление не пересчитало статистику посреди опыта
ALTER DATABASE StatsDemo SET AUTO_UPDATE_STATISTICS OFF;
UPDATE STATISTICS dbo.Orders IX_Orders_Region_Customer WITH FULLSCAN;   -- чистая точка отсчёта
GO
-- 11.1 До: метаданные, статистика, счётчик изменений
SELECT SUM(row_count) AS rows_in_metadata
FROM sys.dm_db_partition_stats
WHERE object_id = OBJECT_ID(N'dbo.Orders') AND index_id IN (0, 1);

SELECT s.name, sp.last_updated, sp.rows, sp.rows_sampled, sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.Orders') AND s.name = N'IX_Orders_Region_Customer';
GO
-- 11.2 Добавляем +20% строк с тем же распределением регионов
;WITH n AS
(
    SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_columns a CROSS JOIN sys.all_columns b
)
INSERT dbo.Orders (CustomerID, Region, OrderDate, Amount)
SELECT n % 5000 + 1,
       CASE WHEN n % 100 < 50 THEN N'Москва'
            WHEN n % 100 < 75 THEN N'Санкт-Петербург'
            WHEN n % 100 < 90 THEN N'Казань'
            WHEN n % 100 < 97 THEN N'Новосибирск'
            ELSE                   N'Владивосток' END,
       '20260101', 100
FROM n;
GO
-- 11.3 После: метаданные выросли СРАЗУ, Rows статистики — нет, счётчик изменений +20 000
SELECT SUM(row_count) AS rows_in_metadata
FROM sys.dm_db_partition_stats
WHERE object_id = OBJECT_ID(N'dbo.Orders') AND index_id IN (0, 1);

SELECT s.name, sp.last_updated, sp.rows, sp.rows_sampled, sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(N'dbo.Orders') AND s.name = N'IX_Orders_Region_Customer';

EXEC sp_spaceused N'dbo.Orders';
GO
-- 11.4 Оценка масштабирована: EQ_ROWS(Москва) × rows_in_metadata / Rows статистики.
--      Сравните Estimated Number of Rows в плане (Ctrl+M) с этим расчётом и с Actual.
SELECT COUNT(*) FROM dbo.Orders WHERE Region = N'Москва' OPTION (RECOMPILE);
GO
-- 11.5 Вернуть автообновление
ALTER DATABASE StatsDemo SET AUTO_UPDATE_STATISTICS ON;
GO


/* ---------- БЛОК 12. Шаги гистограммы и составная статистика (вопросы 29, 30а) ---------- */
USE StatsDemo;
GO
UPDATE STATISTICS dbo.Orders st_Orders_CustomerID WITH FULLSCAN;
GO
-- 12.1 Какие статистики есть и какой столбец в каждой ведущий (stats_column_id = 1)
SELECT s.name, s.auto_created, s.user_created, c.name AS column_name, sc.stats_column_id
FROM sys.stats s
JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
JOIN sys.columns c        ON c.object_id = sc.object_id AND c.column_id = sc.column_id
WHERE s.object_id = OBJECT_ID(N'dbo.Orders')
ORDER BY s.name, sc.stats_column_id;
GO
-- 12.2 Шаги гистограммы по CustomerID (5 000 значений -> шаги объединяют много значений)
DECLARE @sid int = (SELECT stats_id FROM sys.stats
                    WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'st_Orders_CustomerID');
SELECT step_number, range_high_key, range_rows, equal_rows, distinct_range_rows, average_range_rows
FROM sys.dm_db_stats_histogram(OBJECT_ID(N'dbo.Orders'), @sid)
ORDER BY step_number;
GO
-- 12.3 Оценка на границе шага и внутри шага.
--      Берём первый «широкий» шаг, строим запросы с ЛИТЕРАЛАМИ (иначе сработает плотность).
--      Смотрите Estimated и Actual Number of Rows в фактическом плане (Ctrl+M).
DECLARE @sid int = (SELECT stats_id FROM sys.stats
                    WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'st_Orders_CustomerID');
DECLARE @hi int, @inside int, @lo int;
SELECT TOP (1) @hi = CAST(range_high_key AS int)
FROM sys.dm_db_stats_histogram(OBJECT_ID(N'dbo.Orders'), @sid)
WHERE distinct_range_rows > 2 AND step_number > 2
ORDER BY step_number;
SET @inside = @hi - 1;          -- внутри того же шага
SET @lo     = @hi - 2;
DECLARE @sql nvarchar(max) =
      N'SELECT COUNT(*) AS on_boundary FROM dbo.Orders WHERE CustomerID = ' + CAST(@hi AS nvarchar(10)) + N' OPTION (RECOMPILE);'   -- EQ_ROWS
    + N'SELECT COUNT(*) AS inside_step FROM dbo.Orders WHERE CustomerID = ' + CAST(@inside AS nvarchar(10)) + N' OPTION (RECOMPILE);' -- AVG_RANGE_ROWS
    + N'SELECT COUNT(*) AS part_of_step FROM dbo.Orders WHERE CustomerID BETWEEN ' + CAST(@lo AS nvarchar(10))
    + N' AND ' + CAST(@inside AS nvarchar(10)) + N' OPTION (RECOMPILE);'                                                             -- доля шага
    + N'SELECT COUNT(*) AS beyond_max FROM dbo.Orders WHERE CustomerID = 999999 OPTION (RECOMPILE);';                              -- вне гистограммы
PRINT @sql;
EXEC (@sql);
GO
-- 12.4 Второй столбец составного индекса: гистограмма берётся из ДРУГОЙ статистики.
--      В фактическом плане: SELECT -> Properties -> OptimizerStatsUsage (2016 SP2 / 2017+)
--      покажет, что для CustomerID использована st_Orders_CustomerID, а не IX_Orders_Region_Customer.
SELECT COUNT(*) FROM dbo.Orders WHERE Region = N'Москва' AND CustomerID = 1 OPTION (RECOMPILE);
GO


/* ---------- Уборка (раскомментировать при необходимости) ---------- */
-- USE master;
-- ALTER DATABASE StatsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE StatsDemo;
