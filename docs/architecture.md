# Machine roles

m3u is the server and workstation. It owns provider credentials, quota collection,
CLI history scans, and warm-up schedules. m4p is a display client: it fetches
published snapshots from the Incandenza hub and keeps an offline cache.

The installation role comes from machine-local configuration, never the hostname.
Collection requires an explicit `server` role. A client cannot fall back to local
providers or history, even when the server or its key is unavailable.

The existing quota export is also consumed by Incandenza's phone widget. Its wire
format stays independent of the application's shared-defaults snapshots. History
uses `UsageHistorySnapshot` with ISO-8601 dates and the server's calendar time zone.

`UsageHistorySource` is the seam for the Usage page. The local repository and the
remote client both satisfy it; view selection only projects the returned snapshot.
No client creates a local history repository.
