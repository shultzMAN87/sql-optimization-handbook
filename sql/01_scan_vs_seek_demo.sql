/* =====================================================================
   Table Scan / Clustered Index Scan / Index Scan / Index Seek:
   когда что уместно и когда что плохо
   ---------------------------------------------------------------------
   Выполнять ПО БЛОКАМ. Перед запросами включите фактический план (Ctrl+M).
   В каждом операторе смотрите свойства (F4):
     - Actual Number of Rows      — сколько строк вернул оператор
     - Actual Rows Read           — сколько строк он прочитал
     - Seek Predicates / Predicate — что сузило чтение, а что проверялось потом
     - Number of Executions       — сколько раз оператор запускался
   На вкладке Messages — логические чтения (STATISTICS IO).
   ===================================================================== */


/* ---------- БЛОК 0. Учебная база и данные ---------- */
USE master;
GO
IF DB_ID(N'ScanSeekDemo') IS NOT NULL
BEGIN
    ALTER DATABASE ScanSeekDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ScanSeekDemo;
END
GO
CREATE DATABASE ScanSeekDemo;
GO
USE ScanSeekDemo;
GO

-- Основная таблица: кластерный индекс по OrderID.
-- Столбец Note — «балласт», чтобы таблица была широкой, а индексы — заметно уже неё.
CREATE TABLE dbo.Orders
(
    OrderID    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int           NOT NULL,
    Region     nvarchar(30)  NOT NULL,
    OrderDate  date          NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Note       nchar(50)     NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_columns a CROSS JOIN sys.all_columns b
)
INSERT dbo.Orders (CustomerID, Region, OrderDate, Amount, Note)
SELECT
    CASE WHEN n % 10 = 0 THEN 1 ELSE n % 5000 + 1 END,   -- клиент №1: 20 000 заказов, остальные ~40
    CASE WHEN n % 100 < 50 THEN N'Москва'
         WHEN n % 100 < 75 THEN N'Санкт-Петербург'
         WHEN n % 100 < 90 THEN N'Казань'
         WHEN n % 100 < 97 THEN N'Новосибирск'
         ELSE                   N'Владивосток' END,
    DATEADD(DAY, -(n % 1095), '20260101'),              -- 2023–2025 годы
    (n * 37) % 10000 / 1.0,
    N'...'
FROM n;
GO

-- Некластерные индексы (оба НЕ покрывают Amount и Note)
CREATE INDEX IX_Orders_Customer    ON dbo.Orders (CustomerID);
CREATE INDEX IX_Orders_Region_Date ON dbo.Orders (Region, OrderDate);
GO

-- Куча (heap): та же таблица, но БЕЗ кластерного индекса
SELECT OrderID, CustomerID, Region, OrderDate, Amount, Note
INTO dbo.OrdersHeap
FROM dbo.Orders;
CREATE INDEX IX_OrdersHeap_Customer ON dbo.OrdersHeap (CustomerID);
GO

-- Маленький справочник
CREATE TABLE dbo.Regions
(
    RegionID   int          NOT NULL CONSTRAINT PK_Regions PRIMARY KEY CLUSTERED,
    RegionName nvarchar(30) NOT NULL
);
INSERT dbo.Regions VALUES (1, N'Москва'), (2, N'Санкт-Петербург'), (3, N'Казань'),
                          (4, N'Новосибирск'), (5, N'Владивосток');
GO

SET STATISTICS IO ON;
GO


/* =====================================================================
   ЧАСТЬ 1. КОГДА СКАН — НОРМАЛЬНО
   ===================================================================== */

/* ---------- 1.1. Маленькая таблица ----------
   План: Clustered Index Scan по Regions.
   Таблица занимает 1 страницу — искать через индекс нет смысла,
   скан стоит столько же. Индекс по RegionName тут ничего не даст. */
SELECT RegionID FROM dbo.Regions WHERE RegionName = N'Казань';
GO

/* ---------- 1.2. Нужна большая доля строк ----------
   Москва — 50% таблицы. План: Clustered Index Scan.
   Seek по IX_Orders_Region_Date + 100 000 Key Lookup был бы в разы дороже. */
