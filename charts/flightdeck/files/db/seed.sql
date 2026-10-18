-- flightdeck demo data: 40 departures from HYD, BLR, DEL, BOM and MAA.
-- Departure times are anchored to "today" in IST, so the board always looks
-- current whenever the seed is (re)applied. Re-running replaces all rows.

BEGIN;

TRUNCATE flights RESTART IDENTITY;

WITH today AS (
    SELECT date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata' AS d
)
INSERT INTO flights (flight_no, origin_iata, dest_iata, scheduled_dep, status, aircraft)
SELECT v.flight_no, v.origin, v.dest, today.d + v.dep::interval, v.status, v.aircraft
FROM today, (VALUES
    -- Hyderabad (HYD)
    ('6E 6033', 'HYD', 'BLR', '06:00', 'landed',    'A320neo'),
    ('AI 2541', 'HYD', 'DEL', '06:45', 'departed',  'A320neo'),
    ('QP 1312', 'HYD', 'BOM', '07:30', 'departed',  'B737-8'),
    ('6E 5326', 'HYD', 'MAA', '08:15', 'boarding',  'A321neo'),
    ('IX 975',  'HYD', 'DXB', '09:10', 'scheduled', 'B737-8'),
    ('SG 1083', 'HYD', 'GOI', '10:40', 'delayed',   'B737-800'),
    ('6E 6147', 'HYD', 'CCU', '12:05', 'scheduled', 'A320neo'),
    ('6E 7213', 'HYD', 'VGA', '13:20', 'scheduled', 'ATR 72-600'),

    -- Bengaluru (BLR)
    ('6E 5131', 'BLR', 'DEL', '05:50', 'landed',    'A321neo'),
    ('AI 2804', 'BLR', 'BOM', '06:30', 'departed',  'A320neo'),
    ('QP 1355', 'BLR', 'AMD', '07:40', 'departed',  'B737-8'),
    ('6E 6406', 'BLR', 'HYD', '08:20', 'boarding',  'A320neo'),
    ('6E 1005', 'BLR', 'SIN', '09:55', 'scheduled', 'A321neo'),
    ('IX 2731', 'BLR', 'COK', '10:15', 'delayed',   'B737-8'),
    ('AI 176',  'BLR', 'SFO', '13:30', 'scheduled', 'B777-200LR'),
    ('6E 7563', 'BLR', 'IXE', '14:05', 'scheduled', 'ATR 72-600'),

    -- Delhi (DEL)
    ('AI 101',  'DEL', 'JFK', '02:15', 'departed',  'B777-300ER'),
    ('6E 2172', 'DEL', 'BOM', '06:00', 'landed',    'A321neo'),
    ('6E 2133', 'DEL', 'BLR', '07:05', 'departed',  'A320neo'),
    ('AI 2433', 'DEL', 'HYD', '08:40', 'boarding',  'A320neo'),
    ('QP 1335', 'DEL', 'BOM', '09:30', 'delayed',   'B737-8'),
    ('SG 8169', 'DEL', 'PAT', '11:10', 'cancelled', 'B737-800'),
    ('AI 2913', 'DEL', 'SXR', '12:20', 'scheduled', 'A320neo'),
    ('AI 111',  'DEL', 'LHR', '13:45', 'scheduled', 'B787-8'),

    -- Mumbai (BOM)
    ('6E 5216', 'BOM', 'DEL', '06:10', 'landed',    'A321neo'),
    ('AI 2805', 'BOM', 'BLR', '07:00', 'departed',  'A320neo'),
    ('QP 1404', 'BOM', 'HYD', '08:00', 'departed',  'B737-8'),
    ('6E 1451', 'BOM', 'DXB', '09:20', 'boarding',  'A321neo'),
    ('SG 157',  'BOM', 'GOI', '10:35', 'delayed',   'B737-800'),
    ('AI 2979', 'BOM', 'MAA', '11:55', 'scheduled', 'A320neo'),
    ('AI 131',  'BOM', 'LHR', '13:40', 'scheduled', 'B777-300ER'),
    ('6E 6184', 'BOM', 'IXC', '14:25', 'scheduled', 'A320neo'),

    -- Chennai (MAA)
    ('6E 6012', 'MAA', 'DEL', '05:30', 'landed',    'A321neo'),
    ('AI 2891', 'MAA', 'BOM', '06:50', 'departed',  'A320neo'),
    ('6E 5193', 'MAA', 'BLR', '07:45', 'departed',  'A320neo'),
    ('IX 2849', 'MAA', 'HYD', '08:35', 'boarding',  'B737-8'),
    ('6E 1361', 'MAA', 'CMB', '09:50', 'scheduled', 'A320neo'),
    ('6E 7123', 'MAA', 'TRZ', '10:55', 'delayed',   'ATR 72-600'),
    ('AI 346',  'MAA', 'SIN', '12:30', 'scheduled', 'A320neo'),
    ('6E 2213', 'MAA', 'CCU', '15:10', 'scheduled', 'A320neo')
) AS v(flight_no, origin, dest, dep, status, aircraft);

COMMIT;
