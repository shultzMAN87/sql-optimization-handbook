/* =====================================================================
   Отрицания (<>, NOT IN, NOT LIKE) и фильтрованный индекс
   Вопрос 26 методички. Тестовый экземпляр, SQL Server 2016+.
   Выполнять ПО БЛОКАМ с фактическим планом (Ctrl+M) и STATISTICS IO.
   Смотреть: Seek или Scan; у Index Seek — сколько диапазонов в Seek Predicates.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'NegationDemo') IS NOT NULL
BEGIN
    ALTER DATABASE NegationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE NegationDemo;
END;
GO
CREATE DATABASE NegationDemo;
GO
USE NegationDemo;
GO

/* ---------- 0. Заявки: 99% закрыты (Status = 1), остальные 2, 3, 4 ---------- */
CREATE TABLE dbo.Tickets
(
    TicketID   int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Tickets PRIMARY KEY CLUSTERED,
    Status     tinyint      NOT NULL,          -- 1 Закрыта, 2 Новая, 3 В работе, 4 Ожидание
    CustomerID int          NOT NULL,
    Subject    varchar(50)  NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Note       char(200)    NOT NULL           -- балласт: Key Lookup и скан дороги
);
GO
;WITH n AS
(
    SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_columns a CROSS JOIN sys.all_columns b
)
INSERT dbo.Tickets (Status, CustomerID, Subject, Amount, Note)
SELECT CASE WHEN n % 100 <> 0 THEN 1           -- 99%
            ELSE 2 + n % 3 END,                -- 1% делится между 2, 3, 4
       n % 5000 + 1,
       CASE n % 4 WHEN 0 THEN 'Ошибка входа' WHEN 1 THEN 'Отчёт' WHEN 2 THEN 'Абонемент' ELSE 'Прочее' END,
       n % 1000,
       'x'
FROM n;
GO
CREATE INDEX IX_Tickets_Status  ON dbo.Tickets (Status);
CREATE INDEX IX_Tickets_Subject ON dbo.Tickets (Subject);
UPDATE STATISTICS dbo.Tickets WITH FULLSCAN;
GO
SET STATISTICS IO ON;
GO

/* ---------- 1. <> , которое исключает почти всё -> мало строк -> Seek по ДВУМ диапазонам ---------- */
-- Seek Predicates: Status < 1 и Status > 1; дальше Key Lookup на ~2 000 строк.
SELECT TicketID, CustomerID, Amount FROM dbo.Tickets WHERE Status <> 1;
GO

/* ---------- 2. <> , которое выбирает почти всё (99%+) -> Clustered Index Scan ---------- */
SELECT TicketID, CustomerID, Amount FROM dbo.Tickets WHERE Status <> 2;
GO

/* ---------- 3. NOT IN (2, 3) -> несколько диапазонов, но строк ~99% -> Scan ---------- */
SELECT TicketID, CustomerID, Amount FROM dbo.Tickets WHERE Status NOT IN (2, 3);
-- Сравните: NOT IN (1) выбирает 1% -> Seek по диапазонам
SELECT TicketID, CustomerID, Amount FROM dbo.Tickets WHERE Status NOT IN (1);
GO

/* ---------- 4. NOT LIKE -> условие в Predicate, скан (индекс по Subject не ищет) ---------- */
SELECT TicketID, Subject FROM dbo.Tickets WHERE Subject NOT LIKE 'Отч%';
-- Для сравнения: LIKE 'Отч%' -> Seek по диапазону
SELECT TicketID, Subject FROM dbo.Tickets WHERE Subject LIKE 'Отч%';
GO

/* ---------- 5. Отрицание, переписанное перечислением: те же строки, несколько коротких Seek ---------- */
SELECT TicketID, CustomerID, Amount FROM dbo.Tickets WHERE Status IN (2, 3, 4);
GO

/* ---------- 6. Фильтрованный индекс под «активные» заявки ---------- */
CREATE INDEX IX_Tickets_Open
ON dbo.Tickets (CustomerID)
INCLUDE (Amount, Status)
WHERE Status <> 1;
GO
-- 6.1 Литерал совпадает с фильтром -> Seek по маленькому индексу, без Key Lookup
SELECT TicketID, Amount FROM dbo.Tickets WHERE Status <> 1 AND CustomerID = 100;
GO
-- 6.2 Переменная: оптимизатор не может гарантировать @s = 1 -> индекс НЕ используется,
--     на SELECT предупреждение UnmatchedIndexes
DECLARE @s tinyint = 1;
SELECT TicketID, Amount FROM dbo.Tickets WHERE Status <> @s AND CustomerID = 100;
GO
-- 6.3 Та же переменная + RECOMPILE -> значение известно при компиляции -> индекс используется
DECLARE @s tinyint = 1;
SELECT TicketID, Amount FROM dbo.Tickets WHERE Status <> @s AND CustomerID = 100
OPTION (RECOMPILE);
GO
-- 6.4 Размеры: фильтрованный индекс в десятки раз меньше таблицы
SELECT i.name, ps.row_count, ps.used_page_count
FROM sys.dm_db_partition_stats ps
JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id = OBJECT_ID(N'dbo.Tickets');
GO

SET STATISTICS IO OFF;
GO
-- Уборка
-- USE master; ALTER DATABASE NegationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE NegationDemo;
