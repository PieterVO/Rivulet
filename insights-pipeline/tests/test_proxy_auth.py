"""The pipeline authenticates to the tmdb-proxy Worker with a server secret.

The Worker requires App Attest from the app. This pipeline is a server: it has
no Secure Enclave and cannot attest, so it presents a shared secret instead.
If it stops sending that header, the seed stage silently loses TMDB access the
moment the Worker flips from "observe" to "enforce" — so pin the behavior.
"""

from unittest.mock import patch

from insights.stages import seed

from .helpers import make_config


class _Resp:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        pass

    def json(self):
        return self._payload


def test_proxy_get_sends_the_server_key():
    config = make_config(tmdb_proxy_server_key="s3cret")

    with patch.object(seed.requests, "get", return_value=_Resp({"ok": True})) as get:
        seed._proxy_get(config, "/tmdb/list/popular", {"type": "movie"})

    headers = get.call_args.kwargs["headers"]
    assert headers["X-Rivulet-Server-Key"] == "s3cret"


def test_proxy_get_omits_the_header_when_no_key_is_configured():
    # Empty key = send nothing. Still works while the Worker is in "observe",
    # and must not send an empty header (the Worker treats a present-but-wrong
    # key as a forgery attempt and rejects it outright).
    config = make_config(tmdb_proxy_server_key="")

    with patch.object(seed.requests, "get", return_value=_Resp({"ok": True})) as get:
        seed._proxy_get(config, "/tmdb/list/popular", {"type": "movie"})

    assert "X-Rivulet-Server-Key" not in get.call_args.kwargs["headers"]


def test_every_proxy_route_goes_through_the_authenticated_helper():
    # All three tmdb-proxy calls must carry the key, not just the list route.
    config = make_config(tmdb_proxy_server_key="s3cret")

    with patch.object(seed.requests, "get", return_value=_Resp({"number_of_seasons": 2})) as get:
        seed._fetch_tmdb_list(config, "popular", "movie")
        seed._fetch_tmdb_show_season_count(config, 1399)
        seed._fetch_tmdb_season(config, 1399, 1)

    assert get.call_count == 3
    for call in get.call_args_list:
        assert call.kwargs["headers"]["X-Rivulet-Server-Key"] == "s3cret"
