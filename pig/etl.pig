-- ***************************************************************************
-- TASK
-- Aggregate events into features of patient and generate training, testing data for mortality prediction.
-- Steps have been provided to guide you.
-- You can include as many intermediate steps as required to complete the calculations.
-- ***************************************************************************

-- ***************************************************************************
-- TESTS
-- To test, please change the LOAD path for events and mortality to ../../test/events.csv and ../../test/mortality.csv
-- 6 tests have been provided to test all the subparts in this exercise.
-- Manually compare the output of each test against the csv's in test/expected folder.
-- ***************************************************************************

-- register a python UDF for converting data into SVMLight format
REGISTER utils.py USING jython AS utils;

-- load events file
events = LOAD '../../data/events.csv' USING PigStorage(',') AS (patientid:int, eventid:chararray, eventdesc:chararray, timestamp:chararray, value:float);

-- select required columns from events
events = FOREACH events GENERATE patientid, eventid, ToDate(timestamp, 'yyyy-MM-dd') AS etimestamp, value;

-- load mortality file
mortality = LOAD '../../data/mortality.csv' USING PigStorage(',') as (patientid:int, timestamp:chararray, label:int);

mortality = FOREACH mortality GENERATE patientid, ToDate(timestamp, 'yyyy-MM-dd') AS mtimestamp, label;

--To display the relation, use the dump command e.g. DUMP mortality;

-- ***************************************************************************
-- Compute the index dates for dead and alive patients
-- ***************************************************************************
eventswithmort = JOIN events BY patientid FULL OUTER, mortality by patientid;
deadevents = FILTER eventswithmort BY mortality::label == 1;

deadevents = FOREACH deadevents
             GENERATE events::patientid as patientid,
                      events::eventid as eventid,
                      events::value as value,
                      mortality::label as label,
                      events::etimestamp as etime,
                      mortality::mtimestamp as mtime;

deadgroups = GROUP deadevents BY patientid;
deadevents = FOREACH deadgroups {
               GENERATE FLATTEN(deadevents) as (patientid, eventid, value, label,
               etime, mtime), SubtractDuration(MAX(deadevents.mtime), 'P30D') as index,
               SubtractDuration(MAX(deadevents.mtime), 'P2030D') as start;
               };

deadevents = FILTER deadevents BY (etime >= start) AND (etime <= index);

deadevents = FOREACH deadevents
             GENERATE patientid, eventid, value, label, DaysBetween(index,
             etime) as time_difference;

aliveevents = FILTER eventswithmort BY mortality::label is null;
aliveevents = FOREACH aliveevents
             GENERATE events::patientid as patientid,
                      events::eventid as eventid,
                      events::value as value,
                      0 as label,
                      events::etimestamp as etime;

alivegroups = GROUP aliveevents BY patientid;
aliveevents = FOREACH alivegroups {
               GENERATE FLATTEN(aliveevents) as (patientid, eventid, value, label,
               etime), MAX(aliveevents.etime) as index,
               SubtractDuration(MAX(aliveevents.etime), 'P2000D') as start;
               };

aliveevents = FILTER aliveevents BY (etime >= start) AND (etime <= index);

aliveevents = FOREACH aliveevents
             GENERATE patientid, eventid, value, label, DaysBetween(index,
             etime) as time_difference;

--TEST-1
deadevents = ORDER deadevents BY patientid, eventid;
aliveevents = ORDER aliveevents BY patientid, eventid;
STORE aliveevents INTO 'aliveevents' USING PigStorage(',');
STORE deadevents INTO 'deadevents' USING PigStorage(',');

-- ***************************************************************************
-- Filter events within the observation window and remove events with missing values
-- ***************************************************************************
filtered = UNION aliveevents, deadevents;

--TEST-2
filteredgrpd = GROUP filtered BY 1;
filtered = FOREACH filteredgrpd GENERATE FLATTEN(filtered);
filtered = ORDER filtered BY patientid, eventid,time_difference;
STORE filtered INTO 'filtered' USING PigStorage(',');

-- ***************************************************************************
-- Aggregate events to create features
-- ***************************************************************************
filteredgrpd = GROUP filtered BY (patientid, eventid);
featureswithid = FOREACH filteredgrpd GENERATE FLATTEN(group) AS (patientid, eventid),
                 COUNT(filtered.eventid) as featurevalue;
--TEST-3
featureswithid = ORDER featureswithid BY patientid, eventid;
STORE featureswithid INTO 'features_aggregate' USING PigStorage(',');

-- ***************************************************************************
-- Generate feature mapping
-- ***************************************************************************
all_features = FOREACH featureswithid GENERATE eventid;
all_features = DISTINCT all_features;
all_features = RANK all_features by eventid ASC;
all_features = FOREACH all_features GENERATE rank_all_features AS idx,  eventid;

-- store the features as an output file
STORE all_features INTO 'features' using PigStorage(' ');
features = JOIN featureswithid BY eventid FULL OUTER, all_features BY eventid;
features = FOREACH features GENERATE featureswithid::patientid as patientid,
                                     all_features::idx as idx,
                                     featureswithid::featurevalue AS featurevalue;
--TEST-4
features = ORDER features BY patientid, idx;
STORE features INTO 'features_map' USING PigStorage(',');

-- ***************************************************************************
-- Normalize the values using min-max normalization
-- Use DOUBLE precision
-- ***************************************************************************
idxgroups = GROUP features BY idx;
maxvalues = FOREACH idxgroups GENERATE FLATTEN(group) AS idx, (float)MAX(features.featurevalue) AS maxvalues;

normalized = JOIN features BY idx, maxvalues BY idx;

features = FOREACH normalized GENERATE features::patientid AS patientid,
                                       features::idx as idx,
                                       (float)features::featurevalue/maxvalues::maxvalues AS normalizedfeaturevalue;

--TEST-5
features = ORDER features BY patientid, idx;
STORE features INTO 'features_normalized' USING PigStorage(',');

-- ***************************************************************************
-- Generate features in svmlight format
-- features is of the form (patientid, idx, normalizedfeaturevalue) and is the output of the previous step
-- e.g.  1,1,1.0
--  	 1,3,0.8
--	     2,1,0.5
--       3,3,1.0
-- ***************************************************************************

grpd = GROUP features BY patientid;
grpd_order = ORDER grpd BY $0;
features = FOREACH grpd_order
{
    sorted = ORDER features BY idx;
    generate group as patientid, utils.bag_to_svmlight(sorted) as sparsefeature;
}

-- ***************************************************************************
-- Split into train and test set
-- labels is of the form (patientid, label) and contains all patientids followed by label of 1 for dead and 0 for alive
-- e.g. 1,1
--	2,0
--      3,1
-- ***************************************************************************

labels = FOREACH filtered GENERATE patientid, label;
DESCRIBE labels;

--Generate sparsefeature vector relation
samples = JOIN features BY patientid, labels BY patientid;
samples = DISTINCT samples PARALLEL 1;
samples = ORDER samples BY $0;
samples = FOREACH samples GENERATE $3 AS label, $1 AS sparsefeature;

--TEST-6
STORE samples INTO 'samples' USING PigStorage(' ');

-- randomly split data for training and testing
DEFINE rand_gen RANDOM('6505');
samples = FOREACH samples GENERATE rand_gen() as assignmentkey, *;
SPLIT samples INTO testing IF assignmentkey <= 0.20, training OTHERWISE;
training = FOREACH training GENERATE $1..;
testing = FOREACH testing GENERATE $1..;

-- save training and tesing data
STORE testing INTO 'testing' USING PigStorage(' ');
STORE training INTO 'training' USING PigStorage(' ');
