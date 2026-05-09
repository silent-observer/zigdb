create table t (i int);
insert into t values (1), (2), (3);

1: begin;
2: begin;
3: begin;
4: begin;

1: truncate t;
2&: select i from t;
3&: truncate t;
4&: insert into t values (4);

2&:
3&:
4&:

1: commit;
2W:
3&:
4W:

2: commit;
4: commit;
3W:

3: commit;

select i from t;
drop table t;
