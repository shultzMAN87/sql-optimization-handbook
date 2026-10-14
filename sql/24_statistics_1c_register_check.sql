/* =====================================================================
   Статистика таблицы 1С на живых данных: чтение, сверка, перекос,
   автообновление и перехват запроса StatMan
   Практикум П10 (docs/20-statistics-1c-real-walkthrough.md), вопросы 29–34.
   SQL Server 2016 SP1 CU2+ (sys.dm_db_stats_histogram).

   Работает на ЛЮБОЙ таблице базы 1С: в начале каждого блока замените
   имя таблицы и статистики. В примере — регистр сведений
   dbo._InfoRg45092 и статистика его индекса _InfoRg45092_1
   (Период + измерения).

   Блоки 1–7 только читают. Блок 8 создаёт сессию Extended Events
   и пересчитывает статистику — выполняйте на тестовой копии базы.
   Выполнять ПО БЛОКАМ, с включённым фактическим планом (Ctrl+M)
   там, где сказано.
   ===================================================================== */

/* ---------- 1. Все статистики таблицы: свежесть, выборка, счётчик
   изменений и порог автообновления.
   Порог: до 500 строк — 500 изменений; больше — MIN(500 + 20%; √(1000·n))
   при уровне совместимости 130+ (иначе 500 + 20%). ---------- */
DECLARE @tbl sysname = N'dbo._InfoRg45092';

SELECT s.name                                   AS stats_name,
       s.auto_created, s.user_created, s.has_filter, s.no_recompute,
       sp.last_updated, sp.rows, sp.rows_sampled,
       CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS decimal(5,1)) AS sample_pct,
       sp.unfiltered_rows, sp.persisted_sample_percent, sp.steps,
       sp.modification_counter,
       CASE WHEN sp.rows <= 500 THEN 500
            ELSE IIF(500 + 0.2 * sp.rows < SQRT(1000.0 * sp.rows),
                     500 + 0.2 * sp.rows, SQRT(1000.0 * sp.rows)) END AS auto_update_threshold
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID(@tbl)
ORDER BY s.name;

-- Живое число строк из метаданных — для сравнения с Rows статистики (снимок)
SELECT SUM(row_count) AS rows_now
FROM sys.dm_db_partition_stats
WHERE object_id = OBJECT_ID(@tbl) AND index_id IN (0, 1);

-- Настройки базы, от которых зависит автообновление
SELECT name, compatibility_level, is_auto_create_stats_on,
       is_auto_update_stats_on, is_auto_update_stats_async_on
FROM sys.databases WHERE name = DB_NAME();
GO

/* ---------- 2. Все три части статистики ---------- */
DBCC SHOW_STATISTICS (N'dbo._InfoRg45092', N'_InfoRg45092_1');
GO

/* ---------- 3. Сверка трёх частей между собой.
   Должно выполняться:
     SUM(EQ_ROWS) + SUM(RANGE_ROWS)          = Rows
     Steps + SUM(DISTINCT_RANGE_ROWS)        = 1 / density первого столбца
   При выборке (Rows Sampled < Rows) числа экстраполированы, и
   равенства выполняются только приблизительно. ---------- */
DECLARE @tbl sysname = N'dbo._InfoRg45092', @stat sysname = N'_InfoRg45092_1';
DECLARE @obj int = OBJECT_ID(@tbl);
DECLARE @sid int = (SELECT stats_id FROM sys.stats WHERE object_id = @obj AND name = @stat);

DROP TABLE IF EXISTS #dv;
CREATE TABLE #dv (all_density float, avg_length float, columns nvarchar(4000));
INSERT #dv EXEC (N'DBCC SHOW_STATISTICS (N''' + @tbl + N''', N''' + @stat + N''') WITH DENSITY_VECTOR, NO_INFOMSGS');

