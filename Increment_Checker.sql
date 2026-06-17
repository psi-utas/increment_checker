    -- Maruf, Sebgatullah 03013553
    -- Dynamically define all key reference dates for the increment cycle
    -- previous_increment : last March cycle (eligibility baseline history)
    -- step_eligibility_date: 1 September (must remain unchanged after this)
    -- increment: current March increment period being assessed


;WITH params AS (
    SELECT
        CAST(DATEFROMPARTS(YEAR(GETDATE())-1, 3, 1) AS date) AS previous_increment_start,
        CAST(DATEFROMPARTS(YEAR(GETDATE())-1, 3, 31) AS date) AS previous_increment_end,
        CAST(DATEFROMPARTS(YEAR(GETDATE())-1, 9, 1) AS date) AS step_eligibility_date,
        CAST(DATEFROMPARTS(YEAR(GETDATE()), 3, 1) AS date) AS increment_start,
        CAST(DATEFROMPARTS(YEAR(GETDATE()), 3, 31) AS date) AS increment_end
),


   -- Deduplicate HR_JOBS by keeping the latest effective sequence per day
    -- Ensures we only use the final state for any effective-dated row
    -- Also limits dataset to the relevant audit period to improve performance

job_latest AS (
    SELECT *
    FROM (
        SELECT
            h.*,
            ROW_NUMBER() OVER (
                PARTITION BY h.EMPLID, h.EMPL_RCD, h.EFFECTIVE_DATE
                ORDER BY h.EFFECTIVE_SEQ DESC
            ) AS job_date_seq_rank
        FROM data_mart.[HR_JOBS] h
        CROSS JOIN params p
        WHERE h.EFFECTIVE_DATE >= p.previous_increment_start
          AND h.EFFECTIVE_DATE <= p.increment_end
    ) x
    WHERE x.job_date_seq_rank = 1
),

    -- This helps detect if a condition (e.g. payroll status S)
    -- existed across a time interval, not just on a single date

job_ranges AS (
    SELECT
        j.*,
        LEAD(j.EFFECTIVE_DATE) OVER (
            PARTITION BY j.EMPLID, j.EMPL_RCD
            ORDER BY j.EFFECTIVE_DATE
        ) AS next_effective_date
    FROM job_latest j
),

    -- Identify employees who were EVER in payroll status 'S'
    -- between September (eligibility) and March (increment)
    -- These employees are excluded from increment eligibility

payroll_status_s_between AS (
    SELECT DISTINCT
        jr.EMPLID,
        jr.EMPL_RCD
    FROM job_ranges jr
    CROSS JOIN params p
    WHERE UPPER(LTRIM(RTRIM(jr.PAYROLL_STATUS))) = 'S'
      AND jr.EFFECTIVE_DATE <= p.increment_end
      AND COALESCE(jr.next_effective_date, '9999-12-31') > p.step_eligibility_date
),

    -- Snapshot as at end of previous March cycle
    -- Used for audit reference only (not filtering)
    -- Helps explain historical increment position if needed

march_2025_snapshot AS (
    SELECT *
    FROM (
        SELECT j.*,
            ROW_NUMBER() OVER (
                PARTITION BY j.EMPLID, j.EMPL_RCD
                ORDER BY j.EFFECTIVE_DATE DESC, j.EFFECTIVE_SEQ DESC
            ) AS march_2025_rank
        FROM job_latest j
        CROSS JOIN params p
        WHERE j.EFFECTIVE_DATE <= p.previous_increment_end
    ) x
    WHERE march_2025_rank = 1
),

    -- Snapshot at 1 September (eligibility checkpoint)
    -- Employees must remain on same step/grade/plan after this date
    -- Any change after this point makes them ineligible

sept_2025_snapshot AS (
    SELECT *
    FROM (
        SELECT j.*,
            ROW_NUMBER() OVER (
                PARTITION BY j.EMPLID, j.EMPL_RCD
                ORDER BY j.EFFECTIVE_DATE DESC, j.EFFECTIVE_SEQ DESC
            ) AS sept_rank
        FROM job_latest j
        CROSS JOIN params p
        WHERE j.EFFECTIVE_DATE <= p.step_eligibility_date
    ) x
    WHERE sept_rank = 1
),

    -- Latest job record BEFORE March (increment processing)
    -- This is the baseline state used for comparison
    -- Represents employee position just before increment should occur

pre_march_snapshot AS (
    SELECT *
    FROM (
        SELECT j.*,
            ROW_NUMBER() OVER (
                PARTITION BY j.EMPLID, j.EMPL_RCD
                ORDER BY j.EFFECTIVE_DATE DESC, j.EFFECTIVE_SEQ DESC
            ) AS pre_march_rank
        FROM job_latest j
        CROSS JOIN params p
        WHERE j.EFFECTIVE_DATE < p.increment_start
    ) x
    WHERE pre_march_rank = 1
),


    -- Latest job record up to end of March
    -- Used to check if step has increased (increment outcome)

