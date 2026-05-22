create table t (i int, j int, k int, name text);
create index t_idx on t (i, j);
insert into t values (1, 1, 2, '1+1 = 2'), (1, 2, 3, '1+2 = 3'), (1, 3, 4, '1+3 = 4'), (2, 2, 4, '2+2 = 4'), (2, 3, 5, '2+3 = 5'), (3, 3, 6, '3+3 = 6'), (10, 20, 30, '10+20 = 30');

select name from t where i = 2;
select name from t where i >= 2;
select name from t where i <= 2;
select name from t where i > 2;
select name from t where i < 2;
select name from t where i >= 2 and i <= 3;
select name from t where i > 2 and i < 5;

select name from t where i = 2 and j > 1;
select name from t where i = 2 and j > 2;
select name from t where i = 2 and j > 3;
select name from t where i = 2 and j > 1 and j < 3;
