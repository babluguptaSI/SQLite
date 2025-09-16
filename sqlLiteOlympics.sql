1)
WITH country_sport_medals AS (
    SELECT 
        a.country_code,
        m.discipline,
        COUNT(*) AS medal_count
    FROM medals m
    JOIN athletes a ON m.code = a.code
    GROUP BY a.country_code, m.discipline
),
medal_distribution AS (
    SELECT 
        country_code,
        GROUP_CONCAT(discipline || ': ' || medal_count, ', ') AS medals_str
    FROM (
        SELECT country_code, discipline, medal_count
        FROM country_sport_medals
        ORDER BY discipline
    )
    GROUP BY country_code
)
SELECT 
    csm.country_code AS country,
    COUNT(DISTINCT csm.discipline) AS total_sports,
    SUM(csm.medal_count) AS total_medals,
    md.medals_str AS medal_distribution
FROM country_sport_medals csm
JOIN medal_distribution md ON csm.country_code = md.country_code
GROUP BY csm.country_code
ORDER BY total_sports DESC, total_medals DESC
LIMIT 10;

2)
WITH gender_medals AS (
    SELECT 
        a.country_code,
        a.gender,                 -- Assuming 'Male'/'Female' in dataset
        m.discipline,
        COUNT(*) AS medal_count
    FROM medals m
    JOIN athletes a ON m.code = a.code
    GROUP BY a.country_code, a.gender, m.discipline
),
country_totals AS (
    SELECT 
        country_code,
        SUM(CASE WHEN gender = 'Male' THEN medal_count ELSE 0 END) AS male_medals,
        SUM(CASE WHEN gender = 'Female' THEN medal_count ELSE 0 END) AS female_medals
    FROM gender_medals
    GROUP BY country_code
),
ranked_sports AS (
    SELECT
        country_code,
        gender,
        discipline,
        medal_count,
        RANK() OVER (PARTITION BY country_code, gender ORDER BY medal_count DESC) AS rnk
    FROM gender_medals
)
SELECT 
    ct.country_code,
    ct.male_medals,
    ct.female_medals,
    MAX(CASE WHEN rs.gender = 'Male' AND rs.rnk = 1 THEN rs.discipline END) AS top_male_sport,
    MAX(CASE WHEN rs.gender = 'Female' AND rs.rnk = 1 THEN rs.discipline END) AS top_female_sport,
    CASE 
        WHEN ct.male_medals > ct.female_medals THEN 'Male'
        WHEN ct.female_medals > ct.male_medals THEN 'Female'
        ELSE 'Equal'
    END AS dominant_gender
FROM country_totals ct
LEFT JOIN ranked_sports rs ON ct.country_code = rs.country_code
GROUP BY ct.country_code, ct.male_medals, ct.female_medals
ORDER BY (ct.male_medals + ct.female_medals) DESC
LIMIT 10;

3)
WITH athlete_age AS (
    SELECT 
        country_code,
        CAST(strftime('%Y', '2024-07-26') AS INTEGER) - CAST(strftime('%Y', birth_date) AS INTEGER) AS age
    FROM athletes
    WHERE birth_date IS NOT NULL
),
age_stats AS (
    SELECT 
        country_code,
        MIN(age) AS min_age,
        MAX(age) AS max_age,
        ROUND(AVG(age), 2) AS avg_age,
        ROUND(SQRT(AVG(age * age) - AVG(age) * AVG(age)), 2) AS stddev_age,  -- population stddev
        COUNT(*) AS num_athletes
    FROM athlete_age
    GROUP BY country_code
),
medal_counts AS (
    SELECT a.country_code, COUNT(*) AS total_medals
    FROM medals m
    JOIN athletes a ON m.code = a.code
    GROUP BY a.country_code
),
combined AS (
    SELECT 
        s.country_code,
        s.min_age,
        s.max_age,
        s.avg_age,
        s.stddev_age,
        s.num_athletes,
        COALESCE(m.total_medals, 0) AS total_medals,
        ROUND(COALESCE(m.total_medals, 0) * 1.0 / NULLIF(s.num_athletes, 0), 2) AS medals_per_athlete
    FROM age_stats s
    LEFT JOIN medal_counts m USING (country_code)
),
with_quartiles AS (
    SELECT 
        c.*,
        NTILE(4) OVER (ORDER BY stddev_age DESC) AS age_diversity_quartile
    FROM combined c
)
SELECT *
FROM with_quartiles
ORDER BY stddev_age DESC;

