/* =====================================================================
   Как работает оптимизатор изнутри:
   тривиальный и полный план, фазы и бюджет, упрощение, правила трансформации
   Вопросы 20–24 и сквозной пример 28а методички (обзор — начало раздела 3). MS SQL Server 2016+.

   ВНИМАНИЕ: запускать ТОЛЬКО на тестовом сервере.
   - QUERYTRACEON и DBCC RULEOFF требуют прав sysadmin;
   - флаги 8606, 8675 и представление sys.dm_exec_query_transformation_stats недокументированы;
   - DMV sys.dm_exec_query_optimizer_info и transformation_stats общие на весь сервер:
     на нагруженном сервере в «разницу» попадут чужие компиляции.
   ===================================================================== */

---------------------------------------------------------------------------
-- 0. Тестовая база и данные
---------------------------------------------------------------------------
USE master;
GO
IF DB_ID(N'OptDemo') IS NOT NULL
BEGIN
    ALTER DATABASE OptDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE OptDemo;
END;
GO
CREATE DATABASE OptDemo;
GO
USE OptDemo;
GO

CREATE TABLE dbo.Categories (Id int PRIMARY KEY, Name nvarchar(50));
CREATE TABLE dbo.Products   (Id int PRIMARY KEY, Name nvarchar(50), CategoryId int);
CREATE TABLE dbo.Customers  (Id int PRIMARY KEY, Name nvarchar(50), City nvarchar(50));
CREATE TABLE dbo.Orders     (Id int PRIMARY KEY, CustomerId int, OrderDate date, Amount money);
CREATE TABLE dbo.OrderLines (Id int PRIMARY KEY, OrderId int, ProductId int, Qty int);
GO

-- Генератор чисел 1..1 000 000
WITH N AS (
    SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c
)
SELECT n INTO #N FROM N;

INSERT dbo.Categories SELECT n, N'Категория ' + CAST(n AS nvarchar(10)) FROM #N WHERE n <= 20;
INSERT dbo.Products   SELECT n, N'Товар ' + CAST(n AS nvarchar(10)), n % 20 + 1 FROM #N WHERE n <= 1000;
INSERT dbo.Customers  SELECT n, N'Клиент ' + CAST(n AS nvarchar(10)), N'Город ' + CAST(n % 50 AS nvarchar(10)) FROM #N WHERE n <= 10000;
INSERT dbo.Orders     SELECT n, n % 10000 + 1, DATEADD(day, -(n % 1000), '20260101'), n % 500 FROM #N WHERE n <= 200000;
INSERT dbo.OrderLines SELECT n, n % 200000 + 1, n % 1000 + 1, n % 10 + 1 FROM #N WHERE n <= 600000;
DROP TABLE #N;
GO

---------------------------------------------------------------------------
-- 1. Способ «глазами»: предполагаемый план (Ctrl+L в SSMS)
--    Выделите запрос, нажмите Ctrl+L, кликните по оператору SELECT,
--    откройте окно Properties (F4) и смотрите:
--      Optimization Level              -> TRIVIAL или FULL
--      Estimated Subtree Cost          -> стоимость плана
--      Reason For Early Termination    -> Good Enough Plan Found / Time Out
--      CompileTime, CompileCPU, CompileMemory -> цена компиляции
---------------------------------------------------------------------------

-- Q1. Тривиальный: выбор по первичному ключу, вариант ровно один
SELECT Name FROM dbo.Customers WHERE Id = 5;

-- Q2. Две таблицы: search 0 пропускается (нужно >= 3 таблиц), сразу search 1
SELECT c.City, COUNT(*) AS Cnt
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7'
GROUP BY c.City;

-- Q3. Пять таблиц и агрегация: дорогой запрос, вариантов много
SELECT cat.Name, c.City, SUM(ol.Qty * o.Amount) AS Total
FROM dbo.OrderLines ol
JOIN dbo.Orders     o   ON o.Id   = ol.OrderId
JOIN dbo.Customers  c   ON c.Id   = o.CustomerId
JOIN dbo.Products   p   ON p.Id   = ol.ProductId
JOIN dbo.Categories cat ON cat.Id = p.CategoryId
GROUP BY cat.Name, c.City;

