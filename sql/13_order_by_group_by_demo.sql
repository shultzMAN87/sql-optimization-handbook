/* =====================================================================
   ORDER BY и GROUP BY: Sort, Top N Sort, Stream / Hash Aggregate
   и когда B-tree индекс делает их ненужными.
   Вопрос 50а методички. Тестовый экземпляр, SQL Server 2016+.
   Выполнять ПО БЛОКАМ с фактическим планом (Ctrl+M). Смотреть:
     - есть ли оператор Sort / Top N Sort / Hash Match (Aggregate);
     - у оператора чтения: Ordered = True/False, Scan Direction;
     - у SELECT: MemoryGrantInfo (у запросов с Sort/Hash);
     - Messages: logical reads.
   Планы описаны «как обычно бывает»: на вашем железе выбор может отличаться.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'SortAggDemo') IS NOT NULL
BEGIN
    ALTER DATABASE SortAggDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SortAggDemo;
END;
GO
CREATE DATABASE SortAggDemo;
GO
USE SortAggDemo;
GO

/* ---------- 0. Данные: 200 000 продаж, «широкая» строка ---------- */
CREATE TABLE dbo.Sales
(
    SaleID     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Sales PRIMARY KEY CLUSTERED,
    Region     nvarchar(30)  NOT NULL,
    CustomerID int           NOT NULL,
    SaleDate   date          NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Note       nchar(100)    NOT NULL      -- балласт: Key Lookup и полное чтение дороги
);
GO
;WITH n AS
(
    SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_columns a CROSS JOIN sys.all_columns b
)
INSERT dbo.Sales (Region, CustomerID, SaleDate, Amount, Note)
SELECT CASE WHEN n % 100 < 50 THEN N'Москва'
            WHEN n % 100 < 75 THEN N'Санкт-Петербург'
            WHEN n % 100 < 90 THEN N'Казань'
            WHEN n % 100 < 97 THEN N'Пермь'
            ELSE                   N'Владивосток' END,
       n % 5000 + 1,
       DATEADD(DAY, -(n % 1095), '20260101'),
       (n * 37) % 10000 / 1.0,
       N'...'
FROM n;
GO
CREATE INDEX IX_Sales_Region_Customer ON dbo.Sales (Region, CustomerID);
-- В листьях индекса: Region, CustomerID + SaleID (ключ кластера).
-- Индекс неуникальный, поэтому фактически отсортирован по (Region, CustomerID, SaleID).
UPDATE STATISTICS dbo.Sales WITH FULLSCAN;
GO
SET STATISTICS IO ON;
GO


/* =====================================================================
   ЧАСТЬ 1. ORDER BY
   ===================================================================== */

/* 1.1 Порядок совпадает с ключом индекса, индекс покрывает запрос.
       План: Index Scan (IX_Sales_Region_Customer), Ordered = True, Sort НЕТ. */
SELECT Region, CustomerID FROM dbo.Sales ORDER BY Region, CustomerID;
GO

/* 1.2 Другой порядок столбцов -> Sort (блокирующий, с memory grant). */
SELECT Region, CustomerID FROM dbo.Sales ORDER BY CustomerID, Region;
GO

/* 1.3 Все направления инвертированы -> обратное сканирование, Sort НЕТ.
       Scan Direction = BACKWARD (обратный скан не распараллеливается). */
SELECT Region, CustomerID FROM dbo.Sales ORDER BY Region DESC, CustomerID DESC;
GO

/* 1.4 Направления смешаны и не совпадают с индексом -> Sort.
       Помог бы индекс (Region ASC, CustomerID DESC). */
SELECT Region, CustomerID FROM dbo.Sales ORDER BY Region ASC, CustomerID DESC;
GO

/* 1.5 Равенство на ведущем столбце «фиксирует» его:
       Index Seek (Region = Казань), строки уже идут по CustomerID -> Sort НЕТ. */
SELECT Region, CustomerID FROM dbo.Sales WHERE Region = N'Казань' ORDER BY CustomerID;
GO

/* 1.6 IN / диапазон по ведущему столбцу: два отрезка индекса, каждый отсортирован
       по CustomerID, но вместе — нет -> Seek + Sort. */
SELECT Region, CustomerID FROM dbo.Sales
WHERE Region IN (N'Казань', N'Пермь') ORDER BY CustomerID;
GO

/* 1.7 Ключ кластера «хвостом» входит в неуникальный индекс -> Sort НЕТ. */
SELECT Region, CustomerID, SaleID FROM dbo.Sales ORDER BY Region, CustomerID, SaleID;
GO

/* 1.8 Индекс НЕ покрывает запрос, строк много:
       200 000 Key Lookup дороже, чем Clustered Index Scan + Sort.
       Смотрите у SELECT: MemoryGrantInfo (GrantedMemory, MaxUsedMemory). */
SELECT * FROM dbo.Sales ORDER BY Region, CustomerID;
GO

/* 1.9 Тот же порядок, но TOP (20): «цель по строкам» (row goal).
       План: Top <- Nested Loops <- Index Scan (Ordered) + 20 Key Lookup. Sort НЕТ.
       Так работают динамические списки 1С (SELECT TOP N ... ORDER BY). */