4)
WITH medalists AS (
    SELECT m.discipline, a.gender, a.height
    FROM medals m
    JOIN athletes a ON m.code = a.code
    WHERE a.height IS NOT NULL AND a.height > 0
),
disc_medals AS (
    SELECT
        discipline,
        COUNT(*) AS total_medals,
        ROUND(AVG(height), 2) AS avg_medalist_height,
        SUM(CASE WHEN gender = 'Male' THEN 1 ELSE 0 END) AS male_medals,
        SUM(CASE WHEN gender = 'Female' THEN 1 ELSE 0 END) AS female_medals
    FROM medalists
    GROUP BY discipline
),
athlete_stats AS (
    SELECT
        d.discipline,
        ROUND((
            SELECT AVG(a.height)
            FROM athletes a
            WHERE a.height IS NOT NULL AND a.height > 0
              AND a.disciplines LIKE '%' || d.discipline || '%' COLLATE NOCASE
        ), 2) AS avg_height_athletes,
        (SELECT COUNT(*)
         FROM athletes a
         WHERE a.height IS NOT NULL AND a.height > 0
           AND a.disciplines LIKE '%' || d.discipline || '%' COLLATE NOCASE
        ) AS total_athletes,
        (SELECT COUNT(*)
         FROM athletes a
         WHERE a.height IS NOT NULL AND a.height > 0
           AND a.disciplines LIKE '%' || d.discipline || '%' COLLATE NOCASE
           AND a.height BETWEEN (
               SELECT MIN(height) FROM (
                   SELECT height FROM medalists WHERE discipline = d.discipline
                   ORDER BY height LIMIT 1 OFFSET (SELECT COUNT(*)/4 FROM medalists WHERE discipline = d.discipline)
               )
           ) AND (
               SELECT MIN(height) FROM (
                   SELECT height FROM medalists WHERE discipline = d.discipline
                   ORDER BY height LIMIT 1 OFFSET (SELECT 3*COUNT(*)/4 FROM medalists WHERE discipline = d.discipline)
               )
           )
        ) AS athletes_in_ideal_range
    FROM disc_medals d
)
SELECT
    d.discipline,
    d.total_medals,
    ad.avg_height_athletes,
    d.avg_medalist_height,
    CASE
        WHEN d.male_medals > d.female_medals THEN 'Male'
        WHEN d.female_medals > d.male_medals THEN 'Female'
        ELSE 'Equal'
    END AS dominant_gender,
    -- Using approximate quartiles
    ROUND((
        SELECT height FROM medalists WHERE discipline = d.discipline
        ORDER BY height LIMIT 1 OFFSET (SELECT COUNT(*)/4 FROM medalists WHERE discipline = d.discipline)
    ), 2) AS ideal_height_q1,
    ROUND((
        SELECT height FROM medalists WHERE discipline = d.discipline
        ORDER BY height LIMIT 1 OFFSET (SELECT 3*COUNT(*)/4 FROM medalists WHERE discipline = d.discipline)
    ), 2) AS ideal_height_q3,
    ROUND(
        COALESCE(ad.athletes_in_ideal_range, 0) * 100.0 / NULLIF(ad.total_athletes,0), 2
    ) AS pct_athletes_in_ideal_range
FROM disc_medals d
LEFT JOIN athlete_stats ad USING (discipline)
ORDER BY d.total_medals DESC;


5)
WITH country_medal AS (
    SELECT 
        a.country_code,
        COUNT(*) AS medal_count
    FROM athletes a
    JOIN medals m ON m.code = a.code
    GROUP BY a.country_code
),
unique_medalist AS (
    SELECT 
        a.country_code,
        COUNT(DISTINCT a.name) AS unique_athletes
    FROM athletes a
    JOIN medals m ON m.code = a.code
    GROUP BY a.country_code
),
athlete_medal_count AS (
    SELECT 
        a.country_code,
        a.name AS athlete_name,
        COUNT(*) AS medals
    FROM athletes a
    JOIN medals m ON m.code = a.code
    GROUP BY a.country_code, a.name
),
top_athletes AS (
    SELECT
        country_code,
        athlete_name,
        medals,
        ROW_NUMBER() OVER (PARTITION BY country_code ORDER BY medals DESC) AS rn,
        SUM(medals) OVER (PARTITION BY country_code ORDER BY medals DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_medals
    FROM athlete_medal_count
),
top_10_share AS (
    SELECT
        country_code,
        SUM(CASE WHEN rn <= 10 THEN medals ELSE 0 END) AS top_10_medals
    FROM top_athletes
    GROUP BY country_code
),
most_decorated AS (
    SELECT country_code, athlete_name AS most_decorated_athlete, medals AS max_medals
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY country_code ORDER BY medals DESC) AS rn
        FROM athlete_medal_count
    ) t
    WHERE rn = 1
)
SELECT
    cm.country_code,
    cm.medal_count AS total_medals,
    um.unique_athletes,
    COALESCE(ROUND((t10.top_10_medals * 1.0 / cm.medal_count) * 100, 2), 0) AS top_10_share_pct,
    md.most_decorated_athlete,
    md.max_medals AS most_decorated_medal_count
FROM country_medal cm
JOIN unique_medalist um ON cm.country_code = um.country_code
LEFT JOIN top_10_share t10 ON cm.country_code = t10.country_code
LEFT JOIN most_decorated md ON cm.country_code = md.country_code
ORDER BY cm.medal_count DESC;