end_march_snapshot AS (
    SELECT *
    FROM (
        SELECT j.*,
            ROW_NUMBER() OVER (
                PARTITION BY j.EMPLID, j.EMPL_RCD
                ORDER BY j.EFFECTIVE_DATE DESC, j.EFFECTIVE_SEQ DESC
            ) AS end_march_rank
        FROM job_latest j
        CROSS JOIN params p
        WHERE j.EFFECTIVE_DATE <= p.increment_end
    ) x
    WHERE end_march_rank = 1
),

    -- Identify any change in salary plan, grade, or step
    -- AFTER September but BEFORE March
    -- These changes break eligibility and are excluded


post_sept_grade_step_changes AS (
    SELECT DISTINCT j.EMPLID, j.EMPL_RCD
    FROM job_latest j
    JOIN sept_2025_snapshot sep
        ON j.EMPLID = sep.EMPLID
       AND j.EMPL_RCD = sep.EMPL_RCD
    CROSS JOIN params p
    WHERE j.EFFECTIVE_DATE > p.step_eligibility_date
      AND j.EFFECTIVE_DATE < p.increment_start
      AND (
            ISNULL(j.SAL_ADMIN_PLAN,'') <> ISNULL(sep.SAL_ADMIN_PLAN,'')
         OR ISNULL(j.GRADE,'') <> ISNULL(sep.GRADE,'')
         OR ISNULL(j.STEP,'') <> ISNULL(sep.STEP,'')
      )
),

    -- Identify salary plan or grade changes during March
    -- Step change is allowed (expected increment outcome)
    -- But grade/plan change invalidates increment scenario

march_grade_plan_changes AS (
    SELECT DISTINCT j.EMPLID, j.EMPL_RCD
    FROM job_latest j
    JOIN pre_march_snapshot pre
        ON j.EMPLID = pre.EMPLID
       AND j.EMPL_RCD = pre.EMPL_RCD
    CROSS JOIN params p
    WHERE j.EFFECTIVE_DATE BETWEEN p.increment_start AND p.increment_end
      AND (
            ISNULL(j.SAL_ADMIN_PLAN,'') <> ISNULL(pre.SAL_ADMIN_PLAN,'')
         OR ISNULL(j.GRADE,'') <> ISNULL(pre.GRADE,'')
      )
),


    -- Exclude employees terminated or suspended during March
    -- These employees are not expected to receive increment

march_exclusions AS (
    SELECT DISTINCT j.EMPLID, j.EMPL_RCD
    FROM job_latest j
    CROSS JOIN params p
    WHERE j.EFFECTIVE_DATE BETWEEN p.increment_start AND p.increment_end
      AND (
            UPPER(j.ACTION_DESC) LIKE 'TERMINATION%'
         OR UPPER(j.ACTION_DESC) LIKE 'SUSPENSION%'
      )
),


    -- Get latest valid salary plan configuration
    -- Needed to determine maximum step per grade

