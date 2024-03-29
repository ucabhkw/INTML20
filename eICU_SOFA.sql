--IMPORTANT: Please note that there are some possible issues.
--This code is based on code by Matthieu and Michael and others, with changes to allow it to be used 
--Thanks to Matthieu, Michael and Mornin! 
--https://github.com/nus-mornin-lab/oxygenation_kc/blob/master/data-extraction/eICU/eicu_sofa_results.sql
--The code has been translated into Bigquery for the AKI study.


WITH 
pat AS (
SELECT * FROM `mimiciii-250307.eicucrd.patient`),

cohort1 AS (
SELECT * FROM `mimiciii-250307.view_aki_eicucrd.cohort1`),
--To try to hold a small dataset, we merged the dataset with the following tables first.

lab AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.lab` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

vitalperiodic AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.vitalPeriodic` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

vitalaperiodic AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.vitalAperiodic` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

infusiondrug AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.infusionDrug` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

respiratorycare AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.respiratoryCare` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

treatment AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.treatment` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

careplangeneral AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.carePlanGeneral` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

physicalexam AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.physicalExam` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

chart AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.nurseCharting` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

intakeoutput AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.intakeOutput` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id),

respchart AS (
SELECT A.* FROM `mimiciii-250307.eicucrd.respiratoryCharting` AS A
inner join cohort1 on A.patientUnitStayID = cohort1.icustay_id ),

-- MAP
t1 as -- MAP
(
select pt.patientunitstayid, 
case when tt1.map is not null then tt1.map
	 else tt2.map end as map
from pat pt
left outer join (
	select patientunitstayid, min( case when noninvasivemean is not null then noninvasivemean else null end) as map
	from vitalaperiodic
	where observationoffset between -1440 and 1440
	group by patientunitstayid
	) tt1
on tt1.patientunitstayid=pt.patientunitstayid
left outer join (
	select patientunitstayid, min( case when systemicmean is not null then systemicmean else null end) as map
	from vitalperiodic
	where observationoffset between -1440 and 1440
	group by patientunitstayid
	) tt2
on tt2.patientunitstayid=pt.patientunitstayid
order by pt.patientunitstayid
),

t2 as --DOPAMINE
(
select distinct  patientunitstayid, 
	max(case when lower(drugname) like '%(ml/hr)%' then round(cast(drugrate as numeric)/3,3) 
			 when lower(drugname) like '%(mcg/kg/min)%' then cast(drugrate as numeric)
		else null end ) as dopa
from infusiondrug id
where lower(drugname) like '%dopamine%' and infusionoffset between -120 and 1440 
	and REGEXP_CONTAINS(drugrate, '^[0-9]{0,5}$') and drugrate<>'' and drugrate<>'.'
group by patientunitstayid
), 

t3 as  --NOREPI
(
select distinct patientunitstayid, 
	max(case when lower(drugname) like '%(ml/hr)%' and drugrate<>''  and drugrate<>'.' then round(cast(drugrate as numeric)/300,3) 
			 when lower(drugname) like '%(mcg/min)%' and drugrate<>'' and drugrate<>'.'  then round(cast(drugrate as numeric)/80 ,3)-- divide by 80 kg
			 when lower(drugname) like '%(mcg/kg/min)%' and drugrate<>'' and drugrate<>'.' then cast(drugrate as numeric)
		else null end ) as norepi
from infusiondrug id
where lower(drugname) like '%norepinephrine%'  and infusionoffset between -120 and 1440  
	and REGEXP_CONTAINS(drugrate, '^[0-9]{0,5}$') and drugrate<>'' and drugrate<>'.'
group by patientunitstayid
), 

t4 as  --DOBUTAMINE
(
select distinct patientunitstayid, 1 as dobu
from infusiondrug id
where lower(drugname) like '%dobutamin%' and drugrate <>'' and drugrate<>'.' and drugrate <>'0' 
	and REGEXP_CONTAINS(drugrate, '^[0-9]{0,5}$') and infusionoffset between -120 and 1440
),

