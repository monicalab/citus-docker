-- Citus single shard table udf

-- init global tid_mark table
create or replace procedure citus.init_tid_mark()
    language plpgsql
as
$$
declare
    tid_mark_count int;
begin
    -- create global tid_mark table
    create table if not exists citus.tid_mark
    (
        tid text primary key
    );
    -- create distributed table for tid_mark
    select count(*) from citus_tables where table_name = 'citus.tid_mark'::regclass into tid_mark_count;
    if (tid_mark_count = 0) then
        perform create_distributed_table('citus.tid_mark', 'tid');
    end if;
end;
$$;

-- whether the table contains only one single shard
create or replace function citus.is_single_shard_table(tbl_name text)
    returns boolean
    language plpgsql
as
$$
declare
    r boolean;
begin
    select count(shardid) = 1
    from citus_shards
    where table_name = tbl_name::regclass
    into r;
    return r;
end;
$$;


-- whether the single shard table need to be rebalanced
create or replace function citus.is_single_shard_table_colocated(tbl_name text, tid text)
    returns boolean
    language plpgsql
as
$$
declare
    ori_nodename    text;
    ori_nodeport    integer;
    target_nodename text;
    target_nodeport integer;
begin
    if citus.is_single_shard_table(tbl_name) = false then
        return true;
    else
        select nodename, nodeport
        from citus_shards
        where table_name = tbl_name::regclass
        into ori_nodename, ori_nodeport;

        select nodename, nodeport
        from citus_shards
        where shardid = (select shardid
                         from pg_dist_shard
                         where logicalrelid = 'citus.tid_mark'::regclass
                           and (select hashtext(tid)) between shardminvalue::integer and shardmaxvalue::integer
                         limit 1)
        into target_nodename, target_nodeport;
        return not (ori_nodename = target_nodename and ori_nodeport = target_nodeport);
    end if;
end;
$$;

-- co-locate the  single shard table in citus cluster
create or replace function citus.colocate_single_shard_table(tbl_name text, tid text)
    returns record
    language plpgsql
as
$$
declare
    shard_id        bigint;
    ori_nodename    text;
    ori_nodeport    integer;
    target_nodename text;
    target_nodeport integer;
    r               record;
begin
    if citus.is_single_shard_table(tbl_name) = false then
        return r;
    else
        select shardid, nodename, nodeport
        from citus_shards
        where table_name = tbl_name::regclass
        into shard_id, ori_nodename, ori_nodeport;

        select nodename, nodeport
        from citus_shards
        where shardid = (select shardid
                         from pg_dist_shard
                         where logicalrelid = 'citus.tid_mark'::regclass
                           and (select hashtext(tid)) between shardminvalue::integer and shardmaxvalue::integer
                         limit 1)
        into target_nodename, target_nodeport;

        select shard_id, target_nodename, target_nodeport into r;

        if (ori_nodename = target_nodename and ori_nodeport = target_nodeport) then
            return r;
        else
            perform citus_move_shard_placement(shard_id, ori_nodename, ori_nodeport, target_nodename, target_nodeport);
            return r;
        end if;

    end if;
end;
$$;


-- randomly place the single shard table
create or replace function citus.randomly_single_shard_table(tbl_name text)
    returns record
    language plpgsql
as
$$
declare
    shard_id        bigint;
    ori_nodename    text;
    ori_nodeport    integer;
    target_nodename text;
    target_nodeport integer;
    r               record;
begin
    if citus.is_single_shard_table(tbl_name) = false then
        return r;
    else
        select shardid, nodename, nodeport
        from citus_shards
        where table_name = tbl_name::regclass
        into shard_id, ori_nodename, ori_nodeport;

        select node_name,
               node_port
        from citus_get_active_worker_nodes()
        order by random()
        limit 1
        into target_nodename, target_nodeport;

        select shard_id, target_nodename, target_nodeport into r;

        if (ori_nodename = target_nodename and ori_nodeport = target_nodeport) then
            return r;
        else
            perform citus_move_shard_placement(shard_id, ori_nodename, ori_nodeport, target_nodename,
                                               target_nodeport);

            return r;
        end if;
    end if;

end;
$$;


-- create a distributed table with only one shard
create or replace function citus.create_single_shard_distributed_table(tbl_name text)
    returns void
    language plpgsql
as
$$
declare
    ns_space    text;
    rel_name    text;
    has_pri_col boolean;
    shard_col   text;
begin
    select nspname, relname
    from pg_catalog.pg_class as c
             join pg_catalog.pg_namespace as ns
                  on c.relnamespace = ns.oid
    where c.oid = tbl_name::regclass::oid
    into ns_space, rel_name;

    select count(column_name) > 0
    from information_schema.key_column_usage
    where table_catalog = current_database()
      and table_schema = ns_space
      and table_name = rel_name
    into has_pri_col;

    if (has_pri_col) then
        -- using the first primary key column as shard key
        select column_name
        from information_schema.key_column_usage
        where table_catalog = current_database()
          and table_schema = ns_space
          and table_name = rel_name
        order by ordinal_position
        limit 1
        into shard_col;
        perform create_distributed_table(tbl_name, shard_col, shard_count := 1);
    else
        -- using the first column as shard key
        select column_name
        from information_schema.columns
        where table_catalog = current_database()
          and table_schema = ns_space
          and table_name = rel_name
        order by ordinal_position
        limit 1
        into shard_col;
        perform create_distributed_table(tbl_name, shard_col, shard_count := 1);
    end if;
end ;
$$;