-- Q4. Много соединений: шанс получить Time Out (зависит от версии и данных)
SELECT COUNT(*)
FROM dbo.Orders o1
JOIN dbo.Orders o2  ON o2.Id  = o1.Id + 1
JOIN dbo.Orders o3  ON o3.Id  = o2.Id + 1
JOIN dbo.Orders o4  ON o4.Id  = o3.Id + 1
JOIN dbo.Orders o5  ON o5.Id  = o4.Id + 1
JOIN dbo.Orders o6  ON o6.Id  = o5.Id + 1
JOIN dbo.Orders o7  ON o7.Id  = o6.Id + 1
JOIN dbo.Orders o8  ON o8.Id  = o7.Id + 1
JOIN dbo.Customers c1 ON c1.Id = o1.CustomerId
JOIN dbo.Customers c2 ON c2.Id = o4.CustomerId
JOIN dbo.Customers c3 ON c3.Id = o8.CustomerId
WHERE c1.City = c2.City AND c2.City = c3.City;
GO

---------------------------------------------------------------------------
-- 2. Способ «изнутри»: флаг 8675 печатает фазы, стоимость и число задач
--    Результат смотреть на вкладке Messages (Сообщения). Строки примерно такие:
--      end search(0), cost: ... tasks: ...
--      end search(1), cost: ... tasks: ...
--      end search(2), cost: ... tasks: ...
--    cost  = стоимость лучшего плана после фазы
--    tasks = сколько задач (шагов перебора) потрачено -> это и есть расход бюджета
--    У тривиального запроса строк search нет совсем.
---------------------------------------------------------------------------

SELECT Name FROM dbo.Customers WHERE Id = 5
OPTION (RECOMPILE, QUERYTRACEON 3604, QUERYTRACEON 8675);

SELECT c.City, COUNT(*) AS Cnt
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7'
GROUP BY c.City
OPTION (RECOMPILE, QUERYTRACEON 3604, QUERYTRACEON 8675);

SELECT cat.Name, c.City, SUM(ol.Qty * o.Amount) AS Total
FROM dbo.OrderLines ol
JOIN dbo.Orders     o   ON o.Id   = ol.OrderId
JOIN dbo.Customers  c   ON c.Id   = o.CustomerId
JOIN dbo.Products   p   ON p.Id   = ol.ProductId
JOIN dbo.Categories cat ON cat.Id = p.CategoryId
GROUP BY cat.Name, c.City
OPTION (RECOMPILE, QUERYTRACEON 3604, QUERYTRACEON 8675);
GO

---------------------------------------------------------------------------
-- 3. Способ «по счётчикам»: DMV sys.dm_exec_query_optimizer_info
--    Снимок до, запрос, снимок после, разница = что сделал оптимизатор.
--    В DMV value — СРЕДНЕЕ по всем оптимизациям сервера, поэтому значение
--    для одного запроса считаем как разницу сумм (occurrence × value).
---------------------------------------------------------------------------

-- 3.0 «Прогрев»: компиляция самих запросов снимка не должна попасть в разницу
SELECT counter, occurrence, value INTO #before FROM sys.dm_exec_query_optimizer_info;
DROP TABLE #before;
GO
SELECT counter, occurrence, value INTO #before FROM sys.dm_exec_query_optimizer_info;
GO
-- >>> сюда подставьте любой запрос из Q1..Q4 <<<
SELECT cat.Name, c.City, SUM(ol.Qty * o.Amount) AS Total
FROM dbo.OrderLines ol
JOIN dbo.Orders     o   ON o.Id   = ol.OrderId
JOIN dbo.Customers  c   ON c.Id   = o.CustomerId
JOIN dbo.Products   p   ON p.Id   = ol.ProductId
JOIN dbo.Categories cat ON cat.Id = p.CategoryId
GROUP BY cat.Name, c.City
OPTION (RECOMPILE);
GO
SELECT a.counter,
       a.occurrence - b.occurrence AS [сколько раз],
       CASE WHEN a.occurrence - b.occurrence > 0
            THEN (a.occurrence * a.value - b.occurrence * b.value)
                 / (a.occurrence - b.occurrence) END AS [значение для этих оптимизаций]