sofacv as
(
select pt.icustay_id, t1.map, t2.dopa, t3.norepi, t4.dobu,
(case when dopa>=15 or norepi>0.1 then 4
	  when dopa>5 or (norepi>0 and norepi <=0.1) then 3
	  when dopa<=5 or dobu > 0 then 2
	  when map <70 then 1
	  else 0 end) as SOFA_cv --COMPUTE SOFA CV
from cohort1 pt
left outer join t1
on t1.patientunitstayid=pt.icustay_id
left outer join t2
on t2.patientunitstayid=pt.icustay_id
left outer join t3
on t3.patientunitstayid=pt.icustay_id
left outer join t4
on t4.patientunitstayid=pt.icustay_id
),

-- SOFA-RESPI
sofarespi as
(
with tempo2 as 
(
with tempo1 as
(
with t1 as --FIO2 from respchart
(
select *
from
(
select distinct patientunitstayid, max(cast(respchartvalue as numeric)) as rcfio2
-- , max(case when respchartvaluelabel = 'FiO2' then respchartvalue else null end) as fiO2
from respchart
where respchartoffset between -120 and 1440 and respchartvalue <> '' and REGEXP_CONTAINS(respchartvalue, '^[0-9]{0,2}$')
group by patientunitstayid
) as tempo
where rcfio2 >20 -- many values are liters per minute!
order by patientunitstayid


), 

t2 as --FIO2 from nursecharting
(
select distinct patientunitstayid, max(cast(nursingchartvalue as numeric)) as ncfio2
from chart nc
where lower(nursingchartcelltypevallabel) like '%fio2%' and REGEXP_CONTAINS(nursingchartvalue, '^[0-9]{0,2}$') and nursingchartentryoffset between -120 and 1440
group by patientunitstayid


), 

t3 as --sao2 from vitalperiodic
(
select patientunitstayid,
min( case when sao2 is not null then sao2 else null end) as sao2
from vitalperiodic
where observationoffset between -1440 and 1440
group by patientunitstayid


), 

t4 as --pao2 from lab
(
select patientunitstayid,
min(case when lower(labname) like 'pao2%' then labresult else null end) as pao2
from lab
where labresultoffset between -1440 and 1440
group by patientunitstayid


), 

t5 as --airway type combining 3 sources (1=invasive)
(


with t1 as --airway type from respcare (1=invasive) (by resp therapist!!)
(
select distinct patientunitstayid,
max(case when airwaytype in ('Oral ETT','Nasal ETT','Tracheostomy') then 1 else NULL end) as airway  -- either invasive airway or NULL
from respiratorycare
where respcarestatusoffset between -1440 and 1440

group by patientunitstayid
),


t2 as --airway type from respcharting (1=invasive)
(
select distinct patientunitstayid, 1 as ventilator
from respchart rc
where respchartvalue like '%ventilator%'
or respchartvalue like '%vent%'
or respchartvalue like '%bipap%'
or respchartvalue like '%840%'
or respchartvalue like '%cpap%'
or respchartvalue like '%drager%'
or respchartvalue like 'mv%'
or respchartvalue like '%servo%'
or respchartvalue like '%peep%'
and respchartoffset between -1440 and 1440
group by patientunitstayid
-- order by patientunitstayid
),


t3 as --airway type from treatment (1=invasive)


(
select distinct patientunitstayid, max(case when treatmentstring in
('pulmonary|ventilation and oxygenation|mechanical ventilation',
'pulmonary|ventilation and oxygenation|tracheal suctioning',
'pulmonary|ventilation and oxygenation|ventilator weaning',
'pulmonary|ventilation and oxygenation|mechanical ventilation|assist controlled',
'pulmonary|radiologic procedures / bronchoscopy|endotracheal tube',
'pulmonary|ventilation and oxygenation|oxygen therapy (> 60%)',
'pulmonary|ventilation and oxygenation|mechanical ventilation|tidal volume 6-10 ml/kg',
'pulmonary|ventilation and oxygenation|mechanical ventilation|volume controlled',
'surgery|pulmonary therapies|mechanical ventilation',
'pulmonary|surgery / incision and drainage of thorax|tracheostomy',
'pulmonary|ventilation and oxygenation|mechanical ventilation|synchronized intermittent',
'pulmonary|surgery / incision and drainage of thorax|tracheostomy|performed during current admission for ventilatory support',
'pulmonary|ventilation and oxygenation|ventilator weaning|active',
'pulmonary|ventilation and oxygenation|mechanical ventilation|pressure controlled',
'pulmonary|ventilation and oxygenation|mechanical ventilation|pressure support',
'pulmonary|ventilation and oxygenation|ventilator weaning|slow',
'surgery|pulmonary therapies|ventilator weaning',
'surgery|pulmonary therapies|tracheal suctioning',
'pulmonary|radiologic procedures / bronchoscopy|reintubation',
'pulmonary|ventilation and oxygenation|lung recruitment maneuver',
'pulmonary|surgery / incision and drainage of thorax|tracheostomy|planned',
'surgery|pulmonary therapies|ventilator weaning|rapid',
'pulmonary|ventilation and oxygenation|prone position',
'pulmonary|surgery / incision and drainage of thorax|tracheostomy|conventional',
'pulmonary|ventilation and oxygenation|mechanical ventilation|permissive hypercapnea',
'surgery|pulmonary therapies|mechanical ventilation|synchronized intermittent',
'pulmonary|medications|neuromuscular blocking agent',
'surgery|pulmonary therapies|mechanical ventilation|assist controlled',
'pulmonary|ventilation and oxygenation|mechanical ventilation|volume assured',
'surgery|pulmonary therapies|mechanical ventilation|tidal volume 6-10 ml/kg',
'surgery|pulmonary therapies|mechanical ventilation|pressure support',
'pulmonary|ventilation and oxygenation|non-invasive ventilation',
'pulmonary|ventilation and oxygenation|non-invasive ventilation|face mask',
'pulmonary|ventilation and oxygenation|non-invasive ventilation|nasal mask',
'pulmonary|ventilation and oxygenation|mechanical ventilation|non-invasive ventilation',
'pulmonary|ventilation and oxygenation|mechanical ventilation|non-invasive ventilation|face mask',
'surgery|pulmonary therapies|non-invasive ventilation',
'surgery|pulmonary therapies|non-invasive ventilation|face mask',
'pulmonary|ventilation and oxygenation|mechanical ventilation|non-invasive ventilation|nasal mask',
'surgery|pulmonary therapies|non-invasive ventilation|nasal mask',
'surgery|pulmonary therapies|mechanical ventilation|non-invasive ventilation',
'surgery|pulmonary therapies|mechanical ventilation|non-invasive ventilation|face mask'
) then 1  else NULL end) as interface   -- either ETT/NiV or NULL
from treatment
where treatmentoffset between -1440 and 1440
group by patientunitstayid-- , treatmentoffset, interface
order by patientunitstayid-- , treatmentoffset
)

select pt.icustay_id,
case when t1.airway is not null or t2.ventilator is not null or t3.interface is not null then 1 
	else null end as mechvent --summarize
from cohort1 pt
left outer join t1
on t1.patientunitstayid=pt.icustay_id
left outer join t2
on t2.patientunitstayid=pt.icustay_id
left outer join t3
on t3.patientunitstayid=pt.icustay_id

)


select pt.icustay_id, t3.sao2, t4.pao2, 
(case when t1.rcfio2>20 then t1.rcfio2 when t2.ncfio2 >20 then t2.ncfio2  when t1.rcfio2=1 or t2.ncfio2=1 then 100 else null end) as fio2, t5.mechvent
from cohort1 pt
left outer join t1
on t1.patientunitstayid=pt.icustay_id
left outer join t2
on t2.patientunitstayid=pt.icustay_id
left outer join t3
on t3.patientunitstayid=pt.icustay_id
left outer join t4
on t4.patientunitstayid=pt.icustay_id
left outer join t5
on t5.icustay_id=pt.icustay_id
-- order by pt.patientunitstayid
)


select *, -- coalesce(fio2,nullif(fio2,0),21) as fn, nullif(fio2,0) as nullifzero, coalesce(coalesce(nullif(fio2,0),21),fio2,21) as ifzero21 ,
coalesce(pao2,100)/coalesce(coalesce(nullif(fio2,0),21),fio2,21) as pf, coalesce(sao2,100)/coalesce(coalesce(nullif(fio2,0),21),fio2,21) as sf
from tempo1
)


select icustay_id, 
(case when pf <1 or sf <0.67 then 4  --COMPUTE SOFA RESPI
when pf between 1 and 2 or sf between 0.67 and 1.41 then 3
when pf between 2 and 3 or sf between 1.42 and 2.2 then 2
when pf between 3 and 4 or sf between 2.21 and 3.01 then 1
when pf > 4 or sf> 3.01 then 0 else 0 end ) as SOFA_respi
from tempo2
order by icustay_id
),