DECLARE @distinct_by_density float =
    (SELECT TOP (1) ROUND(1 / all_density, 0) FROM #dv ORDER BY avg_length);   -- первая строка вектора

SELECT sp.rows,
       SUM(h.equal_rows)                              AS sum_eq_rows,
       SUM(h.range_rows)                              AS sum_range_rows,
       SUM(h.equal_rows) + SUM(h.range_rows)          AS eq_plus_range,       -- = rows
       COUNT(*)                                       AS steps,
       SUM(h.distinct_range_rows)                     AS distinct_inside_steps,
       COUNT(*) + SUM(h.distinct_range_rows)          AS distinct_by_histogram,   -- = distinct_by_density
       @distinct_by_density                           AS distinct_by_density
FROM sys.dm_db_stats_properties(@obj, @sid) sp
CROSS APPLY sys.dm_db_stats_histogram(@obj, @sid) h
GROUP BY sp.rows;

-- Вектор плотности с пересчётом в «число разных комбинаций» и приростом длины ключа
SELECT columns, all_density,
       ROUND(1 / all_density, 0)                         AS distinct_combinations,
       avg_length,
       avg_length - LAG(avg_length, 1, 0) OVER (ORDER BY avg_length) AS bytes_added_by_column
FROM #dv
ORDER BY avg_length;
GO

/* ---------- 4. Плотность вручную — те же числа обычными запросами.
   Список столбцов — из вывода блока 2 (раздел DENSITY_VECTOR). ---------- */
SELECT N'_Period' AS cols, COUNT(*) AS distinct_cnt, 1.0 / COUNT(*) AS all_density
FROM (SELECT DISTINCT _Period FROM dbo._InfoRg45092) t
UNION ALL
SELECT N'_Period, _Fld45093', COUNT(*), 1.0 / COUNT(*)
FROM (SELECT DISTINCT _Period, _Fld45093 FROM dbo._InfoRg45092) t
UNION ALL
SELECT N'полный ключ', COUNT(*), 1.0 / COUNT(*)
FROM (SELECT DISTINCT _Period, _Fld45093, _Fld45094RRef, _Fld45095RRef, _Fld47048RRef
      FROM dbo._InfoRg45092) t;
-- Сразу после пересчёта статистики числа совпадут с блоком 3.
-- Если с тех пор данные менялись — разница и есть «отставание» статистики.
GO

/* ---------- 5. Гистограмма против реальности: каждый шаг.
   actual_* — сколько строк в таблице СЕЙЧАС. Сразу после FULLSCAN
   все столбцы совпадут; после вставок видно, где статистика отстала. ---------- */
DECLARE @obj int = OBJECT_ID(N'dbo._InfoRg45092');
DECLARE @sid int = (SELECT stats_id FROM sys.stats WHERE object_id = @obj AND name = N'_InfoRg45092_1');

WITH h AS
(
    SELECT step_number,
           CAST(range_high_key AS datetime2(0)) AS hi_key,
           LAG(CAST(range_high_key AS datetime2(0))) OVER (ORDER BY step_number) AS prev_key,
           equal_rows, range_rows, distinct_range_rows, average_range_rows
    FROM sys.dm_db_stats_histogram(@obj, @sid)
)
SELECT h.step_number, h.prev_key, h.hi_key,
       h.equal_rows,
       (SELECT COUNT(*) FROM dbo._InfoRg45092 t WHERE t._Period = h.hi_key) AS actual_eq,
       h.range_rows,
       (SELECT COUNT(*) FROM dbo._InfoRg45092 t
         WHERE t._Period > ISNULL(h.prev_key, '0001-01-01') AND t._Period < h.hi_key) AS actual_range,
       h.distinct_range_rows,
       (SELECT COUNT(DISTINCT t._Period) FROM dbo._InfoRg45092 t
         WHERE t._Period > ISNULL(h.prev_key, '0001-01-01') AND t._Period < h.hi_key) AS actual_distinct,
       h.average_range_rows
FROM h
ORDER BY h.step_number;

-- Строки ПРАВЕЕ последнего шага: о них гистограмма не знает (восходящий ключ, вопрос 35)
SELECT COUNT(*) AS rows_after_last_step
FROM dbo._InfoRg45092
WHERE _Period > (SELECT MAX(CAST(range_high_key AS datetime2(0)))
                 FROM sys.dm_db_stats_histogram(@obj, @sid));
GO

/* ---------- 6. Перекос: одно условие — две оценки. Включите Ctrl+M.
   Подставьте значение с самым большим EQ_ROWS из гистограммы
   (в примере 4026-10-14 09:04:47, EQ_ROWS = 43). ---------- */

-- 6а. Литерал: оценка по гистограмме = EQ_ROWS (43)
SELECT _Period, _Fld45093 FROM dbo._InfoRg45092
WHERE _Period = '4026-10-14 09:04:47';

-- 6б. Локальная переменная: значение при компиляции неизвестно,
--     оценка = Rows × density(_Period) (183 / 105 ≈ 1,74)
DECLARE @p datetime2(0) = '4026-10-14 09:04:47';
SELECT _Period, _Fld45093 FROM dbo._InfoRg45092
WHERE _Period = @p;

-- 6в. Как это делает 1С: параметр через sp_executesql.
--     Первый вызов «подсматривает» значение — оценка по гистограмме (43).
--     Второй вызов с редким значением берёт тот же план из кэша:
--     в свойствах SELECT сравните Parameter Compiled Value и Runtime Value.
EXEC sp_executesql N'SELECT _Period, _Fld45093 FROM dbo._InfoRg45092 WHERE _Period = @P1',
                   N'@P1 datetime2(0)', @P1 = '4026-10-14 09:04:47';
EXEC sp_executesql N'SELECT _Period, _Fld45093 FROM dbo._InfoRg45092 WHERE _Period = @P1',
                   N'@P1 datetime2(0)', @P1 = '4026-09-23 03:49:38';
GO

/* ---------- 7. Почему статистика «не пересчиталась».
   Rows, Unfiltered Rows, Updated и гистограмма — снимок на момент
   последнего пересчёта. Пока modification_counter не превысил порог
   (блок 1) И пока к таблице не пришёл запрос, которому нужна эта
   статистика, снимок не меняется. ---------- */
DECLARE @obj int = OBJECT_ID(N'dbo._InfoRg45092');
SELECT s.name, sp.last_updated, sp.rows AS rows_in_snapshot, sp.unfiltered_rows,
       sp.modification_counter,
       (SELECT SUM(row_count) FROM sys.dm_db_partition_stats
         WHERE object_id = @obj AND index_id IN (0, 1)) AS rows_now
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = @obj;

-- Пересчитать вручную, не дожидаясь порога:
-- UPDATE STATISTICS dbo._InfoRg45092 _InfoRg45092_1 WITH FULLSCAN;
GO

/* ---------- 8. Каким запросом строится статистика: перехват StatMan
   через Extended Events. ТЕСТОВАЯ КОПИЯ: пересчитывает статистику.
   То же в Profiler — событие SP:StmtCompleted с фильтром
   TextData LIKE '%StatMan%' (пошагово — практикум П10, пункт 9). ---------- */
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'StatManCapture')
    DROP EVENT SESSION StatManCapture ON SERVER;