FROM sys.dm_exec_query_optimizer_info a
JOIN #before b ON b.counter = a.counter
WHERE a.occurrence <> b.occurrence
  AND a.counter IN (N'optimizations', N'trivial plan', N'search 0', N'search 1',
                    N'search 2', N'timeout', N'tasks', N'elapsed time',
                    N'final cost', N'tables', N'maximum DOP')
ORDER BY a.counter;
DROP TABLE #before;
GO
/* В разницу может попасть и компиляция итогового SELECT к DMV (optimizations +1).
   Надёжнее выполнить весь блок 3 дважды и смотреть второй результат. */

---------------------------------------------------------------------------
-- 4. Упрощение (вопрос 23): противоречие, удаление соединения, транзитивность
---------------------------------------------------------------------------
-- Ограничения, которые использует упрощение (WITH CHECK -> доверенные)
ALTER TABLE dbo.Orders WITH CHECK ADD CONSTRAINT CK_Orders_Amount CHECK (Amount >= 0 AND Amount < 500);
ALTER TABLE dbo.Orders WITH CHECK ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerId) REFERENCES dbo.Customers (Id);
GO

-- 4.1 Противоречие с CHECK: в плане только Constant Scan, 0 логических чтений
SET STATISTICS IO ON;
SELECT Id, Amount FROM dbo.Orders WHERE Amount > 1000 OPTION (RECOMPILE);
-- Самопротиворечие в тексте
SELECT Id FROM dbo.Orders WHERE Id > 10 AND Id < 5 OPTION (RECOMPILE);
SET STATISTICS IO OFF;
GO
-- 4.2 Деревья до и после упрощения (Messages): Input Tree -> Simplified Tree с LogOp_ConstTableGet
SELECT Id, Amount FROM dbo.Orders WHERE Amount > 1000
OPTION (RECOMPILE, QUERYTRACEON 3604, QUERYTRACEON 8606);
GO
-- 4.3 Удаление INNER JOIN по доверенному FK: столбцы Customers не нужны -> таблицы нет в плане.
--     CustomerId допускает NULL -> вместо соединения фильтр CustomerId IS NOT NULL.
SELECT o.Id, o.Amount
FROM dbo.Orders o
JOIN dbo.Customers c ON c.Id = o.CustomerId
WHERE o.Id < 100;
GO
-- 4.4 Тот же запрос, но FK стал НЕдоверенным -> соединение вернулось в план
ALTER TABLE dbo.Orders NOCHECK CONSTRAINT FK_Orders_Customers;
SELECT name, is_not_trusted FROM sys.foreign_keys WHERE name = N'FK_Orders_Customers';
SELECT o.Id, o.Amount
FROM dbo.Orders o
JOIN dbo.Customers c ON c.Id = o.CustomerId
WHERE o.Id < 100;
ALTER TABLE dbo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;   -- снова доверенный
GO
-- 4.5 Удаление LEFT JOIN: справа уникальный ключ, столбцы справа не нужны (FK не требуется)
SELECT o.Id FROM dbo.Orders o LEFT JOIN dbo.Customers c ON c.Id = o.CustomerId WHERE o.Id < 100;
GO
-- 4.6 Транзитивность: из o.CustomerId = c.Id AND o.CustomerId = 42 выводится c.Id = 42
--     В плане: Clustered Index Seek по Customers с Id = 42
SELECT o.Id, c.Name
FROM dbo.Orders o
JOIN dbo.Customers c ON c.Id = o.CustomerId
WHERE o.CustomerId = 42;
GO

---------------------------------------------------------------------------
-- 5. Правила трансформации (вопрос 24)
---------------------------------------------------------------------------
-- 5.1 Какие правила сработали для запроса: снимок transformation_stats до и после
SELECT * INTO #tb FROM sys.dm_exec_query_transformation_stats;   -- прогрев
SELECT * INTO #ta FROM sys.dm_exec_query_transformation_stats;
DROP TABLE #tb, #ta;
GO
SELECT * INTO #tb FROM sys.dm_exec_query_transformation_stats;
GO
SELECT c.Id, COUNT(*) AS Cnt
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.Id
GROUP BY c.Id
OPTION (RECOMPILE);
GO
SELECT * INTO #ta FROM sys.dm_exec_query_transformation_stats;
GO
SELECT a.name AS rule_name,
       a.promised  - b.promised  AS times_promised,
       a.succeeded - b.succeeded AS times_succeeded
