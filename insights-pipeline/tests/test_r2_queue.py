"""Tests for the R2 request-queue client (`insights/r2_queue.py`).

Pure key helpers are tested directly. `Boto3QueueClient` is tested only
against a mocked `boto3.client` -- no real R2 credentials or network calls.
"""

from __future__ import annotations

from unittest.mock import MagicMock

from insights.r2_queue import PENDING_PREFIX, Boto3QueueClient, parse_pending_key, request_object_key
from tests.helpers import make_config


def test_request_object_key_roundtrip():
    k = "tv:125988:S1E1"
    obj = request_object_key(k)
    assert obj == f"{PENDING_PREFIX}tv:125988:S1E1.json"
    assert parse_pending_key(obj) == k


def test_parse_ignores_non_json():
    assert parse_pending_key("requests/pending/") is None


def test_boto3_queue_client_requires_r2_configured():
    config = make_config()  # r2_* all empty by default
    import pytest

    with pytest.raises(RuntimeError):
        Boto3QueueClient(config)


def test_boto3_queue_client_list_pending(monkeypatch):
    config = make_config(
        r2_endpoint_url="https://example.r2.cloudflarestorage.com",
        r2_bucket="rivulet-insights",
        r2_access_key_id="key",
        r2_secret_access_key="secret",
    )
    fake_s3 = MagicMock()
    fake_s3.list_objects_v2.return_value = {
        "Contents": [{"Key": f"{PENDING_PREFIX}tv:1:S1E1.json"}, {"Key": f"{PENDING_PREFIX}movie:2.json"}]
    }
    monkeypatch.setattr("boto3.client", lambda *a, **kw: fake_s3)

    client = Boto3QueueClient(config)
    out = client.list_pending(10)

    fake_s3.list_objects_v2.assert_called_once_with(
        Bucket="rivulet-insights", Prefix=PENDING_PREFIX, MaxKeys=10
    )
    assert out == ["tv:1:S1E1", "movie:2"]


def test_boto3_queue_client_get_request(monkeypatch):
    config = make_config(
        r2_endpoint_url="https://example.r2.cloudflarestorage.com",
        r2_bucket="rivulet-insights",
        r2_access_key_id="key",
        r2_secret_access_key="secret",
    )
    fake_body = MagicMock()
    fake_body.read.return_value = b'{"key": "movie:1"}'
    fake_s3 = MagicMock()
    fake_s3.get_object.return_value = {"Body": fake_body}
    monkeypatch.setattr("boto3.client", lambda *a, **kw: fake_s3)

    client = Boto3QueueClient(config)
    result = client.get_request("movie:1")

    fake_s3.get_object.assert_called_once_with(
        Bucket="rivulet-insights", Key=f"{PENDING_PREFIX}movie:1.json"
    )
    assert result == {"key": "movie:1"}


def test_boto3_queue_client_delete_request(monkeypatch):
    config = make_config(
        r2_endpoint_url="https://example.r2.cloudflarestorage.com",
        r2_bucket="rivulet-insights",
        r2_access_key_id="key",
        r2_secret_access_key="secret",
    )
    fake_s3 = MagicMock()
    monkeypatch.setattr("boto3.client", lambda *a, **kw: fake_s3)

    client = Boto3QueueClient(config)
    client.delete_request("movie:1")

    fake_s3.delete_object.assert_called_once_with(
        Bucket="rivulet-insights", Key=f"{PENDING_PREFIX}movie:1.json"
    )


def test_boto3_queue_client_object_exists(monkeypatch):
    config = make_config(
        r2_endpoint_url="https://example.r2.cloudflarestorage.com",
        r2_bucket="rivulet-insights",
        r2_access_key_id="key",
        r2_secret_access_key="secret",
    )
    fake_s3 = MagicMock()
    monkeypatch.setattr("boto3.client", lambda *a, **kw: fake_s3)

    client = Boto3QueueClient(config)
    assert client.object_exists("insights/movie/1.json") is True
    fake_s3.head_object.assert_called_once_with(
        Bucket="rivulet-insights", Key="insights/movie/1.json"
    )

    fake_s3.head_object.side_effect = Exception("not found")
    assert client.object_exists("insights/movie/2.json") is False