-- SOFA-RENAL


sofarenal as
(
with t1 as --CREATININE
(
select pt.patientunitstayid,
max(case when lower(labname) like 'creatin%' then labresult else null end) as creat
from pat pt
left outer join lab
on pt.patientunitstayid=lab.patientunitstayid
where labresultoffset between -1440 and 1440
group by pt.patientunitstayid


),

t2 as --UO
(


with uotemp as
(
select patientunitstayid,
case when dayz=1 then sum(outputtotal) else null end as uod1
from
(


select distinct patientunitstayid, intakeoutputoffset, outputtotal,
(CASE
WHEN  (intakeoutputoffset) between -120 and 1440 THEN 1
else null
end) as dayz
from intakeoutput
where intakeoutputoffset between 0 and 5760
order by patientunitstayid, intakeoutputoffset


) as temp
group by patientunitstayid, temp.dayz
)


select pt.patientunitstayid,
max(case when uod1 is not null then uod1 else null end) as UO
from pat pt
left outer join uotemp
on uotemp.patientunitstayid=pt.patientunitstayid
group by pt.patientunitstayid


)


select pt.icustay_id, -- t1.creat, t2.uo,
(case --COMPUTE SOFA RENAL
when uo <200 or creat>5 then 4
when uo <500 or creat >3.5 then 3
when creat between 2 and 3.5 then 2
when creat between 1.2 and 2 then 1
else 0
end) as sofarenal
from cohort1 pt
left outer join t1
on t1.patientunitstayid=pt.icustay_id
left outer join t2
on t2.patientunitstayid=pt.icustay_id
order by pt.icustay_id
-- group by pt.patientunitstayid, t1.creat, t2.uo


),


