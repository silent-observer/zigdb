create table employees (emp_name text, emp_department uint4);
create table departments (dep_id uint4, dep_name text);

insert into employees values ('Rafferty',   31),
                             ('Jones',      33),
                             ('Heisenberg', 33),
                             ('Robinson',   34),
                             ('Smith',      34),
                             ('Williams',   null);

insert into departments values (31, 'Sales'),
                               (33, 'Engineering'),
                               (34, 'Clerical'),
                               (35, 'Marketing');

select * from employees;
select * from departments;

select * from employees cross join departments;
select * from employees, departments;
select * from employees inner join departments on 1=1;

select emp_name, dep_id, dep_name
    from employees
    join departments on emp_department = dep_id;
select emp_name, dep_id, dep_name
    from employees, departments
    where emp_department = dep_id;

select emp_name, dep_id, dep_name
    from employees
    left join departments on emp_department = dep_id;
select emp_name, dep_id, dep_name
    from employees
    right join departments on emp_department = dep_id;
select emp_name, dep_id, dep_name
    from employees
    full join departments on emp_department = dep_id;