FROM #tb b JOIN #ta a ON a.name = b.name
WHERE a.succeeded <> b.succeeded
ORDER BY times_succeeded DESC;
DROP TABLE #tb, #ta;
GO
-- 5.2 Сколько всего правил знает оптимизатор
SELECT COUNT(*) AS rules_total FROM sys.dm_exec_query_transformation_stats;
GO
-- 5.3 Отключаем правила на один запрос и сравниваем планы (Ctrl+L)
--     а) как есть
SELECT c.Id, COUNT(*) AS Cnt
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.Id
GROUP BY c.Id
OPTION (RECOMPILE);
--     б) без агрегации до соединения: если в а) Aggregate стоял ДО Join, здесь он окажется после
SELECT c.Id, COUNT(*) AS Cnt
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.Id
GROUP BY c.Id
OPTION (RECOMPILE, QUERYRULEOFF GbAggBeforeJoin);
--     в) без Hash и Merge Join: остаётся только Nested Loops
SELECT c.Id, COUNT(*) AS Cnt
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.Id
GROUP BY c.Id
OPTION (RECOMPILE, QUERYRULEOFF JNtoHS, QUERYRULEOFF JNtoSM);
GO
-- 5.4 То же на уровне сессии
DBCC TRACEON (3604);
DBCC RULEOFF ('GbAggBeforeJoin');
DBCC SHOWOFFRULES;              -- список отключённых правил
DBCC RULEON ('GbAggBeforeJoin');
DBCC TRACEOFF (3604);
GO

---------------------------------------------------------------------------
-- 6. Сквозной пример вопроса 28а: запрос проходит весь путь оптимизатора
---------------------------------------------------------------------------
-- 6.1 Предполагаемый план (Ctrl+L). Ожидаемо:
--     Hash Match (build Customers ~200 строк, probe Orders ~73 200) + Stream Aggregate,
--     Estimated Subtree Cost около 0,8–0,9, Optimization Level = FULL,
--     Reason For Early Termination = Good Enough Plan Found.
SELECT c.City, COUNT(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7'
  AND o.OrderDate >= '20250101'
GROUP BY c.City;
GO
-- 6.2 Фаза и число задач (Messages): ожидается только search(1), десятки задач
SELECT c.City, COUNT(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7' AND o.OrderDate >= '20250101'
GROUP BY c.City
OPTION (RECOMPILE, QUERYTRACEON 3604, QUERYTRACEON 8675);
GO
-- 6.3 Во сколько оптимизатор оценил ОТВЕРГНУТЫЕ варианты (Ctrl+L по каждому,
--     сравните Estimated Subtree Cost на SELECT с планом 6.1)
SELECT c.City, COUNT(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7' AND o.OrderDate >= '20250101'
GROUP BY c.City
OPTION (LOOP JOIN);    -- Nested Loops: для каждого клиента скан Orders или поиск по Customers
SELECT c.City, COUNT(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7' AND o.OrderDate >= '20250101'
GROUP BY c.City
OPTION (MERGE JOIN);   -- Merge Join: появятся Sort по CustomerId
GO
-- 6.4 Добавляем индекс -> появляется вариант Nested Loops + Index Seek, и он выигрывает
CREATE INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId) INCLUDE (OrderDate, Amount);
GO
SELECT c.City, COUNT(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7'
  AND o.OrderDate >= '20250101'
GROUP BY c.City;
-- Для сравнения — прежний вариант, навязанный хинтом:
SELECT c.City, COUNT(*) AS Cnt, SUM(o.Amount) AS Total
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.Id
WHERE c.City = N'Город 7' AND o.OrderDate >= '20250101'
GROUP BY c.City
OPTION (HASH JOIN);
GO
DROP INDEX IX_Orders_CustomerId ON dbo.Orders;
GO

---------------------------------------------------------------------------
-- 7. Уборка
---------------------------------------------------------------------------
-- USE master; ALTER DATABASE OptDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE OptDemo;
