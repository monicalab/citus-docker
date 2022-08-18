# Citus

[![Image Size](https://raw.githubusercontent.com/citusdata/citus/main/citus-readme-banner.png)][image size]
[![Release](https://img.shields.io/github/release/citusdata/docker.svg)][release]
[![License](https://img.shields.io/github/license/citusdata/docker.svg)][license]

Citus is a PostgreSQL-based distributed RDBMS. For more information, see the [Citus Data website][citus data].

This branch adds additional support for [distributed single shard tables](#Distributed Single Shard Table Supports) to the citus project, as well as prepending the following pg plugins:

* [pg_jieba](https://github.com/jaiminpan/pg_jieba)

## Function

This image provides a single running Citus instance (atop PostgreSQL 12.2), using standard configuration values. It is based on [the official PostgreSQL image][docker-postgres], so be sure to consult that image’s documentation for advanced configuration options (including non-default settings for e.g. `PGDATA` or `POSTGRES_USER`).

Just like the standard PostgreSQL image, this image exposes port `5432`. In other words, all containers on the same Docker network should be able to connect on this port, and exposing it externally will permit connections from external clients (`psql`, adapters, applications).

## Usage

Since Citus is intended for use within a cluster, there are many ways to deploy it. This repository provides configuration to permit two kinds of deployment: local (standalone) or local (with workers).

### Standalone Use

If you just want to run a single Citus instance, it’s pretty easy to get started:

```bash
docker run --name citus_standalone -p 5432:5432 citusdata/citus
```

You should now be able to connect to `127.0.0.1` on port `5432` using e.g. `psql` to run a few commands (see the Citus documentation for more information).

As with the PostgreSQL image, the default `PGDATA` directory will be mounted as a volume, so it will persist between restarts of the container. But while the above _will_ get you a running Citus instance, it won’t have any workers to exercise distributed query planning. For that, you may wish to try the included [`docker-compose.yml`][compose-config] configuration.

#### Nightly Image

In addition to the `latest` (release) tag and the major-, minor-, and patch-specific tags, the `Dockerfile` in the `nightly` directory builds a tagged image with the latest Citus nightly (from the Citus `master` branch).

### Docker Compose

The included `docker-compose.yml` file provides an easy way to get started with a Citus cluster, complete with multiple workers. Just copy it to your current directory and run:

```bash
docker-compose -p citus up

# Creating network "citus_default" with the default driver
# Creating citus_worker_1
# Creating citus_master
# Creating citus_config
# Attaching to citus_worker_1, citus_master, citus_config
# worker_1    | The files belonging to this database system will be owned by user "postgres".
# worker_1    | This user must also own the server process.
# ...
```

That’s it! As with the standalone mode, you’ll want to find your `docker-machine ip` if you’re using that technology, otherwise, just connect locally to `5432`. By default, you’ll only have one worker:

```sql
SELECT master_get_active_worker_nodes();

--  master_get_active_worker_nodes
-- --------------------------------
--  (citus_worker_1,5432)
-- (1 row)
```

But you can add more workers at will using `docker-compose scale` in another tab. For instance, to bring your worker count to five…

```bash
docker-compose -p citus scale worker=5

# Creating and starting 2 ... done
# Creating and starting 3 ... done
# Creating and starting 4 ... done
# Creating and starting 5 ... done
```

```sql
SELECT master_get_active_worker_nodes();

--  master_get_active_worker_nodes
-- --------------------------------
--  (citus_worker_5,5432)
--  (citus_worker_1,5432)
--  (citus_worker_3,5432)
--  (citus_worker_2,5432)
--  (citus_worker_4,5432)
-- (5 rows)
```

If you inspect the configuration file, you’ll find that there is a container that is neither a master nor worker node: `citus_config`. It simply listens for new containers tagged with the worker role, then adds them to the config file in a volume shared with the master node. If new nodes have appeared, it calls `master_initialize_node_metadata` against the master to repopulate the node table. See Citus’ [`workerlist-gen`][workerlist-gen] repo for more details.

You can stop your cluster with `docker-compose -p citus down`.

## Distributed Single Shard Table Supports

In the multi-tenant scenario, citus solves the tenant partitioning problem for same-structured tables very well and maintains a good co-location policy. However, for tables with completely different structures held by different tenants, in the case that the data volume of these tables is small, such as the average total number of rows not exceeding 5000, directly using citus' distributed tables does not work well, and the query performance loss caused by multiple partitions (especially when the partitions are distributed on different nodes) is far worse than storing the table on a regular postgres node. But using native postgres directly does not take advantage of the sharding rebalancing capabilities provided by citus.

One solution is to wrap the native Postgres table into a single-shard citus distributed table and schedule it to the correct node using citus's sharddistribution policy. This achieves the goal of co-locating a small single-node storage table with the citus distributed table corresponding to the tenant's shard.

![image-20220818190748903](../../Library/Application Support/typora-user-images/image-20220818190748903.png)

### Usage

Initialize global distribution identifier after the citus cluster initialization is complete:

```sql
call citus.init_tid_mark()
```

Create a distributed single shard table, there are two shard placement strategies:

* Co-located with tenant-id:  `citus.colocate_single_shard_table`
* Random distribution: `citus.randomly_single_shard_table`

```sql
-- create a local table on coordinator node
create table test(
  f1 text,
  f2 int,
  f3 int
);

-- wrapper the local table 'test' as distributed single shard table
select citus.create_single_shard_distributed_table('test')

-- strategy A: co-located with tenent-id
select citus.colocate_single_shard_table('test', 'f1741e9e-fbbb-41f3-9160-77109a073f75')

-- strategy B: random distributed
select citus.randomly_single_shard_table('test')
```

By default, the first primary key column of the wrapped table or this first normal column (in case it does not contain any primary key) is used as the shard column of the citus distributed table.

When the citus cluster is scaling out, consider rebalancing distributed single shard table to the correct tenent_id co-located node:

```sql
select citus.colocate_single_shard_table('test')
```

Of course, the distributed single shard table itself is a citus distributed table and can be converted to a citus native distributed table at any time.

```sql
-- convert to citus native distributed table
select alter_distributed_table('test', distribution_column:='f2', shard_count:=32)
```

## Build Image

```bash
git submodule update --init --recursive pg_jieba
docker build -t citus-monica .
```

## License

The following license information (and associated [LICENSE][license] file) apply _only to the files within **this** repository_. Please consult Citus’s own repository for information regarding its licensing.

Copyright © 2016–2017 Citus Data, Inc.

Licensed under the Apache License, Version 2.0 (the “License”); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

[image size]: https://microbadger.com/images/citusdata/citus
[release]: https://github.com/citusdata/docker/releases/latest
[license]: LICENSE
[citus data]: https://www.citusdata.com
[docker-postgres]: https://hub.docker.com/_/postgres/
[compose-config]: docker-compose.yml
[workerlist-gen]: https://github.com/citusdata/workerlist-gen
