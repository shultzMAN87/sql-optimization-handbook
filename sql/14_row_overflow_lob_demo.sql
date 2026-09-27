/* =====================================================================
   IN_ROW_DATA, ROW_OVERFLOW_DATA, LOB_DATA: куда уезжают большие значения
   Вопросы 1, 1а методички. Тестовый экземпляр, SQL Server 2016+.
   Выполнять ПО БЛОКАМ, смотреть результаты dbo.ShowAlloc и вкладку Messages.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'LobDemo') IS NOT NULL
BEGIN
    ALTER DATABASE LobDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LobDemo;
END;
GO
CREATE DATABASE LobDemo;
GO
USE LobDemo;
GO

/* ---------- Помощник: сколько СТРОК и страниц в каждой единице распределения ---------- */
CREATE OR ALTER PROCEDURE dbo.ShowAlloc @table sysname
AS
SELECT alloc_unit_type_desc,               -- IN_ROW_DATA / ROW_OVERFLOW_DATA / LOB_DATA
       page_count,
       record_count,                       -- сколько значений реально лежит в этой единице
       avg_record_size_in_bytes
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@table), NULL, NULL, 'DETAILED')
WHERE index_level = 0
ORDER BY alloc_unit_type_desc;
GO


/* =====================================================================
   БЛОК 1. ROW_OVERFLOW: «много средних колонок не влезли вместе»
   ===================================================================== */
CREATE TABLE dbo.RO
(
    ID int NOT NULL PRIMARY KEY,
    A  varchar(5000) NOT NULL,
    B  varchar(5000) NOT NULL
);
GO
-- 1.1 4 000 + 3 000 байт: строка помещается в 8 060 -> только IN_ROW_DATA
INSERT dbo.RO VALUES (1, REPLICATE('a', 4000), REPLICATE('b', 3000));
EXEC dbo.ShowAlloc N'dbo.RO';
GO
-- 1.2 5 000 + 5 000 байт: не помещается -> одна колонка ЦЕЛИКОМ уезжает в ROW_OVERFLOW_DATA
INSERT dbo.RO VALUES (2, REPLICATE('a', 5000), REPLICATE('b', 5000));
EXEC dbo.ShowAlloc N'dbo.RO';   -- ROW_OVERFLOW_DATA: record_count = 1, avg ≈ 5 000 байт
GO
-- 1.3 Цена: вынесенные колонки читаются отдельно (lob logical reads)
SET STATISTICS IO ON;
SELECT ID FROM dbo.RO;             -- lob logical reads = 0: вынесенное не трогаем
SELECT ID, A, B FROM dbo.RO;       -- lob logical reads > 0: переход по указателю
SET STATISTICS IO OFF;
GO
-- 1.4 Строка уменьшилась -> значение возвращается в строку
UPDATE dbo.RO SET A = 'a' WHERE ID = 2;
EXEC dbo.ShowAlloc N'dbo.RO';      -- record_count в ROW_OVERFLOW_DATA снова 0
GO


/* =====================================================================
   БЛОК 2. LOB: (max) лежит в строке, пока помещается
   ===================================================================== */
CREATE TABLE dbo.L
(
    ID int NOT NULL PRIMARY KEY,
    M  varchar(max) NULL
);
GO
-- 2.1 Короткое значение (max)-типа: в строке, LOB пуст
INSERT dbo.L VALUES (1, REPLICATE('x', 100));
EXEC dbo.ShowAlloc N'dbo.L';
GO
-- 2.2 20 000 байт: больше 8 000 -> LOB_DATA (не ROW_OVERFLOW!)
--     REPLICATE обрезает результат до 8 000 байт, если вход не (max) — отсюда CAST.
INSERT dbo.L VALUES (2, REPLICATE(CAST('x' AS varchar(max)), 20000));
EXEC dbo.ShowAlloc N'dbo.L';
GO
-- 2.3 Опция: все (max)-значения вне строки. Существующие переезжают только при UPDATE.
EXEC sp_tableoption N'dbo.L', 'large value types out of row', 1;
UPDATE dbo.L SET M = M WHERE ID = 1;
EXEC dbo.ShowAlloc N'dbo.L';       -- короткое значение тоже в LOB_DATA, строка IN_ROW стала узкой
EXEC sp_tableoption N'dbo.L', 'large value types out of row', 0;
GO