SELECT OrderID, Amount FROM dbo.Orders WHERE Region = N'Москва' OPTION (RECOMPILE);
GO

/* ---------- 1.3. Агрегат по всей таблице: скан самого УЗКОГО индекса ----------
   План: Index Scan по IX_Orders_Customer (int + ключ кластера),
   а НЕ Clustered Index Scan. Строк столько же, страниц — в разы меньше.
   Сравните logical reads с запросом ниже, где скан кластерного индекса неизбежен. */
SELECT COUNT(*) FROM dbo.Orders;
SELECT SUM(Amount) FROM dbo.Orders;   -- Amount есть только в кластерном индексе
GO

/* ---------- 1.4. Скан + TOP: прочитано совсем немного ----------
   План: Top <- Clustered Index Scan.
   У скана Actual Number of Rows = 10 и Actual Rows Read ≈ 10:
   Top получил свои 10 строк и перестал запрашивать следующие. */
SELECT TOP (10) * FROM dbo.Orders WHERE Amount > 100;
GO

/* ---------- 1.5. Упорядоченный скан вместо сортировки ----------
   Первый запрос: Top <- Clustered Index Scan (Ordered = True), Sort нет,
   прочитано 100 строк.
   Второй: Top N Sort <- Clustered Index Scan — чтобы найти 100 самых
   дорогих заказов, нужно прочитать ВСЕ 200 000 строк (блокирующий оператор). */
SELECT TOP (100) OrderID, Amount FROM dbo.Orders ORDER BY OrderID;
SELECT TOP (100) OrderID, Amount FROM dbo.Orders ORDER BY Amount DESC;
GO


/* =====================================================================
   ЧАСТЬ 2. ТОЧКА ПЕРЕЛОМА (TIPPING POINT): ОДИН ЗАПРОС — РАЗНЫЕ ПЛАНЫ
   ===================================================================== */

/* ---------- 2.1. Мало строк -> Seek + Key Lookup ----------
   Клиент 42: ~40 заказов.
   План: Nested Loops <- Index Seek (IX_Orders_Customer) + Key Lookup.
   У Key Lookup Number of Executions = 40. */
SELECT OrderID, Amount FROM dbo.Orders WHERE CustomerID = 42 OPTION (RECOMPILE);
GO

/* ---------- 2.2. Много строк -> Clustered Index Scan ----------
   Клиент 1: 20 000 заказов (10% таблицы).
   Тот же текст запроса, но план — скан: 20 000 Lookup дороже. */
SELECT OrderID, Amount FROM dbo.Orders WHERE CustomerID = 1 OPTION (RECOMPILE);
GO

/* ---------- 2.3. «Хороший» Seek, который на самом деле плохой ----------
   Заставляем использовать индекс для клиента 1.
   План: Index Seek + Key Lookup с Number of Executions = 20 000.
   Сравните logical reads с 2.2 — Seek проиграет скану в разы. */
SELECT OrderID, Amount
FROM dbo.Orders WITH (INDEX (IX_Orders_Customer))
WHERE CustomerID = 1
OPTION (RECOMPILE);
GO


/* =====================================================================
   ЧАСТЬ 3. КОГДА СКАН — СИМПТОМ ПРОБЛЕМЫ
   ===================================================================== */

/* ---------- 3.1. Функция над столбцом (non-SARGable) ----------
   Все запросы выбирают только столбцы индекса IX_Orders_Region_Date
   (OrderID входит в него неявно как ключ кластера) — индекс покрывающий.

   а) YEAR(OrderDate): Index Seek только по Region,
      YEAR(...) = 2025 — в Predicate (остаточный предикат).
      Actual Rows Read ≈ 30 000 (вся Казань), Actual Rows ≈ 10 000.
   б) Диапазон дат: Seek Predicates содержит И Region, И OrderDate.
      Actual Rows Read ≈ Actual Rows ≈ 10 000. */
SELECT OrderID, OrderDate FROM dbo.Orders
WHERE Region = N'Казань' AND YEAR(OrderDate) = 2025;                              -- а)