salary_plan_latest AS (
    SELECT *
    FROM (
        SELECT s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.SAL_ADMIN_PLAN, s.GRADE, s.STEP
                ORDER BY s.EFFDT DESC
            ) AS salary_plan_rank
        FROM [PWB_PeopleAnalytics].[data_mart].[HR_SALARY_PLANS] s
        CROSS JOIN params p
        WHERE s.EFFDT <= p.increment_start
          AND UPPER(s.STATUS) = 'A'
    ) x
    WHERE salary_plan_rank = 1
),

    -- Calculate maximum step per salary plan and grade
    -- Used to exclude employees already at top step (no further increment poss

max_step_by_grade AS (
    SELECT SAL_ADMIN_PLAN, GRADE,
           MAX(TRY_CONVERT(int, STEP)) AS max_step
    FROM salary_plan_latest
    GROUP BY SAL_ADMIN_PLAN, GRADE
),

    -- Calculate total unpaid leave (WOP) hours in the eligibility window
    -- This does NOT exclude employees
    -- It is used only to ex

unpaid_leave_summary AS (
    SELECT
        l.EMPLID,
        l.EMPL_RCD,
        SUM(COALESCE(l.ALL_DAYS_HOURS,0)) AS total_wop_hours
    FROM [PWB_PeopleAnalytics].[data_mart].[HR_LEAVE] l
    CROSS JOIN params p
    WHERE UPPER(l.ABSENCE_NAME) LIKE '%WOP%'
      AND l.START_DATE <= p.increment_end
      AND l.END_DATE >= p.step_eligibility_date
      AND COALESCE(l.VOIDED,'N') <> 'Y'
    GROUP BY l.EMPLID, l.EMPL_RCD
),


-- Lists Eligible Employees

eligible_population AS (
    SELECT
        pre.*,
        endm.STEP AS end_march_step,
        endm.GRADE AS end_march_grade,
        m.max_step,
        ul.total_wop_hours
    FROM pre_march_snapshot pre

    JOIN sept_2025_snapshot sep
        ON pre.EMPLID = sep.EMPLID
       AND pre.EMPL_RCD = sep.EMPL_RCD

    LEFT JOIN end_march_snapshot endm
        ON pre.EMPLID = endm.EMPLID
       AND pre.EMPL_RCD = endm.EMPL_RCD

    LEFT JOIN max_step_by_grade m
        ON pre.SAL_ADMIN_PLAN = m.SAL_ADMIN_PLAN
       AND pre.GRADE = m.GRADE

    LEFT JOIN unpaid_leave_summary ul
        ON pre.EMPLID = ul.EMPLID
       AND pre.EMPL_RCD = ul.EMPL_RCD

    LEFT JOIN payroll_status_s_between ps
        ON pre.EMPLID = ps.EMPLID
       AND pre.EMPL_RCD = ps.EMPL_RCD

    LEFT JOIN post_sept_grade_step_changes chg
        ON pre.EMPLID = chg.EMPLID
       AND pre.EMPL_RCD = chg.EMPL_RCD

    LEFT JOIN march_grade_plan_changes mgc
        ON pre.EMPLID = mgc.EMPLID
       AND pre.EMPL_RCD = mgc.EMPL_RCD

    WHERE 1=1

      AND UPPER(pre.SAL_ADMIN_PLAN) NOT IN ('SMCP','ELTA')

      AND pre.HR_STATUS = 'A'
      AND sep.HR_STATUS = 'A'

      AND COALESCE(pre.PAYROLL_STATUS,'') NOT IN ('T','S')
      AND COALESCE(sep.PAYROLL_STATUS,'') NOT IN ('T','S')

      AND COALESCE(pre.HONORARY_FLAG,'N') <> 'Y'

      AND UPPER(pre.EMPL_CLASS_DESC) IN (
            'AVRG SERVE FRACTION-FIXEDTERM',
            'CONTINUING',
            'CONTINUING - PROBATIONARY',
            'CONTINUING CONTINGENT FUNDED',
            'CONTINUING EST - PROBATIONARY',
            'CONTINUING ESTABLISHMENT',
            'FIXED-TERM - FLEX WORK ARRANGE',
            'FIXED-TERM (ARC FUNDED)',
            'FIXED-TERM (CONTRACT)',
            'FIXED-TERM EST (CONTRACT)',
            'FIXED-TERM HIGHER DUTIES ALLOW',
            'FIXED-TERM PROBATIONARY',
            'GRADUATE TEACHING FELLOW',
            'NEWLY CREATED ACADEMIC'
      )

      AND ISNULL(pre.SAL_ADMIN_PLAN,'') = ISNULL(sep.SAL_ADMIN_PLAN,'')
      AND ISNULL(pre.GRADE,'') = ISNULL(sep.GRADE,'')
      AND ISNULL(pre.STEP,'') = ISNULL(sep.STEP,'')

      AND COALESCE(pre.LAST_START_DATE,pre.ORIGINAL_START_DATE) <= DATEFROMPARTS(YEAR(GETDATE())-1,9,1)

      AND ps.EMPLID IS NULL
      AND chg.EMPLID IS NULL
      AND mgc.EMPLID IS NULL

      AND (
            m.max_step IS NULL
         OR TRY_CONVERT(int, pre.STEP) < m.max_step
      )
      AND TRY_CONVERT(int, pre.STEP) > 0
)

--table to display result
SELECT
    e.EMPLID,
    e.EMPL_RCD,
    e.POSITION_NBR,
    e.POSITION_TITLE,
    e.EMPL_CATEGORY_DESCR,

    e.EFFECTIVE_DATE AS PRE_MARCH_EFF_DATE,
    e.GRADE,
    e.STEP,

    e.end_march_grade AS END_MARCH_GRADE,
    e.end_march_step AS END_MARC_STEP,

    e.max_step AS MAX_STEP,

    e.total_wop_hours AS TOTAL_WOP_HOURS,

    CASE
        WHEN TRY_CONVERT(int, e.end_march_step) <= TRY_CONVERT(int, e.STEP)
             AND COALESCE(e.total_wop_hours,0) >= 76
            THEN 'Missed Increment + LWOP > 2 weeks'
        WHEN TRY_CONVERT(int, e.end_march_step) <= TRY_CONVERT(int, e.STEP)
            THEN 'Missed Increment (No LWOP)'
        ELSE 'OK'
    END AS AUDIT_REASON

FROM eligible_population e

LEFT JOIN march_exclusions mx
    ON e.EMPLID = mx.EMPLID
   AND e.EMPL_RCD = mx.EMPL_RCD

WHERE mx.EMPLID IS NULL
  AND TRY_CONVERT(int, e.end_march_step) <= TRY_CONVERT(int, e.STEP)

ORDER BY AUDIT_REASON

OPTION (RECOMPILE);
