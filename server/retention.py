import threading
import time
import traceback

import clip_storage
import db

# Keeps clip storage from growing forever and from filling up with orphans:
#
# - Motion events (and so their clips) older than RETENTION_DAYS are deleted.
# - Every deleted motion event that had a clip leaves its storage key in
#   `clip_deletions` (a database trigger does this, see supabase/schema.sql),
#   whatever deleted it: this job, or a cascade from a deleted household or
#   Supabase Auth user, which the server never hears about. The job then
#   deletes those objects from storage and clears the queue.
#
# It runs in a background thread of the (single) server process.

# Storage's delete call takes up to 1000 keys.
BATCH_SIZE = 500


def run_once(retention_days, storage):
    if retention_days > 0:
        cutoff = db.now() - retention_days * 86400
        expired = db.table('motion_events').delete().lt('started_at', cutoff).execute().data
        if expired:
            print(f'Retention: deleted {len(expired)} motion events older than {retention_days} days')
    drain_deletions(storage)


def drain_deletions(storage):
    """Deletes every object queued in `clip_deletions` from storage. Also run
    right after a user deletes an event, so its files go straight away."""
    while True:
        rows = db.table('clip_deletions').select('clip_key').limit(BATCH_SIZE).execute().data
        if not rows:
            return
        keys = [row['clip_key'] for row in rows]
        storage.delete(keys)
        db.table('clip_deletions').delete().in_('clip_key', keys).execute()
        print(f'Deleted {len(keys)} clips from storage')
        if len(rows) < BATCH_SIZE:
            return


def start(app):
    retention_days = app.config['RETENTION_DAYS']
    interval_s = app.config['RETENTION_INTERVAL_S']
    storage = app.extensions['clip_storage']

    def loop():
        while True:
            try:
                run_once(retention_days, storage)
            except Exception:
                # A failed pass (e.g. storage briefly unreachable) leaves the
                # queue in place for the next one.
                traceback.print_exc()
            time.sleep(interval_s)

    threading.Thread(target=loop, name='retention', daemon=True).start()