-- SOFA- GCS, liver, platelets


sofa3others as
(
with t1 as --GCS
(
select patientunitstayid, sum(cast(physicalexamvalue as numeric)) as gcs
from physicalexam pe
where (lower(physicalexampath) like '%gcs/eyes%'
or lower(physicalexampath) like '%gcs/verbal%'
or lower(physicalexampath) like '%gcs/motor%')
and physicalexamoffset between -1440 and 1440
group by patientunitstayid--, physicalexamoffset
), t2 as
(
select pt.patientunitstayid,
max(case when lower(labname) like 'total bili%' then labresult else null end) as bili, --BILI
min(case when lower(labname) like 'platelet%' then labresult else null end) as plt --PLATELETS
from pat pt
left outer join lab
on pt.patientunitstayid=lab.patientunitstayid
where labresultoffset between -1440 and 1440
group by pt.patientunitstayid
)


select distinct pt.icustay_id, min(t1.gcs) as gcs, max(t2.bili) as bili, min(t2.plt) as plt,
max(case when plt<20 then 4
when plt<50 then 3
when plt<100 then 2
when plt<150 then 1
else 0 end) as sofacoag,
max(case when bili>12 then 4
when bili>6 then 3
when bili>2 then 2
when bili>1.2 then 1
else 0 end) as sofaliver,
max(case when gcs=15 then 0
when gcs>=13 then 1
when gcs>=10 then 2
when gcs>=6 then 3
when gcs>=3 then 4
else 0 end) as sofacns
from cohort1 pt
left outer join t1
on t1.patientunitstayid=pt.icustay_id
left outer join t2
on t2.patientunitstayid=pt.icustay_id
group by pt.icustay_id, t1.gcs, t2.bili, t2.plt
order by pt.icustay_id
)


-- SOFA: COMBINE ALL SUBSCORES 


Select pt.icustay_id, --  sofacv.sofa_cv, sofarespi.sofa_respi,sofarenal.sofarenal,sofa3others.sofacoag,sofa3others.sofaliver,sofa3others.sofacns, 
sofacv.sofa_cv+sofarespi.sofa_respi+ sofarenal.sofarenal+sofa3others.sofacoag+ sofa3others.sofaliver+sofa3others.sofacns as sofatotal
From cohort1 pt
Left outer join sofacv
On pt.icustay_id=sofacv.icustay_id
Left outer join sofarespi
On pt.icustay_id= sofarespi.icustay_id
Left outer join sofarenal
On pt.icustay_id= sofarenal.icustay_id
Left outer join sofa3others
On pt.icustay_id= sofa3others.icustay_id