SELECT TOP (20) * FROM dbo.Sales ORDER BY Region, CustomerID;
GO

/* 1.10 Top N Sort: чтобы найти 10 самых дорогих продаж, нужно прочитать всё,
        но в памяти держатся только 10 строк. */
SELECT TOP (10) SaleID, Amount FROM dbo.Sales ORDER BY Amount DESC;
GO
CREATE INDEX IX_Sales_Amount ON dbo.Sales (Amount);
GO
-- После индекса: Top <- Index Scan BACKWARD, прочитано ~10 строк.
SELECT TOP (10) SaleID, Amount FROM dbo.Sales ORDER BY Amount DESC;
GO

/* 1.11 Сортировка по выражению от столбца -> Top N Sort по всей таблице:
        порядок YEAR(SaleDate) индекс не хранит (помог бы вычисляемый столбец + индекс). */
SELECT TOP (10) SaleID, SaleDate FROM dbo.Sales ORDER BY YEAR(SaleDate) DESC, SaleID;
GO


/* =====================================================================
   ЧАСТЬ 2. АГРЕГАЦИЯ
   ===================================================================== */

/* 2.1 Скалярный агрегат: Stream Aggregate поверх САМОГО УЗКОГО индекса
       (IX_Sales_Amount или IX_Sales_Region_Customer, а не кластерного). */
SELECT COUNT(*) FROM dbo.Sales;
GO

/* 2.2 MIN/MAX по индексированному столбцу: Top(1) по индексу, 2–3 чтения.
       По неиндексированному SaleDate — скан всей таблицы + Stream Aggregate. */
SELECT MAX(Amount)   FROM dbo.Sales;   -- Index Scan (Backward) + Top 1
SELECT MAX(SaleDate) FROM dbo.Sales;   -- полный скан
GO

/* 2.3 GROUP BY по ведущему столбцу индекса: Stream Aggregate без Sort. */
SELECT Region, COUNT(*) AS Cnt FROM dbo.Sales GROUP BY Region;
GO

/* 2.4 Порядок столбцов в GROUP BY НЕ важен (в отличие от ORDER BY):
       группы (CustomerID, Region) = группы (Region, CustomerID) -> тот же индекс, Stream. */
SELECT CustomerID, Region, COUNT(*) AS Cnt FROM dbo.Sales GROUP BY CustomerID, Region;
GO

/* 2.5 Индекса по SaleDate нет, групп ~1 100: Hash Match (Aggregate).
       Для сравнения — принудительно Sort + Stream Aggregate.            */
SELECT SaleDate, COUNT(*) AS Cnt FROM dbo.Sales GROUP BY SaleDate;
SELECT SaleDate, COUNT(*) AS Cnt FROM dbo.Sales GROUP BY SaleDate OPTION (ORDER GROUP);
GO

/* 2.6 GROUP BY + ORDER BY по тому же столбцу:
       после Hash Aggregate нужен Sort (но сортируются уже ~1 100 групп, а не 200 000 строк);
       после Stream Aggregate порядок уже есть. */
SELECT SaleDate, COUNT(*) AS Cnt FROM dbo.Sales GROUP BY SaleDate ORDER BY SaleDate;
SELECT Region,   COUNT(*) AS Cnt FROM dbo.Sales GROUP BY Region   ORDER BY Region;
GO

/* 2.7 Агрегируемого столбца нет в индексе группировки:
       IX_Sales_Region_Customer не содержит Amount -> обычно Clustered Index Scan + Hash Aggregate.
       Покрывающий индекс -> Stream Aggregate по узкому индексу, без хеша и сортировки. */
SELECT Region, SUM(Amount) AS Total FROM dbo.Sales GROUP BY Region;
GO
CREATE INDEX IX_Sales_Region_Amount ON dbo.Sales (Region) INCLUDE (Amount);
GO
SELECT Region, SUM(Amount) AS Total FROM dbo.Sales GROUP BY Region;
GO

/* 2.8 Агрегат с фильтром: WHERE по ведущему столбцу + MAX по второму -> Seek + Top 1. */
SELECT MAX(CustomerID) FROM dbo.Sales WHERE Region = N'Казань';
GO

/* 2.9 DISTINCT — это группировка без агрегатов.
       По индексу: Stream Aggregate. С TOP без индекса: Hash Match (Flow Distinct) —
       потоковый вариант, отдаёт новое значение сразу, как только его встретил. */
SELECT DISTINCT Region FROM dbo.Sales;
SELECT DISTINCT TOP (5) SaleDate FROM dbo.Sales;
GO

/* 2.10 Параллельная агрегация (если сервер разрешает параллелизм):
        Partial (local) Aggregate в каждом потоке -> Repartition/Gather -> Global Aggregate. */
SELECT CustomerID, SUM(Amount) FROM dbo.Sales GROUP BY CustomerID
OPTION (USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE'));   -- только для эксперимента
GO

SET STATISTICS IO OFF;
GO

-- Уборка
-- USE master; ALTER DATABASE SortAggDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE SortAggDemo;
