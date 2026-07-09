"""R2 request-queue access (S3 API via boto3).

The on-demand queue is one object per request under requests/pending/. The
Worker writes them; the serve stage lists, reads, and deletes them. boto3 is
used (not wrangler) because only the S3 API can LIST a prefix. Requires
config.r2_configured (an R2 S3 API token); the container sets these env vars.
"""

from __future__ import annotations

import json
import logging
from typing import Protocol

from insights.config import Config

logger = logging.getLogger(__name__)
PENDING_PREFIX = "requests/pending/"


def request_object_key(work_item_key: str) -> str:
    return f"{PENDING_PREFIX}{work_item_key}.json"


def parse_pending_key(object_key: str) -> str | None:
    if not object_key.startswith(PENDING_PREFIX) or not object_key.endswith(".json"):
        return None
    return object_key[len(PENDING_PREFIX) : -len(".json")]


class R2QueueClient(Protocol):
    def list_pending(self, max_items: int) -> list[str]: ...
    def get_request(self, work_item_key: str) -> dict | None: ...
    def delete_request(self, work_item_key: str) -> None: ...
    def object_exists(self, published_key: str) -> bool: ...


class Boto3QueueClient:
    def __init__(self, config: Config) -> None:
        if not config.r2_configured:
            raise RuntimeError("R2 not configured: on-demand queue needs r2_* env vars")
        import boto3

        self._bucket = config.r2_bucket
        self._s3 = boto3.client(
            "s3",
            endpoint_url=config.r2_endpoint_url,
            aws_access_key_id=config.r2_access_key_id,
            aws_secret_access_key=config.r2_secret_access_key,
        )

    def list_pending(self, max_items: int) -> list[str]:
        resp = self._s3.list_objects_v2(Bucket=self._bucket, Prefix=PENDING_PREFIX, MaxKeys=max_items)
        out = []
        for obj in resp.get("Contents", []):
            k = parse_pending_key(obj["Key"])
            if k:
                out.append(k)
        return out

    def get_request(self, work_item_key: str) -> dict | None:
        try:
            resp = self._s3.get_object(Bucket=self._bucket, Key=request_object_key(work_item_key))
        except self._s3.exceptions.NoSuchKey:
            return None
        return json.loads(resp["Body"].read())

    def delete_request(self, work_item_key: str) -> None:
        self._s3.delete_object(Bucket=self._bucket, Key=request_object_key(work_item_key))

    def object_exists(self, published_key: str) -> bool:
        try:
            self._s3.head_object(Bucket=self._bucket, Key=published_key)
            return True
        except Exception:
            return False