/* =====================================================================
   БЛОК 3. Значение 1 МБ: дерево LOB-страниц
   ===================================================================== */
CREATE TABLE dbo.Big
(
    ID int NOT NULL PRIMARY KEY,
    M  varchar(max) NOT NULL
);
GO
INSERT dbo.Big VALUES (1, REPLICATE(CAST('x' AS varchar(max)), 1048576));
EXEC dbo.ShowAlloc N'dbo.Big';     -- LOB_DATA: ~130+ страниц
GO
-- 3.1 Типы страниц (НЕДОКУМЕНТИРОВАННАЯ функция, SQL Server 2012+, только для изучения):
--     данные LOB и узлы дерева (TEXT_TREE_PAGE)
SELECT allocation_unit_type_desc, page_type_desc, COUNT(*) AS pages
FROM sys.dm_db_database_page_allocations(DB_ID(), OBJECT_ID(N'dbo.Big'), NULL, NULL, 'DETAILED')
WHERE is_allocated = 1
GROUP BY allocation_unit_type_desc, page_type_desc
ORDER BY allocation_unit_type_desc, page_type_desc;
GO
-- 3.2 Чтение из середины: путь «корень -> узел -> лист», единицы lob logical reads.
--     Полное чтение: все ~130 страниц.
SET STATISTICS IO ON;
SELECT SUBSTRING(M, 600000, 100) FROM dbo.Big WHERE ID = 1;
DECLARE @v varchar(max);
SELECT @v = M FROM dbo.Big WHERE ID = 1;
SET STATISTICS IO OFF;
GO
-- 3.3 Частичное обновление без перезаписи всего значения
UPDATE dbo.Big SET M.WRITE('HELLO', 600000, 5) WHERE ID = 1;
SELECT SUBSTRING(M, 599999, 10) FROM dbo.Big WHERE ID = 1;
GO


/* =====================================================================
   БЛОК 4. Проверка: КАКАЯ колонка уедет и КУДА
   Таблица (ID, A nvarchar(4000), B nvarchar(max)): A = 7 000 байт, B = 3 000 байт.
   Документированное правило: выносится самая широкая колонка переменной длины.
   Смотрите, где появилась запись: в ROW_OVERFLOW_DATA (уехала A) или в LOB_DATA (уехала B).
   ===================================================================== */
CREATE TABLE dbo.Mix1 (ID int PRIMARY KEY, A nvarchar(4000) NOT NULL, B nvarchar(max) NOT NULL);
INSERT dbo.Mix1 VALUES (1, REPLICATE(N'a', 3500), REPLICATE(CAST(N'b' AS nvarchar(max)), 1500));
EXEC dbo.ShowAlloc N'dbo.Mix1';
GO
-- Вариант: обе колонки ограниченной длины -> вынос только в ROW_OVERFLOW
CREATE TABLE dbo.Mix2 (ID int PRIMARY KEY, A nvarchar(4000) NOT NULL, B nvarchar(2000) NOT NULL);
INSERT dbo.Mix2 VALUES (1, REPLICATE(N'a', 3500), REPLICATE(N'b', 1500));
EXEC dbo.ShowAlloc N'dbo.Mix2';    -- какая из двух: смотрите avg_record_size_in_bytes (~7 000 или ~3 000)
GO


/* =====================================================================
   БЛОК 5. Обзор по всей базе: где есть overflow и LOB
   ===================================================================== */
SELECT OBJECT_SCHEMA_NAME(ps.object_id) + N'.' + OBJECT_NAME(ps.object_id) AS table_name,
       ps.index_id,
       SUM(ps.in_row_data_page_count)       AS in_row_pages,
       SUM(ps.row_overflow_used_page_count) AS row_overflow_pages,
       SUM(ps.lob_used_page_count)          AS lob_pages
FROM sys.dm_db_partition_stats ps
WHERE OBJECTPROPERTY(ps.object_id, 'IsUserTable') = 1
GROUP BY ps.object_id, ps.index_id
ORDER BY row_overflow_pages DESC, lob_pages DESC;
GO

-- Уборка
-- USE master; ALTER DATABASE LobDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE LobDemo;
