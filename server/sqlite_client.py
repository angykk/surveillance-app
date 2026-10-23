import sqlite3
import threading
import time
import uuid
from types import SimpleNamespace

# A local SQLite stand-in for the supabase client, for development and tests
# (set SQLITE_PATH). It implements just the slice of the PostgREST query
# builder the server uses — select (with one level of many-to-one embedding,
# e.g. `devices(name)`), insert, update, delete, the eq/is_/gt/in_ filters,
# order, limit, and the `provision_user` RPC — by translating each query to
# SQL. Mirrors supabase/schema.sql, minus Postgres-only parts (RLS, the
# auth.users link).

SCHEMA = '''
create table if not exists users (
  id text primary key,
  email text,
  created_at real not null
);
create table if not exists households (
  id text primary key,
  name text not null,
  owner_user_id text not null references users (id) on delete cascade,
  created_at real not null
);
create table if not exists memberships (
  user_id text not null references users (id) on delete cascade,
  household_id text not null references households (id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'viewer')),
  created_at real not null,
  primary key (user_id, household_id)
);
create table if not exists devices (
  id text primary key,
  household_id text not null references households (id) on delete cascade,
  name text not null,
  token_hash text not null unique,
  created_at real not null,
  last_seen_at real,
  revoked_at real
);
create table if not exists pairing_codes (
  code text primary key,
  household_id text not null references households (id) on delete cascade,
  created_by text not null references users (id) on delete cascade,
  expires_at real not null,
  used_at real
);
create table if not exists motion_events (
  id text primary key,
  device_id text not null references devices (id) on delete cascade,
  household_id text not null references households (id) on delete cascade,
  started_at real not null,
  ended_at real,
  clip_filename text,
  clip_size_bytes integer
);
'''

# (table, embedded table) -> the foreign key column on `table`.
_FOREIGN_KEYS = {
    ('devices', 'households'): 'household_id',
}


class SQLiteClient:
    def __init__(self, path):
        # One connection shared across Flask-SocketIO's threads, with every
        # statement serialized by a lock.
        self._conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        self._conn.execute('pragma foreign_keys = on')
        self._conn.executescript(SCHEMA)

    def table(self, name):
        return _Query(self, name)

    def rpc(self, name, params):
        if name != 'provision_user':
            raise ValueError(f'unknown rpc {name!r}')
        return SimpleNamespace(execute=lambda: self._provision_user(params['p_user_id'], params['p_email']))

    def _run(self, sql, args=()):
        with self._lock:
            return [dict(row) for row in self._conn.execute(sql, args).fetchall()]

    def _provision_user(self, user_id, email):
        """Same as `provision_user` in supabase/schema.sql: the user row plus
        a default "Home" household, in one transaction."""
        now = time.time()
        with self._lock:
            self._conn.execute('begin')
            try:
                created = self._conn.execute(
                    'insert into users (id, email, created_at) values (?, ?, ?) on conflict (id) do nothing',
                    (user_id, email, now),
                ).rowcount
                if created:
                    household_id = str(uuid.uuid4())
                    self._conn.execute(
                        'insert into households (id, name, owner_user_id, created_at) values (?, ?, ?, ?)',
                        (household_id, 'Home', user_id, now),
                    )
                    self._conn.execute(
                        'insert into memberships (user_id, household_id, role, created_at) values (?, ?, ?, ?)',
                        (user_id, household_id, 'owner', now),
                    )
                self._conn.execute('commit')
            except Exception:
                self._conn.execute('rollback')
                raise
        return SimpleNamespace(data=None)


class _Query:
    def __init__(self, client, name):
        self._client = client
        self._name = name
        self._op = None
        self._where = []
        self._args = []
        self._order = ''
        self._limit = ''

    def select(self, *columns):
        self._op = ('select', [c.strip() for c in ','.join(columns).split(',')])
        return self

    def insert(self, values):
        self._op = ('insert', values)
        return self

    def update(self, values):
        self._op = ('update', values)
        return self

    def delete(self):
        self._op = ('delete', None)
        return self

    def eq(self, column, value):
        return self._filter(f'{self._col(column)} = ?', value)

    def gt(self, column, value):
        return self._filter(f'{self._col(column)} > ?', value)

    def is_(self, column, value):
        if value != 'null':
            raise ValueError('only is_(column, "null") is supported')
        self._where.append(f'{self._col(column)} is null')
        return self

    def in_(self, column, values):
        values = list(values)
        self._where.append(f"{self._col(column)} in ({', '.join('?' * len(values))})" if values else '0')
        self._args.extend(values)
        return self

    def order(self, column, *, desc=False):
        self._order = f" order by {self._col(column)} {'desc' if desc else 'asc'}"
        return self

    def limit(self, n):
        self._limit = f' limit {int(n)}'
        return self

    def _filter(self, clause, value):
        self._where.append(clause)
        self._args.append(value)
        return self

    def _col(self, column):
        return f'"{self._name}"."{column}"'

    def _where_sql(self):
        return f" where {' and '.join(self._where)}" if self._where else ''

    def execute(self):
        op, arg = self._op
        run = self._client._run
        if op == 'insert':
            columns = ', '.join(f'"{c}"' for c in arg)
            placeholders = ', '.join('?' * len(arg))
            rows = run(
                f'insert into "{self._name}" ({columns}) values ({placeholders}) returning *',
                tuple(arg.values()),
            )
        elif op == 'update':
            assignments = ', '.join(f'"{c}" = ?' for c in arg)
            # One statement, so a conditional update (e.g. claiming a pairing
            # code) is atomic just as it is in Postgres.
            rows = run(
                f'update "{self._name}" set {assignments}{self._where_sql()} returning *',
                (*arg.values(), *self._args),
            )
        elif op == 'delete':
            rows = run(f'delete from "{self._name}"{self._where_sql()} returning *', tuple(self._args))
        else:
            rows = self._select(arg)
        return SimpleNamespace(data=rows)

    def _select(self, columns):
        selected, joins, embeds = [], [], []
        for column in columns:
            if column == '*':
                selected.append(f'"{self._name}".*')
            elif '(' in column:
                embedded, inner = column[:-1].split('(')
                fk = _FOREIGN_KEYS[(self._name, embedded)]
                joins.append(f' join "{embedded}" on "{embedded}".id = {self._col(fk)}')
                fields = [c.strip() for c in inner.split(',')]
                selected.extend(f'"{embedded}"."{c}" as "{embedded}.{c}"' for c in fields)
                embeds.append(embedded)
            else:
                selected.append(self._col(column))
        rows = self._client._run(
            f"select {', '.join(selected)} from \"{self._name}\"{''.join(joins)}"
            f'{self._where_sql()}{self._order}{self._limit}',
            tuple(self._args),
        )
        # Nest embedded columns the way PostgREST does: {'devices': {'name': ...}}.
        for row in rows:
            for embedded in embeds:
                prefix = f'{embedded}.'
                row[embedded] = {k[len(prefix):]: row.pop(k) for k in list(row) if k.startswith(prefix)}
        return rows
