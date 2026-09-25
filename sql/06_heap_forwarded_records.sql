/* =====================================================================
   Куча (heap): RID, forwarded records и RID Lookup
   Вопросы 2, 9 методички. Выполнять по блокам на тестовом экземпляре.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'HeapDemo') IS NOT NULL
BEGIN
    ALTER DATABASE HeapDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HeapDemo;
END;
GO
CREATE DATABASE HeapDemo;
GO
USE HeapDemo;
GO

/* ---------- 1. Куча с короткими строками переменной длины ---------- */
CREATE TABLE dbo.HeapT
(
    ID      int          NOT NULL,
    Payload varchar(4000) NOT NULL
);   -- кластерного индекса нет -> это куча

INSERT dbo.HeapT (ID, Payload)
SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'x'
FROM sys.all_columns a CROSS JOIN sys.all_columns b;

CREATE INDEX IX_HeapT_ID ON dbo.HeapT (ID);   -- в листьях: ключ + RID
GO

/* ---------- 2. Физический адрес строки (RID = файл:страница:слот) ---------- */
SELECT TOP (5) ID, sys.fn_PhysLocFormatter(%%physloc%%) AS RID   -- недокументировано
FROM dbo.HeapT;
GO

/* ---------- 3. До: forwarded_record_count = 0 ---------- */
SELECT index_type_desc, page_count, avg_page_space_used_in_percent, forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapT'), 0, NULL, 'DETAILED');
GO

/* ---------- 4. Удлиняем строки: они не помещаются на своей странице и переезжают ---------- */
UPDATE dbo.HeapT SET Payload = REPLICATE('y', 1000) WHERE ID % 3 = 0;
GO

/* ---------- 5. После: forwarded_record_count > 0, страниц стало больше ---------- */
SELECT index_type_desc, page_count, avg_page_space_used_in_percent, forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapT'), 0, NULL, 'DETAILED');
GO

/* ---------- 6. Цена: сравните logical reads скана и счётчик forwarded fetches ---------- */
SET STATISTICS IO ON;
SELECT COUNT(*), MAX(LEN(Payload)) FROM dbo.HeapT;             -- Table Scan ходит по указателям
SELECT ID, Payload FROM dbo.HeapT WHERE ID BETWEEN 1 AND 3000   -- Index Seek + RID Lookup
OPTION (RECOMPILE);
SET STATISTICS IO OFF;

SELECT forwarded_fetch_count
FROM sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID(N'dbo.HeapT'), 0, NULL);
GO

/* ---------- 7. Лечение: перестроить кучу (перестроятся и все НК-индексы!) ---------- */
ALTER TABLE dbo.HeapT REBUILD;
SELECT index_type_desc, page_count, forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapT'), 0, NULL, 'DETAILED');
GO

/* ---------- 8. Радикальное лечение: кластерный индекс (RID Lookup -> Key Lookup) ---------- */
CREATE CLUSTERED INDEX CIX_HeapT_ID ON dbo.HeapT (ID);
GO
SELECT ID, Payload FROM dbo.HeapT WHERE ID BETWEEN 1 AND 30 OPTION (RECOMPILE); -- смотрите план
GO

-- Уборка
-- USE master; ALTER DATABASE HeapDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE HeapDemo;