GO
CREATE EVENT SESSION StatManCapture ON SERVER
ADD EVENT sqlserver.sp_statement_completed
    (WHERE sqlserver.like_i_sql_unicode_string(statement, N'%StatMan%')),
ADD EVENT sqlserver.sql_statement_completed
    (WHERE sqlserver.like_i_sql_unicode_string(statement, N'%StatMan%')),
ADD EVENT sqlserver.auto_stats                    -- автосоздание и автообновление при компиляции
ADD TARGET package0.ring_buffer;
GO
ALTER EVENT SESSION StatManCapture ON SERVER STATE = START;
GO

-- 8а. Полный пересчёт: в тексте запроса НЕТ TABLESAMPLE
UPDATE STATISTICS dbo._InfoRg45092 _InfoRg45092_1 WITH FULLSCAN;
GO
-- 8б. Выборка: в тексте появится TABLESAMPLE SYSTEM (50 PERCENT)
--     (на маленькой таблице сервер всё равно может прочитать всё)
UPDATE STATISTICS dbo._InfoRg45092 _InfoRg45092_1 WITH SAMPLE 50 PERCENT;
GO
-- 8в. Вернуть точную статистику
UPDATE STATISTICS dbo._InfoRg45092 _InfoRg45092_1 WITH FULLSCAN;
GO

SELECT ev.x.value('@name', 'nvarchar(60)')                                     AS event_name,
       ev.x.value('@timestamp', 'datetime2')                                   AS ts_utc,
       ev.x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')       AS statement_text,
       ev.x.value('(data[@name="duration"]/value)[1]', 'bigint')               AS duration_mcs,
       ev.x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')          AS logical_reads,
       ev.x.value('(data[@name="statistics_list"]/value)[1]', 'nvarchar(max)') AS auto_stats_list
FROM (SELECT CAST(t.target_data AS xml) AS td
      FROM sys.dm_xe_session_targets t
      JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
      WHERE s.name = N'StatManCapture') d
CROSS APPLY d.td.nodes('//event') ev(x)
ORDER BY ts_utc;
GO

ALTER EVENT SESSION StatManCapture ON SERVER STATE = STOP;
DROP EVENT SESSION StatManCapture ON SERVER;
GO

/* ---------- 9. План чтения, которым строится статистика.
   Сам SELECT StatMan(...) выполнить нельзя: StatMan — внутренняя функция
   движка. Но его «подзапрос» можно выполнить с фактическим планом (Ctrl+M)
   и посмотреть, нужен ли Sort. Для индекса Период + измерения ожидаем
   Index Scan этого индекса с Ordered = True и без оператора Sort:
   индекс уже упорядочен по всем столбцам статистики. ---------- */
SELECT TOP 100 PERCENT _Period, _Fld45093, _Fld45094RRef, _Fld45095RRef, _Fld47048RRef
FROM dbo._InfoRg45092 WITH (READUNCOMMITTED)
ORDER BY _Period, _Fld45093, _Fld45094RRef, _Fld45095RRef, _Fld47048RRef;
GO