SELECT OrderID, OrderDate FROM dbo.Orders
WHERE Region = N'Казань' AND OrderDate >= '20250101' AND OrderDate < '20260101';  -- б)
GO

/* ---------- 3.2. Условие только по ВТОРОМУ столбцу индекса ----------
   Индекс (Region, OrderDate) отсортирован сначала по Region —
   искать по одной дате в нём нельзя.
   План: Index Scan по IX_Orders_Region_Date (узкий, покрывающий),
   условие на дату — в Predicate. Прочитано 200 000, возвращено ~5 500. */
SELECT OrderID, OrderDate FROM dbo.Orders
WHERE OrderDate >= '20250101' AND OrderDate < '20250201';
GO

/* ---------- 3.3. LIKE с % в начале ----------
   а) 'Каз%' — известно начало строки -> Index Seek по диапазону.
   б) '%зань' — начало неизвестно -> Index Scan всего индекса. */
SELECT OrderID FROM dbo.Orders WHERE Region LIKE N'Каз%';    -- а)
SELECT OrderID FROM dbo.Orders WHERE Region LIKE N'%зань';   -- б)
GO

/* ---------- 3.4. Seek, который читает ВСЁ ----------
   Формально условие по ведущему столбцу, в плане может быть «Index Seek»,
   но диапазон — весь индекс: Actual Rows Read = 200 000.
   Название оператора не гарантирует эффективности. */
SELECT OrderID FROM dbo.Orders WHERE Region >= N'';
GO

/* ---------- 3.5. Table Scan по куче и RID Lookup ----------
   а) Нет индекса по Amount -> Table Scan всей кучи.
   б) Поиск по индексу на куче: Index Seek + RID Lookup
      (на куче нет ключа кластера, строка ищется по физическому адресу RID). */
SELECT OrderID, Amount FROM dbo.OrdersHeap WHERE Amount > 9990;                     -- а)
SELECT OrderID, Amount FROM dbo.OrdersHeap WHERE CustomerID = 42 OPTION (RECOMPILE); -- б)
GO


/* =====================================================================
   ЧАСТЬ 4. ИСПРАВЛЕНИЕ: ПОКРЫВАЮЩИЙ ИНДЕКС
   ===================================================================== */

/* До: клиент 1 -> Clustered Index Scan (блок 2.2).
   Добавляем Amount в индекс как включённый столбец. */
CREATE INDEX IX_Orders_Customer
ON dbo.Orders (CustomerID) INCLUDE (Amount)
WITH (DROP_EXISTING = ON);
GO

/* После: для ОБОИХ клиентов — только Index Seek, без Key Lookup.
   20 000 строк читаются подряд из узкого индекса — точка перелома исчезла. */
SELECT OrderID, Amount FROM dbo.Orders WHERE CustomerID = 42 OPTION (RECOMPILE);
SELECT OrderID, Amount FROM dbo.Orders WHERE CustomerID = 1  OPTION (RECOMPILE);
GO


/* =====================================================================
   ЧАСТЬ 5. СКАН КАК ОСНОВНОЙ РЕЖИМ: COLUMNSTORE
   ===================================================================== */

/* Копия таблицы с кластерным колоночным индексом */
SELECT OrderID, CustomerID, Region, OrderDate, Amount, Note
INTO dbo.OrdersCS
FROM dbo.Orders;
CREATE CLUSTERED COLUMNSTORE INDEX CCI_OrdersCS ON dbo.OrdersCS;
GO

/* Аналитический запрос по всей таблице.
   Rowstore: Clustered Index Scan + Hash/Stream Aggregate.
   Columnstore: Columnstore Index Scan в режиме Batch (Actual Execution Mode = Batch),
   читаются только столбцы Region и Amount, в сжатом виде.
   Сравните logical reads (у columnstore — lob logical reads) и время. */
SELECT Region, SUM(Amount) FROM dbo.Orders   GROUP BY Region;
SELECT Region, SUM(Amount) FROM dbo.OrdersCS GROUP BY Region;
GO

SET STATISTICS IO OFF;
GO


/* ---------- Уборка (раскомментировать при необходимости) ---------- */
-- USE master;
-- ALTER DATABASE ScanSeekDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE ScanSeekDemo;
