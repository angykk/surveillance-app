import time
import uuid

from supabase import Client, create_client

# Data lives in the Supabase project's Postgres (schema: supabase/schema.sql),
# reached through the supabase client over HTTPS rather than a direct
# Postgres connection. Everything a user can see is scoped by household: a
# user reaches cameras and motion events only through a membership in the
# household that owns them.
#
# Rows come back as plain dicts. Queries go through the Data API, so there
# are no multi-statement transactions; the one place that needs atomicity
# (first-sign-in provisioning) is the `provision_user` Postgres function.

ROLES = ('owner', 'admin', 'viewer')
MANAGER_ROLES = ('owner', 'admin')

client: Client = None


def init_client(url, key):
    global client
    if key.startswith('sb_publishable_'):
        # The publishable key is the one shipped in the mobile app; RLS
        # blocks it from every table, so the server would fail on its first
        # query with a less obvious error.
        raise RuntimeError(
            'SUPABASE_KEY is the publishable key. The server needs the secret key '
            '(Project Settings → API Keys → Secret keys, starts with sb_secret_).'
        )
    client = create_client(url, key)
    return client


def use_client(stand_in):
    """Swaps in a stand-in client, e.g. the local SQLite one."""
    global client
    client = stand_in


def table(name):
    return client.table(name)


def first(response):
    """The first row of a query response, or None."""
    return response.data[0] if response.data else None


def new_id():
    return str(uuid.uuid4())


def is_id(value):
    """Whether `value` is shaped like an id column (uuid). Ids taken from a
    URL are checked first, since Postgres rejects a malformed uuid with an
    error rather than matching no rows."""
    try:
        uuid.UUID(value)
        return True
    except (TypeError, ValueError):
        return False


def now():
    return time.time()
