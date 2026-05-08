create table t (i int, t text, flag boolean);
insert into t values (1, 'hello', true), (2, 'world', false), (null, 'null', null);
select i, t, flag from t;
select i, t, flag from t where i > 1;
select i, t, flag from t where i is not null;
